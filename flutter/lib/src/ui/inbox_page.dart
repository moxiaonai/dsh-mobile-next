/// 通知中心。对齐 `docs/10-ui-spec.md` §5.5。
///
/// **七个筛选 chip** 与 `WEB_PUSH.md` 的六类对齐（问题/计划/审批/回复/目标/失败）+ 全部。
/// spec 明确：**这是已证实的类别集合，不得自行增加第七类**。
///
/// **脱敏**：列表只显示会话标题与类别，**不显示问题正文**
/// （与锁屏策略一致）。
///
/// **点击不代为回答或批准**：只深链到任务详情并展开 dock。
library;

import 'package:flutter/material.dart';

import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme, EmptyState;
import 'tokens.dart';

/// 通知类别。与 `WEB_PUSH.md` 的六类一一对应。
enum InboxCategory {
  question,
  plan,
  approval,
  reply,
  goal,
  failure;

  /// 多语言标签（枚举不能持有运行时值）。
  String label(AppStrings strings) => switch (this) {
    InboxCategory.question => strings('inbox.questions'),
    InboxCategory.plan => strings('inbox.plans'),
    InboxCategory.approval => strings('inbox.approval'),
    InboxCategory.reply => strings('inbox.replies'),
    InboxCategory.goal => strings('inbox.goals'),
    InboxCategory.failure => strings('inbox.failed'),
  };
}

/// 一条通知。
class InboxEntry {
  const InboxEntry({
    required this.id,
    required this.category,
    required this.sessionId,
    required this.sessionTitle,
    required this.at,
    this.read = false,
  });

  final String id;
  final InboxCategory category;

  /// 深链目标。
  final String sessionId;

  /// 只显示会话标题 —— **不含正文**（脱敏）。
  final String sessionTitle;

  final DateTime at;
  final bool read;

  InboxEntry copyWith({bool? read}) => InboxEntry(
    id: id,
    category: category,
    sessionId: sessionId,
    sessionTitle: sessionTitle,
    at: at,
    read: read ?? this.read,
  );
}

/// 筛选：全部 + 六类。
sealed class InboxFilter {
  const InboxFilter();
}

class AllFilter extends InboxFilter {
  const AllFilter();
}

class CategoryFilter extends InboxFilter {
  const CategoryFilter(this.category);
  final InboxCategory category;
}

/// 通知中心。
class InboxPage extends StatefulWidget {
  const InboxPage({
    super.key,
    required this.entries,
    this.onOpen,
    this.onMarkAllRead,
    this.onBack,
    this.title,
  });

  final List<InboxEntry> entries;

  /// 点击一条通知：深链到任务详情。**不得**代为回答。
  final void Function(InboxEntry e)? onOpen;

  final VoidCallback? onMarkAllRead;

  /// 返回动作。通知页是 push 上来的二级页，必须自己给返回入口
  /// （外层 tab 壳不提供 AppBar）。为空时仍尽量 `maybePop`。
  final VoidCallback? onBack;

  /// 页面标题；为空时用当前语言的默认值。
  final String? title;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  InboxFilter _filter = const AllFilter();

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);

    final filtered = switch (_filter) {
      AllFilter() => widget.entries,
      CategoryFilter(:final category) =>
        widget.entries.where((e) => e.category == category).toList(),
    };

    final groups = _groupByDay(filtered, AppStrings.of(context));

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.s7,
                Space.s6,
                Space.s7,
                Space.s3,
              ),
              child: Row(
                children: [
                  if (widget.onBack != null || Navigator.of(context).canPop())
                    IconButton(
                      onPressed: widget.onBack ??
                          () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.chevron_left),
                      color: t.textSecondary,
                      tooltip: AppStrings.of(context)('common.back'),
                      constraints: const BoxConstraints(
                        minWidth: Hit.min,
                        minHeight: Hit.min,
                      ),
                    ),
                  Text(widget.title ?? AppStrings.of(context)('inbox.title'), style: txt.h1),
                  const Spacer(),
                  if (widget.onMarkAllRead != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: Hit.min),
                      child: TextButton(
                        onPressed: widget.onMarkAllRead,
                        style: TextButton.styleFrom(
                          foregroundColor: t.accent,
                          minimumSize: const Size(0, Hit.min),
                        ),
                        child: Text(AppStrings.of(context)('inbox.markAllRead')),
                      ),
                    ),
                ],
              ),
            ),
            _chips(t, txt, AppStrings.of(context)),
            const SizedBox(height: Space.s2),
            Expanded(
              child: groups.isEmpty
                  ? EmptyState(
                      title: AppStrings.of(context)('inbox.empty'),
                      body: AppStrings.of(context)('inbox.hint'),
                      icon: Icons.notifications_none,
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: Space.s12),
                      children: [
                        for (final g in groups) ...[
                          _groupHeader(g.title, t, txt),
                          for (final e in g.entries)
                            _InboxRow(
                              entry: e,
                              onTap: () => widget.onOpen?.call(e),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chips(Tokens t, AppTextStyles txt, AppStrings strings) {
    final items = <(InboxFilter, String)>[
      (const AllFilter(), AppStrings.of(context)('sessions.all')),
      for (final c in InboxCategory.values) (CategoryFilter(c), c.label(strings)),
    ];
    return SizedBox(
      height: Hit.min,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.s7),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: Space.s4),
        itemBuilder: (context, i) {
          final (f, label) = items[i];
          final on = _sameFilter(f);
          final count = _countOf(f);
          return Center(
            child: InkWell(
              onTap: () => setState(() => _filter = f),
              borderRadius: Radii.rFull,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: Space.s6),
                decoration: BoxDecoration(
                  color: on ? t.accent : t.bgSunken,
                  borderRadius: Radii.rFull,
                ),
                alignment: Alignment.center,
                child: Text(
                  count > 0 ? '$label $count' : label,
                  style: txt.chrome.copyWith(
                    color: on ? t.onAccent : t.textSecondary,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  bool _sameFilter(InboxFilter f) => switch ((_filter, f)) {
    (AllFilter(), AllFilter()) => true,
    (CategoryFilter(category: final a), CategoryFilter(category: final b)) =>
      a == b,
    _ => false,
  };

  int _countOf(InboxFilter f) => switch (f) {
    AllFilter() => widget.entries.length,
    CategoryFilter(:final category) =>
      widget.entries.where((e) => e.category == category).length,
  };

  Widget _groupHeader(String title, Tokens t, AppTextStyles txt) => Container(
    height: 32,
    color: t.bgCanvas,
    padding: const EdgeInsets.symmetric(horizontal: Space.s7),
    alignment: Alignment.centerLeft,
    child: Text(
      title,
      style: txt.chrome.copyWith(color: t.textSecondary),
    ),
  );

  static List<({String title, List<InboxEntry> entries})> _groupByDay(
    List<InboxEntry> entries,
    AppStrings strings,
  ) {
    final now = DateTime.now();
    final today = <InboxEntry>[];
    final yesterday = <InboxEntry>[];
    final earlier = <InboxEntry>[];
    for (final e in entries) {
      final d = now.difference(e.at);
      if (d.inHours < 24 && now.day == e.at.day) {
        today.add(e);
      } else if (d.inDays <= 1) {
        yesterday.add(e);
      } else {
        earlier.add(e);
      }
    }
    return [
      if (today.isNotEmpty) (title: strings('inbox.today'), entries: today),
      if (yesterday.isNotEmpty) (title: strings('inbox.yesterday'), entries: yesterday),
      if (earlier.isNotEmpty) (title: strings('inbox.earlier'), entries: earlier),
    ];
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({required this.entry, this.onTap});

  final InboxEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final (icon, color, bg) = _style(entry.category, t);

    return Material(
      color: t.bgCard,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.s7,
            vertical: Space.s5,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: t.borderSubtle, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              // 图标放在 32×32 圆角 8 的 weak 底色块里
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: Radii.rSm,
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: Space.s5),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      // 只显示类别 + 会话标题，不含正文（脱敏）
                      '${entry.category.label(AppStrings.of(context))} · ${entry.sessionTitle}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: txt.body,
                    ),
                    const SizedBox(height: Space.s1),
                    Text(_timeLabel(entry.at), style: txt.caption),
                  ],
                ),
              ),
              if (!entry.read) ...[
                const SizedBox(width: Space.s4),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: t.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static (IconData, Color, Color) _style(InboxCategory c, Tokens t) =>
      switch (c) {
        InboxCategory.question => (
          Icons.help_outline,
          t.warn,
          t.warnWeakBg,
        ),
        InboxCategory.plan => (Icons.map_outlined, t.accent, t.accentWeakBg),
        InboxCategory.approval => (
          Icons.shield_outlined,
          t.danger,
          t.dangerWeakBg,
        ),
        InboxCategory.reply => (
          Icons.chat_bubble_outline,
          t.accent,
          t.accentWeakBg,
        ),
        InboxCategory.goal => (
          Icons.flag_outlined,
          t.success,
          t.successWeakBg,
        ),
        InboxCategory.failure => (
          Icons.error_outline,
          t.danger,
          t.dangerWeakBg,
        ),
      };

  static String _timeLabel(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}';
  }
}
