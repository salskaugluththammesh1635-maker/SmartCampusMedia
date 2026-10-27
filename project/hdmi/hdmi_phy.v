// =============================================================================
// hdmi_phy.v —— HDMI 1.4b 发射核的物理层：4 条通道并行串化
// -----------------------------------------------------------------------------
// 【职责边界】
//   上游（hdmi_1_4b_transmitter_core）在像素时钟域给出 4 组 10 bit TMDS 字：
//     ch0 = 蓝   ch1 = 绿   ch2 = 红   clk = 像素时钟本身（TMDS 时钟通道）
//   本模块把它们各串成一条 10 倍速低压差分对。D0/D1/D2/CLK 的对应关系必须与
//   hdmi_1_4b_transmitter_core 的命名一致，否则会出"图像偏色/分辨率不对"这类
//   难查的现象。
//
// 【位反序为什么放在这里】
//   发射核按 LSB-first 输出，而移位寄存器 MSB 先出。把 {in[0],...,in[9]} 的
//   倒序集中在这一层做，lane 模块就退化成纯"按序串化"，职责一分为二、各自可测。
//
// 【负端为什么不引出】
//   本板 HDMI 座的负端由 FPGA 差分对自动配对（LVDS33 的 N 端固定球号）。
//   约束文件里只写正端，工具会自动配对并生成负端 —— 这与原 DVI 核的做法一致，
//   已在 area.txt 的 IO 明细里得到印证（HDMI_*_P(n) 自动出现）。
// =============================================================================
`timescale 1ns / 1ps

module hdmi_phy (
    input  wire       I_pixel_clk,
    input  wire       I_serial_clk,
    input  wire       I_rst,          // 高有效（N 端已在本模块内部取反前给出）
    input  wire [9:0] I_tmds_ch0,     // 蓝
    input  wire [9:0] I_tmds_ch1,     // 绿
    input  wire [9:0] I_tmds_ch2,     // 红
    input  wire [9:0] I_tmds_clk,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p
);

    // 10 bit 全位反序（LSB-first → MSB-first）。
    wire [9:0] rev_ch0 = {I_tmds_ch0[0], I_tmds_ch0[1], I_tmds_ch0[2], I_tmds_ch0[3], I_tmds_ch0[4],
                          I_tmds_ch0[5], I_tmds_ch0[6], I_tmds_ch0[7], I_tmds_ch0[8], I_tmds_ch0[9]};
    wire [9:0] rev_ch1 = {I_tmds_ch1[0], I_tmds_ch1[1], I_tmds_ch1[2], I_tmds_ch1[3], I_tmds_ch1[4],
                          I_tmds_ch1[5], I_tmds_ch1[6], I_tmds_ch1[7], I_tmds_ch1[8], I_tmds_ch1[9]};
    wire [9:0] rev_ch2 = {I_tmds_ch2[0], I_tmds_ch2[1], I_tmds_ch2[2], I_tmds_ch2[3], I_tmds_ch2[4],
                          I_tmds_ch2[5], I_tmds_ch2[6], I_tmds_ch2[7], I_tmds_ch2[8], I_tmds_ch2[9]};
    wire [9:0] rev_clk = {I_tmds_clk[0], I_tmds_clk[1], I_tmds_clk[2], I_tmds_clk[3], I_tmds_clk[4],
                          I_tmds_clk[5], I_tmds_clk[6], I_tmds_clk[7], I_tmds_clk[8], I_tmds_clk[9]};

    lane_lvds_10_1 u_lane_ch0 (
        .I_pixel_clk (I_pixel_clk), .I_serial_clk (I_serial_clk), .I_rst (I_rst),
        .I_data_in (rev_ch0), .O_serial_out (O_tmds_ch0_p));

    lane_lvds_10_1 u_lane_ch1 (
        .I_pixel_clk (I_pixel_clk), .I_serial_clk (I_serial_clk), .I_rst (I_rst),
        .I_data_in (rev_ch1), .O_serial_out (O_tmds_ch1_p));

    lane_lvds_10_1 u_lane_ch2 (
        .I_pixel_clk (I_pixel_clk), .I_serial_clk (I_serial_clk), .I_rst (I_rst),
        .I_data_in (rev_ch2), .O_serial_out (O_tmds_ch2_p));

    lane_lvds_10_1 u_lane_clk (
        .I_pixel_clk (I_pixel_clk), .I_serial_clk (I_serial_clk), .I_rst (I_rst),
        .I_data_in (rev_clk), .O_serial_out (O_tmds_clk_p));

endmodule
