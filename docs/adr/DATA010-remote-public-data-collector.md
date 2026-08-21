# DATA010. Remote Public-Data Collector（VPS 部署方案）

- **Status**: Accepted（2026-08-21 随 PROV-3b 实施主体落地：客户端
  RemoteStagingProvider + 服务端 `remote-collector/` 发布器 + 离线跨语言
  契约测试；VPS 真实部署与 HTTP 端到端验收跟踪在 rollout PROV-3b 剩余项，
  不影响本架构决策生效）
- **Date**: 2026-08-12（Proposed）/ 2026-08-21（Accepted）
- **Epic / Story**: Epic 4 / PROV-3b

## Context

DATA007 规定 AKShare 只能作为**进程外 Collector**（本地 Python 进程 + JSONL staging）。
但本地 Collector 落地有两个硬障碍（见 rollout 2026-08-12 讨论）：

1. **分发困境**（DATA007 §Consequences Negative 已承认但未解决）：
   - 方案 A（用户自备 Python + pip install akshare）：且慢用户是普通投资者，
     装 Python + pandas/lxml 几乎不可能，C 端功能报废
   - 方案 B（PyInstaller 嵌入 bundle）：App 体积翻 2-3 倍（+80-150MB），CI 复杂化
   - 方案 C（独立工具单独分发）：进阶用户各取所需，但默认 App 无 A 股全量
2. **iOS 不可用**：DATA007 §Decision 2 明确 iOS 不含 Collector

讨论中评估了 **D（服务端 Collector）**：VPS 上跑 Python collector 抓 AKShare **公开数据**，
nginx 托管 JSONL staging，App 通过 HTTP 拉取。本 ADR 把 D 的边界、安全、降级定死。

### 关键前提：只做公开数据

本方案**只覆盖 AKShare 的公开市场数据**（A 股行情、基金净值、指数、宏观）。
**用户私有数据（且慢持仓、个人资产、cookie 登录态）永不走服务端**——凭证集中化
是致命风险（服务端成单点攻破 = 全用户金融账号沦陷），个人开发者无力承担。
私有数据链永远本地（现有 QiemanNativeClient 带 cookie 直连）。

## Decision

**VPS 上部署 Python collector 抓公开数据 → nginx 托管 JSONL staging（复用 PROV-1 schema）
→ App 通过 RemoteStagingProvider 拉取 + 验签 + SchemaValidator。客户端三档降级，
服务端不可用时不影响 App 基础功能。**

### 1. 数据流与职责边界

```
[VPS]                                    [App]
 collector.py（akshare，定时）            RemoteStagingProvider
  → ProviderRecord JSONL（PROV-1 schema）  → 验签 + SchemaValidator
  → manifest.json（sha256 + 签名）          → Pipeline → Canonical
 nginx 静态托管 + 鉴权                     失败 → 降级到原生 provider
```

- 服务端是 **App 的专属私有后端**，不是公开数据源
- Python 产出的 JSONL 必须**字节对齐** Swift `ProviderRecord` 的 Codable：
  `iso8601` 日期、camelCase 字段、枚举 rawValue（`DAILY_BAR` 等）、
  `rawPayload` base64 编码。契约由跨语言测试守护（PROV-3b 验收）

### 2. 反爬：聚合去重优先

服务端 collector 的反爬核心是**用缓存把高频压成低频**——同一基金净值一天抓一次，
所有用户共享。单 IP 低频反而比多 IP 高频安全。手段按性价比：

| 手段 | 作用 |
|---|---|
| 聚合缓存（治本）| 同一标的收敛到 1 次抓取 + 全局共享，源站压力降到最低 |
| 请求 jitter + 并发上限 | 随机延迟、单源同时上限，避免模式识别 |
| 收盘数据日级抓取 | 不做日内轮询，历史数据只回填一次后增量 |
| 多源冗余 | 东财主、新浪/同花顺备，主源异常 collector 内部切 |
| 尊重 429/503/Retry-After | 不硬冲 |

定位是「礼貌的公开数据缓存代理」，不是「暴力爬虫」。
单 VPS 单 IP 是短板；务实先单 IP + 严格限频跑，被封禁再考虑多区域出口。

### 3. 降级：客户端绝不单点依赖

App **始终保留 Swift 原生 provider 作为 fallback**。三层：

```
① 服务端 staging（新鲜全量 A 股）  ← primary，挂了才降级
        │ 挂 / 封 / 超时 / 熔断
        ▼
② 本地原生 provider（且慢/天天基金/Stooq/FRED 直连 HTTP）  ← secondary，本就能用
        │ 也没有
        ▼
③ 标 unavailable，不伪造（DATA006 缺口语义）  ← UI 告知「数据暂缺」
```

- staging 新鲜度监控（DATA007 已设计）：超 N 小时未更新 → ProviderHealth `.degraded`
- 客户端断路器：连续失败指数退避，触发后一段时间直接走 ②，避免疯狂重试
- 优雅降级到「只读历史」：服务端挂了，本地已有 staging 仍可用于历史分析/回测
  （PIT 语义保证历史可信，新鲜度问题不污染历史）
- **降级的额外红利**：正因为客户端能降级，服务端被滥用/异常时可果断关端点止损

### 4. 鉴权与反白嫖

服务端是 App 专属后端，鉴权目的是**保护 VPS 资源不被白嫖**（数据本就公开）：

```
Cloudflare 免费层（隐藏源 IP + Bot 防护）
    ↓
nginx 校验 X-Collector-Key（App 内置，版本化可轮换）
    ↓
per-key 限流 + 总带宽 cap
    ↓
异常流量监控 → 自动 503（客户端降级）
```

- 挡随机路人（无 key）、自动化扫描（CF + key）、单点滥用（限流 + 熔断）
- key 提取门槛（反编译 App）远高于「自己用 AKShare 抓公开数据」的收益，不值得破解
- per-token 鉴权（device token）留作未来选项，当前 overkill

### 5. 完整性：验签防注入

- manifest.json 含每个 staging 文件的 sha256 + 产出时间 + collectorVersion
- App 先拉 manifest，比对本地已有 hash，只下载变化的文件（增量）
- 可选：manifest 用 Ed25519 私钥签名，App 内置公钥验签——即使 VPS 被攻陷、
  nginx 被替换，攻击者无私钥也无法伪造能过验签的 staging
- SchemaValidator（PROV-1）是完整性兜底：即使签名层失效，结构非法的 staging 仍被拒
- **验签强度分档（生产必须 signed）**：
  - **signed（生产强制）**：服务端 `--signing-key` + 客户端验签公钥都配置。
    VPS/nginx 被攻陷的最坏效果是 **rollback**——攻击者无私钥伪造不了能过验签
    的 manifest，只能把客户端指向旧快照（旧 manifest + 旧签名对仍验签通过），
    数据真实性不受影响
  - **unsigned（仅测试 / 受信网络）**：不配置签名时，sha256 只对「同源
    manifest」负责——攻陷方可同时改数据与 manifest 里的 sha256，客户端将
    **接受伪造数据**。「最坏 rollback」的结论**只适用于 signed 模式**；
    unsigned 模式不提供对抗服务端攻陷的任何真实性保证（只防传输损坏/截断），
    生产部署缺任一侧签名配置视为配置错误（发布器对 unsigned 发布打stderr告警）
- **残余风险（signed 模式下显式接受）**：快照指针 `snapshot.txt` 本身不签名
  ——最坏效果是被指回旧快照（rollback）；新鲜度由 `generatedAt` 监控兜底
  （客户端超时 → degraded，陈旧不冒充新鲜；服务端严格解析 + fail-closed，
  无法经发布链伪造）。实施细节与完整威胁模型见 `remote-collector/README.md`
- **批次一致性**：客户端只读一次指针固定快照 ID，manifest / 签名 / 文件整批
  从 `snapshots/<id>/` 不可变路径读取——并发发布不会让一次 sync 混入两个
  快照（防「旧 manifest + 新签名」误判篡改）；快照清理带时间宽限期，
  慢客户端正读的快照不会被删

## Consequences

- **Positive**：
  - App 默认零 Python 依赖，纯 Swift，人人能用；A 股全量作为「拉取增强」
  - 服务端聚合去重对源站更友好，反爬风险可控
  - 客户端三档降级复用现有 DATA006/ProviderHealth/PIT 体系，服务端故障不致命
  - 聚合缓存效率远高于 N 用户各自本地抓
  - Python 侧 schema 一旦对齐，Swift 接收侧零特殊代码（复用 PROV-1 Reader + Validator）

- **Negative**：
  - **FREE001 让步**：VPS 要持续付费 + 长期 SRE 维护（监控/重启/封禁应对）。
    这是个人开发者要明确承担的负担，不是一次性工作
  - 双语言（Swift + Python）维护，schema 对齐是高风险点，需跨语言契约测试守护
  - 服务端单点：VPS 挂了全部用户断 A 股全量（降级到原生 provider，不致命但有损）
  - 带宽成本随用户数增长；鉴权/限流不当会被白嫖
  - 仍然 macOS only 有效（iOS 拉远程 staging 可行，但首次需联网）

- **Neutral**：
  - 服务端 collector 和 App 完全解耦：未来换回本地 collector（DATA007 PROV-3a）
    客户端侧几乎不用改，只是数据来源从「远程 HTTP」换成「本地文件」
  - 公开数据缓存对源站压力小，法律/伦理风险低（不做付费数据、不高频轰）

## 与其他 ADR 的关系

- **DATA007（进程外 Collector）**：本 ADR 是 DATA007 的「远程部署变体」。
  DATA007 的本地 collector 方案保留为 PROV-3a（备选/进阶），本方案为 PROV-3b（默认）
- **FREE001（Zero Paid Dependency）**：VPS 付费是 FREE001 的**受控让步**。
  PROV-3b 实施前须在 PR 声明此让步，并在 AGENTS.md 注明「远程 collector 服务端」例外
- **DATA003（Raw Canonicalization）**：服务端 staging 仍走完整 Pipeline（SchemaValidator
  → Factory → Canonical Commit），不绕过任何防火墙
- **DATA006（Free Provider Fragility）**：服务端故障走三档降级（本 ADR §3）
- **DATA004（Local Accumulation）**：服务端是历史 backfill 的主力，历史抓过永久缓存

## Compliance Check

- **PROV-3b 验收**：
  - 跨语言契约测试：collector 产出的样本 JSONL 在 Swift 侧 Reader → SchemaValidator →
    ObservationFactory 全链路通过（守护 schema 对齐）
  - 降级测试：模拟服务端 503/超时/签名失败，App 降级到原生 provider 不崩
  - 鉴权测试：无 key / 错 key / 超限流 → 403/429，App 降级
- **凭证边界**：任何用户私有凭证（且慢 cookie）出现在服务端代码/配置 → 拒绝
- **完整性**：staging 被篡改（sha256 不符 / 验签失败）→ 拒收 + 降级
- **iOS**：iOS target 不引入 Python；iOS 可拉远程 staging（联网时）
- **PR checklist**：
  - 服务端代码出现用户私有数据抓取 → 拒绝
  - App 单点依赖服务端（无原生 provider fallback）→ 拒绝
  - staging 绕过 SchemaValidator 直接入 Canonical → 拒绝

## References

- rollout §3 Epic 4 PROV-3b
- 关联 ADR：DATA007（本地 Collector 备选）、FREE001（付费让步）、
  DATA003（Pipeline）、DATA006（降级）、DATA004（backfill）
