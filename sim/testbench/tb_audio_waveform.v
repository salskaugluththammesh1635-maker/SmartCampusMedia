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
//      y_curr = Y_CENTER + (hist[idx]      >>> Y_SHIFT)
//      y_prev = Y_CENTER + (hist[idx_prev] >>> Y_SHIFT)
//      y_min/y_max 取二者较小/较大，然后
//      wave_pixel = wave_en && de && in_window && (active_y >= y_min) && (active_y <= y_max)
//      → 每列点亮的是 y_min..y_max 的**闭区间**，两端都要亮。
//
//   4) 颜色恒为 24'hFF_FF_40（黄色），与九宫格/电平条区分。
//
// 【本 TB 的核心手法：造一条可精确预测的斜坡】
//   依次推入 64 个样本，第 j 个样本的高 16 位 = min(j, AMP_POS)*Y_STEP（一个像素行），
//   即在 AMP_POS 行处饱和。于是历史里 hist[i] = min(63-i, AMP_POS)*Y_STEP，代入映射得
//   （q = rel_x[9:3] 即第 q 段）：
//        q <= AMP_POS： y_curr = Y_CENTER + q，y_prev = Y_CENTER + q - 1   (q>=1)
//        q  > AMP_POS： y_curr = y_prev = Y_TOP（两个样本同值，退化为单行）
//        q=0 段没有更旧的邻居，退化为单行 y = Y_CENTER
//   ★ 必须饱和：64 个样本各升一整行需要 63*Y_STEP <= 32767，Y_SHIFT=10 时
//     63*1024=64512 会撑爆 16 位有符号历史（也撑爆 24 位有符号的 push_sample 入参），
//     所以在满幅 AMP_POS 处截断。Y_SHIFT=9 时 AMP_POS=63，饱和点刚好在最后一个
//     样本之外，行为与不饱和完全等价 —— 这正是本次改造能在旧参数下保持 76/0 的原因。
//   每列应当点亮的像素区间完全可预测，可以逐列核对"两端亮、上下各一格灭"。
//   这条斜坡同时把移位方向、索引方向、>>> 缩放、连线区间一次性钉死。
// =============================================================================
`timescale 1ns / 1ps

module tb_audio_waveform;

    // ---- DUT 参数（与默认值一致，写出来便于断言引用）----------------------
    localparam integer X0       = 64;
    localparam integer X1       = 576;
    localparam integer Y_CENTER = 408;      // 波形中心线（= DUT 的 parameter Y_CENTER）
    localparam integer Y_SHIFT  = 10;       // 幅度缩放（= DUT 的 parameter Y_SHIFT）
    localparam integer HIST     = 64;

    // 由上面两个参数按定义复算出的规格量。**这些量必须与 DUT 的移位量严格独立**：
    // 改这里不改 RTL 就必须红一片，改 RTL 不改这里也必须红一片 —— 两份字面量分开写
    // 才有交叉验证的意义（从 DUT 读参数等于自己证明自己）。
    localparam integer Y_STEP  = 1 << Y_SHIFT;           // 一个像素行 = 样本高 16 位的倍数
    localparam integer AMP_POS = 32767 >>> Y_SHIFT;      // 正向满幅行数
    localparam integer AMP_NEG = -(32768 >>> Y_SHIFT);   // 负向满幅行数（比正向多 1，向下取整）
    localparam integer Y_TOP   = Y_CENTER + AMP_POS;     // 波形最高行
    localparam integer Y_BOT   = Y_CENTER + AMP_NEG;     // 波形最低行

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
            y_of = Y_CENTER + (s >>> Y_SHIFT);
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
    integer yc;          // 本段当前样本的 y
    integer yp;          // 本段相邻（更旧）样本的 y
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
        probe(11'd64,  Y_CENTER, 1,          "[reset] center line lit at left edge");
        probe(11'd320, Y_CENTER, 1,          "[reset] center line lit in the middle");
        probe(11'd575, Y_CENTER, 1,          "[reset] center line lit at right edge");
        probe(11'd320, Y_CENTER - 1, 0,      "[reset] row above center is dark");
        probe(11'd320, Y_CENTER + 1, 0,      "[reset] row below center is dark");

        // =====================================================================
        // ② x 窗口边界：in_window = (x >= 64) && (x < 576)
        // =====================================================================
        probe(11'd63,  Y_CENTER, 0,          "[window] x=63 is left of the window");
        probe(11'd64,  Y_CENTER, 1,          "[window] x=64 is the first column");
        probe(11'd575, Y_CENTER, 1,          "[window] x=575 is the last column");
        probe(11'd576, Y_CENTER, 0,          "[window] x=576 is right of the window");
        probe(11'd640, Y_CENTER, 0,          "[window] x=640 (active area end) is dark");

        // =====================================================================
        // ③ 两级使能门控：de 与 wave_en 都必须为 1
        // =====================================================================
        de = 1'b0;
        probe(11'd320, Y_CENTER, 0,          "[gate] de=0 blanks the waveform");
        de = 1'b1;
        wave_en = 1'b0;
        probe(11'd320, Y_CENTER, 0,          "[gate] wave_en=0 blanks the waveform");
        wave_en = 1'b1;
        probe(11'd320, Y_CENTER, 1,          "[gate] both enables restore the pixel");

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
        push_sample(Y_STEP * 256);          // hist=Y_STEP → >>>Y_SHIFT = 1 → y = Y_CENTER+1
        #1;
        ck(u_dut.hist[0] === Y_STEP,        "[ymap] one-pixel sample stores hist=Y_STEP");
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), Y_CENTER + 1,     "[ymap] +Y_STEP maps to one row below center");
        // x=575 → idx=0（最新样本），idx_prev=1（全 0 → y=200）
        probe(11'd575, Y_CENTER, 1,          "[ymap] line reaches back to the center row");
        probe(11'd575, Y_CENTER + 1, 1,      "[ymap] line reaches the sample row");
        probe(11'd575, Y_CENTER - 1, 0,      "[ymap] one row above the line is dark");
        probe(11'd575, Y_CENTER + 2, 0,      "[ymap] one row below the line is dark");

        // 负样本 → 向下（y 减小）
        clear_state;
        push_sample(-(Y_STEP * 256));       // 有符号 -Y_STEP → y = Y_CENTER-1
        #1;
        ck(u_dut.hist[0] === -Y_STEP,       "[ymap] negative sample stores hist=-Y_STEP");
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), Y_CENTER - 1,     "[ymap] -Y_STEP maps to one row above center");
        probe(11'd575, Y_CENTER - 1, 1,      "[ymap] negative sample draws above the center");
        probe(11'd575, Y_CENTER, 1,          "[ymap] negative sample still connects to center");
        probe(11'd575, Y_CENTER + 1, 0,      "[ymap] nothing drawn below when the sample is negative");

        // 极端幅度：+32767>>>Y_SHIFT = AMP_POS → Y_TOP；-32768>>>Y_SHIFT = AMP_NEG → Y_BOT
        clear_state;
        push_sample(24'sh7F_FF00);          // hist = 0x7FFF = 32767
        #1;
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), Y_TOP,            "[ymap] full positive amplitude reaches Y_TOP");
        probe(11'd575, Y_TOP, 1,             "[ymap] top of swing is lit");
        probe(11'd575, Y_TOP + 1, 0,         "[ymap] one row above the swing is dark");

        clear_state;
        push_sample(24'sh80_0000);          // hist = 0x8000 = -32768
        #1;
        s16 = u_dut.hist[0];
        ck_int(y_of(s16), Y_BOT,            "[ymap] full negative amplitude reaches Y_BOT");
        probe(11'd575, Y_BOT, 1,             "[ymap] bottom of swing is lit");
        probe(11'd575, Y_BOT - 1, 0,         "[ymap] one row below the swing is dark");

        // =====================================================================
        // ⑥ 最左列的退化情形：idx == 63 时 idx_prev = idx（没有更旧样本）
        //    这是最容易写错的一处：若误写成 idx+1，会越界读到 hist[64]。
        // =====================================================================
        clear_state;
        // 先推入一个"旧"样本占住 hist[63]，再推 63 个零，让 hist[62] 与 hist[63] 明显不同
        push_sample(24'sh7F_FF00);          // hist = +32767（正向满幅）→ y = Y_TOP，作为最旧样本
        // 注：原版送 24'sh7E_0000（hist=32256=63*512）把步长 512 焊进了样本值；
        //     改为正向满幅 +32767 后，两种 Y_SHIFT 下都取到 AMP_POS，样本值不再依赖移位量。
        for (j = 0; j < 63; j = j + 1)
            push_sample(24'sd0);
        #1;
        ck(u_dut.hist[63] === 16'sd32767,   "[degenerate] oldest slot holds the far sample");
        ck(u_dut.hist[62] === 16'sd0,       "[degenerate] next slot is zero");

        // x=64 → rel_x=0 → idx=63, idx_prev=63 → 单像素 y=Y_TOP
        probe(11'd64, Y_TOP, 1,              "[degenerate] leftmost column draws the old sample");
        probe(11'd64, Y_CENTER, 0,           "[degenerate] leftmost column does NOT connect to the next sample");
        probe(11'd64, Y_TOP - 1, 0,          "[degenerate] leftmost column is a single pixel (no stretch)");
        // x=72 → rel_x=8 → idx=62(=0, y=Y_CENTER), idx_prev=63(=32767, y=Y_TOP) → 整段相连
        probe(11'd72, Y_CENTER, 1,           "[degenerate] second column starts at the center row");
        probe(11'd72, Y_TOP, 1,              "[degenerate] second column connects up to the old sample");
        probe(11'd72, Y_TOP, 1,              "[degenerate] second column lights the whole segment");
        probe(11'd72, (Y_CENTER + Y_TOP) / 2, 1, "[degenerate] second column lights a pixel mid-segment");
        probe(11'd72, Y_TOP + 1, 0,          "[degenerate] second column stops at the old sample");

        // =====================================================================
        // ⑦ 每 8 像素一个样本：同一 q 内 8 列相同，跨过 q 边界才换样本
        //    造一条斜坡：让 hist[0] 逐拍增长 min(j, AMP_POS)*Y_STEP。
        //    因为 hist 只存 sample[23:8]，push_sample(v) 得到 hist = v>>8，
        //    所以送 v = min(j, AMP_POS)*Y_STEP*256 才能让 hist[0] = min(j,AMP_POS)*Y_STEP。
        //    最终 hist[i] = min(63-i, AMP_POS)*Y_STEP → 前 AMP_POS 段 y_curr = Y_CENTER + q。
        //    ★ AMP_POS 处必须饱和：Y_SHIFT=10 时 63*Y_STEP = 64512 既超 16 位历史也超
        //      24 位 push_sample 入参；饱和后最大值 AMP_POS*Y_STEP <= 32767 两头都安全
        //      （Y_SHIFT=9：63*512=32256；Y_SHIFT=10：31*1024=31744）。
        // =====================================================================
        for (j = 0; j < HIST; j = j + 1)
            push_sample(((j < AMP_POS) ? j : AMP_POS) * Y_STEP * 256);
        #1;
        ck(u_dut.hist[0]  === ((63 < AMP_POS) ? 63 : AMP_POS) * Y_STEP,
                                            "[ramp] newest slot = min(63,AMP_POS)*Y_STEP");
        ck(u_dut.hist[63] === 16'sd0,       "[ramp] oldest slot = 0");
        ck(u_dut.hist[32] === ((31 < AMP_POS) ? 31 : AMP_POS) * Y_STEP,
                                            "[ramp] middle slot follows the ramp");

        // q=0 段（x=64..71）：idx=63 且 idx_prev=63 → 单像素 y=Y_CENTER
        probe(11'd64,  Y_CENTER, 1,          "[ramp] q=0 column lights the center row");
        probe(11'd71,  Y_CENTER, 1,          "[ramp] q=0 last column still center (8px per sample)");
        probe(11'd71,  Y_CENTER + 1, 0,      "[ramp] q=0 does not stretch (no older neighbour)");
        // q=1 段（x=72..79）：y_curr=Y_CENTER+1, y_prev=Y_CENTER → 连两行
        probe(11'd72,  Y_CENTER, 1,          "[ramp] q=1 begins at the center row");
        probe(11'd79,  Y_CENTER + 1, 1,      "[ramp] q=1 ends one row below center");
        probe(11'd79,  Y_CENTER + 2, 0,      "[ramp] q=1 does not reach two rows below");
        // q=2 段（x=80..87）：y_curr=Y_CENTER+2, y_prev=Y_CENTER+1 → 连两行
        probe(11'd80,  Y_CENTER + 2, 1,      "[ramp] q=2 advances by exactly one row");
        probe(11'd80,  Y_CENTER + 1, 1,      "[ramp] q=2 starts one row below center");
        probe(11'd80,  Y_CENTER, 0,          "[ramp] q=2 does not reach the center row");

        // 全段扫描：64 个 q 段逐列核对 y_min..y_max 亮、两端外各一格灭
        bad = 0;
        for (q = 0; q < HIST; q = q + 1) begin
            x = X0 + 8*q + 3;               // 取该段中间一列，避开段边界
            // 饱和形式统一表达（q > AMP_POS 时两个样本同值 → ymin == ymax）
            yc = Y_CENTER + ((q > AMP_POS) ? AMP_POS : q);
            if (q == 0)
                yp = yc;
            else
                yp = Y_CENTER + (((q - 1) > AMP_POS) ? AMP_POS : (q - 1));
            ymin = (yc < yp) ? yc : yp;
            ymax = (yc > yp) ? yc : yp;
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
        probe(11'd320, Y_CENTER, 1,          "[resume] center line back after reset release");
        push_sample(2 * Y_STEP * 256);      // hist = 2*Y_STEP → y = Y_CENTER+2
        #1;
        ck(u_dut.hist[0] === 2 * Y_STEP,    "[resume] history records again after reset");
        probe(11'd575, Y_CENTER + 2, 1,      "[resume] new sample is drawn two rows below center");
        probe(11'd575, Y_CENTER, 1,          "[resume] new sample still connects to center");

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
