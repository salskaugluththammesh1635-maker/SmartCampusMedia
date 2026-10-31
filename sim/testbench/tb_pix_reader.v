// =============================================================================
// tb_pix_reader — 使用真实 video_timing_gen 的帧缓冲读出自检
// =============================================================================
// 默认缩小几何以快速验证全部边界；用顶层参数可复跑 640x480。
// 消隐坐标由现有 VTG 真实归零；参考像素只使用 VTG 的坐标，不按 valid 自增。
// 内存预置是测试夹具，不代表 SD/BMP/顶层写入已集成；刷新语义仅验证行为模型。
`timescale 1ns / 1ps
module tb_pix_reader;
	parameter PIX_PER_LINE = 64;
	parameter LINES = 8;
	parameter H_FP = 8;
	parameter H_SYNC = 16;
	parameter H_BP = 8;
	parameter V_FP = 6;
	parameter V_SYNC = 2;
	parameter V_BP = 4;
	parameter FIFO_AW = 6;
	parameter LEVEL_HI = 48;
	parameter STRESS = 1;
	parameter CLK_SDR_PERIOD = 25.0;
	localparam CLK_PIX_PERIOD = 40.0;
	localparam H_TOTAL = PIX_PER_LINE + H_FP + H_SYNC + H_BP;
	localparam V_TOTAL = LINES + V_FP + V_SYNC + V_BP;
	localparam FRAME_WORDS = PIX_PER_LINE * LINES / 2;
localparam FRAME_BASE = 21'd0;
	localparam FRAME_GROUPS = FRAME_WORDS / 4;
	localparam WAIT_BOUND = H_TOTAL * V_TOTAL * 2;
	reg clk_sdr = 1'b0;
	reg clk_pix = 1'b0;
	reg rst_n_sdr = 1'b0;
	reg rst_n_pix = 1'b0;
	reg stall = 1'b0;
	reg write_load = 1'b0;
	reg check_en = 1'b0;
	reg row_only = 1'b0;
	integer frame_seed = 1;
	integer checks = 0;
	integer errors = 0;
	integer cases_done = 0;
	integer pixels_checked = 0;
	integer pixel_errors = 0;
	integer first_bad_x = -1;
	integer first_bad_y = -1;
	integer groups = 0;
	integer group_start = 0;
	integer level_peak = 0;
	integer written_words = 0;
	integer restart_count = 0;
	integer restart_start = 0;
	integer i;
	wire de, hs, vs, frame_start;
	wire [10:0] active_x;
	wire [9:0] active_y;
	wire rd_req, rd_ack, rd_valid, rd_idle, rd_restart_done, rd_restart;
	wire [31:0] rd_data;
	reg [20:0] rd_base = FRAME_BASE; // 由上层选定的显示帧首，本 TB 固定第 0 帧
	wire [15:0] pix_rgb565;
	wire pix_valid;
	wire [2:0] stat;
	wire init_done, ref_vld, sdr_busy, arb_busy, arb_err;
	wire app_wr_en, app_rd_en, wr_ack, sdr_rd_en;
	wire [20:0] app_wr_addr, app_rd_addr;
	wire [31:0] app_wr_din, sdr_rd_dout;
	wire [3:0] app_wr_dm;
	wire arb_ref_vld = ref_vld || stall;

	always #(CLK_SDR_PERIOD / 2.0) clk_sdr = ~clk_sdr;
	always #(CLK_PIX_PERIOD / 2.0) clk_pix = ~clk_pix;

	video_timing_gen #(
		.H_ACTIVE(PIX_PER_LINE), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
		.V_ACTIVE(LINES), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP)
	) u_vtg (
		.pixel_clk(clk_pix), .rst_n(rst_n_pix), .hs(hs), .vs(vs), .de(de),
		.active_x(active_x), .active_y(active_y), .frame_start(frame_start)
	);
	sdram_ctrl_wrap #(
		.SIM_MEM_WORDS(262144), .REFRESH_PERIOD(97)
	) u_ctrl (
		.clk(clk_sdr), .clk_sft(~clk_sdr), .rst_n(rst_n_sdr),
		.init_done(init_done), .ref_vld(ref_vld), .busy(sdr_busy),
		.app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
		.app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm),
		.app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
		.sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout),
		.sdram_clk(), .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(),
		.sdram_cas_n(), .sdram_we_n(), .sdram_ba(), .sdram_addr(),
		.sdram_dm(), .sdram_dq()
	);
	framebuf_arbiter #(
		.FRAME_WORDS(FRAME_WORDS), .WR_STARVE_LIMIT(32)
	) u_arb (
		.clk(clk_sdr), .rst_n(rst_n_sdr), .sdr_init_done(init_done),
		.ref_vld(arb_ref_vld), .wr_req(write_load), .wr_word_addr(21'd0),
		.wr_data(32'hA55A5AA5), .wr_dm(4'hF), .wr_ack(wr_ack),
		.rd_req(rd_req), .rd_data(rd_data), .rd_valid(rd_valid), .rd_ack(rd_ack),
		.rd_restart(rd_restart), .rd_base(rd_base), .rd_idle(rd_idle),
		.rd_restart_done(rd_restart_done), .app_wr_en(app_wr_en),
		.app_wr_addr(app_wr_addr), .app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm),
		.app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
		.sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout), .busy(arb_busy), .err(arb_err)
	);
	pix_reader #(
		.PIX_PER_LINE(PIX_PER_LINE), .FRAME_LINES(LINES),
		.FIFO_AW(FIFO_AW), .LEVEL_HI(LEVEL_HI)
	) dut (
		.clk_sdr(clk_sdr), .rst_n_sdr(rst_n_sdr), .rd_req(rd_req), .rd_ack(rd_ack),
		.rd_data(rd_data), .rd_valid(rd_valid), .rd_idle(rd_idle),
		.rd_restart_done(rd_restart_done), .rd_restart(rd_restart), .rd_base(rd_base),
		.pix_clk(clk_pix), .rst_n_pix(rst_n_pix), .de(de), .active_y(active_y),
		.pix_rgb565(pix_rgb565), .pix_valid(pix_valid), .stat(stat)
	);

	task chk;
		input condition;
		input [8*120-1:0] message;
		begin
			checks = checks + 1;
			if (condition !== 1'b1) begin
				errors = errors + 1;
				$display("FAIL: %0s t=%0t", message, $time);
			end
		end
	endtask

	function [15:0] expected_pixel;
		input integer x;
		input integer y;
		begin
			if (row_only) expected_pixel = y * 211 + frame_seed * 1009;
			else expected_pixel = x * 73 + y * 211 + frame_seed * 1009;
		end
	endfunction

	// 在消隐期开测试夹具，不用 DUT 数据/指针生成参考结果。
	task fill_frame;
		integer y, word_x, address;
		reg [31:0] word_data;
		begin
			chk(!de, "fixture updates occur outside visible pixels");
			for (y = 0; y < LINES; y = y + 1) begin
				for (word_x = 0; word_x < PIX_PER_LINE / 2; word_x = word_x + 1) begin
					address = y * (PIX_PER_LINE / 2) + word_x;
					word_data[15:0] = expected_pixel(word_x * 2, y);
					word_data[31:16] = expected_pixel(word_x * 2 + 1, y);
					u_ctrl.u_model.mem[address] = word_data;
				end
			end
		end
	endtask

	// 使用真实坐标找帧末；所有等待均有上限，边界在下降沿处理以消除竞争。
	task wait_blank;
		integer guard;
		begin
			guard = 0;
			@(negedge clk_pix);
			while (!(de && active_x == PIX_PER_LINE - 1 && active_y == LINES - 1)
				&& guard < WAIT_BOUND) begin
				@(negedge clk_pix);
				guard = guard + 1;
			end
			chk(guard < WAIT_BOUND, "bounded wait reaches final visible pixel");
			@(negedge clk_pix);
			chk(!de, "frame boundary is in blanking");
		end
	endtask

	task reset_system;
		integer guard;
		begin
			check_en = 1'b0;
			stall = 1'b0;
			write_load = 1'b0;
			@(negedge clk_pix);
			rst_n_sdr = 1'b0;
			rst_n_pix = 1'b0;
			repeat (20) @(negedge clk_pix);
			rst_n_sdr = 1'b1;
			repeat (5) @(negedge clk_pix);
			rst_n_pix = 1'b1;
			guard = 0;
			while (!init_done && guard < 256) begin
				@(negedge clk_sdr);
				guard = guard + 1;
			end
			chk(init_done, "controller reinitializes within bounded wait");
		end
	endtask

	task scan_frame;
		input [8*32-1:0] label;
		input allow_underflow;
		begin
			pixels_checked = 0;
			pixel_errors = 0;
			first_bad_x = -1;
			first_bad_y = -1;
			group_start = groups;
			restart_start = restart_count;
			level_peak = 0;
			check_en = 1'b1;
			wait_blank;
			check_en = 1'b0;
			chk(pixels_checked == PIX_PER_LINE * LINES, "entire frame checked against real VTG coordinates");
			chk(pixel_errors == 0, "every pixel matches without first-pixel or halfword phase loss");
			chk(groups - group_start >= FRAME_GROUPS, "read count supplies at least one complete frame");
			chk(groups - group_start <= FRAME_GROUPS + (LEVEL_HI + 7) / 4 + 4,
				"read count bounded by one frame plus conservative prefetch capacity");
			chk(restart_count - restart_start == 1, "exactly one completed restart per checked frame");
			chk(level_peak <= LEVEL_HI + 4, "Gray-synchronized water level respects reserved-group bound");
			chk(stat[1] === 1'b0, "no FIFO overflow in frame");
			chk(allow_underflow || stat[0] === 1'b0, "no unexpected sticky underflow");
			chk(!arb_err, "arbiter remains protocol-error free");
			$display("FRAME %0s: pixels=%0d mismatches=%0d groups=%0d level_peak=%0d restarts=%0d",
				label, pixels_checked, pixel_errors, groups - group_start, level_peak,
				restart_count - restart_start);
			if (first_bad_x >= 0)
				$display("FIRST_MISMATCH x=%0d y=%0d", first_bad_x, first_bad_y);
			cases_done = cases_done + 1;
		end
	endtask

	// 在 NBA 前观测：VTG 与 FIFO 都将在该边沿更新，参考不延迟 de 或坐标。
	always @(posedge clk_pix) begin
		if (rst_n_pix && check_en && de) begin
			pixels_checked = pixels_checked + 1;
			if (pix_valid !== 1'b1 || pix_rgb565 !== expected_pixel(active_x, active_y)) begin
				pixel_errors = pixel_errors + 1;
				if (first_bad_x < 0) begin
					first_bad_x = active_x;
					first_bad_y = active_y;
					$display("PIXEL_MISMATCH x=%0d y=%0d valid=%b got=%04h expected=%04h state=%0d",
						active_x, active_y, pix_valid, pix_rgb565,
						expected_pixel(active_x, active_y), dut.state);
				end
			end
		end
	end
	always @(posedge clk_sdr) begin
		if (rst_n_sdr) begin
			if (rd_ack) groups = groups + 1;
			if (wr_ack) written_words = written_words + 1;
			if (rd_restart_done) restart_count = restart_count + 1;
			if (check_en && dut.reserved_level > level_peak) level_peak = dut.reserved_level;
			if (app_wr_en && app_rd_en) chk(1'b0, "read/write commands never overlap");
			if (arb_ref_vld && (app_wr_en || app_rd_en)) chk(1'b0, "refresh blocks commands immediately");
			if (rd_ack && !app_rd_en) chk(1'b0, "group acknowledgement always names a real command");
		end
	end

	initial begin
		$display("CASE: real-VTG integration %0dx%0d dense refresh every 97 clocks", PIX_PER_LINE, LINES);
		reset_system;
		wait_blank;
		fill_frame;
		scan_frame("cold_alignment", 1'b0);
		for (i = 0; i < 3; i = i + 1) begin
			frame_seed = i + 2;
			fill_frame;
			scan_frame("changing_content", 1'b0);
		end
		row_only = 1'b1;
		frame_seed = 5;
		fill_frame;
		scan_frame("row_address_isolation", 1'b0);
		if (STRESS) begin
			row_only = 1'b0;
			frame_seed = 6;
			fill_frame;
			write_load = 1'b1;
			scan_frame("concurrent_masked_writes", 1'b0);
			write_load = 1'b0;
			chk(written_words > 0, "real write service occurs while display reads continue");
			$display("CASE: deliberate starvation, sticky underflow, next-frame realignment");
			begin : inject_stall
				integer guard;
				guard = 0;
				while (!(de && active_x == 0 && active_y == LINES / 2) && guard < WAIT_BOUND) begin
					@(negedge clk_pix);
					guard = guard + 1;
				end
				chk(guard < WAIT_BOUND, "bounded stall injection reaches mid-frame");
				stall = 1'b1;
				repeat (4 * (LEVEL_HI + 32)) @(negedge clk_pix);
				stall = 1'b0;
				chk(stat[0] === 1'b1, "deliberate no-service interval causes real sticky underflow");
			end
			wait_blank;
			frame_seed = 7;
			fill_frame;
			scan_frame("underflow_recovery", 1'b1);
			$display("CASE: simultaneous FIFO reset with staggered safe release");
			reset_system;
			wait_blank;
			frame_seed = 8;
			fill_frame;
			scan_frame("system_reset_recovery", 1'b0);
		end
		chk(cases_done >= 5, "all mandatory full-frame cases executed");
		$display("SUMMARY: checks=%0d errors=%0d cases=%0d geometry=%0dx%0d",
			checks, errors, cases_done, PIX_PER_LINE, LINES);
		if (errors == 0) $display("ALL CHECKS PASSED: tb_pix_reader");
		else $display("FAILED: tb_pix_reader errors=%0d", errors);
		$finish;
	end
	initial begin
		#(H_TOTAL * V_TOTAL * CLK_PIX_PERIOD * 24);
		$display("FAILED: tb_pix_reader global timeout");
		$finish;
	end
endmodule
