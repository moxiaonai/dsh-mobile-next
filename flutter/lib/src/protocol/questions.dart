/// 待处理交互：「需要你」区的数据层。
///
/// ## 提问从哪来（实测确认的链路）
///
/// 这里有一条**反直觉**的结论：`userQuestions.active` 投影是**空的**，
/// 即使 `session/state.pendingInput` 已经报了 `["question"]`。
///
/// 真实路径是：
///
/// 1. `session/state` → `pendingInput: ["question"]` —— 只报**类别**，无内容
/// 2. `session/events`（unary）→ `records[].event` 里找 `type == 'tool/call'`
/// 3. 该事件的 `data.name == 'ask_user_question'`
/// 4. 提问正文在 `data.arguments`（**JSON 字符串**，需要二次解析）
/// 5. `data.callId` 就是回答时要用的 `callId`
///
/// 实测样例：
/// ```json
/// {"type":"tool/call","data":{
///   "callId":"call_00_14mw...",
///   "name":"ask_user_question",
///   "arguments":"{\"questions\":[{\"id\":\"color\",\"question\":\"Which color...\",
///                  \"options\":[{\"label\":\"Red\"},...]}]}"}}
/// ```
///
/// ## 回答
///
/// `userQuestions/answer`（**unary**）参数是平铺的三个：
/// `agentId`、`callId`、`answer: {answers: [{id, selected[], custom?}]}`。
/// **注意不是包在 `request` 里** —— 与 `session/*` 端点的约定不同。
///
/// ⚠ **参数名必须用 `wire` 而非 `name`**：schema 里这个参数
/// `name: 'agent'` 但 `wire: 'agentId'`，线上只认后者。
/// 全库共 **35 处**这种差异（`agent`→`agentId`、
/// `workspaceFileScope`→`workspaceFileScopeId`），
/// 用错会得到 `gateway/arguments-invalid: missing "agentId"; unexpected "agent"`。
library;

import 'dart:convert';

import '../transport/unary.dart';
import 'frames.dart';

/// 一个选项。
class QuestionOption {
  const QuestionOption({required this.label, this.description});

  final String label;
  final String? description;

  factory QuestionOption.fromJson(Map<String, Object?> json) {
    final label = json['label'];
    if (label is! String || label.isEmpty) {
      throw const ProtocolError('question option has no label');
    }
    return QuestionOption(
      label: label,
      description: json['description'] as String?,
    );
  }
}

/// 单个问题。
class Question {
  const Question({
    required this.id,
    required this.question,
    this.header,
    this.detail,
    this.options = const [],
    this.multiSelect = false,
  });

  /// 稳定 id，回答时要原样回传。
  final String id;

  /// 要展示的问题正文。
  final String question;

  /// 可选短标题/分组标签。
  final String? header;

  /// 可选补充说明（渲染在正文旁，不混进选项标签）。
  final String? detail;

  final List<QuestionOption> options;

  /// 是否可多选（默认单选）。
  final bool multiSelect;

  factory Question.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const ProtocolError('question has no id');
    }
    final q = json['question'];
    final rawOpts = json['options'];
    return Question(
      id: id,
      question: q is String ? q : '',
      header: json['header'] as String?,
      detail: json['detail'] as String?,
      options: rawOpts is List
          ? rawOpts
                .whereType<Map>()
                .map((m) => QuestionOption.fromJson(m.cast<String, Object?>()))
                .toList()
          : const [],
      multiSelect: json['multiSelect'] == true,
    );
  }
}

/// 一次待答请求（可能含多个问题）。
class PendingQuestion {
  const PendingQuestion({
    required this.sessionId,
    required this.callId,
    required this.questions,
    this.seq,
  });

  final String sessionId;

  /// 回答时必须回传的 callId。
  final String callId;

  final List<Question> questions;

  /// 事件序号，用于排序。
  final int? seq;

  /// 主标题：优先第一个问题的 header，否则用正文首行。
  String get title {
    if (questions.isEmpty) return '需要你的回答';
    final h = questions.first.header;
    if (h != null && h.isNotEmpty) return h;
    final q = questions.first.question;
    return q.length > 40 ? '${q.substring(0, 40)}…' : q;
  }

  /// 正文摘要。
  String get summary {
    if (questions.isEmpty) return '';
    return questions.first.question;
  }

  @override
  String toString() =>
      'PendingQuestion($sessionId, $callId, ${questions.length} 题)';
}

/// 从 `session/events` 的记录里提取待答提问。
///
/// 只看 `tool/call` + `name == 'ask_user_question'`，并跳过已有对应
/// `user/message`（已回答）的 callId —— 否则会把已答的问题当成待答。
class QuestionExtractor {
  const QuestionExtractor._();

  /// 已答的 callId 集合。
  ///
  /// 回答后 DSH 会插入一条 `user/message`，其 `source` 里带 callId。
  static Set<String> answeredCallIds(List<Object?> records) {
    final out = <String>{};
    for (final r in records) {
      final ev = _eventOf(r);
      if (ev == null) continue;
      if (ev['type'] != 'user/message') continue;
      final data = ev['data'];
      if (data is! Map) continue;
      final source = data['source'];
      final s = _findCallId(source);
      if (s != null) out.add(s);
    }
    return out;
  }

  /// 提取所有待答提问。
  static List<PendingQuestion> extract(
    String sessionId,
    List<Object?> records,
  ) {
    final answered = answeredCallIds(records);
    final out = <PendingQuestion>[];
    for (final r in records) {
      final ev = _eventOf(r);
      if (ev == null) continue;
      if (ev['type'] != 'tool/call') continue;
      final data = ev['data'];
      if (data is! Map) continue;
      if (data['name'] != 'ask_user_question') continue;

      final callId = data['callId'];
      if (callId is! String || callId.isEmpty) continue;
      if (answered.contains(callId)) continue;

      final questions = _parseQuestions(data['arguments']);
      if (questions.isEmpty) continue;

      final seq = ev['seq'];
      out.add(
        PendingQuestion(
          sessionId: sessionId,
          callId: callId,
          questions: questions,
          seq: seq is num ? seq.toInt() : null,
        ),
      );
    }
    // 最新的在前
    out.sort((a, b) => (b.seq ?? 0).compareTo(a.seq ?? 0));
    return out;
  }

  /// `arguments` 是 **JSON 字符串**，需要二次解析。
  static List<Question> _parseQuestions(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return const [];
      }
    }
    if (decoded is! Map) return const [];
    final list = decoded['questions'];
    if (list is! List) return const [];
    final out = <Question>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        out.add(Question.fromJson(item.cast<String, Object?>()));
      } on ProtocolError {
        continue;
      }
    }
    return out;
  }

  static Map<String, Object?>? _eventOf(Object? record) {
    if (record is! Map) return null;
    final ev = record['event'];
    if (ev is! Map) return null;
    return ev.cast<String, Object?>();
  }

  /// 在任意嵌套结构里找形如 callId 的字符串。
  static String? _findCallId(Object? value) {
    if (value is String) {
      return value.startsWith('call_') ? value : null;
    }
    if (value is Map) {
      for (final v in value.values) {
        final hit = _findCallId(v);
        if (hit != null) return hit;
      }
    }
    if (value is List) {
      for (final v in value) {
        final hit = _findCallId(v);
        if (hit != null) return hit;
      }
    }
    return null;
  }
}

/// 一次回答：某题的选项 + 可选自定义文本。
class QuestionAnswer {
  const QuestionAnswer({
    required this.id,
    required this.selected,
    this.custom,
  });

  final String id;
  final List<String> selected;
  final String? custom;

  Map<String, Object?> toJson() => {
    'id': id,
    'selected': selected,
    if (custom != null && custom!.isNotEmpty) 'custom': custom,
  };
}

/// 待答查询 + 回答的客户端。
class QuestionCenter {
  QuestionCenter({required this.unary});

  final UnaryClient unary;

  /// 拉一个会话的待答提问。
  ///
  /// 内部走 `session/events`（unary），而不是投影 —— 投影的
  /// `userQuestions.active` 实测为空（见文件头说明）。
  Future<List<PendingQuestion>> pending(String sessionId) async {
    final raw = await unary.call(
      'session/events',
      args: {
        'request': {
          'address': {'kind': 'session', 'sessionId': sessionId},
          'limit': 200,
        },
      },
    );
    if (raw is! Map) return const [];
    final records = raw['records'];
    if (records is! List) return const [];
    return QuestionExtractor.extract(sessionId, records);
  }

  /// 提交回答。
  ///
  /// ⚠ 参数是**平铺**的 `agent` / `callId` / `answer`，
  /// 不包在 `request` 里 —— 与 `session/*` 的约定不同。
  ///
  /// 返回 `true` 表示问题仍在继续（答复已排队，等 agent 接收）。
  Future<bool> answer({
    required String sessionId,
    required String callId,
    required List<QuestionAnswer> answers,
  }) async {
    final value = await unary.call(
      'userQuestions/answer',
      args: {
        // wire 名是 agentId，不是 agent（见文件头说明）
        'agentId': sessionId,
        'callId': callId,
        'answer': {
          'answers': answers.map((a) => a.toJson()).toList(),
        },
      },
    );
    return value == true;
  }
}
