const fs = require('fs');
const p = process.argv[2];
let t = fs.readFileSync(p, 'utf8');
if (!t.includes('"dsh-startup-hook"')) {
  t = t.replace(
    /("dsh-skill-mcp-panel": "[^"]+",\n)/,
    '$1    "dsh-startup-hook": "link:D:/yang/日常非项目活动/code/dsh-startup-hook/observer",\n'
  );
  t = t.replace(
    /("@deepseek-ai\/dsh-experimental-auto-review",\n)/,
    '$1        "dsh-startup-hook",\n'
  );
  fs.writeFileSync(p, t, 'utf8');
}
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
console.log('[json] deps含hook=' + !!j.dependencies['dsh-startup-hook'] +
  ' bundles含hook=' + j.dsh.profile.bundles.includes('dsh-startup-hook') +
  ' deps=' + Object.keys(j.dependencies).length +
  ' bundles=' + j.dsh.profile.bundles.length);
