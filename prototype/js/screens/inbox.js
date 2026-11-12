/* ============================================================================
   screens/inbox.js — 通知中心 Inbox (UI spec §5.5)
   ----------------------------------------------------------------------------
   Six evidenced notification categories (问题/计划/审批/回复/目标/失败) plus
   全部. The list shows session titles only — never question bodies — matching
   the lock-screen redaction policy. Tapping deep-links into the task and opens
   the corresponding dock; it NEVER answers or approves on the user's behalf.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;
  var root = null;
  var filter = 'all';
  var alive = false;

  var KINDS = {
    question: { label: '问题', icon: 'alert' },
    plan: { label: '计划', icon: 'list' },
    approval: { label: '审批', icon: 'shield' },
    reply: { label: '回复', icon: 'terminal' },
    goal: { label: '目标', icon: 'check' },
    failed: { label: '失败', icon: 'x' },
    done: { label: '完成', icon: 'check' }
  };

  function mount(node) {
    root = node;
    alive = true;
    render();
    var off = Store.on('change', function (evt) {
      if (/^(inbox|nav|connection|theme|task:|pending:)/.test(evt.type)) scheduleRender();
    });
    return function dispose() { alive = false; off(); };
  }

  var scheduleRender = U.schedule(function () { if (alive) render(); });

  function render() {
    if (!root) return;
    var scrollTop = root.querySelector('.scroll') ? root.querySelector('.scroll').scrollTop : 0;
    U.clear(root);

    var unread = Store.unreadInboxCount();

    root.appendChild(UI.header({
      lead: UI.backButton(),
      title: '通知',
      smallTitle: true,
      titleId: 'inbox-h1',
      actions: [
        UI.button('全部已读', {
          variant: 'text',
          disabled: unread === 0,
          onClick: function () { Store.actions.markAllInboxRead(); }
        })
      ]
    }));

    var banner = UI.offlineBanner();
    if (banner) root.appendChild(banner);

    /* Filter chips: 全部 + the six evidenced categories. */
    var counts = { all: Store.state.inbox.length };
    Object.keys(KINDS).forEach(function (k) {
      counts[k] = Store.state.inbox.filter(function (n) { return n.kind === k; }).length;
    });
    var chipItems = [{ id: 'all', label: '全部', count: counts.all }].concat(
      ['question', 'plan', 'approval', 'reply', 'goal', 'failed'].map(function (k) {
        return { id: k, label: KINDS[k].label, count: counts[k] || null };
      })
    );
    root.appendChild(UI.filterChips(chipItems, filter, function (id) {
      filter = id;
      scheduleRender();
    }, { label: '通知筛选' }));

    var scroll = el('div.scroll.scroll--tabs');
    var items = Store.state.inbox.filter(function (n) {
      return filter === 'all' || n.kind === filter;
    });

    if (!items.length) {
      scroll.appendChild(UI.emptyState({
        icon: 'bell',
        title: '暂无通知',
        text: '任务完成、等待输入或需要审批时会出现在这里。'
      }));
      root.appendChild(scroll);
      return;
    }

    /* Grouped by 今天 / 昨天 / earlier. */
    var groups = groupByDay(items);
    groups.forEach(function (group) {
      scroll.appendChild(UI.groupHeader(group.label, { count: group.items.length }));
      var box = el('div.inbox-group', { style: { margin: '0 16px 12px' } });
      group.items.forEach(function (item) { box.appendChild(inboxRow(item)); });
      scroll.appendChild(box);
    });

    root.appendChild(scroll);
    scroll.scrollTop = scrollTop;
  }

  function groupByDay(items) {
    var now = new Date();
    var todayKey = now.toDateString();
    var yesterday = new Date(now.getTime() - 86400000).toDateString();
    var buckets = [];
    var map = {};

    items.forEach(function (item) {
      var d = new Date(item.at).toDateString();
      var label = d === todayKey ? '今天' : d === yesterday ? '昨天' : '更早';
      if (!map[label]) { map[label] = { label: label, items: [] }; buckets.push(map[label]); }
      map[label].items.push(item);
    });
    return buckets;
  }

  function inboxRow(item) {
    var kind = KINDS[item.kind] || KINDS.reply;
    var meta = U.fmtClock(item.at) + ' · ' + item.workspace;

    return el('button.inbox-row', {
      type: 'button',
      'aria-label': kind.label + '，' + item.title + '，' + meta + (item.read ? '' : '，未读'),
      onclick: function () {
        Store.actions.markInboxRead(item.id);
        if (item.taskId) {
          Store.actions.push('task', item.taskId, { openDock: !!item.pendingId });
          // The dock opens to the specific pending item.
          if (item.pendingId) {
            var task = Store.getTask(item.taskId);
            if (task) {
              var idx = task.pending.findIndex(function (p) { return p.id === item.pendingId; });
              if (idx >= 0) Store.state.ui.dockIndex[item.taskId] = idx;
            }
          }
        } else {
          Store.toast('这条通知对应的会话还没有任务投影');
        }
      }
    }, [
      el('span', { className: 'inbox-row__icon inbox-row__icon--' + (item.kind === 'done' ? 'done' : item.kind) },
        [icon(kind.icon, 'i--sm')]),
      el('span.inbox-row__main', null, [
        el('span.inbox-row__title', { text: item.title }),
        el('span.inbox-row__meta', null, [
          el('span', { text: meta })
        ])
      ]),
      el('span.inbox-row__tail', null, [
        item.read ? null : el('span.unread-dot', { 'aria-hidden': 'true' })
      ])
    ]);
  }

  global.InboxScreen = { mount: mount, render: render };
})(window);
