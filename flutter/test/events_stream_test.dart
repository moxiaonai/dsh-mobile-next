/// `$events` 由连接层持有：一条连接一条流，断线重连后必须自动重开。
///
/// 这条测试守的是一个真实事故：早前「建连开一条流只为等 ready、上层再开
/// 第二条流收事件」，两条流同时挂在 `$events` 上时，服务端只把**增量**推给
/// 登记的那一条 —— 冷启动靠重放能看到历史审批，在线时新审批永远不出现。
/// 另外 mux 重连会清掉所有逻辑流，若不重开，审批这类纯推送事件永久失效。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/transport/connection.dart';
import 'package:dsh_mobile/src/transport/mux.dart';
import 'package:dsh_mobile/src/transport/unary.dart';

/// 只回 `session/list` 的假 unary 传输。
class _FakeTransport implements HttpTransport {
  @override
  Future<({int statusCode, String body})> post(
    Uri uri,
    String body, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    final request = jsonDecode(body) as Map<String, Object?>;
    return (
      statusCode: 200,
      body: jsonEncode({
        'type': 'server-response',
        'rpcId': request['rpcId'],
        'result': {
          'ok': true,
          'value': {'sessions': <Object?>[]},
        },
      }),
    );
  }
}

/// 每次 open 回一个递增的 clientId，便于断言「重连后换了 generation」。
var _clientIdSeq = 0;

/// 可在测试里推帧、断线的假 WebSocket。
class _FakeSocket implements MuxSocket {
  final _controller = StreamController<String>.broadcast();
  final List<String> sent = [];

  @override
  Stream<String> get messages => _controller.stream;

  @override
  Future<void> get ready async {}

  @override
  void send(String data) {
    sent.add(data);
    // 服务端在 open 之后会立刻回 ready：这里自动回，避免测试与连接层互相等待。
    final frame = jsonDecode(data);
    if (frame is Map && frame['type'] == 'open') {
      final streamId = frame['streamId'];
      Future<void>.delayed(Duration.zero, () {
        if (_controller.isClosed) return;
        push(
          jsonEncode({
            'type': 'ready',
            'streamId': streamId,
            'clientId': 'cid-${++_clientIdSeq}',
          }),
        );
      });
    }
  }

  @override
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  void push(String frame) => _controller.add(frame);

  /// 已发出的 open 帧里，指向 [endpoint] 的那些。
  List<Map<String, Object?>> opens(String endpoint) => [
    for (final raw in sent)
      if (jsonDecode(raw) case final Map<String, Object?> frame
          when frame['type'] == 'open' && frame['endpoint'] == endpoint)
        frame,
  ];
}

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时${reason == null ? '' : '：$reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late List<_FakeSocket> sockets;

  Future<DshConnection> connect() => DshConnection.connect(
    origin: Uri.parse('https://127.0.0.1:9'),
    cookieHeader: 'dsh-mobile-next-session=x',
    transport: _FakeTransport(),
    socketFactory: (uri, headers) async {
      final socket = _FakeSocket();
      sockets.add(socket);
      return socket;
    },
    backoff: const BackoffPolicy(baseMs: 5, maxMs: 5),
    random: () => 1,
  );

  setUp(() {
    sockets = [];
    _clientIdSeq = 0;
  });

  test(r'建连只开一条 $events，clientId 取自 ready 帧', () async {
    final conn = await connect();
    addTearDown(conn.dispose);

    expect(sockets, hasLength(1));
    expect(sockets.first.opens(r'$events'), hasLength(1));
    await _waitFor(() => conn.eventsClientId == 'cid-1');
  });

  test(r'mux 重连后自动重开 $events，新事件仍能送达', () async {
    final conn = await connect();
    addTearDown(conn.dispose);
    await _waitFor(() => conn.eventsClientId == 'cid-1');

    final received = <Object?>[];
    final sub = conn.events.listen((event) {
      if (event is StreamItem) received.add(event.value);
    });
    addTearDown(sub.cancel);

    // 模拟 socket 断开：mux 会退避重连，connection 必须在新 socket 上重开流。
    await sockets.first.close();
    await _waitFor(() => sockets.length == 2, reason: 'mux 未重连');
    await _waitFor(
      () => sockets[1].opens(r'$events').isNotEmpty,
      reason: r'$events 未重开',
    );
    expect(sockets[1].opens(r'$events').single['streamId'], 's1');
    await _waitFor(() => conn.eventsClientId == 'cid-2');

    sockets[1].push(
      jsonEncode({
        'type': 'item',
        'streamId': 's1',
        'value': {'type': 'waterfall', 'event': 'approval/request'},
      }),
    );
    await _waitFor(
      () => received.any((v) => v is Map && v['event'] == 'approval/request'),
      reason: '重连后的事件没送达',
    );
  });

  test(r'释放连接会取消 $events 并关闭广播', () async {
    final conn = await connect();
    await _waitFor(() => conn.eventsClientId == 'cid-1');

    await conn.dispose();
    await expectLater(conn.events, emitsDone);
  });
}
