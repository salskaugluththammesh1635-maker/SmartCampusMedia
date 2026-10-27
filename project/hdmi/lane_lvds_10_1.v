// =============================================================================
// lane_lvds_10_1.v —— 单条 TMDS 通道的 10:1 串化器（EG4 原语版）
// -----------------------------------------------------------------------------
// 【为什么不能直接让发射核驱引脚】
//   hdmi_1_4b_transmitter_core 输出的是 10 bit 并行 TMDS 字（每像素时钟一个）。
//   真正送到 HDMI 座上必须是 10 倍速的串行差分对。EG4 器件里能做这个的只有
//   专用 ODDR 原语（EG_LOGIC_ODDR），所以必须有这一层。
//
// 【怎么做到 10:1】
//   I_serial_clk = 5 × I_pixel_clk。ODDR 在时钟的上下沿各出一位，所以一个
//   serial 时钟周期出 2 位 → 5 个 serial 周期出 10 位 = 正好一个像素。
//   于是：每个 pixel 时钟翻转一次 odd/even 标志；serial 域把这个标志打两拍
//   检测跳变，得到"该装载新字了"的使能，装载后每拍左移 2 位。
//
// 【为什么数据要位反序】
//   发射核给的 10 bit 是 LSB-first 语义（bit0 先出），而移位寄存器是 MSB 先出。
//   参考实现因此在 PHY 输入端整体倒序。这个反序放在 hdmi_phy.v 里做，
//   本模块只负责"按给定顺序串化"，职责单一，将来换核对齐方式也只需改一处。
//
// 【复位为什么只在 serial 域做两级同步】
//   I_rst 来自 pixel 时钟域，而本模块主体跑在 serial 时钟域（5 倍频），
//   直接当异步复位用会有恢复/移除时间风险。这里改成"pixel 域同步 + serial 域
//   同步后当同步复位"，这样时序分析能看到真实的跨域路径。
// =============================================================================
`timescale 1ns / 1ps

module lane_lvds_10_1 (
    input  wire       I_pixel_clk,
    input  wire       I_serial_clk,
    input  wire       I_rst,        // 高有效（与参考实现一致，由 hdmi_phy 统一取反）
    input  wire [9:0] I_data_in,
    output wire       O_serial_out
);

    // ---- pixel 域：奇偶标志，每像素翻转一次 --------------------------------
    reg odd_even;
    always @(posedge I_pixel_clk) begin
        if (I_rst) odd_even <= 1'b0;
        else       odd_even <= ~odd_even;
    end

    // ---- serial 域：同步复位 + 标志打两拍找跳变 ----------------------------
    // 不复位问题：serial 域的移位寄存器不接异步复位（参考实现也不接），
    // 只让同步后的复位信号把装载使能压住，避免复位期间输出毛刺。
    reg [1:0] rst_sync_s;
    always @(posedge I_serial_clk) begin
        rst_sync_s <= {rst_sync_s[0], I_rst};
    end

    reg [1:0] odd_even_s;
    always @(posedge I_serial_clk) begin
        odd_even_s <= {odd_even_s[0], odd_even};
    end

    // 两拍之间跳变 → 一个 serial 周期的装载窗口。
    wire load_en = odd_even_s[0] ^ odd_even_s[1];

    reg [1:0] load_en_s;
    always @(posedge I_serial_clk) begin
        load_en_s <= {load_en_s[0], load_en};
    end

    // ---- 10 bit 移位寄存器：装载或每拍左移 2 位 ----------------------------
    reg [9:0] shift_data;
    always @(posedge I_serial_clk) begin
        if (rst_sync_s[1])       shift_data <= 10'd0;
        else if (load_en_s[1])   shift_data <= I_data_in;
        else                     shift_data <= {shift_data[7:0], 2'b00};
    end

    reg [1:0] oddr_data;
    always @(posedge I_serial_clk) begin
        if (rst_sync_s[1]) oddr_data <= 2'b00;
        else               oddr_data <= shift_data[9:8];
    end

    // ODDR：d1 在时钟下降沿出、d0 在上升沿出（EG4 原语语义），合起来就是
    // 每个 serial 周期两位，正好把 10 bit 摊到 5 个周期里。
    EG_LOGIC_ODDR u_oddr (
        .clk (I_serial_clk),
        .rst (rst_sync_s[1]),
        .d1  (oddr_data[0]),
        .d0  (oddr_data[1]),
        .q   (O_serial_out)
    );

endmodule
