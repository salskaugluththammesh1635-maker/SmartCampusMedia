set outdir C:/Users/Koobee/AppData/Local/Temp/td_hdmi_sdc
import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project D:/FPGA_Compelate/SmartCampusMedia/project/hdmi_td.al} emsg]} { puts "FAIL-open_project: $emsg"; exit 2 } else { puts "PASS-open_project" }
if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} { puts "FAIL-elaborate: $emsg"; exit 3 } else { puts "PASS-elaborate" }
if {[catch {read_adc D:/FPGA_Compelate/SmartCampusMedia/project/hdmi/dmz_eg4s20_hdmi.adc} emsg]} { puts "FAIL-read_adc: $emsg" } else { puts "PASS-read_adc" }
if {[catch {read_sdc D:/FPGA_Compelate/SmartCampusMedia/project/hdmi/dmz_eg4s20_hdmi.sdc} emsg]} { puts "FAIL-read_sdc: $emsg"; exit 4 } else { puts "PASS-read_sdc" }
foreach step {optimize_rtl optimize_gate place route} {
  if {[catch {eval $step} emsg]} { puts "FAIL-$step: $emsg"; exit 5 } else { puts "PASS-$step" }
}
if {[catch {update_timing -mode final} emsg]} { puts "FAIL-update_timing: $emsg"; exit 6 } else { puts "PASS-update_timing" }
catch { report_timing_summary -file $outdir/hdmi_pr.timing }
catch { report_timing_status -file $outdir/hdmi_phy.ts }
catch { report_area -io_info -file $outdir/hdmi_phy.area }
puts "HDMI_SDC_FLOW: done"
exit 0
