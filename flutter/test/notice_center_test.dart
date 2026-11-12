/// 通知中心的纯逻辑测试。
///
/// 去重与已读是这一层存在的理由：`$events` 会重放未结算的 waterfall，
/// 不去重的话同一条审批会重复出现；已读若按位置存，清理后会错位。
library;

import 'package:dsh_mobile/src/notice_center.dart';
import 'package:flutter_test/flutter_test.dart';

Notice n(
  String id, {
  NoticeKind kind = NoticeKind.approval,
  String session = 's1',
  int minutesAgo = 0,
}) => Notice(
  id: id,
  kind: kind,
  sessionId: session,
  title: 't-$id',
  at: DateTime(2026, 1, 1, 12).subtract(Duration(minutes: minutesAgo)),
);

void main() {
  group('NoticeCenter 去重', () {
    test('同 id 只保留一条', () {
      final c = NoticeCenter();
      expect(c.add(n('a')), isTrue, reason: '首次加入应为新通知');
      expect(c.add(n('a')), isFalse, reason: '重复加入不算新');
      expect(c.items, hasLength(1));
    });

    test('同 id 重复加入时保留最新内容', () {
      final c = NoticeCenter();
      c.add(n('a'));
      c.add(
        Notice(
          id: 'a',
          kind: NoticeKind.approval,
          sessionId: 's1',
          title: 'updated',
          at: DateTime(2026, 2, 1),
        ),
      );
      expect(c.items.single.title, 'updated');
    });

    test('不同 id 各自保留', () {
      final c = NoticeCenter();
      c.add(n('a'));
      c.add(n('b'));
      expect(c.items, hasLength(2));
    });
  });

  group('NoticeCenter 已读', () {
    test('未读数正确', () {
      final c = NoticeCenter();
      c.add(n('a'));
      c.add(n('b'));
      expect(c.unreadCount, 2);
      c.markRead('a');
      expect(c.unreadCount, 1);
    });

    test('重复标记同一 id 不重复计数', () {
      final c = NoticeCenter();
      c.add(n('a'));
      expect(c.markRead('a'), isTrue);
      expect(c.markRead('a'), isFalse, reason: '已读再标一次应无变化');
      expect(c.unreadCount, 0);
    });

    test('标记不存在的 id 无副作用', () {
      final c = NoticeCenter();
      c.add(n('a'));
      expect(c.markRead('zzz'), isFalse);
      expect(c.unreadCount, 1);
    });

    test('markAllRead 清零未读', () {
      final c = NoticeCenter();
      c.add(n('a'));
      c.add(n('b'));
      c.markAllRead();
      expect(c.unreadCount, 0);
    });
  });

  group('NoticeCenter 排序与有界', () {
    test('items 按时间倒序', () {
      final c = NoticeCenter();
      c.add(n('old', minutesAgo: 10));
      c.add(n('new', minutesAgo: 1));
      expect(c.items.map((e) => e.id).toList(), ['new', 'old']);
    });

    test('超出上限丢最旧的', () {
      final c = NoticeCenter(maxEntries: 3);
      for (var i = 0; i < 6; i++) {
        c.add(n('id$i', minutesAgo: 10 - i));
      }
      expect(c.items, hasLength(3));
      // 保留最近 3 条：id3/id4/id5
      expect(c.items.map((e) => e.id).toSet(), {'id3', 'id4', 'id5'});
    });

    test('清空', () {
      final c = NoticeCenter();
      c.add(n('a'));
      c.clear();
      expect(c.isEmpty, isTrue);
      expect(c.unreadCount, 0);
    });
  });

  group('Notice 序列化', () {
    test('往返不丢字段', () {
      final original = Notice(
        id: 'x',
        kind: NoticeKind.question,
        sessionId: 's9',
        title: '问题',
        at: DateTime(2026, 3, 4, 5, 6),
        read: true,
      );
      final back = Notice.fromJson(original.toJson());
      expect(back, isNotNull);
      expect(back!.id, 'x');
      expect(back.kind, NoticeKind.question);
      expect(back.sessionId, 's9');
      expect(back.title, '问题');
      expect(back.read, isTrue);
      expect(back.at, original.at);
    });

    test('缺字段返回 null 而不是抛错', () {
      expect(Notice.fromJson(const {}), isNull);
      expect(Notice.fromJson(const {'id': 'a'}), isNull);
    });
  });
}
