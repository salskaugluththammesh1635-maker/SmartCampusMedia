# 存储链路的本地 ModelSim 自检；失败退出非零，不能把 $finish 误认为通过。
[CmdletBinding()]
param(
    [ValidateSet('All', 'Fifo', 'Arbiter', 'Model', 'Pixels')]
    [string]$Suite = 'All',
    [switch]$FullVga,
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\s6_validation'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
$out = [IO.Path]::GetFullPath($ReportDir)
New-Item -ItemType Directory -Path $out -Force | Out-Null
$tools = @{}
foreach ($tool in @('vlib', 'vlog', 'vsim')) {
    $candidate = Join-Path $ModelSimPath "$tool.exe"
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "找不到 ModelSim 工具：$candidate；请用 -ModelSimPath 指定安装目录。"
    }
    $tools[$tool] = $candidate
}
$sources = @(
    'rtl\common\async_fifo.v',
    'rtl\video\video_timing_gen.v',
    'rtl\storage\framebuf_arbiter.v',
    'rtl\storage\sdram_ctrl_wrap.v',
    'rtl\storage\pix_reader.v',
    # t10 补覆盖：rle_decoder 是科普模式视频通路的核心模块，此前没有任何回归
    # 套件引用 tb_rle_decoder.v（sim/testbench 下 78 个 tb 里 10 个孤儿之一）。
    # 它验证的正是 t9 修的 P0-A2 归属门控（外来 blk_done 不得推进块计数）。
    'rtl\storage\rle_decoder.v',
    'sim\testbench\tb_async_fifo.v',
    'sim\testbench\tb_framebuf_arbiter.v',
    'sim\testbench\tb_sdram_ctrl_wrap.v',
    'sim\testbench\tb_pix_reader.v',
    'sim\testbench\tb_rle_decoder.v'
)
$sourceHashes = foreach ($source in $sources) {
    $sourcePath = Join-Path $root $source
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "源文件缺失：$source" }
    [ordered]@{ path = $source; sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash }
}
$manifest = [ordered]@{
    suite = $Suite; fullVgaRequested = [bool]$FullVga
    startedAt = (Get-Date).ToString('o'); modelSimPath = $ModelSimPath
    compileExit = $null; status = 'running'; sources = @($sourceHashes); tests = @()
}
$manifestPath = Join-Path $out 'result.json'
$failed = $false

# ---- A4 分母断言（t9 加）---------------------------------------------------
# 只断言「没有失败」在「一个 case 都没跑」时同样成立，而「一个 case 都没跑」
# 恰恰是最该报警的状态。收尾必须同时断言分母三件事：
#   1) $script:A4Ran -gt 0               真的跑了
#   2) $script:A4Ran -eq $ExpCaseCount   跑够没有（与下面的期望数比，不同源自证）
#   3) $script:A4Passed -eq $script:A4Ran  全过了没有
# 必须用 $script: 前缀：将来若把主循环包进函数，函数里的 += 改的是局部副本，
# 外层判据会永远看到 0 → 照样打印 PASS（scripts\run_tb_baseline.ps1 头注记着这坑）。
# 期望数是**硬编码**的、刻意不用 @($cases).Count：后者是同源自证，case 表被误删
# 时期望值会跟着一起变小，断言永远成立、永远抓不到。
# storage 的 case 数由 -Suite / -FullVga 两个参数决定。这里**独立**
# 重算期望数（不读 $tests），所以 tests 表被误删一条时期望数不变 → 断言红。
# t10：把孤儿 TB tb_rle_decoder 补进套件，All 的 case 数 4 -> 5。
$ExpCaseCount = $(if ($Suite -eq 'All') { 5 } else { 1 }) + $(if ($FullVga) { 1 } else { 0 })
$script:A4Ran    = 0
$script:A4Passed = 0

Push-Location $out
try {
    if (-not (Test-Path -LiteralPath 'work')) {
        & $tools.vlib work *> vlib.log
        if ($LASTEXITCODE -ne 0) { throw "vlib 失败，退出码 $LASTEXITCODE；详见 vlib.log。" }
    }
    $compileArgs = @('-quiet', '+define+SDRAM_SIM_MODEL') + @($sources | ForEach-Object { Join-Path $root $_ })
    & $tools.vlog @compileArgs *> compile.log
    $manifest.compileExit = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { throw "vlog 编译失败，退出码 $LASTEXITCODE；未运行任何旧二进制。详见 compile.log。" }
    $tests = @()
    if ($Suite -in @('All', 'Fifo')) {
        $tests += @{ name = 'tb_async_fifo'; top = 'tb_async_fifo'; marker = 'ALL CHECKS PASSED: async_fifo'; arguments = @() }
    }
    if ($Suite -in @('All', 'Arbiter')) {
        $tests += @{ name = 'tb_framebuf_arbiter'; top = 'tb_framebuf_arbiter'; arguments = @() }
    }
    if ($Suite -in @('All', 'Model')) {
        $tests += @{ name = 'tb_sdram_ctrl_wrap'; top = 'tb_sdram_ctrl_wrap'; arguments = @() }
    }
    if ($Suite -in @('All', 'Pixels')) {
        $tests += @{ name = 'tb_pix_reader'; top = 'tb_pix_reader'; arguments = @() }
    }
    # tb_rle_decoder 的向量用相对路径 ../testbench/vectors/*.hex，只有 cwd 落在
    # sim/ 的下一层目录时才能解析。故单独给它一个 cwd（sim/_regression_rle），
    # 并用绝对 work 映射（vmap + -modelsimini）把编译好的库接回来 ——
    # 直接把 cwd 改成 sim/testbench 反而找不到 work 库（vsim-19）。
    # 它的收尾行是 "RESULT: PASS"（不是 "ALL CHECKS PASSED: ..."），且 summary
    # 不带 cases= 字段，故显式给 marker 与硬编码的 casesFallback=8。
    if ($Suite -in @('All', 'Pixels')) {
        $tests += @{
            name = 'tb_rle_decoder'; top = 'tb_rle_decoder'; arguments = @()
            workCwd = (Join-Path $root 'sim\_regression_rle')
            marker = 'RESULT: PASS'
            casesFallback = 8
        }
    }
    if ($FullVga) {
        $tests += @{
            name = 'tb_pix_reader_vga'; top = 'tb_pix_reader'
            arguments = @('-gPIX_PER_LINE=640', '-gLINES=480', '-gH_FP=16', '-gH_SYNC=96',
                '-gH_BP=48', '-gV_FP=10', '-gV_SYNC=2', '-gV_BP=33',
                '-gFIFO_AW=9', '-gLEVEL_HI=384', '-gSTRESS=0')
        }
    }
    foreach ($test in $tests) {
        $script:A4Ran++
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $logPath = Join-Path $out ($test.name + '.log')
        $do = 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0'
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $test.arguments + @('-do', $do, ('work.' + $test.top))
        # 需要专用 cwd 的用例（当前只有 tb_rle_decoder）：在它的目录里跑，并用
        # -modelsimini 指回绝对 work 映射。路径必须用正斜杠：反斜杠会被 -do 里的
        # Tcl 当转义吃掉（实测变成 "D:FPGA_Compelate..."，报 vsim-7）。
        $runCwd = $out
        if ($test.ContainsKey('workCwd')) {
            $runCwd = $test.workCwd
            New-Item -ItemType Directory -Path $runCwd -Force | Out-Null
            # vmap fixed output name: <cwd>/modelsim.ini
            Push-Location $out
            try { & (Join-Path $ModelSimPath 'vmap.exe') work (Join-Path $out 'work') *> vmap.log }
            finally { Pop-Location }
            if ($LASTEXITCODE -ne 0) { throw "vmap 失败，退出码 $LASTEXITCODE；详见 vmap.log。" }
            $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $test.arguments + @(
                '-modelsimini', (Join-Path $out 'modelsim.ini').Replace('\', '/'),
                '-do', $do, ('work.' + $test.top))
        }
        Push-Location $runCwd
        try { & $tools.vsim @simArgs *> $logPath } finally { Pop-Location }
        $exit = $LASTEXITCODE
        $clock.Stop()
        $logText = [IO.File]::ReadAllText($logPath)
        $marker = 'ALL CHECKS PASSED: ' + $test.top
        if ($test.ContainsKey('marker')) { $marker = $test.marker }
        $summary = [regex]::Match($logText, 'SUMMARY:\s*checks=(\d+)\s+errors=(\d+)\s+cases=(\d+)')
        # 部分 TB（如 tb_rle_decoder）的 summary 不带 cases= 字段，此时退回两段式
        # 正则并用硬编码的 casesFallback 兜底；兜底值不随 case 表变化，仍能抓到
        # "少跑了" 这种情况（同 A4 分母断言的思路）。
        $hasCases = $summary.Success
        if (-not $hasCases -and $test.ContainsKey('casesFallback')) {
            $summary = [regex]::Match($logText, 'SUMMARY:\s*checks=(\d+)\s+errors=(\d+)')
        }
        $casesSeen = 0
        if ($summary.Success) {
            if ($hasCases) { $casesSeen = [int]$summary.Groups[3].Value }
            elseif ($test.ContainsKey('casesFallback')) { $casesSeen = [int]$test.casesFallback }
        }
        $bad = $logText -match '(?m)^\s*(?:#\s*)?(?:FAIL(?:ED)?\b|.*GLOBAL TIMEOUT|.*CHECKS FAILED)' -or
            $logText -match '\*\*\s+(?:Error|Fatal)\b'
        $passed = $exit -eq 0 -and $logText.Contains($marker) -and -not $bad -and
            $summary.Success -and [int]$summary.Groups[1].Value -gt 0 -and
            [int]$summary.Groups[2].Value -eq 0 -and $casesSeen -gt 0
        $result = [ordered]@{
            name = $test.name; status = $(if ($passed) { 'passed' } else { 'failed' })
            exitCode = $exit; log = $logPath; seconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
            checks = $(if ($summary.Success) { [int]$summary.Groups[1].Value } else { 0 })
            errors = $(if ($summary.Success) { [int]$summary.Groups[2].Value } else { $null })
            cases = $casesSeen
            arguments = @($simArgs)
        }
        $manifest.tests += $result
        Write-Output ('{0}: {1}; exit={2}; checks={3}; errors={4}; cases={5}; log={6}' -f
            $test.name, $result.status, $exit, $result.checks, $result.errors, $result.cases, $logPath)
        if ($passed) { $script:A4Passed++ } else { $failed = $true }
    }
    # 编译和运行期间源文件不得漂移，否则证据不能绑定到最终源码。
    foreach ($source in $sourceHashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
            throw "验证期间源文件被并发修改：$($source.path)；本轮证据失效，请重跑。"
        }
    }
    # ---- A4 分母断言（t9 加）--------------------------------------------
    if ($script:A4Ran -eq 0) {
        Write-Output ('  A4-GATE: ran=0（一个 case 都没跑却要打印通过，这是最该报警的状态）')
        $failed = $true
    }
    if ($script:A4Ran -ne $ExpCaseCount) {
        Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' 与期望 case 数 ' + $ExpCaseCount + ' 不符（case 表被改过？）')
        $failed = $true
    }
    if ($script:A4Passed -ne $script:A4Ran) {
        Write-Output ('  A4-GATE: passed=' + $script:A4Passed + ' / ran=' + $script:A4Ran)
        $failed = $true
    }
    Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' passed=' + $script:A4Passed + ' expected=' + $ExpCaseCount)

    $manifest.ran = $script:A4Ran
    $manifest.passedCount = $script:A4Passed
    $manifest.expectedCaseCount = $ExpCaseCount
    $manifest.status = $(if ($failed) { 'failed' } else { 'passed' })
}
catch {
    $failed = $true
    $manifest.status = 'failed'
    $manifest.failure = $_.Exception.Message
    Write-Error -ErrorAction Continue $_
}
finally {
    $manifest.finishedAt = (Get-Date).ToString('o')
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Pop-Location
}
if ($failed) { exit 1 }
exit 0
