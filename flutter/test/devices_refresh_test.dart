import 'dart:io';

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/ui/devices_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const first = PairedDevice(
  id: 'first',
  name: 'First computer',
  origin: 'first:443',
  reachability: DeviceReachability.reachable,
  isCurrent: true,
);
const second = PairedDevice(
  id: 'second',
  name: 'Second computer',
  origin: 'second:443',
  reachability: DeviceReachability.unreachable,
);

Widget host(Widget child) => AppLocaleScope(
  language: AppLanguage.zh,
  child: AppTheme(
    tokens: Tokens.light,
    text: AppTextStyles(Tokens.light, 16),
    child: MaterialApp(home: child),
  ),
);

void main() {
  testWidgets('current and other device menus dispatch the selected identity', (
    tester,
  ) async {
    PairedDevice? selected;
    await tester.pumpWidget(
      host(
        DevicesPage(
          devices: const [first, second],
          onOpenActions: (device) => selected = device,
        ),
      ),
    );
    final menus = find.byIcon(Icons.more_horiz);
    expect(menus, findsNWidgets(2));
    await tester.tap(menus.first);
    expect(selected?.id, first.id);
    await tester.tap(menus.last);
    expect(selected?.id, second.id);
  });

  testWidgets(
    'pushed device route refreshes after add, switch and removal without reentering',
    (tester) async {
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      var devices = <PairedDevice>[first];
      late BuildContext homeContext;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              homeContext = context;
              return const Scaffold(body: Text('Home'));
            },
          ),
        ),
      );
      Navigator.of(homeContext).push<void>(
        MaterialPageRoute(
          builder: (_) => AnimatedBuilder(
            animation: changes,
            builder: (_, _) => DevicesPage(devices: devices),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final originalRoute = ModalRoute.of(
        tester.element(find.byType(DevicesPage)),
      );
      devices = [first, second];
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(second.name), findsOneWidget);
      devices = [
        const PairedDevice(
          id: 'first',
          name: 'First computer',
          origin: 'first:443',
          reachability: DeviceReachability.unreachable,
        ),
        const PairedDevice(
          id: 'second',
          name: 'Second computer',
          origin: 'second:443',
          reachability: DeviceReachability.reachable,
          isCurrent: true,
        ),
      ];
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DevicesPage>(find.byType(DevicesPage))
            .devices
            .singleWhere((d) => d.isCurrent)
            .id,
        second.id,
      );
      devices = [];
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('还没有配对电脑'), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(DevicesPage))),
        same(originalRoute),
      );
    },
  );

  testWidgets(
    'add and revoke actions respond, missing menu callback is disabled',
    (tester) async {
      var added = 0;
      var revoked = 0;
      await tester.pumpWidget(
        host(
          DevicesPage(
            devices: const [second],
            onAdd: () => added++,
            onRevokeAll: () => revoked++,
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.add));
      expect(added, 1);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.more_horiz),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('撤销本机全部配对'));
      await tester.tap(find.text('撤销本机全部配对'));
      expect(revoked, 1);
    },
  );

  test('shell wires live updates, selected reconnect and action menu', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('animation: _deviceChanges'));
    expect(
      source,
      contains('onOpenActions: _connecting ? null : _openDeviceActions'),
    );
    expect(
      source,
      contains('onReconnect: _connecting ? null : _reconnectDevice'),
    );
    expect(source, contains('_reconnect(credential: credential)'));
    expect(source, contains('flow.reconnect(credential)'));
    expect(source, isNot(contains('.reconnect(_credentials.first)')));
    expect(source, contains('_connectionRequests.invalidate();'));
  });
}
