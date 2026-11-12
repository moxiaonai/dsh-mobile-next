/// 配对页。对齐 `docs/10-ui-spec.md` §5.6。
///
/// 四步单页流程：扫码 → 校验 → 完成（3 段步骤条，高 4，r-full）。
///
/// **安全文案必须在屏上**（spec：trust is visible）：
/// 校验步骤固定显示「只连接你自己电脑上的 DSH。配对后手机可操作电脑上的全部会话。」
///
/// **不伪造相机**：`idle` 态取景框内只显示静态说明文字，没有相机预览。
/// 相机是原生能力，本页只负责 UI 状态机。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_strings.dart';
import '../auth/pairing.dart';
import 'job_widgets.dart' show AppTheme, EmptyState;
import 'tokens.dart';

/// 配对阶段。
enum PairingStage {
  scan,
  verify,
  done;

  /// 多语言标签（枚举不能持有运行时值）。
  String label(AppStrings strings) => switch (this) {
    PairingStage.scan => strings('pair.step.scan'),
    PairingStage.verify => strings('pair.step.verify'),
    PairingStage.done => strings('pair.step.done'),
  };
}

/// 配对页状态。
enum PairingState {
  /// 等待扫码。
  idle,

  /// 请求相机权限中。
  requestingPermission,

  /// 权限被拒。
  permissionDenied,

  /// 扫描中。
  scanning,

  /// 校验电脑身份中。
  verifying,

  /// 配对成功。
  success,

  /// 配对码过期。
  expired,

  /// 失败。
  failed,
}

/// 配对页。
class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.onPair,
    this.onOpenSettings,
    this.onEnterApp,
    this.onRetry,
    this.initialState = PairingState.idle,
    this.onBack,
    this.title,
    this.onCancel,
  });

  /// 用解析出的描述符执行配对。抛异常即视为失败。
  final Future<PairingResult> Function(PairingDescriptor d) onPair;

  /// 「去系统设置」。
  final VoidCallback? onOpenSettings;

  /// 成功后「进入任务」。
  final VoidCallback? onEnterApp;

  /// 重试。
  final VoidCallback? onRetry;

  final PairingState initialState;

  /// 返回。为 null 时不显示返回按钮。
  ///
  /// 本页是被 push 打开的，没有返回入口用户就出不去 —— 实测踩过。
  final VoidCallback? onBack;

  /// 页面标题；为空时用当前语言的默认值。
  final String? title;
  final VoidCallback? onCancel;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  late PairingState _state = widget.initialState;

  /// 扫码控制器。懒创建：只有真正进入扫码态才申请相机权限。
  MobileScannerController? _scanner;

  /// 一次扫码只处理一次（相机回调会连续触发）。
  bool _scanHandled = false;

  String _linkInput = '';
  String? _linkError;
  String? _errorText;
  PairingResult? _result;
  String? _descriptorLabel;
  String? _fingerprint;
  int _generation = 0;

  PairingStage get _stage => switch (_state) {
    PairingState.idle ||
    PairingState.requestingPermission ||
    PairingState.permissionDenied ||
    PairingState.scanning => PairingStage.scan,
    PairingState.verifying => PairingStage.verify,
    PairingState.success => PairingStage.done,
    PairingState.expired || PairingState.failed => PairingStage.scan,
  };

  Future<void> _submitLink() async {
    setState(() {
      _linkError = null;
      _errorText = null;
    });
    final PairingDescriptor d;
    try {
      d = PairingDescriptor.parse(_linkInput);
    } on PairingException catch (e) {
      setState(() => _linkError = e.message);
      return;
    }
    await _runPair(d);
  }

  Future<void> _runPair(PairingDescriptor d) async {
    final generation = ++_generation;
    _fingerprint = d.iroh?.metadata.fingerprint;
    setState(() {
      _state = PairingState.verifying;
      _descriptorLabel = d.instanceId;
    });
    try {
      final r = await widget.onPair(d);
      if (!mounted || generation != _generation) return;
      setState(() {
        _result = r;
        _state = PairingState.success;
      });
    } on PairingException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = e.statusCode == 401
            ? PairingState.expired
            : PairingState.failed;
        _errorText = e.message;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _state = PairingState.failed;
        _errorText = '$e';
      });
    }
  }

  @override
  void dispose() {
    ++_generation;
    widget.onCancel?.call();
    _scanner?.dispose();
    _scanner = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);

    return Scaffold(
      backgroundColor: t.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TopBar(
              title: widget.title ?? AppStrings.of(context)('pair.title'),
              onBack: widget.onBack,
              t: t,
              txt: txt,
            ),
            _StepBar(stage: _stage, t: t, txt: txt),
            const SizedBox(height: Space.s8),
            Expanded(child: _content(t, txt)),
          ],
        ),
      ),
    );
  }

  Widget _content(Tokens t, AppTextStyles txt) {
    switch (_state) {
      case PairingState.permissionDenied:
        return Column(
          children: [
            const Expanded(
              child: EmptyState(
                title: '无法使用相机',
                body: '可以在系统设置里授予相机权限，或改用链接配对。',
                icon: Icons.no_photography_outlined,
              ),
            ),
            _secondary('去系统设置', widget.onOpenSettings, t),
            _secondary(AppStrings.of(context)('pair.useLink'), () {
              setState(() => _state = PairingState.idle);
            }, t),
            const SizedBox(height: Space.s7),
          ],
        );

      case PairingState.verifying:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s7),
          child: Column(
            children: [
              const SizedBox(height: Space.s9),
              const CircularProgressIndicator(),
              const SizedBox(height: Space.s7),
              Text('正在校验电脑身份…', style: txt.h3),
              const SizedBox(height: Space.s6),
              // spec：显示证书指纹后 6 位 + 安装标识前 8 位，供肉眼比对。
              // 指纹字段名未证实（ASSUMPTION），有则显示，无则整块不渲染。
              if (_descriptorLabel != null && _descriptorLabel!.isNotEmpty)
                _kv(
                  '安装标识',
                  '${_descriptorLabel!.substring(0, _descriptorLabel!.length.clamp(0, 8))}…',
                  t,
                  txt,
                ),
              if (_fingerprint != null)
                _kv('CA SHA-256', _fingerprint!.substring(58), t, txt),
              const Spacer(),
              _securityNote(t, txt),
              const SizedBox(height: Space.s7),
            ],
          ),
        );

      case PairingState.success:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s7),
          child: Column(
            children: [
              const SizedBox(height: Space.s9),
              Icon(Icons.check_circle, size: 48, color: t.successDot),
              const SizedBox(height: Space.s6),
              Text(AppStrings.of(context)('pair.success'), style: txt.h1),
              const SizedBox(height: Space.s3),
              Text(
                _result?.deviceId == null
                    ? '已连接电脑'
                    : '设备 ${_result!.deviceId.substring(0, 8)}…',
                style: txt.caption,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: Hit.primary,
                child: FilledButton(
                  onPressed: widget.onEnterApp,
                  style: FilledButton.styleFrom(
                    backgroundColor: t.accent,
                    foregroundColor: t.onAccent,
                  ),
                  child: Text(AppStrings.of(context)('pair.enterApp')),
                ),
              ),
              const SizedBox(height: Space.s7),
            ],
          ),
        );

      case PairingState.expired:
        return Column(
          children: [
            const Expanded(
              child: EmptyState(
                title: '配对码已过期',
                body: '请回到电脑上重新生成二维码。',
                icon: Icons.timer_off_outlined,
              ),
            ),
            _primary('重新扫码', widget.onRetry, t, txt),
            const SizedBox(height: Space.s7),
          ],
        );

      case PairingState.failed:
        return Column(
          children: [
            Expanded(
              child: EmptyState(
                title: AppStrings.of(context)('pair.failed'),
                body: _errorText ?? '请重试，或改用链接配对。',
                icon: Icons.error_outline,
              ),
            ),
            _primary(
              AppStrings.of(context)('pair.retry'),
              widget.onRetry,
              t,
              txt,
            ),
            const SizedBox(height: Space.s3),
            _secondary(AppStrings.of(context)('pair.useLink'), () {
              setState(() => _state = PairingState.idle);
            }, t),
            const SizedBox(height: Space.s7),
          ],
        );

      case PairingState.idle:
      case PairingState.requestingPermission:
      case PairingState.scanning:
        return _scanContent(t, txt);
    }
  }

  /// 真正可用的扫码视图。
  ///
  /// 之前这里是个静态占位框：点「打开相机」只改了一下 `_state`，
  /// 根本没有相机预览，也没有识别 —— 用户以为在扫码，其实什么也没发生。
  /// 现在接 `mobile_scanner`：进入扫码态即申请权限并出预览。
  Widget _scannerView(Tokens t, AppTextStyles txt) {
    final controller = _scanner ??= MobileScannerController(
      // 配对码是二维码，限制格式能显著减少误识别
      formats: const [BarcodeFormat.qrCode],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );

    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: Radii.rLg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) {
                // 权限被拒 / 无相机：给可操作的替代路径，而不是黑屏
                return ColoredBox(
                  color: t.bgSunken,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.s7),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.no_photography_outlined,
                            size: 28,
                            color: t.textTertiary,
                          ),
                          const SizedBox(height: Space.s4),
                          Text(
                            AppStrings.of(context)('pair.cameraUnavailable'),
                            style: txt.h3,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: Space.s3),
                          Text(
                            '请在系统设置里允许相机权限，\n或直接用下面的「粘贴配对链接」。',
                            style: txt.caption,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            // 取景框：只是视觉引导，不拦截触摸
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    border: Border.all(color: t.onAccent, width: 2),
                    borderRadius: Radii.rMd,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 识别到二维码。
  ///
  /// 相机回调会连续触发，`_scanHandled` 保证只处理第一条 ——
  /// 否则会对同一个码连发多次配对请求。
  void _onDetect(BarcodeCapture capture) {
    if (_scanHandled) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;

    final PairingDescriptor d;
    try {
      d = PairingDescriptor.parse(raw);
    } on PairingException catch (e) {
      // 扫到了别的东西：提示但不锁定，允许继续扫
      setState(() => _linkError = e.message);
      return;
    }
    _scanHandled = true;
    // 立刻停掉相机，省电且避免重复识别
    _scanner?.stop();
    unawaited(_runPair(d));
  }

  Widget _scanContent(Tokens t, AppTextStyles txt) {
    final scanning = _state == PairingState.scanning;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: Space.s7),
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, c) {
              final side = c.maxWidth.clamp(0.0, 240.0);
              return SizedBox(
                width: side,
                height: side,
                child: scanning
                    ? _scannerView(t, txt)
                    : Container(
                        decoration: BoxDecoration(
                          color: t.bgSunken,
                          borderRadius: Radii.rLg,
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(Space.s8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.qr_code_scanner,
                                  size: 40,
                                  color: t.textTertiary,
                                ),
                                const SizedBox(height: Space.s4),
                                Text(
                                  '点下面的按钮打开相机\n扫描电脑上的配对二维码',
                                  textAlign: TextAlign.center,
                                  style: txt.caption,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              );
            },
          ),
        ),
        const SizedBox(height: Space.s6),
        Center(
          child: Text(
            scanning
                ? AppStrings.of(context)('pair.scanHint')
                : AppStrings.of(context)('pair.idle'),
            style: txt.caption,
          ),
        ),
        const SizedBox(height: Space.s7),
        _primary(
          scanning
              ? AppStrings.of(context)('pair.stopScan')
              : AppStrings.of(context)('pair.openCamera'),
          () => setState(() {
            if (scanning) {
              _scanner?.stop();
              _state = PairingState.idle;
            } else {
              _scanHandled = false;
              _linkError = null;
              _state = PairingState.scanning;
            }
          }),
          t,
          txt,
        ),
        const SizedBox(height: Space.s4),
        Text(
          AppStrings.of(context)('pair.pasteLink'),
          style: txt.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Space.s3),
        TextField(
          onChanged: (v) => setState(() {
            _linkInput = v;
            _linkError = null;
          }),
          keyboardType: TextInputType.url,
          style: txt.body.copyWith(fontSize: 16),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'https://…/mobile-access/pair#token=…',
            hintStyle: txt.caption,
            filled: true,
            fillColor: t.bgSunken,
            constraints: const BoxConstraints(minHeight: 48),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Space.s5,
              vertical: Space.s5,
            ),
            border: OutlineInputBorder(
              borderRadius: Radii.rMd,
              borderSide: BorderSide.none,
            ),
            errorText: _linkError,
            errorStyle: txt.caption.copyWith(color: t.danger),
          ),
        ),
        const SizedBox(height: Space.s4),
        _primary(
          AppStrings.of(context)('pair.submit'),
          _linkInput.trim().isEmpty ? null : _submitLink,
          t,
          txt,
        ),
        const SizedBox(height: Space.s7),
        _securityNote(t, txt),
        const SizedBox(height: Space.s9),
      ],
    );
  }

  Widget _securityNote(Tokens t, AppTextStyles txt) => Container(
    padding: const EdgeInsets.all(Space.s5),
    decoration: BoxDecoration(color: t.bgSunken, borderRadius: Radii.rMd),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.shield_outlined, size: 16, color: t.textSecondary),
        const SizedBox(width: Space.s3),
        Expanded(
          child: Text(
            '只连接你自己电脑上的 DSH。配对后手机可操作电脑上的全部会话。',
            style: txt.caption.copyWith(color: t.textSecondary),
          ),
        ),
      ],
    ),
  );

  Widget _kv(String k, String v, Tokens t, AppTextStyles txt) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('$k ', style: txt.caption),
        Text(
          v,
          style: txt.caption.copyWith(
            color: t.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );

  Widget _primary(
    String label,
    VoidCallback? onTap,
    Tokens t,
    AppTextStyles txt,
  ) => SizedBox(
    width: double.infinity,
    height: Hit.primary,
    child: FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        disabledBackgroundColor: t.disabledBg,
        disabledForegroundColor: t.disabledText,
      ),
      child: Text(label),
    ),
  );

  Widget _secondary(String label, VoidCallback? onTap, Tokens t) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Space.s7),
    child: SizedBox(
      width: double.infinity,
      height: Hit.min,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: t.textSecondary,
          side: BorderSide(color: t.borderSubtle),
        ),
        child: Text(label),
      ),
    ),
  );
}

/// 顶部：返回按钮 + 标题。
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.t,
    required this.txt,
  });

  final String title;
  final VoidCallback? onBack;
  final Tokens t;
  final AppTextStyles txt;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: EdgeInsets.only(
        left: onBack == null ? Space.s7 : Space.s2,
        right: Space.s7,
      ),
      child: Row(
        children: [
          if (onBack != null)
            SizedBox(
              width: Hit.min,
              height: Hit.min,
              child: IconButton(
                onPressed: onBack,
                icon: Icon(Icons.chevron_left, color: t.textSecondary),
                tooltip: AppStrings.of(context)('pair.back'),
              ),
            ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: txt.h1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 3 段步骤条。
///
/// 布局要点：进度段与标签**同宽对齐**（都用 Expanded），
/// 段之间留 8px 间距且标签居中对齐到段 —— 否则视觉上会错位。
class _StepBar extends StatelessWidget {
  const _StepBar({required this.stage, required this.t, required this.txt});

  final PairingStage stage;
  final Tokens t;
  final AppTextStyles txt;

  static const double _gap = Space.s4;

  @override
  Widget build(BuildContext context) {
    final idx = stage.index;
    final labels = PairingStage.values;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.s7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 进度段
          Row(
            children: [
              for (var i = 0; i < labels.length; i++) ...[
                if (i > 0) const SizedBox(width: _gap),
                Expanded(
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: i <= idx ? t.accent : t.bgSunken,
                      borderRadius: Radii.rFull,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Space.s3),
          // 标签：与进度段同宽，当前步加粗
          Row(
            children: [
              for (var i = 0; i < labels.length; i++) ...[
                if (i > 0) const SizedBox(width: _gap),
                Expanded(
                  child: Text(
                    labels[i].label(AppStrings.of(context)),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: txt.caption.copyWith(
                      color: i == idx
                          ? t.accent
                          : i < idx
                          ? t.textSecondary
                          : t.textTertiary,
                      fontWeight: i == idx ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
