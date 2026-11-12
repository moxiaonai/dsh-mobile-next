/// 会话与工作区：分组、筛选、搜索。
///
/// ## 数据来源
///
/// | 需要 | 端点 | 载体 |
/// | --- | --- | --- |
/// | 会话列表 | `session/list` | unary |
/// | 工作区分组 | `workspace/follow` | **stream** |
///
/// `workspace/follow` 的 `baseline` 帧给出 `items[]`，每项含
/// `workspaceId` / `title` / `sessionIds[]`，这就是分组的权威来源。
///
/// ## 未读与失败标记
///
/// `session/list` **不提供** `unread` / `failed` 字段（架构 A2 已裁决）。
/// 这里用可推导的信号替代：
/// - **失败**：`SessionSummary` 没有该字段，只能靠 `job/list` 里该会话
///   是否有 `failed` 任务间接判断 —— 但那不是「会话失败」，所以不做。
/// - **未读**：由客户端水位线算（「上次访问之后有活动」）。
///
/// 因此本层**不伪造**这两个标记，只用真实可得的信号：
/// 最近活动时间、是否有任务在跑、是否持有活 Agent。
library;

import 'dart:async';

import '../transport/mux.dart';
import '../transport/unary.dart';
import 'frames.dart';
import 'session.dart';

/// 一个工作区。
class Workspace {
  const Workspace({
    required this.id,
    required this.path,
    required this.title,
    required this.sessionIds,
  });

  final String id;
  final String path;
  final String title;

  /// 该工作区下的会话（按手动顺序）。
  final List<String> sessionIds;

  factory Workspace.fromJson(Map<String, Object?> json) {
    final id = json['workspaceId'];
    if (id is! String || id.isEmpty) {
      throw const ProtocolError('workspace has no id');
    }
    final ids = json['sessionIds'];
    return Workspace(
      id: id,
      path: json['path'] as String? ?? '',
      title: json['title'] as String? ?? (json['path'] as String? ?? id),
      sessionIds: ids is List ? ids.whereType<String>().toList() : const [],
    );
  }
}

/// 分组来源。决定 UI 如何取标题、以及断连时的降级路径。
enum SessionGroupKind {
  /// 有 workspace 归属：标题用 `Workspace.title`。
  workspace,

  /// 仅凭 cwd 聚合：标题用路径末段。
  directory,

  /// 无 cwd：标题留空，由 UI 用 `sessions.groupOther` 本地化。
  unassigned,
}

/// 会话分组。
class SessionGroup {
  const SessionGroup({
    required this.key,
    required this.kind,
    required this.title,
    required this.sessions,
    this.path,
    this.isPinned = false,
  });

  /// 稳定身份：`ws:<workspaceId>` / `cwd:<规范化路径>` / `unassigned`。
  ///
  /// ⚠ 折叠状态必须以它作键 —— 标题会因重命名而变，路径不会。
  final String key;

  final SessionGroupKind kind;

  /// 显示标题。`unassigned` 组为空串，由 UI 本地化。
  final String title;

  final List<SessionSummary> sessions;

  /// 规范化后的路径（workspace 组为 workspace.path）。
  final String? path;

  /// 置顶分组（spec §5.2 的「已置顶」）。
  final bool isPinned;

  /// 组内最近活动时间，用于组间排序。
  DateTime? get latestAt {
    DateTime? best;
    for (final s in sessions) {
      final t = s.updatedAt;
      if (t == null) continue;
      if (best == null || t.isAfter(best)) best = t;
    }
    return best;
  }
}

/// 一次 workspace 读取的完整快照。
///
/// 为什么不能只返回 `List<Workspace>`：归档与置顶信息在 baseline 的
/// **同级字段**里（`archivedSessionIds` / `pinnedSessionIds`），
/// 不在每个 Workspace 内部。只取 `items` 会把它们丢掉 ——
/// 那正是「归档的会话仍然出现在列表里」的原因。
class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.items,
    required this.archivedSessionIds,
    required this.pinnedSessionIds,
  });

  const WorkspaceSnapshot.empty()
      : items = const <Workspace>[],
        archivedSessionIds = const <String>{},
        pinnedSessionIds = const <String>{};

  final List<Workspace> items;

  /// 已归档的会话 id。
  final Set<String> archivedSessionIds;

  /// 已置顶的会话 id（最近置顶在前，这里只关心是否置顶）。
  final Set<String> pinnedSessionIds;

  bool get isEmpty => items.isEmpty && archivedSessionIds.isEmpty;
}

/// 筛选条件。
enum SessionFilter { all, running, withAgent }

/// 会话列表服务。
class SessionBrowser {
  SessionBrowser({required this.unary, required this.mux});

  final UnaryClient unary;
  final MuxClient mux;

  /// 拉会话列表。
  Future<List<SessionSummary>> list() async {
    final raw = await unary.call(
      'session/list',
      args: const {'_request': <String, Object?>{}},
    );
    return SessionController.parseSessionList(raw);
  }

  /// 新建会话。
  ///
  /// ## 参数形态（已按 `tool/schema.json` 核实，非猜测）
  ///
  /// `session/create` 的 `SessionCreateRequest` **没有任何必填字段**
  /// （`"required": []`），四个字段全部可选：
  ///
  /// | 字段 | 含义 |
  /// | --- | --- |
  /// | `workspaceId` | 会话加入的工作区，**与 `cwd` 互斥** |
  /// | `cwd` | 会话独占的目录（不指定工作区时用） |
  /// | `sessionId` | 要复用的空白会话；该 id 下没有可复用会话时作为新会话的身份 |
  /// | `agentPreset` | Agent 预设，省略时用配置的默认值 |
  ///
  /// 因此**不传任何参数**也是合法的：由服务端决定落在哪个目录。
  /// 这也是手机端的正确默认 —— 手机拿不到电脑的文件系统，不该凭空造一个路径。
  ///
  /// ## 返回值
  ///
  /// `SessionCreateValue.sessionId` 是**实际**的会话 id，可能与请求的
  /// `sessionId` 不同（复用了别的空白会话）。调用方必须用返回值，
  /// 不能假设就是自己传进去的那个。
  ///
  /// ## 为什么不在这里 `ensureActive`
  ///
  /// 新建的会话是**空白会话**（`blank: true`），列表里会被过滤掉
  /// （见 `sessions_page.dart` 的 `nonBlank`）。但详情页的 WebView 是
  /// 按 sessionId 直接打开的（`session_webview.dart` 的 `_sessionBootstrap`），
  /// 不依赖 `session/list` 的可见性。激活由用户发出第一条 prompt 时
  /// 由 `SessionController.prompt` 负责（它内部会 `ensureActive`），
  /// 这里提前激活只会让冷会话多一次无用的 follow。
  Future<String> create({
    String? workspaceId,
    String? cwd,
    String? sessionId,
    String? agentPreset,
  }) async {
    // workspaceId 与 cwd 互斥（schema 明确写了 exclusive with cwd）。
    // 两个都传会被服务端拒绝，这里先拦下，错误信息比协议报错更好懂。
    assert(
      workspaceId == null || cwd == null,
      'session/create: workspaceId 与 cwd 互斥，不能同时传',
    );
    final request = <String, Object?>{
      if (workspaceId != null) 'workspaceId': workspaceId,
      if (cwd != null) 'cwd': cwd,
      if (sessionId != null) 'sessionId': sessionId,
      if (agentPreset != null) 'agentPreset': agentPreset,
    };
    final raw = await unary.call(
      'session/create',
      args: {'request': request},
    );
    if (raw is! Map) {
      throw const ProtocolError('session/create did not return an object');
    }
    final id = raw['sessionId'];
    if (id is! String || id.isEmpty) {
      throw const ProtocolError('session/create returned no sessionId');
    }
    return id;
  }

  /// 拉工作区分组。
  ///
  /// `workspace/follow` 是流式端点，这里只取 `baseline` 帧后即取消。
  /// 失败时返回空列表 —— 分组是增强，不应让会话列表整体不可用。
  /// 拉工作区快照（含归档/置顶集合）。
  ///
  /// `workspace/follow` 是流式端点，这里只取 `baseline` 帧后即取消。
  /// 失败时返回空快照 —— 分组与归档过滤是增强，不应让会话列表整体不可用。
  Future<WorkspaceSnapshot> workspaces() async {
    if (!mux.isConnected) return const WorkspaceSnapshot.empty();
    try {
      final stream = mux.openStream(
        'workspace/follow',
        payload: const {'args': <String, Object?>{}},
      );
      var snapshot = const WorkspaceSnapshot.empty();
      await for (final event in stream.events) {
        if (event is! StreamItem) break;
        final v = event.value;
        if (v is! Map) continue;
        final m = v.cast<String, Object?>();
        if (m['type'] != 'baseline') continue;
        final value = m['value'];
        if (value is! Map) continue;
        snapshot = _parseSnapshot(value.cast<String, Object?>());
        break;
      }
      await mux.cancelStream(stream.streamId);
      return snapshot;
    } catch (_) {
      return const WorkspaceSnapshot.empty();
    }
  }

  /// 解析 baseline 的 `value`。
  ///
  /// 结构：`{items: [...], archivedSessionIds: [...], pinnedSessionIds: [...]}`
  /// —— 归档与置顶在**同级**，不在每个 Workspace 里。
  static WorkspaceSnapshot _parseSnapshot(Map<String, Object?> value) {
    final items = value['items'];
    final workspaces = <Workspace>[];
    if (items is List) {
      for (final item in items) {
        if (item is! Map) continue;
        try {
          workspaces.add(Workspace.fromJson(item.cast<String, Object?>()));
        } on ProtocolError {
          continue;
        }
      }
    }
    Set<String> ids(Object? raw) =>
        raw is List ? raw.whereType<String>().toSet() : <String>{};
    return WorkspaceSnapshot(
      items: workspaces,
      archivedSessionIds: ids(value['archivedSessionIds']),
      pinnedSessionIds: ids(value['pinnedSessionIds']),
    );
  }


  /// 按工作区分组 —— **与 PC 端侧栏一致**。
  ///
  /// ## 为什么只认显式成员
  ///
  /// 早先这里用 cwd 路径前缀去「推断」归属（P2/P3），结果是列表里冒出
  /// `workspace`、`tmp`、`T`、`qc-fullstack-workspace` 等一堆分组 ——
  /// 它们**不是工作区**，只是某个目录名。服务端只有 5 个 workspace，
  /// App 却显示 13 个分组，看起来就像脏数据。
  ///
  /// PC 端侧栏只列 `workspace/follow` 返回的 workspace，会话归属也只看
  /// `Workspace.sessionIds`。这里对齐它：
  ///
  /// - 属于某 workspace 的会话 → 该分组
  /// - 其余 → 「未分组」（PC 端也有这一项）
  ///
  /// 不再按 cwd 造分组。用户要归类某个目录，应该去电脑上建 workspace ——
  /// 那才是唯一真相，App 不该发明它。
  static List<SessionGroup> group(
    List<SessionSummary> sessions,
    List<Workspace> workspaces,
  ) {
    final byId = {for (final s in sessions) s.id: s};
    final assigned = <String>{};
    final groups = <SessionGroup>[];

    for (final w in workspaces) {
      final members = <SessionSummary>[];
      for (final sid in w.sessionIds) {
        final s = byId[sid];
        if (s == null) continue;
        members.add(s);
        assigned.add(sid);
      }
      if (members.isEmpty) continue;
      groups.add(
        SessionGroup(
          key: 'ws:${w.id}',
          kind: SessionGroupKind.workspace,
          title: w.title,
          path: normalizeCwd(w.path),
          sessions: _sortWithin(members),
        ),
      );
    }

    final rest = sessions.where((s) => !assigned.contains(s.id)).toList();
    if (rest.isNotEmpty) {
      groups.add(
        SessionGroup(
          key: 'unassigned',
          kind: SessionGroupKind.unassigned,
          // 标题留给 UI 本地化（PC 端叫「未分组」）
          title: '',
          sessions: _sortWithin(rest),
        ),
      );
    }

    _sortGroups(groups);
    return groups;
  }

  /// 组内排序：`updatedAt` 倒序，null 最后，并列按 id。
  static List<SessionSummary> _sortWithin(List<SessionSummary> list) {
    final copy = [...list];
    copy.sort((a, b) {
      final ta = a.updatedAt;
      final tb = b.updatedAt;
      if (ta != null && tb != null) {
        final c = tb.compareTo(ta);
        if (c != 0) return c;
      } else if (ta != null) {
        return -1;
      } else if (tb != null) {
        return 1;
      }
      return a.id.compareTo(b.id);
    });
    return copy;
  }

  /// 组间排序：未归类恒最后；其余按最近活动倒序，无时间排后，并列按标题。
  static void _sortGroups(List<SessionGroup> groups) {
    groups.sort((a, b) {
      final au = a.kind == SessionGroupKind.unassigned;
      final bu = b.kind == SessionGroupKind.unassigned;
      if (au != bu) return au ? 1 : -1;
      final ta = a.latestAt;
      final tb = b.latestAt;
      if (ta != null && tb != null) {
        final c = tb.compareTo(ta);
        if (c != 0) return c;
      } else if (ta != null) {
        return -1;
      } else if (tb != null) {
        return 1;
      }
      return a.title.compareTo(b.title);
    });
  }

  /// 在已分组的列表上搜索。
  ///
  /// 组标题/路径命中 → 整组保留；否则只留命中会话，空组丢弃。
  /// 这样搜索能命中工作区名（`SessionBrowser.search` 只看 title/cwd/id）。
  static List<SessionGroup> searchGroups(
    List<SessionGroup> groups,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return groups;
    final out = <SessionGroup>[];
    for (final g in groups) {
      final groupHit =
          g.title.toLowerCase().contains(q) ||
          (g.path?.toLowerCase().contains(q) ?? false);
      if (groupHit) {
        out.add(g);
        continue;
      }
      final matched = search(g.sessions, q);
      if (matched.isEmpty) continue;
      out.add(
        SessionGroup(
          key: g.key,
          kind: g.kind,
          title: g.title,
          path: g.path,
          sessions: matched,
          isPinned: g.isPinned,
        ),
      );
    }
    return out;
  }

  /// 按标题 / 工作目录搜索。
  static List<SessionSummary> search(
    List<SessionSummary> sessions,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return sessions;
    return sessions.where((s) {
      if ((s.title ?? '').toLowerCase().contains(q)) return true;
      if ((s.cwd ?? '').toLowerCase().contains(q)) return true;
      return s.id.toLowerCase().contains(q);
    }).toList();
  }

  /// 按状态筛选。
  static List<SessionSummary> filter(
    List<SessionSummary> sessions,
    SessionFilter f,
  ) => switch (f) {
    SessionFilter.all => sessions,
    SessionFilter.running => sessions.where((s) => s.running).toList(),
    SessionFilter.withAgent =>
      sessions.where((s) => s.agentAvailable).toList(),
  };
}


/// 归一化路径用于比较/分组键。
///
/// 只做**无损**变换，不猜测语义：
/// - 不展开 `~`（手机端拿不到 host 的 HOME，展开即造假）
/// - 不做大小写折叠（大小写敏感卷上两个不同目录会被错误合并）
/// - 不解析符号链接（要发请求，得不偿失）
String normalizeCwd(String raw) {
  var p = raw.trim();
  if (p.isEmpty) return '';
  p = p.replaceAll(RegExp(r'/+'), '/');
  if (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p;
}

/// `cwd` 是否位于 `root` 之下（含相等）。`root == '/'` 时一切绝对路径都算。
bool isUnder(String cwd, String root) {
  if (root.isEmpty) return false;
  if (root == '/') return cwd.startsWith('/');
  return cwd == root || cwd.startsWith('$root/');
}

