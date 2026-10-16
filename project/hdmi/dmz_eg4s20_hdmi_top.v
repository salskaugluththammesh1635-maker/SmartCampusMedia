// =============================================================================
// dmz_eg4s20_hdmi_top.v — 阶段三：HDMI 视频输出系统顶层
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 顶层（Top Level）—— 整个 HDMI 工程的"总装配图"
//   工程归属 : project/hdmi_td.al（HDMI 工程，器件 EG4S20BG256）
//   数据流位置:
//       50MHz 晶振(球 R7)
//            ↓
//       hdmi_pll ──────→ 25MHz 像素时钟 + 125MHz 串化时钟（严格 5 倍）
//            ↓
//       video_timing_gen ──→ 行同步 hs / 场同步 vs / 数据有效 de / 有效区坐标
//            ↓
//       test_pattern_gen ──→ RGB888 像素流（8 种测试图案）
//            ↓
//       hdmi_tx(VHDL 桥接层) ──→ DVITransmitter(加密核) ──→ TMDS 差分 ──→ 显示器
//   并行支路:
//       key_matrix_4x4 ──→ 图案切换（KEY4/KEY5）+ 蜂鸣器提示音触发
//       seg_decoder + seg_scan4 ──→ 数码管显示当前图案号
//       LED ──→ 高 4 位显示图案号 / bit4 显示 PLL 锁定状态
//   为什么需要它:
//     把 7 个子模块装配成可综合的完整系统，并集中处理"全局性事务"
//     （时钟生成、复位策略、时钟域划分），使各子模块保持纯粹、可复用。
//     若没有顶层，每个子模块都要自己关心 PLL、复位、管脚分配，无法复用。
//
// 【二、本模块功能】
//   一句话职责: 实现 640×480@60Hz 测试图案 → HDMI TMDS 输出的完整链路，
//               并支持按键切换 8 种测试图案 + PWM 音频测试音输出。
//   关键特性:
//     - 全系统单一时钟域（25MHz 像素时钟）：从根上规避跨时钟域（CDC）问题，
//       键盘/数码管/LED/蜂鸣器/视频全部同域，无需任何同步器
//     - PLL 锁定后才释放系统复位；复位同步器采用"异步置位、同步释放"，
//       消除复位撤除时刻的亚稳态风险
//     - PLL 锁定状态引到 LED[4]：现场调试时无需示波器即可判断时钟是否正常
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  clk           : 50MHz 系统时钟（球 R7）
//     输入  rst_n_btn     : 复位按键（球 E3，低有效）
//     输出  key_row[3:0]  : 矩阵键盘行扫描输出（E10/C10/F9/D9，低电平选通）
//     输入  key_col[3:0]  : 矩阵键盘列输入（E11/D11/C11/F10，板上 10k 上拉）
//     输出  led[7:0]      : LED 指示（B14/B15/B16/C15/C16/E13/E16/F16，高电平点亮）
//     输出  seg_data[7:0] : 数码管段选（A4/A6/B8/E8/A7/B5/A8/C8，低电平点亮）
//     输出  seg_cs[3:0]   : 数码管位选（C9/B6/A5/A3，低电平选通）
//     输出  buzzer        : 蜂鸣器（球 H11，低电平响）
//     输出  audio_pwm     : PWM 音频（球 F3，板载低通+功放，基础要求③）
//     输出  HDMI_*_P ×4   : TMDS 差分正端（P1/N1/P4/J3，IOSTANDARD=LVDS33）
//
//   内部逻辑块（共 10 块，按信号流顺序）:
//     [1] PLL 复位延时发生器      always @(posedge clk or negedge rst_n_btn)
//           功能: 上电后延时约 2.5us 释放 PLL 复位，等 50MHz 参考时钟稳定
//           输入: clk, rst_n_btn              输出: pll_reset
//     [2] hdmi_pll               子模块例化
//           功能: 由 50MHz 生成 25MHz 像素时钟与 125MHz 串化时钟（严格 5 倍）
//           输入: clk, pll_reset              输出: clk_pixel, clk_5x, locked
//     [3] 复位同步器              always @(posedge clk_pixel or negedge rst_n_pll)
//           功能: 三级移位链实现"异步置位、同步释放"
//           输入: clk_pixel, rst_n_pll         输出: rst_n（全系统复位）
//     [4] key_matrix_4x4         子模块例化
//           功能: 4×4 键盘扫描 + 20ms 逐键消抖 + 按下事件输出
//           输入: clk_pixel, rst_n, key_col    输出: key_event, key_code, key_state
//     [5] 图案选择器              always @(posedge clk_pixel or negedge rst_n)
//           功能: KEY4 减一 / KEY5 加一，循环切换 8 种图案（3 位自动回绕）
//           输入: key_event, key_code          输出: pattern_sel[2:0]
//     [6] video_timing_gen       子模块例化
//           功能: 640×480@60Hz 时序发生（hs/vs/de/有效区坐标）
//           输入: clk_pixel, rst_n             输出: hs, vs, de, active_x/y, frame_start
//     [7] test_pattern_gen       子模块例化
//           功能: 依 pattern_sel 生成 8 种测试图案的 RGB888 像素
//           输入: clk_pixel, de, active_x/y, pattern_sel   输出: pr/pg/pb[7:0]
//     [8] hdmi_tx                子模块例化（VHDL 桥接，内部调用 DVITransmitter 加密核）
//           功能: RGB888 → 8b/10b 编码 → 并串转换 → TMDS 差分输出
//           输入: clk_pixel, clk_5x, rst_n, hs/vs/de, {pr,pg,pb}
//           输出: HDMI_CLK_P, HDMI_D0_P, HDMI_D1_P, HDMI_D2_P
//     [9] 状态显示与提示音       子模块例化 + assign
//           功能: 数码管显示图案号（其余三位熄灭）/ LED 显示图案号与锁定状态 /
//                 按键时蜂鸣器短鸣 100ms
//           输入: pattern_sel, key_event, locked
//           输出: seg_data, seg_cs, led, buzzer
//     [10] pwm_audio_out         子模块例化
//           功能: DDS 三角波测试音 → 8bit PWM → 板载音频通路（基础要求③）
//           输入: clk_pixel, rst_n            输出: audio_pwm
//
// 【四、设计思路与范式】
//   主要范式 : 结构化装配（Structural）—— 顶层只做例化与连线，不含算法逻辑
//   次要范式 :
//     - 打拍/移位 : [1] PLL 复位延时计数器、[3] 复位同步器（异步置位、同步释放）
//     - 组合译码  : [9b] LED 位拼接（纯 assign 组合逻辑）
//   为什么这样写:
//     把所有"全局性事务"（时钟生成、复位策略、时钟域划分）集中到顶层处理，
//     子模块因此可以保持纯粹 —— 它们不关心 PLL、不关心复位从哪来，只专注
//     自己的功能。这样才能做到"独立仿真、跨工程复用"：本项目
//     seg_decoder / seg_scan4 / key_matrix_4x4 / buzzer_tone 四个模块
//     就被最小系统（bringup_td）与 HDMI（hdmi_td）两个工程同时使用。
//   关键写法要点:
//     1) 顶层不写算法。若某段小逻辑超过十几行，就该拆成独立模块
//        （本文件的内联逻辑仅剩"计数器/选择器/位拼接"这类三五行的小事）
//     2) 复位策略集中在此: PLL 锁定 → 复位同步释放 → 分发给所有子模块
//     3) 时钟域划分在此确定: 本设计只有 clk_pixel 一个时钟域，
//        因此全文件没有任何跨时钟域同步器 —— 这是**刻意选择**而非遗漏
//   范式认读方法: 见 docs/design_patterns.md
//
// 【板级事实】来源: 底板引脚说明 3.3 + 底板例程 hdmi.adc（与核心板原理图三源一致）
//   HDMI_CLK_P=P1  HDMI_D0_P=N1  HDMI_D1_P=P4  HDMI_D2_P=J3（均 LVDS33）
//   板载 HDMI-019S 座 + AZ1045-04F ESD 阵列，无需转接板；无 DDC → 不做 EDID
//
// 【实现路径说明】HDMI 发送采用官方 DVITransmitter 加密核（与底板例程
//   10_VGA_hdmi_tx_display_MB 同源、与官方赛题参考实现技术同族）。
//   备选自研路径已探明：SF2_LOGIC_HS_OSERDES 原语 + sim_release/eg4 仿真库，
//   可自写 8b/10b 编码器实现完全可仿真的自主 TMDS，留作后续替换。
// =============================================================================
`timescale 1ns / 1ps

module dmz_eg4s20_hdmi_top (
    // ---- 系统时钟 / 复位 ----
    input  wire        clk,            // 50MHz, 球 R7
    input  wire        rst_n_btn,      // RSTn 按键, 球 E3, 低有效
    // ---- 4x4 矩阵键盘 ----
    output wire [3:0]  key_row,        // E10,C10,F9,D9（低电平扫描选通）
    input  wire [3:0]  key_col,        // E11,D11,C11,F10（上拉, 按下为低）
    // ---- LED（高电平点亮）----
    output wire [7:0]  led,            // B14,B15,B16,C15,C16,E13,E16,F16
    // ---- 数码管（段低电平点亮 / 位低电平选通）----
    output wire [7:0]  seg_data,       // A4,A6,B8,E8,A7,B5,A8,C8
    output wire [3:0]  seg_cs,         // C9,B6,A5,A3
    // ---- 蜂鸣器（低电平响）----
    output wire        buzzer,         // H11
    // ---- PWM 音频输出（板载低通+功放，赛规基础要求③）----
    output wire        audio_pwm,      // F3，占空比调制信号
    // ---- HDMI TMDS（只出差分正端；负端由工具按差分对自动配对）----
    output wire        HDMI_CLK_P,     // P1
    output wire        HDMI_D0_P,      // N1
    output wire        HDMI_D1_P,      // P4
    output wire        HDMI_D2_P       // J3
);

    // -------------------------------------------------------------------------
    // [1] PLL 复位延时发生器
    //     功能: 上电后让 PLL 保持复位约 2.5us（8 位计数器计满 128 拍 @50MHz），
    //           等外部晶振起振稳定后再释放，避免 PLL 锁到未稳定的参考时钟
    //     输入: clk, rst_n_btn        输出: pll_reset（高有效）
    // -------------------------------------------------------------------------
    reg [7:0] pll_rst_cnt;  // 【PLL 复位延时计数器】上电后从 0 数到 128（2.56µs @50MHz）
                            //   作用: 让 PLL 在电源与晶振稳定前保持复位状态，
                            //         避免锁到尚未稳定的参考时钟（这是 PLL 的标准启动流程）
                            //   判据: 计到第 8 位为 1（即 128 拍）后释放 pll_reset

    // ---------------- always 块 ① / 共 3 块: PLL 复位延时计数 ----------------
    // 功能: 上电后计数 128 拍（≈2.56µs @50MHz），期间保持 pll_reset 为高，
    //       等外部晶振起振稳定后再释放 PLL —— 避免 PLL 锁到未稳定的参考时钟
    // 输入: clk, rst_n_btn        输出: pll_rst_cnt（pll_reset 取自其最高位）
    always @(posedge clk or negedge rst_n_btn) begin
        if (!rst_n_btn)
            pll_rst_cnt <= 8'd0;
        else if (!pll_rst_cnt[7])
            pll_rst_cnt <= pll_rst_cnt + 8'd1;
    end

    wire pll_reset = ~pll_rst_cnt[7];
                            // 【PLL 复位信号】高有效: 计数未满（bit7 = 0）期间保持为高
                            //   作用: 上电或按键复位时把 PLL 按住，等参考时钟稳定后再放行

    // -------------------------------------------------------------------------
    // [2] hdmi_pll —— 时钟发生器
    //     功能: 50MHz → 25MHz 像素时钟 + 125MHz 串化时钟（严格 5 倍关系）
    //     输入: clk, pll_reset        输出: clk_pixel, clk_5x, locked
    // -------------------------------------------------------------------------
    wire clk_pixel;         // 【25MHz 像素时钟】本工程的**唯一系统时钟**
                            //   作用: 驱动键盘/视频时序/数码管/蜂鸣器/TMDS 像素侧
    wire clk_5x;            // 【125MHz 串化时钟】= 5 × clk_pixel（严格 5 倍关系）
                            //   作用: 仅供 TMDS 并串转换器使用（不驱动任何逻辑）
    wire locked;            // 【PLL 锁定指示】1 = PLL 已锁定、时钟稳定可用
                            //   作用: ① 作为系统复位的释放条件 ② 引到 LED[4] 供现场判断

    hdmi_pll u_pll (
        .refclk    (clk),
        .reset     (pll_reset),
        .extlock   (locked),
        .clk_pixel (clk_pixel),
        .clk_5x    (clk_5x)
    );

    wire rst_n_pll = locked & rst_n_btn;
                            // 【PLL 侧复位】低有效: PLL 已锁定 且 复位键未按下
                            //   作用: 作为复位同步器的异步置位源 —— 任一条件不满足即复位

    // -------------------------------------------------------------------------
    // [3] 复位同步器
    //     功能: 三级移位链实现"异步置位、同步释放"——复位立即生效（异步），
    //           但撤除时刻与 clk_pixel 对齐（同步），避免亚稳态
    //     输入: clk_pixel, rst_n_pll  输出: rst_n（低有效，供全系统使用）
    // -------------------------------------------------------------------------
    reg [2:0] rst_sync;     // 【复位同步移位链】三级串联，每拍向高位补 1
                            //   作用: 实现"异步置位、同步释放"—— 复位立即生效（异步），
                            //         但撤除时刻与 clk_pixel 对齐（同步），规避亚稳态

    // ------------- always 块 ② / 共 3 块: 复位同步释放 -------------
    // 功能: 当 PLL 未锁定或按键按下时全部清 0（复位立即生效）；
    //       否则每拍把 1 向高位移动，三级之后 rst_n 才变高（释放与时钟对齐）
    // 输入: clk_pixel, rst_n_pll      输出: rst_sync（rst_n 取自最高位）
    always @(posedge clk_pixel or negedge rst_n_pll) begin
        if (!rst_n_pll)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], 1'b1};
    end

    wire rst_n = rst_sync[2];
                            // 【全系统复位】低有效，且已与 clk_pixel 同步释放
                            //   作用: 分发给所有子模块（键盘 / 视频 / 显示 / 蜂鸣器 / HDMI）

    // -------------------------------------------------------------------------
    // [4] key_matrix_4x4 —— 键盘扫描
    //     功能: 4×4 矩阵扫描 + 逐键 20ms 消抖 + 按下沿事件输出
    //     输入: clk_pixel, rst_n, key_col    输出: key_event, key_code, key_state
    //     注: 时钟参数改为 25MHz（全系统统一像素时钟域），消抖时长仍为 20ms
    // -------------------------------------------------------------------------
    wire        key_event;  // 【按键事件】单拍脉冲，1 = 有键刚被按下（来自键盘模块）
    wire [3:0]  key_code;   // 【键号】0~15，标识具体是哪个键被按下
    wire [15:0] key_state;  // 【键状态位图】16 键的稳定状态（本顶层未使用，
                            //   综合时会自动优化掉；保留连接便于将来扩展）

    key_matrix_4x4 #(
        .CLK_FREQ_HZ (25_000_000),
        .DEBOUNCE_MS (20)
    ) u_key (
        .clk       (clk_pixel),
        .rst_n     (rst_n),
        .key_row   (key_row),
        .key_col   (key_col),
        .key_event (key_event),
        .key_code  (key_code),
        .key_state (key_state)
    );

    // -------------------------------------------------------------------------
    // [5] 图案选择器
    //     功能: KEY4 上一个图案 / KEY5 下一个图案（3 位自然回绕）
    //     输入: key_event, key_code   输出: pattern_sel[2:0]
    //     注: 键位分配遵循规范——不得与其他模块复用同一按键
    //         （KEY0~KEY3 留给阶段五的播放控制，KEY15 留给应急）
    // -------------------------------------------------------------------------
    reg [2:0] pattern_sel;  // 【当前测试图案编号】0~7，决定 test_pattern_gen 输出哪种图
                            //   3 位正好对应 8 种图案，加减时自然回绕（0-1→7，7+1→0）

    // ------------- always 块 ③ / 共 3 块: 测试图案选择 -------------
    // 功能: KEY4 切到上一个图案、KEY5 切到下一个图案
    // 输入: clk_pixel, rst_n, key_event, key_code      输出: pattern_sel
    // 说明: KEY0~KEY3 留给播放控制，此处只用 KEY4/KEY5 —— 避免同一按键被两个功能复用
    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n)
            pattern_sel <= 3'd0;
        else if (key_event && (key_code == 4'd4))
            pattern_sel <= pattern_sel - 3'd1;      // KEY4 上一图案
        else if (key_event && (key_code == 4'd5))
            pattern_sel <= pattern_sel + 3'd1;      // KEY5 下一图案
    end

    // -------------------------------------------------------------------------
    // [6] video_timing_gen —— 视频时序发生
    //     功能: 产生 640×480@60Hz 的 hs/vs/de 与有效区坐标
    //     输入: clk_pixel, rst_n      输出: hs, vs, de, active_x/y, frame_start
    // -------------------------------------------------------------------------
    wire        hs, vs, de; // 【视频同步】hs=行同步, vs=场同步, de=数据有效（来自 video_timing_gen）
    wire [10:0] active_x;   // 【有效区 X 坐标】0~639（仅 de=1 时有效）
    wire [9:0]  active_y;   // 【有效区 Y 坐标】0~479（仅 de=1 时有效）
    wire        frame_start;// 【帧起始脉冲】每帧一个单拍（预留给阶段四双缓冲切换）

    video_timing_gen u_vtg (
        .pixel_clk   (clk_pixel),
        .rst_n       (rst_n),
        .hs          (hs),
        .vs          (vs),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .frame_start (frame_start)
    );

    // -------------------------------------------------------------------------
    // [7] test_pattern_gen —— 测试图案发生器
    //     功能: 依 pattern_sel 组合译码出 8 种图案的 RGB888 像素
    //     输入: clk_pixel, de, active_x/y, pattern_sel, user_color
    //     输出: pr/pg/pb[7:0]（24 位 RGB888）
    //     注: 纯组合输出，与 de/坐标严格同拍（避免 1 像素相位偏移）
    // -------------------------------------------------------------------------
    wire [7:0] pr, pg, pb;  // 【测试图案像素】红/绿/蓝各 8 位，由 test_pattern_gen 组合输出
                            //   注意: 它与 de/坐标**同拍**产生，不可再寄存
                            //         （否则整幅图会向右偏移 1 个像素）

    test_pattern_gen #(
        .H_ACTIVE (11'd640),
        .V_ACTIVE (10'd480)
    ) u_pat (
        .pixel_clk   (clk_pixel),
        .rst_n       (rst_n),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .pattern_sel (pattern_sel),
        .user_color  (24'h00_00_00),        // 纯色模式用黑色（阶段五接状态叠加）
        .rgb_r       (pr),
        .rgb_g       (pg),
        .rgb_b       (pb)
    );

    // -------------------------------------------------------------------------
    // [8] hdmi_tx —— TMDS 发送（VHDL 桥接层 → DVITransmitter 加密核）
    //     功能: RGB888 + 同步信号 → 8b/10b 编码 → 并串转换 → TMDS 差分输出
    //     输入: clk_pixel, clk_5x, rst_n, hs/vs/de, {pr,pg,pb}
    //     输出: HDMI_CLK_P, HDMI_D0_P, HDMI_D1_P, HDMI_D2_P
    //     注: RST_N 低有效（官方顶层把它恒接 0 = 永不复位；
    //         本工程接的是 PLL 锁定后同步释放的 rst_n，更严谨）
    // -------------------------------------------------------------------------
    hdmi_tx #(
        .FAMILY ("EG4")
    ) u_hdmi (
        .PXLCLK_I    (clk_pixel),
        .PXLCLK_5X_I (clk_5x),
        .RST_N       (rst_n),
        .VGA_HS      (hs),
        .VGA_VS      (vs),
        .VGA_DE      (de),
        .VGA_RGB     ({pr, pg, pb}),
        .HDMI_CLK_P  (HDMI_CLK_P),
        .HDMI_D2_P   (HDMI_D2_P),
        .HDMI_D1_P   (HDMI_D1_P),
        .HDMI_D0_P   (HDMI_D0_P)
    );

    // -------------------------------------------------------------------------
    // [9a] 数码管显示
    //      功能: 最右位显示当前图案号（0~7），其余三位熄灭
    //      输入: pattern_sel + rst_n + clk_pixel
    //      输出: seg_data[7:0], seg_cs[3:0]
    //      注: 段码为低电平点亮 → 8'hFF 表示该位全灭
    // -------------------------------------------------------------------------
    wire [6:0] seg_pat;     // 【图案号段码】pattern_sel 经 seg_decoder 译码后的 7 段码
                            //   位序 {g,f,e,d,c,b,a}，低电平点亮
    seg_decoder u_dec_pat (
        .bin_data ({1'b0, pattern_sel}),
        .seg_data (seg_pat)
    );

    seg_scan4 #(
        .CLK_FREQ_HZ (25_000_000),
        .SCAN_HZ     (1000)
    ) u_seg (
        .clk      (clk_pixel),
        .rst_n    (rst_n),
        .dig0     ({1'b1, seg_pat}),        // 最右位: 图案号（DP 灭）
        .dig1     (8'hFF),                  // 以下三位熄灭
        .dig2     (8'hFF),
        .dig3     (8'hFF),
        .seg_data (seg_data),
        .seg_cs   (seg_cs)
    );

    // -------------------------------------------------------------------------
    // [9b] LED 指示
    //      功能: bit7~5 = 图案号, bit4 = PLL 锁定指示（现场调试关键信号）,
    //            低 4 位预留
    //      输入: pattern_sel, locked      输出: led[7:0]
    // -------------------------------------------------------------------------
    assign led = {pattern_sel, locked, 4'b0000};

    // -------------------------------------------------------------------------
    // [9c] 蜂鸣器提示音
    //      功能: 每次按键短鸣 100ms（C5≈523Hz），作为操作反馈
    //      输入: clk_pixel, rst_n, key_event   输出: buzzer（低电平响）
    // -------------------------------------------------------------------------
    buzzer_tone #(
        .CLK_FREQ_HZ (25_000_000)
    ) u_buzz (
        .clk        (clk_pixel),
        .rst_n      (rst_n),
        .tone_sel   (2'd1),                 // 按键音模式
        .trig       (key_event),
        .buzzer_out (buzzer)
    );

    // -------------------------------------------------------------------------
    // [10] PWM 音频输出 —— 赛规基础要求③（音频通路）
    //      功能: DDS 合成 440Hz 三角波测试音 → 8bit PWM 调制 → 板载低通+功放
    //      输入: clk_pixel, rst_n               输出: audio_pwm（球 F3）
    //      注: 与蜂鸣器分工 —— H11 蜂鸣器出按键提示音（方波），
    //          F3 音频座出持续测试音（验证音频通路）；驱动不同器件互不冲突
    // -------------------------------------------------------------------------
    pwm_audio_out #(
        .CLK_FREQ_HZ (25_000_000),
        .FREQ_HZ     (440)
    ) u_audio (
        .clk       (clk_pixel),
        .rst_n     (rst_n),
        .mute      (1'b0),                  // 现阶段常开；阶段五接播放控制
        .audio_pwm (audio_pwm)
    );

endmodule
