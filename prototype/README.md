# DSH Mobile — 可点击原型

一个**零依赖、零构建**的静态原型，演示「手机接管/监督电脑上正在跑的任务」。
打开文件即可运行，没有 npm install，没有 CDN，没有打包步骤。

实现依据：`docs/00-brief.md`（冻结 IA）、`docs/10-ui-spec.md`（逐屏规格与 token）、
`docs/20-architecture.md`（事件模型与降级口径）、`reference/design-system/dsh-mobile/MASTER.md`（颜色）。

---

## 怎么跑

**方式一：直接打开文件**

```
open prototype/index.html          # macOS
```

`file://` 下已验证可用。脚本全部是经典 `<script>`，不是 ES module（`file://` 会拦模块加载），
所以不需要任何服务器。

**方式二：静态服务器**（想用手机在同一局域网打开时用这个）

```
cd prototype
python3 -m http.server 8080
# 打开 http://127.0.0.1:8080/
```

手机访问时用电脑的局域网 IP，例如 `http://192.168.1.24:8080/`。
桌面浏览器里会自动套一个居中的 430px 手机框；视口宽度 ≤519px 时就是全屏移动布局。

**目标视口**：375 / 390 / 430 宽。原型在桌面浏览器里同样可用。

---

## 一眼看懂能做什么

打开后默认在 **任务 Home**。几秒内模拟事件流就会开始跑：

| 时间 | 会发生什么 | 看哪里 |
| --- | --- | --- |
| ~2s | 工具调用开始流入 | Home 的「进行中」行内 `Read src/...` 会变；进详情看活动条 |
| ~6s | 又一个工具调用 | 活动条的步骤数 +1 |
| ~14s | 一个任务**完成** | 掉到「最近完成」，同时通知中心多一条，并弹 toast |
| ~22s | 电脑上**新开一个任务** | Home 多一条进行中 |
| ~31s | 新任务**抛出一个问题** | 详情页 dock 停靠在输入框上方等你回答 |
| ~46s | **断线 5 秒**再恢复 | 顶部离线横幅 + 时钟冻结 + 按钮文案变「排队提交」 |

不想等的话：**设备页 → 原型 → 原型演示面板**（或按 `d` 键），可以手动触发上面每一个事件，
也能暂停/恢复模拟流。这是原型专用的入口，产品本身没有这个控件。

### 建议的 5 分钟走查路径

1. **Home** — 「需要你」两张卡钉在顶部，每张都能**不滚动**直接回答/审批。
   往下是进行中（实时秒表 + 当前工具调用 + 进度条）和最近完成。
2. 点第一张卡 → **任务详情**：
   - 顶部 sticky header：状态 pill + 延迟 + `⋯`（停止/分叉/打开工作区…）
   - **活动条**：`跟随中` / `已暂停跟随`。往上滑转写 → 变「已暂停跟随」并浮出「回到最新」；
     但**活动条本身仍然实时更新**（暂停的只是转写跟随）。
   - **待处理 dock** 钉在输入框上方，选一个选项 → 提交 → 卡片淡出、回答进转写。
   - 代码块在自己的容器里横滑，右上角有复制按钮。
   - 输入框：有字时是发送，没字且任务在跑时是**停止**。
3. **会话** — 按工作区/已置顶分组，搜索框可筛；每行左滑露出「置顶/静音/归档」，
   行尾 `⋯` 打开**同样动作**的 sheet（滑动手势是加速器，不是唯一入口）。
4. **设备** — 当前电脑卡（可达点 + 延迟 + 证书指纹后 6 位）、其他电脑（远程/已移除）、
   切换电脑、连接诊断、撤销配对。
5. **通知中心**（Home 右上角铃铛）— 六类通知 + 全部；点一条直接深链到对应任务并**自动展开** dock。
6. **配对** — 扫码 → 校验（显示指纹供肉眼比对 + 常驻安全提示）→ 成功。
   还有过期/权限被拒/失败三个分支可点。
7. **浅色/深色** — 每个 tab 页右上角的月亮/太阳图标；偏好写进 localStorage。

---

## 文件地图

```
prototype/
├── index.html              # 外壳：SVG 图标 sprite、tab bar、push 容器、脚本加载顺序
├── styles.css              # 全部样式，按 UI spec 章节编号组织（见下）
├── README.md               # 本文件
├── js/
│   ├── util.js             # DOM 助手、时间格式化、markdown 渲染、发布订阅、调度器
│   ├── data.js             # 种子数据（设备/任务/会话/通知/诊断），形状对齐 TaskSummary
│   ├── store.js            # 唯一状态源 + 具名 action + 选择器（对应架构 §4.4 读模型）
│   ├── sim.js              # 模拟事件流：step / message / pending / done / 断线
│   ├── ui.js               # 共用组件 C01–C40：chip、pill、按钮、搜索、sheet、toast、空状态
│   ├── app.js              # 路由、tab bar、键盘 visualViewport、演示面板
│   └── screens/
│       ├── home.js         # 任务 Home（§5.1）
│       ├── sessions.js     # 会话（§5.2，含 swipe）
│       ├── devices.js      # 设备（§5.3）
│       ├── task.js         # 任务详情（§5.4 + dock §6 + 活动条 §7）
│       ├── inbox.js        # 通知中心（§5.5）
│       ├── pairing.js      # 配对（§5.6）
│       └── settings.js     # 连接诊断（§5.7）+ 外观（§5.8）
└── tests/
    ├── selfcheck.html      # 布局/尺寸/禁用项自检（3 个宽度 × 10 个页面）
    └── behaviourcheck.html # 交互自检（跟随状态机、dock、搜索、离线、主题…）
```

### `styles.css` 的章节编号与 spec 一一对应

| CSS 段落 | 对应 spec |
| --- | --- |
| `§1 DESIGN TOKENS` | `10-ui-spec.md` §2 / §14（**逐值照抄**，未新增任何 token） |
| `§2 RESET & SHELL` | §3 布局系统、§2.7 安全区、§3.3 屏幕外壳 |
| `§3 PRIMITIVES` | §4.1 C01–C12 + C39 tab bar / C40 FAB |
| `§4 HOME` | §5.1（TaskCard / TaskRow / ProgressBar） |
| `§5 SESSIONS` | §5.2（SessionRow + swipe） |
| `§6 DEVICES` | §5.3（DeviceCard / DeviceRow / 可达四态） |
| `§7 TASK DETAIL` | §5.4 + §6 dock + §7 活动条 |
| `§8 INBOX` | §5.5 |
| `§9 PAIRING` | §5.6 |
| `§10 DIAGNOSTICS & APPEARANCE` | §5.7 / §5.8 |
| `§11 STATES` | §8 空 / 错误 / 离线 |
| `§12 LAYERS` | §2.7 层级（scrim → sheet → toast） |
| `§13 RESPONSIVE & MOTION` | §3.1、§2.6、§10 |

代码里的注释用同样方式标注来源，例如 `/* C21 PendingDock (§6) */`，
可以拿 spec 的章节号直接搜代码。

---

## 冻结 IA 的落地方式

- **3 个 tab + 中间 FAB**：`index.html` 的 `.tabbar` 是 `1fr 1fr 56px 1fr` 四轨，
  FAB 绝对定位在中间那轨上。tab 项 ≥44（实测 106×56）。
- **任务详情是 push 面，不是 tab**：进入详情时 `tabbar.hidden = true`，
  底部换成 composer。`Store.state.pushStack` 维护返回栈。
- **切 tab 不丢东西**：三个 tab 面板一直挂载（非活动面板 `hidden`），
  所以滚动位置、草稿、半展开的 dock 都保留（brief 原则 3）。
  push 面切换时会**显式 dispose**（解订阅 + 停 timer），避免旧页面覆盖新页面。

---

## 必须存在的四个「监督感」部件

| 部件 | 位置 | 关键行为 |
| --- | --- | --- |
| **待处理 dock** | 详情页，输入框正上方 | 审批 > 问题 > 计划 的优先级；折叠 56 / 展开 ≤`min(44dvh,360px)`；提交后淡出再移除；键盘打开时强制折叠 |
| **活动条** | header 下方，sticky | 折叠 44 / 展开 ≤`min(40dvh,320px)`；**转写暂停跟随时它仍然实时** |
| **跟随状态机** | 详情页滚动区 | 距底 >48px 暂停、≤8px 恢复（滞回，防抖）；暂停时浮出「回到最新」并累计 `+N` |
| **模拟事件流** | `js/sim.js` | 每 4s 一次工具调用；脚本化的完成 / 新任务 / 提问 / 断线 |

---

## 已验证的约束

下面每一条都跑过自动化断言（`tests/` 里两个 harness，Chrome headless 执行）：

| 约束 | 结果 |
| --- | --- |
| 375 / 390 / 430 下无页面级横向溢出 | `scrollWidth === clientWidth`，三个宽度全通过 |
| 所有可点目标 ≥44×44 | 10 个页面 × 3 个宽度，实测 `getBoundingClientRect()`，0 个不达标 |
| 宽内容只在自己容器里滚 | 代码块 `pre`、chip 条、meta 行均 `overflow-x:auto` + `overscroll-behavior:contain` |
| 首屏预算（§5.1.4） | 375×812 下 2 张「需要你」卡 + 2 条「进行中」全在 tab bar 之上 |
| 每屏一个可见 `h1` | 通过（非活动 tab 面板带 `hidden`，不进可访问树） |
| 输入框 ≥16px | 全局 `input, textarea { font-size: max(16px, 1em) }`，防 iOS 聚焦缩放 |
| 无渐变 / 玻璃 / 发光 | `styles.css` 中 0 处 `gradient`、0 处 `backdrop-filter` |
| 无 emoji 图标 | 全部 inline SVG（`index.html` 的 sprite，24 网格 / stroke 2） |
| 尊重 `prefers-reduced-motion` | 全部过渡归零、脉冲点停用、swipe 无过渡 |
| 无正 `tabindex` | 通过 |
| 四边安全区 | `--sa-top/right/bottom/left` 全部被消费，`viewport-fit=cover` |
| `file://` 直接打开可运行 | 通过（无 ES module、无 fetch 依赖、无 CORS 资源） |

跑测试：

```
cd prototype
python3 -m http.server 8080
# 浏览器打开 http://127.0.0.1:8080/tests/selfcheck.html
#          http://127.0.0.1:8080/tests/behaviourcheck.html
```

两个页面会把结果打印在 iframe 下方（需要 http:// 而不是 file://，因为要跨文档取样式表）。

---

## 原型里刻意做的取舍

这些地方在 spec 里有更完整的要求，原型做了简化，**不是遗漏**：

1. **没有真实网络层**。`sim.js` 直接产出「效果」，没有伪造 WS/SSE 帧格式
   （架构 §4.1 明确那些帧格式是 `ASSUMPTION`，伪造会误导实现方）。
2. **没有真相机**。配对取景框是静态框，点「打开相机」直接走模拟的权限→校验→成功。
3. **没有真实语音**。麦克风按钮给一段固定转写，因为原型不采集音频。
4. **延迟是档位**（`延迟约 12ms`），不是伪精确值；拿不到就不显示（对应 A6）。
5. **进度条固定 40% 填充** + `aria-valuetext="进行中，已 N 步"`，
   不假装知道百分比（对应 A10）。
6. **审批卡**用「允许一次 / 始终允许 / 拒绝」三档纵向堆叠，并在正文里原样显示待执行命令
   （对应 A5 的降级口径）；命令含 `DROP`/`rm` 时加危险条。
7. **离线快照只保留「有多少事」**，不保留标题正文（架构 §7.3 的刻意取舍）。
   原型里标题仍在内存中，但离线横幅与冻结时钟表达同一件事：数据是旧的。
8. **诊断的「手机路径」永远是 info**，即使电脑侧全绿也显示「未在手机上验证」。
9. **已撤销/已过期配对不用红色**，用灰色 + 删除线（红色只表示失败）。
10. **列表行用「覆盖式按钮」**（`.hit` 绝对定位铺满整行），而不是 `role="button"` 里嵌
    真按钮——后者是无效 ARIA，读屏会把同一个动作念两遍。

---

## 已知限制

- 深色模式跟随系统时，切换系统主题需要页面保持前台；后台标签页里 `matchMedia` 的
  change 事件会被节流，这是浏览器行为。
- `visualViewport` 键盘判定阈值 120px，只在真机或浏览器设备模拟器里有意义；
  桌面浏览器不会触发，属预期。
- 滑动删除用的是 Pointer Events，鼠标拖拽也能触发，方便桌面走查。

---

**Frontend Developer** · 2026-11-10 · 对应 `docs/10-ui-spec.md` v1 与 `docs/20-architecture.md` v1
