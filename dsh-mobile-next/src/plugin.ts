/**
 * 插件主入口。
 *
 * ## 生命周期
 *
 * ```
 * DSH 启动
 *   → plugin(ctx, config)         ← 本文件
 *       → 读 setup.json / control.json
 *       → 初始化 AccessController（加载 devices.json）
 *       → 注册回环管理路由（始终注册，即使网关关闭）
 *       → 若 control.enabled：生成证书 → 起网关
 *   → ctx 销毁
 *       → 停网关、关 access
 * ```
 *
 * ## 为什么管理路由始终注册
 *
 * 网关关闭时用户仍需要能打开面板、选网卡、开启访问。
 * 如果路由随网关一起起停，关闭后就再也开不起来了。
 *
 * ## 安全默认
 *
 * - `initiallyEnabled: false` —— 装完不自动对外监听
 * - `allowedCidrs: [127.0.0.0/8]` —— 只允许回环，直到用户选定网卡
 * - 配对令牌只从回环管理路由签发
 */

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { fingerprintOf } from './tls.js'
import { dirname, join } from 'node:path'

import { AccessController } from './access.js'
import { createAdminRoutes, type AdminRoute, type DiagnosticCheck } from './admin.js'
import {
  loadPersistedState,
  resolveConfig,
  stateDirectoryOf,
  type ControlFile,
  type PluginConfig,
  type SetupFile,
} from './config.js'
import { LanGateway } from './gateway.js'
import { UpstreamAuth } from './upstream-auth.js'
import { RemoteController } from './remote.js'
import { AccessError } from './access.js'
import {
  addressStillPresent,
  isAllowedSource,
  listCandidates,
  pickDefaultCandidate,
} from './network.js'
import { ensureTlsMaterial, readTlsMaterial, shortFingerprint } from './tls.js'

/** DSH 上下文的最小结构（只声明用到的部分，便于测试）。 */
export interface PluginContext {
  readonly webServer: {
    readonly port?: number
    /** 读监听地址（DSH 提供）。可能不存在于旧版本。 */
    readonly getOrigin?: () => string
    /**
     * 注册一条 HTTP 路由。
     *
     * 形态来自 `@deepseek-ai/dsh-host-webserver` 的 `WebRoute`：
     * `{ kind: 'exact' | 'prefix', path, handler }`。
     * 返回 disposer。
     */
    register(route: {
      kind: 'exact' | 'prefix'
      path: string
      handler(
        request: import('node:http').IncomingMessage,
        response: import('node:http').ServerResponse,
      ): Promise<void>
    }): () => void
  }
  /**
   * DSH 的浏览器会话服务。
   *
   * 用它拿「带 launch token 的 URL」，再交换出 DSH 自己的 `dsh-auth-*` Cookie。
   * 没有它，代理出去的请求会被 DSH 拒绝。
   */
  readonly connection?: {
    /**
     * 返回带 launch token 的 URL。
     *
     * 不带 query 的返回值表示「上游不需要浏览器认证」。
     */
    authenticatedUrl?: (baseUrl: string) => string
  }
  readonly effect?: (callback: () => void | (() => Promise<void> | void)) => void
  readonly logger?: (message: string) => void
  readonly on?: (event: string, handler: () => void) => () => void
}

/** 插件元信息。 */
export const name = 'dsh-mobile-next'

/** 注入的服务。 */
export const inject = ['webServer', 'connection'] as const

/** 运行时状态。 */
interface Runtime {
  readonly config: ReturnType<typeof resolveConfig>
  readonly access: AccessController
  gateway: LanGateway | undefined
  setup: SetupFile
  control: ControlFile
  selectedAddress: string | undefined
  upstreamAuth: UpstreamAuth | undefined
  disposers: Array<() => void>
}

/** 写入 setup.json。 */
async function persistSetup(
  path: string | undefined,
  setup: SetupFile,
): Promise<void> {
  if (path === undefined) return
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, JSON.stringify(setup, null, 2), {
    encoding: 'utf8',
    mode: 0o600,
  })
}

/** 写入 control.json。 */
async function persistControl(
  path: string | undefined,
  control: ControlFile,
): Promise<void> {
  if (path === undefined) return
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, JSON.stringify(control, null, 2), {
    encoding: 'utf8',
    mode: 0o600,
  })
}

/** 读出实例标识（首次生成后固定，用于区分不同电脑）。 */
async function ensureInstanceId(directory: string | undefined): Promise<string | undefined> {
  if (directory === undefined) return undefined
  const path = join(directory, 'installation-id')
  try {
    const existing = (await readFile(path, 'utf8')).trim()
    if (existing !== '') return existing
  } catch {
    // 不存在：生成
  }
  const { randomBytes } = await import('node:crypto')
  const id = randomBytes(16).toString('hex')
  await mkdir(directory, { recursive: true })
  await writeFile(path, `${id}\n`, { encoding: 'utf8', mode: 0o600 })
  return id
}

/**
 * 插件入口。
 */
export default async function plugin(
  ctx: PluginContext,
  rawConfig: PluginConfig = {},
): Promise<void> {
  const config = resolveConfig(rawConfig)
  const directory = stateDirectoryOf(config)
  const { setup, control } = await loadPersistedState(config)

  await ensureInstanceId(directory)

  const access = new AccessController(config.stateFile)
  await access.initialize()

  // 注入安装标识：客户端用它区分不同电脑
  const instanceId = await ensureInstanceId(directory)
  access.setInstanceId(instanceId)

  const runtime: Runtime = {
    config,
    access,
    gateway: undefined,
    setup,
    control,
    selectedAddress: undefined,
    upstreamAuth: undefined,
    disposers: [],
  }

  const log = (event: string, fields: Record<string, unknown> = {}): void => {
    const line = JSON.stringify({
      timestamp: new Date().toISOString(),
      plugin: name,
      event,
      ...fields,
    })
    ctx.logger?.(line)
  }

  /**
   * 解析当前应使用的监听地址。
   *
   * 优先用 setup.json 里保存的网卡；若该网卡已不存在（换 Wi-Fi），
   * 退回自动挑选。
   */
  const resolveListenAddress = (): string | undefined => {
    const saved = setup.networkInterface
    if (saved !== undefined) {
      const candidates = listCandidates()
      const hit = candidates.find((c) => c.interfaceName === saved)
      if (hit !== undefined) return hit.address
      log('saved-interface-missing', { interfaceName: saved })
    }
    const fallback = pickDefaultCandidate()
    return fallback?.address
  }

  /** 启动网关。 */
  const startGateway = async (): Promise<void> => {
    if (runtime.gateway?.state === 'running') return

    const address = resolveListenAddress()
    if (address === undefined) {
      log('gateway-skipped', { reason: 'no-candidate-address' })
      return
    }
    runtime.selectedAddress = address

    if (config.tlsMode === 'disabled') {
      log('gateway-skipped', { reason: 'tls-disabled' })
      return
    }

    // 证书目录：默认放在 setup.json 同级
    const tlsDirectory =
      setup.tlsDirectory ??
      (directory === undefined ? undefined : join(directory, 'tls'))
    if (tlsDirectory === undefined) {
      log('gateway-skipped', { reason: 'no-tls-directory' })
      return
    }

    const material = await ensureTlsMaterial(tlsDirectory, [address])
    log('tls-ready', {
      fingerprint: shortFingerprint(material.caFingerprint),
      sans: material.sans,
    })

    const tls = await readTlsMaterial(tlsDirectory)
    if (tls === undefined) {
      log('gateway-skipped', { reason: 'tls-read-failed' })
      return
    }

    // 上游凭据：用 DSH 的 authenticatedUrl 换它自己的 Cookie。
    //
    // 注意这里**每次启动都重建** —— Host 重启后 launch token 变了，
    // 旧的交换结果无效。
    const upstreamOrigin = ctx.webServer.port === undefined
      ? undefined
      : `http://127.0.0.1:${String(ctx.webServer.port)}`
    const upstreamAuth = new UpstreamAuth(
      () => {
        const connection = ctx.connection
        if (typeof connection?.authenticatedUrl !== 'function') return undefined
        if (upstreamOrigin === undefined) return undefined
        try {
          return connection.authenticatedUrl(upstreamOrigin)
        } catch {
          return undefined
        }
      },
      () => upstreamOrigin,
    )
    runtime.upstreamAuth = upstreamAuth

    const gateway = new LanGateway({
      config,
      access,
      upstreamPort: () => ctx.webServer.port,
      upstreamAuth,
      tls,
      listenAddress: address,
      log,
    })

    try {
      await gateway.start()
      runtime.gateway = gateway
      log('gateway-ready', { origin: gateway.origin })
    } catch (error) {
      log('gateway-start-error', {
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  /** 停止网关。 */
  const stopGateway = async (): Promise<void> => {
    const gateway = runtime.gateway
    runtime.gateway = undefined
    if (gateway !== undefined) await gateway.stop()
  }

  // 远程网关只绑定回环，绝不能把 DSH 管理端口直接送进隧道。
  const remoteAccess = new AccessController(directory === undefined ? undefined : join(directory, 'remote-devices.json'))
  await remoteAccess.initialize()
  remoteAccess.setInstanceId(instanceId)
  let remoteGateway: LanGateway | undefined
  const remote: RemoteController = new RemoteController({
    stateDirectory: directory,
    access: remoteAccess,
    startBackend: async (context) => {
      if (directory === undefined) throw new AccessError(409, 'remote_state_directory_required')
      if (ctx.webServer.port === undefined) throw new AccessError(503, 'upstream_not_ready')
      const [cert, key, ca] = await Promise.all([
        readFile(context.tls.certFile, 'utf8'), readFile(context.tls.keyFile, 'utf8'), readFile(context.tls.caFile, 'utf8'),
      ])
      if (fingerprintOf(ca) !== context.caFingerprint) throw new AccessError(500, 'iroh_ca_mismatch')
      remoteAccess.setInstanceId(context.caFingerprint.replaceAll(':', '').toLowerCase())
      if (context.signal.aborted) throw new AccessError(409, 'remote_cancelled')
      const upstreamOrigin = `http://127.0.0.1:${ctx.webServer.port}`
      const upstreamAuth = new UpstreamAuth(
        () => ctx.connection?.authenticatedUrl?.(upstreamOrigin), () => upstreamOrigin,
      )
      const gateway = new LanGateway({
        config, access: remoteAccess, upstreamPort: () => ctx.webServer.port,
        upstreamAuth, tls: { cert, key, caFingerprint: context.caFingerprint },
        listenAddress: '127.0.0.1', listenPort: context.localPort,
        publicOrigin: () => remote.status().origin, log,
      })
      await gateway.start()
      remoteGateway = gateway
      return gateway.origin!
    },
    stopBackend: async () => {
      const gateway = remoteGateway
      remoteGateway = undefined
      await gateway?.stop()
      remoteAccess.close() // 撤掉旧会话与未使用的二维码；保留已配对设备摘要。
    },
  })
  await remote.initialize()

  // ── 管理路由（始终注册） ─────────────────────────────
  const routes: AdminRoute[] = createAdminRoutes({
    remote, remoteAccess,
    status: () => ({
      state: runtime.gateway?.state ?? 'stopped',
      origin: runtime.gateway?.origin,
      caFingerprint: runtime.gateway?.info.caFingerprint,
      listenPort: config.listenPort,
      error: runtime.gateway?.info.error,
    }),
    candidates: () => listCandidates(),
    selectedAddress: () => runtime.selectedAddress,
    setEnabled: async (enabled: boolean) => {
      runtime.control = { version: 1, enabled }
      await persistControl(config.controlFile, runtime.control)
      if (enabled) {
        await startGateway()
      } else {
        await stopGateway()
      }
      log('enabled-changed', { enabled })
    },
    selectNetwork: async (interfaceName: string) => {
      const candidates = listCandidates()
      const hit = candidates.find((c) => c.interfaceName === interfaceName)
      if (hit === undefined) {
        throw new (await import('./access.js')).AccessError(400, 'unknown_interface')
      }
      runtime.setup = { ...runtime.setup, networkInterface: interfaceName }
      await persistSetup(config.setupFile, runtime.setup)
      log('network-selected', { interfaceName, address: hit.address })
    },
    openPairing: () => access.openPairing(),
    access,
    pairingUrl: (token: string) => {
      const origin = runtime.gateway?.origin
      if (origin === undefined) return undefined
      const url = new URL('/mobile-access-next/pair', origin)
      url.searchParams.set('token', token)
      return url.toString()
    },
    listenAddress: () => runtime.selectedAddress,
    diagnostics: () => {
      const checks: DiagnosticCheck[] = []
      // 插件自己的运行时信息：上游凭据是代理链上最容易漏的一环，
      // 单独报一项（它失败时症状是「手机能看到登录页但进不去」）。
      const upstream = runtime.upstreamAuth
      checks.push({
        id: 'upstream-auth',
        level: upstream === undefined ? 'unknown' : 'ok',
        title: '上游凭据交换',
        detail:
          upstream === undefined
            ? '网关未启动，尚未初始化'
            : '已就绪（把手机的请求转给 DSH 时自动注入）',
        hint: '若手机能打开页面却一直要求登录，多半是这一环失败',
      })
      // 状态文件可写性
      const stateFile = config.stateFile
      checks.push({
        id: 'state-file',
        level: stateFile === undefined ? 'unknown' : 'ok',
        title: '设备状态文件',
        detail: stateFile ?? '未配置（设备列表只在内存里，重启即失）',
        hint: '删掉 devices.json 等于让所有手机重新配对',
      })
      const remoteStatus = remote.status()
      checks.push({
        id: 'remote-channel', level: remoteStatus.state === 'error' ? 'error' : remoteStatus.state === 'running' ? 'warn' : 'unknown',
        title: '远程通道', detail: remoteStatus.error ?? (remoteStatus.state === 'running' ? 'iroh 本机端点已就绪，手机跨网络连通性尚未验证' : '未开启'),
        hint: '使用支持 iroh 的 App 扫描配对描述符验证；原生通道只转发回环网关的 TLS 字节',
      })
      return checks
    },
  })

  for (const route of routes) {
    // 传整个 route（含 kind），不要拆字段 —— register 依赖 route.kind 选表
    const unregister = ctx.webServer.register(route)
    runtime.disposers.push(unregister)
  }
  log('admin-routes-registered', { count: routes.length })

  // ── 按 control 决定是否启动网关 ─────────────────────
  if (control.enabled) {
    await startGateway()
  } else {
    log('gateway-disabled', { hint: 'call POST /api/mobile-access-next/enable' })
  }

  // ── 注册清理 ────────────────────────────────────────
  const dispose = async (): Promise<void> => {
    for (const d of runtime.disposers.splice(0)) {
      try {
        d()
      } catch {
        // 忽略单个清理失败
      }
    }
    await remote.close()
    remoteAccess.close()
    await stopGateway()
    access.close()
    log('disposed')
  }

  if (typeof ctx.effect === 'function') {
    ctx.effect(() => dispose)
  }
}
