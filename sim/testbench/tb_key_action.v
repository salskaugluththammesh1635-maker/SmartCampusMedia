// ============================================================================
// tb_key_action —— key_action（KEY7~KEY14 扩展键译码）独立仿真
// ============================================================================
// 被测: rtl/control/key_action.v
// 目的: 把"按哪个键 → 哪个输出怎么变"这条映射关系固化成可重跑的断言，
//       而不是靠上板肉眼观察。
//
// 验证项（9 个用例 / 39 条断言）:
//   K01 复位默认值:   8 个输出全 0（= 与改造前逐像素一致的画面）
//   K02 KEY7 亮度:    0→1→2→3→4→0 五档循环，到顶回零
//   K03 KEY8 反色:    0→1→0 纯翻转
//   K04 KEY9 倍率:    0→1→2→3→0 四位自然回绕
//   K05 KEY10 重扫:   每次按键恰好 1 拍脉冲，且不会持续为高
//   K06 KEY11~14:     四个开关各自独立翻转
//   K07 无关键号:     KEY0~KEY6 / KEY15 按下后 8 个输出全部不变
//   K08 互不干扰:     连按 KEY7 五次不得改动其它 7 个输出
//   K09 复位恢复:     状态中途复位 → 全部回到默认值
//
// 用法（工作目录 sim/msim_work）:
//   vlog -quiet ../../rtl/control/key_action.v ../testbench/tb_key_action.v
//   vsim -c -quiet -lib work -do "run -all; quit -f" tb_key_action
// ============================================================================
`timescale 1ns/1ps

module tb_key_action;

    // ---- 时钟: 25MHz（周期 40ns，与本系统 clk_pixel 一致）----
    localparam CLK_PERIOD = 40;             // ns
    reg clk;
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n;

    // ---- 共享激励（来自 key_matrix_4x4）----
    reg        key_event = 1'b0;
    reg  [3:0] key_code  = 4'd0;

    // ---- DUT 输出 ----
    wire [2:0] bright_sel;
    wire       invert_en;
    wire [1:0] auto_sw_sel;
    wire       grid_en;
    wire       info_en;
    wire       level_en;
    wire       wave_en;
    wire       beep_muted;
    wire       rescan_req;

    key_action dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .key_event  (key_event),
        .key_code   (key_code),
        .bright_sel (bright_sel),
        .invert_en  (invert_en),
        .auto_sw_sel(auto_sw_sel),
        .rescan_req (rescan_req),
        .grid_en    (grid_en),
        .info_en    (info_en),
        .level_en   (level_en),
        .wave_en    (wave_en),
        .beep_muted (beep_muted)
    );

    // ========================================================================
    // rescan_req 单拍性监视
    //   为什么单独监视: 下游 gallery_probe 按"电平 + 状态机"采样，如果
    //   rescan_req 连续两拍为高，等价于按了两次键 —— 现场表现是图库被重扫两遍，
    //   且第一次扫到一半就被第二次清掉。这类问题在波形里很难一眼看出，
    //   所以用计数器把它变成断言。
    // ========================================================================
    integer rescan_pulses = 0;
    integer rescan_stuck  = 0;
    reg     rescan_d      = 1'b0;

    always @(posedge clk) begin
        rescan_d <= rescan_req;
        if (rst_n && rescan_req && !rescan_d) rescan_pulses = rescan_pulses + 1;
        if (rst_n && rescan_req &&  rescan_d) rescan_stuck  = rescan_stuck  + 1;
    end

    // ========================================================================
    // 检查工具
    // ========================================================================
    integer errors = 0;
    integer checks = 0;

    task chk;
        input         cond;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_eq8;
        input [7:0]   got;
        input [7:0]   exp;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", name);
            else begin
                $display("FAIL: %0s (got %0d, expect %0d)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // 一次按键: key_event 保持 1 拍（与 key_matrix_4x4 的输出契约一致）
    task press_key;
        input [3:0] code;
        begin
            @(negedge clk);
            key_code  = code;
            key_event = 1'b1;
            @(negedge clk);
            key_event = 1'b0;
            key_code  = 4'd0;
            @(negedge clk);
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            @(negedge clk);
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    // 8 个输出是否全部处于默认值
    wire all_default = (bright_sel == 3'd0) && (invert_en == 1'b0) &&
                       (auto_sw_sel == 2'd0) && (grid_en == 1'b0) &&
                       (info_en == 1'b0) && (level_en == 1'b0) &&
                       (wave_en == 1'b0) && (beep_muted == 1'b0);

    // ---- 循环/计数用 ----
    integer k;
    integer n0;

    // ========================================================================
    // 主测试序列
    // ========================================================================
    initial begin
        $display("=== tb_key_action start ===");

        // ---------------- K01 复位默认值 ----------------
        // 这一条是整个特性的安全底线: 什么都不按时，顶层拿到的 8 个控制量
        // 必须全 0，否则上电画面就与改造前不一致（亮度变暗/叠加信息条）。
        $display("");
        $display("--- K01 reset defaults ---");
        do_reset;
        chk(all_default,                       "K01 all 8 outputs default to 0 after reset");
        chk(rescan_req == 1'b0,                "K01 rescan_req idle low after reset");
        chk_eq8({5'd0, bright_sel}, 8'd0,      "K01 bright_sel = 0 (100% brightness)");
        chk_eq8({6'd0, auto_sw_sel}, 8'd0,     "K01 auto_sw_sel = 0 (x1)");

        // ---------------- K02 KEY7 亮度五档循环 ----------------
        $display("");
        $display("--- K02 KEY7 brightness cycle ---");
        press_key(4'd1);                       // 先造一个非默认状态
        chk_eq8({5'd0, bright_sel}, 8'd0,      "K02 brightness untouched by KEY1");
        press_key(4'd7);
        chk_eq8({5'd0, bright_sel}, 8'd1,      "K02 KEY7 0 -> 1");
        press_key(4'd7);
        chk_eq8({5'd0, bright_sel}, 8'd2,      "K02 KEY7 1 -> 2");
        press_key(4'd7);
        chk_eq8({5'd0, bright_sel}, 8'd3,      "K02 KEY7 2 -> 3");
        press_key(4'd7);
        chk_eq8({5'd0, bright_sel}, 8'd4,      "K02 KEY7 3 -> 4 (darkest)");
        press_key(4'd7);
        chk_eq8({5'd0, bright_sel}, 8'd0,      "K02 KEY7 4 -> 0 (wraps to brightest)");

        // ---------------- K03 KEY8 反色 ----------------
        $display("");
        $display("--- K03 KEY8 invert toggle ---");
        press_key(4'd8);
        chk(invert_en == 1'b1,                 "K03 KEY8 turns invert on");
        press_key(4'd8);
        chk(invert_en == 1'b0,                 "K03 KEY8 turns invert off again");

        // ---------------- K04 KEY9 倍率四位回绕 ----------------
        // 为什么要刻意验证"3 -> 0": auto_sw_sel 是 2 位，靠自然溢出回绕。
        //   若将来有人把它加宽到 3 位却忘了改循环上限，就会走到 4/5/6 档 ——
        //   而 player_ctrl 只认 0..3，4 以上会落进 default 分支。
        $display("");
        $display("--- K04 KEY9 rotation speed cycle ---");
        press_key(4'd9);
        chk_eq8({6'd0, auto_sw_sel}, 8'd1,     "K04 KEY9 0 -> 1 (x2)");
        press_key(4'd9);
        chk_eq8({6'd0, auto_sw_sel}, 8'd2,     "K04 KEY9 1 -> 2 (x3)");
        press_key(4'd9);
        chk_eq8({6'd0, auto_sw_sel}, 8'd3,     "K04 KEY9 2 -> 3 (x4)");
        press_key(4'd9);
        chk_eq8({6'd0, auto_sw_sel}, 8'd0,     "K04 KEY9 3 -> 0 (wraps to x1)");

        // ---------------- K05 KEY10 图库重扫单拍脉冲 ----------------
        $display("");
        $display("--- K05 KEY10 rescan single-cycle pulse ---");
        n0 = rescan_pulses;
        press_key(4'd10);
        repeat (10) @(negedge clk);
        $display("  K05: pulses=%0d stuck=%0d", rescan_pulses - n0, rescan_stuck);
        chk((rescan_pulses - n0) == 1,         "K05 KEY10 emits exactly one rescan pulse");
        chk(rescan_req == 1'b0,                "K05 rescan_req back low after the pulse");
        chk(rescan_stuck == 0,                 "K05 rescan_req never held high two cycles");
        // 连按两次必须产生两个脉冲（不能因为"上一次还没被处理"就吞掉）
        n0 = rescan_pulses;
        press_key(4'd10);
        press_key(4'd10);
        repeat (10) @(negedge clk);
        chk((rescan_pulses - n0) == 2,         "K05 two keypresses give two rescan pulses");

        // ---------------- K06 KEY11~KEY14 四个开关 ----------------
        $display("");
        $display("--- K06 KEY11..KEY14 layer switches ---");
        press_key(4'd11);
        chk(grid_en == 1'b1,                   "K06 KEY11 turns grid on");
        press_key(4'd12);
        chk(info_en == 1'b1,                   "K06 KEY12 turns info bar on");
        press_key(4'd13);
        chk(level_en == 1'b1 && !wave_en,      "K06 KEY13#1 turns level bar on");
        press_key(4'd13);
        chk(!level_en && wave_en == 1'b1,      "K06 KEY13#2 switches to waveform");
        press_key(4'd13);
        chk(level_en == 1'b1 && wave_en == 1'b1, "K06 KEY13#3 shows level + waveform");
        press_key(4'd14);
        chk(beep_muted == 1'b1,                "K06 KEY14 mutes the buzzer");
        // 关回去，确认是 4 态循环而不是简单置位
        press_key(4'd11);
        press_key(4'd12);
        press_key(4'd13);
        press_key(4'd14);
        chk(!grid_en && !info_en && !level_en && !wave_en && !beep_muted,
                                               "K06 all switches and waveform turn back off");

        // ---------------- K07 无关键号不得产生任何动作 ----------------
        // 这 8 个键号各有归属: KEY0/1/2/3/15 → player_ctrl，
        //   KEY4/5 → 顶层 pattern_sel，KEY6 → 顶层 audio_muted。
        //   本模块收到它们时必须"什么都不做"，否则就是一个键干了两件事。
        $display("");
        $display("--- K07 unrelated key codes are ignored ---");
        do_reset;
        press_key(4'd7);                       // 造一个可见的非默认状态
        chk_eq8({5'd0, bright_sel}, 8'd1,      "K07 precondition: brightness = 1");
        for (k = 0; k < 16; k = k + 1) begin
            if ((k != 7) && (k != 8) && (k != 9) && (k != 10) &&
                (k != 11) && (k != 12) && (k != 13) && (k != 14)) begin
                press_key(k[3:0]);
            end
        end
        chk_eq8({5'd0, bright_sel}, 8'd1,      "K07 KEY0..KEY6 & KEY15 leave brightness alone");
        chk(invert_en == 1'b0,                 "K07 unrelated keys leave invert alone");
        chk_eq8({6'd0, auto_sw_sel}, 8'd0,     "K07 unrelated keys leave speed alone");
        chk(!grid_en && !info_en && !level_en && !wave_en && !beep_muted,
                                               "K07 unrelated keys leave switches alone");
        chk(rescan_stuck == 0,                 "K07 unrelated keys never pulse rescan");

        // ---------------- K08 一个键只动自己那一路 ----------------
        $display("");
        $display("--- K08 keypresses do not cross-talk ---");
        do_reset;
        press_key(4'd9);                       // 只动倍率
        press_key(4'd9);
        chk_eq8({6'd0, auto_sw_sel}, 8'd2,     "K08 speed moved to 2");
        chk_eq8({5'd0, bright_sel}, 8'd0,      "K08 KEY9 did not touch brightness");
        chk(!invert_en && !grid_en && !info_en && !level_en && !wave_en && !beep_muted,
                                               "K08 KEY9 did not touch any switch");
        press_key(4'd14);                      // 只动静音
        chk_eq8({6'd0, auto_sw_sel}, 8'd2,     "K08 KEY14 did not touch speed");
        chk(beep_muted == 1'b1,                "K08 KEY14 did mute the buzzer");

        // ---------------- K09 复位恢复默认 ----------------
        $display("");
        $display("--- K09 reset restores defaults ---");
        press_key(4'd7); press_key(4'd7);      // 亮度拉到 2
        press_key(4'd8);                       // 反色开
        press_key(4'd9);                       // 倍率 1
        press_key(4'd11); press_key(4'd12);    // 网格/信息条开
        press_key(4'd13); press_key(4'd14);    // 电平条/静音开
        chk(!all_default,                      "K09 precondition: outputs are non-default");
        do_reset;
        chk(all_default,                       "K09 reset clears all 8 outputs");
        chk(rescan_req == 1'b0,                "K09 reset leaves rescan_req low");

        // ---------------- 收尾 ----------------
        $display("");
        chk(rescan_stuck == 0, "global: rescan_req never held high for two cycles");
        $display("=== tb_key_action: %0d checks, %0d error(s) ===", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: key_action");
        else             $display("CHECKS FAILED: %0d error(s)", errors);
        $finish;
    end

endmodule
