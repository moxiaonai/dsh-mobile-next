/// 会话列表页。视觉按 2026-11-13 UI 稿重做：
///
/// - 大标题「会话」+ 右上两个圆形入口（搜索 / 筛选）
/// - 搜索框：`bgSunken` 底、`rLg` 圆角、56 高
/// - 筛选 chip：选中黑底白字，未选中灰底黑字
/// - 分组卡片：展开时「灰色组头 + 白色行」，收起时整卡一行（文件夹图标）
/// - 行：44 图标瓦片 + 标题/副标题 + 右箭头，分隔线只从标题左沿开始
/// - FAB：黑色圆形（与 chip / 底部导航选中态同一套「墨色」）
///
/// 折叠状态仍由外层持久化（`initialCollapsed` / `onCollapsedChanged`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/session.dart';
import '../protocol/sessions.dart';
import '../app_strings.dart';
import 'cards.dart';
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
  final _searchFocus = FocusNode();

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

  void _expandAll() {
    setState(() => _collapsed = <String>{});
    widget.onCollapsedChanged?.call(<String>{});
  }

  void _collapseAll() {
    setState(() => _collapsed = {for (final g in _groups) g.key});
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
    _searchFocus.dispose();
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
                    Space.s8,
                    Space.s2,
                    Space.s8,
                    0,
                  ),
                  child: Row(
                    children: [
                      Text(
                        widget.title ?? strings('sessions.title'),
                        style: txt.display,
                      ),
                      const Spacer(),
                      RoundIconButton(
                        icon: Icons.search,
                        tooltip: strings('sessions.searchAction'),
                        onTap: () => _searchFocus.requestFocus(),
                      ),
                      const SizedBox(width: Space.s4),
                      RoundIconButton(
                        icon: Icons.tune,
                        tooltip: strings('sessions.filter'),
                        onTap: () => _openFilterSheet(t, txt, strings),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s5),
                _searchField(t, txt),
                const SizedBox(height: Space.s6),
                _chips(t, txt, strings),
                const SizedBox(height: Space.s4),
                Expanded(child: _body(t, txt, groups)),
              ],
            ),
            // FAB 放在 body 的 Stack 里而不是 Scaffold.floatingActionButton：
            // 本页嵌在外层 Scaffold 的 body 中，内层 FAB 会被外层的
            // bottomNavigationBar 盖住（实测点了没反应）。
            if (widget.onCreate != null)
              Positioned(
                right: Space.s10,
                bottom: Space.s10,
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: FloatingActionButton(
                    key: const ValueKey('sessions.fab'),
                    tooltip: strings('sessions.new'),
                    backgroundColor: t.textPrimary,
                    foregroundColor: t.bgCard,
                    elevation: 2,
                    shape: const CircleBorder(),
                    onPressed: _creating ? null : _create,
                    child: _creating
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: t.bgCard,
                            ),
                          )
                        : const Icon(Icons.add, size: 30),
                  ),
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
      padding: const EdgeInsets.symmetric(horizontal: Space.s8),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
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
          hintStyle: txt.body.copyWith(color: t.textTertiary),
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
          contentPadding: const EdgeInsets.symmetric(vertical: Space.s4),
          constraints: const BoxConstraints(minHeight: 56),
          border: OutlineInputBorder(
            borderRadius: Radii.rLg,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: Radii.rLg,
            borderSide: BorderSide(color: t.textPrimary, width: 1.2),
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
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.s8),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: Space.s5),
        itemBuilder: (context, i) {
          final (f, label) = items[i];
          final on = _filter == f;
          return Center(
            child: Material(
              color: on ? t.textPrimary : t.bgSunken,
              borderRadius: Radii.rFull,
              child: InkWell(
                onTap: () => setState(() {
                  _filter = f;
                  _recompute();
                }),
                borderRadius: Radii.rFull,
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: Space.s9),
                  alignment: Alignment.center,
                  child: Text(
                    label,
                    style: txt.body.copyWith(
                      color: on ? t.bgCard : t.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 右上「筛选」入口：筛选 + 分组的批量展开/收起。
  Future<void> _openFilterSheet(
    Tokens t,
    AppTextStyles txt,
    AppStrings strings,
  ) {
    final items = [
      (SessionFilter.all, AppStrings.of(context)('sessions.all')),
      (SessionFilter.running, AppStrings.of(context)('session.state.running')),
      (SessionFilter.withAgent, AppStrings.of(context)('sessions.withAgent')),
    ];
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: t.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.s8,
              Space.s6,
              Space.s8,
              Space.s4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(strings('sessions.filter'), style: txt.h3),
                const SizedBox(height: Space.s2),
                for (final (f, label) in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label, style: txt.body),
                    trailing: _filter == f
                        ? Icon(Icons.check, color: t.textPrimary)
                        : null,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      setState(() {
                        _filter = f;
                        _recompute();
                      });
                    },
                  ),
                Divider(color: t.borderSubtle, height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.unfold_more, color: t.textSecondary),
                  title: Text(strings('sessions.expandAll'), style: txt.body),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _expandAll();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.unfold_less, color: t.textSecondary),
                  title: Text(strings('sessions.collapseAll'), style: txt.body),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _collapseAll();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 分组灰头。组名在「未归类」组是本地化的（协议层留空串）。
  Widget _header(
    AppStrings strings,
    SessionGroup g, {
    required bool expanded,
    required bool forceExpand,
    required bool animate,
  }) {
    final name = g.kind == SessionGroupKind.unassigned
        ? strings('sessions.groupOther')
        : g.title;
    return GroupHeaderCard(
      title: name,
      count: g.sessions.length,
      expanded: expanded,
      onTap: forceExpand ? null : () => _toggleGroup(g.key),
      animate: animate,
      semanticsLabel: strings.withArgs(
        expanded ? 'sessions.groupExpanded' : 'sessions.groupCollapsed',
        {'name': name, 'n': g.sessions.length},
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
    final scrollController = PrimaryScrollController.maybeOf(context);

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        key: const PageStorageKey('sessions.list'),
        primary: scrollController == null,
        slivers: [
          for (final g in groups) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.s8,
                  Space.s8,
                  Space.s8,
                  0,
                ),
                child: _header(
                  strings,
                  g,
                  expanded: forceExpand || !_collapsed.contains(g.key),
                  forceExpand: forceExpand,
                  animate: !noAnimation,
                ),
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
                    last: i == g.sessions.length - 1,
                    onTap: () => widget.onOpen?.call(s),
                  );
                },
              ),
          ],
          // 底部留白：FAB 是 64 高、离底 24，共占 88。
          // 不留够的话最后一行会被 FAB 盖住，点不到也看不全。
          SliverToBoxAdapter(
            child: SizedBox(height: widget.onCreate == null ? Space.s12 : 96),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    this.onTap,
    this.showPath = true,
    this.last = false,
  });

  final SessionSummary session;

  /// 是否在副标题里显示工作目录。
  ///
  /// 按项目分组后组头已经是项目名，行里再重复一次是噪音；
  /// 未归类组没有组头信息可依赖，所以仍显示。
  final bool showPath;

  /// 是否本组最后一行（只有它带底部圆角，和上面的组头凑成一张卡）。
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    return CardRow(
      leadingIcon: _iconFor(session),
      title: session.title ?? _shortId(session.id),
      subtitle: cardSubtitle(
        _subtitle(session, AppStrings.of(context), showPath: showPath),
        txt,
        t,
      ),
      dotColor: session.running ? t.successDot : null,
      onTap: onTap,
      last: last,
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
}

/// 行首图标：按会话标题/路径里的关键词挑一个，取不到的用「层叠」兜底。
///
/// 纯装饰，不进语义树；同一个会话永远得到同一个图标（确定性映射）。
IconData _iconFor(SessionSummary s) {
  final text = '${s.title ?? ''} ${s.cwd ?? ''}'.toLowerCase();
  if (text.contains('图标') || text.contains('icon') || text.contains('image')) {
    return Icons.image_outlined;
  }
  if (text.contains('回退') || text.contains('0.1.')) {
    return Icons.layers_outlined;
  }
  if (text.contains('ui') ||
      text.contains('交互') ||
      text.contains('重设计') ||
      text.contains('重构')) {
    return Icons.code;
  }
  if (text.contains('插件') ||
      text.contains('仓库') ||
      text.contains('打包') ||
      text.contains('发布')) {
    return Icons.inventory_2_outlined;
  }
  if (text.contains('远程') ||
      text.contains('通道') ||
      text.contains('架构') ||
      text.contains('git') ||
      text.contains('分支')) {
    return Icons.account_tree_outlined;
  }
  if (text.contains('移动端') ||
      text.contains('app') ||
      text.contains('手机') ||
      text.contains('任务接管')) {
    return Icons.smartphone;
  }
  if (text.contains('错乱') ||
      text.contains('失败') ||
      text.contains('异常') ||
      text.contains('bug')) {
    return Icons.error_outline;
  }
  if (text.contains('代码') ||
      text.contains('实现') ||
      text.contains('开发') ||
      text.contains('flutter')) {
    return Icons.code;
  }
  return Icons.layers_outlined;
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
