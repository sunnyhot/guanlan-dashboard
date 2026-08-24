import Foundation
import CryptoKit

// MARK: - CanonicalPipeline（GRDB-8，Staging → Canonical Commit 的四防火墙管道）
//
// ADR-DATA003 §Decision 3 的 Canonical 化路径，防火墙全部在 commit 之前：
//
// ```
// ProviderRecord[]（来自 staging spool / Provider 直产）
//   ① ProviderRecordSchemaValidator   结构闸门（字段非空 / 时间序 / payload 解码）
//   ② ObservationFactory              identity 解析（防火墙 1：未解析 / fuzzy 拒收）
//                                    + TemporalNormalizer（防火墙 2：policy 选 + PIT 标注）
//   ③ CanonicalDataValidator          语义闸门（四时间不变量 / OHLC 拓扑 / 正性 / 权重界）
//   ④ GRDBRepository.commit           单事务提交（防火墙 4 兜底：FK 违例整批回滚）
// ```
//
// **拒收粒度**：单条记录拒收不阻塞批次——合法子集照常提交（DATA006 拒收
// 不阻塞的管道侧语义）；拒收逐条报告（stage + 原因），供上层诊断与重试。
//
// **幂等与确定性**（ADR-DATA004：spool 是事实源、库是派生物，重放重建）：
// - ObservationID = SHA256(provider + scheme + value + kind + effectiveAt +
//   publishedAt)——同一条 ProviderRecord 重放生成同 ID，INSERT OR REPLACE
//   幂等替换；
// - Vintage = (announcementDate: publishedAt, publisherVersion: 1)——Provider
//   重新公布（更正公告）= 不同 publishedAt = 新 vintage 行，旧 vintage 保留
//   （ADR-DATA008）。publisherVersion > 1 保留给同公告日的多次修订
//  （ProviderRecord 无法表达，SEC/FRED 的修订天然带新 filed/vintage 日期）。

/// Staging → Canonical Commit 管道。
struct CanonicalPipeline: Sendable {

    /// 单条记录被拒收的阶段（对应四防火墙 + 提交事务）。
    enum RejectionStage: String, Sendable, Equatable {
        case schema = "SCHEMA"
        case identityTemporal = "IDENTITY_TEMPORAL"
        case dataValidation = "DATA_VALIDATION"
        /// 同 (维度, effectiveAt, vintage, provider) 已有不同内容——审查 P1：
        /// 重摄入不得静默覆盖历史；逐条拒收不阻塞批次。
        case contentConflict = "CONTENT_CONFLICT"
        case commit = "COMMIT"
    }

    /// 单条拒收（进入结果报告；不阻塞批次）。
    struct Rejection: Equatable, Sendable {
        let provider: String
        let scheme: String
        let value: String
        let kind: String
        let stage: RejectionStage
        let reason: String
    }

    /// 一轮 commit 的结果。
    struct CommitResult: Equatable, Sendable {
        /// 成功提交的记录数（单事务原子）
        let committedCount: Int
        /// 拒收清单（防火墙 ①②③；逐条原因）
        let rejections: [Rejection]
        /// 提交事务失败（防火墙 ④：FK 违例等——**整批回滚，未提交任何行**）。
        /// 非 nil 时 committedCount == 0 且 rejections 的合法子集也未入库。
        let commitError: String?
    }

    private let repository: GRDBRepository
    private let schemaValidator: ProviderRecordSchemaValidator
    private let dataValidator: CanonicalDataValidator
    private let calendar: TradingCalendar

    init(
        repository: GRDBRepository,
        calendar: TradingCalendar,
        schemaValidator: ProviderRecordSchemaValidator = ProviderRecordSchemaValidator(),
        dataValidator: CanonicalDataValidator = CanonicalDataValidator()
    ) {
        self.repository = repository
        self.calendar = calendar
        self.schemaValidator = schemaValidator
        self.dataValidator = dataValidator
    }

    // MARK: - 主入口

    /// 把一批 ProviderRecord canonical 化并提交。
    ///
    /// identity 快照在入口一次性取自 Repository（`allProviderIdentifiers`），
    /// 整批用同一份映射（批内一致性）；SYNC-8 的增量 identity 建立是另一条路径。
    func commit(records: [ProviderRecord]) -> CommitResult {
        let resolver = IdentityResolver.from(repository.allProviderIdentifiers())
        let factory = ObservationFactory(normalizer: TemporalNormalizer(calendar: calendar), resolver: resolver)

        var accepted: [CanonicalObservationKind] = []
        var rejections: [Rejection] = []

        for record in records {
            do {
                // ① 结构闸门
                let structural = try schemaValidator.validate(record)
                // ② identity 解析 + 时间规范化（防火墙 1 + 2）
                let observation = try factory.makeObservation(
                    from: structural,
                    observationID: Self.deriveObservationID(from: record),
                    vintage: Self.deriveVintage(from: record)
                )
                // ③ 语义闸门
                try dataValidator.validate(observation)
                accepted.append(observation)
            } catch {
                rejections.append(Self.rejection(for: record, error: error))
            }
        }

        // ④ Canonical Commit（单事务；内容冲突逐条拒收，FK 违例整批回滚）
        do {
            let conflicts = try repository.commit(accepted)
            var allRejections = rejections
            for conflict in conflicts {
                if case .observationContentConflict(let observationID, let table) = conflict {
                    allRejections.append(Rejection(
                        provider: "-", scheme: "-", value: observationID,
                        kind: "-", stage: .contentConflict,
                        reason: "\(table) 同身份重摄入内容不同：\(conflict)"
                    ))
                }
            }
            return CommitResult(
                committedCount: accepted.count - conflicts.count,
                rejections: allRejections,
                commitError: nil
            )
        } catch {
            return CommitResult(
                committedCount: 0,
                rejections: rejections,
                commitError: "commit 事务失败（整批回滚）：\(error)"
            )
        }
    }

    // MARK: - 确定性派生（幂等重放的前提）

    /// ObservationID = SHA256(provider|scheme|value|kind|effective|published)。
    /// 同一条 ProviderRecord 任何时刻重放生成同一 ID。
    static func deriveObservationID(from record: ProviderRecord) -> ObservationID {
        let ms: (Date) -> Int64 = { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
        let canonical = [
            record.providerID.rawValue,
            record.providerCode.scheme,
            record.providerCode.value,
            record.kind.rawValue,
            String(ms(record.effectiveAt)),
            String(ms(record.publishedAt)),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return ObservationID(rawValue: "obs_\(hex)")
    }

    /// Vintage = (announcementDate: publishedAt, publisherVersion: 1)。
    /// Provider 更正重公布 → 新 publishedAt → 新 vintage（旧行保留，DATA008）。
    static func deriveVintage(from record: ProviderRecord) -> Vintage {
        Vintage(announcementDate: record.publishedAt, publisherVersion: 1)
    }

    // MARK: - 错误归因

    private static func rejection(for record: ProviderRecord, error: Error) -> Rejection {
        let stage: RejectionStage
        switch error {
        case is ProviderRecordSchemaError:
            stage = .schema
        case is ObservationFactoryError:
            stage = .identityTemporal
        case is CanonicalDataValidator.Violation:
            stage = .dataValidation
        default:
            stage = .identityTemporal
        }
        return Rejection(
            provider: record.providerID.rawValue,
            scheme: record.providerCode.scheme,
            value: record.providerCode.value,
            kind: record.kind.rawValue,
            stage: stage,
            reason: String(describing: error)
        )
    }
}

// MARK: - staging spool 直连（PROV-1 Reader → pipeline）

extension CanonicalPipeline {

    /// 从 staging JSONL spool 读取一轮并提交（Sync 循环的每轮入口，SYNC-2..5）。
    /// spool 读取失败抛错（文件级问题不是记录级拒收，调用方决定重试）。
    func commitRecords(fromSpool url: URL) throws -> CommitResult {
        let records = try ProviderStagingReader().read(from: url)
        return commit(records: records)
    }
}
