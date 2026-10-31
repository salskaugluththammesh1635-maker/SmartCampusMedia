# Build the C2 adaptive image scaler on top of the validated display.
# Changes: bmp_parser gains a CHECK_SIZE switch so non-640x480 headers pass,
# img_scaler (Bresenham nearest-neighbour shrink, aspect preserved, centred)
# sits between bmp_parser and img_loader, image_player packs the scaled
# coordinates into the framebuffer address and completes on out_w*out_h words,
# and image_window_mask forces the letterbox area black before the content mux.
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set repdir [file normalize $prjdir/../reports/c2_scaler_20261030]
file mkdir $repdir
import_device eagle_s20.db -package EG4S20BG256
open_project $prjdir/hdmi_td.al
elaborate -top dmz_eg4s20_hdmi_top
read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc
read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc
foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} { puts "C2_SCALER_FAIL-$step: $emsg"; exit 2 }
    puts "C2_SCALER_PASS-$step"
}
update_timing -mode final
report_timing_summary -file $repdir/timing.txt
report_area -io_info -file $repdir/area.txt
check_timing -file $repdir/coverage.txt
bitgen -bit $repdir/hdmi_c2_scaler.bit
set handle [open $repdir/timing.txt r]
set timing_text [read $handle]
close $handle
if {![regexp {SWNS:\s+(-?[0-9.]+)ns,\s+STNS:} $timing_text unused setup_slack] ||
    ![regexp {HWNS:\s+(-?[0-9.]+)ns,\s+HTNS:} $timing_text unused hold_slack]} {
    puts "C2_SCALER_TIMING_REPORT_INVALID"
    exit 2
}
if {$setup_slack < 0 || $hold_slack < 0} {
    puts "C2_SCALER_TIMING_FAILED: setup=$setup_slack hold=$hold_slack"
    exit 3
}
puts "C2_SCALER_TIMING_PASSED: setup=$setup_slack hold=$hold_slack"
exit 0
