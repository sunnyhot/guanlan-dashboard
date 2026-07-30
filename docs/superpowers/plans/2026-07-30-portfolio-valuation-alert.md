# 持仓估值目标预警 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为「我的持仓」标的添加「估值达到目标值时发系统通知提醒卖出/加仓」能力（不含自动下单）。

**Architecture:** 独立新模块（方案 A）。新建数据模型、纯函数评估器、持久化 Store、AppModel 子逻辑；评估挂在现有持仓 60s 自动刷新循环末尾（零新增定时器）；详情抽屉新增预警区块 + 编辑 sheet；设置中心新增第 5 个面板。涨跌色用 AppPalette（红涨绿跌）。

**Tech Stack:** SwiftUI + Foundation (macOS 14+), XCTest。

## Global Constraints

- **纯 Swift 运行时**，不依赖 Python/localhost。
- **红涨绿跌**：所有涨跌颜色用 AppPalette（marketGain/marketLoss）。
- **@MainActor + ObservableObject**：AppModel 是单一状态容器。
- **新建 Swift 文件无需更新 `scripts/build_qieman_cli.sh`**（本功能纯 App，不涉及 CLI；SPM 自动发现源文件）。
- **测试基线**：`macos-app/` 目录 `swift test` 全绿。
- 浮点容差 `1e-9`，与现有 `PersonalWatchlistAlertEvaluator` 一致。
- 数据缺失（估值/净值/收益率为 nil）时**保持 breached 状态不解除**（与现有 watchlist 行为一致，避免行情闪烁导致误解除）。

---

## File Structure

**新建（8 个）：**
| 文件 | 职责 |
|---|---|
| `macos-app/Core/Models/PortfolioValuationAlert.swift` | 数据模型（metric/side/direction/rule/profile/settings） |
| `macos-app/Core/PortfolioValuationAlertEvaluator.swift` | 纯函数评估器 + 文案 describe |
| `macos-app/Core/PortfolioValuationAlertStore.swift` | 持久化（profiles + settings JSON） |
| `macos-app/Core/AppModel/PortfolioValuationAlertActions.swift` | AppModel 子逻辑（评估+发通知+CRUD）。注：命名用 `*Actions.swift` 而非 `PortfolioValuationAlert.swift`，因 `Core/Models/PortfolioValuationAlert.swift` 已占同名 basename，SPM 报 multiple producers |
| `macos-app/Views/PersonalAsset/PortfolioValuationAlertSection.swift` | 详情抽屉预警区块 |
| `macos-app/Views/PersonalAsset/PortfolioValuationAlertEditSheet.swift` | 预警编辑 sheet |
| `macos-app/Views/SettingsValuationAlertPanel.swift` | 设置中心面板 |
| `macos-app/Tests/QiemanDashboardTests/PortfolioValuationAlertTests.swift` | 纯函数测试 |

**改动（6 个）：**
| 文件 | 改动 |
|---|---|
| `macos-app/Core/AppModel.swift` | 实例化 store + settings；`start()` 加载；不加新循环 |
| `macos-app/Core/AppModel/ComputedProperties.swift` | 新增 fileURL 计算属性 |
| `macos-app/Core/AppModel/PortfolioRefresh.swift` | `refreshPortfolioIfAutoRefreshVisible` 末尾挂评估 |
| `macos-app/Core/AppModel/PortfolioCRUD.swift` | 删除持仓时联动清理 store |
| `macos-app/Core/Models/ManagerWatchSettings.swift` | 通知深链新增 `.portfolioValuationAlert` case + 解析 |
| `macos-app/Core/AppModel/ManagerWatch.swift` | 深链 handler 新增 case |
| `macos-app/Views/PersonalAsset/PersonalAssetDetailSheet.swift` | 插入预警区块 |
| `macos-app/Views/SettingsSectionView.swift` | `SettingsFocus` 新增 case + 状态/面板接入 |

---

## Task 1: 数据模型

**Files:**
- Create: `macos-app/Core/Models/PortfolioValuationAlert.swift`

**Interfaces:**
- Produces: `PortfolioValuationAlertMetric`, `PortfolioValuationAlertSide`, `PortfolioValuationAlertDirection`, `PortfolioValuationAlertRule`, `PortfolioValuationAlertProfile`, `PortfolioValuationAlertSettings`

- [ ] **Step 1: 创建模型文件**

Create `macos-app/Core/Models/PortfolioValuationAlert.swift`:

```swift
import Foundation

/// 估值预警触发维度
enum PortfolioValuationAlertMetric: String, Codable, CaseIterable {
    /// 持有收益率（止盈/止损）
    case holdingProfitPct
    /// 盘中估算涨跌幅
    case estimateChangePct
    /// 盘中估算净值绝对值（仅基金有意义）
    case estimatePrice

    var displayName: String {
        switch self {
        case .holdingProfitPct: return "持有收益率"
        case .estimateChangePct: return "盘中估算涨跌"
        case .estimatePrice: return "估算净值"
        }
    }

    var unit: String {
        switch self {
        case .holdingProfitPct, .estimateChangePct: return "%"
        case .estimatePrice: return ""
        }
    }

    /// 股票不支持估算净值维度
    var appliesToStock: Bool {
        self != .estimatePrice
    }
}

/// 买卖方向（用户配规则时选，决定通知文案）
enum PortfolioValuationAlertSide: String, Codable, CaseIterable {
    /// 提醒卖出（止盈/高位）
    case sell
    /// 提醒加仓（止损/低位）
    case buy

    var displayName: String {
        switch self {
        case .sell: return "提醒卖出"
        case .buy: return "提醒加仓"
        }
    }
}

/// 比较方向
enum PortfolioValuationAlertDirection: String, Codable, CaseIterable {
    /// 上穿 >= 阈值
    case above
    /// 下穿 <= 阈值
    case below

    var displayName: String {
        switch self {
        case .above: return "达到或高于"
        case .below: return "跌到或低于"
        }
    }
}

/// 单条预警规则
struct PortfolioValuationAlertRule: Codable, Identifiable, Equatable {
    let id: UUID
    var metric: PortfolioValuationAlertMetric
    var side: PortfolioValuationAlertSide
    var direction: PortfolioValuationAlertDirection
    /// 收益率/涨跌幅为百分点数字（20 = 20%）；估算净值为绝对值
    var threshold: Double
    var note: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        metric: PortfolioValuationAlertMetric,
        side: PortfolioValuationAlertSide,
        direction: PortfolioValuationAlertDirection,
        threshold: Double,
        note: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.metric = metric
        self.side = side
        self.direction = direction
        self.threshold = threshold
        self.note = note
        self.isEnabled = isEnabled
    }
}

/// 一只标的的全部规则 + 去重状态
struct PortfolioValuationAlertProfile: Codable, Equatable {
    let fundCode: String
    var rules: [PortfolioValuationAlertRule]
    /// 当前已触发未回落的规则 id（滞回去重）
    var breachedRuleIDs: Set<UUID>
    /// 每条规则上次触发时间（ISO 字符串）
    var lastTriggeredAt: [UUID: String]

    init(
        fundCode: String,
        rules: [PortfolioValuationAlertRule] = [],
        breachedRuleIDs: Set<UUID> = [],
        lastTriggeredAt: [UUID: String] = [:]
    ) {
        self.fundCode = fundCode
        self.rules = rules
        self.breachedRuleIDs = breachedRuleIDs
        self.lastTriggeredAt = lastTriggeredAt
    }

    /// 存在任意启用规则
    var hasActiveRules: Bool {
        rules.contains { $0.isEnabled }
    }

    /// 当前是否有规则处于已触发态
    var isCurrentlyBreached: Bool {
        !breachedRuleIDs.isEmpty
    }
}

/// 全局设置
struct PortfolioValuationAlertSettings: Codable, Equatable {
    var isEnabled: Bool

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED（新文件被 SPM 自动发现）。

- [ ] **Step 3: Commit**

```bash
git add macos-app/Core/Models/PortfolioValuationAlert.swift
git commit -m "feat: 持仓估值预警数据模型"
```

---

## Task 2: 纯函数评估器（TDD）

**Files:**
- Create: `macos-app/Core/PortfolioValuationAlertEvaluator.swift`
- Test: `macos-app/Tests/QiemanDashboardTests/PortfolioValuationAlertTests.swift`

**Interfaces:**
- Consumes: Task 1 的模型
- Produces: `PortfolioValuationAlertContext`, `PortfolioValuationAlertEvaluation`（枚举）, `PortfolioValuationAlertEvaluator.evaluate(...)`、`PortfolioValuationAlertEvaluator.describe(rule:value:)`

- [ ] **Step 1: 写失败测试**

Create `macos-app/Tests/QiemanDashboardTests/PortfolioValuationAlertTests.swift`:

```swift
import Foundation
import XCTest
@testable import QiemanDashboard

final class PortfolioValuationAlertTests: XCTestCase {

    private func makeRule(
        metric: PortfolioValuationAlertMetric = .holdingProfitPct,
        side: PortfolioValuationAlertSide = .sell,
        direction: PortfolioValuationAlertDirection = .above,
        threshold: Double,
        isEnabled: Bool = true
    ) -> PortfolioValuationAlertRule {
        PortfolioValuationAlertRule(
            metric: metric, side: side, direction: direction,
            threshold: threshold, isEnabled: isEnabled
        )
    }

    private func context(
        holdingProfitPct: Double? = nil,
        estimateChangePct: Double? = nil,
        estimatePrice: Double? = nil
    ) -> PortfolioValuationAlertContext {
        PortfolioValuationAlertContext(
            holdingProfitPct: holdingProfitPct,
            estimateChangePct: estimateChangePct,
            estimatePrice: estimatePrice
        )
    }

    // MARK: - 基础触发

    func testFireAbovePositiveThreshold() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 20.5), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .fire)
    }

    func testFireBelowNegativeThreshold() {
        let rule = makeRule(direction: .below, side: .buy, threshold: -10)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: -10.3), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .fire)
    }

    // MARK: - 去重（滞回）

    func testHoldWhenBreachedStillInRange() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 21), isCurrentlyBreached: true)
        XCTAssertEqual(eval, .hold)
    }

    func testFireAgainAfterReturningAndReCrossing() {
        let rule = makeRule(direction: .above, threshold: 20)
        // 第一次达标 → fire
        var lastBreached = false
        let first = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 21), isCurrentlyBreached: lastBreached)
        XCTAssertEqual(first, .fire)
        lastBreached = true
        // 回落离开 → clear
        let回落 = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 18), isCurrentlyBreached: lastBreached)
        XCTAssertEqual(回落, .clear)
        lastBreached = false
        // 再次穿越 → fire
        let again = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 22), isCurrentlyBreached: lastBreached)
        XCTAssertEqual(again, .fire)
    }

    func testClearWhenBreachedLeavesRange() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 15), isCurrentlyBreached: true)
        XCTAssertEqual(eval, .clear)
    }

    // MARK: - 浮点容差

    func testFireBoundaryEpsilon() {
        let rule = makeRule(direction: .above, threshold: 20)
        // 20.0 - 1e-10 仍 >= 20 - 1e-9
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 20.0 - 1e-10), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .fire)
    }

    // MARK: - 数据缺失：保持 breached 状态（不解除）

    func testHoldWhenObservedValueNilAndBreached() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: nil), isCurrentlyBreached: true)
        XCTAssertEqual(eval, .hold)
    }

    func testIdleWhenObservedValueNilAndNotBreached() {
        let rule = makeRule(direction: .above, threshold: 20)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: nil), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .idle)
    }

    // MARK: - 规则禁用

    func testIdleWhenRuleDisabled() {
        let rule = makeRule(direction: .above, threshold: 20, isEnabled: false)
        let eval = PortfolioValuationAlertEvaluator.evaluate(
            rule: rule, context: context(holdingProfitPct: 25), isCurrentlyBreached: false)
        XCTAssertEqual(eval, .idle)
    }

    // MARK: - 文案

    func testDescribeHoldingProfitPctSell() {
        let rule = makeRule(.holdingProfitPct, .sell, .above, threshold: 20)
        let body = PortfolioValuationAlertEvaluator.describe(
            rule: rule, fundName: "易方达蓝筹", fundCode: "005827", observedValue: 20.5)
        XCTAssertTrue(body.contains("易方达蓝筹"), "body 应含基金名：\(body)")
        XCTAssertTrue(body.contains("持有收益率"), "body 应含维度名：\(body)")
        XCTAssertTrue(body.contains("卖出"), "body 应含卖出方向：\(body)")
    }

    func testDescribeEstimatePrice() {
        let rule = makeRule(.estimatePrice, .sell, .above, threshold: 1.5)
        let body = PortfolioValuationAlertEvaluator.describe(
            rule: rule, fundName: "易方达蓝筹", fundCode: "005827", observedValue: 1.512)
        XCTAssertTrue(body.contains("估算净值"), "body 应含估算净值：\(body)")
        XCTAssertTrue(body.contains("1.5"), "body 应含目标阈值：\(body)")
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `cd macos-app && swift test --filter PortfolioValuationAlertTests 2>&1 | tail -15`
Expected: FAIL — 类型/方法未定义（编译错误）。

- [ ] **Step 3: 实现评估器**

Create `macos-app/Core/PortfolioValuationAlertEvaluator.swift`:

```swift
import Foundation

/// 从 UserPortfolioValuationRow 派生的只读估值上下文
struct PortfolioValuationAlertContext: Equatable {
    let holdingProfitPct: Double?
    let estimateChangePct: Double?
    let estimatePrice: Double?

    init(holdingProfitPct: Double?, estimateChangePct: Double?, estimatePrice: Double?) {
        self.holdingProfitPct = holdingProfitPct
        self.estimateChangePct = estimateChangePct
        self.estimatePrice = estimatePrice
    }
}

/// 单条规则的评估结果
enum PortfolioValuationAlertEvaluation: Equatable {
    /// 未 breached 且达标 → 应触发通知
    case fire
    /// 已 breached 仍在区间 → 不重发（去重）
    case hold
    /// 已 breached 但已回落离开 → 解除 breached
    case clear
    /// 未达标且未 breached → 无动作
    case idle
}

enum PortfolioValuationAlertEvaluator {
    /// 浮点比较容差，与 PersonalWatchlistAlertEvaluator 一致
    static let thresholdEpsilon: Double = 1e-9

    /// 评估单条规则本次应如何处理
    static func evaluate(
        rule: PortfolioValuationAlertRule,
        context: PortfolioValuationAlertContext,
        isCurrentlyBreached: Bool
    ) -> PortfolioValuationAlertEvaluation {
        guard rule.isEnabled else { return .idle }

        guard let observedValue = observedValue(for: rule.metric, in: context),
              observedValue.isFinite else {
            // 数据缺失：保持 breached 状态（不解除），避免行情闪烁误解除
            return isCurrentlyBreached ? .hold : .idle
        }

        let inRange: Bool
        switch rule.direction {
        case .above:
            inRange = observedValue >= rule.threshold - thresholdEpsilon
        case .below:
            inRange = observedValue <= rule.threshold + thresholdEpsilon
        }

        if inRange {
            return isCurrentlyBreached ? .hold : .fire
        } else {
            return isCurrentlyBreached ? .clear : .idle
        }
    }

    private static func observedValue(
        for metric: PortfolioValuationAlertMetric,
        in context: PortfolioValuationAlertContext
    ) -> Double? {
        switch metric {
        case .holdingProfitPct: return context.holdingProfitPct
        case .estimateChangePct: return context.estimateChangePct
        case .estimatePrice: return context.estimatePrice
        }
    }

    /// 生成通知正文文案
    static func describe(
        rule: PortfolioValuationAlertRule,
        fundName: String,
        fundCode: String,
        observedValue: Double?
    ) -> String {
        let nameText = "\(fundName)(\(fundCode))"
        let sideText = rule.side == .sell ? "可考虑卖出" : "可考虑加仓"
        let metricName = rule.metric.displayName
        let thresholdText = formatThreshold(rule)

        if let observedValue, observedValue.isFinite {
            let valueText = formatValue(observedValue, metric: rule.metric)
            switch rule.metric {
            case .holdingProfitPct:
                return "\(nameText) 持有收益率达 \(valueText)，超过 \(thresholdText) 目标，\(sideText)"
            case .estimateChangePct:
                return "\(nameText) 盘中估算涨跌 \(valueText)，超过 \(thresholdText) 目标"
            case .estimatePrice:
                return "\(nameText) 估算净值 \(valueText)，超过 \(thresholdText) 目标，\(sideText)"
            }
        } else {
            return "\(nameText) \(metricName)\(rule.direction == .above ? "达到" : "跌破") \(thresholdText) 目标，\(sideText)"
        }
    }

    private static func formatValue(_ value: Double, metric: PortfolioValuationAlertMetric) -> String {
        switch metric {
        case .holdingProfitPct, .estimateChangePct:
            return "\(value >= 0 ? "+" : "")\(String(format: "%.2f", value))%"
        case .estimatePrice:
            return String(format: "%.4f", value)
        }
    }

    private static func formatThreshold(_ rule: PortfolioValuationAlertRule) -> String {
        switch rule.metric {
        case .holdingProfitPct, .estimateChangePct:
            return "\(rule.threshold >= 0 ? "+" : "")\(String(format: "%.2f", rule.threshold))%"
        case .estimatePrice:
            return String(format: "%.4f", rule.threshold)
        }
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `cd macos-app && swift test --filter PortfolioValuationAlertTests 2>&1 | tail -15`
Expected: 全部 PASS（11 个测试）。

- [ ] **Step 5: Commit**

```bash
git add macos-app/Core/PortfolioValuationAlertEvaluator.swift macos-app/Tests/QiemanDashboardTests/PortfolioValuationAlertTests.swift
git commit -m "feat: 持仓估值预警纯函数评估器与文案生成"
```

---

## Task 3: 持久化 Store

**Files:**
- Create: `macos-app/Core/PortfolioValuationAlertStore.swift`

**Interfaces:**
- Consumes: Task 1 模型
- Produces: `PortfolioValuationAlertStore`（load/save/profile/upsert/remove/hasActiveAlerts）、`PortfolioValuationAlertSettingsStore`（load/save settings）

- [ ] **Step 1: 实现 Store**

Create `macos-app/Core/PortfolioValuationAlertStore.swift`（参照 `PersonalWatchlistStore` 的纯函数 load/save 模式）:

```swift
import Foundation

/// 持仓估值预警 profiles 持久化（profile 集合 JSON）
struct PortfolioValuationAlertStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func load(from fileURL: URL) throws -> [String: PortfolioValuationAlertProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let array = try decoder.decode([PortfolioValuationAlertProfile].self, from: data)
        return Dictionary(uniqueKeysWithValues: array.map { ($0.fundCode, $0) })
    }

    func save(_ profiles: [String: PortfolioValuationAlertProfile], to fileURL: URL) throws {
        let array = profiles.values.sorted { $0.fundCode < $1.fundCode }
        let data = try encoder.encode(array)
        try data.write(to: fileURL, options: .atomic)
    }

    func delete(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// 持仓估值预警全局设置持久化
struct PortfolioValuationAlertSettingsStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func load(from fileURL: URL) throws -> PortfolioValuationAlertSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PortfolioValuationAlertSettings()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(PortfolioValuationAlertSettings.self, from: data)
    }

    func save(_ settings: PortfolioValuationAlertSettings, to fileURL: URL) throws {
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add macos-app/Core/PortfolioValuationAlertStore.swift
git commit -m "feat: 持仓估值预警持久化 Store"
```

---

## Task 4: 通知深链扩展

**Files:**
- Modify: `macos-app/Core/Models/ManagerWatchSettings.swift:257-262`（`NotificationDeepLinkType` 枚举）

**Interfaces:**
- Produces: `NotificationDeepLinkType.portfolioValuationAlert`

- [ ] **Step 1: 新增深链 case**

In `macos-app/Core/Models/ManagerWatchSettings.swift`, find the `NotificationDeepLinkType` enum (around line 257) and add a case. Change:

```swift
enum NotificationDeepLinkType: String {
    case platformAction = "platform_action"
    case forumRecord = "forum_record"
    case workbenchTrend = "workbench_trend"
    case personalWatchlist = "personal_watchlist"
}
```

to:

```swift
enum NotificationDeepLinkType: String {
    case platformAction = "platform_action"
    case forumRecord = "forum_record"
    case workbenchTrend = "workbench_trend"
    case personalWatchlist = "personal_watchlist"
    case portfolioValuationAlert = "portfolio_valuation_alert"
}
```

（`NotificationDeepLinkPayload.init?(userInfo:)` 已用 `NotificationDeepLinkType(rawValue:)` 解析，新增 case 自动支持；`userInfo` getter 也走 `type.rawValue`，无需改动。）

- [ ] **Step 2: 处理深链（新增 case 分支）**

In `macos-app/Core/AppModel/ManagerWatch.swift:538-550` 的 `handleNotificationDeepLink`，在 `case .personalWatchlist:` 后追加：

```swift
        case .personalWatchlist:
            selectedSection = .portfolio
        case .portfolioValuationAlert:
            selectedSection = .portfolio
        }
```

- [ ] **Step 3: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED（switch 已穷尽新 case）。

- [ ] **Step 4: Commit**

```bash
git add macos-app/Core/Models/ManagerWatchSettings.swift macos-app/Core/AppModel/ManagerWatch.swift
git commit -m "feat: 估值预警通知深链支持"
```

---

## Task 5: AppModel 接线（加载 + CRUD + 计算属性）

**Files:**
- Modify: `macos-app/Core/AppModel.swift`（实例化 store + settings 状态）
- Modify: `macos-app/Core/AppModel/ComputedProperties.swift`（新增 fileURL）

**Interfaces:**
- Consumes: Task 1 模型、Task 3 Store
- Produces: AppModel 上的 `portfolioValuationAlertStore`、`portfolioValuationAlertProfiles`、`portfolioValuationAlertSettings`、`portfolioValuationAlertFileURL`、`portfolioValuationAlertSettingsFileURL`

- [ ] **Step 1: 新增 fileURL 计算属性**

In `macos-app/Core/AppModel/ComputedProperties.swift`，在 `investmentPlanFileURL`（约 :44）之后追加：

```swift
    var portfolioValuationAlertFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("portfolio-valuation-alerts.json", isDirectory: false)
    }

    var portfolioValuationAlertSettingsFileURL: URL? {
        dataDirectoryURL?.appendingPathComponent("portfolio-valuation-alert-settings.json", isDirectory: false)
    }
```

- [ ] **Step 2: AppModel 实例化 store + 状态**

In `macos-app/Core/AppModel.swift`，找到 Services 区域（约 :108-119，`let managerWatchStore = ManagerWatchStore()` 那段），在 `let personalWatchlistStore = PersonalWatchlistStore()` 下一行加：

```swift
    let portfolioValuationAlertStore = PortfolioValuationAlertStore()
    let portfolioValuationAlertSettingsStore = PortfolioValuationAlertSettingsStore()
```

然后在 `@Published` 状态区域（约 :98 `managerWatchSettings` 附近），追加：

```swift
    @Published var portfolioValuationAlertProfiles: [String: PortfolioValuationAlertProfile] = [:]
    @Published var portfolioValuationAlertSettings = PortfolioValuationAlertSettings()
```

- [ ] **Step 3: 启动时加载**

找到 `AppModel` 的 `start()` / `func loadSaved...` 区域（参考 `loadSavedPersonalWatchlist()` 在 `PersonalWatchlistActions.swift:287`）。在 `Core/AppModel.swift` 中找到 `start()` 方法（约 :610-615），在已有加载调用（如 `loadSavedPersonalWatchlist()`）附近追加调用。先确认 start 的位置：

Run: `cd macos-app && grep -n "func start()\|loadSavedPersonalWatchlist()\|loadInvestmentPlans()\|loadSavedPortfolio" Core/AppModel.swift`

在 `start()` 内已有加载序列里追加一行：

```swift
        loadSavedPortfolioValuationAlerts()
```

并在 `Core/AppModel/PortfolioValuationAlert.swift`（Task 6 创建）实现该方法。本步先只加调用，Task 6 补实现。

（若 `swift build` 暂时编译失败属正常，Task 6 完成后通过。）

- [ ] **Step 4: Commit（与 Task 6 合并提交，本步不单独 commit）**

暂不提交，等 Task 6 完成。

---

## Task 6: AppModel 评估+通知逻辑

**Files:**
- Create: `macos-app/Core/AppModel/PortfolioValuationAlert.swift`
- Modify: `macos-app/Core/AppModel/PortfolioCRUD.swift`（删除持仓联动清理）

**Interfaces:**
- Consumes: Task 1-5
- Produces: `AppModel.loadSavedPortfolioValuationAlerts()`、`evaluatePortfolioValuationAlerts()`、`upsertPortfolioValuationAlertProfile(_:)`、`removePortfolioValuationAlertProfile(fundCode:)`、`setPortfolioValuationAlertEnabled(_:)`、`hasActivePortfolioValuationAlerts`

- [ ] **Step 1: 实现子逻辑**

Create `macos-app/Core/AppModel/PortfolioValuationAlert.swift`:

```swift
import Foundation

// MARK: - Portfolio Valuation Alert

extension AppModel {

    var hasActivePortfolioValuationAlerts: Bool {
        portfolioValuationAlertProfiles.values.contains { $0.hasActiveRules }
    }

    /// 启动时从磁盘加载
    func loadSavedPortfolioValuationAlerts() {
        do {
            if let portfolioValuationAlertFileURL {
                portfolioValuationAlertProfiles = try portfolioValuationAlertStore.load(
                    from: portfolioValuationAlertFileURL)
            }
            if let portfolioValuationAlertSettingsFileURL {
                portfolioValuationAlertSettings = try portfolioValuationAlertSettingsStore.load(
                    from: portfolioValuationAlertSettingsFileURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 持久化 profiles
    private func persistPortfolioValuationAlerts() {
        guard let portfolioValuationAlertFileURL else { return }
        try? portfolioValuationAlertStore.save(
            portfolioValuationAlertProfiles, to: portfolioValuationAlertFileURL)
    }

    /// 持久化设置
    private func persistPortfolioValuationAlertSettings() {
        guard let portfolioValuationAlertSettingsFileURL else { return }
        try? portfolioValuationAlertSettingsStore.save(
            portfolioValuationAlertSettings, to: portfolioValuationAlertSettingsFileURL)
    }

    /// 获取某标的的 profile（不存在则建空）
    func portfolioValuationAlertProfile(for fundCode: String) -> PortfolioValuationAlertProfile {
        portfolioValuationAlertProfiles[fundCode]
            ?? PortfolioValuationAlertProfile(fundCode: fundCode)
    }

    /// 保存/更新某标的的 profile
    func upsertPortfolioValuationAlertProfile(_ profile: PortfolioValuationAlertProfile) {
        var next = profile
        // 清理：移除已不存在于 rules 的 breached/lastTriggered 残留
        let validIDs = Set(next.rules.map(\.id))
        next.breachedRuleIDs.formIntersection(validIDs)
        next.lastTriggeredAt = next.lastTriggeredAt.filter { validIDs.contains($0.key) }
        portfolioValuationAlertProfiles[next.fundCode] = next
        persistPortfolioValuationAlerts()
    }

    /// 删除某标的的 profile（持仓删除时联动）
    func removePortfolioValuationAlertProfile(fundCode: String) {
        guard portfolioValuationAlertProfiles.removeValue(forKey: fundCode) != nil else { return }
        persistPortfolioValuationAlerts()
    }

    /// 设置全局开关
    func setPortfolioValuationAlertEnabled(_ enabled: Bool) {
        portfolioValuationAlertSettings.isEnabled = enabled
        persistPortfolioValuationAlertSettings()
    }

    /// 评估所有持仓的预警并发通知（挂在 60s 刷新循环末尾）
    func evaluatePortfolioValuationAlerts() async {
        guard portfolioValuationAlertSettings.isEnabled else { return }
        guard let snapshot = userPortfolioSnapshot else { return }

        var firedPayloads: [(rule: PortfolioValuationAlertRule, fundName: String, fundCode: String, value: Double?)] = []
        var didMutate = false

        for row in snapshot.rows {
            let fundCode = row.holding.fundCode
            guard var profile = portfolioValuationAlertProfiles[fundCode],
                  profile.hasActiveRules else { continue }

            let context = PortfolioValuationAlertContext(
                holdingProfitPct: row.profitPct,
                estimateChangePct: row.estimateChangePct,
                estimatePrice: row.estimatePrice
            )

            for rule in profile.rules where rule.isEnabled {
                let isBreached = profile.breachedRuleIDs.contains(rule.id)
                let evaluation = PortfolioValuationAlertEvaluator.evaluate(
                    rule: rule, context: context, isCurrentlyBreached: isBreached)
                switch evaluation {
                case .fire:
                    profile.breachedRuleIDs.insert(rule.id)
                    profile.lastTriggeredAt[rule.id] = Self.currentTimestamp()
                    firedPayloads.append((rule, row.fundName, fundCode, observedValue(rule: rule, context: context)))
                    didMutate = true
                case .clear:
                    profile.breachedRuleIDs.remove(rule.id)
                    didMutate = true
                case .hold, .idle:
                    break
                }
            }

            if didMutate || profile != portfolioValuationAlertProfiles[fundCode] {
                portfolioValuationAlertProfiles[fundCode] = profile
            }
        }

        if didMutate {
            persistPortfolioValuationAlerts()
        }

        guard !firedPayloads.isEmpty else { return }
        guard await notificationManager.requestAuthorizationIfNeeded() else { return }
        for payload in firedPayloads {
            let title = payload.rule.side == .sell
                ? "估值预警 · 提醒卖出"
                : "估值预警 · 提醒加仓"
            let body = PortfolioValuationAlertEvaluator.describe(
                rule: payload.rule, fundName: payload.fundName,
                fundCode: payload.fundCode, observedValue: payload.value)
            try? await notificationManager.send(
                title: title, body: body,
                deepLink: NotificationDeepLinkPayload(
                    type: .portfolioValuationAlert,
                    targetID: "\(payload.fundCode):\(payload.rule.id.uuidString)"
                )
            )
        }
    }

    private func observedValue(
        rule: PortfolioValuationAlertRule,
        context: PortfolioValuationAlertContext
    ) -> Double? {
        switch rule.metric {
        case .holdingProfitPct: return context.holdingProfitPct
        case .estimateChangePct: return context.estimateChangePct
        case .estimatePrice: return context.estimatePrice
        }
    }

    private static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }
}
```

- [ ] **Step 2: 完成 start() 加载调用确认**

确认 Task 5 Step 3 在 `start()` 里已加 `loadSavedPortfolioValuationAlerts()`。若未加，在 `start()` 内已有 `loadSavedPersonalWatchlist()` / `loadInvestmentPlans()` 等加载序列旁补上。

- [ ] **Step 3: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -8`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 持仓删除联动清理**

In `macos-app/Core/AppModel/PortfolioCRUD.swift` 的 `deletePersonalAssetEntry(_:scope:)`（约 :20），找到删除 holding 成功后、`deletedParts.append(...)` 之前/之后。在 holding 删除块（约 :33-50）的 `if !holdingIDs.isEmpty { ... }` 块末尾追加联动清理。

定位删除成功的分支（约 :48 `deletedParts.append(...)` 之后）插入：

```swift
                // 联动清理估值预警
                if let fundCode = row.fundCode {
                    removePortfolioValuationAlertProfile(fundCode: fundCode)
                }
```

同样在 `clearPortfolio()`（约 :7-18）的 `userPortfolioHoldings = []` 之后追加：

```swift
            // 清空所有估值预警
            for fundCode in portfolioValuationAlertProfiles.keys {
                portfolioValuationAlertProfiles[fundCode] = nil
            }
            persistPortfolioValuationAlertsFile()
```

注意：`persistPortfolioValuationAlerts()` 是 private。因此改为直接调用 store：在 `clearPortfolio` 中用：

```swift
            if let portfolioValuationAlertFileURL {
                try? portfolioValuationAlertStore.save([:], to: portfolioValuationAlertFileURL)
            }
            portfolioValuationAlertProfiles = [:]
```

（`deletePersonalAssetEntry` 已通过 `removePortfolioValuationAlertProfile` 间接持久化，无需重复。）

- [ ] **Step 5: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -8`
Expected: BUILD SUCCEEDED。

- [ ] **Step 6: Commit（Task 5 + 6 合并）**

```bash
git add macos-app/Core/AppModel.swift \
  macos-app/Core/AppModel/ComputedProperties.swift \
  macos-app/Core/AppModel/PortfolioValuationAlert.swift \
  macos-app/Core/AppModel/PortfolioCRUD.swift
git commit -m "feat: 估值预警接入 AppModel 状态、加载与评估发通知"
```

---

## Task 7: 挂载到 60s 刷新循环

**Files:**
- Modify: `macos-app/Core/AppModel/PortfolioRefresh.swift:188-219`（`refreshPortfolioIfAutoRefreshVisible`）

- [ ] **Step 1: 在刷新末尾挂评估**

In `macos-app/Core/AppModel/PortfolioRefresh.swift` 的 `refreshPortfolioIfAutoRefreshVisible()`（:188），在方法最末尾（`if shouldRefreshWatchlist { ... }` 块之后、方法结束 `}` 之前）追加：

```swift
        // 估值预警评估：无论可见性，只要有持仓数据就评估（持仓刷新在 ticker 常驻时也会后台进行）
        if portfolioValuationAlertSettings.isEnabled, userPortfolioSnapshot != nil {
            await evaluatePortfolioValuationAlerts()
        }
```

完整修改后该方法尾部为：

```swift
        if shouldRefreshWatchlist {
            do {
                try await refreshPersonalWatchlist(updateNotice: false)
            } catch {
                errorMessage = "我的关注自动刷新失败：\(error.localizedDescription)"
            }
        }

        if portfolioValuationAlertSettings.isEnabled, userPortfolioSnapshot != nil {
            await evaluatePortfolioValuationAlerts()
        }
    }
```

- [ ] **Step 2: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: 运行全量测试，确认无回归**

Run: `cd macos-app && swift test 2>&1 | tail -8`
Expected: 全部测试 PASS（含 Task 2 的 11 个 + 既有测试）。

- [ ] **Step 4: Commit**

```bash
git add macos-app/Core/AppModel/PortfolioRefresh.swift
git commit -m "feat: 估值预警挂载到持仓 60s 自动刷新循环"
```

---

## Task 8: 详情抽屉预警区块

**Files:**
- Create: `macos-app/Views/PersonalAsset/PortfolioValuationAlertSection.swift`
- Modify: `macos-app/Views/PersonalAsset/PersonalAssetDetailSheet.swift:57`

- [ ] **Step 1: 实现预警区块 View**

Create `macos-app/Views/PersonalAsset/PortfolioValuationAlertSection.swift`:

```swift
import SwiftUI

/// 资产详情抽屉中的「估值预警」区块
struct PortfolioValuationAlertSection: View {
    @EnvironmentObject private var model: AppModel
    let row: PersonalAssetAggregateRow
    @State private var isEditing = false

    private var fundCode: String? { row.fundCode }
    private var profile: PortfolioValuationAlertProfile? {
        guard let fundCode else { return nil }
        return model.portfolioValuationAlertProfiles[fundCode]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.warning)
                    .accentIconStyle(tint: AppPalette.warning, size: 22)
                Text("估值预警")
                    .font(AppPalette.appFont(.headline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Button {
                    isEditing = true
                } label: {
                    Label(profile == nil ? "设置目标" : "编辑", systemImage: "slider.horizontal.3")
                        .font(AppPalette.appFont(.footnote, weight: .semibold))
                }
                .buttonStyle(.appSecondary)
            }

            snapshotStrip

            if let profile, !profile.rules.isEmpty {
                VStack(spacing: 6) {
                    ForEach(profile.rules) { rule in
                        ruleRow(rule, isBreached: profile.breachedRuleIDs.contains(rule.id))
                    }
                }
            } else {
                Text("未设置目标。达到目标值时发通知提醒卖出或加仓（不会自动下单）。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AppPalette.cardStrong, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
            }

            Text("条件从「未达到」变为「达到」时通知一次；回到阈值另一侧后重新待命。数据缺失时不解除已触发态。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
        }
        .padding(14)
        .background(AppPalette.card.opacity(0.82), in: RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .panelStroke(opacity: 0.36)
        .sheet(isPresented: $isEditing) {
            if let fundCode {
                PortfolioValuationAlertEditSheet(row: row, fundCode: fundCode)
            }
        }
    }

    private var snapshotStrip: some View {
        HStack(spacing: 0) {
            snapshotMetric("持有收益率", row.profitPct.map { Self.formatPct($0) })
            Divider().frame(height: 40).overlay(AppPalette.line.opacity(0.46))
            snapshotMetric("盘中估算涨跌", row.estimateChangePct.map { Self.formatPct($0) })
            Divider().frame(height: 40).overlay(AppPalette.line.opacity(0.46))
            snapshotMetric("估算净值", row.estimatePrice.map { String(format: "%.4f", $0) })
        }
        .padding(.vertical, 6)
        .background(AppPalette.card, in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .cardStroke(opacity: 0.32)
    }

    private func snapshotMetric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppPalette.appFont(.caption, weight: .medium))
                .foregroundStyle(AppPalette.muted)
            Text(value ?? "—")
                .font(AppPalette.appFont(.body, weight: .bold, design: .rounded))
                .foregroundStyle(AppPalette.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .padding(.horizontal, 8)
    }

    private func ruleRow(_ rule: PortfolioValuationAlertRule, isBreached: Bool) -> some View {
        let sideTint: Color = rule.side == .sell ? AppPalette.marketGain : AppPalette.marketLoss
        return HStack(alignment: .center, spacing: 10) {
            Text(rule.side == .sell ? "卖出" : "加仓")
                .font(AppPalette.appFont(.caption, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(sideTint, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rule.metric.displayName) \(rule.direction.displayName) \(Self.formatThreshold(rule))")
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(rule.isEnabled ? AppPalette.ink : AppPalette.muted)
                if isBreached {
                    Text("● 当前已触发")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.warning)
                }
            }
            Spacer()
            if !rule.isEnabled {
                Text("已禁用")
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.muted)
            }
        }
        .padding(10)
        .background(AppPalette.cardStrong.opacity(0.72), in: RoundedRectangle(cornerRadius: AppPalette.cardRadius))
    }

    static func formatPct(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(String(format: "%.2f", value))%"
    }

    static func formatThreshold(_ rule: PortfolioValuationAlertRule) -> String {
        switch rule.metric {
        case .holdingProfitPct, .estimateChangePct:
            return "\(rule.threshold >= 0 ? "+" : "")\(String(format: "%.2f", rule.threshold))%"
        case .estimatePrice:
            return String(format: "%.4f", rule.threshold)
        }
    }
}
```

- [ ] **Step 2: 接入详情抽屉**

In `macos-app/Views/PersonalAsset/PersonalAssetDetailSheet.swift`，找到 `body` 中 `supportingSections(summary.attentionItems)`（约 :57）。在其后追加一行新区块：

```swift
                    supportingSections(summary.attentionItems)

                    PortfolioValuationAlertSection(row: row)
```

- [ ] **Step 3: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
git add macos-app/Views/PersonalAsset/PortfolioValuationAlertSection.swift \
  macos-app/Views/PersonalAsset/PersonalAssetDetailSheet.swift
git commit -m "feat: 资产详情抽屉新增估值预警区块"
```

---

## Task 9: 预警编辑 sheet

**Files:**
- Create: `macos-app/Views/PersonalAsset/PortfolioValuationAlertEditSheet.swift`

- [ ] **Step 1: 实现编辑 sheet**

Create `macos-app/Views/PersonalAsset/PortfolioValuationAlertEditSheet.swift`（参照 `PersonalWatchlistAlertSheet` 的开关+数值输入模式）:

```swift
import SwiftUI

private struct ValuationAlertDraftRule: Identifiable {
    let id = UUID()
    let metric: PortfolioValuationAlertMetric
    var isEnabled: Bool
    var side: PortfolioValuationAlertSide
    var direction: PortfolioValuationAlertDirection
    var thresholdText: String
}

struct PortfolioValuationAlertEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let row: PersonalAssetAggregateRow
    let fundCode: String

    @State private var drafts: [ValuationAlertDraftRule]
    @State private var inlineErrorMessage = ""

    init(row: PersonalAssetAggregateRow, fundCode: String) {
        self.row = row
        self.fundCode = fundCode
        // 初始 draft：从现有 profile 载入，缺失的维度补空（按 assetType 过滤）
        let profile = row.fundCode.flatMap {
            // 占位：实际从 model 取在 body onAppear 处理
            nil as PortfolioValuationAlertProfile?
        }
        _drafts = State(initialValue: Self.initialDrafts(assetType: row.assetType, profile: nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ForEach($drafts) { $draft in
                ruleEditor(draft: $draft)
                if draft.id != drafts.last?.id { Divider().opacity(0.45) }
            }
            if !inlineErrorMessage.isEmpty {
                ToastBar(text: inlineErrorMessage, tint: AppPalette.danger, onDismiss: { inlineErrorMessage = "" })
            }
            Text("条件从「未达到」变为「达到」时通知一次；回到阈值另一侧后重新待命。")
                .font(AppPalette.appFont(.caption))
                .foregroundStyle(AppPalette.muted)
            actionButtons
        }
        .padding(18)
        .frame(width: 500)
        .onAppear { loadDrafts() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .font(AppPalette.appFont(.title2, weight: .semibold))
                .foregroundStyle(AppPalette.warning)
                .accentIconStyle(tint: AppPalette.warning, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("估值预警")
                    .font(AppPalette.appFont(.title2, weight: .bold))
                    .foregroundStyle(AppPalette.ink)
                Text("\(row.fundName) · \(fundCode)")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
            }
            Spacer()
        }
    }

    private func ruleEditor(draft: Binding<ValuationAlertDraftRule>) -> some View {
        let metric = draft.wrappedValue.metric
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: draft.isEnabled) {
                    Text(metric.displayName)
                        .font(AppPalette.appFont(.body, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                }
                .toggleStyle(.switch)
                Spacer()
            }
            if draft.wrappedValue.isEnabled {
                HStack(spacing: 10) {
                    Picker("方向", selection: draft.side) {
                        ForEach(PortfolioValuationAlertSide.allCases, id: \.self) { side in
                            Text(side.displayName).tag(side)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("条件", selection: draft.direction) {
                        ForEach(PortfolioValuationAlertDirection.allCases, id: \.self) { dir in
                            Text(dir.displayName).tag(dir)
                        }
                    }
                    .pickerStyle(.menu)
                    HStack(spacing: 4) {
                        TextField(metric == .estimatePrice ? "例如 1.5" : "例如 20", text: draft.thresholdText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 110)
                        Text(metric.unit).font(AppPalette.appFont(.caption)).foregroundStyle(AppPalette.muted)
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if model.portfolioValuationAlertProfiles[fundCode]?.hasActiveRules == true {
                Button("清除全部", role: .destructive) {
                    model.removePortfolioValuationAlertProfile(fundCode: fundCode)
                    dismiss()
                }
                .buttonStyle(.appDanger)
            }
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.appSecondary)
                .keyboardShortcut(.cancelAction)
            Button("保存") { save() }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.warning)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func loadDrafts() {
        let profile = model.portfolioValuationAlertProfile(for: fundCode)
        drafts = Self.initialDrafts(assetType: row.assetType, profile: profile)
    }

    private func save() {
        var rules: [PortfolioValuationAlertRule] = []
        for draft in drafts {
            guard draft.isEnabled else { continue }
            guard let threshold = Double(draft.thresholdText.trimmingCharacters(in: .whitespaces)),
                  threshold.isFinite else {
                inlineErrorMessage = "「\(draft.metric.displayName)」的阈值无效，请输入数字。"
                return
            }
            rules.append(PortfolioValuationAlertRule(
                metric: draft.metric, side: draft.side,
                direction: draft.direction, threshold: threshold
            ))
        }
        let profile = PortfolioValuationAlertProfile(fundCode: fundCode, rules: rules)
        model.upsertPortfolioValuationAlertProfile(profile)
        dismiss()
    }

    private static func initialDrafts(
        assetType: PersonalAssetType,
        profile: PortfolioValuationAlertProfile?
    ) -> [ValuationAlertDraftRule] {
        let allMetrics = PortfolioValuationAlertMetric.allCases.filter {
            assetType == .stock ? $0.appliesToStock : true
        }
        let existingByID = Dictionary(profile?.rules.map { ($0.metric, $0) } ?? [], uniquingKeysWith: { a, _ in a })
        return allMetrics.map { metric in
            let existing = existingByID[metric]
            return ValuationAlertDraftRule(
                metric: metric,
                isEnabled: existing != nil,
                side: existing?.side ?? defaultSide(for: metric),
                direction: existing?.direction ?? defaultDirection(for: metric),
                thresholdText: existing.map { formatExistingThreshold($0) } ?? ""
            )
        }
    }

    private static func defaultSide(for metric: PortfolioValuationAlertMetric) -> PortfolioValuationAlertSide {
        // 默认：收益率正阈值/价格上穿 → 卖出；下穿 → 加仓
        switch metric {
        case .holdingProfitPct, .estimatePrice: return .sell
        case .estimateChangePct: return .sell
        }
    }

    private static func defaultDirection(for metric: PortfolioValuationAlertMetric) -> PortfolioValuationAlertDirection {
        switch metric {
        case .holdingProfitPct, .estimateChangePct, .estimatePrice: return .above
        }
    }

    private static func formatExistingThreshold(_ rule: PortfolioValuationAlertRule) -> String {
        rule.metric == .estimatePrice
            ? String(format: "%.4f", rule.threshold)
            : String(format: "%.2f", rule.threshold)
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -8`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: Commit**

```bash
git add macos-app/Views/PersonalAsset/PortfolioValuationAlertEditSheet.swift
git commit -m "feat: 估值预警编辑 sheet"
```

---

## Task 10: 设置中心面板

**Files:**
- Create: `macos-app/Views/SettingsValuationAlertPanel.swift`
- Modify: `macos-app/Views/SettingsSectionView.swift:6`（枚举）、`:229`（status）、`:250`（tint）、`:263`（panel switch）

- [ ] **Step 1: 实现面板**

Create `macos-app/Views/SettingsValuationAlertPanel.swift`:

```swift
import SwiftUI

extension SettingsSectionView {
    var valuationAlertPanel: some View {
        SettingsPanel(title: "估值预警", subtitle: "持仓目标买卖提醒", icon: "target") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    runtimeCard
                    summaryCard
                }
                VStack(spacing: 14) {
                    runtimeCard
                    summaryCard
                }
            }
        }
    }

    private var runtimeCard: some View {
        SettingsCardGroup(title: "运行", subtitle: "总开关与状态", icon: "power", tint: AppPalette.warning) {
            SettingsToggleRow(
                title: "启用估值预警",
                detail: "随持仓每 60 秒自动检查",
                icon: "bell.badge",
                tint: AppPalette.warning,
                isOn: Binding(
                    get: { model.portfolioValuationAlertSettings.isEnabled },
                    set: { model.setPortfolioValuationAlertEnabled($0) }
                )
            )
            SettingsDivider()
            SettingsRow(
                title: "已配置规则",
                value: "\(totalRuleCount) 条 / \(configuredFundCount) 只标的",
                detail: "在持仓详情抽屉中逐只设置",
                icon: "list.number",
                tint: AppPalette.info
            )
            SettingsDivider()
            SettingsActionRow {
                Button {
                    Task { await model.evaluatePortfolioValuationAlerts() }
                } label: {
                    Label("立即检查", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.appSecondary)
            }
        }
    }

    private var summaryCard: some View {
        SettingsCardGroup(title: "规则汇总", subtitle: "所有标的已配置的目标", icon: "scope", tint: AppPalette.brand) {
            if summaries.isEmpty {
                Text("暂无已配置的估值预警。打开持仓详情抽屉即可为目标值设置提醒。")
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(summaries, id: \.fundCode) { item in
                    summaryRow(item)
                    if item.fundCode != summaries.last?.fundCode {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private func summaryRow(_ item: ValuationAlertSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.fundName)
                    .font(AppPalette.appFont(.subheadline, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                if item.isAnyBreached {
                    Label("已触发", systemImage: "bell.badge.fill")
                        .font(AppPalette.appFont(.caption, weight: .semibold))
                        .foregroundStyle(AppPalette.warning)
                }
            }
            Text(item.fundCode)
                .font(AppPalette.appFont(.caption, design: .monospaced))
                .foregroundStyle(AppPalette.muted)
            Text(item.ruleText)
                .font(AppPalette.appFont(.footnote))
                .foregroundStyle(AppPalette.muted)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
    }

    private struct ValuationAlertSummary {
        let fundCode: String
        let fundName: String
        let ruleText: String
        let isAnyBreached: Bool
    }

    private var summaries: [ValuationAlertSummary] {
        guard let snapshot = model.userPortfolioSnapshot else {
            return model.portfolioValuationAlertProfiles.compactMap { code, profile in
                guard profile.hasActiveRules else { return nil }
                return ValuationAlertSummary(
                    fundCode: code, fundName: code,
                    ruleText: profile.rules.map { PortfolioValuationAlertSection.formatThreshold($0) }.joined(separator: " · "),
                    isAnyBreached: profile.isCurrentlyBreached
                )
            }.sorted { $0.fundCode < $1.fundCode }
        }
        let nameByCode = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.holding.fundCode, $0.fundName) })
        return model.portfolioValuationAlertProfiles.compactMap { code, profile in
            guard profile.hasActiveRules else { return nil }
            return ValuationAlertSummary(
                fundCode: code,
                fundName: nameByCode[code] ?? code,
                ruleText: profile.rules.map { "\($0.metric.displayName) \($0.side.displayName) \(PortfolioValuationAlertSection.formatThreshold($0))" }.joined(separator: " · "),
                isAnyBreached: profile.isCurrentlyBreached
            )
        }.sorted { $0.fundCode < $1.fundCode }
    }

    private var totalRuleCount: Int {
        model.portfolioValuationAlertProfiles.values.reduce(0) { $0 + $1.rules.filter(\.isEnabled).count }
    }

    private var configuredFundCount: Int {
        model.portfolioValuationAlertProfiles.values.filter(\.hasActiveRules).count
    }
}
```

- [ ] **Step 2: 接入设置中心枚举与路由**

In `macos-app/Views/SettingsSectionView.swift`:

(a) `SettingsFocus` 枚举（:6）新增 case：

```swift
enum SettingsFocus: CaseIterable, Identifiable {
    case general
    case watch
    case trend
    case menuBar
    case valuationAlert        // 新增
```

并在 `title`/`subtitle`/`systemImage` 的 switch 各加一个分支：

```swift
        case .valuationAlert:
            return "估值预警"
```
```swift
        case .valuationAlert:
            return "持仓目标买卖提醒"
```
```swift
        case .valuationAlert:
            return "target"
```

(b) `settingsStatus(for:)`（:229）新增：

```swift
        case .valuationAlert:
            return model.portfolioValuationAlertSettings.isEnabled
                ? "\(model.portfolioValuationAlertProfiles.values.reduce(0) { $0 + $1.rules.filter(\.isEnabled).count }) 条规则"
                : "已关闭"
```

(c) `settingsStatusTint(for:)`（:250）新增：

```swift
        case .valuationAlert:
            return model.portfolioValuationAlertSettings.isEnabled ? AppPalette.warning : AppPalette.muted
```

(d) `selectedSettingsPanel`（:263）新增：

```swift
        case .valuationAlert:
            valuationAlertPanel
```

- [ ] **Step 3: 编译验证**

Run: `cd macos-app && swift build 2>&1 | tail -8`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: Commit**

```bash
git add macos-app/Views/SettingsValuationAlertPanel.swift macos-app/Views/SettingsSectionView.swift
git commit -m "feat: 设置中心新增估值预警面板"
```

---

## Task 11: 全量测试与最终验证

- [ ] **Step 1: 运行全量测试**

Run: `cd macos-app && swift test 2>&1 | tail -15`
Expected: 全部 PASS（含 Task 2 的 11 个新测试 + 既有所有测试）。

- [ ] **Step 2: 构建完整 App**

Run: `APP_VERSION=3.13.0 bash scripts/build_macos_app.sh 2>&1 | tail -8`
Expected: 构建成功，产出 `dist/macos-app/QiemanDashboard.app`。

- [ ] **Step 3: 修复发现的问题（若有）**

若测试/构建失败，逐项修复后重新运行 Step 1-2。

- [ ] **Step 4: 最终提交（若有修复）**

```bash
git add -A
git commit -m "fix: 估值预警集成验证修复"   # 仅在有修复时
```

---

## Self-Review

**1. Spec coverage:**
- §1 数据模型 → Task 1 ✓
- §2 评估器（滞回去重、epsilon、数据缺失保持 breached、文案）→ Task 2 ✓
- §3 持久化 Store + 设置持久化 → Task 3 ✓
- §3 刷新挂载（60s 循环、不做可见性门控）→ Task 7 ✓
- §3 持仓删除联动 → Task 6 Step 4 ✓
- §2 通知深链 → Task 4 ✓
- §2 AppModel 评估+发通知 → Task 6 ✓
- §4.1 详情抽屉区块 → Task 8 ✓
- §4.1 编辑 sheet（assetType 过滤 estimatePrice）→ Task 9 ✓
- §4.2 设置中心面板 → Task 10 ✓
- §5 测试 → Task 2 + Task 11 ✓

**2. Placeholder scan:** 无 TBD/TODO，每个代码步骤均含完整代码。Task 5 Step 3 的 `loadSavedPortfolioValuationAlerts()` 调用在 Task 6 Step 1 实现，已显式说明依赖关系。

**3. Type consistency:**
- `PortfolioValuationAlertEvaluator.evaluate(...)` 签名 Task 2 定义、Task 6 调用一致。
- `AppModel.evaluatePortfolioValuationAlerts()` / `upsertPortfolioValuationAlertProfile(_:)` / `removePortfolioValuationAlertProfile(fundCode:)` / `setPortfolioValuationAlertEnabled(_:)` / `portfolioValuationAlertProfile(for:)` 在 Task 6 定义，Task 8/9/10 调用一致。
- `PortfolioValuationAlertSection.formatThreshold(_:)` Task 8 定义，Task 10 调用一致。
- `model.portfolioValuationAlertProfiles` / `model.portfolioValuationAlertSettings` Task 5 定义，Task 6/8/9/10 引用一致。
- 深链 `NotificationDeepLinkType.portfolioValuationAlert` Task 4 定义，Task 6 使用一致。

**注意点（实现时留心）：**
- Task 6 Step 1 的 `evaluatePortfolioValuationAlerts` 中 `didMutate` 标志在多标的循环里是累加的（任一标的变更即持久化），正确。
- `clearPortfolio()` 不调用 private `persistPortfolioValuationAlerts()`，改为直接用 store save 空字典（已在 Task 6 Step 4 说明）。
- Task 9 的 `init` 无法访问 `model`（EnvironmentObject 在 body 才可用），故用 `onAppear { loadDrafts() }` 从 model 载入初始 draft——已处理。
