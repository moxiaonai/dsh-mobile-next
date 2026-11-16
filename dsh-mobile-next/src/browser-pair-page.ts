import { randomBytes } from 'node:crypto'

/** 独立登录页：无需加载受认证保护的 DSH，也不在浏览器持久化长期凭据。 */
export function browserPairPage(pairPath: string, token = ''): {
  html: string
  headers: Record<string, string>
} {
  const nonce = randomBytes(18).toString('base64')
  const literal = (value: string): string => JSON.stringify(value).replace(/</g, '\\u003c')
  return {
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
      'content-security-policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    },
    html: `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<title>DSH Mobile · 网页登录</title>
<style nonce="${nonce}">
  * { box-sizing: border-box; }
  :root { font: 16px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; color-scheme: light dark; }
  body { margin: 0; min-height: 100vh; min-height: 100dvh; display: grid; place-items: center; padding: 24px 16px; background: #f7f8fa; color: #17212e; }
  main { width: 100%; max-width: 440px; padding: 28px 24px; background: #fff; border: 1px solid #e4e7ec; border-radius: 20px; }
  .brand { color: #2563eb; font-weight: 700; letter-spacing: .04em; }
  h1 { margin: 12px 0 8px; font-size: 26px; line-height: 1.35; }
  p { margin: 8px 0; }
  .muted, ol, .note { color: #526071; }
  ol { padding-left: 22px; margin: 20px 0; }
  li + li { margin-top: 8px; }
  label { display: block; margin-bottom: 8px; font-weight: 600; }
  textarea { width: 100%; min-height: 104px; resize: vertical; border: 1px solid #cbd5e1; border-radius: 12px; padding: 12px; font: inherit; background: #fff; color: inherit; overflow-wrap: anywhere; }
  textarea:focus { outline: 2px solid #2563eb; outline-offset: 2px; }
  button { width: 100%; min-height: 48px; margin-top: 16px; padding: 10px 16px; border: 0; border-radius: 12px; font: inherit; font-weight: 600; background: #2563eb; color: #fff; cursor: pointer; }
  button:disabled { opacity: .6; cursor: wait; }
  #status { margin-top: 16px; overflow-wrap: anywhere; }
  #status.error { color: #b91c1c; }
  .note { font-size: 13px; margin-top: 20px; }
  [hidden] { display: none !important; }
  @media (prefers-color-scheme: dark) {
    body { background: #0f172a; color: #f8fafc; }
    main { background: #1e293b; border-color: #334155; }
    textarea { background: #0f172a; border-color: #64748b; }
    .muted, ol, .note { color: #cbd5e1; }
    .brand { color: #93c5fd; }
    #status.error { color: #fca5a5; }
  }
</style>
</head>
<body>
<main>
  <div class="brand">DSH MOBILE · WEB</div>
  <h1>在浏览器中连接电脑</h1>
  <p class="muted">无需安装 App。首次访问需由电脑授权，配对后即可使用 DSH 网页。</p>
  <ol>
    <li>在电脑 DSH 中打开「移动访问」。</li>
    <li>生成局域网配对链接，复制到下方；也可以直接在这个浏览器中打开链接。</li>
  </ol>
  <form id="pair-form">
    <label for="pair-input">配对链接或配对令牌</label>
    <textarea id="pair-input" name="pairing" placeholder="粘贴电脑端生成的局域网配对链接" required maxlength="4096" autocomplete="off" autocapitalize="none" spellcheck="false"></textarea>
    <button id="submit" type="submit">配对并进入 DSH</button>
  </form>
  <p id="status" role="status" aria-live="polite"></p>
  <button id="go" type="button" hidden>进入 DSH</button>
  <p class="note">登录状态仅保存在当前浏览器。状态过期或被撤销后需重新配对。请勿向他人分享配对链接。</p>
  <noscript><p>此页面需要 JavaScript，请在浏览器设置中启用后重试。</p></noscript>
</main>
<script nonce="${nonce}">
(function () {
  var pairPath = ${literal(pairPath)};
  var initialToken = ${literal(token)};
  var form = document.getElementById('pair-form');
  var input = document.getElementById('pair-input');
  var submit = document.getElementById('submit');
  var status = document.getElementById('status');
  var go = document.getElementById('go');
  var busy = false;

  function readToken(value) {
    value = value.trim();
    if (!value) throw new Error('请粘贴电脑端生成的配对链接或配对令牌。');
    if (/^https?:\\/\\//i.test(value)) {
      var url = new URL(value);
      if (url.origin !== location.origin || url.pathname !== pairPath) {
        throw new Error('配对链接不属于当前电脑，请打开链接中的地址，或重新生成这台电脑的局域网配对链接。');
      }
      value = url.searchParams.get('token') || '';
    }
    if (!/^[A-Za-z0-9_-]{43}$/.test(value)) {
      throw new Error('配对链接或令牌格式不正确，请完整复制电脑端生成的内容。');
    }
    return value;
  }

  function errorMessage(code, statusCode) {
    if (code === 'authentication_failed') return '配对令牌无效、已过期或已使用，请在电脑上重新生成。';
    if (statusCode === 429) return '尝试次数过多，请稍后再试。';
    if (code === 'too_many_devices') return '已达到设备数量上限，请在电脑上撤销不用的设备后重试。';
    return '配对失败（HTTP ' + statusCode + '），请检查电脑端的移动访问状态后重试。';
  }

  async function pair(value) {
    if (busy) return;
    var token;
    try { token = readToken(value); }
    catch (error) { status.className = 'error'; status.textContent = error.message; return; }
    busy = true;
    submit.disabled = true;
    input.disabled = true;
    status.className = '';
    status.textContent = '正在配对…';
    var controller = new AbortController();
    var timeout = setTimeout(function () { controller.abort(); }, 15000);
    try {
      var res = await fetch(pairPath, {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ token: token, label: 'Web browser' }),
        signal: controller.signal,
      });
      var body = await res.json().catch(function () { return {}; });
      if (!res.ok) throw new Error(errorMessage(body.error, res.status));
      input.value = '';
      initialToken = '';
      form.hidden = true;
      status.textContent = '配对成功，正在进入 DSH…';
      go.hidden = false;
      location.replace('/');
    } catch (error) {
      status.className = 'error';
      status.textContent = error.name === 'AbortError'
        ? '连接超时，请确认手机与电脑网络互通后重试。'
        : (error.message || '连接失败，请检查网络后重试。');
    } finally {
      clearTimeout(timeout);
      busy = false;
      submit.disabled = false;
      input.disabled = false;
    }
  }

  form.addEventListener('submit', function (event) { event.preventDefault(); pair(input.value); });
  go.addEventListener('click', function () { location.replace('/'); });
  if (initialToken) {
    // 配对令牌只保留在当前页面内存，尽早移出地址栏与浏览器历史。
    history.replaceState(null, '', pairPath);
    pair(initialToken);
  }
})();
</script>
</body>
</html>`,
  }
}
