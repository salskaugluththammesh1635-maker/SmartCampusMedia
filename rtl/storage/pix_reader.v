// =============================================================================
// pix_reader — SDRAM 顺序读流到 RGB565 像素流
// =============================================================================
// 数据路径：framebuf_arbiter -> 异步 FIFO -> 每字两个 RGB565 像素。
// clk_sdr=150MHz；pix_clk=25MHz。系统复位必须同时复位两侧，分别同步释放。
// 每次垂直消隐：停止新组 -> 等仲裁器排空 -> 读空 FIFO -> 请求帧首重启
// -> 等明确的重启完成握手 -> 在消隐期预填。运行时不单独复位 FIFO 指针。
// 读计数以格雷码跨域，不能把多位二进制计数直接打两拍。
// ARM_QUIET_C/ARM_SETTLE_C 为像素时钟拍数；消隐期须容纳排空与预填。
// FIFO_AW>=2，PIX_PER_LINE 为偶数，12 <= LEVEL_HI，LEVEL_HI+4 <= 2**FIFO_AW。
// 兼容 video_timing_gen 的消隐坐标归零：观察最后有效行末后锁存消隐状态，
// 首次扫描输出黑帧，完整经历帧末后建立对齐；也接受带消隐值的原始行计数。
// 超时/真核刷新语义由仲裁器负责；本模块不声称单侧复位可自愈。
// =============================================================================
`timescale 1ns / 1ps

module pix_reader #(
	parameter ADDR_WIDTH = 21,           // SDRAM 字地址位宽
	parameter FRAME_BASE = 21'd0,       // 四字对齐的帧首地址
	parameter PIX_PER_LINE = 640,       // 每行有效像素，须为偶数
	parameter Y_WIDTH = 10,             // 行号位宽
	parameter FRAME_LINES = 480,        // 有效行数，后续行为垂直消隐
	parameter FIFO_AW = 10,             // FIFO 深度的二进制地址位宽
	parameter LEVEL_HI = 768,           // 含在飞读数的预取水位阈值
	parameter ARM_QUIET_C = 16,         // 停请求后的最短同步等待
	parameter ARM_SETTLE_C = 8          // 确认 FIFO 空的稳定窗口
) (
	input wire clk_sdr,                 // SDRAM 域时钟
	input wire rst_n_sdr,               // SDRAM 域低有效复位
	output wire rd_req,                 // 允许仲裁器发起新的四字组
	input wire rd_ack,                  // 实际发起四字组的组首握手
	input wire [31:0] rd_data,          // 仲裁器返回的一字数据
	input wire rd_valid,                // 返回数据有效，同拍写 FIFO
	input wire rd_idle,                 // 无读组、在飞返回或输出数据
	input wire rd_restart_done,         // 仲裁器确已执行重启的单拍脉冲
	output wire rd_restart,             // SDRAM 域的单拍重启请求
	output wire [ADDR_WIDTH-1:0] rd_base,// 重启目标帧首，保持不变
	input wire pix_clk,                 // 像素域时钟
	input wire rst_n_pix,               // 像素域低有效复位
	input wire de,                      // 当前拍处于有效显示区
	input wire [Y_WIDTH-1:0] active_y,   // 有效行号；允许消隐归零或给出原始消隐行号
	output wire [15:0] pix_rgb565,       // 偶像素低半字、奇像素高半字，组合输出
	output wire pix_valid,              // 当前拍确有像素，不额外延迟 de
	output wire [2:0] stat              // [2]已对齐 [1]溢出 [0]下溢
);

	localparam [2:0] P_WAIT = 3'd0;      // 冷启动等待垂直消隐
	localparam [2:0] P_QUIET = 3'd1;     // 关闭请求并等在飞读数据
	localparam [2:0] P_DRAIN = 3'd2;     // 排空旧帧预取字
	localparam [2:0] P_RESTART = 3'd3;   // 等帧首重启完成握手
	localparam [2:0] P_READY = 3'd4;     // 消隐期预取，等下一帧有效区
	localparam [2:0] P_RUN = 3'd5;       // 正常像素消费
	localparam COUNT_W = FIFO_AW + 2;
	// 两拍水位流水线预留八字，覆盖最坏情况下尚未反映的两个四字组。
	localparam [COUNT_W-1:0] LEVEL_LIMIT = LEVEL_HI - 8;

	reg [2:0] state;                    // 像素域当前状态
	reg [2:0] next_state;               // 组合计算的下一状态
	reg [15:0] arm_count;               // 静默或空稳定计数
	reg blank_prev;                    // 垂直消隐的前一拍
	reg restart_toggle;                // 像素域重启事件翻转位
	reg restart_seen;                  // 本次请求前已观察到的完成翻转位
	reg armed;                         // 已在帧首进入正常消费
	reg [10:0] pix_count;               // 行内像素的奇偶与边界检查
	reg [31:0] word_hold;               // 当前偶像素对应的整字
	reg word_valid;                    // 高半字是否来自成功的偶像素取字
	reg underflow_lat;                 // 下溢粘滞标志
	reg [COUNT_W-1:0] rd_count;         // 本域真实出队计数，含排空
	reg [COUNT_W-1:0] rd_gray;          // 出队计数的格雷码
	reg idle_meta;                     // 仲裁器静默状态的亚稳缓冲级
	reg idle_sync;                     // 像素域可用的仲裁器静默状态
	reg done_meta;                     // 重启完成翻转位的亚稳缓冲级
	reg done_sync;                     // 像素域可用的重启完成翻转位
	reg overflow_meta;                 // 溢出状态的亚稳缓冲级
	reg overflow_sync;                 // 像素域可用的溢出状态

	reg [COUNT_W-1:0] issued_count;     // 组首一次承诺四字，包含所有在飞字
	reg [COUNT_W-1:0] rd_gray_meta;     // 消费格雷码的亚稳缓冲级
	reg [COUNT_W-1:0] rd_gray_sync;     // SDRAM 域可用的消费格雷码
	reg [COUNT_W-1:0] rd_binary_sync;   // 格雷码解码单独寄存，滞后只会高估水位
	reg [COUNT_W-1:0] reserved_level;   // 已承诺总字数减已同步出队字数
	reg credit_ok;                     // 水位比较寄存后才进入仲裁器
	reg run_meta;                      // 允许预取电平的亚稳缓冲级
	reg run_sync;                      // SDRAM 域可用的预取门控
	reg restart_meta;                  // 重启翻转位的亚稳缓冲级
	reg restart_sync;                  // SDRAM 域同步后的重启翻转位
	reg restart_prev;                  // 重启翻转位的前一拍
	reg done_toggle;                   // SDRAM 域完成事件翻转位
	reg overflow_lat;                  // FIFO 溢出粘滞标志

	wire blank;                        // 当前在垂直消隐期
	wire run_enable;                   // 允许预填或正常读取
	wire display_enable;               // 已对齐且正在扫描正常帧
	wire fifo_rd_en;                   // 真实 FIFO 出队
	wire fifo_wr_en;                   // 真实 FIFO 入队
	wire [31:0] fifo_rd_data;           // FIFO 当前队头
	wire fifo_rd_empty;                // 像素域 FIFO 空
	wire fifo_wr_full;                 // SDRAM 域 FIFO 满
	wire [COUNT_W-1:0] rd_binary;       // 同步格雷码的组合解码
	wire [COUNT_W-1:0] rd_count_next;   // 成功出队后的消费计数
	wire take_even;                    // 正常帧当前应消费低半字
	genvar gray_bit;

	// video_timing_gen 的消隐坐标恒为零，因此从最后一行末到首行首像素锁存消隐。
	reg in_vblank;                    // 已见帧末、尚未见下一帧首像素
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) in_vblank <= 1'b0;
		else if (de && (active_y == FRAME_LINES - 1) &&
			(pix_count == PIX_PER_LINE - 1)) in_vblank <= 1'b1;
		else if (de && (active_y == 0)) in_vblank <= 1'b0;
	end
	assign blank = in_vblank || (active_y >= FRAME_LINES); // 同时兼容原始行计数输入
	assign run_enable = (state == P_READY) || (state == P_RUN); // 重启确认后才放开预取
	assign display_enable = (state == P_RUN) ||
		((state == P_READY) && de && (active_y == 0)); // 帧首第一像素不能多延迟一拍
	assign take_even = display_enable && de && !pix_count[0]; // 两像素只出队一次
	assign fifo_rd_en = !fifo_rd_empty && ((state == P_DRAIN) || take_even); // 排空和显示共用出队
	assign fifo_wr_en = rd_valid && !fifo_wr_full; // 写入与返回在同一边沿发生
	assign rd_count_next = rd_count + 1'b1; // 模计数位宽大于最大占用，允许自然回绕
	assign rd_req = run_sync && credit_ok; // 停请求门控保持即时响应
	assign rd_base = FRAME_BASE; // 请求期间与完成期间基址都稳定
	assign rd_restart = restart_sync ^ restart_prev; // 翻转事件恢复为 SDRAM 单拍
	assign pix_valid = de && display_enable &&
		(pix_count[0] ? word_valid : !fifo_rd_empty); // 缺字时不谎报有效
	assign pix_rgb565 = !pix_valid ? 16'd0 :
		(pix_count[0] ? word_hold[31:16] : fifo_rd_data[15:0]); // 与 de 同拍，不增加像素延迟
	assign stat = {armed, overflow_sync, underflow_lat}; // 全部状态已归入像素域

	generate
		for (gray_bit = 0; gray_bit < COUNT_W; gray_bit = gray_bit + 1) begin : g_gray_decode
			assign rd_binary[gray_bit] = ^rd_gray_sync[COUNT_W-1:gray_bit]; // 格雷码前缀异或解码
		end
	endgenerate

	// 状态寄存器：只在本域时钟更新，复位后不消费尚未对齐的内容。
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) state <= P_WAIT;
		else state <= next_state;
	end

	// 下一状态：每个正常帧都在消隐期重新定位，避免旧帧预取或下溢永久移相。
	always @(*) begin
		next_state = state;
		case (state)
			P_WAIT: if (blank) next_state = P_QUIET;
			P_QUIET: if ((arm_count >= ARM_QUIET_C) && idle_sync)
				next_state = P_DRAIN;
			P_DRAIN: if ((arm_count >= ARM_SETTLE_C) && fifo_rd_empty && idle_sync)
				next_state = P_RESTART;
			P_RESTART: if (done_sync != restart_seen) next_state = P_READY;
			P_READY: if (blank_prev && !blank) next_state = P_RUN;
			P_RUN: if (blank) next_state = P_QUIET;
			default: next_state = P_WAIT;
		endcase
	end

	// 状态任务：稳定空窗口、重启事件和帧首就绪标志各自只由本块驱动。
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) begin
			arm_count <= 16'd0;
			blank_prev <= 1'b0;
			restart_toggle <= 1'b0;
			restart_seen <= 1'b0;
			armed <= 1'b0;
		end else begin
			blank_prev <= blank;
			if (state != next_state) arm_count <= 16'd0;
			else if (state == P_QUIET) begin
				if (arm_count != 16'hFFFF) arm_count <= arm_count + 16'd1;
			end else if (state == P_DRAIN) begin
				if (!fifo_rd_empty || !idle_sync) arm_count <= 16'd0;
				else if (arm_count != 16'hFFFF) arm_count <= arm_count + 16'd1;
			end else arm_count <= 16'd0;
			if ((state == P_DRAIN) && (next_state == P_RESTART)) begin
				restart_toggle <= ~restart_toggle;
				restart_seen <= done_sync;
			end
			if (next_state == P_QUIET) armed <= 1'b0;
			else if ((state == P_READY) && (next_state == P_RUN)) armed <= 1'b1;
		end
	end

	// 像素消费：空白期保留预填字；只有排空状态可在 de=0 时出队。
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) begin
			rd_count <= 16'd0;
			rd_gray <= 16'd0;
			pix_count <= 11'd0;
			word_hold <= 32'd0;
			word_valid <= 1'b0;
			underflow_lat <= 1'b0;
		end else begin
			if (fifo_rd_en) begin
				rd_count <= rd_count_next;
				rd_gray <= rd_count_next ^ (rd_count_next >> 1);
			end
			if (!de) begin
				pix_count <= 11'd0;
				word_valid <= 1'b0;
			end else begin
				pix_count <= pix_count + 11'd1;
				if (take_even) begin
					word_valid <= !fifo_rd_empty;
					if (!fifo_rd_empty) word_hold <= fifo_rd_data;
					else underflow_lat <= 1'b1;
				end
			end
		end
	end

	// 组首一次承诺四字，返回时不再增减信用，避免串联入队、在飞、水位三次运算。
	// 解码、减法、比较分别寄存；八字余量覆盖水位更新前可能发出的组。
	always @(posedge clk_sdr or negedge rst_n_sdr) begin
		if (!rst_n_sdr) begin
			issued_count <= 0;
			rd_binary_sync <= 0;
			reserved_level <= 0;
			credit_ok <= 1'b0;
			overflow_lat <= 1'b0;
			done_toggle <= 1'b0;
		end else begin
			if (rd_ack) issued_count <= issued_count + 4;
			rd_binary_sync <= rd_binary;
			reserved_level <= issued_count - rd_binary_sync;
			credit_ok <= (reserved_level < LEVEL_LIMIT);
			if (rd_valid && fifo_wr_full) overflow_lat <= 1'b1;
			if (rd_restart_done) done_toggle <= ~done_toggle;
		end
	end

	// SDRAM 域同步器：多位计数只同步格雷码，其余跨域事件均为电平/翻转位。
	always @(posedge clk_sdr or negedge rst_n_sdr) begin
		if (!rst_n_sdr) begin
			rd_gray_meta <= 16'd0;
			rd_gray_sync <= 16'd0;
			run_meta <= 1'b0;
			run_sync <= 1'b0;
			restart_meta <= 1'b0;
			restart_sync <= 1'b0;
			restart_prev <= 1'b0;
		end else begin
			rd_gray_meta <= rd_gray;
			rd_gray_sync <= rd_gray_meta;
			run_meta <= run_enable;
			run_sync <= run_meta;
			restart_meta <= restart_toggle;
			restart_sync <= restart_meta;
			restart_prev <= restart_sync;
		end
	end

	// 像素域同步器：短的 done 脉冲先转翻转位，避免 150MHz -> 25MHz 漏采。
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) begin
			idle_meta <= 1'b0;
			idle_sync <= 1'b0;
			done_meta <= 1'b0;
			done_sync <= 1'b0;
			overflow_meta <= 1'b0;
			overflow_sync <= 1'b0;
		end else begin
			idle_meta <= rd_idle;
			idle_sync <= idle_meta;
			done_meta <= done_toggle;
			done_sync <= done_meta;
			overflow_meta <= overflow_lat;
			overflow_sync <= overflow_meta;
		end
	end

	// 双时钟 FIFO：两侧只接系统复位，运行中的对齐用排空而非复位完成。
	async_fifo #(
		.DATA_WIDTH (32),
		.ADDR_WIDTH (FIFO_AW)
	) u_pix_fifo (
		.wr_clk (clk_sdr), .wr_rst_n (rst_n_sdr),
		.wr_en (fifo_wr_en), .wr_data (rd_data), .wr_full (fifo_wr_full),
		.rd_clk (pix_clk), .rd_rst_n (rst_n_pix),
		.rd_en (fifo_rd_en), .rd_data (fifo_rd_data), .rd_empty (fifo_rd_empty)
	);

endmodule
