/// 任务中心页面。
///
/// 数据来自 [JobCenter.watch]（`job/list` 流），每帧是**完整集合**，
/// 因此这里直接替换列表，不做增量合并。
///
/// 分区顺序对齐 `docs/10-ui-spec.md` §5.1：
/// **需要你** → 进行中 → 最近完成。
///
/// 「需要你」的数据来自 [QuestionCenter]（`session/events` 的 `tool/call`），
/// 不是投影 —— 投影的 `userQuestions.active` 实测为空，见 questions.dart 说明。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/approvals.dart';
import '../protocol/jobs.dart';
import '../protocol/questions.dart';
import '../transport/mux.dart';
import 'approval_widgets.dart';
import 'job_output_page.dart';
import '../app_strings.dart';
import 'job_widgets.dart';
import 'question_widgets.dart';
import 'tokens.dart';

/// 任务中心。
class JobCenterPage extends StatefulWidget {
  const JobCenterPage({
    super.key,
    required this.sessionId,
    required this.watch,
    required this.onKill,
    this.questionCenter,
    this.approvalCenter,
    this.mux,
    this.onBack,
    this.title = '任务',
  });

  /// 当前会话（`job/list` 需要 sessionId 才能确定可见集合）。
  final String sessionId;

  /// 订阅任务列表。由调用方注入，便于测试替换。
  final Stream<List<JobSummary>> Function(String sessionId) watch;

  /// 终止任务。
  final Future<JobKillResult> Function(String jobId) onKill;

  /// 待答查询与回答。为 null 时不显示提问卡。
  final QuestionCenter? questionCenter;

  /// 审批回复。为 null 时不显示审批卡。
  final ApprovalCenter? approvalCenter;

  /// mux 连接，用于 `job/follow` 输出流。为 null 时详情不显示「查看输出」。
  final MuxClient? mux;

  /// 返回回调。为 null 时不显示返回按钮。
  ///
  /// 作为 tab 页时为 null（底部导航就是出口）；
  /// 被 push 打开时必须提供，否则用户没有退出路径 —— 实测踩过这个坑。
  ///
  /// 用回调而不是内部 `Navigator.pop`，是因为本页可能被
  /// 「setState 切换 body」的宿主（而非 Navigator）承载，
  /// 此时 pop 会回到错误的层级。
  final VoidCallback? onBack;

  final String title;

  @override
  State<JobCenterPage> createState() => _JobCenterPageState();
}

class _JobCenterPageState extends State<JobCenterPage> {
  StreamSubscription<List<JobSummary>>? _sub;
  List<JobSummary> _jobs = const [];
  Object? _error;
  bool _loading = true;

  List<PendingQuestion> _pending = const [];
  String? _busyCallId;
  final Set<String> _dismissed = {};
  Timer? _questionPoll;

  /// 审批来自 `$events` 的 waterfall 帧，由 [registerApproval] 注入。
  final List<PendingApproval> _approvals = [];
  String? _busyEventId;

  /// 追加一条审批（由外部在收到 waterfall 帧时调用）。
  void registerApproval(PendingApproval approval) {
    if (!mounted) return;
    if (_approvals.any((a) => a.eventId == approval.eventId)) return;
    setState(() => _approvals.add(approval));
  }

  /// 移除一条审批（已回复或已失效）。
  void removeApproval(String eventId) {
    if (!mounted) return;
    setState(() => _approvals.removeWhere((a) => a.eventId == eventId));
  }

  @override
  void initState() {
    super.initState();
    _subscribe();
    _startQuestionPolling();
  }

  /// 轮询待答。
  ///
  /// 为什么用轮询而不是事件流：`$events` 的转发事件里**没有**提问内容
  /// （只有 `api-session/*` 等应用级事件），提问正文在 `session/events`
  /// 的历史记录里。轮询是当前唯一可靠的方式。
  ///
  /// 间隔 8s：提问不是高频事件，且每次要读 200 条记录，太频繁会浪费带宽。
  void _startQuestionPolling() {
    final qc = widget.questionCenter;
    if (qc == null) return;
    unawaited(_refreshQuestions());
    _questionPoll = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_refreshQuestions());
    });
  }

  Future<void> _refreshQuestions() async {
    final qc = widget.questionCenter;
    if (qc == null) return;
    try {
      final list = await qc.pending(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _pending = list
            .where((p) => !_dismissed.contains(p.callId))
            .toList(growable: false);
      });
    } catch (_) {
      // 轮询失败不打断 UI；下次重试。
    }
  }

  Future<void> _answer(PendingQuestion p, Question q, String label) async {
    final qc = widget.questionCenter;
    if (qc == null) return;
    setState(() => _busyCallId = p.callId);
    try {
      await qc.answer(
        sessionId: widget.sessionId,
        callId: p.callId,
        answers: [
          QuestionAnswer(id: q.id, selected: [label]),
        ],
      );
      if (!mounted) return;
      // 乐观移除：答复已提交，不必等 agent 消费
      setState(() {
        _pending = _pending
            .where((x) => x.callId != p.callId)
            .toList(growable: false);
        _busyCallId = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已提交：$label')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyCallId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('提交失败：$e')));
    }
  }

  Future<void> _decide(PendingApproval a, ApprovalDecision d) async {
    final ac = widget.approvalCenter;
    if (ac == null) return;
    setState(() => _busyEventId = a.eventId);
    try {
      await ac.respond(a, d);
      if (!mounted) return;
      setState(() {
        _approvals.removeWhere((x) => x.eventId == a.eventId);
        _busyEventId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(d == ApprovalDecision.approve ? AppStrings.of(context)('jobs.allowed') : AppStrings.of(context)('jobs.denied')),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyEventId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败：$e')));
    }
  }

  void _dismiss(PendingQuestion p) {
    setState(() {
      _dismissed.add(p.callId);
      _pending = _pending
          .where((x) => x.callId != p.callId)
          .toList(growable: false);
    });
  }

  void _subscribe() {
    _sub?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    _sub = widget.watch(widget.sessionId).listen(
      (jobs) {
        if (!mounted) return;
        setState(() {
          // 每帧是全集，直接替换。
          _jobs = jobs;
          _loading = false;
          _error = null;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _error = e;
          _loading = false;
        });
      },
    );
  }

  @override
  void dispose() {
    _questionPoll?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);

    final live = _jobs.where((j) => j.isLive).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final done = _jobs.where((j) => j.isSettled).toList()
      ..sort((a, b) {
        final af = a.finishedAt ?? a.startedAt;
        final bf = b.finishedAt ?? b.startedAt;
        return bf.compareTo(af);
      });

    // 被 push 打开时，Android 的系统返回（手势/返回键）应能退出。
    // Scaffold 默认已支持，这里显式声明只是为了语义清晰。
    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async => _subscribe(),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.s7,
                    Space.s6,
                    Space.s7,
                    Space.s2,
                  ),
                  child: Row(
                    children: [
                      if (widget.onBack != null) ...[
                        SizedBox(
                          width: Hit.min,
                          height: Hit.min,
                          child: IconButton(
                            onPressed: widget.onBack,
                            icon: Icon(
                              Icons.chevron_left,
                              color: t.textSecondary,
                            ),
                            tooltip: AppStrings.of(context)('common.back'),
                          ),
                        ),
                        const SizedBox(width: Space.s2),
                      ],
                      Text(widget.title, style: txt.h1),
                      const Spacer(),
                      if (_error != null)
                        IconButton(
                          onPressed: _subscribe,
                          icon: const Icon(Icons.refresh),
                          color: t.textSecondary,
                          tooltip: AppStrings.of(context)('common.retry'),
                        ),
                    ],
                  ),
                ),
              ),
              if (_loading && _jobs.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null && _jobs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ErrorState(error: _error!, onRetry: _subscribe),
                )
              else if (_jobs.isEmpty && _pending.isEmpty && _approvals.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    title: AppStrings.of(context)('jobs.empty'),
                    body: AppStrings.of(context)('jobs.emptyHint'),
                    icon: Icons.task_alt,
                  ),
                )
              else ...[
                if (_approvals.isNotEmpty) ...[
                  _section(AppStrings.of(context)('jobs.awaitingApproval'), _approvals.length),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.s7,
                      ),
                      child: ApprovalsSection(
                        approvals: _approvals,
                        busyEventId: _busyEventId,
                        onDecide: _decide,
                      ),
                    ),
                  ),
                ],
                if (_pending.isNotEmpty) ...[
                  _section(AppStrings.of(context)('tasks.needsYou'), _pending.length),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.s7,
                      ),
                      child: NeedsYouSection(
                        pending: _pending,
                        busyCallId: _busyCallId,
                        onAnswer: (p, q, label) => _answer(p, q, label),
                        onDismiss: _dismiss,
                      ),
                    ),
                  ),
                ],
                if (live.isNotEmpty) ...[
                  _section(AppStrings.of(context)('jobs.runningSection'), live.length),
                  _rows(live),
                ],
                if (done.isNotEmpty) ...[
                  _section(AppStrings.of(context)('jobs.recentDone'), done.length),
                  _rows(done),
                ],
              ],
              const SliverToBoxAdapter(child: SizedBox(height: Space.s12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String title, int count) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.s7,
        Space.s6,
        Space.s7,
        0,
      ),
      child: SectionHeader(title: title, count: count),
    ),
  );

  Widget _rows(List<JobSummary> jobs) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: Space.s7),
    sliver: SliverList.separated(
      itemCount: jobs.length,
      separatorBuilder: (_, _) => const SizedBox(height: Space.s4),
      itemBuilder: (context, i) {
        final job = jobs[i];
        return TaskRow(
          job: job,
          onTap: () => _openDetail(job),
        );
      },
    ),
  );

  Future<void> _openDetail(JobSummary job) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _JobDetailSheet(
        job: job,
        onKill: job.isLive ? () => _confirmKill(job) : null,
        onOpenOutput: widget.mux == null
            ? null
            : () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => JobOutputPage(
                      job: job,
                      mux: widget.mux!,
                      sessionId: widget.sessionId,
                      onKill: (id) => widget.onKill(id),
                    ),
                  ),
                );
              },
      ),
    );
  }

  Future<void> _confirmKill(JobSummary job) async {
    final (t, txt) = AppTheme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.bgCard,
        title: Text(AppStrings.of(context)('jobs.killConfirm'), style: txt.h3),
        content: Text(
          job.label,
          style: txt.body,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppStrings.of(context)('common.cancel'), style: TextStyle(color: t.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.of(context)('jobs.kill'), style: TextStyle(color: t.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final result = await widget.onKill(job.id);
      if (!mounted) return;
      final msg = result.requested
          ? AppStrings.of(context)('jobs.killRequested')
          : result.alreadyFinished
          ? AppStrings.of(context)('jobs.finished')
          : AppStrings.of(context)('jobs.actionSubmitted');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('终止失败：${_describeError(e)}')),
      );
    }
  }

  static String _describeError(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}

/// 任务详情底部面板。
class _JobDetailSheet extends StatelessWidget {
  const _JobDetailSheet({
    required this.job,
    this.onKill,
    this.onOpenOutput,
  });

  final JobSummary job;
  final Future<void> Function()? onKill;
  final VoidCallback? onOpenOutput;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final style = JobStatusStyle.of(job.status, t, AppStrings.of(context));

    return Container(
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.lg),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        Space.s7,
        Space.s6,
        Space.s7,
        Space.s8 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: t.borderSubtle,
                borderRadius: Radii.rFull,
              ),
            ),
          ),
          const SizedBox(height: Space.s6),
          Row(
            children: [
              ReasonChip(label: style.label, fg: style.fg, bg: style.bg),
              const SizedBox(width: Space.s3),
              Text(job.kind, style: txt.caption),
            ],
          ),
          const SizedBox(height: Space.s4),
          SelectableText(job.label, style: txt.body),
          const SizedBox(height: Space.s6),
          _kv(AppStrings.of(context)('jobs.jobId'), job.id, t, txt),
          _kv(AppStrings.of(context)('jobs.startedAt'), _fmtTime(job.startedAt), t, txt),
          if (job.finishedAt != null)
            _kv(AppStrings.of(context)('jobs.endedAt'), _fmtTime(job.finishedAt!), t, txt),
          _kv(AppStrings.of(context)('jobs.elapsed'), '${job.elapsed().inSeconds} 秒', t, txt),
          if (job.progress != null) _kv(AppStrings.of(context)('jobs.progress'), job.progress!, t, txt),
          if (job.detail != null) _kv(AppStrings.of(context)('jobs.detail'), job.detail!, t, txt),
          _kv(AppStrings.of(context)('jobs.output'), '${job.output.total} 字节', t, txt),
          if (job.output.spillPaths.isNotEmpty)
            _kv(AppStrings.of(context)('jobs.spillFile'), job.output.spillPaths.join('\n'), t, txt),
          if (onOpenOutput != null) ...[
            const SizedBox(height: Space.s8),
            SizedBox(
              width: double.infinity,
              height: Hit.primary,
              child: FilledButton(
                onPressed: onOpenOutput,
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: t.onAccent,
                ),
                child: Text(AppStrings.of(context)('jobs.viewOutput')),
              ),
            ),
          ],
          if (onKill != null) ...[
            const SizedBox(height: Space.s4),
            SizedBox(
              width: double.infinity,
              height: Hit.primary,
              child: FilledButton.tonal(
                onPressed: () {
                  Navigator.pop(context);
                  onKill!();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: t.dangerWeakBg,
                  foregroundColor: t.danger,
                ),
                child: Text(AppStrings.of(context)('jobs.killJob')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static Widget _kv(String k, String v, Tokens t, AppTextStyles txt) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(k, style: txt.caption),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: txt.caption.copyWith(color: t.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtTime(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
