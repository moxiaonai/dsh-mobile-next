/// 系统返回键（Android 返回键 / 左滑返回手势）的层级解析。
///
/// ## 为什么需要这一层
///
/// 会话详情与后台任务**不是 Navigator 路由**，而是宿主用 `setState` 换
/// `body`（见 `main.dart` 的 `_ShellState.build`）。好处是切 tab 不会重建
/// WebView；代价是系统返回键**没有任何拦截点**：
///
/// ```
/// WidgetsBinding.handlePopRoute()
///   → 遍历 WidgetsBindingObserver.didPopRoute()   // 详情页不在其中
///   → 全部返回 false
///   → SystemNavigator.pop()                       // App 直接退出
/// ```
///
/// 于是用户在详情页一左滑就退回桌面（`docs/70-ui-interaction-redesign.md`
/// §P0-8 记录的缺陷）。
///
/// ## 为什么单独成文件
///
/// 「先关内层、再关外层、最后才退出」这条顺序曾经出过错（早期版本点返回
/// 跳到了设备页），而它被埋在 `main.dart` 的私有 State 里无法单测。
/// 这里把判定抽成纯函数，顺序由 `back_navigation_test.dart` 锁住。
library;

/// 系统返回键要执行的动作。
enum BackAction {
  /// 最内层：后台任务 → 回到会话详情。
  closeJobs,

  /// 中间层：会话详情 → 回到 tab 页。
  closeSession,

  /// 已在 tab 页：交还系统，退出 App。
  exitApp,
}

/// 解析一次系统返回该关哪一层。
///
/// 入参必须与 `_ShellState.build` 的分支条件**逐字对应**：
///
/// | build 分支 | 条件 |
/// | --- | --- |
/// | 后台任务页 | `showJobs && hasSession` |
/// | 会话详情页 | `hasSession` |
/// | tab 页 / 连接中 | 其余 |
///
/// 两处一旦不同步，返回键就会跳层或误退出 —— 这正是本函数存在的理由。
///
/// [hasSession] 由调用方传入 `_openSession != null && _conn != null`，
/// 不能只判 `_openSession`：断连后详情页不再渲染（build 的第二个分支要求
/// `_conn != null`），此时按返回应当退出而不是「关一个看不见的页面」。
BackAction resolveBackAction({
  required bool showJobs,
  required bool hasSession,
}) {
  if (!hasSession) return BackAction.exitApp;
  if (showJobs) return BackAction.closeJobs;
  return BackAction.closeSession;
}
