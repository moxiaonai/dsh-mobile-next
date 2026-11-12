/// 收窄 DSH 布局为纯对话区的 CSS，以及会话 WebView 用到的注入脚本。
///
/// ## 重要设计决定：**不干预任何布局**
///
/// 排查过程（保留给后人，避免重蹈）：
///
/// 1. 初版写了 `[data-slot="conversation"] { width: 100% !important }`
///    → 内容区塌陷成 0×0，表现为「有 header、有 composer、中间全空」
/// 2. 改成给 `[data-slot="main"]` 设 `height: 100%` + flex
///    → main 高度确实变成 784px（探针确认 `mainHeight: "784px|flex|column"`），
///      但内容**仍然不渲染**
/// 3. 深入探针发现：`conversation.chat.flow` 与 `conversation.session` 都是
///    **`display: contents`**
///
/// 第 3 点解释了一切：`display: contents` 的元素**本身不产生盒子**，
/// 因此 `getBoundingClientRect()` 返回 `0×0` 是**规范行为**，不是缺陷。
/// 我一直在用错误的元素测尺寸，把正常现象当成了 bug。
///
/// **结论**：DSH 的布局是自洽的（flex/grid + display:contents），
/// 任何外部强加的 width/height/flex 都会破坏它。手机宽度下 DSH 原生
/// 就是纯对话区（spike 2 已验），我们只需要隐藏宽屏才出现的侧栏。
library;

import 'dart:convert';

/// 生成收窄 CSS 的注入脚本。
///
/// [includeHeader] 为 true 时不注入任何样式（完全交给 DSH）。
///
/// ## 为什么要带「head 尚未出现」的兜底
///
/// `AT_DOCUMENT_START` 注入时 `<head>` **可能还不存在**（解析器尚未建出它）。
/// 早先的写法是 `(document.head || document.documentElement).appendChild(style)`，
/// 探针实测结果落在 `<html>` 上（`parent: "HTML"`）。样式虽然仍生效，
/// 但 `<html>` 上的 `<style>` 会被 DSH 后续的 head 重建操作漏掉，
/// 且原实现用 `if (getElementById) return` 做幂等，导致**再也不会补注入**。
///
/// 现在改为：能插 head 就插 head，插不上就在 DOMContentLoaded 时重试；
/// 已存在则**刷新内容**而不是直接 return，保证重复调用是安全的幂等操作。
String sessionNarrowCss({bool includeHeader = false}) {
  if (includeHeader) return '';

  // 注意：这段是 JS 源码字符串。CSS 与 JS 里都不含 `$`，用普通字符串即可。
  return '''
(function () {
  var ID = 'dsh-mobile-narrow';
  var css = [
    '@media (min-width: 768px) {',
    '  [data-slot="sidebar"] { display: none !important; }',
    '  [data-slot="sidebar.root"] { display: none !important; }',
    '  [data-slot="sidebar.handle"] { display: none !important; }',
    '  [data-slot="sidebar.right"] { display: none !important; }',
    '  [data-slot="sidebar-right"] { display: none !important; }',
    '}',
    '[role="separator"] { display: none !important; }'
  ].join('\\n');

  function apply() {
    try {
      var el = document.getElementById(ID);
      if (!el) {
        el = document.createElement('style');
        el.id = ID;
        var host = document.head || document.documentElement;
        if (!host) return false;
        host.appendChild(el);
      }
      if (el.textContent !== css) el.textContent = css;
      return true;
    } catch (e) {
      return false;
    }
  }

  if (!apply()) {
    document.addEventListener('DOMContentLoaded', apply, { once: true });
  }
})();
''';
}

/// 用于校验「当前显示的是哪个会话」的探测脚本。
///
/// 返回 `data-conversation-session` 的值，或 null。
/// 上层应在 `onLoadStop` 后调用它，确认打开的确实是目标会话
/// —— 因为 localStorage 写入失败时页面会静默退回默认会话。
const String probeCurrentSessionJs = '''
(function () {
  var el = document.querySelector('[data-conversation-session]');
  return el ? el.getAttribute('data-conversation-session') : null;
})();
''';

/// 就绪 + 强制重绘脚本。
///
/// 返回 JSON 字符串：`{marker, rows, visible, scrolled}`。
///
/// ## 为什么要「滚到底 → 抖 1px → 回底部」
///
/// Android WebView 首屏之外的区域**没有执行绘制**（invalidation 缺失），
/// 表现为「只看到顶部一小段，手指滚一下内容才全部出现」。这不是布局问题
/// —— 探针确认 133 个子元素里 129 个有正常高度，而截图上 y=950 之后只剩
/// 左边框一条竖线。滚动会强制触发重绘。
///
/// 只在 `rows > 0`（对话内容已经渲染）时滚动，避免把欢迎页/骨架屏滚乱。
const String settleAndRepaintJs = '''
(function () {
  try {
    var el = document.querySelector('[data-conversation-session]');
    var flow = document.querySelector('[data-slot="conversation.chat.flow"]');
    var rows = flow ? flow.children.length : 0;
    var visible = 0;
    for (var i = 0; i < rows; i++) {
      if (flow.children[i].getBoundingClientRect().height > 0) visible++;
    }

    var best = null, bestArea = 0;
    var all = document.querySelectorAll('*');
    for (var j = 0; j < all.length; j++) {
      var n = all[j];
      var cs = getComputedStyle(n);
      if ((cs.overflowY === 'auto' || cs.overflowY === 'scroll')
          && n.scrollHeight > n.clientHeight + 40 && n.clientHeight > 200) {
        var area = n.scrollHeight * n.clientHeight;
        if (area > bestArea) { bestArea = area; best = n; }
      }
    }

    var scrolled = -1;
    if (best && rows > 0) {
      best.scrollTop = best.scrollHeight;
      best.scrollTop = best.scrollHeight - 1;
      best.scrollTop = best.scrollHeight;
      scrolled = best.scrollTop;
    }

    return JSON.stringify({
      marker: el ? el.getAttribute('data-conversation-session') : null,
      rows: rows,
      visible: visible,
      scrolled: scrolled
    });
  } catch (e) {
    return JSON.stringify({ err: String(e) });
  }
})();
''';

/// 主题注入脚本：把 App 的明暗设置同步到 DSH 页面。
///
/// ## DSH 的主题机制
///
/// `dsh-client-ui-layout` 的 ThemePresenter 通过 **`document.body` 上的
/// `data-ds-dark-theme` 属性**切换暗色调色板；同时把主题来源写到
/// `data-ds-theme-source`（`light` / `dark` / `system`）。
///
/// ## 为什么需要它
///
/// WebView 是**独立文档**，不继承 App 的 Flutter 主题。不注入的话：
/// App 切到深色、点进会话详情却是浅色页面，像两个 App 拼在一起。
///
/// ## 为什么同时设 `color-scheme`
///
/// DSH 页面的滚动条、原生控件（input/select）跟随 `color-scheme`。
/// 只设属性不设它，深色下滚动条仍是浅色的白条。
String themeBootstrap({required bool dark, String? localeTag}) {
  final theme = dark ? 'dark' : 'light';
  final boolLiteral = dark ? 'true' : 'false';
  // DSH 用 `dsh.locale.preference` 记住语言（Host user-settings 的浏览器侧镜像）。
  // 未设置时它读 navigator.language —— WebView 默认 en-US，所以是英文。
  final localeLiteral = localeTag == null ? 'null' : jsonEncode(localeTag);
  return '''
(function () {
  try {
    var root = document.documentElement;
    var body = document.body;
    // 属性挂在 body 上（ThemePresenter 读的就是 body）
    if (body) {
      if ($boolLiteral) {
        body.setAttribute('data-ds-dark-theme', '');
      } else {
        body.removeAttribute('data-ds-dark-theme');
      }
      body.setAttribute('data-ds-theme-source', '$theme');
    }
    // 同时挂 html：DSH 的 CSS 里 `[data-ds-dark-theme]` 选择器
    // 在 body 尚未解析时就可能被求值，提前挂上避免先渲染浅色。
    if (root) {
      if ($boolLiteral) {
        root.setAttribute('data-ds-dark-theme', '');
      } else {
        root.removeAttribute('data-ds-dark-theme');
      }
      root.setAttribute('data-ds-theme-source', '$theme');
    }
    // color-scheme 挂 html，影响滚动条与原生控件。
    // 同时设背景色：reload 期间 DSH 尚未渲染，浏览器用默认白/黑色画底，
    // 深色主题下会闪一下黑。这里先把 html 背景定成主题色，重载瞬间也一致。
    if (root) {
      root.style.colorScheme = '$theme';
      root.style.backgroundColor = $dark
        ? '#151517'
        : '#f7f8fa';
      // 语言：DSH 的初始语言来自 `navigator.languages`（只读一次，
    // 见 dsh-client-locale 的 resolveInitialLocale）。
    // 因此**必须**在文档开始时把 navigator 的语言改掉 ——
    // 只写 localStorage / lang 属性它根本不读。
      if ($localeLiteral !== null) {
        root.setAttribute('lang', $localeLiteral);
      }
    }
    if ($localeLiteral !== null) {
      try {
        // navigator.language / languages 是只读属性，用 defineProperty 覆盖。
        // 必须在 DSH 脚本执行前完成（AT_DOCUMENT_START 满足）。
        var langs = [$localeLiteral, $localeLiteral.split('-')[0]];
        Object.defineProperty(navigator, 'languages', {
          get: function () { return langs; },
          configurable: true
        });
        Object.defineProperty(navigator, 'language', {
          get: function () { return $localeLiteral; },
          configurable: true
        });
      } catch (e) {
        console.warn('[dsh-mobile] navigator language override failed', e);
      }
    }
  } catch (e) {
    console.warn('[dsh-mobile] theme bootstrap failed', e);
  }
})();
''';
}

/// 主题守卫：在页面内装一个 MutationObserver，只在**不一致时**纠正。
///
/// ## 为什么需要它
///
/// DSH 的 `ThemePresenter`（`dsh-client-ui-layout`）会在插件激活时
/// `apply(snapshot)`，按**它自己的**主题设置写
/// `document.body[data-ds-dark-theme]`。我们在 `AT_DOCUMENT_START`
/// 写的属性会被它覆盖 —— 表现为「外层浅色、WebView 深色」。
///
/// ## 为什么不用 Dart 侧轮询
///
/// 试过每 200ms 从 Dart 推一次，结果是**闪烁**：两个写入者互相覆盖，
/// 用户看到先黑后白。页面内 observer 的好处是它只在属性被改动时
/// 触发一次判断，一致就什么都不做，不会产生抖动。
///
/// ## 为什么不会被 DSH 再次覆盖
///
/// observer 在每次属性变更后立即检查：若与期望不符就改回来。
/// DSH 只在主题切换时写一次，写完后 observer 纠正，之后稳定。
String themeGuardScript({required bool dark, String? localeTag}) {
  final boolLiteral = dark ? 'true' : 'false';
  final theme = dark ? 'dark' : 'light';
  return '''
(function () {
  try {
    var want = $boolLiteral;
    var scheme = '$theme';

    // AT_DOCUMENT_START 时 <body> 可能还不存在。
    // 先挂一个 html 上的 observer 等 body 出现，再转为监听 body 属性。
    function install(body) {
      function correct() {
        var has = body.hasAttribute('data-ds-dark-theme');
        if (has !== want) {
          if (want) body.setAttribute('data-ds-dark-theme', '');
          else body.removeAttribute('data-ds-dark-theme');
        }
        if (document.documentElement.style.colorScheme !== scheme) {
          document.documentElement.style.colorScheme = scheme;
        }
      }
      correct();
      var observer = new MutationObserver(function () {
        // 期望值可能被后续的 _applyTheme 更新（切换主题）
        var w = window.__dshMobileThemeWant !== undefined
          ? window.__dshMobileThemeWant : want;
        var has = body.hasAttribute('data-ds-dark-theme');
        if (has !== w) {
          if (w) body.setAttribute('data-ds-dark-theme', '');
          else body.removeAttribute('data-ds-dark-theme');
        }
      });
      observer.observe(body, {
        attributes: true,
        attributeFilter: ['data-ds-dark-theme']
      });
      window.__dshMobileThemeGuard = { want: want, scheme: scheme };
      window.__dshMobileThemeObserver = observer;
      window.__dshMobileThemeWant = want;
    }

    // ★ 拦在写入之前：DSH 的 ThemePresenter 在同一个同步调用里
    // 先设 color-scheme 再设 data-ds-dark-theme。MutationObserver 是
    // **异步**的（微任务），等它触发时浏览器已经用深色画完一帧 ——
    // 用户看到的就是「闪一下黑」。
    //
    // 因此必须劫持 setAttribute / removeAttribute：DSH 想设成深色时
    // 我们直接不写（或改写成期望值），它那一帧就是对的。
    function hijack() {
      var proto = Element.prototype;
      if (proto.__dshMobileThemeHijacked) return;
      var origSet = proto.setAttribute;
      var origRemove = proto.removeAttribute;
      // color-scheme 是 style 属性，同样会被 DSH 写成 dark。
      // 用 CSSOM 的 setProperty 拦截。
      var rootStyle = document.documentElement.style;
      var origSetProp = CSSStyleDeclaration.prototype.setProperty;
      CSSStyleDeclaration.prototype.setProperty = function (name, value, priority) {
        if (name === 'color-scheme' && this === rootStyle && value !== scheme) {
          return; // 忽略 DSH 写的错误 scheme
        }
        return origSetProp.call(this, name, value, priority);
      };
      proto.setAttribute = function (name, value) {
        if (name === 'data-ds-dark-theme') {
          // 只允许写「期望值」：期望浅色时忽略深色写入
          if (!want) return;
          return origSet.call(this, name, value);
        }
        return origSet.call(this, name, value);
      };
      proto.removeAttribute = function (name) {
        if (name === 'data-ds-dark-theme') {
          if (want) return; // 期望深色时忽略移除
          return origRemove.call(this, name);
        }
        return origRemove.call(this, name);
      };
      proto.__dshMobileThemeHijacked = true;
    }
    hijack();

    // ★ 最关键的一步：在 DSH 的任何样式生效之前，把 html/body 的底色
    // 直接写死成主题色。
    //
    // 闪白的真正来源不是 WebView 平台视图（已设 transparent），而是
    // **HTML 文档本身**：DSH 的 CSS 还没加载时，浏览器用默认白底画一帧。
    // 用 !important 的 inline style 压住，等 DSH 样式就绪后再让它接管。
    function paintBase() {
      var root = document.documentElement;
      var bg = $dark ? '#151517' : '#f7f8fa';
      if (root) {
        root.style.setProperty('background-color', bg, 'important');
      }
      if (document.body) {
        document.body.style.setProperty('background-color', bg, 'important');
      }
      // 把暗色属性挂到 **html** 上（DSH 挂 body）。
      // 这样即使 body 还不存在、或 DSH 稍后才挂 body，
      // 基于 `[data-ds-dark-theme]` 的 CSS 也能提前命中 ——
      // 深色主题下不会先渲染浅色。
      if ($dark && root) {
        root.setAttribute('data-ds-dark-theme', '');
      }
    }
    paintBase();
    // body 出现后再刷一次（AT_DOCUMENT_START 时通常还没有 body）
    if (!document.body) {
      var paintWatch = new MutationObserver(function () {
        if (document.body) {
          paintBase();
          paintWatch.disconnect();
        }
      });
      paintWatch.observe(document.documentElement, { childList: true });
    }
    // 等 DSH 样式就绪后撤掉我们的底色，交还给它（避免和它的主题打架）
    setTimeout(function () {
      try {
        var root2 = document.documentElement;
        // 只撤 background-color，**保留** html 上的 data-ds-dark-theme
        if (root2) root2.style.removeProperty('background-color');
        if (document.body) document.body.style.removeProperty('background-color');
      } catch (e) {}
    }, 1200);

    if (document.body) {
      install(document.body);
      return;
    }
    // body 还没解析出来：监听 documentElement 的子节点变化
    var boot = new MutationObserver(function () {
      if (document.body) {
        boot.disconnect();
        install(document.body);
      }
    });
    boot.observe(document.documentElement, { childList: true });

  } catch (e) {
    console.warn('[dsh-mobile] theme guard failed', e);
  }
})();
''';
}
