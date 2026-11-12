// GENERATED FILE — 不要手改。
//
// 生成命令：node tool/generate_models.mjs
// 数据来源：tool/schema.json（从 DSH app.asar 提取的 endpoint descriptor）
// 生成时间：2026-11-10T11:48:49.778Z
//
// 设计说明：
// - 手写 fromJson/toJson，不依赖 json_serializable / build_runner
// - 每个类保留 `extra`，存 schema 未覆盖的字段（协议会演进，不能丢数据）
// - 枚举带 unknown 兜底，新枚举值不会导致崩溃

// ignore_for_file: type=lint, unused_field, unused_element

part of 'models.dart';

/// JobKillValueOutcome
enum JobKillValueOutcome {
  requested,
  alreadyFinished,
  /// 未知值兜底 —— 协议新增枚举值时不会崩溃。
  unknown,
}

extension JobKillValueOutcomeCodec on JobKillValueOutcome {
  String get wire => switch (this) {
    JobKillValueOutcome.requested => 'requested',
    JobKillValueOutcome.alreadyFinished => 'already-finished',
    JobKillValueOutcome.unknown => '',
  };

  static JobKillValueOutcome fromWire(Object? raw) => switch (raw) {
    'requested' => JobKillValueOutcome.requested,
    'already-finished' => JobKillValueOutcome.alreadyFinished,
    _ => JobKillValueOutcome.unknown,
  };
}

/// JobListValueJobsItemStatus
enum JobListValueJobsItemStatus {
  failed,
  running,
  stopping,
  completed,
  killed,
  /// 未知值兜底 —— 协议新增枚举值时不会崩溃。
  unknown,
}

extension JobListValueJobsItemStatusCodec on JobListValueJobsItemStatus {
  String get wire => switch (this) {
    JobListValueJobsItemStatus.failed => 'failed',
    JobListValueJobsItemStatus.running => 'running',
    JobListValueJobsItemStatus.stopping => 'stopping',
    JobListValueJobsItemStatus.completed => 'completed',
    JobListValueJobsItemStatus.killed => 'killed',
    JobListValueJobsItemStatus.unknown => '',
  };

  static JobListValueJobsItemStatus fromWire(Object? raw) => switch (raw) {
    'failed' => JobListValueJobsItemStatus.failed,
    'running' => JobListValueJobsItemStatus.running,
    'stopping' => JobListValueJobsItemStatus.stopping,
    'completed' => JobListValueJobsItemStatus.completed,
    'killed' => JobListValueJobsItemStatus.killed,
    _ => JobListValueJobsItemStatus.unknown,
  };
}

/// SessionPromptRequestMode
enum SessionPromptRequestMode {
  queue,
  steer,
  /// 未知值兜底 —— 协议新增枚举值时不会崩溃。
  unknown,
}

extension SessionPromptRequestModeCodec on SessionPromptRequestMode {
  String get wire => switch (this) {
    SessionPromptRequestMode.queue => 'queue',
    SessionPromptRequestMode.steer => 'steer',
    SessionPromptRequestMode.unknown => '',
  };

  static SessionPromptRequestMode fromWire(Object? raw) => switch (raw) {
    'queue' => SessionPromptRequestMode.queue,
    'steer' => SessionPromptRequestMode.steer,
    _ => SessionPromptRequestMode.unknown,
  };
}

/// SessionStateValuePendingInputItem
enum SessionStateValuePendingInputItem {
  approval,
  question,
  other,
  /// 未知值兜底 —— 协议新增枚举值时不会崩溃。
  unknown,
}

extension SessionStateValuePendingInputItemCodec on SessionStateValuePendingInputItem {
  String get wire => switch (this) {
    SessionStateValuePendingInputItem.approval => 'approval',
    SessionStateValuePendingInputItem.question => 'question',
    SessionStateValuePendingInputItem.other => 'other',
    SessionStateValuePendingInputItem.unknown => '',
  };

  static SessionStateValuePendingInputItem fromWire(Object? raw) => switch (raw) {
    'approval' => SessionStateValuePendingInputItem.approval,
    'question' => SessionStateValuePendingInputItem.question,
    'other' => SessionStateValuePendingInputItem.other,
    _ => SessionStateValuePendingInputItem.unknown,
  };
}

/// SessionStateValueQueueItemPlacement
enum SessionStateValueQueueItemPlacement {
  queued,
  steering,
  context,
  /// 未知值兜底 —— 协议新增枚举值时不会崩溃。
  unknown,
}

extension SessionStateValueQueueItemPlacementCodec on SessionStateValueQueueItemPlacement {
  String get wire => switch (this) {
    SessionStateValueQueueItemPlacement.queued => 'queued',
    SessionStateValueQueueItemPlacement.steering => 'steering',
    SessionStateValueQueueItemPlacement.context => 'context',
    SessionStateValueQueueItemPlacement.unknown => '',
  };

  static SessionStateValueQueueItemPlacement fromWire(Object? raw) => switch (raw) {
    'queued' => SessionStateValueQueueItemPlacement.queued,
    'steering' => SessionStateValueQueueItemPlacement.steering,
    'context' => SessionStateValueQueueItemPlacement.context,
    _ => SessionStateValueQueueItemPlacement.unknown,
  };
}

/// target job, owning session, and optional resume offset.
class JobFollowRequest {
  const JobFollowRequest({
    this.sessionId,
    required this.jobId,
    this.from,
    this.extra = const {},
  });

  /// Owning session for the fenced read. Omitted for an unowned job, which any
  /// caller may observe.
  final String? sessionId;
  final String jobId;
  /// Absolute byte offset to resume from (a prior frame's `next`). Omitted, the
  /// stream starts at the oldest retained byte.
  final num? from;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory JobFollowRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
      'jobId',
      'from',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return JobFollowRequest(
      sessionId: asString(json['sessionId']),
      jobId: asString(json['jobId'])!,
      from: asNum(json['from']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    final localSessionId = sessionId; if (localSessionId != null) out['sessionId'] = localSessionId;
    out['jobId'] = jobId;
    final localFrom = from; if (localFrom != null) out['from'] = localFrom;
    out.addAll(extra);
    return out;
  }
}

/// Session whose job list carries the job, and the job id.
class JobKillRequest {
  const JobKillRequest({
    required this.sessionId,
    required this.jobId,
    this.extra = const {},
  });

  /// Session whose job list carries the job; the fenced lookup reads as it.
  final String sessionId;
  final String jobId;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory JobKillRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
      'jobId',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return JobKillRequest(
      sessionId: asString(json['sessionId'])!,
      jobId: asString(json['jobId'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out['jobId'] = jobId;
    out.addAll(extra);
    return out;
  }
}

/// the registry's admission of the kill request.
class JobKillValue {
  const JobKillValue({
    required this.outcome,
    this.extra = const {},
  });

  final JobKillValueOutcome outcome;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory JobKillValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'outcome',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return JobKillValue(
      outcome: JobKillValueOutcomeCodec.fromWire(json['outcome']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['outcome'] = outcome.wire;
    out.addAll(extra);
    return out;
  }
}

/// the session whose visible set to mirror.
class JobListRequest {
  const JobListRequest({
    required this.sessionId,
    this.extra = const {},
  });

  final String sessionId;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory JobListRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return JobListRequest(
      sessionId: asString(json['sessionId'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out.addAll(extra);
    return out;
  }
}

/// the roster frames.
class JobListValue {
  const JobListValue({
    required this.type,
    required this.jobs,
    this.extra = const {},
  });

  final String type;
  final List<JobListValueJobsItem> jobs;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory JobListValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'type',
      'jobs',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return JobListValue(
      type: asString(json['type'])!,
      jobs: asList<JobListValueJobsItem>(json['jobs'], JobListValueJobsItem.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['type'] = type;
    out['jobs'] = jobs.map((e) => e.toJson()).toList();
    out.addAll(extra);
    return out;
  }
}

class JobListValueJobsItem {
  const JobListValueJobsItem({
    required this.id,
    required this.kind,
    required this.label,
    this.owner,
    this.outputLimitBytes,
    required this.status,
    this.progress,
    this.detail,
    required this.startedAt,
    this.finishedAt,
    required this.output,
    this.extra = const {},
  });

  /// The registry-issued id (`<kind>-<short-uuid>`).
  final String id;
  /// The producer kind the job was registered with: a Host-registered
  /// `JobKind`, carried as an open string because a browser bundle or a Remote
  /// codec sees only the `JobKindMap` merges its own program compiles.
  final String kind;
  /// The producer-supplied one-line label.
  final String label;
  /// Owning session; absent for an unowned job, which every caller can see.
  final String? owner;
  /// Producer-owned cap for complete model-facing notices and reads, in UTF-8
  /// bytes.
  final num? outputLimitBytes;
  /// Current lifecycle state.
  final JobListValueJobsItemStatus status;
  /// The producer's live progress line (`3/10`, the current phase); cleared at
  /// settlement.
  final String? progress;
  /// Terminal reason (`exit code: 3`); a recorded kill reason is merged in.
  final String? detail;
  /// Epoch ms when the job was registered.
  final num startedAt;
  /// Epoch ms when the job settled; absent while live.
  final num? finishedAt;
  /// The output ring's absolute coordinates and the complete-stream files
  /// behind it. `total` is the offset the next chunk starts at (0 while nothing
  /// was written); `earliest` is the oldest retained byte, greater than zero
  /// exactly when retention dropped the head. `spillPaths` lists the spill
  /// files the job's pull sources currently keep, in source order and
  /// deduplicated, and is absent while no source keeps one: it outlives any
  /// chunk, so a reader below `earliest` can still name where the bytes went.
  final JobListValueJobsItemOutput output;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory JobListValueJobsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'id',
      'kind',
      'label',
      'owner',
      'outputLimitBytes',
      'status',
      'progress',
      'detail',
      'startedAt',
      'finishedAt',
      'output',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return JobListValueJobsItem(
      id: asString(json['id'])!,
      kind: asString(json['kind'])!,
      label: asString(json['label'])!,
      owner: asString(json['owner']),
      outputLimitBytes: asNum(json['outputLimitBytes']),
      status: JobListValueJobsItemStatusCodec.fromWire(json['status']),
      progress: asString(json['progress']),
      detail: asString(json['detail']),
      startedAt: asNum(json['startedAt'])!,
      finishedAt: asNum(json['finishedAt']),
      output: asModel<JobListValueJobsItemOutput>(json['output'], JobListValueJobsItemOutput.fromJson)!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['id'] = id;
    out['kind'] = kind;
    out['label'] = label;
    final localOwner = owner; if (localOwner != null) out['owner'] = localOwner;
    final localOutputLimitBytes = outputLimitBytes; if (localOutputLimitBytes != null) out['outputLimitBytes'] = localOutputLimitBytes;
    out['status'] = status.wire;
    final localProgress = progress; if (localProgress != null) out['progress'] = localProgress;
    final localDetail = detail; if (localDetail != null) out['detail'] = localDetail;
    out['startedAt'] = startedAt;
    final localFinishedAt = finishedAt; if (localFinishedAt != null) out['finishedAt'] = localFinishedAt;
    out['output'] = output.toJson();
    out.addAll(extra);
    return out;
  }
}

/// The output ring's absolute coordinates and the complete-stream files behind
/// it. `total` is the offset the next chunk starts at (0 while nothing was
/// written); `earliest` is the oldest retained byte, greater than zero exactly
/// when retention dropped the head. `spillPaths` lists the spill files the
/// job's pull sources currently keep, in source order and deduplicated, and is
/// absent while no source keeps one: it outlives any chunk, so a reader below
/// `earliest` can still name where the bytes went.
class JobListValueJobsItemOutput {
  const JobListValueJobsItemOutput({
    required this.total,
    required this.earliest,
    this.spillPaths,
    this.extra = const {},
  });

  final num total;
  final num earliest;
  final List<String>? spillPaths;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory JobListValueJobsItemOutput.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'total',
      'earliest',
      'spillPaths',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return JobListValueJobsItemOutput(
      total: asNum(json['total'])!,
      earliest: asNum(json['earliest'])!,
      spillPaths: asListRaw<String>(json['spillPaths']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['total'] = total;
    out['earliest'] = earliest;
    final localSpillPaths = spillPaths; if (localSpillPaths != null) out['spillPaths'] = localSpillPaths;
    out.addAll(extra);
    return out;
  }
}

/// Session whose active Agent turn is cancelled.
class SessionCancelRequest {
  const SessionCancelRequest({
    required this.sessionId,
    this.extra = const {},
  });

  final String sessionId;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionCancelRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionCancelRequest(
      sessionId: asString(json['sessionId'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out.addAll(extra);
    return out;
  }
}

/// acknowledgement that cancellation was requested.
class SessionCancelValue {
  const SessionCancelValue({
    required this.accepted,
    this.extra = const {},
  });

  final bool accepted;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionCancelValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'accepted',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionCancelValue(
      accepted: asBool(json['accepted'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['accepted'] = accepted;
    out.addAll(extra);
    return out;
  }
}

/// optional blank Session to reuse, location, and Agent preset.
class SessionCreateRequest {
  const SessionCreateRequest({
    this.workspaceId,
    this.cwd,
    this.sessionId,
    this.agentPreset,
    this.extra = const {},
  });

  /// Workspace the Session joins; exclusive with `cwd`.
  final String? workspaceId;
  /// Directory the Session owns when no Workspace is named.
  final String? cwd;
  /// Blank Session to reuse while it is reusable, or the identity of a new
  /// Session when none is stored under it.
  final String? sessionId;
  /// Preset the Session runs, replacing a reused Session's recorded preset; the
  /// configured default when omitted.
  final String? agentPreset;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionCreateRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'workspaceId',
      'cwd',
      'sessionId',
      'agentPreset',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionCreateRequest(
      workspaceId: asString(json['workspaceId']),
      cwd: asString(json['cwd']),
      sessionId: asString(json['sessionId']),
      agentPreset: asString(json['agentPreset']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    final localWorkspaceId = workspaceId; if (localWorkspaceId != null) out['workspaceId'] = localWorkspaceId;
    final localCwd = cwd; if (localCwd != null) out['cwd'] = localCwd;
    final localSessionId = sessionId; if (localSessionId != null) out['sessionId'] = localSessionId;
    final localAgentPreset = agentPreset; if (localAgentPreset != null) out['agentPreset'] = localAgentPreset;
    out.addAll(extra);
    return out;
  }
}

/// the created or reused Session identity and its preset when configured.
class SessionCreateValue {
  const SessionCreateValue({
    required this.sessionId,
    this.agentPreset,
    this.extra = const {},
  });

  /// The created or reused Session, which may differ from the requested
  /// `sessionId`.
  final String sessionId;
  /// Preset the Session runs, when the deployment composes a preset roster.
  final String? agentPreset;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionCreateValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
      'agentPreset',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionCreateValue(
      sessionId: asString(json['sessionId'])!,
      agentPreset: asString(json['agentPreset']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    final localAgentPreset = agentPreset; if (localAgentPreset != null) out['agentPreset'] = localAgentPreset;
    out.addAll(extra);
    return out;
  }
}

/// durable address, optional fixed cut, backward cursor, and page budget.
class SessionEventsRequest {
  const SessionEventsRequest({
    required this.address,
    this.throughSeq,
    this.beforeSeq,
    this.maxMessages,
    this.turnWindow,
    this.extra = const {},
  });

  final Map<String, Object?> address;
  /// Inclusive log cut; omission selects the observed log end. A follow opening
  /// reports the cut it covered so a caller can pin the same point.
  final num? throughSeq;
  final num? beforeSeq;
  final num? maxMessages;
  /// Stop at a Turn start after both minima, unless maxMessages or history
  /// exhaustion wins.
  final SessionEventsRequestTurnWindow? turnWindow;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionEventsRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'address',
      'throughSeq',
      'beforeSeq',
      'maxMessages',
      'turnWindow',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionEventsRequest(
      address: asMapOrEmpty(json['address']),
      throughSeq: asNum(json['throughSeq']),
      beforeSeq: asNum(json['beforeSeq']),
      maxMessages: asNum(json['maxMessages']),
      turnWindow: asModel<SessionEventsRequestTurnWindow>(json['turnWindow'], SessionEventsRequestTurnWindow.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['address'] = address;
    final localThroughSeq = throughSeq; if (localThroughSeq != null) out['throughSeq'] = localThroughSeq;
    final localBeforeSeq = beforeSeq; if (localBeforeSeq != null) out['beforeSeq'] = localBeforeSeq;
    final localMaxMessages = maxMessages; if (localMaxMessages != null) out['maxMessages'] = localMaxMessages;
    final localTurnWindow = turnWindow; if (localTurnWindow != null) out['turnWindow'] = localTurnWindow.toJson();
    out.addAll(extra);
    return out;
  }
}

/// Stop at a Turn start after both minima, unless maxMessages or history
/// exhaustion wins.
class SessionEventsRequestTurnWindow {
  const SessionEventsRequestTurnWindow({
    required this.minMessages,
    required this.minTurns,
    this.extra = const {},
  });

  /// Minimum append-origin user/assistant messages; must not exceed
  /// maxMessages.
  final num minMessages;
  /// Minimum Turn starts crossed, including the partial Turn at beforeSeq.
  final num minTurns;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionEventsRequestTurnWindow.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'minMessages',
      'minTurns',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionEventsRequestTurnWindow(
      minMessages: asNum(json['minMessages'])!,
      minTurns: asNum(json['minTurns'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['minMessages'] = minMessages;
    out['minTurns'] = minTurns;
    out.addAll(extra);
    return out;
  }
}

/// one chronological page with its inclusive cursor.
class SessionEventsValue {
  const SessionEventsValue({
    required this.cursor,
    required this.records,
    required this.hasMore,
    this.extra = const {},
  });

  final num cursor;
  final List<SessionEventsValueRecordsItem> records;
  final bool hasMore;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionEventsValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'cursor',
      'records',
      'hasMore',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionEventsValue(
      cursor: asNum(json['cursor'])!,
      records: asList<SessionEventsValueRecordsItem>(json['records'], SessionEventsValueRecordsItem.fromJson),
      hasMore: asBool(json['hasMore'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['cursor'] = cursor;
    out['records'] = records.map((e) => e.toJson()).toList();
    out['hasMore'] = hasMore;
    out.addAll(extra);
    return out;
  }
}

class SessionEventsValueRecordsItem {
  const SessionEventsValueRecordsItem({
    required this.type,
    required this.event,
    this.extra = const {},
  });

  final String type;
  final SessionEventsValueRecordsItemEvent event;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionEventsValueRecordsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'type',
      'event',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionEventsValueRecordsItem(
      type: asString(json['type'])!,
      event: asModel<SessionEventsValueRecordsItemEvent>(json['event'], SessionEventsValueRecordsItemEvent.fromJson)!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['type'] = type;
    out['event'] = event.toJson();
    out.addAll(extra);
    return out;
  }
}

class SessionEventsValueRecordsItemEvent {
  const SessionEventsValueRecordsItemEvent({
    required this.type,
    required this.seq,
    required this.time,
    required this.data,
    this.ignorable,
    this.sourceEventSeqs,
    this.surfaceOp,
    this.extra = const {},
  });

  final String type;
  final num seq;
  final num time;
  final Map<String, Object?> data;
  final bool? ignorable;
  /// Earlier sources on current surface events; opaque JSON on unknown
  /// ignorable events.
  final Map<String, Object?>? sourceEventSeqs;
  /// Canonical placement on current surface events; opaque JSON on unknown
  /// ignorable events.
  final Map<String, Object?>? surfaceOp;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionEventsValueRecordsItemEvent.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'type',
      'seq',
      'time',
      'data',
      'ignorable',
      'sourceEventSeqs',
      'surfaceOp',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionEventsValueRecordsItemEvent(
      type: asString(json['type'])!,
      seq: asNum(json['seq'])!,
      time: asNum(json['time'])!,
      data: asMapOrEmpty(json['data']),
      ignorable: asBool(json['ignorable']),
      sourceEventSeqs: asMap(json['sourceEventSeqs']),
      surfaceOp: asMap(json['surfaceOp']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['type'] = type;
    out['seq'] = seq;
    out['time'] = time;
    out['data'] = data;
    final localIgnorable = ignorable; if (localIgnorable != null) out['ignorable'] = localIgnorable;
    final localSourceEventSeqs = sourceEventSeqs; if (localSourceEventSeqs != null) out['sourceEventSeqs'] = localSourceEventSeqs;
    final localSurfaceOp = surfaceOp; if (localSurfaceOp != null) out['surfaceOp'] = localSurfaceOp;
    out.addAll(extra);
    return out;
  }
}

/// durable address and last committed sequence already held by the caller.
class SessionFollowRequest {
  const SessionFollowRequest({
    required this.address,
    this.activate,
    this.assistantStream,
    this.maxMessages,
    this.turnWindow,
    this.extra = const {},
  });

  final Map<String, Object?> address;
  /// Request background activation; omission leaves the read passive.
  final bool? activate;
  /// Include process-local assistant presentation frames for the Web client.
  final bool? assistantStream;
  final num? maxMessages;
  /// Stop at a Turn start after both minima, unless maxMessages or history
  /// exhaustion wins.
  final SessionFollowRequestTurnWindow? turnWindow;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionFollowRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'address',
      'activate',
      'assistantStream',
      'maxMessages',
      'turnWindow',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionFollowRequest(
      address: asMapOrEmpty(json['address']),
      activate: asBool(json['activate']),
      assistantStream: asBool(json['assistantStream']),
      maxMessages: asNum(json['maxMessages']),
      turnWindow: asModel<SessionFollowRequestTurnWindow>(json['turnWindow'], SessionFollowRequestTurnWindow.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['address'] = address;
    final localActivate = activate; if (localActivate != null) out['activate'] = localActivate;
    final localAssistantStream = assistantStream; if (localAssistantStream != null) out['assistantStream'] = localAssistantStream;
    final localMaxMessages = maxMessages; if (localMaxMessages != null) out['maxMessages'] = localMaxMessages;
    final localTurnWindow = turnWindow; if (localTurnWindow != null) out['turnWindow'] = localTurnWindow.toJson();
    out.addAll(extra);
    return out;
  }
}

/// Stop at a Turn start after both minima, unless maxMessages or history
/// exhaustion wins.
class SessionFollowRequestTurnWindow {
  const SessionFollowRequestTurnWindow({
    required this.minMessages,
    required this.minTurns,
    this.extra = const {},
  });

  /// Minimum append-origin user/assistant messages; must not exceed
  /// maxMessages.
  final num minMessages;
  /// Minimum Turn starts crossed, including the partial Turn at beforeSeq.
  final num minTurns;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionFollowRequestTurnWindow.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'minMessages',
      'minTurns',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionFollowRequestTurnWindow(
      minMessages: asNum(json['minMessages'])!,
      minTurns: asNum(json['minTurns'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['minMessages'] = minMessages;
    out['minTurns'] = minTurns;
    out.addAll(extra);
    return out;
  }
}

/// source Session, optional exact inclusive event boundary, and migration
/// preflight choice.
class SessionForkRequest {
  const SessionForkRequest({
    required this.sessionId,
    this.atSeq,
    this.allowMigration,
    this.extra = const {},
  });

  final String sessionId;
  /// Exact inclusive source event seq; omission selects the latest
  /// completed-turn prefix.
  final num? atSeq;
  /// False asks the Host to check for required migration before forking.
  /// Defaults to true.
  final bool? allowMigration;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionForkRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
      'atSeq',
      'allowMigration',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionForkRequest(
      sessionId: asString(json['sessionId'])!,
      atSeq: asNum(json['atSeq']),
      allowMigration: asBool(json['allowMigration']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    final localAtSeq = atSeq; if (localAtSeq != null) out['atSeq'] = localAtSeq;
    final localAllowMigration = allowMigration; if (localAllowMigration != null) out['allowMigration'] = localAllowMigration;
    out.addAll(extra);
    return out;
  }
}

/// the new Session identity.
class SessionForkValue {
  const SessionForkValue({
    required this.sessionId,
    this.extra = const {},
  });

  final String sessionId;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionForkValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionForkValue(
      sessionId: asString(json['sessionId'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out.addAll(extra);
    return out;
  }
}

/// reserved empty list request.
class SessionListRequest {
  const SessionListRequest({
    this.cursor,
    this.extra = const {},
  });

  final String? cursor;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'cursor',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListRequest(
      cursor: asString(json['cursor']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    final localCursor = cursor; if (localCursor != null) out['cursor'] = localCursor;
    out.addAll(extra);
    return out;
  }
}

/// visible Session summaries ordered by activity.
class SessionListValue {
  const SessionListValue({
    required this.items,
    this.extra = const {},
  });

  final List<SessionListValueItemsItem> items;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'items',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValue(
      items: asList<SessionListValueItemsItem>(json['items'], SessionListValueItemsItem.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['items'] = items.map((e) => e.toJson()).toList();
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItem {
  const SessionListValueItemsItem({
    required this.agentAvailable,
    this.formatStatus,
    required this.sessionId,
    required this.updatedAt,
    required this.running,
    required this.blank,
    this.parentSessionId,
    this.origin,
    this.cwd,
    this.projections,
    this.extra = const {},
  });

  /// Whether this Session currently owns a live Agent.
  final bool agentAvailable;
  /// Current for attached Sessions; otherwise the persistence format status
  /// when reported.
  final String? formatStatus;
  final String sessionId;
  final num updatedAt;
  final bool running;
  final bool blank;
  final String? parentSessionId;
  final String? origin;
  final String? cwd;
  final SessionListValueItemsItemProjections? projections;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'agentAvailable',
      'formatStatus',
      'sessionId',
      'updatedAt',
      'running',
      'blank',
      'parentSessionId',
      'origin',
      'cwd',
      'projections',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItem(
      agentAvailable: asBool(json['agentAvailable'])!,
      formatStatus: asString(json['formatStatus']),
      sessionId: asString(json['sessionId'])!,
      updatedAt: asNum(json['updatedAt'])!,
      running: asBool(json['running'])!,
      blank: asBool(json['blank'])!,
      parentSessionId: asString(json['parentSessionId']),
      origin: asString(json['origin']),
      cwd: asString(json['cwd']),
      projections: asModel<SessionListValueItemsItemProjections>(json['projections'], SessionListValueItemsItemProjections.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['agentAvailable'] = agentAvailable;
    final localFormatStatus = formatStatus; if (localFormatStatus != null) out['formatStatus'] = localFormatStatus;
    out['sessionId'] = sessionId;
    out['updatedAt'] = updatedAt;
    out['running'] = running;
    out['blank'] = blank;
    final localParentSessionId = parentSessionId; if (localParentSessionId != null) out['parentSessionId'] = localParentSessionId;
    final localOrigin = origin; if (localOrigin != null) out['origin'] = localOrigin;
    final localCwd = cwd; if (localCwd != null) out['cwd'] = localCwd;
    final localProjections = projections; if (localProjections != null) out['projections'] = localProjections.toJson();
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjections {
  const SessionListValueItemsItemProjections({
    required this.kind,
    required this.asOfSeq,
    required this.values,
    this.extra = const {},
  });

  /// `sequenced`: the Host's live registry produced the block for an attached
  /// Session, so `asOfSeq` is comparable with baselines and frames of the same
  /// connection. `cached`: a header-only listing viewed the block from the
  /// persisted projection cache, so `asOfSeq` is the stored record's own
  /// watermark and must not be compared with the connected Session's values.
  final String kind;
  /// Watermark of the block in the sequence space named by `kind`.
  final num asOfSeq;
  /// Provider-validated summary values present in the block; omitted keys
  /// remain unknown.
  final SessionListValueItemsItemProjectionsValues values;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjections.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'kind',
      'asOfSeq',
      'values',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjections(
      kind: asString(json['kind'])!,
      asOfSeq: asNum(json['asOfSeq'])!,
      values: asModel<SessionListValueItemsItemProjectionsValues>(json['values'], SessionListValueItemsItemProjectionsValues.fromJson)!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['kind'] = kind;
    out['asOfSeq'] = asOfSeq;
    out['values'] = values.toJson();
    out.addAll(extra);
    return out;
  }
}

/// Provider-validated summary values present in the block; omitted keys remain
/// unknown.
class SessionListValueItemsItemProjectionsValues {
  const SessionListValueItemsItemProjectionsValues({
    this.subagent,
    this.inbox,
    this.modelSelection,
    this.agentPreset,
    this.title,
    this.sessionListMetadata,
    this.workingDirectory,
    this.permissions,
    this.subagentCatalog,
    this.subagentTiming,
    this.tokenUsage,
    this.userQuestions,
    this.agentTeam,
    this.forgeChangeRequests,
    this.forgeWorktree,
    this.forkLineage,
    this.goal,
    this.plan,
    this.extra = const {},
  });

  /// Identity of a descriptor-backed subagent session. `null` ⟺ no valid
  /// descriptor (missing, malformed, or unrecognized-version — deliberately
  /// undistinguished). The sentinel is deliberately serializable: a value
  /// pushed over JSON transports must survive `JSON.stringify` losslessly,
  /// where an `undefined` field would be dropped and a stale identity would
  /// survive on the receiving side. The entry itself stays non-optional.
  final Map<String, Object?>? subagent;
  /// Pending agent input reconstructed from durable inbox splices.
  final SessionListValueItemsItemProjectionsValuesInbox? inbox;
  /// Recorded model selection for the next model step and the latest request.
  final SessionListValueItemsItemProjectionsValuesModelSelection? modelSelection;
  /// Preset the Session runs, or null when the deployment composes none.
  final String? agentPreset;
  /// The session's current normalized title — the latest `session/title`
  /// event's text (last-wins), or `null` before the first title lands. A plain
  /// string: the shape the client list rows consume.
  final String? title;
  /// Persisted facts used to summarize a Session without activating it.
  final SessionListValueItemsItemProjectionsValuesSessionListMetadata? sessionListMetadata;
  /// Recorded current directory for Session observations, or null when none is
  /// recorded.
  final String? workingDirectory;
  /// The session's current permission, folded from the three whole-value knob
  /// events (`permission/preset`, `sandbox/mode`, `approval/policy`) over the
  /// composition defaults. Selectable options come from the process-level
  /// catalog Remote. Key absence means no permission service is composed —
  /// clients hide the control.
  final SessionListValueItemsItemProjectionsValuesPermissions? permissions;
  /// Direct children in parent catalog event order, excluding fork-inherited
  /// facts.
  final List<Map<String, Object?>>? subagentCatalog;
  /// Active-turn duration and latest closed-turn completion for a
  /// descriptor-backed subagent session.
  final SessionListValueItemsItemProjectionsValuesSubagentTiming? subagentTiming;
  /// Provider-reported usage accumulated across the complete durable log.
  final SessionListValueItemsItemProjectionsValuesTokenUsage? tokenUsage;
  /// Timed questions that remain answerable in this Session, and the ones a
  /// late reply settled.
  final SessionListValueItemsItemProjectionsValuesUserQuestions? userQuestions;
  /// Durable roster and non-deleted task board of the Team rooted at the
  /// projected Session.
  final SessionListValueItemsItemProjectionsValuesAgentTeam? agentTeam;
  /// Every change request bound to the Session, hidden ones included, in
  /// binding order.
  final List<SessionListValueItemsItemProjectionsValuesForgeChangeRequestsItem>? forgeChangeRequests;
  /// The worktree the panel created for the Session while the Session works in
  /// it, else null.
  final Map<String, Object?>? forgeWorktree;
  /// Branch facts one reader was given for a branch of a shared Session.
  final SessionListValueItemsItemProjectionsValuesForkLineage? forkLineage;
  /// The session's current goal and admitted-round count, or `null` before the
  /// first create and after a clear tombstone. `goal/change` supplies the whole
  /// lifecycle value; matching admitted `user/message` events advance
  /// `roundsStarted`.
  final Map<String, Object?>? goal;
  /// Plan collaboration state folded from the plan command lifecycle and
  /// `plan/mode` events.
  final SessionListValueItemsItemProjectionsValuesPlan? plan;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValues.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'subagent',
      'inbox',
      'modelSelection',
      'agentPreset',
      'title',
      'sessionListMetadata',
      'workingDirectory',
      'permissions',
      'subagentCatalog',
      'subagentTiming',
      'tokenUsage',
      'userQuestions',
      'agentTeam',
      'forgeChangeRequests',
      'forgeWorktree',
      'forkLineage',
      'goal',
      'plan',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValues(
      subagent: asMap(json['subagent']),
      inbox: asModel<SessionListValueItemsItemProjectionsValuesInbox>(json['inbox'], SessionListValueItemsItemProjectionsValuesInbox.fromJson),
      modelSelection: asModel<SessionListValueItemsItemProjectionsValuesModelSelection>(json['modelSelection'], SessionListValueItemsItemProjectionsValuesModelSelection.fromJson),
      agentPreset: asString(json['agentPreset']),
      title: asString(json['title']),
      sessionListMetadata: asModel<SessionListValueItemsItemProjectionsValuesSessionListMetadata>(json['sessionListMetadata'], SessionListValueItemsItemProjectionsValuesSessionListMetadata.fromJson),
      workingDirectory: asString(json['workingDirectory']),
      permissions: asModel<SessionListValueItemsItemProjectionsValuesPermissions>(json['permissions'], SessionListValueItemsItemProjectionsValuesPermissions.fromJson),
      subagentCatalog: asMapList(json['subagentCatalog']),
      subagentTiming: asModel<SessionListValueItemsItemProjectionsValuesSubagentTiming>(json['subagentTiming'], SessionListValueItemsItemProjectionsValuesSubagentTiming.fromJson),
      tokenUsage: asModel<SessionListValueItemsItemProjectionsValuesTokenUsage>(json['tokenUsage'], SessionListValueItemsItemProjectionsValuesTokenUsage.fromJson),
      userQuestions: asModel<SessionListValueItemsItemProjectionsValuesUserQuestions>(json['userQuestions'], SessionListValueItemsItemProjectionsValuesUserQuestions.fromJson),
      agentTeam: asModel<SessionListValueItemsItemProjectionsValuesAgentTeam>(json['agentTeam'], SessionListValueItemsItemProjectionsValuesAgentTeam.fromJson),
      forgeChangeRequests: asListOrNull<SessionListValueItemsItemProjectionsValuesForgeChangeRequestsItem>(json['forgeChangeRequests'], SessionListValueItemsItemProjectionsValuesForgeChangeRequestsItem.fromJson),
      forgeWorktree: asMap(json['forgeWorktree']),
      forkLineage: asModel<SessionListValueItemsItemProjectionsValuesForkLineage>(json['forkLineage'], SessionListValueItemsItemProjectionsValuesForkLineage.fromJson),
      goal: asMap(json['goal']),
      plan: asModel<SessionListValueItemsItemProjectionsValuesPlan>(json['plan'], SessionListValueItemsItemProjectionsValuesPlan.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    final localSubagent = subagent; if (localSubagent != null) out['subagent'] = localSubagent;
    final localInbox = inbox; if (localInbox != null) out['inbox'] = localInbox.toJson();
    final localModelSelection = modelSelection; if (localModelSelection != null) out['modelSelection'] = localModelSelection.toJson();
    final localAgentPreset = agentPreset; if (localAgentPreset != null) out['agentPreset'] = localAgentPreset;
    final localTitle = title; if (localTitle != null) out['title'] = localTitle;
    final localSessionListMetadata = sessionListMetadata; if (localSessionListMetadata != null) out['sessionListMetadata'] = localSessionListMetadata.toJson();
    final localWorkingDirectory = workingDirectory; if (localWorkingDirectory != null) out['workingDirectory'] = localWorkingDirectory;
    final localPermissions = permissions; if (localPermissions != null) out['permissions'] = localPermissions.toJson();
    final localSubagentCatalog = subagentCatalog; if (localSubagentCatalog != null) out['subagentCatalog'] = localSubagentCatalog;
    final localSubagentTiming = subagentTiming; if (localSubagentTiming != null) out['subagentTiming'] = localSubagentTiming.toJson();
    final localTokenUsage = tokenUsage; if (localTokenUsage != null) out['tokenUsage'] = localTokenUsage.toJson();
    final localUserQuestions = userQuestions; if (localUserQuestions != null) out['userQuestions'] = localUserQuestions.toJson();
    final localAgentTeam = agentTeam; if (localAgentTeam != null) out['agentTeam'] = localAgentTeam.toJson();
    final localForgeChangeRequests = forgeChangeRequests; if (localForgeChangeRequests != null) out['forgeChangeRequests'] = localForgeChangeRequests.map((e) => e.toJson()).toList();
    final localForgeWorktree = forgeWorktree; if (localForgeWorktree != null) out['forgeWorktree'] = localForgeWorktree;
    final localForkLineage = forkLineage; if (localForkLineage != null) out['forkLineage'] = localForkLineage.toJson();
    final localGoal = goal; if (localGoal != null) out['goal'] = localGoal;
    final localPlan = plan; if (localPlan != null) out['plan'] = localPlan.toJson();
    out.addAll(extra);
    return out;
  }
}

/// Durable roster and non-deleted task board of the Team rooted at the
/// projected Session.
class SessionListValueItemsItemProjectionsValuesAgentTeam {
  const SessionListValueItemsItemProjectionsValuesAgentTeam({
    required this.members,
    required this.tasks,
    this.failure,
    this.extra = const {},
  });

  final List<SessionListValueItemsItemProjectionsValuesAgentTeamMembersItem> members;
  final List<SessionListValueItemsItemProjectionsValuesAgentTeamTasksItem> tasks;
  final String? failure;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesAgentTeam.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'members',
      'tasks',
      'failure',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesAgentTeam(
      members: asList<SessionListValueItemsItemProjectionsValuesAgentTeamMembersItem>(json['members'], SessionListValueItemsItemProjectionsValuesAgentTeamMembersItem.fromJson),
      tasks: asList<SessionListValueItemsItemProjectionsValuesAgentTeamTasksItem>(json['tasks'], SessionListValueItemsItemProjectionsValuesAgentTeamTasksItem.fromJson),
      failure: asString(json['failure']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['members'] = members.map((e) => e.toJson()).toList();
    out['tasks'] = tasks.map((e) => e.toJson()).toList();
    final localFailure = failure; if (localFailure != null) out['failure'] = localFailure;
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesAgentTeamMembersItem {
  const SessionListValueItemsItemProjectionsValuesAgentTeamMembersItem({
    required this.id,
    required this.name,
    required this.role,
    required this.phase,
    this.error,
    this.extra = const {},
  });

  final String id;
  final String name;
  final String role;
  /// Durable lifecycle; the Lead row is always `active`. Turn activity comes
  /// from Session status.
  final String phase;
  final String? error;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesAgentTeamMembersItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'id',
      'name',
      'role',
      'phase',
      'error',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesAgentTeamMembersItem(
      id: asString(json['id'])!,
      name: asString(json['name'])!,
      role: asString(json['role'])!,
      phase: asString(json['phase'])!,
      error: asString(json['error']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['id'] = id;
    out['name'] = name;
    out['role'] = role;
    out['phase'] = phase;
    final localError = error; if (localError != null) out['error'] = localError;
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesAgentTeamTasksItem {
  const SessionListValueItemsItemProjectionsValuesAgentTeamTasksItem({
    required this.id,
    required this.revision,
    required this.subject,
    required this.description,
    required this.status,
    required this.blockedBy,
    required this.writeScopes,
    this.ownerName,
    required this.ready,
    required this.writeScopeWarnings,
    this.extra = const {},
  });

  final String id;
  final num revision;
  final String subject;
  final String description;
  final String status;
  final List<String> blockedBy;
  final List<String> writeScopes;
  final String? ownerName;
  final bool ready;
  final List<String> writeScopeWarnings;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesAgentTeamTasksItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'id',
      'revision',
      'subject',
      'description',
      'status',
      'blockedBy',
      'writeScopes',
      'ownerName',
      'ready',
      'writeScopeWarnings',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesAgentTeamTasksItem(
      id: asString(json['id'])!,
      revision: asNum(json['revision'])!,
      subject: asString(json['subject'])!,
      description: asString(json['description'])!,
      status: asString(json['status'])!,
      blockedBy: asListRaw<String>(json['blockedBy']),
      writeScopes: asListRaw<String>(json['writeScopes']),
      ownerName: asString(json['ownerName']),
      ready: asBool(json['ready'])!,
      writeScopeWarnings: asListRaw<String>(json['writeScopeWarnings']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['id'] = id;
    out['revision'] = revision;
    out['subject'] = subject;
    out['description'] = description;
    out['status'] = status;
    out['blockedBy'] = blockedBy;
    out['writeScopes'] = writeScopes;
    final localOwnerName = ownerName; if (localOwnerName != null) out['ownerName'] = localOwnerName;
    out['ready'] = ready;
    out['writeScopeWarnings'] = writeScopeWarnings;
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesForgeChangeRequestsItem {
  const SessionListValueItemsItemProjectionsValuesForgeChangeRequestsItem({
    required this.url,
    required this.origin,
    required this.dismissed,
    this.extra = const {},
  });

  /// Web URL as first recorded.
  final String url;
  /// How the change request became bound.
  final String origin;
  /// Whether a dismissal hides the binding.
  final bool dismissed;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesForgeChangeRequestsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'url',
      'origin',
      'dismissed',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesForgeChangeRequestsItem(
      url: asString(json['url'])!,
      origin: asString(json['origin'])!,
      dismissed: asBool(json['dismissed'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['url'] = url;
    out['origin'] = origin;
    out['dismissed'] = dismissed;
    out.addAll(extra);
    return out;
  }
}

/// Branch facts one reader was given for a branch of a shared Session.
class SessionListValueItemsItemProjectionsValuesForkLineage {
  const SessionListValueItemsItemProjectionsValuesForkLineage({
    required this.origin,
    required this.sourceSessionId,
    required this.authoredByViewer,
    required this.workspaceReadOnly,
    this.extra = const {},
  });

  /// How the Session came to exist; only `fork` is published under this key.
  final String origin;
  /// Session the branch was cut from.
  final String sourceSessionId;
  /// True when the reader created the branch it is reading.
  final bool authoredByViewer;
  /// True when the branch's workspace stays read-only for its reader.
  final bool workspaceReadOnly;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesForkLineage.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'origin',
      'sourceSessionId',
      'authoredByViewer',
      'workspaceReadOnly',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesForkLineage(
      origin: asString(json['origin'])!,
      sourceSessionId: asString(json['sourceSessionId'])!,
      authoredByViewer: asBool(json['authoredByViewer'])!,
      workspaceReadOnly: asBool(json['workspaceReadOnly'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['origin'] = origin;
    out['sourceSessionId'] = sourceSessionId;
    out['authoredByViewer'] = authoredByViewer;
    out['workspaceReadOnly'] = workspaceReadOnly;
    out.addAll(extra);
    return out;
  }
}

/// Pending agent input reconstructed from durable inbox splices.
class SessionListValueItemsItemProjectionsValuesInbox {
  const SessionListValueItemsItemProjectionsValuesInbox({
    required this.nextTurn,
    required this.nextStep,
    this.extra = const {},
  });

  final List<Map<String, Object?>> nextTurn;
  final List<Map<String, Object?>> nextStep;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesInbox.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'next-turn',
      'next-step',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesInbox(
      nextTurn: asMapList(json['next-turn']) ?? const [],
      nextStep: asMapList(json['next-step']) ?? const [],
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['next-turn'] = nextTurn;
    out['next-step'] = nextStep;
    out.addAll(extra);
    return out;
  }
}

/// Recorded model selection for the next model step and the latest request.
class SessionListValueItemsItemProjectionsValuesModelSelection {
  const SessionListValueItemsItemProjectionsValuesModelSelection({
    this.lastUsed,
    this.next,
    this.extra = const {},
  });

  /// Selection used by the latest recorded model request.
  final Map<String, Object?>? lastUsed;
  /// Selection the next model step uses; null while the Agent's initial options
  /// supply the route.
  final Map<String, Object?>? next;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesModelSelection.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'lastUsed',
      'next',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesModelSelection(
      lastUsed: asMap(json['lastUsed']),
      next: asMap(json['next']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    final localLastUsed = lastUsed; if (localLastUsed != null) out['lastUsed'] = localLastUsed;
    final localNext = next; if (localNext != null) out['next'] = localNext;
    out.addAll(extra);
    return out;
  }
}

/// The session's current permission, folded from the three whole-value knob
/// events (`permission/preset`, `sandbox/mode`, `approval/policy`) over the
/// composition defaults. Selectable options come from the process-level catalog
/// Remote. Key absence means no permission service is composed — clients hide
/// the control.
class SessionListValueItemsItemProjectionsValuesPermissions {
  const SessionListValueItemsItemProjectionsValuesPermissions({
    required this.currentValue,
    this.extra = const {},
  });

  /// The effective current value: a configured preset key, `auto`, or `custom`.
  final String currentValue;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesPermissions.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'currentValue',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesPermissions(
      currentValue: asString(json['currentValue'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['currentValue'] = currentValue;
    out.addAll(extra);
    return out;
  }
}

/// Plan collaboration state folded from the plan command lifecycle and
/// `plan/mode` events.
class SessionListValueItemsItemProjectionsValuesPlan {
  const SessionListValueItemsItemProjectionsValuesPlan({
    required this.active,
    required this.pending,
    this.extra = const {},
  });

  final bool active;
  final bool pending;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesPlan.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'active',
      'pending',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesPlan(
      active: asBool(json['active'])!,
      pending: asBool(json['pending'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['active'] = active;
    out['pending'] = pending;
    out.addAll(extra);
    return out;
  }
}

/// Persisted facts used to summarize a Session without activating it.
class SessionListValueItemsItemProjectionsValuesSessionListMetadata {
  const SessionListValueItemsItemProjectionsValuesSessionListMetadata({
    required this.blank,
    this.lastPromptAt,
    this.extra = const {},
  });

  /// Whether the folded prefix contains no turn.
  final bool blank;
  /// Latest human-authored prompt time in the folded prefix.
  final num? lastPromptAt;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesSessionListMetadata.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'blank',
      'lastPromptAt',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesSessionListMetadata(
      blank: asBool(json['blank'])!,
      lastPromptAt: asNum(json['lastPromptAt']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['blank'] = blank;
    final localLastPromptAt = lastPromptAt; if (localLastPromptAt != null) out['lastPromptAt'] = localLastPromptAt;
    out.addAll(extra);
    return out;
  }
}

/// Active-turn duration and latest closed-turn completion for a
/// descriptor-backed subagent session.
class SessionListValueItemsItemProjectionsValuesSubagentTiming {
  const SessionListValueItemsItemProjectionsValuesSubagentTiming({
    required this.settledMs,
    this.active,
    this.lastTurnCompleted,
    this.extra = const {},
  });

  /// Milliseconds accumulated across completed turns after the child's own
  /// descriptor.
  final num settledMs;
  /// Same-cut bounds of the currently open turn, when one has not reached
  /// `turn/end`.
  final SessionListValueItemsItemProjectionsValuesSubagentTimingActive? active;
  /// Whether the latest closed turn after the child's own descriptor completed
  /// normally; absent while a turn is open or before one closes.
  final bool? lastTurnCompleted;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesSubagentTiming.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'settledMs',
      'active',
      'lastTurnCompleted',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesSubagentTiming(
      settledMs: asNum(json['settledMs'])!,
      active: asModel<SessionListValueItemsItemProjectionsValuesSubagentTimingActive>(json['active'], SessionListValueItemsItemProjectionsValuesSubagentTimingActive.fromJson),
      lastTurnCompleted: asBool(json['lastTurnCompleted']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['settledMs'] = settledMs;
    final localActive = active; if (localActive != null) out['active'] = localActive.toJson();
    final localLastTurnCompleted = lastTurnCompleted; if (localLastTurnCompleted != null) out['lastTurnCompleted'] = localLastTurnCompleted;
    out.addAll(extra);
    return out;
  }
}

/// Same-cut bounds of the currently open turn, when one has not reached
/// `turn/end`.
class SessionListValueItemsItemProjectionsValuesSubagentTimingActive {
  const SessionListValueItemsItemProjectionsValuesSubagentTimingActive({
    required this.since,
    required this.through,
    this.extra = const {},
  });

  /// Start of the open turn.
  final num since;
  /// Latest event time folded into this projection cut.
  final num through;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesSubagentTimingActive.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'since',
      'through',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesSubagentTimingActive(
      since: asNum(json['since'])!,
      through: asNum(json['through'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['since'] = since;
    out['through'] = through;
    out.addAll(extra);
    return out;
  }
}

/// Provider-reported usage accumulated across the complete durable log.
class SessionListValueItemsItemProjectionsValuesTokenUsage {
  const SessionListValueItemsItemProjectionsValuesTokenUsage({
    required this.uncachedInputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    this.extra = const {},
  });

  final num uncachedInputTokens;
  final num outputTokens;
  final num cacheReadTokens;
  final num cacheWriteTokens;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesTokenUsage.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'uncachedInputTokens',
      'outputTokens',
      'cacheReadTokens',
      'cacheWriteTokens',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesTokenUsage(
      uncachedInputTokens: asNum(json['uncachedInputTokens'])!,
      outputTokens: asNum(json['outputTokens'])!,
      cacheReadTokens: asNum(json['cacheReadTokens'])!,
      cacheWriteTokens: asNum(json['cacheWriteTokens'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['uncachedInputTokens'] = uncachedInputTokens;
    out['outputTokens'] = outputTokens;
    out['cacheReadTokens'] = cacheReadTokens;
    out['cacheWriteTokens'] = cacheWriteTokens;
    out.addAll(extra);
    return out;
  }
}

/// Timed questions that remain answerable in this Session, and the ones a late
/// reply settled.
class SessionListValueItemsItemProjectionsValuesUserQuestions {
  const SessionListValueItemsItemProjectionsValuesUserQuestions({
    required this.active,
    required this.settled,
    this.extra = const {},
  });

  /// Calls that can still take an answer, in ask order.
  final List<SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItem> active;
  /// Calls an answer settled, in settlement order.
  final List<SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItem> settled;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesUserQuestions.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'active',
      'settled',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesUserQuestions(
      active: asList<SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItem>(json['active'], SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItem.fromJson),
      settled: asList<SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItem>(json['settled'], SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItem.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['active'] = active.map((e) => e.toJson()).toList();
    out['settled'] = settled.map((e) => e.toJson()).toList();
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItem {
  const SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItem({
    required this.callId,
    required this.questions,
    required this.state,
    this.extra = const {},
  });

  final String callId;
  final List<SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItem> questions;
  final String state;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'callId',
      'questions',
      'state',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItem(
      callId: asString(json['callId'])!,
      questions: asList<SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItem>(json['questions'], SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItem.fromJson),
      state: asString(json['state'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['callId'] = callId;
    out['questions'] = questions.map((e) => e.toJson()).toList();
    out['state'] = state;
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItem {
  const SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItem({
    required this.id,
    required this.question,
    this.detail,
    this.header,
    this.options,
    this.multiSelect,
    this.intent,
    this.extra = const {},
  });

  /// Stable caller-provided question id, echoed in the answer.
  final String id;
  /// The question to display.
  final String question;
  /// Optional supporting detail rendered with the question but kept out of
  /// option labels.
  final String? detail;
  /// Optional short heading/group label.
  final String? header;
  /// Optional choices the UI can render as a menu.
  final List<SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItemOptionsItem>? options;
  /// Whether more than one option may be selected. Defaults to single-select.
  final bool? multiSelect;
  /// Optional presentation intent for capable UIs; absent asks for the generic
  /// option list.
  final Map<String, Object?>? intent;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'id',
      'question',
      'detail',
      'header',
      'options',
      'multiSelect',
      'intent',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItem(
      id: asString(json['id'])!,
      question: asString(json['question'])!,
      detail: asString(json['detail']),
      header: asString(json['header']),
      options: asListOrNull<SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItemOptionsItem>(json['options'], SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItemOptionsItem.fromJson),
      multiSelect: asBool(json['multiSelect']),
      intent: asMap(json['intent']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['id'] = id;
    out['question'] = question;
    final localDetail = detail; if (localDetail != null) out['detail'] = localDetail;
    final localHeader = header; if (localHeader != null) out['header'] = localHeader;
    final localOptions = options; if (localOptions != null) out['options'] = localOptions.map((e) => e.toJson()).toList();
    final localMultiSelect = multiSelect; if (localMultiSelect != null) out['multiSelect'] = localMultiSelect;
    final localIntent = intent; if (localIntent != null) out['intent'] = localIntent;
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItemOptionsItem {
  const SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItemOptionsItem({
    required this.label,
    this.description,
    this.extra = const {},
  });

  /// User-facing label.
  final String label;
  /// Optional extra context rendered by capable UIs.
  final String? description;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItemOptionsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'label',
      'description',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesUserQuestionsActiveItemQuestionsItemOptionsItem(
      label: asString(json['label'])!,
      description: asString(json['description']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['label'] = label;
    final localDescription = description; if (localDescription != null) out['description'] = localDescription;
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItem {
  const SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItem({
    required this.callId,
    required this.answers,
    this.extra = const {},
  });

  /// The settled call.
  final String callId;
  /// The recorded batch, one entry per question; empty when the late reply
  /// carried none.
  final List<SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItemAnswersItem> answers;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'callId',
      'answers',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItem(
      callId: asString(json['callId'])!,
      answers: asList<SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItemAnswersItem>(json['answers'], SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItemAnswersItem.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['callId'] = callId;
    out['answers'] = answers.map((e) => e.toJson()).toList();
    out.addAll(extra);
    return out;
  }
}

class SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItemAnswersItem {
  const SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItemAnswersItem({
    required this.id,
    required this.selected,
    this.custom,
    this.extra = const {},
  });

  /// The answered question id.
  final String id;
  /// Selected option labels. May accompany custom text for a multi-select
  /// question.
  final List<String> selected;
  /// Optional free-text "Other" answer.
  final String? custom;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItemAnswersItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'id',
      'selected',
      'custom',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionListValueItemsItemProjectionsValuesUserQuestionsSettledItemAnswersItem(
      id: asString(json['id'])!,
      selected: asListRaw<String>(json['selected']),
      custom: asString(json['custom']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['id'] = id;
    out['selected'] = selected;
    final localCustom = custom; if (localCustom != null) out['custom'] = localCustom;
    out.addAll(extra);
    return out;
  }
}

/// durable address, optional fixed cut, backward cursor, and page budget.
class SessionPageRequest {
  const SessionPageRequest({
    required this.address,
    this.throughSeq,
    this.beforeSeq,
    this.maxMessages,
    this.turnWindow,
    this.extra = const {},
  });

  final Map<String, Object?> address;
  /// Inclusive log cut; omission selects the observed log end. A follow opening
  /// reports the cut it covered so a caller can pin the same point.
  final num? throughSeq;
  final num? beforeSeq;
  final num? maxMessages;
  /// Stop at a Turn start after both minima, unless maxMessages or history
  /// exhaustion wins.
  final SessionPageRequestTurnWindow? turnWindow;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionPageRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'address',
      'throughSeq',
      'beforeSeq',
      'maxMessages',
      'turnWindow',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionPageRequest(
      address: asMapOrEmpty(json['address']),
      throughSeq: asNum(json['throughSeq']),
      beforeSeq: asNum(json['beforeSeq']),
      maxMessages: asNum(json['maxMessages']),
      turnWindow: asModel<SessionPageRequestTurnWindow>(json['turnWindow'], SessionPageRequestTurnWindow.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['address'] = address;
    final localThroughSeq = throughSeq; if (localThroughSeq != null) out['throughSeq'] = localThroughSeq;
    final localBeforeSeq = beforeSeq; if (localBeforeSeq != null) out['beforeSeq'] = localBeforeSeq;
    final localMaxMessages = maxMessages; if (localMaxMessages != null) out['maxMessages'] = localMaxMessages;
    final localTurnWindow = turnWindow; if (localTurnWindow != null) out['turnWindow'] = localTurnWindow.toJson();
    out.addAll(extra);
    return out;
  }
}

/// Stop at a Turn start after both minima, unless maxMessages or history
/// exhaustion wins.
class SessionPageRequestTurnWindow {
  const SessionPageRequestTurnWindow({
    required this.minMessages,
    required this.minTurns,
    this.extra = const {},
  });

  /// Minimum append-origin user/assistant messages; must not exceed
  /// maxMessages.
  final num minMessages;
  /// Minimum Turn starts crossed, including the partial Turn at beforeSeq.
  final num minTurns;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionPageRequestTurnWindow.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'minMessages',
      'minTurns',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionPageRequestTurnWindow(
      minMessages: asNum(json['minMessages'])!,
      minTurns: asNum(json['minTurns'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['minMessages'] = minMessages;
    out['minTurns'] = minTurns;
    out.addAll(extra);
    return out;
  }
}

/// one chronological page with its inclusive cursor; an omitted `throughSeq`
/// selects the observed log end.
class SessionPageValue {
  const SessionPageValue({
    required this.cursor,
    required this.records,
    required this.hasMore,
    this.extra = const {},
  });

  final num cursor;
  final List<SessionPageValueRecordsItem> records;
  final bool hasMore;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionPageValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'cursor',
      'records',
      'hasMore',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionPageValue(
      cursor: asNum(json['cursor'])!,
      records: asList<SessionPageValueRecordsItem>(json['records'], SessionPageValueRecordsItem.fromJson),
      hasMore: asBool(json['hasMore'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['cursor'] = cursor;
    out['records'] = records.map((e) => e.toJson()).toList();
    out['hasMore'] = hasMore;
    out.addAll(extra);
    return out;
  }
}

class SessionPageValueRecordsItem {
  const SessionPageValueRecordsItem({
    required this.type,
    required this.event,
    this.extra = const {},
  });

  final String type;
  final SessionPageValueRecordsItemEvent event;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionPageValueRecordsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'type',
      'event',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionPageValueRecordsItem(
      type: asString(json['type'])!,
      event: asModel<SessionPageValueRecordsItemEvent>(json['event'], SessionPageValueRecordsItemEvent.fromJson)!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['type'] = type;
    out['event'] = event.toJson();
    out.addAll(extra);
    return out;
  }
}

class SessionPageValueRecordsItemEvent {
  const SessionPageValueRecordsItemEvent({
    required this.type,
    required this.seq,
    required this.time,
    required this.data,
    this.ignorable,
    this.sourceEventSeqs,
    this.surfaceOp,
    this.extra = const {},
  });

  final String type;
  final num seq;
  final num time;
  final Map<String, Object?> data;
  final bool? ignorable;
  /// Earlier sources on current surface events; opaque JSON on unknown
  /// ignorable events.
  final Map<String, Object?>? sourceEventSeqs;
  /// Canonical placement on current surface events; opaque JSON on unknown
  /// ignorable events.
  final Map<String, Object?>? surfaceOp;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionPageValueRecordsItemEvent.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'type',
      'seq',
      'time',
      'data',
      'ignorable',
      'sourceEventSeqs',
      'surfaceOp',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionPageValueRecordsItemEvent(
      type: asString(json['type'])!,
      seq: asNum(json['seq'])!,
      time: asNum(json['time'])!,
      data: asMapOrEmpty(json['data']),
      ignorable: asBool(json['ignorable']),
      sourceEventSeqs: asMap(json['sourceEventSeqs']),
      surfaceOp: asMap(json['surfaceOp']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['type'] = type;
    out['seq'] = seq;
    out['time'] = time;
    out['data'] = data;
    final localIgnorable = ignorable; if (localIgnorable != null) out['ignorable'] = localIgnorable;
    final localSourceEventSeqs = sourceEventSeqs; if (localSourceEventSeqs != null) out['sourceEventSeqs'] = localSourceEventSeqs;
    final localSurfaceOp = surfaceOp; if (localSurfaceOp != null) out['surfaceOp'] = localSurfaceOp;
    out.addAll(extra);
    return out;
  }
}

/// Session whose current values are required.
class SessionProjectionsRequest {
  const SessionProjectionsRequest({
    required this.sessionId,
    this.extra = const {},
  });

  final String sessionId;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionProjectionsRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionProjectionsRequest(
      sessionId: asString(json['sessionId'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out.addAll(extra);
    return out;
  }
}

/// Session identity, prompt content, source metadata, and delivery mode.
class SessionPromptRequest {
  const SessionPromptRequest({
    required this.requestId,
    required this.sessionId,
    required this.mode,
    required this.content,
    this.clientTimeZone,
    this.extra = const {},
  });

  /// Client-minted identity persisted on the exact accepted user message.
  final String requestId;
  final String sessionId;
  final SessionPromptRequestMode mode;
  /// At least one non-whitespace text part or attachment.
  final List<Map<String, Object?>> content;
  final String? clientTimeZone;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionPromptRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'requestId',
      'sessionId',
      'mode',
      'content',
      'clientTimeZone',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionPromptRequest(
      requestId: asString(json['requestId'])!,
      sessionId: asString(json['sessionId'])!,
      mode: SessionPromptRequestModeCodec.fromWire(json['mode']),
      content: asMapList(json['content']) ?? const [],
      clientTimeZone: asString(json['clientTimeZone']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['requestId'] = requestId;
    out['sessionId'] = sessionId;
    out['mode'] = mode.wire;
    out['content'] = content;
    final localClientTimeZone = clientTimeZone; if (localClientTimeZone != null) out['clientTimeZone'] = localClientTimeZone;
    out.addAll(extra);
    return out;
  }
}

/// acknowledgement that the Agent accepted the prompt.
class SessionPromptValue {
  const SessionPromptValue({
    required this.accepted,
    this.extra = const {},
  });

  final bool accepted;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionPromptValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'accepted',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionPromptValue(
      accepted: asBool(json['accepted'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['accepted'] = accepted;
    out.addAll(extra);
    return out;
  }
}

/// Session identity and proposed title.
class SessionRenameRequest {
  const SessionRenameRequest({
    required this.sessionId,
    required this.title,
    this.extra = const {},
  });

  final String sessionId;
  final String title;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionRenameRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
      'title',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionRenameRequest(
      sessionId: asString(json['sessionId'])!,
      title: asString(json['title'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out['title'] = title;
    out.addAll(extra);
    return out;
  }
}

/// the accepted title and durable event sequence.
class SessionRenameValue {
  const SessionRenameValue({
    required this.title,
    required this.seq,
    this.extra = const {},
  });

  final String title;
  final num seq;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionRenameValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'title',
      'seq',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionRenameValue(
      title: asString(json['title'])!,
      seq: asNum(json['seq'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['title'] = title;
    out['seq'] = seq;
    out.addAll(extra);
    return out;
  }
}

/// literal message-content query.
class SessionSearchRequest {
  const SessionSearchRequest({
    required this.query,
    this.extra = const {},
  });

  final String query;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionSearchRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'query',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionSearchRequest(
      query: asString(json['query'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['query'] = query;
    out.addAll(extra);
    return out;
  }
}

/// authorized bounded Session search results.
class SessionSearchValue {
  const SessionSearchValue({
    required this.items,
    required this.hasMore,
    this.extra = const {},
  });

  final List<SessionSearchValueItemsItem> items;
  final bool hasMore;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionSearchValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'items',
      'hasMore',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionSearchValue(
      items: asList<SessionSearchValueItemsItem>(json['items'], SessionSearchValueItemsItem.fromJson),
      hasMore: asBool(json['hasMore'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['items'] = items.map((e) => e.toJson()).toList();
    out['hasMore'] = hasMore;
    out.addAll(extra);
    return out;
  }
}

class SessionSearchValueItemsItem {
  const SessionSearchValueItemsItem({
    required this.sessionId,
    required this.snippet,
    this.extra = const {},
  });

  final String sessionId;
  final String snippet;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionSearchValueItemsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
      'snippet',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionSearchValueItemsItem(
      sessionId: asString(json['sessionId'])!,
      snippet: asString(json['snippet'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out['snippet'] = snippet;
    out.addAll(extra);
    return out;
  }
}

/// target Session.
class SessionStateRequest {
  const SessionStateRequest({
    required this.sessionId,
    this.extra = const {},
  });

  final String sessionId;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionStateRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionStateRequest(
      sessionId: asString(json['sessionId'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out.addAll(extra);
    return out;
  }
}

/// current passive state.
class SessionStateValue {
  const SessionStateValue({
    required this.cursor,
    required this.active,
    required this.running,
    this.queue,
    required this.pendingInput,
    this.extra = const {},
  });

  final num cursor;
  final bool active;
  final bool running;
  final List<SessionStateValueQueueItem>? queue;
  /// Pending Remote requests sampled when this state was read. A pending change
  /// alone does not trigger `observeState`; `wait` refreshes on its own
  /// interval.
  final List<SessionStateValuePendingInputItem> pendingInput;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionStateValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'cursor',
      'active',
      'running',
      'queue',
      'pendingInput',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionStateValue(
      cursor: asNum(json['cursor'])!,
      active: asBool(json['active'])!,
      running: asBool(json['running'])!,
      queue: asListOrNull<SessionStateValueQueueItem>(json['queue'], SessionStateValueQueueItem.fromJson),
      pendingInput: asEnumList<SessionStateValuePendingInputItem>(json['pendingInput'], SessionStateValuePendingInputItemCodec.fromWire),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['cursor'] = cursor;
    out['active'] = active;
    out['running'] = running;
    final localQueue = queue; if (localQueue != null) out['queue'] = localQueue.map((e) => e.toJson()).toList();
    out['pendingInput'] = pendingInput.map((e) => e.wire).toList();
    out.addAll(extra);
    return out;
  }
}

class SessionStateValueQueueItem {
  const SessionStateValueQueueItem({
    required this.id,
    required this.placement,
    this.rpcId,
    required this.content,
    this.extra = const {},
  });

  final String id;
  final SessionStateValueQueueItemPlacement placement;
  final String? rpcId;
  final List<Map<String, Object?>> content;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SessionStateValueQueueItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'id',
      'placement',
      'rpcId',
      'content',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SessionStateValueQueueItem(
      id: asString(json['id'])!,
      placement: SessionStateValueQueueItemPlacementCodec.fromWire(json['placement']),
      rpcId: asString(json['rpcId']),
      content: asMapList(json['content']) ?? const [],
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['id'] = id;
    out['placement'] = placement.wire;
    final localRpcId = rpcId; if (localRpcId != null) out['rpcId'] = localRpcId;
    out['content'] = content;
    out.addAll(extra);
    return out;
  }
}

/// Session identity whose cwd and preset select the catalog view.
class SkillsListRequest {
  const SkillsListRequest({
    required this.sessionId,
    this.extra = const {},
  });

  final String sessionId;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SkillsListRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'sessionId',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SkillsListRequest(
      sessionId: asString(json['sessionId'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['sessionId'] = sessionId;
    out.addAll(extra);
    return out;
  }
}

/// user-invocable skill metadata without loading skill bodies.
class SkillsListValue {
  const SkillsListValue({
    required this.skills,
    this.extra = const {},
  });

  final List<SkillsListValueSkillsItem> skills;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SkillsListValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'skills',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SkillsListValue(
      skills: asList<SkillsListValueSkillsItem>(json['skills'], SkillsListValueSkillsItem.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['skills'] = skills.map((e) => e.toJson()).toList();
    out.addAll(extra);
    return out;
  }
}

class SkillsListValueSkillsItem {
  const SkillsListValueSkillsItem({
    this.path,
    required this.name,
    required this.description,
    this.whenToUse,
    required this.modelInvocable,
    this.extra = const {},
  });

  /// Absolute SKILL.md path when supplied by a filesystem provider.
  final String? path;
  /// Kebab-case identifier referenced as `/name`.
  final String name;
  /// Short routing description.
  final String description;
  /// Optional extra routing guidance.
  final String? whenToUse;
  /// Whether the same skill is also advertised to the model.
  final bool modelInvocable;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory SkillsListValueSkillsItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'path',
      'name',
      'description',
      'whenToUse',
      'modelInvocable',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return SkillsListValueSkillsItem(
      path: asString(json['path']),
      name: asString(json['name'])!,
      description: asString(json['description'])!,
      whenToUse: asString(json['whenToUse']),
      modelInvocable: asBool(json['modelInvocable'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    final localPath = path; if (localPath != null) out['path'] = localPath;
    out['name'] = name;
    out['description'] = description;
    final localWhenToUse = whenToUse; if (localWhenToUse != null) out['whenToUse'] = localWhenToUse;
    out['modelInvocable'] = modelInvocable;
    out.addAll(extra);
    return out;
  }
}

/// Complete structured answer batch, one item per question of the call.
class UserQuestionsAnswerRequest {
  const UserQuestionsAnswerRequest({
    required this.answers,
    this.extra = const {},
  });

  /// Structured answers keyed by question id.
  final List<UserQuestionsAnswerRequestAnswersItem> answers;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory UserQuestionsAnswerRequest.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'answers',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return UserQuestionsAnswerRequest(
      answers: asList<UserQuestionsAnswerRequestAnswersItem>(json['answers'], UserQuestionsAnswerRequestAnswersItem.fromJson),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['answers'] = answers.map((e) => e.toJson()).toList();
    out.addAll(extra);
    return out;
  }
}

class UserQuestionsAnswerRequestAnswersItem {
  const UserQuestionsAnswerRequestAnswersItem({
    required this.id,
    required this.selected,
    this.custom,
    this.extra = const {},
  });

  /// The answered question id.
  final String id;
  /// Selected option labels. May accompany custom text for a multi-select
  /// question.
  final List<String> selected;
  /// Optional free-text "Other" answer.
  final String? custom;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory UserQuestionsAnswerRequestAnswersItem.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'id',
      'selected',
      'custom',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return UserQuestionsAnswerRequestAnswersItem(
      id: asString(json['id'])!,
      selected: asListRaw<String>(json['selected']),
      custom: asString(json['custom']),
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['id'] = id;
    out['selected'] = selected;
    final localCustom = custom; if (localCustom != null) out['custom'] = localCustom;
    out.addAll(extra);
    return out;
  }
}

/// One Host-computed remaining duration, or no frames once the wait ended.
class UserQuestionsAttachWaitValue {
  const UserQuestionsAttachWaitValue({
    required this.remainingMs,
    this.extra = const {},
  });

  final num remainingMs;

  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。
  final Map<String, Object?> extra;

  factory UserQuestionsAttachWaitValue.fromJson(Map<String, Object?> json) {
    const known = <String>{
      'remainingMs',
    };
    final rest = <String, Object?>{};
    for (final e in json.entries) {
      if (!known.contains(e.key)) rest[e.key] = e.value;
    }
    return UserQuestionsAttachWaitValue(
      remainingMs: asNum(json['remainingMs'])!,
      extra: rest,
    );
  }

  Map<String, Object?> toJson() {
    final out = <String, Object?>{};
    out['remainingMs'] = remainingMs;
    out.addAll(extra);
    return out;
  }
}

/// 端点载体索引 —— 双载具是协议强制要求（见 docs/60-protocol-feasibility.md §5.1）。
///
/// 走错载体分别得到 `gateway/signature-invalid`（unary 走 mux）与 404（stream 走 HTTP）。
enum EndpointTransport { unary, stream }

const Map<String, EndpointTransport> endpointTransports = {
  'session/list': EndpointTransport.unary,
  'session/state': EndpointTransport.unary,
  'session/create': EndpointTransport.unary,
  'session/prompt': EndpointTransport.unary,
  'session/rename': EndpointTransport.unary,
  'session/fork': EndpointTransport.unary,
  'session/cancel': EndpointTransport.unary,
  'session/events': EndpointTransport.unary,
  'session/follow': EndpointTransport.stream,
  'session/page': EndpointTransport.unary,
  'session/search': EndpointTransport.unary,
  'session/projections': EndpointTransport.unary,
  'job/list': EndpointTransport.stream,
  'job/follow': EndpointTransport.stream,
  'job/kill': EndpointTransport.unary,
  'workspace/follow': EndpointTransport.stream,
  'userQuestions/answer': EndpointTransport.unary,
  'userQuestions/attachWait': EndpointTransport.stream,
  'fileReferences/list': EndpointTransport.unary,
  'skills/list': EndpointTransport.unary,
};
