`timescale 1ns / 1ps
// fade_mixer 独立验证：B2 转场的像素缩放是纯组合公式，错了只会在上板时"看起来发暗"，
// 所以把两端的精确性与三通道独立性都变成可重跑的断言。
module tb_fade_mixer;
    reg [15:0] rgb_in = 16'h0000;
    reg [7:0] level = 8'hFF;
    wire [15:0] rgb_out;
    integer checks = 0;
    integer errors = 0;
    integer i;
    reg [4:0] r5;
    reg [5:0] g6;
    reg [4:0] b5;
    reg [4:0] r_exp;
    reg [5:0] g_exp;
    reg [4:0] b_exp;

    fade_mixer dut (.rgb_in(rgb_in), .level(level), .rgb_out(rgb_out));

    task expect_rgb;
        input [15:0] expected;
        input [8*100-1:0] label;
        begin
            #1;
            checks = checks + 1;
            if (rgb_out !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s got=%04h expected=%04h", label, rgb_out, expected);
            end else begin
                $display("PASS: %0s rgb=%04h", label, rgb_out);
            end
        end
    endtask

    initial begin
        // ---- F01 满档恒等：level=255 必须逐位还原，转场结束后画面不能有偏差 ----
        level = 8'hFF;
        rgb_in = 16'hFFFF; expect_rgb(16'hFFFF, "F01 level 255 keeps white exact");
        rgb_in = 16'h0000; expect_rgb(16'h0000, "F01 level 255 keeps black exact");
        rgb_in = 16'hF800; expect_rgb(16'hF800, "F01 level 255 keeps pure red exact");
        rgb_in = 16'h07E0; expect_rgb(16'h07E0, "F01 level 255 keeps pure green exact");
        rgb_in = 16'h001F; expect_rgb(16'h001F, "F01 level 255 keeps pure blue exact");
        rgb_in = 16'h8410; expect_rgb(16'h8410, "F01 level 255 keeps mixed value exact");

        // ---- F02 零档全黑：level=0 必须输出 0，不能残留暗色或串色 ----
        level = 8'h00;
        rgb_in = 16'hFFFF; expect_rgb(16'h0000, "F02 level 0 forces white to black");
        rgb_in = 16'hF800; expect_rgb(16'h0000, "F02 level 0 forces pure red to black");
        rgb_in = 16'h001F; expect_rgb(16'h0000, "F02 level 0 forces pure blue to black");
        rgb_in = 16'h8410; expect_rgb(16'h0000, "F02 level 0 forces mixed value to black");

        // ---- F03 通道独立：不能把 RGB565 当 16 位整数整体缩放 ----
        // 整体右移会把高位红通道压进低位蓝通道，红像素会变成蓝像素。
        level = 8'h80;
        rgb_in = 16'hF800;
        #1;
        checks = checks + 1;
        if (rgb_out[15:11] == 5'd0 || rgb_out[4:0] != 5'd0) begin
            errors = errors + 1;
            $display("FAIL: F03 half level bleeds the red channel into blue: %04h", rgb_out);
        end else $display("PASS: F03 half level keeps red in the red channel: %04h", rgb_out);

        // ---- F04 单调：同一像素随 level 增大而单调不减 ----
        rgb_in = 16'h8410;
        begin : monotonic
            reg [15:0] prev;
            reg [15:0] cur;
            integer bad;
            bad = 0;
            prev = 16'h0000;
            for (i = 0; i <= 255; i = i + 1) begin
                level = i[7:0];
                #1;
                cur = rgb_out;
                if (cur[15:11] < prev[15:11] || cur[10:5] < prev[10:5] || cur[4:0] < prev[4:0]) bad = bad + 1;
                prev = cur;
            end
            checks = checks + 1;
            if (bad != 0) begin
                errors = errors + 1;
                $display("FAIL: F04 brightness is not monotonic over 256 levels (%0d steps)", bad);
            end else $display("PASS: F04 brightness rises monotonically across all 256 levels");
        end

        // ---- F05 每通道按同一比例缩放：逐通道独立算期望值，覆盖全部 256 档 ----
        begin : channel_scaling
            integer bad;
            bad = 0;
            for (i = 0; i <= 255; i = i + 1) begin
                level = i[7:0];
                rgb_in = 16'hFFFF;
                #1;
                r5 = 5'd31;
                g6 = 6'd63;
                b5 = 5'd31;
                r_exp = (r5 * (i + 1)) >> 8;
                g_exp = (g6 * (i + 1)) >> 8;
                b_exp = (b5 * (i + 1)) >> 8;
                if (rgb_out !== {r_exp, g_exp, b_exp}) bad = bad + 1;
            end
            checks = checks + 1;
            if (bad != 0) begin
                errors = errors + 1;
                $display("FAIL: F05 channel scaling deviates from level+1 formula (%0d levels)", bad);
            end else $display("PASS: F05 every level matches the per-channel level+1 formula");
        end

        // ---- F06 中间档抽查：128 档约等于一半亮度 ----
        level = 8'h80;
        rgb_in = 16'hFFFF;
        #1;
        checks = checks + 1;
        if (rgb_out !== 16'h7BEF) begin
            errors = errors + 1;
            $display("FAIL: F06 half level should halve each channel, got %04h", rgb_out);
        end else $display("PASS: F06 half level halves each channel: %04h", rgb_out);

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: fade_mixer");
        else $display("CHECKS FAILED: fade_mixer");
        $finish;
    end
endmodule
