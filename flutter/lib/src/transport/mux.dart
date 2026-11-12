/// WebSocket 流载具：`/api/remote.mux`。
///
/// 这是**双载具**之二（见 `docs/60-protocol-feasibility.md` §5.1）：
/// 流式端点（`$events`、`session/follow`、`job/list`、`workspace/follow`…）
/// 必须走这条 WebSocket；unary 端点走它会得到 `gateway/signature-invalid`。
///
/// 设计要点：
/// - **一条物理 socket 承载多条逻辑流**，按 `streamId` 分发。
/// - 重连由 [MuxClient] 自身按官方退避阶梯处理，且每次重试都**换一条新 socket**
///   并重开 `$events`（官方行为，spike 已实测）。
/// - 退避是**抖动**的（`cap/2 … cap`），因此断言不能写 `delay == cap`。
library;

import 'dart:async';
import 'dart:convert';

import '../protocol/frames.dart';

/// 一条逻辑流的事件。
sealed class StreamEvent {
  const StreamEvent();
}

class StreamItem extends StreamEvent {
  const StreamItem(this.value, {this.hasValue = true});
  final Object? value;
  final bool hasValue;
}

class StreamEnded extends StreamEvent {
  const StreamEnded();
}

class StreamFailed extends StreamEvent {
  const StreamFailed(this.error);
  final RemoteError error;
}

/// 官方退避参数（`dsh-client-connection/lib/client.node.js`）：
/// `backoffBaseMs: 500, backoffFactor: 2, backoffMaxMs: 10000`。
class BackoffPolicy {
  const BackoffPolicy({
    this.baseMs = 500,
    this.factor = 2,
    this.maxMs = 10000,
    this.jitterFloor = 0.5,
  });

  final int baseMs;
  final int factor;
  final int maxMs;

  /// 抖动下界比例。官方为 50%–100%：`cap/2 + rand*(cap/2)`。
  final double jitterFloor;

  /// 第 [attempt] 次重试的 cap（attempt 从 1 开始）。
  int cap(int attempt) {
    if (attempt < 1) return baseMs;
    final raw = baseMs * _pow(factor, attempt - 1);
    return raw > maxMs ? maxMs : raw;
  }

  /// 第 [attempt] 次重试的实际等待时长。
  ///
  /// [random] 返回 `[0,1)`，注入以便测试确定化。
  Duration delay(int attempt, double Function() random) {
    final c = cap(attempt);
    final floor = (c * jitterFloor).round();
    final span = c - floor;
    return Duration(milliseconds: floor + (span * random()).round());
  }

  static int _pow(int base, int exp) {
    var result = 1;
    for (var i = 0; i < exp; i++) {
      result *= base;
      if (result > 100000000) return 100000000;
    }
    return result;
  }
}

/// WebSocket 抽象，便于测试替换。
abstract class MuxSocket {
  Stream<String> get messages;
  Future<void> get ready;
  void send(String data);
  Future<void> close();
  int? get closeCode;
  String? get closeReason;
}

/// 建立一条物理 socket。
typedef MuxSocketFactory =
    Future<MuxSocket> Function(Uri uri, Map<String, String> headers);

/// 单条逻辑流的句柄。
class RemoteStream {
  RemoteStream._(this.streamId, this.endpoint);

  final String streamId;
  final String endpoint;

  final _controller = StreamController<StreamEvent>.broadcast();

  /// 下行事件流。订阅后即可收到 item/end/error。
  Stream<StreamEvent> get events => _controller.stream;

  bool _closed = false;
  bool get isClosed => _closed;

  void _emit(StreamEvent event) {
    if (_closed) return;
    _controller.add(event);
    if (event is StreamEnded || event is StreamFailed) {
      _closed = true;
    }
  }

  Future<void> _dispose() async {
    _closed = true;
    await _controller.close();
  }
}

/// mux 连接状态。
enum MuxState { idle, connecting, connected, reconnecting, closed }

/// Remote mux 客户端。
///
/// 用法：
/// ```dart
/// final mux = MuxClient(uri: ..., headers: ..., socketFactory: ...);
/// await mux.connect();
/// final events = mux.openStream(eventsEndpoint);
/// await for (final e in events.events) { ... }
/// ```
class MuxClient {
  MuxClient({
    required this.uri,
    required this.headers,
    required this.socketFactory,
    this.backoff = const BackoffPolicy(),
    this.maxAttempts,
    double Function()? random,
  }) : _random = random ?? _defaultRandom;

  final Uri uri;
  final Map<String, String> headers;
  final MuxSocketFactory socketFactory;
  final BackoffPolicy backoff;

  /// `null` 表示无限重试（官方行为：持续到恢复）。
  final int? maxAttempts;

  final double Function() _random;

  MuxSocket? _socket;
  StreamSubscription<String>? _sub;
  MuxState _state = MuxState.idle;
  final _stateController = StreamController<MuxState>.broadcast();
  final Map<String, RemoteStream> _streams = {};
  int _streamSeq = 0;
  Timer? _retryTimer;
  int _attempt = 0;
  bool _disposed = false;

  /// 连接状态变化。
  Stream<MuxState> get stateChanges => _stateController.stream;
  MuxState get state => _state;

  /// 当前是否可用。
  bool get isConnected => _state == MuxState.connected;

  /// 建立连接。
  ///
  /// **失败时抛出**：初版这里静默返回，调用方只看到 `isConnected == false`，
  /// 拿不到原因（实测表现为 UI 显示「mux 未连接」而无从排查）。
  /// 现在把首个物理连接的错误原样抛出；重连（[_scheduleRetry]）仍保持后台静默。
  Future<void> connect() async {
    if (_disposed) throw StateError('MuxClient is disposed');
    _setState(MuxState.connecting);
    await _open(firstAttempt: true);
  }

  /// 打开物理连接。
  ///
  /// [firstAttempt] 为 true 时把错误抛给 `connect()` 的调用方；
  /// 重连路径传 false，失败交给退避调度。
  Future<void> _open({bool firstAttempt = false}) async {
    try {
      final socket = await socketFactory(uri, headers);
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      await socket.ready;
      _sub = socket.messages.listen(
        _onMessage,
        onError: (Object _) => _onDisconnected(),
        onDone: _onDisconnected,
      );
      _attempt = 0;
      _setState(MuxState.connected);
    } catch (e) {
      // 首次连接失败：不排后台重试，把错误交给 connect() 的调用方。
      _onDisconnected(scheduleRetry: !firstAttempt);
      if (firstAttempt) rethrow;
    }
  }

  void _onMessage(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      // 非 JSON 帧直接丢弃：官方同样不做容错解析。
      return;
    }

    final ServerFrame frame;
    try {
      frame = ServerFrame.parse(decoded);
    } on ProtocolError {
      // 畸形帧使当前 generation 失效 —— 与官方行为一致。
      _onDisconnected();
      return;
    }

    final stream = _streams[frame.streamId];
    if (stream == null) return; // 未知 streamId：静默忽略（官方也会丢弃）

    switch (frame.type) {
      case FrameType.item:
        stream._emit(StreamItem(frame.value, hasValue: frame.hasValue));
      case FrameType.ready:
        stream._emit(StreamItem(frame.value, hasValue: true));
      case FrameType.end:
        stream._emit(const StreamEnded());
        unawaited(stream._dispose());
        _streams.remove(frame.streamId);
      case FrameType.error:
        stream._emit(StreamFailed(frame.error!));
        unawaited(stream._dispose());
        _streams.remove(frame.streamId);
      case FrameType.unknown:
        break;
    }
  }

  /// 处理连接断开。
  ///
  /// [scheduleRetry] 为 false 时**不调度重连** —— 用于首次 `connect()` 失败：
  /// 那时调用方会收到 rethrow，若再后台排一次重试，异常路径与重连路径会同时
  /// 持有连接意图，语义混乱。
  ///
  /// 注：曾经观察到「启动后出现 2 条 WS 握手」并据此怀疑双连接，后经
  /// `connect()`/`_open()` 调用计数与干净进程重启验证，**那 2 条来自未完全
  /// 退出的旧进程**，不是本模块的缺陷。此处保留该参数是为了让失败语义清晰，
  /// 不是为了修那个假象。
  void _onDisconnected({bool scheduleRetry = true}) {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    _socket = null;

    // 所有在途流随 socket 一起失效。
    for (final entry in _streams.entries.toList()) {
      entry.value._emit(
        const StreamFailed(
          RemoteError(code: 'gateway/carrier-lost', message: 'socket closed'),
        ),
      );
      unawaited(entry.value._dispose());
    }
    _streams.clear();

    if (scheduleRetry) _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _attempt++;
    final max = maxAttempts;
    if (max != null && _attempt > max) {
      _setState(MuxState.closed);
      return;
    }
    _setState(MuxState.reconnecting);
    final delay = backoff.delay(_attempt, _random);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_disposed) return;
      // 每次重试都换一条新 socket（官方行为）。
      _open();
    });
  }

  /// 打开一条逻辑流。
  ///
  /// 调用方负责在拿到 `ready`/首个 item 后自行判定流是否就绪。
  RemoteStream openStream(
    String endpoint, {
    Map<String, Object?> payload = const {},
    String? streamId,
  }) {
    if (!isConnected) {
      throw StateError('MuxClient is not connected (state=$_state)');
    }
    final id = streamId ?? 's${_streamSeq++}';
    if (_streams.containsKey(id)) {
      throw StateError('streamId "$id" is already open');
    }
    final stream = RemoteStream._(id, endpoint);
    _streams[id] = stream;
    _socket!.send(
      OpenFrame(streamId: id, endpoint: endpoint, payload: payload).encode(),
    );
    return stream;
  }

  /// 向一条流发送上行 item。
  void sendItem(String streamId, Object? value, {bool hasValue = true}) {
    if (!isConnected) throw StateError('MuxClient is not connected');
    _socket!.send(
      ItemFrame(streamId: streamId, value: value, hasValue: hasValue).encode(),
    );
  }

  /// 半关闭一条流的上行。
  void sendEnd(String streamId) {
    if (!isConnected) throw StateError('MuxClient is not connected');
    _socket!.send(EndFrame(streamId: streamId).encode());
  }

  /// 取消一条流。
  Future<void> cancelStream(String streamId) async {
    final stream = _streams.remove(streamId);
    if (stream == null) return;
    if (isConnected) {
      _socket!.send(CancelFrame(streamId: streamId).encode());
    }
    await stream._dispose();
  }

  void _setState(MuxState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _sub?.cancel();
    for (final s in _streams.values) {
      await s._dispose();
    }
    _streams.clear();
    await _socket?.close();
    await _stateController.close();
    _setState(MuxState.closed);
  }

  static double _defaultRandom() => DateTime.now().microsecondsSinceEpoch % 1000 / 1000.0;
}
