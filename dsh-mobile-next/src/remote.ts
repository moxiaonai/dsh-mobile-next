/** iroh transports opaque TLS bytes to an independently authenticated loopback gateway.
 * No downloads, shell commands, TLS bypass, or claims of external verification.
 * Native CLI/NDJSON v1 follows saya-ch/dsh-mobile-iroh (Apache-2.0/MIT).
 */
import { spawn as nodeSpawn } from 'node:child_process'
import type { ChildProcess, SpawnOptions } from 'node:child_process'
import { createHash, randomUUID, X509Certificate } from 'node:crypto'
import { lstat, mkdir, open, readFile, rename, unlink } from 'node:fs/promises'
import { isAbsolute, join, resolve } from 'node:path'
import { isIP } from 'node:net'
import { AccessController, AccessError } from './access.js'

export type RemoteProvider = 'iroh'
export type RemoteState = 'starting' | 'running' | 'stopped' | 'error'
export interface RemoteConfig {
  readonly provider: RemoteProvider
  /** Absolute path to an already installed native host; never command-line arguments. */
  readonly irohPath?: string
  /** Stable phone-side logical port, also used by the dedicated gateway. */
  readonly localPort?: number
}
export interface RemoteStatus extends RemoteConfig {
  readonly state: RemoteState
  readonly enabled: boolean
  readonly origin?: string
  readonly backendOrigin?: string
  readonly endpointId?: string
  readonly verified: false
  /** Fixed safe error code. Never process output, pairing secrets, or exception messages. */
  readonly error?: string
}
export interface RemoteBackendContext {
  readonly endpointId: string
  readonly origin: string
  readonly localPort: number
  readonly tls: { readonly caFile: string; readonly certFile: string; readonly keyFile: string }
  readonly caFingerprint: string
  readonly signal: AbortSignal
}
export type RemoteSpawn = (file: string, args: readonly string[], options: SpawnOptions) => ChildProcess
export interface RemoteOptions {
  readonly stateDirectory?: string
  readonly startBackend: (context: RemoteBackendContext) => Promise<string>
  readonly stopBackend: () => Promise<void>
  /** Independent remote access controller; never share LAN sessions/pairing windows. */
  readonly access?: AccessController
  readonly onOrigin?: (origin: string | undefined) => void | Promise<void>
  readonly spawn?: RemoteSpawn
  readonly startupTimeoutMs?: number
  readonly commandTimeoutMs?: number
  readonly killTimeoutMs?: number
  readonly now?: () => number
  /** Test/operator-only: suppress discovery and relay, never silently enable this in production. */
  readonly localOnly?: boolean
}
export interface IrohPairingDescriptor {
  readonly version: 1
  readonly type: 'dsh-mobile-iroh-pairing'
  readonly endpointId: string
  readonly origin: string
  readonly localPort: number
  readonly irohCode: string
  readonly gatewayToken: string
  /** Canonical base64 DER of public CA, not PEM and never a private key. */
  readonly caCertificate: string
  /** SHA-256 of CA DER; matches the ordinary gateway pairing instance ID. */
  readonly instanceId: string
  readonly expiresAt: number
}
interface TlsMetadata {
  version: 1
  endpointId: string
  hostname: string
  instanceId: string
  caFingerprint256: string
  leafFingerprint256: string
  caValidTo: number
  leafValidTo: number
  tls: RemoteBackendContext['tls']
}
type Event = Record<string, unknown> & { version: 1; type: string }
interface OwnedProcess {
  child: ChildProcess
  closed: boolean
  failed: boolean
  stopping: boolean
  done: Promise<void>
  dispose: () => void
  reject: (error: AccessError) => void
}
const HEX = /^[a-f0-9]{64}$/u
const MAX_LINE = 16 * 1024
const DEFAULT_PORT = 3445
function fault(code: string, status = 502): AccessError { return new AccessError(status, code) }
function exact(value: unknown, fields: readonly string[]): value is Record<string, unknown> {
  return !!value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join(',') === [...fields].sort().join(',')
}
function hex(value: unknown): value is string { return typeof value === 'string' && HEX.test(value) }
function text(value: unknown, max: number): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/u.test(value)
}
export function irohOrigin(endpointId: string, localPort = DEFAULT_PORT): string {
  if (!hex(endpointId) || !Number.isSafeInteger(localPort) || localPort < 1024 || localPort > 65535) throw fault('invalid_iroh_origin', 400)
  return `https://${endpointId.slice(0, 32)}.${endpointId.slice(32)}.iroh.localhost:${localPort}`
}
/** Public browser identity must be exactly the full endpoint and fixed logical port. */
export function validateRemoteOrigin(value: unknown, endpointId: string, localPort = DEFAULT_PORT): string {
  const expected = irohOrigin(endpointId, localPort)
  if (value !== expected) throw fault('invalid_iroh_origin', 400)
  return expected
}
/** Native sidecar proxies bytes, not URLs. Only literal 127.0.0.1 / ::1 HTTPS upstream. */
export function validateBackendOrigin(value: unknown): string {
  if (typeof value !== 'string' || !/^https:\/\/(?:127\.0\.0\.1|\[::1\])(?::[0-9]+)?\/?$/u.test(value)) throw fault('invalid_backend_origin', 400)
  let url: URL
  try { url = new URL(value) } catch { throw fault('invalid_backend_origin', 400) }
  return url.origin
}
function parseConfig(input: unknown): RemoteConfig {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw fault('invalid_remote_config', 400)
  const value = input as Record<string, unknown>
  if (Object.keys(value).some(key => !['provider', 'irohPath', 'localPort'].includes(key)) || value.provider !== 'iroh') throw fault('invalid_remote_provider', 400)
  if (value.irohPath !== undefined && (!text(value.irohPath, 4096) || !isAbsolute(value.irohPath))) throw fault('invalid_iroh_path', 400)
  const localPort = value.localPort ?? DEFAULT_PORT
  if (!Number.isSafeInteger(localPort) || (localPort as number) < 1024 || (localPort as number) > 65535) throw fault('invalid_iroh_port', 400)
  return { provider: 'iroh', ...(value.irohPath ? { irohPath: value.irohPath as string } : {}), localPort: localPort as number }
}
function directAddress(value: unknown): boolean {
  if (!text(value, 128)) return false
  try {
    const url = new URL(`http://${value}`)
    return isIP(url.hostname.replace(/^\[|\]$/gu, '')) !== 0 && url.port !== '' &&
      url.pathname === '/' && !url.username && !url.password && !url.search && !url.hash
  } catch { return false }
}
function decodeEvent(line: Buffer): Event {
  let event: unknown
  try { event = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line)) } catch { throw fault('iroh_protocol_error') }
  const value = event as Event
  const fields = ({ ready: ['endpoint_id', 'direct_addresses', 'local_only'], pairing: ['code', 'expires_in_sec'],
    'pairing-closed': ['reason'], 'pairing-done': ['peer', 'name'], 'peer-connected': ['peer', 'name'],
    'peer-path': ['peer', 'kind', 'remote'], 'peer-disconnected': ['peer'], 'proxy-opened': ['peer'],
    devices: ['devices'], error: ['code', 'message'], stopped: [] } as Record<string, string[]>)[value?.type]
  if (!fields || !exact(value, ['version', 'type', ...fields]) || value.version !== 1) throw fault('iroh_protocol_error')
  if ('peer' in value && !hex(value.peer) || 'name' in value && !text(value.name, 128)) throw fault('iroh_protocol_error')
  if (value.type === 'ready') {
    if (!hex(value.endpoint_id) || typeof value.local_only !== 'boolean' || !Array.isArray(value.direct_addresses) ||
      value.direct_addresses.length > 64 || !value.direct_addresses.every(directAddress)) throw fault('iroh_protocol_error')
  } else if (value.type === 'pairing') {
    if (typeof value.code !== 'string' || !/^\d{6}$/u.test(value.code) || !Number.isSafeInteger(value.expires_in_sec) ||
      (value.expires_in_sec as number) < 1 || (value.expires_in_sec as number) > 3600) throw fault('iroh_protocol_error')
  } else if (value.type === 'devices') {
    if (!Array.isArray(value.devices) || value.devices.length > 256 || !value.devices.every(device =>
      exact(device, ['id', 'name', 'paired_at', 'online']) && hex(device.id) && text(device.name, 128) &&
      text(device.paired_at, 64) && typeof device.online === 'boolean')) throw fault('iroh_protocol_error')
  } else if (value.type === 'error' && (!text(value.code, 128) || !text(value.message, 1024)) ||
    value.type === 'pairing-closed' && !text(value.reason, 128) || value.type === 'peer-path' &&
    (!['direct', 'relay'].includes(value.kind as string) || !text(value.remote, 512))) throw fault('iroh_protocol_error')
  return value
}

export class RemoteController {
  #config: RemoteConfig = { provider: 'iroh', localPort: DEFAULT_PORT }
  #state: RemoteState = 'stopped'
  #enabled = false
  #origin: string | undefined
  #backendOrigin: string | undefined
  #metadata: TlsMetadata | undefined
  #error: string | undefined
  #initialized = false
  #closed = false
  #backendActive = false
  #backendPending = false
  #process: OwnedProcess | undefined
  #queue: Promise<unknown> = Promise.resolve()
  #abort: AbortController | undefined
  #listeners = new Set<(event: Event) => void>()
  readonly #startupTimeout: number
  readonly #commandTimeout: number
  readonly #killTimeout: number
  readonly #now: () => number
  constructor(private readonly options: RemoteOptions) {
    this.#startupTimeout = options.startupTimeoutMs ?? 30_000
    this.#commandTimeout = options.commandTimeoutMs ?? 5_000
    this.#killTimeout = options.killTimeoutMs ?? 2_000
    this.#now = options.now ?? Date.now
    for (const n of [this.#startupTimeout, this.#commandTimeout, this.#killTimeout]) {
      if (!Number.isSafeInteger(n) || n < 1 || n > 300_000) throw fault('invalid_remote_timeout', 400)
    }
  }
  get config(): RemoteConfig { return { ...this.#config } }
  status(): RemoteStatus {
    return { ...this.#config, state: this.#state, enabled: this.#enabled, verified: false,
      ...(this.#origin ? { origin: this.#origin } : {}), ...(this.#backendOrigin ? { backendOrigin: this.#backendOrigin } : {}),
      ...(this.#state === 'running' && this.#metadata ? { endpointId: this.#metadata.endpointId } : {}),
      ...(this.#error ? { error: this.#error } : {}) }
  }
  #exclusive<T>(action: () => Promise<T>): Promise<T> {
    const task = this.#queue.then(action, action); this.#queue = task.catch(() => {}); return task
  }
  #assertReady(): void {
    if (this.#closed) throw fault('remote_closed', 409)
    if (!this.#initialized) throw fault('remote_not_initialized', 409)
  }
  initialize(): Promise<void> {
    return this.#exclusive(async () => {
      if (this.#closed) throw fault('remote_closed', 409)
      if (this.#initialized) return
      if (this.options.stateDirectory) {
        const file = join(this.options.stateDirectory, 'remote.json')
        try {
          const info = await lstat(file)
          if (!info.isFile() || info.isSymbolicLink() || info.size > 8192 ||
            process.platform !== 'win32' && ((info.mode & 0o777) !== 0o600 ||
              typeof process.getuid === 'function' && info.uid !== process.getuid())) throw fault('remote_config_load_failed')
          const snapshot: unknown = JSON.parse(await readFile(file, 'utf8'))
          if (!exact(snapshot, ['version', 'config']) || snapshot.version !== 1) throw fault('remote_config_load_failed')
          this.#config = parseConfig(snapshot.config)
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
            this.#state = 'error'; this.#error = 'remote_config_load_failed'
            this.#config = { provider: 'iroh', localPort: DEFAULT_PORT }
          }
        }
      }
      this.#initialized = true // Saved configuration NEVER automatically starts a transport.
    })
  }
  configure(input: RemoteConfig): Promise<RemoteStatus> {
    return this.#exclusive(async () => {
      this.#assertReady()
      if (this.#enabled || this.#process || this.#backendActive || this.#backendPending) throw fault('remote_must_be_stopped', 409)
      const next = parseConfig(input); await this.#persist(next); this.#config = next
      this.#state = 'stopped'; this.#error = undefined; return this.status()
    })
  }
  async #persist(config: RemoteConfig): Promise<void> {
    const directory = this.options.stateDirectory
    if (!directory) return
    const temporary = join(directory, `.remote-${randomUUID()}.tmp`)
    try {
      await mkdir(directory, { recursive: true, mode: 0o700 })
      const file = await open(temporary, 'wx', 0o600)
      try { await file.writeFile(JSON.stringify({ version: 1, config }) + '\n'); await file.sync() } finally { await file.close() }
      await rename(temporary, join(directory, 'remote.json'))
    } catch { throw fault('remote_config_save_failed', 500) }
    finally { await unlink(temporary).catch(() => {}) }
  }
  /** Bound every awaited startup phase; late gateway results are retired, never published. */
  async #bounded<T>(task: Promise<T>, signal: AbortSignal): Promise<T> {
    let abort!: () => void
    const cancelled = new Promise<never>((_, reject) => {
      abort = () => reject(fault(signal.reason === 'timeout' ? 'iroh_start_timeout' : 'remote_cancelled'))
      signal.addEventListener('abort', abort, { once: true }); if (signal.aborted) abort()
    })
    try { return await Promise.race([task, cancelled]) } finally { signal.removeEventListener('abort', abort) }
  }
  start(): Promise<RemoteStatus> {
    return this.#exclusive(async () => {
      this.#assertReady()
      if (this.#state === 'running') return this.status()
      if (this.#process || this.#backendActive || this.#backendPending) throw fault('remote_cleanup_required', 409)
      this.#enabled = true; this.#state = 'starting'; this.#error = undefined; this.#origin = undefined
      const abort = this.#abort = new AbortController()
      const timer = setTimeout(() => abort.abort('timeout'), this.#startupTimeout)
      try {
        await this.#bounded(Promise.resolve(this.options.onOrigin?.(undefined)), abort.signal)
        if (!this.#config.irohPath) throw fault('iroh_component_missing', 409)
        if (!this.options.stateDirectory) throw fault('iroh_state_directory_required', 409)
        const directory = join(resolve(this.options.stateDirectory), 'iroh')
        await this.#bounded(mkdir(directory, { recursive: true, mode: 0o700 }), abort.signal)
        this.#metadata = await this.#prepareTls(directory, abort.signal)
        const origin = irohOrigin(this.#metadata.endpointId, this.#config.localPort)
        this.#backendActive = true; this.#backendPending = true
        const backend = Promise.resolve().then(() => {
          if (abort.signal.aborted) throw fault('remote_cancelled')
          return this.options.startBackend({ endpointId: this.#metadata!.endpointId, origin,
            localPort: this.#config.localPort!, tls: this.#metadata!.tls,
            caFingerprint: this.#metadata!.caFingerprint256.match(/../gu)!.join(':').toUpperCase(), signal: abort.signal })
        })
        void backend.then(async () => {
          this.#backendPending = false
          if (abort.signal.aborted) {
            try { await this.options.stopBackend(); this.#backendActive = false; this.#backendOrigin = undefined }
            catch { this.#error = 'remote_backend_cleanup_failed' }
          }
        }, () => { this.#backendPending = false })
        this.#backendOrigin = validateBackendOrigin(await this.#bounded(backend, abort.signal))
        const target = new URL(this.#backendOrigin)
        if (Number(target.port || 443) !== this.#config.localPort) throw fault('iroh_backend_port_mismatch')
        await this.#host(directory, `${target.hostname}:${target.port || 443}`, abort.signal)
        await this.#bounded(Promise.resolve(this.options.onOrigin?.(origin)), abort.signal)
        if (this.#unhealthy()) throw fault('iroh_process_exited')
        this.#origin = origin; this.#state = 'running'; return this.status()
      } catch (error) {
        abort.abort('failed')
        this.#error = error instanceof AccessError ? error.code : 'iroh_start_failed'
        try { await this.#cleanup() } catch (cleanup) { this.#error = cleanup instanceof AccessError ? cleanup.code : 'remote_cleanup_failed' }
        this.#state = 'error'; throw fault(this.#error!)
      } finally { clearTimeout(timer); if (this.#abort === abort) this.#abort = undefined }
    })
  }
  #unhealthy(): boolean { return this.#process?.closed === true || this.#process?.failed === true }
  #spawn(args: string[], data: (chunk: Buffer) => void, closed: (code: number | null) => void,
    failure: (error: AccessError) => void, host = false): OwnedProcess {
    let child: ChildProcess
    try { child = (this.options.spawn ?? ((file, argv, options) => nodeSpawn(file, [...argv], options)))(
      this.#config.irohPath!, args, { shell: false, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true }) }
    catch { throw fault('iroh_spawn_failed') }
    let resolveDone!: () => void
    const done = new Promise<void>(resolve => { resolveDone = resolve })
    const record: OwnedProcess = { child, done, closed: false, failed: false, stopping: false, reject: failure, dispose: () => {
      child.stdout?.off('data', onData); child.stdout?.off('error', onError)
      child.stderr?.off('error', onError); child.stdin?.off('error', onError)
      child.off('error', onError); child.off('close', onClose); child.off('exit', onExit)
    } }
    const failRuntime = (code: string) => {
      record.failed = true; failure(fault(code))
      if (host && !record.stopping && this.#state === 'running') {
        // Remove advertised authority immediately, then serialize resource retirement.
        this.#origin = undefined; this.#state = 'error'; this.#error = code
        void this.#exclusive(async () => {
          if (this.#process !== record) return
          try { await this.#cleanup() } catch (error) { this.#error = error instanceof AccessError ? error.code : 'remote_cleanup_failed' }
        })
      }
    }
    const onData = (chunk: Buffer | string) => {
      if (record.failed) return
      try { data(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)) } catch { failRuntime('iroh_protocol_error') }
    }
    const onError = () => failRuntime('iroh_process_error')
    const onExit = () => { if (host) failRuntime('iroh_process_exited') }
    const onClose = (code: number | null) => {
      if (record.closed) return
      record.closed = true; resolveDone(); closed(code)
      if (host) failRuntime('iroh_process_exited')
    }
    this.#process = record
    child.stdout?.on('data', onData); child.stdout?.on('error', onError)
    child.stdin?.on('error', onError); child.stderr?.on('error', onError); child.stderr?.resume()
    child.on('error', onError); child.on('exit', onExit); child.on('close', onClose)
    return record
  }
  async #prepareTls(directory: string, signal: AbortSignal): Promise<TlsMetadata> {
    let output = Buffer.alloc(0)
    let record!: OwnedProcess
    const result = new Promise<TlsMetadata>((resolveResult, reject) => {
      record = this.#spawn(['--lang', 'en', 'tls-prepare', '--data-dir', directory,
        '--leaf-validity-days', '90', '--renew-before-days', '30'], chunk => {
        if (output.length + chunk.length > 8192) throw fault('iroh_protocol_error')
        output = Buffer.concat([output, chunk])
      }, code => {
        try {
          if (code !== 0 || record.failed) throw fault('iroh_identity_failed')
          const raw = new TextDecoder('utf-8', { fatal: true }).decode(output)
          const metadata: unknown = JSON.parse(raw)
          if (!exact(metadata, ['version', 'endpointId', 'hostname', 'instanceId', 'caFingerprint256',
            'leafFingerprint256', 'caValidTo', 'leafValidTo', 'tls']) || metadata.version !== 1 ||
            !hex(metadata.endpointId) || metadata.hostname !== new URL(irohOrigin(metadata.endpointId)).hostname ||
            !hex(metadata.caFingerprint256) || metadata.instanceId !== metadata.caFingerprint256 || !hex(metadata.leafFingerprint256) ||
            !Number.isSafeInteger(metadata.caValidTo) || !Number.isSafeInteger(metadata.leafValidTo) ||
            (metadata.leafValidTo as number) <= this.#now() || (metadata.leafValidTo as number) > (metadata.caValidTo as number) ||
            !exact(metadata.tls, ['caFile', 'certFile', 'keyFile']) || metadata.tls.caFile !== join(directory, 'tls', 'ca.pem') ||
            metadata.tls.certFile !== join(directory, 'tls', 'server.pem') || metadata.tls.keyFile !== join(directory, 'tls', 'server-key.pem')) throw fault('iroh_identity_invalid')
          resolveResult(metadata as unknown as TlsMetadata)
        } catch { reject(fault('iroh_identity_invalid')) }
      }, reject)
    })
    const metadata = await this.#bounded(result, signal)
    record.dispose(); if (this.#process === record) this.#process = undefined
    return metadata
  }
  async #host(directory: string, socket: string, signal: AbortSignal): Promise<void> {
    let pending = Buffer.alloc(0)
    let gotReady = false
    const ready = new Promise<void>((resolveReady, reject) => {
      this.#spawn(['--lang', 'en', 'host', '--data-dir', directory, '--proxy-target', socket,
        ...(this.options.localOnly ? ['--local-only'] : [])], chunk => {
        let offset = 0
        while (offset < chunk.length) {
          const newline = chunk.indexOf(10, offset)
          const end = newline < 0 ? chunk.length : newline
          if (pending.length + end - offset > MAX_LINE) throw fault('iroh_protocol_error')
          pending = Buffer.concat([pending, chunk.subarray(offset, end)])
          if (newline < 0) return
          const event = decodeEvent(pending); pending = Buffer.alloc(0); offset = newline + 1
          if (event.type === 'error' || event.type === 'stopped') throw fault('iroh_process_error')
          if (event.type === 'ready') {
            if (gotReady || event.endpoint_id !== this.#metadata?.endpointId || event.local_only !== (this.options.localOnly ?? false)) throw fault('iroh_protocol_error')
            gotReady = true; resolveReady()
          }
          for (const listener of this.#listeners) listener(event)
        }
      }, () => reject(fault(pending.length ? 'iroh_protocol_error' : 'iroh_process_exited')), reject, true)
    })
    await this.#bounded(ready, signal)
  }
  #send(type: 'device-list' | 'pairing-begin' | 'shutdown'): void {
    const record = this.#process
    if (!record || record.closed || record.failed || !record.child.stdin || record.child.stdin.destroyed) throw fault('iroh_not_ready', 409)
    const encoded = JSON.stringify({ version: 1, type }) + '\n'
    if (record.child.stdin.writableLength > 64 * 1024) throw fault('iroh_command_buffer_full')
    record.child.stdin.write(encoded)
  }
  async #event(type: string, command: 'device-list' | 'pairing-begin'): Promise<Event> {
    let timer: ReturnType<typeof setTimeout> | undefined
    let listener!: (event: Event) => void
    const result = new Promise<Event>((resolveEvent, reject) => {
      listener = event => { if (event.type === type) resolveEvent(event) }
      this.#listeners.add(listener)
      timer = setTimeout(() => reject(fault('iroh_command_timeout')), this.#commandTimeout)
      try { this.#send(command) } catch (error) { reject(error) }
    })
    try { return await result } finally { clearTimeout(timer); this.#listeners.delete(listener) }
  }
  /** Only authenticated desktop admin may call this; secrets are never cached in status/config. */
  openPairing(): Promise<{ descriptor: IrohPairingDescriptor; qrPayload: string }> {
    return this.#exclusive(async () => {
      this.#assertReady()
      if (this.#state !== 'running' || !this.#origin || !this.#metadata || !this.options.access) throw fault('iroh_not_ready', 409)
      try {
        // FIFO barrier drains any startup pairing before asking for a fresh one.
        await this.#event('devices', 'device-list')
        const requestedAt = this.#now()
        const pairing = await this.#event('pairing', 'pairing-begin')
        const nativeDeadline = requestedAt + (pairing.expires_in_sec as number) * 1000
        const gatewayTtl = Math.min(300_000, nativeDeadline - this.#now())
        if (gatewayTtl < 10_000) throw fault('iroh_pairing_expiry_too_short')
        const gateway = await this.options.access.openPairing(gatewayTtl)
        if (this.#state !== 'running' || !this.#origin || this.#closed) throw fault('remote_cancelled')
        const expiresAt = Math.min(gateway.expiresAt, requestedAt + (pairing.expires_in_sec as number) * 1000, requestedAt + 600_000)
        const ca = new X509Certificate(await readFile(this.#metadata.tls.caFile))
        if (!ca.ca || ca.subject !== ca.issuer || !ca.verify(ca.publicKey) ||
          Date.parse(ca.validFrom) > this.#now() || Date.parse(ca.validTo) < expiresAt ||
          createHash('sha256').update(ca.raw).digest('hex') !== this.#metadata.caFingerprint256) throw fault('iroh_pairing_ca_invalid')
        const descriptor: IrohPairingDescriptor = { version: 1, type: 'dsh-mobile-iroh-pairing',
          endpointId: this.#metadata.endpointId, origin: this.#origin, localPort: this.#config.localPort!,
          irohCode: pairing.code as string, gatewayToken: gateway.token, caCertificate: ca.raw.toString('base64'),
          instanceId: this.#metadata.caFingerprint256, expiresAt }
        const qrPayload = JSON.stringify(descriptor)
        if (ca.raw.length > 1536 || Buffer.byteLength(qrPayload) > 2200 || expiresAt <= this.#now()) throw fault('iroh_pairing_invalid')
        return { descriptor, qrPayload }
      } catch (error) {
        // Uncertain FIFO response cannot be replayed into another operation. Retire the channel.
        this.#origin = undefined; this.#error = error instanceof AccessError ? error.code : 'iroh_pairing_failed'
        try { await this.#cleanup() } catch { this.#error = 'remote_cleanup_failed' }
        this.#state = 'error'; throw fault(this.#error!)
      }
    })
  }
  async #wait(record: OwnedProcess): Promise<boolean> {
    if (record.closed) return true
    let timer: ReturnType<typeof setTimeout> | undefined
    try { return await Promise.race([record.done.then(() => true), new Promise<boolean>(resolveWait => {
      timer = setTimeout(() => resolveWait(false), this.#killTimeout)
    })]) } finally { clearTimeout(timer) }
  }
  async #cleanup(): Promise<void> {
    this.#origin = undefined
    let failed: string | undefined
    try {
      await this.#boundedCleanup(Promise.resolve(this.options.onOrigin?.(undefined)))
    } catch { failed = 'remote_origin_cleanup_failed' }
    const record = this.#process
    if (record) {
      record.stopping = true
      if (!record.closed) {
        record.reject(fault('remote_cancelled'))
        if (this.#state !== 'starting') { try { this.#send('shutdown') } catch { /* continue to signals */ } }
        try { record.child.kill('SIGTERM') } catch { /* close is authoritative */ }
        if (!await this.#wait(record)) {
          try { record.child.kill('SIGKILL') } catch { /* close is authoritative */ }
          if (!await this.#wait(record)) failed = 'remote_kill_timeout'
        }
      }
      if (record.closed) { record.dispose(); this.#process = undefined }
    }
    if (this.#backendActive) {
      try {
        await this.#boundedCleanup(this.options.stopBackend())
        if (!this.#backendPending) this.#backendActive = false
        this.#backendOrigin = undefined
      } catch { failed ??= 'remote_backend_cleanup_failed' }
    }
    if (failed) throw fault(failed)
  }
  async #boundedCleanup(task: Promise<unknown>): Promise<void> {
    let timer: ReturnType<typeof setTimeout> | undefined
    try { await Promise.race([task, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(fault('remote_cleanup_timeout')), this.#killTimeout)
    })]) } finally { clearTimeout(timer) }
  }
  stop(): Promise<RemoteStatus> {
    this.#abort?.abort('stop')
    return this.#exclusive(async () => {
      this.#assertReady(); this.#enabled = false
      try { await this.#cleanup(); this.#state = 'stopped'; this.#error = undefined }
      catch (error) { this.#state = 'error'; this.#error = error instanceof AccessError ? error.code : 'remote_cleanup_failed'; throw error }
      return this.status()
    })
  }
  close(): Promise<void> {
    this.#closed = true; this.#abort?.abort('close'); this.#origin = undefined
    return this.#exclusive(async () => {
      this.#enabled = false
      try { await this.#cleanup(); this.#state = 'stopped'; this.#error = undefined }
      catch (error) { this.#state = 'error'; this.#error = error instanceof AccessError ? error.code : 'remote_cleanup_failed'; throw error }
    })
  }
}
