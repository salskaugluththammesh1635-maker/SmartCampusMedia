# Full HDMI + SD image pipeline build.
# Paths derive from this script's own location, so it does not depend on the CWD.
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set repdir [file normalize $prjdir/../reports/s6_integration]
set outdir $prjdir/hdmi_td_Runs/phy_1
file mkdir $repdir
file mkdir $outdir
import_device eagle_s20.db -package EG4S20BG256
open_project $prjdir/hdmi_td.al
elaborate -top dmz_eg4s20_hdmi_top
read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc
read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc
foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} { puts "S6_FAIL-$step: $emsg"; exit 2 }
    puts "S6_PASS-$step"
}
update_timing -mode final
report_timing_summary -file $repdir/timing.txt
report_area -io_info -file $repdir/area.txt
check_timing -file $repdir/coverage.txt
# A generated bit is an engineering candidate; acceptance also requires timing.txt.
bitgen -bit $outdir/hdmi_td.bit
puts "S6_BIT_FLOW_DONE"
set report_handle [open $repdir/timing.txt r]
set timing_text [read $report_handle]
close $report_handle
if {![regexp {SWNS:\s+(-?[0-9.]+)ns,\s+STNS:} $timing_text unused setup_slack] ||
    ![regexp {HWNS:\s+(-?[0-9.]+)ns,\s+HTNS:} $timing_text unused hold_slack]} {
    puts "S6_TIMING_REPORT_INVALID"
    exit 2
}
if {$setup_slack < 0 || $hold_slack < 0} {
    puts "S6_TIMING_FAILED: setup=$setup_slack ns hold=$hold_slack ns; bit is a candidate only"
    exit 3
}
puts "S6_TIMING_PASSED"
exit 0
