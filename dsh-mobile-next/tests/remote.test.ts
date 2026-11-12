import { EventEmitter } from 'node:events'
import type { ChildProcess } from 'node:child_process'
import { PassThrough } from 'node:stream'
import { chmod, mkdtemp, readFile, stat, writeFile, rm, mkdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { createHash, X509Certificate } from 'node:crypto'
import forge from 'node-forge'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { RemoteController, irohOrigin, validateRemoteOrigin, validateBackendOrigin } from '../src/remote.js'
import type { RemoteOptions, RemoteSpawn, RemoteBackendContext } from '../src/remote.js'
import { AccessController } from '../src/access.js'

const ID = 'a'.repeat(64)
const controllers: RemoteController[] = []
const directories: string[] = []
const children: FakeProcess[] = []
class FakeProcess extends EventEmitter {
  stdin = new PassThrough()
  stdout = new PassThrough()
  stderr = new PassThrough()
  pid: number | undefined = 42
  signals: string[] = []
  ignoreTerm = false
  ignoreKill = false
  kill(signal: string) {
    this.signals.push(signal)
    if (!(signal === 'SIGTERM' ? this.ignoreTerm : this.ignoreKill)) this.finish(null, signal)
    return true
  }
  finish(code: number | null = 0, signal: string | null = null) { this.emit('exit', code, signal); this.emit('close', code, signal) }
  event(event: object) { this.stdout.write(JSON.stringify({ version: 1, ...event }) + '\n') }
}
afterEach(async () => {
  for (const child of children.splice(0)) { child.ignoreKill = false; child.ignoreTerm = false; child.finish() }
  for (const remote of controllers.splice(0)) await remote.close().catch(() => {})
  for (const directory of directories.splice(0)) {
    expect(resolve(directory)).toBe(directory)
    expect(directory.startsWith(join(tmpdir(), 'dsh-iroh-test-'))).toBe(true)
    await rm(directory, { recursive: true, force: true })
  }
})
async function setup(options: Partial<RemoteOptions> = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-iroh-test-')); directories.push(directory)
  const processList: FakeProcess[] = []
  const spawn = vi.fn<RemoteSpawn>(() => {
    const child = new FakeProcess(); processList.push(child); children.push(child)
    return child as unknown as ChildProcess
  })
  const startBackend = vi.fn(async (_context: RemoteBackendContext) => 'https://127.0.0.1:3445')
  const stopBackend = vi.fn(async () => {})
  const onOrigin = vi.fn(async (_origin: string | undefined) => {})
  const remote = new RemoteController({ stateDirectory: directory, startBackend, stopBackend, onOrigin, spawn,
    startupTimeoutMs: 500, commandTimeoutMs: 50, killTimeoutMs: 10, ...options })
  controllers.push(remote); await remote.initialize()
  await remote.configure({ provider: 'iroh', irohPath: '/installed/dsh-mobile-iroh-host' })
  return { remote, directory, processList, spawn, startBackend, stopBackend, onOrigin }
}
function metadata(directory: string, caFingerprint = 'b'.repeat(64)) {
  return { version: 1, endpointId: ID, hostname: new URL(irohOrigin(ID)).hostname,
    instanceId: caFingerprint, caFingerprint256: caFingerprint, leafFingerprint256: 'c'.repeat(64),
    caValidTo: Date.now() + 100_000_000, leafValidTo: Date.now() + 90_000_000,
    tls: { caFile: join(directory, 'iroh/tls/ca.pem'), certFile: join(directory, 'iroh/tls/server.pem'), keyFile: join(directory, 'iroh/tls/server-key.pem') } }
}
async function tlsReady(context: Awaited<ReturnType<typeof setup>>, changes = {}) {
  await vi.waitFor(() => expect(context.spawn).toHaveBeenCalledTimes(1), { interval: 1 })
  const tls = context.processList[0]!
  tls.stdout.write(JSON.stringify({ ...metadata(context.directory), ...changes }) + '\n')
  tls.finish()
}
async function hostReady(context: Awaited<ReturnType<typeof setup>>) {
  await vi.waitFor(() => expect(context.spawn).toHaveBeenCalledTimes(2), { interval: 1 })
  const host = context.processList[1]!
  host.event({ type: 'ready', endpoint_id: ID, direct_addresses: [], local_only: false })
  return host
}
async function running(context: Awaited<ReturnType<typeof setup>>) {
  const pending = context.remote.start()
  await tlsReady(context); const host = await hostReady(context); await pending; return host
}

describe('iroh origin contracts', () => {
  it('uses full endpoint in two DNS-safe labels, never a public domain or short ID', () => {
    expect(irohOrigin(ID)).toBe(`https://${'a'.repeat(32)}.${'a'.repeat(32)}.iroh.localhost:3445`)
    expect(validateRemoteOrigin(irohOrigin(ID), ID)).toBe(irohOrigin(ID))
    for (const value of ['https://example.com', `https://${ID}.iroh.localhost:3445`, irohOrigin(ID) + '/', irohOrigin(ID) + '?', irohOrigin(ID).replace('3445', '4444')]) {
      expect(() => validateRemoteOrigin(value, ID)).toThrow()
    }
    expect(() => irohOrigin('a'.repeat(32))).toThrow()
  })
  it.each(['http://127.0.0.1', 'https://localhost', 'https://127.1', 'https://10.0.0.1', 'https://192.168.1.1', 'https://127.0.0.1/path', 'https://user@127.0.0.1', 'https://127.0.0.1?', 'https://127.0.0.1#'])('rejects unsafe backend %s', value => {
    expect(() => validateBackendOrigin(value)).toThrow()
  })
  it('accepts only literal HTTPS loopback root', () => {
    expect(validateBackendOrigin('https://[::1]:3445/')).toBe('https://[::1]:3445')
  })
})
describe('iroh RemoteController', () => {
  it('defaults disabled and validates configuration without command injection or alternate providers', async () => {
    const remote = new RemoteController({ startBackend: async () => '', stopBackend: async () => {} })
    controllers.push(remote)
    expect(remote.status()).toEqual({ provider: 'iroh', localPort: 3445, enabled: false, state: 'stopped', verified: false })
    await expect(remote.start()).rejects.toMatchObject({ code: 'remote_not_initialized' })
    await remote.initialize()
    await expect(remote.configure({ provider: 'iroh', irohPath: 'host --args' })).rejects.toMatchObject({ code: 'invalid_iroh_path' })
    await expect(remote.configure({ provider: 'iroh', localPort: 80 })).rejects.toMatchObject({ code: 'invalid_iroh_port' })
    await expect(remote.configure({ provider: 'origin' } as never)).rejects.toMatchObject({ code: 'invalid_remote_provider' })
    await expect(remote.configure({ provider: 'iroh', args: [] } as never)).rejects.toMatchObject({ code: 'invalid_remote_provider' })
    await expect(remote.start()).rejects.toMatchObject({ code: 'iroh_component_missing' })
  })
  it('persists only nonsecret config with 600 and never starts during restore', async () => {
    const context = await setup(); const host = await running(context)
    expect((await stat(join(context.directory, 'remote.json'))).mode & 0o777).toBe(0o600)
    const raw = JSON.parse(await readFile(join(context.directory, 'remote.json'), 'utf8'))
    expect(raw).toEqual({ version: 1, config: { provider: 'iroh', irohPath: '/installed/dsh-mobile-iroh-host', localPort: 3445 } })
    host.finish(); await context.remote.close()
    const spawn = vi.fn<RemoteSpawn>()
    const restored = new RemoteController({ stateDirectory: context.directory, spawn, startBackend: async () => '', stopBackend: async () => {} })
    controllers.push(restored); await restored.initialize()
    expect(restored.status()).toMatchObject({ state: 'stopped', enabled: false, provider: 'iroh' })
    expect(spawn).not.toHaveBeenCalled()
  })
  it('corrupt config remains disabled with sanitized error and can be repaired without blocking LAN', async () => {
    const context = await setup(); await writeFile(join(context.directory, 'remote.json'), '{SECRET')
    const restored = new RemoteController({ stateDirectory: context.directory, startBackend: async () => '', stopBackend: async () => {} })
    controllers.push(restored); await restored.initialize()
    expect(restored.status()).toMatchObject({ state: 'error', enabled: false, error: 'remote_config_load_failed' })
    expect(JSON.stringify(restored.status())).not.toContain('SECRET')
    await restored.configure({ provider: 'iroh', irohPath: '/installed/host' })
    expect(restored.status().state).toBe('stopped')
  })
  it('rejects unsafe existing configuration permissions without silently repairing them', async () => {
    const context = await setup(); const file = join(context.directory, 'remote.json'); await chmod(file, 0o644)
    const restored = new RemoteController({ stateDirectory: context.directory, startBackend: async () => '', stopBackend: async () => {} })
    controllers.push(restored); await restored.initialize()
    expect(restored.status()).toMatchObject({ enabled: false, state: 'error', error: 'remote_config_load_failed' })
    expect((await stat(file)).mode & 0o777).toBe(0o644)
  })
  it('uses tls-prepare before gateway, launches opaque host without shell, and serializes duplicate starts', async () => {
    const context = await setup()
    const first = context.remote.start(); const second = context.remote.start()
    await tlsReady(context)
    expect(context.spawn.mock.calls[0]).toEqual(['/installed/dsh-mobile-iroh-host',
      ['--lang', 'en', 'tls-prepare', '--data-dir', join(context.directory, 'iroh'), '--leaf-validity-days', '90', '--renew-before-days', '30'],
      { shell: false, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true }])
    await hostReady(context); expect(await first).toMatchObject({ origin: irohOrigin(ID), state: 'running', endpointId: ID, verified: false })
    await second
    expect(context.startBackend).toHaveBeenCalledTimes(1)
    expect(context.startBackend.mock.calls[0]![0]).toMatchObject({ endpointId: ID, origin: irohOrigin(ID), localPort: 3445,
      caFingerprint: Array(32).fill('BB').join(':'), tls: metadata(context.directory).tls })
    expect(context.spawn.mock.calls[1]![1]).toEqual(['--lang', 'en', 'host', '--data-dir', join(context.directory, 'iroh'), '--proxy-target', '127.0.0.1:3445'])
    await expect(context.remote.configure({ provider: 'iroh' })).rejects.toMatchObject({ code: 'remote_must_be_stopped' })
    await context.remote.stop()
    expect(context.remote.status()).toMatchObject({ state: 'stopped', enabled: false })
    expect(context.onOrigin).toHaveBeenLastCalledWith(undefined)
  })
  it('TLS metadata rejects identity/path substitution', async () => {
    const context = await setup(); const pending = context.remote.start()
    const assertion = expect(pending).rejects.toMatchObject({ code: 'iroh_identity_invalid' })
    await tlsReady(context, { tls: { caFile: '/secret', certFile: '/secret', keyFile: '/secret' } }); await assertion
    expect(context.startBackend).not.toHaveBeenCalled()
  })
  it('startup timeout applies to TLS process, kills it and leaves no origin', async () => {
    const context = await setup({ startupTimeoutMs: 15 })
    const pending = context.remote.start(); const assertion = expect(pending).rejects.toMatchObject({ code: 'iroh_start_timeout' })
    await assertion
    expect(context.processList[0]!.signals).toEqual(['SIGTERM'])
    expect(context.remote.status().origin).toBeUndefined()
  })
  it('startup timeout applies to backend and late backend success cannot publish or escape cleanup', async () => {
    let resolveBackend!: (origin: string) => void
    const context = await setup({ startupTimeoutMs: 30, startBackend: async () => new Promise(resolve => { resolveBackend = resolve }) })
    const pending = context.remote.start(); const assertion = expect(pending).rejects.toMatchObject({ code: 'iroh_start_timeout' })
    await tlsReady(context); await assertion
    await expect(context.remote.start()).rejects.toMatchObject({ code: 'remote_cleanup_required' })
    resolveBackend('https://127.0.0.1:3445')
    await vi.waitFor(() => expect(context.stopBackend).toHaveBeenCalledTimes(2), { interval: 1 })
    expect(context.spawn).toHaveBeenCalledTimes(1)
    expect(context.remote.status().origin).toBeUndefined()
  })
  it('rejects malformed or unknown host events and excessive stdout without leaking logs', async () => {
    const context = await setup(); const pending = context.remote.start()
    const assertion = expect(pending).rejects.toMatchObject({ code: 'iroh_protocol_error' })
    await tlsReady(context)
    await vi.waitFor(() => expect(context.spawn).toHaveBeenCalledTimes(2), { interval: 1 })
    context.processList[1]!.stderr.write('SECRET token=credential\n')
    context.processList[1]!.stdout.write('x'.repeat(100_000))
    await assertion
    expect(context.stopBackend).toHaveBeenCalled()
    expect(JSON.stringify(context.remote.status())).not.toContain('SECRET')
  })
  it('host ready must match prepared identity', async () => {
    const context = await setup(); const pending = context.remote.start()
    const assertion = expect(pending).rejects.toMatchObject({ code: 'iroh_protocol_error' })
    await tlsReady(context); await vi.waitFor(() => expect(context.spawn).toHaveBeenCalledTimes(2), { interval: 1 })
    context.processList[1]!.event({ type: 'ready', endpoint_id: 'd'.repeat(64), direct_addresses: [], local_only: false }); await assertion
  })
  it('runtime exit clears authority immediately and retires gateway', async () => {
    const context = await setup(); const host = await running(context)
    host.finish(1)
    expect(context.remote.status()).toMatchObject({ state: 'error', error: 'iroh_process_exited' })
    expect(context.remote.status().origin).toBeUndefined()
    await vi.waitFor(() => expect(context.stopBackend).toHaveBeenCalledTimes(1), { interval: 1 })
  })
  it('close cancels pending startup and is terminal, stop/close are idempotent', async () => {
    const context = await setup(); const pending = context.remote.start()
    const assertion = expect(pending).rejects.toMatchObject({ code: 'remote_cancelled' })
    await vi.waitFor(() => expect(context.spawn).toHaveBeenCalled(), { interval: 1 })
    const closing = context.remote.close(); await assertion; await closing; await context.remote.close()
    expect(context.remote.status()).toMatchObject({ state: 'stopped', enabled: false })
    await expect(context.remote.start()).rejects.toMatchObject({ code: 'remote_closed' })
  })
  it('kill escalation awaits actual close and retains handle after kill timeout', async () => {
    const context = await setup(); const host = await running(context)
    host.ignoreTerm = true; host.ignoreKill = true
    await expect(context.remote.stop()).rejects.toMatchObject({ code: 'remote_kill_timeout' })
    expect(host.signals).toEqual(['SIGTERM', 'SIGKILL'])
    expect(context.remote.status()).toMatchObject({ enabled: false, state: 'error' })
    await expect(context.remote.start()).rejects.toMatchObject({ code: 'remote_cleanup_required' })
    host.ignoreKill = false; await context.remote.close()
    expect(context.remote.status().state).toBe('stopped')
    expect(host.listenerCount('close')).toBe(0)
  })
  it('local-only native smoke flag is explicit and validates matching ready mode', async () => {
    const context = await setup({ localOnly: true })
    const pending = context.remote.start(); await tlsReady(context)
    await vi.waitFor(() => expect(context.spawn).toHaveBeenCalledTimes(2), { interval: 1 })
    expect(context.spawn.mock.calls[1]![1]).toContain('--local-only')
    context.processList[1]!.event({ type: 'ready', endpoint_id: ID, direct_addresses: ['127.0.0.1:1234'], local_only: true })
    await pending
    expect(context.remote.status().verified).toBe(false)
  })
  it('command timeout retires uncertain pairing channel and closes its gateway', async () => {
    const access = new AccessController(undefined); await access.initialize()
    const context = await setup({ access, commandTimeoutMs: 10 }); await running(context)
    await expect(context.remote.openPairing()).rejects.toMatchObject({ code: 'iroh_command_timeout' })
    expect(context.remote.status()).toMatchObject({ state: 'error', error: 'iroh_command_timeout' })
    expect(context.stopBackend).toHaveBeenCalled()
    expect(context.remote.status().origin).toBeUndefined(); access.close()
  })
  it('builds native-compatible pairing descriptor through FIFO barrier and never leaks secrets into status', async () => {
    const access = new AccessController(undefined); await access.initialize()
    const context = await setup({ access })
    const key = forge.pki.rsa.generateKeyPair(1024)
    const cert = forge.pki.createCertificate(); cert.publicKey = key!.publicKey; cert.serialNumber = '01'
    cert.validity.notBefore = new Date(Date.now() - 60_000); cert.validity.notAfter = new Date(Date.now() + 86_400_000)
    cert.setSubject([{ name: 'commonName', value: 'iroh test CA' }]); cert.setIssuer(cert.subject.attributes)
    cert.setExtensions([{ name: 'basicConstraints', cA: true }, { name: 'keyUsage', keyCertSign: true }]); cert.sign(key!.privateKey, forge.md.sha256.create())
    const pem = forge.pki.certificateToPem(cert); const x509 = new X509Certificate(pem)
    const fingerprint = createHash('sha256').update(x509.raw).digest('hex')
    const file = join(context.directory, 'iroh/tls/ca.pem'); await mkdir(join(context.directory, 'iroh/tls'), { recursive: true }); await writeFile(file, pem)
    const starting = context.remote.start(); await tlsReady(context, { caFingerprint256: fingerprint, instanceId: fingerprint })
    const host = await hostReady(context); await starting
    const commands: string[] = []
    host.stdin.on('data', chunk => {
      const message = JSON.parse(chunk.toString()); commands.push(message.type)
      if (message.type === 'device-list') host.event({ type: 'devices', devices: [] })
      if (message.type === 'pairing-begin') host.event({ type: 'pairing', code: '123456', expires_in_sec: 60 })
    })
    const result = await context.remote.openPairing()
    expect(commands).toEqual(['device-list', 'pairing-begin'])
    expect(result.descriptor).toMatchObject({ version: 1, type: 'dsh-mobile-iroh-pairing', endpointId: ID, origin: irohOrigin(ID),
      localPort: 3445, irohCode: '123456', instanceId: fingerprint, caCertificate: x509.raw.toString('base64') })
    expect(result.descriptor.gatewayToken).toMatch(/^[A-Za-z0-9_-]{43}$/u)
    expect(JSON.parse(result.qrPayload)).toEqual(result.descriptor)
    expect(Buffer.byteLength(result.qrPayload)).toBeLessThanOrEqual(2200)
    expect(JSON.stringify(context.remote.status())).not.toContain('123456')
    expect(JSON.stringify(context.remote.status())).not.toContain(result.descriptor.gatewayToken)
    access.close()
  })
})
