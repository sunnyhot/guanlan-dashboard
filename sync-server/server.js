#!/usr/bin/env node
/**
 * 且慢主理人看板 — 数据同步服务端
 *
 * 端到端加密(E2EE):服务端只存密文 blob,看不到明文也看不到密码。
 * SQLite 存储,零外部网络依赖(better-sqlite3 内置)。
 *
 * 协议见 PROTOCOL.md。
 *
 * 启动: node server.js  (默认端口 8787,可用 PORT 环境变量改)
 */

const http = require('http');
const crypto = require('crypto');

// ============================================================
// 配置
// ============================================================
const PORT = process.env.PORT || 8787;
const MAX_BLOB_SIZE = 2 * 1024 * 1024;  // 2MB
const MAX_GROUPS = 10000;  // 防滥用上限

// ============================================================
// SQLite 存储(内存实现,生产可换 better-sqlite3)
//
// 数据结构:
//   groups: Map<groupId, { accessToken, currentBlob, currentRevision, prevBlob, sourceDeviceId, timestamp }>
//
// 生产建议换 better-sqlite3,加 WAL 模式、备份、日志脱敏。
// 这里用 Map 保证零依赖、可直接跑。
// ============================================================
const groups = new Map();

function genId(prefix) {
  return prefix + '_' + crypto.randomBytes(9).toString('base64url');
}

// ============================================================
// HTTP 工具
// ============================================================
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', chunk => {
      size += chunk.length;
      if (size > MAX_BLOB_SIZE + 1024) {
        reject(new Error('payload too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString()));
    req.on('error', reject);
  });
}

function sendJSON(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function checkAuth(req, group) {
  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return false;
  const token = auth.slice(7);
  return token === group.accessToken;
}

// ============================================================
// 路由处理
// ============================================================

// POST /v1/groups — 注册同步组
async function handleRegister(req, res) {
  if (groups.size >= MAX_GROUPS) {
    return sendJSON(res, 503, { error: 'server_full', message: '服务端同步组数量已满' });
  }
  const groupId = genId('g');
  const deviceId = genId('d');
  const accessToken = genId('tok');
  groups.set(groupId, {
    accessToken,
    currentBlob: null,
    currentRevision: 0,
    prevBlob: null,
    sourceDeviceId: deviceId,
    timestamp: new Date().toISOString(),
  });
  return sendJSON(res, 201, { groupId, deviceId, accessToken });
}

// GET /v1/groups/:groupId/blob — 拉取密文
function handlePull(req, res, groupId) {
  const group = groups.get(groupId);
  if (!group) return sendJSON(res, 404, { error: 'group_not_found' });
  if (!checkAuth(req, group)) return sendJSON(res, 401, { error: 'unauthorized' });
  if (!group.currentBlob) return sendJSON(res, 404, { error: 'no_data', message: '尚未上传过数据' });

  return sendJSON(res, 200, {
    revision: group.currentRevision,
    serverTimestamp: group.timestamp,
    sourceDeviceId: group.sourceDeviceId,
    blob: group.currentBlob.toString('base64'),
  });
}

// PUT /v1/groups/:groupId/blob — 上传密文(覆盖)
async function handlePush(req, res, groupId) {
  const group = groups.get(groupId);
  if (!group) return sendJSON(res, 404, { error: 'group_not_found' });
  if (!checkAuth(req, group)) return sendJSON(res, 401, { error: 'unauthorized' });

  // 乐观锁:If-Match revision 检查
  const ifMatch = req.headers['if-match'];
  if (ifMatch !== undefined) {
    const expected = parseInt(ifMatch, 10);
    if (!isNaN(expected) && group.currentRevision !== expected) {
      return sendJSON(res, 409, {
        error: 'conflict',
        message: '云端有更新版本',
        currentRevision: group.currentRevision,
      });
    }
  }

  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch (e) {
    return sendJSON(res, 400, { error: 'bad_request', message: e.message });
  }

  if (!body.blob) {
    return sendJSON(res, 400, { error: 'bad_request', message: '缺少 blob 字段' });
  }

  const blob = Buffer.from(body.blob, 'base64');
  if (blob.length > MAX_BLOB_SIZE) {
    return sendJSON(res, 413, { error: 'too_large', message: '数据超过 2MB 上限' });
  }

  // 保存:当前 blob 转为上一版(防误覆盖毁唯一副本),新 blob 入位
  group.prevBlob = group.currentBlob;
  group.currentBlob = blob;
  group.currentRevision += 1;
  group.sourceDeviceId = body.sourceDeviceId || 'unknown';
  group.timestamp = new Date().toISOString();

  return sendJSON(res, 200, {
    revision: group.currentRevision,
    serverTimestamp: group.timestamp,
  });
}

// ============================================================
// 请求分发
// ============================================================
const server = http.createServer(async (req, res) => {
  // CORS(开发用)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, If-Match');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  const url = new URL(req.url, `http://localhost:${PORT}`);
  const path = url.pathname;
  const parts = path.split('/').filter(Boolean);  // ["v1","groups",...] or ["v1","groups",":id","blob"]

  try {
    // POST /v1/groups
    if (req.method === 'POST' && parts.length === 2 && parts[0] === 'v1' && parts[1] === 'groups') {
      return await handleRegister(req, res);
    }
    // GET /v1/groups/:groupId/blob
    if (req.method === 'GET' && parts.length === 4 && parts[0] === 'v1' && parts[1] === 'groups' && parts[3] === 'blob') {
      return handlePull(req, res, parts[2]);
    }
    // PUT /v1/groups/:groupId/blob
    if (req.method === 'PUT' && parts.length === 4 && parts[0] === 'v1' && parts[1] === 'groups' && parts[3] === 'blob') {
      return await handlePush(req, res, parts[2]);
    }

    return sendJSON(res, 404, { error: 'not_found' });
  } catch (e) {
    console.error(`[ERROR] ${req.method} ${path}:`, e.message);
    return sendJSON(res, 500, { error: 'server_error', message: '同步服务异常' });
  }
});

server.listen(PORT, () => {
  console.log(`[且慢同步服务] 运行在 http://localhost:${PORT}`);
  console.log(`  POST   /v1/groups            注册同步组`);
  console.log(`  GET    /v1/groups/:id/blob   拉取密文`);
  console.log(`  PUT    /v1/groups/:id/blob   上传密文`);
  console.log(`  上限:  ${MAX_BLOB_SIZE / 1024}KB/blob, ${MAX_GROUPS} 组`);
});
