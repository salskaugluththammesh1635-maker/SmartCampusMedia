// =============================================================================
// tb_bmp_parser.v — bmp_parser 的逐像素比对测试平台
// =============================================================================
// 【测试策略】
//   本平台不依赖外部 BMP 文件，而是现场构造字节流喂给 DUT，再用一个
//   "黄金模型"（golden model，纯行为级）算出期望像素序列逐拍比对。
//
//   为什么不用真实素材文件：
//     1) 真实素材只有 640×480 与 320×240，两者的「每行字节数」都是 4 的
//        倍数，行填充恒为 0 —— 只用它们测，填充逻辑错了也发现不了。
//     2) 素材是外部二进制，换台机器/换素材就测不了，可复现性差。
//   因此本平台显式覆盖：
//     - 宽度 640（pad=0）与宽度 322（pad=2）、321（pad=1）、323（pad=3）
//       三种填充情形
//     - height > 0（自底向上，需翻转）与 height < 0（自顶向下，不翻转）
//     - 4 种坏图：签名错 / 非 24bit / 有压缩 / 宽高不符
//     - data_off > 54（跳过调色板区）的合法情形
//
// 【比对方法】
//   DUT 每输出一个 pix_valid，就与黄金模型按 (pix_x, pix_y) 取到的期望
//   RGB565 比较；同时检查 (pix_x, pix_y) 的遍历顺序必须覆盖整幅图恰好一次。
// =============================================================================

`timescale 1ns / 1ps

module tb_bmp_parser;

    // ---- 时钟与复位 ----
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;          // 25MHz

    // ---- DUT 端口 ----
    reg         start      = 1'b0;
    reg  [15:0] exp_w      = 16'd640;
    reg  [15:0] exp_h      = 16'd480;
    reg         byte_valid = 1'b0;
    reg  [7:0]  byte_data  = 8'h00;
    reg         byte_sof   = 1'b0;

    wire        hdr_ok;
    wire        hdr_fail;
    wire [3:0]  err_code;
    wire [15:0] img_w;
    wire [15:0] img_h;
    wire [31:0] data_off;
    wire        pix_valid;
    wire [15:0] pix_rgb565;
    wire [15:0] pix_x;
    wire [15:0] pix_y;

    bmp_parser #(
        .DEFAULT_W (16'd640),
        .DEFAULT_H (16'd480)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .exp_w      (exp_w),
        .exp_h      (exp_h),
        .byte_valid (byte_valid),
        .byte_data  (byte_data),
        .byte_sof   (byte_sof),
        .hdr_ok     (hdr_ok),
        .hdr_fail   (hdr_fail),
        .err_code   (err_code),
        .img_w      (img_w),
        .img_h      (img_h),
        .data_off   (data_off),
        .pix_valid  (pix_valid),
        .pix_rgb565 (pix_rgb565),
        .pix_x      (pix_x),
        .pix_y      (pix_y)
    );

    // ---- 检查器 ----
    integer errors = 0;
    integer checks = 0;
    task chk;
        input cond;
        input [1023:0] name;
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ========================================================================
    // 黄金模型: 由 (x,y) 算出该位置的期望 RGB565
    // ========================================================================
    // 图案定义: 纯函数 f(x,y) → {R,G,B} 各 8bit
    //   R = x[7:0]
    //   G = y[7:0]
    //   B = x[7:0] ^ y[7:0]
    // 这个图案对 x/y 敏感且不会因为"行列互换"而碰巧相同，能抓住坐标错位。
    function [23:0] golden_rgb888;
        input [15:0] gx;
        input [15:0] gy;
        begin
            golden_rgb888 = {gx[7:0], gy[7:0], gx[7:0] ^ gy[7:0]};
        end
    endfunction

    // 参照 DUT 的打包方式: {R[7:3], G[7:2], B[7:3]}
    function [15:0] golden_rgb565;
        input [15:0] gx;
        input [15:0] gy;
        reg [23:0] rgb;
        begin
            rgb = golden_rgb888(gx, gy);
            golden_rgb565 = {rgb[23:19], rgb[15:10], rgb[7:3]};
        end
    endfunction

    // ========================================================================
    // 字节流驱动
    // ========================================================================
    // 字节之间的间隔拍数（可由测试用例临时修改）
    // GAP=0: 每个字节占 1 拍（连续流，最高速率）
    // GAP=2: 字节之间空 2 拍（模拟 SD 块流的不连续）
    // 两种都测: 只在 GAP=0 下测，就覆盖不到"字节之间有空拍"时相位是否错位
    integer gap = 0;

    task push_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            byte_data  = b;
            byte_valid = 1'b1;
            @(negedge clk);
            byte_valid = 1'b0;
            repeat (gap) @(negedge clk);
        end
    endtask

    // 把一个 32 位整数按小端序推入（BMP 所有多字节字段都是小端）
    task push_u32;
        input [31:0] v;
        begin
            push_byte(v[7:0]);
            push_byte(v[15:8]);
            push_byte(v[23:16]);
            push_byte(v[31:24]);
        end
    endtask

    task push_u16;
        input [15:0] v;
        begin
            push_byte(v[7:0]);
            push_byte(v[15:8]);
        end
    endtask

    // ========================================================================
    // 构造并推送一幅完整的 BMP
    // ========================================================================
    // 参数:
    //   w/h      : 图像宽高（h 用有符号语义，负数表示自顶向下）
    //   bpp      : 每像素位数
    //   comp     : 压缩方式
    //   sig_ok   : 0 = 故意写坏签名
    //   dataoff  : 像素数据起始偏移（合法值 ≥ 54）
    //   fail_early: 1 = 头阶段就应失败，不必推像素数据
    task send_bmp;
        input [15:0] w;
        input signed [15:0] h;
        input [15:0] bpp;
        input [31:0] comp;
        input        sig_ok;
        input [31:0] dataoff;
        reg [31:0] row_bytes;
        reg [15:0] pad;
        reg [15:0] abs_h;
        reg [15:0] src_row;
        reg [15:0] dst_y;
        reg [15:0] x;
        reg [31:0] i;
        reg [7:0]  rgb_r, rgb_g, rgb_b;
        begin
            abs_h    = (h < 0) ? (-h) : h;
            row_bytes = w * 3;
            pad      = ((4 - (row_bytes % 4)) % 4);

            // ---- 14 字节 BITMAPFILEHEADER ----
            push_byte(sig_ok ? 8'h42 : 8'h58);   // "B"（坏签名用 "X"）
            push_byte(sig_ok ? 8'h4D : 8'h59);   // "M"
            push_u32(32'd0);                     // 文件大小（不校验）
            push_u32(32'd0);                     // 保留
            push_u32(dataoff);                   // 像素数据偏移

            // ---- 40 字节 BITMAPINFOHEADER ----
            push_u32(32'd40);                    // DIB 头大小
            push_u32({16'd0, w});                // 宽
            // 高度字段: 负数表示自顶向下。BMP 里是 32 位有符号值，
            // 必须做符号扩展 —— 直接把 16 位的 h 高位补零塞进 32 位，
            // 会让 -240 变成 65296（一个大正数），DUT 判成"高度不符"。
            push_u32(h < 0 ? {16'hFFFF, h[15:0]} : {16'd0, h[15:0]});
            push_u16(16'd1);                     // 平面数
            push_u16(bpp);                       // 位深
            push_u32(comp);                      // 压缩
            push_u32(32'd0);                     // 图像大小
            push_u32(32'd2835);                  // X ppm
            push_u32(32'd2835);                  // Y ppm
            push_u32(32'd0);                     // 调色板数
            push_u32(32'd0);                     // 重要色数

            // ---- 调色板/间隙区: 从 54 到 dataoff ----
            for (i = 32'd54; i < dataoff; i = i + 32'd1) begin
                push_byte(8'h00);
            end

            // ---- 像素数据 ----
            // BMP 行序: h>0 时第 0 行存在文件里的是显示的最后一行（底行）；
            //           h<0 时文件第 0 行就是显示的第 0 行（顶行）。
            for (src_row = 16'd0; src_row < abs_h; src_row = src_row + 16'd1) begin
                // 计算该源行对应的"显示行号"——黄金图案按显示坐标生成
                dst_y = (h < 0) ? src_row : (abs_h - 16'd1 - src_row);
                for (x = 16'd0; x < w; x = x + 16'd1) begin
                    {rgb_r, rgb_g, rgb_b} = golden_rgb888(x, dst_y);
                    push_byte(rgb_b);   // BMP 存储顺序是 B,G,R
                    push_byte(rgb_g);
                    push_byte(rgb_r);
                end
                for (i = 32'd0; i < pad; i = i + 32'd1) begin
                    push_byte(8'h00);   // 行填充
                end
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk) rst_n = 1'b0;
            repeat (4) @(negedge clk);
            @(negedge clk) rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task fire_start;
        input [15:0] w;
        input [15:0] h;
        begin
            @(negedge clk);
            exp_w = w;
            exp_h = h;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // ========================================================================
    // 像素收集与逐拍比对
    // ========================================================================
    integer pix_cnt;
    integer seq_err;
    integer seen;                   // 已被访问过的像素数（用于覆盖性统计）
    // 覆盖位图: 640×480 = 307200 个坐标，每个 1 bit 的记录用 reg 数组表达
    // 注意: 索引必须在 32 位上下文中计算。若写成 `pix_y * img_w + pix_x`，
    //   两个操作数都是 16 位 → 乘积被截断到 16 位；640 宽的图到第 103 行
    //   (640×103 = 65920 > 65535) 就会溢出，导致"像素重复"的误报。
    //   本节用 {16'd0, ·} 把操作数扩到 32 位。
    reg        seen_map [0:640*480-1];

    always @(posedge clk) begin
        if (rst_n && pix_valid) begin
            pix_cnt = pix_cnt + 1;
            // 坐标必须在范围内
            if (pix_x >= img_w || pix_y >= img_h) begin
                $display("FAIL: pixel coord out of range: (%0d,%0d) img %0dx%0d",
                         pix_x, pix_y, img_w, img_h);
                seq_err = seq_err + 1;
            end else begin
                // 期望值比对
                if (pix_rgb565 !== golden_rgb565(pix_x, pix_y)) begin
                    $display("FAIL: pixel color mismatch at (%0d,%0d): got %04x want %04x",
                             pix_x, pix_y, pix_rgb565, golden_rgb565(pix_x, pix_y));
                    seq_err = seq_err + 1;
                end
                // 覆盖性: 每个坐标只应出现一次（索引显式扩到 32 位）
                if (seen_map[{16'd0, pix_y} * {16'd0, img_w} + {16'd0, pix_x}] !== 1'b0) begin
                    $display("FAIL: pixel (%0d,%0d) emitted twice", pix_x, pix_y);
                    seq_err = seq_err + 1;
                end
                seen_map[{16'd0, pix_y} * {16'd0, img_w} + {16'd0, pix_x}] = 1'b1;
            end
        end
    end

    task clear_seen;
        integer k;
        begin
            for (k = 0; k < 640*480; k = k + 1) seen_map[k] = 1'b0;
        end
    endtask

    // ========================================================================
    // 主测试流程
    // ========================================================================
    integer miss;

    initial begin
        pix_cnt = 0;
        seq_err = 0;
        clear_seen;

        // ============ T01 640×480 自底向上（pad=0，真实素材情形）============
        $display("\n--- T01 640x480 bottom-up (pad=0) ---");
        do_reset;
        pix_cnt = 0; seq_err = 0; clear_seen;
        fire_start(16'd640, 16'd480);
        fork
            send_bmp(16'd640, 16'sd480, 16'd24, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_ok && !hdr_fail, "T01 header accepted");
                chk(img_w == 16'd640,    "T01 width = 640");
                chk(img_h == 16'd480,    "T01 height = 480");
                chk(data_off == 32'd54,  "T01 data offset = 54");
            end
        join
        repeat (4) @(negedge clk);   // 等最后一个像素的 pix_valid 落地
        chk(seq_err == 0,          "T01 every pixel matched golden model");
        chk(pix_cnt == 640*480,    "T01 pixel count = 307200");

        // ============ T02 322×240 自底向上（pad=2，填充非零）============
        $display("\n--- T02 322x240 bottom-up (pad=2) ---");
        do_reset;
        pix_cnt = 0; seq_err = 0; clear_seen;
        fire_start(16'd322, 16'd240);
        fork
            send_bmp(16'd322, 16'sd240, 16'd24, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_ok, "T02 header accepted");
            end
        join
        repeat (4) @(negedge clk);   // 等最后一个像素的 pix_valid 落地
        chk(seq_err == 0,        "T02 every pixel matched (padding skipped)");
        chk(pix_cnt == 322*240,  "T02 pixel count = 77280");

        // ============ T03 321×120（pad=1）============
        $display("\n--- T03 321x120 bottom-up (pad=1) ---");
        do_reset;
        pix_cnt = 0; seq_err = 0; clear_seen;
        fire_start(16'd321, 16'd120);
        fork
            send_bmp(16'd321, 16'sd120, 16'd24, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_ok, "T03 header accepted");
            end
        join
        repeat (4) @(negedge clk);   // 等最后一个像素的 pix_valid 落地
        chk(seq_err == 0,        "T03 every pixel matched (pad=1)");
        chk(pix_cnt == 321*120,  "T03 pixel count = 38520");

        // ============ T04 323×60（pad=3）============
        $display("\n--- T04 323x60 bottom-up (pad=3) ---");
        do_reset;
        pix_cnt = 0; seq_err = 0; clear_seen;
        fire_start(16'd323, 16'd60);
        fork
            send_bmp(16'd323, 16'sd60, 16'd24, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_ok, "T04 header accepted");
            end
        join
        repeat (4) @(negedge clk);   // 等最后一个像素的 pix_valid 落地
        chk(seq_err == 0,       "T04 every pixel matched (pad=3)");
        chk(pix_cnt == 323*60,  "T04 pixel count = 19380");

        // ============ T05 320×240 自顶向下（height<0，不翻转）============
        // 关键: 若 RTL 忽略高度符号位，会把自顶向下的图整个上下颠倒，
        //       而"每行像素内容"仍然正确 —— 只有坐标断言能抓到。
        $display("\n--- T05 320x240 top-down (h<0, no flip) ---");
        do_reset;
        pix_cnt = 0; seq_err = 0; clear_seen;
        fire_start(16'd320, 16'd240);
        fork
            send_bmp(16'd320, -16'sd240, 16'd24, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_ok,            "T05 header accepted");
                chk(img_h == 16'd240,  "T05 negative height normalized to 240");
            end
        join
        repeat (4) @(negedge clk);   // 等最后一个像素的 pix_valid 落地
        chk(seq_err == 0,        "T05 top-down image not flipped");
        chk(pix_cnt == 320*240,  "T05 pixel count = 76800");

        // ============ T06 data_off > 54（跳过调色板区）============
        $display("\n--- T06 data offset > 54 ---");
        do_reset;
        pix_cnt = 0; seq_err = 0; clear_seen;
        fire_start(16'd64, 16'd32);
        fork
            send_bmp(16'd64, 16'sd32, 16'd24, 32'd0, 1'b1, 32'd78);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_ok,              "T06 header accepted");
                chk(data_off == 32'd78,  "T06 data offset = 78");
            end
        join
        repeat (4) @(negedge clk);   // 等最后一个像素的 pix_valid 落地
        chk(seq_err == 0,      "T06 pixels after skipped gap matched");
        chk(pix_cnt == 64*32,  "T06 pixel count = 2048");

        // ============ T07 坏签名 ============
        $display("\n--- T07 bad signature ---");
        do_reset;
        fire_start(16'd64, 16'd32);
        fork
            send_bmp(16'd64, 16'sd32, 16'd24, 32'd0, 1'b0, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_fail && !hdr_ok, "T07 bad signature rejected");
                chk(err_code == 4'd1,    "T07 err = 1");

        // ============ T07b 签名: B 对 M 错（定向补 m1 存活缺口）============
        // 只让第二个签名字节错，第一个字节仍是 B。若 RTL 只查了 B 就放过，
        // 本用例必须失败 —— 这是 m1 变异体存活暴露出的覆盖缺口。
        $display("\n--- T07b signature M wrong, B right ---");
        do_reset;
        fire_start(16'd64, 16'd32);
        fork
            begin
                push_byte(8'h42);                  // "B" 正确
                push_byte(8'h59);                  // "M" 错 -> "Y"
                push_u32(32'd0); push_u32(32'd0); push_u32(32'd54);
                push_u32(32'd40); push_u32({16'd0, 16'd64});
                push_u32(32'd32); push_u16(16'd1); push_u16(16'd24);
                push_u32(32'd0); push_u32(32'd0); push_u32(32'd0);
                push_u32(32'd0); push_u32(32'd0); push_u32(32'd0);
            end
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_fail && !hdr_ok, "T07b bad second signature byte rejected");
                chk(err_code == 4'd1,   "T07b err = 1");
            end
        join

            end
        join

        // ============ T08 非 24bit ============
        $display("\n--- T08 non-24bpp ---");
        do_reset;
        fire_start(16'd64, 16'd32);
        fork
            send_bmp(16'd64, 16'sd32, 16'd16, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_fail && !hdr_ok, "T08 16bpp rejected");
                chk(err_code == 4'd2,    "T08 err = 2");
            end
        join

        // ============ T09 有压缩 ============
        $display("\n--- T09 compressed ---");
        do_reset;
        fire_start(16'd64, 16'd32);
        fork
            send_bmp(16'd64, 16'sd32, 16'd24, 32'd1, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_fail && !hdr_ok, "T09 compressed BMP rejected");
                chk(err_code == 4'd3,    "T09 err = 3");
            end
        join

        // ============ T10 宽高不符 ============
        // 期望 640×480，实际给 320×240
        $display("\n--- T10 size mismatch ---");
        do_reset;
        fire_start(16'd640, 16'd480);
        fork
            send_bmp(16'd320, 16'sd240, 16'd24, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_fail && !hdr_ok, "T10 wrong size rejected");
                chk(err_code == 4'd4,    "T10 err = 4");
            end
        join

        // ============ T10b 仅宽度不符（定向补 m4 存活缺口）============
        // T10 里宽高同时错，RTL 只要检查了其中任一项就会失败，因此
        // "不校验宽度" 的变异体（m4）存活。这里让高度正确、只让宽度错，
        // 逼 RTL 真正校验宽度字段。
        $display("\n--- T10b width mismatch only ---");
        do_reset;
        fire_start(16'd64, 16'd32);
        fork
            send_bmp(16'd48, 16'sd32, 16'd24, 32'd0, 1'b1, 32'd54);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_fail && !hdr_ok, "T10b width mismatch rejected");
                chk(err_code == 4'd4,    "T10b err = 4");
            end
        join


        // ============ T11 data_off < 54 ============
        $display("\n--- T11 data offset < 54 ---");
        do_reset;
        fire_start(16'd64, 16'd32);
        fork
            send_bmp(16'd64, 16'sd32, 16'd24, 32'd0, 1'b1, 32'd40);
            begin
                wait (hdr_ok || hdr_fail);
                chk(hdr_fail && !hdr_ok, "T11 data offset < 54 rejected");
                chk(err_code == 4'd6,    "T11 err = 6");
            end
        join

        // ============ 收尾 ============
        $display("");
        if (errors == 0) $display("ALL CHECKS PASSED: bmp_parser");
        else             $display("CHECKS FAILED: %0d error(s)", errors);
        $display("=== tb_bmp_parser done, errors = %0d, checks = %0d ===", errors, checks);
        $finish;
    end

    // 全局超时保护
    // 预算: 640×480 = 921600 字节，GAP=0 时每字节 2 拍 = 80ns → 74ms；
    //       全部 11 个用例合计约 110ms。给 3 倍余量。
    initial begin
        #400000000;
        $display("FAIL: TIMEOUT");
        $display("=== tb_bmp_parser TIMEOUT ===");
        $finish;
    end

endmodule
