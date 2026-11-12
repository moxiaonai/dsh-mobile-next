/// 外观设置测试 —— 重点是主题切换真的生效。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/appearance_state.dart';
import 'package:dsh_mobile/src/ui/appearance_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/tokens.dart';

/// 包一层 AppTheme（AppearancePage 依赖它取 tokens）。
Widget host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('AppearanceState.resolveBrightness', () {
    test('light 覆盖系统', () {
      const s = AppearanceState(theme: ThemePreference.light);
      expect(s.resolveBrightness(Brightness.dark), Brightness.light);
    });

    test('dark 覆盖系统', () {
      const s = AppearanceState(theme: ThemePreference.dark);
      expect(s.resolveBrightness(Brightness.light), Brightness.dark);
    });

    test('system 跟随平台', () {
      const s = AppearanceState();
      expect(s.resolveBrightness(Brightness.dark), Brightness.dark);
      expect(s.resolveBrightness(Brightness.light), Brightness.light);
    });
  });

  group('AppearanceState.resolveReduceMotion', () {
    test('reduced 强制减弱', () {
      const s = AppearanceState(motion: MotionPreference.reduced);
      expect(s.resolveReduceMotion(false), isTrue);
    });

    test('system 跟随平台', () {
      const s = AppearanceState();
      expect(s.resolveReduceMotion(true), isTrue);
      expect(s.resolveReduceMotion(false), isFalse);
    });
  });

  group('序列化', () {
    test('往返保持所有字段', () {
      const s = AppearanceState(
        theme: ThemePreference.dark,
        fontBase: 20,
        motion: MotionPreference.reduced,
        scalePercent: 115,
      );
      final back = AppearanceState.fromJson(s.toJson());
      expect(back, s);
    });

    test('非法值回退默认', () {
      final back = AppearanceState.fromJson({
        'theme': 'nonsense',
        'fontBase': 'abc',
        'motion': '???',
        'scalePercent': null,
      });
      expect(back.theme, ThemePreference.system);
      expect(back.fontBase, 16);
      expect(back.motion, MotionPreference.system);
      expect(back.scalePercent, 100);
    });

    test('字号越界被钳制', () {
      expect(
        AppearanceState.fromJson({'fontBase': 999}).fontBase,
        AppearanceSettings.maxFont,
      );
      expect(
        AppearanceState.fromJson({'fontBase': 1}).fontBase,
        AppearanceSettings.minFont,
      );
    });
  });

  group('与设置页模型互转', () {
    test('往返保持', () {
      const s = AppearanceState(
        theme: ThemePreference.dark,
        fontBase: 18,
        motion: MotionPreference.reduced,
        scalePercent: 105,
      );
      final back = AppearanceState.fromSettings(s.toSettings());
      expect(back, s);
    });
  });

  group('主题切换真的生效（回归）', () {
    testWidgets('点「深色」后 onChanged 收到深色', (tester) async {
      AppearanceSettings? got;
      await tester.pumpWidget(
        host(
          AppearancePage(
            settings: const AppearanceSettings(),
            onChanged: (s) => got = s,
          ),
        ),
      );
      // 主题分段控件里的「深色」
      await tester.tap(find.text('深色'));
      await tester.pump();

      expect(got, isNotNull, reason: '点主题应触发 onChanged');
      expect(
        got!.theme,
        ThemePreference.dark,
        reason: '主题改动不能被丢弃 —— 这正是初版的 bug',
      );
    });

    testWidgets('点「始终减弱」后 onChanged 收到减弱', (tester) async {
      AppearanceSettings? got;
      await tester.pumpWidget(
        host(
          AppearancePage(
            settings: const AppearanceSettings(),
            onChanged: (s) => got = s,
          ),
        ),
      );
      await tester.tap(find.text('始终减弱'));
      await tester.pump();
      expect(got!.motion, MotionPreference.reduced);
    });
  });
}
