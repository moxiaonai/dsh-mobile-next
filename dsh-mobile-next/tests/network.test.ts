/**
 * 测试：网络发现与配置解析。
 */

import { describe, expect, it } from 'vitest'

import {
  parseControlFile,
  parseSetupFile,
  resolveConfig,
} from '../src/config.js'
import {
  cidrContains,
  isAllowedSource,
  isPrivateAddress,
  listCandidates,
} from '../src/network.js'

describe('isPrivateAddress', () => {
  it('识别 RFC1918', () => {
    expect(isPrivateAddress('10.0.0.1')).toBe(true)
    expect(isPrivateAddress('10.255.255.255')).toBe(true)
    expect(isPrivateAddress('172.16.0.1')).toBe(true)
    expect(isPrivateAddress('172.31.255.255')).toBe(true)
    expect(isPrivateAddress('192.168.1.1')).toBe(true)
  })

  it('识别 CGNAT（Tailscale）', () => {
    expect(isPrivateAddress('100.64.0.1')).toBe(true)
    expect(isPrivateAddress('100.127.255.255')).toBe(true)
  })

  it('拒绝公网与相邻段', () => {
    expect(isPrivateAddress('8.8.8.8')).toBe(false)
    expect(isPrivateAddress('172.15.0.1')).toBe(false)
    expect(isPrivateAddress('172.32.0.1')).toBe(false)
    expect(isPrivateAddress('100.63.0.1')).toBe(false)
    expect(isPrivateAddress('100.128.0.1')).toBe(false)
  })

  it('非法输入返回 false', () => {
    expect(isPrivateAddress('not-an-ip')).toBe(false)
    expect(isPrivateAddress('192.168.1')).toBe(false)
    expect(isPrivateAddress('192.168.1.999')).toBe(false)
  })
})

describe('cidrContains', () => {
  it('/24', () => {
    expect(cidrContains('192.168.1.0/24', '192.168.1.55')).toBe(true)
    expect(cidrContains('192.168.1.0/24', '192.168.2.1')).toBe(false)
  })

  it('/8', () => {
    expect(cidrContains('10.0.0.0/8', '10.1.2.3')).toBe(true)
    expect(cidrContains('10.0.0.0/8', '11.0.0.1')).toBe(false)
  })

  it('/32 精确匹配', () => {
    expect(cidrContains('127.0.0.1/32', '127.0.0.1')).toBe(true)
    expect(cidrContains('127.0.0.1/32', '127.0.0.2')).toBe(false)
  })

  it('无前缀视为 /32', () => {
    expect(cidrContains('1.2.3.4', '1.2.3.4')).toBe(true)
    expect(cidrContains('1.2.3.4', '1.2.3.5')).toBe(false)
  })

  it('/0 匹配一切', () => {
    expect(cidrContains('0.0.0.0/0', '8.8.8.8')).toBe(true)
  })

  it('非 8 对齐的前缀', () => {
    // /20 = 255.255.240.0
    expect(cidrContains('192.168.16.0/20', '192.168.31.255')).toBe(true)
    expect(cidrContains('192.168.16.0/20', '192.168.32.1')).toBe(false)
  })
})

describe('isAllowedSource', () => {
  it('回环网段允许本机', () => {
    expect(isAllowedSource(['127.0.0.0/8'], '127.0.0.1')).toBe(true)
  })

  it('IPv4-mapped IPv6 被归一化', () => {
    expect(isAllowedSource(['127.0.0.0/8'], '::ffff:127.0.0.1')).toBe(true)
  })

  it('undefined 地址被拒', () => {
    expect(isAllowedSource(['127.0.0.0/8'], undefined)).toBe(false)
  })

  it('不在网段内被拒', () => {
    expect(isAllowedSource(['192.168.1.0/24'], '10.0.0.1')).toBe(false)
  })
})

describe('listCandidates', () => {
  it('返回的地址不含回环与链路本地', () => {
    const candidates = listCandidates()
    for (const c of candidates) {
      expect(c.address.startsWith('127.')).toBe(false)
      expect(c.address.startsWith('169.254.')).toBe(false)
    }
  })

  it('按分数降序', () => {
    const candidates = listCandidates()
    for (let i = 1; i < candidates.length; i++) {
      expect(candidates[i - 1]!.score).toBeGreaterThanOrEqual(candidates[i]!.score)
    }
  })

  it('排除虚拟网卡', () => {
    const candidates = listCandidates()
    for (const c of candidates) {
      expect(c.interfaceName).not.toMatch(/^(utun|tun|tap|docker|br-|veth)/u)
    }
  })
})

describe('resolveConfig', () => {
  it('空配置用默认值', () => {
    const config = resolveConfig({})
    expect(config.listenPort).toBe(3444)
    expect(config.initiallyEnabled).toBe(false)
    expect(config.tlsMode).toBe('managed')
    expect(config.allowedCidrs).toEqual(['127.0.0.0/8'])
  })

  it('非法端口退回默认', () => {
    expect(resolveConfig({ listenPort: 0 }).listenPort).toBe(3444)
    expect(resolveConfig({ listenPort: -1 }).listenPort).toBe(3444)
    expect(resolveConfig({ listenPort: 70000 }).listenPort).toBe(3444)
    expect(resolveConfig({ listenPort: 1.5 }).listenPort).toBe(3444)
  })

  it('合法端口保留', () => {
    expect(resolveConfig({ listenPort: 8080 }).listenPort).toBe(8080)
  })

  it('非法 tls mode 退回 managed', () => {
    expect(
      resolveConfig({ tls: { mode: 'bogus' as 'managed' } }).tlsMode,
    ).toBe('managed')
  })

  it('initiallyEnabled 只认 true', () => {
    expect(
      resolveConfig({ initiallyEnabled: 'yes' as unknown as boolean })
        .initiallyEnabled,
    ).toBe(false)
  })
})

describe('parseSetupFile', () => {
  it('空值用默认', () => {
    const setup = parseSetupFile(undefined, 3444)
    expect(setup.listenPort).toBe(3444)
    expect(setup.tlsMode).toBe('managed')
    expect(setup.networkInterface).toBeUndefined()
  })

  it('保留合法字段', () => {
    const setup = parseSetupFile(
      { networkInterface: 'en0', listenPort: 9443, tlsMode: 'disabled' },
      3444,
    )
    expect(setup.networkInterface).toBe('en0')
    expect(setup.listenPort).toBe(9443)
    expect(setup.tlsMode).toBe('disabled')
  })

  it('忽略非法字段', () => {
    const setup = parseSetupFile(
      { networkInterface: 123, listenPort: 'abc', tlsMode: 'nope' },
      3444,
    )
    expect(setup.networkInterface).toBeUndefined()
    expect(setup.listenPort).toBe(3444)
    expect(setup.tlsMode).toBe('managed')
  })

  it('数组/字符串输入不崩', () => {
    expect(parseSetupFile([], 3444).listenPort).toBe(3444)
    expect(parseSetupFile('x', 3444).listenPort).toBe(3444)
  })
})

describe('parseControlFile', () => {
  it('缺失时用 initiallyEnabled', () => {
    expect(parseControlFile(undefined, true).enabled).toBe(true)
    expect(parseControlFile(undefined, false).enabled).toBe(false)
  })

  it('只认显式 true', () => {
    expect(parseControlFile({ enabled: true }, false).enabled).toBe(true)
    expect(parseControlFile({ enabled: 'true' }, false).enabled).toBe(false)
    expect(parseControlFile({ enabled: 1 }, false).enabled).toBe(false)
  })
})
