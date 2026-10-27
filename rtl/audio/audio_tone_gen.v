// =============================================================================
// audio_tone_gen.v —— HDMI 音频嵌入的音频源（48 kHz / 24 bit PCM）
// -----------------------------------------------------------------------------
// 【为什么需要这个模块】
//   原工程的音频只有 pwm_audio_out（固定 440 Hz 测试音走 PWM 引脚），与 HDMI
//   无关。赛题基础验收第 5 条要求"音频与播放状态联动"，而 HDMI 音频嵌入要求
//   发射核按采样率节拍收到 PCM 样本。本模块同时解决这两件事：
//     1) 按 48 kHz 节拍产生 I_audio_valid + 24 bit 左右声道样本，直接喂给
//        HDMI 1.4b 发射核的 Audio Interface；
//     2) 音高/静音由 playback_state 决定 —— 换图、装载、轮播、应急各有不同的
//        声音，听感本身就反映机器在干什么（这不只是"有个声音"，而是可听状态）。
//
// 【采样率怎么来的】
//   25 MHz 不是 48 kHz 的整数倍，所以用分数分频累加器：
//     每个时钟 acc += 48000，一旦 acc >= 25000000 就抵消并产生一拍 sample_en。
//   平均频率精确等于 48000 Hz，且不需要除法器/ROM。累加器最大 24 999 999，
//   加 48000 仍在 32 位内，不会溢出。
//
// 【波形为什么用三角波而不是方波】
//   参考例程用的是方波，方波谐波多、经板载功放后很刺耳。三角波只含奇次谐波且
//   幅度随次数平方衰减，听感明显柔和，而实现代价只是相位累加器的高位取反。
//   幅度固定缩到约 ±2.1e6（与参考 AMP=2000000 同量级），留足余量避免削顶。
//
// 【静音时仍然发 valid】
//   HDMI 发射核要求音频输入速率等于采样率（APUG092 文档原话："音频输入数据的
//   速率需要等于音频采样率"）。如果静音就停发 valid，核会认为音频流中断。
//   所以静音的实现是"照常发 valid、样本填 0"，而不是停发。
// =============================================================================
`timescale 1ns / 1ps

module audio_tone_gen #(
    parameter CLK_FREQ_HZ       = 25_000_000,   // 像素时钟频率（与 clk_pixel 一致）
    parameter SAMPLE_RATE_HZ    = 48_000,       // 音频采样率（须与核参数一致）
    parameter NOTE_HOLD_SAMPLES = 24_000        // 每个音符保持的样本数（0.5 s @48k）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  playback_state,   // 播放状态，决定音高/静音（音视频联动）
    input  wire        mute,             // 按键静音（KEY6）
    output reg         audio_valid,      // 单拍脉冲 @ SAMPLE_RATE_HZ
    output reg  [23:0] audio_left,       // 左声道样本（有符号补码）
    output reg  [23:0] audio_right       // 右声道样本（与左声道同值）
);

    // ---- 播放状态编码（与顶层一致，改这里必须同步改顶层注释）----------------
    localparam [2:0] ST_IDLE  = 3'd0;   // 未就绪（无卡/未上电完成）：静音
    localparam [2:0] ST_SCAN  = 3'd1;   // 扫描图库：低音 C4 长鸣
    localparam [2:0] ST_LOAD  = 3'd2;   // 装载图片：E4
    localparam [2:0] ST_READY = 3'd3;   // 图片就绪显示：G4
    localparam [2:0] ST_AUTO  = 3'd4;   // 自动轮播：五音循环
    localparam [2:0] ST_EMERG = 3'd5;   // 应急模式：C5/G4 交替告警
    localparam [2:0] ST_FAIL  = 3'd6;   // 资源故障：静音（不制造噪音干扰排查）

    // ---- 音名频率控制字 -----------------------------------------------------
    // note_inc 是"每样本的 32 位相位增量"：inc = f_note / f_sample * 2^32。
    // 例如 A4 = 440 Hz：440 / 48000 * 2^32 = 39370534。
    // 注意累加发生在 48 kHz 节拍上（不是 25 MHz），所以这些常数才是标准音高。
    function [31:0] note_inc;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: note_inc = 32'd23409862;  // C4  261.63 Hz
                3'd1: note_inc = 32'd26276681;  // D4  293.66 Hz
                3'd2: note_inc = 32'd29494578;  // E4  329.63 Hz
                3'd3: note_inc = 32'd31248410;  // F4  349.23 Hz
                3'd4: note_inc = 32'd35075155;  // G4  392.00 Hz
                3'd5: note_inc = 32'd39370534;  // A4  440.00 Hz
                3'd6: note_inc = 32'd44191930;  // B4  493.88 Hz
                default: note_inc = 32'd46819716;  // C5  523.25 Hz
            endcase
        end
    endfunction

    // ---- 48 kHz 采样使能（分数分频）----------------------------------------
    reg  [31:0] sample_acc;
    wire [31:0] sample_acc_add = sample_acc + SAMPLE_RATE_HZ;
    reg         sample_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_acc <= 32'd0;
            sample_en  <= 1'b0;
        end else if (sample_acc_add >= CLK_FREQ_HZ) begin
            sample_acc <= sample_acc_add - CLK_FREQ_HZ;
            sample_en  <= 1'b1;
        end else begin
            sample_acc <= sample_acc_add;
            sample_en  <= 1'b0;
        end
    end

    // ---- 音符保持计数（按样本计）--------------------------------------------
    reg [15:0] hold_cnt;
    wire       note_tick = sample_en && (hold_cnt == NOTE_HOLD_SAMPLES - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hold_cnt <= 16'd0;
        else if (sample_en) hold_cnt <= note_tick ? 16'd0 : (hold_cnt + 1'b1);
    end

    // ---- 轮播旋律索引（只有 ST_AUTO 用）------------------------------------
    reg [2:0] melody_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) melody_idx <= 3'd0;
        else if (note_tick) begin
            if (melody_idx == 3'd4) melody_idx <= 3'd0;
            else melody_idx <= melody_idx + 1'b1;
        end
    end

    // ---- 当前音符选择 -------------------------------------------------------
    // 组合块内全部用阻塞赋值，与其它时序块不共享变量（满足 lint 的 E1/E2 规则）。
    reg [2:0] note_idx;
    always @(*) begin
        case (playback_state)
            ST_SCAN:  note_idx = 3'd0;                                  // C4
            ST_LOAD:  note_idx = 3'd2;                                  // E4
            ST_READY: note_idx = 3'd4;                                  // G4
            ST_AUTO:  note_idx = melody_idx;                            // 五音循环
            ST_EMERG: note_idx = hold_cnt[13] ? 3'd7 : 3'd4;            // C5/G4 交替
            default:  note_idx = 3'd0;                                  // IDLE/FAIL
        endcase
    end

    // ---- 相位累加 + 三角波取形 ---------------------------------------------
    reg  [31:0] phase_acc;
    wire [31:0] phase_inc = note_inc(note_idx);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase_acc <= 32'd0;
        else if (sample_en) phase_acc <= phase_acc + phase_inc;
    end

    // 相位最高位决定三角波方向：上升半周取原值、下降半周取反，得到对称三角波。
    wire [23:0] tri_raw  = phase_acc[31] ? ~phase_acc[30:7] : phase_acc[30:7];
    // 中心化到 0（-8388608..+8388607），再右移 2 位把幅度压到约 ±2.1e6。
    wire signed [23:0] tri_centered = $signed(tri_raw) - 24'sd8388608;
    wire signed [23:0] sample_out   = tri_centered >>> 2;

    // ---- 静音判定 -----------------------------------------------------------
    // 未就绪与故障状态下静音：这两种状态本来就该"没声音"，出音反而误导现场。
    wire silent = mute || (playback_state == ST_IDLE) || (playback_state == ST_FAIL);

    // ---- 输出寄存 -----------------------------------------------------------
    // valid 与数据在同一个时钟沿更新，保证核看到的样本与有效标志严格同拍。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audio_valid <= 1'b0;
            audio_left  <= 24'sd0;
            audio_right <= 24'sd0;
        end else begin
            audio_valid <= sample_en;
            if (sample_en) begin
                audio_left  <= silent ? 24'sd0 : sample_out;
                audio_right <= silent ? 24'sd0 : sample_out;
            end
        end
    end

endmodule
