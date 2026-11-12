/// DSH Remote 流协议的帧定义。
///
/// 权威来源：`@deepseek-ai/dsh-api-gateway/lib/types/stream-protocol.js`
/// （已从 app.asar 提取核对，见 `docs/60-protocol-feasibility.md`）。
///
/// 校验与官方一致：**严格键集合**（多一个字段即拒绝），`streamId` 必须是非空字符串。
/// 这里不发明字段，也不放宽校验 —— 放宽会让客户端在协议演进时静默错位。
library;

import 'dart:convert';

/// WebSocket 路径。该路径在 dsh-mobile 插件的 `WS_PATHS` 白名单内
/// （`http-security.ts:14`），经插件网关无需额外放行。
const String remoteMuxPath = '/api/remote.mux';

/// 应用级事件流端点（**不是** turn 流，见 docs/60 §2.2）。
const String eventsEndpoint = r'$events';

/// 事件应答端点。
const String eventsResultEndpoint = r'$events/result';

enum FrameType { item, end, error, ready, unknown }

/// 客户端 → Host 的帧。
sealed class ClientFrame {
  const ClientFrame();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());
}

/// 打开一条逻辑流。
///
/// 官方校验（`parseRemoteStreamClientMessage`）：
/// 恰好 `{type, streamId, endpoint, payload}`。
class OpenFrame extends ClientFrame {
  const OpenFrame({
    required this.streamId,
    required this.endpoint,
    required this.payload,
  });

  final String streamId;
  final String endpoint;
  final Map<String, Object?> payload;

  @override
  Map<String, Object?> toJson() => {
    'type': 'open',
    'streamId': streamId,
    'endpoint': endpoint,
    'payload': payload,
  };
}

/// 上行数据。
///
/// `hasValue == false` 时省略 `value` 键 —— 官方把「有 value 但为 null」
/// 与「无 value」视为两种合法形态，不能混同。
class ItemFrame extends ClientFrame {
  const ItemFrame({required this.streamId, this.value, this.hasValue = true});

  final String streamId;
  final Object? value;
  final bool hasValue;

  @override
  Map<String, Object?> toJson() => {
    'type': 'item',
    'streamId': streamId,
    if (hasValue) 'value': value,
  };
}

/// 半关闭上行。
class EndFrame extends ClientFrame {
  const EndFrame({required this.streamId});
  final String streamId;

  @override
  Map<String, Object?> toJson() => {'type': 'end', 'streamId': streamId};
}

/// 取消整条流。
class CancelFrame extends ClientFrame {
  const CancelFrame({required this.streamId});
  final String streamId;

  @override
  Map<String, Object?> toJson() => {'type': 'cancel', 'streamId': streamId};
}

/// Host → 客户端 的帧。
class ServerFrame {
  const ServerFrame({
    required this.type,
    required this.streamId,
    this.value,
    this.hasValue = false,
    this.error,
  });

  final FrameType type;
  final String streamId;
  final Object? value;
  final bool hasValue;
  final RemoteError? error;

  bool get isItem => type == FrameType.item;
  bool get isEnd => type == FrameType.end;
  bool get isError => type == FrameType.error;

  /// 解析一帧；不合法时抛 [ProtocolError]。
  static ServerFrame parse(Object? decoded) {
    if (decoded is! Map) {
      throw const ProtocolError('frame must be a JSON object');
    }
    final map = decoded.cast<String, Object?>();
    final type = map['type'];
    if (type is! String) throw const ProtocolError('frame.type must be a string');
    final streamId = map['streamId'];
    if (streamId is! String || streamId.isEmpty) {
      throw const ProtocolError('frame.streamId must be a non-empty string');
    }

    switch (type) {
      case 'item':
        _exactKeys(map, const ['type', 'streamId'], const ['value']);
        return ServerFrame(
          type: FrameType.item,
          streamId: streamId,
          value: map['value'],
          hasValue: map.containsKey('value'),
        );
      case 'end':
        _exactKeys(map, const ['type', 'streamId'], const []);
        return ServerFrame(type: FrameType.end, streamId: streamId);
      case 'error':
        _exactKeys(map, const ['type', 'streamId', 'error'], const []);
        final err = map['error'];
        if (err is! Map) {
          throw const ProtocolError('frame.error must be an object');
        }
        final em = err.cast<String, Object?>();
        _exactKeys(em, const ['code', 'message', 'details'], const []);
        return ServerFrame(
          type: FrameType.error,
          streamId: streamId,
          error: RemoteError(
            code: em['code'] as String? ?? 'unknown',
            message: em['message'] as String? ?? '',
            details: em['details'],
          ),
        );
      case 'ready':
        // `$events` 的 generation 握手帧。不同版本会附加 clientId/host，
        // 因此这里不要求精确键集合，但 `type`/`streamId` 仍已校验。
        return ServerFrame(
          type: FrameType.ready,
          streamId: streamId,
          value: map,
          hasValue: true,
        );
      default:
        // 未知帧类型不抛错：协议允许演进，调用方按 unknown 忽略。
        return ServerFrame(type: FrameType.unknown, streamId: streamId);
    }
  }
}

/// 远程错误，对应官方 `RemoteError`（code / message / details）。
class RemoteError implements Exception {
  const RemoteError({required this.code, required this.message, this.details});

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'RemoteError($code): $message';
}

/// 帧格式不合法，或客户端违反了契约。
class ProtocolError implements Exception {
  const ProtocolError(this.message);
  final String message;

  @override
  String toString() => 'ProtocolError: $message';
}

void _exactKeys(
  Map<String, Object?> value,
  List<String> required,
  List<String> optional,
) {
  for (final key in required) {
    if (!value.containsKey(key)) {
      throw ProtocolError('missing required key "$key"');
    }
  }
  for (final key in value.keys) {
    if (!required.contains(key) && !optional.contains(key)) {
      throw ProtocolError('unexpected key "$key"');
    }
  }
}
