# =============================================================================
# flow_sdc.tcl —— HDMI 工程 SDC 流程验证脚本
# -----------------------------------------------------------------------------
# 【用途】从工程定义重新读入 ADC / SDC，跑完整 RTL→Gate→Place→Route 流程，
#   确认时序约束真的进入了 STA，并输出布线后时序与面积报告。
# 【用法】& <TD安装路径>/bin/td_commands_prompt.exe <仓库>/project/flow_sdc.tcl
# 【输出】$outdir 下的 timing / status / area 报告；默认写到脚本同目录的
#   sdc_flow_out/，可通过环境变量 SCM_SDC_OUTDIR 覆盖。
# 【说明】脚本先切到自身所在目录（project/）作为工作基准，工程与约束文件均按
#   该目录推导，不写死本机绝对路径，可在任意检出位置复现。注意 import_device
#   的器件库由 TD 环境解析，脚本仍需在 TD 的 td_commands_prompt 中运行。
# =============================================================================

set prjdir [file dirname [file normalize [info script]]]
cd $prjdir

if {[info exists ::env(SCM_SDC_OUTDIR)] && $::env(SCM_SDC_OUTDIR) ne ""} {
    set outdir $::env(SCM_SDC_OUTDIR)
} else {
    set outdir [file join $prjdir "sdc_flow_out"]
}
file mkdir $outdir

import_device eagle_s20.db -package EG4S20BG256
if {[catch {open_project [file join $prjdir "hdmi_td.al"]} emsg]} { puts "FAIL-open_project: $emsg"; exit 2 } else { puts "PASS-open_project" }
if {[catch {elaborate -top dmz_eg4s20_hdmi_top} emsg]} { puts "FAIL-elaborate: $emsg"; exit 3 } else { puts "PASS-elaborate" }
if {[catch {read_adc [file join $prjdir "hdmi/dmz_eg4s20_hdmi.adc"]} emsg]} { puts "FAIL-read_adc: $emsg" } else { puts "PASS-read_adc" }
if {[catch {read_sdc [file join $prjdir "hdmi/dmz_eg4s20_hdmi.sdc"]} emsg]} { puts "FAIL-read_sdc: $emsg"; exit 4 } else { puts "PASS-read_sdc" }
foreach step {optimize_rtl optimize_gate place route} {
  if {[catch {eval $step} emsg]} { puts "FAIL-$step: $emsg"; exit 5 } else { puts "PASS-$step" }
}
if {[catch {update_timing -mode final} emsg]} { puts "FAIL-update_timing: $emsg"; exit 6 } else { puts "PASS-update_timing" }
catch { report_timing_summary -file [file join $outdir "hdmi_pr.timing"] }
catch { report_timing_status -file [file join $outdir "hdmi_phy.ts"] }
catch { report_area -io_info -file [file join $outdir "hdmi_phy.area"] }
puts "HDMI_SDC_FLOW: done"
exit 0
