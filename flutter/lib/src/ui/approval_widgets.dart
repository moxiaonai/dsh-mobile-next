/// 审批卡片 UI。
///
/// 对齐 `docs/10-ui-spec.md` §5.1.3 的 TaskCard（C13）：
/// - 左侧 3px 状态条，色 = `--c-danger`（审批比提问更危险）
/// - 标题 `--t-h3`，最多 2 行
/// - 原因 chip（danger 色）
/// - 动作行两列等分，按钮高 48
///
/// 安全要求（spec §6.5 / ADR-002）：
/// - **必须展示待执行操作的原文**，不能只写「允许/拒绝」
/// - 沙箱升级类审批额外加危险标记
/// - 不在 UI 上伪造「始终允许」——协议里没有这个语义
library;

import 'package:flutter/material.dart';

import '../protocol/approvals.dart';
import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme, ReasonChip;
import 'tokens.dart';

/// 审批卡片。
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.approval,
    this.onDecide,
    this.busy = false,
    this.language = 'zh',
  });

  final PendingApproval approval;

  /// 选择后回调。`busy` 时禁用。
  final void Function(ApprovalDecision decision)? onDecide;

  final bool busy;

  /// 原因展示语言（`zh` / `en` …）。
  final String language;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final reason = approval.localizedReason(language);
    final dangerous = approval.isSandboxEscalation;

    return Semantics(
      container: true,
      label: '需要你审批：${approval.toolName}，$reason',
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
              // 左侧状态条：审批用 danger 色，比提问更醒目
              SizedBox(width: 3, child: ColoredBox(color: t.danger)),
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
                      Row(
                        children: [
                          ReasonChip(
                            label: AppStrings.of(context)('approval.waiting'),
                            fg: t.danger,
                            bg: t.dangerWeakBg,
                          ),
                          if (dangerous) ...[
                            const SizedBox(width: Space.s3),
                            ReasonChip(
                              label: AppStrings.of(context)('approval.escalate'),
                              fg: t.danger,
                              bg: t.dangerWeakBg,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: Space.s4),
                      // 标题：工具名
                      Text(
                        _titleFor(approval, AppStrings.of(context)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: txt.h3,
                      ),
                      const SizedBox(height: Space.s3),
                      // ⚠ 必须展示原因原文：用户要看清自己在批准什么
                      Text(
                        reason,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: txt.caption.copyWith(color: t.textSecondary),
                      ),
                      if (approval.callId.isNotEmpty) ...[
                        const SizedBox(height: Space.s3),
                        Text(
                          approval.callId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: txt.caption.copyWith(
                            color: t.textTertiary,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: Space.s6),
                      // 动作：拒绝 / 允许（拒绝在左，允许在右）
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: Hit.primary,
                              child: OutlinedButton(
                                onPressed: busy || onDecide == null
                                    ? null
                                    : () => onDecide!(
                                        ApprovalDecision.deny,
                                      ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: t.danger,
                                  side: BorderSide(color: t.borderSubtle),
                                ),
                                child: Text(AppStrings.of(context)('approval.deny')),
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.s4),
                          Expanded(
                            child: SizedBox(
                              height: Hit.primary,
                              child: FilledButton(
                                onPressed: busy || onDecide == null
                                    ? null
                                    : () => onDecide!(
                                        ApprovalDecision.approve,
                                      ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: t.accent,
                                  foregroundColor: t.onAccent,
                                  disabledBackgroundColor: t.disabledBg,
                                  disabledForegroundColor: t.disabledText,
                                ),
                                child: Text(AppStrings.of(context)('approval.allow')),
                              ),
                            ),
                          ),
                        ],
                      ),
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

  static String _titleFor(PendingApproval a, AppStrings strings) {
    if (a.toolName.isEmpty || a.toolName == 'unknown') {
      return strings('approval.confirm');
    }
    return strings.withArgs('approval.request', {'tool': a.toolName});
  }
}

/// 审批区。
class ApprovalsSection extends StatelessWidget {
  const ApprovalsSection({
    super.key,
    required this.approvals,
    this.onDecide,
    this.busyEventId,
    this.language = 'zh',
  });

  final List<PendingApproval> approvals;
  final void Function(PendingApproval a, ApprovalDecision d)? onDecide;
  final String? busyEventId;
  final String language;

  @override
  Widget build(BuildContext context) {
    if (approvals.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < approvals.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.s4),
          ApprovalCard(
            approval: approvals[i],
            busy: busyEventId == approvals[i].eventId,
            language: language,
            onDecide: onDecide == null
                ? null
                : (d) => onDecide!(approvals[i], d),
          ),
        ],
      ],
    );
  }
}
