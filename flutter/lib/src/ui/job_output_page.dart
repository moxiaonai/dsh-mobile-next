/// 后台任务输出页：订阅 `job/follow` 并实时渲染。
///
/// ## 为什么单独一页而不是底部面板
///
/// 输出是**持续增长**的（命令可以跑几分钟），底部面板高度有限且手势冲突。
/// 独立页面可以全屏滚动、支持「跟随/暂停」、支持长文本选择。
///
/// ## 跟随语义
///
/// 与 `docs/10-ui-spec.md` §7 的活动条一致：
/// - 新内容到达时，若用户在底部附近 → 自动跟随
/// - 用户上滑超过阈值 → 暂停跟随，浮出「回到最新」
/// - 阈值用滞回（48px 暂停 / 8px 恢复），避免手指停留时抖动
///
/// ## 断线续读
///
/// `job/follow` 支持 `from` 参数（绝对字节偏移）。断线后带上次的
/// `subscription.cursor` 重开即可，不重复不跳。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol/job_output.dart';
import '../protocol/jobs.dart';
import '../transport/mux.dart';
import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme, ErrorState, JobStatusStyle, PulseDot, ReasonChip;
import 'tokens.dart';

/// 任务输出页。
class JobOutputPage extends StatefulWidget {
  const JobOutputPage({
    super.key,
    required this.job,
    required this.mux,
    this.sessionId,
    this.onKill,
    this.title,
  });

  final JobSummary job;
  final MuxClient mux;

  /// 会话 id（无主任务传 null）。
  final String? sessionId;

  final Future<JobKillResult> Function(String jobId)? onKill;

  /// 页面标题；为空时用当前语言的默认值。
  final String? title;

  @override
  State<JobOutputPage> createState() => _JobOutputPageState();
}

class _JobOutputPageState extends State<JobOutputPage> {
  /// 跟随阈值（spec §7.3）：距底 >48 暂停，≤8 恢复。
  static const double _pauseAt = 48;
  static const double _resumeAt = 8;

  final _scroll = ScrollController();
  final _acc = OutputAccumulator();
  final _buffer = StringBuffer();

  JobOutputSubscription? _sub;
  StreamSubscription<JobFollowFrame>? _frames;
  JobSummary? _live;
  Object? _error;
  bool _loading = true;
  bool _following = true;
  bool _lossy = false;

  /// 收到新内容但用户暂停跟随时，累计未读行数。
  int _unseen = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_connect());
  }

  Future<void> _connect() async {
    if (!widget.mux.isConnected) {
      setState(() {
        _error = StateError('mux is not connected');
        _loading = false;
      });
      return;
    }
    try {
      final sub = JobOutputReader(mux: widget.mux).open(
        jobId: widget.job.id,
        sessionId: widget.sessionId,
        // 断线重连时从上次游标继续
        from: _acc.text.isEmpty ? null : _sub?.cursor,
      );
      _sub = sub;
      _frames = sub.frames.listen(
        (frame) {
          if (!mounted) return;
          setState(() {
            switch (frame) {
              case JobFollowOpened(:final job):
                _live = job;
                _loading = false;
              case JobFollowOutput(:final chunks):
                for (final c in chunks) {
                  final gap = _acc.append(c);
                  if (gap) _lossy = true;
                }
                _buffer
                  ..clear()
                  ..write(_acc.text);
                if (_following) {
                  _scrollToBottomSoon();
                } else {
                  _unseen += chunks.length;
                }
              case JobFollowStatus(:final job):
                _live = job;
            }
          });
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() {
            _error = e;
            _loading = false;
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _loading = false);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final distance = pos.maxScrollExtent - pos.pixels;
    if (_following && distance > _pauseAt) {
      setState(() {
        _following = false;
        _unseen = 0;
      });
    } else if (!_following && distance <= _resumeAt) {
      setState(() {
        _following = true;
        _unseen = 0;
      });
    }
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _resumeFollow() {
    setState(() {
      _following = true;
      _unseen = 0;
    });
    _scrollToBottomSoon();
  }

  @override
  void dispose() {
    _frames?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final job = _live ?? widget.job;

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _header(context, t, txt, job),
            Expanded(child: _body(t, txt, job)),
          ],
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    Tokens t,
    AppTextStyles txt,
    JobSummary job,
  ) {
    final style = JobStatusStyle.of(job.status, t, AppStrings.of(context));
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: Space.s3),
      decoration: BoxDecoration(
        color: t.bgCard,
        border: Border(
          bottom: BorderSide(color: t.borderSubtle, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: Hit.min,
            height: Hit.min,
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.chevron_left, color: t.textSecondary),
              tooltip: AppStrings.of(context)('common.back'),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.title ?? AppStrings.of(context)('jobout.title'),
                  style: txt.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: Space.s1),
                Row(
                  children: [
                    if (style.isLive) ...[
                      PulseDot(color: style.dot),
                      const SizedBox(width: Space.s3),
                    ],
                    ReasonChip(label: style.label, fg: style.fg, bg: style.bg),
                    const SizedBox(width: Space.s3),
                    Flexible(
                      child: Text(
                        job.kind,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: txt.caption,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (job.isLive && widget.onKill != null)
            SizedBox(
              height: Hit.min,
              child: TextButton(
                onPressed: () => _confirmKill(context, job),
                style: TextButton.styleFrom(foregroundColor: t.danger),
                child: Text(AppStrings.of(context)('jobs.kill')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(Tokens t, AppTextStyles txt, JobSummary job) {
    if (_error != null) {
      return ErrorState(error: _error!, onRetry: _connect);
    }
    if (_loading && _buffer.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final text = _buffer.toString();
    if (text.isEmpty && job.isSettled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.s12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.notes, size: 32, color: t.textTertiary),
              const SizedBox(height: Space.s6),
              Text(AppStrings.of(context)('jobout.empty'), style: txt.h3),
              if (job.detail != null) ...[
                const SizedBox(height: Space.s3),
                Text(job.detail!, style: txt.caption),
              ],
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        // 输出区：等宽字体、可选文本、内部滚动
        SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(
            Space.s7,
            Space.s6,
            Space.s7,
            Space.s12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_lossy)
                Container(
                  margin: const EdgeInsets.only(bottom: Space.s4),
                  padding: const EdgeInsets.all(Space.s4),
                  decoration: BoxDecoration(
                    color: t.warnWeakBg,
                    borderRadius: Radii.rSm,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 14, color: t.warn),
                      const SizedBox(width: Space.s3),
                      Expanded(
                        child: Text(
                          AppStrings.of(context)('jobout.evicted'),
                          style: txt.caption.copyWith(color: t.warn),
                        ),
                      ),
                    ],
                  ),
                ),
              SelectableText(
                text,
                style: txt.caption.copyWith(
                  fontFamily: 'monospace',
                  color: t.textPrimary,
                  height: 1.45,
                ),
              ),
              if (job.isLive) ...[
                const SizedBox(height: Space.s4),
                Row(
                  children: [
                    PulseDot(color: t.accent),
                    const SizedBox(width: Space.s3),
                    Text(AppStrings.of(context)('jobout.running'), style: txt.caption),
                  ],
                ),
              ],
            ],
          ),
        ),
        // 「回到最新」浮标：暂停跟随时出现
        if (!_following)
          Positioned(
            right: Space.s7,
            bottom: Space.s7,
            child: Material(
              color: t.accent,
              borderRadius: Radii.rFull,
              elevation: 2,
              child: InkWell(
                onTap: _resumeFollow,
                borderRadius: Radii.rFull,
                child: Container(
                  height: Hit.min,
                  padding: const EdgeInsets.symmetric(horizontal: Space.s6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_downward,
                        size: 16,
                        color: t.onAccent,
                      ),
                      const SizedBox(width: Space.s3),
                      Text(
                        _unseen > 0 ? '回到最新 (+$_unseen)' : AppStrings.of(context)('jobout.toLatest'),
                        style: txt.chrome.copyWith(color: t.onAccent),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmKill(BuildContext outerContext, JobSummary job) async {
    final (t, txt) = AppTheme.of(context);
    final ok = await showDialog<bool>(
      context: outerContext,
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
    if (ok != true || widget.onKill == null) return;
    try {
      await widget.onKill!(job.id);
      // 用 State.context（配 mounted 检查），不用捕获的 outerContext
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppStrings.of(context)('jobs.killRequested'))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('终止失败：$e')));
    }
  }
}
