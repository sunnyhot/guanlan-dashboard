import Foundation

// 决策事项指标快照(Schema V2)。
//
// 每次重新评估 Case 时追加一条快照,记录当时的真实指标值。
// 复盘时比较 baselineMetricSnapshot 和当前快照。
// 数据不足时 value=nil(不是 0)。

struct DecisionCaseMetricSnapshot: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let caseID: UUID
    let recordedAt: String
    let metric: DecisionMetricIdentifier
    /// 真实指标值。nil = 数据不足(不是 0)。
    let value: Double?
    let unit: DecisionMetricUnit
    let dataAsOf: String
    /// 穿透覆盖率(如果适用)。
    let coverage: Double?
    let evidenceIDs: [String]
    /// 数据不足时的原因。
    let unavailableReason: String?

    init(
        id: UUID = UUID(),
        caseID: UUID,
        recordedAt: String,
        metric: DecisionMetricIdentifier,
        value: Double?,
        unit: DecisionMetricUnit,
        dataAsOf: String,
        coverage: Double? = nil,
        evidenceIDs: [String] = [],
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.caseID = caseID
        self.recordedAt = recordedAt
        self.metric = metric
        self.value = value
        self.unit = unit
        self.dataAsOf = dataAsOf
        self.coverage = coverage
        self.evidenceIDs = evidenceIDs
        self.unavailableReason = unavailableReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        caseID = try c.decode(UUID.self, forKey: .caseID)
        recordedAt = try c.decodeIfPresent(String.self, forKey: .recordedAt) ?? ""
        metric = try c.decodeIfPresent(DecisionMetricIdentifier.self, forKey: .metric) ?? .directHoldingWeight
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        unit = try c.decodeIfPresent(DecisionMetricUnit.self, forKey: .unit) ?? .percent
        dataAsOf = try c.decodeIfPresent(String.self, forKey: .dataAsOf) ?? ""
        coverage = try c.decodeIfPresent(Double.self, forKey: .coverage)
        evidenceIDs = try c.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason)
    }
}
