/// 协议层单元测试。
///
/// 这些测试**不需要 Flutter 运行时**，用纯 Dart 即可跑：
///   dart test
///
/// 覆盖重点是官方 `exactKeys` 的严格性 —— 放宽校验会让客户端在协议演进时
/// 静默错位，比直接失败更难排查。
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'package:dsh_mobile/src/protocol/frames.dart';
import 'package:dsh_mobile/src/transport/mux.dart';

void main() {
  group('ServerFrame.parse', () {
    test('parses an item frame with value', () {
      final f = ServerFrame.parse({'type': 'item', 'streamId': 's1', 'value': 42});
      expect(f.type, FrameType.item);
      expect(f.streamId, 's1');
      expect(f.value, 42);
      expect(f.hasValue, isTrue);
    });

    test('parses an item frame without value', () {
      final f = ServerFrame.parse({'type': 'item', 'streamId': 's1'});
      expect(f.type, FrameType.item);
      expect(f.hasValue, isFalse);
    });

    test('distinguishes null value from absent value', () {
      final withNull = ServerFrame.parse({
        'type': 'item',
        'streamId': 's1',
        'value': null,
      });
      expect(withNull.hasValue, isTrue);
      expect(withNull.value, isNull);

      final absent = ServerFrame.parse({'type': 'item', 'streamId': 's1'});
      expect(absent.hasValue, isFalse);
    });

    test('parses an end frame', () {
      final f = ServerFrame.parse({'type': 'end', 'streamId': 's1'});
      expect(f.type, FrameType.end);
    });

    test('parses an error frame', () {
      final f = ServerFrame.parse({
        'type': 'error',
        'streamId': 's1',
        'error': {'code': 'gateway/cancelled', 'message': 'boom', 'details': {}},
      });
      expect(f.type, FrameType.error);
      expect(f.error!.code, 'gateway/cancelled');
      expect(f.error!.message, 'boom');
    });

    test('rejects extra keys (official exactKeys behaviour)', () {
      expect(
        () => ServerFrame.parse({
          'type': 'end',
          'streamId': 's1',
          'unexpected': true,
        }),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('rejects error frame missing details', () {
      expect(
        () => ServerFrame.parse({
          'type': 'error',
          'streamId': 's1',
          'error': {'code': 'x', 'message': 'y'},
        }),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('rejects empty streamId', () {
      expect(
        () => ServerFrame.parse({'type': 'end', 'streamId': ''}),
        throwsA(isA<ProtocolError>()),
      );
    });

    test('rejects non-object frames', () {
      expect(() => ServerFrame.parse(<Object?>[]),
          throwsA(isA<ProtocolError>()));
      expect(() => ServerFrame.parse('x'), throwsA(isA<ProtocolError>()));
    });

    test('tolerates unknown frame types', () {
      final f = ServerFrame.parse({'type': 'future-thing', 'streamId': 's1'});
      expect(f.type, FrameType.unknown);
    });
  });

  group('ClientFrame encoding', () {
    test('open frame has exactly the four official keys', () {
      final json = OpenFrame(
        streamId: 's1',
        endpoint: r'$events',
        payload: const {'args': <String, Object?>{}},
      ).toJson();
      expect(json.keys.toSet(), {'type', 'streamId', 'endpoint', 'payload'});
      expect(jsonDecode(jsonEncode(json)), json);
    });

    test('item frame omits value when hasValue is false', () {
      final json = const ItemFrame(streamId: 's1', hasValue: false).toJson();
      expect(json.containsKey('value'), isFalse);
      expect(json.keys.toSet(), {'type', 'streamId'});
    });

    test('item frame keeps null value when hasValue is true', () {
      final json = const ItemFrame(streamId: 's1', value: null).toJson();
      expect(json.containsKey('value'), isTrue);
      expect(json['value'], isNull);
    });

    test('end and cancel frames carry only type and streamId', () {
      expect(const EndFrame(streamId: 's1').toJson().keys.toSet(),
          {'type', 'streamId'});
      expect(const CancelFrame(streamId: 's1').toJson().keys.toSet(),
          {'type', 'streamId'});
    });
  });

  group('BackoffPolicy', () {
    const policy = BackoffPolicy();

    test('cap follows the documented ladder', () {
      // 500, 1000, 2000, 4000, 8000, 10000, then 10000 held
      expect(policy.cap(1), 500);
      expect(policy.cap(2), 1000);
      expect(policy.cap(3), 2000);
      expect(policy.cap(4), 4000);
      expect(policy.cap(5), 8000);
      expect(policy.cap(6), 10000);
      expect(policy.cap(7), 10000);
      expect(policy.cap(20), 10000);
    });

    test('delay stays inside the documented cap/2 … cap jitter window', () {
      for (var attempt = 1; attempt <= 8; attempt++) {
        final cap = policy.cap(attempt);
        final floor = cap ~/ 2;
        // 边界值必须落在窗口内 —— 断言 delay == cap 会让测试在真机上飘。
        final low = policy.delay(attempt, () => 0.0).inMilliseconds;
        final high = policy.delay(attempt, () => 0.999999).inMilliseconds;
        expect(low, greaterThanOrEqualTo(floor));
        expect(low, lessThanOrEqualTo(cap));
        expect(high, greaterThanOrEqualTo(floor));
        expect(high, lessThanOrEqualTo(cap));
      }
    });
  });
}
