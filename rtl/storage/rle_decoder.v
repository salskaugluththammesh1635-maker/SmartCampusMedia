// =============================================================================
// rle_decoder.v - RLE video frame decoder (SD byte stream -> SDRAM back buffer)
// =============================================================================
// [1] ROLE IN THE SYSTEM
//   Layer    : storage path (rtl/storage)
//   Instance : u_rle in the top level, 25 MHz main clock domain (same clock as
//              sd_spi_ctrl / fat32_reader / img_loader / bmp_parser / img_scaler)
//   Position : SD card 512B block --sd_spi_ctrl--> rle_decoder --ext_wr_*-->
//              image_player --framebuf_arbiter--> SDRAM frame A / frame B
//
//   Why hardware decompression is mandatory:
//     A 640x480 RGB565 frame is 614,400 bytes uncompressed. The SD path delivers
//     512 B per 409.6 us (practical 1.25 MB/s), while 5 fps of raw frames needs
//     3.07 MB/s - a 2.5x shortfall. assets/v2/sdcard/BURN640/SCI.RLE has a
//     compression ratio of 0.2124 (631 frames, 82,362,927 bytes, mean 130,528 B
//     per frame), which lands at 0.65 MB/s and fits the window with margin.
//
// [2] WHAT THIS MODULE DOES
//   Streaming RLE decoder. It pulls one 512 B block at a time from sd_spi_ctrl,
//   parses the per-frame header, expands 3-byte run entries into RGB565 pixels,
//   packs two pixels per 32-bit word and writes every word into the SDRAM back
//   buffer through image_player's external write port. When the whole frame has
//   been written it raises a single-cycle ext_wr_done.
//
//   Properties that matter for the display path:
//     - whole-frame atomicity: ext_wr_done is only raised after all FRAME_WORDS
//       words have been acknowledged by the arbiter; a partial frame never flips
//       the front buffer
//     - underrun keeps the previous frame: no done -> no commit -> no flip
//     - the decoder initiates every block read, so SD back-pressure is natural
//
// [3] FILE FORMAT (.RLE, little endian, header repeated before every frame)
//      offset 0..3    magic "SCMR"        = 0x53 0x43 0x4D 0x52
//      offset 4..5    width  16-bit LE    = 640 (0x0280)
//      offset 6..7    height 16-bit LE    = 480 (0x01E0)
//      offset 8..11   run_count 32-bit LE
//      offset 12..    3 * run_count bytes, each entry {rgb565[15:0], run_len[7:0]}
//                     byte order inside an entry: rgb565 high byte, rgb565 low
//                     byte, then run_len.  run_len == 0 means 256 pixels.
//   Measured frame 0: magic 0x53434D52, w 0x0280, h 0x01E0, runs 0x000004B0
//   (1200), which matches line 0 of SCI.IDX ("00000 0 3612 1200"; 3612 = 12+3*1200).
//
// [4] WRITE PORT CONTRACT (why the 4-deep buffer below is not optional)
//   Three properties the integrator relies on:
//     P1  ext_wr_addr[1:0] is 2'b00 at every write-group start.
//         Note for testbench authors: ext_wr_addr advances by one per accepted
//         beat, so inside a group the low two bits do walk 1,2,3 and are only
//         zero again at the next group base. The property to assert is therefore
//         "ext_wr_addr[1:0]==0 whenever a group opens", NOT "on every valid
//         cycle". Asserting the latter would fail on functionally correct RTL.
//     P2  the address must not advance while ext_wr_busy is high (handled by
//         only advancing on ext_wr_ack; busy is a wire the external side may
//         ignore internally because no state depends on it).
//     P3  a frame flip happens only on vblank_rise, driven by ext_wr_done.
//
//   P1 is the subtle one. framebuf_arbiter with WR_ADDR_FROM_FIFO=1 captures the
//   group base on the first beat and then writes four consecutive words as one
//   SDRAM burst-of-4, taking the address from an internal counter rather than
//   from this module. A burst that starts at a non-4-word-aligned address wraps
//   inside the aligned block, so a writer that stalls in the middle of a group
//   would let the next burst land on top of already written words. The visible
//   symptom is a single horizontal tear line, easy to misdiagnose as a monitor
//   fault.
//
//   The cure is a 4-deep word buffer: a group is only opened when four words are
//   already buffered, so all four beats are guaranteed to be present and a group
//   is never abandoned half way. Every group base is therefore frame_base + 4k,
//   and both frame bases (0 and 153,600) are multiples of 4, so P1 holds by
//   construction.
//
// [5] DESIGN TRAPS AND HOW THEY ARE AVOIDED
//   1) The write port, not the SD card, is the bottleneck. Frame 0 has 1200 runs
//      in 3612 bytes = 8 blocks, which the SD side delivers in 8*512 cycles
//      (164 us), while 153,600 words at 4 words per 13 arbiter cycles need about
//      20 ms. That is why the decoder requests blocks itself: the SD card only
//      reads when the decoder asks, so one 512 B block buffer suffices and no
//      deep FIFO is needed.
//   2) Pixels within a run share one colour, so a step emits two pixels per word.
//      An odd run length leaves half a word in px_half/px_lo and is completed by
//      the first pixel of the next run - a word is never written twice and never
//      dropped.
//   3) The frame must contain exactly 2*FRAME_WORDS pixels. Once FRAME_WORDS
//      words have been queued any surplus pixels are discarded, but the run and
//      entry counters still drain, otherwise the entry loop would deadlock.
//   4) Single-driver discipline: the block buffer write port has its own always
//      block, the inter-frame watchdog has another, the expander is pure
//      combinational logic, and everything else (FSM, word buffer, external
//      write port, bank toggle) lives in one clocked block.
//   5) No intra-block read-after-write hazard: the word pushed into the buffer
//      comes from a combinational wire (exp_word), not from a register that is
//      assigned in the same block, so the value written is the value visible in
//      the current cycle.
//   6) Simulation speed: the frame interval is CLK_FREQ_HZ/play_fps. A testbench
//      passing a small CLK_FREQ_HZ (e.g. 25000) with play_fps=250 gets a
//      100-cycle interval instead of waiting 200 ms of simulated time.
//
// [6] FILE CONTIGUITY ASSUMPTION
//   The .RLE file is stored in contiguous sectors (BURN640/SCI.RLE was written in
//   one pass by the packer and SCI.IDX lists raw byte offsets per frame, which
//   proves there is no fragmentation). This module only holds file_lba/file_size
//   and never walks a FAT chain; a fragmented card needs a contiguous copy first.
//
// [6.1] SD BUS ARBITRATION (want_blk / sd_grant / blk_start)
//   The SD bus is shared with wav_stream_player (audio), the gallery probe and
//   img_loader (BMP). The top level arbitrates it with three level/pulse signals:
//     want_blk  level, out  - "I need a block"; raised while a block is needed
//     sd_grant  level, in   - "the bus is yours for this block"
//     blk_start pulse, out  - "here is my request", asserted only on a cycle
//                             where sd_grant is already high
//
//   Why blk_start must be qualified by sd_grant rather than by a latched request:
//   sd_spi_ctrl takes one look at blk_start. If this module raised it while the
//   bus belonged to somebody else, the card would fetch a sector for the wrong
//   consumer - the audio stream would be fed video bytes (audible as noise) and
//   this decoder would expand WAV samples as run-length pairs, producing garbage
//   plus err_code=4 within a few blocks. Nothing about that failure is visible in
//   a testbench that ties sd_grant to 1'b1, which is why tb_rle_decoder drives it
//   low for several cycles at a time.
//
//   Why there is NO pending latch here (unlike wav_stream_player):
//     wav_stream_player wraps fat32_reader, which raises its own single-cycle
//     request from inside a sub-FSM; that pulse cannot be held, so the wrapper
//     must latch "a request happened" and replay it on the grant cycle.
//     This decoder raises blk_start from its own state machine, so it can simply
//     stay in R_NEXT_BLK until sd_grant arrives. req_sent is not a pending latch:
//     it only records that the pulse has already been issued for the current
//     block. Adding a second latch would duplicate state and make it possible for
//     the FSM and the latch to disagree about which block is outstanding.
//
//   Why waiting for grant is unbounded (no timeout, no R_ERR):
//     The arbiter serves every level request eventually; the only way to never get
//     a grant is a dead peer, and in that case the top-level watchdog reports it.
//     A local timeout would instead turn a slow bus into a silently frozen picture
//     that keeps reporting "no error", which is far harder to diagnose.
//
//   want_blk is deliberately raised early: it is high while (!blk_ready) as well
//   as in R_NEXT_BLK, so the arbiter sees the request at least one block ahead and
//   can hand over the bus without the decoder having to stall for a full block
//   latency. Raising it only inside R_NEXT_BLK would cost one extra arbitration
//   round trip per block.
// =============================================================================
`timescale 1ns / 1ps

module rle_decoder #(
    parameter CLK_FREQ_HZ   = 25_000_000, // main clock, same domain as sd_spi_ctrl
    parameter FRAME_W       = 16'd640,    // expected width, mismatch is an error
    parameter FRAME_H       = 16'd480,    // expected height
    parameter JITTER_FRAMES = 8'd3,       // frame periods one frame may occupy
    parameter INIT_WR_BANK  = 1'b1,       // first frame goes to bank 1 (back buffer)
    parameter LOOP_PLAY     = 1'b1,       // loop back to frame 0 at end of file
    parameter BLK_BYTES     = 16'd512     // SD block size in bytes
) (
    input  wire        clk,
    input  wire        rst_n,

    // SD block service (same clock domain as sd_spi_ctrl)
    output wire        blk_start,   // valid with blk_addr, held until blk_busy rises
    output reg  [31:0] blk_addr,    // sector number = file_lba + block index
    input  wire        blk_busy,
    input  wire        blk_done,    // single cycle: all BLK_BYTES bytes delivered
    input  wire        blk_err,     // single cycle: block read failed
    input  wire [7:0]  data_byte,
    input  wire        data_valid,  // with data_byte, BLK_BYTES consecutive cycles

    // SD bus arbitration (level, driven by the top-level arbiter)
    //   want_blk : "this module needs a block" (level, already raised early)
    //   sd_grant : "the bus is yours for this block" (level)
    //   blk_start is only raised on a cycle where sd_grant is high, so the
    //   sector on blk_addr can never be stolen by wav_stream_player or the
    //   BMP loader. Waiting for grant is unbounded on purpose: the arbiter
    //   always serves a level request eventually, and a timeout here would
    //   turn a slow bus into a picture that silently stops advancing.
    input  wire        sd_grant,

    // Playback control
    input  wire        play_en,
    input  wire [7:0]  play_fps,    // target frame rate, 0 is treated as 1
    input  wire [31:0] file_lba,    // first sector of the .RLE file
    input  wire [31:0] file_size,   // file length in bytes

    output reg  [15:0] frame_idx,   // frames decoded so far (wraps when looping)

    // External write port towards image_player
    output reg         ext_wr_done, // single cycle: all FRAME_WORDS words written
    output reg         ext_wr_valid,
    output reg  [20:0] ext_wr_addr, // word address, 4-word aligned at group start
    output wire [31:0] ext_wr_data, // high 16 bits = right pixel, low = left pixel
    output wire [3:0]  ext_wr_dm,   // always 4'h0, all four bytes written (dm[n]=1 masks)
    input  wire        ext_wr_ack,  // single cycle: this word was accepted
    input  wire        ext_wr_busy, // high: no ack yet, address must not advance

    output reg  [3:0]  err_code,    // 1=magic 2=geometry 3=pixel count 4=truncated/block error
    output reg         underrun,    // high: one frame could not be shown in time
    output wire        want_blk     // high: this module is waiting for an SD block
);

    // ------------------------------------------------------------------
    // [7] Constants
    // ------------------------------------------------------------------
    localparam [31:0] CLK_HZ       = CLK_FREQ_HZ;
    localparam [31:0] FRAME_PIXELS = FRAME_W * FRAME_H;
    localparam [31:0] FRAME_WORDS  = FRAME_PIXELS >> 1;
    localparam [20:0] BANK_A_BASE  = 21'd0;
    localparam [20:0] BANK_B_BASE  = FRAME_WORDS[20:0];
    localparam [15:0] BLK_BYTES_V  = BLK_BYTES;
    localparam [9:0]  BLK_LAST     = BLK_BYTES_V[9:0] - 10'd1;
    localparam [31:0] MAGIC_RLE    = 32'h5343_4D52; // "SCMR"

    localparam [2:0] R_IDLE       = 3'd0,
                     R_HDR_MAGIC  = 3'd1,
                     R_HDR_WH     = 3'd2,
                     R_HDR_RUNCNT = 3'd3,
                     R_PAYLOAD    = 3'd4,
                     R_NEXT_BLK   = 3'd5,
                     R_FRAME_END  = 3'd6,
                     R_ERR        = 3'd7;

    // ------------------------------------------------------------------
    // [8] Registered state
    // ------------------------------------------------------------------
    reg  [2:0]  state;
    reg  [2:0]  resume_state;

    // block buffer, written by its own always block
    //
    // 【已评估：不换 BRAM】blk_buf 是 4,096 bit（512 x 8），读口在 R_PAYLOAD 里是
    //   组合取字节（cur_byte = blk_buf[rd_ptr]），异步读 → TD 必定推成 LUTRAM/DRAM
    //   而不是 BRAM（与 u_pix_fifo 同一机制，见 docs/plan_v2/T4_VIDEO_PATH.md §18）。
    //   换成 BRAM 可省约 256 LUT，但当前 LUT 余量充足（17,645 / 90.03%，余 1,955），
    //   不做 —— 换 BRAM 会引入 1 拍读延迟，而本读口处在
    //   「读字节 → 判 run_len → 拼半字 → 推 SDRAM 写口」这条紧凑组合链上，
    //   加一拍会打乱 t4 已验证的写组时序（tb_rle_decoder 30 条断言覆盖）。
    reg  [7:0]  blk_buf [0:BLK_BYTES_V-1];
    reg  [9:0]  wr_ptr;
    reg         blk_start_d;
    reg         blk_start_int;  // request, gated by sd_grant on the way out
    reg         blk_ready;      // whole block available
    reg  [9:0]  rd_ptr;         // main block
    reg         req_sent;
    reg  [31:0] blk_index;
    reg  [31:0] pos_cnt;        // bytes consumed since file start

    // frame header accumulators
    reg  [1:0]  hdr_idx;
    reg  [31:0] hdr_magic;
    reg  [15:0] hdr_w;
    reg  [15:0] hdr_h;
    reg  [31:0] hdr_runs;

    // run entry and expansion
    reg  [1:0]  ent_idx;        // 0=rgb high, 1=rgb low, 2=run_len
    reg  [15:0] run_rgb;
    reg  [8:0]  run_left;
    reg  [31:0] runs_left;
    reg  [15:0] px_lo;
    reg         px_half;
    reg  [17:0] push_cnt;       // words queued for this frame

    // 4-deep word buffer (group atomicity, see [4])
    reg  [31:0] wmem [0:3];
    reg  [1:0]  whead;
    reg  [1:0]  wtail;
    reg  [2:0]  wcount;

    // external write port
    reg  [2:0]  group_left;     // beats still to present in the current group
    reg  [17:0] wr_done_cnt;    // words acknowledged for this frame
    reg         done_sent;      // ext_wr_done was already raised for this frame
    reg         frame_go;       // pulse: a new frame starts, its buffer base is set
    reg  [20:0] frame_base;

    // bank selection and frame pacing
    reg  [1:0]  wr_bank;
    reg  [31:0] gap_acc;
    reg  [7:0]  jitter_cnt;
    reg         wd_expired;
    reg         eof_stop;

    // ------------------------------------------------------------------
    // [9] Combinational helpers
    // ------------------------------------------------------------------
    wire [7:0]  fps_eff   = (play_fps == 8'd0) ? 8'd1 : play_fps;
    wire [32:0] gap_sum   = {1'b0, gap_acc} + {25'd0, fps_eff};
    wire        gap_tick  = (gap_sum >= {1'b0, CLK_HZ});

    wire        at_eof     = (pos_cnt >= file_size);
    // the last block may be short: stop consuming as soon as pos_cnt reaches
    // file_size, otherwise stale bytes in that block would be decoded as data
    wire        have_byte  = blk_ready && !at_eof;
    wire [7:0]  cur_byte   = blk_buf[rd_ptr];
    wire        buf_room   = (wcount < 3'd4);
    wire        do_pop     = ext_wr_valid && ext_wr_ack;
    // pack_done must fire exactly once: done_sent latches so that neither a
    // lingering wr_done_cnt nor the final beat can raise a second ext_wr_done
    wire        pack_done  = (wr_done_cnt == FRAME_WORDS[17:0]) && !ext_wr_valid &&
                             !done_sent;
    wire        pixel_done = (push_cnt == FRAME_WORDS[17:0]);

    // ---- combinational expander: the next word to push into the buffer ----
    // A step is allowed only when the buffer has room and the frame still needs
    // pixels. Odd run tails park half a word in px_half/px_lo until the first
    // pixel of the following run completes it.
    wire exp_active = (state == R_PAYLOAD) && (run_left != 9'd0) &&
                      !pixel_done && buf_room;
    wire exp_half   = exp_active && px_half;
    wire exp_pair   = exp_active && !px_half && (run_left >= 9'd2);
    wire exp_single = exp_active && !px_half && (run_left == 9'd1);
    wire exp_push   = exp_half || exp_pair;
    wire [31:0] exp_word = exp_half ? {run_rgb, px_lo} : {run_rgb, run_rgb};

    assign want_blk = play_en && !eof_stop &&
                      (state != R_FRAME_END) && (state != R_ERR) &&
                      ((state == R_NEXT_BLK) || !blk_ready);

    // The request is registered (blk_start_int) but handed to sd_spi_ctrl only on
    // a cycle where the grant is still high. Gating here rather than on req_sent
    // is what closes the one-cycle hole: the top level ORs every owner's request
    // combinationally (sd_arb_start = |(sd_owner_* & blk_start)), so if sd_grant
    // drops on the cycle after the FSM decided to go, a request that was already
    // registered would be dropped by the arbiter while req_sent claims it was
    // issued - the card is never started and blk_done never comes. With the AND
    // in place the pulse simply re-appears as soon as the grant returns, and
    // sd_spi_ctrl (which samples blk_start once, on init_done) still sees a clean
    // request held until blk_busy rises.
    assign blk_start = blk_start_int && sd_grant;

    // word is read combinationally at wtail: on ack wtail advances, so the next
    // word is already presented in the following cycle while valid stays high
    assign ext_wr_data = wmem[wtail];
    // dm[n]=1 masks byte n of the word (sdram_ctrl_wrap.v behaviour model:
    // "if (!app_wr_dm[0]) mem[..][7:0] <= app_wr_din[7:0]"). A video word always
    // carries two complete pixels, so no byte may be masked: dm must be 4'h0.
    // img_loader uses the same polarity (fifo_wr_dm <= 4'h0 for a full write,
    // 4'hC to write only the low half word).
    assign ext_wr_dm   = 4'h0;

    // ------------------------------------------------------------------
    // [10] Block buffer write port (own always block, keeps the array dual ported)
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= 10'd0;
            blk_start_d <= 1'b0;
        end else begin
            blk_start_d <= blk_start_int;
            if (blk_start_int && !blk_start_d) begin
                wr_ptr <= 10'd0;
            end else if (data_valid) begin
                blk_buf[wr_ptr] <= data_byte;
                wr_ptr          <= wr_ptr + 10'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // [11] Main block: expander, word buffer, external write port, FSM
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= R_IDLE;
            resume_state   <= R_HDR_MAGIC;
            rd_ptr         <= 10'd0;
            blk_ready      <= 1'b0;
            req_sent       <= 1'b0;
            blk_index      <= 32'd0;
            pos_cnt        <= 32'd0;
            blk_start_int      <= 1'b0;
            blk_addr       <= 32'd0;
            hdr_idx        <= 2'd0;
            hdr_magic      <= 32'd0;
            hdr_w          <= 16'd0;
            hdr_h          <= 16'd0;
            hdr_runs       <= 32'd0;
            ent_idx        <= 2'd0;
            run_rgb        <= 16'd0;
            run_left       <= 9'd0;
            runs_left      <= 32'd0;
            px_lo          <= 16'd0;
            px_half        <= 1'b0;
            push_cnt       <= 18'd0;
            whead          <= 2'd0;
            wtail          <= 2'd0;
            wcount         <= 3'd0;
            group_left     <= 3'd0;
            wr_done_cnt    <= 18'd0;
            frame_go       <= 1'b0;
            frame_base     <= 21'd0;
            ext_wr_valid   <= 1'b0;
            ext_wr_addr    <= 21'd0;
            ext_wr_done    <= 1'b0;
            wr_bank        <= INIT_WR_BANK ? 2'd1 : 2'd0;
            gap_acc        <= 32'd0;
            err_code       <= 4'd0;
            underrun       <= 1'b0;
            frame_idx      <= 16'd0;
            eof_stop       <= 1'b0;
            done_sent      <= 1'b0;
        end else begin
            // ---- default for the single-cycle strobes ----
            ext_wr_done <= 1'b0;
            frame_go    <= 1'b0;

            // ---- frame pacing accumulator (fractional, no divider) ----
            if (!play_en)      gap_acc <= 32'd0;
            else if (gap_tick) gap_acc <= 32'd0;
            else               gap_acc <= gap_sum[31:0];

            // ---- underrun is a per-frame sticky flag ----
            if (wd_expired) underrun <= 1'b1;

            // ============================================================
            // Word buffer push (from the combinational expander)
            // ============================================================
            if (exp_push) begin
                wmem[whead] <= exp_word;
                whead       <= whead + 2'd1;
                push_cnt    <= push_cnt + 18'd1;
            end

            // ---- run_left / px_half update for this expansion step ----
            if (exp_half) begin
                px_half  <= 1'b0;
                run_left <= run_left - 9'd1;
            end else if (exp_pair) begin
                run_left <= run_left - 9'd2;
            end else if (exp_single) begin
                px_lo    <= run_rgb;
                px_half  <= 1'b1;
                run_left <= 9'd0;
            end

            // ============================================================
            // Word buffer occupancy
            // ============================================================
            case ({exp_push, do_pop})
            2'b10:   wcount <= wcount + 3'd1;
            2'b01:   wcount <= wcount - 3'd1;
            default: wcount <= wcount;
            endcase

            // ============================================================
            // External write port. Runs every cycle, independent of the FSM.
            // A group is opened only when four words are buffered, so all four
            // beats are always present and the group base stays 4-word aligned.
            // ============================================================
            if (!play_en || frame_go) begin
                ext_wr_valid <= 1'b0;
                group_left   <= 3'd0;
                wr_done_cnt  <= 18'd0;
                wtail        <= 2'd0;
                whead        <= 2'd0;
                wcount       <= 3'd0;
                // Park at the frame base rather than holding a stale address:
                // an aborted frame must restart from its base, and a finished one
                // leaves the port parked where the next frame will begin.
                ext_wr_addr  <= frame_base;
            end else if (do_pop) begin
                ext_wr_addr <= ext_wr_addr + 21'd1;
                wr_done_cnt <= wr_done_cnt + 18'd1;
                wtail       <= wtail + 2'd1;
                if (group_left == 3'd1) begin
                    group_left   <= 3'd0;
                    ext_wr_valid <= 1'b0;
                end else begin
                    group_left <= group_left - 3'd1;
                end
            end else if (!ext_wr_valid && (group_left == 3'd0) && (wcount >= 3'd4)) begin
                ext_wr_valid <= 1'b1;
                group_left   <= 3'd4;
            end

            // ---- whole-frame completion: only after every word was accepted ----
            if (pack_done) ext_wr_done <= 1'b1;
            if (!play_en || frame_go) done_sent <= 1'b0;
            else if (pack_done)       done_sent <= 1'b1;

            // ============================================================
            // Frame FSM
            // ============================================================
            if (!play_en) begin
                state        <= R_IDLE;
                resume_state <= R_HDR_MAGIC;
                run_left     <= 9'd0;
                runs_left    <= 32'd0;
                px_half      <= 1'b0;
                ent_idx      <= 2'd0;
                hdr_idx      <= 2'd0;
                push_cnt     <= 18'd0;
                blk_start_int    <= 1'b0;
                req_sent     <= 1'b0;
                eof_stop     <= 1'b0;
                err_code     <= 4'd0;
            end else begin
                case (state)
                // ------------------------------------------------------
                R_IDLE: begin
                    if (gap_tick && !blk_busy && !eof_stop) begin
                        hdr_idx     <= 2'd0;
                        hdr_magic   <= 32'd0;
                        hdr_w       <= 16'd0;
                        hdr_h       <= 16'd0;
                        hdr_runs    <= 32'd0;
                        ent_idx     <= 2'd0;
                        run_left    <= 9'd0;
                        runs_left   <= 32'd0;
                        px_half     <= 1'b0;
                        push_cnt    <= 18'd0;
                        frame_base  <= (wr_bank == 2'd1) ? BANK_B_BASE : BANK_A_BASE;
                        frame_go    <= 1'b1;
                        underrun    <= 1'b0; // new frame, clear the previous flag
                        state       <= R_HDR_MAGIC;
                    end
                end
                // ------------------------------------------------------
                R_HDR_MAGIC: begin
                    if (have_byte) begin
                        rd_ptr  <= rd_ptr + 10'd1;
                        pos_cnt <= pos_cnt + 32'd1;
                        if (rd_ptr == BLK_LAST) blk_ready <= 1'b0;
                        if (hdr_idx == 2'd3) begin
                            hdr_idx <= 2'd0;
                            if ({hdr_magic[23:0], cur_byte} != MAGIC_RLE) begin
                                err_code <= 4'd1;
                                underrun <= 1'b1;
                                state    <= R_ERR;
                            end else begin
                                state <= R_HDR_WH;
                            end
                        end else begin
                            hdr_magic <= {hdr_magic[23:0], cur_byte};
                            hdr_idx   <= hdr_idx + 2'd1;
                        end
                    end else if (at_eof) begin
                        if (LOOP_PLAY) begin
                            blk_index <= 32'd0;
                            pos_cnt   <= 32'd0;
                            rd_ptr    <= 10'd0;
                            blk_ready <= 1'b0;
                        end else begin
                            eof_stop <= 1'b1;
                            state    <= R_IDLE;
                        end
                    end else begin
                        resume_state <= R_HDR_MAGIC;
                        state        <= R_NEXT_BLK;
                    end
                end
                // ------------------------------------------------------
                R_HDR_WH: begin
                    if (have_byte) begin
                        rd_ptr  <= rd_ptr + 10'd1;
                        pos_cnt <= pos_cnt + 32'd1;
                        if (rd_ptr == BLK_LAST) blk_ready <= 1'b0;
                        case (hdr_idx)
                        2'd0: hdr_w[7:0]    <= cur_byte;
                        2'd1: hdr_w[15:8]   <= cur_byte;
                        2'd2: hdr_h[7:0]    <= cur_byte;
                        default: hdr_h[15:8] <= cur_byte;
                        endcase
                        if (hdr_idx != 2'd3) begin
                            hdr_idx <= hdr_idx + 2'd1;
                        end else begin
                            hdr_idx <= 2'd0;
                            // width and height are little-endian in the header:
                            // the byte currently on cur_byte is the HIGH half of
                            // the last field, so it must be concatenated on the
                            // left. Writing {hdr_h[7:0], cur_byte} would compare
                            // against 0xE001 instead of 0x01E0 and reject every
                            // legal frame with err_code=2.
                            if ((hdr_w != FRAME_W) || ({cur_byte, hdr_h[7:0]} != FRAME_H)) begin
                                err_code <= 4'd2;
                                underrun <= 1'b1;
                                state    <= R_ERR;
                            end else begin
                                state <= R_HDR_RUNCNT;
                            end
                        end
                    end else if (at_eof) begin
                        err_code <= 4'd4;
                        underrun <= 1'b1;
                        state    <= R_ERR;
                    end else begin
                        resume_state <= R_HDR_WH;
                        state        <= R_NEXT_BLK;
                    end
                end
                // ------------------------------------------------------
                R_HDR_RUNCNT: begin
                    if (have_byte) begin
                        rd_ptr  <= rd_ptr + 10'd1;
                        pos_cnt <= pos_cnt + 32'd1;
                        if (rd_ptr == BLK_LAST) blk_ready <= 1'b0;
                        case (hdr_idx)
                        2'd0: hdr_runs[7:0]    <= cur_byte;
                        2'd1: hdr_runs[15:8]   <= cur_byte;
                        2'd2: hdr_runs[23:16]  <= cur_byte;
                        default: hdr_runs[31:24] <= cur_byte;
                        endcase
                        if (hdr_idx != 2'd3) begin
                            hdr_idx <= hdr_idx + 2'd1;
                        end else begin
                            hdr_idx <= 2'd0;
                            // run_count is little endian like width/height, so
                            // cur_byte (the 4th and last byte of the field) is the
                            // MOST significant byte and must be concatenated on the
                            // left. {hdr_runs[23:0], cur_byte} would yield
                            // 0x0004B000 = 307200 for a real count of 0x000004B0 =
                            // 1200, and the decoder would then read far past the
                            // last entry until it hit end of file (err_code=4).
                            if ({cur_byte, hdr_runs[23:0]} == 32'd0) begin
                                err_code <= 4'd3;
                                underrun <= 1'b1;
                                state    <= R_ERR;
                            end else begin
                                runs_left <= {cur_byte, hdr_runs[23:0]};
                                state     <= R_PAYLOAD;
                            end
                        end
                    end else if (at_eof) begin
                        err_code <= 4'd4;
                        underrun <= 1'b1;
                        state    <= R_ERR;
                    end else begin
                        resume_state <= R_HDR_RUNCNT;
                        state        <= R_NEXT_BLK;
                    end
                end
                // ------------------------------------------------------
                R_PAYLOAD: begin
                    if (run_left != 9'd0) begin
                        // the expander normally drains the run. The surplus case
                        // (frame already holds FRAME_WORDS words) must drop the
                        // rest of the run unconditionally, including a parked
                        // half word, otherwise this branch would never exit.
                        if (pixel_done) begin
                            run_left <= 9'd0;
                            px_half  <= 1'b0;
                        end
                    end else if (runs_left == 32'd0) begin
                        // every entry expanded: the frame is complete only when
                        // exactly FRAME_WORDS words were produced and drained
                        if (px_half || !pixel_done) begin
                            err_code <= 4'd3;   // pixel count mismatch
                            underrun <= 1'b1;
                            state    <= R_IDLE;
                        end else if (pack_done) begin
                            wr_bank  <= (wr_bank == 2'd1) ? 2'd0 : 2'd1;
                            underrun <= 1'b0;
                            state    <= R_FRAME_END;
                        end
                        // else: the write port is still draining, wait
                    end else if (have_byte) begin
                        rd_ptr  <= rd_ptr + 10'd1;
                        pos_cnt <= pos_cnt + 32'd1;
                        if (rd_ptr == BLK_LAST) blk_ready <= 1'b0;
                        case (ent_idx)
                        2'd0: run_rgb[15:8] <= cur_byte;
                        2'd1: run_rgb[7:0]  <= cur_byte;
                        default: begin
                            run_left  <= (cur_byte == 8'd0) ? 9'd256 : {1'b0, cur_byte};
                            runs_left <= runs_left - 32'd1;
                        end
                        endcase
                        ent_idx <= (ent_idx == 2'd2) ? 2'd0 : (ent_idx + 2'd1);
                    end else if (at_eof) begin
                        err_code <= 4'd4;
                        underrun <= 1'b1;
                        state    <= R_IDLE;
                    end else begin
                        resume_state <= R_PAYLOAD;
                        state        <= R_NEXT_BLK;
                    end
                end
                // ------------------------------------------------------
                R_NEXT_BLK: begin
                    // Only claim the bus on a cycle where the arbiter grants it.
                    // blk_addr is loaded on the very same cycle as blk_start, so
                    // the sector handed to the card always belongs to this block
                    // and never to whoever owned the bus a cycle earlier.
                    // While sd_grant stays low the FSM simply parks here: no
                    // timeout, no R_ERR, because a late grant is not a fault.
                    if (!req_sent && sd_grant) begin
                        blk_start_int <= 1'b1;
                        blk_addr  <= file_lba + blk_index;
                        req_sent  <= 1'b1;
                    end else if (blk_busy) begin
                        blk_start_int <= 1'b0;
                    end
                    if (blk_done) begin
                        blk_ready <= 1'b1;
                        rd_ptr    <= 10'd0;
                        blk_index <= blk_index + 32'd1;
                        req_sent  <= 1'b0;
                        blk_start_int <= 1'b0;
                        state     <= resume_state;
                    end else if (blk_err) begin
                        blk_start_int <= 1'b0;
                        req_sent  <= 1'b0;
                        err_code  <= 4'd4;
                        underrun  <= 1'b1;
                        state     <= R_ERR;
                    end
                end
                // ------------------------------------------------------
                R_FRAME_END: begin
                    frame_idx <= frame_idx + 16'd1;
                    if (LOOP_PLAY && at_eof) begin
                        blk_index <= 32'd0;
                        pos_cnt   <= 32'd0;
                        rd_ptr    <= 10'd0;
                        blk_ready <= 1'b0;
                    end
                    state <= R_IDLE;
                end
                // ------------------------------------------------------
                R_ERR: begin
                    blk_start_int <= 1'b0;
                    req_sent  <= 1'b0;
                    underrun  <= 1'b1;
                end
                // ------------------------------------------------------
                default: state <= R_IDLE;
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // [12] Inter-frame watchdog. Raises wd_expired when one frame occupies more
    //      than JITTER_FRAMES frame periods. It only sets a flag: the frame in
    //      flight is never abandoned, because dropping a done would drop a frame.
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            jitter_cnt <= 8'd0;
            wd_expired <= 1'b0;
        end else if (!play_en) begin
            jitter_cnt <= 8'd0;
            wd_expired <= 1'b0;
        end else if ((state == R_IDLE) || (state == R_FRAME_END) || (state == R_ERR)) begin
            jitter_cnt <= 8'd0;
            wd_expired <= 1'b0;
        end else if (jitter_cnt == JITTER_FRAMES) begin
            wd_expired <= 1'b1;
        end else if (gap_tick) begin
            jitter_cnt <= jitter_cnt + 8'd1;
        end
    end

endmodule
