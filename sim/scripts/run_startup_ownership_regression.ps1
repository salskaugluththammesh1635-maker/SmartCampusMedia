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
    & (Join-Path $ModelSimPath 'vsim.exe') -c -quiet -onfinish stop @($case.args) `
      -do 'onerror {quit -f -code 2}; run -all; quit -f -code 0' work.tb_startup_ownership *> ($case.name+'.log')
    if ($LASTEXITCODE -ne 0) { throw "Simulation process failed: $($case.name)" }
    $log = [IO.File]::ReadAllText((Join-Path $ReportDir ($case.name+'.log')))
    if (-not $log.Contains($case.marker) -or $log -match 'FAIL:|errors=[1-9]') {
      throw "Regression assertion failed: $($case.name)"
    }
    Write-Output ($case.name+': passed')
  }
}
finally { Pop-Location }
