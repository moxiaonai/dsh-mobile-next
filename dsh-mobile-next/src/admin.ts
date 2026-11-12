/**
 * 回环管理路由。
 *
 * ## 安全边界
 *
 * 这些路由**只在 DSH 自己的回环 Web 端口**上注册（`ctx.webServer.register`），
 * 不经过局域网网关。因此：
 * - 只有电脑本机浏览器能访问
 * - 手机看不到、也调不到
 *
 * 这是刻意的：配对令牌必须由**电脑本机**生成，否则任何人都能给自己发配对码。
 *
 * ## 端点
 *
 * | 方法 | 路径 | 作用 |
 * | --- | --- | --- |
 * | GET  | `/mobile-access-next/status`  | 网关状态 + 候选网卡 |
 * | GET  | `/mobile-access-next/diagnostics` | 逐项自检（面板「诊断」抽屉） |
 * | POST | `/mobile-access-next/network` | 选定网卡（需重启生效） |
 * | POST | `/mobile-access-next/enable`  | 启停网关 |
 * | POST | `/mobile-access-next/pairing` | 生成一次性配对令牌 |
 * | POST | `/mobile-access-next/renew` | 用设备令牌换新会话（冷启动重连，不用扫码） |
 * | GET  | `/mobile-access-next/devices` | 已配对设备列表 |
 * | POST | `/mobile-access-next/devices/revoke` | 撤销设备 |
 * | POST | `/mobile-access-next/devices/revoke-all` | 一次撤销全部设备 |
 */

import type { IncomingMessage, ServerResponse } from 'node:http'

import { loadQRCode } from './deps.js'

import { AccessError } from './access.js'
import type { AccessController } from './access.js'
import type { RemoteController } from './remote.js'
import { isIP } from 'node:net'
import type { NetworkCandidate } from './network.js'

/**
 * 管理路由前缀。
 *
 * ⚠ **不要放在 `/api/` 下**。
 *
 * DSH 对 `/api/*` 有自己的认证层（浏览器会话 Cookie），未认证会返回
 * `401 unauthorized`，**在到达我们的 handler 之前就被拦掉**。
 *
 * 实测踩过：路由注册"成功"，`status`/`devices` 能用（因为它们碰巧
 * 走了不同分支），但新加的 `probe-upstream` 一直 401 ——
 * 排查很久才发现是前缀撞了 DSH 的认证区。
 *
 * 改用 `/mobile-access-next/` 前缀，与参考实现的 `/mobile-access/` 一致。
 */
export const ADMIN_PREFIX = '/mobile-access-next'

/** 一条自检结果。 */
export interface DiagnosticCheck {
  readonly id: string
  /**
   * `ok` 通过 / `warn` 注意 / `error` 失败 / `unknown` 本端拿不到。
   *
   * `unknown` 是诚实原则：电脑端拿不到的信息（例如手机侧的 TLS 信任状态）
   * 显示「未检查」，**不**显示 ✓。
   */
  readonly level: 'ok' | 'warn' | 'error' | 'unknown'
  readonly title: string
  readonly detail: string
  readonly hint?: string
}

/** 管理面依赖。 */
export interface AdminDeps {
  readonly remote?: RemoteController
  readonly remoteAccess?: AccessController
  /** 当前网关状态。 */
  readonly status: () => {
    readonly state: string
    readonly origin?: string
    readonly caFingerprint?: string
    readonly listenPort?: number
    readonly error?: string
  }
  /** 候选网卡。 */
  readonly candidates: () => readonly NetworkCandidate[]
  /** 当前选定的地址。 */
  readonly selectedAddress: () => string | undefined
  /** 启停。 */
  readonly setEnabled: (enabled: boolean) => Promise<void>
  /** 选定网卡（保存到 setup.json，重启后生效）。 */
  readonly selectNetwork: (interfaceName: string) => Promise<void>
  /** 生成配对令牌。 */
  readonly openPairing: () => Promise<{ token: string; expiresAt: number }>
  /** 设备操作。 */
  readonly access: AccessController
  /** 生成配对链接（供二维码编码）。 */
  readonly pairingUrl: (token: string) => string | undefined
  /** 额外自检项（由插件按运行时信息补充；缺省时只跑内建检查）。 */
  readonly diagnostics?: () => readonly DiagnosticCheck[]
  /** 当前监听地址（用于自检报告）。 */
  readonly listenAddress?: () => string | undefined
}

/**
 * 已注册路由的形态。
 *
 * ⚠ 必须与 `@deepseek-ai/dsh-host-webserver` 的 `WebRoute` 对齐：
 * 是 `{ kind: 'exact' | 'prefix', path, handler }`，**不是** `{ method, path }`。
 * 实测踩过：写成 method 形式会导致 register 落进 prefixes 表且匹配不到。
 */
export interface AdminRoute {
  readonly kind: 'exact' | 'prefix'
  readonly path: string
  handler(request: IncomingMessage, response: ServerResponse): Promise<void>
}

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body)
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
  })
  response.end(text)
}

async function readBody(
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
  const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'))
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new AccessError(400, 'bad_request')
  }
  return parsed as Record<string, unknown>
}

/** 读配对窗口状态；旧版 / 测试替身没有该方法时按「未开启」处理。 */
function readPairingStatus(
  access: AccessController,
): { readonly open: boolean; readonly expiresAt?: number } {
  const candidate = access as unknown as { pairingStatus?: unknown }
  if (typeof candidate.pairingStatus !== 'function') return { open: false }
  try {
    return (candidate.pairingStatus as () => {
      readonly open: boolean
      readonly expiresAt?: number
    })()
  } catch {
    return { open: false }
  }
}

/**
 * 构造内建自检项。
 *
 * 口径：**只报能验证的**。电脑端看不到手机侧的 TLS 信任、手机网络可达性，
 * 这些返回 `unknown` 并说明原因，而不是假装通过。
 */
function builtinDiagnostics(deps: AdminDeps): DiagnosticCheck[] {
  const status = deps.status()
  const candidates = deps.candidates()
  const selected = deps.selectedAddress()
  const checks: DiagnosticCheck[] = []

  // ① 网关
  if (status.state === 'running') {
    checks.push({
      id: 'gateway',
      level: 'ok',
      title: '局域网网关',
      detail: `正在监听 ${status.origin ?? '—'}`,
    })
  } else if (status.state === 'error') {
    checks.push({
      id: 'gateway',
      level: 'error',
      title: '局域网网关',
      detail: status.error ?? '启动失败',
      hint: '常见原因：端口被占用、证书目录不可写、选定网卡已断开',
    })
  } else {
    checks.push({
      id: 'gateway',
      level: 'warn',
      title: '局域网网关',
      detail: '未开启，手机无法访问',
      hint: '在面板主操作里点「开启局域网访问」',
    })
  }

  // ② 网卡
  if (candidates.length === 0) {
    checks.push({
      id: 'network',
      level: 'error',
      title: '局域网地址',
      detail: '没有找到可用的局域网 IPv4',
      hint: '确认电脑已连接 Wi-Fi 或有线网络',
    })
  } else {
    checks.push({
      id: 'network',
      level: 'ok',
      title: '局域网地址',
      detail:
        selected === undefined
          ? `候选 ${String(candidates.length)} 个，尚未选定`
          : `${selected}（候选 ${String(candidates.length)} 个）`,
    })
  }

  // ③ TLS 证书
  if (status.caFingerprint === undefined) {
    checks.push({
      id: 'tls',
      level: 'unknown',
      title: 'TLS 证书',
      detail: '网关未启动，证书尚未加载',
    })
  } else {
    checks.push({
      id: 'tls',
      level: 'ok',
      title: 'TLS 证书',
      detail: `CA 指纹 ${status.caFingerprint.slice(0, 23)}…`,
      hint: '手机首次连接需信任这张自签 CA；更换网卡后指纹会变',
    })
  }

  // ④ 手机侧（拿不到 → unknown）
  checks.push({
    id: 'device-trust',
    level: 'unknown',
    title: '手机侧 TLS 信任',
    detail: '电脑端无法检查手机是否已信任 CA',
    hint: '手机端表现为「证书不受信任」时，重新扫码配对即可',
  })

  // ⑤ 已配对设备
  const devices = deps.access.listDevices()
  checks.push({
    id: 'devices',
    level: devices.length === 0 ? 'warn' : 'ok',
    title: '已配对设备',
    detail:
      devices.length === 0
        ? '还没有设备配对'
        : `${String(devices.length)} 台（最近 ${devices
            .map((d) => d.label)
            .slice(0, 3)
            .join('、')}）`,
  })

  // ⑥ 插件补充项
  if (deps.diagnostics !== undefined) {
    try {
      checks.push(...deps.diagnostics())
    } catch (error) {
      checks.push({
        id: 'plugin',
        level: 'warn',
        title: '插件自检',
        detail: error instanceof Error ? error.message : String(error),
      })
    }
  }

  return checks
}

/**
 * 构造管理路由列表。
 *
 * 调用方负责把返回的数组注册到 `ctx.webServer`。
 */
export function createAdminRoutes(deps: AdminDeps): AdminRoute[] {
  const routes: AdminRoute[] = [
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/status`,
      async handler(_request, response) {
        const status = deps.status()
        sendJson(response, 200, {
          ...status,
          remote: deps.remote?.status(),
          selectedAddress: deps.selectedAddress() ?? null,
          candidates: deps.candidates(),
          // 配对窗口只给倒计时用；拿不到就报未开启（旧版 access 实现没有这个方法）
          pairing: readPairingStatus(deps.access),
        })
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/diagnostics`,
      async handler(_request, response) {
        sendJson(response, 200, { checks: builtinDiagnostics(deps) })
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/network`,
      async handler(request, response) {
        try {
          const body = await readBody(request)
          const name = body.interfaceName
          if (typeof name !== 'string' || name === '') {
            throw new AccessError(400, 'bad_request')
          }
          await deps.selectNetwork(name)
          sendJson(response, 200, { ok: true, restartRequired: true })
        } catch (error) {
          if (error instanceof AccessError) {
            sendJson(response, error.status, { error: error.code })
            return
          }
          sendJson(response, 500, { error: 'internal' })
        }
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/enable`,
      async handler(request, response) {
        try {
          const body = await readBody(request)
          if (typeof body.enabled !== 'boolean') {
            throw new AccessError(400, 'bad_request')
          }
          await deps.setEnabled(body.enabled)
          sendJson(response, 200, { ok: true, state: deps.status().state })
        } catch (error) {
          if (error instanceof AccessError) {
            sendJson(response, error.status, { error: error.code })
            return
          }
          sendJson(response, 500, { error: 'internal' })
        }
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/pairing`,
      async handler(_request, response) {
        try {
          const result = await deps.openPairing()
          const url = deps.pairingUrl(result.token)
          // 同时生成 SVG 二维码：面板可以直接内联展示，不必再拉图片
          let qrSvg: string | null = null
          const pairingTarget = url ?? undefined
          if (pairingTarget !== undefined) {
            try {
              // @types/qrcode 的 Promise 重载与 callback 重载签名冲突，
              // 显式包一层 Promise 最稳（实测 tsc 直接调会报 overload 不匹配）
              const QRCode = await loadQRCode()
              qrSvg = await new Promise<string>((resolve, reject) => {
                QRCode.toString(
                  pairingTarget,
                  { type: 'svg', margin: 1, errorCorrectionLevel: 'M' },
                  (error: Error | null | undefined, svg: string) => {
                    if (error !== null && error !== undefined) reject(error)
                    else resolve(svg)
                  },
                )
              })
            } catch {
              // 生成失败不影响返回 URL：调用方可以自己渲染
              qrSvg = null
            }
          }
          sendJson(response, 201, {
            token: result.token,
            expiresAt: result.expiresAt,
            // 手机用这个 URL 配对；二维码内容也是它
            url: url ?? null,
            qrSvg,
          })
        } catch (error) {
          if (error instanceof AccessError) {
            sendJson(response, error.status, { error: error.code })
            return
          }
          sendJson(response, 500, { error: 'internal' })
        }
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/renew`,
      async handler(request, response) {
        try {
          const body = await readBody(request)
          const deviceToken = body.deviceToken
          if (typeof deviceToken !== 'string' || deviceToken === '') {
            throw new AccessError(400, 'bad_request')
          }
          const result = await deps.access.renew(deviceToken)
          sendJson(response, 200, result)
        } catch (error) {
          if (error instanceof AccessError) {
            sendJson(response, error.status, { error: error.code })
            return
          }
          sendJson(response, 500, { error: 'internal' })
        }
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/devices`,
      async handler(_request, response) {
        sendJson(response, 200, { devices: [
          ...deps.access.listDevices().map(device => ({ ...device, channel: 'lan' })),
          ...(deps.remoteAccess?.listDevices() ?? []).map(device => ({ ...device, channel: 'remote' })),
        ] })
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/devices/revoke`,
      async handler(request, response) {
        try {
          const body = await readBody(request)
          const deviceId = body.deviceId
          if (typeof deviceId !== 'string' || deviceId === '') {
            throw new AccessError(400, 'bad_request')
          }
          if (body.channel !== undefined && body.channel !== 'lan' && body.channel !== 'remote') throw new AccessError(400, 'bad_channel')
          const access = body.channel === 'remote' ? deps.remoteAccess : deps.access
          if (access === undefined) throw new AccessError(404, 'channel_not_found')
          await access.revoke(deviceId)
          sendJson(response, 200, { ok: true })
        } catch (error) {
          if (error instanceof AccessError) {
            sendJson(response, error.status, { error: error.code })
            return
          }
          sendJson(response, 500, { error: 'internal' })
        }
      },
    },
    {
      kind: 'exact',
      path: `${ADMIN_PREFIX}/devices/revoke-all`,
      async handler(_request, response) {
        try {
          const removed = await deps.access.revokeAll() + (await deps.remoteAccess?.revokeAll() ?? 0)
          sendJson(response, 200, { ok: true, removed })
        } catch (error) {
          if (error instanceof AccessError) {
            sendJson(response, error.status, { error: error.code })
            return
          }
          sendJson(response, 500, { error: 'internal' })
        }
      },
    },
  ]
  if (deps.remote !== undefined && deps.remoteAccess !== undefined) {
    const remote = deps.remote
    const access = deps.remoteAccess
    for (const operation of ['config', 'enable', 'pairing'] as const) {
      routes.push({
        kind: 'exact', path: `${ADMIN_PREFIX}/remote/${operation}`,
        async handler(request, response) {
          try {
            if (request.method !== 'POST') throw new AccessError(405, 'method_not_allowed')
            const body = await readBody(request)
            if (operation === 'config') {
              await remote.configure(body as never)
              sendJson(response, 200, remote.status())
            } else if (operation === 'enable') {
              if (typeof body.enabled !== 'boolean') throw new AccessError(400, 'bad_request')
              if (body.enabled) await remote.start()
              else await remote.stop()
              sendJson(response, 200, remote.status())
            } else {
              const result = await remote.openPairing()
              const QRCode = await loadQRCode()
              const qrSvg = await QRCode.toString(result.qrPayload, { type: 'svg', margin: 2, errorCorrectionLevel: 'M' }).catch(() => null)
              sendJson(response, 201, { ...result, url: result.qrPayload,
                token: result.descriptor.gatewayToken, expiresAt: result.descriptor.expiresAt, qrSvg })
            }
          } catch (error) {
            sendJson(response, error instanceof AccessError ? error.status : 500, { error: error instanceof AccessError ? error.code : 'internal' })
          }
        },
      })
    }
  }
  // 管理口防跨站请求与非回环调用；网关侧还会阻断整个管理前缀。
  return routes.map(route => ({ ...route, async handler(request, response) {
    const address = request.socket?.remoteAddress
    const local = address === undefined || address === '::1' || address === '127.0.0.1' || address === '::ffff:127.0.0.1'
    let trusted = local && request.headers['sec-fetch-site'] !== 'cross-site'
    const host = request.headers.host
    if (host !== undefined) {
      try {
        const hostname = new URL(`http://${host}`).hostname
        trusted &&= hostname === 'localhost' || hostname === '[::1]' || (isIP(hostname) === 4 && hostname.startsWith('127.'))
      } catch { trusted = false }
    }
    if (request.headers.origin !== undefined) {
      try {
        const origin = new URL(request.headers.origin)
        trusted &&= origin.host === host && (origin.protocol === 'http:' || origin.protocol === 'https:')
      } catch { trusted = false }
    }
    if (!trusted) { sendJson(response, 403, { error: 'untrusted_origin' }); return }
    const readonly = ['/status', '/diagnostics', '/devices'].some(path => route.path === `${ADMIN_PREFIX}${path}`)
    if (request.method !== (readonly ? 'GET' : 'POST')) {
      sendJson(response, 405, { error: 'method_not_allowed' }); return
    }
    await route.handler(request, response)
  } }))
}
