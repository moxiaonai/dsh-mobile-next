/**
 * 私有 CA 与服务器证书。
 *
 * ## 为什么需要自签
 *
 * 局域网内没有公网域名，无法申请受信任证书。DSH 的做法是**自带私有 CA**：
 * - 插件生成一个长期 CA（10 年）
 * - 用它签发短期服务器证书（含网卡 IP 的 SAN）
 * - 手机首次配对时**固定该 CA 指纹**，之后只信任这一个 CA
 *
 * 这比"忽略证书错误"安全得多：手机明确知道该信任谁。
 *
 * ## ⚠ 一个真实的实现陷阱
 *
 * 最初用 `selfsigned.generate()` 生成服务器证书，测试报
 * `self-signed certificate`（客户端不信任）。查源码发现：
 *
 * ```js
 * cert.sign(keyPair.privateKey, ...)   // 用自己的私钥签，永远是自签
 * ```
 *
 * `selfsigned` **不支持用现有 CA 签发** —— 它只会生成自签证书。
 * 必须改用 `node-forge` 手动构造并 `cert.sign(caPrivateKey, ...)`，
 * 同时把 issuer 设为 CA 的 subject，否则链验证失败。
 *
 * 这个坑只有在"客户端真正校验证书链"时才会暴露；
 * 如果测试里 `rejectUnauthorized: false`，永远发现不了。
 */

import { X509Certificate, createHash } from 'node:crypto'
import type * as NodeForge from 'node-forge'

/** node-forge 的运行时类型（由 deps.ts 懒加载）。 */
type ForgeModule = typeof NodeForge
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

import { loadForge } from './deps.js'

/** 证书文件集合。 */
export interface TlsFiles {
  readonly caCertFile: string
  readonly caKeyFile: string
  readonly serverCertFile: string
  readonly serverKeyFile: string
}

/** 生成结果。 */
export interface TlsMaterial {
  readonly files: TlsFiles
  /** CA 证书的 SHA-256 指纹（冒号分隔大写十六进制）。 */
  readonly caFingerprint: string
  /** 服务器证书的 SAN 列表。 */
  readonly sans: readonly string[]
}

const CA_DAYS = 3650
const SERVER_DAYS = 397
const KEY_BITS = 2048

function fileNames(directory: string): TlsFiles {
  return {
    caCertFile: join(directory, 'ca.pem'),
    caKeyFile: join(directory, 'ca-key.pem'),
    serverCertFile: join(directory, 'server-cert.pem'),
    serverKeyFile: join(directory, 'server-key.pem'),
  }
}

/** 计算证书指纹（SHA-256，冒号分隔大写）。 */
export function fingerprintOf(pem: string): string {
  return new X509Certificate(pem).fingerprint256
}

/** 生成一对 RSA 密钥。 */
function generateKeyPair(forge: ForgeModule): NodeForge.pki.rsa.KeyPair {
  return forge.pki.rsa.generateKeyPair(KEY_BITS)
}

/** 生成私有 CA 证书。 */
function createCa(forge: ForgeModule): { certPem: string; keyPem: string } {
  const keys = generateKeyPair(forge)
  const cert = forge.pki.createCertificate()
  cert.publicKey = keys.publicKey
  cert.serialNumber = `01${forge.util.bytesToHex(forge.random.getBytesSync(8))}`
  cert.validity.notBefore = new Date()
  cert.validity.notAfter = new Date()
  cert.validity.notAfter.setDate(cert.validity.notBefore.getDate() + CA_DAYS)

  const attrs = [
    { name: 'commonName', value: 'dsh-mobile-next Private CA' },
    { name: 'organizationName', value: 'dsh-mobile-next' },
  ]
  cert.setSubject(attrs)
  // 自签：issuer = subject
  cert.setIssuer(attrs)
  cert.setExtensions([
    { name: 'basicConstraints', cA: true, critical: true },
    {
      name: 'keyUsage',
      keyCertSign: true,
      cRLSign: true,
      critical: true,
    },
    { name: 'subjectKeyIdentifier' },
  ])
  // CA 自签：用自己的私钥
  cert.sign(keys.privateKey, forge.md.sha256.create())

  return {
    certPem: forge.pki.certificateToPem(cert),
    keyPem: forge.pki.privateKeyToPem(keys.privateKey),
  }
}

/**
 * 用 CA 签发服务器证书。
 *
 * 关键点：
 * - `setIssuer(ca.subject.attributes)` —— issuer 必须是 CA 的 subject
 * - `cert.sign(caPrivateKey)` —— 用 CA 私钥签名
 * - SAN 必须含实际访问的 IP
 */
function createServerCert(
  forge: ForgeModule,
  caCertPem: string,
  caKeyPem: string,
  addresses: readonly string[],
): { certPem: string; keyPem: string } {
  const caCert = forge.pki.certificateFromPem(caCertPem)
  const caKey = forge.pki.privateKeyFromPem(caKeyPem)

  const keys = generateKeyPair(forge)
  const cert = forge.pki.createCertificate()
  cert.publicKey = keys.publicKey
  cert.serialNumber = `02${forge.util.bytesToHex(forge.random.getBytesSync(8))}`
  cert.validity.notBefore = new Date()
  cert.validity.notAfter = new Date()
  cert.validity.notAfter.setDate(cert.validity.notBefore.getDate() + SERVER_DAYS)

  cert.setSubject([
    {
      name: 'commonName',
      value: addresses[0] ?? 'dsh-mobile-next.local',
    },
    { name: 'organizationName', value: 'dsh-mobile-next' },
  ])
  // ⚠ 必须是 CA 的 subject，否则链验证失败
  cert.setIssuer(caCert.subject.attributes)

  const extensions: Array<Record<string, unknown>> = [
    { name: 'basicConstraints', cA: false, critical: true },
    {
      name: 'keyUsage',
      digitalSignature: true,
      keyEncipherment: true,
      critical: true,
    },
    { name: 'extKeyUsage', serverAuth: true },
  ]
  if (addresses.length > 0) {
    extensions.push({
      name: 'subjectAltName',
      altNames: addresses.map((ip) => ({ type: 7, ip })),
    })
  }
  cert.setExtensions(extensions as Parameters<typeof cert.setExtensions>[0])

  // ⚠ 用 CA 私钥签，不是自己的
  cert.sign(caKey, forge.md.sha256.create())

  return {
    certPem: forge.pki.certificateToPem(cert),
    keyPem: forge.pki.privateKeyToPem(keys.privateKey),
  }
}

/**
 * 确保证书存在且覆盖给定地址。
 *
 * - CA 不存在 → 生成
 * - 服务器证书不存在 / 过期 / SAN 不覆盖 → 用现有 CA 重签
 *
 * **CA 不变是关键**：手机已固定的 CA 继续有效，用户不必重新配对。
 */
export async function ensureTlsMaterial(
  directory: string,
  addresses: readonly string[],
  options: { readonly force?: boolean } = {},
): Promise<TlsMaterial> {
  await mkdir(directory, { recursive: true })
  const files = fileNames(directory)

  const caExists = existsSync(files.caCertFile) && existsSync(files.caKeyFile)
  let caCertPem: string
  let caKeyPem: string

  if (caExists && options.force !== true) {
    caCertPem = await readFile(files.caCertFile, 'utf8')
    caKeyPem = await readFile(files.caKeyFile, 'utf8')
  } else {
    const forge = await loadForge()
    const ca = createCa(forge)
    caCertPem = ca.certPem
    caKeyPem = ca.keyPem
    await writeFile(files.caCertFile, caCertPem, 'utf8')
    await writeFile(files.caKeyFile, caKeyPem, {
      encoding: 'utf8',
      mode: 0o600,
    })
  }

  // 判断现有服务器证书是否可用
  let needServer = options.force === true
  if (!needServer && existsSync(files.serverCertFile) && existsSync(files.serverKeyFile)) {
    try {
      const existing = await readFile(files.serverCertFile, 'utf8')
      const cert = new X509Certificate(existing)
      const notAfter = Date.parse(cert.validTo)
      const expiringSoon =
        Number.isFinite(notAfter) && notAfter - Date.now() < 7 * 86_400_000
      const covered = addresses.every((ip) => cert.checkIP(ip) !== undefined)
      // 还要确认它确实由当前 CA 签发（换 CA 后旧证书失效）
      const signedByCa = cert.checkIssued(new X509Certificate(caCertPem))
      needServer = expiringSoon || !covered || !signedByCa
    } catch {
      needServer = true
    }
  } else {
    needServer = true
  }

  if (needServer) {
    const server = createServerCert(await loadForge(), caCertPem, caKeyPem, addresses)
    // 只写叶子证书，不把 CA 附在链里。
    //
    // 两种错误都实测过：
    // - 只给叶子、客户端不传 ca  → "unable to verify the first certificate"
    // - 叶子 + 自签 CA 一起给     → "self-signed certificate in certificate chain"
    //
    // 正确做法：服务器只发叶子证书，客户端通过 `ca:` 显式信任私有 CA。
    // 手机端同理 —— 配对时固定 CA 指纹，之后用它校验。
    await writeFile(files.serverCertFile, server.certPem, 'utf8')
    await writeFile(files.serverKeyFile, server.keyPem, {
      encoding: 'utf8',
      mode: 0o600,
    })
  }

  return {
    files,
    caFingerprint: fingerprintOf(caCertPem),
    sans: addresses,
  }
}

/** 读取现成的 TLS 材料（不生成）。 */
export async function readTlsMaterial(directory: string): Promise<
  | {
      readonly cert: string
      readonly key: string
      readonly caPem: string
      readonly caFingerprint: string
    }
  | undefined
> {
  const files = fileNames(directory)
  try {
    const [cert, key, caPem] = await Promise.all([
      readFile(files.serverCertFile, 'utf8'),
      readFile(files.serverKeyFile, 'utf8'),
      readFile(files.caCertFile, 'utf8'),
    ])
    return { cert, key, caPem, caFingerprint: fingerprintOf(caPem) }
  } catch {
    return undefined
  }
}

/** 证书短指纹（前 6 位十六进制，去掉冒号），用于界面上人眼比对。 */
export function shortFingerprint(fingerprint: string): string {
  return fingerprint.replaceAll(':', '').slice(0, 6).toUpperCase()
}

/** 由任意文本派生的稳定短标识（用于 instanceId）。 */
export function stableId(seed: string): string {
  return createHash('sha256').update(seed).digest('hex').slice(0, 32)
}
