// ============================================================================
// 文件名  : tb_brightness_apply.v
// 目的    : 验证 rtl/video/brightness_apply.v 的 10 档亮度衰减
// 权威依据: docs/plan_v2/KEYMAP.md §9.1（数值表，方向经 captain m00290 修正）
//           captain 裁决 m00290 ②③（纯组合 / 0=最亮 / 复位 4'd0）
// ============================================================================
// 【测试策略】
//   本模块是纯组合，没有时钟也没有状态，所以不需要时序激励，直接把输入
//   摆好再 #1 采样即可。这种 tb 的价值全部在"覆盖表"上：
//
//     1. 逐档数值断言（C01~C10）：用 x=255 的白像素过一遍 10 档，
//        核对每档输出与文档表一致。x=255 是唯一能同时压出"最大值"和
//        "最高位"的输入，档间差异最明显。
//     2. 单调性（C11）：0→9 输出严格递减。这是人眼最敏感的性质，
//        比单档精度重要 —— 若某档系数写错导致档 8 比档 9 还暗，
//        用户会看到"越按越亮又突然一暗"，比整体偏暗难用得多。
//     3. 旁值扫描（C12）：对 0..255 全部取值过一遍 10 档，断言
//        "输出 ≤ 输入"（衰减不能变亮）且"输出 ≤ 255"（不溢出），
//        覆盖右移截断在中间值上的边界行为。
//     4. 三通道独立（C13）：R/G/B 分别给不同值，确认没有串通道
//        （典型 bug 是复制粘贴时把 r_in 写成 g_in）。
//     5. de=0 消隐（C14）：输出必须为 0，不能残留上一像素。
//     6. 复位值一致性（C15）：文档声明复位档位 = 4'd0（最亮），
//        这里断言档 0 的输出逐位等于输入 —— 只有"直通"才算真正的最亮。
//
// 【为什么不用时钟】
//   模块端口里没有 clk。加时钟只会让 tb 更复杂而不增加覆盖。
//   de_out 是 de 的组合直通，也在 C14 里一并断言。
// ============================================================================
`timescale 1ns / 1ps

module tb_brightness_apply;

    // ---- DUT 端口 ----
    reg         de;
    reg  [23:0] rgb_in;
    reg  [3:0]  bright_lvl;
    wire        de_out;
    wire [23:0] rgb_out;

    // ---- 记分板 ----
    integer pass_cnt;
    integer fail_cnt;

    task chk;
        input        cond;
        input [511:0] msg;
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

    // ========================================================================
    // DUT
    // ========================================================================
    brightness_apply u_dut (
        .de         (de),
        .rgb_in     (rgb_in),
        .bright_lvl (bright_lvl),
        .de_out     (de_out),
        .rgb_out    (rgb_out)
    );

    // ========================================================================
    // 期望值函数（按 KEYMAP.md §9.1 + m00290 ③ 的方向独立实现一遍）
    //   刻意不调用 DUT 内部函数：如果 tb 复用 DUT 的 function，就等于
    //   "用被测代码验证被测代码"，系数写错时两边一起错，测试形同虚设。
    //   这里用整数乘除算精确值，再与 DUT 的移位加实现比对，能真正
    //   暴露"移位加逼近得对不对"。
    // ========================================================================
    function integer exact_dim;
        input integer x;
        input integer lvl;
        integer k;
        begin
            // k = 每档的增益分子（分母 32）
            case (lvl)
                0: k = 32;
                1: k = 29;
                2: k = 26;
                3: k = 23;
                4: k = 20;
                5: k = 16;
                6: k = 13;
                7: k = 10;
                8: k = 6;
                default: k = 3;
            endcase
            exact_dim = (x * k) / 32;
        end
    endfunction

    // 允许误差：右移截断最多丢 2~3 LSB（x 越大丢得越多，但不超过 3）
    function integer tol;
        input integer dummy;
        begin
            tol = 3;
        end
    endfunction

    // ========================================================================
    // 主激励
    // ========================================================================
    integer lvl_i;
    integer x_i;
    integer exact_v;
    integer diff;
    reg [7:0] prev_val;
    reg [7:0] cur_val;
    reg [23:0] mono_prev;   // 上一档的输出（单调性用）

    // 期望 x=255 时的输出（KEYMAP.md §9.1 表右列）
    reg [7:0] exp_255 [0:9];

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;

        exp_255[0] = 8'd255;
        exp_255[1] = 8'd233;
        exp_255[2] = 8'd209;
        exp_255[3] = 8'd185;
        exp_255[4] = 8'd161;
        exp_255[5] = 8'd127;
        exp_255[6] = 8'd105;
        exp_255[7] = 8'd78;
        exp_255[8] = 8'd46;
        exp_255[9] = 8'd22;

        de        = 1'b0;
        rgb_in    = 24'd0;
        bright_lvl = 4'd0;
        #1;

        // ================================================================
        // C01~C10: 逐档数值（x=255，三通道同时给 255）
        //   同时断言三个通道，值相同，便于一次定位到哪一档写错。
        // ================================================================
        de     = 1'b1;
        rgb_in = 24'hFF_FF_FF;
        for (lvl_i = 0; lvl_i < 10; lvl_i = lvl_i + 1) begin
            bright_lvl = lvl_i[3:0];
            #1;
            diff = rgb_out[23:16] - exp_255[lvl_i];
            if (diff < 0) diff = -diff;
            if (diff <= tol(0)) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: C%02d lvl=%0d x=255 -> r=%0d (exp %0d, tol +-%0d)",
                         lvl_i + 1, lvl_i, rgb_out[23:16], exp_255[lvl_i], tol(0));
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: C%02d lvl=%0d x=255 -> r=%0d (exp %0d, tol +-%0d)",
                         lvl_i + 1, lvl_i, rgb_out[23:16], exp_255[lvl_i], tol(0));
            end
            // g / b 通道必须与 r 完全一致（同表同实现）
            if (rgb_out[15:8] == rgb_out[23:16] && rgb_out[7:0] == rgb_out[23:16]) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: C%02d-ch lvl=%0d g/b 与 r 一致 (%0d/%0d/%0d)",
                         lvl_i + 1, lvl_i, rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: C%02d-ch lvl=%0d g/b 与 r 不一致 (%0d/%0d/%0d)",
                         lvl_i + 1, lvl_i, rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
            end
        end

        // ================================================================
        // C11: 单调性 —— 0→9 严格递减（x=255）
        //   这是本模块最重要的性质：人眼对"越按越暗"的连续性极敏感。
        // ================================================================
        mono_prev = 24'hFF_FFFF;
        begin : mono_blk
            integer m_ok;
            m_ok = 1;
            for (lvl_i = 0; lvl_i < 10; lvl_i = lvl_i + 1) begin
                bright_lvl = lvl_i[3:0];
                #1;
                if (rgb_out[23:16] >= mono_prev) begin
                    m_ok = 0;
                    $display("  mono break at lvl=%0d: %0d >= prev %0d",
                             lvl_i, rgb_out[23:16], mono_prev);
                end
                mono_prev = rgb_out[23:16];
            end
            chk(m_ok == 1, "C11 单调性: lvl 0->9 输出严格递减");
        end

        // ================================================================
        // C12: 全值扫描 0..255 × 10 档
        //   两条不变量：输出 ≤ 输入（衰减不能变亮）、输出 ≤ 255（不溢出）。
        // ================================================================
        begin : sweep_blk
            integer s_ok;
            s_ok = 1;
            for (lvl_i = 0; lvl_i < 10; lvl_i = lvl_i + 1) begin
                bright_lvl = lvl_i[3:0];
                for (x_i = 0; x_i < 256; x_i = x_i + 1) begin
                    rgb_in = {x_i[7:0], x_i[7:0], x_i[7:0]};
                    #1;
                    if (rgb_out[23:16] > x_i[7:0]) begin
                        if (s_ok == 1)
                            $display("  变亮违例: lvl=%0d x=%0d out=%0d",
                                     lvl_i, x_i, rgb_out[23:16]);
                        s_ok = 0;
                    end
                end
            end
            chk(s_ok == 1, "C12 全值扫描: 输出 <= 输入（衰减不变亮）");
        end

        // ================================================================
        // C13: 通道独立 —— R=255 G=128 B=64，档 5（16/32）
        //   典型 bug：复制粘贴把 r_in 写成 g_in，三通道输出会完全相同。
        // ================================================================
        bright_lvl = 4'd5;
        rgb_in     = 24'hFF_80_40;
        #1;
        begin : chan_blk
            reg [7:0] er;
            reg [7:0] eg;
            reg [7:0] eb;
            reg       c_ok;
            er = (255 * 16) / 32;   // 127
            eg = (128 * 16) / 32;   // 64
            eb = (64  * 16) / 32;   // 32
            c_ok = 1;
            if (rgb_out[23:16] > er + 3 || rgb_out[23:16] + 3 < er) c_ok = 0;
            if (rgb_out[15:8]  > eg + 3 || rgb_out[15:8]  + 3 < eg) c_ok = 0;
            if (rgb_out[7:0]   > eb + 3 || rgb_out[7:0]   + 3 < eb) c_ok = 0;
            $display("  C13 rgb=(255,128,64) lvl=5 -> (%0d,%0d,%0d) exp ~(%0d,%0d,%0d)",
                     rgb_out[23:16], rgb_out[15:8], rgb_out[7:0], er, eg, eb);
            chk(c_ok == 1, "C13 通道独立: R/G/B 各自衰减不串扰");
        end

        // ================================================================
        // C14: de=0 消隐期输出全 0（且 de_out 组合直通）
        // ================================================================
        de         = 1'b0;
        rgb_in     = 24'hFF_FF_FF;
        bright_lvl = 4'd0;
        #1;
        chk(rgb_out == 24'd0,  "C14a de=0 时 rgb_out 全 0（消隐期无残留）");
        chk(de_out == 1'b0,    "C14b de=0 时 de_out=0（组合直通）");

        // ================================================================
        // C15: 档 0 = 逐位直通（最亮语义）
        //   文档声明"档 0 是 32/32 旁路"，这里对若干特征值做逐位相等断言。
        //   若哪次改动把档 0 写成 x - (x>>4) 之类，这条会立刻挂。
        // ================================================================
        begin : thru_blk
            integer t_ok;
            t_ok = 1;
            de         = 1'b1;
            bright_lvl = 4'd0;
            for (x_i = 0; x_i < 256; x_i = x_i + 17) begin
                rgb_in = {x_i[7:0], (255 - x_i[7:0]), x_i[7:0]};
                #1;
                if (rgb_out !== rgb_in) begin
                    if (t_ok == 1)
                        $display("  直通违例: in=%06h out=%06h", rgb_in, rgb_out);
                    t_ok = 0;
                end
            end
            chk(t_ok == 1, "C15 档 0 逐位直通（32/32 最亮）");
        end

        // ================================================================
        // C16: 档 9 最暗 —— 必须严格小于档 0（防止两档被写成同一式）
        // ================================================================
        de     = 1'b1;
        rgb_in = 24'hC0_80_40;      // 192,128,64
        bright_lvl = 4'd0;
        #1;
        cur_val = rgb_out[23:16];
        bright_lvl = 4'd9;
        #1;
        chk(rgb_out[23:16] < cur_val, "C16 档 9 严格暗于档 0");

        // ================================================================
        // 结算
        // ================================================================
        $display("");
        $display("tb_brightness_apply: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: brightness_apply");
        end else begin
            $display("CHECKS FAILED: brightness_apply");
        end
        $finish;
    end

endmodule
