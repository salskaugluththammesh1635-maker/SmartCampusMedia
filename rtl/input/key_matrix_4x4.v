// =============================================================================
// key_matrix_4x4.v
// 功能: 4x4 矩阵键盘扫描 + 逐键消抖 + 按键事件输出（DMZ-EG4S20 板级适配）
// 板级事实（来源: 走近FPGA 表1.1 + 核心板原理图p4 KEY 区, 已核实）:
//   行 Key_Row[3:0] = E10,C10,F9,D9  （FPGA 输出, 低电平选通行）
//   列 Key_Col[3:0] = E11,D11,C11,F10（FPGA 输入, 行网络 10k 上拉, 按下为低）
//   键号: KEY(行 r, 列 c) = 4*r + c, 即 KEY0~KEY15
// 【工作原理】
//   1) 扫描: 依次把 4 行中的某一行拉低（1ms/行，4ms 走完一轮）。
//      某行被拉低且该行上的按键按下时，对应列线也被拉低 → 从列线即可读出按键。
//   2) 消抖: 机械触点抖动约 5~10ms。本模块为 16 个键**各自维护一个计数器**，
//      连续 (DEBOUNCE_MS/4) 次采样一致才认可状态变化（默认 20ms 阈值）。
//      ⚠️ 关键: 计数器只在"扫描到该键所在行"时才更新 —— 因为列线读数
//         仅对当前扫描行有效，其他行的值是无意义的。若每轮全局更新所有键，
//         未扫描行的键会被误判为"未按下"，计数器永远清零，消抖失效。
//         （这正是本项目早期踩过的真实 bug，见 docs/progress.md 问题记录）
//   3) 事件: 某键稳定态由 0→1（按下瞬间）时输出单拍 key_event + key_code。
//      按住不放不会重复发事件；同时按下多键时取键号最小者（低位优先）。
//   4) 键号: KEY(行 r, 列 c) = 4*r + c，即 KEY0 ~ KEY15。
// =============================================================================
`timescale 1ns / 1ps

module key_matrix_4x4 #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter DEBOUNCE_MS = 20
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire [3:0]  key_row,
    input  wire [3:0]  key_col,
    output reg         key_event,
    output reg  [3:0]  key_code,
    output reg  [15:0] key_state
);

    // ---- 扫描节拍参数 ----
    // SCAN_DIV: 由时钟频率换算出的 1ms 计数值（50MHz→50000, 25MHz→25000）
    localparam [15:0] SCAN_DIV = CLK_FREQ_HZ / 1000;
    // DB_MAX: 需要的"连续一致"次数。每轮扫描 4ms 中每个键被采样 1 次，
    //         故 20ms 消抖 = 20/4 = 5 次
    localparam [3:0]  DB_MAX   = (DEBOUNCE_MS + 3) / 4;   // 20ms → 5 轮

    // ---- 1ms 节拍发生器（自由运行计数器，计满即产生单拍 scan_tick）----
    reg [15:0] scan_cnt;
    wire       scan_tick = (scan_cnt == SCAN_DIV - 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            scan_cnt <= 16'd0;
        else if (scan_tick)
            scan_cnt <= 16'd0;
        else
            scan_cnt <= scan_cnt + 16'd1;
    end

    // ---- 行计数 0~3：每个 scan_tick 前进一行，循环扫描 ----
    reg [1:0] row_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            row_idx <= 2'd0;
        else if (scan_tick)
            row_idx <= row_idx + 2'd1;
    end

    // ---- 行驱动：组合译码，把当前行拉低（其余行保持高）----
    // 例: row_idx=0 → key_row = ~4'b0001 = 4'b1110（仅第 0 行为低）
    assign key_row = ~(4'b0001 << row_idx);

    // ---- 列输入两级同步（防亚稳态）----
    // 列线来自板上的机械触点与 10k 上拉，相对 FPGA 内部时钟是异步信号，
    // 直接采样可能产生亚稳态 → 用两级触发器打拍后再使用。
    // 复位值为 4'hF（全 1 = 未按下，与上拉电平一致）。
    reg [3:0] col_s0, col_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_s0 <= 4'hF;
            col_s1 <= 4'hF;
        end
        else begin
            col_s0 <= key_col;      // 第一级：同步
            col_s1 <= col_s0;       // 第二级：再打一拍，输出给后续逻辑
        end
    end

    wire [3:0] col_pressed = ~col_s1;      // 板级按下为低 → 取反后 1 = 按下

    // ---- 逐键消抖（本模块最核心的逻辑）----
    // col_stable: 16 位"已确认稳定状态"位图，bit k = 1 表示键 k 处于按下态
    // db_cnt    : 16 个键各自的 4 位计数器，键 k 占 db_cnt[k*4 +: 4]
    reg [15:0] col_stable;
    reg [63:0] db_cnt;

    integer k;   // for 循环变量（综合时循环会被完全展开为并行逻辑）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_stable <= 16'd0;
            db_cnt     <= 64'd0;
        end
        else if (scan_tick) begin              // 每 1ms 检查一次（此刻正在扫描某一行）
            for (k = 0; k < 16; k = k + 1) begin
                // 键号 k = 4*行 + 列 → k[3:2] 取行号，k[1:0] 取列号
                if (k[3:2] == row_idx) begin   // 只处理"当前正在扫描的这一行"的 4 个键
                    if (col_pressed[k[1:0]] == col_stable[k]) begin
                        db_cnt[k*4 +: 4] <= 4'd0;               // 采样值与稳定态一致 → 计数清零
                    end
                    else if (db_cnt[k*4 +: 4] >= DB_MAX) begin
                        col_stable[k] <= col_pressed[k[1:0]];   // 连续不一致达阈值 → 正式翻转稳定态
                    end
                    else begin
                        db_cnt[k*4 +: 4] <= db_cnt[k*4 +: 4] + 4'd1;  // 不一致但未达阈值 → 继续计数
                    end
                end
                // 非当前行的键：本轮不更新（其列线读数无意义）
            end
        end
    end

    // 键状态位图输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            key_state <= 16'd0;
        else
            key_state <= col_stable;
    end

    // 按下沿检测 + 优先级编码（低位键优先）
    reg [15:0] col_stable_d;
    wire [15:0] press_edge = col_stable & ~col_stable_d;

    // ---- 优先级编码：从 16 位按键位图中取出"键号最小"的那一个 ----
    // 循环从最高位 (15) 遍历到最低位 (0)，每次发现置位就覆盖结果变量，
    // 因此最终保留的是**最后一次写入** = 最低位的键号 ✓（低位优先）
    // 例：键 2 与键 10 同时按下 → 返回 2
    function [3:0] prio_code;
        input [15:0] v;
        integer j;
        begin
            prio_code = 4'd0;
            for (j = 15; j >= 0; j = j - 1)
                if (v[j])
                    prio_code = j[3:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_stable_d <= 16'd0;
            key_event    <= 1'b0;
            key_code     <= 4'd0;
        end
        else begin
            col_stable_d <= col_stable;
            key_event    <= 1'b0;
            if (press_edge != 16'd0) begin
                key_event <= 1'b1;
                key_code  <= prio_code(press_edge);
            end
        end
    end

endmodule
