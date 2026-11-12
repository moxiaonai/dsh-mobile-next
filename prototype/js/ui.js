/* ============================================================================
   ui.js — shared components (UI spec §4.1 component inventory C01–C40).
   ----------------------------------------------------------------------------
   Each factory returns a DOM node and takes plain data. Nothing here reads the
   store directly except where a component is inherently global (toast, sheet),
   so screens stay in control of their own data flow.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;

  /* ── C01 DeviceChip ───────────────────────────────────────────────────── */
  function deviceChip(opts) {
    opts = opts || {};
    var device = Store.currentDevice();
    var name = device ? device.name : '未配对电脑';
    var typeLabel = !device ? '' : device.transport === 'lan' ? '局域网' : '远程';
    var reach = device ? device.reach : null;

    var dotCls = 'dot';
    if (reach === 'reachable') dotCls += '';
    else if (reach === 'checking') dotCls += ' dot--accent dot--pulse';
    else if (!device) dotCls += ' dot--idle';
    else dotCls += ' dot--idle';

    var label = !device
      ? '未配对电脑，去配对'
      : '当前电脑：' + name + '，' + typeLabel + '，' + reachText(device);

    return el('button.device-chip', {
      type: 'button',
      'aria-label': label + '。切换到设备页',
      onclick: function () { Store.actions.setTab('devices'); }
    }, [
      el('span', { className: dotCls }),
      el('span.device-chip__name', { text: name }),
      typeLabel ? el('span.device-chip__type', { text: typeLabel }) : null,
      icon('chevron-down', 'i--sm')
    ]);
  }

  function reachText(device) {
    if (!device) return '未连接';
    if (device.reach === 'reachable') return '可达' + (device.latencyMs ? ' · 延迟约 ' + device.latencyMs + 'ms' : '');
    if (device.reach === 'checking') return '检测中';
    if (device.reach === 'expired') return '配对已过期';
    return '暂不可达';
  }

  /* ── C02 IconButton ───────────────────────────────────────────────────── */
  function iconBtn(name, label, opts) {
    opts = opts || {};
    var btn = el('button.icon-btn' + (opts.cls ? '.' + opts.cls.split(' ').join('.') : ''), {
      type: 'button',
      'aria-label': label,
      onclick: opts.onClick,
      disabled: opts.disabled || false
    }, [icon(name, opts.iconCls)]);
    if (opts.badge) {
      btn.appendChild(el('span.badge-count', { text: opts.badge > 9 ? '9+' : String(opts.badge) }));
      btn.setAttribute('aria-label', label + '，' + opts.badge + ' 条未读');
    }
    return btn;
  }

  /* ── C07 StatusPill ───────────────────────────────────────────────────── */
  var STATUS = {
    running: { label: '运行中', cls: 'pill--running', dot: 'dot--accent dot--pulse' },
    needs_input: { label: '等待你', cls: 'pill--needs', dot: 'dot--warn' },
    completed: { label: '已完成', cls: 'pill--done', dot: '' },
    failed: { label: '失败', cls: 'pill--failed', dot: '' },
    stopped: { label: '已停止', cls: 'pill--idle', dot: 'dot--muted' },
    unknown: { label: '未知', cls: 'pill--idle', dot: 'dot--idle' }
  };

  function statusPill(state, opts) {
    opts = opts || {};
    var meta = STATUS[state] || STATUS.unknown;
    var label = opts.label || meta.label;
    var children = [];
    if (opts.dot !== false) {
      children.push(el('span', { className: 'dot ' + (meta.dot || 'dot--muted'), style: { width: '6px', height: '6px' } }));
    }
    children.push(document.createTextNode(label));
    return el('span.pill ' + meta.cls, {
      role: opts.live ? 'status' : null,
      'aria-live': opts.live ? 'polite' : null
    }, children);
  }

  /* ── C08/C09 Chips ────────────────────────────────────────────────────── */
  function chip(text, opts) {
    opts = opts || {};
    return el('span.chip' + (opts.cls ? '.' + opts.cls.split(' ').join('.') : ''), null, [
      opts.icon ? icon(opts.icon, 'i--xs') : null,
      el('span.chip__text', { text: text })
    ]);
  }

  function metaChip(text, opts) {
    opts = opts || {};
    return el('span.chip', { title: text }, [
      opts.icon ? icon(opts.icon, 'i--xs') : null,
      el('span.chip__text', { text: text })
    ]);
  }

  /* ── C11 FilterChips ──────────────────────────────────────────────────── */
  function filterChips(items, activeId, onSelect, opts) {
    opts = opts || {};
    var row = el('div.chips-row', {
      role: opts.role || 'group',
      'aria-label': opts.label || '筛选'
    });
    items.forEach(function (item) {
      var count = item.count;
      var text = item.label + (count != null ? ' ' + count : '');
      var btn = el('button.chip-btn', {
        type: 'button',
        'aria-pressed': String(item.id === activeId),
        'aria-label': item.label + (count != null ? '，' + count + ' 条' : ''),
        onclick: function () { onSelect(item.id); }
      }, [el('span.chip-btn__pill', { text: text })]);
      row.appendChild(btn);
    });
    return row;
  }

  /* ── C12 SearchField ──────────────────────────────────────────────────── */
  function searchField(opts) {
    opts = opts || {};
    var input = el('input.search__input', {
      type: 'search',
      inputmode: 'search',
      enterkeyhint: 'search',
      placeholder: opts.placeholder || '搜索',
      'aria-label': opts.placeholder || '搜索',
      autocomplete: 'off',
      value: opts.value || ''
    });
    var clearBtn = el('button.icon-btn.search__clear', {
      type: 'button',
      'aria-label': '清除搜索',
      hidden: !opts.value
    }, [icon('x', 'i--sm')]);

    var wrap = el('div.search', null, [icon('search', 'i--sm'), input, clearBtn]);

    input.addEventListener('input', function () {
      clearBtn.hidden = !input.value;
      if (opts.onInput) opts.onInput(input.value);
    });
    clearBtn.addEventListener('click', function () {
      input.value = '';
      clearBtn.hidden = true;
      input.focus();
      if (opts.onInput) opts.onInput('');
    });
    wrap.focusInput = function () { input.focus(); };
    wrap.input = input;
    return wrap;
  }

  /* ── Header (C39 shell piece) ─────────────────────────────────────────── */
  function header(opts) {
    opts = opts || {};
    var node = el('header.header', { role: opts.role || null }, [
      opts.lead || null,
      opts.title ? el('h1.header__title' + (opts.smallTitle ? '.header__title--plain' : ''), { text: opts.title, id: opts.titleId }) : null,
      opts.titleNode || null,
      el('div.header__spacer'),
      el('div.header__actions', null, opts.actions || [])
    ]);
    return node;
  }

  /* Back button used by every push surface (44×44, label 返回). */
  function backButton() {
    return iconBtn('chevron-left', '返回', { onClick: function () { Store.actions.back(); } });
  }

  /* ── C16 GroupHeader ──────────────────────────────────────────────────── */
  function groupHeader(text, opts) {
    opts = opts || {};
    return el('div.group-head', null, [
      opts.icon ? icon(opts.icon, 'i--xs') : null,
      el('span', { text: text }),
      opts.count != null ? el('span.group-head__count', { text: String(opts.count) }) : null,
      opts.action ? el('span.group-head__action', null, opts.action) : null
    ]);
  }

  function sectionHead(title, opts) {
    opts = opts || {};
    return el('div.section-head', null, [
      el('h2', { text: title }),
      opts.count != null ? el('span.group-head__count', { text: String(opts.count) }) : null,
      opts.action ? el('span.section-head__action', null, opts.action) : null
    ]);
  }

  /* ── Buttons ──────────────────────────────────────────────────────────── */
  function button(label, opts) {
    opts = opts || {};
    var cls = 'btn';
    if (opts.variant === 'primary') cls += ' btn--primary';
    else if (opts.variant === 'secondary') cls += ' btn--secondary';
    else if (opts.variant === 'danger') cls += ' btn--danger';
    else if (opts.variant === 'text') cls += ' btn--text';
    if (opts.block) cls += ' btn--block';
    if (opts.loading) cls += ' btn--loading';

    var btn = el('button', {
      type: 'button',
      className: cls,
      disabled: opts.disabled || false,
      'aria-busy': opts.loading ? 'true' : null,
      onclick: opts.onClick
    }, [opts.icon ? icon(opts.icon, 'i--sm') : null, label]);

    if (opts.disabled && opts.disabledReason) btn.title = opts.disabledReason;
    return btn;
  }

  /* ── C19 ProgressBar ──────────────────────────────────────────────────── */
  function progressBar(opts) {
    opts = opts || {};
    var fillCls = 'progress__fill';
    if (opts.variant === 'done') fillCls += ' progress__fill--done';
    if (opts.variant === 'failed') fillCls += ' progress__fill--failed';
    var fill = el('div', { className: fillCls });
    if (opts.percent != null) fill.style.width = opts.percent + '%';
    // A10: no real percentage exists, so the accessible value is textual.
    return el('div.progress', {
      role: 'progressbar',
      'aria-valuetext': opts.valueText || '进行中',
      'aria-valuemin': opts.percent != null ? '0' : null,
      'aria-valuemax': opts.percent != null ? '100' : null,
      'aria-valuenow': opts.percent != null ? String(opts.percent) : null
    }, [fill]);
  }

  /* ── C34 EmptyState ───────────────────────────────────────────────────── */
  function emptyState(opts) {
    opts = opts || {};
    return el('div.empty', null, [
      el('div.empty__icon', null, [icon(opts.icon || 'list', 'i--lg')]),
      el('h2.empty__title', { text: opts.title || '暂无内容' }),
      opts.text ? el('p.empty__text', { text: opts.text }) : null,
      opts.action || null
    ]);
  }

  /* ── C35 ErrorState ───────────────────────────────────────────────────── */
  function errorState(opts) {
    opts = opts || {};
    return el('div.error-state', { role: 'alert' }, [
      el('h3.error-state__title', null, [icon('alert', 'i--sm'), opts.title || '出错了']),
      el('p.error-state__text', { text: opts.text || '' }),
      opts.code ? el('div.error-state__code', { text: opts.code }) : null,
      el('div.error-state__actions', null, opts.actions || [])
    ]);
  }

  /* ── C36 OfflineBanner ────────────────────────────────────────────────── */
  function offlineBanner() {
    var s = Store.state;
    if (s.online && !s.reconnecting) return null;
    var text;
    if (s.reconnecting) text = '重连中（第 2 次）';
    else text = '离线 · 显示 ' + U.fmtClock(s.lastSyncedAt) + ' 的数据';
    return el('div.offline-banner', { role: 'status', 'aria-live': 'polite' }, [
      icon('wifi', 'i--sm'),
      el('span', { text: text })
    ]);
  }

  /* ── C37 Sheet ────────────────────────────────────────────────────────── */
  var sheetState = { open: false, lastFocus: null };

  function openSheet(opts) {
    var layer = document.getElementById('sheet-layer');
    var scrim = document.getElementById('scrim');
    sheetState.lastFocus = document.activeElement;

    U.clear(layer);
    var sheet = el('div.sheet', {
      role: 'dialog',
      'aria-modal': 'true',
      'aria-label': opts.title || '操作'
    }, [
      el('div.sheet__grip'),
      opts.title ? el('h2.sheet__title', { text: opts.title }) : null,
      el('div.sheet__body', null, (opts.items || []).map(function (item) {
        if (item.type === 'note') return el('p.sheet__note', { text: item.text });
        return el('button', {
          className: 'sheet__item' + (item.danger ? ' sheet__item--danger' : ''),
          type: 'button',
          onclick: function () {
            closeSheet();
            if (item.onClick) setTimeout(item.onClick, 0);
          }
        }, [
          item.icon ? icon(item.icon, 'i--sm') : null,
          el('span', { style: { flex: '1 1 auto', minWidth: '0' } }, [
            el('span', { style: { display: 'block' }, text: item.label }),
            item.sub ? el('span.sheet__item-sub', { text: item.sub }) : null
          ])
        ]);
      }).concat([
        el('button.sheet__cancel', {
          type: 'button',
          text: '取消',
          onclick: closeSheet
        })
      ]))
    ]);

    layer.appendChild(sheet);
    layer.hidden = false;
    scrim.hidden = false;
    // Force a frame so the transform transition actually runs.
    requestAnimationFrame(function () {
      sheet.classList.add('sheet--in');
      scrim.classList.add('scrim--in');
    });
    sheetState.open = true;

    var first = sheet.querySelector('button');
    if (first) first.focus();

    function onKey(e) {
      if (e.key === 'Escape') { closeSheet(); }
      if (e.key === 'Tab') trapFocus(e, sheet);
    }
    document.addEventListener('keydown', onKey);
    sheet._onKey = onKey;
    scrim.onclick = closeSheet;
    return sheet;
  }

  function trapFocus(e, container) {
    var focusables = U.qsa('button, [href], input, textarea, [tabindex]:not([tabindex="-1"])', container)
      .filter(function (n) { return !n.disabled && n.offsetParent !== null; });
    if (!focusables.length) return;
    var first = focusables[0], last = focusables[focusables.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  }

  function closeSheet() {
    var layer = document.getElementById('sheet-layer');
    var scrim = document.getElementById('scrim');
    var sheet = layer.querySelector('.sheet');
    if (!sheet) return;
    sheet.classList.remove('sheet--in');
    scrim.classList.remove('scrim--in');
    if (sheet._onKey) document.removeEventListener('keydown', sheet._onKey);
    setTimeout(function () {
      layer.hidden = true;
      scrim.hidden = true;
      U.clear(layer);
      scrim.onclick = null;
    }, U.prefersReducedMotion() ? 0 : 240);
    sheetState.open = false;
    if (sheetState.lastFocus && sheetState.lastFocus.focus) {
      try { sheetState.lastFocus.focus(); } catch (e) { /* node may be gone */ }
    }
  }

  /* ── C38 Toast ────────────────────────────────────────────────────────── */
  function mountToastLayer() {
    var layer = document.getElementById('toast-layer');
    if (!layer) return;
    Store.on('toast', function (item) {
      var node = el('div.toast' + (item.kind === 'error' ? '.toast--error' : ''), { role: 'status' }, [
        el('span.toast__text', { text: item.text }),
        item.action ? el('button.toast__action', {
          type: 'button',
          text: item.action.label,
          onclick: function () {
            item.action.onClick();
            node.remove();
          }
        }) : null
      ]);
      node.dataset.toastId = item.id;
      layer.appendChild(node);
      // Keep at most 2 stacked toasts so the transcript stays readable.
      while (layer.children.length > 2) layer.removeChild(layer.firstChild);
    });
    Store.on('toast:remove', function (item) {
      var node = layer.querySelector('[data-toast-id="' + item.id + '"]');
      if (node) node.remove();
    });
  }

  /* ── Toggle (light/dark) — appears in every tab header ────────────────── */
  function themeToggle() {
    var dark = Store.state.resolvedTheme === 'dark';
    return iconBtn(dark ? 'sun' : 'moon', dark ? '切换到浅色主题' : '切换到深色主题', {
      onClick: function () {
        Store.actions.setTheme(dark ? 'light' : 'dark');
      }
    });
  }

  global.UI = {
    deviceChip: deviceChip,
    iconBtn: iconBtn,
    statusPill: statusPill,
    chip: chip,
    metaChip: metaChip,
    filterChips: filterChips,
    searchField: searchField,
    header: header,
    backButton: backButton,
    groupHeader: groupHeader,
    sectionHead: sectionHead,
    button: button,
    progressBar: progressBar,
    emptyState: emptyState,
    errorState: errorState,
    offlineBanner: offlineBanner,
    openSheet: openSheet,
    closeSheet: closeSheet,
    mountToastLayer: mountToastLayer,
    themeToggle: themeToggle,
    reachText: reachText,
    STATUS: STATUS
  };
})(window);
