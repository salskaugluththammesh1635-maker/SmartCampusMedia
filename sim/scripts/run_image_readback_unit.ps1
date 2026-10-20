param([string]$ReportDir='reports\image_dm_fix\unit')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$bin='D:\Quartus_APP\modelsim_ase\win32aloem'
if(-not[IO.Path]::IsPathRooted($ReportDir)){$ReportDir=Join-Path $root $ReportDir}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$sources=@('rtl/storage/image_readback_diag.v','rtl/storage/sdram_ctrl_wrap.v','sim/testbench/tb_image_readback_diag.v')
$result=[ordered]@{status='running';sources=@($sources | ForEach-Object {
    @{path=$_;sha256=(Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash}
})}
Push-Location $ReportDir
try {
    if(-not(Test-Path work)){& "$bin\vlib.exe" work *> vlib.txt;if($LASTEXITCODE){throw 'vlib failed'}}
    & "$bin\vlog.exe" -quiet +define+SDRAM_SIM_MODEL @($sources | ForEach-Object {Join-Path $root $_}) *> compile.txt
    if($LASTEXITCODE){throw 'vlog failed'}
    & "$bin\vsim.exe" -c -quiet -onfinish stop -do 'run -all; quit -f -code 0' work.tb_image_readback_diag *> simulation.txt
    $result.exitCode=$LASTEXITCODE
    $content=Get-Content -Raw simulation.txt
    $summary=[regex]::Match($content,'SUMMARY: checks=(\d+) errors=(\d+)')
    $pass=$result.exitCode -eq 0 -and $summary.Success -and $summary.Groups[2].Value -eq '0' -and
        $content.Contains('ALL CHECKS PASSED: image_readback_unit') -and $content -notmatch '\*\*\s+(?:Error|Fatal)|# FAIL:'
    foreach($entry in $result.sources){
        if((Get-FileHash (Join-Path $root $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256){throw ('Changed source: '+$entry.path)}
    }
    $result.status=if($pass){'passed'}else{'failed'}
    $result.checks=if($summary.Success){[int]$summary.Groups[1].Value}else{0}
    $result.errors=if($summary.Success){[int]$summary.Groups[2].Value}else{-1}
    $result.log='simulation.txt'
    Write-Output ('Readback unit: '+$result.status+' checks='+$result.checks+' errors='+$result.errors)
}
catch {$result.status='failed';$result.error=$_.Exception.Message;throw}
finally {$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 result.json;Pop-Location}
if($result.status -ne 'passed'){exit 1}
