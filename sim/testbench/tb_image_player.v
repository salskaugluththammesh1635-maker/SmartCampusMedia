// Integration test: real FAT32, BMP, async FIFOs, arbiter, SDRAM model and video timing.
// Only the external sector service is modeled. Golden pixels use displayed x/y.
`timescale 1ns / 1ps
module tb_image_player #(parameter FULL=0, parameter SEAMLESS=1);
    localparam W=FULL ? 640 : 32, H=FULL ? 480 : 16, NSEC=FULL ? 4096 : 64;
    localparam SPC=FULL ? 8 : 1, FAT_SIZE=FULL ? 8 : 1, MAX_BMP=FULL ? 1048576 : 8192;
    // 双缓冲要两整帧，容量必须是 2 的幂：640x480 两帧 = 307200 字，取 524288。
    localparam MEM_WORDS = FULL ? (SEAMLESS ? 524288 : 262144) : 1024;
    localparam [31:0] PART_LBA=4;
    localparam [15:0] L_MBR=0,L_VBR=4,L_FAT1=5,L_FAT2=FULL ? 13 : 6,L_DIR0=FULL ? 21 : 7,L_FILE=FULL ? 37 : 9;
    reg clk=0, sdr_clk=0, rst_n=0;
    always #20 clk=~clk;
    always #3.333 sdr_clk=~sdr_clk;
    reg sd_ready=1, sd_failed=0, load_req=0;
    reg memory_online=1;
    reg [8:0] image_index=1;
    wire blk_start; wire [31:0] blk_addr;
    reg blk_done=0, blk_err=0, data_valid=0;
    reg [7:0] data_byte=0;
    wire de, hs, vs, vblank;
    wire [10:0] x; wire [9:0] y;
    wire [15:0] rgb565;
    wire pixel_valid, image_ready, loading, failed;
    wire [3:0] error_code; wire [2:0] reader_status;
    reg [7:0] disk[0:NSEC*512-1];
    integer checks=0, fails=0, pattern_id=0;
    localparam RD_GAP = 1;      // 字节间隔（拍）
    integer    rd_byte;
    reg [31:0] rd_lba;
    reg        err_inject = 1'b0;
    reg        service_stall = 1'b0;
    integer    err_lba = -1;   // >=0 时只在指定扇区注入错误
    integer    oob_hits = 0;

    localparam M_IDLE = 2'd0,
               M_RUN  = 2'd1,
               M_DONE = 2'd2;

    reg  [1:0]  mdl_st = M_IDLE;
    reg  [31:0] mdl_lba;
    integer     mdl_i;
    integer     mdl_gap;

    video_timing_gen #(.H_ACTIVE(W), .H_FP(16), .H_SYNC(FULL ? 96 : 8), .H_BP(FULL ? 48 : 24),
        .V_ACTIVE(H), .V_FP(FULL ? 10 : 8), .V_SYNC(2), .V_BP(FULL ? 33 : 12)) timing (
        .pixel_clk(clk), .rst_n(rst_n), .hs(hs), .vs(vs), .de(de),
        .active_x(x), .active_y(y), .frame_start(), .vblank(vblank));
    image_player #(.WIDTH(W), .HEIGHT(H), .LOAD_TIMEOUT(FULL ? 10000000 : 200000), .MEM_WORDS(MEM_WORDS), .SEAMLESS(SEAMLESS)) dut (
        .pix_clk(clk), .rst_n_pix(rst_n), .sdr_clk(sdr_clk), .sdr_clk_sft(~sdr_clk), .rst_n_sdr(rst_n && memory_online),
        .sd_ready(sd_ready), .sd_failed(sd_failed), .blk_busy(mdl_st != M_IDLE),
        .load_req(load_req), .image_index(image_index), .blk_start(blk_start), .blk_addr(blk_addr),
        .blk_done(blk_done), .blk_err(blk_err), .data_byte(data_byte), .data_valid(data_valid),
        .de(de), .scan_y(vblank ? H[9:0] : y), .rgb565(rgb565), .pixel_valid(pixel_valid),
        .image_ready(image_ready), .loading(loading), .failed(failed), .error_code(error_code),
        .reader_status(reader_status), .sdram_clk(), .sdram_cke(), .sdram_cs_n(),
        .sdram_ras_n(), .sdram_cas_n(), .sdram_we_n(), .sdram_ba(), .sdram_addr(), .sdram_dm(), .sdram_dq());
    task chk;
        input cond; input [8*120-1:0] msg;
        begin
            checks=checks+1;
            if (cond !== 1'b1) begin fails=fails+1; $display("FAIL: %0s t=%0t",msg,$time); end
        end
    endtask
    // 前台帧首翻转次数：双缓冲切换的唯一外部可观测证据，用于断言换帧确实发生。
    reg front_sel_d = 1'b0;
    integer front_changes = 0;
    integer seam_checked = 0;      // 已提交帧在显且装载进行中的拍数
    integer seam_gaps = 0;         // 上述拍数中 de 有效却没有像素的拍数（必须为 0）
    always @(posedge clk) begin
        if (!rst_n) begin
            front_sel_d <= 1'b0;
            front_changes = 0;
        end else begin
            front_sel_d <= dut.front_sel;
            if (dut.front_sel !== front_sel_d) front_changes = front_changes + 1;
            // 无缝的核心契约：重载期间前台帧不得断供。
            // 这两项跨复位累积，由用例按基准取增量，避免复位把证据抹掉。
            if (SEAMLESS && image_ready && dut.loading) begin
                seam_checked = seam_checked + 1;
                if (de && !pixel_valid) seam_gaps = seam_gaps + 1;
            end
        end
    end
    task request_image;
        input [8:0] idx;
        integer request_guard;
        begin
            @(negedge clk); image_index=idx; load_req=1;
            @(negedge clk); load_req=0;
            request_guard=0;
            while(!loading && request_guard<10000) begin @(negedge clk); request_guard=request_guard+1; end
            chk(request_guard<10000,"load request begins within bound after outstanding sector");
        end
    endtask
    task terminal;
        integer guard;
        begin
            // 双缓冲下 image_ready 常驻为 1，不能用它判装载结束。
            // 装载期(dut.loading)与提交挂起(dut.commit_pending)都清掉，才算这一次请求真正落地；
            // 失败时 failed 置位立即返回，此时旧帧仍在显示。
            guard=0;
            repeat(4) @(negedge clk);
            while((dut.loading || dut.commit_pending) && !failed && guard<(FULL ? 11000000 : 220000)) begin
                @(negedge clk); guard=guard+1;
            end
            chk(guard<(FULL ? 11000000 : 220000),"load reaches a terminal within bound");
        end
    endtask
    task check_frame;
        integer guard, n;
        reg [15:0] expect565;
        begin
            guard=0; n=0;
            while(!vblank && guard<2000000) begin @(negedge clk); guard=guard+1; end
            while(vblank && guard<2000000) begin @(negedge clk); guard=guard+1; end
            while(!vblank && guard<2000000) begin
                if(de) begin
                    expect565=to565(golden888(x,y));
                    chk(pixel_valid,"every visible pixel has valid data");
                    if (rgb565 !== expect565 && fails<10) $display("pixel x=%0d y=%0d got=%h expect=%h",x,y,rgb565,expect565);
                    chk(rgb565===expect565,"displayed pixel matches independent x/y reference");
                    n=n+1;
                end
                @(negedge clk); guard=guard+1;
            end
            chk(n==W*H,"complete visible frame covered");
            chk(reader_status[1:0]==0,"no FIFO underflow or overflow");
        end
    endtask
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
            M_RUN: if (!service_stall) begin
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
    reg  [7:0]  bmp_buf [0:MAX_BMP-1];       // 构造缓冲（本 tb 只测小图）
    integer     bmp_len;

    // 黄金像素: 对 (x,y) 敏感
    function [23:0] golden888;
        input integer gx, gy;
        reg [7:0] gr, gg, gb;
        begin
            gr = gx*17 + pattern_id*31; gg = gy*13 + pattern_id*7; gb = (gx ^ gy)*19 + pattern_id*23;
            golden888 = {gr,gg,gb};
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
            for (bp = 0; bp < MAX_BMP; bp = bp + 1) bmp_buf[bp] = 8'h00;

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
                bmp_buf[24] = 8'hFF; bmp_buf[25] = 8'hFF;
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
            wr8 (L_VBR, 13, SPC);             // spc = 1
            wr16(L_VBR, 14, 16'd1);            // reserved = 1
            wr8 (L_VBR, 16, 8'd2);             // num_fats = 2
            wr32(L_VBR, 36, FAT_SIZE);            // fat_size = 1
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
                for (bi = 0; bi < (bmp_len+SPC*512-1)/(SPC*512); bi = bi + 1) begin
                    if (bi == (bmp_len+SPC*512-1)/(SPC*512) - 1)
                        wr32(L_FAT1, 16 + bi*4, 32'h0FFF_FFF8);
                    else
                        wr32(L_FAT1, 16 + bi*4, 32'd4 + bi + 1);
                end
            end

            // ---- 文件数据 ----
            flush_bmp(L_FILE, bmp_len);
        end
    endtask


    // Force refresh at the registered-command boundary, where a FIFO word used to be lost.
    initial begin
        wait(rst_n); wait(dut.wr_ack); @(posedge sdr_clk);
        @(negedge sdr_clk); force dut.u_sdram.u_model.ref_vld=1'b1;
        repeat(3) begin @(negedge sdr_clk);
        end
        release dut.u_sdram.u_model.ref_vld;
    end
    initial begin
        $display("CASE 1: boot, bottom-up BMP, complete displayed frame");
        build_bmp(W,H,54,0); build_image(W,H,54,0,4,0);
        repeat(8) @(negedge clk); rst_n=1;
        terminal; chk(image_ready && !failed,"boot image is committed"); check_frame;
        $display("CASE 2: top-down BMP reload with different pixel data");
        pattern_id=1; build_bmp(W,H,54,1); build_image(W,H,54,1,4,0);
        begin : seamless_reload
            integer changes_before;
            changes_before = front_changes;
            request_image(1); terminal; chk(image_ready && !failed,"top-down reload commits"); check_frame;
            if (SEAMLESS) begin
                // 换帧必须在后台帧写完之后发生，且恰好一次。
                chk(front_changes == changes_before + 1,"seamless reload flips the front buffer exactly once");
                // 装载全程前台帧持续供给：这是"无缝"的直接证据。
                chk(seam_checked > 0,"reload overlaps the displayed frame, giving seamlessness a chance to break");
                chk(seam_gaps == 0,"front frame never starves while the back buffer loads");
            end else begin
                chk(front_changes == changes_before,"single-buffer mode never flips the front selection");
            end
        end
        // FULL 用例只跑前两个 CASE（整帧 614,404 项检查已足够覆盖几何），
        // 双缓冲的两帧切换证据必须在这之前收齐，不能放在后面的用例里。
        if(FULL) begin
            $display("SEAMLESS: mode=%0d front_flips=%0d overlap_cycles=%0d starve_cycles=%0d",
                SEAMLESS, front_changes, seam_checked, seam_gaps);
            $display("SUMMARY: FULL 640x480 checks=%0d errors=%0d",checks,fails);
            if(fails==0) $display("ALL CHECKS PASSED: image_player_full");
            else $display("CHECKS FAILED: image_player_full");
            $finish;
        end
        $display("CASE 3: missing image, then retry without resetting SD");
        request_image(2); terminal; chk(failed && error_code==1,"missing file reports FAT location failure");
        // 双缓冲下装载失败保留上一帧继续显示；单帧模式必须立刻退掉，因为马上要覆盖它。
        chk(SEAMLESS ? image_ready : !image_ready,"failed load keeps the committed frame in seamless mode");
        request_image(1); terminal; chk(image_ready && !failed,"retry succeeds"); check_frame;
        $display("CASE 4: malformed BMP header");
        disk[L_FILE*512]=0;
        request_image(1); terminal; chk(failed && error_code==2,"invalid BMP reports header failure");
        $display("CASE 5: short file cannot publish a partial frame");
        build_bmp(W,H,54,0); build_image(W,H,54,0,4,100);
        request_image(1); terminal; chk(failed && error_code==7,"incomplete image is rejected by pixel count");
        $display("CASE 6: data sector read error");
        build_bmp(W,H,54,0); build_image(W,H,54,0,4,0);
        err_inject=1; err_lba=L_FILE;
        request_image(1); terminal; chk(failed && error_code==3,"sector failure reports I/O error");
        err_inject=0;
        $display("CASE 7: latest pending request survives an active load");
        request_image(2); repeat(100) @(negedge clk); request_image(1);
        repeat(10000) @(negedge clk); terminal;
        chk(image_ready && !failed,"pending valid image replaces failed request"); check_frame;
        $display("CASE 8: SDRAM fault while displaying invalidates the image");
        force dut.arb_error=1'b1;
        repeat(5) @(negedge clk);
        chk(failed && !image_ready && error_code==8,"display-time SDRAM fault publishes error 8");
        release dut.arb_error;
        request_image(1); terminal; chk(image_ready && !failed,"retry resets the complete memory path");
        $display("CASE 9: stalled sector service reaches the load watchdog");
        service_stall=1;
        request_image(1); terminal;
        // 装载侧失败（超时）不破坏已显示帧，双缓冲下旧帧必须还在。
        chk(failed && (SEAMLESS ? image_ready : !image_ready) && error_code==9,
            "stalled load cannot wait forever or publish a frame");
        service_stall=0;
        request_image(1); terminal; chk(image_ready && !failed,"timed-out load can retry when service returns");
        $display("CASE 10: SD startup failure, then retry after recovery");
        @(negedge clk); rst_n=0; sd_ready=0; sd_failed=1;
        repeat(8) @(negedge clk); rst_n=1;
        // 整机复位已经清掉 image_ready，双缓冲与单帧在这一步行为相同。
        terminal; chk(failed && !image_ready && error_code==6,"SD startup failure reports error 6");
        sd_ready=1; sd_failed=0;
        request_image(1); terminal; chk(image_ready && !failed,"SD recovery request loads a new image");
        check_frame;
        $display("CASE 11: SDRAM clock lock loss resets both sides of the storage path");
        memory_online=0;
        repeat(10) @(negedge clk);
        chk(failed && !image_ready && error_code==8,"memory reset while displaying invalidates the frame");
        chk(!dut.store_rst_pix && !dut.store_rst_sdr,"both storage domains are held in reset");
        memory_online=1;
        request_image(1); terminal; chk(image_ready && !failed,"memory lock recovery permits a complete reload");
        check_frame;
        chk(oob_hits==0,"no out-of-range sector requests");
        $display("SEAMLESS: mode=%0d front_flips=%0d overlap_cycles=%0d starve_cycles=%0d",
            SEAMLESS, front_changes, seam_checked, seam_gaps);
        $display("SUMMARY: checks=%0d errors=%0d",checks,fails);
        if(fails==0) $display("ALL CHECKS PASSED: image_player");
        else $display("CHECKS FAILED: image_player");
        $finish;
    end
    initial begin #500000000; $display("CHECKS FAILED: image_player TIMEOUT"); $finish; end
endmodule
