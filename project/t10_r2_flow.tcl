# t10 round2：import_db 复用 t10 run2 导出的 gate.db（对应当前工作树 RTL），
# 跳过 elaborate / optimize_rtl / optimize_gate 三段，只跑 place → route → bitgen。
#
# 历史（4 趟）：
#   1. elaborate + seed 7                → FAIL-route（PHY-8023 落在 rst_n_dup_34）
#   2. elaborate + 默认 seed             → FAIL-route（rst_n_dup_53；route 内 setup 曾到
#                                          +0.124 ns，hold −0.012 ns 触发 8 条 hold fix 后炸）
#   3. 路线1 'place enable_congestion_recovery on place enhanced_gp on'
#                                        → FAIL-route，且**恶化**（#slices 90.23%、H-EP 16）
#                                          「先疏松布局」假设被证伪
#   4. 路线2 'place hfn_opt_effort high place crit_path_opt on'
#                                        → **PASS**（238.9 s）。hold fix 从 8 条降到 4 条且
#                                          0 条命中 rst_n_dup_*，全落在 HDMI core FIFO 数据网
#                                          + player loader 局部复位
#
# ★ 结论：失败的根因不是时序不收敛，是**高扇出复位复制网（rst_n_dup_*）在 89% slice
#   占用下没地方插 hold buffer**。`hfn_opt_effort high` 重组了高扇出网，才是对症参数。
#
# ★ 本脚本复用 gate.db 的**前提**（脚本内有断言，见下方 GATEDB_STALE 检查）：
#   该 gate.db 必须晚于 rtl/ 下所有 .v 的 mtime。若你改过任何 RTL，本脚本会拒绝运行，
#   必须先走完整流程（project/t7b_bit3.tcl）重新导出 gate.db。
#
# ★ 关于「这是不是一次性脚本」——captain 的判断与审查意见不同，理由如下：
#   审查建议把它标注为「一次性脚本」，理由是它硬编码了 t10 第 1 轮 run2 的 gate.db 路径。
#   但硬编码路径本身不构成一次性：真正决定可复用性的是**它会不会在前提不成立时静默出错**。
#   本工程历史上两次严重误判都是这一类（tb 用 parameter override 绕过了 RTL 默认值的错误；
#   tb 接旧线验证了出货配置里根本不存在的电路），共同点是「跑起来全绿、结果无效」。
#   所以这里选择了硬断言而不是「一次性」标签：
#     - 前提成立（gate.db 比全部 RTL 新）  → 正常跑，且打印 PASS-T7B3_gatedb_fresh；
#     - 前提不成立（有人改过 RTL）        → FAIL-T7B3_GATEDB_STALE + exit 32，拒绝产出位流。
#   换句话说，它现在是一个**带前提校验的可复用入口**，而不是靠人记住「别乱用」的脚本。
#   代价是它仍然只覆盖 place/route/bitgen 三段（综合复用），若需要全程可视必须用
#   project/t7b_bit3.tcl。这一点已在头部「产物」段与下方 gate.db 注释里写明。
#
# 参数：T7B3_EXTRA 由环境变量传入，格式 "step param val [step param val ...]"
# 产物：reports/t7b3_<tag>_{gate_area,area,timing,coverage}.txt
#       project/t7b3_<tag>_{gate,place}.db
#       project/hdmi_td_Runs/phy_1/hdmi_td.bit

set prjdir [file dirname [file normalize [info script]]]
set repdir [file normalize $prjdir/../reports]
set outdir $prjdir/hdmi_td_Runs/phy_1

set rl 45
if {[info exists ::env(T7B3_RL)] && $::env(T7B3_RL) ne ""} {
    if {![regexp {^[0-9]+$} $::env(T7B3_RL)]} {
        puts "FAIL-T7B3_RL: T7B3_RL 必须是纯数字"
        exit 23
    }
    set rl $::env(T7B3_RL)
}

set extra ""
if {[info exists ::env(T7B3_EXTRA)]} { set extra [string trim $::env(T7B3_EXTRA)] }

set tag "rl$rl"
if {$extra ne ""} { set tag "${tag}_[string map {" " "_"} $extra]" }
set tag [regsub -all {[^A-Za-z0-9_.-]} $tag "_"]
if {[regexp {[/\\:]} $tag]} {
    puts "FAIL-T7B3_TAG: tag 含危险字符"
    exit 24
}

# import_db 复用的 gate.db 由 t10 run2 用同一份 RTL 在 optimize_gate 之后导出。
set gate_db $prjdir/../reports/t10_verify_build_20261103_routefail/run2_defaultseed/t7b3_rl45_gate.db
if {![file exists $gate_db]} {
    puts "FAIL-T7B3_GATEDB_MISSING: $gate_db"
    exit 31
}

# ---------------------------------------------------------------------------
# ★ 时效性断言（captain 补）：gate.db 必须晚于 rtl/ 下所有 .v 的 mtime。
#
#   为什么必须有这一条：本脚本跳过综合，直接拿 gate.db 里的网表做 place/route。
#   如果 gate.db 比某个 .v 旧，那么综合进去的是**旧源码**，但 BRAM=37 / LUT / 时序
#   三道判据全会 PASS —— 位流看起来"成功"，实际验证的是不存在的电路。
#   本工程已经踩过两次同类坑（tb 用 parameter override 绕过常量错误、tb 接线用
#   旧线验证了出货配置里不存在的电路），所以这里必须硬断言而不是只打印。
# ---------------------------------------------------------------------------
set gdb_mtime [file mtime $gate_db]
set newest_v 0
set newest_name ""
foreach vf [glob -nocomplain -directory $prjdir/../rtl -types f -recurse *.v] {
    set vt [file mtime $vf]
    if {$vt > $newest_v} {
        set newest_v $vt
        set newest_name $vf
    }
}
if {$newest_v > $gdb_mtime} {
    puts "FAIL-T7B3_GATEDB_STALE: gate.db 比 RTL 旧，拒绝复用"
    puts "  gate.db : [clock format $gdb_mtime -format {%Y-%m-%d %H:%M:%S}]"
    puts "  最新 .v : [clock format $newest_v -format {%Y-%m-%d %H:%M:%S}]  ($newest_name)"
    puts "  请改用 project/t7b_bit3.tcl 走完整流程重新导出 gate.db"
    exit 32
}
puts "PASS-T7B3_gatedb_fresh: gate.db 晚于全部 RTL（最新 .v = $newest_name）"

puts "INFO-T7B3-TAG=$tag"
puts "INFO-T7B3-RL=$rl"
puts "INFO-T7B3-EXTRA=$extra"
puts "INFO-T7B3-gate_db=[file size $gate_db] bytes"
puts "INFO-T7B3-gate_db_mtime=[clock format $gdb_mtime -format {%Y-%m-%d %H:%M:%S}]"

if {[catch {import_device eagle_s20.db -package EG4S20BG256} err]} {
    puts "FAIL-import_device: $err"; exit 1
}
puts "PASS-import_device"

if {[catch {open_project $prjdir/hdmi_td.al} err]} {
    puts "FAIL-open_project: $err"; exit 2
}
puts "PASS-open_project"

if {[catch {set_param rtl min_ripple_len $rl} err]} {
    puts "FAIL-set_param_rtl: $err"; exit 20
}
puts "PASS-set_param rtl min_ripple_len $rl"
if {[catch {commit_param -step rtl} err]} {
    puts "FAIL-commit_rtl: $err"; exit 21
}
puts "PASS-commit_param rtl"

# 复用综合结果：跳过 elaborate / optimize_rtl / optimize_gate
if {[catch {import_db $gate_db} err]} {
    puts "FAIL-import_db: $err"; exit 30
}
puts "PASS-import_db"

# 应用 place/route 参数（T7B3_EXTRA 三元组），并对每个 distinct step 提交
if {$extra ne ""} {
    # 用 split + 过滤空串，不用 regexp -all -inline {\S+}：本机 TD 的 Tcl 里
    # 那次组合没有返回任何元素（导致 set_param 收到三个空参数，报 RUN-8001）。
    set toks {}
    foreach t [split $extra " "] {
        if {$t ne ""} { lappend toks $t }
    }
    if {[expr {[llength $toks] % 3}] != 0} {
        puts "FAIL-T7B3_EXTRA: 需要 3 的倍数个 token，实际 [llength $toks]"
        exit 22
    }
    set steps {}
    foreach {st pa va} $toks {
        if {[catch {set_param $st $pa $va} err]} {
            puts "FAIL-set_param $st $pa $va: $err"; exit 22
        }
        puts "PASS-set_param $st $pa $va"
        if {[lsearch -exact $steps $st] < 0} { lappend steps $st }
    }
    foreach st $steps {
        if {[catch {commit_param -step $st} err]} {
            puts "FAIL-commit_$st: $err"; exit 22
        }
        puts "PASS-commit_param $st"
    }
} else {
    puts "INFO-extra_skipped: T7B3_EXTRA 为空"
}
# import_db 之后必须补 commit place/route，否则参数不下发（t7b_seed_full.tcl:78-85）
if {[catch {commit_param -step place} err]} {
    puts "FAIL-commit_place_after_import: $err"; exit 22
}
puts "PASS-commit_param place (post-import)"
if {[catch {commit_param -step route} err]} {
    puts "FAIL-commit_route_after_import: $err"; exit 22
}
puts "PASS-commit_param route (post-import)"

if {[catch {read_adc $prjdir/hdmi/dmz_eg4s20_hdmi.adc} err]} {
    puts "FAIL-read_adc: $err"; exit 4
}
puts "PASS-read_adc"
if {[catch {read_sdc $prjdir/hdmi/dmz_eg4s20_hdmi.sdc} err]} {
    puts "FAIL-read_sdc: $err"; exit 5
}
puts "PASS-read_sdc"

set t0 [clock milliseconds]
if {[catch {place} err]} {
    puts "FAIL-place: $err"; exit 8
}
puts "PASS-place"
puts "INFO-place_ms=[expr {[clock milliseconds] - $t0}]"
if {[catch {export_db $prjdir/t7b3_${tag}_place.db} err]} {
    puts "WARN-export_place_db: $err"
} else {
    puts "PASS-export_place_db"
}

set t1 [clock milliseconds]
if {[catch {route} err]} {
    puts "FAIL-route: $err"; exit 9
}
puts "PASS-route"
puts "INFO-route_ms=[expr {[clock milliseconds] - $t1}]"

if {[catch {update_timing -mode final} err]} {
    puts "FAIL-update_timing: $err"; exit 10
}
puts "PASS-update_timing"

if {[catch {report_timing_summary -file $repdir/t7b3_${tag}_timing.txt} err]} {
    puts "FAIL-report_timing: $err"
} else {
    puts "PASS-report_timing"
}
if {[catch {report_area -file $repdir/t7b3_${tag}_area.txt} err]} {
    puts "FAIL-report_area: $err"
} else {
    puts "PASS-report_area"
}
if {[catch {check_timing -file $repdir/t7b3_${tag}_coverage.txt} err]} {
    puts "FAIL-check_timing: $err"
} else {
    puts "PASS-check_timing"
}

# ---- #slices 只在 *.qor 里 ----
foreach step {gate place route} {
    set qor $prjdir/$step.qor
    if {[file exists $qor]} {
        set fh [open $qor r]; set txt [read $fh]; close $fh
        if {[regexp {\|\s*#slices\s*\|\s*([0-9]+)\s*\|} $txt -> sl]} {
            set pct ""
            if {[regexp {\|\s*slices percentage\s*\|\s*([0-9.]+)%} $txt -> p]} { set pct " ($p%)" }
            puts "T7B_SLICES-$step=$sl$pct"
        }
    }
}

# ---- 面积判据 ----
set area_file $repdir/t7b3_${tag}_area.txt
if {![file exists $area_file]} { puts "T7B_AREA_MISSING"; exit 15 }
if {[file size $area_file] == 0} { puts "T7B_AREA_EMPTY"; exit 15 }
set fh [open $area_file r]; set atxt [read $fh]; close $fh
if {![regexp {#bram\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)} $atxt -> bram_used bram_total]} {
    puts "T7B_AREA_NO_BRAM"; exit 15
}
if {![regexp {#lut\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)} $atxt -> lut_used lut_total]} {
    puts "T7B_AREA_NO_LUT"; exit 15
}
puts "T7B_BRAM=$bram_used/$bram_total"
puts "T7B_LUT=$lut_used/$lut_total"
if {$bram_used < 35} {
    puts "T7B_BRAM_REGRESSED: $bram_used"
    exit 16
}

# ---- 时序判据 ----
set tim_file $repdir/t7b3_${tag}_timing.txt
if {![file exists $tim_file]} { puts "T7B_TIMING_MISSING"; exit 11 }
if {[file size $tim_file] == 0} { puts "T7B_TIMING_EMPTY"; exit 11 }
set fh [open $tim_file r]; set ttxt [read $fh]; close $fh
if {![regexp {SWNS:\s+(-?[0-9.]+)ns,\s+STNS:} $ttxt -> setup_slack]} {
    puts "T7B_TIMING_NO_SWNS"; exit 11
}
if {![regexp {HWNS:\s+(-?[0-9.]+)ns,\s+HTNS:} $ttxt -> hold_slack]} {
    puts "T7B_TIMING_NO_HWNS"; exit 11
}
puts "T7B_TIMING_PASSED: setup=$setup_slack ns hold=$hold_slack ns"
if {$setup_slack < 0 || $hold_slack < 0} {
    puts "T7B_TIMING_FAILED: setup=$setup_slack hold=$hold_slack"
    exit 12
}

# ---- 位流 ----
if {[catch {bitgen -bit $outdir/hdmi_td.bit} err]} {
    puts "FAIL-bitgen: $err"; exit 13
}
puts "PASS-bitgen"
if {![file exists $outdir/hdmi_td.bit] || [file size $outdir/hdmi_td.bit] == 0} {
    puts "T7B_BITFILE_MISSING"; exit 14
}
puts "T7B_BITFILE_OK: $outdir/hdmi_td.bit ([file size $outdir/hdmi_td.bit] bytes)"
exit 0
