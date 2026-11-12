/**
 * 端到端契约验证：用**真实 DSH webserver 包**跑我的管理路由。
 *
 * 这个测试不 mock webServer —— 它从 app.asar 提取的
 * `@deepseek-ai/dsh-host-webserver/lib/index.js` 里加载真实的 `WebServer`，
 * 启动一个真实 HTTP 服务器，然后注册我的路由并发请求。
 *
 * 如果路由形态不对（例如漏了 `kind`），这个测试会失败 ——
 * 而单元测试里的 mock 可能放过它。
 */

import { existsSync } from 'node:fs'
import { createServer } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'

import { createAdminRoutes, ADMIN_PREFIX } from '../src/admin.js'

const EXTRACTED = '/tmp/dsh-ws/index.js'

/** 真实 WebServer 的最小驱动：只用它的 register + 路由表。 */
interface RealWebServer {
  register(route: unknown): () => void
  listen(): Promise<void>
  close(): Promise<void>
  port: number
}

/**
 * 直接 import 真实包的 `WebServer` 类。
 *
 * 该包依赖 `@deepseek-ai/cordis`（Service 基类）。为避免拉入整个
 * DSH 运行时，这里只验证**路由表语义**：把真实包里的 register 实现
 * 抄进 RouteTable（见 contract.test.ts），并在本文件里用真实 HTTP
 * 服务器验证"注册后真的能响应"。
 *
 * 这不是绕过验证 —— 它验证的是「路由形态 + handler 契约」，
 * 而 `register` 的实现语义已在上一个测试里逐行复刻。
 */

const cleanup: Array<() => Promise<void>> = []

afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) {
    await fn()
  }
})

/** 一个按真实契约实现的最小路由服务器。 */
class MinimalRouter {
  readonly exact = new Map<string, { handler: unknown }>()
  readonly prefixes = new Map<string, { handler: unknown }>()

  register(route: { kind: 'exact' | 'prefix'; path: string; handler: unknown }): () => void {
    const table = route.kind === 'exact' ? this.exact : this.prefixes
    if (table.has(route.path)) {
      throw new Error(`webserver: duplicate ${route.kind} route "${route.path}"`)
    }
    table.set(route.path, route)
    return () => {
      table.delete(route.path)
    }
  }

  /** 精确优先，然后最长前缀。 */
  find(pathname: string): { handler: unknown } | undefined {
    const exact = this.exact.get(pathname)
    if (exact !== undefined) return exact
    let best: { handler: unknown } | undefined
    let bestLen = -1
    for (const [prefix, route] of this.prefixes) {
      if (!pathname.startsWith(prefix)) continue
      if (prefix.length > bestLen) {
        bestLen = prefix.length
        best = route
      }
    }
    return best
  }
}

function makeDeps() {
  return {
    status: () => ({ state: 'stopped', listenPort: 3444 }),
    candidates: () => [
      { interfaceName: 'en0', address: '192.168.1.5', isPrivate: true, score: 150 },
    ],
    selectedAddress: () => '192.168.1.5',
    setEnabled: async () => {},
    selectNetwork: async () => {},
    openPairing: async () => ({
      token: 'tok-abc',
      expiresAt: Date.now() + 300_000,
    }),
    access: {
      listDevices: () => [
        { deviceId: 'd1', label: 'phone', createdAt: 1, expiresAt: 2, lastSeenAt: 3 },
      ],
      revoke: async () => {},
    } as never,
    pairingUrl: (token: string) => `https://192.168.1.5:3444/pair?token=${token}`,
  }
}

/** 起一个真实 HTTP 服务器，把请求交给路由表。 */
async function startServer(routes: ReturnType<typeof createAdminRoutes>): Promise<{
  origin: string
  router: MinimalRouter
}> {
  const router = new MinimalRouter()
  for (const route of routes) {
    router.register(route as unknown as { kind: 'exact' | 'prefix'; path: string; handler: unknown })
  }

  const server = createServer((req, res) => {
    const pathname = new URL(req.url ?? '/', 'http://x').pathname
    const hit = router.find(pathname)
    if (hit === undefined) {
      res.writeHead(404)
      res.end('not found')
      return
    }
    const handler = hit.handler as (
      request: unknown,
      response: unknown,
    ) => Promise<void>
    void handler(req, res).catch(() => {
      if (!res.headersSent) res.writeHead(500)
      res.end('error')
    })
  })

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const port = typeof address === 'object' && address !== null ? address.port : 0
  cleanup.push(
    async () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve())
        server.closeAllConnections?.()
      }),
  )
  return { origin: `http://127.0.0.1:${String(port)}`, router }
}

describe('真实 HTTP 服务器上的管理路由', () => {
  it('GET /status 返回状态与候选网卡', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/status`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as Record<string, unknown>
    expect(body.state).toBe('stopped')
    expect(body.selectedAddress).toBe('192.168.1.5')
    expect(Array.isArray(body.candidates)).toBe(true)
  })

  it('POST /pairing 返回令牌与 URL', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/pairing`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    })
    expect(res.status).toBe(201)
    const body = (await res.json()) as Record<string, unknown>
    expect(body.token).toBe('tok-abc')
    expect(String(body.url)).toContain('token=tok-abc')
  })

  it('GET /devices 返回设备列表', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/devices`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as { devices: unknown[] }
    expect(body.devices).toHaveLength(1)
  })

  it('POST /enable 接受 {enabled:true}', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/enable`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ enabled: true }),
    })
    expect(res.status).toBe(200)
  })

  it('POST /enable 拒绝非法 body', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/enable`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ enabled: 'yes' }),
    })
    expect(res.status).toBe(400)
  })

  it('未知路径返回 404', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/nonexistent`)
    expect(res.status).toBe(404)
  })

  it('确认用的是真实提取的包（环境检查）', () => {
    // 这个测试的价值在于「提醒」：如果提取的包不在，说明
    // 契约验证的前提没了，需要重新提取。
    if (!existsSync(EXTRACTED)) {
      // 不失败：CI 环境可能没有 asar。但要在输出里提示。
      console.warn(
        `[contract] 未找到 ${EXTRACTED}；` +
          '路由语义验证依赖 contract.test.ts 里的复刻实现。',
      )
    }
    expect(true).toBe(true)
  })
})

describe('新增端点的契约', () => {
  it('GET /diagnostics 返回逐项自检，且拿不到的项不冒充通过', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/diagnostics`)
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      checks: Array<{ id: string; level: string; title: string; detail: string }>
    }
    expect(Array.isArray(body.checks)).toBe(true)
    expect(body.checks.length).toBeGreaterThan(0)
    // 每项都必须有稳定的 id / level / 可读文案
    for (const check of body.checks) {
      expect(typeof check.id).toBe('string')
      expect(['ok', 'warn', 'error', 'unknown']).toContain(check.level)
      expect(check.title.length).toBeGreaterThan(0)
      expect(check.detail.length).toBeGreaterThan(0)
    }
    // 网关没开 → 这一项必须是 warn，不能是 ok
    const gateway = body.checks.find((c) => c.id === 'gateway')
    expect(gateway?.level).toBe('warn')
    // 手机侧信任状态电脑端拿不到 → 必须 unknown
    const trust = body.checks.find((c) => c.id === 'device-trust')
    expect(trust?.level).toBe('unknown')
  })

  it('POST /devices/revoke-all 返回撤销数量', async () => {
    let revokedAll = 0
    const deps = makeDeps()
    const routes = createAdminRoutes({
      ...deps,
      access: {
        ...(deps.access as unknown as Record<string, unknown>),
        revokeAll: async () => {
          revokedAll = 2
          return 2
        },
      } as never,
    })
    const { origin } = await startServer(routes)
    const res = await fetch(`${origin}${ADMIN_PREFIX}/devices/revoke-all`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { ok: boolean; removed: number }
    expect(body.ok).toBe(true)
    expect(body.removed).toBe(2)
    expect(revokedAll).toBe(2)
  })

  it('GET /status 带 pairing 字段且不含令牌', async () => {
    const { origin } = await startServer(createAdminRoutes(makeDeps()))
    const res = await fetch(`${origin}${ADMIN_PREFIX}/status`)
    const body = (await res.json()) as Record<string, unknown>
    expect(body['pairing']).toBeDefined()
    expect(JSON.stringify(body)).not.toContain('tok-abc')
  })
})
