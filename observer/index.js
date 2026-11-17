// index.js — 只读启动进度观察者
//
// 设计红线：
//   * 只读：只调用 loader 的读取接口，从不修改任何 DSH 状态；
//   * 只写：全部输出写进一个独立 jsonl 文件；
//   * 不抛错：所有异常就地吞掉，绝不影响启动；
//   * 不注入：绝不 ctx.provide / ctx.set 任何服务。
//
// 输出行：
//   {type:'mount',   pid, at}
//   {type:'entries', at, count, sample:[...]}   ← loader 条目表快照
//   {type:'step',    at, count, id, name}       ← 每有一个新条目被初始化
//   {type:'error',   at, where, message}

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 输出路径固定为「本包所在目录的上一级 / runtime」——也就是项目里的 runtime\。
// 观察者是以 junction 形式挂在 profile\node_modules\dsh-startup-hook 下的，
// import.meta.url 解析到的是真实路径（junction 会被解析），所以这里拿到的
// 是工作区里的 observer\index.js，上一级就是 dsh-startup-hook\。
//
// 不再依赖 DSH_STARTUP_HOOK_OUT：Electron 主进程会过滤 host 子进程的环境，
// 那个变量根本传不进来（实测），早先因此不得不同时写一份到 %TEMP%。
// 现在用固定路径，运行缓存统一落在 runtime\ 下，不再污染系统临时目录。
const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(HERE, '..', 'runtime', 'observer.jsonl');

try { fs.mkdirSync(path.dirname(OUT), { recursive: true }); } catch { }
let broken = false;

// 每条记录都立刻落盘：常开一个文件描述符，用 writeSync 追加。
//
// 之前是「攒 32 条 + 250ms 定时器异步刷」，但插件加载期 Node 的事件循环会被同步
// 初始化工作长时间占满，定时器根本不触发 —— 实测观察者 20.75s 就激活了，面板却
// 到 28.61s 才读到文件，而且第一次读到就已经 327/366，进度条完全失去意义。
//
// writeSync 到已打开的 fd 只是一次内存到内核的拷贝（微秒级），比 appendFileSync
// 每次 open/close 便宜得多；384 条全量写实测可以忽略不计（见 tools/compare-observer-cost.ps1）。
let fd = null;
try { fd = fs.openSync(OUT, 'a'); } catch { fd = null; }

function write(obj) {
  if (broken || fd === null) { if (fd === null) broken = true; return; }
  const line = JSON.stringify({ ...obj, pid: process.pid }) + '\n';
  try { fs.writeSync(fd, line); } catch { broken = true; }
}

export const name = 'startup-hook';

/** 从各种可能的形状里取出「已加载条目数」和若干条目名。 */
function readEntries(loader) {
  if (!loader) return null;
  const candidates = [
    ['entries', loader.entries],
    ['store', loader.store],
    ['config', loader.config],
    ['tree', loader.tree],
  ];
  for (const [key, value] of candidates) {
    if (value === undefined || value === null) continue;
    let list = null;
    if (typeof value.values === 'function') {
      try { list = [...value.values()]; } catch { list = null; }
    } else if (Array.isArray(value)) {
      list = value;
    } else if (value instanceof Map || value instanceof Set) {
      try { list = [...value]; } catch { list = null; }
    }
    if (!list) continue;
    const names = [];
    for (const item of list.slice(0, 400)) {
      if (item === null || item === undefined) { names.push(String(item)); continue; }
      if (typeof item === 'string') { names.push(item); continue; }
      const id = item.id ?? item.options?.id ?? item.name ?? item.options?.name;
      if (typeof id === 'string') names.push(id);
    }
    return { key, count: list.length, names };
  }
  return null;
}

export function apply(ctx) {
  try {
    write({ type: 'mount', at: Date.now(), pid: process.pid });

    const loader = (() => {
      try { return ctx.get?.('loader') ?? ctx.loader ?? null; } catch { return null; }
    })();

    if (!loader) {
      write({ type: 'error', at: Date.now(), where: 'mount', message: 'loader service not reachable' });
      return;
    }

    const snapshot = readEntries(loader);
    if (snapshot) {
      write({ type: 'entries', at: Date.now(), count: snapshot.count, key: snapshot.key, sample: snapshot.names.slice(0, 12) });
    } else {
      write({ type: 'error', at: Date.now(), where: 'mount', message: 'loader entries shape unknown' });
    }

    // 探测 loader 的可用字段（一次即可，帮助确认 entries 语义）
    try {
      const own = Object.keys(loader).slice(0, 30);
      write({ type: 'loader-keys', at: Date.now(), keys: own });
      for (const key of own) {
        const v = loader[key];
        if (v && typeof v === 'object') {
          const kind = Array.isArray(v) ? `array(${v.length})` : (v instanceof Map ? `map(${v.size})` : (v instanceof Set ? `set(${v.size})` : 'object'));
          write({ type: 'loader-field', at: Date.now(), key, kind });
          // 再深一层：看看它自己的键，条目表很可能藏在里面
          try {
            const sub = Object.keys(v).slice(0, 24);
            if (sub.length) write({ type: 'loader-subkeys', at: Date.now(), key, subkeys: sub });
          } catch { /* ignore */ }
        }
      }
    } catch (error) {
      write({ type: 'error', at: Date.now(), where: 'probe', message: String(error?.message ?? error) });
    }

    // 探测 loader.root：tree / data 可能就是「条目树」与「激活状态」
    try {
      const root = loader.root;
      for (const key of ['tree', 'data']) {
        const v = root?.[key];
        if (!v) continue;
        let count = null;
        let sample = [];
        if (typeof v.size === 'number') count = v.size;
        else if (Array.isArray(v)) count = v.length;
        try {
          if (typeof v.keys === 'function') {
            const keys = [...v.keys()].slice(0, 10);
            sample = keys.map((k) => String(k));
          } else if (Array.isArray(v)) {
            sample = v.slice(0, 10).map((x) => (x && typeof x === 'object' ? String(x.id ?? x.name ?? JSON.stringify(x).slice(0, 40)) : String(x)));
          }
        } catch { /* ignore */ }
        write({ type: 'root-shape', at: Date.now(), key, count, sample });
        // 若像 Map，统计其中「已激活」的可数项
        if (typeof v.values === 'function') {
          try {
            const vals = [...v.values()];
            const states = {};
            for (const item of vals) {
              const st = item?.state ?? item?.fiber?.state ?? item?.status;
              const key2 = st === undefined ? 'undefined' : String(st);
              states[key2] = (states[key2] ?? 0) + 1;
            }
            write({ type: 'root-states', at: Date.now(), key, total: vals.length, states });
          } catch (error) {
            write({ type: 'error', at: Date.now(), where: `root.${key}.values`, message: String(error?.message ?? error) });
          }
        }
      }
    } catch (error) {
      write({ type: 'error', at: Date.now(), where: 'root-probe', message: String(error?.message ?? error) });
    }

    // ── 真实激活进度：订阅 fiber 生命周期事件 ──
    // internal/plugin : fiber 创建时发一次 (fiber)
    // internal/status : 状态迁移时发 (fiber, oldState)  ← 真正的进度信号
    // internal/config : 配置解析 (fiber)
    // state: 0=pending 2=active 3=error 4=disposed
    const fibers = new Map(); // uid -> { name, state, at }
    let seq = 0;

    const nameOf = (fiber) => {
      try {
        return fiber?.runtime?.name || fiber?.config?.name || fiber?.ctx?.config?.name || '';
      } catch { return ''; }
    };

    const emitProgress = (reason) => {
      const counts = { 0: 0, 2: 0, 3: 0, other: 0 };
      for (const p of fibers.values()) {
        if (p.state === 0) counts[0] += 1;
        else if (p.state === 2) counts[2] += 1;
        else if (p.state === 3) counts[3] += 1;
        else counts.other += 1;
      }
      write({
        type: 'progress', at: Date.now(), reason,
        total: fibers.size, active: counts[2], pending: counts[0], error: counts[3], other: counts.other,
      });
    };

    const target = ctx.root ?? ctx;
    target.on('internal/plugin', (fiber) => {
      try {
        const uid = fiber?.uid;
        if (uid === undefined || uid === null) return;
        const prev = fibers.get(uid);
        fibers.set(uid, { name: nameOf(fiber) || prev?.name || '', state: fiber?.state ?? 0, at: Date.now() });
        seq += 1;
      } catch (error) {
        write({ type: 'error', at: Date.now(), where: 'internal/plugin', message: String(error?.message ?? error) });
      }
    });

    target.on('internal/status', (fiber, oldState) => {
      try {
        const uid = fiber?.uid;
        if (uid === undefined || uid === null) return;
        const prev = fibers.get(uid);
        const name = nameOf(fiber) || prev?.name || '';
        const state = fiber?.state ?? 0;
        const becameActive = state === 2 && prev?.state !== 2;
        fibers.set(uid, { name, state, at: Date.now() });
        // 只记录「变为 active」这一种迁移——其它迁移对进度没有价值，
        // 全记会把启动关键路径拖慢（实测同步写 + 全量记录 ≈ +0.78s）。
        if (!becameActive) return;
        write({
          type: 'status', at: Date.now(), uid, name,
          oldState: oldState ?? null, state,
          becameActive: true, total: fibers.size,
        });
        emitProgress('activated');
      } catch (error) {
        write({ type: 'error', at: Date.now(), where: 'internal/status', message: String(error?.message ?? error) });
      }
    });

    write({ type: 'watching', at: Date.now(), events: ['internal/plugin', 'internal/status', 'internal/config'] });
  } catch (error) {
    try { write({ type: 'error', at: Date.now(), where: 'apply', message: String(error?.message ?? error) }); } catch { /* ignore */ }
  }
}
