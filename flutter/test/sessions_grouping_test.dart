/// 会话页两种分组轴：按项目 / 按状态。
///
/// 任务页已并进会话列表（同一批会话按状态切一遍），所以这里锁住三件事：
/// 1. 默认按项目轴分组
/// 2. 切成状态轴后出现「需要你/进行中/空闲/历史」这类组头
/// 3. 「需要你」chip 只留下有未答提问的会话
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/app_strings.dart';
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

SessionSummary _sess(
  String id,
  String title, {
  bool running = false,
  List<PendingQuestionSummary> questions = const [],
}) => SessionSummary(
  id: id,
  title: title,
  cwd: '/Users/x/proj',
  running: running,
  agentAvailable: true,
  pendingQuestions: questions,
  updatedAt: DateTime.now(),
);

Future<WorkspaceSnapshot> _workspaces() async => WorkspaceSnapshot(
  items: const [
    Workspace(
      id: 'w1',
      path: '/Users/x/proj',
      title: 'proj',
      sessionIds: ['s1', 's2'],
    ),
  ],
  archivedSessionIds: const {},
  pinnedSessionIds: const {},
);

void main() {
  testWidgets('默认按项目分组，组头是工作区名', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionsPage(
          listSessions: () async => [_sess('s1', '甲'), _sess('s2', '乙')],
          listWorkspaces: _workspaces,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('proj'), findsOneWidget);
    expect(find.text('按状态'), findsOneWidget, reason: '胶囊显示的是「切过去之后」');
  });

  testWidgets('点胶囊切成状态轴，出现「进行中」组头', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionsPage(
          listSessions: () async => [
            _sess('s1', '甲', running: true),
            _sess('s2', '乙'),
          ],
          listWorkspaces: _workspaces,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('按状态'));
    await tester.pumpAndSettle();

    expect(find.text('进行中'), findsWidgets);
    expect(find.text('proj'), findsNothing, reason: '状态轴不再有项目组头');
    expect(find.text('按项目'), findsOneWidget);
  });

  testWidgets('「需要你」chip 只留下有未答提问的会话', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionsPage(
          listSessions: () async => [
            _sess(
              's1',
              '等我回答的',
              questions: [
                PendingQuestionSummary(
                  callId: 'q1',
                  question: '要不要发布？',
                ),
              ],
            ),
            _sess('s2', '不需要理会的'),
          ],
          listWorkspaces: _workspaces,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('需要你'));
    await tester.pumpAndSettle();

    expect(find.text('等我回答的'), findsOneWidget);
    expect(find.text('不需要理会的'), findsNothing);
  });

  testWidgets('铃铛只在传入 onOpenInbox 时出现，且带未读角标', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionsPage(
          listSessions: () async => [_sess('s1', '甲')],
          listWorkspaces: _workspaces,
          unreadNotices: 3,
          onOpenInbox: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
