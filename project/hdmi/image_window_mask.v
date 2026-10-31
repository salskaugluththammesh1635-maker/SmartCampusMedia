`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
//  缩放窗口屏蔽（letterbox）
// ---------------------------------------------------------------------------
//  背景：img_scaler 只输出目标窗口内的像素，帧缓存里窗口之外的区域**从不写入**，
//        那里保持上一张图的内容（或上电后的随机值）。若不屏蔽，缩小后的图片
//        四周会漏出前一张图的残影，上电首图则会漏出未初始化数据。
//
//  职责：按当前扫描坐标判断是否落在窗口内，落在窗口外就把 pixel_valid 拉低，
//        由下游 video_content_mux 的「无效像素输出黑色」规则补黑。
//        这样本模块不需要知道像素位宽，也不必改动 565→888 的扩展逻辑。
//
//  坐标：active_x/active_y 来自 video_timing_gen，与 de 同拍有效，是当前像素的
//        绝对坐标（不是行内偏移）。窗口参数来自 image_player 透传的缩放结果。
//
//  时序：纯组合，不增加像素延迟 —— 显示通路不能插寄存器。
// ---------------------------------------------------------------------------
module image_window_mask #(
    parameter X_WIDTH = 11,
    parameter Y_WIDTH = 10
) (
    input  wire                 de,
    input  wire [X_WIDTH-1:0]   active_x,
    input  wire [Y_WIDTH-1:0]   active_y,
    input  wire [15:0]          win_w,
    input  wire [15:0]          win_h,
    input  wire [15:0]          win_off_x,
    input  wire [15:0]          win_off_y,
    input  wire                 pixel_valid,
    output wire                 pixel_valid_out
);
    // 用 16 位上下文比较：active_x 最宽 11 位，窗口参数是 16 位，
    // 直接混用会让综合工具在窄侧补零的同时给出位宽告警。
    wire [15:0] x_now = {{(16-X_WIDTH){1'b0}}, active_x};
    wire [15:0] y_now = {{(16-Y_WIDTH){1'b0}}, active_y};
    // 上界用加法而不是减法：win_w 为 0（尚未配置）时，减法会得到
    // off_x-1 这种回绕值，反而把一整片区域判成窗口内。
    wire [16:0] x_end = {1'b0, win_off_x} + {1'b0, win_w};
    wire [16:0] y_end = {1'b0, win_off_y} + {1'b0, win_h};
    wire in_window = (x_now >= win_off_x) && ({1'b0, x_now} < x_end) &&
                     (y_now >= win_off_y) && ({1'b0, y_now} < y_end);
    assign pixel_valid_out = de && pixel_valid && in_window;
endmodule
