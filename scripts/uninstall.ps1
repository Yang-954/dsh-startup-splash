# uninstall.ps1 — 从 DSH profile 移除启动观察者（回到零侵入状态）
#
# 移除三处痕迹：
#   1. package.json 的 dependencies 里的 dsh-startup-hook
#   2. package.json 的 bundles 里的 dsh-startup-hook
#   3. profile\node_modules\dsh-startup-hook 的 junction
#
# 前提：DSH 已完全退出。
#
# 用法：pwsh -NoProfile -File scripts\uninstall.ps1 [-ProfileName desktop]
param([string]$ProfileName = 'desktop')

$ErrorActionPreference = 'Stop'
# 本脚本在 scripts\ 下，$here 指向项目根；profile 路径读 DSH_HOME 环境变量
$here = Split-Path $PSScriptRoot -Parent
$dshHome = [Environment]::GetEnvironmentVariable('DSH_HOME')
if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
$prof = Join-Path $dshHome "profiles\$ProfileName"
if (-not (Test-Path $prof)) { throw "profile 不存在: $prof" }
Write-Output ("profile: $prof")

$running = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'DeepSeek Harness.exe' -and $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch 'dsh-desktop-host' }
if ($running) {
    Write-Output ('ABORT: DSH 仍在运行 (PID ' + (($running | ForEach-Object { $_.ProcessId }) -join ',') + ')，请先从托盘退出。')
    exit 1
}

New-Item -ItemType Directory -Force -Path (Join-Path $here 'backup') | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item "$prof\package.json" (Join-Path $here "backup\package.json.$stamp.bak")
Write-Output ("[1/3] 备份 package.json.$stamp.bak")

node (Join-Path $PSScriptRoot 'uninstall-hook.cjs') "$prof\package.json"

$link = "$prof\node_modules\dsh-startup-hook"
if (Test-Path $link) { Remove-Item $link -Force; Write-Output '[2/3] junction 已移除' }
else { Write-Output '[2/3] junction 不存在' }

Write-Output '[3/3] 完成。观察者已移除：面板仍会启动，但读不到真实计数，进度停 0、只显示阶段文案。'
