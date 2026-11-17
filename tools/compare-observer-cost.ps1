# compare-observer-cost.ps1 — 量化「启动观察者」本身的开销
#
# 在临时 profile 里各跑一次：带 observer / 不带 observer，比较 host 就绪时刻。
# 临时 profile 用 DSH_HOME 覆盖 + 独立端口，不影响正在运行的 desktop 实例。

$ErrorActionPreference = 'Stop'
# 本脚本在 tools\ 下，$here 指向项目根；测试产物全部落在 runtime\ 里
$here = Split-Path $PSScriptRoot -Parent
$runtime = Join-Path $here 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$testHome = Join-Path $runtime 'test-home'
$profileDir = Join-Path $testHome 'profiles\cost-test'
# DSH CLI：从安装目录探测，不写死路径
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\common.ps1')
$dsh = Find-DshCli
if (-not $dsh) { throw '找不到 dsh CLI。请设置 DSH_INSTALL_DIR 环境变量。' }

function Prepare([bool]$withObserver) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $bundles = if ($withObserver) {
        '["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-startup-hook"]'
    } else {
        '["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]'
    }
    @"
{
  "name": "cost-test-profile",
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
    if ($withObserver) {
        New-Item -ItemType Junction -Path $link -Target (Join-Path $here 'observer') | Out-Null
    }
}

function RunOnce([bool]$withObserver, [string]$tag) {
    Prepare $withObserver
    $out = Join-Path $runtime "cost-$tag-out.txt"
    $err = Join-Path $runtime "cost-$tag-err.txt"
    Remove-Item $out, $err -ErrorAction SilentlyContinue
    $hookOut = Join-Path $runtime "cost-$tag-hook.jsonl"
    Remove-Item $hookOut -ErrorAction SilentlyContinue
    $env:DSH_HOME = $testHome
    $env:DSH_STARTUP_HOOK_OUT = $hookOut
    $t0 = Get-Date
    $p = Start-Process -FilePath $dsh -ArgumentList @('--profile', 'cost-test', '--port', '3098', '--no-open') `
        -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    $ready = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 100
        try {
            $t = Get-Content $out -Raw -ErrorAction SilentlyContinue
            if ($t -and $t -match 'dsh web:\s*https?://') { $ready = Get-Date; break }
        } catch { }
    }
    $sw.Stop()
    try { $p | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 800
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'cost-test' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    $env:DSH_HOME = $null
    $env:DSH_STARTUP_HOOK_OUT = $null
    $hookSize = if (Test-Path $hookOut) { (Get-Item $hookOut).Length } else { 0 }
    return [pscustomobject]@{
        tag = $tag
        ready_s = if ($ready) { [math]::Round(($ready - $t0).TotalSeconds, 2) } else { $null }
        hook_bytes = $hookSize
    }
}

Write-Output '=== observer 开销对照（临时 profile，端口 3098） ==='
$a = RunOnce $false 'off'
Write-Output ("  无观察者: host ready = " + $a.ready_s + " s")
$b = RunOnce $true 'on'
Write-Output ("  有观察者: host ready = " + $b.ready_s + " s   (hook 输出 " + [math]::Round($b.hook_bytes/1KB,1) + " KB)")
if ($null -ne $a.ready_s -and $null -ne $b.ready_s) {
    Write-Output ("  => 观察者引入的额外耗时: " + [math]::Round($b.ready_s - $a.ready_s, 2) + " s")
}
