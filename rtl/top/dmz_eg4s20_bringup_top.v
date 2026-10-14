// =============================================================================
// dmz_eg4s20_bringup_top.v — 整机预演顶层（最小系统 + 视频通路）
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 顶层（Top Level）—— 阶段三的"过渡型总装配图"
//   工程归属 : 暂未单独建 TD 工程（用于仿真验证与方案预演；
//              正式 HDMI 工程为 project/hdmi_td.al）
//   数据流位置:
//       50MHz 晶振(R7) → 【本模块】→ 三路并行:
//         ① 视频路: 视频时序 → 测试图（RGB888 并行输出，可接底板 VGA/RGB565）
//         ② 控制路: 键盘 → player_ctrl（播放控制状态机）
//         ③ 显示路: 数码管 / LED / 蜂鸣器
//   为什么需要它（与另外两个顶层的关系）:
//     - dmz_eg4s20_min_top  : 只验证板级基础（无视频）
//     - dmz_eg4s20_hdmi_top : 正式 HDMI 工程（视频 + TMDS，暂不含播放控制）
//     - **本模块**          : 中间的"预演平台"—— 把播放控制状态机与视频通路
//                             放在一起跑通，并保留 RGB888 并行接口
//                             （不依赖 HDMI 加密核，可直接接底板 VGA 目检）
//     三者的子模块完全相同，差异只在"装配了哪些" —— 这正是分层设计的价值
//
// 【二、本模块功能】
//   一句话职责: 在最小系统基础上加入视频通路与播放控制，形成完整功能预演。
//   组成:
//     1. 时钟/复位: 50M 输入直驱（PLL 在 TD 工程中添加；仿真用 50M÷2 近似像素时钟）
//     2. 4×4 键盘 → 播放控制 + 测试图切换
//     3. 视频时序 → 测试图（8 模式）→ RGB888 并行输出
//     4. 数码管显示 模式/图案号/图号；LED 显示图案号 + 控制状态
//     5. 蜂鸣器: 按键音 / 应急音
//   键位分配（同一按键不得被两个功能复用 —— 修复前 KEY0/KEY1 曾同时驱动
//             播放控制与图案切换，导致一次按键触发两种行为）:
//     KEY0 = 上一张      KEY1 = 下一张      KEY2 = 播放/暂停    KEY3 = 模式循环
//     KEY4 = 上一图案    KEY5 = 下一图案    KEY15 = 应急直达
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  clk            : 50MHz 系统时钟（球 R7）
//     输入  rst_n_btn      : 复位按键（球 E3，低有效）
//     输出  key_row[3:0]   : 键盘行扫描（E10/C10/F9/D9）
//     输入  key_col[3:0]   : 键盘列回读（E11/D11/C11/F10）
//     输出  led[7:0]       : LED（B14…F16，高电平点亮）
//     输出  seg_data[7:0]  : 数码管段选（低电平点亮）
//     输出  seg_cs[3:0]    : 数码管位选（低电平选通）
//     输出  buzzer         : 蜂鸣器（H11，低电平响）
//     输出  video_r/g/b[7:0]: 并行 RGB888 视频输出（24 位）
//     输出  video_hs/vs/de  : 视频同步与数据有效
//     输出  video_clk_out   : 像素时钟输出（VGA 模式需要）
//
//   内部逻辑块（共 9 块，按信号流顺序）:
//     [1] 像素时钟分频（内联）  always @(posedge clk50)
//           功能: 50MHz ÷ 2 ≈ 25MHz 近似像素时钟（仿真与 RGB 目检用；
//                 正式 HDMI 工程改用 PLL 精确产生）
//           输入: clk50, rst_n              输出: clk_pix
//     [2] key_matrix_4x4       子模块例化
//           功能: 键盘扫描 + 20ms 消抖 + 按下事件
//           输入: clk50, rst_n, key_col     输出: key_event, key_code, key_state
//     [3] player_ctrl          子模块例化
//           功能: 播放控制状态机（切图 / 播放暂停 / 模式切换 / 自动轮播）
//           输入: key_event, key_code, gallery_count/valid
//           输出: img_index, img_switch_req, auto_play_en, mode, status_led
//     [4] 图案选择器（内联）    always @(posedge clk50)
//           功能: KEY4 上一个图案 / KEY5 下一个图案
//           输入: key_event, key_code       输出: pattern_sel[2:0]
//     [5] video_timing_gen     子模块例化
//           功能: 640×480@60 时序发生
//           输入: clk_pix, rst_n            输出: hs, vs, de, active_x/y, frame_start
//     [6] test_pattern_gen     子模块例化
//           功能: 8 种测试图案
//           输入: de, active_x/y, pattern_sel, user_color   输出: pr/pg/pb
//     [7] seg_decoder ×4       子模块例化
//           功能: 模式号 / 图案号 / 图号十位 / 图号个位 → 4 组段码
//           输入: mode, pattern_sel, img_tens, img_ones     输出: 4 组段码
//     [8] seg_scan4            子模块例化
//           功能: 动态扫描驱动数码管
//           输入: 4 组段码                  输出: seg_data, seg_cs
//     [9] buzzer_tone          子模块例化
//           功能: 按键音 / 应急音（应急模式下自动切到急促音）
//           输入: key_event, mode           输出: buzzer
//     另有若干 assign: LED 拼接、视频输出直通
//
//   【板级事实】来源: 核心板原理图 p2/p4 + 走近FPGA 表1.1~1.6（全部已核实）
//     clk=R7(50M)  rst_n_btn=E3(低有效)
//     LED0~7 = B14/B15/B16/C15/C16/E13/E16/F16（高电平点亮）
//     键盘行 E10/C10/F9/D9，列 E11/D11/C11/F10
//     数码管 / 蜂鸣器的管脚见各自模块头部注释
//
// 【四、设计思路与范式】
//   主要范式 : 结构化装配（Structural）
//   次要范式 : 计数器分频（像素时钟）、组合译码（图号 → BCD 十位/个位）、
//              状态机驱动（player_ctrl 的输出被多处消费）
//   为什么这样写:
//     1) **为什么保留"两个控制器"分离**: player_ctrl 管"播放什么"（图号、模式），
//        顶层的图案选择器管"显示哪种测试图"。两者职责不同：前者是产品功能，
//        后者是调试工具 —— 混在一起会导致阶段五难以剥离
//     2) **为什么用 50M÷2 而不是 PLL**: 这是仿真与 RGB 目检阶段的权宜方案
//        （误差 0.7%，VGA 显示器可容忍）。正式 HDMI 链路必须用 PLL ——
//        因为 TMDS 要求像素时钟与串化时钟严格 5 倍，普通分频做不到
//     3) **为什么视频输出保留 24 位 RGB888 而不直接出 TMDS**: 保留并行接口便于
//        ① 仿真验证 ② 接底板 VGA/RGB565 座目检（不依赖 HDMI 加密核）。
//        这样"视频时序是否正确"与"HDMI 发送是否正确"可以分开排查
//   关键写法要点:
//     - 顶层不写算法；内联逻辑只保留"计数器/选择器/位拼接"这类三五行的小事
//     - 例化显式传参、端口一律命名连接（便于换时钟频率与调整端口顺序）
//   范式认读方法: 见 docs/design_patterns.md
// =============================================================================
`timescale 1ns / 1ps

module dmz_eg4s20_bringup_top (
    // 系统时钟/复位
    input  wire        clk,            // 50MHz, 球 R7
    input  wire        rst_n_btn,      // RSTn 按键, 球 E3, 低有效（按下=低）
    // 4x4 矩阵键盘
    output wire [3:0]  key_row,        // E10,C10,F9,D9
    input  wire [3:0]  key_col,        // E11,D11,C11,F10
    // LED（高亮）, 板上与 R-2R DAC 复用
    output wire [7:0]  led,            // B14,B15,B16,C15,C16,E13,E16,F16
    // 数码管
    output wire [7:0]  seg_data,       // 段选（低电平点亮, 与 seg_decoder 段码极性一致）
    output wire [3:0]  seg_cs,         // 位选（低选通）
    // 蜂鸣器
    output wire        buzzer,         // H11, 低响
    // 视频并行 RGB 输出（VGA DAC 底板 / RGB565 FPC / 后级 HDMI 核）
    output wire [7:0]  video_r,
    output wire [7:0]  video_g,
    output wire [7:0]  video_b,
    output wire        video_hs,
    output wire        video_vs,
    output wire        video_de,
    output wire        video_clk_out   // 像素时钟输出（VGA 模式需要）
);
    // ---------------------------------------------------------------------------
    // 复位: 按键低有效, 板级无附加去抖需求（RSTn 直入 PLL 与逻辑, 按键机械抖动
    // 对异步复位影响可接受; 若上板发现复位抖动问题再追加同步释放）
    wire clk50 = clk;       // 【系统时钟别名】把输入端口 clk 改名为 clk50 使用
                            //   作用: 信号名里带频率，读代码时一眼看出这是 50MHz 时钟域
                            //         —— 本项目把"频率"写进时钟信号名，避免时钟域混淆
    wire rst_n = rst_n_btn; // 【复位别名】把复位按键改名为全工程统一的低有效 rst_n
                            //   作用: 统一命名约定 —— 子模块端口一律叫 rst_n，
                            //         极性差异只在这一处体现，改动时不必翻阅各模块
    // 上板建议: PLL locked 后再释放内部复位（此处直接用按键, 最小系统先跑通）
    // ---------------------------------------------------------------------------

    // ============================ 按键 ============================
    wire       key_event;          // 【按键事件】单拍脉冲，1 = 有键刚被按下（来自键盘模块）
    wire [3:0] key_code;           // 【键号】0~15，标识具体是哪个键被按下
    wire [15:0] key_state;         // 【键状态位图】16 键的稳定状态（本顶层未使用，
                                   //   综合时会自动优化掉；保留连接便于将来扩展）

    key_matrix_4x4 #(
        .CLK_FREQ_HZ (50_000_000),
        .DEBOUNCE_MS (20)
    ) u_key (
        .clk       (clk50),
        .rst_n     (rst_n),
        .key_row   (key_row),
        .key_col   (key_col),
        .key_event (key_event),
        .key_code  (key_code),
        .key_state (key_state)
    );

    // ============================ 播放控制 ============================
    wire [4:0]  img_index;         // 【当前图片索引】0~31，由 player_ctrl 状态机维护
                                   //   本顶层用它算出数码管要显示的"图号"
    wire        img_switch_req;    // 【切图请求】单拍脉冲
                                   //   预留接口: 阶段四接 SDRAM 帧缓存控制器；
                                   //   本顶层暂未使用，保留是为了阶段四能"即插即用"
    wire        auto_play_en;      // 【自动轮播使能】1 = 正在自动轮播
                                   //   预留接口: 阶段六接 OSD/状态显示
    wire [1:0]  mode;              // 【工作模式】0=日常 1=科普 2=应急
                                   //   作用: 驱动蜂鸣器音调切换与 LED 状态指示
    wire [3:0]  status_led;        // 【状态指示】bit0=轮播中, bit1=应急模式（来自 player_ctrl）

    player_ctrl #(
        .IMG_COUNT   (8),
        .AUTO_SW_S   (5),
        .CLK_FREQ_HZ (50_000_000)
    ) u_ctrl (
        .clk            (clk50),
        .rst_n          (rst_n),
        .key_event      (key_event),
        .key_code       (key_code),
        .gallery_count  (5'd8),          // 最小系统: 假设 8 图（SD 链路接入后由扫描结果驱动）
        .gallery_valid  (1'b1),
        .img_index      (img_index),
        .img_switch_req (img_switch_req),
        .auto_play_en   (auto_play_en),
        .mode           (mode),
        .status_led     (status_led)
    );

    // ============================ 视频 ============================
    // 像素时钟: 真实硬件 25.175MHz 由 PLL 分出; 最小系统仿真与 RGB 目检阶段
    // 先用 50M/2 = 25MHz 直分频（误差 0.7%, VGA 显示器容忍; HDMI 正式链路用 PLL）
    reg clk_pix;            // 【像素时钟】50MHz ÷ 2 ≈ 25MHz 的近似像素时钟
                            //   作用: 驱动视频时序与图案发生器（仿真与 RGB 目检阶段使用）
                            //   正式 HDMI 工程改用 PLL 精确产生 —— 因为 TMDS 要求像素时钟
                            //   与串化时钟严格 5 倍关系，普通逻辑分频无法满足
    // ========== always 块 ① / 共 2 块: 像素时钟二分频 ==========
    // 功能: 每个 clk50 上升沿翻转一次 clk_pix → 得到 25MHz 方波
    // 输入: clk50, rst_n              输出: clk_pix
    // 说明: 这是最简单的分频写法（T 触发器）。此处可用是因为 clk_pix 只驱动
    //       普通逻辑且频率远低于系统时钟；若要把它当作独立时钟域边界使用，
    //       必须改用 BUFG 原语而非普通逻辑输出
    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n)          clk_pix <= 1'b0;
        else                 clk_pix <= ~clk_pix;
    end

    wire        hs, vs, de, frame_start;
                                   // 【视频时序信号】来自 video_timing_gen:
                                   //   hs = 行同步, vs = 场同步, de = 数据有效
                                   //   frame_start = 帧起始单拍脉冲（预留: 阶段四双缓冲切换）
    wire [10:0] active_x;          // 【有效区 X 坐标】0~639（仅 de=1 时有效）
    wire [9:0]  active_y;          // 【有效区 Y 坐标】0~479（仅 de=1 时有效）

    video_timing_gen u_vtg (
        .pixel_clk   (clk_pix),
        .rst_n       (rst_n),
        .hs          (hs),
        .vs          (vs),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .frame_start (frame_start)
    );

    // 图案选择: KEY4/KEY5 增减（独立于 player_ctrl 占用的 KEY0~KEY3）
    reg [2:0] pattern_sel;  // 【当前测试图案编号】0~7，决定 test_pattern_gen 输出哪种图
                            //   作用: 现场调试时快速切换画面、定位故障（哪种图案不对，
                            //         就能反推是哪一段链路有问题）
                            //   为何用 3 位: 共 8 种图案，加减时自然回绕（0-1→7，7+1→0）

    // ============ always 块 ② / 共 2 块: 测试图案选择 ============
    // 功能: KEY4 切到上一个图案、KEY5 切到下一个图案（3 位自然回绕）
    // 输入: clk50, rst_n, key_event, key_code      输出: pattern_sel
    // 说明: 按键分工刻意与 player_ctrl 错开 —— KEY0~KEY3 归播放控制、
    //       KEY4/KEY5 归图案切换。早期两者曾共用 KEY0/KEY1，导致按一次键
    //       同时触发"切图片"和"切图案"两种行为（本项目已修复的按键冲突）
    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n)
            pattern_sel <= 3'd0;
        else if (key_event && (key_code == 4'd4))
            pattern_sel <= pattern_sel - 3'd1;      // KEY4 上一图案
        else if (key_event && (key_code == 4'd5))
            pattern_sel <= pattern_sel + 3'd1;      // KEY5 下一图案
    end

    wire [7:0] pr, pg, pb;         // 【测试图案像素】红/绿/蓝各 8 位
                                   //   由 test_pattern_gen 组合输出，与 de/坐标严格同拍
                                   //   （下游不可再寄存，否则图案会向右偏移 1 像素）
    test_pattern_gen #(
        .H_ACTIVE (11'd640),
        .V_ACTIVE (10'd480)
    ) u_pat (
        .pixel_clk   (clk_pix),
        .rst_n       (rst_n),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .pattern_sel (pattern_sel),
        .user_color  ({8'h00, mode, 3'b000, img_index[4:0], 6'h00}),  // 纯色模式下嵌入状态位（24bit）
        .rgb_r       (pr),
        .rgb_g       (pg),
        .rgb_b       (pb)
    );

    assign video_r   = pr;
    assign video_g   = pg;
    assign video_b   = pb;
    assign video_hs  = hs;
    assign video_vs  = vs;
    assign video_de  = de;
    assign video_clk_out = clk_pix;

    // ============================ 数码管 ============================
    // 显示: 最左位=模式(0/1/2), 次 3 位=图案号十六进制（直观化最小系统状态）
    wire [6:0] seg_mode, seg_pat_h, seg_pat_m, seg_pat_l;
                                   // 【4 位数码管段码】从最左位到最右位依次为:
                                   //   seg_mode  = 工作模式号（0/1/2，一眼看出当前模式）
                                   //   seg_pat_h = 测试图案号（0~7）
                                   //   seg_pat_m = 图片索引十位
                                   //   seg_pat_l = 图片索引个位
                                   //   均由 seg_decoder 译码产生，低电平点亮
    seg_decoder u_dec_mode (
        .bin_data ({2'b00, mode}), .seg_data (seg_mode)
    );
    seg_decoder u_dec_pat3 (
        .bin_data ({1'b0, pattern_sel[2:0]}), .seg_data (seg_pat_h)
    );
    // 中/右两位显示图号（img_index 十位/个位 BCD; 图数 ≤31, 用简单分支避免
    // 对表达式取位/取模, 保证 Verilog-2001 与综合工具兼容）
    wire [3:0] img_tens;           // 【图号十位】= img_index / 10（组合运算）
    wire [3:0] img_ones;           // 【图号个位】= img_index % 10（组合运算）
                                   //   说明: 索引范围仅 0~31，综合器可把除法/取模
                                   //         优化成小规模查表，资源代价很小
    assign img_tens = (img_index >= 5'd30) ? 4'd3 :
                      (img_index >= 5'd20) ? 4'd2 :
                      (img_index >= 5'd10) ? 4'd1 : 4'd0;
    wire [4:0] img_ones5 = img_index - ({1'b0, img_tens} * 5'd10);
    assign img_ones = img_ones5[3:0];
    seg_decoder u_dec_tens (.bin_data (img_tens), .seg_data (seg_pat_m));
    seg_decoder u_dec_ones (.bin_data (img_ones), .seg_data (seg_pat_l));

    seg_scan4 #(
        .CLK_FREQ_HZ (50_000_000),
        .SCAN_HZ     (1000)
    ) u_seg (
        .clk      (clk50),
        .rst_n    (rst_n),
        .dig0     ({1'b1, seg_pat_l}),      // 右位: 图号个位（DP 灭）
        .dig1     ({1'b1, seg_pat_m}),      // 次右: 图号十位
        .dig2     ({1'b1, seg_pat_h}),      // 次左: 图案号
        .dig3     ({1'b1, seg_mode}),       // 最左: 模式
        .seg_data (seg_data),
        .seg_cs   (seg_cs)
    );

    // ============================ LED ============================
    // LED7~0: bit7 预留(0), bit6~4 = pattern_sel, bit3~0 = status_led
    // 注: 拼接总宽必须等于 8 —— 修复前 {pattern_sel, status_led} 仅 7 位,
    //     导致 led[7] 恒 0 且产生位宽不匹配告警
    assign led = {1'b0, pattern_sel, status_led};

    // ============================ 蜂鸣器 ============================
    // 应急模式 → 急促音（250ms 响/停循环）; 其余时刻 → 按键音模式（trig 开启 100ms 窗口）
    wire beep_trig = key_event;   // 【蜂鸣器触发】任意按键都触发一声提示音
                                  //   直接接按键事件（单拍），响多久由 buzzer_tone 内部决定
    wire [1:0] tone_sel = (mode == 2'd2) ? 2'd2 : 2'd1;
                                  // 【音调选择】应急模式(2) 用应急音，其余模式用按键音
                                  //   作用: 让"进入应急模式"在听觉上也有明确区分度
    buzzer_tone #(
        .CLK_FREQ_HZ (50_000_000)
    ) u_buzz (
        .clk        (clk50),
        .rst_n      (rst_n),
        .tone_sel   (tone_sel),
        .trig       (beep_trig),
        .buzzer_out (buzzer)
    );

endmodule
