// =============================================================================
// tb_pwm_audio_out.v — pwm_audio_out 单元测试
// -----------------------------------------------------------------------------
// 验证点:
//   T1 复位后输出为 0（静音态）
//   T2 音高: DDS 440Hz@25MHz —— 20 个波形窗口统计到 20±1 个周期
//      （FTW = 440×2^32/25e6 = 75594；每波形周期 = 2^32/75594 ≈ 56809 clk）
//   T3 三角波单调性: 相邻幅值步进只允许 ±1 或波峰/波谷回绕（无跳变毛刺）
//   T4 PWM 占空比跟踪: 统计整载波周期(256 clk)内高电平拍数 ≈ 幅值/256
//   T5 mute: 置位后 2 个载波周期内输出恒 0
// 仿真时长: ≈46ms（20 波形周期 + 余量），ModelSim 数秒内可完成
// =============================================================================
`timescale 1ns / 1ps

module tb_pwm_audio_out;

    localparam CLKPeriod = 40;              // 25MHz = 40ns
    localparam CLKS_PER_WAVE = 56809;       // 2^32/FTW ≈ 每波形周期时钟数

    reg  clk = 0;
    reg  rst_n = 0;
    reg  mute = 0;
    wire audio_pwm;

    pwm_audio_out #(
        .CLK_FREQ_HZ (25_000_000),
        .FREQ_HZ     (440)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .mute      (mute),
        .audio_pwm (audio_pwm)
    );

    always #(CLKPeriod/2) clk = ~clk;

    // ---- 内部信号探针 ----
    wire [31:0] phase_acc = dut.phase_acc;
    wire [7:0]  wave_amp  = dut.wave_amp;
    wire [7:0]  pwm_cnt   = dut.pwm_cnt;

    // ---- T2 音高统计: 幅值过中点(>=128)的上升沿 = 一个完整周期 ----
    integer cycle_cnt = 0;
    reg  amp_above = 0;
    reg  amp_above_d = 0;
    always @(posedge clk) begin
        amp_above_d <= amp_above;
        amp_above   <= (wave_amp >= 8'd128);
        if (amp_above && !amp_above_d)
            cycle_cnt <= cycle_cnt + 1;
    end

    // ---- T3 单调性检查（复位释放后才开始统计）----
    integer mono_err = 0;
    reg [7:0] amp_d = 0;
    always @(posedge clk) begin
        amp_d <= wave_amp;
        if (rst_n) begin
            if ((wave_amp > amp_d) && (wave_amp != amp_d + 8'd1) &&
                !(amp_d == 8'd255 && wave_amp == 8'd0))
                mono_err <= mono_err + 1;
            else if ((wave_amp < amp_d) && (wave_amp != amp_d - 8'd1) &&
                     !(amp_d == 8'd0 && wave_amp == 8'd255))
                mono_err <= mono_err + 1;
        end
    end

    // ---- T4 占空比测量: 每逢 256 拍（一个载波周期）结算一次 ----
    integer pwm_high = 0;       // 当前窗口内高电平拍数
    integer pwm_total = 0;      // 上一完整窗口的高电平拍数
    integer amp_locked = 0;     // 上一窗口起点附近的幅值
    reg [7:0] pwm_win = 0;
    always @(posedge clk) begin
        if (pwm_win == 8'd255) begin
            pwm_win   <= 8'd0;
            pwm_total <= pwm_high;
            amp_locked<= wave_amp;
            pwm_high  <= audio_pwm ? 1 : 0;
        end
        else begin
            pwm_win <= pwm_win + 8'd1;
            if (audio_pwm)
                pwm_high <= pwm_high + 1;
        end
    end

    // ---- T4b 平均占空比: 完整波形周期内 audio_pwm 高电平占比 ≈ 50%（三角波对称）----
    integer wave_high = 0;
    always @(posedge clk)
        if (rst_n && !mute)
            wave_high <= wave_high + ((audio_pwm) ? 1 : 0);

    // ---- 主序列 ----
    integer errors = 0;

    task chk;
        input cond;
        input [1023:0] name;
        begin
            if (cond) $display("PASS - %0s", name);
            else begin
                $display("FAIL - %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        // T1 复位态
        #(CLKPeriod*10);
        chk(audio_pwm === 1'b0, "T1 reset output=0");
        rst_n = 1;

        // 跑 20 个完整波形周期（约 45.4ms 仿真时间）
        #(CLKPeriod * 20 * CLKS_PER_WAVE);
        $display("T2 info: %0d cycles in 20-wave window (440Hz@25MHz)", cycle_cnt);
        chk((cycle_cnt >= 19) && (cycle_cnt <= 21), "T2 frequency 440Hz");
        $display("T3 info: %0d illegal triangle steps", mono_err);
        chk(mono_err == 0, "T3 triangle monotonic");

        // T4 占空比: 最近一个完整载波窗口的统计
        if (amp_locked >= 64 && amp_locked <= 192) begin
            // 期望 pwm_total ≈ amp_locked（±15% 容差: 载波窗口内幅值仍在缓变）
            $display("T4 info: duty %0d/256 vs amp %0d/256", pwm_total, amp_locked);
            chk((pwm_total >= amp_locked * 85 / 100) &&
                (pwm_total <= amp_locked * 115 / 100), "T4 duty tracks amplitude");
        end else begin
            $display("INFO - T4 amp %0d not mid-range, duty check skipped", amp_locked);
        end

        // T5 前先做 T4b 平均占空比统计（20 波形周期 ≈ 113.6 万拍, 中心 50%±5%）
        if (wave_high * 2 > (20 * CLKS_PER_WAVE * 90 / 100) &&
            wave_high * 2 < (20 * CLKS_PER_WAVE * 110 / 100))
            chk(1'b1, "T4b average duty ~50%");
        else
            chk(1'b0, "T4b average duty ~50%");
        $display("T4b info: high %0d / total %0d = %0d%%",
                 wave_high, 20 * CLKS_PER_WAVE, wave_high * 100 / (20 * CLKS_PER_WAVE));

        // T5 mute
        mute = 1;
        #(CLKPeriod * 600);
        chk(audio_pwm === 1'b0, "T5 mute output=0");

        #(CLKPeriod*10);
        if (errors == 0)
            $display("ALL CHECKS PASSED, errors = 0");
        else
            $display("FAILED, errors = %0d", errors);
        $finish;
    end

endmodule
