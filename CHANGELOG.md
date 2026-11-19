# Changelog

## [5.0.2] - 2026-11-19

### Added
- 菜单栏“黄金·汇率”新增上海银 Ag(T+D) 国内行情，以元/千克展示最新价、涨跌和报价时间，并与伦敦银的 USD/oz 单位区分。

## [5.0.1] - 2026-11-19

### Added
- 菜单栏“黄金·汇率”新增上海金 Au99.99 国内现货行情，以元/克展示最新价、涨跌和报价时间，并与伦敦金的 USD/oz 单位区分。

### Fixed
- 完善 Homebrew 升级命令与发布同步，Release 自动更新 cask 的版本号和 ZIP SHA256。

## [5.0.0] - 2026-11-18

### Changed
- 盘中研判统一为行情、新闻、持仓三路分析加汇总决策的 3+1 子 Agent，移除 V1 单 Agent 和全市场机会雷达；接入真实行情与基金穿透证据，最终报告在证据修复后重新校验，证据不足一律降级为持有。
- 长期研判支持安全的自动补做；收盘复盘仅在当天补做，失败窗口不自动重试，避免重复扣费。
- 移除旧每日调度、L6 市场信号、L7 市场研究流水线、L8 策略回测、TrendTracking 及 DecisionCase 历史迁移。
- 盘中动作统一为 buy / sell / hold；趋势报告与 DecisionCase 仅接受 schemaVersion=2，v1 数据明确拒绝加载。
- 修正旧风控、证据绑定、行情新鲜度与退役功能相关文案，更新贡献者文档和行为基线。

## [2.5.6] - 2026-05-21

### Fixed
- 修复收到推送通知后 createMainWindow() 在后台线程崩溃 (SIGABRT) (LUC-195)
  - 在 AppModel.init() 的 Combine 订阅中添加 .receive(on: DispatchQueue.main)

## [2.5.5] - 2026-05-21

### Fixed
- 开机自启动后，若设置中 Dock 为不显示，自动隐藏 Dock 图标 (LUC-187)
  - 在 `applicationDidFinishLaunching` 中立即读取 UserDefaults 并设置 activationPolicy

## [2.5.4] - 2026-05-21

### Fixed
- 改进浅色模式对比度

## [2.5.3] - 2026-05-20

### Fixed
- 防止个人资产表格重叠
- 构建脚本增加产物完整性验证

## [2.5.2] - 2026-05-20

### Fixed
- QiemanDashboardApp 编译错误修复
- latest.json 指向正确版本

## [2.5.1] - 2026-05-20

### Fixed
- 解决 AppModel 合并冲突
- 去掉 clipShape 避免裁剪表格详情内容
