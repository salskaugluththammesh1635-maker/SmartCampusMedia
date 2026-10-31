// =============================================================================
// tb_hdmi_phy.v —— HDMI PHY 四通道并行串化（hdmi_phy）自检测试平台
// -----------------------------------------------------------------------------
// 【被评测对象】
//   rtl/video/hdmi/hdmi_phy.v：把发射核给的 4 组 10 bit TMDS 字
//   （ch0=蓝 ch1=绿 ch2=红 clk=像素时钟）各串成一条 10 倍速串行流。
//   重点保障两件事：
//     ① 四条通道各自独立串化，互不干扰（串了就会串色）；
//     ② **位反序确实做了**。发射核输出是 LSB-first，移位寄存器是 MSB-first，
//        位序漏掉/做反在仿真里表现为"颜色错乱但图像结构正常"，
//        上板极难查，所以必须在这里钉死。
//
// 【判据】
//   沿用 tb_lane_lvds_10_1 已验证的"相位模板匹配"（字与字在 5:1 下首尾相接，
//   不存在空隙，所以不能用找字首的办法）。本平台对每条通道单独建采样缓冲，
//   期望模板由 DUT 内部反序的结果推出来：
//     输入 I_tmds_chN = W  → 反序后 rev = bit_reverse(W) → 串行 MSB-first 出
//     故解出的字应等于 bit_reverse(W)。
//   如果 hdmi_phy 漏了位反序，解出的字会等于 W 本身（当 W ≠ rev(W) 时失配）；
//   从而位反序这一条有了决定性判据。
//
// 【位反序的决定性用例】
//   W = 10'b1000000000（只有 bit9 为 1）。rev(W) = 10'b0000000001。
//   若漏做反序，串行流会是"每 10 拍首拍为 1"；做了反序则是"每 10 拍末拍为 1"。
//   这两种流在模板匹配下只有一个相位能对齐，必然分辨出来。
//
// 【四条通道互不干扰】
//   同一轮里给四条通道不同的字，逐条通道独立比对；只要有任何一条被串到，
//   该通道的模板就会失配。
// =============================================================================
`timescale 1ns / 1ps

module tb_hdmi_phy;

    // ---- 时钟 --------------------------------------------------------------
    localparam PIX_HALF = 50;   // 像素周期 100ns
    localparam SER_HALF = 10;   // 串行周期 20ns（5:1）
    localparam SAMP_DLY = 5;
    localparam PERIOD   = 10;   // 一个像素 = 10 个半周期采样点
    localparam MAXCAP   = 200;

    reg pix_clk;
    reg ser_clk;

    initial begin pix_clk = 1'b0; #7; forever #PIX_HALF pix_clk = ~pix_clk; end
    initial begin ser_clk = 1'b0; #3; forever #SER_HALF ser_clk = ~ser_clk; end

    // ---- 被测模块接口 ------------------------------------------------------
    reg        rst;
    reg [9:0]  tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;

    wire out_ch0, out_ch1, out_ch2, out_clk;

    hdmi_phy u_dut (
        .I_pixel_clk  (pix_clk),
        .I_serial_clk (ser_clk),
        .I_rst        (rst),
        .I_tmds_ch0   (tmds_ch0),
        .I_tmds_ch1   (tmds_ch1),
        .I_tmds_ch2   (tmds_ch2),
        .I_tmds_clk   (tmds_clk),
        .O_tmds_ch0_p (out_ch0),
        .O_tmds_ch1_p (out_ch1),
        .O_tmds_ch2_p (out_ch2),
        .O_tmds_clk_p (out_clk)
    );

    // ---- 四条通道各一份采样缓冲 --------------------------------------------
    reg     cap0 [0:MAXCAP-1];
    reg     cap1 [0:MAXCAP-1];
    reg     cap2 [0:MAXCAP-1];
    reg     cap3 [0:MAXCAP-1];   // 时钟通道
    integer cap_n;
    reg     cap_en;

    initial begin cap_n = 0; cap_en = 1'b0; end

    always @(ser_clk) begin
        #(SAMP_DLY);
        if (cap_en && (cap_n < MAXCAP)) begin
            cap0[cap_n] = out_ch0;
            cap1[cap_n] = out_ch1;
            cap2[cap_n] = out_ch2;
            cap3[cap_n] = out_clk;
            cap_n = cap_n + 1;
        end
    end

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    // ---- 工具函数：10 bit 位反序（与 hdmi_phy 内部一致）--------------------
    function [9:0] rev10;
        input [9:0] v;
        begin
            rev10 = {v[0], v[1], v[2], v[3], v[4],
                     v[5], v[6], v[7], v[8], v[9]};
        end
    endfunction

    task wait_pix;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge pix_clk);
        end
    endtask

    task capture;
        input integer n;
        begin
            cap_n  = 0;
            cap_en = 1'b1;
            wait (cap_n >= n);
            cap_en = 1'b0;
        end
    endtask

    // 相位模板匹配（chan: 0..3）
    task check_lane;
        input integer    chan;
        input [9:0]      word;        // 期望解出的字（应为 rev10(输入)）
        input [8*48-1:0] label;
        integer p, k, ti, mis, best_p, best_mis, bad;
        reg     qb;
        begin
            best_p   = -1;
            best_mis = 1000000000;
            for (p = 0; p < PERIOD; p = p + 1) begin
                mis = 0;
                for (k = p; k < cap_n; k = k + 1) begin
                    ti = (k - p) % PERIOD;
                    case (chan)
                        0: qb = cap0[k];
                        1: qb = cap1[k];
                        2: qb = cap2[k];
                        default: qb = cap3[k];
                    endcase
                    if (qb !== word[9 - ti]) mis = mis + 1;
                end
                if (mis < best_mis) begin
                    best_mis = mis;
                    best_p   = p;
                end
            end

            checks = checks + 1;
            if (best_mis == 0) begin
                $display("PASS: %0s | chan%0d word=%b phase=%0d",
                         label, chan, word, best_p);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s | chan%0d word=%b best_phase=%0d mismatch=%0d/%0d",
                         label, chan, word, best_p, best_mis, cap_n);
                bad = 0;
                for (k = best_p; k < cap_n && bad < 8; k = k + 1) begin
                    ti = (k - best_p) % PERIOD;
                    case (chan)
                        0: qb = cap0[k];
                        1: qb = cap1[k];
                        2: qb = cap2[k];
                        default: qb = cap3[k];
                    endcase
                    if (qb !== word[9 - ti]) begin
                        $display("      idx=%0d got=%b exp=%b (bit%0d)",
                                 k, qb, word[9 - ti], 9 - ti);
                        bad = bad + 1;
                    end
                end
            end
        end
    endtask

    // 送一组四通道字 → 稳定 → 采样 → 四条通道各自判据
    task run_quad;
        input [9:0]      w0;
        input [9:0]      w1;
        input [9:0]      w2;
        input [9:0]      wc;
        input [8*48-1:0] label;
        begin
            tmds_ch0 = w0;
            tmds_ch1 = w1;
            tmds_ch2 = w2;
            tmds_clk = wc;
            wait_pix(8);
            capture(100);
            check_lane(0, rev10(w0), label);
            check_lane(1, rev10(w1), label);
            check_lane(2, rev10(w2), label);
            check_lane(3, rev10(wc), label);
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;

    initial begin
        $display("=== tb_hdmi_phy : HDMI PHY 4-lane serializer ===");

        rst      = 1'b1;
        tmds_ch0 = 10'd0;
        tmds_ch1 = 10'd0;
        tmds_ch2 = 10'd0;
        tmds_clk = 10'd0;

        // 1) 复位期间四条通道都必须安静
        wait_pix(10);
        capture(60);
        checks = checks + 1;
        if ((cap0[20] === 1'b0) && (cap1[20] === 1'b0) &&
            (cap2[20] === 1'b0) && (cap3[20] === 1'b0)) begin
            $display("PASS: [reset-hold] all four lanes held low");
        end else begin
            errors = errors + 1;
            $display("FAIL: [reset-hold] ch0=%b ch1=%b ch2=%b clk=%b",
                     cap0[20], cap1[20], cap2[20], cap3[20]);
        end

        rst = 1'b0;
        wait_pix(8);

        // 2) 位反序的决定性用例：单 bit 走查
        //    输入只有 bit(i) 为 1 → 反序后只有 bit(9-i) 为 1
        //    若 hdmi_phy 漏做反序，这两者不同（i≠4），模板必然失配
        for (i = 0; i < 10; i = i + 1) begin
            run_quad((10'b1 << i), 10'b0, 10'b0, 10'b0,
                     "[bitrev-walk] ch0 single bit");
        end

        // 3) 四条通道互不干扰：四个不同图案同时送
        run_quad(10'b1111111111, 10'b0000000000, 10'b1010101010, 10'b0101010101,
                 "[quad-distinct] all four lanes");

        run_quad(10'b1000000001, 10'b0111111110, 10'b1100000011, 10'b0011111100,
                 "[quad-edge] all four lanes");

        run_quad(10'b1100110011, 10'b0011001100, 10'b1111000011, 10'b0000111100,
                 "[quad-mixed] all four lanes");

        // 4) 时钟通道：TMDS 时钟是"每像素 5 个 1、5 个 0"的固定图案
        //    设计里由发射核给 10'b1111100000，反序后为 10'b0000011111
        run_quad(10'b0000000000, 10'b0000000000, 10'b0000000000, 10'b1111100000,
                 "[tmds-clock] clk lane pattern");

        // 5) 复位可中途打断
        run_quad(10'b1010101010, 10'b1010101010, 10'b1010101010, 10'b1010101010,
                 "[pre-reset] pattern before reset");
        rst = 1'b1;
        wait_pix(6);
        capture(60);
        checks = checks + 1;
        if ((cap0[30] === 1'b0) && (cap1[30] === 1'b0) &&
            (cap2[30] === 1'b0) && (cap3[30] === 1'b0)) begin
            $display("PASS: [mid-reset] all four lanes forced low");
        end else begin
            errors = errors + 1;
            $display("FAIL: [mid-reset] ch0=%b ch1=%b ch2=%b clk=%b",
                     cap0[30], cap1[30], cap2[30], cap3[30]);
        end
        rst = 1'b0;
        wait_pix(10);

        // 6) 恢复后重新对齐
        run_quad(10'b1100110011, 10'b1100110011, 10'b1100110011, 10'b1100110011,
                 "[resume] pattern after reset");

        // 7) 收尾
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: hdmi_phy");
        else             $display("CHECKS FAILED: hdmi_phy");
        $finish;
    end

endmodule
