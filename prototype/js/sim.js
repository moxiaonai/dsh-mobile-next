/* ============================================================================
   sim.js — fake live event stream.
   ----------------------------------------------------------------------------
   The reference gateway pushes `task-notify {sessionId, turn}` and the page
   consumes session/tool deltas over a WS mux. Neither payload shape is
   evidenced (architecture §4.1 marks them ASSUMPTION), so this simulator emits
   the *effects* the UI needs instead of pretending to be the wire protocol:

     step    → a tool call starts / finishes   (activity strip, §7)
     message → an assistant delta lands         (transcript)
     pending → a question / approval arrives    (dock, §6)
     done    → turn/end with reason=completed   (task-events.ts, evidenced)
     conn    → SSE drop / recovery              (offline banner, §8.3)

   Everything is on a timer that can be paused from the prototype demo sheet,
   and every timer is registered so pausing genuinely stops the world.
   ========================================================================== */
(function (global) {
  'use strict';

  var timers = [];
  var stepTimer = null;
  var booted = false;

  var TOOL_POOL = [
    { name: 'Read', args: ['src/pay/refund.ts', 'src/pay/policy.ts', 'src/auth/session.ts', 'docs/install.md'] },
    { name: 'Grep', args: ['retryPolicy', 'AbortController', 'org_id', 'useSessions'] },
    { name: 'Edit', args: ['src/pay/refund.ts', 'src/auth/login.tsx', 'docs/install.md'] },
    { name: 'Bash', args: ['pnpm test pay/refund', 'pnpm lint --fix', 'pnpm db:migrate --dry-run'] },
    { name: 'Write', args: ['migrations/2026_11_user_settings.ts', 'docs/install.md'] }
  ];

  var ASSISTANT_SNIPPETS = [
    '现在把 `createRefund` 的调用点一起改掉，避免类型不匹配。',
    '测试跑完了，`refund` 相关 12 个用例通过，还有 2 个快照需要更新。',
    '顺手把重复的重试分支合并成一个 helper，行为不变。',
    '正在检查改动是否会影响到 `settle` 的幂等逻辑。',
    '这里有个边界情况：金额为 0 时不应该走重试，已经补上判断。'
  ];

  function rand(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

  /** Register a timer so the demo switch can cancel everything at once. */
  function later(fn, ms) {
    var id = setTimeout(function () {
      timers = timers.filter(function (t) { return t !== id; });
      if (!Store.state.simPaused) fn();
    }, ms);
    timers.push(id);
    return id;
  }

  function every(fn, ms) {
    var id = setInterval(function () {
      if (!Store.state.simPaused) fn();
    }, ms);
    timers.push(id);
    return id;
  }

  function cancelAll() {
    timers.forEach(function (id) { clearTimeout(id); clearInterval(id); });
    timers = [];
    stepTimer = null;
  }

  /* ── Individual beats ─────────────────────────────────────────────────── */

  /** One tool call on a running task. This is what makes the strip feel alive. */
  function stepBeat(taskId) {
    var task = Store.getTask(taskId);
    if (!task || (task.state !== 'running' && task.state !== 'needs_input')) return;
    if (!Store.state.online) return;      // §8.3: never animate while offline

    // Finish whatever is currently running, then start a new one.
    var running = task.steps.filter(function (s) { return s.status === 'run'; })[0];
    if (running) {
      Store.actions.finishStep(taskId, running.name, 'ok');
    }

    var tool = rand(TOOL_POOL);
    Store.actions.addStep(taskId, { name: tool.name, arg: rand(tool.args), status: 'run', durMs: 0 });

    // Occasionally the assistant says something too, so the transcript moves.
    if (Math.random() < 0.35) {
      Store.actions.appendTranscript(taskId, {
        role: 'assistant',
        md: rand(ASSISTANT_SNIPPETS),
        streaming: true
      });
    }
  }

  /** A task finishing — mirrors turn/end + reason.kind === 'completed'. */
  function completeBeat(taskId) {
    var task = Store.getTask(taskId);
    if (!task || task.state === 'completed') return;
    if (task.pending.length) return;    // never complete while blocked on the user
    Store.actions.finishStep(taskId);
    Store.actions.appendTranscript(taskId, {
      role: 'assistant',
      md: '改动完成。\n\n- `createRefund` 及其 4 个调用点已改为 async\n- 重试策略保持不变，`retry` 取代了 `retrySync`\n- `pnpm test pay/refund` 通过（12 passed）'
    });
    Store.actions.completeTask(taskId);
  }

  /** A brand new task started on the PC, discovered by the phone. */
  function newTaskBeat() {
    var id = 't_live_' + Date.now().toString(36);
    Store.state.tasks.push({
      id: id,
      sessionId: 'ses_' + Math.random().toString(36).slice(2, 8),
      title: '补齐 org 设置的接口测试',
      workspace: 'dsh-api',
      model: 'Sonnet 4.5',
      state: 'running',
      turn: 1,
      startedAt: Date.now(),
      lastEventAt: Date.now(),
      completedAt: null,
      latencyMs: Store.state.latencyMs,
      steps: [{ name: 'Read', arg: 'test/org.settings.test.ts', status: 'run', durMs: 0 }],
      pending: [],
      transcript: [
        { role: 'user', at: Date.now(), md: '给 org 设置接口补上测试，覆盖权限不足的分支。' },
        { role: 'assistant', at: Date.now(), md: '先看现有测试的结构，然后补 3 个用例。' }
      ]
    });
    Store.emit('task:new', { taskId: id });
    Store.toast('电脑上开始了一个新任务');
    return id;
  }

  /** A question arriving from the desktop agent (the dock's reason to exist). */
  function questionBeat(taskId) {
    var task = Store.getTask(taskId);
    if (!task || task.pending.length) return;
    Store.actions.addPending(taskId, {
      id: 'q_live_' + Date.now().toString(36),
      kind: 'question',
      title: '这三个用例要直接替换掉旧的快照，还是保留两套？',
      body: '旧的快照断言的是同步返回的 shape，改成 async 之后会对不上。保留两套会多 40 行，但可以分阶段迁移。',
      multi: false,
      options: [
        { id: 'replace', label: '直接替换旧快照' },
        { id: 'both', label: '保留两套，分阶段迁移' },
        { id: 'other', label: '其他（在下面说明）' }
      ],
      allowFreeText: true
    });
    Store.toast('「' + task.title + '」在等你回答');
  }

  /** Connection drop + honest recovery (§8.3, §5.4). */
  function offlineBeat() {
    if (!Store.state.online) return;
    Store.actions.setOnline(false);
    Store.toast('实时连接已断开 · 数据可能已过期');
    later(function () {
      Store.actions.setReconnecting(true);
      later(function () {
        Store.actions.setReconnecting(false);
        Store.actions.setOnline(true);
        Store.toast('已恢复实时更新');
      }, 2200);
    }, 5000);
  }

  /** Small latency drift so the header number is not a constant. */
  function latencyBeat() {
    if (!Store.state.online) return;
    var base = 10 + Math.round(Math.random() * 24);
    Store.actions.setLatency(base);
  }

  /* ── Scripted opening (what a first-time user sees) ───────────────────── */

  function start() {
    if (booted) return;
    booted = true;

    // Tool calls keep landing on whatever is running. 4s cadence: fast enough to
    // notice, slow enough to read.
    stepTimer = every(function () {
      var running = Store.runningTasks().filter(function (t) { return t.state === 'running'; });
      if (!running.length) return;
      stepBeat(rand(running).id);
    }, 4000);

    every(latencyBeat, 9000);

    // Scripted beats, spaced so a viewer can follow each one.
    later(function () { stepBeat('t_payment'); }, 1800);
    later(function () { stepBeat('t_docs'); }, 6000);
    later(function () { completeBeat('t_docs'); }, 14000);
    later(function () {
      var id = newTaskBeat();
      later(function () { questionBeat(id); }, 9000);
    }, 22000);
    later(offlineBeat, 46000);
  }

  function pause() {
    Store.actions.setSimPaused(true);
  }

  function resume() {
    Store.actions.setSimPaused(false);
  }

  function reset() {
    cancelAll();
    booted = false;
    start();
  }

  /* Exposed so the prototype demo sheet can trigger any beat on demand. */
  global.Sim = {
    start: start,
    pause: pause,
    resume: resume,
    reset: reset,
    cancelAll: cancelAll,
    beats: {
      step: function () {
        var running = Store.runningTasks().filter(function (t) { return t.state === 'running'; });
        if (running.length) stepBeat(rand(running).id);
      },
      stepOn: stepBeat,
      complete: function () {
        var running = Store.runningTasks().filter(function (t) { return t.state === 'running' && !t.pending.length; });
        if (running.length) completeBeat(rand(running).id);
      },
      question: function () {
        var target = Store.runningTasks().filter(function (t) { return t.state === 'running'; })[0];
        if (target) questionBeat(target.id);
        else questionBeat(newTaskBeat());
      },
      newTask: newTaskBeat,
      offline: offlineBeat
    }
  };
})(window);
