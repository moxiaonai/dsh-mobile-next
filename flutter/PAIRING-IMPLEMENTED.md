# 配对流程实现

> 状态：**UI 链路已打通，协议语义已验证，但真机端到端配对未验证。**

## 做了什么

| 层 | 文件 | 内容 |
| --- | --- | --- |
| 凭据存储 | `lib/src/auth/credential_store.dart` | `CredentialStore` 接口 + 文件实现 + 内存实现（测试用） |
| 编排 | `lib/src/auth/pairing_flow.dart` | 「解析 → 换凭据 → 保存 → 建连」状态机 + 失败分类 |
| 接线 | `lib/main.dart` | 设备页「添加电脑」→ `PairingPage` → `PairingFlow` |

## 真机验证（已通过）

设备页显示「添加电脑」，点击后配对页正常打开：

```
添加电脑
扫码 | 校验 | 完成          ← 三步步骤条
把电脑上的配对二维码放进框内
[打开相机]
或粘贴配对链接
只连接你自己电脑上的 DSH。配对后手机可操作电脑上的全部会话。   ← 安全文案
```

## 顶部样式优化

初版顶部有三个问题（截图可见）：

| 问题 | 原因 | 修复 |
| --- | --- | --- |
| **没有返回按钮** | 页面被 push 打开，但没给返回入口 | 加 `_TopBar`（返回 + 标题），`onBack` 回调 |
| 标题与步骤条挤在一起 | 两者各自 `Padding`，间距不一致 | 统一为 `_TopBar` + `_StepBar` 两段，间距 `Space.s8` |
| 进度段与标签不对齐 | 进度段 `Expanded` 但标签左对齐 | 标签也 `Expanded` + `TextAlign.center`，与段同宽 |

**真机验证**（坐标）：

```
返回     x=11-126    ← 与标题不重叠
标题     x=126-1043
扫码     x=37-358  (中心 197)
校验     x=379-701 (中心 540)
完成     x=722-1043(中心 882)
```

三个标签中心均匀分布（间距 343/342），全部同高 `y=303-350`。
进度条高 3px（原 4px），只点亮当前段。

**当前步高亮**：标签用 accent 色 + `w600`，已完成步用 secondary，未到步用 tertiary。

## 协议语义（已用正式包验证，见 PAIRING-VERIFY.md）

14/14 通过：一次性 token、摘要存储、凭据完整、可续期。

## 测试

**14 个新测试**，覆盖：

- 二维码载荷解析（`#token=` 与 `#key=dsh1.<id>.<token>` 两种）
- 失败分类：坏链接 / 401 过期 / 403 拒绝 / 网络不通
- 成功时保存凭据、重复配对只保留一条
- 请求发到正确端点 `/mobile-access/auth/native-pair`
- 凭据 CRUD 与同设备覆盖

## ⚠ 三个必须说明的限制

### 1. 凭据存储**不是 Keystore**

当前用 `dart:io` 明文写 `<DSH_HOME>/mobile-client/credentials.json`。

**这是开发用实现**，正式版必须换：
- Android：`EncryptedSharedPreferences` / Keystore
- iOS：Keychain

差别是实质性的：文件可被 root/备份工具读取，Keystore 不可导出。
代码里已加 `assert` 警告，且接口抽象成 `CredentialStore`，替换只改工厂。

### 2. cookie 名是**推测值**

```dart
static String _cookieFromPairing(PairingResult r) =>
    'dsh-mobile-session=${r.sessionToken}; dsh-mobile-csrf=${r.csrfToken}';
```

插件的 `sessionToken` **不是** DSH 的 `dsh-auth-*` cookie，
插件代理层负责换成上游 cookie。这里的 cookie 名 `dsh-mobile-session`
是按插件约定推测的，**需真机配对时确认**。若不对，改动只在这一处。

### 3. 真机端到端配对**未执行**

UI 能打开、协议语义已验证，但「扫码 → 拿到凭据 → 建连成功」
这条完整链路**没在真机跑过**。

原因：需要装 `dsh-mobile` 插件并起网关，会修改用户的 live profile。

## 下一步

1. 装插件到隔离目录，走一次完整配对
2. 确认 cookie 名（上面第 2 点）
3. 验证通过后，移除 `--dart-define=DSH_COOKIE` 调试注入
