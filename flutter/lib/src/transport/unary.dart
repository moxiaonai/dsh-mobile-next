/// Unary RPC 载具：`POST /api/<endpoint>`。
///
/// 这是**双载具**之一（见 `docs/60-protocol-feasibility.md` §5.1）：
/// unary 端点（`session/list`、`session/prompt`、`session/state`…）
/// **不能**走 `/api/remote.mux`，会得到 `gateway/signature-invalid`。
///
/// 信封格式由 spike 实测确认，并在 `dsh-client-connection/lib/index.js`
/// 中核对过 `client-request` / `server-response` / `rpcId` 三个关键字。
library;

import 'dart:async';
import 'dart:convert';

import '../protocol/frames.dart' show RemoteError;

/// 一次 unary 调用的失败。
class UnaryException implements Exception {
  const UnaryException(this.message, {this.statusCode, this.remote});

  final String message;
  final int? statusCode;

  /// 服务端返回的结构化错误（若有）。
  final RemoteError? remote;

  @override
  String toString() =>
      'UnaryException(${statusCode ?? '-'}): $message${remote == null ? '' : ' [$remote]'}';
}

/// 传输抽象。抽出来是为了让 unary 层可单测，不绑死 `HttpClient`。
abstract class HttpTransport {
  /// 发起一次 POST，返回 `(statusCode, body)`。
  Future<({int statusCode, String body})> post(
    Uri uri,
    String body, {
    required Map<String, String> headers,
    Duration? timeout,
  });
}

/// Unary RPC 客户端。
class UnaryClient {
  UnaryClient({
    required this.origin,
    required this.transport,
    required this.cookieHeader,
    this.timeout = const Duration(seconds: 30),
  });

  /// 形如 `https://192.168.1.10:3443`（无尾斜杠）。
  final Uri origin;
  final HttpTransport transport;

  /// `Cookie` 头内容，例如 `dsh-auth-xxx=v1.…`。
  final String cookieHeader;

  final Duration timeout;

  /// 调用一个 unary 端点。
  ///
  /// [args] 会作为 `payload.args` 发送。成功时返回 `result.value`，
  /// 失败时抛 [UnaryException]。
  Future<Object?> call(
    String endpoint, {
    Map<String, Object?> args = const {},
    Duration? timeoutOverride,
  }) async {
    final rpcId = _newRpcId();
    final uri = origin.replace(
      path: '/api/$endpoint',
      query: null,
      fragment: null,
    );
    final body = jsonEncode({
      'type': 'client-request',
      'rpcId': rpcId,
      'method': endpoint,
      'payload': {'args': args},
    });

    final response = await transport.post(
      uri,
      body,
      headers: {
        'content-type': 'application/json',
        'cookie': cookieHeader,
      },
      timeout: timeoutOverride ?? timeout,
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnaryException(
        'HTTP ${response.statusCode} from /api/$endpoint: '
        '${_truncate(response.body)}',
        statusCode: response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw UnaryException('response is not JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const UnaryException('response envelope is not an object');
    }
    final envelope = decoded.cast<String, Object?>();

    if (envelope['type'] != 'server-response') {
      throw UnaryException(
        'unexpected envelope type "${envelope['type']}" '
        '(expected server-response)',
      );
    }
    // rpcId 必须回显一致：不一致说明响应错配，不能当成成功。
    if (envelope['rpcId'] != rpcId) {
      throw UnaryException(
        'rpcId mismatch: sent $rpcId, got ${envelope['rpcId']}',
      );
    }

    final result = envelope['result'];
    if (result is! Map) {
      throw const UnaryException('envelope.result is not an object');
    }
    final rm = result.cast<String, Object?>();
    if (rm['ok'] != true) {
      final err = rm['error'];
      if (err is Map) {
        final em = err.cast<String, Object?>();
        final remote = RemoteError(
          code: em['code'] as String? ?? 'unknown',
          message: em['message'] as String? ?? '',
          details: em['details'],
        );
        throw UnaryException(
          '$endpoint failed: ${remote.code}',
          remote: remote,
        );
      }
      throw UnaryException('$endpoint failed: ${_truncate(jsonEncode(rm))}');
    }
    return rm['value'];
  }

  static String _truncate(String s, [int max = 300]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  static int _rpcCounter = 0;

  /// 生成 rpcId。不用 `dart:math` 的随机数是为了让它在测试里可预测地递增，
  /// 同时保留时间前缀以免跨进程碰撞。
  static String _newRpcId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final seq = (_rpcCounter++).toRadixString(36);
    return 'dshm-$now-$seq';
  }
}
