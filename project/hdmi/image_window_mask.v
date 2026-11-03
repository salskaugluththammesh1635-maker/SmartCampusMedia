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
//        绝对坐标（不是行内偏移）。
//
//  【v2 t7：两组窗口必须同时满足，缺一就会漏残影】
//   本模块有两个互相独立的矩形，判决是两者的**交集**：
//     ① win_*  —— Key9 屏占比档位窗口（ratio_map 查表）。它回答「这一档允许
//        显示屏幕上的哪一块」，是**显示侧**的裁切范围。
//     ② img_*  —— 本次装载图像自己的 letterbox 窗口（image_player 的 out_*，
//        即 display_*，与 front_sel 同拍提交）。它回答「帧缓存里真正被写过
//        像素的是哪一块」，是**写入侧**的几何。
//   只留 ①：源图小于 640×480 时，img_scaler 只写了居中那一小块，四周仍是
//   上一张图的旧数据，而 Key9 满屏档放行全屏 ⇒ 用户看到「一堆黑边 + 残影」。
//   这正是 t7-B 把 win_* 从 img_scaler.out_* 改接 ratio_map 之后丢掉的职责
//   —— 不是接错，是语义切换时漏了「写入侧几何」这一半，本版补回。
//   只留 ②：Key9 五档全部失效（窗口外的图像会重新露出来）。
//   ★ 两者都取半开区间，且上界一律用加法：窗口尺寸为 0（尚未配置）时减法会
//     回绕成 off-1，反而把一整片判成窗口内。img_w 为 0 表示「还没有提交过任何
//     帧」，此时 in_img 恒假 —— 画面保持黑色，与上电初始状态一致。
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
    // 写入侧几何：img_scaler 本次实际写入帧缓存的矩形（来自 image_player 的
    // out_*，即 display_*）。与上面 win_* 是**交集**关系，见文件头说明。
    input  wire [15:0]          img_w,
    input  wire [15:0]          img_h,
    input  wire [15:0]          img_off_x,
    input  wire [15:0]          img_off_y,
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
    // 写入侧矩形：同样的半开区间与加法上界。
    wire [16:0] img_x_end = {1'b0, img_off_x} + {1'b0, img_w};
    wire [16:0] img_y_end = {1'b0, img_off_y} + {1'b0, img_h};
    wire in_image = (x_now >= img_off_x) && ({1'b0, x_now} < img_x_end) &&
                    (y_now >= img_off_y) && ({1'b0, y_now} < img_y_end);
    // 交集：只有「Key9 允许显示」且「帧缓存这一块真被写过」的像素才放行。
    assign pixel_valid_out = de && pixel_valid && in_window && in_image;
endmodule
