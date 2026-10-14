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

    // ---- 移动方块位置（8 种图案中唯一需要"状态"的图案）----
    // 思路: 在每帧的最后一个像素处更新一次方块位置，实现"每 60 帧移动一步"
    //       （约 1 秒一步），避免在像素流中插入除法/取模运算。
    localparam [10:0] BOX_SIZE = 11'd64;    // 方块边长 64 像素
    reg [6:0]  frame_cnt;                   // 帧计数：0~59
    reg [10:0] box_x, box_y;                // 方块左上角坐标
    reg        box_dx, box_dy;              // 移动方向：1 = 正向（坐标增大）

    // 一帧的最后一个有效像素（640×480 的右下角）
    wire last_pixel = (active_x == H_ACTIVE - 1) && (active_y == V_ACTIVE - 1);

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cnt <= 7'd0;
            box_x     <= 11'd0;
            box_y     <= 10'd0;
            box_dx    <= 1'b1;
            box_dy    <= 1'b1;
        end
        else if (de && last_pixel) begin        // 仅在帧末更新
            frame_cnt <= frame_cnt + 7'd1;
            if (frame_cnt == 7'd59) begin       // 每 60 帧（≈1 秒）移动一步
                frame_cnt <= 7'd0;
                // ---- X 方向往返（步长 64 像素）----
                if (box_dx) box_x <= box_x + BOX_SIZE;
                else        box_x <= box_x - BOX_SIZE;
                // 触到右边界则转向，回到左边界再转回来
                // （注意：这里比较的是"更新前"的 box_x，与上面的赋值同一拍生效）
                if ((box_x + BOX_SIZE) >= (H_ACTIVE - BOX_SIZE)) box_dx <= 1'b0;
                else if (box_x == 11'd0)                         box_dx <= 1'b1;
                // ---- Y 方向往返（同理）----
                if (box_dy) box_y <= box_y + BOX_SIZE;
                else        box_y <= box_y - BOX_SIZE;
                if ((box_y + BOX_SIZE) >= (V_ACTIVE - BOX_SIZE)) box_dy <= 1'b0;
                else if (box_y == 10'd0)                         box_dy <= 1'b1;
            end
        end
    end

    // ---- 8 色彩条的分带索引（用比较链代替除法，利于综合）----
    // 640 像素宽 ÷ 8 带 = 每带 80 像素；比较链避免除法器，资源更省
    wire [2:0] bar_idx;
    assign bar_idx = (active_x < 11'd80)  ? 3'd0 :
                     (active_x < 11'd160) ? 3'd1 :
                     (active_x < 11'd240) ? 3'd2 :
                     (active_x < 11'd320) ? 3'd3 :
                     (active_x < 11'd400) ? 3'd4 :
                     (active_x < 11'd480) ? 3'd5 :
                     (active_x < 11'd560) ? 3'd6 : 3'd7;

    // 当前像素是否落在移动方块内（供图案 6 使用）
    wire in_box = (active_x >= box_x) && (active_x < (box_x + BOX_SIZE)) &&
                  (active_y >= box_y) && (active_y < (box_y + BOX_SIZE));

    // ---- 组合译码输出 ----
    // ⚠️ 为什么用组合逻辑（always @(*)）而不是时序逻辑：
    //    像素数据必须与本拍的 de / active_x / active_y 严格同拍输出。
    //    若在这里再打一拍，整幅图会向右偏移 1 个像素（本项目早期踩过的相位 bug）。
    always @(*) begin
        rgb_r = 8'h00;      // 默认黑色：消隐期（de=0）与未定义图案都走这里，
        rgb_g = 8'h00;      // 保证消隐期 RGB 恒为 0（这是显示器正常锁定的前提）
        rgb_b = 8'h00;
        if (de) begin
            case (pattern_sel)
                // ---- 0: 8 色彩条（白 黄 青 绿 品红 红 蓝 黑，与官方 color_bar 一致）----
                // 用于快速判断三路 TMDS 通道是否接错（颜色错乱即通道映射错）
                3'd0: begin
                    case (bar_idx)
                        3'd0: begin rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'hFF; end  // 白
                        3'd1: begin rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'h00; end  // 黄
                        3'd2: begin rgb_r = 8'h00; rgb_g = 8'hFF; rgb_b = 8'hFF; end  // 青
                        3'd3: begin rgb_r = 8'h00; rgb_g = 8'hFF; rgb_b = 8'h00; end  // 绿
                        3'd4: begin rgb_r = 8'hFF; rgb_g = 8'h00; rgb_b = 8'hFF; end  // 品红
                        3'd5: begin rgb_r = 8'hFF; rgb_g = 8'h00; rgb_b = 8'h00; end  // 红
                        3'd6: begin rgb_r = 8'h00; rgb_g = 8'h00; rgb_b = 8'hFF; end  // 蓝
                        default: begin rgb_r = 8'h00; rgb_g = 8'h00; rgb_b = 8'h00; end // 黑
                    endcase
                end
                // ---- 1: 64×64 像素网格（白线黑底）----
                // 用途: 检查画面是否被正确裁切/缩放，以及行列计数是否对齐。
                // 判据: active_x 低 6 位或 active_y 低 6 位为 0 时画白线
                //       → 即 640/64 = 10 条竖线、480/64 = 7 条横线
                3'd1: begin
                    if ((active_x[5:0] == 6'd0) || (active_y[5:0] == 6'd0)) begin
                        rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'hFF;
                    end
                end
                // ---- 2/3/4: 单色横向渐变（分别只驱动 R / G / B）----
                // 用途: 单独确认每一路颜色通道的正常工作。
                // active_x[10:3] 取横坐标高 8 位 → 渐变从 0 到 79（约 31% 亮度）
                3'd2: rgb_r = {active_x[10:3]};
                3'd3: rgb_g = {active_x[10:3]};
                3'd4: rgb_b = {active_x[10:3]};
                // ---- 5: 纯色（颜色由外部 user_color 注入，便于观察内部状态变量）----
                3'd5: begin rgb_r = user_color[23:16];
                            rgb_g = user_color[15:8];
                            rgb_b = user_color[7:0]; end
                // ---- 6: 移动方块（绿块在深蓝背景上往复运动）----
                // 用途: 动态检查是否存在画面撕裂/闪烁/丢帧 —— 静态图看不出这类问题
                3'd6: begin
                    if (in_box) begin rgb_r = 8'h00; rgb_g = 8'hFF; rgb_b = 8'h00; end
                    else        begin rgb_r = 8'h00; rgb_g = 8'h00; rgb_b = 8'h20; end
                end
                // ---- 7: 16×16 像素棋盘格（白黑相间）----
                // 用途: 检查像素时钟抖动与采样点偏移（棋盘格最容易暴露抖动）
                // 判据: 横纵坐标第 4 位异或 → 每 16 像素翻转一次
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
