# DSH Mobile — Flutter 传输层

方案 1（Flutter 原生 + WebView 混合）的**传输层**。已用真实运行中的 DSH 实例验证。

## 状态

| 项 | 状态 |
| --- | --- |
| 静态分析 | ✅ `dart analyze` 无问题 |
| 单元测试 | ✅ 87/87 通过（含 55 个 widget 测试） |
| 端到端联调 | ✅ 6/6 通过（对真实 DSH） |
| 配对流程 | ✅ 协议语义已验证（14/14，见 [PAIRING-VERIFY.md](PAIRING-VERIFY.md)） |
| 安卓 WebView | ✅ 定向会话验证通过（见 [ANDROID-DEBUG.md](ANDROID-DEBUG.md)） |
| 任务中心 | ✅ 数据层 + 实时推送 + UI（安卓/macOS 双平台，见 [JOBS-VERIFY.md](JOBS-VERIFY.md)） |
| 需要你区 | ✅ 真实待答问题验证通过（见 [QUESTIONS-VERIFY.md](QUESTIONS-VERIFY.md)） |
| 审批 | ✅ approve/deny 双路径验证通过（见 [APPROVALS-VERIFY.md](APPROVALS-VERIFY.md)） |
| 任务输出流 | ✅ `job/follow` 真实拉取验证通过（见 [APPROVALS-VERIFY.md](APPROVALS-VERIFY.md)） |
| 8 个屏幕 | ✅ 全部实现，5 个主 tab 安卓真机验证（见 [SCREENS-VERIFY.md](SCREENS-VERIFY.md)） |
| iroh 远程通道 | 🧪 原生传输 + 严格 TLS 已接入（桌面插件见 [remote-access.md](../dsh-mobile-next/docs/remote-access.md)）；尚未做真机跨网验证 |

## iroh 远程通道（实验性）

配对二维码里是 **JSON 描述符**（`type: dsh-mobile-iroh-pairing`），不是网址。App 收到后：

1. `IrohPairingMaterial.parse` 严格校验字段、CA 的 base64 DER 规范编码与 64 位指纹、六位码、43 字符 gateway token、期限（≤10 分钟）。
2. 通过 Android `MethodChannel('dsh_mobile/iroh')` 建原生 iroh 传输：QUIC 加密直连，打不通走中继；本机只开 `127.0.0.1:<localPort>` 回环 TCP，字节原样转发。
3. Dart `HttpClient` 的 `connectionFactory` 只连回环，但 **TLS 仍以逻辑 hostname 握手**（`SecureSocket.secure(host: ...)`），只信任描述符带来的 CA —— 证书不是自签就算数，必须过 SAN 与链校验。
4. WebView 走 Android PKIX 独立校验（`verifyCertificate`）：只信该 CA、精确 DNS SAN、有效期、当前 requestId 与 native `ready` 同时成立才 `PROCEED`；旧 LAN 的“签发者名字匹配”路径**不用于 iroh**。
5. 配对成功后仍走原有设备 token / renew 流程；传输元数据是可选的，旧 LAN 记录不受影响。

构建原生库（需已装 NDK 与 Rust 目标）：

```sh
rustup target add aarch64-linux-android x86_64-linux-android
ANDROID_NDK_HOME=/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358 \
  bash ../native/iroh-android/build-android.sh arm64-v8a
ANDROID_NDK_HOME=/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358 \
  bash ../native/iroh-android/build-android.sh x86_64
flutter build apk --debug
```

**边界**：只支持 Android；`本地就绪`不等于手机跨网可达；全局 VPN/TUN 与 fake-IP DNS 可能干扰直连/中继；尚未在真机上验证跨网拓扑。

## 快速验证

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd flutter

dart pub get
dart analyze          # 静态检查
dart test             # 16 个协议单测
dart run tool/e2e_smoke.dart   # 端到端（需 DSH Desktop 运行中）
```

端到端实测输出：

```
STEP 1 — 铸造浏览器会话 cookie        ✅ 读到 32 字节 HMAC 密钥 / 发现 DSH
STEP 2 — unary 载具                   ✅ session/list 返回 77 个会话
STEP 3 — WebSocket 载具               ✅ 已连接 /api/remote.mux
STEP 4 — $events generation 握手      ✅ 收到 ready 帧（含 clientId、host.home）
STEP 5 — 双载具路由                    ✅ unary 端点走 mux 被拒
SUMMARY  6 passed · 0 failed
```

## 架构

```
lib/src/
├── protocol/
│   ├── frames.dart      帧定义与严格校验（对应官方 stream-protocol.js）
│   └── session.dart     会话操作 + 双载具路由 + 冷会话激活
├── transport/
│   ├── unary.dart       HTTP unary 载具（POST /api/<endpoint>）
│   ├── mux.dart         WebSocket 流载具（/api/remote.mux）+ 退避重连
│   ├── connection.dart  编排：先 unary 探活，再连 mux，等 $events ready
│   └── io_transport.dart dart:io 实现（可替换为 Flutter 平台实现）
└── auth/
    └── pairing.dart     二维码解析 + native-pair / native-renew
```

**设计要点**：传输层只依赖 `HttpTransport` 与 `MuxSocket` 两个抽象，
因此能在**纯 Dart VM 下跑单测**，不需要 Flutter 运行时或模拟器。

## 双载具（这是最容易做错的地方）

协议有两条互不相通的载体，走错就失败：

| 载体 | 承载 | 端点 | 走错的表现 |
| --- | --- | --- | --- |
| `POST /api/<endpoint>` | unary | `session/list`、`session/prompt`、`session/state`… | 走 mux → `gateway/signature-invalid` |
| `WS /api/remote.mux` | 流式 | `$events`、`session/follow`、`job/list`… | 走 HTTP → 404 |

`SessionController` 把差异收在内部，上层不必关心。

## 联调中发现的四个真实陷阱

这些都是**纸面设计没覆盖、只有真跑才会暴露**的：

### 1. `session/list` 必须带 `_request`

传空 args 会被拒：
```
gateway/arguments-invalid: args fields do not match the descriptor: missing "_request"
```
正确写法：`{'args': {'_request': {}}}`。

### 2. `$events` 必须带空 `args` 对象

传空 payload 会被拒：
```
gateway/arguments-invalid: forwarded Remote event stream requires an empty args object
```
正确写法：`payload: {'args': {}}`。

### 3. WebSocket 升级必须显式带 `Host` 头

WebSocket 升级同样要过 `assertExternalTrust`（`gateway.ts:4391`），
而 `dart:io` 的 `WebSocket.connect` **不会**自动补 `Host`。
不带的直接后果是 401。

### 4. scheme 必须从 origin 推导

`http://` 对应 `ws://`，`https://` 对应 `wss://`。
写死 `wss` 会让本地 http 实例直接连接失败。

## 冷会话陷阱（已在代码里处理）

对一个**没有活 Agent** 的会话直接 `session/prompt`，服务端返回
`{"accepted": true}` 然后**什么都不做** —— 无错误、无事件。

`SessionController.prompt()` 会先调 `ensureActive()`，即
`session/follow {activate: true}`，并等到 opening 帧才算激活成功。

重连后必须调用 `resetActivation()`：服务端的活 Agent 绑定已随 socket 失效，
不清缓存会让下一次 prompt 跳过激活而静默失败。`DshConnection` 已在
`MuxState.connected` 时自动处理。

## 退避重连

按官方阶梯（`dsh-client-connection`）：

```
cap(n)   = min(10000, 500 * 2^(n-1))     → 500, 1000, 2000, 4000, 8000, 10000, 10000…
delay(n) = cap/2 + rand * (cap/2)        → 50%–100% 抖动
```

⚠️ **等待时长是抖动的**。断言 `delay == cap` 会让测试在真机上随机失败，
应断言 `cap/2 ≤ delay ≤ cap`（单测已覆盖边界）。

## 配对流程（已验证协议语义）

`auth/pairing.dart` 按插件的 `native-pair` / `native-renew` 契约实现，
协议语义已用 **npm 正式包 `dsh-mobile@0.8.6`** 的编译产物验证，14/14 通过。

验证方式：从正式包逐字节截取 `src/access.ts` 的编译段，直接实例化
`AccessController` 跑全链路。见 [PAIRING-VERIFY.md](PAIRING-VERIFY.md)。

已确认的四条关键语义：

| 语义 | 含义 |
| --- | --- |
| 一次性 token | 二维码泄露后不可重复利用 |
| 摘要存储 | 持久化状态不含明文 deviceToken |
| 凭据完整 | 手机可独立认证，无需文件系统访问 |
| 可续期 | Host 重启后无需重新配对 |

**仍未验证**：手机端通过真实 HTTP 调用 `native-pair` 的网络往返
（需装插件并起网关，会修改 live profile）。但协议语义与 HTTP 传输层
都已分别验证过。

**重要**：`sessionToken` **不是** DSH 的 `dsh-auth-*` cookie。
插件持有上游凭据并代理注入，手机永远看不到 DSH 密钥。

## 规划项完成情况

| # | 规划项 | 状态 |
| --- | --- | --- |
| 1 | 传输层（双载具 + 重连） | ✅ |
| 2 | 数据类生成（150 端点 → 66 类） | ✅ |
| 3 | WebView 容器（定向会话） | ✅ |
| 4 | 任务中心（`job/list` + 实时 + UI） | ✅ |
| 5 | 「需要你」区（提问） | ✅ |
| 6 | 审批（approve / deny） | ✅ |
| 7 | 任务输出流（`job/follow`） | ✅ |
| 8 | 配对协议 | ✅ |
| 9 | 端到端联调 | ✅ |

## 后续可扩展（未在本次规划内）

1. **终端** —— `terminal/attach` 流
2. **文件浏览** —— `workspaceFiles/*`
3. **会话行 Swipe 动作** —— spec 允许，已有「…」等价路径
4. **正式版清理** —— 移除调试用的 `--dart-define=DSH_COOKIE` 注入路径
5. **真机配对往返** —— 装插件到隔离目录做一次完整配对
