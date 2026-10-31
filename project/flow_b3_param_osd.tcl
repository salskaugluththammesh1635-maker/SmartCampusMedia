# Build the B3 real-time parameter OSD on top of the validated display.
# Changes include an 8x16 ASCII glyph ROM (rtl/osd/), a 3-line parameter text
# table, a dimmed-glass panel in the top-right corner, and a 2.5 s auto-popup
# trigger that watches the four user-adjustable parameters. No key is consumed:
# all 16 key numbers were already assigned.
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set repdir [file normalize $prjdir/../reports/b3_param_osd_20261029]
file mkdir $repdir
import_device eagle_s20.db -package EG4S20BG256
open_project $prjdir/hdmi_td.al
elaborate -top dmz_eg4s20_hdmi_top
read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc
read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc
foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} { puts "B3_PARAM_OSD_FAIL-$step: $emsg"; exit 2 }
    puts "B3_PARAM_OSD_PASS-$step"
}
update_timing -mode final
report_timing_summary -file $repdir/timing.txt
report_area -io_info -file $repdir/area.txt
check_timing -file $repdir/coverage.txt
bitgen -bit $repdir/hdmi_b3_param_osd.bit
set handle [open $repdir/timing.txt r]
set timing_text [read $handle]
close $handle
if {![regexp {SWNS:\s+(-?[0-9.]+)ns,\s+STNS:} $timing_text unused setup_slack] ||
    ![regexp {HWNS:\s+(-?[0-9.]+)ns,\s+HTNS:} $timing_text unused hold_slack]} {
    puts "B3_PARAM_OSD_TIMING_REPORT_INVALID"
    exit 2
}
if {$setup_slack < 0 || $hold_slack < 0} {
    puts "B3_PARAM_OSD_TIMING_FAILED: setup=$setup_slack hold=$hold_slack"
    exit 3
}
puts "B3_PARAM_OSD_TIMING_PASSED: setup=$setup_slack hold=$hold_slack"
exit 0
