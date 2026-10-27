// =============================================================================
// framebuf_arbiter — 单时钟域四字组 SDRAM 仲裁，无跨域逻辑
// =============================================================================
// app_*、wr_ack、rd_ack 在同一边沿表示真实接受，不以注册命令提前出队。
// 组首地址对齐且四拍内恒定；DM=1 屏蔽，断流用 DM=F 补足完整组。
// 重启先捕获基址，待组结束、在飞返回和输出排空才回位并给 done。
// 看门狗按连续无回包计时；超时锁故障至系统复位，不伪造排空。
// ref_vld 中不接受命令，模型保留组相位；真核跨刷新相位尚待硬件核实。
// =============================================================================
`timescale 1ns / 1ps
module framebuf_arbiter #(
	parameter WR_ADDR_FROM_FIFO = 0,   // 保留外部组地址模式，默认顺序模式
	parameter ADDR_WIDTH = 21,         // SDRAM 字地址位宽
	parameter BUS_TURN_GAP = 2,        // 方向切换空拍数，0..255
	parameter WR_STARVE_LIMIT = 256,   // 写请求优先等待阈值
	parameter RD_TIMEOUT = 1024,       // 连续无回包看门狗，1..65535
	parameter FRAME_BASE = 21'd0,      // 四字对齐帧首地址
	parameter FRAME_WORDS = 18'd153600 // 帧字数，须为四的倍数
) (
	input wire clk,                   // SDRAM 域时钟
	input wire rst_n,                 // 低有效异步复位
	input wire sdr_init_done,         // 控制器初始化完成
	input wire ref_vld,               // 刷新窗口，禁止新接受命令
	input wire wr_req,                // FIFO 队头有效
	input wire [ADDR_WIDTH-1:0] wr_word_addr, // 外部四字组基址
	input wire [31:0] wr_data,         // FIFO 队头数据
	input wire [3:0] wr_dm,            // 高有效字节屏蔽
	output wire wr_ack,               // 本边沿真实消费队头
	input wire rd_req,                // 允许开启新的四字组
	output reg [31:0] rd_data,         // 注册的返回数据
	output reg rd_valid,              // 注册的返回有效
	output wire rd_ack,               // 真正接受读组首拍
	input wire rd_restart,            // 帧首重启单拍请求
	input wire [ADDR_WIDTH-1:0] rd_base, // 请求时捕获的重启基址
	output wire rd_idle,              // 无组/在飞/输出/重启/故障
	output reg rd_restart_done,       // 实际执行重启后的单拍完成
	output wire app_wr_en,            // 同拍接受写命令
	output wire [ADDR_WIDTH-1:0] app_wr_addr, // 四拍内保持组基址
	output wire [31:0] app_wr_din,      // 队头字或全屏蔽补拍零值
	output wire [3:0] app_wr_dm,        // 真写掩码或补拍 F
	output wire app_rd_en,            // 同拍接受读命令
	output wire [ADDR_WIDTH-1:0] app_rd_addr, // 四拍内保持组基址
	input wire sdr_rd_en,             // 控制器返回有效
	input wire [31:0] sdr_rd_dout,     // 控制器返回数据
	output wire busy,                // 控制器尚未初始化
	output reg err                   // 协议/超时粘滞异常
);
	localparam [1:0] A_IDLE = 2'd0;    // 选择方向
	localparam [1:0] A_WR = 2'd1;      // 原子写组
	localparam [1:0] A_RD = 2'd2;      // 原子读组并排空
	localparam [1:0] A_GAP = 2'd3;     // 换向保护
	localparam [ADDR_WIDTH-1:0] FRAME_LAST = FRAME_BASE + FRAME_WORDS - 4;
	reg [1:0] st;                     // 当前状态
	reg [1:0] next_st;                // 下一状态
	reg [ADDR_WIDTH-1:0] wr_addr;      // 顺序模式当前写组地址
	reg [ADDR_WIDTH-1:0] wr_base_hold; // 外部模式锁存的当前写组地址
	reg [ADDR_WIDTH-1:0] rd_addr;      // 当前读组地址
	reg [1:0] wr_beat;                // 下一写拍序号
	reg [1:0] rd_beat;                // 下一读拍序号
	reg wr_grp_active;                // 写组尚未走完
	reg rd_grp_active;                // 读组尚未走完
	reg rd_rst_pend;                  // 已捕获重启请求
	reg [ADDR_WIDTH-1:0] rd_base_hold; // 已捕获重启目标
	reg [ADDR_WIDTH-1:0] rd_frame_base; // 运行期读帧首，随重启基址更新
	reg [ADDR_WIDTH-1:0] rd_frame_last; // 运行期读帧末组首，随重启基址预计算
	reg [4:0] rd_outstanding;          // 精确在飞数，最多 31
	reg [15:0] rd_wait_cnt;            // 最近回包后的无进展计数
	reg rd_fault;                     // 不可安全自动恢复的读故障
	reg [15:0] wr_starve;             // 写需求的服务等待
	reg wr_starve_reached;            // 阈值提前一拍比较，避免比较器串入接受路径
	reg [7:0] gap_cnt;                // 换向空拍计数
	wire bus_ok;                     // 当前边沿可接受命令
	wire wr_starved;                 // 写侧已等待过久
	wire wr_last_beat;               // 写组第四拍
	wire rd_last_beat;               // 读组第四拍
	wire wr_new_allowed;             // 允许新的写组
	wire rd_new_allowed;             // 允许新的读组且有完整组信用
	wire wr_fire;                    // 真实写命令
	wire wr_real;                    // 含有效队头的真实写命令
	wire rd_fire;                    // 真实读命令
	wire rd_timeout;                 // 当前无回包且已超时
	wire wr_may_exit;                // 不在写组内且不再开组
	wire rd_may_exit;                // 不在读组内且已排空
	wire restart_apply;              // 当前可安全执行已捕获重启
	wire unexpected_return;          // 无在飞命令却收到回包

	assign bus_ok = rst_n && sdr_init_done && !ref_vld; // 接受边沿服从即时刷新
	assign wr_starved = wr_req && wr_starve_reached; // 不保留虚假饥饿
	assign wr_last_beat = (wr_beat == 2'd3); // 四拍后才换向
	assign rd_last_beat = (rd_beat == 2'd3); // 四拍后才换向
	assign wr_new_allowed = wr_req && (!rd_req || wr_starved || rd_fault); // 读优先并防写饥饿
	assign rd_new_allowed = rd_req && !wr_starved && !rd_rst_pend && !rd_restart
		&& (rd_outstanding <= 5'd27); // 组首预留四个信用
	assign wr_fire = (st == A_WR) && bus_ok && (wr_grp_active || wr_new_allowed); // 单一接受谓词
	assign wr_real = wr_fire && wr_req; // 真数据才使 FIFO 出队
	assign rd_timeout = (rd_outstanding != 5'd0) && !sdr_rd_en
		&& (rd_wait_cnt >= RD_TIMEOUT - 1); // 任何真实回包都重置无进展窗口
	assign rd_fire = (st == A_RD) && bus_ok && !rd_fault && !rd_timeout
		&& (rd_grp_active || rd_new_allowed); // 完整组使用首拍预留信用
	assign wr_may_exit = !wr_grp_active && !wr_new_allowed; // 退出与开组互斥
	assign rd_may_exit = !rd_grp_active && (rd_outstanding == 5'd0)
		&& (!rd_new_allowed || rd_fault); // 先停新组再等返回排空
	assign restart_apply = rd_rst_pend && !rd_restart && !rd_grp_active
		&& (rd_outstanding == 5'd0) && !rd_valid && !rd_fault && bus_ok; // 不混入迟到旧数据
	assign unexpected_return = sdr_rd_en && (rd_outstanding == 5'd0); // 防止计数下溢
	assign rd_ack = rd_fire && !rd_grp_active; // 真首拍而非请求统计
	assign wr_ack = wr_real; // FIFO 和控制器在同一边沿消费
	assign app_wr_en = wr_fire; // 不再延后一拍越过刷新边界
	assign app_wr_addr = WR_ADDR_FROM_FIFO ?
		(wr_grp_active ? wr_base_hold : wr_word_addr) : wr_addr; // 兼容外部地址并锁组首
	assign app_wr_din = wr_real ? wr_data : 32'd0; // 补拍值不会写入
	assign app_wr_dm = wr_real ? wr_dm : (wr_fire ? 4'hF : 4'h0); // 只屏蔽补写拍；读/空闲必须放开 DQM
	assign app_rd_en = rd_fire; // 命令与在飞计数同一个边沿
	assign app_rd_addr = rd_addr; // 四拍内恒定
	assign rd_idle = !rd_grp_active && (rd_outstanding == 5'd0) && !rd_valid
		&& !rd_fire && !rd_rst_pend && !rd_restart && !rd_fault; // 故障不得伪造排空
	assign busy = !sdr_init_done; // 保留初始化状态语义

	// 状态寄存器：状态选择与寄存分开。
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) st <= A_IDLE;
		else st <= next_st;
	end
	// 组边界换向；停止新组后才有机会把持续流水排空。
	always @(*) begin
		next_st = st;
		case (st)
			A_IDLE: begin
				if (bus_ok) begin
					if (wr_starved) next_st = A_WR;
					else if (rd_new_allowed && !rd_fault) next_st = A_RD;
					else if (wr_req) next_st = A_WR;
				end
			end
			A_WR: if (bus_ok && wr_may_exit) next_st = A_GAP;
			A_RD: if (bus_ok && rd_may_exit) next_st = A_GAP;
			A_GAP: if (gap_cnt == 8'd0) next_st = A_IDLE;
			default: next_st = A_IDLE;
		endcase
	end
	// 空拍和服务等待：无写需求也清残留饥饿标志。
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			gap_cnt <= 8'd0;
			wr_starve <= 16'd0;
			wr_starve_reached <= (WR_STARVE_LIMIT == 0);
		end else begin
			if (st == A_GAP) begin
				if (gap_cnt != 8'd0) gap_cnt <= gap_cnt - 8'd1;
			end else gap_cnt <= BUS_TURN_GAP;
			if (wr_real || !wr_req) begin
				wr_starve <= 16'd0;
				wr_starve_reached <= (WR_STARVE_LIMIT == 0);
			end else if (bus_ok && (wr_starve != 16'hFFFF)) begin
				wr_starve <= wr_starve + 16'd1;
				wr_starve_reached <= (WR_STARVE_LIMIT == 0) || (wr_starve >= WR_STARVE_LIMIT-1);
			end
		end
	end
	// 真实接受才推进写组，补拍也占用一拍但不消费 FIFO。
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			wr_addr <= FRAME_BASE;
			wr_base_hold <= FRAME_BASE;
			wr_beat <= 2'd0;
			wr_grp_active <= 1'b0;
		end else if (wr_fire) begin
			if (!wr_grp_active) wr_base_hold <= wr_word_addr;
			wr_grp_active <= !wr_last_beat;
			if (wr_last_beat) begin
				wr_beat <= 2'd0;
				if (wr_addr >= FRAME_LAST) wr_addr <= FRAME_BASE;
				else wr_addr <= wr_addr + 4;
			end else wr_beat <= wr_beat + 2'd1;
		end
	end
	// 捕获重启目标，排空后明确回复完成，而不是仅依赖短脉冲传播。
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			rd_addr <= FRAME_BASE;
			rd_beat <= 2'd0;
			rd_grp_active <= 1'b0;
			rd_rst_pend <= 1'b0;
			rd_base_hold <= FRAME_BASE;
			rd_frame_base <= FRAME_BASE;
			rd_frame_last <= FRAME_LAST;
			rd_restart_done <= 1'b0;
		end else begin
			rd_restart_done <= 1'b0;
			if (rd_restart) begin
				rd_rst_pend <= 1'b1;
				rd_base_hold <= rd_base;
				// 读基址可在双缓冲下指向任意帧首，回绕边界必须随之预计算。
				rd_frame_base <= rd_base;
				rd_frame_last <= rd_base + FRAME_WORDS - 4;
			end
			if (restart_apply) begin
				rd_addr <= rd_base_hold;
				rd_beat <= 2'd0;
				rd_rst_pend <= 1'b0;
				rd_restart_done <= 1'b1;
			end else if (rd_fire) begin
				rd_grp_active <= !rd_last_beat;
				if (rd_last_beat) begin
					rd_beat <= 2'd0;
					if (rd_addr >= rd_frame_last) rd_addr <= rd_frame_base;
					else rd_addr <= rd_addr + 4;
				end else rd_beat <= rd_beat + 2'd1;
			end
		end
	end
	// 精确在飞计数；故障后丢弃返回且保持故障，不能把旧数据冒充新帧。
	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			rd_data <= 32'd0;
			rd_valid <= 1'b0;
			rd_outstanding <= 5'd0;
			rd_wait_cnt <= 16'd0;
			rd_fault <= 1'b0;
			err <= 1'b0;
		end else begin
			rd_valid <= 1'b0;
			if (sdr_rd_en && (rd_outstanding != 5'd0)) begin
				rd_data <= sdr_rd_dout;
				if (!rd_fault) rd_valid <= 1'b1;
			end
			case ({rd_fire, sdr_rd_en})
				2'b10: rd_outstanding <= rd_outstanding + 5'd1;
				2'b01: if (rd_outstanding != 5'd0) rd_outstanding <= rd_outstanding - 5'd1;
				default: rd_outstanding <= rd_outstanding;
			endcase
			if ((rd_outstanding == 5'd0) || sdr_rd_en) rd_wait_cnt <= 16'd0;
			else if (rd_wait_cnt != 16'hFFFF) rd_wait_cnt <= rd_wait_cnt + 16'd1;
			if (rd_timeout || unexpected_return) begin
				rd_fault <= 1'b1;
				err <= 1'b1;
			end
		end
	end
endmodule
