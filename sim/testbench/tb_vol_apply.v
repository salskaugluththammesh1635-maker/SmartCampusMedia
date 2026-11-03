// ============================================================================
//  tb_vol_apply.v —— rtl/audio/vol_apply.v 的单元测试台
// ----------------------------------------------------------------------------
//  覆盖（captain m01078 明确要求的判据全部在内）：
//    V01  复位：sample_out = 0、eff_lvl 跟随 vol_lvl、sample_valid_out = 0
//    V02  10 档增益表逐档数值（满量程正样本 x=+8388607）
//    V03  ★ 方向（正半轴）：out(0) < out(9) —— 音量档越大越响
//    V04  ★ 方向（负半轴）：|out(0)| < |out(9)| —— 必须用绝对值
//    V05  ★ 负半轴符号位仍为 1（抓 >>> 误写成 >> 的符号翻转）
//    V06  10 档单调递增（正半轴，严格）
//    V07  10 档绝对值单调递增（负半轴，严格）
//    V08  档 9 满幅逐位直通（正、负两个满量程）
//    V09  近零样本不爆幅（abs24(out) <= 16，容忍 ±2 LSB 真量化）
//    V10  饱和：不可能超过 24 位满量程
//    V11  audio_en = 0 → sample_out 逐位为 0（严格静音由这里实现）
//    V12  应急钳位：mode=2 且 vol_lvl<3 时 eff_lvl=3，但 vol_lvl 寄存器不被改写
//    V13  应急钳位不影响 mode 0/1
//    V14  非应急时 eff_lvl == vol_lvl（含越界 10~15 的兜底）
//    V15  无 sample_valid 时输出保持上一值（不归零 —— 归零经 sigma-delta 是爆音）
//
//  ★★ 为什么 V03/V04 必须成对出现（这是本 tb 存在的核心理由）★★
//     音频是有符号 24 位。在负半轴上「更响」= 绝对值更大 = **数值更小**。
//     若只在正半轴验方向，把 `>>>`（算术右移）写成 `>>`（逻辑右移）的
//     bug 完全检不出 —— -8388608 >> 4 = +524288，符号翻成正数大音量，
//     而正半轴断言全过。这类失效与「亮度/音量方向相反」同源：
//     方向对、但符号错。
//
//  消息全 ASCII（ModelSim 在 Windows 按系统代码页写日志，中文会变 ????）。
// ============================================================================
`timescale 1ns / 1ps

module tb_vol_apply;

    // ------------------------------------------------------------------
    //  时钟 / 复位
    // ------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;          // 25 MHz（周期 40 ns）

    // ------------------------------------------------------------------
    //  DUT 端口
    // ------------------------------------------------------------------
    reg                sample_valid = 1'b0;
    reg  signed [23:0] sample_in    = 24'sd0;
    reg  [3:0]         vol_lvl      = 4'd6;
    reg  [1:0]         mode         = 2'd0;
    reg                audio_en     = 1'b1;

    wire               sample_valid_out;
    wire signed [23:0] sample_out;
    wire [3:0]         eff_lvl;

    vol_apply #(
        .VOL_MAX (4'd9)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_valid     (sample_valid),
        .sample_in        (sample_in),
        .vol_lvl          (vol_lvl),
        .mode             (mode),
        .audio_en         (audio_en),
        .sample_valid_out (sample_valid_out),
        .sample_out       (sample_out),
        .eff_lvl          (eff_lvl)
    );

    // ------------------------------------------------------------------
    //  记分板
    // ------------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk(input cond, input [1023:0] msg);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  绝对值（24 位有符号）：-8388608 → 8388608，用 25 位存
    // ------------------------------------------------------------------
    function [24:0] abs24(input signed [23:0] x);
        begin
            if (x[23]) abs24 = (~{x[23], x} + 25'd1);
            else       abs24 = {x[23], x};
        end
    endfunction

    // ------------------------------------------------------------------
    //  推一个样本进去，取回输出
    //    单拍脉冲：拉高 sample_valid 一拍，下一拍 #1 采 sample_out
    // ------------------------------------------------------------------
    reg signed [23:0] cap_out;
    task push(input signed [23:0] x);
        begin
            @(negedge clk);
            sample_in    = x;
            sample_valid = 1'b1;
            @(negedge clk);
            sample_valid = 1'b0;
            @(posedge clk);
            #1;
            cap_out = sample_out;
        end
    endtask

    // 带档位设置的推样本
    reg signed [23:0] vol_out [0:15];
    task meas(input [3:0] lvl, input signed [23:0] x);
        begin
            vol_lvl = lvl;
            push(x);
            vol_out[lvl] = cap_out;
        end
    endtask

    // ------------------------------------------------------------------
    //  期望值：用**独立**的整数乘除算，不复用 DUT 的移位表达式
    //    档位增益（与 vol_apply.v 表同源，但用乘除而不是移位加，
    //    这样 DUT 里任何一处移位写错都会被抓到）
    // ------------------------------------------------------------------
    function integer gain_num(input [3:0] lvl);
        begin
            case (lvl)
                4'd0: gain_num = 3;
                4'd1: gain_num = 6;
                4'd2: gain_num = 10;
                4'd3: gain_num = 13;
                4'd4: gain_num = 16;
                4'd5: gain_num = 20;
                4'd6: gain_num = 23;
                4'd7: gain_num = 26;
                4'd8: gain_num = 29;
                default: gain_num = 32;
            endcase
        end
    endfunction

    function integer exact_out(input integer x, input [3:0] lvl);
        integer p;
        begin
            p = x * gain_num(lvl);
            if (p >= 0) exact_out = p / 32;
            else        exact_out = -((-p + 31) / 32);   // 向负无穷舍入
        end
    endfunction

    // ------------------------------------------------------------------
    //  主流程
    // ------------------------------------------------------------------
    integer k;
    integer mism;
    integer bad;

    initial begin
        $display("=== tb_vol_apply start ===");

        // ================================================================
        //  V01 复位
        // ================================================================
        rst_n = 1'b0;
        vol_lvl = 4'd0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk); #1;
        chk(sample_out       === 24'sd0, "V01a reset: sample_out == 0");
        chk(sample_valid_out === 1'b0,   "V01b reset: sample_valid_out == 0");
        chk(eff_lvl          === 4'd0,   "V01c reset: eff_lvl follows vol_lvl (0)");

        // ================================================================
        //  V02 10 档数值（满量程正样本）
        // ================================================================
        $display("");
        $display("---- V02: 10-level gain table (x = +8388607) ----");
        for (k = 0; k < 10; k = k + 1) meas(k[3:0], 24'sh7F_FFFF);
        for (k = 0; k < 10; k = k + 1) begin
            $display("     level %0d: out = %0d (exact %0d)",
                     k, vol_out[k], exact_out(8388607, k[3:0]));
            // 容差 ±2 LSB：移位加实现与整数乘除的舍入差
            bad = vol_out[k] - exact_out(8388607, k[3:0]);
            if (bad < 0) bad = -bad;
            chk(bad <= 2, "V02 level table value within +/-2 LSB");
        end

        // ================================================================
        //  V03 ★ 方向（正半轴）—— 必须与 V04 相邻
        // ================================================================
        $display("");
        $display("---- V03/V04: direction (positive axis and negative axis) ----");
        chk(vol_out[0] < vol_out[9],
            "V03 volume direction: out(0) < out(9) (positive axis)");

        // ================================================================
        //  V04 ★ 方向（负半轴，用绝对值）—— 必须紧跟上一条
        // ================================================================
        for (k = 0; k < 10; k = k + 1) meas(k[3:0], -24'sh80_0000);
        chk(abs24(vol_out[0]) < abs24(vol_out[9]),
            "V04 volume direction: |out(0)| < |out(9)| (negative axis, abs needed)");

        // ================================================================
        //  V05 ★ 负半轴符号位仍为 1（抓 >>> 写成 >> 的符号翻转）
        // ================================================================
        chk(vol_out[0][23] === 1'b1, "V05a negative axis: out(0) sign bit still 1");
        chk(vol_out[9][23] === 1'b1, "V05b negative axis: out(9) sign bit still 1");
        chk(vol_out[4][23] === 1'b1, "V05c negative axis: out(4) sign bit still 1");

        // ================================================================
        //  V06 正半轴严格单调递增
        // ================================================================
        for (k = 0; k < 10; k = k + 1) meas(k[3:0], 24'sh7F_FFFF);
        mism = 0;
        for (k = 0; k < 9; k = k + 1)
            if (!(vol_out[k] < vol_out[k+1])) mism = mism + 1;
        chk(mism == 0, "V06 strictly increasing across 10 levels (positive axis)");

        // ================================================================
        //  V07 负半轴绝对值严格单调递增
        // ================================================================
        for (k = 0; k < 10; k = k + 1) meas(k[3:0], -24'sh80_0000);
        mism = 0;
        for (k = 0; k < 9; k = k + 1)
            if (!(abs24(vol_out[k]) < abs24(vol_out[k+1]))) mism = mism + 1;
        chk(mism == 0, "V07 strictly increasing |out| across 10 levels (negative axis)");

        // ================================================================
        //  V08 档 9 满幅逐位直通
        // ================================================================
        meas(4'd9, 24'sh7F_FFFF);
        chk(vol_out[9] === 24'sh7F_FFFF, "V08a level 9 passes +full-scale bit-exact");
        meas(4'd9, -24'sh80_0000);
        chk(vol_out[9] === -24'sh80_0000, "V08b level 9 passes -full-scale bit-exact");

        // ================================================================
        //  V09 近零样本不爆幅
        //    负数算术右移向负无穷舍入，档 0 两项各舍到 -1 相加得 -2
        //    （理想值 -0.09），这是固有量化，±2 LSB / 24 位 = 2.4e-7。
        //    真正要抓的失效是 >> 的爆幅：-1 >> 4 = +16,777,215 →
        //    饱和成 +8,388,607。所以判据取 abs <= 16 两者都能满足。
        // ================================================================
        $display("");
        $display("---- V09: near-zero samples must not blow up ----");
        mism = 0;
        for (k = 0; k < 10; k = k + 1) begin
            meas(k[3:0], -24'sd1);
            if (abs24(vol_out[k]) > 25'd16) begin
                $display("     level %0d: out(-1) = %0d  <-- too large", k, vol_out[k]);
                mism = mism + 1;
            end
        end
        chk(mism == 0, "V09a out(-1) magnitude <= 16 for all 10 levels (no sign-flip blow-up)");
        meas(4'd5, 24'sd1);
        chk(abs24(vol_out[5]) <= 25'd16, "V09b out(+1) magnitude <= 16 at level 5 (symmetry)");

        // ================================================================
        //  V10 饱和：任何档位都不越 24 位满量程
        // ================================================================
        mism = 0;
        for (k = 0; k < 10; k = k + 1) begin
            meas(k[3:0], 24'sh7F_FFFF);
            if (vol_out[k] > 24'sh7F_FFFF) mism = mism + 1;
            meas(k[3:0], -24'sh80_0000);
            if (vol_out[k] < -24'sh80_0000) mism = mism + 1;
        end
        chk(mism == 0, "V10 never exceeds 24-bit full scale (saturation works)");

        // ================================================================
        //  V11 audio_en = 0 → 严格静音
        //    KEYMAP 里档 0 是 3/32（9.4%）而不是静音，所以"严格静音"
        //    只能由 audio_en 门控实现。这条必须逐位为 0，不能只是"很小"。
        // ================================================================
        $display("");
        $display("---- V11: audio_en gate (strict mute) ----");
        audio_en = 1'b0;
        mism = 0;
        for (k = 0; k < 10; k = k + 1) begin
            meas(k[3:0], 24'sh7F_FFFF);
            if (vol_out[k] !== 24'sd0) mism = mism + 1;
            meas(k[3:0], -24'sh80_0000);
            if (vol_out[k] !== 24'sd0) mism = mism + 1;
        end
        chk(mism == 0, "V11a audio_en=0 forces sample_out to exactly 0 for all levels");
        meas(4'd9, 24'sh7F_FFFF);
        chk(vol_out[9] === 24'sd0, "V11b audio_en=0 silences even at max level");
        audio_en = 1'b1;
        meas(4'd9, 24'sh7F_FFFF);
        chk(vol_out[9] === 24'sh7F_FFFF, "V11c audio_en=1 restores full output");

        // ================================================================
        //  V12 应急钳位：mode=2 且 vol_lvl < 3 → eff_lvl = 3
        //       但 vol_lvl 寄存器本身不被改写（退出应急要能恢复用户选择）
        // ================================================================
        $display("");
        $display("---- V12/V13/V14: emergency clamp ----");
        mode    = 2'd2;
        vol_lvl = 4'd0;
        @(posedge clk); #1;
        chk(eff_lvl === 4'd3, "V12a emergency + vol_lvl=0 -> eff_lvl clamped to 3");
        chk(vol_lvl === 4'd0, "V12b vol_lvl register NOT overwritten (user choice preserved)");
        // 钳位生效的直接证据：mode=2、vol_lvl=0 时的输出，必须与
        //   mode=0、vol_lvl=3 时的输出**逐位相同**（同一输入样本）。
        //   注意两次测量要用同一个 sample_in，且不能拿负满量程的旧值来比。
        meas(4'd0, 24'sh7F_FFFF);          // mode=2, vol_lvl=0 → 实际按档 3
        cap_out = vol_out[0];
        mode = 2'd0;
        meas(4'd3, 24'sh7F_FFFF);          // mode=0, vol_lvl=3 → 基准
        chk(cap_out === vol_out[3],
            "V12c emergency clamp: output at vol_lvl=0 equals level-3 output");
        mode = 2'd2;

        vol_lvl = 4'd2;
        @(posedge clk); #1;
        chk(eff_lvl === 4'd3, "V12d emergency + vol_lvl=2 -> eff_lvl clamped to 3");

        vol_lvl = 4'd3;
        @(posedge clk); #1;
        chk(eff_lvl === 4'd3, "V12e emergency + vol_lvl=3 -> eff_lvl stays 3 (boundary)");

        vol_lvl = 4'd7;
        @(posedge clk); #1;
        chk(eff_lvl === 4'd7, "V12f emergency + vol_lvl=7 -> eff_lvl stays 7 (above floor)");

        // ================================================================
        //  V13 应急钳位不影响 mode 0/1
        // ================================================================
        mode    = 2'd0;
        vol_lvl = 4'd0;
        @(posedge clk); #1;
        chk(eff_lvl === 4'd0, "V13a daily mode: no clamp (eff_lvl == vol_lvl == 0)");
        mode    = 2'd1;
        @(posedge clk); #1;
        chk(eff_lvl === 4'd0, "V13b science mode: no clamp (eff_lvl == vol_lvl == 0)");

        // ================================================================
        //  V14 非应急时 eff_lvl == vol_lvl，越界值兜底到 9
        // ================================================================
        mode = 2'd0;
        mism = 0;
        for (k = 0; k < 10; k = k + 1) begin
            vol_lvl = k[3:0];
            @(posedge clk); #1;
            if (eff_lvl !== k[3:0]) mism = mism + 1;
        end
        chk(mism == 0, "V14a non-emergency: eff_lvl == vol_lvl for 0..9");
        // ★ eff_lvl 只做**应急钳位**，不做越界钳位 —— 越界保护在
        //   lvl_safe（只作用于增益通路）。所以 vol_lvl=12 时 eff_lvl
        //   如实反映 12，而输出按 VOL_MAX=9 处理。两者职责不同，
        //   判据要分开验，别把两件事混成一条。
        vol_lvl = 4'd12;
        @(posedge clk); #1;
        chk(eff_lvl === 4'd12, "V14b eff_lvl reflects raw vol_lvl=12 (no over-range clamp here)");
        meas(4'd12, 24'sh7F_FFFF);
        chk(vol_out[12] === vol_out[9],
            "V14c over-range vol_lvl=12 gains like level 9 (lvl_safe clamps to VOL_MAX)");

        // ================================================================
        //  V15 无 sample_valid 时输出保持
        //    归零经 sigma-delta 是占空比阶跃 → 喇叭上一声"啪"
        // ================================================================
        $display("");
        $display("---- V15: hold last sample when no valid ----");
        vol_lvl = 4'd9;
        push(24'sh12_3456);
        chk(cap_out === 24'sh12_3456, "V15a pushed sample reaches output");
        sample_valid = 1'b0;
        sample_in    = 24'sh00_0000;    // 输入归零，但 valid=0
        repeat (10) @(posedge clk);
        #1;
        chk(sample_out === 24'sh12_3456,
            "V15b output holds last sample while sample_valid=0 (no zero step)");

        // ================================================================
        //  收尾
        // ================================================================
        $display("");
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: vol_apply");
        end else begin
            $display("CHECKS FAILED: vol_apply  pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
        $display("=== tb_vol_apply: pass=%0d fail=%0d ===", pass_cnt, fail_cnt);
        $finish;
    end

    // 全局超时
    initial begin
        #50_000_000;
        $display("GLOBAL TIMEOUT: tb_vol_apply");
        $finish;
    end

endmodule
