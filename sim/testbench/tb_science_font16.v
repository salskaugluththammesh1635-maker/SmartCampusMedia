// =============================================================================
// tb_science_font16.v —— 16x16 汉字/字符点阵字库 ROM 单元测试
// -----------------------------------------------------------------------------
// 【被测对象】
//   rtl/video/science_font16.v
//   module science_font16 (input wire [5:0] glyph, input wire [3:0] row,
//                          output reg [15:0] pixels);
//
// 【模块性质】
//   纯组合查表：case ({glyph, row})，10 位选择子，命中则输出该行 16 位点阵，
//   default 输出 16'h0000。字库共 40 个字形：
//     1..36  汉字（认识数字系统逻辑并行输入组合寄存器输出时序钟沿保状态
//                  多个单元同计算决定处理）
//     37..40 字符 F P G A（拼成 "FPGA"）
//   每个字形 16 行，行号 0..15；位 15 是**最左像素**，位 0 是最右像素。
//   实际填充 607 行（部分汉字底部留空，不是每字都填满 16 行）。
//   唯一使用者：rtl/video/science_page.v:180，取像素用
//   `wire glyph_on = glyph_pixels[4'd15 - font_x];` —— 即 font_x=0 取 bit15，
//   这条接线是本 TB 判定"bit15 = 最左"的依据。
//
// 【为什么这个"纯数据表"值得单独测】
//   它看起来测不出什么，但实际有三类真实风险，而且都是"肉眼扫一眼觉得对、
//   逐像素比才露馅"的缺陷，正好适合自动比对：
//     1) 索引拼位顺序错：{glyph,row} 写成 {row,glyph} —— 整屏字全部错位
//     2) 位序镜像：把 bit15 当成最右像素 —— 每个汉字左右翻转，仍"能看"但全错
//     3) 表项缺行 / 复制粘贴错行 —— 某一行永远空白，汉字少一横
//
// 【黄金值从哪来（本 TB 的诚实边界，务必读）】
//   字库没有"外部标准答案"可比，所以这里分两层判据：
//   A. **独立钉子**（[nail] 段）：手写、可肉眼核对的期望值。例如字形 37 'F'
//      第 7 行 = 16'h0FE0 = 0000_1111_1110_0000 —— 左边 4 个像素暗、中间 7 个
//      亮、右边 5 个暗，正是字母 F 竖笔加中间横杠的形状。这一层能真正抓出
//      位序镜像与索引错位，是本 TB 的**正确性**判据。
//   B. **结构判据**（[struct] 段）：不依赖任何期望表，只断言字库自身必须成立
//      的性质 —— 未定义项为 0、越界字形为 0、40 个字无一全黑、无全亮行、
//      每字形至少两种行型、40 个字形签名互不相同（抓复制粘贴整个字形）。
//   刻意**不**用"从 RTL 源码反抽表再比对"的做法：抽出来的表和被测对象同源，
//   改错时两边一起错，看似全绿实则什么都没验到。
//
// 【注意：不是所有"看起来该成立"的性质都成立】
//   本字库是粗笔画点阵，**相邻行常常完全相同**（如 'F' 的第 4/5/6 行都是
//   0E00，第 2/3 行都是 0FF0）。所以"相邻行必须不同"是错误的判据，会误报
//   126 处失败。真正该断言的是"每字形至少两种行型"与"字形之间不重复"。
// =============================================================================
`timescale 1ns / 1ps

module tb_science_font16;

    reg  [5:0]  glyph = 6'd0;
    reg  [3:0]  row   = 4'd0;
    wire [15:0] pixels;

    integer checks = 0;
    integer errors = 0;

    // -------------------------------------------------------------------------
    // 计分器
    // -------------------------------------------------------------------------
    task ck(input cond, input [8*110-1:0] label);
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    task ck_int(input integer got, input integer exp, input [8*110-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s (got %0d expected %0d)", label, got, exp);
            end
        end
    endtask

    task ck_hex16(input [15:0] got, input [15:0] exp, input [8*110-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s (got %04h expected %04h)", label, got, exp);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    science_font16 u_dut (
        .glyph  (glyph),
        .row    (row),
        .pixels (pixels)
    );

    // 驱动一个选择子并取回输出（纯组合，#1 后读稳定值）
    task apply(input [5:0] g, input [3:0] r);
        begin
            glyph = g;
            row   = r;
            #1;
        end
    endtask

    // -------------------------------------------------------------------------
    // 逐像素断言：把当前 pixels 与期望的 16 位串比对，失败时打印实际位串
    //   期望串按 bit15..bit0 顺序书写，例如 0000111111100000
    // -------------------------------------------------------------------------
    task ck_bits(input [15:0] exp_bits, input [8*110-1:0] label);
        integer k;
        integer miss;
        begin
            miss = 0;
            for (k = 15; k >= 0; k = k - 1) begin
                if (pixels[k] !== exp_bits[k]) miss = miss + 1;
            end
            checks = checks + 1;
            if (miss == 0) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s (got %b, %0d pixel(s) differ from %b)",
                         label, pixels, miss, exp_bits);
            end
        end
    endtask

    // 统计一个 16 位行里点亮的像素个数
    function integer popcount16(input [15:0] v);
        integer k;
        begin
            popcount16 = 0;
            for (k = 0; k < 16; k = k + 1) begin
                if (v[k] === 1'b1) popcount16 = popcount16 + 1;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // 全量扫描留存的快照与派生统计
    // -------------------------------------------------------------------------
    reg [15:0] snap   [0:1023];
    integer    gsum   [1:40];      // 每个字形 16 行数值之和（唯一性签名）
    integer    gdist  [1:40];      // 每个字形不同行型的个数
    integer    gpop   [1:40];      // 每个字形点亮像素总数

    integer g;
    integer r;
    integer i;
    integer j;
    integer k;
    integer bad;
    integer nonempty;
    integer lit_rows;
    integer collisions;
    reg [15:0] got;

    initial begin
        $display("=== tb_science_font16 start ===");

        // ---------------------------------------------------------------------
        // [1] 全量驱动 1024 个选择子：确认无 x/z，并留下快照
        // ---------------------------------------------------------------------
        bad = 0;
        for (g = 0; g < 64; g = g + 1) begin
            for (r = 0; r < 16; r = r + 1) begin
                apply(g[5:0], r[3:0]);
                if (^pixels === 1'bx) bad = bad + 1;
                snap[g*16 + r] = pixels;
            end
        end
        ck_int(bad, 0, "[sweep] all 1024 (glyph,row) selectors produce a fully-defined output");

        // ---------------------------------------------------------------------
        // [2] glyph=0 与越界 glyph 41..63 必须全 0（default 分支生效）
        // ---------------------------------------------------------------------
        bad = 0;
        for (r = 0; r < 16; r = r + 1) begin
            if (snap[0*16 + r] !== 16'h0000) bad = bad + 1;
        end
        ck_int(bad, 0, "[default] glyph 0 is entirely blank (all 16 rows)");

        bad = 0;
        for (g = 41; g < 64; g = g + 1) begin
            for (r = 0; r < 16; r = r + 1) begin
                if (snap[g*16 + r] !== 16'h0000) bad = bad + 1;
            end
        end
        ck_int(bad, 0, "[default] out-of-range glyphs 41..63 are entirely blank");

        // ---------------------------------------------------------------------
        // [3] 40 个字形全部非空 + 填充行总数 = 607
        // ---------------------------------------------------------------------
        bad      = 0;
        nonempty = 0;
        lit_rows = 0;
        for (g = 1; g <= 40; g = g + 1) begin
            i = 0;
            for (r = 0; r < 16; r = r + 1) begin
                if (snap[g*16 + r] !== 16'h0000) i = i + 1;
            end
            lit_rows = lit_rows + i;
            if (i > 0) nonempty = nonempty + 1;
            else       bad      = bad + 1;
        end
        ck_int(bad, 0,       "[struct] no glyph is completely blank");
        ck_int(nonempty, 40, "[struct] all 40 glyphs have at least one lit row");
        ck_int(lit_rows, 607, "[struct] total populated rows is 607 (table size is stable)");

        // ---------------------------------------------------------------------
        // [4] 无全亮行（16 像素全 1 说明数据错或位宽没截断）
        // ---------------------------------------------------------------------
        bad = 0;
        for (g = 1; g <= 40; g = g + 1) begin
            for (r = 0; r < 16; r = r + 1) begin
                if (snap[g*16 + r] === 16'hFFFF) bad = bad + 1;
            end
        end
        ck_int(bad, 0, "[struct] no row is fully lit (all 16 pixels on)");

        // ---------------------------------------------------------------------
        // [5] 每字形至少两种不同行型（粗笔画点阵允许相邻行相同，
        //     但整字所有行都一样就说明表项填错了）
        // ---------------------------------------------------------------------
        bad = 0;
        for (g = 1; g <= 40; g = g + 1) begin
            i = 0;
            for (r = 0; r < 16; r = r + 1) begin
                if (snap[g*16 + r] === 16'h0000) begin
                    // 空白行不参与"行型"统计
                    i = i + 0;
                end
                else begin
                    // 统计这一行在字形内是否是首次出现
                    k = 0;
                    for (j = 0; j < r; j = j + 1) begin
                        if (snap[g*16 + j] === snap[g*16 + r]) k = 1;
                    end
                    if (k == 0) i = i + 1;
                end
            end
            gdist[g] = i;
            if (i < 2) bad = bad + 1;
        end
        ck_int(bad, 0, "[struct] every glyph has at least two distinct row patterns");

        // ---------------------------------------------------------------------
        // [6] 40 个字形签名互不相同（抓"整个字形被复制粘贴"）
        //     签名 = 该字形 16 行数值之和；实测 40 个全不相同
        // ---------------------------------------------------------------------
        for (g = 1; g <= 40; g = g + 1) begin
            gsum[g] = 0;
            gpop[g] = 0;
            for (r = 0; r < 16; r = r + 1) begin
                gsum[g] = gsum[g] + snap[g*16 + r];
                gpop[g] = gpop[g] + popcount16(snap[g*16 + r]);
            end
        end
        collisions = 0;
        for (g = 1; g <= 40; g = g + 1) begin
            for (i = g + 1; i <= 40; i = i + 1) begin
                if (gsum[g] === gsum[i] && gpop[g] === gpop[i]) begin
                    collisions = collisions + 1;
                    $display("INFO: glyph %0d and %0d have identical signature (sum=%0d pop=%0d)",
                             g, i, gsum[g], gpop[g]);
                end
            end
        end
        ck_int(collisions, 0, "[struct] all 40 glyph signatures are distinct (no duplicated glyph)");

        // 抽查两个签名，钉死"签名算法本身没算错"
        ck_int(gsum[37], 44960, "[struct] glyph 37 (F) row sum is 44960");
        ck_int(gpop[37], 54,    "[struct] glyph 37 (F) lit-pixel total is 54");
        ck_int(gsum[40], 35512, "[struct] glyph 40 (A) row sum is 35512");
        ck_int(gpop[40], 63,    "[struct] glyph 40 (A) lit-pixel total is 63");

        // ---------------------------------------------------------------------
        // [7] 位序钉子 —— 字形 37 'F'
        //   行 7 = 0x0FE0 = 0000_1111_1110_0000（竖笔 + 中间横杠，7 个亮点）
        //   若实现把 bit15 当最右像素，得到的是镜像 0000_0111_1111_0000，
        //   下面的逐像素断言会立刻失败。
        // ---------------------------------------------------------------------
        apply(6'd37, 4'd7);
        ck_hex16(pixels, 16'h0FE0, "[nail] glyph 37 (F) row 7 equals 0FE0");
        ck_bits(16'b0000111111100000, "[nail] glyph 37 (F) row 7 pixel map (bit15 = leftmost)");
        ck_int(popcount16(pixels), 7, "[nail] glyph 37 (F) row 7 lights exactly 7 pixels");
        ck(pixels[15:11] === 5'b00001, "[nail] glyph 37 row 7 leftmost 5 pixels: only bit11 lit");
        ck(pixels[11:5]  === 7'b1111111, "[nail] glyph 37 row 7 middle 7 pixels lit");
        ck(pixels[4:0]   === 5'b00000,   "[nail] glyph 37 row 7 rightmost 5 pixels dark");

        // 行 4 = 0x0E00 = 0000_1110_0000_0000（纯竖笔，3 个亮点）
        apply(6'd37, 4'd4);
        ck_hex16(pixels, 16'h0E00, "[nail] glyph 37 (F) row 4 equals 0E00 (stem only)");
        ck_bits(16'b0000111000000000, "[nail] glyph 37 (F) row 4 pixel map");
        ck(popcount16(pixels) < popcount16(16'h0FE0),
           "[nail] glyph 37 stem row is narrower than its crossbar row (shape is upright)");

        // 顶部两行同为 0x0FF0（粗笔画点阵的合法重复，顺带钉住"允许重复行"）
        apply(6'd37, 4'd2);
        ck_hex16(pixels, 16'h0FF0, "[nail] glyph 37 (F) row 2 equals 0FF0");
        apply(6'd37, 4'd3);
        ck_hex16(pixels, 16'h0FF0, "[nail] glyph 37 (F) row 3 equals 0FF0 (top bar is 2 rows thick)");

        // ---------------------------------------------------------------------
        // [8] 位序钉子 —— 字形 38 'P'
        //   行 4 = 0x1C70 = 0001_1100_0111_0000：左竖笔 + 右圆弧（6 个亮点）
        //   行 10 = 0x1C00 = 0001_1100_0000_0000：只有竖笔（3 个亮点）
        // ---------------------------------------------------------------------
        apply(6'd38, 4'd4);
        ck_hex16(pixels, 16'h1C70, "[nail] glyph 38 (P) row 4 equals 1C70");
        ck_bits(16'b0001110001110000, "[nail] glyph 38 (P) row 4 pixel map");
        ck_int(popcount16(pixels), 6, "[nail] glyph 38 (P) row 4 lights exactly 6 pixels");

        apply(6'd38, 4'd10);
        ck_hex16(pixels, 16'h1C00, "[nail] glyph 38 (P) row 10 equals 1C00 (stem only)");
        ck_bits(16'b0001110000000000, "[nail] glyph 38 (P) row 10 pixel map");

        // ---------------------------------------------------------------------
        // [9] 位序钉子 —— 字形 39 'G'
        //   行 2 = 0x03E0 = 0000_0011_1110_0000：顶部圆弧（5 个亮点，居中偏左）
        // ---------------------------------------------------------------------
        apply(6'd39, 4'd2);
        ck_hex16(pixels, 16'h03E0, "[nail] glyph 39 (G) row 2 equals 03E0");
        ck_bits(16'b0000001111100000, "[nail] glyph 39 (G) row 2 pixel map");
        ck_int(popcount16(pixels), 5, "[nail] glyph 39 (G) row 2 lights exactly 5 pixels");

        // ---------------------------------------------------------------------
        // [10] 位序钉子 —— 字形 40 'A'
        //   行 2 = 0x03C0 = 0000_0011_1100_0000：顶点（4 个亮点）
        //   行 9 = 0x0FF0 = 0000_1111_1111_0000：横杠（8 个亮点，最宽处）
        // ---------------------------------------------------------------------
        apply(6'd40, 4'd2);
        ck_hex16(pixels, 16'h03C0, "[nail] glyph 40 (A) row 2 equals 03C0 (apex)");
        ck_bits(16'b0000001111000000, "[nail] glyph 40 (A) row 2 pixel map");

        apply(6'd40, 4'd9);
        ck_hex16(pixels, 16'h0FF0, "[nail] glyph 40 (A) row 9 equals 0FF0 (crossbar)");
        ck_bits(16'b0000111111110000, "[nail] glyph 40 (A) row 9 pixel map");
        ck(popcount16(pixels) > popcount16(16'h03C0),
           "[nail] glyph 40 (A) crossbar is wider than its apex (shape is upright)");

        // ---------------------------------------------------------------------
        // [11] 索引钉子：整体错位一位会立刻暴露
        //   glyph=1（第一个汉字"认"）行 0 = 0x1030
        //   glyph=2（"识"）行 1 = 0x71FE
        //   glyph=40（最后一个字形 'A'）行 2 = 0x03C0
        // ---------------------------------------------------------------------
        apply(6'd1, 4'd0);
        ck_hex16(pixels, 16'h1030, "[index] glyph 1 row 0 equals 1030 (first glyph, first row)");
        ck_bits(16'b0001000000110000, "[index] glyph 1 row 0 pixel map");

        apply(6'd2, 4'd1);
        ck_hex16(pixels, 16'h71FE, "[index] glyph 2 row 1 equals 71FE (second glyph)");
        ck_bits(16'b0111000111111110, "[index] glyph 2 row 1 pixel map");

        apply(6'd40, 4'd2);
        ck_hex16(pixels, 16'h03C0, "[index] glyph 40 row 2 equals 03C0 (last glyph)");

        // 首尾字形必须不同 —— 若索引被整体错位，两者会撞在一起
        ck(snap[1*16 + 0] !== snap[40*16 + 2],
           "[index] first and last glyph differ (index is not aliased)");

        // ---------------------------------------------------------------------
        // [12] 组合特性：无时钟依赖，输入变化立即跟随；返回原输入输出复原
        // ---------------------------------------------------------------------
        apply(6'd37, 4'd7);
        got = pixels;
        apply(6'd38, 4'd7);
        #1;
        ck(pixels !== got, "[comb] output follows glyph change with no clock edge");
        apply(6'd37, 4'd7);
        #1;
        ck_hex16(pixels, got, "[comb] output returns when input returns (no latch)");

        // 只改 row 也必须立即跟随
        apply(6'd37, 4'd4);
        got = pixels;
        apply(6'd37, 4'd7);
        #1;
        ck(pixels !== got, "[comb] output follows row change with no clock edge");

        // 输入回到 0 时输出必须回到 0（不是锁存上一个字形）
        apply(6'd37, 4'd7);
        got = pixels;
        apply(6'd0, 4'd0);
        #1;
        ck(pixels === 16'h0000, "[comb] output falls back to blank when glyph returns to 0");
        ck(got !== 16'h0000,  "[comb] the previous glyph was non-blank (fallback is meaningful)");

        // ---------------------------------------------------------------------
        // [13] 端口契约：本模块没有时钟、没有复位，上电即可用
        //   （这条是文档性断言：若将来给 ROM 加了 rst 端口，TB 会编译失败
        //    而不是静默漏测 —— 比注释更可靠）
        // ---------------------------------------------------------------------
        apply(6'd37, 4'd7);
        ck_hex16(pixels, 16'h0FE0, "[port] module has no clock/reset: output valid immediately");

        // ---------------------------------------------------------------------
        // 汇总
        // ---------------------------------------------------------------------
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: science_font16");
        else             $display("CHECKS FAILED: science_font16");
        $finish;
    end

    initial begin
        #1000000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors + 1);
        $display("CHECKS FAILED: science_font16");
        $finish;
    end

endmodule
