// SD 扇区服务 -> BMP -> 带目标地址的写 FIFO -> SDRAM -> 同拍 RGB565。
// 双缓冲无缝切换：装载写后台帧，前台继续读旧帧，提交后下个垂直消隐换帧首。
// B2 转场：提交后先淡出到黑、全黑时翻帧首、再淡入，混合目标恒为黑故只需一路读。
// WIDTH 必须为 8 的倍数；两时钟域必须共同复位；SD 服务必须有块超时。
// 仅在完整像素数、所有写命令落盘后切换前台；装载失败保留上一帧。
// SEAMLESS=0 退回单帧缓冲：重载时共同复位存储数据通路，失败不保留旧帧。
`timescale 1ns / 1ps
module image_player #(
	parameter WIDTH = 640,
	parameter HEIGHT = 480,
	parameter FIFO_AW = 9,
	parameter LOAD_TIMEOUT = 100_000_000,
	parameter MEM_WORDS = 262_144,
	parameter SEAMLESS = 1,             // 1=双缓冲无缝切换，0=单帧缓冲
	parameter FADE_EN = 1,              // 1=换帧走淡出到黑再淡入，0=消隐期硬切换
	parameter FADE_FRAMES = 8           // 每个方向的渐变帧数，1 表示关闭转场
) (
	input wire pix_clk, rst_n_pix,
	input wire sdr_clk, sdr_clk_sft, rst_n_sdr,
	input wire sd_ready, sd_failed, blk_busy,
	input wire load_req,
	input wire [8:0] image_index,         // 1=IMG001.BMP
	output wire blk_start,
	output wire [31:0] blk_addr,
	input wire blk_done, blk_err,
	input wire [7:0] data_byte,
	input wire data_valid,
	input wire de,
	input wire [9:0] scan_y,             // 垂直消隐时必须 >= HEIGHT
	output wire [15:0] rgb565,
	output wire pixel_valid,
	// 缩放后的有效显示窗口（绝对坐标）。letterbox 区域本模块不写，
	// 顶层必须按这组值屏蔽，否则会漏出上一张图的残影。
	output wire [15:0] out_w, out_h, out_off_x, out_off_y,
	output reg image_ready,
	output wire loading,
	output reg failed,
	output reg [3:0] error_code,         // 1..5,10=loader；6=SD；7=像素数；8=SDRAM；9=装载无进度；11=SDRAM 初始化超时；12=写完成超时
	output wire [2:0] reader_status,
	output wire sdram_clk, sdram_cke, sdram_cs_n,
	output wire sdram_ras_n, sdram_cas_n, sdram_we_n,
	output wire [1:0] sdram_ba,
	output wire [10:0] sdram_addr,
	output wire [3:0] sdram_dm,
	inout wire [31:0] sdram_dq
);
	localparam [3:0] C_WAIT=0, C_RESET=1, C_MEM=2, C_START=3,
		C_LOAD=4, C_COMMIT=5, C_SHOW=6, C_FAIL=7;
	localparam WORDS_LINE = WIDTH/2;
	localparam FRAME_WORDS = WIDTH*HEIGHT/2;
	localparam FRAME_PIXELS = WIDTH*HEIGHT;
	localparam [20:0] FRAME_SPAN = FRAME_WORDS; // 一帧占用的 32 位字数，双缓冲的缓冲跨度
	// 转场：整帧恒定的亮度系数，只在垂直消隐推进，翻帧首发生在全黑那一拍。
	localparam [1:0] F_IDLE = 0, F_OUT = 1, F_IN = 2;
	localparam FADE_ON = FADE_EN && (FADE_FRAMES > 1);
	localparam [7:0] FADE_STEP = (FADE_FRAMES > 1) ? (256 / FADE_FRAMES) : 8'd1;
	reg [1:0] fade_state;
	reg [7:0] fade_alpha;                // 255=原样显示，0=全黑
	reg [3:0] state;
	reg [31:0] timer;
	reg [2:0] drain_cnt;                 // loader_done 后等缩放器末像素落地
	reg pending;
	reg [8:0] pending_index, selected_index;
	// 双缓冲：前台显示、后台装载，各占一整帧空间。装载目标永远是前台的另一半。
	// 单帧模式下 back_sel 恒为 0，读写都落在第 0 帧，行为与旧设计等价。
	reg front_sel;
	reg commit_pending;                  // 后台帧已就绪，等垂直消隐再换帧首
	wire back_sel = SEAMLESS ? ~front_sel : 1'b0;
	wire [20:0] back_off = back_sel ? FRAME_SPAN : 21'd0;
	wire [20:0] rd_base;                 // 当前显示帧首，rd_restart 那拍必须稳定
	// 装载通路每次重载都要清空；显示通路只在无有效帧时才复位，双缓冲不得打断前台。
	wire loader_enable = (state != C_WAIT) && (state != C_RESET);
	wire store_keep = SEAMLESS && image_ready;
	wire store_enable = loader_enable || store_keep;
	wire loader_async_pix = rst_n_pix && rst_n_sdr && loader_enable;
	wire loader_async_sdr = rst_n_pix && rst_n_sdr && loader_enable;
	wire store_async_pix = rst_n_pix && rst_n_sdr && store_enable;
	wire store_async_sdr = rst_n_pix && rst_n_sdr && store_enable;
	reg [2:0] loader_sync_pix;
	wire loader_rst_pix = loader_sync_pix[2];
	reg [2:0] loader_sync_sdr;
	wire loader_rst_sdr = loader_sync_sdr[2];
	reg [2:0] store_sync_pix;
	wire store_rst_pix = store_sync_pix[2];
	reg [2:0] store_sync_sdr;
	wire store_rst_sdr = store_sync_sdr[2];
	reg [1:0] front_sync_sdr;            // 前台索引跨到 sdr 域，供读重启采样
	reg [1:0] sdr_online;
	reg [1:0] init_sync, complete_sync, arb_error_sync;
	wire init_done, ref_vld, arb_error, refresh_error, writes_complete;
	wire loader_start = (state == C_START);
	wire loader_done, loader_fail;
	wire [3:0] loader_error;
	wire [31:0] pixel_count;
	localparam [9:0] HEIGHT_IN = HEIGHT;
	wire ext_vblank = (scan_y >= HEIGHT_IN); // 顶层把消隐编码成扫描行号越界
	// 缩放器信号必须在状态机之前声明：C_LOAD 的像素数校验要用 out_cfg_ok/out_pixels。
	wire        hdr_ok, scale_valid, scale_cfg_ok;
	wire [15:0] bmp_img_w, bmp_img_h, scale565, scale_x, scale_y;
	wire [15:0] scale_w, scale_h, scale_off_x, scale_off_y;
	wire [31:0] scale_pixels;


	// 装载通路：清空 loader、BMP 解析、写 FIFO 与组计数，避免旧事务污染下一张图。
	always @(posedge pix_clk or negedge loader_async_pix) begin
		if (!loader_async_pix) loader_sync_pix <= 3'd0;
		else loader_sync_pix <= {loader_sync_pix[1:0], 1'b1};
	end
	always @(posedge sdr_clk or negedge loader_async_sdr) begin
		if (!loader_async_sdr) loader_sync_sdr <= 3'd0;
		else loader_sync_sdr <= {loader_sync_sdr[1:0], 1'b1};
	end
	// 显示通路：整机复位或尚无有效帧才复位；双缓冲装载期间保持运行读旧帧。
	always @(posedge pix_clk or negedge store_async_pix) begin
		if (!store_async_pix) store_sync_pix <= 3'd0;
		else store_sync_pix <= {store_sync_pix[1:0], 1'b1};
	end
	always @(posedge sdr_clk or negedge store_async_sdr) begin
		if (!store_async_sdr) store_sync_sdr <= 3'd0;
		else store_sync_sdr <= {store_sync_sdr[1:0], 1'b1};
	end
	always @(posedge sdr_clk or negedge rst_n_sdr) begin
		if (!rst_n_sdr) front_sync_sdr <= 2'd0;
		else front_sync_sdr <= {front_sync_sdr[0], front_sel};
	end
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) sdr_online <= 0;
		else sdr_online <= {sdr_online[0], rst_n_sdr};
	end
	// 装载侧握手信号随装载复位重新起算，避免残留的完成标志提前放行下一次提交。
	always @(posedge pix_clk or negedge loader_rst_pix) begin
		if (!loader_rst_pix) begin
			init_sync <= 2'd0;
			complete_sync <= 2'd0;
		end else begin
			init_sync <= {init_sync[0], init_done};
			complete_sync <= {complete_sync[0], writes_complete};
		end
	end
	// 源故障随存储复位清除；同步值另需两拍消退，不能随装载复位直接丢掉。
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) arb_error_sync <= 2'd0;
		else arb_error_sync <= {arb_error_sync[0], arb_error || refresh_error};
	end
	assign loading = (state >= C_RESET) && (state <= C_COMMIT);
	reg vblank_d;
	wire vblank_rise = ext_vblank && !vblank_d;
	// 忙时只保存最后一次请求。索引在进入 RESET 时锁存，整个装载期保持。
	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) begin
			state <= C_WAIT;
			timer <= 0;
			drain_cnt <= 3'd0;
			pending <= 1'b0;
			pending_index <= 9'd1;
			selected_index <= 9'd1;
			image_ready <= 1'b0;
			failed <= 1'b0;
			error_code <= 0;
			front_sel <= 1'b0;
			commit_pending <= 1'b0;
			vblank_d <= 1'b0;
			fade_state <= F_IDLE;
			fade_alpha <= 8'hFF;
		end else begin
			vblank_d <= ext_vblank;
			if (load_req) begin
				pending <= 1'b1;
				pending_index <= image_index;
			end
			if (loading) timer <= timer + 1;
			// 后台帧写完整后挂起提交，等垂直消隐再换帧首，切换落在消隐内不撕裂。
			// 尚无有效帧时无需等待，直接提交即可开始首次显示。
			// 已有旧帧时先按帧淡出到黑，全黑那一拍才翻帧首，再逐帧淡入；
			// 混合目标恒为黑，所以全程只需读一帧，不额外占用读带宽。
			if (commit_pending) begin
				if (!image_ready) begin
					// 首帧没有可淡出的上一帧，直接提交并全亮。
					front_sel <= back_sel;
					image_ready <= 1'b1;
					commit_pending <= 1'b0;
					fade_alpha <= 8'hFF;
					fade_state <= F_IDLE;
				end else if (!FADE_ON) begin
					if (vblank_rise) begin
						front_sel <= back_sel;
						commit_pending <= 1'b0;
					end
				end else begin
					if (vblank_rise) begin
						if (fade_alpha > FADE_STEP) fade_alpha <= fade_alpha - FADE_STEP;
						else fade_alpha <= 8'h00;
					end
					// 上一拍已把系数压到 0，这一次消隐就是全黑换帧点。
					if ((fade_alpha == 8'h00) && vblank_rise) begin
						front_sel <= back_sel;
						commit_pending <= 1'b0;
						fade_state <= F_IN;
					end else begin
						fade_state <= F_OUT;
					end
				end
			end else if (fade_state == F_IN) begin
				if (vblank_rise) begin
					if (fade_alpha < (8'hFF - FADE_STEP)) fade_alpha <= fade_alpha + FADE_STEP;
					else begin
						fade_alpha <= 8'hFF;
						fade_state <= F_IDLE;
					end
				end
			end
			case (state)
				C_WAIT: if (sd_ready && !blk_busy) begin
					selected_index <= load_req ? image_index : (pending ? pending_index : 9'd1);
					pending <= 1'b0;
					timer <= 0;
					state <= C_RESET;
				end else if (sd_failed) begin
					failed <= 1'b1; error_code <= 6; state <= C_FAIL;
				end
				C_RESET: if (timer >= 16) begin
					timer <= 0; state <= C_MEM;
				end
				C_MEM: if (init_sync[1]) begin
					timer <= 0; state <= C_START;
				end
				C_START: begin timer <= 0; drain_cnt <= 3'd0; state <= C_LOAD; end
				// 看门狗按进度计时：每完成一个扇区就清零，LOAD_TIMEOUT 变为“单扇区无进度”上限，
				// 慢卡整帧装载超过 4 s 不再误报；真正停滞的扇区仍会触发错误码 9。
				C_LOAD: if (loader_fail) begin
					failed <= 1'b1; error_code <= loader_error; state <= C_FAIL;
				end else if (loader_done) begin
					// 缩放器输出比源像素晚一拍，最后一个目标像素可能在 loader_done
					// 之后才落进 pix_count；先等几拍再比对，否则好帧会被误判成像素数不符。
					if (drain_cnt != 3'd7) drain_cnt <= drain_cnt + 3'd1;
					else if (!scale_cfg_ok || (pixel_count != scale_pixels)) begin
						failed <= 1'b1; error_code <= 7; state <= C_FAIL;
					end else begin
						// 进提交段重新计时：C_LOAD 期间看门狗被扇区不断喂过，
						// 这里必须让 timer 只反映“等写完成”这一段，否则慢卡会被误判成 12。
						timer <= 0;
						state <= C_COMMIT;
					end
				end
				C_COMMIT: if (complete_sync[1]) begin
					commit_pending <= 1'b1; state <= C_SHOW;
				end
				C_SHOW, C_FAIL: if ((pending || load_req) && sd_ready && !blk_busy) begin
					selected_index <= load_req ? image_index : pending_index;
					pending <= 1'b0;
					// 双缓冲保留在显帧直到新帧提交；单帧必须立刻退掉，因为马上要覆盖它。
					if (!SEAMLESS) image_ready <= 1'b0;
					failed <= 1'b0; error_code <= 0;
					// 转场被新请求打断时立刻回到全亮：旧帧还在显示，不能停在暗态。
					// 转场挂起期间 commit_pending 一直没清，必须一并撤掉，否则这次
					// 提交会在新帧装载中途翻帧首，把半张新图翻到前台。
					if (FADE_ON && commit_pending) commit_pending <= 1'b0;
					fade_alpha <= 8'hFF;
					fade_state <= F_IDLE;
					timer <= 0; state <= C_RESET;
				end
				default: state <= C_WAIT;
			endcase
			// 扇区完成即喂狗（写在 case 之后，覆盖本拍的 timer+1）。
			if ((state == C_LOAD) && blk_done) timer <= 0;
			// 主动复位时等旧故障同步值消退；双缓冲旧帧仍在显示时继续监视。
			if ((loading && (timer >= LOAD_TIMEOUT)) || (((loading && (state != C_RESET)) || image_ready) && arb_error_sync[1]) ||
				(((state == C_LOAD) || (state == C_COMMIT) || image_ready) && !sdr_online[1])) begin
				// 存储侧故障必须先退掉旧帧：显示通路共用复位靠 image_ready 释放，
				// 否则粘滞错误永远清不掉。装载侧失败则保留上一帧继续显示。
				if (!SEAMLESS || arb_error_sync[1] || !sdr_online[1]) image_ready <= 1'b0;
				failed <= 1'b1;
				// 超时按阶段细分：9=C_LOAD 无进度，11=C_MEM 等 SDRAM 初始化，12=C_COMMIT 等写完成。
				error_code <= (arb_error_sync[1] || !sdr_online[1]) ? 4'd8 :
				              (state == C_MEM)    ? 4'd11 :
				              (state == C_COMMIT) ? 4'd12 : 4'd9;
				commit_pending <= 1'b0;
				fade_alpha <= 8'hFF;
				fade_state <= F_IDLE;
				state <= C_FAIL;
			end
		end
	end

	wire bmp_start, byte_valid, byte_sof, hdr_fail;
	wire [15:0] bmp_w, bmp_h, pixel565, pixel_y;
	wire [7:0] byte_data;
	wire bmp_pixel_valid, fifo_wr_en, fifo_full;
	wire [31:0] fifo_wr_data;
	wire [3:0] fifo_wr_dm;
	// loader 的 pix_count 现在统计缩放后的有效像素数，供 C_LOAD 与 out_pixels 比对。
	img_loader #(.CHAIN_MAX(4096)) u_loader (
		.clk(pix_clk), .rst_n(loader_rst_pix), .start(loader_start),
		.img_index(selected_index), .cfg_w(WIDTH[15:0]), .cfg_h(HEIGHT[15:0]),
		.busy(), .done(loader_done), .fail(loader_fail), .err_code(loader_error),
		.pix_count(pixel_count), .blk_start(blk_start), .blk_addr(blk_addr),
		.blk_done(blk_done), .blk_err(blk_err), .data_byte(data_byte), .data_valid(data_valid),
		.bmp_start(bmp_start), .bmp_exp_w(bmp_w), .bmp_exp_h(bmp_h),
		.byte_valid(byte_valid), .byte_data(byte_data), .byte_sof(byte_sof),
		.bmp_hdr_fail(hdr_fail), .pix_valid(scale_valid), .pix_rgb565(scale565),
		.fifo_wr_en(fifo_wr_en), .fifo_wr_data(fifo_wr_data),
		.fifo_wr_dm(fifo_wr_dm), .fifo_wr_full(fifo_full)
	);
	// CHECK_SIZE(0)：缩放模式下任意分辨率都能映射进 WIDTH×HEIGHT，
	// 不再要求源图恰好等于容器尺寸；img_w/img_h 仍照常输出给缩放器。
	bmp_parser #(.CHECK_SIZE(0)) u_bmp (
		.clk(pix_clk), .rst_n(loader_rst_pix), .start(bmp_start), .exp_w(bmp_w), .exp_h(bmp_h),
		.byte_valid(byte_valid), .byte_data(byte_data), .byte_sof(byte_sof),
		.hdr_ok(hdr_ok), .hdr_fail(hdr_fail), .err_code(), .img_w(bmp_img_w), .img_h(bmp_img_h), .data_off(),
		.pix_valid(bmp_pixel_valid), .pix_rgb565(pixel565), .pix_x(), .pix_y(pixel_y)
	);
	// hdr_ok 与 img_w/img_h 同拍寄存，所以脉冲那拍 src_w/src_h 已是新值。
	// 缩放器在本帧首像素到达前有几十拍余量跑完 21 位除法流水。
	img_scaler #(.DST_W(WIDTH), .DST_H(HEIGHT)) u_scaler (
		.clk(pix_clk), .rst_n(loader_rst_pix),
		.src_start(hdr_ok), .src_w(bmp_img_w), .src_h(bmp_img_h),
		.src_valid(bmp_pixel_valid), .src_rgb565(pixel565), .src_y(pixel_y),
		.dst_valid(scale_valid), .dst_rgb565(scale565), .dst_x(scale_x), .dst_y(scale_y),
		.out_w(scale_w), .out_h(scale_h), .out_off_x(scale_off_x), .out_off_y(scale_off_y),
		.out_cfg_ok(scale_cfg_ok), .out_pixels(scale_pixels)
	);
	assign out_w = scale_w;
	assign out_h = scale_h;
	assign out_off_x = scale_off_x;
	assign out_off_y = scale_off_y;
	// 缩放器的 dst_x/dst_y 在无效拍保持上一像素的坐标 —— loader 拼字后那一拍
	// 仍需按刚完成的奇像素算字地址，坐标必须稳定，不能每拍刷新。
	// 双缓冲下写到后台帧，前台继续读旧帧，两者地址互不重叠。
	wire [20:0] word_addr = scale_y * WORDS_LINE + (scale_x >> 1) + back_off;
	wire [56:0] fifo_out;
	wire fifo_empty, wr_ack;
	reg [56:0] write_head;
	reg write_head_valid;
	wire fifo_pop = !fifo_empty && (!write_head_valid || wr_ack);
	// 异步 RAM 队头先寄存，避免大扇入读复用器直接串入 SDRAM 命令路径。
	always @(posedge sdr_clk or negedge loader_rst_sdr) begin
		if (!loader_rst_sdr) begin write_head <= 0; write_head_valid <= 1'b0; end
		else if (fifo_pop) begin write_head <= fifo_out; write_head_valid <= 1'b1; end
		else if (wr_ack) write_head_valid <= 1'b0;
	end
	async_fifo #(.DATA_WIDTH(57), .ADDR_WIDTH(FIFO_AW)) u_write_fifo (
		.wr_clk(pix_clk), .wr_rst_n(loader_rst_pix), .wr_en(fifo_wr_en),
		.wr_data({word_addr[20:2], 2'b00, fifo_wr_dm, fifo_wr_data}), .wr_full(fifo_full),
		.rd_clk(sdr_clk), .rd_rst_n(loader_rst_sdr),
		.rd_en(fifo_pop), .rd_data(fifo_out), .rd_empty(fifo_empty)
	);

	// 至少收齐四字再启动组。这样串行 SD 的稀疏像素不会触发仲裁器补拍而丢地址。
	reg [17:0] produced;
	reg [15:0] produced_gray;
	reg [15:0] prod_meta, prod_sync;
	reg [17:0] consumed;
	reg [15:0] consumed_gray;
	reg [2:0] batch_left;
	// 只跨域完整四字组的格雷码。组计数不等即有完整组，省去解码和宽减法。
	wire [15:0] produced_group_next = produced[17:2] + 16'd1;
	wire [15:0] consumed_group_next = consumed[17:2] + 16'd1;
	wire write_request = write_head_valid && (batch_left != 0);
	always @(posedge pix_clk or negedge loader_rst_pix) begin
		if (!loader_rst_pix) begin produced <= 0; produced_gray <= 0; end
		else if (fifo_wr_en && !fifo_full) begin
			produced <= produced + 18'd1;
			if (produced[1:0] == 2'd3)
				produced_gray <= produced_group_next ^ (produced_group_next >> 1);
		end
	end
	reg [17:0] written;
	reg [3:0] write_settle;
	wire app_wr_en, app_rd_en;
	wire [20:0] app_wr_addr, app_rd_addr;
	wire [31:0] app_wr_din;
	wire [3:0] app_wr_dm;
	// 缩放后只写窗口内的像素，字数不再是 FRAME_WORDS。out_pixels 在整个
	// 装载期稳定（只在下一次 src_start 更新），跨域取两级同步即可。
	reg [31:0] pixels_meta, pixels_sync;
	always @(posedge sdr_clk or negedge loader_rst_sdr) begin
		if (!loader_rst_sdr) begin pixels_meta <= 32'd0; pixels_sync <= 32'd0; end
		else begin pixels_meta <= scale_pixels; pixels_sync <= pixels_meta; end
	end
	// 每两像素拼一字；out_w 恒为偶数，故字数恰为 out_pixels/2。
	// expect_words 为 0 时必须判未完成：装载刚开始 written 也是 0，
	// 否则会在首个字落盘前就误报完成。
	wire [17:0] expect_words = pixels_sync[18:1];
	assign writes_complete = (expect_words != 18'd0) && (written == expect_words)
	                      && (write_settle == 15);
	always @(posedge sdr_clk or negedge loader_rst_sdr) begin
		if (!loader_rst_sdr) begin
			prod_meta <= 0; prod_sync <= 0; consumed <= 0; consumed_gray <= 0; batch_left <= 0;
			written <= 0; write_settle <= 0;
		end else begin
			prod_meta <= produced_gray; prod_sync <= prod_meta;
			// 先锁定一个完整组，再对仲裁器提出请求，比较器不串入 FIFO 接受路径。
			if ((batch_left == 0) && (prod_sync != consumed_gray)) batch_left <= 3'd4;
			else if (wr_ack) begin
				consumed <= consumed + 18'd1;
				if (batch_left == 1)
					consumed_gray <= consumed_group_next ^ (consumed_group_next >> 1);
				batch_left <= batch_left - 3'd1;
			end
			if (app_wr_en && !ref_vld) begin written <= written + 18'd1; write_settle <= 0; end
			else if (write_settle != 15) write_settle <= write_settle + 1'b1;
		end
	end

	wire rd_req, rd_ack, rd_valid, rd_idle, rd_restart, rd_restart_done;
	wire [31:0] rd_data, sdr_rd_dout;
	wire sdr_rd_en;
	// 显示侧帧首跨到 sdr 域后采样，rd_restart 那拍必须稳定。
	assign rd_base = front_sync_sdr[1] ? FRAME_SPAN : 21'd0;
	framebuf_arbiter #(.WR_ADDR_FROM_FIFO(1), .FRAME_WORDS(FRAME_WORDS)) u_arb (
		.clk(sdr_clk), .rst_n(store_rst_sdr), .sdr_init_done(init_done), .ref_vld(ref_vld),
		.wr_req(write_request), .wr_word_addr(write_head[56:36]),
		.wr_data(write_head[31:0]), .wr_dm(write_head[35:32]), .wr_ack(wr_ack),
		.rd_req(rd_req), .rd_ack(rd_ack), .rd_data(rd_data), .rd_valid(rd_valid), .rd_idle(rd_idle),
		.rd_restart(rd_restart), .rd_base(rd_base), .rd_restart_done(rd_restart_done),
		.app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr), .app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm),
		.app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr), .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout),
		.busy(), .err(arb_error)
	);
	// reader 两侧只在整个存储数据通路重置或尚未提交图片时共同保持复位。
	wire reader_async_sdr = store_rst_sdr && image_ready;
	reg [2:0] reader_sync_sdr;
	always @(posedge sdr_clk or negedge reader_async_sdr) begin
		if (!reader_async_sdr) reader_sync_sdr <= 0;
		else reader_sync_sdr <= {reader_sync_sdr[1:0], 1'b1};
	end
	wire [15:0] reader565;
	pix_reader #(.PIX_PER_LINE(WIDTH), .FRAME_LINES(HEIGHT), .FIFO_AW(9), .LEVEL_HI(384)) u_reader (
		.clk_sdr(sdr_clk), .rst_n_sdr(reader_sync_sdr[2]),
		.rd_req(rd_req), .rd_ack(rd_ack), .rd_data(rd_data), .rd_valid(rd_valid), .rd_idle(rd_idle),
		.rd_restart(rd_restart), .rd_base(rd_base), .rd_restart_done(rd_restart_done),
		.pix_clk(pix_clk), .rst_n_pix(store_rst_pix && image_ready), .de(de), .active_y(scan_y),
		.pix_rgb565(reader565), .pix_valid(pixel_valid), .stat(reader_status)
	);
	// 转场混合必须与 de 同拍：reader 是组合输出，中间不能插寄存器，否则像素整拍错位。
	fade_mixer u_fade (.rgb_in(reader565), .level(fade_alpha), .rgb_out(rgb565));
	sdram_ctrl_wrap #(.SIM_MEM_WORDS(MEM_WORDS)) u_sdram (
		.clk(sdr_clk), .clk_sft(sdr_clk_sft), .rst_n(store_rst_sdr),
		.init_done(init_done), .ref_vld(ref_vld), .busy(),
		.refresh_error(refresh_error),
		.app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr), .app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm),
		.app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr), .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout),
		.sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
		.sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
		.sdram_ba(sdram_ba), .sdram_addr(sdram_addr), .sdram_dm(sdram_dm), .sdram_dq(sdram_dq)
	);
endmodule
