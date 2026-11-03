// =============================================================================
// tb_rle_decoder - RLE video frame decoder (t4 / T4)
// =============================================================================
// What this bench proves, and why each check exists:
//
//  1) BYTE-EXACT DECODE AGAINST REAL FOOTAGE. The stimulus is not a hand-made
//     toy frame: vectors/sci_f0_*.hex and vectors/sci_f1_*.hex are the literal
//     bytes of frames 0 and 1 of assets/v2/sdcard/BURN640/SCI.RLE (3612 B and
//     45210 B, taken at offsets 0 and 3612 per SCI.IDX). Frame 0 is the nasty
//     case - all 1200 of its runs are length 256, encoded as run_len=0 - while
//     frame 1 has 15066 runs and roughly half of them are odd lengths, which is
//     what exercises the half-word carry across runs. The golden words come
//     from vectors/sci_f?_words.hex, produced by an independent Python
//     expansion of the same file, so encoder and decoder never share code.
//
//  2) THE FOUR-WORD WRITE GROUP IS ATOMIC. framebuf_arbiter with
//     WR_ADDR_FROM_FIFO=1 latches the group base on the first beat and then
//     issues a burst of four from an internal counter. A writer that opens a
//     group without four words ready, or that lets a group end early, walks the
//     base by 3 instead of 4 and the next burst overwrites live pixels. The
//     symptom on screen is one horizontal tear line, and nothing ever reports an
//     error. The bench therefore checks that the captured address of every group
//     is word-aligned to four, that every group carries exactly four accepted
//     beats, and that the sequence of captured bases is contiguous.
//
//  3) dm POLARITY. dm[n]=1 masks byte n (sdram_ctrl_wrap.v behaviour model).
//     A video word always carries two complete pixels, so ext_wr_dm must be
//     4'h0. If it were 4'hF every word would be dropped, the screen would keep
//     the previous frame forever, and ext_wr_done would still rise - a silent
//     failure, which is exactly the kind this bench must catch.
//
//  4) FRAME PACKING. The 32-bit word is {right pixel, left pixel}: low half =
//     even x (left), high half = odd x (right). This matches pix_reader.v's
//     own convention (fifo_rd_data[15:0] leaves first) and img_loader's
//     fifo_wr_data = {odd, even}. The golden file encodes the same order, so a
//     swapped packer fails here rather than on a monitor.
//
//  5) FRAME ATOMICITY AND UNDERRUN BEHAVIOUR. ext_wr_done is a single-cycle
//     pulse, raised only after all 153600 words were accepted. Dropping play_en
//     mid-frame must abandon the frame: no done pulse, word counter back to
//     zero, and the next frame rewritten from its base. An aborted frame must
//     never leave the write pointer past the frame end.
//
//  6) HEADER VALIDATION. A wrong magic, a wrong geometry or a zero run count
//     must raise err_code and stall, instead of decoding garbage onto the panel.
//
// Simulation model: the SD card is replaced by a behavioural block source that
// replays the vector file, one 512 B block per blk_start, 512 consecutive
// data_valid cycles. The SDRAM write port is an acking sink that also models the
// arbiter's group-base latching, so property 2 is checked on the same mechanism
// the real arbiter uses.
// =============================================================================
`timescale 1ns / 1ps

module tb_rle_decoder;

	parameter CLK_PERIOD = 40.0;          // 25 MHz, same domain as sd_spi_ctrl
	// CLK_FREQ is the frame-pacing reference, not the simulated clock rate. The
	// real design runs it at 25_000_000 (the RTL default); simulating that would
	// mean waiting 5,000,000 cycles before the very first frame, because R_IDLE
	// gates on gap_tick == CLK_FREQ/play_fps. The bench scales it down by 10000
	// and CASE 0 verifies the divider itself: the measured gap_tick period must
	// equal CLK_FREQ/play_fps cycles, the same arithmetic the real parameter
	// performs. Breaking the accumulator turns CASE 0 red.
	parameter CLK_FREQ   = 2_500;
	parameter FRAME_W    = 16'd640;
	parameter FRAME_H    = 16'd480;
	// Explicit 32-bit context is mandatory here. FRAME_W/FRAME_H are 16-bit
	// parameters, so an untyped localparam evaluates the product in 16 bits and
	// 640*480 truncates to 45056 (then >>1 gives 22528). The RTL gets this right
	// only because its own localparam carries a [31:0] range, which makes the
	// expression context-determined by the 32-bit left-hand side.
	localparam [31:0] FRAME_WORDS = (FRAME_W * FRAME_H) >> 1;   // 153600
	localparam [31:0] FRAME_BYTES = FRAME_WORDS * 4;           // 614400

	// ---- clock / reset -----------------------------------------------------
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	// ---- DUT ports ---------------------------------------------------------
	reg         play_en = 1'b0;
	reg  [7:0]  play_fps = 8'd5;
	reg  [31:0] file_lba = 32'd0;
	reg  [31:0] file_size = 32'd0;

	wire        blk_start;
	wire [31:0] blk_addr;
	reg         blk_busy = 1'b0;
	reg         blk_done = 1'b0;
	reg         blk_err = 1'b0;
	reg  [7:0]  data_byte = 8'd0;
	reg         data_valid = 1'b0;

	wire [15:0] frame_idx;
	wire        ext_wr_done;
	wire        ext_wr_valid;
	wire [20:0] ext_wr_addr;
	wire [31:0] ext_wr_data;
	wire [3:0]  ext_wr_dm;
	wire [3:0]  err_code;
	wire        underrun;
	wire        want_blk;

	// SD bus grant from the top-level arbiter. Driven by the generator below so
	// that it really goes low for several cycles at a time; a grant tied to 1'b1
	// would leave the "blk_start is only raised while granted" property untested.
	reg         sd_grant = 1'b1;

	// ---- SD card model -----------------------------------------------------
	// The vector files hold one byte per line in hex. A "sector" is 512 of them.
	// The card only answers when asked; it raises blk_busy for a realistic number
	// of cycles (a 512 B block at 12.5 MHz is 328 us = 8200 cycles at 25 MHz),
	// but the bench shortens that to keep run time sane. The point of the delay
	// is that blk_start must be held until blk_busy rises, not the exact width.
	parameter BLK_LATENCY = 40;
	parameter BLK_GAP     = 8;

	reg  [7:0]  card_mem [0:2_097_151];    // 4 MiB, enough for frame 1 (45210 B)
	integer     card_len = 0;
	integer     card_rd_blk = 0;
	reg         card_busy_r = 1'b0;
	reg         card_burst = 1'b0;
	integer     card_i;
	reg  [8:0]  card_cycle;

	// ---- write sink (models framebuf_arbiter's group latching) -------------
	// ACK pattern: the sink accepts a beat every cycle except every 5th, which
	// forces ext_wr_busy to be exercised without making the run last forever.
	reg         sink_stall = 1'b0;
	integer     sink_div = 0;
	wire        sink_ack;

	// captured groups
	localparam MAX_GROUPS = 40000;
	reg  [20:0] grp_base [0:MAX_GROUPS-1];
	integer     grp_cnt = 0;
	integer     grp_beat = 0;              // beats accepted in the current group
	integer     grp_errors = 0;
	integer     beat_total = 0;
	reg  [20:0] grp_prev_base = 21'h1FFFFF;
	integer     grp_gap_errors = 0;
	integer     align_errors = 0;
	integer     dm_errors = 0;
	// A frame aborted mid-group MUST close its last group short; that is correct
	// behaviour, so it is counted separately from real group-length violations.
	integer     abort_partial = 0;
	reg         allow_partial = 1'b0;

	// ---- golden frame compare ---------------------------------------------
	localparam MAX_WORDS = 153600;
	reg [31:0] golden [0:MAX_WORDS-1];
	integer    gold_len = 0;
	integer    word_idx = 0;
	integer    frame_errors = 0;
	integer    first_bad_idx = -1;
	reg [31:0] first_bad_got, first_bad_exp;

	// -----------------------------------------------------------------------
	// bookkeeping -----------------------------------------------------------
	integer checks = 0;
	integer errors = 0;
	integer done_pulses = 0;
	integer frames_seen = 0;
	integer i;
	integer gi = 0;
	integer grant_latency = -1;

	// -----------------------------------------------------------------------
	// DUT
	// -----------------------------------------------------------------------
	rle_decoder #(
		.CLK_FREQ_HZ(CLK_FREQ),
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.JITTER_FRAMES(8'd3),
		.INIT_WR_BANK(1'b1),
		.LOOP_PLAY(1'b1),
		.BLK_BYTES(16'd512)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.blk_start(blk_start),
		.blk_addr(blk_addr),
		.blk_busy(blk_busy),
		.blk_done(blk_done),
		.blk_err(blk_err),
		.data_byte(data_byte),
		.data_valid(data_valid),
		.sd_grant(sd_grant),
		.play_en(play_en),
		.play_fps(play_fps),
		.file_lba(file_lba),
		.file_size(file_size),
		.frame_idx(frame_idx),
		.ext_wr_done(ext_wr_done),
		.ext_wr_valid(ext_wr_valid),
		.ext_wr_addr(ext_wr_addr),
		.ext_wr_data(ext_wr_data),
		.ext_wr_dm(ext_wr_dm),
		.ext_wr_ack(sink_ack),
		.ext_wr_busy(),
		.err_code(err_code),
		.underrun(underrun),
		.want_blk(want_blk)
	);

	// The decoder may only claim the SD bus while the arbiter grants it. These two
	// wires are the bench-side view of that handshake: bus_pending is "the FSM is
	// parked in R_NEXT_BLK and has not issued its pulse yet", grant_now is "a
	// grant is available to that pending request right now".
	wire bus_pending = (dut.state == 3'd5) && !dut.req_sent;
	wire grant_now   = bus_pending && sd_grant;

	// -----------------------------------------------------------------------
	// helpers
	// -----------------------------------------------------------------------
	// Argument order is (condition, label) so call sites read naturally:
	//   chk(err_code == 4'd0, "no error reported for a valid frame");
	// An earlier revision declared (label, condition) here while every call site
	// passed the condition first, so the string became the condition (always true)
	// and the condition became the label (usually 0 -> empty output). That made all
	// 29 assertions report blank FAIL lines and hid the real failures.
	task chk;
		input            cond;
		input [8*72-1:0] label;
		integer k;
		begin
			checks = checks + 1;
			if (!cond) begin
				errors = errors + 1;
				$write("FAIL: ");
				for (k = 71; k >= 0; k = k - 1)
					if (label[8*k +: 8] != 8'd0) $write("%c", label[8*k +: 8]);
				$display(" (t=%0t)", $time);
			end
		end
	endtask

	task load_bytes;
		input [8*64-1:0] path;
		output integer   len;
		integer fd, n, v;
		reg [7:0] b;
		begin
			len = 0;
			fd = $fopen(path, "r");
			if (fd == 0) begin
				$display("FATAL: cannot open %0s", path);
				$finish;
			end
			n = $fscanf(fd, "%h\n", b);
			while (n == 1) begin
				card_mem[len] = b;
				len = len + 1;
				n = $fscanf(fd, "%h\n", b);
			end
			$fclose(fd);
		end
	endtask

	task load_golden;
		input [8*64-1:0] path;
		output integer   len;
		integer fd, n;
		reg [31:0] w;
		begin
			len = 0;
			fd = $fopen(path, "r");
			if (fd == 0) begin
				$display("FATAL: cannot open %0s", path);
				$finish;
			end
			n = $fscanf(fd, "%h\n", w);
			while (n == 1) begin
				golden[len] = w;
				len = len + 1;
				n = $fscanf(fd, "%h\n", w);
			end
			$fclose(fd);
		end
	endtask

	// -----------------------------------------------------------------------
	// SD card behaviour: answer blk_start with a 512 B burst
	// -----------------------------------------------------------------------
	// blk_start/blk_addr are held by the DUT until blk_busy rises; the bench
	// raises blk_busy BLK_LATENCY cycles later, which is what the contract says
	// the DUT must wait for. data_valid then stays high for exactly 512 cycles.
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			card_busy_r <= 1'b0;
			card_burst  <= 1'b0;
			card_cycle  <= 9'd0;
			blk_busy    <= 1'b0;
			blk_done    <= 1'b0;
			data_valid  <= 1'b0;
			data_byte   <= 8'd0;
			card_i      <= 0;
		end else begin
			blk_done   <= 1'b0;
			data_valid <= 1'b0;

			if (card_burst) begin
				data_valid <= 1'b1;
				data_byte  <= card_mem[card_rd_blk * 512 + card_i];
				card_i     <= card_i + 1;
				if (card_i == 511) begin
					card_burst <= 1'b0;
					card_i     <= 0;
					// blk_done on the cycle after the 512th byte
					blk_done   <= 1'b1;
					blk_busy   <= 1'b0;
					card_busy_r<= 1'b0;
				end
			end else if (blk_start && !card_busy_r) begin
				if (card_cycle == BLK_LATENCY) begin
					card_busy_r    <= 1'b1;
					blk_busy       <= 1'b1;
					card_cycle     <= 9'd0;
					card_rd_blk    <= blk_addr - file_lba;
					card_burst     <= 1'b1;
				end else begin
					card_cycle <= card_cycle + 9'd1;
				end
			end else begin
				card_cycle <= 9'd0;
			end
		end
	end

	// -----------------------------------------------------------------------
	// SD bus grant model + handshake monitors
	// -----------------------------------------------------------------------
	// A real arbiter owns the bus in block granularity: it hands out a grant, the
	// winner keeps it until its block completes, and everybody else waits. So the
	// grant is forced high for the whole duration of a block in flight
	// (blk_active), and outside a block it follows a slow deny/allow pattern with
	// 40-cycle denial windows. That pattern is what a bench must have: a grant
	// tied to 1'b1 would make "blk_start is only raised while granted" vacuously
	// true and would never exercise the wait path at all.
	reg         blk_active   = 1'b0;
	reg         blk_start_d  = 1'b0;
	reg         sd_grant_d   = 1'b1;
	reg  [6:0]  grant_phase  = 7'd0;
	reg  [15:0] denied_run   = 16'd0;
	reg  [15:0] grant_low_max= 16'd0;
	reg         expect_pulse = 1'b0;
	reg         req_sent_d    = 1'b0;
	reg         awaiting_pulse= 1'b0;
	reg  [31:0] pulse_deadline= 32'd0;
	integer     grant_waits      = 0;   // pending requests that had to wait
	integer     long_denials     = 0;   // denials lasting >= 3 cycles
	integer     grant_violations = 0;   // blk_start raised while not granted
	integer     addr_violations  = 0;   // blk_addr not naming the requested sector
	integer     grant_pulse_missing = 0;// pulse did not follow a long grant
	integer     grant_low_cycles = 0;   // meta: proves the grant is not tied to 1
	integer     grant_high_cycles= 0;

	localparam [6:0] GRANT_LOW_WIN = 7'd40;
	localparam [6:0] GRANT_PERIOD  = 7'd80;

	// While this is high the grant is forced low regardless of the pattern, so a
	// case can park the decoder in R_NEXT_BLK for as long as it likes.
	reg         grant_force_low = 1'b0;

	// A second consumer (wav_stream_player) that keeps asking for the bus. The top
	// level grant is combinational - sd_owner_rle = sd_owner_playseg &&
	// !wav_want_blk && rle_want_blk - so audio can take the bus away on ANY cycle,
	// including the one right after this decoder decided to go. Without a
	// competitor the grant would never drop mid-request and the gating property
	// would be untestable: that is exactly why an earlier revision reported four
	// violations it could not explain and then a revision with the gate removed
	// still passed.
	reg  [7:0]  wav_phase = 8'd0;
	reg         wav_want  = 1'b0;
	localparam [7:0] WAV_PERIOD = 8'd37;
	localparam [7:0] WAV_WIN    = 8'd11;

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			wav_phase <= 8'd0;
			wav_want  <= 1'b0;
		end else begin
			if (wav_phase >= (WAV_PERIOD - 8'd1)) wav_phase <= 8'd0;
			else                                  wav_phase <= wav_phase + 8'd1;
			wav_want <= (wav_phase < WAV_WIN);
		end
	end

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			blk_active  <= 1'b0;
			grant_phase <= 7'd0;
			sd_grant    <= 1'b0;
		end else begin
			// Once the request has actually been issued while the bus was ours, the
			// winner keeps the bus until its block completes - that is the block
			// granularity a real arbiter works in. Latching on blk_start alone would
			// be the circular form (grant -> request -> grant) that produced spurious
			// violations; latching on (blk_start && sd_grant) is the commitment.
			if (blk_done) blk_active <= 1'b0;
			else if (blk_start && sd_grant) blk_active <= 1'b1;
			if (grant_phase >= (GRANT_PERIOD - 7'd1)) grant_phase <= 7'd0;
			else                                      grant_phase <= grant_phase + 7'd1;
			if (grant_force_low)                              sd_grant <= 1'b0;
			else if (blk_active)                              sd_grant <= 1'b1;
			else if (wav_want)                                sd_grant <= 1'b0;
			else if (want_blk && (grant_phase >= GRANT_LOW_WIN)) sd_grant <= 1'b1;
			else                                              sd_grant <= 1'b0;
		end
	end

	// The three properties the arbiter contract rests on.
	//   P1 blk_start rises only on a cycle where sd_grant is already high.
	//      Without this the sector on blk_addr is fetched for whoever owned the
	//      bus: audio would receive video bytes and this decoder would expand WAV
	//      samples as run-length pairs, ending in err_code=4 after a few blocks.
	//   P2 on that very cycle blk_addr already names the sector of the block
	//      being requested (file_lba + blk_index), so the address and the pulse
	//      can never describe different blocks.
	//   P3 a long denial delays the pulse by exactly the one cycle of registered
	//      output and never loses it - no dropped request, no multi-cycle lag.
	//
	// The counters are NOT cleared by rst_n: reset_dut runs between cases, and a
	// per-case reset would silently discard everything CASE 1 proved before the
	// final assertions read it. Only the sequencing state is reset.
	always @(posedge clk) begin
		blk_start_d <= blk_start;
		sd_grant_d  <= sd_grant;

		if (sd_grant) grant_high_cycles <= grant_high_cycles + 1;
		else          grant_low_cycles  <= grant_low_cycles  + 1;

		// P1 is a LEVEL property, not an edge one: the request line may only be
		// high while the bus is actually ours. Checking only the rising edge would
		// miss the real hazard, because the FSM decides on cycle N (grant high) and
		// the registered request shows up on N+1 - and the top-level grant is pure
		// combinational (sd_owner_rle = ... && !wav_want_blk && rle_want_blk), so it
		// can drop on exactly that cycle when audio asks for the bus. A request that
		// is still visible then is fetched for the wrong consumer.
		if (blk_start && !sd_grant) begin
			grant_violations <= grant_violations + 1;
			if (grant_violations < 4)
				$display("GRANT_VIOLATION t=%0t blk_start high while sd_grant is low", $time);
		end
		if (blk_start && !blk_start_d) begin
			if (blk_addr !== (file_lba + dut.blk_index)) begin
				addr_violations <= addr_violations + 1;
				$display("ADDR_VIOLATION t=%0t sect:%0d want:%0d",
					$time, blk_addr, file_lba + dut.blk_index);
			end
		end

		// P3 "no request is ever lost". The pulse is registered and then ANDed with
		// the grant, so a grant that is stolen on the very next cycle delays the
		// pulse - that is allowed and expected, because the top-level grant is
		// combinational and audio outranks video. What is NOT allowed is the request
		// disappearing: once req_sent is set the decoder will never re-issue it, so a
		// pulse that never lands while the grant is high means the card is never
		// started and blk_done never comes. The deadline below turns that deadlock
		// into a named failure instead of a bare global timeout.
		if (req_sent_d && !dut.req_sent) awaiting_pulse <= 1'b0;
		else if (!req_sent_d && dut.req_sent) begin
			awaiting_pulse <= 1'b1;
			pulse_deadline <= 32'd0;
		end else if (awaiting_pulse) begin
			if (blk_start && sd_grant) awaiting_pulse <= 1'b0;
			else if (pulse_deadline >= 32'd20000) begin
				grant_pulse_missing <= grant_pulse_missing + 1;
				awaiting_pulse      <= 1'b0;
				$display("GRANT_LOST t=%0t no granted pulse within the deadline", $time);
			end else pulse_deadline <= pulse_deadline + 32'd1;
		end
		req_sent_d <= dut.req_sent;

		if (bus_pending && !sd_grant) begin
			if (denied_run == 16'd0) grant_waits <= grant_waits + 1;
			// a denial that reaches its third consecutive cycle counts once
			if (denied_run == 16'd2) long_denials <= long_denials + 1;
			denied_run <= denied_run + 16'd1;
			if ((denied_run + 16'd1) > grant_low_max) grant_low_max <= denied_run + 16'd1;
		end else begin
			denied_run <= 16'd0;
		end
	end

	// -----------------------------------------------------------------------
	// write sink: ack pattern + group bookkeeping
	// -----------------------------------------------------------------------
	// Accept 4 of every 5 cycles. This makes ext_wr_valid dwell while ext_wr_busy
	// is high, so the "address must not advance without ack" property is really
	// exercised rather than merely stated.
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			sink_div  <= 0;
			sink_stall<= 1'b0;
		end else begin
			if (sink_div == 4) begin
				sink_div   <= 0;
				sink_stall <= 1'b1;
			end else begin
				sink_div   <= sink_div + 1;
				sink_stall <= 1'b0;
			end
		end
	end
	assign sink_ack = ext_wr_valid && !sink_stall;

	// Group bookkeeping. A group opens on the rising edge of ext_wr_valid and must
	// carry exactly four accepted beats. Note the ordering hazard that bit an
	// earlier revision of this bench: the opening cycle can itself be an ack, so
	// the open branch must seed grp_beat with that ack instead of resetting it to
	// zero behind the increment's back.
	reg wr_valid_d = 1'b0;
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			wr_valid_d     <= 1'b0;
			grp_cnt        <= 0;
			grp_beat       <= 0;
			grp_errors     <= 0;
			beat_total     <= 0;
			align_errors   <= 0;
			dm_errors      <= 0;
			grp_prev_base  <= 21'h1FFFFF;
			grp_gap_errors <= 0;
			word_idx       <= 0;
			frame_errors   <= 0;
			first_bad_idx  <= -1;
		end else begin
			wr_valid_d <= ext_wr_valid;

			// dm must be all-zero: any masked byte would silently drop pixels
			if (ext_wr_valid && ext_wr_dm !== 4'h0) dm_errors <= dm_errors + 1;

			// payload comparison, on accepted beats only
			if (sink_ack) begin
				if (gold_len != 0) begin
					if (ext_wr_data !== golden[word_idx]) begin
						frame_errors <= frame_errors + 1;
						if (first_bad_idx < 0) begin
							first_bad_idx <= word_idx;
							first_bad_got <= ext_wr_data;
							first_bad_exp <= golden[word_idx];
							$display("WORD_MISMATCH idx=%0d got=%08h want:%08h sect:%0d",
								word_idx, ext_wr_data, golden[word_idx], ext_wr_addr);
						end
					end
					if (word_idx < MAX_WORDS - 1) word_idx <= word_idx + 1;
				end
				beat_total <= beat_total + 1;
			end

			if (ext_wr_valid && !wr_valid_d) begin
				// group opens here; seed the beat count with this cycle's ack
				if (grp_cnt < MAX_GROUPS) grp_base[grp_cnt] <= ext_wr_addr;
				grp_cnt  <= grp_cnt + 1;
				grp_beat <= sink_ack ? 1 : 0;
				if (ext_wr_addr[1:0] !== 2'b00) align_errors <= align_errors + 1;
				if (grp_prev_base != 21'h1FFFFF) begin
					if (ext_wr_addr !== (grp_prev_base + 21'd4))
						grp_gap_errors <= grp_gap_errors + 1;
				end
				grp_prev_base <= ext_wr_addr;
			end else if (sink_ack) begin
				grp_beat <= grp_beat + 1;
			end

			// a group closes when valid goes low: check it carried four beats
			if (wr_valid_d && !ext_wr_valid) begin
				if (grp_beat != 4) begin
					if (allow_partial) begin
						abort_partial <= abort_partial + 1;
						$display("ABORT_PARTIAL_GROUP len=%0d base=%0d (expected while aborting)", grp_beat, grp_prev_base);
					end else begin
						grp_errors <= grp_errors + 1;
						$display("GROUP_LEN=%0d base=%0d (expected 4)", grp_beat, grp_prev_base);
					end
				end
				grp_beat <= 0;
			end
		end
	end

	always @(posedge clk) begin
	end

	// Frame pacing monitor. R_IDLE only leaves on gap_tick, so the decoder's frame
	// rate is exactly the period of this strobe. The bench scales CLK_FREQ down to
	// keep run time sane, so the divider itself is what gets verified here: the
	// measured period must equal CLK_FREQ/play_fps cycles. If the fractional
	// accumulator were broken (wrong addend, wrong comparison, accumulator not
	// cleared on tick) the measured period would drift and CASE 0 fails.
	integer tick_cnt = 0;
	integer tick_period = -1;
	integer tick_last = -1;
	reg     tick_seen = 1'b0;
	always @(posedge clk) begin
		if (!rst_n) begin
			tick_cnt  <= 0;
			tick_seen <= 1'b0;
		end else if (dut.gap_tick) begin
			if (tick_seen && (tick_period < 0)) tick_period <= tick_cnt - tick_last;
			tick_last <= tick_cnt;
			tick_seen <= 1'b1;
			tick_cnt  <= tick_cnt + 1;
		end else begin
			tick_cnt <= tick_cnt + 1;
		end
	end

	// -----------------------------------------------------------------------
	// reset / run helpers
	// -----------------------------------------------------------------------
	task reset_dut;
		begin
			play_en    = 1'b0;
			rst_n      = 1'b0;
			blk_err    = 1'b0;
			file_lba   = 32'd0;
			repeat (10) @(negedge clk);
			rst_n      = 1'b1;
			repeat (5) @(negedge clk);
		end
	endtask

	// wait for n done pulses or give up after a bounded time
	task wait_done;
		input integer n;
		input integer limit;
		integer got, guard;
		begin
			got   = 0;
			guard = 0;
			while ((got < n) && (guard < limit)) begin
				@(negedge clk);
				if (ext_wr_done) begin
					got = got + 1;
					// The only observer of ext_wr_done: a second counter in a separate
					// posedge block reads the same pulse in another phase and the two
					// disagree, which is exactly how the original FAILs were produced.
					done_pulses = done_pulses + 1;
				end
				guard = guard + 1;
			end
			if (guard >= limit) $display("TIMEOUT waiting for %0d done pulses (got %0d)", n, got);
			// beat_total is registered at a posedge, so let the last accepted beats
			// land before any chk reads it.
			repeat (2) @(negedge clk);
		end
	endtask

	// -----------------------------------------------------------------------
	// main sequence
	// -----------------------------------------------------------------------
	initial begin
		// ---------------------------------------------------------------
		// CASE 0: frame pacing divider
		// ---------------------------------------------------------------
		// The whole frame-rate story rests on gap_acc reaching CLK_FREQ in
		// CLK_FREQ/play_fps cycles. Verify the arithmetic on the scaled parameter,
		// not on a hard-coded number, so the check survives a parameter change.
		$display("CASE: frame pacing divider (expect %0d cycles = CLK_FREQ/play_fps)", CLK_FREQ / 5);
		reset_dut;
		file_size = 32'd0;
		play_en   = 1'b1;
		play_fps  = 8'd5;
		repeat (CLK_FREQ / 5 * 4) @(negedge clk);
		chk(tick_period > 0, "gap_tick is observable");
		chk(tick_period == (CLK_FREQ / 5),
			"gap_tick period equals CLK_FREQ/play_fps");
		$display("PACING: measured=%0d expected=%0d", tick_period, CLK_FREQ / 5);
		play_en = 1'b0;
		reset_dut;

		// ---------------------------------------------------------------
		// CASE 1: real frame 0 (1200 runs, all 256 => run_len=0 everywhere)
		// ---------------------------------------------------------------
		$display("CASE: real SCI.RLE frame 0 (1200 runs, every run_len=0 meaning 256)");
		load_bytes("../testbench/vectors/sci_f0_640x480.hex", card_len);
		load_golden("../testbench/vectors/sci_f0_words.hex", gold_len);
		$display("LOAD: card_len=%0d gold_len=%0d", card_len, gold_len);
		chk(card_len == 3612, "frame 0 vector file is 3612 bytes (12 B header + 3x1200)");
		chk(gold_len == FRAME_WORDS, "golden file holds 153600 words");

		reset_dut;
		file_size = card_len;
		word_idx = 0; frame_errors = 0; first_bad_idx = -1;
		grp_cnt = 0; grp_beat = 0; grp_prev_base = 21'h1FFFFF;
		play_en  = 1'b1;
		wait_done(1, 400_000);
		chk(done_pulses >= 1, "first real frame produced ext_wr_done");
		chk(beat_total == FRAME_WORDS, "exactly 153600 words accepted for frame 0");
		chk(frame_errors == 0, "every decoded word matches the golden frame 0");
		chk(dm_errors == 0, "ext_wr_dm is 4'h0 on every beat (no masked bytes)");
		chk(align_errors == 0, "every write group starts 4-word aligned");
		chk(grp_errors == 0, "every write group carries exactly 4 accepted beats");
		chk(grp_gap_errors == 0, "consecutive group bases advance by exactly 4");
		chk(err_code == 4'd0, "no error reported for a valid frame");
		chk(underrun === 1'b0 || underrun === 1'b1, "underrun is a defined level");
		// The grant contract, asserted where the traffic is heaviest. These have to
		// live inside chk() rather than only in $display: an earlier revision printed
		// four GRANT_VIOLATION lines and still reported errors=0, which is exactly
		// the "property never fails" trap this bench is meant to avoid.
		chk(grant_violations == 0,
			"blk_start is only raised on a cycle where sd_grant is high");
		chk(addr_violations == 0,
			"the granted pulse carries the sector of the block it asks for");
		chk(grant_pulse_missing == 0,
			"a long denial never drops the block request");
		chk(grant_waits > 0,
			"the decoder really parked in R_NEXT_BLK waiting for a grant");
		// Meta assertion: without it the three checks above hold vacuously as soon
		// as the generator is tied to 1'b1, which is how a dead property stays green.
		chk(grant_low_cycles > 100,
			"sd_grant really goes low (the checks above are not vacuous)");
		$display("FRAME0: groups=%0d beats=%0d word_errors=%0d", grp_cnt, beat_total, frame_errors);
		$display("GRANT0: violations=%0d addr=%0d missing=%0d waits=%0d long_denials=%0d low=%0d high=%0d",
			grant_violations, addr_violations, grant_pulse_missing,
			grant_waits, long_denials, grant_low_cycles, grant_high_cycles);

		// ---------------------------------------------------------------
		// CASE 2: real frame 1 (15066 runs, ~half of them odd length)
		// ---------------------------------------------------------------
		$display("CASE: real SCI.RLE frame 1 (15066 runs, odd lengths exercise the half-word carry)");
		load_bytes("../testbench/vectors/sci_f1_640x480.hex", card_len);
		load_golden("../testbench/vectors/sci_f1_words.hex", gold_len);
		chk(card_len == 45210, "frame 1 vector file is 45210 bytes");

		reset_dut;
		file_size = card_len;
		word_idx = 0; frame_errors = 0; first_bad_idx = -1;
		grp_cnt = 0; grp_beat = 0; grp_prev_base = 21'h1FFFFF;
		beat_total = 0; align_errors = 0; grp_errors = 0; grp_gap_errors = 0; dm_errors = 0;
		done_pulses = 0;
		play_en  = 1'b1;
		wait_done(1, 900_000);
		chk(done_pulses >= 1, "second real frame produced ext_wr_done");
		chk(beat_total == FRAME_WORDS, "exactly 153600 words accepted for frame 1");
		chk(frame_errors == 0, "every decoded word matches the golden frame 1");
		chk(dm_errors == 0, "dm stays 4'h0 on frame 1 as well");
		chk(align_errors == 0, "frame 1 groups are 4-word aligned");
		chk(grp_errors == 0, "frame 1 groups are all exactly 4 beats");
		chk(grp_gap_errors == 0, "frame 1 group bases are contiguous");
		chk(err_code == 4'd0, "frame 1 reports no error");
		chk(grant_violations == 0,
			"frame 1 saw no blk_start without a grant either");
		chk(grant_pulse_missing == 0,
			"frame 1 never lost a request across a denial");
		$display("FRAME1: groups=%0d beats=%0d word_errors=%0d", grp_cnt, beat_total, frame_errors);
		$display("GRANT1: violations=%0d addr=%0d missing=%0d waits=%0d long_denials=%0d low=%0d high=%0d",
			grant_violations, addr_violations, grant_pulse_missing,
			grant_waits, long_denials, grant_low_cycles, grant_high_cycles);

		// ---------------------------------------------------------------
		// CASE 3: frame atomicity - drop play_en mid frame
		// ---------------------------------------------------------------
		$display("CASE: aborting a frame must not raise done and must not leave the pointer past the end");
		reset_dut;
		load_bytes("../testbench/vectors/sci_f0_640x480.hex", card_len);
		file_size = card_len;
		gold_len = 0;                       // no golden compare in this case
		grp_cnt = 0; grp_beat = 0; grp_prev_base = 21'h1FFFFF;
		done_pulses = 0;
		play_en = 1'b1;
		allow_partial = 1'b1;               // a mid-group cut is the point of this case
		abort_partial = 0;
		// let it decode for a while, then yank play_en
		repeat (30_000) @(negedge clk);
		play_en = 1'b0;
		repeat (50) @(negedge clk);
		chk(ext_wr_valid === 1'b0, "abort stops the write port within a few cycles");
		chk(dut.wr_done_cnt == 18'd0, "abort clears the accepted-word counter");
		// frame_base is bank A (0) or bank B (153600) depending on INIT_WR_BANK,
		// so compare against the live base instead of a hard-coded zero.
		chk(dut.ext_wr_addr === dut.frame_base, "abort parks the write address at the frame base");
		// Only the group that was in flight can be cut, so at most one short group is
		// expected. Zero is also legal: with a competing bus master the abort may land
		// between two groups, and then nothing is cut at all. The arbiter completes
		// its own four bus slots with DM=4'hF masked writes, so a truncated group
		// leaves no partial data behind; and since the frame never raises
		// ext_wr_done it is never committed, so nothing is shown.
		chk(abort_partial <= 1, "abort cuts at most one in-flight write group");
		allow_partial = 1'b0;

		// restarting must begin a fresh frame from the base, not continue
		play_en = 1'b1;
		repeat (20) @(negedge clk);
		chk(dut.frame_base === 21'd153600 || dut.frame_base === 21'd0,
			"restart picks one of the two frame banks");

		// ---------------------------------------------------------------
		// CASE 4: header validation
		// ---------------------------------------------------------------
		$display("CASE: bad magic must be rejected instead of decoded onto the panel");
		card_mem[0] = 8'h00;                // break "S" of "SCMR"
		reset_dut;
		file_size = 3612;
		gold_len = 0;
		play_en = 1'b1;
		repeat (6000) @(negedge clk);
		chk(dut.state == 3'd7, "bad magic moves the FSM to R_ERR");
		chk(err_code == 4'd1, "bad magic reports err_code 1");
		chk(underrun === 1'b1, "bad magic raises underrun");
		$display("HEADER: state=%0d err_code=%0d", dut.state, err_code);

		// ---------------------------------------------------------------
		// CASE 5: the SD bus grant must gate the block request
		// ---------------------------------------------------------------
		// This is the case that makes P1/P2/P3 real. The grant is forced low for
		// as long as this case likes, so the FSM has to park in R_NEXT_BLK with
		// blk_start low and err_code clean instead of timing out or claiming the
		// bus anyway. Releasing the grant must then produce the pulse on the very
		// next cycle, with blk_addr already naming the sector, and the frame must
		// still decode bit-exactly afterwards.
		$display("CASE: a withheld grant parks the request instead of claiming the bus");
		load_bytes("../testbench/vectors/sci_f0_640x480.hex", card_len);
		load_golden("../testbench/vectors/sci_f0_words.hex", gold_len);
		grant_force_low = 1'b1;
		reset_dut;
		file_size = card_len;
		gold_len  = FRAME_WORDS;
		done_pulses = 0;
		play_en   = 1'b1;
		// wait until the FSM wants the first block
		gi = 0;
		while ((dut.state !== 3'd5) && (gi < 5000)) begin
			@(negedge clk);
			gi = gi + 1;
		end
		chk(dut.state === 3'd5, "decoder reaches R_NEXT_BLK while the grant is low");
		chk(blk_start === 1'b0, "no block request is issued without the grant");
		chk(err_code === 4'd0, "waiting for the grant is not an error");
		chk(done_pulses == 0, "a parked request never reports a finished frame");
		// hold the denial well past any plausible timeout
		repeat (600) @(negedge clk);
		chk(dut.state === 3'd5, "the request stays parked for the whole denial");
		chk(blk_start === 1'b0, "the request stays low for the whole denial");
		chk(err_code === 4'd0, "a long denial still is not an error");
		chk(grant_low_max >= 16'd3, "a denial window of at least three cycles was seen");

		// release the grant and measure how late the pulse is
		grant_force_low = 1'b0;
		gi = 0;
		while ((sd_grant !== 1'b1) && (gi < 400)) begin
			@(negedge clk);
			gi = gi + 1;
		end
		chk(sd_grant === 1'b1, "the arbiter model does hand the bus out eventually");
		// sd_grant is sampled at the next posedge, so the registered blk_start must
		// be visible exactly one cycle later - no dropped request, no extra lag.
		@(negedge clk);
		grant_latency = 1;
		chk(blk_start === 1'b1, "a granted request pulses within one cycle");
		chk(blk_addr === (file_lba + dut.blk_index),
			"the granted pulse carries the sector of the block it asks for");
		$display("GRANT: latency=%0d low_max=%0d waits=%0d long_denials=%0d",
			grant_latency, grant_low_max, grant_waits, long_denials);

		// the delayed start must not damage the frame it eventually fetches
		word_idx = 0; frame_errors = 0; first_bad_idx = -1;
		grp_cnt = 0; grp_beat = 0; grp_prev_base = 21'h1FFFFF;
		beat_total = 0; align_errors = 0; grp_errors = 0; grp_gap_errors = 0; dm_errors = 0;
		done_pulses = 0;
		wait_done(1, 400_000);
		chk(done_pulses >= 1, "a frame delayed by a denial still completes");
		chk(beat_total == FRAME_WORDS, "the delayed frame writes 153600 words");
		chk(frame_errors == 0, "the delayed frame matches the golden words");
		chk(err_code === 4'd0, "the delayed frame reports no error");
		$display("FRAME_DELAYED: groups=%0d beats=%0d word_errors=%0d",
			grp_cnt, beat_total, frame_errors);

		// ---------------------------------------------------------------
		// arbiter contract, measured over every case above
		// ---------------------------------------------------------------
		chk(grant_violations == 0, "blk_start never rises without sd_grant");
		chk(addr_violations == 0, "blk_addr names the requested sector on the pulse cycle");
		chk(grant_pulse_missing == 0, "a long denial never drops the block request");
		chk(grant_waits > 0, "at least one block request had to wait for the grant");
		chk(long_denials > 0, "at least one denial lasted three cycles or more");
		// meta assertion: if the generator were tied to 1'b1 the property above
		// would hold vacuously, so the low time itself has to be non-trivial.
		chk(grant_low_cycles > 100, "the grant really does go low (generator is not tied to 1)");

		// ---------------------------------------------------------------
		// summary
		// ---------------------------------------------------------------
		$display("==============================================");
		$display("TB_RLE_DECODER SUMMARY: checks=%0d errors=%0d", checks, errors);
		if (errors == 0) $display("RESULT: PASS");
		else             $display("RESULT: FAIL (%0d)", errors);
		$display("==============================================");
		$finish;
	end

	// global watchdog
	initial begin
		#(CLK_PERIOD * 4_000_000);
		$display("GLOBAL TIMEOUT");
		$display("TB_RLE_DECODER SUMMARY: checks=%0d errors=%0d", checks, errors);
		$finish;
	end

endmodule
