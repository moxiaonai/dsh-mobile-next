/// 通知中心：把散落的事件聚合成一条可持久化的时间线。
///
/// ## 为什么需要这一层
///
/// 原来的「通知」tab 直接渲染 `_ShellState._approvalList` —— 一个内存数组：
///
/// - 只在 App 运行期间累积，**重启即空**
/// - 只收审批，不收提问/任务完成/失败（`InboxCategory` 定义了 6 类，实际只用 1 类）
/// - 没有已读状态
///
/// 所以那一页实质是个空壳。要把「通知」并进任务页，必须先有真正的数据层。
///
/// ## 设计
///
/// - **去重**：同 `id` 的条目只保留最新一条（事件可能重放，`$events` 会重发
///   未结算的 waterfall）
/// - **已读**：只存「已读的 id 集合」，不存整条通知 —— 这样过期清理
///   不会把已读状态一起丢掉
/// - **有界**：最多保留 [maxEntries] 条，超出丢最旧的（防长期运行内存膨胀）
/// - **持久化**：与 `AppearanceStore` 同构（`dart:io` + JSON，零新依赖）
library;

import 'dart:convert';
import 'dart:io';

/// 通知类别。
///
/// 与 `WEB_PUSH.md` 的六类对齐；当前能真实产出的见各值的注释。
enum NoticeKind {
  /// 审批请求（`approval/request`）—— 可产出。
  approval,

  /// 提问（`user-questions/request`）—— 可产出。
  question,

  /// 会话跑完一轮（从 `running` 变 `false`）—— 由会话状态变化推导。
  turnDone,

  /// 会话出错 —— 暂无可观测来源，保留枚举以便将来接入。
  failed,
}

/// 一条通知。
class Notice {
  const Notice({
    required this.id,
    required this.kind,
    required this.sessionId,
    required this.title,
    required this.at,
    this.read = false,
  });

  /// 稳定身份：审批用 eventId、提问用 callId、轮次用 `sessionId@seq`。
  ///
  /// 去重与已读都以它为准 —— **不能用时间戳**，否则同一条会被反复插入。
  final String id;

  final NoticeKind kind;
  final String sessionId;

  /// 一句话说明（如工具名、问题摘要）。
  final String title;

  final DateTime at;
  final bool read;

  Notice copyWith({bool? read}) => Notice(
    id: id,
    kind: kind,
    sessionId: sessionId,
    title: title,
    at: at,
    read: read ?? this.read,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'sessionId': sessionId,
    'title': title,
    'at': at.millisecondsSinceEpoch,
    'read': read,
  };

  static Notice? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final sessionId = json['sessionId'];
    final at = json['at'];
    if (id is! String || id.isEmpty) return null;
    if (sessionId is! String || sessionId.isEmpty) return null;
    if (at is! int) return null;
    NoticeKind kind = NoticeKind.approval;
    final k = json['kind'];
    if (k is String) {
      for (final v in NoticeKind.values) {
        if (v.name == k) {
          kind = v;
          break;
        }
      }
    }
    return Notice(
      id: id,
      kind: kind,
      sessionId: sessionId,
      title: json['title'] is String ? json['title']! as String : '',
      at: DateTime.fromMillisecondsSinceEpoch(at),
      read: json['read'] == true,
    );
  }
}

/// 通知中心的状态机 + 持久化。
///
/// 纯内存操作是同步的（UI 直接读），持久化是异步的（失败静默）。
class NoticeCenter {
  NoticeCenter({this.filePath, this.maxEntries = 200});

  /// 持久化路径。启动时异步解析（path_provider），因此不是 final。
  String? filePath;

  /// 最多保留条数。超出丢最旧的。
  final int maxEntries;

  final List<Notice> _items = [];

  /// 未读数。
  int get unreadCount => _items.where((n) => !n.read).length;

  /// 全部通知，按时间倒序（最新在前）。
  List<Notice> get items {
    final copy = [..._items];
    copy.sort((a, b) => b.at.compareTo(a.at));
    return copy;
  }

  bool get isEmpty => _items.isEmpty;

  /// 读盘。
  Future<void> load() async {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    try {
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final list = decoded['items'];
      if (list is! List) return;
      _items.clear();
      for (final item in list) {
        if (item is! Map) continue;
        final notice = Notice.fromJson(item.cast<String, Object?>());
        if (notice != null) _items.add(notice);
      }
    } catch (_) {
      // 损坏不阻断启动
    }
  }

  /// 加入一条通知（按 id 去重，保留最新）。
  ///
  /// 返回 true 表示这是一条**新**通知（可用于提示音/角标动效）。
  bool add(Notice notice) {
    final index = _items.indexWhere((n) => n.id == notice.id);
    if (index >= 0) {
      _items[index] = notice;
      return false;
    }
    _items.add(notice);
    _trim();
    unawaitedSave();
    return true;
  }

  /// 标记已读。返回是否发生了变化。
  bool markRead(String id) {
    final index = _items.indexWhere((n) => n.id == id);
    if (index < 0 || _items[index].read) return false;
    _items[index] = _items[index].copyWith(read: true);
    unawaitedSave();
    return true;
  }

  /// 全部标记已读。
  void markAllRead() {
    var changed = false;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].read) continue;
      _items[i] = _items[i].copyWith(read: true);
      changed = true;
    }
    if (changed) unawaitedSave();
  }

  /// 清空。
  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    unawaitedSave();
  }

  void _trim() {
    if (_items.length <= maxEntries) return;
    // 按时间升序排，丢最旧的
    _items.sort((a, b) => a.at.compareTo(b.at));
    final drop = _items.length - maxEntries;
    _items.removeRange(0, drop);
  }

  File? get _file {
    final p = filePath;
    if (p == null) return null;
    return File(p);
  }

  /// 落盘（不 await，调用方是同步路径）。
  ///
  /// 失败静默：通知是辅助信息，写不进去不该影响交互。
  void unawaitedSave() {
    final f = _file;
    if (f == null) return;
    // 用 Future 而不是 async 方法：调用方不需要 await，也不想被异常打断。
    Future<void>(() async {
      try {
        await f.parent.create(recursive: true);
        await f.writeAsString(
          jsonEncode({
            'version': 1,
            'items': _items.map((n) => n.toJson()).toList(),
          }),
        );
      } catch (_) {
        // 忽略
      }
    });
  }
}
