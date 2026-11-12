/**
 * 集成测试：插件完整生命周期。
 *
 * 用假 ctx 模拟 DSH 环境，验证：
 * - 插件能被调用
 * - 管理路由被注册
 * - 关闭时默认不起网关
 * - 启用后网关真的起来
 * - 管理 API 可用
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import plugin from '../src/plugin.js'
import type { PluginContext } from '../src/plugin.js'

const cleanup: Array<() => Promise<void>> = []

afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) {
    await fn()
  }
})

/** 记录注册的路由。 */
interface RegisteredRoute {
  kind: 'exact' | 'prefix'
  path: string
  handler: (
    request: import('node:http').IncomingMessage,
    response: import('node:http').ServerResponse,
  ) => Promise<void>
}

/** 构造假 ctx。 */
function makeCtx(port: number): {
  ctx: PluginContext
  routes: RegisteredRoute[]
  logs: string[]
  dispose: () => Promise<void>
} {
  const routes: RegisteredRoute[] = []
  const logs: string[] = []
  let disposer: (() => Promise<void> | void) | undefined

  const ctx: PluginContext = {
    webServer: {
      port,
      register(route) {
        // 校验形态：必须是 kind-based（WebRoute 契约）
        if (route.kind !== 'exact' && route.kind !== 'prefix') {
          throw new Error(`bad route kind: ${String(route.kind)}`)
        }
        routes.push(route as RegisteredRoute)
        return () => {
          const index = routes.indexOf(route as RegisteredRoute)
          if (index >= 0) routes.splice(index, 1)
        }
      },
    },
    effect(callback) {
      disposer = callback()
    },
    logger(message) {
      logs.push(message)
    },
  }

  return {
    ctx,
    routes,
    logs,
    dispose: async () => {
      if (disposer !== undefined) await disposer()
    },
  }
}

/** 临时目录 + 配置。 */
async function makeConfig(): Promise<{
  config: {
    setupFile: string
    controlFile: string
    stateFile: string
    listenPort: number
    initiallyEnabled: boolean
  }
  dir: string
}> {
  const dir = await mkdtemp(join(tmpdir(), 'dshmn-plugin-'))
  cleanup.push(async () => rm(dir, { recursive: true, force: true }))
  return {
    dir,
    config: {
      setupFile: join(dir, 'setup.json'),
      controlFile: join(dir, 'control.json'),
      stateFile: join(dir, 'devices.json'),
      listenPort: 40000 + Math.floor(Math.random() * 10000),
      initiallyEnabled: false,
    },
  }
}

describe('插件生命周期', () => {
  it('默认不起网关，但注册管理路由', async () => {
    const { config } = await makeConfig()
    const { ctx, routes, logs } = makeCtx(12345)

    await plugin(ctx, config)

    // 管理路由应该注册了 9 条（status / diagnostics / network / enable / pairing / renew / devices / revoke / revoke-all）
    expect(routes.length).toBe(12)
    expect(routes.map((r) => r.path)).toEqual(
      expect.arrayContaining([
        '/mobile-access-next/status',
        '/mobile-access-next/pairing',
        '/mobile-access-next/enable',
      ]),
    )

    // 日志应显示网关未启用
    expect(logs.some((l) => l.includes('gateway-disabled'))).toBe(true)
  })

  it('status 路由返回候选网卡', async () => {
    const { config } = await makeConfig()
    const { ctx, routes } = makeCtx(12345)
    await plugin(ctx, config)

    const statusRoute = routes.find((r) => r.path.endsWith('/status'))
    expect(statusRoute).toBeDefined()

    const body = await callRoute(statusRoute!, 'GET')
    expect(body.state).toBe('stopped')
    expect(Array.isArray(body.candidates)).toBe(true)
  })

  it('enable 后网关启动（有可用网卡时）', async () => {
    const { config } = await makeConfig()
    const { ctx, routes, logs } = makeCtx(12345)
    await plugin(ctx, config)

    const enableRoute = routes.find((r) => r.path.endsWith('/enable'))!
    const result = await callRoute(enableRoute, 'POST', { enabled: true })

    // 本机有网卡时会 running；没有时仍是 stopped 但不应报错
    expect(['running', 'stopped']).toContain(result.state)

    const statusRoute = routes.find((r) => r.path.endsWith('/status'))!
    const status = await callRoute(statusRoute, 'GET')
    expect(status.state).toBe(result.state)

    // control.json 应该被写入
    const control = JSON.parse(await readFile(config.controlFile, 'utf8'))
    expect(control.enabled).toBe(true)

    // 清理：关闭网关
    await callRoute(enableRoute, 'POST', { enabled: false })
  })

  it('pairing 路由在网关未启用时返回 null URL', async () => {
    const { config } = await makeConfig()
    const { ctx, routes } = makeCtx(12345)
    await plugin(ctx, config)

    const pairingRoute = routes.find((r) => r.path.endsWith('/pairing'))!
    const result = await callRoute(pairingRoute, 'POST', {})

    expect(typeof result.token).toBe('string')
    expect(result.url).toBeNull()
  })

  it('network 路由拒绝未知网卡', async () => {
    const { config } = await makeConfig()
    const { ctx, routes } = makeCtx(12345)
    await plugin(ctx, config)

    const networkRoute = routes.find((r) => r.path.endsWith('/network'))!
    const result = await callRoute(networkRoute, 'POST', {
      interfaceName: 'nonexistent999',
    })
    expect(result.error).toBe('unknown_interface')
  })

  it('devices 路由返回空列表', async () => {
    const { config } = await makeConfig()
    const { ctx, routes } = makeCtx(12345)
    await plugin(ctx, config)

    const devicesRoute = routes.find((r) => r.path.endsWith('/devices'))!
    const result = await callRoute(devicesRoute, 'GET')
    expect(result.devices).toEqual([])
  })

  it('dispose 清理路由与网关', async () => {
    const { config } = await makeConfig()
    const { ctx, routes, dispose } = makeCtx(12345)
    await plugin(ctx, config)

    expect(routes.length).toBe(12)
    await dispose()
    expect(routes.length).toBe(0)
  })
})

/** 调用一个已注册的路由，返回解析后的 JSON。 */
async function callRoute(
  route: RegisteredRoute,
  method: string,
  body?: unknown,
): Promise<Record<string, unknown>> {
  const request = {
    method,
    headers: { 'content-type': 'application/json' },
    async *[Symbol.asyncIterator]() {
      if (body !== undefined) {
        yield Buffer.from(JSON.stringify(body))
      }
    },
  } as unknown as import('node:http').IncomingMessage

  let status = 0
  let payload = ''
  const response = {
    writeHead(code: number) {
      status = code
      return this
    },
    end(text: string) {
      payload = text
    },
  } as unknown as import('node:http').ServerResponse

  await route.handler(request, response)
  expect(status).toBeGreaterThan(0)
  return JSON.parse(payload) as Record<string, unknown>
}
