#!/usr/bin/env node
/**
 * 验证 patch 文件能否被 DSH 的 loader 正确解析。
 *
 * 这个脚本从 app.asar 提取的真实 `cordis-plugin-loader` 里取
 * `evaluate` 与 `interpolate` 的语义，然后：
 *   1. 用 YAML 解析我的 cordis.patch.yml
 *   2. 模拟 DSH 注入的 ctx（含 dshHomePath）
 *   3. 求值 `!!js` 表达式
 *   4. 断言结果符合预期
 *
 * 为什么需要它：`!!js` 求值失败时，DSH 的报错往往很模糊
 * （"plugin tree failed to load"），提前验证能省掉一轮排查。
 *
 * 用法：node scripts/verify-patch.mjs
 */

import { readFile } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')

// ── 复刻 DSH loader 的求值语义 ────────────────────────
// 来源：app.asar 内 cordis-plugin-loader/lib/index.js:361-372
const evaluate = new Function('ctx', 'expr', `
  with (ctx) {
    return eval(expr)
  }
`)

const isJsExpr = (value) => value instanceof Object && '__jsExpr' in value

function interpolate(ctx, value) {
  if (isJsExpr(value)) return evaluate(ctx, value.__jsExpr)
  if (!value || typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map((item) => interpolate(ctx, item))
  const out = {}
  for (const [k, v] of Object.entries(value)) out[k] = interpolate(ctx, v)
  return out
}

// ── 模拟 DSH 注入的 ctx ───────────────────────────────
// 来源：dsh-app-boot/lib/index.js:223004 `ctx.provide("dshHomePath", dshHomePath)`
const FAKE_HOME = '/tmp/fake-dsh-home'
const ctx = {
  dshHomePath: (...segments) => join(FAKE_HOME, ...segments),
}

// ── 极简 YAML 解析（只支持本文件用到的子集）───────────
// 不引入 yaml 依赖，避免为验证脚本增加安装负担。
function parseYaml(text) {
  const lines = text.split('\n')
  const result = []
  let current = null
  let stack = []

  const indentOf = (line) => line.length - line.trimStart().length

  for (const rawLine of lines) {
    const line = rawLine.replace(/\s+$/u, '')
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue

    const indent = indentOf(line)
    const trimmed = line.trim()

    // 数组项
    if (trimmed.startsWith('- ')) {
      const content = trimmed.slice(2)
      if (content.startsWith('insert:')) {
        current = { insert: [] }
        result.push(current)
        stack = [{ obj: current, indent, key: 'insert', isArray: true }]
        continue
      }
      // 数组里的对象项（例如 - id: xxx）
      if (content.includes(':')) {
        const obj = {}
        const [k, ...rest] = content.split(':')
        obj[k.trim()] = rest.join(':').trim()
        if (stack.length > 0 && stack[stack.length - 1].isArray) {
          stack[stack.length - 1].obj[stack[stack.length - 1].key].push(obj)
          stack.push({ obj, indent, key: null })
        }
        continue
      }
      continue
    }

    // key: value
    const colon = trimmed.indexOf(':')
    if (colon < 0) continue
    const key = trimmed.slice(0, colon).trim()
    const value = trimmed.slice(colon + 1).trim()

    while (stack.length > 0 && stack[stack.length - 1].indent >= indent) {
      stack.pop()
    }
    const parent = stack.length > 0 ? stack[stack.length - 1].obj : null
    if (parent === null) continue

    if (value === '') {
      // 嵌套对象
      const child = {}
      parent[key] = child
      stack.push({ obj: child, indent, key: null })
      continue
    }

    // !!js 表达式
    if (value.startsWith('!!js ')) {
      parent[key] = { __jsExpr: value.slice(5).trim() }
      continue
    }

    // 普通标量
    if (value === 'true') parent[key] = true
    else if (value === 'false') parent[key] = false
    else if (/^-?\d+$/u.test(value)) parent[key] = Number(value)
    else if (value.startsWith('[') && value.endsWith(']')) {
      parent[key] = value
        .slice(1, -1)
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s !== '')
    } else {
      parent[key] = value.replace(/^["']|["']$/gu, '')
    }
  }
  return result
}

// ── 主流程 ────────────────────────────────────────────
const patchPath = join(root, 'cordis.patch.yml')
const text = await readFile(patchPath, 'utf8')
const parsed = parseYaml(text)

let failures = 0
const pass = (msg) => console.log(`  ✅ ${msg}`)
const fail = (msg, detail) => {
  failures += 1
  console.log(`  ❌ ${msg}${detail === undefined ? '' : `: ${detail}`}`)
}

console.log(`验证 ${patchPath}\n`)

if (parsed.length === 0) {
  fail('patch 解析出 0 条 insert')
} else {
  pass(`patch 解析出 ${parsed.length} 条 insert`)
}

const entry = parsed[0]?.insert?.[0]
if (entry === undefined) {
  fail('未找到插件条目')
} else {
  pass(`条目 id = ${entry.id}`)
  if (entry.name === 'dsh-mobile-next') pass('name 正确')
  else fail('name 不匹配', entry.name)

  if (Array.isArray(entry.inject)) {
    pass(`inject = [${entry.inject.join(', ')}]`)
    if (!entry.inject.includes('webServer')) fail('缺少 webServer 注入')
  } else {
    fail('inject 不是数组', entry.inject)
  }
}

// 求值 !!js
const evaluated = interpolate(ctx, parsed)
const config = evaluated[0]?.insert?.[0]?.config ?? {}

console.log('\n求值 !!js 后：')
for (const [key, value] of Object.entries(config)) {
  if (key === 'tls') continue
  const display = typeof value === 'string' ? value : JSON.stringify(value)
  console.log(`  ${key} = ${display}`)
}

// 断言路径都被正确解析
const expectPath = (key) => {
  const value = config[key]
  if (typeof value !== 'string') {
    fail(`${key} 未被求值为字符串`, typeof value)
    return
  }
  if (!value.startsWith(FAKE_HOME)) {
    fail(`${key} 路径前缀不对`, value)
    return
  }
  if (!value.endsWith('.json')) {
    fail(`${key} 不是 json 文件`, value)
    return
  }
  pass(`${key} = ${value}`)
}

expectPath('setupFile')
expectPath('controlFile')
expectPath('stateFile')

if (config.initiallyEnabled === false) pass('initiallyEnabled = false（安全默认）')
else fail('initiallyEnabled 不是 false', config.initiallyEnabled)

if (Array.isArray(config.allowedCidrs)) pass(`allowedCidrs = ${JSON.stringify(config.allowedCidrs)}`)
else fail('allowedCidrs 不是数组', config.allowedCidrs)

console.log('')
if (failures > 0) {
  console.log(`SUMMARY  ${failures} 项失败`)
  process.exit(1)
}
console.log('SUMMARY  全部通过')
