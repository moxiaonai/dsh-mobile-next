# iroh 远程接入（实验性）

本实现只支持 `provider: "iroh"`，不使用域名隧道、Cloudflare 或自建公网反向代理服务。iroh 在网络允许时加密直连，否则可能经 iroh 中继；`running` 只表示本机 native sidecar 和专用网关已准备好，**不证明手机可达、是否直连、是否经过中继或公网验证成功**。状态始终 `verified: false`。

## 安装与显式启停

- 必须先有已安装、与本机平台匹配的 `dsh-mobile-iroh-host` 可执行文件。控制器不下载、不安装、不运行 shell、不执行用户自定义参数。
- 配置只有 `provider: "iroh"`、`irohPath`（绝对可执行路径）和 `localPort`（默认 3445，1024–65535）。允许路径中的空格，因为其始终作为单一 spawn 文件参数，不解释成命令行。
- `initialize()` 只读取配置，绝不启动网络。每次进程启动后均需明确调用 `start()`。`stop()` 与 `close()` 清理专用网关和 sidecar；磁盘不保存 enabled 状态。
- 配置位于父层提供的 `stateDirectory/remote.json`，原子写入、权限 0600。读取已有文件检查用户所有权、0600、常规文件和大小上限，不静默 chmod 修复。损坏/不安全配置只禁用远程接入并返回安全错误码，不阻断独立 LAN 网关。
- Native 身份、TLS 和已配对传输 peer 保存在 `stateDirectory/iroh/`。Native 自身严格校验目录/文件权限和身份完整性；不要通过 chmod 放宽目录、删除身份或替换证书绕过错误。

## 数据通道与 TLS

1. 控制器运行固定 native `tls-prepare --data-dir … --leaf-validity-days 90 --renew-before-days 30`，等待有界 JSON 响应和真实进程 close。
2. 全长 EndpointID 分成两个 32 字符 DNS 标签，逻辑浏览器 origin 为 `https://<前32hex>.<后32hex>.iroh.localhost:<localPort>`。严格绑定身份和端口；不接受用户名、路径、query、hash、其他域名或缩短身份。
3. 父层 `startBackend(context)` 用 native 返回的 CA/leaf/key 路径创建**独立鉴权**的 HTTPS 网关，监听 `127.0.0.1` 或 `::1`。回调必须尊重 `context.signal`，禁止取消后开启迟到的监听器；控制器也会清理迟到结果。
4. 控制器运行固定 `host --data-dir … --proxy-target 127.0.0.1:<port>`。Sidecar 只透传 TLS 字节，TLS 在电脑上的 HTTPS 网关终止；它不改 Host/Origin，不注入 DSH cookie。**没有任何 no-tls-verify 或外部 TLS 绕过。**
5. 手机必须有兼容的原生 iroh transport。普通浏览器、二维码 URL 或现有 HTTPS-only Flutter 客户端无法仅凭 `.iroh.localhost` 域名连通电脑。App 使用本地 TCP listener 接入 iroh 并验证二维码带来的固定 CA/精确身份 hostname。

## 管理层接口

`RemoteController({ stateDirectory, startBackend, stopBackend, access, … })`：

- `configure({ provider: "iroh", irohPath, localPort })`：只允许停止且无待清理资源时配置。
- `status()`：`state` 为 `starting/running/stopped/error`，并含 `enabled/provider/origin/backendOrigin/endpointId/irohPath/localPort/error/verified:false`（可选项只在适用时存在）。不含日志、二维码、6 位码、gateway token、私钥路径或中继路径。
- `start()/stop()/close()`：生命周期串行化。启动有总超时；停止/关闭可取消启动。进程错误、退出、未知事件、非法 UTF-8 和超长 NDJSON 均失败关闭；stdout 每行最多 16 KiB；stderr 直接排空，不保存。
- `startBackend(context)` 的 context 包含 `endpointId/origin/localPort/tls/caFingerprint/signal`。`caFingerprint` 用大写冒号 X509 格式；二维码 `instanceId` 用相同摘要的小写无冒号 64hex。父层独立 AccessController 应设置一致的实例标识。
- `stopBackend()` 必须销毁 remote pairing window 和所有 remote sessions，不能影响 LAN。传输 peer 撤销与 Mobile 设备 token 撤销是两层不同授权。
- `openPairing()` 只能由已认证的桌面管理端调用，返回 `{ descriptor, qrPayload }`。先发送 `device-list` FIFO barrier，再请求新 `pairing-begin` 和新的网关一次性窗口。错误/超时不自动重试，以免旧响应被另一操作使用。

描述符 v1 的字段严格为 `version/type/endpointId/origin/localPort/irohCode/gatewayToken/caCertificate/instanceId/expiresAt`，type 为 `dsh-mobile-iroh-pairing`，CA 为 canonical base64 DER，最大 2200 UTF-8 字节，期限不超过两个窗口和 10 分钟上限。不要记录描述符、二维码、配对码或 gateway token。扫描描述符是用户的带外信任操作；自签 CA 本身不能证明陌生二维码属于目标电脑。

## 测试边界

单元测试使用 dependency-injected 假进程，不启动真实 iroh 端点、不访问公网、不下载依赖。`localOnly: true` 是额外的测试/可信 operator 选项，native 固定参数追加 `--local-only`，默认关闭此选项；它仅适合本地 native 协议 smoke，不代表跨网手机测试。

退出清理等待真实 close，超时升级 SIGTERM→SIGKILL。未确认进程关闭时保留资源句柄并报告 `remote_kill_timeout`，不伪装停止成功，不允许直接重启。启动超时和迟到回调同样不能发布 origin。运维需在测试设备上另行验证真实手机、固定 CA、配对、HTTP/WSS 和跨网拓扑。

协议依据：[upstream sidecar controller](https://github.com/saya-ch/dsh-mobile-iroh/blob/main/src/sidecar-controller.mjs)、[native TLS manager](https://github.com/saya-ch/dsh-mobile-iroh/blob/main/integration/native-tls-manager.mjs)、[pairing descriptor](https://github.com/saya-ch/dsh-mobile-iroh/blob/main/integration/pairing-descriptor.mjs)、[集成接缝](https://github.com/saya-ch/dsh-mobile-iroh/blob/main/docs/INTEGRATION_SEAM.md)。改写实现，未直接复制上游源文件；native/Flutter 分发仍须保留各依赖的 Apache-2.0/MIT 等许可证。
