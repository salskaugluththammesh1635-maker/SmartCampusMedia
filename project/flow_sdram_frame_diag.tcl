set prjdir [file dirname [file normalize [info script]]]
set repdir [file normalize $prjdir/../reports/sdram_white_diag]
set outdir $prjdir/sdram_frame_diag_td_Runs/phy_1
file mkdir $repdir
file mkdir $outdir
import_device eagle_s20.db -package EG4S20BG256
open_project $prjdir/sdram_frame_diag_td.al
elaborate -top sdram_frame_diag_top
read_adc $prjdir/../constraints/sdram_frame_diag.adc
read_sdc $prjdir/../constraints/sdram_frame_diag.sdc
foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} { puts "FRAME_DIAG_FAIL-$step: $emsg"; exit 2 }
}
update_timing -mode final
report_timing_summary -file $repdir/timing.txt
report_area -file $repdir/area.txt
check_timing -file $repdir/coverage.txt
bitgen -bit $outdir/sdram_frame_diag.bit
puts "FRAME_DIAG_BIT_DONE"
set f [open $repdir/timing.txt r]
set timing [read $f]
close $f
if {![regexp {SWNS:\s+(-?[0-9.]+)ns} $timing unused setup] ||
    ![regexp {HWNS:\s+(-?[0-9.]+)ns} $timing unused hold]} {
    puts "FRAME_DIAG_TIMING_REPORT_INVALID"; exit 2
}
if {$setup < 0 || $hold < 0} {
    puts "FRAME_DIAG_TIMING_FAILED: setup=$setup hold=$hold; diagnostic candidate only"
    exit 3
}
puts "FRAME_DIAG_TIMING_PASSED"
exit 0
