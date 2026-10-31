`timescale 1ns / 1ps
module tb_video_content_mux;
    reg de = 1'b1;
    reg [1:0] mode = 2'd0;
    reg image_ready = 1'b1;
    reg image_ever_ready = 1'b1;
    reg image_pixel_valid = 1'b0;
    reg [23:0] image_rgb = 24'h12_34_56;
    reg [23:0] pattern_rgb = 24'hFF_FF_FF;
    reg [23:0] science_rgb = 24'h08_20_40;
    wire [23:0] rgb_out;
    integer checks = 0;
    integer errors = 0;

    video_content_mux dut (
        .de(de), .mode(mode), .image_ready(image_ready),
        .image_ever_ready(image_ever_ready),
        .image_pixel_valid(image_pixel_valid), .image_rgb(image_rgb),
        .pattern_rgb(pattern_rgb), .science_rgb(science_rgb), .rgb_out(rgb_out));

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

    initial begin
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

        mode = 2'd1;
        expect_rgb(24'h08_20_40, "science mode selects its independent page");

        mode = 2'd2;
        expect_rgb(24'hFF_00_00, "emergency mode keeps highest priority");

        mode = 2'd0;
        de = 1'b0;
        expect_rgb(24'h00_00_00, "blanking always outputs black");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: video_content_mux");
        else $display("CHECKS FAILED: video_content_mux");
        $finish;
    end
endmodule
