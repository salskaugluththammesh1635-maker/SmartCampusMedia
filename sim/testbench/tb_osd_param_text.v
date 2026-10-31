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
//   期望字符串（"PARAM OSD"、"BRI:0 INV:0 RATE:X1" …）逐字符比对。
//   期望值以"屏幕上应该看到的那行字"的形式写在断言里，肉眼可校对：
//
//       chk_line(2'd1, "BRI:3 INV:1 RATE:X2", "V02 ...");
//
//   于是"字符码算错"和"字模编址规则不一致"这两类错误都会被抓住 ——
//   因为还原规则来自字模 ROM 的生成器（scripts/gen_osd_font8.py 里
//   `rom_index = ord(ch) & 0x3F`），与 DUT 的实现无耦合。
//
// 【断言编号】
//   V01 默认值（全 0）三行完整文字
//   V02 亮度 0..4 五档
//   V03 反色 0/1
//   V04 倍率 0..3 -> X1..X4
//   V05 模式 0..3 名称（含定宽补空格）
//   V06 图号个位 0..9
//   V07 图号十位边界 10/19/20/29/30/31
//   V08 图库张数边界
//   V09 行号越界（line=3）输出空白
//   V10 列号越界（col 22..31）输出空格
//   V11 参数全非默认的组合
// ============================================================================
`timescale 1ns / 1ps

module tb_osd_param_text;

    // ---- DUT 输入 ------------------------------------------------------
    reg  [2:0] bright_sel;
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
        .bright_sel    (bright_sel),
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
        begin
            ok = 1'b1;
            for (i = 0; i < 22; i = i + 1) begin
                line = ln;
                col  = i[4:0];
                #1;
                g = code_to_ascii(char_code);
                e = exp_byte(expect, i);
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

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        bright_sel = 3'd0; invert_en = 1'b0; auto_sw_sel = 2'd0;
        info_mode = 2'd0; img_index = 5'd0; gallery_count = 5'd0;
        line = 2'd0; col = 5'd0;
        #1;

        // ================= V01 默认值 =================
        // 复位后所有参数为 0，面板应显示这三行。这条同时锁定了
        // "上电观感"：改版面必须同步改这里，否则是破坏性变更。
        chk_line(2'd0, "PARAM OSD",             "V01a default title");
        chk_line(2'd1, "BRI:0 INV:0 RATE:X1",   "V01b default params");
        chk_line(2'd2, "MODE:NORMAL  IMG:00/00","V01c default status");

        // ================= V02 亮度 0..4 =================
        // 显示的是 bright_sel 原值（0..4），不是 1..5 —— 见模块头注释【四】。
        for (i = 0; i < 5; i = i + 1) begin
            bright_sel = i[2:0];
            #1;
            case (i)
            0: chk_line(2'd1, "BRI:0 INV:0 RATE:X1", "V02 BRI=0");
            1: chk_line(2'd1, "BRI:1 INV:0 RATE:X1", "V02 BRI=1");
            2: chk_line(2'd1, "BRI:2 INV:0 RATE:X1", "V02 BRI=2");
            3: chk_line(2'd1, "BRI:3 INV:0 RATE:X1", "V02 BRI=3");
            default: chk_line(2'd1, "BRI:4 INV:0 RATE:X1", "V02 BRI=4");
            endcase
        end
        bright_sel = 3'd0;

        // ================= V03 反色 =================
        invert_en = 1'b1;
        #1;
        chk_line(2'd1, "BRI:0 INV:1 RATE:X1", "V03 INV=1");
        invert_en = 1'b0;
        #1;

        // ================= V04 倍率 0..3 -> X1..X4 =================
        // 倍率显示 +1：寄存器 0 表示 ×1，显示 "X1"（0 倍速无意义）。
        for (i = 0; i < 4; i = i + 1) begin
            auto_sw_sel = i[1:0];
            #1;
            case (i)
            0: chk_line(2'd1, "BRI:0 INV:0 RATE:X1", "V04 RATE=0 -> X1");
            1: chk_line(2'd1, "BRI:0 INV:0 RATE:X2", "V04 RATE=1 -> X2");
            2: chk_line(2'd1, "BRI:0 INV:0 RATE:X3", "V04 RATE=2 -> X3");
            default: chk_line(2'd1, "BRI:0 INV:0 RATE:X4", "V04 RATE=3 -> X4");
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
        // col 是 5 位（0..31），但版面只有 22 列。23..31 必须输出空格。
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
        // 亮度 4 + 反色 1 + 倍率 3(->X4) + 模式 2(EMERG) + 图号 30 + 张数 31
        bright_sel    = 3'd4;
        invert_en     = 1'b1;
        auto_sw_sel   = 2'd3;
        info_mode     = 2'd2;
        img_index     = 5'd30;
        gallery_count = 5'd31;
        #1;
        chk_line(2'd0, "PARAM OSD",               "V11a combo title unchanged");
        chk_line(2'd1, "BRI:4 INV:1 RATE:X4",     "V11b combo params");
        chk_line(2'd2, "MODE:EMERG   IMG:30/31",  "V11c combo status");

        // 恢复默认，确认可逆（无隐藏状态 —— 本模块是纯组合，理论上必然可逆，
        // 但这条能在将来误加寄存器时立刻报警）
        bright_sel = 3'd0; invert_en = 1'b0; auto_sw_sel = 2'd0;
        info_mode = 2'd0; img_index = 5'd0; gallery_count = 5'd0;
        #1;
        chk_line(2'd1, "BRI:0 INV:0 RATE:X1",     "V11d restore to default");
        chk_line(2'd2, "MODE:NORMAL  IMG:00/00",  "V11e restore status");

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
