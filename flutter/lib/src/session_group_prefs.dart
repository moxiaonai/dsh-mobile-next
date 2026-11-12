/// 会话分组折叠状态的读写。
///
/// ## 为什么单独一个文件
///
/// 不塞进 `AppearanceState`：那个类有 `==` / `hashCode` 与序列化断言
/// （`settings_roundtrip_test.dart`），把列表偏好混进去会连带改一堆测试，
/// 而两者语义无关（一个是外观，一个是列表布局）。
///
/// 实现逐行镜像 `AppearanceStore`：`dart:io` + JSON，零新依赖。
library;

import 'dart:convert';
import 'dart:io';

/// 折叠分组集合的持久化。
class CollapsedGroupsStore {
  CollapsedGroupsStore({this.filePath});

  final String? filePath;

  File? get _file {
    final p = filePath;
    if (p == null) return null;
    return File(p);
  }

  /// 读取折叠集合。文件缺失或损坏时返回空集合（默认全展开）。
  Future<Set<String>> load() async {
    final f = _file;
    if (f == null || !f.existsSync()) return <String>{};
    try {
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String>{};
      final list = decoded['collapsed'];
      if (list is! List) return <String>{};
      return list.whereType<String>().toSet();
    } catch (_) {
      // 损坏不阻断启动
      return <String>{};
    }
  }

  /// 写入折叠集合。失败静默（与 `AppearanceStore.save` 同策略）。
  Future<void> save(Set<String> keys) async {
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({'collapsed': keys.toList()}));
    } catch (_) {
      // 写失败不影响交互
    }
  }
}
