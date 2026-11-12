/// 设置页 UI → 状态 的完整链路。
///
/// 回归背景：用户反馈「语言无法切换」。
/// 模型层往返测试是通的，但 UI 点击后状态没变 —— 必须用 widget 测试
/// 覆盖 `AppearancePage` 的 onChanged 链路。
library;

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/ui/appearance_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把 AppearancePage 包进它需要的主题环境。
Widget _host(Widget child) => AppTheme(
  tokens: Tokens.light,
  text: AppTextStyles(Tokens.light, 16),
  child: MaterialApp(home: child),
);

void main() {
  group('设置页语言切换', () {
    testWidgets('点「简体中文」会回调 onChanged 且带上 language', (tester) async {
      AppearanceSettings? received;
      await tester.pumpWidget(
        _host(
          AppearancePage(
            settings: const AppearanceSettings(language: AppLanguage.en),
            onChanged: (s) => received = s,
            onReset: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final zh = find.text('简体中文');
      expect(zh, findsOneWidget, reason: '语言选项应渲染出来');
      await tester.tap(zh);
      await tester.pumpAndSettle();

      expect(received, isNotNull, reason: 'onChanged 必须被调用');
      expect(received!.language, AppLanguage.zh);
    });

    testWidgets('点「English」会回调 onChanged', (tester) async {
      AppearanceSettings? received;
      await tester.pumpWidget(
        _host(
          AppearancePage(
            settings: const AppearanceSettings(language: AppLanguage.zh),
            onChanged: (s) => received = s,
            onReset: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(received?.language, AppLanguage.en);
    });

    testWidgets('切语言不会丢掉其它设置', (tester) async {
      AppearanceSettings? received;
      await tester.pumpWidget(
        _host(
          AppearancePage(
            settings: const AppearanceSettings(
              language: AppLanguage.system,
              fontBase: 20,
              scalePercent: 110,
            ),
            onChanged: (s) => received = s,
            onReset: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(received!.language, AppLanguage.en);
      expect(received!.fontBase, 20, reason: '切语言不能重置字号');
      expect(received!.scalePercent, 110);
    });
  });
}
