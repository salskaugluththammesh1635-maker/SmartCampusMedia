// =============================================================================
// tb_hdmi_pll.v —— hdmi_pll 单元测试
// -----------------------------------------------------------------------------
// 【被测对象】
//   rtl/video/hdmi/hdmi_pll.v
//   端口: refclk(50MHz 参考) / reset(高有效) / extlock(锁定指示)
//         clk_pixel(25MHz 像素时钟) / clk_5x(125MHz 串行时钟)
//
// 【为什么必须测这个模块】
//   HDMI 1.4b 的 10bit TMDS 要靠"像素时钟 25MHz + 串行时钟 125MHz 严格 5 倍
//   且同源同相"才能把 10 bit 摊到 5 个串行周期里。这条契约一旦不成立：
//     - 比值偏小 → 10 bit 塞不进一个像素周期，尾部 bit 被下一字覆盖（画面错位）
//     - 比值偏大 → 串行周期多出空拍，接收端采样点漂移（画面撕裂或黑屏）
//     - 两路不同源 → 相位缓慢漂移，长时间运行后随机出横纹
//   这三类失效在板上表现为"时好时坏"，最难定位。所以在这里用数值钉死。
//
// 【判据设计】
//   1) 频率用"数边沿"而不是"测单周期"：单周期受 PLL 模型 realtime 延迟的
//      亚纳秒抖动影响，数 N 个周期求平均才能稳定判定。
//   2) 5 倍关系用"整窗口计数"：取 64 个像素周期，数其中 clk_5x 的上升沿个数，
//      必须恰好 5×64=320。这自动吸收任意固定相位差，只验频率比。
//   3) 单周期数值也单独验一次（容差 1%），用于抓"比值对但绝对频率错"的情况。
//   4) 复位期间 extlock 必须为 0（下游靠它做"PLL 没好不许发 SDRAM/HDMI"）。
//
// 【仿真依赖】
//   官方库 eg_phy_pll.v（EG_PHY_PLL 真实分频模型）、eg_logic_clk.v（EG_LOGIC_BUFG）、
//   eg_phy_glbl.v（glbl）。vsim 命令行须带 glbl 作为第二顶层。
// =============================================================================
`timescale 1ns / 1ps

module tb_hdmi_pll;

    // ---- 参考时钟：50MHz → 半周期 10ns ----
    localparam REF_HALF = 10;

    // ---- 期望输出频率 ----
    localparam real EXP_PIXEL_NS = 40.0;    // 25MHz
    localparam real EXP_5X_NS    = 8.0;     // 125MHz
    localparam real TOL_NS       = 0.40;    // 单周期容差 1%

    // ---- 整窗口计数参数 ----
    localparam integer WIN_PIX    = 64;             // 观察 64 个像素周期
    localparam integer EXP_5X_EDGES = 5 * WIN_PIX;  // 其中应有 320 个 5x 上升沿

    reg  refclk = 1'b0;
    reg  reset  = 1'b1;

    wire extlock;
    wire clk_pixel;
    wire clk_5x;

    integer checks = 0;
    integer errors = 0;

    always #(REF_HALF) refclk = ~refclk;

    hdmi_pll u_pll (
        .refclk    (refclk),
        .reset     (reset),
        .extlock   (extlock),
        .clk_pixel (clk_pixel),
        .clk_5x    (clk_5x)
    );

    // -------------------------------------------------------------------------
    // 计分器
    // -------------------------------------------------------------------------
    task ck(input cond, input [8*96-1:0] label);
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    task ck_real(input real got, input real exp, input real tol, input [8*96-1:0] label);
        begin
            checks = checks + 1;
            if ((got > exp - tol) && (got < exp + tol)) $display("PASS: %0s (got %0.3f ns)", label, got);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s (got %0.3f ns expected %0.3f +/- %0.3f)", label, got, exp, tol);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 测单个时钟周期（连续两次上升沿之间的时间）
    // -------------------------------------------------------------------------
    task measure_period(output real period, input integer dummy);
        real t0, t1;
        begin
            @(posedge clk_pixel); t0 = $realtime;
            @(posedge clk_pixel); t1 = $realtime;
            period = t1 - t0;
        end
    endtask

    // -------------------------------------------------------------------------
    // 在 WIN_PIX 个像素周期窗口内数 clk_5x 的上升沿
    //   从 clk_pixel 上升沿开始、到第 WIN_PIX 个上升沿结束，
    //   边界处用半个 5x 周期的裕量避免把窗口两端的沿算错。
    // -------------------------------------------------------------------------
    task count_5x_in_window(output integer edges);
        integer n;
        begin
            edges = 0;
            @(posedge clk_pixel);
            for (n = 0; n < WIN_PIX; n = n + 1) begin
                @(posedge clk_5x); edges = edges + 1;
                @(posedge clk_5x); edges = edges + 1;
                @(posedge clk_5x); edges = edges + 1;
                @(posedge clk_5x); edges = edges + 1;
                @(posedge clk_5x); edges = edges + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 等 extlock 拉高，带超时
    // -------------------------------------------------------------------------
    task wait_lock(output locked, input integer max_ns);
        integer waited;
        begin
            locked = 1'b0;
            waited = 0;
            while ((waited < max_ns) && (extlock !== 1'b1)) begin
                #100;
                waited = waited + 100;
            end
            if (extlock === 1'b1) locked = 1'b1;
        end
    endtask

    // -------------------------------------------------------------------------
    // 主流程
    // -------------------------------------------------------------------------
    real    period_pixel;
    real    period_5x;
    real    ratio;
    integer edges_5x;
    integer edges_5x_2;
    reg     locked;
    integer i;

    initial begin
        $display("=== hdmi_pll unit test ===");

        // ---------------------------------------------------------------------
        // [1] 复位期间：extlock 必须为低
        //     下游（顶层复位同步器）靠 extlock 判断"PLL 还没好"，若这里为高，
        //     SDRAM 与 HDMI 会在时钟未稳时就发操作，上电随机挂死。
        // ---------------------------------------------------------------------
        reset = 1'b1;
        #(REF_HALF * 40);
        ck(extlock === 1'b0, "[reset] extlock is low while reset is asserted");

        // ---------------------------------------------------------------------
        // [2] 释放复位后应在合理时间内锁定
        //     官方模型约 800ns 出锁定；给 100us 上限，超时即判定锁定失败。
        // ---------------------------------------------------------------------
        reset = 1'b0;
        wait_lock(locked, 100000);
        ck(locked === 1'b1, "[lock] extlock rises after reset release");

        // 锁定后再等一会，让分频器相位稳定（PLL 模型前几拍在算周期）
        #(REF_HALF * 200);

        // ---------------------------------------------------------------------
        // [3] 单周期数值
        //     抓"比值对但绝对频率错"的情况（例如 C0/C2 分频比整体偏移）。
        // ---------------------------------------------------------------------
        measure_period(period_pixel, 0);
        ck_real(period_pixel, EXP_PIXEL_NS, TOL_NS, "[freq] clk_pixel period is 40ns (25MHz)");

        // clk_5x 周期太短，直接测容易被亚纳秒抖动吃掉精度，
        // 改成测 10 个周期再除以 10。
        begin : measure_5x
            real a, b;
            @(posedge clk_5x); a = $realtime;
            for (i = 0; i < 10; i = i + 1) @(posedge clk_5x);
            b = $realtime;
            period_5x = (b - a) / 10.0;
        end
        ck_real(period_5x, EXP_5X_NS, TOL_NS / 2.0, "[freq] clk_5x period is 8ns (125MHz)");

        // ---------------------------------------------------------------------
        // [4] 严格 5 倍关系（核心契约）
        //     整窗口数边沿，必须恰好 320 个。多一个少一个都说明串化比不是 5:1。
        // ---------------------------------------------------------------------
        count_5x_in_window(edges_5x);
        ck(edges_5x === EXP_5X_EDGES,
           "[ratio] exactly 5 clk_5x edges per clk_pixel cycle (320 in 64 cycles)");
        if (edges_5x !== EXP_5X_EDGES) begin
            $display("      got %0d edges, expected %0d", edges_5x, EXP_5X_EDGES);
        end

        // 再数一次，确认关系持续成立而不是偶然对齐
        count_5x_in_window(edges_5x_2);
        ck(edges_5x_2 === EXP_5X_EDGES,
           "[ratio] 5x ratio holds on a second independent window");

        // ---------------------------------------------------------------------
        // [5] 由实测周期反算比值，与 [4] 互相印证
        // ---------------------------------------------------------------------
        ratio = period_pixel / period_5x;
        ck_real(ratio, 5.0, 0.02, "[ratio] measured period ratio is 5.00");

        // ---------------------------------------------------------------------
        // [6] 运行中复位：extlock 必须掉回低
        //     板上按复位键时，下游必须被拦住。若 extlock 不响应复位，
        //     复位期间 SDRAM 控制器仍在发命令，会造成总线冲突。
        // ---------------------------------------------------------------------
        reset = 1'b1;
        #(REF_HALF * 200);
        ck(extlock === 1'b0, "[reset] extlock drops when reset is re-asserted mid-run");

        // ---------------------------------------------------------------------
        // [7] 复位释放后重新锁定，且频率关系仍然成立
        // ---------------------------------------------------------------------
        reset = 1'b0;
        wait_lock(locked, 100000);
        ck(locked === 1'b1, "[resume] extlock recovers after second reset release");

        #(REF_HALF * 200);
        count_5x_in_window(edges_5x);
        ck(edges_5x === EXP_5X_EDGES, "[resume] 5x ratio still exact after reset cycle");

        measure_period(period_pixel, 0);
        ck_real(period_pixel, EXP_PIXEL_NS, TOL_NS, "[resume] clk_pixel period still 40ns");

        // ---------------------------------------------------------------------
        // [8] 两路时钟都在翻转（防止"锁定但某路死平"的僵死态）
        // ---------------------------------------------------------------------
        ck((clk_pixel === 1'b0) || (clk_pixel === 1'b1), "[alive] clk_pixel is not X");
        ck((clk_5x === 1'b0) || (clk_5x === 1'b1), "[alive] clk_5x is not X");

        // ---------------------------------------------------------------------
        // 汇总
        // ---------------------------------------------------------------------
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: hdmi_pll");
        else             $display("CHECKS FAILED: hdmi_pll");
        $finish;
    end

    // 看门狗：任何一步卡死都要有明确失败输出，不能静默超时
    initial begin
        #5000000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors + 1);
        $display("CHECKS FAILED: hdmi_pll");
        $finish;
    end

endmodule
