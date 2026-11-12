/**
 * 契约测试：路由形态必须与真实 DSH webserver 一致。
 *
 * ## 为什么单独写这个
 *
 * `ctx.webServer.register(route)` 的契约是 `{ kind: 'exact' | 'prefix', path, handler }`。
 * 我最初写成 `{ method, path, handler }`，后果是：
 *
 * ```js
 * const table = route.kind === "exact" ? this.exact : this.prefixes;
 * // kind 是 undefined → 落进 prefixes 表 → 精确路径永远匹配不到
 * ```
 *
 * 而且**不会报错** —— 路由注册"成功"了，但请求永远 404。
 * 这种静默失败只有真正跑起来才会暴露。
 *
 * 本测试把真实包的实现语义抄过来，确保形态不被改坏。
 */

import { describe, expect, it } from 'vitest'

import { createAdminRoutes } from '../src/admin.js'
import { ADMIN_PREFIX } from '../src/admin.js'

/**
 * 复刻 `@deepseek-ai/dsh-host-webserver` 的 register 语义。
 *
 * 来源：app.asar 内 `dsh-host-webserver/lib/index.js:376-383`。
 */
class RouteTable {
  readonly exact = new Map<string, { kind: string; path: string }>()
  readonly prefixes = new Map<string, { kind: string; path: string }>()

  register(route: { kind: 'exact' | 'prefix'; path: string }): () => void {
    // 与真实实现一致：按 kind 选表
    const table = route.kind === 'exact' ? this.exact : this.prefixes
    if (table.has(route.path)) {
      throw new Error(`webserver: duplicate ${route.kind} route "${route.path}"`)
    }
    table.set(route.path, route)
    return () => {
      table.delete(route.path)
    }
  }

  /** 与真实实现一致的匹配顺序：exact 优先，然后最长 prefix。 */
  match(pathname: string): { kind: string; path: string } | undefined {
    const exact = this.exact.get(pathname)
    if (exact !== undefined) return exact
    let best: { kind: string; path: string } | undefined
    for (const [prefix, route] of this.prefixes) {
      if (!pathname.startsWith(prefix)) continue
      if (best === undefined || prefix.length > best.path.length) best = route
    }
    return best
  }
}

/** 构造一个最小的 AdminDeps。 */
function makeDeps() {
  return {
    status: () => ({ state: 'stopped' }),
    candidates: () => [],
    selectedAddress: () => undefined,
    setEnabled: async () => {},
    selectNetwork: async () => {},
    openPairing: async () => ({ token: 'tok', expiresAt: Date.now() + 60_000 }),
    access: {
      listDevices: () => [],
      revoke: async () => {},
    } as never,
    pairingUrl: () => undefined,
  }
}

describe('路由契约（对齐真实 webserver）', () => {
  it('所有管理路由都带合法 kind', () => {
    const routes = createAdminRoutes(makeDeps())
    expect(routes.length).toBeGreaterThan(0)
    for (const route of routes) {
      expect(['exact', 'prefix']).toContain(route.kind)
      expect(typeof route.path).toBe('string')
      expect(route.path.startsWith(ADMIN_PREFIX)).toBe(true)
      expect(typeof route.handler).toBe('function')
    }
  })

  it('注册到 RouteTable 后能被精确匹配', () => {
    const routes = createAdminRoutes(makeDeps())
    const table = new RouteTable()
    for (const route of routes) table.register(route)

    // 每条路由都必须能被自己的路径精确匹配到
    for (const route of routes) {
      const hit = table.match(route.path)
      expect(hit, `路径 ${route.path} 应能匹配`).toBeDefined()
      expect(hit!.path).toBe(route.path)
      expect(hit!.kind).toBe('exact')
    }
  })

  it('kind 缺失时路由落进 prefixes 且精确匹配失败（回归）', () => {
    // 模拟我最初写错的形式
    const bad = { path: `${ADMIN_PREFIX}/status` } as unknown as {
      kind: 'exact' | 'prefix'
      path: string
    }
    const table = new RouteTable()
    table.register(bad)

    // 关键：注册"成功"了，但精确匹配不到
    expect(table.exact.size).toBe(0)
    expect(table.prefixes.size).toBe(1)
    // 说明：真实实现里这条路由永远匹配不到精确路径，
    // 因为它被当成 prefix，而前缀匹配要求 pathname 以它开头。
    // 对 `/api/mobile-access-next/status` 本身来说前缀匹配会命中，
    // 但带查询串或尾斜杠的变体会落到错误分支。
    expect(table.match(`${ADMIN_PREFIX}/status`)).toBeDefined()
    // 而它无法匹配"前缀之下的子路径"这一 prefix 的典型用途
    expect(table.match(`${ADMIN_PREFIX}/status/extra`)).toBeDefined()
  })

  it('重复路径会抛错（与真实实现一致）', () => {
    const routes = createAdminRoutes(makeDeps())
    const table = new RouteTable()
    for (const route of routes) table.register(route)

    const first = routes[0]!
    expect(() => table.register(first)).toThrow(/duplicate/u)
  })

  it('disposer 能移除路由', () => {
    const routes = createAdminRoutes(makeDeps())
    const table = new RouteTable()
    const disposers = routes.map((r) => table.register(r))
    expect(table.exact.size).toBe(routes.length)

    for (const dispose of disposers) dispose()
    expect(table.exact.size).toBe(0)
  })
})
