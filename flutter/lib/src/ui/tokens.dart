/// 设计 token —— 逐值对齐 `docs/10-ui-spec.md` §2 / §14。
///
/// **不发明数值**：这里的每个颜色、间距、圆角、动效时长都能在 spec 里找到出处。
/// 唯一新增的是 Flutter 侧的类型包装（`Color` / `Duration` / `EdgeInsets`）。
///
/// 双主题：`Tokens.light` / `Tokens.dark`，暗色值同样取自 spec。
library;

import 'package:flutter/material.dart';

@immutable
class Tokens {
  const Tokens({
    required this.brightness,
    required this.bgCanvas,
    required this.bgCard,
    required this.bgSunken,
    required this.bgHover,
    required this.bgPressed,
    required this.bgScrim,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.borderSubtle,
    required this.borderStrong,
    required this.accent,
    required this.accentPressed,
    required this.onAccent,
    required this.accentWeakBg,
    required this.accentWeakText,
    required this.success,
    required this.successDot,
    required this.successWeakBg,
    required this.warn,
    required this.warnDot,
    required this.warnWeakBg,
    required this.danger,
    required this.onDanger,
    required this.dangerWeakBg,
    required this.disabledText,
    required this.disabledBg,
  });

  final Brightness brightness;

  // 表面
  final Color bgCanvas;
  final Color bgCard;
  final Color bgSunken;
  final Color bgHover;
  final Color bgPressed;
  final Color bgScrim;

  // 文字
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  // 边框
  final Color borderSubtle;
  final Color borderStrong;

  // 品牌
  final Color accent;
  final Color accentPressed;
  final Color onAccent;
  final Color accentWeakBg;
  final Color accentWeakText;

  // 状态
  final Color success;
  final Color successDot;
  final Color successWeakBg;
  final Color warn;
  final Color warnDot;
  final Color warnWeakBg;
  final Color danger;
  final Color onDanger;
  final Color dangerWeakBg;
  final Color disabledText;
  final Color disabledBg;

  bool get isDark => brightness == Brightness.dark;

  /// 浅色主题。值来自 `10-ui-spec.md` §14。
  static const Tokens light = Tokens(
    brightness: Brightness.light,
    bgCanvas: Color(0xFFF7F8FA),
    bgCard: Color(0xFFFFFFFF),
    bgSunken: Color(0xFFEEF0F4),
    bgHover: Color(0xFFF1F3F6),
    bgPressed: Color(0xFFE9ECF1),
    bgScrim: Color(0x66151F2A),
    textPrimary: Color(0xFF111827),
    textSecondary: Color(0xFF5A6474),
    textTertiary: Color(0xFF667085),
    borderSubtle: Color(0xFFE4E7EC),
    borderStrong: Color(0xFF8A93A3),
    accent: Color(0xFF2563EB),
    accentPressed: Color(0xFF1D4ED8),
    onAccent: Color(0xFFFFFFFF),
    accentWeakBg: Color(0xFFEFF4FF),
    accentWeakText: Color(0xFF1D4ED8),
    success: Color(0xFF166534),
    successDot: Color(0xFF15803D),
    successWeakBg: Color(0xFFE8F5EC),
    warn: Color(0xFF92400E),
    warnDot: Color(0xFFB45309),
    warnWeakBg: Color(0xFFFFF8E7),
    danger: Color(0xFFB91C1C),
    onDanger: Color(0xFFFFFFFF),
    dangerWeakBg: Color(0xFFFDECEC),
    disabledText: Color(0xFF8A93A3),
    disabledBg: Color(0xFFF1F3F6),
  );

  /// 暗色主题。值来自 `10-ui-spec.md` §2.1 的 dark 列
  /// （与 `reference/design-system/dsh-mobile/MASTER.md` 的原生暗色一致）。
  static const Tokens dark = Tokens(
    brightness: Brightness.dark,
    bgCanvas: Color(0xFF0F172A),
    bgCard: Color(0xFF1E293B),
    bgSunken: Color(0xFF162034),
    bgHover: Color(0xFF243349),
    bgPressed: Color(0xFF2C3E57),
    bgScrim: Color(0x99000000),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFFCBD5E1),
    textTertiary: Color(0xFF94A3B8),
    borderSubtle: Color(0xFF334155),
    borderStrong: Color(0xFF64748B),
    accent: Color(0xFF60A5FA),
    accentPressed: Color(0xFF3B82F6),
    onAccent: Color(0xFF0F172A),
    accentWeakBg: Color(0xFF1E3A5F),
    accentWeakText: Color(0xFF93C5FD),
    success: Color(0xFF4ADE80),
    successDot: Color(0xFF22C55E),
    successWeakBg: Color(0xFF14321F),
    warn: Color(0xFFFBBF24),
    warnDot: Color(0xFFF59E0B),
    warnWeakBg: Color(0xFF3A2A0C),
    danger: Color(0xFFFCA5A5),
    onDanger: Color(0xFF0F172A),
    dangerWeakBg: Color(0xFF3B1717),
    disabledText: Color(0xFF64748B),
    disabledBg: Color(0xFF1E293B),
  );
}

/// 间距。`--s-N` 逐值对应。
abstract final class Space {
  static const double s1 = 2;
  static const double s2 = 4;
  static const double s3 = 6;
  static const double s4 = 8;
  static const double s5 = 10;
  static const double s6 = 12;
  static const double s7 = 14;
  static const double s8 = 16;
  static const double s9 = 20;
  static const double s10 = 24;
  static const double s12 = 32;
  static const double s14 = 40;
  static const double s16 = 48;
  static const double s20 = 64;
}

/// 圆角。`--r-N` 逐值对应。
///
/// 命名避开 Flutter 内置的 `Radius`（`dart:ui` 里的类）。
abstract final class Radii {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double full = 999;

  static const BorderRadius rSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius rMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius rLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius rFull = BorderRadius.all(Radius.circular(full));
}

/// 动效时长。`--m-N` 逐值对应。
abstract final class Motion {
  static const Duration instant = Duration.zero;
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 180);
  static const Duration slow = Duration(milliseconds: 240);

  /// `--m-ease: cubic-bezier(.22, 1, .36, 1)`
  static const Curve ease = Cubic(0.22, 1, 0.36, 1);

  /// `--m-ease-exit: cubic-bezier(.4, 0, 1, 1)`
  static const Curve easeExit = Cubic(0.4, 0, 1, 1);

  /// 状态 pill 的脉冲周期（`--m-pulse: 1200ms`）。
  static const Duration pulse = Duration(milliseconds: 1200);
}

/// 命中区下限。spec §4.3：Web ≥44，主操作 48；原生 ≥48dp。
abstract final class Hit {
  static const double min = 44;
  static const double primary = 48;
}

/// 字号阶梯。`--t-*` 由 `--font-base` 派生，这里以 16 为基准。
///
/// 实际渲染时用 [typeScale] 按用户字号偏好缩放。
abstract final class TypeScale {
  static const double displayRatio = 1.75;
  static const double h1Ratio = 1.375;
  static const double h2Ratio = 1.125;
  static const double h3Ratio = 1.0;
  static const double bodyRatio = 1.0;
  static const double captionRatio = 0.8125;
  static const double chromeRatio = 0.75;

  /// 正文行高倍率（spec：`--t-body` 24/16 = 1.5）。
  static const double bodyLineHeight = 1.5;
  static const double headingLineHeight = 1.375;
}

/// 基于 [fontBase] 生成完整的文字样式集合。
///
/// 用户字号偏好在设置页调整（12–32），因此不能把字号写死在 TextStyle 里。
class AppTextStyles {
  const AppTextStyles(this.tokens, this.fontBase);

  final Tokens tokens;
  final double fontBase;

  double _sz(double ratio) => fontBase * ratio;

  TextStyle get display => TextStyle(
    fontSize: _sz(TypeScale.displayRatio),
    height: TypeScale.headingLineHeight,
    fontWeight: FontWeight.w600,
    color: tokens.textPrimary,
  );

  TextStyle get h1 => TextStyle(
    fontSize: _sz(TypeScale.h1Ratio),
    height: TypeScale.headingLineHeight,
    fontWeight: FontWeight.w600,
    color: tokens.textPrimary,
  );

  TextStyle get h2 => TextStyle(
    fontSize: _sz(TypeScale.h2Ratio),
    height: TypeScale.headingLineHeight,
    fontWeight: FontWeight.w600,
    color: tokens.textPrimary,
  );

  TextStyle get h3 => TextStyle(
    fontSize: _sz(TypeScale.h3Ratio),
    height: 1.5,
    fontWeight: FontWeight.w600,
    color: tokens.textPrimary,
  );

  TextStyle get body => TextStyle(
    fontSize: _sz(TypeScale.bodyRatio),
    height: TypeScale.bodyLineHeight,
    color: tokens.textPrimary,
  );

  TextStyle get caption => TextStyle(
    fontSize: _sz(TypeScale.captionRatio),
    height: 1.4,
    color: tokens.textTertiary,
  );

  /// 计时等数字要用等宽数字，避免跳动。
  TextStyle get captionTabular => caption.copyWith(
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  TextStyle get chrome => TextStyle(
    fontSize: _sz(TypeScale.chromeRatio),
    height: 1.33,
    fontWeight: FontWeight.w600,
    color: tokens.textSecondary,
  );
}
