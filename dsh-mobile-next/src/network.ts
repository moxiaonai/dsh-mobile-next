/**
 * 网卡与局域网地址发现。
 *
 * ## 为什么需要
 *
 * 手机要连的是电脑的**局域网 IPv4**，不是 `127.0.0.1`。
 * 但一台电脑常有多个网卡（Wi-Fi、以太网、VPN、Docker 虚拟网卡），
 * 需要：
 * 1. 列出候选
 * 2. 自动挑一个最可能的
 * 3. 让用户能改
 *
 * ## 过滤规则
 *
 * 排除：
 * - 回环（127.0.0.0/8、::1）
 * - 链路本地（169.254.0.0/16）—— DHCP 失败时的自分配地址，通常不可达
 * - 虚拟网卡（`utun`/`tun`/`tap`/`docker`/`br-`/`veth`/`vmnet`/`bridge`）——
 *   这些是 VPN 或容器网络，手机连不上
 *
 * 保留并优先：
 * - `en0`/`en1`（macOS 的 Wi-Fi/以太网）
 * - `eth0`/`wlan0`（Linux）
 * - RFC1918 私有地址段（10/8、172.16/12、192.168/16）
 * - `100.64.0.0/10`（Tailscale 的 CGNAT 段，参考实现也接受）
 */

import { networkInterfaces } from 'node:os'

/** 一个候选地址。 */
export interface NetworkCandidate {
  /** 网卡名，例如 `en0`。 */
  readonly interfaceName: string
  /** IPv4 地址。 */
  readonly address: string
  /** 是否为私有地址（RFC1918 或 CGNAT）。 */
  readonly isPrivate: boolean
  /** 推荐分数，越高越优先。 */
  readonly score: number
}

const VIRTUAL_INTERFACE_PATTERN =
  /^(utun|tun|tap|docker|br-|veth|vmnet|virbr|bridge|llw|awdl)/iu

/** 解析 IPv4 为 4 个字节。 */
function ipv4Bytes(address: string): [number, number, number, number] | undefined {
  const parts = address.split('.')
  if (parts.length !== 4) return undefined
  const bytes: number[] = []
  for (const part of parts) {
    const n = Number(part)
    if (!Number.isInteger(n) || n < 0 || n > 255) return undefined
    bytes.push(n)
  }
  return [bytes[0]!, bytes[1]!, bytes[2]!, bytes[3]!]
}

/** 判断是否私有地址（含 CGNAT）。 */
export function isPrivateAddress(address: string): boolean {
  const bytes = ipv4Bytes(address)
  if (bytes === undefined) return false
  const [a, b] = bytes
  if (a === 10) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  // 100.64.0.0/10（Tailscale / CGNAT）
  if (a === 100 && b >= 64 && b <= 127) return true
  return false
}

/** 判断是否链路本地（169.254/16）。 */
function isLinkLocal(address: string): boolean {
  const bytes = ipv4Bytes(address)
  return bytes !== undefined && bytes[0] === 169 && bytes[1] === 254
}

/** 计算推荐分数。 */
function scoreOf(interfaceName: string, address: string): number {
  let score = 0
  // 私有地址优先
  if (isPrivateAddress(address)) score += 100
  // 常见物理网卡名加分
  if (/^(en[0-9]|eth[0-9]|wlan[0-9]|wl[0-9])/iu.test(interfaceName)) score += 50
  // 虚拟网卡减分
  if (VIRTUAL_INTERFACE_PATTERN.test(interfaceName)) score -= 200
  return score
}

/**
 * 列出所有可用的局域网候选地址。
 *
 * 按推荐分数降序返回；被排除的地址不会出现在结果里。
 */
export function listCandidates(): NetworkCandidate[] {
  const interfaces = networkInterfaces()
  const out: NetworkCandidate[] = []

  for (const [interfaceName, addresses] of Object.entries(interfaces)) {
    if (addresses === undefined) continue
    for (const info of addresses) {
      // 只看 IPv4（Node 的 family 在不同版本里是 'IPv4' 或 4）
      const family = info.family
      const isV4 = family === 'IPv4' || (family as unknown) === 4
      if (!isV4) continue
      if (info.internal) continue
      if (info.address.startsWith('127.')) continue
      if (isLinkLocal(info.address)) continue
      if (VIRTUAL_INTERFACE_PATTERN.test(interfaceName)) continue

      out.push({
        interfaceName,
        address: info.address,
        isPrivate: isPrivateAddress(info.address),
        score: scoreOf(interfaceName, info.address),
      })
    }
  }

  out.sort((a, b) => b.score - a.score)
  return out
}

/** 自动挑选一个最可能的地址。 */
export function pickDefaultCandidate(): NetworkCandidate | undefined {
  return listCandidates()[0]
}

/**
 * 校验一个地址是否仍然存在于本机。
 *
 * 用于启动时确认已保存的网卡没有失效（换 Wi-Fi 后旧地址会消失）。
 */
export function addressStillPresent(address: string): boolean {
  return listCandidates().some((c) => c.address === address)
}

/**
 * 简易 CIDR 匹配（只支持 IPv4 前缀）。
 *
 * 用于 `allowedCidrs` 判定请求来源是否在允许网段内。
 */
export function cidrContains(cidr: string, address: string): boolean {
  const [network, prefixText] = cidr.split('/')
  if (network === undefined) return false
  const netBytes = ipv4Bytes(network)
  const addrBytes = ipv4Bytes(address)
  if (netBytes === undefined || addrBytes === undefined) return false

  const prefix = prefixText === undefined ? 32 : Number(prefixText)
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) return false
  if (prefix === 0) return true

  const fullBytes = Math.floor(prefix / 8)
  const remainingBits = prefix % 8

  for (let i = 0; i < fullBytes; i++) {
    if (netBytes[i] !== addrBytes[i]) return false
  }
  if (remainingBits === 0) return true

  const mask = 0xff << (8 - remainingBits)
  return (netBytes[fullBytes]! & mask) === (addrBytes[fullBytes]! & mask)
}

/** 判断来源地址是否在任一允许网段内。 */
export function isAllowedSource(
  allowedCidrs: readonly string[],
  address: string | undefined,
): boolean {
  if (address === undefined) return false
  // Node 在双栈监听时可能给出 `::ffff:127.0.0.1`
  const normalized = address.startsWith('::ffff:') ? address.slice(7) : address
  return allowedCidrs.some((cidr) => cidrContains(cidr, normalized))
}
