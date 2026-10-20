// =============================================================================
// tb_sdram_ctrl_wrap.v — ERAM 行为模型的独立、自检、有限等待测试
// =============================================================================
// 参考侧独立按“每四个被接受拍锁存一次首址”寻址，不读取 DUT 内部存储。
// DM=1 表示屏蔽；主实例的 70000 拍刷新周期还用于发现 16 位参数截断。
// 密集刷新实例只验证当前行为模型的暂停语义，不替代加密真核契约验证。
`timescale 1ns / 1ps

module tb_sdram_ctrl_wrap;
    localparam CLK_PERIOD = 6.667;
    localparam MEM_WORDS = 1024;
    localparam INIT_CYCLES = 64;
    localparam RD_LATENCY = 10;
    localparam REFRESH_PERIOD = 70000;
    localparam FAST_REFRESH = 96;
    localparam REF_VLD_CYCLES = 8;
    localparam QUEUE_WORDS = 8192;

    reg clk = 1'b0;
    wire clk_sft = ~clk;
    reg rst_n;
    wire init_done, ref_vld, busy;
    reg app_wr_en, app_rd_en;
    reg [20:0] app_wr_addr, app_rd_addr;
    reg [31:0] app_wr_din;
    reg [3:0] app_wr_dm;
    wire sdr_rd_en;
    wire [31:0] sdr_rd_dout;

    reg f_wr_en, f_rd_en;
    reg [20:0] f_wr_addr, f_rd_addr;
    reg [31:0] f_wr_din;
    reg [3:0] f_wr_dm;
    wire f_init_done, f_ref_vld, f_busy, f_rd_valid;
    wire [31:0] f_rd_data;

    integer checks = 0;
    integer errors = 0;
    integer cases_done = 0;
    integer cycle = 0;
    integer wr_phase = 0;
    integer rd_phase = 0;
    integer wr_base = 0;
    integer rd_base_latched = 0;
    integer writes = 0;
    integer reads = 0;
    integer q_head = 0;
    integer q_tail = 0;
    integer first_ref_cycle = 0;
    integer ref_width = 0;
    integer ref_windows = 0;
    reg ref_prev = 1'b0;
    reg [31:0] golden [0:MEM_WORDS-1];
    reg [31:0] expected [0:QUEUE_WORDS-1];
    integer due_cycle [0:QUEUE_WORDS-1];
    integer effective_addr;

    integer f_cycle = 0;
    integer f_wr_phase = 0;
    integer f_rd_phase = 0;
    integer f_wr_base = 0;
    integer f_rd_base = 0;
    integer f_writes = 0;
    integer f_reads = 0;
    integer f_head = 0;
    integer f_tail = 0;
    integer f_ref_width = 0;
    integer f_ref_windows = 0;
    integer f_low_cycles = 0;
    integer f_write_pauses = 0;
    reg f_ref_prev = 1'b0;
    reg [31:0] f_golden [0:MEM_WORDS-1];
    reg [31:0] f_expected [0:QUEUE_WORDS-1];
    integer f_due_cycle [0:QUEUE_WORDS-1];
    integer f_effective_addr;
    integer i, guard, before_reads, before_writes, windows_before;

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    sdram_ctrl_wrap #(
        .CLK_FREQ_HZ(150000000), .SIM_MEM_WORDS(MEM_WORDS),
        .REFRESH_PERIOD(REFRESH_PERIOD)
    ) dut (
        .clk(clk), .clk_sft(clk_sft), .rst_n(rst_n),
        .init_done(init_done), .ref_vld(ref_vld), .busy(busy),
        .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
        .app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
        .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout),
        .sdram_clk(), .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(),
        .sdram_cas_n(), .sdram_we_n(), .sdram_ba(), .sdram_addr(),
        .sdram_dm(), .sdram_dq()
    );

    sdram_ctrl_wrap #(
        .CLK_FREQ_HZ(150000000), .SIM_MEM_WORDS(MEM_WORDS),
        .REFRESH_PERIOD(FAST_REFRESH)
    ) dut_fast (
        .clk(clk), .clk_sft(clk_sft), .rst_n(rst_n),
        .init_done(f_init_done), .ref_vld(f_ref_vld), .busy(f_busy),
        .app_wr_en(f_wr_en), .app_wr_addr(f_wr_addr),
        .app_wr_din(f_wr_din), .app_wr_dm(f_wr_dm),
        .app_rd_en(f_rd_en), .app_rd_addr(f_rd_addr),
        .sdr_rd_en(f_rd_valid), .sdr_rd_dout(f_rd_data),
        .sdram_clk(), .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(),
        .sdram_cas_n(), .sdram_we_n(), .sdram_ba(), .sdram_addr(),
        .sdram_dm(), .sdram_dq()
    );

    task chk;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL: %0s (t=%0t)", message, $time);
            end
        end
    endtask

    // 在上升沿 NBA 前采样：被接受拍到返回 valid 必须精确相隔 10 个边沿。
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle = 0;
            wr_phase = 0;
            rd_phase = 0;
            wr_base = 0;
            rd_base_latched = 0;
            writes = 0;
            reads = 0;
            q_head = 0;
            q_tail = 0;
            first_ref_cycle = 0;
            ref_width = 0;
            ref_windows = 0;
            ref_prev = 1'b0;
        end else begin
            cycle = cycle + 1;
            if (!init_done) begin
                chk(!sdr_rd_en, "main: no read return before initialization");
                chk(busy, "main: busy during initialization");
            end else begin
                chk(busy === ref_vld, "main: initialized busy equals refresh window");
            end
            if (ref_vld) begin
                ref_width = ref_width + 1;
                if (!ref_prev && first_ref_cycle == 0) first_ref_cycle = cycle;
            end else if (ref_prev) begin
                chk(ref_width == REF_VLD_CYCLES, "main: refresh is exactly eight sampled clocks");
                ref_width = 0;
                ref_windows = ref_windows + 1;
            end
            ref_prev = ref_vld;

            if (sdr_rd_en) begin
                chk(q_head < q_tail, "main: no unsolicited or duplicate read return");
                if (q_head < q_tail) begin
                    chk(cycle == due_cycle[q_head], "main: read latency is exactly ten clocks");
                    chk(sdr_rd_dout === expected[q_head], "main: read data matches independent burst reference");
                    q_head = q_head + 1;
                end
            end
            if (q_head < q_tail)
                chk(cycle <= due_cycle[q_head], "main: no overdue or missing read return");

            if (init_done && !ref_vld && app_wr_en) begin
                if (wr_phase == 0) wr_base = app_wr_addr % MEM_WORDS;
                effective_addr = (wr_base + wr_phase) % MEM_WORDS;
                if (!app_wr_dm[0]) golden[effective_addr][7:0] = app_wr_din[7:0];
                if (!app_wr_dm[1]) golden[effective_addr][15:8] = app_wr_din[15:8];
                if (!app_wr_dm[2]) golden[effective_addr][23:16] = app_wr_din[23:16];
                if (!app_wr_dm[3]) golden[effective_addr][31:24] = app_wr_din[31:24];
                wr_phase = (wr_phase + 1) % 4;
                writes = writes + 1;
            end
            if (init_done && !ref_vld && app_rd_en) begin
                if (rd_phase == 0) rd_base_latched = app_rd_addr % MEM_WORDS;
                effective_addr = (rd_base_latched + rd_phase) % MEM_WORDS;
                chk(q_tail < QUEUE_WORDS, "main: bounded expected-data queue has capacity");
                if (q_tail < QUEUE_WORDS) begin
                    expected[q_tail] = golden[effective_addr];
                    due_cycle[q_tail] = cycle + RD_LATENCY;
                    q_tail = q_tail + 1;
                end
                rd_phase = (rd_phase + 1) % 4;
                reads = reads + 1;
            end
        end
    end

    // 密集刷新实例使用另一套参考数据及相位，不借用主实例或 DUT 内部状态。
    always @(posedge clk) begin
        if (!rst_n) begin
            f_cycle = 0;
            f_wr_phase = 0;
            f_rd_phase = 0;
            f_wr_base = 0;
            f_rd_base = 0;
            f_writes = 0;
            f_reads = 0;
            f_head = 0;
            f_tail = 0;
            f_ref_width = 0;
            f_ref_windows = 0;
            f_low_cycles = 0;
            f_write_pauses = 0;
            f_ref_prev = 1'b0;
        end else begin
            f_cycle = f_cycle + 1;
            if (f_init_done) chk(f_busy === f_ref_vld, "fast: busy reflects refresh");
            if (f_ref_vld) begin
                f_ref_width = f_ref_width + 1;
                f_low_cycles = 0;
                if (!f_ref_prev && f_wr_phase != 0)
                    f_write_pauses = f_write_pauses + 1;
            end else begin
                f_low_cycles = f_low_cycles + 1;
                if (f_ref_prev) begin
                    chk(f_ref_width == REF_VLD_CYCLES, "fast: refresh is exactly eight sampled clocks");
                    f_ref_width = 0;
                    f_ref_windows = f_ref_windows + 1;
                end
            end
            f_ref_prev = f_ref_vld;
            if (f_rd_valid) begin
                chk(f_head < f_tail, "fast: ignored refresh reads produce no extra return");
                if (f_head < f_tail) begin
                    chk(f_cycle == f_due_cycle[f_head], "fast: accepted read retains exact ten-clock latency");
                    chk(f_rd_data === f_expected[f_head], "fast: data and burst phase survive refresh pause");
                    f_head = f_head + 1;
                end
            end
            if (f_head < f_tail)
                chk(f_cycle <= f_due_cycle[f_head], "fast: no missing read return");
            if (f_init_done && !f_ref_vld && f_wr_en) begin
                if (f_wr_phase == 0) f_wr_base = f_wr_addr % MEM_WORDS;
                f_effective_addr = (f_wr_base + f_wr_phase) % MEM_WORDS;
                if (!f_wr_dm[0]) f_golden[f_effective_addr][7:0] = f_wr_din[7:0];
                if (!f_wr_dm[1]) f_golden[f_effective_addr][15:8] = f_wr_din[15:8];
                if (!f_wr_dm[2]) f_golden[f_effective_addr][23:16] = f_wr_din[23:16];
                if (!f_wr_dm[3]) f_golden[f_effective_addr][31:24] = f_wr_din[31:24];
                f_wr_phase = (f_wr_phase + 1) % 4;
                f_writes = f_writes + 1;
            end
            if (f_init_done && !f_ref_vld && f_rd_en) begin
                if (f_rd_phase == 0) f_rd_base = f_rd_addr % MEM_WORDS;
                f_effective_addr = (f_rd_base + f_rd_phase) % MEM_WORDS;
                chk(f_tail < QUEUE_WORDS, "fast: bounded expected-data queue has capacity");
                if (f_tail < QUEUE_WORDS) begin
                    f_expected[f_tail] = f_golden[f_effective_addr];
                    f_due_cycle[f_tail] = f_cycle + RD_LATENCY;
                    f_tail = f_tail + 1;
                end
                f_rd_phase = (f_rd_phase + 1) % 4;
                f_reads = f_reads + 1;
            end
        end
    end

    // mode=0 恒首址；mode=1 首址+拍号；mode=2 组内任意变化，验证已锁首址。
    // mode=2 仅测本行为模型的既定选择，不声称官方接口允许任意组内跳址。
    task write_group;
        input [20:0] base;
        input [31:0] seed_data;
        input [3:0] mask;
        input integer mode;
        integer beat, wait_cycles;
        begin
            for (beat = 0; beat < 4; beat = beat + 1) begin
                @(negedge clk);
                app_wr_en = 1'b0;
                wait_cycles = 0;
                while ((!init_done || ref_vld) && wait_cycles < 256) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                chk(init_done && !ref_vld, "write driver reaches an accepting cycle within bound");
                app_wr_en = 1'b1;
                app_wr_addr = base;
                if (mode == 1) app_wr_addr = base + beat;
                if (mode == 2 && beat != 0) app_wr_addr = base + 64 + beat * 8;
                app_wr_din = seed_data + beat;
                app_wr_dm = mask;
            end
            @(negedge clk);
            app_wr_en = 1'b0;
        end
    endtask

    task read_group;
        input [20:0] base;
        input integer mode;
        integer beat, wait_cycles;
        begin
            for (beat = 0; beat < 4; beat = beat + 1) begin
                @(negedge clk);
                app_rd_en = 1'b0;
                wait_cycles = 0;
                while ((!init_done || ref_vld) && wait_cycles < 256) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                chk(init_done && !ref_vld, "read driver reaches an accepting cycle within bound");
                app_rd_en = 1'b1;
                app_rd_addr = base;
                if (mode == 1) app_rd_addr = base + beat;
                if (mode == 2 && beat != 0) app_rd_addr = base + 64 + beat * 8;
            end
            @(negedge clk);
            app_rd_en = 1'b0;
        end
    endtask

    task fast_write_group;
        input [20:0] base;
        input [31:0] seed_data;
        integer beat, wait_cycles;
        begin
            for (beat = 0; beat < 4; beat = beat + 1) begin
                @(negedge clk);
                f_wr_en = 1'b0;
                wait_cycles = 0;
                while ((!f_init_done || f_ref_vld) && wait_cycles < 256) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                chk(f_init_done && !f_ref_vld, "fast write driver has bounded ready wait");
                f_wr_en = 1'b1;
                f_wr_addr = base;
                f_wr_din = seed_data + beat;
                f_wr_dm = 4'h0;
            end
            @(negedge clk);
            f_wr_en = 1'b0;
        end
    endtask

    task fast_read_group;
        input [20:0] base;
        integer beat, wait_cycles;
        begin
            for (beat = 0; beat < 4; beat = beat + 1) begin
                @(negedge clk);
                f_rd_en = 1'b0;
                wait_cycles = 0;
                while ((!f_init_done || f_ref_vld) && wait_cycles < 256) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                end
                chk(f_init_done && !f_ref_vld, "fast read driver has bounded ready wait");
                f_rd_en = 1'b1;
                f_rd_addr = base;
            end
            @(negedge clk);
            f_rd_en = 1'b0;
        end
    endtask

    task drain_reads;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((q_head != q_tail || f_head != f_tail) && wait_cycles < 256) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            chk(q_head == q_tail && f_head == f_tail, "all accepted reads return within bounded drain");
        end
    endtask

    task reset_and_init;
        integer wait_cycles;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            app_wr_en = 1'b0;
            app_rd_en = 1'b0;
            f_wr_en = 1'b0;
            f_rd_en = 1'b0;
            repeat (4) @(negedge clk);
            chk(!init_done && busy, "reset clears init_done and asserts busy");
            rst_n = 1'b1;
            wait_cycles = 0;
            while ((!init_done || !f_init_done) && wait_cycles < INIT_CYCLES + 8) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            chk(init_done && f_init_done, "both instances initialize within bounded wait");
            chk(wait_cycles >= INIT_CYCLES, "initialization is not spuriously shortened");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        app_wr_en = 1'b0;
        app_rd_en = 1'b0;
        app_wr_addr = 21'd0;
        app_rd_addr = 21'd0;
        app_wr_din = 32'd0;
        app_wr_dm = 4'hF;
        f_wr_en = 1'b0;
        f_rd_en = 1'b0;
        f_wr_addr = 21'd0;
        f_rd_addr = 21'd0;
        f_wr_din = 32'd0;
        f_wr_dm = 4'hF;
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            golden[i] = 32'd0;
            f_golden[i] = 32'd0;
        end

        $display("CASE T01/T02: reset, initialization, and busy contract");
        reset_and_init;
        chk(init_done && !busy, "initialized main instance is ready");
        cases_done = cases_done + 2;

        $display("CASE T03/T04: constant-base four-beat write/read and exact latency");
        write_group(21'd0, 32'hA0130200, 4'h0, 0);
        write_group(21'd4, 32'hB0240300, 4'h0, 0);
        before_reads = reads;
        read_group(21'd0, 0);
        read_group(21'd4, 0);
        drain_reads;
        chk(reads - before_reads == 8, "two complete groups accept exactly eight reads");
        chk(golden[0] == 32'hA0130200 && golden[3] == 32'hA0130203,
            "reference uses distinct words throughout each complete group");
        cases_done = cases_done + 2;

        $display("CASE T05: byte lanes and fully masked sentinel preservation");
        write_group(21'd64, 32'h11223340, 4'h0, 0);
        write_group(21'd64, 32'hAABBCCD0, 4'hE, 0);
        chk(golden[64] == 32'h112233D0, "DM=1110 changes only byte zero");
        write_group(21'd64, 32'hAABBCCD0, 4'h7, 0);
        chk(golden[64] == 32'hAA2233D0, "DM=0111 changes only byte three");
        write_group(21'd64, 32'hDEADBEE0, 4'hF, 0);
        read_group(21'd64, 0);
        drain_reads;
        chk(golden[64] == 32'hAA2233D0 && golden[67] == 32'hAA2233D3,
            "DM=1111 preserves all four sentinel words");
        cases_done = cases_done + 1;

        $display("CASE T06/T07: refresh rejects writes and reads without changing group phase");
        fast_write_group(21'd200, 32'h55667780);
        fast_read_group(21'd200);
        drain_reads;
        guard = 0;
        while (!f_ref_vld && guard < FAST_REFRESH + 32) begin
            @(negedge clk);
            guard = guard + 1;
        end
        chk(f_ref_vld, "reach fast refresh window within bound");
        before_reads = f_reads;
        before_writes = f_writes;
        f_wr_en = 1'b1;
        f_wr_addr = 21'd200;
        f_wr_din = 32'hBAD0BAD0;
        f_wr_dm = 4'h0;
        f_rd_en = 1'b1;
        f_rd_addr = 21'd200;
        repeat (2) @(negedge clk);
        chk(f_ref_vld, "injected commands remain entirely inside refresh window");
        f_wr_en = 1'b0;
        f_rd_en = 1'b0;
        repeat (RD_LATENCY + 4) @(negedge clk);
        chk(f_reads == before_reads && f_writes == before_writes,
            "refresh accepts neither injected read nor injected write");
        fast_read_group(21'd200);
        drain_reads;
        cases_done = cases_done + 2;

        $display("CASE T08: repeated refresh windows have exactly eight clocks");
        windows_before = f_ref_windows;
        repeat (FAST_REFRESH * 3 + REF_VLD_CYCLES * 4) @(negedge clk);
        chk(f_ref_windows - windows_before >= 2, "at least two complete refresh windows observed");
        cases_done = cases_done + 1;

        $display("CASE T09: full memory scan, sequential-address compatibility, and boundary");
        for (i = 0; i < MEM_WORDS; i = i + 4)
            write_group(i, 32'h61000000 + i * 7, 4'h0, 1);
        for (i = 0; i < MEM_WORDS; i = i + 4)
            read_group(i, 1);
        drain_reads;
        chk(wr_phase == 0 && rd_phase == 0, "scan ends only on complete four-beat groups");
        cases_done = cases_done + 1;

        $display("CASE T10: reset cancels old read pipeline and reinitializes");
        read_group(21'd300, 0);
        reset_and_init;
        repeat (RD_LATENCY + 2) @(negedge clk);
        chk(!sdr_rd_en && q_head == q_tail, "reset does not leak old in-flight returns");
        fast_write_group(21'd200, 32'h55667780);
        fast_read_group(21'd200);
        write_group(21'd300, 32'h78102030, 4'h0, 0);
        read_group(21'd300, 0);
        drain_reads;
        cases_done = cases_done + 1;

        $display("CASE T11: group-start base is locked despite later address changes");
        write_group(21'd512, 32'h9A102030, 4'h0, 2);
        read_group(21'd512, 2);
        write_group(21'd516, 32'hAB203040, 4'h0, 0);
        read_group(21'd516, 0);
        drain_reads;
        cases_done = cases_done + 1;

        $display("CASE T12: long refresh parameter is not truncated to sixteen bits");
        guard = 0;
        while (ref_windows == 0 && guard < REFRESH_PERIOD + INIT_CYCLES + 32) begin
            @(negedge clk);
            guard = guard + 1;
        end
        chk(ref_windows >= 1, "main long-period refresh eventually completes");
        chk(first_ref_cycle >= REFRESH_PERIOD,
            "70000-clock refresh does not occur at truncated 4464-clock interval");
        chk(first_ref_cycle <= REFRESH_PERIOD + INIT_CYCLES + 4,
            "long-period refresh occurs within documented initialization allowance");
        cases_done = cases_done + 1;

        drain_reads;
        chk(cases_done == 12, "all twelve required test cases completed");
        chk(checks > 0 && reads > 0 && f_reads > 0, "self-checks and both data paths were exercised");
        $display("SUMMARY: checks=%0d errors=%0d cases=%0d", checks, errors, cases_done);
        if (errors == 0)
            $display("ALL CHECKS PASSED: tb_sdram_ctrl_wrap");
        else
            $display("FAILED: tb_sdram_ctrl_wrap errors=%0d", errors);
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: tb_sdram_ctrl_wrap global timeout");
        $display("FAILED: tb_sdram_ctrl_wrap global timeout");
        $finish;
    end
endmodule
