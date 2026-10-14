// =============================================================================
// hdmi_pll.v
// 功能: HDMI 时钟发生（50MHz 输入 → 25MHz 像素时钟 + 125MHz 串化时钟）
// -----------------------------------------------------------------------------
// 【参数设计依据】官方底板例程 tx_pll.v（10_VGA_hdmi_tx_display_MB/prj/al_ip/）
//   官方 1080p 配置: REFCLK_DIV=2 → 内部参考 25MHz
//                    VCO = 25 × CLKC0_DIV(43) = 1075 MHz
//                    C1 = 1075/10 = 107.5 MHz  （像素时钟）
//                    C2 = 1075/2  = 537.5 MHz  （5× 串化时钟，严格 5 倍）
// 【本工程 640×480@60 配置】
//   像素时钟 25MHz（标准 25.175MHz 的 99.3%，显示器同步范围内容忍）
//   取 VCO = 25 × 40 = 1000 MHz：
//     C0 = 1000/40 = 25 MHz  → 经 BUFG 输出为像素时钟，同时作反馈
//     C2 = 1000/8  = 125 MHz → 5× 串化时钟 ✓ 严格 5 倍关系
//   注: 25.175MHz 无法由 50MHz 参考整数分频得到（所需 VCO 超出 PLL 上限），
//       故取 25MHz；场频 = 60 × 25/25.175 = 59.58Hz，在显示器同步范围内。
// 【为什么 C0 必须经 BUFG 反馈】
//   原语配置 FEEDBK_PATH="CLKC0_EXT" + .fbclk(clk0_out)，即 C0 走外部反馈
//   路径 —— 这是官方验证过的接法，BUFG 不可省略。
// =============================================================================
`timescale 1ns / 1ps

module hdmi_pll (
    input  wire refclk,      // 50MHz 参考（球 R7）
    input  wire reset,       // 高有效复位（配 PLLRST_ENA="ENABLE"）
    output wire extlock,     // PLL 锁定指示（高 = 锁定）
    output wire clk_pixel,   // 25MHz 像素时钟
    output wire clk_5x       // 125MHz 串化时钟（= 5 × clk_pixel）
);

    wire clk0_buf;

    // C0 反馈路径：PLL 输出 → BUFG → 回送 fbclk，同时作为像素时钟输出
    EG_LOGIC_BUFG bufg_feedback (
        .i (clk0_buf),
        .o (clk_pixel)
    );

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
        // ---- 环路参数：沿用官方 1075MHz 配置（本设计 1000MHz 接近，可共用）----
        .GMC_GAIN           (2),
        .ICP_CURRENT        (9),
        .KVCO               (2),
        .LPF_CAPACITOR      (1),
        .LPF_RESISTOR       (8),
        // ---- 分频比 ----
        .REFCLK_DIV         (2),            // 50/2 = 25MHz 内部参考
        .FBCLK_DIV          (1),
        // ---- C0: 25MHz（反馈 + 像素时钟）----
        .CLKC0_ENABLE       ("ENABLE"),
        .CLKC0_DIV          (40),           // VCO 1000/40 = 25MHz
        .CLKC0_CPHASE       (39),           // = DIV-1
        .CLKC0_FPHASE       (0),
        // ---- C1: 同频备用输出（当前顶层未使用）----
        .CLKC1_ENABLE       ("ENABLE"),
        .CLKC1_DIV          (40),
        .CLKC1_CPHASE       (39),
        .CLKC1_FPHASE       (0),
        // ---- C2: 125MHz（5× 串化时钟）----
        .CLKC2_ENABLE       ("ENABLE"),
        .CLKC2_DIV          (8),            // VCO 1000/8 = 125MHz = 5 × 25MHz
        .CLKC2_CPHASE       (7),
        .CLKC2_FPHASE       (0)
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
        .fbclk    (clk_pixel),              // C0 外部反馈
        .clkc     ({open, open, clk_5x, open, clk0_buf})   // {C4,C3,C2,C1,C0}
    );

endmodule
