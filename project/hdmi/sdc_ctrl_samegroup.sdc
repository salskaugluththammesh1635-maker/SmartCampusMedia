# =============================================================================
# sdc_ctrl_samegroup.sdc — 对照实验用约束（**临时，非交付物**）
# -----------------------------------------------------------------------------
# 目的：分离两个改动的各自贡献。
#
#   改动 A（RTL，rtl/storage/sdram_pll.v）：给 C1/C2 加 EG_LOGIC_BUFG，落 GCLK
#   改动 B（SDC，constraints/dmz_eg4s20_hdmi.sdc）：把 clkc[1] 与 clkc[2]
#           从"同一组"拆成"两个互异步组"，从而不再分析 0°/180° 接口路径
#
# 本文件 = 只做 A、不做 B：
#   · RTL 用带 BUFG 的版本（已被 sync_src.ps1 同步到 project/hdmi/）
#   · 时钟组恢复为修复前的"同组"写法，即保留 clkc[1] <-> clkc[2] 的
#     双向同步分析（这正是仓库既有立场要求保留的）
#
# 判读：
#   若 0°/180° 接口余量显著改善 → 违例主因是时钟树，BUFG 修复已足够，
#                                   不应拆组（拆组属于掩盖）。
#   若仍然大幅为负              → 违例主因是 TD 硬核模型的 ±5ns 固定惩罚，
#                                   属接口建模口径问题，需另行决策。
# =============================================================================

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks

# 修复前的原始写法：两颗 PLL 之间异步，但 SDRAM PLL 的 0°/180° 留在同一组
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[0] u_pll/pll_inst.clkc[2]}] \
    -group [get_clocks {u_sdram_pll/pll_inst.clkc[1] u_sdram_pll/pll_inst.clkc[2]}]
