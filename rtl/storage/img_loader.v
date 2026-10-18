// ============================================================================
//  img_loader.v —— 图片装载器：FAT32 定位 → 簇链遍历 → BMP 解析 → 拼字 → SDRAM
//
//  阶段四 S6（全链）的核心模块，把 S1~S5 的模块缝合成一条流水线：
//
//      sd_spi_ctrl ──扇区数据──> fat32_reader（定位 首簇/大小/数据区参数）
//                              │
//                              └──> 本模块沿 FAT 簇链自己算数据扇区号
//                                     │
//                                     ├──> bmp_parser（头解析 + 24bit→RGB565）
//                                     │        │ pix_valid/pix_rgb565
//                                     │        v
//                                     └──> 像素拼字（2 像素/32bit）→ async_fifo
//                                              │
//                                              v
//                                        framebuf_arbiter（写入 SDRAM）
//
//  为什么需要这个模块（而不是把逻辑塞进顶层）:
//    1) SD 扇区是「一次 512 字节的顺序流」，BMP 是「逐像素」的，速率差 1536 倍；
//       本模块负责把字节流按需喂给 bmp_parser。
//    2) FAT32 簇链遍历要反复读 FAT 表（每跨一簇读一次），而 bmp_parser
//       只认连续字节流、不认中间插入的 FAT 扇区。本模块用「先取下一簇、
//       再读数据扇区」的顺序把两者隔开。
//    3) 像素必须 2 个拼成 32 位字，才能配合 framebuf_arbiter 的 4 拍突发组
//       （一组写 4 字 = 8 像素）。
//
//  ★ 背压说明（本模块最关键的约束）★
//    bmp_parser 是纯流式模块，**没有反压能力** —— 一旦喂字节就必须产出像素。
//    因此本模块采用**扇区级粗粒度背压**：每个扇区开始前若 FIFO 已满就原地等待。
//    一个 512 字节扇区最多产出 512/3 ≈ 171 像素 ≈ 86 个 32 位字，而 FIFO
//    深度 511，因此只要「扇区开始前 FIFO 不满」就能保证整扇区不丢像素。
//    代价是 FIFO 偶尔短暂空转，换来 bmp_parser 无需改造。
//
//  错误码:
//     1 = FAT32 定位失败        2 = BMP 头解析失败
//     3 = 底层读块失败          4 = FAT 簇链异常
//     5 = FIFO 长时间无空间（下游卡死）
//
//  时钟域: 全程 25MHz（与 sd_spi_ctrl / fat32_reader / bmp_parser 同域）。
//          跨到 150MHz 的 SDRAM 侧由 async_fifo 承担，本模块不碰跨时钟域。
// ============================================================================
module img_loader #(
    parameter CLK_FREQ_HZ = 25_000_000, // 主时钟频率
    parameter CHAIN_MAX   = 255,        // 单文件簇数上限（防死循环）
    parameter WR_TIMEOUT  = 1_048_576   // 等 FIFO 空间的最长拍数（约 42ms @25MHz）
)(
    input  wire        clk,             // 25MHz
    input  wire        rst_n,           // 异步复位，低有效

    // —— 上层控制 ——
    input  wire        start,           // 脉冲: 启动一次装载
    input  wire [8:0]  img_index,       // 电平: 目标图片序号 1~999
    input  wire [15:0] cfg_w,           // 电平: 期望图像宽（给 bmp_parser 校验）
    input  wire [15:0] cfg_h,           // 电平: 期望图像高
    output reg         busy,            // 电平: 装载进行中
    output reg         done,            // 电平: 装载成功（保持到下次 start）
    output reg         fail,            // 电平: 装载失败（保持到下次 start）
    output reg  [3:0]  err_code,        // 电平: 失败原因（见文件头）
    output reg  [31:0] pix_count,       // 电平: 已产出像素总数（调试/校验用）

    // —— 对接 sd_spi_ctrl（扇区读取服务，内部并联 fat32_reader）——
    output wire        blk_start,       // 脉冲: 启动读一块
    output wire [31:0] blk_addr,        // 电平: 扇区号
    input  wire        blk_done,        // 脉冲: 块读完成
    input  wire        blk_err,         // 脉冲: 块读失败
    input  wire [7:0]  data_byte,       // 电平: 块数据字节
    input  wire        data_valid,      // 脉冲: 字节有效

    // —— 对接 bmp_parser ——
    output wire        bmp_start,       // 脉冲: 启动解析（锁期望宽高）
    output wire [15:0] bmp_exp_w,       // 期望宽
    output wire [15:0] bmp_exp_h,       // 期望高
    output wire        byte_valid,      // 脉冲: 字节有效（仅数据扇区）
    output wire [7:0]  byte_data,       // 电平: 字节数据
    output wire        byte_sof,        // 脉冲: 文件第 0 字节（off_cnt 归零）
    input  wire        bmp_hdr_fail,    // 头非法（单拍）
    input  wire        pix_valid,       // 像素有效（单拍）
    input  wire [15:0] pix_rgb565,      // RGB565 像素

    // —— 对接 async_fifo（像素跨域到 150MHz 侧）——
    output reg         fifo_wr_en,      // 写使能（1 拍脉冲）
    output reg  [31:0] fifo_wr_data,    // {奇数x像素, 偶数x像素}
    output reg  [3:0]  fifo_wr_dm,      // 字节掩码，全写时为 4'h0
    input  wire        fifo_wr_full     // 满标志（寄存器输出，与 wr_en 同域）
);

    // ------------------------------------------------------------------------
    //  错误码
    // ------------------------------------------------------------------------
    localparam [3:0] E_FATLOC  = 4'd1,
                     E_BMPHDR  = 4'd2,
                     E_BLKIO   = 4'd3,
                     E_CHAIN   = 4'd4,
                     E_WRSTALL = 4'd5;

    // ------------------------------------------------------------------------
    //  状态机
    //      T_IDLE    等 start
    //      T_FATLOC  委托 fat32_reader 定位，等 found/fail
    //      T_CHKSPC  每个扇区前的决策点：收尾 / 等 FIFO / 取 FAT / 读数据
    //      T_FATRD   收 FAT 扇区，摘 4 字节簇号，块结束时评估
    //      T_DATRD   收数据扇区，逐字节转发给 bmp_parser
    //      T_FINISH  收尾（单像素补半字由块[3]处理）
    //      T_DONE    成功终态
    //      T_FAIL    失败终态
    // ------------------------------------------------------------------------
    localparam [3:0] T_IDLE   = 4'd0,
                     T_FATLOC = 4'd1,
                     T_CHKSPC = 4'd2,
                     T_FATRD  = 4'd3,
                     T_DATRD  = 4'd4,
                     T_FINISH = 4'd5,
                     T_DONE   = 4'd6,
                     T_FAIL   = 4'd7;

    reg  [3:0]  st;

    // ------------------------------------------------------------------------
    //  与 fat32_reader 的握手
    // ------------------------------------------------------------------------
    reg         fat_start;
    reg  [8:0]  fat_index;
    wire        fat_busy, fat_found, fat_fail;
    wire [3:0]  fat_err;
    wire [31:0] fat_size;
    wire [31:0] fat_first_clu;
    wire [31:0] fat_data_begin;
    wire [31:0] fat_fat_begin;
    wire [7:0]  fat_spc;
    wire        fr_blk_start;
    wire [31:0] fr_blk_addr;

    // ------------------------------------------------------------------------
    //  簇链遍历寄存器
    // ------------------------------------------------------------------------
    reg  [31:0] cur_cluster;
    reg  [15:0] chain_cnt;
    reg  [31:0] bytes_left;
    reg  [7:0]  sec_in_clu;
    reg  [9:0]  byte_cnt;
    reg  [8:0]  fat_off;
    reg  [3:0]  fat_byte_i;
    reg  [31:0] fat_val;
    reg  [3:0]  spc_shift;
    reg         sof_pending;   // 1 = 下一字节是文件第 0 字节（待发 sof）
    reg         sof_hold;      // 1 = 已发 sof，本拍要补送第 0 字节

    // 像素拼字状态（块[2] 独占驱动）
    reg  [15:0] pix_lo;        // 暂存的偶数 x 像素
    reg         pix_odd;       // 1 = 已存下一个，等第二个配对

    // 数据扇区号: data_begin + ((cluster - 2) << spc_shift)
    //   用移位代替乘法 —— spc 恒为 2 的幂（fat32_reader 已在 VBR 阶段校验）
    wire [31:0] clu_off     = cur_cluster - 32'd2;
    wire [34:0] clu_off_shl = {3'd0, clu_off} << spc_shift;
    wire [31:0] dat_clu_sec = fat_data_begin + clu_off_shl[31:0];
    // FAT 项所在扇区: fat_begin + (cluster >> 7)；项内偏移: (cluster & 127) * 4
    wire [31:0] fat_sec_add   = fat_fat_begin + {25'd0, cur_cluster[31:7]};
    wire [8:0]  fat_entry_off = {cur_cluster[6:0], 2'b00};

    // ------------------------------------------------------------------------
    //  SD 总线并联: fat32_reader 与 本模块 分时占用
    //    定位阶段由 fat32_reader 驱动，其余阶段由本模块驱动。
    //    blk_owner 明确归属，避免两个请求源同时拉高。
    // ------------------------------------------------------------------------
    reg         blk_owner;
    reg         blk_start_i;
    reg  [31:0] blk_addr_i;
    assign blk_start = blk_owner ? blk_start_i : fr_blk_start;
    assign blk_addr  = blk_owner ? blk_addr_i  : fr_blk_addr;

    // ------------------------------------------------------------------------
    //  bmp_parser 的字节转发
    //    只有数据扇区的字节才允许进 bmp_parser；FAT/目录/MBR 字节混进去
    //    会让 offset 全乱，所以用独立的转发寄存器隔离。
    // ------------------------------------------------------------------------
    reg         bmp_start_r;
    reg         byte_valid_r;
    reg  [7:0]  byte_data_r;
    reg         byte_sof_r;
    assign bmp_start  = bmp_start_r;
    assign bmp_exp_w  = cfg_w;
    assign bmp_exp_h  = cfg_h;
    assign byte_valid = byte_valid_r;
    assign byte_data  = byte_data_r;
    assign byte_sof   = byte_sof_r;

    // ------------------------------------------------------------------------
    //  spc → 移位量（组合，替代被禁用的 function）
    //    spc 只可能是 1/2/4/8/16/32/64/128 之一。
    // ------------------------------------------------------------------------
    reg [3:0] spc_shift_c;
    always @(*) begin
        if      (fat_spc >= 8'd128) spc_shift_c = 4'd7;
        else if (fat_spc >= 8'd64)  spc_shift_c = 4'd6;
        else if (fat_spc >= 8'd32)  spc_shift_c = 4'd5;
        else if (fat_spc >= 8'd16)  spc_shift_c = 4'd4;
        else if (fat_spc >= 8'd8)   spc_shift_c = 4'd3;
        else if (fat_spc >= 8'd4)   spc_shift_c = 4'd2;
        else if (fat_spc >= 8'd2)   spc_shift_c = 4'd1;
        else                        spc_shift_c = 4'd0;
    end

    // ------------------------------------------------------------------------
    //  [1] 主序列机
    // ------------------------------------------------------------------------
    reg [31:0] stall_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st           <= T_IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            fail         <= 1'b0;
            err_code     <= 4'd0;
            fat_start    <= 1'b0;
            fat_index    <= 9'd0;
            blk_owner    <= 1'b0;
            blk_start_i  <= 1'b0;
            blk_addr_i   <= 32'd0;
            bmp_start_r  <= 1'b0;
            cur_cluster  <= 32'd0;
            chain_cnt    <= 16'd0;
            bytes_left   <= 32'd0;
            sec_in_clu   <= 8'd0;
            byte_cnt     <= 10'd0;
            fat_off      <= 9'd0;
            fat_byte_i   <= 4'd0;
            fat_val      <= 32'd0;
            spc_shift    <= 4'd0;
            sof_pending  <= 1'b0;
            sof_hold     <= 1'b0;
            byte_valid_r <= 1'b0;
            byte_data_r  <= 8'd0;
            byte_sof_r   <= 1'b0;
            stall_cnt    <= 32'd0;
        end else begin
            // 默认单拍信号归零
            fat_start   <= 1'b0;
            blk_start_i <= 1'b0;
            bmp_start_r <= 1'b0;
            byte_sof_r  <= 1'b0;

            case (st)
            // ------------------------------------------------------------
            T_IDLE: begin
                busy      <= 1'b0;
                blk_owner <= 1'b0;
                if (start) begin
                    busy         <= 1'b1;
                    done         <= 1'b0;
                    fail         <= 1'b0;
                    err_code     <= 4'd0;
                    chain_cnt    <= 16'd0;
                    stall_cnt    <= 32'd0;
                    byte_valid_r <= 1'b0;
                    sof_pending  <= 1'b0;
                    sof_hold     <= 1'b0;
                    fat_index    <= img_index;
                    fat_start    <= 1'b1;
                    st           <= T_FATLOC;
                end
            end
            // ------------------------------------------------------------
            T_FATLOC: begin
                if (fat_found) begin
                    bytes_left   <= fat_size;
                    cur_cluster  <= fat_first_clu;
                    sec_in_clu   <= 8'd0;
                    spc_shift    <= spc_shift_c;
                    sof_pending  <= 1'b1;
                    bmp_start_r  <= 1'b1;      // 数据流开始前先启动解析器
                    blk_owner    <= 1'b1;
                    st           <= T_CHKSPC;
                end else if (fat_fail) begin
                    err_code <= E_FATLOC;
                    st       <= T_FAIL;
                end
            end
            // ------------------------------------------------------------
            //  扇区级决策点
            // ------------------------------------------------------------
            T_CHKSPC: begin
                if (bytes_left == 32'd0) begin
                    st <= T_FINISH;
                end else if (fifo_wr_full) begin
                    // 粗粒度背压：满就原地等，超时判下游卡死
                    if (stall_cnt >= WR_TIMEOUT[31:0]) begin
                        err_code <= E_WRSTALL;
                        st       <= T_FAIL;
                    end else begin
                        stall_cnt <= stall_cnt + 32'd1;
                    end
                end else if (sec_in_clu >= fat_spc) begin
                    // 本簇读完 → 读 FAT 表取下一簇
                    stall_cnt   <= 32'd0;
                    fat_off     <= fat_entry_off;
                    fat_byte_i  <= 4'd0;
                    fat_val     <= 32'd0;
                    byte_cnt    <= 10'd0;
                    blk_addr_i  <= fat_sec_add;
                    blk_start_i <= 1'b1;
                    st          <= T_FATRD;
                end else begin
                    stall_cnt   <= 32'd0;
                    byte_cnt    <= 10'd0;
                    blk_addr_i  <= dat_clu_sec + {24'd0, sec_in_clu};
                    blk_start_i <= 1'b1;
                    st          <= T_DATRD;
                end
            end
            // ------------------------------------------------------------
            //  FAT 扇区接收: 只摘 4 字节，块结束时评估簇链
            // ------------------------------------------------------------
            T_FATRD: begin
                if (blk_err) begin
                    err_code <= E_BLKIO;
                    st       <= T_FAIL;
                end else if (data_valid) begin
                    if (byte_cnt >= fat_off && byte_cnt < (fat_off + 9'd4)) begin
                        case (fat_byte_i)
                            4'd0:    fat_val[7:0]   <= data_byte;
                            4'd1:    fat_val[15:8]  <= data_byte;
                            4'd2:    fat_val[23:16] <= data_byte;
                            default: fat_val[31:24] <= data_byte;
                        endcase
                        fat_byte_i <= fat_byte_i + 4'd1;
                    end
                    byte_cnt <= byte_cnt + 10'd1;
                end else if (blk_done) begin
                    // 簇链合法性: EOC(≥0x0FFFFFF8) 之外的 <2 或保留区都非法
                    if (fat_val >= 32'h0FFF_FFF8) begin
                        // 链尾 —— 文件本应读完；没读完说明文件被截断
                        if (bytes_left != 32'd0) begin
                            err_code <= E_CHAIN;
                            st       <= T_FAIL;
                        end else begin
                            st <= T_FINISH;
                        end
                    end else if (fat_val < 32'd2 || fat_val > 32'h0FFF_FFEF) begin
                        err_code <= E_CHAIN;
                        st       <= T_FAIL;
                    end else if (chain_cnt >= CHAIN_MAX) begin
                        err_code <= E_CHAIN;
                        st       <= T_FAIL;
                    end else begin
                        cur_cluster <= fat_val;
                        sec_in_clu  <= 8'd0;
                        chain_cnt   <= chain_cnt + 16'd1;
                        st          <= T_CHKSPC;
                    end
                end
            end
            // ------------------------------------------------------------
            //  数据扇区接收: 逐字节转发给 bmp_parser
            //    ★ byte_sof 的语义是「本拍只清 off_cnt、不消费字节」
            //      （见 bmp_parser.v 的 ST_HDR: if (byte_sof) off_cnt<=0;
            //        else if (byte_valid) case(off_cnt) ...），
            //      因此文件第 0 字节必须**分成两拍**：
            //        第 1 拍: byte_sof=1, byte_valid=0  → 清偏移
            //        第 2 拍: byte_valid=1, byte_sof=0  → 送 'B'
            //      若同一拍既 sof 又 valid，'B' 会被丢弃、整幅图偏移 1 字节。
            // ------------------------------------------------------------
            T_DATRD: begin
                if (blk_err) begin
                    byte_valid_r <= 1'b0;
                    err_code     <= E_BLKIO;
                    st           <= T_FAIL;
                end else if (sof_pending && data_valid) begin
                    // 第 0 字节到来：本拍只发 sof，字节留到下一拍再送
                    byte_sof_r   <= 1'b1;
                    byte_valid_r <= 1'b0;
                    byte_data_r  <= data_byte;   // 先存住，下一拍送出
                    sof_pending  <= 1'b0;
                    sof_hold     <= 1'b1;        // 标记"有字节待补送"
                end else if (sof_hold) begin
                    // 补送第 0 字节（bmp_parser 此时 off_cnt 已归零）
                    byte_sof_r   <= 1'b0;
                    byte_valid_r <= 1'b1;        // byte_data_r 保持为上拍存入的值
                    sof_hold     <= 1'b0;
                    if (bytes_left != 32'd0) bytes_left <= bytes_left - 32'd1;
                end else if (data_valid) begin
                    // ★ 文件字节已耗尽：扇区尾部的填充字节绝不能再喂给
                    //   bmp_parser —— 否则它会把磁盘垃圾当成像素继续产出，
                    //   表现为"像素数远超文件应有值"（T01 期望 64 实得 152）。
                    //   此时只静默丢弃，但仍需等 blk_done 收完整块。
                    if (bytes_left == 32'd0) begin
                        byte_valid_r <= 1'b0;
                    end else begin
                        byte_valid_r <= 1'b1;
                        byte_data_r  <= data_byte;
                        bytes_left   <= bytes_left - 32'd1;
                    end
                end else begin
                    byte_valid_r <= 1'b0;
                    if (bmp_hdr_fail) begin
                        err_code <= E_BMPHDR;
                        st       <= T_FAIL;
                    end else if (blk_done) begin
                        sec_in_clu <= sec_in_clu + 8'd1;
                        stall_cnt  <= 32'd0;
                        st         <= T_CHKSPC;
                    end
                end
            end
            // ------------------------------------------------------------
            T_FINISH: begin
                blk_owner <= 1'b0;
                st        <= T_DONE;
            end
            // ------------------------------------------------------------
            T_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
            end
            // ------------------------------------------------------------
            T_FAIL: begin
                busy         <= 1'b0;
                fail         <= 1'b1;
                blk_owner    <= 1'b0;
                byte_valid_r <= 1'b0;
            end
            // ------------------------------------------------------------
            default: st <= T_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    //  [2] 像素拼字 + FIFO 写入
    //    pix_odd=0: 暂存到 pix_lo（偶数 x 的像素）
    //    pix_odd=1: 与 pix_lo 拼成 {奇数x, 偶数x} 写入 FIFO
    //    奇数宽度图像最后一个像素没有配对 —— 收尾时用 dm 只写低半字。
    //    ★ 本块是 pix_count/pix_lo/pix_odd/fifo_* 的**唯一驱动者**，
    //      主序列机不得再碰这些寄存器（避免 lint E2 多驱动）。
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_lo       <= 16'd0;
            pix_odd      <= 1'b0;
            pix_count    <= 32'd0;
            fifo_wr_en   <= 1'b0;
            fifo_wr_data <= 32'd0;
            fifo_wr_dm   <= 4'h0;
        end else if (st == T_IDLE && start) begin
            pix_lo       <= 16'd0;
            pix_odd      <= 1'b0;
            pix_count    <= 32'd0;
            fifo_wr_en   <= 1'b0;
            fifo_wr_dm   <= 4'h0;
        end else begin
            fifo_wr_en <= 1'b0;
            if (pix_valid) begin
                pix_count <= pix_count + 32'd1;
                if (!pix_odd) begin
                    pix_lo  <= pix_rgb565;
                    pix_odd <= 1'b1;
                end else begin
                    pix_odd      <= 1'b0;
                    fifo_wr_data <= {pix_rgb565, pix_lo};
                    fifo_wr_dm   <= 4'h0;
                    fifo_wr_en   <= 1'b1;
                end
            end
            // 收尾: 若还有单像素没配对，补一个只写低半字的字
            if (st == T_FINISH && pix_odd) begin
                pix_odd      <= 1'b0;
                fifo_wr_data <= {16'h0000, pix_lo};
                fifo_wr_dm   <= 4'hC;      // dm=1 表示屏蔽 → 只写 [15:0]
                fifo_wr_en   <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------------
    //  fat32_reader 例化（本模块作为它的上层）
    // ------------------------------------------------------------------------
    fat32_reader #(
        .CLK_FREQ_HZ   (CLK_FREQ_HZ),
        .FAT_CHAIN_MAX (64)
    ) u_fat (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (fat_start),
        .img_index      (fat_index),
        .busy           (fat_busy),
        .found          (fat_found),
        .fail           (fat_fail),
        .err_code       (fat_err),
        .file_size      (fat_size),
        .first_cluster  (fat_first_clu),
        .out_data_begin (fat_data_begin),
        .out_fat_begin  (fat_fat_begin),
        .out_spc        (fat_spc),
        .blk_start      (fr_blk_start),
        .blk_addr       (fr_blk_addr),
        .blk_busy       (1'b0),
        .blk_done       (blk_done),
        .blk_err        (blk_err),
        .data_byte      (data_byte),
        .data_valid     (data_valid)
    );

endmodule
