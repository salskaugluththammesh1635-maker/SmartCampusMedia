# 2026-10-31 KEY1 切图加固构建（参照 flow_d810_fix_20261031.tcl）
# 目的：framebuf_arbiter 写组首间隔保护（WR_GROUP_CYCLES=13），针对切图时黑带/白线现象
# 编译成可上板的 bit 文件，报告落在 reports/key1_fix_20261031/。
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set repdir [file normalize $prjdir/../reports/key1_fix_20261031]
file mkdir $repdir

import_device eagle_s20.db -package EG4S20BG256
open_project $prjdir/hdmi_td.al
elaborate -top dmz_eg4s20_hdmi_top
read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc
read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc

foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} {
        puts "KEY1_BUILD_FAIL-$step: $emsg"
        exit 2
    }
    puts "KEY1_BUILD_PASS-$step"
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
    puts "KEY1_BUILD_TIMING_REPORT_INVALID"
    exit 2
}
if {$setup_slack < 0 || $hold_slack < 0} {
    puts "KEY1_BUILD_TIMING_FAILED: setup=$setup_slack hold=$hold_slack"
    exit 3
}

set bitfile $repdir/smartcampus_media_key1fix_20261031.bit
if {[catch {bitgen -bit $bitfile} emsg]} {
    puts "KEY1_BUILD_FAIL-bitgen: $emsg"
    exit 4
}
if {![file exists $bitfile] || [file size $bitfile] == 0} {
    puts "KEY1_BUILD_FAIL-bitfile-missing"
    exit 4
}
puts "KEY1_BUILD_TIMING_PASSED: setup=$setup_slack hold=$hold_slack"
puts "KEY1_BUILD_BITFILE: $bitfile"
exit 0
