/// 手动验收用：在真实网关上触发一条待审批，留给手机端点掉。
///
/// 跑法（不进默认 test 套件）：
///   flutter test tool/manual/trigger_approval_test.dart
///
/// 注意：flutter_test 默认把所有 HTTP 请求替换成 400 响应，
/// 这里把 HttpOverrides 清掉才能连真机网关。
library;
// 手动工具：只在本机跑，允许直接 print 结果。
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/approvals.dart';
import 'package:dsh_mobile/src/transport/io_transport.dart';
import 'package:dsh_mobile/src/transport/mux.dart';
import 'package:dsh_mobile/src/transport/unary.dart';

const origin = 'https://192.168.0.102:3444';

const adminBase = 'http://127.0.0.1:52883';

/// 走真实配对链路拿设备会话 cookie：
/// 管理端点签一次性 token → 网关 /pair 换 session cookie。
///
/// 不走浏览器 cookie：网关只认「已配对设备」的会话（access.authorize）。
Future<String> _pairedCookie(Uri gateway) async {
  final client = HttpClient()..badCertificateCallback = (_, _, _) => true;

  Future<HttpClientResponse> post(Uri uri, String body) async {
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.write(body);
    return req.close();
  }

  // ① 管理端点（仅回环可调）签一次性配对 token
  final pairingRes = await post(
    Uri.parse('$adminBase/mobile-access-next/pairing'),
    '{}',
  );
  final pairingBody = await pairingRes.transform(utf8.decoder).join();
  final token = RegExp(r'token=([A-Za-z0-9_-]+)')
      .firstMatch(pairingBody)
      ?.group(1);
  if (token == null) {
    throw StateError('没有拿到配对 token：$pairingBody');
  }

  // ② 网关 /pair 换设备会话
  final pairRes = await post(
    gateway.replace(path: '/mobile-access-next/pair'),
    jsonEncode({'token': token, 'label': 'approval-probe'}),
  );
  if (pairRes.statusCode != 200 && pairRes.statusCode != 201) {
    throw StateError('配对失败 ${pairRes.statusCode}: '
        '${await pairRes.transform(utf8.decoder).join()}');
  }
  final raw = await pairRes.transform(utf8.decoder).join();
  final body = jsonDecode(raw) as Map<String, Object?>;
  final sessionToken = body['sessionToken'];
  if (sessionToken is! String) {
    throw StateError('配对成功但没有 sessionToken：$raw');
  }
  client.close();
  return 'dsh-mobile-next-session=$sessionToken';
}

void main() {
  test('触发一条真实审批并保留', () async {
    HttpOverrides.global = null; // 允许真实网络（默认被 flutter_test 拦掉）
    final uri = Uri.parse(origin);
    final cookie = await _pairedCookie(uri);
    print('已配对，拿到设备会话');
    final ca = File('/Users/wuwenjing/.dsh/mobile-access-next/tls/ca.pem').readAsStringSync();
    final auth = '${uri.host}:${uri.port}';

    final u = UnaryClient(
      origin: uri,
      transport: IoHttpTransport(trustedCaPem: ca),
      cookieHeader: cookie,
    );
    final mux = MuxClient(
      uri: uri.replace(scheme: 'wss', path: '/api/remote.mux'),
      headers: {'cookie': cookie, 'host': auth},
      socketFactory: ioMuxSocketFactory(trustedCaPem: ca),
    );
    await mux.connect();

    final ev = mux.openStream(r'$events', payload: const {'args': <String, Object?>{}});
    PendingApproval? found;
    String? target;
    final ready = Completer<void>();
    ev.events.listen((e) {
      if (e is! StreamItem || e.value is! Map) return;
      final frame = (e.value as Map).cast<String, Object?>();
      if (WaterfallExtractor.clientIdOf(frame) != null) {
        if (!ready.isCompleted) ready.complete();
        return;
      }
      final ap = WaterfallExtractor.approval(frame);
      if (ap == null) return;
      if (target != null && ap.sessionId != target) return;
      found ??= ap;
      print('APPROVAL ${ap.toolName} ${ap.callId} :: ${ap.localizedReason()}');
    });
    await ready.future.timeout(const Duration(seconds: 15));

    final created = await u.call('session/create', args: {'request': {'cwd': '/tmp'}});
    final sid = (created as Map)['sessionId'] as String;
    target = sid;
    print('SESSION $sid');

    final follow = mux.openStream('session/follow', payload: {
      'args': {'request': {'sessionId': sid, 'activate': true}},
    });
    await follow.events.first.timeout(const Duration(seconds: 15));

    await u.call('session/prompt', args: {
      'request': {
        'requestId': 'apv-${DateTime.now().microsecondsSinceEpoch}',
        'sessionId': sid,
        'mode': 'queue',
        'content': [
          {
            'type': 'text',
            'text': 'Run this exact bash command: echo approval-probe > /etc/dsh-approval-probe.txt. Do nothing else.',
          },
        ],
      },
    });

    for (var i = 0; i < 40 && found == null; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    print('TRIGGERED ${found != null}');
    expect(found, isNotNull, reason: '该会话可能被设为 never-ask，审批不会出现');
    // 保持订阅存活：事件流一断，服务端会把这个 waterfall 结算掉，
    // 手机端就再也看不到这条审批了。留 90 秒给手机截图/点按。
    print('HOLD 90s');
    await Future<void>.delayed(const Duration(seconds: 90));
    await mux.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));

}
