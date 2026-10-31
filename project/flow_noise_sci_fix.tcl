# Build the source-selection and science-page fix on top of the validated display.
# Changes include the ready-frame underflow guard, a built-in FPGA lesson page,
# a compact Chinese glyph ROM, and the persistent science-mode indicator.
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set repdir [file normalize $prjdir/../reports/noise_sci_fix_20261029]
file mkdir $repdir
import_device eagle_s20.db -package EG4S20BG256
open_project $prjdir/hdmi_td.al
elaborate -top dmz_eg4s20_hdmi_top
read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc
read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc
foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} { puts "NOISE_SCI_FIX_FAIL-$step: $emsg"; exit 2 }
    puts "NOISE_SCI_FIX_PASS-$step"
}
update_timing -mode final
report_timing_summary -file $repdir/timing.txt
report_area -io_info -file $repdir/area.txt
check_timing -file $repdir/coverage.txt
bitgen -bit $repdir/hdmi_noise_sci_fix.bit
set handle [open $repdir/timing.txt r]
set timing_text [read $handle]
close $handle
if {![regexp {SWNS:\s+(-?[0-9.]+)ns,\s+STNS:} $timing_text unused setup_slack] ||
    ![regexp {HWNS:\s+(-?[0-9.]+)ns,\s+HTNS:} $timing_text unused hold_slack]} {
    puts "NOISE_SCI_FIX_TIMING_REPORT_INVALID"
    exit 2
}
if {$setup_slack < 0 || $hold_slack < 0} {
    puts "NOISE_SCI_FIX_TIMING_FAILED: setup=$setup_slack hold=$hold_slack"
    exit 3
}
puts "NOISE_SCI_FIX_TIMING_PASSED: setup=$setup_slack hold=$hold_slack"
exit 0
