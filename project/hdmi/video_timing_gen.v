// =============================================================================
// video_timing_gen.v
// 功能: 640x480@60Hz 视频时序发生器（hs/vs/de + 有效区像素坐标）
// 时序参数来源: 官方 lab_ex5_i2s/SD/color_bar.v L42-53（VIDEO_640_480, 已核实）
//   H: SYNC=96, BP=48, ACTIVE=640, FP=16   TOTAL=800
//   V: SYNC=2,  BP=33, ACTIVE=480, FP=10   TOTAL=525
//   HS/VS 负极性（VESA 标准, 与官方参数一致）
// 行内次序: [同步段][后沿][有效区][前沿]（标准次序; 与官方 color_bar 的
//           "FP 在行首"写法相位不同, 但段宽与总线数一致, 接收端可正常锁定）
// 对齐约定: de 与 active_x/active_y 同一拍寄存器输出; test_pattern_gen 为组合
//           逻辑 → 像素数据与该拍 de/坐标严格对齐（无 1 像素偏斜）
// =============================================================================
`timescale 1ns / 1ps

module video_timing_gen #(
    parameter H_ACTIVE = 11'd640,
    parameter H_FP     = 11'd16,
    parameter H_SYNC   = 11'd96,
    parameter H_BP     = 11'd48,
    parameter V_ACTIVE = 10'd480,
    parameter V_FP     = 10'd10,
    parameter V_SYNC   = 10'd2,
    parameter V_BP     = 10'd33,
    parameter HS_POL   = 1'b0,
    parameter VS_POL   = 1'b0
)(
    input  wire        pixel_clk,    // 像素时钟 25.175MHz（上板由 PLL 产生）
    input  wire        rst_n,        // 低有效复位
    output wire        hs,           // 行同步
    output wire        vs,           // 场同步
    output reg         de,           // 数据有效
    output reg  [10:0] active_x,     // 有效区 X 0~639
    output reg  [9:0]  active_y,     // 有效区 Y 0~479
    output reg         frame_start   // 帧起始单拍脉冲（有效区首行前）
);

    localparam H_TOTAL     = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
    localparam V_TOTAL     = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525
    localparam H_ACT_START = H_SYNC + H_BP;                     // 144
    localparam H_ACT_END   = H_ACT_START + H_ACTIVE;            // 784
    localparam V_ACT_START = V_SYNC + V_BP;                     // 35
    localparam V_ACT_END   = V_ACT_START + V_ACTIVE;            // 515

    reg [10:0] h_cnt;
    reg [9:0]  v_cnt;

    // 行计数
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n)
            h_cnt <= 11'd0;
        else if (h_cnt == H_TOTAL - 1)
            h_cnt <= 11'd0;
        else
            h_cnt <= h_cnt + 11'd1;
    end

    // 场计数（行末递增）
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n)
            v_cnt <= 10'd0;
        else if (h_cnt == H_TOTAL - 1)
            v_cnt <= (v_cnt == V_TOTAL - 1) ? 10'd0 : (v_cnt + 10'd1);
    end

    // 同步信号（组合译码, 段宽精确）
    wire h_sync_act = (h_cnt < H_SYNC);
    wire v_sync_act = (v_cnt < V_SYNC);
    assign hs = HS_POL ? h_sync_act : ~h_sync_act;
    assign vs = VS_POL ? v_sync_act : ~v_sync_act;

    // 有效区判定
    wire h_act = (h_cnt >= H_ACT_START) && (h_cnt < H_ACT_END);
    wire v_act = (v_cnt >= V_ACT_START) && (v_cnt < V_ACT_END);
    wire de_c  = h_act && v_act;

    // 输出寄存器（de / 坐标 / frame_start 同拍更新, 保证严格对齐）
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            de          <= 1'b0;
            active_x    <= 11'd0;
            active_y    <= 10'd0;
            frame_start <= 1'b0;
        end
        else begin
            de          <= de_c;
            active_x    <= de_c ? (h_cnt - H_ACT_START) : 11'd0;
            active_y    <= de_c ? (v_cnt - V_ACT_START) : 10'd0;
            // 帧起始脉冲: 在"有效区首行开始前"的最后一个像素位置发出
            // （即 v_cnt = V_ACT_START-1 的行末）。修复前用 V_ACT_START,
            //  实际落在有效区第一行的行末 —— 晚了一整行, 与注释语义不符。
            frame_start <= (v_cnt == V_ACT_START - 10'd1) && (h_cnt == H_TOTAL - 1);
        end
    end

endmodule
