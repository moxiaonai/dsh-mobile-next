/// 配对流程测试（不碰网络）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/auth/credential_store.dart';
import 'package:dsh_mobile/src/auth/pairing.dart';
import 'package:dsh_mobile/src/auth/pairing_flow.dart';
import 'package:dsh_mobile/src/transport/unary.dart';

/// 可控的假传输。
class FakeTransport implements HttpTransport {
  FakeTransport({this.code = 201, this.responseBody = '', this.throwError});

  final int code;
  final String responseBody;
  final Object? throwError;
  final List<Uri> calls = [];

  @override
  Future<({int statusCode, String body})> post(
    Uri uri,
    String body, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    calls.add(uri);
    if (throwError != null) throw throwError!;
    return (statusCode: code, body: responseBody);
  }
}

String okBody({String deviceId = 'dev-1', String token = 'dtok-1'}) =>
    '{"deviceId":"$deviceId","deviceToken":"$token",'
    '"deviceExpiresAt":1790000000000,"sessionToken":"stok-1",'
    '"csrfToken":"csrf-1","sessionExpiresAt":1790000000000,'
    '"instanceId":"inst-1"}';

const goodUrl = 'https://192.168.1.5:3443/mobile-access/pair'
    '#token=abc123&instance=inst-1';

void main() {
  group('PairingDescriptor.parse', () {
    test('解析 token 形式', () {
      final d = PairingDescriptor.parse(goodUrl);
      expect(d.token, 'abc123');
      expect(d.instanceId, 'inst-1');
      expect(d.origin.host, '192.168.1.5');
      expect(d.origin.port, 3443);
    });

    test('解析 key 形式', () {
      final d = PairingDescriptor.parse(
        'https://h:3443/mobile-access/pair#key=dsh1.inst-9.tok-9',
      );
      expect(d.token, 'tok-9');
      expect(d.instanceId, 'inst-9');
    });

    test('无 fragment 报错', () {
      expect(
        () => PairingDescriptor.parse('https://h:3443/pair'),
        throwsA(isA<PairingException>()),
      );
    });

    // ── 回归：插件生成的是 `?token=`（query），不是 `#token=` ──
    // 只认 fragment 会让「扫我们自己的码」直接失败。
    test('解析 query 形式（插件实际生成的载荷）', () {
      final d = PairingDescriptor.parse(
        'https://192.168.1.5:3444/mobile-access-next/pair?token=q-tok',
      );
      expect(d.token, 'q-tok');
      expect(d.origin.host, '192.168.1.5');
      expect(d.origin.port, 3444);
    });

    // ── 回归：origin 必须干净 ──
    // 旧实现用 `uri.replace(fragment:'', query:'')`，Uri 会留下 `?` 和 `#`，
    // origin 变成 `…/pair?#`。再拼一次就是 `##token=`，token 丢失，
    // 报错「pairing URL has no token」。
    test('origin 不含残留的 ? 与 #', () {
      final d = PairingDescriptor.parse(
        'https://h:3444/mobile-access-next/pair?token=t1&instance=i1',
      );
      expect(d.origin.toString(), 'https://h:3444');
      expect(d.origin.hasQuery, isFalse);
      expect(d.origin.hasFragment, isFalse);
    });

    test('query 形式的描述符可再次解析（往返不丢 token）', () {
      final first = PairingDescriptor.parse(
        'https://h:3444/mobile-access-next/pair?token=round-trip',
      );
      // 用干净 origin 重建，再解析一次
      final rebuilt = Uri.parse(
        '${first.origin}/mobile-access-next/pair?token=${first.token}',
      );
      final second = PairingDescriptor.parse(rebuilt.toString());
      expect(second.token, 'round-trip');
      expect(second.origin.toString(), first.origin.toString());
    });

    test('非 URL 报错', () {
      expect(
        () => PairingDescriptor.parse('not a url'),
        throwsA(isA<PairingException>()),
      );
    });

    test('拒绝非 http(s) scheme', () {
      expect(
        () => PairingDescriptor.parse('ftp://h/pair#token=x'),
        throwsA(isA<PairingException>()),
      );
    });
  });

  group('PairingFlow', () {
    test('坏链接 → badDescriptor', () async {
      final flow = PairingFlow(
        store: MemoryCredentialStore(),
        transport: FakeTransport(),
        connectAfterPair: false,
      );
      final out = await flow.run('garbage');
      expect(out, isA<PairingFailed>());
      expect((out as PairingFailed).failure, PairingFailure.badDescriptor);
    });

    test('401 → expiredOrInvalid', () async {
      final flow = PairingFlow(
        store: MemoryCredentialStore(),
        transport: FakeTransport(code: 401, responseBody: 'nope'),
        connectAfterPair: false,
      );
      final out = await flow.run(goodUrl);
      expect(
        (out as PairingFailed).failure,
        PairingFailure.expiredOrInvalid,
      );
    });

    test('403 → rejected', () async {
      final flow = PairingFlow(
        store: MemoryCredentialStore(),
        transport: FakeTransport(code: 403, responseBody: 'no'),
        connectAfterPair: false,
      );
      final out = await flow.run(goodUrl);
      expect((out as PairingFailed).failure, PairingFailure.rejected);
    });

    test('连接被拒 → network', () async {
      final flow = PairingFlow(
        store: MemoryCredentialStore(),
        transport: FakeTransport(
          throwError: const SocketException('Connection refused'),
        ),
        connectAfterPair: false,
      );
      final out = await flow.run(goodUrl);
      expect((out as PairingFailed).failure, PairingFailure.network);
    });

    test('成功时保存凭据', () async {
      final store = MemoryCredentialStore();
      final flow = PairingFlow(
        store: store,
        transport: FakeTransport(responseBody: okBody()),
        connectAfterPair: false,
      );
      final out = await flow.run(goodUrl, label: '我的电脑');

      expect(out, isA<PairingSucceeded>());
      final ok = out as PairingSucceeded;
      expect(ok.credential.deviceId, 'dev-1');
      expect(ok.credential.deviceToken, 'dtok-1');
      expect(ok.credential.instanceId, 'inst-1');
      expect(ok.credential.label, '我的电脑');

      final saved = await store.loadAll();
      expect(saved, hasLength(1));
      expect(saved.single.deviceToken, 'dtok-1');
    });

    test('重复配对同一台电脑只保留一条', () async {
      final store = MemoryCredentialStore();
      final flow = PairingFlow(
        store: store,
        transport: FakeTransport(responseBody: okBody()),
        connectAfterPair: false,
      );
      await flow.run(goodUrl);
      await flow.run(goodUrl);
      expect((await store.loadAll()), hasLength(1));
    });

    test('配对请求发到正确端点', () async {
      final transport = FakeTransport(responseBody: okBody());
      final flow = PairingFlow(
        store: MemoryCredentialStore(),
        transport: transport,
        connectAfterPair: false,
      );
      await flow.run(goodUrl);
      expect(transport.calls, hasLength(1));
      // 端点必须与 `dsh-mobile-next` 插件一致（不是参考实现的 native-pair）
      expect(
        transport.calls.single.path,
        '/mobile-access-next/pair',
      );
    });
  });

  group('CredentialStore', () {
    test('save / load / remove / clear', () async {
      final store = MemoryCredentialStore();
      final c1 = DeviceCredential(
        origin: Uri.parse('https://a:1'),
        deviceId: 'd1',
        deviceToken: 't1',
        instanceId: 'i1',
      );
      final c2 = DeviceCredential(
        origin: Uri.parse('https://b:2'),
        deviceId: 'd2',
        deviceToken: 't2',
        instanceId: 'i2',
      );

      await store.save(c1);
      await store.save(c2);
      expect((await store.loadAll()), hasLength(2));

      await store.remove(c1);
      final left = await store.loadAll();
      expect(left, hasLength(1));
      expect(left.single.deviceId, 'd2');

      await store.clear();
      expect((await store.loadAll()), isEmpty);
    });

    test('同 origin+instance 覆盖', () async {
      final store = MemoryCredentialStore();
      const origin = 'https://a:1';
      await store.save(
        DeviceCredential(
          origin: Uri.parse(origin),
          deviceId: 'd1',
          deviceToken: 'old',
          instanceId: 'i1',
        ),
      );
      await store.save(
        DeviceCredential(
          origin: Uri.parse(origin),
          deviceId: 'd1',
          deviceToken: 'new',
          instanceId: 'i1',
        ),
      );
      final all = await store.loadAll();
      expect(all, hasLength(1));
      expect(all.single.deviceToken, 'new');
    });
  });
}
