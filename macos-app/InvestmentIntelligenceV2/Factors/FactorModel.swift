import Foundation

// MARK: - Factor 模型（FAC-1，Epic 7）
//
// 铁律（rollout §Epic 7）：每个 factor 返回 metric（Decimal + unit），不返回分数；
// ordinal signal 由独立 SignalPolicy（FAC-2）产生。
//
// PIT 语义：FactorSnapshot 以 economicKnowledge(asOf:) 读取输入序列——
// 只有 availableAt ≤ asOf 的观测参与计算（ADR-DATA002）。历史重算 = 用旧 asOf
// 重跑引擎，得到 byte-identical 的 snapshot（同输入同输出，D002 确定性）。
//
// 缺口语义（ADR-DATA006）：输入 bar 数不足 metric 声明的 minimumBars 时，
// value = nil + insufficiency 说明，不猜、不填 0。

/// 因子数值单位（强类型，禁止裸 Decimal 隐式约定单位）。
enum FactorUnit: String, Sendable, Codable, Hashable {
    /// 无量纲比率（0.05 = 5%）：closeVsMA20、区间收益、回撤等
    case ratio = "RATIO"
    /// 每日比率量（日频波动率、MA 日斜率）
    case ratioPerDay = "RATIO_PER_DAY"
}

/// versioned 因子定义（D002 精神：公式 / 参数可审计、历史可重放）。
///
/// 公式或参数变更必须 bump `version`：老 version 的历史 snapshot 引用老定义，
/// 重放时不受新公式影响（与 CriterionDefinition / SignalPolicy 同一套 provenance 纪律）。
struct FactorDefinition: Sendable, Codable, Hashable {
    /// 稳定 key（如 "trend.closeVsMA20" / "momentum.return60"）
    let key: String
    /// 定义版本（"v1"）
    let version: String
    let unit: FactorUnit
    /// 显式参数（窗口长度 / slope horizon / benchmark 标的），全部可审计
    let parameters: [Parameter]

    init(key: String, version: String, unit: FactorUnit, parameters: [Parameter] = []) {
        self.key = key
        self.version = version
        self.unit = unit
        self.parameters = parameters
    }

    /// 单个定义参数（值统一存字符串：bar 数、ListingID、horizon 都可表达）。
    struct Parameter: Sendable, Codable, Hashable {
        let name: String
        let value: String

        init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        init(name: String, intValue: Int) {
            self.name = name
            self.value = String(intValue)
        }

        var intValue: Int? { Int(value) }
    }

    /// 定义指纹（进引擎 factorVersion 与 snapshot id）。
    ///
    /// 十一轮 P2-2：参数纳入指纹——「参数变更必须 bump version」不再只是
    /// 纪律：同 key@version 不同参数（window / benchmark / horizon）在指纹
    /// 层即分裂，同快照 ID 下混入不同数学的通道关闭（对照八轮 P1-4
    /// criterion 的 contentDigest——同一类缺口）。无参数定义保持纯
    /// `key@version`（与既有形态兼容）。
    var fingerprint: String {
        guard !parameters.isEmpty else { return "\(key)@\(version)" }
        // 参数规范化：按 (name, value) 排序后 JSON 摘要（确定性类型的
        // 编码失败 = 编程错误，fail-fast）
        let canonical = try! StableDigest.jsonPayload(
            parameters.sorted { ($0.name, $0.value) < ($1.name, $1.value) }
        )
        return "\(key)@\(version)@\(StableDigest.digest(canonical))"
    }
}

/// 单个因子的计算产出（metric = Decimal + unit，不是分数）。
struct FactorMetric: Sendable, Codable, Hashable {
    /// metric 值的统一舍入位数（消除除法展开尾差，golden 值跨运行稳定）
    static let metricScale = 12

    let definition: FactorDefinition
    /// 计算值（已按 metricScale 舍入）。nil = 输入不足（不猜，ADR-DATA006）
    let value: Decimal?
    /// value == nil 时的不足说明；value != nil 时必须为 nil
    let insufficiency: Insufficiency?

    init(definition: FactorDefinition, value: Decimal) {
        self.definition = definition
        self.value = value.rounded(toScale: Self.metricScale)
        self.insufficiency = nil
    }

    init(definition: FactorDefinition, insufficiency: Insufficiency) {
        self.definition = definition
        self.value = nil
        self.insufficiency = insufficiency
    }

    /// 输入不足的结构化说明。
    struct Insufficiency: Sendable, Codable, Hashable {
        let reason: Reason
        /// 该 metric 要求的最少 bar 数（能确定时；benchmarkMissing 时为 nil）
        let requiredBars: Int?
        /// 实际可用 bar 数
        let actualBars: Int

        enum Reason: String, Sendable, Codable, Hashable {
            case emptySeries = "EMPTY_SERIES"
            case insufficientBars = "INSUFFICIENT_BARS"
            case benchmarkMissing = "BENCHMARK_MISSING"
        }
    }
}

// MARK: - 计算输入（PIT 过滤后的复权收盘序列）

/// 单个时点的复权收盘（factor 计算的原子输入）。
///
/// adjustedClose = rawClose × adjustmentFactor（ADR-DATA003 §Decision 2：
/// raw + adjustment 分离存储，查询时按 vintage 拼装）。fxRate 刻意不参与——
/// 因子全部是同一 Listing 自身的时序比率，恒定货币假设下汇率约掉。
struct AdjustedClosePoint: Sendable, Codable, Hashable {
    let observationID: ObservationID
    let effectiveAt: Date
    let adjustedClose: Decimal
}

/// 一次因子计算的全部输入序列。
struct FactorInputs: Sendable, Hashable {
    /// 主标的（asset）序列，升序、每日一条（economicKnowledge 输出语义）
    let assetSeries: [AdjustedClosePoint]
    /// benchmark 序列（RelativeStrength 用；其他 calculator 忽略）
    let benchmarkSeries: [AdjustedClosePoint]

    init(assetSeries: [AdjustedClosePoint], benchmarkSeries: [AdjustedClosePoint] = []) {
        self.assetSeries = assetSeries
        self.benchmarkSeries = benchmarkSeries
    }
}

/// 因子计算器协议（FAC-3..7 的统一接口）。
///
/// 实现要求：纯函数——同 inputs 必产同 metrics（D002 确定性）；不读全局状态、
/// 不做 IO；数据不足时产 nil metric + insufficiency，不抛错（缺口是正常业务态）。
protocol FactorCalculator: Sendable {
    /// 本 calculator 产出的全部 metric 定义（顺序稳定，进 snapshot 的 metrics 序）
    var definitions: [FactorDefinition] { get }
    func compute(inputs: FactorInputs) -> [FactorMetric]
}

/// DailyBar 序列 → 复权收盘点序列的提取（升序保证在此处收口）。
enum FactorSeries {
    /// 输入应为 Repository economicKnowledge 输出（每日一条）；
    /// 此处仍按 effectiveAt 再排一次序并去重（同 effectiveAt 取 observationID 字典序最小），
    /// 保证对任意输入顺序都产出确定序列。
    static func adjustedCloseSeries(from bars: [DailyBar]) -> [AdjustedClosePoint] {
        let byDay = Dictionary(grouping: bars, by: { $0.temporalEnvelope.effectiveAt })
        return byDay
            .compactMap { _, sameDay -> AdjustedClosePoint? in
                guard let bar = sameDay.min(by: {
                    $0.id.rawValue < $1.id.rawValue
                }) else { return nil }
                return AdjustedClosePoint(
                    observationID: bar.id,
                    effectiveAt: bar.temporalEnvelope.effectiveAt,
                    adjustedClose: bar.rawClose.value * bar.adjustmentFactor
                )
            }
            .sorted { $0.effectiveAt < $1.effectiveAt }
    }
}

// MARK: - FactorSnapshot（Artifact，FAC-1）

/// 输入序列覆盖情况（透明记录实际用了多少 bar，下游据此判断可信度）。
struct FactorInputCoverage: Sendable, Codable, Hashable {
    let barCount: Int
    let firstEffectiveAt: Date?
    let lastEffectiveAt: Date?

    init(series: [AdjustedClosePoint]) {
        self.barCount = series.count
        self.firstEffectiveAt = series.first?.effectiveAt
        self.lastEffectiveAt = series.last?.effectiveAt
    }
}

/// 一次因子计算的完整产出（FAC-1）。
///
/// provenance 三件套：
/// - `sourceObservationIDs`：参与计算的全部 observation（重放取数依据，D004）
/// - `factorVersion`：引擎指纹（全部 definition key@version 的 SHA256 前缀）
/// - `asOf`：PIT 锚点（序列以 economicKnowledge(asOf:) 读取）
///
/// 历史 Factor 可重算：同 repository 状态 + 同 asOf + 同引擎 → 同 snapshot
/// （id 确定性派生，重算幂等覆盖）。
struct FactorSnapshot: Artifact {
    let id: FactorSnapshotID
    let producedAt: Date
    /// 行情观测修订 / 新 bar 到达即失效（dependencies 粒度精确到 observation）
    let validityPolicy: ValidityPolicy
    /// 每个源 observation 一个 .observation 依赖（由 sourceObservationIDs 派生）
    let dependencies: [ArtifactDependency]

    let listingID: ListingID
    /// PIT 锚点
    let asOf: Date
    /// 引擎指纹（definition 变更 → 指纹变化 → 旧 snapshot 失效重算）
    let factorVersion: String
    /// 全部 calculator 的 metric，definition 顺序稳定
    let metrics: [FactorMetric]
    /// 参与计算的 observation IDs（asset + benchmark，按 effectiveAt 排序去重）
    let sourceObservationIDs: [ObservationID]
    let assetCoverage: FactorInputCoverage
    /// benchmark 输入覆盖（未指定 benchmark 时为 nil）
    let benchmarkCoverage: FactorInputCoverage?

    init(
        id: FactorSnapshotID,
        producedAt: Date,
        listingID: ListingID,
        asOf: Date,
        factorVersion: String,
        metrics: [FactorMetric],
        sourceObservationIDs: [ObservationID],
        assetSeries: [AdjustedClosePoint],
        benchmarkSeries: [AdjustedClosePoint]?
    ) {
        self.id = id
        self.producedAt = producedAt
        self.validityPolicy = .untilDependencyChanges
        self.dependencies = sourceObservationIDs.map {
            ArtifactDependency(kind: .observation, referenceID: $0.rawValue)
        }
        self.listingID = listingID
        self.asOf = asOf
        self.factorVersion = factorVersion
        self.metrics = metrics
        self.sourceObservationIDs = sourceObservationIDs
        self.assetCoverage = FactorInputCoverage(series: assetSeries)
        self.benchmarkCoverage = benchmarkSeries.map { FactorInputCoverage(series: $0) }
    }
}

// MARK: - FactorEngine（从 Repository 取数并跑全部 calculator）

/// 因子引擎：PIT 读数 → 跑全部 calculator → 产出 FactorSnapshot。
struct FactorEngine: Sendable {
    let calculators: [any FactorCalculator]

    init(calculators: [any FactorCalculator]) {
        self.calculators = calculators
    }

    /// 引擎版本指纹：全部 definition 的 fingerprint（key@version[@参数摘要]，
    /// 十一轮 P2-2）排序拼接后的确定性摘要。新增因子 / version bump /
    /// **参数值变更**都会改变指纹——参数已纳入 definition.fingerprint
    /// （修正原「参数在 definition 内即改变指纹」的注释与实现矛盾：
    /// fingerprint 原本只有 key@version，参数变更若不 bump version 则
    /// 指纹不变）。
    var factorVersion: String {
        let joined = calculators
            .flatMap { $0.definitions.map(\.fingerprint) }
            .sorted()
            .joined(separator: "|")
        return Self.shortDigest(joined)
    }

    /// 计算 listing 在 asOf 时点的因子快照。
    ///
    /// - benchmarkListingID：显式 benchmark（FAC-7 要求 benchmark 必须显式声明，
    ///   不允许隐式默认）；nil 时 RelativeStrength 产 benchmarkMissing。
    /// - producedAt：产出时间（重放时可传历史时间保持 byte-identical）。
    func snapshot(
        listingID: ListingID,
        asOf: Date,
        repository: any MarketTimeSeriesRepository,
        benchmarkListingID: ListingID? = nil,
        producedAt: Date
    ) -> FactorSnapshot {
        let context = KnowledgeContext.economicKnowledge(asOf: asOf)
        let assetBars = repository.dailyBars(listingID: listingID, context: context)
        let benchmarkBars = benchmarkListingID.map {
            repository.dailyBars(listingID: $0, context: context)
        } ?? []

        let inputs = FactorInputs(
            assetSeries: FactorSeries.adjustedCloseSeries(from: assetBars),
            benchmarkSeries: FactorSeries.adjustedCloseSeries(from: benchmarkBars)
        )
        let metrics = calculators.flatMap { $0.compute(inputs: inputs) }

        let sourceIDs = Self.sourceObservationIDs(assetBars: assetBars, benchmarkBars: benchmarkBars)
        return FactorSnapshot(
            id: Self.deterministicID(
                listingID: listingID,
                asOf: asOf,
                benchmarkListingID: benchmarkListingID,
                factorVersion: factorVersion,
                sourceObservationIDs: sourceIDs
            ),
            producedAt: producedAt,
            listingID: listingID,
            asOf: asOf,
            factorVersion: factorVersion,
            metrics: metrics,
            sourceObservationIDs: sourceIDs,
            assetSeries: inputs.assetSeries,
            benchmarkSeries: benchmarkListingID == nil ? nil : inputs.benchmarkSeries
        )
    }

    /// 参与计算的 observation IDs：asset + benchmark，按 (effectiveAt, rawValue) 排序去重。
    private static func sourceObservationIDs(assetBars: [DailyBar], benchmarkBars: [DailyBar]) -> [ObservationID] {
        let keyed = (assetBars + benchmarkBars).map { bar in
            (bar.temporalEnvelope.effectiveAt, bar.id.rawValue, bar.id)
        }
        var seen = Set<String>()
        return keyed
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1 < rhs.1
            }
            .filter { seen.insert($0.1).inserted }
            .map(\.2)
    }

    /// snapshot id 确定性派生：listing + asOf + benchmark + 引擎指纹 +
    /// **参与计算的 observation 身份**（十一轮 P2-1：修订场景下同 asOf 重算
    /// 的快照内容不同（metrics / sourceObservationIDs 变化），ID 必须分裂
    /// ——否则 ArtifactRow.write 幂等比对对语义应为 untilDependencyChanges
    /// supersede 的修订误报 conflict；与 ExposureReport 二轮 P1-7 同款收口）
    /// → 摘要前 24 hex。同输入同 id（重算幂等覆盖）；asOf / benchmark /
    /// 引擎 / 源 observation 任一变化 → 新 id。
    ///
    /// 十二轮 P3：`sourceObservationIDs` **无默认值**——省略会让 ID 静默
    /// 退回四元组形态（修订不分裂 ID、写入 conflict 而非 supersede），
    /// 关键身份参数必须显式传入。
    static func deterministicID(
        listingID: ListingID,
        asOf: Date,
        benchmarkListingID: ListingID?,
        factorVersion: String,
        sourceObservationIDs: [ObservationID]
    ) -> FactorSnapshotID {
        let millis = Int(asOf.timeIntervalSince1970 * 1000)
        let sources = sourceObservationIDs.map(\.rawValue).sorted().joined(separator: ",")
        let canonical = "factor-snapshot|\(listingID.rawValue)|\(millis)|\(benchmarkListingID?.rawValue ?? "-")|\(factorVersion)|\(sources)"
        return FactorSnapshotID(rawValue: "fs_\(shortDigest(canonical))")
    }

    /// 双 FNV-1a 64 位组合的确定性摘要（128 bit hex）。
    /// 只需防意外漂移（同输入必同输出），不防恶意碰撞，无需密码学哈希。
    private static func shortDigest(_ input: String) -> String {
        let data = Data(input.utf8)
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for byte in data {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(byte)) &* 0xbf58476d1ce4e5b9
        }
        return String(format: "%016lx%016lx", h1, h2)
    }
}

// MARK: - Decimal 舍入 helper（模块内共享）

extension Decimal {
    /// 四舍五入到指定小数位（消除除法展开尾差，golden 值稳定）。
    func rounded(toScale scale: Int) -> Decimal {
        var result = self
        var raw = self
        NSDecimalRound(&result, &raw, scale, .plain)
        return result
    }

    /// 平方根（牛顿迭代；Foundation Decimal 无 squareRoot）。
    ///
    /// Double 初值（IEEE 754 sqrt 正确舍入，确定性）+ Decimal 牛顿精化
    /// 到全精度——二次收敛下 5 次迭代从 1e-16 相对误差到 38 位精度上限。
    /// 输入 ≤ 0（方差非负，负数属上游 bug）返回 0。
    func decimalSquareRoot() -> Decimal {
        guard self > 0 else { return .zero }
        let initial = (self as NSDecimalNumber).doubleValue.squareRoot()
        var y = Decimal(initial)
        for _ in 0..<5 {
            let next = (y + self / y) / 2
            if next == y { break }
            y = next
        }
        return y
    }
}
