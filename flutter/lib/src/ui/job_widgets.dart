/// 任务中心 UI 组件。
///
/// 逐条对齐 `docs/10-ui-spec.md` §5.1（任务 Home）与 §4（组件清单）：
/// - `TaskRow`（C14）—— 进行中 / 已完成的任务行，min-height 72
/// - `ProgressBar`（C19）—— 3px 高，**不假装知道百分比**
/// - `ReasonChip` —— 状态标签
/// - `SectionHeader` —— 分区标题 + 计数药丸
/// - `PulseDot` —— 进行中的"活着"信号（1200ms 周期，尊重 reduced-motion）
///
/// 禁用项（spec §12.5）已遵守：无渐变、无发光、无玻璃、无粒子、
/// 无 shimmer/skeleton 扫光、控件内无 emoji 图标。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol/jobs.dart';
import '../app_strings.dart';
import 'friendly_error.dart';
import 'tokens.dart';

/// 主题注入：把 [Tokens] 与 [AppTextStyles] 传到子树。
class AppTheme extends InheritedWidget {
  const AppTheme({
    super.key,
    required this.tokens,
    required this.text,
    required super.child,
  });

  final Tokens tokens;
  final AppTextStyles text;

  static (Tokens, AppTextStyles) of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<AppTheme>();
    assert(t != null, 'AppTheme 未注入');
    return (t!.tokens, t.text);
  }

  @override
  bool updateShouldNotify(AppTheme old) =>
      tokens != old.tokens || text.fontBase != old.text.fontBase;
}

/// 分区标题 + 计数药丸（spec §5.1.2）。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.count,
    this.trailing,
    this.trailingOnTap,
  });

  final String title;
  final int? count;
  final String? trailing;
  final VoidCallback? trailingOnTap;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s4),
      child: Row(
        children: [
          Text(title, style: txt.h2),
          if (count != null && count! > 0) ...[
            const SizedBox(width: Space.s3),
            Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: Space.s3),
              decoration: BoxDecoration(
                color: t.bgSunken,
                borderRadius: Radii.rFull,
              ),
              alignment: Alignment.center,
              child: Text(
                '$count',
                style: txt.chrome.copyWith(color: t.textSecondary),
              ),
            ),
          ],
          const Spacer(),
          if (trailing != null)
            // 文字动作也要满足 44 命中区：用 InkWell + 最小尺寸包裹。
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Hit.min),
              child: TextButton(
                onPressed: trailingOnTap,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, Hit.min),
                  padding: const EdgeInsets.symmetric(horizontal: Space.s4),
                  foregroundColor: t.accent,
                  textStyle: txt.caption.copyWith(color: t.accent),
                ),
                child: Text(trailing!),
              ),
            ),
        ],
      ),
    );
  }
}

/// 进行中的脉冲点（spec：`--m-pulse: 1200ms`）。
///
/// `prefers-reduced-motion` 下不播放动画 —— Flutter 对应
/// `MediaQuery.disableAnimations`。
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: Motion.pulse);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 尊重「减少动态效果」：禁用动画时不启动脉冲。
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // 透明度在 1.0 ↔ 0.45 之间呼吸，不做缩放（避免布局抖动）。
        final o = 1.0 - 0.55 * Curves.easeInOut.transform(_c.value);
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: o),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

/// 状态标签（ReasonChip）。高 24，`--r-sm`。
class ReasonChip extends StatelessWidget {
  const ReasonChip({
    super.key,
    required this.label,
    required this.fg,
    required this.bg,
  });

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    final (_, txt) = AppTheme.of(context);
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: Space.s3),
      decoration: BoxDecoration(color: bg, borderRadius: Radii.rSm),
      alignment: Alignment.center,
      child: Text(
        label,
        style: txt.chrome.copyWith(color: fg, fontSize: txt.fontBase * 0.75),
      ),
    );
  }
}

/// 进度条（C19）。
///
/// **不假装知道百分比**：`job/list` 不提供 step 总数，因此填充固定 40%，
/// 并用 `aria-valuetext` 等价物（`Semantics.value`）说明真实状态。
/// 这是 spec 明确要求的降级口径（A10）。
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, this.fraction = 0.4, this.label});

  final double fraction;

  /// 无障碍朗读文本，例如「进行中，已 3 步」。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final (t, _) = AppTheme.of(context);
    return Semantics(
      label: label,
      value: label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 3,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: t.bgSunken)),
              FractionallySizedBox(
                widthFactor: fraction.clamp(0.0, 1.0),
                child: ColoredBox(color: t.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 任务状态 → 展示映射。
///
/// 集中在一处，避免每个组件各自决定颜色/文案。
class JobStatusStyle {
  const JobStatusStyle({
    required this.label,
    required this.fg,
    required this.bg,
    required this.dot,
    required this.isLive,
  });

  final String label;
  final Color fg;
  final Color bg;
  final Color dot;
  final bool isLive;

  static JobStatusStyle of(JobStatus status, Tokens t, AppStrings strings) => switch (status) {
    JobStatus.running => JobStatusStyle(
      label: strings('job.state.running'),
      fg: t.accentWeakText,
      bg: t.accentWeakBg,
      dot: t.accent,
      isLive: true,
    ),
    JobStatus.stopping => JobStatusStyle(
      label: strings('job.state.stopping'),
      fg: t.warn,
      bg: t.warnWeakBg,
      dot: t.warnDot,
      isLive: true,
    ),
    JobStatus.completed => JobStatusStyle(
      label: strings('job.state.done'),
      fg: t.success,
      bg: t.successWeakBg,
      dot: t.successDot,
      isLive: false,
    ),
    JobStatus.failed => JobStatusStyle(
      label: strings('job.state.failed'),
      fg: t.danger,
      bg: t.dangerWeakBg,
      dot: t.danger,
      isLive: false,
    ),
    JobStatus.killed => JobStatusStyle(
      label: strings('job.state.killed'),
      fg: t.textSecondary,
      bg: t.bgSunken,
      dot: t.textTertiary,
      isLive: false,
    ),
    JobStatus.unknown => JobStatusStyle(
      label: strings('job.state.unknown'),
      fg: t.textSecondary,
      bg: t.bgSunken,
      dot: t.textTertiary,
      isLive: false,
    ),
  };
}

/// 任务行（C14）。min-height 72。
class TaskRow extends StatelessWidget {
  const TaskRow({
    super.key,
    required this.job,
    this.onTap,
    this.now,
  });

  final JobSummary job;
  final VoidCallback? onTap;

  /// 注入当前时间，便于测试与避免每行各自取时钟。
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final style = JobStatusStyle.of(job.status, t, AppStrings.of(context));
    final elapsed = _formatElapsed(job.elapsed(now));

    return Semantics(
      button: onTap != null,
      label: '${job.label}，${style.label}',
      child: Material(
        color: t.bgCard,
        borderRadius: Radii.rLg,
        child: InkWell(
          onTap: onTap,
          borderRadius: Radii.rLg,
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.fromLTRB(
              Space.s7,
              Space.s6,
              Space.s7,
              Space.s5,
            ),
            decoration: BoxDecoration(
              borderRadius: Radii.rLg,
              border: Border.all(color: t.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：标题 + 计时
                Row(
                  children: [
                    if (style.isLive) ...[
                      PulseDot(color: style.dot),
                      const SizedBox(width: Space.s3),
                    ],
                    Expanded(
                      child: Text(
                        job.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: txt.body.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(width: Space.s4),
                    Text(elapsed, style: txt.captionTabular),
                  ],
                ),
                const SizedBox(height: Space.s2),
                // 第二行：类型 + 状态
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        job.kind,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: txt.caption,
                      ),
                    ),
                    const SizedBox(width: Space.s3),
                    Text('·', style: txt.caption),
                    const SizedBox(width: Space.s3),
                    ReasonChip(label: style.label, fg: style.fg, bg: style.bg),
                    if (job.progress != null && job.progress!.isNotEmpty) ...[
                      const SizedBox(width: Space.s3),
                      Flexible(
                        child: Text(
                          job.progress!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: txt.captionTabular,
                        ),
                      ),
                    ],
                  ],
                ),
                // 第三行：进度条（仅运行中）
                if (style.isLive) ...[
                  const SizedBox(height: Space.s4),
                  ProgressBar(
                    label: '进行中${job.progress == null ? '' : '，${job.progress}'}',
                  ),
                ],
                if (job.detail != null && job.detail!.isNotEmpty) ...[
                  const SizedBox(height: Space.s3),
                  Text(
                    job.detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: txt.caption.copyWith(
                      color: job.status == JobStatus.failed
                          ? t.danger
                          : t.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 时长格式：`4:12`（分:秒），超过 1 小时用 `1:04:12`。
  static String _formatElapsed(Duration d) {
    final total = math.max(0, d.inSeconds);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }
}

/// 任务列表的空状态。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.body,
    this.icon,
  });

  final String title;
  final String? body;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.s12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 32, color: t.textTertiary),
              const SizedBox(height: Space.s6),
            ],
            Text(title, style: txt.h3, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: Space.s3),
              Text(body!, style: txt.caption, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}

/// 带重试的错误状态。
///
/// 与 [EmptyState] 的区别：这个专门用于**可恢复的失败**，
/// 因此必须给重试入口，且不展示原始异常（除非用户主动展开）。
class ErrorState extends StatefulWidget {
  const ErrorState({
    super.key,
    required this.error,
    this.onRetry,
    this.retryLabel,
  });

  final Object error;
  final VoidCallback? onRetry;
  /// 重试按钮文案；为空时用当前语言的默认值。
  final String? retryLabel;

  @override
  State<ErrorState> createState() => _ErrorStateState();
}

class _ErrorStateState extends State<ErrorState> {
  bool _showDetail = false;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final friendly = FriendlyError.from(widget.error, AppStrings.of(context));
    final hasDetail = friendly.detail.isNotEmpty;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.s12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 32, color: t.textTertiary),
            const SizedBox(height: Space.s6),
            Text(
              friendly.title,
              style: txt.h3,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.s3),
            Text(
              friendly.hint,
              style: txt.caption,
              textAlign: TextAlign.center,
            ),
            if (friendly.retryable && widget.onRetry != null) ...[
              const SizedBox(height: Space.s7),
              SizedBox(
                height: Hit.primary,
                child: FilledButton(
                  onPressed: widget.onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: t.onAccent,
                  ),
                  child: Text(widget.retryLabel ?? AppStrings.of(context)('common.retry')),
                ),
              ),
            ],
            if (hasDetail) ...[
              const SizedBox(height: Space.s4),
              TextButton(
                onPressed: () => setState(() => _showDetail = !_showDetail),
                style: TextButton.styleFrom(
                  foregroundColor: t.textTertiary,
                  minimumSize: const Size(0, Hit.min),
                ),
                child: Text(_showDetail
                    ? AppStrings.of(context)('job.hideDetail')
                    : AppStrings.of(context)('job.showDetail')),
              ),
              if (_showDetail)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Space.s5),
                  decoration: BoxDecoration(
                    color: t.bgSunken,
                    borderRadius: Radii.rMd,
                  ),
                  child: SelectableText(
                    friendly.detail,
                    style: txt.caption.copyWith(
                      fontFamily: 'monospace',
                      color: t.textSecondary,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
