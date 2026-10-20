set prjdir [file dirname [file normalize [info script]]]
set repdir [file normalize $prjdir/../reports/image_dm_fix]
set outdir $prjdir/image_dm_fix_td_Runs/phy_1
cd $prjdir
file mkdir $repdir
file mkdir $outdir
import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project $prjdir/image_dm_fix_td.al} emsg]} { puts "IMAGE_DM_FIX_FAIL-open: $emsg"; exit 2 }
if {[catch {elaborate -top dmz_eg4s20_dm_fix_top} emsg]} { puts "IMAGE_DM_FIX_FAIL-elaborate: $emsg"; exit 2 }
read_adc $prjdir/../constraints/dmz_eg4s20_hdmi.adc
read_sdc $prjdir/../constraints/dmz_eg4s20_hdmi.sdc
set_param place seed 1
foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} { puts "IMAGE_DM_FIX_FAIL-$step: $emsg"; exit 2 }
}
update_timing -mode final
report_timing_summary -file $repdir/timing.txt
report_area -file $repdir/area.txt
check_timing -file $repdir/coverage.txt
bitgen -bit $outdir/image_dm_fix.bit
puts "IMAGE_DM_FIX_BIT_DONE"
set f [open $repdir/timing.txt r]
set timing [read $f]
close $f
if {![regexp {SWNS:\s+(-?[0-9.]+)ns} $timing unused setup] ||
    ![regexp {HWNS:\s+(-?[0-9.]+)ns} $timing unused hold]} {
    puts "IMAGE_DM_FIX_TIMING_REPORT_INVALID"; exit 2
}
if {$setup < 0 || $hold < 0} {
    puts "IMAGE_DM_FIX_TIMING_FAILED: setup=$setup hold=$hold; diagnostic candidate only"
    exit 3
}
exit 0
