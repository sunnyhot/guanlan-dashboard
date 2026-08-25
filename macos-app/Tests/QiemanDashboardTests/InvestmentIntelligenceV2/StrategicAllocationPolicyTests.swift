import XCTest
@testable import QiemanDashboard

/// DEC-1 单元测试：StrategicAllocationPolicy / AllocationTarget /
/// TargetAllocationProvenance / StrategicAllocationValidator（ADR-D000）。
final class StrategicAllocationPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let policy = StrategicAllocationPolicy()

    private func r(_ s: String) -> Ratio { Ratio(value: Decimal(string: s)!) }
    private func entry(_ cls: AssetClass, _ w: String) -> AllocationTargetEntry {
        AllocationTargetEntry(assetClass: cls, targetWeight: r(w))
    }

    private var sampleCatalog: AllocationTemplateCatalog {
        AllocationTemplateCatalog(templates: [
            .init(id: "xiaolei-si000192", version: "v3", displayName: "基金全磊打",
                  entries: [entry(.equity, "0.8"), entry(.fixedIncome, "0.15"), entry(.cash, "0.05")]),
        ])
    }

    // MARK: - 用户显式配置(D000 来源一)

    func testUserAllocationProducesAuditableTarget() throws {
        let target = try policy.applyUserAllocation(
            entries: [entry(.equity, "0.6"), entry(.fixedIncome, "0.4")],
            note: "股六债四", now: now
        )
        XCTAssertEqual(target.entries.map(\.assetClass), [.equity, .fixedIncome], "按 rawValue 排序的确定性形态")
        XCTAssertEqual(target.targetWeight(for: .equity)?.value, Decimal(string: "0.6"))
        XCTAssertEqual(target.targetWeight(for: .alternative), nil, "缺即缺,不默认 0")

        guard case .explicitUserAllocation(let detail) = target.provenance else {
            return XCTFail("provenance 必须是 explicitUserAllocation")
        }
        XCTAssertEqual(detail.configuredAt, now)
        XCTAssertEqual(detail.note, "股六债四")
    }

    // MARK: - 模板选择(D000 来源二 + Agent 只能推荐)

    func testTemplateSelectionCarriesVersionAndAgentFlag() throws {
        let target = try policy.applyTemplateSelection(
            templateID: "xiaolei-si000192", catalog: sampleCatalog,
            now: now, viaAgentRecommendation: true
        )
        guard case .userSelectedTemplate(let detail) = target.provenance else {
            return XCTFail("provenance 必须是 userSelectedTemplate")
        }
        XCTAssertEqual(detail.templateID, "xiaolei-si000192")
        XCTAssertEqual(detail.templateVersion, "v3")
        XCTAssertTrue(detail.recommendedByAgent, "Agent 推荐被标注,但写入语义仍是用户选择")

        XCTAssertEqual(target.entries.count, 3)
        XCTAssertEqual(target.targetWeight(for: .equity)?.value, Decimal(string: "0.8"))
    }

    func testUnknownTemplateRejected() {
        XCTAssertThrowsError(
            try policy.applyTemplateSelection(
                templateID: "agent-invented", catalog: sampleCatalog,
                now: now, viaAgentRecommendation: true
            )
        ) { error in
            XCTAssertEqual(
                error as? StrategicAllocationPolicy.PolicyError,
                .unknownTemplate(templateID: "agent-invented"),
                "Agent 不能凭空生成模板(目录外拒收)"
            )
        }
    }

    func testInvalidTemplateEntriesRejected() {
        let badCatalog = AllocationTemplateCatalog(templates: [
            .init(id: "bad", version: "v1", displayName: "坏模板",
                  entries: [entry(.equity, "0.9")]),  // 和 0.9 ≠ 1
        ])
        XCTAssertThrowsError(
            try policy.applyTemplateSelection(
                templateID: "bad", catalog: badCatalog, now: now, viaAgentRecommendation: false
            )
        ) { error in
            XCTAssertEqual(
                error as? StrategicAllocationPolicy.PolicyError,
                .templateEntriesInvalid(templateID: "bad")
            )
        }
    }

    // MARK: - Validator 门禁(D000 §Decision 4)

    func testValidatorRejectsBadShapes() {
        // 空
        XCTAssertThrowsError(try policy.applyUserAllocation(entries: [], note: nil, now: now)) { error in
            XCTAssertEqual(
                (error as? StrategicAllocationPolicy.PolicyError),
                .invalidEntries(.emptyEntries)
            )
        }
        // 权重和 ≠ 1(不允许「剩余配 cash」隐式行为)
        XCTAssertThrowsError(
            try policy.applyUserAllocation(entries: [entry(.equity, "0.6"), entry(.fixedIncome, "0.3")], note: nil, now: now)
        ) { error in
            guard case .invalidEntries(let inner) = error as? StrategicAllocationPolicy.PolicyError else {
                return XCTFail()
            }
            guard case .weightsDoNotSumToOne(let sum) = inner else { return XCTFail() }
            XCTAssertEqual(sum, Decimal(string: "0.9"))
        }
        // 负权重
        XCTAssertThrowsError(
            try policy.applyUserAllocation(entries: [entry(.equity, "1.2"), entry(.cash, "-0.2")], note: nil, now: now)
        )
        // 重复资产类
        XCTAssertThrowsError(
            try policy.applyUserAllocation(entries: [entry(.equity, "0.5"), entry(.equity, "0.5")], note: nil, now: now)
        ) { error in
            guard case .invalidEntries(let inner) = error as? StrategicAllocationPolicy.PolicyError else {
                return XCTFail()
            }
            guard case .duplicateAssetClass = inner else { return XCTFail() }
        }
    }

    // MARK: - Signal 不能改 Target(D000 Cardinal Firewall,类型层)

    func testTargetCannotBeConstructedFromSignals_typeLevel() throws {
        // AllocationTarget 的构造入口只有 policy 的两个 apply 方法——
        // 用 Mirror 反射验证 AllocationTarget 的字段里没有任何
        // Signal / RiskProfile / Exposure 类型,也不存在 setter。
        let target = try policy.applyUserAllocation(
            entries: [entry(.equity, "1.0")], note: nil, now: now
        )
        let labels = Mirror(reflecting: target).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), ["id", "entries", "provenance", "createdAt"])
        // StrategicAllocationPolicy 的公开方法签名不含任何 Signal 输入
        // (D000:信号只能影响 Δw 与 Criterion)——由编译器保证,此处存档说明。
        XCTAssertTrue(true)
    }

    func testMemberwiseInitSuppressed_constructionOnlyViaPolicy() throws {
        // 审查 P1-7 回归:AllocationTarget 的 memberwise init 被 fileprivate
        // 抑制——同文件 Policy 是唯一构造入口,模块内无法绕过
        // (编译期保证:以下写法无法编译,此处以 API 表面存档)
        let target = try policy.applyUserAllocation(
            entries: [entry(.equity, "1.0")], note: nil, now: now
        )
        // 解码是第二入口:走校验式 init(from:)
        let data = try JSONEncoder().encode(target)
        XCTAssertNoThrow(try JSONDecoder().decode(AllocationTarget.self, from: data))
    }

    func testDecodedTargetNormalizesEntryOrder() throws {
        // 十轮 P3 回归:乱序 JSON(同 id、同内容,entries 顺序不同)解出
        // 的 Target 必须与构造路径产物 ==(同 id 必同形态;修复前数组序
        // 参与 Hashable → 同 id 双形态)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let target = try StrategicAllocationPolicy().applyUserAllocation(
            entries: [
                AllocationTargetEntry(assetClass: .equity, targetWeight: Ratio(value: Decimal(string: "0.6")!)),
                AllocationTargetEntry(assetClass: .cash, targetWeight: Ratio(value: Decimal(string: "0.4")!)),
            ],
            note: nil, now: now
        )
        // 构造乱序 JSON:经中性 Codable 中转结构反转 entries 数组
        struct Wire: Codable {
            var id: InvestmentTargetID
            var entries: [AllocationTargetEntry]
            var provenance: TargetAllocationProvenance
            var createdAt: Date
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let wire = try decoder.decode(Wire.self, from: encoder.encode(target))
        let shuffled = Wire(
            id: wire.id, entries: wire.entries.reversed(),
            provenance: wire.provenance, createdAt: wire.createdAt
        )
        let decoded = try decoder.decode(AllocationTarget.self, from: encoder.encode(shuffled))
        XCTAssertEqual(decoded.id, target.id, "ID 派生内部归一化,乱序 JSON 本就通过核对")
        XCTAssertEqual(decoded, target, "解码归一化后同 id 必同形态(修复前 != )")
    }

    func testDecodingRejectsInvalidWeights() throws {
        // 审查 P1-7 回归:脏 JSON(权重和≠1)在解码点拒绝(fail-closed)
        let target = try policy.applyUserAllocation(
            entries: [entry(.equity, "0.6"), entry(.cash, "0.4")], note: nil, now: now
        )
        // 用中间表示篡改权重后重新编码
        struct RawTarget: Codable {
            let id: InvestmentTargetID
            let entries: [AllocationTargetEntry]
            let provenance: TargetAllocationProvenance
            let createdAt: Date
        }
        let raw = RawTarget(
            id: target.id,
            entries: [entry(.equity, "0.9")],   // 和 0.9 ≠ 1
            provenance: target.provenance,
            createdAt: target.createdAt
        )
        let dirty = try JSONEncoder().encode(raw)
        XCTAssertThrowsError(try JSONDecoder().decode(AllocationTarget.self, from: dirty)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("应为 dataCorrupted,实际 \(error)")
            }
        }
    }

    func testDecodingRejectsForgedID() throws {
        // 二轮审查 P1-4 回归:改内容保旧 ID 的「伪造 Target」在解码点拒绝
        struct RawTarget: Codable {
            let id: InvestmentTargetID
            let entries: [AllocationTargetEntry]
            let provenance: TargetAllocationProvenance
            let createdAt: Date
        }
        let original = try policy.applyUserAllocation(
            entries: [entry(.equity, "0.6"), entry(.cash, "0.4")], note: nil, now: now
        )
        let forged = RawTarget(
            id: original.id,   // 保留旧 ID
            entries: [entry(.equity, "0.7"), entry(.cash, "0.3")],   // 换内容(仍合法权重)
            provenance: original.provenance,
            createdAt: original.createdAt
        )
        let dirty = try JSONEncoder().encode(forged)
        XCTAssertThrowsError(try JSONDecoder().decode(AllocationTarget.self, from: dirty)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("应为 dataCorrupted,实际 \(error)")
            }
        }
    }

    func testDeterministicIdAndCodable() throws {
        let a = try policy.applyUserAllocation(
            entries: [entry(.equity, "0.6"), entry(.fixedIncome, "0.4")], note: nil, now: now
        )
        let b = try policy.applyUserAllocation(
            entries: [entry(.fixedIncome, "0.4"), entry(.equity, "0.6")], note: nil, now: now
        )
        XCTAssertEqual(a.id, b.id, "同 provenance+时间+内容(顺序无关归一) → 同 id")

        // Codable round-trip(provenance 关联值保留)
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(AllocationTarget.self, from: data)
        XCTAssertEqual(decoded, a)

        // 模板 provenance round-trip
        let template = try policy.applyTemplateSelection(
            templateID: "xiaolei-si000192", catalog: sampleCatalog,
            now: now, viaAgentRecommendation: false
        )
        let templateData = try JSONEncoder().encode(template)
        let decodedTemplate = try JSONDecoder().decode(AllocationTarget.self, from: templateData)
        XCTAssertEqual(decodedTemplate, template)
    }
}
