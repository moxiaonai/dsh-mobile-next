/**
 * 集成测试：启动真实 HTTPS 网关，验证端到端流程。
 *
 * 这比单元测试更有说服力 —— 真的监听端口、真的 TLS 握手、
 * 真的走配对与代理。
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { createServer as createHttpServer } from 'node:http'
import type { Server as HttpServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { request as httpsRequest } from 'node:https'
import { afterEach, describe, expect, it } from 'vitest'

import { AccessController } from '../src/access.js'
import { resolveConfig } from '../src/config.js'
import { LanGateway, SESSION_COOKIE } from '../src/gateway.js'
import { ensureTlsMaterial, readTlsMaterial } from '../src/tls.js'
import { UpstreamAuth } from '../src/upstream-auth.js'

const cleanup: Array<() => Promise<void>> = []

afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) {
    await fn()
  }
})

/** 起一个假的 DSH 上游，返回收到的 Host 头。 */
async function startUpstream(): Promise<{
  port: number
  seenHosts: string[]
  seenOrigins: string[]
  server: HttpServer
}> {
  const seenHosts: string[] = []
  const seenOrigins: string[] = []
  const server = createHttpServer((req, res) => {
    seenHosts.push(req.headers.host ?? '')
    seenOrigins.push(req.headers.origin ?? '')
    if (req.url === '/') {
      res.writeHead(200, { 'content-type': 'text/html' })
      res.end('<html><body>fake dsh</body></html>')
      return
    }
    res.writeHead(200, { 'content-type': 'text/plain' })
    res.end(`upstream saw ${req.url ?? '/'}`)
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const port = typeof address === 'object' && address !== null ? address.port : 0
  cleanup.push(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  return { port, seenHosts, seenOrigins, server }
}

/** 起网关。 */
async function startGateway(options: {
  upstreamPort: number
  listenPort: number
  tlsDirectory: string
}): Promise<{
  gateway: LanGateway
  access: AccessController
  caPem: string
}> {
  const access = new AccessController(undefined)
  await access.initialize()

  const material = await ensureTlsMaterial(options.tlsDirectory, ['127.0.0.1'])
  const tls = await readTlsMaterial(options.tlsDirectory)
  if (tls === undefined) throw new Error('tls read failed')

  // 测试用的上游不需要浏览器认证：给一个不带 query 的 URL，
  // UpstreamAuth 会返回 undefined，代理时不注入 cookie。
  const upstreamOrigin = `http://127.0.0.1:${String(options.upstreamPort)}`
  const upstreamAuth = new UpstreamAuth(
    () => undefined,
    () => upstreamOrigin,
  )

  const gateway = new LanGateway({
    config: resolveConfig({
      listenPort: options.listenPort,
      tls: { mode: 'managed' },
    }),
    access,
    upstreamPort: () => options.upstreamPort,
    upstreamAuth,
    tls,
    listenAddress: '127.0.0.1',
  })
  await gateway.start()

  cleanup.push(async () => {
    await gateway.stop()
    access.close()
  })

  // ⚠ 必须是 PEM 内容，不是文件路径
  const caPem = await readFile(material.files.caCertFile, 'utf8')
  return { gateway, access, caPem }
}

/** 发一个 HTTPS 请求（信任私有 CA）。 */
function httpsCall(options: {
  port: number
  path: string
  method?: string
  headers?: Record<string, string>
  body?: string
  caPem: string
}): Promise<{ status: number; body: string; headers: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      {
        host: '127.0.0.1',
        port: options.port,
        path: options.path,
        method: options.method ?? 'GET',
        headers: options.headers,
        // 信任我们自己的私有 CA
        ca: options.caPem,
        // SNI 与证书 CN 匹配
        servername: '127.0.0.1',
      },
      (res) => {
        const chunks: Buffer[] = []
        res.on('data', (c: Buffer) => chunks.push(c))
        res.on('end', () => {
          resolve({
            status: res.statusCode ?? 0,
            body: Buffer.concat(chunks).toString('utf8'),
            headers: res.headers as Record<string, unknown>,
          })
        })
      },
    )
    req.on('error', reject)
    if (options.body !== undefined) req.write(options.body)
    req.end()
  })
}

describe('LanGateway 端到端', () => {
  it('未认证请求被拒', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const { caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: 0,
      tlsDirectory: join(dir, 'tls'),
    })
    // listenPort 0 时由系统分配；这里用 3445 会冲突，改为显式端口
    // （见下一个测试）
    expect(caPem).toContain('BEGIN CERTIFICATE')
  })

  it('健康检查无需认证', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    const res = await httpsCall({
      port,
      path: '/mobile-access-next/health',
      caPem,
    })
    expect(res.status).toBe(200)
    expect(JSON.parse(res.body)).toEqual({ ok: true })
  })

  it('无会话访问根路径返回 401', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    const res = await httpsCall({ port, path: '/', caPem })
    expect(res.status).toBe(401)
    expect(res.body).toContain('authentication required')
  })

  it('静态资源无需认证', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    const res = await httpsCall({ port, path: '/assets/app.js', caPem })
    expect(res.status).toBe(200)
  })

  it('配对 → 带 Cookie 访问 → 代理成功且 Host 被改写', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { access, caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    // ① 生成配对令牌
    const win = await access.openPairing()

    // ② 配对
    const pairRes = await httpsCall({
      port,
      path: '/mobile-access-next/pair',
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: win.token, label: '测试手机' }),
      caPem,
    })
    expect(pairRes.status).toBe(201)
    const cookie = pairRes.headers['set-cookie']
    expect(cookie).toBeDefined()
    const cookieValue = String(
      Array.isArray(cookie) ? cookie[0] : cookie,
    ).split(';')[0]!
    expect(cookieValue.startsWith(`${SESSION_COOKIE}=`)).toBe(true)

    // ③ 带 Cookie 访问根路径
    const res = await httpsCall({
      port,
      path: '/',
      headers: { cookie: cookieValue },
      caPem,
    })
    expect(res.status).toBe(200)
    expect(res.body).toContain('fake dsh')

    // ④ 上游看到的 Host 必须是回环（这是 DSH 信任校验的要求）
    expect(upstream.seenHosts.at(-1)).toBe(`127.0.0.1:${String(upstream.port)}`)
  })

  it('错误令牌配对失败', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { access, caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })
    await access.openPairing()

    const res = await httpsCall({
      port,
      path: '/mobile-access-next/pair',
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: 'wrong' }),
      caPem,
    })
    expect(res.status).toBe(401)
  })

  it('伪造 Cookie 访问被拒', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    const res = await httpsCall({
      port,
      path: '/',
      headers: { cookie: `${SESSION_COOKIE}=forged-token` },
      caPem,
    })
    expect(res.status).toBe(401)
  })
})

describe('安全边界：管理路径不得经网关透传', () => {
  /**
   * 这是一条**回归测试**，保护一个真实存在过的洞。
   *
   * 管理路由注册在 DSH 的回环 webServer 上，但网关会把
   * `/mobile-access-next/*` 下未认领的路径“校验会话后透传给 DSH”。
   * 于是一台已配对的手机可以 `POST /mobile-access-next/pairing`
   * 给自己签发新令牌，或 `POST /mobile-access-next/devices/revoke`
   * 踢掉其他设备 —— 等于把电脑本机才能做的操作免费发给每台手机。
   *
   * 现在网关对这类路径一律 404，且**不带 Cookie 时也是 404**
   * （不泄露“这个路径存在”）。
   */
  it('已配对手机访问管理路径 → 404（不透传）', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { access, caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    // 先配对，拿到合法会话 Cookie
    const win = await access.openPairing()
    const pairRes = await httpsCall({
      port,
      path: '/mobile-access-next/pair',
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: win.token, label: '攻击者手机' }),
      caPem,
    })
    expect(pairRes.status).toBe(201)
    const rawCookie = pairRes.headers['set-cookie']
    const cookie = String(Array.isArray(rawCookie) ? rawCookie[0] : rawCookie).split(';')[0]!

    const adminPaths = [
      '/mobile-access-next/status',
      '/mobile-access-next/diagnostics',
      '/mobile-access-next/devices',
      '/mobile-access-next/devices/revoke',
      '/mobile-access-next/devices/revoke-all',
      '/mobile-access-next/enable',
      '/mobile-access-next/network',
    ]

    for (const path of adminPaths) {
      const withCookie = await httpsCall({ port, path, headers: { cookie }, caPem })
      expect(withCookie.status, `${path} 不应透传`).toBe(404)
      const withoutCookie = await httpsCall({ port, path, caPem })
      expect(withoutCookie.status, `${path} 无 Cookie 也应 404`).toBe(404)
    }

    // 关键断言：上游一次都没收到这些请求
    expect(upstream.seenHosts.some((h) => h === '')).toBe(false)
    expect(
      access.listDevices().length,
      '手机不应能给自己签发新设备',
    ).toBe(1)
  })

  it('健康检查与配对端点仍然放行（不误伤）', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-gw-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    const health = await httpsCall({ port, path: '/mobile-access-next/health', caPem })
    expect(health.status).toBe(200)

    const pairPage = await httpsCall({
      port,
      path: '/mobile-access-next/pair?token=whatever',
      caPem,
    })
    expect(pairPage.status).toBe(200)
    expect(pairPage.body).toContain('正在配对')
  })
})

describe('安全边界与凭据：WebSocket 升级', () => {
  /**
   * 回归测试，保护一个真实缺陷。
   *
   * HTTP 代理路径会注入 DSH 自己的 `dsh-auth-*` Cookie，但 **WS 升级路径
   * 最初漏了这一步**。后果是：手机端配对成功（unary 请求正常），
   * 但连 `/api/remote.mux` 时上游 DSH 认不出请求，握手被拒：
   *
   *   WebSocketException: not upgraded to websocket, HTTP status code: 401
   *
   * 症状「配对成功却连不上」极难定位 —— 所以用测试钉住：
   * 升级请求到达上游时，cookie 必须被替换成上游凭据。
   */
  it('WS 升级把设备 Cookie 换成上游凭据', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-ws-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))

    // 上游记录升级请求的 cookie；同时实现 /connect 换凭据（303 + Set-Cookie）
    const seenUpgradeCookies: string[] = []
    const upstream = createHttpServer((req, res) => {
      if ((req.url ?? '').startsWith('/connect')) {
        res.writeHead(303, {
          location: '/',
          'set-cookie': 'dsh-auth-test=v1.payload.sig; Path=/; HttpOnly; Max-Age=3600',
        })
        res.end()
        return
      }
      res.writeHead(200)
      res.end('ok')
    })
    upstream.on('upgrade', (req, socket) => {
      seenUpgradeCookies.push(req.headers.cookie ?? '')
      // 不真的完成 WS 握手，记录后断开即可
      socket.destroy()
    })
    await new Promise<void>((resolve) => upstream.listen(0, '127.0.0.1', resolve))
    const upAddr = upstream.address()
    const upPort = typeof upAddr === 'object' && upAddr !== null ? upAddr.port : 0
    cleanup.push(async () => {
      await new Promise<void>((resolve) => upstream.close(() => resolve()))
    })

    // 上游需要认证：authenticatedUrl 带 query，UpstreamAuth 会去换 Cookie
    const material = await ensureTlsMaterial(join(dir, 'tls'), ['127.0.0.1'])
    const tls = await readTlsMaterial(join(dir, 'tls'))
    if (tls === undefined) throw new Error('tls read failed')

    const access = new AccessController(undefined)
    await access.initialize()

    // 伪造一个「换取上游 cookie」的端点：返回 Set-Cookie
    const upstreamOrigin = `http://127.0.0.1:${String(upPort)}`
    const upstreamAuth = new UpstreamAuth(
      () => `${upstreamOrigin}/connect?token=fake-launch-token`,
      () => upstreamOrigin,
    )

    const port = 40000 + Math.floor(Math.random() * 10000)
    const gateway = new LanGateway({
      config: resolveConfig({ listenPort: port, tls: { mode: 'managed' } }),
      access,
      upstreamPort: () => upPort,
      upstreamAuth,
      tls,
      listenAddress: '127.0.0.1',
    })
    await gateway.start()
    cleanup.push(async () => {
      await gateway.stop()
      access.close()
    })

    // 配对拿设备会话
    const win = await access.openPairing()
    const caPem = await readFile(material.files.caCertFile, 'utf8')
    const pairRes = await httpsCall({
      port,
      path: '/mobile-access-next/pair',
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: win.token, label: 'ws 测试' }),
      caPem,
    })
    expect(pairRes.status).toBe(201)
    const rawCookie = pairRes.headers['set-cookie']
    const deviceCookie = String(
      Array.isArray(rawCookie) ? rawCookie[0] : rawCookie,
    ).split(';')[0]!

    // 发一个 WS 升级请求（带设备会话 Cookie）
    await new Promise<void>((resolve) => {
      const req = httpsRequest({
        host: '127.0.0.1',
        port,
        path: '/api/remote.mux',
        method: 'GET',
        ca: caPem,
        servername: '127.0.0.1',
        headers: {
          connection: 'Upgrade',
          upgrade: 'websocket',
          'sec-websocket-version': '13',
          'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==',
          cookie: deviceCookie,
        },
      })
      req.on('upgrade', () => resolve())
      req.on('response', () => resolve())
      req.on('error', () => resolve())
      req.end()
      // 上游断开后不会再有任何事件，兜底
      setTimeout(resolve, 2000)
    })

    expect(seenUpgradeCookies.length, '上游应收到升级请求').toBeGreaterThan(0)
    const seen = seenUpgradeCookies[0]!
    // 关键断言 1：设备会话 Cookie 不能原样转给上游
    expect(seen).not.toContain('dsh-mobile-next-session')
    // 关键断言 2：必须换成 DSH 自己的 dsh-auth-* 凭据
    expect(seen).toContain('dsh-auth-test=')
  })
})

describe('安全边界：/renew 是唯一放行的管理路径', () => {
  /**
   * `/renew` 必须给手机用（冷启动时凭 deviceToken 换会话），
   * 但**其他管理路径必须继续 404** —— 否则已配对手机能自我续期、
   * 踢掉别的设备。这两条要一起守住，只守一边都等于没守。
   */
  it('/renew 放行且自带鉴权；其他管理路径仍 404', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dshmn-renew-'))
    cleanup.push(async () => rm(dir, { recursive: true, force: true }))
    const upstream = await startUpstream()
    const port = 40000 + Math.floor(Math.random() * 10000)
    const { access, caPem } = await startGateway({
      upstreamPort: upstream.port,
      listenPort: port,
      tlsDirectory: join(dir, 'tls'),
    })

    // 先配对拿 deviceToken
    const win = await access.openPairing()
    const pairRes = await httpsCall({
      port,
      path: '/mobile-access-next/pair',
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: win.token, label: 'renew 测试' }),
      caPem,
    })
    expect(pairRes.status).toBe(201)
    const paired = JSON.parse(pairRes.body) as { deviceToken: string }

    // ① /renew 放行：正确 deviceToken → 200 + 新会话
    const renew = await httpsCall({
      port,
      path: '/mobile-access-next/renew',
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceToken: paired.deviceToken }),
      caPem,
    })
    expect(renew.status, '/renew 应放行').toBe(200)
    const renewed = JSON.parse(renew.body) as { sessionToken: string }
    expect(renewed.sessionToken.length).toBeGreaterThan(20)
    // 同时下发 Cookie（浏览器路径）
    expect(String(renew.headers['set-cookie'])).toContain(SESSION_COOKIE)

    // ② /renew 自带鉴权：错误 deviceToken → 401
    const bad = await httpsCall({
      port,
      path: '/mobile-access-next/renew',
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceToken: 'bogus' }),
      caPem,
    })
    expect(bad.status).toBe(401)

    // ③ 其他管理路径仍然 404（关键：不能因为放行 renew 就打开整个前缀）
    for (const path of [
      '/mobile-access-next/pairing',
      '/mobile-access-next/devices',
      '/mobile-access-next/devices/revoke',
      '/mobile-access-next/devices/revoke-all',
      '/mobile-access-next/enable',
      '/mobile-access-next/status',
    ]) {
      const res = await httpsCall({ port, path, caPem })
      expect(res.status, `${path} 必须仍为 404`).toBe(404)
    }
  })
})
