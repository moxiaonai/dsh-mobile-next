/// 会话 WebView 注入脚本的单元测试。
///
/// 这些测试**不需要 Flutter 运行时**，用纯 Dart 即可跑：
///   dart test test/webview_scripts_test.dart
///
/// 为什么值得单独测：注入脚本是**字符串拼出来的 JavaScript**，
/// 拼错一个引号不会让 Dart 编译失败，只会在真机上表现为白屏或退回默认会话。
/// 这类缺陷在静态分析里是隐形的，只能用测试把住。
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'package:dsh_mobile/src/webview/session_css.dart';

void main() {
  group('sessionNarrowCss', () {
    test('emits a self-invoking script', () {
      final js = sessionNarrowCss();
      expect(js.trimLeft(), startsWith('(function () {'));
      expect(js.trimRight(), endsWith('})();'));
    });

    test('hides the sidebar only at wide widths', () {
      final js = sessionNarrowCss();
      // 手机宽度下 DSH 原生就是纯对话区，收窄只在宽屏生效。
      expect(js, contains('@media (min-width: 768px)'));
      expect(js, contains('[data-slot="sidebar"]'));
      expect(js, contains('display: none !important'));
    });

    test('is idempotent: re-running must not duplicate the style', () {
      final js = sessionNarrowCss();
      // 幂等靠「找到就更新内容」，而不是「找到就 return」。
      // 早先用 return 的写法会在 <html> 上残留一个永不刷新的 <style>。
      expect(js, contains('document.getElementById(ID)'));
      expect(js, contains("var ID = 'dsh-mobile-narrow'"));
      expect(js, isNot(contains('return;')));
    });

    test('falls back when <head> does not exist yet', () {
      final js = sessionNarrowCss();
      // AT_DOCUMENT_START 时 <head> 可能还没建出来。
      expect(js, contains("document.head || document.documentElement"));
      expect(js, contains('DOMContentLoaded'));
    });

    test('includeHeader disables the whole injection', () {
      expect(sessionNarrowCss(includeHeader: true), isEmpty);
    });

    test(r'contains no unescaped backtick or ${} interpolation', () {
      final js = sessionNarrowCss();
      // 用普通字符串 + 数组 join 就是为了避开模板字符串的 ` 和 ${}。
      expect(js, isNot(contains('`')));
      expect(js, isNot(contains(r'${')));
    });
  });

  group('settleAndRepaintJs', () {
    test('is a self-invoking script returning JSON', () {
      expect(settleAndRepaintJs.trimLeft(), startsWith('(function () {'));
      expect(settleAndRepaintJs, contains('JSON.stringify'));
    });

    test('only scrolls when the conversation actually has rows', () {
      // 空会话（欢迎页）滚动会把欢迎页滚乱。
      expect(settleAndRepaintJs, contains('rows > 0'));
    });

    test('reports the marker so callers can verify the session', () {
      expect(settleAndRepaintJs, contains('data-conversation-session'));
      expect(settleAndRepaintJs, contains('marker:'));
    });

    test('wraps everything so a DOM change cannot throw', () {
      expect(settleAndRepaintJs, contains('try {'));
      expect(settleAndRepaintJs, contains('catch (e)'));
    });
  });

  group('probeCurrentSessionJs', () {
    test('reads the session marker', () {
      expect(probeCurrentSessionJs, contains('data-conversation-session'));
    });
  });

  group('session bootstrap literal escaping', () {
    // 注入脚本里的 sessionId 是运行时值。这里复刻生产代码的编码方式
    // （见 SessionWebView._sessionBootstrap），验证特殊字符不会破坏脚本。
    String bootstrap(String sessionId) {
      final payload = jsonEncode({'sessionId': sessionId});
      final literal = jsonEncode(payload);
      return "localStorage.setItem('dsh.sessions.current', $literal);";
    }

    for (final id in <String>[
      'session-f4eb08af-2300-47c7-8ea1-2b4299a6931d',
      r"""session-quote'"`$""",
      'session-üñï-中文',
      'session-with\nnewline',
    ]) {
      test('round-trips ${jsonEncode(id)}', () {
        final js = bootstrap(id);
        // 剥掉固定的调用外壳，剩下的就是 JSON 字符串字面量。
        const prefix = "localStorage.setItem('dsh.sessions.current', ";
        expect(js, startsWith(prefix));
        expect(js, endsWith(');'));
        final literal = js.substring(prefix.length, js.length - 2);
        final decoded = jsonDecode(jsonDecode(literal) as String) as Map;
        expect(decoded['sessionId'], id);
      });
    }

    test('never emits a bare single-quoted interpolation', () {
      // 直接把 id 拼进单引号会让 `'` 提前闭合字符串 —— 这是最容易犯的错。
      final js = bootstrap(r"a'b");
      expect(js, isNot(contains("'a'b'")));
    });
  });
}
