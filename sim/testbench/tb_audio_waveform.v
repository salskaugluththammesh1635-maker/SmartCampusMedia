// =============================================================================
// tb_audio_waveform.v —— audio_waveform 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块的语义（逐条对应 rtl/video/audio_waveform.v 的行号）】
//
//   1) 历史移位寄存器 audio_waveform.v:57-72
//      hist 是 64 个 16 bit 有符号槽。只在 audio_valid 单拍时移位：
//          for (i=63; i>0; i=i-1) hist[i] <= hist[i-1];
//          hist[0] <= audio_sample[23:8];
//      → hist[0] 是最新样本，hist[63] 是最旧样本；
//      → **只取 24 bit 样本的高 16 位**（低 8 位被丢弃），这是必须单测的点：
//        如果误写成 audio_sample[15:0]，波形符号与幅度都会错。
//
//   2) x 方向映射 audio_waveform.v:75-79
//      in_window = (active_x >= X0=64) && (active_x < X1=576)
//      rel_x     = active_x - 64                   （0..511）
//      idx       = 63 - rel_x[9:3]
//      → **每 8 个像素对应一个历史样本**，同一个 q=rel_x[9:3] 内 8 列共用 idx；
//      → 左边（x=64）用 idx=63 最旧样本，右边（x=575）用 idx=0 最新样本。
//
//   3) 相邻样本连线 audio_waveform.v:82-95
//      idx_prev = (idx == 63) ? idx : idx + 1     ← 最左端没有更旧样本，退化为自身
//      y_curr = 200 + (hist[idx]      >>> 9)
//      y_prev = 200 + (hist[idx_prev] >>> 9)
//      y_min/y_max 取二者较小/较大，然后
//      wave_pixel = wave_en && de && in_window && (active_y >= y_min) && (active_y <= y_max)
//      → 每列点亮的是 y_min..y_max 的**闭区间**，两端都要亮。
//
//   4) 颜色恒为 24'hFF_FF_40（黄色），与九宫格/电平条区分。
//
// 【本 TB 的核心手法：造一条可精确预测的斜坡】
//   依次推入 64 个样本，第 j 个样本 = j*1024。
//   于是历史里 hist[i] = (63-i)*1024，代入映射得：
//        q = rel_x[9:3] 时，y_curr = 200 + 2q，y_prev = 198 + 2q  (q>=1)
//   每列应当点亮的像素区间完全可预测，可以逐列核对"两端亮、上下各一格灭"。
//   这条斜坡同时把移位方向、索引方向、>>> 缩放、连线区间一次性钉死。
// =============================================================================
`timescale 1ns / 1ps

module tb_audio_waveform;

    // ---- DUT 参数（与默认值一致，写出来便于断言引用）----------------------
    localparam integer X0       = 64;
    localparam integer X1       = 576;
    localparam integer Y_CENTER = 200;
    localparam integer HIST     = 64;

    // ---- 时钟 --------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #20 clk = ~clk;      // 25MHz 像素时钟

    // ---- DUT 端口 ----------------------------------------------------------
    reg                rst_n;
    reg                audio_valid;
    reg  signed [23:0] audio_sample;
    reg                de;
    reg  [10:0]        active_x;
    reg  [9:0]         active_y;
    reg                wave_en;
    wire               wave_pixel;
    wire [23:0]        wave_rgb;

    audio_waveform u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .audio_valid  (audio_valid),
        .audio_sample (audio_sample),
        .de           (de),
        .active_x     (active_x),
        .active_y     (active_y),
        .wave_en      (wave_en),
        .wave_pixel   (wave_pixel),
        .wave_rgb     (wave_rgb)
    );

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    task ck(input integer cond, input [8*110-1:0] label);
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    task ck_int(input integer got, input integer exp, input [8*110-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s  (%0d)", label, got);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s  (got %0d, expected %0d)", label, got, exp);
            end
        end
    endtask

    // ---- 供 TB 独立复现的 y 映射（不抄 DUT 的实现，按规格重算）-------------
    function integer y_of;
        input signed [15:0] s;
        begin
            y_of = Y_CENTER + (s >>> 9);
        end
    endfunction

    // ---- 推入一个样本（audio_valid 单拍脉冲）------------------------------
    task push_sample(input signed [23:0] s);
        begin
            @(negedge clk);
            audio_sample = s;
            audio_valid  = 1'b1;
            @(negedge clk);
            audio_valid  = 1'b0;
        end
    endtask

    // ---- 探一个像素 --------------------------------------------------------
    task probe(input [10:0] x, input [9:0] y, input integer exp_on,
               input [8*110-1:0] label);
        begin
            active_x = x;
            active_y = y;
            #1;
            checks = checks + 1;
            if (wave_pixel === exp_on[0]) begin
                $display("PASS: %0s  (x=%0d y=%0d %0s)",
                         label, x, y, exp_on ? "ON" : "OFF");
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s  (x=%0d y=%0d got %0s expected %0s)",
                         label, x, y, wave_pixel ? "ON" : "OFF", exp_on ? "ON" : "OFF");
            end
        end
    endtask

    // ---- 全清历史 + 建立基准 ----------------------------------------------
    task clear_state;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer q;
    integer j;
    integer x;
    integer ymin;
    integer ymax;
    integer bad;
    reg signed [15:0] s16;

    initial begin
        $display("=== tb_audio_waveform start ===");
        rst_n        = 1'b0;
        audio_valid  = 1'b0;
        audio_sample = 24'sd0;
        de           = 1'b0;
        active_x     = 11'd0;
        active_y     = 10'd0;
        wave_en      = 1'b0;

        // =====================================================================
        // ① 复位：历史全清、输出恒定颜色、全 0 历史下只有中心线亮
        // =====================================================================
        repeat (5) @(posedge clk);
        #1;
        ck(u_dut.hist[0]  === 16'sd0,       "[reset] hist[0] cleared");
        ck(u_dut.hist[31] === 16'sd0,       "[reset] hist[31] cleared");
        ck(u_dut.hist[63] === 16'sd0,       "[reset] hist[63] cleared");
        ck(wave_rgb === 24'hFF_FF_40,       "[color] wave_rgb is the fixed yellow");

        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 全 0 历史 → y_curr = y_prev = 200，只点亮中心线那一行
        de      = 1'b1;
        wave_en = 1'b1;
        probe(11'd64,  10'd200, 1,          "[reset] center line lit at left edge");
        probe(11'd320, 10'd200, 1,          "[reset] center line lit in the middle");
        probe(11'd575, 10'd200, 1,          "[reset] center line lit at right edge");
        probe(11'd320, 10'd199, 0,          "[reset] row above center is dark");
        probe(11'd320, 10'd201, 0,          "[reset] row below center is dark");

        // =====================================================================
        // ② x 窗口边界：in_window = (x >= 64) && (x < 576)
        // =====================================================================
        probe(11'd63,  10'd200, 0,          "[window] x=63 is left of the window");
        probe(11'd64,  10'd200, 1,          "[window] x=64 is the first column");
        probe(11'd575, 10'd200, 1,          "[window] x=575 is the last column");
        probe(11'd576, 10'd200, 0,          "[window] x=576 is right of the window");
        probe(11'd640, 10'd200, 0,          "[window] x=640 (active area end) is dark");

        // =====================================================================
        // ③ 两级使能门控：de 与 wave_en 都必须为 1
        // =====================================================================
        de = 1'b0;
        probe(11'd320, 10'd200, 0,          "[gate] de=0 blanks the waveform");
        de = 1'b1;
        wave_en = 1'b0;
        probe(11'd320, 10'd200, 0,          "[gate] wave_en=0 blanks the waveform");
        wave_en = 1'b1;
        probe(11'd320, 10'd200, 1,          "[gate] both enables restore the pixel");

        // =====================================================================
        // ④ 移位寄存器语义：hist[0] 最新、hist[63] 最旧、只取高 16 位
        // =====================================================================
        clear_state;
        // 推 3 个可区分样本，检查第 0/1/2 槽与"低 8 位被丢弃"
        push_sample(24'sh12_3456);          // 期望 hist[0] = 16'h1234
        #1;
        ck(u_dut.hist[0] === 16'sh1234,     "[shift] hist[0] takes audio_sample[23:8] (high 16 bits)");
        ck(u_dut.hist[0] !== 16'h3456,      "[shift] low 8 bits are dropped, not used");

        push_sample(24'shAB_CDEF);
        #1;
        ck(u_dut.hist[0] === 16'hABCD,      "[shift] newest sample sits at hist[0]");
        ck(u_dut.hist[1] === 16'h1234,      "[shift] previous sample shifted to hist[1]");

        push_sample(24'sh00_7700);
        #1;
        ck(u_dut.hist[0] === 16'h0077,      "[shift] third sample at hist[0]");
        ck(u_dut.hist[1] === 16'hABCD,      "[shift] second sample at hist[1]");
        ck(u_dut.hist[2] === 16'h1234,      "[shift] first sample at hist[2]");
        ck(u_dut.hist[3] === 16'h0000,      "[shift] untouched slot stays 0");

        // 不带 audio_valid 时不得移位（零阶保持的对称面）
        @(negedge clk);
        audio_sample = 24'shDE_AD00;
        repeat (10) @(posedge clk);
        #1;
        ck(u_dut.hist[0] === 16'h0077,      "[shift] no shift without audio_valid");
        ck(u_dut.hist[1] === 16'hABCD,      "[shift] history untouched without audio_valid");

        // 符号必须保留（有符号 >>> 才能给出负向偏移）
        clear_state;
        push_sample(24'sh80_0000);          // 最负样本 → 高 16 位 16'h8000 = -32768
        #1;
        ck(u_dut.hist[0] === 16'sh8000,     "[shift] most negative sample keeps its sign");
        ck(u_dut.hist[0] < 16'sd0,          "[shift] hist slot is treated as signed");

        // =====================================================================
        // ⑤ y 映射与连线：单样本、相邻两样本
        //    **注意样本量级**：hist 只存 audio_sample[23:8]，所以想让
        //    hist[0] = V，必须送 audio_sample = V << 8。这里要 V=512(+512)，
        //    故送 24'sh02_0000；若按低 16 位的量级送 0x000200，实际只得到
        //    hist=2，y 仍旧是 200 —— 首版就是栽在这个 256 倍的换算上。
        // =====================================================================
        // 全部清 0 后只放一个正样本 → 该列 y_curr=201、y_prev=200（连到中心线）
        clear_state;
        push_sample(24'sh02_0000);          // hist=512 → 512>>>9 = 1 → y=201
        #1;
        ck(u_dut.hist[0] === 16'sd512,      "[ymap] sample 0x020000 stores hist=512");
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), 201,              "[ymap] +512 maps to y = 201");
        // x=575 → idx=0（最新样本），idx_prev=1（全 0 → y=200）
        probe(11'd575, 10'd200, 1,          "[ymap] line reaches back to the center row");
        probe(11'd575, 10'd201, 1,          "[ymap] line reaches the sample row");
        probe(11'd575, 10'd199, 0,          "[ymap] one row above the line is dark");
        probe(11'd575, 10'd202, 0,          "[ymap] one row below the line is dark");

        // 负样本 → 向下（y 减小）
        clear_state;
        push_sample(24'shFE_0000);          // 有符号 -131072 → hist = -512 → y=199
        #1;
        ck(u_dut.hist[0] === -16'sd512,     "[ymap] sample 0xFE0000 stores hist=-512");
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), 199,              "[ymap] -512 maps to y = 199 (above center)");
        probe(11'd575, 10'd199, 1,          "[ymap] negative sample draws above the center");
        probe(11'd575, 10'd200, 1,          "[ymap] negative sample still connects to center");
        probe(11'd575, 10'd201, 0,          "[ymap] nothing drawn below when the sample is negative");

        // 极端幅度：+32767>>>9 = 63 → y=263；-32768>>>9 = -64 → y=136
        clear_state;
        push_sample(24'sh7F_FF00);          // hist = 0x7FFF = 32767
        #1;
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), 263,              "[ymap] full positive amplitude reaches y=263");
        probe(11'd575, 10'd263, 1,          "[ymap] top of swing is lit");
        probe(11'd575, 10'd264, 0,          "[ymap] one row above the swing is dark");

        clear_state;
        push_sample(24'sh80_0000);          // hist = 0x8000 = -32768
        #1;
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), 136,              "[ymap] full negative amplitude reaches y=136");
        probe(11'd575, 10'd136, 1,          "[ymap] bottom of swing is lit");
        probe(11'd575, 10'd135, 0,          "[ymap] one row below the swing is dark");

        // =====================================================================
        // ⑥ 最左列的退化情形：idx == 63 时 idx_prev = idx（没有更旧样本）
        //    这是最容易写错的一处：若误写成 idx+1，会越界读到 hist[64]。
        // =====================================================================
        clear_state;
        // 先推入一个"旧"样本占住 hist[63]，再推 63 个零，让 hist[62] 与 hist[63] 明显不同
        push_sample(24'sh7E_0000);          // hist = +32256 → y = 200+63 = 263，作为最旧样本
        for (j = 0; j < 63; j = j + 1)
            push_sample(24'sd0);
        #1;
        ck(u_dut.hist[63] === 16'sd32256,   "[degenerate] oldest slot holds the far sample");
        ck(u_dut.hist[62] === 16'sd0,       "[degenerate] next slot is zero");

        // x=64 → rel_x=0 → idx=63, idx_prev=63 → 单像素，y=263
        probe(11'd64, 10'd263, 1,           "[degenerate] leftmost column draws the old sample");
        probe(11'd64, 10'd200, 0,           "[degenerate] leftmost column does NOT connect to the next sample");
        probe(11'd64, 10'd262, 0,           "[degenerate] leftmost column is a single pixel (no stretch)");
        // x=72 → rel_x=8 → idx=62(=0, y=200), idx_prev=63(=32256, y=263) → 连 200..263
        probe(11'd72, 10'd200, 1,           "[degenerate] second column starts at the center row");
        probe(11'd72, 10'd263, 1,           "[degenerate] second column connects up to the old sample");
        probe(11'd72, 10'd263, 1,           "[degenerate] second column lights the whole segment");
        probe(11'd72, 10'd231, 1,           "[degenerate] second column lights a pixel mid-segment");
        probe(11'd72, 10'd264, 0,           "[degenerate] second column stops at the old sample");

        // =====================================================================
        // ⑦ 每 8 像素一个样本：同一 q 内 8 列相同，跨过 q 边界才换样本
        //    造一条斜坡：让 hist[0]=j*512 逐拍增长。
        //    因为 hist 只存 sample[23:8]，push_sample(v) 得到 hist = v>>8，
        //    所以送 v = j*131072（即 j*512<<8）才能让 hist[0] = j*512。
        //    最终 hist[i] = (63-i)*512 → y_curr = 200 + (63-i) = 200 + q，完全可预测。
        //    最大值 63*512 = 32256（y=263）落在 480 行内，且 63*131072 = 8257536
        //    未超 24 位有符号上限 8388607，不会溢出。
        // =====================================================================
        for (j = 0; j < HIST; j = j + 1)
            push_sample(j * 131072);
        #1;
        ck(u_dut.hist[0]  === 16'sd32256,   "[ramp] newest slot = 63*512");
        ck(u_dut.hist[63] === 16'sd0,       "[ramp] oldest slot = 0");
        ck(u_dut.hist[32] === 16'sd15872,   "[ramp] middle slot follows the ramp");

        // q=0 段（x=64..71）：idx=63 且 idx_prev=63 → 单像素 y=200
        probe(11'd64,  10'd200, 1,          "[ramp] q=0 column lights y=200");
        probe(11'd71,  10'd200, 1,          "[ramp] q=0 last column still y=200 (8px per sample)");
        probe(11'd71,  10'd201, 0,          "[ramp] q=0 does not stretch (no older neighbour)");
        // q=1 段（x=72..79）：y_curr=201, y_prev=200 → 200..201
        probe(11'd72,  10'd200, 1,          "[ramp] q=1 begins at y=200");
        probe(11'd79,  10'd201, 1,          "[ramp] q=1 ends at y=201");
        probe(11'd79,  10'd202, 0,          "[ramp] q=1 does not reach y=202");
        // q=2 段（x=80..87）：y_curr=202, y_prev=201 → 201..202
        probe(11'd80,  10'd202, 1,          "[ramp] q=2 advances by exactly one row");
        probe(11'd80,  10'd201, 1,          "[ramp] q=2 starts at y=201");
        probe(11'd80,  10'd200, 0,          "[ramp] q=2 does not reach y=200");

        // 全段扫描：64 个 q 段逐列核对 y_min..y_max 亮、两端外各一格灭
        bad = 0;
        for (q = 0; q < HIST; q = q + 1) begin
            x = X0 + 8*q + 3;               // 取该段中间一列，避开段边界
            if (q == 0) begin
                ymin = Y_CENTER;
                ymax = Y_CENTER;
            end else begin
                ymin = Y_CENTER + q - 1;
                ymax = Y_CENTER + q;
            end
            active_x = x;
            active_y = ymin; #1;
            if (wave_pixel !== 1'b1) bad = bad + 1;
            active_y = ymax; #1;
            if (wave_pixel !== 1'b1) bad = bad + 1;
            active_y = ymin - 1; #1;
            if (wave_pixel !== 1'b0) bad = bad + 1;
            active_y = ymax + 1; #1;
            if (wave_pixel !== 1'b0) bad = bad + 1;
        end
        ck_int(bad, 0,                      "[ramp] all 64 columns match y_min..y_max exactly");

        // =====================================================================
        // ⑧ 运行中复位：历史清空、波形回到中心线
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        ck(u_dut.hist[0]  === 16'sd0,       "[mid-reset] hist[0] cleared");
        ck(u_dut.hist[63] === 16'sd0,       "[mid-reset] hist[63] cleared");
        // 复位期间推样本不得写入
        @(negedge clk);
        audio_valid  = 1'b1;
        audio_sample = 24'sh12_3400;
        repeat (4) @(posedge clk);
        #1;
        ck(u_dut.hist[0] === 16'sd0,        "[mid-reset] sample ignored during reset");
        @(negedge clk);
        audio_valid = 1'b0;

        // =====================================================================
        // ⑨ 复位释放后重建
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        de      = 1'b1;
        wave_en = 1'b1;
        probe(11'd320, 10'd200, 1,          "[resume] center line back after reset release");
        push_sample(24'sh04_0000);          // hist = 0x0400 = 1024 → y = 202
        #1;
        ck(u_dut.hist[0] === 16'sd1024,     "[resume] history records again after reset");
        probe(11'd575, 10'd202, 1,          "[resume] new sample is drawn at y=202");
        probe(11'd575, 10'd200, 1,          "[resume] new sample still connects to center");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: audio_waveform");
        else             $display("CHECKS FAILED: audio_waveform");
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("CHECKS FAILED: audio_waveform");
        $finish;
    end

endmodule
