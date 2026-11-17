# test-hook.ps1 — 在【临时 profile】里验证观察者，不碰 desktop profile
#
# 关键安全点：
#   * 用 DSH_HOME 覆盖到工作区内的 test-home，desktop profile 完全不参与；
#   * 用独立端口，避免与正在运行的 desktop 实例抢 3080；
#   * 跑完自动清理进程。
#
# 用法：pwsh -NoProfile -File tools\test-hook.ps1

param([switch]$First)

$ErrorActionPreference = 'Stop'
# 本脚本在 tools\ 下，$here 指向项目根；测试产物全部落在 runtime\ 里
$here = Split-Path $PSScriptRoot -Parent
$runtime = Join-Path $here 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$testHome = Join-Path $runtime 'test-home'
$profileDir = Join-Path $testHome 'profiles\hook-test'
$out = Join-Path $runtime 'hook-output.jsonl'
$stdout = Join-Path $runtime 'hook-stdout.txt'
$stderr = Join-Path $runtime 'hook-stderr.txt'
$report = Join-Path $runtime ('hook-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$t) { Write-Host $t; $lines.Add($t) }

# ---- 建临时 profile ----
New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
$bundles = if ($First) {
    '["dsh-startup-hook", "@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]'
} else {
    '["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-startup-hook"]'
}
@"
{
  "name": "hook-test-profile",
  "version": "0.0.0",
  "private": true,
  "dependencies": {},
  "dsh": { "profile": { "bundles": $bundles } }
}
"@ | Out-File -Encoding utf8 (Join-Path $profileDir 'package.json')
"[]" | Out-File -Encoding utf8 (Join-Path $profileDir 'cordis.yml')
$nm = Join-Path $profileDir 'node_modules'
New-Item -ItemType Directory -Force -Path $nm | Out-Null
$link = Join-Path $nm 'dsh-startup-hook'
if (Test-Path $link) { Remove-Item $link -Force }
New-Item -ItemType Junction -Path $link -Target (Join-Path $here 'observer') | Out-Null
Say ('junction: ' + $link + ' -> ' + (Get-Item $link).Target)

if (Test-Path $out) { Remove-Item $out -Force }
Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

# DSH CLI：从安装目录探测，不写死路径
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\common.ps1')
$dsh = Find-DshCli
if (-not $dsh) { throw '找不到 dsh CLI。请设置 DSH_INSTALL_DIR 环境变量。' }
$env:DSH_HOME = $testHome
$env:DSH_STARTUP_HOOK_OUT = $out

Say 'starting hook-test profile on port 3099 ...'
$t0 = Get-Date
$proc = Start-Process -FilePath $dsh -ArgumentList @('--profile', 'hook-test', '--port', '3099', '--no-open') `
    -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr

# 观察 45 秒，看 jsonl 是否产生
$deadline = (Get-Date).AddSeconds(45)
$seen = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $out) {
        $n = (Get-Content $out -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count
        if ($n -gt $seen) { $seen = $n; Say ('  +{0,5:N1}s  hook lines: {1}' -f ((Get-Date) - $t0).TotalSeconds, $n) }
        if ($n -ge 20) { break }
    }
}

Say ''
Say '=== hook output ==='
if (Test-Path $out) {
    $all = Get-Content $out | Where-Object { $_.Trim() }
    Say ('  total lines: ' + $all.Count)
    $types = @{}
    foreach ($l in $all) { try { $o = $l | ConvertFrom-Json; $types[$o.type] = 1 + ($types[$o.type] ?? 0) } catch {} }
    $types.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { Say ('  {0,-10} {1}' -f $_.Key, $_.Value) }
    Say ''
    Say '  first 6 lines:'
    $all | Select-Object -First 6 | ForEach-Object { Say ('    ' + $_.Substring(0, [Math]::Min(200, $_.Length))) }
    Say ''
    Say '  last 4 lines:'
    $all | Select-Object -Last 4 | ForEach-Object { Say ('    ' + $_.Substring(0, [Math]::Min(200, $_.Length))) }
} else { Say '  NO OUTPUT FILE — hook did not run' }

Say ''
Say '=== host stdout (first 12) ==='
Get-Content $stdout -TotalCount 12 -ErrorAction SilentlyContinue | ForEach-Object { Say ('  | ' + $_) }
Say '=== stderr (first 12) ==='
Get-Content $stderr -TotalCount 12 -ErrorAction SilentlyContinue | ForEach-Object { Say ('  ! ' + $_) }

# 清理
Say ''
Say 'stopping test instance ...'
try { $proc | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Milliseconds 800
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'hook-test' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Say ('  killed ' + $_.ProcessId) } catch { } }
$env:DSH_HOME = $null
$env:DSH_STARTUP_HOOK_OUT = $null
Say ('report: ' + $report)
$lines | Out-File -Encoding utf8 $report