# DSH Mobile

[English](README.en.md) · 简体中文

> 在手机上接管和监管运行在电脑上的 DeepSeek Harness 任务。

[![CI](https://github.com/moxiaonai/dsh-mobile-next/actions/workflows/ci.yml/badge.svg)](https://github.com/moxiaonai/dsh-mobile-next/actions/workflows/ci.yml)

DSH Mobile 由三部分组成：一个 **DSH 插件**（电脑端，发布到 npm）、一个 **Flutter 客户端**（Android，含 iOS PWA 路径）、以及一套 **Rust 原生传输层**（iroh，实验性）。插件在电脑上开一个带设备配对认证的 HTTPS 网关，手机通过局域网或加密远程通道接入，拿到的是**真实的 DSH 页面**加上一层移动布局。

这不是「把桌面聊天界面缩小」。手机在这里是 agent 的**寻呼机**：一屏看清什么需要你、一键批准、语音或文字纠偏，完整转写按需展开。

---

## 目录

- [架构](#架构)
- [组件](#组件)
- [快速开始](#快速开始)
- [协议契约](#协议契约)
- [安全模型](#安全模型)
- [开发](#开发)
- [已知限制](#已知限制)
- [第三方代码与许可证](#第三方代码与许可证)

---

## 架构

```
┌─────────────────────────────┐
│  手机                        │
│  ┌───────────────────────┐  │
│  │ Flutter 客户端         │  │
│  │ · 传输层（unary+mux）  │  │
│  │ · 配对 / 凭据存储      │  │
│  │ · 任务中心 / 审批 UI   │  │
│  └──────────┬────────────┘  │
└─────────────┼───────────────┘
              │ HTTPS（局域网）
              │ 或 QUIC（iroh 远程，实验性）
┌─────────────▼───────────────┐
│  电脑                        │
│  ┌───────────────────────┐  │
│  │ dsh-mobile-next 插件   │  │
│  │ · 网关（TLS + 配对）   │  │
│  │ · 设备令牌 / CSRF      │  │
│  │ · 上游凭据代理注入      │  │
│  └──────────┬────────────┘  │
│  ┌──────────▼────────────┐  │
│  │ DSH（默认 :3080）      │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

关键设计：**插件不修改 DSH 源码**。它以 Host 插件形式插入 loader 树，注入 `webServer` 与 `connection` 两个服务，反向代理到本机 DSH 端口，并在返回的页面里注入移动布局层。

---

## 组件

| 目录 | 内容 | 技术栈 | 规模 |
| --- | --- | --- | --- |
| [`dsh-mobile-next/`](dsh-mobile-next/) | DSH 插件，发布到 npm | TypeScript + React | 5,472 行 |
| [`flutter/`](flutter/) | Android 客户端 | Dart / Flutter | 17,854 行 |
| [`native/`](native/) | iroh 原生传输层（实验性） | Rust | 7,041 行 |
| [`prototype/`](prototype/) | 零依赖可点击原型 | 原生 HTML/CSS/JS | — |
| [`design/`](design/) | 品牌资产与图标 | SVG / PNG | — |

### 插件（`dsh-mobile-next`）

npm 包名 `dsh-mobile-next`，当前 `0.2.0`，MIT。运行时依赖只有两个：`node-forge`（证书）和 `qrcode`（配对二维码）。

提供两条互相独立的通道：

- **局域网** —— 手机通过局域网 HTTPS 访问电脑，带设备配对认证，插件自签私有 CA。
- **远程（iroh，实验性）** —— 加密直连优先、中继兜底，不需要域名或公网端口。需要本机原生组件与支持 iroh 的 App。

```bash
cd dsh-mobile-next
pnpm install
pnpm run typecheck
pnpm test
pnpm run build
```

### 客户端（`flutter/`）

传输层刻意保持**零运行时网络依赖**：`HttpTransport` / `MuxSocket` 是自建抽象，因此能在纯 Dart VM 下跑单测，不需要模拟器。

```
lib/src/
├── protocol/     帧定义、会话操作、双载具路由
├── transport/    unary / mux / 连接编排 / iroh
├── auth/         配对、凭据存储、iroh 描述符
├── ui/           10 个页面
└── webview/      会话 WebView 与注入脚本
```

### 原生传输（`native/`）

三个 Rust crate：`iroh-core`（共享核心）、`iroh-host`（桌面 sidecar）、`iroh-android`（Android 传输）。Host 是**已认证的字节载体**，不是 HTTP/TLS 终结者 —— TLS 在电脑上的 HTTPS 网关终止，授权仍由网关拥有。

```bash
./native/scripts/build-macos.sh
./native/scripts/test-native.sh
```

---

## 快速开始

### 前置要求

| 项 | 版本 |
| --- | --- |
| Node.js | ≥ 20 |
| pnpm | 10+ |
| DSH | `>=0.2.2-rc.1 <0.3.0-0` |
| Flutter（仅客户端） | Dart SDK `^3.13.0` |
| Rust（仅原生传输） | 已安装工具链 |

插件的 `engines.dsh` 是**兼容性闸门**：DSH 版本不匹配时安装会被拒绝（`incompatible-version`），而不是装完运行时报错。

### 1. 安装插件

```bash
# 从 registry（发布后）
dsh plugin --profile desktop add dsh-mobile-next@0.2.0

# 或从源码打包后安装（离线 / 内网）
cd dsh-mobile-next
pnpm pack
dsh plugin --profile desktop add ./dsh-mobile-next-0.2.0.tgz
```

也可以在 DSH 的 **设置 → 插件 → 安装** 里填包名或本地路径。

### 2. 开启局域网访问

打开 DSH 侧栏的 **移动访问** 面板：

1. 点「开启局域网访问」。
2. 面板会**自动**生成配对二维码（无需再点一次）。
3. 用手机扫码配对。

默认只监听回环 `127.0.0.0/8`，且 `initiallyEnabled: false` —— 装完不会自动对外监听，必须显式开启。

### 3. 构建客户端

```bash
cd flutter
dart pub get
dart analyze
dart test
flutter build apk --debug
```

---

## 协议契约

**接口契约由插件方拥有，客户端只消费。** 两端的路径参数是可配置的（`pairPath` / `renewPath`），不是硬编码。

### 手机可达的路由（`/mobile-access-next/*`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/pair` | 配对页 HTML |
| `POST` | `/pair` | 用一次性令牌换取设备凭据 |
| `GET` | `/health` | 健康检查 |
| `POST` | `/renew` | 用设备令牌换新会话（冷启动重连必经） |

**其余 `/mobile-access-next/*` 路径一律 404，绝不透传。** 这是安全边界：`/pairing`（签发新令牌）、`/devices/revoke`（踢设备）这类电脑本机专属操作绝不能暴露给手机。

### 电脑本机专属的管理路由

| 路径 | 用途 |
| --- | --- |
| `/status` | 网关状态 |
| `/diagnostics` | 诊断信息 |
| `/network` | 网卡候选 |
| `/enable` | 启停网关 |
| `/pairing` | 生成配对窗口 |
| `/devices` | 已配对设备列表 |
| `/devices/revoke` | 撤销单个设备 |
| `/devices/revoke-all` | 撤销全部设备 |
| `/remote/{config,enable,pairing}` | iroh 远程通道管理 |

### 客户端消费的 DSH 协议

DSH 有**两条互不相通的载具**，走错就失败：

| 载具 | 承载 | 端点 | 走错的表现 |
| --- | --- | --- | --- |
| `POST /api/<endpoint>` | unary | `session/list`、`session/prompt`… | 走 mux → `gateway/signature-invalid` |
| `WS /api/remote.mux` | 流式 | `$events`、`session/follow`、`job/list`… | 走 HTTP → 404 |

四个只有真跑才会暴露的陷阱（都已在代码里处理）：

1. `session/list` 必须带 `_request`，传空 args 会被拒。
2. `$events` 必须带空 `args` 对象。
3. WebSocket 升级必须显式带 `Host` 头 —— `dart:io` 的 `WebSocket.connect` 不会自动补。
4. scheme 必须从 origin 推导：`http`→`ws`，`https`→`wss`。

---

## 安全模型

| 机制 | 实现 |
| --- | --- |
| 设备配对 | 一次性令牌（扫码泄露后不可复用），换取长期设备令牌 |
| 令牌存储 | 只存摘要，持久化状态不含明文 `deviceToken` |
| TLS | 插件自签私有 CA，客户端**固定**该 CA（不是「自签就算数」） |
| 上游凭据 | 插件持有 DSH 凭据并代理注入 `dsh-auth-*` Cookie，手机永远看不到 |
| 写操作 | CSRF 令牌 |
| Origin 校验 | 精确 Origin 匹配 |
| WebSocket | 按精确路径白名单 |
| 默认关闭 | `initiallyEnabled: false` + 只监听回环 |

**重要**：手机拿到的 `sessionToken` **不是** DSH 的 `dsh-auth-*` cookie。两者是不同的授权层。

iroh 通道额外要求：QUIC 用 EndpointId 认证并提供传输层重放保护；TLS 在电脑上的网关终止，Host 只透传字节；不存在任何 `no-tls-verify` 或外部 TLS 绕过。

---

## 开发

### 测试

| 组件 | 测试 | 状态 |
| --- | --- | --- |
| 插件 | 12 个文件 / 140 个用例 | ✅ **147 passed, 2 skipped**（`pnpm test` 实测） |
| 原生 | `iroh-core` + `iroh-host` | ✅ **56 passed, 0 failed**（`cargo test` 实测） |
| 客户端 | 29 个文件 / 291 个用例 | `flutter analyze` 无问题；`flutter test` 在 CI 中执行 |

```bash
cd dsh-mobile-next && pnpm test          # 插件
cd native && cargo test -p dsh-mobile-iroh-core -p dsh-mobile-iroh-host
cd flutter && flutter analyze && flutter test
```

> Android crate（`native/iroh-android`）只面向 Android 目标构建，
> 因此宿主机侧的 `cargo test` / `cargo clippy` 只跑默认成员。

### 插件验证脚本

```bash
cd dsh-mobile-next
node scripts/verify-patch.mjs      # cordis patch 求值
node scripts/verify-client.mjs     # 客户端 bundle 导出
node scripts/verify-package.mjs    # tarball 可独立安装并加载
```

`prepublishOnly` 会串起 typecheck → test → build → verify-package，发布前自动把关。

### 发版

**推荐：打 tag 触发 CI 自动发布（Trusted Publishing，无需任何 token）**

```bash
cd dsh-mobile-next
npm version minor          # 同时更新 package.json 与 git tag
git push --follow-tags
```

CI 的 `publish` job 只在 `v*` tag 时运行，通过 GitHub OIDC 向 npm 换取短时凭据，
并自动附加 provenance 证明。发布前会校验 tag 与 `package.json` 版本一致，不一致则失败。

**首次配置**（每个包只需一次）：

1. 打开 https://www.npmjs.com/package/dsh-mobile-next/access
2. Trusted Publisher → GitHub Actions
3. 填 Organization/User `moxiaonai`、Repository `dsh-mobile-next`、Workflow `ci.yml`

配置后**不要再配 `NPM_TOKEN`**。npm 已宣布 2027 年 1 月起禁止 bypass-2FA token
直接发布，OIDC 是官方替代方案。

**手动发布**（应急）：需要带 bypass 2FA 的 granular token，且该 token 每次发布都要
过 OTP；`npm publish` 前确保 `~/.npmrc` 不指向内网 registry，或加
`--registry=https://registry.npmjs.org`。

### Android release 签名

仓库**不包含 keystore**。没有 `flutter/android/key.properties` 时，`release`
构建类型复用 debug 签名——产物仅供测试，不能分发或上架。

生成本地 keystore（**请自行保管，不要提交**）：

```bash
keytool -genkeypair -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

在 `flutter/android/key.properties` 写入（该文件已被 gitignore）：

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

之后 `flutter build apk --release` 即产出签名包。

**CI 中启用**：在仓库 Settings → Secrets 添加四个 secret，APK job 会自动切到
release 签名，否则仍构建 debug 包（fork 与 PR 也能拿到可测产物）。

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i upload-keystore.jks \| pbcopy` 的结果 |
| `ANDROID_KEYSTORE_PASSWORD` | storePassword |
| `ANDROID_KEY_ALIAS` | keyAlias |
| `ANDROID_KEY_PASSWORD` | keyPassword |

---

## 已知限制

- **iroh 远程通道是实验性的**。状态里的 `running` 只表示本机 sidecar 和专用网关就绪，**不证明手机可达、是否直连或是否经过中继**。状态始终 `verified: false`。
- **CA 是每台电脑各生成一份的**。把 CA 打进 APK 意味着这个包只信任「打包时那台电脑」；换电脑需重新打包，或改为由配对二维码动态携带 CA 指纹。
- **iOS 走 PWA 路径**，不分发原生 iOS App。
- **Flutter 客户端尚未做跨网真机验证**。全局 VPN / TUN 与 fake-IP DNS 可能干扰 iroh 直连/中继。
- **Android 原生库需自行构建**。`jniLibs/` 下的 `.so` 未入库（每个约 19 MB），复现方式见 [`native/iroh-android/build-android.sh`](native/iroh-android/build-android.sh)。
- **release 签名是可选的，默认回退到 debug**。仓库不包含 keystore；没有 `flutter/android/key.properties` 时，`release` 构建类型复用 debug 签名，产物仅供测试，不能分发。配置方式见下方「Android release 签名」。

---

## 第三方代码与许可证

本仓库主体为 **MIT**（见 [LICENSE](LICENSE)），但**包含第三方代码**，边界如下：

| 位置 | 来源 | 许可证 |
| --- | --- | --- |
| [`native/iroh-host/`](native/iroh-host/)、[`native/iroh-core/`](native/iroh-core/) | 改编自 [saya-ch/dsh-mobile-iroh](https://github.com/saya-ch/dsh-mobile-iroh) | MIT |
| [`native/iroh-android/`](native/iroh-android/) | 同上 + [zexadev/dsh-tether](https://github.com/zexadev/dsh-tether) | MIT / Apache-2.0 |
| 参考实现 | [saya-ch/dsh-mobile](https://github.com/saya-ch/dsh-mobile) | Apache-2.0 |

原始许可证与 NOTICE 保留在 [`native/licenses/`](native/licenses/)。**根 MIT 许可证不替代这些导入部分的许可证。**

> 参考项目 `saya-ch/dsh-mobile` 仅作为协议与约束的**研究参考**，其代码未复制进本仓库的 `flutter/` 与 `dsh-mobile-next/`。
