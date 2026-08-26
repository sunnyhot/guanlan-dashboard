# PKG001. InvestmentIntelligenceV2 暂不抽取独立 SPM package

- **Status**: Accepted
- **Date**: 2026-08-26
- **Epic / Story**: Epic 13 / PKG-1（评估并执行 SPM package 抽取）

## Context

PKG-1 要求在 M10（AGENT-2 完成后）按**已知依赖形状**评估是否把
`macos-app/InvestmentIntelligenceV2/` 抽取为独立
`InvestmentIntelligenceKit` package（「不是猜形状抽」）。AGENT-2 落地后，
消费方与依赖形状首次完整可见。

实测形状（2026-08-26，grep 全仓库）：

**V2 → Core（引擎对宿主的依赖）**：

| 依赖 | V2 内引用文件数 | 性质 |
|---|---|---|
| `AlphaVantageClient` / `AlphaVantageSettings` | 4 / 3 | 行情传输 + 凭据值类型 |
| `SECOfficialSourceClient` / `SECOfficialSourceCache` | 3 / 3 | SEC 传输 + 公平访问缓存 |
| `TavilySearchClient` | 3 | web 搜索传输 |
| `OpenAICompatibleAgentClient` + Agent 契约层（AgentChatMessage 等） | 2 + 1 | LLM 传输 + 消息契约 |
| `TrendAIProviderSettings`（DataSourceSettings） | 1 | Provider 配置值类型 |
| `KeychainHelper` | 1（M2MarketEvidenceSource，测试证据源） | Keychain 封装 |

**Core / Views → V2（宿主对引擎的消费，非测试）**：共 6 个文件——
`Core/AppModel/AttributionV2Bridge` / `InvestmentIntelligenceV2Runtime` /
`MarketDataSync`、`Core/CLI/InvestmentAgentCLI`、`main.swift`、
`Views_macOS/Intelligence/IntelligenceSectionView`（另有 Tests 全套）。

消费方形态：macOS App 与 `investment-agent` CLI 共享同一 SPM target
（同一模块；CLI 经 main.swift 双模式入口实现，没有为 agent 建独立
target）；iOS App 经 xcodegen 的 Xcode 工程编入**同一源集**（非 SPM
target，但源文件共享面相同）。

备选方案与代价：

1. **立即抽取**：V2 → `InvestmentIntelligenceKit` package。
   - V2 依赖的 Core/Clients 传输层必须随之迁移进 package（或抽象成
     protocol 注入——6 个客户端 + 配置值类型 + 诊断日志层，迁移面比 V2
     本身还大）；Core/Clients 同时被 App 的非 V2 路径消费（qieman 平台
     抓取等），迁移会反向撕裂 Core。
   - 宿主侧 6 个消费文件 + 全部测试需补 `import InvestmentIntelligenceKit`；
     Xcode 工程（xcodegen 双 target sources）与 SPM 双构建链要重新对齐。
   - 收益：模块边界编译期强制。但 V2 与 Core 的边界纪律当前靠目录隔离 +
     review + 测试维持（rollout §2.3），实测无违规（V2 内唯一的 AppModel
     字样是注释；KeychainHelper 仅测试证据源使用）。
2. **暂不抽取，条件触发重评**（本决策）。
3. ~~抽部分（只抽无 Core 依赖的子目录）~~：依赖图是纵切（Research/
   Providers 直接用 Clients），按目录横切会产出一个残缺 package，
   违反「按已知形状切」。

## Decision

**暂不抽取**。系统保持单模块（`QiemanDashboard` SPM target 同时编入
V2 + Core + Views + agent CLI）；V2 与 Core 的隔离继续按 rollout §2.3
的目录 + review + 测试纪律维持。

重评触发条件（满足任一即修订本 ADR）：

1. 出现**第三个独立二进制**消费方且无法用 main.swift 双模式入口覆盖
   （如 AGENT-3 XPC daemon 立项，或 watch/widget 扩展）；
2. V2 → Core 的依赖面开始侵蚀边界纪律（如 V2 引用 Views / AppModel /
    ObservableObject 状态容器被 review 拦截两次以上）；
3. 构建时长使 V2 与 App 的迭代互相拖累（增量编译实测）。

## Consequences

- **Positive**：零迁移成本；agent CLI 与 macOS App 共享同一模块（无
  import / 工程对齐税）；iOS 经同一源集共享（xcodegen 工程）；依赖形状
  保持可测（本 ADR 的实测数据即基线）。
- **Negative**：V2 ↔ Core 的边界只能靠纪律维持（编译器不强制）；
  将来若触发抽取，Core/Clients 的迁移是主要成本，需单独 story。
- **Neutral / Neutrality Risks**：AGENT-3（XPC daemon，可选）若立项会
  直接命中重评触发条件 1——届时先修订本 ADR 再动代码。

## Compliance Check

- 每个 V2 PR review 检查项：`InvestmentIntelligenceV2/` 内不引用
  SwiftUI/AppKit/AppModel（grep `import SwiftUI|import AppKit|AppModel`
  应只剩注释命中）；
- `swift test` 全绿（含 V2 套件）+ 双端构建通过（既有基线）；
- 违反时：能就地改的就地改；确需跨边界的，先修订本 ADR（把依赖列入
  实测表）再合 PR。

## References

- `docs/investment-intelligence-rollout.md` §2.3 目录约定与隔离原则、
  Epic 13 PKG-1 story
- `AGENTS.md`（V2 目录约定、构建链）
- ADR-DATA007 / DATA010（Collector 已采用的进程外隔离——抽取之外的
  另一种解耦形态先例）
