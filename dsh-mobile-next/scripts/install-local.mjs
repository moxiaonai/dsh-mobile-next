#!/usr/bin/env node
/**
 * 把当前 profile 里的**软链安装**换成**真实安装**（tarball）。
 *
 * ## 为什么需要
 *
 * 开发期用软链（`node_modules/dsh-mobile-next` → 源码目录）很方便，
 * 但它有两个后果：
 *
 * 1. **插件页的「更新」按钮永远灰** —— DSH 的 `updateRefusal` 要求插件
 *    「从 registry 以自身包名安装」，软链 / `file:` 都不满足。
 * 2. **不可复现** —— `package.json` 的 `dependencies` 与 `pnpm-lock.yaml`
 *    里都没有它，换台机器 clone 下来装不出一样的环境。
 *
 * 这个脚本做一件事：`pnpm pack` → `dsh plugin add <tarball>`，
 * 把软链替换成实体目录，并把它写进 dependencies + lock。
 *
 * ## 用法
 *
 *   node scripts/install-local.mjs            # 装进当前 profile
 *   node scripts/install-local.mjs --profile desktop
 *   node scripts/install-local.mjs --revert   # 改回软链（继续开发用）
 *
 * ## 注意
 *
 * 换成真实安装后，**源码改动不再自动生效** —— 安装的是一份拷贝。
 * 继续开发时用 `--revert` 换回软链，或每次改完重跑本脚本。
 *
 * ## tarball 放哪
 *
 * 必须放在**稳定目录**（仓库的 `dist/`），不能放 `mkdtemp` 临时目录。
 * 原因：`pnpm add <tarball>` 会把路径原样写进 profile 的 `dependencies`
 * （`file:/…/xxx.tgz`）。路径一旦失效，下次 `pnpm install` 直接失败。
 * 实测踩过：tarball 在 temp 目录里被 finally 删掉，profile 的 dependencies
 * 就指向了一个不存在的文件。
 *
 * ## 为什么打包前必须确认 node_modules 在
 *
 * `pnpm pack` 会跑 `prepack`（= `pnpm run build` = `rm -rf lib && tsdown`）。
 * 如果仓库 `node_modules` 缺失，tsdown 会以 `command not found` 失败；
 * 更糟的是**软链时代的残留**：profile 里若还留着指向仓库的软链，
 * 插件会从仓库目录 `require('qrcode')`，仓库没有 node_modules 就
 * `ERR_MODULE_NOT_FOUND`，整个 host 面挂掉（端点直接 404）。
 * 实测踩过，排查了很久。所以这里先检查、缺了就装。
 */

import { execFileSync } from 'node:child_process'
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, rmSync } from 'node:fs'
import { join } from 'node:path'

const root = new URL('..', import.meta.url).pathname
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).name

const args = process.argv.slice(2)
const profileIndex = args.indexOf('--profile')
const profile = profileIndex >= 0 ? args[profileIndex + 1] : 'desktop'
const revert = args.includes('--revert')

/** 找 dsh CLI：优先 PATH，其次应用包内的 runtime。 */
function findDsh() {
  const candidates = [
    '/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh',
    join(process.env.HOME ?? '', 'Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh'),
  ]
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate
  }
  return 'dsh'
}

const dsh = findDsh()
const profileDir = join(process.env.DSH_HOME ?? join(process.env.HOME ?? '', '.dsh'), 'profiles', profile)
const installed = join(profileDir, 'node_modules', pkg)

console.log(`包: ${pkg}`)
console.log(`profile: ${profile}（${profileDir}）`)
console.log('')

if (!existsSync(profileDir)) {
  console.error(`❌ profile 目录不存在：${profileDir}`)
  process.exit(1)
}

// 当前安装形态
const linkStat = existsSync(installed) || isSymlink(installed) ? lstatSafe(installed) : undefined
const isLink = linkStat?.isSymbolicLink() === true
console.log(`当前形态: ${isLink ? `软链 → ${readlinkSafe(installed)}` : linkStat === undefined ? '未安装' : '实体目录'}`)
console.log('')

if (revert) {
  if (isLink) {
    console.log('✅ 已经是软链，无需改动')
    process.exit(0)
  }
  const target = join(root)
  // ⚠ 顺序很重要：先 remove（它会连 node_modules 里的实体目录一起删掉），
  // 再建软链。反过来写的话，remove 会把刚建好的软链删掉 —— 实测踩过。
  console.log('从 dependencies 摘除…')
  try {
    execFileSync(dsh, ['plugin', '--profile', profile, 'remove', pkg], { stdio: 'inherit' })
  } catch {
    console.log('（remove 失败可忽略，继续建软链）')
  }
  console.log(`改回软链 → ${target}`)
  execFileSync('ln', ['-sfn', target, installed], { stdio: 'inherit' })
  console.log('')
  console.log('✅ 已改回软链。源码改动重新生效（记得 node scripts/reload-plugin.mjs）。')
  process.exit(0)
}

// ── 真实安装 ────────────────────────────────────────────
/** 稳定的 tarball 目录：profile 的 dependencies 会记住这里的路径。 */
const distDir = join(root, 'dist')
mkdirSync(distDir, { recursive: true })
// 清掉旧 tarball，避免 pack 输出里出现多个候选
for (const name of readdirSync(distDir)) {
  if (name.endsWith('.tgz')) rmSync(join(distDir, name))
}

try {
  // 仓库 node_modules 必须在：prepack 要跑 tsdown，且软链安装会从仓库解析依赖
  if (!existsSync(join(root, 'node_modules', 'tsdown'))) {
    console.log('⓪ 仓库依赖缺失，先安装…')
    execFileSync('pnpm', ['install'], { cwd: root, stdio: 'inherit' })
    console.log('')
  }

  console.log('① 构建并打包…')
  execFileSync('pnpm', ['run', 'build'], { cwd: root, stdio: 'inherit' })
  // ⚠ 用 `--config.ignore-scripts=true` 跳过 prepack。
  // 上面已经显式 build 过了；再让 pack 触发一次 prepack 是重复劳动，
  // 而且它会在打包瞬间改 lib/ —— 若此刻插件正从仓库解析（软链安装），
  // 就会出现「文件正在被替换」的窗口。
  const packed = execFileSync(
    'pnpm',
    ['pack', '--pack-destination', distDir, '--config.ignore-scripts=true'],
    { cwd: root, encoding: 'utf8' },
  )
  const tarball = packed
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.endsWith('.tgz'))
    .at(-1)
  if (tarball === undefined || !existsSync(tarball)) {
    throw new Error(`找不到 tarball（pack 输出：${packed.slice(-200)}）`)
  }
  console.log(`   ${tarball}`)
  console.log('')

  console.log('② 装进 profile（替换软链）…')
  execFileSync(dsh, ['plugin', '--profile', profile, 'add', tarball], { stdio: 'inherit' })
  console.log('')

  const after = lstatSafe(installed)
  console.log('③ 校验…')
  console.log(`   形态: ${after?.isSymbolicLink() === true ? '❌ 仍是软链' : '✅ 实体目录'}`)
  const manifest = JSON.parse(readFileSync(join(profileDir, 'package.json'), 'utf8'))
  console.log(
    `   dependencies: ${manifest.dependencies?.[pkg] === undefined ? '❌ 未记录' : `✅ ${manifest.dependencies[pkg]}`}`,
  )
  console.log('')
  console.log('✅ 已完成。插件页的「更新」按钮现在可用（需重启 DSH 让 loader 重新解析）。')
  console.log('   继续开发请运行：node scripts/install-local.mjs --revert')
} finally {
  // 不删 tarball：profile 的 dependencies 指向它
}

function lstatSafe(path) {
  try {
    return lstatSync(path)
  } catch {
    return undefined
  }
}

function readlinkSafe(path) {
  try {
    return readlinkSync(path)
  } catch {
    return '?'
  }
}

function isSymlink(path) {
  return lstatSafe(path)?.isSymbolicLink() === true
}
