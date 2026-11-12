/**
 * 局域网 HTTPS 网关。
 *
 * ## 职责
 *
 * 把手机的 HTTPS 请求**反向代理**到 DSH 自己的回环 Web 端口：
 *
 * ```
 * 手机 --HTTPS--> 本网关(:3444) --HTTP--> DSH(127.0.0.1:xxxx)
 * ```
 *
 * ## 为什么是代理而不是改 DSH
 *
 * DSH 的 Web 监听是回环专用的，并且有 Host/Origin 信任校验
 * （`api-request-trust.ts`：Host 必须是回环或监听器绑定 IP）。
 * 手机访问时 Host 是局域网 IP，会被拒。
 *
 * 代理层把 Host 改写成回环，同时**自己完成认证** —— 这正是参考实现
 * `dsh-mobile` 做的事，也是它为什么必须做成插件而不是简单反代。
 *
 * ## 认证边界
 *
 * - 静态资源（`/assets/*`、`/favicon*`）：**不要求**会话，否则登录页都打不开
 * - 配对端点（`/mobile-access-next/*`）：自己校验配对令牌
 * - 其余一切：要求有效会话 Cookie
 *
 * ## 不做什么
 *
 * 不实现 WebSocket 代理的路径白名单、不实现远程隧道、不做压缩协商。
 * 这些留到后续迭代；前期只保证"手机能安全看到 DSH 界面"。
 */

import { createServer as createHttpsServer } from 'node:https'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Server } from 'node:https'
import { request as httpRequest } from 'node:http'

import { AccessController, AccessError } from './access.js'
import { UpstreamAuth } from './upstream-auth.js'
import type { ResolvedConfig } from './config.js'

/** 会话 Cookie 名。 */
export const SESSION_COOKIE = 'dsh-mobile-next-session'

/** 配对相关路径前缀。 */
export const AUTH_PREFIX = '/mobile-access-next'

/** 网关状态。 */
export type GatewayState = 'stopped' | 'starting' | 'running' | 'error'

/** 网关信息（供面板展示）。 */
export interface GatewayInfo {
  readonly state: GatewayState
  readonly origin?: string
  readonly listenPort?: number
  readonly caFingerprint?: string
  readonly error?: string
}

export interface GatewayOptions {
  readonly config: ResolvedConfig
  readonly access: AccessController
  /** DSH 真实回环端口。 */
  readonly upstreamPort: () => number | undefined
  /**
   * 上游凭据。
   *
   * ⚠ 没有它时，代理出去的请求会被 **DSH 自己**的浏览器认证拒绝
   * （"dsh web authentication required"）—— 不是我们的 401。
   * 这是本插件最容易漏的一环。
   */
  readonly upstreamAuth: UpstreamAuth
  readonly tls: { readonly cert: string; readonly key: string; readonly caFingerprint: string }
  /** 监听地址（网卡 IPv4）。 */
  readonly listenAddress: string
  /** 独立远程网关的公网入口；动态读取临时隧道地址。 */
  readonly publicOrigin?: () => string | undefined
  readonly listenPort?: number
  readonly log?: (event: string, fields: Record<string, unknown>) => void
}

/** 需要放行的静态路径（未认证也可访问）。 */
function isPublicAsset(pathname: string): boolean {
  return (
    pathname.startsWith('/assets/') ||
    pathname.startsWith('/favicon') ||
    pathname === '/manifest.webmanifest' ||
    pathname === '/apple-touch-icon.png' ||
    pathname === '/icon-192.png' ||
    pathname === '/icon-512.png'
  )
}

/** 从 Cookie 头解析会话令牌。 */
function readSessionCookie(header: string | undefined): string | undefined {
  if (header === undefined) return undefined
  for (const part of header.split(';')) {
    const eq = part.indexOf('=')
    if (eq < 0) continue
    const name = part.slice(0, eq).trim()
    if (name !== SESSION_COOKIE) continue
    return decodeURIComponent(part.slice(eq + 1).trim())
  }
  return undefined
}

/** 发一个简短的纯文本响应。 */
function sendText(
  response: ServerResponse,
  status: number,
  text: string,
): void {
  response.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
  })
  response.end(text)
}

/** 发 JSON。 */
function sendJson(
  response: ServerResponse,
  status: number,
  body: unknown,
): void {
  const text = JSON.stringify(body)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
  })
  response.end(text)
}

/** 读取 JSON 请求体（有上限）。 */
async function readJsonBody(
  request: IncomingMessage,
  limit = 16 * 1024,
): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of request) {
    const buf = chunk as Buffer
    total += buf.length
    if (total > limit) throw new AccessError(413, 'body_too_large')
    chunks.push(buf)
  }
  if (total === 0) return {}
  try {
    const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new AccessError(400, 'bad_request')
    }
    return parsed as Record<string, unknown>
  } catch (error) {
    if (error instanceof AccessError) throw error
    throw new AccessError(400, 'bad_request')
  }
}

/**
 * 局域网网关。
 */
export class LanGateway {
  #connections = new Set<import('node:stream').Duplex>()
  #server: Server | undefined
  #state: GatewayState = 'stopped'
  #error: string | undefined
  #info: GatewayInfo = { state: 'stopped' }

  constructor(private readonly options: GatewayOptions) {}

  get state(): GatewayState {
    return this.#state
  }

  get info(): GatewayInfo {
    return this.#info
  }

  get origin(): string | undefined {
    return this.#info.origin
  }

  /** 启动监听。 */
  async start(): Promise<void> {
    if (this.#state === 'running') return
    this.#state = 'starting'
    try {
      const server = createHttpsServer(
        { cert: this.options.tls.cert, key: this.options.tls.key },
        (request, response) => {
          void this.#handle(request, response)
        },
      )

      server.on('connection', socket => {
        this.#connections.add(socket)
        socket.once('close', () => this.#connections.delete(socket))
      })

      // WebSocket 升级：转发到上游，由 DSH 自己处理
      server.on('upgrade', (request, socket, head) => {
        this.#handleUpgrade(request, socket, head)
      })

      await new Promise<void>((resolve, reject) => {
        const onError = (error: Error): void => {
          server.off('listening', onListening)
          reject(error)
        }
        const onListening = (): void => {
          server.off('error', onError)
          resolve()
        }
        server.once('error', onError)
        server.once('listening', onListening)
        server.listen(
          this.options.listenPort ?? this.options.config.listenPort,
          this.options.listenAddress,
        )
      })

      this.#server = server
      this.#state = 'running'
      this.#error = undefined
      const address = server.address()
      const port = typeof address === 'object' && address !== null ? address.port : this.options.config.listenPort
      this.#info = {
        state: 'running',
        origin: `https://${this.options.listenAddress}:${port}`,
        listenPort: port,
        caFingerprint: this.options.tls.caFingerprint,
      }
      this.options.log?.('gateway-started', {
        address: this.options.listenAddress,
        port,
      })
    } catch (error) {
      this.#state = 'error'
      this.#error = error instanceof Error ? error.message : String(error)
      this.#info = { state: 'error', error: this.#error }
      this.options.log?.('gateway-start-failed', { error: this.#error })
      throw error
    }
  }

  /** 停止监听。 */
  async stop(): Promise<void> {
    const server = this.#server
    this.#server = undefined
    this.#state = 'stopped'
    this.#info = { state: 'stopped' }
    for (const socket of this.#connections) socket.destroy()
    this.#connections.clear()
    if (server === undefined) return
    await new Promise<void>((resolve) => {
      server.close(() => resolve())
      // 主动断开保活连接，否则 close 可能等很久
      server.closeAllConnections?.()
    })
  }

  /** 浏览器跨站写操作与升级在改写 Origin 前校验；原生客户端可省略 Origin。 */
  #trustedOrigin(request: IncomingMessage): boolean {
    const expected = this.options.publicOrigin?.() ?? this.origin
    if (this.options.publicOrigin !== undefined && expected === undefined) {
      return request.method === 'GET' && request.url === `${AUTH_PREFIX}/health`
    }
    const origin = request.headers.origin
    if (origin !== undefined && origin !== expected) return false
    const site = request.headers['sec-fetch-site']
    return site !== 'cross-site'
  }

  /** 处理一个 HTTP 请求。 */
  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    try {
      const url = request.url ?? '/'
      const pathname = new URL(url, 'https://placeholder').pathname
      if (!this.#trustedOrigin(request)) {
        sendJson(response, 403, { error: 'untrusted_origin' })
        return
      }

      // ① 配对端点：自己处理，不代理
      if (pathname === `${AUTH_PREFIX}/pair`) {
        if (request.method === 'GET') {
          await this.#handlePairPage(request, response)
          return
        }
        await this.#handlePair(request, response)
        return
      }
      if (pathname === `${AUTH_PREFIX}/health`) {
        sendJson(response, 200, { ok: true })
        return
      }

      // ①b 其余管理路径：**一律 404**，绝不透传。
      //
      // ⚠ 这是安全边界，不是可选优化。
      //
      // 管理路由（`/status` `/pairing` `/devices/revoke` …）注册在 DSH 自己的
      // **回环** webServer 上，只有电脑本机能调。但网关会把 `/mobile-access-next/*`
      // 下**未认领**的路径在“校验会话后透传给 DSH”——而管理路由正好在那边。
      // 于是一台已配对的手机可以：
      //   - `POST /mobile-access-next/pairing` 给自己签发新令牌（无限自我续期）
      //   - `POST /mobile-access-next/devices/revoke` 踢掉其他设备
      //
      // 实测踩过：这个洞是“新增管理端点”之前必须先堵的，否则每加一个端点
      // 就等于把它免费发给每台已配对手机。
      //
      // 顺带的好处：漏注册的新端点会立刻 404 暴露，而不是变成需要排查的谜。
      // 唯一的例外：`/renew` 必须给手机用。
      //
      // 它本身就是「拿设备令牌换新会话」的端点 —— 手机冷启动时
      // 没有有效会话，只能凭 deviceToken 调它。这个接口自带鉴权
      // （校验 deviceToken 摘要），不需要回环限制。
      //
      // 其余路径继续 404：`/pairing`（签新令牌）、`/devices/revoke`
      // （踢设备）这类电脑本机专属操作绝不能发给手机。
      if (pathname === `${AUTH_PREFIX}/renew`) {
        await this.#handleRenew(request, response)
        return
      }
      if (pathname.startsWith(`${AUTH_PREFIX}/`)) {
        sendJson(response, 404, { error: 'not_found' })
        return
      }

      // ② 静态资源：放行（否则登录/首屏都加载不了）
      if (isPublicAsset(pathname)) {
        await this.#proxy(request, response, url)
        return
      }

      // ③ 其余：要求会话
      const session = readSessionCookie(request.headers.cookie)
      try {
        this.options.access.authorize(session)
      } catch {
        sendText(
          response,
          401,
          'dsh-mobile-next: authentication required.\n'
            + '请在电脑的「移动访问」面板生成配对链接，用手机打开一次完成配对。',
        )
        return
      }

      await this.#proxy(request, response, url)
    } catch (error) {
      if (response.headersSent) {
        response.destroy()
        return
      }
      if (error instanceof AccessError) {
        sendText(response, error.status, error.code)
        return
      }
      sendText(response, 502, 'gateway error')
    }
  }

  /**
   * 配对页（GET）。
   *
   * 二维码扫出来是 GET 请求，直接打开这个页面；页面自动提交 POST
   * 完成配对，然后把用户带到 DSH。
   *
   * 为什么需要它：二维码内容只能是一个 URL，扫码必然是 GET。
   * 若二维码指向 POST 端点，扫码会得到 405 —— 实测踩过。
   */
  async #handlePairPage(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    const url = new URL(request.url ?? '/', 'https://placeholder')
    const token = url.searchParams.get('token') ?? ''
    if (token === '') {
      sendText(response, 400, 'missing token')
      return
    }
    const html = `<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>正在配对…</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font: 16px/1.6 -apple-system, system-ui, sans-serif;
    margin: 0; min-height: 100vh;
    display: flex; align-items: center; justify-content: center;
    background: #F7F8FA; color: #111827;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #0F172A; color: #F8FAFC; }
    .card { background: #1E293B !important; border-color: #334155 !important; }
  }
  .card {
    background: #fff; border: 1px solid #E4E7EC; border-radius: 16px;
    padding: 24px; max-width: 320px; text-align: center;
  }
  .ok { color: #166534; font-weight: 600; }
  .err { color: #B91C1C; font-weight: 600; }
  button {
    margin-top: 16px; min-height: 48px; width: 100%;
    border: 0; border-radius: 12px; background: #2563EB; color: #fff;
    font-size: 16px; font-weight: 600;
  }
</style>
</head><body>
<div class="card">
  <div id="status">正在配对…</div>
  <div id="detail" style="font-size:14px;opacity:.7;margin-top:8px"></div>
  <button id="go" hidden onclick="location.href='/'">进入 DSH</button>
</div>
<script>
(async function () {
  var status = document.getElementById('status');
  var detail = document.getElementById('detail');
  var go = document.getElementById('go');
  try {
    var res = await fetch('${AUTH_PREFIX}/pair', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: ${JSON.stringify(token).replace(/</g, '\\u003c')}, label: 'Mobile' }),
    });
    var body = await res.json().catch(function () { return {}; });
    if (res.ok) {
      status.className = 'ok';
      status.textContent = '配对成功';
      detail.textContent = '这台手机已获得访问权限。';
      go.hidden = false;
    } else {
      status.className = 'err';
      status.textContent = '配对失败';
      detail.textContent = body.error === 'authentication_failed'
        ? '配对码无效或已过期，请在电脑上重新生成。'
        : (body.error || ('HTTP ' + res.status));
    }
  } catch (e) {
    status.className = 'err';
    status.textContent = '配对失败';
    detail.textContent = String(e);
  }
})();
</script>
</body></html>`
    response.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'referrer-policy': 'no-referrer',
    })
    response.end(html)
  }

  /** 处理配对请求。 */
  async #handlePair(request: IncomingMessage, response: ServerResponse): Promise<void> {
    if (request.method !== 'POST') {
      sendText(response, 405, 'method_not_allowed')
      return
    }
    const sourceKey = request.socket.remoteAddress ?? 'unknown'
    try {
      const body = await readJsonBody(request)
      const token = body.token
      if (typeof token !== 'string') {
        throw new AccessError(400, 'bad_request')
      }
      const label = typeof body.label === 'string' ? body.label : undefined
      const result = await this.options.access.pair(sourceKey, token, label)

      // 会话写 HttpOnly Cookie；Secure 因为本网关只跑 HTTPS
      const cookie = [
        `${SESSION_COOKIE}=${encodeURIComponent(result.sessionToken)}`,
        'Path=/',
        'HttpOnly',
        'Secure',
        'SameSite=Strict',
        `Max-Age=${String(Math.max(0, Math.floor((result.sessionExpiresAt - Date.now()) / 1000)))}`,
      ].join('; ')
      response.setHeader('set-cookie', cookie)
      // 同时提供两种形态：
      // - `Set-Cookie`（浏览器路径，上面已设）
      // - 响应体里的 `sessionToken`（原生客户端路径，存 Keystore）
      //
      // 参考实现 `dsh-mobile` 就是两者都给：浏览器靠 Cookie，
      // App 靠 body 里的 token。只给 Cookie 会让原生客户端拿不到凭据。
      sendJson(response, 201, {
        deviceId: result.deviceId,
        deviceToken: result.deviceToken,
        deviceExpiresAt: result.deviceExpiresAt,
        sessionToken: result.sessionToken,
        csrfToken: result.csrfToken,
        sessionExpiresAt: result.sessionExpiresAt,
        instanceId: result.instanceId,
      })
    } catch (error) {
      if (error instanceof AccessError) {
        sendJson(response, error.status, { error: error.code })
        return
      }
      sendJson(response, 500, { error: 'internal' })
    }
  }

  /**
   * `/renew`：把手机的设备令牌转发给回环管理端点，换一个新会话。
   *
   * 为什么由网关自己转而不是直接透传：
   * 透传会把「已配对手机能访问所有管理路径」这个洞重新打开。
   * 这里只放行这一条，并且**不让手机指定任意路径**。
   */
  async #handleRenew(
    request: IncomingMessage,
    response: ServerResponse,
  ): Promise<void> {
    if (request.method !== 'POST') {
      sendText(response, 405, 'method_not_allowed')
      return
    }
    const upstreamPort = this.options.upstreamPort()
    if (upstreamPort === undefined) {
      sendText(response, 503, 'upstream not ready')
      return
    }
    try {
      const body = await readJsonBody(request)
      const deviceToken = body.deviceToken
      if (typeof deviceToken !== 'string' || deviceToken === '') {
        sendJson(response, 400, { error: 'bad_request' })
        return
      }
      const result = await this.options.access.renew(deviceToken)
      // 同时下发 Cookie：浏览器路径靠它，原生客户端读 body
      const cookie = [
        `${SESSION_COOKIE}=${encodeURIComponent(result.sessionToken)}`,
        'Path=/',
        'HttpOnly',
        'Secure',
        'SameSite=Strict',
        `Max-Age=${String(Math.max(0, Math.floor((result.sessionExpiresAt - Date.now()) / 1000)))}`,
      ].join('; ')
      response.setHeader('set-cookie', cookie)
      sendJson(response, 200, result)
    } catch (error) {
      if (error instanceof AccessError) {
        sendJson(response, error.status, { error: error.code })
        return
      }
      sendJson(response, 500, { error: 'internal' })
    }
  }

  /** 反代到 DSH 回环端口。 */
  async #proxy(
    request: IncomingMessage,
    response: ServerResponse,
    url: string,
  ): Promise<void> {
    const upstreamPort = this.options.upstreamPort()
    if (upstreamPort === undefined) {
      sendText(response, 503, 'upstream not ready')
      return
    }

    // ⚠ 关键：Host 必须改写成回环，否则 DSH 的 Host 信任校验会 403
    const headers = { ...request.headers }
    headers.host = `127.0.0.1:${String(upstreamPort)}`

    // ⚠ 更关键：注入 DSH 自己的认证 Cookie。
    //
    // 只带我们的设备 Cookie 是不够的 —— DSH 会用自己的 `dsh-auth-*`
    // 校验，缺失时直接 401（"dsh web authentication required"）。
    // 实测踩过：一度以为是自己的会话校验失败。
    let upstreamCookie: string | undefined
    try {
      upstreamCookie = await this.options.upstreamAuth.cookie()
    } catch (error) {
      // 交换失败：把原因写进响应，便于真机排查
      sendText(
        response,
        502,
        `upstream auth exchange failed: ${error instanceof Error ? error.message : String(error)}\n`,
      )
      return
    }
    // undefined 表示上游不需要浏览器认证（例如某些配置下 authenticatedUrl
    // 不带 query）。这是合法状态，不注入 cookie 即可，不能当成错误。
    delete headers.cookie
    delete headers.authorization
    delete headers.forwarded
    for (const key of Object.keys(headers)) if (key.startsWith('x-forwarded-')) delete headers[key]
    if (upstreamCookie !== undefined) {
      headers.cookie = upstreamCookie
    }
    // Origin 也要改，否则 WS/写请求会被 Origin 校验拒绝
    if (headers.origin !== undefined) {
      headers.origin = `http://127.0.0.1:${String(upstreamPort)}`
    }
    if (headers.referer !== undefined) {
      headers.referer = `http://127.0.0.1:${String(upstreamPort)}/`
    }

    await new Promise<void>((resolve, reject) => {
      const proxied = httpRequest(
        {
          host: '127.0.0.1',
          port: upstreamPort,
          method: request.method,
          path: url,
          headers,
        },
        (upstream) => {
          response.writeHead(upstream.statusCode ?? 502, upstream.headers)
          upstream.pipe(response)
          upstream.once('end', () => resolve())
          upstream.once('error', reject)
        },
      )
      proxied.once('error', reject)
      request.pipe(proxied)
    })
  }

  /** 处理 WebSocket 升级。 */
  #handleUpgrade(
    request: IncomingMessage,
    socket: import('node:stream').Duplex,
    head: Buffer,
  ): void {
    const upstreamPort = this.options.upstreamPort()
    if (upstreamPort === undefined) {
      socket.destroy()
      return
    }
    if (!this.#trustedOrigin(request) || new URL(request.url ?? '/', 'https://placeholder').pathname.startsWith(`${AUTH_PREFIX}/`)) {
      socket.destroy()
      return
    }
    // 升级同样需要认证：手机上的 DSH 页面用同一 Cookie
    const session = readSessionCookie(request.headers.cookie)
    try {
      this.options.access.authorize(session)
    } catch {
      socket.destroy()
      return
    }

    // ⚠ WS 升级也必须注入 DSH 自己的 `dsh-auth-*` Cookie。
    //
    // HTTP 代理路径（#proxy）做了这件事，WS 升级路径最初漏了。
    // 后果：手机端配对成功后连 `/api/remote.mux` 必然 401 ——
    // 上游 DSH 认不出请求，握手被拒（`not upgraded to websocket,
    // HTTP status code: 401`）。而 unary 请求却正常，所以症状是
    // 「配对成功但连不上」，极难定位。
    //
    // 这里改为异步：先换 Cookie，再建隧道。失败就按 503 断开，
    // 不把半成品连接交给上游。
    void this.#pipeUpgrade(request, socket, head, upstreamPort).catch(() => {
      socket.destroy()
    })
  }

  /** 换好上游凭据后，把 WS 升级请求透传给 DSH。 */
  async #pipeUpgrade(
    request: IncomingMessage,
    socket: import('node:stream').Duplex,
    head: Buffer,
    upstreamPort: number,
  ): Promise<void> {
    let upstreamCookie: string | undefined
    try {
      upstreamCookie = await this.options.upstreamAuth.cookie()
    } catch (error) {
      this.options.log?.('upgrade-auth-failed', {
        error: error instanceof Error ? error.message : String(error),
      })
      socket.destroy()
      return
    }

    const headers = { ...request.headers }
    headers.host = `127.0.0.1:${String(upstreamPort)}`
    // 设备会话 Cookie 对上游没有意义，替换成 DSH 自己的凭据
    delete headers.cookie
    delete headers.authorization
    delete headers.forwarded
    for (const key of Object.keys(headers)) if (key.startsWith('x-forwarded-')) delete headers[key]
    if (upstreamCookie !== undefined) headers.cookie = upstreamCookie
    if (headers.origin !== undefined) {
      headers.origin = `http://127.0.0.1:${String(upstreamPort)}`
    }
    if (headers.referer !== undefined) {
      headers.referer = `http://127.0.0.1:${String(upstreamPort)}/`
    }

    if (socket.destroyed || this.#state !== 'running') return
    const target = import('node:net').then(({ connect }) => {
      const upstream = connect(upstreamPort, '127.0.0.1', () => {
        const lines = [
          `${request.method ?? 'GET'} ${request.url ?? '/'} HTTP/1.1`,
        ]
        for (const [key, value] of Object.entries(headers)) {
          if (Array.isArray(value)) {
            for (const item of value) lines.push(`${key}: ${item}`)
          } else if (value !== undefined) {
            lines.push(`${key}: ${String(value)}`)
          }
        }
        upstream.write(`${lines.join('\r\n')}\r\n\r\n`)
        if (head.length > 0) upstream.write(head)
        upstream.pipe(socket)
        socket.pipe(upstream)
      })
      this.#connections.add(upstream)
      upstream.once('close', () => { this.#connections.delete(upstream); socket.destroy() })
      socket.once('close', () => upstream.destroy())
      upstream.on('error', () => socket.destroy())
      socket.on('error', () => upstream.destroy())
    })
    void target
  }
}
