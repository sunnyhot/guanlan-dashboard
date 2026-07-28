# 且慢主理人看板 — 设计系统规范

版本：1.1 | 更新：2026-07-28 | 对应代码：`Design/AppPalette.swift`

---

## 一、色彩体系

### 语义色（light / dark 独立调色，非反转）

| Token | 用途 | Light | Dark |
|---|---|---|---|
| `brand` | 品牌主色（按钮/链接/选中态） | `(0.16, 0.40, 0.88)` | `(0.31, 0.55, 1.00)` |
| `ink` | 主文字 | 近黑 | 近白 |
| `muted` | 次要文字/说明 | 中灰 | 浅灰 |
| `surface` | 基础背景 | 白/极浅灰 | 深灰 |
| `card` / `cardStrong` | 卡片背景 | 白 | 中深灰 |
| `hairline` | 分隔线/描边 | 浅灰 | 深灰 |
| `info` | 信息提示（蓝） | — | — |
| `positive` | 涨/正向（A 股红涨） | 深绿 | 亮绿 |
| `warning` | 警告 | 琥珀 | 亮琥珀 |
| `danger` | 跌/负向（A 股绿跌）/破坏性操作 | 深红 | 亮红 |
| `marketGain` | 行情涨色 | 红 | 亮红 |
| `marketLoss` | 行情跌色 | 绿 | 亮绿 |

### 规则
- **红涨绿跌**（A 股惯例），所有涨跌色必须走 `AppPalette.marketTint(for:)` 或 `marketGain/marketLoss`
- 文字色用 `ink`/`muted`，不用 `Color.primary`/`.secondary`（vibrancy 场景除外）
- 禁止硬编码 `Color.white`/`Color.black`；用语义色

### 涨跌色辅助函数
```swift
AppPalette.marketTint(for: profitAmount)   // Double → Color（正→gain，负→loss，零→muted）
AppPalette.marketTint(for: changePct)
```

---

## 二、字号阶梯

| Token (`AppFontSize`) | pt | 场景 |
|---|---|---|
| `.caption2` | 9 | 图表刻度/免责声明；不承载正文或操作说明 |
| `.caption` | 10 | badge 文字/时间戳/来源标注 |
| `.footnote` | 11 | 卡片说明/rationale/辅助信息 |
| `.subheadline` | 12 | 二级说明/摘要/正文下限 |
| `.body` | 13 | 列表标题/板块名/常规 UI 文字（主力） |
| `.headline` | 14 | 侧边栏项/按钮文字/section 标题 |
| `.title3` | 15 | 设置分区标题/弹窗标题 |
| `.title2` | 17 | 卡片大标题 |
| `.title` | 20 | 页面主标题 |
| `.largeTitle` | 24 | Onboarding 标题 |

### 用法
```swift
// 基础
.font(AppPalette.appFont(.body))

// 带字重
.font(AppPalette.appFont(.headline, weight: .bold))

// 自动响应 Bold Text 辅助功能
.font(AppPalette.appFontAdaptive(.body, weight: .medium))

// 等宽（代码/金额）
.font(AppPalette.appFont(.footnote, design: .monospaced))
```

### 规则
- **禁止** `.font(.system(size: N))` 硬编码字号
- 11pt 以下文字不承载正文、操作建议或风险说明
- 字重默认 `.regular`；标题/按钮 `.semibold` 或 `.bold`
- 金额/代码用 `design: .monospaced`；统计数字用 `design: .rounded`

---

## 三、间距阶梯

| Token | pt | 场景 |
|---|---|---|
| `spaceXS` | 4 | 图标与文字间距/badge 内边距 |
| `spaceS` | 8 | 卡片内元素间距/行内间距 |
| `spaceM` | 12 | 卡片间距/分区内部 |
| `spaceL` | 16 | 板块间距/内容边距（主力） |
| `spaceXL` | 20 | 大板块间距/onboarding 内边距 |
| `contentPadding` | 16 | 页面内容统一边距 |
| `toolbarPaddingH` | 16 | 工具栏水平边距 |
| `toolbarPaddingTop` | 16 | 工具栏顶部 |
| `toolbarPaddingBottom` | 14 | 工具栏底部 |

### 规则
- 禁止 off-grid 魔数（9/10/14/18/34 等）；统一走 token
- VStack/HStack `spacing` 优先用 token

---

## 四、圆角

| Token | pt | 场景 |
|---|---|---|
| `cardRadius` | 10 | 卡片/面板 |
| `panelRadius` | 12 | 大面板/sidebar |
| `controlRadius` | 8 | 按钮/输入框/选择器 |
| `badgeRadius` | 6 | 标签/badge |
| `iconBoxRadius` | 6 | 图标背景框 |
| `sidebarRowRadius` | 9 | 侧边栏行 |

---

## 五、表面层级与阴影

### 表面层级

| 层级 | 用途 | 推荐实现 |
|---|---|---|
| S0 | 窗口画布 | `surface` / 系统 window material |
| S1 | 页面分区 | 间距 + 标题，必要时使用 `SectionCard` 的弱底板 |
| S2 | 可交互分组 | `card` / `cardStrong.opacity(...)` + 弱描边 |
| S3 | 临时浮层 | Sheet、Popover、菜单，允许 material 与阴影 |

规则：

- 任意普通内容区域不超过三层可见表面。
- 普通 Section 不同时使用强背景、完整描边和阴影。
- 统计摘要优先使用 `MetricStrip`，不要拆成一排等权彩色卡片。
- 长篇 AI 或报告内容优先放入 `ReadingPanel`，正文宽度受控。

| 函数 | 用途 |
|---|---|
| `AppPalette.cardShadow()` | 少量需要抬升的卡片，默认 `0.08 / 8 / 2` |
| `AppPalette.subtleShadow()` | 临时 hover 或浮层反馈 |
| `AppPalette.panelShadow()` | 真正独立的大面板或浮层 |

普通 `SectionCard` 默认不使用阴影；`sectionShadow*` 与选中态 glow 保留为兼容 token，但当前值为关闭。侧边栏不使用投影模拟浮层。

---

## 六、动画

| Token | 时长 | 用途 |
|---|---|---|
| `motionFast` | 0.12s easeOut | 微交互（hover/选中） |
| `motionStandard` | 0.18s easeOut | 常规过渡（切换/展开） |
| `motionSection` | 0.20s easeInOut | 区段过渡 |
| `motionSlow` | 0.25s easeInOut | 大面积过渡 |
| `motionSpring` | interactiveSpring(0.24, 0.86) | 弹性交互（拖拽/滑动） |

### 规则
- 禁止裸时长 `.easeInOut(duration: 0.2)`；统一用 token
- `@Environment(\.accessibilityReduceMotion)` 为 true 时跳过动画

---

## 七、组件样式规范

### 按钮
| 样式 | 用途 | 示例 |
|---|---|---|
| `.appPrimary` | 主操作（刷新/生成） | 品牌色填充 |
| `.appSecondary` | 次操作（设置/取消） | 描边/浅底 |
| `.plain` | 图标按钮/链接 | 无背景 |

- `controlSize(.small)` → 紧凑模式（菜单栏/卡片内）
- 文字字号 `.headline`（14pt）+ `.semibold`
- Pressed 仅允许轻微缩放（当前 `0.98`）；hover 不上浮、不放大
- 系统 `Button`、`Toggle`、`Picker` 跟随系统 Accent Color；自定义主操作继续使用 `brand`

### 卡片
- 背景：`AppPalette.card.opacity(0.72)` 或必要时 `cardStrong`
- 圆角：`cardRadius`（10）
- 内边距：`spaceL`（16）或 `spaceM`（12，紧凑）
- 描边：`hairline.opacity(strokeSubtle)`（0.35）
- 阴影：普通内容卡片默认无；只给浮层或确有层级差的对象

### 输入框
- 圆角：`controlRadius`（8）
- 字号：`.body`（13pt）
- 焦点描边：`brand`
- 背景：`surface`

### 侧边栏行
- 圆角：`sidebarRowRadius`（9）
- 选中态：`selectionFill` + brand rail（3pt 宽）+ 弱描边
- hover：仅切换为 `cardHover`，`hoverLift` 固定为 0
- 图标底板仅在选中态出现
- 字号：`.headline`（14pt）
- badge：`.caption`（10pt）+ `.bold` + brand 胶囊
- 禁止 glow、位移和常驻悬浮阴影

### 空状态
- 标题：`.headline`（14pt）+ `.semibold`
- 说明：`.subheadline`（12pt）+ `muted`
- 背景：`cardStrong`

### Badge / Tag
- 字号：`.caption`（10pt）+ `.bold` + `design: .rounded`
- 内边距：`.horizontal(7)` + `.vertical(2)`
- 形状：`Capsule()`

### Toolbar

- 页面标题、连接状态与刷新操作使用原生 SwiftUI `.toolbar`。
- 不在内容区重复模拟标题栏或刷新栏。
- 标准 sidebar toggle、交通灯、拖动、缩放、全屏与 Split View 行为必须保留。
- 页面级状态文本可以与标题组合，但不能替代可访问的刷新按钮状态。

### 渐进披露

- AI 结论和可执行动作先出现，证据与触发条件使用 `DisclosureGroup`。
- 完整运行日志默认收起；生成中自动展开，生成完成后自动收起。
- 折叠标题显示数量、失败或异常状态，避免隐藏关键风险。

---

## 八、暗色模式 + 无障碍

### 暗色模式
- 所有颜色经 `adaptive(light:dark:)` 注册为动态 NSColor
- 用户可切 system / 浅色 / 深色（`AppAppearance`）
- 禁止固定色；用 `AppPalette` 语义色

### 无障碍适配

| 设置 | 适配方式 |
|---|---|
| **Reduce Motion** | `SharedComponents` 统一读 `@Environment(\.accessibilityReduceMotion)`，true 时跳过动画 |
| **Reduce Transparency** | `SidebarFloatingCompatModifier` 读 `@Environment(\.accessibilityReduceTransparency)`，true 时 material → `surface` 不透明 |
| **Bold Text** | `appFontAdaptive(isBoldText:)` 读 `@Environment(\.legibilityWeight)`，true 时升级字重到 `.bold` |
| **Increase Contrast** | `AppPalette.borderOpacity(isIncreasedContrast:)` 读 `@Environment(\.colorSchemeContrast)`，true 时描边加深 |

---

## 九、Material / Vibrancy

| 场景 | Material |
|---|---|
| 侧边栏背景 | `.sidebar` behindWindow |
| 工具栏背景 | `.windowBackground` withinWindow |
| 内容区叠加 | `.underWindowBackground` behindWindow (opacity 0.3) |
| 玻璃卡片 | `.ultraThinMaterial` |

### 规则
- Reduce Transparency 开启时所有 material 回退为 `surface` 不透明色
- 文字色在 material 上建议用 `.primary`/`.secondary`（自动 vibrancy）

---

## 十、禁止事项

1. ❌ `.font(.system(size: N))` — 用 `AppPalette.appFont(.body)`
2. ❌ `.padding(N)` off-grid — 用 `AppPalette.spaceS/M/L`
3. ❌ `Color.white` / `Color.black` — 用语义色
4. ❌ `.easeInOut(duration: 0.2)` 裸时长 — 用 `AppPalette.motion*`
5. ❌ 固定色不加 adaptive — 所有颜色走 `adaptive(light:dark:)`
6. ❌ 红绿灯遮挡 — 侧边栏顶部留 34pt 安全区
7. ❌ 无 .contextMenu 的列表行 — 关键交互元素要有右键菜单
8. ❌ 普通卡片使用 glow、hover lift 或多层黑色投影
9. ❌ 在内容区重复实现系统 toolbar
10. ❌ 将 AI 日志、依据和主结论默认同时展开
