// =============================================================================
// buzzer_tone.v
// 功能: 无源蜂鸣器驱动 + 提示音发生器（DMZ-EG4S20 板级适配）
// 板级事实（来源: 走近FPGA 表1.5 + 核心板原理图p4 BUZ 区, 已核实）:
//   无源蜂鸣器, PNP(MMBT3906) 驱动: FPGA 输出【低电平】→ 三极管导通 → 发声
//   Buzzer_Out = H11; 音调由输出方波频率决定
// 音调:
//   tone_sel=0 静音
//   tone_sel=1 按键提示音（trig 触发后响 100ms, C5≈523Hz）
//   tone_sel=2 应急提示音（E6≈1319Hz, 250ms 响/250ms 停自动循环）
// 【实现要点】
//   1) 单一 always 块驱动全部内部寄存器 —— 早期版本曾把 beep_cnt 分散在
//      两个 always 块里写，导致多驱动（仿真出现 X 态），这是本项目踩过的坑，
//      务必保持"一个模块一套状态、一个块管完"的结构。
//   2) 方波由"半周期计数翻转"产生：计满 half_period 就翻转 sq，
//      因此输出频率 = CLK_FREQ_HZ / (2 × half_period)。
//      参数化后换时钟频率无需改逻辑（50MHz / 25MHz 均可）。
//   3) 输出再经一级寄存器取反送出 —— 板上是 PNP 三极管驱动，
//      FPGA 输出低电平时导通发声，故 buzzer_out 为低有效。
// =============================================================================
`timescale 1ns / 1ps

module buzzer_tone #(
    parameter CLK_FREQ_HZ = 50_000_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] tone_sel,       // 0=静音 1=按键音 2=应急音
    input  wire       trig,           // 单拍触发（按键音窗口开启）
    output reg        buzzer_out      // 蜂鸣器驱动, 低=响
);
    // 半周期计数（向下计数到 0 翻转方波）
    localparam [31:0] HALF_C5  = CLK_FREQ_HZ / (2 * 523);
    localparam [31:0] HALF_E6  = CLK_FREQ_HZ / (2 * 1319);
    localparam [31:0] BEEP_TICKS  = CLK_FREQ_HZ / 10;    // 100ms 按键音窗口
    localparam [31:0] EMERG_HALF  = CLK_FREQ_HZ / 4;     // 250ms 应急音半周期

    reg [31:0] beep_cnt;      // 按键音剩余窗口计数
    reg [31:0] emerg_cnt;     // 应急音相位计数
    reg [31:0] half_cnt;      // 方波半周期计数
    reg        sq;            // 内部方波（高=发声）
    reg        beep_run;      // 按键音进行中
    reg        emerg_on;      // 应急音响段

    wire [31:0] half_period = (tone_sel == 2'd2) ? HALF_E6 : HALF_C5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beep_cnt  <= 32'd0;
            emerg_cnt <= 32'd0;
            half_cnt  <= 32'd0;
            sq        <= 1'b0;
            beep_run  <= 1'b0;
            emerg_on  <= 1'b0;
        end
        else begin
            // ---- 按键音窗口（trig 触发, 持续 100ms）----
            if (trig) begin
                beep_run <= 1'b1;
                beep_cnt <= 32'd0;
            end
            else if (beep_run) begin
                if (beep_cnt >= BEEP_TICKS - 1)
                    beep_run <= 1'b0;
                else
                    beep_cnt <= beep_cnt + 32'd1;
            end

            // ---- 应急音相位（250ms 响 / 250ms 停, 自动循环）----
            if (tone_sel == 2'd2) begin
                if (emerg_cnt >= (EMERG_HALF * 2) - 1)
                    emerg_cnt <= 32'd0;
                else
                    emerg_cnt <= emerg_cnt + 32'd1;
                emerg_on <= (emerg_cnt < EMERG_HALF);
            end
            else begin
                emerg_cnt <= 32'd0;
                emerg_on  <= 1'b0;
            end

            // ---- 方波发生（仅发声窗口内切换）----
            if ((tone_sel == 2'd1 && beep_run) ||
                (tone_sel == 2'd2 && emerg_on)) begin
                if (half_cnt >= half_period - 1) begin
                    half_cnt <= 32'd0;
                    sq       <= ~sq;
                end
                else begin
                    half_cnt <= half_cnt + 32'd1;
                end
            end
            else begin
                half_cnt <= 32'd0;
                sq       <= 1'b0;      // 静音
            end
        end
    end

    // 低电平有效输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            buzzer_out <= 1'b1;
        else
            buzzer_out <= ~sq;
    end

endmodule
