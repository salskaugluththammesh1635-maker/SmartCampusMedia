# Independent SD/FAT32/BMP/playback regression, with positive pass markers.
[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\s6_integration\frontend'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$sources = @(
    'rtl/storage/sd_spi_ctrl.v', 'rtl/storage/sd_probe.v',
    'rtl/storage/fat32_reader.v', 'rtl/storage/gallery_probe.v',
    'rtl/storage/bmp_parser.v',
    'rtl/storage/img_loader.v', 'rtl/control/player_ctrl.v',
    'sim/testbench/tb_sd_spi_protocol.v', 'sim/testbench/tb_sd_spi_ctrl.v',
    'sim/testbench/tb_sd_probe.v', 'sim/testbench/tb_fat32_reader.v',
    'sim/testbench/tb_gallery_probe.v',
    'sim/testbench/tb_bmp_parser.v', 'sim/testbench/tb_img_loader.v',
    'sim/testbench/tb_player_ctrl.v'
)
$hashes = @($sources | ForEach-Object {
    @{ path = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }
})
$result = [ordered]@{ startedAt=(Get-Date).ToString('o'); status='running'; sources=$hashes; tests=@() }
$failed = $false
Push-Location $ReportDir
try {
    if (-not (Test-Path work)) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & "$ModelSimPath\vlog.exe" -quiet @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    $cases = @(
        @{name='sd_protocol_default'; top='tb_sd_spi_protocol'; marker='ALL CHECKS PASSED: strict SD SPI protocol'; arguments=@()},
        @{name='sd_protocol_fast'; top='tb_sd_spi_protocol'; marker='ALL CHECKS PASSED: strict SD SPI protocol';
            arguments=@('-gINIT_DIV=2', '-gLOOP_LIMIT=4', '-gTOKEN_LIMIT=256', '-gPOWERUP_DELAY=100')},
        @{name='sd_spi_ctrl'; top='tb_sd_spi_ctrl'; marker='ALL CHECKS PASSED, errors = 0'; arguments=@()},
        @{name='sd_probe'; top='tb_sd_probe'; marker='*** ALL CHECKS PASSED ***'; arguments=@()},
        @{name='fat32_reader'; top='tb_fat32_reader'; marker='ALL CHECKS PASSED: fat32_reader'; arguments=@()},
        @{name='gallery_probe'; top='tb_gallery_probe'; marker='ALL CHECKS PASSED: gallery_probe'; arguments=@()},
        @{name='bmp_parser'; top='tb_bmp_parser'; marker='ALL CHECKS PASSED: bmp_parser'; arguments=@()},
        @{name='img_loader'; top='tb_img_loader'; marker='ALL CHECKS PASSED: img_loader'; arguments=@()},
        @{name='player_ctrl'; top='tb_player_ctrl'; marker='ALL CHECKS PASSED: player_ctrl'; arguments=@()}
    )
    foreach ($case in $cases) {
        $log = $case.name + '.txt'
        $simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $case.arguments + @(
            '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
            ('work.' + $case.top)
        )
        & "$ModelSimPath\vsim.exe" @simArgs *> $log
        $exit = $LASTEXITCODE
        $content = [IO.File]::ReadAllText((Join-Path $ReportDir $log))
        $checks = [regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS:').Count
        $bad = $content -match 'CHECKS FAILED|GLOBAL TIMEOUT|(?:^|\n)\s*(?:#\s*)?(?:FAIL\b|TIMEOUT:)|\*\*\s+(?:Error|Fatal)\b'
        $passed = $exit -eq 0 -and $content.Contains($case.marker) -and $checks -gt 0 -and -not $bad
        $result.tests += @{ name=$case.name; passed=$passed; exitCode=$exit; passLines=$checks; log=$log; arguments=@($simArgs) }
        Write-Output ($case.name + ': passed=' + $passed + '; passLines=' + $checks)
        if (-not $passed) { $failed = $true }
    }
    foreach ($source in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
            throw ('Source changed during validation: ' + $source.path)
        }
    }
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
