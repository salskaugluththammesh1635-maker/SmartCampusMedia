// =============================================================================
// test_pattern_gen.v
// 功能: 多模式测试图发生器（彩条/网格/渐变/纯色/移动方块/棋盘）
// 关键设计: 像素输出为【组合逻辑】, 由 de/active_x/active_y 直接译码
//           → 与 video_timing_gen 的 de/坐标严格同拍对齐（无 1 像素相位差）
// 说明: 图案与官方 lab_ex5_i2s color_bar.v 的 8 色一致; 其余图案为自研扩展,
//       用于无 SDRAM 阶段的视频链路自检与现场目检
// =============================================================================
`timescale 1ns / 1ps

module test_pattern_gen #(
    parameter H_ACTIVE = 11'd640,
    parameter V_ACTIVE = 10'd480
)(
    input  wire        pixel_clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [10:0] active_x,
    input  wire [9:0]  active_y,
    input  wire [2:0]  pattern_sel,
    input  wire [23:0] user_color,
    output reg  [7:0]  rgb_r,
    output reg  [7:0]  rgb_g,
    output reg  [7:0]  rgb_b
);

    // ---- 移动方块位置（唯一需要时序状态的图案）----
    localparam [10:0] BOX_SIZE = 11'd64;
    reg [6:0]  frame_cnt;
    reg [10:0] box_x, box_y;
    reg        box_dx, box_dy;

    wire last_pixel = (active_x == H_ACTIVE - 1) && (active_y == V_ACTIVE - 1);

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cnt <= 7'd0;
            box_x     <= 11'd0;
            box_y     <= 10'd0;
            box_dx    <= 1'b1;
            box_dy    <= 1'b1;
        end
        else if (de && last_pixel) begin
            frame_cnt <= frame_cnt + 7'd1;
            if (frame_cnt == 7'd59) begin
                frame_cnt <= 7'd0;
                // X 方向往返
                if (box_dx) box_x <= box_x + BOX_SIZE;
                else        box_x <= box_x - BOX_SIZE;
                if ((box_x + BOX_SIZE) >= (H_ACTIVE - BOX_SIZE)) box_dx <= 1'b0;
                else if (box_x == 11'd0)                         box_dx <= 1'b1;
                // Y 方向往返
                if (box_dy) box_y <= box_y + BOX_SIZE;
                else        box_y <= box_y - BOX_SIZE;
                if ((box_y + BOX_SIZE) >= (V_ACTIVE - BOX_SIZE)) box_dy <= 1'b0;
                else if (box_y == 10'd0)                         box_dy <= 1'b1;
            end
        end
    end

    // ---- 8 彩条色带索引（比较链, 免除法, 利于综合）----
    wire [2:0] bar_idx;
    assign bar_idx = (active_x < 11'd80)  ? 3'd0 :
                     (active_x < 11'd160) ? 3'd1 :
                     (active_x < 11'd240) ? 3'd2 :
                     (active_x < 11'd320) ? 3'd3 :
                     (active_x < 11'd400) ? 3'd4 :
                     (active_x < 11'd480) ? 3'd5 :
                     (active_x < 11'd560) ? 3'd6 : 3'd7;

    wire in_box = (active_x >= box_x) && (active_x < (box_x + BOX_SIZE)) &&
                  (active_y >= box_y) && (active_y < (box_y + BOX_SIZE));

    // ---- 组合译码输出 ----
    always @(*) begin
        rgb_r = 8'h00;
        rgb_g = 8'h00;
        rgb_b = 8'h00;
        if (de) begin
            case (pattern_sel)
                // 0: 8 色彩条（白 黄 青 绿 品红 红 蓝 黑, 与官方 color_bar 一致）
                3'd0: begin
                    case (bar_idx)
                        3'd0: begin rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'hFF; end
                        3'd1: begin rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'h00; end
                        3'd2: begin rgb_r = 8'h00; rgb_g = 8'hFF; rgb_b = 8'hFF; end
                        3'd3: begin rgb_r = 8'h00; rgb_g = 8'hFF; rgb_b = 8'h00; end
                        3'd4: begin rgb_r = 8'hFF; rgb_g = 8'h00; rgb_b = 8'hFF; end
                        3'd5: begin rgb_r = 8'hFF; rgb_g = 8'h00; rgb_b = 8'h00; end
                        3'd6: begin rgb_r = 8'h00; rgb_g = 8'h00; rgb_b = 8'hFF; end
                        default: begin rgb_r = 8'h00; rgb_g = 8'h00; rgb_b = 8'h00; end
                    endcase
                end
                // 1: 64 像素网格（白线黑底）
                3'd1: begin
                    if ((active_x[5:0] == 6'd0) || (active_y[5:0] == 6'd0)) begin
                        rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'hFF;
                    end
                end
                // 2/3/4: 单色渐变（R/G/B）
                3'd2: rgb_r = {active_x[10:3]};
                3'd3: rgb_g = {active_x[10:3]};
                3'd4: rgb_b = {active_x[10:3]};
                // 5: 纯色（由 user_color 注入状态位, 便于调试观察）
                3'd5: begin rgb_r = user_color[23:16];
                            rgb_g = user_color[15:8];
                            rgb_b = user_color[7:0]; end
                // 6: 移动方块（动态验证显示通路无撕裂）
                3'd6: begin
                    if (in_box) begin rgb_r = 8'h00; rgb_g = 8'hFF; rgb_b = 8'h00; end
                    else        begin rgb_r = 8'h00; rgb_g = 8'h00; rgb_b = 8'h20; end
                end
                // 7: 16x16 棋盘格
                3'd7: begin
                    if (active_x[4] ^ active_y[4]) begin
                        rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'hFF;
                    end
                end
                default: begin rgb_r = 8'h00; rgb_g = 8'h00; rgb_b = 8'h00; end
            endcase
        end
    end

endmodule
