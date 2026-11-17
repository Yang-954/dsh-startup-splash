const fs = require('fs');
const p = process.argv[2];
let t = fs.readFileSync(p, 'utf8');
const before = t;
t = t.replace(/^\s*"dsh-startup-hook": "[^"]*",\n/m, '');
t = t.replace(/^\s*"dsh-startup-hook",\n/m, '');
if (t !== before) fs.writeFileSync(p, t, 'utf8');
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
console.log('[json] deps含hook=' + !!j.dependencies['dsh-startup-hook'] +
  ' bundles含hook=' + j.dsh.profile.bundles.includes('dsh-startup-hook') +
  ' deps=' + Object.keys(j.dependencies).length +
  ' bundles=' + j.dsh.profile.bundles.length);
