# =============================================================================
# run_full_regression.ps1
# -----------------------------------------------------------------------------
# One command to run EVERY simulation suite in this repository and print a single
# pass/fail table.
#
#   powershell -ExecutionPolicy Bypass -File sim\scripts\run_full_regression.ps1
#   pwsh -File sim\scripts\run_full_regression.ps1 -Suite unit
#
# Suites (each is one existing script; this driver only orchestrates):
#   unit        run_unit_coverage_regression.ps1  18 module testbenches (NEW)
#   frontend    run_frontend_regression.ps1       SD/FAT32/BMP/player/OSD (20 TB)
#   storage     run_storage_regression.ps1        SDRAM/framebuf/retention
#   audio       run_audio_regression.ps1          audio path
#   startup     run_startup_ownership_regression.ps1  startup ownership
#   display     run_display_content.ps1           display content
#   image       run_image_regression.ps1          image path
#
# ORDER MATTERS ONLY FOR READABILITY - suites are independent. Each suite gets
# its own report directory and its own ModelSim work library.
#
# REPORT DIRECTORY
#   Defaults to <temp>\scm_full_regression\<suite>. Sub-directories cannot be
#   created inside the repository in this environment, so a temp default is the
#   only one that works out of the box. Override with -ReportRoot if your
#   checkout allows repo-local output.
# =============================================================================
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$PrimLibPath  = 'D:\TD_6_24_APP\sim_release\eg4',
    [string]$ReportRoot   = (Join-Path $env:TEMP 'scm_full_regression'),
    # Comma separated subset, e.g. -Suite unit,frontend. Empty means all.
    [string[]]$Suite      = @(),
    # Keep going after a failing suite and report the whole table.
    [switch]$ContinueOnError,
    # vlog 编译宏，本编排器**自己不编译任何源**，它只负责把宏转发给愿意接收的子
    # 套件脚本。
    #
    # 为什么需要一个统一入口：rtl/storage/sdram_ctrl_wrap.v:127 是
    #     `ifdef SDRAM_SIM_MODEL  -> 文件内自带行为模型
    #     `else                   -> Anlogic 加密核 sdr_as_ram.enc.v
    # ModelSim ASE 编不动加密核（vlog 直接 exit=2）。所以凡是要编到
    # sdram_ctrl_wrap 的套件都必须拿到这个宏，否则 T9 一跑就整片红。
    #
    # 但**不能无脑传给所有子脚本**：7 个子脚本里只有 run_frontend_regression.ps1
    # 与 run_audio_regression.ps1 声明了 [string[]]$VlogDefines 形参；其余（含
    # run_unit_coverage_regression.ps1，它连 CmdletBinding 都没有）收到未知参数
    # 会直接 "A parameter cannot be found that matches parameter name
    # 'VlogDefines'" 报错退出，本来绿的套件会被这个转发机制拖红。
    # 所以下面按「子脚本源码里是否出现 $VlogDefines」逐个判定，能接的才传。
    [string[]]$VlogDefines = @('+define+SDRAM_SIM_MODEL')
)

$ErrorActionPreference = 'Stop'

$repoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptsDir   = Join-Path $repoRoot 'sim\scripts'
New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null

# ---- Suite table -----------------------------------------------------------
#   script : file name under sim\scripts
#   title  : one-line description shown in the summary
#   extra  : extra arguments appended to the child invocation (optional)
# ---- A4 分母断言（t9 加）---------------------------------------------------
# 编排器同样有"一个套件都没跑也照样 PASS"的缺口：$failed 只在某套件红或脚本缺失时
# 置位，-$Suite 传了不存在的组合 / 全被过滤掉时 $results 为空、$failed 仍为 $false，
# 于是尾判据照旧打印 'FULL REGRESSION PASSED'。
# 期望套件数**不从 $results 反推**（那是同源自证：套件表被误删一条，期望值也跟着小，
# 断言永远成立），而是按"用户要的名单"独立算：不给 -Suite 就是全套 7 个。
# 计数器用 $script: 前缀：将来若把主循环包进函数，函数内 += 只改局部副本，
# 外层判据会永远看到 0 —— scripts\run_tb_baseline.ps1 头注记着这个坑。
$script:A4Ran    = 0
$script:A4Passed = 0
$ExpSuiteCount = 7

$allSuites = @(
    @{ name='unit';     script='run_unit_coverage_regression.ps1';      title='29 module unit testbenches';            extra=@() },
    @{ name='frontend'; script='run_frontend_regression.ps1';           title='SD/FAT32/BMP/player/OSD';               extra=@() },
    @{ name='storage';  script='run_storage_regression.ps1';            title='SDRAM / framebuf / retention';          extra=@() },
    @{ name='audio';    script='run_audio_regression.ps1';              title='audio tone / PWM / waveform path';      extra=@() },
    @{ name='startup';  script='run_startup_ownership_regression.ps1';  title='startup ownership handoff';             extra=@() },
    @{ name='display';  script='run_display_content.ps1';               title='display content verification';          extra=@() },
    @{ name='image';    script='run_image_regression.ps1';              title='image path regression';                 extra=@() }
)

# ---- Select the suites to run ---------------------------------------------
if ($Suite.Count -gt 0) {
    $wanted = @($Suite | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($wanted | Where-Object { $_ -notin @($allSuites | ForEach-Object { $_.name }) })
    if ($unknown.Count -gt 0) {
        throw ("Unknown suite(s): " + ($unknown -join ', ') +
               ". Known suites: " + (($allSuites | ForEach-Object { $_.name }) -join ', '))
    }
    $selected = @($allSuites | Where-Object { $_.name -in $wanted })
} else {
    $selected = $allSuites
}

# ---- Preflight -------------------------------------------------------------
foreach ($tool in @('vlib', 'vlog', 'vsim')) {
    $exe = Join-Path $ModelSimPath ($tool + '.exe')
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Missing ModelSim tool: $tool.exe under $ModelSimPath"
    }
}

$results  = @()
$failed   = $false
$startedAt = Get-Date

foreach ($s in $selected) {
    $scriptPath = Join-Path $scriptsDir $s.script
    $reportDir  = Join-Path $ReportRoot $s.name

    Write-Output ''
    Write-Output ('=== [' + $s.name + '] ' + $s.title + ' ===')

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Output ('  SKIP: script not found: ' + $s.script)
        $results += @{ name=$s.name; title=$s.title; status='missing'; exitCode=$null;
                       seconds=0; passLines=0; reportDir=$reportDir; note=('missing ' + $s.script) }
        $failed = $true
        continue
    }

    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
    $consoleLog = Join-Path $reportDir 'console.log'
    $t0 = Get-Date

    # Child scripts accept -ModelSimPath / -ReportDir uniformly.
    #
    # -VlogDefines 则**不是**uniform 的：只有 run_frontend_regression.ps1 和
    # run_audio_regression.ps1 声明了这个形参。其余子脚本收到它会立刻
    #   "A parameter cannot be found that matches parameter name 'VlogDefines'"
    # 报错退出（run_unit_coverage_regression.ps1 甚至没有 CmdletBinding，
    # 参数解析更严格），本来全绿的套件会被这个转发机制拖红。
    # 所以先读子脚本源码，出现 $VlogDefines 才把宏传下去。
    $childAcceptsDefines = $false
    try {
        $childSrc = [IO.File]::ReadAllText($scriptPath)
        $childAcceptsDefines = ($childSrc -match '\$VlogDefines')
    } catch { $childAcceptsDefines = $false }
    $childArgs = @('-ModelSimPath', $ModelSimPath, '-ReportDir', $reportDir)
    if ($childAcceptsDefines -and $VlogDefines.Count -gt 0) {
        $childArgs += @('-VlogDefines') + @($VlogDefines)
    }
    $childArgs += @($s.extra)

    # Run in a separate PowerShell process so one suite's Push-Location or
    # preference changes cannot leak into the next one.
    $psExe = (Get-Process -Id $PID).Path
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @childArgs *> $consoleLog
    $code = $LASTEXITCODE
    $secs = [int]((Get-Date) - $t0).TotalSeconds

    $console = ''
    if (Test-Path -LiteralPath $consoleLog) { $console = [IO.File]::ReadAllText($consoleLog) }

    # A suite counts as passed when it exits 0 and never printed a FAIL line.
    $sawFail = $console -match '(?m)^\s*(?:#\s*)?FAIL\b|CHECKS FAILED|GLOBAL TIMEOUT|\*\*\s+(?:Error|Fatal)\b'
    $status  = if (($code -eq 0) -and (-not $sawFail)) { 'passed' } else { 'failed' }
    if ($status -eq 'failed') { $failed = $true }

    # Count the assertions this suite actually verified. The console of a suite
    # script only carries its own summary table, so the numbers have to come
    # from its result.json. The existing suites do not share one schema, so try
    # every field name a suite might use before giving up.
    $suitePassLines = 0

    # Surface the per-suite result.json status when the script wrote one.
    $note = ''
    $rj = Join-Path $reportDir 'result.json'
    if (Test-Path -LiteralPath $rj) {
        try {
            $j = Get-Content -LiteralPath $rj -Raw | ConvertFrom-Json
            $note = 'result.json status=' + $j.status
            if ($j.PSObject.Properties.Name -contains 'tests') {
                # Some suites record a boolean `passed`, others a `status` string.
                $n = @($j.tests).Count
                $p = @($j.tests | Where-Object {
                    ($_.PSObject.Properties.Name -contains 'passed' -and $_.passed) -or
                    ($_.PSObject.Properties.Name -contains 'status' -and $_.status -eq 'passed')
                }).Count
                $note += (' tests=' + $p + '/' + $n)

                # Assertion count per test: `passLines` in the legacy suites,
                # `checks` in the diagnostic ones.
                foreach ($t in @($j.tests)) {
                    if ($t.PSObject.Properties.Name -contains 'passLines' -and $t.passLines) {
                        $suitePassLines += [int]$t.passLines
                    } elseif ($t.PSObject.Properties.Name -contains 'checks' -and $t.checks) {
                        $suitePassLines += [int]$t.checks
                    }
                }
            }
            # Suites that report a single aggregate count instead of per-test rows.
            if (($suitePassLines -eq 0) -and ($j.PSObject.Properties.Name -contains 'checks') -and $j.checks) {
                $suitePassLines = [int]$j.checks
                $note += (' checks=' + $j.checks)
                if ($j.PSObject.Properties.Name -contains 'errors') { $note += (' errors=' + $j.errors) }
            }
        } catch { $note = 'result.json unreadable' }
    }

    # Fallback for suites that write no result.json (startup ownership): count
    # the "# PASS:" lines they leave in their own per-case logs.
    if ($suitePassLines -eq 0) {
        foreach ($lg in @(Get-ChildItem -LiteralPath $reportDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
            $txt = [IO.File]::ReadAllText($lg.FullName)
            $suitePassLines += [regex]::Matches($txt, '(?m)^\s*(?:#\s*)?PASS:').Count
        }
    }

    if ($suitePassLines -gt 0) { $note += (' asserts=' + $suitePassLines) }

    Write-Output ('  ' + $status + '  exit=' + $code + '  ' + $secs + 's  ' + $note)

    $results += @{ name=$s.name; title=$s.title; status=$status; exitCode=$code;
                   seconds=$secs; passLines=$suitePassLines; reportDir=$reportDir; note=$note }

    if (($status -eq 'failed') -and (-not $ContinueOnError)) {
        Write-Output '  stopping after first failure (use -ContinueOnError to run all)'
        break
    }
}

# ---- A4 分母断言（t9 加）---------------------------------------------------
$script:A4Ran    = @($results).Count
$script:A4Passed = @($results | Where-Object { $_.status -eq 'passed' }).Count
if ($Suite.Count -gt 0) {
    # 用户点名跑子集时，期望数就是名单长度（名单来自命令行，不是本脚本的表）
    $ExpSuiteCount = @($Suite | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
                       Where-Object { $_ }).Count
}
if ($script:A4Ran -eq 0) {
    Write-Output '  A4-GATE: ran=0（一个套件都没跑却要打印通过，这是最该报警的状态）'
    $failed = $true
}
if ($script:A4Ran -ne $ExpSuiteCount) {
    Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' 与期望套件数 ' + $ExpSuiteCount + ' 不符（套件表被改过？）')
    $failed = $true
}
if ($script:A4Passed -ne $script:A4Ran) {
    Write-Output ('  A4-GATE: passed=' + $script:A4Passed + ' / ran=' + $script:A4Ran)
    $failed = $true
}
Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' passed=' + $script:A4Passed + ' expected=' + $ExpSuiteCount)

# ---- Summary table ---------------------------------------------------------
$elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
Write-Output ''
Write-Output '================ FULL REGRESSION SUMMARY ================'
$results | ForEach-Object {
    '{0,-10} {1,-8} exit={2,-6} {3,5}s  asserts={4,-7} {5}' -f `
        $_.name, $_.status.ToUpper(), $(if ($null -eq $_.exitCode) { 'n/a' } else { $_.exitCode }),
        $_.seconds, $_.passLines, $_.title
}
Write-Output ('--------------------------------------------------------')
$pass = @($results | Where-Object { $_.status -eq 'passed' }).Count
$totalPassLines = (@($results | ForEach-Object { $_.passLines }) | Measure-Object -Sum).Sum
if (-not $totalPassLines) { $totalPassLines = 0 }
Write-Output ('suites: passed=' + $pass + ' failed=' + (@($results).Count - $pass) +
              ' total=' + @($results).Count + '  asserts=' + $totalPassLines +
              '  elapsed=' + $elapsed + 's')

# ---- Machine readable summary ---------------------------------------------
$summary = [ordered]@{
    startedAt  = $startedAt.ToString('o')
    finishedAt = (Get-Date).ToString('o')
    status     = $(if ($failed) { 'failed' } else { 'passed' })
    modelSimPath = $ModelSimPath
    primLibPath  = $PrimLibPath
    # 记下这次编排携带的编译宏，便于 t9 报告直接引用（哪些子套件真正收到，
    # 见各自 result.json 里的 arguments）。
    vlogDefines  = @($VlogDefines)
    reportRoot   = $ReportRoot
    elapsedSeconds = $elapsed
    totalPassLines = $totalPassLines
    ran            = $script:A4Ran
    passedCount    = $script:A4Passed
    expectedSuiteCount = $ExpSuiteCount
    suites     = $results
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $ReportRoot 'summary.json') -Encoding utf8

if ($failed) {
    Write-Output 'FULL REGRESSION FAILED'
    exit 1
}
Write-Output 'FULL REGRESSION PASSED'
exit 0
