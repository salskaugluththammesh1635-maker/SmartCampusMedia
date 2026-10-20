// Replay captured SD sectors through the real FAT32/BMP loading path.
// Fixture: lba.hex contains absolute sector addresses; data.hex contains bytes.
`timescale 1ns/1ps
module tb_sd_card_replay;
    localparam MAX_SECTORS = 4096;
    reg clk = 0;
    always #20 clk = ~clk;
    reg rst_n = 0;
    reg start = 0;
    wire busy, done, fail;
    wire [3:0] err_code;
    wire [31:0] pix_count;
    wire blk_start;
    wire [31:0] blk_addr;
    reg blk_done = 0, blk_err = 0;
    reg [7:0] data_byte = 0;
    reg data_valid = 0;
    wire bmp_start, byte_valid, byte_sof, bmp_hdr_fail, pix_valid;
    wire [15:0] bmp_exp_w, bmp_exp_h, pix_rgb565, pix_x, pix_y;
    wire [7:0] byte_data;
    wire fifo_wr_en;
    wire [31:0] fifo_wr_data;
    wire [3:0] fifo_wr_dm;

    img_loader #(.CHAIN_MAX(4096)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .img_index(9'd1),
        .cfg_w(16'd640), .cfg_h(16'd480),
        .busy(busy), .done(done), .fail(fail), .err_code(err_code),
        .pix_count(pix_count), .blk_start(blk_start), .blk_addr(blk_addr),
        .blk_done(blk_done), .blk_err(blk_err),
        .data_byte(data_byte), .data_valid(data_valid),
        .bmp_start(bmp_start), .bmp_exp_w(bmp_exp_w), .bmp_exp_h(bmp_exp_h),
        .byte_valid(byte_valid), .byte_data(byte_data), .byte_sof(byte_sof),
        .bmp_hdr_fail(bmp_hdr_fail), .pix_valid(pix_valid),
        .pix_rgb565(pix_rgb565), .fifo_wr_en(fifo_wr_en),
        .fifo_wr_data(fifo_wr_data), .fifo_wr_dm(fifo_wr_dm), .fifo_wr_full(1'b0)
    );
    bmp_parser parser (
        .clk(clk), .rst_n(rst_n), .start(bmp_start),
        .exp_w(bmp_exp_w), .exp_h(bmp_exp_h),
        .byte_valid(byte_valid), .byte_data(byte_data), .byte_sof(byte_sof),
        .hdr_ok(), .hdr_fail(bmp_hdr_fail), .err_code(), .img_w(), .img_h(),
        .data_off(), .pix_valid(pix_valid), .pix_rgb565(pix_rgb565),
        .pix_x(pix_x), .pix_y(pix_y)
    );

    reg [31:0] sector_lba [0:MAX_SECTORS-1];
    reg [7:0] sector_data [0:MAX_SECTORS*512-1];
    integer sector_count;
    reg [2047:0] lba_file, data_file;
    integer i, slot, rd_slot, rd_byte, gap;
    integer requests = 0, missing = 0, pixels = 0, words = 0, errors = 0;
    reg active = 0;
    reg [15:0] expected_pixel;

    // Match the 25MHz host / 12.5MHz SPI payload rate: one byte per 16 clocks.
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 0;
            data_valid <= 0;
            blk_done <= 0;
            blk_err <= 0;
            rd_byte <= 0;
            gap <= 0;
        end else begin
            data_valid <= 0;
            blk_done <= 0;
            blk_err <= 0;
            if (blk_start && !active) begin
                slot = -1;
                for (i = 0; i < sector_count; i = i + 1)
                    if (sector_lba[i] == blk_addr) slot = i;
                requests = requests + 1;
                if (requests <= 4) $display("READ LBA=%0d captured_slot=%0d", blk_addr, slot);
                if (slot < 0) begin
                    missing = missing + 1;
                    $display("FAIL: missing captured LBA %0d", blk_addr);
                    blk_err <= 1;
                end else begin
                    active <= 1;
                    rd_slot <= slot;
                    rd_byte <= 0;
                    gap <= 0;
                end
            end else if (active) begin
                if (gap > 0) gap <= gap - 1;
                else if (rd_byte < 512) begin
                    data_byte <= sector_data[rd_slot*512 + rd_byte];
                    data_valid <= 1;
                    rd_byte <= rd_byte + 1;
                    gap <= 15;
                end else begin
                    active <= 0;
                    blk_done <= 1;
                end
            end
            if (pix_valid) begin
                pixels = pixels + 1;
                expected_pixel = (pix_x >= 220 && pix_x < 420 &&
                                  pix_y >= 140 && pix_y < 340) ? 16'hf800 : 16'hffff;
                if (pix_rgb565 !== expected_pixel) begin
                    if (errors < 5) $display("FAIL: pixel x=%0d y=%0d got=%h expected=%h",
                                            pix_x, pix_y, pix_rgb565, expected_pixel);
                    errors = errors + 1;
                end
            end
            if (fifo_wr_en) begin
                words = words + 1;
                if (fifo_wr_dm !== 4'b0000) errors = errors + 1;
            end
        end
    end

    integer guard;
    initial begin
        if (!$value$plusargs("SECTOR_COUNT=%d", sector_count) ||
            !$value$plusargs("LBA_FILE=%s", lba_file) ||
            !$value$plusargs("DATA_FILE=%s", data_file))
            $fatal(1, "Missing capture arguments");
        if (sector_count < 1 || sector_count > MAX_SECTORS)
            $fatal(1, "Invalid sector count");
        $readmemh(lba_file, sector_lba, 0, sector_count-1);
        $readmemh(data_file, sector_data, 0, sector_count*512-1);
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);
        start = 1;
        @(negedge clk);
        start = 0;
        guard = 0;
        while (!done && !fail && guard < 30000000) begin
            @(negedge clk);
            guard = guard + 1;
        end
        repeat (4) @(negedge clk);
        $display("REPLAY_RESULT done=%b fail=%b err=%0d pixels=%0d words=%0d requests=%0d missing=%0d errors=%0d",
                 done, fail, err_code, pixels, words, requests, missing, errors);
        if (fail) $display("BOARD_DISPLAY=2%0h10", err_code);
        if (!done || fail || pixels != 307200 || pix_count != 307200 ||
            words != 153600 || missing != 0 || errors != 0)
            $fatal(1, "Captured SD card image did not load correctly");
        $display("PASS: all 307200 captured-card pixels match white background / red square");
        $display("ALL CHECKS PASSED: SD card replay");
        $finish;
    end
endmodule
