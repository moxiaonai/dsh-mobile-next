/* ============================================================================
   screens/pairing.js — 配对 pairing (UI spec §5.6)
   ----------------------------------------------------------------------------
   Four-state single page: scan → verify → success (+ expired/denied/error).
   The trust line is on screen at all times (brief principle 4: trust is visible).
   No camera is used — the viewfinder is a static frame and the demo advances by
   tapping, so the flow is demonstrable in a desktop browser.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;
  var root = null;
  var alive = false;
  var step = 'scan';        // scan | verifying | success | expired | error | denied
  var linkValue = '';
  var linkError = '';

  var STEPS = ['扫码', '校验', '完成'];

  function mount(node) {
    root = node;
    alive = true;
    step = 'scan';
    linkValue = '';
    linkError = '';
    render();
    var off = Store.on('change', function (evt) {
      if (/^(theme|nav|connection)/.test(evt.type)) render();
    });
    return function dispose() { alive = false; off(); };
  }

  function render() {
    if (!root || !alive) return;
    U.clear(root);

    root.appendChild(UI.header({
      lead: UI.backButton(),
      title: '添加电脑',
      smallTitle: true,
      titleId: 'pairing-h1'
    }));

    var scroll = el('div.scroll');
    var page = el('div.page');
    page.appendChild(stepperBar());
    page.appendChild(body());
    scroll.appendChild(page);
    root.appendChild(scroll);
  }

  function stepperBar() {
    var activeIndex = step === 'scan' ? 0 : step === 'verifying' ? 1 : 2;
    var wrap = el('div', { style: { display: 'grid', gap: '6px' } });
    var bar = el('div.stepper', { role: 'progressbar', 'aria-valuemin': '1', 'aria-valuemax': '3', 'aria-valuenow': String(activeIndex + 1), 'aria-valuetext': '第 ' + (activeIndex + 1) + ' 步，共 3 步：' + STEPS[activeIndex] });
    STEPS.forEach(function (_, i) {
      bar.appendChild(el('div.stepper__seg' + (i <= activeIndex ? '.stepper__seg--on' : '')));
    });
    wrap.appendChild(bar);
    wrap.appendChild(el('div.stepper__labels', null, STEPS.map(function (label, i) {
      return el('span', { text: label, style: { color: i <= activeIndex ? 'var(--c-text-primary)' : 'var(--c-text-tertiary)', fontWeight: i === activeIndex ? '600' : '400' } });
    })));
    return wrap;
  }

  function body() {
    if (step === 'scan') return scanView();
    if (step === 'verifying') return verifyingView();
    if (step === 'success') return successView();
    if (step === 'expired') return expiredView();
    if (step === 'denied') return deniedView();
    return errorView();
  }

  /* ── Scan ─────────────────────────────────────────────────────────────── */
  function scanView() {
    var wrap = el('div.pair');

    var qr = el('div.qr', { role: 'img', 'aria-label': '二维码取景框，把电脑上的配对二维码放进来' }, [
      el('div.qr__corner.qr__corner--tl'),
      el('div.qr__corner.qr__corner--tr'),
      el('div.qr__corner.qr__corner--bl'),
      el('div.qr__corner.qr__corner--br'),
      el('div.qr__dash'),
      icon('qr', 'i--lg')
    ]);
    wrap.appendChild(qr);
    wrap.appendChild(el('p.qr__hint', { text: '把电脑上的配对二维码放进框内' }));

    var actions = el('div.pair__actions', null, [
      UI.button('打开相机', {
        variant: 'primary',
        block: true,
        icon: 'camera',
        onClick: function () {
          // Prototype: no real camera. Simulate permission + a detected code.
          step = 'verifying';
          render();
          setTimeout(function () {
            if (alive && step === 'verifying') { step = 'success'; render(); }
          }, 1800);
        }
      }),
      UI.button('改用链接配对', {
        variant: 'secondary',
        block: true,
        icon: 'link',
        onClick: function () { openLinkSheet(); }
      })
    ]);
    wrap.appendChild(actions);

    wrap.appendChild(trustLine());

    // Demo escape hatches so every state is reachable in a click-through.
    wrap.appendChild(el('div', { style: { display: 'flex', gap: '8px', flexWrap: 'wrap', justifyContent: 'center' } }, [
      linkPill('模拟扫码成功', function () { step = 'success'; render(); }),
      linkPill('模拟过期', function () { step = 'expired'; render(); }),
      linkPill('模拟权限被拒', function () { step = 'denied'; render(); })
    ]));

    return wrap;
  }

  function linkPill(label, onClick) {
    return el('button.btn.btn--text', { type: 'button', text: label, onclick: onClick, style: { fontSize: 'var(--t-caption)' } });
  }

  function openLinkSheet() {
    var wrap = el('div', { style: { padding: '0 16px 16px', display: 'grid', gap: '8px' } });
    var field = el('div.field', null, [
      el('label.field__label', { text: '配对链接', for: 'pair-link' }),
      el('input.field__input', {
        id: 'pair-link',
        type: 'url',
        inputmode: 'url',
        placeholder: 'https://192.168.1.24:3443/mobile-access/pair#…',
        value: linkValue
      })
    ]);
    var errorNode = el('p.field__error', { text: linkError, hidden: !linkError });
    var input = field.querySelector('input');
    input.addEventListener('input', function () {
      linkValue = input.value;
      linkError = '';
      errorNode.hidden = true;
    });

    wrap.appendChild(field);
    wrap.appendChild(errorNode);
    wrap.appendChild(UI.button('连接', {
      variant: 'primary',
      block: true,
      onClick: function () {
        if (!/^https?:\/\/\S+/.test(linkValue)) {
          linkError = '这不像一个配对链接，应该以 https:// 开头';
          errorNode.textContent = linkError;
          errorNode.hidden = false;
          input.focus();
          return;
        }
        UI.closeSheet();
        step = 'verifying';
        render();
        setTimeout(function () { if (alive && step === 'verifying') { step = 'success'; render(); } }, 1800);
      }
    }));
    wrap.appendChild(el('p.sheet__note', {
      text: '链接里带一次性配对码，粘贴后只在本机使用，不会上传到任何第三方。'
    }));

    var layer = document.getElementById('sheet-layer');
    var scrim = document.getElementById('scrim');
    U.clear(layer);
    var sheet = el('div.sheet', { role: 'dialog', 'aria-modal': 'true', 'aria-label': '粘贴配对链接' }, [
      el('div.sheet__grip'),
      el('h2.sheet__title', { text: '粘贴配对链接' }),
      wrap,
      el('button.sheet__cancel', { type: 'button', text: '取消', onclick: UI.closeSheet })
    ]);
    layer.appendChild(sheet);
    layer.hidden = false;
    scrim.hidden = false;
    requestAnimationFrame(function () { sheet.classList.add('sheet--in'); scrim.classList.add('scrim--in'); });
    setTimeout(function () { input.focus(); }, 120);
  }

  /* ── Verifying ────────────────────────────────────────────────────────── */
  function verifyingView() {
    var wrap = el('div.pair');
    wrap.appendChild(el('div.qr', null, [
      el('div.qr__corner.qr__corner--tl'),
      el('div.qr__corner.qr__corner--tr'),
      el('div.qr__corner.qr__corner--bl'),
      el('div.qr__corner.qr__corner--br'),
      el('span', { className: 'dot dot--accent dot--pulse', style: { width: '12px', height: '12px' } })
    ]));
    wrap.appendChild(el('h1.pair__title', { text: '正在校验电脑身份…' }));
    wrap.appendChild(el('p.pair__note', { text: '请把下面的指纹和电脑上显示的一致再继续。' }));

    // ASSUMPTION A7: fingerprint + install id fields are not evidenced; shown
    // as a comparison aid, degrades to text only when unavailable.
    wrap.appendChild(el('div.fingerprint', null, [
      el('div.fingerprint__row', null, [
        el('span', { text: '证书指纹（后 6 位）' }),
        el('span.fingerprint__val', { text: '5D2A·9F' })
      ]),
      el('div.fingerprint__row', null, [
        el('span', { text: '安装标识（前 8 位）' }),
        el('span.fingerprint__val', { text: 'a41f9c02' })
      ])
    ]));

    wrap.appendChild(trustLine());
    wrap.appendChild(UI.button('取消', {
      variant: 'secondary',
      block: true,
      onClick: function () { step = 'scan'; render(); }
    }));
    return wrap;
  }

  /* ── Success ──────────────────────────────────────────────────────────── */
  function successView() {
    var wrap = el('div.pair');
    wrap.appendChild(el('div.empty__icon', { style: { width: '56px', height: '56px', color: 'var(--c-success)', background: 'var(--c-success-weak-bg)' } },
      [icon('check', 'i--lg')]));
    wrap.appendChild(el('h1.pair__title', { text: '配对成功' }));
    wrap.appendChild(el('p.pair__note', { text: 'MacBook Pro · 局域网 192.168.1.24:3443' }));
    wrap.appendChild(el('div.pair__actions', null, [
      UI.button('进入任务', {
        variant: 'primary',
        block: true,
        onClick: function () {
          Store.actions.setTab('home');
        }
      }),
      UI.button('查看连接诊断', {
        variant: 'secondary',
        block: true,
        onClick: function () { Store.actions.push('diagnostics'); }
      })
    ]));
    wrap.appendChild(trustLine());
    return wrap;
  }

  /* ── Expired / denied / error ─────────────────────────────────────────── */
  function expiredView() {
    var wrap = el('div.pair');
    wrap.appendChild(el('div.empty__icon', { style: { width: '56px', height: '56px' } }, [icon('clock', 'i--lg')]));
    wrap.appendChild(el('h1.pair__title', { text: '配对码已过期' }));
    wrap.appendChild(el('p.pair__note', { text: '请回到电脑上重新生成二维码，再扫一次。' }));
    wrap.appendChild(UI.button('重新扫码', {
      variant: 'primary',
      block: true,
      onClick: function () { step = 'scan'; render(); }
    }));
    return wrap;
  }

  function deniedView() {
    var wrap = el('div.pair');
    wrap.appendChild(el('div.empty__icon', { style: { width: '56px', height: '56px' } }, [icon('camera', 'i--lg')]));
    wrap.appendChild(el('h1.pair__title', { text: '无法使用相机' }));
    wrap.appendChild(el('p.pair__note', { text: '相机权限被拒绝。可以到系统设置里打开，或改用链接配对。' }));
    wrap.appendChild(el('div.pair__actions', null, [
      UI.button('去系统设置', { variant: 'secondary', block: true, onClick: function () { Store.toast('原型无法打开系统设置'); } }),
      UI.button('改用链接配对', { variant: 'primary', block: true, onClick: function () { step = 'scan'; render(); openLinkSheet(); } })
    ]));
    return wrap;
  }

  function errorView() {
    return el('div.pair', null, [
      UI.errorState({
        title: '配对失败',
        text: '电脑没有接受这次配对请求。可能是电脑端已经取消了二维码，或者两台设备不在同一网络。',
        code: 'pairing_failed',
        actions: [
          UI.button('重试', { variant: 'primary', onClick: function () { step = 'verifying'; render(); setTimeout(function () { step = 'success'; render(); }, 1600); } }),
          UI.button('改用链接配对', { variant: 'secondary', onClick: function () { step = 'scan'; render(); openLinkSheet(); } })
        ]
      })
    ]);
  }

  /* Trust is visible: this line is always on the pairing screen. */
  function trustLine() {
    return el('div.trust-line', null, [
      icon('shield', 'i--sm'),
      el('span', { text: '只连接你自己电脑上的 DSH。配对后手机可以操作电脑上的全部会话。' })
    ]);
  }

  global.PairingScreen = { mount: mount, render: render };
})(window);
