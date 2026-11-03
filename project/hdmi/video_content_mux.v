// Final pixel-source selection for the HDMI display.
// mode: 0 = gallery/日常, 1 = 科普视频（与日常共用图片读出通路）, 2 = 应急疏散图.
//
// 【v1 → v2 变化（t16 裁定 + 用户 m00664 裁决）】
//   v1：mode 0/3 = 图库, 1 = 内置静态科普页 science_rgb, 2 = 整屏纯红 24'hFF_00_00。
//   v2：
//     · 科普视频不走独立页面，它与图库共用同一条 SDRAM 读出通路
//       （rle_decoder 解出的帧由 image_player 的外部写口写进帧缓存，
//        再由 pix_reader 读出），所以 2'd1 与 default 合流 ——
//       image_ready / image_pixel_valid 对两者语义完全相同。
//     · 应急不再是一块纯红，改为 emerg_page 画的疏散图（带走廊/出口/当前位置）。
//       纯红屏只能表达"出事了"，说不出"往哪跑"，而后者才是应急页的目的。
//   净端口变化 0：删掉 science_rgb，加上 emerg_rgb。
//
// 【为什么 mode 位宽仍是 2 位、0/3 同义】
//   顶层 2'd3 从未被驱动（mode_ctrl 只出 0/1/2），保留 default 兜底即可，
//   不必为不存在的值加分支。
module video_content_mux (
    input  wire        de,
    input  wire [1:0]  mode,
    input  wire        image_ready,
    input  wire        image_ever_ready,
    input  wire        image_pixel_valid,
    input  wire [23:0] image_rgb,
    input  wire [23:0] pattern_rgb,
    input  wire [23:0] emerg_rgb,
    output reg  [23:0] rgb_out
);
    always @* begin
        rgb_out = 24'd0;
        if (de) begin
            case (mode)
                // 应急最高优先：不看 image_ready —— 应急图是纯组合现算的，
                // 不依赖 SD/SDRAM 是否就绪，这正是它"随时可用"的意义。
                2'd2: rgb_out = emerg_rgb;
                default: begin
                    // 日常与科普共用此分支：image_ready 成立表示帧缓存里
                    // 已有一帧完整图像（图库 BMP 或科普视频解出的帧）。
                    //
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
