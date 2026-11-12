/**
 * 第三方 CJS 依赖的加载器。
 *
 * ## 为什么不能直接 `import forge from 'node-forge'`
 *
 * 实测：插件装进 DSH 后整条插件激活失败，报
 *
 * ```
 * TypeError: Cannot read properties of undefined (reading 'usePureJavaScript')
 * ```
 *
 * 错误来自 node-forge 自己的 CJS 内部链（`random.js` 读 `forge.options`），
 * 说明宿主加载器把 `node-forge` 的默认导出解析成了 undefined。
 * 而同样的代码在纯 Node / Electron `import()` 下是好的 —— 属于**宿主互操作差异**。
 *
 * ## 做法
 *
 * 1. 优先用 `createRequire`（Node 原生 CJS 解析），完全绕开 ESM 默认导出互操作；
 * 2. 失败再退回动态 `import()`，并从 `default` 里取真正的对象；
 * 3. 取到的对象**必须通过结构检查**（有 `pki`/`util`，或 `toString` 函数），
 *    否则明确报错，而不是让调用方在深处拿到 undefined 崩掉。
 */

import { createRequire } from 'node:module'

type ForgeModule = typeof import('node-forge')
type QRCodeModule = typeof import('qrcode')

/** 从 ESM 命名空间或 `{ default }` 包装里取出真正的导出对象。 */
function unwrap<T>(loaded: unknown): T | undefined {
  if (loaded === null || typeof loaded !== 'object') return undefined
  const record = loaded as Record<string, unknown>
  const inner = record.default
  if (inner !== null && typeof inner === 'object') return inner as T
  return record as T
}

function isForge(value: unknown): value is ForgeModule {
  const record = value as Record<string, unknown> | undefined
  return (
    record !== undefined &&
    typeof record.pki === 'object' &&
    record.pki !== null &&
    typeof record.util === 'object' &&
    record.util !== null
  )
}

function isQRCode(value: unknown): value is QRCodeModule {
  return (
    value !== undefined &&
    value !== null &&
    typeof (value as { toString?: unknown }).toString === 'function'
  )
}

/** Node 原生 require；在 ESM 下用 createRequire 构造。 */
function nodeRequire(): ((id: string) => unknown) | undefined {
  try {
    return createRequire(import.meta.url) as (id: string) => unknown
  } catch {
    return undefined
  }
}

async function loadCjs<T>(
  id: string,
  accept: (value: unknown) => value is T,
): Promise<T> {
  const require = nodeRequire()
  if (require !== undefined) {
    try {
      const candidate = unwrap<T>(require(id))
      if (accept(candidate)) return candidate
    } catch {
      // 继续走动态 import（例如打包器改写了 require 的目标）
    }
  }
  const candidate = unwrap<T>(await import(id))
  if (!accept(candidate)) {
    throw new Error(`dependency ${id} resolved to an unexpected shape`)
  }
  return candidate
}

let forgePromise: Promise<ForgeModule> | undefined
let qrCodePromise: Promise<QRCodeModule> | undefined

/** 懒加载 node-forge（自签 CA 只在需要时才付这个代价）。 */
export function loadForge(): Promise<ForgeModule> {
  forgePromise ??= loadCjs<ForgeModule>('node-forge', isForge)
  return forgePromise
}

/** 懒加载 qrcode。 */
export function loadQRCode(): Promise<QRCodeModule> {
  qrCodePromise ??= loadCjs<QRCodeModule>('qrcode', isQRCode)
  return qrCodePromise
}
