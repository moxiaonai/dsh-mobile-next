/** Opt-in real native CLI smoke coverage. Never enables relay/discovery/public listeners.
 * Run with DSH_IROH_HOST=/absolute/path/dsh-mobile-iroh-host and system Node.
 * This is host-only local validation, NOT phone pairing or cross-network verification. */
import { execFile, spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { isAbsolute, join, resolve } from 'node:path'
import { promisify } from 'node:util'
import { createHash, X509Certificate } from 'node:crypto'
import { createServer, request } from 'node:https'
import { afterEach, describe, expect, it } from 'vitest'
import { irohOrigin } from '../src/remote.js'

const binary = process.env.DSH_IROH_HOST
const skipReason = !binary ? 'DSH_IROH_HOST not set; real native binary explicitly opt-in' :
  !isAbsolute(binary) ? 'DSH_IROH_HOST must be an absolute path' :
    !existsSync(binary) ? 'DSH_IROH_HOST binary does not exist' : undefined
const exec = promisify(execFile)
const cleanup: Array<() => Promise<void>> = []
afterEach(async () => { for (const fn of cleanup.splice(0).reverse()) await fn() })

async function identity() {
  const directory = await mkdtemp(join(tmpdir(), 'dshmn-iroh-native-'))
  cleanup.push(async () => {
    expect(resolve(directory)).toBe(directory)
    expect(directory.startsWith(join(tmpdir(), 'dshmn-iroh-native-'))).toBe(true)
    await rm(directory, { recursive: true, force: true })
  })
  expect((await stat(directory)).mode & 0o777).toBe(0o700)
  const args = ['--lang', 'en', 'tls-prepare', '--data-dir', directory, '--leaf-validity-days', '90', '--renew-before-days', '30']
  const prepared = await exec(binary!, args, { timeout: 15_000, maxBuffer: 16 * 1024 })
  const metadata = JSON.parse(prepared.stdout)
  return { directory, args, metadata }
}

function hostEvents(child: ChildProcess) {
  let pending = ''
  const events: any[] = []
  const errors: string[] = []
  const listeners = new Set<() => void>()
  let closed = false
  let exitCode: number | null = null
  child.stdout!.setEncoding('utf8')
  child.stderr!.setEncoding('utf8')
  child.stderr!.on('data', chunk => errors.push(String(chunk)))
  child.stdout!.on('data', chunk => {
    pending += chunk
    while (pending.includes('\n')) {
      const index = pending.indexOf('\n'), line = pending.slice(0, index)
      pending = pending.slice(index + 1)
      try { events.push(JSON.parse(line)) } catch { errors.push(`non-JSON stdout: ${line}`) }
    }
    for (const listener of listeners) listener()
  })
  child.on('error', error => { errors.push(error.message); for (const listener of listeners) listener() })
  const done = new Promise<void>(resolveDone => child.on('close', code => {
    exitCode = code; closed = true; for (const listener of listeners) listener(); resolveDone()
  }))
  const event = (type: string): Promise<any> => new Promise((resolveEvent, reject) => {
    const timer = setTimeout(() => { listeners.delete(check); reject(new Error(`native ${type} timeout: ${errors.join('')}`)) }, 10_000)
    const check = () => {
      const value = events.find(event => event.type === type)
      if (value) { clearTimeout(timer); listeners.delete(check); resolveEvent(value) }
      else if (closed || errors.length) { clearTimeout(timer); listeners.delete(check); reject(new Error(`native exited/errors before ${type}: ${errors.join('')}`)) }
    }
    listeners.add(check); check()
  })
  return { events, errors, event, done, get closed() { return closed }, get exitCode() { return exitCode } }
}

describe.skipIf(Boolean(skipReason))(`real iroh native CLI, local-only host smoke${skipReason ? ` [SKIP: ${skipReason}]` : ''}`, () => {
  it('tls-prepare and id persist a full endpoint identity with verifiable CA and endpoint-only SAN', async () => {
    const { directory, args, metadata } = await identity()
    expect(metadata).toMatchObject({ version: 1, endpointId: expect.stringMatching(/^[a-f0-9]{64}$/u) })
    expect(metadata.hostname).toBe(new URL(irohOrigin(metadata.endpointId)).hostname)
    const id = await exec(binary!, ['--lang', 'en', 'id', '--data-dir', directory], { timeout: 10_000 })
    expect(id.stdout.trim()).toBe(metadata.endpointId)
    const ca = new X509Certificate(await readFile(metadata.tls.caFile))
    const leaf = new X509Certificate(await readFile(metadata.tls.certFile))
    expect(ca.ca).toBe(true); expect(ca.subject).toBe(ca.issuer); expect(ca.verify(ca.publicKey)).toBe(true)
    expect(leaf.verify(ca.publicKey)).toBe(true)
    expect(leaf.checkHost(metadata.hostname)).toBe(metadata.hostname)
    expect(leaf.checkHost('wrong.iroh.localhost')).toBeUndefined()
    expect(leaf.checkIP('127.0.0.1')).toBeUndefined()
    expect(createHash('sha256').update(ca.raw).digest('hex')).toBe(metadata.instanceId)
    expect(metadata.caFingerprint256).toBe(metadata.instanceId)
    expect(createHash('sha256').update(leaf.raw).digest('hex')).toBe(metadata.leafFingerprint256)
    expect(metadata.leafValidTo).toBe(Date.parse(leaf.validTo))
    expect(metadata.caValidTo).toBe(Date.parse(ca.validTo))
    expect(metadata.leafValidTo).toBeGreaterThan(Date.now())
    expect(metadata.leafValidTo).toBeLessThanOrEqual(metadata.caValidTo)
    expect((await stat(metadata.tls.keyFile)).mode & 0o777).toBe(0o600)
    const repeated = JSON.parse((await exec(binary!, args, { timeout: 15_000 })).stdout)
    expect(repeated).toEqual(metadata)
  }, 30_000)

  it('host --local-only reaches ready on loopback, accepts NDJSON device-list and shuts down cleanly', async () => {
    const { directory, metadata } = await identity()
    const [cert, key, ca] = await Promise.all([readFile(metadata.tls.certFile), readFile(metadata.tls.keyFile), readFile(metadata.tls.caFile)])
    const backend = createServer({ cert, key }, (_req, res) => res.end('local TLS backend'))
    await new Promise<void>(resolveReady => backend.listen(0, '127.0.0.1', resolveReady))
    cleanup.push(() => new Promise(resolveDone => { backend.close(() => resolveDone()); backend.closeAllConnections() }))
    const port = (backend.address() as { port: number }).port
    // Verify actual TLS identity before handing the opaque target socket to native host.
    const body = await new Promise<string>((resolveBody, reject) => {
      const req = request({ hostname: '127.0.0.1', port, servername: metadata.hostname, ca, agent: false }, res => {
        let text = ''; res.on('data', chunk => { text += chunk }); res.on('end', () => resolveBody(text))
      })
      req.on('error', reject); req.end()
    })
    expect(body).toBe('local TLS backend')
    const child = spawn(binary!, ['--lang', 'en', 'host', '--data-dir', directory, '--proxy-target', `127.0.0.1:${port}`, '--local-only'],
      { shell: false, stdio: ['pipe', 'pipe', 'pipe'] })
    const host = hostEvents(child)
    cleanup.push(async () => {
      if (host.closed) return
      child.kill('SIGTERM')
      let timer: ReturnType<typeof setTimeout> | undefined
      try { await Promise.race([host.done, new Promise<void>((_, reject) => {
        timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('native cleanup timeout')) }, 5000)
      })]) } finally { clearTimeout(timer) }
    })
    const ready = await host.event('ready')
    expect(ready).toMatchObject({ version: 1, endpoint_id: metadata.endpointId, local_only: true })
    expect(Array.isArray(ready.direct_addresses)).toBe(true)
    expect(ready.direct_addresses.length).toBeGreaterThan(0)
    for (const address of ready.direct_addresses) expect(address).toMatch(/^(?:127\.0\.0\.1:\d+|\[::1\]:\d+)$/u)
    child.stdin!.write(JSON.stringify({ version: 1, type: 'device-list' }) + '\n')
    expect(await host.event('devices')).toMatchObject({ version: 1, devices: [] })
    child.stdin!.write(JSON.stringify({ version: 1, type: 'shutdown' }) + '\n')
    expect(await host.event('stopped')).toEqual({ version: 1, type: 'stopped' })
    await host.done
    expect(host.exitCode).toBe(0)
    expect(host.events.some(event => event.type === 'error')).toBe(false)
    // No dial/client/peer transfer occurs: ready is not evidence of external accessibility.
    expect(host.events.some(event => event.type === 'peer-connected' || event.type === 'proxy-opened')).toBe(false)
  }, 30_000)
})
