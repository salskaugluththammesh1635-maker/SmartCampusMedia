// =============================================================================
// ax_debounce.v — 官方单路按键消抖模块【参考件 · 未参与编译】
// -----------------------------------------------------------------------------
// 【为什么保留这个文件】
//   本项目的 4×4 矩阵键盘需要 16 路并行消抖，且必须"扫到哪一行才更新哪一行
//   的计数器"，与本模块（单路按键）的适用场景不同 → 故自研了
//   rtl/input/key_matrix_4x4.v。此文件保留作为**实现对照**，
//   便于对比两种消抖思路的差异。
//
// 【与自研版的关键差异】
//   1) 本模块只能处理"一路"按键；矩阵键盘需要 16 路并行计数
//   2) 复位为**高有效**（always @(posedge rst)），而本项目全系统统一采用
//      低有效 rst_n —— 直接混用会导致复位逻辑相反，是移植时的典型坑
//   3) 阈值算法: TIMER_MAX_VAL = MAX_TIME(ms) × 1000 × FREQ(MHz)，
//      按"时钟以 MHz 为单位"直接换算；自研版用 CLK_FREQ_HZ / 1000 的写法
//
// 【来源】官方示例（安路 FPGA 随板例程），未做任何修改。
// 【状态】未参与任何 TD 工程编译（仅作参考资料保留）。
// =============================================================================
module  ax_debounce 
(
    input       clk, 
    input       rst, 
    input       button_in,
    output reg  button_posedge,
    output reg  button_negedge,
    output reg  button_out
);
//// ---------------- internal constants --------------
parameter N = 32 ;           // 消抖计数器的位宽。作用: 决定计数器能表示的最大值
                             //   32 位足以容纳 MAX_TIME × 1000 × FREQ 的任意合理组合
parameter FREQ = 50;         // 时钟频率，单位 **MHz**（注意单位！）
                             //   ⚠️ 本项目自研模块用的是 CLK_FREQ_HZ（单位 Hz），
                             //      两者差 100 万倍，移植时务必换算，否则消抖时间会错得离谱
parameter MAX_TIME = 20;     // 消抖时长(ms)。机械触点抖动约 5~10ms，取 20ms 有 2 倍余量
localparam TIMER_MAX_VAL =   MAX_TIME * 1000 * FREQ;
                             // ↑ 作用: 计数目标值 = 消抖时长(ms) × 1000 × 时钟频率(MHz)
                             //   例: 20 × 1000 × 50 = 1_000_000 个时钟周期 = 20ms @50MHz
                             //   计数器数到这个值才认可按键状态变化
////---------------- internal variables ---------------
reg  [N-1 : 0]  q_reg;      // timing regs
reg  [N-1 : 0]  q_next;
reg DFF1, DFF2;             // input flip-flops
wire q_add;                 // control flags
wire q_reset;
reg button_out_d0;
//// ------------------------------------------------------

////contenious assignment for counter control
assign q_reset = (DFF1  ^ DFF2);          // xor input flip flops to look for level chage to reset counter
assign q_add = ~(q_reg == TIMER_MAX_VAL); // add to counter when q_reg msb is equal to 0
    
//// combo counter to manage q_next 
always @ ( q_reset, q_add, q_reg)
begin
    case( {q_reset , q_add})
        2'b00 :
                q_next <= q_reg;
        2'b01 :
                q_next <= q_reg + 1;
        default :
                q_next <= { N {1'b0} };
    endcase     
end

//// Flip flop inputs and q_reg update
always @ ( posedge clk or posedge rst)
begin
    if(rst == 1'b1)
    begin
        DFF1 <= 1'b0;
        DFF2 <= 1'b0;
        q_reg <= { N {1'b0} };
    end
    else
    begin
        DFF1 <= button_in;
        DFF2 <= DFF1;
        q_reg <= q_next;
    end
end

//// counter control
always @ ( posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		button_out <= 1'b1;
    else if(q_reg == TIMER_MAX_VAL)
        button_out <= DFF2;
    else
        button_out <= button_out;
end

always @ ( posedge clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		button_out_d0 <= 1'b1;
		button_posedge <= 1'b0;
		button_negedge <= 1'b0;
	end
	else
	begin
		button_out_d0 <= button_out;
		button_posedge <= ~button_out_d0 & button_out;
		button_negedge <= button_out_d0 & ~button_out;
	end	
end
endmodule


