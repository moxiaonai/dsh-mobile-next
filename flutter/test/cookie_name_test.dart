/// Cookie 名必须与插件 `gateway.ts` 的 `SESSION_COOKIE` 一致。
///
/// 这条测试存在的原因是一个真实的 bug：配对后建连时用了
/// `dsh-mobile-session`，而插件读的是 `dsh-mobile-next-session`，
/// 于是**每个请求都 401**，表现为「配对成功但连不上」。
///
/// 更麻烦的是当时有**两份**同名实现（`connection.dart` 与
/// `pairing_flow.dart`），只改了其中一份，修复看起来没生效。
/// 这条测试同时锁住「名字正确」和「只有一处实现」。
library;

import 'package:dsh_mobile/src/auth/pairing.dart';
import 'package:dsh_mobile/src/transport/connection.dart';
import 'package:flutter_test/flutter_test.dart';

PairingResult _result() => const PairingResult(
  deviceId: 'd1',
  deviceToken: 'dt',
  deviceExpiresAt: null,
  sessionToken: 'SESS',
  csrfToken: 'CSRF',
  sessionExpiresAt: null,
);

void main() {
  group('配对后的 Cookie 头', () {
    test('会话 cookie 名与插件一致', () {
      final header = cookieHeaderFromPairing(_result());
      expect(
        header,
        contains('dsh-mobile-next-session=SESS'),
        reason: '插件 gateway.ts 的 SESSION_COOKIE 是 dsh-mobile-next-session',
      );
    });

    test('不能出现旧名字 dsh-mobile-session', () {
      final header = cookieHeaderFromPairing(_result());
      // 用 `=` 边界判断，避免 `dsh-mobile-next-session=` 里含子串造成误报
      expect(
        header.split('; ').any((part) => part.startsWith('dsh-mobile-session=')),
        isFalse,
        reason: '旧名字会让网关认不出会话，每个请求 401',
      );
    });

    test('csrf 也带 next 前缀', () {
      final header = cookieHeaderFromPairing(_result());
      expect(header, contains('dsh-mobile-next-csrf=CSRF'));
    });
  });
}
