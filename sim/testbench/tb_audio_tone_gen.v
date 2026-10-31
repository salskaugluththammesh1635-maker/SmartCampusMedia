// =============================================================================
// tb_audio_tone_gen.v —— audio_tone_gen 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块的规格】
//   音频发声核心：由播放状态（playback_state）决定音高，产生 48 kHz 的
//   24 位有符号样本流。三件事同时发生：
//     1) 分数分频：sample_acc 累加 SAMPLE_RATE_HZ，溢出 CLK_FREQ_HZ 时
//        产生一拍 sample_en（= 采样使能，等效 48 kHz）
//     2) 相位累加：每个 sample_en 让 phase_acc 加一个 note_inc
//        （inc = f_note / f_sample * 2^32，所以常数表直接决定音高）
//     3) 三角波取形：tri = phase[31] ? ~phase[30:7] : phase[30:7]，
//        中心化后 >>> 2 压幅度
//
//   状态 → 音名映射（本 TB 逐一钉死）：
//     0 IDLE  → 静音（无声）
//     1 SCAN  → C4 (23409862)
//     2 LOAD  → E4 (29494578)
//     3 READY → G4 (35075155)
//     4 AUTO  → 五音循环 C4→D4→E4→F4→G4
//     5 EMERG → hold_cnt[13] ? C5 (46819716) : G4
//     6 FAIL  → 静音（故障时不制造噪音）
//
// 【参数缩放】
//   真实 clk=25MHz、48kHz 采样、0.5s 保持。直接仿真要跑几百万拍，且
//   hold_cnt 是 16 位、bit13（8192）在 EMERG 里用来切 C5/G4，若把
//   NOTE_HOLD_SAMPLES 缩到很小就永远等不到 bit13。
//   所以本例用两个实例分别覆盖两类需求：
//     u_dut  CLK_FREQ_HZ=100 / SAMPLE_RATE_HZ=25 / NOTE_HOLD_SAMPLES=8
//            → 每 4 拍一个样本、每 8 个样本换一个音，适合测节拍与旋律循环
//     u_hold CLK_FREQ_HZ=100 / SAMPLE_RATE_HZ=25 / NOTE_HOLD_SAMPLES=16384
//            → hold_cnt 能真正爬到 bit13 以上，用来测 EMERG 的 C5/G4 交替
//   inc 常数表不随 SAMPLE_RATE_HZ 缩放，因此音高绝对值在缩放后不具物理意义；
//   但"状态选对了哪个 inc""节拍对不对""波形公式对不对"全部照旧可验。
//
// 【相位增量测量法】
//   不窥探 note_idx（那是组合中间量），而是直接测 phase_acc 的增量：
//   增量恒等于当前音符的 note_inc，等于同时验证了"选音正确"与"相位累加正确"。
// =============================================================================
`timescale 1ns / 1ps

module tb_audio_tone_gen;

    localparam CLK_HZ      = 100;    // 缩放后的"像素时钟"
    localparam SMP_HZ      = 25;     // 缩放后的采样率 → 每 4 拍一个样本
    localparam HOLD_FAST   = 8;      // 快速实例：每 8 个样本换音
    localparam HOLD_LONG   = 16384;  // 长保持实例：hold_cnt 能到 bit13 以上
    localparam SMPDIV      = CLK_HZ / SMP_HZ;   // = 4

    // ---- 音名相位增量（与 DUT 的 note_inc 表一致）--------------------------
    localparam [31:0] INC_C4 = 32'd23409862;
    localparam [31:0] INC_D4 = 32'd26276681;
    localparam [31:0] INC_E4 = 32'd29494578;
    localparam [31:0] INC_F4 = 32'd31248410;
    localparam [31:0] INC_G4 = 32'd35075155;
    localparam [31:0] INC_A4 = 32'd39370534;
    localparam [31:0] INC_B4 = 32'd44191930;
    localparam [31:0] INC_C5 = 32'd46819716;

    // ---- 时钟 --------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #20 clk = ~clk;           // 40ns 周期

    // ---- 主实例（快速）-----------------------------------------------------
    reg         rst_n;
    reg  [2:0]  pb_state;
    reg         mute_a;
    wire        audio_valid;
    wire [23:0] audio_left;
    wire [23:0] audio_right;

    audio_tone_gen #(
        .CLK_FREQ_HZ       (CLK_HZ),
        .SAMPLE_RATE_HZ    (SMP_HZ),
        .NOTE_HOLD_SAMPLES (HOLD_FAST)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .playback_state (pb_state),
        .mute           (mute_a),
        .audio_valid    (audio_valid),
        .audio_left     (audio_left),
        .audio_right    (audio_right)
    );

    // ---- 长保持实例（只为 EMERG 的 bit13 分支）-----------------------------
    reg         mute_h;
    wire        audio_valid_h;
    wire [23:0] audio_left_h;
    wire [23:0] audio_right_h;

    audio_tone_gen #(
        .CLK_FREQ_HZ       (CLK_HZ),
        .SAMPLE_RATE_HZ    (SMP_HZ),
        .NOTE_HOLD_SAMPLES (HOLD_LONG)
    ) u_hold (
        .clk            (clk),
        .rst_n          (rst_n),
        .playback_state (3'd5),        // 恒定 EMERG
        .mute           (mute_h),
        .audio_valid    (audio_valid_h),
        .audio_left     (audio_left_h),
        .audio_right    (audio_right_h)
    );

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    task ck(input integer cond, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    task ck_eq(input [31:0] got, input [31:0] exp, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s  (got %0d, expected %0d)", label, got, exp);
            end
        end
    endtask

    // ---- 期望波形（独立于 RTL 的写法，用 32 位整数运算）--------------------
    //   tri_raw = phase[31] ? ~phase[30:7] : phase[30:7]      （24 位无符号）
    //   中心化：tri_raw - 8388608                             （24 位有符号）
    //   压幅度：(tri_centered) >>> 2
    function [23:0] exp_sample;
        input [31:0] phase;
        integer tri_v;          // 注意：不能用 "tri" —— 它是 Verilog 保留字（三态线网）
        integer ctr;
        begin
            if (phase[31]) tri_v = (~phase[30:7]) & 24'hFFFFFF;
            else           tri_v = phase[30:7] & 24'hFFFFFF;
            ctr = tri_v - 8388608;
            exp_sample = ctr >>> 2;     // integer 的 >>> 是算术右移
        end
    endfunction

    function [31:0] inc_of;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: inc_of = INC_C4;
                3'd1: inc_of = INC_D4;
                3'd2: inc_of = INC_E4;
                3'd3: inc_of = INC_F4;
                3'd4: inc_of = INC_G4;
                3'd5: inc_of = INC_A4;
                3'd6: inc_of = INC_B4;
                default: inc_of = INC_C5;
            endcase
        end
    endfunction

    // ---- 主实例监视器（negedge 采样，与 DUT 状态错开一拍）------------------
    //   DUT 在 posedge 寄存，若 TB 也在 posedge 读会拿到更新前的值。
    //   这里做三件事：
    //     1) 把 phase_acc 的每次增量压进 FIFO（供任务按顺序取用）
    //     2) 每个 audio_valid 拍核对 audio_left 是否等于 exp_sample(上一拍的相位)
    //     3) 统计 audio_valid 脉冲宽度 / 左右声道是否恒等
    integer    dq [0:1023];
    integer    dq_head, dq_tail;
    reg [31:0] phase_1;               // 上一拍 negedge 观察到的 phase_acc
    reg [31:0] phase_now;
    integer    audio_valid_w;         // 当前脉冲已连续为高的拍数
    reg        audio_valid_d;
    integer    valid_count;
    integer    wave_bad;
    integer    mono_bad;
    integer    silent_bad;
    integer    expect_silent;         // 1 = 当前状态应当静音

    always @(negedge clk) begin
        if (rst_n) begin
            // ---- 相位增量入队 ----
            // 注意：dq_tail 必须回绕。它若一直自增，超过 1023 后写入被忽略、
            // 读取得到 x，表现为"莫名奇妙的 x 增量"。
            phase_now = u_dut.phase_acc;
            if (phase_now !== phase_1) begin
                dq[dq_tail[9:0]] = phase_now - phase_1;
                dq_tail = (dq_tail + 1) & 10'h3FF;
            end

            // ---- 样本核对 ----
            if (audio_valid === 1'b1) begin
                valid_count = valid_count + 1;
                if (audio_left !== audio_right) mono_bad = mono_bad + 1;
                if (audio_valid_d !== 1'b1) audio_valid_w = 1;
                else audio_valid_w = audio_valid_w + 1;
                if (expect_silent) begin
                    if (audio_left !== 24'sd0 || audio_right !== 24'sd0)
                        silent_bad = silent_bad + 1;
                end else begin
                    if (audio_left !== exp_sample(phase_1)) wave_bad = wave_bad + 1;
                end
            end
            audio_valid_d = audio_valid;

            // ---- 本轮结束，保存相位 ----
            phase_1 = phase_now;
        end else begin
            phase_1       = u_dut.phase_acc;
            audio_valid_d = audio_valid;
            audio_valid_w = 0;
        end
    end

    // ---- 长保持实例监视器：只记录每次相位增量与当时 hold_cnt[13] ----------
    //   注意：相位增量是在 posedge 上算的，此时 hold_cnt 用的是**上一拍**的值
    //   （非阻塞赋值，RHS 取旧值）。所以分类时必须用上一拍 negedge 记下的
    //   bit13，否则在 bit13 跳变的那个样本上必然误判一次。
    reg [31:0] hold_phase_1;
    reg        hold_bit13_1;
    integer    hold_g4_ok;        // bit13=0 时增量是 G4 的次数
    integer    hold_c5_ok;        // bit13=1 时增量是 C5 的次数
    integer    hold_other;        // 出现意外音名的次数

    always @(negedge clk) begin
        if (rst_n) begin
            if (u_hold.phase_acc !== hold_phase_1) begin
                if (hold_bit13_1 === 1'b0) begin
                    if ((u_hold.phase_acc - hold_phase_1) === INC_G4)
                        hold_g4_ok = hold_g4_ok + 1;
                    else begin
                        hold_other = hold_other + 1;
                        if (hold_other <= 3)
                            $display("      [emerg] unexpected delta %0d at bit13_1=%b",
                                     u_hold.phase_acc - hold_phase_1, hold_bit13_1);
                    end
                end else begin
                    if ((u_hold.phase_acc - hold_phase_1) === INC_C5)
                        hold_c5_ok = hold_c5_ok + 1;
                    else begin
                        hold_other = hold_other + 1;
                        if (hold_other <= 3)
                            $display("      [emerg] unexpected delta %0d at bit13_1=%b",
                                     u_hold.phase_acc - hold_phase_1, hold_bit13_1);
                    end
                end
            end
            hold_phase_1 = u_hold.phase_acc;
            hold_bit13_1 = u_hold.hold_cnt[13];
        end else begin
            hold_phase_1 = u_hold.phase_acc;
            hold_bit13_1 = u_hold.hold_cnt[13];
        end
    end

    task flush_dq;
        begin dq_head = dq_tail; end
    endtask

    task get_delta(output [31:0] d);
        begin
            while (dq_head == dq_tail) @(negedge clk);
            d = dq[dq_head[9:0]];
            dq_head = (dq_head + 1) & 10'h3FF;
        end
    endtask

    // 切状态并同步到目标音名：改动输入后队列里可能残留 1 个旧增量，丢掉它
    task setup_state(input [2:0] st, input m, input [31:0] exp,
                     input [8*100-1:0] label);
        integer g;
        reg [31:0] d;
        reg        ok;
        begin
            @(negedge clk);
            pb_state = st;
            mute_a   = m;
            ok = 1'b0;
            g  = 0;
            while (g < 24 && !ok) begin
                get_delta(d);
                g = g + 1;
                if (d === exp) ok = 1'b1;
            end
            ck(ok, label);
        end
    endtask

    // AUTO 专用的柔性入口：melody_idx 是**连续**运行的（不随状态复位），
    // 进入 AUTO 时它可能停在任何音名上，所以不能断言入口是 C4。
    // 这里只要求第一个增量是五音之一，并把该音名回填给 out_d。
    task setup_auto(input [2:0] st, input m, output [31:0] out_d);
        integer g;
        reg [31:0] d;
        reg        ok;
        begin
            @(negedge clk);
            pb_state = st;
            mute_a   = m;
            ok = 1'b0;
            g  = 0;
            out_d = 32'd0;
            while (g < 24 && !ok) begin
                get_delta(d);
                g = g + 1;
                if (d === INC_C4 || d === INC_D4 || d === INC_E4 ||
                    d === INC_F4 || d === INC_G4) begin
                    ok    = 1'b1;
                    out_d = d;
                end
            end
            ck(ok, "[auto] entering melody lands on one of the five notes");
        end
    endtask

    // 连续取 n 个增量，全须等于 exp
    task expect_n_delta(input integer n, input [31:0] exp, input [8*100-1:0] label);
        integer t;
        integer bad;
        reg [31:0] d;
        begin
            bad = 0;
            for (t = 0; t < n; t = t + 1) begin
                get_delta(d);
                if (d !== exp) begin
                    bad = bad + 1;
                    if (bad <= 2) $display("      delta[%0d] got %0d expected %0d", t, d, exp);
                end
            end
            ck_eq(bad, 0, label);
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    integer g;
    integer n_ok;
    reg [31:0] d;
    reg [31:0] prev_d;
    reg [31:0] run_exp;
    integer    run_len;
    integer    trans_bad;
    integer    transition_count;

    initial begin
        $display("=== tb_audio_tone_gen start (SMPDIV=%0d HOLD_FAST=%0d) ===",
                 SMPDIV, HOLD_FAST);
        dq_head = 0; dq_tail = 0;
        phase_1 = 0; phase_now = 0;
        audio_valid_w = 0; audio_valid_d = 1'b0;
        valid_count = 0; wave_bad = 0; mono_bad = 0; silent_bad = 0;
        expect_silent = 1'b1;
        hold_phase_1 = 0; hold_g4_ok = 0; hold_c5_ok = 0; hold_other = 0;

        rst_n    = 1'b0;
        pb_state = 3'd0;
        mute_a   = 1'b0;
        mute_h   = 1'b0;

        // =====================================================================
        // ① 复位值
        // =====================================================================
        repeat (5) @(posedge clk);
        #1;
        ck(audio_valid === 1'b0,            "[reset] audio_valid low");
        ck(audio_left  === 24'sd0,          "[reset] audio_left zero");
        ck(audio_right === 24'sd0,          "[reset] audio_right zero");
        ck(u_dut.phase_acc === 32'd0,       "[reset] phase_acc cleared");
        ck(u_dut.hold_cnt  === 16'd0,       "[reset] hold_cnt cleared");
        ck(u_dut.melody_idx === 3'd0,       "[reset] melody_idx cleared");

        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        flush_dq;

        // =====================================================================
        // ② 采样节拍：CLK_FREQ_HZ=100、SAMPLE_RATE_HZ=25 → 每 4 拍一个样本
        //    统计 40 拍里 audio_valid 为高的次数必须恰好 10 次
        // =====================================================================
        begin : cadence
            integer hits;
            integer t;
            hits = 0;
            for (t = 0; t < 40; t = t + 1) begin
                @(negedge clk);
                if (audio_valid === 1'b1) hits = hits + 1;
            end
            ck_eq(hits, 40 / SMPDIV,        "[cadence] one audio_valid per 4 clocks (10 in 40)");
        end

        // =====================================================================
        // ③ 状态 0 IDLE：静音
        // =====================================================================
        setup_state(3'd0, 1'b0, INC_C4,     "[idle] phase still advances with C4 inc");
        expect_silent = 1'b1;
        flush_dq;
        repeat (5 * SMPDIV) @(posedge clk);
        @(negedge clk);
        ck_eq(silent_bad, 0,                "[idle] audio_left/right are exactly zero");
        ck_eq(mono_bad,   0,                "[idle] left == right (mono)");

        // =====================================================================
        // ④ 状态 6 FAIL：同样必须静音
        // =====================================================================
        setup_state(3'd6, 1'b0, INC_C4,     "[fail] phase advances (C4 default inc)");
        expect_silent = 1'b1;
        repeat (6 * SMPDIV) @(posedge clk);
        @(negedge clk);
        ck_eq(silent_bad, 0,                "[fail] still silent in FAIL state");

        // =====================================================================
        // ⑤ 1 SCAN → C4；2 LOAD → E4；3 READY → G4
        //    这三条一起验证"状态选音"与常数表
        // =====================================================================
        expect_silent = 1'b0;
        setup_state(3'd1, 1'b0, INC_C4,     "[scan] note is C4 (23409862)");
        expect_n_delta(6, INC_C4,           "[scan] C4 phase increment stable over 6 samples");

        setup_state(3'd2, 1'b0, INC_E4,     "[load] note is E4 (29494578)");
        expect_n_delta(6, INC_E4,           "[load] E4 phase increment stable over 6 samples");

        setup_state(3'd3, 1'b0, INC_G4,     "[ready] note is G4 (35075155)");
        expect_n_delta(6, INC_G4,           "[ready] G4 phase increment stable over 6 samples");

        // =====================================================================
        // ⑥ 三角波波形：audio_left 必须等于 exp_sample(上一拍相位)
        //    （已在监视器里每个样本都核对，这里只要确认样本够多且零错）
        // =====================================================================
        @(negedge clk);
        ck(wave_bad === 0,                  "[wave] every sample matches triangle formula");
        ck(valid_count > 20,                "[wave] enough samples inspected (>20)");

        // 幅度上下界：|sample| <= 8388608/4 = 2097152
        // 注意：audio_left 声明为 wire [23:0]，是**无符号**的。直接拿它和
        // 负的 24 位常量比较会退化成无符号比较（负数变成接近 2^24 的大数），
        // 从而把每一个负样本都误判成越界。必须先做符号扩展再比较。
        begin : bounds
            integer t;
            integer over;
            integer av;
            over = 0;
            for (t = 0; t < 60; t = t + 1) begin
                @(negedge clk);
                if (audio_valid === 1'b1) begin
                    if (audio_left[23]) av = audio_left - 16777216;
                    else                av = audio_left;
                    if (av > 2097152 || av < -2097152) over = over + 1;
                end
            end
            ck_eq(over, 0,                  "[wave] amplitude stays within +/-2097152");
        end

        // =====================================================================
        // ⑦ 静音键（mute）优先级最高：状态 3（G4）本应响，mute=1 必须为 0
        // =====================================================================
        setup_state(3'd3, 1'b1, INC_G4,     "[mute] phase keeps running while muted");
        expect_silent = 1'b1;
        repeat (6 * SMPDIV) @(posedge clk);
        @(negedge clk);
        ck_eq(silent_bad, 0,                "[mute] mute forces zero output in READY state");
        expect_silent = 1'b0;
        setup_state(3'd3, 1'b0, INC_G4,     "[mute] unmute restores G4 phase increments");

        // =====================================================================
        // ⑧ 状态 4 AUTO：五音循环 C4→D4→E4→F4→G4→C4
        //    每音保持 NOTE_HOLD_SAMPLES(=8) 个样本。
        //
        //    关键：melody_idx 与 hold_cnt 都**不随状态复位**，只受 note_tick
        //    驱动自增。而上一个用例（EMERG）用的音恰好也是 G4，若直接切到
        //    AUTO，观测到的第一段 G4 会把"EMERG 尾巴 + AUTO 开头"连起来算，
        //    游程长度变成 19 而非 8。所以这里先复位，让 melody_idx/hold_cnt
        //    都从 0 起，AUTO 才能从 C4 开始、每段都是完整 8 个样本。
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        phase_1 = u_dut.phase_acc;
        flush_dq;

        setup_auto(3'd4, 1'b0, run_exp);
        expect_silent = 1'b0;
        begin : melody
            integer k;
            integer ok_runs;
            prev_d      = run_exp;
            run_len     = 0;
            trans_bad   = 0;
            transition_count = 0;
            ok_runs     = 0;
            for (k = 0; k < 64; k = k + 1) begin
                get_delta(d);
                if (d === prev_d) begin
                    run_len = run_len + 1;
                end else begin
                    // 换音了：检查游程长度与环序
                    if (run_len > HOLD_FAST) begin
                        trans_bad = trans_bad + 1;
                        $display("      [auto] run too long: prev=%0d next=%0d len=%0d",
                                 prev_d, d, run_len);
                    end
                    transition_count = transition_count + 1;
                    case (prev_d)
                        INC_C4: if (d !== INC_D4) begin
                                    trans_bad = trans_bad + 1;
                                    $display("      [auto] bad trans C4->%0d (len=%0d)", d, run_len);
                                end
                        INC_D4: if (d !== INC_E4) begin
                                    trans_bad = trans_bad + 1;
                                    $display("      [auto] bad trans D4->%0d (len=%0d)", d, run_len);
                                end
                        INC_E4: if (d !== INC_F4) begin
                                    trans_bad = trans_bad + 1;
                                    $display("      [auto] bad trans E4->%0d (len=%0d)", d, run_len);
                                end
                        INC_F4: if (d !== INC_G4) begin
                                    trans_bad = trans_bad + 1;
                                    $display("      [auto] bad trans F4->%0d (len=%0d)", d, run_len);
                                end
                        INC_G4: if (d !== INC_C4) begin
                                    trans_bad = trans_bad + 1;
                                    $display("      [auto] bad trans G4->%0d (len=%0d)", d, run_len);
                                end
                        default: begin
                                    trans_bad = trans_bad + 1;
                                    $display("      [auto] bad prev %0d -> %0d (len=%0d)",
                                             prev_d, d, run_len);
                                end
                    endcase
                    if (run_len == HOLD_FAST) ok_runs = ok_runs + 1;
                    run_len = 1;
                    prev_d  = d;
                end
            end
            ck(transition_count >= 5,       "[auto] at least 5 note changes within 64 samples");
            ck_eq(trans_bad, 0,             "[auto] note order is C4>D4>E4>F4>G4>C4");
            ck(ok_runs >= 4,                "[auto] full-length runs equal NOTE_HOLD_SAMPLES(8)");
        end

        // =====================================================================
        // ⑨ EMERG 的 G4 半边（快速实例 hold_cnt 到不了 bit13，永远是 G4）
        // =====================================================================
        setup_state(3'd5, 1'b0, INC_G4,     "[emerg] fast instance: hold_cnt[13]=0 -> G4");
        expect_n_delta(6, INC_G4,           "[emerg] G4 stays while hold_cnt < 8192");

        // 长保持实例：bit13 在 8192 个样本后置位，音名应切到 C5
        // 期间（bit13=0）增量必须一直是 G4，置位后必须一直是 C5。
        $display("      waiting hold_cnt[13] on long-hold instance (8192 samples)...");
        g = 0;
        while (u_hold.hold_cnt[13] !== 1'b1 && g < 200000) begin
            @(negedge clk);
            g = g + 1;
        end
        ck(u_hold.hold_cnt[13] === 1'b1,    "[emerg] long-hold instance reached hold_cnt[13]");
        ck(hold_g4_ok > 1000,               "[emerg] long-hold: G4 increments before bit13");
        ck_eq(hold_other, 0,                "[emerg] long-hold: no unexpected note before bit13");

        // 等 bit13 段跑够采样数，再检查 C5
        repeat (40 * SMPDIV) @(posedge clk);
        ck(hold_c5_ok > 5,                  "[emerg] long-hold: C5 increments after bit13");
        ck_eq(hold_other, 0,                "[emerg] long-hold: no unexpected note after bit13");
        ck(audio_left_h === audio_right_h || audio_valid_h !== 1'b1,
                                            "[emerg] long-hold output is mono");
        ck_eq(hold_c5_ok > 5 ? 1 : 0, 1,
                                            "[emerg] long-hold: C5 branch exercised");

        // =====================================================================
        // ⑩ 运行中复位：输出清零、相位与保持计数归零
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        ck(audio_valid === 1'b0,            "[mid-reset] audio_valid cleared");
        ck(audio_left  === 24'sd0,          "[mid-reset] audio_left cleared");
        ck(u_dut.phase_acc  === 32'd0,      "[mid-reset] phase_acc cleared");
        ck(u_dut.hold_cnt   === 16'd0,      "[mid-reset] hold_cnt cleared");
        // 复位期间即使状态要求发声，也不能有 valid
        pb_state = 3'd3;
        mute_a   = 1'b0;
        repeat (10) @(posedge clk);
        #1;
        ck(audio_valid === 1'b0,            "[mid-reset] no audio_valid while reset asserted");
        ck(audio_left  === 24'sd0,          "[mid-reset] no sample data while reset asserted");

        // =====================================================================
        // ⑪ 复位释放后恢复发声
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        // 注意：复位释放后 phase_acc 从 0 重新开始，监视器里的 phase_1 必须
        // 同步到当前值，否则第一个增量是"0 - 旧相位"的垃圾值。
        @(negedge clk);
        phase_1 = u_dut.phase_acc;
        flush_dq;
        expect_silent = 1'b0;
        setup_state(3'd3, 1'b0, INC_G4,     "[resume] G4 tone returns after reset release");
        expect_n_delta(6, INC_G4,           "[resume] increments stable after reset");
        @(negedge clk);
        ck_eq(wave_bad, 0,                  "[resume] waveform still matches formula");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: audio_tone_gen");
        else             $display("CHECKS FAILED: audio_tone_gen");
        $finish;
    end

    initial begin
        #3000000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("CHECKS FAILED: audio_tone_gen");
        $finish;
    end

endmodule
