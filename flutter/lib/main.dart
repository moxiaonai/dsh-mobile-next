/// DSH Mobile 客户端入口。
///
/// 当前接入：任务中心（含「需要你」提问与审批）。
/// 其余屏幕（会话/设备/通知/配对/诊断/外观）已实现，通过底部导航接入。
///
/// 运行：
///   flutter run -d macos --dart-define=DSH_COOKIE=`<cookie>`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// SystemNavigator：tab 页兜底退出 App（详情/后台任务层由 PopScope 拦截）
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/app_strings.dart';
import 'src/appearance_state.dart';
import 'src/notice_center.dart';
import 'src/session_group_prefs.dart';
import 'src/auth/credential_store.dart';
import 'src/auth/pairing.dart';
import 'src/auth/pairing_flow.dart';
import 'src/ui/pairing_page.dart';
import 'src/protocol/approvals.dart';
import 'src/protocol/jobs.dart';
import 'src/protocol/questions.dart';
import 'src/protocol/session.dart';
import 'src/protocol/sessions.dart';
import 'src/transport/connection.dart';
import 'src/transport/io_transport.dart';
import 'src/transport/mux.dart';
import 'src/transport/request_generation.dart';
import 'src/ui/appearance_page.dart';
import 'src/ui/back_navigation.dart';
import 'src/ui/devices_page.dart';
import 'src/ui/job_center_page.dart';
import 'src/ui/job_widgets.dart' show AppTheme, ErrorState;
import 'src/ui/session_detail_page.dart';
import 'src/ui/session_tasks_page.dart';
import 'src/ui/sessions_page.dart';
import 'src/ui/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _App());
}

class _App extends StatefulWidget {
  const _App();
  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  AppearanceState _appearance = const AppearanceState();
  // 路径要异步解析（path_provider），因此 store 不能是 late final 常量。
  // 在 _loadAppearance 里先解析路径再建。
  AppearanceStore? _store;


  @override
  void initState() {
    super.initState();
    unawaited(_loadAppearance());
  }

  Future<void> _loadAppearance() async {
    // ⚠ 必须用 App 私有目录：systemTemp 在 Android 上不可写，
    // 写失败被静默吞掉 → 表现为「改了设置，重启就重置」。
    final path = await resolveStatePath('appearance.json');
    final store = AppearanceStore(filePath: path);
    _store = store;
    final loaded = await store.load();
    if (!mounted) return;
    setState(() => _appearance = loaded);
  }

  void _updateAppearance(AppearanceState next) {
    if (next == _appearance) return;
    setState(() => _appearance = next);
    final store = _store;
    if (store != null) unawaited(store.save(next));
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        // 系统亮度：用于 theme=system 时解析
        final platformBrightness =
            MediaQuery.platformBrightnessOf(context);
        final reduceMotion =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;

        final brightness = _appearance.resolveBrightness(platformBrightness);
        final tokens = brightness == Brightness.dark
            ? Tokens.dark
            : Tokens.light;
        final text = AppTextStyles(tokens, _appearance.fontBase);

        // 解析实际语言（system → 跟随系统）
        final systemLocale = WidgetsBinding.instance.platformDispatcher.locale;
        final language = resolveLanguage(_appearance.language, systemLocale);

        return AppLocaleScope(
          language: language,
          child: AppTheme(
          tokens: tokens,
          text: text,
          child: MaterialApp(
            title: 'DSH Mobile',
            debugShowCheckedModeBanner: false,
            // ⚠ 必须用 GlobalMaterialLocalizations（来自 flutter_localizations）。
            //
            // `DefaultMaterialLocalizations` **只支持英文**：locale 解析成 zh 时
            // NavigationBar 找不到中文的 MaterialLocalizations，直接红屏
            // （"No MaterialLocalizations found"）。实测踩过。
            locale: Locale(language.name),
            supportedLocales: const [Locale('zh'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(
              useMaterial3: true,
              brightness: brightness,
              colorSchemeSeed: const Color(0xFF2563EB),
            ),
            builder: (context, child) {
              // 动效偏好：reduced 时禁用所有隐式动画
              final media = MediaQuery.of(context);
              return MediaQuery(
                data: media.copyWith(
                  disableAnimations: _appearance.resolveReduceMotion(
                    reduceMotion,
                  ),
                ),
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: _Shell(
              appearance: _appearance,
              onAppearanceChanged: _updateAppearance,
            ),
          ),
          ),
        );
      },
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell({
    required this.appearance,
    required this.onAppearanceChanged,
  });

  final AppearanceState appearance;
  final ValueChanged<AppearanceState> onAppearanceChanged;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _tab = 0;

  /// 会话分组折叠状态（跨 tab / 重启保留）。
  ///
  /// 放在这里而不是 SessionsPage 内部：`switch (_tab)` 会卸载页面
  /// 的 Element，本地 state 切一次 tab 就丢了。
  // 路径异步解析（与 appearance 同理：systemTemp 在 Android 上不可写）
  CollapsedGroupsStore? _groupPrefs;

  /// 通知中心（持久化，覆盖审批与提问两类真实事件）。
  final NoticeCenter _notices = NoticeCenter();

  Set<String> _collapsedGroups = <String>{};

  void _updateCollapsedGroups(Set<String> next) {
    if (setEquals(next, _collapsedGroups)) return;
    setState(() => _collapsedGroups = next);
    final prefs = _groupPrefs;
    if (prefs != null) unawaited(prefs.save(next));
  }

  // 连接状态
  String _status = '连接中…';
  Object? _error;
  JobCenter? _jobs;
  QuestionCenter? _questions;
  ApprovalCenter? _approvals;
  SessionBrowser? _browser;
  String? _sessionId;
  DshConnection? _conn;
  IoHttpTransport? _transport;
  final List<PendingApproval> _approvalList = [];

  /// 当前打开的会话详情（null = 在 tab 页）。
  SessionSummary? _openSession;

  /// 是否在看该会话的后台任务（在详情之上再压一层）。
  bool _showJobs = false;

  /// 已配对设备（从凭据存储加载）。
  List<DeviceCredential> _credentials = const [];

  /// 配对流程（懒创建）。
  PairingFlow? _pairingFlow;
  final RequestGeneration _connectionRequests = RequestGeneration();

  /// 打包进 APK 的私有 CA（PEM）。启动时读一次。
  String? _caPem;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCollapsed());
    unawaited(_loadNotices());
    _boot();
  }

  /// 真机上「已经配对过」的判断依据。
  ///
  /// 之前只认编译期 `--dart-define=DSH_COOKIE`，手机上既没有那个宏、
  /// 也没有 `~/.dsh/.credentials.yaml`，于是永远卡在「连接中…」——
  /// 装上去就是个白屏。现在改为：有凭据就重连，没有就进配对页。
  /// 打开设备管理（从 tab 降为设置页里的一项）。
  Future<void> _openDevices() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: DevicesPage(
            devices: _deviceList(),
            onAdd: _openPairing,
            onReconnect: (_) => _reconnect(),
            onBack: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 点通知 → 打开对应会话（并把该条标记已读）。
  void _openNotice(Notice notice) {
    setState(() {
      _notices.markRead(notice.id);
      // 通知里只有 sessionId，构造一个最小 summary 供详情页使用
      _openSession = SessionSummary(
        id: notice.sessionId,
        title: null,
        running: false,
        agentAvailable: false,
      );
      _showJobs = false;
    });
  }

  Future<void> _loadNotices() async {
    // 路径异步解析（systemTemp 在 Android 上不可写，见 resolveStatePath）
    _notices.filePath = await resolveStatePath('notices.json');
    await _notices.load();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadCollapsed() async {
    final path = await resolveStatePath('session-groups.json');
    final prefs = CollapsedGroupsStore(filePath: path);
    _groupPrefs = prefs;
    final loaded = await prefs.load();
    if (!mounted) return;
    setState(() => _collapsedGroups = loaded);
  }

  Future<void> _boot() async {
    // 重试时先清空旧错误，否则 ErrorState 会一直显示上一次的失败。
    if (_error != null) {
      setState(() {
        _error = null;
        _status = '连接中…';
      });
    }

    // ① 已配对设备优先：用保存的凭据重连
    final store = await createCredentialStoreAsync();
    final saved = await store.loadAll();
    debugPrint('[boot] 读到已配对设备 ${saved.length} 台');
    if (!mounted) return;
    _credentials = saved;
    // 私有 CA 必须固定，否则 TLS 握手直接失败（真机上表现为「连不上」）
    _caPem ??= await loadBundledCaPem();
    _pairingFlow ??= PairingFlow(store: store, trustedCaPem: _caPem);
    if (saved.isNotEmpty) {
      setState(() => _status = AppStrings.of(context)('conn.reconnectingPaired'));
      await _reconnect();
      debugPrint('[boot] 重连结果 conn=${_conn != null} sessionId=$_sessionId');
      if (_conn != null) return;
    }

    // ② 没有任何已配对设备 → 直接进配对页（而不是卡在连接中）
    if (!mounted) return;
    setState(() {
      _status = '尚未配对';
      _error = null;
    });
    await _openPairing();
    if (!mounted) return;

    // 配对页里已经连上了：补全会话状态再返回，否则界面判据不满足会一直转圈
    if (_conn != null) {
      await _hydrateSessions(_conn!);
      return;
    }

    // ③ 配对页返回但没连上：停在可操作的空态，不再转圈
    setState(() => _status = AppStrings.of(context)('conn.unpairedHint'));
    return;

    // 以下为旧的「编译期注入」路径，保留给桌面调试（-d macos）。
    // ignore: dead_code
    try {
      const originStr = String.fromEnvironment(
        'DSH_ORIGIN',
        defaultValue: 'http://127.0.0.1:59851',
      );
      const sid = String.fromEnvironment('SESSION_ID', defaultValue: '');
      const injected = String.fromEnvironment('DSH_COOKIE', defaultValue: '');

      final origin = Uri.parse(originStr);
      final cookie = injected.isNotEmpty ? injected : _mintLocal(origin);
      if (cookie == null) {
        setState(() => _status = AppStrings.of(context)('conn.noCookie'));
        return;
      }

      final transport = IoHttpTransport(trustedCaPem: _caPem);

      // 统一由 DshConnection 编排：unary 探活 → 连 mux → 等 $events ready，
      // 并在重连时重置会话激活状态（见 connection.dart 的 _bind）。
      final conn = await DshConnection.connect(
        origin: origin,
        cookieHeader: cookie,
        transport: transport,
        socketFactory: ioMuxSocketFactory(trustedCaPem: _caPem),
      );

      final approvals = ApprovalCenter(unary: conn.unary);

      // 订阅 $events：取 clientId 并收集审批。
      // 注意：$events 会**重放**所有未结算的 waterfall，包括别的会话遗留的，
      // 因此这里先只取 clientId；审批按会话过滤由 UI 侧负责。
      final ev = conn.mux.openStream(
        r'$events',
        payload: const {'args': <String, Object?>{}},
      );
      ev.events.listen((e) {
        if (e is! StreamItem || e.value is! Map) return;
        final frame = (e.value as Map).cast<String, Object?>();
        final cid = WaterfallExtractor.clientIdOf(frame);
        if (cid != null) {
          approvals.setClientId(cid);
          return;
        }
        final ap = WaterfallExtractor.approval(frame);
        if (ap != null && mounted) {
          setState(() {
            _approvalList.add(ap);
            // 同时进通知中心（去重 + 持久化 + 已读）
            _notices.add(
              Notice(
                id: ap.eventId,
                kind: NoticeKind.approval,
                sessionId: ap.sessionId,
                title: ap.toolName,
                at: DateTime.now(),
              ),
            );
          });
        }

      });

      final browser = SessionBrowser(unary: conn.unary, mux: conn.mux);
      var target = sid;
      if (target.isEmpty) {
        final sessions = await browser.list();
        final running = sessions.where((s) => s.running).toList();
        target = (running.isNotEmpty ? running.first : sessions.first).id;
      }

      // 加载已配对设备（用于设备页展示）
      //
      // ⚠ 必须用**异步工厂**：同步版在真机上拿不到 DSH_HOME 会退化成
      // 内存存储，配对结果写不进磁盘，重启即丢。
      // 而且这里曾经**覆盖**了 _boot 里建好的、带 CA 的 _pairingFlow ——
      // 覆盖后既没有 CA 也没有持久化，症状是「配对成功但进入任务仍显示未配对」。
      final store = await createCredentialStoreAsync();
      final creds = await store.loadAll();

      if (!mounted) return;
      setState(() {
        _credentials = creds;
        // 保留 _boot 已建好的实例（它带 trustedCaPem）；只在缺失时补建
        _pairingFlow ??= PairingFlow(store: store, trustedCaPem: _caPem);
        _conn = conn;
        _jobs = JobCenter(unary: conn.unary, mux: conn.mux);
        _questions = QuestionCenter(unary: conn.unary);
        _approvals = approvals;
        _browser = browser;
        _sessionId = target;
        _transport = transport;
        _status = '已连接';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _status = '连接失败';
      });
    }
  }

  @override
  void dispose() {
    _connectionRequests.invalidate();
    _pairingFlow?.dispose();
    _conn?.dispose();
    _transport?.close();
    super.dispose();
  }

  /// 设备页列表：来自凭据存储。
  ///
  /// 当前连接的那台标记为「当前」。可达性暂按「已连接 = 可达」简化 ——
  /// 真实探测需要逐台建连，代价大且会干扰当前连接。
  List<PairedDevice> _deviceList() {
    if (_credentials.isEmpty) {
      // 没有持久化凭据时（如调试 cookie 注入），仍显示当前连接
      if (_conn == null) return const [];
      return [
        PairedDevice(
          id: 'current',
          name: AppStrings.of(context)('conn.currentPc'),
          origin: '${_conn!.origin.host}:${_conn!.origin.port}',
          reachability: DeviceReachability.reachable,
          isCurrent: true,
        ),
      ];
    }
    return [
      for (var i = 0; i < _credentials.length; i++)
        PairedDevice(
          id: '${_credentials[i].origin}#${_credentials[i].instanceId ?? i}',
          name: _credentials[i].label ??
              '${_credentials[i].origin.host}:${_credentials[i].origin.port}',
          origin: '${_credentials[i].origin.host}:${_credentials[i].origin.port}',
          reachability: DeviceReachability.reachable,
          isCurrent: i == 0,
        ),
    ];
  }

  /// 连上之后补全会话状态。
  ///
  /// 界面的「已连接」判据要求 `_jobs != null && _sessionId != null`，
  /// 而重连只拿到连接对象。这里把会话列表拉一次、选一个作为当前会话，
  /// 顺便预热 JobCenter 需要的 sessionId。
  Future<void> _hydrateSessions(DshConnection conn) async {
    try {
      final browser = _browser ?? SessionBrowser(unary: conn.unary, mux: conn.mux);
      // 加超时：unary 默认 30s，对用户来说就是「一直转圈」。
      // 8 秒拿不到列表就按失败处理，把界面切到可操作状态。
      final sessions = await browser.list().timeout(const Duration(seconds: 8));
      if (!mounted || _conn != conn) return;
      String? target;
      if (sessions.isNotEmpty) {
        final running = sessions.where((s) => s.running).toList();
        target = (running.isNotEmpty ? running.first : sessions.first).id;
      }
      setState(() {
        _browser = browser;
        _sessionId = target ?? '';
      });
    } catch (e) {
      if (!mounted || _conn != conn) return;
      // 拉列表失败不阻断使用：把状态写清楚，用户可点重试
      setState(() {
        _sessionId = '';
        _status = AppStrings.of(context)('conn.sessionsFailed');
      });
      debugPrint('[boot] 会话列表加载失败: $e');
    }
  }

  /// 新建会话并直接进入详情（spec §5.2 的 FAB ＋）。
  ///
  /// ## 为什么不刷新列表
  ///
  /// 新会话是**空白会话**（`blank: true`）。列表与任务页都会过滤 blank
  /// （`sessions_page.dart` 的 `nonBlank`、`SessionTasks.build` 跳过 blank），
  /// 因为打开一个空会话在 DSH 里看到的是欢迎页，体验像坏页面。
  ///
  /// 所以「创建 → 刷新列表」这条路走不通：新建的会话根本不会出现。
  /// 正确做法是用 `session/create` 返回的 id 直接打开详情 ——
  /// 详情页的 WebView 按 sessionId 打开（`session_webview.dart`），
  /// 不依赖 `session/list` 的可见性。用户在详情页发出第一条消息后，
  /// 会话就不再是 blank，下次刷新列表自然出现。
  ///
  /// ## 参数
  ///
  /// 全部留空：手机拿不到电脑的文件系统，凭空指定 `cwd` 会造出一个
  /// 不存在的目录。不传时由服务端决定落点（见 [SessionBrowser.create]）。
  Future<String?> _createSession() async {
    final browser = _browser;
    if (browser == null) return null;
    try {
      // 10 秒超时：创建要落盘，比 list 慢一点，但不能无限等。
      final id = await browser
          .create()
          .timeout(const Duration(seconds: 10));
      if (!mounted) return null;
      // 直接进详情。构造一个最小 SessionSummary：
      // 详情页只用 id（拼 WebView）与 title/running（渲染 header）。
      final summary = SessionSummary(
        id: id,
        title: null,
        running: false,
        agentAvailable: false,
        blank: true,
        cwd: null,
      );
      setState(() {
        _openSession = summary;
        _showJobs = false;
      });
      return id;
    } catch (e) {
      debugPrint('[create] 新建会话失败: $e');
      // 交给 SessionsPage 统一提示（它持有 context 与多语言文案）
      rethrow;
    }
  }

  /// 重新读凭据存储（配对成功 / 撤销后调用）。
  Future<void> _reloadCredentials() async {
    final store = await createCredentialStoreAsync();
    final creds = await store.loadAll();
    if (!mounted) return;
    setState(() => _credentials = creds);
  }

  /// 打开配对页。
  Future<void> _openPairing() async {
    final flow = _pairingFlow;
    if (flow == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context)('conn.pairNotReady'))),
      );
      return;
    }
    if (!mounted) return;
    var pairingPageActive = true;
    int? pairingRequest;
    var pairingCommitted = false;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PairingPage(
          onCancel: () {
            pairingPageActive = false;
            final request = pairingRequest;
            // A popped old route must not cancel a newer reconnect request.
            if (!pairingCommitted && request != null && _connectionRequests.cancel(request)) {
              unawaited(flow.cancel());
            }
          },
          // PairingPage 传入的是解析后的描述符；flow 需要原始 URL，
          // 这里还原成插件支持的 `#token=` 形式。
          onPair: (descriptor) async {
            final request = _connectionRequests.begin();
            pairingRequest = request;
            pairingCommitted = false;
            bool owns() => mounted && pairingPageActive && _connectionRequests.owns(request);
            // 直接传描述符：不要再拼成字符串重新解析（有损往返，会丢 token）
            final outcome = await flow.runDescriptor(descriptor);
            if (!owns()) {
              if (outcome is PairingSucceeded) await outcome.connection.dispose();
              throw const PairingException('pairing cancelled');
            }
            if (outcome is PairingFailed) {
              throw PairingException(outcome.message);
            }
            final ok = outcome as PairingSucceeded;
            // 配对成功：刷新设备列表并切到新连接
            final creds = await flow.store.loadAll();
            if (!owns()) {
              await ok.connection.dispose();
              throw const PairingException('pairing cancelled');
            }
            await _conn?.dispose();
            if (!owns()) {
              await ok.connection.dispose();
              throw const PairingException('pairing cancelled');
            }
            pairingCommitted = true;
            if (owns()) {
              setState(() {
                _credentials = creds;
                _conn = ok.connection;
                _jobs = JobCenter(
                  unary: ok.connection.unary,
                  mux: ok.connection.mux,
                );
                _questions = QuestionCenter(unary: ok.connection.unary);
                _approvals = ApprovalCenter(unary: ok.connection.unary);
                _browser = SessionBrowser(
                  unary: ok.connection.unary,
                  mux: ok.connection.mux,
                );
                _status = '已连接';
                _error = null;
              });
              // ⚠ 必须补 _sessionId：界面判据是
              // `_jobs == null || _sessionId == null`，只设 _jobs 会让
              // 界面永远停在「尚未配对」转圈 —— 服务端其实已经配对成功，
              // 真机上表现就是「配对完成但一直转」。
              await _hydrateSessions(ok.connection);
            }
            // PairingPage 只需要知道「成功了」，不消费这个结果
            return PairingResult(
              deviceId: ok.credential.deviceId,
              deviceToken: ok.credential.deviceToken,
              deviceExpiresAt: null,
              sessionToken: '',
              csrfToken: '',
              sessionExpiresAt: null,
              instanceId: ok.credential.instanceId,
            );
          },
          onEnterApp: () {
            if (mounted) Navigator.of(context).pop();
            // 配对成功即刷新已配对列表，否则首页仍显示「尚未配对」
            unawaited(_reloadCredentials());
            setState(() => _tab = 0);
          },
          onRetry: () {},
          // 配对页是 push 打开的，必须给返回入口
          onBack: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  /// 用第一台已配对设备重连。
  Future<void> _reconnect() async {
    final flow = _pairingFlow;
    if (flow == null || _credentials.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context)('conn.noPairedDevice'))),
      );
      return;
    }
    final request = _connectionRequests.begin();
    bool owns() => mounted && _connectionRequests.owns(request);
    // 先取 messenger 与文案：await 之后不能再碰 context（会跨异步间隙）。
    final messenger = ScaffoldMessenger.of(context);
    final reconnectedText = AppStrings.of(context)('conn.reconnected');
    final outcome = await flow.reconnect(_credentials.first);
    if (!owns()) {
      if (outcome is PairingSucceeded) await outcome.connection.dispose();
      return;
    }
    if (outcome is PairingSucceeded) {
      await _conn?.dispose();
      if (!owns()) {
        await outcome.connection.dispose();
        return;
      }
      setState(() {
        _conn = outcome.connection;
        _jobs = JobCenter(
          unary: outcome.connection.unary,
          mux: outcome.connection.mux,
        );
        _questions = QuestionCenter(unary: outcome.connection.unary);
        _approvals = ApprovalCenter(unary: outcome.connection.unary);
        _browser = SessionBrowser(
          unary: outcome.connection.unary,
          mux: outcome.connection.mux,
        );
        // ⚠ 必须同时把 _sessionId 填上。
        //
        // 界面的「已连接」判据是 `_jobs == null || _sessionId == null`，
        // 只设 _jobs 而漏了 _sessionId 时，界面会永远停在
        // 「正在连接已配对电脑…」—— 而日志里 conn=true，看起来像 UI 没刷新。
        _status = '已连接';
        _error = null;
      });
      // 重连后拉一次会话，填上 _sessionId（否则界面判据仍不满足）
      await _hydrateSessions(outcome.connection);
      if (!owns()) return;
      messenger.showSnackBar(SnackBar(content: Text(reconnectedText)));
    } else {
      final failed = outcome as PairingFailed;
      // ⚠ 重连失败必须把界面从「连接中」切走，否则用户看到的是无限转圈，
      // 而真正的失败原因只在一条会自动消失的 SnackBar 里。
      if (mounted) {
        setState(() {
          _error = failed.message;
          _status = '重连失败';
          // 清掉半截连接状态，让界面走 ErrorState（带重试按钮）
          _jobs = null;
          _sessionId = null;
        });
      }
      messenger.showSnackBar(
        SnackBar(content: Text('重连失败：${failed.message}')),
      );
    }
  }

  /// 当前是否深色。
  ///
  /// 用 `AppTheme.of(context).tokens` 而不是 `Theme.of(context).brightness`：
  /// App 的主题由自己的 `AppearanceState` 决定（可覆盖系统设置），
  /// `Theme.of` 读的是 MaterialApp 的 ThemeData，在「跟随系统」时
  /// 两者可能短暂不同步。以 AppTheme 为准才是用户真正看到的配色。
  bool _isDark(BuildContext context) {
    final (tokens, _) = AppTheme.of(context);
    // Tokens 暴露 bgCanvas；用它判断比读 brightness 更贴近实际渲染
    return tokens.bgCanvas.computeLuminance() < 0.5;
  }

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final strings = AppStrings.of(context);
    final Widget body;
    if (_showJobs && _openSession != null && _conn != null) {
      // 后台任务是详情之上的第二层（不占 tab）。
      body = JobCenterPage(
        sessionId: _openSession!.id,
        watch: _jobs!.watch,
        onKill: (jobId) =>
            _jobs!.kill(sessionId: _openSession!.id, jobId: jobId),
        questionCenter: _questions,
        approvalCenter: _approvals,
        mux: _conn!.mux,
        title: '后台任务',
        // 返回：只清 _showJobs，回到会话详情（而不是回到 tab）
        onBack: () => setState(() => _showJobs = false),
      );
    } else if (_openSession != null && _conn != null) {
      // 会话详情是 push 面，不是 tab：覆盖整个内容区。
      //
      // 注意：这里用 setState 切换 body 而不是 Navigator.push。
      // 因此本页内的任何 Navigator.push（如「后台任务」）都会压在
      // tab 壳之上 —— 它们的 pop 回到的是 tab 壳，而不是会话详情。
      // 详情页的 onBack 必须显式清空 _openSession。
      body = SessionDetailPage(
        session: _openSession!,
        origin: _conn!.origin,
        cookieHeader: _conn!.cookieHeader,
        // 把 App 的明暗传进去，WebView 才能和外壳一致
        dark: _isDark(context),
        localeTag: AppStrings.of(context).language.tag,
        onBack: () => setState(() {
          _openSession = null;
          _showJobs = false;
        }),
        // 后台命令降级为详情页的辅助信息（不再占主界面）。
        // 用回调切换 _showJobs，而不是 Navigator.push ——
        // 会话详情本身不是 Navigator 路由，push 会压到 tab 壳上，
        // pop 时回到错误的层级（实测：点返回跳到了设备页）。
        onOpenJobs: _jobs == null
            ? null
            : () => setState(() => _showJobs = true),
      );
    } else if (_jobs == null || _sessionId == null) {
      // 连接中 / 连接失败。
      //
      // 失败时用 ErrorState：它把 SocketException 之类的原始异常翻译成
      // 用户能看懂的话，并给重试入口。直接显示 `$_error` 是不可接受的
      // （实测用户看到的是 `SocketException: Connection refused (OS Error:
      // Connection refused, errno = 111), address = 10.0.2.2, port = 59852`）。
      // 尚未配对时给一个**首屏直达**的入口。
      //
      // 之前要进「设备」tab 才看得到「添加电脑」—— 新用户装上 App
      // 第一眼是空白，根本不知道该点哪里。现在未配对即首屏引导。
      final unpaired = _conn == null && _credentials.isEmpty;
      body = unpaired
          ? _UnpairedLanding(
              status: _status,
              onPair: _openPairing,
              onRetry: _boot,
              t: t,
              txt: txt,
            )
          : _error == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: Space.s6),
                  Text(_status, style: txt.body),
                ],
              ),
            )
          : ErrorState(error: _error!, onRetry: _boot);
    } else {
      body = switch (_tab) {
        0 => SessionTasksPage(
          listSessions: _browser!.list,
          onOpen: (s) => setState(() => _openSession = s),
          // 通知并入任务页：两者回答同一个问题「有什么要我处理」
          notices: _notices,
          onOpenNotice: _openNotice,
          onMarkAllNoticesRead: () {
            setState(_notices.markAllRead);
          },
        ),
        // 会话（中间 tab：最常用的入口放拇指最容易够到的位置）
        1 => SessionsPage(
          listSessions: _browser!.list,
          listWorkspaces: _browser!.workspaces,
          onOpen: (s) => setState(() => _openSession = s),
          // 未连接时不给 FAB：按了必然失败，比不给更糟。
          onCreate: _conn == null ? null : _createSession,
          initialCollapsed: _collapsedGroups,
          onCollapsedChanged: _updateCollapsedGroups,
        ),
        _ => AppearancePage(
          settings: widget.appearance.toSettings(),
          deviceCount: _deviceList().length,
          onOpenDevices: _openDevices,
          // ⚠ 必须整体回传，不能只取 fontBase ——
          // 初版写成 `onFontChanged(s.fontBase)`，导致主题/动效改动被丢弃，
          // 点「浅色/深色」毫无反应。
          onChanged: (s) => widget.onAppearanceChanged(
            AppearanceState.fromSettings(s),
          ),
          onReset: () => widget.onAppearanceChanged(
            const AppearanceState(),
          ),
        ),
      };
    }

    final shell = Scaffold(
      backgroundColor: t.bgCanvas,
      body: body,
      // 会话详情是 push 面，隐藏底部导航（spec §5.4：详情页不占 tab）。
      bottomNavigationBar: (_openSession != null || _showJobs)
          ? null
          // 选中态是「墨色」：indicator 透明 + 图标/文字用 textPrimary，
          // 未选中降到 textTertiary。新稿里 FAB、筛选 chip 用的是同一套。
          : NavigationBarTheme(
              data: NavigationBarThemeData(
                backgroundColor: t.bgCard,
                indicatorColor: Colors.transparent,
                iconTheme: WidgetStateProperty.resolveWith(
                  (states) => IconThemeData(
                    size: 24,
                    color: states.contains(WidgetState.selected)
                        ? t.textPrimary
                        : t.textTertiary,
                  ),
                ),
                labelTextStyle: WidgetStateProperty.resolveWith(
                  (states) => TextStyle(
                    fontSize: 12,
                    fontWeight: states.contains(WidgetState.selected)
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: states.contains(WidgetState.selected)
                        ? t.textPrimary
                        : t.textTertiary,
                  ),
                ),
              ),
              child: NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                backgroundColor: t.bgCard,
                indicatorColor: Colors.transparent,
                height: 64,
                destinations: [
                  // 任务（含通知角标）：回答「有什么要我处理」
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: _notices.unreadCount > 0,
                      label: Text('${_notices.unreadCount}'),
                      child: const Icon(Icons.task_alt),
                    ),
                    label: strings('nav.tasks'),
                  ),
                  // 会话：回答「我要找某个对话」
                  NavigationDestination(
                    icon: const Icon(Icons.forum_outlined),
                    label: strings('nav.sessions'),
                  ),
                  // 设置：外观 + 已配对设备（低频，收进这里）
                  NavigationDestination(
                    icon: const Icon(Icons.settings_outlined),
                    label: strings('nav.settings'),
                  ),
                ],
              ),
            ),
    );

    // 系统返回（Android 返回键 / 左滑返回手势）必须**先关内层**再退出 App。
    //
    // 详情页与后台任务页不是 Navigator 路由，而是用 setState 换 body
    // （见上面两处注释）。因此系统返回键原本没有任何拦截点：
    // `handlePopRoute` 遍历观察者无果后直接 `SystemNavigator.pop()`
    // → 用户从详情页一左滑，App 就退到桌面。这是 docs/70 §P0-8 记录的缺陷。
    //
    // 这里按「内层优先」的顺序消费返回：
    //   后台任务 → 详情 → tab 页（tab 页才是唯一允许退出 App 的层级）
    // 注意 `canPop: false` 时 `maybePop` 返回 true（navigator.dart:5611-5613），
    // 所以框架不会继续走 `SystemNavigator.pop()`，拦截是真实生效的。
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        // didPop == true 表示框架已弹掉路由（本页在根路由上时不会发生），
        // 只有 false 才是「被我们拦下」，此时才需要自己处理。
        if (didPop) return;
        _handleBack();
      },
      child: shell,
    );
  }

  /// 当前这一层该被返回键关掉哪一层。
  ///
  /// 详情页 / 后台任务页都不是 Navigator 路由，所以这一层必须自己判断。
  /// ⚠ `hasSession` 必须同时判 `_conn != null`：断连后详情页不再渲染
  /// （build 分支要求 `_conn != null`），此时按返回应当退出，
  /// 而不是「关一个看不见的页面」。
  BackAction get _backAction => resolveBackAction(
    showJobs: _showJobs,
    hasSession: _openSession != null && _conn != null,
  );

  /// 是否处在「返回键应该被本页消费」的层级。
  bool get _canGoBack => _backAction != BackAction.exitApp;

  /// 消费一次系统返回：由内向外关一层。
  ///
  /// 层级判定交给 [resolveBackAction]，保证与 build 的 if/else 分支同源 ——
  /// 两处一旦不同步，返回键就会跳层（历史上「点返回跳到设备页」就是这么来的）。
  void _handleBack() {
    // 复用 _backAction：判定只算一次，避免两处条件漂移
    switch (_backAction) {
      case BackAction.closeJobs:
        // 最内层：后台任务 → 回到会话详情
        setState(() => _showJobs = false);
      case BackAction.closeSession:
        // 中间层：详情 → 回到 tab 页
        setState(() {
          _openSession = null;
          _showJobs = false;
        });
      case BackAction.exitApp:
        // 已经在 tab 页：交还给系统（退出 App）。
        // 正常情况下 canPop 已为 true、不会走到这里，保留作防御性兜底。
        unawaited(SystemNavigator.pop());
    }
  }


  /// 桌面调试用：读本机凭据铸造 cookie。
  ///
  /// 路径从 `$HOME` 推导，不写死某台机器的用户名。
  static String? _mintLocal(Uri origin) {
    try {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return null;
      final yaml = File(
        '$home/.dsh/.credentials.yaml',
      ).readAsStringSync();
      final m = RegExp(
        r'client-connection/browser-session:[\s\S]*?secret:\s*(\S+)',
      ).firstMatch(yaml);
      if (m == null) return null;
      final b64 = m.group(1)!.replaceAll('-', '+').replaceAll('_', '/');
      final secret = base64Decode(b64 + '=' * ((4 - b64.length % 4) % 4));
      final authority = '${origin.host}:${origin.port}';
      final now = DateTime.now().millisecondsSinceEpoch;
      final body = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'version': 1,
                'authority': authority,
                'issuedAt': now,
                'expiresAt': now + 30 * 24 * 3600 * 1000,
              }),
            ),
          )
          .replaceAll('=', '');
      final sig = base64Url
          .encode(
            Hmac(sha256, secret).convert(utf8.encode(body)).bytes,
          )
          .replaceAll('=', '');
      final name =
          'dsh-auth-${base64Url.encode(sha256.convert(utf8.encode(authority)).bytes).replaceAll('=', '')}';
      return '$name=v1.$body.$sig';
    } catch (_) {
      return null;
    }
  }
}


/// 未配对时的首屏。
///
/// 设计目标：新装 App 打开后**第一眼就知道该做什么**。
/// 之前这里只有一个转圈 + 「连接中…」，用户无从下手 ——
/// 入口藏在「设备」tab 里的一个按钮后面。
class _UnpairedLanding extends StatelessWidget {
  const _UnpairedLanding({
    required this.status,
    required this.onPair,
    required this.onRetry,
    required this.t,
    required this.txt,
  });

  final String status;
  final VoidCallback onPair;
  final VoidCallback onRetry;
  final Tokens t;
  final AppTextStyles txt;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.s7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: t.accentWeakBg,
                borderRadius: Radii.rLg,
              ),
              child: Icon(Icons.phonelink_setup, size: 30, color: t.accent),
            ),
            const SizedBox(height: Space.s6),
            Text(
              AppStrings.of(context)('unpaired.title'),
              style: txt.h2,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.s3),
            Text(
              AppStrings.of(context)('unpaired.hint'),
              style: txt.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.s8),
            SizedBox(
              height: Hit.primary,
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onPair,
                icon: const Icon(Icons.qr_code_scanner, size: 20),
                label: Text(AppStrings.of(context)('unpaired.scan')),
                style: FilledButton.styleFrom(
                  backgroundColor: t.accent,
                  foregroundColor: t.onAccent,
                ),
              ),
            ),
            const SizedBox(height: Space.s4),
            SizedBox(
              height: Hit.primary,
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.textPrimary,
                  side: BorderSide(color: t.borderSubtle),
                ),
                child: Text(AppStrings.of(context)('unpaired.retry')),
              ),
            ),
            const SizedBox(height: Space.s6),
            Text(status, style: txt.caption.copyWith(color: t.textTertiary)),
          ],
        ),
      ),
    );
  }
}
