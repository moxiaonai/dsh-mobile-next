/**
 * 客户端模块：移动访问全屏面板。
 *
 * ## 这个文件跑在哪
 *
 * 被 `__ModuleLoader__.load()` 包装，由 DSH 的 Web 前端加载，运行在**浏览器**里。
 * 因此只能用浏览器 API（fetch / DOM / clipboard），React 由 loader 提供，不打包。
 *
 * ## 交互结构（参考 DSH 官方面板）
 *
 * ```
 * ┌──────────────────────────────────────────────────────────┐
 * │ 移动访问   ● 已开启              [诊断] [设备 2] [✕]      │ 固定头
 * ├──────────────┬───────────────────────────────────────────┤
 * │ 局域网 已开启 │ 浏览器访问 https://10.0.0.2:3444    [复制] │
 * │              │                                           │
 * │ 远程通道     │            ┌─────────────┐                │
 * │ 独立启停     │            │   二维码     │                │
 * │              │            └─────────────┘                │
 * │              │  ● 用手机扫码配对 · 剩余 4:32              │
 * │              │                                           │
 * │              │  [生成配对二维码]  [关闭局域网访问]        │
 * │              │                                           │
 * │              │  ▸ 高级：网卡 · 端口 · CA 指纹            │
 * └──────────────┴───────────────────────────────────────────┘
 * ```
 *
 * 三个“快速操作”设计点：
 *
 * 1. **侧栏一键直达**：注册到 `sidebar.panellist`，点图标即开，不再翻设置页。
 * 2. **开箱即出码**：面板打开时若网关已开启，**自动**生成配对二维码，
 *    用户不需要先点一次“生成”。（每个面板实例只自动生成一次，避免
 *    过期后无限重试。）
 * 3. **主操作随状态变**：没码时是「生成」，有码时是「复制链接」——
 *    用户永远只有一个“下一步该点哪个”的答案。
 *
 * ## 为什么不用 `@deepseek-ai/dsh-client-ui-primitives`
 *
 * DSH 的插件作者指南明确要求第三方插件**不要** require Harness 的 Client 包：
 * 它们会无预告变更，且一旦组件抛错整个 slot 条目会被摘除（控制台
 * `slot entry crashed in '<slot>'`）。这里自写控件、只用 `--dsw-alias-*`
 * token，与宿主视觉一致且不会因宿主升级而白屏。
 *
 * ## 状态矩阵
 *
 * | 网关 | 徽标 | 主区 | 主操作 |
 * | --- | --- | --- | --- |
 * | stopped | 已关闭 | 三步指引 | 开启局域网访问 |
 * | starting | 启动中 | 骨架 | disabled |
 * | running 无码 | 已开启 | 地址 + 虚线占位 | 生成配对二维码 |
 * | running 有码 | 已开启 | 地址 + 二维码 + 倒计时 | 复制配对链接 |
 * | running 过期 | 已开启 | 地址 + 过期提示 | 重新生成 |
 * | error | 出错 | 错误 + 建议 | 重试 |
 * | 无候选网卡 | 未就绪 | 未找到地址 | 重新扫描 |
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactElement, ReactNode } from 'react'

/** 管理 API 前缀（与 host 侧 `admin.ts` 一致）。 */
const ADMIN_PREFIX = '/mobile-access-next'

/** `main` 槽的面板 key，也是 `layout.selectPanel()` 的入参。 */
export const PANEL_ID = 'mobile-access'

/** 侧栏行标题。 */
const PANEL_LABEL = '移动访问'

/** 请求超时。网关挂住时面板不该永久「读取中…」。 */
const REQUEST_TIMEOUT_MS = 12_000
/** iroh 启动允许等待 60 秒，留出响应传输余量；不影响普通请求。 */
const REMOTE_START_TIMEOUT_MS = 75_000

type Channel = 'lan' | 'remote'

interface RemoteStatus {
  readonly state: 'stopped' | 'starting' | 'running' | 'error'
  readonly enabled: boolean
  readonly provider: 'iroh'
  /** 只在 App 原生 iroh 传输内解析，不是浏览器公网入口。 */
  readonly origin?: string
  readonly backendOrigin?: string
  readonly endpointId?: string
  readonly error?: string
  readonly irohPath?: string
  readonly localPort?: number
  readonly verified?: boolean
}

/** 组件需由用户自行准备；不把命令名或相对路径误当已安装组件。 */
export function validateIrohConfig(irohPath: string, port: string): {
  provider: 'iroh'; irohPath?: string; localPort: number
} {
  const path = irohPath.trim()
  if (path !== '' && !path.startsWith('/') && !/^[A-Za-z]:[\\\\/]/u.test(path)) {
    throw new Error('iroh 组件路径必须是绝对路径')
  }
  const localPort = Number(port)
  if (!Number.isInteger(localPort) || localPort < 1024 || localPort > 65535) {
    throw new Error('本地端口必须是 1024–65535 的整数')
  }
  return { provider: 'iroh', ...(path === '' ? {} : { irohPath: path }), localPort }
}

/** iroh 的复制内容是配对描述符 JSON，不是逻辑 origin 或普通网址。 */
export function irohPairingContent(payload: {
  readonly qrPayload?: string; readonly descriptor?: Record<string, unknown>
}): string {
  if (!payload.qrPayload || payload.descriptor === undefined) {
    throw new Error('后端未返回 iroh 配对描述符，请检查插件版本')
  }
  const decoded: unknown = JSON.parse(payload.qrPayload)
  if (decoded === null || typeof decoded !== 'object' || Array.isArray(decoded)) {
    throw new Error('iroh 配对描述符格式无效')
  }
  return payload.qrPayload
}

/** 通道切换或停启后，旧异步配对响应不能写入当前视图。 */
export function pairingRequestIsCurrent(
  request: { readonly channel: Channel; readonly epoch: number },
  current: { readonly channel: Channel; readonly epoch: number },
): boolean {
  return request.channel === current.channel && request.epoch === current.epoch
}

/** 面板可见时的状态轮询间隔。 */
const POLL_INTERVAL_MS = 4_000

/** 网关状态。 */
interface GatewayStatus {
  readonly remote?: RemoteStatus
  readonly state: 'stopped' | 'starting' | 'running' | 'error'
  readonly origin?: string
  readonly caFingerprint?: string
  readonly listenPort?: number
  readonly error?: string
  readonly selectedAddress?: string | null
  readonly candidates?: readonly NetworkCandidate[]
}

/** 候选网卡。 */
interface NetworkCandidate {
  readonly interfaceName: string
  readonly address: string
  readonly isPrivate: boolean
  readonly score?: number
}

/** 配对结果。 */
interface PairingPayload {
  readonly descriptor?: Record<string, unknown>
  readonly qrPayload?: string
  readonly token: string
  readonly url: string | null
  readonly qrSvg: string | null
  readonly expiresAt: number
}

/** 已配对设备。 */
interface DeviceRow {
  readonly channel: Channel
  readonly deviceId: string
  readonly label: string
  readonly createdAt?: number
  readonly lastSeenAt: number
  readonly expiresAt: number
}

/** 诊断项。 */
interface DiagnosticCheck {
  readonly id: string
  readonly level: 'ok' | 'warn' | 'error' | 'unknown'
  readonly title: string
  readonly detail: string
  readonly hint?: string
}

/** 带超时的 JSON 请求。 */
async function api<T>(path: string, init: RequestInit = {}, timeoutMs = REQUEST_TIMEOUT_MS): Promise<T> {
  const controller = new AbortController()
  const timer = setTimeout(() => {
    controller.abort()
  }, timeoutMs)
  try {
    const response = await fetch(`${ADMIN_PREFIX}${path}`, {
      credentials: 'same-origin',
      ...init,
      signal: controller.signal,
      headers:
        init.body === undefined
          ? init.headers
          : { 'content-type': 'application/json', ...init.headers },
    })
    if (!response.ok) {
      const text = await response.text().catch(() => '')
      throw new Error(`HTTP ${String(response.status)}${text === '' ? '' : `: ${text.slice(0, 120)}`}`)
    }
    return (await response.json()) as T
  } finally {
    clearTimeout(timer)
  }
}

/** 把任意错误转成一行可读文案。 */
function messageOf(error: unknown): string {
  if (error instanceof DOMException && error.name === 'AbortError') return '请求超时，请重试'
  if (error instanceof Error) return error.message
  return String(error)
}

/** 剩余毫秒 → `4:32`。 */
function formatRemaining(milliseconds: number): string {
  const total = Math.max(0, Math.ceil(milliseconds / 1000))
  const minutes = Math.floor(total / 60)
  const seconds = total % 60
  return `${String(minutes)}:${String(seconds).padStart(2, '0')}`
}

/** 时间戳 → `刚刚` / `3 分钟前` / `昨天 12:04`。 */
function formatRelative(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '未知'
  const delta = Date.now() - timestamp
  if (delta < 60_000) return '刚刚'
  if (delta < 3_600_000) return `${String(Math.floor(delta / 60_000))} 分钟前`
  if (delta < 86_400_000) return `${String(Math.floor(delta / 3_600_000))} 小时前`
  const date = new Date(timestamp)
  return `${String(date.getMonth() + 1)}/${String(date.getDate())} ${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

/** 复制文本；剪贴板 API 不可用时退回 `execCommand`。 */
async function copyText(text: string): Promise<void> {
  try {
    if (navigator.clipboard !== undefined) {
      await navigator.clipboard.writeText(text)
      return
    }
  } catch {
    // 权限被拒 → 走兜底
  }
  const area = document.createElement('textarea')
  area.value = text
  area.setAttribute('readonly', '')
  area.style.position = 'fixed'
  area.style.opacity = '0'
  document.body.appendChild(area)
  area.select()
  try {
    if (!document.execCommand('copy')) throw new Error('复制失败，请检查剪贴板权限后重试')
  } finally {
    area.remove()
  }
}

/* ────────────────────────── 小图标 ────────────────────────── */

type IconProps = { readonly size?: number }

function PhoneIcon({ size = 16 }: IconProps): ReturnType<typeof createIcon> {
  return createIcon(
    { size },
    <rect x="4.5" y="1.5" width="7" height="13" rx="2" />,
    <path d="M7 12h2" />,
  )
}

function createIcon(
  props: IconProps,
  ...children: readonly ReactNode[]
): ReactElement {
  return (
    <svg
      aria-hidden="true"
      focusable="false"
      width={props.size ?? 16}
      height={props.size ?? 16}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {children}
    </svg>
  )
}

function CopyIcon(): ReturnType<typeof createIcon> {
  return createIcon(
    {},
    <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />,
    <path d="M10.5 5.5V4A1.5 1.5 0 0 0 9 2.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5" />,
  )
}

function RefreshIcon(): ReturnType<typeof createIcon> {
  return createIcon(
    {},
    <path d="M13 8a5 5 0 1 1-1.6-3.7" />,
    <path d="M13 2.5V6H9.5" />,
  )
}

function CloseIcon(): ReturnType<typeof createIcon> {
  return createIcon({}, <path d="M4 4l8 8M12 4l-8 8" />)
}

function StethoscopeIcon(): ReturnType<typeof createIcon> {
  return createIcon(
    {},
    <path d="M5 2v4a3 3 0 0 0 6 0V2" />,
    <path d="M8 9v2a3 3 0 0 0 3 3h1" />,
    <circle cx="12.5" cy="14" r="1.2" />,
  )
}

function DevicesIcon(): ReturnType<typeof createIcon> {
  return createIcon(
    {},
    <rect x="1.5" y="3.5" width="9" height="9" rx="1.5" />,
    <path d="M12.5 5.5h1.5v8h-8V12" />,
  )
}

function ChevronIcon({ open }: { readonly open: boolean }): ReturnType<typeof createIcon> {
  return createIcon({}, <path d={open ? 'M4 10l4-4 4 4' : 'M6 4l4 4-4 4'} />)
}

/* ────────────────────────── 面板 ────────────────────────── */

/**
 * 全屏面板主体。
 *
 * 注册进 `main`（keyed）槽，由 `layout.selectPanel(PANEL_ID)` 打开。
 */
export function MobileAccessPanel(
  props: { readonly onClose?: () => void } = {},
): ReactElement {
  const { onClose } = props
  const [status, setStatus] = useState<GatewayStatus | undefined>(undefined)
  const [devices, setDevices] = useState<readonly DeviceRow[]>([])
  const [pairing, setPairing] = useState<PairingPayload | undefined>(undefined)
  const [error, setError] = useState<string | undefined>(undefined)
  const [busy, setBusy] = useState<string | undefined>(undefined)
  const [toast, setToast] = useState<string | undefined>(undefined)
  const [sheet, setSheet] = useState<'devices' | 'diagnostics' | undefined>(undefined)
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const [remaining, setRemaining] = useState(0)
  const [channel, setChannel] = useState<Channel>('lan')
  const [refreshError, setRefreshError] = useState<string | undefined>(undefined)
  /** 一次性自动出码独立于通道；切换立即使旧响应失效。 */
  const autoGenerated = useRef({ lan: false, remote: false })
  const pairingContext = useRef<{ channel: Channel; epoch: number }>({ channel: 'lan', epoch: 0 })
  const statusSequence = useRef(0)
  const previousStatus = useRef<GatewayStatus | undefined>(undefined)
  const activeState = channel === 'lan' ? status?.state : status?.remote?.state
  const running = activeState === 'running'

  const switchChannel = (next: Channel): void => {
    if (next === channel) return
    pairingContext.current = { channel: next, epoch: pairingContext.current.epoch + 1 }
    setChannel(next)
    setPairing(undefined)
    setRemaining(0)
    setError(undefined)
  }

  const refresh = useCallback(async (): Promise<void> => {
    const sequence = ++statusSequence.current
    try {
      const [nextStatus, deviceList] = await Promise.all([
        api<GatewayStatus>('/status'),
        api<{ devices: readonly DeviceRow[] }>('/devices'),
      ])
      if (sequence !== statusSequence.current) return
      const context = pairingContext.current
      const old = context.channel === 'lan' ? previousStatus.current : previousStatus.current?.remote
      const next = context.channel === 'lan' ? nextStatus : nextStatus.remote
      const endpointChanged = context.channel === 'remote' &&
        previousStatus.current?.remote?.endpointId !== nextStatus.remote?.endpointId
      if (old?.state === 'running' && (next?.state !== 'running' || old.origin !== next.origin || endpointChanged)) {
        pairingContext.current = { ...context, epoch: context.epoch + 1 }
        setPairing(undefined)
      }
      previousStatus.current = nextStatus
      setStatus(nextStatus)
      setDevices(deviceList.devices)
      setRefreshError(undefined)
    } catch (caught) {
      if (sequence === statusSequence.current) setRefreshError(messageOf(caught))
    }
  }, [])

  // 首次加载 + 可见时轮询（后台标签页不打扰 host）
  useEffect(() => {
    void refresh()
    const timer = setInterval(() => {
      if (document.visibilityState === 'visible') void refresh()
    }, POLL_INTERVAL_MS)
    return () => {
      clearInterval(timer)
    }
  }, [refresh])

  const generate = useCallback(async (): Promise<void> => {
    const request = { ...pairingContext.current, epoch: pairingContext.current.epoch + 1 }
    pairingContext.current = request
    setPairing(undefined)
    setBusy('pairing')
    try {
      const next = await api<PairingPayload>(request.channel === 'remote' ? '/remote/pairing' : '/pairing', {
        method: 'POST', body: '{}',
      })
      if (!pairingRequestIsCurrent(request, pairingContext.current)) return
      if (request.channel === 'remote') irohPairingContent(next)
      setPairing(next)
      setError(undefined)
      void refresh()
    } catch (caught) {
      if (pairingRequestIsCurrent(request, pairingContext.current)) setError(messageOf(caught))
    } finally {
      setBusy(undefined)
    }
  }, [refresh])

  // 保留 LAN 自动出码；实验性 iroh 由用户明确生成，不自动打开远程配对窗口。
  useEffect(() => {
    if (channel !== 'lan' || autoGenerated.current[channel] || !running || busy !== undefined || pairing !== undefined) return
    autoGenerated.current[channel] = true
    void generate()
  }, [channel, running, busy, pairing, generate])

  // 倒计时：只依赖 expiresAt，避免每秒重建 interval
  const expiresAt = pairing?.expiresAt
  useEffect(() => {
    if (expiresAt === undefined) {
      setRemaining(0)
      return
    }
    const tick = (): void => {
      setRemaining(Math.max(0, expiresAt - Date.now()))
    }
    tick()
    const timer = setInterval(tick, 1000)
    return () => {
      clearInterval(timer)
    }
  }, [expiresAt])

  // toast 自动消失
  useEffect(() => {
    if (toast === undefined) return
    const timer = setTimeout(() => {
      setToast(undefined)
    }, 2400)
    return () => {
      clearTimeout(timer)
    }
  }, [toast])

  const toggle = useCallback(
    async (enabled: boolean): Promise<void> => {
      const requestChannel = channel
      const request = { channel: requestChannel, epoch: pairingContext.current.epoch + 1 }
      pairingContext.current = request
      setPairing(undefined)
      setBusy('toggle')
      setError(undefined)
      try {
        await api(requestChannel === 'remote' ? '/remote/enable' : '/enable', {
          method: 'POST', body: JSON.stringify({ enabled }),
        }, requestChannel === 'remote' ? REMOTE_START_TIMEOUT_MS : REQUEST_TIMEOUT_MS)
        await refresh()
        setToast(`${requestChannel === 'remote' ? '远程通道' : '局域网访问'}${enabled ? '已启动' : '已关闭'}`)
      } catch (caught) {
        if (pairingRequestIsCurrent(request, pairingContext.current)) setError(messageOf(caught))
        void refresh()
      } finally {
        setBusy(undefined)
      }
    },
    [channel, refresh],
  )

  const copyLink = useCallback(async (): Promise<void> => {
    if (pairing === undefined || pairing.expiresAt <= Date.now()) return
    try {
      const content = channel === 'remote' ? irohPairingContent(pairing) : pairing.url
      if (content === null) return
      await copyText(content)
      setToast(channel === 'remote' ? 'iroh 配对描述符已复制，请粘贴到支持 iroh 的 App' : '配对链接已复制')
    } catch (caught) {
      setError(messageOf(caught))
    }
  }, [channel, pairing])

  const revoke = useCallback(
    async (deviceId: string, deviceChannel: Channel): Promise<void> => {
      setBusy(`revoke:${deviceChannel}:${deviceId}`)
      try {
        await api('/devices/revoke', { method: 'POST', body: JSON.stringify({ deviceId, channel: deviceChannel }) })
        await refresh()
        setToast('已撤销该设备')
      } catch (caught) {
        setError(messageOf(caught))
      } finally {
        setBusy(undefined)
      }
    },
    [refresh],
  )

  const revokeAll = useCallback(async (): Promise<void> => {
    setBusy('revoke-all')
    try {
      await api('/devices/revoke-all', { method: 'POST', body: '{}' })
      await refresh()
      setToast('已撤销全部设备')
    } catch (caught) {
      setError(messageOf(caught))
    } finally {
      setBusy(undefined)
    }
  }, [refresh])

  const selectNetwork = useCallback(
    async (interfaceName: string): Promise<void> => {
      setBusy('network')
      try {
        const result = await api<{ restartRequired?: boolean }>('/network', {
          method: 'POST',
          body: JSON.stringify({ interfaceName }),
        })
        await refresh()
        setToast(result.restartRequired === true ? '已保存，重启 DSH 后生效' : '网卡已切换')
      } catch (caught) {
        setError(messageOf(caught))
      } finally {
        setBusy(undefined)
      }
    },
    [refresh],
  )

  const phase = useMemo(() => {
    if (status === undefined) return 'loading' as const
    if (status.state === 'error') return 'error' as const
    if (status.state === 'starting') return 'starting' as const
    if (status.state === 'running') return 'running' as const
    const candidates = status.candidates ?? []
    return candidates.length === 0 ? 'no-network' as const : 'stopped' as const
  }, [status])

  const expired = pairing !== undefined && remaining <= 0

  const chip = useMemo(() => {
    switch (phase) {
      case 'running':
        return { text: '已开启', tone: 'ok' as const }
      case 'starting':
        return { text: '启动中', tone: 'warn' as const }
      case 'error':
        return { text: '出错', tone: 'err' as const }
      case 'no-network':
        return { text: '未就绪', tone: 'idle' as const }
      case 'loading':
        return { text: '读取中', tone: 'idle' as const }
      default:
        return { text: '已关闭', tone: 'idle' as const }
    }
  }, [phase])

  const remoteChip = status?.remote === undefined
    ? { text: status === undefined ? '读取中' : '不可用', tone: 'idle' }
    : status.remote.state === 'running'
      ? { text: '本地就绪', tone: 'warn' }
      : status.remote.state === 'starting'
        ? { text: '启动中', tone: 'warn' }
        : status.remote.state === 'error'
          ? { text: '出错', tone: 'err' }
          : { text: '已关闭', tone: 'idle' }
  const overallChip = status?.state === 'running' || status?.remote?.state === 'running'
    ? { text: '已开启', tone: 'ok' }
    : status?.state === 'starting' || status?.remote?.state === 'starting'
      ? { text: '启动中', tone: 'warn' }
      : status?.state === 'error' || status?.remote?.state === 'error'
        ? { text: '出错', tone: 'err' }
        : chip

  return (
    <div className="dshmn-root">
      <header className="dshmn-head">
        <div className="dshmn-headMain">
          <h1 className="dshmn-title">{PANEL_LABEL}</h1>
          <span className={`dshmn-chip dshmn-chip--${overallChip.tone}`} aria-live="polite">
            {overallChip.text}
          </span>
        </div>
        <div className="dshmn-headActions">
          <button
            type="button"
            className="dshmn-textBtn"
            onClick={() => {
              setSheet('diagnostics')
            }}
          >
            <StethoscopeIcon />
            诊断
          </button>
          <button
            type="button"
            className="dshmn-textBtn"
            onClick={() => {
              setSheet('devices')
            }}
          >
            <DevicesIcon />
            设备{devices.length > 0 ? ` ${String(devices.length)}` : ''}
          </button>
          <button
            type="button"
            className="dshmn-iconBtn"
            aria-label="关闭面板"
            title="关闭面板（Esc）"
            onClick={() => {
              onClose?.()
            }}
          >
            <CloseIcon />
          </button>
        </div>
      </header>

      <div className="dshmn-body">
        <nav className="dshmn-rail" aria-label="连接方式">
          <div className="dshmn-railTitle">连接方式</div>
          <button type="button" className="dshmn-channel" data-active={channel === 'lan'} aria-pressed={channel === 'lan'} onClick={() => { switchChannel('lan') }}>
            <span className="dshmn-channelTop">
              <span className="dshmn-channelName">局域网</span>
              <span className={`dshmn-chip dshmn-chip--${chip.tone}`}>{chip.text}</span>
            </span>
            <span className="dshmn-channelDesc">同一 Wi-Fi 或热点下直连，最快</span>
          </button>
          <button type="button" className="dshmn-channel" data-active={channel === 'remote'} aria-pressed={channel === 'remote'} onClick={() => { switchChannel('remote') }}>
            <span className="dshmn-channelTop">
              <span className="dshmn-channelName">远程通道</span>
              <span className={`dshmn-chip dshmn-chip--${remoteChip.tone}`}>{remoteChip.text}</span>
            </span>
            <span className="dshmn-channelDesc">不在同一网络时使用</span>
          </button>
        </nav>

        <main className="dshmn-main">
          {error !== undefined || refreshError !== undefined ? (
            <div className="dshmn-alert" role="alert">
              <span className="dshmn-alertText">{error ?? refreshError}</span>
              <button
                type="button"
                className="dshmn-btn dshmn-btn--small"
                onClick={() => {
                  setError(undefined)
                  void refresh()
                }}
              >
                重试
              </button>
            </div>
          ) : null}

          <div className="dshmn-remoteView" hidden={channel !== 'remote'}>
            <RemoteSection
              status={status?.remote}
              loading={status === undefined}
              pairing={channel === 'remote' ? pairing : undefined}
              remaining={channel === 'remote' ? remaining : 0}
              busy={busy !== undefined}
              busyAction={busy}
              onToggle={(enabled) => { void toggle(enabled) }}
              onGenerate={() => { void generate() }}
              onCopyLink={() => { void copyLink() }}
              onSaved={() => { void refresh(); setToast('远程配置已保存') }}
            />
          </div>
          {channel === 'lan' ? <>
          {phase === 'loading' ? (
            <div className="dshmn-card" aria-busy="true">
              <div className="dshmn-skeleton" />
              <div className="dshmn-skeleton dshmn-skeleton--wide" />
            </div>
          ) : null}

          {phase === 'no-network' ? (
            <div className="dshmn-card">
              <div className="dshmn-cardTitle">未找到局域网地址</div>
              <p className="dshmn-text">
                电脑当前没有可用的局域网 IPv4（可能没连 Wi-Fi，或只有虚拟网卡）。
                连上 Wi-Fi 后点「重新扫描」，或在高级里手动选网卡。
              </p>
              <div className="dshmn-actions">
                <button
                  type="button"
                  className="dshmn-btn dshmn-btn--primary"
                  disabled={busy !== undefined}
                  onClick={() => {
                    void refresh()
                  }}
                >
                  <RefreshIcon />
                  重新扫描
                </button>
              </div>
            </div>
          ) : null}

          {phase === 'stopped' ? (
            <div className="dshmn-card">
              <div className="dshmn-cardTitle">局域网访问未开启</div>
              <ol className="dshmn-steps">
                <li>开启局域网访问（只在本机同一网络内可访问）</li>
                <li>手机扫码或粘贴配对链接完成配对</li>
                <li>配对后手机会记住这台电脑，下次直接打开</li>
              </ol>
              <div className="dshmn-actions">
                <button
                  type="button"
                  className="dshmn-btn dshmn-btn--primary"
                  disabled={busy !== undefined}
                  onClick={() => {
                    void toggle(true)
                  }}
                >
                  {busy === 'toggle' ? '正在开启…' : '开启局域网访问'}
                </button>
                <button
                  type="button"
                  className="dshmn-btn"
                  onClick={() => {
                    setSheet('diagnostics')
                  }}
                >
                  诊断
                </button>
              </div>
              <p className="dshmn-caption">
                {status?.selectedAddress === null || status?.selectedAddress === undefined
                  ? '尚未选定网卡'
                  : `将监听 ${status.selectedAddress}:${String(status.listenPort ?? '')}`}
              </p>
            </div>
          ) : null}

          {phase === 'starting' ? (
            <div className="dshmn-card" aria-busy="true">
              <div className="dshmn-cardTitle">正在启动局域网访问…</div>
              <div className="dshmn-skeleton" />
              <div className="dshmn-skeleton dshmn-skeleton--wide" />
            </div>
          ) : null}

          {phase === 'error' ? (
            <div className="dshmn-card">
              <div className="dshmn-cardTitle dshmn-cardTitle--err">网关启动失败</div>
              <p className="dshmn-text">{status?.error ?? '未知错误'}</p>
              <p className="dshmn-caption">
                常见原因：端口 {String(status?.listenPort ?? 3444)} 被占用；证书目录不可写；
                选定的网卡已断开。
              </p>
              <div className="dshmn-actions">
                <button
                  type="button"
                  className="dshmn-btn dshmn-btn--primary"
                  disabled={busy !== undefined}
                  onClick={() => {
                    void toggle(true)
                  }}
                >
                  重试
                </button>
                <button
                  type="button"
                  className="dshmn-btn"
                  onClick={() => {
                    setSheet('diagnostics')
                  }}
                >
                  诊断
                </button>
              </div>
            </div>
          ) : null}

          {phase === 'running' ? (
            <div className="dshmn-card">
              <div className="dshmn-address">
                <span className="dshmn-addressLabel">浏览器访问</span>
                <code className="dshmn-addressValue">{status?.origin ?? '—'}</code>
                <button
                  type="button"
                  className="dshmn-iconBtn"
                  aria-label="复制地址"
                  title="复制地址"
                  onClick={() => {
                    const origin = status?.origin
                    if (origin === undefined) return
                    void copyText(origin).then(
                      () => {
                        setToast('地址已复制')
                      },
                      (caught: unknown) => {
                        setError(messageOf(caught))
                      },
                    )
                  }}
                >
                  <CopyIcon />
                </button>
              </div>

              {pairing?.qrSvg !== null && pairing?.qrSvg !== undefined && !expired ? (
                <div className="dshmn-qrWrap">
                  {/* SVG 来自我们自己的 host（qrcode 生成），内容可信 */}
                  <div
                    className="dshmn-qr"
                    dangerouslySetInnerHTML={{ __html: pairing.qrSvg }}
                  />
                  <div className={`dshmn-statusLine${remaining <= 60_000 ? ' dshmn-statusLine--warn' : ''}`}>
                    <span className="dshmn-dot" />
                    用手机扫码配对 · 剩余 {formatRemaining(remaining)}
                  </div>
                </div>
              ) : (
                <div className="dshmn-qrPlaceholder">
                  {expired ? '配对码已过期，重新生成一个' : '生成配对二维码，用手机扫描'}
                </div>
              )}

              <div className="dshmn-actions">
                {pairing !== undefined && !expired ? (
                  <button
                    type="button"
                    className="dshmn-btn dshmn-btn--primary"
                    disabled={busy !== undefined}
                    onClick={() => {
                      void copyLink()
                    }}
                  >
                    <CopyIcon />
                    复制配对链接
                  </button>
                ) : (
                  <button
                    type="button"
                    className="dshmn-btn dshmn-btn--primary"
                    disabled={busy !== undefined}
                    onClick={() => {
                      void generate()
                    }}
                  >
                    {busy === 'pairing'
                      ? '正在生成…'
                      : expired
                        ? '重新生成配对二维码'
                        : '生成配对二维码'}
                  </button>
                )}
                {pairing !== undefined && !expired ? (
                  <button
                    type="button"
                    className="dshmn-btn"
                    disabled={busy !== undefined}
                    onClick={() => {
                      void generate()
                    }}
                  >
                    <RefreshIcon />
                    重新生成
                  </button>
                ) : null}
                <button
                  type="button"
                  className="dshmn-btn"
                  disabled={busy !== undefined}
                  onClick={() => {
                    void toggle(false)
                  }}
                >
                  关闭局域网访问
                </button>
              </div>
            </div>
          ) : null}

          <AdvancedSection
            open={advancedOpen}
            onToggle={() => {
              setAdvancedOpen(!advancedOpen)
            }}
            status={status}
            busy={busy !== undefined}
            onSelectNetwork={(interfaceName) => {
              void selectNetwork(interfaceName)
            }}
            onCopyFingerprint={() => {
              const fingerprint = status?.caFingerprint
              if (fingerprint === undefined) return
              void copyText(fingerprint).then(
                () => {
                  setToast('CA 指纹已复制')
                },
                (caught: unknown) => {
                  setError(messageOf(caught))
                },
              )
            }}
          />
          </> : null}
        </main>
      </div>

      {toast !== undefined ? (
        <div className="dshmn-toast" role="status">
          {toast}
        </div>
      ) : null}

      {sheet === 'devices' ? (
        <Sheet
          title={`已配对设备（${String(devices.length)}）`}
          subtitle="撤销后该手机需要重新扫码配对"
          onClose={() => {
            setSheet(undefined)
          }}
        >
          {devices.length === 0 ? (
            <div className="dshmn-empty">还没有配对设备。生成二维码后用手机扫描即可。</div>
          ) : (
            <ul className="dshmn-list">
              {devices.map((device) => (
                <li key={`${device.channel}:${device.deviceId}`} className="dshmn-listRow">
                  <div className="dshmn-listMain">
                    <span className="dshmn-listTitle">{device.label}</span>
                    <span className="dshmn-caption">
                      {device.channel === 'remote' ? '远程通道' : '局域网'} · 最近连接 {formatRelative(device.lastSeenAt)}
                    </span>
                  </div>
                  <button
                    type="button"
                    className="dshmn-btn dshmn-btn--small dshmn-btn--danger"
                    disabled={busy !== undefined}
                    onClick={() => {
                      void revoke(device.deviceId, device.channel)
                    }}
                  >
                    {busy === `revoke:${device.channel}:${device.deviceId}` ? '撤销中…' : '撤销'}
                  </button>
                </li>
              ))}
            </ul>
          )}
          {devices.length > 1 ? (
            <div className="dshmn-sheetFooter">
              <button
                type="button"
                className="dshmn-btn dshmn-btn--danger"
                disabled={busy !== undefined}
                onClick={(event) => {
                  const target = event.currentTarget
                  if (target.dataset['confirm'] !== '1') {
                    target.dataset['confirm'] = '1'
                    target.textContent = `确认撤销全部 ${String(devices.length)} 台？`
                    return
                  }
                  void revokeAll()
                }}
              >
                全部撤销
              </button>
            </div>
          ) : null}
        </Sheet>
      ) : null}

      {sheet === 'diagnostics' ? (
        <DiagnosticsSheet
          onClose={() => {
            setSheet(undefined)
          }}
        />
      ) : null}
    </div>
  )
}

/* ────────────────────────── 远程通道 ────────────────────────── */

function RemoteSection({ status, loading, pairing, remaining, busy, busyAction, onToggle, onGenerate, onCopyLink, onSaved }: {
  readonly status: RemoteStatus | undefined
  readonly loading: boolean
  readonly pairing: PairingPayload | undefined
  readonly remaining: number
  readonly busy: boolean
  readonly busyAction: string | undefined
  readonly onToggle: (enabled: boolean) => void
  readonly onGenerate: () => void
  readonly onCopyLink: () => void
  readonly onSaved: () => void
}): ReactElement {
  const [irohPath, setIrohPath] = useState('')
  const [localPort, setLocalPort] = useState('3445')
  const [dirty, setDirty] = useState(false)
  const [saving, setSaving] = useState(false)
  const [configError, setConfigError] = useState<string | undefined>(undefined)
  const [zoomOpen, setZoomOpen] = useState(false)
  // 轮询仅同步未编辑的表单，不覆盖未保存输入。
  useEffect(() => {
    if (status === undefined || dirty) return
    setIrohPath(status.irohPath ?? '')
    setLocalPort(String(status.localPort ?? 3445))
  }, [status?.irohPath, status?.localPort, dirty])
  const savedConfigMatches = status !== undefined && irohPath.trim() === (status.irohPath ?? '') &&
    Number(localPort) === (status.localPort ?? 3445)
  const pendingConfig = dirty && !savedConfigMatches
  useEffect(() => {
    if (dirty && savedConfigMatches && !saving) setDirty(false)
  }, [dirty, savedConfigMatches, saving])
  const locked = status?.state !== 'stopped' || busy || saving
  const running = status?.state === 'running'
  const expired = pairing !== undefined && (remaining <= 0 || pairing.expiresAt <= Date.now())
  const validPairing = running && pairing?.qrPayload !== undefined && !expired
  useEffect(() => { setZoomOpen(false) }, [pairing?.qrPayload, running, expired])

  const save = async (): Promise<void> => {
    if (status?.state !== 'stopped') return
    setSaving(true)
    setConfigError(undefined)
    try {
      const config = validateIrohConfig(irohPath, localPort)
      await api('/remote/config', { method: 'POST', body: JSON.stringify(config) })
      setLocalPort(String(config.localPort))
      // 等新状态确认后才解除 dirty，避免用保存前的轮询值回填。
      onSaved()
    } catch (caught) {
      setConfigError(messageOf(caught))
    } finally {
      setSaving(false)
    }
  }

  if (status === undefined) return (
    <div className="dshmn-card" aria-busy={loading}>
      <div className="dshmn-cardTitle">{loading ? '正在读取远程状态…' : '远程通道不可用'}</div>
      {!loading ? <p className="dshmn-text">后端尚未提供 iroh 状态，请检查插件版本。</p> : <div className="dshmn-skeleton" />}
    </div>
  )

  return <>
    <section className="dshmn-card" aria-label="iroh 远程配置">
      <div className="dshmn-channelTop"><div className="dshmn-cardTitle">iroh 远程通道</div><span className="dshmn-chip dshmn-chip--warn">实验性</span></div>
      <p className="dshmn-text">加密直连优先，中继兜底。不需要公网域名或端口映射；局域网与远程独立启停、独立配对。</p>
      <p className="dshmn-hint">需要安装支持原生 iroh 的 App（Android 完整版）。普通手机浏览器不能使用 iroh 描述符或逻辑地址连接。</p>
      <label className="dshmn-field"><span className="dshmn-fieldLabel">iroh sidecar 组件绝对路径</span>
        <input className="dshmn-input" type="text" value={irohPath} placeholder="/absolute/path/dsh-mobile-iroh-host" spellCheck={false} autoCapitalize="none" disabled={locked} onChange={(event) => { setIrohPath(event.currentTarget.value); setDirty(true); setConfigError(undefined) }} />
      </label>
      <p className="dshmn-caption">请自行构建或准备与当前平台匹配的 native 组件，再填写路径。这里不会自动下载或安装；组件不存在或无法启动时会报告错误，不会显示就绪。</p>
      <label className="dshmn-field"><span className="dshmn-fieldLabel">本地专用网关端口</span>
        <input className="dshmn-input" type="number" min={1024} max={65535} step={1} value={localPort} disabled={locked} onChange={(event) => { setLocalPort(event.currentTarget.value); setDirty(true); setConfigError(undefined) }} />
      </label>
      <p className="dshmn-caption">默认 3445，仅供 sidecar 连接本地回环网关，不是公网访问端口。</p>
      {configError !== undefined ? <div className="dshmn-alert" role="alert"><span className="dshmn-alertText">{configError}</span><button type="button" className="dshmn-btn dshmn-btn--small" disabled={locked} onClick={() => { void save() }}>重试保存</button></div> : null}
      <div className="dshmn-actions">
        <button type="button" className="dshmn-btn" disabled={locked || !pendingConfig} onClick={() => { void save() }}>{saving ? '正在保存…' : '保存配置'}</button>
        {status.state === 'stopped' ? <button type="button" className="dshmn-btn dshmn-btn--primary" disabled={busy || saving || pendingConfig || !status.irohPath?.trim()} onClick={() => { onToggle(true) }}>{busyAction === 'toggle' ? '正在开启…' : '开启 iroh 远程通道'}</button> :
          <button type="button" className="dshmn-btn" disabled={busy || saving} onClick={() => { onToggle(false) }}>关闭 iroh 远程通道</button>}
      </div>
      <p className="dshmn-caption">{pendingConfig ? '有未保存的配置，请先保存再开启。' : status.state !== 'stopped' ? '请先关闭远程通道，再修改配置。' : !status.irohPath?.trim() ? '尚未配置 native 组件，请填写绝对路径并保存后再开启。' : '配置仅在停止时可保存。'}</p>
    </section>
    {status.state === 'starting' || busyAction === 'toggle' && status.state === 'stopped' ? <div className="dshmn-card" aria-busy="true"><div className="dshmn-cardTitle">正在启动 iroh 通道…</div><p className="dshmn-text">正在准备本地网关与端点，可能需要 60 秒，请稍候。</p><div className="dshmn-skeleton" /></div> : null}
    {status.state === 'error' ? <div className="dshmn-card"><div className="dshmn-cardTitle dshmn-cardTitle--err">iroh 通道启动失败</div><p className="dshmn-text" role="alert">{status.error ?? '未知错误'}</p><p className="dshmn-caption">检查 native 组件绝对路径、平台兼容性、本地端口和网络连接。修改配置前先关闭通道；不要删除已有端点身份或关闭证书验证。</p><div className="dshmn-actions"><button type="button" className="dshmn-btn dshmn-btn--primary" disabled={busy || saving || pendingConfig || !status.irohPath?.trim()} onClick={() => { onToggle(true) }}>重试启动</button></div></div> : null}
    {running ? <section className="dshmn-card" aria-label="iroh 配对">
      <div className="dshmn-cardTitle">本地端点已就绪 · 手机跨网尚未验证</div>
      <p className="dshmn-hint">本地就绪不代表手机已连通，也不保证所有网络可用。端点连接中继服务不代表数据一定经过中继。请使用支持原生 iroh 的 App 验证跨网连接。</p>
      <div className="dshmn-field"><span className="dshmn-fieldLabel">端点身份</span><code className="dshmn-mono">{status.endpointId ?? '未返回端点身份'}</code></div>
      {status.origin !== undefined ? <div className="dshmn-field"><span className="dshmn-fieldLabel">App 内部逻辑地址（不可在浏览器打开）</span><code className="dshmn-mono">{status.origin}</code></div> : null}
      {status.backendOrigin !== undefined ? <div className="dshmn-field"><span className="dshmn-fieldLabel">本地回环 backendOrigin（仅供 sidecar）</span><code className="dshmn-mono">{status.backendOrigin}</code></div> : null}
      {validPairing && pairing?.qrSvg ? <div className="dshmn-qrWrap"><button type="button" className="dshmn-qrButton" aria-label="放大 iroh 配对二维码" onClick={() => { setZoomOpen(true) }}><div className="dshmn-qr dshmn-qr--iroh" role="img" aria-label="iroh 配对二维码" dangerouslySetInnerHTML={{ __html: pairing.qrSvg }} /></button><span className="dshmn-caption">点击二维码可放大；也可复制描述符粘贴到 App</span></div> : <div className="dshmn-qrPlaceholder">{expired ? 'iroh 配对窗口已过期，请重新生成' : validPairing ? '二维码未生成，可复制配对描述符到 App' : '明确生成 iroh 配对二维码，用支持 iroh 的 App 扫描'}</div>}
      {validPairing ? <div className={`dshmn-statusLine${remaining <= 60_000 ? ' dshmn-statusLine--warn' : ''}`}><span className="dshmn-dot" />iroh 配对窗口 · 剩余 {formatRemaining(remaining)}</div> : null}
      <div className="dshmn-actions">
        <button type="button" className="dshmn-btn dshmn-btn--primary" disabled={busy || saving} onClick={onGenerate}><RefreshIcon />{busyAction === 'pairing' ? '正在生成…' : pairing !== undefined ? '重新生成 iroh 配对二维码' : '生成 iroh 配对二维码'}</button>
        <button type="button" className="dshmn-btn" disabled={busy || saving || !validPairing} onClick={onCopyLink}><CopyIcon />复制 iroh 配对描述符</button>
      </div>
      <p className="dshmn-caption">复制的是 JSON 配对描述符，不是普通网址；重复复制不会刷新或替换令牌。不要分享描述符或二维码。重新生成将替换旧配对窗口，但不影响局域网配对码。</p>
    </section> : null}
    {zoomOpen && validPairing && pairing?.qrSvg ? <Sheet title="iroh 配对二维码" subtitle="请使用支持原生 iroh 的 App 扫描" onClose={() => { setZoomOpen(false) }}><div className="dshmn-qrWrap"><div className="dshmn-qr dshmn-qr--zoom" role="img" aria-label="放大的 iroh 配对二维码" dangerouslySetInnerHTML={{ __html: pairing.qrSvg }} /><span className="dshmn-caption">剩余 {formatRemaining(remaining)}</span></div></Sheet> : null}
  </>
}

/* ────────────────────────── 高级折叠 ────────────────────────── */

function AdvancedSection({
  open,
  onToggle,
  status,
  busy,
  onSelectNetwork,
  onCopyFingerprint,
}: {
  readonly open: boolean
  readonly onToggle: () => void
  readonly status: GatewayStatus | undefined
  readonly busy: boolean
  readonly onSelectNetwork: (interfaceName: string) => void
  readonly onCopyFingerprint: () => void
}): ReactElement {
  const candidates = status?.candidates ?? []
  const selected = status?.selectedAddress ?? undefined

  return (
    <div className="dshmn-advanced">
      <button
        type="button"
        className="dshmn-disclosure"
        aria-expanded={open}
        onClick={onToggle}
      >
        <ChevronIcon open={open} />
        高级：网卡 · 端口 · 证书
      </button>
      {open ? (
        <div className="dshmn-advancedBody">
          <div className="dshmn-field">
            <div className="dshmn-fieldLabel">网卡</div>
            {candidates.length === 0 ? (
              <div className="dshmn-caption">没有可用候选网卡</div>
            ) : (
              <div className="dshmn-options">
                {candidates.map((candidate) => {
                  const active = candidate.address === selected
                  return (
                    <button
                      key={candidate.interfaceName}
                      type="button"
                      className="dshmn-option"
                      data-active={active ? 'true' : 'false'}
                      aria-pressed={active}
                      disabled={busy}
                      onClick={() => {
                        onSelectNetwork(candidate.interfaceName)
                      }}
                    >
                      <span className="dshmn-optionName">{candidate.interfaceName}</span>
                      <span className="dshmn-optionValue">{candidate.address}</span>
                    </button>
                  )
                })}
              </div>
            )}
          </div>
          <div className="dshmn-field">
            <div className="dshmn-fieldLabel">监听端口</div>
            <div className="dshmn-mono">{String(status?.listenPort ?? 3444)}</div>
          </div>
          <div className="dshmn-field">
            <div className="dshmn-fieldLabel">CA 指纹</div>
            {status?.caFingerprint === undefined ? (
              <div className="dshmn-caption">网关未启动，暂无证书</div>
            ) : (
              <div className="dshmn-fingerprint">
                <code className="dshmn-mono">{status.caFingerprint}</code>
                <button type="button" className="dshmn-btn dshmn-btn--small" onClick={onCopyFingerprint}>
                  复制
                </button>
              </div>
            )}
          </div>
        </div>
      ) : null}
    </div>
  )
}

/* ────────────────────────── 抽屉 ────────────────────────── */

function Sheet({
  title,
  subtitle,
  onClose,
  children,
}: {
  readonly title: string
  readonly subtitle?: string
  readonly onClose: () => void
  readonly children: ReactNode
}): ReactElement {
  const container = useRef<HTMLDivElement>(null)
  const closeRef = useRef(onClose)
  closeRef.current = onClose

  // Esc 关闭 + Tab 焦点循环（与宿主 Modal 的行为对齐）
  useEffect(() => {
    const node = container.current
    if (node === null) return
    const previous = document.activeElement as HTMLElement | null
    const focusables = (): readonly HTMLElement[] =>
      Array.from(
        node.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ),
      )
    focusables()[0]?.focus()
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        closeRef.current()
        return
      }
      if (event.key !== 'Tab') return
      const items = focusables()
      const first = items[0]
      const last = items[items.length - 1]
      if (first === undefined || last === undefined) return
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }
    node.addEventListener('keydown', onKeyDown)
    return () => {
      node.removeEventListener('keydown', onKeyDown)
      previous?.focus?.()
    }
  }, [])

  return (
    <div className="dshmn-scrim">
      <div
        ref={container}
        className="dshmn-sheet"
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <div className="dshmn-sheetHead">
          <div>
            <div className="dshmn-sheetTitle">{title}</div>
            {subtitle === undefined ? null : <div className="dshmn-caption">{subtitle}</div>}
          </div>
          <button
            type="button"
            className="dshmn-iconBtn"
            aria-label="关闭"
            onClick={onClose}
          >
            <CloseIcon />
          </button>
        </div>
        <div className="dshmn-sheetBody">{children}</div>
      </div>
    </div>
  )
}

/* ────────────────────────── 诊断 ────────────────────────── */

function DiagnosticsSheet({ onClose }: { readonly onClose: () => void }): ReactElement {
  const [checks, setChecks] = useState<readonly DiagnosticCheck[] | undefined>(undefined)
  const [error, setError] = useState<string | undefined>(undefined)

  const load = useCallback(async (): Promise<void> => {
    try {
      const result = await api<{ checks: readonly DiagnosticCheck[] }>('/diagnostics')
      setChecks(result.checks)
      setError(undefined)
    } catch (caught) {
      setError(messageOf(caught))
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  return (
    <Sheet title="诊断" subtitle="拿不到的项目显示「未检查」，不假装通过" onClose={onClose}>
      {error !== undefined ? <div className="dshmn-alert">{error}</div> : null}
      {checks === undefined ? (
        <div className="dshmn-empty">正在检查…</div>
      ) : (
        <ul className="dshmn-list">
          {checks.map((check) => (
            <li key={check.id} className="dshmn-check" data-level={check.level}>
              <span className="dshmn-checkMark" aria-hidden="true">
                {check.level === 'ok'
                  ? '✓'
                  : check.level === 'warn'
                    ? '!'
                    : check.level === 'error'
                      ? '✕'
                      : '?'}
              </span>
              <div className="dshmn-listMain">
                <span className="dshmn-listTitle">
                  {check.title}
                  <span className="dshmn-srOnly">
                    ：{check.level === 'ok' ? '正常' : check.level === 'warn' ? '注意' : check.level === 'error' ? '失败' : '未检查'}
                  </span>
                </span>
                <span className="dshmn-caption">{check.detail}</span>
                {check.hint === undefined ? null : (
                  <span className="dshmn-hint">{check.hint}</span>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
      <div className="dshmn-sheetFooter">
        <button
          type="button"
          className="dshmn-btn"
          onClick={() => {
            void load()
          }}
        >
          <RefreshIcon />
          重新检查
        </button>
      </div>
    </Sheet>
  )
}

/* ────────────────────────── 侧栏入口 ────────────────────────── */

/** 侧栏图标。只画图标，尺寸由宿主给。 */
export function MobilePanelIcon(props: { readonly size?: number } = {}): ReactElement {
  return <PhoneIcon size={props.size ?? 18} />
}

/**
 * 插件页里的兜底入口。
 *
 * 主入口是侧栏图标；这一行保证「面板万一打不开」时仍有一条可达路径，
 * 点一下同样切到全屏面板。
 */
export function MobileAccessRow(props: { readonly onOpen?: () => void } = {}): ReactElement {
  const { onOpen } = props
  return (
    <div className="dshmn-row">
      <div className="dshmn-listMain">
        <span className="dshmn-listTitle">{PANEL_LABEL}</span>
        <span className="dshmn-caption">在侧栏点手机图标可直接打开；也可从这里进入</span>
      </div>
      <button
        type="button"
        className="dshmn-btn dshmn-btn--small"
        onClick={() => {
          onOpen?.()
        }}
      >
        打开面板
      </button>
    </div>
  )
}

/* ────────────────────────── 样式 ────────────────────────── */

/**
 * 样式。
 *
 * 只用宿主 token（`--dsw-alias-*` / `--dsw-radius-*` / `--dsw-shadow-*`），
 * 因此明暗主题自动跟随。唯一写死颜色的是二维码底板：扫码需要固定
 * 白底黑码，不能跟随暗色主题。
 */
const STYLES = `
.dshmn-root {
  position: relative; display: flex; flex-direction: column;
  flex: 1; min-width: 0; min-height: 0;
  container-type: inline-size;
  background: var(--dsw-alias-bg-base);
  color: var(--dsw-alias-label-primary);
  font-family: var(--dsw-font-family, -apple-system, system-ui, sans-serif);
  font-size: 14px; line-height: 20px;

  /* 状态色直接当文字色对比度不够：
     green-500 on green-100 = 2.09:1，amber-500 on amber-100 = 1.99:1（实测）。
     把状态色压向 label-primary 后达标（浅色 6.8 / 6.6，深色 8.2 / 10.9），
     且仍然看得出是"绿/黄"——与宿主 contextGreen 的 color-mix 写法同源。 */
  --dshmn-success-text: color-mix(in srgb, var(--dsw-alias-state-success-primary) 45%, var(--dsw-alias-label-primary));
  --dshmn-warn-text: color-mix(in srgb, var(--dsw-alias-state-warn-primary) 45%, var(--dsw-alias-label-primary));

  /* 次级文字：宿主的 label-caption 本身只有 2.13:1（浅色），直接拿来写说明文字
     不达标。压向 label-primary 后浅色 4.84:1、深色 8.79:1，仍然明显弱于正文。 */
  --dshmn-muted: color-mix(in srgb, var(--dsw-alias-label-caption) 60%, var(--dsw-alias-label-primary));
}
.dshmn-head {
  display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 12px;
  padding: 16px 24px 12px;
  padding-top: calc(16px + var(--dsh-frame-top-clearance, 0px));
  border-bottom: .5px solid var(--dsw-alias-border-l3);
  flex: none;
}
.dshmn-headMain { display: flex; align-items: center; gap: 10px; min-width: 0; }
.dshmn-title { margin: 0; font-size: 17px; font-weight: 600; line-height: 24px; }
.dshmn-headActions { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; flex: 0 1 auto; max-width: 100%; margin-left: auto; }
.dshmn-textBtn {
  display: inline-flex; align-items: center; gap: 6px;
  min-height: 44px; padding: 0 10px; border: 0; border-radius: var(--dsw-radius-sm);
  background: transparent; color: var(--dsw-alias-label-secondary);
  font: inherit; font-size: 13px; cursor: pointer;
}
.dshmn-textBtn:hover { background: var(--dsw-alias-interactive-bg-hover); color: var(--dsw-alias-label-primary); }
.dshmn-iconBtn {
  display: inline-flex; align-items: center; justify-content: center;
  width: 44px; height: 44px; padding: 0; border: 0; border-radius: var(--dsw-radius-sm);
  background: transparent; color: var(--dsw-alias-label-secondary); cursor: pointer;
}
.dshmn-iconBtn:hover { background: var(--dsw-alias-interactive-bg-hover); color: var(--dsw-alias-label-primary); }
.dshmn-textBtn:focus-visible, .dshmn-iconBtn:focus-visible,
.dshmn-btn:focus-visible, .dshmn-channel:focus-visible,
.dshmn-disclosure:focus-visible, .dshmn-option:focus-visible,
.dshmn-input:focus-visible, .dshmn-qrButton:focus-visible {
  outline: var(--dsw-focus-ring-width, 2px) solid var(--dsw-focus-ring-color, var(--dsw-alias-state-business-primary));
  outline-offset: 1px;
}

.dshmn-body { display: flex; flex: 1; min-height: 0; }
.dshmn-rail {
  width: 224px; flex: none; display: flex; flex-direction: column; gap: 4px;
  padding: 16px 12px; overflow: auto;
  border-right: .5px solid var(--dsw-alias-border-l3);
}
.dshmn-railTitle {
  padding: 0 8px 6px; font-size: 12px; line-height: 16px;
  color: var(--dshmn-muted);
}
.dshmn-channel {
  display: flex; flex-direction: column; gap: 4px; width: 100%;
  padding: 10px 10px; border-radius: var(--dsw-radius-md);
  border: .5px solid transparent; background: transparent; text-align: left;
  color: inherit; font: inherit; cursor: pointer;
}
.dshmn-channel[data-active="true"] {
  background: var(--dsw-alias-bg-layer-2);
  border-color: var(--dsw-alias-border-l3);
}
.dshmn-channel[data-disabled="true"] { opacity: .55; cursor: not-allowed; }
.dshmn-channelTop { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.dshmn-channelName { font-weight: 600; font-size: 14px; }
.dshmn-channelDesc { font-size: 12px; line-height: 16px; color: var(--dshmn-muted); }

.dshmn-main {
  flex: 1; min-width: 0; overflow: auto;
  padding: 20px 24px 32px;
  display: flex; flex-direction: column; gap: 16px;
}
/* 内容列居中：面板在 1440 宽的窗口里也有平衡的留白，而不是贴着左边缘 */
.dshmn-main > * { width: 100%; max-width: 720px; margin-inline: auto; }
.dshmn-remoteView { display: flex; flex-direction: column; gap: 16px; }
.dshmn-remoteView[hidden] { display: none; }

.dshmn-card {
  display: flex; flex-direction: column; gap: 14px;
  padding: 18px; border-radius: var(--dsw-radius-lg);
  border: .5px solid var(--dsw-alias-border-l3);
  background: var(--dsw-alias-bg-layer-2);
}
.dshmn-cardTitle { font-size: 15px; font-weight: 600; }
.dshmn-cardTitle--err { color: var(--dsw-alias-state-error-primary); }
.dshmn-text { margin: 0; color: var(--dsw-alias-label-secondary); }
.dshmn-caption { font-size: 12px; line-height: 18px; color: var(--dshmn-muted); }
.dshmn-hint { font-size: 12px; line-height: 18px; color: var(--dshmn-warn-text); }
.dshmn-mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px; word-break: break-all;
}
.dshmn-steps {
  margin: 0; padding-left: 18px; display: flex; flex-direction: column; gap: 6px;
  color: var(--dsw-alias-label-secondary);
}

.dshmn-address {
  display: flex; align-items: center; gap: 8px; flex-wrap: wrap;
  padding: 10px 12px; border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-bg-base);
  border: .5px solid var(--dsw-alias-border-l2);
}
.dshmn-addressLabel { font-size: 12px; color: var(--dshmn-muted); flex: none; }
.dshmn-addressValue {
  flex: 1; min-width: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 13px; word-break: break-all;
}

.dshmn-qrWrap { display: flex; flex-direction: column; align-items: center; gap: 10px; }
.dshmn-qr {
  width: 200px; height: 200px; padding: 10px;
  border-radius: var(--dsw-radius-md);
  background: #ffffff; /* 扫码需要固定白底，不跟随暗色主题 */
}
.dshmn-qr svg { width: 100%; height: 100%; display: block; }
.dshmn-qrPlaceholder {
  display: flex; align-items: center; justify-content: center;
  min-height: 160px; border-radius: var(--dsw-radius-md);
  border: 1px dashed var(--dsw-alias-border-l3);
  color: var(--dshmn-muted); text-align: center; padding: 16px;
}
.dshmn-statusLine {
  display: inline-flex; align-items: center; gap: 6px;
  font-size: 13px; color: var(--dsw-alias-label-secondary);
  font-variant-numeric: tabular-nums;
}
.dshmn-statusLine--warn { color: var(--dshmn-warn-text); }
.dshmn-dot {
  width: 6px; height: 6px; border-radius: 50%;
  background: currentColor; flex: none;
}

.dshmn-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.dshmn-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  min-height: 44px; padding: 0 16px;
  border-radius: var(--dsw-radius-md);
  border: .5px solid var(--dsw-alias-border-l2);
  background: var(--dsw-alias-bg-base);
  color: var(--dsw-alias-label-primary);
  font: inherit; font-size: 14px; cursor: pointer;
  transition: background .12s ease-out;
}
.dshmn-btn:hover:not(:disabled) { background: var(--dsw-alias-interactive-bg-hover); }
.dshmn-btn--primary {
  min-height: 48px; padding: 0 20px; font-weight: 600;
  background: var(--dsw-alias-button-primary-fill);
  border-color: transparent;
  color: var(--dsw-alias-label-primary-foreground);
}
.dshmn-btn--primary:hover:not(:disabled) { background: var(--dsw-alias-button-primary-hover); }
.dshmn-btn--danger { color: var(--dsw-alias-state-error-primary); }
.dshmn-btn--small { min-height: 36px; padding: 0 12px; font-size: 13px; }
.dshmn-btn:disabled { opacity: .45; cursor: not-allowed; }

.dshmn-chip {
  display: inline-flex; align-items: center;
  font-size: 12px; line-height: 20px; padding: 0 8px; border-radius: 999px;
  border: .5px solid var(--dsw-alias-border-l2);
  background: var(--dsw-alias-bg-base);
  color: var(--dsw-alias-label-secondary); white-space: nowrap;
}
.dshmn-chip--ok {
  color: var(--dshmn-success-text);
  background: var(--dsw-alias-state-success-tertiary);
  border-color: transparent;
}
.dshmn-chip--warn {
  color: var(--dshmn-warn-text);
  background: var(--dsw-alias-state-warn-tertiary);
  border-color: transparent;
}
.dshmn-chip--err {
  color: var(--dsw-alias-state-error-primary);
  background: transparent;
  border-color: currentColor;
}
.dshmn-chip--idle { color: var(--dshmn-muted); }

.dshmn-alert {
  display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
  padding: 10px 12px; border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-bg-layer-2);
  border: .5px solid var(--dsw-alias-state-error-primary);
  color: var(--dsw-alias-state-error-primary);
  font-size: 13px;
}
.dshmn-alertText { flex: 1; min-width: 0; word-break: break-word; }

.dshmn-skeleton {
  height: 14px; width: 60%; border-radius: var(--dsw-radius-xs);
  background: var(--dsw-alias-bg-skeleton);
}
.dshmn-skeleton--wide { width: 90%; }

.dshmn-advanced {
  display: flex; flex-direction: column; gap: 8px;
  border-top: .5px solid var(--dsw-alias-border-l3);
  padding-top: 12px;
}
.dshmn-disclosure {
  display: inline-flex; align-items: center; gap: 6px;
  min-height: 44px; padding: 0 4px; border: 0; background: transparent;
  color: var(--dsw-alias-label-secondary); font: inherit; font-size: 13px; cursor: pointer;
}
.dshmn-disclosure:hover { color: var(--dsw-alias-label-primary); }
.dshmn-advancedBody { display: flex; flex-direction: column; gap: 14px; padding: 4px 4px 0; }
.dshmn-field { display: flex; flex-direction: column; gap: 6px; }
.dshmn-fieldLabel { font-size: 12px; color: var(--dshmn-muted); }
.dshmn-input {
  box-sizing: border-box; width: 100%; min-width: 0; min-height: 44px; padding: 8px 12px;
  border: .5px solid var(--dsw-alias-border-l2); border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-bg-base); color: var(--dsw-alias-label-primary); font: inherit;
}
.dshmn-input:disabled { opacity: .6; cursor: not-allowed; }
.dshmn-qrButton { padding: 0; border: 0; border-radius: var(--dsw-radius-md); background: transparent; cursor: zoom-in; }
.dshmn-qr--iroh { width: 260px; height: 260px; }
.dshmn-qr--zoom { box-sizing: border-box; width: min(100%, 380px); height: auto; aspect-ratio: 1; }
.dshmn-options { display: flex; flex-direction: column; gap: 4px; }
.dshmn-option {
  display: flex; align-items: center; gap: 10px; min-height: 40px; padding: 0 10px;
  border-radius: var(--dsw-radius-sm);
  border: .5px solid var(--dsw-alias-border-l2);
  background: transparent; color: inherit; font: inherit; font-size: 13px;
  cursor: pointer; text-align: left;
}
.dshmn-option[data-active="true"] {
  border-color: var(--dsw-alias-state-business-primary);
  background: var(--dsw-alias-bg-layer-2);
}
.dshmn-optionName { font-weight: 600; }
.dshmn-optionValue { font-family: ui-monospace, monospace; font-size: 12px; color: var(--dsw-alias-label-secondary); }
.dshmn-fingerprint { display: flex; align-items: flex-start; gap: 8px; }
.dshmn-fingerprint .dshmn-mono { flex: 1; min-width: 0; color: var(--dsw-alias-label-secondary); }

.dshmn-toast {
  position: absolute; left: 50%; bottom: 24px; transform: translateX(-50%);
  padding: 8px 14px; border-radius: var(--dsw-radius-md);
  background: var(--dsw-alias-toast-bg);
  color: var(--dsw-alias-label-primary-foreground);
  font-size: 13px; box-shadow: var(--dsw-shadow-lv2);
  z-index: 30; pointer-events: none;
}

.dshmn-scrim {
  position: absolute; inset: 0; z-index: 20;
  display: flex; justify-content: flex-end;
  background: var(--dsw-alias-bg-mask-1);
}
.dshmn-sheet {
  display: flex; flex-direction: column;
  width: min(440px, 100%); height: 100%;
  background: var(--dsw-alias-bg-base);
  border-left: .5px solid var(--dsw-alias-border-l3);
  box-shadow: var(--dsw-shadow-lv2);
}
.dshmn-sheetHead {
  display: flex; align-items: flex-start; justify-content: space-between; gap: 12px;
  padding: 16px 16px 12px; border-bottom: .5px solid var(--dsw-alias-border-l3);
  flex: none;
}
.dshmn-sheetTitle { font-size: 15px; font-weight: 600; }
.dshmn-sheetBody { flex: 1; min-height: 0; overflow: auto; padding: 12px 16px 20px; }
.dshmn-sheetFooter {
  display: flex; gap: 8px; padding-top: 12px; margin-top: 12px;
  border-top: .5px solid var(--dsw-alias-border-l3);
}
.dshmn-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }
.dshmn-listRow {
  display: flex; align-items: center; gap: 12px; justify-content: space-between;
  min-height: 56px; padding: 8px 0;
  border-bottom: .5px solid var(--dsw-alias-border-l1);
}
.dshmn-listMain { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.dshmn-listTitle { font-size: 14px; font-weight: 500; }
.dshmn-empty { padding: 24px 4px; color: var(--dshmn-muted); text-align: center; }
.dshmn-check {
  display: flex; align-items: flex-start; gap: 10px;
  padding: 10px 0; border-bottom: .5px solid var(--dsw-alias-border-l1);
}
.dshmn-checkMark {
  display: inline-flex; align-items: center; justify-content: center;
  width: 20px; height: 20px; flex: none; border-radius: 50%;
  font-size: 12px; font-weight: 700;
  background: var(--dsw-alias-bg-layer-2);
  color: var(--dsw-alias-label-secondary);
}
.dshmn-check[data-level="ok"] .dshmn-checkMark {
  background: var(--dsw-alias-state-success-tertiary);
  color: var(--dshmn-success-text);
}
.dshmn-check[data-level="warn"] .dshmn-checkMark {
  background: var(--dsw-alias-state-warn-tertiary);
  color: var(--dshmn-warn-text);
}
.dshmn-check[data-level="error"] .dshmn-checkMark {
  background: transparent; color: var(--dsw-alias-state-error-primary);
  border: 1px solid currentColor;
}
.dshmn-srOnly {
  position: absolute; width: 1px; height: 1px; overflow: hidden;
  clip: rect(0 0 0 0); white-space: nowrap;
}
.dshmn-row {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  min-height: 44px; padding: 8px 0;
}

@container (max-width: 720px) {
  .dshmn-body { flex-direction: column; }
  .dshmn-rail { box-sizing: border-box; width: 100%; flex-direction: row; padding: 8px 12px; border-right: 0; border-bottom: .5px solid var(--dsw-alias-border-l3); }
  .dshmn-railTitle { display: none; }
  .dshmn-channel { flex: 1; min-width: 0; }
  .dshmn-channelDesc { display: none; }
  .dshmn-head { padding-left: 16px; padding-right: 16px; }
  .dshmn-main { padding: 16px 16px 28px; }
  .dshmn-qr { width: 176px; height: 176px; }
  .dshmn-qr--iroh { width: min(260px, 60cqw); height: auto; aspect-ratio: 1; }
  .dshmn-qr--zoom { width: min(100%, 380px); height: auto; }
}

@media (prefers-reduced-motion: reduce) {
  .dshmn-btn { transition: none; }
}
`

function installStyles(document: Document): void {
  const id = 'dsh-mobile-next-styles'
  if (document.getElementById(id) !== null) return
  const style = document.createElement('style')
  style.id = id
  style.textContent = STYLES
  document.head.appendChild(style)
}

/* ────────────────────────── 注册 ────────────────────────── */

/** 只需要 slots。`layout` 用 `ctx.get('layout')` 惰性取，缺了也不拒绝激活。 */
export const inject = ['slots'] as const

/** 注册面板、侧栏入口、插件页兜底行。 */
export function apply(ctx: {
  readonly slots: {
    inject: (name: string, callback: () => () => void) => () => void
    register: (options: Record<string, unknown>, component: (props: never) => unknown) => () => void
  }
  readonly effect: (callback: () => () => void) => void
  readonly get?: (name: string) => unknown
}): void {
  const layoutOf = (): { selectPanel: (id: string | null) => void } | undefined => {
    const layout = ctx.get?.('layout')
    if (layout === undefined || layout === null) return undefined
    const candidate = layout as { selectPanel?: unknown }
    if (typeof candidate.selectPanel !== 'function') return undefined
    return layout as { selectPanel: (id: string | null) => void }
  }

  const openPanel = (): void => {
    try {
      layoutOf()?.selectPanel(PANEL_ID)
    } catch (error) {
      // selectPanel 对未注册的 id 会抛错 —— 面板没注册上时不该炸掉侧栏
      console.warn('[dsh-mobile-next] 无法打开面板:', error)
    }
  }

  const closePanel = (): void => {
    try {
      layoutOf()?.selectPanel(null)
    } catch {
      // 同上：关闭失败不影响其余交互
    }
  }

  ctx.effect(() => {
    installStyles(document)
    return () => {
      document.getElementById('dsh-mobile-next-styles')?.remove()
    }
  })

  // ① 侧栏图标入口（主入口，一键直达）
  ctx.slots.inject('sidebar.panellist', () =>
    ctx.slots.register(
      {
        name: 'sidebar.panellist',
        id: PANEL_ID,
        order: 30,
        label: () => PANEL_LABEL,
      },
      MobilePanelIcon as unknown as (props: never) => unknown,
    ),
  )

  // ② 中栏全屏面板（keyed 槽，key 必填）
  ctx.slots.inject('main', () =>
    ctx.slots.register(
      {
        name: 'main',
        key: PANEL_ID,
      },
      ((props: { onClose?: () => void } = {}) => (
        <MobileAccessPanel onClose={props.onClose ?? closePanel} />
      )) as unknown as (props: never) => unknown,
    ),
  )

  // ③ 插件页兜底入口：面板万一打不开时仍有一条路
  ctx.slots.inject('plugins.item', () =>
    ctx.slots.register(
      {
        name: 'plugins.item',
        id: 'mobile-access-next',
        order: 60,
        label: () => PANEL_LABEL,
      },
      (() => <MobileAccessRow onOpen={openPanel} />) as unknown as (props: never) => unknown,
    ),
  )
}
