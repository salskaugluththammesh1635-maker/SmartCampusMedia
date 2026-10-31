`timescale 1ns/1ps
// ============================================================================
// 文件名  : tb_osd_caption.v
// 所在位置: sim/testbench/tb_osd_caption.v
// 所属层次: 仿真 / B1 字幕渲染器验证
// 作者    : 智播校园项目组
// ============================================================================
// 【一】验证目标
//   osd_caption 把像素坐标换算成 (文本行, 字符列, 字形行, 位序)，再经两级
//   查表得出字幕笔画。**最容易出错的是坐标换算**——位切片写错一位，屏幕上
//   就是整行文字错位或整个字符偏一列，而综合和仿真都不会报错。
//
//   所以本 testbench 用"参考模型逐点比对"：
//     - 参考模型用 / 和 % 实现坐标换算（RTL 用位切片），写法刻意不同，
//       这样 RTL 的位切片一旦折返/错位，比对立刻失败；
//     - 两级查表复用 osd_strings / osd_font8x16 本身（不重复实现字模），
//       所以本 tb 验证的是"坐标 → 查表地址"的映射，而非重复验证字形。
//
//   字模 ROM 与字符串表的内容另有直接断言（C01、C02），避免"两边一起错"。
//
// 【二】用例
//   C01  字模 ROM 内容抽查（'A' 特征、空格、未收录字符）
//   C02  字符串表内容抽查（标题、序号占位符、标语首尾）
//   C03  标题带逐点比对（16 行 × 96 列 = 1536 点）
//   C04  序号带逐点比对（4 个序号 × 16 × 48 = 3072 点）
//   C05  状态带逐点比对（6 个状态行 × 16 × 72 = 6912 点）
//   C06  标语带逐点比对（2 个滚动位置 × 抽样）
//   C07  字幕带外必须无像素、无衬底
//   C08  caption_en=0 时全屏静默
//   C09  滚动计数器：8 帧 +1、512 回绕、复位清零
//   C10  衬底带覆盖范围与字幕带一致
//
// 【三】判定口径
//   逐点比对不逐点打印 PASS（会刷出上万行日志），只累计；最后汇总成一条
//   断言。任一点不符即记错，并在前 8 个错误上打印坐标与查表地址。
// ============================================================================
module tb_osd_caption;

    // ---- 时钟与复位 ----
    reg pixel_clk;
    reg rst_n;

    // ---- DUT 输入 ----
    reg         de;
    reg  [10:0] active_x;
    reg  [9:0]  active_y;
    reg         caption_en;
    reg  [3:0]  state_line;
    reg  [4:0]  index_val;

    // ---- DUT 输出 ----
    wire caption_pixel;
    wire caption_band;

    integer errors;
    integer perr;          // 逐点比对错误数（与 chk 的 errors 分开计数）
    integer checks;
    integer point_checks;
    integer i;
    integer j;

    // ========================================================================
    // DUT
    // ========================================================================
    osd_caption dut (
        .pixel_clk    (pixel_clk),
        .rst_n        (rst_n),
        .de           (de),
        .active_x     (active_x),
        .active_y     (active_y),
        .caption_en   (caption_en),
        .state_line   (state_line),
        .index_val    (index_val),
        .caption_pixel(caption_pixel),
        .caption_band (caption_band)
    );

    // ========================================================================
    // 参考模型的查表（复用 RTL 的字符串表与字模，不重复实现字形）
    // ========================================================================
    reg  [3:0] r_line;
    reg  [5:0] r_col;
    reg  [3:0] r_row;
    reg  [2:0] r_bit;
    reg        v_on;
    reg        v_band;

    // 这两个接子模块的 output 端口，必须是 wire（reg 不能驱动 output 端口）
    wire [6:0] ref_raw;
    wire [7:0] ref_gp;

    // 参考模型的序号拆分：直接用 / 和 %，与 RTL 的三级比较器写法不同，
    // 形成交叉验证（RTL 为了省 LUT 用比较器，参考模型用除法）。
    wire [3:0] ref_tens = index_val / 10;
    wire [3:0] ref_ones = index_val % 10;

    wire [6:0] ref_rep = (ref_raw == 7'h23) ? {3'b011, ref_tens} :   // '#'
                         (ref_raw == 7'h2A) ? {3'b011, ref_ones} :   // '*'
                                               ref_raw;

    osd_strings ref_strings (
        .line_sel (r_line),
        .col      (r_col),
        .char_code(ref_raw)
    );

    osd_font8x16 ref_font (
        .char_code(ref_rep[5:0]),
        .row      (r_row),
        .pixels   (ref_gp)
    );

    // ---- 字模探针：独立例化一份 ROM，用于直接抽查字形内容 ----
    // 为什么单独例化而不是层次引用 dut.u_font 的输入端口：
    //   dut.u_font.char_code 连的是 wire rep_code，对 net 做过程赋值在
    //   Verilog-2001 里是非法操作，编译就过不去。探针实例用自己的 reg 驱动。
    reg  [5:0] probe_ch;
    reg  [3:0] probe_row;
    wire [7:0] probe_px;

    osd_font8x16 u_font_probe (
        .char_code(probe_ch),
        .row      (probe_row),
        .pixels   (probe_px)
    );

    // ========================================================================
    // 检查工具
    // ========================================================================
    task chk;
        input cond;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (cond) begin
                $display("PASS: %0s", name);
            end else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_eq;
        input [31:0] got;
        input [31:0] exp;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (got === exp) begin
                $display("PASS: %0s", name);
            end else begin
                $display("FAIL: %0s (got %0d, exp %0d)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ========================================================================
    // 参考模型：坐标 → 查表地址
    //   刻意用 / 和 % 而非位切片，与 RTL 实现形成交叉验证。
    // ========================================================================
    task ref_lookup;
        input  [10:0] x;
        input  [9:0]  y;
        input  [3:0]  sline;
        input  [8:0]  scroll;
        output        o_on;
        output [3:0]  o_line;
        output [5:0]  o_col;
        output [3:0]  o_row;
        output [2:0]  o_bit;
        output        o_band;
        integer src;
        begin
            o_on   = 1'b0;
            o_line = 4'd0;
            o_col  = 6'd0;
            o_row  = 4'd0;
            o_bit  = 3'd0;
            o_band = 1'b0;

            // 标语带: y ∈ [448,463]，全宽，列号随滚动偏移
            if ((y >= 448) && (y <= 463)) begin
                o_on   = 1'b1;
                o_line = 4'd15;
                src    = x + scroll;
                o_col  = (src / 8) % 64;
                o_row  = y % 16;
                o_bit  = src % 8;
                o_band = 1'b1;
            end
            // 标题 / 序号共用 y ∈ [16,31]
            else if ((y >= 16) && (y <= 31)) begin
                o_row = y % 16;
                if ((x >= 32) && (x <= 127)) begin
                    o_on   = 1'b1;
                    o_line = 4'd0;
                    o_col  = (x - 32) / 8;
                    o_bit  = x % 8;
                    o_band = 1'b1;
                end else if ((x >= 576) && (x <= 623)) begin
                    o_on   = 1'b1;
                    o_line = 4'd1;
                    o_col  = (x - 576) / 8;
                    o_bit  = x % 8;
                    o_band = 1'b1;
                end
            end
            // 状态带: y ∈ [48,63]，行号由 state_line 决定
            else if ((y >= 48) && (y <= 63)) begin
                if ((x >= 32) && (x <= 103)) begin
                    o_on   = 1'b1;
                    o_line = sline;
                    o_col  = (x - 32) / 8;
                    o_row  = y % 16;
                    o_bit  = x % 8;
                    o_band = 1'b1;
                end
            end
        end
    endtask

    // ========================================================================
    // 逐点比对
    //   错误累加进 perr（而非 chk 用的 errors），这样"比对通过"这条断言
    //   本身不会被比对失败污染计数。
    // ========================================================================
    task cmp_point;
        input [10:0] x;
        input [9:0]  y;
        input [3:0]  sline;
        input [8:0]  scroll;
        reg exp_px;
        reg exp_band;
        begin
            active_x = x;
            active_y = y;
            ref_lookup(x, y, sline, scroll, v_on, r_line, r_col, r_row, r_bit, v_band);
            #1;
            exp_px   = v_on && ref_gp[7 - r_bit] && caption_en;
            exp_band = v_band && caption_en;
            point_checks = point_checks + 1;
            if (caption_pixel !== exp_px) begin
                if (perr < 8) begin
                    $display("  mismatch px @(%0d,%0d): dut=%b exp=%b line=%0d col=%0d row=%0d bit=%0d ch=%02X",
                             x, y, caption_pixel, exp_px, r_line, r_col, r_row, r_bit, ref_rep);
                end
                perr = perr + 1;
            end
            if (caption_band !== exp_band) begin
                if (perr < 8) begin
                    $display("  mismatch band @(%0d,%0d): dut=%b exp=%b",
                             x, y, caption_band, exp_band);
                end
                perr = perr + 1;
            end
        end
    endtask

    // 推进一帧（只在帧首像素给一个 de 拍，让滚动计数器走一格）
    task one_frame;
        begin
            active_x = 11'd0;
            active_y = 10'd0;
            de       = 1'b1;
            @(posedge pixel_clk);
            de       = 1'b0;
            active_x = 11'd639;
            active_y = 10'd479;
            @(posedge pixel_clk);
        end
    endtask

    // ========================================================================
    // 主流程
    // ========================================================================
    initial begin
        pixel_clk  = 1'b0;
        rst_n      = 1'b0;
        de         = 1'b0;
        active_x   = 11'd0;
        active_y   = 10'd0;
        caption_en = 1'b0;
        state_line = 4'd2;
        index_val  = 5'd0;
        errors     = 0;
        perr       = 0;
        checks     = 0;
        point_checks = 0;

        #22;
        rst_n = 1'b1;
        #5;

        // ------------------------------------------------------------------
        $display("--- C01 font ROM content ---");
        // 'A' = 0x41 → char_code[5:0] = 0x01
        // 8x16 的 'A' 顶部与底部各留一行空白，中间是笔画
        probe_ch  = 6'h01;
        probe_row = 4'd0;  #1;
        chk(probe_px == 8'h00, "C01 'A' top row blank");
        probe_row = 4'd15; #1;
        chk(probe_px == 8'h00, "C01 'A' bottom row blank");
        // 'A' 的中间某行必须有笔画，且不是实心块（8x8 时的典型失败样子）
        probe_row = 4'd8;  #1;
        chk(probe_px != 8'h00, "C01 'A' middle row has ink");
        chk(probe_px != 8'hFF, "C01 'A' middle row is not solid");

        // 空格 = 0x20 → [5:0] = 0x20，全 16 行必须全空
        probe_ch = 6'h20;
        perr = 0;
        for (i = 0; i < 16; i = i + 1) begin
            probe_row = i[3:0]; #1;
            if (probe_px != 8'h00) begin
                $display("  space row %0d not blank: %02X", i, probe_px);
                errors = errors + 1;
            end
        end
        chk(perr == 0, "C01 space glyph all rows blank");

        // 未收录字符（'#' = 0x23 → [5:0]=0x23，不在表内）必须全空
        probe_ch = 6'h23;
        perr = 0;
        for (i = 0; i < 16; i = i + 1) begin
            probe_row = i[3:0]; #1;
            if (probe_px != 8'h00) begin
                $display("  unsupported '#' row %0d = %02X", i, probe_px);
                errors = errors + 1;
            end
        end
        chk(perr == 0, "C01 unsupported char renders blank (blank fallback)");

        // ------------------------------------------------------------------
        $display("--- C02 string table content ---");
        r_line = 4'd0; r_col = 6'd0;  #1;
        chk(ref_raw == 7'h53, "C02 title col0 = 'S'");
        r_col = 6'd11; #1;
        chk(ref_raw == 7'h53, "C02 title col11 = 'S' (CAMPUS ends with S)");
        r_col = 6'd12; #1;
        chk(ref_raw == 7'h00, "C02 title col12 = NUL (end of text)");

        r_line = 4'd1; r_col = 6'd4; #1;
        chk(ref_raw == 7'h23, "C02 index col4 = '#' placeholder");
        r_col = 6'd5; #1;
        chk(ref_raw == 7'h2A, "C02 index col5 = '*' placeholder");

        r_line = 4'd15; r_col = 6'd0; #1;
        chk(ref_raw == 7'h53, "C02 ticker col0 = 'S'");
        r_line = 4'd6; r_col = 6'd0; #1;
        chk(ref_raw == 7'h45, "C02 state line6 col0 = 'E' (EMERGENCY)");
        r_line = 4'd7; r_col = 6'd0; #1;
        chk(ref_raw == 7'h46, "C02 state line7 col0 = 'F' (fault state)");

        // ------------------------------------------------------------------
        $display("--- C03 title band, point by point ---");
        caption_en = 1'b1;
        state_line = 4'd2;
        index_val  = 5'd0;
        perr       = 0;
        for (j = 16; j <= 31; j = j + 1) begin
            for (i = 32; i <= 127; i = i + 1) begin
                cmp_point(i[10:0], j[9:0], 4'd2, 9'd0);
            end
        end
        chk(perr == 0, "C03 title band matches reference at every pixel");

        // ------------------------------------------------------------------
        $display("--- C04 index band, point by point ---");
        for (j = 0; j < 4; j = j + 1) begin
            case (j)
                0: index_val = 5'd0;
                1: index_val = 5'd7;
                2: index_val = 5'd15;
                3: index_val = 5'd31;
            endcase
            perr   = 0;
            for (i = 16; i <= 31; i = i + 1) begin
                cmp_point(11'd576, i[9:0], 4'd2, 9'd0);
                cmp_point(11'd580, i[9:0], 4'd2, 9'd0);
                cmp_point(11'd590, i[9:0], 4'd2, 9'd0);
                cmp_point(11'd600, i[9:0], 4'd2, 9'd0);
                cmp_point(11'd610, i[9:0], 4'd2, 9'd0);
                cmp_point(11'd623, i[9:0], 4'd2, 9'd0);
            end
            chk(perr == 0, "C04 index band matches reference");
        end

        // 序号替换的语义断言：index=7 时十位必须是 '0'、个位必须是 '7'
        //   注意每个赋值后要 #1：idx_tens / idx_ones 是组合逻辑，赋值当拍
        //   还读不到新值，不加延时会把上一条的旧结果读成新结果。
        index_val = 5'd7;   #1;
        chk(dut.idx_tens == 4'd0, "C04 index 7 -> tens digit 0");
        chk(dut.idx_ones == 5'd7, "C04 index 7 -> ones digit 7");
        index_val = 5'd23;  #1;
        chk(dut.idx_tens == 4'd2, "C04 index 23 -> tens digit 2");
        chk(dut.idx_ones == 5'd3, "C04 index 23 -> ones digit 3");
        index_val = 5'd31;  #1;
        chk(dut.idx_tens == 4'd3, "C04 index 31 -> tens digit 3");
        chk(dut.idx_ones == 5'd1, "C04 index 31 -> ones digit 1");

        // ------------------------------------------------------------------
        $display("--- C05 state band, point by point ---");
        index_val = 5'd0;
        for (j = 2; j <= 7; j = j + 1) begin
            state_line = j[3:0];
            perr   = 0;
            for (i = 48; i <= 63; i = i + 1) begin
                cmp_point(11'd32,  i[9:0], j[3:0], 9'd0);
                cmp_point(11'd40,  i[9:0], j[3:0], 9'd0);
                cmp_point(11'd56,  i[9:0], j[3:0], 9'd0);
                cmp_point(11'd72,  i[9:0], j[3:0], 9'd0);
                cmp_point(11'd88,  i[9:0], j[3:0], 9'd0);
                cmp_point(11'd103, i[9:0], j[3:0], 9'd0);
            end
            chk(perr == 0, "C05 state band matches reference");
        end

        // ------------------------------------------------------------------
        $display("--- C06 ticker band ---");
        state_line = 4'd2;
        // 先验证滚动计数器还没动
        chk(dut.scroll_px == 9'd0, "C06 scroll starts at 0");

        perr   = 0;
        for (i = 0; i < 640; i = i + 7) begin
            cmp_point(i[10:0], 10'd448, 4'd2, 9'd0);
            cmp_point(i[10:0], 10'd455, 4'd2, 9'd0);
            cmp_point(i[10:0], 10'd463, 4'd2, 9'd0);
        end
        chk(perr == 0, "C06 ticker at scroll=0 matches reference");

        // 推进 24 帧 → scroll_px = 3（非 8 的倍数，列内偏移也必须跟着动）
        for (i = 0; i < 24; i = i + 1) begin
            one_frame;
        end
        chk(dut.scroll_px == 9'd3, "C09 24 frames -> scroll_px = 3");

        perr   = 0;
        for (i = 0; i < 640; i = i + 7) begin
            cmp_point(i[10:0], 10'd448, 4'd2, 9'd3);
            cmp_point(i[10:0], 10'd455, 4'd2, 9'd3);
            cmp_point(i[10:0], 10'd463, 4'd2, 9'd3);
        end
        chk(perr == 0, "C06 ticker at scroll=3 matches reference");

        // 滚动确实改变了画面：同一个点在 scroll=0 和 scroll=3 下字符不同
        active_x = 11'd0; active_y = 10'd448;
        #1;
        chk(dut.t_line == 4'd15, "C06 ticker uses line 15");
        chk(dut.t_col == ((0 + 3) / 8) % 64, "C06 ticker column follows scroll");

        // ------------------------------------------------------------------
        $display("--- C07 outside all bands ---");
        perr   = 0;
        cmp_point(11'd0,   10'd0,   4'd2, 9'd3);   // 左上角（科普标记区）
        cmp_point(11'd300, 10'd240, 4'd2, 9'd3);   // 画面正中
        cmp_point(11'd300, 10'd15,  4'd2, 9'd3);   // 标题带上方一行
        cmp_point(11'd300, 10'd32,  4'd2, 9'd3);   // 标题带下方一行
        cmp_point(11'd300, 10'd447, 4'd2, 9'd3);   // 标语带上方一行
        cmp_point(11'd300, 10'd464, 4'd2, 9'd3);   // 标语带下方一行（信息条区）
        cmp_point(11'd200, 10'd448, 4'd2, 9'd3);   // 标语带内
        cmp_point(11'd0,   10'd55,  4'd2, 9'd3);   // 状态带左侧空白
        cmp_point(11'd500, 10'd55,  4'd2, 9'd3);   // 状态带右侧空白
        chk(perr == 0, "C07 pixels outside bands are transparent");

        // 明确断言几个"必须为 0"的点，不依赖参考模型
        active_x = 11'd300; active_y = 10'd240; #1;
        chk(caption_pixel == 1'b0 && caption_band == 1'b0,
            "C07 screen centre is fully transparent");
        active_x = 11'd0; active_y = 10'd55; #1;
        chk(caption_band == 1'b0, "C07 no backing band left of state text");
        active_x = 11'd500; active_y = 10'd55; #1;
        chk(caption_band == 1'b0, "C07 no backing band right of state text");

        // ------------------------------------------------------------------
        $display("--- C08 caption_en = 0 silences everything ---");
        caption_en = 1'b0;
        active_x = 11'd40; active_y = 10'd20; #1;
        chk(caption_pixel == 1'b0 && caption_band == 1'b0,
            "C08 disabled: title pixel off");
        active_x = 11'd100; active_y = 10'd455; #1;
        chk(caption_pixel == 1'b0 && caption_band == 1'b0,
            "C08 disabled: ticker pixel off");
        active_x = 11'd40; active_y = 10'd55; #1;
        chk(caption_pixel == 1'b0 && caption_band == 1'b0,
            "C08 disabled: state pixel off");
        caption_en = 1'b1;

        // ------------------------------------------------------------------
        $display("--- C09 scroll counter behaviour ---");
        // 复位清零
        rst_n = 1'b0; #22; rst_n = 1'b1; #5;
        chk(dut.scroll_px == 9'd0, "C09 reset clears scroll_px");
        chk(dut.scroll_div == 3'd0, "C09 reset clears scroll_div");

        // 7 帧还不到 1 像素，第 8 帧才 +1
        for (i = 0; i < 7; i = i + 1) begin
            one_frame;
        end
        chk(dut.scroll_px == 9'd0, "C09 7 frames still scroll_px = 0");
        one_frame;
        chk(dut.scroll_px == 9'd1, "C09 8 frames -> scroll_px = 1");

        // 推到 511 再一帧回绕到 0（512 像素 = 64 字符 = 整轮）
        //   当前 scroll_px = 1，要到 511 还需 510 次递增 = 510*8 = 4080 帧
        for (i = 0; i < 4080; i = i + 1) begin
            one_frame;
        end
        chk(dut.scroll_px == 9'd511, "C09 scroll reaches 511");
        for (i = 0; i < 8; i = i + 1) begin
            one_frame;
        end
        chk(dut.scroll_px == 9'd0, "C09 scroll wraps 511 -> 0 after 8 more frames");

        // ------------------------------------------------------------------
        $display("--- C10 backing band geometry ---");
        caption_en = 1'b1;
        // 标语带整行都有衬底
        active_x = 11'd0;   active_y = 10'd448; #1;
        chk(caption_band == 1'b1, "C10 ticker band starts at x=0");
        active_x = 11'd639; active_y = 10'd463; #1;
        chk(caption_band == 1'b1, "C10 ticker band reaches x=639,y=463");
        // 标题带只在两段 x 区间有衬底
        active_x = 11'd32;  active_y = 10'd16; #1;
        chk(caption_band == 1'b1, "C10 title band left edge x=32");
        active_x = 11'd31;  active_y = 10'd16; #1;
        chk(caption_band == 1'b0, "C10 no band at x=31 (protects sci marker)");
        active_x = 11'd576; active_y = 10'd16; #1;
        chk(caption_band == 1'b1, "C10 index band left edge x=576");
        active_x = 11'd560; active_y = 10'd16; #1;
        chk(caption_band == 1'b0, "C10 gap between title and index has no band");

        // ------------------------------------------------------------------
        $display("");
        if ((errors == 0) && (perr == 0)) begin
            $display("point-by-point comparisons: %0d", point_checks);
            $display("checks: %0d, all passed", checks);
            $display("ALL CHECKS PASSED: osd_caption");
        end else begin
            $display("CHECKS FAILED: %0d chk error(s) + %0d point mismatch(es), %0d checks",
                     errors, perr, checks);
        end
        $finish;
    end

    // 100 MHz 便于快速推进帧计数（真实设计是 25 MHz，本 tb 只验证逻辑）
    always #5 pixel_clk = ~pixel_clk;

    // 超时保护
    initial begin
        #20000000;
        $display("TIMEOUT: tb_osd_caption");
        $finish;
    end

endmodule
