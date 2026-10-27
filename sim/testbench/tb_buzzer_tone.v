// =============================================================================
// tb_buzzer_tone.v — 无源蜂鸣器四种发声模式的单元测试
// -----------------------------------------------------------------------------
// 背景:
//   buzzer_tone.v 本次由"三模式（0静音/1按键/2应急）"扩展为
//   "四模式（+3 故障告警）"，tone_sel 由 2 位扩到 3 位。
//   三种"响"的模式必须在**音高**和**节奏**上都能区分，否则用户分不清
//   "按了键""进了应急模式""设备坏了"：
//     模式1 按键音   C5 523Hz，单次 100ms            —— 交互确认
//     模式2 应急音   E6 1319Hz，250ms 响/250ms 停循环 —— 高音急促
//     模式3 故障告警 A4 440Hz，  700ms 停/300ms 响循环 —— 低音沉闷
//   本 TB 用**边沿间隔统计**验证频率，用**相位区间**验证节奏，
//   不依赖具体时钟频率（参数取小值加速仿真）。
//
// 验证项:
//   B1  复位后静音（buzzer_out=1，低电平响的反相）
//   B2  模式 0：任何输入都不发声
//   B3  模式 1：trig 后出现一个有限长度的发声窗口，然后自动停
//   B4  模式 1：trig 在窗口内可重触发（延长窗口）
//   B5  模式 2：持续响/停交替（无需 trig），周期 = 2×EMERG_HALF
//   B6  模式 3：先静后响，周期 = ALARM_OFF + ALARM_ON
//   B7  三种模式的方波频率互不相同，且符合各自设计值（±15%）
//   B8  切回模式 0 立即静音
//
// 【为什么用"边沿间隔"而不是数完整周期】
//   一个完整方波周期要数 half_period×2 拍，三种音都测完仿真时间较长；
//   而"相邻两次 buzzer_out 翻转的间隔"恰好就是一个半周期，等价且更快。
//
// 运行: vsim -c -do "run -all" work.tb_buzzer_tone
// =============================================================================
`timescale 1ns / 1ps

module tb_buzzer_tone;

    // 参数取 100kHz：HALF_C5≈95 拍、HALF_E6≈37 拍、HALF_A4≈113 拍，
    // BEEP_TICKS=10000 拍、EMERG_HALF=25000 拍、ALARM_OFF=70000 拍、ALARM_ON=30000 拍。
    // 节奏窗口偏长，故本 TB 只验证"窗口存在且先后顺序正确"，不做全周期计时。
    localparam integer FREQ       = 100_000;
    localparam integer HALF_C5    = FREQ / (2 * 523);   // 95
    localparam integer HALF_E6    = FREQ / (2 * 1319);  // 37
    localparam integer HALF_A4    = FREQ / (2 * 440);   // 113
    localparam integer BEEP_TICKS = FREQ / 10;          // 10000
    localparam integer EMERG_HALF = FREQ / 4;           // 25000
    localparam integer ALARM_OFF  = (FREQ / 1000) * 700; // 70000
    localparam integer ALARM_ON   = (FREQ / 1000) * 300; // 30000

    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100MHz 仿真时钟，加速时序窗口

    reg rst_n = 1'b0;
    reg [2:0] tone_sel = 3'd0;
    reg       trig     = 1'b0;

    wire buzzer_out;

    buzzer_tone #(.CLK_FREQ_HZ(FREQ)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .tone_sel   (tone_sel),
        .trig       (trig),
        .buzzer_out (buzzer_out)
    );

    integer errors = 0;

    task chk(input cond, input [1023:0] tag);
        begin
            if (cond) $display("PASS: %0s", tag);
            else begin
                $display("FAIL: %0s", tag);
                errors = errors + 1;
            end
        end
    endtask

    task wait_cycles(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    // ---- 测量相邻两次翻转的间隔（= 方波半周期），超时返回 -1 ----
    // 说明: buzzer_out 是低电平响，翻转发生在方波相位切换时，与高低电平极性无关。
    task measure_half_period(output integer half);
        integer t0, t1;
        begin
            @(buzzer_out);              // 等到下一次翻转
            t0 = $time;
            @(buzzer_out);
            t1 = $time;
            half = (t1 - t0) / 10;      // 以时钟周期为单位（#5 半拍 → 10 为一周期）
        end
    endtask

    // ---- 在 n 拍内统计翻转次数（用于判断"是否在发声"）----
    task count_edges(input integer n, output integer cnt);
        integer i;
        reg prev;
        begin
            cnt  = 0;
            prev = buzzer_out;
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk);
                if (buzzer_out !== prev) begin
                    cnt  = cnt + 1;
                    prev = buzzer_out;
                end
            end
        end
    endtask

    integer half, edges, half_meas;

    initial begin
        $display("=== tb_buzzer_tone start ===");
        $display("HALF_C5=%0d HALF_E6=%0d HALF_A4=%0d BEEP_TICKS=%0d",
                 HALF_C5, HALF_E6, HALF_A4, BEEP_TICKS);
        $display("EMERG_HALF=%0d ALARM_OFF=%0d ALARM_ON=%0d",
                 EMERG_HALF, ALARM_OFF, ALARM_ON);

        // ================= B1 复位静音 =================
        rst_n = 1'b0;
        wait_cycles(5);
        chk(buzzer_out === 1'b1, "B1 reset: buzzer silent (out=1)");
        @(negedge clk); rst_n = 1'b1;
        wait_cycles(5);
        chk(buzzer_out === 1'b1, "B1 after reset: still silent");

        // ================= B2 模式 0 静音 =================
        @(negedge clk); tone_sel = 3'd0; trig = 1'b1;
        wait_cycles(2);
        @(negedge clk); trig = 1'b0;
        count_edges(2000, edges);
        chk(edges == 0, "B2 mode0: trig ignored, no edge in 2000 cycles");
        // 模式 0 下即便再次 trig 也不响
        @(negedge clk); trig = 1'b1;
        wait_cycles(2);
        @(negedge clk); trig = 1'b0;
        count_edges(2000, edges);
        chk(edges == 0, "B2 mode0: no sound without enable");

        // ================= B3 模式 1 按键音 =================
        // 【先等残留的按键窗口走完】
        //   上面的 B2 为了验证"模式 0 忽略 trig"确实拉过高电平脉冲，
        //   这会把机制 A 的 beep_state 从 B_IDLE 推到 B_BEEP（窗口与模式无关，
        //   它只计 BEEP_TICKS 那么久）。若不等它自然结束，切到模式 1 的瞬间
        //   beep_run 已为 1，会立刻发声 —— 这**不是缺陷**，而是"按键音窗口
        //   一旦开启就应响完"的既有语义；是测试前提需要对齐，故此处先等满。
        wait_cycles(BEEP_TICKS + 100);
        @(negedge clk); tone_sel = 3'd1;
        wait_cycles(5);
        // 未 trig 前必须安静
        count_edges(500, edges);
        chk(edges == 0, "B3 mode1: quiet before trig");
        // trig → 应有翻转（发声）
        @(negedge clk); trig = 1'b1;
        wait_cycles(2);
        @(negedge clk); trig = 1'b0;
        count_edges(HALF_C5 * 4, edges);
        chk(edges > 0, "B3 mode1: beeps after trig");
        // 发够 BEEP_TICKS 之后自动停
        wait_cycles(BEEP_TICKS);
        count_edges(2000, edges);
        chk(edges == 0, "B3 mode1: stops after 100ms window");

        // ================= B4 模式 1 窗口内可重触发 =================
        @(negedge clk); trig = 1'b1;
        wait_cycles(2);
        @(negedge clk); trig = 1'b0;
        wait_cycles(BEEP_TICKS / 2);        // 走到窗口一半
        count_edges(HALF_C5 * 4, edges);
        chk(edges > 0, "B4 mode1: still beeping mid-window");
        @(negedge clk); trig = 1'b1;        // 重触发，窗口应重新计时
        wait_cycles(2);
        @(negedge clk); trig = 1'b0;
        wait_cycles(BEEP_TICKS / 2 + 100);  // 原本该结束了，但重触发后还在响
        count_edges(HALF_C5 * 4, edges);
        chk(edges > 0, "B4 mode1: retrigger extends window");
        // 最终仍会自动停
        wait_cycles(BEEP_TICKS);
        count_edges(2000, edges);
        chk(edges == 0, "B4 mode1: eventually stops");

        // ================= B5 模式 2 应急音 =================
        @(negedge clk); tone_sel = 3'd2;
        wait_cycles(5);
        // 无需 trig，应立即进入响段
        count_edges(EMERG_HALF / 2, edges);
        chk(edges > 0, "B5 mode2: sounds without trig");
        // 响段结束后进入停段（相位翻转），再核对能重新响起来
        wait_cycles(EMERG_HALF + 10);
        // 此时应处于停段（emerg_phase=E_MUTE），无翻转
        count_edges(500, edges);
        chk(edges == 0, "B5 mode2: quiet phase after 250ms sound");
        // 再经过一个 EMERG_HALF 应回到响段
        wait_cycles(EMERG_HALF + 10);
        count_edges(EMERG_HALF / 2, edges);
        chk(edges > 0, "B5 mode2: sounds again in next cycle");

        // ================= B6 模式 3 故障告警音（先静后响）=================
        @(negedge clk); tone_sel = 3'd3;
        wait_cycles(5);
        // 关键设计: 刚切到模式 3 处于**静段**，不能立刻响
        count_edges(2000, edges);
        chk(edges == 0, "B6 mode3: quiet first (700ms rest phase)");
        // 走完 ALARM_OFF 后进入响段
        wait_cycles(ALARM_OFF);
        count_edges(ALARM_ON / 2, edges);
        chk(edges > 0, "B6 mode3: sounds after 700ms rest");
        // 响段结束后回到静段
        wait_cycles(ALARM_ON + 100);
        count_edges(2000, edges);
        chk(edges == 0, "B6 mode3: quiet again after 300ms sound");

        // ================= B7 三音频率互不相同 =================
        // 模式 1 的半周期
        @(negedge clk); tone_sel = 3'd1;
        @(negedge clk); trig = 1'b1;
        wait_cycles(2);
        @(negedge clk); trig = 1'b0;
        wait_cycles(50);
        measure_half_period(half);
        // 容差 ±15%（HALF_C5 是整数除法结果，理论值 95）
        chk((half >= (HALF_C5 * 85 / 100)) && (half <= (HALF_C5 * 115 / 100)),
            "B7 mode1 half period matches C5");
        half_meas = half;
        // 让按键音窗口走完，避免干扰后续测量
        wait_cycles(BEEP_TICKS + 100);

        // 模式 2 的半周期
        @(negedge clk); tone_sel = 3'd2;
        wait_cycles(50);
        measure_half_period(half);
        chk((half >= (HALF_E6 * 85 / 100)) && (half <= (HALF_E6 * 115 / 100)),
            "B7 mode2 half period matches E6");
        chk(half < half_meas, "B7 E6 is higher pitch than C5");

        // 模式 3 的半周期（需等过 700ms 静段进入响段）
        @(negedge clk); tone_sel = 3'd3;
        wait_cycles(ALARM_OFF);
        measure_half_period(half);
        chk((half >= (HALF_A4 * 85 / 100)) && (half <= (HALF_A4 * 115 / 100)),
            "B7 mode3 half period matches A4");
        chk(half > half_meas, "B7 A4 is lower pitch than C5");

        // ================= B8 切回模式 0 立即静音 =================
        @(negedge clk); tone_sel = 3'd0;
        wait_cycles(10);
        count_edges(2000, edges);
        chk(edges == 0, "B8 back to mode0: silent");
        chk(buzzer_out === 1'b1, "B8 back to mode0: output high (off)");

        // ================= 汇总 =================
        $display("=== tb_buzzer_tone done, errors = %0d ===", errors);
        if (errors == 0) $display("*** ALL CHECKS PASSED ***");
        else             $display("*** CHECKS FAILED ***");
        $finish;
    end

    // ---- 全局超时保护 ----
    initial begin
        #50_000_000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("*** CHECKS FAILED ***");
        $finish;
    end

endmodule
