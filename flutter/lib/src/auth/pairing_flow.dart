/// Pairing/renew orchestration with request-scoped transport ownership.
library;

import 'dart:async';

import '../transport/connection.dart';
import '../transport/io_transport.dart';
import '../transport/iroh_transport.dart';
import '../transport/unary.dart';
import 'credential_store.dart';
import 'pairing.dart';

enum PairingFailure {
  badDescriptor,
  expiredOrInvalid,
  network,
  rejected,
  connectFailed,
  unknown,
}

sealed class PairingOutcome {
  const PairingOutcome();
}

class PairingSucceeded extends PairingOutcome {
  const PairingSucceeded({required this.credential, required this.connection});
  final DeviceCredential credential;
  final DshConnection connection;
}

class PairingFailed extends PairingOutcome {
  const PairingFailed({required this.failure, required this.message});
  final PairingFailure failure;
  final String message;
}

class PairingFlow {
  PairingFlow({
    required this.store,
    HttpTransport? transport,
    this.trustedCaPem,
    this.connectAfterPair = true,
  }) : transport = transport ?? IoHttpTransport(trustedCaPem: trustedCaPem),
       _ownsLanTransport = transport == null;
  final CredentialStore store;
  final HttpTransport transport;
  final bool _ownsLanTransport;
  final String? trustedCaPem;
  final bool connectAfterPair;
  int _generation = 0;
  Future<void> Function()? _pendingClose;

  /// Invalidate BEFORE awaiting native shutdown, so late responses cannot commit.
  Future<void> cancel() async {
    ++_generation;
    final close = _pendingClose;
    _pendingClose = null;
    await close?.call();
  }

  Future<void> dispose() async {
    await cancel();
    if (_ownsLanTransport && transport is IoHttpTransport) {
      (transport as IoHttpTransport).close();
    }
  }

  Future<PairingOutcome> run(String rawInput, {String? label}) async {
    try {
      return await runDescriptor(
        PairingDescriptor.parse(rawInput),
        label: label,
      );
    } on PairingException catch (e) {
      return PairingFailed(
        failure: PairingFailure.badDescriptor,
        message: e.message,
      );
    }
  }

  Future<PairingOutcome> runDescriptor(
    PairingDescriptor descriptor, {
    String? label,
  }) => _execute(descriptor: descriptor, label: label);
  Future<PairingOutcome> reconnect(DeviceCredential credential) =>
      _execute(credential: credential);

  Future<PairingOutcome> _execute({
    PairingDescriptor? descriptor,
    DeviceCredential? credential,
    String? label,
  }) async {
    final generation = ++_generation;
    final previousClose = _pendingClose;
    _pendingClose = null;
    await previousClose?.call();
    final origin = descriptor?.origin ?? credential!.origin;
    final metadata = descriptor?.iroh?.metadata ?? credential?.transport;
    IrohTransport? carrier;
    IoHttpTransport? ownedHttp;
    var activeTransport = transport;
    var sockets = ioMuxSocketFactory(trustedCaPem: trustedCaPem);
    var connecting = false;
    var transferred = false;
    void check() {
      if (generation != _generation) throw StateError('pairing cancelled');
    }

    Future<void> close() async {
      ownedHttp?.close();
      await carrier?.close();
    }

    try {
      check();
      if (metadata != null) {
        if (origin != metadata.origin) {
          throw StateError('saved iroh origin mismatch');
        }
        // Validate the DER as a TLS trust root before any native networking.
        final probe = IoHttpTransport.buildClientFor(metadata.caPem);
        probe.close(force: true);
        carrier = IrohTransport.reserve(metadata);
        _pendingClose = close;
        await carrier.connect(code: descriptor?.iroh?.code);
        check();
        activeTransport = carrier.http;
        sockets = carrier.socketFactory;
      } else if (_ownsLanTransport) {
        // LAN attempts also get isolated clients; cancellation closes old HTTP.
        ownedHttp = IoHttpTransport(trustedCaPem: trustedCaPem);
        activeTransport = ownedHttp;
        final wsClient = trustedCaPem == null
            ? null
            : IoHttpTransport.buildClientFor(trustedCaPem!);
        sockets = (uri, headers) =>
            IoMuxSocket.connect(uri, headers, client: wsClient);
        _pendingClose = () async {
          wsClient?.close(force: true);
          await close();
        };
      }
      if (descriptor?.iroh != null &&
          descriptor!.iroh!.expiresAt.isBefore(DateTime.now())) {
        throw const PairingException(
          'iroh pairing descriptor expired',
          statusCode: 401,
        );
      }
      final client = PairingClient(transport: activeTransport);
      final result = descriptor != null
          ? await client.pair(descriptor, label: label)
          : await client.renew(
              origin: origin,
              deviceToken: credential!.deviceToken,
            );
      check();
      final saved = DeviceCredential(
        origin: origin,
        deviceId: result.deviceId,
        deviceToken: result.deviceToken,
        instanceId:
            result.instanceId ??
            descriptor?.instanceId ??
            credential?.instanceId,
        label: label ?? credential?.label,
        transport: metadata,
      );
      await store.save(saved);
      check();
      if (!connectAfterPair) {
        return PairingSucceeded(
          credential: saved,
          connection: _NullConnection(),
        );
      }
      connecting = true;
      final cleanup = _pendingClose ?? close;
      final conn = await DshConnection.connect(
        origin: origin,
        cookieHeader: cookieHeaderFromPairing(result),
        transport: activeTransport,
        socketFactory: sockets,
        onDispose: cleanup,
      );
      if (generation != _generation) {
        await conn.dispose();
        throw StateError('pairing cancelled');
      }
      _pendingClose = null;
      transferred = true;
      return PairingSucceeded(credential: saved, connection: conn);
    } catch (e) {
      return PairingFailed(
        failure: connecting ? PairingFailure.connectFailed : _classify(e),
        message: generation != _generation ? 'pairing cancelled' : '$e',
      );
    } finally {
      if (!transferred) {
        if (generation == _generation) {
          final cleanup = _pendingClose;
          _pendingClose = null;
          await (cleanup ?? close)();
        } else {
          await close();
        }
      }
    }
  }

  static PairingFailure _classify(Object e) {
    if (e is PairingException) {
      if (e.statusCode == 401) return PairingFailure.expiredOrInvalid;
      if (e.statusCode == 403) return PairingFailure.rejected;
    }
    if (e is TimeoutException ||
        '$e'.contains('Connection refused') ||
        '$e'.contains('connection_failed')) {
      return PairingFailure.network;
    }
    return PairingFailure.unknown;
  }
}

class _NullConnection implements DshConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('connectAfterPair=false');
}
