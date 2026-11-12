/* ============================================================================
   util.js — DOM helpers, formatting, markdown-ish renderer, tiny pub/sub.
   No dependencies. Loaded first; everything else may use these globals.
   ========================================================================== */
(function (global) {
  'use strict';

  /* ── DOM ──────────────────────────────────────────────────────────────── */

  /**
   * Create an element.
   * @param {string} tag  e.g. 'button' or 'button.btn.btn--primary'
   * @param {Object} [attrs] className / text / html / dataset / on* handlers
   * @param {Array<Node|string>} [children]
   */
  function el(tag, attrs, children) {
    var parts = String(tag).split('.');
    var name = parts.shift() || 'div';
    var node = document.createElement(name);
    if (parts.length) node.className = parts.join(' ');

    if (attrs) {
      Object.keys(attrs).forEach(function (key) {
        var val = attrs[key];
        if (val == null || val === false) return;
        if (key === 'className') { node.className = (node.className ? node.className + ' ' : '') + val; return; }
        if (key === 'text') { node.textContent = val; return; }
        if (key === 'html') { node.innerHTML = val; return; }
        if (key === 'dataset') { Object.keys(val).forEach(function (k) { node.dataset[k] = val[k]; }); return; }
        if (key === 'style') { Object.keys(val).forEach(function (k) { node.style[k] = val[k]; }); return; }
        if (key.slice(0, 2) === 'on' && typeof val === 'function') {
          node.addEventListener(key.slice(2).toLowerCase(), val);
          return;
        }
        if (val === true) { node.setAttribute(key, ''); return; }
        node.setAttribute(key, val);
      });
    }

    append(node, children);
    return node;
  }

  function append(node, children) {
    if (children == null) return node;
    (Array.isArray(children) ? children : [children]).forEach(function (child) {
      if (child == null || child === false) return;
      node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    });
    return node;
  }

  function qs(sel, root) { return (root || document).querySelector(sel); }
  function qsa(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  function clear(node) { while (node && node.firstChild) node.removeChild(node.firstChild); return node; }

  /** Inline SVG reference to a sprite symbol. Decorative by default. */
  function icon(name, cls) {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'i' + (cls ? ' ' + cls : ''));
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    var use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#i-' + name);
    svg.appendChild(use);
    return svg;
  }

  function escapeHtml(str) {
    return String(str == null ? '' : str)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /* ── Formatting ───────────────────────────────────────────────────────── */

  /** 4:12 style elapsed clock. Always mm:ss, hours fold into minutes. */
  function fmtElapsed(ms) {
    var total = Math.max(0, Math.floor(ms / 1000));
    var h = Math.floor(total / 3600);
    var m = Math.floor((total % 3600) / 60);
    var s = total % 60;
    if (h > 0) return h + ':' + pad(m) + ':' + pad(s);
    return m + ':' + pad(s);
  }

  function pad(n) { return n < 10 ? '0' + n : String(n); }

  /** Relative time, coarse and honest ("刚刚" / "12 分钟前"). */
  function fmtRelative(ts, now) {
    var diff = Math.max(0, (now || Date.now()) - ts);
    var min = Math.floor(diff / 60000);
    if (min < 1) return '刚刚';
    if (min < 60) return min + ' 分钟前';
    var hr = Math.floor(min / 60);
    if (hr < 24) return hr + ' 小时前';
    var day = Math.floor(hr / 24);
    if (day === 1) return '昨天';
    if (day < 30) return day + ' 天前';
    return new Date(ts).toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' });
  }

  /** HH:MM in the device locale, used for stale banners and inbox rows. */
  function fmtClock(ts) {
    var d = new Date(ts);
    return pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  function fmtDur(ms) {
    if (ms < 1000) return Math.round(ms) + 'ms';
    return (ms / 1000).toFixed(1) + 's';
  }

  /* ── Markdown-ish renderer ────────────────────────────────────────────────
     Deliberately small and safe: everything is escaped first, then a fixed set
     of block/inline constructs is re-introduced. Supports fenced code blocks
     (with language + copy button), headings, lists, blockquote, hr, inline
     code, bold, italic, links. That is what a real DSH transcript needs; a full
     CommonMark parser would be a dependency we are not allowed to add.
     ──────────────────────────────────────────────────────────────────────── */

  function inlineMd(text) {
    var out = escapeHtml(text);
    // inline code first so its contents are not touched by later rules
    out = out.replace(/`([^`]+)`/g, function (_, code) { return '<code>' + code + '</code>'; });
    out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    out = out.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, function (_, label, href) {
      return '<a href="' + href + '" target="_blank" rel="noopener noreferrer">' + label + '</a>';
    });
    return out;
  }

  /**
   * Render markdown-ish text to a DocumentFragment.
   * Code blocks become .code-block with their own scroll container (spec §5.4.4).
   */
  function renderMarkdown(src) {
    var frag = document.createDocumentFragment();
    var lines = String(src == null ? '' : src).replace(/\r\n/g, '\n').split('\n');
    var i = 0;

    function flushParagraph(buf) {
      if (!buf.length) return;
      frag.appendChild(el('p', { html: inlineMd(buf.join(' ')) }));
      buf.length = 0;
    }

    var para = [];
    var list = null;

    function flushList() {
      if (list) { frag.appendChild(list); list = null; }
    }

    while (i < lines.length) {
      var line = lines[i];

      // fenced code block
      var fence = line.match(/^```([\w+#.-]*)\s*$/);
      if (fence) {
        flushParagraph(para); flushList();
        var lang = fence[1] || '';
        var body = [];
        i++;
        while (i < lines.length && !/^```\s*$/.test(lines[i])) { body.push(lines[i]); i++; }
        i++; // closing fence
        frag.appendChild(codeBlock(body.join('\n'), lang));
        continue;
      }

      if (/^\s*$/.test(line)) { flushParagraph(para); flushList(); i++; continue; }

      var heading = line.match(/^(#{1,4})\s+(.*)$/);
      if (heading) {
        flushParagraph(para); flushList();
        var level = Math.min(4, Math.max(3, heading[1].length + 2)); // keep h1/h2 for the screen
        frag.appendChild(el('h' + level, { html: inlineMd(heading[2]) }));
        i++; continue;
      }

      if (/^\s*(---|\*\*\*)\s*$/.test(line)) {
        flushParagraph(para); flushList();
        frag.appendChild(el('hr'));
        i++; continue;
      }

      if (/^>\s?/.test(line)) {
        flushParagraph(para); flushList();
        var quote = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) {
          quote.push(lines[i].replace(/^>\s?/, ''));
          i++;
        }
        frag.appendChild(el('blockquote', { html: inlineMd(quote.join(' ')) }));
        continue;
      }

      var ol = line.match(/^\s*(\d+)[.)]\s+(.*)$/);
      var ul = line.match(/^\s*[-*+]\s+(.*)$/);
      if (ol || ul) {
        flushParagraph(para);
        var isOrdered = !!ol;
        if (!list || list.tagName.toLowerCase() !== (isOrdered ? 'ol' : 'ul')) {
          flushList();
          list = el(isOrdered ? 'ol' : 'ul');
        }
        list.appendChild(el('li', { html: inlineMd(ol ? ol[2] : ul[1]) }));
        i++; continue;
      }

      flushList();
      para.push(line.trim());
      i++;
    }
    flushParagraph(para);
    flushList();
    return frag;
  }

  /** Code block with language label + 44px copy target inside a 32px header. */
  function codeBlock(code, lang) {
    var block = el('div.code-block');
    var head = el('div.code-block__head', null, [
      el('span.code-block__lang', { text: lang || 'text' }),
      el('button.code-block__copy', {
        type: 'button',
        'aria-label': '复制代码',
        onclick: function () {
          copyText(code).then(function () { toast('已复制代码'); });
        }
      }, [icon('copy', 'i--sm')])
    ]);
    var pre = el('pre');
    var codeEl = el('code', { text: code });
    pre.appendChild(codeEl);
    block.appendChild(head);
    block.appendChild(pre);
    return block;
  }

  /* ── Clipboard ────────────────────────────────────────────────────────── */

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return Promise.resolve(legacyCopy(text));
  }

  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '-1000px';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* ignore */ }
    document.body.removeChild(ta);
  }

  /* ── Tiny pub/sub ─────────────────────────────────────────────────────── */

  function Emitter() { this._handlers = {}; }
  Emitter.prototype.on = function (type, fn) {
    (this._handlers[type] || (this._handlers[type] = [])).push(fn);
    return function () { this.off(type, fn); }.bind(this);
  };
  Emitter.prototype.off = function (type, fn) {
    var list = this._handlers[type] || [];
    var idx = list.indexOf(fn);
    if (idx >= 0) list.splice(idx, 1);
  };
  Emitter.prototype.emit = function (type, payload) {
    (this._handlers[type] || []).slice().forEach(function (fn) {
      try { fn(payload); } catch (err) { console.error('[emit]', type, err); }
    });
  };

  /* ── Motion preference ────────────────────────────────────────────────── */

  var reduceMotion = global.matchMedia
    ? global.matchMedia('(prefers-reduced-motion: reduce)')
    : { matches: false, addEventListener: function () {} };

  function prefersReducedMotion() { return !!reduceMotion.matches; }

  /** Scroll helper that respects reduced-motion (spec §2.6). */
  function scrollToBottom(node, smooth) {
    if (!node) return;
    node.scrollTo({
      top: node.scrollHeight,
      behavior: smooth && !prefersReducedMotion() ? 'smooth' : 'auto'
    });
  }

  function isNearBottom(node, threshold) {
    if (!node) return true;
    return node.scrollHeight - node.scrollTop - node.clientHeight <= (threshold || 8);
  }

  /** Debounce; used for resize/scroll bookkeeping. */
  function debounce(fn, wait) {
    var t = null;
    return function () {
      var args = arguments, self = this;
      clearTimeout(t);
      t = setTimeout(function () { fn.apply(self, args); }, wait || 120);
    };
  }

  function clamp(n, min, max) { return Math.min(max, Math.max(min, n)); }

  /**
   * Coalesce a burst of synchronous state changes into one render.
   * Uses setTimeout rather than requestAnimationFrame on purpose: rAF is
   * throttled to zero in background tabs and in headless/virtual-time runs,
   * which would silently freeze the UI. A 0ms macrotask still batches every
   * synchronous mutation in the same turn, which is all we need.
   */
  function schedule(fn) {
    var queued = false;
    return function () {
      if (queued) return;
      queued = true;
      setTimeout(function () { queued = false; fn(); }, 0);
    };
  }

  global.U = {
    el: el, append: append, qs: qs, qsa: qsa, clear: clear, icon: icon,
    escapeHtml: escapeHtml,
    fmtElapsed: fmtElapsed, fmtRelative: fmtRelative, fmtClock: fmtClock,
    fmtDur: fmtDur, pad: pad,
    renderMarkdown: renderMarkdown, inlineMd: inlineMd, codeBlock: codeBlock,
    copyText: copyText,
    Emitter: Emitter,
    prefersReducedMotion: prefersReducedMotion,
    scrollToBottom: scrollToBottom, isNearBottom: isNearBottom,
    debounce: debounce, clamp: clamp, schedule: schedule
  };
})(window);
