// =============================================================================
// dmz_eg4s20_bringup_top.v
// 功能: DMZ-EG4S20 最小系统验证顶层（阶段二）+ 视频通路自检（阶段三预演）
// 组成:
//   1. 时钟/复位: 50M 输入直驱（PLL 在 TD 工程中添加, 仿真用 50M 直通验证逻辑）
//   2. 4x4 矩阵键盘扫描 → 播放控制 + 测试图切换
//   3. 视频时序 → 测试图（8 模式）→ RGB888 输出
//   4. 数码管: 显示 模式/图案号/图号; LED: 图案号 + 控制状态
//   5. 蜂鸣器: 按键音/应急音
// 键位分配（同一按键不得被两个功能复用 —— 修复前 KEY0/KEY1 同时驱动
//           播放控制与图案切换, 导致一次按键触发两种行为）:
//   KEY0 = 上一张      KEY1 = 下一张      KEY2 = 播放/暂停    KEY3 = 模式循环
//   KEY4 = 上一图案    KEY5 = 下一图案    KEY15 = 应急直达
// 板级事实（全部已核实, 见 pending_confirmations.md）:
//   clk=R7(50M)  rst=RSTn(E3,低有效)  LED0~7=B14,B15,B16,C15,C16,E13,E16,F16(高亮)
//   Key_Row=E10,C10,F9,D9  Key_Col=E11,D11,C11,F10  数码管/蜂鸣器见各模块头
// 注意: HDMI TMDS 输出（hdmi_phy/hdmi_tx）依赖 TD IP（.enc 加密）,
//       本顶层先以 RGB888 并行接口引出 video 通路, 供:
//       a) 仿真验证（本文件 + tb）;
//       b) 板上接 VGA/RGB565 底板接口快速目检（不依赖 HDMI 转接板）;
//       c) 后续接官方 APUG092 核 + hdmi_phy 完成 HDMI 输出（阶段三）。
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
    wire clk50 = clk;
    wire rst_n = rst_n_btn;
    // 上板建议: PLL locked 后再释放内部复位（此处直接用按键, 最小系统先跑通）
    // ---------------------------------------------------------------------------

    // ============================ 按键 ============================
    wire       key_event;
    wire [3:0] key_code;
    wire [15:0] key_state;         // 键状态位图（当前顶层未使用, 综合会自动优化）

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
    wire [4:0]  img_index;
    wire        img_switch_req;    // 预留接口: 阶段四接 SDRAM 帧缓存控制器
    wire        auto_play_en;      // 预留接口: 阶段六接 OSD/状态显示
    wire [1:0]  mode;
    wire [3:0]  status_led;

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
    reg clk_pix;
    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n)          clk_pix <= 1'b0;
        else                 clk_pix <= ~clk_pix;
    end

    wire        hs, vs, de, frame_start;
    wire [10:0] active_x;
    wire [9:0]  active_y;

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
    reg [2:0] pattern_sel;
    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n)
            pattern_sel <= 3'd0;
        else if (key_event && (key_code == 4'd4))
            pattern_sel <= pattern_sel - 3'd1;      // KEY4 上一图案
        else if (key_event && (key_code == 4'd5))
            pattern_sel <= pattern_sel + 3'd1;      // KEY5 下一图案
    end

    wire [7:0] pr, pg, pb;
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
    seg_decoder u_dec_mode (
        .bin_data ({2'b00, mode}), .seg_data (seg_mode)
    );
    seg_decoder u_dec_pat3 (
        .bin_data ({1'b0, pattern_sel[2:0]}), .seg_data (seg_pat_h)
    );
    // 中/右两位显示图号（img_index 十位/个位 BCD; 图数 ≤31, 用简单分支避免
    // 对表达式取位/取模, 保证 Verilog-2001 与综合工具兼容）
    wire [3:0] img_tens;
    wire [3:0] img_ones;
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
    wire beep_trig = key_event;                       // 任意按键触发按键音
    wire [1:0] tone_sel = (mode == 2'd2) ? 2'd2 : 2'd1;
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
