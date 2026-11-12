/// 会话分组的纯逻辑测试。
///
/// 分组的归并优先级是这套 UI 的地基，出错的表现是「会话跑到别的项目下」
/// 或「断连后会话全消失」，都不是 widget 测试能覆盖的。这里直接测算法。
library;

import 'package:dsh_mobile/src/protocol/session.dart';
import 'package:dsh_mobile/src/protocol/sessions.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary sess(
  String id, {
  String? title,
  String? cwd,
  DateTime? updatedAt,
  bool running = false,
}) => SessionSummary(
  id: id,
  title: title,
  cwd: cwd,
  updatedAt: updatedAt,
  running: running,
);

Workspace ws(String id, String path, List<String> ids, {String? title}) =>
    Workspace(id: id, path: path, title: title ?? id, sessionIds: ids);

void main() {
  group('normalizeCwd', () {
    test('去掉尾部斜杠（保留根）', () {
      expect(normalizeCwd('/a/b/'), '/a/b');
      expect(normalizeCwd('/'), '/');
    });
    test('折叠重复斜杠', () {
      expect(normalizeCwd('//a//b'), '/a/b');
    });
    test('空串与空白', () {
      expect(normalizeCwd(''), '');
      expect(normalizeCwd('   '), '');
    });
  });

  group('isUnder', () {
    test('相等算在内', () {
      expect(isUnder('/a/b', '/a/b'), isTrue);
    });
    test('子目录算在内', () {
      expect(isUnder('/a/b/c', '/a/b'), isTrue);
    });
    test('前缀相同但不是子目录不算', () {
      expect(isUnder('/a/bc', '/a/b'), isFalse);
    });
    test('根匹配一切绝对路径', () {
      expect(isUnder('/anything', '/'), isTrue);
    });
  });

  group('SessionBrowser.group 归并规则（与 PC 端侧栏一致）', () {
    test('显式成员归到该 workspace', () {
      final groups = SessionBrowser.group(
        [sess('s1', cwd: '/other/place')],
        [ws('w1', '/proj', ['s1'])],
      );
      expect(groups, hasLength(1));
      expect(groups.first.kind, SessionGroupKind.workspace);
      expect(groups.first.key, 'ws:w1');
    });

    test('cwd 匹配但不在 sessionIds 里 → 不归该 workspace', () {
      // 这是「脏数据」的核心回归：早先按 cwd 前缀推断，
      // 结果冒出一堆目录名当分组（workspace / tmp / T ...）。
      final groups = SessionBrowser.group(
        [sess('s1', cwd: '/proj')],
        [ws('w1', '/proj', const [])],
      );
      expect(groups.single.kind, SessionGroupKind.unassigned);
      expect(groups.single.key, 'unassigned');
    });

    test('子目录也不推断归属', () {
      final groups = SessionBrowser.group(
        [sess('s1', cwd: '/proj/packages/a')],
        [ws('w1', '/proj', const [])],
      );
      expect(groups.single.kind, SessionGroupKind.unassigned);
    });

    test('不属于任何 workspace 的会话进「未分组」', () {
      final groups = SessionBrowser.group(
        [sess('s1'), sess('s2', cwd: '/whatever')],
        [ws('w1', '/proj', const [])],
      );
      expect(groups.single.kind, SessionGroupKind.unassigned);
      expect(groups.single.title, '', reason: '标题由 UI 本地化');
      expect(groups.single.sessions, hasLength(2));
    });

    test('未分组恒在最后', () {
      final now = DateTime(2026, 1, 2);
      final groups = SessionBrowser.group(
        [
          sess('a', cwd: '/p', updatedAt: DateTime(2026, 1, 1)),
          sess('b', updatedAt: now),
        ],
        [ws('w1', '/p', ['a'])],
      );
      expect(groups.last.kind, SessionGroupKind.unassigned);
    });

    test('断连降级：workspaces 为空时全部进未分组，且不丢会话', () {
      final input = [
        sess('s1', cwd: '/a'),
        sess('s2', cwd: '/b'),
        sess('s3'),
      ];
      final groups = SessionBrowser.group(input, const []);
      expect(groups, hasLength(1));
      expect(groups.single.kind, SessionGroupKind.unassigned);
      expect(groups.single.sessions, hasLength(3), reason: '不许丢会话');
    });

    test('守恒：不丢不重', () {
      final input = [
        sess('s1', cwd: '/a'),
        sess('s2', cwd: '/a/sub'),
        sess('s3'),
      ];
      final groups = SessionBrowser.group(
        input,
        [ws('w1', '/a', ['s1'])],
      );
      final ids = groups.expand((g) => g.sessions).map((s) => s.id).toList();
      expect(ids.toSet(), {'s1', 's2', 's3'});
      expect(ids, hasLength(3));
    });

    test('组内按 updatedAt 倒序，null 排后', () {
      final groups = SessionBrowser.group(
        [
          sess('old', cwd: '/p', updatedAt: DateTime(2026, 1, 1)),
          sess('new', cwd: '/p', updatedAt: DateTime(2026, 3, 1)),
          sess('none', cwd: '/p'),
        ],
        [ws('w1', '/p', ['old', 'new', 'none'])],
      );
      expect(
        groups.single.sessions.map((s) => s.id).toList(),
        ['new', 'old', 'none'],
      );
    });

    test('组间按最近活动倒序', () {
      final groups = SessionBrowser.group(
        [
          sess('a', updatedAt: DateTime(2026, 1, 1)),
          sess('b', updatedAt: DateTime(2026, 5, 1)),
        ],
        [
          ws('w1', '/p1', ['a']),
          ws('w2', '/p2', ['b']),
        ],
      );
      expect(groups.first.key, 'ws:w2');
    });
  });

  group('searchGroups', () {
    List<SessionGroup> sample() => SessionBrowser.group(
      [
        sess('s1', title: '重构支付', cwd: '/repo/web'),
        sess('s2', title: 'Greeting', cwd: '/repo/web'),
        sess('s3', title: 'other', cwd: '/repo/api'),
      ],
      // 按新规则归属只看显式成员，所以 s1/s2 必须列进 sessionIds
      [ws('w1', '/repo/web', ['s1', 's2'], title: 'dsh-web')],
    );

    test('空查询原样返回', () {
      final g = sample();
      expect(SessionBrowser.searchGroups(g, '  '), same(g));
    });

    test('命中组标题 → 整组保留', () {
      final out = SessionBrowser.searchGroups(sample(), 'dsh-web');
      expect(out, hasLength(1));
      expect(out.single.sessions, hasLength(2), reason: '组标题命中应保留整组');
    });

    test('命中组内会话 → 只留命中项', () {
      final out = SessionBrowser.searchGroups(sample(), '重构');
      expect(out, hasLength(1));
      expect(out.single.sessions.single.id, 's1');
    });

    test('无命中 → 空列表', () {
      expect(SessionBrowser.searchGroups(sample(), 'zzz'), isEmpty);
    });
  });
}
