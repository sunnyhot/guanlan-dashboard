# Remote Collector 服务端（PROV-3b，ADR-DATA010）

**VPS 侧组件**：与本目录与 macOS App 包（`macos-app/`）完全分离——服务端
部署物不进 App / SPM / Xcode 工程，App 零 Python 依赖。App 端接收面是
`macos-app/InvestmentIntelligenceV2/Persistence/RemoteStagingProvider.swift`
（HTTP 拉取 + Ed25519 验签 + sha256 完整性 + SchemaValidator）。

## 数据流

```
[VPS]                                          [App]
 akshare_collector.py（PROV-3a，定时抓取）      RemoteStagingProvider
  → staging（{dataset}.jsonl + manifest）        → 验签 + SchemaValidator
 remote_publish.py（本组件，发布）                → Pipeline → Canonical
  → nginx 托管目录（manifest + 签名）            失败 → 降级原生 provider
```

`akshare_collector.py` 的单一实现在 `macos-app/InvestmentIntelligenceV2/Collector/`
（App 侧可选组件，本地与远程两条链共用，字节级一致是跨语言契约的一部分）。
本脚本按以下顺序定位它：`--collector-script` 显式路径 → 本脚本同目录（**VPS
部署把两个脚本放同一目录**）→ 仓库源码树默认位置（开发 / 契约测试）。

## 边界（DATA010 Compliance）

- **只处理公开市场数据**；用户私有凭证（且慢 cookie / 个人持仓）永不进入本链路
- staging 仍走 App 端完整 Pipeline（SchemaValidator → ObservationFactory →
  Canonical Commit），服务端不写 Canonical
- 空 staging（无 status=ok dataset）不覆盖旧 manifest（保留上一轮有效发布，
  客户端靠新鲜度监控降级）

## VPS 部署

```bash
# 依赖（akshare 抓取 + cryptography 签名）
pip3 install -r requirements.txt

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
签名 + 落盘路径。跨语言契约测试 `RemotePublishContractTests.swift`（macos-app
Tests）即基于此：Python 产物 → Swift `RemoteStagingProvider` 端到端，包括
Ed25519（Python `cryptography` 签 → Swift CryptoKit 验）。

退出码：`0` 发布成功；`1` 没有任何可发布 dataset（不覆盖旧 manifest）；
`2` 配置/环境错误（含找不到 akshare_collector.py、密钥不可读）。
