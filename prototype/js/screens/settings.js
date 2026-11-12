/* ============================================================================
   screens/settings.js — 连接诊断 + 外观 (UI spec §5.7, §5.8)
   ----------------------------------------------------------------------------
   Two push surfaces sharing one module because both are "settings-shaped".

   Diagnostics keeps the seven fixed layers in the same order as
   CONNECTION_DIAGNOSTICS.md and always shows the 手机路径 row as info: a green
   host never implies the phone can fully use the connection.
   ========================================================================== */
(function (global) {
  'use strict';

  var el = U.el, icon = U.icon;

  /* ── 连接诊断 ─────────────────────────────────────────────────────────── */
  function mountDiagnostics(root) {
    var running = false;
    var alive = true;
    var report = Store.state.diagnostics;

    function render() {
      if (!alive) return;
      U.clear(root);

      root.appendChild(UI.header({
        lead: UI.backButton(),
        title: '连接诊断',
        smallTitle: true,
        titleId: 'diag-h1'
      }));

      var scroll = el('div.scroll');
      var page = el('div.page');

      var okCount = report.layers.filter(function (l) { return l.status === 'ok'; }).length;
      var warnCount = report.layers.filter(function (l) { return l.status === 'warn'; }).length;
      var errCount = report.layers.filter(function (l) { return l.status === 'error'; }).length;
      var overall = errCount ? 'error' : warnCount ? 'attention' : 'ok';

      page.appendChild(el('div.banner-summary.banner-summary--' + overall, null, [
        icon(overall === 'ok' ? 'check' : overall === 'error' ? 'x' : 'alert', 'i--lg'),
        el('div', null, [
          el('p.banner-summary__title', { text: overall === 'ok' ? '全部通过' : overall === 'error' ? '连接阶段失败' : '需要处理' }),
          el('p.banner-summary__text', {
            text: okCount + ' 项通过 · ' + warnCount + ' 项需注意 · ' + errCount + ' 项失败'
          }),
          el('p.banner-summary__text', {
            text: '生成于 ' + U.fmtClock(report.generatedAt) + ' · 手机路径未验证'
          })
        ])
      ]));

      page.appendChild(el('div', { style: { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '8px' } }, [
        UI.button(running ? '检查中…' : '开始检查', {
          variant: 'primary',
          loading: running,
          disabled: running,
          onClick: runCheck
        }),
        UI.button('复制报告', {
          variant: 'secondary',
          onClick: function () {
            U.copyText(buildReportText(report)).then(function () { Store.toast('已复制脱敏报告'); });
          }
        })
      ]));

      // Seven fixed layers, in order.
      var lastGroup = null;
      var box = null;
      report.layers.forEach(function (layer) {
        if (layer.group !== lastGroup) {
          lastGroup = layer.group;
          page.appendChild(UI.groupHeader(layer.group));
          box = el('div.card');
          page.appendChild(box);
        }
        box.appendChild(checkRow(layer));
      });

      page.appendChild(el('p.diag-note', {
        text: '绿色只表示对应的本机项目成功，不代表手机已经可以完整使用这条连接。'
      }));

      /* Advanced: third-party WebSocket paths (allow-listed by exact path). */
      var details = el('details', { style: { marginTop: '8px' } });
      details.appendChild(el('summary', {
        text: '高级：第三方 WebSocket 路径',
        style: { minHeight: '44px', display: 'flex', alignItems: 'center', cursor: 'pointer', fontSize: 'var(--t-body-sm)', color: 'var(--c-text-secondary)' }
      }));
      var pre = el('pre.mono', {
        text: '/sidebar/ws/agent-opens     已允许\n/mobile-access/events       已允许',
        style: {
          margin: '0', padding: '12px', borderRadius: '8px',
          background: 'var(--c-bg-sunken)', maxHeight: '240px', overflow: 'auto',
          overscrollBehavior: 'contain', color: 'var(--c-text-secondary)'
        }
      });
      details.appendChild(pre);
      page.appendChild(details);

      scroll.appendChild(page);
      root.appendChild(scroll);
    }

    function checkRow(layer) {
      var map = {
        ok: { icon: 'check', cls: 'check-row__icon--ok', text: '通过' },
        warn: { icon: 'alert', cls: 'check-row__icon--warn', text: '需注意' },
        error: { icon: 'x', cls: 'check-row__icon--error', text: '失败' },
        info: { icon: 'info', cls: 'check-row__icon--info', text: '信息' }
      };
      var meta = map[layer.status] || map.info;

      return el('div.check-row', null, [
        el('span', { className: 'check-row__icon ' + meta.cls }, [icon(meta.icon, 'i--sm')]),
        el('div.check-row__main', null, [
          // Text carries the status; colour only reinforces it (§9.2).
          el('span.check-row__label', { text: layer.group }),
          el('span.check-row__detail', { text: meta.text + ' · ' + layer.label })
        ]),
        layer.action ? el('span.check-row__action', null, [
          UI.button(layer.action, {
            variant: 'secondary',
            onClick: function () { Store.toast('需要在电脑上处理：' + layer.label); }
          })
        ]) : null
      ]);
    }

    function runCheck() {
      if (running) return;
      running = true;
      render();
      setTimeout(function () {
        running = false;
        report = Object.assign({}, report, { generatedAt: Date.now() });
        render();
        Store.toast('检查完成');
      }, 1500);
    }

    render();
    var off = Store.on('change', function (evt) {
      if (/^(theme|connection)/.test(evt.type)) render();
    });
    return function dispose() { alive = false; off(); };
  }

  function buildReportText(report) {
    var lines = ['DSH Mobile · 连接诊断', '生成于 ' + new Date(report.generatedAt).toISOString(), ''];
    report.layers.forEach(function (l) {
      lines.push('[' + l.status + '] ' + l.group + ' — ' + l.label);
    });
    lines.push('', '注：绿色只表示本机项目成功；手机路径未在此报告中验证。');
    return lines.join('\n');
  }

  /* ── 外观 ─────────────────────────────────────────────────────────────── */
  function mountAppearance(root) {
    var alive = true;
    function render() {
      if (!alive) return;
      U.clear(root);
      var s = Store.state;

      root.appendChild(UI.header({
        lead: UI.backButton(),
        title: '外观',
        smallTitle: true,
        titleId: 'appearance-h1'
      }));

      var scroll = el('div.scroll');
      var page = el('div.page');

      /* Theme: 3-way segmented (radiogroup). */
      page.appendChild(UI.groupHeader('主题'));
      var themeBox = el('div.card', { style: { padding: '8px' } });
      var seg = el('div.segmented', { role: 'radiogroup', 'aria-label': '主题' });
      [['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']].forEach(function (pair) {
        seg.appendChild(el('button.segmented__btn', {
          type: 'button',
          role: 'radio',
          'aria-checked': String(s.theme === pair[0]),
          text: pair[1],
          onclick: function () { Store.actions.setTheme(pair[0]); }
        }));
      });
      themeBox.appendChild(seg);
      page.appendChild(themeBox);

      /* Font size stepper. */
      page.appendChild(UI.groupHeader('字号'));
      var fontCard = el('div.card');
      fontCard.appendChild(el('div.setting-row', null, [
        el('div.setting-row__main', null, [
          el('div.setting-row__label', { text: '正文字号' }),
          el('div.setting-row__hint', { text: '影响正文、代码与选项；界面标签保持最小可读尺寸' })
        ]),
        el('div.stepper-ui', null, [
          el('button.stepper-ui__btn', {
            type: 'button',
            'aria-label': '减小字号',
            text: '−',
            disabled: s.fontBase <= 12,
            onclick: function () { Store.actions.setFontBase(s.fontBase - 1); }
          }),
          el('span.stepper-ui__value', { text: String(s.fontBase), 'aria-live': 'polite' }),
          el('button.stepper-ui__btn', {
            type: 'button',
            'aria-label': '增大字号',
            text: '+',
            disabled: s.fontBase >= 32,
            onclick: function () { Store.actions.setFontBase(s.fontBase + 1); }
          })
        ])
      ]));
      page.appendChild(fontCard);

      /* Motion. */
      page.appendChild(UI.groupHeader('动效'));
      var motionCard = el('div.card');
      motionCard.appendChild(el('div.setting-row', null, [
        el('div.setting-row__main', null, [
          el('div.setting-row__label', { text: '减弱动效' }),
          el('div.setting-row__hint', {
            text: '当前跟随系统：' + (U.prefersReducedMotion() ? '已减弱' : '正常')
          })
        ])
      ]));
      page.appendChild(motionCard);

      /* Live preview. */
      page.appendChild(UI.groupHeader('预览'));
      page.appendChild(el('div.preview-box', null, [
        el('p', { text: '这是一段正文示例。重构 payment 模块的退款流程，已用 4:12。', style: { margin: '0 0 8px' } }),
        el('p.mono', { text: 'export async function createRefund(orderId: string)', style: { margin: '0 0 8px' } }),
        el('p', { text: 'Aa 0123456789 · 延迟约 12ms', style: { margin: '0', color: 'var(--c-text-tertiary)' } })
      ]));

      page.appendChild(UI.button('恢复默认', {
        variant: 'secondary',
        block: true,
        onClick: function () {
          UI.openSheet({
            title: '恢复默认外观？',
            items: [
              { type: 'note', text: '字号回到 16，主题回到跟随系统。不会影响任务和会话。' },
              {
                icon: 'refresh',
                label: '恢复默认',
                onClick: function () {
                  Store.actions.setFontBase(16);
                  Store.actions.setTheme('system');
                  Store.toast('已恢复默认外观');
                }
              }
            ]
          });
        }
      }));

      scroll.appendChild(page);
      root.appendChild(scroll);
    }

    render();
    var off = Store.on('change', function (evt) {
      if (/^(theme|font)/.test(evt.type)) render();
    });
    return function dispose() { alive = false; off(); };
  }

  global.SettingsScreens = {
    diagnostics: mountDiagnostics,
    appearance: mountAppearance
  };
})(window);
