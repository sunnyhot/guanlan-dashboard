# 持仓估值目标预警 — 设计文档

- 日期: 2026-07-30
- 状态: 设计已确认，待实现
- 范围: 为「我的持仓」标的添加「估值达到目标值时发通知提醒买卖」能力

## 背景与目标

用户希望为持仓中的标的设置目标值，当估值达到目标时收到系统通知，提醒卖出或加仓。

**重要前提**：且慢 API 不支持自动下单，故本功能为「发通知提醒」，不涉及自动交易。

### 现状（不改动）

- 持仓数据：`UserPortfolioHolding`（静态：`fundCode`/份额/成本）+ `UserPortfolioValuationRow`（动态：`currentPrice`、盘中 `estimatePrice`、`estimateChangePct`、持有收益率 `profitPct`、市值等）。
- 持仓每 60 秒自动刷新（`Core/AppModel/PortfolioRefresh.swift` 的 `restartPortfolioAutoRefreshLoop`，间隔常量 `AppModel.swift:140`）。
- 项目已有一套完整的价格预警系统 `PersonalWatchlistAlert*`，但它只作用于「我的关注自选股（PersonalWatchlist）」，**不作用于真实持仓**。结构含规则 `PersonalWatchlistAlertRules`、评估器 `PersonalWatchlistAlertEvaluator`、去重状态、`LocalNotificationManager.send` 发系统通知。
- 本功能 = 把这套预警能力从「自选股」独立地复制/扩展到「我的持仓」，并增加「买卖方向」语义。

### 设计决策（已与用户确认）

| 决策点 | 选择 |
|---|---|
| 触发维度 | 持有收益率（止盈/止损）、盘中估算涨跌幅、估算净值绝对值 三个维度 |
| 去重策略 | 触发后只发一次，回落离开阈值区间、再次穿越时再发（滞回，与 watchlist 一致） |
| 配置入口 | 持仓详情抽屉里加「估值预警」区块 + 编辑 sheet |
| 全局设置 | 设置中心新增专用「估值预警」面板（第 5 个分区） |
| 买卖语义 | 用户配规则时选「卖出」或「加仓」方向，通知文案明确体现 |

### 方案选型

采用**方案 A：独立新模块**。理由：
- 自选股预警 vs 持仓预警是两回事（持仓才有"持有收益率""买卖方向"语义），强行合并模型会语义冲突。
- 零回归风险，不动现有 watchlist 代码。
- 符合项目「按域拆分模型」「分析模块纯派生」约定。
- 评估器逻辑参照 watchlist 模式独立实现，不强行共用（YAGNI）；后续若两者趋同再抽取。

## §1 数据模型

新建文件 `macos-app/Core/Models/PortfolioValuationAlert.swift`。

```swift
// 触发维度
enum PortfolioValuationAlertMetric: String, Codable, CaseIterable {
    case holdingProfitPct      // 持有收益率（止盈/止损）
    case estimateChangePct     // 盘中估算涨跌幅
    case estimatePrice         // 盘中估算净值绝对值
}

// 买卖方向（用户配规则时选）
enum PortfolioValuationAlertSide: String, Codable {
    case sell   // 提醒卖出（止盈/高位）
    case buy    // 提醒加仓（止损/低位）
}

// 比较方向
enum PortfolioValuationAlertDirection: String, Codable {
    case above  // 上穿 >= 阈值
    case below  // 下穿 <= 阈值
}

// 单条规则
struct PortfolioValuationAlertRule: Codable, Identifiable, Equatable {
    var id: UUID
    var metric: PortfolioValuationAlertMetric
    var side: PortfolioValuationAlertSide
    var direction: PortfolioValuationAlertDirection
    var threshold: Double         // 收益率/涨跌幅为百分点(20 = 20%)；估算净值为绝对值(1.500)
    var note: String?             // 可选备注
    var isEnabled: Bool           // 可单独禁用
}

// 一只标的的全部规则 + 去重状态
struct PortfolioValuationAlertProfile: Codable, Equatable {
    var fundCode: String
    var rules: [PortfolioValuationAlertRule]
    var breachedRuleIDs: Set<UUID>              // 当前已触发未回落的规则
    var lastTriggeredAt: [UUID: Date]           // 上次触发时间
}

// 全局设置
struct PortfolioValuationAlertSettings: Codable, Equatable {
    var enabled: Bool = true     // 全局总开关
}
```

**设计要点：**
- `direction` + `side` 解耦：方向决定「何时算达标」（上穿/下穿），side 决定「达标后通知文案」（卖出/加仓）。用户配置时选 side，方向由 metric+side 给合理默认（如"收益率止盈"默认 above+sell），高级用户可改方向。
- 持久化只存规则和 breached 状态（去重用），不存历史触发记录（YAGNI）。
- `threshold` 单位：收益率/涨跌幅用百分点数字（20 = 20%），与项目 `ValueFormatting` 一致；估算净值用绝对值（1.500）。
- 维度对资产类型的适用性：`holdingProfitPct`/`estimateChangePct` 对基金和股票都适用；`estimatePrice`（估算净值）只对基金有意义（股票无净值概念）。编辑 sheet 按 `assetType` 隐藏不适用的维度（股票不展示 estimatePrice 维度）。

## §2 评估与通知

新建纯逻辑文件 `macos-app/Core/PortfolioValuationAlertEvaluator.swift`，参照 `PersonalWatchlistAlertEvaluator` 模式独立实现。

```swift
struct PortfolioValuationAlertEvaluator {
    static let thresholdEpsilon = 1e-9   // 与 watchlist 一致的浮点容差

    // 输入：一条规则 + 当前估值数据 + 该规则当前是否已 breached
    // 输出：本次评估结果（是否触发 / 是否解除）
    static func evaluate(
        rule: PortfolioValuationAlertRule,
        context: PortfolioValuationAlertContext,
        isCurrentlyBreached: Bool
    ) -> PortfolioValuationAlertEvaluation
}

// 从 UserPortfolioValuationRow 派生的只读上下文
struct PortfolioValuationAlertContext {
    let holdingProfitPct: Double?      // row.profitPct
    let estimateChangePct: Double?     // row.estimateChangePct
    let estimatePrice: Double?         // row.estimatePrice
}

// 评估结果
enum PortfolioValuationAlertEvaluation {
    case fire        // 本次应触发通知（未 breached 且达标）
    case hold        // 已 breached 仍在区间，不重发（去重）
    case clear       // 已 breached 但已回落离开，解除 breached
    case idle        // 未达标且未 breached，无动作
}
```

**评估逻辑：**
1. **取值**：按 `rule.metric` 从 context 取对应值；为 nil（无估值数据）→ `idle`。
2. **比较**（带 epsilon 容差）：
   - `direction == .above`：`value >= threshold - epsilon` 算达标
   - `direction == .below`：`value <= threshold + epsilon` 算达标
3. **去重（滞回）**：
   - 未 breached 且达标 → `fire`，标记 breached
   - 已 breached 且达标 → `hold`（不重发）
   - 已 breached 且未达标 → `clear`（解除 breached，下次再穿越可重发）
   - 未 breached 且未达标 → `idle`

**触发后动作**（在 AppModel 子逻辑，不在 evaluator 里）— 新建 `macos-app/Core/AppModel/PortfolioValuationAlert.swift`：

```swift
func evaluatePortfolioValuationAlerts() async {
    guard settings.enabled else { return }
    guard let snapshot = userPortfolioSnapshot else { return }
    for row in snapshot.rows {
        guard let profile = alertStore.profile(for: row.holding.fundCode),
              profile.rules.contains(where: { $0.isEnabled }) else { continue }
        let ctx = PortfolioValuationAlertContext(from: row)
        var fired: [PortfolioValuationAlertRule] = []
        // 逐规则评估，按结果更新 breachedRuleIDs / lastTriggeredAt，收集 fired
        for rule in profile.rules where rule.isEnabled {
            let eval = PortfolioValuationAlertEvaluator.evaluate(
                rule: rule, context: ctx,
                isCurrentlyBreached: profile.breachedRuleIDs.contains(rule.id))
            switch eval {
            case .fire:
                profile.breachedRuleIDs.insert(rule.id)
                profile.lastTriggeredAt[rule.id] = Date()
                fired.append(rule)
            case .clear:
                profile.breachedRuleIDs.remove(rule.id)
            case .hold, .idle: break
            }
        }
        alertStore.upsert(profile)
        for rule in fired {
            let title = rule.side == .sell ? "估值预警 · 提醒卖出" : "估值预警 · 提醒加仓"
            let body = PortfolioValuationAlertEvaluator.describe(rule: rule, row: row)
            try? await notificationManager.send(
                title: title, body: body,
                deepLink: .portfolioValuationAlert(fundCode: row.holding.fundCode))
        }
    }
    alertStore.save()
}
```

**通知文案示例（买卖方向明确）：**

| metric | side | 文案 |
|---|---|---|
| 持有收益率 above 20% | 卖出 | `易方达蓝筹(005827) 持有收益率达 +20.5%，超过 +20% 止盈目标，可考虑卖出` |
| 持有收益率 below -10% | 加仓 | `易方达蓝筹(005827) 持有收益率跌至 -10.3%，跌破 -10% 止损线，可考虑加仓` |
| 盘中估算涨跌 above 3% | 卖出 | `易方达蓝筹(005827) 盘中估算涨 +3.2%，超过 +3% 目标` |
| 估算净值 above 1.500 | 卖出 | `易方达蓝筹(005827) 估算净值 1.512，超过 1.500 目标` |

**关键设计点：**
- 纯派生 + 不持有时态：evaluator 是静态方法，输入只读 context，输出枚举。可单测。
- 去重状态在 Store（持久化），evaluator 只判单次，AppModel 负责读写 breached 状态——职责分离。
- 通知去重 identifier：`portfolio-valuation-alert-<fundCode>-<ruleID>`，回落重穿后追加 timestamp 后缀避免被系统级去重吞掉。

## §3 持久化与刷新挂载

### 持久化 — 新建 `macos-app/Core/PortfolioValuationAlertStore.swift`

参照现有 Store 模式（纯函数 load/save）：

```swift
final class PortfolioValuationAlertStore {
    private(set) var profiles: [String: PortfolioValuationAlertProfile]  // key = fundCode
    private let fileURL: URL                                             // portfolio-valuation-alerts.json

    func load()
    func save()
    func profile(for fundCode: String) -> PortfolioValuationAlertProfile?
    func upsert(_ profile: PortfolioValuationAlertProfile)
    func remove(for fundCode: String)                 // 持仓删除时联动清理
    func updateBreachedState(fundCode:, ruleID:, breached:, at:)
    var hasActiveAlerts: Bool { get }                 // 是否存在任何已配置规则
}
```

- 全局设置 `PortfolioValuationAlertSettings` 持久化：跟随 AppModel 现有用户偏好存储方式（实现时对齐现有偏好存储，不另起炉灶）。

### 刷新挂载 — 复用现有 60s 循环，零新增定时器

在 `Core/AppModel/PortfolioRefresh.swift` 的 `refreshPortfolioIfAutoRefreshVisible()` 刷新成功后追加：

```swift
if valuationAlertStore.hasActiveAlerts || valuationAlertSettings.enabled {
    await evaluatePortfolioValuationAlerts()
}
```

**关键设计点：**
- 零新增定时器：评估直接复用持仓 60s 刷新循环——估值数据本来就在这次刷新里刚拿到（`userPortfolioSnapshot`），评估紧随其后，数据总是最新。
- 不做可见性门控：即使用户在看别的 tab，只要后台 60s 循环刷新了持仓（菜单栏 ticker 常驻时也会刷新），就顺带评估，保证不漏报。可见性门控只影响"要不要拉行情"，不影响"要不要评估"。
- 持仓删除联动：`PortfolioCRUD` 删除持仓时调 `alertStore.remove(for:)`，避免悬挂预警规则。

**数据流：**
```
60s 循环 refreshPortfolioIfAutoRefreshVisible
  → platformClient.fetchUserPortfolioSnapshot（拉行情，写 userPortfolioSnapshot）
  → rebuildAssetRows
  → [新增] evaluatePortfolioValuationAlerts
        → 遍历 snapshot.rows，按 fundCode 取 profile
        → PortfolioValuationAlertEvaluator.evaluate（纯函数判单次）
        → 命中 .fire：notificationManager.send（带买卖方向 + 数值）
        → 回写 breachedRuleIDs/lastTriggeredAt → alertStore.save
```

## §4 UI

### 4.1 详情抽屉新增「估值预警」区块

接入点：`PersonalAssetDetailSheet.swift:57`，在 `supportingSections(summary.attentionItems)` 后插入 `PortfolioValuationAlertSection(row: row)`。

新建 `macos-app/Views/PersonalAsset/PortfolioValuationAlertSection.swift`：

```swift
struct PortfolioValuationAlertSection: View {
    @EnvironmentObject private var model: AppModel
    let row: PersonalAssetAggregateRow
    @State private var isEditing = false

    var body: some View {
        detailSection(title: "估值预警", icon: "bell.badge") {   // 复用 sheet 的 detailSection 样式
            alertSnapshotStrip        // 当前估值摘要（现价/估算净值/持有收益率）
            ruleList                  // 空态 / 已配置规则（含 enabled toggle + 买卖方向徽标 + 阈值 + 触发态）
            // 底部说明 + "设置目标"按钮 → 弹出编辑 sheet
        }
        .sheet(isPresented: $isEditing) {
            PortfolioValuationAlertEditSheet(row: row)
        }
    }
}
```

**编辑 sheet** — 新建 `PortfolioValuationAlertEditSheet.swift`，参照现有 `PersonalWatchlistAlertSheet`（开关+数值输入）模式，按三个维度 + 买卖方向组织：

```swift
private struct PortfolioValuationAlertEditSheet: View {
    let row: PersonalAssetAggregateRow
    // 三个维度各一行（开关 + 阈值输入 + 买卖方向 Picker），如：
    @State private var profitEnabled: Bool
    @State private var profitThreshold: String      // "20" 表示 20%
    @State private var profitSide: PortfolioValuationAlertSide  // 卖出/加仓
    // ... estimateChangePct / estimatePrice 同理
    // 保存 → model.upsertPortfolioValuationAlertProfile(...)
}
```

**区块内单条规则呈现**（参照 watchlist 样式，加买卖方向徽标）：
```
[●卖出] 易方达蓝筹 持有收益率 ≥ +20%        [开关]
        当前 +20.5% · 已触发        ← 触发态高亮（红涨绿跌色）
```

### 4.2 设置中心新增「估值预警」面板

`SettingsSectionView.swift` 现有 4 个 case（`:6`）。新增第 5 个：

```swift
enum SettingsFocus: CaseIterable {
    case general, watch, trend, menuBar
    case valuationAlert        // 新增
}
// 补全 title/subtitle/systemImage：
//   title "估值预警"  subtitle "持仓目标买卖提醒"  systemImage "target"
// settingsStatus(for:) → model.portfolioValuationAlertSettings.enabled ? "N 条规则" : "已关闭"
// settingsStatusTint(for:) → enabled ? AppPalette.warning : AppPalette.muted
// selectedSettingsPanel switch 新增：case .valuationAlert: SettingsValuationAlertPanel()
```

新建 `macos-app/Views/SettingsValuationAlertPanel.swift`，参照 `SettingsWatchPanel` 结构（`SettingsPanel` 容器 + 卡片）：

```swift
struct SettingsValuationAlertPanel: View { ... }   // extension SettingsSectionView
// 内容：
//   运行卡：全局总开关（enabled）、系统通知权限状态、"立即检查"按钮、最后检查时间
//   汇总卡：列出所有标的已配置规则（fundCode + 规则摘要 + 当前估值 + 触发态），点击跳详情
//   说明卡：去重逻辑说明文案（照搬 watchlist "达到通知一次，回到另一侧后重新待命"）
```

导航自动适配：`settingsNavigation(layout:)` 用 `ForEach(SettingsFocus.allCases)`，无需改遍历逻辑，新增 case 自动出现；"N 个分区"标签自动变 5。

**UI 要点：**
- 完全复用现有模式：预警区块 = sheet 的 `detailSection`；编辑 sheet = `PersonalWatchlistAlertSheet` 的开关+数值；设置面板 = `SettingsWatchPanel` 的卡片式两列自适应布局（与 commit `005d6e1` 统一）。涨跌/触发色用 AppPalette（红涨绿跌），符合中国股市惯例。
- 买卖方向明确可见：规则列表和编辑 sheet 都显示「卖出/加仓」徽标，通知文案也带方向。
- 不改动 watchlist UI：新文件独立，零回归。

## §5 测试与发布

### 测试 — 新建 `macos-app/Tests/PortfolioValuationAlertTests.swift`

聚焦纯函数 evaluator + 文案生成（UI/Store/通知不测，遵循项目惯例）：

```swift
final class PortfolioValuationAlertTests: XCTestCase {
    // —— PortfolioValuationAlertEvaluator.evaluate ——

    // 基础触发
    func testFire_above_正阈值达标()            // 持有收益率 above 20%，当前 +20.5%，未 breached → .fire
    func testFire_below_负阈值达标()            // 持有收益率 below -10%，当前 -10.3%，未 breached → .fire

    // 去重（滞回）
    func testHold_已breached仍在区间()          // above 20%，当前 +21%，已 breached → .hold
    func testFire_回落离开后再次穿越()          // 先达标→回落+18%解除→再涨+21% → .fire
    func testClear_回落到阈值另一侧()           // above 20%，已 breached，当前 +15% → .clear

    // 浮点容差
    func testFire_边界epsilon容差()             // above 20%，当前 20.0 - 1e-10 → 仍 .fire

    // 数据缺失 / 禁用
    func testIdle_对应维度数据为nil()           // estimatePrice 为 nil → estimatePrice 类规则 .idle
    func testIdle_规则被禁用()                  // isEnabled = false → .idle

    // 通知文案生成（纯函数 describe）
    func testDescribe_收益率止盈()              // 含 "持有收益率达 +20.5%" 且含 "卖出"
    func testDescribe_估算净值()                // 含 "估算净值 1.512" 且含目标 "1.500"
}
```

测试要点：只测 evaluator（静态方法）+ describe（纯函数）；去重（滞回）是核心逻辑，重点覆盖进入触发 / 区间内不重发 / 离开解除 / 重新穿越再发；边界 epsilon 与现有 `PersonalWatchlistAlertEvaluator` 对齐。

验证：在 `macos-app/` 目录 `swift test`（项目基线全绿为标准）。

### 发布（遵循项目流程）

实现 → 提交功能代码（清晰中文标题）→ `swift test` 全绿 → 打 tag（`v3.13.0`，新增功能属 minor）→ 推送 main + tag → GitHub Actions 构建 + 回写 `releases/macos/latest.json`。

## 文件清单（新增）

| 文件 | 职责 |
|---|---|
| `macos-app/Core/Models/PortfolioValuationAlert.swift` | 数据模型（metric/side/direction/rule/profile/settings） |
| `macos-app/Core/PortfolioValuationAlertEvaluator.swift` | 纯函数评估器 + 文案 describe |
| `macos-app/Core/PortfolioValuationAlertStore.swift` | 持久化（profiles JSON） |
| `macos-app/Core/AppModel/PortfolioValuationAlert.swift` | AppModel 子逻辑（评估+发通知） |
| `macos-app/Views/PersonalAsset/PortfolioValuationAlertSection.swift` | 详情抽屉预警区块 |
| `macos-app/Views/PersonalAsset/PortfolioValuationAlertEditSheet.swift` | 预警编辑 sheet |
| `macos-app/Views/SettingsValuationAlertPanel.swift` | 设置中心面板 |
| `macos-app/Tests/PortfolioValuationAlertTests.swift` | 纯函数测试 |

## 文件清单（改动）

| 文件 | 改动 |
|---|---|
| `macos-app/Core/AppModel.swift` | 实例化 store、settings；`start()` 不加新循环 |
| `macos-app/Core/AppModel/PortfolioRefresh.swift` | `refreshPortfolioIfAutoRefreshVisible` 末尾挂 `evaluatePortfolioValuationAlerts` |
| `macos-app/Core/AppModel/PortfolioCRUD.swift` | 删除持仓时 `alertStore.remove(for:)` |
| `macos-app/Core/Models/ManagerWatchSettings.swift` | 通知深链新增 `.portfolioValuationAlert` case + 解析 |
| `macos-app/Views/PersonalAsset/PersonalAssetDetailSheet.swift` | `:57` 插入预警区块 |
| `macos-app/Views/SettingsSectionView.swift` | `SettingsFocus` 新增 `.valuationAlert` case + 状态/面板接入 |

## 非目标（YAGNI）

- 不支持自动下单交易（且慢 API 不支持）。
- 不存历史触发记录（只存 breached 去重状态）。
- 不抽取与 watchlist 共用的通用评估器（规则维度不同，收益有限）。
- 不做冷却期去重（采用滞回去重，已满足需求）。
