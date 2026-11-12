#!/usr/bin/env node
/**
 * 让 DSH 重新加载本插件，**不需要重启整个应用**。
 *
 * ## 为什么需要
 *
 * 客户端模块清单（`dsh.client`）是 DSH 启动时扫描 Loader entries 构建的。
 * 改了 `package.json` 后刷新页面没用 —— 传统做法是重启 DSH。
 *
 * 但 DSH 提供了 `pluginManager/setPluginEnabled`，描述里明确写着
 * "apply it on live profiles"。先禁用再启用，就能触发插件重载，
 * 客户端模块随之重新扫描。
 *
 * ## 用法
 *
 *   node scripts/reload-plugin.mjs [port]
 *
 * ## 前提
 *
 * 需要能读 `$DSH_HOME/.credentials.yaml` 来签发会话 Cookie
 * （与 `mint_cookie.dart` 同一套机制）。
 */

import { createHash, createHmac, randomBytes } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const ENTRY_ID = 'include:mobile-access-next'

const port = process.argv[2] ?? '53693'
const origin = `http://127.0.0.1:${port}`
const dshHome = process.env.DSH_HOME ?? join(homedir(), '.dsh')

/** 签发 DSH 的浏览器会话 Cookie。 */
function mintCookie() {
  const yaml = readFileSync(join(dshHome, '.credentials.yaml'), 'utf8')
  const m = /client-connection\/browser-session:[\s\S]*?secret:\s*(\S+)/u.exec(yaml)
  if (m === null) throw new Error('未找到 browser-session 密钥')
  const b64 = m[1].replaceAll('-', '+').replaceAll('_', '/')
  const secret = Buffer.from(b64 + '='.repeat((4 - (b64.length % 4)) % 4), 'base64')

  const authority = `127.0.0.1:${port}`
  const issuedAt = Date.now()
  const expiresAt = issuedAt + 30 * 24 * 3600 * 1000
  const body = Buffer.from(
    JSON.stringify({ version: 1, authority, issuedAt, expiresAt }),
    'utf8',
  ).toString('base64url')
  const signature = createHmac('sha256', secret).update(body).digest('base64url')
  const name = `dsh-auth-${createHash('sha256').update(authority).digest('base64url')}`
  return `${name}=v1.${body}.${signature}`
}

/** 调一个 unary RPC。 */
async function rpc(endpoint, args, cookie) {
  const response = await fetch(`${origin}/api/${endpoint}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      cookie,
      host: `127.0.0.1:${port}`,
    },
    body: JSON.stringify({
      type: 'client-request',
      rpcId: `reload-${randomBytes(8).toString('hex')}`,
      method: endpoint,
      payload: { args },
    }),
  })
  const text = await response.text()
  const envelope = JSON.parse(text)
  if (envelope.result?.ok !== true) {
    throw new Error(`${endpoint} failed: ${JSON.stringify(envelope.result?.error ?? {})}`)
  }
  return envelope.result.value
}

const cookie = mintCookie()

console.log(`DSH: ${origin}`)
console.log(`插件: ${ENTRY_ID}`)
console.log('')

// 1. 确认插件存在
const plugins = await rpc('pluginManager/listPlugins', {}, cookie)
const entry = plugins.find((p) => p.entryId === ENTRY_ID)
if (entry === undefined) {
  console.error('❌ 未找到插件条目。已安装的插件里有 mobile 字样的：')
  for (const p of plugins) {
    if (String(p.moduleName).includes('mobile')) {
      console.error(`   ${p.entryId} → ${p.moduleName}`)
    }
  }
  process.exit(1)
}
console.log(`当前状态: enabled=${String(entry.enabled)} phase=${String(entry.fiberPhase)}`)
console.log('')

// 2. 禁用 → 启用
console.log('禁用…')
const off = await rpc('pluginManager/setPluginEnabled', { id: ENTRY_ID, enabled: false }, cookie)
console.log(`  ${String(off.application)} (changed=${String(off.changed)})`)

await new Promise((r) => setTimeout(r, 2000))

console.log('启用…')
const on = await rpc('pluginManager/setPluginEnabled', { id: ENTRY_ID, enabled: true }, cookie)
console.log(`  ${String(on.application)} (changed=${String(on.changed)})`)

if (on.warnings?.length > 0) {
  console.log('  警告:', on.warnings)
}

console.log('')
console.log('✅ 已触发重载。运行 check-loaded.mjs 确认客户端模块已进入清单：')
console.log(`   node scripts/check-loaded.mjs ${port}`)
