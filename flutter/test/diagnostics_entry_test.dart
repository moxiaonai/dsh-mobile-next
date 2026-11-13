/// 设备页「连接诊断」入口 + 诊断页返回按钮的回归测试。
///
/// 背景：0.1.5 的设备页把 `onDiagnostics` 一直传成 `null`，按钮渲染成灰态
/// 根本点不动，用户以为「诊断功能坏了」；而诊断页本身又是被 push 上来的
/// 二级页却没有返回按钮，只能靠系统手势。两条都容易在重构时再次丢掉，
/// 所以这里各锁一条。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/ui/devices_page.dart';
import 'package:dsh_mobile/src/ui/diagnostics_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/tokens.dart';

Widget _host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(
      home: AppLocaleScope(language: AppLanguage.zh, child: child),
    ),
  );
}

const _device = PairedDevice(
  id: 'd1',
  name: 'A',
  origin: '192.168.0.102:3444',
  reachability: DeviceReachability.reachable,
  isCurrent: true,
);

void main() {
  testWidgets('设备页：接了 onDiagnostics 后「连接诊断」可点击', (tester) async {
    PairedDevice? tapped;
    await tester.pumpWidget(
      _host(
        DevicesPage(
          devices: const [_device],
          onDiagnostics: (d) => tapped = d,
        ),
      ),
    );

    final btn = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '连接诊断'),
    );
    expect(btn.onPressed, isNotNull, reason: '按钮是灰的就是接线漏了');

    await tester.tap(find.widgetWithText(OutlinedButton, '连接诊断'));
    await tester.pump();
    expect(tapped?.id, 'd1', reason: '应把被点的设备传回上层');
  });

  testWidgets('设备页：没接线时按钮禁用（不假装能点）', (tester) async {
    await tester.pumpWidget(_host(const DevicesPage(devices: [_device])));
    final btn = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '连接诊断'),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('诊断页：传了 onBack 就显示返回按钮，点一下回到上一页', (tester) async {
    var popped = 0;
    await tester.pumpWidget(
      _host(DiagnosticsPage(report: null, onBack: () => popped++)),
    );

    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(popped, 1);
  });

  testWidgets('诊断页：底部 tab 直接展示时不显示返回按钮', (tester) async {
    await tester.pumpWidget(_host(const DiagnosticsPage(report: null)));
    expect(find.byIcon(Icons.chevron_left), findsNothing);
  });
}
