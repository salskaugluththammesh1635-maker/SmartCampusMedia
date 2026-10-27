# =============================================================================
# flow_t2_elaborate.tcl — 阶段四 S6 / t2 验证脚本（只到 elaborate）
# -----------------------------------------------------------------------------
# 【目的】证明 hdmi_td.al 里 31 个源文件条目全部能被 TD 识别：
#   无 PRJ-7001 Can't find this file
#   无 HDL-1007 undeclared symbol
#   无 HDL-1004 unknown module（黑盒）
#   且 .adc / .sdc 两份约束能被 read_adc / read_sdc 正常解析
# 【不做什么】不跑 optimize/place/route/bitgen —— 那是 t5 的事；
#   顶层 t3 尚未例化 SDRAM/存储链，此时跑 P&R 无意义。
# 【用法】td_commands_prompt.exe <本文件绝对路径>
#   脚本先切到自身所在目录（project/）作为工作基准，再定位工程与约束。
# =============================================================================
set prjdir [file dirname [file normalize [info script]]]
cd $prjdir
set logdir [file normalize $prjdir/../reports]
set top_name dmz_eg4s20_hdmi_top

puts "==== T2-ELABORATE: begin ===="

# ---- 0. 器件库 ----
if {[catch {import_device eagle_s20.db -package EG4S20BG256} emsg]} {
    puts "FAIL-import_device: $emsg"; exit 2
}
puts "PASS-import_device"

# ---- 1. 打开工程（= 读取 hdmi_td.al 的 31 个 File 条目）----
if {[catch {open_project $prjdir/hdmi_td.al} emsg]} {
    puts "FAIL-open_project: $emsg"; exit 3
}
puts "PASS-open_project"

# ---- 2. elaborate（编译全部源文件 + 展开层次）----
if {[catch {elaborate -top $top_name} emsg]} {
    puts "FAIL-elaborate: $emsg"; exit 4
}
puts "PASS-elaborate"

# ---- 3. 管脚约束解析（41 个 IO，无 SDRAM 管脚）----
if {[catch {read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc} emsg]} {
    puts "FAIL-read_adc: $emsg"; exit 5
}
puts "PASS-read_adc"

# ---- 4. 时序约束解析（create_clock + derive_clocks + set_clock_groups）----
if {[catch {read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc} emsg]} {
    puts "FAIL-read_sdc: $emsg"; exit 6
}
puts "PASS-read_sdc"

# ---- 5. 落报告，便于人工核对层次与时钟 ----
if {[catch {report_area -io_info -file $logdir/t2_elaborate_area.txt} emsg]} {
    puts "WARN-report_area: $emsg"
} else {
    puts "PASS-report_area"
}

puts "==== T2-ELABORATE: done ===="
exit 0
