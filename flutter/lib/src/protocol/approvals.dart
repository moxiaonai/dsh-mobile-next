/// 审批（approval）：接管 `approval/request` waterfall。
///
/// ## 协议（实测确认）
///
/// 审批通过 **`$events` 流上的 `waterfall` 帧**到达客户端，结构：
///
/// ```json
/// {"type":"waterfall","event":"approval/request",
///  "eventId":"32babc2d-...","agentId":"session-...",
///  "request":{
///    "toolName":"bash",
///    "callId":"call_00_t9hf...",
///    "reason":"escalate sandbox to danger-full-access: ...",
///    "displayReason":{"en":"...","zh":"允许本次操作使用 danger-full-access 权限：..."}}}
/// ```
///
/// ## 回复
///
/// 走 `POST /api/$events/result`（**网关内部端点**，不在业务端点表里），
/// 载荷是 `{clientId, eventId, outcome}`：
///
/// | outcome.kind | 含义 |
/// | --- | --- |
/// | `next` | 放行给下一个监听者（不表态） |
/// | `result` | 返回结果，`value` 即审批结论 |
/// | `rejected` | 抛出异常（**不是**审批拒绝，会变成 `unavailable`） |
///
/// `clientId` 来自 `$events` 的 `ready` 帧。
///
/// ## ⚠ `value` 必须用官方词表
///
/// DSH 核心 `dsh-user-approval` 的 waterfall 回调是：
///
/// ```js
/// waterfall(..., 'approval/request', req, () => Promise.resolve('unavailable'))
///   .then(outcome => OUTCOMES.includes(outcome) ? outcome : 'unavailable')
/// ```
///
/// `OUTCOMES = ['allowed-once', 'rejected', 'cancelled', 'unavailable']`。
/// 返回值**不在词表里会被归一化为 `unavailable`**（fail closed），
/// 也就是「什么都没发生」。这就是最初用 `{kind:'result'}` 不带 value 时
/// 审批一直挂起的原因。
///
/// ## 与提问的区别
///
/// 提问（`user-questions/request`）同样走 waterfall，但**回答方式不同**：
/// 提问用 `userQuestions/answer`（unary，按 callId），
/// 审批用 `$events/result`（按 eventId）。
/// 两者不要混用。
library;


import '../transport/unary.dart';
import 'frames.dart';

/// 一次待审批请求。
class PendingApproval {
  const PendingApproval({
    required this.sessionId,
    required this.eventId,
    required this.callId,
    required this.toolName,
    required this.reason,
    this.displayReason = const {},
  });

  /// 所属会话（waterfall 帧的 `agentId`）。
  final String sessionId;

  /// 回复时必须回传的 eventId。
  final String eventId;

  /// 被审批的工具调用 id。
  final String callId;

  /// 工具名（`bash` / `write` 等）。
  final String toolName;

  /// 英文原因（原文）。
  final String reason;

  /// 多语言原因。键是语言码（`en` / `zh`），值是文案。
  final Map<String, String> displayReason;

  /// 按语言取原因，回退到英文原文。
  String localizedReason([String language = 'zh']) {
    final hit = displayReason[language];
    if (hit != null && hit.isNotEmpty) return hit;
    final en = displayReason['en'];
    if (en != null && en.isNotEmpty) return en;
    return reason;
  }

  /// 是否涉及沙箱升级（危险操作）。
  ///
  /// 依据 `reason` 里的 `escalate sandbox to` 前缀 —— 这是实测到的唯一
  /// 可判定信号。不做更激进的语义推断（比如解析命令内容），因为那不可靠。
  bool get isSandboxEscalation =>
      reason.startsWith('escalate sandbox to') ||
      reason.contains('danger-full-access');

  factory PendingApproval.fromWaterfall(
    Map<String, Object?> frame,
    Map<String, Object?> request,
  ) {
    final eventId = frame['eventId'];
    if (eventId is! String || eventId.isEmpty) {
      throw const ProtocolError('approval frame has no eventId');
    }
    final agentId = frame['agentId'];
    final callId = request['callId'];
    final toolName = request['toolName'];
    final reason = request['reason'];

    final display = <String, String>{};
    final rawDisplay = request['displayReason'];
    if (rawDisplay is Map) {
      for (final e in rawDisplay.entries) {
        if (e.key is String && e.value is String) {
          display[e.key as String] = e.value as String;
        }
      }
    }

    return PendingApproval(
      sessionId: agentId is String ? agentId : '',
      eventId: eventId,
      callId: callId is String ? callId : '',
      toolName: toolName is String ? toolName : 'unknown',
      reason: reason is String ? reason : '',
      displayReason: display,
    );
  }

  @override
  String toString() =>
      'PendingApproval($toolName, ${callId.isEmpty ? '-' : callId}, $eventId)';
}

/// 审批回复。
enum ApprovalDecision {
  /// 允许。
  approve,

  /// 拒绝。
  deny,

  /// 不表态，交给下一个监听者。
  pass,
}

/// 审批客户端。
///
/// 需要 `$events` 的 `clientId` 才能回复 —— 该值由 [setClientId] 注入，
/// 通常来自 `$events` 的 `ready` 帧。
class ApprovalCenter {
  ApprovalCenter({required this.unary});

  final UnaryClient unary;

  /// `$events` 的 generation id（ready 帧的 `clientId`）。
  String? _clientId;

  String? get clientId => _clientId;

  /// 记录 `$events` 的 clientId。收到 ready 帧时调用。
  void setClientId(String? id) {
    _clientId = id;
  }

  /// 回复一次审批。
  ///
  /// [reason] 当前**不进入线上载荷** —— 审批结论是封闭词表，没有理由字段。
  /// 保留该参数是为了将来若协议扩展可复用；不要用它承载业务语义。
  Future<void> respond(
    PendingApproval approval,
    ApprovalDecision decision, {
    String? reason,
  }) async {
    final cid = _clientId;
    if (cid == null || cid.isEmpty) {
      throw StateError(r'clientId 未设置：需先收到 $events 的 ready 帧');
    }

    // value 必须落在官方 OUTCOMES 词表内，否则被归一化为 'unavailable'。
    final outcome = switch (decision) {
      ApprovalDecision.approve => <String, Object?>{
        'kind': 'result',
        'value': 'allowed-once',
      },
      ApprovalDecision.deny => <String, Object?>{
        'kind': 'result',
        'value': 'rejected',
      },
      ApprovalDecision.pass => <String, Object?>{'kind': 'next'},
    };

    // `$events/result` 是网关内部端点，走 HTTP unary 载体。
    await unary.call(
      r'$events/result',
      args: {
        'clientId': cid,
        'eventId': approval.eventId,
        'outcome': outcome,
      },
    );
  }
}

/// 从 `$events` 帧里提取审批与提问。
///
/// `$events` 的帧是 `{type, event, eventId, agentId, request}`。
/// 只有 `type == 'waterfall'` 且 `event` 匹配时才提取。
class WaterfallExtractor {
  const WaterfallExtractor._();

  static const String questionEvent = 'user-questions/request';
  static const String approvalEvent = 'approval/request';

  /// 判断是否审批帧。
  static bool isApproval(Map<String, Object?> frame) =>
      frame['type'] == 'waterfall' && frame['event'] == approvalEvent;

  /// 判断是否提问帧。
  static bool isQuestion(Map<String, Object?> frame) =>
      frame['type'] == 'waterfall' && frame['event'] == questionEvent;

  /// 解析审批帧。失败返回 null（不抛，避免单个坏帧打断流）。
  static PendingApproval? approval(Map<String, Object?> frame) {
    if (!isApproval(frame)) return null;
    final request = frame['request'];
    if (request is! Map) return null;
    try {
      return PendingApproval.fromWaterfall(
        frame,
        request.cast<String, Object?>(),
      );
    } on ProtocolError {
      return null;
    }
  }

  /// 从 `ready` 帧取 clientId。
  static String? clientIdOf(Map<String, Object?> frame) {
    if (frame['type'] != 'ready') return null;
    final id = frame['clientId'];
    return id is String && id.isNotEmpty ? id : null;
  }
}
