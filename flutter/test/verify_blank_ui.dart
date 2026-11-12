/// 验证空白会话的详情页提示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/ui/job_widgets.dart' show AppTheme;
import 'package:dsh_mobile/src/ui/session_detail_page.dart';
import 'package:dsh_mobile/src/ui/tokens.dart';

Widget host(Widget child) {
  final t = Tokens.light;
  return AppTheme(
    tokens: t,
    text: AppTextStyles(t, 16),
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('空白会话显示提示而非 WebView', (tester) async {
    await tester.pumpWidget(
      host(
        SessionDetailPage(
          session: const SessionSummary(id: 'session-2e76960c-x', blank: true),
          origin: Uri.parse('http://127.0.0.1:59851'),
          cookieHeader: 'x=y',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('这个会话还没有内容'), findsOneWidget);
    expect(find.textContaining('在电脑上发第一条消息'), findsOneWidget);
  });
}
