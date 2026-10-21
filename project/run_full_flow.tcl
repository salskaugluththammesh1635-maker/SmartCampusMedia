# =============================================================================
# run_full_flow.tcl — 一键跑完整流程（综合 → 布局 → 布线 → 比特流）
# -----------------------------------------------------------------------------
# 用法（在 TD 的 Tcl Console 里执行）:
#   source <仓库>/project/run_full_flow.tcl
#   脚本本身不打开工程、不切换目录，请先在 TD 中打开对应 .al 工程。
#   不写死本机绝对路径；输出文件（.bit / .area / .timing）落在 TD 的当前工作目录。
#
# 对应 GUI 动作: 工具栏 Run（等价于 FPGA Flow 里 Syn Opt + Phy Opt + BitWriter）
# 命令名取自 TD 官方流程脚本 doc/scripts/DefaultFlow.tcl（已核对），各步含义:
#   elaborate -top <top>   读入设计（语法检查）
#   optimize_rtl           RTL 级优化（综合）
#   optimize_gate          门级优化
#   place                  布局
#   route                  布线
#   bitgen -bit <f>.bit    生成比特流
#
# ⚠️ 说明: 本脚本走"命令直调"路径, 与 GUI 流程节点的报告文件
#    （*_rtl.area / *_gate.timing / *_pr.timing / flow.status 等）不完全等同;
#    正式验证请用 GUI: 选中节点按 Shift+R 或点工具栏 Run。
#    本脚本适合: 批量回归、快速判断能否收敛、无 GUI 环境下跑流程。
# =============================================================================

set top_name   "dmz_eg4s20_min_top"
set prj_name   "bringup_td"
set bit_file   "${prj_name}.bit"

proc step { name } {
    puts ""
    puts "======================================================"
    puts " >>> $name"
    puts "======================================================"
}

set flow_ok 1
set t_all0 [clock milliseconds]

# ---- 1. 读入设计 ----
step "1/6 Read Design (elaborate)"
set t0 [clock milliseconds]
if { [catch { elaborate -top $top_name } err] } {
    puts "\[FAIL\] elaborate: $err"
    set flow_ok 0
} else {
    puts "\[PASS\] elaborate 完成 ([expr {[clock milliseconds] - $t0}] ms)"
}

# ---- 2. RTL 优化 ----
if { $flow_ok } {
    step "2/6 Optimize RTL"
    set t0 [clock milliseconds]
    if { [catch { optimize_rtl } err] } {
        puts "\[FAIL\] optimize_rtl: $err"
        set flow_ok 0
    } else {
        puts "\[PASS\] optimize_rtl 完成 ([expr {[clock milliseconds] - $t0}] ms)"
        catch { report_area -file ${prj_name}_rtl.area }
    }
}

# ---- 3. 门级优化 ----
if { $flow_ok } {
    step "3/6 Optimize Gate"
    set t0 [clock milliseconds]
    if { [catch { optimize_gate } err] } {
        puts "\[FAIL\] optimize_gate: $err"
        set flow_ok 0
    } else {
        puts "\[PASS\] optimize_gate 完成 ([expr {[clock milliseconds] - $t0}] ms)"
        catch { report_timing_summary -file ${prj_name}_gate.timing }
        catch { report_timing_status  -file ${prj_name}_gate.ts }
    }
}

# ---- 4. 布局 ----
if { $flow_ok } {
    step "4/6 Optimize Placement"
    set t0 [clock milliseconds]
    if { [catch { place } err] } {
        puts "\[FAIL\] place: $err"
        set flow_ok 0
    } else {
        puts "\[PASS\] place 完成 ([expr {[clock milliseconds] - $t0}] ms)"
        catch { report_area -io_info -file ${prj_name}_phy.area }
        catch { report_timing_summary -file ${prj_name}_place.timing }
    }
}

# ---- 5. 布线 ----
if { $flow_ok } {
    step "5/6 Optimize Routing"
    set t0 [clock milliseconds]
    if { [catch { route } err] } {
        puts "\[FAIL\] route: $err"
        set flow_ok 0
    } else {
        puts "\[PASS\] route 完成 ([expr {[clock milliseconds] - $t0}] ms)"
        catch { report_timing_summary -file ${prj_name}_pr.timing }
        catch { report_timing_status  -file ${prj_name}_phy.ts }
    }
}

# ---- 6. 生成比特流 ----
if { $flow_ok } {
    step "6/6 Generate Bitstream"
    set t0 [clock milliseconds]
    if { [catch { bitgen -bit $bit_file } err] } {
        puts "\[FAIL\] bitgen: $err"
        set flow_ok 0
    } else {
        puts "\[PASS\] bitgen 完成 ([expr {[clock milliseconds] - $t0}] ms)"
        puts "      比特流: $bit_file"
    }
}

# ---- 汇总 ----
puts ""
puts "======================================================"
if { $flow_ok } {
    puts " *** 全流程通过 ***  总耗时 [expr {[clock milliseconds] - $t_all0}] ms"
    puts " 比特流: $bit_file"
    puts " 时序报告: ${prj_name}_pr.timing / ${prj_name}_phy.ts"
    puts " 资源报告: ${prj_name}_phy.area"
    puts ""
    puts " 下一步: GUI 工具栏 Shift+D 打开 BitWriter 下载到板卡"
} else {
    puts " *** 流程中断 ***  请根据上面 \[FAIL\] 信息排查"
}
puts "======================================================"
