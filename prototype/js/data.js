/* ============================================================================
   data.js — seed fixtures.
   ----------------------------------------------------------------------------
   Everything here is *fake but plausible* demo data for the prototype. Where a
   field is not evidenced by the reference repo it is marked ASSUMPTION in the
   same place the UI consumes it (see docs/20-architecture.md §4.4 TaskSummary).
   Shapes intentionally mirror that TaskSummary so the prototype maps 1:1 onto
   the proposed `GET /mobile-access/tasks` projection.
   ========================================================================== */
(function (global) {
  'use strict';

  var NOW = Date.now();
  var MIN = 60 * 1000;

  function ago(minutes) { return NOW - minutes * MIN; }

  /* ── Devices (paired PCs) ─────────────────────────────────────────────────
     `reach` follows the four evidenced states from UI spec §5.3:
     reachable | checking | unreachable | expired. `latencyMs` is DERIVED: it is
     an observed RTT bucket, never a fabricated precise number.
     ────────────────────────────────────────────────────────────────────────── */
  var devices = [
    {
      id: 'dev_mbp',
      name: 'MacBook Pro',
      os: 'macOS 15.2',
      kind: 'local',              // LAN
      transport: 'lan',
      host: '192.168.1.24:3443',
      reach: 'reachable',
      latencyMs: 12,
      current: true,
      lastSeenAt: NOW - 2000,
      pairing: { installedAt: ago(60 * 24 * 21), fingerprint: '9F3A·71C4·E08B·5D2A' }
    },
    {
      id: 'dev_studio',
      name: 'Studio (Windows)',
      os: 'Windows 11',
      kind: 'remote',
      transport: 'tunnel',
      host: 'studio.tailnet.ts.net',
      reach: 'unreachable',
      latencyMs: null,
      current: false,
      lastSeenAt: ago(60 * 24 * 2),
      pairing: { installedAt: ago(60 * 24 * 40), fingerprint: '4C11·A9D2·7F30·BE61' }
    },
    {
      id: 'dev_old',
      name: '旧笔记本',
      os: 'macOS 13.6',
      kind: 'local',
      transport: 'lan',
      host: '—',
      reach: 'expired',
      latencyMs: null,
      current: false,
      lastSeenAt: ago(60 * 24 * 33),
      pairing: { installedAt: ago(60 * 24 * 120), fingerprint: '—' }
    }
  ];

  /* ── Tasks ────────────────────────────────────────────────────────────────
     state: running | needs_input | completed | failed | stopped
     steps: the last N observed tool calls for the activity strip (§7). Each is
     {name, arg, status, durMs} where status ∈ ok | run | fail.
     pending: 0..n pending interactions; dock renders one at a time (§6.3),
     ordered approval > question > plan.
     ────────────────────────────────────────────────────────────────────────── */
  var tasks = [
    {
      id: 't_payment',
      sessionId: 'ses_8f21a4',
      title: '重构 payment 模块的退款流程',
      workspace: 'dsh-web',
      model: 'Opus 4.5',
      state: 'running',
      turn: 12,
      startedAt: ago(4 + 12 / 60),   // 4:12 elapsed at load
      lastEventAt: NOW - 900,
      completedAt: null,
      latencyMs: 12,
      progress: null,                // A10: no percentage available → 40% fixed
      steps: [
        { name: 'Read', arg: 'src/pay/refund.ts', status: 'ok', durMs: 420 },
        { name: 'Grep', arg: 'refundPolicy', status: 'ok', durMs: 210 },
        { name: 'Read', arg: 'src/pay/policy.ts', status: 'ok', durMs: 380 },
        { name: 'Edit', arg: 'src/pay/refund.ts', status: 'ok', durMs: 1240 },
        { name: 'Edit', arg: 'src/pay/refund.ts', status: 'ok', durMs: 980 },
        { name: 'Bash', arg: 'pnpm test pay/refund', status: 'run', durMs: 0 }
      ],
      pending: [
        {
          id: 'q_payment_1',
          kind: 'question',
          title: '要把 src/api 下的 4 个调用点都改成 async 吗？',
          body: 'refund.ts 里已经把 createRefund 改成 async，但还有 4 处调用点仍是同步写法，TypeScript 会报 2323。',
          multi: false,
          options: [
            { id: 'all', label: '全部改成 async（4 处）' },
            { id: 'refund_only', label: '只改 refund 相关的 1 处' },
            { id: 'other', label: '其他（在下面说明）' }
          ],
          allowFreeText: true
        }
      ],
      transcript: [
        { role: 'user', at: ago(4 + 12 / 60), md: '把 refund 流程重构成 async，注意别破坏现有的重试策略。' },
        {
          role: 'assistant', at: ago(4 + 10 / 60),
          md: '先看现有实现，确认重试是在调用方还是被调方。\n\n- `createRefund` 目前是同步的，内部用 `retrySync` 包了一层\n- 重试策略在 `src/pay/policy.ts`，与调用方式无关，重构时可以不碰\n\n所以可以安全地把 `createRefund` 改成 async，重试逻辑保持原样。'
        },
        {
          role: 'tool', at: ago(4 + 4 / 60), name: 'Read', arg: 'src/pay/refund.ts',
          md: '```ts\n// src/pay/refund.ts\nexport function createRefund(orderId: string, amount: number) {\n  const policy = refundPolicy(orderId)\n  return retrySync(() => gateway.refund(orderId, amount), policy)\n}\n```'
        },
        {
          role: 'assistant', at: ago(3 + 40 / 60),
          md: '改成 async 之后，`retrySync` 要换成 `retry`，否则会把 Promise 当成成功值直接返回：\n\n```ts\nexport async function createRefund(orderId: string, amount: number) {\n  const policy = refundPolicy(orderId)\n  return retry(() => gateway.refund(orderId, amount), policy)\n}\n```\n\n已经改完这一处，接下来跑一下 refund 相关测试。'
        },
        { role: 'user', at: ago(3 + 2 / 60), md: '好，跑完把失败的用例贴出来。' },
        {
          role: 'assistant', at: ago(2 + 50 / 60),
          md: '正在跑 `pnpm test pay/refund`。已知会有 4 处调用点因为返回值从同步变异步而报错，等测试结果出来我一起处理。'
        }
      ]
    },

    {
      id: 't_migration',
      sessionId: 'ses_31c0be',
      title: '写 user_settings 表的迁移脚本',
      workspace: 'dsh-api',
      model: 'Sonnet 4.5',
      state: 'needs_input',
      turn: 4,
      startedAt: ago(6 + 3 / 60),
      lastEventAt: ago(45 * 1000),
      completedAt: null,
      latencyMs: 28,
      steps: [
        { name: 'Read', arg: 'migrations/2026_10_add_org.ts', status: 'ok', durMs: 300 },
        { name: 'Write', arg: 'migrations/2026_11_user_settings.ts', status: 'ok', durMs: 1600 },
        { name: 'Bash', arg: 'pnpm db:migrate --dry-run', status: 'fail', durMs: 2400 },
        { name: 'Ask', arg: '选择回滚策略', status: 'run', durMs: 0 }
      ],
      pending: [
        {
          id: 'a_migration_1',
          kind: 'approval',
          title: '需要你确认',
          body: '迁移脚本的 dry-run 失败，需要重建索引。下面这条命令会在电脑上执行。',
          command: 'psql "$DATABASE_URL" -c "DROP INDEX IF EXISTS idx_user_settings_org; CREATE INDEX CONCURRENTLY idx_user_settings_org ON user_settings (org_id, key);"',
          danger: true,
          options: [
            { id: 'allow_once', label: '允许一次' },
            { id: 'allow_always', label: '始终允许' },
            { id: 'deny', label: '拒绝' }
          ]
        }
      ],
      transcript: [
        { role: 'user', at: ago(6 + 3 / 60), md: '给 user_settings 加一个按 (org_id, key) 的复合索引，写成可回滚的迁移。' },
        {
          role: 'assistant', at: ago(5 + 30 / 60),
          md: '照着 `2026_10_add_org.ts` 的结构写了一个新的迁移，`down` 里会删掉索引。\n\n> dry-run 在创建索引这一步失败了：已有的 `idx_user_settings_org` 冲突，必须先 drop 再重建。'
        },
        {
          role: 'tool', at: ago(4), name: 'Bash', arg: 'pnpm db:migrate --dry-run',
          md: '```\nERROR: relation "idx_user_settings_org" already exists\n  at migrations/2026_11_user_settings.ts:18\n```'
        }
      ]
    },

    {
      id: 't_docs',
      sessionId: 'ses_77ab02',
      title: '把 README 里的安装步骤同步到 docs',
      workspace: 'dsh-web',
      model: 'Haiku 4',
      state: 'running',
      turn: 2,
      startedAt: ago(58 * 1000),
      lastEventAt: NOW - 400,
      completedAt: null,
      latencyMs: 34,
      steps: [
        { name: 'Read', arg: 'README.md', status: 'ok', durMs: 180 },
        { name: 'Grep', arg: 'pnpm install', status: 'ok', durMs: 120 },
        { name: 'Edit', arg: 'docs/install.md', status: 'run', durMs: 0 }
      ],
      pending: [],
      transcript: [
        { role: 'user', at: ago(58 * 1000), md: 'README 的安装步骤和 docs/install.md 不一致，帮我同步一下。' },
        { role: 'assistant', at: ago(50 * 1000), md: '先对比两边，找到 3 处差异，正在改 `docs/install.md`。' }
      ]
    },

    {
      id: 't_login',
      sessionId: 'ses_5b9d31',
      title: '修复登录页的竞态问题',
      workspace: 'dsh-web',
      model: 'Opus 4.5',
      state: 'completed',
      turn: 7,
      startedAt: ago(26 * MIN),
      lastEventAt: ago(12 * MIN),
      completedAt: ago(12 * MIN),
      latencyMs: 14,
      steps: [
        { name: 'Read', arg: 'src/auth/login.tsx', status: 'ok', durMs: 260 },
        { name: 'Edit', arg: 'src/auth/login.tsx', status: 'ok', durMs: 900 },
        { name: 'Bash', arg: 'pnpm test auth', status: 'ok', durMs: 6100 }
      ],
      pending: [],
      transcript: [
        { role: 'user', at: ago(26 * MIN), md: '登录按钮连点两次会发两个请求，第二次的结果覆盖第一次。' },
        {
          role: 'assistant', at: ago(12 * MIN),
          md: '是 `useEffect` 里的 abort 没有接上。加了 `AbortController` 并在 cleanup 里 abort，重复点击时旧请求会被取消。\n\n测试：`auth` 相关 18 个用例全过。'
        }
      ],
      fresh: true
    },

    {
      id: 't_review',
      sessionId: 'ses_2ac881',
      title: 'review 迁移脚本的回滚路径',
      workspace: 'dsh-api',
      model: 'Sonnet 4.5',
      state: 'failed',
      turn: 3,
      startedAt: ago(52 * MIN),
      lastEventAt: ago(41 * MIN),
      completedAt: ago(41 * MIN),
      latencyMs: 41,
      steps: [
        { name: 'Read', arg: 'migrations/2026_10_add_org.ts', status: 'ok', durMs: 320 },
        { name: 'Bash', arg: 'pnpm db:migrate:down', status: 'fail', durMs: 8300 }
      ],
      pending: [],
      error: '数据库连接在 8.3s 后超时（ECONNREFUSED 127.0.0.1:5432）',
      transcript: [
        { role: 'user', at: ago(52 * MIN), md: '把上次的迁移回滚路径 review 一遍。' },
        { role: 'assistant', at: ago(41 * MIN), md: '回滚到一半失败：本地 Postgres 没起来，`db:migrate:down` 连不上 5432。' }
      ]
    }
  ];

  /* ── Sessions ─────────────────────────────────────────────────────────────
     Grouped by workspace (ASSUMPTION A3: session→workspace mapping is not
     evidenced; the projection would have to carry it).
     ────────────────────────────────────────────────────────────────────────── */
  var sessions = [
    {
      id: 'ses_8f21a4', title: '重构 payment 模块的退款流程', workspace: 'dsh-web',
      updatedAt: ago(1), unread: true, failed: false, pinned: true, muted: false,
      model: 'Opus 4.5', taskId: 't_payment'
    },
    {
      id: 'ses_31c0be', title: '写 user_settings 表的迁移脚本', workspace: 'dsh-api',
      updatedAt: ago(1), unread: true, failed: false, pinned: false, muted: false,
      model: 'Sonnet 4.5', taskId: 't_migration'
    },
    {
      id: 'ses_77ab02', title: '把 README 里的安装步骤同步到 docs', workspace: 'dsh-web',
      updatedAt: ago(2), unread: false, failed: false, pinned: false, muted: false,
      model: 'Haiku 4', taskId: 't_docs'
    },
    {
      id: 'ses_5b9d31', title: '修复登录页的竞态问题', workspace: 'dsh-web',
      updatedAt: ago(12), unread: false, failed: false, pinned: false, muted: false,
      model: 'Opus 4.5', taskId: 't_login'
    },
    {
      id: 'ses_2ac881', title: 'review 迁移脚本的回滚路径', workspace: 'dsh-api',
      updatedAt: ago(41), unread: false, failed: true, pinned: false, muted: false,
      model: 'Sonnet 4.5', taskId: 't_review'
    },
    {
      id: 'ses_91de07', title: '移动端抽屉的滚动记忆', workspace: 'dsh-web',
      updatedAt: ago(60 * 20), unread: false, failed: false, pinned: false, muted: true,
      model: 'Opus 4.5', taskId: null
    },
    {
      id: 'ses_44ba19', title: '把遥测上报改成批量发送', workspace: 'dsh-api',
      updatedAt: ago(60 * 30), unread: false, failed: false, pinned: false, muted: false,
      model: 'Haiku 4', taskId: null
    },
    {
      id: 'ses_c0ffee', title: '整理 design tokens 的对比度表', workspace: 'dsh-mobile',
      updatedAt: ago(60 * 51), unread: false, failed: false, pinned: false, muted: false,
      model: 'Opus 4.5', taskId: null
    },
    {
      id: 'ses_bad123', title: '给配对页加证书指纹比对', workspace: 'dsh-mobile',
      updatedAt: ago(60 * 74), unread: false, failed: false, pinned: false, muted: false,
      model: 'Sonnet 4.5', taskId: null
    }
  ];

  /* ── Inbox ────────────────────────────────────────────────────────────────
     Categories are the six evidenced by docs/WEB_PUSH.md (问题/计划/审批/回复/
     目标/失败) — the spec forbids inventing a seventh (§5.5). Titles are session
     titles only; bodies never appear in the list (lock-screen redaction policy).
     ────────────────────────────────────────────────────────────────────────── */
  var inbox = [
    { id: 'n1', kind: 'question', title: '等待回答 · 重构 payment 模块的退款流程', workspace: 'dsh-web', at: NOW - 3 * MIN, read: false, taskId: 't_payment', pendingId: 'q_payment_1' },
    { id: 'n2', kind: 'approval', title: '等待审批 · 写 user_settings 表的迁移脚本', workspace: 'dsh-api', at: NOW - 4 * MIN, read: false, taskId: 't_migration', pendingId: 'a_migration_1' },
    { id: 'n3', kind: 'done', title: '已完成 · 修复登录页的竞态问题', workspace: 'dsh-web', at: NOW - 12 * MIN, read: false, taskId: 't_login', pendingId: null },
    { id: 'n4', kind: 'failed', title: '失败 · review 迁移脚本的回滚路径', workspace: 'dsh-api', at: NOW - 41 * MIN, read: true, taskId: 't_review', pendingId: null },
    { id: 'n5', kind: 'plan', title: '计划待批准 · 把遥测上报改成批量发送', workspace: 'dsh-api', at: NOW - 60 * 5, read: true, taskId: null, pendingId: null },
    { id: 'n6', kind: 'reply', title: '回复 · 整理 design tokens 的对比度表', workspace: 'dsh-mobile', at: NOW - 60 * 26, read: true, taskId: null, pendingId: null },
    { id: 'n7', kind: 'goal', title: '目标达成 · 给配对页加证书指纹比对', workspace: 'dsh-mobile', at: NOW - 60 * 30, read: true, taskId: null, pendingId: null }
  ];

  /* ── Diagnostics report (§5.7) ────────────────────────────────────────────
     Seven fixed layers, same order as CONNECTION_DIAGNOSTICS.md. The "手机路径"
     row is ALWAYS info — a green host never implies the phone is fully usable.
     ────────────────────────────────────────────────────────────────────────── */
  var diagnostics = {
    generatedAt: NOW - 6 * MIN,
    overall: 'attention',
    layers: [
      { id: 'version', group: '版本信息', status: 'ok', label: '插件 0.8.6 · DSH 0.1.5 · 最低 App 0.7.2' },
      { id: 'nic', group: '网卡与网关', status: 'ok', label: '局域网监听 3443 · 网卡 en0' },
      { id: 'firewall', group: '防火墙', status: 'warn', label: '未找到所需规则', action: '处理' },
      { id: 'tunnel', group: '本机通道', status: 'ok', label: '远程通道就绪' },
      { id: 'dns', group: '系统 DNS', status: 'info', label: '解析为私网地址 · IPv4' },
      { id: 'egress', group: '电脑出口探测', status: 'error', label: '连接阶段失败 · 2.4s' },
      { id: 'phone', group: '手机路径', status: 'info', label: '未在手机上验证：配对页、资源、WebSocket' }
    ]
  };

  global.SEED = {
    NOW: NOW,
    devices: devices,
    tasks: tasks,
    sessions: sessions,
    inbox: inbox,
    diagnostics: diagnostics
  };
})(window);
