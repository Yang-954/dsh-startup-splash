# clean.ps1 — 清掉运行期产物（不影响安装状态、不动素材）
#
# 删什么：runtime\ 全部（日志、重定向、缓存）、ui\state.json、系统临时目录里的 Edge profile
# 不删：observer\ / ui\ 素材 / scripts\ / backup\
#
# 用法：pwsh -NoProfile -File scripts\clean.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path $PSScriptRoot -Parent
$runtime = Join-Path $here 'runtime'

$freed = 0
function Remove-ItemSafe([string]$path) {
    if (-not (Test-Path $path)) { return }
    try {
        $item = Get-Item $path -Force
        if ($item.PSIsContainer) {
            $sz = (Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $n = @(Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            Remove-Item $path -Recurse -Force -ErrorAction Stop
            Write-Output ("  rm {0}  ({1} 个文件, {2:N1} MB)" -f $path.Replace($here, '.'), $n, ($sz / 1MB))
            $script:freed += $sz
        } else {
            $sz = $item.Length
            Remove-Item $path -Force -ErrorAction Stop
            Write-Output ("  rm {0}  ({1:N0} KB)" -f $path.Replace($here, '.'), ($sz / 1KB))
            $script:freed += $sz
        }
    } catch {
        Write-Output ("  !! {0}: {1}" -f $path.Replace($here, '.'), $_.Exception.Message)
    }
}

Write-Output '=== 清理运行期产物 ==='
# runtime\ 逐项删：DSH 运行时会占着 launch-*.txt 的句柄，整体删会失败。
# 跳过被占用的文件，其它照删。
if (Test-Path $runtime) {
    foreach ($item in (Get-ChildItem $runtime -Force -ErrorAction SilentlyContinue)) {
        Remove-ItemSafe $item.FullName
    }
    try {
        Remove-Item $runtime -Recurse -Force -ErrorAction Stop
        Write-Output '  rm runtime\'
    } catch {
        Write-Output '  runtime\ 仍被占用（DSH 运行中），保留；重启后再跑本脚本即可'
    }
}
Remove-ItemSafe (Join-Path $here 'ui\state.json')
# 清掉旧版遗留（早先缓存写在系统临时目录，现在全部统一在 runtime\ 下）
Remove-ItemSafe (Join-Path $env:TEMP 'dsh-startup-hook.jsonl')
Get-ChildItem $env:TEMP -Filter 'dsh-splash-edge-*' -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-ItemSafe $_.FullName }

Write-Output ''
Write-Output ("释放约 {0:N1} MB" -f ($freed / 1MB))
Write-Output '观察者安装状态未改动；下次启动会自动重建 runtime\'
