# 且慢主理人看板 — 数据同步协议(v1)

> 冻结版契约。客户端(SyncClient)、服务端(server.ts)、密文格式(ArchiveCipher)
> 均以此为准。改动需升 schemaVersion/cipherVersion。

## 1. 设计原则

- **端到端加密(E2EE)**:客户端用密码加密整个 payload,服务端只存密文 blob。
  服务端对**同步内容零知识**,但能看到 groupId/deviceId/IP/时间/blob 大小。
- **手动全量覆盖**:不做字段级合并。上传覆盖云端,下载覆盖本机。
- **无 Apple 账号依赖**:不依赖 iCloud/CloudKit,自建服务,用 AirDrop/网络传输。

## 2. 身份模型

| 字段 | 用途 | 谁生成 | 存哪 |
|---|---|---|---|
| `groupId` | 定位共享 blob(多设备共享同一份) | 服务端(register 时生成) | UserDefaults |
| `deviceId` | 来源设备审计 | 服务端(register 时生成) | UserDefaults |
| `accessToken` | 控制读/写权限(Bearer) | 服务端(register 时生成) | **Keychain** |
| 同步密码 | 加密 payload(永不上传服务端) | 用户设置 | **Keychain** |

**accessToken 不能用同步密码代替**。accessToken 是传输层鉴权,密码是内容层加密。
服务端看不到密码,客户端不拿 accessToken 解密。

## 3. HTTP API

Base URL 由用户在设置页配置(强制 HTTPS;Debug 允许 localhost HTTP)。

### POST /v1/groups — 注册同步组
注册一个新的同步组(或已存在则重新生成 token)。
- 请求: `{ "passwordHash": "<PBKDF2(password, salt)>" }`(可选,用于服务端校验密码一致性,非必须)
- 响应: `201`
  ```json
  { "groupId": "g_abc123", "deviceId": "d_xyz789", "accessToken": "tok_..." }
  ```
- 同步组内多设备共享同一 groupId,各自 deviceId 不同,token 可相同(简化首版)。

### GET /v1/groups/:groupId/blob — 拉取密文
- Header: `Authorization: Bearer <accessToken>`
- 响应: `200`
  ```json
  {
    "revision": 5,
    "serverTimestamp": "2026-08-03T12:00:00Z",
    "sourceDeviceId": "d_xyz789",
    "blob": "<base64 密文>"
  }
  ```
- 无数据时 `404`(组存在但未上传过 blob)。
- 鉴权失败 `401`;组不存在 `404`。

### PUT /v1/groups/:groupId/blob — 上传密文(覆盖)
- Header: `Authorization: Bearer <accessToken>`
- Header: `If-Match: <客户端已知的 revision>`(乐观锁,首次上传可不带)
- 请求:
  ```json
  { "blob": "<base64 密文>", "sourceDeviceId": "d_..." }
  ```
- 响应: `200`
  ```json
  { "revision": 6, "serverTimestamp": "2026-08-03T12:01:00Z" }
  ```
- revision/timestamp **服务端生成**,不信客户端时间。
- `If-Match` 不匹配(云端已是更新版)→ `409 Conflict`(客户端提示用户「云端有更新版,是否仍然覆盖」)。

## 4. 密文格式(二进制,AAD 认证)

```
偏移   长度    字段
0      4       magic = "QMDB"
4      1       cipherVersion = 1
5      1       kdfIDLen
6      N       kdfID = "PBKDF2-SHA256"
6+N    4       iterCount (UInt32 BE, 初始 600000)
10+N   1       saltLen (32)
11+N   32      salt
43+N   1       nonceLen (12)
44+N   12      nonce
56+N   M       ciphertext + GCM tag (16B)
```

**头部(0 到 nonce 结束)作为 AES-GCM 的 AAD(authenticated additional data)一起认证**。
篡改任何头部字段 → GCM tag 验证失败 → `authenticationFailed`。

- 加密:PBKDF2(password, salt, iterCount) → 256位 SymmetricKey → AES.GCM.seal(plaintext, nonce, key, aad=header)
- 解密:读 header → PBKDF2 → AES.GCM.open → 失败则 `authenticationFailed`
- **错误统一叫 `authenticationFailed`**,UI 显示「密码不正确,或同步数据已损坏」(AES-GCM 无法区分密码错 vs 密文损坏)

## 5. SyncPayload(JSON,加密前的明文)

`schemaVersion: 1`。稳定 DTO,不直接绑内部 Codable(后续内部模型改字段不破坏旧版导入)。

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-08-03T12:00:00Z",
  "sourceDeviceName": "MacBook Pro",
  "holdings": [...],
  "pendingTrades": [...],
  "investmentPlans": [...],
  "alfaPortfolios": [...],
  "valuationAlerts": [{ "fundCode": "...", "rules": [...] }],
  "valuationAlertSettings": { "isEnabled": true },
  "managerWatch": { "isEnabled":..., "notificationsEnabled":..., "intervalMinutes":..., "prodCode":..., "managerName":..., "watchForum":..., "selectedAdjustmentSourceIDs":[...] },
  "watchlist": [{ "item": {...}, "baseline": {...}, "alertRules": {...} }],
  "trendSettings": { "provider": {...含apiKey}, "webSearch":{...含apiKey}, "alphaVantage":{...含apiKey} }
}
```

### 运行态字段清洗(同步不含)
- ManagerWatchSettings: 排除 latestSeenAdjustmentIDs/latestSeenForumRecordID/forumBaselineTargetKey/adjustmentBaselineTargetKeys/lastCheckedAt/lastSuccessAt/lastErrorMessage/lastNotificationErrorMessage/lastResultSummary/lastHitAt(10个运行态字段)。只同步 config。
- ValuationAlertProfile: 排除 breachedRuleIDs/lastTriggeredAt。只同步 fundCode + rules。
- WatchlistRecord: 排除 dailyPoints(历史价,各设备自己累积) + alertState(运行态)。只同步 item + baseline + alertRules。

### 不同步的数据
- portfolio-insight-snapshots(60秒刷新)、manager-watch-timeline(巡检时间线)
- trend-analysis-report、next-hour-guidance(派生)
- fund-look-through-cache、trend-agent.log、trend-agent-runs/、dashboard.log、output/、alpha-vantage-cache/(缓存/日志)

## 6. 冲突与回滚

- **乐观锁**:PUT 带 If-Match revision,不匹配返 409,用户明确选「仍然覆盖」。
- **回滚检测**:客户端在 UserDefaults 记最高 revision。GET 返回更低 revision 时报警(恶意服务端回放旧版)。
- **本地事务式导入**:备份→临时目录→原子替换→恢复机制(见步骤2)。

## 7. 错误码

| 场景 | HTTP / 类型 | UI 提示 |
|---|---|---|
| 密码错/密文损坏 | `authenticationFailed` | 密码不正确,或同步数据已损坏 |
| 网络错误 | URLSession error | 网络连接失败,请检查地址和网络 |
| 鉴权失败 | 401 | 同步凭证失效,请重新注册 |
| 组不存在 | 404 | 同步组不存在,请检查或重新注册 |
| 冲突(云端更新) | 409 | 云端有更新版本,是否仍然覆盖 |
| 回滚(revision 倒退) | 客户端检测 | 检测到数据版本异常回退,是否继续 |
| 版本不兼容 | schemaVersion 不匹配 | 同步数据版本不兼容,请升级 App |
| 容量超限 | 413 | 同步数据过大(上限 2MB) |
| 服务端错误 | 5xx | 同步服务异常,请稍后重试 |

## 8. 威胁模型

**保护**:同步内容保密(服务端看不到明文)、内容完整性(AES-GCM 防篡改)、传输层鉴权(accessToken)。
**不保护**:服务端可见元数据(groupId/deviceId/IP/时间/大小)、服务端删除/拒绝/回滚(客户端记 revision 报警)、本机明文文件(API Key 已迁 Keychain,其余 JSON 仍本机明文)。
**不防**:服务端被攻破后回放旧版(客户端 revision 报警,但无法阻止)、暴力猜密码(PBKKDF2 600k 迭代减缓,但服务端 blob 泄露后可离线猜)。

## 9. 本地安全

- 同步密码、accessToken:存 **Keychain**(不放 UserDefaults)
- 服务地址、groupId、deviceId、最高 revision:存 UserDefaults(非敏感)
- API Key:已迁 Keychain(前置步骤),JSON 只存 config,SyncPayload 仅内存短暂包含
