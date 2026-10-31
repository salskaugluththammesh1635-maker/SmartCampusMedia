// Final pixel-source selection for the HDMI display.
// mode: 0/3 = gallery, 1 = built-in science page, 2 = emergency red screen.
module video_content_mux (
    input  wire        de,
    input  wire [1:0]  mode,
    input  wire        image_ready,
    input  wire        image_ever_ready,
    input  wire        image_pixel_valid,
    input  wire [23:0] image_rgb,
    input  wire [23:0] pattern_rgb,
    input  wire [23:0] science_rgb,
    output reg  [23:0] rgb_out
);
    always @* begin
        rgb_out = 24'd0;
        if (de) begin
            case (mode)
                2'd2: rgb_out = 24'hFF_00_00;
                2'd1: rgb_out = science_rgb;
                default: begin
                    // A committed frame owns the source selection. During a
                    // short read-side underflow, black is safer than leaking
                    // a white test-pattern pixel into the new frame.
                    if (image_ready)
                        rgb_out = image_pixel_valid ? image_rgb : 24'd0;
                    else if (image_ever_ready)
                        // 曾经显示过图片后 image_ready 又掉下来（存储故障退帧、
                        // 重装载窗口）：绝不能回落到测试彩条 —— pattern_sel
                        // 复位为 0 是八色彩条，第 0 条正是纯白 24'hFF_FFFF，
                        // 上屏就是一条 80 像素宽的竖向白条。这里强制出黑。
                        rgb_out = 24'd0;
                    else
                        rgb_out = pattern_rgb;
                end
            endcase
        end
    end
endmodule
