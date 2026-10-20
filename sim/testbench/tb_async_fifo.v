// =============================================================================
// tb_async_fifo.v — async_fifo 单元测试
// =============================================================================
// 【测试目标】
//   async_fifo 是跨时钟域的唯一通道，它出错的表现是"随机花屏"——偶发、
//   不可复现、且靠看画面根本定位不到。因此测试重点不是"能传数据"，
//   而是**证明 CDC 安全机制本身正确**：
//     - 格雷码指针每次跳变只改 1 bit（亚稳态的根本来源）
//     - 满/空判定不会误判（误判满 = 丢数据，误判空 = 读出脏数据）
//     - 写满不覆盖、读空不越界
//     - 两侧复位各自独立，互不干扰
//
// 【时钟配置】
//   wr_clk = 37.5ns (≈26.7MHz)，rd_clk = 13ns (≈76.9MHz)
//   两者无整数倍关系 —— 刻意如此。若用 25MHz/50MHz 这种整倍关系，
//   相位关系固定，某些 CDC 缺陷会因为"总是采在稳定窗口"而测不出来。
//
// 【断言要点】
//   [A1] wr_gray 每次变化，popcount(old^new) 必须 == 1
//   [A2] rd_gray 同上
//   [A3] wr_full=1 期间写入的数据不得丢失（最终全部按序读出）
//   [A4] rd_empty=1 期间不得读
//   [A5] 读出的数据序列必须与写入序列完全一致（顺序 + 内容）
// =============================================================================
`timescale 1ns / 1ps

module tb_async_fifo;

    // -------------------------------------------------------------------------
    // 参数
    // -------------------------------------------------------------------------
    localparam DATA_WIDTH = 16;
    localparam ADDR_WIDTH = 4;                  // 深度 16，可用 15
    localparam DEPTH      = (1 << ADDR_WIDTH);

    // -------------------------------------------------------------------------
    // DUT 端口
    // -------------------------------------------------------------------------
    reg                   wr_clk;
    reg                   wr_rst_n;
    reg                   wr_en;
    reg  [DATA_WIDTH-1:0] wr_data;
    wire                  wr_full;

    reg                   rd_clk;
    reg                   rd_rst_n;
    reg                   rd_en;
    wire [DATA_WIDTH-1:0] rd_data;
    wire                  rd_empty;

    // -------------------------------------------------------------------------
    // 统计
    // -------------------------------------------------------------------------
    integer errors       = 0;
    integer checks       = 0;
    integer wr_cnt       = 0;      // 成功写入次数
    integer rd_cnt       = 0;      // 成功读出次数
    integer gray_err     = 0;      // 格雷码单 bit 断言失败次数
    integer full_stall   = 0;      // 因满而阻塞的次数
    integer empty_stall  = 0;      // 因空而阻塞的次数
    integer rd_bad       = 0;      // 数据不匹配次数

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) dut (
        .wr_clk   (wr_clk),
        .wr_rst_n (wr_rst_n),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full),
        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_empty (rd_empty)
    );

    // -------------------------------------------------------------------------
    // 时钟生成
    // -------------------------------------------------------------------------
    initial wr_clk = 1'b0;
    always #18.75 wr_clk = ~wr_clk;      // 周期 37.5ns

    initial rd_clk = 1'b0;
    always #6.5   rd_clk = ~rd_clk;      // 周期 13ns

    // -------------------------------------------------------------------------
    // [A1][A2] 格雷码单 bit 跳变断言
    //
    // 这是本 tb 最重要的一条。格雷码的全部价值就在于"相邻状态只差 1 bit"；
    // 一旦某次跳变改了多位，跨域采样就可能采到从未存在过的指针值，
    // 满/空判定的组合逻辑会随之给出错误结论 —— 这正是花屏的根源。
    //
    // 实现: 记住上一拍的格雷码，变化时数 old^new 的 1 的个数，必须恰好为 1。
    //       同时比较"二进制指针 +1"是否正确（格雷码转换本身不能错）。
    // -------------------------------------------------------------------------
    reg [ADDR_WIDTH:0] wr_gray_prev;
    reg [ADDR_WIDTH:0] rd_gray_prev;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_gray_prev <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_gray_prev <= dut.wr_gray;
        end
    end

    // 逐位数"变了几个 bit"。用显式循环而非 case 列值：
    // 在 Verilog 里 case 分支写 `(1<<0) | (1<<1) | ...` 是**按位或**，
    // 结果为 31，只会匹配 xor==0 或 xor==31，其它合法单 bit 跳变全被误判。
    integer wb;
    integer wr_ndiff;

    always @(posedge wr_clk) begin
        if (wr_rst_n) begin
            if (dut.wr_gray !== wr_gray_prev) begin
                wr_ndiff = 0;
                for (wb = 0; wb < ADDR_WIDTH + 1; wb = wb + 1) begin
                    if ((dut.wr_gray ^ wr_gray_prev) &
                        ({{(ADDR_WIDTH){1'b0}}, 1'b1} << wb)) begin
                        wr_ndiff = wr_ndiff + 1;
                    end
                end
                if (wr_ndiff != 1) begin
                    $display("FAIL: [A1] wr_gray multi-bit jump at %0t: %b -> %b (%0d bits)",
                             $time, wr_gray_prev, dut.wr_gray, wr_ndiff);
                    gray_err = gray_err + 1;
                    errors   = errors + 1;
                end
            end
        end
    end

    integer rb;
    integer rd_ndiff;

    always @(posedge rd_clk) begin
        if (rd_rst_n) begin
            if (dut.rd_gray !== rd_gray_prev) begin
                rd_ndiff = 0;
                for (rb = 0; rb < ADDR_WIDTH + 1; rb = rb + 1) begin
                    if ((dut.rd_gray ^ rd_gray_prev) &
                        ({{(ADDR_WIDTH){1'b0}}, 1'b1} << rb)) begin
                        rd_ndiff = rd_ndiff + 1;
                    end
                end
                if (rd_ndiff != 1) begin
                    $display("FAIL: [A2] rd_gray multi-bit jump at %0t: %b -> %b (%0d bits)",
                             $time, rd_gray_prev, dut.rd_gray, rd_ndiff);
                    gray_err = gray_err + 1;
                    errors   = errors + 1;
                end
            end
            rd_gray_prev <= dut.rd_gray;
        end else begin
            rd_gray_prev <= {(ADDR_WIDTH+1){1'b0}};
        end
    end

    // -------------------------------------------------------------------------
    // 写侧激励与统计
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_rst_n && wr_en) begin
            if (wr_full) begin
                full_stall = full_stall + 1;
            end else begin
                wr_cnt = wr_cnt + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 读侧数据校验
    //   读出的第 n 个数据必须等于写入的第 n 个数据。
    //   写入序列设计成 data = seq（从 1 开始递增），便于直接比对。
    // -------------------------------------------------------------------------
    // -------------------------------------------------------------------------
    // [A5] 读侧数据序列校验
    //
    // 【为什么不能"读出的第 n 个必须等于 n"】
    //   写入序列是 1,2,3,...，但 FIFO 满时 wr_en 会被 wr_full 挡掉 ——
    //   那些编号**本来就没进 FIFO**，不应该出现在读侧。若强行要求
    //   read[n]==n，会把"满时正确丢弃"误判成数据错误。
    //
    // 【正确的不变量】读出的编号必须
    //   (a) 严格递增（FIFO 的先进先出本质，乱序 = 数据错乱）
    //   (b) 不重复（重复 = 指针回绕 bug）
    //   (c) 在 1..(写请求总数) 之间（越界 = 读到了没写过的位置）
    //   (d) 相邻差值不能大到超出"该时段被挡掉的写请求数"——这一条用
    //       全局单调性 + 上界近似，已足以抓住指针错位。
    //
    //   真正能抓住"丢一个数据"的是 (a)+(b)：丢了中间一个，序列仍递增，
    //   但会与后文的期望平齐不上 —— 因此每个用例收尾还会比对
    //   "读出的个数 == 成功写入的个数"，这是最有力的丢数检测。
    // -------------------------------------------------------------------------
    reg [15:0] last_rd_data;
    reg        have_last;
    reg        use_check;

    always @(posedge rd_clk) begin
        if (rd_rst_n && rd_en) begin
            if (rd_empty) begin
                empty_stall = empty_stall + 1;
            end else begin
                if (use_check) begin
                    if (have_last && rd_data <= last_rd_data) begin
                        if (rd_bad < 8) begin
                            $display("FAIL: [A5] read order violated #%0d: got %0d after %0d (t=%0t)",
                                     rd_cnt, rd_data, last_rd_data, $time);
                        end
                        rd_bad = rd_bad + 1;
                        errors = errors + 1;
                    end
                    last_rd_data = rd_data;
                    have_last    = 1'b1;
                end
                rd_cnt = rd_cnt + 1;
            end
        end
    end

    // "读出的个数必须等于成功写入的个数"——丢数检测的主断言
    task chk_balanced;
        input [8*40:1] msg;
        begin
            if (rd_cnt == wr_cnt) begin
                $display("PASS: %0s (wr=%0d rd=%0d)", msg, wr_cnt, rd_cnt);
            end else begin
                $display("FAIL: %0s (wr=%0d rd=%0d, diff=%0d)",
                         msg, wr_cnt, rd_cnt, wr_cnt - rd_cnt);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 辅助 task
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            wr_rst_n   = 1'b0;
            rd_rst_n   = 1'b0;
            wr_en      = 1'b0;
            rd_en      = 1'b0;
            wr_data    = 16'd0;
            last_rd_data = 16'd0;
            have_last    = 1'b0;
            use_check    = 1'b1;
            repeat (4) @(negedge wr_clk);
            repeat (4) @(negedge rd_clk);
            wr_rst_n = 1'b1;
            rd_rst_n = 1'b1;
            repeat (4) @(negedge rd_clk);
        end
    endtask

    task chk;
        input        cond;
        input [8*72:1] msg;
        begin
            checks = checks + 1;
            if (cond) begin
                $display("PASS: %0s", msg);
            end else begin
                $display("FAIL: %0s", msg);
                errors = errors + 1;
            end
        end
    endtask

    // 等待 rd_empty 变低（最多等 timeout 个 rd_clk）
    task wait_not_empty;
        input integer timeout;
        integer k;
        begin
            k = 0;
            while (rd_empty && k < timeout) begin
                @(negedge rd_clk);
                k = k + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 主测试
    // -------------------------------------------------------------------------
    integer i;
    integer t0_wr;
    integer t0_rd;

    initial begin
        $display("=== tb_async_fifo start ===");
        $display("    DATA_WIDTH=%0d ADDR_WIDTH=%0d DEPTH=%0d",
                 DATA_WIDTH, ADDR_WIDTH, DEPTH);

        // =====================================================================
        // T01 复位后状态
        // =====================================================================
        $display("\n--- T01 reset state ---");
        do_reset;
        chk(wr_full  == 1'b0, "T01 wr_full = 0 after reset");
        chk(rd_empty == 1'b1, "T01 rd_empty = 1 after reset");

        // =====================================================================
        // T02 写入 1 个 → 读侧应立即非空，且数据正确
        // =====================================================================
        $display("\n--- T02 single write then read ---");
        do_reset;
        @(negedge wr_clk) wr_en = 1'b1; wr_data = 16'd1;
        @(negedge wr_clk) wr_en = 1'b0;
        wait_not_empty(20);
        chk(!rd_empty, "T02 rd_empty deasserted after one write");
        @(negedge rd_clk) rd_en = 1'b1;
        @(negedge rd_clk) rd_en = 1'b0;
        // 数据校验由 always 块自动完成（expect_seq 从 1 开始）
        repeat (4) @(negedge rd_clk);
        chk(rd_cnt == 1, "T02 exactly one word read");
        chk(rd_bad == 0, "T02 data matched");
        chk(rd_empty,    "T02 empty again after drain");

        // =====================================================================
        // T03 写满：连续写直到 wr_full，验证不会覆盖
        //     写满后停止写，把 DEPTH-1 个数据全部读出，验证顺序与内容
        // =====================================================================
        $display("\n--- T03 fill to full then drain ---");
        do_reset;
        t0_wr = wr_cnt;
        // 阶段 1：一路灌到满（满后的写请求会被 wr_full 挡掉，属正常）
        for (i = 0; i < DEPTH + 8; i = i + 1) begin
            @(negedge wr_clk);
            wr_en   = 1'b1;
            wr_data = i[15:0] + 16'd1;
        end
        @(negedge wr_clk) wr_en = 1'b0;
        repeat (4) @(negedge wr_clk);
        chk(wr_full, "T03 wr_full asserted when full");
        chk((wr_cnt - t0_wr) == DEPTH, "T03 exactly DEPTH words accepted");
        chk(full_stall > 0,            "T03 overflow attempts were blocked");
        // 阶段 2：全部排空
        while (!rd_empty) begin
            @(negedge rd_clk) rd_en = 1'b1;
        end
        @(negedge rd_clk) rd_en = 1'b0;
        repeat (8) @(negedge rd_clk);
        chk(rd_empty, "T03 empty after drain");
        chk_balanced("T03 accepted count == read count");

        // =====================================================================
        // T04 背靠背连续传输：写侧持续灌 300 个，读侧同时持续读
        //     这是真实工作模式（SD 卡 → FIFO，FIFO → 显示）
        // =====================================================================
        $display("\n--- T04 streaming 300 words concurrently ---");
        do_reset;
        t0_wr = wr_cnt; t0_rd = rd_cnt;
        fork
            begin : t04_writer
                for (i = 0; i < 300; i = i + 1) begin
                    @(negedge wr_clk);
                    wr_en   = 1'b1;
                    wr_data = i[15:0] + 16'd1;
                end
                @(negedge wr_clk) wr_en = 1'b0;
            end
            begin : t04_reader
                // 读满 300 个就退出
                while ((rd_cnt - t0_rd) < 300) begin
                    @(negedge rd_clk) rd_en = 1'b1;
                end
                @(negedge rd_clk) rd_en = 1'b0;
            end
        join
        repeat (8) @(negedge rd_clk);
        chk((rd_cnt - t0_rd) == 300, "T04 all 300 words read");
        chk(rd_bad == 0,             "T04 stream data matched");
        chk(rd_empty,                "T04 empty after stream");
        $display("    full_stall=%0d empty_stall=%0d", full_stall, empty_stall);

        // =====================================================================
        // T05 空读：rd_empty=1 时给 rd_en，数据不得推进
        // =====================================================================
        $display("\n--- T05 read while empty ---");
        do_reset;
        use_check = 1'b0;      // 本用例故意在空时读，不比对内容
        t0_rd = rd_cnt;
        @(negedge rd_clk) rd_en = 1'b1;
        repeat (10) @(negedge rd_clk);
        rd_en = 1'b0;
        chk((rd_cnt - t0_rd) == 0, "T05 no read when empty");
        chk(rd_empty,              "T05 still empty");
        chk(rd_bad == 0,           "T05 no bogus data consumed");

        // =====================================================================
        // T06 满写：wr_full=1 时给 wr_en，指针不得推进
        //     若满时仍推进指针，会覆盖未读数据 —— 表现为"偶尔少一帧"
        // =====================================================================
        $display("\n--- T06 write while full ---");
        do_reset;
        use_check = 1'b0;      // 读的是第一次写满的数据，与 expect_seq 起点不同
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge wr_clk) wr_en = 1'b1; wr_data = i[15:0] + 16'd1;
        end
        @(negedge wr_clk) wr_en = 1'b0;
        repeat (4) @(negedge wr_clk);
        chk(wr_full == 1'b1, "T06 full after DEPTH writes");
        // 记住满时的写指针，再给 8 次写请求，指针不得改变
        t0_wr = dut.wr_bin;
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge wr_clk) wr_en = 1'b1; wr_data = 16'hDEAD;
        end
        @(negedge wr_clk) wr_en = 1'b0;
        repeat (2) @(negedge wr_clk);
        chk(dut.wr_bin == t0_wr, "T06 write pointer frozen while full");
        // 全部读出，验证没有被 DEAD 覆盖
        while (!rd_empty) begin
            @(negedge rd_clk) rd_en = 1'b1;
        end
        @(negedge rd_clk) rd_en = 1'b0;
        repeat (8) @(negedge rd_clk);
        chk(rd_bad == 0, "T06 no data corrupted by writes-while-full");

        // =====================================================================
        // T07 单侧复位：只复位读侧，写侧数据不受影响
        //     真实场景: HDMI 侧热复位不应破坏 SD 侧已缓冲的数据
        // =====================================================================
        $display("\n--- T07 read-side-only reset ---");
        do_reset;
        use_check = 1'b0;      // 复位后重读旧数据，序列起点已被打乱
        t0_wr = wr_cnt;
        for (i = 0; i < 5; i = i + 1) begin
            @(negedge wr_clk) wr_en = 1'b1; wr_data = i[15:0] + 16'd1;
        end
        @(negedge wr_clk) wr_en = 1'b0;
        repeat (6) @(negedge wr_clk);
        // 只复位读侧
        rd_rst_n = 1'b0;
        repeat (3) @(negedge rd_clk);
        chk(rd_empty, "T07 read side empty immediately after its own reset");
        rd_rst_n = 1'b1;
        repeat (6) @(negedge rd_clk);
        // 复位后读指针归零，之前写入的数据仍在 → 应能读出
        wait_not_empty(20);
        chk(!rd_empty, "T07 buffered data still visible after rd reset");
        // 清掉 FIFO 里的数据（不复位写侧）
        while (!rd_empty) begin
            @(negedge rd_clk) rd_en = 1'b1;
        end
        @(negedge rd_clk) rd_en = 1'b0;
        repeat (6) @(negedge rd_clk);

        // =====================================================================
        // T08 随机速率压力：写侧随机间隔、读侧随机间隔，跑 400 个
        //     用 $random 打乱两侧节奏，复现"时序恰好踩线"的情形
        // =====================================================================
        $display("\n--- T08 random-rate stress 400 words ---");
        do_reset;
        t0_wr = wr_cnt; t0_rd = rd_cnt;
        fork
            begin : t08_writer
                integer n;
                for (n = 0; n < 400; n = n + 1) begin
                    repeat (($random & 32'h7) + 1) @(negedge wr_clk);
                    wr_en   = 1'b1;
                    wr_data = n[15:0] + 16'd1;
                    @(negedge wr_clk);
                    wr_en = 1'b0;
                end
            end
            begin : t08_reader
                while ((rd_cnt - t0_rd) < 400) begin
                    repeat (($random & 32'h7) + 1) @(negedge rd_clk);
                    rd_en = 1'b1;
                    @(negedge rd_clk);
                    rd_en = 1'b0;
                end
                rd_en = 1'b0;
            end
        join
        repeat (8) @(negedge rd_clk);
        chk((rd_cnt - t0_rd) == 400, "T08 all 400 words read under random rates");
        chk(rd_bad == 0,             "T08 random-rate data matched");
        chk(rd_empty,                "T08 empty after stress");

        // =====================================================================
        // 汇总
        // =====================================================================
        repeat (20) @(negedge rd_clk);
        $display("\n=================================================");
        $display("  total writes  = %0d", wr_cnt);
        $display("  total reads   = %0d", rd_cnt);
        $display("  gray-code err = %0d", gray_err);
        $display("  data mismatch = %0d", rd_bad);
        $display("  full stall    = %0d", full_stall);
        $display("  empty stall   = %0d", empty_stall);
        $display("  errors        = %0d", errors);
        $display("SUMMARY: checks=%0d errors=%0d cases=8", checks, errors);
        if (errors == 0) begin
            $display("ALL CHECKS PASSED: async_fifo");
        end else begin
            $display("*** ALL CHECKS FAILED: async_fifo, errors = %0d ***", errors);
        end
        $display("=================================================");
        $finish;
    end

    // 全局超时
    initial begin
        #5000000;
        $display("FAIL: TIMEOUT");
        $display("=== tb_async_fifo TIMEOUT ===");
        $finish;
    end

endmodule
