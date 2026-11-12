/// 「需要你」区 UI 测试。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/jobs.dart';
import 'package:dsh_mobile/src/protocol/questions.dart';
import 'package:dsh_mobile/src/transport/unary.dart';
import 'package:dsh_mobile/src/ui/job_center_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/question_widgets.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

PendingQuestion pending({
  String callId = 'call_abc',
  String question = 'Which color do you prefer?',
  String header = 'Color',
  List<String> options = const ['Red', 'Blue', 'Green'],
  bool multiSelect = false,
}) => PendingQuestion(
  sessionId: 's1',
  callId: callId,
  questions: [
    Question(
      id: 'q1',
      question: question,
      header: header,
      multiSelect: multiSelect,
      options: options.map((l) => QuestionOption(label: l)).toList(),
    ),
  ],
);

Widget host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

/// 假的 QuestionCenter：只实现 pending/answer，不碰网络。
///
/// `QuestionCenter` 是具体类（`unary` 是 final 字段），所以这里用子类
/// 覆写两个方法；`unary` 传一个永不调用的实例即可。
class FakeQuestionCenter extends QuestionCenter {
  FakeQuestionCenter({this.initial = const []})
    : super(unary: _NeverUnary());

  final List<PendingQuestion> initial;
  final List<List<QuestionAnswer>> answers = [];

  @override
  Future<List<PendingQuestion>> pending(String sessionId) async => initial;

  @override
  Future<bool> answer({
    required String sessionId,
    required String callId,
    required List<QuestionAnswer> answers,
  }) async {
    this.answers.add(answers);
    return false;
  }
}

/// 永不使用的 UnaryClient 替身。
class _NeverUnary extends UnaryClient {
  _NeverUnary()
    : super(
        origin: Uri.parse('http://127.0.0.1:1'),
        transport: _NeverTransport(),
        cookieHeader: 'x',
      );
}

class _NeverTransport implements HttpTransport {
  @override
  Future<({int statusCode, String body})> post(
    Uri uri,
    String body, {
    required Map<String, String> headers,
    Duration? timeout,
  }) =>
      throw StateError('should not be called');
}

void main() {
  testWidgets('渲染问题正文与选项', (tester) async {
    await tester.pumpWidget(
      host(PendingQuestionCard(pending: pending())),
    );

    expect(find.text('Which color do you prefer?'), findsOneWidget);
    expect(find.text('等待回答'), findsOneWidget);
    expect(find.text('Red'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Green'), findsOneWidget);
  });

  testWidgets('点击选项触发 onAnswer', (tester) async {
    String? picked;
    await tester.pumpWidget(
      host(
        PendingQuestionCard(
          pending: pending(),
          onAnswer: (q, label) => picked = label,
        ),
      ),
    );

    await tester.tap(find.text('Blue'));
    await tester.pump();
    expect(picked, 'Blue');
  });

  testWidgets('「稍后」触发 onDismiss', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      host(
        PendingQuestionCard(
          pending: pending(),
          onDismiss: () => dismissed = true,
        ),
      ),
    );

    await tester.tap(find.text('稍后'));
    await tester.pump();
    expect(dismissed, isTrue);
  });

  testWidgets('busy 时按钮禁用', (tester) async {
    String? picked;
    await tester.pumpWidget(
      host(
        PendingQuestionCard(
          pending: pending(),
          busy: true,
          onAnswer: (q, label) => picked = label,
        ),
      ),
    );

    await tester.tap(find.text('Blue'));
    await tester.pump();
    expect(picked, isNull, reason: 'busy 时不应触发回答');
  });

  testWidgets('多题时显示题数', (tester) async {
    final p = PendingQuestion(
      sessionId: 's1',
      callId: 'call_x',
      questions: [
        const Question(id: 'a', question: 'Q1', options: []),
        const Question(id: 'b', question: 'Q2', options: []),
      ],
    );
    await tester.pumpWidget(host(PendingQuestionCard(pending: p)));
    expect(find.text('等待回答 · 2 题'), findsOneWidget);
  });

  testWidgets('无选项时只显示稍后', (tester) async {
    final p = PendingQuestion(
      sessionId: 's1',
      callId: 'call_y',
      questions: [const Question(id: 'a', question: '纯文本问题', options: [])],
    );
    await tester.pumpWidget(
      host(PendingQuestionCard(pending: p, onDismiss: () {})),
    );
    expect(find.text('稍后'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('按钮命中区 ≥48', (tester) async {
    await tester.pumpWidget(
      host(PendingQuestionCard(pending: pending(), onAnswer: (_, _) {})),
    );
    final size = tester.getSize(find.widgetWithText(FilledButton, 'Red'));
    expect(size.height, greaterThanOrEqualTo(Hit.primary));
  });

  testWidgets('长问题最多两行', (tester) async {
    await tester.pumpWidget(
      host(
        PendingQuestionCard(
          pending: pending(
            question: '这是一个非常长的问题' * 8,
            header: '',
          ),
          onAnswer: (_, _) {},
        ),
      ),
    );
    final text = tester.widget<Text>(find.textContaining('这是一个非常长的问题'));
    expect(text.maxLines, 2);
  });

  testWidgets('任务中心集成：需要你区出现在进行中之前', (tester) async {
    final jobController = StreamController<List<JobSummary>>();
    addTearDown(jobController.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => jobController.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
          questionCenter: FakeQuestionCenter(initial: [pending()]),
        ),
      ),
    );

    jobController.add([
      JobSummary(
        id: 'bash-1',
        kind: 'bash',
        label: '跑着的任务',
        status: JobStatus.running,
        startedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        output: const JobOutput(total: 0, earliest: 0),
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('需要你'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);

    // 需要你 应在 进行中 之前
    final needsY = tester.getTopLeft(find.text('需要你')).dy;
    final liveY = tester.getTopLeft(find.text('进行中')).dy;
    expect(needsY, lessThan(liveY));
  });

  testWidgets('回答后卡片消失', (tester) async {
    final jobController = StreamController<List<JobSummary>>();
    addTearDown(jobController.close);
    final fake = FakeQuestionCenter(initial: [pending()]);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => jobController.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
          questionCenter: fake,
        ),
      ),
    );
    jobController.add(const []);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Which color do you prefer?'), findsOneWidget);

    await tester.tap(find.text('Blue'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Which color do you prefer?'), findsNothing);
    expect(fake.answers, hasLength(1));
    expect(fake.answers.first.first.selected, ['Blue']);
  });

  testWidgets('稍后隐藏但不提交', (tester) async {
    final jobController = StreamController<List<JobSummary>>();
    addTearDown(jobController.close);
    final fake = FakeQuestionCenter(initial: [pending()]);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => jobController.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
          questionCenter: fake,
        ),
      ),
    );
    jobController.add(const []);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('稍后'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Which color do you prefer?'), findsNothing);
    expect(fake.answers, isEmpty, reason: '「稍后」不应提交回答');
  });
}
