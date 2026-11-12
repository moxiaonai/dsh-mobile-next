/// 错误处理测试。
///
/// 核心断言：**原始异常不能直接展示给用户**。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/ui/friendly_error.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

Widget host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('FriendlyError 翻译', () {
    test('Connection refused → 连不上电脑', () {
      final e = FriendlyError.from(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
        ),
      );
      expect(e.title, '连不上电脑');
      expect(e.hint, contains('DSH 正在运行'));
      expect(e.retryable, isTrue);
      // 技术细节保留但不在主文案里
      expect(e.detail, contains('SocketException'));
    });

    test('超时 → 连接超时', () {
      final e = FriendlyError.from(TimeoutException('handshake timed out'));
      expect(e.title, '连接超时');
      expect(e.retryable, isTrue);
    });

    test('401 → 配对已失效且不可重试', () {
      final e = FriendlyError.from(StateError('HTTP 401 authentication_failed'));
      expect(e.title, '配对已失效');
      expect(e.retryable, isFalse, reason: '凭据失效重试无用，应引导重新配对');
    });

    test('403 → 电脑拒绝', () {
      final e = FriendlyError.from(StateError('HTTP 403 forbidden'));
      expect(e.title, contains('拒绝'));
    });

    test('gateway 错误 → 提取错误码', () {
      final e = FriendlyError.from(
        StateError('gateway/arguments-invalid: missing "_request"'),
      );
      expect(e.title, contains('电脑端处理失败'));
      expect(e.detail, 'gateway/arguments-invalid');
    });

    test('mux 未连接 → 连接已断开', () {
      final e = FriendlyError.from(StateError('mux is not connected'));
      expect(e.title, '连接已断开');
    });

    test('网络不可达', () {
      final e = FriendlyError.from(
        const SocketException('Network is unreachable', osError: OSError('x', 101)),
      );
      expect(e.title, '网络不可用');
    });

    test('未知错误有兜底文案', () {
      final e = FriendlyError.from(StateError('some weird thing'));
      expect(e.title, '出错了');
      expect(e.hint, isNotEmpty);
    });
  });

  group('ErrorState 渲染', () {
    testWidgets('不直接显示原始异常', (tester) async {
      final err = const SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 111),
      );
      await tester.pumpWidget(host(ErrorState(error: err)));

      // 主文案必须是用户能看懂的
      expect(find.text('连不上电脑'), findsOneWidget);
      // 原始异常不应作为主文案出现
      expect(find.textContaining('errno = 111'), findsNothing);
    });

    testWidgets('提供重试按钮', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        host(
          ErrorState(
            error: const SocketException('Connection refused'),
            onRetry: () => retried = true,
          ),
        ),
      );
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(retried, isTrue);
    });

    testWidgets('不可重试的错误不显示重试按钮', (tester) async {
      await tester.pumpWidget(
        host(
          ErrorState(
            error: StateError('HTTP 401 authentication_failed'),
            onRetry: () {},
          ),
        ),
      );
      expect(find.text('重试'), findsNothing);
      expect(find.text('配对已失效'), findsOneWidget);
    });

    testWidgets('技术细节默认折叠', (tester) async {
      await tester.pumpWidget(
        host(
          ErrorState(
            error: const SocketException('Connection refused'),
          ),
        ),
      );
      expect(find.textContaining('errno'), findsNothing);
      expect(find.text('查看技术细节'), findsOneWidget);

      await tester.tap(find.text('查看技术细节'));
      await tester.pump();
      // 展开后才可见
      expect(find.textContaining('SocketException'), findsOneWidget);
      expect(find.text('隐藏技术细节'), findsOneWidget);
    });

    testWidgets('重试按钮命中区 ≥48', (tester) async {
      await tester.pumpWidget(
        host(
          ErrorState(
            error: const SocketException('Connection refused'),
            onRetry: () {},
          ),
        ),
      );
      final size = tester.getSize(
        find.ancestor(
          of: find.text('重试'),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(size.height, greaterThanOrEqualTo(Hit.primary));
    });
  });
}
