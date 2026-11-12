/// 任务层单元测试（纯逻辑，不需网络）。
library;

import 'package:test/test.dart';

import 'package:dsh_mobile/src/protocol/jobs.dart';

void main() {
  group('JobSummary.fromJson', () {
    Map<String, Object?> base() => {
      'id': 'bash-abc123',
      'kind': 'bash',
      'label': 'pnpm test',
      'status': 'running',
      'startedAt': 1700000000000,
      'output': {'total': 100, 'earliest': 40},
    };

    test('parses a running job', () {
      final j = JobSummary.fromJson(base());
      expect(j.id, 'bash-abc123');
      expect(j.kind, 'bash');
      expect(j.label, 'pnpm test');
      expect(j.status, JobStatus.running);
      expect(j.isLive, isTrue);
      expect(j.isSettled, isFalse);
      expect(j.finishedAt, isNull);
    });

    test('parses a completed job with finishedAt', () {
      final j = JobSummary.fromJson({
        ...base(),
        'status': 'completed',
        'finishedAt': 1700000010000,
        'detail': 'exit code: 0',
      });
      expect(j.status, JobStatus.completed);
      expect(j.isLive, isFalse);
      expect(j.isSettled, isTrue);
      expect(j.finishedAt, isNotNull);
      expect(j.detail, 'exit code: 0');
      expect(j.elapsed().inSeconds, 10);
    });

    test('maps every documented status', () {
      for (final (wire, expected) in [
        ('failed', JobStatus.failed),
        ('running', JobStatus.running),
        ('stopping', JobStatus.stopping),
        ('completed', JobStatus.completed),
        ('killed', JobStatus.killed),
      ]) {
        expect(
          JobSummary.fromJson({...base(), 'status': wire}).status,
          expected,
        );
      }
    });

    test('unknown status falls back without throwing', () {
      final j = JobSummary.fromJson({...base(), 'status': 'future-status'});
      expect(j.status, JobStatus.unknown);
    });

    test('rejects a row without id', () {
      expect(
        () => JobSummary.fromJson({...base(), 'id': null}),
        throwsA(isA<Exception>()),
      );
    });

    test('tolerates missing optional fields', () {
      final j = JobSummary.fromJson({
        'id': 'x-1',
        'kind': 'bash',
        'label': 'x',
        'status': 'running',
        'startedAt': 1700000000000,
        'output': {'total': 0, 'earliest': 0},
      });
      expect(j.owner, isNull);
      expect(j.progress, isNull);
      expect(j.detail, isNull);
    });
  });

  group('JobOutput', () {
    test('computes pending bytes', () {
      const o = JobOutput(total: 100, earliest: 40);
      expect(o.pendingBytes, 60);
      expect(o.hasUnread, isTrue);
    });

    test('zero pending when fully read', () {
      const o = JobOutput(total: 100, earliest: 100);
      expect(o.pendingBytes, 0);
      expect(o.hasUnread, isFalse);
    });

    test('handles empty ring', () {
      const o = JobOutput(total: 0, earliest: 0);
      expect(o.pendingBytes, 0);
    });

    test('keeps spill paths', () {
      final o = JobOutput.fromJson({
        'total': 10,
        'earliest': 0,
        'spillPaths': ['/tmp/a.log', '/tmp/b.log'],
      });
      expect(o.spillPaths, ['/tmp/a.log', '/tmp/b.log']);
    });
  });

  group('JobListFrame.tryParse', () {
    test('parses a rows frame', () {
      final f = JobListFrame.tryParse({
        'type': 'rows',
        'jobs': [
          {
            'id': 'bash-1',
            'kind': 'bash',
            'label': 'a',
            'status': 'running',
            'startedAt': 1,
            'output': {'total': 0, 'earliest': 0},
          },
        ],
      });
      expect(f, isNotNull);
      expect(f!.type, 'rows');
      expect(f.isSnapshot, isTrue);
      expect(f.jobs, hasLength(1));
    });

    test('skips malformed rows but keeps the frame', () {
      final f = JobListFrame.tryParse({
        'type': 'rows',
        'jobs': [
          {'id': 'ok-1', 'kind': 'bash', 'label': 'x', 'status': 'running',
           'startedAt': 1, 'output': {'total': 0, 'earliest': 0}},
          {'kind': 'bash'}, // 缺 id
        ],
      });
      expect(f!.jobs, hasLength(1));
    });

    test('returns null for non-objects', () {
      expect(JobListFrame.tryParse('x'), isNull);
      expect(JobListFrame.tryParse(null), isNull);
      expect(JobListFrame.tryParse(<Object?>[]), isNull);
    });

    test('tolerates unknown frame type', () {
      final f = JobListFrame.tryParse({'type': 'future', 'jobs': []});
      expect(f, isNotNull);
      expect(f!.isSnapshot, isFalse);
    });
  });

  group('JobKillResult', () {
    test('recognises requested', () {
      expect(const JobKillResult(outcome: 'requested').requested, isTrue);
      expect(const JobKillResult(outcome: 'requested').alreadyFinished, isFalse);
    });

    test('recognises already-finished', () {
      const r = JobKillResult(outcome: 'already-finished');
      expect(r.alreadyFinished, isTrue);
      expect(r.requested, isFalse);
    });
  });
}
