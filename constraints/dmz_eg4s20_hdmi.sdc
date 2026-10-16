# ============================================================================
# dmz_eg4s20_hdmi.sdc — HDMI 工程时序约束
# ============================================================================
# 【作用】让静态时序分析（STA）真正"看见" PLL 输出的两个时钟域。
# 【为什么必须有这个文件】
#   hdmi_td.al 原先没挂任何 SDC。实测（无 SDC headless 综合的 hdmi_pr.timing）
#   Clock Summary 里只有 clk0(50MHz, DeriveClock) 一行，clk_5x / clk_pixel 出现
#   0 次 —— PLL 之后的 25MHz 像素域与 125MHz 串化域完全未被分析，
#   "0 时序违例"只是 50MHz 输入域的结论。
#   125MHz（clk_5x）是全设计最快的时钟（TMDS 串行化路径），
#   不约束它 = 显示稳定性（赛规基础要求②）没有时序证据。
# 【TD 6.2.168116 实测写法（与本文件演进记录）】
#   1) rename_clock 两种语法均失败：pin 路径写法报 USR-8125 cannot find
#      target clock；get_clocks 写法报 USR-8124/8130 —— 弃用。
#   2) 官方例程的 rename_clock 对本工程不适用；改用 create_generated_clock
#      直接命名（USR-1002 打印的 derive_clocks 原生语法抄写）。
#      注意会报 USR-6122 "override 自动派生时钟" CRITICAL-WARNING，
#      这是预期行为：新名字顶掉自动名，可忽略。
#   3) derive_clocks 自动派生的实际关系（USR-1002 原文）：
#        clkc[0] = clk ÷2     → 25MHz（像素域，fanout 最大）
#        clkc[2] = clk ×2.5   → 125MHz（串化域）
#      即 hdmi_pll.v 的 .clkc 拼接 {C4,C3,C2,C1,C0} 中 C0 在 clkc[0] 位。
#   4) set_clock_groups -exclusive 实测仍会报告 clk_pixel→clk_5x 的
#      跨域路径（31 条，来自加密核 OSERDES 内部），slack 全正（最差
#      setup 6.307ns）——说明 TD 6.2 的 set_clock_groups 对该写法未生效，
#      但所有路径真实收敛，无违例，保留该语句作为意图声明无害。
#   5) SDC 文件必须存放在 .al 引用的相对路径（project/hdmi/），
#      且 headless 跑 TD 时 CWD 必须是工程目录。
# ============================================================================

# ---- 1. 板级输入主时钟：50MHz（球 R7），周期 20ns ----
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ---- 2. 从 PLL 自动推导输出时钟 ----
derive_clocks

# ---- 3. 命名两个关键 PLL 输出（derive_clocks 同款原生语法） ----
create_generated_clock -name {clk_pixel} -source [get_ports {clk}] -master_clock {clk} -divide_by 2.0000 -duty_cycle 50.0000 [get_pins {u_pll/pll_inst.clkc[0]}]
create_generated_clock -name {clk_5x}    -source [get_ports {clk}] -master_clock {clk} -multiply_by 2.5000 -duty_cycle 50.0000 [get_pins {u_pll/pll_inst.clkc[2]}]

# ---- 4. 像素域与 5× 串化域之间的数据交互只发生在 OSERDES 原语内部 ----
#   RTL 层两域之间无数据路径；设为 exclusive 避免伪跨域违例
#   —— 与官方例程写法一致（见文件头实测记录第 4 条）。
set_clock_groups -exclusive \
    -group [get_clocks {clk_pixel}] \
    -group [get_clocks {clk_5x}]
