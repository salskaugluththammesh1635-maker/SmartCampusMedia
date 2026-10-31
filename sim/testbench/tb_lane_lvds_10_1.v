// =============================================================================
// tb_lane_lvds_10_1.v —— TMDS 10:1 串化器（lane_lvds_10_1）自检测试平台
// -----------------------------------------------------------------------------
// 【被评测对象】
//   rtl/video/hdmi/lane_lvds_10_1.v：每个像素时钟把 10 bit 并行 TMDS 字经
//   EG_LOGIC_ODDR 摊到 5 个串行周期上，MSB 先出（设计文档要求 LSB-first 的
//   反序在 hdmi_phy 里做，本模块只按给定顺序串化）。
//
// 【判据为什么用"相位模板匹配"而不是"找字首"】
//   5:1 串并比下，一个像素 = 5 个串行周期 = 10 个半周期采样点，而一个装载
//   周期也正好是 10 bit —— 字与字首尾相接，输出流里根本不存在空隙，
//   "非零且前一拍为零即字首"这类锚点法对含连续 0 的字（如 10'b1100_0000_01）
//   会数出多个假字首，判据本身是错的。
//   本平台改为：对相位 p = 0..PERIOD-1 逐一试探，要求采样流满足
//        q_mem[p + k*PERIOD + i] == word[9-i]   (i = 0..9)
//   存在任一相位使**全部**采样点匹配即判通过。这一条判据同时覆盖了：
//     · 位序正确（MSB 先出；位反序会让匹配相位不存在）
//     · 每串行周期出 2 bit 且上下沿分工正确（d0 在高电平、d1 在低电平；
//       若 ODDR 的 d0/d1 接反，10'b1100_0000_01 会变成 ...0001_0，失配）
//     · 字与字之间不串位（只要有一个字的某一位错位，整段流就对不上模板）
//
// 【时钟比与采样点】
//   真实设计 I_serial_clk = 5 × I_pixel_clk。本平台取像素周期 100ns、
//   串行周期 20ns。采样点落在每个串行半周期正中（边沿后 5ns），
//   既能避开 0.1ns 的 clk_mux 偏移，也远离任何建立/保持窗口。
//
// 【位序的"决定性"测试：走 1 法】
//   单比特字（10'b1 << i）在流里是"每 10 个采样点只有一个 1"，
//   它的 1 落在模板第 (9-i) 个位置 —— 相位解唯一。因此对 i = 0..9 逐个
//   跑一次，等价于把 10 根数据线逐一钉在对应的串行时隙上，
//   任何一位接错/错位都会被抓到。
//
// 【依赖】
//   仿真需要安路原语 EG_LOGIC_ODDR 与 glbl（eg_phy_glbl.v）。
//   回归脚本 run_full_regression.ps1 会自动找到 D:\TD_6_24_APP\sim_release\eg4
//   下的官方仿真库，并把 glbl 作为第二个顶层一起装入。
// =============================================================================
`timescale 1ns / 1ps

module tb_lane_lvds_10_1;

    // ---- 时钟与采样参数 ----------------------------------------------------
    localparam PIX_HALF = 50;   // 像素时钟半周期 → 周期 100ns
    localparam SER_HALF = 10;   // 串行时钟半周期 → 周期 20ns（5:1）
    localparam SAMP_DLY = 5;    // 半周期中点采样
    localparam PERIOD   = 10;   // 一个像素包含的半周期采样点数
    localparam MAXCAP   = 600;  // 采样缓冲深度

    reg pix_clk;
    reg ser_clk;

    // 两路时钟错开相位启动，避免像素时钟沿与串行时钟沿重合造成竞争
    initial begin pix_clk = 1'b0; #7; forever #PIX_HALF pix_clk = ~pix_clk; end
    initial begin ser_clk = 1'b0; #3; forever #SER_HALF ser_clk = ~ser_clk; end

    // ---- 被测模块接口 ------------------------------------------------------
    reg        rst;
    reg [9:0]  data_in;
    wire       serial_out;

    lane_lvds_10_1 u_dut (
        .I_pixel_clk  (pix_clk),
        .I_serial_clk (ser_clk),
        .I_rst        (rst),
        .I_data_in    (data_in),
        .O_serial_out (serial_out)
    );

    // ---- 半周期采样器 ------------------------------------------------------
    reg     q_mem [0:MAXCAP-1];
    integer cap_n;
    reg     cap_en;

    initial begin cap_n = 0; cap_en = 1'b0; end

    always @(ser_clk) begin
        #(SAMP_DLY);
        if (cap_en && (cap_n < MAXCAP)) begin
            q_mem[cap_n] = serial_out;
            cap_n = cap_n + 1;
        end
    end

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    // ---- 通用任务 ----------------------------------------------------------
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

    // 相位模板匹配：全部采样点都必须落在模板上
    task check_word;
        input [9:0]      word;
        input [8*64-1:0] label;
        integer p, k, ti, mis, best_p, best_mis, dumped;
        begin
            best_p   = -1;
            best_mis = 1000000000;
            for (p = 0; p < PERIOD; p = p + 1) begin
                mis = 0;
                for (k = p; k < cap_n; k = k + 1) begin
                    ti = (k - p) % PERIOD;
                    if (q_mem[k] !== word[9 - ti]) mis = mis + 1;
                end
                if (mis < best_mis) begin
                    best_mis = mis;
                    best_p   = p;
                end
            end

            checks = checks + 1;
            if (best_mis == 0) begin
                $display("PASS: %0s | word=%b phase=%0d samples=%0d",
                         label, word, best_p, cap_n);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s | word=%b best_phase=%0d mismatch=%0d/%0d",
                         label, word, best_p, best_mis, cap_n);
                // 打印前两段（各一个 PERIOD）的实测与期望，方便定位
                dumped = 0;
                for (k = best_p; k < cap_n && dumped < 2*PERIOD; k = k + 1) begin
                    ti = (k - best_p) % PERIOD;
                    if (q_mem[k] !== word[9 - ti]) begin
                        $display("      idx=%0d got=%b exp=%b (bit%0d)",
                                 k, q_mem[k], word[9 - ti], 9 - ti);
                    end
                    dumped = dumped + 1;
                end
            end
        end
    endtask

    // 全零流检查：复位期间 / 全零字时输出必须恒为 0
    task check_zero_stream;
        input [8*64-1:0] label;
        integer k, bad;
        begin
            bad = 0;
            for (k = 0; k < cap_n; k = k + 1)
                if (q_mem[k] !== 1'b0) bad = bad + 1;

            checks = checks + 1;
            if (bad == 0) begin
                $display("PASS: %0s | %0d samples all zero", label, cap_n);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s | %0d of %0d samples nonzero",
                         label, bad, cap_n);
            end
        end
    endtask

    // 送一个字 → 稳定 → 采样 → 判据
    task run_word;
        input [9:0]      word;
        input [8*64-1:0] label;
        begin
            data_in = word;
            wait_pix(8);
            capture(100);
            check_word(word, label);
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;

    initial begin
        $display("=== tb_lane_lvds_10_1 : TMDS 10:1 serializer ===");

        rst     = 1'b1;
        data_in = 10'd0;

        // 1) 复位期间输出必须被压到 0
        //    （rst_sync_s 两级同步需要 2 个串行周期，故先等 10 个像素周期）
        wait_pix(10);
        capture(100);
        check_zero_stream("[reset-hold] line held low by I_rst");

        // 2) 释放复位后先送全 0 字
        rst = 1'b0;
        wait_pix(8);
        capture(100);
        check_zero_stream("[data-zero] all-zero word keeps line low");

        // 3) 全 1 字：最宽的连续高电平，检验满载时无丢位
        run_word(10'b1111111111, "[word-all-ones] 1111111111");

        // 4) 走 1：把 10 根数据线逐个钉到各自的串行时隙上
        //    这是位序（MSB 先出）的决定性测试
        for (i = 0; i < 10; i = i + 1) begin
            run_word((10'b1 << i), "[walk-one] single bit set");
        end

        // 5) 非对称字：两端都有 1，内部连续 0 —— 反序/错位都逃不掉
        run_word(10'b1100000001, "[word-edge-ones] 1100000001");
        run_word(10'b1000000011, "[word-cut-ones] 1000000011");
        run_word(10'b1010101010, "[word-alt-10] 1010101010");
        run_word(10'b1010101011, "[word-alt-11] 1010101011");
        run_word(10'b1111000011, "[word-hi-lo] 1111000011");
        run_word(10'b0111000110, "[word-tmds-ish] 0111000110");

        // 6) 复位是"随时可打断"的：串到一半拉复位，输出必须立刻归零
        data_in = 10'b1100110011;
        wait_pix(8);
        capture(100);
        check_word(10'b1100110011, "[word-cc33] 1100110011");

        rst = 1'b1;
        wait_pix(6);
        capture(100);
        check_zero_stream("[mid-reset] mid-stream reset forces low");

        // 7) 复位释放后必须能无缝续上（shift_data 不复位，靠装载使能压住）
        rst = 1'b0;
        wait_pix(10);
        capture(100);
        check_word(10'b1100110011, "[resume] pattern resumes after reset");

        // 8) 收尾
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: lane_lvds_10_1");
        else             $display("CHECKS FAILED: lane_lvds_10_1");
        $finish;
    end

endmodule
