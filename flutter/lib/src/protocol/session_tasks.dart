/// 会话任务列表：把「会话」聚合为「任务」视角。
///
/// ## 与「后台任务」的区别
///
/// 之前的 `job/list` 展示的是**后台命令执行记录**（`brew install …` 这类）。
/// 那是实现细节，不是用户心智里的「任务」。
///
/// 这一层把**会话**作为任务单位：一个会话 = 一件正在进行的工作。
/// 用户关心的是「哪件事卡住了等我」「哪件在跑」「哪件完成了」。
///
/// ## 数据来源
///
/// `session/list`（unary）一次调用就返回全部会话，每项自带：
/// - `running` —— 该会话是否有轮次在跑
/// - `agentAvailable` —— 是否持有活 Agent
/// - `projections.values.title` —— 会话标题
/// - `projections.values.userQuestions.active` —— **待答提问**（含正文）
/// - `projections.values.workingDirectory` —— 工作目录
///
/// 实测 90 个会话一次拉完，不需要逐个查询。
///
/// ## 待处理的三类信号
///
/// | 信号 | 来源 | 可信度 |
/// | --- | --- | --- |
/// | 待答提问 | `userQuestions.active` | 直接可用 |
/// | 运行中 | `running` | 直接可用 |
/// | 待审批 | **投影里没有** | 只能靠 `$events` 的 waterfall |
///
/// 因此待审批数**不从这里算** —— 由审批中心单独提供，不伪造。
library;

import 'session.dart';

/// 会话任务的分类。
enum SessionTaskKind {
  /// 有轮次在跑。
  running,

  /// 有提问等着回答。
  needsAnswer,

  /// 有活 Agent 但没在跑（空闲待命）。
  idle,

  /// 无 Agent，历史会话。
  dormant,
}

/// 一个会话任务。
class SessionTask {
  const SessionTask({
    required this.session,
    required this.kind,
    this.pendingQuestionCount = 0,
    this.pendingQuestionSummary,
  });

  final SessionSummary session;
  final SessionTaskKind kind;

  /// 待答提问数。
  final int pendingQuestionCount;

  /// 第一个待答提问的正文（用于卡片标题）。
  final String? pendingQuestionSummary;

  String get id => session.id;
  String get title =>
      session.title ?? '会话 ${session.id.substring(0, 8)}';

  /// 是否「需要你」。
  bool get needsYou => pendingQuestionCount > 0;

  /// 最近活动时间（用于排序）。
  DateTime? get updatedAt => session.updatedAt;
}

/// 会话任务聚合。
class SessionTasks {
  const SessionTasks._();

  /// 从会话列表构建任务列表。
  ///
  /// 排序：需要你 → 运行中 → 空闲 → 沉睡，同类按最近活动倒序。
  static List<SessionTask> build(List<SessionSummary> sessions) {
    final out = <SessionTask>[];
    for (final s in sessions) {
      // 跳过空白会话（刚创建还没说话）
      if (s.blank) continue;

      final q = s.pendingQuestions;
      final kind = q.isNotEmpty
          ? SessionTaskKind.needsAnswer
          : s.running
          ? SessionTaskKind.running
          : s.agentAvailable
          ? SessionTaskKind.idle
          : SessionTaskKind.dormant;

      out.add(
        SessionTask(
          session: s,
          kind: kind,
          pendingQuestionCount: q.length,
          pendingQuestionSummary: q.isEmpty ? null : q.first.question,
        ),
      );
    }

    out.sort((a, b) {
      final rank = _rank(a.kind).compareTo(_rank(b.kind));
      if (rank != 0) return rank;
      final at = a.updatedAt;
      final bt = b.updatedAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return out;
  }

  static int _rank(SessionTaskKind k) => switch (k) {
    SessionTaskKind.needsAnswer => 0,
    SessionTaskKind.running => 1,
    SessionTaskKind.idle => 2,
    SessionTaskKind.dormant => 3,
  };

  /// 分区：需要你 / 进行中 / 其他。
  static ({List<SessionTask> needsYou, List<SessionTask> active, List<SessionTask> rest})
  group(List<SessionTask> tasks) {
    return (
      needsYou: tasks.where((t) => t.needsYou).toList(),
      active: tasks
          .where((t) => !t.needsYou && t.kind == SessionTaskKind.running)
          .toList(),
      rest: tasks
          .where(
            (t) =>
                !t.needsYou &&
                t.kind != SessionTaskKind.running,
          )
          .toList(),
    );
  }
}
