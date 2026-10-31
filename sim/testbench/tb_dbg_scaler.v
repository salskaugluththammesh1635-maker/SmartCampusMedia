// =============================================================================
// tb_dbg_scaler.v — img_scaler 行相位临时诊断
// =============================================================================
// 目的: T01（128×96 → 64×48 自底向上）里第一行采样落在 src_y=94 而非 95。
//       本台只灌 128×96 一帧，打印前 6 个源行与输出行，定位首行是否命中。
// =============================================================================
`timescale 1ns / 1ps

module tb_dbg_scaler;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;

    reg         src_start = 1'b0;
    reg  [15:0] src_w = 16'd0;
    reg  [15:0] src_h = 16'd0;
    reg         src_valid = 1'b0;
    reg  [15:0] src_rgb565 = 16'd0;
    reg  [15:0] src_y = 16'd0;

    wire        dst_valid;
    wire [15:0] dst_rgb, dst_x, dst_y;
    wire [15:0] ow, oh, ox, oy;
    wire        ok;
    wire [31:0] pix;

    img_scaler #(.DST_W(64), .DST_H(48)) dut (
        .clk(clk), .rst_n(rst_n),
        .src_start(src_start), .src_w(src_w), .src_h(src_h),
        .src_valid(src_valid), .src_rgb565(src_rgb565), .src_y(src_y),
        .dst_valid(dst_valid), .dst_rgb565(dst_rgb), .dst_x(dst_x), .dst_y(dst_y),
        .out_w(ow), .out_h(oh), .out_off_x(ox), .out_off_y(oy),
        .out_cfg_ok(ok), .out_pixels(pix)
    );

    integer n_src, n_dst;

    always @(posedge clk) begin
        if (rst_n && src_valid && (n_src < 6)) begin
            $display("  t=%0t src_y=%0d  step=%0d thresh=%0d first_row=%0d cur_y=%0d new_row=%0d row_hit=%0d row_use=%0d ty_now=%0d",
                     $time, src_y, dut.step_r, dut.thresh_r, dut.first_row, dut.cur_y,
                     dut.new_row, dut.row_hit, dut.row_use, dut.ty_now);
            n_src = n_src + 1;
        end
        if (rst_n && dst_valid && (n_dst < 3)) begin
            $display("  OUT t=%0t dst=(%0d,%0d) rgb=%04x (sx=%0d sy=%0d)",
                     $time, dst_x, dst_y, dst_rgb, dst_rgb[15:8], dst_rgb[7:0]);
            n_dst = n_dst + 1;
        end
    end

    integer ry, rx, yy;

    initial begin
        n_src = 0; n_dst = 0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- 预热帧: 320x240（模拟主测试台连续用例的前序残留）----
        @(negedge clk);
        src_start = 1'b1; src_w = 16'd320; src_h = 16'd240;
        @(negedge clk);
        src_start = 1'b0;
        while (!ok) @(negedge clk);
        $display("warm cfg: out_w=%0d out_h=%0d step=%0d thresh=%0d",
                 ow, oh, dut.step_r, dut.thresh_r);
        for (ry = 0; ry < 240; ry = ry + 1) begin
            yy = 240 - 1 - ry;
            for (rx = 0; rx < 320; rx = rx + 1) begin
                @(negedge clk);
                src_valid = 1'b1;
                src_rgb565 = 16'd0;
                src_y = yy[15:0];
            end
        end
        @(negedge clk);
        src_valid = 1'b0;
        repeat (2) @(negedge clk);
        $display("--- warm done, start target frame ---");
        n_src = 0; n_dst = 0;

        @(negedge clk);
        src_start = 1'b1; src_w = 16'd128; src_h = 16'd96;
        @(negedge clk);
        src_start = 1'b0;
        while (!ok) @(negedge clk);
        $display("cfg: out_w=%0d out_h=%0d off=(%0d,%0d) pixels=%0d step=%0d thresh=%0d",
                 ow, oh, ox, oy, pix, dut.step_r, dut.thresh_r);

        for (ry = 0; ry < 96; ry = ry + 1) begin
            yy = 96 - 1 - ry;
            for (rx = 0; rx < 128; rx = rx + 1) begin
                @(negedge clk);
                src_valid = 1'b1;
                src_rgb565 = {rx[7:0], yy[7:0]};
                src_y = yy[15:0];
            end
        end
        @(negedge clk);
        src_valid = 1'b0;
        repeat (4) @(negedge clk);
        $finish;
    end

endmodule
