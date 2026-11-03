// =============================================================================
// tb_fifo_fwft.v — async_fifo 的 FWFT 语义回归（t25 落盘后成为常驻回归 tb）
//
// 被测对象: rtl/common/async_fifo.v（已改为「同步读 + FWFT 预取寄存器」）
// 参照对象: 本文件末尾的 async_fifo_ref —— 原始「异步组合读」实现的逐字副本，
//           只在模块名上做了区分（async_fifo_orig → async_fifo_ref）。
//           把它内联进 tb 是为了让本 tb **只依赖 rtl/common/async_fifo.v 一个 RTL 文件**，
//           不引入 project/ 下的探针副本，回归时可独立编译。
//
// 判据：两版 FIFO 在同一激励下，每一次 rd_en 取到的数据必须完全相同、顺序完全相同。
//       任何一次不一致 → 打印 FAIL 并给出首次分歧的序号/期望/实际/时序上下文。
//
// ★ 场景设计要点（写这个 tb 时踩过的坑，别再犯）：
//   S1~S3 都用「先等 rd_empty 掉低、再在下一次 posedge 拉 rd_en」的方式读，
//   这**恰好避开了最危险的时序窗口**——消费端在 rd_empty 刚掉低的同一拍就取数。
//   真实的 pix_reader 是组合判 !rd_empty 就消费，必然命中那个窗口。
//   所以必须有 S4：rd_en 由 !rd_empty_0 组合驱动（连续消费模式），
//   让「空→非空」与「消费最后一个元素」两个边界自然发生。
//   只跑 S1~S3 会得到「全绿但没有证明力」的结论 —— 见 T4_VIDEO_PATH.md §17.9
//   「默认档恰好等于没测」的同族陷阱。
//
// ★ 两条必须保留的变异点（改 FWFT 实现时拿来验判据灵敏度，双计数见 §18.14）：
//   MUTATION-1 预取地址改用当前态 rd_bin（而非次态 rd_bin_next）→ errors=2162
//   MUTATION-2 预取加 `else if (!rd_empty)` 门控（空时不刷新）  → errors=74
//   两条都**只在 S4 存在时才被抓到**，所以 S4 段不许删。
// =============================================================================
`timescale 1ns / 1ps

module tb_fifo_fwft;

    localparam DW = 8;
    localparam AW = 4;                 // 16 深
    localparam DEPTH = 1 << AW;
    localparam MAXN = 4096;

    reg  wr_clk, wr_rst_n, rd_clk, rd_rst_n;
    reg  wr_en;
    reg  [DW-1:0] wr_data;
    wire wr_full_0, wr_full_1, rd_empty_0, rd_empty_1;
    wire [DW-1:0] rd_data_0, rd_data_1;
    wire af0, af1;

    // ---- rd_en 两种驱动方式：手动单拍 / 连续消费（组合）----
    reg  rd_en_manual;
    reg  pull_en;                      // 连续消费使能
    reg  cs_mode;                      // 1 = 连续消费模式
    wire rd_en = cs_mode ? (pull_en && !rd_empty_0) : rd_en_manual;

    integer errors = 0;
    integer checks = 0;

    // 原始版（异步组合读）
    async_fifo_ref  #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ALMOST_FULL_MARGIN(0)) u_ref  (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(wr_en), .wr_data(wr_data),
        .wr_full(wr_full_0), .wr_almost_full(af0),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .rd_en(rd_en),
        .rd_data(rd_data_0), .rd_empty(rd_empty_0)
    );

    // FWFT 版（输出寄存器预取）
    async_fifo      #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW), .ALMOST_FULL_MARGIN(0)) u_fwft (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_en(wr_en), .wr_data(wr_data),
        .wr_full(wr_full_1), .wr_almost_full(af1),
        .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .rd_en(rd_en),
        .rd_data(rd_data_1), .rd_empty(rd_empty_1)
    );

    // 两路独立时钟，故意异相
    initial begin wr_clk = 1'b0; forever #5.0  wr_clk = ~wr_clk; end
    initial begin rd_clk = 1'b0; forever #7.0  rd_clk = ~rd_clk; end

    reg [DW-1:0] model [0:MAXN-1];     // 写侧顺序记录（期望读序）
    integer wr_cnt = 0;
    integer rd_cnt = 0;
    integer mismatch = 0;

    // ---- 每一次读，把两版结果与模型比对 ----
    //   注意 rd_data_0 是组合值（当拍队头），rd_data_1 是寄存器值（上一拍预取）。
    //   「等价」的含义就是这两个在 rd_en 有效的每一拍完全相同。
    always @(posedge rd_clk) begin
        if (rd_rst_n && rd_en && !rd_empty_0) begin
            checks = checks + 1;
            if (rd_data_0 !== rd_data_1) begin
                mismatch = mismatch + 1;
                if (mismatch < 9)   // 注意: 本工程 lint 工具会把 "<= 数字" 误判成非阻塞赋值, 故写成 "< 9"
                    $display("FAIL: rd#%0d data differs orig=%02h fwft=%02h (t=%0t)",
                             rd_cnt, rd_data_0, rd_data_1, $time);
                errors = errors + 1;
            end
            if (rd_cnt < wr_cnt && rd_data_1 !== model[rd_cnt]) begin
                mismatch = mismatch + 1;
                if (mismatch < 9)   // 注意: 本工程 lint 工具会把 "<= 数字" 误判成非阻塞赋值, 故写成 "< 9"
                    $display("FAIL: rd#%0d fwft=%02h expected=%02h (t=%0t)",
                             rd_cnt, rd_data_1, model[rd_cnt], $time);
                errors = errors + 1;
            end
            if (rd_empty_0 !== rd_empty_1) begin
                if (mismatch < 9)   // 注意: 本工程 lint 工具会把 "<= 数字" 误判成非阻塞赋值, 故写成 "< 9"
                    $display("FAIL: rd#%0d empty differs orig=%b fwft=%b (t=%0t)",
                             rd_cnt, rd_empty_0, rd_empty_1, $time);
                errors = errors + 1;
            end
            rd_cnt = rd_cnt + 1;
        end
    end

    task wr_one;
        input [DW-1:0] d;
        begin
            @(negedge wr_clk);
            wr_data = d;
            wr_en   = 1'b1;
            @(negedge wr_clk);
            wr_en   = 1'b0;
            model[wr_cnt] = d;
            wr_cnt = wr_cnt + 1;
        end
    endtask

    // 等 rd_empty 变低（带超时）
    task wait_not_empty;
        begin : wne
            integer g;
            g = 0;
            while (rd_empty_0 && g < 200) begin
                @(posedge rd_clk);
                #1;
                g = g + 1;
            end
            if (g >= 200) begin
                $display("FAIL: timeout waiting rd_empty low at wr_cnt=%0d rd_cnt=%0d", wr_cnt, rd_cnt);
                errors = errors + 1;
            end
        end
    endtask

    // 单次读一拍（在 rd_clk 上升沿之后撤）
    task rd_one;
        begin
            @(posedge rd_clk);
            #1;
            rd_en_manual = 1'b1;
            @(posedge rd_clk);
            #1;
            rd_en_manual = 1'b0;
        end
    endtask

    integer i, j, gap, guard;

    initial begin
        wr_rst_n = 1'b0; rd_rst_n = 1'b0;
        wr_en = 1'b0; rd_en_manual = 1'b0; wr_data = 0;
        pull_en = 1'b0; cs_mode = 1'b0;
        repeat (6) @(posedge wr_clk);
        wr_rst_n = 1'b1;
        repeat (6) @(posedge rd_clk);
        rd_rst_n = 1'b1;
        repeat (4) @(posedge rd_clk);

        // ---------------------------------------------------------------
        // S1：空 FIFO 上立即「写一个 → 读一个」，重复 8 次。
        //     每次读完必然读空，下一次写入紧跟其后 —— 「读空后立即写入」边界。
        //     注意：这里读之前先 wait_not_empty，#1 之后才拉 rd_en，
        //     所以 rd_empty 掉低的当拍 rd_en 仍为 0 —— 这条恰是「安全路径」，
        //     真正危险的当拍命中在 S4。
        // ---------------------------------------------------------------
        $display("SECT: S1 empty-read-refill");
        for (i = 0; i < 8; i = i + 1) begin
            wr_one(8'hA0 + i[7:0]);
            wait_not_empty;
            rd_one;
            repeat (3) @(posedge rd_clk);
        end

        // ---------------------------------------------------------------
        // S2：写满到接近满，然后「读到空」，读到空后再写入一批继续读。
        // ---------------------------------------------------------------
        $display("SECT: S2 drain-to-empty-then-refill");
        for (i = 0; i < DEPTH - 2; i = i + 1) wr_one(8'h10 + i[7:0]);
        for (i = 0; i < DEPTH - 2; i = i + 1) begin
            wait_not_empty;
            rd_one;
        end
        repeat (4) @(posedge rd_clk);
        if (rd_empty_0 !== 1'b1) begin
            $display("FAIL: FIFO not empty after full drain (orig empty=%b fwft=%b)", rd_empty_0, rd_empty_1);
            errors = errors + 1;
        end
        for (i = 0; i < 4; i = i + 1) wr_one(8'hC0 + i[7:0]);
        for (i = 0; i < 4; i = i + 1) begin
            wait_not_empty;
            rd_one;
        end
        repeat (4) @(posedge rd_clk);
        if (rd_empty_0 !== 1'b1) begin
            $display("FAIL: FIFO not empty after second drain (orig empty=%b fwft=%b)", rd_empty_0, rd_empty_1);
            errors = errors + 1;
        end

        // ---------------------------------------------------------------
        // S3：随机深度的填充/排空交替，含 0 空隙与 1~5 拍空隙，共 40 轮。
        // ---------------------------------------------------------------
        $display("SECT: S3 random fill-drain");
        for (j = 0; j < 40; j = j + 1) begin
            gap = (j % 6);
            repeat (gap) @(posedge rd_clk);
            for (i = 0; i < ((j % 5) + 1); i = i + 1) wr_one(8'h30 + j[7:0] + i[7:0]);
            for (i = 0; i < ((j % 5) + 1); i = i + 1) begin
                wait_not_empty;
                rd_one;
            end
        end

        // ---------------------------------------------------------------
        // ★ S4：连续消费 + 随机写入（真并发）。
        //     rd_en = !rd_empty_0 组合驱动（pix_reader 的真实用法），
        //     写侧用 7 位 LFSR 决定「这一拍写不写」（约 50% 写入率），
        //     跑 3000 拍。这样 rd_empty 会在空/非空之间高频跳变，
        //     必然命中「rd_empty 刚掉低的同一拍就要取数」与
        //     「消费最后一个元素后立刻又空」两个边界。
        //     若 FWFT 的预取寄存器在空→非空时不刷新，这里必然红。
        //     注意：写侧与读侧是两个独立 initial 块，真并发，不是轮流。
        // ---------------------------------------------------------------
        $display("SECT: S4 continuous-consume with concurrent writes");
        cs_mode = 1'b1;
        pull_en = 1'b1;
        fork
            begin : s4_writer
                integer k;
                reg [6:0] lfsr;
                reg do_wr;
                lfsr = 7'h5A;
                for (k = 0; k < 3000; k = k + 1) begin
                    @(negedge wr_clk);
                    lfsr = {lfsr[5:0], lfsr[6] ^ lfsr[5]};
                    do_wr  = lfsr[0] && !wr_full_0;
                    wr_en   = do_wr;
                    wr_data = 8'h50 + lfsr[6:3];
                    @(posedge wr_clk);
                    #1;
                    if (do_wr) begin
                        model[wr_cnt] = wr_data;
                        wr_cnt = wr_cnt + 1;
                    end
                end
                @(negedge wr_clk);
                wr_en = 1'b0;
            end
            begin : s4_reader
                integer k;
                for (k = 0; k < 3000; k = k + 1) @(posedge rd_clk);
            end
        join
        // 排空残余
        guard = 0;
        while (rd_cnt < wr_cnt && guard < 2000) begin
            @(posedge rd_clk);
            #1;
            guard = guard + 1;
        end
        if (guard >= 2000) begin
            $display("FAIL: S4 drain timeout wr_cnt=%0d rd_cnt=%0d", wr_cnt, rd_cnt);
            errors = errors + 1;
        end
        pull_en = 1'b0;
        cs_mode = 1'b0;
        repeat (4) @(posedge rd_clk);
        $display("S4: consumed %0d words under continuous mode", rd_cnt);

        repeat (10) @(posedge rd_clk);
        $display("SUMMARY: checks=%0d errors=%0d wrote=%0d read=%0d", checks, errors, wr_cnt, rd_cnt);
        if (errors == 0 && checks > 300) $display("ALL CHECKS PASSED: tb_fifo_fwft");
        else $display("FAILED: tb_fifo_fwft errors=%0d checks=%0d", errors, checks);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAILED: tb_fifo_fwft global timeout");
        $finish;
    end

endmodule

// =============================================================================
// async_fifo.v — 异步 FIFO（格雷码指针，跨时钟域安全）
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 通用层 —— 跨时钟域（CDC）的唯一合法通道
//   工程归属 : project/hdmi_td.al（被 framebuf 子系统例化两份）
//   数据流位置:
//       SD 卡 25MHz 像素域 ──wr_fifo(本模块)──→ ERAM 150MHz 域
//       ERAM 150MHz 域 ─────rd_fifo(本模块)──→ HDMI 25MHz 像素域
//
//   为什么必须用它:
//     ERAM 控制器跑 150MHz，HDMI 像素域跑 25MHz，两者**无任何相位关系**
//     （两颗独立 PLL 各自锁定）。跨域直接传多拍数据必然出现亚稳态采样，
//     表现为随机的花屏/错像素。本模块用"格雷码指针 + 两级同步器"把
//     跨域信号压缩成每次只变 1 bit 的格雷码，从根本上消灭亚稳态风险。
//
// 【二、本模块功能】
//   一句话职责: 双时钟域间的数据缓冲，写侧看 wr_full、读侧看 rd_empty，
//               两侧各自独立复位，绝不跨域直接使用对方的二进制计数器。
//   关键特性:
//     - 指针位宽 = ADDR_WIDTH+1，用最高位区分"空"与"满"（经典 Cummings 结构）
//     - 格雷码每次只变 1 bit，跨域采样时最多错一个状态，不会出现数据错乱
//     - 空/满判断用**寄存器输出**（非组合），代价是容量少用 1 个，
//       换来的是判定干净、无毛刺
//     - 存储用分布式 RAM（异步读），读出无额外延迟
//
// 【三、接口与内部结构】
//   端口一览:
//     写侧（wr_clk 域）: wr_clk/wr_rst_n/wr_en/wr_data[W-1:0]/wr_full
//     读侧（rd_clk 域）: rd_clk/rd_rst_n/rd_en/rd_data[W-1:0]/rd_empty
//
//   内部逻辑块（共 6 块）:
//     [1] 存储阵列 mem        双口：写由 wr_clk 驱动，读为异步组合
//     [2] 写侧二进制指针      wr_bin / wr_bin_next
//     [3] 写侧格雷码 + 满判定 wr_gray / 同步后的 rd_gray
//     [4] 读侧二进制指针      rd_bin / rd_bin_next
//     [5] 读侧格雷码 + 空判定 rd_gray / 同步后的 wr_gray
//     [6] 两级同步器          wr_gray→rd_clk 域、rd_gray→wr_clk 域
//
// 【四、时序行为】
//   - 写入: wr_en=1 且 wr_full=0 时，当拍 wr_data 在 wr_clk 上升沿写入 mem
//   - 读出: rd_data 是 mem[rd_bin] 的**异步**组合输出，rd_en=1 且
//           rd_empty=0 时当拍即可取用，指针在 rd_clk 上升沿前进
//   - wr_full/rd_empty 为**寄存器输出**：wr_full 在"再写一个就满"时拉高，
//     因此实际可用深度是 2^ADDR_WIDTH - 1
//
// 【五、设计陷阱与规避】
//   1) **格雷码指针必须跨域后才比较**。若直接拿未同步的对方二进制指针比，
//      多 bit 同时跳变会被采到中间值，满/空判断随机出错。
//   2) **满判定要反转高 2 位**。指针多 1 位表示圈数，满时写指针比读指针
//      多整整一圈，格雷码上表现为"高 2 位相反、其余位相同"。
//   3) **两侧复位必须各自独立**。用同一个异步复位跨两个域，会在复位释放
//      的亚稳态窗口里同时扰动两个域。
//   4) **不要在满/空判定里加组合逻辑**。组合输出一方面有毛刺，另一方面
//      会成为跨域路径的时序瓶颈。
//   5) **memory 的读地址必须来自本域指针**。用同步过来的指针去读 mem
//      等于把跨域延迟吃进数据路径，读出的数据可能已过期。
// =============================================================================
`timescale 1ns / 1ps

module async_fifo_ref #(
    parameter DATA_WIDTH = 16,      // 数据位宽
    parameter ADDR_WIDTH = 9,       // 深度 = 2^ADDR_WIDTH，实际可用少 1 个
    parameter ALMOST_FULL_MARGIN = 0 // 写侧预留空间；0 表示关闭
) (
    // ---------------- 写侧（生产端时钟域）----------------
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,     // 低有效，异步复位
    input  wire                  wr_en,        // 写请求
    input  wire [DATA_WIDTH-1:0] wr_data,      // 写数据
    output reg                   wr_full,      // 满标志（寄存器输出）
    output wire                  wr_almost_full, // 预留 margin 后的满标志

    // ---------------- 读侧（消费端时钟域）----------------
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,     // 低有效，异步复位
    input  wire                  rd_en,        // 读请求
    output wire [DATA_WIDTH-1:0] rd_data,      // 读数据（异步组合输出）
    output reg                   rd_empty      // 空标志（寄存器输出）
);

    localparam PTR_W = ADDR_WIDTH + 1;         // 指针多 1 位用于区分空/满
    localparam DEPTH = (1 << ADDR_WIDTH);

    // -------------------------------------------------------------------------
    // 内部信号声明（Verilog-2001 要求在使用前声明，故集中放在此处）
    // -------------------------------------------------------------------------
    reg  [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg  [PTR_W-1:0]      wr_bin, wr_bin_next;      // 写侧二进制指针
    reg  [PTR_W-1:0]      wr_gray, wr_gray_next;    // 写侧格雷码
    reg  [PTR_W-1:0]      rd_gray_wr1, rd_gray_wr2; // 读格雷码 → wr 域同步
    reg                   wr_full_next;

    reg  [PTR_W-1:0]      rd_bin, rd_bin_next;      // 读侧二进制指针
    reg  [PTR_W-1:0]      rd_gray, rd_gray_next;    // 读侧格雷码
    reg  [PTR_W-1:0]      wr_gray_rd1, wr_gray_rd2; // 写格雷码 → rd 域同步
    reg                   rd_empty_next;
    reg  [PTR_W-1:0]      rd_bin_wr_sync;
    integer                gray_i;

    // Convert the synchronized read pointer back to binary in the write
    // domain. The stale two-flop pointer makes this estimate conservative,
    // which is exactly what a producer-side reservation needs.
    always @(*) begin
        rd_bin_wr_sync[PTR_W-1] = rd_gray_wr2[PTR_W-1];
        for (gray_i = PTR_W-2; gray_i >= 0; gray_i = gray_i - 1)
            rd_bin_wr_sync[gray_i] = rd_bin_wr_sync[gray_i+1] ^ rd_gray_wr2[gray_i];
    end
    wire [PTR_W-1:0] wr_used = wr_bin - rd_bin_wr_sync;
    // A producer that emits a burst without per-word backpressure must reserve
    // enough slots before starting that burst. image_player uses a 96-word
    // reservation for one 512-byte 24-bit BMP sector (at most 86 packed words
    // plus pipeline slack).
    assign wr_almost_full = (ALMOST_FULL_MARGIN != 0) &&
                            (wr_used >= (DEPTH - ALMOST_FULL_MARGIN));

    // -------------------------------------------------------------------------
    // [1] 存储阵列
    //     写端口: wr_clk 上升沿同步写入（块 RAM/分布式 RAM 均可推断）
    //     读端口: 异步组合读出，读地址用**本域**读指针的低位
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_en && !wr_full) begin
            mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end

    // 异步读：读指针指向"下一个待读位置"，因此数据在 rd_en 当拍就有效
    assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];

    // -------------------------------------------------------------------------
    // [2] 写侧二进制指针
    //     只在"真的写进去了"时前进；写不进去（满）时保持不动，
    //     否则会丢弃数据且指针错位
    // -------------------------------------------------------------------------
    always @(*) begin
        wr_bin_next = (wr_en && !wr_full) ? (wr_bin + 1'b1) : wr_bin;
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin <= {PTR_W{1'b0}};
        end else begin
            wr_bin <= wr_bin_next;
        end
    end

    // -------------------------------------------------------------------------
    // [3] 写侧格雷码 + 满判定
    //     格雷码 = 二进制 ^ (二进制 >> 1)
    //     满判定: 写侧格雷码_next 与"读侧同步格雷码的高 2 位取反"相等
    // -------------------------------------------------------------------------
    // 组合块：纯阻塞赋值，与下方时序块严格分离（满足 lint E1）
    always @(*) begin
        // 先计算前进后的指针与比较结果，使使能只进入末级选择器。
        wr_gray_next = (wr_bin + 1'b1) ^ ((wr_bin + 1'b1) >> 1);
        wr_full_next = (wr_gray_next ==
                       {~rd_gray_wr2[PTR_W-1:PTR_W-2], rd_gray_wr2[PTR_W-3:0]});
        if (!wr_en || wr_full) begin
            wr_gray_next = wr_gray;
            wr_full_next = (wr_gray ==
                           {~rd_gray_wr2[PTR_W-1:PTR_W-2], rd_gray_wr2[PTR_W-3:0]});
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_gray <= {PTR_W{1'b0}};
            wr_full <= 1'b0;
        end else begin
            wr_gray <= wr_gray_next;
            wr_full <= wr_full_next;
        end
    end

    // -------------------------------------------------------------------------
    // [4] 读侧二进制指针
    // -------------------------------------------------------------------------
    always @(*) begin
        rd_bin_next = (rd_en && !rd_empty) ? (rd_bin + 1'b1) : rd_bin;
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin <= {PTR_W{1'b0}};
        end else begin
            rd_bin <= rd_bin_next;
        end
    end

    // -------------------------------------------------------------------------
    // [5] 读侧格雷码 + 空判定
    //     空判定: 读侧格雷码_next 与写侧同步格雷码完全相等
    //     （读指针追上写指针 = 已读空）
    // -------------------------------------------------------------------------
    always @(*) begin
        rd_gray_next = (rd_bin + 1'b1) ^ ((rd_bin + 1'b1) >> 1);
        rd_empty_next = (rd_gray_next == wr_gray_rd2);
        if (!rd_en || rd_empty) begin
            rd_gray_next = rd_gray;
            rd_empty_next = (rd_gray == wr_gray_rd2);
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_gray  <= {PTR_W{1'b0}};
            rd_empty <= 1'b1;          // 复位后必为空
        end else begin
            rd_gray  <= rd_gray_next;
            rd_empty <= rd_empty_next;
        end
    end

    // -------------------------------------------------------------------------
    // [6] 两级同步器（打两拍）
    //     第 1 级可能出现亚稳态，第 2 级把概率压到可接受范围
    //     格雷码保证跨域时只有 1 bit 在变 → 即使第 1 级采到中间值，
    //     第 2 级得到的要么是旧值要么是新值，不会是多 bit 乱码
    // -------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_wr1 <= {PTR_W{1'b0}};
            rd_gray_wr2 <= {PTR_W{1'b0}};
        end else begin
            rd_gray_wr1 <= rd_gray;
            rd_gray_wr2 <= rd_gray_wr1;
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_rd1 <= {PTR_W{1'b0}};
            wr_gray_rd2 <= {PTR_W{1'b0}};
        end else begin
            wr_gray_rd1 <= wr_gray;
            wr_gray_rd2 <= wr_gray_rd1;
        end
    end

endmodule
