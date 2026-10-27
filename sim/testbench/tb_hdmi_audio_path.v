// =============================================================================
// tb_hdmi_audio_path.v —— HDMI 音频嵌入通路的联合单元测试
// -----------------------------------------------------------------------------
// 【测什么】
//   本工程把音频嵌进 HDMI 靠三个自写模块接力（audio_tone_gen → audio_arc、
//   audio_tone_gen → pcm_to_pwm）。任何一个环节的频率、节拍或标志错一拍，现象
//   都是"电视上有图无声"，且无法用眼睛区分是哪一级坏了。所以这里把它们串起来
//   逐级量化：
//     T1 复位态：audio_valid 不冒泡、样本为 0、PWM 恒 0
//     T2 采样率：1 秒里 audio_valid 拍到 48000 次（分数分频的平均值要长窗口才准）
//     T3 音高：ST_READY(G4≈392Hz) 时，过零数 ≈ 2×392
//     T4 静音语义：ST_IDLE / ST_FAIL / mute=1 时 valid 照发、样本恒 0
//                  （核要求音频输入速率 = 采样率，停发 valid 会被当成流中断）
//     T5 音视频联动：ST_LOAD(E4) 与 ST_SCAN(C4) 的过零数不同，证明音高随状态变
//     T6 ACR：每 48 个样本出一次 acr_valid，包间隔 ≈ 48×520.83 拍
//     T7 PWM：整秒平均占空比 ≈ 50%（三角波居中，1 bit 输出无直流偏置）
//     T8 PWM 静音：mute 后积分器归零，输出恒 0
//
// 【为什么 T2 用 1 秒、T5 只给 0.25 秒】
//   25 MHz / 48 kHz = 520.833…，短窗口测不准平均采样率，必须给满 1 秒。
//   而音高是"数周期"，0.25 秒已能数到 131/165 个过零点，足够区分 C4 与 E4，
//   没必要为它再花整秒 —— 仿真时间就是把 ModelSim 的钟点换精度。
//
// 【为什么不能仿真发射核】
//   hdmi_1_4b_transmitter_core_wrapper 是 Anlogic AES 加密件，ModelSim ASE 无
//   解密许可，只能黑盒用于综合。所以本 testbench 覆盖到"交给核的三组信号
//   （AXIS / audio / ACR）全部正确"为止，核内部行为只能上板验证。
// =============================================================================
`timescale 1ns / 1ps

module tb_hdmi_audio_path;

    localparam CLK_PERIOD  = 40;          // 25 MHz
    localparam CLK_FREQ    = 25_000_000;
    localparam SAMPLE_RATE = 48_000;
    localparam ONE_SECOND  = CLK_FREQ;    // 1 秒 = 2500 万拍
    localparam QUARTER_SEC = CLK_FREQ / 4;
    localparam TENTH_SEC   = CLK_FREQ / 10;

    // 播放状态编码（与 audio_tone_gen / 顶层一致）
    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_SCAN  = 3'd1;
    localparam [2:0] ST_LOAD  = 3'd2;
    localparam [2:0] ST_READY = 3'd3;
    localparam [2:0] ST_AUTO  = 3'd4;
    localparam [2:0] ST_EMERG = 3'd5;
    localparam [2:0] ST_FAIL  = 3'd6;

    reg         clk   = 0;
    reg         rst_n = 0;
    reg  [2:0]  playback_state = ST_IDLE;
    reg         mute  = 0;
    reg         stats_en  = 0;   // 统计窗口使能
    reg         stats_rst = 0;   // 统计清零（与计数在同一 always 里，避免竞争）

    wire               audio_valid;
    wire signed [23:0] audio_left, audio_right;
    wire               acr_valid;
    wire [19:0]        acr_cts, acr_n;
    wire               audio_pwm;

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- 被测链路：音频源 → ACR → 模拟音频输出 ----
    audio_tone_gen #(
        .CLK_FREQ_HZ       (CLK_FREQ),
        .SAMPLE_RATE_HZ    (SAMPLE_RATE),
        .NOTE_HOLD_SAMPLES (24_000)
    ) u_tone (
        .clk            (clk),
        .rst_n          (rst_n),
        .playback_state (playback_state),
        .mute           (mute),
        .audio_valid    (audio_valid),
        .audio_left     (audio_left),
        .audio_right    (audio_right)
    );

    audio_arc #(.ACR_N(6144)) u_arc (
        .clk         (clk),
        .rst_n       (rst_n),
        .audio_valid (audio_valid),
        .acr_valid   (acr_valid),
        .acr_cts     (acr_cts),
        .acr_n       (acr_n)
    );

    pcm_to_pwm u_pwm (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_valid (audio_valid),
        .sample_in    (audio_left),
        .mute         (mute),
        .pwm_out      (audio_pwm)
    );

    // =========================================================================
    // 统计探针
    // 全部计数集中在一个时序块（含清零分支），既避免与激励竞争，也避免同一变量
    // 被两个 always 驱动 —— 后者在 Verilog 里是未定义行为，ModelSim 会给出 X。
    // =========================================================================
    integer valid_cnt    = 0;
    integer acr_cnt      = 0;
    integer nonzero_cnt  = 0;
    integer zero_cnt     = 0;
    integer sign_flips   = 0;
    integer pwm_high     = 0;
    integer pwm_total    = 0;
    integer clk_since_acr= 0;
    integer acr_gap_last = 0;
    integer acr_gap_prev = 0;
    reg     sign_prev    = 1'b0;
    reg     acr_seen     = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_cnt     <= 0;
            acr_cnt       <= 0;
            nonzero_cnt   <= 0;
            zero_cnt      <= 0;
            sign_flips    <= 0;
            pwm_high      <= 0;
            pwm_total     <= 0;
            clk_since_acr <= 0;
            acr_gap_last  <= 0;
            acr_gap_prev  <= 0;
            sign_prev     <= 1'b0;
            acr_seen      <= 1'b0;
        end else if (stats_rst) begin
            valid_cnt     <= 0;
            acr_cnt       <= 0;
            nonzero_cnt   <= 0;
            zero_cnt      <= 0;
            sign_flips    <= 0;
            pwm_high      <= 0;
            pwm_total     <= 0;
            // ACR 间隔重新起算：让本次窗口内量到的第一个包间隔是真实间隔
            clk_since_acr <= 0;
            acr_seen      <= 1'b0;
        end else if (stats_en) begin
            if (audio_valid) begin
                valid_cnt <= valid_cnt + 1;
                if (audio_left[23] !== sign_prev) sign_flips <= sign_flips + 1;
                sign_prev <= audio_left[23];
                if (audio_left != 24'sd0) nonzero_cnt <= nonzero_cnt + 1;
                else                      zero_cnt    <= zero_cnt + 1;
            end
            pwm_total <= pwm_total + 1;
            if (audio_pwm) pwm_high <= pwm_high + 1;

            if (acr_valid) begin
                acr_cnt <= acr_cnt + 1;
                if (acr_seen) begin
                    acr_gap_prev <= clk_since_acr;
                    acr_gap_last <= clk_since_acr;
                end
                acr_seen      <= 1'b1;
                clk_since_acr <= 0;
            end else begin
                clk_since_acr <= clk_since_acr + 1;
            end
        end
    end

    // =========================================================================
    // 辅助任务
    // =========================================================================
    integer errors = 0;

    task chk;
        input            cond;
        input [8*64-1:0] name;
        begin
            if (cond) $display("PASS: %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task step_clocks;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    // 开一个统计窗口：清零 → 推进 n 拍 → 关窗。返回时计数器就是这 n 拍的结果。
    task run_window;
        input integer n;
        begin
            stats_en  = 1'b0;
            stats_rst = 1'b1;
            @(posedge clk);
            @(posedge clk);
            stats_rst = 1'b0;
            stats_en  = 1'b1;
            step_clocks(n);
            stats_en  = 1'b0;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // 主序列
    // =========================================================================
    initial begin
        // ---------------- T1 复位态 ----------------
        step_clocks(100);
        chk(audio_valid === 1'b0, "T1.1 reset: audio_valid low");
        chk(audio_left  === 24'sd0, "T1.2 reset: sample=0");
        chk(audio_pwm   === 1'b0, "T1.3 reset: pwm low");
        rst_n = 1;
        step_clocks(100);

        // ---------------- T2/T6/T7 整秒窗口 @ ST_READY ----------------
        playback_state = ST_READY;
        run_window(ONE_SECOND);
        $display("T2 info: valid=%0d nonzero=%0d zero=%0d flips=%0d acr=%0d gap=%0d",
                 valid_cnt, nonzero_cnt, zero_cnt, sign_flips, acr_cnt, acr_gap_prev);
        chk((valid_cnt >= 47_900) && (valid_cnt <= 48_100), "T2.1 sample rate 48kHz");
        chk(acr_n === 20'd6144, "T2.2 ACR N = 6144 (48kHz family)");
        chk((sign_flips >= 760) && (sign_flips <= 810), "T2.3 tone G4 ~392Hz");
        chk(nonzero_cnt > 47_000, "T2.4 ST_READY is audible");
        // 每个包 = 48 个样本 = 48×520.833 ≈ 25000 拍
        chk((acr_gap_prev >= 24_900) && (acr_gap_prev <= 25_100), "T6.1 ACR every 48 samples");
        // 48000 样本 / 48 样本每包 = 1000 包每秒（ACR_N>>7 = 48，见 audio_arc.v）
        chk((acr_cnt >= 995) && (acr_cnt <= 1005), "T6.2 ACR rate ~1000/s");
        // 三角波居中 → 整秒平均占空比接近 50%
        // 注意：pwm_high×1000 会超过 32 位（约 1.25e10），所以只做 ×100 的整数除法
        $display("T7 info: pwm high=%0d total=%0d (%0d permille)",
                 pwm_high, pwm_total, pwm_high * 100 / pwm_total * 10);
        chk((pwm_high * 100 / pwm_total >= 45) && (pwm_high * 100 / pwm_total <= 55),
            "T7.1 pwm average duty ~50%");

        // ---------------- T5 音视频联动：换状态换音高 ----------------
        playback_state = ST_LOAD;                       // E4 = 329.63 Hz
        run_window(QUARTER_SEC);
        $display("T5 info: ST_LOAD flips=%0d (E4 expect ~165)", sign_flips);
        chk((sign_flips >= 155) && (sign_flips <= 175), "T5.1 ST_LOAD tone = E4");

        playback_state = ST_SCAN;                       // C4 = 261.63 Hz
        run_window(QUARTER_SEC);
        $display("T5 info: ST_SCAN flips=%0d (C4 expect ~131)", sign_flips);
        chk((sign_flips >= 122) && (sign_flips <= 140), "T5.2 ST_SCAN tone = C4");

        // ---------------- T4 静音语义 ----------------
        playback_state = ST_IDLE;
        run_window(TENTH_SEC);
        $display("T4 info: ST_IDLE valid=%0d nonzero=%0d", valid_cnt, nonzero_cnt);
        chk((valid_cnt >= 4_700) && (valid_cnt <= 4_900), "T4.1 ST_IDLE still sends valid");
        chk(nonzero_cnt == 0, "T4.2 ST_IDLE samples all zero");

        playback_state = ST_FAIL;
        run_window(TENTH_SEC);
        chk(nonzero_cnt == 0, "T4.3 ST_FAIL samples all zero");
        chk(valid_cnt > 4_700, "T4.4 ST_FAIL still sends valid");

        playback_state = ST_READY;
        mute = 1'b1;
        run_window(TENTH_SEC);
        chk(nonzero_cnt == 0, "T4.5 KEY6 mute zeroes samples");
        chk(valid_cnt > 4_700, "T4.6 mute keeps valid stream alive");

        // ---------------- T8 PWM 静音 ----------------
        // 等 sigma-delta 积分器把残留误差吐完，再量一段足够长的时间
        step_clocks(2_000);
        run_window(100_000);
        chk(pwm_high == 0, "T8.1 mute forces pwm low");
        mute = 1'b0;

        // ---------------- 收尾 ----------------
        step_clocks(1_000);
        if (errors == 0) $display("ALL CHECKS PASSED: hdmi_audio_path");
        else             $display("CHECKS FAILED: hdmi_audio_path, errors=%0d", errors);
        $finish;
    end

    // 全局超时保护：防止回归脚本挂死（实际约 2.7 秒，留足余量）
    initial begin
        #(CLK_PERIOD * 8.0 * ONE_SECOND);
        $display("TIMEOUT: hdmi_audio_path exceeded 8 simulated seconds");
        $finish;
    end

endmodule
