/// 会话页布局回归：分组头的箭头必须贴着卡片右边缘。
///
/// ## 为什么需要这条测试
///
/// 组头最初写成 `Flexible(标题) + Spacer() + 箭头`。`Flexible` 是 flex 子项，
/// 会和 `Spacer` 平分自由空间 —— 标题只占自己的宽度，但它的 flex 份额已经
/// 被分配出去，于是箭头被顶离右边缘约 70dp（1080px 宽屏上偏了 190px）。
///
/// 视觉上第一眼「箭头在右边」，肉眼看截图不容易发现，所以用像素位置锁住：
/// 箭头中心到屏幕右沿的距离必须小于 40dp（= 右内边距 10dp + 半个图标 11dp
/// + 宽容度）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/protocol/sessions.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/sessions_page.dart';
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

SessionSummary _sess(String id, String title) => SessionSummary(
  id: id,
  title: title,
  cwd: '/Users/x/proj',
  updatedAt: DateTime.now(),
);

void main() {
  testWidgets('分组头箭头贴右边缘（展开态）', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionsPage(
          listSessions: () async => [_sess('s1', '第一个会话')],
          listWorkspaces: () async => WorkspaceSnapshot(
            items: [
              const Workspace(
                id: 'w1',
                path: '/Users/x/proj',
                title: 'proj',
                sessionIds: ['s1'],
              ),
            ],
            archivedSessionIds: const {},
            pinnedSessionIds: const {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final screen = tester.getSize(find.byType(MaterialApp)).width;
    final chevron = find.byIcon(Icons.expand_more);
    expect(chevron, findsOneWidget);
    final gap = screen - tester.getCenter(chevron).dx;
    expect(
      gap,
      lessThan(40),
      reason: '箭头离右沿 $gap dp —— Flexible+Spacer 把箭头挤到中间了',
    );
  });

  testWidgets('分组头箭头贴右边缘（收起态）', (tester) async {
    await tester.pumpWidget(
      _host(
        SessionsPage(
          listSessions: () async => [_sess('s1', '第一个会话')],
          listWorkspaces: () async => WorkspaceSnapshot(
            items: [
              const Workspace(
                id: 'w1',
                path: '/Users/x/proj',
                title: 'proj',
                sessionIds: ['s1'],
              ),
            ],
            archivedSessionIds: const {},
            pinnedSessionIds: const {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 收起该组：整个列表只剩组头一张卡。箭头是 rotate(-90°) 的
    // expand_more（视觉上就是右向 chevron），所以按展开态同一个图标找。
    await tester.tap(find.text('proj'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('第一个会话'), findsNothing, reason: '收起后行应消失');

    final screen = tester.getSize(find.byType(MaterialApp)).width;
    final chevron = find.byIcon(Icons.expand_more);
    expect(chevron, findsOneWidget);
    final gap = screen - tester.getCenter(chevron).dx;
    expect(
      gap,
      lessThan(40),
      reason: '收起态箭头离右沿 $gap dp',
    );
  });
}
