/// 系统返回键的层级判定 + 真实 `popRoute` 拦截回归。
///
/// ## 缺陷背景
///
/// 会话详情页与后台任务页**不是 Navigator 路由**，而是宿主用 `setState`
/// 换 `body`。于是系统返回键（Android 返回键 / 左滑返回手势）没有拦截点：
///
/// ```
/// handlePopRoute() → 没有观察者认领 → SystemNavigator.pop() → App 退出
/// ```
///
/// 用户在详情页一左滑就退回桌面。`docs/70-ui-interaction-redesign.md`
/// §P0-8 记录了这个缺陷。
///
/// 这里两层都测：
/// 1. `resolveBackAction` 的纯逻辑（顺序错了就会跳层）；
/// 2. 真的往 `flutter/navigation` 通道注入 `popRoute`，验证 `PopScope`
///    确实把它吃掉、且没有走到 `SystemNavigator.pop()`。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/ui/back_navigation.dart';

/// 往 `flutter/navigation` 注入一次 Android 返回键意图。
///
/// 这是框架自己的测试用的方式（`flutter/test/widgets/app_test.dart:315`），
/// 比直接调 `handlePopRoute()` 更接近真机：真机也是走这个 method channel。
Future<void> pressSystemBack(WidgetTester tester) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  group('resolveBackAction 层级顺序', () {
    test('后台任务页 → 先关后台任务（最内层）', () {
      expect(
        resolveBackAction(showJobs: true, hasSession: true),
        BackAction.closeJobs,
      );
    });

    test('会话详情页 → 关会话', () {
      expect(
        resolveBackAction(showJobs: false, hasSession: true),
        BackAction.closeSession,
      );
    });

    test('tab 页 → 退出 App', () {
      expect(
        resolveBackAction(showJobs: false, hasSession: false),
        BackAction.exitApp,
      );
    });

    test('断连后残留 showJobs 不得拦住返回', () {
      // build 的详情分支要求 _conn != null；断连时详情页根本不渲染，
      // 此时 hasSession 为 false，返回必须是退出而不是「关一个看不见的页」。
      expect(
        resolveBackAction(showJobs: true, hasSession: false),
        BackAction.exitApp,
      );
    });

    test('后台任务优先于详情（不能跳层直接回 tab）', () {
      // 回归：早期版本点返回从后台任务直接跳到 tab（实测跳到设备页）
      final first = resolveBackAction(showJobs: true, hasSession: true);
      expect(first, isNot(BackAction.closeSession));
      // 关掉后台任务后，下一次返回才关详情
      final second = resolveBackAction(showJobs: false, hasSession: true);
      expect(second, BackAction.closeSession);
    });
  });

  group('系统返回被 PopScope 拦截', () {
    /// 记录 `SystemNavigator.pop()` 是否被调用 —— 它就是「退出 App」。
    int exitCalls = 0;

    setUp(() {
      exitCalls = 0;
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemNavigator.pop') exitCalls++;
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    /// 复刻 `_ShellState.build` 的最小外壳：同样的 if/else 层级 + PopScope。
    Widget host({required bool showJobs, required bool hasSession}) {
      final body = showJobs && hasSession
          ? const Text('jobs-layer')
          : hasSession
          ? const Text('detail-layer')
          : const Text('tab-layer');
      return MaterialApp(
        home: PopScope(
          canPop:
              resolveBackAction(showJobs: showJobs, hasSession: hasSession) ==
              BackAction.exitApp,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // 真实实现会 setState 关一层；这里用标记验证「被拦截」即可
          },
          child: Scaffold(body: body),
        ),
      );
    }

    testWidgets('详情页按返回：不退出 App', (tester) async {
      await tester.pumpWidget(host(showJobs: false, hasSession: true));
      expect(find.text('detail-layer'), findsOneWidget);

      await pressSystemBack(tester);

      expect(exitCalls, 0, reason: '详情页的返回不应退出 App');
      expect(find.text('detail-layer'), findsOneWidget);
    });

    testWidgets('后台任务页按返回：不退出 App', (tester) async {
      await tester.pumpWidget(host(showJobs: true, hasSession: true));
      await pressSystemBack(tester);
      expect(exitCalls, 0, reason: '后台任务页的返回不应退出 App');
    });

    testWidgets('tab 页按返回：正常退出（不误拦）', (tester) async {
      await tester.pumpWidget(host(showJobs: false, hasSession: false));
      await pressSystemBack(tester);
      // canPop 为 true，PopScope 不拦；根路由无法再弹，框架走到 SystemNavigator.pop
      expect(exitCalls, 1, reason: 'tab 页应把返回交还系统');
    });
  });

  group('main.dart 接线（静态检查）', () {
    test('_ShellState 必须挂 PopScope 且用 resolveBackAction 判定层级', () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(
        source.contains('PopScope('),
        isTrue,
        reason: '没有 PopScope，系统返回键会直接退出 App（docs/70 §P0-8）',
      );
      expect(
        source.contains('resolveBackAction('),
        isTrue,
        reason: '层级判定必须复用 resolveBackAction，否则容易与 build 分支不同步',
      );
      expect(
        source.contains('_handleBack()'),
        isTrue,
        reason: 'onPopInvokedWithResult 里必须真的关一层',
      );
    });
  });
}
