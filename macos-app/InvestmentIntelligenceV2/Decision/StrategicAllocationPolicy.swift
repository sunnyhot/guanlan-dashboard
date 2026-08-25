import Foundation

// MARK: - Strategic Allocation Target（DEC-1，Epic 10，ADR-D000）
//
// D000 Cardinal Firewall 第一道：Target 的来源必须显式、可审计、不可被
// 非授权源修改。只允许 explicitUserAllocation / userSelectedTemplate 两类
// provenance；Signal / Factor / LLM / Agent 都不能改 Target——
// AllocationTarget 的唯一构造入口是 StrategicAllocationPolicy 的两个
// apply 方法（签名上不存在「从 Signal / Risk / Exposure 构造 Target」
// 的通道），Agent 只能推荐目录已有模板给用户显式确认。

/// Target 配置来源（D000 §Decision 1，仅两类）。
enum TargetAllocationProvenance: Sendable, Codable, Hashable {
    /// 用户显式配置（手输权重）
    case explicitUserAllocation(ExplicitUserAllocation)
    /// 用户从目录选择的模板（晓磊 / 长赢 / 且慢投顾组合）
    case userSelectedTemplate(UserSelectedTemplate)

    struct ExplicitUserAllocation: Sendable, Codable, Hashable {
        let configuredAt: Date
        /// 用户备注（可选）
        let note: String?
    }

    struct UserSelectedTemplate: Sendable, Codable, Hashable {
        let templateID: String
        let templateVersion: String
        let selectedAt: Date
        /// 是否经 Agent 推荐（推荐 ≠ 写入：用户必须显式确认才走到这里）
        let recommendedByAgent: Bool
    }
}

/// 单个资产大类的目标权重条目。
struct AllocationTargetEntry: Sendable, Codable, Hashable {
    let assetClass: AssetClass
    let targetWeight: Ratio

    init(assetClass: AssetClass, targetWeight: Ratio) {
        self.assetClass = assetClass
        self.targetWeight = targetWeight
    }
}

/// 一份战略目标配置（不可变值；变更走 StrategicAllocationPolicy 产新实例）。
///
/// **构造封闭（审查 P1-7 修复，D000）**：memberwise init 被 `fileprivate`
/// init 抑制——同文件的 StrategicAllocationPolicy 是唯一构造入口，模块内
/// 其他代码（含未来 Epic 11 的 Agent）无法绕过 Policy/Validator 直接构造。
/// Codable 解码走校验式 init(from:)：脏数据（权重和≠1 等）在解码点拒绝。
struct AllocationTarget: Sendable, Codable, Hashable {
    let id: InvestmentTargetID
    /// 全部资产大类的目标（完备：Validator 保证无缺漏由调用方对齐
    /// Policy 的资产类集合；权重和恰为 1，无「剩余配 cash」隐式行为）
    let entries: [AllocationTargetEntry]
    let provenance: TargetAllocationProvenance
    let createdAt: Date

    /// 唯一构造入口（fileprivate：抑制 memberwise init，只有同文件的
    /// StrategicAllocationPolicy 两个 apply 方法能构造）。
    fileprivate init(
        id: InvestmentTargetID, entries: [AllocationTargetEntry],
        provenance: TargetAllocationProvenance, createdAt: Date
    ) {
        self.id = id
        self.entries = entries
        self.provenance = provenance
        self.createdAt = createdAt
    }

    /// 校验式解码：不满足 Validator 门禁的 JSON 在解码点拒绝（fail-closed）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(InvestmentTargetID.self, forKey: .id)
        let decodedEntries = try container.decode([AllocationTargetEntry].self, forKey: .entries)
        provenance = try container.decode(TargetAllocationProvenance.self, forKey: .provenance)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        do {
            try StrategicAllocationValidator().validate(entries: decodedEntries)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "AllocationTarget 解码校验失败（D000 门禁）: \(error)"
            ))
        }
        // 二轮审查 P1-4：ID 必须与内容自洽——按规范化 entries + provenance +
        // createdAt 重算派生 ID，与 JSON 提供的 id 核对（换内容保旧 ID 的
        // 「伪造 Target」在解码点拒绝，Target 引用与 D000 防火墙成立）。
        let recomputed = StrategicAllocationPolicy.deriveID(
            provenance: provenance, entries: decodedEntries, createdAt: createdAt
        )
        guard recomputed == id else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "AllocationTarget ID 与内容不一致（应为 \(recomputed.rawValue)，实为 \(id.rawValue)）——拒绝伪造 ID"
            ))
        }
        // 十轮 P3:解码归一化 entries 顺序(deriveID 内部按归一化派生,乱序
        // JSON 本就能过 ID 核对)——否则同 ID 的 Target 会以乱序形态存在,
        // 与构造路径产物「id 相同、== 不等」(同 ID 双形态);归一化收口后
        // 同 id 必同形态
        entries = StrategicAllocationPolicy.normalized(decodedEntries)
    }

    private enum CodingKeys: String, CodingKey {
        case id, entries, provenance, createdAt
    }

    /// 某资产大类的目标权重（缺省 nil——缺即缺，不默认 0）
    func targetWeight(for assetClass: AssetClass) -> Ratio? {
        entries.first { $0.assetClass == assetClass }?.targetWeight
    }
}

// MARK: - 模板目录（D000 §Decision 3：显式数据，不在 Agent 控制下）

/// 目标配置模板目录。
struct AllocationTemplateCatalog: Sendable, Codable, Hashable {
    let templates: [Template]

    struct Template: Sendable, Codable, Hashable {
        let id: String
        let version: String
        let displayName: String
        let entries: [AllocationTargetEntry]
    }

    subscript(id: String) -> Template? {
        templates.first { $0.id == id }
    }
}

// MARK: - Validator（D000 §Decision 4）

/// Target 写入门禁校验器。
struct StrategicAllocationValidator: Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case emptyEntries
        case negativeWeight(AssetClass)
        case duplicateAssetClass(AssetClass)
        /// 权重和 ≠ 1（显式报差值；「剩余配 cash」类隐式补齐禁止）
        case weightsDoNotSumToOne(sum: Decimal)
    }

    /// 校验目标条目集：非空 / 权重非负 / 无重复资产类 / 权重和恰为 1。
    func validate(entries: [AllocationTargetEntry]) throws {
        guard !entries.isEmpty else { throw ValidationError.emptyEntries }
        var seen = Set<AssetClass>()
        var sum = Decimal.zero
        for entry in entries {
            if entry.targetWeight.value < 0 {
                throw ValidationError.negativeWeight(entry.assetClass)
            }
            if !seen.insert(entry.assetClass).inserted {
                throw ValidationError.duplicateAssetClass(entry.assetClass)
            }
            sum += entry.targetWeight.value
        }
        guard sum == Decimal(1) else {
            throw ValidationError.weightsDoNotSumToOne(sum: sum)
        }
    }
}

// MARK: - StrategicAllocationPolicy（唯一写入路径）

/// 战略目标配置的写入门禁（DEC-1）。
///
/// **类型层保证「Signal 不能改 Target」**：两个 apply 方法是
/// AllocationTarget 的唯一合法构造入口，它们的参数里不存在任何
/// Signal / RiskProfile / Exposure 类型——信号影响只能走 Δw（D001）
/// 与 Criterion（D002），Target 永远只从用户动作产生。
struct StrategicAllocationPolicy: Sendable {
    let validator = StrategicAllocationValidator()
    static let policyVersion = "v1"

    enum PolicyError: Error, Equatable, Sendable {
        /// 目录里没有该模板（Agent 不能凭空生成 / 合成模板）
        case unknownTemplate(templateID: String)
        /// 条目非法（透传 Validator 的具体形态）
        case invalidEntries(StrategicAllocationValidator.ValidationError)
        /// 目录模板自身权重不合规（数据问题，目录维护方修）
        case templateEntriesInvalid(templateID: String)
    }

    /// 用户显式手输配置（D000 explicitUserAllocation）。
    func applyUserAllocation(
        entries: [AllocationTargetEntry],
        note: String?,
        now: Date
    ) throws -> AllocationTarget {
        do {
            try validator.validate(entries: entries)
        } catch let error as StrategicAllocationValidator.ValidationError {
            throw PolicyError.invalidEntries(error)
        }
        let provenance = TargetAllocationProvenance.explicitUserAllocation(
            .init(configuredAt: now, note: note)
        )
        return AllocationTarget(
            id: Self.deriveID(provenance: provenance, entries: entries, createdAt: now),
            entries: Self.normalized(entries),
            provenance: provenance,
            createdAt: now
        )
    }

    /// 用户从目录选择模板（D000 userSelectedTemplate）。
    ///
    /// - 模板必须在 catalog 中存在（Agent 不能凭空生成 / 合成模板）
    /// - viaAgentRecommendation 只进入 provenance 标注，写入语义不变：
    ///   方法被调用 = 用户已显式确认（推荐的确认动作在调用方，不在本类型）
    func applyTemplateSelection(
        templateID: String,
        catalog: AllocationTemplateCatalog,
        now: Date,
        viaAgentRecommendation: Bool
    ) throws -> AllocationTarget {
        guard let template = catalog[templateID] else {
            throw PolicyError.unknownTemplate(templateID: templateID)
        }
        do {
            try validator.validate(entries: template.entries)
        } catch is StrategicAllocationValidator.ValidationError {
            throw PolicyError.templateEntriesInvalid(templateID: templateID)
        }
        let provenance = TargetAllocationProvenance.userSelectedTemplate(.init(
            templateID: template.id,
            templateVersion: template.version,
            selectedAt: now,
            recommendedByAgent: viaAgentRecommendation
        ))
        return AllocationTarget(
            id: Self.deriveID(provenance: provenance, entries: template.entries, createdAt: now),
            entries: Self.normalized(template.entries),
            provenance: provenance,
            createdAt: now
        )
    }

    // MARK: - helpers

    /// 条目按 AssetClass rawValue 排序（确定性存储形态；权重值保持原样）。
    /// fileprivate：同文件的 AllocationTarget.init(from:) 解码归一化共用
    /// （十轮 P3：同 id 的 Target 必同形态）。
    fileprivate static func normalized(_ entries: [AllocationTargetEntry]) -> [AllocationTargetEntry] {
        entries.sorted { $0.assetClass.rawValue < $1.assetClass.rawValue }
    }

    /// Target ID 确定性派生（语义完备：provenance + 时间 + entries——
    /// 审查 P1-3 修复：不同 entries 的同日配置不再互相碰撞）。
    fileprivate static func deriveID(
        provenance: TargetAllocationProvenance, entries: [AllocationTargetEntry], createdAt: Date
    ) -> InvestmentTargetID {
        // 确定性类型的编码失败 = 编程错误,fail-fast
        let payload = try! StableDigest.jsonPayload(IdentityPayload(
            provenance: provenance,
            entries: normalized(entries),
            createdAt: createdAt
        ))
        return InvestmentTargetID(rawValue: "at_\(StableDigest.digest(payload))")
    }

    private struct IdentityPayload: Encodable {
        let provenance: TargetAllocationProvenance
        let entries: [AllocationTargetEntry]
        let createdAt: Date
    }
}
