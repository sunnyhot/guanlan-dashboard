# Remote Collector 服务端（PROV-3b，ADR-DATA010）

**VPS 侧组件**：本目录与 macOS App 包（`macos-app/`）完全分离——服务端
部署物不进 App / SPM / Xcode 工程，App 零 Python 依赖。App 端接收面是
`macos-app/InvestmentIntelligenceV2/Persistence/RemoteStagingProvider.swift`
（HTTP 拉取 + Ed25519 验签 + sha256 完整性 + SchemaValidator）。

**FREE001 受控让步声明**：本方案的 VPS 持续费用与长期 SRE 维护（监控 /
重启 / 封禁应对）是 FREE001（Zero Paid Dependency）的**显式受控让步**，
决策记录见 ADR-DATA010 §Consequences。引入任何新的付费依赖仍需先过
FREE001 审查。

## 数据流与发布布局

```
[VPS]                                          [App]
 akshare_collector.py（PROV-3a，定时抓取）      RemoteStagingProvider
  → staging（{dataset}.jsonl + manifest）        → 验签 + SchemaValidator
 remote_publish.py（本组件，发布）                → Pipeline → Canonical
  → snapshots/<ts>/ + snapshot.txt 原子指针    失败 → 降级原生 provider
```

发布根目录布局（nginx 托管发布根）：

```
{publish_root}/
  snapshots/<UTC 时间戳>/   # 一轮发布的完整快照：{dataset}.jsonl + manifest.json
                           # [+ manifest.sig]；落地后不可变，保留最近 5 个供回滚
  snapshot.txt             # 当前快照指针（tmp + rename 原子切换，内容 = 快照目录名）
```

- **快照固定读取**：客户端一次 sync 跨多次 HTTP 请求（manifest → 签名 → 文件），
  若每次都解析可变入口，中途发布会让批次混入两个快照（旧 manifest + 新签名 →
  误判篡改 + 断路器）。客户端只读一次 `snapshot.txt` 固定快照 ID，整批从
  `snapshots/<id>/` 不可变路径读取——nginx 直接托管发布根
- **事务边界**：manifest 与签名都在快照内完成后才切换 `snapshot.txt`——签名
  失败 / 中途崩溃只废弃该快照，线上服务的版本不受影响，不存在「新 manifest 配
  旧签名」的错配对
- **回滚**：把指针切回旧快照即可（原子写）：
  `printf '%s\n' <快照名> > snapshot.txt.tmp && mv snapshot.txt.tmp snapshot.txt`
- **硬链接约定**：staging 文件与快照共享 inode（`install_file` 优先 hardlink），
  线上不可变性依赖 collector 的 write-then-replace 整文件替换（`os.replace`
  换新 inode）。**不得原地修改 staging 目录下的文件**——那会经硬链接直接
  污染已上线快照的字节
- **manifest 只登记本轮通过校验的文件**（显式清单，不扫描目录）：失败 /
  未请求的旧 dataset 不会带着新 `generatedAt` 重新上架；`generatedAt` 取
  staging 声明的数据产出时间（新鲜度监控锚定数据本身）
- **staging 条目校验**：dataset 名在白名单内、文件名严格等于
  `{dataset}.jsonl`、resolve 后仍在 staging 目录内（挡绝对路径 / `../` 穿越）

## 威胁模型与验签分档

**验签强度分两档，生产必须 signed（发布器对 unsigned 发布打 stderr 告警）**：

- **signed（生产强制：`--signing-key` + App 端验签公钥都配齐）**：
  - 保证范围（显式收窄）：**静态托管目录 / nginx / 传输链被攻陷，且签名进程
    与私钥仍可信**时，最坏效果是 **rollback，不是数据伪造**——无私钥造不出
    能过验签的 manifest，只能把客户端指向 `snapshots/` 里已存在的旧快照。
    **完整 collector 主机失陷不在此保证内**：默认部署私钥（未加密 PEM,
    0600）与 collector/publisher 同机，主机失陷可读私钥、或在签名前替换
    staging，产出合法签名的伪造数据；若需覆盖整机失陷，签名须移到独立
    信任域（独立 signer 必须独立授权并核验待签内容——从**独立可信数据源**
    重采集/核验，或基于可信证据的人工在环审批；注意仅从被监护主机自取
    staging 重算 manifest 不充分（hash 一致 ≠ 数据真实性，伪造 JSONL 会被
    照单签名），也不能对被攻陷数据链主机提交的任意字节签名——否则只是把
    签名机退化成签名 Oracle；当前范围外）
  - **指针 `snapshot.txt` 本身不签名（signed 且私钥未失陷时的已知残余风险）**：
    能改写指针的一方（托管链攻陷、明文 HTTP 中间人）可指回旧快照。兜底：
    `manifest.generatedAt` 新鲜度监控（超 N 小时 → ProviderHealth
    `.degraded`，陈旧不冒充新鲜）；generatedAt 服务端严格解析（真实日历
    时间 + round-trip + 未来上界）+ **客户端独立时钟复核未来上界**（服务端
    同机校验对「collector 与 publisher 共用 VPS 时钟一起漂移」失效；客户端
    在下载任何文件前用本机 now() 复查，超过容忍度 fail-closed）——无法经
    发布链伪造
- **unsigned（仅测试 / 受信网络）**：不签名时 sha256 只对**同源 manifest**
  负责——攻陷方可同时改数据与 manifest 里的 sha256，客户端将**接受伪造
  数据**。此模式不提供对抗服务端攻陷的任何真实性保证（只防传输损坏/
  截断），不得用于生产
- **指针无法逃逸快照目录**：客户端对指针内容做白名单校验
  （`[0-9A-Za-z_-]{1,64}`，无 `/` 无 `..`），指向不存在的快照 → 404 →
  `unavailable` 降级，不是注入
- **建议 HTTPS**（Cloudflare 免费层即含）：明文 HTTP 下 rollback 风险扩大到
  路径上的中间人，而不只是服务端攻陷
- **慢客户端 vs prune（半批语义，如实声明）**：RemoteStagingProvider 按
  **单文件**粒度追加（文件 → sha 验证 → append → state checkpoint → 清
  journal）——若 sync 中途失败（如快照被清理后 fetchFile 404），**已完成的
  文件保留**，不会回滚（幂等：下轮经新 manifest 只补缺失文件，PIT 历史可信）。
  快照清理因此带**时间宽限期**（默认 24h 内不清理，另保最新 5 个 + 指针指向
  的）：日级 cron 下慢客户端正读的快照不可能被删，该场景实际不可达；
  宽限期需 ≥ 最长 sync 周期，`--grace-seconds` 可调

`akshare_collector.py` 的单一实现在 `macos-app/InvestmentIntelligenceV2/Collector/`
（App 侧可选组件，本地与远程两条链共用，字节级一致是跨语言契约的一部分）。
本脚本按以下顺序定位它（仅发布 / `--selftest` 路径需要；`--generate-key` 单文件
部署即可运行）：`--collector-script` 显式路径 → 本脚本同目录（**VPS 部署把两个
脚本放同一目录**）→ 仓库源码树默认位置（开发 / 契约测试）。

## 边界（DATA010 Compliance）

- **只处理公开市场数据**；用户私有凭证（且慢 cookie / 个人持仓）永不进入本链路
- staging 仍走 App 端完整 Pipeline（SchemaValidator → ObservationFactory →
  Canonical Commit），服务端不写 Canonical
- 空 staging（无 status=ok dataset）不切指针（线上继续服务上一轮快照，
  客户端靠新鲜度监控降级）

## VPS 部署

要求 Python ≥ 3.9（`Path.is_relative_to`）。cron 建议 flock 防并发 + 日志轮转：

```cron
# 依赖（akshare 抓取 + cryptography 签名）
pip3 install -r requirements.txt

# 1. 一次性：生成 Ed25519 签名密钥（stdout 的 base64 = App 端配置的公钥）
python3 remote_publish.py --generate-key /etc/collector/ed25519.pem

# 2. cron（收盘后）：collector 抓取 → 发布（签名）；flock 防上一轮未跑完叠加
17 15 * * 1-5 flock -n /var/run/collector.lock sh -c \
  'python3 /opt/collector/akshare_collector.py --out-dir /var/lib/collector/staging && \
   python3 /opt/collector/remote_publish.py --staging-dir /var/lib/collector/staging \
     --publish-dir /var/www/staging --signing-key /etc/collector/ed25519.pem' \
  >> /var/log/collector.log 2>&1
```

nginx 侧要点（完整配置按机器情况调整）：

- `location /staging/ { alias /var/www/staging/; }`——托管**整个发布根**
  （`snapshot.txt` 指针 + `snapshots/` 不可变历史）；**原样返回字节**
  （manifest.sig 签的是磁盘精确字节，禁用任何改写响应体的模块）
- 校验 `X-Collector-Key`（App 端 `URLSessionRemoteStagingFetcher` 携带），
  无/错 key 返回 403；配 `limit_req` 防白嫖（超限 429，客户端自动降级）
- 建议前置 Cloudflare 免费层（隐藏源 IP + Bot 防护，DATA010 §4）

## 离线自检

```bash
python3 remote_publish.py --selftest --publish-dir /tmp/publish [--signing-key KEY]
```

不联网、不依赖 akshare / staging 目录，固定样本走与生产完全相同的序列化 +
签名 + 落盘路径。跨语言契约测试 `RemotePublishContractTests.swift`（macos-app
Tests）即基于此：Python 产物 → Swift `RemoteStagingProvider` 端到端，包括
Ed25519（Python `cryptography` 签 → Swift CryptoKit 验）。

退出码：`0` 发布成功；`1` 没有任何 dataset 通过校验（不切指针）；
`2` 配置/环境错误（含找不到 akshare_collector.py、密钥不可读）。

## 客户端配置（App 端启用远程增强）

App 侧接收面已生产接线（`InvestmentIntelligenceV2/Sync/RemoteStagingSync.swift`
+ `Core/AppModel/RemoteStagingSyncLoop.swift`）：启动时读数据目录下的
`remote-staging-sync.json`，配置齐备才启动 sync 循环（立即一轮 + 每 6 小时；
增量比对，未变化轮次只拉一次 manifest）。**文件不存在 = 默认关闭**，零后台
任务、零网络行为。

配置文件路径：App 数据目录（默认
`~/Library/Application Support/QiemanDashboard/`，若 App 内设置了自定义数据
目录则以设置为准）下的 `remote-staging-sync.json`：

```json
{
  "enabled": true,
  "baseURL": "https://your-vps.example.com/staging",
  "collectorKey": "与 nginx 侧约定的一致",
  "signaturePublicKeyBase64": "`remote_publish.py --generate-key` stdout 打印的 base64"
}
```

- `baseURL`：nginx 托管的**发布根**（`snapshot.txt` + `snapshots/` 所在目录）
- `collectorKey` 可空（服务端未开鉴权时省略）
- `signaturePublicKeyBase64` 可空 = 该部署不验签（仅 sha256 完整性，仅限
  测试/受信网络——生产必须启用签名，见上方「威胁模型与验签分档」）
- **配错不静默**：`enabled=true` 但 baseURL 缺失/非法或公钥非法时，App 不会
  带着错误配置偷偷降级运行（也不会当成「未配置」），而是把配置错误写进
  诊断状态（`AppModel.remoteStagingSyncStatus` → misconfigured），修好配置
  重启 App 即可。sync 完成但个别文件被拒收（sha256 不符 / schema 非法）时，
  诊断状态保留拒收计数，不显示为干净成功

同步产物落 `数据目录/investment-intelligence-v2/remote-staging/`（spool.jsonl
+ state.json），供后续 Data Pipeline（GRDB-8）消费；spool 只追加合法记录，
失败轮次不影响已有数据。
