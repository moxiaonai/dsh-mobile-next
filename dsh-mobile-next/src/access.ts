/**
 * 设备配对与鉴权。
 *
 * ## 威胁模型
 *
 * 局域网里可能有其他设备。网关暴露后，任何能连上 `https://<ip>:3444` 的人
 * 都能看到 DSH 界面 —— 除非有认证。本模块提供：
 *
 * 1. **一次性配对令牌**：电脑端生成，短有效期（默认 5 分钟），
 *    手机扫码后用它换长期设备令牌。
 * 2. **设备令牌**：长期有效，存手机 Keystore；服务端**只存摘要**。
 * 3. **会话 Cookie**：短有效期（默认 12 小时），每次请求携带。
 *
 * ## 为什么只存摘要
 *
 * 参考实现的做法（`access.ts`）：`tokenDigest: digestHex(deviceToken)`。
 * 好处是**磁盘泄露不等于凭据泄露** —— 攻击者拿到 devices.json 也无法
 * 反推出可用的令牌。
 *
 * ## 与参考实现的差异
 *
 * 参考实现用 `exclusive()` 串行化所有 mutation，并用 `BoundedRateLimiter`
 * 限制暴力尝试。这里保留同样的语义，但实现更小（前期只做局域网）。
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { dirname } from 'node:path'

/** 错误分类。对外只回一个简短 code，不泄露细节。 */
export class AccessError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code)
    this.name = 'AccessError'
  }
}

/** 持久化的设备记录（只含摘要）。 */
interface StoredDevice {
  readonly deviceId: string
  /** deviceToken 的 SHA-256 十六进制。 */
  readonly tokenDigest: string
  readonly label: string
  readonly createdAt: number
  readonly expiresAt: number
  readonly lastSeenAt: number
}

interface DeviceSnapshot {
  readonly version: 1
  readonly devices: readonly StoredDevice[]
}

/** 配对结果（返回给手机，只此一次）。 */
export interface PairingResult {
  readonly deviceId: string
  readonly deviceToken: string
  readonly deviceExpiresAt: number
  readonly sessionToken: string
  /**
   * CSRF 令牌。
   *
   * 目前网关用 `SameSite=Strict` + 精确 Origin 校验代替 CSRF token，
   * 但原生客户端按参考实现的契约会读这个字段，因此仍然返回（随机值）。
   * 将来若加写操作 CSRF 校验，这里就是校验值。
   */
  readonly csrfToken: string
  readonly sessionExpiresAt: number
  /** 电脑的安装标识，用于客户端区分不同电脑。 */
  readonly instanceId?: string
}

/** 会话记录（内存，不落盘）。 */
interface SessionRecord {
  readonly key: string
  readonly deviceId: string
  readonly createdAt: number
  readonly expiresAt: number
}

/** 授权信息。 */
export interface SessionAuthorization {
  readonly deviceId: string
  readonly sessionKey: string
}

/** 配置。 */
export interface AccessOptions {
  /** 配对令牌有效期（毫秒）。 */
  readonly pairingTtlMs?: number
  /** 设备令牌有效期（毫秒）。 */
  readonly deviceTtlMs?: number
  /** 会话有效期（毫秒）。 */
  readonly sessionTtlMs?: number
  /** 最大设备数。 */
  readonly maxDevices?: number
  /** 每分钟最大配对尝试次数（按来源 IP）。 */
  readonly maxPairingAttempts?: number
  readonly now?: () => number
}

const DEFAULTS = {
  pairingTtlMs: 5 * 60_000,
  deviceTtlMs: 90 * 24 * 3_600_000,
  sessionTtlMs: 12 * 3_600_000,
  maxDevices: 16,
  maxPairingAttempts: 10,
} as const

function digestHex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex')
}

function digest(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest()
}

function opaqueToken(): string {
  return randomBytes(32).toString('base64url')
}

function matchesDigest(value: string, expected: string): boolean {
  const a = digest(value)
  const b = Buffer.from(expected, 'hex')
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/** 简单的按来源限流。 */
class RateLimiter {
  #buckets = new Map<string, { count: number; resetAt: number }>()
  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
  ) {}

  take(key: string, now: number): boolean {
    const existing = this.#buckets.get(key)
    if (existing === undefined || existing.resetAt <= now) {
      this.#buckets.set(key, { count: 1, resetAt: now + this.windowMs })
      return true
    }
    if (existing.count >= this.limit) return false
    existing.count += 1
    return true
  }
}

/**
 * 配对与鉴权状态机。
 *
 * 生命周期：`initialize()` → 若干次 `openPairing()`/`pair()`/`authorize()` → `close()`
 */
export class AccessController {
  readonly #now: () => number
  readonly #options: Required<Omit<AccessOptions, 'now'>>
  readonly #pairLimiter: RateLimiter
  readonly #storeFile: string | undefined

  #devices: StoredDevice[] = []
  #instanceId: string | undefined
  #sessions = new Map<string, SessionRecord>()
  #pairingWindow: { digest: string; expiresAt: number } | undefined
  #initialized = false
  #mutation: Promise<void> = Promise.resolve()

  constructor(storeFile: string | undefined, options: AccessOptions = {}) {
    this.#storeFile = storeFile
    this.#now = options.now ?? Date.now
    this.#options = {
      pairingTtlMs: options.pairingTtlMs ?? DEFAULTS.pairingTtlMs,
      deviceTtlMs: options.deviceTtlMs ?? DEFAULTS.deviceTtlMs,
      sessionTtlMs: options.sessionTtlMs ?? DEFAULTS.sessionTtlMs,
      maxDevices: options.maxDevices ?? DEFAULTS.maxDevices,
      maxPairingAttempts: options.maxPairingAttempts ?? DEFAULTS.maxPairingAttempts,
    }
    this.#pairLimiter = new RateLimiter(
      this.#options.maxPairingAttempts,
      60_000,
    )
  }

  /** 加载持久化状态。必须在使用前调用。 */
  async initialize(): Promise<void> {
    if (this.#initialized) throw new Error('already initialized')
    if (this.#storeFile !== undefined) {
      try {
        const raw = await readFile(this.#storeFile, 'utf8')
        const parsed = JSON.parse(raw) as DeviceSnapshot
        if (Array.isArray(parsed.devices)) {
          this.#devices = parsed.devices.filter(
            (d) => typeof d.deviceId === 'string' && typeof d.tokenDigest === 'string',
          )
        }
      } catch {
        // 文件不存在或损坏：从空状态开始，不阻断启动。
      }
    }
    this.#initialized = true
  }

  /** 设置安装标识（由插件在启动时注入）。 */
  setInstanceId(id: string | undefined): void {
    this.#instanceId = id
  }

  #requireReady(): void {
    if (!this.#initialized) throw new AccessError(503, 'not_ready')
  }

  /** 串行化 mutation，避免并发配对互相覆盖。 */
  async #exclusive<T>(operation: () => Promise<T>): Promise<T> {
    const prior = this.#mutation
    let release!: () => void
    this.#mutation = new Promise<void>((resolve) => {
      release = resolve
    })
    await prior
    try {
      return await operation()
    } finally {
      release()
    }
  }

  #snapshot(): DeviceSnapshot {
    return { version: 1, devices: [...this.#devices] }
  }

  async #persist(): Promise<void> {
    if (this.#storeFile === undefined) return
    const dir = dirname(this.#storeFile)
    await mkdir(dir, { recursive: true })
    await writeFile(
      this.#storeFile,
      JSON.stringify(this.#snapshot(), null, 2),
      { encoding: 'utf8', mode: 0o600 },
    )
  }

  /**
   * 开启一个配对窗口，返回一次性令牌。
   *
   * 只应被**电脑本机**调用（回环管理路由），绝不对外暴露。
   */
  async openPairing(requestedTtlMs?: number): Promise<{
    readonly token: string
    readonly expiresAt: number
  }> {
    this.#requireReady()
    return this.#exclusive(async () => {
      const ttl = requestedTtlMs ?? this.#options.pairingTtlMs
      if (!Number.isSafeInteger(ttl) || ttl < 10_000 || ttl > this.#options.pairingTtlMs) {
        throw new AccessError(400, 'invalid_request')
      }
      const token = opaqueToken()
      const expiresAt = this.#now() + ttl
      this.#pairingWindow = { digest: digestHex(token), expiresAt }
      return { token, expiresAt }
    })
  }

  /**
   * 用一次性令牌换设备凭据。
   *
   * @param sourceKey 来源标识（IP），用于限流
   */
  async pair(sourceKey: string, token: string, label?: string): Promise<PairingResult> {
    this.#requireReady()
    const now = this.#now()
    const window = this.#pairingWindow

    // 未知/过期/不匹配的猜测：先限流，再统一报错（不区分原因）
    if (
      typeof token !== 'string' ||
      token.length === 0 ||
      token.length > 512 ||
      window === undefined ||
      window.expiresAt <= now ||
      !matchesDigest(token, window.digest)
    ) {
      if (!this.#pairLimiter.take(sourceKey, now)) {
        throw new AccessError(429, 'rate_limited')
      }
      throw new AccessError(401, 'authentication_failed')
    }

    return this.#exclusive(async () => {
      // 队列内再验一次：并发配对可能已消费该窗口
      const inner = this.#pairingWindow
      const innerNow = this.#now()
      if (
        inner === undefined ||
        inner.expiresAt <= innerNow ||
        !matchesDigest(token, inner.digest)
      ) {
        throw new AccessError(401, 'authentication_failed')
      }
      this.#pairingWindow = undefined

      if (this.#devices.length >= this.#options.maxDevices) {
        throw new AccessError(409, 'too_many_devices')
      }

      const deviceToken = opaqueToken()
      const deviceId = randomBytes(16).toString('hex')
      const expiresAt = innerNow + this.#options.deviceTtlMs

      const record: StoredDevice = {
        deviceId,
        // 只存摘要
        tokenDigest: digestHex(deviceToken),
        label: normalizeLabel(label),
        createdAt: innerNow,
        expiresAt,
        lastSeenAt: innerNow,
      }
      this.#devices.push(record)
      await this.#persist()

      const session = this.#issueSession(deviceId, innerNow, expiresAt)

      return {
        deviceId,
        deviceToken,
        deviceExpiresAt: expiresAt,
        sessionToken: session.token,
        csrfToken: opaqueToken(),
        sessionExpiresAt: session.expiresAt,
        ...(this.#instanceId === undefined ? {} : { instanceId: this.#instanceId }),
      }
    })
  }

  #issueSession(
    deviceId: string,
    now: number,
    deviceExpiresAt: number,
  ): { token: string; expiresAt: number } {
    const token = opaqueToken()
    const expiresAt = Math.min(now + this.#options.sessionTtlMs, deviceExpiresAt)
    this.#sessions.set(digestHex(token), {
      key: digestHex(token),
      deviceId,
      createdAt: now,
      expiresAt,
    })
    return { token, expiresAt }
  }

  /**
   * 用设备令牌换新会话（Host 重启后会话失效，但设备仍有效）。
   */
  async renew(deviceToken: string): Promise<PairingResult> {
    this.#requireReady()
    const now = this.#now()
    return this.#exclusive(async () => {
      const device = this.#devices.find((d) => matchesDigest(deviceToken, d.tokenDigest))
      if (device === undefined || device.expiresAt <= now) {
        throw new AccessError(401, 'authentication_failed')
      }
      const updated: StoredDevice = { ...device, lastSeenAt: now }
      this.#devices = this.#devices.map((d) =>
        d.deviceId === device.deviceId ? updated : d,
      )
      await this.#persist()
      const session = this.#issueSession(device.deviceId, now, device.expiresAt)
      return {
        deviceId: device.deviceId,
        // 续期不换 deviceToken：手机不必更新 Keystore
        deviceToken,
        deviceExpiresAt: device.expiresAt,
        sessionToken: session.token,
        csrfToken: opaqueToken(),
        sessionExpiresAt: session.expiresAt,
        ...(this.#instanceId === undefined ? {} : { instanceId: this.#instanceId }),
      }
    })
  }

  /** 校验会话令牌。返回授权信息或抛错。 */
  authorize(sessionToken: string | undefined): SessionAuthorization {
    this.#requireReady()
    if (typeof sessionToken !== 'string' || sessionToken === '') {
      throw new AccessError(401, 'authentication_failed')
    }
    const key = digestHex(sessionToken)
    const record = this.#sessions.get(key)
    const now = this.#now()
    if (record === undefined || record.expiresAt <= now) {
      // 过期即删除，避免内存堆积
      if (record !== undefined) this.#sessions.delete(key)
      throw new AccessError(401, 'authentication_failed')
    }
    return { deviceId: record.deviceId, sessionKey: key }
  }

  /** 撤销一台设备（同时清掉它的会话）。 */
  async revoke(deviceId: string): Promise<void> {
    this.#requireReady()
    return this.#exclusive(async () => {
      this.#devices = this.#devices.filter((d) => d.deviceId !== deviceId)
      for (const [key, session] of this.#sessions) {
        if (session.deviceId === deviceId) this.#sessions.delete(key)
      }
      await this.#persist()
    })
  }

  /**
   * 撤销**全部**设备（一次事务完成）。
   *
   * 为什么不在客户端循环调 `revoke`：那样是 N 次串行网络请求 + N 次落盘，
   * 中途失败会留下“撤了一半”的状态，而这是个安全操作 —— 半途而废比没做更糟。
   *
   * @returns 被撤销的设备数。
   */
  async revokeAll(): Promise<number> {
    this.#requireReady()
    return this.#exclusive(async () => {
      const removed = this.#devices.length
      this.#devices = []
      this.#sessions.clear()
      await this.#persist()
      return removed
    })
  }

  /** 当前配对窗口（供面板显示倒计时，不含令牌本身）。 */
  pairingStatus(): { readonly open: boolean; readonly expiresAt?: number } {
    const window = this.#pairingWindow
    if (window === undefined || window.expiresAt <= this.#now()) return { open: false }
    return { open: true, expiresAt: window.expiresAt }
  }

  /** 设备列表（不含令牌）。 */
  listDevices(): ReadonlyArray<{
    deviceId: string
    label: string
    createdAt: number
    expiresAt: number
    lastSeenAt: number
  }> {
    return this.#devices.map((d) => ({
      deviceId: d.deviceId,
      label: d.label,
      createdAt: d.createdAt,
      expiresAt: d.expiresAt,
      lastSeenAt: d.lastSeenAt,
    }))
  }

  /** 关闭：清空内存状态。 */
  close(): void {
    this.#sessions.clear()
    this.#pairingWindow = undefined
  }
}

function normalizeLabel(value: string | undefined): string {
  const label = (value ?? 'Mobile device').normalize('NFC').trim()
  if (label.length < 1 || label.length > 64) return 'Mobile device'
  // 去掉控制字符，避免污染日志与界面
  return label.replaceAll(/[\u0000-\u001f\u007f]/gu, '')
}
