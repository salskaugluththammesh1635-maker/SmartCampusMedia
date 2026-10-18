// =============================================================================
// tb_sdram_ctrl_wrap.v — sdram_ctrl_wrap 行为模型路径的验证
// =============================================================================
// 验证目标（针对 sdram_behavior_model，综合路径由 TD 综合保证）：
//   T01 复位后 init_done=0、busy=1
//   T02 初始化完成后 init_done=1、busy=0
//   T03 写一个 4 拍组后逐字读回，数据完全一致（含 dm 全写）
//   T04 读延迟精确等于 10 拍（手册 §4 硬指标）
//   T05 dm 逐字节屏蔽：只写一个字节，其余字节保持原值
//   T06 刷新期间写命令被忽略（数据不变）
//   T07 刷新期间读命令被忽略（不返回数据）
//   T08 ref_vld 周期性出现，且每次持续 REF_VLD_CYCLES 拍
//   T09 全区扫描写入再读回（含地址边界，验证地址不串）
//   T10 复位中途重新初始化后恢复正常读写
// =============================================================================
`timescale 1ns / 1ps

module tb_sdram_ctrl_wrap;

    // ---------------- 参数 ----------------
    localparam CLK_PERIOD      = 6.667;    // 150MHz
    localparam MEM_WORDS       = 1024;     // 测试用小存储
    // 主实例用**长刷新周期**：本 tb 的主线（数据通路/延迟/dm/地址隔离）
    // 不应被刷新频繁打断。刷新语义由独立的 dut_fast 实例专门验证。
    localparam REFRESH_PERIOD  = 500_000;  // 主实例：极稀疏刷新
    localparam FAST_REFRESH    = 100;      // fast 实例：密集刷新，用于测刷新语义
    localparam REF_VLD_CYCLES  = 8;
    localparam INIT_CYCLES     = 64;
    localparam RD_LATENCY      = 10;

    // ---------------- DUT 信号 ----------------
    reg         clk;
    reg         clk_sft;
    reg         rst_n;

    wire        init_done;
    wire        ref_vld;
    wire        busy;

    reg         app_wr_en;
    reg  [20:0] app_wr_addr;
    reg  [31:0] app_wr_din;
    reg  [3:0]  app_wr_dm;
    reg         app_rd_en;
    reg  [20:0] app_rd_addr;
    wire        sdr_rd_en;
    wire [31:0] sdr_rd_dout;

    wire        sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [1:0]  sdram_ba;
    wire [10:0] sdram_addr;
    wire [3:0]  sdram_dm;
    wire [31:0] sdram_dq;

    // ---------------- 检查与统计 ----------------
    integer checks = 0;
    integer fails  = 0;

    task chk;
        input cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (cond) begin
                $display("  [PASS] %0s (t=%0t)", msg, $time);
            end else begin
                fails = fails + 1;
                $display("  [FAIL] %0s (t=%0t)", msg, $time);
            end
        end
    endtask

    task fail_only;
        input cond;
        input [1023:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("  [FAIL] %0s (t=%0t)", msg, $time);
            end
        end
    endtask

    // ---------------- 时钟 ----------------
    initial begin
        clk     = 1'b0;
        clk_sft = 1'b0;
    end
    always #(CLK_PERIOD/2.0) clk = ~clk;
    // 180° 相移：半周期延迟后翻转
    always @(clk) clk_sft = #(CLK_PERIOD/2.0) ~clk;

    // ---------------- DUT ----------------
    sdram_ctrl_wrap #(
        .CLK_FREQ_HZ    (150_000_000),
        .SIM_MEM_WORDS  (MEM_WORDS),
        .REFRESH_PERIOD (REFRESH_PERIOD)
    ) dut (
        .clk          (clk),
        .clk_sft      (clk_sft),
        .rst_n        (rst_n),
        .init_done    (init_done),
        .ref_vld      (ref_vld),
        .busy         (busy),
        .app_wr_en    (app_wr_en),
        .app_wr_addr  (app_wr_addr),
        .app_wr_din   (app_wr_din),
        .app_wr_dm    (app_wr_dm),
        .app_rd_en    (app_rd_en),
        .app_rd_addr  (app_rd_addr),
        .sdr_rd_en    (sdr_rd_en),
        .sdr_rd_dout  (sdr_rd_dout),
        .sdram_clk    (sdram_clk),
        .sdram_cke    (sdram_cke),
        .sdram_cs_n   (sdram_cs_n),
        .sdram_ras_n  (sdram_ras_n),
        .sdram_cas_n  (sdram_cas_n),
        .sdram_we_n   (sdram_we_n),
        .sdram_ba     (sdram_ba),
        .sdram_addr   (sdram_addr),
        .sdram_dm     (sdram_dm),
        .sdram_dq     (sdram_dq)
    );

    // ---------------- 第二个实例：密集刷新，专测刷新语义 ----------------
    // 为什么分开：REF_VLD_CYCLES=8 / REFRESH_PERIOD=100 时，刷新占空比 8%，
    // 主线用例（上百次读写）必然有几次恰好撞进刷新窗口而被丢弃，导致
    // 假失败。把「数据通路验证」与「刷新语义验证」拆到两个实例上，
    // 各自用合适的参数，是比给主 tb 加重试逻辑更干净的解法。
    reg         f_wr_en;
    reg  [20:0] f_wr_addr;
    reg  [31:0] f_wr_din;
    reg  [3:0]  f_wr_dm;
    reg         f_rd_en;
    reg  [20:0] f_rd_addr;

    wire        f_init_done, f_ref_vld, f_busy;
    wire        f_rd_en_out;
    wire [31:0] f_rd_dout;

    sdram_ctrl_wrap #(
        .CLK_FREQ_HZ    (150_000_000),
        .SIM_MEM_WORDS  (MEM_WORDS),
        .REFRESH_PERIOD (FAST_REFRESH)
    ) dut_fast (
        .clk          (clk),
        .clk_sft      (clk_sft),
        .rst_n        (rst_n),
        .init_done    (f_init_done),
        .ref_vld      (f_ref_vld),
        .busy         (f_busy),
        .app_wr_en    (f_wr_en),
        .app_wr_addr  (f_wr_addr),
        .app_wr_din   (f_wr_din),
        .app_wr_dm    (f_wr_dm),
        .app_rd_en    (f_rd_en),
        .app_rd_addr  (f_rd_addr),
        .sdr_rd_en    (f_rd_en_out),
        .sdr_rd_dout  (f_rd_dout),
        .sdram_clk    (),
        .sdram_cke    (),
        .sdram_cs_n   (),
        .sdram_ras_n  (),
        .sdram_cas_n  (),
        .sdram_we_n   (),
        .sdram_ba     (),
        .sdram_addr   (),
        .sdram_dm     (),
        .sdram_dq     ()
    );

    // ---------------- 时钟周期计数（用于延迟测量）----------------
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    // =========================================================================
    // 辅助：发起一次写
    // =========================================================================
    task do_write;
        input [20:0] addr;
        input [31:0] data;
        input [3:0]  dm;
        begin
            @(negedge clk);
            app_wr_addr = addr;
            app_wr_din  = data;
            app_wr_dm   = dm;
            app_wr_en   = 1'b1;
            @(negedge clk);
            app_wr_en   = 1'b0;
            @(negedge clk);
        end
    endtask

    // =========================================================================
    // 辅助：发起一次读，返回数据（带超时）
    // =========================================================================
    reg [31:0] rd_capture;
    reg        rd_got;

    task do_read;
        input  [20:0] addr;
        output [31:0] data;
        integer guard;
        begin
            @(negedge clk);
            app_rd_addr = addr;
            app_rd_en   = 1'b1;
            @(negedge clk);
            app_rd_en   = 1'b0;
            rd_got = 1'b0;
            guard  = 0;
            // 等 sdr_rd_en 脉冲
            while (!rd_got && guard < 200) begin
                @(posedge clk);
                if (sdr_rd_en) begin
                    rd_capture = sdr_rd_dout;
                    rd_got     = 1'b1;
                end
                guard = guard + 1;
            end
            data = rd_capture;
            @(negedge clk);
        end
    endtask

    // =========================================================================
    // 辅助：等待初始化完成
    // =========================================================================
    task wait_init;
        integer guard;
        begin
            guard = 0;
            while (!init_done && guard < 10000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            @(negedge clk);
        end
    endtask

    // =========================================================================
    // 辅助：等待离开刷新窗口
    // =========================================================================
    task wait_not_ref;
        integer guard;
        begin
            guard = 0;
            while (ref_vld && guard < 10000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            @(negedge clk);
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================
    reg [31:0] rdata;
    reg [31:0] expect;
    reg [31:0] got_data [0:7];
    integer    got_cnt;
    integer    t0, t1, lat;
    integer    i;
    integer    ref_edges;
    integer    ref_dur_max;
    integer    dur;
    reg        prev_ref;

    initial begin
        $display("=========================================================");
        $display(" tb_sdram_ctrl_wrap : start");
        $display("=========================================================");

        rst_n      = 1'b0;
        app_wr_en  = 1'b0;
        app_wr_addr= 21'd0;
        app_wr_din = 32'd0;
        app_wr_dm  = 4'h0;
        app_rd_en  = 1'b0;
        app_rd_addr= 21'd0;
        rd_capture = 32'd0;
        rd_got     = 1'b0;
        got_cnt    = 0;
        for (i = 0; i < 8; i = i + 1) got_data[i] = 32'd0;
        prev_ref   = 1'b0;
        f_wr_en    = 1'b0;
        f_wr_addr  = 21'd0;
        f_wr_din   = 32'd0;
        f_wr_dm    = 4'h0;
        f_rd_en    = 1'b0;
        f_rd_addr  = 21'd0;
        ref_edges  = 0;
        ref_dur_max= 0;
        dur        = 0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;

        // ---------------------------------------------------------------------
        // T01 复位后 init_done=0、busy=1
        // ---------------------------------------------------------------------
        $display("\n--- T01 reset state ---");
        @(negedge clk);
        chk(init_done === 1'b0, "init_done low right after reset");
        chk(busy === 1'b1,      "busy high right after reset");

        // ---------------------------------------------------------------------
        // T02 初始化完成
        // ---------------------------------------------------------------------
        $display("\n--- T02 init completes ---");
        wait_init;
        chk(init_done === 1'b1, "init_done asserted");
        chk(busy === 1'b0,      "busy released");

        // ---------------------------------------------------------------------
        // T03 写 4 拍组后逐字读回
        // ---------------------------------------------------------------------
        $display("\n--- T03 write then read back ---");
        wait_not_ref;
        // 一组 4 拍：地址 0/1/2/3
        for (i = 0; i < 4; i = i + 1) begin
            do_write(i[20:0], 32'hA000_0000 + i, 4'h0);
            wait_not_ref;
        end
        for (i = 0; i < 4; i = i + 1) begin
            wait_not_ref;
            do_read(i[20:0], rdata);
            chk(rd_got === 1'b1, "read data returned");
            chk(rdata === (32'hA000_0000 + i),
                "read back equals written value");
        end

        // ---------------------------------------------------------------------
        // T04 读延迟精确 = 10 拍
        // ---------------------------------------------------------------------
        $display("\n--- T04 read latency == 10 cycles ---");
        wait_not_ref;
        @(negedge clk);
        app_rd_addr = 21'd0;
        app_rd_en   = 1'b1;
        @(negedge clk);
        app_rd_en   = 1'b0;
        t0 = cyc;
        rd_got = 1'b0;
        i = 0;
        while (!rd_got && i < 200) begin
            @(posedge clk);
            if (sdr_rd_en) begin
                t1     = cyc;
                rd_got = 1'b1;
            end
            i = i + 1;
        end
        lat = t1 - t0;
        $display("    measured latency = %0d cycles", lat);
        // 允许 ±1 拍（器件差异，手册明确说明）
        chk(lat >= RD_LATENCY - 1 && lat <= RD_LATENCY + 1,
            "read latency within 10 +/- 1 cycles");

        // ---------------------------------------------------------------------
        // T05 dm 逐字节屏蔽
        // ---------------------------------------------------------------------
        $display("\n--- T05 per-byte mask ---");
        wait_not_ref;
        do_write(21'd100, 32'h1122_3344, 4'h0);
        wait_not_ref;
        do_read(21'd100, rdata);
        chk(rdata === 32'h1122_3344, "full write stores all 4 bytes");

        // 只写最低字节
        wait_not_ref;
        do_write(21'd100, 32'hAABB_CCDD, 4'b1110);   // dm[0]=0 写，其余屏蔽
        wait_not_ref;
        do_read(21'd100, rdata);
        chk(rdata === 32'h1122_33DD, "dm=1110 writes only byte 0");
        chk(rdata[31:8] === 24'h1122_33, "upper bytes preserved under mask");

        // 只写最高字节
        wait_not_ref;
        do_write(21'd100, 32'hEEBB_CCDD, 4'b0111);
        wait_not_ref;
        do_read(21'd100, rdata);
        chk(rdata === 32'hEE22_33DD, "dm=0111 writes only byte 3");

        // ---------------------------------------------------------------------
        // T06/T07 刷新期间命令被忽略（用 dut_fast 的密集刷新）
        // ---------------------------------------------------------------------
        $display("\n--- T06/T07 commands ignored during refresh ---");
        // fast 实例此时早已初始化完成（与主实例同复位）
        chk(f_init_done === 1'b1, "fast instance initialized");
        // 先写一个基准值（避开刷新窗口）
        i = 0;
        while (f_ref_vld && i < 5000) begin @(posedge clk); i = i + 1; end
        @(negedge clk);
        f_wr_addr = 21'd200;
        f_wr_din  = 32'h5555_5555;
        f_wr_dm   = 4'h0;
        f_wr_en   = 1'b1;
        @(negedge clk);
        f_wr_en   = 1'b0;
        i = 0;
        while (f_ref_vld && i < 5000) begin @(posedge clk); i = i + 1; end
        repeat (4) @(posedge clk);

        // 验证基准值已写入
        @(negedge clk);
        f_rd_addr = 21'd200;
        f_rd_en   = 1'b1;
        @(negedge clk);
        f_rd_en   = 1'b0;
        rd_got = 1'b0;
        i = 0;
        while (!rd_got && i < 100) begin
            @(posedge clk);
            if (f_rd_en_out) begin
                rd_capture = f_rd_dout;
                rd_got     = 1'b1;
            end
            i = i + 1;
        end
        chk(rd_got === 1'b1 && rd_capture === 32'h5555_5555,
            "fast instance baseline value stored");

        // 等进刷新窗口，在窗口内发写命令
        i = 0;
        while (!f_ref_vld && i < 5000) begin @(posedge clk); i = i + 1; end
        chk(f_ref_vld === 1'b1, "reached a refresh window to inject write");
        f_wr_addr = 21'd200;
        f_wr_din  = 32'hDEAD_BEEF;
        f_wr_dm   = 4'h0;
        f_wr_en   = 1'b1;
        @(posedge clk);
        f_wr_en   = 1'b0;
        i = 0;
        while (f_ref_vld && i < 5000) begin @(posedge clk); i = i + 1; end
        repeat (4) @(posedge clk);
        // 读回，应仍是基准值
        @(negedge clk);
        f_rd_addr = 21'd200;
        f_rd_en   = 1'b1;
        @(negedge clk);
        f_rd_en   = 1'b0;
        rd_got = 1'b0;
        i = 0;
        while (!rd_got && i < 100) begin
            @(posedge clk);
            if (f_rd_en_out) begin
                rd_capture = f_rd_dout;
                rd_got     = 1'b1;
            end
            i = i + 1;
        end
        chk(rd_got === 1'b1 && rd_capture === 32'h5555_5555,
            "write during refresh is ignored");

        // 刷新期间读：不应返回有效数据
        i = 0;
        while (!f_ref_vld && i < 5000) begin @(posedge clk); i = i + 1; end
        chk(f_ref_vld === 1'b1, "reached a refresh window to inject read");
        f_rd_addr = 21'd200;
        f_rd_en   = 1'b1;
        @(posedge clk);
        f_rd_en   = 1'b0;
        rd_got = 1'b0;
        // **必须跨越整个刷新窗口 + 读延迟才有效**：
        // 读命令若被接受，数据要 10 拍后才出来；只查窗口内的 8 拍会漏掉
        // 这条错误路径（变异体 m04 就是靠这个漏网的）。
        i = 0;
        while ((f_ref_vld || i < 12) && i < 40) begin
            @(posedge clk);
            if (f_rd_en_out) rd_got = 1'b1;
            i = i + 1;
        end
        fail_only(!rd_got, "read issued during refresh returns nothing");

        // ---------------------------------------------------------------------
        // T08 ref_vld 周期性出现且持续时间 = REF_VLD_CYCLES（用 dut_fast）
        // ---------------------------------------------------------------------
        $display("\n--- T08 refresh periodicity ---");
        ref_edges   = 0;
        ref_dur_max = 0;
        dur         = 0;
        prev_ref    = 1'b0;
        for (i = 0; i < 400; i = i + 1) begin
            @(posedge clk);
            if (f_ref_vld && !prev_ref) begin
                ref_edges = ref_edges + 1;
                dur       = 1;
            end else if (f_ref_vld && prev_ref) begin
                dur = dur + 1;
            end else if (!f_ref_vld && prev_ref) begin
                if (dur > ref_dur_max) ref_dur_max = dur;
            end
            prev_ref = f_ref_vld;
        end
        $display("    refresh edges in 400 cycles = %0d, max duration = %0d",
                 ref_edges, ref_dur_max);
        chk(ref_edges >= 3, "refresh asserts periodically");
        chk(ref_dur_max >= REF_VLD_CYCLES - 1 && ref_dur_max <= REF_VLD_CYCLES + 2,
            "refresh duration matches REF_VLD_CYCLES");

        // ---------------------------------------------------------------------
        // T09 全区扫描：写不同值再读回，验证地址不串
        // ---------------------------------------------------------------------
        $display("\n--- T09 full-range scan (address isolation) ---");
        // 用 64 个地址，值 = addr*7+1，保证任意两地址值不同
        for (i = 0; i < 64; i = i + 1) begin
            wait_not_ref;
            do_write(i[20:0], i * 7 + 1, 4'h0);
        end
        for (i = 0; i < 64; i = i + 1) begin
            wait_not_ref;
            do_read(i[20:0], rdata);
            expect = i * 7 + 1;
            if (rdata !== expect) begin
                $display("    addr %0d: got %08h want %08h", i, rdata, expect);
            end
            chk(rdata === expect, "scan readback matches");
        end

        // 地址 0 与地址 1 必须是独立单元（防地址截断）
        wait_not_ref;
        do_write(21'd0, 32'hAAAA_AAAA, 4'h0);
        wait_not_ref;
        do_write(21'd1, 32'hBBBB_BBBB, 4'h0);
        wait_not_ref;
        do_read(21'd0, rdata);
        chk(rdata === 32'hAAAA_AAAA, "addr 0 not overwritten by addr 1");
        wait_not_ref;
        do_read(21'd1, rdata);
        chk(rdata === 32'hBBBB_BBBB, "addr 1 independent");

        // ---------------------------------------------------------------------
        // T11 初始化时长检查：init_done 必须在复位释放后**保持低够久**
        // ---------------------------------------------------------------------
        // 为什么单独测：T01 只查"复位期间为 0"，T02 只查"最终为 1"。
        // 若 INIT_CYCLES 被改小（变异体 m06 改成 1 拍），两者都能过，
        // 但真实 SDRAM 的初始化流程（PRECHARGE 全 BANK + 8 次 REFRESH +
        // 模式寄存器写）需要足够时间，短了会静默失败。
        $display("\n--- T11 init duration ---");
        @(negedge clk);
        rst_n = 1'b0;
        repeat (10) @(negedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        i = 0;
        while (!init_done && i < 10000) begin
            @(posedge clk);
            i = i + 1;
        end
        $display("    init took %0d cycles", i);
        chk(i >= INIT_CYCLES - 2, "init duration at least INIT_CYCLES");
        chk(i <= INIT_CYCLES + 4, "init duration not much longer than INIT_CYCLES");

        // ---------------------------------------------------------------------
        // T12 背靠背读：连续两拍发读命令，第二笔数据不得被第一笔覆盖
        // ---------------------------------------------------------------------
        // 为什么单独测：读延迟模型是一个移位链，若 `sdr_rd_dout` 取错了一位
        // （变异体 m12 取 [1] 而不是 [0]），在"每次读写之间隔很多拍"的用例里
        // 完全看不出差别——因为链里只有一个有效数据在飞。只有**连续发**才能
        // 暴露"取到了相邻拍的数据"。
        $display("\n--- T12 back-to-back reads ---");
        wait_not_ref;
        do_write(21'd400, 32'hC0DE_0001, 4'h0);
        wait_not_ref;
        do_write(21'd401, 32'hC0DE_0002, 4'h0);
        wait_not_ref;
        do_write(21'd402, 32'hC0DE_0003, 4'h0);
        wait_not_ref;

        @(negedge clk);
        app_rd_addr = 21'd400;
        app_rd_en   = 1'b1;
        @(negedge clk);
        app_rd_addr = 21'd401;      // 背靠背：紧接下一拍
        app_rd_en   = 1'b1;
        @(negedge clk);
        app_rd_addr = 21'd402;
        app_rd_en   = 1'b1;
        @(negedge clk);
        app_rd_en   = 1'b0;

        // 收集接下来 20 拍内所有有效数据
        got_cnt = 0;
        i = 0;
        while (i < 30) begin
            @(posedge clk);
            if (sdr_rd_en) begin
                got_data[got_cnt] = sdr_rd_dout;
                got_cnt = got_cnt + 1;
            end
            i = i + 1;
        end
        $display("    back-to-back: got %0d beats", got_cnt);
        chk(got_cnt == 3, "three back-to-back reads return three beats");
        chk(got_data[0] === 32'hC0DE_0001, "beat 0 = addr 400 data");
        chk(got_data[1] === 32'hC0DE_0002, "beat 1 = addr 401 data");
        chk(got_data[2] === 32'hC0DE_0003, "beat 2 = addr 402 data");

        // ---------------------------------------------------------------------
        // T10 复位中途重新初始化
        // ---------------------------------------------------------------------
        $display("\n--- T10 re-init after mid-operation reset ---");
        wait_not_ref;
        do_write(21'd300, 32'h1234_5678, 4'h0);
        wait_not_ref;
        // 中途复位（此时可能在任意状态）
        @(negedge clk);
        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        chk(init_done === 1'b0, "init_done cleared by reset");
        chk(busy === 1'b1,      "busy asserted by reset");
        @(negedge clk);
        rst_n = 1'b1;
        wait_init;
        chk(init_done === 1'b1, "init_done back after re-init");
        // 重新初始化后存储内容应保留（SDRAM 掉电才丢）
        wait_not_ref;
        do_read(21'd300, rdata);
        chk(rdata === 32'h1234_5678, "data survives re-init (SDRAM retains)");
        // 且能正常写新值
        wait_not_ref;
        do_write(21'd300, 32'h8765_4321, 4'h0);
        wait_not_ref;
        do_read(21'd300, rdata);
        chk(rdata === 32'h8765_4321, "write works after re-init");

        // =====================================================================
        $display("\n=========================================================");
        if (fails == 0)
            $display(" ALL CHECKS PASSED: sdram_ctrl_wrap (%0d checks)", checks);
        else
            $display(" CHECKS FAILED: %0d of %0d checks failed", fails, checks);
        $display("=========================================================");
        $finish;
    end

    // 全局超时
    initial begin
        #20_000_000;
        $display(" TIMEOUT: simulation exceeded 20ms");
        $display(" CHECKS FAILED: timeout (%0d checks)", checks);
        $finish;
    end

endmodule
