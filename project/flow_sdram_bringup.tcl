# =============================================================================
# flow_sdram_bringup.tcl — SDRAM 150MHz 链路 bring-up 验证（headless TD）
# -----------------------------------------------------------------------------
# 【目的】用真实的综合/布局布线/时序报告回答三个问题：
#   1. sdram_pll 的 1050MHz VCO → 150MHz 能否被 TD 接受并锁定
#   2. 150MHz 时钟域的逻辑能否满足建立/保持时间
#   3. 加密核 sdr_as_ram 能否正常进工程并连上 EG_PHY_SDRAM_2M_32 SIP 原语
#
# 【用法】CWD 必须是工程目录 project/
#   td_commands_prompt.exe <本文件绝对路径>
#
# 【产物】
#   project/sdram_bringup_td_Runs/phy_1/sdram_bringup_td.bit
#   reports/sdram_sta.txt   （时序摘要）
#   reports/sdram_area.txt  （资源报告）
#
# 【为什么单独建工程而不塞进 hdmi_td】
#   验证工程要能"定位问题"，而不只是"给出结论"。若把 PLL+SDRAM 与键盘、
#   数码管、HDMI 一起综合，时序报告的关键路径会混入无关逻辑，
#   "150MHz 收敛不了到底是 PLL 配置错还是别的逻辑拖累"就说不清。
#   单独综合时，本工程只有 PLL + SDRAM 核 + 几十行序列机，
#   任何时序问题都能直接归因。
# =============================================================================
set prjdir D:/FPGA_Compelate/SmartCampusMedia/project
set outdir D:/FPGA_Compelate/SmartCampusMedia/project/sdram_bringup_td_Runs/phy_1
set repdir D:/FPGA_Compelate/SmartCampusMedia/reports

import_device eagle_s20.db -package EG4S20BG256

if {[catch {open_project $prjdir/sdram_bringup_td.al} emsg]} {
    puts "FAIL-open_project: $emsg"; exit 2
} else { puts "PASS-open_project" }

if {[catch {elaborate -top sdram_bringup_top} emsg]} {
    puts "FAIL-elaborate: $emsg"; exit 3
} else { puts "PASS-elaborate" }

if {[catch {read_adc $prjdir/hdmi/sdram_bringup_td.adc} emsg]} {
    puts "FAIL-read_adc: $emsg"; exit 4
} else { puts "PASS-read_adc" }

if {[catch {read_sdc $prjdir/hdmi/sdram_bringup_rw.sdc} emsg]} {
    puts "FAIL-read_sdc: $emsg"; exit 5
} else { puts "PASS-read_sdc" }

foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} {
        puts "FAIL-$step: $emsg"; exit 6
    } else { puts "PASS-$step" }
}

if {[catch {update_timing -mode final} emsg]} {
    puts "FAIL-update_timing: $emsg"; exit 7
} else { puts "PASS-update_timing" }

catch { report_timing_summary -file $repdir/sdram_sta.txt }
catch { report_area -io_info -file $repdir/sdram_area.txt }

if {[catch {bitgen -bit $outdir/sdram_bringup_td.bit} emsg]} {
    puts "FAIL-bitgen: $emsg"; exit 8
} else { puts "PASS-bitgen" }

puts "SDRAM_BRINGUP_FLOW: done"
exit 0
