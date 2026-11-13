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

  group('恢复默认按钮', () {
    /// 带 AppLocaleScope 的宿主：按钮文案跟随实际语言（英文界面里
    /// 就是截图上的 `Reset to defaults`）。
    Widget hostWith(Widget child, AppLanguage language) => AppLocaleScope(
      language: language,
      child: _host(child),
    );

    /// 页面上的「恢复默认」按钮（sheet 里的确认项是 ListTile，不会混）。
    OutlinedButton resetButton(WidgetTester tester, String label) =>
        tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, label),
        );

    /// 按钮在列表底部（测试窗口 800×600 时在可视区外），先滚进来再点。
    Future<void> tapReset(WidgetTester tester, String label) async {
      final finder = find.widgetWithText(OutlinedButton, label);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('只改了语言时按钮可点，确认后回调 onReset 并 toast', (
      tester,
    ) async {
      var resetCount = 0;
      await tester.pumpWidget(
        hostWith(
          AppearancePage(
            // 回归：语言已偏离默认（中文系统上选了 English），
            // 但主题/字号/缩放/动效都还是默认值。
            settings: const AppearanceSettings(language: AppLanguage.en),
            onChanged: (_) {},
            onReset: () => resetCount++,
          ),
          AppLanguage.en,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        resetButton(tester, 'Reset to defaults').onPressed,
        isNotNull,
        reason: '语言已不是默认值，按钮不能因为别的字段是默认就被禁用',
      );

      // 按下：出二次确认 sheet，此时还没动状态
      await tapReset(tester, 'Reset to defaults');
      expect(find.text('Reset appearance?'), findsOneWidget);
      expect(resetCount, 0, reason: '确认前不能生效');

      // 确认
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(resetCount, 1, reason: '确认后必须把 onReset 回调出去');
      expect(find.text('Appearance reset to defaults'), findsOneWidget);

      // 让 SnackBar 的计时器走完，避免测试结束时残留 pending timer
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('全部为默认值时按钮仍可点（不再置灰）', (tester) async {
      await tester.pumpWidget(
        hostWith(
          AppearancePage(
            settings: const AppearanceSettings(language: AppLanguage.en),
            onChanged: (_) {},
            onReset: () {},
          ),
          AppLanguage.en,
        ),
      );
      await tester.pumpAndSettle();
      expect(resetButton(tester, 'Reset to defaults').onPressed, isNotNull);

      await tapReset(tester, 'Reset to defaults');
      expect(find.text('Reset appearance?'), findsOneWidget);
    });

    testWidgets('取消确认不回调 onReset', (tester) async {
      var resetCount = 0;
      await tester.pumpWidget(
        _host(
          AppearancePage(
            settings: const AppearanceSettings(fontBase: 20),
            onChanged: (_) {},
            onReset: () => resetCount++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tapReset(tester, '恢复默认');
      expect(find.text('恢复默认外观？'), findsOneWidget);

      // 点 sheet 外的遮罩 = 取消
      await tester.tapAt(const Offset(20, 100));
      await tester.pumpAndSettle();
      expect(resetCount, 0);
      expect(find.text('恢复默认外观？'), findsNothing);
    });
  });

  group('isDefault', () {
    test('切换语言后不再是默认值', () {
      expect(const AppearanceSettings().isDefault, isTrue);
      expect(
        const AppearanceSettings(language: AppLanguage.en).isDefault,
        isFalse,
        reason: '语言是设置页的字段，漏算会让「恢复默认」被误判为无操作',
      );
    });

    test('任一字段偏离默认都不是默认值', () {
      expect(const AppearanceSettings(theme: ThemePreference.dark).isDefault,
          isFalse);
      expect(const AppearanceSettings(fontBase: 17).isDefault, isFalse);
      expect(const AppearanceSettings(scalePercent: 105).isDefault, isFalse);
      expect(
        const AppearanceSettings(motion: MotionPreference.reduced).isDefault,
        isFalse,
      );
    });
  });
}
