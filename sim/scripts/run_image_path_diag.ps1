[CmdletBinding()]
param(
    [switch]$FullVga,
    [switch]$Readback,
    [switch]$DmFix,
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\image_path_diag\simulation'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ($DmFix) { $Readback=$true }
if ($Readback -and -not $PSBoundParameters.ContainsKey('ReportDir')) { $ReportDir='reports\image_readback_diag\simulation' }
if ($DmFix -and -not $PSBoundParameters.ContainsKey('ReportDir')) { $ReportDir='reports\image_dm_fix\simulation' }
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$sources = @(
    'rtl/common/async_fifo.v', 'rtl/video/video_timing_gen.v',
    'rtl/storage/framebuf_arbiter.v', 'rtl/storage/sdram_ctrl_wrap.v',
    'rtl/storage/pix_reader.v', 'rtl/storage/fat32_reader.v',
    'rtl/storage/bmp_parser.v', 'rtl/storage/img_loader.v', 'rtl/storage/image_path_probe.v',
    'project/image_path_diag/image_player_path_diag.v', 'project/image_path_diag/tb_image_path_diag.v'
)
$top='tb_image_path_diag'
$marker='ALL CHECKS PASSED: image_path_diag'
if ($Readback) {
    $sources=$sources | Where-Object { $_ -notlike 'project/image_path_diag/*' }
    $sources+=@('rtl/storage/image_readback_diag.v',
        'project/image_readback_diag/image_player_readback_diag.v',
        'project/image_readback_diag/tb_image_readback_diag.v')
    $top='tb_image_readback_diag'
    $marker='ALL CHECKS PASSED: image_readback_diag'
}
if ($DmFix) {
    $sources=$sources | Where-Object { $_ -notlike 'project/image_readback_diag/*' }
    $sources+=@('project/image_dm_fix/image_player_dm_fix.v','project/image_dm_fix/tb_image_dm_fix.v')
    $top='tb_image_dm_fix';$marker='ALL CHECKS PASSED: image_dm_fix'
}
$hashes = @($sources | ForEach-Object {
    @{ path=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }
})
$result = [ordered]@{ startedAt=(Get-Date).ToString('o'); status='running'; sources=$hashes; tests=@() }
Push-Location $ReportDir
try {
    if (-not (Test-Path work)) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & "$ModelSimPath\vlog.exe" -quiet +define+SDRAM_SIM_MODEL @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    $cases = @(@{name='path_boundaries'; arguments=@()})
    if ($FullVga) { $cases += @{name='path_full_vga'; arguments=@('-gFULL=1')} }
    foreach ($case in $cases) {
        $log=$case.name+'.txt'
        $simArgs=@('-c','-quiet','-onfinish','stop') + $case.arguments + @(
            '-do','onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
            ('work.'+$top))
        & "$ModelSimPath\vsim.exe" @simArgs *> $log
        $simExit=$LASTEXITCODE
        $content=[IO.File]::ReadAllText((Join-Path $ReportDir $log))
        $summary=[regex]::Match($content,'SUMMARY:.*?checks=(\d+)\s+errors=(\d+)')
        $passed=$simExit -eq 0 -and $content.Contains($marker) -and
            $summary.Success -and [int]$summary.Groups[1].Value -gt 0 -and
            [int]$summary.Groups[2].Value -eq 0 -and
            $content -notmatch 'CHECKS FAILED|(?:^|\n)#\s*FAIL\b|\*\*\s+(?:Error|Fatal)\b'
        $result.tests += @{name=$case.name; passed=$passed; exitCode=$simExit;
            checks=$(if($summary.Success){[int]$summary.Groups[1].Value}else{0}); log=$log}
        Write-Output ($case.name+': passed='+$passed)
        if (-not $passed) { throw ('Simulation failed: '+$log) }
    }
    foreach ($entry in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw ('Source changed during validation: '+$entry.path)
        }
    }
    $result.status='passed'
}
catch { $result.status='failed'; $result.error=$_.Exception.Message; throw }
finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
