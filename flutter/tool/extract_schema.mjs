#!/usr/bin/env node
// 从 DSH Desktop 的 app.asar 中抽取全部 RPC 端点的 JSON Schema。
//
//   node tool/extract_schema.mjs [--asar <path>] [--out <path>] [--quiet]
//
// 产出 `tool/schema.json`：结构化、键序稳定、可 diff、可提交。
//
// ── 为什么要这么绕 ────────────────────────────────────────────────
// asar 里的 `dsh-api-remotes/lib/client.js` 是一个 Electron 模块包装：
//
//     window.__ModuleLoader__.load({ id, factory: (require) => { ... } })
//
// 端点的描述符（`{ service, description, invocation, parameters[], result }`）
// 是 `factory` 里的**模块私有**变量，唯一的出口是 `apply(ctx)` —— 它会调用
// `ctx.remote.$mount(contribution)`。所以我们：
//
//   1. 解析 asar 头拿到 `client.js` 的字节；
//   2. 在 `node:vm` 里以假的 `zod` 执行它（不需要真的 zod 依赖）；
//   3. 用一个假的 `ctx.remote.$mount` 截获全部 27 个 contribution；
//   4. 展开 `contribution.descriptors` 得到 150 个端点。
//
// `zod` 是假的：我们只关心**结构**，不关心校验。每个 `zod.z.*` 调用都返回一个
// 记录 `{ kind, args, meta }` 的节点，`.describe()/.optional()/.readonly()`
// 就地记录元数据。这样既有 `jsonSchema` 又能拿到 `required` 语义。
//
// ── 两种 schema 来源 ─────────────────────────────────────────────
// 描述符大多自带字面量 `jsonSchema`（编译器投影产物），直接采用，最忠实；
// 但有 37 个 result / 1 个 parameter 只留了 `jsonSchemaError`（"selected
// dictionaries require string keys..."），这时从假 zod 的节点树**合成**一份。
// 每条端点都标注 `schemaSource`，便于日后核对。

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(HERE, '..');

const DEFAULT_ASAR =
  '/Applications/DeepSeek Harness.app/Contents/Resources/app.asar';
const DEFAULT_OUT = path.join(HERE, 'schema.json');

/** 端点描述符所在文件（相对 asar 根）。 */
const CLIENT_JS = '/dsh/node_modules/@deepseek-ai/dsh-api-remotes/lib/client.js';

// ────────────────────────────────────────────────────────────────
// asar 读取
// ────────────────────────────────────────────────────────────────

/**
 * 打开一个 asar 归档。格式（Chromium pickle）：
 *   0..3   uint32 = 4（下一个字段自身长度）
 *   4..7   uint32 = headerSize + 8（含自身）
 *   8..11  uint32 = headerSize + 4（含自身）
 *   12..15 uint32 = headerSize（JSON 字节数）
 *   16..   headerSize 字节 UTF-8 JSON 目录
 * 数据基址 = 16 + headerSize；每个文件用 `offset` 相对基址定位。
 */
function openAsar(file) {
  const fd = fs.openSync(file, 'r');
  const head = Buffer.alloc(16);
  fs.readSync(fd, head, 0, 16, 0);
  const headerSize = head.readUInt32LE(12);
  const headerBuf = Buffer.alloc(headerSize);
  fs.readSync(fd, headerBuf, 0, headerSize, 16);
  const root = JSON.parse(headerBuf.toString('utf8'));
  const dataBase = 16 + headerSize;

  /** 深度优先遍历目录树，返回所有叶子（文件）条目。 */
  const files = [];
  const stack = [['', root]];
  while (stack.length > 0) {
    const [prefix, node] = stack.pop();
    if (node.files) {
      for (const [name, child] of Object.entries(node.files)) {
        stack.push([`${prefix}/${name}`, child]);
      }
      continue;
    }
    files.push({ path: prefix, size: node.size, offset: Number(node.offset) });
  }

  return {
    header: root,
    fileCount: files.length,
    files,
    read(entryPath) {
      const entry = files.find((f) => f.path === entryPath);
      if (!entry) throw new Error(`asar: no such entry ${entryPath}`);
      const buf = Buffer.alloc(entry.size);
      fs.readSync(fd, buf, 0, entry.size, dataBase + entry.offset);
      return buf;
    },
    close: () => fs.closeSync(fd),
  };
}

// ────────────────────────────────────────────────────────────────
// 假 zod：把 `zod.z.*` 调用记录成节点树
// ────────────────────────────────────────────────────────────────

class ZodNode {
  constructor(kind, args, meta) {
    this.kind = kind;
    this.args = args;
    this.meta = meta ?? {};
  }

  describe(text) {
    this.meta.description = text;
    return this;
  }

  readonly() {
    return this;
  }

  optional() {
    this.meta.optional = true;
    return this;
  }

  nonoptional() {
    this.meta.nonoptional = true;
    return this;
  }

  /** 未知的链式方法一律忽略，保证生成器向前兼容。 */
  static install() {
    return new Proxy(
      {},
      {
        get(_target, prop) {
          if (prop === 'z') return ZodNode.install();
          if (prop === 'then') return undefined; // 别让 await 误判为 thenable
          if (typeof prop === 'symbol') return undefined;
          return (...args) => new ZodNode(String(prop), args);
        },
      },
    );
  }
}

/** 只保留 `window.__ModuleLoader__.load(...)` 开始的脚本（前面有 2 字节填充）。 */
function isolateScript(text) {
  const marker = 'window.__ModuleLoader__.load(';
  const at = text.indexOf(marker);
  if (at < 0) throw new Error(`client.js: marker ${marker} not found`);
  return { script: text.slice(at), prefixBytes: at };
}

/** 执行 client.js，截获 `ctx.remote.$mount` 收到的全部 contribution。 */
function loadContributions(script, zodStub) {
  const modules = [];
  const sandbox = {
    window: {
      __ModuleLoader__: { load: (mod) => modules.push(mod) },
    },
    require: (name) => {
      if (name === 'zod') return zodStub;
      throw new Error(`client.js: unexpected require("${name}")`);
    },
    console,
  };
  vm.createContext(sandbox);
  vm.runInContext(script, sandbox, { filename: 'dsh-api-remotes/lib/client.js' });

  if (modules.length !== 1) {
    throw new Error(`client.js: expected 1 module, loaded ${modules.length}`);
  }
  const module = modules[0];
  const exportsObj = module.factory(sandbox.require);

  const contributions = [];
  const ctx = {
    remote: {
      $mount: async (contribution) => {
        contributions.push(contribution);
        return () => {};
      },
    },
  };
  // apply() 是 async，但假 $mount 立即返回，所以一次微任务即可。
  return exportsObj.apply(ctx).then(() => contributions);
}

// ────────────────────────────────────────────────────────────────
// 从假 zod 节点树合成 JSON Schema
// ────────────────────────────────────────────────────────────────

const SCALARS = new Set(['string', 'number', 'boolean']);

/**
 * 合成规则与官方 `jsonSchema` 投影保持一致：
 * - `object`/`strictObject` → `type:object` + `properties` + `required`
 *   （`strictObject` 的 `additionalProperties` 为 false，与官方一致）；
 * - `record` → `type:object` + `additionalProperties`；
 * - `union` → `oneOf`（若全是字面量则折叠成 `enum`）；
 * - `intersection` 且各支都是对象 → 合并成一个对象。
 */
function synthSchema(node, depth = 0) {
  if (node == null || typeof node !== 'object') return {};
  if (depth > 200) throw new Error('synthSchema: depth limit exceeded');

  const meta = node.meta ?? {};
  const out = {};

  switch (node.kind) {
    case 'string':
    case 'number':
    case 'boolean':
      out.type = node.kind;
      break;
    case 'null':
    case 'undefined':
    case 'void':
      out.type = 'null';
      break;
    case 'never':
      out.not = {};
      break;
    case 'json':
      // `zod.z.json()` 就是"任意 JSON 值"，空 schema 即代表。
      break;
    case 'instanceof':
      // 无法用 JSON Schema 表达；退化为不约束。
      break;
    case 'literal': {
      const value = node.args[0];
      if (value === null) {
        out.type = 'null';
      } else {
        out.const = value;
        out.type =
          typeof value === 'number'
            ? 'number'
            : typeof value === 'boolean'
              ? 'boolean'
              : 'string';
      }
      break;
    }
    case 'array': {
      out.type = 'array';
      const items = synthSchema(node.args[0], depth + 1);
      out.items = items;
      break;
    }
    case 'record': {
      out.type = 'object';
      const value = synthSchema(node.args[1], depth + 1);
      out.additionalProperties = value;
      break;
    }
    case 'object':
    case 'strictObject': {
      const shape = node.args[0] ?? {};
      const properties = {};
      const required = [];
      for (const [key, child] of Object.entries(shape)) {
        const schema = synthSchema(child, depth + 1);
        if (child?.meta?.description !== undefined && schema.description === undefined) {
          schema.description = child.meta.description;
        }
        properties[key] = schema;
        if (child?.meta?.optional !== true) required.push(key);
      }
      out.type = 'object';
      out.properties = properties;
      out.required = required;
      out.additionalProperties = node.kind === 'strictObject' ? false : true;
      break;
    }
    case 'union': {
      const arms = node.args[0] ?? [];
      const literals = arms.map((arm) => (arm?.kind === 'literal' ? arm.args[0] : Symbol('x')));
      const allLiterals = literals.every((v) => typeof v === 'string' || typeof v === 'number');
      const sameType =
        allLiterals &&
        literals.every((v) => typeof v === literals[0]?.constructor);
      if (allLiterals && sameType && literals.length > 0) {
        out.type = typeof literals[0] === 'number' ? 'number' : 'string';
        out.enum = literals;
      } else {
        out.oneOf = arms.map((arm) => synthSchema(arm, depth + 1));
      }
      break;
    }
    case 'intersection': {
      const arms = (Array.isArray(node.args[0]) ? node.args[0] : node.args).map((arm) =>
        synthSchema(arm, depth + 1),
      );
      const allObjects = arms.every((arm) => arm.type === 'object');
      if (allObjects) {
        const properties = {};
        const required = new Set();
        for (const arm of arms) {
          Object.assign(properties, arm.properties ?? {});
          for (const key of arm.required ?? []) required.add(key);
        }
        out.type = 'object';
        out.properties = properties;
        out.required = [...required];
        out.additionalProperties = arms.every((arm) => arm.additionalProperties !== false);
      } else {
        out.allOf = arms;
      }
      break;
    }
    default:
      // 未识别的 zod 构造器：退化为不约束，并留痕。
      out['x-unmapped-zod'] = node.kind;
      break;
  }

  if (meta.description !== undefined && out.description === undefined) {
    out.description = meta.description;
  }
  return out;
}

// ────────────────────────────────────────────────────────────────
// 端点描述符 → schema.json 条目
// ────────────────────────────────────────────────────────────────

/** `@deepseek-ai/dsh-api-session-controller/types#SessionListValue` → `SessionListValue`。 */
function shortTypeSymbol(symbol) {
  if (typeof symbol !== 'string') return undefined;
  const hash = symbol.lastIndexOf('#');
  return hash >= 0 ? symbol.slice(hash + 1) : symbol;
}

function normalizeParameter(parameter) {
  const declared = parameter.codec?.jsonSchema;
  const strictDeclared = parameter.strictCodec?.jsonSchema;
  const schema =
    declared ??
    (typeof parameter.codec?.create === 'function'
      ? synthSchema(parameter.codec.create())
      : {});

  return {
    name: parameter.name,
    wire: parameter.wire ?? parameter.name,
    source: parameter.source,
    // `source: "json"` + `acceptsUndefined: true` 才可以在 wire 上缺席；
    // 与官方 `optional(parameter)` 完全一致（client.js:84）。
    optional: parameter.source === 'json' && parameter.acceptsUndefined === true,
    description: parameter.description ?? null,
    typeSymbol: shortTypeSymbol(parameter.codec?.typeSymbol) ?? null,
    schemaSource: declared ? 'declared' : 'synthesized',
    // 记录 strict 变体是否更严（只差 additionalProperties），便于核对。
    strictAdditionalProperties:
      strictDeclared?.additionalProperties ?? null,
    schema,
  };
}

function normalizeResult(result) {
  const declared = result?.jsonSchema;
  const schema =
    declared ??
    (typeof result?.create === 'function' ? synthSchema(result.create()) : {});

  return {
    description: result?.description ?? null,
    typeSymbol: shortTypeSymbol(result?.typeSymbol) ?? null,
    schemaSource: declared ? 'declared' : 'synthesized',
    schemaError: result?.jsonSchemaError ?? null,
    schema,
  };
}

function normalizeDescriptor(descriptor) {
  const [namespace, ...rest] = descriptor.id.split('#')[1].split('/');
  return {
    endpoint: `${namespace}/${rest.join('/')}`,
    namespace,
    method: rest.join('/'),
    id: descriptor.id,
    package: descriptor.id.split('#')[0],
    service: descriptor.service ?? null,
    description: descriptor.description ?? null,
    // `mode: "stream"` 的端点必须走 WebSocket mux，其余走 HTTP unary。
    transport: descriptor.mode === 'stream' ? 'stream' : 'unary',
    scope: descriptor.scope ?? null,
    parameters: (descriptor.parameters ?? []).map(normalizeParameter),
    result: normalizeResult(descriptor.result),
    sourceLocation: descriptor.sourceLocation ?? null,
  };
}

// ────────────────────────────────────────────────────────────────
// main
// ────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { asar: DEFAULT_ASAR, out: DEFAULT_OUT, quiet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--asar') args.asar = argv[++i];
    else if (arg === '--out') args.out = argv[++i];
    else if (arg === '--quiet') args.quiet = true;
    else if (arg === '--help' || arg === '-h') {
      console.log('usage: node tool/extract_schema.mjs [--asar <path>] [--out <path>] [--quiet]');
      process.exit(0);
    } else throw new Error(`unknown argument: ${arg}`);
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const log = args.quiet ? () => {} : (...a) => console.log(...a);

  if (!fs.existsSync(args.asar)) {
    throw new Error(
      `asar not found: ${args.asar}\n` +
        '  DSH Desktop 的 app.asar 路径因安装方式而异，用 --asar 指定。',
    );
  }

  log(`asar: ${args.asar}`);
  const asar = openAsar(args.asar);
  log(`asar: ${asar.fileCount} entries`);

  let clientBytes;
  try {
    clientBytes = asar.read(CLIENT_JS);
  } finally {
    asar.close();
  }
  const clientText = clientBytes.toString('utf8');
  const { script, prefixBytes } = isolateScript(clientText);
  log(`client.js: ${clientBytes.length} bytes（去掉 ${prefixBytes} 字节填充）`);

  const zodStub = ZodNode.install();
  const contributions = await loadContributions(script, zodStub);
  const descriptors = contributions.flatMap((c) => c.descriptors ?? []);
  log(`mounted remotes: ${contributions.length}, endpoints: ${descriptors.length}`);

  const endpoints = descriptors
    .map(normalizeDescriptor)
    .sort((a, b) => (a.endpoint < b.endpoint ? -1 : a.endpoint > b.endpoint ? 1 : 0));

  const seen = new Set();
  for (const endpoint of endpoints) {
    if (seen.has(endpoint.endpoint)) {
      throw new Error(`duplicate endpoint: ${endpoint.endpoint}`);
    }
    seen.add(endpoint.endpoint);
  }

  const namespaces = [...new Set(endpoints.map((e) => e.namespace))].sort();
  const declared = endpoints.filter((e) => e.result.schemaSource === 'declared').length;

  const output = {
    $comment:
      '由 tool/extract_schema.mjs 从 DSH Desktop 的 app.asar 生成，不要手改。' +
      '重跑方式见 lib/src/model/README.md。',
    source: {
      asar: args.asar,
      entry: CLIENT_JS,
      entryBytes: clientBytes.length,
      entrySha256: crypto.createHash('sha256').update(clientBytes).digest('hex'),
      loaderPrefixBytes: prefixBytes,
      endpointCount: endpoints.length,
      remoteCount: contributions.length,
      namespaceCount: namespaces.length,
      // 描述符自带字面量 jsonSchema 的端点数；其余为从 zod 树合成。
      declaredResultSchemas: declared,
    },
    namespaces,
    endpoints,
  };

  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.writeFileSync(args.out, `${JSON.stringify(output, null, 2)}\n`, 'utf8');

  const bytes = fs.statSync(args.out).size;
  log(
    `wrote ${path.relative(REPO_ROOT, args.out)}: ` +
      `${endpoints.length} endpoints / ${namespaces.length} namespaces / ` +
      `${(bytes / 1024).toFixed(0)} KiB`,
  );
  log(`  declared result schemas: ${declared}, synthesized: ${endpoints.length - declared}`);

  // 自检：会话相关端点必须存在，否则生成阶段会静默少产出。
  for (const required of ['session/list', 'job/list', 'workspace/list', 'userQuestions/answer']) {
    if (!seen.has(required)) {
      throw new Error(`self-check failed: missing endpoint ${required}`);
    }
  }
  log('self-check: session/list, job/list, workspace/list, userQuestions/answer present');
}

main().catch((error) => {
  console.error(`extract_schema: ${error.message}`);
  process.exit(1);
});
