# 变异反证：用刻意写错的 pix_mosaic（照抄 addendum :462-469 伪码）喂给同一个 tb，
# 证明 tb_pix_mosaic.v 真的能抓到"输出落后一拍"这个静默缺陷。
#
# 本脚本的"通过"定义与常规仿真相反：
#   tb 报 FAIL 且失败项里包含 I1（src_w=640 逐拍恒等） => 反证成功，exit 0
#   tb 全绿（说明变异体没被抓住）                      => 反证失败，exit 1
#
# 用法: & sim\scripts\run_t1_mutant.ps1
$ErrorActionPreference = 'Stop'

$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem'
$vlib = Join-Path $ModelSimPath 'vlib.exe'
$vlog = Join-Path $ModelSimPath 'vlog.exe'
$vsim = Join-Path $ModelSimPath 'vsim.exe'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$WorkDir  = Join-Path $RepoRoot 'sim\work\mut_t1'
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Set-Location $WorkDir

if (Test-Path (Join-Path $WorkDir 'work')) { Remove-Item -Recurse -Force (Join-Path $WorkDir 'work') }
& $vlib 'work' | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host '[FAIL] vlib 建库失败'; exit 2 }

# 注意编译顺序：变异体必须顶替 rtl/video/pix_mosaic.v，不能被真身覆盖
$Sources = @(
    (Join-Path $WorkDir 'pix_mosaic_mutant.v'),
    (Join-Path $RepoRoot 'rtl\video\ratio_map.v'),
    (Join-Path $RepoRoot 'sim\testbench\tb_pix_mosaic.v')
)

Write-Host '=== vlog 编译（变异体版本）==='
& $vlog -quiet @Sources
if ($LASTEXITCODE -ne 0) { Write-Host '[FAIL] vlog 编译失败'; exit 2 }

Write-Host '=== vsim 运行 tb_pix_mosaic（期望失败）==='
$Transcript = Join-Path $WorkDir 'transcript_mutant.txt'
& $vsim -c -quiet -l $Transcript -onfinish stop `
    -do 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0' `
    'work.tb_pix_mosaic' | Out-Null
$simExit = $LASTEXITCODE

$Text = Get-Content $Transcript -Raw
$hasFailMarker = $Text -match 'CHECKS FAILED: pix_mosaic'
$i1Failed      = $Text -match 'FAIL: I1 '
$failCount     = 0
if ($Text -match 'SUMMARY: checks=(\d+) pass=(\d+) fail=(\d+)') { $failCount = [int]$Matches[3] }

Write-Host ("变异体结果: exit={0} CHECKS_FAILED={1} I1抓到={2} fail={3}" -f $simExit, $hasFailMarker, $i1Failed, $failCount)

if ($hasFailMarker -and $i1Failed -and ($failCount -gt 0)) {
    Write-Host '[PASS] 反证成功：TB 抓到了伪码版本的"落后一拍"缺陷（I1 恒等断言失败）'
    exit 0
}
Write-Host '[FAIL] 反证失效：TB 没有抓到变异体，断言可能形同虚设'
exit 1
