[CmdletBinding()]
param([int[]]$Modes=@(0,1,2,3,4))
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$questaRoot='D:\MentorGraphics\HLVX.2.13\SDD_HOME\hyperlynx64\Ams\pkgs\icx_pro_sim\22.1\questasim\v2022.1'
$env:AMS_MODEL_TECH='D:\MentorGraphics\HLVX.2.13\SDD_HOME\hyperlynx64\Ams\pkgs\icx_pro_sim\22.1\libs'
$bin=Join-Path $questaRoot win64
$report=Join-Path $root 'reports\eram_core_diag\real_core'
New-Item -ItemType Directory -Force -Path $report | Out-Null
$sources=@('ip/local/sdram/global_def.v','ip/local/sdram/sdr_wrrd.enc.v',
    'ip/local/sdram/sdr_init_ref.enc.v','ip/local/sdram/sdr_as_ram.enc.v',
    'ip/local/sdram/IS42s32200.v','rtl/storage/sdram_ctrl_wrap.v','sim/testbench/tb_eram_core_bus.v')
$result=[ordered]@{startedAt=(Get-Date).ToString('o'); status='running'; sources=@(
    $sources | ForEach-Object { @{path=$_; sha256=(Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash} }
); tests=@()}
Push-Location $report
try {
    if(-not (Test-Path work)) {
        & (Join-Path $bin vlib.exe) work *> vlib.txt
        if($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    # Verilog mode avoids unavailable SystemVerilog std packages in this bundled runtime.
    # -permissive accepts the vendor's unsized constant without editing the encrypted IP.
    & (Join-Path $bin vlog.exe) -mfcu -permissive +define+SIMULATION @($sources | ForEach-Object {Join-Path $root $_}) *> compile.txt
    if($LASTEXITCODE -ne 0) { throw 'real core compile failed' }
    foreach($mode in $Modes) {
        $log='mode_'+$mode+'.txt'
        # The legacy -7 SDRAM model specifies a 7ns minimum clock; this is a
        # functional protocol comparison at 150MHz, not physical timing signoff.
        & (Join-Path $bin vsim.exe) -c -quiet +notimingchecks -onfinish stop ('-gMODE='+$mode) -do 'run -all; quit -f -code 0' work.tb_eram_core_bus *> $log
        $simExit=$LASTEXITCODE
        $text=[IO.File]::ReadAllText((Join-Path $report $log))
        $passed=$simExit -eq 0 -and $text.Contains('ALL CHECKS PASSED: eram_core_bus') -and
            $text -notmatch '\*\*\s+(?:Error|Fatal)|MISMATCH|Error loading design|Failed to checkout'
        $result.tests+=@{mode=$mode; passed=$passed; exitCode=$simExit; log=$log}
        Write-Output ('mode='+$mode+' passed='+$passed)
    }
    foreach($entry in $result.sources) {
        if((Get-FileHash (Join-Path $root $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw ('Source changed: '+$entry.path)
        }
    }
    $result.status=if(@($result.tests | Where-Object {-not $_.passed}).Count){'failed'}else{'passed'}
}
catch { $result.status='failed'; $result.error=$_.Exception.Message; throw }
finally {
    $result.finishedAt=(Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content result.json -Encoding utf8
    Pop-Location
}
if($result.status -ne 'passed') { exit 1 }
