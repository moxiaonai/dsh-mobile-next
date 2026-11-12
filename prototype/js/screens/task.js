/* ============================================================================
   screens/task.js — 任务详情 Task detail (UI spec §5.4, §6, §7)
   ----------------------------------------------------------------------------
   Fixed layers, top to bottom:
     header 56 (back + title + status pill + latency + "…")
     meta row 32 (workspace · model · latency · elapsed)   [hidden on keyboard]
     activity strip 44 collapsed / expandable              [always live]
     transcript (the only scroll region)
     pending dock (fixed above composer, forced collapsed on keyboard)
     composer 64

   The two independent signals of §7.3 are implemented literally:
     follow      — does new content auto-scroll?   (paused >48px, resumed ≤8px)
     stripOpen   — is the activity strip expanded?
   A paused follow NEVER freezes the strip: the strip is always live, only the
   transcript stops following.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;
  var root = null;
  var taskId = null;
  var alive = false;

  /* DOM handles we mutate instead of re-rendering (scroll must survive). */
  var refs = {
    scroll: null,
    transcript: null,
    strip: null,
    stripCurrent: null,
    stripCount: null,
    stripFollow: null,
    stripSteps: null,
    dock: null,
    dockLayer: null,
    jump: null,
    composer: null,
    header: null,
    statusPill: null,
    metaElapsed: null,
    newSteps: 0
  };

  var tickTimer = null;

  /* ── Mount ────────────────────────────────────────────────────────────── */
  function mount(node, id, opts) {
    root = node;
    taskId = id;
    alive = true;
    opts = opts || {};
    refs.newSteps = 0;

    var task = Store.getTask(id);
    if (!task) {
      renderMissing(opts);
      return;
    }

    // follow defaults to true on first open (you land at the bottom).
    if (Store.state.ui.follow[id] == null) Store.state.ui.follow[id] = true;

    render();

    // Land at the bottom after layout.
    requestAnimationFrame(function () {
      if (Store.state.ui.follow[id]) U.scrollToBottom(refs.scroll, false);
    });

    if (tickTimer) clearInterval(tickTimer);
    tickTimer = setInterval(tickClocks, 1000);

    if (opts.openDock) {
      Store.state.ui.dockOpen[id] = true;
      syncDock();
    }
  }

  function unmount() {
    alive = false;
    if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
    root = null;
    taskId = null;
    refs = {
      scroll: null, transcript: null, strip: null, stripCurrent: null,
      stripCount: null, stripFollow: null, stripSteps: null, dock: null,
      dockLayer: null, jump: null, composer: null, header: null,
      statusPill: null, metaElapsed: null, newSteps: 0
    };
  }

  function tickClocks() {
    if (!root || !root.offsetParent) return;
    // Offline freezes every clock: a ticking timer would claim the task is
    // still progressing on a PC we cannot see (§8.3 "禁止继续计时").
    if (!Store.state.online) return;
    var task = Store.getTask(taskId);
    if (!task) return;
    if (refs.metaElapsed && (task.state === 'running' || task.state === 'needs_input')) {
      refs.metaElapsed.textContent = '已用 ' + U.fmtElapsed(Date.now() - task.startedAt);
    }
  }

  /* ── Full render (on open / structural change) ────────────────────────── */
  function render() {
    if (!alive || !root) return;
    var task = Store.getTask(taskId);
    if (!task) { renderMissing({}); return; }

    U.clear(root);

    refs.header = buildHeader(task);
    root.appendChild(refs.header);

    var banner = UI.offlineBanner();
    if (banner) root.appendChild(banner);

    root.appendChild(buildMetaRow(task));
    refs.strip = buildStrip(task);
    root.appendChild(refs.strip);

    /* Transcript: the single scroll region. */
    var scrollWrap = el('div', { style: { position: 'relative', flex: '1 1 auto', minHeight: '0', display: 'flex' } });
    refs.scroll = el('div.scroll.push__scroll');
    refs.transcript = el('div.transcript');
    refs.transcript.id = 'transcript-end-anchor';
    refs.transcript.setAttribute('tabindex', '-1');
    refs.scroll.appendChild(refs.transcript);
    scrollWrap.appendChild(refs.scroll);

    refs.jump = buildJumpButton(task);
    scrollWrap.appendChild(refs.jump);
    root.appendChild(scrollWrap);

    attachFollowMachine();

    refs.dockLayer = el('div.dock-layer');
    root.appendChild(refs.dockLayer);
    renderDock(task);

    refs.composer = buildComposer(task);
    root.appendChild(refs.composer);

    renderTranscript(task);
    updateStrip(task);
    syncDock();
    positionJumpButton();
  }

  /* ── Missing task (session without a live projection) ─────────────────── */
  function renderMissing(opts) {
    U.clear(root);
    var header = UI.header({
      lead: UI.backButton(),
      title: opts.title || '会话',
      smallTitle: true,
      titleId: 'task-h1'
    });
    root.appendChild(header);

    var wrap = el('div.scroll', null, [
      el('div.page', null, [
        UI.errorState({
          title: '这个会话还没有任务投影',
          text: '电脑上的这个会话当前没有可监督的任务。打开它之后，新的活动会出现在任务页。',
          code: opts.sessionId ? 'session ' + opts.sessionId : null,
          actions: [
            UI.button('返回会话', { variant: 'secondary', onClick: function () { Store.actions.back(); } }),
            UI.button('回到任务', { variant: 'primary', onClick: function () { Store.actions.setTab('home'); } })
          ]
        })
      ])
    ]);
    root.appendChild(wrap);
  }

  /* ── Header ───────────────────────────────────────────────────────────── */
  function buildHeader(task) {
    var titleWrap = el('div.detail-head__title', null, [
      el('h1', { text: task.title, title: task.title, id: 'task-h1' }),
      el('div.detail-head__sub', null, [
        refs.statusPill = UI.statusPill(task.state, { live: true }),
        el('span', { text: '·' }),
        el('span', {
          className: 'latency',
          text: Store.state.online && Store.state.latencyMs
            ? '● ' + Store.state.latencyMs + 'ms'
            : '—'
        })
      ])
    ]);

    var header = el('header.header.detail-head', null, [
      UI.backButton(),
      titleWrap,
      el('div.header__actions', null, [
        UI.iconBtn('more', '更多操作', { onClick: function () { openTaskSheet(task); } })
      ])
    ]);
    return header;
  }

  function openTaskSheet(task) {
    UI.openSheet({
      title: task.title,
      items: [
        {
          icon: 'stop',
          label: '停止运行',
          sub: '会中断当前工具调用，已产生的输出保留',
          danger: true,
          onClick: function () {
            if (task.state === 'completed' || task.state === 'stopped') {
              Store.toast('这个任务已经结束了');
              return;
            }
            Store.actions.stopTask(task.id);
            refreshStructure();
          }
        },
        {
          icon: 'file',
          label: '分叉到新会话',
          sub: '保留当前上下文，另开一个分支',
          onClick: function () { Store.toast('已在电脑上分叉出新会话'); }
        },
        {
          icon: 'terminal',
          label: '打开工作区',
          sub: task.workspace,
          onClick: function () { Store.toast('正在电脑上打开 ' + task.workspace); }
        },
        {
          icon: 'monitor',
          label: '在电脑上打开',
          sub: '电脑端会切到这个会话',
          onClick: function () { Store.toast('已在电脑上打开'); }
        },
        {
          icon: 'copy',
          label: '复制会话 ID',
          sub: task.sessionId,
          onClick: function () {
            U.copyText(task.sessionId).then(function () { Store.toast('已复制会话 ID'); });
          }
        }
      ]
    });
  }

  /* ── Meta row ─────────────────────────────────────────────────────────── */
  function buildMetaRow(task) {
    var wrap = el('div.meta-row');
    wrap.appendChild(UI.metaChip(task.workspace, { icon: 'terminal' }));
    wrap.appendChild(UI.metaChip(task.model));
    wrap.appendChild(el('span.latency', null, [
      el('span', { className: 'dot' + (Store.state.online ? '' : ' dot--idle') }),
      el('span', {
        text: Store.state.online && task.latencyMs ? '延迟约 ' + task.latencyMs + 'ms' : '未连接'
      })
    ]));
    refs.metaElapsed = el('span.latency', {
      text: '已用 ' + U.fmtElapsed(
        (Store.state.online ? Date.now() : Store.state.lastSyncedAt) - task.startedAt
      )
    });
    wrap.appendChild(refs.metaElapsed);
    if (!Store.state.online) {
      wrap.appendChild(el('span.chip', null, [
        icon('clock', 'i--xs'),
        el('span.chip__text', { text: '截至 ' + U.fmtClock(Store.state.lastSyncedAt) })
      ]));
    }
    wrap.appendChild(UI.metaChip(task.steps.length + ' 步'));
    return wrap;
  }

  /* ── C20 LiveActivityStrip ────────────────────────────────────────────── */
  function buildStrip(task) {
    var expanded = !!Store.state.ui.stripOpen[task.id];
    var strip = el('div.strip' + (expanded ? '.strip--expanded' : ''), {
      role: 'log',
      'aria-live': 'polite',
      'aria-relevant': 'additions',
      'aria-label': '实时活动'
    });

    refs.stripFollow = el('span.strip__follow' + (Store.state.ui.follow[task.id] ? '' : '.strip__follow--paused'), {
      text: Store.state.ui.follow[task.id] ? '跟随中' : '已暂停跟随'
    });

    refs.stripCurrent = el('span.strip__current', { text: '等待第一步' });
    refs.stripCount = el('span.strip__count', { text: '0 步' });

    var summary = el('button.strip__summary', {
      type: 'button',
      'aria-expanded': String(expanded),
      'aria-controls': 'strip-panel',
      onclick: function () {
        Store.actions.toggleStrip(task.id);
        var isOpen = !!Store.state.ui.stripOpen[task.id];
        strip.classList.toggle('strip--expanded', isOpen);
        summary.setAttribute('aria-expanded', String(isOpen));
      }
    }, [
      refs.stripFollow,
      refs.stripCurrent,
      refs.stripCount,
      el('span.strip__chev', null, [icon('chevron-down', 'i--sm')])
    ]);

    refs.stripSteps = el('div.strip__steps', { id: 'strip-panel' });

    strip.appendChild(summary);
    strip.appendChild(el('div.strip__panel', null, [refs.stripSteps]));
    return strip;
  }

  /** Update the strip in place — it stays live even when follow is paused. */
  function updateStrip(task) {
    if (!refs.stripCurrent) return;
    var current = task.steps.filter(function (s) { return s.status === 'run'; })[0];

    var verb = task.state === 'completed' ? '已完成' :
      task.state === 'failed' ? '已失败' :
      task.state === 'stopped' ? '已停止' :
      current ? '正在' : '等待';

    refs.stripCurrent.textContent = current
      ? current.name + ' ' + current.arg
      : task.state === 'completed'
        ? '全部步骤已完成'
        : task.state === 'failed'
          ? (task.error || '任务失败')
          : '等待下一步';

    refs.stripCount.textContent = task.steps.length + ' 步';

    if (refs.stripFollow) {
      var following = Store.state.ui.follow[task.id];
      refs.stripFollow.textContent = following ? '跟随中' : '已暂停跟随';
      refs.stripFollow.classList.toggle('strip__follow--paused', !following);
    }

    if (refs.stripSteps) {
      U.clear(refs.stripSteps);
      task.steps.slice().reverse().forEach(function (step) {
        var iconName = step.status === 'run' ? 'play' : step.status === 'fail' ? 'x' : 'check';
        var cls = step.status === 'run' ? 'step__icon step__icon--run' : step.status === 'fail' ? 'step__icon step__icon--fail' : 'step__icon';
        refs.stripSteps.appendChild(el('div.step', null, [
          el('span', { className: cls }, [icon(iconName, 'i--xs')]),
          el('span.step__name', { text: step.name }),
          el('span.step__arg', { text: step.arg, title: step.arg }),
          el('span.step__dur', { text: step.status === 'run' ? '…' : U.fmtDur(step.durMs || 0) })
        ]));
      });
      if (!task.steps.length) {
        refs.stripSteps.appendChild(el('div.step', null, [
          el('span.step__arg', { text: '等待第一步' })
        ]));
      }
    }
  }

  /* ── Transcript ───────────────────────────────────────────────────────── */
  function renderTranscript(task) {
    if (!refs.transcript) return;
    U.clear(refs.transcript);

    if (!task.transcript.length) {
      refs.transcript.appendChild(el('div.empty', null, [
        el('div.empty__icon', null, [icon('terminal', 'i--lg')]),
        el('p.empty__text', { text: '这个任务还没有输出。在下面输入第一句话，电脑上的代理会开始工作。' })
      ]));
      return;
    }

    task.transcript.forEach(function (block, index) {
      refs.transcript.appendChild(transcriptBlock(block, index));
    });
  }

  function transcriptBlock(block, index) {
    if (block.role === 'tool') {
      var fold = el('div.fold');
      var btn = el('button.fold__btn', {
        type: 'button',
        'aria-expanded': 'false',
        onclick: function () {
          var open = fold.classList.toggle('fold--open');
          btn.setAttribute('aria-expanded', String(open));
        }
      }, [
        icon('terminal', 'i--xs'),
        el('span.fold__name', { text: block.name }),
        el('span.fold__arg', { text: block.arg }),
        el('span.fold__chev', null, [icon('chevron-down', 'i--xs')])
      ]);
      var panel = el('div.fold__panel');
      var pre = el('pre');
      // Tool results arrive as fenced markdown; show the body verbatim (a tool
      // result is not prose) and drop the fence markers.
      var raw = String(block.md || '')
        .replace(/^\s*```[\w+#.-]*\s*\n?/, '')
        .replace(/\n?```\s*$/, '');
      pre.textContent = raw;
      panel.appendChild(pre);
      fold.appendChild(btn);
      fold.appendChild(panel);
      return el('div.tblock', null, [fold]);
    }

    var isUser = block.role === 'user';
    var who = isUser ? '你' : '助手';
    // `md` carries the markdown typography (styles.css §7). Without it the
    // rendered lists/headings/code inherit no spacing at all.
    var body = el('div.tblock__bubble.md');
    U.append(body, U.renderMarkdown(block.md || ''));

    var node = el('div.tblock' + (isUser ? '.tblock--user' : '.tblock--assistant'), null, [
      el('div.tblock__who', null, [
        el('span', { text: who }),
        el('span', { text: '·' }),
        el('span', { text: U.fmtClock(block.at) })
      ]),
      body
    ]);

    if (block.streaming) {
      node.appendChild(el('div.stream-tail', null, [
        el('span', { className: 'dot dot--accent' + (Store.state.online ? ' dot--pulse' : '') }),
        el('span', { text: '正在输出…' })
      ]));
    }
    return node;
  }

  /* ── Follow state machine (§7.3) ──────────────────────────────────────── */
  function attachFollowMachine() {
    var scroll = refs.scroll;
    var PAUSE_AT = 48;   // hysteresis: pause when > 48px from bottom
    var RESUME_AT = 8;   // resume only when ≤ 8px from bottom

    scroll.addEventListener('scroll', function () {
      var distance = scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight;
      var following = Store.state.ui.follow[taskId];

      if (following && distance > PAUSE_AT) {
        Store.actions.setFollow(taskId, false);
        refs.newSteps = 0;
        updateStrip(Store.getTask(taskId));
        positionJumpButton();
      } else if (!following && distance <= RESUME_AT) {
        Store.actions.setFollow(taskId, true);
        refs.newSteps = 0;
        updateStrip(Store.getTask(taskId));
        positionJumpButton();
      }
    }, { passive: true });
  }

  function buildJumpButton(task) {
    var btn = el('button.jump-latest', {
      type: 'button',
      hidden: true,
      onclick: function () {
        Store.actions.setFollow(task.id, true);
        refs.newSteps = 0;
        U.scrollToBottom(refs.scroll, true);
        updateStrip(task);
        positionJumpButton();
      }
    }, [
      icon('arrow-down', 'i--sm'),
      el('span', { text: '回到最新' })
    ]);
    btn._count = el('span.jump-latest__count', { hidden: true, text: '0' });
    btn.appendChild(btn._count);
    return btn;
  }

  /** Keep the pill just above the dock so they never overlap. */
  function positionJumpButton() {
    if (!refs.jump || !refs.dockLayer) return;
    var dockH = refs.dockLayer.offsetHeight || 0;
    refs.jump.style.bottom = (dockH + 12) + 'px';
    refs.jump.hidden = !!Store.state.ui.follow[taskId];
    if (refs.newSteps > 0 && !refs.jump.hidden) {
      refs.jump._count.hidden = false;
      refs.jump._count.textContent = '+' + refs.newSteps;
    }
  }

  /* ── Pending dock (§6) ────────────────────────────────────────────────── */
  function renderDock(task) {
    if (!refs.dockLayer) return;
    U.clear(refs.dockLayer);
    refs.dock = null;

    var top = Store.topPending(task.id);
    if (!top) { positionJumpButton(); return; }

    var expanded = !!Store.state.ui.dockOpen[task.id];
    var pending = top.item;
    var answer = Store.getAnswer(pending.id);
    var submitting = !!Store.state.ui.submitting[pending.id];

    var dock = el('div.dock' + (expanded ? '' : '.dock--collapsed'), {
      role: 'region',
      'aria-label': '待处理交互'
    });

    var reasonLabel = pending.kind === 'approval' ? '等待审批' :
      pending.kind === 'plan' ? '计划待批准' : '等待你的回答';

    /* Summary bar — 56 high, always shows reason + first title line. */
    var bar = el('button.dock__bar', {
      type: 'button',
      'aria-expanded': String(expanded),
      onclick: function () {
        Store.actions.toggleDock(task.id);
        renderDock(task);
        positionJumpButton();
      }
    }, [
      el('div.dock__bar-main', null, [
        UI.chip(reasonLabel, { cls: 'warn', icon: pending.kind === 'approval' ? 'shield' : 'alert' }),
        el('span.dock__bar-title', { text: pending.title })
      ]),
      el('span.dock__bar-count', {
        text: (top.index + 1) + '/' + top.total,
        'aria-live': 'polite',
        'aria-label': '等待处理，共 ' + top.total + ' 个，当前第 ' + (top.index + 1) + ' 个'
      }),
      top.total > 1 ? el('span.icon-btn', {
        role: 'button',
        tabindex: '0',
        'aria-label': '下一个待处理（还有 ' + (top.total - 1) + ' 个）',
        onclick: function (e) { e.stopPropagation(); Store.actions.nextPending(task.id); renderDock(task); },
        onkeydown: function (e) {
          if (e.key === 'Enter' || e.key === ' ') { e.stopPropagation(); Store.actions.nextPending(task.id); renderDock(task); }
        }
      }, [icon('chevron-right', 'i--sm')]) : null,
      el('span.icon-btn', { 'aria-hidden': 'true' }, [icon(expanded ? 'chevron-down' : 'chevron-up', 'i--sm')])
    ]);
    dock.appendChild(bar);

    if (!expanded) {
      refs.dockLayer.appendChild(dock);
      refs.dock = dock;
      positionJumpButton();
      return;
    }

    /* Body: question / approval / plan. */
    var body = el('div.dock__body');

    if (pending.kind === 'approval') {
      body.appendChild(el('p.dock__question', { text: '将在电脑上执行：' }));
      body.appendChild(el('div.dock__cmd', null, [
        pending.danger ? el('div.dock__cmd-label', { text: '这个操作可能不可撤销' }) : null,
        el('pre', { text: pending.command })
      ]));
      if (pending.body) body.appendChild(el('p.dock__question', { text: pending.body }));
    } else {
      if (pending.body) body.appendChild(el('p.dock__question', { text: pending.body }));
    }

    if (pending.kind === 'plan' && pending.steps) {
      var plan = el('ol.plan');
      pending.steps.slice(0, 8).forEach(function (step, i) {
        plan.appendChild(el('li', null, [
          el('span.plan__n', { text: String(i + 1) }),
          el('span', { text: step })
        ]));
      });
      body.appendChild(plan);
    }

    /* Options — radio group, whole row is a label, 48 high each. */
    if (pending.options && pending.options.length) {
      var group = el('div.dock__opts', {
        role: 'radiogroup',
        'aria-label': pending.title
      });
      pending.options.forEach(function (opt) {
        var input = el('input', {
          type: 'radio',
          name: 'pending_' + pending.id,
          value: opt.id,
          disabled: submitting,
          checked: answer.choice === opt.id
        });
        input.addEventListener('change', function () {
          Store.actions.setAnswer(pending.id, { choice: opt.id });
          renderDock(task);
        });
        group.appendChild(el('label.opt' + (submitting ? '.opt--disabled' : ''), null, [
          input,
          el('span.opt__mark', null, [icon('check', 'i--xs')]),
          el('span.opt__text', { text: opt.label })
        ]));
      });
      body.appendChild(group);
    }

    /* Free text for questions that allow it. */
    if (pending.kind === 'question' && pending.allowFreeText) {
      var ta = el('textarea.composer__input', {
        rows: '1',
        placeholder: '补充说明（可选）',
        'aria-label': '补充说明',
        disabled: submitting,
        style: {
          border: '1px solid var(--c-border-subtle)',
          borderRadius: 'var(--r-md)',
          background: 'var(--c-bg-card)',
          minHeight: '44px',
          padding: '10px 12px',
          width: '100%',
          maxHeight: '120px',
          resize: 'none'
        }
      });
      ta.value = answer.freeText || '';
      ta.addEventListener('input', function () {
        Store.actions.setAnswer(pending.id, { freeText: ta.value });
        autosize(ta);
      });
      body.appendChild(ta);
    }

    if (pending.expired) {
      body.appendChild(el('p.dock__hint.dock__hint--warn', { text: '这个问题已超时，但仍可回答' }));
    }
    if (!Store.state.online) {
      body.appendChild(el('p.dock__hint.dock__hint--warn', { text: '连接已断开，回答会在重连后提交' }));
    }

    dock.appendChild(body);

    /* Actions. */
    var canSubmit = !!answer.choice || (answer.freeText && answer.freeText.trim());
    var isApproval = pending.kind === 'approval';

    var actions = el('div.dock__actions' + (isApproval ? '.dock__actions--stack' : ''));
    if (isApproval) {
      // 3 stacked 48-high buttons: allow on top (thumb zone), deny last.
      // Offline: approvals cannot be queued (they are security decisions), so
      // they are disabled with an explicit reason instead of failing silently.
      (pending.options || []).forEach(function (opt) {
        var isPrimary = opt.id === 'allow_once';
        var offlineBlocked = !Store.state.online;
        actions.appendChild(UI.button(
          offlineBlocked ? opt.label + '（需重连）' : opt.label,
          {
            variant: isPrimary ? 'primary' : 'secondary',
            loading: submitting,
            disabled: submitting || pending.expired || offlineBlocked,
            disabledReason: offlineBlocked ? '连接断开时不能审批，请先恢复连接' : null,
            onClick: function () { submitPending(task, pending, opt.id, opt.label); }
          }
        ));
      });
      if (!Store.state.online) {
        body.appendChild(el('p.dock__hint.dock__hint--warn', {
          text: '审批需要实时连接，恢复后按钮才可用'
        }));
      }
    } else {
      actions.appendChild(UI.button('跳过', {
        variant: 'secondary',
        disabled: submitting,
        onClick: function () { Store.toast('已跳过，任务会继续等待'); }
      }));
      actions.appendChild(UI.button(
        submitting ? '提交中' : (!Store.state.online ? '排队提交' : '提交'),
        {
          variant: 'primary',
          loading: submitting,
          disabled: submitting || (!canSubmit && !pending.expired),
          onClick: function () {
            if (!canSubmit) return;
            var chosen = (pending.options || []).filter(function (o) { return o.id === answer.choice; })[0];
            submitPending(task, pending, answer.choice, chosen ? chosen.label : answer.freeText);
          }
        }
      ));
      if (!canSubmit) {
        body.appendChild(el('p.dock__hint', { text: '请选择一个选项' }));
      }
    }
    dock.appendChild(actions);

    refs.dockLayer.appendChild(dock);
    refs.dock = dock;
    positionJumpButton();
  }

  function autosize(node) {
    node.style.height = 'auto';
    node.style.height = Math.min(120, node.scrollHeight) + 'px';
  }

  function submitPending(task, pending, choiceId, label) {
    var answer = Store.getAnswer(pending.id);
    var summary = label + (answer.freeText && pending.kind === 'question' ? '：' + answer.freeText : '');

    Store.actions.setSubmitting(pending.id, true);
    renderDock(task);

    setTimeout(function () {
      Store.actions.setSubmitting(pending.id, false);
      Store.actions.resolvePending(task.id, pending.id, summary);
      Store.toast('已提交：' + label);

      // Dock collapses with a fade once the stack is empty (§6.3).
      if (!task.pending.length) {
        if (refs.dock) {
          refs.dock.classList.add('dock--leaving');
          setTimeout(function () {
            refreshStructure();
            // Focus lands at the transcript end so screen readers continue there.
            if (refs.transcript) refs.transcript.focus({ preventScroll: true });
            Store.toast('已全部处理');
          }, U.prefersReducedMotion() ? 0 : 180);
        } else {
          refreshStructure();
        }
      } else {
        refreshStructure();
      }
    }, 520);
  }

  function syncDock() {
    var task = Store.getTask(taskId);
    if (task) { renderDock(task); positionJumpButton(); }
  }

  /* ── Composer (§5.4.1) ────────────────────────────────────────────────── */
  function buildComposer(task) {
    var running = task.state === 'running' || task.state === 'needs_input';
    var draft = Store.state.ui.draft[task.id] || '';

    var ta = el('textarea.composer__input', {
      rows: '1',
      placeholder: running ? '插话、补充要求…' : '继续这个任务…',
      'aria-label': '输入消息',
      enterkeyhint: 'send'
    });
    ta.value = draft;
    ta.addEventListener('input', function () {
      Store.actions.setDraft(task.id, ta.value);
      autosize(ta);
      sendBtn.disabled = !ta.value.trim();
      sendBtn.classList.toggle('composer__send--stop', false);
      updateSendVisual();
    });
    ta.addEventListener('keydown', function (e) {
      // IME composition must never be interrupted (§10.5).
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        handleSend();
      }
    });
    requestAnimationFrame(function () { autosize(ta); });

    var sendBtn = el('button.composer__send', {
      type: 'button',
      'aria-label': running ? '停止运行' : '发送',
      disabled: running ? false : !draft.trim()
    }, [icon(running ? 'stop' : 'send', 'i--sm')]);

    function updateSendVisual() {
      if (!running) return;
      var hasText = ta.value.trim().length > 0;
      sendBtn.classList.toggle('composer__send--stop', !hasText);
      sendBtn.setAttribute('aria-label', hasText ? '发送' : '停止运行');
      sendBtn.innerHTML = '';
      sendBtn.appendChild(icon(hasText ? 'send' : 'stop', 'i--sm'));
    }

    function handleSend() {
      var text = ta.value.trim();
      if (running && !text) {
        // Empty input + running task = stop button.
        Store.actions.stopTask(task.id);
        refreshStructure();
        return;
      }
      if (!text) return;
      Store.actions.sendMessage(task.id, text);
      ta.value = '';
      autosize(ta);
      updateSendVisual();
      sendBtn.disabled = !running;
      // Sending means "take me to the newest content".
      Store.actions.setFollow(task.id, true);
      refreshStructure();
      requestAnimationFrame(function () { U.scrollToBottom(refs.scroll, true); });
    }

    sendBtn.addEventListener('click', handleSend);

    var tools = el('div.composer__tools', null, [
      UI.iconBtn('plus', '添加附件', {
        cls: 'composer__tool',
        onClick: function () { openAttachSheet(task); }
      }),
      UI.iconBtn('at', '引用文件或工作区', {
        cls: 'composer__tool',
        onClick: function () {
          ta.value += '@';
          ta.focus();
          Store.actions.setDraft(task.id, ta.value);
        }
      }),
      UI.iconBtn('mic', '语音输入', {
        cls: 'composer__tool',
        onClick: function () {
          UI.openSheet({
            title: '语音输入',
            items: [
              { type: 'note', text: '原型不采集真实音频。真实实现里语音会先转成文字，再放进输入框让你确认后发送。' },
              {
                icon: 'mic',
                label: '模拟一段语音转写',
                onClick: function () {
                  ta.value = '把刚才失败的 2 个快照用例也一起更新掉。';
                  Store.actions.setDraft(task.id, ta.value);
                  autosize(ta);
                  sendBtn.disabled = false;
                  ta.focus();
                }
              }
            ]
          });
        }
      })
    ]);

    var attachments = Store.state.ui.attached[task.id] || [];
    var attachRow = attachments.length ? el('div.composer__attach', null, attachments.map(function (file, index) {
      return el('span.attach-chip', null, [
        icon(file.kind === 'image' ? 'image' : 'file', 'i--xs'),
        el('span', { text: file.name }),
        el('button', {
          type: 'button',
          'aria-label': '移除附件 ' + file.name,
          onclick: function () {
            Store.actions.removeAttachment(task.id, index);
            refreshStructure();
          }
        }, [icon('x', 'i--xs')])
      ]);
    })) : null;

    var composer = el('div.composer', null, [
      el('div.composer__field', null, [ta, tools]),
      sendBtn,
      attachRow
    ]);

    if (attachRow) composer.classList.add('composer--attached');
    return composer;
  }

  function openAttachSheet(task) {
    UI.openSheet({
      title: '添加附件',
      items: [
        {
          icon: 'image',
          label: '拍照',
          sub: '拍下屏幕或白板，作为图片发送',
          onClick: function () {
            Store.actions.attachFile(task.id, { name: 'IMG_2043.jpg', kind: 'image' });
            refreshStructure();
            Store.toast('已添加图片');
          }
        },
        {
          icon: 'file',
          label: '选择文件',
          sub: '代码、日志、截图都可以',
          onClick: function () {
            Store.actions.attachFile(task.id, { name: 'error.log', kind: 'file' });
            refreshStructure();
            Store.toast('已添加文件');
          }
        }
      ]
    });
  }

  /* ── Structural refresh: rebuild everything but keep scroll + follow ──── */
  function refreshStructure() {
    if (!root || !alive) return;
    var task = Store.getTask(taskId);
    if (!task) return;
    var scrollTop = refs.scroll ? refs.scroll.scrollTop : 0;
    var wasFollowing = Store.state.ui.follow[taskId];

    render();
    refs.scroll.scrollTop = scrollTop;
    if (wasFollowing) U.scrollToBottom(refs.scroll, false);
  }

  /* ── Live updates from the simulator ──────────────────────────────────── */
  function onStep() {
    if (!root || !alive) return;
    var task = Store.getTask(taskId);
    if (!task) return;

    // The strip is ALWAYS live, even when transcript follow is paused.
    updateStrip(task);

    // Append just the new transcript tail if a message came with the step.
    var last = task.transcript[task.transcript.length - 1];
    if (refs.transcript && last) {
      var rendered = refs.transcript.querySelectorAll('.tblock').length;
      var messageCount = task.transcript.filter(function (b) { return b.role !== 'tool'; }).length;
      if (messageCount > rendered) {
        refs.transcript.appendChild(transcriptBlock(last, task.transcript.length - 1));
      }
    }

    if (Store.state.ui.follow[taskId]) {
      U.scrollToBottom(refs.scroll, true);
    } else {
      refs.newSteps++;
      positionJumpButton();
    }
  }

  function onPending() {
    if (!root || !alive) return;
    var task = Store.getTask(taskId);
    if (!task) return;
    // New blocking question: make sure the dock is visible and expanded, but
    // never steal focus from the composer (§6.8 focus protection).
    if (task.pending.length) {
      var active = document.activeElement;
      var inComposer = active && refs.composer && refs.composer.contains(active);
      if (!inComposer) Store.state.ui.dockOpen[task.id] = true;
    }
    renderDock(task);
    if (refs.statusPill) {
      refs.statusPill.replaceWith(refs.statusPill = UI.statusPill(task.state, { live: true }));
    }
  }

  function onComplete() {
    if (!root || !alive) return;
    var task = Store.getTask(taskId);
    if (!task) return;
    Store.state.ui.follow[taskId] = false;
    refreshStructure();
    Store.actions.setFollow(taskId, true);
    requestAnimationFrame(function () { U.scrollToBottom(refs.scroll, true); });
  }

  global.TaskScreen = {
    mount: mount,
    unmount: unmount,
    onStep: onStep,
    onPending: onPending,
    onComplete: onComplete,
    refresh: refreshStructure
  };
})(window);
