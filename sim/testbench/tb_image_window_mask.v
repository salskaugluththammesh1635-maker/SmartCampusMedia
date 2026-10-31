`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
//  image_window_mask 单元测试
// ---------------------------------------------------------------------------
//  验证重点（都是靠肉眼上板才发现得了的边界）：
//   ① 窗口四边界：左/上含、右/下不含（半开区间，不能多一行一列也不能少）
//   ② 窗口外必须拉低 pixel_valid —— 这正是"残影"的唯一防线
//   ③ win_w/win_h 为 0（尚未配置）时不得把整屏判成窗口内
//   ④ de 为低时即使坐标落在窗口内也必须拉低
//   ⑤ 全屏窗口（1:1 且恰好铺满）等价于直通，不能误伤正常显示
// ---------------------------------------------------------------------------
module tb_image_window_mask;
    reg de = 1'b1;
    reg [10:0] active_x = 11'd0;
    reg [9:0]  active_y = 10'd0;
    reg [15:0] win_w = 16'd0, win_h = 16'd0, win_off_x = 16'd0, win_off_y = 16'd0;
    reg pixel_valid = 1'b1;
    wire pixel_valid_out;
    integer checks = 0;
    integer errors = 0;

    image_window_mask dut (
        .de(de), .active_x(active_x), .active_y(active_y),
        .win_w(win_w), .win_h(win_h),
        .win_off_x(win_off_x), .win_off_y(win_off_y),
        .pixel_valid(pixel_valid), .pixel_valid_out(pixel_valid_out));

    task expect_valid;
        input [10:0] x;
        input [9:0]  y;
        input        expected;
        input [8*72-1:0] label;
        begin
            active_x = x; active_y = y;
            #1;
            checks = checks + 1;
            if (pixel_valid_out !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s at (%0d,%0d) got=%b expected=%b",
                    label, x, y, pixel_valid_out, expected);
            end
        end
    endtask

    initial begin
        // ---- 640×480 容器，窗口 320×240 居中于 (160,120) ----
        win_w = 16'd320; win_h = 16'd240;
        win_off_x = 16'd160; win_off_y = 16'd120;
        expect_valid(11'd160, 10'd120, 1'b1, "top-left corner of the window is inside");
        expect_valid(11'd479, 10'd359, 1'b1, "bottom-right pixel of the window is inside");
        expect_valid(11'd159, 10'd120, 1'b0, "one pixel left of the window is masked");
        expect_valid(11'd160, 10'd119, 1'b0, "one pixel above the window is masked");
        expect_valid(11'd480, 10'd359, 1'b0, "one pixel right of the window is masked");
        expect_valid(11'd479, 10'd360, 1'b0, "one pixel below the window is masked");
        expect_valid(11'd0,   10'd0,   1'b0, "origin is outside a centred window");
        expect_valid(11'd639, 10'd479, 1'b0, "last screen pixel is outside a centred window");

        // ---- 1:1 铺满：等价直通 ----
        win_w = 16'd640; win_h = 16'd480;
        win_off_x = 16'd0; win_off_y = 16'd0;
        expect_valid(11'd0,   10'd0,   1'b1, "full-frame window passes the origin");
        expect_valid(11'd639, 10'd479, 1'b1, "full-frame window passes the last pixel");

        // ---- 尚未配置：宽高为 0 时一个像素都不能通过 ----
        win_w = 16'd0; win_h = 16'd0;
        win_off_x = 16'd160; win_off_y = 16'd120;
        expect_valid(11'd160, 10'd120, 1'b0, "unconfigured window masks the whole screen");
        expect_valid(11'd0,   10'd0,   1'b0, "unconfigured window masks the origin too");
        // 偏移为 0 且宽高为 0：减法式上界判据会回绕，这里必须仍然是全屏蔽。
        win_off_x = 16'd0; win_off_y = 16'd0;
        expect_valid(11'd0, 10'd0, 1'b0, "zero-size window at origin masks everything");

        // ---- de 门控 ----
        win_w = 16'd320; win_h = 16'd240;
        win_off_x = 16'd160; win_off_y = 16'd120;
        de = 1'b0;
        expect_valid(11'd200, 10'd200, 1'b0, "blanking suppresses an in-window pixel");
        de = 1'b1;

        // ---- pixel_valid 门控：坐标在窗口内但上游没有像素 ----
        pixel_valid = 1'b0;
        expect_valid(11'd200, 10'd200, 1'b0, "missing upstream pixel stays invalid inside the window");
        pixel_valid = 1'b1;
        expect_valid(11'd200, 10'd200, 1'b1, "valid upstream pixel passes inside the window");

        // ---- 贴边窗口：偏移 0，只占左上角 ----
        win_w = 16'd64; win_h = 16'd48;
        win_off_x = 16'd0; win_off_y = 16'd0;
        expect_valid(11'd0,  10'd0,  1'b1, "window at the origin includes its corner");
        expect_valid(11'd63, 10'd47, 1'b1, "window at the origin includes its last pixel");
        expect_valid(11'd64, 10'd47, 1'b0, "window at the origin stops at its width");
        expect_valid(11'd63, 10'd48, 1'b0, "window at the origin stops at its height");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: image_window_mask");
        else $display("CHECKS FAILED: image_window_mask");
        $finish;
    end
endmodule
