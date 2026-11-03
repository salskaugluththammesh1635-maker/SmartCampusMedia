// ============================================================================
// 文件名  : tb_thermal_guard.v
// 测试对象: rtl/sensor/thermal_guard.v
// 运行方式: vsim -c -quiet -onfinish stop -do "run -all; quit -f -code 0" work.tb_thermal_guard
// 通过标志: 打印 "ALL CHECKS PASSED: thermal_guard"
// ============================================================================
// 【这个测试台验证什么】
//   thermal_guard 是「阈值 → 迟滞 → 联动」这一层，它不认识任何具体传感器。
//   它的正确性有四条主线，本 tb 逐条覆盖：
//
//     一、阈值判定：45.00 ℃ 触发、40.00 ℃ 解除，边界值必须精确（>= / <=，
//         不是 > / <）。差一个等号，45.00 ℃ 就测不出来 —— 这种错误在仿真里
//         只会让一个用例失败，到了板子上却是"温度正好卡在阈值上时设备不响应"。
//     二、迟滞：40.00 ~ 44.99 ℃ 是保持区，状态必须冻结。若迟滞写错（比如
//         两个阈值写反，或者忘了带 !oth_en / oth_en 条件），会出现
//         "温度刚过 45 ℃ 就立刻退出"或"永远退不出高温"。
//     三、负温度：这是本项目最容易踩的坑。temp_centi_c 是 16 位有符号，
//         -40.00 ℃ 的位模式是 0xF060，按无符号解释等于 61536 —— 会被
//         判成"极高温度"直接触发应急。所以必须专门测负温度不触发。
//     四、失联：上游不再供数时，temp_alive 要拉低，但 oth_en **保持不变**。
//         若失联时强行退出高温，一次传感器故障就会让设备在真实高温下无动于衷。
//
// 【为什么用脉冲计数器而不是在时间点上采样】
//   oth_enter / oth_exit 是单拍脉冲。用"某个时刻读一下 oth_enter"的写法，
//   很可能刚好错过那一拍（读早了还没置起、读晚了已经回零），于是测试
//   时好时坏。改成 always @(posedge clk) 累计脉冲个数，只在需要的地方比较
//   计数的**增量**，时序上完全确定。
//
// 【为什么要把 STALE_CYCLES 覆盖成 200】
//   默认值是 50_000_000（2 秒 @25 MHz）。若用默认值测失联，光是等一次
//   失联就要仿真 200 万拍，日志和波形都会变得不可读。本 tb 把它覆盖成 200 拍
//   —— 判决逻辑与计数器宽度完全一样，只是把等待时间缩短，不影响结论。
//   默认值本身的可综合性由 lint + TD 综合保证，不需要在仿真里跑满。
// ============================================================================
`timescale 1ns/1ps

module tb_thermal_guard;

    // ------------------------------------------------------------------------
    // 时钟与复位
    // ------------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #20 clk = ~clk;            // 25 MHz，周期 40 ns

    // ------------------------------------------------------------------------
    // 被测模块端口
    //   temp_centi_c 必须声明为 signed，否则 tb 自己传负值时就会先错一次，
    //   那样测出来的"通过"毫无意义（错误被 tb 掩盖了）。
    // ------------------------------------------------------------------------
    reg  signed [15:0] temp_centi_c;
    reg                temp_valid;
    wire               oth_en;
    wire               oth_enter;
    wire               oth_exit;
    wire               temp_alive;

    thermal_guard #(
        .TH_HIGH      (16'sd4500),    // 45.00 ℃
        .TH_LOW       (16'sd4000),    // 40.00 ℃
        .STALE_CYCLES (200)           // 覆盖成 200 拍，见文件头说明
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .temp_centi_c (temp_centi_c),
        .temp_valid   (temp_valid),
        .oth_en       (oth_en),
        .oth_enter    (oth_enter),
        .oth_exit     (oth_exit),
        .temp_alive   (temp_alive)
    );

    // ------------------------------------------------------------------------
    // 记分板
    // ------------------------------------------------------------------------
    integer pass_cnt;
    integer fail_cnt;

    task chk;
        input         cond;
        input [639:0] msg;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // 脉冲计数（见文件头第二条说明）
    // ------------------------------------------------------------------------
    integer enter_cnt;
    integer exit_cnt;
    initial begin
        enter_cnt = 0;
        exit_cnt  = 0;
    end
    always @(posedge clk) begin
        if (oth_enter) enter_cnt = enter_cnt + 1;
        if (oth_exit)  exit_cnt  = exit_cnt + 1;
    end

    // ------------------------------------------------------------------------
    // 送一次温度读数（单拍 temp_valid）
    //   在 negedge 拉高、下一个 negedge 拉低 → 高电平恰好覆盖一个 posedge，
    //   DUT 采到且只采到一次。末尾再多等两拍，让 oth_en / oth_enter 稳定。
    // ------------------------------------------------------------------------
    task send_temp;
        input signed [15:0] t;
        begin
            @(negedge clk);
            temp_centi_c = t;
            temp_valid   = 1'b1;
            @(negedge clk);
            temp_valid   = 1'b0;
            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    // ------------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------------
    integer e0, x0;

    initial begin
        pass_cnt     = 0;
        fail_cnt     = 0;
        rst_n        = 1'b0;
        temp_valid   = 1'b0;
        temp_centi_c = 16'sd0;

        // ---- 复位 ----
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5)  @(posedge clk);

        // ====================================================================
        // C01 复位初值
        //   oth_en 必须是 0（上电默认正常展示内容，不能一上电就进应急）。
        //   temp_alive 也必须是 0 —— 还没收到任何读数，不能假装传感器正常。
        // ====================================================================
        chk(oth_en === 1'b0,     "C01 reset: oth_en=0 (power-on is normal)");
        chk(temp_alive === 1'b0, "C01 reset: temp_alive=0 (no reading yet)");

        // ====================================================================
        // C02 第一次有效读数把 temp_alive 拉高
        //   注意此时温度是常温 25.00 ℃，不应该触发高温。
        // ====================================================================
        send_temp(16'sd2500);
        chk(temp_alive === 1'b1, "C02 first valid reading raises temp_alive");
        chk(oth_en === 1'b0,     "C02 25.00C does not trigger");

        // ====================================================================
        // C03 阈值下沿：44.99 ℃ 不得触发（差 0.01 ℃ 也不行）
        //   这条专门防 ">= 写成 >" 和 "阈值常量差一位" 两类错误。
        // ====================================================================
        e0 = enter_cnt;
        send_temp(16'sd4499);
        chk((oth_en === 1'b0) && (enter_cnt == e0),
            "C03 44.99C (just below TH_HIGH) does not trigger");

        // ====================================================================
        // C04 阈值上沿：45.00 ℃ 恰好触发
        //   边界必须包含等号，否则"正好 45 ℃"这个最常见的工况测不出来。
        // ====================================================================
        e0 = enter_cnt;
        send_temp(16'sd4500);
        chk(oth_en === 1'b1,        "C04 45.00C (exactly TH_HIGH) triggers");
        chk(enter_cnt == e0 + 1,    "C04 oth_enter pulses exactly once");

        // ====================================================================
        // C05 迟滞保持区：42.00 ℃ 不得退出
        //   迟滞的作用就是让 40~44.99 ℃ 冻结状态。这里必须保持 oth_en=1，
        //   且不得产生 oth_exit 脉冲。
        // ====================================================================
        x0 = exit_cnt;
        send_temp(16'sd4200);
        chk((oth_en === 1'b1) && (exit_cnt == x0),
            "C05 42.00C inside hysteresis band keeps oth_en=1");

        // ====================================================================
        // C06 解除阈值上沿：40.01 ℃ 仍然不得退出
        // ====================================================================
        x0 = exit_cnt;
        send_temp(16'sd4001);
        chk((oth_en === 1'b1) && (exit_cnt == x0),
            "C06 40.01C (just above TH_LOW) still keeps oth_en=1");

        // ====================================================================
        // C07 解除阈值：40.00 ℃ 恰好退出
        // ====================================================================
        x0 = exit_cnt;
        send_temp(16'sd4000);
        chk(oth_en === 1'b0,     "C07 40.00C (exactly TH_LOW) releases");
        chk(exit_cnt == x0 + 1,  "C07 oth_exit pulses exactly once");

        // ====================================================================
        // C08 负温度不得触发（★ 本 tb 最重要的用例）
        //   -40.00 ℃ 的位模式 0xF060 按无符号是 61536。若判决比较没有按
        //   有符号语义做，它会被当成"极高温度"立刻触发应急 —— 而且这种
        //   错误在常温测试里永远不会暴露（AHT20 装在机箱里，实验室测不到
        //   负温度），只有专门构造负值才能发现。
        //   本例同时验证 -40.00（AHT20 量程下限）与 -1.00（接近 0 的负值，
        //   0xFFFF 段）两个点。
        // ====================================================================
        e0 = enter_cnt;
        send_temp(-16'sd4000);
        chk((oth_en === 1'b0) && (enter_cnt == e0),
            "C08 -40.00C does not trigger (signed compare works)");
        send_temp(-16'sd100);
        chk((oth_en === 1'b0) && (enter_cnt == e0),
            "C08 -1.00C does not trigger (signed compare works)");

        // ====================================================================
        // C09 负温度下温度回升到 45.00 ℃ 仍能正确触发
        //   验证有符号比较不是"一律判负"这种反向错误。
        // ====================================================================
        e0 = enter_cnt;
        send_temp(-16'sd4000);
        send_temp(16'sd4500);
        chk((oth_en === 1'b1) && (enter_cnt == e0 + 1),
            "C09 from -40.00C up to 45.00C triggers exactly once");
        send_temp(16'sd4000);          // 复位回正常，供后续用例使用

        // ====================================================================
        // C10 没有 temp_valid 时，温度值变化不得影响状态
        //   真实链路里 temp_centi_c 会一直保持上一次的读数（上游寄存器输出），
        //   而 temp_valid 只有更新那一拍才为 1。若判决没带 temp_valid 条件，
        //   同一次采样会被重复判决上千万次 —— 结果虽然相同，但会让
        //   oth_enter 连发、污染下游。
        // ====================================================================
        e0 = enter_cnt;
        @(negedge clk);
        temp_centi_c = 16'sd8000;      // 80 ℃，但不给 valid
        repeat (50) @(posedge clk);
        chk((oth_en === 1'b0) && (enter_cnt == e0),
            "C10 no temp_valid: value change alone does not trigger");
        @(negedge clk);
        temp_centi_c = 16'sd2500;

        // ====================================================================
        // C11 失联检测：连续 STALE_CYCLES 拍无读数 → temp_alive 拉低
        //   此时 oth_en=0（正常），失联后必须仍为 0（不主动进高温）。
        // ====================================================================
        send_temp(16'sd2500);          // 先确认存活
        chk(temp_alive === 1'b1, "C11 alive before silence");
        repeat (260) @(posedge clk);   // 超过 STALE_CYCLES=200
        chk(temp_alive === 1'b0, "C11 silent beyond STALE_CYCLES -> temp_alive=0");
        chk(oth_en === 1'b0,     "C11 stale while normal: oth_en stays 0");

        // ====================================================================
        // C12 失联后恢复：再来一次有效读数 → temp_alive 重新拉高
        // ====================================================================
        send_temp(16'sd2500);
        chk(temp_alive === 1'b1, "C12 valid reading restores temp_alive");

        // ====================================================================
        // C13 高温状态下失联：oth_en 必须保持为 1
        //   ★ 这是"最保守"策略的核心断言。若失联时把 oth_en 清 0，
        //   一次 AHT20 排线松动就会让设备在真实高温下退回日常模式，
        //   风扇/告警全停 —— 这是安全相关的失效，必须堵死。
        // ====================================================================
        send_temp(16'sd4600);          // 46 ℃ 触发
        chk(oth_en === 1'b1, "C13 46.00C triggers before silence");
        repeat (260) @(posedge clk);   // 超过 STALE_CYCLES
        chk(temp_alive === 1'b0, "C13 silent -> temp_alive=0");
        chk(oth_en === 1'b1,
            "C13 stale while hot: oth_en HOLDS 1 (fail-safe, not fail-open)");

        // ====================================================================
        // C14 失联恢复后仍能正常退出高温
        //   验证失联期间没有把状态机卡死。
        // ====================================================================
        x0 = exit_cnt;
        send_temp(16'sd3900);          // 39 ℃，低于 TH_LOW
        chk((oth_en === 1'b0) && (exit_cnt == x0 + 1),
            "C14 after recovery, 39.00C releases normally");

        // ====================================================================
        // 汇总
        // ====================================================================
        repeat (10) @(posedge clk);
        $display("");
        $display("=================================================");
        $display(" tb_thermal_guard: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        $display("=================================================");
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: thermal_guard");
        end else begin
            $display("CHECKS FAILED: thermal_guard (%0d failures)", fail_cnt);
        end
        $finish;
    end

    // ------------------------------------------------------------------------
    // 全局超时
    // ------------------------------------------------------------------------
    initial begin
        #1_000_000;
        $display("TIMEOUT: thermal_guard simulation exceeded 1 ms");
        $display("CHECKS FAILED: thermal_guard (timeout)");
        $finish;
    end

endmodule
