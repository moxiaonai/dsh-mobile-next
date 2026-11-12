#!/usr/bin/env node
/**
 * 检查 DSH 是否已加载本插件的客户端模块。
 *
 * 用法：node scripts/check-loaded.mjs [port]
 *
 * 为什么需要它：客户端模块的清单是 DSH **启动时**扫描 Loader entries
 * 构建的。改了 package.json 的 `dsh.client` 后，必须重启 DSH 才会生效 ——
 * 页面刷新不够。
 *
 * 这个脚本能区分三种状态：
 *   A. 已在清单里         → 一切正常
 *   B. 不在清单里         → 需要重启 DSH
 *   C. 清单改了但没重启   → 需要重启 DSH（最容易被误判成"代码没生效"）
 */

import { execSync } from 'node:child_process'
import { readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const port = process.argv[2] ?? findPort()
if (port === undefined) {
  console.error('❌ 未找到 DSH 端口，请显式传入：node scripts/check-loaded.mjs 53693')
  process.exit(1)
}

function findPort() {
  try {
    const out = execSync(
      "lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -i deepseek | grep -oE '127.0.0.1:[0-9]+' | head -1",
      { encoding: 'utf8' },
    )
    return out.trim().split(':')[1]
  } catch {
    return undefined
  }
}

// 1. 拿模块清单（/plugins/events 无需认证）
let graph = ''
try {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 8000)
  // SSE 流不会自然关闭：读够首帧就取消
  const response = await fetch(`http://127.0.0.1:${port}/plugins/events`, {
    signal: controller.signal,
  })
  const reader = response.body?.getReader()
  if (reader !== undefined) {
    const chunks = []
    let total = 0
    while (total < 200_000) {
      const { done, value } = await reader.read()
      if (done) break
      chunks.push(value)
      total += value.length
      // 拿到 graph 就够，不必等流结束
      if (Buffer.concat(chunks).toString('utf8').includes('"type":"graph"')) {
        // 再多读一点，确保 entries 完整
        if (total > 30_000) break
      }
    }
    await reader.cancel().catch(() => {})
    graph = Buffer.concat(chunks).toString('utf8')
  }
  clearTimeout(timer)
} catch (e) {
  console.error('❌ 无法连接 DSH：', e instanceof Error ? e.message : String(e))
  process.exit(1)
}

const inGraph = graph.includes('dsh-mobile-next')
const totalEntries = (graph.match(/"id":"/g) ?? []).length

console.log(`DSH 端口: ${port}`)
console.log(`boot manifest 模块数: ${totalEntries}`)
console.log('')

if (inGraph) {
  console.log('✅ 客户端模块已加载')
  const m = /"id":"dsh-mobile-next"[^}]*"url":"([^"]+)"/u.exec(graph)
  if (m) console.log(`   bundle URL: ${m[1]}`)
  process.exit(0)
}

// 2. 不在清单里：区分「没装」和「装了但没重启」
console.log('❌ 客户端模块未加载')
console.log('')

const pkgPath = join(
  homedir(),
  '.dsh/profiles/desktop/node_modules/dsh-mobile-next/package.json',
)
let pkg
try {
  pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
} catch {
  console.log('原因：插件未安装到 profile')
  console.log(`  期望路径：${pkgPath}`)
  process.exit(1)
}

const decl = pkg.dsh?.client
if (decl === undefined) {
  console.log('原因：package.json 里没有 dsh.client 声明')
  console.log('  → 补上 dsh.client 后重新构建')
  process.exit(1)
}

console.log('清单声明:')
console.log('  platform:', decl.platform)
console.log('  inject:', JSON.stringify(decl.inject ?? []))
console.log('  immediately:', decl.immediately ?? false)
console.log('')

// 3. 比对清单修改时间与进程启动时间
const pkgMtime = statSync(pkgPath).mtimeMs
let procStart
try {
  const pid = execSync(
    `lsof -nP -iTCP:${port} -sTCP:LISTEN 2>/dev/null | tail -1 | awk '{print $2}'`,
    { encoding: 'utf8' },
  ).trim()
  const lstart = execSync(`ps -p ${pid} -o lstart=`, { encoding: 'utf8' }).trim()
  procStart = Date.parse(lstart)
} catch {
  procStart = undefined
}

if (procStart !== undefined && pkgMtime > procStart) {
  console.log('诊断：**清单在 DSH 启动之后才修改**')
  console.log(`  进程启动: ${new Date(procStart).toISOString()}`)
  console.log(`  清单修改: ${new Date(pkgMtime).toISOString()}`)
  console.log('')
  console.log('→ 需要重启 DSH。客户端模块清单是启动时扫描的，刷新页面不够。')
} else {
  console.log('诊断：清单修改早于进程启动，但仍未加载')
  console.log('  → 可能是 dsh.client.inject 里的模块名不存在，或 bundle 构建失败')
  console.log('  → 查看 DSH 启动日志里的 client-modules 报错')
}
process.exit(1)
