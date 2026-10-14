// =============================================================================
// key_matrix_4x4.v
// 功能: 4x4 矩阵键盘扫描 + 逐键消抖 + 按键事件输出（DMZ-EG4S20 板级适配）
// 板级事实（来源: 走近FPGA 表1.1 + 核心板原理图p4 KEY 区, 已核实）:
//   行 Key_Row[3:0] = E10,C10,F9,D9  （FPGA 输出, 低电平选通行）
//   列 Key_Col[3:0] = E11,D11,C11,F10（FPGA 输入, 行网络 10k 上拉, 按下为低）
//   键号: KEY(行 r, 列 c) = 4*r + c, 即 KEY0~KEY15
// 扫描: 1ms/行（4ms 完整一轮）, 逐键独立消抖计数器
// 消抖: 每个键每轮被采样一次, 连续 (DEBOUNCE_MS/4) 次一致才确认
// 事件: 稳定态 0→1 时输出单拍 key_event + key_code（低位优先编码）
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

    // 1ms 行扫描节拍
    localparam [15:0] SCAN_DIV = CLK_FREQ_HZ / 1000;
    localparam [3:0]  DB_MAX   = (DEBOUNCE_MS + 3) / 4;   // 20ms → 5 轮

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

    // 行计数 0~3
    reg [1:0] row_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            row_idx <= 2'd0;
        else if (scan_tick)
            row_idx <= row_idx + 2'd1;
    end

    // 行驱动: 组合译码, 当前行拉低
    assign key_row = ~(4'b0001 << row_idx);

    // 列两级同步（防亚稳态）
    reg [3:0] col_s0, col_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_s0 <= 4'hF;
            col_s1 <= 4'hF;
        end
        else begin
            col_s0 <= key_col;
            col_s1 <= col_s0;
        end
    end

    wire [3:0] col_pressed = ~col_s1;      // 1 = 按下

    // 逐键消抖: 仅在采样当前行的 4 个键时更新它们的计数器
    reg [15:0] col_stable;
    reg [63:0] db_cnt;                     // 16 键 × 4bit 计数器

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_stable <= 16'd0;
            db_cnt     <= 64'd0;
        end
        else if (scan_tick) begin
            for (k = 0; k < 16; k = k + 1) begin
                if (k[3:2] == row_idx) begin           // 仅当前行的 4 个键
                    if (col_pressed[k[1:0]] == col_stable[k]) begin
                        db_cnt[k*4 +: 4] <= 4'd0;      // 与稳定态一致 → 清零
                    end
                    else if (db_cnt[k*4 +: 4] >= DB_MAX) begin
                        col_stable[k] <= col_pressed[k[1:0]];   // 持续不一致达阈值 → 翻转
                    end
                    else begin
                        db_cnt[k*4 +: 4] <= db_cnt[k*4 +: 4] + 4'd1;
                    end
                end
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
