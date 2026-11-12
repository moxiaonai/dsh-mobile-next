/**
 * 测试：GET 配对页（二维码扫码入口）。
 *
 * ## 为什么需要它
 *
 * 二维码内容只能是一个 URL，**扫码必然是 GET 请求**。
 * 若二维码指向 POST 端点，扫码会得到 405。
 *
 * 我最初就把二维码指向了 POST 的 `/pair`，实测扫码 405。
 * 修复是加一个 GET 页面，它渲染 HTML 并自动提交 POST。
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { request as httpsRequest } from 'node:https'
import { afterEach, describe, expect, it } from 'vitest'

import { AccessController } from '../src/access.js'
import { resolveConfig } from '../src/config.js'
import { AUTH_PREFIX, LanGateway } from '../src/gateway.js'
import { ensureTlsMaterial, readTlsMaterial } from '../src/tls.js'
import { UpstreamAuth } from '../src/upstream-auth.js'

const cleanup: Array<() => Promise<void>> = []

afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) {
    await fn()
  }
})

/** 起一个隔离网关。 */
async function startGateway(): Promise<{
  port: number
  access: AccessController
  caPem: string
}> {
  const dir = await mkdtemp(join(tmpdir(), 'dshmn-pair-'))
  cleanup.push(async () => rm(dir, { recursive: true, force: true }))

  const access = new AccessController(undefined)
  await access.initialize()

  await ensureTlsMaterial(join(dir, 'tls'), ['127.0.0.1'])
  const tls = await readTlsMaterial(join(dir, 'tls'))
  if (tls === undefined) throw new Error('tls read failed')

  const port = 45000 + Math.floor(Math.random() * 2000)
  const gateway = new LanGateway({
    config: resolveConfig({ listenPort: port, tls: { mode: 'managed' } }),
    access,
    upstreamPort: () => 1,
    upstreamAuth: new UpstreamAuth(() => undefined, () => 'http://127.0.0.1:1'),
    tls,
    listenAddress: '127.0.0.1',
  })
  await gateway.start()
  cleanup.push(async () => {
    await gateway.stop()
    access.close()
  })

  return {
    port,
    access,
    caPem: await readFile(join(dir, 'tls', 'ca.pem'), 'utf8'),
  }
}

function call(options: {
  port: number
  path: string
  method?: string
  body?: string
  caPem: string
}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      {
        host: '127.0.0.1',
        port: options.port,
        path: options.path,
        method: options.method ?? 'GET',
        ca: options.caPem,
        servername: '127.0.0.1',
        headers: options.body === undefined
          ? undefined
          : { 'content-type': 'application/json' },
      },
      (res) => {
        const chunks: Buffer[] = []
        res.on('data', (c: Buffer) => chunks.push(c))
        res.on('end', () =>
          resolve({
            status: res.statusCode ?? 0,
            body: Buffer.concat(chunks).toString('utf8'),
          }),
        )
      },
    )
    req.on('error', reject)
    if (options.body !== undefined) req.write(options.body)
    req.end()
  })
}

describe('GET 配对页（扫码入口）', () => {
  it('GET 带 token 返回 HTML 页面', async () => {
    const gw = await startGateway()
    const win = await gw.access.openPairing()
    const res = await call({
      port: gw.port,
      path: `${AUTH_PREFIX}/pair?token=${win.token}`,
      caPem: gw.caPem,
    })
    expect(res.status).toBe(200)
    expect(res.body).toContain('<!doctype html>')
    expect(res.body).toContain('<title>')
  })

  it('页面内嵌 token 与自动提交脚本', async () => {
    const gw = await startGateway()
    const win = await gw.access.openPairing()
    const res = await call({
      port: gw.port,
      path: `${AUTH_PREFIX}/pair?token=${win.token}`,
      caPem: gw.caPem,
    })
    // 页面必须自己带着 token 去 POST
    expect(res.body).toContain(win.token)
    expect(res.body).toContain('fetch(')
    expect(res.body).toContain("method: 'POST'")
  })

  it('无 token 返回 400', async () => {
    const gw = await startGateway()
    const res = await call({
      port: gw.port,
      path: `${AUTH_PREFIX}/pair`,
      caPem: gw.caPem,
    })
    expect(res.status).toBe(400)
  })

  it('POST 仍然走配对接口（不是 HTML）', async () => {
    const gw = await startGateway()
    const win = await gw.access.openPairing()
    const res = await call({
      port: gw.port,
      path: `${AUTH_PREFIX}/pair`,
      method: 'POST',
      body: JSON.stringify({ token: win.token }),
      caPem: gw.caPem,
    })
    expect(res.status).toBe(201)
    // 返回 JSON 而不是 HTML
    expect(res.body.trim().startsWith('{')).toBe(true)
    expect(res.body).toContain('deviceToken')
  })

  it('页面不泄露长期凭据', async () => {
    const gw = await startGateway()
    const win = await gw.access.openPairing()
    const res = await call({
      port: gw.port,
      path: `${AUTH_PREFIX}/pair?token=${win.token}`,
      caPem: gw.caPem,
    })
    // 页面里不应出现 deviceToken 字段名（那是配对成功后才有的）
    expect(res.body).not.toContain('deviceToken')
  })
})
