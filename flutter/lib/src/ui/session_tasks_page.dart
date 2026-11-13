/// 会话任务列表页 —— 「任务」tab 的新内容。
///
/// ## 与旧版「后台任务」的区别
///
/// 旧版展示 `job/list` 的**命令执行记录**（`brew install …`），那是实现细节。
/// 新版以**会话**为任务单位：一件工作 = 一个会话。
///
/// 用户打开 app 最想知道的是：
/// 1. 哪件事卡住等我（待答提问）
/// 2. 哪件在跑
/// 3. 其他（空闲/历史）
///
/// 后台命令降级为任务详情里的辅助信息，不再占主界面。
///
/// 视觉上与会话页共用 [cards.dart] 那套卡片语言：大标题 + 右上圆形按钮 +
/// 灰色组头 + 白色行卡。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/session.dart';
import '../notice_center.dart';
import '../protocol/session_tasks.dart';
import '../app_strings.dart';
import 'cards.dart';
import 'job_widgets.dart' show AppTheme, EmptyState, ErrorState;
import 'tokens.dart';

/// 会话任务列表页。
class SessionTasksPage extends StatefulWidget {
  const SessionTasksPage({
    super.key,
    required this.listSessions,
    this.onOpen,
    this.onRefresh,
    this.title,
    this.notices,
    this.onOpenNotice,
    this.onMarkAllNoticesRead,
  });

  final Future<List<SessionSummary>> Function() listSessions;

  /// 打开某个会话（进入详情）。
  final void Function(SessionSummary s)? onOpen;

  final VoidCallback? onRefresh;

  /// 页面标题；为空时用当前语言的默认值。
  final String? title;

  /// 通知中心（与「需要你」并排展示）。
  ///
  /// 通知与任务是同一个问题「有什么要我处理」的两个面：
  /// 任务按会话聚合，通知按时间线排。合成一页比拆两个 tab 更符合心智。
  final NoticeCenter? notices;

  /// 点通知 → 打开对应会话。
  final void Function(Notice notice)? onOpenNotice;

  /// 全部标记已读。
  final VoidCallback? onMarkAllNoticesRead;

  @override
  State<SessionTasksPage> createState() => _SessionTasksPageState();
}

class _SessionTasksPageState extends State<SessionTasksPage> {
  List<SessionTask> _tasks = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_error != null) setState(() => _error = null);
    try {
      final sessions = await widget.listSessions();
      if (!mounted) return;
      setState(() {
        _tasks = SessionTasks.build(sessions);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);

    if (_error != null) {
      return Scaffold(
        backgroundColor: t.bgCanvas,
        body: SafeArea(child: ErrorState(error: _error!, onRetry: _load)),
      );
    }
    if (_loading && _tasks.isEmpty) {
      return Scaffold(
        backgroundColor: t.bgCanvas,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final g = SessionTasks.group(_tasks);
    final noticeList = widget.notices?.items ?? const <Notice>[];
    final unread = widget.notices?.unreadCount ?? 0;
    final hasAny =
        g.needsYou.isNotEmpty ||
        g.active.isNotEmpty ||
        g.rest.isNotEmpty ||
        noticeList.isNotEmpty;

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.s8,
                    Space.s2,
                    Space.s8,
                    Space.s6,
                  ),
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title ?? strings('tasks.title'),
                            style: txt.display,
                          ),
                          if (_tasks.isNotEmpty) ...[
                            const SizedBox(height: Space.s1),
                            Text(
                              strings.withArgs('tasks.count', {
                                'n': _tasks.length,
                              }),
                              style: txt.caption,
                            ),
                          ],
                        ],
                      ),
                      const Spacer(),
                      if (unread > 0)
                        RoundIconButton(
                          icon: Icons.done_all,
                          tooltip: strings('inbox.markAllRead'),
                          onTap: widget.onMarkAllNoticesRead,
                        ),
                      if (unread > 0) const SizedBox(width: Space.s4),
                      RoundIconButton(
                        icon: Icons.refresh,
                        tooltip: strings('common.refresh'),
                        onTap: () {
                          widget.onRefresh?.call();
                          unawaited(_load());
                        },
                      ),
                    ],
                  ),
                ),
              ),
              if (!hasAny)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    title: strings('tasks.empty'),
                    body: strings('tasks.emptyHint'),
                    icon: Icons.task_alt,
                  ),
                )
              else ...[
                if (noticeList.isNotEmpty) ...[
                  _section(strings('inbox.title'), noticeList.length),
                  SliverList.builder(
                    itemCount: noticeList.length,
                    itemBuilder: (context, i) => _NoticeRow(
                      notice: noticeList[i],
                      last: i == noticeList.length - 1,
                      onTap: () => widget.onOpenNotice?.call(noticeList[i]),
                    ),
                  ),
                ],
                if (g.needsYou.isNotEmpty) ...[
                  _section(strings('tasks.needsYou'), g.needsYou.length),
                  _list(g.needsYou),
                ],
                if (g.active.isNotEmpty) ...[
                  _section(strings('tasks.running'), g.active.length),
                  _list(g.active),
                ],
                if (g.rest.isNotEmpty) ...[
                  _section(strings('tasks.other'), g.rest.length),
                  _list(g.rest),
                ],
              ],
              const SliverToBoxAdapter(child: SizedBox(height: Space.s12)),
            ],
          ),
        ),
      ),
    );
  }

  /// 分区灰头。任务页的分区不可折叠 —— 位置固定，收起反而多一步。
  Widget _section(String title, int count) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.s8,
        Space.s8,
        Space.s8,
        0,
      ),
      child: GroupHeaderCard(title: title, count: count),
    ),
  );

  Widget _list(List<SessionTask> tasks) => SliverList.builder(
    itemCount: tasks.length,
    itemBuilder: (context, i) => SessionTaskCard(
      task: tasks[i],
      last: i == tasks.length - 1,
      onTap: () => widget.onOpen?.call(tasks[i].session),
    ),
  );
}

/// 一个会话任务卡片（白卡一行）。
class SessionTaskCard extends StatelessWidget {
  const SessionTaskCard({
    super.key,
    required this.task,
    this.onTap,
    this.last = false,
  });

  final SessionTask task;
  final VoidCallback? onTap;

  /// 是否本组最后一行（带底部圆角）。
  final bool last;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);
    final style = _styleOf(task.kind, t, strings);

    return Semantics(
      button: true,
      label: '${task.title}，${style.label}',
      child: CardRow(
        leadingIcon: _iconOf(task.kind),
        title: task.title,
        dotColor: task.needsYou
            ? t.warnDot
            : (task.kind == SessionTaskKind.running ? t.accent : null),
        last: last,
        onTap: onTap,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Space.s2),
            Row(
              children: [
                _chip(style.label, style.fg, style.bg, txt),
                if (task.pendingQuestionCount > 1) ...[
                  const SizedBox(width: Space.s2),
                  Text(
                    strings.withArgs('tasks.awaitingCount', {
                      'n': task.pendingQuestionCount,
                    }),
                    style: txt.caption,
                  ),
                ],
                const SizedBox(width: Space.s3),
                Expanded(
                  child: Text(
                    _meta(task),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: txt.caption.copyWith(color: t.textTertiary),
                  ),
                ),
              ],
            ),
            // 「需要你」时把问题正文显示出来 —— 这是用户最想看的
            if (task.needsYou && task.pendingQuestionSummary != null) ...[
              const SizedBox(height: Space.s2),
              Text(
                task.pendingQuestionSummary!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: txt.caption.copyWith(color: t.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color fg, Color bg, AppTextStyles txt) => Container(
    height: 20,
    padding: const EdgeInsets.symmetric(horizontal: Space.s3),
    decoration: BoxDecoration(color: bg, borderRadius: Radii.rSm),
    alignment: Alignment.center,
    child: Text(
      label,
      style: txt.chrome.copyWith(color: fg, fontSize: txt.fontBase * 0.7),
    ),
  );

  static IconData _iconOf(SessionTaskKind kind) => switch (kind) {
    SessionTaskKind.needsAnswer => Icons.help_outline,
    SessionTaskKind.running => Icons.bolt_outlined,
    SessionTaskKind.idle => Icons.check_circle_outline,
    SessionTaskKind.dormant => Icons.history,
  };

  static String _meta(SessionTask task) {
    final parts = <String>[];
    final cwd = task.session.cwd;
    if (cwd != null && cwd.isNotEmpty) {
      final segs = cwd.split('/').where((x) => x.isNotEmpty).toList();
      parts.add(segs.isEmpty ? cwd : segs.last);
    }
    final at = task.updatedAt;
    if (at != null) parts.add(_ago(at));
    return parts.join(' · ');
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays == 1) return '昨天';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${(d.inDays / 30).floor()} 个月前';
  }

  static _TaskStyle _styleOf(
    SessionTaskKind kind,
    Tokens t,
    AppStrings strings,
  ) => switch (kind) {
    SessionTaskKind.needsAnswer => _TaskStyle(
      // 分区标题已叫「需要你」，chip 换个说法避免同屏重复
      label: strings('tasks.awaiting'),
      fg: t.warn,
      bg: t.warnWeakBg,
      dot: t.warnDot,
      border: t.warnDot,
    ),
    SessionTaskKind.running => _TaskStyle(
      // 分区标题已叫「进行中」，chip 换个说法
      label: strings('session.state.running'),
      fg: t.accentWeakText,
      bg: t.accentWeakBg,
      dot: t.accent,
      border: t.borderSubtle,
    ),
    SessionTaskKind.idle => _TaskStyle(
      label: strings('session.state.idle'),
      fg: t.textSecondary,
      bg: t.bgSunken,
      dot: t.textTertiary,
      border: t.borderSubtle,
    ),
    SessionTaskKind.dormant => _TaskStyle(
      label: strings('session.state.history'),
      fg: t.textTertiary,
      bg: t.bgSunken,
      dot: t.textTertiary,
      border: t.borderSubtle,
    ),
  };
}

class _TaskStyle {
  const _TaskStyle({
    required this.label,
    required this.fg,
    required this.bg,
    required this.dot,
    required this.border,
  });

  final String label;
  final Color fg;
  final Color bg;
  final Color dot;
  final Color border;
}

/// 一条通知行（任务页内的时间线）。
///
/// 未读用标题前的圆点 + 加粗标题表达，不靠颜色单独承载信息。
class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.notice,
    required this.onTap,
    this.last = false,
  });

  final Notice notice;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);

    final kindLabel = switch (notice.kind) {
      NoticeKind.approval => strings('inbox.approval'),
      NoticeKind.question => strings('inbox.questions'),
      NoticeKind.turnDone => strings('inbox.replies'),
      NoticeKind.failed => strings('inbox.failed'),
    };

    return CardRow(
      leadingIcon: switch (notice.kind) {
        NoticeKind.approval => Icons.verified_outlined,
        NoticeKind.question => Icons.help_outline,
        NoticeKind.turnDone => Icons.check_circle_outline,
        NoticeKind.failed => Icons.error_outline,
      },
      title: '$kindLabel · ${notice.title}',
      titleStyle: txt.body.copyWith(
        fontWeight: notice.read ? FontWeight.w400 : FontWeight.w600,
      ),
      subtitle: cardSubtitle(
        formatRelativeTime(strings, notice.at),
        txt,
        t,
      ),
      dotColor: notice.read ? null : t.accent,
      last: last,
      onTap: onTap,
    );
  }
}
