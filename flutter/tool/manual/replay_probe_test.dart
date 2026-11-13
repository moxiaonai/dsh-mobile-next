/// 探测：新的 $events 订阅者能否收到「已挂起」的审批（replay 语义）。
library;
// 手动工具：只在本机跑，允许直接 print 结果。
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/approvals.dart';
import 'package:dsh_mobile/src/transport/io_transport.dart';
import 'package:dsh_mobile/src/transport/mux.dart';

/// 复用 trigger 里的配对逻辑（临时复制，手动工具不追求复用）。
Future<String> pairedCookie(Uri gateway) async {
  final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
  Future<HttpClientResponse> post(Uri uri, String body) async {
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.write(body);
    return req.close();
  }

  final res = await post(
    Uri.parse('http://127.0.0.1:52883/mobile-access-next/pairing'),
    '{}',
  );
  final text = await res.transform(utf8.decoder).join();
  final token = RegExp(r'token=([A-Za-z0-9_-]+)').firstMatch(text)?.group(1);
  if (token == null) throw StateError('no token: $text');
  final pair = await post(
    gateway.replace(path: '/mobile-access-next/pair'),
    jsonEncode({'token': token, 'label': 'replay-probe'}),
  );
  final body = jsonDecode(await pair.transform(utf8.decoder).join())
      as Map<String, Object?>;
  client.close();
  return 'dsh-mobile-next-session=${body['sessionToken']}';
}

void main() {
  test('replay 探测', () async {
    HttpOverrides.global = null;
    final uri = Uri.parse('https://192.168.0.102:3444');
    final cookie = await pairedCookie(uri);
    final ca = File('/Users/wuwenjing/.dsh/mobile-access-next/tls/ca.pem').readAsStringSync();
    final mux = MuxClient(
      uri: uri.replace(scheme: 'wss', path: '/api/remote.mux'),
      headers: {'cookie': cookie, 'host': '${uri.host}:${uri.port}'},
      socketFactory: ioMuxSocketFactory(trustedCaPem: ca),
    );
    await mux.connect();
    final ev = mux.openStream(r'$events', payload: const {'args': <String, Object?>{}});
    var frames = 0;
    var approvals = 0;
    ev.events.listen((e) {
      if (e is! StreamItem || e.value is! Map) return;
      frames++;
      final frame = (e.value as Map).cast<String, Object?>();
      print('FRAME ${frame['type']} ${frame['event'] ?? ''}');
      if (WaterfallExtractor.approval(frame) != null) approvals++;
    });
    await Future<void>.delayed(const Duration(seconds: 8));
    print('FRAMES $frames APPROVALS $approvals');
    await mux.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));
}
