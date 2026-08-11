# DATA007. External Collector Isolation

- **Status**: Accepted
- **Date**: 2026-08-11
- **Epic / Story**: Epic 1 / ADR-3；Epic 4 PROV-3

## Context

AKShare 是覆盖最全的免费 A 股 / 基金 / 债券 / 指数数据源，但它是 Python 库：

- 项目主架构是纯 Swift（`AGENTS.md` 第 3 条：不依赖 Python 或 localhost HTTP 服务）
- AKShare 依赖 pandas / lxml / requests 等 Python 生态，版本漂移、依赖冲突频发
- AKShare 调用偶尔崩（解析失败 / 网络异常 / 内存溢出），如果直接嵌入主进程会拖垮 SwiftUI App
- iOS 端无法运行 Python（`AGENTS.md` §iOS 视图说明）

如果让 Swift 主进程直接调 Python（如内嵌 PythonKit），会：

- **破坏纯 Swift 运行时**：违反 `AGENTS.md` 第 3 条，iOS 端彻底无法运行
- **故障传播**：Python 崩溃会拖垮整个 App
- **依赖管理噩梦**：Python 生态与 Swift SPM 各管各的，CI 复杂度爆炸

现有代码完全没有这条路径，AKShare 是 Epic 4 才引入的新基础设施。

备选方案：

1. **直接放弃 AKShare**：覆盖度不够，A 股 / 基金 / 债券很多标的没有 alternative 免费 source
2. **内嵌 PythonKit**：违反 `AGENTS.md` 第 3 条，iOS 端不可行
3. **进程外 Collector + JSONL staging**（本决策）：AKShare 作为独立 macOS 进程（Python 脚本 / CLI），Swift 主进程通过文件系统 JSONL spool 与之解耦，Collector 故障不传播到主进程

## Decision

**AKShare 只能作为 macOS 进程外 Collector，输出 JSONL staging 文件，Swift 主进程只读 staging。Collector 失败不影响主进程。**

1. **进程边界**（PROV-3）：
   - Collector 是独立 Python 进程（脚本 / CLI），可以独立启动、独立崩溃、独立升级
   - Collector 与 Swift 主进程的唯一接口是文件系统的 JSONL spool 目录（ProviderStaging，PROV-1）
   - Swift 主进程不 import Python，不内嵌 Python runtime

2. **iOS 不含 Collector**：
   - iOS 端不打包 Collector，不依赖 Python runtime
   - iOS 数据来源仅限 Swift 直接可访问的 Provider（且慢 / 天天基金 / Alpha Vantage 等 HTTP API）
   - macOS Collector 产出的 staging 可通过 iCloud / 手动同步给 iOS（后续 epic 评估）

3. **失败隔离**：
   - Collector 崩溃只丢失本次 staging，不影响主进程；主进程监控 staging 的新鲜度
   - Collector 卡死 / 超时由主进程的 watchdog 杀掉，不影响 UI 响应
   - Collector 输出非法 JSON 由 SchemaValidator 拒收（DATA003 Pipeline），不污染 Canonical

4. **staging 格式严格**：
   - JSONL 一行一条 ProviderRecord，字段严格匹配 PROV-1 定义的 schema
   - Collector 不写 Canonical，不直接写 GRDB；所有写入都过 commit pipeline（GRDB-8）
   - staging 带来源时间戳、collector version，便于审计

5. **多 dataset 覆盖**（PROV-3 8 点）：
   - Collector 支持 A 股股票 / ETF / 指数 / 基金 / 债券多类 dataset
   - 每个 dataset 独立 staging 文件，独立异常处理
   - 同一 Collector 进程可以并发抓多 dataset，但写入 staging 时分类清晰

## Consequences

- **Positive**：
  - Swift 主进程保持纯 Swift，iOS 可继续构建
  - Python 故障不传播，主进程稳定性高
  - Collector 可独立升级 / 重写 / 替换（如换 tushare 免费层），不影响主架构
  - staging 文件可独立审计 / 单测 / fixture

- **Negative**：
  - 双语言（Swift + Python）维护成本高
  - macOS 用户需要本机装 Python + AKShare（依赖说明复杂，影响安装体验）
  - 文件系统 staging 有同步延迟（不是实时），不适合 intraday 高频场景
  - Collector 是 macOS only，iOS 数据覆盖度受限

- **Neutral**：
  - Intraday 高频数据本就不在免费 Provider 覆盖范围（FREE001），文件系统延迟可接受
  - Collector 是 Epic 4 引入的新基础设施，现有代码不动

## Compliance Check

- **PROV-3 验收**：Collector 输出 staging，主进程通过 SchemaValidator 读取；任何主进程代码 `import Python` / 内嵌 Python runtime → 拒绝
- **iOS 构建验证**：iOS target 必须能独立构建，不依赖 Collector / Python
- **故障隔离测试**：模拟 Collector 崩溃 / 超时 / 输出非法 JSON，主进程不崩，staging 不污染 Canonical
- **`AGENTS.md` 第 3 条**：本 ADR 引入 Python 是「进程外 Collector」例外，必须在 `AGENTS.md` 注明（Epic 4 起更新）
- **PR checklist**：
  - 主进程代码出现 Python 调用 → 拒绝
  - Collector 直接写 GRDB → 拒绝（必须走 staging + Pipeline）
  - iOS target 引入 Python 依赖 → 拒绝

## References

- rollout §3 Epic 4 PROV-3
- `AGENTS.md` 第 3 条（纯 Swift 运行时）、iOS 视图说明
- 关联 ADR：
  - FREE001（Zero Paid Dependency）：AKShare 免费是选用根因
  - DATA003（Raw Market Canonicalization）：Collector 输出走 Pipeline
  - DATA004（Local Accumulation）：Collector 是历史 backfill 的主力
  - DATA006（Free Provider Fragility）：Collector 失败走三档降级
