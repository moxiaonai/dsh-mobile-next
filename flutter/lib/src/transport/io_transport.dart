/// 平台适配：把 `dart:io` / `dart:html` 的具体实现注入到传输抽象里。
///
/// 传输层本身只依赖 [HttpTransport] 与 [MuxSocket] 两个抽象，
/// 因此可以在纯 Dart VM 下跑单测，不必启动 Flutter 或模拟器。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'mux.dart';
import 'unary.dart';

/// 基于 `dart:io` 的 HTTP 实现（移动端 / 桌面 / VM 测试均可用）。
///
/// ## 私有 CA 固定
///
/// 局域网网关用**自签私有 CA**。系统信任链里没有它，因此默认的
/// `HttpClient` 会报 `CERTIFICATE_VERIFY_FAILED`（实测）。
///
/// 两种做法：
/// - [trustedCaPem]：给出 CA 的 PEM 内容，用 `SecurityContext` 信任它
/// - [allowBadCertificateForTesting]：**仅测试**，跳过校验
///
/// 生产必须用前者：跳过校验等于没有 TLS。
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({
    HttpClient? client,
    String? trustedCaPem,
    bool allowBadCertificateForTesting = false,
  }) : _client = client ?? _buildClient(trustedCaPem, allowBadCertificateForTesting);

  /// 用给定私有 CA 建一个只信任它的 HttpClient。
  ///
  /// 供 WS 握手复用，保证 unary 与 mux 两条载具的信任策略一致。
  static HttpClient buildClientFor(String caPem) => _buildClient(caPem, false);

  static HttpClient _buildClient(String? caPem, bool allowBad) {
    if (allowBad) {
      return HttpClient()..badCertificateCallback = (_, _, _) => true;
    }
    if (caPem == null) return HttpClient();

    // 用私有 CA 建 SecurityContext，只信任它（不叠加系统根）
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(caPem));
    return HttpClient(context: context);
  }

  final HttpClient _client;

  @override
  Future<({int statusCode, String body})> post(
    Uri uri,
    String body, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    final request = await _client.postUrl(uri);
    headers.forEach(request.headers.set);
    final bytes = utf8.encode(body);
    request.headers.contentLength = bytes.length;
    request.add(bytes);

    final future = request.close();
    final response = timeout == null ? await future : await future.timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    return (statusCode: response.statusCode, body: text);
  }

  void close() => _client.close(force: true);
}

/// 基于 `dart:io` 的 WebSocket 实现。
class IoMuxSocket implements MuxSocket {
  IoMuxSocket._(this._ws, this._ready);

  final WebSocket _ws;
  final Future<void> _ready;

  @override
  Stream<String> get messages => _ws.map((data) => data as String);

  @override
  Future<void> get ready => _ready;

  @override
  void send(String data) => _ws.add(data);

  @override
  Future<void> close() => _ws.close();

  @override
  int? get closeCode => _ws.closeCode;

  @override
  String? get closeReason => _ws.closeReason;

  /// 建立连接。[headers] 会被作为握手请求头（含 `cookie`）。
  ///
  /// [client] 用于固定私有 CA：网关证书不是系统信任链签发的，
  /// 不传它会在 WS 握手阶段直接失败（与 unary 请求同一个原因）。
  static Future<MuxSocket> connect(
    Uri uri,
    Map<String, String> headers, {
    HttpClient? client,
  }) async {
    // ⚠ 必须加超时：`WebSocket.connect` 本身**没有超时**。
    // 手机连不上电脑（不在同一 Wi-Fi、IP 变了、防火墙拦了）时，
    // 这里会无限挂起 —— 用户看到的就是「一直转圈」。
    // 实测：真机上服务端已配对成功，App 却永远停在连接中。
    final ws = await awaitOwnedSocket<WebSocket>(
      WebSocket.connect(uri.toString(), headers: headers, customClient: client),
      timeout: const Duration(seconds: 10),
      close: (ws) async { await ws.close(); },
    );
    return IoMuxSocket._(ws, Future<void>.value());
  }
}

/// A timeout does not cancel an underlying connect Future. Dispose any socket
/// that arrives after ownership expired; its late errors are consumed as well.
Future<T> awaitOwnedSocket<T>(Future<T> pending, {
  required Duration timeout,
  required Future<void> Function(T) close,
}) {
  var expired = false;
  final guarded = pending.then((socket) async {
    if (expired) {
      await close(socket);
      throw StateError('late socket disposed');
    }
    return socket;
  });
  return guarded.timeout(timeout, onTimeout: () {
    expired = true;
    throw TimeoutException('WebSocket handshake timed out', timeout);
  });
}

/// 便捷工厂，供 [DshConnection.connect] 使用。
///
/// [trustedCaPem] 给出时，WS 握手也固定该私有 CA（与 unary 请求一致）。
MuxSocketFactory ioMuxSocketFactory({String? trustedCaPem}) {
  final client = trustedCaPem == null
      ? null
      : IoHttpTransport.buildClientFor(trustedCaPem);
  return (uri, headers) =>
      IoMuxSocket.connect(uri, headers, client: client);
}


/// 从打包进 APK 的 `assets/ca.pem` 读出私有 CA。
///
/// ## 为什么需要它
///
/// 网关用的是插件自签的私有 CA，系统信任链里没有它。不固定 CA 的话，
/// 真机连 `https://<电脑IP>:3444` 会在 TLS 握手阶段直接失败
/// （`HandshakeException`），症状是「连接中…」转圈后报网络错误。
///
/// ## 局限（必须知道）
///
/// CA 是**每台电脑各生成一份**的，打进 APK 意味着这个包只信任
/// 「打包时那台电脑」。换电脑需要重新打包，或改成由配对二维码
/// 携带 CA 指纹再动态固定。
Future<String?> loadBundledCaPem() async {
  try {
    final data = await rootBundle.load('assets/ca.pem');
    return utf8.decode(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}
