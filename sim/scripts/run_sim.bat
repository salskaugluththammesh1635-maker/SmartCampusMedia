@echo off
REM ============================================================================
REM run_sim.bat - 一键运行最小系统仿真（ModelSim）
REM 用法: 双击或在命令行执行  sim\scripts\run_sim.bat
REM 前置: 本机已装 ModelSim（默认路径 D:\Quartus_APP\modelsim_ase\win32aloem）
REM       若路径不同, 修改下面的 MS 变量
REM 输出: sim\msim_work\ 下生成 sim_out_colorbar.ppm / sim_out_grid.ppm
REM       以及 transcript 仿真日志（可转 PNG 目检图像）
REM ============================================================================
setlocal
set MS=D:\Quartus_APP\modelsim_ase\win32aloem
set ROOT=%~dp0..\..
set WORK=%ROOT%\sim\msim_work

if not exist "%MS%\vsim.exe" (
    echo [ERROR] 未找到 ModelSim: %MS%\vsim.exe
    echo         请修改本脚本中的 MS 变量为本机 ModelSim 安装路径
    exit /b 1
)

if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"

echo [1/3] 创建 work 库 ...
"%MS%\vlib.exe" work

echo [2/3] 编译 RTL 与 testbench ...
"%MS%\vlog.exe" -quiet ^
  "%ROOT%\rtl\common\seg_decoder.v" ^
  "%ROOT%\rtl\display\seg_scan4.v" ^
  "%ROOT%\rtl\input\key_matrix_4x4.v" ^
  "%ROOT%\rtl\control\player_ctrl.v" ^
  "%ROOT%\rtl\audio\buzzer_tone.v" ^
  "%ROOT%\rtl\video\video_timing_gen.v" ^
  "%ROOT%\rtl\video\test_pattern_gen.v" ^
  "%ROOT%\rtl\top\dmz_eg4s20_bringup_top.v" ^
  "%ROOT%\sim\testbench\tb_dmz_eg4s20_bringup.v"
if errorlevel 1 (
    echo [ERROR] 编译失败
    exit /b 1
)

echo [3/3] 运行仿真（含 2 帧 PPM 图像导出, 约需 2-5 分钟）...
"%MS%\vsim.exe" -c -do "run -all; quit -f" work.tb_dmz_eg4s20_bringup

echo.
echo === 完成 ===
echo 日志: %WORK%\transcript
echo 图像: %WORK%\sim_out_colorbar.ppm / sim_out_grid.ppm
echo 转 PNG: python -c "from PIL import Image; Image.open('sim_out_colorbar.ppm').save('sim_out_colorbar.png')"
endlocal
