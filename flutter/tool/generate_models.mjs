#!/usr/bin/env node
/**
 * 从 tool/schema.json 生成 Dart 数据类。
 *
 * 设计取舍：
 * - **手写 fromJson/toJson**，不引入 json_serializable / build_runner。
 *   传输层刻意保持零代码生成依赖，build_runner 会让 `dart test` 变慢且引入版本耦合。
 * - **只生成实际用到的端点**（session / job / workspace / userQuestions / fileReferences / skills）。
 *   其余留在 schema.json 里备用，避免死代码。
 * - **每个类保留 `extra`**：协议会演进，schema 未覆盖的字段不能丢。
 * - **枚举带 unknown 兜底**：新枚举值不能让客户端崩溃。
 *
 * 用法：node tool/generate_models.mjs
 * 输出：lib/src/model/generated.dart
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

/** 只生成这些端点涉及的模型。 */
const WANTED_ENDPOINTS = [
  'session/list',
  'session/state',
  'session/create',
  'session/prompt',
  'session/rename',
  'session/fork',
  'session/cancel',
  'session/events',
  'session/follow',
  'session/page',
  'session/search',
  'session/projections',
  'job/list',
  'job/follow',
  'job/kill',
  'workspace/follow',
  'userQuestions/answer',
  'userQuestions/attachWait',
  'fileReferences/list',
  'skills/list',
];

const schema = JSON.parse(readFileSync(join(here, 'schema.json'), 'utf8'));
const byEndpoint = new Map(schema.endpoints.map((e) => [e.endpoint, e]));

// ────────────────────────────────────────────────────────────── 命名

const RESERVED = new Set([
  'class', 'enum', 'switch', 'case', 'default', 'for', 'while', 'do', 'if',
  'else', 'return', 'var', 'final', 'const', 'new', 'this', 'super', 'extends',
  'implements', 'with', 'in', 'is', 'as', 'null', 'true', 'false', 'void',
  'int', 'double', 'num', 'bool', 'String', 'Object', 'dynamic', 'List', 'Map',
  'operator', 'get', 'set', 'factory', 'static', 'abstract', 'interface',
  'assert', 'break', 'continue', 'try', 'catch', 'finally', 'throw', 'rethrow',
  'yield', 'async', 'await', 'sync', 'external', 'covariant', 'late', 'required',
]);

function pascal(s) {
  const cleaned = String(s).replace(/[^A-Za-z0-9]+(.)?/g, (_, c) => (c ? c.toUpperCase() : ''));
  const out = cleaned.charAt(0).toUpperCase() + cleaned.slice(1);
  return out === '' ? 'Value' : out;
}

function camel(s) {
  const p = pascal(s);
  const out = p.charAt(0).toLowerCase() + p.slice(1);
  return RESERVED.has(out) ? `${out}Value` : out;
}

// ────────────────────────────────────────────────────── 类型推断

/** 从 JSON Schema 推断 Dart 类型。返回 {type, isEnum, enumName, enumValues} */
function inferType(node, hintName) {
  if (!node || typeof node !== 'object') return { type: 'Object?' };

  // enum
  if (Array.isArray(node.enum) && node.enum.every((v) => typeof v === 'string')) {
    return {
      type: pascal(hintName),
      isEnum: true,
      enumName: pascal(hintName),
      enumValues: node.enum,
    };
  }

  // oneOf / anyOf：取第一个非 null 分支；若含 null 则整体可空
  const variants = node.oneOf ?? node.anyOf;
  if (Array.isArray(variants)) {
    const nonNull = variants.filter((v) => v && v.type !== 'null' && v.const !== null);
    const hasNull = variants.some((v) => v && (v.type === 'null' || v.const === null));
    if (nonNull.length === 0) return { type: 'Object?' };
    const first = inferType(nonNull[0], hintName);
    if (hasNull && !first.type.endsWith('?')) {
      first.type = `${first.type}?`;
      first.forceNullable = true;
    }
    return first;
  }

  // const（单值）
  if (typeof node.const === 'string') {
    return { type: 'String' };
  }

  const t = node.type;
  if (Array.isArray(t)) {
    // type: ["string","null"]
    const nonNull = t.filter((x) => x !== 'null');
    const hasNull = t.includes('null');
    const inner = inferType({ ...node, type: nonNull[0] }, hintName);
    if (hasNull && !inner.type.endsWith('?')) inner.type = `${inner.type}?`;
    return inner;
  }

  switch (t) {
    case 'string':
      return { type: 'String' };
    case 'integer':
      return { type: 'int' };
    case 'number':
      return { type: 'num' };
    case 'boolean':
      return { type: 'bool' };
    case 'null':
      return { type: 'Object?' };
    case 'array': {
      const inner = inferType(node.items, `${hintName}Item`);
      // 元素类型去掉可空标记：List<T?> 会破坏 .map/.toJson 链。
      const innerType = inner.type.replace(/\?$/, '');
      return { type: `List<${innerType}>`, isArray: true, inner, elementSchema: node.items };
    }
    case 'object':
    default:
      return { type: 'Map<String, Object?>', isObject: true, objectSchema: node };
  }
}

// ──────────────────────────────────────────────── 类收集（按需生成）

/** 已生成的类：name -> { fields, description } */
const classes = new Map();
/** 已生成的枚举：name -> values[] */
const enums = new Map();
const queue = [];

function classNameFor(hint) {
  return pascal(hint);
}

/**
 * 把一个 object schema 注册成一个类，返回类名。
 * 只有"具名"的 object 才会生成类；匿名的用 Map。
 */
function registerObject(schemaNode, hint, description) {
  const name = classNameFor(hint);
  if (classes.has(name) || enums.has(name)) return name;

  const props = schemaNode.properties ?? {};
  const required = new Set(schemaNode.required ?? []);
  const fields = [];
  classes.set(name, { fields, description, ready: false });

  for (const [key, propSchema] of Object.entries(props)) {
    const fieldName = camel(key);
    const hintForChild = `${name}${pascal(key)}`;
    const info = inferType(propSchema, hintForChild);
    const isRequired = required.has(key);
    let type = info.type;

    // 可空性：非 required 一律可空（除非已经是 nullable）
    if (!isRequired && !type.endsWith('?')) type = `${type}?`;

    // 嵌套对象：生成类（有 properties 且字段数 > 0）
    if (info.isObject && propSchema.properties && Object.keys(propSchema.properties).length > 0) {
      const childName = registerObject(propSchema, hintForChild, propSchema.description);
      type = type.endsWith('?') ? `${childName}?` : childName;
    }

    // 数组元素是对象：生成类
    if (info.isArray && info.elementSchema) {
      const es = info.elementSchema;
      // 注意：此处 `type` 形如 `List<X>`，用 `type.includes('?')` 判断会命中
      // 内层的可空标记，导致元素被错误地加上 `?`（进而让 `.map(e => e.toJson())`
      // 报 unchecked_use_of_nullable_value）。必须只看**外层**是否可空。
      const outerNullable = type.endsWith('?');
      if (es && es.type === 'object' && es.properties && Object.keys(es.properties).length > 0) {
        const childName = registerObject(es, `${hintForChild}Item`, es.description);
        type = `List<${childName}>${outerNullable ? '?' : ''}`;
      } else if (es && Array.isArray(es.enum)) {
        const childName = registerEnum(es, `${hintForChild}Item`);
        type = `List<${childName}>${outerNullable ? '?' : ''}`;
      }
    }

    // 枚举字段
    if (info.isEnum) {
      const enumName = registerEnum(propSchema, hintForChild);
      type = type.endsWith('?') ? `${enumName}?` : enumName;
    }

    fields.push({
      jsonKey: key,
      name: fieldName,
      type,
      description: propSchema.description ?? '',
    });
  }

  classes.set(name, { fields, description, ready: true });
  return name;
}

function registerEnum(schemaNode, hint) {
  const name = pascal(hint);
  if (enums.has(name)) return name;
  enums.set(name, schemaNode.enum ?? []);
  return name;
}

// ────────────────────────────────────────────────────────── 主流程

const endpointModels = [];

for (const endpoint of WANTED_ENDPOINTS) {
  const spec = byEndpoint.get(endpoint);
  if (!spec) {
    console.warn(`  ! 跳过（schema 中不存在）: ${endpoint}`);
    continue;
  }

  // 参数模型
  const params = spec.parameters ?? [];
  const paramClassNames = [];
  for (const p of params) {
    const s = p.schema;
    if (!s) continue;
    // 只给有实际字段的对象建类；`_request` 这类空对象跳过
    if (s.type === 'object' && s.properties && Object.keys(s.properties).length > 0) {
      const n = registerObject(s, `${pascal(spec.namespace)}${pascal(spec.method)}Request`, p.description);
      paramClassNames.push(n);
    }
  }

  // 结果模型
  const resultClassNames = [];
  const rs = spec.result?.schema;
  if (rs) {
    if (rs.type === 'object' && rs.properties && Object.keys(rs.properties).length > 0) {
      const n = registerObject(rs, `${pascal(spec.namespace)}${pascal(spec.method)}Value`, spec.result.description);
      resultClassNames.push(n);
    }
  }

  endpointModels.push({
    endpoint,
    transport: spec.transport,
    description: spec.description ?? '',
    request: paramClassNames,
    result: resultClassNames,
  });
}

// ─────────────────────────────────────────────────────── 生成 Dart

const lines = [];
const w = (s = '') => lines.push(s);

w('// GENERATED FILE — 不要手改。');
w('//');
w('// 生成命令：node tool/generate_models.mjs');
w('// 数据来源：tool/schema.json（从 DSH app.asar 提取的 endpoint descriptor）');
w(`// 生成时间：${new Date().toISOString()}`);
w('//');
w('// 设计说明：');
w('// - 手写 fromJson/toJson，不依赖 json_serializable / build_runner');
w('// - 每个类保留 `extra`，存 schema 未覆盖的字段（协议会演进，不能丢数据）');
w('// - 枚举带 unknown 兜底，新枚举值不会导致崩溃');
w('');
w('// ignore_for_file: type=lint, unused_field, unused_element');
w('');
w("part of 'models.dart';");
w('');

// 枚举
for (const [name, values] of [...enums.entries()].sort()) {
  w(`/// ${name}`);
  w(`enum ${name} {`);
  for (const v of values) {
    w(`  ${camel(v)},`);
  }
  w('  /// 未知值兜底 —— 协议新增枚举值时不会崩溃。');
  w('  unknown,');
  w('}');
  w('');
  w(`extension ${name}Codec on ${name} {`);
  w(`  String get wire => switch (this) {`);
  for (const v of values) {
    w(`    ${name}.${camel(v)} => '${v}',`);
  }
  w(`    ${name}.unknown => '',`);
  w('  };');
  w('');
  w(`  static ${name} fromWire(Object? raw) => switch (raw) {`);
  for (const v of values) {
    w(`    '${v}' => ${name}.${camel(v)},`);
  }
  w(`    _ => ${name}.unknown,`);
  w('  };');
  w('}');
  w('');
}

// 类
for (const [name, meta] of [...classes.entries()].sort()) {
  if (!meta.ready) continue;
  const fields = meta.fields;
  if (fields.length === 0) continue;

  if (meta.description) {
    for (const line of wrapComment(meta.description)) w(line);
  }
  w(`class ${name} {`);
  w(`  const ${name}({`);
  for (const f of fields) {
    if (f.type.endsWith('?')) {
      w(`    this.${f.name},`);
    } else {
      w(`    required this.${f.name},`);
    }
  }
  w('    this.extra = const {},');
  w('  });');
  w('');
  for (const f of fields) {
    if (f.description) {
      for (const line of wrapComment(f.description, '  ')) w(line);
    }
    w(`  final ${f.type} ${f.name};`);
  }
  w('');
  w('  /// schema 未覆盖的字段（协议演进时保留，不丢数据）。');
  w('  final Map<String, Object?> extra;');
  w('');

  // fromJson
  w(`  factory ${name}.fromJson(Map<String, Object?> json) {`);
  w(`    const known = <String>{`);
  for (const f of fields) w(`      '${f.jsonKey}',`);
  w('    };');
  w('    final rest = <String, Object?>{};');
  w('    for (final e in json.entries) {');
  w('      if (!known.contains(e.key)) rest[e.key] = e.value;');
  w('    }');
  w(`    return ${name}(`);
  for (const f of fields) {
    w(`      ${f.name}: ${readExpr(f)},`);
  }
  w('      extra: rest,');
  w('    );');
  w('  }');
  w('');

  // toJson
  w('  Map<String, Object?> toJson() {');
  w('    final out = <String, Object?>{};');
  for (const f of fields) {
    w(`    ${writeStmt(f)}`);
  }
  w('    out.addAll(extra);');
  w('    return out;');
  w('  }');
  w('}');
  w('');
}

// 端点索引（便于调用方知道哪个端点走哪个载体）
w('/// 端点载体索引 —— 双载具是协议强制要求（见 docs/60-protocol-feasibility.md §5.1）。');
w('///');
w('/// 走错载体分别得到 `gateway/signature-invalid`（unary 走 mux）与 404（stream 走 HTTP）。');
w('enum EndpointTransport { unary, stream }');
w('');
w('const Map<String, EndpointTransport> endpointTransports = {');
for (const m of endpointModels) {
  const t = m.transport === 'stream' ? 'EndpointTransport.stream' : 'EndpointTransport.unary';
  w(`  '${m.endpoint}': ${t},`);
}
w('};');
w('');

writeFileSync(join(root, 'lib', 'src', 'model', 'generated.dart'), lines.join('\n'), 'utf8');

// ─────────────────────────────────────────────────────── 读写表达式

function readExpr(f) {
  const k = `json['${f.jsonKey}']`;
  const t = f.type;
  const base = t.replace(/\?$/, '');
  const nullable = t.endsWith('?');

  // 列表
  if (base.startsWith('List<')) {
    const inner = base.slice(5, -1).replace(/\?$/, '');
    // 裸 Map 元素（schema 里是 additionalProperties:true 的对象）
    if (inner.startsWith('Map<')) {
      return nullable ? `asMapList(${k})` : `asMapList(${k}) ?? const []`;
    }
    if (['String', 'int', 'num', 'double', 'bool'].includes(inner)) {
      return `asListRaw<${inner}>(${k})`;
    }
    if (enums.has(inner)) {
      return nullable
        ? `asEnumListOrNull<${inner}>(${k}, ${inner}Codec.fromWire)`
        : `asEnumList<${inner}>(${k}, ${inner}Codec.fromWire)`;
    }
    if (classes.has(inner)) {
      return nullable
        ? `asListOrNull<${inner}>(${k}, ${inner}.fromJson)`
        : `asList<${inner}>(${k}, ${inner}.fromJson)`;
    }
    return `asListRaw<Object?>(${k})`;
  }

  // 枚举
  if (enums.has(base)) {
    return nullable
      ? `(${k} == null ? null : ${base}Codec.fromWire(${k}))`
      : `${base}Codec.fromWire(${k})`;
  }

  // 模型
  if (classes.has(base)) {
    return nullable
      ? `asModel<${base}>(${k}, ${base}.fromJson)`
      : `asModel<${base}>(${k}, ${base}.fromJson)!`;
  }

  // 基础类型
  switch (base) {
    case 'String':
      return nullable ? `asString(${k})` : `asString(${k})!`;
    case 'int':
      return nullable ? `asInt(${k})` : `asInt(${k})!`;
    case 'num':
    case 'double':
      return nullable ? `asNum(${k})` : `asNum(${k})!`;
    case 'bool':
      return nullable ? `asBool(${k})` : `asBool(${k})!`;
    case 'DateTime':
      return nullable ? `asDateTime(${k})` : `asDateTime(${k})!`;
  }
  if (base.startsWith('Map<')) {
    return nullable ? `asMap(${k})` : `asMapOrEmpty(${k})`;
  }
  return nullable ? k : `${k}!`;
}

function writeStmt(f) {
  const v = f.name;
  const t = f.type;
  const base = t.replace(/\?$/, '');
  const key = `'${f.jsonKey}'`;
  const nullable = t.endsWith('?');

  // 关键：Dart 不对**公开字段**做类型提升（non-promo public field），
  // 所以 `if (x != null) out[k] = x.toJson()` 会报 unchecked_use_of_nullable_value。
  // 解法是先赋给局部变量再判空 —— 局部变量可被提升。
  const local = `local${v.charAt(0).toUpperCase()}${v.slice(1)}`;

  if (nullable) {
    if (enums.has(base)) {
      return `final ${local} = ${v}; if (${local} != null) out[${key}] = ${local}.wire;`;
    }
    if (classes.has(base)) {
      return `final ${local} = ${v}; if (${local} != null) out[${key}] = ${local}.toJson();`;
    }
    if (base === 'DateTime') {
      return `final ${local} = ${v}; if (${local} != null) out[${key}] = ${local}.millisecondsSinceEpoch;`;
    }
    if (base.startsWith('List<')) {
      const inner = base.slice(5, -1).replace(/\?$/, '');
      if (classes.has(inner)) {
        return `final ${local} = ${v}; if (${local} != null) out[${key}] = ${local}.map((e) => e.toJson()).toList();`;
      }
      if (enums.has(inner)) {
        return `final ${local} = ${v}; if (${local} != null) out[${key}] = ${local}.map((e) => e.wire).toList();`;
      }
    }
    return `final ${local} = ${v}; if (${local} != null) out[${key}] = ${local};`;
  }

  if (enums.has(base)) return `out[${key}] = ${v}.wire;`;
  if (classes.has(base)) return `out[${key}] = ${v}.toJson();`;
  if (base === 'DateTime') return `out[${key}] = ${v}.millisecondsSinceEpoch;`;
  if (base.startsWith('List<')) {
    const inner = base.slice(5, -1).replace(/\?$/, '');
    if (classes.has(inner)) return `out[${key}] = ${v}.map((e) => e.toJson()).toList();`;
    if (enums.has(inner)) return `out[${key}] = ${v}.map((e) => e.wire).toList();`;
  }
  return `out[${key}] = ${v};`;
}

function wrapComment(text, indent = '') {
  const clean = String(text).replace(/\s+/g, ' ').trim();
  const max = 76 - indent.length;
  const words = clean.split(' ');
  const out = [];
  let cur = '';
  for (const word of words) {
    if (cur.length + word.length + 1 > max) {
      out.push(`${indent}/// ${cur}`);
      cur = word;
    } else {
      cur = cur === '' ? word : `${cur} ${word}`;
    }
  }
  if (cur) out.push(`${indent}/// ${cur}`);
  return out.length > 0 ? out : [`${indent}///`];
}

console.log(`生成完成：lib/src/model/generated.dart`);
console.log(`  类：${[...classes.values()].filter((c) => c.ready && c.fields.length > 0).length}`);
console.log(`  枚举：${enums.size}`);
console.log(`  端点：${endpointModels.length}`);
