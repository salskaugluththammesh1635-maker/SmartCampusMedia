# HDMI audio path regression: tone generator -> ACR -> PCM-to-PWM.
# Covers the audio chain that feeds BOTH the HDMI 1.4b transmitter core
# (audio samples + ACR packets) and the onboard PWM pin (F3).
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\s6_integration\audio',
    # vlog 编译宏（本套件所有 case 共用）
    #
    #   +define+SDRAM_SIM_MODEL
    #     让 rtl/storage/sdram_ctrl_wrap.v 例化文件内自带的行为模型，而不是
    #     Anlogic 加密核（ip/local/sdram/sdr_as_ram.enc.v）。ModelSim ASE 编不动
    #     那个加密核 —— vlog 直接 exit=2。sdram_ctrl_wrap.v:25-40 头注写明仿真
    #     与综合只能靠「文件级二选一 + 这个宏」分开。
    #     本套件 6 个源里没有任何 SDRAM 模块，宏在此处是惰性的；默认打开是为了
    #     t9 三个主力脚本（full / frontend / audio）行为一致 —— 三者用同一套
    #     编译宏，将来往里加端到端 case 时不会出现"某个 suite 悄悄编了加密核
    #     然后单独报 vlog exit=2"的假红。run_unit_coverage_regression.ps1 自
    #     2026-11-01 起就用该宏编 29 个 unit case 且全绿，可作无害性证据。
    [string[]]$VlogDefines = @('+define+SDRAM_SIM_MODEL')
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$sources = @(
    'rtl/audio/audio_tone_gen.v',
    'rtl/video/hdmi/audio_arc.v',
    'rtl/audio/pcm_to_pwm.v',
    'rtl/audio/pwm_audio_out.v',
    'sim/testbench/tb_hdmi_audio_path.v',
    'sim/testbench/tb_pwm_audio_out.v'
)
$hashes = @($sources | ForEach-Object {
    @{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }
})
$result = [ordered]@{ startedAt=(Get-Date).ToString('o'); status='running'; sources=$hashes; tests=@() }
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
$script:A4Ran    = 0
$script:A4Passed = 0
$ExpCaseCount  = 2    # audio 套件应有 case 数；tb 增删必须同步改这里

Push-Location $ReportDir
try {
    if (-not (Test-Path work)) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & "$ModelSimPath\vlog.exe" -quiet @VlogDefines @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    $cases = @(
        # The end-to-end chain: 48 kHz sample rate, ACR cadence, PWM duty,
        # per-state pitch (video/audio coupling) and mute semantics.
        @{name='hdmi_audio_path'; top='tb_hdmi_audio_path'; marker='ALL CHECKS PASSED: hdmi_audio_path'; arguments=@()},
        # Legacy PWM test tone module. It is no longer instantiated by the top
        # level (pcm_to_pwm replaced it) but stays in the source tree as the
        # documented rollback path, so it keeps its coverage.
        @{name='pwm_audio_out_legacy'; top='tb_pwm_audio_out'; marker='ALL CHECKS PASSED, errors = 0'; arguments=@()}
    )
    foreach ($case in $cases) {
        $script:A4Ran++
        $log = $case.name + '.txt'
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $case.arguments + @(
            '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
            ('work.' + $case.top)
        )
        & "$ModelSimPath\vsim.exe" @simArgs *> $log
        $exit = $LASTEXITCODE
        $content = [IO.File]::ReadAllText((Join-Path $ReportDir $log))
        # Two PASS conventions live in this tree: 'PASS: ...' (newer benches)
        # and 'PASS - ...' (tb_pwm_audio_out.v). Count the bare token, which
        # also can't match 'PASSED' because of the trailing word boundary.
        $checks = [regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS\b').Count
        $bad = $content -match 'CHECKS FAILED|GLOBAL TIMEOUT|(?:^|\n)\s*(?:#\s*)?(?:FAIL\b|TIMEOUT:)|\*\*\s+(?:Error|Fatal)\b'
        $passed = $exit -eq 0 -and $content.Contains($case.marker) -and $checks -gt 0 -and -not $bad
        $result.tests += @{ name=$case.name; passed=$passed; exitCode=$exit; passLines=$checks; log=$log; arguments=@($simArgs) }
        Write-Output ($case.name + ': passed=' + $passed + '; passLines=' + $checks)
        if ($passed) { $script:A4Passed++ } else { $failed = $true }
    }
    foreach ($source in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
            throw ('Source changed during validation: ' + $source.path)
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

    $result.ran = $script:A4Ran
    $result.passedCount = $script:A4Passed
    $result.expectedCaseCount = $ExpCaseCount
    $result.status = $(if ($failed) { 'failed' } else { 'passed' })
}
catch { $failed=$true; $result.status='failed'; $result.error=$_.Exception.Message; Write-Error -ErrorAction Continue $_ }
finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
if ($failed) { exit 1 }
exit 0
