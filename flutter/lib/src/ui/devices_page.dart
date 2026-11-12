/// 设备页。对齐 `docs/10-ui-spec.md` §5.3。
///
/// **可达四态**（沿用 reference 语义，不新造）：
///
/// | 状态 | 点 | 文案 |
/// | --- | --- | --- |
/// | 可达 | success 实心 | `可达 · 延迟约 12ms` |
/// | 检测中 | accent 脉冲 | `检测中` |
/// | 暂不可达 | tertiary 空心环 | `暂不可达 · 最后连接 …` |
/// | 已移除/已过期 | tertiary 空心环 | `电脑端已移除` / `配对已过期` |
///
/// **延迟口径**（spec 明确）：`DERIVED:` 值必须带「约」；
/// 拿不到时**不显示延迟**，不显示 `--ms`。
library;

import 'package:flutter/material.dart';

import '../app_strings.dart';
import 'job_widgets.dart' show AppTheme, PulseDot;
import 'tokens.dart';

/// 设备可达状态。
enum DeviceReachability {
  reachable,
  checking,
  unreachable,
  revoked,
  expired;

  /// 多语言标签。
  ///
  /// 枚举不能持有依赖 `BuildContext` 的值（const 构造要求编译期常量），
  /// 因此把「状态」和「文案」拆开：枚举只做标识，文案在这里映射。
  String label(AppStrings strings) => switch (this) {
    DeviceReachability.reachable => strings('devices.reachable'),
    DeviceReachability.checking => strings('devices.checking'),
    DeviceReachability.unreachable => strings('devices.unreachable'),
    DeviceReachability.revoked => strings('devices.removed'),
    DeviceReachability.expired => strings('devices.expired'),
  };
}

/// 一台已配对电脑。
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.origin,
    required this.reachability,
    this.via = DeviceChannel.lan,
    this.latencyMs,
    this.lastSeen,
    this.isCurrent = false,
  });

  final String id;
  final String name;
  final String origin;
  final DeviceReachability reachability;
  final DeviceChannel via;

  /// 延迟（毫秒）。`null` 表示拿不到 —— **不要显示占位符**。
  final int? latencyMs;

  final DateTime? lastSeen;
  final bool isCurrent;
}

enum DeviceChannel {
  lan,
  remote;

  /// 多语言标签（枚举不能持有运行时值，见 DeviceReachability 的说明）。
  String label(AppStrings strings) => switch (this) {
    DeviceChannel.lan => strings('devices.lan'),
    DeviceChannel.remote => strings('devices.remote'),
  };
}

/// 设备页。
class DevicesPage extends StatelessWidget {
  const DevicesPage({
    super.key,
    required this.devices,
    this.onReconnect,
    this.onDiagnostics,
    this.onAdd,
    this.onRevokeAll,
    this.onOpenActions,
    this.title,
    this.onBack,
  });

  final List<PairedDevice> devices;
  final void Function(PairedDevice d)? onReconnect;
  final void Function(PairedDevice d)? onDiagnostics;
  final VoidCallback? onAdd;
  final VoidCallback? onRevokeAll;

  /// 「…」动作面板（重命名/检测/置顶/重新配对/删除）。
  final void Function(PairedDevice d)? onOpenActions;

  /// 页面标题；为空时用当前语言的默认值。
  final String? title;

  /// 返回上一页。
  ///
  /// 设备页现在是从设置页 push 打开的二级页面（原先是 tab），
  /// 没有返回入口用户就退不出去 —— 只能靠系统手势，很不明显。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final current = devices.where((d) => d.isCurrent).toList();
    final others = devices.where((d) => !d.isCurrent).toList();

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
            Row(
              children: [
                if (onBack != null)
                  IconButton(
                    onPressed: onBack,
                    icon: const Icon(Icons.chevron_left),
                    color: t.textSecondary,
                    tooltip: AppStrings.of(context)('common.back'),
                    constraints: const BoxConstraints(
                      minWidth: Hit.min,
                      minHeight: Hit.min,
                    ),
                  ),
                Expanded(
                  child: Text(
                    title ?? AppStrings.of(context)('devices.title'),
                    style: txt.h1,
                  ),
                ),
                // 顶部常驻「添加」入口：不用滚到底部才找得到
                if (onAdd != null)
                  IconButton(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    color: t.accent,
                    tooltip: AppStrings.of(context)('devices.add'),
                    constraints: const BoxConstraints(
                      minWidth: Hit.min,
                      minHeight: Hit.min,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Space.s6),

            for (final d in current) ...[
              _DeviceCard(
                device: d,
                onReconnect: onReconnect == null
                    ? null
                    : () => onReconnect!(d),
                onDiagnostics: onDiagnostics == null
                    ? null
                    : () => onDiagnostics!(d),
              ),
              const SizedBox(height: Space.s6),
            ],

            if (others.isNotEmpty) ...[
              _groupHeader(AppStrings.of(context)('devices.others'), t, txt),
              for (final d in others) ...[
                _DeviceRow(
                  device: d,
                  onTap: () => onOpenActions?.call(d),
                  onReconnect: onReconnect == null
                      ? null
                      : () => onReconnect!(d),
                ),
                const SizedBox(height: Space.s4),
              ],
            ],

            if (devices.isEmpty) ...[
              const SizedBox(height: Space.s8),
              Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.devices_other_outlined,
                      size: 40,
                      color: t.textTertiary,
                    ),
                    const SizedBox(height: Space.s4),
                    Text(
                      AppStrings.of(context)('devices.empty'),
                      style: txt.h3,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: Space.s3),
                    Text(
                      AppStrings.of(context)('devices.emptyHint'),
                      style: txt.caption,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],
            if (onAdd != null) ...[
              const SizedBox(height: Space.s6),
              SizedBox(
                height: Hit.primary,
                child: OutlinedButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: Text(AppStrings.of(context)('devices.add')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.accent,
                    side: BorderSide(color: t.borderSubtle),
                  ),
                ),
              ),
            ],

            const SizedBox(height: Space.s9),
            _groupHeader(AppStrings.of(context)('devices.security'), t, txt),
            SizedBox(
              height: Hit.min,
              child: OutlinedButton(
                onPressed: onRevokeAll,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.danger,
                  side: BorderSide(color: t.borderSubtle),
                ),
                child: Text(AppStrings.of(context)('devices.revokeAll')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(String title, Tokens t, AppTextStyles txt) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s4),
    child: Text(
      title,
      style: txt.chrome.copyWith(color: t.textSecondary),
    ),
  );
}

/// 可达状态点。
class _ReachDot extends StatelessWidget {
  const _ReachDot({required this.state, required this.color});

  final DeviceReachability state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final (t, _) = AppTheme.of(context);
    if (state == DeviceReachability.checking) {
      return PulseDot(color: t.accent);
    }
    if (state == DeviceReachability.reachable) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    }
    // 空心环：暂不可达 / 已移除 / 已过期
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
    );
  }
}

/// 状态文案。
///
/// **延迟口径**：有值才显示，且必须带「约」；没有就不显示。
String _statusLine(PairedDevice d, AppStrings strings) {
  switch (d.reachability) {
    case DeviceReachability.reachable:
      if (d.latencyMs != null) {
        return strings.withArgs('devices.reachableLatency', {'n': d.latencyMs!});
      }
      return strings('devices.reachable');
    case DeviceReachability.checking:
      return strings('devices.checking');
    case DeviceReachability.unreachable:
      final last = d.lastSeen == null
          ? null
          : formatRelativeTime(strings, d.lastSeen!);
      return last == null
          ? strings('devices.unreachable')
          : strings.withArgs('devices.unreachableLast', {'t': last});
    case DeviceReachability.revoked:
      return strings('devices.removedRepair');
    case DeviceReachability.expired:
      return strings('devices.expiredRepair');
  }
}


class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    this.onReconnect,
    this.onDiagnostics,
  });

  final PairedDevice device;
  final VoidCallback? onReconnect;
  final VoidCallback? onDiagnostics;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);
    final stateColor = switch (device.reachability) {
      DeviceReachability.reachable => t.successDot,
      DeviceReachability.checking => t.accent,
      _ => t.textTertiary,
    };

    return Container(
      padding: const EdgeInsets.all(Space.s7),
      decoration: BoxDecoration(
        color: t.bgCard,
        borderRadius: Radii.rLg,
        border: Border.all(color: t.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ReachDot(state: device.reachability, color: stateColor),
              const SizedBox(width: Space.s3),
              Expanded(
                child: Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: txt.h3,
                ),
              ),
              Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: Space.s3),
                decoration: BoxDecoration(
                  color: t.accentWeakBg,
                  borderRadius: Radii.rSm,
                ),
                alignment: Alignment.center,
                child: Text(
                  AppStrings.of(context)('devices.current'),
                  style: txt.chrome.copyWith(
                    color: t.accentWeakText,
                    fontSize: txt.fontBase * 0.7,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s3),
          Text(
            '${device.via.label(AppStrings.of(context))} · ${device.origin}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: txt.caption,
          ),
          const SizedBox(height: Space.s2),
          Text(_statusLine(device, strings), style: txt.caption),
          const SizedBox(height: Space.s6),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Hit.primary,
                  child: FilledButton(
                    onPressed: onReconnect,
                    style: FilledButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: t.onAccent,
                    ),
                    child: Text(AppStrings.of(context)('devices.reconnect')),
                  ),
                ),
              ),
              const SizedBox(width: Space.s4),
              Expanded(
                child: SizedBox(
                  height: Hit.primary,
                  child: OutlinedButton(
                    onPressed: onDiagnostics,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: t.textSecondary,
                      side: BorderSide(color: t.borderSubtle),
                    ),
                    child: Text(AppStrings.of(context)('devices.diagnostics')),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    this.onTap,
    this.onReconnect,
  });

  final PairedDevice device;
  final VoidCallback? onTap;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);
    final dead =
        device.reachability == DeviceReachability.revoked ||
        device.reachability == DeviceReachability.expired;
    final stateColor = device.reachability == DeviceReachability.reachable
        ? t.successDot
        : t.textTertiary;

    return Material(
      color: t.bgCard,
      borderRadius: Radii.rLg,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rLg,
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.s7,
            vertical: Space.s5,
          ),
          decoration: BoxDecoration(
            borderRadius: Radii.rLg,
            border: Border.all(color: t.borderSubtle),
          ),
          child: Row(
            children: [
              _ReachDot(state: device.reachability, color: stateColor),
              const SizedBox(width: Space.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // 已移除的设备用弱化色（不靠删除线）
                            style: txt.body.copyWith(
                              color: dead ? t.textTertiary : t.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: Space.s3),
                        Container(
                          height: 20,
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.s3,
                          ),
                          decoration: BoxDecoration(
                            color: t.bgSunken,
                            borderRadius: Radii.rSm,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            device.via.label(AppStrings.of(context)),
                            style: txt.chrome.copyWith(
                              color: t.textSecondary,
                              fontSize: txt.fontBase * 0.68,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.s1),
                    Text(
                      _statusLine(device, strings),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: txt.caption,
                    ),
                  ],
                ),
              ),
              if (dead && onReconnect != null)
                TextButton(
                  onPressed: onReconnect,
                  child: Text(AppStrings.of(context)('devices.repair')),
                )
              else
                SizedBox(
                  width: Hit.min,
                  height: Hit.min,
                  child: IconButton(
                    onPressed: onTap,
                    icon: Icon(Icons.more_horiz, color: t.textTertiary),
                    tooltip: AppStrings.of(context)('devices.more'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
