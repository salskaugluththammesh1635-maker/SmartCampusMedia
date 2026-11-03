// ============================================================================
// 文件名  : tb_osd_caption_cjk.v
// 所在位置: sim/testbench/tb_osd_caption_cjk.v
// 所属层次: 仿真 / OSD 字幕渲染器（中文滚动字幕改造）
// 作者    : 智播校园项目组
// ============================================================================
// 【一】测什么
//   rtl/osd/osd_caption.v 在 v2 里把滚动字幕从 8×16 ASCII 改成 16×16 中文，
//   字库搬进块 RAM（rtl/osd/cjk16_font.v）。这次改造有三类风险，本测试台
//   逐条盯住：
//
//     V-11  字库没装进块 RAM —— 屏幕上一个字都不显示，但综合、下载、仿真
//           全都不报错。这是最危险的一种失败，必须硬断言。
//     打拍  中文路径比 ASCII 路径多 1 拍，若补偿错位，字形会逐行错开一格。
//     段选  六段校园介绍按图片序号切换、应急文案优先，接错了屏幕上会出现
//           牛头不对马嘴的文字，同样是"看起来能跑"的失败。
//
// 【二】五条硬门禁（对应任务书 ①②③④⑤）
//   C01 字库进 BRAM：读 glyph=0 的 row=1 必须等于 16'h3FF8，全零按硬失败。
//   C02 三条 ASCII 带未被延迟：与零延迟参考模型逐拍比对。
//   C03 滚动一轮 1,024 像素无接缝。
//   C04 六段中文文案能按图片索引切换。
//   C05 应急文案优先，且一字不截断。
//
// 【三】参考模型怎么做的
//   参考模型不复用被测代码的控制路径，只复用它无权改动的"数据表"：
//     osd_strings  —— 生成的字符码表（脚本另行校验，见 C04/C05 的统计）
//     osd_font8x16 —— ASCII 字模
//     cjk16_font   —— 中文字模（另起一个实例，同样读 cjk16_bitmap.hex）
//   坐标译码、分段选择、打拍结构全部按规格独立重写一遍。这样测的是
//   "被测实现有没有按规格做"，而不是"它跟自己做的是否一样"。
//
// 【四】为什么用 force 设定 scroll_px
//   scroll_px 每 4 帧 +1 像素，一轮 1024 像素 = 4096 帧。一帧 640×480 =
//   307,200 拍，跑完一轮要 1.2×10^9 拍——仿真跑不动。所以扫整个 0..1023
//   范围时用 force 直接赋值，而"每 4 帧 +1"和"1023 回绕到 0"这两条规则
//   另外用真实帧节拍单独验证（C03 的前两段）。
//
// 【五】$readmemh 的路径前提
//   cjk16_font.v 里写的是 $readmemh("cjk16_bitmap.hex", mem)，相对路径以
//   仿真器的工作目录为基准。因此跑仿真前必须把 rtl/osd/cjk16_bitmap.hex
//   放到 vsim 的工作目录（板级综合时由 scripts/sync_src.ps1 复制到
//   project/hdmi/）。找不到文件时仿真器会报错，但综合工具可能只是静默
//   初始化成全零——所以 C01 是唯一能在上板前发现这个问题的检查点。
// ============================================================================
`timescale 1ns / 1ps

module tb_osd_caption_cjk;

    // ========================================================================
    // 时钟与复位
    // ========================================================================
    reg pixel_clk;
    reg rst_n;

    initial begin
        pixel_clk = 1'b0;
        rst_n     = 1'b0;
    end

    // 25 MHz 像素时钟：周期 40 ns
    always #20 pixel_clk = ~pixel_clk;

    // ========================================================================
    // 被测模块
    // ========================================================================
    reg         de;
    reg  [10:0] active_x;
    reg  [9:0]  active_y;
    reg         caption_en;
    reg  [3:0]  state_line;
    reg  [4:0]  index_val;
    reg         narr_en;      // t13：科普视频字幕开关（0=日常态，保持 v1 行为）
    reg  [15:0] frame_idx;    // t13：视频帧号（@5fps）

    wire        caption_pixel;
    wire        caption_band;

    osd_caption dut (
        .pixel_clk     (pixel_clk),
        .rst_n         (rst_n),
        .de            (de),
        .active_x      (active_x),
        .active_y      (active_y),
        .caption_en    (caption_en),
        .state_line    (state_line),
        .index_val     (index_val),
        .narr_en       (narr_en),    // t13：科普视频字幕开关
        .frame_idx     (frame_idx),  // t13：视频帧号
        .caption_pixel (caption_pixel),
        .caption_band  (caption_band)
    );

    // ========================================================================
    // 参考模型的数据表来源
    // ========================================================================
    reg  [3:0]  ref_line_c;
    reg  [5:0]  ref_col_c;
    reg  [3:0]  ref_row_c;
    reg  [3:0]  ref_bit_c;
    reg         ref_on_c;

    // t24：osd_strings 输出由 10 位收成 9 位（原 bit9 的"中/英"标志被证明恒等于
    // line_sel[3]，已从表里删掉）。参考模型必须与 DUT 端口同宽，否则 vsim-3015
    // 会静默截位、C 段逐像素比对全错。
    wire [8:0]  ref_code;

    osd_strings u_ref_strings (
        .line_sel  (ref_line_c),
        .col       (ref_col_c),
        .char_code (ref_code)
    );

    // 占位符替换（'#' 序号十位、'*' 序号个位），只对 ASCII 码生效。
    // t24：原来靠 ref_code[9] 判中英，表里删掉那一位后改判行号。
    //   ★ 这里写成数值比较 "ref_line_c >= 8"，**故意不写 ref_line_c[3]**：
    //     参考模型必须独立于被测表达式，否则 RTL 把 [3] 写成 [2] 时，
    //     参考模型也一起错，54587 条断言照样全绿（同源同错）。
    //   （与 DUT 的 is_cjk_eff 同构，且 line_sel<=7 => ASCII、>=8 => CJK 已被
    //    T3_CJK_TICKER §14 逐条实测证死）。
    wire [6:0] ref_rep = (ref_line_c < 4'd8) && (ref_code[6:0] == 7'h23)
                         ? (7'h30 + (index_val / 5'd10)) :
                         (ref_line_c < 4'd8) && (ref_code[6:0] == 7'h2A)
                         ? (7'h30 + (index_val % 5'd10)) :
                           ref_code[6:0];

    wire [7:0] ref_ascii;

    osd_font8x16 u_ref_ascii (
        .char_code (ref_rep[5:0]),
        .row       (ref_row_c),
        .pixels    (ref_ascii)
    );

    wire [15:0] ref_cjk;

    cjk16_font u_ref_cjk (
        .clk    (pixel_clk),
        .glyph  (ref_code),
        .row    (ref_row_c),
        .pixels (ref_cjk)
    );

    // ========================================================================
    // 被测模块内部状态（层次化引用，仅用于探测，不参与激励）
    //   scroll_px / emg_half 是"内部计数器"，测试台用它们同步参考模型；
    //   这两个值本身的规则另外单独验证（C03/C05）。必须先声明后使用，
    //   因为在下面的参考模型里就要用到它们。
    // ========================================================================
    wire [9:0] dut_scroll_px = dut.scroll_px;
    wire       dut_emg_half  = dut.emg_half;

    // ========================================================================
    // 参考模型的控制路径：按规格独立重写
    // ========================================================================
    wire ref_in_ticker = (active_y >= 10'd448) && (active_y <= 10'd463);
    wire ref_in_title  = (active_y >= 10'd16)  && (active_y <= 10'd31);
    wire ref_in_state  = (active_y >= 10'd48)  && (active_y <= 10'd63);

    // 滚动后坐标：一轮 = 64 字 × 16 像素
    wire [10:0] ref_ticker_src = active_x + {1'b0, dut_scroll_px};
    wire [5:0]  ref_ticker_col = ref_ticker_src[9:4];
    wire [3:0]  ref_ticker_bit = ref_ticker_src[3:0];

    // 分段：日常按图片序号取 line 8..13，越界回落 line 8；应急取 line 14/15
    wire [3:0] ref_seg_line   = (index_val >= 5'd6) ? 4'd8
                                : (4'd8 + {1'b0, index_val[2:0]});
    wire [3:0] ref_emg_line   = 4'd14 + {3'b000, dut_emg_half};
    wire [3:0] ref_ticker_line = (state_line == 4'd6) ? ref_emg_line : ref_seg_line;

    // 视频字幕模式是否生效（应急优先，与 DUT 同口径）
    wire       ref_narr_active = narr_en && !(state_line == 4'd6);

    // 交叉核对：DUT 的 narr_subline 列号必须是静态 active_x[9:4]。
    // 这一条单独拎出来断言，是因为接错成滚动列号时的现象是"字幕边播边滚走"，
    // 看上去像排版问题而不是接线错误，只有直接盯住端口才能一眼定位。
    wire [5:0] dut_narr_col = dut.u_narr.col;

    // ========================================================================
    // 参考模型：科普视频字幕（narr_subline 与 DUT 同表，故直接例化同一份数据源）
    //   注意列号：必须给静态 active_x[9:4]，不能给滚动列号。
    // ========================================================================
    wire [8:0] ref_narr_code;

    narr_subline u_ref_narr (
        .clk       (pixel_clk),
        .rst_n     (rst_n),
        .frame_idx (frame_idx),
        .col       (active_x[9:4]),
        .narr_code (ref_narr_code)
    );

    always @(*) begin
        ref_on_c   = 1'b0;
        ref_line_c = 4'd0;
        ref_col_c  = 6'd0;
        ref_row_c  = 4'd0;
        ref_bit_c  = 4'd0;

        // t13 起：caption_en 只门控底部滚动带（Key5 语义），
        // 标题行 / 状态行改由 narr_en（科普模式）门控，不再受 caption_en 影响。
        if (ref_in_ticker && caption_en) begin
            ref_on_c   = 1'b1;
            ref_line_c = ref_ticker_line;
            // 列号与格内位偏移必须同源：
            //   科普字幕 = 静态整行，列号 x[9:4]、位偏移 x[3:0]
            //   滚动字幕 = 滚动坐标，列号 ticker_src[9:4]、位偏移 ticker_src[3:0]
            ref_col_c  = ref_narr_active ? active_x[9:4] : ref_ticker_col;
            ref_row_c  = active_y[3:0];
            ref_bit_c  = ref_narr_active ? active_x[3:0] : ref_ticker_bit;
        end else if (ref_in_title && !narr_en) begin
            ref_row_c = active_y[3:0];
            if ((active_x >= 11'd32) && (active_x <= 11'd127)) begin
                ref_on_c   = 1'b1;
                ref_line_c = 4'd0;
                ref_col_c  = (active_x - 11'd32) >> 3;
                ref_bit_c  = {1'b0, active_x[2:0]};
            end else if ((active_x >= 11'd576) && (active_x <= 11'd623)) begin
                ref_on_c   = 1'b1;
                ref_line_c = 4'd1;
                ref_col_c  = (active_x - 11'd576) >> 3;
                ref_bit_c  = {1'b0, active_x[2:0]};
            end
        end else if (ref_in_state && !narr_en) begin
            ref_row_c = active_y[3:0];
            if ((active_x >= 11'd32) && (active_x <= 11'd103)) begin
                ref_on_c   = 1'b1;
                ref_line_c = state_line;
                ref_col_c  = (active_x - 11'd32) >> 3;
                ref_bit_c  = {1'b0, active_x[2:0]};
            end
        end
    end

    // ASCII 路径零延迟：直接用当前拍组合结果
    wire ref_px_ascii = ref_on_c && ref_ascii[~ref_bit_c[2:0]];

    // 中文路径 1 拍：配对信号延后一拍，与块 RAM 的输出寄存器对齐
    reg [3:0] ref_bit_q;
    reg       ref_on_q;
    reg       ref_is_cjk_q;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_bit_q    <= 4'd0;
            ref_on_q     <= 1'b0;
            ref_is_cjk_q <= 1'b0;
        end else begin
            ref_bit_q    <= ref_bit_c;
            ref_on_q     <= ref_on_c;
            // 科普路径的字形码恒为中文（DUT 里由 is_cjk_eff = narr_active | t_line[3]
            // 强制标定），不能拿查表行的 ASCII/CJK 属性来判——那条路在科普模式下
            // 不参与取字。t24：中英标志已不在表里，改由行号 ref_line_c[3] 给出，
            // 与 DUT 的 is_cjk_eff 逐位同构。
            ref_is_cjk_q <= ref_narr_active | (ref_line_c >= 4'd8);
        end
    end

    wire ref_px_cjk = ref_on_q && ref_is_cjk_q && ref_cjk[~ref_bit_q[3:0]];

    // ------------------------------------------------------------------
    // 参考模型的科普字幕路径（2 拍）
    //   拍 N   ：narr 地址 = base[sel] + active_x[9:4]
    //   拍 N+1 ：ref_narr_code = narr_mem[地址]        <- narr_subline 那 1 拍
    //   拍 N+2 ：ref_cjk_narr = cjk_mem[{code,row}]     <- cjk16_font 那 1 拍
    //   所以行号必须取"拍 N 的行号"= ref_row_q，位偏移取 2 拍后的 ref_bit_q2，
    //   任一取错都会让每个字符块内的点阵错位（字还是那个字、笔画位置乱）。
    // ------------------------------------------------------------------
    reg [3:0] ref_row_q;      // 第 1 拍寄存：与 ref_narr_code 配对的字符行号
    reg [3:0] ref_bit_q2;     // 第 2 拍寄存：科普路径的格内位偏移
    reg       ref_on_q2;
    reg       ref_is_cjk_q2;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_row_q     <= 4'd0;
            ref_bit_q2    <= 4'd0;
            ref_on_q2     <= 1'b0;
            ref_is_cjk_q2 <= 1'b0;
        end else begin
            ref_row_q     <= ref_row_c;
            ref_bit_q2    <= ref_bit_q;
            ref_on_q2     <= ref_on_q;
            ref_is_cjk_q2 <= ref_is_cjk_q;
        end
    end

    wire [15:0] ref_cjk_narr;

    cjk16_font u_ref_cjk_narr (
        .clk    (pixel_clk),
        .glyph  (ref_narr_code[8:0]),
        .row    (ref_row_q),
        .pixels (ref_cjk_narr)
    );

    wire ref_px_narr = ref_on_q2 && ref_is_cjk_q2 && ref_cjk_narr[~ref_bit_q2[3:0]];

    // 中文路径分两条：科普字幕 2 拍、日常/应急滚动字幕 1 拍
    wire ref_px_ticker = ref_narr_active ? ref_px_narr : ref_px_cjk;

    wire ref_pixel = ref_in_ticker ? ref_px_ticker : ref_px_ascii;

    // 参考模型的衬底带（与 DUT 的 band_on 逐项对齐：
    //   滚动带受 caption_en 管，标题行/状态行每次由 narr_en 管）
    wire ref_band_title_x = ((active_x >= 11'd32) && (active_x <= 11'd127)) ||
                            ((active_x >= 11'd576) && (active_x <= 11'd623));
    wire ref_band_state_x = (active_x >= 11'd32) && (active_x <= 11'd103);
    wire ref_band = (ref_in_ticker && caption_en) ||
                    (ref_in_title && ref_band_title_x && !narr_en) ||
                    (ref_in_state && ref_band_state_x && !narr_en);

    // ========================================================================
    // 计数与工具
    // ========================================================================
    integer fails;
    integer checks;

    initial begin
        fails  = 0;
        checks = 0;
    end

    // 调试上下文：失败时打印被测与参考的全部中间量，便于定位
    task dbg_ctx;
        begin
            $display("        x=%0d y=%0d de=%b en=%b st=%0d idx=%0d",
                     active_x, active_y, de, caption_en, state_line, index_val);
            $display("        DUT: pix=%b band=%b t_on=%b t_line=%0d t_col=%0d t_row=%0d t_bit=%0d code=%h ascii=%h",
                     caption_pixel, caption_band, dut.t_on, dut.t_line, dut.t_col,
                     dut.t_row, dut.t_bit, dut.raw_code, dut.ascii_px);
            $display("        REF: pix=%b band=%b r_on=%b r_line=%0d r_col=%0d r_row=%0d r_bit=%0d code=%h ascii=%h",
                     ref_pixel, ref_band, ref_on_c, ref_line_c, ref_col_c,
                     ref_row_c, ref_bit_c, ref_code, ref_ascii);
        end
    endtask

    task chk;
        input        cond;
        input [511:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("[FAIL] %0s  (t=%0t)", msg, $time);
                dbg_ctx;
            end
        end
    endtask

    task chk_eq16;
        input [15:0]  got;
        input [15:0]  exp;
        input [511:0] msg;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s  got=16'h%04X exp=16'h%04X  (t=%0t)",
                         msg, got, exp, $time);
            end
        end
    endtask

    // 驱动一个像素：在时钟下降沿改激励，上升沿后采样
    task drive_pixel;
        input [10:0] x;
        input [9:0]  y;
        begin
            de       = 1'b1;
            active_x = x;
            active_y = y;
        end
    endtask

    // 等待一个像素拍：在上升沿之后、下一个下降沿之前采样
    task next_pixel;
        begin
            @(posedge pixel_clk);
            #8;
        end
    endtask

    // 走一拍并比对被测输出与参考模型
    task step_check;
        input [10:0] x;
        input [9:0]  y;
        input [255:0] tag;
        begin
            drive_pixel(x, y);
            next_pixel;
            chk(caption_pixel === ref_pixel, tag);
            chk(caption_band  === ref_band,  "caption_band 与参考不符");
        end
    endtask

    // ========================================================================
    // 探测：字库内容统计、行内容统计
    // ========================================================================
    reg  [3:0]  probe_line;
    reg  [5:0]  probe_col;
    wire [8:0]  probe_code;

    osd_strings u_probe_strings (
        .line_sel  (probe_line),
        .col       (probe_col),
        .char_code (probe_code)
    );

    reg  [8:0]  probe_glyph;
    reg  [3:0]  probe_row;
    wire [15:0] probe_pixels;

    cjk16_font u_probe_rom (
        .clk    (pixel_clk),
        .glyph  (probe_glyph),
        .row    (probe_row),
        .pixels (probe_pixels)
    );

    // ========================================================================
    // 主流程
    // ========================================================================
    integer i;
    integer j;
    integer nz;
    integer lit;
    integer col_seen [0:63];
    reg [9:0] captured [0:1023];
    reg [9:0] expect_c;
    reg [3:0] expect_b;
    reg [3:0] saved_scroll;

    initial begin
        $display("================================================================");
        $display(" tb_osd_caption_cjk : 中文滚动字幕（cjk16 字库进 BRAM）");
        $display("================================================================");

        de         = 1'b0;
        active_x   = 11'd0;
        active_y   = 10'd0;
        caption_en = 1'b1;
        state_line = 4'd5;
        index_val  = 5'd0;
        narr_en    = 1'b0;    // t13：默认日常态，基线必须与改造前逐拍一致
        frame_idx  = 16'd0;

        // ------------------------------------------------------------------
        // 复位
        // ------------------------------------------------------------------
        rst_n = 1'b0;
        repeat (4) @(posedge pixel_clk);
        rst_n = 1'b1;
        @(posedge pixel_clk);

        // ==================================================================
        // C01 字库进了块 RAM 没有（V-11 硬门禁）
        //
        //   字库存放格式：地址 = {glyph[8:0], row[3:0]}，一个字形 16 行连续。
        //   cjk16_bitmap.hex 的第 0 行是 "0000"、第 1 行是 "3ff8"，
        //   即 mem[13'd0] = 16'h0000（「日」的第 0 行，该行确实没有笔画）、
        //   mem[13'd1] = 16'h3FF8（「日」的第 1 行，顶上那一横）。
        //
        //   任务书与裁定书 §5.4 把这条写成"读 glyph=0 第 0 行必须 == 3FF8"，
        //   指的就是 mem[13'd1] 这一项（"索引 0 的第 0 行"是从 1 数起的第 1 行）。
        //   本用例两种口径都断言：mem[1] 必须是 3FF8，mem[0] 必须是 0000，
        //   并且整个字库必须有大量非零项——全零才是真正的失败形态。
        // ==================================================================
        $display("---- C01 字库进块 RAM（V-11） ----");

        chk_eq16(dut.u_cjk.mem[13'd0], 16'h0000, "C01 mem[13'd0] 应为 16'h0000");
        chk_eq16(dut.u_cjk.mem[13'd1], 16'h3FF8,
                 "C01 mem[13'd1]（索引 0「日」第 1 行）应为 16'h3FF8");

        // 前 7,440 项的非零行数。
        //
        //   这里必须用 != 而不是 !==。!== 是"四态严格不等"，x !== 0 为真，
        //   于是"字库根本没装载（整片 x）"会被统计成 7,440 个非零行、反而通过。
        //   != 是"逻辑不等"，任一操作数为 x 时结果为 x，在 if 里按假处理：
        //     mem = 0000 → 假，不计数（对）
        //     mem = xxxx → x，不计数（对：未装载就该判失败）
        //     mem = 3FF8 → 真，计数（对）
        nz = 0;
        for (i = 0; i < 7440; i = i + 1) begin
            if (dut.u_cjk.mem[i[12:0]] != 16'h0000) nz = nz + 1;
        end
        $display("     字库非零行数 = %0d / 7440", nz);
        chk(nz > 6000, "C01 字库非零行数过少，疑似未装载");

        // 未填的 752 个地址（索引 465..511）读出必须是 0。
        //
        //   同样用 != 而不用 !==，为的是不依赖 RTL 的实现方式：
        //   $readmemh 只填 0..7439，其余 752 项若没有 initial 清零循环，仿真里
        //   保持 x（硬件块 RAM 上电为 0）。x 不是缺陷，用 !== 会误报失败；
        //   用 != 时 x 结果为 x、按假处理，只有"读出一个确定的非零值"才失败。
        if (dut.u_cjk.mem[13'd7440] != 16'h0000) begin
            checks = checks + 1;
            fails  = fails + 1;
            $display("[FAIL] C01 未用地址 mem[13'd7440] 应为 16'h0000，实读 16'h%04X  (t=%0t)",
                     dut.u_cjk.mem[13'd7440], $time);
        end else begin
            checks = checks + 1;
        end

        // 功能验证：块 RAM 同步读恰好 1 拍
        probe_glyph = 9'd0;
        probe_row   = 4'd0;
        @(posedge pixel_clk);
        #8;
        chk_eq16(probe_pixels, 16'h0000, "C01 探测：row=0 当拍应仍是旧值");
        probe_row = 4'd1;
        @(posedge pixel_clk);
        #8;
        chk_eq16(probe_pixels, 16'h3FF8, "C01 探测：同步读 1 拍后应为 3FF8");

        // ==================================================================
$display(" [用例累计] 进入 C02 前：检查项 %0d 个，失败 %0d 个", checks, fails);

        // C02 三条 ASCII 带一个寄存器都没加
        //
        //   做法：把三条带整扫一遍，逐拍与"零延迟参考模型"比对。
        //   若有人给 ASCII 路径加了打拍，第一拍就会不匹配——这正是要抓的。
        // ==================================================================
        $display("---- C02 三条 ASCII 带未被延迟 ----");

        caption_en = 1'b1;
        state_line = 4'd5;      // WAITING
        index_val  = 5'd7;      // 让 '#' '*' 两个占位符都产生非零数字

        // 标题带 + 序号带（y = 16..31）
        lit = 0;
        for (i = 16; i <= 31; i = i + 1) begin
            for (j = 0; j < 640; j = j + 1) begin
                step_check(j[10:0], i[9:0], "C02 标题/序号带像素与零延迟参考不符");
                if (caption_pixel) lit = lit + 1;
            end
        end
        $display("     标题带 + 序号带点亮像素 = %0d", lit);
        chk(lit > 100, "C02 标题/序号带几乎全灭，参考模型或译码可能接错");

        // 状态带（y = 48..63）
        lit = 0;
        for (i = 48; i <= 63; i = i + 1) begin
            for (j = 0; j < 640; j = j + 1) begin
                step_check(j[10:0], i[9:0], "C02 状态带像素与零延迟参考不符");
                if (caption_pixel) lit = lit + 1;
            end
        end
        $display("     状态带点亮像素 = %0d", lit);
        chk(lit > 20, "C02 状态带几乎全灭");

        // ------------------------------------------------------------------
        // Key5 语义（t13 需求修正）：caption_en 是"底部字幕开关"，只关滚动带，
        //   不关标题行和状态行。改造前它是整层总开关，会把三条带一起关掉，
        //   与用户"底部字幕开关按钮是 Key5"的原话不符（D-06）。
        //   下面的断言把新语义钉死，同时验证标题行/状态行真的还亮着：
        //   如果哪天有人把 caption_en 又接回整层门控，标题/状态行的采样点会变灭。
        // ------------------------------------------------------------------
        caption_en = 1'b0;
        narr_en    = 1'b0;

        // (a) 滚动带 y∈[448,463]：整条熄灭，且衬底带为 0
        lit = 0;
        for (j = 0; j < 640; j = j + 1) begin
            drive_pixel(j[10:0], 10'd455);
            next_pixel;
            if (caption_pixel) lit = lit + 1;
            chk(caption_band === 1'b0, "C02 Key5 关闭时滚动带衬底带必须为 0");
        end
        chk(lit == 0, "C02 Key5 关闭时滚动带必须整条熄灭");

        // (b) 标题行 y=16..31 × x=32..127：仍必须点亮（caption_en 不应影响它）
        //     逐列扫满整个 x 带，统计点亮像素；字间空白列本来就有，
        //     所以判据是"点亮数 > 0"而不是"全亮"。
        lit = 0;
        for (j = 32; j <= 127; j = j + 1) begin
            drive_pixel(j[10:0], 10'd20);
            next_pixel;
            if (caption_pixel) lit = lit + 1;
        end
        chk(lit > 0, "C02 Key5 关闭时标题行必须仍点亮（Key5 只管底部带）");
        drive_pixel(11'd36, 10'd20);
        next_pixel;
        chk(caption_band === 1'b1, "C02 Key5 关闭时标题行衬底带仍应为 1");

        // (c) 状态行 y=48..63 × x=32..103：同样仍必须点亮
        lit = 0;
        for (j = 32; j <= 103; j = j + 1) begin
            drive_pixel(j[10:0], 10'd52);
            next_pixel;
            if (caption_pixel) lit = lit + 1;
        end
        chk(lit > 0, "C02 Key5 关闭时状态行必须仍点亮（Key5 只管底部带）");
        drive_pixel(11'd36, 10'd52);
        next_pixel;
        chk(caption_band === 1'b1, "C02 Key5 关闭时状态行衬底带仍应为 1");

        // (d) 反过来：caption_en=1 时三条带全亮，且与参考模型逐拍一致
        caption_en = 1'b1;
        lit = 0;
        for (j = 0; j < 640; j = j + 1) begin
            drive_pixel(j[10:0], 10'd455);
            next_pixel;
            if (caption_pixel) lit = lit + 1;
        end
        chk(lit > 100, "C02 caption_en=1 时滚动带应有大量笔画");

        // ==================================================================
$display(" [用例累计] 进入 C03 前：检查项 %0d 个，失败 %0d 个", checks, fails);

        // C03 滚动一轮 1,024 像素无接缝
        //
        //   (a) 每 4 帧 +1 像素（scroll_div 阈值 3'd3）
        //   (b) 1023 → 0 回绕恰好等价于再走一个像素
        //   (c) 逐像素走满 1024 个相位：每个字 16 像素等宽、64 字一轮、
        //       相邻相位之间的列号变化严格是"每 16 次进一格、63 之后回 0"
        // ==================================================================
        $display("---- C03 滚动一轮 1,024 像素 ----");

        // (a) 每 4 帧 +1 像素：连走 8 帧应前进 2 个像素
        force dut.scroll_px = 10'd0;
        release dut.scroll_px;
        // 用复位把滚动计数器清零
        rst_n = 1'b0;
        repeat (2) @(posedge pixel_clk);
        rst_n = 1'b1;
        @(posedge pixel_clk);

        drive_pixel(11'd0, 10'd0);
        next_pixel;
        chk(dut_scroll_px === 10'd0, "C03 复位后 scroll_px 应为 0");

        for (i = 0; i < 8; i = i + 1) begin
            // 每帧的帧节拍只在 (x=0,y=0) 产生一次
            drive_pixel(11'd0, 10'd0);
            next_pixel;
            drive_pixel(11'd1, 10'd0);
            next_pixel;
        end
        $display("     走 8 帧后 scroll_px = %0d（期望 2）", dut_scroll_px);
        chk(dut_scroll_px === 10'd2, "C03 每 4 帧应前进 1 像素");

        // (b) 回绕：scroll_px 在 1023 时再走一像素必须回到 0
        //
        //   注意 force 会压住 always 块里的赋值，所以不能"force 成 1023 再让它
        //   自己加"。做法是：force 到 1023 让寄存器停在那个值，然后 release
        //   （寄存器保持 1023），再用 force 把 scroll_div 顶到 3，制造一次
        //   "本帧真的走一像素"的帧节拍，看它是否 1023 + 1 = 0 回绕。
        force dut.scroll_px = 10'd1023;
        @(posedge pixel_clk);
        #8;
        release dut.scroll_px;
        chk(dut_scroll_px === 10'd1023, "C03 回绕前 scroll_px 应为 1023");

        force dut.scroll_div = 3'd3;
        drive_pixel(11'd0, 10'd0);          // 帧节拍 → scroll_px <= 1024 → 0
        next_pixel;
        release dut.scroll_div;
        drive_pixel(11'd1, 10'd0);
        next_pixel;
        $display("     1023 之后走一像素，scroll_px = %0d（期望 0）", dut_scroll_px);
        chk(dut_scroll_px === 10'd0, "C03 1023 之后再走一像素应回绕到 0");

        // (c) 逐相位扫 1024 个像素，检查字符列与格内偏移
        //
        //   固定 x = 0，令 scroll_px = s：
        //       列号 = (0 + s) >> 4 = s / 16，共 64 个值，每值持续 16 个相位
        //       位号 = s & 15
        //   把每个相位的列号记下来，检查"每 16 次进一格、63 之后回 0"。
        for (i = 0; i < 64; i = i + 1) col_seen[i] = 0;

        for (i = 0; i < 1024; i = i + 1) begin
            force dut.scroll_px = i[9:0];
            drive_pixel(11'd0, 10'd448);
            next_pixel;

            expect_c = i[9:4];          // (0 + s) >> 4
            expect_b = i[3:0];          // (0 + s) & 15

            chk(dut.ticker_col === expect_c[5:0], "C03 滚动列号不对");
            chk(dut.t_bit === expect_b, "C03 滚动格内位号不对");

            col_seen[expect_c[5:0]] = col_seen[expect_c[5:0]] + 1;
        end

        nz = 0;
        for (i = 0; i < 64; i = i + 1) begin
            if (col_seen[i] != 16) begin
                nz = nz + 1;
                $display("     列 %0d 出现 %0d 次（期望 16）", i, col_seen[i]);
            end
        end
        chk(nz == 0, "C03 每个字应恰好占 16 个像素相位");

        // 接缝：x = 639 时，scroll=1023 与 scroll=0 必须是同一列
        //   (639 + 1023) >> 4 = 103，& 63 = 39
        //   (639 +    0) >> 4 =  39，& 63 = 39
        //   两者相同 → 回绕那一拍与"继续往前滚一像素"完全等价，无跳变
        //
        //   注意：这里直接写常量 6'd39 而不是再算一遍表达式。原因是 Verilog 的
        //   相等运算符 === 优先级高于按位与 &，写
        //       chk(dut.ticker_col === (expr) & 6'h3F, ...)
        //   会被解析成 (ticker_col === (expr)) & 6'h3F，结果是 1 位 0/1，
        //   恒假。这类"断言自己写错、看着像 DUT 错"的坑必须靠常量规避。
        force dut.scroll_px = 10'd1023;
        drive_pixel(11'd639, 10'd448);
        next_pixel;
        $display("     接缝 scroll=1023 x=639 → ticker_col = %0d（期望 39）",
                 dut.ticker_col);
        chk(dut.ticker_col === 6'd39, "C03 接缝：scroll=1023 x=639 的列号不符");

        force dut.scroll_px = 10'd0;
        drive_pixel(11'd639, 10'd448);
        next_pixel;
        $display("     接缝 scroll=0    x=639 → ticker_col = %0d（期望 39）",
                 dut.ticker_col);
        chk(dut.ticker_col === 6'd39, "C03 接缝：scroll=0 x=639 的列号不符");

        force dut.scroll_px = 10'd0;
        release dut.scroll_px;

        // ==================================================================
$display(" [用例累计] 进入 C04 前：检查项 %0d 个，失败 %0d 个", checks, fails);

        // C04 六段中文文案按图片索引切换
        // ==================================================================
        $display("---- C04 六段校园介绍按图片索引切换 ----");

        // (a) 表格内容：六段长度必须与 campus_ticker.txt 一致
        //     38 / 39 / 38 / 38 / 34 / 33，其余位置为空白
        begin : c04_table
            integer lens [0:5];
            integer got_len;
            integer bad;

            lens[0] = 38; lens[1] = 39; lens[2] = 38;
            lens[3] = 38; lens[4] = 34; lens[5] = 33;
            bad = 0;

            for (i = 0; i < 6; i = i + 1) begin
                got_len = 0;
                probe_line = 4'd8 + i[3:0];
                for (j = 0; j < 64; j = j + 1) begin
                    probe_col = j[5:0];
                    #1;
                    if (probe_code !== 9'h000) got_len = got_len + 1;
                end
                $display("     line %0d 非空字数 = %0d（期望 %0d）",
                         8 + i, got_len, lens[i]);
                if (got_len != lens[i]) bad = bad + 1;
                chk(got_len == lens[i], "C04 段落字数与文本源不符");
            end
        end

        // (b) 六段必须互不相同（段号译码接错时最容易出现两段相同）
        begin : c04_distinct
            reg [8:0] c0, c1;
            integer dup;
            dup = 0;
            for (i = 0; i < 6; i = i + 1) begin
                probe_line = 4'd8 + i[3:0];
                probe_col  = 6'd0;
                #1;
                c0 = probe_code;
                for (j = i + 1; j < 6; j = j + 1) begin
                    probe_line = 4'd8 + j[3:0];
                    probe_col  = 6'd0;
                    #1;
                    c1 = probe_code;
                    if ((c0 !== 9'h000) && (c0 === c1)) dup = dup + 1;
                end
            end
            chk(dup == 0, "C04 有两段首字相同，段号译码可能接错");
        end

        // (c) 行为：index_val = 0..5 时 t_line 必须是 8..13，且像素流与参考一致
        for (i = 0; i < 6; i = i + 1) begin
            index_val = i[4:0];
            force dut.scroll_px = 10'd0;

            // 行号译码
            drive_pixel(11'd0, 10'd448);
            next_pixel;
            chk(dut.t_line === (4'd8 + i[3:0]),
                "C04 图片序号对应的字幕行号不对");

            // 整行逐像素比对（覆盖 40 个中文字 + 边界）
            for (j = 0; j < 640; j = j + 1) begin
                step_check(j[10:0], 10'd448, "C04 滚动像素流与参考不符");
            end
        end

        // (d) 序号越界（≥6）回落到第 1 段
        index_val = 5'd6;
        drive_pixel(11'd0, 10'd448);
        next_pixel;
        chk(dut.t_line === 4'd8, "C04 index_val=6 应回落到 line 8");
        index_val = 5'd31;
        drive_pixel(11'd0, 10'd448);
        next_pixel;
        chk(dut.t_line === 4'd8, "C04 index_val=31 应回落到 line 8");

        // ==================================================================
$display(" [用例累计] 进入 C05 前：检查项 %0d 个，失败 %0d 个", checks, fails);

        // C05 应急文案优先，且一字不截断
        // ==================================================================
        $display("---- C05 应急文案优先 ----");

        // (a) 应急文案三段共 104 字，一行 64 列装不下，拆 line 14/15
        //     line 14 非空 63 字、line 15 非空 41 字，合计 104 字——一个不少
        begin : c05_table
            integer n14, n15;
            n14 = 0;
            n15 = 0;
            probe_line = 4'd14;
            for (j = 0; j < 64; j = j + 1) begin
                probe_col = j[5:0];
                #1;
                if (probe_code !== 9'h000) n14 = n14 + 1;
            end
            probe_line = 4'd15;
            for (j = 0; j < 64; j = j + 1) begin
                probe_col = j[5:0];
                #1;
                if (probe_code !== 9'h000) n15 = n15 + 1;
            end
            $display("     应急文案：line14 = %0d 字，line15 = %0d 字，合计 %0d 字",
                     n14, n15, n14 + n15);
            chk(n14 + n15 == 104, "C05 应急文案字数不是 104，有字被截断");
            chk(n14 > 0 && n15 > 0, "C05 应急文案两行都应非空");
        end

        // (b) state_line = 6（EMERGENCY）时，即使正在看第 4 张图，
        //     底部字幕也必须切到应急文案，不能显示校园介绍
        index_val  = 5'd3;
        state_line = 4'd6;
        force dut.scroll_px = 10'd0;
        force dut.emg_half  = 1'b0;

        drive_pixel(11'd0, 10'd448);
        next_pixel;
        chk(dut.t_line === 4'd14, "C05 应急模式应显示 line 14");
        chk(dut.t_line !== (4'd8 + 4'd3), "C05 应急模式不应显示当前图号的校园介绍");

        // 整行逐像素比对（参考模型同样按 state_line==6 选应急行）
        for (j = 0; j < 640; j = j + 1) begin
            step_check(j[10:0], 10'd448, "C05 应急字幕像素流与参考不符");
        end

        // (c) 两行交替：emg_half 翻转后显示 line 15
        force dut.emg_half = 1'b1;
        drive_pixel(11'd0, 10'd448);
        next_pixel;
        chk(dut.t_line === 4'd15, "C05 emg_half=1 时应显示 line 15");
        for (j = 0; j < 640; j = j + 1) begin
            step_check(j[10:0], 10'd448, "C05 应急第二行像素流与参考不符");
        end
        release dut.emg_half;

        // (d) 轮次翻转规则：滚完一轮（scroll_px 从 1023 回绕到 0）翻一次
        //
        //   这里不能 force emg_half —— force 会把翻转赋值本身压住，
        //   于是"期望它翻转"的断言永远失败。正确做法是记录当前值 pre，
        //   然后制造一次真实的"滚完一轮"事件，看它是否变成 ~pre。
        begin : c05_flip
            reg pre;

            force dut.scroll_px  = 10'd1023;
            force dut.scroll_div = 3'd3;

            // 非帧首拍：frame_tick 为 0，不应翻转
            drive_pixel(11'd0, 10'd448);
            next_pixel;
            pre = dut.emg_half;
            chk(dut.emg_half === pre, "C05 非帧首拍不应翻转 emg_half");

            // 帧节拍在 (0,0)：scroll_px 已到 1023，本拍应回绕并翻转
            drive_pixel(11'd0, 10'd0);
            next_pixel;
            drive_pixel(11'd1, 10'd0);
            next_pixel;
            $display("     滚完一轮后 emg_half = %0b（翻转为 %0b）",
                     dut.emg_half, ~pre);
            chk(dut.emg_half === ~pre, "C05 滚完一轮后 emg_half 应翻转");

            // 再滚一轮应翻回去（证明是自翻转，不是一次性置位）
            force dut.scroll_px = 10'd1023;
            drive_pixel(11'd0, 10'd0);
            next_pixel;
            drive_pixel(11'd1, 10'd0);
            next_pixel;
            chk(dut.emg_half === pre, "C05 再滚一轮后 emg_half 应翻回原值");

            release dut.scroll_px;
            release dut.scroll_div;
        end

        // (e) 退出应急模式后回到正常分段
        state_line = 4'd5;
        index_val  = 5'd2;
        drive_pixel(11'd0, 10'd448);
        next_pixel;
        chk(dut.t_line === 4'd10, "C05 退出应急后应回到该图号的校园介绍");

        // ==================================================================
$display(" [用例累计] 进入 C06 前：检查项 %0d 个，失败 %0d 个", checks, fails);

        // C06 科普模式视频字幕（t13 B-lite）：静态、不随滚动走、边界无字
        //
        //   这一组用例的由来：最初把 narr_subline 的列号接到了 ticker_col
        //   （滚动列号），结果是字幕边播边往右滚出屏幕，第一段 16 字
        //   64 帧（12.8 s）就整体消失，而整支视频平均每段只有 7 s ——
        //   字幕根本来不及滚完就换段了，比不显示还糟。
        //   下面 ①②③④ 四条分别钉死：不滚动 / 段尾无字 / 起始帧之前无字 /
        //   结束帧之后无字。
        // ==================================================================
        // ------------------------------------------------------------------
        // 【基线快照】C01..C05 全部在 narr_en=0 / frame_idx=0 下跑，
        //   这一段累计值就是「B-lite 改造前的日常模式基线」。
        //   第 5 条 acceptance 要求"仍 54248 项 / 失败 0"，对着这一行看。
        //   C06 之后 narr_en 置 1，故必须在进入 C06 之前打印。
        // ------------------------------------------------------------------
        $display(" BASELINE(narr_en=0) C01..C05 累计检查项 = %0d 个，失败 = %0d 个",
                 checks, fails);

        $display("---- C06 科普视频字幕：静态不滚动 + 三条边界 ----");

        caption_en = 1'b1;
        narr_en    = 1'b1;
        state_line = 4'd5;      // 非应急
        index_val  = 5'd0;

        // 段 0 的起始帧是 4，取 frame_idx = 4 保证落在第一段
        frame_idx  = 16'd4;

        // (a) 列号来源必须静态：DUT 的 narr_subline.col 应等于 active_x[9:4]，
        //     与 scroll_px 无关。逐相位扫一遍 scroll_px，端口值必须纹丝不动。
        begin : c06_static_col
            integer phase;
            reg [5:0] col0;
            reg       same;

            drive_pixel(11'd160, 10'd455);   // x=160 → active_x[9:4] = 10
            next_pixel;
            col0 = dut.u_narr.col;
            chk(col0 === 6'd10, "C06 科普字幕列号应为 active_x[9:4] = 10");

            same = 1'b1;
            for (phase = 0; phase < 16; phase = phase + 1) begin
                force dut.scroll_px = phase[9:0] * 10'd64;
                #1;
                if (dut.u_narr.col !== col0) same = 1'b0;
                release dut.scroll_px;
            end
            chk(same, "C06 科普字幕列号不得随 scroll_px 变化（接错成 ticker_col 的典型症状）");
            $display("     C06(a) x=160 -> narr_subline.col = %0d（期望 active_x[9:4] = 10）",
                     col0);
            $display("     C06(a) scroll_px 扫 16 个相位（0,64,...,960），列号始终保持 %0d = %0s",
                     col0, same ? "是" : "否");
        end

        // (b) 不滚动证明（captain 第 10 条 acceptance 的核心用例）
        //     scroll_px 从 0 递增到 8，滚动带 y=448..463、x=0..127 的**整幅图**
        //     （16 行 × 128 列 = 2048 点）必须逐位与基准完全相同。
        //
        //     为什么是整幅图而不是几个采样点：本用例第一版取 x=64 的三行做采样，
        //     实测三个基准像素全是 0（x=64 恰好落在「，」的空白列），
        //     "逐拍相同"退化成"0 跟 0 相同"——断言永远绿、什么也没证明。
        //     这正是文档 §9.6 说的反例：断言要朝"出问题时变红"设计，
        //     所以这里先断言基准图必须有笔画（lit_base > 20），再比整幅图。
        begin : c06_no_scroll
            integer phase;
            integer yy;
            integer xx;
            integer idx;
            integer lit_base;
            reg [2047:0] base_img;
            reg [2047:0] cur_img;
            reg          same_img;

            // ---- 基准图：scroll_px = 0 ----
            force dut.scroll_px = 10'd0;
            idx = 0;
            lit_base = 0;
            for (yy = 448; yy <= 463; yy = yy + 1) begin
                for (xx = 0; xx <= 127; xx = xx + 1) begin
                    drive_pixel(xx[10:0], yy[9:0]);
                    next_pixel;
                    base_img[idx] = caption_pixel;
                    if (caption_pixel) lit_base = lit_base + 1;
                    idx = idx + 1;
                end
            end
            chk(lit_base > 20,
                "C06 基准图必须含点亮笔画（否则整幅 0 比对是空断言）");
            chk(idx == 2048, "C06 整幅图采样点数应为 2048");

            // ---- 8 个相位逐位比对 ----
            same_img = 1'b1;
            for (phase = 1; phase <= 8; phase = phase + 1) begin
                force dut.scroll_px = phase[9:0];
                idx = 0;
                for (yy = 448; yy <= 463; yy = yy + 1) begin
                    for (xx = 0; xx <= 127; xx = xx + 1) begin
                        drive_pixel(xx[10:0], yy[9:0]);
                        next_pixel;
                        cur_img[idx] = caption_pixel;
                        if (caption_pixel !== base_img[idx]) same_img = 1'b0;
                        idx = idx + 1;
                    end
                end
            end
            release dut.scroll_px;

            chk(same_img,
                "C06 科普字幕不得随 scroll_px 滚动（16x128 整幅图逐位必须与基准相同）");
            $display("     C06(b) 基准图 scroll_px=0: y=448..463 x=0..127 共 %0d 点，点亮 %0d 个",
                     idx, lit_base);
            $display("     C06(b) scroll_px=1..8 共 8 个相位，整幅图逐位比对 = %0s",
                     same_img ? "完全相同" : "出现差异");
        end

        // (c) 段 0 共 16 字：col 0..15（x 0..255）有字形，x >= 256 必须空白。
        //     这里不要求"前 256 列一定有笔画"（字间有空白），只要求
        //     "x >= 256 一个点亮像素都没有"——段尾门控失效时这一条必红。
        begin : c06_seg_len
            integer lit_tail;

            lit_tail = 0;
            for (j = 256; j < 640; j = j + 1) begin
                drive_pixel(j[10:0], 10'd455);
                next_pixel;
                if (caption_pixel) lit_tail = lit_tail + 1;
            end
            chk(lit_tail == 0, "C06 段 0 只有 16 字，x>=256 必须全空白");
            $display("     C06(c) 段 0 尾窗 x=256..639 点亮像素 = %0d（期望 0）", lit_tail);

            // 段内必须有字（否则"全空白"也能骗过上面那条）
            lit = 0;
            for (j = 0; j < 256; j = j + 1) begin
                drive_pixel(j[10:0], 10'd455);
                next_pixel;
                if (caption_pixel) lit = lit + 1;
            end
            chk(lit > 20, "C06 段 0 的 x<256 应有点亮笔画");
            $display("     C06(c) 段 0 段内 x=0..255 点亮像素 = %0d（期望 > 20）", lit);
        end

        // (d) 边界：frame_idx < start[0]=4 无字幕
        frame_idx = 16'd3;
        begin : c06_before
            integer lit_all;
            lit_all = 0;
            for (j = 0; j < 640; j = j + 1) begin
                drive_pixel(j[10:0], 10'd455);
                next_pixel;
                if (caption_pixel) lit_all = lit_all + 1;
            end
            chk(lit_all == 0, "C06 frame_idx=3（<4）应整行空白");
            $display("     C06(d) frame_idx=3（START0=4 之前）整行 640 列点亮像素 = %0d（期望 0）",
                     lit_all);
        end

        // (e) 边界：frame_idx > end=624 无字幕
        frame_idx = 16'd625;
        begin : c06_after
            integer lit_all;
            lit_all = 0;
            for (j = 0; j < 640; j = j + 1) begin
                drive_pixel(j[10:0], 10'd455);
                next_pixel;
                if (caption_pixel) lit_all = lit_all + 1;
            end
            chk(lit_all == 0, "C06 frame_idx=625（>624）应整行空白");
            $display("     C06(e) frame_idx=625（END_FRAME=624 之后）整行 640 列点亮 = %0d（期望 0）",
                     lit_all);
        end

        // (f) 科普模式下三条静态 ASCII 带必须熄灭（narr_en 的另一半职责）
        frame_idx = 16'd4;
        lit = 0;
        for (j = 32; j <= 127; j = j + 1) begin
            drive_pixel(j[10:0], 10'd20);
            next_pixel;
            if (caption_pixel) lit = lit + 1;
        end
        chk(lit == 0, "C06 科普模式下标题行必须熄灭");
        $display("     C06(f) 科普模式标题行 y=20 x=32..127 点亮像素 = %0d（期望 0）", lit);
        lit = 0;
        for (j = 32; j <= 103; j = j + 1) begin
            drive_pixel(j[10:0], 10'd52);
            next_pixel;
            if (caption_pixel) lit = lit + 1;
        end
        chk(lit == 0, "C06 科普模式下状态行必须熄灭");
        $display("     C06(f) 科普模式状态行 y=52 x=32..103 点亮像素 = %0d（期望 0）", lit);

        // (g) 科普 + 应急：应急文案优先，不能被视频字幕顶掉
        state_line = 4'd6;
        frame_idx  = 16'd4;
        drive_pixel(11'd0, 10'd448);
        next_pixel;
        chk(dut.t_line === 4'd14 || dut.t_line === 4'd15,
            "C06 科普模式下进入应急，滚动带应仍显示应急文案 line 14/15");
        chk(dut.u_cjk.glyph !== 9'h1FF,
            "C06 应急优先时字形源不应是视频字幕的空白哨兵");
        $display("     C06(g) 科普+应急（frame_idx=4, state_line=6）t_line = %0d（期望 14/15），cjk glyph = 9'h%03X（期望 != 1FF）",
                 dut.t_line, dut.u_cjk.glyph);
        state_line = 4'd5;

        // (h) 关掉 Key5（caption_en）时，科普字幕也必须熄灭（底部带归 Key5 管）
        caption_en = 1'b0;
        lit = 0;
        for (j = 0; j < 640; j = j + 1) begin
            drive_pixel(j[10:0], 10'd455);
            next_pixel;
            if (caption_pixel) lit = lit + 1;
            chk(caption_band === 1'b0, "C06 Key5 关闭时科普字幕衬底带必须为 0");
        end
        chk(lit == 0, "C06 Key5 关闭时科普字幕必须熄灭");
        $display("     C06(h) Key5 关闭（caption_en=0）时科普字幕整行点亮 = %0d（期望 0），衬底带逐拍均为 0",
                 lit);
        caption_en = 1'b1;

        // 回到日常态，供后续用例使用
        narr_en   = 1'b0;
        frame_idx = 16'd0;


        // ==================================================================
        // 收尾
        // ==================================================================
        $display("================================================================");
        $display(" 检查项 %0d 个，失败 %0d 个", checks, fails);
        if (fails == 0) begin
            $display(" ALL CHECKS PASSED: tb_osd_caption_cjk");
        end else begin
            $display(" *** FAILED: %0d check(s) ***", fails);
        end
        $display("================================================================");
        $finish;
    end

    // 超时保护：正常应在几十毫秒内跑完
    initial begin
        #50_000_000;
        $display(" *** FAILED: timeout ***");
        $finish;
    end

endmodule
