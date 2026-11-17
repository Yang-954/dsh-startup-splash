# splash.ps1 — DSH 启动面板（HTML/CSS 渲染 + 真实插件激活进度）
#
# 面板：Edge app 模式加载 ui\splash.html（独立 user-data-dir，不污染日常浏览器）
# 数据：观察者 progress 快照 -> 写入 ui\state.json -> HTML 轮询渲染
# 就绪：host stdout 出现 `dsh web: <url>` -> ready -> 关闭面板
# 进度：插件激活占前 95%，host 就绪占最后 5%
#
# 用法：
#   pwsh -NoProfile -File splash.ps1            # 正常启动
#   pwsh -NoProfile -File splash.ps1 -Demo      # 只看外观（模拟数据）
#   pwsh -NoProfile -File splash.ps1 -NoLaunch  # 只看面板不启动 DSH

param(
    [switch]$Demo,
    [switch]$NoLaunch,
    # 留空则自动探测（注册表 → 常见路径 → PATH）
    [string]$ExePath = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
# 目录布局：
#   splash.ps1 / start-splash.cmd   入口
#   ui\                            面板（HTML + 素材）
#   observer\                      DSH 插件（观察者）
#   scripts\                       安装 / 卸载 / 回滚
#   tools\                         开发与诊断工具（不参与启动）
#   runtime\                       运行期生成，可随时删除
#   backup\                        profile 备份
# 项目根：从脚本自身位置推导，不依赖任何机器的绝对路径
$here = $PSScriptRoot
if (-not $here) { throw '无法确定脚本目录（$PSScriptRoot 为空）' }
$uiDir    = Join-Path $here 'ui'
$runtime  = Join-Path $here 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$htmlPath = Join-Path $uiDir 'splash.html'
# state.json 必须和 splash.html 同目录：页面用相对路径 ./state.json 轮询
$statePath = Join-Path $uiDir 'state.json'
$progress = Join-Path $runtime 'observer.jsonl'
$stdout   = Join-Path $runtime 'dsh-stdout.txt'
$stderr   = Join-Path $runtime 'dsh-stderr.txt'
$logFile  = Join-Path $runtime 'splash.log'
# Edge 的 user-data-dir：Chromium 内核强制要求，不给它就会去动日常浏览器配置。
# 按用户要求，所有运行缓存统一放在 runtime\ 下（而不是系统临时目录）。
# 每次运行用独立子目录，面板关闭后立刻删除，避免像早先那样累积到 190+ MB。
$edgeProfile = Join-Path $runtime ('.edge-profile-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))

# ---- 自动探测外部程序（不写死任何机器的路径）----
# Edge：先查注册表 App Paths，再退到常见位置
function Find-Edge {
    foreach ($k in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')) {
        if (Test-Path $k) {
            $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).'(default)'
            if ($v -and (Test-Path $v)) { return $v }
        }
    }
    foreach ($p in @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# DSH 主程序：环境变量 → 注册表卸载项 → 常见路径 → PATH
function Find-DshExe {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($e in @('DSH_INSTALL_DIR')) {
        $v = [Environment]::GetEnvironmentVariable($e)
        if ($v) { $cands.Add($v) }
    }
    foreach ($hive in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path $hive)) { continue }
        Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -match 'DeepSeek Harness' -and $p.InstallLocation) { $cands.Add($p.InstallLocation) }
        }
    }
    $cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'))
    $cands.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness'))
    if (${env:ProgramFiles(x86)}) { $cands.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }
    foreach ($c in $cands) {
        if (-not $c) { continue }
        $exe = Join-Path $c 'DeepSeek Harness.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

if (-not $ExePath) {
    $ExePath = Find-DshExe
    if (-not $ExePath) {
        throw '找不到 DeepSeek Harness.exe。请用 -ExePath 指定，或设置 DSH_INSTALL_DIR 环境变量。'
    }
}
$edgeBin = Find-Edge
if (-not $edgeBin) {
    Write-Output 'WARN: 找不到 Microsoft Edge，面板将无法显示（启动流程仍会继续）'
}

# ---- 日志按「轮次」保留最近 N 次，而不是按体积轮转 ----
# splash.log 和 observer.jsonl 都是追加写的，不裁剪就会无限增长
# （splash.log 一轮约 25 KB，observer.jsonl 一轮约 100 KB）。
# 这里在每轮启动开始时裁剪：按 'splash start' 切分，只留最近 $KeepRuns 轮。
$KeepRuns = 10

function Trim-LogByRuns([string]$path, [int]$keep) {
    if (-not (Test-Path $path)) { return }
    try {
        $lines = [System.IO.File]::ReadAllLines($path)
        if ($lines.Count -eq 0) { return }
        # 找出每轮的起始行号
        $starts = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'splash start') { $starts.Add($i) }
        }
        if ($starts.Count -le $keep) { return }
        $cut = $starts[$starts.Count - $keep]
        $kept = $lines[$cut..($lines.Count - 1)]
        [System.IO.File]::WriteAllLines($path, $kept, (New-Object System.Text.UTF8Encoding($false)))
        return $starts.Count - $keep
    } catch { return }
}

# observer.jsonl 没有 'splash start' 标记，按 mount 记录切分（每轮一条 mount）
function Trim-JsonlByMounts([string]$path, [int]$keep) {
    if (-not (Test-Path $path)) { return }
    try {
        $lines = [System.IO.File]::ReadAllLines($path)
        if ($lines.Count -eq 0) { return }
        $mounts = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '"type":"mount"') { $mounts.Add($i) }
        }
        if ($mounts.Count -le $keep) { return }
        $cut = $mounts[$mounts.Count - $keep]
        $kept = $lines[$cut..($lines.Count - 1)]
        [System.IO.File]::WriteAllLines($path, $kept, (New-Object System.Text.UTF8Encoding($false)))
        return $mounts.Count - $keep
    } catch { return }
}

$droppedLog = Trim-LogByRuns $logFile $KeepRuns
$droppedObs = Trim-JsonlByMounts $progress $KeepRuns
# 旧版按体积轮转留下的文件，直接删掉（不再需要）
$oldRotated = Join-Path $runtime 'splash.1.log'
if (Test-Path $oldRotated) { Remove-Item $oldRotated -Force -ErrorAction SilentlyContinue }

# 常开句柄写日志：Out-File -Append 每行都要 open/close 一次，600 行日志就是 600 次
$script:logWriter = $null
try {
    $fs = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $script:logWriter = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
    $script:logWriter.AutoFlush = $true
} catch { }

if ($droppedLog) { Say ("  已裁剪 splash.log：删除最旧的 $droppedLog 轮，保留最近 $KeepRuns 轮") }
if ($droppedObs) { Say ("  已裁剪 observer.jsonl：删除最旧的 $droppedObs 轮，保留最近 $KeepRuns 轮") }

function Say([string]$m) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') + ' ' + $m
    $script:lastSayAt = Get-Date
    try {
        if ($script:logWriter) { $script:logWriter.WriteLine($line) }
        else { $line | Out-File -Append -Encoding utf8 $logFile }
    } catch { }
}

function Read-Shared([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close(); return $t
    } catch { return '' }
}

function Write-State([double]$pct, [string]$stage, [string]$detail, [bool]$ready) {
    $obj = [ordered]@{ pct = [math]::Round($pct, 1); stage = $stage; detail = $detail; ready = $ready }
    try {
        [System.IO.File]::WriteAllText($statePath, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Stop-Panel {
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$edgeProfile*" } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    } catch { }
    # 面板关了就把这次的临时 profile 删掉：Chromium 必须要 user-data-dir，
    # 但没有任何理由留着它（实测一次运行能产生 190+ MB 缓存）。
    try {
        Start-Sleep -Milliseconds 400   # 等 Edge 子进程真正退出、释放文件句柄
        if ($edgeProfile -and (Test-Path $edgeProfile)) {
            Remove-Item $edgeProfile -Recurse -Force -ErrorAction SilentlyContinue
            Say ("  [面板] 临时缓存已清理: " + $edgeProfile)
        }
    } catch { }
}

# 增量读观察者 jsonl：只解析「新增的行」，不再每 130ms 重读整个文件
# （文件会涨到几百 KB，全量重读 + 全量 JSON 解析会把主循环拖慢，表现就是日志不刷新）
# 顺带把 active/total/name 缓存下来，省掉 Get-ProgressState 的重复读盘。
$script:hookPath = $null
$script:hookOffset = 0L
$script:activationIndex = 0
$script:actActive = 0
$script:actTotal = 0
$script:actName = ''
$script:mountSeen = $false

function Update-FromHook {
    if ($null -eq $script:hookPath) {
        foreach ($c in @($progress)) {
            if (Test-Path $c) { $script:hookPath = $c; $script:hookOffset = 0L; break }
        }
        if ($null -eq $script:hookPath) { return @() }
    }
    $newActs = New-Object System.Collections.Generic.List[object]
    try {
        $fs = [System.IO.File]::Open($script:hookPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -lt $script:hookOffset) {
                # 文件被重建（新一轮启动）：重置全部缓存
                $script:hookOffset = 0L
                $script:actActive = 0; $script:actTotal = 0; $script:actName = ''
                $script:mountSeen = $false; $script:activationIndex = 0
            }
            $fs.Position = $script:hookOffset
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $sr.Dispose()
            $lastNl = $text.LastIndexOf("`n")
            if ($lastNl -ge 0) {
                $complete = $text.Substring(0, $lastNl + 1)
                $script:hookOffset += [System.Text.Encoding]::UTF8.GetByteCount($complete)
                foreach ($line in $complete.Split("`n")) {
                    if (-not $line.Trim()) { continue }
                    if ($line -notmatch '"type":') { continue }
                    try { $o = $line | ConvertFrom-Json } catch { continue }
                    if ($o.type -eq 'progress') {
                        $script:actActive = [int]$o.active
                        $script:actTotal = [int]$o.total
                    } elseif ($o.type -eq 'mount') {
                        $script:mountSeen = $true
                    } elseif ($o.type -eq 'status' -and $o.becameActive) {
                        $script:actName = if ($o.name) { $o.name } else { '' }
                        $newActs.Add($o)
                    }
                }
            }
        } finally { $fs.Dispose() }
    } catch { }
    return $newActs
}

# ---- 已有实例 ----
$existing = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -eq 'DeepSeek Harness.exe' -and $_.CommandLine -notmatch '--type=' -and $_.CommandLine -notmatch 'dsh-desktop-host' }
if (-not $Demo -and -not $NoLaunch -and $existing) {
    $pids = ($existing | ForEach-Object { $_.ProcessId }) -join ','
    Say "ABORT existing instance(s): $pids"
    $msg = "DeepSeek Harness 已在运行（PID $pids）。`r`n请先从托盘图标右键退出，再运行本启动器。"
    [System.Windows.Forms.MessageBox]::Show($msg, '无法启动：已有实例在运行') | Out-Null
    exit 0
}
Say ("splash start demo=" + $Demo + " noLaunch=" + $NoLaunch)

if (-not $Demo -and -not $NoLaunch) {
    foreach ($f in @($progress, $stdout, $stderr)) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}
# 清理历史遗留：早期版本把重定向文件放在根目录、后来又改过几次文件名。
# 这里顺手把旧名字一并删掉（DSH 已退出时才删得掉）。
foreach ($legacy in @(
        (Join-Path $here 'launch-stdout.txt'), (Join-Path $here 'launch-stderr.txt'),
        (Join-Path $runtime 'launch-stdout.txt'), (Join-Path $runtime 'launch-stderr.txt'),
        (Join-Path $runtime 'expected-total.json'), (Join-Path $runtime 'expected-cpu.json')
    )) {
    if (Test-Path $legacy) { try { Remove-Item $legacy -Force -ErrorAction Stop } catch { } }
}

# ---- 启动面板（Edge app 模式）----
$panelUp = $false
if (Test-Path $edgeBin) {
    try {
        if (-not (Test-Path $edgeProfile)) { New-Item -ItemType Directory -Force -Path $edgeProfile | Out-Null }
        $uri = (New-Object System.Uri($htmlPath)).AbsoluteUri
        $sw = [System.Windows.Forms.SystemInformation]::VirtualScreen
        # 窗口按视频的 16:9 设计，视频就能用 cover 铺满且不裁剪、不留黑边。
        # Edge 的 --window-size 是外框尺寸，实测内缩 (16, 39)：
        #   outer 800×480  ->  inner 784×441  = 1.7778 = 1920/1080
        $vw = 800; $vh = 480
        $px = [int]($sw.X + ($sw.Width - $vw) / 2)
        $py = [int]($sw.Y + ($sw.Height - $vh) / 2.35)
        $edgeArgs = @(
            "--app=$uri",
            "--window-size=$vw,$vh",
            "--window-position=$px,$py",
            "--user-data-dir=$edgeProfile",
            '--no-first-run',
            '--no-default-browser-check',
            # 关掉同步 / 登录提示：新 profile 首次启动会弹「现在正在你的所有设备上同步
            # 你的浏览数据」整屏遮挡，实测把面板完全盖住
            '--disable-sync',
            '--disable-features=Translate,MediaRouter,OptimizationHints,EdgeSyncPromo,msEdgeIdentityFeature',
            '--no-service-autorun',
            '--disable-component-update',
            '--disable-background-networking',
            '--no-pings',
            '--allow-file-access-from-files',
            '--hide-crash-restore-bubble'
        )
        $ep = Start-Process -FilePath $edgeBin -ArgumentList $edgeArgs -PassThru
        $panelUp = $true
        Say ('panel launched pid=' + $ep.Id + ' uri=' + $uri)
    } catch {
        Say ('panel launch failed: ' + $_.Exception.Message)
        $panelUp = $false
    }
} else {
    Say 'panel skipped: edge not found'
}

# ---- 启动 DSH ----
$app = $null
if (-not $Demo -and -not $NoLaunch) {
    try {
        $p = Start-Process -FilePath $ExePath -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $app = $p
        Say ('dsh launched pid=' + $p.Id)
    } catch {
        Say ('dsh launch exception: ' + $_.Exception.Message)
        Write-State 100 '启动失败' $_.Exception.Message $true
    }
}

# ---- 主循环：四阶段进度 ----
# 启动不是「插件加载」一条线，而是四段（2026-11-17 13:45 实测，到窗口可见共 ~16.2s）：
#   ① 启动引擎  6.01s   进程启动 → 宿主子进程挂上观察者
#   ② 加载插件  2.72s   首个激活 → 第 380 个激活
#   ③ 准备服务  5.98s   激活停滞 → host 打印 `dsh web:` 就绪
#   ④ 呈现界面  ~1.5s   就绪 → 窗口真正出现在屏幕上
# 进度条按这四段的真实边界切分，不再是「插件加载吃掉整条」。
$startedAt = Get-Date
$startMs = [DateTimeOffset]::new($startedAt).ToUnixTimeMilliseconds()
$script:lastSayAt = Get-Date
$ready = $false
$readyAt = $null
$windowSeen = $false

# 进度条与数字必须用同一个时钟：插件阶段只由「激活计数 / 预期总数」驱动。
# 之前阶段③用时间缓动，会出现「数字冻结但条在爬」的观感矛盾。
# 实测 384 个组件在 3 秒内激活完，之后 6 秒是 MCP/作用域等待——那段时间
# 条和数字一起停，靠文案与呼吸动效说明仍在工作。
$W1 = 37.0; $W2 = 54.0; $W3 = 9.0
$P1 = $W1                 # 37  引擎 → 插件
$P2 = $P1 + $W2           # 91  插件 → 界面
$P3 = $P2 + $W3           # 100 界面完成
$bootKinds = @('main', 'gpu-process', 'renderer', 'utility', 'host')

# 预期组件总数：跨轮缓存，让「已激活 N / M」的分母稳定，条形也就能按计数推进
$expectedFile = Join-Path $runtime 'cache-total.json'
$cachedTotal = 0
try {
    if (Test-Path $expectedFile) { $cachedTotal = [int](Get-Content $expectedFile -Raw | ConvertFrom-Json).total }
} catch { }
$predTotal = [Math]::Max(1, $cachedTotal)

$lastPct = 0.0
$lastActive = -1
$lastActAt = Get-Date
$nameShown = ''
$nameAt = (Get-Date).AddSeconds(-10)
$stallStart = $null
$seenKinds = 0
$lastBootProbe = (Get-Date).AddSeconds(-10)

# ---- 日志采集状态：把每一步都记下来，方便事后回答「这次启动分了几段、各多久」----
$logKinds = @{}
$hookSeen = $false
$stdoutLinesLogged = 0
$stallLogged = $false
$tMount = $null
$tBulk = $null
$tReady = $null
$tWindow = $null
$cpuAtMount = 0.0
$curPhase = 1
$seenProcs = @{}          # 进程树里见过的 pid → 名字（含 conhost，仅用于日志）
$script:treePids = New-Object System.Collections.Generic.HashSet[int]   # 用于 CPU/内存统计
$script:lastCpuProbe = (Get-Date).AddSeconds(-10)
$script:cpuPeak = @{}     # pid -> 该进程的 CPU 峰值（进程退出后仍保留）
$script:livePids = New-Object System.Collections.Generic.HashSet[int]  # 本轮存活的 pid
$script:svcSeen = @{}     # 功能进程（排除 conhost）的累计集合，用于「服务 N」
$procCount = 0
$svcCount = 0             # 非 electron、非 conhost 的子孙进程数（node / python / windows-mcp / pwsh…）
$bootProbeMs = 800
# 主进程 pid：DSH 启动后取第一个「非 --type、非 desktop-host」的进程
$mainPid = if ($app) { $app.Id } else { 0 }
# 累计 CPU 预期值（跨轮缓存，用来给阶段 1 定分母）
$cpuFile = Join-Path $runtime 'cache-cpu.json'
$expectedCpu = 6.0
try {
    if (Test-Path $cpuFile) {
        $c = Get-Content $cpuFile -Raw | ConvertFrom-Json
        if ($c.cpu) { $expectedCpu = [double]$c.cpu }
    }
} catch { }
Say '--- 本次启动追踪 ---'
Say '  === 阶段 1/4 · 启动引擎 ==='

while ($true) {
    $el = ((Get-Date) - $startedAt).TotalSeconds
    if ($Demo) {
        $demoPhase++
        # 演示模式只回放节奏，不读真实数据；但日志结构照常输出，方便核对观感
        if ($el -lt 1.5) {
            Write-State 11 '正在启动引擎' '子进程 2 / 5' $false
            if ($demoPhase -eq 1) { Say '  [演示] 以下为模拟节奏，不含真实采集' ; Say '  [演示] [引擎] main / gpu-process 出现' }
        }
        elseif ($el -lt 3.0) {
            Write-State 30 '正在启动引擎' '子进程 4 / 5' $false
            if ($demoPhase -eq 13) { Say '  [演示] [引擎] renderer / utility 出现' }
        }
        elseif ($el -lt 4.0) {
            Write-State 45 '正在加载插件' '已激活 29 个组件' $false
            if ($demoPhase -eq 26) { $tMount = Get-Date; Say '  === 阶段 2/4 · 加载插件 ===' ; Say '  [演示] [插件] #1 … #29' }
        }
        elseif ($el -lt 5.0) {
            Write-State 52 '正在激活 PermissionPresetService' '已激活 169 个组件' $false
            if ($demoPhase -eq 34) { Say '  [演示] [插件] #30 … #169' }
        }
        elseif ($el -lt 8.0) {
            Write-State 71 '正在等待服务就绪（MCP / 作用域）' '已激活 380 个组件' $false
            if ($demoPhase -eq 42) { $tBulk = Get-Date; Say '  === 阶段 3/4 · 准备服务 ===' ; Say '  [演示] [插件] #170 … #380' }
        }
        elseif ($el -lt 9.5) {
            Write-State 94 '正在呈现界面' '宿主已就绪，等待窗口' $false
            if ($demoPhase -eq 67) { $tReady = Get-Date; Say '  === 阶段 4/4 · 呈现界面 ===' ; Say '  [演示] [就绪] host ready' }
        }
        else {
            $tWindow = Get-Date
            Write-State 100 '即将完成' '窗口已呈现' $true
            Say '  [演示] [界面] 窗口可见 → 关闭面板'
            break
        }
        Start-Sleep -Milliseconds 120
        continue
    }

    # ---- 阶段 1：启动引擎 ----
    # 那 5 秒里不会再出现新进程（宿主在进程内加载模块），唯一在变的是它的 CPU 时间
    # 和内存。所以：
    #   * 进程树（含 node.exe / windows-mcp.exe / python.exe 等子进程）逐条记日志
    #   * 进度条由「整棵进程树的累计 CPU 时间」驱动 —— CPU 不涨，条就不动
    #   * 明细行显示进程数 + CPU + 内存，让这段窗口始终有真实的数字在变
    if (-not $windowSeen -and $mainPid -gt 4 -and ((Get-Date) - $lastBootProbe).TotalMilliseconds -ge $bootProbeMs) {
        $lastBootProbe = Get-Date
        # 前 3 秒进程集中出现（gpu/utility/renderer 几乎同时），探得细一点，
# 免得「1 直接跳到 4」；3 秒后放慢到 800ms，进入等待服务后再放到 1200ms
        $bootProbeMs = if ($hookSeen) { 1200 } elseif ($el -lt 3) { 300 } else { 800 }
        try {
            $snap = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
            $byParent = @{}
            foreach ($pr in $snap) {
                $pp = [int]$pr.ParentProcessId
                # 只有 id>4 的父进程才进索引；否则 ParentProcessId=0 会把
                # System Idle / System / smss 这些系统根进程全卷进来
                if ($pp -le 4) { continue }
                if (-not $byParent.ContainsKey($pp)) { $byParent[$pp] = New-Object System.Collections.Generic.List[object] }
                $byParent[$pp].Add($pr)
            }
            $found = @{}
            # 树根（主进程）本身永远不会被遍历到 —— 遍历是从它的子进程开始的。
            # 所以 main 必须手工记上，而且也要进 $seenProcs，否则面板的
            # 「进程 N」永远停在 4（gpu/utility/renderer/host），到不了 5。
            $found['main'] = 1
            $rootKey = [int]$mainPid
            if (-not $seenProcs.ContainsKey($rootKey)) {
                $seenProcs[$rootKey] = 'DeepSeek Harness.exe'
                [void]$script:treePids.Add($rootKey)
                $procCount = $seenProcs.Count
                Say ("  [进程] +{0,6:N2}s  {1,-22} pid={2}" -f $el, '主进程(main)', $rootKey)
            }
            $queue = New-Object System.Collections.Generic.Queue[object]
            if ($byParent.ContainsKey([int]$mainPid)) { foreach ($c in $byParent[[int]$mainPid]) { $queue.Enqueue($c) } }
            $visited = 0
            while ($queue.Count -gt 0 -and $visited -lt 200) {
                $c = $queue.Dequeue()
                $visited++
                $cl = [string]$c.CommandLine
                $nm = [string]$c.Name
                $role = ''
                if ($cl -match '--type=([a-zA-Z-]+)') { $found[$Matches[1]] = 1; $role = 'electron:' + $Matches[1] }
                elseif ($cl -match 'dsh-desktop-host') { $found['host'] = 1; $role = '宿主(host)' }
                elseif ($nm -eq 'DeepSeek Harness.exe') { $role = 'DSH 子进程' }
                else { $role = $nm }
                # conhost.exe 是每个控制台进程的附庸，不算「DSH 的功能进程」，
                # 计入会让数字虚高（实测一次启动能冒出 6 个以上）
                $isConsole = $nm -eq 'conhost.exe'
                # powershell / pwsh 是 DSH 起来后为用户拉起的终端工具，
                # 不属于启动链（实测阶段 4 才出现，会把进程数从 17 顶到 21，
                # 误导「启动还在继续」的判断）。同样不计入。
                $isShellTool = $nm -match '^(powershell|pwsh)\.exe$'
                $key = [int]$c.ProcessId
                if (-not $seenProcs.ContainsKey($key)) {
                    $seenProcs[$key] = $nm
                    [void]$script:treePids.Add($key)
                    if (-not $isConsole -and -not $isShellTool) { $script:svcSeen[$key] = $nm }
                    $procCount = $seenProcs.Count
                    $svcCount = $script:svcSeen.Count
                    $tag = if ($isConsole) { 'conhost(附庸)' } elseif ($isShellTool) { 'shell工具(非启动链)' } else { $role }
                    Say ("  [进程] +{0,6:N2}s  {1,-22} pid={2}" -f $el, $tag, $key)
                }
                if ($byParent.ContainsKey($key)) { foreach ($g in $byParent[$key]) { $queue.Enqueue($g) } }
            }
            # 计数统一在探针末尾刷新一次，避免心跳读到「上一轮」的旧值
            $procCount = $seenProcs.Count
            $svcCount = $script:svcSeen.Count
            $seenKinds = @($bootKinds | Where-Object { $found.ContainsKey($_) }).Count
        } catch { }
    }

    # CPU / 内存：必须统计【整棵进程树】，不能只看 DeepSeek Harness.exe。
    # 实测：等待 MCP 那 6 秒里真正在烧 CPU 的是 python.exe / windows-mcp.exe /
    # node.exe（它们由宿主拉起，但进程名不是 DeepSeek Harness），只统计 DSH 自己
    # 会导致 CPU 数字在那段时间完全冻结（用户看到的「CPU 12.8s 不动」就是这个）。
    #
    # 另外：进程树探针 800~1200ms 才跑一次，新进程会有延迟才进 $treePids。
    # 所以这里【每次都重新取一遍整棵树】，用主进程 pid 现走一次父子关系，
    # 保证 MCP 子进程一出现就被计入（Get-CimInstance 全量约 110ms，
    # 但只在观察者挂载前每轮跑，代价可接受；挂载后改为 400ms 节流）。
    $cpuSec = 0.0; $memMb = 0
    try {
        if ($mainPid -gt 4 -and ((Get-Date) - $script:lastCpuProbe).TotalMilliseconds -ge 400) {
            $script:lastCpuProbe = Get-Date
            $snapC = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
            $byPar = @{}
            foreach ($pr in $snapC) {
                $pp = [int]$pr.ParentProcessId
                if ($pp -le 4) { continue }
                if (-not $byPar.ContainsKey($pp)) { $byPar[$pp] = New-Object System.Collections.Generic.List[int] }
                $byPar[$pp].Add([int]$pr.ProcessId)
            }
            $fresh = New-Object System.Collections.Generic.HashSet[int]
            [void]$fresh.Add([int]$mainPid)
            $q2 = New-Object System.Collections.Generic.Queue[int]
            $q2.Enqueue([int]$mainPid)
            $guard = 0
            while ($q2.Count -gt 0 -and $guard -lt 300) {
                $cur = $q2.Dequeue()
                $guard++
                if ($byPar.ContainsKey($cur)) {
                    foreach ($child in $byPar[$cur]) {
                        if ($fresh.Add($child)) { $q2.Enqueue($child) }
                    }
                }
            }
            foreach ($id2 in $fresh) { [void]$script:treePids.Add($id2) }
        }
        # 用累计集合统计（进程退出后 Get-Process 取不到，自然不再计入）
        $allProc = Get-Process -ErrorAction SilentlyContinue
        $script:livePids.Clear()
        foreach ($dp in $allProc) {
            $id3 = [int]$dp.Id
            if (-not $script:treePids.Contains($id3)) { continue }
            [void]$script:livePids.Add($id3)
            $t3 = $dp.TotalProcessorTime.TotalSeconds
            $cpuSec += $t3
            $memMb += [math]::Round($dp.WorkingSet64 / 1MB)
            # 记住每个进程的 CPU 峰值：进程退出后 Get-Process 就取不到了，
            # 它的 CPU 贡献会凭空消失，导致累计值倒退（实测 16.2s → 15.0s）。
            # 这里把退出进程的最终值保留下来，保证累计 CPU 只增不减。
            if (-not $script:cpuPeak.ContainsKey($id3) -or $t3 -gt $script:cpuPeak[$id3]) {
                $script:cpuPeak[$id3] = $t3
            }
        }
        # 加上所有「当前不存活」进程的峰值（含刚退出的和更早退出的）
        foreach ($id4 in $script:cpuPeak.Keys) {
            if (-not $script:livePids.Contains($id4)) { $cpuSec += $script:cpuPeak[$id4] }
        }
    } catch { }

    # ---- 阶段 3 结束 / 4 开始：宿主就绪 ----
    $so = Read-Shared $stdout
    if ($so) {
        $lines = @($so -split "`n" | Where-Object { $_.Trim() })
        while ($stdoutLinesLogged -lt $lines.Count) {
            $line = $lines[$stdoutLinesLogged].Trim()
            $stdoutLinesLogged++
            if ($stdoutLinesLogged -le 8) {
                Say ("  [输出] +{0,6:N2}s  {1}" -f $el, $line.Substring(0, [Math]::Min(110, $line.Length)))
            } elseif ($stdoutLinesLogged -eq 9) {
                Say ("  [输出] 后续 stdout 行不再逐条记录")
            }
        }
    }
    if (-not $ready -and $so -match 'dsh web:\s*https?://') {
        $ready = $true
        $readyAt = Get-Date
        $tReady = Get-Date
        Say ("  [就绪] host ready (dsh web: line seen)  +{0,6:N2}s" -f $el)
    }

    # ---- 阶段 4 结束：窗口真的出现（MainWindowHandle 非 0）----
    if (-not $windowSeen) {
        try {
            $w = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($w) {
                $windowSeen = $true
                $tWindow = Get-Date
                Say ("  [界面] 窗口可见 hwnd={0}  +{1,6:N2}s" -f $w.MainWindowHandle, $el)
            }
        } catch { }
    }

    # ---- 阶段 2/3：观察者数据（增量解析，不重读整份文件）----
    $newActs = Update-FromHook
    $ps = if ($script:actTotal -gt 0) {
        [pscustomobject]@{ active = $script:actActive; total = $script:actTotal; name = $script:actName }
    } else { $null }
    $ratio = 0.0
    $bulkDone = $false
    if ($null -ne $ps) {
        $ratio = [math]::Min(1.0, $ps.active / [Math]::Max(1, $ps.total))
        # 分母取「缓存值」与「本轮实际」的较大者：缓存让早段的百分比不发虚，
        # 实际值超过缓存时自动跟上，避免进度条被算到 100% 以上卡住。
        if ($ps.total -gt $predTotal) { $predTotal = $ps.total }
        if (-not $hookSeen) {
            $hookSeen = $true
            $tMount = Get-Date
            $cpuAtMount = $cpuSec
            Say ("  [插件] 观察者挂载  +{0,6:N2}s  active {1}/{2}  (阶段1 累计CPU {3:N1}s / {4} 个进程)" -f $el, $ps.active, $ps.total, $cpuSec, $procCount)
        }
        if ($ps.active -gt $lastActive) { $lastActive = $ps.active; $lastActAt = Get-Date }
        # 逐条记录每一个激活的组件，编号递增： #[1] #[2] #[3] …
        foreach ($a in $newActs) {
            $script:activationIndex++
            # 用这条激活自己的时间戳，而不是"读到它的那一刻"。否则爆发期一次读进
            # 几百条，时间戳会全部挤成同一个值，看起来像日志没刷新。
            $evEl = [Math]::Max(0.0, ($a.at - $startMs) / 1000.0)
            Say ("  [插件] #{0,-4} +{1,6:N2}s  {2}" -f $script:activationIndex, $evEl, $(if ($a.name) { $a.name } else { '(未命名)' }))
        }
        if ($ps.name -and ((Get-Date) - $nameAt).TotalMilliseconds -ge 450) {
            $nameShown = $ps.name
            $nameAt = Get-Date
        }
        $bulkDone = $ratio -ge 0.99
        if ($bulkDone -and $null -eq $stallStart) { $stallStart = Get-Date }
    }
    # 兜底：即便没到 0.99（个别 fiber 一直 pending），只要 3 秒没有新激活，
    # 也认为批量加载结束、进入服务等待，否则进度会一直卡在阶段 2 不动。
    if ($null -eq $stallStart -and $lastActive -gt 0 -and ((Get-Date) - $lastActAt).TotalSeconds -ge 3) {
        $stallStart = Get-Date
    }
    if ($null -ne $stallStart -and -not $stallLogged) {
        $stallLogged = $true
        $tBulk = Get-Date
        Say ("  [服务] 批量激活结束，进入收尾等待  +{0,6:N2}s  已激活 {1}" -f $el, $lastActive)
    }

    # ---- 阶段切换：在日志里明确标出「当前处于第几段」----
    $nowPhase = if ($windowSeen -or $ready) { 4 } elseif ($null -ne $stallStart) { 3 } elseif ($null -ne $ps) { 2 } else { 1 }
    if ($nowPhase -ne $curPhase) {
        $curPhase = $nowPhase
        $label = switch ($curPhase) {
            2 { '加载插件' }
            3 { '准备服务' }
            4 { '呈现界面' }
            default { '启动引擎' }
        }
        Say ("  === 阶段 {0}/4 · {1} ===  +{2,6:N2}s" -f $curPhase, $label, $el)
    }

    # ---- 合成进度：与「已激活 N / M」同一个时钟，整体只增不减 ----
    # ① 引擎：由「整棵进程树的累计 CPU 时间」驱动 —— 宿主不在干活，CPU 不涨，条就停；
    #    CPU 涨说明真的在加载模块，条才动。
    #    用渐近曲线而不是硬比值：分母估小了也不会「提前拉满」，只会越来越慢地接近 36.4%。
    $bootCpuPct = ($P1 - 0.6) * (1 - [math]::Exp(-$cpuSec / [Math]::Max(0.5, $expectedCpu / 2.0)))
    $bootFloor = 6.0 * [math]::Min(1.0, $procCount / 12.0)
    $p = [math]::Max($bootFloor, $bootCpuPct)                            # ① 引擎
    if ($null -ne $ps) {
        # ② 插件：只用计数 —— 数字动，条才动；数字停，条就停。
        $ratio2 = [math]::Min(1.0, $ps.active / [Math]::Max(1, $predTotal))
        $p = [math]::Max($p, $P1 + $W2 * $ratio2)
    }
    if ($ready) {                                                        # ③ 界面（就绪 → 窗口）
        if ($windowSeen) { $p = $P3 }
        else {
            $rt = ((Get-Date) - $readyAt).TotalSeconds
            $p = [math]::Max($p, $P2 + ($W3 - 1.2) * (1 - [math]::Exp(-$rt / 0.8)))
        }
    }
    $pct = [math]::Max($lastPct, [math]::Min(100.0, $p))
    $lastPct = $pct

    # ---- 文案 ----
    # 阶段①的三个子阶段，避免「子进程 5/5」从 1.6 秒一直挂到 6 秒显得死板
    $bootStage = if ($seenKinds -le 1) { '启动主进程' }
        elseif ($seenKinds -le 3) { '启动渲染与工具进程' }
        elseif ($seenKinds -eq 4) { '启动宿主进程' }
        else { '解析配置、装配模块' }

    $stalled = ($lastActive -gt 0) -and (((Get-Date) - $lastActAt).TotalMilliseconds -ge 1500)
    $nameFresh = ((Get-Date) - $nameAt).TotalMilliseconds -le 900
    $waited = if ($null -ne $stallStart) { ((Get-Date) - $stallStart).TotalSeconds } else { 0 }

    # ---- 明细行：固定顺序 插件 → 进程 → 服务 → CPU → 内存 ----
    # 顺序在所有阶段保持一致，避免「CPU 一会在前一会在后」的跳变。
    # 插件段只在真正开始加载插件后才出现（阶段①还没有计数，不能显示 0/0）。
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $ps) { $parts.Add("已激活 $($ps.active) / $($predTotal)") }
    $parts.Add("进程 $procCount")
    if ($svcCount -gt 0) { $parts.Add("服务 $svcCount") }
    $parts.Add("CPU $([math]::Round($cpuSec,1))s")
    $parts.Add("内存 ${memMb}MB")
    if ($null -ne $stallStart -and $bulkDone) { $parts.Add("已等待 $([math]::Round($waited,1))s") }
    $detail = $parts -join ' · '

    if ($windowSeen) { $stage = '即将完成' }
    elseif ($ready) { $stage = '正在呈现界面' }
    elseif ($null -eq $ps) { $stage = $bootStage }
    elseif ($stalled -and $bulkDone) { $stage = '正在等待服务就绪（MCP 与作用域）' }
    elseif ($nameFresh -and $nameShown) { $stage = "正在激活 $nameShown" }
    else { $stage = '正在加载插件' }

    Write-State $pct $stage $detail $windowSeen

    # ---- 收尾 ----
    if ($windowSeen) { Say ('  [完成] 关闭面板  +' + ('{0:N2}s' -f $el) + '  ' + [math]::Round($pct,1) + '%'); break }
    if ($ready -and $windowSeen -eq $false -and ((Get-Date) - $readyAt).TotalSeconds -gt 10) {
        Say '  [超时] 就绪后 10s 仍检测不到窗口，强制关闭'
        Write-State 100 '即将完成' '窗口检测超时' $true
        break
    }
    if ($app) {
        $app.Refresh()
        if ($app.HasExited) {
            Say ('  [失败] dsh 进程退出，code=' + $app.ExitCode)
            Write-State 100 '启动失败' "进程已退出（exit code $($app.ExitCode)）" $true
            break
        }
    }
    if ($el -gt 180) { Say '  [超时] 超过 180s'; break }
    # 心跳：1.5 秒没有任何事件也写一行，否则日志会长时间纹丝不动，看着像卡死
    if (-not $windowSeen -and ((Get-Date) - $script:lastSayAt).TotalSeconds -ge 1.5) {
        Say ("  [心跳] +{0,6:N2}s  阶段 {1}/4  已激活 {2} · 进程 {3} · 服务 {4} · CPU {5:N1}s · 内存 {6}MB" -f `
                $el, $curPhase, [Math]::Max(0, $lastActive), $procCount, $svcCount, $cpuSec, $memMb)
    }

    Start-Sleep -Milliseconds 130
}

# ---- 本次启动分段汇总：直接回答「这次启动分了几段、各多久」----
try {
    $endAt = Get-Date
    $total = ($endAt - $startedAt).TotalSeconds
    $seg = {
        param($from, $to)
        if ($null -eq $from) { return $null }
        if ($null -eq $to) { $to = $endAt }
        # 个别异常时序（例如桩测试里数据已经完整）会算出负数，钳到 0，避免汇总出现负时长
        return [Math]::Max(0.0, ($to - $from).TotalSeconds)
    }
    $dEngine = if ($tMount) { (& $seg $startedAt $tMount) } else { $null }
    $dPlugin = if ($tMount -and $tBulk) { (& $seg $tMount $tBulk) } else { $null }
    $dServe  = if ($tBulk -and $tReady) { (& $seg $tBulk $tReady) } else { $null }
    $dWindow = if ($tReady -and $tWindow) { (& $seg $tReady $tWindow) } else { $null }

    Say ''
    # 把本轮观察到的总数缓存下来，下一轮的分母就有据可依（早段百分比不再发虚）
    try {
        if (-not $Demo -and $predTotal -gt 1) {
            [System.IO.File]::WriteAllText($expectedFile,
                (ConvertTo-Json @{ total = $predTotal; at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } -Compress),
                (New-Object System.Text.UTF8Encoding($false)))
        }
        # 阶段 1 的 CPU 分母同样跨轮缓存：本轮到挂载时用了多少 CPU，下轮就按这个估
        if (-not $Demo -and $cpuAtMount -gt 0.5) {
            [System.IO.File]::WriteAllText($cpuFile,
                (ConvertTo-Json @{ cpu = [math]::Round($cpuAtMount, 2); procs = $procCount } -Compress),
                (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch { }
    Say '=== 本次启动分段 ==='
    $rows = @(
        @{ n = '① 启动引擎（进程启动 → 观察者挂载）'; d = $dEngine },
        @{ n = '② 加载插件（首个激活 → 批量结束）'; d = $dPlugin },
        @{ n = '③ 准备服务（收尾等待 → host 就绪）'; d = $dServe },
        @{ n = '④ 呈现界面（就绪 → 窗口可见）'; d = $dWindow }
    )
    foreach ($r in $rows) {
        if ($null -eq $r.d) { Say ("  {0,-40} {1,8}" -f $r.n, '—') }
        else { Say ("  {0,-40} {1,7:N2}s  {2,5:N1}%" -f $r.n, $r.d, (100 * $r.d / [Math]::Max(0.01, $total))) }
    }
    Say ("  {0,-40} {1,7:N2}s" -f '合计', $total)
    Say ("  观察者记到的组件总数: {0}   最后阶段: {1}" -f $(if ($Demo) { '—（演示模式不采集）' } else { $lastActive }), $(if ($windowSeen) { '窗口已呈现' } elseif ($ready) { '就绪未见窗口' } else { '未就绪' }))
} catch {
    Say ('  汇总失败: ' + $_.Exception.Message)
}

Start-Sleep -Milliseconds 500
Stop-Panel
Say 'splash done'
# 释放日志句柄，避免下次运行被占用
try { if ($script:logWriter) { $script:logWriter.Flush(); $script:logWriter.Dispose(); $script:logWriter = $null } } catch { }
