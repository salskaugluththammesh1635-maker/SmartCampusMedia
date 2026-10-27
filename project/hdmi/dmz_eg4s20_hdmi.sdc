# =============================================================================
# dmz_eg4s20_hdmi.sdc — 校园媒体播放器（HDMI + SiP SDRAM）时序约束
# =============================================================================
# 50MHz reference; derive PLL clocks without redefining the same output pin.
# Keep the 25/125MHz HDMI relationship and the 0-degree/180-degree SDRAM relationship.
# =============================================================================
# 【2026-10-27 最终决定：SDRAM 域两次降频 150MHz → 100MHz → 40MHz】
#
# 上午的结论是「-7.232 ns 在 150MHz 下数学上无解」。修法不是改约束，而是**降频**。
# 先降一次到 100MHz，实测证明仍不够；再降到 40MHz。约束文件本身**一条都没改**，
# 只是同组写法保留。
#
# 【第一次降频 100MHz 的实测结果（reports/timing_100mhz_20261027/run.ts）】
#   SWNS -5.565 ns / STNS -231.925 ns，两组接口仍然为负：
#     · 读 DQ（clkc[2]→clkc[1]）：SWNS -5.565 ns，32 违例 / 32 端点
#     · 写 DQ（clkc[1]→clkc[2]）：SWNS -2.001 ns，32 违例 / 48 端点
#     · 内部逻辑域（clkc[1] 自身）：**+2.604 ns，0 违例** ← 逻辑从来不是问题
#   由此反推出一个**与频率无关的常数开销**（150/100MHz 两点互证）：
#       读 slack = T/2 − 10.565 ns   （150M: 3.333−10.565 = −7.232 ✓）
#                                    （100M: 5.000−10.565 = −5.565 ✓）
#       写 slack = T/2 −  7.001 ns   （150M: 3.333− 6.870 ≈ −3.537 ✓）
#                                    （100M: 5.000− 7.001 = −2.001 ✓）
#   常数里 5.000 ns 是 TD 硬核模型惩罚，其余是时钟树偏斜（读 Skew 4.172 ns）
#   与封装内走线，**都不随频率缩放**。临界频率：
#       读路径 T/2 ≥ 10.565 → T ≥ 21.130 ns → f ≤ 47.33 MHz  ← 真正瓶颈
#       写路径 T/2 ≥  7.001 → T ≥ 14.002 ns → f ≤ 71.42 MHz
#
# 【第二次降频 40MHz（本次）】
#   T = 25 ns，T/2 = 12.5 ns，预测：读 +1.935 ns、写 +5.499 ns。
#   带宽：40MHz × 4 字节 = 160 MB/s；640×480@60Hz 24 位色仅需 55.3 MB/s，
#   仍富余 2.9 倍。
#
# 【为什么 150MHz 无解（三层证据）】
#
# 一、约束层面的决定性对照（同一 RTL、同一 TD v6.2.168116、同一器件）：
#
#   | 实验 | RTL           | 时钟组          | SWNS      | STNS       |
#   |------|---------------|-----------------|-----------|------------|
#   | ①    | C1/C2 无 BUFG | 0°/180° 同组    | -7.232 ns | -335.004ns |
#   | ②    | C1/C2 加 BUFG | 0°/180° 拆异步  | +0.275 ns | 0.000 ns   |
#   | ③    | C1/C2 加 BUFG | 0°/180° 同组    | -7.232 ns | -335.004ns |
#
#   ③ 是决定性的一组：**加了 BUFG，只要保留 0°/180° 分析，接口余量一个数字都不变。**
#   两条互不混淆的事实：
#     · BUFG 修复（rtl/storage/sdram_pll.v）是**真实有效**的，但只作用于
#       clkc[1] 自身域：SWNS +0.240ns → +0.326ns，Fmax 155.6 → 157.7 MHz，
#       并消除了 PHY-5079（clkc[2] 走 local routing）告警。
#     · 那 -7.232 ns 的**全部**来源是实验 ② 的拆组动作，与被修复的接缝无关。
#       拆组只是把路径移出分析范围，不是把接口修好了。→ 因此不采用。
#
# 二、路径层面的算术（reports/timing_ctrl_samegroup_20261027/timing.txt）：
#
#     Begin : u_sdram_sip.dq[0]   (clkc[2] 上升沿 3.333ns @150MHz)
#               input (hard ip)  +5.000   ← TD 对 SiP 硬核的固定惩罚
#     End   : u_sdram_sip_syn_1.bpad → sdr_wrrd.enc.v 的 Sdr_rd_dout[0]
#
#   Budget 只有半周期 3.333ns，而单项 hard-ip 惩罚就是 5.000ns，5 > 3.333。
#   数据通路本身 Logic Level = 0、net 延迟 0.000ns（Data Path Delay 6.453ns
#   100% 是 cell，全在 PAD/PLL/GCLK 的时间戳上）—— 通路是空的，slack 仍必负。
#   **只要半周期预算 < 5.000ns，这条路无论怎么写 RTL 都不可能收敛。**
#
# 三、物理层面的旁证（安路社区 EG4S20 SDRAM 控制器实测帖）：
#   https://chipdebug.com/forum-post/52599.html
#     · "ODDR → OPAD → SDRAM → DQ → IDDR 总路径约 5ns，不算 SDRAM 的
#        Output Hold 也起码 3.5ns"
#     · "实测片内逻辑最高可跑到 ~150MHz（只能留 5% 时序余量，而且需要极度
#        流水线化），实用主频不超过 100MHz"
#   EG4S20 datasheet 写的 "200MHz" 是**存储颗粒规格**，不是 FPGA 到它的接口上限。
#
# 【为什么 40MHz 就成立】
#   半周期预算 = 25.000ns / 2 = 12.500ns，扣掉 10.565ns 的常数开销后
#   读路径还剩 +1.935ns、写路径剩 +5.499ns。
#   功能上也不需要更高：640×480@60Hz 约需 55.3 MB/s，
#   40MHz × 4 字节 = 160 MB/s，带宽富余 2.9 倍。
#
# 【同组写法必须保留】—— 仓库既有立场
#   （README.md「时钟、复位与跨域」、docs/progress.md 历史结论更正）：
#   同一 PLL 的 0°/180° 有确定相位关系，不得声明为异步组。历史 bring-up 曾
#   用拆组得到过「+0.104ns / 0 违例」的假绿，被明确判定为不能作为接口通过的证据。
#   降频是**真实的物理修复**，拆组是**把问题移出视野**，两者不能互相替代。
#
# 【降频的连带修改清单】（改 sdram_pll 频率时必须同时改）
#   1. ip/local/sdram/global_def.v     → `SDR_CLK_PERIOD`（现为 1000000000/40000000）
#   2. rtl/storage/sdram_ctrl_wrap.v   → `CLK_FREQ_HZ` 默认值（现为 40_000_000）
#   3. rtl/storage/sdram_bringup_top.v → 例化处 `.CLK_FREQ_HZ(40_000_000)`
# =============================================================================

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
# Two independently locked PLLs exchange data through Gray-code asynchronous FIFOs.
# 注意：两组的**组间**异步是合法的（两颗 PLL 各自独立锁定，跨域走 async_fifo）；
#       但 sdram_pll 的 clkc[1] 与 clkc[2] 必须在**同一组内**，见文件头。
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[0] u_pll/pll_inst.clkc[2]}] \
    -group [get_clocks {u_sdram_pll/pll_inst.clkc[1] u_sdram_pll/pll_inst.clkc[2]}]
