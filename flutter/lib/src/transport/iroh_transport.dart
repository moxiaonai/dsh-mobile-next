/// Owned native QUIC carrier; HTTP/WS retain the pinned logical HTTPS origin.
library;

import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../auth/iroh_descriptor.dart';
import 'io_transport.dart';
import 'mux.dart';

class IrohTransport {
  IrohTransport._(this.requestId, this.metadata);
  static const channel = MethodChannel('dsh_mobile/iroh');
  static int _nextId = DateTime.now().microsecondsSinceEpoch;
  static final Map<String, IrohTransport> _active = {};

  /// Verify the actual WebView leaf certificate, not an issuer-name claim.
  static Future<bool> verifyWebViewCertificate(
    Uri origin,
    String host,
    List<int> der,
  ) async {
    final owner = _active[origin.toString()];
    if (owner == null || owner._closed || host != owner.metadata.origin.host) {
      return false;
    }
    try {
      return await channel.invokeMethod<bool>('verifyCertificate', {
                'requestId': owner.requestId,
                'host': host,
                'certificate': Uint8List.fromList(der),
                'caCertificate': owner.metadata.caCertificate,
              }) ==
              true &&
          !owner._closed;
    } on PlatformException {
      return false;
    }
  }

  final int requestId;
  final IrohMetadata metadata;
  bool _closed = false;
  HttpClient? _client;
  late final IoHttpTransport http = IoHttpTransport(client: client);
  HttpClient get client => _client ??= _buildClient();
  MuxSocketFactory get socketFactory =>
      (uri, headers) => IoMuxSocket.connect(uri, headers, client: client);

  static IrohTransport reserve(IrohMetadata metadata) =>
      IrohTransport._(++_nextId, metadata);

  Future<void> connect({String? code}) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('iroh currently requires Android');
    }
    if (_closed) throw StateError('transport cancelled');
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('connect', {
        'requestId': requestId,
        'endpointId': metadata.endpointId,
        'localPort': metadata.localPort,
        'code': code ?? '',
      });
      if (_closed ||
          result?['peerId'] != metadata.endpointId ||
          result?['localPort'] != metadata.localPort) {
        throw StateError('iroh owner or endpoint mismatch');
      }
      _active[metadata.origin.toString()] = this;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  HttpClient _buildClient() {
    if (_closed) throw StateError('transport closed');
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(metadata.caPem));
    final client = HttpClient(context: context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (_closed ||
          proxyHost != null ||
          uri.host != metadata.origin.host ||
          uri.port != metadata.localPort ||
          (uri.scheme != 'https' && uri.scheme != 'wss')) {
        throw StateError('iroh transport rejected non-paired origin');
      }
      return connectPinnedTls(uri.host, metadata.localPort, context);
    };
    return client;
  }

  /// HttpClient custom connectionFactory does NOT add TLS for DIRECT sockets.
  /// Wrap the loopback TCP explicitly, using the logical host for SNI and SAN.
  static Future<ConnectionTask<Socket>> connectPinnedTls(
    String logicalHost, int loopbackPort, SecurityContext context,
  ) async {
    final tcp = await Socket.startConnect(InternetAddress.loopbackIPv4, loopbackPort);
    Socket? connected;
    var cancelled = false;
    final secure = () async {
      final raw = await tcp.socket;
      connected = raw;
      if (cancelled) { raw.destroy(); throw StateError('TLS connect cancelled'); }
      try {
        final tls = await SecureSocket.secure(raw, host: logicalHost, context: context);
        connected = tls;
        if (cancelled) { tls.destroy(); throw StateError('TLS connect cancelled'); }
        return tls;
      } catch (_) { raw.destroy(); rethrow; }
    }();
    return ConnectionTask.fromSocket<Socket>(secure, () {
      cancelled = true;
      tcp.cancel();
      connected?.destroy();
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (identical(_active[metadata.origin.toString()], this)) {
      _active.remove(metadata.origin.toString());
    }
    _client?.close(force: true);
    if (Platform.isAndroid) {
      try {
        await channel.invokeMethod<void>('close', {'requestId': requestId});
      } on PlatformException {
        /* Missing/failed native owner cannot resurrect. */
      }
    }
  }
}
