# =============================================================================
# run_tb_baseline.ps1 — 三条基线复跑（captain m03010 / m03034 要求）
#
# 为什么单独写脚本而不手敲：三条 tb 的编译集、顶层名、plusargs 都不同，
# 手敲一次记错一个 `-L` 就会「编译过了但仿真跑了另一个 tb」。
# 判据必须来自 tb 自己打印的 SUMMARY/ALL CHECKS，不能靠人看日志。
#
# 判据（脚本自己判）：
#   tb_pix_reader      ALL CHECKS PASSED + checks=542 errors=0 cases=39
#   tb_image_player    ALL CHECKS PASSED + checks=11405 errors=0
#
# 期望值变更史（改这里必须同步改下面的 -ExpectLine，否则会误报 FAIL）：
#   tb_pix_reader   194/13 → 542/39   946f74f 提交 v2 新 tb 时脚本未同步（历史遗留）
#   tb_image_player 11365  → 11405    2026-11-03 t7 补 CASE16/CASE17 与 disp_geom 断言
#   tb_display_content ALL CHECKS PASSED + checks=614406 errors=0
#   tb_fifo_fwft       ALL CHECKS PASSED + errors=0
#
# 纪律（captain）：红了立刻停，**不要改 tb 适配**。
#
# ------------------------------------------------------------------------------
# 第一版两个缺陷（实跑抓到，写在这里防复发）：
#   1. `Push-Location $libdir` 之后用**相对路径** `$Sources` 调 vlog →
#      `vlog-7 Failed to open design unit file "rtl\common\async_fifo.v"`。
#      修法：先把每个源文件解析成绝对路径（在 Push-Location 之前）。
#   2. `$fail += ...` 写在函数里 → PowerShell 函数内的 `+=` 改的是**局部副本**，
#      外层 `$fail` 永远是空数组 ⇒ vlog 明明失败，脚本仍打印 `RESULT: PASS`。
#      这是第六条盲区的又一实例（判据工具永远返回通过）。
#      修法：用 `$script:fail` 显式写作用域，并在退出前再断言一次「跑过的 tb 数」。
# =============================================================================
param(
    [string[]]$Only = @(),        # 只跑指定的（如 -Only pix_reader）
    [switch]$KeepLib              # 保留 work 库便于复查
)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root

$MS = 'D:\Quartus_APP\modelsim_ase\win32aloem'
$VLIB = Join-Path $MS 'vlib.exe'
$VLOG = Join-Path $MS 'vlog.exe'
$VSIM = Join-Path $MS 'vsim.exe'

foreach ($t in @($VLIB, $VLOG, $VSIM)) {
    if (-not (Test-Path $t)) { Write-Host "!! 缺工具: $t"; exit 2 }
}

$env:PYTHONIOENCODING = 'utf-8'
$script:fail = @()
$script:ran = 0
$script:passed = 0

function Run-Tb {
    param(
        [string]$Name,            # 显示名
        [string]$Top,             # vsim 顶层
        [string[]]$Sources,       # 要 vlog 的文件（相对 $Root）
        [string[]]$PlusArgs,      # vsim plusargs
        [string]$ExpectLine       # 必须命中的 SUMMARY 行正则
    )
    Write-Host ''
    Write-Host ('=' * 72)
    Write-Host "  $Name   (top=$Top)"
    Write-Host ('=' * 72)
    $script:ran++

    # 缺陷 1 的修法：Push-Location 之前解析成绝对路径
    $abs = @()
    $missing = @()
    foreach ($s in $Sources) {
        $full = Join-Path $Root $s
        if (Test-Path $full) { $abs += (Resolve-Path $full).Path }
        else { $missing += $s }
    }
    if ($missing.Count -gt 0) {
        Write-Host "  !! 缺源文件: $($missing -join ', ')"
        $script:fail += "$Name(missing-src)"
        return
    }

    $libdir = Join-Path $env:TEMP "t7b_lib_$($Top)"
    if (Test-Path $libdir) { Remove-Item $libdir -Recurse -Force }
    New-Item -ItemType Directory -Path $libdir | Out-Null

    # vlib work 必须在库目录里建（vlog -work <绝对路径> 会报 vlog-19）
    Push-Location $libdir
    try {
        & $VLIB work 2>&1 | Out-Null
        $vlogArgs = @('-work', 'work', '-quiet', '+define+SDRAM_SIM_MODEL') + $abs
        $vlogOut = & $VLOG @vlogArgs 2>&1
        $vlogExit = $LASTEXITCODE
        $vlogErr = ($vlogOut | Select-String -Pattern '\*\* Error' -SimpleMatch).Count
        Write-Host "  VLOG_EXIT=$vlogExit  VLOG_ERRORS=$vlogErr"
        if ($vlogExit -ne 0 -or $vlogErr -gt 0) {
            $vlogOut | Select-String -Pattern '\*\* Error' | Select-Object -First 5 |
                ForEach-Object { Write-Host "  | $($_.Line.Trim())" }
            $script:fail += "$Name(vlog)"
            return
        }

        $do = 'run -all; quit -f'
        $vsimArgs = @('-c', '-quiet', '-do', $do, '-lib', 'work', $Top) + $PlusArgs
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $simOut = & $VSIM @vsimArgs 2>&1
        $sw.Stop()
        $simExit = $LASTEXITCODE
        Write-Host "  VSIM_EXIT=$simExit  WALL_SEC=$([int]$sw.Elapsed.TotalSeconds)"

        $txt = ($simOut | Out-String)
        foreach ($ln in ($simOut | Select-String -Pattern 'SUMMARY:|ALL CHECKS|FAILED:|Error:')) {
            Write-Host "  | $($ln.Line.Trim())"
        }

        $passedOk = ($txt -match 'ALL CHECKS PASSED')
        $expectOk = ($txt -match $ExpectLine)
        if ($passedOk -and $expectOk) {
            Write-Host '  -> PASS'
            $script:passed++
        } else {
            if (-not $passedOk) {
                Write-Host '  -> **FAIL：没有 ALL CHECKS PASSED**'
                $script:fail += "$Name(not-passed)"
            }
            if (-not $expectOk) {
                Write-Host "  -> **FAIL：SUMMARY 不匹配期望 '$ExpectLine'**"
                $script:fail += "$Name(expect)"
            }
        }
    } finally {
        Pop-Location
        if (-not $KeepLib) { Remove-Item $libdir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($Only.Count -eq 0 -or $Only -contains 'fifo_fwft') {
    Run-Tb -Name 'tb_fifo_fwft' -Top 'tb_fifo_fwft' `
        -Sources @(
'rtl\common\async_fifo.v',
                   'sim\testbench\tb_fifo_fwft.v',
                   'ip\local\sdram\global_def.v') `
        -PlusArgs @() -ExpectLine 'errors=0'
}

if ($Only.Count -eq 0 -or $Only -contains 'pix_reader') {
    # 缺陷 3（实跑抓到）：第一版只编了 async_fifo + pix_reader + tb，
    # 但 tb 内部还例化了 video_timing_gen / sdram_ctrl_wrap / framebuf_arbiter，
    # vlog 不做 elaborate 所以 EXIT=0 全绿，到 vsim 才报三个 vsim-3033。
    # 教训：**vlog 通过不等于能仿真**，源文件清单必须按 tb 里的例化逐个核。
    Run-Tb -Name 'tb_pix_reader' -Top 'tb_pix_reader' `
        -Sources @(
'rtl\common\async_fifo.v',
                   'rtl\storage\framebuf_arbiter.v',
                   'rtl\storage\pix_reader.v',
                   'rtl\storage\sdram_ctrl_wrap.v',
                   'rtl\video\video_timing_gen.v',
                   'sim\testbench\tb_pix_reader.v',
                   'ip\local\sdram\global_def.v') `
        -PlusArgs @() -ExpectLine 'checks=542 errors=0'
}

if ($Only.Count -eq 0 -or $Only -contains 'image_player') {
    Run-Tb -Name 'tb_image_player' -Top 'tb_image_player' `
        -Sources @(
'rtl\common\async_fifo.v',
                   'rtl\storage\bmp_parser.v',
                   'rtl\storage\fade_mixer.v',
                   'rtl\storage\fat32_reader.v',
                   'rtl\storage\framebuf_arbiter.v',
                   'rtl\storage\image_player.v',
                   'rtl\storage\img_loader.v',
                   'rtl\storage\img_scaler.v',
                   'rtl\storage\pix_reader.v',
                   'rtl\storage\sdram_ctrl_wrap.v',
                   'rtl\video\image_window_mask.v',
                   'rtl\video\video_timing_gen.v',
                   'sim\testbench\tb_image_player.v',
                   'ip\local\sdram\global_def.v') `
        -PlusArgs @() -ExpectLine 'checks=11405 errors=0'
}

if ($Only.Count -eq 0 -or $Only -contains 'display_content') {
    # 这条 tb 的参考数据靠 plusargs 传，且必须是**绝对路径**：
    # vsim 在 $env:TEMP 的库目录里跑，相对路径会 $readmemh 失败（静默读全 0，
    # 然后 checks=614406 但 errors 巨大，看起来像 RTL 坏了）。
    $gold = Join-Path $Root 'reports\diag_key1_baseline2'
    $plus = @(
        ('+disk='   + (Join-Path $gold 'disk.hex')),
        ('+golden=' + (Join-Path $gold 'golden.hex')),
        ('+golden2='+ (Join-Path $gold 'golden2.hex'))
    )
    Run-Tb -Name 'tb_display_content' -Top 'tb_display_content' `
        -Sources @(
'rtl\common\async_fifo.v',
                   'rtl\storage\bmp_parser.v',
                   'rtl\storage\fade_mixer.v',
                   'rtl\storage\fat32_reader.v',
                   'rtl\storage\framebuf_arbiter.v',
                   'rtl\storage\image_player.v',
                   'rtl\storage\img_loader.v',
                   'rtl\storage\img_scaler.v',
                   'rtl\storage\pix_reader.v',
                   'rtl\storage\sdram_ctrl_wrap.v',
                   'rtl\video\image_window_mask.v',
                   'rtl\video\video_timing_gen.v',
                   'sim\testbench\tb_display_content.v',
                   'ip\local\sdram\global_def.v') `
        -PlusArgs $plus -ExpectLine 'checks=614406 errors=0'
}

Write-Host ''
Write-Host ('=' * 72)
# 缺陷 2 的修法：除了 $fail 为空，还要断言「至少跑过 1 个且全过」
Write-Host "  跑过 $script:ran 个 / 通过 $script:passed 个 / 失败项 $($script:fail.Count) 个"
if ($script:fail.Count -eq 0 -and $script:ran -gt 0 -and $script:passed -eq $script:ran) {
    Write-Host '  RESULT: PASS  基线全绿'
    exit 0
} else {
    if ($script:fail.Count -gt 0) {
        Write-Host "  RESULT: FAIL  $($script:fail -join '; ')"
    } else {
        Write-Host '  RESULT: FAIL  计数不一致（fail 为空但 ran/passed 对不上）'
    }
    Write-Host '  （纪律：红了立刻停下报告，不要改 tb 适配）'
    exit 1
}
