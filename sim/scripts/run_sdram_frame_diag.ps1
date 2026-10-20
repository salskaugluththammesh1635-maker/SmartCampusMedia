[CmdletBinding()]
param(
    [string]$ModelSimPath = 'D:\Quartus_APP\modelsim_ase\win32aloem',
    [string]$ReportDir = 'reports\sdram_white_diag\simulation'
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not [IO.Path]::IsPathRooted($ReportDir)) { $ReportDir = Join-Path $root $ReportDir }
$sources = @('rtl/storage/sdram_frame_diag.v', 'rtl/storage/sdram_ctrl_wrap.v',
             'sim/testbench/tb_sdram_frame_diag.v')
$hashes = @($sources | ForEach-Object {
    @{ path=$_; sha256=(Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }
})
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$result = [ordered]@{ startedAt=(Get-Date).ToString('o'); status='running'; sources=$hashes }
$passed = $false
Push-Location $ReportDir
try {
    if (-not (Test-Path -LiteralPath work)) {
        & "$ModelSimPath\vlib.exe" work *> vlib.txt
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & "$ModelSimPath\vlog.exe" -quiet '+define+SDRAM_SIM_MODEL' @($sources | ForEach-Object { Join-Path $root $_ }) *> compile.txt
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed; no stale simulation was run' }
    & "$ModelSimPath\vsim.exe" -c -quiet -onfinish stop -do 'run -all; quit -f -code 0' work.tb_sdram_frame_diag *> simulation.txt
    $result.exitCode = $LASTEXITCODE
    $log = Get-Content -LiteralPath simulation.txt -Raw
    $summary = [regex]::Match($log, 'SUMMARY: checks=(\d+) errors=(\d+) cases=(\d+)')
    $passed = $result.exitCode -eq 0 -and $log.Contains('ALL CHECKS PASSED: sdram_frame_diag') -and
        $summary.Success -and [int]$summary.Groups[1].Value -gt 0 -and
        [int]$summary.Groups[2].Value -eq 0 -and [int]$summary.Groups[3].Value -eq 4 -and
        $log -notmatch '\*\*\s+(?:Fatal|Error)|(?:^|\n)\s*(?:#\s*)?FAIL\b'
    foreach ($entry in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw ('Source changed during test: ' + $entry.path)
        }
    }
    $result.status = $(if ($passed) { 'passed' } else { 'failed' })
    Get-Content -LiteralPath simulation.txt | Select-String 'PASS:|FAIL:|SUMMARY:|ALL CHECKS|Fatal'
}
catch { $passed=$false; $result.status='failed'; $result.error=$_.Exception.Message; Write-Error -ErrorAction Continue $_ }
finally {
    $result.finishedAt = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
if (-not $passed) { exit 1 }
exit 0
