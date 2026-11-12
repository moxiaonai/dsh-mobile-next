/// 外观设置的状态与持久化。
///
/// ## 为什么单独一层
///
/// 设置页要改的东西（主题 / 字号 / 动效 / 缩放）**影响整棵树**，
/// 但它们的消费点分散在不同位置：
/// - 主题 → `Tokens.light` / `Tokens.dark`
/// - 字号 → `AppTextStyles.fontBase`
/// - 动效 → `MediaQuery.disableAnimations`
///
/// 因此状态必须提升到 `MaterialApp` 之上，而不是留在设置页里。
///
/// ## 一个真实的 bug（已修）
///
/// 初版 `AppearancePage.onChanged` 只接了 `fontBase`：
///
/// ```dart
/// onChanged: (s) => widget.onFontChanged(s.fontBase),  // 主题被丢弃
/// ```
///
/// 导致点「浅色/深色」毫无反应。同时 `settings` 每次 build 都从
/// `txt.fontBase` 重建，主题/动效的改动连暂存都没有。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_strings.dart';
import 'ui/appearance_page.dart';

/// 外观设置。
@immutable
class AppearanceState {
  const AppearanceState({
    this.theme = ThemePreference.system,
    this.fontBase = 16,
    this.motion = MotionPreference.system,
    this.scalePercent = 100,
    this.language = AppLanguage.system,
  });

  final ThemePreference theme;
  final double fontBase;
  final MotionPreference motion;
  final int scalePercent;

  /// 界面语言。同时决定 WebView 里 DSH 页面的语言。
  final AppLanguage language;

  AppearanceState copyWith({
    ThemePreference? theme,
    double? fontBase,
    MotionPreference? motion,
    int? scalePercent,
    AppLanguage? language,
  }) => AppearanceState(
    theme: theme ?? this.theme,
    fontBase: fontBase ?? this.fontBase,
    motion: motion ?? this.motion,
    scalePercent: scalePercent ?? this.scalePercent,
    language: language ?? this.language,
  );

  /// 转成设置页用的模型。
  AppearanceSettings toSettings() => AppearanceSettings(
    theme: theme,
    fontBase: fontBase,
    motion: motion,
    scalePercent: scalePercent,
    // ⚠ 漏了这行会导致「设置页选了语言但没生效」：
    // 设置页回传的是 AppearanceSettings，经 fromSettings 转回状态时
    // 缺字段就被丢弃，状态看起来没变。
    language: language,
  );

  /// 从设置页的模型接收。
  static AppearanceState fromSettings(AppearanceSettings s) => AppearanceState(
    theme: s.theme,
    fontBase: s.fontBase,
    motion: s.motion,
    scalePercent: s.scalePercent,
    language: s.language,
  );

  Map<String, Object?> toJson() => {
    'theme': theme.name,
    'fontBase': fontBase,
    'motion': motion.name,
    'scalePercent': scalePercent,
    'language': language.name,
  };

  static AppearanceState fromJson(Map<String, Object?> json) {
    T byName<T extends Enum>(List<T> values, Object? name, T fallback) {
      if (name is! String) return fallback;
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    final font = json['fontBase'];
    final scale = json['scalePercent'];
    return AppearanceState(
      theme: byName(ThemePreference.values, json['theme'], ThemePreference.system),
      language: byName(AppLanguage.values, json['language'], AppLanguage.system),
      fontBase: font is num
          ? font.toDouble().clamp(
              AppearanceSettings.minFont,
              AppearanceSettings.maxFont,
            )
          : 16,
      motion: byName(MotionPreference.values, json['motion'], MotionPreference.system),
      scalePercent: scale is num
          ? scale.toInt().clamp(
              AppearanceSettings.minScale,
              AppearanceSettings.maxScale,
            )
          : 100,
    );
  }

  /// 实际生效的亮度。
  ///
  /// `system` 跟随平台（`Theme.of` 的 `platformBrightness`）。
  Brightness resolveBrightness(Brightness platform) => switch (theme) {
    ThemePreference.light => Brightness.light,
    ThemePreference.dark => Brightness.dark,
    ThemePreference.system => platform,
  };

  /// 是否应减弱动效。
  bool resolveReduceMotion(bool systemPrefersReduced) => switch (motion) {
    MotionPreference.reduced => true,
    MotionPreference.system => systemPrefersReduced,
  };

  @override
  bool operator ==(Object other) =>
      other is AppearanceState &&
      other.theme == theme &&
      other.fontBase == fontBase &&
      other.motion == motion &&
      other.scalePercent == scalePercent &&
      // 漏掉 language 会让「只改语言」被判为无变化，界面不重建
      other.language == language;

  @override
  int get hashCode =>
      Object.hash(theme, fontBase, motion, scalePercent, language);
}

/// 外观设置的读写。
///
/// 用 `dart:io` 写文件（桌面/移动）；Web 上不可用，静默跳过。
/// 正式版应换成 `shared_preferences` 或原生 KV —— 这里保持零依赖，
/// 与传输层的取舍一致。
class AppearanceStore {
  AppearanceStore({this.filePath});

  final String? filePath;

  File? get _file {
    final p = filePath;
    if (p == null) return null;
    return File(p);
  }

  Future<AppearanceState> load() async {
    final f = _file;
    if (f == null || !f.existsSync()) return const AppearanceState();
    try {
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const AppearanceState();
      return AppearanceState.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      // 读取失败不阻断启动，回默认值。
      return const AppearanceState();
    }
  }

  Future<void> save(AppearanceState state) async {
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(state.toJson()));
    } catch (_) {
      // 写入失败不阻断交互。
    }
  }
}
