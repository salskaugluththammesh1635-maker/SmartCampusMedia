@echo off
REM ============================================================================
REM run_sim.bat - one-click ModelSim regression for the minimal system
REM Usage : double-click it, or run  sim\scripts\run_sim.bat  from a terminal
REM Require: ModelSim installed (default D:\Quartus_APP\modelsim_ase\win32aloem)
REM          change the MS variable below if yours differs
REM Output: sim\msim_work\sim_out_colorbar.ppm / sim_out_grid.ppm
REM         sim\msim_work\transcript  (full simulation log)
REM
REM [IMPORTANT] KEEP THIS FILE ASCII-ONLY - DO NOT ADD CHINESE TEXT.
REM   Why: cmd.exe parses a batch file with the console code page, which is 936
REM   (GBK) on this machine. Chinese saved as UTF-8 without BOM is then decoded
REM   as GBK, where the LAST Chinese byte of a line swallows the trailing CR -
REM   all lines get glued together and the script fails with errors like
REM   'lSim(...' is not recognized as an internal or external command.
REM   (This really happened on 2026-10-16. See docs/progress.md, issue log.)
REM   Chinese documentation belongs in docs/ and in sim\scripts\sim_bringup.do.
REM ============================================================================
setlocal
set MS=D:\Quartus_APP\modelsim_ase\win32aloem
set ROOT=%~dp0..\..
set WORK=%ROOT%\sim\msim_work

if not exist "%MS%\vsim.exe" (
    echo [ERROR] ModelSim not found at %MS%\vsim.exe
    echo         Please edit the MS variable in this script.
    exit /b 1
)

if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"

echo [1/3] Creating work library ...
"%MS%\vlib.exe" work

echo [2/3] Compiling RTL and testbench ...
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
    echo [ERROR] Compilation failed.
    exit /b 2
)

echo [3/3] Running simulation (dumps 2 PPM frames, takes 2-5 minutes) ...
"%MS%\vsim.exe" -c -do "run -all; quit -f" work.tb_dmz_eg4s20_bringup
if errorlevel 1 (
    echo [ERROR] Simulation failed.
    exit /b 3
)

echo.
echo === DONE ===
echo Log   : %WORK%\transcript
echo Frames: %WORK%\sim_out_colorbar.ppm / sim_out_grid.ppm
echo To PNG: python -c "from PIL import Image; Image.open('sim_out_colorbar.ppm').save('sim_out_colorbar.png')"
endlocal