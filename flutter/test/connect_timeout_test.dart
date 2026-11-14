/// 连接路径必须有超时。
///
/// 起因是一个真机 bug：服务端已配对成功（面板里能看到设备、最近连接「刚刚」），
/// App 却永远停在「尚未配对」转圈。根因是 `WebSocket.connect` **没有超时**，
/// 手机连不上电脑时会无限挂起，用户只能看到转圈。
///
/// 这里用静态检查锁住「不许出现无超时的 WebSocket.connect」，
/// 因为这类问题在单测里很难复现（要真的让 TCP 挂住）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('连接超时', () {
    test('WebSocket.connect 必须带 timeout', () {
      final source = File('lib/src/transport/io_transport.dart').readAsStringSync();
      final index = source.indexOf('WebSocket.connect');
      expect(index, greaterThan(0), reason: '应能在 io_transport 里找到 WebSocket.connect');

      // 取调用点之后的一段，检查是否跟了 .timeout 或 awaitOwnedSocket(timeout:)
      final after = source.substring(index);
      final window = after.length > 600 ? after.substring(0, 600) : after;
      expect(
        window.contains('.timeout(') || window.contains('awaitOwnedSocket<'),
        isTrue,
        reason: 'WebSocket.connect 必须有超时（.timeout 或 awaitOwnedSocket(timeout:)），'
            '否则网络不通时会无限挂起',
      );
      expect(
        source.contains('awaitOwnedSocket<'),
        isTrue,
        reason: '超时后迟到的 socket 必须由 awaitOwnedSocket 关闭，不能泄漏',
      );
    });

    test('events ready 等待有超时', () {
      final source = File('lib/src/transport/connection.dart').readAsStringSync();
      expect(
        source.contains('events stream ready timeout'),
        isTrue,
        reason: r'等 $events ready 必须有超时，否则会一直等',
      );
    });

    test('会话列表拉取有超时（界面不能无限转圈）', () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(
        source.contains('browser.list().timeout('),
        isTrue,
        reason: '补会话状态时要给 list() 加超时，8 秒拿不到就切到可操作状态',
      );
    });

    test('重连已配对电脑必须带超时，并给出取消入口', () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(
        source.contains('_connectTimeout'),
        isTrue,
        reason: '重连要有一个明确的超时，否则网关不应答时首屏无限转圈',
      );
      expect(
        source.contains('.timeout(_connectTimeout)'),
        isTrue,
        reason: '重连必须真的用上超时（只定义常量不算）',
      );
      expect(
        source.contains("'conn.cancel'"),
        isTrue,
        reason: '连接中必须能取消，否则用户只能杀进程',
      );
      expect(
        source.contains("'conn.pairNew'"),
        isTrue,
        reason: '连接中/连不上时要能直接去配对一台新电脑',
      );
    });
  });
}
