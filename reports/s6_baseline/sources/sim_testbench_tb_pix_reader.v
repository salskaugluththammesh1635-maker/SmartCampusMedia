// =============================================================================
//  tb_pix_reader.v  ——  pix_reader 的仿真验证
// =============================================================================
// 【被测范围】
//
//   pix_reader + async_fifo + framebuf_arbiter + sdram_ctrl_wrap(行为模型)
//
//   即整条"帧缓冲 → 像素输出"链路，只把 HDMI 侧的 video_timing_gen 换成
//   本文件的简化时序模型（只需 de / active_y，其余消隐细节与验证目标无关）。
//
// 【为什么要把 framebuf_arbiter 一起拉进来】
//
//   pix_reader 的 rd_req 语义（"一个请求换一个字"、"组会自动补完 4 拍"）
//   完全由仲裁器定义。若只对 pix_reader 打桩，桩本身写错就会掩盖真问题 ——
//   这正是 S5-2 变异测试里 m4/m9 存活教训的反向应用：接口两端的理解必须
//   由真实实现来交叉验证，而不是由测试者的假设来对齐。
//
// 【HDMI 时序模型 · 关键约定：连续扫描，永不停止】
//
//   640x480 @ 25MHz 的典型 VESA 参数（与 video_timing_gen 一致）：
//     H: 640 有效 + 16 前肩 + 96 同步 + 48 后肩 = 800 拍/行
//     V: 480 有效 + 10 前肩 + 2  同步 + 33 后肩 = 525 行/帧
//
//   ★ 早期版本用 scan_run 把扫描切成一段一段（每段之间把 de 拉低停止消费），
//     这是本文件踩过的最大的 tb 坑：pix_reader 是**自由流 + 水位背压**架构，
//     150MHz 侧只要水位没到 LEVEL_HI 就会一直读。停掉 de 只是停掉*消费*，
//     写侧照样把 FIFO 灌满 384 字；恢复扫描时 DUT 的读指针仍在帧中间，
//     而输出的却是帧首的字 → 整段错位，且错位量随停顿时长变化。
//     真实 HDMI 是连续扫描、永不停止，所以本文件**不使用** scan_run 门控，
//     h_cnt / v_cnt 从复位释放起就一直自由推进。
//
// 【校验窗口的切换点：必须落在消隐期】
//
//   比对开关 check_en 的所有切换都发生在 v_cnt == LINES（消隐期首行）那几拍，
//   此时 de 恒为 0，initial 块与 always 块之间不存在采样竞争；
//   若在帧首拍切换，会与 de 的第一拍抢同一个 posedge，逐像素比对必然漏拍。
//
// 【校验点（每项只守护一个性质，互不掩盖）】
//
//   T01 单帧逐像素比对（480x640 全部比对）
//        图案 {6'd0, x[5:0], y[9:0]}：列错抓高位、行错抓低位、行列互换必错、
//        相邻像素必然不同（不会因为取到邻居而"碰巧通过"）。
//        守护: 数据通路 + 字序(低半字偶像素/高半字奇像素) + 像素相位
//   T02 连续 3 帧、图案逐帧整体偏移
//        守护: 每帧帧对齐真的发生（若用了上一帧的残留字，行值必然对不上）
//   T03 图案只随行号变化（同一行 640 个像素同值）
//        守护: 行地址计算 / 行边界不漂移（列无关，因此不会掩盖列方向的问题，
//              也不会被列方向的问题掩盖 —— 一次只测一个性质）
//   T04 帧内瞬态复位（rst_n_pix 掉 5 拍）后，下一帧必须完全自愈
//        守护: RTL 文件头 §三(c) 宣称的"任何瞬时错误最多影响当前帧"
//   T05 整帧读请求数严格
//        守护: 不多读不少读。38400 组(整帧) + 消隐期被 flush 丢弃需重读的
//              预填组。区间由架构决定，不是拍脑袋放宽（详见断言处注释）
//   T06 de 有效期内 underflow / overflow 均不应发生
//   T07 全链冷复位（rst_n_sdr + rst_n_pix 同时）后重新建立帧对齐
// =============================================================================
`timescale 1ns / 1ps

module tb_pix_reader;

    // -------------------------------------------------------------------------
    // 时钟与复位
    // -------------------------------------------------------------------------
    localparam real CLK_SDR_PERIOD = 6.667;   // 150MHz
    localparam real CLK_PIX_PERIOD = 40.0;    // 25MHz

    reg clk_sdr = 1'b0;
    reg clk_pix = 1'b0;
    reg rst_n_sdr = 1'b0;
    reg rst_n_pix = 1'b0;

    always #(CLK_SDR_PERIOD/2.0) clk_sdr = ~clk_sdr;
    always #(CLK_PIX_PERIOD/2.0) clk_pix = ~clk_pix;

    // -------------------------------------------------------------------------
    // 参数
    // -------------------------------------------------------------------------
    localparam ADDR_WIDTH   = 21;
    localparam FRAME_BASE   = 21'd0;
    localparam PIX_PER_LINE = 640;
    localparam Y_WIDTH      = 10;
    localparam FIFO_AW      = 9;
    localparam WORDS_LINE   = PIX_PER_LINE / 2;      // 320
    localparam LINES        = 480;

    localparam H_TOTAL      = 800;
    localparam H_DE         = 640;
    localparam V_TOTAL      = 525;

    localparam FRAME_WORDS  = LINES * WORDS_LINE;    // 153600
    localparam GRP_LINE     = WORDS_LINE / 4;        // 80 组/行
    localparam GRP_FRAME    = LINES * GRP_LINE;      // 38400 组/帧
    localparam LEVEL_HI     = 384;                   // 与 pix_reader 参数一致
    localparam GUARD        = 3000000;               // 所有裸 while 的上限

    // -------------------------------------------------------------------------
    // 计数与统计
    // -------------------------------------------------------------------------
    integer checks = 0;
    integer fails  = 0;
    integer wt_g;                    // 裸 while 的 guard 计数器（task 内不许带初值）

    task chk;
        input cond;
        input [767:0] msg;
        begin
            checks = checks + 1;
            if (cond) begin
                $display("  PASS: %0s", msg);
            end else begin
                fails = fails + 1;
                $display("  FAIL: %0s", msg);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // DUT 互连
    // -------------------------------------------------------------------------
    wire        rd_req;
    wire [31:0] rd_data;
    wire        rd_valid;
    wire        rd_ack;
    wire        arb_rd_restart;
    wire [20:0] arb_rd_base;

    wire [15:0] pix_rgb565;
    wire        pix_valid;
    wire [2:0]  stat;

    // HDMI 时序模型产生的 de / active_y（必须在例化之前声明）
    wire        de;
    wire [Y_WIDTH-1:0] active_y;

    // SDRAM 控制器互连
    wire        sdr_init_done;
    wire        ref_vld;
    wire        sdr_busy;
    wire        app_wr_en;
    wire [ADDR_WIDTH-1:0] app_wr_addr;
    wire [31:0] app_wr_din;
    wire [3:0]  app_wr_dm;
    wire        app_rd_en;
    wire [ADDR_WIDTH-1:0] app_rd_addr;
    wire        sdr_rd_en;
    wire [31:0] sdr_rd_dout;
    wire        arb_wr_ack;
    wire        arb_busy;
    wire        arb_err;

    // -------------------------------------------------------------------------
    // 时钟与复位生成
    // -------------------------------------------------------------------------
    // ★ 必须带位宽：无位宽 localparam 做 [7:0] 位选在不同工具下行为不一，
    //   ModelSim 下会得到 0，pll_cnt 于是停在 0、rst_n 恒低、init_done 永不置位。
    localparam [7:0] PLL_LOCK_CYCLES = 8'd128;
    reg [7:0] pll_cnt = 8'd0;        // 控制器复位延迟计数（须先声明，下面例化要用）

    initial begin
        rst_n_sdr = 1'b0;
        rst_n_pix = 1'b0;
        repeat (20) @(posedge clk_sdr);
        rst_n_sdr = 1'b1;
        repeat (20) @(posedge clk_pix);
        rst_n_pix = 1'b1;
    end

    // -------------------------------------------------------------------------
    // SDRAM 控制器（含行为模型）
    //   ★ 编译时必须带 +define+SDRAM_SIM_MODEL，否则会去找加密核 sdr_as_ram
    // -------------------------------------------------------------------------
    sdram_ctrl_wrap #(
        .CLK_FREQ_HZ    (150_000_000),
        .SIM_MEM_WORDS  (262_144),
        .REFRESH_PERIOD (1_000_000)     // 大幅稀疏化，避免刷新干扰逐像素比对
    ) u_ctrl (
        .clk         (clk_sdr),
        .clk_sft     (clk_sdr),
        .rst_n       (rst_n_sdr & (pll_cnt == PLL_LOCK_CYCLES)),
        .init_done   (sdr_init_done),
        .ref_vld     (ref_vld),
        .busy        (sdr_busy),
        .app_wr_en   (app_wr_en),
        .app_wr_addr (app_wr_addr),
        .app_wr_din  (app_wr_din),
        .app_wr_dm   (app_wr_dm),
        .app_rd_en   (app_rd_en),
        .app_rd_addr (app_rd_addr),
        .sdr_rd_en   (sdr_rd_en),
        .sdr_rd_dout (sdr_rd_dout),
        .sdram_clk   (),
        .sdram_cke   (),
        .sdram_cs_n  (),
        .sdram_ras_n (),
        .sdram_cas_n (),
        .sdram_we_n  (),
        .sdram_ba    (),
        .sdram_addr  (),
        .sdram_dm    (),
        .sdram_dq    ()
    );

    // 控制器复位延迟计数（等 PLL 锁定）
    always @(posedge clk_sdr) begin
        if (pll_cnt != PLL_LOCK_CYCLES) pll_cnt <= pll_cnt + 8'd1;
    end

    // -------------------------------------------------------------------------
    // 仲裁器
    // -------------------------------------------------------------------------
    framebuf_arbiter #(
        .ADDR_WIDTH   (ADDR_WIDTH),
        .FRAME_BASE   (FRAME_BASE),
        .FRAME_WORDS  (18'd153600)      // 640*480/2
    ) u_arb (
        .clk           (clk_sdr),
        .rst_n         (rst_n_sdr),
        .sdr_init_done (sdr_init_done),
        .ref_vld       (ref_vld),
        .wr_req        (1'b0),
        .wr_data       (32'd0),
        .wr_dm         (4'h0),
        .wr_ack        (arb_wr_ack),
        .rd_req        (rd_req),
        .rd_data       (rd_data),
        .rd_valid      (rd_valid),
        .rd_ack        (rd_ack),
        .rd_restart    (arb_rd_restart),
        .rd_base       (arb_rd_base),
        .app_wr_en     (app_wr_en),
        .app_wr_addr   (app_wr_addr),
        .app_wr_din    (app_wr_din),
        .app_wr_dm     (app_wr_dm),
        .app_rd_en     (app_rd_en),
        .app_rd_addr   (app_rd_addr),
        .sdr_rd_en     (sdr_rd_en),
        .sdr_rd_dout   (sdr_rd_dout),
        .busy          (arb_busy),
        .err           (arb_err)
    );

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    pix_reader #(
        .ADDR_WIDTH   (ADDR_WIDTH),
        .FRAME_BASE   (FRAME_BASE),
        .PIX_PER_LINE (PIX_PER_LINE),
        .Y_WIDTH      (Y_WIDTH),
        .FIFO_AW      (FIFO_AW),
        .LEVEL_HI     (LEVEL_HI)
    ) dut (
        .clk_sdr    (clk_sdr),
        .rst_n_sdr  (rst_n_sdr),
        .rd_req     (rd_req),
        .rd_data    (rd_data),
        .rd_valid   (rd_valid),
        .rd_ack     (rd_ack),
        .rd_restart (arb_rd_restart),
        .rd_base    (arb_rd_base),
        .pix_clk    (clk_pix),
        .rst_n_pix  (rst_n_pix),
        .de         (de),
        .active_y   (active_y),
        .pix_rgb565 (pix_rgb565),
        .pix_valid  (pix_valid),
        .stat       (stat)
    );

    // -------------------------------------------------------------------------
    // HDMI 时序模型（连续扫描）
    // -------------------------------------------------------------------------
    reg  [9:0] h_cnt = 10'd0;
    reg  [9:0] v_cnt = 10'd0;

    always @(posedge clk_pix) begin
        if (!rst_n_pix) begin
            h_cnt <= 10'd0;
            v_cnt <= 10'd0;
        end else if (h_cnt == H_TOTAL - 1) begin
            h_cnt <= 10'd0;
            if (v_cnt == V_TOTAL - 1) v_cnt <= 10'd0;
            else                      v_cnt <= v_cnt + 10'd1;
        end else begin
            h_cnt <= h_cnt + 10'd1;
        end
    end

    assign de       = (h_cnt < H_DE) && (v_cnt < LINES);
    assign active_y = v_cnt;

    // -------------------------------------------------------------------------
    // 帧缓冲图案
    //   pat_row_only = 0 : 像素 (x,y) = {6'd0, x[5:0], y[9:0]+pat_off}
    //   pat_row_only = 1 : 像素 (x,y) = {6'd0, 6'd0,  y[9:0]+pat_off}   仅随行号
    //   一个 32bit 字装 2 个像素：[15:0]=偶像素(2*xx)  [31:16]=奇像素(2*xx+1)
    // -------------------------------------------------------------------------
    reg        pat_row_only = 1'b0;
    reg [9:0]  pat_off      = 10'd0;

    function [15:0] pix_val;
        input integer x;
        input integer y;
        reg [9:0] yv;
        begin
            yv = y[9:0] + pat_off;
            if (pat_row_only) pix_val = {6'd0, 6'd0, yv};
            else              pix_val = {6'd0, x[5:0], yv};
        end
    endfunction

    // 期望像素值（与 pix_val 同源，避免两处独立推导产生偏差）
    function [15:0] exp_pix;
        input integer x;
        input integer y;
        begin
            exp_pix = pix_val(x, y);
        end
    endfunction

    task fill_frame;
        integer yy, xx, widx;
        reg [31:0] w;
        begin
            for (yy = 0; yy < LINES; yy = yy + 1) begin
                for (xx = 0; xx < WORDS_LINE; xx = xx + 1) begin
                    widx = FRAME_BASE + yy * WORDS_LINE + xx;
                    w[15:0]  = pix_val(2*xx,     yy);
                    w[31:16] = pix_val(2*xx + 1, yy);
                    u_ctrl.u_model.mem[widx] = w;
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 逐像素比对
    //   用 h_cnt 作 x 坐标、v_cnt 作 y 坐标，而不是自己数 pix_valid ——
    //   后者一旦丢拍就会整行平移，掩盖"少一个像素"这类问题。
    // -------------------------------------------------------------------------
    reg         check_en = 1'b0;
    integer     t_checks = 0;
    integer     t_fails  = 0;
    integer     first_bad_x = -1;
    integer     first_bad_y = -1;
    reg [15:0]  first_bad_got;
    reg [15:0]  first_bad_exp;

    always @(posedge clk_pix) begin
        if (rst_n_pix && check_en && de) begin
            t_checks = t_checks + 1;
            if (!pix_valid) begin
                t_fails = t_fails + 1;
                if (first_bad_x < 0) begin
                    first_bad_x   = h_cnt;
                    first_bad_y   = v_cnt;
                    first_bad_got = 16'hDEAD;
                    first_bad_exp = exp_pix(h_cnt, v_cnt);
                end
            end else if (pix_rgb565 !== exp_pix(h_cnt, v_cnt)) begin
                t_fails = t_fails + 1;
                if (first_bad_x < 0) begin
                    first_bad_x   = h_cnt;
                    first_bad_y   = v_cnt;
                    first_bad_got = pix_rgb565;
                    first_bad_exp = exp_pix(h_cnt, v_cnt);
                end
            end
        end
    end

    // DUT 发出的新突发组数（rd_ack 是新组启动脉冲；不能用 rd_valid 数字数）
    integer rd_reqs = 0;
    always @(posedge clk_sdr) begin
        if (rst_n_sdr && rd_ack) rd_reqs = rd_reqs + 1;
    end

    // 帧内 FIFO 水位峰值（用于 T05/T06 的背压检查）
    integer lvl_peak = 0;
    always @(posedge clk_sdr) begin
        if (rst_n_sdr && check_en) begin
            if (dut.level > lvl_peak) lvl_peak = dut.level;
        end
    end

    // -------------------------------------------------------------------------
    // 辅助 task
    // -------------------------------------------------------------------------
    task clear_stats;
        begin
            t_checks = 0;
            t_fails  = 0;
            first_bad_x = -1;
            first_bad_y = -1;
            rd_reqs  = 0;
            lvl_peak = 0;
        end
    endtask

    task report_stats;
        input [511:0] label;
        begin
            $display("  %0s: pixels=%0d mismatches=%0d rd_reqs=%0d level_peak=%0d",
                     label, t_checks, t_fails, rd_reqs, lvl_peak);
            if (first_bad_x >= 0)
                $display("     first bad at (x=%0d,y=%0d) got=%04h exp=%04h",
                         first_bad_x, first_bad_y, first_bad_got, first_bad_exp);
        end
    endtask

    // 等消隐期首行首拍，返回时已越过该拍（保证连续两次调用不会立即命中）
    task wait_blank;
        begin
            wt_g = 0;
            @(posedge clk_pix);
            while (!(v_cnt == LINES && h_cnt == 10'd0) && wt_g < GUARD) begin
                @(posedge clk_pix); wt_g = wt_g + 1;
            end
            if (wt_g >= GUARD) begin
                fails = fails + 1;
                $display("#   FAIL: guard timeout in wait_blank");
            end
        end
    endtask

    // 打开/关闭比对窗口。必须在消隐期调用（de==0，无采样竞争）
    task win_open;
        begin
            wait_blank;
            clear_stats;
            check_en = 1'b1;
        end
    endtask

    task win_close;
        begin
            wait_blank;
            check_en = 1'b0;
        end
    endtask

    task wait_init;
        integer k;
        begin
            k = 0;
            while (pll_cnt != PLL_LOCK_CYCLES && k < 100000) begin @(posedge clk_sdr); k = k + 1; end
            k = 0;
            while (sdr_init_done !== 1'b1 && k < 200000) begin @(posedge clk_sdr); k = k + 1; end
            chk(sdr_init_done === 1'b1, "SDRAM controller initialized");
        end
    endtask

    // -------------------------------------------------------------------------
    // 主流程
    // -------------------------------------------------------------------------
    integer i;
    integer n;

    initial begin
        $display("\n===== tb_pix_reader: 帧缓冲 -> 像素输出 =====");

        wait_init;

        // =====================================================================
        // T01 单帧逐像素比对
        // =====================================================================
        $display("\n-- T01 单帧逐像素比对 --");
        pat_row_only = 1'b0;
        pat_off      = 10'd0;
        fill_frame;


        // 预热两帧：让首次帧对齐完成、FIFO 进入稳态（第一帧之前没有对齐基准）
        wait_blank;
        wait_blank;
        win_open;
        win_close;
        $display("[STAT] de_cnt=%0d empty_hi=%0d rd_cnt=%0d wr_cnt=%0d", de_cnt, empty_hi, dut.rd_cnt, dut.wr_cnt);
        report_stats("T01");
        chk(t_checks == LINES * H_DE, "T01 覆盖 480x640 全部像素");
        chk(t_fails  == 0,            "T01 逐像素全部匹配");

        // =====================================================================
        // T02 连续 3 帧、图案逐帧整体偏移
        //   若某帧没有真正重对齐（沿用上一帧残留字），行值会差 pat_off 的增量
        // =====================================================================
        $display("\n-- T02 连续 3 帧内容变化 --");
        for (i = 0; i < 3; i = i + 1) begin
            pat_row_only = 1'b0;
            pat_off      = 10'd7 * (i + 1);
            // 图案必须在消隐期改：改完要等下一次帧对齐后才被消费
            wait_blank;
            fill_frame;
            check_en = 1'b1;
            wait_blank;
            check_en = 1'b0;
            report_stats("T02");
            chk(t_fails == 0, "T02 帧内逐像素匹配");
            clear_stats;
        end

        // =====================================================================
        // T03 行地址隔离：图案只随行号变化
        //   同一行 640 个像素同值 -> 列方向的问题不会掩盖行方向的问题
        // =====================================================================
        $display("\n-- T03 行地址隔离 --");
        pat_row_only = 1'b1;
        pat_off      = 10'd0;
        wait_blank;
        fill_frame;
        win_open;
        win_close;
        report_stats("T03");
        chk(t_checks == LINES * H_DE, "T03 覆盖 480x640 全部像素");
        chk(t_fails  == 0,            "T03 行地址定位正确");

        // =====================================================================
        // T04 帧内瞬态复位后自愈
        //   RTL 文件头 §三(c) 宣称"任何瞬时错误最多影响当前帧"，
        //   这里直接把 pix 侧复位掉 5 拍来制造错位，下一帧必须逐像素全对
        // =====================================================================
        $display("\n-- T04 帧内瞬态复位后自愈 --");
        pat_row_only = 1'b0;
        pat_off      = 10'd3;
        wait_blank;
        fill_frame;
        // 跑到帧中间再复位，制造最大错位
        wt_g = 0;
        while (!(v_cnt == LINES / 2) && wt_g < GUARD) begin
            @(posedge clk_pix); wt_g = wt_g + 1;
        end
        rst_n_pix = 1'b0;
        repeat (5) @(posedge clk_pix);
        rst_n_pix = 1'b1;
        // 帧起点已被复位打乱，等两次消隐期让对齐重新建立
        wait_blank;
        wait_blank;
        win_open;
        win_close;
        report_stats("T04");
        chk(t_checks == LINES * H_DE, "T04 复位后覆盖 480x640 全部像素");
        chk(t_fails  == 0,            "T04 瞬态复位后下一帧完全自愈");

        // =====================================================================
        // T05 整帧读请求数严格
        //   每帧必须读满整帧 = 38400 组。此外消隐期帧对齐会把 FIFO 里残留的
        //   预填字全部丢弃，这些字必须重读：残留上限 = LEVEL_HI + 在飞余量
        //   = 384 + 60 = 444 字 = 111 组，下限 = 384/4 = 96 组。
        //   因此合法区间是 [38400+96, 38400+111] 组，留 8 组同步余量 ->
        //   [38496, 38519]。"不多读"这一侧被上界严格锁死。
        // =====================================================================
        $display("\n-- T05 整帧读请求数 --");
        pat_row_only = 1'b0;
        pat_off      = 10'd0;
        wait_blank;
        fill_frame;
        win_open;
        win_close;
        report_stats("T05");
        chk(rd_reqs >= GRP_FRAME + 96 && rd_reqs <= GRP_FRAME + 111 + 8,
            "T05 整帧读请求数 = 38400 + 预填重读(96..119) 组");
        chk(lvl_peak <= LEVEL_HI + 60,
            "T05 水位背压生效：level 峰值不超过 LEVEL_HI + 在飞余量");

        // =====================================================================
        // T06 underflow / overflow（全程粘滞标志必须为 0）
        //   ★ 原 tb 这里查 stat[2]，而 RTL 里 stat[2] 是常量 0，恒真、不守护
        //     任何性质；改为查 stat[1]=overflow_lat（真实寄存器）。
        // =====================================================================
        $display("\n-- T06 underflow / overflow --");
        chk(stat[0] == 1'b0, "T06 全程无 underflow");
        chk(stat[1] == 1'b0, "T06 全程无 overflow");

        // =====================================================================
        // T07 全链冷复位后重新建立帧对齐
        // =====================================================================
        $display("\n-- T07 全链冷复位后重新同步 --");
        rst_n_sdr = 1'b0;
        rst_n_pix = 1'b0;
        repeat (200) @(posedge clk_sdr);
        rst_n_sdr = 1'b1;
        repeat (40) @(posedge clk_pix);
        rst_n_pix = 1'b1;
        wait_init;
        pat_row_only = 1'b0;
        pat_off      = 10'd11;
        fill_frame;
        wait_blank;
        wait_blank;
        win_open;
        win_close;
        report_stats("T07");
        chk(t_checks == LINES * H_DE, "T07 冷复位后覆盖 480x640 全部像素");
        chk(t_fails  == 0,            "T07 冷复位后逐像素仍匹配");

        // =====================================================================
        // 收尾
        // =====================================================================
        $display("\n==============================================");
        $display(" 统计: checks=%0d fails=%0d", checks, fails);
        if (fails == 0) $display(" ALL CHECKS PASSED: pix_reader");
        else            $display(" *** CHECKS FAILED: %0d ***", fails);
        $display("==============================================");
        $finish;
    end

    // 全局超时
    initial begin
        #200000000;
        $display(" *** GLOBAL TIMEOUT ***");
        $display(" 统计: checks=%0d fails=%0d", checks, fails);
        $display(" *** CHECKS FAILED: TIMEOUT ***");
        $finish;
    end


    // ===== TMP PROBE: 读侧消费追踪 =====
    integer rc = 0;
    always @(posedge clk_pix) begin
        if (rst_n_pix && rc < 20 && de) begin
            rc = rc + 1;
            $display("[R%0d] t=%0t pcnt=%0d rden=%b empty=%b fdata=%08h hold=%08h out=%04h exp=%04h",
                     rc, $time, dut.pix_cnt, dut.fifo_rd_en, dut.fifo_rd_empty,
                     dut.fifo_rd_data, dut.word_hold, pix_rgb565, exp_pix(h_cnt, v_cnt));
        end
    end
    // 统计 de 出现次数 + rd_empty 长期状态
    integer de_cnt = 0;
    integer empty_hi = 0;
    always @(posedge clk_pix) begin
        if (rst_n_pix) begin
            if (de) de_cnt = de_cnt + 1;
            if (de && dut.fifo_rd_empty) empty_hi = empty_hi + 1;
        end
    end


    // ===== TEMP PROBE: ARM + 仲裁器读指针 =====
    integer apr_n = 0;
    reg     apr_prev_gate = 1'b0;
    always @(posedge clk_pix) begin
        apr_n = apr_n + 1;
        // ARM 状态一变化就打印，附带仲裁器读指针
        if ((dut.arm_st != 3'd0) || (dut.arm_st !== apr_prev_gate))
            $display("[AR] n=%0d st=%0d armed=%b empty=%b arb_rdaddr=%0d grpact=%b outst=%0d lvl=%0d",
                     apr_n, dut.arm_st, dut.armed, dut.fifo_rd_empty,
                     u_arb.rd_addr, u_arb.rd_grp_active, u_arb.rd_outstanding, dut.level);
        apr_prev_gate = dut.arm_st;
    end
    // ===== END PROBE =====

endmodule
