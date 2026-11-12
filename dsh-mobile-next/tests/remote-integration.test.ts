/** Real plugin/admin HTTP + endpoint-specific HTTPS; only native process/network is mocked.
 * No public DNS, relay, tunnel, or TLS verification bypass is used in this suite. */
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createServer, request as httpRequest, type IncomingHttpHeaders } from 'node:http'
import { request as httpsRequest } from 'node:https'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { createHash, X509Certificate } from 'node:crypto'
import forge from 'node-forge'
import { afterEach, describe, expect, it, vi } from 'vitest'

const native = vi.hoisted(() => ({ spawn: vi.fn() }))
vi.mock('node:child_process', () => ({ spawn: native.spawn }))
import plugin from '../src/plugin.js'
import type { AdminRoute } from '../src/admin.js'
import { irohOrigin } from '../src/remote.js'

const ENDPOINT = 'abcdefabcdefabcd'.repeat(4)
const BINARY = '/installed/dsh-mobile-iroh-host'
const LAN_TOKEN = 'existing-lan-device-token'
const cleanup: Array<() => Promise<void>> = []
afterEach(async () => {
  try { for (const fn of cleanup.splice(0).reverse()) await fn() }
  finally { vi.restoreAllMocks(); native.spawn.mockReset() }
})

class NativeProcess extends EventEmitter {
  stdin = new PassThrough()
  stdout = new PassThrough()
  stderr = new PassThrough()
  closed = false
  commands: string[] = []
  finish(code = 0) {
    if (this.closed) return
    this.closed = true
    this.emit('exit', code, null); this.emit('close', code, null)
  }
  kill() { this.finish(); return true }
  event(event: object) { this.stdout.write(JSON.stringify({ version: 1, ...event }) + '\n') }
}

async function certificates(directory: string, now: number) {
  const hostname = new URL(irohOrigin(ENDPOINT)).hostname
  const keys = forge.pki.rsa.generateKeyPair(2048)
  const ca = forge.pki.createCertificate()
  ca.publicKey = keys.publicKey; ca.serialNumber = '01'
  ca.validity.notBefore = new Date(now - 60_000); ca.validity.notAfter = new Date(now + 365 * 86400_000)
  ca.setSubject([{ name: 'commonName', value: 'integration endpoint CA' }]); ca.setIssuer(ca.subject.attributes)
  ca.setExtensions([{ name: 'basicConstraints', cA: true, critical: true }, { name: 'keyUsage', keyCertSign: true, cRLSign: true, critical: true }])
  ca.sign(keys.privateKey, forge.md.sha256.create())
  const leaf = forge.pki.createCertificate()
  leaf.publicKey = keys.publicKey; leaf.serialNumber = '02'
  leaf.validity.notBefore = ca.validity.notBefore; leaf.validity.notAfter = new Date(now + 90 * 86400_000)
  leaf.setSubject([{ name: 'commonName', value: 'iroh endpoint' }]); leaf.setIssuer(ca.subject.attributes)
  leaf.setExtensions([{ name: 'basicConstraints', cA: false, critical: true }, { name: 'keyUsage', digitalSignature: true, keyEncipherment: true, critical: true },
    { name: 'extKeyUsage', serverAuth: true }, { name: 'subjectAltName', altNames: [{ type: 2, value: hostname }] }])
  leaf.sign(keys.privateKey, forge.md.sha256.create())
  const tlsDirectory = join(directory, 'tls')
  await mkdir(tlsDirectory, { recursive: true })
  const tls = { caFile: join(tlsDirectory, 'ca.pem'), certFile: join(tlsDirectory, 'server.pem'), keyFile: join(tlsDirectory, 'server-key.pem') }
  const caPem = forge.pki.certificateToPem(ca)
  const leafPem = forge.pki.certificateToPem(leaf)
  await Promise.all([writeFile(tls.caFile, caPem), writeFile(tls.certFile, leafPem), writeFile(tls.keyFile, forge.pki.privateKeyToPem(keys.privateKey), { mode: 0o600 })])
  const caX509 = new X509Certificate(caPem), leafX509 = new X509Certificate(leafPem)
  const fingerprint = createHash('sha256').update(caX509.raw).digest('hex')
  return { caPem, metadata: { version: 1, endpointId: ENDPOINT, hostname, instanceId: fingerprint, caFingerprint256: fingerprint,
    leafFingerprint256: createHash('sha256').update(leafX509.raw).digest('hex'), caValidTo: Date.parse(caX509.validTo), leafValidTo: Date.parse(leafX509.validTo), tls } }
}

interface Response { status: number; text: string; headers: IncomingHttpHeaders; json: any }
async function fixture(options: { badReady?: boolean; authFailure?: boolean; nativePairingSeconds?: number } = {}) {
  let now = Date.now()
  vi.spyOn(Date, 'now').mockImplementation(() => now)
  const directory = await mkdtemp(join(tmpdir(), 'dshmn-iroh-integration-'))
  cleanup.push(async () => {
    expect(resolve(directory)).toBe(directory)
    expect(directory.startsWith(join(tmpdir(), 'dshmn-iroh-integration-'))).toBe(true)
    await rm(directory, { recursive: true, force: true })
  })
  await writeFile(join(directory, 'devices.json'), JSON.stringify({ version: 1, devices: [{ deviceId: 'lan-device', label: 'LAN phone',
    tokenDigest: createHash('sha256').update(LAN_TOKEN).digest('hex'), createdAt: now, lastSeenAt: now, expiresAt: now + 86400_000 }] }))
  const routes: AdminRoute[] = []
  const seen: Array<{ path: string; headers: IncomingHttpHeaders }> = []
  const server = createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    const route = routes.find(route => route.kind === 'exact' && route.path === url.pathname)
    if (route) { void route.handler(req, res).catch(() => { res.writeHead(500); res.end('handler error') }); return }
    if (url.searchParams.get('launch') === 'local-only-launch') {
      res.writeHead(options.authFailure ? 401 : 303, { 'set-cookie': 'dsh-auth-test=upstream-secret; Max-Age=3600', location: '/' })
      res.end('exchange'); return
    }
    seen.push({ path: req.url!, headers: req.headers })
    res.writeHead(req.headers.cookie === 'dsh-auth-test=upstream-secret' ? 200 : 401)
    res.end('private upstream')
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  cleanup.push(() => new Promise(resolve => { server.close(() => resolve()); server.closeAllConnections() }))
  const upstreamPort = (server.address() as { port: number }).port
  // Reserve an ephemeral loopback port, then release it for the fixed logical iroh port.
  const reservation = createServer()
  await new Promise<void>(resolve => reservation.listen(0, '127.0.0.1', resolve))
  const localPort = (reservation.address() as { port: number }).port
  await new Promise<void>(resolve => reservation.close(() => resolve()))
  const origin = irohOrigin(ENDPOINT, localPort)
  const children: NativeProcess[] = []
  let caPem = ''
  native.spawn.mockImplementation((file: string, args: string[], spawnOptions: object) => {
    expect(file).toBe(BINARY)
    expect(spawnOptions).toEqual({ shell: false, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true })
    const child = new NativeProcess(); children.push(child)
    if (args.includes('tls-prepare')) {
      void certificates(args[args.indexOf('--data-dir') + 1]!, new Date().getTime()).then(result => {
        caPem = result.caPem; child.stdout.write(JSON.stringify(result.metadata)); child.finish()
      }).catch(() => child.finish(1))
    } else {
      expect(args).toEqual(['--lang', 'en', 'host', '--data-dir', join(directory, 'iroh'), '--proxy-target', `127.0.0.1:${localPort}`])
      child.stdin.on('data', chunk => {
        for (const line of String(chunk).trim().split('\n')) {
          const command = JSON.parse(line); child.commands.push(command.type)
          queueMicrotask(() => {
            if (command.type === 'device-list') child.event({ type: 'devices', devices: [] })
            if (command.type === 'pairing-begin') child.event({ type: 'pairing', code: '123456', expires_in_sec: options.nativePairingSeconds ?? 300 })
            if (command.type === 'shutdown') child.finish()
          })
        }
      })
      queueMicrotask(() => {
        // Deliberately split NDJSON to exercise the real controller framing.
        const line = JSON.stringify({ version: 1, type: 'ready', endpoint_id: options.badReady ? 'b'.repeat(64) : ENDPOINT, direct_addresses: [], local_only: false }) + '\n'
        child.stdout.write(line.slice(0, 27)); child.stdout.write(line.slice(27))
      })
    }
    return child
  })
  let dispose: (() => void | Promise<void>) | undefined
  await plugin({
    webServer: { port: upstreamPort, register: route => { routes.push(route); return () => { routes.splice(routes.indexOf(route), 1) } } },
    connection: { authenticatedUrl: base => `${base}/?launch=local-only-launch` },
    effect: callback => { const value = callback(); if (value) dispose = value },
  }, { setupFile: join(directory, 'setup.json'), stateFile: join(directory, 'devices.json'), initiallyEnabled: false })
  cleanup.push(async () => { await dispose?.(); for (const child of children) child.finish() })
  function call(secure: boolean, path: string, body?: unknown, headers: Record<string, string> = {}, tls: { ca?: string; servername?: string } = {}) {
    return new Promise<Response>((resolveResponse, reject) => {
      const request = (secure ? httpsRequest : httpRequest)({ hostname: '127.0.0.1', port: secure ? localPort : upstreamPort, path,
        method: body === undefined ? 'GET' : 'POST', agent: false,
        ...(secure ? { ca: tls.ca ?? caPem, servername: tls.servername ?? new URL(origin).hostname } : {}),
        headers: { ...(secure ? { host: new URL(origin).host } : {}), ...(body === undefined ? {} : { 'content-type': 'application/json' }), ...headers },
      }, response => {
        let text = ''; response.on('data', chunk => { text += chunk }); response.on('end', () => {
          let json: any; try { json = JSON.parse(text) } catch { json = undefined }
          resolveResponse({ status: response.statusCode!, text, headers: response.headers, json })
        })
      })
      request.on('error', reject); request.setTimeout(3000, () => request.destroy(new Error('local request timeout')))
      request.end(body === undefined ? undefined : JSON.stringify(body))
    })
  }
  const admin = (path: string, body?: unknown, headers?: Record<string, string>) => call(false, `/mobile-access-next${path}`, body, headers)
  const gateway = (path: string, body?: unknown, headers?: Record<string, string>, tls?: { ca?: string; servername?: string }) => call(true, path, body, headers, tls)
  const start = async () => {
    expect((await admin('/remote/config', { provider: 'iroh', irohPath: BINARY, localPort })).status).toBe(200)
    return admin('/remote/enable', { enabled: true })
  }
  return { directory, admin, gateway, start, origin, localPort, upstreamPort, seen, children, advance: (ms: number) => { now += ms } }
}
const cookie = (response: Response) => response.headers['set-cookie']![0]!.split(';')[0]!

describe('iroh plugin integration (mock sidecar, real local TLS and admin routes)', () => {
  it('starts independently and emits the complete endpoint/CA-bound descriptor, never a Cloudflare URL', async () => {
    const f = await fixture()
    expect((await f.admin('/remote/pairing', {})).status).toBe(409)
    expect((await f.start()).status).toBe(200)
    const status = (await f.admin('/status')).json
    expect(status.state).toBe('stopped')
    expect(status.remote).toMatchObject({ provider: 'iroh', state: 'running', enabled: true, verified: false, endpointId: ENDPOINT, origin: f.origin, backendOrigin: `https://127.0.0.1:${f.localPort}` })
    expect((await f.admin('/remote/config', { provider: 'iroh' })).status).toBe(409)
    const pairing = await f.admin('/remote/pairing', {})
    expect(pairing.status).toBe(201)
    const descriptor = pairing.json.descriptor
    expect(Object.keys(descriptor).sort()).toEqual(['version', 'type', 'endpointId', 'origin', 'localPort', 'irohCode', 'gatewayToken', 'caCertificate', 'instanceId', 'expiresAt'].sort())
    expect(descriptor).toMatchObject({ version: 1, type: 'dsh-mobile-iroh-pairing', endpointId: ENDPOINT, origin: f.origin, localPort: f.localPort, irohCode: '123456', gatewayToken: pairing.json.token })
    expect(JSON.parse(pairing.json.qrPayload)).toEqual(descriptor)
    expect(pairing.json.url).toBe(pairing.json.qrPayload)
    expect(pairing.json.qrSvg).toContain('<svg')
    const ca = new X509Certificate(Buffer.from(descriptor.caCertificate, 'base64'))
    expect(ca.ca).toBe(true); expect(ca.verify(ca.publicKey)).toBe(true)
    expect(ca.raw.toString('base64')).toBe(descriptor.caCertificate)
    expect(createHash('sha256').update(ca.raw).digest('hex')).toBe(descriptor.instanceId)
    expect(descriptor.expiresAt).toBeGreaterThan(Date.now())
    expect(descriptor.expiresAt).toBeLessThanOrEqual(Date.now() + 300_000)
    expect(Buffer.byteLength(pairing.json.qrPayload)).toBeLessThanOrEqual(2200)
    expect(JSON.stringify(status)).not.toContain(descriptor.gatewayToken)
    expect(JSON.stringify(status)).not.toContain(descriptor.irohCode)
    expect(f.children[1]!.commands).toEqual(['device-list', 'pairing-begin'])
    expect((await f.gateway('/mobile-access-next/health', undefined, {}, { ca: ca.toString() })).status).toBe(200)
    const savedConfig = await readFile(join(f.directory, 'remote.json'), 'utf8')
    expect(JSON.parse(savedConfig)).toEqual({ version: 1, config: { provider: 'iroh', irohPath: BINARY, localPort: f.localPort } })
    expect(savedConfig).not.toContain(descriptor.gatewayToken)
    expect(savedConfig).not.toContain(descriptor.caCertificate)
    await expect(f.gateway('/mobile-access-next/health', undefined, {}, { servername: 'wrong.iroh.localhost' })).rejects.toMatchObject({ code: 'ERR_TLS_CERT_ALTNAME_INVALID' })
    await expect(f.gateway('/mobile-access-next/health', undefined, {}, { ca: '' })).rejects.toBeDefined()
    const pair = await f.gateway('/mobile-access-next/pair', { token: descriptor.gatewayToken, label: 'Remote phone' })
    expect(pair.status).toBe(201); expect(pair.json.instanceId).toBe(descriptor.instanceId)
    expect(pair.headers['set-cookie']![0]).toMatch(/HttpOnly; Secure; SameSite=Strict/u)
    expect((await f.gateway('/mobile-access-next/pair', { token: descriptor.gatewayToken })).status).toBe(401)
  })

  it('isolates LAN credentials, proxies only authorized requests, blocks management and cross-site writes', async () => {
    const f = await fixture(); expect((await f.start()).status).toBe(200)
    const lanPairing = (await f.admin('/pairing', {})).json
    const remotePairing = (await f.admin('/remote/pairing', {})).json.descriptor
    expect((await f.gateway('/mobile-access-next/pair', { token: lanPairing.token })).status).toBe(401)
    const lan = await f.admin('/renew', { deviceToken: LAN_TOKEN })
    expect(lan.status).toBe(200)
    expect((await f.gateway('/', undefined, { cookie: `dsh-mobile-next-session=${lan.json.sessionToken}` })).status).toBe(401)
    expect((await f.gateway('/mobile-access-next/renew', { deviceToken: LAN_TOKEN })).status).toBe(401)
    const pair = await f.gateway('/mobile-access-next/pair', { token: remotePairing.gatewayToken })
    expect(pair.status).toBe(201)
    expect((await f.gateway('/')).status).toBe(401)
    const headers = { cookie: `${cookie(pair)}; attacker=1`, origin: f.origin, authorization: 'Bearer attacker', forwarded: 'for=evil', 'x-forwarded-host': 'evil' }
    expect((await f.gateway('/api/write', { action: 'test' }, headers)).status).toBe(200)
    expect(f.seen.at(-1)).toMatchObject({ path: '/api/write', headers: { host: `127.0.0.1:${f.upstreamPort}`, origin: `http://127.0.0.1:${f.upstreamPort}`, cookie: 'dsh-auth-test=upstream-secret' } })
    expect(f.seen.at(-1)!.headers.authorization).toBeUndefined()
    expect(f.seen.at(-1)!.headers.forwarded).toBeUndefined()
    expect(f.seen.at(-1)!.headers['x-forwarded-host']).toBeUndefined()
    const count = f.seen.length
    for (const path of ['/remote/config', '/remote/enable', '/remote/pairing', '/status', '/pairing', '/devices/revoke', '/unknown']) {
      expect((await f.gateway(`/mobile-access-next${path}`, {}, { cookie: cookie(pair) })).status).toBe(404)
    }
    expect((await f.gateway('/api/write', {}, { cookie: cookie(pair), origin: 'https://evil.example' })).status).toBe(403)
    expect((await f.gateway('/api/write', {}, { cookie: cookie(pair), 'sec-fetch-site': 'cross-site' })).status).toBe(403)
    expect(f.seen).toHaveLength(count)
    expect((await f.admin('/renew', { deviceToken: pair.json.deviceToken })).status).toBe(401)
  })

  it('does not accept a gateway token after the shorter native pairing deadline expires', async () => {
    const f = await fixture({ nativePairingSeconds: 60 }); expect((await f.start()).status).toBe(200)
    const descriptor = (await f.admin('/remote/pairing', {})).json.descriptor
    expect(descriptor.expiresAt).toBeLessThanOrEqual(Date.now() + 60_000)
    f.advance(descriptor.expiresAt - Date.now() + 1)
    expect((await f.gateway('/mobile-access-next/pair', { token: descriptor.gatewayToken })).status).toBe(401)
    expect((await f.admin('/status')).json.remote.state).toBe('running')
  })

  it('expires unused descriptors and clears sessions and pairing windows on native stop while preserving channel-specific devices', async () => {
    const f = await fixture(); expect((await f.start()).status).toBe(200)
    const expired = (await f.admin('/remote/pairing', {})).json.descriptor
    f.advance(expired.expiresAt - Date.now() + 1)
    expect((await f.gateway('/mobile-access-next/pair', { token: expired.gatewayToken })).status).toBe(401)
    const descriptor = (await f.admin('/remote/pairing', {})).json.descriptor
    const pair = await f.gateway('/mobile-access-next/pair', { token: descriptor.gatewayToken })
    expect(pair.status).toBe(201)
    const unused = (await f.admin('/remote/pairing', {})).json.descriptor
    expect((await f.admin('/remote/enable', { enabled: false })).json.state).toBe('stopped')
    expect(f.children[1]!.closed).toBe(true)
    expect((await f.start()).status).toBe(200)
    expect((await f.gateway('/', undefined, { cookie: cookie(pair) })).status).toBe(401)
    expect((await f.gateway('/mobile-access-next/pair', { token: unused.gatewayToken })).status).toBe(401)
    const renewed = await f.gateway('/mobile-access-next/renew', { deviceToken: pair.json.deviceToken })
    expect(renewed.status).toBe(200)
    expect((await f.gateway('/', undefined, { cookie: cookie(renewed) })).status).toBe(200)
    const devices = (await f.admin('/devices')).json.devices
    expect(devices.map((device: any) => device.channel).sort()).toEqual(['lan', 'remote'])
    expect((await f.admin('/devices/revoke', { deviceId: pair.json.deviceId, channel: 'lan' })).status).toBe(200)
    expect((await f.gateway('/', undefined, { cookie: cookie(renewed) })).status).toBe(200)
    expect((await f.admin('/devices/revoke', { deviceId: pair.json.deviceId, channel: 'remote' })).status).toBe(200)
    expect((await f.gateway('/', undefined, { cookie: cookie(renewed) })).status).toBe(401)
    expect((await f.gateway('/mobile-access-next/renew', { deviceToken: pair.json.deviceToken })).status).toBe(401)
    expect((await f.admin('/devices')).json.devices).toMatchObject([{ deviceId: 'lan-device', channel: 'lan' }])
    expect((await f.admin('/renew', { deviceToken: LAN_TOKEN })).status).toBe(200)
    expect((await f.admin('/status')).json.state).toBe('stopped')
  })

  it('rejects obsolete providers/unsafe config and cross-site administration and reports missing component without touching LAN', async () => {
    const f = await fixture()
    for (const config of [{ provider: 'origin', publicOrigin: 'https://mobile.example' }, { provider: 'cloudflare' },
      { provider: 'iroh', irohPath: 'host --args' }, { provider: 'iroh', localPort: 80 }, { provider: 'iroh', command: 'sh' }]) {
      expect((await f.admin('/remote/config', config)).status).toBe(400)
    }
    expect((await f.admin('/remote/enable', { enabled: true }, { origin: 'https://evil.example' })).status).toBe(403)
    expect((await f.admin('/remote/enable', { enabled: true }, { host: 'evil.example' })).status).toBe(403)
    expect((await f.admin('/remote/enable', { enabled: true }, { 'sec-fetch-site': 'cross-site' })).status).toBe(403)
    for (const path of ['/remote/config', '/remote/enable', '/remote/pairing', '/pairing', '/enable', '/network', '/renew', '/devices/revoke', '/devices/revoke-all']) {
      expect((await f.admin(path)).status).toBe(405)
    }
    expect((await f.admin('/remote/enable', { enabled: true })).json).toEqual({ error: 'iroh_component_missing' })
    expect(native.spawn).not.toHaveBeenCalled()
    expect((await f.admin('/status')).json).toMatchObject({ state: 'stopped', remote: { state: 'error', verified: false, error: 'iroh_component_missing' } })
    expect((await f.admin('/diagnostics')).json.checks).toContainEqual(expect.objectContaining({ id: 'remote-channel', level: 'error' }))
  })

  it('retires an identity-mismatched native host with a safe error and no published origin', async () => {
    const f = await fixture({ badReady: true })
    const result = await f.start()
    expect(result.status).toBe(502)
    expect(result.json).toEqual({ error: 'iroh_protocol_error' })
    const status = (await f.admin('/status')).json
    expect(status.state).toBe('stopped')
    expect(status.remote).toMatchObject({ state: 'error', error: 'iroh_protocol_error', verified: false })
    expect(status.remote.origin).toBeUndefined()
    expect(status.remote.backendOrigin).toBeUndefined()
    expect(f.children[1]!.closed).toBe(true)
    await expect(f.gateway('/mobile-access-next/health')).rejects.toMatchObject({ code: 'ECONNREFUSED' })
  })

  it('clears published authority, old sessions and unused tokens after unexpected native exit, without losing LAN devices', async () => {
    const f = await fixture(); expect((await f.start()).status).toBe(200)
    const descriptor = (await f.admin('/remote/pairing', {})).json.descriptor
    const pair = await f.gateway('/mobile-access-next/pair', { token: descriptor.gatewayToken })
    expect(pair.status).toBe(201)
    const unused = (await f.admin('/remote/pairing', {})).json.descriptor
    f.children[1]!.finish(1)
    await vi.waitFor(async () => {
      const status = (await f.admin('/status')).json
      expect(status.remote).toMatchObject({ state: 'error', error: 'iroh_process_exited' })
      expect(status.remote.origin).toBeUndefined()
      expect(status.remote.backendOrigin).toBeUndefined()
    }, { interval: 10, timeout: 1000 })
    expect((await f.admin('/remote/enable', { enabled: true })).status).toBe(200)
    expect((await f.gateway('/', undefined, { cookie: cookie(pair) })).status).toBe(401)
    expect((await f.gateway('/mobile-access-next/pair', { token: unused.gatewayToken })).status).toBe(401)
    expect((await f.gateway('/mobile-access-next/renew', { deviceToken: pair.json.deviceToken })).status).toBe(200)
    expect((await f.admin('/renew', { deviceToken: LAN_TOKEN })).status).toBe(200)
    expect((await f.admin('/status')).json.state).toBe('stopped')
  })

  it('reports upstream authentication exchange failure instead of treating pairing as DSH authorization', async () => {
    const f = await fixture({ authFailure: true }); expect((await f.start()).status).toBe(200)
    const descriptor = (await f.admin('/remote/pairing', {})).json.descriptor
    const pair = await f.gateway('/mobile-access-next/pair', { token: descriptor.gatewayToken })
    expect(pair.status).toBe(201)
    const response = await f.gateway('/', undefined, { cookie: cookie(pair) })
    expect(response.status).toBe(502)
    expect(response.text).toContain('upstream auth exchange failed')
    expect(f.seen).toHaveLength(0)
  })
})
