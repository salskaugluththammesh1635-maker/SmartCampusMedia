# =============================================================================
# verify_timing_fix.tcl — 验证 2026-10-27 时序修复（BUFG + 时钟组拆分）
# -----------------------------------------------------------------------------
# 为什么单独写一个脚本而不复用 flow_sdc.tcl：
#   flow_sdc.tcl 用 [file normalize [info script]] 推导工程目录。从
#   td_commands_prompt.exe 以命令行参数方式调用时 info script 返回空串，
#   $prjdir 变成 "", cd 失败，open_project 收到空路径直接报
#   PRJ-8601 Load project file ... error。
#   本脚本所有路径写死为绝对路径（正斜杠，TD 只认正斜杠），不依赖 info script。
#
# 验证目标（对应 constraints/dmz_eg4s20_hdmi.sdc 文件头【2026-10-27 修复】）：
#   1. set_clock_groups 生效 → clkc[1]→clkc[2] 与 clkc[2]→clkc[1] 两个
#      path group 从报告中消失（不再被当作同域 setup 分析）
#   2. clkc[1]→clkc[1] 自身域仍在分析（这是真实的 150MHz 收敛指标），
#      且 SWNS 相比修复前的 +0.240ns 应有改善（C1 已上 GCLK）
#   3. 全局 SWNS / STNS 应转正
#   4. PHY-5079（时钟走 local routing）告警应消失
# =============================================================================

set prjroot "D:/FPGA_Compelate/SmartCampusMedia"
set outdir  "D:/FPGA_Compelate/SmartCampusMedia/reports/timing_fix_20261027"
file mkdir $outdir

puts "=== VERIFY: working dir = [pwd] ==="
puts "=== VERIFY: prjroot    = $prjroot ==="
puts "=== VERIFY: outdir     = $outdir ==="

import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project "$prjroot/project/hdmi_td.al"} emsg]} {
    puts "FAIL-open_project: $emsg"; exit 2
} else { puts "PASS-open_project" }

if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} {
    puts "FAIL-elaborate: $emsg"; exit 3
} else { puts "PASS-elaborate" }

if {[catch {read_adc "$prjroot/project/hdmi/dmz_eg4s20_hdmi.adc"} emsg]} {
    puts "FAIL-read_adc: $emsg"
} else { puts "PASS-read_adc" }

if {[catch {read_sdc "$prjroot/project/hdmi/dmz_eg4s20_hdmi.sdc"} emsg]} {
    puts "FAIL-read_sdc: $emsg"; exit 4
} else { puts "PASS-read_sdc" }

foreach step {optimize_rtl optimize_gate place route} {
    if {[catch {eval $step} emsg]} {
        puts "FAIL-$step: $emsg"; exit 5
    } else { puts "PASS-$step" }
}

if {[catch {update_timing -mode final} emsg]} {
    puts "FAIL-update_timing: $emsg"; exit 6
} else { puts "PASS-update_timing" }

catch { report_timing_summary -file "$outdir/fix.timing" }
catch { report_timing_status  -file "$outdir/fix.ts" }
catch { report_area -io_info -file "$outdir/fix.area" }

puts "VERIFY_TIMING_FIX: done"
exit 0
