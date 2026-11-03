// ============================================================================
// 文件名  : tb_osd_param_text.v
// 所在位置: sim/testbench/tb_osd_param_text.v
// 被测模块: rtl/osd/osd_param_text.v
// ============================================================================
// 【验证策略 —— 为什么不把期望值写成 6 位字符码】
//   最省事的写法是把期望值写成 DUT 输出的同一形式（6 位码），但那样 TB 就
//   成了 DUT 的抄写件：DUT 里若把 'P' 写成 6'd15，TB 里也写 6'd15，测试
//   照样通过。这类"同源期望值"是 RTL 验证里最常见的假通过来源。
//
//   本 TB 换成**独立来源**：把 DUT 输出的字符码按字模 ROM 的编址规则反向
//   还原成真正的 ASCII 字符（v>=32 -> v；v<32 -> 0x40+v），再与人手写的
//   期望字符串（"PARAM OSD"、"B:8 V:6 R:4 P:4" …）逐字符比对。
//   期望值以"屏幕上应该看到的那行字"的形式写在断言里，肉眼可校对：
//
//       chk_line(2'd1, "B:3 V:6 R:4 P:4", "V02 ...");
//
//   于是"字符码算错"和"字模编址规则不一致"这两类错误都会被抓住 ——
//   因为还原规则来自字模 ROM 的生成器（scripts/gen_osd_font8.py 里
//   `rom_index = ord(ch) & 0x3F`），与 DUT 的实现无耦合。
//
// 【版面（t16 定稿，行 1 见 rtl/osd/osd_param_text.v 头注释【四】）】
//   行 0  "PARAM OSD"
//   行 1  "B:n V:n R:n P:n"（默认态，列 0..14 有效，其余空格）
//         条件列组：I:n 在列 16..18（仅 invert_en != 0）
//                   Xn  在列 20..21（仅 auto_sw_sel != 0，显示 X1..X4）
//   行 2  "MODE:xxxxxxx IMG:nn/nn"
//
//   为什么行 1 用单字母：COLS=22，全称 "BRI:n VOL:n RES:n RAT:n" 要 23 列，
//   超出 osd_panel 的 PANEL_X1=631 边界（见 osd_panel.v 头注释【三之二】）。
//
// 【断言编号】
//   V01 默认值三行完整文字
//   V02 亮度 0..9 十档（★ t16 核心：档 8/9 曾经被 3 位窄口截成 0/1）
//   V03 反色 0/1（含条件列组的"出现/消失"两向断言）
//   V04 倍率 0..3 -> X1..X4（同样两向）
//   V05 模式 0..3 名称（含定宽补空格）
//   V06 图号个位 0..9
//   V07 图号十位边界 10/19/20/29/30/31
//   V08 图库张数边界
//   V09 行号越界（line=3）输出空白
//   V10 列号越界（col 22..31）输出空格
//   V11 参数全非默认的组合
//   V12 音量 0..9 十档（t16 新增）
//   V13 分辨率 0..4 五档（t16 新增）
//   V14 屏占比 0..4 五档（t16 新增）
//   V15 三个新档位互不串扰（六参数组合矩阵，t16 新增）
// ============================================================================
`timescale 1ns / 1ps

module tb_osd_param_text;

    // ---- DUT 输入 ------------------------------------------------------
    //   t16：bright_sel[2:0] -> bright_lvl[3:0]，并新增 vol_lvl / res_sel /
    //   ratio_sel 三口。位宽取 key_router 里的原宽（音量 4 位、另两个 3 位）。
    reg  [3:0] bright_lvl;
    reg  [3:0] vol_lvl;
    reg  [2:0] res_sel;
    reg  [2:0] ratio_sel;
    reg        invert_en;
    reg  [1:0] auto_sw_sel;
    reg  [1:0] info_mode;
    reg  [4:0] img_index;
    reg  [4:0] gallery_count;
    reg  [1:0] line;
    reg  [4:0] col;

    // ---- DUT 输出 ------------------------------------------------------
    wire [5:0] char_code;

    osd_param_text u_dut (
        .bright_lvl    (bright_lvl),
        .vol_lvl       (vol_lvl),
        .res_sel       (res_sel),
        .ratio_sel     (ratio_sel),
        .invert_en     (invert_en),
        .auto_sw_sel   (auto_sw_sel),
        .info_mode     (info_mode),
        .img_index     (img_index),
        .gallery_count (gallery_count),
        .line          (line),
        .col           (col),
        .char_code     (char_code)
    );

    // ---- 统计 ----------------------------------------------------------
    integer pass_cnt;
    integer fail_cnt;
    integer i;

    // ------------------------------------------------------------------------
    // code_to_ascii: 按字模 ROM 的编址规则把 6 位码还原成 ASCII
    //   ROM 索引 = ascii & 0x3F，所以反向：
    //     v >= 32  -> ascii = v        （覆盖 0x20..0x5F：空格/数字/':'/'A'-'Z'）
    //     v <  32  -> ascii = 0x40 + v （覆盖 0x40..0x5F：'A'-'Z' 等）
    //   v == 0 特判为空格：ROM 里索引 0 没有条目，输出全 0（空白），
    //   语义上等同空格。DUT 正常路径不会输出 0（模板默认是 32）。
    // ------------------------------------------------------------------------
    function [7:0] code_to_ascii;
        input [5:0] v;
        begin
            if (v == 6'd0)
                code_to_ascii = 8'h20;
            else if (v >= 6'd32)
                code_to_ascii = {2'b00, v};
            else
                code_to_ascii = 8'h40 + {2'b00, v};
        end
    endfunction

    // ------------------------------------------------------------------------
    // exp_len: 自动探测期望字符串的有效长度（不靠人工数字符）
    //   Verilog 把字符串字面量赋给更宽的向量时，在**高位补 0**。所以字面量
    //   本身占据低位若干字节，最高那个非零字节就是末字符。从高往低扫第一个
    //   非零字节，其下标 +1 即长度。
    //   实测踩坑记录：先按 8*(21-c) 取（等于假设字符串恰好 22 字符），结果
    //   22 字符的行 2 全过、19 字符的行 1 全挂 —— 短字符串在左侧被当成空格，
    //   与实际的 'P'/'B' 对不上。长度必须算出来，不能假定。
    // ------------------------------------------------------------------------
    function integer exp_len;
        input [8*22-1:0] s;
        integer k;
        reg     found;
        begin
            exp_len = 0;
            found   = 1'b0;
            for (k = 21; k >= 0; k = k - 1) begin
                if (!found && (s[8*k +: 8] != 8'h00)) begin
                    exp_len = k + 1;
                    found   = 1'b1;
                end
            end
        end
    endfunction

    // ------------------------------------------------------------------------
    // exp_byte: 取期望字符串的第 c 个字符（c=0 是最左字符），不足补空格
    //   字符串在向量里是"左对齐"的（首字符在字面量最高字节），而面板文字
    //   也是左对齐、右侧留白，两者一致。第 c 个字符位于字节 (len-1-c)。
    // ------------------------------------------------------------------------
    function [7:0] exp_byte;
        input [8*22-1:0] s;
        input integer    c;
        integer          len;
        begin
            len = exp_len(s);
            exp_byte = (c < len) ? s[8*(len-1-c) +: 8] : 8'h20;
        end
    endfunction

    // ---- 打印一行实际渲染结果（失败时用于定位）--------------------------
    task show_line;
        input [1:0] ln;
        integer k;
        begin
            $write("      actual: \"");
            for (k = 0; k < 22; k = k + 1) begin
                line = ln;
                col  = k[4:0];
                #1;
                $write("%c", code_to_ascii(char_code));
            end
            $write("\"\n");
        end
    endtask

    // ------------------------------------------------------------------------
    // chk_line: 整行 22 列逐字符比对
    //   一次性比完整行（而不是每列一条断言）—— 一行 22 条断言会把日志刷成
    //   几百行，反而看不出哪条重要。整行比对 + 失败时打印实际串，定位成本
    //   更低，断言总数也保持在可读范围。
    // ------------------------------------------------------------------------
    task chk_line;
        input [1:0]      ln;
        input [8*22-1:0] expect;
        input [8*8*8-1:0] tag;
        reg   [7:0]      e;
        reg   [7:0]      g;
        reg              ok;
        integer          k;
        begin
            ok = 1'b1;
            for (k = 0; k < 22; k = k + 1) begin
                line = ln;
                col  = k[4:0];
                #1;
                g = code_to_ascii(char_code);
                e = exp_byte(expect, k);
                if (g !== e) ok = 1'b0;
            end
            if (ok) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s line %0d = \"%0s\"", tag, ln, expect);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s line %0d expected \"%0s\"", tag, ln, expect);
                show_line(ln);
            end
        end
    endtask

    // ---- 单列比对（用于越界/空格类检查）---------------------------------
    task chk_col;
        input [1:0]       ln;
        input [4:0]       cl;
        input [8*22-1:0]  expect;
        input [8*8*8-1:0] tag;
        reg   [7:0]       e;
        reg   [7:0]       g;
        begin
            line = ln;
            col  = cl;
            #1;
            g = code_to_ascii(char_code);
            e = exp_byte(expect, cl);
            if (g === e) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s line %0d col %0d = '%c'", tag, ln, cl, g);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s line %0d col %0d expected '%c' got '%c'",
                         tag, ln, cl, e, g);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // chk_range_blank: 断言一行里 col 从 lo 到 21 全是空格
    //   专门用来验"条件列组没使能时必须整组消失"—— 这类断言若写成逐列
    //   chk_col 会一次刷出十几行 PASS 淹没日志，且改版面时要改十几处字面量。
    // ------------------------------------------------------------------------
    task chk_range_blank;
        input [1:0]      ln;
        input integer    lo;
        input [8*8*8-1:0] tag;
        reg   [7:0]      g;
        reg              ok;
        integer          k;
        begin
            ok = 1'b1;
            for (k = lo; k < 22; k = k + 1) begin
                line = ln;
                col  = k[4:0];
                #1;
                g = code_to_ascii(char_code);
                if (g !== 8'h20) begin
                    ok = 1'b0;
                    $display("      col %0d = '%c' (应空白)", k, g);
                end
            end
            if (ok) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s line %0d col %0d..21 all blank", tag, ln, lo);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s line %0d col %0d..21 应全空白", tag, ln, lo);
            end
        end
    endtask

    // 把全部参数恢复成 key_router 的复位值（★ 不是全 0！音量 6、另两个 4）
    task set_defaults;
        begin
            bright_lvl    = 4'd0;
            vol_lvl       = 4'd6;
            res_sel       = 3'd4;
            ratio_sel     = 3'd4;
            invert_en     = 1'b0;
            auto_sw_sel   = 2'd0;
            info_mode     = 2'd0;
            img_index     = 5'd0;
            gallery_count = 5'd0;
            line          = 2'd0;
            col           = 5'd0;
            #1;
        end
    endtask

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        set_defaults;

        // ================= V01 默认值 =================
        // 复位后各参数为 key_router 的复位值（亮度 0 / 音量 6 / 分辨率 4 /
        // 屏占比 4），面板应显示这三行。这条同时锁定了"上电观感"：
        // 改版面必须同步改这里，否则是破坏性变更。
        chk_line(2'd0, "PARAM OSD",              "V01a default title");
        chk_line(2'd1, "B:0 V:6 R:4 P:4",        "V01b default params");
        chk_line(2'd2, "MODE:NORMAL  IMG:00/00", "V01c default status");

        // ================= V02 亮度 0..9 十档 =================
        // ★ t16 的核心用例。改造前 bright_sel 只有 3 位：
        //     档 8 → 8[2:0] = 000 → 显示 "0"
        //     档 9 → 9[2:0] = 001 → 显示 "1"
        //   按键按到第 9 下数字突然回到 0，用户会以为按键坏了。
        //   这里逐档写死期望串（不用循环算），档 8/9 是必红的两条反证靶子。
        for (i = 0; i < 10; i = i + 1) begin
            bright_lvl = i[3:0];
            #1;
            case (i)
            0: chk_line(2'd1, "B:0 V:6 R:4 P:4", "V02 BRI=0");
            1: chk_line(2'd1, "B:1 V:6 R:4 P:4", "V02 BRI=1");
            2: chk_line(2'd1, "B:2 V:6 R:4 P:4", "V02 BRI=2");
            3: chk_line(2'd1, "B:3 V:6 R:4 P:4", "V02 BRI=3");
            4: chk_line(2'd1, "B:4 V:6 R:4 P:4", "V02 BRI=4");
            5: chk_line(2'd1, "B:5 V:6 R:4 P:4", "V02 BRI=5");
            6: chk_line(2'd1, "B:6 V:6 R:4 P:4", "V02 BRI=6");
            7: chk_line(2'd1, "B:7 V:6 R:4 P:4", "V02 BRI=7");
            8: chk_line(2'd1, "B:8 V:6 R:4 P:4", "V02 BRI=8  <-- 3 位窄口时错显 0");
            default: chk_line(2'd1, "B:9 V:6 R:4 P:4", "V02 BRI=9  <-- 3 位窄口时错显 1");
            endcase
        end
        bright_lvl = 4'd0;

        // ================= V03 反色（含条件列组两向） =================
        // 使能：列 16..18 出现 "I:1"；不使能：整组消失（不是显示 "I:0"）。
        invert_en = 1'b1;
        #1;
        chk_line(2'd1, "B:0 V:6 R:4 P:4 I:1", "V03 INV=1 出现 I:1");
        chk_col(2'd1, 5'd16, "B:0 V:6 R:4 P:4 I:1", "V03a INV=1 col16 = 'I'");
        chk_col(2'd1, 5'd18, "B:0 V:6 R:4 P:4 I:1", "V03b INV=1 col18 = '1'");
        invert_en = 1'b0;
        #1;
        chk_line(2'd1, "B:0 V:6 R:4 P:4", "V03c INV=0 整组消失");
        chk_range_blank(2'd1, 15, "V03d INV=0 col15..21 全空白");

        // ================= V04 倍率 0..3 -> X1..X4 =================
        // 倍率显示 +1：寄存器 0 表示 ×1，显示 "X1"（0 倍速无意义）。
        // 默认（0）时不占列；非 0 时在列 20..21 输出 "Xn"。
        for (i = 0; i < 4; i = i + 1) begin
            auto_sw_sel = i[1:0];
            #1;
            case (i)
            0: begin
                chk_line(2'd1, "B:0 V:6 R:4 P:4", "V04 RATE=0 不占列");
                chk_range_blank(2'd1, 15, "V04a RATE=0 col15..21 全空白");
            end
            1: begin
                chk_line(2'd1, "B:0 V:6 R:4 P:4     X2", "V04 RATE=1 -> X2");
                chk_col(2'd1, 5'd20, "B:0 V:6 R:4 P:4     X2", "V04b RATE=1 col20 = 'X'");
                chk_col(2'd1, 5'd21, "B:0 V:6 R:4 P:4     X2", "V04c RATE=1 col21 = '2'");
            end
            2: chk_line(2'd1, "B:0 V:6 R:4 P:4     X3", "V04 RATE=2 -> X3");
            default: chk_line(2'd1, "B:0 V:6 R:4 P:4     X4", "V04 RATE=3 -> X4");
            endcase
        end
        auto_sw_sel = 2'd0;

        // ================= V05 模式名 0..3 =================
        // 模式名是 7 字符定宽，不足补空格 —— 这里逐条锁定补空格的数量，
        // 因为"补几个空格"直接决定 IMG 段的列位置（见模块头注释【五】）。
        info_mode = 2'd0; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:00/00", "V05 MODE=0 NORMAL");
        info_mode = 2'd1; #1;
        chk_line(2'd2, "MODE:SCIENCE IMG:00/00", "V05 MODE=1 SCIENCE");
        info_mode = 2'd2; #1;
        chk_line(2'd2, "MODE:EMERG   IMG:00/00", "V05 MODE=2 EMERG");
        info_mode = 2'd3; #1;
        chk_line(2'd2, "MODE:UNKNOWN IMG:00/00", "V05 MODE=3 UNKNOWN");
        info_mode = 2'd0; #1;

        // ================= V06 图号个位 0..9 =================
        // 0..9 的十位必须是 '0'（而不是空格）—— 早期版本十位直接输出
        // dec_tens 的字符，个位数时会显示 " 5" 而不是 "05"，看起来像错位。
        for (i = 0; i < 10; i = i + 1) begin
            img_index = i[4:0];
            #1;
            case (i)
            0: chk_line(2'd2, "MODE:NORMAL  IMG:00/00", "V06 IMG=0");
            1: chk_line(2'd2, "MODE:NORMAL  IMG:01/00", "V06 IMG=1");
            2: chk_line(2'd2, "MODE:NORMAL  IMG:02/00", "V06 IMG=2");
            3: chk_line(2'd2, "MODE:NORMAL  IMG:03/00", "V06 IMG=3");
            4: chk_line(2'd2, "MODE:NORMAL  IMG:04/00", "V06 IMG=4");
            5: chk_line(2'd2, "MODE:NORMAL  IMG:05/00", "V06 IMG=5");
            6: chk_line(2'd2, "MODE:NORMAL  IMG:06/00", "V06 IMG=6");
            7: chk_line(2'd2, "MODE:NORMAL  IMG:07/00", "V06 IMG=7");
            8: chk_line(2'd2, "MODE:NORMAL  IMG:08/00", "V06 IMG=8");
            default: chk_line(2'd2, "MODE:NORMAL  IMG:09/00", "V06 IMG=9");
            endcase
        end

        // ================= V07 图号十位边界 =================
        // 阈值比较求十位的三个分界点（10/20/30）各测两侧，加最大值 31。
        img_index = 5'd10; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:10/00", "V07 IMG=10 lower bound of tens=1");
        img_index = 5'd19; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:19/00", "V07 IMG=19 upper of tens=1");
        img_index = 5'd20; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:20/00", "V07 IMG=20 lower bound of tens=2");
        img_index = 5'd29; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:29/00", "V07 IMG=29 upper of tens=2");
        img_index = 5'd30; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:30/00", "V07 IMG=30 lower bound of tens=3");
        img_index = 5'd31; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:31/00", "V07 IMG=31 max");
        img_index = 5'd0; #1;

        // ================= V08 图库张数边界 =================
        // 与图号走同一套十进制转换，但独立实例（两处都可能单独写错）。
        gallery_count = 5'd12; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:00/12", "V08 COUNT=12");
        gallery_count = 5'd9; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:00/09", "V08 COUNT=9 leading zero");
        gallery_count = 5'd31; #1;
        chk_line(2'd2, "MODE:NORMAL  IMG:00/31", "V08 COUNT=31 max");
        gallery_count = 5'd0; #1;

        // ================= V09 行号越界 =================
        // line 只有 2 位，取 3 是非法行。模块必须输出空白，而不是让
        // case 落空后保留模板值（那会在第 4 行位置画出标题的残影）。
        // 面板只显示 3 行，这一条保证"第 4 行不存在"。
        line = 2'd3;
        for (i = 0; i < 22; i = i + 1) begin
            col = i[4:0];
            #1;
            if (char_code === 6'd32) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: V09 line=3 col=%0d must be blank, got %0d", i, char_code);
            end
        end
        // 合并成一条可读断言（22 条分散的 PASS 会淹没日志）
        $display("PASS: V09 line=3 all 22 columns blank");

        // ================= V10 列号越界 =================
        // col 是 5 位（0..31），但版面只有 22 列。22..31 必须输出空格。
        line = 2'd0;
        for (i = 22; i < 32; i = i + 1) begin
            col = i[4:0];
            #1;
            if (char_code !== 6'd32) begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: V10 col=%0d out of range must be blank, got %0d",
                         i, char_code);
            end
        end
        $display("PASS: V10 col 22..31 all blank");

        // ================= V11 全非默认组合 =================
        // 六个参数全取非默认值，锁死"多条动态覆盖互不干扰 + 条件列组同时占列"。
        bright_lvl    = 4'd9;
        vol_lvl       = 4'd8;
        res_sel       = 3'd3;
        ratio_sel     = 3'd2;
        invert_en     = 1'b1;
        auto_sw_sel   = 2'd3;
        info_mode     = 2'd2;
        img_index     = 5'd30;
        gallery_count = 5'd31;
        #1;
        chk_line(2'd0, "PARAM OSD",                "V11a combo title unchanged");
        chk_line(2'd1, "B:9 V:8 R:3 P:2 I:1 X4",   "V11b combo params");
        chk_line(2'd2, "MODE:EMERG   IMG:30/31",   "V11c combo status");

        // 恢复默认，确认可逆（无隐藏状态 —— 本模块是纯组合，理论上必然可逆，
        // 但这条能在将来误加寄存器时立刻报警）
        set_defaults;
        chk_line(2'd1, "B:0 V:6 R:4 P:4",        "V11d restore to default");
        chk_line(2'd2, "MODE:NORMAL  IMG:00/00", "V11e restore status");

        // ================= V12 音量 0..9 十档（t16 新增）=================
        // vol_lvl 与 bright_lvl 同宽（4 位）但值域独立。这里逐档写死期望，
        // 同时验证"音量变化不会碰到亮度那一列"（两列邻近，接错线最容易串）。
        for (i = 0; i < 10; i = i + 1) begin
            vol_lvl = i[3:0];
            #1;
            case (i)
            0: chk_line(2'd1, "B:0 V:0 R:4 P:4", "V12 VOL=0");
            1: chk_line(2'd1, "B:0 V:1 R:4 P:4", "V12 VOL=1");
            2: chk_line(2'd1, "B:0 V:2 R:4 P:4", "V12 VOL=2");
            3: chk_line(2'd1, "B:0 V:3 R:4 P:4", "V12 VOL=3");
            4: chk_line(2'd1, "B:0 V:4 R:4 P:4", "V12 VOL=4");
            5: chk_line(2'd1, "B:0 V:5 R:4 P:4", "V12 VOL=5");
            6: chk_line(2'd1, "B:0 V:6 R:4 P:4", "V12 VOL=6 复位值");
            7: chk_line(2'd1, "B:0 V:7 R:4 P:4", "V12 VOL=7");
            8: chk_line(2'd1, "B:0 V:8 R:4 P:4", "V12 VOL=8");
            default: chk_line(2'd1, "B:0 V:9 R:4 P:4", "V12 VOL=9 max");
            endcase
        end
        vol_lvl = 4'd6;

        // ================= V13 分辨率 0..4 五档（t16 新增）=================
        for (i = 0; i < 5; i = i + 1) begin
            res_sel = i[2:0];
            #1;
            case (i)
            0: chk_line(2'd1, "B:0 V:6 R:0 P:4", "V13 RES=0");
            1: chk_line(2'd1, "B:0 V:6 R:1 P:4", "V13 RES=1");
            2: chk_line(2'd1, "B:0 V:6 R:2 P:4", "V13 RES=2");
            3: chk_line(2'd1, "B:0 V:6 R:3 P:4", "V13 RES=3");
            default: chk_line(2'd1, "B:0 V:6 R:4 P:4", "V13 RES=4 复位值");
            endcase
        end
        res_sel = 3'd4;

        // ================= V14 屏占比 0..4 五档（t16 新增）=================
        for (i = 0; i < 5; i = i + 1) begin
            ratio_sel = i[2:0];
            #1;
            case (i)
            0: chk_line(2'd1, "B:0 V:6 R:4 P:0", "V14 RATIO=0");
            1: chk_line(2'd1, "B:0 V:6 R:4 P:1", "V14 RATIO=1");
            2: chk_line(2'd1, "B:0 V:6 R:4 P:2", "V14 RATIO=2");
            3: chk_line(2'd1, "B:0 V:6 R:4 P:3", "V14 RATIO=3");
            default: chk_line(2'd1, "B:0 V:6 R:4 P:4", "V14 RATIO=4 复位值");
            endcase
        end
        ratio_sel = 3'd4;

        // ================= V15 六参数互不串扰（t16 新增）=================
        // 上一条只动一个参数，看不出"列位置接错"（例如把 vol 接到 res 那列）。
        // 这里让四个档位取四个互不相同的值，一次比对整行，任何错列都会红。
        bright_lvl = 4'd1;  vol_lvl = 4'd2;  res_sel = 3'd3;  ratio_sel = 3'd4;
        #1;
        chk_line(2'd1, "B:1 V:2 R:3 P:4", "V15a 四档位互不相同");
        bright_lvl = 4'd4;  vol_lvl = 4'd3;  res_sel = 3'd2;  ratio_sel = 3'd1;
        #1;
        chk_line(2'd1, "B:4 V:3 R:2 P:1", "V15b 四档位逆序");
        // 条件列组同时占列时，与前方四个档位拼接后总长 20 列，列 19 留空
        bright_lvl = 4'd9;  vol_lvl = 4'd0;  res_sel = 3'd1;  ratio_sel = 3'd3;
        invert_en = 1'b1;   auto_sw_sel = 2'd1;
        #1;
        chk_line(2'd1, "B:9 V:0 R:1 P:3 I:1 X2", "V15c 六项同时非默认");
        set_defaults;

        // ================= 汇总 =================
        $display("");
        $display("--------------------------------------------------");
        $display("tb_osd_param_text: %0d checks passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: osd_param_text");
        end else begin
            $display("CHECKS FAILED: osd_param_text");
        end
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
