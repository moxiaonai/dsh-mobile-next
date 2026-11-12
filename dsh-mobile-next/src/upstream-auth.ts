/**
 * 上游凭据交换。
 *
 * ## 为什么必须有这一层
 *
 * 这是整个插件最容易漏掉的一环，也是我实测踩到的坑。
 *
 * DSH 的 Web 页面**自己也要求认证**：它用 `ctx.connection.authorizeIndex`
 * 校验一个 `dsh-auth-*` 签名 Cookie，密钥在 `$DSH_HOME/.credentials.yaml`。
 *
 * 所以只做「设备认证」是不够的：
 *
 * ```
 * 手机 --[我的会话Cookie]--> 我的网关 --[无 Cookie]--> DSH
 *                                                      ↓
 *                                          "dsh web authentication required"
 * ```
 *
 * 实测现象：我的 401 没出现，反而看到 DSH 自己的认证错误。
 * 一开始误以为是我的会话校验失败，查了很久。
 *
 * ## 正确做法（照参考实现 `dsh-mobile`）
 *
 * DSH 通过 `ctx.connection.authenticatedUrl(origin)` 给出一个**带 launch token**
 * 的 URL。用 GET 请求它，DSH 会：
 * - 校验 launch token
 * - 返回 `303 See Other` + `Set-Cookie: dsh-auth-...`
 *
 * 拿到这个 Cookie 后注入每个代理请求，DSH 就认了。
 *
 * ## 缓存
 *
 * Cookie 有 `Max-Age`，缓存到过期前 60 秒。Host 重启后 launch token 失效，
 * 需要重新交换 —— 交换失败时清缓存并重试一次。
 */

import { request as httpRequest } from 'node:http'
import type { IncomingMessage } from 'node:http'

/** 交换失败。 */
export class UpstreamAuthError extends Error {
  constructor(
    readonly stage: string,
    message: string,
  ) {
    super(message)
    this.name = 'UpstreamAuthError'
  }
}

/** 上游凭据持有者。 */
export class UpstreamAuth {
  #cookie: string | undefined
  #expiresAt = 0
  #inFlight: Promise<string | undefined> | undefined

  constructor(
    /** 带 launch token 的 URL（由 DSH 的 connection 服务提供）。 */
    private readonly authenticatedUrl: () => string | undefined,
    /** DSH 的回环 origin，例如 `http://127.0.0.1:62642`。 */
    private readonly upstreamOrigin: () => string | undefined,
    private readonly timeoutMs = 10_000,
  ) {}

  /** 清缓存（Host 重启后调用）。 */
  invalidate(): void {
    this.#cookie = undefined
    this.#expiresAt = 0
  }

  /**
   * 拿一个可用的上游 Cookie。
   *
   * 返回 `undefined` 表示「上游不需要浏览器认证」——
   * 例如某些配置下 `authenticatedUrl` 不带 query。
   */
  async cookie(): Promise<string | undefined> {
    const now = Date.now()
    if (this.#cookie !== undefined && this.#expiresAt - 60_000 > now) {
      return this.#cookie
    }
    // 合并并发交换
    this.#inFlight ??= this.#exchange().finally(() => {
      this.#inFlight = undefined
    })
    return this.#inFlight
  }

  async #exchange(): Promise<string | undefined> {
    const url = this.authenticatedUrl()
    const origin = this.upstreamOrigin()
    if (origin === undefined) {
      throw new UpstreamAuthError('origin', 'upstream origin unavailable')
    }
    // 没有 URL 或 URL 不带 query：上游不需要认证
    if (url === undefined) return undefined

    let target: URL
    try {
      target = new URL(url)
    } catch {
      throw new UpstreamAuthError('url', 'authenticatedUrl is not a URL')
    }
    if (target.search === '') return undefined

    const upstream = new URL(origin)
    if (target.origin !== upstream.origin) {
      throw new UpstreamAuthError(
        'origin',
        `authenticatedUrl origin ${target.origin} != upstream ${upstream.origin}`,
      )
    }

    const response = await this.#get(upstream, target)
    if (response.statusCode !== 303) {
      // 读一点响应体，便于判断是 401 还是别的
      let snippet = ''
      try {
        for await (const chunk of response) {
          snippet += (chunk as Buffer).toString('utf8')
          if (snippet.length > 120) break
        }
      } catch {
        // 读失败不影响报错
      }
      throw new UpstreamAuthError(
        'status',
        `expected 303, got ${String(response.statusCode ?? 0)}: ${snippet.slice(0, 100)}`,
      )
    }

    const setCookie = response.headers['set-cookie']?.[0]
    const pair = setCookie?.split(';', 1)[0]
    if (pair === undefined || pair === '') {
      throw new UpstreamAuthError('cookie', 'no Set-Cookie in exchange response')
    }
    if (!/^dsh-auth-[A-Za-z0-9_-]+=/u.test(pair)) {
      throw new UpstreamAuthError('cookie', `unexpected cookie name in ${pair.slice(0, 24)}`)
    }

    const maxAgeText = setCookie === undefined
      ? undefined
      : /(?:^|;\s*)Max-Age=(\d+)(?:;|$)/iu.exec(setCookie)?.[1]
    const maxAge = maxAgeText === undefined ? 30 * 24 * 3600 : Number(maxAgeText)
    if (!Number.isFinite(maxAge) || maxAge <= 0) {
      throw new UpstreamAuthError('cookie', 'invalid Max-Age')
    }

    this.#cookie = pair
    this.#expiresAt = Date.now() + maxAge * 1000
    return pair
  }

  #get(upstream: URL, target: URL): Promise<IncomingMessage> {
    return new Promise((resolve, reject) => {
      const request = httpRequest(
        {
          protocol: 'http:',
          hostname: upstream.hostname,
          port: Number(upstream.port),
          method: 'GET',
          path: `${target.pathname}${target.search}`,
          headers: {
            // Host 必须是上游的 authority（DSH 的信任校验）
            host: upstream.host,
            accept: 'text/html',
            'accept-encoding': 'identity',
            'sec-fetch-mode': 'same-origin',
          },
          agent: false,
        },
        resolve,
      )
      request.setTimeout(this.timeoutMs, () => {
        request.destroy(new UpstreamAuthError('timeout', 'exchange timed out'))
      })
      request.once('error', reject)
      request.end()
    })
  }
}
