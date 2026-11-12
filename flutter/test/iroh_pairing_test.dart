import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/src/auth/pairing.dart';
import 'package:dsh_mobile/src/auth/pairing_flow.dart';
import 'package:dsh_mobile/src/auth/credential_store.dart';
import 'package:dsh_mobile/src/transport/unary.dart';

Map<String, Object?> descriptor() {
  final id = 'ab' * 32;
  final ca = base64Encode([0x30, 1, 0]);
  return {'version': 1, 'type': 'dsh-mobile-iroh-pairing', 'endpointId': id,
    'origin': 'https://${id.substring(0,32)}.${id.substring(32)}.iroh.localhost:3445',
    'localPort': 3445, 'irohCode': '123456',
    'gatewayToken': base64Url.encode(List.filled(32, 0)).replaceAll('=', ''),
    'caCertificate': ca, 'instanceId': sha256.convert(base64Decode(ca)).toString(),
    'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000};
}
class DeferredHttp implements HttpTransport {
  final response = Completer<({int statusCode, String body})>();
  @override
  Future<({int statusCode, String body})> post(Uri uri, String body,
      {required Map<String, String> headers, Duration? timeout}) => response.future;
}
void main() {
  test('iroh QR preserves logical origin and persists no one-time secrets', () {
    final d = PairingDescriptor.parse(jsonEncode(descriptor()));
    expect(d.iroh!.code, '123456');
    final c = DeviceCredential(origin: d.origin, deviceId: 'd', deviceToken: 't',
      instanceId: d.instanceId, transport: d.iroh!.metadata);
    final saved = jsonEncode(c.toJson());
    expect(saved, isNot(contains('irohCode')));
    expect(saved, isNot(contains('gatewayToken')));
    expect(DeviceCredential.fromJson(c.toJson()).transport!.origin, d.origin);
  });
  test('old LAN credential retains optional metadata compatibility', () {
    final c = DeviceCredential.fromJson({'origin': 'https://pc:3444',
      'deviceId': 'd', 'deviceToken': 't'});
    expect(c.transport, isNull);
    expect(c.toJson().containsKey('transport'), isFalse);
  });
  for (final field in ['version', 'origin', 'irohCode', 'localPort', 'instanceId']) {
    test('reject malformed $field before native networking', () {
      final input = descriptor();
      input[field] = field == 'version' ? 2 : field == 'localPort' ? 0 : 'bad';
      expect(() => PairingDescriptor.parse(jsonEncode(input)), throwsA(isA<PairingException>()));
    });
  }
  test('unknown and duplicate QR keys are rejected', () {
    final input = descriptor()..['unknown'] = true;
    expect(() => PairingDescriptor.parse(jsonEncode(input)), throwsA(isA<PairingException>()));
    final duplicate = jsonEncode(descriptor()).replaceFirst('{', '{"version":1,');
    expect(() => PairingDescriptor.parse(duplicate), throwsA(isA<PairingException>()));
  });
  test('cancelled late pairing result cannot save credentials', () async {
    final http = DeferredHttp();
    final store = MemoryCredentialStore();
    final flow = PairingFlow(store: store, transport: http, connectAfterPair: false);
    final running = flow.run('https://pc:3444/pair?token=once');
    await Future<void>.delayed(Duration.zero);
    await flow.cancel();
    http.response.complete((statusCode: 201, body: jsonEncode({'deviceId': 'd',
      'deviceToken': 't', 'sessionToken': 's', 'csrfToken': 'c'})));
    expect(await running, isA<PairingFailed>());
    expect(store.items, isEmpty);
  });
}
