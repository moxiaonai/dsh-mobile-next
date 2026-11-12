/* ============================================================================
   screens/sessions.js — 会话 Sessions (UI spec §5.2)
   ----------------------------------------------------------------------------
   Grouped by workspace (ASSUMPTION A3), searchable, with swipe actions
   (pin / mute / archive) AND a mandatory "…" menu that exposes exactly the same
   actions — swipe is an accelerator, never the only entry point.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;
  var root = null;
  var query = '';
  var filter = 'all';           // all | unread | failed
  var openRowId = null;         // only one row may be swiped open at a time

  function mount(node) {
    root = node;
    render();
    Store.on('change', function (evt) {
      if (/^(sessions|task:|nav|connection|theme|pending:)/.test(evt.type)) scheduleRender();
    });
  }

  // Guarded: a scheduled repaint must never run against a detached root.
  var scheduleRender = U.schedule(function () { if (root) render(); });

  function matches(session) {
    if (filter === 'unread' && !session.unread) return false;
    if (filter === 'failed' && !session.failed) return false;
    if (!query) return true;
    var q = query.toLowerCase();
    return session.title.toLowerCase().indexOf(q) >= 0 ||
      session.workspace.toLowerCase().indexOf(q) >= 0 ||
      (session.model || '').toLowerCase().indexOf(q) >= 0;
  }

  function render() {
    if (!root) return;
    var scrollTop = root.querySelector('.scroll') ? root.querySelector('.scroll').scrollTop : 0;
    U.clear(root);

    var unreadCount = Store.state.sessions.filter(function (s) { return s.unread; }).length;
    var failedCount = Store.state.sessions.filter(function (s) { return s.failed; }).length;

    root.appendChild(UI.header({
      title: '会话',
      titleId: 'sessions-h1',
      actions: [
        UI.iconBtn('bell', '通知中心', {
          badge: Store.unreadInboxCount(),
          onClick: function () { Store.actions.push('inbox'); }
        }),
        UI.themeToggle()
      ]
    }));

    var banner = UI.offlineBanner();
    if (banner) root.appendChild(banner);

    // Search + filter chips stay above the scroll region so they are always
    // reachable, and so the sticky group headers can pin under them (§10).
    var tools = el('div', { style: { flex: 'none', display: 'grid', gap: '4px', paddingTop: '4px' } });
    var search = UI.searchField({
      placeholder: '搜索会话、工作区、消息…',
      value: query,
      onInput: function (v) { query = v; scheduleRender(); }
    });
    tools.appendChild(el('div', {
      style: { padding: '0 max(var(--s-8), var(--sa-left)) max(var(--s-2), 0)' }
    }, [search]));

    tools.appendChild(UI.filterChips([
      { id: 'all', label: '全部', count: Store.state.sessions.length },
      { id: 'unread', label: '未读', count: unreadCount },
      { id: 'failed', label: '失败', count: failedCount }
    ], filter, function (id) { filter = id; scheduleRender(); }, { label: '会话筛选' }));
    root.appendChild(tools);

    var scroll = el('div.scroll.scroll--tabs');
    var visible = Store.state.sessions.filter(matches);

    if (!visible.length) {
      scroll.appendChild(UI.emptyState({
        icon: 'search',
        title: query ? '没有匹配的会话' : '还没有会话',
        text: query ? '试试工作区名或消息里的关键词。' : '新建任务后，会话会出现在这里。',
        action: query
          ? UI.button('清除筛选', {
              variant: 'secondary',
              onClick: function () { query = ''; filter = 'all'; scheduleRender(); }
            })
          : UI.button('新建任务', { variant: 'primary', icon: 'plus', onClick: HomeScreen.openNewTaskSheet })
      }));
      root.appendChild(scroll);
      return;
    }

    // 已置顶 is its own group (§5.2), then one group per workspace.
    var pinned = visible.filter(function (s) { return s.pinned; });
    if (pinned.length) {
      scroll.appendChild(UI.groupHeader('已置顶', { icon: 'pin', count: pinned.length }));
      pinned.forEach(function (s) { scroll.appendChild(sessionRow(s)); });
    }

    var groups = {};
    visible.filter(function (s) { return !s.pinned; }).forEach(function (s) {
      (groups[s.workspace] || (groups[s.workspace] = [])).push(s);
    });
    Object.keys(groups).sort().forEach(function (ws) {
      var list = groups[ws].sort(function (a, b) { return b.updatedAt - a.updatedAt; });
      scroll.appendChild(UI.groupHeader(ws, { count: list.length }));
      list.forEach(function (s) { scroll.appendChild(sessionRow(s)); });
    });

    root.appendChild(scroll);
    scroll.scrollTop = scrollTop;

    // Any scroll closes the open swipe row (§5.2).
    scroll.addEventListener('scroll', function () {
      if (openRowId) { closeOpenRow(); }
    }, { passive: true });
  }

  function closeOpenRow() {
    if (!openRowId) return;
    var node = root.querySelector('[data-row="' + openRowId + '"]');
    if (node) node.classList.remove('swipe--open');
    openRowId = null;
  }

  /* ── C15 SessionRow with swipe ────────────────────────────────────────── */
  function sessionRow(session) {
    var wrap = el('div.swipe' + (session.failed ? '.swipe--failed' : '') + (session.pinned ? '.swipe--pinned' : ''), {
      dataset: { row: session.id }
    });

    /* Actions layer (revealed by translateX(-216px)). */
    var actions = el('div.swipe__actions', null, [
      el('button.swipe__action', {
        type: 'button',
        'aria-label': (session.pinned ? '取消置顶' : '置顶') + '会话 ' + session.title,
        onclick: function (e) {
          e.stopPropagation();
          Store.actions.togglePin(session.id);
          closeOpenRow();
          Store.toast(session.pinned ? '已取消置顶' : '已置顶');
        }
      }, [icon('pin', 'i--sm'), el('span', { text: session.pinned ? '取消置顶' : '置顶' })]),
      el('button.swipe__action', {
        type: 'button',
        'aria-label': (session.muted ? '取消静音' : '静音') + '会话 ' + session.title,
        onclick: function (e) {
          e.stopPropagation();
          Store.actions.toggleMute(session.id);
          closeOpenRow();
          Store.toast(session.muted ? '已取消静音' : '已静音，通知不再提醒');
        }
      }, [icon('mute', 'i--sm'), el('span', { text: session.muted ? '取消静音' : '静音' })]),
      el('button.swipe__action.swipe__action--danger', {
        type: 'button',
        'aria-label': '归档会话 ' + session.title,
        onclick: function (e) {
          e.stopPropagation();
          archive(session);
        }
      }, [icon('archive', 'i--sm'), el('span', { text: '归档' })])
    ]);
    wrap.appendChild(actions);

    /* Front layer: the row itself. */
    var front = el('div.swipe__front.has-hit', null, [
      el('button.hit', {
        type: 'button',
        'aria-label': session.title + '，' + session.workspace + '，' +
          U.fmtRelative(session.updatedAt) + (session.unread ? '，未读' : '') +
          (session.failed ? '，上次运行失败' : '') + '。打开会话',
        onclick: function () {
          if (openRowId) { closeOpenRow(); return; }
          openSession(session);
        }
      }),
      el('div.swipe__body', null, [
        el('div.swipe__title', null, [
          session.pinned ? icon('pin', 'i--xs pin-mark') : null,
          el('span.swipe__title-text', { text: session.title }),
          session.muted ? icon('mute', 'i--xs mute-mark') : null
        ]),
        el('div.swipe__meta', null, [
          el('span', { text: session.workspace }),
          el('span', { text: '·' }),
          el('span', { text: U.fmtRelative(session.updatedAt) }),
          el('span', { text: '·' }),
          el('span', { text: session.model })
        ])
      ]),
      el('div.swipe__tail', null, [
        session.failed ? icon('alert', 'i--sm') : null,
        session.unread ? el('span.unread-dot') : null,
        el('button.swipe__more', {
          type: 'button',
          'aria-label': '会话操作：' + session.title,
          onclick: function (e) {
            e.stopPropagation();
            openRowSheet(session);
          }
        }, [icon('more', 'i--sm')])
      ])
    ]);

    attachSwipe(front, wrap, session);
    wrap.appendChild(front);
    return wrap;
  }

  /* ── Swipe gesture: horizontal only, vertical scroll wins (§5.2) ──────── */
  function attachSwipe(front, wrap, session) {
    var startX = 0, startY = 0, dx = 0, dragging = false, decided = false, horizontal = false;
    var moved = false;

    front.addEventListener('pointerdown', function (e) {
      if (e.target.closest('.swipe__more')) return;
      startX = e.clientX; startY = e.clientY;
      dx = 0; dragging = true; decided = false; horizontal = false; moved = false;
    });

    front.addEventListener('pointermove', function (e) {
      if (!dragging) return;
      var moveX = e.clientX - startX;
      var moveY = e.clientY - startY;

      if (Math.abs(moveX) > 6 || Math.abs(moveY) > 6) moved = true;
      if (!decided && (Math.abs(moveX) > 6 || Math.abs(moveY) > 6)) {
        decided = true;
        horizontal = Math.abs(moveX) > Math.abs(moveY);
        if (horizontal) {
          if (openRowId && openRowId !== session.id) closeOpenRow();
          front.style.transition = 'none';
        }
      }
      if (!decided || !horizontal) return;

      dx = moveX;
      var base = openRowId === session.id ? -216 : 0;
      var next = U.clamp(base + dx, -216, 0);
      front.style.transform = 'translateX(' + next + 'px)';
    });

    function end() {
      if (!dragging) return;
      dragging = false;
      front.style.transition = '';
      if (!horizontal) { front.style.transform = ''; return; }

      var base = openRowId === session.id ? -216 : 0;
      var next = U.clamp(base + dx, -216, 0);
      if (next < -110) {
        openRowId = session.id;
        wrap.classList.add('swipe--open');
      } else {
        if (openRowId === session.id) openRowId = null;
        wrap.classList.remove('swipe--open');
      }
      front.style.transform = '';
    }

    // A completed horizontal drag must not also activate the row.
    front.addEventListener('click', function (e) {
      if (horizontal && moved) { e.preventDefault(); e.stopPropagation(); }
    }, true);

    front.addEventListener('pointerup', end);
    front.addEventListener('pointercancel', end);
    front.addEventListener('pointerleave', function () { if (dragging) end(); });

    // Long-press → same sheet, so touch users have a non-swipe path too.
    var pressTimer = null;
    front.addEventListener('pointerdown', function () {
      pressTimer = setTimeout(function () {
        openRowSheet(session);
        dragging = false;
        front.style.transform = '';
      }, 550);
    });
    ['pointerup', 'pointermove', 'pointercancel'].forEach(function (t) {
      front.addEventListener(t, function () { clearTimeout(pressTimer); });
    });
  }

  /* ── Shared action sheet (accessible equivalent of swipe) ─────────────── */
  function openRowSheet(session) {
    UI.openSheet({
      title: session.title,
      items: [
        {
          icon: 'pin',
          label: session.pinned ? '取消置顶' : '置顶',
          onClick: function () {
            Store.actions.togglePin(session.id);
            Store.toast(session.pinned ? '已取消置顶' : '已置顶');
          }
        },
        {
          icon: 'mute',
          label: session.muted ? '取消静音' : '静音',
          sub: '静音后该会话完成时不发通知',
          onClick: function () {
            Store.actions.toggleMute(session.id);
            Store.toast(session.muted ? '已取消静音' : '已静音');
          }
        },
        {
          icon: 'monitor',
          label: '在电脑上打开',
          sub: '电脑端会切到这个会话',
          onClick: function () { Store.toast('已在电脑上打开该会话'); }
        },
        {
          icon: 'copy',
          label: '复制会话 ID',
          sub: session.id,
          onClick: function () {
            U.copyText(session.id).then(function () { Store.toast('已复制会话 ID'); });
          }
        },
        {
          icon: 'archive',
          label: '归档',
          danger: true,
          onClick: function () { archive(session); }
        }
      ]
    });
  }

  function archive(session) {
    var removed = Store.actions.archiveSession(session.id);
    closeOpenRow();
    Store.toast('已归档「' + session.title + '」', {
      action: { label: '撤销', onClick: function () { Store.actions.restoreSession(removed); } },
      duration: 5000
    });
  }

  function openSession(session) {
    if (session.unread) Store.actions.markSessionRead(session.id);
    if (session.taskId) {
      Store.actions.push('task', session.taskId);
    } else {
      // No live task projection for this session yet — open it read-only.
      Store.actions.push('task', null, { sessionId: session.id, title: session.title });
    }
  }

  global.SessionsScreen = { mount: mount, render: render };
})(window);
