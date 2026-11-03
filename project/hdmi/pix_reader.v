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
//
// ---------------------------------------------------------------------------
// v2 增补（ARCH_ADDENDUM_VIDEO_PATH.md §9.2）：垂直行映射
// ---------------------------------------------------------------------------
// 新增 src_w/src_h 两输入与 src_y/src_row_hold/map_ident 三输出，用 16 位 DDA
// 精确复现 src_y = floor(active_y * src_h / 480)：
//   每行首 y_acc += src_h；若 y_acc + src_h >= 480 则 y_acc -= 480 且 src_y+1，
//   否则本行 src_row_hold=1（面板行重复上一源行）。
// src_h == FRAME_LINES 时每行必然推进一次，src_y 恒等于 active_y（恒等旁路）。
// DDA 只用「加法 + 比较 + 条件减」，无乘法器，与 RESOURCE_BUDGET 的 +30 LUT
// / 16 FF 预算一致。
//
// 落点说明（与 addendum 伪代码的差异，实测确认）：现 RTL 中 SDRAM 顺序读地址
// 完全由 framebuf_arbiter 内部的 rd_addr 每次 +4 字自主推进，本模块不存在
// row_addr / new_frame 信号，故 addendum 的「row_addr <= row_addr + PIX_PER_LINE」
// 无落点。垂直行重复的真正生效点在下游消费侧（content_mux / pix_mosaic 按
// src_row_hold 决定是否复用上一行），本模块只负责给出映射结果，
// 状态机、FIFO、P_* 六态、行首/行内逻辑、LEVEL_HI 全部零改动。
// 因此 SDRAM 侧读带宽不因档位变化而增加：仍按 640x480 全尺寸顺序读出。
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
	input wire [ADDR_WIDTH-1:0] rd_base,// 当前显示缓冲区首地址，由上层选定
	input wire pix_clk,                 // 像素域时钟
	input wire rst_n_pix,               // 像素域低有效复位
	input wire de,                      // 当前拍处于有效显示区
	input wire [10:0] active_x,          // 有效列号；Key9 水平窗口判据（v3）
	input wire [Y_WIDTH-1:0] active_y,   // 有效行号；允许消隐归零或给出原始消隐行号
	input wire [15:0] src_w,            // 当前档源宽（v2：仅用于映射有效性判定）
	input wire [15:0] src_h,            // 当前档源高：240/300/384/432/480
	input wire [15:0] win_w,            // Key9 窗口宽：本步唯一驱动水平降采样的参数
	input wire [15:0] win_h,            // Key9 窗口高：只参与满屏判据；纵向 1:1 裁剪，不缩放
	input wire [15:0] win_off_x,        // Key9 窗口左上角列号
	input wire [15:0] win_off_y,        // Key9 窗口左上角行号：只参与满屏判据；纵向不缩放
	output wire [15:0] src_y,           // 本行对应的源行号，行首边沿寄存
	output wire src_row_hold,           // 高：本行不推进源行（重复上一源行）
	output wire map_ident,              // 高：src_h==480，映射为恒等旁路
	output wire [15:0] pix_rgb565,       // 偶像素低半字、奇像素高半字，组合输出
	output wire pix_valid,              // 当前拍确有像素，不额外延迟 de
	output wire out_valid,              // 窗口内有效；满屏档与 pix_valid 逐拍完全一致
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
	reg [15:0] y_acc;                  // 垂直 DDA 余数累加器
	reg [15:0] src_y_reg;              // 本行对应的源行号
	reg src_row_hold_reg;              // 本行是否重复上一源行
	wire line_last;                    // 有效区内每行最后一拍
	wire new_frame;                    // 本行为帧末行，下一行开启新帧
	wire row_advance;                  // 行末推进 DDA 的事件
	wire src_ok;                       // 档位参数有效
	wire [15:0] src_h_eff;             // 钳位后的源高，恒等时强制 480
	wire [16:0] y_sum;                 // y_acc + src_h_eff
	wire row_step;                     // 本行是否推进源行
	wire [16:0] y_new;                 // 扣除 480 后的新余数
	reg [15:0] h_acc;                  // 水平 DDA 信用累加器（Key9 窗口降采样）
	wire win_bad;                      // 窗口参数非法/超界：回落恒等
	wire h_ident;                      // 水平恰好满屏且无偏移
	wire use_key9;                     // 真正启用水平降采样
	wire [15:0] win_w_eff;             // 钳位后的窗口宽
	wire [15:0] active_x16;            // active_x 零扩展到 16 位
	wire [15:0] win_end_x;             // 窗口右边界（开区间）
	wire in_win_x;                     // 本拍落在窗口内的有效列
	// pix_valid_raw 在像素输出段用带初值的 wire 声明（声明 + 赋值一步完成），
	// 此处不能再前置声明一次：Verilog-2001 里 wire x; 与 wire x = expr; 是两个
	// 声明语句，同一作用域重复声明会报 (vlog-2388) already declared。
	wire h_take;                       // 本拍取字信用已够
	wire h_pop;                        // 本拍真正出队一个字（信用够且 FIFO 非空）
	wire take_word;                    // 统一出队事件：恒等档等价 take_even
	wire [15:0] h_acc_next;            // 水平累加器次态
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
	// v3：出队事件统一由 take_word 决定（恒等档 take_word === take_even，逐拍等价）。
	assign fifo_rd_en = !fifo_rd_empty && ((state == P_DRAIN) || take_word); // 排空和显示共用出队
	assign fifo_wr_en = rd_valid && !fifo_wr_full; // 写入与返回在同一边沿发生
	assign rd_count_next = rd_count + 1'b1; // 模计数位宽大于最大占用，允许自然回绕
	assign rd_req = run_sync && credit_ok; // 停请求门控保持即时响应
	assign rd_restart = restart_sync ^ restart_prev; // 翻转事件恢复为 SDRAM 单拍
	// v3：恒等档（use_key9=0）逐拍走原奇偶半字通路，与改造前完全一致；
	// 降采样档（use_key9=1）每个取到的字就是一整行的下一个显示像素，取低半字
	//（偶列），不再有 pix_count 奇偶语义，但总取字数仍为每行 PIX_PER_LINE/2。
	// out_valid 与 pix_valid 由同一表达式驱动，逐拍恒等，避免下游选错信号。
	wire pix_valid_raw = de && display_enable &&
		(pix_count[0] ? word_valid : !fifo_rd_empty); // 改造前语义，恒等档原样保留
	assign out_valid = use_key9 ? h_pop : pix_valid_raw;
	assign pix_valid = out_valid;
	assign pix_rgb565 = use_key9 ?
		(out_valid ? fifo_rd_data[15:0] : 16'd0) :
		(!out_valid ? 16'd0 :
		(pix_count[0] ? word_hold[31:16] : fifo_rd_data[15:0])); // 与 de 同拍，不增加像素延迟
	assign stat = {armed, overflow_sync, underflow_lat}; // 全部状态已归入像素域

	// -----------------------------------------------------------------------
	// v2 垂直行映射：src_y = floor(active_y * src_h / 480)
	// 在每行最后一个有效像素处推进一次 16 位余数累加器：溢出则源行 +1 并扣除
	// 480，未溢出则下一行标 src_row_hold=1（重复同一源行）。推进点放在行末而
	// 不是行首，保证 src_y/src_row_hold 在整行内稳定（行末更新后经水平消隐
	// 才进入下一行）。全程只有加法/比较/条件减，无乘法器。
	// 档位参数非法（src_w=0 或 src_h 越界）时退回恒等映射，避免越界传播。
	// -----------------------------------------------------------------------
	localparam [15:0] FRAME_LINES16 = FRAME_LINES;
	localparam [10:0] LAST_PIX = PIX_PER_LINE - 1;
	assign src_ok = (src_w != 16'd0) && (src_h != 16'd0) &&
		(src_h <= FRAME_LINES16);
	assign src_h_eff = src_ok ? src_h : FRAME_LINES16;
	assign map_ident = (src_h_eff == FRAME_LINES16);
	assign line_last = de && (pix_count == LAST_PIX);        // 本行最后一个有效像素
	assign new_frame = line_last && (active_y == FRAME_LINES - 1); // 下一行进入新帧
	assign row_advance = line_last && !new_frame;            // 下一行仍在本帧内
	assign y_sum = {1'b0, y_acc} + {1'b0, src_h_eff};
	assign row_step = (y_sum >= FRAME_LINES);
	assign y_new = row_step ? (y_sum - FRAME_LINES) : y_sum;
	assign src_y = src_y_reg;
	assign src_row_hold = src_row_hold_reg;

	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) begin
			y_acc <= 16'd0;
			src_y_reg <= 16'd0;
			src_row_hold_reg <= 1'b0;
		end else if (new_frame) begin
			y_acc <= 16'd0;
			src_y_reg <= 16'd0;
			src_row_hold_reg <= 1'b0;
		end else if (row_advance) begin
			y_acc <= y_new[15:0];
			if (row_step) begin
				src_y_reg <= src_y_reg + 16'd1;
				src_row_hold_reg <= 1'b0;
			end else begin
				src_row_hold_reg <= 1'b1;
			end
		end
	end

	// -----------------------------------------------------------------------
	// v3 Key9：水平窗口降采样（纵向 1:1 裁剪，不做垂直缩放 —— 见 KEY9_RULING.md）
	// -----------------------------------------------------------------------
	// 语义：输出恒 PIX_PER_LINE x FRAME_LINES。窗口 win_w x win_h 内显示的是
	// 「横向压满 + 纵向 1:1 截取」：横向把整条源行压缩进 win_w 列（等比），
	// 纵向按源行号 1:1 取中间 win_h 行（**是裁剪，纵向不缩放**，见 KEY9_RULING.md）。
	// 本步只驱动水平方向：窗口内第 j
	// 列显示源列 floor(j * 640 / win_w)，即窗口 win_w 拍内取完整个源行的 320 字
	// （一字 = 两相邻像素，取低半字 = 偶列像素），一行总消耗仍 320 字，SDRAM 读
	// 带宽零增加。窗口外（active_x < win_off_x 或 >= win_off_x + win_w）
	// out_valid=0 且 pix_rgb565=0，FIFO 不动。
	//
	// 累加器：窗口内每列加 320、阈值 win_w、真正取到字才减 win_w，取字率恒为
	// 320/win_w，恰好 win_w 列取满一整行的 320 字。每行开头（!de 或 !display_enable）
	// 把信用重置为 win_w，保证「窗口第 0 列必取」且行与行之间不累积漂移；窗口外
	// 保持不动。全程只有加法/比较/条件减，无乘法器无除法器。
	//
	// 恒等档硬判绕过：水平满屏（win_w>=640 且 off_x==0）或窗口参数非法/超界时
	// use_key9=0，走原 take_even 通路 —— 逐拍行为与改造前完全相同，这是防退化的
	// 最后防线（不让 DDA「自然退化」）。
	// pix_count 语义零改动（仍承担行内计数、line_last、in_vblank 判定）。
	// -----------------------------------------------------------------------
	localparam [15:0] LINE_PIX16 = PIX_PER_LINE;
	localparam [15:0] WORDS_LINE16 = PIX_PER_LINE / 2; // 一行 320 字，等于窗口内必须取的字数
	// 窗口参数分三类：
	//   h_ident  —— 水平满屏且无偏移（win_w>=640, off_x==0）：走原通路，逐拍等价改造前
	//   win_bad  —— 非法或超出一行（win_w<320 装不下一整行的 320 字、off_x+win_w>640）：
	//               回落到恒等，宁可直通也不输出错行
	//   其余     —— 正常降采样档
	assign h_ident = (win_w >= LINE_PIX16) && (win_off_x == 16'd0);
	assign win_bad = (win_w == 16'd0) || (win_w < WORDS_LINE16) ||
		((win_off_x + win_w) > LINE_PIX16);
	assign use_key9 = !h_ident && !win_bad;
	assign win_w_eff = use_key9 ? win_w : LINE_PIX16;
	assign active_x16 = {5'd0, active_x};
	assign win_end_x = win_off_x + win_w_eff;
	assign in_win_x = use_key9 && de && display_enable &&
		(active_x16 >= win_off_x) && (active_x16 < win_end_x);
	// 信用累加：窗口内每列加 320 字，真正取到一字才扣 win_w（用 h_pop 不用 h_take，
	// 否则下溢时信用会凭空泄漏）。取字率恒为 320/win_w，win_w 列内恰好取满 320 字
	// —— 一整行的字全部由窗口内拍消耗，窗口外零消耗，SDRAM 读带宽不变。
	// win_w >= WORDS_LINE16 是硬约束：每拍至多取 1 字，窗口窄于 320 列就装不下
	// 一整行 320 字（Key9 五档最小 320，正好卡在边界上，留有余量）。
	assign h_take = in_win_x && (h_acc >= win_w_eff);
	assign h_pop = h_take && !fifo_rd_empty;
	assign take_word = use_key9 ? h_take : take_even;   // 恒等档逐拍等价 take_even
	assign h_acc_next = h_pop ? (h_acc + WORDS_LINE16 - win_w_eff) :
		(h_acc + WORDS_LINE16);
	// out_valid 只在像素输出段（上方 assign out_valid = use_key9 ? h_pop : pix_valid_raw）
	// 驱动一次。此处不得再写 assign out_valid = h_pop; —— 那会成为第二驱动源，
	// 而 lint_verilog.py 只查 always 块级 E2、vlog 对 assign 多驱动也静默，
	// 这类错误只有 vsim 实跑或人眼才看得见。

	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix) h_acc <= 16'd0;
		else if (!de || !display_enable) h_acc <= win_w_eff; // 行首/帧首预载满信用
		else if (in_win_x) h_acc <= h_acc_next;              // 窗口外保持满载不动
	end

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
				// v3：锁存时机必须与出队时机 take_word 同拍（恒等档等价原 take_even）。
				if (take_word) begin
					word_valid <= !fifo_rd_empty;
					if (!fifo_rd_empty) word_hold <= fifo_rd_data;
					else underflow_lat <= 1'b1;  // 信用够但 FIFO 空：降采样档也必须点亮
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
		.wr_almost_full (),
		.rd_clk (pix_clk), .rd_rst_n (rst_n_pix),
		.rd_en (fifo_rd_en), .rd_data (fifo_rd_data), .rd_empty (fifo_rd_empty)
	);

endmodule
