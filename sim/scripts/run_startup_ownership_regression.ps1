[CmdletBinding()]
param(
  [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
  [string]$ReportDir = 'reports\startup_ownership'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
$ReportDir = [IO.Path]::GetFullPath($ReportDir)
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
foreach ($tool in @('vlib','vlog','vsim')) {
  if (-not (Test-Path -LiteralPath (Join-Path $ModelSimPath ($tool+'.exe')))) {
    throw "Missing ModelSim tool: $tool.exe under $ModelSimPath"
  }
}
$sources = @(
  'rtl/common/async_fifo.v','rtl/video/image_window_mask.v',
  'rtl/storage/framebuf_arbiter.v','rtl/storage/sdram_ctrl_wrap.v',
  'rtl/storage/pix_reader.v','rtl/storage/fade_mixer.v',
  'rtl/storage/fat32_reader.v','rtl/storage/bmp_parser.v',
  'rtl/storage/img_loader.v','rtl/storage/img_scaler.v',
  'rtl/storage/image_player.v','rtl/storage/gallery_probe.v',
  'sim/testbench/tb_startup_ownership.v'
)
# ---- A4 分母断言（t9 加）---------------------------------------------------
# 本套件原本完全靠 throw 传播失败、没有任何汇总计数：一个 case 都没跑时
# 也会正常走完 finally 并"成功"返回。这里补上分母三断言。
# 只断言「没有失败」在「一个 case 都没跑」时同样成立，而「一个 case 都没跑」
# 恰恰是最该报警的状态。收尾必须同时断言分母三件事：
#   1) $script:A4Ran -gt 0               真的跑了
#   2) $script:A4Ran -eq $ExpCaseCount   跑够没有（与下面的期望数比，不同源自证）
#   3) $script:A4Passed -eq $script:A4Ran  全过了没有
# 必须用 $script: 前缀：将来若把主循环包进函数，函数里的 += 改的是局部副本，
# 外层判据会永远看到 0 → 照样打印 PASS（scripts\run_tb_baseline.ps1 头注记着这坑）。
# 期望数是**硬编码**的、刻意不用 @($cases).Count：后者是同源自证，case 表被误删
# 时期望值会跟着一起变小，断言永远成立、永远抓不到。
$failed = $false
$script:A4Ran    = 0
$script:A4Passed = 0
$ExpCaseCount  = 2    # startup 套件应有 case 数；case 表增删必须同步改这里

Push-Location $ReportDir
try {
  if (-not (Test-Path work)) {
    & (Join-Path $ModelSimPath 'vlib.exe') work *> vlib.log
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed; inspect vlib.log' }
  }
  & (Join-Path $ModelSimPath 'vlog.exe') -quiet +define+SDRAM_SIM_MODEL @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.log
  if ($LASTEXITCODE -ne 0) { throw 'vlog failed; stale simulation was not run; inspect compile.log' }

  $cases = @(
    @{name='startup_ownership'; marker='ALL CHECKS PASSED: startup_ownership'; args=@()},
    @{name='startup_ownership_legacy'; marker='EXPECTED LEGACY HANDOFF FAILURE DETECTED: startup_ownership'; args=@('-gLEGACY_READY=1')}
  )
  foreach ($case in $cases) {
    $script:A4Ran++
    & (Join-Path $ModelSimPath 'vsim.exe') -c -quiet -onfinish stop @($case.args) `
      -do 'onerror {quit -f -code 2}; run -all; quit -f -code 0' work.tb_startup_ownership *> ($case.name+'.log')
    if ($LASTEXITCODE -ne 0) { throw "Simulation process failed: $($case.name)" }
    $log = [IO.File]::ReadAllText((Join-Path $ReportDir ($case.name+'.log')))
    if (-not $log.Contains($case.marker) -or $log -match 'FAIL:|errors=[1-9]') {
      throw "Regression assertion failed: $($case.name)"
    }
    $script:A4Passed++
    Write-Output ($case.name+': passed')
  }

  # ---- A4 分母断言 ----------------------------------------------------
  if ($script:A4Ran -eq 0) {
    throw 'A4-GATE: ran=0（一个 case 都没跑）'
  }
  if ($script:A4Ran -ne $ExpCaseCount) {
    throw ('A4-GATE: ran=' + $script:A4Ran + ' 与期望 case 数 ' + $ExpCaseCount + ' 不符')
  }
  if ($script:A4Passed -ne $script:A4Ran) {
    throw ('A4-GATE: passed=' + $script:A4Passed + ' / ran=' + $script:A4Ran)
  }
  Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' passed=' + $script:A4Passed + ' expected=' + $ExpCaseCount)
}
finally { Pop-Location }
