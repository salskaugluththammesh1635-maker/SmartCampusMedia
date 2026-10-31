// ============================================================================
// 文件名  : tb_osd_panel.v
// 所在位置: sim/testbench/tb_osd_panel.v
// 被测模块: rtl/osd/osd_panel.v
// ============================================================================
// 【验证策略】
//   osd_panel 是纯组合模块（无寄存器），验证重点是**像素级正确**：
//
//   1) 关面板时逐像素透传 —— 这是"基础功能不因扩展失效"的直接证据，
//      上板后关掉面板画面必须和改造前一模一样。
//   2) 开面板时面板外透传、边框是强调色、内部是暗色玻璃底。
//   3) 文字像素真的亮起来，且标题行与正文行颜色不同。
//   4) 内边距区**不能**出现文字色 —— 这是针对一个具体 bug 的回归：
//      t_x/t_y 是无条件减法，若 glyph_on 不与 in_text 相与，内边距会
//      越界命中字表，面板里凭空出现横线。
//   5) 消隐期（de=0）输出 0，与 video_overlay 的约定一致。
//
// 【期望值来源】
//   几何边界不写死数字，直接引用 DUT 的层次常量（u_dut.PANEL_X0 等）。
//   若将来改了 PANEL_X0/PAD/COLS，TB 自动跟随 —— 写死数字的 TB 会在
//   参数一改就集体失效，然后被人整体注释掉，等于没有测试。
//   文字像素的期望位置则来自字模 ROM 的实际点阵（'P' 的 row3 = 8'h7C，
//   即 .#####.. ，font_x=1 处为 1），这是独立于 osd_panel 实现的数据。
//
// 【断言编号】
//   P01 面板关闭：面板区域逐点透传
//   P02 面板关闭：整帧（含消隐）行为不变
//   P03 面板开启：边框四边为强调色
//   P04 面板开启：面板外像素透传（左/右/上/下各取一点）
//   P05 面板开启：内部底色 = (rgb_in>>2) + 24'h081018
//   P06 文字像素：标题行亮青、正文行淡白
//   P07 文字像素：字形空白列不亮（同一行相邻列对照）
//   P08 内边距区恒为底色（glyph_on 门控回归）
//   P09 消隐期输出 0
//   P10 几何自洽：边框把文字区完整包住
//   P11 面板覆盖优先于 rgb_in（内部即使 rgb_in 全白也不透出白）
// ============================================================================
`timescale 1ns / 1ps

module tb_osd_panel;

    localparam CLK_PERIOD = 40;   // 25 MHz，与 clk_pixel 一致

    reg         pixel_clk;
    reg         rst_n;
    reg         de;
    reg  [10:0] active_x;
    reg  [9:0]  active_y;
    reg  [23:0] rgb_in;
    reg         panel_on;
    reg  [2:0]  bright_sel;
    reg         invert_en;
    reg  [1:0]  auto_sw_sel;
    reg  [1:0]  info_mode;
    reg  [4:0]  img_index;
    reg  [4:0]  gallery_count;
    wire [23:0] rgb_out;

    osd_panel u_dut (
        .pixel_clk     (pixel_clk),
        .rst_n         (rst_n),
        .de            (de),
        .active_x      (active_x),
        .active_y      (active_y),
        .rgb_in        (rgb_in),
        .panel_on      (panel_on),
        .bright_sel    (bright_sel),
        .invert_en     (invert_en),
        .auto_sw_sel   (auto_sw_sel),
        .info_mode     (info_mode),
        .img_index     (img_index),
        .gallery_count (gallery_count),
        .rgb_out       (rgb_out)
    );

    integer pass_cnt;
    integer fail_cnt;

    // ---- 颜色常量（与模块内一致；颜色是"设计决定"，不是推导值，故写死）----
    localparam [23:0] C_BORDER = 24'h40_E0_D0;
    localparam [23:0] C_TITLE  = 24'h40_E0_D0;
    localparam [23:0] C_BODY   = 24'hD0_D0_D0;

    // ---- 几何：引用 DUT 的层次常量，参数一改自动跟随 --------------------
    localparam [10:0] PX0 = u_dut.PANEL_X0;
    localparam [9:0]  PY0 = u_dut.PANEL_Y0;
    localparam [10:0] PX1 = u_dut.PANEL_X1;
    localparam [9:0]  PY1 = u_dut.PANEL_Y1;
    localparam [10:0] TX0 = u_dut.TEXT_X0;
    localparam [9:0]  TY0 = u_dut.TEXT_Y0;
    localparam [10:0] TX1 = u_dut.TEXT_X1;
    localparam [9:0]  TY1 = u_dut.TEXT_Y1;

    // 测试用的图像色：选一个三通道都非零、便于手算的值
    //   dim_bg = (24'h80C040 >> 2) + 24'h081018
    //          = 24'h203010 + 24'h081018 = 24'h284028
    localparam [23:0] IMG_A    = 24'h80_C0_40;
    localparam [23:0] IMG_A_DIM = 24'h28_40_28;

    initial pixel_clk = 1'b0;
    always #(CLK_PERIOD/2) pixel_clk = ~pixel_clk;

    // ---- 通用检查 ------------------------------------------------------
    task chk;
        input        cond;
        input [8*64-1:0] tag;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", tag);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", tag);
            end
        end
    endtask

    // 设置一个像素坐标并等待组合逻辑稳定
    task at;
        input [10:0] x;
        input [9:0]  y;
        begin
            active_x = x;
            active_y = y;
            #1;
        end
    endtask

    // 检查某点 rgb_out 等于期望值
    task chk_px;
        input [10:0] x;
        input [9:0]  y;
        input [23:0] expect;
        input [8*64-1:0] tag;
        begin
            at(x, y);
            if (rgb_out === expect) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s at (%0d,%0d) = %06h", tag, x, y, expect);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s at (%0d,%0d) expected %06h got %06h",
                         tag, x, y, expect, rgb_out);
            end
        end
    endtask

    // 检查某点透传（rgb_out == rgb_in）
    task chk_pass;
        input [10:0] x;
        input [9:0]  y;
        input [8*64-1:0] tag;
        begin
            at(x, y);
            if (rgb_out === rgb_in) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s at (%0d,%0d) passthrough", tag, x, y);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s at (%0d,%0d) not passthrough: in=%06h out=%06h",
                         tag, x, y, rgb_in, rgb_out);
            end
        end
    endtask

    integer i;
    integer nx, ny;

    initial begin
        pass_cnt      = 0;
        fail_cnt      = 0;
        rst_n         = 1'b0;
        de            = 1'b1;
        active_x      = 11'd0;
        active_y      = 10'd0;
        rgb_in        = IMG_A;
        panel_on      = 1'b0;
        bright_sel    = 3'd0;
        invert_en     = 1'b0;
        auto_sw_sel   = 2'd0;
        info_mode     = 2'd0;
        img_index     = 5'd0;
        gallery_count = 5'd0;
        #(CLK_PERIOD * 2);
        rst_n = 1'b1;
        #(CLK_PERIOD);

        // ================= P10 几何自洽（先查，后面的断言依赖它）=========
        // 边框必须完整包住文字区：PX0 < TX0 <= TX1 < PX1，四边同理。
        chk((PX0 < TX0) && (TX1 < PX1) && (PY0 < TY0) && (TY1 < PY1),
            "P10a border encloses text area");
        // 文字区尺寸必须正好是 22 列 x 8 像素 与 3 行 x 16 像素
        chk((TX1 - TX0 + 1) == 11'd176, "P10b text width = 22*8 = 176");
        chk((TY1 - TY0 + 1) == 10'd48,  "P10c text height = 3*16 = 48");
        // 面板右边距屏幕右边缘 8 像素（与信息条左边距 8 对称）
        chk((11'd639 - PX1) == 11'd8,   "P10d right margin = 8 px");
        // 面板必须避开九宫格竖线 x=213/426 与横线 y=160/320
        chk((PX0 > 11'd426),            "P10e panel clear of grid line x=426");
        chk((PY1 < 10'd160),            "P10f panel clear of grid line y=160");

        // ================= P01/P02 面板关闭：完全透传 ======================
        panel_on = 1'b0;
        // 面板区域内取 9 个点，全部应透传
        for (i = 0; i < 9; i = i + 1) begin
            nx = PX0 + ((PX1 - PX0) * i) / 8;
            ny = PY0 + ((PY1 - PY0) * i) / 8;
            chk_pass(nx[10:0], ny[9:0], "P01 panel off passthrough");
        end
        // 整帧抽查：四角与中心
        chk_pass(11'd0,   10'd0,   "P02a frame corner (0,0)");
        chk_pass(11'd639, 10'd0,   "P02b frame corner (639,0)");
        chk_pass(11'd0,   10'd479, "P02c frame corner (0,479)");
        chk_pass(11'd639, 10'd479, "P02d frame corner (639,479)");
        chk_pass(11'd320, 10'd240, "P02e frame center");

        // ================= P03 面板开启：边框 ==============================
        panel_on = 1'b1;
        chk_px(PX0, PY0, C_BORDER, "P03a top-left corner");
        chk_px(PX1, PY0, C_BORDER, "P03b top-right corner");
        chk_px(PX0, PY1, C_BORDER, "P03c bottom-left corner");
        chk_px(PX1, PY1, C_BORDER, "P03d bottom-right corner");
        // 四边中点
        chk_px((PX0 + PX1) / 2, PY0, C_BORDER, "P03e top edge middle");
        chk_px((PX0 + PX1) / 2, PY1, C_BORDER, "P03f bottom edge middle");
        chk_px(PX0, (PY0 + PY1) / 2, C_BORDER, "P03g left edge middle");
        chk_px(PX1, (PY0 + PY1) / 2, C_BORDER, "P03h right edge middle");

        // ================= P04 面板开启：面板外透传 ========================
        chk_pass(PX0 - 11'd1, (PY0 + PY1) / 2, "P04a one px left of panel");
        chk_pass(PX1 + 11'd1, (PY0 + PY1) / 2, "P04b one px right of panel");
        chk_pass((PX0 + PX1) / 2, PY0 - 10'd1, "P04c one px above panel");
        chk_pass((PX0 + PX1) / 2, PY1 + 10'd1, "P04d one px below panel");
        // 远离面板的九宫格线位置也必须透传（面板不能影响别处）
        chk_pass(11'd213, 10'd240, "P04e grid line x=213 untouched");
        chk_pass(11'd426, 10'd240, "P04f grid line x=426 untouched");

        // ================= P05 面板开启：内部底色 ==========================
        // 取文字区的"空白处"：line2 的 col 12 是空格（"MODE:NORMAL  IMG" 里
        // 第 12 列是补位空格），整列 16 行都不该有字。
        nx = TX0 + 12 * 8 + 4;   // col 12 中间
        ny = TY0 + 2 * 16 + 8;   // line 2 中间
        chk_px(nx[10:0], ny[9:0], IMG_A_DIM, "P05a dim bg at blank cell (line2 col12)");
        // 内边距区（左边 447..450）
        chk_px(PX0 + 11'd2, PY0 + 10'd20, IMG_A_DIM, "P05b dim bg in left padding");
        // 内边距区（上方 9..12）
        chk_px(PX0 + 11'd60, PY0 + 10'd2, IMG_A_DIM, "P05c dim bg in top padding");
        // 内边距区（下方 61..64）
        chk_px(PX0 + 11'd60, PY1 - 10'd2, IMG_A_DIM, "P05d dim bg in bottom padding");
        // 内边距区（右边）
        chk_px(PX1 - 11'd2, PY0 + 10'd20, IMG_A_DIM, "P05e dim bg in right padding");

        // 换一个图像色，验证底色公式（全白 -> 24'h474F57）
        rgb_in = 24'hFF_FF_FF;
        chk_px(nx[10:0], ny[9:0], 24'h47_4F_57, "P05f dim bg formula on white");
        rgb_in = 24'h00_00_00;
        chk_px(nx[10:0], ny[9:0], 24'h08_10_18, "P05g dim bg formula on black");
        rgb_in = IMG_A;

        // ================= P06/P07 文字像素 ================================
        // 'P' (line0 col0) 的 row3 = 8'h7C = .#####..，font_x=1 处为 1。
        //   坐标 x = TX0 + 0*8 + 1, y = TY0 + 0*16 + 3
        chk_px(TX0 + 11'd1, TY0 + 10'd3, C_TITLE, "P06a 'P' lit pixel -> title color");
        // font_x=0 处为 0（0x7C 的 bit7 = 0），应仍是底色
        chk_px(TX0 + 11'd0, TY0 + 10'd3, IMG_A_DIM, "P07a 'P' blank column -> bg");
        // font_x=6/7 处为 0（0x7C 的 bit1/bit0 = 0）
        chk_px(TX0 + 11'd6, TY0 + 10'd3, IMG_A_DIM, "P07b 'P' blank col 6 -> bg");
        chk_px(TX0 + 11'd7, TY0 + 10'd3, IMG_A_DIM, "P07c 'P' blank col 7 -> bg");
        // row 0..2 全 0（字形从 row3 开始），标题首格上方应是底色
        chk_px(TX0 + 11'd1, TY0 + 10'd0, IMG_A_DIM, "P07d above glyph -> bg");
        chk_px(TX0 + 11'd1, TY0 + 10'd2, IMG_A_DIM, "P07e above glyph row2 -> bg");

        // 'B' (line1 col0) 的 row3 = 8'h7C，font_x=1 处为 1，正文色。
        //   坐标 x = TX0 + 1, y = TY0 + 16 + 3
        chk_px(TX0 + 11'd1, TY0 + 10'd19, C_BODY, "P06b 'B' lit pixel -> body color");
        // 标题色与正文色必须不同，否则"标题行"没有视觉区分
        chk(C_TITLE != C_BODY, "P06c title color differs from body color");

        // ================= P08 内边距无文字（glyph_on 门控回归）==========
        // 扫描左右内边距与上下内边距的全部像素，要求**恒等于底色**。
        // 这一条专门盯 t_x/t_y 越界命中字表的 bug：若 glyph_on 漏了
        // in_text 门控，内边距会出现几条横线（文字色）。
        //
        // 判定用"等于底色"而不是"不等于文字色"：标题色 C_TITLE 与边框色
        // C_BORDER 是同一种强调色（整个 OSD 只有一套强调色），用"不等于
        // 文字色"会把边框像素误判成文字 —— 首版就是这么挂的。
        // 扫描范围也避开边框那一行/列（PY0、PY1、PX0、PX1），只扫真正的
        // 内边距：横向 y ∈ [PY0+1, PY1-1]，纵向 x ∈ [PX0+1, PX1-1]。
        nx = 0;
        ny = 0;
        for (i = PY0 + 1; i < PY1; i = i + 1) begin
            at(TX0 - 11'd1, i[9:0]);            // 左内边距
            if (rgb_out !== IMG_A_DIM) nx = nx + 1;
            at(TX1 + 11'd1, i[9:0]);            // 右内边距
            if (rgb_out !== IMG_A_DIM) nx = nx + 1;
            ny = ny + 2;
        end
        for (i = PX0 + 1; i < PX1; i = i + 1) begin
            at(i[10:0], TY0 - 10'd1);           // 上内边距
            if (rgb_out !== IMG_A_DIM) nx = nx + 1;
            at(i[10:0], TY1 + 10'd1);           // 下内边距
            if (rgb_out !== IMG_A_DIM) nx = nx + 1;
            ny = ny + 2;
        end
        chk(nx == 0, "P08 no text color anywhere in padding");
        $display("      P08 scanned %0d padding pixels on 4 sides, %0d not bg",
                 ny, nx);

        // ================= P11 面板优先于图像 ==============================
        // 面板内部即使 rgb_in 全白，也不该透出白色（只能看到暗底或文字色）
        rgb_in = 24'hFF_FF_FF;
        chk_px(TX0 + 11'd0, TY0 + 10'd3, 24'h47_4F_57, "P11a white img dimmed inside panel");
        chk_px(PX0, PY0, C_BORDER, "P11b border unaffected by white img");
        rgb_in = IMG_A;

        // ================= P09 消隐期 ======================================
        de = 1'b0;
        chk_px(11'd0,   10'd0,   24'd0, "P09a blanking outputs 0");
        chk_px(11'd320, 10'd240, 24'd0, "P09b blanking outputs 0 (center)");
        chk_px(PX0,     PY0,     24'd0, "P09c blanking outputs 0 (panel corner)");
        de = 1'b1;

        // ================= 汇总 ============================================
        $display("");
        $display("--------------------------------------------------");
        $display("tb_osd_panel: %0d checks passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: osd_panel");
        end else begin
            $display("CHECKS FAILED: osd_panel");
        end
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
