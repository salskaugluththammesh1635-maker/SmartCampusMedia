# Replay captured card sectors; require an explicit passing result, not just exit 0.
[CmdletBinding()]
param(
    [string]$CaptureDir = 'reports\sd_card_2110',
    [string]$ReportDir = 'reports\sd_card_2110\replay',
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($CaptureDir)) { $CaptureDir = Join-Path $root $CaptureDir }
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
$capture = Get-Content -LiteralPath (Join-Path $CaptureDir 'capture.json') -Raw | ConvertFrom-Json
$sources = @('rtl/storage/fat32_reader.v', 'rtl/storage/img_loader.v',
             'rtl/storage/bmp_parser.v', 'sim/testbench/tb_sd_card_replay.v')
$sourceHashes = @($sources | ForEach-Object {
    @{ path=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }
})
$captureHashes = @('lba.hex', 'data.hex', 'capture.json' | ForEach-Object {
    @{ path=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $CaptureDir $_) -Algorithm SHA256).Hash }
})
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$passed = $false
$result = [ordered]@{ startedAt=(Get-Date).ToString('o'); status='running'; sources=$sourceHashes; capture=$captureHashes }
Push-Location $ReportDir
try {
    if (-not (Test-Path -LiteralPath 'work')) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & "$ModelSimPath\vlog.exe" -quiet @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    $simArgs = @('-c', '-quiet', '-onfinish', 'stop',
        ('+SECTOR_COUNT=' + $capture.sector_count),
        ('+LBA_FILE=' + (Join-Path $CaptureDir 'lba.hex').Replace('\','/')),
        ('+DATA_FILE=' + (Join-Path $CaptureDir 'data.hex').Replace('\','/')),
        '-do', 'run -all; quit -f -code 0', 'work.tb_sd_card_replay')
    & "$ModelSimPath\vsim.exe" @simArgs *> replay.txt
    $result.exitCode = $LASTEXITCODE
    $log = [IO.File]::ReadAllText((Join-Path $ReportDir 'replay.txt'))
    $passed = $result.exitCode -eq 0 -and $log.Contains('ALL CHECKS PASSED: SD card replay') -and
        $log -notmatch '\*\*\s+(?:Fatal|Error)|(?:^|\n)\s*(?:#\s*)?FAIL\b'
    foreach ($entry in $sourceHashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw ('Source changed during replay: ' + $entry.path)
        }
    }
    $result.status = $(if ($passed) { 'passed' } else { 'failed' })
    Get-Content -LiteralPath 'replay.txt' | Select-String 'READ LBA|REPLAY_RESULT|BOARD_DISPLAY|PASS:|ALL CHECKS|Fatal|FAIL:'
}
catch { $passed=$false; $result.status='failed'; $result.error=$_.Exception.Message; Write-Error -ErrorAction Continue $_ }
finally {
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath 'result.json' -Encoding utf8
    Pop-Location
}
if (-not $passed) { exit 1 }
exit 0
