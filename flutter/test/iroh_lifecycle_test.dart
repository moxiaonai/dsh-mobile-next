import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/src/transport/io_transport.dart';
import 'package:dsh_mobile/src/transport/request_generation.dart';

void main() {
  test('late WebSocket success is closed after timeout', () async {
    final pending = Completer<Object>();
    final closed = Completer<void>();
    final socket = Object();
    final connecting = awaitOwnedSocket(pending.future,
      timeout: const Duration(milliseconds: 1), close: (result) async {
        expect(identical(socket, result), isTrue);
        closed.complete();
      });
    await expectLater(connecting, throwsA(isA<TimeoutException>()));
    pending.complete(socket);
    await closed.future;
  });
  test('on-time socket transfers ownership without closing', () async {
    var closed = false;
    final socket = Object();
    expect(await awaitOwnedSocket(Future.value(socket),
      timeout: const Duration(seconds: 1), close: (_) async { closed = true; }), same(socket));
    expect(closed, isFalse);
  });
  test('old reconnect failure and old route cancel cannot mutate successor', () {
    final requests = RequestGeneration();
    final old = requests.begin();
    final next = requests.begin();
    expect(requests.owns(old), isFalse);
    expect(requests.cancel(old), isFalse);
    expect(requests.owns(next), isTrue);
    requests.invalidate();
    expect(requests.owns(next), isFalse);
  });
  test('cancellation during previous connection disposal rejects late success', () async {
    final requests = RequestGeneration();
    final oldDispose = Completer<void>();
    final request = requests.begin();
    var published = false;
    var disposed = false;
    final swap = () async {
      await oldDispose.future;
      if (!requests.owns(request)) { disposed = true; return; }
      published = true;
    }();
    requests.cancel(request);
    oldDispose.complete();
    await swap;
    expect(published, isFalse);
    expect(disposed, isTrue);
  });
}
