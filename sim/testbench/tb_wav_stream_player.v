// ============================================================================
//  tb_wav_stream_player.v —— WAV 流播放器验证（t6）
// ----------------------------------------------------------------------------
//  覆盖目标（对应 captain m00903 的硬要求，一条不省）：
//    - 三 chunk 真解析：RIFF / fmt / data，且允许中间夹带无关 chunk（LIST）
//    - 校验 NumChannels==1 / SampleRate==48000 / BitsPerSample==16
//    - 用 data chunk 声明的 size 作播放区间，**不是**"文件大小减 44"
//    - 欠载时保持上一采样、绝不归零，并置 underrun
//    - 正常播完不得误报 underrun
//    - want_blk 在 W_FATLOC 期间必须拉高（否则 fat32_reader 的 fr_blk_start
//      被 sd_grant 吞掉，只能等 BLK_TIMEOUT 报错，表现为"文件存在却超时"）
//    - 跨簇链（文件跨 3 个簇）正确拼接
//    - FIFO 不溢出
//    - 采样节拍平均 520.8333 拍/样本（相位累加器，非整数分频）
//
//  ★ 测试台的 SD 模型为什么不恒给 grant
//    真实拓扑里 sd_grant 由仲裁器逐块授权。如果 tb 里把 grant 恒置 1，
//    "W_FATLOC 期间 want_blk 没拉高"这类缺陷就永远不会暴露（因为
//    blk_start = sd_grant && fr_blk_start 里 sd_grant 恒真）。
//    所以这里刻意做一个**有延迟**的授权器，模拟总线被别的请求者占用。
//
//  编译依赖：rtl/audio/wav_stream_player.v + rtl/storage/fat32_reader.v
// ============================================================================
`timescale 1ns/1ps

module tb_wav_stream_player;

    // ========================================================================
    //  时钟 / 复位
    // ========================================================================
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;              // 25 MHz

    // ========================================================================
    //  记分板
    // ========================================================================
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk(input cond, input [8*100-1:0] msg);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // ========================================================================
    //  FAT32 镜像（16 扇区 = 8 KB）
    //    布局：LBA0=MBR, LBA4=VBR, LBA5=FAT1, LBA6=FAT2,
    //          簇2=LBA7(根目录), 簇3=LBA8, 簇4=LBA9, 簇5=LBA10, 簇6=LBA11
    //    spc=1 / rsv=1 / nf=2 / fat_sz=1  → data_begin = 4+1+2*1 = 7
    // ========================================================================
    localparam NSEC = 16;
    reg [7:0] disk [0:NSEC*512-1];

    localparam [15:0] L_MBR  = 16'd0;
    localparam [15:0] L_VBR  = 16'd4;
    localparam [15:0] L_FAT1 = 16'd5;
    localparam [15:0] L_FAT2 = 16'd6;
    localparam [15:0] L_DIR0 = 16'd7;      // 簇 2
    localparam [15:0] L_DAT  = 16'd9;      // 簇 4 = 文件首簇

    // 注意：ANSI 风格 task 的参数用**逗号**分隔，用分号会报
    //   "near ";": syntax error, unexpected ';', expecting ')'"。
    //   （非 ANSI 风格才是每个 input 单独一行以分号结尾）
    task wr8(input [15:0] sec, input [8:0] off, input [7:0] val);
        begin disk[sec*512 + off] = val; end
    endtask

    task wr16(input [15:0] sec, input [8:0] off, input [15:0] val);
        begin
            disk[sec*512 + off]       = val[7:0];
            disk[sec*512 + off + 1]   = val[15:8];
        end
    endtask

    task wr32(input [15:0] sec, input [8:0] off, input [31:0] val);
        begin
            disk[sec*512 + off]       = val[7:0];
            disk[sec*512 + off + 1]   = val[15:8];
            disk[sec*512 + off + 2]   = val[23:16];
            disk[sec*512 + off + 3]   = val[31:24];
        end
    endtask

    // ------------------------------------------------------------------
    //  文件字节写：按文件内偏移写到指定 LBA 区（簇 4/5/6 → LBA 9/10/11）
    // ------------------------------------------------------------------
    task fput(input integer byte_off, input [7:0] val);
        integer lba;
        begin
            lba = L_DAT + (byte_off / 512);
            disk[lba*512 + (byte_off % 512)] = val;
        end
    endtask

    task fput32(input integer off, input [31:0] val);
        begin
            fput(off + 0, val[7:0]);
            fput(off + 1, val[15:8]);
            fput(off + 2, val[23:16]);
            fput(off + 3, val[31:24]);
        end
    endtask

    task fput16(input integer off, input [15:0] val);
        begin
            fput(off + 0, val[7:0]);
            fput(off + 1, val[15:8]);
        end
    endtask

    // ========================================================================
    //  场景参数
    // ========================================================================
    // 文件数据长度（PCM 字节数）。500 样本 × 2 = 1000 字节 → 文件 1044 字节
    //   → 跨 3 个扇区（LBA 9/10/11）→ 必然走 FAT 簇链。
    localparam integer PCM_BYTES = 1000;
    localparam integer FILE_BYTES = 44 + PCM_BYTES;
    // 【t26 新增】NARR.WAV：100 个样本 = 200 字节 PCM，文件总长 244 字节
    localparam integer NARR_PCM   = 200;
    localparam integer NARR_BYTES = 44 + NARR_PCM;

    integer g_chan   = 1;         // 注入：声道数
    integer g_rate   = 48000;     // 注入：采样率
    integer g_bits   = 16;        // 注入：位深
    integer g_format = 1;         // 注入：1=PCM
    integer g_riff_bad = 0;       // 注入：1 = 'RIFF' 写错
    integer g_extra_list = 0;     // 注入：1 = 在 fmt 与 data 之间插一个 LIST chunk
    integer g_no_fmt = 0;         // 注入：1 = 完全没有 fmt chunk
    reg [31:0] g_data_size = PCM_BYTES;  // 注入：data chunk 声明长度
    // 【t26 新增】1 = 镜像里额外放一个 NARR.WAV（簇 7，100 样本），
    //   用于「BGM 播完后不复位直接换源」的用例。
    integer g_add_narr = 0;

    // ========================================================================
    //  镜像构造
    // ========================================================================
    integer i;
    integer j;

    task build_image;
        integer off;
        reg [15:0] blk_align;
        reg [31:0] byte_rate;
        begin
            for (i = 0; i < NSEC*512; i = i + 1) disk[i] = 8'h00;

            // ---- MBR ----
            wr8 (L_MBR, 9'd446, 8'h80);
            wr8 (L_MBR, 9'd450, 8'h0C);          // FAT32 LBA
            wr32(L_MBR, 9'd454, 32'd4);          // 分区起始 LBA
            wr32(L_MBR, 9'd458, 32'd8192);
            wr16(L_MBR, 9'd510, 16'hAA55);

            // ---- VBR ----
            wr16(L_VBR, 9'd11, 16'd512);         // bytes/sector
            wr8 (L_VBR, 9'd13, 8'd1);            // sectors/cluster = 1
            wr16(L_VBR, 9'd14, 16'd1);           // reserved sectors
            wr8 (L_VBR, 9'd16, 8'd2);            // num fats
            wr32(L_VBR, 9'd36, 32'd1);           // fat size
            wr32(L_VBR, 9'd44, 32'd2);           // root cluster
            wr16(L_VBR, 9'd510, 16'hAA55);

            // ---- FAT：簇2(目录)=EOC，簇4→5→6→EOC ----
            //   ★ EOC 必须 >= 0x0FFF_FFF8（FAT32 规范）。
            //     这里原来写的是 0x0FFF_FEF8 —— 比下沿小 0x100，落在
            //     合法簇号区间 2..0x0FFF_FFEF 里，于是 DUT 会把它当成
            //     "下一个簇 = 268435192" 继续读，blk_addr 直接越界
            //     （tb 报 out-of-range LBA 268435197）。
            //     症状极具误导性：播放/样本/错误码全对，只有 SD 模型在
            //     旁边喊越界；很容易被当成"模型误报"而放过。
            wr32(L_FAT1, 9'd8,  32'h0FFF_FFF8);  // 簇 2 = EOC
            wr32(L_FAT1, 9'd12, 32'h0FFF_FFF8);  // 簇 3 = EOC
            wr32(L_FAT1, 9'd16, 32'd5);          // 簇 4 → 5
            wr32(L_FAT1, 9'd20, 32'd6);          // 簇 5 → 6
            wr32(L_FAT1, 9'd24, 32'h0FFF_FFF8);  // 簇 6 = EOC
            wr32(L_FAT2, 9'd8,  32'h0FFF_FFF8);
            wr32(L_FAT2, 9'd12, 32'h0FFF_FFF8);
            wr32(L_FAT2, 9'd16, 32'd5);
            wr32(L_FAT2, 9'd20, 32'd6);
            wr32(L_FAT2, 9'd24, 32'h0FFF_FFF8);
            if (g_add_narr) begin
                wr32(L_FAT1, 9'd28, 32'h0FFF_FFF8);  // 簇 7 = EOC
                wr32(L_FAT2, 9'd28, 32'h0FFF_FFF8);
            end

            // ---- 根目录：LFN 干扰项 + 卷标干扰项 + BGM.WAV ----
            wr8(L_DIR0, 9'd0,  8'h41);           // LFN 序列
            wr8(L_DIR0, 9'd11, 8'h0F);
            wr8(L_DIR0, 9'd32, 8'h42);           // 卷标
            wr8(L_DIR0, 9'd43, 8'h08);
            // BGM.WAV：项 2
            off = 64;
            // 名字 8 字节：B G M 空格×5
            disk[L_DIR0*512 + off + 0] = 8'h42;  // 'B'
            disk[L_DIR0*512 + off + 1] = 8'h47;  // 'G'
            disk[L_DIR0*512 + off + 2] = 8'h4D;  // 'M'
            for (i = 3; i < 8; i = i + 1) disk[L_DIR0*512 + off + i] = 8'h20;
            disk[L_DIR0*512 + off + 8] = 8'h57;  // 'W'
            disk[L_DIR0*512 + off + 9] = 8'h41;  // 'A'
            disk[L_DIR0*512 + off +10] = 8'h56;  // 'V'
            disk[L_DIR0*512 + off +11] = 8'h20;  // attr = 归档
            disk[L_DIR0*512 + off +20] = 8'h00;  // 首簇高 16 位
            disk[L_DIR0*512 + off +21] = 8'h00;
            disk[L_DIR0*512 + off +26] = 8'd4;   // 首簇低 16 位 = 簇 4
            disk[L_DIR0*512 + off +27] = 8'h00;
            disk[L_DIR0*512 + off +28] = FILE_BYTES[7:0];
            disk[L_DIR0*512 + off +29] = FILE_BYTES[15:8];
            disk[L_DIR0*512 + off +30] = 8'h00;
            disk[L_DIR0*512 + off +31] = 8'h00;
            // NARR.WAV：项 3（仅换源用例需要）
            if (g_add_narr) begin
                off = 96;
                disk[L_DIR0*512 + off + 0] = 8'h4E;  // 'N'
                disk[L_DIR0*512 + off + 1] = 8'h41;  // 'A'
                disk[L_DIR0*512 + off + 2] = 8'h52;  // 'R'
                disk[L_DIR0*512 + off + 3] = 8'h52;  // 'R'
                for (i = 4; i < 8; i = i + 1) disk[L_DIR0*512 + off + i] = 8'h20;
                disk[L_DIR0*512 + off + 8] = 8'h57;  // 'W'
                disk[L_DIR0*512 + off + 9] = 8'h41;  // 'A'
                disk[L_DIR0*512 + off +10] = 8'h56;  // 'V'
                disk[L_DIR0*512 + off +11] = 8'h20;  // attr = 归档
                disk[L_DIR0*512 + off +20] = 8'h00;
                disk[L_DIR0*512 + off +21] = 8'h00;
                disk[L_DIR0*512 + off +26] = 8'd7;   // 首簇 = 簇 7
                disk[L_DIR0*512 + off +27] = 8'h00;
                disk[L_DIR0*512 + off +28] = NARR_BYTES[7:0];
                disk[L_DIR0*512 + off +29] = NARR_BYTES[15:8];
                disk[L_DIR0*512 + off +30] = 8'h00;
                disk[L_DIR0*512 + off +31] = 8'h00;
                wr8(L_DIR0, 9'd128, 8'h00);          // 目录结束标记顺延
            end else begin
                wr8(L_DIR0, 9'd96, 8'h00);
            end

            // ---- WAV 文件内容 ----
            // RIFF 头
            fput(0, 8'h52); fput(1, 8'h49); fput(2, 8'h46); fput(3, 8'h46); // 'RIFF'
            if (g_riff_bad) fput(0, 8'h58);                                 // 注入：'X'
            fput32(4, FILE_BYTES - 8);
            fput(8, 8'h57); fput(9, 8'h41); fput(10, 8'h56); fput(11, 8'h45); // 'WAVE'

            // 可选：在 RIFF 头与 fmt 之间插入一个 LIST chunk（验证无关 chunk 跳过）
            off = 12;
            if (g_extra_list) begin
                fput(off+0, 8'h4C); fput(off+1, 8'h49);  // 'LI'
                fput(off+2, 8'h53); fput(off+3, 8'h54);  // 'ST'
                fput32(off+4, 32'd13);                   // 奇数长度 13 → 需补齐 1 字节
                for (i = 0; i < 13; i = i + 1) fput(off+8+i, 8'hA5);
                fput(off+8+13, 8'h00);                   // 补齐字节
                off = off + 8 + 14;
            end

            // fmt chunk
            if (!g_no_fmt) begin
                fput(off+0, 8'h66); fput(off+1, 8'h6D);  // 'fm'
                fput(off+2, 8'h74); fput(off+3, 8'h20);  // 't '
                fput32(off+4, 32'd16);
                fput16(off+8,  g_format[15:0]);
                fput16(off+10, g_chan[15:0]);
                fput32(off+12, g_rate[31:0]);
                // Verilog-2001 不允许对表达式做位选（`(a*b)[15:0]` 非法），
                //   必须先落到一个 reg 再取低 16 位。
                blk_align = g_chan * (g_bits/8);
                byte_rate = g_rate * blk_align;
                fput32(off+16, byte_rate[31:0]);
                fput16(off+20, blk_align[15:0]);
                fput16(off+22, g_bits[15:0]);
                off = off + 8 + 16;
            end

            // data chunk
            fput(off+0, 8'h64); fput(off+1, 8'h61);  // 'da'
            fput(off+2, 8'h74); fput(off+3, 8'h61);  // 'ta'
            fput32(off+4, g_data_size);
            off = off + 8;

            // PCM 样本：第 i 个样本 = i * 100（16bit 小端，正数，便于顺序验证）
            for (i = 0; i < PCM_BYTES/2; i = i + 1) begin
                fput16(off + i*2, (i * 100) & 16'hFFFF);
            end

            // ---- NARR.WAV 的内容（簇 7 = LBA 12）----
            //   样本值用 i*7+3，与 BGM 的 i*100 完全不同，谁被播了一看就知道。
            if (g_add_narr) begin
                off = (12 - L_DAT) * 512;
                fput(off+0, 8'h52); fput(off+1, 8'h49);
                fput(off+2, 8'h46); fput(off+3, 8'h46);          // 'RIFF'
                fput32(off+4, NARR_BYTES - 8);
                fput(off+8, 8'h57); fput(off+9, 8'h41);
                fput(off+10, 8'h56); fput(off+11, 8'h45);        // 'WAVE'
                fput(off+12, 8'h66); fput(off+13, 8'h6D);
                fput(off+14, 8'h74); fput(off+15, 8'h20);        // 'fmt '
                fput32(off+16, 32'd16);
                fput16(off+20, 16'd1);                           // PCM
                fput16(off+22, 16'd1);                           // 单声道
                fput32(off+24, 32'd48000);
                fput32(off+28, 32'd96000);                       // byte rate
                fput16(off+32, 16'd2);                           // block align
                fput16(off+34, 16'd16);                          // bits
                fput(off+36, 8'h64); fput(off+37, 8'h61);
                fput(off+38, 8'h74); fput(off+39, 8'h61);        // 'data'
                fput32(off+40, NARR_PCM);
                for (i = 0; i < NARR_PCM/2; i = i + 1) begin
                    fput16(off + 44 + i*2, (i * 7 + 3) & 16'hFFFF);
                end
            end
        end
    endtask

    // ========================================================================
    //  SD 读块模型（顶替 sd_spi_ctrl）
    // ========================================================================
    reg        card_active = 1'b0;
    reg [31:0] card_lba    = 32'd0;
    reg [9:0]  card_cnt    = 10'd0;
    reg        card_stall  = 1'b0;      // 1 = 故意憋住不响应（欠载注入）
    integer    stall_cnt   = 0;
    integer    stall_len   = 0;

    reg [7:0]  data_byte  = 8'h00;
    reg        data_valid = 1'b0;
    reg        blk_done   = 1'b0;
    reg        blk_err    = 1'b0;
    reg        blk_busy   = 1'b0;

    integer    oob_hits = 0;

    wire        blk_start;
    wire [31:0] blk_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            card_active <= 1'b0;
            card_lba    <= 32'd0;
            card_cnt    <= 10'd0;
            data_byte   <= 8'h00;
            data_valid  <= 1'b0;
            blk_done    <= 1'b0;
            blk_err     <= 1'b0;
            blk_busy    <= 1'b0;
            stall_cnt   <= 0;
        end else begin
            blk_done <= 1'b0;
            blk_err  <= 1'b0;

            // 憋住计数器
            if (stall_cnt > 0) stall_cnt <= stall_cnt - 1;

            if (blk_start && !card_active && (stall_cnt == 0)) begin
                card_active <= 1'b1;
                blk_busy    <= 1'b1;
                card_lba    <= blk_addr;
                card_cnt    <= 10'd0;
                if (blk_addr >= NSEC) begin
                    $display("FAIL: out-of-range LBA %0d (t=%0t) st=%0d clu=%0d sec=%0d fat=%h",
                             blk_addr, $time, u_dut.st, u_dut.cur_cluster,
                             u_dut.sec_in_clu, u_dut.fat_val);
                    oob_hits = oob_hits + 1;
                end
            end else if (card_active) begin
                if (card_cnt < 10'd512) begin
                    data_byte  <= disk[card_lba*512 + card_cnt];
                    data_valid <= 1'b1;
                    card_cnt   <= card_cnt + 10'd1;
                end else begin
                    data_valid  <= 1'b0;
                    blk_done    <= 1'b1;
                    blk_busy    <= 1'b0;
                    card_active <= 1'b0;
                end
            end else begin
                data_valid <= 1'b0;
            end
        end
    end

    // ========================================================================
    //  仲裁器模型（有延迟授权，模拟总线被别的请求者占用）
    // ========================================================================
    wire want_blk;
    reg  sd_grant = 1'b0;
    integer grant_wait = 0;
    integer grant_delay = 3;            // 常态：3 拍后授权

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_grant   <= 1'b0;
            grant_wait <= 0;
        end else begin
            if (!want_blk) begin
                sd_grant   <= 1'b0;
                grant_wait <= 0;
            end else if (!sd_grant) begin
                if (grant_wait >= grant_delay) begin
                    sd_grant   <= 1'b1;
                    grant_wait <= 0;
                end else begin
                    grant_wait <= grant_wait + 1;
                end
            end else if (blk_done || blk_err) begin
                // 一块读完让出总线，下一块重新竞争（逐块仲裁语义）
                sd_grant   <= 1'b0;
                grant_wait <= 0;
            end
        end
    end

    // ========================================================================
    //  DUT
    // ========================================================================
    reg         start      = 1'b0;
    reg  [87:0] target_name = 88'd0;
    reg         play_en    = 1'b1;
    reg         loop       = 1'b0;
    wire        busy;
    wire        playing;
    wire [3:0]  err_code;
    wire        underrun;
    wire [9:0]  fifo_level;
    wire        sample_valid;
    wire signed [23:0] sample_l;
    wire signed [23:0] sample_r;

    wav_stream_player #(
        .CLK_FREQ_HZ (25_000_000),
        .SAMPLE_RATE (48_000),
        .FIFO_AW     (10),
        .LOW_WM      (256)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .target_name(target_name),
        .play_en    (play_en),
        .loop       (loop),
        .busy       (busy),
        .playing    (playing),
        .err_code   (err_code),
        .underrun   (underrun),
        .fifo_level (fifo_level),
        .sd_grant   (sd_grant),
        .blk_start  (blk_start),
        .blk_addr   (blk_addr),
        .want_blk   (want_blk),
        .blk_busy   (blk_busy),
        .blk_done   (blk_done),
        .blk_err    (blk_err),
        .data_byte  (data_byte),
        .data_valid (data_valid),
        .sample_valid(sample_valid),
        .sample_l   (sample_l),
        .sample_r   (sample_r)
    );

    // ========================================================================
    //  采集器
    // ========================================================================
    integer        s_cnt = 0;
    reg signed [23:0] s_val [0:2047];
    integer        max_fifo = 0;
    integer        tick_cnt = 0;
    time           tick_t0 = 0;
    time           tick_t1 = 0;
    time           tick_span = 0;
    integer        fatal_seen = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            // 只收"真的从文件里出来的"样本（ever_played 之后）
            if (sample_valid && u_dut.ever_played && (s_cnt < 2048)) begin
                s_val[s_cnt] = sample_l;
                s_cnt = s_cnt + 1;
            end
            if (fifo_level > max_fifo) max_fifo = fifo_level;
            if (blk_err) fatal_seen = fatal_seen + 1;
        end
    end

    // 节拍计数：第 200 个 tick 与第 300 个 tick 之间的时间差 → 100 个样本的周期
    always @(posedge clk) begin
        if (rst_n && sample_valid && u_dut.ever_played) begin
            tick_cnt = tick_cnt + 1;
            if (tick_cnt == 200) tick_t0 = $time;
            if (tick_cnt == 300) tick_t1 = $time;
        end
    end

    // 监视 want_blk 在 W_FATLOC 期间的状态
    integer want_in_fatloc = 0;
    always @(posedge clk) begin
        if (rst_n && (u_dut.st == 3'd1) && want_blk) want_in_fatloc = 1;
    end

    // ------------------------------------------------------------------
    //  调试监视（DBG 宏控制，定位完用 `define DBG 0 关掉）
    // ------------------------------------------------------------------
    `ifdef DBG_PCM
    integer pcm_dbg = 0;
    always @(posedge clk) begin
        if (rst_n && u_dut.byte_in && (u_dut.st == u_dut.W_DATRD) && u_dut.streaming
            && (pcm_dbg < 16)) begin
            $display("     [t=%0t] PCM byte #%0d = %h  half=%0b s_lo=%h bcnt=%0d data_left=%0d",
                     $time, pcm_dbg, u_dut.data_byte, u_dut.half, u_dut.s_lo,
                     u_dut.blk_byte_idx, u_dut.data_left);
            pcm_dbg = pcm_dbg + 1;
        end
    end
    `endif

    `ifdef DBG_TRACE
    reg [2:0] st_d = 3'd0;
    reg [2:0] fst_d = 3'd0;
    integer   dbg_edges = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (u_dut.st !== st_d) begin
                $display("     [t=%0t] st %0d -> %0d  err=%0d ph=%0d bc=%0d ckid=%h cksz=%0d bodyleft=%0d dataleft=%0d stream=%0b fmtseen=%0b clu=%0d sec=%0d fifo=%0d",
                         $time, st_d, u_dut.st, u_dut.err_code, u_dut.ph, u_dut.bc,
                         u_dut.ck_id, u_dut.ck_size, u_dut.body_left, u_dut.data_left,
                         u_dut.streaming, u_dut.fmt_seen, u_dut.cur_cluster,
                         u_dut.sec_in_clu, u_dut.fifo_cnt);
                st_d = u_dut.st;
            end
            if (u_dut.u_fat.st !== fst_d) begin
                $display("        [t=%0t] FAT st %0d -> %0d stage=%0d err=%0d lba=%0d busy=%0b found=%0b fail=%0b bytcnt=%0d nmbad=%0b",
                         $time, fst_d, u_dut.u_fat.st, u_dut.u_fat.stage,
                         u_dut.u_fat.err_code, u_dut.u_fat.next_lba,
                         u_dut.u_fat.busy, u_dut.u_fat.found, u_dut.u_fat.fail,
                         u_dut.u_fat.byte_cnt, u_dut.u_fat.nm_bad);
                fst_d = u_dut.u_fat.st;
            end
        end
    end
    `endif

    // ========================================================================
    //  操作
    // ========================================================================
    task do_reset;
        begin
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            #1 rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task set_name_bgm;
        begin
            // "BGM" + 5 空格 + "WAV"，同样按 target_name[7:0]=第0字节 的契约拼
            target_name = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20,
                           8'h20, 8'h20, 8'h20, 8'h4D, 8'h47, 8'h42};
        end
    endtask

    task fire_start(input [87:0] nm);
        begin
            @(negedge clk);
            target_name = nm;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // 等 DUT 离开 busy（完成或失败），带超时
    task wait_idle(output integer ok);
        integer guard;
        begin
            ok = 0;
            guard = 0;
            while (busy && (guard < 5_000_000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (!busy) ok = 1;
        end
    endtask

    // 清采集器
    task clr_coll;
        begin
            s_cnt = 0;
            max_fifo = 0;
            tick_cnt = 0;
            fatal_seen = 0;
            want_in_fatloc = 0;
        end
    endtask

    // ------------------------------------------------------------------
    //  ★ 短名字节序（踩过一次的坑，务必留意）
    //    fat32_reader.v:108-109 的契约是：
    //        target_name[7:0]   = 第 0 字节（名字首字符 'B'）
    //        target_name[87:80] = 第 10 字节（扩展名末字符 'V'）
    //    Verilog 的拼接 {a, b, c} 把**最左边的操作数放在最高位**，
    //    所以按直觉写 {B,G,M,sp,sp,sp,sp,sp,W,A,V} 会让 'B' 落到 [87:80]，
    //    整串被倒着比对 —— 现象是 fat32_reader 报 err=4（未找到），
    //    而且 MBR/VBR/目录三级读取全部正常（LBA 0→4→7 都对），
    //    只有 nm_bad=1，很容易误判成"文件其实不在这张卡上"。
    //    正确写法是把扩展名放最左、主名倒序放右边，
    //    或者干脆用下面这种逐字节赋值的 task（本文件采用后者）。
    // ------------------------------------------------------------------
    task mk_name8_3(input [63:0] nm8, input [23:0] ext3, output [87:0] res);
        integer k;
        begin
            res = 88'd0;
            // 主名 8 字节：nm8 的最高字节是第 0 个字符
            for (k = 0; k < 8; k = k + 1)
                res[k*8 +: 8] = nm8[(7-k)*8 +: 8];
            // 扩展名 3 字节：ext3 的最高字节是第 8 个字符
            for (k = 0; k < 3; k = k + 1)
                res[(k+8)*8 +: 8] = ext3[(2-k)*8 +: 8];
        end
    endtask

    reg [87:0] NAME_BGM;
    reg [87:0] NAME_NONE;
    reg [87:0] NAME_NARR;

    // ------------------------------------------------------------------
    //  第 i 个样本的期望值（16 位有符号，再符号扩展到 24 位）
    //    build_image 写的是 (i*100) & 16'hFFFF；i >= 328 时该值超过
    //    32767，落进负数区间，DUT 会按 $signed 扩展成 24 位负数。
    //    判据必须复现同一语义，否则会误判成 RTL 错。
    // ------------------------------------------------------------------
    function signed [23:0] exp_samp(input integer i);
        reg [15:0] raw;
        begin
            raw = (i * 100) & 16'hFFFF;
            exp_samp = {{8{raw[15]}}, raw};
        end
    endfunction

    // ========================================================================
    //  主流程
    // ========================================================================
    integer ok;
    integer k;
    integer mism;
    integer lguard;   // L01/L03 轮询超时守卫（wait_idle 里的 guard 是 task 局部的，不能共用）
    time    period_avg;
    time    period_lo;
    time    period_hi;

    initial begin
        NAME_BGM  = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h4D, 8'h47, 8'h42};
        NAME_NONE = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h5A, 8'h5A, 8'h5A};
        NAME_NARR = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20, 8'h20, 8'h52, 8'h52, 8'h41, 8'h4E};

        // ====================================================================
        //  C01 —— 复位初值
        // ====================================================================
        g_chan = 1; g_rate = 48000; g_bits = 16; g_format = 1;
        g_riff_bad = 0; g_extra_list = 0; g_no_fmt = 0; g_data_size = PCM_BYTES;
        build_image;
        do_reset;
        clr_coll;
        chk(busy     == 1'b0, "C01a reset: busy == 0");
        chk(playing  == 1'b0, "C01b reset: playing == 0");
        chk(err_code == 4'd0, "C01c reset: err_code == 0");
        chk(underrun == 1'b0, "C01d reset: underrun == 0");

        // ====================================================================
        //  C02 —— 正常播放（跨 3 簇 + 无关 chunk 跳过）
        // ====================================================================
        $display("");
        $display("---- C02: normal playback (1044 B file spanning 3 clusters) ----");
        g_extra_list = 1;                 // 顺带验证 LIST chunk 被跳过
        build_image;
        do_reset;
        clr_coll;
        fire_start(NAME_BGM);
        wait_idle(ok);
        chk(ok == 1,             "C02a playback finished without hang");
        chk(err_code == 4'd0,    "C02b err_code == 0 (no error)");
        chk(playing == 1'b0,     "C02c playing deasserted at end");
        chk(underrun == 1'b0,    "C02d no underrun during normal playback");
        chk(oob_hits == 0,       "C02e no out-of-range LBA access");
        chk(max_fifo <= 1024,    "C02f FIFO never overflowed (<= 1024)");
        $display("     collected samples = %0d (expect 500)", s_cnt);
        chk(s_cnt >= 500,        "C02g collected at least 500 samples");

        // ---- C03 —— 样本值顺序正确（前 200 个逐个比对，i*100）----
        mism = 0;
        for (k = 0; k < 200; k = k + 1) begin
            if (s_val[k] !== (k * 100)) begin
                if (mism < 5)
                    $display("     sample[%0d] = %0d, expect %0d", k, s_val[k], k * 100);
                mism = mism + 1;
            end
        end
        chk(mism == 0, "C03 first 200 samples identical to i*100 (order + value)");

        // ---- C04 —— 尾部样本也正确（证明跨簇拼接无错位）----
        //   ★ 期望值必须按 **16 位有符号** 算，不能直接比 k*100：
        //     build_image 写入的是 (i*100) & 16'hFFFF，从 i=328 起
        //     32800 > 32767 已经溢出成负数（0x8020 = -32736），
        //     DUT 正确地符号扩展成 24 位 -32736，而 tb 若拿整数
        //     32800 去比就必然失配 —— 这是判据错，不是 RTL 错。
        mism = 0;
        for (k = 400; k < 500; k = k + 1) begin
            if (s_val[k] !== exp_samp(k)) begin
                if (mism < 5)
                    $display("     sample[%0d] = %0d, expect %0d",
                             k, s_val[k], exp_samp(k));
                mism = mism + 1;
            end
        end
        chk(mism == 0, "C04 samples 400..499 correct (cluster chain stitched)");

        // ---- C05 —— 左右声道相同（单声道复制）----
        chk(sample_l == sample_r, "C05 mono source duplicated to both channels");

        // ---- C06 —— 采样节拍平均 520.8333 拍/样本 ----
        if (tick_t1 > tick_t0) begin
            // 100 个样本跨度 = 100 * 520.8333 * 40ns = 2,083,333 ns
            tick_span = tick_t1 - tick_t0;
            $display("     tick span for 100 samples = %0d ns (expect ~2083333)", tick_span);
            chk((tick_span > 2_082_000) && (tick_span < 2_085_000),
                "C06 sample tick period averages 520.8333 cycles (phase accumulator)");
        end else begin
            chk(1'b0, "C06 sample tick period averages 520.8333 cycles");
        end

        // ---- C07 —— W_FATLOC 期间 want_blk 必须拉高 ----
        chk(want_in_fatloc == 1,
            "C07 want_blk asserted during W_FATLOC (else fr_blk_start is swallowed)");

        // ====================================================================
        //  C08 —— 欠载：播放中途停 SD，输出必须保持而非归零
        // ====================================================================
        $display("");
        $display("---- C08: underrun (stall SD mid-playback) ----");
        build_image;
        do_reset;
        clr_coll;
        fire_start(NAME_BGM);
        // 等播放真正开始并填满 FIFO
        wait (playing == 1'b1);
        repeat (60_000) @(posedge clk);
        // 憋住 SD 700,000 拍 ≈ 1024 样本 × 520 拍 + 余量 → FIFO 必然耗尽
        stall_len = 700_000;
        stall_cnt = stall_len;
        repeat (750_000) @(posedge clk);
        chk(underrun == 1'b1, "C08a underrun flagged when FIFO starved with data_left != 0");
        // 关键断言：欠载期间输出不得归零（归零对 sigma-delta 是爆音）
        chk(sample_l !== 24'sd0 || s_val[s_cnt-1] === 24'sd0,
            "C08b output held last sample during underrun (not forced to zero)");
        stall_cnt = 0;
        repeat (5_000) @(posedge clk);
        $display("     underrun=%0b err=%0d", underrun, err_code);

        // ====================================================================
        //  错误路径（每个都是重建镜像 + 复位 + 启动，快速失败）
        // ====================================================================
        // ---- C09 —— RIFF 标识错 → err 1 ----
        $display("");
        $display("---- C09..C15: error paths ----");
        g_chan = 1; g_rate = 48000; g_bits = 16; g_format = 1;
        g_extra_list = 0; g_no_fmt = 0; g_data_size = PCM_BYTES;
        g_riff_bad = 1; build_image; do_reset; clr_coll;
        fire_start(NAME_BGM); wait_idle(ok);
        chk(err_code == 4'd1, "C09 bad RIFF magic -> err_code 1");
        g_riff_bad = 0;

        // ---- C10 —— fmt 非 PCM → err 2 ----
        g_format = 3; build_image; do_reset; clr_coll;
        fire_start(NAME_BGM); wait_idle(ok);
        chk(err_code == 4'd2, "C10 non-PCM format -> err_code 2");
        g_format = 1;

        // ---- C11 —— 位深非 16 → err 3 ----
        g_bits = 8; build_image; do_reset; clr_coll;
        fire_start(NAME_BGM); wait_idle(ok);
        chk(err_code == 4'd3, "C11 bits != 16 -> err_code 3");
        g_bits = 16;

        // ---- C12 —— 采样率非 48k → err 4 ----
        g_rate = 44100; build_image; do_reset; clr_coll;
        fire_start(NAME_BGM); wait_idle(ok);
        chk(err_code == 4'd4, "C12 sample rate != 48000 -> err_code 4");
        g_rate = 48000;

        // ---- C13 —— 声道数非 1 → err 9 ----
        g_chan = 2; build_image; do_reset; clr_coll;
        fire_start(NAME_BGM); wait_idle(ok);
        chk(err_code == 4'd9, "C13 channels != 1 -> err_code 9");
        g_chan = 1;

        // ---- C14 —— 没有 fmt chunk → err 2 ----
        g_no_fmt = 1; build_image; do_reset; clr_coll;
        fire_start(NAME_BGM); wait_idle(ok);
        chk(err_code == 4'd2, "C14 missing fmt chunk -> err_code 2");
        g_no_fmt = 0;

        // ---- C15 —— 文件不存在 → err 6 ----
        build_image; do_reset; clr_coll;
        fire_start(NAME_NONE); wait_idle(ok);
        chk(err_code == 4'd6, "C15 missing file -> err_code 6");

        // ====================================================================
        //  C16 —— data chunk 长度 > 实际数据（截断）→ err 5 或正常结束
        //    这里让 data 声明的长度比文件剩余字节多，走 FAT 链到 EOC 时
        //    data_left != 0 → 必须报截断，而不是"播到一半静默停止"。
        // ====================================================================
        g_data_size = 32'd4000;                // 声明 4000 字节，实际只有 1000
        build_image; do_reset; clr_coll;
        fire_start(NAME_BGM); wait_idle(ok);
        chk(err_code == 4'd5, "C16 truncated data -> err_code 5");
        g_data_size = PCM_BYTES;

        // ====================================================================
        //  L01..L03 —— 循环播放（captain m01303 指定）
        //    母版规格 BGM/BGM2/BGM3/ALARM 四段全部 loop=true。
        //    不循环 = 日常模式响 40 秒后永久静音、应急 siren 6 秒后静音。
        // ====================================================================
        $display("");
        $display("---- L01..L03: loop playback ----");

        // ---- L01 —— loop=1：跑完一整遍后继续出样本，第二轮首样本 == 第一轮首样本
        //   镜像里的文件只有 500 个样本（1044 B），跑完 500 个就该回绕。
        //   判据：跑到 900 个样本时仍未结束，且 s_val[500..] 与 s_val[0..] 逐点相同。
        build_image; do_reset; clr_coll;
        loop = 1'b1;
        fire_start(NAME_BGM);
        // 等采集到足够样本（500 + 400 = 900 覆盖一整圈 + 400 个第二圈样本）
        lguard = 0;
        while ((s_cnt < 900) && (lguard < 6_000_000)) begin
            @(posedge clk);
            lguard = lguard + 1;
        end
        chk(s_cnt >= 900, "L01a loop=1 keeps producing samples past end of file");
        chk(err_code == 4'd0, "L01b loop=1 err_code stays 0 after wraparound");
        chk(busy == 1'b1, "L01c loop=1 still busy (did not fall back to W_IDLE)");
        // 第二圈首样本必须与第一圈首样本相同（证明回到 PCM 起点而非文件首簇）
        mism = 0;
        for (k = 0; k < 400; k = k + 1) begin
            if (s_val[500 + k] !== s_val[k]) begin
                if (mism < 5)
                    $display("     loop sample[%0d] = %0d, first-pass [%0d] = %0d",
                             k, s_val[500 + k], k, s_val[k]);
                mism = mism + 1;
            end
        end
        chk(mism == 0, "L01d second pass samples identical to first pass (wrapped to PCM start, not file start)");
        chk(s_val[500] == 24'sd0 && s_val[501] === 24'sd100,
            "L01e wraparound starts exactly at PCM sample 0 (no WAV header leaked into FIFO)");

        // ---- L02 —— loop=0：跑完必须停（保持既有行为，不能改坏）----
        loop = 1'b0;
        build_image; do_reset; clr_coll;
        fire_start(NAME_BGM);
        wait_idle(ok);
        chk(ok == 1,          "L02a loop=0 finishes without hang");
        chk(playing == 1'b0,  "L02b loop=0 playing deasserted at end");
        chk(u_dut.st == u_dut.W_IDLE, "L02c loop=0 returns to W_IDLE");
        chk(s_cnt >= 500 && s_cnt < 600,
            "L02d loop=0 produces exactly one pass of samples");

        // ---- L03 —— loop=1 连跑三圈，err_code 全程为 0（验 clu_count 清零生效）----
        //   1500 个样本 = 3 圈 × 500。若回绕时漏清 clu_count，第二圈
        //   立刻撞 CHAIN_MAX 报 E_TRUNC，err_code 会变成 5。
        loop = 1'b1;
        build_image; do_reset; clr_coll;
        fire_start(NAME_BGM);
        lguard = 0;
        while ((s_cnt < 1500) && (lguard < 12_000_000)) begin
            @(posedge clk);
            lguard = lguard + 1;
        end
        chk(s_cnt >= 1500,    "L03a loop=1 runs at least 3 full passes");
        chk(err_code == 4'd0, "L03b err_code stays 0 across 3 wraparounds (clu_count reset works)");
        chk(underrun == 1'b0, "L03c no underrun across 3 wraparounds");
        loop = 1'b0;

        // ====================================================================
        //  D02 —— BGM → NARR 换源（t26）
        //    同一个 wav_stream_player 实例、同一个 u_fat 实例，播完 BGM 后
        //    **不复位**直接换源播 NARR。这正对应「用户开机后切一次模式」
        //    的真实路径（日常模式播 BGM、科普模式换 NARR）。
        //    修复前：u_fat 停在 S_DONE，start 被吞，第二次拿到的是陈旧元数据。
        // ====================================================================
        $display("");
        $display("---- D02: source swap BGM -> NARR without reset ----");
        loop = 1'b0;
        g_add_narr = 1;
        build_image; do_reset; clr_coll;
        fire_start(NAME_BGM);
        wait_idle(ok);
        chk(ok == 1 && err_code == 4'd0, "D02a BGM plays to completion (err 0)");
        chk(u_dut.wav_cluster == 32'd4 && u_dut.wav_size == FILE_BYTES[31:0],
            "D02b BGM metadata located (clu 4, 1044 B)");
        $display("     after BGM: clu=%0d size=%0d samples=%0d",
                 u_dut.wav_cluster, u_dut.wav_size, s_cnt);

        // 换源：只发 start，不碰 rst_n
        clr_coll;
        fire_start(NAME_NARR);
        wait_idle(ok);
        $display("     after NARR: clu=%0d size=%0d samples=%0d err=%0d",
                 u_dut.wav_cluster, u_dut.wav_size, s_cnt, err_code);
        chk(ok == 1,                        "D02c second source finishes without hang");
        chk(err_code == 4'd0,               "D02d second source err_code 0 (no E_BLKTMO)");
        chk(u_dut.wav_cluster == 32'd7,     "D02e locator re-ran and found NARR at cluster 7");
        chk(u_dut.wav_size == NARR_BYTES[31:0],
            "D02f locator returned NARR size 244 (not the stale 1044)");
        chk(s_cnt >= 90 && s_cnt <= 120,    "D02g second source played ~100 samples, not BGM's 500");
        chk(s_val[0] == 24'sd3 && s_val[1] === 24'sd10,
            "D02h first samples come from NARR PCM (i*7+3), not BGM (i*100)");
        g_add_narr = 0;

        // ====================================================================
        //  收尾
        // ====================================================================
        $display("");
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: wav_stream_player");
        end else begin
            $display("CHECKS FAILED: wav_stream_player  pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
        $display("=== tb_wav_stream_player: pass=%0d fail=%0d ===", pass_cnt, fail_cnt);
        $finish;
    end

    // 全局超时
    initial begin
        #200_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
