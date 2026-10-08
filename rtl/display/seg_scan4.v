// =============================================================================
// seg_scan4.v
// 功能: 4 位七段数码管动态扫描驱动（DMZ-EG4S20 板级适配）
// 板级事实（来源: 走近FPGA 表1.4 + 核心板原理图p4 DIG 区 + 官方段码表交叉验证）:
//   4 位数码管, 8 段（含 DP）
//   段选 Digitron_Out[7:0]: **低电平点亮**（0=亮, 1=灭; 全 1 = 全灭）
//     依据: 官方 seg_decoder 段码 "0"→7'b100_0000（g 灭、其余亮）、"8"→7'b000_0000（全亮）
//           + 官方 seg_scan 未用位填 7'b111_1111（全灭）→ 印证低有效
//   ⚠️ 此结论修正了本文档早前"高电平点亮"的误记（详见 pending_confirmations 第 6 节）
//   位选 DigitronCS_Out[3:0]: 低电平选通
//   位序: COM0(最右)~COM3(最左), 输入 dig0~dig3 依次为 最右→最左
// 扫描频率: SCAN_HZ=1000 表示整轮 1kHz（每位 250us, 无可感闪烁）
// =============================================================================
`timescale 1ns / 1ps

module seg_scan4 #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter SCAN_HZ     = 1000          // 每位刷新率
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] dig0,              // 最右位段码 {DP,G,F,E,D,C,B,A}（含 DP 于 bit7）
    input  wire [7:0] dig1,
    input  wire [7:0] dig2,
    input  wire [7:0] dig3,              // 最左位
    output reg  [7:0] seg_data,          // 段选输出（高亮）
    output reg  [3:0] seg_cs             // 位选输出（低选通）: seg_cs[0]=COM0(最右)
);
    localparam SCAN_DIV = CLK_FREQ_HZ / (SCAN_HZ * 4) - 1;  // 4 位轮转

    reg [23:0] div_cnt;
    reg [1:0]  dig_idx;
    wire       scan_tick = (div_cnt == SCAN_DIV);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 24'd0;
            dig_idx <= 2'd0;
        end
        else if (scan_tick) begin
            div_cnt <= 24'd0;
            dig_idx <= dig_idx + 2'd1;
        end
        else
            div_cnt <= div_cnt + 24'd1;
    end

    // 输入排列: {dig3,dig2,dig1,dig0} = {最左,...,最右}
    // 输出排列: seg_cs[0]=COM0 最右位 ... seg_cs[3]=COM3 最左位
    //
    // 结构说明: 组合逻辑先算出 next 值, 时序逻辑统一寄存
    //   —— 避免同一变量在时序块内混用阻塞/非阻塞赋值
    //   （安路 TD 综合器对混用直接报 ERROR）
    reg [7:0] seg_data_nxt;
    reg [3:0] seg_cs_nxt;

    always @(*) begin
        seg_cs_nxt   = 4'b1111;            // 默认: 全部位选不选通
        seg_data_nxt = 8'hFF;              // 默认: 段全灭（低电平点亮 → 全 1 才是灭; 消影防重影）
        case (dig_idx)
            2'd0: begin seg_cs_nxt[0] = 1'b0; seg_data_nxt = dig0; end
            2'd1: begin seg_cs_nxt[1] = 1'b0; seg_data_nxt = dig1; end
            2'd2: begin seg_cs_nxt[2] = 1'b0; seg_data_nxt = dig2; end
            2'd3: begin seg_cs_nxt[3] = 1'b0; seg_data_nxt = dig3; end
            default: ;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_data <= 8'hFF;             // 复位全灭（低电平点亮, 全 1 = 灭）
            seg_cs   <= 4'b1111;           // 全不选通
        end
        else begin
            seg_data <= seg_data_nxt;
            seg_cs   <= seg_cs_nxt;
        end
    end

endmodule
