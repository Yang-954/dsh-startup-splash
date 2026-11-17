// verify-composition.mjs — 只读校验 desktop profile 的组合是否正常
//
// 用 dshmarket 的 analyzeProfile()（插件市场"诊断"面板同款解析），
// 检查加入启动观察者后：组合是否仍然 ok、有无孤儿/重复条目、hook 行位置。
// 全程只读，不启动 DSH。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROFILE = 'C:/Users/Admin/.dsh/profiles/desktop';
const ASAR = 'C:/Users/Admin/AppData/Local/Programs/DeepSeek Harness/resources/app.asar/dsh';

const check = await import(new URL('file:///' + path.join(PROFILE, 'node_modules/dshmarket/lib/check.js').replace(/\\/g, '/')));
const report = check.analyzeProfile(PROFILE, { dshInstallDir: ASAR, homeDir: 'C:/Users/Admin/.dsh' });

const rows = Array.isArray(report.rows) ? report.rows : [];
const hookIdx = rows.findIndex((r) => r && typeof r.name === 'string' && r.name.includes('dsh-startup-hook'));
const bundles = (report.bundles ?? []).map((b) => b.label ?? b.id ?? String(b));

console.log(JSON.stringify({
  summaryOk: report.summary?.ok ?? null,
  errors: report.summary?.errors ?? [],
  warnings: report.summary?.warnings ?? [],
  rows: rows.length,
  duplicates: report.duplicates?.length ?? 0,
  orphans: report.orphans?.length ?? 0,
  hookRowIndex: hookIdx,
  hookRow: hookIdx >= 0 ? { id: rows[hookIdx].id, name: rows[hookIdx].name } : null,
  bundles: bundles.slice(0, 8),
  bundleCount: bundles.length,
}, null, 2));