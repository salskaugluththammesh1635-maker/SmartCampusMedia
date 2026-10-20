// ============================================================================
// tb_fat32_reader —— fat32_reader 独立仿真（S3 切片验证）
// ============================================================================
// 验证内容（13 项，每项对应一个真实失效可能）:
//   T01 正常命中 IMG001.BMP:  首簇 5、大小 921654 均应正确回读
//   T02 小写短名命中:         "img002  bmp" 也应命中（大小写不敏感）
//   T03 目录项不算文件:       IMG003.BMP 属性 0x10（目录）必须跳过
//   T04 不存在的序号:         IMG009 不在目录 → err=4（未找到）
//   T05 目录跨簇:             根目录第 1 簇读尽后沿 FAT 链到第 2 簇找到 IMG010
//   T06 LFN/卷标项跳过:       镜像第 0 项是 LFN(0x0F)、第 1 项是卷标(0x08)
//   T07 MBR 签名坏:           签名非 0x55AA → err=1
//   T08 VBR 签名坏:           BPB 尾部签名错 → err=2
//   T09 BPB 簇大小为 0:       spc=0（非法）→ err=2
//   T10 BPB 簇大小非 2 的幂:  spc=3 → err=2
//   T11 目录簇链尾提前结束:   FAT[2]=链尾且目录无匹配 → err=4
//   T12 FAT 项非法:           FAT[2]=0（空闲簇）→ err=3
//   T13 底层读块失败:         卡模型注入 blk_err → err=5
//   T14 序号 0:               img_index=0 无意义 → err=6
//   T15 分区起始 LBA 为 0:    分区表项无效 → err=2
//
// 卡模型说明:
//   本 tb 用「扇区读取模型」顶替 sd_spi_ctrl——它对 fat32_reader 呈现同样的
//   blk_start/blk_addr → data_valid/data_byte ×512 → blk_done 握手。
//   磁盘镜像存在 disk[] 一维字节数组里，由 build_image() 按场景重新构造，
//   不依赖外部镜像文件（便于在任意机器上复跑）。
// ============================================================================
`timescale 1ns/1ps

module tb_fat32_reader;

    // ---- 时钟与复位（25MHz 周期 40ns）----
    reg clk = 1'b0;
    always #20 clk = ~clk;
    reg rst_n = 1'b0;

    // ---- DUT 连线 ----
    reg         start   = 1'b0;
    reg  [8:0]  img_index = 9'd1;
    wire        busy, found, fail;
    wire [3:0]  err_code;
    wire [31:0] file_size;
    wire [31:0] first_cluster;
    wire [31:0] out_data_begin;   // 新增输出：数据区首扇区号
    wire [31:0] out_fat_begin;    // 新增输出：FAT 表首扇区号
    wire [7:0]  out_spc;          // 新增输出：每簇扇区数

    wire        blk_start;
    wire [31:0] blk_addr;
    wire        blk_busy;
    reg         blk_done = 1'b0;
    reg         blk_err  = 1'b0;
    reg  [7:0]  data_byte = 8'h00;
    reg         data_valid = 1'b0;

    // ---- DUT ----
    fat32_reader #(
        .FAT_CHAIN_MAX (8)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .img_index     (img_index),
        .busy          (busy),
        .found         (found),
        .fail          (fail),
        .err_code      (err_code),
        .file_size     (file_size),
        .first_cluster (first_cluster),
        .out_data_begin(out_data_begin),
        .out_fat_begin (out_fat_begin),
        .out_spc       (out_spc),
        .blk_start     (blk_start),
        .blk_addr      (blk_addr),
        .blk_busy      (blk_busy),
        .blk_done      (blk_done),
        .blk_err       (blk_err),
        .data_byte     (data_byte),
        .data_valid    (data_valid)
    );

    // ---- 检查工具 ----
    integer errors = 0;
    integer oob_hits = 0;                  // 越界 LBA 访问计数（必须为 0）
    task chk;
        input         cond;
        input [511:0] name;
        begin
            if (cond) begin
                $display("PASS: %0s", name);
            end else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ========================================================================
    // 磁盘镜像与扇区读取模型
    // ========================================================================
    localparam NSEC = 16;                  // 镜像 16 个扇区 = 8KB
    reg [7:0] disk [0:NSEC*512-1];

    // —— 扇区读取模型（顶替 sd_spi_ctrl）——
    reg        card_active = 1'b0;
    reg [31:0] card_lba    = 32'd0;
    reg [9:0]  card_cnt    = 10'd0;
    reg        card_fail   = 1'b0;
    reg        err_inject  = 1'b0;         // 测试用: 1 = 本次读块注入错误

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            card_active <= 1'b0;
            card_lba    <= 32'd0;
            card_cnt    <= 10'd0;
            card_fail   <= 1'b0;
            data_byte   <= 8'h00;
            data_valid  <= 1'b0;
            blk_done    <= 1'b0;
            blk_err     <= 1'b0;
        end else begin
            blk_done  <= 1'b0;
            blk_err   <= 1'b0;
            if (blk_start && !card_active) begin
                card_active <= 1'b1;
                card_lba    <= blk_addr;
                card_cnt    <= 10'd0;
                card_fail   <= err_inject;
                // 越界 LBA 检测: fat32_reader 若把非法簇号当成有效簇号，
                // 算出的 LBA 会远超镜像范围。此时不能静默返回垃圾数据——
                // 否则「读到越界数据→簇链耗尽→撞 FAT_CHAIN_MAX 兜底」
                // 这条错误路径最终也会报 err=3，与正确的「FAT 项拦截」
                // 无法区分，变异体就会在仿真中存活。
                if (blk_addr >= NSEC) begin
                    $display("FAIL: out-of-range LBA access: addr=%0d (image has %0d sectors)",
                             blk_addr, NSEC);
                    oob_hits = oob_hits + 1;
                end
            end else if (card_active) begin
                if (card_fail) begin
                    data_valid  <= 1'b0;
                    blk_err     <= 1'b1;       // 注入读块失败
                    card_active <= 1'b0;
                end else if (card_cnt < 10'd512) begin
                    data_byte   <= disk[card_lba*512 + card_cnt];
                    data_valid  <= 1'b1;
                    card_cnt    <= card_cnt + 10'd1;
                end else begin
                    data_valid  <= 1'b0;
                    blk_done    <= 1'b1;       // 512 字节发完
                    card_active <= 1'b0;
                end
            end else begin
                data_valid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // 镜像构造工具
    // ========================================================================
    task wr8;
        input [15:0] sec;
        input [8:0]  off;
        input [7:0]  val;
        begin
            disk[sec*512 + off] = val;
        end
    endtask

    task wr16;
        input [15:0] sec;
        input [8:0]  off;
        input [15:0] val;
        begin
            disk[sec*512 + off]     = val[7:0];
            disk[sec*512 + off + 1] = val[15:8];
        end
    endtask

    task wr32;
        input [15:0] sec;
        input [8:0]  off;
        input [31:0] val;
        begin
            disk[sec*512 + off]     = val[7:0];
            disk[sec*512 + off + 1] = val[15:8];
            disk[sec*512 + off + 2] = val[23:16];
            disk[sec*512 + off + 3] = val[31:24];
        end
    endtask

    // 构造「IMGnnn.BMP」短名目录项
    //   num  : 1~999         attr : 属性字节
    //   clu  : 首簇号        sz   : 文件大小
    //   lower: 1 = 短名存成小写
    task mkfile;
        input [15:0] sec;
        input [3:0]  ent;
        input [8:0]  num;
        input [7:0]  attr;
        input [31:0] clu;
        input [31:0] sz;
        input        lower;
        integer base;
        integer h, t, o;
        integer i;
        begin
            base = sec*512 + ent*32;
            h = num / 100;
            t = (num % 100) / 10;
            o = num % 10;
            // 8 字节名域: I/M/G + 三位数字 + 两个空格
            disk[base+0] = lower ? "i" : "I";
            disk[base+1] = lower ? "m" : "M";
            disk[base+2] = lower ? "g" : "G";
            disk[base+3] = "0" + h;
            disk[base+4] = "0" + t;
            disk[base+5] = "0" + o;
            disk[base+6] = " ";
            disk[base+7] = " ";
            // 3 字节扩展名域: B/M/P
            disk[base+8]  = lower ? "b" : "B";
            disk[base+9]  = lower ? "m" : "M";
            disk[base+10] = lower ? "p" : "P";
            disk[base+11] = attr;
            disk[base+12] = 8'h00;             // NTRes
            disk[base+13] = 8'h00;             // CrtTimeTenth
            for (i = 14; i <= 19; i = i + 1) disk[base+i] = 8'h00;
            disk[base+20] = clu[23:16];        // +0x14 首簇高 16 位（低字节）
            disk[base+21] = clu[31:24];
            disk[base+22] = 8'h00;
            disk[base+23] = 8'h00;
            disk[base+24] = 8'h00;
            disk[base+25] = 8'h00;
            disk[base+26] = clu[7:0];          // +0x1A 首簇低 16 位（低字节）
            disk[base+27] = clu[15:8];
            disk[base+28] = sz[7:0];           // +0x1C 文件大小
            disk[base+29] = sz[15:8];
            disk[base+30] = sz[23:16];
            disk[base+31] = sz[31:24];
        end
    endtask

    // 构造一个「任意名字」目录项（用于 LFN / 卷标 / 干扰项）
    task mkother;
        input [15:0] sec;
        input [3:0]  ent;
        input [7:0]  b0;                   // 首字节（0xE5=删除, 0x00=结束）
        input [7:0]  attr;
        integer base;
        integer i;
        begin
            base = sec*512 + ent*32;
            for (i = 0; i < 32; i = i + 1) disk[base+i] = 8'h00;
            disk[base+0]  = b0;
            disk[base+11] = attr;
        end
    endtask

    // ========================================================================
    // 场景镜像构造
    // ========================================================================
    // 基础布局（分区起始 LBA = 4 / reserved=1 / spc=1 / num_fats=2 / fat_size=1 /
    // root_cluster=2）:
    //   VBR        = LBA 4
    //   fat_begin  = part(4) + reserved(1) = 5
    //   data_begin = 5 + 2*1 = 7
    //   簇 2 → LBA 7, 簇 3 → LBA 8, 簇 4 → LBA 9 ...
    //
    // 为什么分区起始 LBA 取 4 而不是 1:
    //   若取 1，字节序为 01 00 00 00，与「偏移 450 处分区类型+CHS」等
    //   近邻字段的值域高度混淆，RTL 把 454 错写成 450 也能读出近似结果，
    //   这类偏移错误会在仿真中静默通过。取 4 后错位读数必然不同。
    localparam [31:0] PART_LBA = 32'd4;

    localparam [15:0] L_MBR  = 16'd0;      // MBR（绝对 LBA 0）
    localparam [15:0] L_VBR  = 16'd4;      // 分区 VBR / BPB
    localparam [15:0] L_FAT1 = 16'd5;      // FAT 副本 1
    localparam [15:0] L_FAT2 = 16'd6;      // FAT 副本 2
    localparam [15:0] L_DIR0 = 16'd7;      // 数据区簇 2 = 根目录第 1 簇
    localparam [15:0] L_DIR1 = 16'd8;      // 数据区簇 3 = 根目录第 2 簇
    localparam [15:0] L_FILE = 16'd9;      // 数据区簇 4

    localparam SC_BASIC   = 4'd0,  // 正常（含 LFN/卷标/目录/小写）
               SC_XCLU    = 4'd1,  // 根目录跨簇
               SC_BADMBR  = 4'd2,  // MBR 签名坏
               SC_BADVBR  = 4'd3,  // VBR 签名坏
               SC_SPC0    = 4'd4,  // spc = 0
               SC_SPC3    = 4'd5,  // spc = 3（非 2 的幂）
               SC_CHAINEND= 4'd6,  // 目录簇链尾提前结束（EOC 非 0x0FFFFFFF）
               SC_FATBAD  = 4'd7,  // FAT[2] = 0（非法簇号）
               SC_PART0   = 4'd8,  // 分区起始 LBA = 0
               SC_HICLU   = 4'd9,  // 首簇高 16 位非零（>65535）
               SC_RSV     = 4'd10; // FAT[2] 落在保留区 0x0FFFFFF0~0x0FFFFFF7

    integer i;
    task build_image;
        input [3:0] sc;
        reg [15:0] rsv;
        reg [7:0]  sp, nf;
        reg [31:0] fsz, rc;
        reg [15:0] mbrsig, vbrsig;
        reg [31:0] plba;
        begin
            // 全场清零
            for (i = 0; i < NSEC*512; i = i + 1) disk[i] = 8'h00;

            // 默认 BPB 参数
            rsv    = 16'd1;
            sp     = 8'd1;
            nf     = 8'd2;
            fsz    = 32'd1;
            rc     = 32'd2;
            mbrsig = 16'hAA55;
            vbrsig = 16'hAA55;
            plba   = PART_LBA;
            case (sc)
                SC_BADMBR:   mbrsig = 16'h1234;
                SC_BADVBR:   vbrsig = 16'h1234;
                SC_SPC0:     sp     = 8'd0;
                SC_SPC3:     sp     = 8'd3;
                SC_PART0:    plba   = 32'd0;
                default: begin end
            endcase

            // ---- MBR（LBA 0）----
            // 分区表项0 布局: +0 引导标志, +1..3 起始 CHS, +4 分区类型,
            //                 +5..7 结束 CHS, +8..11 起始 LBA, +12..15 扇区数
            // 注意: 绝对偏移 450 处是「分区类型 + 结束 CHS」，绝不能写成起
            //       始 LBA 的副本——否则 RTL 把 454 错写成 450 也读不出差异，
            //       该类偏移错误就会在仿真中静默通过。
            wr8 (L_MBR, 9'd446, 8'h80);                // 引导标志（活动分区）
            wr8 (L_MBR, 9'd450, 8'h0C);                // 分区类型 = FAT32 LBA
            wr32(L_MBR, 9'd454, plba);                 // 起始 LBA
            wr32(L_MBR, 9'd458, 32'd8192);             // 分区扇区数
            wr16(L_MBR, 9'd510, mbrsig);

            // ---- VBR / BPB（LBA 1）----
            wr16(L_VBR, 9'd11, 16'd512);               // bytes_per_sector
            wr8 (L_VBR, 9'd13, sp);                    // sectors_per_cluster
            wr16(L_VBR, 9'd14, rsv);                   // reserved_sectors
            wr8 (L_VBR, 9'd16, nf);                    // num_fats
            wr32(L_VBR, 9'd36, fsz);                   // fat_size_sectors
            wr32(L_VBR, 9'd44, rc);                    // root_cluster
            wr16(L_VBR, 9'd510, vbrsig);

            // ---- FAT 副本（两份内容相同）----
            // 簇 2（根目录首簇）: 基础场景为链尾；跨簇场景指向簇 3
            if (sc == SC_CHAINEND) begin
                // 链尾用 0x0FFFFFF8（EOC 区间下沿，非 0x0FFFFFFF）：
                // 若 RTL 只认 0x0FFFFFFF 会把 EOC 当成有效簇号而算飞 LBA
                wr32(L_FAT1, 9'd8,  32'h0FFF_FFF8);
                wr32(L_FAT2, 9'd8,  32'h0FFF_FFF8);
            end else if (sc == SC_RSV) begin
                // 保留区下沿 0x0FFFFFF0：既不是 EOC 也不是有效簇号
                wr32(L_FAT1, 9'd8,  32'h0FFF_FFF0);
                wr32(L_FAT2, 9'd8,  32'h0FFF_FFF0);
            end else if (sc == SC_FATBAD) begin
                wr32(L_FAT1, 9'd8,  32'h0000_0000);    // 簇2→0 = 空闲簇（非法）
                wr32(L_FAT2, 9'd8,  32'h0000_0000);
            end else if (sc == SC_XCLU) begin
                wr32(L_FAT1, 9'd8,  32'd3);            // 簇2→簇3
                wr32(L_FAT2, 9'd8,  32'd3);
                wr32(L_FAT1, 9'd12, 32'h0FFF_FFF8);    // 簇3→EOC(下沿)
                wr32(L_FAT2, 9'd12, 32'h0FFF_FFF8);
            end else begin
                wr32(L_FAT1, 9'd8,  32'h0FFF_FEF8);    // 簇2→EOC(中值)
                wr32(L_FAT2, 9'd8,  32'h0FFF_FEF8);
            end
            // 簇 3/4/5 一律 EOC 中值（供文件数据使用，目录不追）
            wr32(L_FAT1, 9'd12, 32'h0FFF_FEF8);
            wr32(L_FAT1, 9'd16, 32'h0FFF_FEF8);
            wr32(L_FAT1, 9'd20, 32'h0FFF_FEF8);
            wr32(L_FAT2, 9'd12, 32'h0FFF_FEF8);
            wr32(L_FAT2, 9'd16, 32'h0FFF_FEF8);
            wr32(L_FAT2, 9'd20, 32'h0FFF_FEF8);

            // ---- 根目录第 1 簇 ----
            if (sc == SC_XCLU) begin
                // 16 项全部是干扰项（非目标名），且不能出现 0x00 结束标记
                for (i = 0; i < 16; i = i + 1) begin
                    mkfile(L_DIR0, i[3:0], 9'd100 + i[8:0], 8'h20,
                           32'd4, 32'd100, 1'b0);
                end
                // 第 2 簇: 放 IMG010
                mkfile(L_DIR1, 4'd0, 9'd10, 8'h20, 32'd6, 32'd921654, 1'b0);
                mkother(L_DIR1, 4'd1, 8'h00, 8'h00);   // 结束标记
            end else if ((sc == SC_CHAINEND) || (sc == SC_FATBAD) ||
                         (sc == SC_RSV)) begin
                // 这三种场景必须让 RTL 真正走到 FAT 表取下一簇，
                // 所以第 1 簇必须塞满 16 个「不匹配项」且不得出现 0x00 结束标记
                for (i = 0; i < 16; i = i + 1) begin
                    mkfile(L_DIR0, i[3:0], 9'd100 + i[8:0], 8'h20,
                           32'd4, 32'd100, 1'b0);
                end
            end else if (sc == SC_HICLU) begin
                // 首簇高 16 位两个字节都非零: 0x0101_0005 = 16842757。
                // 为什么两个字节都要非零: 若只用 0x0001_0005，高 16 位的高
                // 字节恒为 0x00，把 hit_clu_hi[15:8] 的赋值删掉的变异体
                // 读出的结果不变，该变异就会在仿真中静默存活。
                // 上界校验: 0x01010005 < 0x0FFFFFEF，是合法簇号。
                mkother(L_DIR0, 4'd0, 8'h41, 8'h0F);   // LFN
                mkfile (L_DIR0, 4'd1, 9'd1, 8'h20, 32'h0101_0005,
                        32'd921654, 1'b0);
                mkother(L_DIR0, 4'd2, 8'h00, 8'h00);   // 结束标记
            end else begin
                mkother(L_DIR0, 4'd0, 8'h41, 8'h0F);   // 项0: LFN 序列（必须跳过）
                mkother(L_DIR0, 4'd1, 8'h42, 8'h08);   // 项1: 卷标（必须跳过）
                mkfile (L_DIR0, 4'd2, 9'd1, 8'h20, 32'd5, 32'd921654, 1'b0);
                mkfile (L_DIR0, 4'd3, 9'd2, 8'h20, 32'd6, 32'd230454, 1'b1);
                mkfile (L_DIR0, 4'd4, 9'd3, 8'h10, 32'd7, 32'd0,      1'b0);
                mkother(L_DIR0, 4'd5, 8'h00, 8'h00);   // 项5: 目录结束
            end
        end
    endtask

    // ========================================================================
    // 场景驱动工具
    // ========================================================================
    task do_reset;
        begin
            rst_n = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task fire_start;
        input [8:0] idx;
        begin
            img_index = idx;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task wait_terminal;
        integer guard;
        begin
            guard = 0;
            while (!found && !fail && guard < 400000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (guard >= 400000) $display("TIMEOUT: terminal state not reached");
        end
    endtask

    // ========================================================================
    // 主测试序列
    // ========================================================================
    initial begin
        $display("=== tb_fat32_reader start ===");

        // ---------------- T01 正常命中 IMG001.BMP ----------------
        err_inject = 1'b0;
        build_image(SC_BASIC);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        $display("  T01: found=%b fail=%b err=%0d clu=%0d size=%0d",
                 found, fail, err_code, first_cluster, file_size);
        chk(found,      "T01 found IMG001.BMP");
        chk(!fail,      "T01 no failure flag");
        chk(first_cluster == 32'd5,     "T01 first cluster = 5");
        chk(file_size     == 32'd921654,"T01 file size = 921654 (921,654 B)");
        // 新增输出：默认 BPB(rv=1, spc=1, nf=2, fsz=1) 且分区起点 PART_LBA=4
        //   fat_begin  = 4 + 1          = 5
        //   data_begin = 5 + 2 × 1      = 7
        chk(out_fat_begin  == 32'd5, "T01 out_fat_begin  = 5  (part 4 + reserved 1)");
        chk(out_data_begin == 32'd7, "T01 out_data_begin = 7  (fat 5 + 2 x 1)");
        chk(out_spc        == 8'd1,  "T01 out_spc        = 1");

        // ---------------- T02 小写短名命中 ----------------
        build_image(SC_BASIC);
        do_reset;
        fire_start(9'd2);
        wait_terminal;
        $display("  T02: found=%b err=%0d clu=%0d size=%0d",
                 found, err_code, first_cluster, file_size);
        chk(found,      "T02 lowercase short name matched");
        chk(first_cluster == 32'd6,     "T02 first cluster = 6");
        chk(file_size     == 32'd230454,"T02 file size = 230454");

        // ---------------- T03 目录项不算文件 ----------------
        build_image(SC_BASIC);
        do_reset;
        fire_start(9'd3);
        wait_terminal;
        $display("  T03: fail=%b err=%0d", fail, err_code);
        chk(fail && !found,        "T03 directory entry is not a file");
        chk(err_code == 4'd4,      "T03 err = 4 (not found)");

        // ---------------- T04 不存在的序号 ----------------
        build_image(SC_BASIC);
        do_reset;
        fire_start(9'd9);
        wait_terminal;
        $display("  T04: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd4, "T04 IMG009 absent -> err = 4");

        // ---------------- T05 目录跨簇 ----------------
        build_image(SC_XCLU);
        do_reset;
        fire_start(9'd10);
        wait_terminal;
        $display("  T05: found=%b err=%0d clu=%0d size=%0d",
                 found, err_code, first_cluster, file_size);
        chk(found,      "T05 root dir walked across cluster chain");
        chk(first_cluster == 32'd6,     "T05 IMG010 first cluster = 6");
        chk(file_size     == 32'd921654,"T05 IMG010 size correct");

        // ---------------- T06 LFN 与卷标跳过（用 IMG002 验证仍有命中能力）----
        // 基础镜像的项0=LFN、项1=卷标，若二者被误当文件，
        // 会让 T03 的目录项判断输出错乱；T01/T02 已证明越过它们命中，
        // 此处再用序号 1 验证命中的是"项2"而不是"项0/1"。
        build_image(SC_BASIC);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        chk(found && first_cluster == 32'd5,
            "T06 LFN and volume label skipped correctly");

        // ---------------- T07 MBR 签名坏 ----------------
        build_image(SC_BADMBR);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        $display("  T07: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd1, "T07 bad MBR signature -> err = 1");

        // ---------------- T08 VBR 签名坏 ----------------
        build_image(SC_BADVBR);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        $display("  T08: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd2, "T08 bad VBR signature -> err = 2");

        // ---------------- T09 BPB 簇大小为 0 ----------------
        build_image(SC_SPC0);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        $display("  T09: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd2, "T09 spc = 0 -> err = 2");

        // ---------------- T10 BPB 簇大小非 2 的幂 ----------------
        build_image(SC_SPC3);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        $display("  T10: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd2, "T10 spc = 3 (not power of 2) -> err = 2");

        // ---------------- T11 目录簇链尾提前结束 ----------------
        build_image(SC_CHAINEND);
        do_reset;
        fire_start(9'd9);
        wait_terminal;
        $display("  T11: fail=%b err=%0d", fail, err_code);
        chk(fail && !found,           "T11 chain end before match -> not found");
        chk(err_code == 4'd4,         "T11 err = 4");

        // ---------------- T12 FAT 项非法（簇号 0）----------------
        build_image(SC_FATBAD);
        do_reset;
        fire_start(9'd9);
        wait_terminal;
        $display("  T12: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd3, "T12 FAT[2]=0 invalid cluster -> err = 3");

        // ---------------- T13 底层读块失败 ----------------
        build_image(SC_BASIC);
        do_reset;
        err_inject = 1'b1;              // 让第一次读块就报错
        fire_start(9'd1);
        wait_terminal;
        err_inject = 1'b0;
        $display("  T13: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd5, "T13 block read error -> err = 5");

        // ---------------- T14 序号 0 ----------------
        build_image(SC_BASIC);
        do_reset;
        fire_start(9'd0);
        wait_terminal;
        $display("  T14: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd6, "T14 img_index = 0 -> err = 6");

        // ---------------- T15 分区起始 LBA = 0 ----------------
        build_image(SC_PART0);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        $display("  T15: fail=%b err=%0d", fail, err_code);
        chk(fail && err_code == 4'd2, "T15 partition LBA = 0 -> err = 2");

        // ---------------- T16 首簇高 16 位非零 ----------------
        // 对应变异 m10（命中后不回填 hit_clu_hi[15:8]）——基础镜像首簇
        // 都 < 65536，高 16 位恒 0，该变异无法被察觉，必须专门造一个大簇号
        build_image(SC_HICLU);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        $display("  T16: found=%b err=%0d clu=%0d(0x%08x) size=%0d",
                 found, err_code, first_cluster, first_cluster, file_size);
        chk(found,                          "T16 large cluster number found");
        chk(first_cluster == 32'h0101_0005,"T16 first cluster = 0x01010005 (16842757)");
        chk(file_size     == 32'd921654,    "T16 file size correct");

        // ---------------- T17 FAT 项落在保留区（0x0FFFFFF0~0x0FFFFFF7）----
        // 对应 RTL 修正：该区间既不是有效簇号（上界 0x0FFFFFEF）也不是 EOC
        // （下沿 0x0FFFFFF8）。若不做上界拦截，会被当成有效簇号，
        // 算出的 data_begin + (N-2)*spc 是一个天文 LBA，读块必然越界。
        build_image(SC_RSV);
        do_reset;
        fire_start(9'd9);
        wait_terminal;
        $display("  T17: fail=%b err=%0d", fail, err_code);
        chk(fail && !found,           "T17 reserved-range FAT entry rejected");
        chk(err_code == 4'd3,         "T17 err = 3 (chain error)");

        // ---------------- T18 FAT32 directly at card LBA 0 ----------------
        // Real card layout: no partition table, VBR occupies sector 0.
        build_image(SC_BASIC);
        for (i = 0; i < 6*512; i = i + 1) disk[i] = disk[4*512+i];
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        chk(found && !fail, "T18 unpartitioned FAT32 volume finds IMG001.BMP");
        chk(first_cluster == 32'd5 && file_size == 32'd921654,
            "T18 file metadata preserved");
        chk(out_fat_begin == 32'd1 && out_data_begin == 32'd3 && out_spc == 8'd1,
            "T18 unpartitioned FAT/data addresses use volume base zero");

        // ---------------- T19 VBR boot code is not a partition table ----------------
        build_image(SC_BASIC);
        for (i = 0; i < 6*512; i = i + 1) disk[i] = disk[4*512+i];
        wr32(16'd0, 9'd454, 32'h12345678);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        chk(found && !fail, "T19 VBR boot code at MBR offsets does not redirect reads");
        chk(out_fat_begin == 32'd1 && out_data_begin == 32'd3,
            "T19 boot code does not become the volume base");

        // ---------------- T20/T21 require a FAT32 BPB before accepting LBA 0 ----------------
        build_image(SC_BASIC);
        for (i = 0; i < 6*512; i = i + 1) disk[i] = disk[4*512+i];
        wr16(16'd0, 9'd11, 16'd1024);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        chk(fail && err_code == 4'd2, "T20 non-512-byte direct volume rejected");

        build_image(SC_BASIC);
        for (i = 0; i < 6*512; i = i + 1) disk[i] = disk[4*512+i];
        wr16(16'd0, 9'd17, 16'd512);
        do_reset;
        fire_start(9'd1);
        wait_terminal;
        chk(fail && err_code == 4'd2, "T21 FAT16-style root directory is not FAT32");

        // ---------------- 收尾 ----------------
        $display("");
        // 越界访问是硬错误: 任何一次超出镜像范围的读块都说明 RTL 把非法
        // 簇号当成了有效簇号，即便最终错误码",恰好"相同也必须判失败
        chk(oob_hits == 0, "no out-of-range LBA access during whole test");
        if (errors == 0) $display("ALL CHECKS PASSED: fat32_reader");
        else             $display("CHECKS FAILED: %0d error(s)", errors);
        $display("=== tb_fat32_reader done, errors = %0d ===", errors);
        $finish;
    end

endmodule
