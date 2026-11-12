/**
 * 测试：访问控制与配对。
 *
 * 重点验证**安全不变量**：
 * - 一次性令牌只能消费一次
 * - 只存摘要，不存明文
 * - 过期/错误令牌被拒
 * - 限流生效
 */

import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import { AccessController, AccessError } from '../src/access.js'

const tempDirs: string[] = []

async function makeStore(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'dshmn-'))
  tempDirs.push(dir)
  return join(dir, 'devices.json')
}

afterEach(async () => {
  for (const dir of tempDirs.splice(0)) {
    await rm(dir, { recursive: true, force: true })
  }
})

async function ready(storeFile?: string, options = {}): Promise<AccessController> {
  const access = new AccessController(storeFile, options)
  await access.initialize()
  return access
}

describe('AccessController 配对', () => {
  it('openPairing 返回一次性令牌', async () => {
    const access = await ready()
    const win = await access.openPairing()
    expect(typeof win.token).toBe('string')
    expect(win.token.length).toBeGreaterThan(20)
    expect(win.expiresAt).toBeGreaterThan(Date.now())
    access.close()
  })

  it('正确令牌可配对并返回凭据', async () => {
    const access = await ready()
    const win = await access.openPairing()
    const result = await access.pair('1.2.3.4', win.token, '我的手机')

    expect(result.deviceId).toMatch(/^[0-9a-f]{32}$/u)
    expect(result.deviceToken.length).toBeGreaterThan(20)
    expect(result.sessionToken.length).toBeGreaterThan(20)
    expect(result.deviceExpiresAt).toBeGreaterThan(Date.now())
    access.close()
  })

  it('令牌只能使用一次', async () => {
    const access = await ready()
    const win = await access.openPairing()
    await access.pair('1.2.3.4', win.token)

    await expect(access.pair('1.2.3.4', win.token)).rejects.toBeInstanceOf(AccessError)
    access.close()
  })

  it('错误令牌被拒', async () => {
    const access = await ready()
    await access.openPairing()
    await expect(access.pair('1.2.3.4', 'wrong-token')).rejects.toMatchObject({
      status: 401,
      code: 'authentication_failed',
    })
    access.close()
  })

  it('没有配对窗口时拒绝', async () => {
    const access = await ready()
    await expect(access.pair('1.2.3.4', 'any')).rejects.toMatchObject({
      status: 401,
    })
    access.close()
  })

  it('超长令牌被拒（防 DoS）', async () => {
    const access = await ready()
    await access.openPairing()
    await expect(
      access.pair('1.2.3.4', 'x'.repeat(1000)),
    ).rejects.toMatchObject({ status: 401 })
    access.close()
  })

  it('配对窗口过期后拒绝', async () => {
    let now = 1_000_000
    const access = await ready(undefined, { now: () => now })
    const win = await access.openPairing()
    now += 6 * 60_000 // 超过 5 分钟 TTL
    await expect(access.pair('1.2.3.4', win.token)).rejects.toMatchObject({
      status: 401,
    })
    access.close()
  })

  it('限流：连续错误后返回 429', async () => {
    const access = await ready(undefined, { maxPairingAttempts: 2 })
    await access.openPairing()
    // 前两次是 401
    await expect(access.pair('9.9.9.9', 'bad1')).rejects.toMatchObject({ status: 401 })
    await expect(access.pair('9.9.9.9', 'bad2')).rejects.toMatchObject({ status: 401 })
    // 第三次被限流
    await expect(access.pair('9.9.9.9', 'bad3')).rejects.toMatchObject({ status: 429 })
    access.close()
  })

  it('限流按来源隔离', async () => {
    const access = await ready(undefined, { maxPairingAttempts: 1 })
    await access.openPairing()
    await expect(access.pair('1.1.1.1', 'bad')).rejects.toMatchObject({ status: 401 })
    // 另一个来源不受影响（仍是 401 而不是 429）
    await expect(access.pair('2.2.2.2', 'bad')).rejects.toMatchObject({ status: 401 })
    access.close()
  })
})

describe('AccessController 持久化', () => {
  it('只存令牌摘要，不存明文', async () => {
    const storeFile = await makeStore()
    const access = await ready(storeFile)
    const win = await access.openPairing()
    const result = await access.pair('1.2.3.4', win.token)

    const raw = await readFile(storeFile, 'utf8')
    // 明文 deviceToken 绝不能出现在磁盘上
    expect(raw).not.toContain(result.deviceToken)
    // 但摘要应该在
    expect(raw).toContain('tokenDigest')
    access.close()
  })

  it('重启后设备仍在（可续期）', async () => {
    const storeFile = await makeStore()
    const first = await ready(storeFile)
    const win = await first.openPairing()
    const result = await first.pair('1.2.3.4', win.token)
    first.close()

    const second = await ready(storeFile)
    const renewed = await second.renew(result.deviceToken)
    expect(renewed.deviceId).toBe(result.deviceId)
    expect(renewed.sessionToken.length).toBeGreaterThan(20)
    second.close()
  })

  it('无效 deviceToken 续期被拒', async () => {
    const access = await ready()
    await expect(access.renew('bogus')).rejects.toMatchObject({ status: 401 })
    access.close()
  })

  it('续期不更换 deviceToken', async () => {
    const access = await ready()
    const win = await access.openPairing()
    const result = await access.pair('1.2.3.4', win.token)
    const renewed = await access.renew(result.deviceToken)
    expect(renewed.deviceToken).toBe(result.deviceToken)
    access.close()
  })
})

describe('AccessController 会话', () => {
  it('有效会话可授权', async () => {
    const access = await ready()
    const win = await access.openPairing()
    const result = await access.pair('1.2.3.4', win.token)

    const auth = access.authorize(result.sessionToken)
    expect(auth.deviceId).toBe(result.deviceId)
    access.close()
  })

  it('无令牌 / 空令牌被拒', async () => {
    const access = await ready()
    expect(() => access.authorize(undefined)).toThrow(AccessError)
    expect(() => access.authorize('')).toThrow(AccessError)
    access.close()
  })

  it('伪造会话被拒', async () => {
    const access = await ready()
    expect(() => access.authorize('fake-session')).toThrow(AccessError)
    access.close()
  })

  it('会话过期后拒绝', async () => {
    let now = 1_000_000
    const access = await ready(undefined, {
      now: () => now,
      sessionTtlMs: 60_000,
    })
    const win = await access.openPairing()
    const result = await access.pair('1.2.3.4', win.token)

    now += 61_000
    expect(() => access.authorize(result.sessionToken)).toThrow(AccessError)
    access.close()
  })
})

describe('AccessController 设备管理', () => {
  it('撤销设备后其会话失效', async () => {
    const access = await ready()
    const win = await access.openPairing()
    const result = await access.pair('1.2.3.4', win.token)

    await access.revoke(result.deviceId)

    expect(access.listDevices()).toHaveLength(0)
    expect(() => access.authorize(result.sessionToken)).toThrow(AccessError)
    access.close()
  })

  it('设备数超限被拒', async () => {
    const access = await ready(undefined, { maxDevices: 1 })
    const win1 = await access.openPairing()
    await access.pair('1.1.1.1', win1.token)

    const win2 = await access.openPairing()
    await expect(access.pair('2.2.2.2', win2.token)).rejects.toMatchObject({
      status: 409,
      code: 'too_many_devices',
    })
    access.close()
  })

  it('设备列表不含令牌', async () => {
    const access = await ready()
    const win = await access.openPairing()
    await access.pair('1.2.3.4', win.token, '手机A')

    const devices = access.listDevices()
    expect(devices).toHaveLength(1)
    expect(devices[0]!.label).toBe('手机A')
    expect(JSON.stringify(devices)).not.toContain('tokenDigest')
    access.close()
  })

  it('label 中的控制字符被清理', async () => {
    const access = await ready()
    const win = await access.openPairing()
    await access.pair('1.2.3.4', win.token, 'bad\u0000label\u001f')
    const devices = access.listDevices()
    expect(devices[0]!.label).not.toContain('\u0000')
    access.close()
  })

  it('超长 label 退回默认', async () => {
    const access = await ready()
    const win = await access.openPairing()
    await access.pair('1.2.3.4', win.token, 'x'.repeat(100))
    expect(access.listDevices()[0]!.label).toBe('Mobile device')
    access.close()
  })
})

describe('AccessController 批量撤销与配对窗口', () => {
  it('revokeAll 清空设备并让其会话失效', async () => {
    const access = await ready()
    const a = await access.pair('1.1.1.1', (await access.openPairing()).token, 'A')
    const b = await access.pair('1.1.1.2', (await access.openPairing()).token, 'B')
    expect(access.listDevices()).toHaveLength(2)

    const removed = await access.revokeAll()
    expect(removed).toBe(2)
    expect(access.listDevices()).toHaveLength(0)
    // 会话一并清掉：否则已撤销的手机还能继续用旧 Cookie
    expect(() => access.authorize(a.sessionToken)).toThrow()
    expect(() => access.authorize(b.sessionToken)).toThrow()
    access.close()
  })

  it('revokeAll 在空列表上返回 0 且不抛错', async () => {
    const access = await ready()
    await expect(access.revokeAll()).resolves.toBe(0)
    access.close()
  })

  it('pairingStatus 反映窗口开闭，且不泄露令牌', async () => {
    const access = await ready()
    expect(access.pairingStatus().open).toBe(false)

    const win = await access.openPairing()
    const status = access.pairingStatus()
    expect(status.open).toBe(true)
    expect(status.expiresAt).toBe(win.expiresAt)
    expect(JSON.stringify(status)).not.toContain(win.token)
    access.close()
  })

  it('pairingStatus 在窗口过期后报未开启', async () => {
    let now = 1_000_000
    const access = new AccessController(undefined, { now: () => now })
    await access.initialize()
    const win = await access.openPairing(60_000)
    now = win.expiresAt + 1
    expect(access.pairingStatus().open).toBe(false)
    access.close()
  })
})
