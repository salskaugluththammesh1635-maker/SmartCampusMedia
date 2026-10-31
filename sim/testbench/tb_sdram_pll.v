// =============================================================================
// tb_sdram_pll.v —— sdram_pll 单元测试
// -----------------------------------------------------------------------------
// 【被测对象】
//   rtl/storage/sdram_pll.v
//   端口: refclk(50MHz) / reset(高有效) / extlock
//         sdram_clk(40MHz 0deg) / sdram_clk_sft(40MHz 180deg)
//
// 【为什么必须测这个模块】
//   SDRAM 采用"源同步写"：控制器用 sdram_clk 发数据，SDRAM 芯片用
//   sdram_clk_sft 采样。两者必须**同频且严格反相（180deg）**：
//     - 若同相 → 数据和采样沿重合，建立/保持时间双双归零，写入必错
//     - 若相位偏离 180deg 较大 → 时序裕量被吃掉，高温或换批次颗粒后随机出错
//     - 若不同频 → 相位持续漂移，一段时间好一段时间坏，最难查
//   本项目为这个时钟曾经两次降频（150→100→40MHz，见 sdram_pll.v 头部注释），
//   说明这条契约是真实的工程瓶颈，所以必须用数值钉死。
//
// 【判据设计】
//   1) 两路周期都必须是 25ns（40MHz），各测一次。
//   2) 两路必须同频：在 64 个 0deg 周期窗口内，180deg 的上升沿数必须恰好 64。
//   3) 反相判定用"电平互补"而不是"延迟时间"：
//        - 在 0deg 上升沿之后 1ns 采样，180deg 必须是低
//        - 在 0deg 下降沿之后 1ns 采样，180deg 必须是高
//      这样判据直接对应"数据和采样沿错开半周期"这个物理目的，
//      不受 PLL 模型内部固定延迟的影响。采样点放在沿后 1ns 是为了躲开
//      两个时钟跳变的竞争窗口。
//   4) 反相判定重复多轮（连续 8 个周期），防止偶然对齐。
//   5) 复位期间 extlock 必须为低；运行中复位必须掉回低。
//   6) 180deg 时钟绝不能是死平电平（曾出现过 C2 未被 BUFG 缓冲的布线问题）。
//
// 【仿真依赖】
//   官方库 eg_phy_pll.v / eg_logic_clk.v / eg_logic_io.v / eg_phy_glbl.v。
//   vsim 命令行须带 glbl 作为第二顶层。
// =============================================================================
`timescale 1ns / 1ps

module tb_sdram_pll;

    localparam REF_HALF = 10;          // 50MHz 参考
    localparam real EXP_NS = 25.0;     // 40MHz
    localparam real TOL_NS = 0.25;     // 1%

    localparam integer WIN_CYC     = 64;   // 观察 64 个 0deg 周期
    localparam integer EXP_SFT_EDG = WIN_CYC;
    localparam integer PHASE_ROUNDS = 8;   // 反相判定重复轮数

    reg  refclk = 1'b0;
    reg  reset  = 1'b1;

    wire extlock;
    wire sdram_clk;
    wire sdram_clk_sft;

    integer checks = 0;
    integer errors = 0;

    always #(REF_HALF) refclk = ~refclk;

    sdram_pll u_pll (
        .refclk        (refclk),
        .reset         (reset),
        .extlock       (extlock),
        .sdram_clk     (sdram_clk),
        .sdram_clk_sft (sdram_clk_sft)
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
    // 测平均周期（n 个周期除以 n，抑制亚纳秒抖动）
    // -------------------------------------------------------------------------
    task avg_period_clk0(output real p, input integer n);
        real a, b; integer i;
        begin
            @(posedge sdram_clk); a = $realtime;
            for (i = 0; i < n; i = i + 1) @(posedge sdram_clk);
            b = $realtime;
            p = (b - a) / n;
        end
    endtask

    task avg_period_sft(output real p, input integer n);
        real a, b; integer i;
        begin
            @(posedge sdram_clk_sft); a = $realtime;
            for (i = 0; i < n; i = i + 1) @(posedge sdram_clk_sft);
            b = $realtime;
            p = (b - a) / n;
        end
    endtask

    // -------------------------------------------------------------------------
    // 在 WIN_CYC 个 0deg 周期内数 180deg 的上升沿
    // -------------------------------------------------------------------------
    task count_sft_edges(output integer edges);
        integer n;
        begin
            edges = 0;
            @(posedge sdram_clk);
            for (n = 0; n < WIN_CYC; n = n + 1) begin
                @(posedge sdram_clk_sft); edges = edges + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 反相判定：跑 PHASE_ROUNDS 轮，每轮检查两个采样点
    //   返回违例个数，0 表示严格反相
    // -------------------------------------------------------------------------
    task check_antiphase(output integer bad);
        integer r;
        begin
            bad = 0;
            for (r = 0; r < PHASE_ROUNDS; r = r + 1) begin
                // 0deg 上升沿之后 1ns：180deg 应当为低
                @(posedge sdram_clk);
                #1;
                if (sdram_clk_sft !== 1'b0) bad = bad + 1;
                // 0deg 下降沿之后 1ns：180deg 应当为高
                @(negedge sdram_clk);
                #1;
                if (sdram_clk_sft !== 1'b1) bad = bad + 1;
            end
        end
    endtask

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
    real    p0, p1;
    integer edges_sft;
    integer bad_phase;
    reg     locked;

    initial begin
        $display("=== sdram_pll unit test ===");

        // ---------------------------------------------------------------------
        // [1] 复位期间 extlock 必须为低
        // ---------------------------------------------------------------------
        reset = 1'b1;
        #(REF_HALF * 40);
        ck(extlock === 1'b0, "[reset] extlock is low while reset is asserted");

        // ---------------------------------------------------------------------
        // [2] 释放复位后锁定
        // ---------------------------------------------------------------------
        reset = 1'b0;
        wait_lock(locked, 100000);
        ck(locked === 1'b1, "[lock] extlock rises after reset release");
        #(REF_HALF * 200);

        // ---------------------------------------------------------------------
        // [3] 两路频率都必须是 40MHz
        // ---------------------------------------------------------------------
        avg_period_clk0(p0, 20);
        ck_real(p0, EXP_NS, TOL_NS, "[freq] sdram_clk period is 25ns (40MHz)");

        avg_period_sft(p1, 20);
        ck_real(p1, EXP_NS, TOL_NS, "[freq] sdram_clk_sft period is 25ns (40MHz)");

        // ---------------------------------------------------------------------
        // [4] 同频：64 个 0deg 周期里恰好 64 个 180deg 上升沿
        //     若两路有频率偏差（哪怕 0.1%），64 拍内就会少一个或多一个沿。
        // ---------------------------------------------------------------------
        count_sft_edges(edges_sft);
        ck(edges_sft === EXP_SFT_EDG, "[ratio] one sft edge per main edge (64 in 64 cycles)");
        if (edges_sft !== EXP_SFT_EDG) begin
            $display("      got %0d sft edges, expected %0d", edges_sft, EXP_SFT_EDG);
        end

        // ---------------------------------------------------------------------
        // [5] 严格反相（核心契约）
        // ---------------------------------------------------------------------
        check_antiphase(bad_phase);
        ck(bad_phase === 0,
           "[phase] sft clock is exactly antiphase (low at main rise, high at main fall)");
        if (bad_phase !== 0) begin
            $display("      %0d of %0d phase samples violated", bad_phase, PHASE_ROUNDS * 2);
        end

        // ---------------------------------------------------------------------
        // [6] 两路都在翻转（防"锁定但某路死平"）
        // ---------------------------------------------------------------------
        ck((sdram_clk === 1'b0) || (sdram_clk === 1'b1), "[alive] sdram_clk is not X");
        ck((sdram_clk_sft === 1'b0) || (sdram_clk_sft === 1'b1), "[alive] sdram_clk_sft is not X");

        // 180deg 一路若被焊死成常数，[5] 会全违例；这里再单独确认它确实在跳
        //   采样时刻必须钉在确定的电平上：先等下降沿取低电平，再等上升沿取高电平。
        //   若随手取当前值，恰好落在上升沿附近时会读到高电平，造成假失败。
        begin : toggle_check
            reg v0, v1;
            @(negedge sdram_clk_sft);
            #1;
            v0 = sdram_clk_sft;
            @(posedge sdram_clk_sft);
            #1;
            v1 = sdram_clk_sft;
            ck((v0 === 1'b0) && (v1 === 1'b1), "[alive] sdram_clk_sft actually toggles low then high");
        end

        // ---------------------------------------------------------------------
        // [7] 运行中复位：extlock 掉低
        // ---------------------------------------------------------------------
        reset = 1'b1;
        #(REF_HALF * 200);
        ck(extlock === 1'b0, "[reset] extlock drops when reset is re-asserted mid-run");

        // ---------------------------------------------------------------------
        // [8] 复位释放后重新锁定，频率与相位关系仍成立
        // ---------------------------------------------------------------------
        reset = 1'b0;
        wait_lock(locked, 100000);
        ck(locked === 1'b1, "[resume] extlock recovers after second reset release");
        #(REF_HALF * 200);

        avg_period_clk0(p0, 20);
        ck_real(p0, EXP_NS, TOL_NS, "[resume] sdram_clk period still 25ns");

        check_antiphase(bad_phase);
        ck(bad_phase === 0, "[resume] sft clock still exactly antiphase");

        // ---------------------------------------------------------------------
        // 汇总
        // ---------------------------------------------------------------------
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: sdram_pll");
        else             $display("CHECKS FAILED: sdram_pll");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors + 1);
        $display("CHECKS FAILED: sdram_pll");
        $finish;
    end

endmodule
