# =============================================================================
# verify_timing_fix2.tcl — 第二轮：在已收敛基础上加物理优化，拉大余量
# -----------------------------------------------------------------------------
# 第一轮（verify_timing_fix.tcl）结果：SWNS -7.232ns → +0.275ns，STNS → 0
# 但 +0.275ns 只占 6.666ns 周期的 4%，且关键路径 82% 是走线延迟
# （两条 fo=8 的网分别 1.628ns / 2.301ns），属于布局分散问题。
# 本轮在 place 之后、route 之前插入 phys_opt -post_place，
# 并在 route 之后再跑一次 phys_opt -post_route，然后重新收时序。
#
# 结果输出到独立目录，不覆盖第一轮报告，便于对比。
# =============================================================================

set prjroot "D:/FPGA_Compelate/SmartCampusMedia"
set outdir  "D:/FPGA_Compelate/SmartCampusMedia/reports/timing_fix2_20261027"
file mkdir $outdir

puts "=== VERIFY2: outdir = $outdir ==="

import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project "$prjroot/project/hdmi_td.al"} emsg]} {
    puts "FAIL-open_project: $emsg"; exit 2
} else { puts "PASS-open_project" }

if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} {
    puts "FAIL-elaborate: $emsg"; exit 3
} else { puts "PASS-elaborate" }

catch { read_adc "$prjroot/project/hdmi/dmz_eg4s20_hdmi.adc" }
if {[catch {read_sdc "$prjroot/project/hdmi/dmz_eg4s20_hdmi.sdc"} emsg]} {
    puts "FAIL-read_sdc: $emsg"; exit 4
} else { puts "PASS-read_sdc" }

foreach step {optimize_rtl optimize_gate place} {
    if {[catch {eval $step} emsg]} {
        puts "FAIL-$step: $emsg"; exit 5
    } else { puts "PASS-$step" }
}

# ---- 关键新增：place 后的物理优化，专门针对走线占主导的路径 ----
#     注意：phys_opt -post_route -effort high 在 TD v6.2.168116 上会直接崩溃
#     （exit code 0xC0000005 访问违规，实测 2026-10-27），因此只做 post_place。
if {[catch {phys_opt -post_place -effort high} emsg]} {
    puts "WARN-phys_opt_post_place: $emsg"
} else { puts "PASS-phys_opt_post_place" }

if {[catch {route} emsg]} {
    puts "FAIL-route: $emsg"; exit 5
} else { puts "PASS-route" }

if {[catch {update_timing -mode final} emsg]} {
    puts "FAIL-update_timing: $emsg"; exit 6
} else { puts "PASS-update_timing" }

catch { report_timing_summary -file "$outdir/fix2.timing" }
catch { report_timing_status  -file "$outdir/fix2.ts" }
catch { report_area -io_info -file "$outdir/fix2.area" }

puts "VERIFY_TIMING_FIX2: done"
exit 0
