# 只跑 t1 几何模块（pix_mosaic + ratio_map）的定向仿真，不走整工程
# 用法: pwsh -File sim/scripts/run_t1_geom.ps1
$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'

$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem'
$vlib = Join-Path $ModelSimPath 'vlib.exe'
$vlog = Join-Path $ModelSimPath 'vlog.exe'
$vsim = Join-Path $ModelSimPath 'vsim.exe'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$WorkDir  = Join-Path $RepoRoot 'sim\work\t1_geom'
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Set-Location $WorkDir

# 干净重建库，避免旧编译产物掩盖语法错误
if (Test-Path (Join-Path $WorkDir 'work')) { Remove-Item -Recurse -Force (Join-Path $WorkDir 'work') }
& $vlib 'work' | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host '[FAIL] vlib 建库失败'; exit 2 }

$Sources = @(
    (Join-Path $RepoRoot 'rtl\video\pix_mosaic.v'),
    (Join-Path $RepoRoot 'rtl\video\ratio_map.v'),
    (Join-Path $RepoRoot 'sim\testbench\tb_pix_mosaic.v')
)

Write-Host '=== vlog 编译 ==='
& $vlog -quiet @Sources
if ($LASTEXITCODE -ne 0) { Write-Host '[FAIL] vlog 编译失败'; exit 2 }

Write-Host '=== vsim 运行 tb_pix_mosaic ==='
$Transcript = Join-Path $WorkDir 'transcript_pix_mosaic.txt'
& $vsim -c -quiet -l $Transcript -onfinish stop `
    -do 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0' `
    'work.tb_pix_mosaic'
$simExit = $LASTEXITCODE

$Text = Get-Content $Transcript -Raw -Encoding utf8
Write-Host $Text

# 判过口径与 run_display_content.ps1 一致：exit 0 + 有 ALL CHECKS PASSED + 无失败特征串
$hasPass = $Text -match 'ALL CHECKS PASSED: pix_mosaic'
$hasFail = $Text -match 'CHECKS FAILED|ERROR:|\*\*\s+(?:Error|Fatal)|\bFAIL:'

if (($simExit -eq 0) -and $hasPass -and (-not $hasFail)) {
    Write-Host "[PASS] tb_pix_mosaic 全部断言通过 (exit=$simExit)"
    exit 0
}
Write-Host "[FAIL] tb_pix_mosaic 未通过 (exit=$simExit pass=$hasPass fail=$hasFail)"
exit 1
