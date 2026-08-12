import Foundation

// MARK: - ProviderRecordSchemaValidator（PROV-1，ADR-DATA003 §Decision 3 Pipeline 第 4 步）
//
// Pipeline 顺序：Staging → IdentityResolver → TemporalNormalizer → **SchemaValidator**
//                → DataValidator → Canonical Commit。
//
// **职责边界**（与 ObservationFactory 互补，不重叠）：
// - SchemaValidator 是 ProviderRecord 的 **结构性前置闸门**：字段非空、kind/reliability
//   合法、时间序合理、rawPayload 能按声明的 kind 解码成对应 schema。廉价、无 I/O、不做
//   identity 解析也不构建 CanonicalObservation。
// - ObservationFactory（REPO-5a/5b）才是 **语义转换**：identity 解析 + policy 选择 +
//   PIT 标注 + Canonical 构建。Factory 会再次解码 payload 作为权威构建来源（commit 路径
//   仅占 0.1% 调用，重复解码可接受；GRDB-8 可后续优化为透传已解码 payload）。
//
// 这样脏记录（schema 漂移 / 字段缺失）在进 Factory 前就被拒，错误归类清晰：
// SchemaValidator 报「结构非法」，Factory 报「identity/temporal/payload 语义失败」。

/// ProviderRecord 结构校验错误。
enum ProviderRecordSchemaError: Error, Equatable, Sendable {
    /// providerID 为空
    case emptyProviderID
    /// providerCode 的 scheme 或 value 为空
    case emptyProviderCode
    /// rawPayload 为空（Adapter 必须产非空 payload）
    case emptyPayload
    /// 时间序违反：effectiveAt 必须不晚于 publishedAt（事件先发生再公布）
    case invalidTimestampOrder
    /// rawPayload 无法按声明的 kind 解码（schema 漂移 / kind 与 payload 不匹配）
    case payloadSchemaMismatch(kind: ProviderRecordKind, detail: String)
}

/// ProviderRecord 结构校验器。
///
/// 不做 identity 解析、不做业务校验（NAV>0 / 权重和≤1 等留给 DataValidator / GRDB-8）。
/// 只保证记录「形状正确」，可安全进入后续 Pipeline 步骤。
struct ProviderRecordSchemaValidator: Sendable {
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    /// 校验单条 ProviderRecord。通过返回原记录（便于链式 / 收集合法批），
    /// 失败抛 ProviderRecordSchemaError（Pipeline 拒收并按 Provider 降级，ADR-DATA006）。
    @discardableResult
    func validate(_ record: ProviderRecord) throws -> ProviderRecord {
        guard !record.providerID.rawValue.isEmpty else {
            throw ProviderRecordSchemaError.emptyProviderID
        }
        guard !record.providerCode.scheme.isEmpty, !record.providerCode.value.isEmpty else {
            throw ProviderRecordSchemaError.emptyProviderCode
        }
        guard !record.rawPayload.isEmpty else {
            throw ProviderRecordSchemaError.emptyPayload
        }
        // 时间序：effectiveAt ≤ publishedAt（事件→公布，恒成立）。
        // 不校验 ingestedAt——它是本机抓取时间，与 availableAt/有效事件无固定序（DATA002 §4）。
        guard record.effectiveAt <= record.publishedAt else {
            throw ProviderRecordSchemaError.invalidTimestampOrder
        }
        // payload schema：rawPayload 必须能按声明的 kind 解码为对应 schema struct。
        // 捕获 kind 与 payload 不匹配（如 kind=dailyBar 但 payload 是 NAVPayload）。
        do {
            try validatePayloadSchema(kind: record.kind, payload: record.rawPayload)
        } catch let e as ProviderRecordSchemaError {
            throw e
        } catch {
            throw ProviderRecordSchemaError.payloadSchemaMismatch(kind: record.kind, detail: "\(error)")
        }
        return record
    }

    /// 按 kind 分派解码 rawPayload，验证 schema 匹配。
    private func validatePayloadSchema(kind: ProviderRecordKind, payload: Data) throws {
        switch kind {
        case .dailyBar:
            _ = try decoder.decode(DailyBarPayload.self, from: payload)
        case .navObservation:
            _ = try decoder.decode(NAVPayload.self, from: payload)
        case .fundHoldingSnapshot:
            _ = try decoder.decode(FundHoldingPayload.self, from: payload)
        case .macroObservation:
            _ = try decoder.decode(MacroPayload.self, from: payload)
        case .corporateAction:
            _ = try decoder.decode(CorporateActionPayload.self, from: payload)
        }
    }

    /// 批量校验：返回 (合法, 非法) 分桶。非法记录带错误，调用方可据此降级 / 告警
    /// （ADR-DATA006 三档降级：部分失败不应让整批 Provider 数据全丢）。
    func partition(_ records: [ProviderRecord]) -> (valid: [ProviderRecord], invalid: [(record: ProviderRecord, error: ProviderRecordSchemaError)]) {
        var valid: [ProviderRecord] = []
        var invalid: [(ProviderRecord, ProviderRecordSchemaError)] = []
        for record in records {
            do {
                valid.append(try validate(record))
            } catch let e as ProviderRecordSchemaError {
                invalid.append((record, e))
            } catch {
                // 不应发生（validate 只抛 ProviderRecordSchemaError），兜底
                invalid.append((record, .payloadSchemaMismatch(kind: record.kind, detail: "\(error)")))
            }
        }
        return (valid, invalid)
    }
}
