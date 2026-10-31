# Release candidate build for the current SmartCampusMedia workspace.
# Keeps prior bitstreams and reports intact under a fresh dated directory.
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set repdir [file normalize $prjdir/../reports/watchdog_20261030]
file mkdir $repdir

import_device eagle_s20.db -package EG4S20BG256
open_project $prjdir/hdmi_td.al
elaborate -top dmz_eg4s20_hdmi_top
read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc
read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc

foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} {
        puts "FLASHABLE_BUILD_FAIL-$step: $emsg"
        exit 2
    }
    puts "FLASHABLE_BUILD_PASS-$step"
}

update_timing -mode final
report_timing_summary -file $repdir/timing.txt
report_area -io_info -file $repdir/area.txt
check_timing -file $repdir/coverage.txt

set handle [open $repdir/timing.txt r]
set timing_text [read $handle]
close $handle
if {![regexp {SWNS:\s+(-?[0-9.]+)ns,\s+STNS:} $timing_text unused setup_slack] ||
    ![regexp {HWNS:\s+(-?[0-9.]+)ns,\s+HTNS:} $timing_text unused hold_slack]} {
    puts "FLASHABLE_BUILD_TIMING_REPORT_INVALID"
    exit 2
}
if {$setup_slack < 0 || $hold_slack < 0} {
    puts "FLASHABLE_BUILD_TIMING_FAILED: setup=$setup_slack hold=$hold_slack"
    exit 3
}

set bitfile $repdir/smartcampus_media_watchdog_20261030.bit
if {[catch {bitgen -bit $bitfile} emsg]} {
    puts "FLASHABLE_BUILD_FAIL-bitgen: $emsg"
    exit 4
}
if {![file exists $bitfile] || [file size $bitfile] == 0} {
    puts "FLASHABLE_BUILD_FAIL-bitfile-missing"
    exit 4
}
puts "FLASHABLE_BUILD_TIMING_PASSED: setup=$setup_slack hold=$hold_slack"
puts "FLASHABLE_BUILD_BITFILE: $bitfile"
exit 0
