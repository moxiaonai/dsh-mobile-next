/// 任务输出流：`job/follow`。
///
/// ## 帧结构（三种）
///
/// | type | 字段 | 含义 |
/// | --- | --- | --- |
/// | `opened` | `job`, `from` | 打开时的任务快照 + 首帧起始偏移 |
/// | `output` | `chunks[]`, `next`, `lossy?` | 输出块；`next` 是下次续读偏移 |
/// | `status` | `job` | 任务状态变化（含终止） |
///
/// `output.chunks[]` 每项是 `{at, text}`，`at` 是该块的**绝对字节偏移**，
/// 一旦分配就不再变化 —— 这是可靠续读的基础。
///
/// `lossy: true` 表示请求的偏移到 `chunks` 之间已有字节被淘汰，
/// UI 必须显式告知用户「中间有内容缺失」，不能静默拼接。
///
/// ## 续读
///
/// 断线重连后带上上次的 `next` 重新 `job/follow` 即可，
/// 不会重复也不会跳（除非 `lossy`）。
///
/// ## 载体
///
/// `job/follow` 是 **stream** 端点，走 WebSocket mux。
library;

import 'dart:async';

import '../protocol/frames.dart';
import '../transport/mux.dart';
import 'jobs.dart';

/// 一段输出。
class OutputChunk {
  const OutputChunk({required this.at, required this.text});

  /// 该块首字节的绝对偏移。
  final int at;

  final String text;

  factory OutputChunk.fromJson(Map<String, Object?> json) {
    final at = json['at'];
    final text = json['text'];
    return OutputChunk(
      at: at is num ? at.toInt() : 0,
      text: text is String ? text : '',
    );
  }
}

/// `job/follow` 的一帧。
sealed class JobFollowFrame {
  const JobFollowFrame();
}

class JobFollowOpened extends JobFollowFrame {
  const JobFollowOpened({required this.job, required this.from});

  final JobSummary job;

  /// 首帧 `output` 的起始偏移。
  final int from;
}

class JobFollowOutput extends JobFollowFrame {
  const JobFollowOutput({
    required this.chunks,
    required this.next,
    this.lossy = false,
  });

  final List<OutputChunk> chunks;

  /// 下次续读的偏移。
  final int next;

  /// 是否有字节被淘汰（中间缺失）。
  final bool lossy;
}

class JobFollowStatus extends JobFollowFrame {
  const JobFollowStatus({required this.job});
  final JobSummary job;
}

/// 解析一帧 `job/follow`。无法识别时返回 null（协议可演进）。
JobFollowFrame? parseJobFollowFrame(Object? value) {
  if (value is! Map) return null;
  final m = value.cast<String, Object?>();
  final type = m['type'];
  if (type is! String) return null;

  try {
    switch (type) {
      case 'opened':
        final job = m['job'];
        if (job is! Map) return null;
        final from = m['from'];
        return JobFollowOpened(
          job: JobSummary.fromJson(job.cast<String, Object?>()),
          from: from is num ? from.toInt() : 0,
        );
      case 'output':
        final rawChunks = m['chunks'];
        final next = m['next'];
        return JobFollowOutput(
          chunks: rawChunks is List
              ? rawChunks
                    .whereType<Map>()
                    .map((c) => OutputChunk.fromJson(c.cast<String, Object?>()))
                    .toList(growable: false)
              : const [],
          next: next is num ? next.toInt() : 0,
          lossy: m['lossy'] == true,
        );
      case 'status':
        final job = m['job'];
        if (job is! Map) return null;
        return JobFollowStatus(
          job: JobSummary.fromJson(job.cast<String, Object?>()),
        );
      default:
        return null;
    }
  } on ProtocolError {
    return null;
  }
}

/// 任务输出流的订阅句柄。
///
/// 用法：
/// ```dart
/// final sub = JobOutputReader(mux: mux).open(sessionId, jobId);
/// await for (final event in sub.events) { ... }
/// ```
class JobOutputReader {
  JobOutputReader({required this.mux});

  final MuxClient mux;

  /// 打开一个任务的输出流。
  ///
  /// [from] 为 null 时从最早的保留字节开始。
  /// [sessionId] 为 null 表示无主任务（任何调用方都能看）。
  JobOutputSubscription open({
    required String jobId,
    String? sessionId,
    int? from,
  }) {
    if (!mux.isConnected) {
      throw StateError('mux is not connected');
    }
    final stream = mux.openStream(
      'job/follow',
      payload: {
        'args': {
          'request': {
            'jobId': jobId,
            if (sessionId != null) 'sessionId': sessionId,
            if (from != null) 'from': from,
          },
        },
      },
    );
    return JobOutputSubscription._(stream, mux);
  }
}

/// 一条输出流的生命周期。
class JobOutputSubscription {
  JobOutputSubscription._(this._stream, this._mux);

  final RemoteStream _stream;
  final MuxClient _mux;

  /// 已收到的最大偏移，用于断线续读。
  int _cursor = 0;
  int get cursor => _cursor;

  /// 是否发生过数据丢失。
  bool _lossy = false;
  bool get lossy => _lossy;

  /// 帧流。调用方负责消费。
  Stream<JobFollowFrame> get frames async* {
    await for (final event in _stream.events) {
      switch (event) {
        case StreamItem(:final value):
          final frame = parseJobFollowFrame(value);
          if (frame == null) continue;
          if (frame is JobFollowOutput) {
            if (frame.lossy) _lossy = true;
            if (frame.next > _cursor) _cursor = frame.next;
          }
          yield frame;
        case StreamFailed():
          // 流失败：结束迭代，调用方可按 _cursor 重开。
          return;
        case StreamEnded():
          return;
      }
    }
  }

  /// 取消订阅。
  Future<void> cancel() => _mux.cancelStream(_stream.streamId);
}

/// 把输出块按顺序拼成文本。
///
/// 只拼接**连续**的块；遇到偏移跳跃时插入缺失标记，
/// 而不是静默拼接（后者会让用户以为看到了完整输出）。
class OutputAccumulator {
  final StringBuffer _buffer = StringBuffer();
  int _expect = -1;

  /// 追加一块，返回是否发生跳跃。
  bool append(OutputChunk chunk) {
    var gap = false;
    if (_expect >= 0 && chunk.at > _expect) {
      _buffer.write('\n…[缺失 ${chunk.at - _expect} 字节]…\n');
      gap = true;
    }
    _buffer.write(chunk.text);
    _expect = chunk.at + chunk.text.length;
    return gap;
  }

  String get text => _buffer.toString();

  void clear() {
    _buffer.clear();
    _expect = -1;
  }
}
