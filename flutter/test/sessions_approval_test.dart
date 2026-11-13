/// 会话页置顶的「待审批」区。
///
/// 审批比会话更急：不表态就卡住。所以锁定三件事：
/// 1. 有待审批时置顶渲染，且带「待审批 N」组头
/// 2. 点「允许 / 拒绝」回传对应决策
/// 3. 搜索/筛选把会话清空时，待审批仍然在（不能被藏起来）
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/protocol/approvals.dart';
import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/protocol/sessions.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/sessions_page.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

Widget _host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(
      home: AppLocaleScope(language: AppLanguage.zh, child: child),
    ),
  );
}

PendingApproval _approval({
  String eventId = 'evt-1',
  String toolName = 'bash',
}) => PendingApproval(
  sessionId: 's1',
  eventId: eventId,
  callId: 'call_debug_001',
  toolName: toolName,
  reason: 'escalate sandbox to danger-full-access: rm -rf /tmp/build',
  displayReason: const {'zh': '允许本次操作使用 danger-full-access 权限'},
);

Future<List<SessionSummary>> _sessions() async => [
  SessionSummary(
    id: 's1',
    title: '本地代码回退0.1.5版本',
    cwd: '/Users/x/proj',
    agentAvailable: true,
    updatedAt: DateTime.now(),
  ),
];

Future<WorkspaceSnapshot> _workspaces() async => WorkspaceSnapshot(
  items: const [
    Workspace(
      id: 'w1',
      path: '/Users/x/proj',
      title: 'proj',
      sessionIds: ['s1'],
    ),
  ],
  archivedSessionIds: const {},
  pinnedSessionIds: const {},
);

Widget _page({
  List<PendingApproval> approvals = const [],
  void Function(PendingApproval, ApprovalDecision)? onDecide,
}) => _host(
  SessionsPage(
    listSessions: _sessions,
    listWorkspaces: _workspaces,
    approvals: approvals,
    onDecideApproval: onDecide,
  ),
);

void main() {
  testWidgets('有待审批时置顶渲染组头与卡片', (tester) async {
    await tester.pumpWidget(_page(approvals: [_approval()]));
    await tester.pumpAndSettle();

    expect(find.text('待审批'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('bash 请求执行'), findsOneWidget);
    expect(find.text('等待审批'), findsOneWidget);
    // 原因原文必须在
    expect(find.textContaining('danger-full-access'), findsWidgets);

    // 置顶：待审批组头在第一个会话组头之上
    final approvalY = tester.getTopLeft(find.text('待审批')).dy;
    final groupY = tester.getTopLeft(find.text('proj')).dy;
    expect(approvalY, lessThan(groupY));
  });

  testWidgets('没有待审批时不渲染组头', (tester) async {
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('待审批'), findsNothing);
  });

  testWidgets('点允许回传 approve，点拒绝回传 deny', (tester) async {
    final decisions = <ApprovalDecision>[];
    await tester.pumpWidget(
      _page(
        approvals: [_approval()],
        onDecide: (_, d) => decisions.add(d),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('允许'));
    await tester.pump();
    await tester.tap(find.text('拒绝'));
    await tester.pump();

    expect(decisions, [ApprovalDecision.approve, ApprovalDecision.deny]);
  });

  testWidgets('搜索无命中时待审批仍在', (tester) async {
    await tester.pumpWidget(_page(approvals: [_approval()]));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'zzzz-no-match');
    await tester.pumpAndSettle();

    expect(find.text('bash 请求执行'), findsOneWidget);
    expect(find.text('待审批'), findsOneWidget);
  });

  testWidgets('未接 onDecideApproval 时按钮禁用', (tester) async {
    await tester.pumpWidget(_page(approvals: [_approval()]));
    await tester.pumpAndSettle();

    for (final label in ['允许', '拒绝']) {
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (w) => w is ButtonStyleButton,
          ),
        ).first,
      );
      expect(button.onPressed, isNull);
    }
  });

  testWidgets('允许按钮用警示色，和普通主按钮区分开', (tester) async {
    await tester.pumpWidget(
      _page(approvals: [_approval()], onDecide: (_, _) {}),
    );
    await tester.pumpAndSettle();

    final allow = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('允许'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ).first,
    );
    final t = Tokens.light;
    final bg = allow.style?.backgroundColor?.resolve({});
    expect(bg, t.danger, reason: '放行是危险动作，必须是警示色而不是墨色');
  });
}
