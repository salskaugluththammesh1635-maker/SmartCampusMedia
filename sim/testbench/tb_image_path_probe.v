// =============================================================================
// tb_image_path_probe.v —— image_path_probe 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块是干什么的】
//   rtl/storage/image_path_probe.v 是一块**只观察、不干预**的白屏诊断探针。
//   它挂在图像链的四个观测点上，各自用 4 bit 粘滞（sticky）标志累积"见到过
//   什么"，最后拼成 16 bit 的 stages 输出，供上层读出判断图像卡在哪一级：
//
//     stages[15:12] = decode_seen   BMP 解码输出（pix 域）
//     stages[11:8]  = write_seen    SDRAM 写入（sdr 域，跨域同步后）
//     stages[7:4]   = read_seen     SDRAM 读回（sdr 域，跨域同步后）
//     stages[3:0]   = pixel_seen    像素输出（pix 域）
//
//   每个 nibble 的位含义由 function pixel_flags 定义：
//     bit0 = 1            见到过数据（恒置位）
//     bit1 = (v == F800)  见到过 RGB565 红色
//     bit2 = (v != FFFF)  见到过"非白"像素
//     bit3 = 0            保留
//
// 【本 TB 要验的六件事】
//   ① 复位全清；② 四个观测点各自独立记账；③ 粘滞性（脉冲过后不复位就一直
//   保持）；④ pixel_flags 的三种典型值（白 / 红 / 其它非白）；⑤ 32 bit 通道
//   的高低半字都要被检查；⑥ **两个时钟域互不干扰**——sdr 域复位不能清 pix
//   域的记录，pix 域复位也不能清 sdr 域的记录，且跨域只需两级同步延迟。
//
// 【为什么要专门测"跨域互不干扰"】
//   本模块的价值全在"出问题时还能读出历史"。若某个域的复位顺手把另一个域
//   的记录也清了，现场证据就丢了——这是诊断类模块最典型也最致命的缺陷。
// =============================================================================
`timescale 1ns / 1ps

module tb_image_path_probe;

    // ---- 双时钟 ------------------------------------------------------------
    //   pix 25MHz(40ns) / sdr 50MHz(20ns)，与真实系统里 pixel 域慢于 sdr 域一致。
    reg pix_clk;
    reg sdr_clk;
    initial pix_clk = 1'b0;
    always #20 pix_clk = ~pix_clk;
    initial sdr_clk = 1'b0;
    always #10 sdr_clk = ~sdr_clk;

    // ---- DUT 端口 ----------------------------------------------------------
    reg         rst_n_pix;
    reg         rst_n_sdr;
    reg         decode_valid;
    reg  [15:0] decode_pixel;
    reg         write_valid;
    reg  [31:0] write_data;
    reg         read_valid;
    reg  [31:0] read_data;
    reg         pixel_valid;
    reg  [15:0] pixel_data;
    wire [15:0] stages;

    image_path_probe u_dut (
        .pix_clk     (pix_clk),
        .rst_n_pix   (rst_n_pix),
        .sdr_clk     (sdr_clk),
        .rst_n_sdr   (rst_n_sdr),
        .decode_valid(decode_valid),
        .decode_pixel(decode_pixel),
        .write_valid (write_valid),
        .write_data  (write_data),
        .read_valid  (read_valid),
        .read_data   (read_data),
        .pixel_valid (pixel_valid),
        .pixel_data  (pixel_data),
        .stages      (stages)
    );

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    task ck(input integer cond, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    task ck_nib(input [3:0] got, input [3:0] exp, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s  (0x%01h)", label, got);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s  (got 0x%01h, expected 0x%01h)", label, got, exp);
            end
        end
    endtask

    // ---- 各 nibble 的取位（与 DUT 的 {decode, memory_sync, pixel} 拼法一致）--
    wire [3:0] n_decode = stages[15:12];
    wire [3:0] n_write  = stages[11:8];
    wire [3:0] n_read   = stages[7:4];
    wire [3:0] n_pixel  = stages[3:0];

    // ---- 期望的 pixel_flags（TB 侧独立复现，不抄 DUT 的实现）----------------
    function [3:0] flags_of;
        input [15:0] v;
        begin
            flags_of[3] = 1'b0;
            flags_of[2] = (v != 16'hFFFF);   // 非白
            flags_of[1] = (v == 16'hF800);   // RGB565 红
            flags_of[0] = 1'b1;              // 见到过数据
        end
    endfunction

    // ---- 送一次 pix 域激励（decode 或 pixel 由调用方选）-------------------
    task pulse_decode(input [15:0] v);
        begin
            @(negedge pix_clk);
            decode_pixel = v;
            decode_valid = 1'b1;
            @(negedge pix_clk);
            decode_valid = 1'b0;
        end
    endtask

    task pulse_pixel(input [15:0] v);
        begin
            @(negedge pix_clk);
            pixel_data  = v;
            pixel_valid = 1'b1;
            @(negedge pix_clk);
            pixel_valid = 1'b0;
        end
    endtask

    // 送一次 sdr 域写/读激励。注意 DUT 是"先寄存再判"，所以有效数据在
    // valid 之后的下一拍才被记账。
    task pulse_write(input [31:0] d);
        begin
            @(negedge sdr_clk);
            write_data  = d;
            write_valid = 1'b1;
            @(negedge sdr_clk);
            write_valid = 1'b0;
        end
    endtask

    task pulse_read(input [31:0] d);
        begin
            @(negedge sdr_clk);
            read_data  = d;
            read_valid = 1'b1;
            @(negedge sdr_clk);
            read_valid = 1'b0;
        end
    endtask

    // 等两级 pix 同步完成（memory_meta -> memory_sync 需要 2 个 pix 沿）
    task sync_mem;
        begin
            repeat (3) @(posedge pix_clk);
            #1;
        end
    endtask

    task do_reset;
        begin
            @(negedge pix_clk);
            rst_n_pix = 1'b0;
            rst_n_sdr = 1'b0;
            decode_valid = 1'b0;
            pixel_valid  = 1'b0;
            write_valid  = 1'b0;
            read_valid   = 1'b0;
            decode_pixel = 16'hFFFF;
            pixel_data   = 16'hFFFF;
            write_data   = 32'hFFFF_FFFF;
            read_data    = 32'hFFFF_FFFF;
            repeat (4) @(posedge pix_clk);
            repeat (4) @(posedge sdr_clk);
            @(negedge pix_clk);
            rst_n_pix = 1'b1;
            @(negedge pix_clk);
            rst_n_sdr = 1'b1;
            repeat (3) @(posedge pix_clk);
            #1;
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    reg [3:0] d_exp;
    reg [3:0] w_exp;
    reg [3:0] r_exp;
    reg [3:0] p_exp;

    initial begin
        $display("=== tb_image_path_probe start ===");
        rst_n_pix    = 1'b0;
        rst_n_sdr    = 1'b0;
        decode_valid = 1'b0;
        decode_pixel = 16'hFFFF;
        write_valid  = 1'b0;
        write_data   = 32'hFFFF_FFFF;
        read_valid   = 1'b0;
        read_data    = 32'hFFFF_FFFF;
        pixel_valid  = 1'b0;
        pixel_data   = 16'hFFFF;

        // =====================================================================
        // ① 复位值：四个 nibble 全 0
        // =====================================================================
        repeat (5) @(posedge pix_clk);
        repeat (5) @(posedge sdr_clk);
        #1;
        ck_nib(stages, 16'h0000,            "[reset] all four nibbles cleared");
        ck_nib(n_decode, 4'h0,              "[reset] decode nibble is 0");
        ck_nib(n_write,  4'h0,              "[reset] write nibble is 0");
        ck_nib(n_read,   4'h0,              "[reset] read nibble is 0");
        ck_nib(n_pixel,  4'h0,              "[reset] pixel nibble is 0");

        @(negedge pix_clk);
        rst_n_pix = 1'b1;
        @(negedge pix_clk);
        rst_n_sdr = 1'b1;
        repeat (3) @(posedge pix_clk);

        // =====================================================================
        // ② pixel_flags 的三种典型值（这是整个模块的语义基石）
        //    白 FFFF   → 0001（有数据、不红、算"白"）
        //    红 F800   → 0111（有数据、红、非白）
        //    黑 0000   → 0101（有数据、不红、非白）
        //    用独立的 decode 通道逐次验证，每次都复位重建
        // =====================================================================
        do_reset;
        pulse_decode(16'hFFFF);
        repeat (2) @(posedge pix_clk);
        #1;
        ck_nib(n_decode, flags_of(16'hFFFF), "[flags] white FFFF -> 0x1 (data only)");

        do_reset;
        pulse_decode(16'hF800);
        repeat (2) @(posedge pix_clk);
        #1;
        ck_nib(n_decode, flags_of(16'hF800), "[flags] red F800 -> 0x7 (data+red+nonwhite)");

        do_reset;
        pulse_decode(16'h0000);
        repeat (2) @(posedge pix_clk);
        #1;
        ck_nib(n_decode, flags_of(16'h0000), "[flags] black 0000 -> 0x5 (data+nonwhite)");

        // 红线：F800 必须同时置 bit1 与 bit2（不能只置一个）
        do_reset;
        pulse_decode(16'hF800);
        repeat (2) @(posedge pix_clk);
        #1;
        ck(n_decode[1] === 1'b1,            "[flags] red sets bit1");
        ck(n_decode[2] === 1'b1,            "[flags] red also sets bit2 (nonwhite)");
        ck(n_decode[3] === 1'b0,            "[flags] bit3 is reserved and stays 0");

        // 反例：白色不得置 bit2（否则"非白"判据永远为真、诊断失去意义）
        do_reset;
        pulse_decode(16'hFFFF);
        repeat (2) @(posedge pix_clk);
        #1;
        ck(n_decode[2] === 1'b0,            "[flags] white does NOT set the nonwhite bit");

        // =====================================================================
        // ③ 粘滞性：一次脉冲后长期保持
        // =====================================================================
        do_reset;
        pulse_decode(16'h0000);
        repeat (200) @(posedge pix_clk);
        #1;
        ck_nib(n_decode, 4'h5,              "[sticky] decode flags survive 200 cycles");

        do_reset;
        pulse_pixel(16'hF800);
        repeat (200) @(posedge pix_clk);
        #1;
        ck_nib(n_pixel, 4'h7,               "[sticky] pixel flags survive 200 cycles");

        // 多个不同像素 → 标志按位或累积，不是被最后一个覆盖
        do_reset;
        pulse_pixel(16'hFFFF);              // 0001
        repeat (2) @(posedge pix_clk);
        pulse_pixel(16'hF800);              // 0111
        repeat (2) @(posedge pix_clk);
        pulse_pixel(16'h1234);              // 0101
        repeat (2) @(posedge pix_clk);
        #1;
        ck_nib(n_pixel, 4'h7,               "[sticky] flags OR together across pixels");
        ck(n_pixel[0] === 1'b1 && n_pixel[1] === 1'b1 && n_pixel[2] === 1'b1,
                                            "[sticky] all three seen-bits latched");

        // =====================================================================
        // ④ 32 bit 通道的高低半字都要检查（write_data[15:0] 与 [31:16]）
        // =====================================================================
        do_reset;
        pulse_write(32'hFFFF_F800);         // 低半字是红
        sync_mem;
        ck_nib(n_write, 4'h7,               "[write] low half-word F800 sets red+nonwhite");

        do_reset;
        pulse_write(32'hF800_FFFF);         // 高半字是红
        sync_mem;
        ck_nib(n_write, 4'h7,               "[write] high half-word F800 also inspected");

        do_reset;
        pulse_write(32'hFFFF_FFFF);         // 全白
        sync_mem;
        ck_nib(n_write, 4'h1,               "[write] all-white data only sets the seen bit");

        do_reset;
        pulse_read(32'h0000_F800);          // 低半字红，高半字黑
        sync_mem;
        ck_nib(n_read, 4'h7,                "[read] read channel flags both red and nonwhite");

        // 写与读是两个独立 nibble，不能串味
        do_reset;
        pulse_write(32'hF800_F800);
        sync_mem;
        ck_nib(n_write, 4'h7,               "[write] write channel records red");
        ck_nib(n_read,  4'h0,               "[write] write activity does not touch the read nibble");

        do_reset;
        pulse_read(32'h0000_0000);
        sync_mem;
        ck_nib(n_read,  4'h5,               "[read] read channel records nonwhite");
        ck_nib(n_write, 4'h0,               "[read] read activity does not touch the write nibble");

        // =====================================================================
        // ⑤ 跨域同步延迟：sdr 域的粘滞标志经两级 pix 同步后才可见
        //    这是本模块唯一的时序契约，必须钉死"早一拍看不到"。
        //
        //    两级寄存链：memory_meta <= {write_seen, read_seen}
        //                memory_sync <= memory_meta
        //    同步器本身由 pix_clk 驱动，而 sdr_clk(20ns) 是 pix_clk(40ns) 的两倍快，
        //    所以"写完之后到我们回头看"这段路上 pix 时钟已经跑了几拍，第一级
        //    可能已经完成 → 期望的出现时刻取决于**快照那一刻 memory_meta 的状态**，
        //    不能一律假设"还差两拍"。这里按快照时 memory_meta 的实际值分两种情形
        //    给出确定的期望，既钉死语义、又不受错相位影响。
        // =====================================================================
        begin : cross_domain_latency
            integer cyc0;
            integer seen_at;
            integer exp_at;
            reg [3:0] w_snap;
            reg [7:0] meta_snap;
            @(negedge pix_clk);
            rst_n_sdr = 1'b0;
            repeat (3) @(posedge sdr_clk);
            @(negedge sdr_clk);
            rst_n_sdr = 1'b1;
            repeat (3) @(posedge sdr_clk);

            // 在 sdr 域记一笔红色写入
            pulse_write(32'hF800_F800);
            // 让 sdr 域的 write_seen 先稳定（写路径本身有一拍寄存）
            repeat (3) @(posedge sdr_clk);
            #1;
            ck_nib(u_dut.write_seen, 4'h7,  "[xdomain] write_seen latched in sdr domain");

            // 立刻快照 pix 域：可见部分只可能走到第一级，第二级必未完成
            w_snap    = n_write;
            meta_snap = u_dut.memory_meta;
            ck_nib(w_snap, 4'h0,            "[xdomain] not visible before the two-stage sync completes");

            // 按第一级是否已完成，推导第二级还需几拍
            if (meta_snap[7:4] !== 4'h7) exp_at = 1;   // 第一级待完成 → 共需 2 拍
            else                          exp_at = 0;   // 第一级已完成 → 再 1 拍即可见

            // 逐步走 pix 时钟，记录它第几拍才出现
            seen_at = -1;
            for (cyc0 = 0; cyc0 < 8; cyc0 = cyc0 + 1) begin
                @(posedge pix_clk);
                #1;
                if (n_write !== 4'h0 && seen_at < 0) seen_at = cyc0;
            end
            ck(seen_at === exp_at,
                                            "[xdomain] flag appears exactly after the two-stage sync");
            $display("      cross-domain flag appeared at pix cycle %0d (meta_snap=0x%02h, expected %0d)",
                     seen_at, meta_snap, exp_at);
            ck(seen_at <= 1,                "[xdomain] never takes more than two pix clocks");
            ck_nib(n_write, 4'h7,           "[xdomain] full flags arrive intact after sync");
        end

        // =====================================================================
        // ⑥ 两个时钟域的复位互不干扰（诊断模块最致命的缺陷模式）
        //    rst_n_sdr 只清 write/read；rst_n_pix 只清 decode/pixel + 同步器。
        // =====================================================================
        begin : independent_resets
            // 先在两个域各记一笔
            do_reset;
            pulse_decode(16'h0000);         // pix 域：0101
            pulse_pixel(16'hF800);          // pix 域：0111
            repeat (2) @(posedge pix_clk);
            pulse_write(32'h0000_0000);     // sdr 域：0101
            sync_mem;
            ck_nib(n_decode, 4'h5,          "[iso-reset] decode recorded before reset test");
            ck_nib(n_pixel,  4'h7,          "[iso-reset] pixel recorded before reset test");
            ck_nib(n_write,  4'h5,          "[iso-reset] write recorded before reset test");

            // 只复位 sdr 域
            @(negedge sdr_clk);
            rst_n_sdr = 1'b0;
            repeat (4) @(posedge sdr_clk);
            @(negedge sdr_clk);
            rst_n_sdr = 1'b1;
            repeat (3) @(posedge sdr_clk);
            #1;
            ck_nib(u_dut.write_seen, 4'h0,  "[iso-reset] sdr reset clears write_seen");
            ck_nib(n_decode, 4'h5,          "[iso-reset] sdr reset leaves decode_seen intact");
            ck_nib(n_pixel,  4'h7,          "[iso-reset] sdr reset leaves pixel_seen intact");

            // 同步器把"清零后的 write_seen=0"送过来，write nibble 随之归零
            repeat (4) @(posedge pix_clk);
            #1;
            ck_nib(n_write, 4'h0,           "[iso-reset] cleared write flag propagates to pix domain");

            // 只复位 pix 域
            pulse_write(32'hF800_F800);     // 重新在 sdr 域记一笔
            repeat (3) @(posedge sdr_clk);
            @(negedge pix_clk);
            rst_n_pix = 1'b0;
            repeat (4) @(posedge pix_clk);
            @(negedge pix_clk);
            rst_n_pix = 1'b1;
            repeat (3) @(posedge pix_clk);
            #1;
            ck_nib(n_decode, 4'h0,          "[iso-reset] pix reset clears decode_seen");
            ck_nib(n_pixel,  4'h0,          "[iso-reset] pix reset clears pixel_seen");
            ck_nib(u_dut.write_seen, 4'h7,  "[iso-reset] pix reset leaves write_seen intact");

            // pix 复位也清了同步器，所以 write nibble 暂时读不到；
            // 但 sdr 域的历史仍在，同步会把它重新送过来（这正是"证据不丢"的关键）
            repeat (4) @(posedge pix_clk);
            #1;
            ck_nib(n_write, 4'h7,           "[iso-reset] sdr history re-syncs after pix reset");
        end

        // =====================================================================
        // ⑦ 全通道联合：四个 nibble 同时记账，互不覆盖
        // =====================================================================
        do_reset;
        pulse_decode(16'hF800);
        repeat (2) @(posedge pix_clk);
        pulse_write(32'h0000_0000);
        repeat (2) @(posedge sdr_clk);
        pulse_read(32'hFFFF_FFFF);
        repeat (2) @(posedge sdr_clk);
        pulse_pixel(16'h1234);
        sync_mem;
        repeat (2) @(posedge pix_clk);
        #1;
        ck_nib(n_decode, 4'h7,              "[all] decode nibble correct in joint test");
        ck_nib(n_write,  4'h5,              "[all] write nibble correct in joint test");
        ck_nib(n_read,   4'h1,              "[all] read nibble correct in joint test");
        ck_nib(n_pixel,  4'h5,              "[all] pixel nibble correct in joint test");
        ck_nib(stages, {4'h7, 4'h5, 4'h1, 4'h5},
                                            "[all] stages assembles as {decode,write,read,pixel}");

        // 逐 nibble 独立核对一遍（防止拼位顺序写反）
        ck(stages[15:12] === n_decode,      "[all] stages[15:12] is decode_seen");
        ck(stages[11:8]  === n_write,       "[all] stages[11:8] is write_seen");
        ck(stages[7:4]   === n_read,        "[all] stages[7:4] is read_seen");
        ck(stages[3:0]   === n_pixel,       "[all] stages[3:0] is pixel_seen");

        // =====================================================================
        // ⑧ 运行中复位：立刻回到全 0
        // =====================================================================
        @(negedge pix_clk);
        rst_n_pix = 1'b0;
        @(negedge pix_clk);
        rst_n_sdr = 1'b0;
        repeat (4) @(posedge pix_clk);
        repeat (4) @(posedge sdr_clk);
        #1;
        ck_nib(stages, 16'h0000,            "[mid-reset] stages cleared while in reset");
        // 复位期间来的脉冲不得记账
        @(negedge pix_clk);
        decode_valid = 1'b1;
        decode_pixel = 16'hF800;
        pixel_valid  = 1'b1;
        pixel_data   = 16'h0000;
        repeat (4) @(posedge pix_clk);
        #1;
        ck_nib(n_decode, 4'h0,              "[mid-reset] decode pulse ignored during reset");
        ck_nib(n_pixel,  4'h0,              "[mid-reset] pixel pulse ignored during reset");
        @(negedge pix_clk);
        decode_valid = 1'b0;
        pixel_valid  = 1'b0;

        // =====================================================================
        // ⑨ 复位释放后重新开始记账
        // =====================================================================
        @(negedge pix_clk);
        rst_n_pix = 1'b1;
        repeat (2) @(posedge pix_clk);
        @(negedge pix_clk);
        rst_n_sdr = 1'b1;
        repeat (2) @(posedge sdr_clk);
        pulse_decode(16'h0000);
        repeat (2) @(posedge pix_clk);
        #1;
        ck_nib(n_decode, 4'h5,              "[resume] decode records again after reset release");
        pulse_write(32'h0000_F800);
        sync_mem;
        ck_nib(n_write, 4'h7,               "[resume] write records again after reset release");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: image_path_probe");
        else             $display("CHECKS FAILED: image_path_probe");
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("CHECKS FAILED: image_path_probe");
        $finish;
    end

endmodule
