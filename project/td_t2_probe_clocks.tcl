# =============================================================================
# td_t2_probe_clocks.tcl — t2 诊断：确认 derive_clocks 真的把 150MHz 派生出来
# -----------------------------------------------------------------------------
# 【为什么需要】read_sdc 静默通过 ≠ 时钟真的进了 STA。必须看到 Clock Summary
#   里有 150.000 / 12.500 / 25.000 / 125.000 才算数（否则就是假绿）。
# 本脚本用 catch 包住每个探测命令，某一命令不存在也不会中断整个流程。
# =============================================================================
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set repdir [file normalize $prjdir/../reports]

puts "==== T2-PROBE: begin ===="
set rc [catch {import_device eagle_s20.db -package EG4S20BG256} emsg]
if {$rc} { puts "FAIL-import_device: $emsg"; exit 2 }
set rc [catch {open_project $prjdir/hdmi_td.al} emsg]
if {$rc} { puts "FAIL-open_project: $emsg"; exit 3 }
set rc [catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]
if {$rc} { puts "FAIL-elaborate: $emsg"; exit 4 }
puts "PASS-elaborate"
set rc [catch {read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc} emsg]
if {$rc} { puts "FAIL-read_adc: $emsg"; exit 5 }
set rc [catch {read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc} emsg]
if {$rc} { puts "FAIL-read_sdc: $emsg"; exit 6 }
puts "PASS-read_sdc"

# ---- 探测：read_sdc 之后有没有可用的时钟报告命令 ----
foreach c {
    {report_clocks -file REP/clocks_after_sdc.txt}
    {check_timing -file REP/check_timing_after_sdc.txt}
} {
    set cmd [string map [list REP $repdir] $c]
    if {[catch {eval $cmd} e]} {
        puts "PROBE-FAIL: $cmd  ->  $e"
    } else {
        puts "PROBE-PASS: $cmd"
    }
}

# ---- 跑 optimize_rtl 让时序引擎真正建立时钟网络，再看一次 ----
set rc [catch {optimize_rtl} emsg]
if {$rc} { puts "FAIL-optimize_rtl: $emsg"; exit 7 }
puts "PASS-optimize_rtl"

foreach c {
    {report_clocks -file REP/clocks_after_opt.txt}
    {check_timing -file REP/check_timing_after_opt.txt}
    {update_timing -mode final}
    {report_timing_summary -file REP/t2_timing_summary.txt}
} {
    set cmd [string map [list REP $repdir] $c]
    if {[catch {eval $cmd} e]} {
        puts "PROBE-FAIL: $cmd  ->  $e"
    } else {
        puts "PROBE-PASS: $cmd"
    }
}

puts "==== T2-PROBE: done ===="
exit 0
