/* ============================================================================
   store.js — single source of truth for the prototype.
   ----------------------------------------------------------------------------
   Shape is deliberately close to the proposed read model in
   docs/20-architecture.md §4.4 (TaskSummary) so the UI code can be lifted into
   the real client with a data-source swap and no layout rework.

   Everything mutating goes through a named action that emits 'change'. Screens
   subscribe and re-render their own region; there is no virtual DOM and no
   diffing, which is fine at this scale and keeps the prototype dependency-free.
   ========================================================================== */
(function (global) {
  'use strict';

  var LS_KEY = 'dsh-mobile-prototype/v1';
  var bus = new U.Emitter();

  /* ── Persisted preferences (theme, font size, last-visit waterline) ───────
     Only UI preferences are persisted. No transcript, no drafts: the spec says
     drafts belong to DSH, not to us (architecture §5.5).
     ──────────────────────────────────────────────────────────────────────── */
  function loadPrefs() {
    try {
      return JSON.parse(localStorage.getItem(LS_KEY) || '{}') || {};
    } catch (e) { return {}; }
  }

  function savePrefs(patch) {
    try {
      var next = Object.assign(loadPrefs(), patch);
      localStorage.setItem(LS_KEY, JSON.stringify(next));
    } catch (e) { /* private mode — preferences simply do not persist */ }
  }

  var prefs = loadPrefs();

  /* ── State ────────────────────────────────────────────────────────────── */
  var state = {
    /* appearance */
    theme: prefs.theme || 'system',       // 'system' | 'light' | 'dark'
    resolvedTheme: 'light',
    fontBase: prefs.fontBase || 16,
    reduceMotion: prefs.reduceMotion || 'system',

    /* navigation */
    tab: 'home',                          // home | sessions | devices
    push: null,                           // {name:'task', id} | {name:'inbox'} | …
    pushStack: [],

    /* connectivity (offline is first-class, not an afterthought) */
    online: true,
    reconnecting: false,
    lastSyncedAt: Date.now(),
    latencyMs: 12,

    /* data */
    tasks: SEED.tasks.map(function (t) { return Object.assign({}, t, { pending: t.pending.slice(), steps: t.steps.slice() }); }),
    sessions: SEED.sessions.map(function (s) { return Object.assign({}, s); }),
    devices: SEED.devices.map(function (d) { return Object.assign({}, d); }),
    inbox: SEED.inbox.map(function (n) { return Object.assign({}, n); }),
    diagnostics: SEED.diagnostics,

    /* supervision UI state, keyed by task id (survives tab switches) */
    ui: {
      follow: {},          // taskId -> bool (auto-scroll transcript)
      stripOpen: {},       // taskId -> bool (activity strip expanded)
      dockOpen: {},        // taskId -> bool
      dockIndex: {},       // taskId -> index into pending[]
      answers: {},         // pendingId -> {choice, freeText}
      submitting: {},      // pendingId -> bool
      draft: {},           // taskId -> composer text (never persisted)
      attached: {},        // taskId -> [{name, kind}]
      scroll: {}           // screen key -> scrollTop
    },

    /* "finished since last visit" waterline — pure client-side (architecture §4.4) */
    lastVisitAt: prefs.lastVisitAt || (Date.now() - 30 * 60 * 1000),

    /* transient */
    toasts: [],
    simPaused: false
  };

  /* ── Derived selectors ────────────────────────────────────────────────── */

  function getTask(id) {
    for (var i = 0; i < state.tasks.length; i++) if (state.tasks[i].id === id) return state.tasks[i];
    return null;
  }

  function runningTasks() {
    return state.tasks.filter(function (t) {
      return t.state === 'running' || t.state === 'needs_input' || t.state === 'failed';
    }).sort(function (a, b) {
      // needs_input first (it is blocking), then running by start time desc
      var rank = function (t) { return t.state === 'needs_input' ? 0 : t.state === 'running' ? 1 : 2; };
      return rank(a) - rank(b) || b.startedAt - a.startedAt;
    });
  }

  /** Tasks that block on the user: pending questions/approvals. */
  function needsYou() {
    return state.tasks.filter(function (t) { return t.pending.length > 0 && t.state !== 'completed'; });
  }

  /** Completed after the last-visit waterline. */
  function finishedSinceVisit() {
    return state.tasks.filter(function (t) {
      return t.state === 'completed' && t.completedAt && t.completedAt > state.lastVisitAt;
    }).sort(function (a, b) { return b.completedAt - a.completedAt; });
  }

  function completedTasks() {
    return state.tasks.filter(function (t) { return t.state === 'completed'; })
      .sort(function (a, b) { return (b.completedAt || 0) - (a.completedAt || 0); });
  }

  function unreadInboxCount() {
    return state.inbox.filter(function (n) { return !n.read; }).length;
  }

  function currentDevice() {
    for (var i = 0; i < state.devices.length; i++) if (state.devices[i].current) return state.devices[i];
    return null;
  }

  /** The single pending item the dock shows for a task (approval > question > plan). */
  function topPending(taskId) {
    var task = getTask(taskId);
    if (!task || !task.pending.length) return null;
    var rank = { approval: 0, question: 1, plan: 2 };
    var sorted = task.pending.slice().sort(function (a, b) { return rank[a.kind] - rank[b.kind]; });
    var idx = U.clamp(state.ui.dockIndex[taskId] || 0, 0, sorted.length - 1);
    return { item: sorted[idx], index: idx, total: sorted.length };
  }

  function getAnswer(pendingId) {
    return state.ui.answers[pendingId] || { choice: null, freeText: '' };
  }

  /* ── Mutations ────────────────────────────────────────────────────────── */

  function emit(type, payload) {
    bus.emit(type, payload);
    bus.emit('change', { type: type, payload: payload });
  }

  var actions = {
    /* appearance ---------------------------------------------------------- */
    setTheme: function (theme) {
      state.theme = theme;
      savePrefs({ theme: theme });
      applyTheme();
      emit('theme');
    },

    setFontBase: function (px) {
      state.fontBase = U.clamp(px, 12, 32);
      savePrefs({ fontBase: state.fontBase });
      document.documentElement.style.setProperty('--font-base', state.fontBase + 'px');
      document.documentElement.classList.toggle('font-large', state.fontBase >= 20);
      emit('font');
    },

    /* navigation ---------------------------------------------------------- */
    setTab: function (tab) {
      if (state.tab === tab && !state.push) return;
      state.push = null;
      state.pushStack = [];
      state.tab = tab;
      emit('nav');
    },

    push: function (name, id, opts) {
      state.pushStack.push(state.push);
      state.push = { name: name, id: id, opts: opts || {} };
      emit('nav');
    },

    back: function () {
      state.push = state.pushStack.pop() || null;
      emit('nav');
    },

    /* tasks --------------------------------------------------------------- */
    addStep: function (taskId, step) {
      var task = getTask(taskId);
      if (!task) return;
      // Mark the previous running step as finished unless it is the same name.
      task.steps = task.steps.map(function (s) {
        return s.status === 'run' ? Object.assign({}, s, { status: 'ok', durMs: s.durMs || 800 }) : s;
      });
      task.steps.push(Object.assign({ status: 'run', durMs: 0 }, step));
      if (task.steps.length > 50) task.steps = task.steps.slice(-50);  // §7.2 keeps last 50
      task.lastEventAt = Date.now();
      emit('task:step', { taskId: taskId, step: step });
    },

    finishStep: function (taskId, name, status) {
      var task = getTask(taskId);
      if (!task) return;
      task.steps = task.steps.map(function (s) {
        if (s.status === 'run' && (!name || s.name === name)) {
          return Object.assign({}, s, { status: status || 'ok', durMs: s.durMs || Math.round(600 + Math.random() * 1400) });
        }
        return s;
      });
      task.lastEventAt = Date.now();
      emit('task:step', { taskId: taskId });
    },

    appendTranscript: function (taskId, block) {
      var task = getTask(taskId);
      if (!task) return;
      task.transcript.push(Object.assign({ at: Date.now() }, block));
      task.lastEventAt = Date.now();
      emit('task:message', { taskId: taskId });
    },

    completeTask: function (taskId) {
      var task = getTask(taskId);
      if (!task) return;
      task.state = 'completed';
      task.completedAt = Date.now();
      task.lastEventAt = task.completedAt;
      task.pending = [];
      task.steps = task.steps.map(function (s) {
        return s.status === 'run' ? Object.assign({}, s, { status: 'ok', durMs: s.durMs || 700 }) : s;
      });
      state.ui.follow[taskId] = false;
      addInboxItem({
        kind: 'done',
        title: '已完成 · ' + task.title,
        workspace: task.workspace,
        taskId: task.id,
        pendingId: null
      });
      emit('task:complete', { taskId: taskId });
      toast('「' + task.title + '」已完成');
    },

    failTask: function (taskId, reason) {
      var task = getTask(taskId);
      if (!task) return;
      task.state = 'failed';
      task.completedAt = Date.now();
      task.error = reason || '未知错误';
      emit('task:failed', { taskId: taskId });
    },

    stopTask: function (taskId) {
      var task = getTask(taskId);
      if (!task) return;
      task.state = 'stopped';
      task.completedAt = Date.now();
      task.pending = [];
      task.steps = task.steps.map(function (s) {
        return s.status === 'run' ? Object.assign({}, s, { status: 'fail', durMs: s.durMs || 0 }) : s;
      });
      emit('task:stopped', { taskId: taskId });
      toast('已请求停止 · 已产生的输出保留');
    },

    /* pending interactions ------------------------------------------------ */
    addPending: function (taskId, pending) {
      var task = getTask(taskId);
      if (!task) return;
      task.pending.push(pending);
      if (task.state === 'running') task.state = 'needs_input';
      addInboxItem({
        kind: pending.kind === 'approval' ? 'approval' : pending.kind === 'plan' ? 'plan' : 'question',
        title: (pending.kind === 'approval' ? '等待审批 · ' : pending.kind === 'plan' ? '计划待批准 · ' : '等待回答 · ') + task.title,
        workspace: task.workspace,
        taskId: task.id,
        pendingId: pending.id
      });
      emit('pending:add', { taskId: taskId, pending: pending });
    },

    setAnswer: function (pendingId, patch) {
      var cur = state.ui.answers[pendingId] || { choice: null, freeText: '' };
      state.ui.answers[pendingId] = Object.assign({}, cur, patch);
      emit('pending:answer', { pendingId: pendingId });
    },

    setSubmitting: function (pendingId, value) {
      state.ui.submitting[pendingId] = value;
      emit('pending:submit', { pendingId: pendingId });
    },

    /** Resolve a pending item: remove it, append the answer to the transcript. */
    resolvePending: function (taskId, pendingId, summary) {
      var task = getTask(taskId);
      if (!task) return;
      task.pending = task.pending.filter(function (p) { return p.id !== pendingId; });
      delete state.ui.answers[pendingId];
      delete state.ui.submitting[pendingId];
      state.ui.dockIndex[taskId] = 0;
      if (!task.pending.length && task.state === 'needs_input') task.state = 'running';
      task.lastEventAt = Date.now();
      task.transcript.push({ role: 'user', at: Date.now(), md: summary, fromPending: true });
      // Mark the matching inbox row read — it has been handled.
      state.inbox = state.inbox.map(function (n) {
        return n.pendingId === pendingId ? Object.assign({}, n, { read: true, handled: true }) : n;
      });
      emit('pending:resolve', { taskId: taskId, pendingId: pendingId });
    },

    nextPending: function (taskId) {
      var t = topPending(taskId);
      if (!t || t.total < 2) return;
      state.ui.dockIndex[taskId] = (t.index + 1) % t.total;
      emit('pending:next', { taskId: taskId });
    },

    toggleDock: function (taskId) {
      state.ui.dockOpen[taskId] = !state.ui.dockOpen[taskId];
      emit('ui:dock', { taskId: taskId });
    },

    /* follow state machine (§7.3): paused >48px from bottom, resumed ≤8px */
    setFollow: function (taskId, value) {
      if (state.ui.follow[taskId] === value) return;
      state.ui.follow[taskId] = value;
      emit('ui:follow', { taskId: taskId, value: value });
    },

    toggleStrip: function (taskId) {
      state.ui.stripOpen[taskId] = !state.ui.stripOpen[taskId];
      emit('ui:strip', { taskId: taskId });
    },

    /* composer ------------------------------------------------------------ */
    setDraft: function (taskId, text) {
      state.ui.draft[taskId] = text;
    },

    sendMessage: function (taskId, text) {
      var task = getTask(taskId);
      if (!task) return;
      var trimmed = String(text || '').trim();
      if (!trimmed) return;
      task.transcript.push({ role: 'user', at: Date.now(), md: trimmed });
      task.lastEventAt = Date.now();
      state.ui.draft[taskId] = '';
      state.ui.attached[taskId] = [];
      if (task.state === 'completed' || task.state === 'failed' || task.state === 'stopped') {
        task.state = 'running';
        task.startedAt = Date.now();
        task.completedAt = null;
        task.error = null;
      }
      emit('task:message', { taskId: taskId, sent: true });
    },

    attachFile: function (taskId, file) {
      var list = state.ui.attached[taskId] || (state.ui.attached[taskId] = []);
      list.push(file);
      emit('composer:attach', { taskId: taskId });
    },

    removeAttachment: function (taskId, index) {
      var list = state.ui.attached[taskId] || [];
      list.splice(index, 1);
      emit('composer:attach', { taskId: taskId });
    },

    /* sessions ------------------------------------------------------------ */
    togglePin: function (sessionId) {
      state.sessions = state.sessions.map(function (s) {
        return s.id === sessionId ? Object.assign({}, s, { pinned: !s.pinned }) : s;
      });
      emit('sessions');
    },

    toggleMute: function (sessionId) {
      state.sessions = state.sessions.map(function (s) {
        return s.id === sessionId ? Object.assign({}, s, { muted: !s.muted }) : s;
      });
      emit('sessions');
    },

    archiveSession: function (sessionId) {
      var target = state.sessions.filter(function (s) { return s.id === sessionId; })[0];
      state.sessions = state.sessions.filter(function (s) { return s.id !== sessionId; });
      emit('sessions');
      return target;
    },

    restoreSession: function (session) {
      if (!session) return;
      state.sessions = state.sessions.concat([session]);
      emit('sessions');
    },

    markSessionRead: function (sessionId) {
      state.sessions = state.sessions.map(function (s) {
        return s.id === sessionId ? Object.assign({}, s, { unread: false }) : s;
      });
      emit('sessions');
    },

    /* inbox --------------------------------------------------------------- */
    markInboxRead: function (id) {
      state.inbox = state.inbox.map(function (n) {
        return n.id === id ? Object.assign({}, n, { read: true }) : n;
      });
      emit('inbox');
    },

    markAllInboxRead: function () {
      state.inbox = state.inbox.map(function (n) { return Object.assign({}, n, { read: true }); });
      emit('inbox');
      toast('全部标记为已读');
    },

    addInboxItem: function (partial) { addInboxItem(partial); },

    /* devices ------------------------------------------------------------- */
    switchDevice: function (deviceId) {
      state.devices = state.devices.map(function (d) {
        return Object.assign({}, d, { current: d.id === deviceId });
      });
      var target = currentDevice();
      if (target) {
        state.latencyMs = target.latencyMs || null;
        toast('已切换到 ' + target.name);
      }
      emit('devices');
    },

    setDeviceReach: function (deviceId, reach, latencyMs) {
      state.devices = state.devices.map(function (d) {
        return d.id === deviceId ? Object.assign({}, d, { reach: reach, latencyMs: latencyMs != null ? latencyMs : d.latencyMs }) : d;
      });
      emit('devices');
    },

    removeDevice: function (deviceId) {
      var removed = state.devices.filter(function (d) { return d.id === deviceId; })[0];
      state.devices = state.devices.filter(function (d) { return d.id !== deviceId; });
      emit('devices');
      return removed;
    },

    /* connection ---------------------------------------------------------- */
    setOnline: function (online) {
      state.online = online;
      if (online) state.lastSyncedAt = Date.now();
      emit('connection');
    },

    setReconnecting: function (v) {
      state.reconnecting = v;
      emit('connection');
    },

    setLatency: function (ms) {
      state.latencyMs = ms;
      emit('latency');
    },

    /* last visit ---------------------------------------------------------- */
    markVisit: function () {
      state.lastVisitAt = Date.now();
      savePrefs({ lastVisitAt: state.lastVisitAt });
      emit('visit');
    },

    /* misc ---------------------------------------------------------------- */
    setSimPaused: function (v) {
      state.simPaused = v;
      emit('sim');
    }
  };

  function addInboxItem(partial) {
    var item = Object.assign({
      id: 'n_' + Math.random().toString(36).slice(2, 8),
      at: Date.now(),
      read: false,
      pendingId: null,
      taskId: null,
      workspace: 'dsh-web'
    }, partial);
    state.inbox = [item].concat(state.inbox);
    emit('inbox', { added: item });
  }

  /* ── Theme resolution ─────────────────────────────────────────────────── */

  var mqlDark = global.matchMedia ? global.matchMedia('(prefers-color-scheme: dark)') : null;

  function resolveTheme() {
    if (state.theme === 'system') {
      return mqlDark && mqlDark.matches ? 'dark' : 'light';
    }
    return state.theme;
  }

  function applyTheme() {
    state.resolvedTheme = resolveTheme();
    document.documentElement.setAttribute('data-theme', state.resolvedTheme);
    document.documentElement.style.setProperty('--font-base', state.fontBase + 'px');
    document.documentElement.classList.toggle('font-large', state.fontBase >= 20);
  }

  if (mqlDark && mqlDark.addEventListener) {
    mqlDark.addEventListener('change', function () {
      if (state.theme === 'system') { applyTheme(); emit('theme'); }
    });
  }

  /* ── Toasts ───────────────────────────────────────────────────────────── */

  function toast(text, opts) {
    opts = opts || {};
    var item = {
      id: 'toast_' + Math.random().toString(36).slice(2, 8),
      text: text,
      action: opts.action || null,     // {label, onClick}
      kind: opts.kind || 'default',
      duration: opts.duration || 3200
    };
    state.toasts.push(item);
    emit('toast', item);
    setTimeout(function () {
      state.toasts = state.toasts.filter(function (t) { return t.id !== item.id; });
      emit('toast:remove', item);
    }, item.duration);
    return item.id;
  }

  global.Store = {
    state: state,
    on: bus.on.bind(bus),
    off: bus.off.bind(bus),
    emit: emit,
    actions: actions,
    // selectors
    getTask: getTask,
    runningTasks: runningTasks,
    needsYou: needsYou,
    finishedSinceVisit: finishedSinceVisit,
    completedTasks: completedTasks,
    unreadInboxCount: unreadInboxCount,
    currentDevice: currentDevice,
    topPending: topPending,
    getAnswer: getAnswer,
    // helpers
    toast: toast,
    applyTheme: applyTheme,
    savePrefs: savePrefs,
    loadPrefs: loadPrefs
  };

  global.toast = toast;   // used by util.js codeBlock copy handler
})(window);
