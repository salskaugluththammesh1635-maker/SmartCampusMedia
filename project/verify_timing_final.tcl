# =============================================================================
# verify_timing_final.tcl — 最终验收：BUFG 修复 + 仓库认可的 SDC 口径（0°/180° 同组）
# -----------------------------------------------------------------------------
# 与 verify_timing_ctrl.tcl 流程完全一致，只是把输出落到正式目录并绑定
# 当前的 project/hdmi/dmz_eg4s20_hdmi.sdc（已回退为 0°/180° 同组写法）。
# 目的：给出可以写进 README 的权威数字。
# =============================================================================

set prjroot "D:/FPGA_Compelate/SmartCampusMedia"
set outdir  "D:/FPGA_Compelate/SmartCampusMedia/reports/timing_final_20261027"
file mkdir $outdir

puts "=== VERIFY FINAL: outdir = $outdir ==="

import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project "$prjroot/project/hdmi_td.al"} emsg]} {
    puts "FAIL-open_project: $emsg"; exit 2
} else { puts "PASS-open_project" }

if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} {
    puts "FAIL-elaborate: $emsg"; exit 3
} else { puts "PASS-elaborate" }

catch { read_adc "$prjroot/project/hdmi/dmz_eg4s20_hdmi.adc" }
if {[catch {read_sdc "$prjroot/project/hdmi/dmz_eg4s20_hdmi.sdc"} emsg]} {
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

catch { report_timing_summary -file "$outdir/final.timing" }
catch { report_timing_status  -file "$outdir/final.ts" }
catch { report_area -io_info -file "$outdir/final.area" }

puts "VERIFY_TIMING_FINAL: done"
exit 0
