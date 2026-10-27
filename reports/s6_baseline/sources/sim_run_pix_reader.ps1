# =============================================================================
#  run_pix_reader.ps1 —— 一键编译 + 运行 tb_pix_reader
#  用法:  pwsh -File run_pix_reader.ps1
#  产出:  sim/msim_work/sim_out.txt （utf8），并把 vlog / vsim 退出码打到屏幕
#  纪律:  先看 VLOG_EXIT，非 0 就停，不要读旧二进制的输出
# =============================================================================
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot          # ...\SmartCampusMedia
$work = Join-Path $PSScriptRoot 'msim_work'
if (!(Test-Path $work)) { New-Item -ItemType Directory -Path $work | Out-Null }

Push-Location $work
try {
    $vlogArgs = @(
        '-quiet',
        '+define+SDRAM_SIM_MODEL',
        '../../rtl/common/async_fifo.v',
        '../../rtl/storage/framebuf_arbiter.v',
        '../../rtl/storage/sdram_ctrl_wrap.v',
        '../../rtl/storage/pix_reader.v',
        '../testbench/tb_pix_reader.v'
    )
    & vlog @vlogArgs 2>&1 | Out-File -Encoding utf8 vlog_out.txt
    $vlogExit = $LASTEXITCODE
    Write-Output "VLOG_EXIT=$vlogExit"
    if ($vlogExit -ne 0) {
        Write-Output "----- vlog_out.txt -----"
        Get-Content vlog_out.txt | Select-Object -Last 40
        Write-Output "*** COMPILE FAILED - NOT RUNNING vsim ***"
        exit $vlogExit
    }

    & vsim -c -quiet -lib work -do "run -all; quit -f" tb_pix_reader 2>&1 |
        Out-File -Encoding utf8 sim_out.txt
    $vsimExit = $LASTEXITCODE
    Write-Output "VSIM_EXIT=$vsimExit"
    Write-Output "----- sim_out.txt -----"
    Get-Content sim_out.txt
}
finally {
    Pop-Location
}
