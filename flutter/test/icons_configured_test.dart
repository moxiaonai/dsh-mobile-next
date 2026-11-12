/// 图标字体配置的防回归测试。
///
/// ## 为什么需要这个测试
///
/// `pubspec.yaml` 缺少 `flutter: uses-material-design: true` 时：
/// - `flutter build` **不会报错**
/// - `flutter analyze` **不会报错**
/// - 所有 `Icons.*` 在运行时渲染成方框（tofu）
///
/// 这是一个只在真机上肉眼可见的静默失败。本测试把配置断言进 CI。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pubspec 声明 uses-material-design: true', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    // 必须存在 flutter: 段
    expect(
      RegExp(r'^flutter:', multiLine: true).hasMatch(pubspec),
      isTrue,
      reason: '缺少顶层 flutter: 段',
    );

    // 该段内必须有 uses-material-design: true
    final hasFlag = RegExp(
      r'^\s+uses-material-design:\s*true\s*$',
      multiLine: true,
    ).hasMatch(pubspec);
    expect(
      hasFlag,
      isTrue,
      reason: '缺少 uses-material-design: true —— '
          'Material Icons 字体不会被打包，所有图标渲染成方框',
    );
  });

  test('图标字体已打包进 APK（若存在构建产物）', () {
    final apk = File(
      'build/app/outputs/flutter-apk/app-debug.apk',
    );
    if (!apk.existsSync()) {
      // 没有构建产物时跳过：这个断言只在跑过 flutter build 后有内容
      return;
    }
    // 用 unzip -l 列内容（APK 是 zip）
    final result = Process.runSync('unzip', ['-l', apk.path]);
    final listing = result.stdout.toString();
    expect(
      listing.contains('MaterialIcons-Regular.otf'),
      isTrue,
      reason: 'APK 内没有 MaterialIcons 字体，图标会渲染成方框',
    );
  });
}
