/* ============================================================================
   screens/devices.js — 设备 Devices (UI spec §5.3)
   ----------------------------------------------------------------------------
   Connection & control. Reachability uses the four evidenced states; the dot is
   always paired with text so state never depends on colour (§9.2). Revoked /
   expired pairings use strike-through semantics, never red — red means failure.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;
  var root = null;

  function mount(node) {
    root = node;
    render();
    Store.on('change', function (evt) {
      if (/^(devices|connection|theme|nav|sync|latency)/.test(evt.type)) scheduleRender();
    });
  }

  // Guarded: a scheduled repaint must never run against a detached root.
  var scheduleRender = U.schedule(function () { if (root) render(); });

  function render() {
    if (!root) return;
    var scrollTop = root.querySelector('.scroll') ? root.querySelector('.scroll').scrollTop : 0;
    U.clear(root);

    root.appendChild(UI.header({
      title: '设备',
      titleId: 'devices-h1',
      actions: [UI.themeToggle()]
    }));

    var banner = UI.offlineBanner();
    if (banner) root.appendChild(banner);

    var scroll = el('div.scroll.scroll--tabs');
    var page = el('div.page');
    scroll.appendChild(page);

    var devices = Store.state.devices;
    var current = devices.filter(function (d) { return d.current; })[0];
    var others = devices.filter(function (d) { return !d.current; });

    /* ── Current PC ─────────────────────────────────────────────────────── */
    if (!current) {
      page.appendChild(UI.emptyState({
        icon: 'monitor',
        title: '还没有配对电脑',
        text: '在电脑上打开「移动访问」，扫描二维码完成配对。',
        action: UI.button('扫码配对', {
          variant: 'primary',
          icon: 'qr',
          onClick: function () { Store.actions.push('pairing'); }
        })
      }));
    } else {
      page.appendChild(deviceCard(current));
    }

    /* ── Other PCs ──────────────────────────────────────────────────────── */
    if (others.length) {
      page.appendChild(UI.groupHeader('其他电脑', { count: others.length }));
      var list = el('div.stack');
      others.forEach(function (d) { list.appendChild(deviceRow(d)); });
      page.appendChild(list);
    }

    /* ── Add a PC ───────────────────────────────────────────────────────── */
    page.appendChild(UI.button('添加电脑', {
      variant: 'secondary',
      icon: 'plus',
      block: true,
      onClick: function () { Store.actions.push('pairing'); }
    }));

    /* ── Legend: what the dots mean, in words ───────────────────────────── */
    page.appendChild(el('div.legend', null, [
      el('span.legend__item', null, [el('span.dot'), el('span', { text: '可达' })]),
      el('span.legend__item', null, [el('span', { className: 'dot dot--accent dot--pulse' }), el('span', { text: '检测中' })]),
      el('span.legend__item', null, [el('span', { className: 'dot dot--idle' }), el('span', { text: '暂不可达' })]),
      el('span.legend__item', null, [el('span', { className: 'dot dot--muted' }), el('span', { text: '配对已过期' })])
    ]));

    /* ── Security ───────────────────────────────────────────────────────── */
    page.appendChild(UI.groupHeader('安全'));
    page.appendChild(UI.button('撤销本机全部配对', {
      variant: 'danger',
      block: true,
      onClick: function () {
        UI.openSheet({
          title: '撤销本机全部配对？',
          items: [
            { type: 'note', text: '手机上保存的所有电脑配对都会被删除，包括正在使用的这台。下次使用需要重新扫码。' },
            {
              icon: 'x',
              label: '撤销全部配对',
              danger: true,
              onClick: function () {
                Store.state.devices.forEach(function (d) { Store.actions.removeDevice(d.id); });
                Store.toast('已撤销全部配对');
              }
            }
          ]
        });
      }
    }));

    page.appendChild(el('p.diag-note', {
      text: '延迟为最近一次成功探测的往返耗时，显示为约数；拿不到时不显示。'
    }));

    /* ── Prototype-only demo entry (not part of the product spec) ────────── */
    page.appendChild(UI.groupHeader('原型'));
    page.appendChild(el('button.demo-entry', {
      type: 'button',
      onclick: function () { if (window.openDemoSheet) window.openDemoSheet(); }
    }, [
      icon('play', 'i--sm'),
      el('span', { text: '原型演示面板：手动触发模拟事件' }),
      el('span.demo-entry__tag', { text: '仅原型' })
    ]));

    root.appendChild(scroll);
    scroll.scrollTop = scrollTop;
  }

  /* ── C17 DeviceCard (the PC you are currently driving) ────────────────── */
  function deviceCard(device) {
    var reach = device.reach;
    var dotCls = 'dot' + (reach === 'reachable' ? '' : reach === 'checking' ? ' dot--accent dot--pulse' : ' dot--idle');

    var card = el('div.device-card.device-card--current', null, [
      el('div.device-card__head', null, [
        el('span', { className: dotCls }),
        el('span.device-card__name', { text: device.name }),
        el('span', { style: { flex: '1 1 auto' } }),
        UI.chip('当前', { cls: 'accent' })
      ]),
      el('div.device-card__meta', null, [
        el('span', { text: (device.transport === 'lan' ? '局域网' : '远程') + ' · ' + device.host }),
        el('span', { text: device.os }),
        el('span', { text: latencyText(device) })
      ]),
      el('div.device-card__meta', null, [
        el('span', { text: '已配对 ' + Math.round((Date.now() - device.pairing.installedAt) / 86400000) + ' 天' }),
        el('span', { text: '证书指纹 ' + device.pairing.fingerprint.slice(-9) })
      ]),
      el('div.device-card__actions', null, [
        UI.button(reach === 'checking' ? '连接中…' : '重新连接', {
          variant: 'secondary',
          loading: reach === 'checking',
          disabled: reach === 'checking',
          onClick: function () { reconnect(device); }
        }),
        UI.button('连接诊断', {
          variant: 'secondary',
          onClick: function () { Store.actions.push('diagnostics'); }
        })
      ])
    ]);

    // Tapping the reachability line re-probes, so the dot is never a dead end.
    card.querySelector('.device-card__meta').addEventListener('click', function () { reconnect(device); });
    return card;
  }

  function latencyText(device) {
    if (device.reach === 'checking') return '检测中';
    if (device.reach === 'reachable') {
      // DERIVED: bucket, never a fabricated precise number when unmeasured.
      if (device.latencyMs == null) return '可达';
      return '延迟约 ' + device.latencyMs + 'ms';
    }
    if (device.reach === 'expired') return '配对已过期';
    return '暂不可达 · 最后连接 ' + U.fmtRelative(device.lastSeenAt);
  }

  function reconnect(device) {
    Store.actions.setDeviceReach(device.id, 'checking', null);
    Store.toast('正在检测 ' + device.name + '…');
    setTimeout(function () {
      var ok = device.reach !== 'expired' && Math.random() > 0.25;
      Store.actions.setDeviceReach(
        device.id,
        ok ? 'reachable' : 'unreachable',
        ok ? 8 + Math.round(Math.random() * 22) : null
      );
      if (ok) {
        Store.actions.setOnline(true);
        Store.toast('已连接到 ' + device.name);
      } else {
        Store.toast('连不上 ' + device.name + '，检查网络或远程通道', { kind: 'error' });
      }
    }, 1600);
  }

  /* ── C18 DeviceRow (another paired PC) ────────────────────────────────── */
  function deviceRow(device) {
    var removed = device.reach === 'expired';
    var dotCls = 'dot' + (device.reach === 'reachable' ? '' : device.reach === 'checking' ? ' dot--accent dot--pulse' : ' dot--idle');

    return el('div.device-row.has-hit' + (removed ? '.device-row--removed' : ''), null, [
      el('button.hit', {
        type: 'button',
        'aria-label': device.name + '，' + latencyText(device) + '。打开操作菜单',
        onclick: function () { openDeviceSheet(device); }
      }),
      el('span', { className: dotCls }),
      el('div.device-row__main', null, [
        el('div.device-row__name', null, [
          el('span', { text: device.name }),
          UI.chip(device.transport === 'lan' ? '局域网' : '远程')
        ]),
        el('div.device-row__meta', { text: latencyText(device) })
      ]),
      el('button.icon-btn', {
        type: 'button',
        'aria-label': '设备操作：' + device.name,
        onclick: function (e) { e.stopPropagation(); openDeviceSheet(device); }
      }, [icon('more', 'i--sm')])
    ]);
  }

  function openDeviceSheet(device) {
    var items = [];

    if (device.reach === 'expired') {
      items.push({
        icon: 'qr',
        label: '重新配对',
        sub: '电脑端已移除这台手机，需要重新扫码',
        onClick: function () { Store.actions.push('pairing'); }
      });
    } else {
      items.push({
        icon: 'monitor',
        label: '切换到这电脑',
        sub: '手机将接管 ' + device.name + ' 上的任务',
        onClick: function () { Store.actions.switchDevice(device.id); }
      });
      items.push({
        icon: 'refresh',
        label: '立即检测',
        onClick: function () { reconnect(device); }
      });
      items.push({
        icon: 'pin',
        label: '置顶显示',
        onClick: function () { Store.toast('已置顶 ' + device.name); }
      });
      items.push({
        icon: 'link',
        label: '重新配对',
        sub: '会替换当前的设备令牌',
        onClick: function () { Store.actions.push('pairing'); }
      });
    }

    items.push({
      icon: 'archive',
      label: '删除本机记录',
      danger: true,
      onClick: function () { removeDevice(device); }
    });

    UI.openSheet({ title: device.name, items: items });
  }

  function removeDevice(device) {
    UI.openSheet({
      title: '删除 ' + device.name + ' 的本机记录？',
      items: [
        {
          type: 'note',
          text: '只会删除手机上的这条记录，不会恢复电脑端的授权；电脑端仍保留这台手机的配对，需要到电脑上撤销。'
        },
        {
          icon: 'archive',
          label: '删除本机记录',
          danger: true,
          onClick: function () {
            var removed = Store.actions.removeDevice(device.id);
            Store.toast('已删除 ' + device.name + ' 的本机记录', {
              action: {
                label: '撤销',
                onClick: function () {
                  Store.state.devices.push(removed);
                  Store.emit('devices');
                }
              },
              duration: 5000
            });
          }
        }
      ]
    });
  }

  global.DevicesScreen = { mount: mount, render: render };
})(window);
