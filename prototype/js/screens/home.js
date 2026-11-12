/* ============================================================================
   screens/home.js — 任务 Home (UI spec §5.1)
   ----------------------------------------------------------------------------
   Supervision inbox, in this order and no other:
     1. 需要你   — approvals/questions pinned top (blocks the desktop agent)
     2. 进行中   — running tasks, live elapsed + progress
     3. 最近完成 — finished since last visit, then older history

   First-screen budget (§5.1.4): 2 cards + 2 rows must fit above the tab bar at
   375×812. Nothing else is allowed above 最近完成.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;
  var root = null;
  var timer = null;

  function mount(node) {
    root = node;
    render();
    Store.on('change', function (evt) {
      // Cheap targeted re-render: Home only cares about task/inbox/connection.
      if (/^(task:|pending:|ui:|connection|sync|nav|visit|theme|sessions)/.test(evt.type)) {
        scheduleRender();
      }
    });
    // Elapsed clocks tick locally once a second; they do not hit the network.
    timer = setInterval(tickClocks, 1000);
  }

  // Guarded: a scheduled repaint must never run against a detached root.
  var scheduleRender = U.schedule(function () { if (root) render(); });

  /** Update only the elapsed labels — avoids tearing down the list each second. */
  function tickClocks() {
    if (!root || !root.offsetParent) return;
    // Offline freezes every clock — see UI spec §8.3. A timer that keeps
    // running would imply the PC is still working, which we cannot know.
    if (!Store.state.online) return;
    var now = Date.now();
    U.qsa('[data-elapsed]', root).forEach(function (node) {
      var task = Store.getTask(node.dataset.elapsed);
      if (!task) return;
      if (task.state === 'running' || task.state === 'needs_input') {
        node.textContent = U.fmtElapsed(now - task.startedAt);
      }
    });
  }

  function render() {
    if (!root) return;
    var scrollTop = root.querySelector('.scroll') ? root.querySelector('.scroll').scrollTop : 0;
    U.clear(root);

    var needs = Store.needsYou();
    var running = Store.runningTasks();
    var fresh = Store.finishedSinceVisit();
    var done = Store.completedTasks();

    /* ── Header: device chip (left) + bell + theme toggle (right) ────────── */
    var unread = Store.unreadInboxCount();
    var header = UI.header({
      title: '任务',
      titleId: 'home-h1',
      actions: [
        UI.iconBtn('bell', '通知中心', {
          badge: unread,
          onClick: function () { Store.actions.push('inbox'); }
        }),
        UI.themeToggle()
      ]
    });
    // Replace the plain title with the device chip (spec §5.1.1) but keep an h1
    // for screen readers so every screen still has exactly one.
    header.insertBefore(UI.deviceChip(), header.querySelector('h1'));
    header.querySelector('h1').classList.add('sr-only');

    root.appendChild(header);

    var banner = UI.offlineBanner();
    if (banner) root.appendChild(banner);

    var scroll = el('div.scroll.scroll--tabs');
    var page = el('div.page');
    scroll.appendChild(page);

    /* ── 1. 需要你 ──────────────────────────────────────────────────────── */
    page.appendChild(UI.sectionHead('需要你', {
      count: needs.length,
      action: needs.length ? el('button.btn.btn--text', {
        type: 'button',
        text: '全部处理',
        onclick: function () {
          Store.actions.push('task', needs[0].id);
        }
      }) : null
    }));

    if (!needs.length) {
      page.appendChild(el('div.home-banner', null, [
        icon('check', 'i--sm'),
        el('span', { text: '没有等你处理的事，电脑上的任务会自己跑。' })
      ]));
    } else {
      needs.slice(0, 3).forEach(function (task) {
        page.appendChild(needsCard(task));
      });
    }

    /* ── 2. 进行中 ──────────────────────────────────────────────────────── */
    var runningOnly = running.filter(function (t) { return t.state === 'running'; });
    var blockedOrFailed = running.filter(function (t) { return t.state === 'failed'; });

    page.appendChild(UI.sectionHead('进行中', { count: runningOnly.length }));
    if (!runningOnly.length) {
      page.appendChild(el('p.caption', { text: '当前没有正在运行的任务。', style: { margin: '0 0 4px' } }));
    } else {
      runningOnly.slice(0, 4).forEach(function (task) {
        page.appendChild(runningRow(task));
      });
    }

    if (blockedOrFailed.length) {
      blockedOrFailed.forEach(function (task) { page.appendChild(runningRow(task)); });
    }

    /* ── 3. 最近完成 ────────────────────────────────────────────────────── */
    var historyTitle = fresh.length ? '最近完成' : '已完成';
    page.appendChild(UI.sectionHead(historyTitle, {
      count: done.length,
      action: fresh.length ? el('button.btn.btn--text', {
        type: 'button',
        text: '标记为已看',
        onclick: function () {
          Store.actions.markVisit();
          Store.toast('已更新"最近完成"水位线');
        }
      }) : null
    }));

    if (!done.length) {
      page.appendChild(UI.emptyState({
        icon: 'list',
        title: '电脑上还没有任务',
        text: '在电脑上开一个任务，或在这里新建一个。',
        action: UI.button('新建任务', {
          variant: 'primary',
          icon: 'plus',
          onClick: function () { openNewTaskSheet(); }
        })
      }));
    } else {
      var shown = done.slice(0, 5);
      shown.forEach(function (task) {
        page.appendChild(doneRow(task, fresh.indexOf(task) >= 0));
      });
      if (done.length > shown.length) {
        page.appendChild(el('p.caption', {
          text: '还有 ' + (done.length - shown.length) + ' 个更早的任务，在「会话」里按工作区找。',
          style: { margin: '0 0 8px' }
        }));
      }
    }

    root.appendChild(scroll);
    scroll.scrollTop = scrollTop;

    // Mark scroll state so the sticky header can grow a border (§2.5).
    scroll.addEventListener('scroll', function () {
      header.classList.toggle('header--scrolled', scroll.scrollTop > 2);
    }, { passive: true });
  }

  /* ── C13 TaskCard: a task that blocks on you ──────────────────────────── */
  function needsCard(task) {
    var pending = task.pending[0];
    var isApproval = pending.kind === 'approval';
    var isPlan = pending.kind === 'plan';
    var reasonLabel = isApproval ? '等待审批' : isPlan ? '计划待批准' : '等待回答';
    var countLabel = task.pending.length > 1 ? ' · 1/' + task.pending.length : '';

    // The card is a plain container with one absolutely-positioned overlay
    // button: nesting <button> inside role="button" is invalid ARIA and makes
    // screen readers announce the same action twice.
    var card = el('div.task-card.has-hit' + (isApproval ? '.task-card--danger' : ''), null, [
      el('button.hit', {
        type: 'button',
        'aria-label': reasonLabel + '：' + pending.title + '。打开任务详情',
        onclick: function () { Store.actions.push('task', task.id); }
      }),
      el('div.task-card__top', null, [
        UI.chip(reasonLabel + countLabel, { cls: 'warn', icon: isApproval ? 'shield' : 'alert' }),
        el('span.task-card__ctx', null, [
          el('span', { text: task.workspace }),
          el('span', { text: '·' }),
          el('span', { text: task.model })
        ])
      ]),
      el('h3.task-card__title', { text: pending.title }),
      el('div.task-card__actions', null, isApproval ? [
        UI.button('拒绝', {
          variant: 'secondary',
          onClick: function (e) {
            e.stopPropagation();
            quickResolve(task, pending, '拒绝');
          }
        }),
        UI.button('允许', {
          variant: 'primary',
          onClick: function (e) {
            e.stopPropagation();
            quickResolve(task, pending, '允许一次');
          }
        })
      ] : [
        UI.button('稍后', {
          variant: 'secondary',
          onClick: function (e) { e.stopPropagation(); Store.toast('已稍后处理，任务会继续等待'); }
        }),
        UI.button('现在回答', {
          variant: 'primary',
          onClick: function (e) {
            e.stopPropagation();
            Store.actions.push('task', task.id);
            // Opening the dock expanded is the whole point: no scrolling needed.
            Store.state.ui.dockOpen[task.id] = true;
          }
        })
      ])
    ]);
    return card;
  }

  function quickResolve(task, pending, answerLabel) {
    Store.actions.resolvePending(task.id, pending.id, answerLabel);
    Store.toast('已提交：' + answerLabel);
  }

  /* ── C14 TaskRow: a running task with live elapsed + progress ─────────── */
  function runningRow(task) {
    var isFailed = task.state === 'failed';
    var isWaiting = task.state === 'needs_input';
    var current = task.steps.filter(function (s) { return s.status === 'run'; })[0];
    var stepCount = task.steps.length;

    var row = el('div.task-row.has-hit' + (isFailed ? '.task-row--failed' : ''), null, [
      el('button.hit', {
        type: 'button',
        'aria-label': task.title + '，' + (isFailed ? '失败' : isWaiting ? '等待输入' : '运行中') +
          '，已用 ' + U.fmtElapsed(Date.now() - task.startedAt) +
          (current ? '，当前步骤 ' + current.name + ' ' + current.arg : ''),
        onclick: function () { Store.actions.push('task', task.id); }
      }),
      el('div.task-row__line', null, [
        el('span.task-row__title', { text: task.title, title: task.title }),
        isWaiting
          ? el('span.task-row__elapsed.task-row__elapsed--warn', { text: '等待输入' })
          : isFailed
            ? el('span.task-row__elapsed', { text: '已失败' })
            : el('span.task-row__elapsed', {
                text: U.fmtElapsed(Date.now() - task.startedAt),
                dataset: { elapsed: task.id }
              })
      ]),
      el('div.task-row__meta', null, [
        el('span', { text: task.workspace }),
        el('span.sep', { text: '·' }),
        el('span', { text: task.model }),
        el('span.sep', { text: '·' }),
        el('span', { text: stepCount + ' 步' })
      ]),
      // The live "what is the PC doing right now" line — the whole point of Home.
      current && !isFailed ? el('div.task-row__now', null, [
        el('span', { className: 'dot dot--accent' + (Store.state.online ? ' dot--pulse' : '') }),
        el('span.mono', { text: current.name + ' ' + current.arg })
      ]) : null,
      isFailed
        ? el('p.caption', { text: task.error || '任务失败', style: { margin: '0', color: 'var(--c-danger)' } })
        : UI.progressBar({
            // A10: no percentage is available, so the bar is a fixed 40% fill
            // and the accessible value is textual. Waiting tasks say so.
            valueText: isWaiting
              ? '等待输入，已 ' + stepCount + ' 步'
              : '进行中，已 ' + stepCount + ' 步'
          })
    ]);
    return row;
  }

  /* ── Finished row ─────────────────────────────────────────────────────── */
  function doneRow(task, isFresh) {
    return el('div.done-row.has-hit' + (isFresh ? '.done-row--fresh' : ''), null, [
      el('button.hit', {
        type: 'button',
        'aria-label': task.title + '，已完成 ' + U.fmtRelative(task.completedAt) + '。打开任务详情',
        onclick: function () { Store.actions.push('task', task.id); }
      }),
      el('div.done-row__icon', null, [icon('check', 'i--sm')]),
      el('div.done-row__main', null, [
        el('div.done-row__title', { text: task.title }),
        el('div.done-row__meta', null, [
          el('span', { text: U.fmtRelative(task.completedAt) }),
          el('span', { text: '·' }),
          el('span', { text: task.workspace })
        ])
      ]),
      isFresh ? el('span.done-row__new', { text: '新' }) : null
    ]);
  }

  /* ── New task sheet (center FAB target) ───────────────────────────────── */
  function openNewTaskSheet() {
    UI.openSheet({
      title: '新建任务',
      items: [
        { icon: 'list', label: '用文字描述任务', sub: '在电脑当前工作区开一个新会话', onClick: function () { startNewTask('text'); } },
        { icon: 'mic', label: '语音输入', sub: '按住说话，松开后转成文字', onClick: function () { startNewTask('voice'); } },
        { icon: 'image', label: '拍照或选文件', sub: '作为任务附件发送到电脑', onClick: function () { startNewTask('image'); } },
        { icon: 'monitor', label: '接着电脑上的会话继续', sub: '接管电脑上已经打开的任务', onClick: function () { Store.actions.setTab('sessions'); } }
      ]
    });
  }

  function startNewTask(kind) {
    var id = 't_new_' + Date.now().toString(36);
    var draftLabel = kind === 'voice' ? '（语音）' : kind === 'image' ? '（图片）' : '';
    Store.state.tasks.push({
      id: id,
      sessionId: 'ses_' + Math.random().toString(36).slice(2, 8),
      title: '新任务' + (draftLabel ? ' ' + draftLabel : ''),
      workspace: 'dsh-web',
      model: 'Opus 4.5',
      state: 'running',
      turn: 1,
      startedAt: Date.now(),
      lastEventAt: Date.now(),
      completedAt: null,
      latencyMs: Store.state.latencyMs,
      steps: [],
      pending: [],
      transcript: []
    });
    Store.emit('task:new', { taskId: id });
    Store.actions.push('task', id);
    setTimeout(function () {
      var input = document.querySelector('.composer__input');
      if (input) input.focus();
    }, 320);
  }

  global.HomeScreen = {
    mount: mount,
    render: render,
    openNewTaskSheet: openNewTaskSheet
  };
})(window);
