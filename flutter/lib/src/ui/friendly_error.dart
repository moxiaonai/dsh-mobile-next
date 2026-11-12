/// 把技术异常翻译成用户能看懂的话。
///
/// ## 为什么需要
///
/// 直接把异常 `toString()` 显示给用户是不可接受的：
///
/// ```
/// SocketException: Connection refused (OS Error: Connection refused,
/// errno = 111), address = 10.0.2.2, port = 59852
/// ```
///
/// 普通用户看到这行字既不知道发生了什么，也不知道该做什么。
///
/// ## 设计
///
/// 每个错误给三样东西：
/// - **标题**：一句话说清发生了什么
/// - **建议**：用户能做什么
/// - **技术细节**：折叠起来给排查用，默认不显示
///
/// 分类依据是实测见过的错误形态，不猜测：
/// - `SocketException` / `Connection refused` → 电脑端没开或代理没起
/// - `TimeoutException` → 网络慢或电脑忙
/// - `401` / `authentication_failed` → 凭据失效
/// - `gateway/*` → DSH 协议层错误
library;

import 'dart:async';
import 'dart:io';

import '../app_strings.dart';

/// 一类可展示的错误。
class FriendlyError {
  const FriendlyError({
    required this.title,
    required this.hint,
    required this.detail,
    this.retryable = true,
  });

  /// 一句话说清发生了什么。
  final String title;

  /// 用户能做什么。
  final String hint;

  /// 技术细节（折叠显示，用于排查）。
  final String detail;

  /// 是否值得重试。
  final bool retryable;

  /// 从任意异常推断。
  static FriendlyError from(Object error, [AppStrings? strings]) {
    // 未传时用中文（保持旧调用点的行为）
    final s = strings ?? AppStrings.forLanguage(AppLanguage.zh);
    final raw = error.toString();

    // ── 连接类 ──────────────────────────────────────────
    //
    // 顺序要紧：`Network is unreachable` 同样是 SocketException，
    // 若先判 `error is SocketException` 会被「连不上电脑」抢先匹配，
    // 而它实际是**本机网络断了**，建议完全不同。所以更具体的先判。
    if (raw.contains('Network is unreachable') || raw.contains('errno = 101')) {
      return FriendlyError(
        title: s('err.network.title'),
        hint: s('err.network.hint'),
        detail: '',
      );
    }

    if (error is SocketException ||
        raw.contains('Connection refused') ||
        raw.contains('errno = 111')) {
      return FriendlyError(
        title: s('err.connect.title'),
        hint: s('err.connect.hint'),
        detail: raw,
      );
    }

    if (error is TimeoutException ||
        raw.contains('TimeoutException') ||
        raw.contains('timed out')) {
      return FriendlyError(
        title: s('err.timeout.title'),
        hint: s('err.timeout.hint'),
        detail: '',
      );
    }

    // ── 鉴权类 ──────────────────────────────────────────
    if (raw.contains('401') || raw.contains('authentication_failed')) {
      return FriendlyError(
        title: s('err.auth.title'),
        hint: s('err.auth.hint'),
        detail: '',
        retryable: false,
      );
    }

    if (raw.contains('403') || raw.contains('forbidden')) {
      return FriendlyError(
        title: s('err.rejected.title'),
        hint: s('err.rejected.hint'),
        detail: '',
      );
    }

    // ── 协议类 ──────────────────────────────────────────
    if (raw.contains('gateway/')) {
      final code = RegExp(r'gateway/[a-z-]+').firstMatch(raw)?.group(0) ?? '';
      return FriendlyError(
        title: s('err.host.title'),
        hint: s('err.host.hint'),
        detail: code.isEmpty ? raw : code,
      );
    }

    if (raw.contains('mux is not connected') ||
        raw.contains(s('err.mux.title'))) {
      return FriendlyError(
        title: s('err.mux.title'),
        hint: s('err.mux.hint'),
        detail: '',
      );
    }

    // ── 兜底 ────────────────────────────────────────────
    return FriendlyError(
      title: s('err.generic.title'),
      hint: s('err.generic.hint'),
      detail: raw,
    );
  }
}
