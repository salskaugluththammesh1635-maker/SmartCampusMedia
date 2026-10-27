# =============================================================================
# verify_timing_40mhz.tcl — 40MHz 降频后的时序验证（headless TD）
# -----------------------------------------------------------------------------
# 降频路线（两次，均由实测驱动）：
#   150MHz → 100MHz：SiP 硬核对接口有固定 5.000ns 惩罚，而 0°/180° 半周期预算
#                     只有 3.333ns，通路为空 slack 也必负 —— 数学上无解。
#   100MHz 实测：读 DQ（clkc[2]→clkc[1]）SWNS −5.565ns、写 DQ（clkc[1]→clkc[2]）
#                 −2.001ns，而内部逻辑域（clkc[1] 自身）+2.604ns、0 违例。
#   由此反推出与频率无关的常数开销：
#                 读 slack = T/2 − 10.565ns  → 临界 f ≤ 47.33 MHz
#                 写 slack = T/2 −  7.001ns  → 临界 f ≤ 71.42 MHz
#   100MHz → 40MHz：半周期预算 12.5ns，预测读 +1.935ns、写 +5.499ns。
# 本脚本：跑完整 optimize_rtl / optimize_gate / place / route，
#         用真实报告回答「40MHz 下 SiP 接口组是否真正收敛」。
# 用法：& D:/TD_6_24_APP/bin/td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/verify_timing_40mhz.tcl
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
set outdir  "D:/FPGA_Compelate/SmartCampusMedia/reports/timing_40mhz_20261027"
file mkdir $outdir

cd $prjroot/project

puts "=== VERIFY 40MHz: pwd = [pwd] / outdir = $outdir ==="

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

puts "VERIFY_TIMING_40MHZ: done"
exit 0
