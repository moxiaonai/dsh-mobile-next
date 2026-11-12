import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/src/transport/iroh_transport.dart';

void main() {
  test('real loopback TLS pins CA and retains logical host/SAN', () async {
    final fixture = Directory('test/fixtures/iroh-tls');
    final serverContext = SecurityContext()
      ..useCertificateChain('${fixture.path}/server.pem')
      ..usePrivateKey('${fixture.path}/server-key.pem');
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverContext);
    final hostSeen = <String?>[];
    server.listen((request) async {
      hostSeen.add(request.headers.value(HttpHeaders.hostHeader));
      request.response.write('pinned');
      await request.response.close();
    });
    final caContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('${fixture.path}/ca.pem');
    HttpClient client(SecurityContext context) {
      final client = HttpClient(context: context);
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) =>
          IrohTransport.connectPinnedTls(uri.host, server.port, context);
      return client;
    }
    final good = client(caContext);
    final untrusted = client(SecurityContext(withTrustedRoots: false));
    try {
      final response = await (await good.getUrl(Uri.parse('https://iroh.test.localhost:${server.port}/'))).close();
      expect(await response.transform(utf8.decoder).join(), 'pinned');
      expect(hostSeen.single, 'iroh.test.localhost:${server.port}');
      await expectLater(good.getUrl(Uri.parse('https://wrong.test.localhost:${server.port}/')), throwsA(isA<HandshakeException>()));
      await expectLater(untrusted.getUrl(Uri.parse('https://iroh.test.localhost:${server.port}/')), throwsA(isA<HandshakeException>()));
    } finally {
      good.close(force: true);
      untrusted.close(force: true);
      await server.close(force: true);
    }
  });
}
