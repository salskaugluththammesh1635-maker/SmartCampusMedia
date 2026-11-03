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
//   ⑥ 【v2 t7】两组几何（Key9 档位窗口 win_* / 写入侧矩形 img_*）取交集：
//      Key9 满屏 + 源图小于屏幕时，必须只剩 img_* 那一块 —— 这是 t7-B 之后
//      丢掉的职责，也是「一堆黑边 + 残影」的直接成因，必须由单元测试钉死。
// ---------------------------------------------------------------------------
module tb_image_window_mask;
    reg de = 1'b1;
    reg [10:0] active_x = 11'd0;
    reg [9:0]  active_y = 10'd0;
    reg [15:0] win_w = 16'd0, win_h = 16'd0, win_off_x = 16'd0, win_off_y = 16'd0;
    // 写入侧矩形。默认给满屏（640×480 @ 0,0），这样下面第 ①~⑤ 组断言只受
    // win_* 影响，与前版本逐条等价；第 ⑥ 组再单独改这组值验证交集语义。
    reg [15:0] img_w = 16'd640, img_h = 16'd480, img_off_x = 16'd0, img_off_y = 16'd0;
    reg pixel_valid = 1'b1;
    wire pixel_valid_out;
    integer checks = 0;
    integer errors = 0;

    image_window_mask dut (
        .de(de), .active_x(active_x), .active_y(active_y),
        .win_w(win_w), .win_h(win_h),
        .win_off_x(win_off_x), .win_off_y(win_off_y),
        .img_w(img_w), .img_h(img_h),
        .img_off_x(img_off_x), .img_off_y(img_off_y),
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

        // ------------------------------------------------------------------
        //  ⑥ 【v2 t7】两组几何取交集 —— 这一组是本次改动的核心，缺了它
        //     「Key9 满屏 + 小图」的残影就没人拦得住。
        // ------------------------------------------------------------------
        // 6.1 Key9 满屏（win = 640×480@0,0）+ 源图 320×240 居中（img = 320×240@160,120）
        //     ⇒ 只有 img 那一块放行，四周补黑。这正是用户看到的「一堆黑边」，
        //     改之前这些位置会被放行，露出上一张图的残影。
        win_w = 16'd640; win_h = 16'd480;
        win_off_x = 16'd0; win_off_y = 16'd0;
        img_w = 16'd320; img_h = 16'd240;
        img_off_x = 16'd160; img_off_y = 16'd120;
        expect_valid(11'd160, 10'd120, 1'b1, "small image: its top-left corner still passes");
        expect_valid(11'd479, 10'd359, 1'b1, "small image: its bottom-right pixel still passes");
        expect_valid(11'd159, 10'd120, 1'b0, "small image: letterbox left of it is masked");
        expect_valid(11'd480, 10'd359, 1'b0, "small image: letterbox right of it is masked");
        expect_valid(11'd160, 10'd119, 1'b0, "small image: letterbox above it is masked");
        expect_valid(11'd160, 10'd360, 1'b0, "small image: letterbox below it is masked");
        expect_valid(11'd0,   10'd0,   1'b0, "small image: screen origin is letterbox");
        expect_valid(11'd639, 10'd479, 1'b0, "small image: last screen pixel is letterbox");

        // 6.2 Key9 非满屏（320×240@160,120）+ 图像全幅（640×480@0,0）
        //     ⇒ 交集 = Key9 窗口，五档照常生效（证明没有把 t7-B 回退掉）。
        win_w = 16'd320; win_h = 16'd240;
        win_off_x = 16'd160; win_off_y = 16'd120;
        img_w = 16'd640; img_h = 16'd480;
        img_off_x = 16'd0; img_off_y = 16'd0;
        expect_valid(11'd160, 10'd120, 1'b1, "key9 window: its top-left corner passes");
        expect_valid(11'd479, 10'd359, 1'b1, "key9 window: its bottom-right pixel passes");
        expect_valid(11'd159, 10'd120, 1'b0, "key9 window: outside it is masked even if written");
        expect_valid(11'd480, 10'd359, 1'b0, "key9 window: right of it is masked even if written");

        // 6.3 两组窗口部分重叠：交集必须严格是重叠矩形（(200,150) 起 120×90）。
        win_w = 16'd320; win_h = 16'd240;
        win_off_x = 16'd160; win_off_y = 16'd120;   // → [160,480) × [120,360)
        img_w = 16'd320; img_h = 16'd240;
        img_off_x = 16'd200; img_off_y = 16'd150;   // → [200,520) × [150,390)
        expect_valid(11'd200, 10'd150, 1'b1, "overlap: first common pixel passes");
        expect_valid(11'd479, 10'd359, 1'b1, "overlap: last common pixel passes");
        expect_valid(11'd199, 10'd150, 1'b0, "overlap: left of the intersection is masked");
        expect_valid(11'd200, 10'd149, 1'b0, "overlap: above the intersection is masked");
        expect_valid(11'd480, 10'd359, 1'b0, "overlap: right of the intersection is masked");
        expect_valid(11'd479, 10'd360, 1'b0, "overlap: below the intersection is masked");

        // 6.4 两组窗口不相交：一个像素都不能放行（旧实现只判 win_* 会漏）。
        win_w = 16'd320; win_h = 16'd240;
        win_off_x = 16'd0; win_off_y = 16'd0;       // → [0,320) × [0,240)
        img_w = 16'd320; img_h = 16'd240;
        img_off_x = 16'd320; img_off_y = 16'd240;   // → [320,640) × [240,480)
        expect_valid(11'd0,   10'd0,   1'b0, "disjoint: win side alone must not pass");
        expect_valid(11'd319, 10'd239, 1'b0, "disjoint: win corner alone must not pass");
        expect_valid(11'd320, 10'd240, 1'b0, "disjoint: img corner alone must not pass");

        // 6.5 img_w=0（还没提交过任何帧）⇒ 全屏蔽，即使 Key9 满屏。
        //     上电后 image_ready 为 0 期间就是这一态：画面必须全黑而不是随机雪花。
        win_w = 16'd640; win_h = 16'd480;
        win_off_x = 16'd0; win_off_y = 16'd0;
        img_w = 16'd0; img_h = 16'd0;
        img_off_x = 16'd0; img_off_y = 16'd0;
        expect_valid(11'd0,   10'd0,   1'b0, "no committed frame yet masks the whole screen");
        expect_valid(11'd320, 10'd240, 1'b0, "no committed frame yet masks the centre too");

        // 6.6 【v2 t7】ext（科普视频）写口场景：写满整帧 ⇒ img_* = 640×480@(0,0)。
        //     此时 in_image 恒真，mask 必须**只**受 win_* 约束，一个像素都不能多裁。
        //     这条钉住的是 image_player 侧 disp_*_sel 的契约：ext_wr_mode=1 时
        //     display_* 必须取满帧几何，而不是沿用最后一张 BMP 的 letterbox 矩形。
        //     反例（6.6b）用一张 400×300@(120,90) 的"上一张 BMP 窗口"来演示：
        //     若 image_player 漏掉那层选择，科普视频就会被裁进这块，四周补黑。
        img_w = 16'd640; img_h = 16'd480;
        img_off_x = 16'd0; img_off_y = 16'd0;
        win_w = 16'd640; win_h = 16'd480;
        win_off_x = 16'd0; win_off_y = 16'd0;
        expect_valid(11'd0,   10'd0,   1'b1, "ext full-frame write: top-left corner passes");
        expect_valid(11'd639, 10'd479, 1'b1, "ext full-frame write: bottom-right pixel passes");
        expect_valid(11'd0,   10'd479, 1'b1, "ext full-frame write: bottom-left pixel passes");
        expect_valid(11'd639, 10'd0,   1'b1, "ext full-frame write: top-right pixel passes");
        // 6.6b Key9 压到 320×240 时，视频只能显示中间一块（Key9 语义，不是缺陷）。
        win_w = 16'd320; win_h = 16'd240;
        win_off_x = 16'd160; win_off_y = 16'd120;
        expect_valid(11'd160, 10'd120, 1'b1, "ext + key9: key9 window corner still passes");
        expect_valid(11'd159, 10'd120, 1'b0, "ext + key9: outside the key9 window is masked");
        // 6.6c 反例：若 img_* 被错留成 400×300@(120,90)，窗口外会被误裁。
        win_w = 16'd640; win_h = 16'd480;
        win_off_x = 16'd0; win_off_y = 16'd0;
        img_w = 16'd400; img_h = 16'd300;
        img_off_x = 16'd120; img_off_y = 16'd90;
        expect_valid(11'd0,   10'd0,   1'b0, "stale bmp geometry would crop the video (regression guard)");
        expect_valid(11'd119, 10'd240, 1'b0, "stale bmp geometry crops the left band");
        expect_valid(11'd120, 10'd90,  1'b1, "stale bmp geometry keeps only the bmp rect");
        // 复位回满屏，避免影响后续（本 tb 到此结束，写清楚以免将来加断言踩坑）。
        img_w = 16'd640; img_h = 16'd480;
        img_off_x = 16'd0; img_off_y = 16'd0;

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: image_window_mask");
        else $display("CHECKS FAILED: image_window_mask");
        $finish;
    end
endmodule
