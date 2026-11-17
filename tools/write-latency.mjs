// write-latency.mjs — 测观察者「事件发生 → 文件可见」的延迟
//
// 做法：轮询 hook 文件，记录它首次出现的墙钟时刻，再读文件里的 mount 时间戳，
// 两者之差就是「观察者激活 → 磁盘可见」的延迟。理想值 < 300ms。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const file = process.argv[2] || path.join(os.tmpdir(), 'dsh-startup-hook.jsonl');
const startedAt = Date.now();
const deadline = startedAt + 60000;
let seenAt = null;

while (Date.now() < deadline) {
  if (fs.existsSync(file) && fs.statSync(file).size > 0) { seenAt = Date.now(); break; }
  await new Promise((r) => setTimeout(r, 100));
}

if (seenAt === null) { console.log('60s 内没出现文件: ' + file); process.exit(1); }

const txt = fs.readFileSync(file, 'utf8');
const mounts = txt.split('\n').filter((l) => l.includes('"type":"mount"'))
  .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const mountAt = mounts.length ? mounts[mounts.length - 1].at : null;

console.log('文件: ' + file);
console.log('轮询开始时间戳 : ' + startedAt);
console.log('文件首次可见   : ' + seenAt);
console.log('文件内 mount.at: ' + (mountAt ?? '无'));
if (mountAt) {
  const latency = seenAt - mountAt;
  console.log('延迟(mount→可见): ' + latency + ' ms ' + (latency < 400 ? '✅ 即时' : '⚠ 有缓冲'));
}