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
	// v4（T31）：长帧浸泡帧数。每帧都重新 P_RESTART，故每帧都是一次独立的
	// 「从帧首补水到窗口首行」的完整压力过程。默认 20 帧。
	parameter SOAK_FRAMES = 20;
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
	// v2（T4）：垂直行映射端口。缺省接恒等档（src_w=PIX_PER_LINE、src_h=LINES），
	// 与 v1 行为逐像素一致；V-03 用例再把 src_h 改成 LINES/2 验证倍行。
	reg [15:0] src_w = PIX_PER_LINE;
	reg [15:0] src_h = LINES;
	reg check_map = 1'b0;
	integer map_checked = 0;
	integer map_errors = 0;
	integer map_first_y = -1;
	// v3（Key9 第 1 步）：水平窗口降采样端口。缺省接满屏恒等档
	//（win_w=PIX_PER_LINE、win_h=LINES、off=0），与改造前逐拍等价；
	// 只有专门的窗口用例才把 win_w 收窄，验证窗口内外两条判据。
	reg [15:0] win_w = PIX_PER_LINE;
	reg [15:0] win_h = LINES;
	reg [15:0] win_off_x = 16'd0;
	reg [15:0] win_off_y = 16'd0;
	wire out_valid;
	reg check_k9 = 1'b0;      // 窗口用例的逐拍校验使能
	reg check_ident = 1'b0;   // 恒等红线：逐拍比对改造前像素语义
	integer k9_take_idx = 0;  // 本行窗口内已取到的源字序号
	integer k9_rows = 0;      // 已走完的窗口行数
	integer k9_row_min = 0;   // 单行取字数最小值
	integer k9_row_max = 0;   // 单行取字数最大值
	integer k9_in_cycles = 0; // 窗口内有效拍数
	integer k9_in_bad = 0;    // 窗口内像素/有效错误数
	integer k9_out_cycles = 0;// 窗口外拍数
	integer k9_out_bad = 0;   // 窗口外非零违例数
	integer ident_cycles = 0; // 恒等档逐拍比对拍数
	integer ident_bad = 0;    // 恒等档不一致拍数
	integer k9_row_bad = 0;   // 行末取字数不等于 PIX_PER_LINE/2 的行数
	// 取字位置分布：只查「每行取满 32 字」抓不到「全挤在左边」——把 32 次取字
	// 集中在窗口前 32 列同样满足配额，且第 k 次取到源字 k 也照样成立。所以再单独
	// 校验第 k 次取字落在窗口内第 floor(k*W/N) .. ceil((k+1)*W/N)-1 列上（DDA 的
	// 精确定义），并顺带统计实际列间隔的最小/最大值。
	integer k9_prev_x = -1;   // 本行上一次取字的窗口内列号
	integer k9_gap_min = 0;
	integer k9_gap_max = 0;
	integer k9_gap = 0;       // 相邻两次取字的列间隔（先存 integer 再比较，避免无符号陷阱）
	integer k9_prev_src = -1;  // 本行上一次取字对应的源列号
	integer k9_src_step_bad = 0; // 源列步进不等于 2 的次数
	integer k9_spread_bad = 0; // 第 k 次取字不在理论窗口内的次数
	reg skip_pixels = 1'b0;   // Key9 窗口档下「逐拍 == 原像素语义」不再成立，跳过该判据
	// -----------------------------------------------------------------------
	// v4（T31）：纵向裁剪对齐观测（只观测，不驱动 DUT）。
	//   契约：窗口占面板行 [win_off_y, win_off_y+win_h)，其中第 r 行（r 从 0 起）
	//   必须显示源行 win_off_y + r —— 即「居中裁剪」，不是「从源图顶部裁」。
	//   参考值一律由内存夹具 expected_pixel 反查，不复用 DUT 内部任何表达式。
	//   纵向是 1:1 裁剪，故源行号 == 面板行号；这一条同时是判据本身。
	// -----------------------------------------------------------------------
	reg check_k9y = 1'b0;       // 纵向对齐观测使能
	reg k9y_horiz = 1'b0;       // 1=水平窗口档（窗口内第 w 次出队字=源列 2w）
	                            // 0=满屏恒等档（每拍一像素，逐像素等值比对）
	integer k9y_word = 0;       // 本行窗口内已出队的字数（仅水平窗口档使用）
	integer k9y_off = 0;        // 本档期望的 win_off_y
	integer k9y_h = 0;          // 本档期望的 win_h
	integer k9y_row = 0;        // 本行已输出的窗口内字数
	integer k9y_rows = 0;       // 已走完的窗口行数
	integer k9y_align_bad = 0;  // 窗口内像素与「源行 = 面板行」不符的次数
	integer k9y_first_panel = -1; // 首个窗口行的面板行号
	integer k9y_first_src = -1;   // 首个窗口行实际显示的源行号（反查得到）
	integer k9y_last_panel = -1;  // 末个窗口行的面板行号
	integer k9y_last_src = -1;    // 末个窗口行实际显示的源行号
	integer k9y_probe_done = 0;   // 首行反查是否已完成
	integer k9y_rows_bad = 0;     // 窗口行数不等于 win_h 的次数
	// 欠载观测（T31 第二节：h_pop 在 FIFO 空那拍为 0，信用会超前累积）
	integer k9y_empty_cycles = 0; // 窗口内 FIFO 空拍数
	integer k9y_win_cycles = 0;   // 窗口内拍数
	integer k9y_underflow_frames = 0; // 出现欠载的帧数
	integer k9y_underflow_total = 0;  // 欠载总次数（stat[0] 上升沿计）
	integer k9y_underflow_edges = 0;  // stat[0]（sticky underflow）上升沿次数
	reg k9y_uf_prev = 1'b0;       // stat[0] 上一拍值，用于上升沿计数
	integer k9y_soak_bad = 0;     // 浸泡期间首行漂移的帧数
	integer k9y_soak_frames = 0;  // 浸泡完成的帧数
	integer k9y_li = 0;           // 源行反查循环变量（必须用独立变量：同一 always
	                              // 块里若复用共享的 i，会与 initial 块的用法互相踩）
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
	// v2（T4）：pix_reader 行映射输出
	wire [15:0] src_y;
	wire src_row_hold, map_ident;
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
		.active_x(active_x),
		.src_w(src_w), .src_h(src_h),
		.win_w(win_w), .win_h(win_h), .win_off_x(win_off_x), .win_off_y(win_off_y),
		.out_valid(out_valid),
		.src_y(src_y), .src_row_hold(src_row_hold), .map_ident(map_ident),
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
	// 像素通路校验与 V-03 垂直行映射校验合并在同一个 always 块里，原因有两条：
	//   1. 两者都是 posedge clk_pix 的纯观测计数，语义上可共存；
	//   2. scripts/lint_verilog.py 的 E2 判据是"同一变量被多个 always 块驱动"，
	//      而它的 find_blocks() 不剥字符串、把 $display 格式串里的裸标识符也当成赋值，
	//      拆成两个块会误报一批 E2。合并后两块变一块，误报消失，判据也不放宽。
	always @(posedge clk_pix) begin
		if (rst_n_pix && check_en && de) begin
			pixels_checked = pixels_checked + 1;
			// Key9 窗口档下输出不再是「每拍源列 = active_x」，逐拍等值判据不成立，
			// 改由下方 check_k9 段按「第 k 次取字 = 源列 2k」比对；这里只跳过比较，
			// pixels_checked 仍照常计数，scan_frame 的覆盖率判据不放宽。
			if (!skip_pixels && (pix_valid !== 1'b1 || pix_rgb565 !== expected_pixel(active_x, active_y))) begin
				pixel_errors = pixel_errors + 1;
				if (first_bad_x < 0) begin
					first_bad_x = active_x;
					first_bad_y = active_y;
					$display("PIXEL_MISMATCH ax=%0d ay=%0d pv=%b got=%04h exp_px=%04h st=%0d",
						active_x, active_y, pix_valid, pix_rgb565,
						expected_pixel(active_x, active_y), dut.state);
				end
			end
		end
		// V-03（T4）：垂直行映射闭合校验。参考值用闭式 floor(active_y * src_h / FRAME_LINES)，
		// 与 DUT 内部 16 位 DDA 是同一定义（DDA 只在 y_acc+src_h>=FRAME_LINES 时才推进源行）。
		// 全程只累加计数，不在逐像素循环里调 chk，避免 checks 计数被淹没。
		if (rst_n_pix && check_map && de) begin
			map_checked = map_checked + 1;
			if (src_y !== ((active_y * src_h) / LINES)) begin
				map_errors = map_errors + 1;
				if (map_first_y < 0) begin
					map_first_y = active_y;
					$display("MAP_MISMATCH ay=%0d sy=%0d exp_y=%0d sh=%0d hl=%b idn=%b",
						active_y, src_y, (active_y * src_h) / LINES, src_h, src_row_hold, map_ident);
				end
			end
			if ((src_h == LINES) && (map_ident !== 1'b1)) map_errors = map_errors + 1;
			if ((src_h != LINES) && (map_ident !== 1'b0)) map_errors = map_errors + 1;
		end
		// v3（Key9 第 1 步）：水平窗口降采样的逐拍校验。参考值一律由内存夹具推导
		//（expected_pixel），不复用 DUT 内部任何表达式，避免「tb 与 RTL 同源同错」。
		//   · FIFO 是先进先出，窗口内第 k 次取字拿到的必然是源字 k，而源字 k 的
		//     低半字就是源列 2k —— 故参考值 = expected_pixel(2k, active_y)。k 从 0
		//     连续递增即同时证明「首列是源列 0 而不是 win_off_x」与「相邻源列间隔恒 2」。
		//   · 窗口内未取字的拍必须输出 0（不谎报有效像素）。
		//   · 窗口外每拍必须 out_valid=0 且 pix_rgb565=0。
		if (rst_n_pix && check_ident && de) begin
			ident_cycles = ident_cycles + 1;
			if (pix_valid !== 1'b1 || pix_rgb565 !== expected_pixel(active_x, active_y))
				ident_bad = ident_bad + 1;
		end
		// v4（T31）：纵向裁剪对齐观测。判据两条，互相独立：
		//   (a) 逐拍等值：窗口内第 k 次取到的字，必须等于源图 (2k, active_y) 的像素。
		//       纵向 1:1 裁剪意味着「面板行 active_y 显示源行 active_y」——窗口起于
		//       面板行 win_off_y 时就显示源行 win_off_y，即居中裁剪而非从顶部裁。
		//   (b) 首/末行反查：把实际输出像素反查成源行号，直接打印 first_src_row，
		//       供报告里逐档引号。反查不许复用 DUT 表达式，一律走 expected_pixel。
		// 顺带统计窗口内 FIFO 空拍数与 stat[0] 上升沿，用于回答「欠载是否发生」。
		if (rst_n_pix && check_k9y && de) begin
			// fifo_rd_empty 是 DUT 内部 wire（端口表里没有），只能层级引用。
			// 层级引用在仿真里是只读观测，不改 DUT 任何状态。
			if (dut.fifo_rd_empty) k9y_empty_cycles = k9y_empty_cycles + 1;
			if (stat[0] === 1'b1 && k9y_uf_prev === 1'b0)
				k9y_underflow_edges = k9y_underflow_edges + 1;
			k9y_uf_prev = stat[0];
			if (k9y_horiz) begin
				// 甲：水平窗口档（use_key9=1）。窗口内第 w 次出队字 = 源列 2w。
				if ((active_x >= win_off_x) && (active_x < (win_off_x + win_w))) begin
					k9y_win_cycles = k9y_win_cycles + 1;
					if (out_valid === 1'b1) begin
						if (pix_rgb565 !== expected_pixel(k9y_word * 2, active_y))
							k9y_align_bad = k9y_align_bad + 1;
						// 只反查窗口首行/末行的第一个字，避免逐拍做大循环
						if ((k9y_word == 0) &&
							((active_y == win_off_y) ||
							 (active_y == (win_off_y + win_h - 1)))) begin
							for (k9y_li = 0; k9y_li < (LINES + 1); k9y_li = k9y_li + 1) begin  // 不写 "<=" 接数字: lint 工具会误判成非阻塞赋值
								if (pix_rgb565 === expected_pixel(0, k9y_li)) begin
									if (active_y == win_off_y) begin
										if (k9y_first_src < 0) begin
											k9y_first_panel = active_y;
											k9y_first_src = k9y_li;
										end
									end else if (k9y_last_src < 0) begin
										k9y_last_panel = active_y;
										k9y_last_src = k9y_li;
									end
								end
							end
						end
						k9y_word = k9y_word + 1;
					end
				end
				if (active_x == PIX_PER_LINE - 1) k9y_word = 0;
			end else begin
				// 乙：满屏恒等档（use_key9=0）。逐像素比对，判据更强。
				if ((active_x == win_off_x) &&
					((active_y == win_off_y) || (active_y == (win_off_y + win_h - 1)))) begin
					if (pix_valid === 1'b1) begin
						for (k9y_li = 0; k9y_li < (LINES + 1); k9y_li = k9y_li + 1) begin  // 不写 "<=" 接数字: lint 工具会误判成非阻塞赋值
							if (pix_rgb565 === expected_pixel(0, k9y_li)) begin
								if (active_y == win_off_y) begin
									if (k9y_first_src < 0) begin
										k9y_first_panel = active_y;
										k9y_first_src = k9y_li;
									end
								end else if (k9y_last_src < 0) begin
									k9y_last_panel = active_y;
									k9y_last_src = k9y_li;
								end
							end
						end
					end
				end
				if ((active_x >= win_off_x) && (active_x < (win_off_x + win_w))) begin
					k9y_win_cycles = k9y_win_cycles + 1;
					if (pix_valid === 1'b1) begin
						if (pix_rgb565 !== expected_pixel(active_x, active_y))
							k9y_align_bad = k9y_align_bad + 1;
					end
				end
			end
			if (active_x == PIX_PER_LINE - 1) begin
				if ((active_y >= win_off_y) && (active_y < (win_off_y + win_h)))
					k9y_rows = k9y_rows + 1;
			end
		end
		if (rst_n_pix && check_k9 && de) begin
			if ((active_x >= win_off_x) && (active_x < (win_off_x + win_w))) begin
				k9_in_cycles = k9_in_cycles + 1;
				if (out_valid === 1'b1) begin
					if (pix_rgb565 !== expected_pixel(k9_take_idx * 2, active_y))
						k9_in_bad = k9_in_bad + 1;
					// DDA 精确位置：第 k 次取字必须落在窗口内第 k 段的列区间里
					// [floor(k*W/N), ceil((k+1)*W/N)-1]，W=窗口宽、N=每行取字数。
					// 这一条能抓住「取字全挤在左边」——那种实现也满足「每行取满 N 字」。
					begin : k9_place
						integer rel, lo, hi;
						rel = active_x - win_off_x;
						lo = (k9_take_idx * win_w) / (PIX_PER_LINE / 2);
						hi = (((k9_take_idx + 1) * win_w) + (PIX_PER_LINE / 2) - 1)
							/ (PIX_PER_LINE / 2) - 1;
						if ((rel < lo) || (rel > hi)) k9_spread_bad = k9_spread_bad + 1;
					end
					// 列间隔统计：必须先把差值存进 integer 再比较。
					// 直接写 (active_x - k9_prev_x) > k9_gap_max 时，active_x 是
					// 无符号 11 位、k9_prev_x 是 integer，混合表达式按无符号求值，
					// 初值 -1 会被当成 32'hFFFFFFFF，判据恒假、gap_max 永远停在 -1。
					// 行首（k9_prev_x<0）没有上一个取字点，不能计入间隔。
					if (k9_prev_x >= 0) begin
						k9_gap = active_x - k9_prev_x;
						if (k9_gap < k9_gap_min) k9_gap_min = k9_gap;
						if (k9_gap > k9_gap_max) k9_gap_max = k9_gap;
					end
					k9_prev_x = active_x;
					// 源列步进：第 k 次取字输出的是源列 2k（一个字含两个相邻源像素，
					// 取字只出低半字=偶列）。这里单独钉一条，与「拍间隔」分开。
					// 若有人把取字频率减半来"满足拍间隔"，源列步进会变成 4，此条变红。
					if (k9_prev_src >= 0) begin
						if (((k9_take_idx * 2) - k9_prev_src) != 2) k9_src_step_bad = k9_src_step_bad + 1;
					end
					k9_prev_src = k9_take_idx * 2;
					k9_take_idx = k9_take_idx + 1;
				end else if (pix_rgb565 !== 16'd0) begin
					k9_in_bad = k9_in_bad + 1;
				end
			end else begin
				k9_out_cycles = k9_out_cycles + 1;
				if ((out_valid !== 1'b0) || (pix_rgb565 !== 16'd0)) k9_out_bad = k9_out_bad + 1;
			end
			// 行末结算：本行取字数必须恰为 PIX_PER_LINE/2（一整行的字全部由窗口内拍取走）
			if (active_x == PIX_PER_LINE - 1) begin
				if (k9_take_idx < k9_row_min) k9_row_min = k9_take_idx;
				if (k9_take_idx > k9_row_max) k9_row_max = k9_take_idx;
				if (k9_take_idx != (PIX_PER_LINE / 2)) k9_row_bad = k9_row_bad + 1;
				k9_rows = k9_rows + 1;
				k9_take_idx = 0;
				k9_prev_x = -1;
				k9_prev_src = -1;
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
			// 注意：本行字符串里不能出现 always 这个词。scripts/lint_verilog.py 的
			// find_blocks() 只剥注释不剥字符串，会把这个词误当成新 always 块的起点，
			// 造出一个与下面 V-03 校验块重叠的假块，从而误报一批 E2 多驱动。
			if (rd_ack && !app_rd_en) chk(1'b0, "group acknowledgement must name a real command");
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
		// ---------------------------------------------------------------------
		// V-03（T4）：垂直行映射。
		// 判据用闭式 floor(active_y * src_h / FRAME_LINES)，与 pix_reader 内部
		// 16 位 DDA 同一定义；两档都必须逐像素吻合，且 map_ident 只在恒等档为 1。
		// 注意本用例只验证映射结果，不改像素通路：读带宽与 v1 完全一致。
		// ---------------------------------------------------------------------
		$display("CASE: vertical line mapping identity src_h=%0d", LINES);
		row_only = 1'b0;
		frame_seed = 9;
		src_h = LINES;
		fill_frame;
		check_map = 1'b1;
		map_checked = 0;
		map_errors = 0;
		map_first_y = -1;
		scan_frame("vertical_map_identity", 1'b0);
		chk(map_errors == 0, "identity src_h matches floor(active_y*src_h/FRAME_LINES)");
		chk(map_checked >= PIX_PER_LINE * LINES, "identity map check covers every visible pixel");
		chk(src_y < LINES, "identity mapped row never leaves the source frame");
		check_map = 1'b0;
		if (LINES >= 2) begin
			$display("CASE: vertical line mapping half src_h=%0d over FRAME_LINES=%0d", LINES / 2, LINES);
			frame_seed = 10;
			src_h = LINES / 2;
			fill_frame;
			check_map = 1'b1;
			map_checked = 0;
			map_errors = 0;
			map_first_y = -1;
			scan_frame("vertical_map_half", 1'b0);
			chk(map_errors == 0, "half src_h matches floor(active_y*src_h/FRAME_LINES)");
			chk(map_checked >= PIX_PER_LINE * LINES, "half map check covers every visible pixel");
			chk(src_y < LINES, "half mapped row never leaves the source frame");
			chk(map_ident === 1'b0, "half src_h must not assert identity bypass");
			check_map = 1'b0;
		end
		src_h = LINES;   // 恢复恒等档，后续用例行为与 v1 一致
		// ---------------------------------------------------------------------
		// v3（Key9 第 1 步）：水平窗口降采样。只驱动水平，垂直仍走 src_h=LINES。
		// 三个用例分别覆盖：恒等红线、窗口收窄到 1/2（每 2 源列取 1）、
		// 非整除窗口宽（64/48，验证 DDA 在非整除比例下仍恰好取满一整行）。
		// ---------------------------------------------------------------------
		$display("CASE: key9 identity with win_w=%0d win_off_x=0", PIX_PER_LINE);
		row_only = 1'b0;
		frame_seed = 11;
		win_w = PIX_PER_LINE;
		win_h = LINES;
		win_off_x = 16'd0;
		fill_frame;
		ident_cycles = 0;
		ident_bad = 0;
		check_ident = 1'b1;
		scan_frame("key9_identity", 1'b0);
		check_ident = 1'b0;
		$display("K9_IDENT: compared=%0d mismatches=%0d", ident_cycles, ident_bad);
		chk(ident_cycles == PIX_PER_LINE * LINES, "identity compares every visible cycle");
		chk(ident_bad == 0, "identity matches pre-change pixel semantics cycle by cycle");
		// 窗口宽 = 半个屏、居中：每 2 源列取 1，源列序列 0,2,4,...,PIX_PER_LINE-2
		$display("CASE: key9 half window win_w=%0d win_off_x=%0d", PIX_PER_LINE / 2, PIX_PER_LINE / 4);
		frame_seed = 12;
		win_w = PIX_PER_LINE / 2;
		win_off_x = PIX_PER_LINE / 4;
		fill_frame;
		k9_take_idx = 0;
		k9_rows = 0;
		k9_row_min = 999999;
		k9_row_max = -1;
		k9_in_cycles = 0;
		k9_in_bad = 0;
		k9_out_cycles = 0;
		k9_out_bad = 0;
		k9_row_bad = 0;
		k9_spread_bad = 0;
		k9_prev_x = -1;
		k9_prev_src = -1;
		k9_src_step_bad = 0;
		k9_gap_min = 999999;
		k9_gap_max = 0;          // 不能用 -1 当哨兵：混合无符号比较下它等于 32'hFFFFFFFF
		skip_pixels = 1'b1;
		check_k9 = 1'b1;
		scan_frame("key9_half_window", 1'b0);
		check_k9 = 1'b0;
		skip_pixels = 1'b0;
		$display("K9_HALF: rows=%0d takes_per_row=[%0d..%0d] in_cycles=%0d in_bad=%0d out_cycles=%0d out_bad=%0d row_bad=%0d spread_bad=%0d gap=[%0d..%0d] src_step_bad=%0d",
			k9_rows, k9_row_min, k9_row_max, k9_in_cycles, k9_in_bad,
			k9_out_cycles, k9_out_bad, k9_row_bad, k9_spread_bad, k9_gap_min, k9_gap_max,
			k9_src_step_bad);
		chk(k9_rows == LINES, "half window covers every row of a frame");
		chk(k9_row_min == PIX_PER_LINE / 2, "min takes per row equals PIX_PER_LINE/2");
		chk(k9_row_max == PIX_PER_LINE / 2, "max takes per row equals PIX_PER_LINE/2");
		chk(k9_row_bad == 0, "no row deviates from the take quota");
		chk(k9_in_cycles == (PIX_PER_LINE / 2) * LINES, "in-window cycles equal win_w times LINES");
		chk(k9_out_cycles == (PIX_PER_LINE / 2) * LINES, "out-window cycles equal blank width times LINES");
		chk(k9_in_bad == 0, "in-window source columns are 0,2,4,... and idle cycles emit zero");
		chk(k9_out_bad == 0, "out-window cycles hold out_valid and pix_rgb565 at zero");
		chk(k9_spread_bad == 0, "each take lands in its own DDA segment of the window");
		// 「拍间隔」与「源列步进」必须分开判：win_w == 每行字数时窗口内每拍都取字，
		// 所以拍间隔恒为 1（不是 2）。源列步进恒为 2 由 src_step 那条单独钉住。
		chk(k9_gap_min == 1 && k9_gap_max == 1, "half window takes one word every display cycle");
		chk(k9_src_step_bad == 0, "half window source column step is exactly 2");
		// 非整除窗口宽：64/48，DDA 必须仍恰好取满一整行（32 字）
		$display("CASE: key9 fraction window win_w=%0d win_off_x=%0d", (PIX_PER_LINE * 3) / 4, PIX_PER_LINE / 8);
		frame_seed = 13;
		win_w = (PIX_PER_LINE * 3) / 4;
		win_off_x = PIX_PER_LINE / 8;
		fill_frame;
		k9_take_idx = 0;
		k9_rows = 0;
		k9_row_min = 999999;
		k9_row_max = -1;
		k9_in_cycles = 0;
		k9_in_bad = 0;
		k9_out_cycles = 0;
		k9_out_bad = 0;
		k9_row_bad = 0;
		k9_spread_bad = 0;
		k9_prev_x = -1;
		k9_prev_src = -1;
		k9_src_step_bad = 0;
		k9_gap_min = 999999;
		k9_gap_max = 0;          // 不能用 -1 当哨兵：混合无符号比较下它等于 32'hFFFFFFFF
		skip_pixels = 1'b1;
		check_k9 = 1'b1;
		scan_frame("key9_fraction_window", 1'b0);
		check_k9 = 1'b0;
		skip_pixels = 1'b0;
		$display("K9_FRAC: rows=%0d takes_per_row=[%0d..%0d] in_cycles=%0d in_bad=%0d out_cycles=%0d out_bad=%0d row_bad=%0d spread_bad=%0d gap=[%0d..%0d] src_step_bad=%0d",
			k9_rows, k9_row_min, k9_row_max, k9_in_cycles, k9_in_bad,
			k9_out_cycles, k9_out_bad, k9_row_bad, k9_spread_bad, k9_gap_min, k9_gap_max,
			k9_src_step_bad);
		chk(k9_row_bad == 0, "fraction window still takes exactly PIX_PER_LINE/2 per row");
		chk(k9_in_bad == 0, "fraction window keeps strictly increasing source columns");
		chk(k9_out_bad == 0, "fraction window holds out-window cycles at zero");
		chk(k9_spread_bad == 0, "fraction window take positions follow the DDA segments");
		// 非整除档（64/48 = 4:3）：每 4 拍取 3 字，拍间隔在 1 与 2 之间交替，
		// 源列步进仍恒为 2。两条分开判，含义不同。
		chk(k9_gap_min >= 1 && k9_gap_max <= 2, "fraction window take gap stays within one cycle");
		chk(k9_src_step_bad == 0, "fraction window source column step is exactly 2");
		// ---------------------------------------------------------------------
		// v4（T31）：纵向裁剪对齐 —— 五档逐档实测。
		//   契约：窗口占面板行 [win_off_y, win_off_y+win_h)，其中第 r 行显示源行
		//   win_off_y + r（纵向 1:1 裁剪、居中，不是从源图顶部裁）。
		//   做法：满屏宽度（win_w=PIX_PER_LINE、win_off_x=0）⇒ h_ident=1、use_key9=0，
		//   走逐像素通路，判据最强；只在 y 方向收窄 win_h。
		//   五档 win_off_y/win_h 按 LINES 等比缩放：-FullVga（LINES=480）时即真值
		//   120/90/60/30/0 与 240/300/360/420/480；小几何下为等比缩小档。
		// ---------------------------------------------------------------------
		begin : k9y_tiers
			integer t;
			for (t = 0; t < 5; t = t + 1) begin
				case (t)
					0: begin k9y_off = (LINES * 120) / 480; k9y_h = (LINES * 240) / 480; end
					1: begin k9y_off = (LINES * 90) / 480;  k9y_h = (LINES * 300) / 480; end
					2: begin k9y_off = (LINES * 60) / 480;  k9y_h = (LINES * 360) / 480; end
					3: begin k9y_off = (LINES * 30) / 480;  k9y_h = (LINES * 420) / 480; end
					default: begin k9y_off = 0; k9y_h = LINES; end
				endcase
				if (k9y_h > LINES) k9y_h = LINES;
				if ((k9y_off + k9y_h) > LINES) k9y_h = LINES - k9y_off;
				if ((k9y_h > 0) && (k9y_off >= 0)) begin
					win_w = PIX_PER_LINE;
					win_h = k9y_h;
					win_off_x = 16'd0;
					win_off_y = k9y_off;
					frame_seed = 21 + t;
					fill_frame;
					k9y_word = 0;
					k9y_rows = 0;
					k9y_align_bad = 0;
					k9y_first_panel = -1;
					k9y_first_src = -1;
					k9y_last_panel = -1;
					k9y_last_src = -1;
					k9y_empty_cycles = 0;
					k9y_win_cycles = 0;
					k9y_underflow_edges = 0;
					k9y_uf_prev = 1'b0;
					k9y_horiz = 1'b0;
					check_k9y = 1'b1;
					scan_frame("vertical_crop_tier", 1'b0);
					check_k9y = 1'b0;
					$display("K9Y_TIER t=%0d off_y=%0d win_h=%0d first_panel=%0d first_src=%0d last_panel=%0d last_src=%0d rows=%0d align_bad=%0d empty=%0d/%0d uf=%0d",
						t, k9y_off, k9y_h, k9y_first_panel, k9y_first_src,
						k9y_last_panel, k9y_last_src, k9y_rows, k9y_align_bad,
						k9y_empty_cycles, k9y_win_cycles, k9y_underflow_edges);
					chk(k9y_first_panel == k9y_off,
						"first window row is the panel row win_off_y");
					chk(k9y_first_src == k9y_off,
						"first window row shows source row win_off_y (centered crop)");
					chk(k9y_last_src == (k9y_off + k9y_h - 1),
						"last window row shows source row win_off_y+win_h-1");
					chk(k9y_align_bad == 0,
						"every window row shows its own source row (1:1 vertical crop)");
					chk(k9y_rows == k9y_h, "checked window covers exactly win_h rows");
					chk(k9y_underflow_edges == 0,
						"no sticky underflow observed across the checked crop frame");
				end
			end
		end
		// 水平窗口档下的纵向对齐：窗口收窄到半屏、y 方向仍取最高档，
		// 证明水平 DDA（取 4 停 1 的节奏）不影响行推进 —— 行的推进只由行末触发。
		begin : k9y_horiz_case
			k9y_off = (LINES * 120) / 480;
			k9y_h = (LINES * 240) / 480;
			if (k9y_h > LINES) k9y_h = LINES;
			if ((k9y_off + k9y_h) > LINES) k9y_h = LINES - k9y_off;
			win_w = PIX_PER_LINE / 2;
			win_h = k9y_h;
			win_off_x = PIX_PER_LINE / 4;
			win_off_y = k9y_off;
			frame_seed = 31;
			fill_frame;
			k9y_word = 0;
			k9y_rows = 0;
			k9y_align_bad = 0;
			k9y_first_panel = -1;
			k9y_first_src = -1;
			k9y_last_panel = -1;
			k9y_last_src = -1;
			k9y_empty_cycles = 0;
			k9y_win_cycles = 0;
			k9y_underflow_edges = 0;
			k9y_uf_prev = 1'b0;
			k9y_horiz = 1'b1;
			skip_pixels = 1'b1;
			check_k9y = 1'b1;
			scan_frame("vertical_crop_horiz_window", 1'b0);
			check_k9y = 1'b0;
			skip_pixels = 1'b0;
			$display("K9Y_HORIZ: off_y=%0d win_w=%0d first_panel=%0d first_src=%0d last_src=%0d rows=%0d align_bad=%0d empty=%0d/%0d uf=%0d",
				k9y_off, win_w, k9y_first_panel, k9y_first_src, k9y_last_src,
				k9y_rows, k9y_align_bad, k9y_empty_cycles, k9y_win_cycles,
				k9y_underflow_edges);
			chk(k9y_first_src == k9y_off,
				"horizontal window keeps the horizontal DDA from shifting the row origin");
			chk(k9y_last_src == (k9y_off + k9y_h - 1),
				"horizontal window reaches the last window row unchanged");
			chk(k9y_align_bad == 0,
				"horizontal window keeps every row 1:1 against its own source row");
			chk(k9y_rows == k9y_h, "horizontal window covers exactly win_h rows");
		end
		// ---------------------------------------------------------------------
		// v4（T31）：长帧浸泡。每帧都重新 P_RESTART，故每帧都是一次独立的
		// 「帧首从空 FIFO 补水到窗口首行」的完整过程。用真实 SDRAM 读组时序
		//（framebuf_arbiter 4 字/13 拍）补水，统计窗口内 FIFO 空拍、sticky 欠载
		// 上升沿，并逐帧核对首行源行号是否始终等于 win_off_y。
		// ---------------------------------------------------------------------
		begin : k9y_soak
			integer f;
			k9y_off = (LINES * 120) / 480;
			k9y_h = (LINES * 240) / 480;
			if (k9y_h > LINES) k9y_h = LINES;
			if ((k9y_off + k9y_h) > LINES) k9y_h = LINES - k9y_off;
			k9y_soak_bad = 0;
			k9y_soak_frames = 0;
			if (SOAK_FRAMES > 0) begin
				win_w = PIX_PER_LINE;
				win_h = k9y_h;
				win_off_x = 16'd0;
				win_off_y = k9y_off;
				k9y_horiz = 1'b0;
				$display("CASE: vertical crop soak frames=%0d off_y=%0d win_h=%0d", SOAK_FRAMES, k9y_off, k9y_h);
				for (f = 0; f < SOAK_FRAMES; f = f + 1) begin
					frame_seed = 41 + f;
					fill_frame;
					k9y_word = 0;
					k9y_rows = 0;
					k9y_align_bad = 0;
					k9y_first_panel = -1;
					k9y_first_src = -1;
					k9y_last_panel = -1;
					k9y_last_src = -1;
					k9y_empty_cycles = 0;
					k9y_win_cycles = 0;
					k9y_underflow_edges = 0;
					k9y_uf_prev = 1'b0;
					check_k9y = 1'b1;
					scan_frame("vertical_crop_soak", 1'b1);
					check_k9y = 1'b0;
					k9y_soak_frames = k9y_soak_frames + 1;
					k9y_underflow_total = k9y_underflow_total + k9y_underflow_edges;
					if (k9y_underflow_edges != 0) k9y_underflow_frames = k9y_underflow_frames + 1;
					if (k9y_first_src != k9y_off) begin
						k9y_soak_bad = k9y_soak_bad + 1;
						$display("K9Y_SOAK_DRIFT frame=%0d first_src=%0d want=%0d empty=%0d/%0d uf=%0d",
							f, k9y_first_src, k9y_off, k9y_empty_cycles, k9y_win_cycles,
							k9y_underflow_edges);
					end
				end
				$display("K9Y_SOAK: frames=%0d drift=%0d uf_frames=%0d uf_edges=%0d",
					k9y_soak_frames, k9y_soak_bad, k9y_underflow_frames,
					k9y_underflow_total);
				chk(k9y_soak_frames == SOAK_FRAMES, "soak runs the requested number of frames");
				chk(k9y_soak_bad == 0,
					"soak keeps the first window row pinned to win_off_y on every frame");
			end
		end
		// 恢复满屏恒等档，后续 STRESS 用例行为与 v1 一致
		win_w = PIX_PER_LINE;
		win_h = LINES;
		win_off_x = 16'd0;
		win_off_y = 16'd0;
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
		// 帧预算必须随新增用例一起放大，否则 watchdog 会在合法用例中途触发。
		// 原基线 24 帧；v4（T31）新增 5 档纵向用例 + 1 个水平窗口档 + SOAK_FRAMES 帧
		// 浸泡，再多留 8 帧余量。这里只放宽「测多久」，不放宽任何判据。
		#(H_TOTAL * V_TOTAL * CLK_PIX_PERIOD * (24 + SOAK_FRAMES + 6 + 8));
		$display("FAILED: tb_pix_reader global timeout");
		$finish;
	end
endmodule
