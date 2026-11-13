/// 审批卡片 UI。
///
/// 对齐 `docs/10-ui-spec.md` §5.1.3 与新稿（2026-11-13）：
/// - 白卡 + 16 圆角 + 1px 描边，不用左侧色条（新稿用的是说明文字 + 芯片）
/// - 顶部 chips：`等待审批` / `提权`（沙箱升级时）
/// - 标题 `{tool} 请求执行`，w600
/// - 正文：本地化原因（必须展示原文，不能只写「允许/拒绝」）
/// - 等宽代码块：**仅当协议里真的带了命令文本时**才渲染
/// - 页脚：callId（等宽，弱化）
/// - 动作：两列等分胶囊按钮，拒绝在左（描边）/ 允许在右（墨色实心）
///
/// 安全要求（spec §6.5 / ADR-002）：
/// - **必须展示待执行操作的原文**，不能只写「允许/拒绝」
/// - 沙箱升级类审批额外加危险标记
/// - 不在 UI 上伪造「始终允许」——协议里没有这个语义，只有 `allowed-once`
library;

import 'package:flutter/material.dart';

import '../protocol/approvals.dart';
import '../app_strings.dart';
import 'cards.dart';
import 'job_widgets.dart' show AppTheme;
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
    final strings = AppStrings.of(context);
    final reason = approval.localizedReason(language);
    final dangerous = approval.isSandboxEscalation;
    final command = approval.command;

    return Semantics(
      container: true,
      label: strings.withArgs('approval.needsYou', {
        'tool': approval.toolName,
        'reason': reason,
      }),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: Space.s8),
        decoration: BoxDecoration(
          color: t.bgCard,
          borderRadius: Radii.rLg,
          border: Border.all(color: t.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.s5,
            Space.s5,
            Space.s5,
            Space.s5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Chip(
                    label: strings('approval.waiting'),
                    fg: t.textPrimary,
                    bg: t.bgSunken,
                  ),
                  if (dangerous) ...[
                    const SizedBox(width: Space.s2),
                    _Chip(
                      label: strings('approval.escalate'),
                      fg: t.textPrimary,
                      bg: t.bgSunken,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: Space.s4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  IconTile(
                    icon: dangerous
                        ? Icons.warning_amber_rounded
                        : Icons.help_outline,
                    size: 40,
                    iconSize: 20,
                  ),
                  const SizedBox(width: Space.s4),
                  Expanded(
                    child: Text(
                      _titleFor(approval, strings),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: cardTitleStyle(txt),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.s3),
              // ⚠ 必须展示原因原文：用户要看清自己在批准什么
              Text(
                reason,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: txt.body.copyWith(color: t.textSecondary),
              ),
              if (command != null && command.isNotEmpty) ...[
                const SizedBox(height: Space.s4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.s4,
                    vertical: Space.s3,
                  ),
                  decoration: BoxDecoration(
                    color: t.bgSunken,
                    borderRadius: Radii.rMd,
                  ),
                  child: Text(
                    command,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: txt.caption.copyWith(
                      color: t.textPrimary,
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Roboto Mono'],
                    ),
                  ),
                ),
              ],
              if (approval.callId.isNotEmpty) ...[
                const SizedBox(height: Space.s4),
                Row(
                  children: [
                    Icon(
                      Icons.layers_outlined,
                      size: 16,
                      color: t.textTertiary,
                    ),
                    const SizedBox(width: Space.s2),
                    Expanded(
                      child: Text(
                        approval.callId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: txt.chrome.copyWith(
                          color: t.textTertiary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: Space.s5),
              // 动作：拒绝在左（描边）/ 允许在右（警示色实心）
              //
              // 「允许」是放行动作，视觉上必须和普通主按钮区分开：
              // 用 danger 色是唯一能让用户在扫一眼时停下来的信号。
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: Hit.primary,
                      child: OutlinedButton(
                        onPressed: busy || onDecide == null
                            ? null
                            : () => onDecide!(ApprovalDecision.deny),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.textPrimary,
                          side: BorderSide(color: t.borderSubtle),
                          shape: const StadiumBorder(),
                        ),
                        child: Text(strings('approval.deny')),
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
                            : () => onDecide!(ApprovalDecision.approve),
                        style: FilledButton.styleFrom(
                          backgroundColor: t.danger,
                          foregroundColor: t.bgCard,
                          disabledBackgroundColor: t.disabledBg,
                          disabledForegroundColor: t.disabledText,
                          shape: const StadiumBorder(),
                        ),
                        child: Text(strings('approval.allow')),
                      ),
                    ),
                  ),
                ],
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
///
/// 列表页用它渲染「待审批」整块；单条卡片之间的间距由这里统一给，
/// 免得每个调用点各写一套。
class ApprovalsSection extends StatelessWidget {
  const ApprovalsSection({
    super.key,
    required this.approvals,
    this.onDecide,
    this.busyEventId,
    this.language = 'zh',
    this.showHeader = true,
  });

  final List<PendingApproval> approvals;
  final void Function(PendingApproval a, ApprovalDecision d)? onDecide;
  final String? busyEventId;
  final String language;

  /// 是否自带「待审批 N」组头。嵌在别的区块里时可以关掉。
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    if (approvals.isEmpty) return const SizedBox.shrink();
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.s8,
              Space.s8,
              Space.s8,
              Space.s4,
            ),
            child: Row(
              children: [
                Text(
                  strings('approval.pending'),
                  style: txt.h1,
                ),
                const SizedBox(width: Space.s3),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.s3,
                    vertical: Space.s1,
                  ),
                  decoration: BoxDecoration(
                    color: t.bgSunken,
                    borderRadius: Radii.rFull,
                  ),
                  child: Text(
                    '${approvals.length}',
                    style: txt.caption.copyWith(
                      color: t.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
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

/// 小号芯片（与任务卡片的 chip 同族，但这里是审批专用）。
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.fg, required this.bg});

  final String label;
  final Color fg;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    final (_, txt) = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s3,
        vertical: Space.s1,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: Radii.rFull),
      child: Text(label, style: txt.caption.copyWith(color: fg)),
    );
  }
}
