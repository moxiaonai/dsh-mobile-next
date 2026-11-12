/// 「需要你」区 UI。
///
/// 对齐 `docs/10-ui-spec.md` §5.1.3 的 TaskCard（C13）与 §6 的待处理 dock：
/// - 卡片左侧 3px 状态条，色 = 原因色（warn）
/// - 标题 `--t-h3`，最多 2 行
/// - 原因 chip 高 24
/// - 动作行两列等分，按钮高 48
///
/// 数据来自 [QuestionCenter]（`session/events` 的 `tool/call` 事件），
/// **不是**投影 —— 投影的 `userQuestions.active` 实测为空。
library;

import 'package:flutter/material.dart';

import '../protocol/questions.dart';
import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme, ReasonChip;
import 'tokens.dart';

/// 待答卡片。
class PendingQuestionCard extends StatelessWidget {
  const PendingQuestionCard({
    super.key,
    required this.pending,
    this.onAnswer,
    this.onDismiss,
    this.busy = false,
  });

  final PendingQuestion pending;

  /// 选择某个选项后回调。
  final void Function(Question question, String label)? onAnswer;

  /// 「稍后」。
  final VoidCallback? onDismiss;

  /// 提交中：禁用按钮并显示指示器。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final q = pending.questions.isEmpty ? null : pending.questions.first;

    return Semantics(
      container: true,
      label: '需要你的回答：${pending.summary}',
      child: Container(
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: Radii.rLg,
          border: Border.all(color: t.borderSubtle),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F0F172A),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左侧状态条：3px，warn 色（spec §5.1.3）
              SizedBox(width: 3, child: ColoredBox(color: t.warnDot)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.s7,
                    Space.s6,
                    Space.s7,
                    Space.s6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ReasonChip(
                        label: _reasonLabel(pending, AppStrings.of(context)),
                        fg: t.warn,
                        bg: t.warnWeakBg,
                      ),
                      const SizedBox(height: Space.s4),
                      // 标题最多 2 行
                      Text(
                        pending.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: txt.h3,
                      ),
                      if (q != null && q.detail != null) ...[
                        const SizedBox(height: Space.s3),
                        Text(
                          q.detail!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: txt.caption,
                        ),
                      ],
                      const SizedBox(height: Space.s6),
                      _actions(context, t, txt, q),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 动作区。
  ///
  /// 有选项时：每个选项一个按钮（纵向堆叠，最多 3 个），保证命中区。
  /// 无选项时：只有「稍后」。
  Widget _actions(
    BuildContext context,
    Tokens t,
    AppTextStyles txt,
    Question? q,
  ) {
    final options = q?.options ?? const <QuestionOption>[];

    if (options.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: SizedBox(
              height: Hit.primary,
              child: OutlinedButton(
                onPressed: busy ? null : onDismiss,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.textSecondary,
                  side: BorderSide(color: t.borderSubtle),
                ),
                child: Text(AppStrings.of(context)('question.later')),
              ),
            ),
          ),
        ],
      );
    }

    // 选项 ≤3 时纵向堆叠（避免两列挤压长标签）
    return Column(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.s4),
          SizedBox(
            width: double.infinity,
            height: Hit.primary,
            child: FilledButton(
              onPressed: busy || onAnswer == null
                  ? null
                  : () => onAnswer!(q!, options[i].label),
              style: FilledButton.styleFrom(
                backgroundColor: i == 0 ? t.accent : t.accentWeakBg,
                foregroundColor: i == 0 ? t.onAccent : t.accentWeakText,
                disabledBackgroundColor: t.disabledBg,
                disabledForegroundColor: t.disabledText,
              ),
              child: Text(options[i].label, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
        if (onDismiss != null) ...[
          const SizedBox(height: Space.s3),
          SizedBox(
            width: double.infinity,
            height: Hit.min,
            child: TextButton(
              onPressed: busy ? null : onDismiss,
              style: TextButton.styleFrom(foregroundColor: t.textSecondary),
              child: Text(AppStrings.of(context)('question.later')),
            ),
          ),
        ],
      ],
    );
  }

  static String _reasonLabel(PendingQuestion p, AppStrings strings) {
    if (p.questions.length > 1) {
      return strings.withArgs('question.waitingCount', {'n': p.questions.length});
    }
    return strings('question.waiting');
  }
}

/// 「需要你」区。
class NeedsYouSection extends StatelessWidget {
  const NeedsYouSection({
    super.key,
    required this.pending,
    this.onAnswer,
    this.onDismiss,
    this.busyCallId,
  });

  final List<PendingQuestion> pending;
  final void Function(PendingQuestion p, Question q, String label)? onAnswer;
  final void Function(PendingQuestion p)? onDismiss;

  /// 正在提交的 callId（该卡片显示 busy）。
  final String? busyCallId;

  @override
  Widget build(BuildContext context) {
    if (pending.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < pending.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.s4),
          PendingQuestionCard(
            pending: pending[i],
            busy: busyCallId == pending[i].callId,
            onAnswer: onAnswer == null
                ? null
                : (q, label) => onAnswer!(pending[i], q, label),
            onDismiss: onDismiss == null ? null : () => onDismiss!(pending[i]),
          ),
        ],
      ],
    );
  }
}
