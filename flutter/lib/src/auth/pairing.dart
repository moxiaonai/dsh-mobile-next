/// 凭据与配对。
///
/// ## 验证状态
///
/// 配对**协议语义已用真实发布代码验证**（14/14 通过）：
/// 见 `tool/pairing-verify/verify_pairing.mjs` —— 它直接实例化 npm 正式包
/// `dsh-mobile@0.8.6` 编译产物里的 `AccessController`，跑通
/// `openPairing → pair → renew` 全链路，并断言：
///
/// - 一次性 token 只能使用一次
/// - 错误 token 被拒（401 `authentication_failed`）
/// - 只持久化 deviceToken 的摘要，不存明文
/// - `renew` 能换新 sessionToken，无效 deviceToken 被拒
///
/// **尚未验证的部分**：手机端通过 HTTP 调用 `/mobile-access/auth/native-pair`
/// 的真实网络往返（需要装插件并起网关）。协议本身已确认。
///
/// ## 边界
///
/// - [PairingClient] 按 `dsh-mobile` 插件的 `native-pair` 契约实现；
/// - 它**不**读 `.credentials.yaml` —— 那是桌面端特权，手机不可能拥有。
///
/// 手机的凭据来自扫码：插件生成一次性 token 嵌在二维码里，
/// 手机 POST 到 `/mobile-access/auth/native-pair` 换取 `deviceToken` 等。
///
/// ## 关键机制
///
/// 返回的 `sessionToken` **不是** DSH 的 `dsh-auth-*` cookie。
/// 插件自己持有上游凭据（`upstreamAuthenticatedUrl`），换取真实 DSH cookie
/// 后注入每个代理请求与 WebSocket 升级。手机永远看不到 DSH 密钥。
library;

import 'dart:async';
import 'dart:convert';

import '../transport/unary.dart' show HttpTransport;
import 'iroh_descriptor.dart';
export 'iroh_descriptor.dart';

/// 配对结果。字段名与插件 `handleNativePair` 的 201 响应一致
/// （`reference/src/gateway.ts:2038-2048`）。
class PairingResult {
  const PairingResult({
    required this.deviceId,
    required this.deviceToken,
    required this.deviceExpiresAt,
    required this.sessionToken,
    required this.csrfToken,
    required this.sessionExpiresAt,
    this.instanceId,
  });

  final String deviceId;

  /// 长期设备令牌，存 Keystore。用于 `native-renew`。
  final String deviceToken;

  final DateTime? deviceExpiresAt;

  /// 会话令牌。**注意：它不是 DSH cookie** —— 插件持有上游凭据并代理。
  final String sessionToken;

  final String csrfToken;
  final DateTime? sessionExpiresAt;
  final String? instanceId;

  factory PairingResult.fromJson(Map<String, Object?> json) {
    String need(String key) {
      final v = json[key];
      if (v is! String || v.isEmpty) {
        throw PairingException('pairing response missing "$key"');
      }
      return v;
    }

    DateTime? at(String key) {
      final v = json[key];
      if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    return PairingResult(
      deviceId: need('deviceId'),
      deviceToken: need('deviceToken'),
      deviceExpiresAt: at('deviceExpiresAt'),
      sessionToken: need('sessionToken'),
      csrfToken: need('csrfToken'),
      sessionExpiresAt: at('sessionExpiresAt'),
      instanceId: json['instanceId'] as String?,
    );
  }
}

class PairingException implements Exception {
  const PairingException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'PairingException(${statusCode ?? '-'}): $message';
}

/// 二维码/配对链接的解析结果。
class PairingDescriptor {
  const PairingDescriptor({
    required this.origin,
    required this.token,
    this.instanceId,
    this.iroh,
  });

  final Uri origin;
  final String token;
  final String? instanceId;
  final IrohPairingMaterial? iroh;

  /// 解析插件生成的配对载荷。
  ///
  /// 已知形态（`reference/src/gateway.ts:4546-4559`）：
  /// - `https://host:port/mobile-access/pair#instance=<id>&token=<token>`
  /// - `https://host:port/mobile-access/pair#key=dsh1.<id>.<token>`
  ///
  /// 两种都解析；无法识别时抛 [PairingException]，不猜测。
  static PairingDescriptor parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      try {
        final material = IrohPairingMaterial.parse(trimmed);
        return PairingDescriptor(
          origin: material.metadata.origin,
          token: material.gatewayToken,
          instanceId: material.instanceId,
          iroh: material,
        );
      } on FormatException {
        throw const PairingException(
          'invalid or expired iroh pairing descriptor',
        );
      }
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      throw const PairingException('not a URL');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw PairingException('unsupported scheme "${uri.scheme}"');
    }

    // 两种载荷都要接受：
    //   - 参考实现：`…/pair#token=xxx`（fragment）
    //   - dsh-mobile-next：`…/pair?token=xxx`（query，二维码就是这么生成的）
    // 只认 fragment 会让「扫我们自己的码」直接失败。
    final fragment = uri.fragment;
    final params = fragment.isNotEmpty
        ? Uri.splitQueryString(fragment)
        : uri.queryParameters;

    final key = params['key'];
    if (key != null) {
      // dsh1.<instanceId>.<token>
      final parts = key.split('.');
      if (parts.length < 3 || parts[0] != 'dsh1') {
        throw const PairingException('malformed key fragment');
      }
      return PairingDescriptor(
        origin: _cleanOrigin(uri),
        token: parts.sublist(2).join('.'),
        instanceId: parts[1],
      );
    }

    final token = params['token'];
    if (token == null || token.isEmpty) {
      throw const PairingException('pairing URL has no token');
    }
    return PairingDescriptor(
      origin: _cleanOrigin(uri),
      token: token,
      instanceId: params['instance'],
    );
  }

  /// 只保留 scheme + host + port。
  ///
  /// ⚠ 不能用 `uri.replace(fragment: '', query: '')`：Uri 的 `replace`
  /// 在 query/fragment 传空串时**不会删除**它们，而是留下 `?` 和 `#`。
  /// 结果 origin 变成 `https://h:p/path?#`，再拼一次就成了 `##token=`，
  /// 重新解析时 token 丢失 —— 报错正是「pairing URL has no token」。
  static Uri _cleanOrigin(Uri uri) => Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

/// 配对客户端。
class PairingClient {
  PairingClient({
    required this.transport,
    this.timeout = const Duration(seconds: 30),
    this.pairPath = '/mobile-access-next/pair',
    this.renewPath = '/mobile-access-next/renew',
  });

  final HttpTransport transport;
  final Duration timeout;

  /// 配对端点路径。
  ///
  /// 不同插件的路径不同：
  /// - `dsh-mobile`：`/mobile-access/auth/native-pair`
  /// - `dsh-mobile-next`：`/mobile-access-next/pair`
  ///
  /// 因此做成可配置，而不是硬编码。
  final String pairPath;

  /// 续期端点路径。`dsh-mobile-next` 目前没有独立续期端点。
  final String renewPath;

  /// 用一次性 token 换取设备凭据。
  Future<PairingResult> pair(
    PairingDescriptor descriptor, {
    String? label,
  }) async {
    final uri = descriptor.origin.replace(
      path: pairPath,
      query: null,
      fragment: null,
    );
    final body = jsonEncode({
      'token': descriptor.token,
      if (label != null) 'label': label,
    });

    final response = await transport.post(
      uri,
      body,
      headers: {'content-type': 'application/json'},
      timeout: timeout,
    );

    if (response.statusCode != 201) {
      throw PairingException(
        'pairing rejected (HTTP ${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const PairingException('pairing response is not JSON');
    }
    if (decoded is! Map) {
      throw const PairingException('pairing response is not an object');
    }
    return PairingResult.fromJson(decoded.cast<String, Object?>());
  }

  /// 用 deviceToken 续期（Host 重启后会话失效时使用）。
  ///
  /// 对应 `native-renew`（`reference/src/gateway.ts:2049-2065`），返回新的
  /// `sessionToken` / `csrfToken`。
  Future<PairingResult> renew({
    required Uri origin,
    required String deviceToken,
  }) async {
    final uri = origin.replace(path: renewPath, query: null, fragment: null);
    final response = await transport.post(
      uri,
      jsonEncode({'deviceToken': deviceToken}),
      headers: {'content-type': 'application/json'},
      timeout: timeout,
    );
    if (response.statusCode != 200) {
      throw PairingException(
        'renew rejected (HTTP ${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const PairingException('renew response is not an object');
    }
    return PairingResult.fromJson(decoded.cast<String, Object?>());
  }
}

/// 已保存的设备凭据（应存 Keystore / Keychain）。
class DeviceCredential {
  const DeviceCredential({
    required this.origin,
    required this.deviceId,
    required this.deviceToken,
    required this.instanceId,
    this.label,
    this.transport,
  });

  final Uri origin;
  final String deviceId;
  final String deviceToken;
  final String? instanceId;
  final String? label;
  final IrohMetadata? transport;

  Map<String, Object?> toJson() => {
    'origin': origin.toString(),
    'deviceId': deviceId,
    'deviceToken': deviceToken,
    'instanceId': instanceId,
    'label': label,
    if (transport != null) 'transport': transport!.toJson(),
  };

  static DeviceCredential fromJson(Map<String, Object?> json) {
    return DeviceCredential(
      origin: Uri.parse(json['origin'] as String),
      deviceId: json['deviceId'] as String,
      deviceToken: json['deviceToken'] as String,
      instanceId: json['instanceId'] as String?,
      label: json['label'] as String?,
      transport: json['transport'] == null
          ? null
          : IrohMetadata.fromJson(
              (json['transport'] as Map).cast<String, Object?>(),
            ),
    );
  }
}
