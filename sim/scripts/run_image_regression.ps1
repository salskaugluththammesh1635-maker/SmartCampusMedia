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
    'rtl/storage/framebuf_arbiter.v', 'rtl/storage/sdram_ctrl_wrap.v',
    'rtl/storage/pix_reader.v', 'rtl/storage/fat32_reader.v',
    'rtl/storage/bmp_parser.v', 'rtl/storage/img_loader.v', 'rtl/storage/image_player.v',
    'sim/testbench/tb_image_player.v'
)
$hashes = @($sources | ForEach-Object {
    $file = Join-Path $root $_
    @{ path = $_; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
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
    $cases = @(@{name='image_player'; arguments=@()})
    if ($FullVga) { $cases += @{name='image_player_full'; arguments=@('-gFULL=1')} }
    foreach ($case in $cases) {
        $log = $case.name + '.txt'
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $case.arguments + @(
            '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
            'work.tb_image_player'
        )
        & "$ModelSimPath\vsim.exe" @simArgs *> $log
        $exit = $LASTEXITCODE
        $content = [IO.File]::ReadAllText((Join-Path $ReportDir $log))
        $summary = [regex]::Match($content, 'SUMMARY:.*?checks=(\d+)\s+errors=(\d+)')
        $passed = $exit -eq 0 -and $content.Contains('ALL CHECKS PASSED: '+$case.name) -and
            $summary.Success -and [int]$summary.Groups[1].Value -gt 0 -and
            [int]$summary.Groups[2].Value -eq 0 -and
            $content -notmatch 'CHECKS FAILED|(?:^|\n)#\s*FAIL\b|\*\*\s+(?:Error|Fatal)\b'
        $result.tests += @{ name=$case.name; passed=$passed; exitCode=$exit;
            checks=$(if($summary.Success){[int]$summary.Groups[1].Value}else{0}); log=$log }
        Write-Output ($case.name + ': passed=' + $passed)
        if (-not $passed) { throw ('Simulation failed: '+$log) }
    }
    foreach ($file in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $file.path) -Algorithm SHA256).Hash -ne $file.sha256) {
            throw ('Source changed during validation: '+$file.path)
        }
    }
    $result.status = 'passed'
}
catch { $result.status='failed'; $result.error=$_.Exception.Message; throw }
finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
