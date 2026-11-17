// simulate.mjs — 用真实观察者数据离线推演面板会显示什么（验证用，不启动任何程序）
//
// 复刻 splash.ps1 的三段模型（进度条与「已激活 N / M」共用同一个时钟）：
//   ① 启动引擎 0→37%   子进程类别出现作低权重地板 + 段内时间缓动（上限 36.4%）
//   ② 加载插件 37→91%  只用计数：active / 预期总数（跨轮缓存 384）
//   ③ 呈现界面 91→100% 就绪 → 窗口可见
//
// 用法：node simulate.mjs [就绪秒数] [窗口延迟秒数]

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const readySec = Number(process.argv[2] ?? 17.2);
const windowDelay = Number(process.argv[3] ?? 1.75);

const W1 = 37, W2 = 54, W3 = 9;
const P1 = W1, P2 = P1 + W2, P3 = P2 + W3;

// 阶段 1 子进程出现时刻（取自实测：main 0.02s / 其余 1.10s / host 1.61s）
const BOOT_KINDS = [
  ['main', 0.02],
  ['gpu-process', 1.10],
  ['renderer', 1.10],
  ['utility', 1.10],
  ['host', 1.61],
];

const file = path.join(os.tmpdir(), 'dsh-startup-hook.jsonl');
let objs = [];
if (fs.existsSync(file)) {
  objs = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim())
    .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
}
const mounts = objs.filter((o) => o.type === 'mount').sort((a, b) => a.at - b.at);
const last = mounts[mounts.length - 1] ?? null;

const MOUNT_AT = 6.09;
const prog = last ? objs.filter((o) => o.type === 'progress' && o.at >= last.at).sort((a, b) => a.at - b.at) : [];
const acts = last ? objs.filter((o) => o.type === 'status' && o.becameActive && o.at >= last.at).sort((a, b) => a.at - b.at) : [];

// 预期总数：模拟跨轮缓存
let predTotal = 384;

const readyAt = readySec;
const windowAt = readyAt + windowDelay;

let lastPct = 0, lastActive = -1, lastActAt = 0, nameShown = '', nameAt = -10000, stallStart = null;
let pi = 0, ai = 0;
const out = [];
let prevStage = null, backwards = 0, maxJump = 0, maxJumpAt = 0;
let inconsistent = 0;   // 阶段②里「数字没动但条在动」的帧数
let prevPctForCheck = -1, prevActiveForCheck = -1;

const total = Math.max(windowAt + 0.5, 18);
for (let t = 0; t <= total; t += 0.13) {
  const seen = BOOT_KINDS.filter(([, at]) => t >= at).length;
  const bootEase = (P1 - 0.6) * (1 - Math.exp(-t / 2.2));
  const bootFloor = 12 * (seen / BOOT_KINDS.length);
  let p = Math.max(bootFloor, bootEase);

  let ps = null, psName = '';
  if (last && t >= MOUNT_AT) {
    const absMs = last.at + (t - MOUNT_AT) * 1000;
    while (pi < prog.length && prog[pi].at <= absMs) pi++;
    ps = pi > 0 ? prog[pi - 1] : null;
    while (ai < acts.length && acts[ai].at <= absMs) ai++;
    psName = ai > 0 ? (acts[ai - 1].name || '') : '';
  }

  let ratio = 0, bulkDone = false;
  if (ps && ps.total > 0) {
    if (ps.total > predTotal) predTotal = ps.total;
    ratio = Math.min(1, ps.active / ps.total);
    if (ps.active > lastActive) { lastActive = ps.active; lastActAt = t; }
    if (psName && t - nameAt >= 0.45) { nameShown = psName; nameAt = t; }
    bulkDone = ratio >= 0.99;
    if (bulkDone && stallStart === null) stallStart = t;
    p = Math.max(p, P1 + W2 * Math.min(1, ps.active / Math.max(1, predTotal)));
  }
  if (stallStart === null && lastActive > 0 && t - lastActAt >= 3) stallStart = t;

  const ready = t >= readyAt;
  const windowSeen = t >= windowAt;
  if (ready) {
    if (windowSeen) p = P3;
    else p = Math.max(p, P2 + (W3 - 1.2) * (1 - Math.exp(-(t - readyAt) / 0.8)));
  }

  const pct = Math.max(lastPct, Math.min(100, p));
  if (pct < lastPct - 1e-9) backwards++;
  const jump = pct - lastPct;
  if (jump > maxJump) { maxJump = jump; maxJumpAt = t; }
  lastPct = pct;

  // 一致性检查：插件阶段（未就绪）里，若百分比动了但计数没动，就是两个时钟
  const actNow = lastActive;
  if (!ready && ps && ps.active === prevActiveForCheck && pct > prevPctForCheck + 0.01) inconsistent++;
  prevPctForCheck = pct; prevActiveForCheck = actNow;

  const stalled = lastActive > 0 && t - lastActAt >= 1.5;
  const nameFresh = t - nameAt <= 0.9;
  const bootStage = seen <= 1 ? '启动主进程' : seen <= 3 ? '启动渲染与工具进程' : seen === 4 ? '启动宿主进程' : '解析配置、装配模块';
  const countText = ps ? ('已激活 ' + ps.active + ' / ' + predTotal) : '';
  let stage, detail;
  if (windowSeen) { stage = '即将完成'; detail = '窗口已呈现'; }
  else if (ready) { stage = '正在呈现界面'; detail = '宿主已就绪，等待窗口'; }
  else if (!ps) { stage = bootStage; detail = '子进程 ' + seen + ' / ' + BOOT_KINDS.length; }
  else if (stalled && bulkDone) { stage = '正在等待服务就绪（MCP 与作用域）'; detail = countText + ' · 已等待 ' + (t - stallStart).toFixed(1) + 's'; }
  else if (nameFresh && nameShown) { stage = '正在激活 ' + nameShown; detail = countText; }
  else { stage = '正在加载插件'; detail = countText; }

  if (stage !== prevStage) {
    out.push('  +' + t.toFixed(2) + 's  ' + pct.toFixed(1).padStart(5) + '%  [' + stage + ']  ' + detail);
    prevStage = stage;
  }
}

console.log('=== 三段模型推演（就绪 ' + readySec + 's，窗口 ' + windowAt.toFixed(1) + 's） ===');
console.log(out.join('\n'));
console.log('');
console.log('=== 校验 ===');
console.log('  进度倒退次数      : ' + backwards + (backwards === 0 ? '  ✅' : '  ❌'));
console.log('  单帧最大跳变      : ' + maxJump.toFixed(2) + ' 点 @ +' + maxJumpAt.toFixed(2) + 's' + (maxJump <= 2.5 ? '  ✅ 平滑' : '  ⚠ 有台阶'));
console.log('  数字不动条却动帧数: ' + inconsistent + (inconsistent === 0 ? '  ✅ 同一个时钟' : '  ❌ 两个时钟'));
console.log('  终值              : ' + lastPct.toFixed(1) + '%');
console.log('  带宽              : 引擎 0~' + P1 + '% / 插件 ' + P1 + '~' + P2 + '% / 界面 ' + P2 + '~' + P3 + '%');