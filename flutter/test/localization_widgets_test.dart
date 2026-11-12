/// Material 组件的多语言。
///
/// 回归背景：切到中文后底部导航栏红屏，报
/// `No MaterialLocalizations found`。
///
/// 原因：`localizationsDelegates` 用了 `DefaultMaterialLocalizations`
/// （**只支持英文**）。locale 解析成 zh 时，NavigationBar / 对话框等
/// Material 组件找不到中文文案，直接抛断言。
///
/// 修法是改用 `GlobalMaterialLocalizations`（来自 flutter_localizations）。
library;

import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Locale locale, Widget home) => AppTheme(
  tokens: Tokens.light,
  text: AppTextStyles(Tokens.light, 16),
  child: MaterialApp(
    locale: locale,
    supportedLocales: const [Locale('zh'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  ),
);

Widget _navBar() => NavigationBar(
  selectedIndex: 0,
  onDestinationSelected: (_) {},
  destinations: const [
    NavigationDestination(icon: Icon(Icons.task_alt), label: '任务'),
    NavigationDestination(icon: Icon(Icons.forum_outlined), label: '会话'),
  ],
);

void main() {
  group('Material 多语言', () {
    testWidgets('中文 locale 下 NavigationBar 不红屏', (tester) async {
      await tester.pumpWidget(_app(const Locale('zh'), _navBar()));
      await tester.pumpAndSettle();
      // 若缺 delegate 会抛 "No MaterialLocalizations found"
      expect(tester.takeException(), isNull);
      expect(find.text('任务'), findsOneWidget);
    });

    testWidgets('英文 locale 下 NavigationBar 正常', (tester) async {
      await tester.pumpWidget(_app(const Locale('en'), _navBar()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('中文下 Material 自带文案已本地化', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        _app(
          const Locale('zh'),
          Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = MaterialLocalizations.of(captured);
      // 中文的「确定」；英文是 OK。取反证明真的切到了中文
      expect(l10n.okButtonLabel, isNot(equals('OK')));
    });
  });
}
