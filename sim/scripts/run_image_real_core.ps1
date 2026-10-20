param([switch]$Small,[switch]$IdleDmFix)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$bin='D:\MentorGraphics\HLVX.2.13\SDD_HOME\hyperlynx64\Ams\pkgs\icx_pro_sim\22.1\questasim\v2022.1\win64'
$env:AMS_MODEL_TECH='D:\MentorGraphics\HLVX.2.13\SDD_HOME\hyperlynx64\Ams\pkgs\icx_pro_sim\22.1\libs'
$report=Join-Path $root 'reports\image_real_core_sim'
if($Small){$report=Join-Path $report 'small'}
if($IdleDmFix){$report=Join-Path $report 'idle_dm_fix'}
New-Item -ItemType Directory -Force -Path $report | Out-Null
$sources=@('ip/local/sdram/global_def.v','ip/local/sdram/sdr_wrrd.enc.v',
    'ip/local/sdram/sdr_init_ref.enc.v','ip/local/sdram/sdr_as_ram.enc.v',
    'ip/local/sdram/IS42s32200.v','rtl/common/async_fifo.v','rtl/video/video_timing_gen.v',
    'rtl/storage/framebuf_arbiter.v','rtl/storage/sdram_ctrl_wrap.v','rtl/storage/pix_reader.v',
    'rtl/storage/fat32_reader.v','rtl/storage/bmp_parser.v','rtl/storage/img_loader.v',
    'rtl/storage/image_path_probe.v','rtl/storage/image_readback_diag.v',
    'project/image_readback_diag/image_player_readback_diag.v','reports/image_real_core_sim/tb_image_real_core.v')
if(-not $IdleDmFix){$sources=$sources | ForEach-Object {if($_ -eq 'rtl/storage/framebuf_arbiter.v'){'reports/dm_mask_fix/baseline/framebuf_arbiter.v'}else{$_}}}
$result=[ordered]@{startedAt=(Get-Date).ToString('o');status='running';physicalTimingValidated=$false;sources=@(
    $sources | ForEach-Object { @{path=$_;sha256=(Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash} }
)}
Push-Location $report
try {
    if(-not(Test-Path work)){ & "$bin\vlib.exe" work *> vlib.txt; if($LASTEXITCODE){ throw 'vlib failed' } }
    & "$bin\vlog.exe" -mfcu -permissive +define+SIMULATION @($sources | ForEach-Object {Join-Path $root $_}) *> compile.txt
    if($LASTEXITCODE){ throw 'vlog failed' }
    $full=if($Small){0}else{1}
    & "$bin\vsim.exe" -c -quiet +notimingchecks -onfinish stop ('-gFULL='+$full) -do 'run -all; quit -f -code 0' work.tb_image_real_core *> simulation.txt
    $result.exitCode=$LASTEXITCODE
    $content=Get-Content -Raw simulation.txt
    $summary=[regex]::Match($content,'SUMMARY: checks=(\d+) errors=(\d+)')
    $result.passed=$result.exitCode -eq 0 -and $content.Contains('ALL CHECKS PASSED: image_real_core') -and
        $summary.Success -and [int]$summary.Groups[2].Value -eq 0 -and
        $content -notmatch '\*\*\s+(?:Fatal|Error)|(?:^|\n)#\s*FAIL\b'
    foreach($entry in $result.sources){
        if((Get-FileHash (Join-Path $root $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256){ throw ('Source changed: '+$entry.path) }
    }
    $result.status=if($result.passed){'passed'}else{'failed'}
    if($summary.Success){$result.checks=[int]$summary.Groups[1].Value;$result.errors=[int]$summary.Groups[2].Value}
    Write-Output ($result | ConvertTo-Json -Depth 2)
}
catch { $result.status='failed';$result.error=$_.Exception.Message;throw }
finally { $result.finishedAt=(Get-Date).ToString('o');$result | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 result.json;Pop-Location }
if($result.status -ne 'passed'){exit 1}
