# =============================================================================
# sdram_bringup_rw.sdc — SDRAM 150MHz bring-up 验证工程时序约束
# =============================================================================
# 【作用】让 STA 真正"看见" 150MHz 时钟域。
# 【为什么必须有这个文件】
#   若不显式约束，TD 的 Clock Summary 只有 50MHz 输入域，
#   "0 违例"只是 50MHz 的结论，150MHz 域根本没被分析。
#   本次验证的核心问题恰恰是"150MHz 能不能收敛"，所以约束必须写全。
#
# 【本工程的时钟】
#   clk  : 50MHz 输入（球 R7），周期 20ns —— 唯一的外部时钟
#   PLL 输出三颗（由 derive_clocks 自动派生，不要手工重定义）：
#     u_pll/pll_inst.clkc[0] : 12.5MHz  （VCO 反馈支路 C0）
#     u_pll/pll_inst.clkc[1] : 150MHz 0°（SDRAM 控制器逻辑主时钟）
#     u_pll/pll_inst.clkc[2] : 150MHz 180°（只送 SDRAM_CLK 引脚）
#
# 【重要 — 曾经踩过的坑（勿重犯）】
#   初版这里写了 create_generated_clock 给 clkc[1]/clkc[2] 重新命名，结果与
#   derive_clocks 自动派生的同名目标**冲突**，TD 报：
#       USR-6122 CRITICAL-WARNING: Clock definition problem.
#                 Clock clk_sdr override clock u_pll/pll_inst.clkc[1],
#                 as two clocks are defined on the same target pin.
#       USR-8159 CRITICAL-WARNING: Command create_generated_clock ... fails.
#       USR-8130 CRITICAL-WARNING: No clock match the pattern: clk_sdr.
#   三层连锁失败后，Clock Summary 里**根本没有 150MHz**，STA 退化成只分析
#   50MHz —— 这正是"看起来 0 违例、实则关键时钟未被分析"的经典假绿。
#   正确做法：derive_clocks 已经能从 EG_PHY_PLL 的 CLKC*_DIV 参数正确反推
#   频率（日志里能看到 multiply_by 3.0000 / phase 180），
#   **直接用它派生的名字**，不要再 create_generated_clock。
# =============================================================================

# ---- 1. 板级输入主时钟：50MHz，周期 20ns ----
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ---- 2. 从 PLL 参数自动派生全部输出时钟 ----
#   derive_clocks 读 EG_PHY_PLL 的 REFCLK_DIV/CLKC*_DIV/CLKC*_CPHASE 参数，
#   实测会自动生成：
#     create_generated_clock -name {u_pll/pll_inst.clkc[0]} ... -divide_by 4.0000
#     create_generated_clock -name {u_pll/pll_inst.clkc[1]} ... -multiply_by 3.0000
#     create_generated_clock -name {u_pll/pll_inst.clkc[2]} ... -multiply_by 3.0000 -phase 180
#   即 12.5MHz / 150MHz 0° / 150MHz 180°，与 sdram_pll.v 的意图完全一致。
derive_clocks

# ---- 3. 声明两颗 150MHz 之间是固定相位关系 ----
#   clkc[1] 驱动全部控制器逻辑，clkc[2] 只送 SDRAM_CLK 引脚，
#   RTL 层两者之间**没有数据路径**（SDRAM DQ 由器件在 CLK 边沿采样）。
#   显式声明为互不相关的时钟组，避免 TD 把 180° 相移当成需要收敛的跨域路径。
#   注意：这里用的是 derive_clocks 自动派生的**原始名字**，
#   若写成自定义名（如 clk_sdr）会立即触发 USR-8130 "No clock match"。
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[1]}] \
    -group [get_clocks {u_pll/pll_inst.clkc[2]}]
