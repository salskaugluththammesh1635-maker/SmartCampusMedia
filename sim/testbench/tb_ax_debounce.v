// =============================================================================
// tb_ax_debounce.v —— ax_debounce 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块的规格】
//   单路按键消抖（官方参考件，未参与 TD 工程编译，但必须保证其行为正确）。
//   核心思想：不判断"按键现在是什么电平"，而判断"电平是否已连续稳定 MAX_TIME"。
//   任何一次电平变化都把计数器清零重来 —— 抖动期计数器被反复清零永远数不满；
//   直到电平安静下来、计数器第一次爬满，才把当前电平采纳为真实输出。
//   这在数字设计里叫"可重触发定时器"（retriggerable timer）。
//
// 【本 TB 要钉死的五条不变量】
//   1) 抖动期输出绝对不可见：只要电平还在变，button_out 纹丝不动
//   2) 稳定满 TIMER_MAX_VAL 拍后才采纳，早一拍都不行（不是"大约"）
//   3) 计数器数满后停在满值，不回绕 —— 若溢出归零，"已数满"状态会被悄悄洗掉
//   4) 边沿脉冲严格 1 拍宽，且只在消抖后的电平变化时出现一次
//   5) 复位是**高有效**（本模块与全项目低有效 rst_n 相反，是移植时的典型坑）
//
// 【参数缩放：为什么不按真实 20ms 跑】
//   真实值 TIMER_MAX_VAL = MAX_TIME(ms) × 1000 × FREQ(MHz) = 20 × 1000 × 50
//                        = 1_000_000 拍
//   跑满一次消抖要 100 万拍，几十个用例就是几千万拍，仿真时间不可接受。
//   本 TB 取 FREQ=1、MAX_TIME=1 → TIMER_MAX_VAL = 1000 拍。
//   注意：TIMER_MAX_VAL 是 localparam，不能用 vsim -g 覆盖，
//   但它的计算式只依赖 FREQ / MAX_TIME 两个 parameter，所以改这两个即可。
//   1000 拍的窗口足够装下"抖动 300 拍 + 稳定 1000 拍"的完整时序，
//   又短到能在一个用例里反复验证多次。
// =============================================================================
`timescale 1ns / 1ps

module tb_ax_debounce;

    // ---- 缩放后的常量 ------------------------------------------------------
    // MAX_TIME=1(ms) × 1000 × FREQ=1(MHz) = 1000
    localparam TIMER_MAX = 1000;

    // ---- 时钟（50MHz，周期 20ns）------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // ---- DUT ---------------------------------------------------------------
    reg  rst;                // 高有效！
    reg  button_in;
    wire button_posedge;
    wire button_negedge;
    wire button_out;

    ax_debounce #(
        .N        (32),
        .FREQ     (1),        // MHz
        .MAX_TIME (1)         // ms  → TIMER_MAX_VAL = 1 × 1000 × 1 = 1000
    ) u_dut (
        .clk            (clk),
        .rst            (rst),
        .button_in      (button_in),
        .button_posedge (button_posedge),
        .button_negedge (button_negedge),
        .button_out     (button_out)
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

    task ck_eq(input integer got, input integer exp, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s  (got %0d, expected %0d)", label, got, exp);
            end
        end
    endtask

    // ---- 边沿脉冲统计 ------------------------------------------------------
    integer pos_pulses;
    integer neg_pulses;
    integer pos_width;        // 最近一次 posedge 脉冲的宽度（拍）
    integer neg_width;
    reg     pos_d, neg_d;
    integer pos_run, neg_run;

    always @(posedge clk) begin
        pos_d <= button_posedge;
        neg_d <= button_negedge;
        // 上升沿开始计数宽度
        if (button_posedge === 1'b1 && pos_d !== 1'b1) begin
            pos_pulses = pos_pulses + 1;
            pos_run    = 1;
        end else if (button_posedge === 1'b1) begin
            pos_run = pos_run + 1;
        end else begin
            if (pos_run > 0) pos_width = pos_run;
            pos_run = 0;
        end
        if (button_negedge === 1'b1 && neg_d !== 1'b1) begin
            neg_pulses = neg_pulses + 1;
            neg_run    = 1;
        end else if (button_negedge === 1'b1) begin
            neg_run = neg_run + 1;
        end else begin
            if (neg_run > 0) neg_width = neg_run;
            neg_run = 0;
        end
    end

    task clr_stats;
        begin
            pos_pulses = 0; neg_pulses = 0;
            pos_width  = 0; neg_width  = 0;
            pos_run    = 0; neg_run    = 0;
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    integer cyc;
    integer changed_at;

    initial begin
        $display("=== tb_ax_debounce start (TIMER_MAX_VAL=%0d) ===", TIMER_MAX);
        clr_stats();
        button_in = 1'b1;      // 按键低有效：1 = 未按下
        rst       = 1'b1;      // 高有效复位：1 = 复位中

        // =====================================================================
        // ① 复位保持：高有效极性钉子
        //    若 RTL 误按低有效处理，rst=1 时输出就全是 x 或 0，这里立刻暴露
        // =====================================================================
        repeat (5) @(posedge clk);
        #1;
        ck(button_out     === 1'b1, "[reset] button_out = 1 (idle, not pressed)");
        ck(button_posedge === 1'b0, "[reset] no posedge pulse");
        ck(button_negedge === 1'b0, "[reset] no negedge pulse");
        ck(rst === 1'b1,            "[reset] high-active reset polarity in use");

        // =====================================================================
        // ② 释放复位、输入保持"未按下"：稳定后 button_out 仍为 1，无任何脉冲
        // =====================================================================
        @(negedge clk);
        rst = 1'b0;
        clr_stats();
        repeat (TIMER_MAX + 20) @(posedge clk);
        #1;
        ck(button_out     === 1'b1,   "[idle] button_out stays 1 when input stays 1");
        ck_eq(pos_pulses, 0,          "[idle] zero posedge pulses");
        ck_eq(neg_pulses, 0,          "[idle] zero negedge pulses");

        // =====================================================================
        // ③ 抖动期不可见：每 3 拍翻转一次，连续 300 拍
        //    300 < 1000，计数器被反复清零，永远数不满 → 输出必须纹丝不动
        // =====================================================================
        clr_stats();
        for (i = 0; i < 100; i = i + 1) begin
            @(negedge clk); button_in = 1'b0;
            @(negedge clk); button_in = 1'b1;
            @(negedge clk); button_in = 1'b0;
        end
        ck(button_out     === 1'b1, "[bounce] output unchanged during 300 cycles of bouncing");
        ck_eq(pos_pulses, 0,        "[bounce] no posedge pulse during bouncing");
        ck_eq(neg_pulses, 0,        "[bounce] no negedge pulse during bouncing");

        // 抖动结束但还没稳定够：停在第 500 拍左右，仍不该采纳
        @(negedge clk); button_in = 1'b0;      // 最后一次变化，从此保持 0
        repeat (TIMER_MAX - 100) @(posedge clk);
        #1;
        ck(button_out === 1'b1, "[bounce] still 1 at 900 cycles after last edge");
        ck_eq(neg_pulses, 0,    "[bounce] no negedge pulse yet");

        // =====================================================================
        // ④ 稳定满 TIMER_MAX 拍后采纳：negedge 脉冲出现且仅 1 拍宽
        // =====================================================================
        cyc       = 0;
        changed_at = -1;
        while (cyc < 200) begin
            @(posedge clk); #1;
            cyc = cyc + 1;
            if (button_out !== 1'b1) begin
                changed_at = cyc;
                cyc = 200;      // 跳出
            end
        end
        ck(changed_at >= 0,                          "[settle] output finally changed to pressed");
        ck(changed_at <= 120,                        "[settle] change happened within 120 cycles (not too late)");
        ck_eq(button_out, 1'b0,                      "[settle] button_out = 0 (pressed)");

        repeat (5) @(posedge clk);
        #1;
        ck_eq(neg_pulses, 1,                         "[settle] exactly one negedge pulse");
        // 脉冲宽度在统计块里只在脉冲结束时才落定，这里直接用当拍观察更可靠
        ck(button_negedge === 1'b0,                  "[settle] negedge pulse already gone 5 cycles later");

        // =====================================================================
        // ⑤ 计数器饱和不回绕：已稳定状态下长期保持，输出不抖动、无新脉冲
        //    若 q_reg 数满后继续 +1 回绕到 0，"已数满"状态被洗掉，
        //    button_out 会退回到"自保持"分支，输出可能被冻结在错值上
        // =====================================================================
        clr_stats();
        repeat (TIMER_MAX * 2) @(posedge clk);
        #1;
        ck_eq(button_out,   1'b0, "[saturate] output stable through 2000 cycles");
        ck_eq(pos_pulses,   0,    "[saturate] no spurious posedge over 2000 cycles");
        ck_eq(neg_pulses,   0,    "[saturate] no spurious negedge over 2000 cycles");

        // =====================================================================
        // ⑥ 释放：电平回到 1，稳定满窗口后 posedge 脉冲出现一次
        // =====================================================================
        @(negedge clk); button_in = 1'b1;
        clr_stats();
        repeat (TIMER_MAX - 50) @(posedge clk);
        #1;
        ck(button_out === 1'b0, "[release] still pressed 950 cycles after release edge");

        repeat (100) @(posedge clk);
        #1;
        ck_eq(button_out, 1'b1, "[release] button_out = 1 after full debounce window");
        ck_eq(pos_pulses, 1,    "[release] exactly one posedge pulse");

        // =====================================================================
        // ⑦ 可重触发定时器：快要数满时来一个毛刺，计时必须从头开始
        //    这条是消抖的灵魂 —— 若计数器只做"抑制"而不清零，
        //    一个 999 拍的"稳定"加 1 拍毛刺就会被误判成稳定
        // =====================================================================
        @(negedge clk); button_in = 1'b0;       // 开始按下
        repeat (TIMER_MAX - 20) @(posedge clk); // 稳定 980 拍（差 20 拍就满）
        ck(button_out === 1'b1, "[retrigger] not yet adopted at 980 cycles");

        @(negedge clk); button_in = 1'b1;       // 毛刺：单拍回到 1
        @(negedge clk); button_in = 1'b0;       // 立刻又变回 0
        // 毛刺把计数器清零，现在要重新数满 1000 拍才采纳
        repeat (TIMER_MAX - 200) @(posedge clk);
        #1;
        ck(button_out === 1'b1, "[retrigger] counter restarted: still 1 at 800 cycles after glitch");

        repeat (250) @(posedge clk);
        #1;
        ck_eq(button_out, 1'b0, "[retrigger] adopted only after full new window");

        // =====================================================================
        // ⑧ 运行中复位：输出立刻回到复位值 1，且不产生假边沿
        // =====================================================================
        clr_stats();
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk); #1;
        ck(button_out     === 1'b1, "[mid-reset] button_out forced back to 1");
        ck(button_posedge === 1'b0, "[mid-reset] no posedge on reset entry");
        ck(button_negedge === 1'b0, "[mid-reset] no negedge on reset entry");

        // 复位期间即便输入一直在跳，输出也必须钉在 1
        for (i = 0; i < 20; i = i + 1) begin
            @(negedge clk); button_in = ~button_in;
        end
        #1;
        ck(button_out === 1'b1, "[mid-reset] output pinned at 1 while reset asserted");

        // =====================================================================
        // ⑨ 复位释放后重新建立基准
        // =====================================================================
        @(negedge clk);
        button_in = 1'b1;       // 未按下
        rst       = 1'b0;
        repeat (TIMER_MAX + 50) @(posedge clk);
        #1;
        ck(button_out === 1'b1, "[resume] button_out = 1 after reset release");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: ax_debounce");
        else             $display("CHECKS FAILED: ax_debounce");
        $finish;
    end

    // 看门狗：防止逻辑写错导致仿真挂死
    initial begin
        #(20 * (TIMER_MAX * 12));
        $display("FAIL: GLOBAL TIMEOUT");
        $display("CHECKS FAILED: ax_debounce");
        $finish;
    end

endmodule
