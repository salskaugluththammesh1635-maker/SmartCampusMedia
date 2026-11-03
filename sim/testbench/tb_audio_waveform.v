// =============================================================================
// tb_audio_waveform.v —— audio_waveform 的单元测试
// -----------------------------------------------------------------------------
// 【★ t6 改造：本 tb 的规格随 RTL 一起变了】
//   旧规格: hist 存 16 bit（只取 audio_sample[23:8]）、Y_SHIFT=10。
//           两级右移合计 18 位 ⇒ 满幅 16bit WAV 样本只得到 0 行偏移、
//           tone_gen 也只有 ±8 行 —— 上板表现为"全程没有音频可视化"。
//   新规格: hist 存 **24 bit 全精度**、Y_SHIFT=18（单级）。
//           24 bit 满幅 8 388 607 >>> 18 = 31 行，负向 -8 388 608 >>> 18 = -32 行，
//           即 y ∈ [408-32, 408+31] = [376, 439]，与 video_overlay 里
//           波形层注释承诺的窗口完全一致。
//   为什么必须同步改本 tb：旧断言把"符号扩展/截高 16 位"当成了规格
//   （例如 `hist[0] === 16'sh1234`、`push_sample(Y_STEP*256)`），
//   规格变了还留着它们，就会把正确的 RTL 判成失败，反过来掩盖真问题。
//   除了把旧断言搬到新规格，本 tb **新增两条量级断言**（见文末 ⑩）：
//     ① 满幅 24bit 正弦 → 波形高度 ≥ ±30 行（直接验证"看得见"）
//     ② 16bit WAV 左对齐后的样本 → 波形高度 ≥ ±10 行（验证 F3+F4 协同）
//   这两条是 t2 报告 §5.2 要求的，也是"用户到底能不能看见波形"的判据。
//
// 【被测模块的语义（逐条对应 rtl/video/audio_waveform.v）】
//
//   1) 历史移位寄存器（hist / 移位块）
//      hist 是 64 个 **24 bit** 有符号槽。只在 audio_valid 单拍时移位：
//          for (i=63; i>0; i=i-1) hist[i] <= hist[i-1];
//          hist[0] <= audio_sample;              ← 全 24 位，不截位
//      → hist[0] 是最新样本，hist[63] 是最旧样本；
//      → **全精度入史**是本轮修复的关键：截掉低 8 位再叠一个大的 Y_SHIFT
//        就等于把幅度压两遍（旧版正是如此）。
//
//   2) x 方向映射
//      in_window = (active_x >= X0=64) && (active_x < X1=576)
//      rel_x     = active_x - 64                   （0..511）
//      idx       = 63 - rel_x[9:3]
//      → **每 8 个像素对应一个历史样本**，同一个 q=rel_x[9:3] 内 8 列共用 idx；
//      → 左边（x=64）用 idx=63 最旧样本，右边（x=575）用 idx=0 最新样本。
//
//   3) 相邻样本连线
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
//   依次推入 64 个样本，第 j 个样本 = min(j, AMP_POS)*Y_STEP（一个像素行），
//   即在 AMP_POS 行处饱和。于是历史里 hist[i] = min(63-i, AMP_POS)*Y_STEP，代入映射得
//   （q = rel_x[9:3] 即第 q 段）：
//        q <= AMP_POS： y_curr = Y_CENTER + q，y_prev = Y_CENTER + q - 1   (q>=1)
//        q  > AMP_POS： y_curr = y_prev = Y_TOP（两个样本同值，退化为单行）
//        q=0 段没有更旧的邻居，退化为单行 y = Y_CENTER
//   ★ 必须饱和：Y_SHIFT=18 时一个像素行 = 262 144，63 行需要 16 515 072，
//     已超 24 bit 有符号满幅（8 388 607），所以必须在 AMP_POS(=31) 处截断。
//   每列应当点亮的像素区间完全可预测，可以逐列核对"两端亮、上下各一格灭"。
//   这条斜坡同时把移位方向、索引方向、>>> 缩放、连线区间一次性钉死。
// =============================================================================
`timescale 1ns / 1ps

module tb_audio_waveform;

    // ---- DUT 参数（与默认值一致，写出来便于断言引用）----------------------
    localparam integer X0       = 64;
    localparam integer X1       = 576;
    localparam integer Y_CENTER = 408;      // 波形中心线（= DUT 的 parameter Y_CENTER）
    localparam integer Y_SHIFT  = 18;       // 幅度缩放（= DUT 的 parameter Y_SHIFT）
    localparam integer HIST     = 64;

    // 由上面两个参数按定义复算出的规格量。**这些量必须与 DUT 的移位量严格独立**：
    // 改这里不改 RTL 就必须红一片，改 RTL 不改这里也必须红一片 —— 两份字面量分开写
    // 才有交叉验证的意义（从 DUT 读参数等于自己证明自己）。
    localparam integer Y_STEP  = 1 << Y_SHIFT;            // 一个像素行 = 样本量级
    localparam integer AMP_POS = (2**23 - 1) >>> Y_SHIFT; // 正向满幅行数 = 31
    localparam integer AMP_NEG = -(2**23 >>> Y_SHIFT);    // 负向满幅行数 = -32
    localparam integer Y_TOP   = Y_CENTER + AMP_POS;      // 波形最高行 = 439
    localparam integer Y_BOT   = Y_CENTER + AMP_NEG;      // 波形最低行 = 376

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
    //   ★ t6：入参从 16 bit 提到 24 bit —— hist 现在存全精度样本。
    function integer y_of;
        input signed [23:0] s;
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
    reg signed [23:0] s24;      // ★ t6：hist 现在是 24 bit，取样也要 24 bit
    integer span_hi;
    integer span_lo;
    integer ytmp;

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
        ck(u_dut.hist[0]  === 24'sd0,       "[reset] hist[0] cleared");
        ck(u_dut.hist[31] === 24'sd0,       "[reset] hist[31] cleared");
        ck(u_dut.hist[63] === 24'sd0,       "[reset] hist[63] cleared");
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
        // ④ 移位寄存器语义：hist[0] 最新、hist[63] 最旧、**全 24 位入史**
        //    ★ t6：旧断言是 `hist[0] === 16'sh1234`（证明低 8 位被丢弃）；
        //      新规格要求低 8 位**保留**，断言必须反过来 —— 这正是本轮修复的核心，
        //      留着旧断言会把正确的 RTL 判成失败。
        // =====================================================================
        clear_state;
        // 推 3 个可区分样本，检查第 0/1/2 槽与"全 24 位都保留"
        push_sample(24'sh12_3456);          // 期望 hist[0] = 24'h123456（全保留）
        #1;
        ck(u_dut.hist[0] === 24'sh123456,   "[shift] hist[0] keeps all 24 bits of audio_sample");
        ck(u_dut.hist[0] !== 24'sh001234,   "[shift] high bits not shifted down (no [23:8] truncation)");

        push_sample(24'shAB_CDEF);
        #1;
        ck(u_dut.hist[0] === 24'shABCDEF,   "[shift] newest sample sits at hist[0]");
        ck(u_dut.hist[1] === 24'sh123456,   "[shift] previous sample shifted to hist[1]");

        push_sample(24'sh00_7700);
        #1;
        ck(u_dut.hist[0] === 24'sh007700,   "[shift] third sample at hist[0]");
        ck(u_dut.hist[1] === 24'shABCDEF,   "[shift] second sample at hist[1]");
        ck(u_dut.hist[2] === 24'sh123456,   "[shift] first sample at hist[2]");
        ck(u_dut.hist[3] === 24'sd0,        "[shift] untouched slot stays 0");

        // 不带 audio_valid 时不得移位（零阶保持的对称面）
        @(negedge clk);
        audio_sample = 24'shDE_AD00;
        repeat (10) @(posedge clk);
        #1;
        ck(u_dut.hist[0] === 24'sh007700,   "[shift] no shift without audio_valid");
        ck(u_dut.hist[1] === 24'shABCDEF,   "[shift] history untouched without audio_valid");

        // 符号必须保留（有符号 >>> 才能给出负向偏移）
        clear_state;
        push_sample(24'sh80_0000);          // 最负样本 → 24'sh800000 = -8 388 608
        #1;
        ck(u_dut.hist[0] === 24'sh800000,   "[shift] most negative sample keeps its sign");
        ck(u_dut.hist[0] < 24'sd0,          "[shift] hist slot is treated as signed");

        // =====================================================================
        // ⑤ y 映射与连线：单样本、相邻两样本
        //    ★ t6：hist 现在存全 24 位，push_sample(v) 得到 hist = v，
        //      不再需要旧的 *256 换算（那段 *256 是"只存高 16 位"时代的产物）。
        // =====================================================================
        // 全部清 0 后只放一个正样本 → 该列 y_curr=Y_CENTER+1、y_prev=Y_CENTER（连到中心线）
        clear_state;
        push_sample(Y_STEP);                // hist=Y_STEP → >>>Y_SHIFT = 1 → y = Y_CENTER+1
        #1;
        ck(u_dut.hist[0] === Y_STEP,        "[ymap] one-pixel sample stores hist=Y_STEP");
        s24 = u_dut.hist[0];
        ck_int(y_of(s24), Y_CENTER + 1,     "[ymap] +Y_STEP maps to one row below center");
        // x=575 → idx=0（最新样本），idx_prev=1（全 0 → y=Y_CENTER）
        probe(11'd575, Y_CENTER, 1,          "[ymap] line reaches back to the center row");
        probe(11'd575, Y_CENTER + 1, 1,      "[ymap] line reaches the sample row");
        probe(11'd575, Y_CENTER - 1, 0,      "[ymap] one row above the line is dark");
        probe(11'd575, Y_CENTER + 2, 0,      "[ymap] one row below the line is dark");

        // 负样本 → 向上（y 减小）
        clear_state;
        push_sample(-(Y_STEP));             // 有符号 -Y_STEP → y = Y_CENTER-1
        #1;
        ck(u_dut.hist[0] === -Y_STEP,       "[ymap] negative sample stores hist=-Y_STEP");
        s24 = u_dut.hist[0];
        ck_int(y_of(s24), Y_CENTER - 1,     "[ymap] -Y_STEP maps to one row above center");
        probe(11'd575, Y_CENTER - 1, 1,      "[ymap] negative sample draws above the center");
        probe(11'd575, Y_CENTER, 1,          "[ymap] negative sample still connects to center");
        probe(11'd575, Y_CENTER + 1, 0,      "[ymap] nothing drawn below when the sample is negative");

        // 极端幅度：24bit 满幅 >>>Y_SHIFT = AMP_POS / AMP_NEG → Y_TOP / Y_BOT
        clear_state;
        push_sample(24'sh7F_FFFF);          // 最大正样本 = 8 388 607
        #1;
        s24 = u_dut.hist[0];
        ck_int(y_of(s24), Y_TOP,            "[ymap] full positive amplitude reaches Y_TOP");
        probe(11'd575, Y_TOP, 1,             "[ymap] top of swing is lit");
        probe(11'd575, Y_TOP + 1, 0,         "[ymap] one row above the swing is dark");

        clear_state;
        push_sample(24'sh80_0000);          // 最小负样本 = -8 388 608
        #1;
        s24 = u_dut.hist[0];
        ck_int(y_of(s24), Y_BOT,            "[ymap] full negative amplitude reaches Y_BOT");
        probe(11'd575, Y_BOT, 1,             "[ymap] bottom of swing is lit");
        probe(11'd575, Y_BOT - 1, 0,         "[ymap] one row below the swing is dark");

        // =====================================================================
        // ⑥ 最左列的退化情形：idx == 63 时 idx_prev = idx（没有更旧样本）
        //    这是最容易写错的一处：若误写成 idx+1，会越界读到 hist[64]。
        // =====================================================================
        clear_state;
        // 先推入一个"旧"样本占住 hist[63]，再推 63 个零，让 hist[62] 与 hist[63] 明显不同
        push_sample(24'sh7F_FFFF);          // 24bit 满幅正 → y = Y_TOP，作为最旧样本
        // 注：原版送 24'sh7E_0000（hist=32256=63*512）把步长 512 焊进了样本值；
        //     改为 24bit 满幅后，样本值不再依赖移位量。
        for (j = 0; j < 63; j = j + 1)
            push_sample(24'sd0);
        #1;
        ck(u_dut.hist[63] === 24'sh7FFFFF,  "[degenerate] oldest slot holds the far sample");
        ck(u_dut.hist[62] === 24'sd0,       "[degenerate] next slot is zero");

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
        //    ★ t6：hist 现在存**全 24 位**，push_sample(v) 得到 hist = v，
        //      不再需要旧版的 `* 256`（那是"只存 [23:8]"时代的换算）。
        //    最终 hist[i] = min(63-i, AMP_POS)*Y_STEP → 前 AMP_POS 段 y_curr = Y_CENTER + q。
        //    ★ AMP_POS 处必须饱和：AMP_POS*Y_STEP = 31*262144 = 8 126 464，
        //      在 24 位有符号范围内（< 8 388 607），不会溢出；
        //      而 63*Y_STEP = 16 515 072 会溢出，所以必须饱和。
        // =====================================================================
        for (j = 0; j < HIST; j = j + 1)
            push_sample(((j < AMP_POS) ? j : AMP_POS) * Y_STEP);
        #1;
        ck(u_dut.hist[0]  === ((63 < AMP_POS) ? 63 : AMP_POS) * Y_STEP,
                                            "[ramp] newest slot = min(63,AMP_POS)*Y_STEP");
        ck(u_dut.hist[63] === 24'sd0,       "[ramp] oldest slot = 0");
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
        ck(u_dut.hist[0]  === 24'sd0,       "[mid-reset] hist[0] cleared");
        ck(u_dut.hist[63] === 24'sd0,       "[mid-reset] hist[63] cleared");
        // 复位期间推样本不得写入
        @(negedge clk);
        audio_valid  = 1'b1;
        audio_sample = 24'sh12_3400;
        repeat (4) @(posedge clk);
        #1;
        ck(u_dut.hist[0] === 24'sd0,        "[mid-reset] sample ignored during reset");
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
        push_sample(2 * Y_STEP);            // hist = 2*Y_STEP → y = Y_CENTER+2
        #1;
        ck(u_dut.hist[0] === 2 * Y_STEP,    "[resume] history records again after reset");
        probe(11'd575, Y_CENTER + 2, 1,      "[resume] new sample is drawn two rows below center");
        probe(11'd575, Y_CENTER, 1,          "[resume] new sample still connects to center");

        // =====================================================================
        // ⑩ 【t6 新增】量级断言 —— 本轮修复的核心可测目标
        //    旧实现（hist 只存 [23:8] + Y_SHIFT=10）的问题不是"波形画得难看"，
        //    而是**幅度被 256 倍压成一条直线**：16bit WAV 满幅只得到 1 行。
        //    这两条断言直接测"能画出多少行"，任何把幅度重新压回去的改动都会红。
        // =====================================================================
        // ⑩-1 满幅 24 bit 正弦（±8 388 607，即音频通路的 tone_gen / 左对齐 WAV）
        //      期望跨度 ≥ ±30 行（Y_SHIFT=18 时理论值 ±31/-32，取 30 留 1 行余量）
        clear_state;
        de      = 1'b0;                      // 采集期间关掉 de，避免 probe 干扰
        span_hi = -32768;
        span_lo =  32767;
        for (j = 0; j < HIST; j = j + 1) begin
            // 用一个简单三角波扫过全量程，确保正负两端都被采到
            // 注意：中点用 24'sd8388607 而不是 -(24'sh800000)，
            //      后者在 24 bit 有符号里会溢出（+8 388 608 > 最大值 8 388 607）。
            if (j < (HIST/2))
                s24 = (24'sd8388607 * (j + 1)) / (HIST/2);
            else
                s24 = -(24'sd8388607 * ((j - HIST/2) + 1) / (HIST - HIST/2));
            push_sample(s24);
        end
        #1;
        // 用 hist 数组复算理论 y 范围（独立于 DUT 的组合逻辑）
        span_hi = -32768;
        span_lo =  32767;
        for (j = 0; j < HIST; j = j + 1) begin
            ytmp = Y_CENTER + (u_dut.hist[j] >>> Y_SHIFT);
            if (ytmp > span_hi) span_hi = ytmp;
            if (ytmp < span_lo) span_lo = ytmp;
        end
        $display("[magnitude] full-scale 24bit swing: y from %0d to %0d (span=%0d rows)",
                 span_lo, span_hi, span_hi - span_lo + 1);
        ck((span_hi - Y_CENTER) >= 30,       "[magnitude] full-scale 24bit reaches >= +30 rows");
        ck((Y_CENTER - span_lo) >= 30,       "[magnitude] full-scale 24bit reaches <= -30 rows");

        // ⑩-2 16 bit WAV 经 F3 左对齐（sample = raw16 << 8）后的实际幅度
        //      素材实测峰值：BGM 19953、NARR 29162、ALARM 23260
        //      左对齐后 = 19953<<8 = 5 108 号 …>>>18 = 19 行；29162<<8>>>18 = 28 行
        //      断言"最响的那一份（NARR）≥ 25 行"，即"用户能看出摆动"
        clear_state;
        s24 = 24'sd29162 <<< 8;             // NARR 峰值左对齐 = 7 465 472
        for (j = 0; j < HIST; j = j + 1)
            push_sample(s24);
        #1;
        ytmp = Y_CENTER + (u_dut.hist[0] >>> Y_SHIFT);
        $display("[magnitude] NARR peak after F3 left-align: sample=%0d y_off=%0d",
                 u_dut.hist[0], ytmp - Y_CENTER);
        ck((ytmp - Y_CENTER) >= 25,          "[magnitude] NARR peak after left-align reaches >= 25 rows");

        // ⑩-3 反证：若把样本按 16bit 原样符号扩展（F3 未修的状态），幅度必须塌到 1 行
        //      这条防止有人把 F3 改回去却仍让 ⑩-2 通过
        clear_state;
        s24 = 24'sd29162;                   // = 29162（16bit 原样，未左移 8 位）
        for (j = 0; j < HIST; j = j + 1)
            push_sample(s24);
        #1;
        ytmp = Y_CENTER + (u_dut.hist[0] >>> Y_SHIFT);
        $display("[magnitude] NARR peak WITHOUT left-align (regression guard): y_off=%0d",
                 ytmp - Y_CENTER);
        ck((ytmp - Y_CENTER) <= 1,           "[magnitude] un-aligned 16bit signal collapses to <= 1 row (guards F3)");
        de = 1'b1;

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
