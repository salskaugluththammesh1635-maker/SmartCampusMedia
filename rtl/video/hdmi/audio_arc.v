// =============================================================================
// audio_arc.v —— 生成 HDMI 音频时钟再生包（ACR）的 CTS / N 参数对
// -----------------------------------------------------------------------------
// 【这个包是干什么的】
//   HDMI 的音频不是"跟着像素时钟走"的，它有自己的 48 kHz 基准。接收端（显示器/
//   功放）没有 48 kHz 晶振可用，所以发送端必须周期性告诉它"多少个像素时钟对应
//   多少个音频采样"，它才能用 TMDS 时钟把 48 kHz 还原出来。这对参数就是 CTS/N：
//       f_audio = f_pixel * N / (128 * CTS)
//   代入本工程（f_pixel=25 MHz、N=6144、CTS 由计数器产生），接收端算出的
//   音频频率刚好是 25e6*6144/(128*CTS) Hz。CTS 每个 ACR 包+1，随像素时钟自然
//   增长，正是"用像素时钟测量音频时钟"的实现。
//
// 【N 为什么取 6144】
//   HDMI 规范对 48 kHz 家族规定 N = 6144（32 kHz 是 4096、44.1 kHz 家族是 6272）。
//   这不是随便选的常数，改采样率就必须同时改这里和发射核的 AUDIO_SAMPLE_RATE。
//
// 【AUDIO_DIV 的作用】
//   ACR 包不需要每个样本都发。参考实现取 ACR_N>>7 = 48 个样本发一次，
//   即 48000/48 = 1000 次/秒。这样既满足接收端跟踪精度，又不占满数据岛带宽。
// =============================================================================
`timescale 1ns / 1ps

module audio_arc #(
    parameter ACR_N = 6144
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        audio_valid,    // 来自 audio_tone_gen 的 48 kHz 单拍使能
    output reg         acr_valid,
    output reg  [19:0] acr_cts,
    output reg  [19:0] acr_n
);

    localparam [7:0] AUDIO_DIV = ACR_N >> 7;   // 6144>>7 = 48

    reg [7:0]  div_cnt;
    reg [19:0] cts_cnt;

    // 每 AUDIO_DIV 个音频样本产生一次 ACR 更新节拍。
    wire div_tick = audio_valid && (div_cnt == (AUDIO_DIV - 1'b1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 8'd0;
            cts_cnt <= 20'd0;
        end else if (audio_valid) begin
            div_cnt <= div_tick ? 8'd0 : (div_cnt + 1'b1);
            // 每次发 ACR 包时 CTS 清零，包之间连续自增 —— 这样接收端看到的
            // CTS 序列就是"自上一个包以来经过了多少个像素时钟"。
            cts_cnt <= div_tick ? 20'd0 : (cts_cnt + 1'b1);
        end else begin
            cts_cnt <= cts_cnt + 1'b1;
        end
    end

    // 输出寄存：acr_valid 高的一拍，核从 acr_cts / acr_n 取值。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acr_valid <= 1'b0;
            acr_cts   <= 20'd0;
            acr_n     <= ACR_N[19:0];
        end else if (div_tick) begin
            acr_valid <= 1'b1;
            acr_cts   <= cts_cnt + 1'b1;
            acr_n     <= ACR_N[19:0];
        end else begin
            acr_valid <= 1'b0;
        end
    end

endmodule
