import { runInNewContext } from 'node:vm'
import { describe, expect, it, vi } from 'vitest'
import { browserPairPage } from '../src/browser-pair-page.js'

const pairPath = '/mobile-access-next/pair'
const origin = 'https://192.168.1.5:3444'
const token = 'A'.repeat(43)

/** 只执行页面脚本做行为测试；不用于渲染或声称真机视觉验证。 */
function browser(initialToken = '', fetch = vi.fn(async () => ({
  ok: true, status: 201, json: async () => ({}),
}))) {
  const elements = Object.fromEntries(['pair-form', 'pair-input', 'submit', 'status', 'go'].map(id => [id, {
    value: '', textContent: '', className: '', disabled: false, hidden: id === 'go',
    listeners: {} as Record<string, (event: { preventDefault: () => void }) => void>,
    addEventListener(type: string, listener: (event: { preventDefault: () => void }) => void) {
      this.listeners[type] = listener
    },
  }]))
  const replace = vi.fn()
  const replaceState = vi.fn()
  const page = browserPairPage(pairPath, initialToken)
  const script = /<script nonce="[^"]+">([\s\S]*?)<\/script>/.exec(page.html)?.[1]
  if (script === undefined) throw new Error('missing inline script')
  runInNewContext(script, {
    document: { getElementById: (id: string) => elements[id] },
    location: { origin, replace }, history: { replaceState },
    URL, fetch, AbortController, setTimeout, clearTimeout,
  })
  return {
    elements, replace, replaceState, fetch,
    submit(value: string) {
      elements['pair-input']!.value = value
      elements['pair-form']!.listeners.submit!({ preventDefault: vi.fn() })
    },
  }
}

describe('网页登录页脚本', () => {
  it('直接访问只展示表单，不自动申请设备', () => {
    const b = browser()
    expect(b.fetch).not.toHaveBeenCalled()
    expect(b.elements['pair-form']!.hidden).toBe(false)
  })

  it.each([token, `  ${origin}${pairPath}?token=${token}  `])('粘贴链接或令牌后使用原配对接口并进入 DSH: %s', async value => {
    const b = browser()
    b.submit(value)
    await vi.waitFor(() => expect(b.replace).toHaveBeenCalledWith('/'))
    expect(b.fetch).toHaveBeenCalledTimes(1)
    const [path, options] = b.fetch.mock.calls[0]! as unknown as [string, RequestInit]
    expect(path).toBe(pairPath)
    expect(options.credentials).toBe('same-origin')
    expect(options.method).toBe('POST')
    expect(JSON.parse(options.body as string)).toEqual({ token, label: 'Web browser' })
    expect(b.elements['pair-form']!.hidden).toBe(true)
    expect(b.elements['pair-input']!.value).toBe('')
  })

  it('扫码入口自动配对并清除地址栏的令牌', async () => {
    const b = browser(token)
    expect(b.replaceState).toHaveBeenCalledWith(null, '', pairPath)
    await vi.waitFor(() => expect(b.replace).toHaveBeenCalledWith('/'))
    expect(b.fetch).toHaveBeenCalledTimes(1)
  })

  it.each([
    '', '123456', 'dsh-mobile://remote',
    `https://another-computer:3444${pairPath}?token=${token}`,
    `${origin}/wrong?token=${token}`,
    `${origin}${pairPath}`,
  ])('格式错误或其他电脑的链接不会提交: %s', value => {
    const b = browser()
    b.submit(value)
    expect(b.fetch).not.toHaveBeenCalled()
    expect(b.elements.status!.className).toBe('error')
    expect(b.elements.status!.textContent).not.toBe('')
  })

  it.each([
    [401, 'authentication_failed', '已过期或已使用'],
    [429, 'rate_limited', '尝试次数过多'],
    [409, 'too_many_devices', '设备数量上限'],
  ])('失败时给出可操作提示并允许重试: %s', async (status, error, message) => {
    const fetch = vi.fn(async () => ({ ok: false, status, json: async () => ({ error }) }))
    const b = browser('', fetch)
    b.submit(token)
    await vi.waitFor(() => expect(b.elements.status!.textContent).toContain(message))
    expect(b.elements['pair-form']!.hidden).toBe(false)
    expect(b.elements.submit!.disabled).toBe(false)
    expect(b.replace).not.toHaveBeenCalled()
  })

  it('连接超时恢复表单', async () => {
    vi.useFakeTimers()
    try {
      const fetch = vi.fn(async (...args: unknown[]) => {
        const options = args[1] as RequestInit
        await new Promise((_, reject) => options.signal!.addEventListener('abort', () => {
          const error = new Error('aborted'); error.name = 'AbortError'; reject(error)
        }))
        return { ok: true, status: 201, json: async () => ({}) }
      })
      const b = browser('', fetch)
      b.submit(token)
      b.submit(token)
      expect(fetch).toHaveBeenCalledTimes(1)
      await vi.advanceTimersByTimeAsync(15000)
      expect(b.elements.status!.textContent).toContain('连接超时')
      expect(b.elements.submit!.disabled).toBe(false)
      expect(b.replace).not.toHaveBeenCalled()
    } finally {
      vi.useRealTimers()
    }
  })

  it('令牌不能逃逸 script，登录页不缓存且不能被嵌入第三方页面', () => {
    const page = browserPairPage(pairPath, '</script><script>alert(1)</script>')
    expect(page.html.match(/<script nonce=/g)).toHaveLength(1)
    expect(page.html).not.toContain('</script><script>alert(1)')
    expect(page.headers['cache-control']).toBe('no-store')
    expect(page.headers['referrer-policy']).toBe('no-referrer')
    expect(page.headers['content-security-policy']).toContain("frame-ancestors 'none'")
    const nonce = /<script nonce="([^"]+)">/.exec(page.html)![1]
    expect(page.headers['content-security-policy']).toContain(`script-src 'nonce-${nonce}'`)
    expect(page.headers['content-security-policy']).toContain(`style-src 'nonce-${nonce}'`)
    expect(page.html).not.toContain('localStorage')
    expect(page.html).not.toContain('deviceToken')
  })
})
