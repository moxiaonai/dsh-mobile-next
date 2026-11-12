/// 审批卡片 UI 测试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/approvals.dart';
import 'package:dsh_mobile/src/ui/approval_widgets.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/tokens.dart';

PendingApproval approval({
  String eventId = 'evt-1',
  String toolName = 'bash',
  String reason = 'escalate sandbox to danger-full-access: writes to /etc',
  Map<String, String> display = const {'zh': '允许本次操作使用 danger-full-access 权限'},
}) => PendingApproval(
  sessionId: 's1',
  eventId: eventId,
  callId: 'call_abc',
  toolName: toolName,
  reason: reason,
  displayReason: display,
);

Widget host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets('渲染工具名与原因原文', (tester) async {
    await tester.pumpWidget(
      host(ApprovalCard(approval: approval())),
    );

    expect(find.text('bash 请求执行'), findsOneWidget);
    expect(find.text('等待审批'), findsOneWidget);
    // 关键：必须展示原因原文，不能只写「允许/拒绝」
    expect(find.textContaining('danger-full-access'), findsOneWidget);
  });

  testWidgets('沙箱升级显示提权标记', (tester) async {
    await tester.pumpWidget(
      host(ApprovalCard(approval: approval())),
    );
    expect(find.text('提权'), findsOneWidget);
  });

  testWidgets('非沙箱升级不显示提权标记', (tester) async {
    await tester.pumpWidget(
      host(
        ApprovalCard(
          approval: approval(reason: 'wants to read a file'),
        ),
      ),
    );
    expect(find.text('提权'), findsNothing);
  });

  testWidgets('点击允许回调 approve', (tester) async {
    ApprovalDecision? got;
    await tester.pumpWidget(
      host(
        ApprovalCard(
          approval: approval(),
          onDecide: (d) => got = d,
        ),
      ),
    );
    await tester.tap(find.text('允许'));
    await tester.pump();
    expect(got, ApprovalDecision.approve);
  });

  testWidgets('点击拒绝回调 deny', (tester) async {
    ApprovalDecision? got;
    await tester.pumpWidget(
      host(
        ApprovalCard(
          approval: approval(),
          onDecide: (d) => got = d,
        ),
      ),
    );
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(got, ApprovalDecision.deny);
  });

  testWidgets('busy 时两个按钮都禁用', (tester) async {
    var called = false;
    await tester.pumpWidget(
      host(
        ApprovalCard(
          approval: approval(),
          busy: true,
          onDecide: (_) => called = true,
        ),
      ),
    );
    await tester.tap(find.text('允许'));
    await tester.pump();
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(called, isFalse);
  });

  testWidgets('按钮命中区 ≥48', (tester) async {
    await tester.pumpWidget(
      host(ApprovalCard(approval: approval(), onDecide: (_) {})),
    );
    for (final label in ['允许', '拒绝']) {
      final size = tester.getSize(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(size.height, greaterThanOrEqualTo(Hit.primary));
    }
  });

  testWidgets('语言回退：无 zh 时用 en', (tester) async {
    await tester.pumpWidget(
      host(
        ApprovalCard(
          approval: approval(display: const {'en': 'English reason'}),
        ),
      ),
    );
    expect(find.textContaining('English reason'), findsOneWidget);
  });

  testWidgets('无 displayReason 时用原文', (tester) async {
    await tester.pumpWidget(
      host(
        ApprovalCard(
          approval: approval(reason: 'raw reason text', display: const {}),
        ),
      ),
    );
    expect(find.textContaining('raw reason text'), findsOneWidget);
  });

  testWidgets('多审批堆叠', (tester) async {
    await tester.pumpWidget(
      host(
        ApprovalsSection(
          approvals: [
            approval(eventId: 'e1', toolName: 'bash'),
            approval(eventId: 'e2', toolName: 'write'),
          ],
          onDecide: (_, _) {},
        ),
      ),
    );
    expect(find.text('bash 请求执行'), findsOneWidget);
    expect(find.text('write 请求执行'), findsOneWidget);
  });

  testWidgets('空列表不渲染', (tester) async {
    await tester.pumpWidget(
      host(const ApprovalsSection(approvals: [])),
    );
    expect(find.byType(ApprovalCard), findsNothing);
  });
}
