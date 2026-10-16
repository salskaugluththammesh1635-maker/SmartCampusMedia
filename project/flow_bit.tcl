# flow_bit.tcl — HDMI 工程正式出 bit 流（含 SDC 时序约束）
# 用法: CWD=project/ 下运行  td_commands_prompt.exe <本文件绝对路径>
# 产物: project/hdmi_td_Runs/phy_1/hdmi_td.bit（与 GUI 工程命名一致）
set outdir D:/FPGA_Compelate/SmartCampusMedia/project/hdmi_td_Runs/phy_1
set repdir D:/FPGA_Compelate/SmartCampusMedia/reports
import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project D:/FPGA_Compelate/SmartCampusMedia/project/hdmi_td.al} emsg]} { puts "FAIL-open_project: $emsg"; exit 2 } else { puts "PASS-open_project" }
if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} { puts "FAIL-elaborate: $emsg"; exit 3 } else { puts "PASS-elaborate" }
if {[catch {read_adc D:/FPGA_Compelate/SmartCampusMedia/project/hdmi/dmz_eg4s20_hdmi.adc} emsg]} { puts "FAIL-read_adc: $emsg"; exit 4 } else { puts "PASS-read_adc" }
if {[catch {read_sdc D:/FPGA_Compelate/SmartCampusMedia/project/hdmi/dmz_eg4s20_hdmi.sdc} emsg]} { puts "FAIL-read_sdc: $emsg"; exit 5 } else { puts "PASS-read_sdc" }
foreach step {optimize_rtl optimize_gate place route} {
  if {[catch {eval $step} emsg]} { puts "FAIL-$step: $emsg"; exit 6 } else { puts "PASS-$step" }
}
if {[catch {update_timing -mode final} emsg]} { puts "FAIL-update_timing: $emsg"; exit 7 } else { puts "PASS-update_timing" }
catch { report_timing_summary -file $repdir/hdmi_sta.txt }
catch { report_area -io_info -file $repdir/hdmi_area.txt }
# 出 bit（BitWriter）
if {[catch {bitgen -bit $outdir/hdmi_td.bit} emsg]} { puts "FAIL-bitgen: $emsg"; exit 8 }
puts "PASS-bitgen"
puts "HDMI_BIT_FLOW: done"
exit 0
