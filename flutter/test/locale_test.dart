import 'dart:ui' show Locale;

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('中文表完整', () {
    final zh = AppStrings.forLanguage(AppLanguage.zh);
    expect(zh('nav.tasks'), '任务');
    expect(zh('nav.settings'), '设置');
  });
  test('英文表完整', () {
    final en = AppStrings.forLanguage(AppLanguage.en);
    expect(en('nav.tasks'), 'Tasks');
    expect(en('nav.settings'), 'Settings');
  });
  test('缺翻译回退中文而不是显示 key', () {
    final en = AppStrings.forLanguage(AppLanguage.en);
    // 所有中文键在英文表里都要有
    for (final k in ['nav.tasks','unpaired.title','pair.success','settings.language']) {
      expect(en(k), isNot(equals(k)), reason: '$k 缺英文翻译');
    }
  });
  test('resolveLanguage: system 跟随系统', () {
    expect(resolveLanguage(AppLanguage.system, const Locale('zh','CN')), AppLanguage.zh);
    expect(resolveLanguage(AppLanguage.system, const Locale('en','US')), AppLanguage.en);
    expect(resolveLanguage(AppLanguage.zh, const Locale('en','US')), AppLanguage.zh);
  });
  test('语言标签正确', () {
    expect(AppLanguage.zh.tag, 'zh-CN');
    expect(AppLanguage.en.tag, 'en-US');
    expect(AppLanguage.system.tag, isNull);
  });
}
