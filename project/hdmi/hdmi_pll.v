// =============================================================================
// hdmi_pll.v — HDMI 时钟发生器
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 时钟层 —— 整个 HDMI 工程的"心脏"
//   工程归属 : project/hdmi_td.al（被 dmz_eg4s20_hdmi_top.v 例化为 u_pll）
//   数据流位置:
//       50MHz 晶振(球 R7)
//            ↓
//        【本模块】
//            ├──→ 25MHz 像素时钟（clk_pixel）→ 全系统主时钟
//            │      驱动: 键盘扫描 / 视频时序 / 数码管 / 蜂鸣器 / TMDS 像素侧
//            └──→ 125MHz 串化时钟（clk_5x）  → TMDS 并串转换器
//   为什么需要它:
//     HDMI 要求"像素时钟"与"串化时钟"存在**严格 5 倍关系**且同源同相，
//     否则 TMDS 无法正确把 10 bit 并行数据串行化。普通逻辑分频无法保证
//     两个时钟的相位确定性，必须用 PLL 从同一个 VCO 整数分频得到。
//
// 【二、本模块功能】
//   一句话职责: 由 50MHz 参考时钟生成 HDMI 所需的 25MHz 像素时钟与
//               125MHz 串化时钟（严格 5 倍），并输出锁定指示。
//   关键特性:
//     - VCO = 1000MHz，两个输出均由同一 VCO 整数分频 → 天然同源、相位固定
//     - C0 经 BUFG 输出后回送 PLL 的 fbclk（外部反馈路径），
//       这是官方已验证的接法，BUFG 不可省略
//     - 25.175MHz（VESA 标准值）无法由 50MHz 整数分频得到（所需 VCO 超出
//       芯片上限 ~1200MHz），故取 25MHz：偏差 0.7%，场频 59.58Hz，
//       落在显示器同步范围内
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  refclk    : 50MHz 参考时钟（球 R7）
//     输入  reset     : 高有效复位（配置项 PLLRST_ENA="ENABLE" 使能复位）
//     输出  extlock   : 锁定指示，高 = 已锁定（顶层引到 LED[4] 供现场判断）
//     输出  clk_pixel : 25MHz 像素时钟（同时作为反馈源）
//     输出  clk_5x    : 125MHz 串化时钟（= 5 × clk_pixel）
//
//   内部逻辑块（共 2 块）:
//     [1] EG_LOGIC_BUFG  bufg_feedback     原语例化
//           功能: 全局时钟缓冲。把 PLL 的 C0 输出送上全局时钟网络，
//                 同时该信号回送到 PLL 的 fbclk 引脚，构成外部反馈环路
//                 反馈的作用: 让 PLL 把 BUFG 与走线的延迟也纳入锁定范围，
//                 使输出时钟与内部逻辑的相位关系确定
//           输入: clk0_buf（PLL 的 C0 原始输出，25MHz）
//           输出: clk_pixel（既作像素时钟输出，又作反馈源）
//     [2] EG_PHY_PLL     pll_inst          原语例化
//           功能: 锁相倍频/分频，产生 25MHz 与 125MHz
//           输入: refclk, reset, fbclk(=clk_pixel), stdby/ps*/d* 等配置引脚
//           输出: extlock, clk0_buf(→C0, 25MHz), clk_5x(→C2, 125MHz)
//
//   【PLL 参数推导】对照官方 tx_pll.v 结构（10_VGA_hdmi_tx_display_MB/prj/al_ip/）
//     REFCLK_DIV = 2   → 内部参考 = 50/2 = 25 MHz
//     VCO = 25 × CLKC0_DIV(40) = 1000 MHz          （芯片 VCO 范围约 400~1200）
//     C0  = 1000/40 = 25 MHz   （反馈 + 像素时钟）
//     C1  = 1000/40 = 25 MHz   （同频备用输出，当前顶层未使用）
//     C2  = 1000/8  = 125 MHz  （5× 串化时钟，严格 5 倍 ✓）
//     CPHASE = DIV - 1（占空比相关），FPHASE = 0（无额外相移）
//     环路参数 GMC_GAIN/ICP_CURRENT/KVCO/LPF_CAPACITOR/LPF_RESISTOR
//     沿用官方 1075MHz 配置值；本设计 1000MHz 与之同量级，可共用。
//
// 【四、设计思路与范式】
//   主要范式 : 原语例化（Primitive Instantiation）—— 不写逻辑，配置硬核资源
//   次要范式 : 结构化装配（两个原语之间的连接与反馈路径）
//   为什么这样写:
//     时钟的倍频/分频若用普通逻辑实现（例如计数器翻转），会有三个致命问题：
//     抖动大（受逻辑延迟影响）、占空比不精确、两个输出时钟的相位关系不确定。
//     HDMI 要求像素时钟与串化时钟严格 5 倍且同相，只能依靠芯片内的硬核 PLL
//     —— 它由模拟电路（压控振荡器 + 环路滤波器）实现，抖动在皮秒级。
//   关键写法要点:
//     1) 原语名与器件系列强绑定: EG4/SF2 系列用 EG_PHY_PLL、EG_LOGIC_BUFG；
//        换芯片系列必须查对应手册，不能照抄参数名
//     2) 反馈路径必须闭合: FEEDBK_PATH="CLKC0_EXT" 要求 C0 输出经 BUFG 后
//        回送到 fbclk 引脚，漏掉这一步 PLL 不会锁定
//     3) 参数是"算"出来的不是"猜"出来的:
//          VCO = f_ref × CLKC0_DIV（f_ref = FIN / REFCLK_DIV）
//          各输出 = VCO / CLKCx_DIV，且所有分频结果必须整除
//     4) 环路滤波参数（LPF_*/ICP_CURRENT/KVCO）与目标频率相关，
//        最稳妥的做法是用 TD 的 IP Generator 生成（GUI 自动计算）
//   范式认读方法: 见 docs/design_patterns.md
//
// 【上板验证提示】
//   若 LED[4] 不亮 = PLL 未锁定。此时应改用 TD 的 IP Generator 重新生成
//   PLL —— GUI 会按目标频率自动计算环路滤波参数（手算易有偏差）。
// =============================================================================
`timescale 1ns / 1ps

module hdmi_pll (
    input  wire refclk,      // 50MHz 参考（球 R7）
    input  wire reset,       // 高有效复位（配 PLLRST_ENA="ENABLE"）
    output wire extlock,     // PLL 锁定指示（高 = 锁定）
    output wire clk_pixel,   // 25MHz 像素时钟
    output wire clk_5x       // 125MHz 串化时钟（= 5 × clk_pixel）
);

    wire clk0_buf;          // 【C0 通道原始输出】PLL 的 C0 输出（25MHz），尚未经全局缓冲
                            //   作用: 先送 BUFG 缓冲，再由 BUFG 的输出同时充当
                            //         ① 像素时钟 clk_pixel 与 ② 回送 PLL 的 fbclk
                            //         （两者共用同一信号，保证反馈路径真实反映输出时钟）

    // -------------------------------------------------------------------------
    // [1] C0 反馈路径：PLL 输出 → BUFG → 回送 fbclk，同时作为像素时钟输出
    //     这一级不能省：FEEDBK_PATH="CLKC0_EXT" 要求 C0 经外部缓冲后反馈
    // -------------------------------------------------------------------------
    EG_LOGIC_BUFG bufg_feedback (
        .i (clk0_buf),
        .o (clk_pixel)
    );

    // -------------------------------------------------------------------------
    // [2] PLL 本体
    //     输入: refclk(50MHz) / reset / fbclk(clk_pixel)
    //     输出: extlock / clk0_buf(25MHz) / clk_5x(125MHz)
    // -------------------------------------------------------------------------
    EG_PHY_PLL #(
        .DPHASE_SOURCE      ("DISABLE"),
        .DYNCFG             ("DISABLE"),    // 不用动态重配置
        .FIN                ("50.000"),     // 输入 50MHz
        .FEEDBK_MODE        ("NORMAL"),
        .FEEDBK_PATH        ("CLKC0_EXT"),  // C0 外部反馈（经 BUFG）
        .STDBY_ENABLE       ("DISABLE"),
        .PLLRST_ENA         ("ENABLE"),     // 允许 reset 引脚复位 PLL
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
        .FBCLK_DIV          (1),            // 反馈不分频
        // ---- C0: 25MHz（反馈 + 像素时钟）----
        .CLKC0_ENABLE       ("ENABLE"),
        .CLKC0_DIV          (40),           // VCO 1000/40 = 25MHz
        .CLKC0_CPHASE       (39),           // = DIV-1
        .CLKC0_FPHASE       (0),            // 无额外相移
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
        .refclk   (refclk),                 // 参考时钟输入
        .reset    (reset),                  // 高有效复位
        .stdby    (1'b0),                   // 待机模式，不用
        .extlock  (extlock),                // 锁定输出
        .load_reg (1'b0),                   // 动态配置相关，不用
        .psclk    (1'b0),                   // 相移时钟，不用
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (open),
        .dclk     (1'b0),                   // 动态重配置接口，不用
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'b0000_0000),
        .daddr    (6'b000000),
        .do       ({open, open, open, open, open, open, open, open}),
        .fbclk    (clk_pixel),              // C0 外部反馈（关键）
        .clkc     ({open, open, clk_5x, open, clk0_buf})   // {C4,C3,C2,C1,C0}
    );

endmodule
