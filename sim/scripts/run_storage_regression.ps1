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
    'sim\testbench\tb_async_fifo.v',
    'sim\testbench\tb_framebuf_arbiter.v',
    'sim\testbench\tb_sdram_ctrl_wrap.v',
    'sim\testbench\tb_pix_reader.v'
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
    if ($FullVga) {
        $tests += @{
            name = 'tb_pix_reader_vga'; top = 'tb_pix_reader'
            arguments = @('-gPIX_PER_LINE=640', '-gLINES=480', '-gH_FP=16', '-gH_SYNC=96',
                '-gH_BP=48', '-gV_FP=10', '-gV_SYNC=2', '-gV_BP=33',
                '-gFIFO_AW=9', '-gLEVEL_HI=384', '-gSTRESS=0')
        }
    }
    foreach ($test in $tests) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $logPath = Join-Path $out ($test.name + '.log')
        $do = 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0'
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $test.arguments + @('-do', $do, ('work.' + $test.top))
        & $tools.vsim @simArgs *> $logPath
        $exit = $LASTEXITCODE
        $clock.Stop()
        $logText = [IO.File]::ReadAllText($logPath)
        $marker = 'ALL CHECKS PASSED: ' + $test.top
        if ($test.ContainsKey('marker')) { $marker = $test.marker }
        $summary = [regex]::Match($logText, 'SUMMARY:\s*checks=(\d+)\s+errors=(\d+)\s+cases=(\d+)')
        $bad = $logText -match '(?m)^\s*(?:#\s*)?(?:FAIL(?:ED)?\b|.*GLOBAL TIMEOUT|.*CHECKS FAILED)' -or
            $logText -match '\*\*\s+(?:Error|Fatal)\b'
        $passed = $exit -eq 0 -and $logText.Contains($marker) -and -not $bad -and
            $summary.Success -and [int]$summary.Groups[1].Value -gt 0 -and
            [int]$summary.Groups[2].Value -eq 0 -and [int]$summary.Groups[3].Value -gt 0
        $result = [ordered]@{
            name = $test.name; status = $(if ($passed) { 'passed' } else { 'failed' })
            exitCode = $exit; log = $logPath; seconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
            checks = $(if ($summary.Success) { [int]$summary.Groups[1].Value } else { 0 })
            errors = $(if ($summary.Success) { [int]$summary.Groups[2].Value } else { $null })
            cases = $(if ($summary.Success) { [int]$summary.Groups[3].Value } else { 0 })
            arguments = @($simArgs)
        }
        $manifest.tests += $result
        Write-Output ('{0}: {1}; exit={2}; checks={3}; errors={4}; cases={5}; log={6}' -f
            $test.name, $result.status, $exit, $result.checks, $result.errors, $result.cases, $logPath)
        if (-not $passed) { $failed = $true }
    }
    # 编译和运行期间源文件不得漂移，否则证据不能绑定到最终源码。
    foreach ($source in $sourceHashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
            throw "验证期间源文件被并发修改：$($source.path)；本轮证据失效，请重跑。"
        }
    }
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
