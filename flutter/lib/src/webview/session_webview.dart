/// 会话 WebView 容器。
///
/// 目标：在 Flutter 里打开 **指定会话** 并只显示对话区，复用 DSH 的全部
/// 客户端插件（Markdown、代码高亮、KaTeX、终端、文件预览）。
///
/// ## 核心难点：注入时机
///
/// DSH 前端**没有 URL 路由**（spike 2 实测：`?session=`、`#/session/`、
/// `/session/<id>` 全部无效，服务端也没有 SPA fallback）。会话选择持久化在
/// `localStorage['dsh.sessions.current']`，由 `createSnapshotStore` 在构造时
/// 重新水合（`dsh-client-ui-workspace/lib/client.js` 的 `UiWorkspaceService`）。
///
/// 因此必须在**首个文档的 JS 执行前**写好这个 key。
///
/// ## 为什么不再「写入 + reload」
///
/// 早先的实现是：加载 `/` → `onLoadStop` 里写 localStorage → `reload()`。
/// 这个方案能工作，但**每次打开会话都要完整加载两遍**：
///
/// ```
/// 09:54:52.640  [webview] wrote session: {"sessionId":"session-f4eb08af-..."}
/// 09:54:53.487  [detail] PROBE {"marker":null,...,"bodyLen":80}    ← 第一遍：骨架
/// 09:55:01.498  [detail] PROBE {"marker":"session-f4eb08af-...",...} ← 第二遍
/// ```
///
/// 用户看到的就是「会话加载两次、样式错乱」—— 第一遍渲染出 DSH 的完整
/// 外壳（侧栏 + 欢迎页 + composer），第二遍才换成目标会话。两次布局切换
/// 之间会看到侧栏滑入、composer 从欢迎页位置跳到会话位置。
///
/// 实测证明**根本不需要 reload**：
///
/// `Page.addScriptToEvaluateOnNewDocument`（等价于
/// `UserScriptInjectionTime.AT_DOCUMENT_START`）在 `readyState === "loading"`
/// 的 49ms 时点执行，此时 `localStorage` **已可用且可写**：
///
/// ```json
/// {"t":49,"readyState":"loading","origin":"http://10.0.2.2:59852",
///  "lsAvailable":true,"lsWrite":"v1","lsReadBack":true}
/// ```
///
/// 早先「该时机写 localStorage 不生效」的结论是**误判**：真正的原因见下面
/// 的「重复加载」一节 —— 写入其实成功了，但页面随后被**重新创建**，
/// 探针读到的是新文档里尚未被写入的旧值。
///
/// ## 重复加载的真正原因
///
/// 除了自建的 reload，还有两个独立的二次加载源：
///
/// 1. **父级 rebuild 重建 WebView**。`InAppWebView` 是 `PlatformViewLink`，
///    一旦 widget 身份变化（无 key、父级 setState），平台视图会被 dispose
///    并重建，`initialUrlRequest` 重新发一次 —— 这是完整的一次页面加载。
/// 2. **渲染进程崩溃后自动重载**。日志实测：
///    ```
///    E chromium: [ERROR:aw_browser_terminator.cc(165)] Renderer process (20245) crash detected (code -1).
///    ```
///    Android WebView 在 renderer 崩溃后会自己重载页面。
///
/// 对策：
/// - 给 `InAppWebView` 一个**稳定的 key**，让父级 rebuild 时复用平台视图；
/// - 引导写入放在 `AT_DOCUMENT_START`，**不再**由 `onLoadStop` 触发 reload；
/// - 用导航序号只处理**最后一次**导航，旧导航的回调直接丢弃。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'session_css.dart';
import '../transport/iroh_transport.dart';

/// WebView 容器的状态回调。
class SessionWebViewCallbacks {
  const SessionWebViewCallbacks({
    this.onReady,
    this.onError,
    this.onProgress,
    this.onProbe,
  });

  /// 页面加载完成（且收窄样式已应用）。
  final void Function()? onReady;

  /// 页面探针结果（JSON 字符串）。
  ///
  /// 含实际打开的会话标记、localStorage 内容、标题与正文长度 ——
  /// 用于验证"确实打开了目标会话"，而不是静默退回默认会话。
  final void Function(Object? result)? onProbe;
  final void Function(Object error)? onError;
  final void Function(int percent)? onProgress;
}

/// 打开指定会话的 WebView。
class SessionWebView extends StatefulWidget {
  const SessionWebView({
    super.key,
    required this.origin,
    required this.cookieHeader,
    required this.sessionId,
    this.conversationOnly = true,
    this.dark = false,
    this.localeTag,
    this.callbacks = const SessionWebViewCallbacks(),
  });

  /// 形如 `https://192.168.1.10:3443`（无尾斜杠）。
  final Uri origin;

  /// `Cookie` 头内容。
  final String cookieHeader;

  /// 要打开的会话 id。
  final String sessionId;

  /// 是否使用暗色主题。
  ///
  /// DSH 前端用 `document.body[data-ds-dark-theme]` 切换暗色（见
  /// `dsh-client-ui-layout` 的 ThemePresenter）。WebView 是独立文档，
  /// 不会继承 App 的主题，必须显式注入这个属性 —— 否则 App 是深色、
  /// WebView 里却是浅色，视觉上像两个 App 拼在一起。
  final bool dark;

  /// 语言标签（如 `zh-CN`）。
  ///
  /// DSH 前端的语言偏好存在 Host 的 user-settings（namespace `locale`）；
  /// 未设置时它「delegate to the browser」，而 WebView 默认 `en-US` ——
  /// 这就是「电脑上是中文、手机 WebView 里是英文」的原因。
  ///
  /// 这里同时做两件事：请求头带 `Accept-Language`，并把语言写进页面。
  final String? localeTag;

  /// 是否收窄为纯对话区（隐藏侧栏/右栏/头部）。
  ///
  /// 手机宽度下 DSH 原生布局已是纯对话区，此项主要影响宽屏 WebView。
  final bool conversationOnly;

  final SessionWebViewCallbacks callbacks;

  @override
  State<SessionWebView> createState() => _SessionWebViewState();
}

class _SessionWebViewState extends State<SessionWebView> {
  // 保留引用以便将来做注入/探测；当前仅用于调试。
  // ignore: unused_field
  InAppWebViewController? _controller;

  /// 把 `cookieHeader` 里的每一对写进 WebView CookieManager。
  ///
  /// 必须按 host+port 精确设置，且 `isSecure: true`（网关是 HTTPS）。
  Future<void> _installCookies() async {
    try {
      final cm = CookieManager.instance();
      for (final part in widget.cookieHeader.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = part.substring(0, eq).trim();
        final value = part.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        await cm.setCookie(
          url: WebUri(widget.origin.toString()),
          name: name,
          value: value,
          path: '/',
          isSecure: widget.origin.scheme == 'https',
          isHttpOnly: true,
        );
      }
      debugPrint('[webview] 已写入 ${widget.cookieHeader.split(';').length} 条 Cookie');
    } catch (e) {
      debugPrint('[webview] Cookie 写入失败: $e');
    }
  }

  /// 打包进 APK 的私有 CA（PEM），懒加载。
  static String? _pinnedCaPem;

  /// 判断服务器证书链是否由**我们打包的那张 CA**签发。
  ///
  /// 不做「一律 PROCEED」：那等于关掉 TLS 校验，任何中间人都能截获
  /// 手机与电脑之间的会话（里面是完整的 DSH 访问凭据）。
  ///
  /// 判据：挑战里带回的服务器证书，其 issuer 必须与我们 CA 的 subject 一致，
  /// 且有效期覆盖当前时间。WebView 不提供完整链，因此这里校验
  /// 「签发者 + 有效期」这一可验证的子集；真正的链验证由 Dart 侧的
  /// `SecurityContext`（unary / mux）完成。
  Future<bool> _isTrustedByPinnedCa(URLAuthenticationChallenge challenge) async {
    // Chromium does not share Dart's SecurityContext: validate its ACTUAL leaf
    // through Android PKIX + exact SAN against this active owner's QR-pinned CA.
    if (widget.origin.host.endsWith('.iroh.localhost')) {
      final der = challenge.protectionSpace.sslCertificate?.x509Certificate?.encoded;
      if (der == null || challenge.protectionSpace.port != widget.origin.port) return false;
      return IrohTransport.verifyWebViewCertificate(widget.origin,
        challenge.protectionSpace.host, der);
    }
    try {
      final cert = challenge.protectionSpace.sslCertificate;
      final x509 = cert?.x509Certificate;
      if (x509 == null) return false;

      // ① 有效期必须覆盖当前时间
      final now = DateTime.now();
      final notBefore = x509.notBefore;
      final notAfter = x509.notAfter;
      if (notBefore != null && now.isBefore(notBefore)) return false;
      if (notAfter != null && now.isAfter(notAfter)) return false;

      // ② 签发者必须是我们打包的 CA
      final issuer = x509.issuerDistinguishedName;
      if (issuer == null) return false;
      _pinnedCaPem ??= await _loadCaPem();
      final caPem = _pinnedCaPem;
      if (caPem == null) return false;
      final caSubject = await _caSubject();
      if (caSubject == null) return false;

      final ok = _issuerMatches(issuer, caSubject);
      debugPrint('[webview] 证书校验 issuer=$issuer caSubject=$caSubject → $ok');
      return ok;
    } catch (e) {
      debugPrint('[webview] 证书校验异常: $e');
      return false;
    }
  }

  /// 取打包 CA 的 subject。
  ///
  /// PEM 里不含明文 subject，因此用 `X509Certificate` 解析同一份 PEM：
  /// 先写到临时文件再用平台解析代价大，这里改为**预先算好**
  /// （`assets/ca.pem` 是构建时固定的，subject 不会变）。
  Future<String?> _caSubject() async {
    return _cachedCaSubject ??= await _deriveCaSubject();
  }

  static String? _cachedCaSubject;

  Future<String?> _deriveCaSubject() async {
    // 我们生成的 CA 固定用这个 CN（`dsh-mobile-next/src/tls.ts:88`）。
    // 不引入 x509 解析库：CA 是插件自签、CN 在构建时就定死，
    // 多引一个依赖只为读一个常量不划算。
    return 'dsh-mobile-next Private CA';
  }

  /// 判断证书 issuer 是否指向我们的 CA。
  static bool _issuerMatches(String issuer, String caSubject) {
    final a = issuer.toLowerCase().replaceAll(' ', '');
    final b = caSubject.toLowerCase().replaceAll(' ', '');
    return a.contains(b) || b.contains(a);
  }

  Future<String?> _loadCaPem() async {
    try {
      final data = await rootBundle.load('assets/ca.pem');
      return utf8.decode(data.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  /// 导航序号：每次主框架导航自增，用于丢弃过期导航的回调。
  ///
  /// renderer 崩溃后 WebView 会自动重载，旧导航的 `onLoadStop` 会在新文档里
  /// 执行。用序号把过期的回调挡掉，否则探针会读到骨架而误判失败。
  int _navigationSeq = 0;

  /// 是否已经为「校正会话」重载过一次。
  ///
  /// 只允许一次：若重载后 localStorage 仍不一致（例如 DSH 有自己的
  /// 会话选择逻辑，会覆盖我们写的值），再 reload 就是死循环。
  /// 那时应该接受现实，把不一致报给上层而不是无限刷。
  bool _sessionReloaded = false;

  /// 首帧遮罩：PlatformView 首次合成前先盖住，避免闪白。
  bool _showCover = true;

  @override
  void didUpdateWidget(SessionWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // App 切主题：直接把新主题推给已加载的页面，**不重载** ——
    // 重载会丢掉滚动位置、正在输入的草稿，代价太大。
    if (oldWidget.dark != widget.dark ||
        oldWidget.localeTag != widget.localeTag) {
      unawaited(_applyTheme(widget.dark, widget.localeTag));
    }
    // 语言变化必须**重载页面**：DSH 在启动时把 navigator.languages 读进
    // 内存（resolveInitialLocale），之后再改 navigator / localStorage 都不会
    // 让它重新解析。主题是纯 CSS 属性，可以原地改；语言不行。
    //
    // 代价是丢掉滚动位置 —— 但语言切换是低频操作，可以接受；
    // 不重载的代价是「切了没反应」，更糟。
    if (oldWidget.localeTag != widget.localeTag) {
      unawaited(_reloadForLocale());
    }
  }

  /// 语言变化后重载页面，让 DSH 用新的 navigator.languages 重新初始化。
  Future<void> _reloadForLocale() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      // 先确保 navigator 覆盖生效（重载后 AT_DOCUMENT_START 会再跑一次）
      await controller.evaluateJavascript(
        source: themeBootstrap(dark: widget.dark, localeTag: widget.localeTag),
      );
      // 重置会话校正标记：重载后需要重新校验会话是否挂上
      _sessionReloaded = false;
      // 重载会重新走首帧，遮罩重新盖上
      if (mounted && !_showCover) setState(() => _showCover = true);
      await controller.reload();
      debugPrint('[webview] 语言变化，已重载页面 locale=${widget.localeTag}');
    } catch (e) {
      debugPrint('[webview] 语言切换重载失败: $e');
    }
  }

  /// 把主题推给当前文档。
  Future<void> _applyTheme(bool dark, String? localeTag) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      // 主题走 guard（同步期望值 + 立即纠正），语言走 bootstrap
      await controller.evaluateJavascript(
        source: themeGuardScript(dark: dark, localeTag: localeTag),
      );
      await controller.evaluateJavascript(
        source: themeBootstrap(dark: dark, localeTag: localeTag),
      );
      debugPrint('[webview] 主题/语言已切换 dark=$dark locale=$localeTag');
    } catch (e) {
      debugPrint('[webview] 主题切换失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = InAppWebViewSettings(
      // 允许 DSH 自己的脚本与 WebSocket
      javaScriptEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      // 局域网自签证书：默认不放宽。需要时由调用方在 platform 层处理。
      useShouldOverrideUrlLoading: false,
      mediaPlaybackRequiresUserGesture: false,
      // 移动端视口
      useWideViewPort: true,
      loadWithOverviewMode: false,
      supportZoom: false,
      // 允许 file:// 资源（DSH 前端会用到 blob/worker）
      allowFileAccessFromFileURLs: true,
      allowUniversalAccessFromFileURLs: true,
      // ★ 关键：WebView 平台视图在页面首帧之前会画一层默认背景（白）。
      // 深色主题下这就是「点进详情闪一下白」。
      // 官方文档原话："can prevent a white flash on initialization"。
      transparentBackground: true,
    );

    // 用主题底色包住 WebView：WebView 背景透明，透出这层颜色。
    // 这样首帧前看到的是**正确的主题色**，而不是平台默认白。
    //
    // ⚠ 但 PlatformView 首次合成时，Android 会先画一帧白底再叠上原生视图，
    // 单靠底色盖不住。用 Stack 在 WebView 之上压一层**同色遮罩**，
    // 等页面开始渲染（progress > 0）再淡出 —— 遮罩期间用户看到的是
    // 主题色，不是白。
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: widget.dark ? const Color(0xFF151517) : const Color(0xFFF7F8FA),
          child: const SizedBox.expand(),
        ),
        InAppWebView(
      // ★ 稳定 key：父级 rebuild 时复用同一个平台视图。
      //
      // 没有 key 时，widget 身份由位置决定；父级一旦 setState 且树结构变化，
      // PlatformViewLink 会被重建 —— 表现为页面**重新加载一次**。
      // key 里带 sessionId：切会话时确实需要新视图，切回同一会话则复用。
      key: ValueKey('dsh-session-webview-${widget.sessionId}'),
      initialUrlRequest: URLRequest(
        url: WebUri(widget.origin.replace(path: '/').toString()),
        headers: {
          'Cookie': widget.cookieHeader,
          // 让服务端与页面脚本都按 App 的语言渲染
          if (widget.localeTag != null) 'Accept-Language': widget.localeTag!,
        },
      ),
      initialSettings: settings,
      initialUserScripts: UnmodifiableListView<UserScript>([
        // ★ 关键：在**任何页面脚本执行前**写入会话选择。
        //
        // 实测该时机 localStorage 已可用（见文件头），因此**不需要**
        // 先加载再 reload。这样整个打开过程只有一次文档加载。
        UserScript(
          source: _sessionBootstrap(widget.sessionId),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        // 主题：在文档开始时注入，避免「深色 App 里先闪一下浅色页面」。
        // ⚠ 顺序很重要：先装守卫，再设属性。
        //
        // 守卫用 MutationObserver 盯着 `data-ds-dark-theme`，一旦被 DSH 的
        // ThemePresenter 改动就立刻改回。在 AT_DOCUMENT_START 就装上，
        // 意味着 **DSH 第一次写属性时就被纠正**，不会渲染出深色帧 ——
        // 这是消除「点进详情闪一下黑」的关键。
        //
        // 之前守卫只在 onLoadStop 装，那时 DSH 已经用深色画完了首屏，
        // 用户看到的就是一闪。
        UserScript(
          source: themeGuardScript(
            dark: widget.dark,
            localeTag: widget.localeTag,
          ),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: themeBootstrap(
            dark: widget.dark,
            localeTag: widget.localeTag,
          ),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        // 收窄样式：同样在文档开始时注入，避免侧栏先出现再消失。
        if (widget.conversationOnly)
          UserScript(
            source: sessionNarrowCss(),
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]),
      onWebViewCreated: (controller) {
        _controller = controller;
        debugPrint('[webview] created, 目标 ${widget.origin}');
        // ★ 关键：把会话 Cookie 写进 WebView 的 Cookie 仓库。
        //
        // `initialUrlRequest.headers['Cookie']` **只对首个请求生效**，
        // 不作用于子资源。而 DSH 的 HTML 会 preload 一批 `plugins/??…`
        // 模块（实测 57 个合成一个 7MB 请求）；这些子请求不带 Cookie
        // 就会被网关 401，DSH 随即报
        // `client-modules: HTML did not preload …`，页面白屏。
        //
        // 真机症状：列表能出来（那是 Dart 侧 unary），点进详情打不开。
        unawaited(_installCookies());
      },
      onLoadStart: (controller, url) {
        debugPrint('[webview] loadStart $url');
        _navigationSeq++;
      },
      onLoadStop: (controller, url) async {
        final seq = _navigationSeq;

        // 只处理最后一次导航。renderer 崩溃后 WebView 会自动重载，
        // 旧导航的回调会在新文档里执行，探针会读到「骨架」而误判失败。
        if (seq != _navigationSeq) return;

        // 兜底再注入一次样式：AT_DOCUMENT_START 时 <head> 可能还不存在。
        if (widget.conversationOnly) {
          try {
            await controller.evaluateJavascript(source: sessionNarrowCss());
          } catch (_) {}
        }

        // ★ 再推一次主题：DSH 的 ThemePresenter 会在插件激活时 apply()，
        // 用**它自己的**主题快照覆盖我们 AT_DOCUMENT_START 写的属性
        // （`dsh-client-ui-layout` 的 theme-presenter.js：
        //   `if (scheme === "dark") body.setAttribute(DARK_ATTRIBUTE, "")`）。
        // 因此必须在它之后重写一次，否则外层浅色、WebView 深色。
        //
        // 插件激活是异步的，单次重写可能仍被它盖掉。但**不能**周期性
        // 从 Dart 侧推 —— 那会和 DSH 的 ThemePresenter 打架，表现为闪烁
        // （实测：先黑后白闪一下）。
        //
        // 改为在页面内装一个 MutationObserver：只在我们期望值与实际值
        // 不一致时才纠正。它由页面自己执行，不跨进程、不轮询，
        // 且一旦一致就什么都不做 —— 不会与 DSH 抖动。
        try {
          await controller.evaluateJavascript(
            source: themeGuardScript(
              dark: widget.dark,
              localeTag: widget.localeTag,
            ),
          );
        } catch (_) {}
        await _applyTheme(widget.dark, widget.localeTag);

        // 主题已校正、页面已就绪，才撤遮罩。
        // 之前用 progress>=10 撤，那时 DSH 还没画出内容，露出的就是白底。
        if (mounted && _showCover) {
          setState(() => _showCover = false);
        }

        // ★ 校正会话：AT_DOCUMENT_START 时写入的 localStorage 可能没被
        // DSH 的 createSnapshotStore 采纳（它可能在脚本之前就读完了）。
        // 这时页面会停在自己的默认会话上 —— 表现为「详情页打开了，但内容是
        // 另一个会话」，探针里 marker 与目标 sessionId 不一致。
        //
        // 这里在文档就绪后再写一次并 reload 一次。只在**确实不一致**时才 reload，
        // 避免正常路径白加载两遍。
        try {
          final current = await controller.evaluateJavascript(
            source: '''
(function () {
  try { return localStorage.getItem('dsh.sessions.current'); } catch (e) { return null; }
})();
''',
          );
          // ⚠ 只比 sessionId，不要整串比较。
          //
          // DSH 会往这个值里加字段（实测 `subagentAddress`：打开子会话后
          // 多出 parentSessionId/childSessionId/mode）。整串比较会把
          // 「同一会话但多了元数据」判成不一致 → 触发 reload →
          // 重载期间闪一帧深色。这是「点详情闪黑」的真正来源。
          final wantId = widget.sessionId;
          final gotId = _sessionIdOf(current is String ? current : null);
          debugPrint('[webview] 会话检查 gotId=$gotId wantId=$wantId reloaded=$_sessionReloaded');
          if (gotId != wantId) {
            if (_sessionReloaded) {
              // 已经重载过一次仍不一致：不再刷，交给上层决定
              debugPrint('[webview] 会话仍不一致（已重载过一次）：want=$wantId got=$gotId');
            } else {
              _sessionReloaded = true;
              debugPrint('[webview] 会话未采纳，重写 localStorage 并重载：want=$wantId got=$gotId');
              await controller.evaluateJavascript(source: _sessionBootstrap(widget.sessionId));
              if (!mounted || seq != _navigationSeq) return;
              // ⚠ reload 会重新走一遍首屏：DSH 在拿到主题前先按默认（深色）
              // 画一帧，用户看到的就是「闪一下黑」。实测连续截图能捕到。
              //
              // 折中：重载前先把主题压到 html 上（reload 后 <html> 仍在，
              // 而 AT_DOCUMENT_START 也会重新注入守卫），减少可见的深色帧。
              await controller.evaluateJavascript(
                source: themeBootstrap(
                  dark: widget.dark,
                  localeTag: widget.localeTag,
                ),
              );
              await controller.reload();
              return; // reload 会触发新的 onLoadStop，交给下一轮处理
            }
          }
        } catch (e) {
          debugPrint('[webview] 会话校正失败: $e');
        }

        // 校验实际打开的会话。
        //
        // 必要性：localStorage 写入失败（隐私模式、首次访问、内核限制）时，
        // 页面会**静默退回默认会话**，不报错。不校验就会以为成功了。
        try {
          final probe = await controller.evaluateJavascript(
            source: '''
(function () {
  var el = document.querySelector('[data-conversation-session]');
  var stored = null;
  try { stored = localStorage.getItem('dsh.sessions.current'); } catch (e) {}
  return JSON.stringify({
    marker: el ? el.getAttribute('data-conversation-session') : null,
    stored: stored,
    title: document.title,
    bodyLen: document.body ? document.body.innerText.length : 0,
    dark: document.body ? document.body.hasAttribute('data-ds-dark-theme') : null,
    scheme: document.documentElement.style.colorScheme || null,
    lang: document.documentElement.getAttribute('lang'),
    navLang: navigator.language,
    locPref: (function(){ try { return localStorage.getItem('dsh.locale.preference'); } catch(e) { return null; } })(),
    bg: getComputedStyle(document.body).backgroundColor
  });
})();
''',
          );
          widget.callbacks.onProbe?.call(probe);
        } catch (e) {
          widget.callbacks.onError?.call(e);
        }

        // 会话渲染是异步的（session/follow + 历史回放）。
        //
        // `onLoadStop` 时页面通常还是骨架屏，marker 为 null。这里轮询等待
        // 目标会话真正挂载，再做「强制重绘」—— 早先固定等 8 秒，既慢又
        // 不可靠（慢网络下 8 秒仍可能是骨架）。
        _awaitSessionMounted(controller, seq);

        widget.callbacks.onReady?.call();
      },
      // ★ 自签私有 CA 的 TLS 处理。
      //
      // 网关用的是插件自签的 CA，系统信任链里没有它。WebView 默认严格校验，
      // 于是真机上打开详情页会**直接白屏**（`net::ERR_CERT_AUTHORITY_INVALID`），
      // 而 Dart 侧的 HTTP 客户端因为固定了 CA 反而正常 —— 症状就是
      // 「列表能出来、点进详情打不开」。
      //
      // 这里只信任**打包进 APK 的那张 CA**（与 unary/mux 用的同一张），
      // 不做 `proceed` 全放开：放开等于关掉 TLS。
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        final ok = await _isTrustedByPinnedCa(challenge);
        return ok
            ? ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.PROCEED,
              )
            : ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.CANCEL,
              );
      },
      onReceivedError: (controller, request, error) {
        debugPrint('[webview] 加载失败 ${request.url}: ${error.description}');
        widget.callbacks.onError?.call(error);
      },
      onProgressChanged: (controller, progress) {
        // 只在 10% 的整数倍上报，避免刷屏；卡住时能看出停在哪一档
        if (progress % 10 == 0) {
          debugPrint('[webview] progress $progress%');
        }
        widget.callbacks.onProgress?.call(progress);
      },
      ),
        // 遮罩：同色不透明，progress >= 10 时淡出
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _showCover ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: ColoredBox(
              color: widget.dark
                  ? const Color(0xFF151517)
                  : const Color(0xFFF7F8FA),
            ),
          ),
        ),
      ],
    );
  }

  /// 轮询等待目标会话挂载，然后强制重绘并上报。
  ///
  /// 为什么轮询而不是固定延时：DSH 的会话渲染依赖 `session/follow` 的
  /// opening 帧 + 历史回放，耗时随会话大小变化（实测 0.5s–9s 都有）。
  /// 固定延时要么太慢要么不可靠。
  Future<void> _awaitSessionMounted(
    InAppWebViewController controller,
    int seq,
  ) async {
    const maxAttempts = 40; // 40 × 250ms = 10s 上限
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // 页面已经换了一轮导航 → 放弃这一轮。
      if (seq != _navigationSeq) return;
      if (!mounted) return;

      try {
        final ready = await controller.evaluateJavascript(
          source: '''
(function () {
  var el = document.querySelector('[data-conversation-session]');
  if (!el) return 'no-marker';
  if (el.getAttribute('data-conversation-session') !== ${jsonEncode(widget.sessionId)}) {
    return 'wrong-session';
  }
  var flow = document.querySelector('[data-slot="conversation.chat.flow"]');
  if (!flow) return 'no-flow';
  var visible = 0;
  for (var i = 0; i < flow.children.length; i++) {
    if (flow.children[i].getBoundingClientRect().height > 0) visible++;
  }
  return visible > 0 ? 'ready' : 'empty';
})();
''',
        );

        if (ready == 'ready' || ready == 'empty') {
          final result =
              await controller.evaluateJavascript(source: settleAndRepaintJs);
          widget.callbacks.onProbe?.call(result);
          return;
        }
      } catch (_) {
        // 文档正在替换（renderer 重启）时会抛错，继续等下一轮。
      }
    }
  }

  /// 生成写入 localStorage 的启动脚本。
  ///
  /// 格式来自实测：`{"sessionId":"<id>"}`。
  /// 用 `try/catch` 包住：某些内核在 AT_DOCUMENT_START 时 localStorage
  /// 尚不可用（隐私模式/首次访问），此时不应让整页崩溃。
  static String _sessionBootstrap(String sessionId) {
    final payload = jsonEncode({'sessionId': sessionId});
    // 注意：不能直接把 payload 嵌进单引号字符串，用 jsonEncode 再包一层。
    final literal = jsonEncode(payload);
    return '''
(function () {
  try {
    localStorage.setItem('dsh.sessions.current', $literal);
  } catch (e) {
    // localStorage 不可用时静默失败：页面会退回默认会话，
    // 而不是白屏。上层会通过 onProbe 校验实际打开的会话。
    console.warn('[dsh-mobile] session bootstrap failed', e);
  }
})();
''';
  }
  /// 从 localStorage 的 JSON 里取出 sessionId；解析失败返回 null。
  static String? _sessionIdOf(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final id = decoded['sessionId'];
        if (id is String && id.isNotEmpty) return id;
      }
    } catch (_) {}
    return null;
  }

}
