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
//     - 存储用**块 RAM + FWFT 预取寄存器**（同步读），读出仍是"当拍可取队头"
//       （t25 改动：原先用分布式 RAM 的异步组合读，读出无延迟，但深度合计
//        512×32 的阵列被综合成 1,633 个 LUT4，是全工程最大的一笔 LUT 支出。
//        改为同步读后阵列进 BRAM，见下文【六、存储阵列的推断方式】）
//
// 【三、接口与内部结构】
//   端口一览:
//     写侧（wr_clk 域）: wr_clk/wr_rst_n/wr_en/wr_data[W-1:0]/wr_full
//     读侧（rd_clk 域）: rd_clk/rd_rst_n/rd_en/rd_data[W-1:0]/rd_empty
//
//   内部逻辑块（共 7 块）:
//     [1] 存储阵列 mem        双口：写由 wr_clk 驱动，读由 rd_clk 驱动（同步）
//     [2] 写侧二进制指针      wr_bin / wr_bin_next
//     [3] 写侧格雷码 + 满判定 wr_gray / 同步后的 rd_gray
//     [4] 读侧二进制指针      rd_bin / rd_bin_next
//     [5] 读侧格雷码 + 空判定 rd_gray / 同步后的 wr_gray
//     [6] 两级同步器          wr_gray→rd_clk 域、rd_gray→wr_clk 域
//     [7] FWFT 预取寄存器     rd_data_r（t25 新增，见下）
//
// 【四、时序行为】
//   - 写入: wr_en=1 且 wr_full=0 时，当拍 wr_data 在 wr_clk 上升沿写入 mem
//   - 读出: rd_data **当拍即可取用**（rd_en=1 且 rd_empty=0 时），
//           指针在 rd_clk 上升沿前进。注意"当拍可取"不是靠组合读实现的，
//           而是靠预取寄存器 rd_data_r：它在任意拍恒等于 mem[rd_bin]，
//           即"当前队头"。详见【六】。
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
//
// 【六、存储阵列的推断方式 —— 改之前先读这段（t25）】
//   为什么要改: 原实现用异步组合读（`assign rd_data = mem[rd_bin[...]]`），
//     结构上无法映射块 RAM，综合器只能用 LUT4 拼阵列。`u_pix_fifo`
//     （512×32 = 16,384 bit）因此在 route 后占 1,633 个 LUT —— 全工程最大
//     的一笔 LUT 支出，而 route 后总 LUT 已 18,473 / 19,600 = 94.25%。
//   怎么改: 读口改为 `rd_clk` 同步读进预取寄存器 rd_data_r。
//   ★ 为什么能保持"当拍取队头": 预取地址取**次态** rd_bin_next 而非当前 rd_bin。
//     因为 rd_data_r 是**上一拍**采样 rd_bin_next 得到的，而那一拍的 rd_bin_next
//     恰好就是这一拍的 rd_bin ⇒ rd_data_r 在任意拍恒等于 mem[rd_bin]。逐拍等价。
//   ★ 为什么不需要 priming（空→非空的首字）: 预取是**无条件每拍采样**的。
//     FIFO 空且刚写进一个字时，rd_en=0 或 rd_empty=1 ⇒ rd_bin_next == rd_bin
//     ⇒ 采到的正是 mem[rd_bin]，也就是刚写进来的那个字；下一拍 rd_empty 落低时
//     rd_data_r 已经是正确队头。零额外状态、零额外逻辑。
//   ★ 千万不要加 `else if (!rd_empty)` 之类的采样门控: 那会让空时的预取失效，
//     正是"加了门控反而错"的经典写法（tb_fifo_fwft 的 MUTATION-2 实测 errors=74）。
//   ★ 同理不要改回采当前态 rd_bin: 那会让 rd_data_r 落后一项
//     （MUTATION-1 实测 errors=2162）。
//   ★ `(* ram_style = "block" *)` 属性单独加**无效**：实测「异步读 + 属性」
//     与「异步读无属性」面积逐字相同（2,317 LUT / 0 BRAM）。属性只是辅助，
//     **决定推断结果的是读法**。反例：同一份代码在 57 位上下文里，
//     异步读同样掉回 LUTRAM（4,196 LUT / 0 BRAM）。
// =============================================================================
`timescale 1ns / 1ps

module async_fifo #(
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
    output wire [DATA_WIDTH-1:0] rd_data,      // 读数据（FWFT 预取寄存器输出）
    output reg                   rd_empty      // 空标志（寄存器输出）
);

    localparam PTR_W = ADDR_WIDTH + 1;         // 指针多 1 位用于区分空/满
    localparam DEPTH = (1 << ADDR_WIDTH);

    // -------------------------------------------------------------------------
    // 内部信号声明（Verilog-2001 要求在使用前声明，故集中放在此处）
    // -------------------------------------------------------------------------
    // t25: 存储阵列加 ram_style 提示，让综合器优先用块 RAM。
    //      注意这只是"提示"，真正决定能不能推断成 BRAM 的是下方的同步读口
    //      （见【六】）。阵列位宽/深度不变，不消耗额外 BRAM 端口。
    (* ram_style = "block" *) reg  [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg  [PTR_W-1:0]      wr_bin, wr_bin_next;      // 写侧二进制指针
    reg  [PTR_W-1:0]      wr_gray, wr_gray_next;    // 写侧格雷码
    reg  [PTR_W-1:0]      rd_gray_wr1, rd_gray_wr2; // 读格雷码 → wr 域同步
    reg                   wr_full_next;

    reg  [PTR_W-1:0]      rd_bin, rd_bin_next;      // 读侧二进制指针
    reg  [PTR_W-1:0]      rd_gray, rd_gray_next;    // 读侧格雷码
    reg  [PTR_W-1:0]      wr_gray_rd1, wr_gray_rd2; // 写格雷码 → rd 域同步
    reg                   rd_empty_next;
    reg  [PTR_W-1:0]      rd_bin_wr_sync;
    reg  [DATA_WIDTH-1:0] rd_data_r;                // t25: FWFT 预取寄存器
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
    //     写端口: wr_clk 上升沿同步写入
    //     读端口: rd_clk 上升沿同步读出，读地址用**本域**读指针的低位
    //     t25: 读口必须是同步的，否则综合器无法推断块 RAM（见【六】）
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_en && !wr_full) begin
            mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end

    // -------------------------------------------------------------------------
    // [7] FWFT 预取寄存器（t25 新增）
    //     目的: 在不牺牲"当拍取队头"的前提下，把存储阵列换成块 RAM。
    //
    //     ★ 采样地址必须是**次态** rd_bin_next，不能是当前态 rd_bin。
    //       本拍采到的是"上一拍算出的次态"，而上一拍的次态恰好等于本拍的
    //       rd_bin ⇒ rd_data_r 在任意拍恒等于 mem[rd_bin]（当前队头）。
    //       若改用当前态 rd_bin，rd_data_r 会落后一项（MUTATION-1: errors=2162）。
    //
    //     ★ 必须**无条件每拍采样**，不能加 `if (!rd_empty)` 之类的门控。
    //       FIFO 空且刚写入一个字时 rd_bin_next == rd_bin，采到的正是那个字，
    //       下一拍 rd_empty 落低时数据已就位 —— 空→非空的首字（priming）
    //       靠的就是这条，不需要任何额外逻辑。
    //       加门控会让 priming 失效（MUTATION-2: errors=74）。
    // -------------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_data_r <= {DATA_WIDTH{1'b0}};
        end else begin
            rd_data_r <= mem[rd_bin_next[ADDR_WIDTH-1:0]];
        end
    end

    // rd_data 端口类型保持 output wire 不变：内部寄存器驱动 + assign 引出，
    // 这样两个例化点（pix_reader / image_player）一行都不用改。
    assign rd_data = rd_data_r;

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
