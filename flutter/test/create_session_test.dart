/// `session/create`（新建会话）的协议形态与 FAB 入口回归。
///
/// ## 为什么单独测协议形态
///
/// `docs/70-ui-interaction-redesign.md` §6 的 F-2 把「`session/create` 的
/// 必填参数形态」列为**前置 spike**：参数传错时服务端的拒绝信息是
/// `gateway/arguments-invalid`，从手机端看就是「点了没反应」。
///
/// 已按 `tool/schema.json` 核实：`SessionCreateRequest` 的 `required` 是
/// **空数组**，`workspaceId` / `cwd` / `sessionId` / `agentPreset` 全部可选，
/// 且 `workspaceId` 与 `cwd` **互斥**。这些约束用测试锁住，
/// 免得以后有人「补全必填字段」把手机端弄坏。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/protocol/frames.dart' show ProtocolError;
import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/protocol/sessions.dart';
import 'package:dsh_mobile/src/transport/mux.dart';
import 'package:dsh_mobile/src/transport/unary.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/sessions_page.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

/// 记录请求并返回可控响应的假传输。
///
/// 必须回显 `rpcId`：`UnaryClient` 会校验它与请求一致（防响应错配），
/// 不回显会被判为协议错误。
class _RecordingTransport implements HttpTransport {
  _RecordingTransport({this.value, this.statusCode = 200});

  /// 成功时返回的 `result.value`。
  final Object? value;
  final int statusCode;

  /// 每次请求的 (endpoint, 请求体)。
  final List<({String endpoint, Map<String, Object?> body})> calls = [];

  @override
  Future<({int statusCode, String body})> post(
    Uri uri,
    String body, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    final decoded = jsonDecode(body) as Map<String, Object?>;
    calls.add((
      // 端点形如 `/api/session/create`，取 `api/` 之后的全部
      endpoint: uri.path.replaceFirst('/api/', ''),
      body: decoded,
    ));
    if (statusCode != 200) {
      return (statusCode: statusCode, body: '{"error":"boom"}');
    }
    return (
      statusCode: 200,
      body: jsonEncode({
        'type': 'server-response',
        'rpcId': decoded['rpcId'],
        'result': {'ok': true, 'value': value},
      }),
    );
  }
}

/// 取出请求体里的 `args.request`。
Map<String, Object?> _requestOf(_RecordingTransport t) {
  final args = t.calls.single.body['payload'] as Map;
  return (args['args'] as Map).cast<String, Object?>()['request']
      as Map<String, Object?>;
}

SessionBrowser _browserWith(_RecordingTransport transport) => SessionBrowser(
  unary: UnaryClient(
    origin: Uri.parse('https://127.0.0.1:3443'),
    transport: transport,
    cookieHeader: 'dsh-auth-x=v1.abc',
  ),
  // create() 只走 unary，不碰 mux；给一个永不调用的 factory 即可。
  mux: MuxClient(
    uri: Uri.parse('wss://127.0.0.1:3443'),
    headers: const {},
    socketFactory: (_, _) => throw StateError('mux 不应被 create() 使用'),
  ),
);
Widget host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(
      home: AppLocaleScope(language: AppLanguage.zh, child: child),
    ),
  );
}

SessionSummary sess(String id, {String? title}) => SessionSummary(
  id: id,
  title: title,
  cwd: '/Users/x/proj',
  updatedAt: DateTime.now(),
);

void main() {
  group('SessionBrowser.create 协议形态', () {
    test('不传任何参数也合法（全部可选）', () async {
      final t = _RecordingTransport(value: {'sessionId': 'session-new'});
      final id = await _browserWith(t).create();

      expect(id, 'session-new');
      expect(t.calls.single.endpoint, 'session/create');
      // 空 request 是合法的：required 为空数组
      expect(_requestOf(t), isEmpty);
    });

    test('只传 workspaceId', () async {
      final t = _RecordingTransport(value: {'sessionId': 's-new'});
      await _browserWith(t).create(workspaceId: 'w1');
      expect(_requestOf(t), {'workspaceId': 'w1'});
    });

    test('只传 cwd', () async {
      final t = _RecordingTransport(value: {'sessionId': 's-new'});
      await _browserWith(t).create(cwd: '/Users/x/proj');
      expect(_requestOf(t), {'cwd': '/Users/x/proj'});
    });

    test('返回服务端给的实际 id（可能不同于请求的）', () async {
      // schema：sessionId 是「要复用的空白会话」，服务端可能返回别的
      final t = _RecordingTransport(value: {'sessionId': 'session-reused'});
      final id = await _browserWith(t).create(sessionId: 'session-asked');
      expect(id, 'session-reused', reason: '必须用返回值，不能假设是自己传的');
      expect(_requestOf(t)['sessionId'], 'session-asked');
    });

    test('缺 sessionId 时抛 ProtocolError 而不是返回空串', () async {
      final t = _RecordingTransport(value: {'agentPreset': 'x'});
      expect(
        () => _browserWith(t).create(),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('sessionId 是空串也算失败', () async {
      final t = _RecordingTransport(value: {'sessionId': ''});
      expect(
        () => _browserWith(t).create(),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('返回值不是对象时抛 ProtocolError', () async {
      final t = _RecordingTransport(value: 'nope');
      expect(
        () => _browserWith(t).create(),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('服务端拒绝时抛 UnaryException', () async {
      final t = _RecordingTransport(statusCode: 400);
      expect(
        () => _browserWith(t).create(),
        throwsA(isA<UnaryException>()),
      );
    });

    test('workspaceId 与 cwd 互斥（assert 拦住）', () {
      final t = _RecordingTransport(value: {'sessionId': 'x'});
      expect(
        () => _browserWith(t).create(workspaceId: 'w1', cwd: '/tmp'),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('SessionsPage 新建会话 FAB', () {
    testWidgets('提供 onCreate 时显示 FAB', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [sess('s1', title: 'A')],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
            onCreate: () async => 'session-new',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byTooltip('新建会话'), findsOneWidget);
    });

    testWidgets('未提供 onCreate 时不显示 FAB', (tester) async {
      // 未连接时不该给一个按了必然失败的入口
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [sess('s1', title: 'A')],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('点 FAB 触发 onCreate', (tester) async {
      var called = 0;
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [sess('s1', title: 'A')],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
            onCreate: () async {
              called++;
              return 'session-new';
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(called, 1);
    });

    testWidgets('空列表也显示 FAB（新用户第一件事就是新建）', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => const [],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
            onCreate: () async => 'session-new',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('暂无会话'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('创建中禁用 FAB（防连点建出多个空会话）', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [sess('s1', title: 'A')],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
            onCreate: () async {
              calls++;
              // 挂住不返回，模拟慢网络
              await Future<void>.delayed(const Duration(seconds: 5));
              return 'session-new';
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();

      // 第二次点击必须被忽略
      await tester.tap(find.byType(FloatingActionButton), warnIfMissed: false);
      await tester.pump();

      expect(calls, 1, reason: '创建中必须忽略重复点击');

      // 收尾：让挂起的 future 结束，避免 pending timer
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('创建失败给出提示且 FAB 恢复可点', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [sess('s1', title: 'A')],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
            onCreate: () async {
              calls++;
              throw StateError('offline');
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('新建会话失败'), findsOneWidget);

      // 失败后必须能再点：否则一次网络抖动就永久锁死入口
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 2, reason: '失败后 FAB 必须恢复可点');
    });

    testWidgets('外层拿不到 id 时也提示，不静默失败', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [sess('s1', title: 'A')],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
            onCreate: () async => null,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('没能新建会话'), findsOneWidget);
    });
  });
}
