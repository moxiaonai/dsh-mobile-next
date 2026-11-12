/// WebView 主题同步。
///
/// 背景：WebView 是独立文档，不继承 Flutter 主题。不注入的话，
/// App 切到深色、点进会话详情却是浅色页面。
///
/// DSH 的暗色开关是 `document.body[data-ds-dark-theme]`
/// （见 dsh-client-ui-layout 的 ThemePresenter），这里锁住注入脚本的形状。
library;

import 'package:dsh_mobile/src/webview/session_css.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebView 主题注入', () {
    test('深色时设 data-ds-dark-theme', () {
      final js = themeBootstrap(dark: true);
      expect(js, contains('data-ds-dark-theme'));
      expect(js, contains('setAttribute'));
      expect(js, contains("'dark'"));
      // 必须挂到 body 上：ThemePresenter 读的是 body
      expect(js, contains('document.body'));
    });

    test('浅色时移除属性而不是设空值', () {
      final js = themeBootstrap(dark: false);
      expect(js, contains('removeAttribute'));
      expect(js, contains("'light'"));
    });

    test('同时设 color-scheme（滚动条/原生控件跟随）', () {
      final js = themeBootstrap(dark: true);
      expect(
        js,
        contains('colorScheme'),
        reason: '只设属性不设 color-scheme，深色下滚动条仍是浅色',
      );
    });

    test('注入脚本用 try/catch 包裹，单点失败不影响页面', () {
      final js = themeBootstrap(dark: true);
      expect(js, contains('try'));
      expect(js, contains('catch'));
    });

    test('两个主题生成的脚本不同', () {
      expect(themeBootstrap(dark: true), isNot(equals(themeBootstrap(dark: false))));
    });

    // ── 语言：必须覆盖 navigator.languages ──
    // DSH 的初始语言来自 navigator.languages（resolveInitialLocale），
    // 只写 localStorage / lang 属性它根本不读 —— 实测「切中文 WebView 不变」。
    test('传 localeTag 时覆盖 navigator.languages', () {
      final js = themeBootstrap(dark: false, localeTag: 'zh-CN');
      expect(js, contains('navigator'));
      expect(js, contains('languages'));
      expect(js, contains('defineProperty'));
      expect(js, contains('zh-CN'));
    });

    test('不传 localeTag 时语言字面量为 null（运行时跳过覆盖）', () {
      final js = themeBootstrap(dark: false);
      // 生成的是 `if (null !== null) { ... }`，运行期不会执行覆盖
      expect(js, contains('if (null !== null)'));
      expect(js, isNot(contains('zh-CN')));
      expect(js, isNot(contains('en-US')));
    });
  });
}
