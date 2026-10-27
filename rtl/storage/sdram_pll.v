// =============================================================================
// sdram_pll.v — ERAM SDRAM 专用时钟发生器（40MHz 0° + 40MHz 180°）
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 时钟层 —— SDRAM 帧缓冲子系统的时钟源
//   工程归属 : project/hdmi_td.al（被 dmz_eg4s20_hdmi_top.v 例化为 u_sdram_pll）
//   数据流位置:
//       50MHz 晶振(球 R7)
//            ↓
//        【本模块】（独立第二颗 PLL）
//            ├──→ 40MHz   0°（sdram_clk）    → SDRAM 控制器逻辑 + 写 FIFO 写侧
//            └──→ 40MHz 180°（sdram_clk_sft）→ 仅送 SDRAM_CLK 引脚（源同步对齐）
//
//   为什么不用 hdmi_pll 顺便输出 40MHz:
//     hdmi_pll 的 VCO = 1000MHz，需同时整数分出 25MHz(C0) 与 125MHz(C2)。
//     1000 / 40 = 25 虽为整数，但把 SDRAM 时钟塞进同一颗 PLL 会让 HDMI 的
//     25M/125M 参数与环路滤波被迫重验，风险远大于收益；
//     且芯片共 4 颗 PLL、当前只用 2 颗，余量充足。
//     → 结论：**独立第二颗 PLL**。
//
// 【二、2026-10-27 降频决策：150MHz → 100MHz → 40MHz（两次降频，实测驱动）】
//
//   ── 第一次降频：150MHz → 100MHz（已被证明不够）──
//   背景：150MHz 时 SiP SDRAM 接口组始终无法收敛（setup WNS −7.232 ns）。
//   根因不是 RTL 逻辑，而是安路 TD 对 SiP 硬核接口的固定惩罚：
//     - clkc[1]→clkc[2]（写方向）带 output (hard ip) −5.000 ns
//     - clkc[2]→clkc[1]（读方向）带 input  (hard ip) +5.000 ns
//   而 0°/180° 的半周期预算只有 3.333 ns，5 ns > 3.333 ns，
//   **即使数据通路上一个门都没有，slack 也必然是负的** —— 数学上无解。
//
//   ── 100MHz 实测结果（reports/timing_100mhz_20261027/run.ts）──
//   SWNS −5.565 ns / STNS −231.925 ns，两组接口路径**仍然为负**：
//     - 读 DQ（clkc[2]→clkc[1]）：SWNS −5.565 ns，32 违例 / 32 端点
//     - 写 DQ（clkc[1]→clkc[2]）：SWNS −2.001 ns，32 违例 / 48 端点
//     - 内部逻辑域（clkc[1] 自身）：**+2.604 ns，0 违例** ← 逻辑从来不是问题
//   这次实测反推出一个**与频率无关的常数开销**（两点互证）：
//       读路径  slack = T/2 − 10.565 ns   （150M: 3.333−10.565 = −7.232 ✓）
//                                          （100M: 5.000−10.565 = −5.565 ✓）
//       写路径  slack = T/2 −  7.001 ns   （150M: 3.333− 6.870 ≈ −3.537 ✓）
//                                          （100M: 5.000− 7.001 = −2.001 ✓）
//   这两个常数里，5.000 ns 是 TD 硬核模型惩罚，其余是时钟树偏斜（读路径
//   Skew 4.172 ns）与封装内走线。它们**不随频率缩放**，所以降频只能线性地
//   买到 T/2 的增长。由此算出临界频率：
//       读路径需要 T/2 ≥ 10.565 → T ≥ 21.130 ns → **f ≤ 47.33 MHz**
//       写路径需要 T/2 ≥  7.001 → T ≥ 14.002 ns → **f ≤ 71.42 MHz**
//   ⇒ 100MHz 处在两者之上，必然仍红；**读路径是真正的瓶颈**。
//
//   ── 第二次降频：100MHz → 40MHz（本次）──
//   取 40MHz（T = 25 ns，T/2 = 12.5 ns），预测：
//       读 slack = 12.5 − 10.565 = **+1.935 ns**
//       写 slack = 12.5 −  7.001 = **+5.499 ns**
//   带宽校核：40MHz × 4 字节 = 160 MB/s；640×480@60Hz 24 位色只要
//       640×480×60×3 = 55.3 MB/s，仍富余 2.9 倍。
//
//   佐证（安路社区 EG4S20 SDRAM 控制器实测帖，chipdebug.com/forum-post/52599）：
//     - "ODDR → OPAD → SDRAM → DQ → IDDR 总路径约 5 ns，不算 SDRAM 的
//        Output Hold 也起码 3.5 ns"
//     - "实测片内逻辑最高可跑到 ~150MHz（只能留 5% 时序余量，而且需要极度
//        流水线化），实用主频不超过 100MHz"
//     - "当 SDRAM 时钟提前 2.666ns 时，读时序 bug 基本消失"
//   器件 datasheet 的 "200MHz" 是**存储颗粒规格**，不是 FPGA 到它的接口上限。
//
//   为什么这次不继续用「调 SDR」（set_multicycle_path / 拆时钟组）刷绿：
//     - 拆 0°/180° 成异步组会掩盖真实接缝分析（仓库历史已否掉该做法）；
//     - Xilinx 的 MEGA65 工程实测过 set_multicycle_path 反而引入 5.6 ns
//       无端延迟，跨品牌都会反噬。
//   降频是唯一既真实、又不伪造约束的收敛路径。
//
// 【三、本模块功能】
//   一句话职责: 由 50MHz 参考时钟生成 SDRAM 控制器所需的 40MHz 同频异相双时钟。
//   关键特性:
//     - VCO = 1000MHz，C1 = 1000/25 = 40MHz 0°，C2 = 40MHz 180°
//     - 环路参数沿用原 1050MHz 配置（VCO 只降 5%，环路时间常数影响可忽略）
//     - **VCO 保持不变（1000MHz）**，只改 C1/C2 分频比 → 环路滤波无需重验
//
// 【四、接口与内部结构】
//   端口一览:
//     输入  refclk       : 50MHz 参考时钟（球 R7）
//     输入  reset        : 高有效复位（PLLRST_ENA="ENABLE" 使能）
//     输出  extlock      : 锁定指示，高 = 已锁定（顶层引到 LED 便于现场判断）
//     输出  sdram_clk    : 40MHz 0°，供 SDRAM 控制器与写 FIFO 写侧
//     输出  sdram_clk_sft: 40MHz 180°，仅供送到 SDRAM_CLK 引脚
//
//   内部逻辑块（共 3 块）:
//     [1] EG_LOGIC_BUFG  bufg_feedback    C0 输出经全局缓冲后回送 fbclk
//           作用: FEEDBK_PATH="CLKC0_EXT" 要求 C0 经外部缓冲后反馈，
//                 让 PLL 把 BUFG 与走线延迟也纳入锁定范围
//     [2] EG_LOGIC_BUFG  bufg_clk1 / bufg_clk2
//           C1/C2 各自落 GCLK（2026-10-27 修复，见下方 [2] 段注释）
//     [3] EG_PHY_PLL     pll_inst         倍频/分频产生 0° 与 180° 双时钟
//
// 【五、时序行为】
//   - extlock=1 表示 PLL 已锁定；**上电后必须等 extlock 才能发起 SDRAM 操作**
//     （顶层有专门的复位同步器做这件事，本模块只负责给时钟）
//   - sdram_clk 与 sdram_clk_sft 同频、固定 180° 相差，用于 SDRAM 源同步写
//
// 【六、设计陷阱与规避】
//   1) **两颗 PLL 各自独立锁定** → 40MHz 域与 25MHz 域之间没有任何相位关系，
//      跨域**必须**走 async_fifo（已实现，见 rtl/common/async_fifo.v）。
//      绝不能因为"都是 PLL 出来的"就当成同步域。
//   2) **CPHASE/FPHASE 的编码规则（已从官方 IP Generator 输出反推并验证）**：
//          相位延时 = (CPHASE + 1) + FPHASE/8   个 VCO 周期
//          相移角度 = 延时 / CLKCx_DIV × 360°
//      验证 ①：官方 lab_ex5 的 PLL_HDMI_AUDIO.v，C1 目标 90°，
//              DIV=2 / CPHASE=1 / FPHASE=4 → (2 + 0.5)/2 = 1.25 周期
//              → 小数部分 0.25 × 360° = 90° ✓
//      验证 ②：本文件降频前的 C2 目标 180°，DIV=7 / CPHASE=2 / FPHASE=4
//              → (3 + 0.5)/7 = 0.5 → 180° ✓
//      由此得 180° 的通用写法：
//              DIV 为偶数 → CPHASE = DIV/2 − 1，FPHASE = 0
//              DIV 为奇数 → CPHASE = (DIV−3)/2，  FPHASE = 4
//      本文件降频后 DIV=25（奇数）→ CPHASE = (25−3)/2 = 11，FPHASE = 4，
//              验证 (12 + 0.5)/25 = 0.5 → 180° ✓
//   3) **环路滤波参数与目标频率绑定**。本文件两次降频（150→100→40MHz）
//      **VCO 都保持 1000MHz 不变**，只改 C1/C2 分频比，
//      因此沿用原 GMC_GAIN/ICP_CURRENT/KVCO/LPF_CAPACITOR/LPF_RESISTOR 是安全的；
//      若改 VCO 幅度超过 ±20%，必须用 TD 的 IP Generator 重新生成。
//   4) **sdram_clk_sft 只送引脚**，绝不要拿它驱动任何内部逻辑
//      （否则等于引入一个与 sdram_clk 相位不同的时钟域）。
//   5) **改频率必须同步改三处**，否则刷新周期算错或参数不一致：
//        a) ip/local/sdram/global_def.v 的 `SDR_CLK_PERIOD`
//           与 `SELF_REFRESH_INTERVAL`
//        b) rtl/storage/sdram_ctrl_wrap.v 的 `CLK_FREQ_HZ` 默认值
//        c) rtl/storage/sdram_bringup_top.v 里例化时的 `.CLK_FREQ_HZ(...)`
//
// 【上板验证提示】
//   若 extlock 不亮 = PLL 未锁定。优先核对 REFCLK_DIV 与 CLKC0/1/2_DIV
//   的整除关系，或改用 TD 的 IP Generator 重新生成（GUI 会自动算环路参数）。
// =============================================================================
`timescale 1ns / 1ps

module sdram_pll (
    input  wire refclk,        // 50MHz 参考（球 R7）
    input  wire reset,         // 高有效复位
    output wire extlock,       // PLL 锁定指示（高 = 锁定）
    output wire sdram_clk,     // 40MHz 0°
    output wire sdram_clk_sft  // 40MHz 180°
);

    wire clk0_buf;          // C0 通道原始输出（未经全局缓冲），既作反馈源也作 clk0_out
    wire clk0_out;          // C0 经全局缓冲后的 12.5MHz（仅反馈用，不对外）
    wire clk1_raw;          // C1 原始输出（40MHz 0°，未走 BUFG）
    wire clk2_raw;          // C2 原始输出（40MHz 180°，未走 BUFG）
    wire clk1_buf;          // C1 经 BUFG 后的 40MHz 0°（= 全设计 SDRAM 主时钟）
    wire clk2_buf;          // C2 经 BUFG 后的 40MHz 180°（仅送 SDRAM_CLK 引脚）

    // -------------------------------------------------------------------------
    // [0] 悬空端口占位
    //     Verilog-2001 里 `open` 不是关键字，直接写 .port(open) 会被综合器当作
    //     隐式 wire 并报 "undeclared symbol 'open'"。因此显式声明悬空信号。
    //     注意：PLL 原语未使用的输出**不能**留空不接，必须显式终止。
    // -------------------------------------------------------------------------
    wire        psdone_unused;
    wire [7:0]  dout_unused;
    wire        clk3_unused;
    wire        clk4_unused;

    // -------------------------------------------------------------------------
    // [1] C0 反馈路径：PLL 输出 → BUFG → 回送 fbclk
    //     FEEDBK_PATH="CLKC0_EXT" 要求这一级不能省
    //     ⚠️ 这一路的输出是 **12.5MHz（C0）**，不是 40MHz。
    //        它只用于 fbclk 反馈，绝不能当作 sdram_clk 使用。
    // -------------------------------------------------------------------------
    EG_LOGIC_BUFG bufg_feedback (
        .i (clk0_buf),
        .o (clk0_out)
    );

    // -------------------------------------------------------------------------
    // [2] 40MHz 0° / 180° 的全局缓冲
    //     【2026-10-27 修复：必须手工插入 BUFG，不能依赖工具自动推断】
    //     修复前：C1/C2 直接从 PLL 原语 `assign` 到顶层端口，依赖 TD 布局时
    //             自动插入全局缓冲。实测布线后：
    //               - 只有 C0（经 bufg_feedback）落到了 GCLK；
    //               - C1 走的是普通布线网络，fanout 844、网线延迟 2.410ns；
    //               - C2 更糟，fanout=1 且被判定为 local routing
    //                 （TD 报 PHY-5079 CRITICAL-WARNING）。
    //     修复后：C1/C2 各自经 EG_LOGIC_BUFG 落到 GCLK，
    //             ① 时钟树延迟由全局网络统一承担，不再计入数据通路；
    //             ② 两颗时钟的 skew 大幅收敛；
    //             ③ PHY-5079 的 local routing 告警随之消失；
    //             ④ 实测 150MHz 自身域 SWNS 从 +0.240ns 提升到 +0.326ns。
    //     注：C0 已经走 bufg_feedback，**不能**再加第二个 BUFG
    //         （一个 PLL 通道只能进一个 BUFG，否则反馈路径与时钟路径不一致）。
    // -------------------------------------------------------------------------
    EG_LOGIC_BUFG bufg_clk1 (
        .i (clk1_raw),
        .o (clk1_buf)
    );

    EG_LOGIC_BUFG bufg_clk2 (
        .i (clk2_raw),
        .o (clk2_buf)
    );

    assign sdram_clk     = clk1_buf;   // C1 = 40MHz 0°（经 GCLK）
    assign sdram_clk_sft = clk2_buf;   // C2 = 40MHz 180°（经 GCLK）

    // -------------------------------------------------------------------------
    // [3] PLL 本体
    //     VCO = (50/4) × 80 × 1 = 12.5 × 80 = 1000 MHz（两次降频均不变）
    //      C0 = 1000/80 = 12.5 MHz   （仅作反馈，不对外使用）
    //      C1 = 1000/25 = 40 MHz     （0°，CPHASE=24 → 延时 25 周期 = 1 整圈）
    //      C2 = 1000/25 = 40 MHz     （180°，CPHASE=11 + FPHASE=4 → 12.5 周期 = 半圈）
    // -------------------------------------------------------------------------
    EG_PHY_PLL #(
        .DPHASE_SOURCE      ("DISABLE"),
        .DYNCFG             ("DISABLE"),
        .FIN                ("50.000"),     // 输入 50MHz
        .FEEDBK_MODE        ("NORMAL"),
        .FEEDBK_PATH        ("CLKC0_EXT"),  // C0 外部反馈（经 BUFG）
        .STDBY_ENABLE       ("DISABLE"),
        .PLLRST_ENA         ("ENABLE"),
        .SYNC_ENABLE        ("DISABLE"),
        .DERIVE_PLL_CLOCKS  ("DISABLE"),
        .GEN_BASIC_CLOCK    ("DISABLE"),
        // ---- 环路参数：VCO 保持 1000MHz 不变，原配置原样沿用 ----
        .GMC_GAIN           (0),
        .ICP_CURRENT        (9),
        .KVCO               (2),
        .LPF_CAPACITOR      (2),
        .LPF_RESISTOR       (8),
        // ---- 分频比 ----
        .REFCLK_DIV         (4),            // 50/4 = 12.5MHz（内部参考，保持不变）
        .FBCLK_DIV          (1),
        // ---- C0: 12.5MHz（仅反馈，不对外）----
        .CLKC0_ENABLE       ("ENABLE"),
        .CLKC0_DIV          (80),           // VCO = 12.5 × 80 = 1000MHz
        .CLKC0_CPHASE       (79),           // 延时 80 周期 = 1 整圈 → 0°
        .CLKC0_FPHASE       (0),
        // ---- C1: 40MHz 0° ----
        .CLKC1_ENABLE       ("ENABLE"),
        .CLKC1_DIV          (25),           // 1000/25 = 40MHz
        .CLKC1_CPHASE       (24),           // 延时 25 周期 = 1 整圈 → 0°
        .CLKC1_FPHASE       (0),
        // ---- C2: 40MHz 180°（DIV 奇数 → CPHASE = (DIV−3)/2 = 11，FPHASE = 4）----
        .CLKC2_ENABLE       ("ENABLE"),
        .CLKC2_DIV          (25),
        .CLKC2_CPHASE       (11),           // 延时 12.5 周期 = 半圈 → 180°
        .CLKC2_FPHASE       (4)             // 0.5 个 VCO 周期的细调（奇数 DIV 必需）
    ) pll_inst (
        .refclk   (refclk),
        .reset    (reset),
        .stdby    (1'b0),
        .extlock  (extlock),
        .load_reg (1'b0),
        .psclk    (1'b0),
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (psdone_unused),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'b0000_0000),
        .daddr    (6'b000000),
        .do       (dout_unused),
        .fbclk    (clk0_out),               // C0 经 BUFG 反馈（官方同款，关键）
        .clkc     ({clk4_unused, clk3_unused, clk2_raw, clk1_raw, clk0_buf})
    );

endmodule
