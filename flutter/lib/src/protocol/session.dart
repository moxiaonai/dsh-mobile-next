/// 会话操作封装。
///
/// 这一层存在的理由是协议里两个**反直觉**的行为（spike 实测确认，
/// 见 `docs/60-protocol-feasibility.md` §5）：
///
/// 1. **双载具**：`session/list`、`session/prompt`、`session/state` 等 unary
///    端点走 HTTP；`session/follow`、`$events` 等流式端点走 WebSocket。
///    走错载体分别得到 `gateway/signature-invalid` 与 404。
///
/// 2. **冷会话陷阱**：对一个没有活 Agent 的会话直接 `session/prompt`，
///    服务端返回 `{"accepted": true}` 然后**什么都不做** —— 无错误、无事件。
///    必须先 `session/follow {activate: true}` 把会话激活。
///    [SessionController.prompt] 通过 [ensureActive] 强制这一点。
library;

import 'dart:async';

import '../protocol/frames.dart';
import '../transport/mux.dart';
import '../transport/unary.dart';

/// 会话摘要。字段取自 `session/list` 的返回值，只声明实际用到的部分。
class SessionSummary {
  const SessionSummary({
    required this.id,
    this.title,
    this.updatedAt,
    this.running = false,
    this.agentAvailable = false,
    this.blank = false,
    this.cwd,
    this.pendingQuestions = const [],
    this.raw = const {},
  });

  final String id;
  final String? title;
  final DateTime? updatedAt;

  /// 该会话当前是否有一轮在跑。
  final bool running;

  /// 该会话是否持有活 Agent。
  ///
  /// **这个字段很关键**：为 false 时直接 `session/prompt` 会静默成功而不执行，
  /// 必须先 `session/follow {activate:true}`（见 [SessionController.prompt]）。
  final bool agentAvailable;

  final bool blank;

  /// 当前工作目录。
  final String? cwd;

  /// 待答提问（来自 `projections.values.userQuestions.active`）。
  ///
  /// 实测 `session/list` 一次返回全部会话的这个字段，
  /// 因此不需要逐会话查询就能做「需要你」聚合。
  final List<PendingQuestionSummary> pendingQuestions;

  /// 原始 JSON，保留未建模字段，避免过早丢失信息。
  final Map<String, Object?> raw;

  factory SessionSummary.fromJson(Map<String, Object?> json) {
    final id = json['id'] ?? json['sessionId'];
    if (id is! String || id.isEmpty) {
      throw const ProtocolError('session summary has no id');
    }

    DateTime? updated;
    final rawUpdated = json['updatedAt'] ?? json['lastActivityAt'];
    if (rawUpdated is num) {
      updated = DateTime.fromMillisecondsSinceEpoch(rawUpdated.toInt());
    } else if (rawUpdated is String) {
      updated = DateTime.tryParse(rawUpdated);
    }

    // ⚠ 标题不在顶层，而在 `projections.values.title`
    // （schema 已确认：SessionListValue.items[].projections.values.title）。
    // 早期版本读顶层 `title`，导致 title 永远是 null —— 这是实测发现的 bug。
    final projections = json['projections'];
    String? title;
    String? workingDirectory;
    if (projections is Map) {
      final values = projections['values'];
      if (values is Map) {
        final t = values['title'];
        if (t is String && t.isNotEmpty) title = t;
        final wd = values['workingDirectory'];
        if (wd is String && wd.isNotEmpty) workingDirectory = wd;
      }
    }

    final cwd = json['cwd'] is String
        ? json['cwd'] as String
        : workingDirectory;

    // 待答提问：`projections.values.userQuestions.active`
    final pending = <PendingQuestionSummary>[];
    if (projections is Map) {
      final values = projections['values'];
      if (values is Map) {
        final uq = values['userQuestions'];
        if (uq is Map) {
          final active = uq['active'];
          if (active is List) {
            for (final item in active) {
              if (item is! Map) continue;
              final qs = item['questions'];
              if (qs is! List || qs.isEmpty) continue;
              final first = qs.first;
              if (first is! Map) continue;
              final text = first['question'];
              final header = first['header'];
              pending.add(
                PendingQuestionSummary(
                  callId: item['callId'] as String? ?? '',
                  question: text is String ? text : '',
                  header: header is String ? header : null,
                  count: qs.length,
                ),
              );
            }
          }
        }
      }
    }

    return SessionSummary(
      id: id,
      title: title,
      updatedAt: updated,
      running: json['running'] == true,
      agentAvailable: json['agentAvailable'] == true,
      blank: json['blank'] == true,
      cwd: cwd,
      pendingQuestions: pending,
      raw: json,
    );
  }

  @override
  String toString() =>
      'SessionSummary($id, ${title ?? '(untitled)'}'
      '${running ? ', running' : ''}${agentAvailable ? ', agent' : ''})';
}

/// 待答提问摘要（只含展示所需字段）。
///
/// 完整提问结构在 `questions.dart` 的 `Question`；
/// 这里只保留 `session/list` 投影直接给出的部分。
class PendingQuestionSummary {
  const PendingQuestionSummary({
    required this.callId,
    required this.question,
    this.header,
    this.count = 1,
  });

  final String callId;
  final String question;
  final String? header;

  /// 本次请求包含几道题。
  final int count;

  @override
  String toString() => 'PendingQuestionSummary($callId, $question)';
}

/// 会话控制器：把双载具的差异收在这一个类里。
class SessionController {
  SessionController({required this.unary, required this.mux});

  final UnaryClient unary;
  final MuxClient mux;

  /// 已激活的会话，避免重复 follow。
  final Set<String> _active = {};

  /// 会话列表。
  ///
  /// 注意 `session/list` 的 Typert 描述符声明了一个必填参数 `_request`，
  /// 传空 args 会被拒（`gateway/arguments-invalid: missing "_request"`）。
  /// 这是实测发现的，不是文档里写明的。
  Future<List<SessionSummary>> list() async {
    final value = await unary.call(
      'session/list',
      args: const {'_request': <String, Object?>{}},
    );
    final items = _extractList(value);
    return items.map(SessionSummary.fromJson).toList(growable: false);
  }

  /// 确保会话已激活。
  ///
  /// 这是**冷会话陷阱**的唯一正确解法：`session/follow {activate:true}`。
  /// 返回该会话的 follow 流，调用方可持续读取 turn 事件。
  ///
  /// 若已经激活过则直接返回 `null`（表示无需重复 follow）。
  Future<RemoteStream?> ensureActive(String sessionId) async {
    if (_active.contains(sessionId)) return null;
    if (!mux.isConnected) {
      throw StateError('cannot activate session: mux is not connected');
    }
    final stream = mux.openStream(
      'session/follow',
      payload: {
        'args': {
          'request': {'sessionId': sessionId, 'activate': true},
        },
      },
    );

    // 等到 opening 帧（官方为 `snapshot`）出现才算激活成功。
    // 只等首帧，不消费后续 turn 事件 —— 它们由调用方从同一 stream 读取。
    await _awaitOpening(stream, sessionId);
    _active.add(sessionId);
    return stream;
  }

  Future<void> _awaitOpening(RemoteStream stream, String sessionId) async {
    final completer = Completer<void>();
    late StreamSubscription<StreamEvent> sub;
    sub = stream.events.listen(
      (event) {
        switch (event) {
          case StreamItem():
            if (!completer.isCompleted) completer.complete();
          case StreamFailed(:final error):
            if (!completer.isCompleted) {
              completer.completeError(
                UnaryException('session/follow failed: ${error.code}',
                    remote: error),
              );
            }
          case StreamEnded():
            if (!completer.isCompleted) {
              completer.completeError(
                const UnaryException('session/follow ended before opening frame'),
              );
            }
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    try {
      await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw const UnaryException(
          'session/follow did not produce an opening frame within 15s',
        ),
      );
    } finally {
      // 只退订这个探测订阅，stream 本身仍归调用方使用。
      await sub.cancel();
    }
  }

  /// 发送一条 prompt。
  ///
  /// 会**先确保会话已激活**，否则服务端会静默接受而不执行。
  /// [mode] 为 `queue`（默认）或 `steer`。
  Future<void> prompt(
    String sessionId,
    String content, {
    String mode = 'queue',
    String? requestId,
  }) async {
    await ensureActive(sessionId);

    // ⚠ 参数必须包在 `request` 里。直接平铺会报：
    //   gateway/arguments-invalid: args fields do not match the descriptor:
    //   missing "request"; unexpected "requestId", "sessionId", ...
    await unary.call(
      'session/prompt',
      args: {
        'request': {
          'requestId': requestId ?? _newRequestId(),
          'sessionId': sessionId,
          'mode': mode,
          'content': [
            {'type': 'text', 'text': content},
          ],
        },
      },
    );
  }

  /// 取消当前 turn。
  Future<void> cancel(String sessionId) async {
    await unary.call(
      'session/cancel',
      args: {
        'request': {'sessionId': sessionId},
      },
    );
  }

  /// 会话状态。
  Future<Map<String, Object?>> state(String sessionId) async {
    final value = await unary.call(
      'session/state',
      args: {
        'request': {'sessionId': sessionId},
      },
    );
    if (value is Map) return value.cast<String, Object?>();
    throw const ProtocolError('session/state did not return an object');
  }

  /// 忘记激活状态（重连后必须调用，因为服务端的活 Agent 绑定已失效）。
  void resetActivation([String? sessionId]) {
    if (sessionId == null) {
      _active.clear();
    } else {
      _active.remove(sessionId);
    }
  }

  static int _requestSeq = 0;
  static String _newRequestId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'dshm-req-$now-${(_requestSeq++).toRadixString(36)}';
  }

  /// 从 `session/list` 的返回值中取出数组。
  ///
  /// 服务端可能直接返回数组，也可能包在 `sessions` / `items` 里；
  /// 两种都接受，其余形态视为协议错误而不是静默返回空列表。
  static List<Map<String, Object?>> _extractList(Object? value) {
    if (value is List) {
      return value
          .whereType<Map>()
          .map((m) => m.cast<String, Object?>())
          .toList(growable: false);
    }
    if (value is Map) {
      for (final key in const ['sessions', 'items', 'list']) {
        final inner = value[key];
        if (inner is List) {
          return inner
              .whereType<Map>()
              .map((m) => m.cast<String, Object?>())
              .toList(growable: false);
        }
      }
    }
    throw ProtocolError(
      'session/list returned an unexpected shape: ${value.runtimeType}',
    );
  }

  /// 公开版本的 [_extractList]，供联调脚本与测试复用。
  static List<SessionSummary> parseSessionList(Object? value) =>
      _extractList(value).map(SessionSummary.fromJson).toList(growable: false);
}
