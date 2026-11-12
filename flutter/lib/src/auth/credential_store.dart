/// 凭据存储：配对后长期保存设备令牌。
///
/// ## 安全边界（必须说清）
///
/// **这不是 Keystore。** 当前用 `dart:io` 写文件，只适合开发与桌面。
///
/// 正式版**必须**换成平台安全存储：
/// - Android：`EncryptedSharedPreferences` / Keystore（参考项目用
///   `DeviceCredentialStore.kt` + Keystore）
/// - iOS：Keychain
///
/// 两者的差别是实质性的：文件可被 root/备份工具读取，Keystore 不可导出。
/// 因此在 `debug` 之外使用本实现应当被显式警告。
///
/// ## 为什么要单独一层
///
/// 存储后端会换（文件 → Keystore），但**调用方不该感知**。
/// 这里定义 `CredentialStore` 接口 + 文件实现，后续替换只改工厂。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'pairing.dart';

/// 凭据存储接口。
abstract class CredentialStore {
  /// 读取全部已配对设备。
  Future<List<DeviceCredential>> loadAll();

  /// 保存（同 origin + instanceId 视为同一设备，覆盖）。
  Future<void> save(DeviceCredential credential);

  /// 删除一台。
  Future<void> remove(DeviceCredential credential);

  /// 清空。
  Future<void> clear();
}

/// 文件实现（开发用）。
///
/// ⚠ **不安全**：明文 JSON 落盘。见文件头说明。
class FileCredentialStore implements CredentialStore {
  FileCredentialStore({required this.filePath});

  final String? filePath;

  File? get _file {
    final p = filePath;
    if (p == null) return null;
    return File(p);
  }

  @override
  Future<List<DeviceCredential>> loadAll() async {
    final f = _file;
    if (f == null || !f.existsSync()) return const [];
    try {
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <DeviceCredential>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          out.add(DeviceCredential.fromJson(item.cast<String, Object?>()));
        } catch (_) {
          // 单条损坏不影响其余
          continue;
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> save(DeviceCredential credential) async {
    final all = await loadAll();
    // 同一台电脑（origin + instanceId）覆盖，不重复追加
    final next = all
        .where(
          (c) =>
              !(c.origin == credential.origin &&
                  c.instanceId == credential.instanceId),
        )
        .toList()
      ..add(credential);
    await _write(next);
  }

  @override
  Future<void> remove(DeviceCredential credential) async {
    final all = await loadAll();
    final next = all
        .where(
          (c) =>
              !(c.origin == credential.origin &&
                  c.instanceId == credential.instanceId),
        )
        .toList();
    await _write(next);
  }

  @override
  Future<void> clear() => _write(const []);

  Future<void> _write(List<DeviceCredential> list) async {
    final f = _file;
    if (f == null) {
      // 没有路径 = 凭据只存在内存里，重启即丢。必须让调用方知道。
      debugPrint('[credentials] 无可用路径，凭据未落盘（重启后需重新配对）');
      return;
    }
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode(list.map((c) => c.toJson()).toList()),
      );
      debugPrint('[credentials] 已写入 ${f.path}（${list.length} 条）');
    } catch (e) {
      // ⚠ 不能静默吞掉：之前这里 `catch (_) {}`，写失败时 save() 仍返回成功，
      // 表现为「配对成功但重启后又要求配对」，且没有任何线索。
      // 现在至少打日志；调用方（PairingFlow）已在 try/catch 里，不会崩。
      debugPrint('[credentials] 写入失败 ${f.path}: $e');
    }
  }
}

/// 内存实现（测试用）。
class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore([List<DeviceCredential> initial = const []])
    : _items = [...initial];

  final List<DeviceCredential> _items;

  List<DeviceCredential> get items => List.unmodifiable(_items);

  @override
  Future<List<DeviceCredential>> loadAll() async => List.of(_items);

  @override
  Future<void> save(DeviceCredential credential) async {
    _items.removeWhere(
      (c) =>
          c.origin == credential.origin &&
          c.instanceId == credential.instanceId,
    );
    _items.add(credential);
  }

  @override
  Future<void> remove(DeviceCredential credential) async {
    _items.removeWhere(
      (c) =>
          c.origin == credential.origin &&
          c.instanceId == credential.instanceId,
    );
  }

  @override
  Future<void> clear() async => _items.clear();
}

/// 生产环境应使用的存储工厂。
///
/// 目前返回文件实现（开发期）。正式版替换为 Keystore 实现。
/// 凭据文件路径（异步解析）。
///
/// ## 为什么不能用 systemTemp
///
/// 之前写成 `Directory.systemTemp`（Android 上是 `/data/local/tmp`），
/// 而**普通 App 对该目录没有写权限**。后果是配对成功、凭据却写不进去，
/// 下次启动读不到 —— 表现为「配对成功后点进入任务，又回到尚未配对」。
///
/// 现在改用 `getApplicationSupportDirectory()`：Android 是
/// `/data/data/<pkg>/files`，iOS 是 App 沙盒，桌面是用户配置目录。
/// 这些位置 App 有写权限，且卸载时才清除。
Future<String?> resolveCredentialPath() => resolveStatePath('credentials.json');

/// 解析一个持久化文件的绝对路径。
///
/// ## 为什么不能只用 `Directory.systemTemp`
///
/// Android 上 `systemTemp` 是 `/data/local/tmp`，**普通 App 没有写权限**。
/// 写文件会失败，而调用方通常静默 catch —— 表现为「设置改了，重启就重置」，
/// 且没有任何错误线索。实测踩过：主题/语言/折叠状态全都存不下来，
/// 只有走 `path_provider` 的凭据是好的。
///
/// 优先级：
/// 1. `$DSH_HOME`（桌面调试时显式指定）
/// 2. `getApplicationSupportDirectory()`（Android/iOS 的 App 私有目录）
/// 3. null（Web / 拿不到目录 → 调用方退化为内存存储）
Future<String?> resolveStatePath(String fileName) async {
  if (kIsWeb) return null;
  final home = Platform.environment['DSH_HOME'];
  if (home != null && home.isNotEmpty) {
    return '$home/mobile-client/$fileName';
  }
  try {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return '${dir.path}/mobile-client/$fileName';
  } catch (_) {
    return null;
  }
}

/// 同步版：仅供不关心持久化的调用点（返回 null 表示用内存存储）。
CredentialStore createCredentialStore() {
  if (kIsWeb) {
    // Web 无文件系统：退化为内存（刷新即丢，必须重新配对）
    return MemoryCredentialStore();
  }
  final home = Platform.environment['DSH_HOME'];
  if (home == null || home.isEmpty) {
    // 真机上拿不到 DSH_HOME —— 调用方应改用 [createCredentialStoreAsync]
    return MemoryCredentialStore();
  }
  final path = '$home/mobile-client/credentials.json';

  // 显式警告：这是开发用存储，不具备 Keystore 级保护
  assert(() {
    debugPrint(
      '[credentials] 使用文件存储（开发用）：$path\n'
      '  正式版必须替换为 Keystore / Keychain —— 文件可被读取，Keystore 不可导出。',
    );
    return true;
  }());

  return FileCredentialStore(filePath: path);
}


/// 异步工厂：真机上用它，凭据落在 App 私有目录。
Future<CredentialStore> createCredentialStoreAsync() async {
  final path = await resolveCredentialPath();
  if (path == null) return MemoryCredentialStore();
  return FileCredentialStore(filePath: path);
}
