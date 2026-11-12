#!/usr/bin/env node
/**
 * 冒烟验证客户端 bundle：能被 loader 注册、导出齐全、每个槽组件都能渲染。
 *
 * 为什么不用真浏览器：这里检查的是**注册契约**（槽名 / id / key / label），
 * 那部分一旦写错就是静默失败（面板不出现，控制台无报错）。视觉与交互在
 * 真实 DSH 页面里验证。
 *
 * 用法：node scripts/verify-client.mjs
 */

let registered = null
global.window = {
  __ModuleLoader__: {
    load: (registration) => {
      registered = registration
    },
  },
}
global.document = {
  getElementById: () => null,
  createElement: () => ({ set id(_v) {}, set textContent(_v) {} }),
  head: { appendChild: () => {} },
}

/** 最小 React 替身：只够跑 createElement / hooks 的空转。 */
const React = {
  createElement: (type, props, ...children) => ({ type, props, children }),
  useState: (init) => [typeof init === 'function' ? init() : init, () => {}],
  useEffect: () => {},
  useCallback: (fn) => fn,
  useMemo: (fn) => fn(),
  useRef: (init) => ({ current: init }),
  Fragment: 'Fragment',
}

const fakeRequire = (name) => {
  if (name === 'react') return React
  if (name === 'react/jsx-runtime') {
    return {
      jsx: React.createElement,
      jsxs: React.createElement,
      Fragment: 'Fragment',
    }
  }
  throw new Error(`unexpected require: ${name}`)
}

let failures = 0
const pass = (message) => console.log(`  ✅ ${message}`)
const fail = (message, detail) => {
  console.log(`  ❌ ${message}${detail === undefined ? '' : `: ${detail}`}`)
  failures += 1
}

console.log('=== 1. bundle 注册 ===')
await import(new URL('../lib/client.js', import.meta.url).href)
if (registered === null) {
  fail('bundle 未调用 __ModuleLoader__.load')
  process.exit(1)
}
if (registered.id === 'dsh-mobile-next') pass(`loader id = ${registered.id}`)
else fail('loader id 不匹配', registered.id)

const exports = registered.factory(fakeRequire)
const exportNames = Object.keys(exports).sort()
console.log(`  导出: ${exportNames.join(', ')}`)

console.log('\n=== 2. 导出契约 ===')
for (const name of ['apply', 'inject', 'PANEL_ID']) {
  if (name in exports) pass(name)
  else fail(`缺导出 ${name}`)
}
if (Array.isArray(exports.inject) && exports.inject.includes('slots')) {
  pass(`inject = ${JSON.stringify(exports.inject)}`)
} else {
  fail('inject 必须包含 slots', JSON.stringify(exports.inject))
}

console.log('\n=== 3. 槽注册 ===')
const registrations = []
let styleInstalled = false
const ctx = {
  slots: {
    inject: (name, callback) => {
      callback()
      return () => {}
    },
    register: (options, component) => {
      registrations.push({ options, component })
      return () => {}
    },
  },
  effect: (callback) => {
    callback()
    styleInstalled = true
    return () => {}
  },
  get: () => undefined,
}
exports.apply(ctx)

const bySlot = new Map(registrations.map((r) => [r.options.name, r]))
const expected = [
  ['sidebar.panellist', 'id'],
  ['main', 'key'],
  ['plugins.item', 'id'],
]
for (const [slot, identity] of expected) {
  const entry = bySlot.get(slot)
  if (entry === undefined) {
    fail(`未注册到 ${slot}`)
    continue
  }
  if (typeof entry.options[identity] !== 'string' || entry.options[identity] === '') {
    fail(`${slot} 缺 ${identity}`)
    continue
  }
  if (identity === 'id' && typeof entry.options.label !== 'function') {
    fail(`${slot} 缺 label（侧栏/插件页不渲染）`)
    continue
  }
  pass(`${slot} → ${identity}=${entry.options[identity]}`)
}
// main 的 key 必须与 layout.selectPanel 用的 id 一致，否则点了打不开
const mainKey = bySlot.get('main')?.options.key
const panellistId = bySlot.get('sidebar.panellist')?.options.id
if (mainKey === panellistId && mainKey === exports.PANEL_ID) {
  pass(`main.key 与侧栏 id 一致（${String(mainKey)}）`)
} else {
  fail('main.key / sidebar id / PANEL_ID 不一致', `${String(mainKey)} / ${String(panellistId)}`)
}

console.log('\n=== 4. 组件渲染（不同 props）===')
const propSets = [
  ['无 props', undefined],
  ['空对象', {}],
  ['size（侧栏图标）', { size: 18, active: false }],
  ['onClose（面板）', { onClose: () => {} }],
]
for (const { options, component } of registrations) {
  for (const [label, props] of propSets) {
    try {
      const out = component(props)
      if (out === null || out === undefined) {
        // 面板首帧可能因为没数据返回 null —— 但这里的所有组件都应返回元素
        fail(`${options.name} / ${label} 返回空`)
        continue
      }
      pass(`${options.name} / ${label}`)
    } catch (error) {
      fail(`${options.name} / ${label} 渲染抛错`, error instanceof Error ? error.message : String(error))
    }
  }
}

console.log('\n=== 5. 样式安装 ===')
if (styleInstalled) pass('ctx.effect 里安装了样式')
else fail('样式未安装')

console.log('')
if (failures > 0) {
  console.log(`SUMMARY  ${failures} 项失败`)
  process.exit(1)
}
console.log('SUMMARY  全部通过')
