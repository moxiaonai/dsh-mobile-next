/// 会话详情页。
///
/// ## 为什么用 WebView 而不是原生重绘
///
/// 对话内容的渲染极重：Markdown、代码高亮、KaTeX、终端、文件预览、附件缩略图。
/// 这些能力 DSH 的客户端插件已经实现了，原生重做等于永久追版本。
///
/// 因此会话详情页承载一个 WebView，用 spike 2 验证过的配方打开**指定会话**：
/// 首个文档加载前写 `localStorage['dsh.sessions.current']`，再加载 `/`。
///
/// ## 顶部为什么是原生的
///
/// spec §5.4 要求详情页有 sticky header（标题 + 状态 + 更多菜单）。
/// 用原生做这一条，比让 WebView 自己画更稳：WebView 的头部随 DSH 版本变化，
/// 原生的不会。
library;

import 'package:flutter/material.dart';

import '../protocol/session.dart';
import '../webview/session_webview.dart';
import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme;
import 'tokens.dart';

/// 会话详情页。
class SessionDetailPage extends StatelessWidget {
  const SessionDetailPage({
    super.key,
    required this.session,
    required this.origin,
    required this.cookieHeader,
    this.onBack,
    this.onOpenOnPc,
    this.onOpenJobs,
    this.dark = false,
    this.localeTag,
  });

  final SessionSummary session;
  final Uri origin;
  final String cookieHeader;

  final VoidCallback? onBack;

  /// 当前 App 是否深色。传给 WebView 以同步 DSH 页面的主题。
  final bool dark;

  /// 当前 App 的语言标签（`zh-CN` / `en-US`），同步给 WebView。
  final String? localeTag;

  /// 「在电脑上打开」（暂未接入，留注入位）。
  final VoidCallback? onOpenOnPc;

  /// 打开该会话的后台任务列表。
  ///
  /// 后台命令是**辅助信息**，不再占主界面（主界面是会话任务列表）。
  /// 传入后在 header 显示一个入口按钮。
  ///
  /// 用回调而不是内部 `Navigator.push`：本页由宿主用 setState 切换 body
  /// 承载，不是 Navigator 路由；内部 push 会压到 tab 壳上，pop 时
  /// 回到错误层级（实测：点返回跳到了设备页）。
  final VoidCallback? onOpenJobs;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);

    // ⚠ 底部必须让出安全区。
    //
    // 之前用 `SafeArea(bottom: false)`，WebView 一直延伸到屏幕最底边，
    // DSH 页面自己的 composer 就压在系统手势条上，被遮挡（实测截图确认：
    // 底部 2325–2350 区域有 20,373 个变化像素，正是 composer 与手势条重叠）。
    //
    // 顶部仍用 `bottom: false` 之外的默认行为：header 已经处理状态栏，
    // 因此只补底部 padding，不整体包 SafeArea（避免顶部重复留白）。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: Column(
        children: [
          SafeArea(bottom: false, child: _header(context, t, txt)),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              // 空白会话也走 WebView。
              //
              // 实测 DSH 对 `blank: true` 渲染的是**欢迎页**：
              //   Workspaces / Into the Unknown / [Choose workspace] / Standard mode
              // 此时没有输入框（`hasComposer: false`），必须先点
              // 「Choose workspace」选一个工作区；选完后 DSH 自己把
              // composer 显示出来（提示语 "Describe what you want to build…"），
              // 之后就能直接打字。
              //
              // 所以「新建会话」的完整流程是：新建 → 欢迎页 → 选工作区 → 输入。
              // App 不需要自造输入框，交给 DSH 即可。
              child: SessionWebView(
                      origin: origin,
                      cookieHeader: cookieHeader,
                      sessionId: session.id,
                      conversationOnly: true,
                      dark: dark,
                      localeTag: localeTag,
                      callbacks: SessionWebViewCallbacks(
                        onProbe: (r) => debugPrint('[detail] PROBE $r'),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, Tokens t, AppTextStyles txt) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: Space.s3),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(
          bottom: BorderSide(color: t.borderSubtle, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: Hit.min,
            height: Hit.min,
            child: IconButton(
              onPressed: onBack,
              icon: Icon(Icons.chevron_left, color: t.textSecondary),
              tooltip: AppStrings.of(context)('common.back'),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  session.title ?? _shortId(session.id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: txt.body.copyWith(fontWeight: FontWeight.w600),
                ),
                if (session.running)
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: t.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: Space.s2),
                      Text(AppStrings.of(context)('session.state.running'), style: txt.caption),
                    ],
                  ),
              ],
            ),
          ),
          if (onOpenJobs != null)
            SizedBox(
              width: Hit.min,
              height: Hit.min,
              child: IconButton(
                onPressed: onOpenJobs,
                icon: Icon(Icons.terminal, color: t.textSecondary),
                tooltip: AppStrings.of(context)('detail.jobs'),
              ),
            ),
          if (onOpenOnPc != null)
            SizedBox(
              width: Hit.min,
              height: Hit.min,
              child: IconButton(
                onPressed: onOpenOnPc,
                icon: Icon(Icons.desktop_windows_outlined,
                    color: t.textSecondary),
                tooltip: AppStrings.of(context)('detail.openOnPc'),
              ),
            ),
        ],
      ),
    );
  }

/// 会话 id 的短标签。
///
/// DSH 的会话 id 形如 `session-267a5de3-3088-...`，直接取前 8 位会得到
/// 全是 `session-` 的无用标签。这里先剥掉前缀再截取。
String _shortId(String id) {
  final stripped = id.startsWith('session-') ? id.substring(8) : id;
  final short = stripped.length > 8 ? stripped.substring(0, 8) : stripped;
  return '会话 $short';
}

}

/// 空白会话提示。

class _BlankComposer extends StatefulWidget {
  const _BlankComposer({
    required this.t,
    required this.txt,
    required this.onSend,
  });

  final Tokens t;
  final AppTextStyles txt;
  final Future<void> Function(String text)? onSend;

  @override
  State<_BlankComposer> createState() => _BlankComposerState();
}

class _BlankComposerState extends State<_BlankComposer> {
  final _controller = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final send = widget.onSend;
    debugPrint('[composer] send 触发 text="$text" hasSend=${send != null} sending=$_sending');
    if (text.isEmpty || send == null || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await send(text);
      if (mounted) _controller.clear();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final t = widget.t;
    final txt = widget.txt;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.s12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 32,
                    color: t.textTertiary,
                  ),
                  const SizedBox(height: Space.s6),
                  Text(
                    strings('detail.empty'),
                    style: txt.h3,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Space.s3),
                  Text(
                    strings('detail.emptyHint'),
                    style: txt.caption,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.s5),
            child: Text(
              _error!,
              style: txt.caption.copyWith(color: t.danger),
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(
            Space.s5,
            Space.s4,
            Space.s5,
            Space.s5,
          ),
          decoration: BoxDecoration(
            color: t.bgCard,
            border: Border(top: BorderSide(color: t.borderSubtle)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 5,
                  enabled: !_sending,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: strings('detail.firstMessage'),
                    hintStyle: txt.caption,
                    filled: true,
                    fillColor: t.bgSunken,
                    constraints: const BoxConstraints(minHeight: Hit.min),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Space.s5,
                      vertical: Space.s4,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: Radii.rMd,
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Space.s3),
              SizedBox(
                width: Hit.min,
                height: Hit.min,
                child: IconButton(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.arrow_upward, color: t.onAccent),
                  style: IconButton.styleFrom(backgroundColor: t.accent),
                  tooltip: strings('detail.send'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

