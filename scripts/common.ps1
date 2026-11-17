# 公共路径解析 —— 所有脚本 dot-source 这个文件，不写死任何绝对路径
#
# 解决的问题：
#   1. 项目目录不能假设在某台机器的某个位置 → 用 $PSScriptRoot 推导
#   2. DSH 安装位置因机器而异 → 从注册表 / 常见位置 / PATH 依次探测
#   3. profile 目录随 DSH_HOME 变化 → 读环境变量，默认 ~/.dsh

# ---- 项目根 ----
# 调用方通常在 scripts\ 或 tools\ 下，所以向上找一级
function Get-ProjectRoot {
    param([string]$From)
    if (-not $From) { $From = $PSScriptRoot }
    # 如果当前目录本身就是项目根（含 splash.ps1），直接用
    if (Test-Path (Join-Path $From 'splash.ps1')) { return $From }
    $parent = Split-Path $From -Parent
    if ($parent -and (Test-Path (Join-Path $parent 'splash.ps1'))) { return $parent }
    throw "无法定位项目根：$From 及其父目录都没有 splash.ps1"
}

# ---- DSH 安装位置 ----
# 依次尝试：环境变量 → 注册表卸载项 → 常见安装路径 → PATH
function Find-DshInstall {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($env in @('DSH_INSTALL_DIR', 'DSH_HOME_DIR')) {
        $v = [Environment]::GetEnvironmentVariable($env)
        if ($v) { $candidates.Add($v) }
    }

    # 注册表：HKCU / HKLM 的卸载项里找 DisplayName 含 DeepSeek Harness 的
    foreach ($hive in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $hive)) { continue }
        Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'DeepSeek Harness' -and $p.InstallLocation) {
                $candidates.Add($p.InstallLocation)
            }
        }
    }

    # 常见位置
    $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'))
    $candidates.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness'))
    $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness'))

    # PATH 里的 dsh
    $onPath = Get-Command dsh -ErrorAction SilentlyContinue
    if ($onPath) { $candidates.Add((Split-Path (Split-Path (Split-Path $onPath.Source -Parent) -Parent) -Parent)) }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $exe = Join-Path $c 'DeepSeek Harness.exe'
        if (Test-Path $exe) { return (Resolve-Path $c).Path }
    }
    return $null
}

# ---- DSH CLI ----
function Find-DshCli {
    $install = Find-DshInstall
    if ($install) {
        $cli = Join-Path $install 'resources\runtime\cli\bin\dsh.cmd'
        if (Test-Path $cli) { return $cli }
    }
    $onPath = Get-Command dsh -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

# ---- profile 目录 ----
# 优先读 DSH_HOME 环境变量，默认 ~\.dsh
function Get-ProfileDir {
    param([string]$Name = 'desktop')
    $home_ = [Environment]::GetEnvironmentVariable('DSH_HOME')
    if (-not $home_) { $home_ = Join-Path $env:USERPROFILE '.dsh' }
    return (Join-Path $home_ "profiles\$Name")
}

# ---- 一次性解析全部 ----
function Resolve-DshPaths {
    $root = Get-ProjectRoot
    $install = Find-DshInstall
    $exe = if ($install) { Join-Path $install 'DeepSeek Harness.exe' } else { $null }
    return [pscustomobject]@{
        ProjectRoot = $root
        InstallDir  = $install
        Exe         = $exe
        Cli         = Find-DshCli
        Profile     = Get-ProfileDir
    }
}
