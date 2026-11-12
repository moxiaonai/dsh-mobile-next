/* ============================================================================
   app.js — shell, router, keyboard handling, demo panel.
   ----------------------------------------------------------------------------
   Routing model (frozen IA): three tabs + center FAB, task detail is a PUSH
   surface. Push surfaces replace the tab bar entirely and keep their own back
   stack, which is why `state.pushStack` exists rather than a URL router — the
   prototype must run from file:// where History API is awkward.

   Panels stay mounted (display:none) so switching tabs never loses scroll
   position, draft text or an expanded dock (brief principle 3).
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;

  var dom = {
    app: null,
    panels: {},
    tabbar: null,
    push: null,
    fab: null,
    tabs: {}
  };

  var currentPushKey = null;
  var currentDispose = null;   // tears down the active push surface's listener

  /* ── Boot ─────────────────────────────────────────────────────────────── */
  function boot() {
    dom.app = document.getElementById('app');
    dom.tabbar = document.getElementById('tabbar');
    dom.push = document.getElementById('push');
    dom.fab = document.getElementById('fab');

    ['home', 'sessions', 'devices'].forEach(function (name) {
      dom.panels[name] = document.getElementById('panel-' + name);
      dom.tabs[name] = document.getElementById('tab-' + name);
    });

    // Theme + font before first paint of content.
    Store.applyTheme();

    // Mount tab screens once; they re-render themselves on store changes.
    HomeScreen.mount(dom.panels.home);
    SessionsScreen.mount(dom.panels.sessions);
    DevicesScreen.mount(dom.panels.devices);

    UI.mountToastLayer();

    /* Tab bar wiring. */
    ['home', 'sessions', 'devices'].forEach(function (name) {
      dom.tabs[name].addEventListener('click', function () {
        Store.actions.setTab(name);
      });
    });

    dom.fab.addEventListener('click', function () { HomeScreen.openNewTaskSheet(); });

    /* Global keyboard support: Escape pops a push surface. */
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && Store.state.push) {
        var sheetOpen = !document.getElementById('sheet-layer').hidden;
        if (!sheetOpen) Store.actions.back();
      }
    });

    /* Router. */
    Store.on('change', function (evt) {
      if (evt.type === 'nav') renderRoute();
      if (evt.type === 'theme') {
        // Rebuild the active push surface so its header icon flips.
        if (Store.state.push) renderPush(true);
      }
      if (evt.type === 'connection') {
        // Offline banners live at the shell level for tab screens; the task
        // detail owns its own banner AND its dock must re-label its submit
        // action ("排队提交") the moment the connection drops (§6.7).
        renderOfflineState();
        if (Store.state.push && Store.state.push.name === 'task') TaskScreen.refresh();
      }
    });

    Store.on('task:step', function (p) { if (isOpenTask(p.taskId)) TaskScreen.onStep(); });
    Store.on('task:message', function (p) { if (isOpenTask(p.taskId)) TaskScreen.refresh(); });
    Store.on('pending:add', function (p) { if (isOpenTask(p.taskId)) TaskScreen.onPending(); });
    Store.on('pending:resolve', function (p) { if (isOpenTask(p.taskId)) TaskScreen.refresh(); });
    Store.on('task:complete', function (p) { if (isOpenTask(p.taskId)) TaskScreen.onComplete(); });
    Store.on('task:stopped', function (p) { if (isOpenTask(p.taskId)) TaskScreen.refresh(); });

    installKeyboardWatcher();
    installScrollReset();

    renderRoute();
    mountDemoHandle();

    // Kick the simulated stream once the first screen has painted.
    requestAnimationFrame(function () {
      setTimeout(function () { Sim.start(); }, 600);
    });
  }

  function isOpenTask(id) {
    var push = Store.state.push;
    return push && push.name === 'task' && push.id === id;
  }

  /* ── Routing ──────────────────────────────────────────────────────────── */
  function renderRoute() {
    var push = Store.state.push;

    if (push) {
      dom.tabbar.hidden = true;
      dom.app.classList.add('push-open');
      Object.keys(dom.panels).forEach(function (name) { dom.panels[name].hidden = true; });
      renderPush(false);
      return;
    }

    // Back to a tab: tear down any push surface.
    if (currentPushKey) {
      teardownPush();
      U.clear(dom.push);
      dom.push.hidden = true;
    }
    dom.tabbar.hidden = false;
    dom.app.classList.remove('push-open');

    Object.keys(dom.panels).forEach(function (name) {
      dom.panels[name].hidden = name !== Store.state.tab;
    });
    Object.keys(dom.tabs).forEach(function (name) {
      dom.tabs[name].setAttribute('aria-selected', String(name === Store.state.tab));
    });

    renderOfflineState();
  }

  function renderPush(force) {
    var push = Store.state.push;
    if (!push) return;

    // Include the resolved surface kind in the key. Two pushes with different
    // names but the same (empty) id used to collide — e.g. inbox -> pairing
    // reused the inbox render and never mounted the pairing screen.
    var key = push.name + '|' + (push.id || '') + '|' + (push.opts ? JSON.stringify(push.opts) : '');
    if (key === currentPushKey && !force) return;

    // Every push surface shares one container, so the previous surface must be
    // fully disposed (timers + store subscription) before the next one mounts.
    // Without this, a stale listener re-renders the old screen over the new one.
    teardownPush();
    currentPushKey = key;
    dom.push.hidden = false;

    if (push.name === 'task') {
      TaskScreen.mount(dom.push, push.id, push.opts);
    } else if (push.name === 'inbox') {
      currentDispose = InboxScreen.mount(dom.push);
    } else if (push.name === 'pairing') {
      currentDispose = PairingScreen.mount(dom.push);
    } else if (push.name === 'diagnostics') {
      currentDispose = SettingsScreens.diagnostics(dom.push);
    } else if (push.name === 'appearance') {
      currentDispose = SettingsScreens.appearance(dom.push);
    }
  }

  /** Dispose the active push surface: stop timers, drop the store listener. */
  function teardownPush() {
    if (currentDispose) {
      try { currentDispose(); } catch (e) { /* already gone */ }
      currentDispose = null;
    }
    TaskScreen.unmount();   // idempotent; clears the task screen tick timer
    currentPushKey = null;
  }

  /* Tab screens need an offline banner that is not inside their own render
     cycle (the banner is shell chrome, not screen content). Each screen also
     renders its own banner from UI.offlineBanner(), so this only fills the gap
     before a screen re-renders. */
  function renderOfflineState() {
    Object.keys(dom.panels).forEach(function (name) {
      var panel = dom.panels[name];
      var existing = panel.querySelector('.offline-banner--shell');
      var shouldShow = !Store.state.online && !panel.querySelector('.offline-banner');
      if (existing) existing.remove();
      if (shouldShow) {
        var banner = UI.offlineBanner();
        if (banner) {
          banner.classList.add('offline-banner--shell');
          var header = panel.querySelector('.header');
          if (header && header.nextSibling) panel.insertBefore(banner, header.nextSibling);
          else if (header) panel.appendChild(banner);
        }
      }
    });
  }

  /* ── Keyboard / visualViewport (§10) ───────────────────────────────────── */
  function installKeyboardWatcher() {
    var vv = global.visualViewport;
    if (!vv) return;

    var apply = U.debounce(function () {
      // >120px difference means a soft keyboard is up (spec §10 heuristic).
      var kbOpen = (global.innerHeight - vv.height) > 120;
      document.documentElement.classList.toggle('kb-open', kbOpen);
      document.documentElement.style.setProperty('--kb-height', Math.max(0, global.innerHeight - vv.height) + 'px');
      if (Store.state.push && Store.state.push.name === 'task') {
        // Dock must never stay expanded while the keyboard is open.
        var id = Store.state.push.id;
        if (kbOpen && Store.state.ui.dockOpen[id]) {
          Store.state.ui.dockOpen[id] = false;
          TaskScreen.refresh();
        }
      }
    }, 100);

    vv.addEventListener('resize', apply);
    vv.addEventListener('scroll', apply);
    apply();
  }

  /* Restore each screen's scroll position when returning to a tab. */
  function installScrollReset() {
    Store.on('change', function (evt) {
      if (evt.type !== 'nav') return;
      requestAnimationFrame(function () {
        var panel = dom.panels[Store.state.tab];
        if (!panel) return;
        var scroll = panel.querySelector('.scroll');
        if (!scroll) return;
        var saved = Store.state.ui.scroll[Store.state.tab];
        if (saved != null) scroll.scrollTop = saved;
      });
    });
  }

  /* ── Demo panel ───────────────────────────────────────────────────────────
     Entry points: a dashed row at the bottom of Devices, and the "d" key.
     Deliberately not a floating button — a fixed control over content would
     violate the "no content hidden behind fixed controls" rule. */
  function mountDemoHandle() {
    global.openDemoSheet = openDemoSheet;
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'd' && e.key !== 'D') return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      var tag = (document.activeElement && document.activeElement.tagName) || '';
      if (tag === 'INPUT' || tag === 'TEXTAREA') return;
      openDemoSheet();
    });
  }

  function openDemoSheet() {
    var paused = Store.state.simPaused;
    UI.openSheet({
      title: '原型演示',
      items: [
        { type: 'note', text: '这里可以手动触发模拟事件流，不用等它自己发生。' },
        {
          icon: 'play',
          label: '来一次工具调用',
          sub: '活动条会出现新的步骤',
          onClick: function () { Sim.beats.step(); }
        },
        {
          icon: 'check',
          label: '让一个任务完成',
          sub: '任务会进入"最近完成"并推一条通知',
          onClick: function () { Sim.beats.complete(); }
        },
        {
          icon: 'alert',
          label: '来一个待回答的问题',
          sub: 'dock 会停靠在输入框上方',
          onClick: function () { Sim.beats.question(); }
        },
        {
          icon: 'plus',
          label: '电脑上开一个新任务',
          sub: '首页会多一条进行中的任务',
          onClick: function () { Sim.beats.newTask(); }
        },
        {
          icon: 'wifi',
          label: '断开再恢复连接',
          sub: '演示离线横幅与诚实降级',
          onClick: function () { Sim.beats.offline(); }
        },
        {
          icon: paused ? 'play' : 'pause',
          label: paused ? '继续模拟事件流' : '暂停模拟事件流',
          sub: paused ? '当前已暂停' : '当前每 4 秒一次工具调用',
          onClick: function () { paused ? Sim.resume() : Sim.pause(); }
        },
        {
          icon: 'sun',
          label: '切换浅色 / 深色',
          onClick: function () { Store.actions.setTheme(Store.state.resolvedTheme === 'dark' ? 'light' : 'dark'); }
        },
        {
          icon: 'refresh',
          label: '重置模拟数据',
          sub: '重新加载页面',
          onClick: function () { location.reload(); }
        }
      ]
    });
  }

  /* Save scroll positions on tab change so returning restores them. */
  document.addEventListener('scroll', function (e) {
    var target = e.target;
    if (!target || !target.classList || !target.classList.contains('scroll')) return;
    var panel = target.closest('.tabpanel');
    if (panel) Store.state.ui.scroll[panel.dataset.tab] = target.scrollTop;
  }, true);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})(window);
