/// 其余 6 个屏幕的 widget 测试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/protocol/sessions.dart';
import 'package:dsh_mobile/src/app_strings.dart';
import 'package:dsh_mobile/src/ui/appearance_page.dart';
import 'package:dsh_mobile/src/ui/devices_page.dart';
import 'package:dsh_mobile/src/ui/diagnostics_page.dart';
import 'package:dsh_mobile/src/ui/inbox_page.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/pairing_page.dart';
import 'package:dsh_mobile/src/ui/session_tasks_page.dart';
import 'package:dsh_mobile/src/ui/sessions_page.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

Widget host(Widget child) {
  final t = Tokens.light;
  // 包 AppLocaleScope：否则 AppStrings.of 回退到英文，
  // 而本文件断言的是中文文案。
  return AppTheme(
      tokens: t,
      text: AppTextStyles(t, 16),
      child: MaterialApp(
        home: AppLocaleScope(language: AppLanguage.zh, child: child),
      ),
  );
}

SessionSummary sess(
  String id, {
  String? title,
  bool running = false,
  bool agent = false,
  bool blank = false,
  String? cwd = '/Users/x/proj',
  DateTime? updatedAt,
}) =>
    SessionSummary(
      id: id,
      title: title,
      running: running,
      agentAvailable: agent,
      blank: blank,
      cwd: cwd,
      updatedAt:
          updatedAt ??
          DateTime.now().subtract(const Duration(minutes: 5)),
    );

void main() {
  sessionNavTests();
  pairingTopBarTests();
  blankSessionTests();

  sessionGroupingTests();
  archivedFilterTests();

  group('会话页', () {
    testWidgets('渲染分组与行', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [
              sess('s1', title: '重构支付'),
              sess('s2', title: '修复登录'),
            ],
            listWorkspaces: () async => WorkspaceSnapshot(items: [
              const Workspace(
                id: 'w1',
                path: '/x/proj',
                title: 'dsh-web',
                sessionIds: ['s1', 's2'],
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

      expect(find.text('dsh-web'), findsOneWidget);
      expect(find.text('重构支付'), findsOneWidget);
      expect(find.text('修复登录'), findsOneWidget);
    });

    testWidgets('搜索过滤', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [
              sess('s1', title: '重构支付'),
              sess('s2', title: '修复登录'),
            ],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField), '支付');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('重构支付'), findsOneWidget);
      expect(find.text('修复登录'), findsNothing);
    });

    testWidgets('空状态', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => const [],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('暂无会话'), findsOneWidget);
    });
  });

  group('设备页', () {
    testWidgets('渲染当前设备卡与其他电脑', (tester) async {
      await tester.pumpWidget(
        host(
          DevicesPage(
            devices: [
              const PairedDevice(
                id: 'd1',
                name: 'MacBook Pro',
                origin: '192.168.1.5:3443',
                reachability: DeviceReachability.reachable,
                latencyMs: 12,
                isCurrent: true,
              ),
              PairedDevice(
                id: 'd2',
                name: 'Studio',
                origin: 'remote',
                reachability: DeviceReachability.unreachable,
                via: DeviceChannel.remote,
                lastSeen: DateTime.now().subtract(const Duration(days: 2)),
              ),
            ],
          ),
        ),
      );
      expect(find.text('MacBook Pro'), findsOneWidget);
      expect(find.text('当前'), findsOneWidget);
      expect(find.text('其他电脑'), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget);
    });

    testWidgets('延迟带「约」，无值时不显示', (tester) async {
      await tester.pumpWidget(
        host(
          DevicesPage(
            devices: [
              const PairedDevice(
                id: 'd1',
                name: 'A',
                origin: 'x',
                reachability: DeviceReachability.reachable,
                latencyMs: 12,
                isCurrent: true,
              ),
            ],
          ),
        ),
      );
      expect(find.textContaining('延迟约 12ms'), findsOneWidget);

      await tester.pumpWidget(
        host(
          DevicesPage(
            devices: [
              const PairedDevice(
                id: 'd1',
                name: 'A',
                origin: 'x',
                reachability: DeviceReachability.reachable,
                isCurrent: true,
              ),
            ],
          ),
        ),
      );
      // 无 latencyMs 时只显示「可达」，不显示 --ms
      expect(find.text('可达'), findsOneWidget);
      expect(find.textContaining('--ms'), findsNothing);
    });

    testWidgets('已移除设备显示重新配对', (tester) async {
      await tester.pumpWidget(
        host(
          DevicesPage(
            devices: [
              const PairedDevice(
                id: 'd1',
                name: '旧机',
                origin: 'x',
                reachability: DeviceReachability.revoked,
              ),
            ],
            onReconnect: (_) {},
          ),
        ),
      );
      expect(find.textContaining('电脑端已移除'), findsOneWidget);
      expect(find.text('重新配对'), findsOneWidget);
    });
  });

  group('外观页', () {
    testWidgets('渲染所有区块', (tester) async {
      await tester.pumpWidget(
        host(
          AppearancePage(
            settings: const AppearanceSettings(),
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('主题'), findsOneWidget);
      expect(find.text('跟随系统'), findsWidgets);
      expect(find.text('字号'), findsOneWidget);
      expect(find.text('16'), findsOneWidget);
      expect(find.textContaining('预览'), findsWidgets);
      expect(find.text('恢复默认'), findsOneWidget);
    });

    testWidgets('缩放行默认不渲染', (tester) async {
      await tester.pumpWidget(
        host(
          AppearancePage(
            settings: const AppearanceSettings(),
            onChanged: (_) {},
          ),
        ),
      );
      expect(find.text('页面缩放'), findsNothing);
    });

    testWidgets('声明能力后渲染缩放行', (tester) async {
      await tester.pumpWidget(
        host(
          AppearancePage(
            settings: const AppearanceSettings(),
            onChanged: (_) {},
            scaleSupported: true,
          ),
        ),
      );
      expect(find.text('页面缩放'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('字号边界禁用', (tester) async {
      await tester.pumpWidget(
        host(
          AppearancePage(
            settings: const AppearanceSettings(
              fontBase: AppearanceSettings.maxFont,
            ),
            onChanged: (_) {},
          ),
        ),
      );
      // 上限时 [+] 禁用
      final addBtn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.add),
      );
      expect(addBtn.onPressed, isNull);
    });

    testWidgets('默认状态下恢复按钮禁用', (tester) async {
      await tester.pumpWidget(
        host(
          AppearancePage(
            settings: const AppearanceSettings(),
            onChanged: (_) {},
          ),
        ),
      );
      final btn = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '恢复默认'),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('通知中心', () {
    testWidgets('七个筛选 chip（全部 + 六类）', (tester) async {
      await tester.pumpWidget(
        host(const InboxPage(entries: [])),
      );
      // 全部 + 问题/计划/审批/回复/目标/失败
      expect(find.text('全部'), findsOneWidget);
      for (final c in InboxCategory.values) {
        expect(find.text(c.label(AppStrings.forLanguage(AppLanguage.zh))),
            findsOneWidget);
      }
    });

    testWidgets('不显示问题正文（脱敏）', (tester) async {
      await tester.pumpWidget(
        host(
          InboxPage(
            entries: [
              InboxEntry(
                id: 'n1',
                category: InboxCategory.question,
                sessionId: 's1',
                sessionTitle: '重构支付',
                at: DateTime.now(),
              ),
            ],
          ),
        ),
      );
      // 只显示类别 + 会话标题
      expect(find.textContaining('问题 · 重构支付'), findsOneWidget);
    });

    testWidgets('空状态', (tester) async {
      await tester.pumpWidget(host(const InboxPage(entries: [])));
      expect(find.text('暂无通知'), findsOneWidget);
    });
  });

  group('配对页', () {
    testWidgets('idle 显示取景框与安全文案', (tester) async {
      await tester.pumpWidget(
        host(PairingPage(onPair: (_) async => throw UnimplementedError())),
      );
      expect(find.text('打开相机'), findsOneWidget);
      expect(find.textContaining('只连接你自己电脑上的 DSH'), findsOneWidget);
      expect(find.text('扫码'), findsOneWidget);
    });

    testWidgets('权限被拒显示替代路径', (tester) async {
      await tester.pumpWidget(
        host(
          PairingPage(
            onPair: (_) async => throw UnimplementedError(),
            initialState: PairingState.permissionDenied,
          ),
        ),
      );
      expect(find.text('无法使用相机'), findsOneWidget);
      expect(find.text('去系统设置'), findsOneWidget);
      expect(find.text('改用链接配对'), findsOneWidget);
    });

    testWidgets('过期态', (tester) async {
      await tester.pumpWidget(
        host(
          PairingPage(
            onPair: (_) async => throw UnimplementedError(),
            initialState: PairingState.expired,
          ),
        ),
      );
      expect(find.text('配对码已过期'), findsOneWidget);
    });

    testWidgets('链接解析失败显示错误行', (tester) async {
      await tester.pumpWidget(
        host(PairingPage(onPair: (_) async => throw UnimplementedError())),
      );
      await tester.enterText(find.byType(TextField), 'not-a-url');
      await tester.pump();
      await tester.tap(find.text('配对'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 错误显示在框下方，不弹模态
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('诊断页', () {
    DiagnosticReport report() => DiagnosticReport(
      generatedAt: DateTime.now(),
      layers: [
        const DiagnosticLayer(
          title: '版本信息',
          checks: [
            DiagnosticCheck(label: '插件 0.8.6 · DSH 0.1.5', status: CheckStatus.ok),
          ],
        ),
        DiagnosticLayer(
          title: '手机路径',
          checks: [phonePathCheck(AppStrings.forLanguage(AppLanguage.zh))],
        ),
      ],
    );

    testWidgets('渲染分层与结论', (tester) async {
      await tester.pumpWidget(
        host(DiagnosticsPage(report: report())),
      );
      expect(find.text('版本信息'), findsOneWidget);
      expect(find.text('手机路径'), findsOneWidget);
      expect(find.textContaining('项通过'), findsOneWidget);
    });

    testWidgets('手机路径永远是 info，不显示 ✓', (tester) async {
      final c = phonePathCheck(AppStrings.forLanguage(AppLanguage.zh));
      expect(c.status, CheckStatus.info);
      expect(c.label, contains('需在手机上验证'));
    });

    testWidgets('无报告时复制按钮禁用', (tester) async {
      await tester.pumpWidget(host(const DiagnosticsPage(report: null)));
      final btn = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '复制报告'),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('运行中主按钮禁用且文案变化', (tester) async {
      await tester.pumpWidget(
        host(DiagnosticsPage(report: report(), running: true)),
      );
      expect(find.text('检查中…'), findsOneWidget);
      final btn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '检查中…'),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('报告脱敏：不含凭据', (tester) async {
      final text = report().toPlainText();
      expect(text, contains('已脱敏'));
      expect(text, isNot(contains('token')));
      expect(text, isNot(contains('cookie')));
    });
  });
}

// ───────────────────────── 会话详情导航 ─────────────────────────

void sessionNavTests() {
  group('会话详情导航', () {
    testWidgets('点击会话行触发 onOpen', (tester) async {
      SessionSummary? opened;
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [sess('s1', title: '可点会话')],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
            onOpen: (s) => opened = s,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('可点会话'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(opened, isNotNull);
      expect(opened!.id, 's1');
    });
  });
}


// ───────────────────── 空白会话处理 ─────────────────────

void blankSessionTests() {
  group('空白会话', () {
    testWidgets('会话列表过滤 blank 会话', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [
              sess('blank1', title: null, blank: true),
              sess('real1', title: '有内容的会话'),
            ],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('有内容的会话'), findsOneWidget);
      // 空白会话不应出现在列表
      expect(find.textContaining('blank1'), findsNothing);
    });

    testWidgets('任务列表同样过滤 blank', (tester) async {
      await tester.pumpWidget(
        host(
          SessionTasksPage(
            listSessions: () async => [
              sess('blank1', title: null, blank: true),
              sess('real1', title: '真实任务', running: true),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('真实任务'), findsOneWidget);
      expect(find.textContaining('blank1'), findsNothing);
    });
  });
}

// ───────────────────── 配对页顶部 ─────────────────────

void pairingTopBarTests() {
  group('配对页顶部', () {
    testWidgets('有 onBack 时显示返回按钮', (tester) async {
      var backed = false;
      await tester.pumpWidget(
        host(
          PairingPage(
            onPair: (_) async => throw UnimplementedError(),
            onBack: () => backed = true,
          ),
        ),
      );
      expect(find.byTooltip('返回'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pump();
      expect(backed, isTrue);
    });

    testWidgets('无 onBack 时不显示返回', (tester) async {
      await tester.pumpWidget(
        host(PairingPage(onPair: (_) async => throw UnimplementedError())),
      );
      expect(find.byTooltip('返回'), findsNothing);
    });

    testWidgets('三步标签全部渲染', (tester) async {
      await tester.pumpWidget(
        host(
          PairingPage(
            onPair: (_) async => throw UnimplementedError(),
            onBack: () {},
          ),
        ),
      );
      expect(find.text('扫码'), findsOneWidget);
      expect(find.text('校验'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('当前步标签加粗且用 accent 色', (tester) async {
      await tester.pumpWidget(
        host(
          PairingPage(
            onPair: (_) async => throw UnimplementedError(),
            onBack: () {},
            initialState: PairingState.verifying,
          ),
        ),
      );
      // 校验阶段：第 2 步为当前
      final label = tester.widget<Text>(find.text('校验'));
      expect(label.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('返回按钮命中区 ≥44', (tester) async {
      await tester.pumpWidget(
        host(
          PairingPage(
            onPair: (_) async => throw UnimplementedError(),
            onBack: () {},
          ),
        ),
      );
      final size = tester.getSize(find.byTooltip('返回'));
      expect(size.height, greaterThanOrEqualTo(Hit.min));
    });

    testWidgets('标题与返回按钮不重叠', (tester) async {
      await tester.pumpWidget(
        host(
          PairingPage(
            onPair: (_) async => throw UnimplementedError(),
            onBack: () {},
          ),
        ),
      );
      final backRect = tester.getRect(find.byTooltip('返回'));
      final titleRect = tester.getRect(find.text('添加电脑'));
      expect(
        backRect.right,
        lessThanOrEqualTo(titleRect.left),
        reason: '返回按钮与标题不应重叠',
      );
    });
  });
}

// ── 会话分组折叠 ──
//
// 覆盖：默认展开、点击收起/展开、多组独立、搜索强制展开、
// 组头命中区与语义、未归类组本地化、注入恢复。
void sessionGroupingTests() {
  /// 两个 workspace，各有会话。
  Widget twoGroups({
    Set<String>? initialCollapsed,
    ValueChanged<Set<String>>? onCollapsedChanged,
  }) => host(
    SessionsPage(
      listSessions: () async => [
        sess('s1', title: '重构支付', cwd: '/repo/web'),
        sess('s2', title: '修复登录', cwd: '/repo/web'),
        sess('s3', title: '优化接口', cwd: '/repo/api'),
      ],
      listWorkspaces: () async => const WorkspaceSnapshot(
        items: [
          Workspace(
            id: 'w1',
            path: '/repo/web',
            title: 'dsh-web',
            sessionIds: ['s1', 's2'],
          ),
          Workspace(
            id: 'w2',
            path: '/repo/api',
            title: 'dsh-api',
            sessionIds: ['s3'],
          ),
        ],
        archivedSessionIds: {},
        pinnedSessionIds: {},
      ),
      initialCollapsed: initialCollapsed,
      onCollapsedChanged: onCollapsedChanged,
    ),
  );

  group('会话分组折叠', () {
    testWidgets('默认全部展开', (tester) async {
      await tester.pumpWidget(twoGroups());
      await tester.pumpAndSettle();
      expect(find.text('dsh-web'), findsOneWidget);
      expect(find.text('dsh-api'), findsOneWidget);
      expect(find.text('重构支付'), findsOneWidget);
      expect(find.text('优化接口'), findsOneWidget);
    });

    testWidgets('点组头收起该组，其他组不受影响', (tester) async {
      await tester.pumpWidget(twoGroups());
      await tester.pumpAndSettle();

      await tester.tap(find.text('dsh-web'));
      await tester.pumpAndSettle();

      // web 组的行消失
      expect(find.text('重构支付'), findsNothing);
      expect(find.text('修复登录'), findsNothing);
      // 组头仍在
      expect(find.text('dsh-web'), findsOneWidget);
      // 另一组不受影响
      expect(find.text('优化接口'), findsOneWidget);
    });

    testWidgets('再点一次恢复展开', (tester) async {
      await tester.pumpWidget(twoGroups());
      await tester.pumpAndSettle();

      await tester.tap(find.text('dsh-web'));
      await tester.pumpAndSettle();
      expect(find.text('重构支付'), findsNothing);

      await tester.tap(find.text('dsh-web'));
      await tester.pumpAndSettle();
      expect(find.text('重构支付'), findsOneWidget);
    });

    testWidgets('收起时回调携带组键', (tester) async {
      Set<String>? reported;
      await tester.pumpWidget(
        twoGroups(onCollapsedChanged: (s) => reported = s),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('dsh-web'));
      await tester.pumpAndSettle();

      expect(reported, isNotNull);
      expect(reported, contains('ws:w1'));
    });

    testWidgets('注入 initialCollapsed → 首帧即收起', (tester) async {
      await tester.pumpWidget(
        twoGroups(initialCollapsed: const {'ws:w1'}),
      );
      await tester.pumpAndSettle();

      expect(find.text('重构支付'), findsNothing);
      expect(find.text('优化接口'), findsOneWidget);
    });

    testWidgets('搜索强制展开，清空后恢复折叠', (tester) async {
      await tester.pumpWidget(
        twoGroups(initialCollapsed: const {'ws:w1'}),
      );
      await tester.pumpAndSettle();
      expect(find.text('重构支付'), findsNothing);

      // 搜索命中被折叠组里的会话
      await tester.enterText(find.byType(TextField).first, '重构');
      await tester.pumpAndSettle();
      expect(find.text('重构支付'), findsOneWidget, reason: '搜索必须强制展开');

      // 清空 → 回到折叠
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(find.text('重构支付'), findsNothing, reason: '折叠状态不能被搜索清掉');
    });

    testWidgets('搜索能命中工作区名（组标题）', (tester) async {
      await tester.pumpWidget(twoGroups());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'dsh-web');
      await tester.pumpAndSettle();

      // 整组保留
      expect(find.text('重构支付'), findsOneWidget);
      expect(find.text('修复登录'), findsOneWidget);
      // 另一组不命中
      expect(find.text('优化接口'), findsNothing);
    });

    testWidgets('组头命中区 ≥44', (tester) async {
      await tester.pumpWidget(twoGroups());
      await tester.pumpAndSettle();

      final header = tester.getSize(
        find
            .ancestor(
              of: find.text('dsh-web'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(header.height, greaterThanOrEqualTo(Hit.min));
    });

    testWidgets('未归类组标题本地化为「未归类」', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [
              sess('s1', title: '无目录会话', cwd: null),
            ],
            listWorkspaces: () async => const WorkspaceSnapshot.empty(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('未归类'), findsOneWidget);
      expect(find.text('无目录会话'), findsOneWidget);
    });

    testWidgets('组头语义带 expanded 状态', (tester) async {
      await tester.pumpWidget(twoGroups());
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('dsh-web')),
        isSemantics(isExpanded: true, hasTapAction: true),
      );

      await tester.tap(find.text('dsh-web'));
      await tester.pumpAndSettle();

      expect(
        tester.getSemantics(find.text('dsh-web')),
        isSemantics(isExpanded: false),
      );
    });

    testWidgets('筛选后计数跟随过滤结果，折叠态保持', (tester) async {
      await tester.pumpWidget(
        host(
          SessionsPage(
            listSessions: () async => [
              sess('s1', title: '运行中会话', cwd: '/repo/web', running: true),
              sess('s2', title: '空闲会话', cwd: '/repo/web'),
            ],
            listWorkspaces: () async => const WorkspaceSnapshot(
              items: [
                Workspace(
                  id: 'w1',
                  path: '/repo/web',
                  title: 'dsh-web',
                  sessionIds: ['s1', 's2'],
                ),
              ],
              archivedSessionIds: {},
              pinnedSessionIds: {},
            ),
            initialCollapsed: const {'ws:w1'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 收起时计数是 2
      expect(find.text('2'), findsOneWidget);

      // 切「运行中」→ 计数变 1，折叠保持
      await tester.tap(find.text('运行中'));
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      expect(find.text('运行中会话'), findsNothing, reason: '折叠态应保持');
    });
  });
}

// ── 归档会话过滤 ──
//
// `session/list` 返回的是**全部**会话，不含归档标记；
// 归档信息在 `workspace/follow` baseline 的 `archivedSessionIds` 里。
// 只解析 items 会把归档丢掉 —— 那正是「归档的会话还在列表里」的原因。
void archivedFilterTests() {
  Widget page({
    required Set<String> archived,
    List<String>? workspaces,
  }) => host(
    SessionsPage(
      listSessions: () async => [
        sess('s1', title: '正常会话', cwd: '/repo/web'),
        sess('s2', title: '归档会话', cwd: '/repo/web'),
        sess('s3', title: '空白会话', cwd: '/repo/web', blank: true),
      ],
      listWorkspaces: () async => WorkspaceSnapshot(
        items: const [
          Workspace(
            id: 'w1',
            path: '/repo/web',
            title: 'dsh-web',
            sessionIds: ['s1', 's2', 's3'],
          ),
        ],
        archivedSessionIds: archived,
        pinnedSessionIds: const {},
      ),
    ),
  );

  group('归档过滤', () {
    testWidgets('未归档时全部可见（blank 除外）', (tester) async {
      await tester.pumpWidget(page(archived: const {}));
      await tester.pumpAndSettle();
      expect(find.text('正常会话'), findsOneWidget);
      expect(find.text('归档会话'), findsOneWidget);
      expect(find.text('空白会话'), findsNothing, reason: 'blank 始终过滤');
    });

    testWidgets('归档的会话不出现在列表里', (tester) async {
      await tester.pumpWidget(page(archived: const {'s2'}));
      await tester.pumpAndSettle();
      expect(find.text('正常会话'), findsOneWidget);
      expect(find.text('归档会话'), findsNothing, reason: '归档必须被过滤');
    });

    testWidgets('全部归档时显示空态', (tester) async {
      await tester.pumpWidget(page(archived: const {'s1', 's2'}));
      await tester.pumpAndSettle();
      expect(find.text('暂无会话'), findsOneWidget);
    });

    testWidgets('归档组的计数不含归档会话', (tester) async {
      await tester.pumpWidget(page(archived: const {'s2'}));
      await tester.pumpAndSettle();
      // 组内只剩 s1
      expect(find.text('1'), findsOneWidget);
    });
  });
}
