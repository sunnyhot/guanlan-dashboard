# AKShare Collector 工具集（PROV-3a 本地方案 + PROV-3b 远程发布器）

**进阶可选组件**：默认 App 与 iOS 不含本目录内容（SPM 已 exclude，`project.yml`
的 app target sources 也不含 `InvestmentIntelligenceV2/Collector/`）。想用 A 股
全量的 macOS 用户自行安装 Python + AKShare 后运行本脚本。

| 文件 | 角色 |
|---|---|
| `akshare_collector.py` | 本地 Collector（PROV-3a，ADR-DATA007 进程外隔离） |
| `remote_publish.py` | 远程 staging 发布器（PROV-3b 服务端，ADR-DATA010） |

## 边界（DATA007 Compliance）

- Collector 是独立 Python 进程（本脚本），与 App 进程唯一接口是 staging 输出目录
  （JSONL + manifest.json）。App 进程不 import Python、不内嵌 Python runtime。
- 只产 `ProviderRecord`（PROV-1 schema）到 staging，**不写 Canonical / GRDB**；
  Canonical 化由 Swift Pipeline（SchemaValidator → ObservationFactory → Commit）完成。
- iOS 永不运行 Collector；iOS 数据来源仅限 Swift 直连 Provider。
- Collector 崩溃 / 超时只丢本轮 staging，不影响 App（调用方负责 watchdog 超时杀进程，
  见 Swift 侧 `AKShareLocalCollectorLauncher`）。

## 安装（可选）

```bash
pip3 install -r requirements.txt
```

## 运行

```bash
# 离线自检（不联网、不需要 akshare；跨语言契约测试同款路径）
python3 akshare_collector.py --out-dir /tmp/akshare-staging --selftest

# 正式抓取（默认配置：600519/000858 个股、沪深300/中证500、110022 净值+持仓、GDP）
python3 akshare_collector.py --out-dir ~/Library/Application\ Support/QiemanDashboard/akshare-staging

# 自定义标的 + 窗口
python3 akshare_collector.py --out-dir <dir> --config collector_config.example.json \
  --start-date 20240101 --end-date 20241231
```

输出目录产物：

- `{dataset}.jsonl` —— 每 dataset 一文件，一行一条 ProviderRecord（Swift Codable
  字节对齐：camelCase / ISO8601 UTC / enum rawValue / rawPayload base64）
- `manifest.json` —— 每 dataset 的 status / recordCount / droppedMalformed /
  errorCategory / errorMessage / sha256（Swift 侧 `AKShareStagingManifest` 消费）

退出码：`0` 全部成功；`1` 部分/全部 dataset 失败（manifest 仍落盘，失败原因可诊断）；
`2` 环境错误（缺 akshare / 配置不可读 / 未知 dataset）；超时无退出码（被 watchdog 杀）。

## dataset 覆盖（DATA007 §Decision 5 多 dataset + 独立异常处理）

| dataset | AKShare 接口 | ProviderRecord kind | providerCode scheme |
|---|---|---|---|
| `stock_daily` | `stock_zh_a_hist`（adjust='' raw 不复权） | DAILY_BAR | `stock_symbol` |
| `index_daily` | `index_zh_a_hist` | DAILY_BAR | `index_code` |
| `fund_nav` | `fund_open_fund_info_em`（单位+累计净值按日合并） | NAV_OBSERVATION | `fund_code` |
| `fund_holdings` | `fund_portfolio_hold_em`（按季度聚合） | FUND_HOLDING_SNAPSHOT | `fund_code` |
| `macro_china` | `macro_china_gdp_yearly` 等 | MACRO_OBSERVATION | `ak_macro_series` |

PIT 口径：AKShare 宏观 / 持仓无公布时间字段，`publishedAt = effectiveAt`（与
Swift 侧 `EastmoneyHoldingRecordBuilder` 同惯例，不发明时间）；精确公布时间由
FRED 链路（realtime_start）负责。A 股日期归一化到 Asia/Shanghai 当日 00:00 的
UTC 瞬时，与 Swift `EastmoneyResponseParser.normalizeToTradingDay` 一致。

## Swift 侧对接

- `macos-app/InvestmentIntelligenceV2/Providers/AKShareLocalCollector.swift`
  （staging manifest 模型 + 失败隔离的 staging 摄取 + 仅 macOS 进程外 launcher）
- 跨语言契约测试：`AKShareCollectorContractTests.swift`（`--selftest` 输出 →
  ProviderStagingReader → SchemaValidator → ObservationFactory 全链路）

---

# remote_publish.py（PROV-3b 远程发布器，ADR-DATA010）

**默认路径的服务端组件**：VPS 上跑 collector 抓公开数据 → 本发布器产 nginx 可
托管的 staging → App 通过 `RemoteStagingProvider` HTTP 拉取 + 验签 + SchemaValidator。
App 零 Python 依赖；本地 Collector（上文）保留为进阶备选。

## 边界（DATA010 Compliance）

- **只处理公开市场数据**；用户私有凭证（且慢 cookie / 个人持仓）永不进入本链路
- staging 仍走 App 端完整 Pipeline（SchemaValidator → ObservationFactory →
  Canonical Commit），服务端不写 Canonical
- 空 staging（无 status=ok dataset）不覆盖旧 manifest（保留上一轮有效发布，
  客户端靠新鲜度监控降级）

## VPS 部署链（cron 示例）

```bash
# 1. 一次性：生成 Ed25519 签名密钥（stdout 的 base64 = App 端配置的公钥）
python3 remote_publish.py --generate-key /etc/collector/ed25519.pem

# 2. cron（收盘后）：collector 抓取 → 发布（签名）
python3 akshare_collector.py --out-dir /var/lib/collector/staging
python3 remote_publish.py --staging-dir /var/lib/collector/staging \
  --publish-dir /var/www/staging --signing-key /etc/collector/ed25519.pem
```

nginx 侧要点（完整配置按机器情况调整）：

- `location /staging/` 静态托管 publish 目录；**原样返回字节**（manifest.sig
  签的是磁盘精确字节，禁用任何改写响应体的模块）
- 校验 `X-Collector-Key`（App 端 `URLSessionRemoteStagingFetcher` 携带），
  无/错 key 返回 403；配 `limit_req` 防白嫖（超限 429，客户端自动降级）
- 建议前置 Cloudflare 免费层（隐藏源 IP + Bot 防护，DATA010 §4）

## 离线自检

```bash
python3 remote_publish.py --selftest --publish-dir /tmp/publish [--signing-key KEY]
```

不联网、不依赖 akshare / staging 目录，固定样本走与生产完全相同的序列化 +
签名 + 落盘路径。跨语言契约测试 `RemotePublishContractTests.swift` 即基于此：
Python 产物 → Swift `RemoteStagingProvider`（验签 / sha256 / 增量 / SchemaValidator）
→ spool 端到端，包括 Ed25519（Python `cryptography` 签 → Swift CryptoKit 验）。

签名依赖 `cryptography` 库（`pip3 install cryptography`，仅签名部署需要；
无签名部署与 `--selftest` 不引入）。
