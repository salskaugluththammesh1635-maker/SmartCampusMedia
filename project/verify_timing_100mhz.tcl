# =============================================================================
# verify_timing_100mhz.tcl — 100MHz 降频后的时序验证（headless TD）
# -----------------------------------------------------------------------------
# 背景：SiP SDRAM 接口在 150MHz 下数学上无法收敛（TD 硬核对 SiP 接口的固定
#       5.000ns 惩罚 > 0°/180° 的半周期预算 3.333ns，通路为空 slack 也必负）。
#       决策：sdram_pll 从 1050MHz VCO→150MHz 改为 1000MHz VCO→100MHz，
#       半周期预算变为 5.000ns。
# 本脚本：跑完整 optimize_rtl / optimize_gate / place / route，
#         用真实报告回答「100MHz 下 SiP 接口组是否真正收敛」。
# 用法：& D:/TD_6_24_APP/bin/td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/verify_timing_100mhz.tcl
# 注意：TD 脚本路径一律正斜杠；脚本不能带 UTF-8 BOM。
# =============================================================================

# 【关键】必须 cd 到 project 目录再 open_project。
# hdmi_td.al 里的源文件是相对路径（hdmi/sdram_pll.v、../ip/local/sdram/global_def.v），
# TD 按当前工作目录解析它们。不 cd 时 open_project 会「成功」并报 analyzed 36 files，
# 但那些文件其实是空的，随后 elaborate 立刻报
#   HDL-5007 WARNING: could not find top-level module/unit
#   HDL-8001 ERROR: Incorrect top-level module name "dmz_eg4s20_hdmi_top"
# 另外 open_project 的参数一律写成无引号的正斜杠字符串——用 "引号包裹变量" 时
# TD 会把它解析成目录路径，报 PRJ-8601。（2026-10-27 实测两种写法各失败一次）
set prjroot "D:/FPGA_Compelate/SmartCampusMedia"
set outdir  "D:/FPGA_Compelate/SmartCampusMedia/reports/timing_100mhz_20261027"
file mkdir $outdir

cd $prjroot/project

puts "=== VERIFY 100MHz: pwd = [pwd] / outdir = $outdir ==="

import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project $prjroot/project/hdmi_td.al} emsg]} {
    puts "FAIL-open_project: $emsg"; exit 2
} else { puts "PASS-open_project" }

if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} {
    puts "FAIL-elaborate: $emsg"; exit 3
} else { puts "PASS-elaborate" }

catch { read_adc $prjroot/project/hdmi/dmz_eg4s20_hdmi.adc }
if {[catch {read_sdc $prjroot/project/hdmi/dmz_eg4s20_hdmi.sdc} emsg]} {
    puts "FAIL-read_sdc: $emsg"; exit 4
} else { puts "PASS-read_sdc" }

foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} {
        puts "FAIL-$step: $emsg"; exit 5
    } else { puts "PASS-$step" }
}

if {[catch {update_timing -mode final} emsg]} {
    puts "FAIL-update_timing: $emsg"; exit 6
} else { puts "PASS-update_timing" }

catch { report_timing_summary -file "$outdir/run.timing" }
catch { report_timing_status  -file "$outdir/run.ts" }
catch { report_area -io_info -file "$outdir/run.area" }

puts "VERIFY_TIMING_100MHZ: done"
exit 0
