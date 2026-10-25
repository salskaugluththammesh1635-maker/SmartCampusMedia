// ============================================================================
// tb_gallery_probe.v —— gallery_probe 图库自动扫描器 行为级验证
// ----------------------------------------------------------------------------
// 验证对象: rtl/storage/gallery_probe.v
// 验证方式: 纯行为仿真。用「扇区读取模型」顶替 sd_spi_ctrl:
//             blk_start/blk_addr → data_valid/data_byte ×512 → blk_done
//           镜像存在 disk[] 字节数组里，由 build_gallery() 按场景重建，
//           不依赖外部文件、不依赖真卡。
//
// 为什么必须单独验证这个模块:
//   它是"换卡不改 bit 流"这件事的全部依据。如果它数错张数，上层
//   player_ctrl 的索引就会越过真实素材数 —— 表现为按"下一张"落到空文件、
//   屏幕卡在上一帧、错误码锁死。这类故障在板子上看起来像"SD 卡坏了"，
//   实际是枚举逻辑错了，所以每一个边界都必须在这里钉死。
//
// 覆盖场景:
//   W01  正常 3 张连续        → count=3, done=1, fail=0, first_img_req 恰好 1 拍
//   W02  卡里一张都没有       → count=0, done=1, fail=0, 不发 first_img_req
//        （0 是合法结果，不是失败 —— 上层据此显示"无素材"而不是"卡坏了"）
//   W03  有 5 张但上限是 4    → count=4，到上限即停，不数第 5 张
//        （MAX_COUNT 取 4 而非 31，才能在 16 扇区镜像里验证"到上限即停"）
//   W04  连续区间中间缺一张   → count=1（IMG001 有、IMG002 无 → 立即截断，
//        不会把后面的 IMG003 当成第 2 张）
//   W05  底层读块失败         → fail=1, err_code=5（不是静默当成"没有图"）
//   W06  扫描完成后 sd_ok 一直为高 → count 不变、first_img_req 不重复触发
//        （避免每拍都是新请求，导致 img_loader 被反复重载）
//   W07  复位后重新扫描       → 结果与首次一致（状态被彻底清干净）
//
// 通过判据: 末尾打印 `ALL CHECKS PASSED: gallery_probe`（回归脚本按此精确匹配）
// ============================================================================
`timescale 1ns / 1ps

module tb_gallery_probe;

    // ------------------------------------------------------------------
    // 时钟与复位
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    always #20 clk = ~clk;          // 40ns 周期 = 25MHz（与整板 clk_pixel 一致）

    reg rst_n = 1'b0;

    // ------------------------------------------------------------------
    // 统计量
    // ------------------------------------------------------------------
    integer errors     = 0;   // 失败计数
    integer oob_hits   = 0;   // 越界 LBA 访问次数（必须为 0）
    integer firq_pulses = 0;  // first_img_req 累计拉高拍数（只增不减）
    integer firq_base   = 0;  // 本轮扫描开始前的基线，用于算"本轮脉冲数"

    // ------------------------------------------------------------------
    // 被测模块接口
    // ------------------------------------------------------------------
    reg         sd_ok       = 1'b0;  // 由 TB 驱动: 上升沿启动扫描
    wire        gp_blk_start;
    wire [31:0] gp_blk_addr;
    reg         gp_blk_done  = 1'b0; // 由卡模型驱动
    reg         gp_blk_err   = 1'b0;
    reg  [7:0]  gp_data_byte = 8'h00;
    reg         gp_data_valid= 1'b0;
    wire        gp_done;
    wire        gp_fail;
    wire [4:0]  gp_count;
    wire        gp_first_req;
    wire [3:0]  gp_err;

    gallery_probe #(
        .CLK_FREQ_HZ (25_000_000),
        .MAX_COUNT   (5'd4)          // 上限 4: 小镜像里就能验证"到上限即停"
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .sd_ok         (sd_ok),
        .blk_start     (gp_blk_start),
        .blk_addr      (gp_blk_addr),
        .blk_done      (gp_blk_done),
        .blk_err       (gp_blk_err),
        .data_byte     (gp_data_byte),
        .data_valid    (gp_data_valid),
        .done          (gp_done),
        .fail          (gp_fail),
        .count         (gp_count),
        .first_img_req (gp_first_req),
        .err_code      (gp_err)
    );

    // first_img_req 脉冲计数: 必须是"每完成一次扫描恰好 1 拍"，
    // 既不能一个都没有（首图永远不会被装载），也不能每拍都来（反复重载）
    always @(posedge clk) begin
        if (rst_n && gp_first_req) firq_pulses = firq_pulses + 1;
    end

    // ------------------------------------------------------------------
    // 检查工具
    // ------------------------------------------------------------------
    task chk;
        input cond;
        input [511:0] name;
        begin
            if (cond) $display("PASS: %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // SD 卡镜像: 16 扇区 × 512 字节
    //   布局与 tb_fat32_reader 完全一致（同一套 BPB 数值、同一套目录项编码），
    //   这样两个 TB 对 fat32_reader 的假设是同一份，不会各自漂移。
    // ------------------------------------------------------------------
    localparam NSEC = 16;
    reg [7:0] disk [0:NSEC*512-1];

    localparam [31:0] PART_LBA = 32'd4;
    localparam [31:0] L_MBR = 32'd0,  // 分区表扇区
                      L_VBR = 32'd4,  // 卷引导扇区（= PART_LBA）
                      L_FAT1= 32'd5,  // 第一份 FAT
                      L_FAT2= 32'd6,  // 第二份 FAT
                      L_DIR0= 32'd7;  // 根目录首扇区（簇 2，每簇 1 扇区）

    // —— 卡模型状态 ——
    reg        card_active = 1'b0;
    reg [31:0] card_lba    = 32'd0;
    reg [9:0]  card_cnt    = 10'd0;
    reg        card_fail   = 1'b0;
    reg        err_inject  = 1'b0;  // TB 置 1 让下一次读块失败

    // 扇区读取模型: 收到 blk_start 后逐字节吐出 512 字节，再给 blk_done。
    // 注意 data_byte/data_valid 是**寄存输出**（比 blk_addr 晚一拍生效），
    // fat32_reader 的 S_EVAL 隔一拍判定正是为此。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            card_active  <= 1'b0;
            card_lba     <= 32'd0;
            card_cnt     <= 10'd0;
            card_fail    <= 1'b0;
            gp_data_byte <= 8'h00;
            gp_data_valid<= 1'b0;
            gp_blk_done  <= 1'b0;
            gp_blk_err   <= 1'b0;
        end else begin
            gp_blk_done <= 1'b0;
            gp_blk_err  <= 1'b0;
            if (gp_blk_start && !card_active) begin
                card_active <= 1'b1;
                card_lba    <= gp_blk_addr;
                card_cnt    <= 10'd0;
                card_fail   <= err_inject;
                if (gp_blk_addr >= NSEC) begin
                    $display("FAIL: out-of-range LBA access: addr=%0d (image has %0d sectors)",
                             gp_blk_addr, NSEC);
                    oob_hits = oob_hits + 1;
                end
            end else if (card_active) begin
                if (card_fail) begin
                    gp_data_valid <= 1'b0;
                    gp_blk_err    <= 1'b1;
                    card_active   <= 1'b0;
                end else if (card_cnt < 10'd512) begin
                    gp_data_byte  <= disk[card_lba*512 + card_cnt];
                    gp_data_valid <= 1'b1;
                    card_cnt      <= card_cnt + 10'd1;
                end else begin
                    gp_data_valid <= 1'b0;
                    gp_blk_done   <= 1'b1;
                    card_active   <= 1'b0;
                end
            end else begin
                gp_data_valid <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 镜像写入工具（小端）
    // ------------------------------------------------------------------
    task wr8;
        input [15:0] sec;
        input [8:0]  off;
        input [7:0]  val;
        begin disk[sec*512 + off] = val; end
    endtask

    task wr16;
        input [15:0] sec;
        input [8:0]  off;
        input [15:0] val;
        begin
            disk[sec*512 + off]   = val[7:0];
            disk[sec*512 + off+1] = val[15:8];
        end
    endtask

    task wr32;
        input [15:0] sec;
        input [8:0]  off;
        input [31:0] val;
        begin
            disk[sec*512 + off]   = val[7:0];
            disk[sec*512 + off+1] = val[15:8];
            disk[sec*512 + off+2] = val[23:16];
            disk[sec*512 + off+3] = val[31:24];
        end
    endtask

    // 8.3 短名目录项: "IMGnnn  .BMP"（实际编码为 IMGnnn␣␣BMP，11 字节无点）
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
        begin
            base = sec*512 + ent*32;
            h = num / 100;
            t = (num % 100) / 10;
            o = num % 10;
            disk[base+0] = lower ? 8'h69 : 8'h49;   // 'I' / 'i'
            disk[base+1] = lower ? 8'h6D : 8'h4D;   // 'M' / 'm'
            disk[base+2] = lower ? 8'h67 : 8'h47;   // 'G' / 'g'
            disk[base+3] = 8'h30 + h[7:0];
            disk[base+4] = 8'h30 + t[7:0];
            disk[base+5] = 8'h30 + o[7:0];
            disk[base+6] = 8'h20;
            disk[base+7] = 8'h20;
            disk[base+8] = lower ? 8'h62 : 8'h42;   // 'B' / 'b'
            disk[base+9] = lower ? 8'h6D : 8'h4D;   // 'M' / 'm'
            disk[base+10]= lower ? 8'h70 : 8'h50;   // 'P' / 'p'
            disk[base+11]= attr;
            disk[base+12]= 8'h00;
            disk[base+13]= 8'h00;
            disk[base+14]= 8'h00;      // 创建时间
            disk[base+15]= 8'h00;
            disk[base+16]= 8'h00;      // 创建日期
            disk[base+17]= 8'h00;
            disk[base+18]= 8'h00;      // 最后访问日期
            disk[base+19]= 8'h00;
            disk[base+20]= clu[23:16]; // 首簇高 16 位
            disk[base+21]= clu[31:24];
            disk[base+22]= 8'h00;      // 修改时间
            disk[base+23]= 8'h00;
            disk[base+24]= 8'h00;      // 修改日期
            disk[base+25]= 8'h00;
            disk[base+26]= clu[7:0];   // 首簇低 16 位
            disk[base+27]= clu[15:8];
            disk[base+28]= sz[7:0];
            disk[base+29]= sz[15:8];
            disk[base+30]= sz[23:16];
            disk[base+31]= sz[31:24];
        end
    endtask

    // 其它目录项（LFN / 卷标 / 结束标记）: 首字节与属性可指定，其余清零
    task mkother;
        input [15:0] sec;
        input [3:0]  ent;
        input [7:0]  b0;
        input [7:0]  attr;
        integer base;
        integer k;
        begin
            base = sec*512 + ent*32;
            for (k = 0; k < 32; k = k + 1) disk[base+k] = 8'h00;
            disk[base+0]  = b0;
            disk[base+11] = attr;
        end
    endtask

    // ------------------------------------------------------------------
    // 按场景重建镜像: 造 n 张连续 IMG001..IMG00n，skip 指定要"故意缺席"的序号
    //   skip=0 表示不缺；skip=k 表示第 k 个名字不写（模拟素材编号断档）
    // ------------------------------------------------------------------
    integer i;
    integer kk;
    integer ent;

    task build_gallery;
        input [8:0] n;
        input [8:0] skip;
        begin
            // 全场清零: 每次重建都从干净镜像开始，避免上个场景的残留目录项
            for (i = 0; i < NSEC*512; i = i + 1) disk[i] = 8'h00;

            // —— MBR（分区表）——
            wr8 (L_MBR, 9'd446, 8'h80);          // 活动标志
            wr8 (L_MBR, 9'd450, 8'h0C);          // 类型: FAT32 LBA
            wr32(L_MBR, 9'd454, PART_LBA);       // 分区起始 LBA
            wr32(L_MBR, 9'd458, 32'd8192);       // 分区扇区数
            wr16(L_MBR, 9'd510, 16'hAA55);       // 签名

            // —— VBR（BPB）——
            wr16(L_VBR, 9'd11, 16'd512);         // 每扇区字节数
            wr8 (L_VBR, 9'd13, 8'd1);            // 每簇扇区数 = 1
            wr16(L_VBR, 9'd14, 16'd1);           // 保留扇区数
            wr8 (L_VBR, 9'd16, 8'd2);            // FAT 份数
            wr32(L_VBR, 9'd36, 32'd1);           // 每份 FAT 扇区数
            wr32(L_VBR, 9'd44, 32'd2);           // 根目录簇号 = 2
            wr16(L_VBR, 9'd510, 16'hAA55);       // 签名

            // —— FAT: 簇 2（根目录）标为链尾 ——
            wr32(L_FAT1, 9'd8, 32'h0FFF_FFF8);
            wr32(L_FAT2, 9'd8, 32'h0FFF_FFF8);

            // —— 根目录: 项 0 = 长文件名，项 1 = 卷标（都必须被跳过）——
            mkother(L_DIR0, 4'd0, 8'h41, 8'h0F); // LFN 项（属性 0x0F）
            mkother(L_DIR0, 4'd1, 8'h42, 8'h08); // 卷标（属性 0x08）

            // —— 文件项从项 2 开始，编号连续（skip 处留空）——
            ent = 2;
            for (kk = 1; kk <= n; kk = kk + 1) begin
                if (kk != skip) begin
                    mkfile(L_DIR0, ent[3:0], kk[8:0], 8'h20,
                           32'd5 + kk, 32'd921654, (kk == 2));
                    ent = ent + 1;
                end
            end

            // —— 目录结束标记（0x00）: 让"未找到"走 dir_end → err=4 路径 ——
            mkother(L_DIR0, ent[3:0], 8'h00, 8'h00);
        end
    endtask

    // ------------------------------------------------------------------
    // 驱动
    // ------------------------------------------------------------------
    // 复位 DUT，同时把 sd_ok 拉回 0 —— 下次 start_scan 才能产生干净的上升沿
    task do_reset;
        begin
            rst_n = 1'b0;
            sd_ok = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    // 拉起 sd_ok: 下一拍的上边沿触发 G_IDLE → G_ARST
    task start_scan;
        begin
            @(negedge clk);
            sd_ok = 1'b1;
        end
    endtask

    // 等扫描进入终态（done 或 fail）。超时即报错，避免回归"假通过"
    task wait_scan_done;
        integer guard;
        begin
            guard = 0;
            while (!gp_done && !gp_fail && guard < 200000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (guard >= 200000) $display("TIMEOUT: scan terminal state not reached");
        end
    endtask

    // ==================================================================
    // 主测试序列
    // ==================================================================
    initial begin
        $display("=== tb_gallery_probe start ===");

        // ---------------- W01 正常 3 张连续 ----------------
        $display("");
        $display("--- W01: three consecutive images ---");
        build_gallery(9'd3, 9'd0);
        do_reset;
        firq_base = firq_pulses;   // 记基线: 本轮脉冲数 = firq_pulses - firq_base
        // sd_ok 为 0 时不得启动: 确认扫描只由上升沿触发
        repeat (20) @(negedge clk);
        chk(!gp_done && !gp_fail, "W01 no scan before sd_ok rises");
        start_scan;
        wait_scan_done;
        $display("  W01: done=%b fail=%b count=%0d err=%0d pulses=%0d",
                 gp_done, gp_fail, gp_count, gp_err, firq_pulses - firq_base);
        chk(gp_done && !gp_fail,              "W01 scan completed without failure");
        chk(gp_count == 5'd3,                 "W01 count = 3 consecutive images");
        chk(gp_err == 4'd0,                   "W01 no error code");
        chk((firq_pulses - firq_base) == 1,   "W01 first_img_req asserted exactly once");
        // 扫描结束后卡模型必须回到空闲: 若 card_active 仍为 1，说明 RTL 在
        // 最后一次读数后没有正常收尾，真卡上会表现为"下一次读块被残留状态挡住"
        repeat (4) @(negedge clk);
        chk(!card_active,                     "W01 card model idle after scan");

        // ---------------- W02 一张都没有 ----------------
        $display("");
        $display("--- W02: empty gallery ---");
        build_gallery(9'd0, 9'd0);
        do_reset;
        firq_base = firq_pulses;   // 记基线: 本轮脉冲数 = firq_pulses - firq_base
        start_scan;
        wait_scan_done;
        $display("  W02: done=%b fail=%b count=%0d err=%0d pulses=%0d",
                 gp_done, gp_fail, gp_count, gp_err, firq_pulses - firq_base);
        chk(gp_done && !gp_fail, "W02 empty gallery is success, not failure");
        chk(gp_count == 5'd0,    "W02 count = 0");
        chk((firq_pulses - firq_base) == 0,    "W02 no first_img_req when gallery is empty");

        // ---------------- W03 到上限即停 ----------------
        $display("");
        $display("--- W03: five images, MAX_COUNT = 4 ---");
        build_gallery(9'd5, 9'd0);
        do_reset;
        firq_base = firq_pulses;   // 记基线: 本轮脉冲数 = firq_pulses - firq_base
        start_scan;
        wait_scan_done;
        $display("  W03: done=%b count=%0d pulses=%0d", gp_done, gp_count, firq_pulses - firq_base);
        chk(gp_done && !gp_fail, "W03 stopped cleanly at the upper limit");
        chk(gp_count == 5'd4,    "W03 count clamped to MAX_COUNT = 4");
        chk((firq_pulses - firq_base) == 1,    "W03 first_img_req asserted once at limit");

        // ---------------- W04 连续区间中间缺一张 ----------------
        $display("");
        $display("--- W04: gap in numbering (IMG002 missing) ---");
        build_gallery(9'd3, 9'd2);
        do_reset;
        firq_base = firq_pulses;   // 记基线: 本轮脉冲数 = firq_pulses - firq_base
        start_scan;
        wait_scan_done;
        $display("  W04: done=%b count=%0d pulses=%0d", gp_done, gp_count, firq_pulses - firq_base);
        chk(gp_done && !gp_fail, "W04 gap ends the scan cleanly");
        chk(gp_count == 5'd1,    "W04 count truncated to 1 by the missing IMG002");
        chk((firq_pulses - firq_base) == 1,    "W04 first_img_req still asserted once");

        // ---------------- W05 底层读块失败 ----------------
        $display("");
        $display("--- W05: card read error ---");
        build_gallery(9'd3, 9'd0);
        do_reset;
        firq_base = firq_pulses;   // 记基线: 本轮脉冲数 = firq_pulses - firq_base
        err_inject = 1'b1;
        start_scan;
        wait_scan_done;
        err_inject = 1'b0;
        $display("  W05: done=%b fail=%b err=%0d pulses=%0d",
                 gp_done, gp_fail, gp_err, firq_pulses - firq_base);
        chk(gp_fail && !gp_done,  "W05 read error fails the scan");
        chk(gp_err == 4'd5,       "W05 err_code = 5 (block read failure)");
        chk((firq_pulses - firq_base) == 0,     "W05 no first_img_req after a failure");

        // ---------------- W06 完成后 sd_ok 持续为高，不得重扫 ----------------
        $display("");
        $display("--- W06: sd_ok stays high after completion ---");
        build_gallery(9'd3, 9'd0);
        do_reset;
        firq_base = firq_pulses;   // 记基线: 本轮脉冲数 = firq_pulses - firq_base
        start_scan;
        wait_scan_done;
        repeat (400) @(negedge clk);          // 远长于一轮完整扫描
        $display("  W06: count=%0d pulses=%0d", gp_count, firq_pulses - firq_base);
        chk(gp_count == 5'd3,     "W06 count stable while sd_ok stays high");
        chk((firq_pulses - firq_base) == 1,     "W06 first_img_req does not re-assert");

        // ---------------- W07 复位后重扫，结果一致 ----------------
        $display("");
        $display("--- W07: rescan after reset ---");
        do_reset;
        firq_base = firq_pulses;   // 记基线: 本轮脉冲数 = firq_pulses - firq_base
        start_scan;
        wait_scan_done;
        $display("  W07: done=%b count=%0d pulses=%0d", gp_done, gp_count, firq_pulses - firq_base);
        chk(gp_done && !gp_fail, "W07 second scan completes");
        chk(gp_count == 5'd3,    "W07 rescan reproduces count = 3");

        // ---------------- 收尾 ----------------
        $display("");
        // 越界访问是硬错误: 说明枚举过程把非法 LBA 送到了卡上
        chk(oob_hits == 0, "no out-of-range LBA access during whole test");
        if (errors == 0) $display("ALL CHECKS PASSED: gallery_probe");
        else             $display("CHECKS FAILED: %0d error(s)", errors);
        $display("=== tb_gallery_probe done, errors = %0d ===", errors);
        $finish;
    end

endmodule
