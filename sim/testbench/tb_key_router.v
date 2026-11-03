// ============================================================================
// 文件名  : tb_key_router.v
// 目的    : 验证 rtl/control/key_router.v 的 Key4~Key15 键译码
// 权威依据: docs/plan_v2/KEYMAP.md §7（端口契约）、§8（键号判定表）、
//           §9（档位值表）、§5（三模式作用域矩阵）、§5.1（应急音量下限）、
//           §5.2（ticker_en 与 viz_en 必须独立）
//           captain 裁决 m00290 ③（bright_lvl 复位 4'd0 = 最亮）
// ============================================================================
// 【测试策略】
//   本模块是纯组合逻辑 + 一组寄存器，测试核心是**寄存器语义**，不是时序。
//   用例分组：
//
//   组 A · 复位值（C01）
//     三个开关全 1、bright_lvl=0（最亮）、vol_lvl=6、res_sel=4、ratio_sel=4。
//     复位值本身就是用户看到的初始状态，写错会直接变成"上电黑屏"或
//     "上电静音"这类现场故障，必须断言。
//
//   组 B · 10 档 / 5 档循环（C02~C07）
//     每个参数键连按 12 次，断言"0→1→…→9→0"的环绕点精确。
//     环绕点是最容易写错的地方（> 与 >= 之差），单看代码看不出来。
//
//   组 C · 一键一模块纪律（C08、C09）
//     把 Key0~Key3 全部按一遍，断言本模块的任何寄存器都不动。
//     这条测试的价值：将来若有人为了"顺手"把 Key2 也接进来，
//     会立刻红。
//
//   组 D · 应急钳位（C10~C13）
//     这是本模块最微妙的地方，也是唯一有"两套语义"的地方：
//       - audio_en / ticker_en 的**寄存器**保持用户值不变
//       - audio_en_eff / ticker_en_eff 的输出被钳位到 1
//     测试必须同时断言这两件事。只测前者会漏掉"应急时没声音"，
//     只测后者会漏掉"退出应急后用户设置被偷改"。
//
//   组 E · ticker_en 与 viz_en 独立（C14）
//     按 Key5 只影响 ticker_en，按 Key10 只影响 viz_en，两者互不干扰。
//     这是 KEYMAP §5.2 明令禁止合并的一对信号。
//
//   组 F · osd_pop_req 单拍与 osd_item 编码（C15~C18）
//     面板弹出请求必须是单拍 —— 若变成持续高，参数面板会一直挂着不消失。
//     同时核对 osd_item 的编码与文档一致（下游 osd_panel 靠它选文字）。
//
//   组 G · P2 备用键（C19）
//     P2_EN=0 时 Key11~Key15 不得产生任何输出变化。
// ============================================================================
`timescale 1ns / 1ps

module tb_key_router;

    localparam integer CLK_PERIOD = 40;     // 25 MHz

    // ---- DUT 端口 ----
    reg        clk;
    reg        rst_n;
    reg        key_event;
    reg  [3:0] key_code;
    reg  [1:0] mode;

    wire [3:0] bright_lvl;
    wire [3:0] vol_lvl;
    wire [2:0] res_sel;
    wire [2:0] ratio_sel;
    wire       audio_en;
    wire       ticker_en;
    wire       viz_en;
    wire       osd_pop_req;
    wire [4:0] osd_item;
    wire       audio_en_eff;
    wire       ticker_en_eff;
    wire       rescan_req;
    wire [2:0] pattern_sel;
    wire       invert_en;
    wire       grid_en;
    wire       beep_muted;

    // ---- 记分板 ----
    integer pass_cnt;
    integer fail_cnt;

    task chk;
        input         cond;
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
    // DUT（P2_EN = 0，与默认配置一致）
    // ========================================================================
    key_router #(
        .CLK_FREQ_HZ (25_000_000),
        .OSD_HOLD_MS (2500),
        .P2_EN       (1'b0)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .key_event    (key_event),
        .key_code     (key_code),
        .mode         (mode),
        .bright_lvl   (bright_lvl),
        .vol_lvl      (vol_lvl),
        .res_sel      (res_sel),
        .ratio_sel    (ratio_sel),
        .audio_en     (audio_en),
        .ticker_en    (ticker_en),
        .viz_en       (viz_en),
        .osd_pop_req  (osd_pop_req),
        .osd_item     (osd_item),
        .audio_en_eff (audio_en_eff),
        .ticker_en_eff(ticker_en_eff),
        .rescan_req   (rescan_req),
        .pattern_sel  (pattern_sel),
        .invert_en    (invert_en),
        .grid_en      (grid_en),
        .beep_muted   (beep_muted)
    );

    // ========================================================================
    // 时钟
    // ========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ========================================================================
    // 按键 task
    // ========================================================================
    task press_key;
        input [3:0] k;
        begin
            @(negedge clk);
            key_event = 1'b1;
            key_code  = k;
            @(negedge clk);
            key_event = 1'b0;
            key_code  = 4'd0;
            @(posedge clk);
            #1;
        end
    endtask

    // ========================================================================
    // osd_pop_req 单拍监视
    // ========================================================================
    integer pop_cnt;
    integer pop_wide;
    reg     pop_d;

    initial begin
        pop_cnt  = 0;
        pop_wide = 0;
        pop_d    = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pop_cnt  <= 0;
            pop_wide <= 0;
            pop_d    <= 1'b0;
        end else begin
            if (osd_pop_req) pop_cnt <= pop_cnt + 1;
            if (osd_pop_req && pop_d) pop_wide <= pop_wide + 1;
            pop_d <= osd_pop_req;
        end
    end

    // ========================================================================
    // 主激励
    // ========================================================================
    integer i;
    integer prev_v;

    initial begin
        pass_cnt  = 0;
        fail_cnt  = 0;
        rst_n     = 1'b0;
        key_event = 1'b0;
        key_code  = 4'd0;
        mode      = 2'd0;

        repeat (5) @(posedge clk);
        #1;

        // ================================================================
        // 组 A · 复位值
        // ================================================================
        chk(bright_lvl == 4'd0, "C01a 复位: bright_lvl = 0（**0 = 最亮**，m00290 ③）");
        chk(vol_lvl    == 4'd6, "C01b 复位: vol_lvl = 6（约 50%）");
        chk(res_sel    == 3'd4, "C01c 复位: res_sel = 4（640×480 原生档）");
        chk(ratio_sel  == 3'd4, "C01d 复位: ratio_sel = 4（满屏）");
        chk(audio_en   == 1'b1, "C01e 复位: audio_en = 1（开）");
        chk(ticker_en  == 1'b1, "C01f 复位: ticker_en = 1（开）");
        chk(viz_en     == 1'b1, "C01g 复位: viz_en = 1（开）");
        chk(osd_pop_req == 1'b0, "C01h 复位: osd_pop_req = 0（无面板请求）");

        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // ================================================================
        // 组 B · 亮度 10 档循环（Key6）
        // ================================================================
        // 从 0 连按 10 次应回到 0，中途逐档核对
        begin : brt_blk
            integer b_ok;
            b_ok = 1;
            for (i = 0; i < 10; i = i + 1) begin
                press_key(4'd6);
                if (bright_lvl !== ((i + 1) % 10)) begin
                    b_ok = 0;
                    $display("  亮度循环违例: 第 %0d 次按后 = %0d，期望 %0d",
                             i + 1, bright_lvl, (i + 1) % 10);
                end
            end
            chk(b_ok == 1, "C02 Key6 亮度: 0->1->...->9->0 十档循环");
        end
        // 环绕点专项：当前又回到 0，按第 10 次时必须是 9→0 而非 9→10
        chk(bright_lvl == 4'd0, "C03 亮度环绕点: 第 10 次按后精确回到 0");

        // ================================================================
        // 组 B2 · 音量 10 档循环（Key7）
        // ================================================================
        // 复位值是 6，从 6 按到 9 再回 0
        begin : vol_blk
            integer v_ok;
            v_ok = 1;
            for (i = 0; i < 10; i = i + 1) begin
                prev_v = vol_lvl;
                press_key(4'd7);
                if (prev_v == 9) begin
                    if (vol_lvl !== 4'd0) begin
                        v_ok = 0;
                        $display("  音量环绕违例: 9 之后 = %0d，期望 0", vol_lvl);
                    end
                end else begin
                    if (vol_lvl !== prev_v + 1) begin
                        v_ok = 0;
                        $display("  音量递增违例: %0d -> %0d", prev_v, vol_lvl);
                    end
                end
            end
            chk(v_ok == 1, "C04 Key7 音量: 十档递增 + 9->0 环绕");
        end

        // ================================================================
        // 组 B3 · 分辨率 5 档循环（Key8）
        // ================================================================
        begin : res_blk
            integer r_ok;
            r_ok = 1;
            for (i = 0; i < 10; i = i + 1) begin
                prev_v = res_sel;
                press_key(4'd8);
                if (prev_v == 4) begin
                    if (res_sel !== 3'd0) begin
                        r_ok = 0;
                        $display("  分辨率环绕违例: 4 之后 = %0d", res_sel);
                    end
                end else if (res_sel !== prev_v + 1) begin
                    r_ok = 0;
                    $display("  分辨率递增违例: %0d -> %0d", prev_v, res_sel);
                end
            end
            chk(r_ok == 1, "C05 Key8 分辨率: 5 档循环 + 4->0 环绕");
        end

        // ================================================================
        // 组 B4 · 屏占比 5 档循环（Key9）
        // ================================================================
        begin : ratio_blk
            integer q_ok;
            q_ok = 1;
            for (i = 0; i < 5; i = i + 1) begin
                prev_v = ratio_sel;
                press_key(4'd9);
                if (prev_v == 4) begin
                    if (ratio_sel !== 3'd0) begin
                        q_ok = 0;
                        $display("  屏占比环绕违例: 4 之后 = %0d", ratio_sel);
                    end
                end else if (ratio_sel !== prev_v + 1) begin
                    q_ok = 0;
                    $display("  屏占比递增违例: %0d -> %0d", prev_v, ratio_sel);
                end
            end
            chk(q_ok == 1, "C06 Key9 屏占比: 5 档循环 + 4->0 环绕");
        end

        // ================================================================
        // 组 B5 · 三开关翻转（Key4 / Key5 / Key10）
        // ================================================================
        begin : sw_blk
            reg a0, t0, v0;
            integer s_ok;
            s_ok = 1;
            // Key4 音频：两次翻转回原值
            a0 = audio_en;
            press_key(4'd4);
            if (audio_en === a0)             s_ok = 0;
            press_key(4'd4);
            if (audio_en !== a0)             s_ok = 0;
            // Key5 字幕
            t0 = ticker_en;
            press_key(4'd5);
            if (ticker_en === t0)            s_ok = 0;
            press_key(4'd5);
            if (ticker_en !== t0)            s_ok = 0;
            // Key10 可视化
            v0 = viz_en;
            press_key(4'd10);
            if (viz_en === v0)               s_ok = 0;
            press_key(4'd10);
            if (viz_en !== v0)               s_ok = 0;
            chk(s_ok == 1, "C07 Key4/Key5/Key10: 三个开关各自翻转且回环");
        end

        // ================================================================
        // 组 C · 一键一模块纪律：Key0~Key3 不得触碰本模块任何寄存器
        // ================================================================
        begin : other_key_blk
            reg [3:0] b0, v0r;
            reg [2:0] rs0, rt0;
            reg       a0, t0, vz0;
            integer   o_ok;
            b0 = bright_lvl; v0r = vol_lvl; rs0 = res_sel; rt0 = ratio_sel;
            a0 = audio_en;   t0  = ticker_en; vz0 = viz_en;
            o_ok = 1;
            for (i = 0; i < 4; i = i + 1) begin
                press_key(i[3:0]);
                if (bright_lvl !== b0 || vol_lvl !== v0r || res_sel !== rs0 ||
                    ratio_sel   !== rt0 || audio_en !== a0 || ticker_en !== t0 ||
                    viz_en      !== vz0) begin
                    o_ok = 0;
                    $display("  Key%0d 越界: 本模块寄存器被改动", i);
                end
            end
            chk(o_ok == 1, "C08 Key0~Key3 全部按过: 本模块寄存器零变化（一键一模块）");
        end

        // ---- C09 Key0~Key3 也不应发 osd_pop_req ----
        begin : other_pop_blk
            integer op_before;
            integer op_ok;
            op_ok = 1;
            repeat (2) @(posedge clk);
            op_before = pop_cnt;
            for (i = 0; i < 4; i = i + 1) press_key(i[3:0]);
            repeat (2) @(posedge clk);
            if (pop_cnt != op_before) op_ok = 0;
            chk(op_ok == 1, "C09 Key0~Key3: 不发 osd_pop_req（不抢面板）");
        end

        // ================================================================
        // 组 D · 应急钳位（本模块最微妙处）
        // ================================================================
        // 先把 audio_en / ticker_en 都关掉，进入应急后验证：
        //   寄存器保持 0（用户设置不被偷改）
        //   输出 eff 被钳位到 1（应急必须出声/出字）
        begin : emerg_blk
            // 确保两开关为 0
            if (audio_en)  press_key(4'd4);
            if (ticker_en) press_key(4'd5);
            #1;

            // ---- C10 日常下关掉 ----
            chk(audio_en == 1'b0 && ticker_en == 1'b0,
                "C10 日常: 音频与字幕均已关闭（用户设置）");
            chk(audio_en_eff == 1'b0 && ticker_en_eff == 1'b0,
                "C10b 日常: eff 输出跟随用户设置");

            // ---- C11 进入应急：eff 钳位，寄存器不变 ----
            @(negedge clk);
            mode = 2'd2;
            #1;
            chk(audio_en  == 1'b0 && ticker_en  == 1'b0,
                "C11a 应急: **寄存器保持用户值 0**（退出后能自动恢复）");
            chk(audio_en_eff == 1'b1 && ticker_en_eff == 1'b1,
                "C11b 应急: eff 输出被钳位到 1（必须出声/出字）");

            // ---- C12 应急下按 Key4/Key5 被忽略 ----
            press_key(4'd4);
            press_key(4'd5);
            #1;
            chk(audio_en == 1'b0 && ticker_en == 1'b0,
                "C12 应急下 Key4/Key5: 用户值不变（拒绝切换）");
            chk(audio_en_eff == 1'b1 && ticker_en_eff == 1'b1,
                "C12b 应急下 Key4/Key5: eff 仍钳位 1");

            // ---- C13 退出应急：恢复用户设置 ----
            @(negedge clk);
            mode = 2'd0;
            #1;
            chk(audio_en_eff == 1'b0 && ticker_en_eff == 1'b0,
                "C13 退出应急: eff 恢复用户设置 0（设置未被应急污染）");
        end

        // ================================================================
        // 组 E · ticker_en 与 viz_en 必须独立（KEYMAP §5.2 禁令）
        // ================================================================
        begin : indep_blk
            reg t0, v0;
            integer i_ok;
            i_ok = 1;
            // 都置 1
            if (!ticker_en) press_key(4'd5);
            if (!viz_en)    press_key(4'd10);
            #1;
            // 只按 Key5
            t0 = ticker_en; v0 = viz_en;
            press_key(4'd5);
            if (ticker_en === t0)  i_ok = 0;   // 必须变
            if (viz_en    !== v0)  i_ok = 0;   // 必须不变
            // 只按 Key10
            t0 = ticker_en; v0 = viz_en;
            press_key(4'd10);
            if (viz_en    === v0)  i_ok = 0;
            if (ticker_en !== t0)  i_ok = 0;
            chk(i_ok == 1, "C14 Key5(ticker) 与 Key10(viz) 完全独立，无耦合");
        end

        // ================================================================
        // 组 F · osd_pop_req 单拍 + osd_item 编码
        // ================================================================
        // ---- C15 参数键必须发 pop，且 osd_item 编码正确 ----
        begin : pop_item_blk
            integer p_ok;
            p_ok = 1;
            // Key4 -> item 0
            @(negedge clk); key_event = 1'b1; key_code = 4'd4;
            @(negedge clk); key_event = 1'b0; key_code = 4'd0;
            #1;
            if (!osd_pop_req || osd_item !== 5'd0) begin
                p_ok = 0; $display("  Key4: pop=%b item=%0d (exp 0)", osd_pop_req, osd_item);
            end
            repeat (2) @(posedge clk);
            // Key5 -> item 1
            @(negedge clk); key_event = 1'b1; key_code = 4'd5;
            @(negedge clk); key_event = 1'b0; key_code = 4'd0;
            #1;
            if (!osd_pop_req || osd_item !== 5'd1) begin
                p_ok = 0; $display("  Key5: pop=%b item=%0d (exp 1)", osd_pop_req, osd_item);
            end
            repeat (2) @(posedge clk);
            // Key6 -> item 2
            @(negedge clk); key_event = 1'b1; key_code = 4'd6;
            @(negedge clk); key_event = 1'b0; key_code = 4'd0;
            #1;
            if (!osd_pop_req || osd_item !== 5'd2) begin
                p_ok = 0; $display("  Key6: pop=%b item=%0d (exp 2)", osd_pop_req, osd_item);
            end
            repeat (2) @(posedge clk);
            // Key7 -> item 3
            @(negedge clk); key_event = 1'b1; key_code = 4'd7;
            @(negedge clk); key_event = 1'b0; key_code = 4'd0;
            #1;
            if (!osd_pop_req || osd_item !== 5'd3) begin
                p_ok = 0; $display("  Key7: pop=%b item=%0d (exp 3)", osd_pop_req, osd_item);
            end
            repeat (2) @(posedge clk);
            // Key8 -> item 4
            @(negedge clk); key_event = 1'b1; key_code = 4'd8;
            @(negedge clk); key_event = 1'b0; key_code = 4'd0;
            #1;
            if (!osd_pop_req || osd_item !== 5'd4) begin
                p_ok = 0; $display("  Key8: pop=%b item=%0d (exp 4)", osd_pop_req, osd_item);
            end
            repeat (2) @(posedge clk);
            // Key9 -> item 5
            @(negedge clk); key_event = 1'b1; key_code = 4'd9;
            @(negedge clk); key_event = 1'b0; key_code = 4'd0;
            #1;
            if (!osd_pop_req || osd_item !== 5'd5) begin
                p_ok = 0; $display("  Key9: pop=%b item=%0d (exp 5)", osd_pop_req, osd_item);
            end
            repeat (2) @(posedge clk);
            // Key10 -> item 6
            @(negedge clk); key_event = 1'b1; key_code = 4'd10;
            @(negedge clk); key_event = 1'b0; key_code = 4'd0;
            #1;
            if (!osd_pop_req || osd_item !== 5'd6) begin
                p_ok = 0; $display("  Key10: pop=%b item=%0d (exp 6)", osd_pop_req, osd_item);
            end
            repeat (2) @(posedge clk);
            chk(p_ok == 1, "C15 osd_item 编码: Key4..Key10 -> item 0..6 逐一对齐");
        end

        // ---- C16 pop 全程单拍 ----
        chk(pop_wide == 0, "C16 osd_pop_req 全程单拍（无连续两拍为高）");
        $display("  共发生 %0d 次 osd_pop_req 脉冲", pop_cnt);

        // ---- C17 参数键之外的键不发 pop（已在 C09 测 Key0~3，这里补 Key11~15）----
        begin : p2_pop_blk
            integer p2_ok;
            integer p2_before;
            p2_ok = 1;
            repeat (2) @(posedge clk);
            p2_before = pop_cnt;
            for (i = 11; i < 16; i = i + 1) press_key(i[3:0]);
            repeat (2) @(posedge clk);
            if (pop_cnt != p2_before) p2_ok = 0;
            chk(p2_ok == 1, "C17 Key11~Key15(P2 关闭): 不发 osd_pop_req");
        end

        // ================================================================
        // 组 G · P2 备用键（P2_EN = 0 时零输出）
        // ================================================================
        begin : p2_blk
            integer g_ok;
            g_ok = 1;
            for (i = 11; i < 16; i = i + 1) begin
                press_key(i[3:0]);
                if (rescan_req !== 1'b0 || pattern_sel !== 3'd0 ||
                    invert_en  !== 1'b0 || grid_en     !== 1'b0 ||
                    beep_muted !== 1'b0) begin
                    g_ok = 0;
                    $display("  P2 越界: 按 Key%0d 后 rescan=%b pat=%0d inv=%b grid=%b beep=%b",
                             i, rescan_req, pattern_sel, invert_en, grid_en, beep_muted);
                end
            end
            chk(g_ok == 1, "C18 P2_EN=0: Key11~Key15 不产生任何输出变化");
        end

        // ================================================================
        // C19 复位能清掉一切
        // ================================================================
        press_key(4'd6);
        press_key(4'd4);
        #1;
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        chk(bright_lvl == 4'd0 && vol_lvl == 4'd6 &&
            res_sel == 3'd4 && ratio_sel == 3'd4,
            "C19a 复位: 四个档位寄存器回到默认");
        chk(audio_en == 1'b1 && ticker_en == 1'b1 && viz_en == 1'b1,
            "C19b 复位: 三个开关回到 1");

        // ================================================================
        // 结算
        // ================================================================
        $display("");
        $display("tb_key_router: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: key_router");
        end else begin
            $display("CHECKS FAILED: key_router");
        end
        $finish;
    end

    // 全局超时
    initial begin
        #5_000_000;
        $display("GLOBAL TIMEOUT: key_router");
        $finish;
    end

endmodule
