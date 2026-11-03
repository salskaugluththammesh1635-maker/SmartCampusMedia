`timescale 1ns / 1ps
// video_content_mux 的单元回归。
//
// 【v2 改写说明（2026-11-02，t7）】
//   本 tb 原先有两条断言在 v2 之下必然为红，它们测的是两个**已被裁决删除**的功能：
//     :68  expect_rgb(24'h08_20_40, "science mode selects its independent page")
//            —— 测"mode 1 选中一块独立的静态科普页 science_rgb"。
//               该端口已随 t16 裁定删除（科普改为视频流，与图库共用 SDRAM 读出通路）。
//     :71  expect_rgb(24'hFF_00_00, "emergency mode keeps highest priority")
//            —— 测"mode 2 输出整屏纯红"。
//               用户 m00664 裁决把纯红替换成 emerg_page 画的疏散图。
//   处理方式不是"把红了的断言注释掉"，而是**换成测新契约的断言**：
//     mode 1：测"进科普时如果视频首帧还没到，画面必须继续显示上一帧图库内容，
//             中间既不闪彩条（说明回落到了 pattern_rgb）也不闪黑（说明被清零）"。
//     mode 2：测"输出恒等于 emerg_page 的 rgb_out"，并且**额外一条断言证明它不是
//             纯红** —— 否则把 24'hFF_00_00 接回去这条也照样"通过"，等于白测。
module tb_video_content_mux;
    reg de = 1'b1;
    reg [1:0] mode = 2'd0;
    reg image_ready = 1'b1;
    reg image_ever_ready = 1'b1;
    reg image_pixel_valid = 1'b0;
    reg [23:0] image_rgb = 24'h12_34_56;
    reg [23:0] pattern_rgb = 24'hFF_FF_FF;
    // emerg_page 的输出在顶层是纯组合现算的，这里用一个"不是纯红也不是纯黑也不是
    // 彩条白"的固定值代表它，才能分辨出"mux 真的在透传 emerg_rgb"。
    reg [23:0] emerg_rgb = 24'h2A_6B_8C;
    wire [23:0] rgb_out;
    integer checks = 0;
    integer errors = 0;

    video_content_mux dut (
        .de(de), .mode(mode), .image_ready(image_ready),
        .image_ever_ready(image_ever_ready),
        .image_pixel_valid(image_pixel_valid), .image_rgb(image_rgb),
        .pattern_rgb(pattern_rgb), .emerg_rgb(emerg_rgb), .rgb_out(rgb_out));

    task expect_rgb;
        input [23:0] expected;
        input [8*100-1:0] label;
        begin
            #1;
            checks = checks + 1;
            if (rgb_out !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s got=%06h expected=%06h", label, rgb_out, expected);
            end else begin
                $display("PASS: %0s rgb=%06h", label, rgb_out);
            end
        end
    endtask

    // 不等式断言：专门用来防"把被替换掉的旧常量接回去也能通过"这种假阳性。
    task expect_not_rgb;
        input [23:0] forbidden;
        input [8*100-1:0] label;
        begin
            #1;
            checks = checks + 1;
            if (rgb_out === forbidden) begin
                errors = errors + 1;
                $display("FAIL: %0s rgb=%06h must NOT equal %06h", label, rgb_out, forbidden);
            end else begin
                $display("PASS: %0s rgb=%06h != %06h", label, rgb_out, forbidden);
            end
        end
    endtask

    initial begin
        // ================= 日常模式（mode 0）的既有行为，全部保留 =============
        // Exact white-leak trigger: the new frame is committed, but a pixel
        // is temporarily invalid while the white color-bar fallback is active.
        expect_rgb(24'h00_00_00, "ready image with invalid pixel must suppress white pattern");

        image_pixel_valid = 1'b1;
        expect_rgb(24'h12_34_56, "valid gallery pixel is selected");

        // ---- 关键回归：显示过图之后 image_ready 掉落，必须出黑而不是彩条 ----
        // 现场现象（KEY0/KEY1 切图时竖向白色碎条）就出在这里：pattern_sel 复位
        // 为 0，八色彩条第 0 条是纯白 24'hFF_FFFF，占 x∈[0,79]，正好是一条
        // 80 像素宽的竖向白条。image_ready 被存储故障清零的那几帧就闪白条。
        image_ready = 1'b0;
        image_ever_ready = 1'b1;
        image_pixel_valid = 1'b0;
        expect_rgb(24'h00_00_00, "ready-then-dropped image must show black, never white pattern");
        image_pixel_valid = 1'b1;
        expect_rgb(24'h00_00_00, "dropped image must not leak stale gallery pixels either");

        mode = 2'd3;
        expect_rgb(24'h00_00_00, "reserved mode after first frame also suppresses the pattern");

        // ---- 上电首次出图前：测试彩条仍然允许显示（保留原行为）----
        mode = 2'd0;
        image_ever_ready = 1'b0;
        image_ready = 1'b0;
        image_pixel_valid = 1'b0;
        expect_rgb(24'hFF_FF_FF, "test pattern is still used before any image has ever been shown");
        image_pixel_valid = 1'b1;
        expect_rgb(24'hFF_FF_FF, "uncommitted image data cannot replace the test pattern");

        // ================= mode 1：科普视频（与图库共用通路）=================
        // 【契约】mode 1 在 content_mux 里**没有独立分支**，它落进 default，与日常
        //   完全同构：帧缓存里已有完整帧就显示它，没有就按 image_ever_ready 兜底。
        //   这是"科普视频写入同一块帧缓存"这一架构决策的直接体现。
        //
        // 场景 A：刚按 Key2 进科普、视频首帧还没解出来（disp_mode 仍是 0，
        //         顶层此时还在显示图库的最后一帧）。要求：画面停在图库内容上，
        //         **既不闪彩条也不闪黑** —— 这正是 ARCH §5.2「零闪黑」的验收点。
        mode = 2'd1;
        image_ready = 1'b1;
        image_ever_ready = 1'b1;
        image_pixel_valid = 1'b1;
        image_rgb = 24'h12_34_56;
        expect_rgb(24'h12_34_56, "mode 1 before first video frame keeps showing gallery content (no pattern, no black)");
        expect_not_rgb(24'hFF_FF_FF, "mode 1 wait state must NOT fall back to the test pattern");
        expect_not_rgb(24'h00_00_00, "mode 1 wait state must NOT blank to black");

        // 场景 B：视频首帧已写进帧缓存，走同一条读出通路出像素。
        image_rgb = 24'h5A_5A_5A;
        expect_rgb(24'h5A_5A_5A, "mode 1 video frame is read out through the same gallery path");

        // 场景 C：科普模式下若帧缓存失效（rle 断流/退帧），仍是黑而不是彩条 ——
        //         与日常模式的"显示过图之后不许回落彩条"同一条规则。
        image_ready = 1'b0;
        image_pixel_valid = 1'b0;
        expect_rgb(24'h00_00_00, "mode 1 after a shown frame must show black on underflow, never the pattern");
        image_rgb = 24'h12_34_56;
        image_ready = 1'b1;
        image_pixel_valid = 1'b1;

        // ================= mode 2：应急疏散图 =================================
        // 【契约】mode 2 不看 image_ready / image_pixel_valid / image_ever_ready，
        //   恒透传 emerg_rgb —— 应急图是纯组合现算，不依赖 SD/SDRAM。
        mode = 2'd2;
        expect_rgb(24'h2A_6B_8C, "emergency mode passes emerg_page output straight through");

        // ★ 防退化：旧实现是整屏纯红。若有人把 24'hFF_00_00 接回去，上面那条
        //   （用 2A_6B_8C 做期望值）会红；这一条是第二道保险 —— 即使有人把
        //   期望值也一起改成纯红，这条仍会拦住"应急页退化成纯红"。
        expect_not_rgb(24'hFF_00_00, "emergency mode must NOT be the legacy solid-red screen");

        // 应急优先级最高：即使图库/视频这边一切正常，也不能盖掉疏散图。
        image_ready = 1'b1;
        image_ever_ready = 1'b1;
        image_pixel_valid = 1'b1;
        image_rgb = 24'h12_34_56;
        expect_rgb(24'h2A_6B_8C, "emergency mode keeps highest priority over a fully valid image path");

        // 应急图内容本身在变（active_x/active_y 变化会改变 emerg_rgb）：必须跟着变，
        // 证明是透传而不是被锁存成某个值。
        emerg_rgb = 24'hC0_10_20;
        expect_rgb(24'hC0_10_20, "emergency mode tracks emerg_page per-pixel changes");

        // ================= 消隐 ==============================================
        mode = 2'd0;
        de = 1'b0;
        expect_rgb(24'h00_00_00, "blanking always outputs black");

        // 消隐在应急模式下也必须是黑（否则会带出 emerg 图的残行）。
        mode = 2'd2;
        expect_rgb(24'h00_00_00, "blanking suppresses the emergency page too");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: video_content_mux");
        else $display("CHECKS FAILED: video_content_mux");
        $finish;
    end
endmodule
