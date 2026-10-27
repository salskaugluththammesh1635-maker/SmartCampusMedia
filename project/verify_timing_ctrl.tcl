# =============================================================================
# verify_timing_ctrl.tcl — 分离实验：只做 BUFG 修复，不拆时钟组
# -----------------------------------------------------------------------------
# 见 project/hdmi/sdc_ctrl_samegroup.sdc 的说明。
# 输出目录独立，不覆盖前两轮报告。
# =============================================================================

set prjroot "D:/FPGA_Compelate/SmartCampusMedia"
set outdir  "D:/FPGA_Compelate/SmartCampusMedia/reports/timing_ctrl_samegroup_20261027"
file mkdir $outdir

puts "=== VERIFY CTRL: outdir = $outdir ==="

import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project "$prjroot/project/hdmi_td.al"} emsg]} {
    puts "FAIL-open_project: $emsg"; exit 2
} else { puts "PASS-open_project" }

if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} {
    puts "FAIL-elaborate: $emsg"; exit 3
} else { puts "PASS-elaborate" }

catch { read_adc "$prjroot/project/hdmi/dmz_eg4s20_hdmi.adc" }
if {[catch {read_sdc "$prjroot/project/hdmi/sdc_ctrl_samegroup.sdc"} emsg]} {
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

catch { report_timing_summary -file "$outdir/ctrl.timing" }
catch { report_timing_status  -file "$outdir/ctrl.ts" }
catch { report_area -io_info -file "$outdir/ctrl.area" }

puts "VERIFY_TIMING_CTRL: done"
exit 0
