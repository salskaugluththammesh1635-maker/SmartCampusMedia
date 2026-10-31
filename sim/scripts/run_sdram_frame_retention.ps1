# Real-controller full-frame write, 64ms retention and repeated readback gate.
[CmdletBinding()]
param(
    [string]$ReportDir='reports/display_diag_20261028/final/retention',
    [string]$QuestaPath='D:/MentorGraphics/HLVX.2.13/SDD_HOME/hyperlynx64/Ams/pkgs/icx_pro_sim/22.1/questasim/v2022.1',
    [string]$AmsModelTech='D:/MentorGraphics/HLVX.2.13/SDD_HOME/hyperlynx64/Ams/pkgs/icx_pro_sim/22.1/libs'
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(-not [IO.Path]::IsPathRooted($ReportDir)){$ReportDir=Join-Path $root $ReportDir}
$ReportDir=[IO.Path]::GetFullPath($ReportDir)
$bin=Join-Path $QuestaPath 'win64'
foreach($toolName in @('vlib.exe','vlog.exe','vsim.exe')){
    if(-not(Test-Path -LiteralPath (Join-Path $bin $toolName))){throw ('Questa tool not found: '+(Join-Path $bin $toolName))}
}
$env:AMS_MODEL_TECH=$AmsModelTech
$sourceNames=@(
    'ip/config/sdram/global_def.v',
    'ip/local/sdram/sdr_wrrd.enc.v',
    'ip/local/sdram/sdr_init_ref.enc.v',
    'ip/local/sdram/sdr_as_ram.enc.v',
    'ip/local/sdram/IS42s32200.v',
    'rtl/common/async_fifo.v',
    'rtl/storage/framebuf_arbiter.v',
    'rtl/storage/sdram_ctrl_wrap.v',
    'sim/testbench/tb_sdram_frame_retention.v'
)
$sourcePaths=@($sourceNames | ForEach-Object {Join-Path $root $_})
$hashes=@($sourcePaths | ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}})
$result=[ordered]@{
    startedAt=(Get-Date).ToString('o');status='running';sources=$hashes
    clockSdrMHz=40;clockProducerMHz=25;spiEquivalentMHz=12.5
    geometry='640x480';holdMs=64;frames=2;expectedWords=307200
    vendorTimingDefaults=$true;timingChecksEnabled=$true;physicalTimingValidated=$false
}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
Push-Location $ReportDir
try {
    if(-not(Test-Path -LiteralPath work)){
        & (Join-Path $bin 'vlib.exe') work *> vlib.txt
        if($LASTEXITCODE -ne 0){throw 'vlib failed'}
    }
    # One compilation unit gives every controller the repository-owned config.
    & (Join-Path $bin 'vlog.exe') -mfcu -permissive +define+SIMULATION @sourcePaths *> compile.txt
    if($LASTEXITCODE -ne 0){throw 'Compile failed; no stale simulation was run'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $bin 'vsim.exe') -c -quiet -vopt -onfinish stop -do 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0' work.tb_sdram_frame_retention *> simulation.txt
    $result.exitCode=$LASTEXITCODE
    $clock.Stop();$result.seconds=$clock.Elapsed.TotalSeconds
    $content=[IO.File]::ReadAllText((Join-Path $ReportDir 'simulation.txt'))
    $summary=[regex]::Match($content,'RETENTION_RESULT frames=(\d+) words=(\d+) errors=(\d+) refresh_error=(\d+)')
    $passed=$result.exitCode -eq 0 -and $content.Contains('ALL CHECKS PASSED: sdram_frame_retention') -and
        $summary.Success -and [int]$summary.Groups[1].Value -eq 2 -and
        [int]$summary.Groups[2].Value -eq 307200 -and [int]$summary.Groups[3].Value -eq 0 -and
        [int]$summary.Groups[4].Value -eq 0 -and
        $content -notmatch 'MISMATCH|ERROR:|violation|CHECKS FAILED|\*\*\s+(?:Error|Fatal)|Error loading design|Failed to checkout'
    foreach($source in $hashes){
        if((Get-FileHash -LiteralPath $source.path -Algorithm SHA256).Hash -ne $source.sha256){
            throw ('Source changed during verification: '+$source.path)
        }
    }
    $result.summary=$summary.Value
    $result.status=if($passed){'passed'}else{'failed'}
    Select-String -LiteralPath simulation.txt -Pattern 'CONFIG|WRITE_COMPLETE|HOLD_RESULT|FRAME_RESULT|REFRESH_|RETENTION_RESULT|PASSED|MISMATCH|ERROR:|violation|\*\*\s+(?:Error|Fatal)' | ForEach-Object {$_.Line}
    Write-Output ('elapsedSeconds='+$result.seconds)
} catch {
    $result.status='failed';$result.failure=$_.Exception.Message
    Write-Error -ErrorAction Continue $_
} finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath result.json -Encoding utf8
    Pop-Location
}
if($result.status -ne 'passed'){exit 1}
