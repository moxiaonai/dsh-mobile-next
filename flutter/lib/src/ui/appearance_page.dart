/// 设置 / 外观页。对齐 `docs/10-ui-spec.md` §5.8。
///
/// 关键规格：
/// - Segmented 3 段，轨道 sunken，选中卡白 + `--e-1`；每段 min-height 44
/// - Stepper：`[−]` 44×44、值 48 宽 tabular-nums、`[+]` 44×44；
///   边界处按钮 disabled（字号 12–32；缩放 80–125）
/// - 字号生效**不重载页面**，不打断草稿
/// - 页面缩放行只在原生能力声明时渲染（未声明则**整行不渲染**，不显示灰行）
library;

import 'package:flutter/material.dart';

import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme;
import 'tokens.dart';

/// 主题偏好。
enum ThemePreference {
  system('跟随系统'),
  light('浅色'),
  dark('深色');

  const ThemePreference(this.label);
  final String label;
}

/// 动效偏好。
enum MotionPreference {
  system('跟随系统'),
  reduced('始终减弱');

  const MotionPreference(this.label);
  final String label;
}

/// 外观设置。
class AppearanceSettings {
  const AppearanceSettings({
    this.theme = ThemePreference.system,
    this.fontBase = 16,
    this.scalePercent = 100,
    this.motion = MotionPreference.system,
    this.language = AppLanguage.system,
  });

  final ThemePreference theme;

  /// 界面语言。
  final AppLanguage language;

  /// 正文字号（12–32）。
  final double fontBase;

  /// 页面缩放百分比（80–125）。
  final int scalePercent;

  final MotionPreference motion;

  AppearanceSettings copyWith({
    ThemePreference? theme,
    double? fontBase,
    int? scalePercent,
    MotionPreference? motion,
    AppLanguage? language,
  }) => AppearanceSettings(
    language: language ?? this.language,
    theme: theme ?? this.theme,
    fontBase: fontBase ?? this.fontBase,
    scalePercent: scalePercent ?? this.scalePercent,
    motion: motion ?? this.motion,
  );

  static const double minFont = 12;
  static const double maxFont = 32;
  static const int minScale = 80;
  static const int maxScale = 125;
  static const int scaleStep = 5;

  bool get isDefault =>
      theme == ThemePreference.system &&
      fontBase == 16 &&
      scalePercent == 100 &&
      motion == MotionPreference.system;
}

/// 设置页。
class AppearancePage extends StatelessWidget {
  const AppearancePage({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onReset,
    this.scaleSupported = false,
    this.title,
    this.deviceCount,
    this.onOpenDevices,
  });

  final AppearanceSettings settings;
  final ValueChanged<AppearanceSettings> onChanged;
  final VoidCallback? onReset;

  /// 原生 bridge 是否声明了 `appearance.scale`。
  ///
  /// spec：未声明则**整行不渲染**，不显示灰行。
  final bool scaleSupported;

  /// 页面标题；为空时用当前语言的默认值。
  final String? title;

  /// 已配对设备数（0 时显示「去配对」）。
  final int? deviceCount;

  /// 打开设备管理（从 tab 降为设置页里的一项 —— 配对是低频操作）。
  final VoidCallback? onOpenDevices;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final s = AppStrings.of(context);

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.s7,
            Space.s6,
            Space.s7,
            Space.s12,
          ),
          children: [
            Text(title ?? s('appearance.title'), style: txt.h1),
            const SizedBox(height: Space.s7),

            _label(s('appearance.theme'), t, txt),
            _Segmented<ThemePreference>(
              values: ThemePreference.values,
              selected: settings.theme,
              labelOf: (v) => themeLabel(s, v),
              onChanged: (v) => onChanged(settings.copyWith(theme: v)),
            ),

            const SizedBox(height: Space.s8),
            _label(s('appearance.language'), t, txt),
            _Segmented<AppLanguage>(
              values: AppLanguage.values,
              selected: settings.language,
              labelOf: (v) => languageLabel(s, v),
              onChanged: (v) => onChanged(settings.copyWith(language: v)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: Space.s3),
              child: Text(
                s('appearance.language.hint'),
                style: txt.caption,
              ),
            ),

            const SizedBox(height: Space.s8),
            _label(s('appearance.font'), t, txt),
            _StepperRow(
              label: s('appearance.font.label'),
              hint: s('appearance.font.hint'),
              value: settings.fontBase.round().toString(),
              canDec:
                  settings.fontBase > AppearanceSettings.minFont,
              canInc:
                  settings.fontBase < AppearanceSettings.maxFont,
              onDec: () => onChanged(
                settings.copyWith(
                  fontBase: (settings.fontBase - 1).clamp(
                    AppearanceSettings.minFont,
                    AppearanceSettings.maxFont,
                  ),
                ),
              ),
              onInc: () => onChanged(
                settings.copyWith(
                  fontBase: (settings.fontBase + 1).clamp(
                    AppearanceSettings.minFont,
                    AppearanceSettings.maxFont,
                  ),
                ),
              ),
            ),

            if (scaleSupported) ...[
              const SizedBox(height: Space.s6),
              _StepperRow(
                label: s('appearance.scale'),
                hint: s('appearance.scale.hint'),
                value: '${settings.scalePercent}%',
                canDec:
                    settings.scalePercent > AppearanceSettings.minScale,
                canInc:
                    settings.scalePercent < AppearanceSettings.maxScale,
                onDec: () => onChanged(
                  settings.copyWith(
                    scalePercent: (settings.scalePercent -
                            AppearanceSettings.scaleStep)
                        .clamp(
                          AppearanceSettings.minScale,
                          AppearanceSettings.maxScale,
                        ),
                  ),
                ),
                onInc: () => onChanged(
                  settings.copyWith(
                    scalePercent: (settings.scalePercent +
                            AppearanceSettings.scaleStep)
                        .clamp(
                          AppearanceSettings.minScale,
                          AppearanceSettings.maxScale,
                        ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: Space.s8),
            _label(s('appearance.motion'), t, txt),
            _Segmented<MotionPreference>(
              values: MotionPreference.values,
              selected: settings.motion,
              labelOf: (v) => motionLabel(s, v),
              onChanged: (v) => onChanged(settings.copyWith(motion: v)),
            ),

            if (onOpenDevices != null) ...[
              const SizedBox(height: Space.s9),
              _label(s('devices.title'), t, txt),
              InkWell(
                onTap: onOpenDevices,
                borderRadius: Radii.rMd,
                child: Container(
                  constraints: const BoxConstraints(minHeight: Hit.min),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.s5,
                    vertical: Space.s4,
                  ),
                  decoration: BoxDecoration(
                    color: t.bgCard,
                    borderRadius: Radii.rMd,
                    border: Border.all(color: t.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.devices_outlined,
                        size: 18,
                        color: t.textSecondary,
                      ),
                      const SizedBox(width: Space.s4),
                      Expanded(
                        child: Text(
                          (deviceCount ?? 0) > 0
                              ? s.withArgs('devices.pairedCount', {
                                  'n': deviceCount ?? 0,
                                })
                              : s('devices.add'),
                          style: txt.body,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: t.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: Space.s9),
            _label(s('appearance.preview'), t, txt),
            Container(
              padding: const EdgeInsets.all(Space.s6),
              decoration: BoxDecoration(
                color: t.bgCard,
                borderRadius: Radii.rMd,
                border: Border.all(color: t.borderSubtle),
              ),
              child: Text(
                s('appearance.preview.sample'),
                // 实时反映字号
                style: txt.body.copyWith(fontSize: settings.fontBase),
              ),
            ),

            const SizedBox(height: Space.s9),
            SizedBox(
              height: Hit.min,
              child: OutlinedButton(
                onPressed: settings.isDefault ? null : onReset,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.textSecondary,
                  side: BorderSide(color: t.borderSubtle),
                ),
                child: Text(s('appearance.reset')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text, Tokens t, AppTextStyles txt) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s3),
    child: Text(
      text,
      style: txt.chrome.copyWith(color: t.textSecondary),
    ),
  );
}

/// 分段控件（spec：轨道 sunken，选中卡白 + e-1，每段 ≥44）。
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.bgSunken,
        borderRadius: Radii.rMd,
      ),
      child: Row(
        children: [
          for (final v in values)
            Expanded(
              child: Semantics(
                selected: v == selected,
                inMutuallyExclusiveGroup: true,
                button: true,
                child: GestureDetector(
                  onTap: () => onChanged(v),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: Hit.min),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == selected ? t.bgCard : Colors.transparent,
                      borderRadius: Radii.rSm,
                      boxShadow: v == selected
                          ? const [
                              BoxShadow(
                                color: Color(0x0F0F172A),
                                blurRadius: 2,
                                offset: Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      labelOf(v),
                      style: txt.chrome.copyWith(
                        color: v == selected
                            ? t.textPrimary
                            : t.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 步进行：`[−]` 44 / 值 48 / `[+]` 44。
class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.label,
    required this.value,
    required this.canDec,
    required this.canInc,
    required this.onDec,
    required this.onInc,
    this.hint,
  });

  final String label;
  final String value;
  final bool canDec;
  final bool canInc;
  final VoidCallback onDec;
  final VoidCallback onInc;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Space.s6,
        Space.s3,
        Space.s3,
        Space.s3,
      ),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: Radii.rMd,
        border: Border.all(color: t.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(label, style: txt.body),
                if (hint != null) ...[
                  const SizedBox(height: Space.s1),
                  Text(hint!, style: txt.caption),
                ],
              ],
            ),
          ),
          _stepButton(Icons.remove, canDec, onDec, t),
          SizedBox(
            width: 48,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: txt.body.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          _stepButton(Icons.add, canInc, onInc, t),
        ],
      ),
    );
  }

  Widget _stepButton(
    IconData icon,
    bool enabled,
    VoidCallback onTap,
    Tokens t,
  ) => SizedBox(
    width: Hit.min,
    height: Hit.min,
    child: IconButton(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18),
      color: t.accent,
      disabledColor: t.disabledText,
      tooltip: icon == Icons.add ? '增加' : '减少',
    ),
  );
}


// ── 枚举 → 多语言标签 ──
//
// 枚举自带的 `label` 是硬编码中文（`跟随系统`/`浅色`…），
// 直接显示会在英文界面里漏出中文。这里统一走 AppStrings。

/// 主题选项的显示名。
String themeLabel(AppStrings s, ThemePreference v) => switch (v) {
  ThemePreference.system => s('appearance.theme.system'),
  ThemePreference.light => s('appearance.theme.light'),
  ThemePreference.dark => s('appearance.theme.dark'),
};

/// 语言选项的显示名。
///
/// 语言名用**各自的语言**书写（`简体中文` / `English`），不随界面语言变化 ——
/// 否则英文界面下「中文」会显示成 Chinese，用户反而不好找。
String languageLabel(AppStrings s, AppLanguage v) => v.label;

/// 动效选项的显示名。
String motionLabel(AppStrings s, MotionPreference v) => switch (v) {
  MotionPreference.system => s('appearance.motion.system'),
  MotionPreference.reduced => s('appearance.motion.reduced'),
};
