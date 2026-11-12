/// 连接编排：把双载具（HTTP unary + WebSocket mux）组合成一个可用的客户端。
///
/// 这一层是传输层的对外门面。上层 UI 只跟 [DshConnection] 打交道，
/// 不需要知道哪个端点走哪个载体。
library;

import 'dart:async';

import '../auth/pairing.dart';
import '../protocol/frames.dart';
import '../protocol/session.dart';
import '../transport/mux.dart';
import '../transport/unary.dart';

/// 连接状态。
enum ConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// 一条已建立连接的 DSH 客户端。
class DshConnection {
  DshConnection._({
    required this.origin,
    required this.unary,
    required this.mux,
    required this.sessions,
    required this.cookieHeader,
    this.onDispose,
  });

  final Uri origin;
  final UnaryClient unary;
  final MuxClient mux;

  /// 上游凭据 Cookie 头。
  ///
  /// 会话详情页用 WebView 渲染对话，需要把它注入页面请求。
  /// 只在本进程内存里流转，不落盘。
  final String cookieHeader;
  final SessionController sessions;
  final Future<void> Function()? onDispose;
  bool _disposed = false;

  final _stateController = StreamController<ConnectionState>.broadcast();
  ConnectionState _state = ConnectionState.disconnected;
  StreamSubscription<MuxState>? _muxSub;

  Stream<ConnectionState> get stateChanges => _stateController.stream;
  ConnectionState get state => _state;

  /// 建立连接。
  ///
  /// 顺序很重要：**先 unary 探活，再连 mux**。因为 unary 失败通常意味着
  /// 凭据或网络有问题，此时去连 WebSocket 只会得到一堆无意义的握手失败。
  static Future<DshConnection> connect({
    required Uri origin,
    required String cookieHeader,
    required HttpTransport transport,
    required MuxSocketFactory socketFactory,
    BackoffPolicy backoff = const BackoffPolicy(),
    double Function()? random,
    Future<void> Function()? onDispose,
  }) async {
    final unary = UnaryClient(
      origin: origin,
      transport: transport,
      cookieHeader: cookieHeader,
    );

    // 探活：session/list 是最轻的 unary 调用，用它验证凭据与连通性。
    // ⚠ 必须带 `_request`：该端点声明了必填参数，传空 args 会报
    //   gateway/arguments-invalid: missing "_request"（实测）。
    await unary.call(
      'session/list',
      args: const {'_request': <String, Object?>{}},
    );

    final muxUri = origin.replace(
      scheme: origin.scheme == 'https' ? 'wss' : 'ws',
      path: remoteMuxPath,
      query: null,
      fragment: null,
    );
    final mux = MuxClient(
      uri: muxUri,
      // WebSocket 升级同样要过 assertExternalTrust（gateway.ts:4391），
      // 因此必须显式带 Host —— dart:io 的 WebSocket.connect 不会自动补。
      headers: {
        'cookie': cookieHeader,
        'host': origin.hasPort ? '${origin.host}:${origin.port}' : origin.host,
      },
      socketFactory: socketFactory,
      backoff: backoff,
      random: random,
    );
    try {
      await mux.connect();

      // 开 $events 并等 ready —— 官方以 ready 帧作为 generation 建立的标志。
      // 不等它就开始读数据，会与增量观察竞态（官方注释明确此点）。
      await _awaitEventsReady(mux);
    } catch (_) {
      await mux.dispose();
      rethrow;
    }

    final conn = DshConnection._(
      origin: origin,
      unary: unary,
      mux: mux,
      sessions: SessionController(unary: unary, mux: mux),
      cookieHeader: cookieHeader,
      onDispose: onDispose,
    );
    conn._bind();
    conn._setState(ConnectionState.connected);
    return conn;
  }

  static Future<void> _awaitEventsReady(MuxClient mux) async {
    // `$events` 要求 payload 里有一个**空的 args 对象**：
    // 传空 payload 会被拒（`gateway/arguments-invalid`：
    // "forwarded Remote event stream requires an empty args object"）。
    final stream = mux.openStream(
      eventsEndpoint,
      payload: const {'args': <String, Object?>{}},
    );
    final completer = Completer<void>();
    late StreamSubscription<StreamEvent> sub;
    sub = stream.events.listen(
      (event) {
        if (completer.isCompleted) return;
        switch (event) {
          case StreamItem():
            completer.complete();
          case StreamFailed(:final error):
            completer.completeError(
              StateError('events stream failed: ${error.code}'),
            );
          case StreamEnded():
            completer.completeError(
              StateError('events stream ended before ready'),
            );
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );
    try {
      await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw StateError('events stream ready timeout (15s)'),
      );
    } finally {
      await sub.cancel();
    }
  }

  void _bind() {
    _muxSub = mux.stateChanges.listen((muxState) {
      switch (muxState) {
        case MuxState.connected:
          // 重连成功后服务端的活 Agent 绑定已失效，必须清掉激活缓存，
          // 否则下一次 prompt 会跳过 ensureActive 而静默失败。
          sessions.resetActivation();
          _setState(ConnectionState.connected);
        case MuxState.reconnecting:
          sessions.resetActivation();
          _setState(ConnectionState.reconnecting);
        case MuxState.closed:
          _setState(ConnectionState.failed);
        case MuxState.connecting:
          _setState(ConnectionState.connecting);
        case MuxState.idle:
          break;
      }
    });
  }

  void _setState(ConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _muxSub?.cancel();
      await mux.dispose();
      _setState(ConnectionState.disconnected);
      await _stateController.close();
    } finally {
      await onDispose?.call();
    }
  }
}

/// 从已保存的设备凭据恢复连接。
///
/// 使用 `native-renew` 换新会话令牌 —— Host 重启后旧的 sessionToken 会失效，
/// 但 deviceToken 仍然有效。
Future<DshConnection> connectWithCredential({
  required DeviceCredential credential,
  required HttpTransport transport,
  required MuxSocketFactory socketFactory,
}) async {
  final pairing = PairingClient(transport: transport);
  final renewed = await pairing.renew(
    origin: credential.origin,
    deviceToken: credential.deviceToken,
  );

  return DshConnection.connect(
    origin: credential.origin,
    // 插件把 sessionToken 映射为 `dsh-auth-*` cookie 的等价物。
    // 具体 cookie 名由插件决定，这里沿用配对响应的 csrf 与 session 令牌。
    cookieHeader: cookieHeaderFromPairing(renewed),
    transport: transport,
    socketFactory: socketFactory,
  );
}

/// 由配对结果构造 Cookie 头。
///
/// 说明：插件的 `sessionToken` **不是** DSH 的 `dsh-auth-*` cookie，
/// 而是插件自己的会话令牌。具体以哪个 cookie 名传给上游，
/// 由插件的代理层决定（`reference/src/gateway.ts:3083`）。
/// 这里按插件的既有约定使用 `dsh-mobile-session`；
/// **此项需在真机配对验证时确认**（见 spike/RESULTS.md §4 的未决项）。
/// ⚠ Cookie 名必须与插件 `gateway.ts` 的 `SESSION_COOKIE` 一致。
/// 插件用的是 `dsh-mobile-next-session`；写成 `dsh-mobile-session` 时
/// 网关读不到会话，每次都 401（重连必然失败）。
String cookieHeaderFromPairing(PairingResult result) =>
    'dsh-mobile-next-session=${result.sessionToken}; dsh-mobile-next-csrf=${result.csrfToken}';
