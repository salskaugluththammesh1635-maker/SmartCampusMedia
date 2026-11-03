# Independent library for SD image integration; explicit pass markers and source hashes.
[CmdletBinding()]
param(
    [switch]$FullVga,
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\s6_integration\simulation'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$sources = @(
    'rtl/common/async_fifo.v', 'rtl/video/video_timing_gen.v',
    'rtl/video/image_window_mask.v',
    'rtl/storage/framebuf_arbiter.v', 'rtl/storage/sdram_ctrl_wrap.v',
    'rtl/storage/pix_reader.v', 'rtl/storage/fade_mixer.v', 'rtl/storage/fat32_reader.v',
    'rtl/storage/bmp_parser.v', 'rtl/storage/img_loader.v', 'rtl/storage/img_scaler.v',
    'rtl/storage/image_player.v',
    'sim/testbench/tb_image_player.v', 'sim/testbench/tb_img_scaler.v',
    # t10 补覆盖：image_window_mask 是 t7 修的"窗口外漏旧帧"判决器。此前没有
    # 任何回归套件引用 tb_image_window_mask.v（78 个 tb 里 10 个孤儿之一）。
    # 它验证 in_window 与 in_image 的交集判决、以及 img_w=0 的全屏蔽语义。
    'sim/testbench/tb_image_window_mask.v'
)
$hashes = @($sources | ForEach-Object {
    $file = Join-Path $root $_
    @{ path = $_; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
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
# image 默认 4 个 case，-FullVga 再追加 2 个。期望数独立算，不读 \$cases。
# t10 把孤儿 TB tb_image_window_mask 补进套件，默认 case 数 3 -> 4。
$ExpCaseCount = 4 + $(if ($FullVga) { 2 } else { 0 })
$script:A4Ran    = 0
$script:A4Passed = 0

Push-Location $ReportDir
try {
    if (-not (Test-Path work)) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & "$ModelSimPath\vlog.exe" -quiet +define+SDRAM_SIM_MODEL @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    # marker 是该用例在日志里必须出现的通过标记，允许同一 testbench 跑不同参数组合。
    # image_player_scaled 是 C2 自适应缩放的端到端用例：96×64 源图缩到 32×16 容器，
    # 验证取整、居中、只写窗口、letterbox 屏蔽四件事。
    $cases = @(
        @{name='img_scaler'; top='tb_img_scaler'; marker='img_scaler'; arguments=@()},
        @{name='image_player'; arguments=@(); marker='image_player'},
        @{name='image_player_scaled'; arguments=@('-gSCALE=1'); marker='image_player_scaled'},
        # t10 补覆盖：t7 的交集判决器（窗口外不再漏出上一帧残影）
        @{name='image_window_mask'; top='tb_image_window_mask'; marker='image_window_mask'; arguments=@()}
    )
    if ($FullVga) {
        $cases += @{name='image_player_full'; arguments=@('-gFULL=1'); marker='image_player_full'}
        $cases += @{name='image_player_single'; arguments=@('-gSEAMLESS=0'); marker='image_player'}
    }
    foreach ($case in $cases) {
        $script:A4Ran++
        $log = $case.name + '.txt'
        $top = 'tb_image_player'
        if ($case.ContainsKey('top')) { $top = $case.top }
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $case.arguments + @(
            '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
            ('work.' + $top)
        )
        & "$ModelSimPath\vsim.exe" @simArgs *> $log
        $exit = $LASTEXITCODE
        $content = [IO.File]::ReadAllText((Join-Path $ReportDir $log))
        $summary = [regex]::Match($content, 'SUMMARY:.*?checks=(\d+)\s+errors=(\d+)')
        $passed = $exit -eq 0 -and $content.Contains('ALL CHECKS PASSED: '+$case.marker) -and
            $summary.Success -and [int]$summary.Groups[1].Value -gt 0 -and
            [int]$summary.Groups[2].Value -eq 0 -and
            $content -notmatch 'CHECKS FAILED|(?:^|\n)#\s*FAIL\b|\*\*\s+(?:Error|Fatal)\b'
        $result.tests += @{ name=$case.name; passed=$passed; exitCode=$exit;
            checks=$(if($summary.Success){[int]$summary.Groups[1].Value}else{0}); log=$log }
        Write-Output ($case.name + ': passed=' + $passed)
        if ($passed) { $script:A4Passed++ } else { throw ('Simulation failed: '+$log) }
    }
    foreach ($file in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $file.path) -Algorithm SHA256).Hash -ne $file.sha256) {
            throw ('Source changed during validation: '+$file.path)
        }
    }
    # ---- A4 分母断言（t9 加）--------------------------------------------
    if ($script:A4Ran -eq 0) {
        Write-Output ('  A4-GATE: ran=0（一个 case 都没跑却要打印通过，这是最该报警的状态）')
        throw ('A4-GATE failed')
    }
    if ($script:A4Ran -ne $ExpCaseCount) {
        Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' 与期望 case 数 ' + $ExpCaseCount + ' 不符（case 表被改过？）')
        throw ('A4-GATE failed')
    }
    if ($script:A4Passed -ne $script:A4Ran) {
        Write-Output ('  A4-GATE: passed=' + $script:A4Passed + ' / ran=' + $script:A4Ran)
        throw ('A4-GATE failed')
    }
    Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' passed=' + $script:A4Passed + ' expected=' + $ExpCaseCount)

    $result.ran = $script:A4Ran
    $result.passedCount = $script:A4Passed
    $result.expectedCaseCount = $ExpCaseCount
    $result.status = 'passed'
}
catch { $result.status='failed'; $result.error=$_.Exception.Message; throw }
finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
