// ============================================================================
//  tb_img_loader.v —— img_loader 测试平台（S6 装载链路）
//
//  测试策略:
//    用**真实的** fat32_reader + bmp_parser 与 DUT 对接，只把 sd_spi_ctrl
//    替换成"扇区读取模型"（按 blk_addr 从内存镜像里吐出 512 字节）。
//    这样测的是真实的模块间协作，而不是 mock 出来的接口。
//
//  磁盘镜像布局（扇区号）:
//    L_MBR  = 0    MBR（分区表项0 指向 PART_LBA）
//    L_VBR  = 4    VBR/BPB（reserved=1, spc=1, num_fats=2, fat_size=1, root=2）
//    L_FAT1 = 5    FAT 表副本 1
//    L_FAT2 = 6    FAT 表副本 2
//    L_DIR0 = 7    数据区簇 2 = 根目录
//    L_FILE = 9    数据区簇 4 = 文件数据起点
//    fat_begin = 5, data_begin = 7
//
//  用例:
//    T01 单簇小文件装载成功（少于 512 字节）
//    T02 跨 2 簇文件（FAT 链 4→5），验证簇链遍历与扇区地址换算
//    T03 跨 3 簇文件（4→5→6），验证多级链
//    T04 簇链在文件读完前结束（FAT=EOC 但 bytes_left≠0）→ err=4
//    T05 FAT 项为非法簇号（保留区 0x0FFFFFF0）→ err=4
//    T06 FAT 项为 0（空闲簇）→ err=4
//    T07 底层读块失败 → err=3
//    T08 BMP 头签名错 → err=2
//    T09 图片序号不存在 → err=1
//    T10 奇数像素收尾（图像含奇数个像素）→ dm 屏蔽高半字
//    T11 FIFO 长时间满 → err=5
//    T12 逐像素校验：按 BMP 黄金图案比对 FIFO 收到的每个像素
// ============================================================================
`timescale 1ns / 1ps

module tb_img_loader;

    localparam CLK_PERIOD = 40;            // 25MHz
    localparam NSEC       = 64;            // 镜像扇区数

    localparam [31:0] PART_LBA = 32'd4;
    localparam [15:0] L_MBR    = 16'd0;
    localparam [15:0] L_VBR    = 16'd4;
    localparam [15:0] L_FAT1   = 16'd5;
    localparam [15:0] L_FAT2   = 16'd6;
    localparam [15:0] L_DIR0   = 16'd7;
    localparam [15:0] L_FILE   = 16'd9;

    // ---- 时钟 / 复位 ----
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- DUT 端口 ----
    reg         start = 1'b0;
    reg  [8:0]  img_index = 9'd1;
    // 期望宽高（本 tb 用的都是小图，逐个用例设置）
    reg  [15:0] cfg_w = 16'd8;
    reg  [15:0] cfg_h = 16'd8;
    wire        busy, done, fail;
    wire [3:0]  err_code;
    wire [31:0] pix_count;

    wire        blk_start;
    wire [31:0] blk_addr;
    reg         blk_done = 1'b0;
    reg         blk_err  = 1'b0;
    reg  [7:0]  data_byte = 8'h00;
    reg         data_valid = 1'b0;

    wire        bmp_start;
    wire [15:0] bmp_exp_w, bmp_exp_h;
    wire        byte_valid;
    wire [7:0]  byte_data;
    wire        byte_sof;
    wire        bmp_hdr_fail;
    wire        pix_valid;
    wire [15:0] pix_rgb565;

    wire        fifo_wr_en;
    wire [31:0] fifo_wr_data;
    wire [3:0]  fifo_wr_dm;
    reg         fifo_wr_full = 1'b0;

    // ---- bmp_parser 的真实输出（DUT 内部例化，这里接到顶层观测）----
    wire        bmp_hdr_ok;
    wire [3:0]  bmp_err;
    wire [15:0] bmp_img_w, bmp_img_h;

    // ---- 磁盘镜像 ----
    reg [7:0] disk [0:NSEC*512-1];

    // ---- 统计 ----
    integer checks   = 0;
    integer fails    = 0;
    integer pix_seen = 0;
    integer wr_words = 0;

    // ------------------------------------------------------------------------
    //  DUT + 真实的 bmp_parser
    // ------------------------------------------------------------------------
    img_loader #(
        .CLK_FREQ_HZ (25_000_000),
        .CHAIN_MAX   (16),
        .WR_TIMEOUT  (4096)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .img_index     (img_index),
        .cfg_w         (cfg_w),
        .cfg_h         (cfg_h),
        .busy          (busy),
        .done          (done),
        .fail          (fail),
        .err_code      (err_code),
        .pix_count     (pix_count),
        .blk_start     (blk_start),
        .blk_addr      (blk_addr),
        .blk_done      (blk_done),
        .blk_err       (blk_err),
        .data_byte     (data_byte),
        .data_valid    (data_valid),
        .bmp_start     (bmp_start),
        .bmp_exp_w     (bmp_exp_w),
        .bmp_exp_h     (bmp_exp_h),
        .byte_valid    (byte_valid),
        .byte_data     (byte_data),
        .byte_sof      (byte_sof),
        .bmp_hdr_fail  (bmp_hdr_fail),
        .pix_valid     (pix_valid),
        .pix_rgb565    (pix_rgb565),
        .fifo_wr_en    (fifo_wr_en),
        .fifo_wr_data  (fifo_wr_data),
        .fifo_wr_dm    (fifo_wr_dm),
        .fifo_wr_full  (fifo_wr_full)
    );

    bmp_parser #(
        .DEFAULT_W (640),
        .DEFAULT_H (480)
    ) u_bmp (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (bmp_start),
        .exp_w      (bmp_exp_w),
        .exp_h      (bmp_exp_h),
        .byte_valid (byte_valid),
        .byte_data  (byte_data),
        .byte_sof   (byte_sof),
        .hdr_ok     (bmp_hdr_ok),
        .hdr_fail   (bmp_hdr_fail),
        .err_code   (bmp_err),
        .img_w      (bmp_img_w),
        .img_h      (bmp_img_h),
        .data_off   (),
        .pix_valid  (pix_valid),
        .pix_rgb565 (pix_rgb565),
        .pix_x      (),
        .pix_y      ()
    );

    // ------------------------------------------------------------------------
    //  扇区读取模型（顶替 sd_spi_ctrl）
    //    这是一个独立的小状态机：收到 blk_start 后逐字节吐出 512 字节，
    //    末尾给 blk_done。用状态机而非 fork，避免 always 块里的并发进程。
    // ------------------------------------------------------------------------
    localparam RD_GAP = 1;      // 字节间隔（拍）
    integer    rd_byte;
    reg [31:0] rd_lba;
    reg        err_inject = 1'b0;
    integer    err_lba = -1;   // >=0 时只在指定扇区注入错误
    integer    oob_hits = 0;

    localparam M_IDLE = 2'd0,
               M_RUN  = 2'd1,
               M_DONE = 2'd2;

    reg  [1:0]  mdl_st = M_IDLE;
    reg  [31:0] mdl_lba;
    integer     mdl_i;
    integer     mdl_gap;

    always @(posedge clk) begin
        if (!rst_n) begin
            blk_done   <= 1'b0;
            blk_err    <= 1'b0;
            data_valid <= 1'b0;
            data_byte  <= 8'h00;
            mdl_st     <= M_IDLE;
            mdl_i      = 0;
            mdl_gap    = 0;
        end else begin
            blk_done   <= 1'b0;
            blk_err    <= 1'b0;
            data_valid <= 1'b0;

            case (mdl_st)
            M_IDLE: begin
                if (blk_start) begin
                    if ($test$plusargs("dbg"))
                        $display("  [mdl] blk_start addr=%0d", blk_addr);
                    if (blk_addr >= NSEC) begin
                        $display("  FAIL: out-of-range LBA %0d", blk_addr);
                        oob_hits = oob_hits + 1;
                        blk_err  <= 1'b1;
                    end else if (err_inject && (err_lba < 0 || blk_addr == err_lba)) begin
                        blk_err  <= 1'b1;
                    end else begin
                        mdl_lba = blk_addr;
                        mdl_i   = 0;
                        mdl_gap = 0;
                        mdl_st  <= M_RUN;
                    end
                end
            end
            M_RUN: begin
                if (mdl_gap < RD_GAP) begin
                    mdl_gap = mdl_gap + 1;
                end else begin
                    mdl_gap = 0;
                    data_byte  <= disk[mdl_lba*512 + mdl_i];
                    data_valid <= 1'b1;
                    mdl_i = mdl_i + 1;
                    if (mdl_i >= 512) mdl_st <= M_DONE;
                end
            end
            M_DONE: begin
                blk_done <= 1'b1;
                mdl_st   <= M_IDLE;
            end
            default: mdl_st <= M_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    //  FIFO 观测（统计写入字数）
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && fifo_wr_en) wr_words = wr_words + 1;
    end

    // ------------------------------------------------------------------------
    //  像素内容校验器
    //    ★ 只数 pix_count 是**不够**的 —— 变异测试证明：让 cur_cluster 不更新
    //      （整个文件读成重复扇区）时像素数量仍正确，只有内容错了。
    //      这里按"第 n 个像素"反推它在图里的 (x,y)，与黄金图案逐点比对。
    //      n → x = n % w，y = top_down ? n/w : h-1-(n/w)
    // ------------------------------------------------------------------------
    integer    chk_en  = 0;
    integer    chk_seq = 0;
    integer    chk_err = 0;
    integer    chk_w   = 8;
    integer    chk_h   = 8;
    integer    chk_td  = 0;

    task check_one_pix;
        input integer seq;
        input [15:0] got;
        integer px, py;
        reg [23:0] e888;
        reg [15:0] e565;
        begin
            px = seq % chk_w;
            py = chk_td ? (seq / chk_w) : (chk_h - 1 - (seq / chk_w));
            e888 = golden888(px, py);
            e565 = {e888[23:19], e888[15:10], e888[7:3]};
            if (got !== e565) begin
                if (chk_err < 5)
                    $display("  FAIL: pixel(%0d,%0d) got %04h exp %04h", px, py, got, e565);
                chk_err = chk_err + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && fifo_wr_en && chk_en) begin
            check_one_pix(chk_seq, fifo_wr_data[15:0]);   // 低半字 = 偶数 x
            chk_seq = chk_seq + 1;
            if (fifo_wr_dm[2] == 1'b0) begin              // 高半字有效
                check_one_pix(chk_seq, fifo_wr_data[31:16]);
                chk_seq = chk_seq + 1;
            end
        end
    end

    task chk_begin;
        input integer w;
        input integer h;
        input integer td;
        begin
            chk_w = w; chk_h = h; chk_td = td;
            chk_seq = 0; chk_err = 0; chk_en = 1;
        end
    endtask

    task chk_end;
        input [255:0] label;
        begin
            chk_en = 0;
            checks = checks + 1;
            if (chk_err == 0) $display("  PASS: %0s 像素内容逐点一致", label);
            else begin
                $display("  FAIL: %0s 像素内容不符 %0d 处", label, chk_err);
                fails = fails + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------------
    //  辅助 task
    // ------------------------------------------------------------------------
    task chk;
        input cond;
        input [255:0] msg;
        begin
            checks = checks + 1;
            if (cond) $display("  PASS: %0s", msg);
            else begin
                $display("  FAIL: %0s", msg);
                fails = fails + 1;
            end
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            repeat (8) @(posedge clk);
            @(negedge clk) rst_n = 1'b1;
            repeat (4) @(posedge clk);
        end
    endtask

    task fire_start;
        input [8:0] idx;
        begin
            img_index = idx;
            @(negedge clk) start = 1'b1;
            @(negedge clk) start = 1'b0;
        end
    endtask

    // 带期望宽高的启动（cfg_w/cfg_h 由用例指定）
    task fire_start_wh;
        input [8:0]  idx;
        input [15:0] w;
        input [15:0] h;
        begin
            cfg_w = w;
            cfg_h = h;
            img_index = idx;
            @(negedge clk) start = 1'b1;
            @(negedge clk) start = 1'b0;
        end
    endtask

    // 等终态（带超时 guard，避免死等拖死整轮仿真）
    task wait_terminal;
        integer i;
        begin
            i = 0;
            while (!done && !fail && i < 4000000) begin
                @(posedge clk);
                i = i + 1;
            end
            if (i >= 4000000) begin
                $display("  FAIL: timeout waiting for terminal state");
                fails = fails + 1;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    // ---- 写字节 / 半字 / 字 ----
    task wr8;
        input [15:0] sec;
        input integer off;
        input [7:0] v;
        begin disk[sec*512 + off] = v; end
    endtask

    task wr16;
        input [15:0] sec;
        input integer off;
        input [15:0] v;
        begin
            disk[sec*512 + off]     = v[7:0];
            disk[sec*512 + off + 1] = v[15:8];
        end
    endtask

    task wr32;
        input [15:0] sec;
        input integer off;
        input [31:0] v;
        begin
            disk[sec*512 + off]     = v[7:0];
            disk[sec*512 + off + 1] = v[15:8];
            disk[sec*512 + off + 2] = v[23:16];
            disk[sec*512 + off + 3] = v[31:24];
        end
    endtask

    // ------------------------------------------------------------------------
    //  构造 24bit BMP 文件内容到镜像
    //    参数: w/h = 图像尺寸；chain = 是否写 FAT 链
    //          sec_start = 数据起始扇区；file_clu = 首簇号
    //  返回: 文件总字节数
    // ------------------------------------------------------------------------
    reg  [7:0]  bmp_buf [0:8191];       // 构造缓冲（本 tb 只测小图）
    integer     bmp_len;

    // 黄金像素: 对 (x,y) 敏感
    function [23:0] golden888;
        input integer gx, gy;
        begin
            golden888 = {gx[7:0], gy[7:0], gx[7:0] ^ gy[7:0]};
        end
    endfunction

    function [15:0] to565;
        input [23:0] c;
        begin
            to565 = {c[23:19], c[15:10], c[7:3]};
        end
    endfunction

    // 造一个 w×h 的 24bit BMP 到 bmp_buf，长度写入 bmp_len
    //   h 为负表示自顶向下
    integer bp;
    integer bx, by;
    reg [7:0] br, bg, bb;
    reg [23:0] bcolor;
    integer row_bytes, pad_bytes, file_bytes;

    task build_bmp;
        input integer w;
        input integer h;
        input integer dataoff;
        input integer top_down;
        begin
            row_bytes  = w * 3;
            pad_bytes  = (4 - (row_bytes % 4)) % 4;
            file_bytes = dataoff + (row_bytes + pad_bytes) * h;
            bmp_len    = file_bytes;

            // 清零
            for (bp = 0; bp < 8192; bp = bp + 1) bmp_buf[bp] = 8'h00;

            // ---- 14 字节文件头 ----
            bmp_buf[0]  = 8'h42;   // 'B'
            bmp_buf[1]  = 8'h4D;   // 'M'
            bmp_buf[2]  = file_bytes[7:0];
            bmp_buf[3]  = file_bytes[15:8];
            bmp_buf[4]  = file_bytes[23:16];
            bmp_buf[5]  = file_bytes[31:24];
            bmp_buf[10] = dataoff[7:0];
            bmp_buf[11] = dataoff[15:8];
            bmp_buf[12] = dataoff[23:16];
            bmp_buf[13] = dataoff[31:24];

            // ---- 40 字节信息头 ----
            bmp_buf[14] = 8'd40;
            bmp_buf[18] = w[7:0];
            bmp_buf[19] = w[15:8];
            if (top_down) begin
                bmp_buf[22] = (-h) & 8'hFF;
                bmp_buf[23] = ((-h) >> 8) & 8'hFF;
            end else begin
                bmp_buf[22] = h & 8'hFF;
                bmp_buf[23] = (h >> 8) & 8'hFF;
            end
            bmp_buf[26] = 8'd1;     // planes
            bmp_buf[28] = 8'd24;    // bpp

            // ---- 像素数据（BMP 是自底向上，除 top_down）----
            for (by = 0; by < h; by = by + 1) begin
                for (bx = 0; bx < w; bx = bx + 1) begin
                    bcolor = golden888(bx, by);
                    br = bcolor[23:16];
                    bg = bcolor[15:8];
                    bb = bcolor[7:0];
                    // 存储顺序是 B,G,R
                    bp = dataoff + (top_down ? (by * (row_bytes + pad_bytes))
                                             : ((h - 1 - by) * (row_bytes + pad_bytes)))
                                  + bx * 3;
                    bmp_buf[bp]     = bb;
                    bmp_buf[bp + 1] = bg;
                    bmp_buf[bp + 2] = br;
                end
            end
        end
    endtask

    // 把 bmp_buf 的内容摊到镜像里（连续的 sec_start 起的扇区）
    task flush_bmp;
        input [15:0] sec_start;
        input integer nbytes;
        integer i;
        begin
            for (i = 0; i < nbytes; i = i + 1)
                disk[sec_start*512 + i] = bmp_buf[i];
        end
    endtask

    // ------------------------------------------------------------------------
    //  构造完整磁盘镜像
    //    参数: w/h/dataoff/top_down 决定 BMP；chain_n 决定 FAT 链长度
    //          chain_n = 0 表示单簇（FAT 项=EOC）
    // ------------------------------------------------------------------------
    integer bi;
    task build_image;
        input integer w;
        input integer h;
        input integer dataoff;
        input integer top_down;
        input integer chain_n;      // 数据占用簇数（1 = 单簇）
        input [31:0] file_size_override;  // 0 = 用真实长度
        begin
            for (bi = 0; bi < NSEC*512; bi = bi + 1) disk[bi] = 8'h00;

            // ---- MBR ----
            wr8 (L_MBR, 446, 8'h80);           // 引导标志
            wr8 (L_MBR, 450, 8'h0C);           // 分区类型 FAT32 LBA
            wr32(L_MBR, 454, PART_LBA);        // 分区起始 LBA
            wr32(L_MBR, 458, 32'd4096);        // 扇区数
            wr16(L_MBR, 510, 16'hAA55);

            // ---- VBR ----
            wr16(L_VBR, 11, 16'd512);          // 每扇区字节数
            wr8 (L_VBR, 13, 8'd1);             // spc = 1
            wr16(L_VBR, 14, 16'd1);            // reserved = 1
            wr8 (L_VBR, 16, 8'd2);             // num_fats = 2
            wr32(L_VBR, 36, 32'd1);            // fat_size = 1
            wr32(L_VBR, 44, 32'd2);            // root_cluster = 2
            wr16(L_VBR, 510, 16'hAA55);

            // ---- 根目录簇 2（扇区 L_DIR0）----
            // 目录项 0: IMG001.BMP
            //   ★ 8.3 短名: 基名固定 8 字节（不足补 0x20 空格），扩展名 3 字节
            //     即 "IMG001  " + "BMP" —— 偏移 0..7 是基名，8..10 是扩展名。
            //     把 BMP 直接接在 "IMG001" 后面写在偏移 6/7/8 是错的，
            //     fat32_reader 期望偏移 6/7 = 空格、8/9/10 = 'B''M''P'。
            wr8 (L_DIR0, 0,  8'h49);  // 'I'
            wr8 (L_DIR0, 1,  8'h4D);  // 'M'
            wr8 (L_DIR0, 2,  8'h47);  // 'G'
            wr8 (L_DIR0, 3,  8'h30);  // '0'
            wr8 (L_DIR0, 4,  8'h30);  // '0'
            wr8 (L_DIR0, 5,  8'h31);  // '1'
            wr8 (L_DIR0, 6,  8'h20);  // 空格
            wr8 (L_DIR0, 7,  8'h20);  // 空格
            wr8 (L_DIR0, 8,  8'h42);  // 'B'
            wr8 (L_DIR0, 9,  8'h4D);  // 'M'
            wr8 (L_DIR0, 10, 8'h50);  // 'P'
            wr8 (L_DIR0, 11, 8'h20);  // 属性: 普通文件
            wr16(L_DIR0, 20, 16'h0000);  // 首簇高 16 位
            wr16(L_DIR0, 26, 16'd4);     // 首簇低 16 位 = 4
            if (file_size_override != 32'd0)
                wr32(L_DIR0, 28, file_size_override);
            else
                wr32(L_DIR0, 28, bmp_len);
            // 目录项 1: 结束标记
            wr8 (L_DIR0, 32, 8'h00);

            // ---- FAT 表：簇 4 起串联 ----
            //  簇 4 → 5 → 6 ... 最后一个 EOC
            if (chain_n <= 1) begin
                wr32(L_FAT1, 16, 32'h0FFF_FFF8);   // 簇4 = EOC
            end else begin
                for (bi = 0; bi < chain_n; bi = bi + 1) begin
                    if (bi == chain_n - 1)
                        wr32(L_FAT1, 16 + bi*4, 32'h0FFF_FFF8);
                    else
                        wr32(L_FAT1, 16 + bi*4, 32'd4 + bi + 1);
                end
            end

            // ---- 文件数据 ----
            flush_bmp(L_FILE, bmp_len);
        end
    endtask

    // ------------------------------------------------------------------------
    //  主测试流程
    // ------------------------------------------------------------------------
    integer i;
    integer tr_i;
    integer t_words;
    integer t_pix;
    reg [31:0] exp_words;

    initial begin
        $display("==============================================");
        $display(" tb_img_loader: S6 装载链路");
        $display("==============================================");

        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_img_loader.vcd");
            $dumpvars(0, tb_img_loader);
        end

        do_reset;

        // ====================================================================
        // T01 单簇小文件装载成功
        //   用 8x8 的小图（192 字节像素 + 54 头 = 246 字节，一簇即可）
        // ====================================================================
        $display("\n-- T01 单簇小文件 --");
        build_bmp(8, 8, 54, 0);
        build_image(8, 8, 54, 0, 1, 32'd0);
        do_reset;
        pix_seen = 0;
        wr_words = 0;
         chk_begin(8, 8, 0);
        fire_start_wh(9'd1, 16'd8, 16'd8);
        wait_terminal;
         chk_end("T01");
        $display("  T01: done=%b fail=%b err=%0d pix_count=%0d words=%0d",
                 done, fail, err_code, pix_count, wr_words);
        chk(done && !fail,        "T01 装载成功");
        chk(err_code == 4'd0,     "T01 err = 0");
        chk(pix_count == 64,      "T01 产出 64 像素 (8x8)");
        chk(wr_words == 32,       "T01 写入 32 个字 (64/2)");

        // ====================================================================
        // T02 跨 2 簇（FAT 链 4→5）
        //   16x8 = 128 像素，行 48 字节 pad=0，像素 384 字节 + 54 = 438 字节
        //   仍在一簇内 —— 为了真跨簇，需要 > 512 字节：用 24x8 = 576+54 = 630
        // ====================================================================
        $display("\n-- T02 跨 2 簇 --");
        build_bmp(24, 8, 54, 0);       // 24*8=192 像素，像素 576 字节，总 630
        build_image(24, 8, 54, 0, 2, 32'd0);
        do_reset;
        pix_seen = 0;
        wr_words = 0;
         chk_begin(24, 8, 0);
        fire_start_wh(9'd1, 16'd24, 16'd8);
        wait_terminal;
         chk_end("T02");
        $display("  T02: done=%b fail=%b err=%0d pix_count=%0d words=%0d",
                 done, fail, err_code, pix_count, wr_words);
        chk(done && !fail,        "T02 跨簇装载成功");
        chk(pix_count == 192,     "T02 产出 192 像素 (24x8)");
        chk(wr_words == 96,       "T02 写入 96 个字");

        // ====================================================================
        // T03 跨 3 簇（FAT 链 4→5→6）
        //   32x16 = 512 像素，像素 1536 字节，总 1590 字节 → 需 4 簇
        //   改用 chain_n=4 更贴切；这里保持 3 簇但文件只有 1590 字节
        //   → 实际会读满 3 簇(1536 字节数据区)后 EOC，文件本应更长
        //   所以改用 40x12 = 480 像素 = 1440 字节，总 1494，需 3 簇
        // ====================================================================
        $display("\n-- T03 跨 3 簇 --");
        build_bmp(40, 12, 54, 0);      // 480 像素，像素 1440，总 1494 → 3 簇
        build_image(40, 12, 54, 0, 3, 32'd0);
        do_reset;
        pix_seen = 0;
        wr_words = 0;
         chk_begin(40, 12, 0);
        fire_start_wh(9'd1, 16'd40, 16'd12);
        wait_terminal;
         chk_end("T03");
        $display("  T03: done=%b fail=%b err=%0d pix_count=%0d words=%0d",
                 done, fail, err_code, pix_count, wr_words);
        chk(done && !fail,        "T03 跨 3 簇装载成功");
        chk(pix_count == 480,     "T03 产出 480 像素 (40x12)");

        // ====================================================================
        // T04 簇链提前结束（FAT=EOC 但文件声明更大）
        // ====================================================================
        $display("\n-- T04 簇链提前结束 --");
        build_bmp(8, 8, 54, 0);
        // 文件实际 246 字节，但目录项声明 5000 字节；FAT 链只有 1 簇
        build_image(8, 8, 54, 0, 1, 32'd5000);
        do_reset;
        fire_start_wh(9'd1, 16'd8, 16'd8);
        wait_terminal;
        $display("  T04: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T04 装载失败");
        chk(err_code == 4'd4,     "T04 err = 4 (簇链异常)");

        // ====================================================================
        // T05 FAT 项为保留区值 0x0FFFFFF0
        // ====================================================================
        $display("\n-- T05 FAT 项保留区 --");
        build_bmp(24, 8, 54, 0);
        build_image(24, 8, 54, 0, 1, 32'd0);   // ★ 单簇：注入的读块错误必须落在数据阶段，
        //   若用多簇，错误会先被 T_FATRD 捕获、走不到 T_DATRD。
        wr32(L_FAT1, 16, 32'h0FFF_FFF0);    // 簇4 → 保留区
        do_reset;
        fire_start_wh(9'd1, 16'd24, 16'd8);
        wait_terminal;
        $display("  T05: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T05 装载失败");
        chk(err_code == 4'd4,     "T05 err = 4 (保留区簇号)");

        // ====================================================================
        // T06 FAT 项为 0（空闲簇）
        // ====================================================================
        $display("\n-- T06 FAT 项为 0 --");
        build_bmp(24, 8, 54, 0);
        build_image(24, 8, 54, 0, 2, 32'd0);
        wr32(L_FAT1, 16, 32'd0);
        do_reset;
        fire_start_wh(9'd1, 16'd24, 16'd8);
        wait_terminal;
        $display("  T06: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T06 装载失败");
        chk(err_code == 4'd4,     "T06 err = 4 (空闲簇号)");

        // ====================================================================
        // T07 底层读块失败
        // ====================================================================
        $display("\n-- T07 读块失败 --");
        build_bmp(8, 8, 54, 0);
        build_image(8, 8, 54, 0, 1, 32'd0);
        do_reset;
        err_inject = 1'b1;
        fire_start_wh(9'd1, 16'd8, 16'd8);
        wait_terminal;
        err_inject = 1'b0;
        $display("  T07: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T07 装载失败");
        chk(err_code == 4'd3 || err_code == 4'd1,
            "T07 err = 3(读块) 或 1(定位失败)");

        // ====================================================================
        // T08 BMP 签名错
        // ====================================================================
        $display("\n-- T08 BMP 签名错 --");
        build_bmp(8, 8, 54, 0);
        build_image(8, 8, 54, 0, 1, 32'd0);
        disk[L_FILE*512 + 0] = 8'h58;   // 'X' 而非 'B'
        do_reset;
        fire_start_wh(9'd1, 16'd8, 16'd8);
        wait_terminal;
        $display("  T08: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T08 装载失败");
        chk(err_code == 4'd2,     "T08 err = 2 (BMP 头非法)");

        // ====================================================================
        // T09 图片序号不存在
        // ====================================================================
        $display("\n-- T09 序号不存在 --");
        build_bmp(8, 8, 54, 0);
        build_image(8, 8, 54, 0, 1, 32'd0);
        do_reset;
        fire_start_wh(9'd9, 16'd8, 16'd8);          // 目录里只有 IMG001
        wait_terminal;
        $display("  T09: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T09 装载失败");
        chk(err_code == 4'd1,     "T09 err = 1 (FAT32 定位失败)");

        // ====================================================================
        // T10 奇数像素（宽为奇数 → 每行像素数为奇数）
        //   用 7x6 = 42 像素，42 是偶数但每行 7 个奇数 → 拼字会跨行
        //   改用 5x5 = 25 像素（奇数总数），最后必有一个不配对的像素
        // ====================================================================
        $display("\n-- T10 奇数像素收尾 --");
        build_bmp(5, 5, 54, 0);        // 25 像素，行 15 字节 pad=1
        build_image(5, 5, 54, 0, 2, 32'd0);
        do_reset;
        pix_seen = 0;
        wr_words = 0;
         chk_begin(5, 5, 0);
        fire_start_wh(9'd1, 16'd5, 16'd5);
        wait_terminal;
         chk_end("T10");
        $display("  T10: done=%b fail=%b err=%0d pix_count=%0d words=%0d",
                 done, fail, err_code, pix_count, wr_words);
        chk(done && !fail,        "T10 装载成功");
        chk(pix_count == 25,      "T10 产出 25 像素");
        chk(wr_words == 13,       "T10 写入 13 个字 (12 整字 + 1 半字)");

        // ====================================================================
        // T11 FIFO 长时间满 → err=5
        // ====================================================================
        $display("\n-- T11 FIFO 卡死 --");
        build_bmp(8, 8, 54, 0);
        build_image(8, 8, 54, 0, 1, 32'd0);
        do_reset;
        fifo_wr_full = 1'b1;        // 一直满
        fire_start_wh(9'd1, 16'd8, 16'd8);
        wait_terminal;
        fifo_wr_full = 1'b0;
        $display("  T11: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T11 装载失败");
        chk(err_code == 4'd5,     "T11 err = 5 (FIFO 卡死)");

        // ====================================================================
        // T12 逐像素校验（用非对称图，确保行列互换会被发现）
        //   8x6 = 48 像素，逐像素与黄金模型比对
        //   这里通过观测 pix_x/pix_y 已不可行（DUT 内部），改为比对 FIFO 数据
        // ====================================================================
        $display("\n-- T12 逐像素校验 --");
        build_bmp(12, 10, 54, 0);      // 120 像素，便于整字配对
        build_image(12, 10, 54, 0, 2, 32'd0);
        do_reset;
        pix_seen = 0;
        wr_words = 0;
         chk_begin(12, 10, 0);
        fire_start_wh(9'd1, 16'd12, 16'd10);
        wait_terminal;
         chk_end("T12");
        $display("  T12: done=%b fail=%b err=%0d pix_count=%0d words=%0d",
                 done, fail, err_code, pix_count, wr_words);
        chk(done && !fail,        "T12 装载成功");
        chk(pix_count == 120,     "T12 产出 120 像素 (12x10)");
        chk(wr_words == 60,       "T12 写入 60 个字");

        // ====================================================================
        // ====================================================================
        // T13 多扇区簇（spc = 2）—— 验证 spc 移位换算
        //   ★ 前面所有用例 spc 都是 1，移位量恒为 0，
        //     变异测试证明「spc 移位恒 0」这类缺陷完全抓不到。
        //   本用例 spc=2：一簇 2 扇区，簇 4 首扇区 = data_begin(7) + 2*2 = 11
        // ====================================================================
        $display("\n-- T13 spc=2 多扇区簇 --");
        build_bmp(24, 8, 54, 0);
        build_image(24, 8, 54, 0, 1, 32'd0);
        wr8 (L_VBR, 13, 8'd2);            // spc = 2
        // ★ 扇区 9 恰好是 spc=1 时簇 4 的首扇区、也是 build_image 写文件的位置。
        //   若不清掉，把 spc 移位写死为 0 的变异体也会读到正确数据 → 测不出来。
        //   这里把 9/10 抹成 0xFF（非法 BMP 头），数据只放在 spc=2 的正确位置 11。
        for (tr_i = 0; tr_i < 1024; tr_i = tr_i + 1) disk[9*512 + tr_i] = 8'hFF;
        flush_bmp(16'd11, bmp_len);
        do_reset;
        pix_seen = 0;
        wr_words = 0;
        chk_begin(24, 8, 0);
        fire_start_wh(9'd1, 16'd24, 16'd8);
        wait_terminal;
        chk_end("T13");
        $display("  T13: done=%b fail=%b err=%0d pix_count=%0d words=%0d",
                 done, fail, err_code, pix_count, wr_words);
        chk(done && !fail,        "T13 spc=2 装载成功");
        chk(pix_count == 192,     "T13 产出 192 像素 (24x8)");
        chk(wr_words == 96,       "T13 写入 96 个字");

        // ====================================================================
        // T14 链深超限（CHAIN_MAX = 16）
        //   声明 20000 字节需要 40 簇，FAT 链给足 20 簇 → 应报 E_CHAIN
        // ====================================================================
        $display("\n-- T14 链深超限 --");
        build_bmp(8, 8, 54, 0);
        build_image(8, 8, 54, 0, 70, 32'd70000);   // 70 簇远超 CHAIN_MAX=16
        do_reset;
        fire_start_wh(9'd1, 16'd8, 16'd8);
        wait_terminal;
        $display("  T14: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T14 链深超限应当失败");
        chk(err_code == 4'd4,     "T14 err = 4 (簇链异常/超深)");

        // ====================================================================
        // T15 数据阶段读块失败
        //   ★ err_inject 若全程生效，fat32_reader 定位时就会失败(err=1)，
        //     永远走不到数据阶段 —— 必须等 DUT 进入 T_DATRD 再注入。
        // ====================================================================
        $display("\n-- T15 数据阶段读块失败 --");
        build_bmp(24, 8, 54, 0);
        build_image(24, 8, 54, 0, 2, 32'd0);
        do_reset;
        // ★ 只在数据扇区 9 注入错误。
        //   若在 FAT 扇区(5)注入，错误会被 T_FATRD 的 blk_err 捕获，
        //   永远测不到 T_DATRD 的错误处理分支（变异测试 m11 就是这样存活的）。
        err_lba    = 9;
        err_inject = 1'b1;
        fire_start_wh(9'd1, 16'd24, 16'd8);
        wait_terminal;
        err_inject = 1'b0;
        err_lba    = -1;
        $display("  T15: done=%b fail=%b err=%0d", done, fail, err_code);
        chk(fail && !done,        "T15 数据阶段读块失败应当失败");
        chk(err_code == 4'd3,     "T15 err = 3 (底层读块失败)");
        // 收尾
        // ====================================================================
        chk(oob_hits == 0, "全程无越界扇区访问");
        $display("\n==============================================");
        $display(" 统计: checks=%0d fails=%0d", checks, fails);
        if (fails == 0) $display(" ALL CHECKS PASSED: img_loader");
        else            $display(" *** CHECKS FAILED: %0d ***", fails);
        $display("==============================================");
        $finish;
    end

    // 全局超时
    initial begin
        #200000000;
        $display(" *** GLOBAL TIMEOUT ***");
        $display(" 统计: checks=%0d fails=%0d", checks, fails);
        $finish;
    end

endmodule
