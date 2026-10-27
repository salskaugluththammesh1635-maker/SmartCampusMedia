// =============================================================================
// video_rgb_to_axis.v —— 把 RGB + DE + VS 打包成 HDMI 发射核要的 AXIS 视频流
// -----------------------------------------------------------------------------
// 【为什么需要这一层】
//   本工程原来的视频路径是 DVI 风格：直接给 hdmi_tx 送 DE/HS/VS/RGB，控制信号
//   靠 TMDS 的 C0/C1 通道单独编码。带音频的 HDMI 1.4b 发射核换成了 AXIS 流：
//     I_axis_s_user  —— 帧起始，只在"第一行第一个有效像素"拉高一拍
//     I_axis_s_valid —— 数据有效（等于 DE）
//     I_axis_s_last  —— 行尾，每行第 640 个有效像素拉高一拍
//     I_axis_s_data  —— 24 bit RGB
//   核内部自己重建时序与信息包，所以这里只负责翻译控制信号，不碰时序参数。
//
// 【为什么 user/last 用"计数到边界"而不是"看 HS 边沿"】
//   核的 O_axis_s_ready 只会在 last 之后拉低（APUG092 文档：不支持断续输入，
//   一行必须连续）。如果 user/last 依赖 HS 边沿，一旦时序发生器相位变化就会
//   错一行，整帧对齐失败。用 DE 上升沿 + 像素计数则是自洽的：行首必然由 DE
//   上升沿定义，行尾必然由第 ACTIVE-1 个像素定义，与 HS 无关。
//
// 【S_frame_arm 的作用】
//   VS 翻转说明进入新的一帧，此时把 arm 置位；下一个行首才允许发 user。
//   这样保证"帧起始"只在整帧的第一行出现，而不是每个行首都出现。
// =============================================================================
`timescale 1ns / 1ps

module video_rgb_to_axis #(
    parameter H_ACTIVE = 640
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        vs,           // 场同步（本工程为负极性，这里只关心跳变）
    input  wire        de,           // 数据有效
    input  wire [23:0] rgb,
    output reg         video_user,   // 帧起始
    output reg         video_valid,  // 数据有效
    output reg         video_last,   // 行尾
    output reg  [23:0] video_data
);

    reg        vs_1d, de_1d;
    reg        frame_arm;
    reg [10:0] x_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_1d      <= 1'b0;
            de_1d      <= 1'b0;
            frame_arm  <= 1'b1;
            x_cnt      <= 11'd0;
            video_user <= 1'b0;
            video_valid <= 1'b0;
            video_last <= 1'b0;
            video_data <= 24'd0;
        end else begin
            vs_1d       <= vs;
            de_1d       <= de;
            video_valid <= de;          // valid 与数据同拍直通
            video_data  <= rgb;
            video_user  <= 1'b0;        // 默认单拍脉冲
            video_last  <= 1'b0;

            if (vs_1d != vs) frame_arm <= 1'b1;

            // x_cnt 的语义是"当前有效像素的 0 基下标"：
            //   消隐期间清零 → 行首那拍 x_cnt=0（第 1 个像素）→ 每拍 +1
            //   → 第 640 个像素那拍 x_cnt=639，正好用于判行尾。
            // 注意行首那拍也必须 +1（不能只清零），否则 last 会晚一拍落到
            // DE 已经拉低之后，核永远等不到行尾，整帧对齐失败。
            if (de) begin
                if (!de_1d && frame_arm) begin
                    video_user <= 1'b1;     // 整帧第一行的第一个有效像素
                    frame_arm  <= 1'b0;
                end
                x_cnt <= x_cnt + 1'b1;
                if (x_cnt == (H_ACTIVE - 1)) video_last <= 1'b1;
            end else begin
                x_cnt <= 11'd0;
            end
        end
    end

endmodule
