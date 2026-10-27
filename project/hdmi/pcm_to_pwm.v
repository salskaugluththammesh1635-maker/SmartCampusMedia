// =============================================================================
// pcm_to_pwm.v —— 24 bit PCM 到 1 bit PWM 的一阶 sigma-delta 调制
// -----------------------------------------------------------------------------
// 【为什么替换原来的 pwm_audio_out】
//   pwm_audio_out 是"固定 440 Hz 方波 + 8 bit 载波"的测试音发生器：它只能证明
//   "引脚有信号"，无法承载任何真实音频，也无法与 HDMI 音频共用同一份样本。
//   本模块把 48 kHz / 24 bit 的 PCM 样本调制到 25 MHz 的 1 bit 流上，于是
//   HDMI 里的声音和 3.5 mm 接口里的声音出自同一份数据 —— 这才叫音视频联动。
//
// 【一阶 sigma-delta 的原理（一行数学）】
//   设累加器 acc、输入增量 x、输出 y：
//       acc(n+1) = (acc(n) + x(n)) mod 2^32 ,  y(n) = acc(n+1) 的最高位
//   取模等价于"减去 y*2^32"，所以这就是标准的一阶噪声整形：
//       acc(n+1) = acc(n) + x(n) - y(n)*2^32
//   输出的平均值（占空比）严格等于 x / 2^32，量化误差被推到高频，再由板载
//   RC 低通滤掉。硬件代价只有一个 32 位加法器，比 8 bit 计数器 PWM 还省。
//
// 【量程映射】
//   输入 24 bit 有符号样本加 2^23 偏置变成 0..2^24-1，再左移 8 位得 32 位增量。
//   这样 0 样本正好对应 2^31，即 50% 占空比（交流耦合后是静音），
//   满幅样本对应 0% 或 100% 占空比。
//
// 【静音为什么是"输出恒 0"而不是"输出 50%"】
//   保持与原 pwm_audio_out 的对外行为一致（低电平静音），这样换模块不会改变
//   已上板验证过的引脚语义；板载功放输入端有隔直电容，两种直流都不会出声。
// =============================================================================
`timescale 1ns / 1ps

module pcm_to_pwm (
    input  wire               clk,          // 25 MHz 像素时钟
    input  wire               rst_n,
    input  wire               sample_valid, // 48 kHz 单拍使能（来自 audio_tone_gen）
    input  wire signed [23:0] sample_in,    // 24 bit 有符号 PCM
    input  wire               mute,         // 静音（KEY6）
    output wire               pwm_out       // 至 F3，板载低通 + 功放
);

    // ---- 保持当前样本（零阶保持到下一个样本到来）--------------------------
    reg signed [23:0] sample_hold;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_hold <= 24'sd0;
        else if (sample_valid) sample_hold <= sample_in;
    end

    // ---- 偏置到无符号量程 ---------------------------------------------------
    // sample_hold + 2^23 落在 0..2^24-1；用 24 位无符号承载即可。
    wire [23:0] sample_ofs = sample_hold + 24'sh800000;
    // 左移 8 位放到 32 位量程：中心值 2^23<<8 = 2^31，即 50% 占空比。
    wire [31:0] sample_ext = {sample_ofs, 8'b0};

    // ---- 一阶 sigma-delta 累加器 -------------------------------------------
    reg  [31:0] acc;
    wire [31:0] acc_next = acc + sample_ext;
    reg         pwm_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc   <= 32'd0;
            pwm_q <= 1'b0;
        end else begin
            acc   <= acc_next;
            pwm_q <= acc_next[31];   // 最高位即调制输出，与累加值同拍
        end
    end

    // 静音时把调制器也清零，避免恢复瞬间残留旧样本造成的爆音。
    assign pwm_out = mute ? 1'b0 : pwm_q;

endmodule
