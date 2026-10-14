// =============================================================================
// dmz_eg4s20_hdmi_top.v
// 功能: 阶段三 —— HDMI 视频输出顶层（640×480@60 测试图 → TMDS → 显示器）
// -----------------------------------------------------------------------------
// 信号链: 50MHz(R7) → PLL(25MHz 像素 + 125MHz 串化) → 视频时序 → 测试图
//         → HDMI TMDS 发送核 → 板载 HDMI 座（P1/N1/P4/J3, LVDS33）
// 时钟架构【关键设计决策】:
//   全系统单一 25MHz 时钟域（= 像素时钟），键盘/数码管/LED/蜂鸣器/视频同域。
//   理由: 彻底规避跨时钟域（CDC）问题；25MHz 对按键扫描/数码管扫描/音调发生
//         都足够（各模块 CLK_FREQ_HZ 参数相应改为 25MHz 即可自适应）。
//   PLL 未锁定时整系统保持复位的状态（板子仍能显示"未锁定"指示）。
// HDMI 实现路径【阶段三选型】:
//   采用官方 DVITransmitter 加密核（底板例程 10_VGA_hdmi_tx_display_MB 同源，
//   与官方赛题参考实现 lab_ex5_i2s 技术同族）。
//   - 加密核文件在 ip/local/hdmi/enc/（IEEE1735 加密, 不入 git）
//   - VHDL 薄封装 rtl/video/hdmi/hdmi_tx.vhd（官方提供, 非加密）
//   - 接口极简: RGB888 + HS/VS/DE + 像素时钟 + 5× 串化时钟
//   备选路径（后续可替换，已在 TD 原语库确认可行）:
//   自研 TMDS = SF2_LOGIC_HS_OSERDES（10:1 串化）+ 自写 8b/10b 编码器，
//   完全可仿真、无加密依赖；本阶段先用官方核快速点亮硬件链路。
// 板级事实（来源: 底板引脚说明 3.3 + 底板例程 hdmi.adc, 已核实）:
//   HDMI_CLK_P=P1  HDMI_D0_P=N1  HDMI_D1_P=P4  HDMI_D2_P=J3（均 LVDS33）
//   板载 HDMI-019S 座 + AZ1045-04F ESD 阵列，无需转接板；无 DDC → 不做 EDID。
// =============================================================================
`timescale 1ns / 1ps

module dmz_eg4s20_hdmi_top (
    // ---- 系统时钟 / 复位 ----
    input  wire        clk,            // 50MHz, 球 R7
    input  wire        rst_n_btn,      // RSTn 按键, 球 E3, 低有效
    // ---- 4x4 矩阵键盘 ----
    output wire [3:0]  key_row,        // E10,C10,F9,D9（低电平扫描选通）
    input  wire [3:0]  key_col,        // E11,D11,C11,F10（上拉, 按下为低）
    // ---- LED（高电平点亮）----
    output wire [7:0]  led,            // B14,B15,B16,C15,C16,E13,E16,F16
    // ---- 数码管（段低电平点亮 / 位低电平选通）----
    output wire [7:0]  seg_data,       // A4,A6,B8,E8,A7,B5,A8,C8
    output wire [3:0]  seg_cs,         // C9,B6,A5,A3
    // ---- 蜂鸣器（低电平响）----
    output wire        buzzer,         // H11
    // ---- HDMI TMDS（只出差分正端；负端由工具按差分对自动配对）----
    output wire        HDMI_CLK_P,     // P1
    output wire        HDMI_D0_P,      // N1
    output wire        HDMI_D1_P,      // P4
    output wire        HDMI_D2_P       // J3
);

    // -------------------------------------------------------------------------
    // 1. PLL 复位：上电后延时释放（官方例程同款做法，等参考时钟稳定）
    // -------------------------------------------------------------------------
    reg [7:0] pll_rst_cnt;
    always @(posedge clk or negedge rst_n_btn) begin
        if (!rst_n_btn)
            pll_rst_cnt <= 8'd0;
        else if (!pll_rst_cnt[7])
            pll_rst_cnt <= pll_rst_cnt + 8'd1;
    end

    wire pll_reset = ~pll_rst_cnt[7];   // 上电期间为高 → 复位 PLL

    // -------------------------------------------------------------------------
    // 2. 时钟：像素 25MHz + 串化 125MHz（严格 5 倍）
    // -------------------------------------------------------------------------
    wire clk_pixel;
    wire clk_5x;
    wire locked;

    hdmi_pll u_pll (
        .refclk    (clk),
        .reset     (pll_reset),
        .extlock   (locked),
        .clk_pixel (clk_pixel),
        .clk_5x    (clk_5x)
    );

    wire rst_n_pll = locked & rst_n_btn;    // PLL 锁定 + 按键未按下

    // 复位同步器：异步置位、同步释放（降低复位释放时刻的亚稳态风险）
    reg [2:0] rst_sync;
    always @(posedge clk_pixel or negedge rst_n_pll) begin
        if (!rst_n_pll)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], 1'b1};
    end

    wire rst_n = rst_sync[2];               // 全系统复位（低有效）

    // -------------------------------------------------------------------------
    // 3. 4x4 矩阵键盘（挂在像素时钟域，25MHz 下 20ms 消抖等效）
    // -------------------------------------------------------------------------
    wire        key_event;
    wire [3:0]  key_code;
    wire [15:0] key_state;                  // 键状态位图（当前未用, 综合会优化）

    key_matrix_4x4 #(
        .CLK_FREQ_HZ (25_000_000),
        .DEBOUNCE_MS (20)
    ) u_key (
        .clk       (clk_pixel),
        .rst_n     (rst_n),
        .key_row   (key_row),
        .key_col   (key_col),
        .key_event (key_event),
        .key_code  (key_code),
        .key_state (key_state)
    );

    // -------------------------------------------------------------------------
    // 4. 图案选择：KEY4 上一个 / KEY5 下一个
    //    （键位分配遵循 ai_handover 规范：不得与其他模块复用同一按键）
    // -------------------------------------------------------------------------
    reg [2:0] pattern_sel;
    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n)
            pattern_sel <= 3'd0;
        else if (key_event && (key_code == 4'd4))
            pattern_sel <= pattern_sel - 3'd1;      // KEY4 上一图案
        else if (key_event && (key_code == 4'd5))
            pattern_sel <= pattern_sel + 3'd1;      // KEY5 下一图案
    end

    // -------------------------------------------------------------------------
    // 5. 视频时序 → 测试图（RGB888）
    // -------------------------------------------------------------------------
    wire        hs, vs, de;
    wire [10:0] active_x;
    wire [9:0]  active_y;
    wire        frame_start;                // 帧起始脉冲（预留给阶段四帧缓存）

    video_timing_gen u_vtg (
        .pixel_clk   (clk_pixel),
        .rst_n       (rst_n),
        .hs          (hs),
        .vs          (vs),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .frame_start (frame_start)
    );

    wire [7:0] pr, pg, pb;

    test_pattern_gen #(
        .H_ACTIVE (11'd640),
        .V_ACTIVE (10'd480)
    ) u_pat (
        .pixel_clk   (clk_pixel),
        .rst_n       (rst_n),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .pattern_sel (pattern_sel),
        .user_color  (24'h00_00_00),        // 纯色模式用黑色（阶段五接状态叠加）
        .rgb_r       (pr),
        .rgb_g       (pg),
        .rgb_b       (pb)
    );

    // -------------------------------------------------------------------------
    // 6. HDMI TMDS 发送（官方 DVITransmitter 核，经 hdmi_tx.vhd 封装）
    //    注: RST_N 为低有效（官方 hdmi_tx_display.v 中恒接 0 = 不复位）
    // -------------------------------------------------------------------------
    hdmi_tx #(
        .FAMILY ("EG4")
    ) u_hdmi (
        .PXLCLK_I    (clk_pixel),
        .PXLCLK_5X_I (clk_5x),
        .RST_N       (rst_n),
        .VGA_HS      (hs),
        .VGA_VS      (vs),
        .VGA_DE      (de),
        .VGA_RGB     ({pr, pg, pb}),
        .HDMI_CLK_P  (HDMI_CLK_P),
        .HDMI_D2_P   (HDMI_D2_P),
        .HDMI_D1_P   (HDMI_D1_P),
        .HDMI_D0_P   (HDMI_D0_P)
    );

    // -------------------------------------------------------------------------
    // 7. 数码管：最右位显示当前图案号（其余位熄灭）
    //    段码为低电平点亮 → 8'hFF 表示全灭
    // -------------------------------------------------------------------------
    wire [6:0] seg_pat;
    seg_decoder u_dec_pat (
        .bin_data ({1'b0, pattern_sel}),
        .seg_data (seg_pat)
    );

    seg_scan4 #(
        .CLK_FREQ_HZ (25_000_000),
        .SCAN_HZ     (1000)
    ) u_seg (
        .clk      (clk_pixel),
        .rst_n    (rst_n),
        .dig0     ({1'b1, seg_pat}),        // 最右位: 图案号（DP 灭）
        .dig1     (8'hFF),                  // 以下三位熄灭
        .dig2     (8'hFF),
        .dig3     (8'hFF),
        .seg_data (seg_data),
        .seg_cs   (seg_cs)
    );

    // -------------------------------------------------------------------------
    // 8. LED：bit7~5 = 图案号, bit4 = PLL 锁定指示（现场调试关键）, 低 4 位备用
    // -------------------------------------------------------------------------
    assign led = {pattern_sel, locked, 4'b0000};

    // -------------------------------------------------------------------------
    // 9. 蜂鸣器：按键提示音（C5≈523Hz, 100ms）
    // -------------------------------------------------------------------------
    buzzer_tone #(
        .CLK_FREQ_HZ (25_000_000)
    ) u_buzz (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .tone_sel   (2'd1),                 // 按键音模式
        .trig       (key_event),
        .buzzer_out (buzzer)
    );

endmodule
