#!/usr/bin/env node
/**
 * 验证打包产物可以独立安装并加载。
 *
 * 为什么需要：本地开发用软链接（`node_modules/dsh-mobile-next` → 源码目录），
 * 但**软链接不能分发给别人**。真实分发必须走 `pnpm pack` 的 tarball。
 *
 * 这个脚本检查：
 *   1. tarball 里包含所有必需文件
 *   2. package.json 的入口都能解析
 *   3. 解包后 host / client 两面都能加载
 *
 * 用法：node scripts/verify-package.mjs
 */

import { execSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const root = new URL('..', import.meta.url).pathname
const NODE = process.execPath
const PNPM = process.env.PNPM_BIN ?? 'pnpm'

const pass = (m) => console.log(`  ✅ ${m}`)
const fail = (m, d) => {
  console.log(`  ❌ ${m}${d === undefined ? '' : `: ${d}`}`)
  failures += 1
}
let failures = 0

const work = mkdtempSync(join(tmpdir(), 'dshmn-pkg-'))
console.log(`临时目录: ${work}\n`)

try {
  // 1. 打包
  console.log('=== 1. pnpm pack ===')
  execSync(`${PNPM} pack --pack-destination ${work}`, {
    cwd: root,
    stdio: 'pipe',
  })
  const tarball = execSync(`ls ${work}/*.tgz`, { encoding: 'utf8' }).trim()
  const size = readFileSync(tarball).length
  pass(`tarball: ${tarball.split('/').pop()} (${size} 字节)`)

  // 2. 解包检查必需文件
  console.log('\n=== 2. 包内文件 ===')
  execSync(`tar xzf ${tarball} -C ${work}`)
  const pkgDir = join(work, 'package')
  const required = [
    'package.json',
    'lib/index.js',
    'lib/index.d.ts',
    'lib/client.js',
    'cordis.patch.yml',
    'README.md',
    // 插件页显示中文名与图标靠这两个（缺了会退回包名 + 默认图）
    'locale/en.json',
    'locale/zh.json',
    'assets/icon.svg',
  ]
  for (const f of required) {
    if (existsSync(join(pkgDir, f))) pass(f)
    else fail(`${f} 缺失`)
  }

  // 3. 入口解析
  console.log('\n=== 3. 入口解析 ===')
  const pkg = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8'))
  const checkEntry = (label, rel) => {
    if (rel === undefined) return fail(`${label} 未定义`)
    const p = rel.replace('./', '')
    if (existsSync(join(pkgDir, p))) pass(`${label} → ${rel}`)
    else fail(`${label} → ${rel} 不存在`)
  }
  checkEntry('main', pkg.main)
  checkEntry('types', pkg.types)
  checkEntry('exports["."]', pkg.exports?.['.']?.default)
  checkEntry('exports["./client"]', pkg.exports?.['./client']?.default)

  // 4. 独立安装并加载
  console.log('\n=== 4. 独立安装 ===')
  const proj = join(work, 'proj')
  execSync(`mkdir -p ${proj} && echo '{"name":"t","private":true,"type":"module"}' > ${proj}/package.json`)
  execSync(`${PNPM} add ${tarball} --registry=https://registry.npmjs.org`, {
    cwd: proj,
    stdio: 'pipe',
  })
  pass('安装成功')

  // 5. 两面加载
  console.log('\n=== 5. 加载验证 ===')
  const script = `
    const m = await import('dsh-mobile-next');
    const hostOk = typeof m.default === 'function' && m.name === 'dsh-mobile-next';
    global.window = { __ModuleLoader__: { load: (o) => { global.__reg = o } } };
    global.document = {
      getElementById: () => null,
      createElement: () => ({ set id(v){}, set textContent(v){} }),
      head: { appendChild: () => {} },
    };
    await import('dsh-mobile-next/client');
    const reg = global.__reg;
    const react = { createElement: () => null, useState: () => [false, () => {}],
                    useEffect: () => {}, useCallback: (f) => f, useMemo: (f) => f(),
                    useRef: (v) => ({ current: v }), Fragment: 'Fragment' };
    // 面板用 JSX，因此 bundle 会 require('react/jsx-runtime')：
    // 两者都由 DSH 的种子模块表提供，这里都要喂进去
    const jsxRuntime = { jsx: react.createElement, jsxs: react.createElement, Fragment: 'Fragment' };
    const ex = reg.factory((n) => {
      if (n === 'react') return react;
      if (n === 'react/jsx-runtime') return jsxRuntime;
      throw new Error(n);
    });
    console.log(JSON.stringify({
      hostOk,
      hostInject: m.inject,
      loaderId: reg.id,
      clientExports: Object.keys(ex),
      clientInject: ex.inject,
    }));
  `
  const out = execSync(`${NODE} --input-type=module -e "${script.replaceAll('"', '\\"')}"`, {
    cwd: proj,
    encoding: 'utf8',
  }).trim()
  const result = JSON.parse(out)
  if (result.hostOk) pass(`host 面: inject=${JSON.stringify(result.hostInject)}`)
  else fail('host 面加载异常')
  if (result.loaderId === 'dsh-mobile-next') pass(`client loader id 正确`)
  else fail('client loader id 不匹配', result.loaderId)
  if (result.clientExports.includes('apply')) pass(`client 导出: ${result.clientExports.join(', ')}`)
  else fail('client 缺 apply 导出')
} finally {
  rmSync(work, { recursive: true, force: true })
}

console.log('')
if (failures > 0) {
  console.log(`SUMMARY  ${failures} 项失败`)
  process.exit(1)
}
console.log('SUMMARY  全部通过')
