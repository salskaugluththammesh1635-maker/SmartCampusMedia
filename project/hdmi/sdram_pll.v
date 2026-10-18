// =============================================================================
// sdram_pll.v — ERAM SDRAM 专用时钟发生器（150MHz 0° + 150MHz 180°）
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 时钟层 —— SDRAM 帧缓冲子系统的时钟源
//   工程归属 : project/hdmi_td.al（被 dmz_eg4s20_hdmi_top.v 例化为 u_sdram_pll）
//   数据流位置:
//       50MHz 晶振(球 R7)
//            ↓
//        【本模块】（独立第二颗 PLL）
//            ├──→ 150MHz   0°（sdram_clk）    → SDRAM 控制器逻辑 + 写 FIFO 写侧
//            └──→ 150MHz 180°（sdram_clk_sft）→ 仅送 SDRAM_CLK 引脚（源同步对齐）
//
//   为什么不用 hdmi_pll 顺便输出 150MHz:
//     hdmi_pll 的 VCO = 1000MHz，需同时整数分出 25MHz(C0) 与 125MHz(C2)。
//     1000 / 150 = 6.667，非整数 → 同一 VCO 分不出 150MHz。
//     理论上换一个能同时整除 25/125/150 的 VCO 也可行（最小公倍数 750：
//     750/25=30、750/125=6、750/150=5，均为整数），但那要**推翻并重验**
//     hdmi_pll 现有的 25M/125M 全部参数与环路滤波，风险远大于收益；
//     且芯片共 4 颗 PLL、当前只用 1 颗，余量充足。
//     → 结论：**独立第二颗 PLL**，参数直接沿用官方已验证的 1050MHz 配置。
//
// 【二、本模块功能】
//   一句话职责: 由 50MHz 参考时钟生成 SDRAM 控制器所需的 150MHz 同频异相双时钟。
//   关键特性:
//     - VCO = 1050MHz，C1 = 1050/7 = 150MHz 0°，C2 = 150MHz 180°
//     - **参数完全沿用安路官方 APUG011 例程 prj/al_ip/clk_pll.v**
//       （FIN=25.000 / REFCLK_DIV=2 / CLKC0_DIV=84 → VCO=1050MHz），
//       只是把参考频率从 25MHz 换成 50MHz、REFCLK_DIV 取 4，
//       让内部参考仍是 12.5MHz，VCO 与各分频比一个不动。
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  refclk       : 50MHz 参考时钟（球 R7）
//     输入  reset        : 高有效复位（PLLRST_ENA="ENABLE" 使能）
//     输出  extlock      : 锁定指示，高 = 已锁定（顶层引到 LED 便于现场判断）
//     输出  sdram_clk    : 150MHz 0°，供 SDRAM 控制器与写 FIFO 写侧
//     输出  sdram_clk_sft: 150MHz 180°，仅供送到 SDRAM_CLK 引脚
//
//   内部逻辑块（共 2 块）:
//     [1] EG_LOGIC_BUFG  bufg_feedback    C0 输出经全局缓冲后回送 fbclk
//           作用: FEEDBK_PATH="CLKC0_EXT" 要求 C0 经外部缓冲后反馈，
//                 让 PLL 把 BUFG 与走线延迟也纳入锁定范围
//     [2] EG_PHY_PLL     pll_inst         倍频/分频产生 0° 与 180° 双时钟
//
// 【四、时序行为】
//   - extlock=1 表示 PLL 已锁定；**上电后必须等 extlock 才能发起 SDRAM 操作**
//     （顶层有专门的复位同步器做这件事，本模块只负责给时钟）
//   - sdram_clk 与 sdram_clk_sft 同频、固定 180° 相差，用于 SDRAM 源同步写
//
// 【五、设计陷阱与规避】
//   1) **两颗 PLL 各自独立锁定** → 150MHz 域与 25MHz 域之间没有任何相位关系，
//      跨域**必须**走 async_fifo（已实现，见 rtl/common/async_fifo.v）。
//      绝不能因为"都是 PLL 出来的"就当成同步域。
//   2) **CPHASE/FPHASE 不要乱改**。180° 相移靠 `CLKC2_CPHASE=2, FPHASE=4`
//      与 DIV=7 配合实现（官方值），手算容易偏差，导致 SDRAM 采样窗口偏移。
//   3) **环路滤波参数与目标频率绑定**。本模块沿用官方 GMC_GAIN/ICP_CURRENT/
//      KVCO/LPF_CAPACITOR/LPF_RESISTOR，因为它们对应的就是 1050MHz VCO。
//   4) **sdram_clk_sft 只送引脚**，绝不要拿它驱动任何内部逻辑
//      （否则等于引入一个与 sdram_clk 相位不同的时钟域）。
//   5) **改频率必须同步改 global_def.v** 的 `SDR_CLK_PERIOD` 与
//      `SELF_REFRESH_INTERVAL` 两个宏，否则刷新周期算错，SDRAM 会丢数据。
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
    output wire sdram_clk,     // 150MHz 0°
    output wire sdram_clk_sft  // 150MHz 180°
);

    wire clk0_buf;          // C0 通道原始输出（未经全局缓冲），用作反馈源

    // -------------------------------------------------------------------------
    // [1] C0 反馈路径：PLL 输出 → BUFG → 回送 fbclk
    //     FEEDBK_PATH="CLKC0_EXT" 要求这一级不能省
    // -------------------------------------------------------------------------
    EG_LOGIC_BUFG bufg_feedback (
        .i (clk0_buf),
        .o (sdram_clk)
    );

    // -------------------------------------------------------------------------
    // [2] PLL 本体
    //     VCO = (50/4) × 84 = 12.5 × 84 = 1050 MHz
    //      C0 = 1050/84 = 12.5 MHz   （仅作反馈，不对外使用）
    //      C1 = 1050/7  = 150 MHz    （0°）
    //      C2 = 1050/7  = 150 MHz    （180°，官方 CPHASE=2 / FPHASE=4）
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
        // ---- 环路参数：官方 APUG011 1050MHz VCO 配置，原样沿用 ----
        .GMC_GAIN           (0),
        .ICP_CURRENT        (9),
        .KVCO               (2),
        .LPF_CAPACITOR      (2),
        .LPF_RESISTOR       (8),
        // ---- 分频比 ----
        .REFCLK_DIV         (4),            // 50/4 = 12.5MHz（与官方 25/2 等效）
        .FBCLK_DIV          (1),
        // ---- C0: 12.5MHz（仅反馈，不对外）----
        .CLKC0_ENABLE       ("ENABLE"),
        .CLKC0_DIV          (84),           // VCO = 12.5 × 84 = 1050MHz
        .CLKC0_CPHASE       (83),
        .CLKC0_FPHASE       (0),
        // ---- C1: 150MHz 0° ----
        .CLKC1_ENABLE       ("ENABLE"),
        .CLKC1_DIV          (7),            // 1050/7 = 150MHz
        .CLKC1_CPHASE       (6),
        .CLKC1_FPHASE       (0),
        // ---- C2: 150MHz 180°（官方值 CPHASE=2 / FPHASE=4）----
        .CLKC2_ENABLE       ("ENABLE"),
        .CLKC2_DIV          (7),
        .CLKC2_CPHASE       (2),
        .CLKC2_FPHASE       (4)
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
        .psdone   (open),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'b0000_0000),
        .daddr    (6'b000000),
        .do       ({open, open, open, open, open, open, open, open}),
        .fbclk    (sdram_clk),              // C0 外部反馈（关键）
        .clkc     ({open, open, sdram_clk_sft, open, clk0_buf})  // {C4,C3,C2,C1,C0}
    );

endmodule
