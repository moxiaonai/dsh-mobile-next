import 'dart:async';
import 'dart:io';

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/ui/diagnostics_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DiagnosticReport _report(String label) => DiagnosticReport(
  generatedAt: DateTime(2026, 1, 1),
  layers: [
    DiagnosticLayer(
      title: '现场状态',
      checks: [DiagnosticCheck(label: label, status: CheckStatus.ok)],
    ),
  ],
);

class _Observer extends NavigatorObserver {
  int pushes = 0;
  int replacements = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      replacements++;
}

Widget _host(Widget child, {_Observer? observer}) {
  final tokens = Tokens.light;
  return AppTheme(
    tokens: tokens,
    text: AppTextStyles(tokens, 16),
    child: AppLocaleScope(
      language: AppLanguage.zh,
      child: MaterialApp(
        navigatorObservers: [if (observer != null) observer],
        home: child,
      ),
    ),
  );
}

void main() {
  test('手机路径始终为说明，不因其他层成功而显示通过', () {
    final strings = AppStrings.forLanguage(AppLanguage.zh);
    expect(phonePathCheck(strings).status, CheckStatus.info);
    expect(phonePathCheck(strings).detail, isNotNull);
  });

  test('应用诊断入口不递归/替换路由，并使用现场连接与设备状态', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('  Future<void> _openDiagnostics(');
    final end = source.indexOf('  Future<void> _decideApproval(', start);
    final method = source.substring(start, end);
    expect(RegExp(r'_openDiagnostics\(').allMatches(method), hasLength(1));
    expect(method, isNot(contains('pushReplacement')));
    expect(method, contains('DiagnosticsRunner('));
    expect(method, contains('_deviceList().where((d) => d.id == device.id)'));
    expect(method, contains("state.name == 'connected'"));
    expect(method, contains("'session/list'"));
    expect(method, contains('identical(conn, _conn)'));
  });

  testWidgets('检查原地更新，不新增/替换路由；返回只需一次', (tester) async {
    final observer = _Observer();
    var runs = 0;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (context) => DiagnosticsRunner(
                  run: () async => _report('报告 ${++runs}'),
                  onBack: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            child: const Text('设备页'),
          ),
        ),
        observer: observer,
      ),
    );
    await tester.tap(find.text('设备页'));
    await tester.pumpAndSettle();
    final pushes = observer.pushes;
    final runner = tester.state(find.byType(DiagnosticsRunner));
    for (var i = 1; i <= 3; i++) {
      await tester.tap(find.widgetWithText(FilledButton, '开始检查'));
      await tester.pumpAndSettle();
      expect(find.text('报告 $i'), findsOneWidget);
      expect(tester.state(find.byType(DiagnosticsRunner)), same(runner));
    }
    expect(observer.pushes, pushes);
    expect(observer.replacements, 0);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('设备页'), findsOneWidget);
    expect(find.byType(DiagnosticsRunner), findsNothing);
  });

  testWidgets('下一帧前连点也只执行一次，busy 禁用按钮', (tester) async {
    var runs = 0;
    final pending = Completer<DiagnosticReport>();
    await tester.pumpWidget(
      _host(
        DiagnosticsRunner(
          run: () {
            runs++;
            return pending.future;
          },
        ),
      ),
    );
    final run = tester
        .widget<DiagnosticsPage>(find.byType(DiagnosticsPage))
        .onRun!;
    run();
    run();
    expect(runs, 1);
    await tester.pump();
    expect(find.text('检查中…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    pending.complete(_report('当前报告'));
    await tester.pumpAndSettle();
    expect(find.text('当前报告'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('同步/异步错误均恢复并保留报告，后续检查读取新状态', (tester) async {
    var attempts = 0;
    var snapshot = '首次状态';
    String? copied;
    await tester.pumpWidget(
      _host(
        DiagnosticsRunner(
          initialReport: _report(snapshot),
          onCopyReport: (text) => copied = text,
          run: () {
            attempts++;
            if (attempts == 1) {
              throw StateError('secret-token https://private.example');
            }
            if (attempts == 2) {
              return Future.error(StateError('private-cookie'));
            }
            return Future.value(_report(snapshot));
          },
        ),
      ),
    );
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.widgetWithText(FilledButton, '开始检查'));
      await tester.pumpAndSettle();
      expect(find.text('首次状态'), findsOneWidget);
      expect(
        tester
            .widget<DiagnosticsPage>(find.byType(DiagnosticsPage))
            .errorMessage,
        '失败',
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(find.textContaining('secret-token'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    snapshot = '重新读取的状态';
    await tester.tap(find.widgetWithText(FilledButton, '开始检查'));
    await tester.pumpAndSettle();
    expect(find.text(snapshot), findsOneWidget);
    expect(find.text('首次状态'), findsNothing);
    expect(
      tester.widget<DiagnosticsPage>(find.byType(DiagnosticsPage)).errorMessage,
      isNull,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, '复制报告'));
    expect(copied, contains(snapshot));
    expect(copied, isNot(contains('首次状态')));
  });

  for (final fails in [false, true]) {
    testWidgets('退出后忽略迟到${fails ? '错误' : '报告'}', (tester) async {
      final pending = Completer<DiagnosticReport>();
      await tester.pumpWidget(
        _host(DiagnosticsRunner(run: () => pending.future)),
      );
      await tester.tap(find.widgetWithText(FilledButton, '开始检查'));
      await tester.pump();
      await tester.pumpWidget(_host(const Text('已退出')));
      if (fails) {
        pending.completeError(StateError('late failure'));
      } else {
        pending.complete(_report('迟到报告'));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('已退出'), findsOneWidget);
      expect(find.text('迟到报告'), findsNothing);
    });
  }
}
