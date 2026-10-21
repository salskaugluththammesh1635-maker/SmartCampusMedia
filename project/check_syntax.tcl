# =============================================================================
# check_syntax.tcl — TD 语法检测 / 流程运行辅助脚本
# -----------------------------------------------------------------------------
# 用法（在 TD 的 Tcl Console 里执行其一）:
#   source <仓库>/project/check_syntax.tcl          ;# 语法检测
#   source <仓库>/project/run_full_flow.tcl         ;# 跑完整流程
#   本脚本用自身所在目录（project/）定位 bringup_td.al，不写死本机绝对路径；
#   run_full_flow.tcl 不对工程定位，沿用 TD 中已打开的工程。
#
# 说明: 本脚本调用 TD 官方流程命令（命令名取自 TD 安装目录下
#       doc/scripts/DefaultFlow.tcl，与实际流程节点一一对应）:
#         Read Design        -> elaborate -top <top>
#         Optimize RTL       -> optimize_rtl
#         Optimize Gate      -> optimize_gate
#         Optimize Placement -> place
#         Optimize Routing   -> route
#         Generate Bitstream -> bitgen -bit <name>.bit
#
# 注意: 通过 GUI 流程节点运行（选中节点按 Shift+R）会同步更新 FPGA Flow 的
#       状态标记与报告文件; 本脚本用于快速检查, 不替代 GUI 的完整流程记录。
# =============================================================================

set top_name "dmz_eg4s20_min_top"
set prjdir [file dirname [file normalize [info script]]]

puts "======================================================"
puts " TD 语法检测 (Read Design / elaborate)"
puts " 顶层模块: $top_name"
puts "======================================================"

# 若尚未打开工程, 尝试自动打开（工程已打开时该命令会跳过）
if { [catch { current_project } cur_prj] } {
    puts "# 提示: 未检测到已打开工程, 尝试打开 bringup_td.al ..."
    if { [catch { open_project "$prjdir/bringup_td.al" } err] } {
        puts "# \[WARN\] 自动打开工程失败: $err"
        puts "#        请在 TD 中先打开工程, 再重新 source 本脚本。"
        return
    }
} else {
    puts "# 当前工程: $cur_prj"
}

set t0 [clock milliseconds]
if { [catch { elaborate -top $top_name } err] } {
    set t1 [clock milliseconds]
    puts ""
    puts "**************** \[FAIL\] 语法检测未通过 ****************"
    puts "耗时: [expr {$t1 - $t0}] ms"
    puts "错误信息:"
    puts $err
    puts "********************************************************"
} else {
    set t1 [clock milliseconds]
    puts ""
    puts "**************** \[PASS\] 语法检测通过 ****************"
    puts "耗时: [expr {$t1 - $t0}] ms"
    puts "提示: 接下来可运行 optimize_rtl 做综合, 或回 GUI 用 Shift+R 跑完整流程。"
    puts "********************************************************"
}
