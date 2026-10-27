// =============================================================================
// audio_waveform.v — 音频波形图层（KEY13 第三档）
// -----------------------------------------------------------------------------
// 【在系统中的位置】
//   video_overlay 内部子模块。把 audio_tone_gen 的 24 bit PCM 样本存成
//   64 点滚动历史，并在 x ∈ [64,575]、y 以 200 为中心的区域内画一条
//   "示波器式"的连续波形。
//
// 【为什么单独成模块】
//   电平条是纯组合的（只要看当前样本幅度），波形必须有历史状态。
//   把 64×16 bit 的移位历史收在本模块里，video_overlay 仍然保持
//   "输入坐标 → 输出像素"的组合语义，便于测试台逐像素断言。
//
// 【显示映射】
//   - x 方向: 每 8 像素对应一个历史样本，共 64 样本 = 512 像素；
//     左边是较旧样本，右边是最新样本（hist[0] 为最新）。
//   - y 方向: y = 200 + (sample[23:8] >>> 9)，幅度约 ±64 像素。
//   - 连续线: 同时读当前样本与相邻旧样本，把两者 y 之间的像素全部点亮，
//     避免出现一条断点很多的"点阵"。
//
// 【资源量级】
//   64×16 bit 历史 = 1024 个寄存器；变量索引读会综合成分布式 RAM/多路选择。
//   在 EG4S20 当前余量下（REG 16k 空闲、LUT 12k 空闲）可以忽略。
//
// 【时钟/复位】
//   - 只在 audio_valid 单拍时移位，48 kHz 下每秒 48000 次；
//   - 像素输出是组合的，不引入额外一拍延迟；
//   - 复位清空历史，上电不会出现随机波形。
// =============================================================================
`timescale 1ns / 1ps

module audio_waveform #(
    parameter [10:0] X0       = 11'd64,    // 波形窗口左边界（含）
    parameter [10:0] X1       = 11'd576,   // 波形窗口右边界（不含）
    parameter [9:0]  Y_CENTER = 10'd200,   // 波形中心线
    parameter integer Y_SHIFT = 9,         // 幅度缩放: 样本 >>> Y_SHIFT
    parameter integer HISTORY = 64         // 历史样本数（本实现固定 64）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        audio_valid,              // 48 kHz 单拍
    input  wire signed [23:0] audio_sample,      // 与 HDMI/3.5mm 同一份 PCM
    input  wire        de,
    input  wire [10:0] active_x,
    input  wire [9:0]  active_y,
    input  wire        wave_en,
    output wire        wave_pixel,
    output wire [23:0] wave_rgb
);

    // HISTORY=64 → 索引 6 bit。改 HISTORY 时必须同步改这里。
    localparam integer IDX_W = 6;
    // 有符号中心线常量，避免 unsigned + signed 的宽度/符号歧义
    localparam signed [15:0] Y_CENTER_S = Y_CENTER;

    // 16 bit 有符号历史；取 24 bit 样本的高 16 位保留符号。
    reg signed [15:0] hist [0:HISTORY-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < HISTORY; i = i + 1)
                hist[i] <= 16'sd0;
        end
        else if (audio_valid) begin
            for (i = HISTORY-1; i > 0; i = i - 1)
                hist[i] <= hist[i-1];
            // 只保留高 16 位：低 8 位对 64 像素高的波形没有可见贡献，
            // 省一半寄存器；TD 会对 audio_sample[7:0] 报 SYN-5014 未连接警告，属预期。
            hist[0] <= audio_sample[23:8];
        end
    end

    // ---- 当前像素落在波形窗口内？----
    wire in_window = (active_x >= X0) && (active_x < X1);
    wire [10:0] rel_x = active_x - X0;

    // 每 8 像素一个样本；x 越大索引越小（右边最新，左边最旧）。
    wire [IDX_W-1:0] idx = (HISTORY-1) - rel_x[9:3];

    // 相邻旧样本用于连线；最左端没有更旧样本时退化为自身。
    wire [IDX_W-1:0] idx_prev = (idx == (HISTORY-1)) ? idx : (idx + 1'b1);

    wire signed [15:0] s_curr = hist[idx];
    wire signed [15:0] s_prev = hist[idx_prev];

    // 以 Y_CENTER 为中心的纵向位置（Y_CENTER_S 为有符号常量，避免无符号加法）
    wire signed [15:0] y_curr_s = Y_CENTER_S + (s_curr >>> Y_SHIFT);
    wire signed [15:0] y_prev_s = Y_CENTER_S + (s_prev >>> Y_SHIFT);
    wire [9:0] y_curr = y_curr_s[9:0];
    wire [9:0] y_prev = y_prev_s[9:0];

    // 连接相邻样本：把 min..max 之间的像素全部点亮
    wire [9:0] y_min = (y_curr < y_prev) ? y_curr : y_prev;
    wire [9:0] y_max = (y_curr < y_prev) ? y_prev : y_curr;

    assign wave_pixel = wave_en && de && in_window &&
                        (active_y >= y_min) && (active_y <= y_max);

    // 与九宫格/电平条/信息条区分开的黄色
    assign wave_rgb = 24'hFF_FF_40;

endmodule
