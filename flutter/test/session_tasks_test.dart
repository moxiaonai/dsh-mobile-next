/// 会话任务列表测试。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/protocol/session_tasks.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/session_tasks_page.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

SessionSummary sess(
  String id, {
  String? title,
  bool running = false,
  bool agent = false,
  bool blank = false,
  int qCount = 0,
  String qText = '',
  DateTime? at,
}) => SessionSummary(
  id: id,
  title: title,
  running: running,
  agentAvailable: agent,
  blank: blank,
  cwd: '/Users/x/proj',
  updatedAt: at ?? DateTime.now(),
  pendingQuestions: List.generate(
    qCount,
    (i) => PendingQuestionSummary(
      callId: 'call_$i',
      question: qText.isEmpty ? '问题 $i' : qText,
    ),
  ),
);

Widget host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(home: child),
  );
}

void main() {
  group('SessionTasks.build', () {
    test('有提问 → needsAnswer（优先级最高）', () {
      final t = SessionTasks.build([
        sess('a', title: 'A', running: true),
        sess('b', title: 'B', qCount: 1, qText: '要部署到哪？'),
      ]);
      expect(t.first.id, 'b');
      expect(t.first.kind, SessionTaskKind.needsAnswer);
      expect(t.first.needsYou, isTrue);
      expect(t.first.pendingQuestionSummary, '要部署到哪？');
    });

    test('运行中 → running', () {
      final t = SessionTasks.build([sess('a', running: true, agent: true)]);
      expect(t.single.kind, SessionTaskKind.running);
    });

    test('有 Agent 但没跑 → idle', () {
      final t = SessionTasks.build([sess('a', agent: true)]);
      expect(t.single.kind, SessionTaskKind.idle);
    });

    test('无 Agent → dormant', () {
      final t = SessionTasks.build([sess('a')]);
      expect(t.single.kind, SessionTaskKind.dormant);
    });

    test('跳过空白会话', () {
      final t = SessionTasks.build([
        sess('a', blank: true),
        sess('b', title: 'B'),
      ]);
      expect(t, hasLength(1));
      expect(t.single.id, 'b');
    });

    test('排序：需要你 > 运行中 > 空闲 > 历史', () {
      final t = SessionTasks.build([
        sess('d'),
        sess('c', agent: true),
        sess('b', running: true),
        sess('a', qCount: 1),
      ]);
      expect(t.map((e) => e.id).toList(), ['a', 'b', 'c', 'd']);
    });

    test('同类按最近活动倒序', () {
      final now = DateTime.now();
      final t = SessionTasks.build([
        sess('old', running: true, at: now.subtract(const Duration(hours: 5))),
        sess('new', running: true, at: now),
      ]);
      expect(t.map((e) => e.id).toList(), ['new', 'old']);
    });
  });

  group('SessionTasks.group', () {
    test('分三组', () {
      final tasks = SessionTasks.build([
        sess('q', qCount: 1),
        sess('r', running: true),
        sess('i', agent: true),
      ]);
      final g = SessionTasks.group(tasks);
      expect(g.needsYou.map((e) => e.id), ['q']);
      expect(g.active.map((e) => e.id), ['r']);
      expect(g.rest.map((e) => e.id), ['i']);
    });
  });

  group('SessionTasksPage', () {
    testWidgets('渲染三个分区', (tester) async {
      await tester.pumpWidget(
        host(
          SessionTasksPage(
            listSessions: () async => [
              sess('q', title: '部署任务', qCount: 1, qText: '要部署到哪？'),
              sess('r', title: '重构支付', running: true),
              sess('i', title: '旧会话', agent: true),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('需要你'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);
      expect(find.text('其他'), findsOneWidget);
      expect(find.text('部署任务'), findsOneWidget);
      // 需要你时展示问题正文
      expect(find.text('要部署到哪？'), findsOneWidget);
    });

    testWidgets('空状态', (tester) async {
      await tester.pumpWidget(
        host(SessionTasksPage(listSessions: () async => const [])),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('还没有任务'), findsOneWidget);
    });

    testWidgets('错误态有重试', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          SessionTasksPage(
            listSessions: () async {
              calls++;
              throw const SocketException('Connection refused');
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('连不上电脑'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(calls, 1);
    });

    testWidgets('点击卡片触发 onOpen', (tester) async {
      SessionSummary? opened;
      await tester.pumpWidget(
        host(
          SessionTasksPage(
            listSessions: () async => [sess('a', title: '可点任务', running: true)],
            onOpen: (s) => opened = s,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('可点任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(opened?.id, 'a');
    });

    testWidgets('卡片命中区 ≥44', (tester) async {
      await tester.pumpWidget(
        host(
          SessionTasksPage(
            listSessions: () async => [sess('a', title: 'X', running: true)],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final size = tester.getSize(find.byType(SessionTaskCard).first);
      expect(size.height, greaterThanOrEqualTo(Hit.min));
    });

    testWidgets('不伪造待审批数', (tester) async {
      // 投影里没有审批信息，界面不应显示审批相关字样
      await tester.pumpWidget(
        host(
          SessionTasksPage(
            listSessions: () async => [sess('a', title: 'X', running: true)],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('审批'), findsNothing);
    });
  });
}
