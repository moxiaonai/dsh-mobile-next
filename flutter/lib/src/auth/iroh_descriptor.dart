/// iroh v1 QR transport material. Secrets are consumed once and never persisted.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

class IrohMetadata {
  const IrohMetadata({
    required this.endpointId,
    required this.localPort,
    required this.caCertificate,
    this.caFingerprint,
  });
  final String endpointId;
  final int localPort;

  /// Base64 DER, not PEM. Only this trust root is used for end-to-end TLS.
  final String caCertificate;
  final String? caFingerprint;

  Uri get origin => Uri.parse(
    'https://${endpointId.substring(0, 32)}.'
    '${endpointId.substring(32)}.iroh.localhost:$localPort',
  );
  String get caPem =>
      '-----BEGIN CERTIFICATE-----\n'
      '${RegExp('.{1,64}').allMatches(caCertificate).map((m) => m.group(0)).join('\n')}\n'
      '-----END CERTIFICATE-----\n';
  String get fingerprint =>
      sha256.convert(base64Decode(caCertificate)).toString();
  Map<String, Object?> toJson() => {
    'type': 'iroh',
    'version': 1,
    'endpointId': endpointId,
    'localPort': localPort,
    'caCertificate': caCertificate,
    if (caFingerprint != null) 'caFingerprint': caFingerprint,
  };

  static IrohMetadata fromJson(Map<String, Object?> json) {
    if (json['version'] != 1 || json['type'] != 'iroh') {
      throw const FormatException('unsupported saved transport');
    }
    return validate(json);
  }

  static IrohMetadata validate(Map<String, Object?> json) {
    final id = json['endpointId'];
    final port = json['localPort'];
    final ca = json['caCertificate'];
    final fp = json['caFingerprint'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        port is! int ||
        port < 1024 ||
        port > 65535 ||
        ca is! String ||
        ca.isEmpty ||
        ca.length > 2048 ||
        (fp != null &&
            (fp is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(fp)))) {
      throw const FormatException('invalid iroh transport metadata');
    }
    final bytes = base64Decode(ca);
    if (bytes.isEmpty || bytes.length > 1536 || base64Encode(bytes) != ca) {
      throw const FormatException('invalid iroh CA encoding');
    }
    final metadata = IrohMetadata(
      endpointId: id,
      localPort: port,
      caCertificate: ca,
      caFingerprint: fp as String?,
    );
    if (fp != null && metadata.fingerprint != fp) {
      throw const FormatException('iroh CA fingerprint mismatch');
    }
    return metadata;
  }
}

class IrohPairingMaterial {
  const IrohPairingMaterial({
    required this.metadata,
    required this.code,
    required this.gatewayToken,
    required this.expiresAt,
    this.instanceId,
  });
  final IrohMetadata metadata;
  final String code;
  final String gatewayToken;
  final DateTime expiresAt;
  final String? instanceId;

  static IrohPairingMaterial parse(String raw, {DateTime? now}) {
    if (utf8.encode(raw).length > 2600) {
      throw const FormatException('iroh descriptor too large');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('iroh descriptor must be an object');
    }
    const required = {
      'version',
      'type',
      'endpointId',
      'origin',
      'localPort',
      'irohCode',
      'gatewayToken',
      'caCertificate',
      'expiresAt',
    };
    const allowed = {...required, 'caFingerprint', 'instanceId'};
    if (!decoded.keys.toSet().containsAll(required) ||
        decoded.keys.any((k) => !allowed.contains(k)) ||
        RegExp(r'"(?:[^"\\]|\\[\s\S])*"\s*:').allMatches(raw).length !=
            decoded.length ||
        decoded['version'] != 1 ||
        decoded['type'] != 'dsh-mobile-iroh-pairing') {
      throw const FormatException('unsupported iroh descriptor fields');
    }
    final metadata = IrohMetadata.validate(decoded);
    final code = decoded['irohCode'];
    final token = decoded['gatewayToken'];
    final expiry = decoded['expiresAt'];
    final instance = decoded['instanceId'];
    final clock = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (decoded['origin'] != metadata.origin.toString() ||
        code is! String ||
        !RegExp(r'^[0-9]{6}$').hasMatch(code) ||
        token is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
        base64Url.encode(base64Url.decode('$token=')).replaceAll('=', '') !=
            token ||
        expiry is! int ||
        expiry <= clock ||
        expiry - clock > 600000 ||
        (instance != null &&
            (instance is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(instance)))) {
      throw const FormatException('invalid or expired iroh descriptor');
    }
    if (instance != null && instance != metadata.fingerprint) {
      throw const FormatException('iroh instance fingerprint mismatch');
    }
    return IrohPairingMaterial(
      metadata: metadata,
      code: code,
      gatewayToken: token,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiry),
      instanceId: instance as String?,
    );
  }
}
