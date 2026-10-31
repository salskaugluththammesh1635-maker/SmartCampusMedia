[CmdletBinding()]
param(
    [string]$ConfigPath='ip/config/sdram/global_def.v',
    [string]$ReportDir='reports/display_diag_20261028/refresh_config'
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if(-not [IO.Path]::IsPathRooted($ConfigPath)){$ConfigPath=Join-Path $root $ConfigPath}
if(-not [IO.Path]::IsPathRooted($ReportDir)){$ReportDir=Join-Path $root $ReportDir}
$bin='D:/MentorGraphics/HLVX.2.13/SDD_HOME/hyperlynx64/Ams/pkgs/icx_pro_sim/22.1/questasim/v2022.1/win64'
$env:AMS_MODEL_TECH='D:/MentorGraphics/HLVX.2.13/SDD_HOME/hyperlynx64/Ams/pkgs/icx_pro_sim/22.1/libs'
$sources=@($ConfigPath)+@('ip/local/sdram/sdr_wrrd.enc.v','ip/local/sdram/sdr_init_ref.enc.v',
    'ip/local/sdram/sdr_as_ram.enc.v','rtl/storage/framebuf_arbiter.v','rtl/storage/sdram_ctrl_wrap.v','sim/testbench/tb_sdram_refresh_config.v' |
    ForEach-Object {Join-Path $root $_})
$hashes=@($sources | ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}})
$result=[ordered]@{startedAt=(Get-Date).ToString('o');status='running';sources=$hashes;
    physicalTimingValidated=$false;refreshCommandCadenceValidated=$false;checks=0;errors=0;cases=0}
New-Item -ItemType Directory -Force $ReportDir | Out-Null
Push-Location $ReportDir
try {
    if(-not(Test-Path work)){& "$bin/vlib.exe" work *> vlib.txt;if($LASTEXITCODE){throw 'vlib failed'}}
    & "$bin/vlog.exe" -mfcu -permissive +define+SIMULATION @sources *> compile.txt
    if($LASTEXITCODE){throw 'compile failed'}
    & "$bin/vsim.exe" -c -quiet -vopt -onfinish stop -do 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0' work.tb_sdram_refresh_config *> simulation.txt
    $result.exitCode=$LASTEXITCODE
    $content=[IO.File]::ReadAllText((Join-Path $ReportDir 'simulation.txt'))
    $summary=[regex]::Match($content,'SUMMARY:\s*checks=(\d+)\s+errors=(\d+)\s+cases=(\d+)')
    if($summary.Success){
        $result.checks=[int]$summary.Groups[1].Value;$result.errors=[int]$summary.Groups[2].Value
        $result.cases=[int]$summary.Groups[3].Value
    }
    $passed=$result.exitCode -eq 0 -and $content.Contains('ALL CHECKS PASSED: sdram_refresh_config') -and
        $content -notmatch '\*\*\s+(?:Error|Fatal)|FAIL\b' -and $summary.Success -and
        $result.errors -eq 0 -and $result.cases -eq 5
    foreach($source in $hashes){if((Get-FileHash -LiteralPath $source.path -Algorithm SHA256).Hash -ne $source.sha256){throw ('Source changed: '+$source.path)}}
    $result.status=if($passed){'passed'}else{'failed'}
    $result.refreshCommandCadenceValidated=$passed
    Select-String -LiteralPath simulation.txt -Pattern 'CASE |MACRO_CONFIG|REFRESH_WINDOW|REFRESH_DRAIN|REFRESH_WATCHDOG|REFRESH_RESET|SUMMARY|PASSED|Error|Fatal|FAIL' | ForEach-Object {$_.Line}
} catch {$result.status='failed';$result.error=$_.Exception.Message;Write-Error -ErrorAction Continue $_}
finally {$result.finishedAt=(Get-Date).ToString('o');$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath result.json -Encoding utf8;Pop-Location}
if($result.status -ne 'passed'){exit 1}
