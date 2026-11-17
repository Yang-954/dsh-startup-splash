// probe-hook.mjs — 只读分析观察者 jsonl 的时间结构（诊断用，不启动任何程序）
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const f = path.join(os.tmpdir(), 'dsh-startup-hook.jsonl');
if (!fs.existsSync(f)) { console.log('文件不存在: ' + f); process.exit(0); }

const t = (ms) => {
  const d = new Date(ms);
  return d.toLocaleTimeString('zh-CN', { hour12: false }) + '.' + String(ms % 1000).padStart(3, '0');
};

const objs = fs.readFileSync(f, 'utf8').split('\n').filter((l) => l.trim())
  .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);

const mounts = objs.filter((o) => o.type === 'mount').sort((a, b) => a.at - b.at);
console.log('文件路径   : ' + f);
console.log('总记录数   : ' + objs.length);
console.log('mount 记录 : ' + mounts.length + ' 条');
for (const m of mounts) console.log('   pid=' + String(m.pid).padEnd(6) + ' ' + t(m.at));

const first = objs[0];
console.log('第一条记录 : type=' + first.type + '  ' + t(first.at));

const lastM = mounts[mounts.length - 1];
const acts = objs.filter((o) => o.type === 'status' && o.becameActive && o.at >= lastM.at)
  .sort((a, b) => a.at - b.at);
console.log('最后一次 mount 之后 becameActive: ' + acts.length + ' 条');
if (acts.length) {
  console.log('   第 1 条 : ' + t(acts[0].at) + '  ' + (acts[0].name || '(未命名)'));
  const mid = acts[Math.floor(acts.length / 2)];
  console.log('   中间    : ' + t(mid.at) + '  ' + (mid.name || '(未命名)'));
  const last = acts[acts.length - 1];
  console.log('   最后 1 条: ' + t(last.at) + '  ' + (last.name || '(未命名)'));
  const span = (last.at - acts[0].at) / 1000;
  console.log('   跨度    : ' + span.toFixed(2) + 's');
}

const progs = objs.filter((o) => o.type === 'progress' && o.at >= lastM.at).sort((a, b) => a.at - b.at);
console.log('最后一次 mount 之后 progress 快照: ' + progs.length + ' 条');
if (progs.length) {
  const p0 = progs[0];
  console.log('   首个快照: ' + t(p0.at) + '  active ' + p0.active + '/' + p0.total);
  const pN = progs[progs.length - 1];
  console.log('   末个快照: ' + t(pN.at) + '  active ' + pN.active + '/' + pN.total);
}