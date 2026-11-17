# install.ps1 — 把启动观察者装进 DSH profile（开启「真实插件激活进度」）
#
# 做了什么：
#   1. 备份 profile\package.json 到 backup\
#   2. 在 profile\node_modules 下建 junction 指向工作区的 observer\
#   3. 在 package.json 的 dependencies 与 bundles 里各加一行 dsh-startup-hook
#
# 前提：DSH 已完全退出（托盘图标右键退出），否则它会覆盖你的改动。
#
# 用法：pwsh -NoProfile -File scripts\install.ps1 [-Profile desktop]
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

$link = "$prof\node_modules\dsh-startup-hook"
if (Test-Path $link) { Remove-Item $link -Force }
New-Item -ItemType Junction -Path $link -Target (Join-Path $here 'observer') | Out-Null
Write-Output ('[2/3] junction -> ' + (Get-Item $link).Target)

node (Join-Path $PSScriptRoot 'install-hook.cjs') "$prof\package.json"
Write-Output '[3/3] 完成。重新启动 DSH 即生效（面板请用 start-splash.cmd 启动）'
