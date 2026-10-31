// =============================================================================
// tb_pcm_to_pwm.v —— pcm_to_pwm 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块的规格】
//   24 bit PCM → 1 bit 一阶 sigma-delta 调制器。核心三条：
//
//   1) 零阶保持：sample_hold 只在 sample_valid 那拍更新，其余时间保持不变。
//
//   2) 量程映射：sample_ext = {sample_hold + 2^23, 8'b0}
//      即中心（sample=0）→ 2^31 → 50% 占空比；
//      满正（sample=+2^23-1）→ 约 100%；满负 → 约 0%。
//
//   3) 一阶噪声整形：acc(n+1) = acc(n) + x  (mod 2^32)，y = acc(n+1)[31]
//      取模等价于 acc(n+1) = acc(n) + x - y*2^32，
//      所以 **输出的长期平均值（占空比）严格等于 x / 2^32**。
//      这条"占空比 = x / 2^32"是本 TB 的核心判据：它同时验证了累加、
//      取最高位、以及"同拍"（若 pwm_q 晚一拍，占空比在平稳信号下仍然对，
//      但在突变样本的第一个周期会差 1 拍——这一点用脉冲位置判据补齐）。
//
//   4) 静音：mute=1 时 pwm_out 恒 0（低电平静音，与原 pwm_audio_out 一致），
//      且调制器本身仍在跑（恢复瞬间不会有残留旧样本的爆音）。
//
// 【占空比怎么测才可靠】
//   单个样本周期里的占空比是量化的（32 位累加器不可能在短窗口里精确表达
//   任意比例），所以必须对"同一个样本持续很多个时钟"做统计。
//   本 TB 的做法：给一个样本，然后跑 N 个时钟（N 取 4096 的整数倍，
//   即 2^12，保证统计窗口与累加器周期对齐），数 1 的个数，与理论值比对，
//   容差取窗口长度的千分之一。
//
// 【参数缩放】
//   本模块没有可缩放的 parameter，全部行为都是 32 位算术，
//   clk 频率只影响时间轴，不影响任何判据 → 直接用 40ns 周期。
// =============================================================================
`timescale 1ns / 1ps

module tb_pcm_to_pwm;

    // ---- 统计窗口（必须是 2 的幂，且能被 2^12 整除）-----------------------
    localparam WIN = 4096;      // 一个样本连续跑 4096 个时钟
    localparam TOL = 4;         // 占空比容差（4096 的千分之一）

    // ---- 时钟 --------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #20 clk = ~clk;      // 40ns

    // ---- DUT ---------------------------------------------------------------
    reg         rst_n;
    reg         sample_valid;
    reg  signed [23:0] sample_in;
    reg         mute;
    wire        pwm_out;

    pcm_to_pwm u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_valid (sample_valid),
        .sample_in    (sample_in),
        .mute         (mute),
        .pwm_out      (pwm_out)
    );

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    integer known_issues;
    initial begin checks = 0; errors = 0; known_issues = 0; end

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

    // ---- 送一个样本（零阶保持会记住它）-------------------------------------
    task send_sample(input signed [23:0] s);
        begin
            @(negedge clk);
            sample_in    = s;
            sample_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            sample_valid = 1'b0;
        end
    endtask

    // ---- 在 n 个时钟里数 pwm_out 为高的拍数 --------------------------------
    task count_high(input integer n, output integer high);
        integer t;
        begin
            high = 0;
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk);
                if (pwm_out === 1'b1) high = high + 1;
            end
        end
    endtask

    // ---- 理论占空比 --------------------------------------------------------
    //   duty = (sample + 2^23) / 2^24 * ncyc
    //
    //   注意：不能用整数乘法 `ofs * ncyc`——ofs 最大 2^24-1、ncyc 取 4096/8192 时
    //   乘积达 3.4e10，远超 32 位 integer 的 2.1e9 上界，会溢出成负数再截断成 0，
    //   导致所有期望值都是 0（这个坑在首运行时把 9 项 duty 断言全部误判成 FAIL）。
    //   这里改用 real 做除法，先把比例算出来再乘窗口长度。
    function integer duty_of;
        input integer s24;              // 有符号 24 位样本，用 integer 承载
        input integer ncyc;
        real frac;
        begin
            frac    = (s24 + 8388608) / 16777216.0;   // 落在 0.0 .. 1.0
            duty_of = frac * ncyc;
        end
    endfunction

    // 测一个样本的占空比。
    // 设计律：duty = (sample + 2^23) / 2^24 * ncyc
    // 【历史缺陷，已修复】修复前对 1/4、1/8 这类中间量占空比恒为 50%（取的是
    // 截断和的 bit31 而非进位）。RTL 已改 33 位累加器取 acc_next[32]，现在
    // 占空比严格跟随输入；本 task 因此恢复为硬断言，偏离设计律即判 FAIL。
    task check_duty(input signed [23:0] s, input integer ncyc,
                    input [8*100-1:0] label);
        integer high;
        integer exp;
        integer diff;
        integer tol;
        begin
            send_sample(s);
            count_high(ncyc, high);
            exp  = duty_of(s, ncyc);
            tol  = ncyc / 512;          // 约 0.2% 窗口长度
            if (tol < 4) tol = 4;
            diff = high - exp;
            if (diff < 0) diff = -diff;
            checks = checks + 1;
            if (diff <= tol) begin
                $display("PASS: %0s  (high=%0d exp=%0d)", label, high, exp);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s  (high=%0d exp=%0d diff=%0d) - duty does not track DC input",
                         label, high, exp, diff);
            end
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    integer high;
    integer exp;
    integer pulse_max;
    integer pulse_run;
    reg     pwm_d;

    initial begin
        $display("=== tb_pcm_to_pwm start (WIN=%0d) ===", WIN);
        rst_n        = 1'b0;
        sample_valid = 1'b0;
        sample_in    = 24'sd0;
        mute         = 1'b0;

        // =====================================================================
        // ① 复位值
        // =====================================================================
        repeat (5) @(posedge clk);
        #1;
        ck(pwm_out === 1'b0,                "[reset] pwm_out low");
        ck(u_dut.acc === 32'd0,             "[reset] accumulator cleared");
        ck(u_dut.sample_hold === 24'sd0,    "[reset] sample_hold cleared");
        ck(u_dut.pwm_q === 1'b0,            "[reset] pwm_q cleared");

        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // =====================================================================
        // ② 零阶保持：不送新样本时 sample_hold 必须一动不动
        // =====================================================================
        send_sample(24'sd1234567);
        #1;
        ck(u_dut.sample_hold === 24'sd1234567,
                                            "[hold] sample captured on sample_valid");
        repeat (200) @(posedge clk);
        #1;
        ck(u_dut.sample_hold === 24'sd1234567,
                                            "[hold] sample held for 200 cycles without valid");

        // 换一个样本必须靠 sample_valid，光改 sample_in 无效
        @(negedge clk);
        sample_in = 24'sd7654321;           // 只改数据、不给 valid
        repeat (50) @(posedge clk);
        #1;
        ck(u_dut.sample_hold === 24'sd1234567,
                                            "[hold] data change without valid is ignored");
        @(negedge clk);
        sample_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        sample_valid = 1'b0;
        #1;
        ck(u_dut.sample_hold === 24'sd7654321,
                                            "[hold] valid latches the new sample");

        // =====================================================================
        // ③ 量程映射：sample_ext = {sample + 2^23, 8'b0}
        //    中心 0 → 2^31；最大正 → 约 2^32；最大负 → 约 0
        // =====================================================================
        send_sample(24'sd0);
        #1;
        ck(u_dut.sample_ofs === 24'd8388608,
                                            "[scale] zero sample maps to 2^23 offset");
        ck(u_dut.sample_ext === 32'h8000_0000,
                                            "[scale] zero sample -> 2^31 (50% duty)");

        send_sample(24'sh7FFFFF);           // 最大正
        #1;
        ck(u_dut.sample_ext === 32'hFFFF_FF00,
                                            "[scale] max positive -> near full scale");

        send_sample(24'sh800000);           // 最大负
        #1;
        ck(u_dut.sample_ext === 32'h0000_0000,
                                            "[scale] max negative -> zero increment");

        // =====================================================================
        // ④ 占空比 = x / 2^32（一阶 sigma-delta 的核心不变量）
        //    每个样本跑 WIN 个时钟做统计
        // =====================================================================
        check_duty(24'sd0,         WIN,     "[duty] zero sample -> 50%");
        check_duty(24'sh400000,    WIN,     "[duty] +1/4 FS -> 75%");
        check_duty(24'shC00000,    WIN,     "[duty] -1/4 FS -> 25%");
        check_duty(24'sh200000,    WIN,     "[duty] +1/8 FS -> 62.5%");
        check_duty(24'shE00000,    WIN,     "[duty] -1/8 FS -> 37.5%");
        check_duty(24'sh7FFFFF,    WIN,     "[duty] max positive -> ~100%");
        check_duty(24'sh800000,    WIN,     "[duty] max negative -> ~0%");
        check_duty(24'sh000001,    WIN * 2, "[duty] tiny positive -> slightly above 50%");
        check_duty(24'shFFFFFE,    WIN * 2, "[duty] tiny negative -> slightly below 50%");

        // =====================================================================
        // ⑤ 根因诊断：pwm_q 取的是"和的 bit31"，而不是"进位"
        //    ------------------------------------------------------------------
        //    设计律要求 duty = x / 2^32，其中 x = {sample+2^23, 8'b0}。
        //
        //    一阶 sigma-delta 的反馈式是  acc(n+1) = (acc(n) + x) mod 2^32 ，
        //    这个"mod 2^32"正是"减掉 y*2^32"那一步，所以 y 必须取**进位**
        //    （33 位和的最高的第 32 位），而不是 32 位截断和的 bit31。
        //    这两个信号在数学上不等价：
        //
        //      进位  = 1  ⟺  acc + x >= 2^32          （溢出，需减回去）
        //      bit31 = 1  ⟺  (acc + x) mod 2^32 >= 2^31（截断和的符号位）
        //
        //    而本模块的 x 恒为 256 的倍数、acc 也从 0 起，于是 acc 的全部取值
        //    是"256 的倍数"这一等距点集，该点集恰好对 2^31 对称 —— 于是
        //    "bit31 = 1" 恒占整整一半的时间。任何直流输入都得到 50% 占空比，
        //    这正是 §④ 里 9 个 duty 用例全部落在 2048/4096 的原因。
        //
        //    本段把两种解释同时算出来对照，把根因钉死在断言里：
        //      · DUT 实测        → 应等于"bit31 解释"（证明实现就是错的）
        //      · "进位解释"模型  → 应精确等于设计律（证明进位才是对的）
        //    选 x = 0xC0000000（+1/4 FS）时两种解释的差异是 1/4 对 1/2，
        //    周期 4 拍，4096 拍窗口下分别是 3072 与 2048，均为整数、无舍入误差。
        // =====================================================================
        begin : carry_root_cause
            integer k;
            integer b31_high;
            integer cy_high;
            integer dut_high;
            reg [32:0] msum;
            reg [31:0] macc;

            // 复位建立确定性起点（acc=0），再锁存 1/4 FS 样本
            @(negedge clk);
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            send_sample(24'sh400000);       // +1/4 FS → x = 0xC0000000
            #1;
            ck(u_dut.sample_ext === 32'hC000_0000,
                                            "[rootcause] +1/4 FS yields x = 0xC0000000");

            // 从 acc=0 起同步推进 33 位模型，同时数 DUT 输出的高电平拍数
            macc    = 32'd0;
            b31_high = 0;
            cy_high  = 0;
            dut_high = 0;
            for (k = 0; k < WIN; k = k + 1) begin
                msum = {1'b0, macc} + {1'b0, 32'hC000_0000};
                if (msum[31]) b31_high = b31_high + 1;   // 截断和的 bit31
                if (msum[32]) cy_high  = cy_high  + 1;   // 真正的进位
                macc = msum[31:0];
                @(negedge clk);
                if (pwm_out === 1'b1) dut_high = dut_high + 1;
            end

            $display("      [rootcause] dut_high=%0d  bit31_model=%0d  carry_model=%0d  law=%0d",
                     dut_high, b31_high, cy_high, (WIN*3)/4);

            // 这一段原来是"缺陷根因诊断"：证明实现取的是和的 bit31 而不是进位，
            // 导致任何直流输入都输出 50% 占空比。RTL 已修复（acc 改 33 位、
            // 取 acc_next[32]），所以这里翻转为"修复回归护栏"——
            // 一旦有人把取位改回 bit31，下面 ①② 会立刻失败，缺陷无法悄悄回归。
            //
            // 期望值参考：x = 0xC0000000 即 +1/4 FS，正确的占空比应为 3/4。

            // ① DUT 的输出逐拍等于"和的进位" → 证明实现取的是进位（正确）
            ck_eq(dut_high, cy_high,
                     "[rootcause] DUT duty == carry-of-sum interpretation (fixed)");

            // ② 进位解释下占空比精确等于设计律 3/4
            ck_eq(cy_high, (WIN*3)/4,
                     "[rootcause] carry interpretation yields the correct 75% duty");

            // ③ 若退回 bit31，占空比会恒为 1/2 —— DUT 必须不等于它
            ck_eq(b31_high, WIN/2,
                     "[rootcause] bit31 interpretation would yield a flat 50% duty");
            ck(dut_high !== b31_high,
                     "[rootcause] measured duty is NOT the buggy bit31 behaviour");
        end

        // =====================================================================
        // ⑥ 噪声整形：直流输入下单个脉冲宽度必须有界
        //    一阶 sigma-delta 在直流输入下的最大连 0/连 1 长度约为 1/(1-duty)，
        //    若有人把 pwm_q 写成"计数器比较"式实现，这里会出现几百拍的常量段。
        //    这里只是宽松上界：任何一个连续段的长度都必须远小于窗口长度。
        //    注意：本项与⑤的缺陷无关——即使取错信号，噪声整形仍然成立，
        //    所以这里是**真实通过**的断言，用来排除"实现退化成普通计数器"。
        // =====================================================================
        send_sample(24'sh400000);           // 75% 占空比
        pulse_max = 0;
        pulse_run = 0;
        pwm_d     = 1'b0;
        for (i = 0; i < WIN; i = i + 1) begin
            @(negedge clk);
            if (pwm_out === pwm_d) begin
                pulse_run = pulse_run + 1;
            end else begin
                if (pulse_run > pulse_max) pulse_max = pulse_run;
                pulse_run = 1;
                pwm_d     = pwm_out;
            end
        end
        if (pulse_run > pulse_max) pulse_max = pulse_run;
        ck(pulse_max < 64,                  "[sigma-delta] longest constant run < 64 cycles");
        $display("      longest constant run = %0d cycles", pulse_max);

        // =====================================================================
        // ⑥ 静音：pwm_out 恒 0，但调制器仍在跑（内部 acc 继续变化）
        // =====================================================================
        send_sample(24'sd0);                // 50% 占空比的样本
        @(negedge clk);
        mute = 1'b1;
        high = 0;
        count_high(200, high);
        ck_eq(high, 0,                      "[mute] pwm_out stuck low while muted");
        ck(mute === 1'b1 && pwm_out === 1'b0,
                                            "[mute] mute overrides the modulator output");

        // 静音期间内部累加器照常推进（不是被冻结）
        begin : muted_acc
            reg [31:0] a1;
            reg [31:0] a2;
            a1 = u_dut.acc;
            repeat (20) @(posedge clk);
            a2 = u_dut.acc;
            ck(a1 !== a2,                   "[mute] modulator still running while muted");
        end

        @(negedge clk);
        mute = 1'b0;
        count_high(200, high);
        ck(high > 80,                       "[mute] output resumes after unmute");

        // =====================================================================
        // ⑦ 运行中复位：累加器与保持值清空、输出低
        // =====================================================================
        send_sample(24'sh400000);
        repeat (100) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        ck(u_dut.acc === 32'd0,             "[mid-reset] accumulator cleared");
        ck(u_dut.sample_hold === 24'sd0,    "[mid-reset] sample_hold cleared");
        ck(pwm_out === 1'b0,                "[mid-reset] pwm_out low");
        // 复位期间送样本也不能被锁存
        @(negedge clk);
        sample_in    = 24'sh200000;
        sample_valid = 1'b1;
        repeat (5) @(posedge clk);
        #1;
        ck(u_dut.sample_hold === 24'sd0,    "[mid-reset] sample not latched during reset");
        @(negedge clk);
        sample_valid = 1'b0;

        // =====================================================================
        // ⑧ 复位释放后恢复调制
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        check_duty(24'sd0,     WIN,         "[resume] zero sample -> 50% after reset");
        check_duty(24'sh400000, WIN,        "[resume] +1/4 FS -> 75% after reset");

        // =====================================================================
        // ⑩ 极性方向钉子：正样本占空比必须大于负样本（防符号搞反）
        //    量程映射：duty = 0.5 + 0.5 * sample/2^23。
        //    所以 ±1/8 FS 的理论占空比是 0.5625 与 0.4375，差值 = WIN/8 = 512。
        //    注意这里必须用 >=：差值恰好等于 WIN/8，写 > 会因取整差 1 而误报。
        // =====================================================================
        begin : polarity
            integer hi_pos;
            integer hi_neg;
            send_sample(24'sh100000);       // +1/8 FS → 0.5625
            count_high(WIN, hi_pos);
            send_sample(24'shF00000);       // -1/8 FS → 0.4375
            count_high(WIN, hi_neg);
            checks = checks + 1;
            if (hi_pos > hi_neg) begin
                $display("PASS: [polarity] positive sample has higher duty than negative");
            end else begin
                errors = errors + 1;
                $display("FAIL: [polarity] duty not monotonic in sign (pos=%0d neg=%0d)",
                         hi_pos, hi_neg);
            end
            checks = checks + 1;
            if (hi_pos - hi_neg >= (WIN/8 - 8)) begin
                $display("PASS: [polarity] duty difference is about FS/4 span (diff=%0d)",
                         hi_pos - hi_neg);
            end else begin
                errors = errors + 1;
                $display("FAIL: [polarity] duty difference too small (diff=%0d expected ~%0d)",
                         hi_pos - hi_neg, WIN/8);
            end
        end

        // =====================================================================
        // 汇总
        //   曾经登记的 12 条 KNOWN ISSUE（9 个 duty + resume 1 个 + polarity 2 个）
        //   全部源自"取截断和 bit31 而不是进位"这一个缺陷；RTL 修复后它们
        //   已全部转为硬断言，因此正常情况下 known_issues 应为 0。
        // =====================================================================
        $display("SUMMARY: checks=%0d errors=%0d known_issues=%0d",
                 checks, errors, known_issues);
        if (errors == 0) $display("ALL CHECKS PASSED: pcm_to_pwm");
        else             $display("CHECKS FAILED: pcm_to_pwm");
        $finish;
    end

    // ---- 看门狗（必须大于全部用例的总时钟数）------------------------------
    //   本 TB 的统计窗口很长：9 个 duty 用例约 45000 拍，加上极性、静音、
    //   复位等约 60000 拍，按 40ns 计约 2.4ms → 给 20ms 余量。
    initial begin
        #20000000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("CHECKS FAILED: pcm_to_pwm");
        $finish;
    end

endmodule
