/**
 * 配置解析。
 *
 * 三个文件分工（与参考实现一致，便于将来迁移）：
 * - `setup.json`   —— 网络配置（网卡、端口、TLS 路径）。**持久化**。
 * - `control.json` —— 启停开关。**持久化**，面板可改。
 * - `devices.json` —— 已配对设备（只存令牌摘要）。由 access 层管理。
 *
 * 设计取舍：配置全部走文件而不是环境变量，因为用户要在面板里改，
 * 且改完需要跨重启生效。
 */

import { readFile } from 'node:fs/promises'
import { dirname } from 'node:path'

/** TLS 模式。 */
export type TlsMode = 'disabled' | 'managed'

/** 插件配置（来自 cordis.patch.yml）。 */
export interface PluginConfig {
  readonly setupFile?: string
  readonly controlFile?: string
  readonly stateFile?: string
  readonly initiallyEnabled?: boolean
  readonly listenHost?: string
  readonly listenPort?: number
  readonly allowedCidrs?: readonly string[]
  readonly tls?: {
    readonly mode?: TlsMode
  }
}

/** 网络配置（setup.json 的结构）。 */
export interface SetupFile {
  readonly version: 1
  /** 选定的网卡名，例如 `en0`。未选定时为 undefined。 */
  readonly networkInterface?: string
  /** 局域网监听端口。 */
  readonly listenPort: number
  /** TLS 模式。 */
  readonly tlsMode: TlsMode
  /** 证书目录（managed 模式下由插件生成）。 */
  readonly tlsDirectory?: string
}

/** 启停状态（control.json）。 */
export interface ControlFile {
  readonly version: 1
  readonly enabled: boolean
}

/** 解析后的运行时配置。 */
export interface ResolvedConfig {
  readonly setupFile: string | undefined
  readonly controlFile: string | undefined
  readonly stateFile: string | undefined
  readonly initiallyEnabled: boolean
  readonly listenHost: string
  readonly listenPort: number
  readonly allowedCidrs: readonly string[]
  readonly tlsMode: TlsMode
}

const DEFAULT_LISTEN_PORT = 3444
const DEFAULT_LISTEN_HOST = '0.0.0.0'

/**
 * 解析插件配置。
 *
 * 原则：**不做激进校验**。非法值退回默认并记录，而不是抛错 ——
 * 配置错误不该让整个 DSH 起不来。
 */
export function resolveConfig(config: PluginConfig): ResolvedConfig {
  const port = config.listenPort
  const listenPort =
    typeof port === 'number' && Number.isSafeInteger(port) && port > 0 && port < 65536
      ? port
      : DEFAULT_LISTEN_PORT

  const mode = config.tls?.mode
  const tlsMode: TlsMode = mode === 'disabled' || mode === 'managed' ? mode : 'managed'

  return {
    setupFile: config.setupFile,
    controlFile: config.controlFile,
    stateFile: config.stateFile,
    initiallyEnabled: config.initiallyEnabled === true,
    listenHost: config.listenHost ?? DEFAULT_LISTEN_HOST,
    listenPort,
    allowedCidrs: config.allowedCidrs ?? ['127.0.0.0/8'],
    tlsMode,
  }
}

/** 读取 JSON 文件；不存在或损坏时返回 undefined。 */
async function readJsonFile(path: string | undefined): Promise<unknown> {
  if (path === undefined) return undefined
  try {
    const raw = await readFile(path, 'utf8')
    return JSON.parse(raw) as unknown
  } catch {
    // 不存在 / 权限 / 语法错误都视为"没有配置"，走默认值。
    return undefined
  }
}

/** 解析 setup.json。 */
export function parseSetupFile(value: unknown, fallbackPort: number): SetupFile {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return { version: 1, listenPort: fallbackPort, tlsMode: 'managed' }
  }
  const record = value as Record<string, unknown>

  const port = record.listenPort
  const listenPort =
    typeof port === 'number' && Number.isSafeInteger(port) && port > 0 && port < 65536
      ? port
      : fallbackPort

  const mode = record.tlsMode
  const tlsMode: TlsMode = mode === 'disabled' || mode === 'managed' ? mode : 'managed'

  const iface = record.networkInterface
  const tlsDirectory = record.tlsDirectory

  return {
    version: 1,
    ...(typeof iface === 'string' && iface !== '' ? { networkInterface: iface } : {}),
    listenPort,
    tlsMode,
    ...(typeof tlsDirectory === 'string' && tlsDirectory !== '' ? { tlsDirectory } : {}),
  }
}

/** 解析 control.json。 */
export function parseControlFile(value: unknown, initiallyEnabled: boolean): ControlFile {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return { version: 1, enabled: initiallyEnabled }
  }
  const record = value as Record<string, unknown>
  return {
    version: 1,
    enabled: record.enabled === true,
  }
}

/** 读取并解析 setup / control。 */
export async function loadPersistedState(config: ResolvedConfig): Promise<{
  readonly setup: SetupFile
  readonly control: ControlFile
}> {
  const [rawSetup, rawControl] = await Promise.all([
    readJsonFile(config.setupFile),
    readJsonFile(config.controlFile),
  ])
  return {
    setup: parseSetupFile(rawSetup, config.listenPort),
    control: parseControlFile(rawControl, config.initiallyEnabled),
  }
}

/** 状态目录（用于放 TLS 证书等派生文件）。 */
export function stateDirectoryOf(config: ResolvedConfig): string | undefined {
  const anchor = config.setupFile ?? config.controlFile ?? config.stateFile
  if (anchor === undefined) return undefined
  return dirname(anchor)
}
