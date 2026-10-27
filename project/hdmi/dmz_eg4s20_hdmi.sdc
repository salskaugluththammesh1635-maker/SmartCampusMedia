# =============================================================================
# dmz_eg4s20_hdmi.sdc — 校园媒体播放器（HDMI + SiP SDRAM）时序约束
# =============================================================================
# 50MHz reference; derive PLL clocks without redefining the same output pin.
# Keep the 25/125MHz HDMI relationship and 150MHz/180-degree SDRAM relationship.
# =============================================================================
# 【2026-10-27 结论：0°/180° 必须留在同一时钟组，不要拆成异步组】
#
# 一天之内做过三次对照实验（同一 RTL、同一 TD v6.2.168116、同一器件）：
#
#   | 实验 | RTL                  | 时钟组          | SWNS      | STNS       |
#   |------|----------------------|-----------------|-----------|------------|
#   | ①    | C1/C2 无 BUFG        | 0°/180° 同组    | -7.232 ns | -335.004ns |
#   | ②    | C1/C2 加 BUFG        | 0°/180° 拆异步  | +0.275 ns | 0.000 ns   |
#   | ③    | C1/C2 加 BUFG        | 0°/180° 同组    | -7.232 ns | -335.004ns |
#
#   ③ 是决定性的一组：**加了 BUFG，只要保留 0°/180° 分析，接口余量一个数字都不变。**
#   由此得到两条互不混淆的事实：
#     · BUFG 修复（rtl/storage/sdram_pll.v）是**真实有效**的，但它只作用于
#       clkc[1] 自身域：SWNS +0.240ns → +0.326ns，Fmax 155.6 → 157.7 MHz，
#       并且消除了 PHY-5079（clkc[2] 走 local routing）告警。
#     · 那 -7.232 ns 的**全部**来源是实验 ② 里的拆组动作，与被修复的接缝无关。
#       拆组只是把路径移出分析范围，不是把接口修好了。
#
# 【为什么这条路径在数学上无法收敛】
#   最差路径（reports/timing_ctrl_samegroup_20261027/ctrl.timing 的
#   clkc[2] -> clkc[1] 组）实际构成是：
#
#     Begin : u_sdram_sip.dq[0]   (clkc[2] 上升沿 3.333ns)
#               PAD x040y041  3.816 -> launch edge @9.165ns
#               input (hard ip)  +5.000   ← TD 对 SiP 硬核的固定惩罚
#     End   : u_sdram_sip_syn_1.bpad
#               -> sdr_wrrd.enc.v 的 Sdr_rd_dout[0] (clkc[1] 上升沿 6.666ns)
#
#   Budget 只有半个周期 3.333ns，而单项 hard-ip 惩罚就是 5.000ns，5 > 3.333。
#   数据通路本身 Logic Level = 0、net 延迟 0.000ns（Data Path Delay 6.453ns
#   100% 是 cell，全在 PAD/PLL/GCLK 的时间戳上）—— 通路是空的，slack 仍必负。
#   这是 TD 的 SiP 硬核接口模型在 150MHz 下的建模口径问题，不是 RTL 缺陷。
#   旁证：reports/image_dm_fix/candidate.json 里，那个真机上跑出红块、
#   整帧比较通过的诊断工程，setup_wns_ns 同样是 -7.232、timing_passed=false。
#
# 【所以本文件保留同组写法】——按仓库既有立场
#   （README.md「时钟、复位与跨域」、docs/progress.md 历史结论更正）：
#   同一 PLL 的 0°/180° 有确定相位关系，不得声明为异步组。历史 bring-up 曾
#   用拆组得到过「+0.104ns / 0 违例」的假绿，被明确判定为不能作为接口通过的证据。
#   本工程如实报告 -7.232 ns，并把它列为发布阻塞项，而不是用约束掩盖。
#
# 【不要把这条路走回去】若将来要真正解决 SiP 接口时序，方向是给 SiP 引脚补
#   set_input_delay / set_output_delay 配合器件 tAC 重新建模，或用
#   set_multicycle_path 声明读路径实际跨两拍；而不是重新拆异步组。
# =============================================================================

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
# Two independently locked PLLs exchange data through Gray-code asynchronous FIFOs.
# 注意：两组的**组间**异步是合法的（两颗 PLL 各自独立锁定，跨域走 async_fifo）；
#       但 sdram_pll 的 clkc[1] 与 clkc[2] 必须在**同一组内**，见文件头。
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[0] u_pll/pll_inst.clkc[2]}] \
    -group [get_clocks {u_sdram_pll/pll_inst.clkc[1] u_sdram_pll/pll_inst.clkc[2]}]
