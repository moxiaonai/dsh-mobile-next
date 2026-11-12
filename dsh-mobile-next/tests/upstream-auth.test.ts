/**
 * 测试：上游凭据交换。
 *
 * 这是本插件最容易漏的一环，用真实 HTTP 服务器验证交换语义。
 */

import { createServer } from 'node:http'
import type { Server } from 'node:http'
import { afterEach, describe, expect, it } from 'vitest'

import { UpstreamAuth, UpstreamAuthError } from '../src/upstream-auth.js'

const cleanup: Array<() => Promise<void>> = []

afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) {
    await fn()
  }
})

/** 起一个假的 DSH 上游，模拟 launch token 交换。 */
async function startFakeDsh(options: {
  /** 交换时返回的状态码。 */
  status?: number
  /** Set-Cookie 的 Max-Age。 */
  maxAge?: number
  /** 是否返回 Cookie。 */
  withCookie?: boolean
  /** Cookie 名。 */
  cookieName?: string
} = {}): Promise<{
  origin: string
  token: string
  hits: Array<{ path: string; cookie: string | undefined }>
}> {
  const token = 'launch-token-abc'
  const hits: Array<{ path: string; cookie: string | undefined }> = []

  const server: Server = createServer((req, res) => {
    hits.push({
      path: req.url ?? '/',
      cookie: req.headers.cookie as string | undefined,
    })
    // 只接受带正确 token 的根路径
    if (req.url === `/?token=${token}`) {
      if (options.status !== undefined && options.status !== 303) {
        res.writeHead(options.status)
        res.end('nope')
        return
      }
      const headers: Record<string, string> = { location: './' }
      if (options.withCookie !== false) {
        const name = options.cookieName ?? 'dsh-auth-abcdef'
        headers['set-cookie'] =
          `${name}=v1.payload.sig; Path=/; HttpOnly; SameSite=Strict; Max-Age=${String(options.maxAge ?? 2592000)}`
      }
      res.writeHead(303, headers)
      res.end()
      return
    }
    res.writeHead(404)
    res.end('not found')
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
  return { origin: `http://127.0.0.1:${String(port)}`, token, hits }
}

describe('UpstreamAuth 交换', () => {
  it('成功交换出 dsh-auth Cookie', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=${dsh.token}`,
      () => dsh.origin,
    )
    const cookie = await auth.cookie()
    expect(cookie).toBeDefined()
    expect(cookie!.startsWith('dsh-auth-')).toBe(true)
    // 请求确实带了 token
    expect(dsh.hits[0]!.path).toBe(`/?token=${dsh.token}`)
  })

  it('缓存：第二次不重复请求', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=${dsh.token}`,
      () => dsh.origin,
    )
    await auth.cookie()
    await auth.cookie()
    await auth.cookie()
    expect(dsh.hits).toHaveLength(1)
  })

  it('并发请求合并为一次交换', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=${dsh.token}`,
      () => dsh.origin,
    )
    await Promise.all([auth.cookie(), auth.cookie(), auth.cookie()])
    expect(dsh.hits).toHaveLength(1)
  })

  it('invalidate 后重新交换', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=${dsh.token}`,
      () => dsh.origin,
    )
    await auth.cookie()
    auth.invalidate()
    await auth.cookie()
    expect(dsh.hits).toHaveLength(2)
  })

  it('URL 不带 query 时返回 undefined（上游无需认证）', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/`,
      () => dsh.origin,
    )
    expect(await auth.cookie()).toBeUndefined()
    expect(dsh.hits).toHaveLength(0)
  })

  it('无 authenticatedUrl 时返回 undefined', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => undefined,
      () => dsh.origin,
    )
    expect(await auth.cookie()).toBeUndefined()
  })

  it('非 303 状态被拒', async () => {
    const dsh = await startFakeDsh({ status: 200 })
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=${dsh.token}`,
      () => dsh.origin,
    )
    await expect(auth.cookie()).rejects.toBeInstanceOf(UpstreamAuthError)
  })

  it('没有 Set-Cookie 被拒', async () => {
    const dsh = await startFakeDsh({ withCookie: false })
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=${dsh.token}`,
      () => dsh.origin,
    )
    await expect(auth.cookie()).rejects.toMatchObject({ stage: 'cookie' })
  })

  it('Cookie 名不是 dsh-auth-* 被拒', async () => {
    const dsh = await startFakeDsh({ cookieName: 'evil-cookie' })
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=${dsh.token}`,
      () => dsh.origin,
    )
    await expect(auth.cookie()).rejects.toMatchObject({ stage: 'cookie' })
  })

  it('origin 不匹配被拒（防 SSRF）', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => `${dsh.origin}/?token=x`,
      () => 'http://127.0.0.1:1',
    )
    await expect(auth.cookie()).rejects.toMatchObject({ stage: 'origin' })
  })

  it('非法 URL 被拒', async () => {
    const dsh = await startFakeDsh()
    const auth = new UpstreamAuth(
      () => 'not-a-url',
      () => dsh.origin,
    )
    await expect(auth.cookie()).rejects.toMatchObject({ stage: 'url' })
  })

  it('上游 origin 缺失时报错', async () => {
    const auth = new UpstreamAuth(
      () => 'http://127.0.0.1:1/?token=x',
      () => undefined,
    )
    await expect(auth.cookie()).rejects.toMatchObject({ stage: 'origin' })
  })
})
