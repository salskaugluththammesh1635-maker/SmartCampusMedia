// =============================================================================
// tb_sdram_frame_diag_top.v —— SDRAM 帧级 BIST 顶层整链集成测试
// -----------------------------------------------------------------------------
// 【被测对象】
//   rtl/storage/sdram_frame_diag.v 中的第二个 module：
//     module sdram_frame_diag_top (input wire clk, rst_n_btn,
//                                  output wire [7:0] led);
//
// 【这个顶层是干什么的】
//   板级自检入口：上电后自己跑一遍"整帧写入 + 整帧读回 + 逐字比对"，
//   用 8 个 LED 报告结果。它不接 SD、不接 HDMI、不接帧 FIFO，是独立诊断固件。
//   它串起了项目里最底层、最容易出问题的一条链：
//     clk(50MHz) -> sdram_pll(40MHz + 180deg) -> 复位同步 -> sdram_ctrl_wrap
//                -> sdram_frame_bist(写 153600 字 / 读回 / 比对)
//
// 【为什么这个顶层值得单独测（尽管它的子模块已有 TB）】
//   子模块各自绿了，不代表串起来能跑：
//     1) PLL 锁定前的复位释放时序（pll_delay 计数器 + async_reset_n = rst_n_btn && locked）
//     2) 两个时钟域（50MHz 输入 / 40MHz 内部）之间的复位同步
//     3) sdram_ctrl_wrap 的初始化握手（init_done / ref_vld）与 BIST 状态机对接
//     4) LED 8 位的编码顺序（位序写反了，板子上看到的现象完全不同）
//   这四件事只有整链仿真能验证。
//
// 【仿真可行性（已实测确认，这是本 TB 能存在的前提）】
//   - sdram_ctrl_wrap 有 `ifdef SDRAM_SIM_MODEL 分支，定义该宏后例化内联的
//     sdram_behavior_model，不需要加密的 EG_PHY_SDRAM_2M_32 物理模型。
//   - sdram_pll 用官方 eg_phy_pll.v 行为模型（真分频，实测锁定在 202 拍）。
//   - 必须把 glbl 作为第二顶层传入，否则 gsr_n 恒 0、PLL 永不复位释放。
//   实测里程碑（50MHz 输入时钟）：
//     LOCKED    cyc≈202
//     INIT_DONE cyc≈286
//     WRITING   cyc≈287   （写 153600 字）
//     READING   cyc≈192697（读回并逐字比对）
//     COMPLETE  cyc≈300k~400k 之间
//
// 【LED 编码（来自 sdram_frame_diag.v 的 led_reg 赋值，位序即字面顺序）】
//   led[7] = complete && all_zeros
//   led[6] = complete && all_ones
//   led[5] = timed_out
//   led[4] = mismatch
//   led[3] = reading
//   led[2] = writing
//   led[1] = locked
//   led[0] = passed
//   正常完成时的期望值：8'b0000_0011 = 0x03（只有 locked 与 passed 亮）
//   这个期望值同时钉死了"位序没写反"和"没有误报错标志"。
// =============================================================================
`timescale 1ns / 1ps

module tb_sdram_frame_diag_top;

    // 50MHz 输入时钟
    localparam CLK_HALF   = 10;
    // 整链跑完约 40 万拍；给 3 倍余量作为硬上限，防止 RTL 死锁时仿真挂住
    localparam MAX_CYCLES = 1200000;

    reg        clk       = 1'b0;
    reg        rst_n_btn = 1'b0;
    wire [7:0] led;

    integer checks = 0;
    integer errors = 0;

    always #CLK_HALF clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    sdram_frame_diag_top u_top (
        .clk       (clk),
        .rst_n_btn (rst_n_btn),
        .led       (led)
    );

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

    // -------------------------------------------------------------------------
    // 全程监视器：记录每个里程碑首次出现的拍号，并统计"写/读互斥"违例
    // -------------------------------------------------------------------------
    integer cyc        = 0;
    integer t_locked   = -1;
    integer t_init     = -1;
    integer t_write    = -1;
    integer t_read     = -1;
    integer t_complete = -1;
    integer both_active = 0;    // writing 与 reading 同时为 1 的拍数（必须为 0）
    integer lock_lost   = 0;    // 锁定后又丢失的拍数（正常必须为 0）

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (t_locked   < 0 && u_top.locked)    begin t_locked   = cyc;
            $display("INFO: PLL locked at cycle %0d", cyc); end
        if (t_init     < 0 && u_top.init_done) begin t_init     = cyc;
            $display("INFO: SDRAM init_done at cycle %0d", cyc); end
        if (t_write    < 0 && u_top.writing)   begin t_write    = cyc;
            $display("INFO: BIST writing at cycle %0d", cyc); end
        if (t_read     < 0 && u_top.reading)   begin t_read     = cyc;
            $display("INFO: BIST reading at cycle %0d", cyc); end
        if (t_complete < 0 && u_top.complete)  begin t_complete = cyc;
            $display("INFO: BIST complete at cycle %0d (passed=%b mismatch=%b timed_out=%b)",
                     cyc, u_top.passed, u_top.mismatch, u_top.timed_out); end
        if (u_top.writing && u_top.reading) both_active = both_active + 1;
        if (t_locked >= 0 && !u_top.locked) lock_lost = lock_lost + 1;
    end

    // -------------------------------------------------------------------------
    // 等待 complete（带拍数上限）
    // -------------------------------------------------------------------------
    task wait_complete(input integer limit);
        begin
            while (t_complete < 0 && cyc < limit) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // LED 采样同步（本 TB 最关键的一个小工具）
    // -------------------------------------------------------------------------
    // led_reg 是在 **sdr_clk（40MHz）** 的 posedge 上寄存的，而本 TB 的观测
    // 时序（t_write / t_read / t_complete 等里程碑）都建立在 **clk（50MHz）**
    // 上。两个时钟异步且频率不同，所以在 posedge clk 之后 #1 采 LED，很可能
    // 落在 sdr_clk 那一次更新**之前**，读到的是上一拍的状态 —— 表现为"内部
    // 信号已经翻转、LED 却还停在旧值"的假失败。
    // 对策：凡是断言 LED 的地方，都先等 3 个 sdr_clk 上升沿，让 led_reg 至少
    // 完成一次（实际上是三次）更新，再采样。
    task sync_led;
        begin
            @(posedge u_top.sdr_clk);
            @(posedge u_top.sdr_clk);
            @(posedge u_top.sdr_clk);
            #1;
        end
    endtask

    initial begin
        $display("=== tb_sdram_frame_diag_top start ===");

        // ---------------------------------------------------------------------
        // [1] 复位保持期：LED 全灭、PLL 未锁、BIST 未启动
        // ---------------------------------------------------------------------
        rst_n_btn = 1'b0;
        repeat (20) @(posedge clk);
        #1;
        ck_int(led, 8'h00, "[reset] LED all off while rst_n_btn is held low");
        ck(!u_top.locked,     "[reset] PLL not locked during reset hold");
        ck(!u_top.init_done,  "[reset] SDRAM init not done during reset hold");
        ck(!u_top.complete,   "[reset] BIST not complete during reset hold");
        ck(!u_top.writing && !u_top.reading, "[reset] BIST idle during reset hold");

        // ---------------------------------------------------------------------
        // [2] 释放复位，等 PLL 锁定
        // ---------------------------------------------------------------------
        rst_n_btn = 1'b1;
        while (t_locked < 0 && cyc < 20000) @(posedge clk);
        ck(t_locked >= 0, "[pll] PLL reaches lock after reset release");
        ck(t_locked < 2000, "[pll] PLL locks within 2000 cycles (no long settling)");
        sync_led;
        ck(led[1] === 1'b1, "[pll] LED bit1 reports locked");
        ck(led[0] === 1'b0, "[pll] LED bit0 (passed) still low before the BIST finishes");

        // ---------------------------------------------------------------------
        // [3] 等 SDRAM 初始化完成，BIST 必须随后启动写阶段
        // ---------------------------------------------------------------------
        while (t_init < 0 && cyc < 40000) @(posedge clk);
        ck(t_init >= 0, "[sdram] controller reports init_done");
        ck(t_init > t_locked, "[sdram] init_done comes after PLL lock (reset ordering)");

        while (t_write < 0 && cyc < 40000) @(posedge clk);
        ck(t_write >= 0, "[bist] write phase starts after init_done");
        ck(t_write >= t_init, "[bist] write phase never starts before init_done");

        // ---------------------------------------------------------------------
        // [4] 写阶段进行中：LED 的 writing 位必须亮、passed 位必须灭
        // ---------------------------------------------------------------------
        sync_led;
        ck(led[2] === 1'b1, "[bist] LED bit2 reports the write phase");
        ck(led[0] === 1'b0, "[bist] passed stays low while writing");

        // ---------------------------------------------------------------------
        // [5] 等读回比对阶段开始
        // ---------------------------------------------------------------------
        while (t_read < 0 && cyc < 900000) @(posedge clk);
        ck(t_read >= 0, "[bist] read-back phase starts");
        ck(t_read > t_write, "[bist] read phase comes strictly after the write phase");
        sync_led;
        ck(led[3] === 1'b1, "[bist] LED bit3 reports the read phase");

        // ---------------------------------------------------------------------
        // [6] 等整链完成
        // ---------------------------------------------------------------------
        wait_complete(MAX_CYCLES);
        ck(t_complete >= 0, "[bist] completes within the cycle budget");
        if (t_complete < 0) begin
            $display("FAIL: [bist] GLOBAL TIMEOUT waiting for complete");
            $display("INFO: cyc=%0d led=%b writing=%b reading=%b timed_out=%b",
                     cyc, led, u_top.writing, u_top.reading, u_top.timed_out);
            $display("SUMMARY: checks=%0d errors=%0d", checks, errors + 1);
            $display("CHECKS FAILED: sdram_frame_diag_top");
            $finish;
        end

        #1;
        sync_led;

        // ---------------------------------------------------------------------
        // [7] 完成态判定：必须 passed、且没有任何错误标志
        // ---------------------------------------------------------------------
        ck(u_top.passed    === 1'b1, "[result] BIST reports passed");
        ck(u_top.mismatch  === 1'b0, "[result] no data mismatch");
        ck(u_top.timed_out === 1'b0, "[result] no timeout");
        ck(u_top.all_ones  === 1'b0, "[result] read-back is not stuck at all-ones");
        ck(u_top.all_zeros === 1'b0, "[result] read-back is not stuck at all-zeros");
        ck(!u_top.writing && !u_top.reading, "[result] BIST returns to idle after completion");

        // ---------------------------------------------------------------------
        // [8] LED 编码：正常完成时只有 locked 与 passed 亮
        //   这一条同时验证了位序（写反了会变成 0xC0 之类）与"无错误标志"
        // ---------------------------------------------------------------------
        ck_int(led, 8'h03, "[led] final LED pattern is 0x03 (locked + passed only)");
        ck(led[7] === 1'b0, "[led] bit7 (all_zeros alarm) is low");
        ck(led[6] === 1'b0, "[led] bit6 (all_ones alarm) is low");
        ck(led[5] === 1'b0, "[led] bit5 (timeout alarm) is low");
        ck(led[4] === 1'b0, "[led] bit4 (mismatch alarm) is low");
        ck(led[3] === 1'b0, "[led] bit3 (reading) cleared after completion");
        ck(led[2] === 1'b0, "[led] bit2 (writing) cleared after completion");
        ck(led[1] === 1'b1, "[led] bit1 (locked) still high");
        ck(led[0] === 1'b1, "[led] bit0 (passed) high");

        // ---------------------------------------------------------------------
        // [9] 时序不变量：写读互斥、锁定不丢
        // ---------------------------------------------------------------------
        ck_int(both_active, 0, "[invariant] writing and reading are never active together");
        ck_int(lock_lost,   0, "[invariant] PLL lock is never lost once acquired");

        // ---------------------------------------------------------------------
        // [10] 完成态稳定：再观察 200 拍，LED 不得变化（无抖动）
        // ---------------------------------------------------------------------
        repeat (200) @(posedge clk);
        #1;
        ck_int(led, 8'h03, "[led] final LED pattern is stable for 200 further cycles");

        // ---------------------------------------------------------------------
        // 汇总
        // ---------------------------------------------------------------------
        $display("INFO: milestones locked=%0d init=%0d write=%0d read=%0d complete=%0d cycles",
                 t_locked, t_init, t_write, t_read, t_complete);
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: sdram_frame_diag_top");
        else             $display("CHECKS FAILED: sdram_frame_diag_top");
        $finish;
    end

    // -------------------------------------------------------------------------
    // 绝对超时兜底（wall-clock 保护）
    // -------------------------------------------------------------------------
    initial begin
        #(CLK_HALF * 2 * (MAX_CYCLES + 100000));
        $display("FAIL: GLOBAL TIMEOUT");
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors + 1);
        $display("CHECKS FAILED: sdram_frame_diag_top");
        $finish;
    end

endmodule
