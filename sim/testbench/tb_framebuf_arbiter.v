// =============================================================================
// tb_framebuf_arbiter.v — 以实际接受事件为中心的独立、自检测试平台
// =============================================================================
// FIFO 仅在 wr_ack 的上升沿消费队头；参考控制器仅在 app_*_en 有效时接受。
// 写/读组独立锁存首址并按四个接受拍推进；DM=1 屏蔽对应字节。
// 所有等待均有本地上限，另有全局 guard；失败绝不输出通过标记。
`timescale 1ns / 1ps

module tb_framebuf_arbiter;
    localparam ADDR_WIDTH = 21;
    localparam BUS_TURN_GAP = 2;
    localparam WR_STARVE_LIMIT = 32;
    localparam FRAME_BASE = 21'd0;
    localparam FRAME_WORDS = 256;
    localparam RD_LATENCY = 10;
    localparam RD_TIMEOUT = 1024;
    localparam MEM_WORDS = 1024;
    localparam FIFO_WORDS = 4096;
    localparam CLK_PERIOD = 6.667;

    reg clk = 1'b0;
    reg rst_n;
    reg sdr_init_done;
    reg ref_vld;
    reg wr_enable;
    wire wr_req;
    wire [31:0] wr_data;
    reg [3:0] wr_dm;
    wire wr_ack;
    reg rd_req;
    reg rd_restart;
    reg [ADDR_WIDTH-1:0] rd_base;
    wire [31:0] rd_data;
    wire rd_valid, rd_idle, rd_restart_done, rd_ack;
    wire app_wr_en, app_rd_en;
    wire [ADDR_WIDTH-1:0] app_wr_addr, app_rd_addr;
    wire [31:0] app_wr_din;
    wire [3:0] app_wr_dm;
    wire sdr_rd_en;
    wire [31:0] sdr_rd_dout;
    wire busy, err;

    reg [31:0] fifo_mem [0:FIFO_WORDS-1];
    integer fifo_tail = 0;
    integer fifo_used = 0;
    reg [31:0] sim_mem [0:MEM_WORDS-1];
    reg [1:0] model_wr_phase;
    reg [1:0] model_rd_phase;
    reg [ADDR_WIDTH-1:0] model_wr_base;
    reg [ADDR_WIDTH-1:0] model_rd_base;
    wire [ADDR_WIDTH-1:0] model_wr_effective;
    wire [ADDR_WIDTH-1:0] model_rd_effective;
    reg [RD_LATENCY-1:0] read_pipe_valid;
    reg [31:0] read_pipe_data [0:RD_LATENCY-1];
    reg drop_returns;
    reg inject_return;
    reg allow_err;
    integer model_index;

    integer checks = 0;
    integer errors = 0;
    integer cases_done = 0;
    integer cycle_count = 0;
    integer wr_cmds = 0;
    integer rd_cmds = 0;
    integer rd_acks = 0;
    integer rd_returns = 0;
    integer delivered = 0;
    integer padded_writes = 0;
    integer done_count = 0;
    integer expected_outstanding = 0;
    integer max_outstanding = 0;
    integer expected_wr_addr = 0;
    integer expected_rd_addr = 0;
    integer last_direction = 0;
    integer command_gap = 0;
    integer captured_restart_base = 0;
    reg restart_pending_reference = 1'b0;
    reg sampled_return;
    reg sampled_read;
    reg sampled_spurious;
    reg sampled_fault;
    reg [31:0] sampled_data;
    integer i, guard, snapshot, snapshot2;
    reg [31:0] lfsr;

    always #(CLK_PERIOD / 2.0) clk = ~clk;
    assign wr_req = wr_enable && (fifo_used < fifo_tail);
    assign wr_data = (fifo_used < fifo_tail && fifo_used < FIFO_WORDS)
                     ? fifo_mem[fifo_used] : 32'd0;
    assign model_wr_effective = (model_wr_phase == 0)
                               ? app_wr_addr : model_wr_base + model_wr_phase;
    assign model_rd_effective = (model_rd_phase == 0)
                               ? app_rd_addr : model_rd_base + model_rd_phase;
    assign sdr_rd_en = inject_return || (!drop_returns && read_pipe_valid[0]);
    assign sdr_rd_dout = inject_return ? 32'hBAD0CAFE : read_pipe_data[0];

    framebuf_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH), .BUS_TURN_GAP(BUS_TURN_GAP),
        .WR_STARVE_LIMIT(WR_STARVE_LIMIT), .RD_TIMEOUT(RD_TIMEOUT), .FRAME_BASE(FRAME_BASE),
        .FRAME_WORDS(FRAME_WORDS)
    ) dut (
        .clk(clk), .rst_n(rst_n), .sdr_init_done(sdr_init_done), .ref_vld(ref_vld),
        .wr_req(wr_req), .wr_data(wr_data), .wr_dm(wr_dm), .wr_ack(wr_ack),
        .wr_word_addr(21'd0),
        .rd_req(rd_req), .rd_data(rd_data), .rd_valid(rd_valid), .rd_ack(rd_ack),
        .rd_restart(rd_restart), .rd_base(rd_base),
        .rd_idle(rd_idle), .rd_restart_done(rd_restart_done),
        .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
        .app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
        .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout), .busy(busy), .err(err)
    );

    task chk;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                if (errors <= 60)
                    $display("FAIL: %0s (t=%0t)", message, $time);
            end
        end
    endtask

    // 独立 ERAM 参考模型：只计算实际接受拍，不使用 dut.wr_fire/rd_fire。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_used <= 0;
            model_wr_phase <= 2'd0;
            model_rd_phase <= 2'd0;
            model_wr_base <= FRAME_BASE;
            model_rd_base <= FRAME_BASE;
            read_pipe_valid <= {RD_LATENCY{1'b0}};
            for (model_index = 0; model_index < RD_LATENCY; model_index = model_index + 1)
                read_pipe_data[model_index] <= 32'd0;
            for (model_index = 0; model_index < MEM_WORDS; model_index = model_index + 1)
                sim_mem[model_index] <= 32'hD00D0000 + model_index;
        end else begin
            if (wr_ack) fifo_used <= fifo_used + 1;
            read_pipe_valid[RD_LATENCY-1] <= app_rd_en && sdr_init_done && !ref_vld;
            for (model_index = 0; model_index < RD_LATENCY-1; model_index = model_index + 1) begin
                read_pipe_valid[model_index] <= read_pipe_valid[model_index+1];
                read_pipe_data[model_index] <= read_pipe_data[model_index+1];
            end
            if (app_wr_en && sdr_init_done && !ref_vld) begin
                if (model_wr_phase == 0) model_wr_base <= app_wr_addr;
                if (!app_wr_dm[0]) sim_mem[model_wr_effective % MEM_WORDS][7:0] <= app_wr_din[7:0];
                if (!app_wr_dm[1]) sim_mem[model_wr_effective % MEM_WORDS][15:8] <= app_wr_din[15:8];
                if (!app_wr_dm[2]) sim_mem[model_wr_effective % MEM_WORDS][23:16] <= app_wr_din[23:16];
                if (!app_wr_dm[3]) sim_mem[model_wr_effective % MEM_WORDS][31:24] <= app_wr_din[31:24];
                model_wr_phase <= model_wr_phase + 1'b1;
            end
            if (app_rd_en && sdr_init_done && !ref_vld) begin
                if (model_rd_phase == 0) model_rd_base <= app_rd_addr;
                read_pipe_data[RD_LATENCY-1] <= sim_mem[model_rd_effective % MEM_WORDS];
                model_rd_phase <= model_rd_phase + 1'b1;
            end
        end
    end

    // 输入在下降沿驱动；先采接受事件，再在 NBA 后核对注册输出，避免竞态。
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle_count = 0;
            wr_cmds = 0;
            rd_cmds = 0;
            rd_acks = 0;
            rd_returns = 0;
            delivered = 0;
            padded_writes = 0;
            done_count = 0;
            expected_outstanding = 0;
            max_outstanding = 0;
            expected_wr_addr = FRAME_BASE;
            expected_rd_addr = FRAME_BASE;
            captured_restart_base = FRAME_BASE;
            restart_pending_reference = 1'b0;
            last_direction = 0;
            command_gap = 0;
        end else begin
            cycle_count = cycle_count + 1;
            sampled_return = sdr_rd_en;
            sampled_fault = err;
            sampled_data = sdr_rd_dout;
            sampled_read = app_rd_en;
            sampled_spurious = inject_return && expected_outstanding == 0 && !app_rd_en;
            chk(!(app_wr_en && app_rd_en), "read and write commands never overlap");
            if (!app_wr_en)
                chk(app_wr_dm === 4'h0,
                    "read and idle cycles leave SDRAM DQM unmasked, including return drain");
            if (!sdr_init_done || ref_vld)
                chk(!app_wr_en && !app_rd_en && !wr_ack && !rd_ack,
                    "no command or FIFO acceptance during init/refresh, including its first cycle");
            chk(wr_ack === (app_wr_en && wr_req), "wr_ack equals same-cycle real FIFO write acceptance");
            chk(rd_ack === (app_rd_en && model_rd_phase == 0),
                "rd_ack denotes exactly an accepted read-group first beat");
            if (rd_ack) rd_acks = rd_acks + 1;
            if (rd_restart) begin
                captured_restart_base = rd_base;
                restart_pending_reference = 1'b1;
            end
            if (app_wr_en) begin
                chk(model_rd_phase == 0, "write cannot interrupt a partial read group");
                chk(expected_outstanding == 0, "write waits until every outstanding read has returned");
                chk(app_wr_addr[1:0] == 2'b00, "arbiter presents aligned constant write-group base");
                if (model_wr_phase == 0)
                    chk(app_wr_addr == expected_wr_addr, "write group address advances by four and wraps at frame end");
                else
                    chk(app_wr_addr == model_wr_base, "write address remains locked inside a group");
                if (wr_ack) begin
                    chk(app_wr_din === fifo_mem[fifo_used], "accepted write data is the current FIFO head");
                    chk(app_wr_dm === wr_dm, "real write preserves the requested DM");
                end else begin
                    padded_writes = padded_writes + 1;
                    chk(app_wr_dm === 4'hF, "make-up write masks all byte lanes");
                end
                if (model_wr_phase == 3) begin
                    if (expected_wr_addr + 4 >= FRAME_BASE + FRAME_WORDS)
                        expected_wr_addr = FRAME_BASE;
                    else expected_wr_addr = expected_wr_addr + 4;
                end
                if (last_direction == 2)
                    chk(command_gap >= BUS_TURN_GAP, "read-to-write turnaround observes configured gap");
                last_direction = 1;
                command_gap = 0;
                wr_cmds = wr_cmds + 1;
            end else if (app_rd_en) begin
                chk(model_wr_phase == 0, "read cannot interrupt a partial write group");
                chk(app_rd_addr[1:0] == 2'b00, "arbiter presents aligned constant read-group base");
                if (model_rd_phase == 0)
                    chk(app_rd_addr == expected_rd_addr, "read starts at expected sequential or captured restart base");
                else chk(app_rd_addr == model_rd_base, "read address remains locked inside a group");
                if (model_rd_phase == 3) begin
                    if (expected_rd_addr + 4 >= captured_restart_base + FRAME_WORDS)
                        expected_rd_addr = captured_restart_base;
                    else expected_rd_addr = expected_rd_addr + 4;
                end
                if (last_direction == 1)
                    chk(command_gap >= BUS_TURN_GAP, "write-to-read turnaround observes configured gap");
                last_direction = 2;
                command_gap = 0;
                rd_cmds = rd_cmds + 1;
            end else command_gap = command_gap + 1;
            if (app_rd_en) expected_outstanding = expected_outstanding + 1;
            if (sdr_rd_en) begin
                rd_returns = rd_returns + 1;
                if (expected_outstanding > 0) expected_outstanding = expected_outstanding - 1;
            end
            if (expected_outstanding > max_outstanding) max_outstanding = expected_outstanding;
            chk(expected_outstanding <= 31, "read credit count never exceeds five-bit capacity");
            #1;
            chk(dut.rd_outstanding === expected_outstanding[4:0],
                "outstanding equals actual accepted commands minus actual returns without wrap");
            if (!sampled_spurious) begin
                chk(rd_valid === (sampled_return && !sampled_fault),
                    "registered returns are valid only before a latched protocol fault");
                if (sampled_return && !sampled_fault) begin
                    chk(rd_data === sampled_data, "rd_data is aligned with the registered return event");
                    delivered = delivered + 1;
                end
            end
            if (expected_outstanding > 0 || rd_valid)
                chk(!rd_idle, "read side never advertises idle with in-flight data or valid output");
            if (rd_restart_done) begin
                done_count = done_count + 1;
                chk(restart_pending_reference, "restart_done acknowledges a captured restart request");
                chk(!sampled_read && expected_outstanding == 0 && !rd_valid && model_rd_phase == 0,
                    "restart executes only after complete group and all return/output drain");
                expected_rd_addr = captured_restart_base;
                restart_pending_reference = 1'b0;
            end
            if (!allow_err) chk(err === 1'b0, "normal traffic never raises scheduler error");
        end
    end

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            sdr_init_done = 1'b0;
            ref_vld = 1'b0;
            wr_enable = 1'b0;
            wr_dm = 4'h0;
            rd_req = 1'b0;
            rd_restart = 1'b0;
            rd_base = FRAME_BASE;
            fifo_tail = 0;
            drop_returns = 1'b0;
            inject_return = 1'b0;
            allow_err = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task fill_words;
        input integer count;
        input [31:0] first_word;
        integer word_index;
        begin
            chk(fifo_tail + count <= FIFO_WORDS, "source FIFO fill stays within bounded storage");
            for (word_index = 0; word_index < count; word_index = word_index + 1) begin
                if (fifo_tail < FIFO_WORDS) begin
                    fifo_mem[fifo_tail] = first_word + word_index;
                    fifo_tail = fifo_tail + 1;
                end
            end
        end
    endtask

    task wait_written;
        input integer target;
        input integer limit;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (fifo_used < target && wait_cycles < limit) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            chk(fifo_used >= target, "FIFO write service completes within bounded wait");
        end
    endtask

    task wait_reads;
        input integer target;
        input integer limit;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (rd_cmds < target && wait_cycles < limit) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            chk(rd_cmds >= target, "read command target completes within bounded wait");
        end
    endtask

    task wait_read_idle;
        input integer limit;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((!rd_idle || expected_outstanding != 0 || model_rd_phase != 0) && wait_cycles < limit) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            chk(rd_idle && expected_outstanding == 0 && model_rd_phase == 0,
                "read groups and returns drain to true idle within bound");
        end
    endtask

    task wait_restart;
        input integer target;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (done_count < target && wait_cycles < 256) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            chk(done_count >= target, "captured restart completes within bounded drain time");
        end
    endtask

    initial begin
        rst_n = 1'b0;
        sdr_init_done = 1'b0;
        ref_vld = 1'b0;
        wr_enable = 1'b0;
        wr_dm = 4'h0;
        rd_req = 1'b0;
        rd_restart = 1'b0;
        rd_base = FRAME_BASE;
        drop_returns = 1'b0;
        inject_return = 1'b0;
        allow_err = 1'b0;
        lfsr = 32'hCEFA1234;

        $display("CASE T01: reset and initialization block all acceptances");
        do_reset;
        fill_words(8, 32'h10000000);
        wr_enable = 1'b1;
        rd_req = 1'b1;
        repeat (12) @(negedge clk);
        chk(wr_cmds == 0 && rd_cmds == 0 && fifo_used == 0,
            "uninitialized controller cannot consume FIFO or accept a command");
        cases_done = cases_done + 1;

        $display("CASE T02: exactly four writes preserve FIFO order and data");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(4, 32'h20102030);
        wr_enable = 1'b1;
        wait_written(4, 128);
        wr_enable = 1'b0;
        repeat (12) @(negedge clk);
        chk(wr_cmds == 4 && padded_writes == 0, "one full FIFO group produces four real writes");
        for (i = 0; i < 4; i = i + 1)
            chk(sim_mem[i] === (32'h20102030 + i), "four distinct FIFO words reach four distinct addresses");
        cases_done = cases_done + 1;

        $display("CASE T03: one requested read group has one ack and four valid returns");
        do_reset;
        sdr_init_done = 1'b1;
        rd_req = 1'b1;
        wait_reads(1, 128);
        rd_req = 1'b0;
        wait_read_idle(128);
        chk(rd_cmds == 4 && rd_acks == 1 && delivered == 4,
            "request withdrawal completes existing group without starting another");
        cases_done = cases_done + 1;

        $display("CASE T04: read initially wins simultaneous requests");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(64, 32'h30405060);
        wr_enable = 1'b1;
        rd_req = 1'b1;
        repeat (6) @(negedge clk);
        chk(rd_cmds > 0 && wr_cmds == 0, "initial arbitration grants read priority");
        rd_req = 1'b0;
        wait_written(4, 256);
        wr_enable = 1'b0;
        repeat (32) @(negedge clk);
        wait_read_idle(128);
        cases_done = cases_done + 1;

        $display("CASE T05: real returning continuous reads cannot starve writes");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(16, 32'h40506070);
        wr_enable = 1'b1;
        rd_req = 1'b1;
        wait_written(1, WR_STARVE_LIMIT + RD_LATENCY * 3 + 32);
        chk(rd_returns > 0 && rd_cmds > 0, "starvation case includes real returns, not a stuck controller");
        chk(cycle_count < RD_TIMEOUT && !err, "write service occurs before any timeout recovery");
        rd_req = 1'b0;
        wait_written(16, 256);
        wr_enable = 1'b0;
        wait_read_idle(128);
        cases_done = cases_done + 1;

        $display("CASE T06: refresh first cycle rejects both command types");
        do_reset;
        sdr_init_done = 1'b1;
        ref_vld = 1'b1;
        fill_words(8, 32'h50607080);
        wr_enable = 1'b1;
        rd_req = 1'b1;
        repeat (16) @(negedge clk);
        chk(wr_cmds == 0 && rd_cmds == 0 && fifo_used == 0, "refresh never consumes an unaccepted FIFO word");
        ref_vld = 1'b0;
        repeat (64) @(negedge clk);
        chk(wr_cmds + rd_cmds > 0, "traffic resumes after refresh");
        rd_req = 1'b0;
        wr_enable = 1'b0;
        repeat (48) @(negedge clk);
        wait_read_idle(128);
        cases_done = cases_done + 1;

        $display("CASE T07: refresh after two writes loses no FIFO word or group beat");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(8, 32'h60708090);
        wr_enable = 1'b1;
        wait_written(2, 128);
        ref_vld = 1'b1;
        snapshot = wr_cmds;
        repeat (8) @(negedge clk);
        chk(snapshot == 2 && wr_cmds == snapshot && fifo_used == 2,
            "refresh freezes exact accepted write count from its rising edge");
        ref_vld = 1'b0;
        wait_written(8, 128);
        wr_enable = 1'b0;
        repeat (12) @(negedge clk);
        chk(wr_cmds == 8 && model_wr_phase == 0, "both write groups finish exactly once after pause");
        for (i = 0; i < 8; i = i + 1)
            chk(sim_mem[i] === (32'h60708090 + i), "refresh preserves FIFO word-to-address mapping");
        cases_done = cases_done + 1;

        $display("CASE T08: refresh pauses partial read issue while existing returns drain");
        do_reset;
        sdr_init_done = 1'b1;
        rd_req = 1'b1;
        wait_reads(2, 128);
        ref_vld = 1'b1;
        rd_req = 1'b0;
        snapshot = rd_cmds;
        repeat (8) @(negedge clk);
        chk(snapshot == 2 && rd_cmds == snapshot, "refresh freezes partial read issue count immediately");
        ref_vld = 1'b0;
        wait_read_idle(128);
        chk(rd_cmds == 4 && rd_acks == 1 && delivered == 4,
            "read pause neither creates a fake ack nor loses a return");
        cases_done = cases_done + 1;

        $display("CASE T09: write address wraps after one complete frame");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(FRAME_WORDS + 8, 32'h70809000);
        wr_enable = 1'b1;
        wait_written(FRAME_WORDS + 8, FRAME_WORDS * 4);
        wr_enable = 1'b0;
        repeat (12) @(negedge clk);
        chk(wr_cmds == FRAME_WORDS + 8, "wrap scan emits the exact number of words");
        for (i = 0; i < 8; i = i + 1)
            chk(sim_mem[i] === (32'h70809000 + FRAME_WORDS + i), "new frame overwrites only wrapped leading words");
        chk(sim_mem[8] === 32'h70809008 && sim_mem[255] === 32'h708090FF,
            "unwrapped frame words retain their original values");
        cases_done = cases_done + 1;

        $display("CASE T10: deterministic mixed request and refresh stress");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(512, 32'h80900000);
        wr_enable = 1'b1;
        for (i = 0; i < 512; i = i + 1) begin
            @(negedge clk);
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            rd_req = lfsr[0];
            ref_vld = (lfsr[4:1] == 4'd0);
        end
        rd_req = 1'b0;
        wr_enable = 1'b0;
        ref_vld = 1'b0;
        repeat (64) @(negedge clk);
        wait_read_idle(128);
        chk(wr_cmds > 0 && rd_cmds > 0 && rd_returns > 0, "stress exercises both directions and real returns");
        chk(model_wr_phase == 0 && model_rd_phase == 0, "stress finishes all partial groups");
        cases_done = cases_done + 1;

        $display("CASE T11: healthy continuous read lasts more than twice RD_TIMEOUT");
        do_reset;
        sdr_init_done = 1'b1;
        rd_req = 1'b1;
        repeat (RD_TIMEOUT * 2 + 64) @(negedge clk);
        chk(rd_cmds > RD_TIMEOUT && rd_returns > RD_TIMEOUT,
            "long stream has both issues and returns beyond timeout threshold");
        chk(!err, "progressing long stream never trips no-return watchdog");
        rd_req = 1'b0;
        wait_read_idle(128);
        chk(rd_cmds % 4 == 0 && rd_acks * 4 == rd_cmds,
            "long stream acknowledgments exactly count complete groups");
        cases_done = cases_done + 1;

        $display("CASE T12: make-up DM=F and real masked writes preserve sentinel");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(2, 32'h90A0B0C0);
        wr_enable = 1'b1;
        wait_written(2, 128);
        wr_enable = 1'b0;
        repeat (16) @(negedge clk);
        chk(wr_cmds == 4 && padded_writes == 2 && fifo_used == 2,
            "short source consumes only real data and pads the complete group");
        chk(sim_mem[0] === 32'h90A0B0C0 && sim_mem[1] === 32'h90A0B0C1, "real source words are written without shift");
        chk(sim_mem[2] === 32'hD00D0002 && sim_mem[3] === 32'hD00D0003,
            "masked make-up beats do not overwrite sentinel memory");
        do_reset;
        sdr_init_done = 1'b1;
        fill_words(4, 32'hFFFFFFFF);
        wr_dm = 4'hF;
        wr_enable = 1'b1;
        wait_written(4, 128);
        wr_enable = 1'b0;
        repeat (12) @(negedge clk);
        for (i = 0; i < 4; i = i + 1)
            chk(sim_mem[i] === (32'hD00D0000 + i), "real DM=F writes also preserve sentinel bytes");
        cases_done = cases_done + 1;

        $display("CASE T13: captured restart finishes old group, drains, and emits no fake ack");
        do_reset;
        sdr_init_done = 1'b1;
        rd_req = 1'b1;
        wait_reads(1, 128);
        rd_restart = 1'b1;
        rd_base = 21'd64;
        @(negedge clk);
        rd_restart = 1'b0;
        rd_base = 21'd128;
        wait_restart(1);
        chk(rd_cmds == 4 && rd_acks == 1 && expected_outstanding == 0,
            "restart finishes and drains only original group before done");
        wait_reads(5, 128);
        rd_req = 1'b0;
        wait_read_idle(128);
        chk(rd_cmds == 8 && rd_acks == 2 && done_count == 1, "captured-base restart begins one complete new group");
        do_reset;
        sdr_init_done = 1'b1;
        rd_req = 1'b1;
        @(negedge clk);
        rd_restart = 1'b1;
        rd_base = 21'd96;
        #1;
        chk(!app_rd_en && !rd_ack, "boundary restart cannot advertise a discarded command");
        @(negedge clk);
        rd_restart = 1'b0;
        rd_base = 21'd128;
        wait_restart(1);
        chk(rd_cmds == 0 && rd_acks == 0, "boundary restart acknowledges no old-base group");
        wait_reads(1, 128);
        rd_req = 1'b0;
        wait_read_idle(128);
        chk(rd_cmds == 4 && rd_acks == 1, "actual first group after boundary restart has one ack");
        cases_done = cases_done + 1;

        $display("CASE T14: timeout keeps outstanding and blocks reads until reset");
        do_reset;
        sdr_init_done = 1'b1;
        drop_returns = 1'b1;
        allow_err = 1'b1;
        rd_req = 1'b1;
        repeat (64) @(negedge clk);
        chk(rd_cmds == 28 && max_outstanding == 28,
            "whole-group credit reserve accepts twenty-eight words without saturation loss");
        chk(!err, "credit backpressure alone does not immediately trigger timeout");
        guard = 0;
        while (!err && guard < RD_TIMEOUT + 64) begin
            @(negedge clk);
            guard = guard + 1;
        end
        chk(err, "missing returns trigger bounded watchdog error");
        chk(expected_outstanding == 28 && dut.rd_outstanding == 28 && !rd_idle,
            "timeout preserves all unreturned reads and cannot fake idle");
        snapshot = rd_cmds;
        repeat (32) @(negedge clk);
        chk(rd_cmds == snapshot && !rd_idle, "latched timeout blocks subsequent read commands");
        snapshot2 = expected_outstanding;
        inject_return = 1'b1;
        @(negedge clk);
        inject_return = 1'b0;
        chk(expected_outstanding == snapshot2 - 1 && !rd_idle,
            "late return reclaims one credit without pretending complete drain");
        repeat (16) @(negedge clk);
        chk(rd_cmds == snapshot && err, "late return does not clear fault or restart traffic");
        do_reset;
        sdr_init_done = 1'b1;
        rd_req = 1'b1;
        wait_reads(1, 128);
        rd_req = 1'b0;
        wait_read_idle(128);
        chk(!err && delivered == 4, "system reset recovers after a latched read timeout");
        cases_done = cases_done + 1;

        $display("CASE T15: unsolicited return at zero cannot underflow outstanding");
        do_reset;
        sdr_init_done = 1'b1;
        allow_err = 1'b1;
        inject_return = 1'b1;
        @(negedge clk);
        inject_return = 1'b0;
        chk(err && expected_outstanding == 0 && dut.rd_outstanding == 0,
            "zero-count return raises error and holds lower bound at zero");
        repeat (4) @(negedge clk);
        chk(dut.rd_outstanding == 0, "unsolicited return never wraps zero to thirty-one");
        cases_done = cases_done + 1;

        chk(cases_done == 15 && checks > 0, "all fifteen required self-check cases completed");
        $display("SUMMARY: checks=%0d errors=%0d cases=%0d", checks, errors, cases_done);
        if (errors == 0) $display("ALL CHECKS PASSED: tb_framebuf_arbiter");
        else $display("FAILED: tb_framebuf_arbiter errors=%0d", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: tb_framebuf_arbiter global timeout");
        $display("FAILED: tb_framebuf_arbiter global timeout");
        $finish;
    end
endmodule
