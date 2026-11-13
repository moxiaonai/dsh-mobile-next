/// 多语言支持。
///
/// ## 设计取舍：为什么不用 `flutter_localizations` + ARB
///
/// 标准做法要 `intl` 依赖、`l10n.yaml`、代码生成。本项目的文案集中在
/// 界面层，且只需要中英两种，引入整套生成的收益不抵成本：
///
/// - 生成物进版本库，每次改文案都要重新 generate
/// - `BuildContext` 依赖让纯 Dart 单测变麻烦（现有 190+ 测试大多不挂 Widget 树）
///
/// 这里用一个显式的字典表 + `AppStrings.of(context)`，满足三点：
/// 1. 新增语言只加一个 map
/// 2. 缺翻译时**回退到中文**而不是显示 key
/// 3. 单测可以直接 `AppStrings.forLocale('en')`，不需要 context
///
/// ## 与 DSH（WebView）的关系
///
/// App 的语言**同时决定 WebView 的语言**：DSH 前端的语言偏好存在
/// Host 的 user-settings（namespace `locale`，字段 `preference`）；
/// 未设置时它「delegate to the browser」，而 WebView 默认 `en-US`。
/// 因此我们把语言通过 `Accept-Language` 与注入脚本传给页面。
library;

import 'package:flutter/widgets.dart';

/// 支持的语言。
enum AppLanguage {
  /// 跟随系统。
  system,

  /// 简体中文。
  zh,

  /// English.
  en,
}

/// 语言偏好 → BCP 47 标签（用于 WebView 与 DSH 设置）。
extension AppLanguageTag on AppLanguage {
  /// `null` 表示跟随系统（不强行覆盖）。
  String? get tag => switch (this) {
    AppLanguage.system => null,
    AppLanguage.zh => 'zh-CN',
    AppLanguage.en => 'en-US',
  };

  /// 设置页显示的名字（用各自的语言书写，不翻译）。
  String get label => switch (this) {
    AppLanguage.system => '跟随系统',
    AppLanguage.zh => '简体中文',
    AppLanguage.en => 'English',
  };
}

/// 从系统 locale 解析出实际语言。
AppLanguage resolveLanguage(AppLanguage pref, Locale? system) {
  if (pref != AppLanguage.system) return pref;
  final code = system?.languageCode;
  return code == 'zh' ? AppLanguage.zh : AppLanguage.en;
}

/// 文案表。
///
/// 键名用点分层级（`nav.tasks`），与 DSH 的 locale 字典风格一致，
/// 便于将来把两边的键对齐。
class AppStrings {
  const AppStrings._(this.language, this._values);

  final AppLanguage language;
  final Map<String, String> _values;

  /// 取文案。缺失时回退到中文，再缺则返回键名（便于发现漏翻）。
  String call(String key) =>
      _values[key] ?? _zh[key] ?? key;

  /// 带占位符的文案：`t('tasks.count', {'n': '5'})`。
  ///
  /// 用简单的 `{name}` 替换而不是 intl 的 ICU：只需要插值，
  /// 复数规则中英都简单（英文 `1 session` vs `2 sessions` 差异
  /// 由调用方用不同键表达，避免引入复数引擎）。
  String withArgs(String key, Map<String, Object?> args) {
    var text = call(key);
    for (final entry in args.entries) {
      text = text.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return text;
  }

  /// 按语言取文案表。
  static AppStrings forLanguage(AppLanguage language) {
    final table = switch (language) {
      AppLanguage.zh || AppLanguage.system => _zh,
      AppLanguage.en => _en,
    };
    return AppStrings._(language, table);
  }

  /// 从 context 取（依赖 `AppLocaleScope`）。
  static AppStrings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppLocaleScope>();
    return forLanguage(scope?.language ?? AppLanguage.zh);
  }

  // ── 中文（基准表，其余语言按需补齐）──
  static const Map<String, String> _zh = {
    // 导航
    'nav.tasks': '任务',
    'nav.sessions': '会话',
    'nav.devices': '设备',
    'nav.inbox': '通知',
    'nav.settings': '设置',
    // 通用
    'common.retry': '重试',
    'common.refresh': '刷新',
    'common.cancel': '取消',
    'common.close': '关闭',
    'common.back': '返回',
    'common.copy': '复制',
    'common.copied': '已复制',
    'common.confirm': '确认',
    'common.loading': '加载中…',
    'common.failed': '失败',
    'common.empty': '暂无内容',
    // 未配对
    'unpaired.title': '还没有配对电脑',
    'unpaired.hint': '在电脑上打开 DSH 的「移动访问」面板生成二维码，\n然后用这台手机扫一下。',
    'unpaired.scan': '扫码配对',
    'unpaired.retry': '重试连接已配对电脑',
    // 连接
    'connect.connecting': '连接中…',
    'connect.reconnecting': '正在连接已配对电脑…',
    'connect.connected': '已连接',
    'connect.failed': '连接失败',
    // 设置页
    'settings.appearance': '外观',
    'settings.language': '语言',
    'settings.language.system': '跟随系统',
    'settings.language.hint': '同时影响 App 与内嵌的 DSH 页面',
    // 会话
    'session.running': '运行中',
    'session.idle': '空闲',
    'session.history': '历史',
    'session.jobs': '后台任务',
    'session.blank': '这个会话还没有内容',
    // 配对页
    'pair.title': '添加电脑',
    'pair.step.scan': '扫码',
    'pair.step.verify': '校验',
    'pair.step.done': '完成',
    'pair.scanHint': '把电脑上的配对二维码放进框内',
    'pair.openCamera': '打开相机',
    'pair.stopScan': '停止扫码',
    'pair.pasteLink': '或粘贴配对链接',
    'pair.submit': '配对',
    'pair.success': '配对成功',
    'pair.failed': '配对失败',
    'pair.enterApp': '进入任务',
    // 外观设置页
    'appearance.title': '外观',
    'appearance.theme': '主题',
    'appearance.theme.system': '跟随系统',
    'appearance.theme.light': '浅色',
    'appearance.theme.dark': '深色',
    'appearance.language': '语言',
    'appearance.language.hint': '同时影响 App 与内嵌的 DSH 页面',
    'appearance.font': '字号',
    'appearance.font.label': '正文字号',
    'appearance.font.hint': '影响正文、代码与选项；界面标签保持最小可读尺寸',
    'appearance.scale': '页面缩放',
    'appearance.scale.hint': '仅 Android App；80–125%，步进 5',
    'appearance.motion': '动效',
    'appearance.motion.system': '跟随系统',
    'appearance.motion.reduced': '始终减弱',
    'appearance.preview': '预览',
    'appearance.preview.sample': '预览：这是一段正文示例。Aa 0123456789',
    'appearance.reset': '恢复默认',
    'appearance.reset.confirmTitle': '恢复默认外观？',
    'appearance.reset.confirmNote':
        '字号回到 16、缩放 100%，主题与语言跟随系统。不会影响任务和会话。',
    'appearance.reset.done': '已恢复默认外观',
    'appearance.increase': '增加',
    'appearance.decrease': '减少',
    // 任务页
    'tasks.title': '任务',
    'tasks.count': '{n} 个会话',
    'tasks.empty': '还没有任务',
    'tasks.emptyHint': '在电脑上开始一个对话，它就会出现在这里',
    'tasks.needsYou': '需要你',
    'tasks.running': '进行中',
    'tasks.other': '其他',
    'tasks.awaiting': '等回答',
    'tasks.awaitingCount': '等 {n} 个回答',
    // 时间
    'time.justNow': '刚刚',
    'time.minutesAgo': '{n} 分钟前',
    'time.hoursAgo': '{n} 小时前',
    'time.yesterday': '昨天',
    'time.daysAgo': '{n} 天前',
    'time.monthsAgo': '{n} 个月前',
    // 设备页
    'devices.title': '设备',
    'devices.add': '添加电脑',
    'devices.pairedCount': '{n} 台已配对设备',
    'devices.others': '其他电脑',
    'devices.empty': '还没有配对电脑',
    'devices.emptyHint': '在电脑上打开「移动访问」面板生成二维码，\n点下面的按钮扫码配对。',
    'devices.security': '安全',
    'devices.revokeAll': '撤销本机全部配对',
    'devices.revokeAllHint': '这会删掉本机保存的全部配对凭据，并断开当前连接。电脑上的设备记录仍可在「移动访问」面板删除。',
    'devices.revokeAllConfirm': '撤销配对',
    'devices.current': '当前',
    'devices.reconnect': '重新连接',
    'devices.diagnostics': '连接诊断',
    'devices.repair': '重新配对',
    'devices.more': '更多操作',
    'devices.reachable': '可达',
    'devices.checking': '检测中',
    'devices.unreachable': '暂不可达',
    'devices.removed': '电脑端已移除',
    'devices.expired': '配对已过期',
    'devices.lan': '局域网',
    'devices.remote': '远程',
    // 会话列表
    'sessions.title': '会话',
    'sessions.search': '搜索会话、工作区…',
    'sessions.clear': '清除',
    'sessions.all': '全部',
    'sessions.withAgent': '有 Agent',
    'sessions.groupByProject': '按项目',
    'sessions.groupByState': '按状态',
    'sessions.empty': '暂无会话',
    'sessions.emptyHint': '在电脑上开始一个任务后会出现在这里',
    'sessions.noMatch': '没有匹配的会话',
    'sessions.noMatchHint': '试试别的关键词',
    'sessions.agentReady': 'Agent 就绪',
    'sessions.new': '新建会话',
    'sessions.createFailed': '没能新建会话，请检查连接后重试',
    'sessions.createFailedWhy': '新建会话失败：{e}',
    'sessions.created': '已新建会话',
    'sessions.rowLabel': '会话 {id}',
    'sessions.groupOther': '未归类',
    'sessions.groupExpanded': '{name}，{n} 个会话，已展开',
    'sessions.groupCollapsed': '{name}，{n} 个会话，已收起',
    'sessions.expand': '展开',
    'sessions.collapse': '收起',
    'sessions.filter': '筛选',
    'sessions.expandAll': '全部展开',
    'sessions.collapseAll': '全部收起',
    'sessions.searchAction': '搜索',

    // 会话状态
    'session.state.running': '运行中',
    'session.state.idle': '空闲',
    'session.state.history': '历史',
    // 通知中心
    'inbox.title': '通知',
    'inbox.empty': '暂无通知',
    'inbox.emptyHint': '审批与提问会出现在这里',
    'inbox.approval': '审批',
    'inbox.question': '提问',
    // 后台任务
    'jobs.title': '后台任务',
    'jobs.empty': '暂无后台任务',
    'jobs.emptyHint': 'Agent 运行的长命令会出现在这里',
    'jobs.kill': '终止',
    'jobs.output': '输出',
    'jobs.running': '运行中',
    'jobs.done': '已完成',
    'jobs.failed': '失败',
    'jobs.exitCode': '退出码 {n}',
    // 诊断
    'diag.title': '诊断',
    'diag.rerun': '重新检查',
    'diag.copy': '复制报告',
    'diag.copied': '报告已复制',
    'diag.empty': '暂无诊断结果',
    'diag.passed': '正常',
    'diag.warn': '注意',
    'diag.failed': '失败',
    'diag.unknown': '未检查',
    // 审批 / 提问
    'approval.allow': '允许',
    'approval.deny': '拒绝',
    'approval.title': '需要审批',
    'question.answer': '回答',
    'question.submit': '提交',
    'question.title': '需要你的回答',
    // 错误
    'error.network': '网络不可达',
    'error.networkHint': '确认手机与电脑在同一 Wi-Fi，且电脑上的移动访问已开启',
    'error.timeout': '连接超时',
    'error.timeoutHint': '电脑可能正在忙，或网络不稳定',
    'error.auth': '配对已失效',
    'error.authHint': '在电脑上重新生成配对二维码，然后重新配对',
    'error.unknown': '出现未知错误',
    'error.detail': '查看详情',
    'error.hideDetail': '收起详情',
    // 配对页补充
    'pair.back': '返回',
    'pair.securityNote': '只连接你自己电脑上的 DSH。配对后手机可操作电脑上的全部会话。',
    'pair.cameraUnavailable': '相机不可用',
    'pair.cameraHint': '请在系统设置里允许相机权限，\n或直接用下面的「粘贴配对链接」。',
    'pair.scanning': '正在识别…',
    'pair.idle': '还没有开始扫码',
    'pair.startScan': '点下面的按钮打开相机\n扫描电脑上的配对二维码',
    'pair.retry': '重试',
    'pair.useLink': '改用链接配对',
    'devices.reachableLatency': '可达 · 延迟约 {n}ms',
    'devices.unreachableLast': '暂不可达 · 最后连接 {t}',
    'devices.removedRepair': '电脑端已移除 · 需重新配对',
    'devices.expiredRepair': '配对已过期 · 需重新配对',
    'inbox.questions': '问题',
    'inbox.plans': '计划',
    'inbox.replies': '回复',
    'inbox.goals': '目标',
    'inbox.failed': '失败',
    'inbox.markAllRead': '全部已读',
    'inbox.today': '今天',
    'inbox.yesterday': '昨天',
    'inbox.earlier': '更早',
    'inbox.hint': '任务完成、等待输入或需要审批时会出现在这里',
    'jobs.submitted': '已提交：{label}',
    'jobs.submitFailed': '提交失败：{e}',
    'jobs.allowed': '已允许',
    'jobs.denied': '已拒绝',
    'jobs.actionFailed': '操作失败：{e}',
    'jobs.awaitingApproval': '等待审批',
    'jobs.runningSection': '进行中',
    'jobs.recentDone': '最近完成',
    'jobs.killConfirm': '终止任务？',
    'jobs.killRequested': '已请求终止',
    'jobs.finished': '任务已结束',
    'jobs.actionSubmitted': '操作已提交',
    'jobs.killFailed': '终止失败：{e}',
    'jobs.jobId': '任务 ID',
    'jobs.startedAt': '开始时间',
    'jobs.endedAt': '结束时间',
    'jobs.elapsed': '耗时',
    'jobs.seconds': '{n} 秒',
    'jobs.progress': '进度',
    'jobs.detail': '详情',
    'jobs.bytes': '{n} 字节',
    'jobs.spillFile': '落盘文件',
    'jobs.viewOutput': '查看输出',
    'jobs.killJob': '终止任务',
    'err.network.title': '网络不可用',
    'err.network.hint': '检查手机的 Wi-Fi 或移动网络。',
    'err.connect.title': '连不上电脑',
    'err.connect.hint': '确认电脑上的 DSH 正在运行，且手机和电脑在同一网络。',
    'err.timeout.title': '连接超时',
    'err.timeout.hint': '网络可能较慢，或电脑正忙。稍后重试。',
    'err.auth.title': '配对已失效',
    'err.auth.hint': '需要重新扫描电脑上的配对二维码。',
    'err.rejected.title': '电脑拒绝了这次请求',
    'err.rejected.hint': '可能是电脑端的访问配置有变。到「连接诊断」查看详情。',
    'err.host.title': '电脑端处理失败',
    'err.host.hint': '这是 DSH 内部错误。可以重试，或到「连接诊断」查看。',
    'err.mux.title': '连接已断开',
    'err.mux.hint': '正在尝试重连。若持续失败，检查电脑端是否还在运行。',
    'err.generic.title': '出错了',
    'err.generic.hint': '可以重试；若持续出现，请到「连接诊断」查看。',
    'diag.pass': '通过',
    'diag.attention': '需注意',
    'diag.fail': '失败',
    'diag.explain': '说明',
    'diag.allOk': '全部正常',
    'diag.needAction': '需要处理',
    'diag.hasIssues': '存在问题',
    'diag.reportTitle': 'DSH 连接诊断报告',
    'diag.reportGenerated': '生成于 {at}',
    'diag.reportConclusion': '结论: {name}',
    'diag.reportRedacted': '注：本报告已脱敏，不含凭据与完整地址。',
    'diag.connectTitle': '连接诊断',
    'diag.connection': '连接状态',
    'diag.phonePath': '手机路径',
    'diag.connState': '网关连接',
    'diag.connDown': '未连接：当前没有可用连接',
    'diag.deviceReachable': '电脑可达',
    'diag.tlsTrust': '电脑侧证书信任',
    'diag.tlsTrustHint': 'App 无法检查电脑侧的证书信任，请在电脑上运行诊断',
    'diag.checking': '检查中…',
    'diag.start': '开始检查',
    'diag.summary': '{ok} 项通过 · {warn} 项需注意 · {err} 项失败',
    'diag.generatedAt': '生成于 {at} · 手机路径未验证',
    'diag.needsDevice': '需在手机上验证',
    'diag.deviceOnly': '配对页、资源、WebSocket 都只能真机确认',
    'jobout.title': '任务输出',
    'jobout.empty': '这个任务没有输出',
    'jobout.evicted': '中间部分输出已被淘汰，无法显示完整内容',
    'jobout.running': '运行中…',
    'jobout.toLatest': '回到最新',
    'jobout.toLatestN': '回到最新 (+{n})',
    'job.state.running': '运行中',
    'job.state.stopping': '正在停止',
    'job.state.done': '已完成',
    'job.state.failed': '失败',
    'job.state.killed': '已终止',
    'job.state.unknown': '未知',
    'job.runningProgress': '进行中 {p}',
    'job.hideDetail': '隐藏技术细节',
    'job.showDetail': '查看技术细节',
    'approval.needsYou': '需要你审批：{tool}，{reason}',
    'approval.waiting': '等待审批',
    'approval.pending': '待审批',
    'approval.failed': '审批提交失败：{error}',
    'approval.escalate': '提权',
    'approval.confirm': '需要你的确认',
    'approval.request': '{tool} 请求执行',
    'question.needsYou': '需要你的回答：{summary}',
    'question.later': '稍后',
    'question.waitingCount': '等待回答 · {n} 题',
    'question.waiting': '等待回答',
    'detail.openOnPc': '在电脑上打开',
    'detail.empty': '这个会话还没有内容',
    'detail.emptyHint': '在电脑上发第一条消息后，对话会显示在这里。',
    'detail.jobs': '后台任务',
    'detail.firstMessage': '输入第一条消息…',
    'detail.send': '发送',
    'conn.connecting': '连接中…',
    'conn.reconnectingPaired': '正在连接已配对电脑…',
    'conn.unpaired': '尚未配对',
    'conn.unpairedHint': '尚未配对，点「添加电脑」扫码或粘贴配对链接',
    'conn.noCookie': '无凭据：请传 --dart-define=DSH_COOKIE',
    'conn.connected': '已连接',
    'conn.failed': '连接失败',
    'conn.currentPc': '当前电脑',
    'conn.sessionsFailed': '已连接（会话列表加载失败）',
    'conn.pairNotReady': '配对未就绪：请先完成一次连接',
    'conn.noPairedDevice': '没有已配对设备',
    'conn.reconnected': '已重新连接',
    'conn.reconnectFailed': '重连失败',
    'conn.reconnectFailedMsg': '重连失败：{msg}',
    'nav.jobs': '后台任务',
  };

  // ── English ──
  static const Map<String, String> _en = {
    'nav.tasks': 'Tasks',
    'nav.sessions': 'Sessions',
    'nav.devices': 'Devices',
    'nav.inbox': 'Inbox',
    'nav.settings': 'Settings',
    'common.retry': 'Retry',
    'common.refresh': 'Refresh',
    'common.cancel': 'Cancel',
    'common.close': 'Close',
    'common.back': 'Back',
    'common.copy': 'Copy',
    'common.copied': 'Copied',
    'common.confirm': 'Confirm',
    'common.loading': 'Loading…',
    'common.failed': 'Failed',
    'common.empty': 'Nothing here',
    'unpaired.title': 'No computer paired yet',
    'unpaired.hint':
        'Open the "Mobile Access" panel on your computer to generate a QR code,\nthen scan it with this phone.',
    'unpaired.scan': 'Scan to pair',
    'unpaired.retry': 'Retry connecting',
    'connect.connecting': 'Connecting…',
    'connect.reconnecting': 'Connecting to paired computer…',
    'connect.connected': 'Connected',
    'connect.failed': 'Connection failed',
    'settings.appearance': 'Appearance',
    'settings.language': 'Language',
    'settings.language.system': 'System default',
    'settings.language.hint': 'Affects both the app and the embedded DSH page',
    'session.running': 'Running',
    'session.idle': 'Idle',
    'session.history': 'History',
    'session.jobs': 'Background jobs',
    'session.blank': 'This session has no content yet',
    'pair.title': 'Add computer',
    'pair.step.scan': 'Scan',
    'pair.step.verify': 'Verify',
    'pair.step.done': 'Done',
    'pair.scanHint': 'Put the pairing QR code from your computer in the frame',
    'pair.openCamera': 'Open camera',
    'pair.stopScan': 'Stop scanning',
    'pair.pasteLink': 'Or paste the pairing link',
    'pair.submit': 'Pair',
    'pair.success': 'Paired',
    'pair.failed': 'Pairing failed',
    'pair.enterApp': 'Go to tasks',
    'appearance.title': 'Appearance',
    'appearance.theme': 'Theme',
    'appearance.theme.system': 'System',
    'appearance.theme.light': 'Light',
    'appearance.theme.dark': 'Dark',
    'appearance.language': 'Language',
    'appearance.language.hint': 'Affects both the app and the embedded DSH page',
    'appearance.font': 'Font size',
    'appearance.font.label': 'Body text size',
    'appearance.font.hint':
        'Affects body text, code and options; labels keep a minimum readable size',
    'appearance.scale': 'Page scale',
    'appearance.scale.hint': 'Android only; 80–125% in steps of 5',
    'appearance.motion': 'Motion',
    'appearance.motion.system': 'System',
    'appearance.motion.reduced': 'Always reduced',
    'appearance.preview': 'Preview',
    'appearance.preview.sample': 'Preview: body text sample. Aa 0123456789',
    'appearance.reset': 'Reset to defaults',
    'appearance.reset.confirmTitle': 'Reset appearance?',
    'appearance.reset.confirmNote':
        'Text size goes back to 16, scale to 100%, theme and language follow '
        'the system. Tasks and sessions are not affected.',
    'appearance.reset.done': 'Appearance reset to defaults',
    'appearance.increase': 'Increase',
    'appearance.decrease': 'Decrease',
    'tasks.title': 'Tasks',
    'tasks.count': '{n} sessions',
    'tasks.empty': 'No tasks yet',
    'tasks.emptyHint': 'Start a conversation on your computer and it shows up here',
    'tasks.needsYou': 'Needs you',
    'tasks.running': 'Running',
    'tasks.other': 'Other',
    'tasks.awaiting': 'Awaiting reply',
    'tasks.awaitingCount': '{n} awaiting',
    'time.justNow': 'just now',
    'time.minutesAgo': '{n} min ago',
    'time.hoursAgo': '{n} h ago',
    'time.yesterday': 'yesterday',
    'time.daysAgo': '{n} d ago',
    'time.monthsAgo': '{n} mo ago',
    'devices.title': 'Devices',
    'devices.add': 'Add computer',
    'devices.pairedCount': '{n} paired devices',
    'devices.others': 'Other computers',
    'devices.empty': 'No computer paired yet',
    'devices.emptyHint': 'Open the "Mobile Access" panel on your computer to generate a QR code,\nthen tap the button below to scan it.',
    'devices.security': 'Security',
    'devices.revokeAll': 'Unpair all devices',
    'devices.revokeAllHint': 'Deletes every pairing saved on this phone and drops the current connection. The device entry on your computer stays until you remove it in Mobile Access.',
    'devices.revokeAllConfirm': 'Unpair',
    'devices.current': 'Current',
    'devices.reconnect': 'Reconnect',
    'devices.diagnostics': 'Diagnostics',
    'devices.repair': 'Pair again',
    'devices.more': 'More actions',
    'devices.reachable': 'Reachable',
    'devices.checking': 'Checking',
    'devices.unreachable': 'Unreachable',
    'devices.removed': 'Removed on computer',
    'devices.expired': 'Pairing expired',
    'devices.lan': 'LAN',
    'devices.remote': 'Remote',
    'sessions.title': 'Sessions',
    'sessions.search': 'Search sessions and workspaces…',
    'sessions.clear': 'Clear',
    'sessions.all': 'All',
    'sessions.withAgent': 'Has agent',
    'sessions.empty': 'No sessions yet',
    'sessions.emptyHint': 'Start a task on your computer and it shows up here',
    'sessions.noMatch': 'No matching sessions',
    'sessions.noMatchHint': 'Try a different keyword',
    'sessions.agentReady': 'Agent ready',
    'sessions.new': 'New session',
    'sessions.createFailed': 'Could not create a session — check the connection and retry',
    'sessions.createFailedWhy': 'Failed to create session: {e}',
    'sessions.created': 'Session created',
    'sessions.rowLabel': 'Session {id}',
    'sessions.groupOther': 'Unassigned',
    'sessions.groupExpanded': '{name}, {n} sessions, expanded',
    'sessions.groupCollapsed': '{name}, {n} sessions, collapsed',
    'sessions.expand': 'Expand',
    'sessions.collapse': 'Collapse',
    'sessions.filter': 'Filter',
    'sessions.expandAll': 'Expand all',
    'sessions.collapseAll': 'Collapse all',
    'sessions.searchAction': 'Search',

    'session.state.running': 'Running',
    'session.state.idle': 'Idle',
    'session.state.history': 'History',
    'inbox.title': 'Inbox',
    'inbox.empty': 'No notifications',
    'inbox.emptyHint': 'Approvals and questions show up here',
    'inbox.approval': 'Approval',
    'inbox.question': 'Question',
    'jobs.title': 'Background jobs',
    'jobs.empty': 'No background jobs',
    'jobs.emptyHint': 'Long commands the agent runs show up here',
    'jobs.kill': 'Kill',
    'jobs.output': 'Output',
    'jobs.running': 'Running',
    'jobs.done': 'Done',
    'jobs.failed': 'Failed',
    'jobs.exitCode': 'exit code {n}',
    'diag.title': 'Diagnostics',
    'diag.rerun': 'Check again',
    'diag.copy': 'Copy report',
    'diag.copied': 'Report copied',
    'diag.empty': 'No diagnostics yet',
    'diag.passed': 'OK',
    'diag.warn': 'Warning',
    'diag.failed': 'Failed',
    'diag.unknown': 'Not checked',
    'approval.allow': 'Allow',
    'approval.deny': 'Deny',
    'approval.title': 'Approval needed',
    'question.answer': 'Answer',
    'question.submit': 'Submit',
    'question.title': 'Your answer is needed',
    'error.network': 'Network unreachable',
    'error.networkHint':
        'Make sure the phone and computer share a Wi-Fi and mobile access is on',
    'error.timeout': 'Connection timed out',
    'error.timeoutHint': 'The computer may be busy, or the network is unstable',
    'error.auth': 'Pairing expired',
    'error.authHint': 'Generate a new pairing QR code on your computer and pair again',
    'error.unknown': 'Something went wrong',
    'error.detail': 'Show details',
    'error.hideDetail': 'Hide details',
    'pair.back': 'Back',
    'pair.securityNote':
        'Only connect to DSH on your own computer. Once paired, the phone can operate all sessions on it.',
    'pair.cameraUnavailable': 'Camera unavailable',
    'pair.cameraHint':
        'Allow camera access in system settings,\nor use "paste pairing link" below.',
    'pair.scanning': 'Scanning…',
    'pair.idle': 'Not scanning yet',
    'pair.startScan': 'Tap the button below to open the camera\nand scan the pairing QR code',
    'pair.retry': 'Retry',
    'pair.useLink': 'Use link instead',
    'devices.reachableLatency': 'Reachable · ~{n}ms',
    'devices.unreachableLast': 'Unreachable · last seen {t}',
    'devices.removedRepair': 'Removed on computer · pair again',
    'devices.expiredRepair': 'Pairing expired · pair again',
    'inbox.questions': 'Questions',
    'inbox.plans': 'Plans',
    'inbox.replies': 'Replies',
    'inbox.goals': 'Goals',
    'inbox.failed': 'Failed',
    'inbox.markAllRead': 'Mark all read',
    'inbox.today': 'Today',
    'inbox.yesterday': 'Yesterday',
    'inbox.earlier': 'Earlier',
    'inbox.hint': 'Completed tasks, waiting inputs and approvals show up here',
    'jobs.submitted': 'Submitted: {label}',
    'jobs.submitFailed': 'Submit failed: {e}',
    'jobs.allowed': 'Allowed',
    'jobs.denied': 'Denied',
    'jobs.actionFailed': 'Action failed: {e}',
    'jobs.awaitingApproval': 'Awaiting approval',
    'jobs.runningSection': 'Running',
    'jobs.recentDone': 'Recently finished',
    'jobs.killConfirm': 'Kill this job?',
    'jobs.killRequested': 'Kill requested',
    'jobs.finished': 'Job finished',
    'jobs.actionSubmitted': 'Action submitted',
    'jobs.killFailed': 'Kill failed: {e}',
    'jobs.jobId': 'Job ID',
    'jobs.startedAt': 'Started',
    'jobs.endedAt': 'Ended',
    'jobs.elapsed': 'Elapsed',
    'jobs.seconds': '{n}s',
    'jobs.progress': 'Progress',
    'jobs.detail': 'Detail',
    'jobs.bytes': '{n} bytes',
    'jobs.spillFile': 'Spill file',
    'jobs.viewOutput': 'View output',
    'jobs.killJob': 'Kill job',
    'err.network.title': 'Network unavailable',
    'err.network.hint': 'Check the phone Wi-Fi or mobile network.',
    'err.connect.title': "Can't reach the computer",
    'err.connect.hint': 'Make sure DSH is running and both are on the same network.',
    'err.timeout.title': 'Connection timed out',
    'err.timeout.hint': 'The network may be slow or the computer is busy. Try again.',
    'err.auth.title': 'Pairing expired',
    'err.auth.hint': 'Scan the pairing QR code on your computer again.',
    'err.rejected.title': 'The computer rejected this request',
    'err.rejected.hint': 'The access config may have changed. Check Diagnostics.',
    'err.host.title': 'The computer failed to handle it',
    'err.host.hint': 'This is an internal DSH error. Retry or check Diagnostics.',
    'err.mux.title': 'Connection lost',
    'err.mux.hint': 'Reconnecting. If it keeps failing, check the computer.',
    'err.generic.title': 'Something went wrong',
    'err.generic.hint': 'Retry; if it persists, check Diagnostics.',
    'diag.pass': 'Pass',
    'diag.attention': 'Attention',
    'diag.fail': 'Fail',
    'diag.explain': 'Details',
    'diag.allOk': 'All good',
    'diag.needAction': 'Needs action',
    'diag.hasIssues': 'Issues found',
    'diag.reportTitle': 'DSH connection diagnostics report',
    'diag.reportGenerated': 'Generated at {at}',
    'diag.reportConclusion': 'Conclusion: {name}',
    'diag.reportRedacted':
        'Note: this report is redacted and contains no credentials or full addresses.',
    'diag.connectTitle': 'Diagnostics',
    'diag.connection': 'Connection',
    'diag.phonePath': 'Phone path',
    'diag.connState': 'Gateway connection',
    'diag.connDown': 'Not connected: no live connection',
    'diag.deviceReachable': 'Computer reachable',
    'diag.tlsTrust': 'Certificate trust on computer',
    'diag.tlsTrustHint':
        'The app cannot check certificate trust on the computer; run diagnostics there',
    'diag.checking': 'Checking…',
    'diag.start': 'Start check',
    'diag.summary': '{ok} passed · {warn} attention · {err} failed',
    'diag.generatedAt': 'Generated at {at} · phone path not verified',
    'diag.needsDevice': 'Verify on the phone',
    'diag.deviceOnly':
        'Pairing page, assets and WebSocket can only be confirmed on a real device',
    'jobout.title': 'Job output',
    'jobout.empty': 'This job has no output',
    'jobout.evicted': 'Middle output was evicted; the full content is unavailable',
    'jobout.running': 'Running…',
    'jobout.toLatest': 'Jump to latest',
    'jobout.toLatestN': 'Jump to latest (+{n})',
    'job.state.running': 'Running',
    'job.state.stopping': 'Stopping',
    'job.state.done': 'Done',
    'job.state.failed': 'Failed',
    'job.state.killed': 'Killed',
    'job.state.unknown': 'Unknown',
    'job.runningProgress': 'Running {p}',
    'job.hideDetail': 'Hide technical details',
    'job.showDetail': 'Show technical details',
    'approval.needsYou': 'Approval needed: {tool}, {reason}',
    'approval.waiting': 'Awaiting approval',
    'approval.pending': 'Pending approval',
    'approval.failed': 'Could not submit: {error}',
    'approval.escalate': 'Escalate',
    'approval.confirm': 'Your confirmation is needed',
    'approval.request': '{tool} requests to run',
    'question.needsYou': 'Your answer is needed: {summary}',
    'question.later': 'Later',
    'question.waitingCount': 'Awaiting answer · {n} questions',
    'question.waiting': 'Awaiting answer',
    'detail.openOnPc': 'Open on computer',
    'detail.empty': 'This session has no content yet',
    'detail.emptyHint': 'The conversation shows up here after the first message on your computer.',
    'detail.jobs': 'Background jobs',
    'detail.firstMessage': 'Type the first message…',
    'detail.send': 'Send',
    'conn.connecting': 'Connecting…',
    'conn.reconnectingPaired': 'Connecting to paired computer…',
    'conn.unpaired': 'Not paired',
    'conn.unpairedHint': 'Not paired yet — tap "Add computer" to scan or paste a link',
    'conn.noCookie': 'No credentials: pass --dart-define=DSH_COOKIE',
    'conn.connected': 'Connected',
    'conn.failed': 'Connection failed',
    'conn.currentPc': 'Current computer',
    'conn.sessionsFailed': 'Connected (failed to load sessions)',
    'conn.pairNotReady': 'Pairing not ready: connect once first',
    'conn.noPairedDevice': 'No paired device',
    'conn.reconnected': 'Reconnected',
    'conn.reconnectFailed': 'Reconnect failed',
    'conn.reconnectFailedMsg': 'Reconnect failed: {msg}',
    'nav.jobs': 'Background jobs',
  };
}

/// 把当前语言下发给整棵树。
class AppLocaleScope extends InheritedWidget {
  const AppLocaleScope({
    super.key,
    required this.language,
    required super.child,
  });

  /// 解析后的实际语言（不会是 `system`）。
  final AppLanguage language;

  @override
  bool updateShouldNotify(AppLocaleScope oldWidget) =>
      oldWidget.language != language;
}


/// 相对时间格式化。
///
/// 之前每个页面各写一份（`session_tasks_page` / `sessions_page` /
/// `devices_page` 都有几乎相同的 `刚刚 / N 分钟前 / 昨天`），
/// 且都是硬编码中文。统一到这里，顺便支持多语言。
String formatRelativeTime(AppStrings strings, DateTime at, {DateTime? now}) {
  final base = now ?? DateTime.now();
  final d = base.difference(at);
  if (d.inMinutes < 1) return strings('time.justNow');
  if (d.inHours < 1) return strings.withArgs('time.minutesAgo', {'n': d.inMinutes});
  if (d.inDays < 1) return strings.withArgs('time.hoursAgo', {'n': d.inHours});
  if (d.inDays < 2) return strings('time.yesterday');
  if (d.inDays < 30) return strings.withArgs('time.daysAgo', {'n': d.inDays});
  return strings.withArgs('time.monthsAgo', {'n': (d.inDays / 30).floor()});
}
