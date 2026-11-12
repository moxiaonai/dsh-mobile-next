/// 任务中心：把 `job/*` 端点包装成可用的读模型。
///
/// ## 为什么单独写一层
///
/// `job/list` 是**流式**端点，帧结构随 `type` 字段变化（`rows` / 增量 / 结算）。
/// 代码生成器只覆盖 unary 的 result schema，不适合直接套用，因此这里手写
/// 帧解析 —— 字段名严格对齐 `tool/schema.json` 里的 `JobListFrame`。
///
/// ## 双载具提醒
///
/// | 端点 | 载体 |
/// | --- | --- |
/// | `job/list` | **stream**（WebSocket mux） |
/// | `job/follow` | **stream**（WebSocket mux） |
/// | `job/kill` | **unary**（HTTP POST） |
///
/// 走错载体分别得到 `gateway/signature-invalid` 与 404。
library;

import 'dart:async';

import '../protocol/frames.dart';
import '../transport/mux.dart';
import '../transport/unary.dart';

/// 任务状态。与 schema 的 enum 一致，另加 `unknown` 兜底。
enum JobStatus { failed, running, stopping, completed, killed, unknown }

JobStatus _parseStatus(Object? raw) => switch (raw) {
  'failed' => JobStatus.failed,
  'running' => JobStatus.running,
  'stopping' => JobStatus.stopping,
  'completed' => JobStatus.completed,
  'killed' => JobStatus.killed,
  _ => JobStatus.unknown,
};

/// 输出环的绝对坐标。
///
/// `total` 是下一块数据的起始偏移（为 0 表示还没有输出），
/// `earliest` 是环里仍可取到的最早偏移。
class JobOutput {
  const JobOutput({
    required this.total,
    required this.earliest,
    this.spillPaths = const [],
  });

  final int total;
  final int earliest;

  /// 完整流落盘文件的路径（大输出时由 Host 提供）。
  final List<String> spillPaths;

  /// 是否还有未读输出。
  bool get hasUnread => total > earliest;

  /// 尚未读出的字节数。
  int get pendingBytes => total > earliest ? total - earliest : 0;

  factory JobOutput.fromJson(Map<String, Object?> json) {
    final total = json['total'];
    final earliest = json['earliest'];
    return JobOutput(
      total: total is num ? total.toInt() : 0,
      earliest: earliest is num ? earliest.toInt() : 0,
      spillPaths: json['spillPaths'] is List
          ? (json['spillPaths'] as List).whereType<String>().toList()
          : const [],
    );
  }
}

/// 一个后台任务。
class JobSummary {
  const JobSummary({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    required this.startedAt,
    required this.output,
    this.owner,
    this.progress,
    this.detail,
    this.finishedAt,
    this.raw = const {},
  });

  /// 注册表签发的 id，形如 `<kind>-<short-uuid>`。
  final String id;

  /// 生产者类型（open string，不枚举 —— 插件可自定义）。
  final String kind;

  /// 生产者提供的一行标签。
  final String label;

  /// 所属会话；无主任务为 null（所有调用方都能看到）。
  final String? owner;

  final JobStatus status;

  /// 生产者上报的实时进度行（`3/10`、当前阶段），结算时清空。
  final String? progress;

  /// 结算原因（`exit code: 3`），可能含记录下来的终止原因。
  final String? detail;

  final DateTime startedAt;

  /// 结算时间；仍在跑时为 null。
  final DateTime? finishedAt;

  final JobOutput output;

  final Map<String, Object?> raw;

  bool get isLive =>
      status == JobStatus.running || status == JobStatus.stopping;

  bool get isSettled => !isLive;

  /// 已运行时长。仅对活任务有意义。
  Duration elapsed([DateTime? now]) =>
      (finishedAt ?? now ?? DateTime.now()).difference(startedAt);

  factory JobSummary.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const ProtocolError('job row has no id');
    }
    final startedRaw = json['startedAt'];
    final started = startedRaw is num
        ? DateTime.fromMillisecondsSinceEpoch(startedRaw.toInt())
        : DateTime.now();
    final finishedRaw = json['finishedAt'];
    final out = json['output'];
    return JobSummary(
      id: id,
      kind: json['kind'] as String? ?? 'unknown',
      label: json['label'] as String? ?? '',
      owner: json['owner'] as String?,
      status: _parseStatus(json['status']),
      progress: json['progress'] as String?,
      detail: json['detail'] as String?,
      startedAt: started,
      finishedAt: finishedRaw is num
          ? DateTime.fromMillisecondsSinceEpoch(finishedRaw.toInt())
          : null,
      output: out is Map
          ? JobOutput.fromJson(out.cast<String, Object?>())
          : const JobOutput(total: 0, earliest: 0),
      raw: json,
    );
  }

  @override
  String toString() =>
      'JobSummary($id, $kind, $label, ${status.name}'
      '${progress == null ? '' : ', $progress'})';
}

/// `job/list` 的一帧。
class JobListFrame {
  const JobListFrame({required this.type, this.jobs = const []});

  /// 帧类型。已知 `rows`；其它类型保留但不解析（协议可演进）。
  final String type;
  final List<JobSummary> jobs;

  /// 是否为完整集合快照。
  ///
  /// `job/list` 的语义是「打开时一帧，之后变化时再一帧，每帧都是**全集**」，
  /// 因此收到新帧应整体替换而非增量合并。
  bool get isSnapshot => type == 'rows';

  static JobListFrame? tryParse(Object? value) {
    if (value is! Map) return null;
    final m = value.cast<String, Object?>();
    final type = m['type'];
    if (type is! String) return null;
    final rawJobs = m['jobs'];
    if (rawJobs is! List) return JobListFrame(type: type);
    final jobs = <JobSummary>[];
    for (final item in rawJobs) {
      if (item is! Map) continue;
      try {
        jobs.add(JobSummary.fromJson(item.cast<String, Object?>()));
      } on ProtocolError {
        // 单条坏数据不应让整帧失败。
        continue;
      }
    }
    return JobListFrame(type: type, jobs: jobs);
  }
}

/// 任务中心。
///
/// 用法：
/// ```dart
/// final center = JobCenter(unary: conn.unary, mux: conn.mux);
/// final sub = center.watch(sessionId).listen((jobs) { ... });
/// ```
class JobCenter {
  JobCenter({required this.unary, required this.mux});

  final UnaryClient unary;
  final MuxClient mux;

  /// 订阅某会话可见的任务集合。
  ///
  /// 返回的 Stream 会在每次 Host 推送新帧时发出**完整**任务列表
  /// （不是增量），调用方直接替换即可。
  Stream<List<JobSummary>> watch(String sessionId) {
    late RemoteStream stream;
    final controller = StreamController<List<JobSummary>>();
    StreamSubscription<StreamEvent>? sub;

    controller.onListen = () {
      if (!mux.isConnected) {
        controller.addError(StateError('mux is not connected'));
        return;
      }
      stream = mux.openStream(
        'job/list',
        payload: {
          'args': {
            'request': {'sessionId': sessionId},
          },
        },
      );
      sub = stream.events.listen(
        (event) {
          switch (event) {
            case StreamItem(:final value):
              final frame = JobListFrame.tryParse(value);
              if (frame != null && frame.isSnapshot) {
                controller.add(frame.jobs);
              }
            case StreamFailed(:final error):
              controller.addError(error);
            case StreamEnded():
              // 流结束：不关闭 controller，让调用方可重连后重订阅。
              break;
          }
        },
        onError: controller.addError,
      );
    };

    controller.onCancel = () async {
      await sub?.cancel();
      await mux.cancelStream(stream.streamId);
    };

    return controller.stream;
  }

  /// 终止一个后台任务。
  ///
  /// 这是 **unary** 端点，走 HTTP。任务必须属于该会话可见集合。
  Future<JobKillResult> kill({
    required String sessionId,
    required String jobId,
  }) async {
    final value = await unary.call(
      'job/kill',
      args: {
        'request': {'sessionId': sessionId, 'jobId': jobId},
      },
    );
    if (value is Map) {
      final m = value.cast<String, Object?>();
      final outcome = m['outcome'];
      return JobKillResult(
        outcome: outcome is String ? outcome : 'unknown',
        raw: m,
      );
    }
    return const JobKillResult(outcome: 'unknown');
  }
}

/// `job/kill` 的结果。
class JobKillResult {
  const JobKillResult({required this.outcome, this.raw = const {}});

  /// 已知值：`requested` / `already-finished`。
  final String outcome;
  final Map<String, Object?> raw;

  bool get requested => outcome == 'requested';
  bool get alreadyFinished => outcome == 'already-finished';
}
