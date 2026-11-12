/**
 * 包入口：导出公开 API。
 *
 * 只导出**需要被测试或外部引用**的符号。
 * 内部模块（如 `gateway` 的私有辅助函数）不导出，减少 API 面。
 */

import pluginFn from './plugin.js'

export { pluginFn as plugin }
export { name, inject } from './plugin.js'

/**
 * 默认导出。
 *
 * DSH 的 loader 可能按默认导出取插件函数；只给具名导出会导致
 * `plugin is undefined`（实测踩过）。两种都给，兼容两种约定。
 */
export default pluginFn
export type { PluginContext } from './plugin.js'

export { AccessController, AccessError } from './access.js'
export type {
  AccessOptions,
  PairingResult,
  SessionAuthorization,
} from './access.js'

export {
  resolveConfig,
  parseSetupFile,
  parseControlFile,
  loadPersistedState,
  stateDirectoryOf,
} from './config.js'
export type {
  ControlFile,
  PluginConfig,
  ResolvedConfig,
  SetupFile,
  TlsMode,
} from './config.js'

export { LanGateway, AUTH_PREFIX, SESSION_COOKIE } from './gateway.js'
export { UpstreamAuth, UpstreamAuthError } from './upstream-auth.js'
export type { GatewayInfo, GatewayOptions, GatewayState } from './gateway.js'

export { createAdminRoutes, ADMIN_PREFIX } from './admin.js'
export type { AdminDeps, AdminRoute } from './admin.js'

export {
  listCandidates,
  pickDefaultCandidate,
  addressStillPresent,
  isPrivateAddress,
  isAllowedSource,
  cidrContains,
} from './network.js'
export type { NetworkCandidate } from './network.js'

export {
  ensureTlsMaterial,
  readTlsMaterial,
  fingerprintOf,
  shortFingerprint,
  stableId,
} from './tls.js'
export type { TlsFiles, TlsMaterial } from './tls.js'

export { RemoteController } from './remote.js'
