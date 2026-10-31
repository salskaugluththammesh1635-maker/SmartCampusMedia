// =============================================================================
// test_pattern_gen.v — 多模式测试图发生器
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 视频层（像素数据源）
//   工程归属 : project/hdmi_td.al（被 dmz_eg4s20_hdmi_top.v 例化为 u_pat）
//   数据流位置:
//       video_timing_gen ──→ de（数据有效）+ active_x/active_y（像素坐标）
//            ↓
//       【本模块】──→ rgb_r/g/b[7:0]（24 位 RGB888 像素）
//            ↓
//       hdmi_tx → TMDS 编码 → 显示器
//   为什么需要它:
//     视频通路接好后，必须先有一个**确定已知**的画面来验证链路是否正常 ——
//     否则显示器不亮时无法判断是"时序错"还是"数据错"。本模块提供 8 种
//     判据明确的测试图，每一种针对特定故障模式（详见下方图案表）。
//     在阶段四接入 SD 卡真实图片之前，它是唯一的像素来源。
//
// 【二、本模块功能】
//   一句话职责: 根据当前像素坐标与图案编号，组合译码出该像素的 RGB 颜色。
//   关键特性:
//     - **纯组合输出**（always @(*)）：与 de/坐标严格同拍，无相位偏移
//     - 8 种图案，每一种都有明确的"看什么"判据
//     - 分辨率全参数化（H_ACTIVE/V_ACTIVE），图案随分辨率自动适配
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  pixel_clk   : 像素时钟 25MHz（本模块仅"移动方块"用到）
//     输入  rst_n       : 低有效复位
//     输入  de          : 数据有效（0 = 消隐期，输出强制为黑）
//     输入  active_x/y  : 有效区内像素坐标（0~639 / 0~479）
//     输入  pattern_sel : 图案编号 0~7
//     输入  user_color  : 24 位注入色（图案 5 纯色模式使用，便于观察内部状态）
//     输出  rgb_r/g/b   : 24 位 RGB888 像素输出（组合逻辑）
//
//   内部逻辑块（共 4 块）:
//     [1] 移动方块位置更新   always @(posedge pixel_clk)   ← 唯一的时序块
//           功能: 在每帧最后一个像素处更新方块坐标（每 60 帧移动一步），
//                 触到边界时反转移动方向
//           输入: de, active_x/y       输出: box_x, box_y, box_dx, box_dy
//     [2] 彩条分带索引       assign（组合）
//           功能: 用比较链把 active_x 分成 8 段（每段 80 像素宽）
//           输入: active_x             输出: bar_idx[2:0]
//     [3] 方块命中判定       assign（组合）
//           功能: 判断当前像素是否落在移动方块矩形内
//           输入: active_x/y, box_x/y  输出: in_box
//     [4] 图案组合译码       always @(*)   ← 8 种图案的核心
//           功能: 依 pattern_sel 与像素坐标译码出 RGB；de=0 时输出黑
//           输入: de, active_x/y, pattern_sel, user_color, bar_idx, in_box
//           输出: rgb_r, rgb_g, rgb_b
//
//   【8 种图案与各自的故障判据】
//     0 八色彩条 : 白黄青绿品红红蓝黑 —— 颜色错乱 = TMDS 三通道映射错
//     1 64px 网格: 10 条竖线 + 7 条横线 —— 线条歪斜/偏移 = 行列计数错位
//     2 R 渐变   : 只有红色横向渐变      —— 单独确认红通道
//     3 G 渐变   : 只有绿色横向渐变      —— 单独确认绿通道
//     4 B 渐变   : 只有蓝色横向渐变      —— 单独确认蓝通道
//     5 纯色     : 颜色由 user_color 注入 —— 观察内部状态变量的"可视化窗口"
//     6 移动方块 : 绿块在深蓝底上往复     —— 画面撕裂/丢帧（静态图看不出）
//     7 棋盘格   : 16×16 白黑相间         —— 像素时钟抖动与采样点偏移
//
// 【四、设计思路与范式】
//   主要范式 : 组合译码（Combinational Decode）—— 本项目规模最大的组合译码
//   次要范式 : 慢节拍状态（仅"移动方块"图案需要状态，且每帧只更新一次）
//   为什么这样写:
//     1) **为什么像素输出必须用组合逻辑**: 像素数据必须与本拍的 de/坐标
//        **同拍**出现。若在这里再寄存一拍，整幅图会向右偏移 1 个像素
//        —— 这是本项目早期踩过的相位 bug（已修复并记入 docs/progress.md）
//     2) **为什么用比较链而不是除法**: `active_x / 80` 会综合出除法器（很费
//        资源）；用 8 级比较链只需几个 LUT，且组合路径更短
//     3) **为什么"移动方块"要单独用状态**: 其余 7 种图案都是"坐标 → 颜色"的
//        纯映射（无记忆），唯有移动方块需要记住"现在在哪、往哪走"
//   关键写法要点:
//     - 组合块内只用 `=`；**开头必须先给默认值**（本例先赋黑色），
//       这样 de=0 与未列举情况都能落到安全值，避免综合出锁存器
//     - case 必须有 default 分支（同上理由）
//     - 慢节拍状态更新用"帧末单点触发"（`de && last_pixel`），
//       避免在像素流里做复杂运算
//   范式认读方法: 见 docs/design_patterns.md
// =============================================================================
`timescale 1ns / 1ps

module test_pattern_gen #(
    parameter H_ACTIVE = 11'd640,   // 横向有效像素数（= 分辨率宽度）。作用: 彩条分带、
                                    //   渐变范围、网格间距都以它为基准计算。
                                    //   ⚠️ 必须与 video_timing_gen 的同名参数一致，
                                    //      否则图案会与画面区域错位（图案画到消隐区里）
    parameter V_ACTIVE = 10'd480    // 纵向有效行数（= 分辨率高度）。作用: 同上，用于纵向图案计算
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
    localparam [10:0] BOX_SIZE = 11'd64;
    //   ↑ 作用: "移动方块"图案中方块的边长（像素）。
    //     取 64 与 640×480 相称（约占画面 1/10 宽）—— 既能看清，又能明显观察到移动
    //     改这个值会同时改变方块的尺寸与它的移动步长（两者共用此常量）
    reg [6:0]  frame_cnt;                   // 帧计数：0~59
    reg [10:0] box_x, box_y;                // 方块左上角坐标
    reg        box_dx, box_dy;              // 移动方向：1 = 正向（坐标增大）

    // 一帧的最后一个有效像素（640×480 的右下角）
    wire last_pixel = (active_x == H_ACTIVE - 1) && (active_y == V_ACTIVE - 1);

    // ============ always 块 ① / 共 2 块: 移动方块位置更新 ============
    // 功能: 在每帧的最后一个像素处更新方块坐标（每 60 帧移动一步，约 1 秒），
    //       并在触到边界时反转移动方向，形成往复运动
    // 输入: pixel_clk, rst_n, de, active_x/y
    // 输出: frame_cnt, box_x, box_y, box_dx, box_dy
    // 说明: ① 这是本模块**唯一的时序块**——其余 7 种图案都是"坐标→颜色"的纯映射
    //       ② 选择"帧末单点更新"而非逐像素计算，避免在像素流里做复杂运算
    //          （步长 64 像素恰好是 8 色彩条的带宽，也是刻意对齐的）
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
                // 因为判据看的是更新前的值，回程到达 0 的那一步必须用 <= 而不是 ==：
                // box_x 由 BOX_SIZE 减到 0 时，更新前的值是 BOX_SIZE（不等于 0），
                // 若只判 ==0 就不会翻回正向，下一步执行 0 - BOX_SIZE 在 11 位
                // 无符号下溢成 1984，方块飞出画面。
                if ((box_x + BOX_SIZE) >= (H_ACTIVE - BOX_SIZE)) box_dx <= 1'b0;
                else if (box_x <= BOX_SIZE)                      box_dx <= 1'b1;
                // ---- Y 方向往返（同理）----
                if (box_dy) box_y <= box_y + BOX_SIZE;
                else        box_y <= box_y - BOX_SIZE;
                if ((box_y + BOX_SIZE) >= (V_ACTIVE - BOX_SIZE)) box_dy <= 1'b0;
                else if (box_y <= BOX_SIZE)                      box_dy <= 1'b1;
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
