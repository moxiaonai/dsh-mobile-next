# 启用 iroh 远程通道（macOS）

## 1. 原生组件（已构建）

```
$REPO/native/target/release/dsh-mobile-iroh-host
```

这是本机 arm64 自建产物（不是官方发布件）。重建：

```sh
./native/scripts/build-macos.sh
```

## 2. 在移动访问面板里配置

打开 DSH 的 **移动访问** → 左栏 **远程通道**：

| 字段 | 值 |
| --- | --- |
| iroh sidecar 组件绝对路径 | `$REPO/native/target/release/dsh-mobile-iroh-host` |
| 本地专用网关端口 | `3445`（默认；只用于回环，不是公网端口） |

点 **保存配置** → **开启 iroh 远程通道**。状态变成「本地就绪」只表示本机 sidecar 与专用网关起来了。

## 3. 配对

点 **生成 iroh 配对二维码**，用支持原生 iroh 的 Android 完整版 App 扫描；
或点 **复制 iroh 配对描述符** 粘贴到 App。描述符是 JSON，**不是网址**，普通浏览器打不开。

## 4. 手机端

```sh
cd flutter
flutter build apk --debug        # 已包含两个 ABI 的 iroh 原生库
```

重装 APK 后即可扫码。`flutter/android/app/src/main/jniLibs/{arm64-v8a,x86_64}/` 里的 `.so` 由
`native/iroh-android/build-android.sh` 生成，需要时重建：

```sh
rustup target add aarch64-linux-android x86_64-linux-android
ANDROID_NDK_HOME=/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358 \
  bash native/iroh-android/build-android.sh arm64-v8a
ANDROID_NDK_HOME=/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358 \
  bash native/iroh-android/build-android.sh x86_64
```

## 5. 已知边界

- 只支持 Android；iOS/普通浏览器不支持 iroh 描述符。
- `running` / 本地就绪 **不代表**手机跨网可达、也不代表直连成功（可能走中继）。
- 全局 VPN/TUN、fake-IP DNS 可能干扰 iroh 直连与中继。
- 远程通道与局域网各自独立启停、独立配对；关闭远程只清远程会话，不影响局域网。
