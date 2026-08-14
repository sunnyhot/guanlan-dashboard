# AKShare 本地 Collector（PROV-3a，ADR-DATA007 进程外隔离）

**进阶可选组件**：默认 App 与 iOS 不含本目录内容（SPM 已 exclude，`project.yml`
的 app target sources 也不含 `InvestmentIntelligenceV2/Collector/`）。想用 A 股
全量的 macOS 用户自行安装 Python + AKShare 后运行本脚本。

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
