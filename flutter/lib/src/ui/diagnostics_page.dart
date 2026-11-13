/// 连接诊断页。对齐 `docs/10-ui-spec.md` §5.7。
///
/// **分层顺序固定 7 层**，与 `CONNECTION_DIAGNOSTICS.md` 一致：
/// 版本 / 网卡与网关 / 防火墙 / 本机通道 / 系统 DNS / 电脑出口探测 / 手机路径。
///
/// **「手机路径」永远是 info**：即使电脑侧全绿也显示「未在手机上验证」，
/// 不得显示 ✓ —— 这是 spec 的硬要求，避免把「电脑能连」误读成「手机能连」。
///
/// **状态不靠颜色单独传达**：每种状态都配文字（✓/⚠/✕/ℹ + 说明）。
library;

import 'package:flutter/material.dart';

import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme;
import 'tokens.dart';

/// 检查状态。
enum CheckStatus {
  ok,
  warning,
  error,
  info;

  /// 多语言标签（枚举不能持有运行时值）。
  String label(AppStrings strings) => switch (this) {
    CheckStatus.ok => strings('diag.pass'),
    CheckStatus.warning => strings('diag.attention'),
    CheckStatus.error => strings('diag.fail'),
    CheckStatus.info => strings('diag.explain'),
  };
}

/// 一条检查项。
class DiagnosticCheck {
  const DiagnosticCheck({
    required this.label,
    required this.status,
    this.detail,
    this.actionLabel,
    this.onAction,
  });

  final String label;
  final CheckStatus status;
  final String? detail;

  /// 可选动作（如「处理」）。
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// 一层检查（固定 7 层之一）。
class DiagnosticLayer {
  const DiagnosticLayer({required this.title, required this.checks});

  final String title;
  final List<DiagnosticCheck> checks;
}

/// 整体结论。
enum DiagnosticOverall {
  ok,
  attention,
  error;

  /// 多语言标签。
  String label(AppStrings strings) => switch (this) {
    DiagnosticOverall.ok => strings('diag.allOk'),
    DiagnosticOverall.attention => strings('diag.needAction'),
    DiagnosticOverall.error => strings('diag.hasIssues'),
  };
}

/// 诊断报告。
class DiagnosticReport {
  const DiagnosticReport({
    required this.layers,
    required this.generatedAt,
  });

  final List<DiagnosticLayer> layers;
  final DateTime generatedAt;

  int countOf(CheckStatus s) => layers
      .expand((l) => l.checks)
      .where((c) => c.status == s)
      .length;

  DiagnosticOverall get overall {
    if (countOf(CheckStatus.error) > 0) return DiagnosticOverall.error;
    if (countOf(CheckStatus.warning) > 0) return DiagnosticOverall.attention;
    return DiagnosticOverall.ok;
  }

  /// 脱敏报告文本。
  ///
  /// **不含**任何 token / cookie / 完整地址 —— 只有层名、检查名、状态。
  String toPlainText([AppStrings? strings]) {
    final s = strings ?? AppStrings.forLanguage(AppLanguage.zh);
    final b = StringBuffer();
    b.writeln('# ${s('diag.reportTitle')}');
    b.writeln('# ${s.withArgs('diag.reportGenerated', {'at': generatedAt.toIso8601String()})}');
    b.writeln('# ${s.withArgs('diag.reportConclusion', {'name': overall.name})}');
    b.writeln();
    for (final l in layers) {
      b.writeln('## ${l.title}');
      for (final c in l.checks) {
        b.writeln('- [${c.status.name}] ${c.label}');
        if (c.detail != null) b.writeln('    ${c.detail}');
      }
      b.writeln();
    }
    b.writeln(s('diag.reportRedacted'));
    return b.toString();
  }
}

/// 连接诊断页。
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({
    super.key,
    required this.report,
    this.running = false,
    this.onRun,
    this.onCopyReport,
    this.advanced,
    this.title,
    this.onBack,
  });

  /// `null` 表示尚未运行。
  final DiagnosticReport? report;

  /// 运行中：主按钮 disabled + 文案「检查中…」。
  final bool running;

  final VoidCallback? onRun;
  final void Function(String text)? onCopyReport;

  /// 高级区（第三方 WebSocket 路径）。
  final Widget? advanced;

  /// 页面标题；为空时用当前语言的默认值。
  final String? title;

  /// 返回上一页；为空时不显示返回按钮。
  ///
  /// 诊断页是被设备页 push 上来的二级页，顶栏必须自带返回入口 ——
  /// 否则用户只能靠系统手势，而在 tab 页上返回手势的语义是「退出 App」。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.s7,
            Space.s6,
            Space.s7,
            Space.s12,
          ),
          children: [
            Row(
              children: [
                if (onBack != null)
                  IconButton(
                    onPressed: onBack,
                    icon: const Icon(Icons.chevron_left),
                    color: t.textSecondary,
                    tooltip: strings('common.back'),
                    constraints: const BoxConstraints(
                      minWidth: Hit.min,
                      minHeight: Hit.min,
                    ),
                  ),
                Expanded(
                  child: Text(
                    title ?? strings('diag.connectTitle'),
                    style: txt.h1,
                  ),
                ),
                // 有返回按钮时右侧补等宽占位，标题才会与下方内容左对齐
                if (onBack != null) const SizedBox(width: Hit.min),
              ],
            ),
            const SizedBox(height: Space.s6),
            if (report != null) ...[
              _SummaryBanner(report: report!, t: t, txt: txt),
              const SizedBox(height: Space.s4),
            ],
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: Hit.primary,
                    child: FilledButton(
                      onPressed: running ? null : onRun,
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: t.onAccent,
                        disabledBackgroundColor: t.disabledBg,
                        disabledForegroundColor: t.disabledText,
                      ),
                      child: Text(running ? strings('diag.checking') : strings('diag.start')),
                    ),
                  ),
                ),
                const SizedBox(width: Space.s4),
                SizedBox(
                  height: Hit.primary,
                  child: OutlinedButton(
                    // 只在有报告时启用
                    onPressed: report == null || onCopyReport == null
                        ? null
                        : () => onCopyReport!(report!.toPlainText()),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: t.textSecondary,
                      side: BorderSide(color: t.borderSubtle),
                    ),
                    child: Text(strings('diag.copy')),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.s7),

            if (report != null)
              for (final layer in report!.layers) ...[
                _groupHeader(layer.title, t, txt),
                for (final c in layer.checks) _CheckRow(check: c),
                const SizedBox(height: Space.s4),
              ],

            if (advanced != null) ...[
              const SizedBox(height: Space.s4),
              advanced!,
            ],
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(String title, Tokens t, AppTextStyles txt) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s2),
    child: Text(
      title,
      style: txt.chrome.copyWith(color: t.textSecondary),
    ),
  );
}

class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner({
    required this.report,
    required this.t,
    required this.txt,
  });

  final DiagnosticReport report;
  final Tokens t;
  final AppTextStyles txt;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (report.overall) {
      DiagnosticOverall.ok => (
        t.successWeakBg,
        t.success,
        Icons.check_circle_outline,
      ),
      DiagnosticOverall.attention => (
        t.warnWeakBg,
        t.warn,
        Icons.warning_amber_outlined,
      ),
      DiagnosticOverall.error => (
        t.dangerWeakBg,
        t.danger,
        Icons.error_outline,
      ),
    };

    final ok = report.countOf(CheckStatus.ok);
    final warn = report.countOf(CheckStatus.warning);
    final err = report.countOf(CheckStatus.error);
    final at = report.generatedAt;

    return Container(
      constraints: const BoxConstraints(minHeight: 88),
      padding: const EdgeInsets.all(Space.s6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: Radii.rLg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: Space.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  report.overall.label(AppStrings.of(context)),
                  style: txt.h3.copyWith(color: fg),
                ),
                const SizedBox(height: Space.s1),
                Text(
                  AppStrings.of(context).withArgs('diag.summary', {
                    'ok': ok,
                    'warn': warn,
                    'err': err,
                  }),
                  style: txt.caption.copyWith(color: t.textSecondary),
                ),
                const SizedBox(height: Space.s1),
                Text(
                  AppStrings.of(context).withArgs('diag.generatedAt', {
                    'at':
                        '${at.hour.toString().padLeft(2, '0')}:'
                        '${at.minute.toString().padLeft(2, '0')}',
                  }),
                  style: txt.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});

  final DiagnosticCheck check;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final (glyph, color) = switch (check.status) {
      CheckStatus.ok => ('✓', t.success),
      CheckStatus.warning => ('⚠', t.warn),
      CheckStatus.error => ('✕', t.danger),
      CheckStatus.info => ('ℹ', t.textTertiary),
    };

    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: Space.s3),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: t.borderSubtle, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态不靠颜色单独传达：符号 + 文字说明
          SizedBox(
            width: 20,
            child: Text(
              glyph,
              style: txt.body.copyWith(color: color),
            ),
          ),
          const SizedBox(width: Space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  check.label,
                  style: txt.body.copyWith(fontWeight: FontWeight.w500),
                ),
                if (check.detail != null) ...[
                  const SizedBox(height: Space.s1),
                  Text(
                    check.detail!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: txt.caption,
                  ),
                ],
              ],
            ),
          ),
          if (check.actionLabel != null)
            SizedBox(
              height: Hit.min,
              child: TextButton(
                onPressed: check.onAction,
                style: TextButton.styleFrom(foregroundColor: t.accent),
                child: Text(check.actionLabel!),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「手机路径」行的固定文案。
///
/// spec：**永远 info**，不得因电脑侧全绿就显示 ✓。
DiagnosticCheck phonePathCheck(AppStrings strings) => DiagnosticCheck(
  // 层标题已叫「手机路径」，检查项不再重复同名（否则 UI 上出现两次）
  label: strings('diag.needsDevice'),
  status: CheckStatus.info,
  detail: strings('diag.deviceOnly'),
);
