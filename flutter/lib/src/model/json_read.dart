/// 手写的 JSON 读取助手，供 `generated.dart` 使用。
///
/// 为什么需要它：Dart 的类型提升（type promotion）只对**局部变量**生效，
/// 对 `json['key']` 这类索引表达式不生效。因此生成代码里直接写
/// `json['x'] is Map ? ... : null` 无法通过静态分析。
///
/// 把这些判断收进助手函数，生成代码就能保持简单且类型安全。
library;

/// 取对象。非 Map 返回 null。
Map<String, Object?>? asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

/// 取对象，缺失时返回空 Map（用于非空字段）。
Map<String, Object?> asMapOrEmpty(Object? value) =>
    asMap(value) ?? const <String, Object?>{};

/// 把 JSON 对象转成模型；非对象返回 null。
T? asModel<T>(Object? value, T Function(Map<String, Object?>) decode) {
  final map = asMap(value);
  return map == null ? null : decode(map);
}

/// 把 JSON 数组转成模型列表；非数组返回空列表（用于非空字段）。
List<T> asList<T>(Object? value, T Function(Map<String, Object?>) decode) =>
    asListOrNull(value, decode) ?? const [];

/// 把 JSON 数组转成模型列表；非数组返回 null（用于可空字段）。
List<T>? asListOrNull<T>(
  Object? value,
  T Function(Map<String, Object?>) decode,
) {
  if (value is! List) return null;
  final out = <T>[];
  for (final item in value) {
    final map = asMap(item);
    if (map != null) out.add(decode(map));
  }
  return out;
}

/// 把 JSON 数组转成枚举列表；非数组返回空列表。
List<T> asEnumList<T>(Object? value, T Function(Object?) decode) =>
    asEnumListOrNull(value, decode) ?? const [];

/// 把 JSON 数组转成枚举列表；非数组返回 null。
List<T>? asEnumListOrNull<T>(Object? value, T Function(Object?) decode) {
  if (value is! List) return null;
  return value.map(decode).toList();
}

/// 字符串列表；非数组返回空列表。
List<String> asStringList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<String>().toList();
}

int? asInt(Object? value) => value is num ? value.toInt() : null;

num? asNum(Object? value) => value is num ? value : null;

bool? asBool(Object? value) => value is bool ? value : null;

String? asString(Object? value) => value is String ? value : null;

/// 毫秒时间戳 → DateTime。
DateTime? asDateTime(Object? value) {
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// 基础类型列表（String/int/num/bool）。非数组返回空列表。
List<T> asListRaw<T>(Object? value) {
  if (value is! List) return const [];
  final out = <T>[];
  for (final item in value) {
    if (item is T) out.add(item);
  }
  return out;
}

/// 对象数组 → `List<Map<String, Object?>>`；非数组返回 null。
List<Map<String, Object?>>? asMapList(Object? value) {
  if (value is! List) return null;
  final out = <Map<String, Object?>>[];
  for (final item in value) {
    final map = asMap(item);
    if (map != null) out.add(map);
  }
  return out;
}
