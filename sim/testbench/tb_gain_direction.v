// ============================================================================
//  tb_gain_direction.v —— 亮度/音量方向对照（t6 必测项）
// ----------------------------------------------------------------------------
//  ★ 本测试台存在的唯一理由
//    `brightness_apply.v` 与 `vol_apply.v` 的 10 档增益集合**完全相同**：
//        {3, 6, 10, 13, 16, 20, 23, 26, 29, 32} / 32
//    只是排列方向相反：
//        亮度：档 0 = 32/32 最亮  →  档 9 = 3/32 最暗
//        音量：档 0 =  3/32 最轻  →  档 9 = 32/32 最响
//    这是最容易"复制粘贴后忘了翻转"的地方，而且翻转后单看任何一个模块
//    的 tb 都可能不报错（亮度 tb 只验亮度、音量 tb 只验音量）。
//    所以把两条方向断言放进**同一个 tb 的相邻两行**，任何一处翻转都会
//    立刻在唯一的日志里炸出来。
//
//  ★ 第二个陷阱：负半轴的"更响"是数值更小
//    音频是 24 位**有符号**数。负半轴上"更响" = 绝对值更大 = 数值更小。
//    如果只验正半轴，把 `>>>`（算术右移）写成 `>>`（逻辑右移）的缺陷
//    完全检不出：`-8388608 >> 4` = `+524288`，符号翻转成正数大音量，
//    而正半轴断言全过、上板是"负半周削顶+直流偏置"的典型爆音。
//    所以必须补 `|out(0)| < |out(9)|` 这条绝对值的断言。
//
//  编译依赖：rtl/video/brightness_apply.v + rtl/audio/vol_apply.v
// ============================================================================
`timescale 1ns/1ps

module tb_gain_direction;

    // ------------------------------------------------------------------------
    //  时钟与复位
    // ------------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;          // 25 MHz

    // ------------------------------------------------------------------------
    //  亮度模块（纯组合，无时钟）
    // ------------------------------------------------------------------------
    reg  [23:0] brt_rgb_in = 24'd0;
    reg  [3:0]  brt_lvl    = 4'd0;
    reg         brt_de     = 1'b1;
    wire        brt_de_out;
    wire [23:0] brt_rgb_out;

    brightness_apply u_brt (
        .de        (brt_de),
        .rgb_in    (brt_rgb_in),
        .bright_lvl(brt_lvl),
        .de_out    (brt_de_out),
        .rgb_out   (brt_rgb_out)
    );

    // ------------------------------------------------------------------------
    //  音量模块（时序，输出打一拍）
    // ------------------------------------------------------------------------
    reg  signed [23:0] vol_sample_in   = 24'sd0;
    reg  [3:0]         vol_lvl         = 4'd0;
    reg  [1:0]         vol_mode        = 2'd0;
    reg                vol_audio_en    = 1'b1;
    reg                vol_sample_valid= 1'b0;
    wire               vol_sample_valid_out;
    wire signed [23:0] vol_sample_out;
    wire [3:0]         vol_eff_lvl;

    vol_apply u_vol (
        .clk             (clk),
        .rst_n           (rst_n),
        .sample_valid    (vol_sample_valid),
        .sample_in       (vol_sample_in),
        .vol_lvl         (vol_lvl),
        .mode            (vol_mode),
        .audio_en        (vol_audio_en),
        .sample_valid_out(vol_sample_valid_out),
        .sample_out      (vol_sample_out),
        .eff_lvl         (vol_eff_lvl)
    );

    // ------------------------------------------------------------------------
    //  记分板
    // ------------------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk(input cond, input [8*96-1:0] msg);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    //  操作 task
    // ------------------------------------------------------------------------
    // 亮度：纯组合，直接算
    task brt_out(input [3:0] lvl, input [7:0] chan_r, output [7:0] res);
        begin
            brt_lvl    = lvl;
            brt_rgb_in = {chan_r, chan_r, chan_r};
            #1;
            res = brt_rgb_out[23:16];
        end
    endtask

    // 音量：时序，脉冲 sample_valid 后取下一拍输出
    task vol_out_i(input [3:0] lvl, input signed [23:0] samp, output signed [23:0] res);
        begin
            @(negedge clk);
            vol_lvl          = lvl;
            vol_sample_in    = samp;
            vol_audio_en     = 1'b1;
            vol_mode         = 2'd0;
            vol_sample_valid = 1'b1;
            @(negedge clk);
            vol_sample_valid = 1'b0;
            res = vol_sample_out;
        end
    endtask

    // 24 位有符号取绝对值（-8388608 的正确结果是 8388608 = 24'h80_0000）
    function [23:0] abs24(input signed [23:0] x);
        begin
            abs24 = x[23] ? (~x[23:0] + 24'd1) : x[23:0];
        end
    endfunction

    // ------------------------------------------------------------------------
    //  结果暂存
    // ------------------------------------------------------------------------
    reg [7:0]         brt_v [0:9];
    reg signed [23:0] vol_v [0:9];
    reg signed [23:0] vol_neg_v [0:9];
    integer i;
    integer m;

    // ------------------------------------------------------------------------
    //  主流程
    // ------------------------------------------------------------------------
    initial begin
        // ---- 复位 ----
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ====================================================================
        //  C01/C02 —— 方向断言（★ 相邻两行，本 tb 的核心）
        // ====================================================================
        // 亮度：满量程 255，档 0 必须比档 9 亮
        brt_out(4'd0, 8'd255, brt_v[0]);
        brt_out(4'd9, 8'd255, brt_v[9]);
        vol_out_i(4'd0, 24'sh7F_FFFF, vol_v[0]);
        vol_out_i(4'd9, 24'sh7F_FFFF, vol_v[9]);

        $display("");
        $display("---- direction check (adjacent lines, must both hold) ----");
        chk(brt_v[0] > brt_v[9],
            "C01 brightness_apply direction: out(0) > out(9)  [0=brightest, 9=darkest]");
        chk(vol_v[0] < vol_v[9],
            "C02 vol_apply direction: out(0) < out(9)  [0=quietest, 9=loudest]");
        $display("     brightness out(0)=%0d out(9)=%0d", brt_v[0], brt_v[9]);
        $display("     volume     out(0)=%0d out(9)=%0d", vol_v[0], vol_v[9]);
        $display("");

        // ====================================================================
        //  C03/C04 —— 负半轴绝对值断言（捕获 >> 误写成 >>> 的反向 bug）
        // ====================================================================
        vol_out_i(4'd0, -24'sh80_0000, vol_neg_v[0]);
        vol_out_i(4'd9, -24'sh80_0000, vol_neg_v[9]);
        chk(abs24(vol_neg_v[0]) < abs24(vol_neg_v[9]),
            "C03 vol_apply negative half: |out(0)| < |out(9)|  (arithmetic shift sanity)");
        // 更强的判据：负半轴输出必须仍为负数（符号未被逻辑右移翻转）
        chk(vol_neg_v[0][23] == 1'b1,
            "C04 vol_apply negative half: out(0) sign bit still 1 (no sign flip)");
        chk(vol_neg_v[9][23] == 1'b1,
            "C05 vol_apply negative half: out(9) sign bit still 1 (no sign flip)");
        $display("     volume neg out(0)=%0d |%0d|  out(9)=%0d |%0d|",
                 vol_neg_v[0], abs24(vol_neg_v[0]),
                 vol_neg_v[9], abs24(vol_neg_v[9]));
        $display("");

        // ====================================================================
        //  C06 —— 亮度 10 档严格单调递减（含数值表打印）
        // ====================================================================
        for (i = 0; i < 10; i = i + 1) begin
            brt_out(i[3:0], 8'd255, brt_v[i]);
        end
        $display("---- brightness 10 levels (x=255) ----");
        for (i = 0; i < 10; i = i + 1) begin
            $display("     lvl %0d -> %0d", i, brt_v[i]);
        end
        m = 1;
        for (i = 0; i < 9; i = i + 1) begin
            if (!(brt_v[i] > brt_v[i+1])) m = 0;
        end
        chk(m, "C06 brightness 10 levels strictly decreasing 0->9");

        // ====================================================================
        //  C07 —— 音量 10 档严格单调递增（含数值表打印，供交付文档引用）
        // ====================================================================
        for (i = 0; i < 10; i = i + 1) begin
            vol_out_i(i[3:0], 24'sh7F_FFFF, vol_v[i]);
        end
        $display("---- volume 10 levels (x=+8388607) ----");
        for (i = 0; i < 10; i = i + 1) begin
            $display("     lvl %0d -> %0d", i, vol_v[i]);
        end
        m = 1;
        for (i = 0; i < 9; i = i + 1) begin
            if (!(vol_v[i] < vol_v[i+1])) m = 0;
        end
        chk(m, "C07 volume 10 levels strictly increasing 0->9");

        // ====================================================================
        //  C08 —— 音量 10 档在负半轴也严格单调（绝对值递增）
        // ====================================================================
        for (i = 0; i < 10; i = i + 1) begin
            vol_out_i(i[3:0], -24'sh80_0000, vol_neg_v[i]);
        end
        m = 1;
        for (i = 0; i < 9; i = i + 1) begin
            if (!(abs24(vol_neg_v[i]) < abs24(vol_neg_v[i+1]))) m = 0;
        end
        chk(m, "C08 volume 10 levels |abs| strictly increasing 0->9 (negative half)");

        // ====================================================================
        //  C09 —— 亮度档 0 必须逐位直通（不引入无谓衰减）
        // ====================================================================
        brt_out(4'd0, 8'd255, brt_v[0]);
        chk(brt_v[0] == 8'd255, "C09 brightness lvl0 is bit-exact passthrough (255 -> 255)");

        // ====================================================================
        //  C10 —— 音量档 9 必须逐位直通（满幅不衰减也不溢出）
        // ====================================================================
        vol_out_i(4'd9, 24'sh7F_FFFF, vol_v[9]);
        chk(vol_v[9] == 24'sh7F_FFFF, "C10 volume lvl9 is bit-exact passthrough (max -> max)");
        vol_out_i(4'd9, -24'sh80_0000, vol_neg_v[9]);
        chk(vol_neg_v[9] == -24'sh80_0000, "C11 volume lvl9 negative full scale exact");

        // ====================================================================
        //  C12 —— 近零样本不得出现符号翻转式爆幅
        //    `>>>` 对 -1 恒得 -1，故各档输出都是 -1 或由移位项相减得到的
        //    0/±1/±2（量化噪声，24 位满量程的 2.4e-7，听感 -120dB 以下）。
        //
        //    ★ 判据为什么是"绝对值极小"而不是"恒等于 -1"：
        //      档 0 = (x>>>4)+(x>>>5)，对 x=-1 两个算术右移各自舍入到 -1，
        //      相加得 **-2**；档 3 = (x>>>1)-(x>>>4)-(x>>>5) 得 **+1**。
        //      这是"负数算术右移向负无穷舍入"的固有量化，不是缺陷 ——
        //      理想值 -0.09 量化到 -2 或 +1 都在 ±2 LSB 内。
        //      真正要抓的失效是 `>>>` 误写成 `>>` 时的那个量级：
        //          -1 >> 4 = 0x0FFF_FFFF，24 位截断 = 0x00FF_FFFF
        //          = +16,777,215 → 饱和成 +8,388,607
        //      绝对值从 2 跳到 8 百万，所以阈值取 |out| <= 16 既能容忍
        //      真量化的 ±2，又能把逻辑右移的爆幅死死拦住。
        // ====================================================================
        m = 1;
        for (i = 0; i < 10; i = i + 1) begin
            vol_out_i(i[3:0], -24'sd1, vol_neg_v[i]);
            $display("     near-zero lvl %0d -> %0d  (|%0d|)", i, vol_neg_v[i], abs24(vol_neg_v[i]));
            if (abs24(vol_neg_v[i]) > 24'd16) m = 0;
        end
        chk(m, "C12 near-zero sample -1: |out| <= 16 at all 10 levels (no logic-shift blowup)");

        // ====================================================================
        //  C13 —— 近零正样本 +1 同样不得爆幅（对称性检查）
        // ====================================================================
        m = 1;
        for (i = 0; i < 10; i = i + 1) begin
            vol_out_i(i[3:0], 24'sd1, vol_neg_v[i]);
            if (abs24(vol_neg_v[i]) > 24'd16) m = 0;
        end
        chk(m, "C13 near-zero sample +1: |out| <= 16 at all 10 levels (symmetric)");

        // ====================================================================
        //  收尾
        // ====================================================================
        $display("");
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: gain_direction");
        end else begin
            $display("CHECKS FAILED: gain_direction  pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
        $display("=== tb_gain_direction: pass=%0d fail=%0d ===", pass_cnt, fail_cnt);
        $finish;
    end

    // 全局超时
    initial begin
        #2_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
