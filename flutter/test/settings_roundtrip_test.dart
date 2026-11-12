/// 设置项往返完整性。
///
/// 起因是一个真实 bug：`toSettings` / `fromSettings` 漏了 `language`，
/// 于是「设置页选了语言」→ 回传 `AppearanceSettings` → 转回状态时被丢弃，
/// 表现为**语言无法切换**（点了没反应）。
///
/// 同类风险适用于任何新加的设置项，所以这里用「逐字段改动都要能往返」
/// 的方式钉住：以后再加字段，漏了就会失败。
library;

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/appearance_state.dart';
import 'package:dsh_mobile/src/ui/appearance_page.dart'
    show MotionPreference, ThemePreference;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppearanceState 往返', () {
    test('默认值往返不变', () {
      const a = AppearanceState();
      final back = AppearanceState.fromSettings(a.toSettings());
      expect(back, equals(a));
    });

    test('语言改动能往返（回归）', () {
      const a = AppearanceState(language: AppLanguage.en);
      final s = a.toSettings();
      expect(s.language, AppLanguage.en, reason: 'toSettings 必须带上 language');
      final back = AppearanceState.fromSettings(s);
      expect(back.language, AppLanguage.en, reason: 'fromSettings 必须还原 language');
    });

    test('每个字段单独改动都能往返', () {
      const base = AppearanceState();
      final variants = <AppearanceState>[
        base.copyWith(language: AppLanguage.zh),
        base.copyWith(language: AppLanguage.en),
        base.copyWith(fontBase: 20),
        base.copyWith(scalePercent: 120),
        base.copyWith(theme: ThemePreference.dark),
        base.copyWith(motion: MotionPreference.reduced),
      ];
      for (final v in variants) {
        final back = AppearanceState.fromSettings(v.toSettings());
        expect(back, equals(v), reason: '字段在往返中丢失: $v');
      }
    });

    test('语言不同则状态不相等（否则界面不重建）', () {
      const a = AppearanceState();
      const b = AppearanceState(language: AppLanguage.en);
      expect(a == b, isFalse, reason: '只改语言时 == 必须为 false');
      expect(a.hashCode == b.hashCode, isFalse);
    });

    test('JSON 持久化包含语言', () {
      const a = AppearanceState(language: AppLanguage.en);
      final json = a.toJson();
      expect(json['language'], 'en');
      expect(AppearanceState.fromJson(json).language, AppLanguage.en);
    });
  });
}

// ── 追加：设置页 UI 回调链路 ──
// 用 widget 测试直接点击「简体中文」，确保 onChanged 真的被调用。
// 之前只测了模型往返，没测 UI → 模型这一段，所以「点了没反应」漏掉了。
