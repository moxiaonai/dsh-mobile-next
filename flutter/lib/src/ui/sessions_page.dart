/// 会话列表页。对齐 `docs/10-ui-spec.md` §5.2。
///
/// 元素规格（逐条照抄 spec）：
/// - SearchField 高 44，`--r-md`，`--c-bg-sunken` 底；聚焦加 accent 描边 + 3px 光晕；
///   字号 ≥16（防 iOS 缩放）
/// - FilterChips：外层命中 44，内部药丸 32，横滑
/// - GroupHeader 高 32，sticky，`--t-chrome`
/// - SessionRow min-height 64，标题 1 行 ellipsis + 第二行工作区/时间
///
/// **未做 Swipe 动作**：spec 要求 swipe 是加速器、必须有「…」按钮的等价路径。
/// 这里只做「…」路径 —— 功能完整，少一套手势；swipe 可后续补。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/session.dart';
import '../protocol/sessions.dart';
import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme, EmptyState, ErrorState;
import 'tokens.dart';

/// 会话列表页。
class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.listSessions,
    required this.listWorkspaces,
    this.onOpen,
    this.onCreate,
    this.title,
    this.initialCollapsed,
    this.onCollapsedChanged,
  });

  final Future<List<SessionSummary>> Function() listSessions;
  final Future<WorkspaceSnapshot> Function() listWorkspaces;
  final void Function(SessionSummary s)? onOpen;

  /// 新建会话（spec §5.2 的 FAB ＋）。
  ///
  /// 传 null 时不显示 FAB —— 未连接时不该给一个按了必然失败的入口。
  /// 返回新建会话的 id；页面用它直接进入详情（新会话是 blank 的，
  /// 不会出现在列表里，所以必须靠返回值而不是刷新列表）。
  final Future<String?> Function()? onCreate;
  /// 页面标题；为空时用当前语言的默认值。
  final String? title;

  /// 初始折叠的分组键（由外层持久化后注入）。
  final Set<String>? initialCollapsed;

  /// 折叠集合变化时回调（外层负责持久化）。
  final ValueChanged<Set<String>>? onCollapsedChanged;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  List<SessionSummary> _all = const [];
  WorkspaceSnapshot _snapshot = const WorkspaceSnapshot.empty();
  bool _loading = true;

  /// 正在创建会话：防止慢网络下连点 FAB 建出多个空白会话。
  bool _creating = false;
  Object? _error;
  String _query = '';
  SessionFilter _filter = SessionFilter.all;
  final _searchController = TextEditingController();

  /// 已计算的分组（filter + group + search 的结果）。
  ///
  /// 缓存它而不是每次 build 重算：收起一个组只改 `_collapsed`，
  /// 不该顺带把上百个会话重新分组。
  List<SessionGroup> _groups = const [];

  /// 折叠的分组键（`SessionGroup.key`，不用标题 —— 标题会变）。
  late Set<String> _collapsed;

  @override
  void initState() {
    super.initState();
    _collapsed = {...?widget.initialCollapsed};
    unawaited(_load());
  }

  /// 唯一的重算入口：筛选 → 分组 → 搜索。
  void _recompute() {
    // 过滤规则：
    //   1. blank：DSH 打开后渲染欢迎页而非对话，像坏页面
    //   2. 已归档：用户在电脑上归档掉的，不该再出现在列表里
    //
    // 归档信息来自 workspace 快照的 `archivedSessionIds`
    // —— `session/list` 本身**不返回**归档标记，它给的是「全部会话」。
    final archived = _snapshot.archivedSessionIds;
    final visible = _all
        .where((s) => !s.blank && !archived.contains(s.id))
        .toList();
    final filtered = SessionBrowser.filter(visible, _filter);
    final grouped = SessionBrowser.group(filtered, _snapshot.items);
    _groups = _query.trim().isEmpty
        ? grouped
        : SessionBrowser.searchGroups(grouped, _query);
  }

  /// 切换分组折叠。**不重算分组**。
  void _toggleGroup(String key) {
    setState(() {
      if (_collapsed.contains(key)) {
        _collapsed.remove(key);
      } else {
        _collapsed.add(key);
      }
    });
    widget.onCollapsedChanged?.call({..._collapsed});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await widget.listSessions();
      final snapshot = await widget.listWorkspaces();
      if (!mounted) return;
      setState(() {
        _all = sessions;
        _snapshot = snapshot;
        _loading = false;
        _recompute();
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
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);

    // 分组结果由 _recompute() 维护，这里直接用 —— 收起一个组
    // 不该重算上百个会话的分组。
    final groups = _groups;

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
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
                  Text(widget.title ?? AppStrings.of(context)('sessions.title'), style: txt.h1),
                  const Spacer(),
                  if (_error != null)
                    IconButton(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      color: t.textSecondary,
                      tooltip: AppStrings.of(context)('common.retry'),
                    ),
                ],
              ),
            ),
            _searchField(t, txt),
            const SizedBox(height: Space.s3),
            _chips(t, txt, strings),
            const SizedBox(height: Space.s2),
            Expanded(child: _body(t, txt, groups)),
          ],
            ),
            // FAB 放在 body 的 Stack 里而不是 Scaffold.floatingActionButton：
            // 本页嵌在外层 Scaffold 的 body 中，内层 FAB 会被外层的
            // bottomNavigationBar 盖住（实测点了没反应）。
            if (widget.onCreate != null)
              Positioned(
                right: Space.s5,
                bottom: Space.s5,
                child: FloatingActionButton(
                  key: const ValueKey('sessions.fab'),
                  onPressed: _creating ? null : _create,
                  backgroundColor: t.accent,
                  foregroundColor: t.onAccent,
                  tooltip: strings('sessions.new'),
                  child: _creating
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: t.onAccent,
                          ),
                        )
                      : const Icon(Icons.add),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 新建会话并交给外层打开详情。
  ///
  /// 新会话是**空白会话**（`blank: true`），`session/list` 里会被过滤掉，
  /// 因此不能靠「创建完刷新列表」来让用户看到它 —— 必须直接用返回的
  /// id 进入详情页（WebView 是按 sessionId 打开的，不依赖列表可见性）。
  Future<void> _create() async {
    final create = widget.onCreate;
    if (create == null || _creating) return;
    setState(() => _creating = true);
    try {
      final id = await create();
      if (!mounted) return;
      if (id == null || id.isEmpty) {
        // 外层拿不到 id（例如未连接）：给一句可读的提示，不静默失败。
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.of(context)('sessions.createFailed'))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppStrings.of(context)
                .withArgs('sessions.createFailedWhy', {'e': e}),
          ),
        ),
      );
    } finally {
      // finally 而不是 try 尾部：异常路径也必须把 FAB 恢复成可点，
      // 否则一次网络抖动就永久锁死创建入口。
      if (mounted) setState(() => _creating = false);
    }
  }

  Widget _searchField(Tokens t, AppTextStyles txt) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.s7),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() {
          _query = v;
          _recompute();
        }),
        // spec：字号 ≥16 防 iOS 聚焦缩放
        style: txt.body.copyWith(fontSize: txt.fontBase < 16 ? 16 : null),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: AppStrings.of(context)('sessions.search'),
          hintStyle: txt.caption,
          prefixIcon: Icon(Icons.search, size: 20, color: t.textTertiary),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close, size: 18, color: t.textTertiary),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _query = '';
                      _recompute();
                    });
                  },
                  tooltip: AppStrings.of(context)('sessions.clear'),
                ),
          filled: true,
          fillColor: t.bgSunken,
          contentPadding: const EdgeInsets.symmetric(vertical: Space.s5),
          constraints: const BoxConstraints(minHeight: Hit.min),
          border: OutlineInputBorder(
            borderRadius: Radii.rMd,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: Radii.rMd,
            borderSide: BorderSide(color: t.accent),
          ),
        ),
      ),
    );
  }

  Widget _chips(Tokens t, AppTextStyles txt, AppStrings strings) {
    final items = [
      (SessionFilter.all, AppStrings.of(context)('sessions.all')),
      (SessionFilter.running, AppStrings.of(context)('session.state.running')),
      (SessionFilter.withAgent, AppStrings.of(context)('sessions.withAgent')),
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
          final on = _filter == f;
          return Center(
            child: InkWell(
              onTap: () => setState(() {
                _filter = f;
                _recompute();
              }),
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
                  label,
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

  Widget _body(Tokens t, AppTextStyles txt, List<SessionGroup> groups) {
    final strings = AppStrings.of(context);
    if (_loading && _all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _all.isEmpty) {
      return ErrorState(error: _error!, onRetry: _load);
    }
    if (groups.isEmpty) {
      return EmptyState(
        title: _query.isEmpty
            ? strings('sessions.empty')
            : strings('sessions.noMatch'),
        body: _query.isEmpty
            ? strings('sessions.emptyHint')
            : strings('sessions.noMatchHint'),
        icon: Icons.forum_outlined,
      );
    }

    // 搜索时强制展开：把命中项藏在折叠头后面，用户会以为没搜到。
    // 筛选不强制展开 —— 那是在同一列表上缩小范围，折叠仍是有效手势。
    final forceExpand = _query.trim().isNotEmpty;
    final noAnimation = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        key: const PageStorageKey('sessions.list'),
        slivers: [
          for (final g in groups)
            SliverMainAxisGroup(
              slivers: [
                // 组头在本组可见期间吸顶（spec §5.2 的 sticky）。
                PinnedHeaderSliver(
                  child: _GroupHeader(
                    group: g,
                    count: g.sessions.length,
                    collapsed: !forceExpand && _collapsed.contains(g.key),
                    tokens: t,
                    txt: txt,
                    strings: strings,
                    onToggle: forceExpand ? null : () => _toggleGroup(g.key),
                    animate: !noAnimation,
                  ),
                ),
                if (forceExpand || !_collapsed.contains(g.key))
                  SliverList.builder(
                    itemCount: g.sessions.length,
                    itemBuilder: (context, i) {
                      final s = g.sessions[i];
                      return _SessionRow(
                        session: s,
                        // 组头已经显示项目名，行里不再重复
                        showPath: g.kind == SessionGroupKind.unassigned,
                        onTap: () => widget.onOpen?.call(s),
                      );
                    },
                  ),
              ],
            ),
          // 底部留白：FAB 是 56 高、离底 16，共占 72。
          // 不留够的话最后一行会被 FAB 盖住，点不到也看不全。
          SliverToBoxAdapter(
            child: SizedBox(height: widget.onCreate == null ? Space.s12 : 72),
          ),
        ],
      ),
    );
  }

}

/// 分组头：可点击展开/收起，命中区 44。
///
/// 之前叫 `_StickyGroupHeader` 但**并不 sticky**（只是普通 32 高的 Container），
/// 长列表滚动时组名直接滚出屏幕，失去定位依据。现在由
/// `PinnedHeaderSliver` 真正吸顶，高度也提到 `Hit.min`(44) 满足命中区要求。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.count,
    required this.collapsed,
    required this.tokens,
    required this.txt,
    required this.strings,
    required this.onToggle,
    required this.animate,
  });

  final SessionGroup group;
  final int count;
  final bool collapsed;
  final Tokens tokens;
  final AppTextStyles txt;
  final AppStrings strings;
  final VoidCallback? onToggle;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    // 未归类组的标题由 UI 本地化（协议层留空串）
    final title = group.kind == SessionGroupKind.unassigned
        ? strings('sessions.groupOther')
        : group.title;

    final semanticsLabel = strings.withArgs(
      collapsed ? 'sessions.groupCollapsed' : 'sessions.groupExpanded',
      {'name': title, 'n': count},
    );

    return Semantics(
      button: onToggle != null,
      // ⚠ 只给 expanded，不同时给 onExpand —— Flutter 会抛
      // "An expanded node cannot have an expand action"
      expanded: !collapsed,
      label: semanticsLabel,
      child: Material(
        color: tokens.bgCanvas,
        child: InkWell(
          onTap: onToggle,
          child: Container(
            constraints: const BoxConstraints(minHeight: Hit.min),
            padding: const EdgeInsets.symmetric(horizontal: Space.s7),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: animate
                      ? const Duration(milliseconds: 150)
                      : Duration.zero,
                  curve: Curves.easeOut,
                  child: Icon(
                    Icons.expand_more,
                    size: 16,
                    color: tokens.textTertiary,
                  ),
                ),
                const SizedBox(width: Space.s3),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: txt.chrome.copyWith(color: tokens.textSecondary),
                  ),
                ),
                const SizedBox(width: Space.s3),
                Text(
                  '$count',
                  style: txt.caption.copyWith(color: tokens.textTertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    this.onTap,
    this.showPath = true,
  });

  final SessionSummary session;

  /// 是否在副标题里显示工作目录。
  ///
  /// 按项目分组后组头已经是项目名，行里再重复一次是噪音；
  /// 未归类组没有组头信息可依赖，所以仍显示。
  final bool showPath;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    return Material(
      color: t.bgCanvas,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.fromLTRB(
            Space.s7,
            Space.s5,
            Space.s7,
            Space.s5,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: t.borderSubtle, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        if (session.running) ...[
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: t.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: Space.s3),
                        ],
                        Expanded(
                          child: Text(
                            session.title ?? _shortId(session.id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: txt.body,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.s1),
                    Text(
                      _subtitle(session, AppStrings.of(context), showPath: showPath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: txt.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.s4),
              Icon(Icons.chevron_right, size: 18, color: t.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  static String _subtitle(
    SessionSummary s,
    AppStrings strings, {
    bool showPath = true,
  }) {
    final parts = <String>[];
    if (showPath && s.cwd != null && s.cwd!.isNotEmpty) {
      final segs = s.cwd!.split('/').where((x) => x.isNotEmpty).toList();
      parts.add(segs.isEmpty ? s.cwd! : segs.last);
    }
    if (s.agentAvailable) parts.add(strings('sessions.agentReady'));
    if (s.updatedAt != null) parts.add(formatRelativeTime(strings, s.updatedAt!));
    return parts.isEmpty ? s.id.substring(0, 12) : parts.join(' · ');
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
