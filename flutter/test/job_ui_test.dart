/// 任务中心 UI 的 widget 测试。
///
/// 不依赖网络：用假数据流驱动 [JobCenterPage]，验证分区、状态、终止流程。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/jobs.dart';
import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/ui/job_center_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

JobSummary job({
  required String id,
  required JobStatus status,
  String label = 'test job',
  String kind = 'bash',
  String? progress,
  String? detail,
  int startedAtMs = 1700000000000,
  int? finishedAtMs,
}) => JobSummary(
  id: id,
  kind: kind,
  label: label,
  status: status,
  progress: progress,
  detail: detail,
  startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMs),
  finishedAt: finishedAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(finishedAtMs),
  output: const JobOutput(total: 0, earliest: 0),
);

Widget host(Widget child, {double width = 390}) {
  final tokens = Tokens.light;
  final text = AppTextStyles(tokens, 16);
  // 包 AppLocaleScope：断言的是中文文案，缺了会回退到英文。
  return AppTheme(
      tokens: tokens,
      text: text,
      child: MaterialApp(
        home: AppLocaleScope(
          language: AppLanguage.zh,
          child: SizedBox(width: width, child: child),
        ),
      ),
  );
}

void main() {
  backButtonTests();

  testWidgets('显示进行中与已完成分区', (tester) async {
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => controller.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
        ),
      ),
    );

    controller.add([
      job(id: 'a', status: JobStatus.running, label: '正在跑的', progress: '3/10'),
      job(id: 'b', status: JobStatus.completed, label: '已完成的',
          finishedAtMs: 1700000010000),
    ]);
    // 不能用 pumpAndSettle：PulseDot 是无限循环动画，永远「不 settle」。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('最近完成'), findsOneWidget);
    expect(find.text('正在跑的'), findsOneWidget);
    expect(find.text('已完成的'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
  });

  testWidgets('空状态', (tester) async {
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => controller.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
        ),
      ),
    );
    controller.add(const []);
    await tester.pumpAndSettle();

    expect(find.text('暂无后台任务'), findsOneWidget);
  });

  testWidgets('错误态可重试', (tester) async {
    var calls = 0;
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) {
            calls++;
            return controller.stream;
          },
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
        ),
      ),
    );
    controller.addError(StateError('mux is not connected'));
    await tester.pumpAndSettle();

    // 错误提示已改为 FriendlyError 翻译后的文案（不显示原始异常）。
    expect(find.text('连接已断开'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('每帧是全集：新帧替换旧列表', (tester) async {
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => controller.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
        ),
      ),
    );

    controller.add([job(id: 'a', status: JobStatus.running, label: '旧任务')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('旧任务'), findsOneWidget);

    // 全集帧里没有旧任务 → 应该消失
    controller.add([job(id: 'b', status: JobStatus.running, label: '新任务')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('旧任务'), findsNothing);
    expect(find.text('新任务'), findsOneWidget);
  });

  testWidgets('点击任务行打开详情', (tester) async {
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => controller.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
        ),
      ),
    );
    controller.add([
      job(id: 'bash-xyz', status: JobStatus.running, label: '可点任务'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('可点任务'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('任务 ID'), findsOneWidget);
    expect(find.text('bash-xyz'), findsOneWidget);
    expect(find.text('终止任务'), findsOneWidget);
  });

  testWidgets('已完成任务不显示终止按钮', (tester) async {
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => controller.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
        ),
      ),
    );
    controller.add([
      job(id: 'done-1', status: JobStatus.completed, label: '已完成任务',
          finishedAtMs: 1700000010000),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('已完成任务'));
    await tester.pumpAndSettle();

    expect(find.text('终止任务'), findsNothing);
  });

  testWidgets('终止流程：确认后调用 onKill', (tester) async {
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);
    String? killedId;

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => controller.stream,
          onKill: (id) async {
            killedId = id;
            return const JobKillResult(outcome: 'requested');
          },
        ),
      ),
    );
    controller.add([
      job(id: 'live-1', status: JobStatus.running, label: '待终止'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('待终止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('终止任务'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 二次确认
    expect(find.text('终止任务？'), findsOneWidget);
    await tester.tap(find.text('终止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(killedId, 'live-1');
    expect(find.text('已请求终止'), findsOneWidget);
  });

  testWidgets('TaskRow 命中区不小于 44', (tester) async {
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 390,
          child: TaskRow(
            job: job(id: 'a', status: JobStatus.running, label: 'x'),
            onTap: () {},
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(TaskRow));
    expect(size.height, greaterThanOrEqualTo(Hit.min));
  });

  testWidgets('ProgressBar 不声称精确百分比', (tester) async {
    await tester.pumpWidget(
      host(
        const ProgressBar(label: '进行中，已 3 步'),
      ),
    );
    // 语义标签应包含真实状态而非编造的百分比
    final semantics = tester.getSemantics(find.byType(ProgressBar));
    expect(semantics.label, contains('进行中'));
  });

  testWidgets('窄屏无横向溢出', (tester) async {
    final controller = StreamController<List<JobSummary>>();
    addTearDown(controller.close);

    await tester.pumpWidget(
      host(
        JobCenterPage(
          sessionId: 's1',
          watch: (_) => controller.stream,
          onKill: (_) async => const JobKillResult(outcome: 'requested'),
        ),
        width: 375,
      ),
    );
    controller.add([
      job(
        id: 'long-1',
        status: JobStatus.running,
        label: '这是一个非常非常非常非常非常非常非常非常长的任务标签用来测试溢出',
        progress: 'step 12345 / 99999',
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });
}

// ───────────────────── 返回按钮 ─────────────────────

void backButtonTests() {
  group('JobCenterPage 返回按钮', () {
    testWidgets('showBack=false 时不显示返回', (tester) async {
      final c = StreamController<List<JobSummary>>();
      addTearDown(c.close);
      await tester.pumpWidget(
        host(
          JobCenterPage(
            sessionId: 's1',
            watch: (_) => c.stream,
            onKill: (_) async => const JobKillResult(outcome: 'requested'),
          ),
        ),
      );
      c.add(const []);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byTooltip('返回'), findsNothing);
    });

    testWidgets('onBack 存在时显示返回按钮并触发回调', (tester) async {
      final c = StreamController<List<JobSummary>>();
      addTearDown(c.close);
      var backed = false;

      await tester.pumpWidget(
        host(
          JobCenterPage(
            sessionId: 's1',
            watch: (_) => c.stream,
            onKill: (_) async => const JobKillResult(outcome: 'requested'),
            onBack: () => backed = true,
            title: '后台任务',
          ),
        ),
      );
      c.add(const []);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byTooltip('返回'), findsOneWidget);
      expect(find.text('后台任务'), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      expect(backed, isTrue, reason: '点返回应触发 onBack 回调');
    });

    testWidgets('返回按钮命中区 ≥44', (tester) async {
      final c = StreamController<List<JobSummary>>();
      addTearDown(c.close);
      await tester.pumpWidget(
        host(
          JobCenterPage(
            sessionId: 's1',
            watch: (_) => c.stream,
            onKill: (_) async => const JobKillResult(outcome: 'requested'),
            onBack: () {},
          ),
        ),
      );
      c.add(const []);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final size = tester.getSize(find.byTooltip('返回'));
      expect(size.height, greaterThanOrEqualTo(Hit.min));
    });
  });
}
