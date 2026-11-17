# rollback-hook.ps1 — 从 desktop profile 移除启动观察者
#
# 做三件事：
#   1. 恢复 profile\package.json（从 backup 目录最新备份）
#   2. 删除 profile\node_modules\dsh-startup-hook junction
#   3. 打印核对结果
#
# 用法（DSH 必须完全退出）：
#   pwsh -NoProfile -File scripts\rollback-hook.ps1 [-ProfileName desktop]
param([string]$ProfileName = 'desktop')

$ErrorActionPreference = 'Stop'
# 本脚本在 scripts\ 下，$here 指向项目根；profile 路径读 DSH_HOME 环境变量
$here = Split-Path $PSScriptRoot -Parent
$dshHome = [Environment]::GetEnvironmentVariable('DSH_HOME')
if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
$prof = Join-Path $dshHome "profiles\$ProfileName"
if (-not (Test-Path $prof)) { throw "profile 不存在: $prof" }
$backupDir = Join-Path $here 'backup'
$link = Join-Path $prof 'node_modules\dsh-startup-hook'

Write-Output '=== rollback: startup hook ==='

$running = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'DeepSeek Harness.exe' -and $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch 'dsh-desktop-host' }
if ($running) {
    Write-Output ('ABORT: DSH still running (PID ' + (($running | ForEach-Object { $_.ProcessId }) -join ',') + '). Quit it first.')
    exit 1
}

$latest = Get-ChildItem $backupDir -Filter 'package.json.*.bak' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) {
    Copy-Item $latest.FullName (Join-Path $prof 'package.json') -Force
    Write-Output ('  restored manifest from: ' + $latest.Name)
} else {
    Write-Output '  WARN: no manifest backup found; package.json left untouched.'
}

if (Test-Path $link) {
    Write-Output ('  junction target: ' + (Get-Item $link).Target)
    Remove-Item $link -Force
    Write-Output '  removed junction dsh-startup-hook'
} else {
    Write-Output '  junction not present'
}

$j = Get-Content (Join-Path $prof 'package.json') -Raw | ConvertFrom-Json
Write-Output ('  bundles[0..2]: ' + (($j.dsh.profile.bundles | Select-Object -First 3) -join ', '))
Write-Output ('  hook still listed: ' + [bool]($j.dsh.profile.bundles -contains 'dsh-startup-hook'))
Write-Output 'done.'