import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/protocol/sessions.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/sessions_page.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => AppTheme(
  tokens: Tokens.light,
  text: AppTextStyles(Tokens.light, 16),
  child: MaterialApp(
    home: AppLocaleScope(language: AppLanguage.zh, child: child),
  ),
);

void main() {
  testWidgets('FAB 存在且可点击', (tester) async {
    var called = 0;
    await tester.pumpWidget(
      host(
        SessionsPage(
          listSessions: () async => [
            SessionSummary(id: 's1', title: 'A', cwd: '/p', updatedAt: DateTime.now()),
          ],
          listWorkspaces: () async => const WorkspaceSnapshot.empty(),
          onCreate: () async {
            called += 1;
            return 'new-id';
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fab = find.byKey(const ValueKey('sessions.fab'));
    expect(fab, findsOneWidget, reason: 'FAB 应渲染');

    await tester.tap(fab);
    await tester.pumpAndSettle();
    expect(called, 1, reason: 'FAB 点击应触发 onCreate');
  });

  testWidgets('onCreate 为 null 时不渲染 FAB', (tester) async {
    await tester.pumpWidget(
      host(
        SessionsPage(
          listSessions: () async => const [],
          listWorkspaces: () async => const WorkspaceSnapshot.empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sessions.fab')), findsNothing);
  });
}
