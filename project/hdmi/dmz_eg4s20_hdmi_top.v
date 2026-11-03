// 阶段四 S6 + 阶段五 S7 前置切片：SD/FAT32/BMP -> SiP SDRAM -> HDMI 图片播放顶层。
// S7 切片要点：图库张数不再由编译参数给定，改由 gallery_probe 在 SD 就绪后
//   runtime 扫描得出（见下方"三段严格串行"），换一批素材/换一张卡都不必重综合。
// S8 切片要点（本次）：**HDMI 音频嵌入**。原来的 hdmi_tx（Anlogic DVITransmitter
//   加密核）是纯 DVI 发射器，实体上只有 4 条视频通道，没有任何音频入口 —— 所以
//   "加一段音频代码"在这条路径上不可能实现，必须换成带音频通道的 HDMI 1.4b
//   发射核（APUG092 的 hdmi_1_4b_transmitter_core）。换核带来三处结构性改动：
//     1) 视频接口从 DVI 的 DE/HS/VS/RGB 改为 AXIS 流（user/valid/last/data），
//        因此新增 video_rgb_to_axis 做翻译；
//     2) 新增 Audio 接口（48 kHz I_audio_valid + 24 bit 左右声道）与 ACR 接口
//        （CTS/N），分别由 audio_tone_gen / audio_arc 驱动；
//     3) TMDS 串化从核内部搬到 RTL 层（hdmi_phy + lane_lvds_10_1，用 EG_LOGIC_ODDR）。
// 上板结果须单独记录。管脚依据 constraints/。
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
    // ---- SD 卡（SPI 模式，启动探针后接 FAT32/BMP 扇区读取）----
    output wire        sd_cs_n,        // F13, 片选（低有效）
    output wire        sd_sck,         // F15, SPI 时钟
    output wire        sd_mosi,        // F14, 主出从入（CMD 线）
    input  wire        sd_miso,        // D14, 主入从出（DAT0 线）
    input  wire        sd_cd,          // E15, 卡插入检测（无卡=1 插卡=0）
    // ---- 模拟音频输出（板载低通+功放，赛规基础要求③）----
    // 语义已升级：不再是固定 440 Hz 测试音，而是与 HDMI 内嵌音频同一份 PCM
    // 经一阶 sigma-delta 调制后的 1 bit 流（见 pcm_to_pwm.v 文件头）。
    output wire        audio_pwm,      // F3
    // ---- AHT20 温湿度传感器（I2C，开漏 + 外部上拉）----
    // 用户裁定：只用 AHT20 单传感器，NTC / Plan B 不实施。
    // ★ 必须接成开漏三态，不能接成推挽输出：接推挽时总线上任一方拉低，
    //   另一方若正在输出高电平就是短路（V_OL 冲突），轻则通信失败重则损伤器件。
    //   顶层写法：assign i2c_scl = scl_oe ? 1'bz : 1'b0;
    //   .adc 里已配 PULLTYPE = PULLUP（D1/E1），两端都是"只拉低、靠上拉拉高"。
    // ★ I2C 是双向线，端口方向必须 inout，不能拆成 in + out 两个端口。
    output wire        i2c_scl,        // D1, 开漏（0 = 拉低, 高阻 = 释放）
    inout  wire        i2c_sda,        // E1, 开漏双向（写时驱动，读时释放）
    // ---- HDMI TMDS（只出差分正端；负端由工具按差分对自动配对）----
    output wire        HDMI_CLK_P,     // P1
    output wire        HDMI_D0_P,      // N1
    output wire        HDMI_D1_P,      // P4
    output wire        HDMI_D2_P       // J3
);

    // 50MHz 参考时钟同时送两颗 PLL；视频不依赖 SDRAM PLL 是否锁定。
    reg [7:0] pll_rst_cnt;
    always @(posedge clk or negedge rst_n_btn) begin
        if(!rst_n_btn) pll_rst_cnt <= 0;
        else if(!pll_rst_cnt[7]) pll_rst_cnt <= pll_rst_cnt + 1'b1;
    end
    wire pll_reset = ~pll_rst_cnt[7];
    wire clk_pixel, clk_5x, locked, clk_sdr, clk_sdr_sft, sdram_locked;
    hdmi_pll u_pll (.refclk(clk), .reset(pll_reset), .extlock(locked),
        .clk_pixel(clk_pixel), .clk_5x(clk_5x));
    sdram_pll u_sdram_pll (.refclk(clk), .reset(pll_reset), .extlock(sdram_locked),
        .sdram_clk(clk_sdr), .sdram_clk_sft(clk_sdr_sft));
    wire rst_async_pix = rst_n_btn && locked;
    wire rst_async_sdr = rst_n_btn && locked && sdram_locked;
    reg [2:0] rst_sync_pix, rst_sync_sdr;
    always @(posedge clk_pixel or negedge rst_async_pix) begin
        if(!rst_async_pix) rst_sync_pix <= 0;
        else rst_sync_pix <= {rst_sync_pix[1:0],1'b1};
    end
    always @(posedge clk_sdr or negedge rst_async_sdr) begin
        if(!rst_async_sdr) rst_sync_sdr <= 0;
        else rst_sync_sdr <= {rst_sync_sdr[1:0],1'b1};
    end
    wire rst_n = rst_sync_pix[2];
    wire key_event; wire [3:0] key_code;
    key_matrix_4x4 #(.CLK_FREQ_HZ(25_000_000), .DEBOUNCE_MS(20)) u_key (
        .clk(clk_pixel), .rst_n(rst_n), .key_row(key_row), .key_col(key_col),
        .key_event(key_event), .key_code(key_code), .key_state());
    // =========================================================================
    // 键位分配总表（v2，见 docs/plan_v2/KEYMAP.md §8）
    //   同一按键不得被两个功能复用 —— 这是本项目历史上出过事故的地方。
    //   KEY0/1        → player_ctrl（上一张 / 下一张；经 key_event_media 门控后才进得去）
    //   KEY2/3        → mode_ctrl（模式循环 / 应急直达与双按退出）
    //   KEY4~KEY10    → key_router（音频/字幕/亮度/音量/分辨率/屏占比/可视化）
    //   KEY11~KEY15   → key_router 的 P2 备用键（P2_EN=0 时恒 0，见 key_router.v）
    //
    // 【v1 → v2 删掉了什么，为什么】
    //   v1 在顶层直接消费了三个键号：
    //     :84/:85  key_code==4 / ==5 → pattern_sel（测试图案上/下一张）
    //     :402     key_code==6       → audio_muted（音频静音）
    //   而 v2 的 key_router 已经把 Key4~Key15 全部收拢成唯一译码点。若顶层
    //   继续保留这三处直连，同一个键就有两个消费者 —— 按一次动两下，或者
    //   动的是另一个参数，**不报错、不告警**。所以这三处必须删干净，
    //   再让 key_router 接管（顺序：先建后删，见 §3.6）。
    // =========================================================================

    // ---- 模式状态机：模式的唯一权威（取代 player_ctrl.mode）------------------
    // 为什么不能再用 player_ctrl.mode：它的 mode 是 assign mode = state[1:0]，
    //   只认 K_MODE=3 / K_EMERG=15 两个 v1 键号，而 v2 的规格是 Key2/Key3。
    //   两套键号不能共存（Key3 在 player_ctrl 里是"轮播"，在 v2 里是"应急"）。
    wire [1:0] mode;            // 0=日常 1=科普 2=应急
    wire       emerg_latched;   // 应急已锁存（电平；只能由 Key3 双按清除）
    wire [1:0] emerg_src;       // 0=无 1=按键 2=温度
    wire       confirm_armed;   // 退出确认窗口内为 1
    wire       mode_changed;    // 单拍：模式变化
    wire       m_daily, m_science, m_emerg;   // 组合译码，= (mode==0/1/2)
    // 温度报警：来自 thermal_guard.oth_en（电平，已含迟滞）。
    //   ★ 必须接电平版 oth_en，不能接 oth_enter（单拍）—— mode_ctrl 内部自己要
    //     做 temp_alarm_rise = temp_alarm & ~temp_alarm_d，接单拍会永远采不到。
    //   ★ 绝不能接 aht20_ctrl.sensor_fault：传感器坏 ≠ 着火。接了会让终端进
    //     应急并且**退不出来**（根本没有读数可用来降温退出）。
    wire       temp_alarm;
    mode_ctrl #(.CLK_FREQ_HZ(25_000_000), .CONFIRM_MS(2000)) u_mode (
        .clk(clk_pixel), .rst_n(rst_n),
        .key_event(key_event), .key_code(key_code),
        .temp_alarm(temp_alarm),
        .mode(mode), .emerg_latched(emerg_latched), .emerg_src(emerg_src),
        .confirm_armed(confirm_armed), .mode_changed(mode_changed),
        .daily_mode(m_daily), .science_mode(m_science), .emerg_mode(m_emerg));

    // ---- 功能键统一译码（Key4~Key15 的唯一入口）------------------------------
    wire [3:0] bright_lvl;      // Key6 亮度 0..9（**0 = 最亮**，与音量方向相反）
    wire [3:0] vol_lvl;         // Key7 音量 0..9（0 = 最轻 9.4%）
    wire [2:0] res_sel;         // Key8 分辨率 0..4（0→320x240 … 4→640x480）
    wire [2:0] ratio_sel;       // Key9 屏占比 0..4（窗口尺寸 + 居中偏移）
    wire       viz_en;          // Key10 音频可视化
    wire       audio_en_eff;    // Key4 生效值（应急强制 1）
    wire       ticker_en_eff;   // Key5 生效值（应急强制 1）
    // 下面 5 根在 P2_EN=1'b0 时恒 0/由 key_router 内部钳位，但**不要**改接常量：
    //   接常量会让将来把 P2_EN 打开时静默失效（改了开关却什么也没发生）。
    wire [2:0] pattern_sel;     // Key12 测试图案（P2_EN=0 → 恒 0）
    wire       rescan_req;      // Key11 图库重扫（P2_EN=0 → 恒 0）
    wire       invert_en;       // Key13 反色（P2_EN=0 → 恒 0）
    wire       grid_en;         // Key14 九宫格（P2_EN=0 → 恒 0）
    wire       beep_muted;      // Key15 蜂鸣器静音（P2_EN=0 → 恒 0）
    key_router #(
        .CLK_FREQ_HZ(25_000_000), .OSD_HOLD_MS(2500), .P2_EN(1'b0)
    ) u_keyrouter (
        .clk(clk_pixel), .rst_n(rst_n),
        .key_event(key_event), .key_code(key_code),
        .mode(mode),                            // 应急钳位用
        .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),
        .res_sel(res_sel), .ratio_sel(ratio_sel),
        .audio_en(), .ticker_en(),              // 被 _eff 取代，有意空连接
        .viz_en(viz_en),
        .osd_pop_req(), .osd_item(),            // osd_autopop 无此输入，有意空连接
        .audio_en_eff(audio_en_eff), .ticker_en_eff(ticker_en_eff),
        .rescan_req(rescan_req), .pattern_sel(pattern_sel),
        .invert_en(invert_en), .grid_en(grid_en), .beep_muted(beep_muted));

    // ---- key_action 删除后的三个无替身信号（附录 C 裁定，逐条有理由）---------
    //  key_action.v 原输出 9 个，key_router 只覆盖其中 6 个，剩 3 个这样定：
    //    auto_sw_sel[1:0] → 2'd0：轮播功能完整保留（AUTO_TICKS×1），只是倍率
    //                       不可调。降级项 D-02。
    //    info_en          → 1'b1：底部信息条常开，是赛规加分项 E4 的载体；
    //                       osd_autopop 已有 2.5 s 自动隐藏，不会常驻遮挡。
    //    level_en         → 1'b0：旧 KEY13 的"电平条→波形→关"4 态循环被
    //                       Key10 = viz_en 单管波形层取代，电平条无归属。D-03。
    wire [2:0] bright_sel = bright_lvl[2:0];  // 只用于信息条第 8/9/10 格
    wire [1:0] auto_sw_sel = 2'd0;            // D-02
    wire       info_en     = 1'b1;
    wire       level_en    = 1'b0;            // D-03
    wire       wave_en     = viz_en;          // Key10 音频可视化
    wire sd_ok, sd_fail;
    wire [3:0] probe_err;
    wire [4:0] img_index;
    wire [8:0] loader_index;
    wire switch_req, auto_play;
    // 图库张数来自扫描器（runtime 实测），不再是编译参数：
    //   固定接常量的话，现场换一批素材就得重新综合 —— 这正是本次切片要消除的。
    wire [4:0] gallery_count;
    wire       gallery_done;
    // ---------------------------------------------------------------------
    // player_ctrl 保留，但键事件被门控到 Key0/Key1（media_player 从未交付）
    // ---------------------------------------------------------------------
    // 【为什么不换掉它】ARCH.md 说 u_ctrl 要 1:1 换成 media_player，但该模块
    //   从未交付（全库无 media_player.v）。而 img_index / loader_index /
    //   switch_req / auto_play 这四个"图片什么时候换下一张"的唯一驱动源都在
    //   player_ctrl 里 —— 删掉它等于删掉整条轮播链路。
    // 【为什么门控 key_event 而不是屏蔽 key_code】player_ctrl 内部译码是
    //   `if (key_event && key_code == K_xxx)`，key_event 是最高层使能。
    //   把 key_event 按掉 = 这个键对它不存在，key_code 原样传下去。
    //   ★★ 绝不能用哨兵值改 key_code（例如"把不要的键改成 4'hF"）：
    //      key_code 是 [3:0]，0..15 全被 Key0~Key15 占满，4'hF == 4'd15 ==
    //      player_ctrl.K_EMERG。改成 4'hF 会让按 Key2/Key3 触发**应急直达**，
    //      而且仿真里看不出来（它也是一个合法的键事件）。
    // 【用户规格里没有播放/暂停键、没有轮播开关】所以 Key2/Key3/Key15 对
    //   player_ctrl 不是"被降级"，而是"按规格不该存在"。
    // 应急期是否再加上 && (mode != 2'd2) 门控：t7 决定不加（少一根跨模块线；
    //   应急时 content_mux 走 emerg_page，改 img_index 用户看不见）。
    wire key_event_media = key_event && (key_code == 4'd0 || key_code == 4'd1);
    player_ctrl #(.CLK_FREQ_HZ(25_000_000)) u_ctrl (
        .clk(clk_pixel), .rst_n(rst_n), .key_event(key_event_media), .key_code(key_code),
        .auto_sw_sel(auto_sw_sel),
        .gallery_count(gallery_count), .gallery_valid(gallery_done), .img_index(img_index),
        .loader_index(loader_index), .img_switch_req(switch_req), .auto_play_en(auto_play),
        .mode(), .status_led());          // mode 由 u_mode 唯一提供，此处有意空连接
    wire vs, de, vblank;
    wire [10:0] active_x; wire [9:0] active_y;
    // 注意：本版不再需要视频时序发生器给出 HS。带音频的 HDMI 1.4b 发射核自己
    // 按 HTOTAL/HSA/HFP/HBP 参数重建同步，外部只提供"帧起始 + 行内有效数据"，
    // 因此 HS 在这里没有消费者（保留端口空连接，参数仍在 video_timing_gen 内）。
    video_timing_gen u_vtg (.pixel_clk(clk_pixel), .rst_n(rst_n), .hs(), .vs(vs), .de(de),
        .active_x(active_x), .active_y(active_y), .frame_start(), .vblank(vblank));
    wire [7:0] pr, pg, pb;
    test_pattern_gen u_pat (.pixel_clk(clk_pixel), .rst_n(rst_n), .de(de),
        .active_x(active_x), .active_y(active_y), .pattern_sel(pattern_sel), .user_color(24'd0),
        .rgb_r(pr), .rgb_g(pg), .rgb_b(pb));
    // ---- 应急疏散图（取代 v1 的 science_page 静态科普页，t16 裁定）-----------
    // 四端口与 science_page 完全同款，平级替换：de/active_x/active_y → rgb_out。
    // ★ 它**不经** pix_mosaic / image_window_mask（应急必须全屏满分辨率），
    //   直接进 video_content_mux 的 mode==2 分支。
    // ★ `24'hFF_00_00`（v1 的整屏纯红）在全 rtl 只有一处，已随本次改造消失。
    wire [23:0] emerg_rgb;
    emerg_page u_emerg (
        .de(de), .active_x(active_x), .active_y(active_y), .rgb_out(emerg_rgb));

    // =========================================================================
    // AHT20 温湿度传感器链（i2c_master → aht20_ctrl → thermal_guard → mode_ctrl）
    // =========================================================================
    // 用户裁决：只用 AHT20 单传感器，NTC / Plan B 不实施。
    //
    // 三层职责严格分层，不能合并：
    //   i2c_master   只懂比特时序（START/STOP/字节/ACK），不懂 AHT20 的寄存器；
    //   aht20_ctrl   只懂 AHT20 的测量流程（触发 0xAC 0x33 0x00、等 80 ms、
    //                读 6 字节、CRC-8 校验、把原始值换算成 0.01℃ / 0.01%RH）；
    //   thermal_guard 只懂"温度超过阈值"这一条业务规则（含 5℃ 迟滞、
    //                2 s 数据失联自保），输出 oth_en 电平。
    //
    // 时钟域：全部在 clk_pixel（25 MHz）单域内，无跨域。
    //   i2c_master 的参数 CLK_FREQ_HZ 必须写 25_000_000 —— 写成 50M 会让
    //   SCL 实际跑 200 kHz，超出 AHT20 的 400 kHz 上限之外的时序裕量衰减。
    wire scl_oe, sda_oe, i2c_sda_in;
    wire i2c_start_req, i2c_start_done;
    wire i2c_stop_req,  i2c_stop_done;
    wire i2c_wr_req,    i2c_wr_done, i2c_wr_ack;
    wire [7:0] i2c_wr_data;
    wire i2c_rd_req,    i2c_rd_done, i2c_rd_nack;
    wire [7:0] i2c_rd_data;
    wire i2c_busy;

    i2c_master #(.CLK_FREQ_HZ(25_000_000), .SCL_FREQ_HZ(100_000)) u_i2c (
        .clk(clk_pixel), .rst_n(rst_n),
        .start_req(i2c_start_req), .start_done(i2c_start_done),
        .stop_req(i2c_stop_req),   .stop_done(i2c_stop_done),
        .wr_req(i2c_wr_req), .wr_data(i2c_wr_data), .wr_done(i2c_wr_done), .wr_ack(i2c_wr_ack),
        .rd_req(i2c_rd_req), .rd_nack(i2c_rd_nack), .rd_done(i2c_rd_done), .rd_data(i2c_rd_data),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_in(i2c_sda_in), .busy(i2c_busy));

    // 开漏三态（两条线都是"1 = 释放给上拉，0 = 主动拉低"）。
    // ★ 绝不能写成 assign i2c_scl = scl_oe; —— 那是推挽输出，
    //   oe=1 时驱动高电平，若器件正在拉低就是电源对地短路路径。
    assign i2c_scl    = scl_oe ? 1'bz : 1'b0;
    assign i2c_sda    = sda_oe ? 1'bz : 1'b0;
    // 回读必须取自**引脚本身的电压**，不能取 sda_oe：
    //   sda_oe 只是"我想释放"，而实际电平由对方（AHT20）决定。
    assign i2c_sda_in = i2c_sda;

    wire signed [15:0] temp_centi_c;      // 单位 0.01℃（例如 -1252 = -12.52℃）
    wire        temp_valid;
    wire [15:0] humid_centi;              // 单位 0.01 %RH
    wire        humid_valid;
    wire        cal_ok, sensor_ok, sensor_fault, sensor_busy, meas_tick;
    wire [3:0]  sensor_err;
    aht20_ctrl #(
        .CLK_FREQ_HZ(25_000_000),
        .POWERUP_CYCLES(2_500_000),       // 上电后等 100 ms 再通信
        .MEAS_WAIT_CYCLES(2_000_000),     // 测量等待 80 ms
        .RESET_WAIT_CYCLES(500_000),      // 软复位等待 20 ms
        .PERIOD_CYCLES(25_000_000),       // 每 1 s 测一次
        .RETRY_MAX(3),
        .DEV_ADDR(7'h38),
        .CMD_TRIGGER(8'hAC), .CMD_TRIG_P0(8'h33), .CMD_TRIG_P1(8'h00),
        .CMD_SOFT_RESET(8'hBE), .CRC_POLY(8'h31)
    ) u_aht20 (
        .clk(clk_pixel), .rst_n(rst_n),
        .i2c_start_req(i2c_start_req), .i2c_start_done(i2c_start_done),
        .i2c_stop_req(i2c_stop_req),   .i2c_stop_done(i2c_stop_done),
        .i2c_wr_req(i2c_wr_req), .i2c_wr_data(i2c_wr_data),
        .i2c_wr_done(i2c_wr_done), .i2c_wr_ack(i2c_wr_ack),
        .i2c_rd_req(i2c_rd_req), .i2c_rd_nack(i2c_rd_nack),
        .i2c_rd_done(i2c_rd_done), .i2c_rd_data(i2c_rd_data),
        .temp_centi_c(temp_centi_c), .temp_valid(temp_valid),
        .humid_centi(humid_centi),   .humid_valid(humid_valid),
        .cal_ok(cal_ok), .sensor_ok(sensor_ok),
        .err_code(sensor_err), .busy(sensor_busy),
        .sensor_fault(sensor_fault), .meas_tick(meas_tick));

    // 高温保护：阈值 45.00℃，迟滞 5℃（降到 40.00℃ 才退出），数据失联 2 s 自保。
    // ★ 阈值用 16'sd4500 而不是 45 —— 单位是 0.01℃。
    // ★ STALE_CYCLES = 50_000_000 即 25 MHz 下 2 s：AHT20 每 1 s 出一次数，
    //   连续 2 个周期没有任何 temp_valid 就判"数据失联"，此时**保持 oth_en 不变**
    //   （既不主动进应急也不主动退），避免传感器抖动导致画面反复闪切。
    thermal_guard #(
        .TH_HIGH(16'sd4500), .TH_LOW(16'sd4000), .STALE_CYCLES(50_000_000)
    ) u_thermal (
        .clk(clk_pixel), .rst_n(rst_n),
        .temp_centi_c(temp_centi_c), .temp_valid(temp_valid),
        .oth_en(temp_alarm),            // ★ 电平版，直接进 mode_ctrl
        .oth_enter(), .oth_exit(),      // 单拍沿，本设计无消费者
        .temp_alive());
    // ★★ 绝对禁令：`sensor_fault` 绝不能接到 `temp_alarm`。
    //   传感器坏 ≠ 着火。接了会让终端进应急并且**退不出来**：
    //   退出要等温度降到 TH_LOW，而传感器坏了根本不再出读数。
    //   "把屏幕锁死在应急画面"比"没有高温联动"严重得多。
    //   当前 sensor_fault 无消费者（降级项 D-04）；若 t10 要求上屏，
    //   正确做法是接 err_prompt 另开一路提示，而不是接 temp_alarm。

    // 启动阶段沿用已验证的 SD 探针；探针通过后先由 gallery_probe 枚举图库，
    // 枚举结束再把扇区服务独占交给图片链路 —— 三段严格串行。
    // 为什么必须串行而不是"同时都接上"：sd_spi_ctrl 只有一个读块端口，
    //   三方同时驱动 blk_start/blk_addr 就是多驱动，TD 会直接报错；
    //   而且扫描与装载并行会让 SD 事务交错，真卡上表现为 CRC 错误/超时。
    // 选择依据用"上一段是否已完成"，而不是用 sd_ok 这种持续电平：
    //   sd_ok 一旦拉高就一直为高，无法表达"该轮到下一段了"。
    wire init_start, init_done, init_fail;
    wire [3:0] sd_err;
    wire sd_busy, sd_blk_done, sd_blk_err, sd_dvalid;
    wire [7:0] sd_dbyte;
    wire probe_start, gallery_start, player_start;
    wire [31:0] probe_addr, gallery_addr, player_addr;
    // 扫描器输出先声明: 下面的仲裁要用 gallery_done / gallery_fail 判断该轮到谁。
    // （Verilog-2001 要求先声明后使用，声明顺序不能随意挪。）
    wire       gallery_fail, gallery_first_req;
    wire [3:0] gallery_err;
    // WAV 播放器的 SD 端口信号必须先声明：下面的仲裁要用 wav_want_blk /
    //   wav_blk_start / wav_blk_addr 判断该不该把总线让给音频。
    //   （Verilog-2001 先声明后使用；例化位置在音频段，离这里很远。）
    wire        wav_want_blk, wav_blk_start;
    wire [31:0] wav_blk_addr;
    // RLE 视频解码器同理：仲裁段要用它的电平请求与块地址做三选一。
    // 【t7-B：已换成 u_rle 的真实输出，不再钉常量】
    //   t7-A 阶段这三根是 `= 1'b0` / `= 32'd0` 的常量（因为 rle_decoder 尚未
    //   例化，只声明不驱动会变成 z，经 !rle_want_blk 传染成 x）。
    //   现在由 u_rle 驱动（例化在 gallery_probe 之后，Verilog-2001 允许先声明后使用）。
    wire        rle_want_blk;
    wire        rle_blk_start;
    wire [31:0] rle_blk_addr;
    // gallery_probe 的 SCI.RLE 四输出（例化在下方 :4xx，此处先声明：
    //   Verilog-2001 要求先声明后使用，而锁存块必须在仲裁段之前把值准备好）。
    wire [31:0] gallery_rle_lba, gallery_rle_size;
    wire        gallery_rle_found, gallery_rle_fail;

    // ------------------------------------------------------------------
    //  SCI.RLE 的存在性与起始扇区：必须**锁存**，不能直接拿 gallery 的组合值
    // ------------------------------------------------------------------
    //  【为什么不能直接把 gallery_rle_lba 送给 u_rle】
    //    gallery_probe.v:352-355 / :369-372 在 G_ARST 期间把 rle_lba / rle_size /
    //    rle_found / rle_fail **全部清 0**，而 rescan（Key11）会重新走一遍 G_ARST。
    //    若直接组合送，rescan 那一拍 u_rle 的 file_lba 会瞬间变 0 —— 于是它去读
    //    扇区 0（MBR），解出垃圾魔数，err_code=1，且**看起来像是「视频文件坏了」**。
    //    锁存 + `!rle_play_en` 门控之后，rescan 期间 u_rle 的 play_en 先掉 0，
    //    file_lba/file_size 保持旧值直到新值稳定，不存在「半路换源」的窗口。
    //
    //  【为什么用 rle_found 判存在性，而不是 lba==0】
    //    gallery_probe.v:130-135 的端口注释写死了这条：
    //      「上层必须靠这一位判断，不能靠『lba==0 就是没找到』—— 扇区 0 是合法值，
    //        用 0 当哨兵迟早出事」。
    //    「卡上没放 SCI.RLE」= rle_found=0 且 rle_fail=0，属**正常情形**
    //    （用户没放视频），此时 rle_play_en 保持 0，u_rle 不占总线、不上屏、
    //    不报错 —— 科普模式退化成「静态科普页 + 滚动字幕」，这是设计允许的。
    // ------------------------------------------------------------------
    reg        rle_lba_vld;      // 已锁存到一个有效的 SCI.RLE 起始扇区
    reg [31:0] rle_lba_q, rle_size_q;
    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            rle_lba_vld <= 1'b0;
            rle_lba_q   <= 32'd0;
            rle_size_q  <= 32'd0;
        end else if (rescan_req) begin
            // Key11 重扫：先作废旧值。下一次 gallery_done 会重新锁存。
            rle_lba_vld <= 1'b0;
            rle_lba_q   <= 32'd0;
            rle_size_q  <= 32'd0;
        end else if (gallery_done && gallery_rle_found && !gallery_rle_fail
                     && !rle_lba_vld) begin
            // 只在「扫描完成 + 确实找到 + 没有真故障 + 尚未锁存」的那一拍锁一次。
            // !rle_lba_vld 保证不会每拍重复写（gallery_done 是电平，会一直为 1）。
            rle_lba_vld <= 1'b1;
            rle_lba_q   <= gallery_rle_lba;
            rle_size_q  <= gallery_rle_size;
        end
    end

    // 视频解码器什么时候工作：
    //   ① 卡上有 SCI.RLE 且已锁存（rle_lba_vld）
    //   ② 当前是科普模式（mode==1）—— 日常模式播图库、应急模式播疏散图，
    //      视频只在科普模式出现（用户规格：科普 = 视频 + 中文字幕）
    //   ③ 图库扫描已经结束（总线已交给播放段；否则 sd_owner_playseg 还是 0，
    //      u_rle 会一直拉 want_blk 却永远等不到 grant —— 虽然不报错，
    //      但 want_blk 会持续压制 sd_owner_img，让图库播放饿死）
    wire rle_play_en = rle_lba_vld && m_science && (gallery_done || gallery_fail);
    // 仲裁: 探针未结束 → 探针；探针结束后扫描未结束 → 扫描器；否则 → 播放段
    // 【2026-10-31】三路归属显式互斥（独热），不再用"否则落到第三路"的三元级联：
    //   旧写法在 sd_ok=0 时把 player_start 静默丢弃并改路由 probe_start。
    //   现在每一路只在自己归属时才能驱动总线；不归属的请求由 image_player
    //   通过 sd_ready(=sd_owner_playseg) 复查自己退回 C_WAIT，不会再"发了没人收"。
    //
    // 【v2 新增：播放段内部再分 WAV 与图片两路】
    //   播放段原来只有 image_player 一个消费者。v2 加了 wav_stream_player
    //   （BGM/NARR/ALARM 三个 48 kHz 音频流），它也吃 SD 的读块服务。
    //   两者同时驱动 blk_start/blk_addr 就是多驱动 —— TD 直接报错还是好的，
    //   真卡上是 WAV 的扇区被当成 BMP 读进帧缓存（或反之），画面出现错位色块。
    //   优先级取「音频优先」：爆音比卡一帧难忍，且音频带宽只占 60% 余量。
    //   ★ 这是 t7-A 的临时两路形态。t7-B 还要把 rle_decoder 接成第三路，
    //     它已带 sd_grant 输入（§5 #2 裁定，rtl-storage 15:05 已落盘并跑过 tb），
    //     届时把上面三根 rle_* 常量换成 u_rle 的真实输出即可，仲裁逻辑不用改。
    wire        sd_owner_probe   = !sd_ok;
    wire        sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;
    // 播放段门（三条消费者共用）：v2 起改名为 playseg，
    //   因为「player」现在会同时指 BMP 那一路和整条媒体通路，容易读错。
    //   注意 u_player.sd_ready 接的是 sd_owner_playseg 而不是这一拍的总线归属。
    wire        sd_owner_playseg = sd_ok && (gallery_done || gallery_fail);
    // 播放段内部再三选一：WAV > RLE 视频 > BMP 图片。
    //   wav_want_blk / rle_want_blk 都是电平请求：
    //     WAV 在 FIFO 低水位时拉高，RLE 在"缺块或即将缺块"时提前拉高。
    //   优先级取「音频 > 视频 > 图片」，理由：
    //     · 音频欠载 = 爆音/断续，用户立刻听得见；
    //     · 视频欠载 = 卡一帧（200 ms 里丢一帧几乎看不出来，且 rle_decoder
    //       有 underrun 输出可作提示）；
    //     · 图片换页本来就有几百毫秒的装载窗口，最不急。
    //   带宽核算：@5 fps 视频 0.649 MB/s + 音频 0.096 MB/s = 0.745 MB/s，
    //   对实用 1.25 MB/s 有 60% 余量；且 rle 一帧只占 10~24 ms，
    //   200 ms 周期内其余时间总线全空，音频的 512 B 块（约 328 µs）随时插得进去。
    wire        sd_owner_wav     = sd_owner_playseg && wav_want_blk;
    wire        sd_owner_rle     = sd_owner_playseg && !wav_want_blk && rle_want_blk;
    wire        sd_owner_img     = sd_owner_playseg && !wav_want_blk && !rle_want_blk;
    // sd_grant 必须是**组合**给出、不打拍：打一拍会让 WAV/RLE 在被授权的那一拍
    //   看到 sd_grant=0 而不发 blk_start，授权窗口被静默跳过（块请求丢失）。
    //   这也是 rle_decoder 的 sd_grant 协议要求：blk_start 与 blk_addr 必须在
    //   同一拍被同一条件门控，否则会把别人的扇区当自己的数据解码（静默错帧）。
    wire        sd_grant_wav     = sd_owner_wav;
    wire        sd_grant_rle     = sd_owner_rle;
    wire        sd_arb_start     = (sd_owner_probe   & probe_start)
                                 | (sd_owner_gallery & gallery_start)
                                 | (sd_owner_wav     & wav_blk_start)
                                 | (sd_owner_rle     & rle_blk_start)
                                 | (sd_owner_img     & player_start);
    wire [31:0] sd_arb_addr      = ({32{sd_owner_probe}}   & probe_addr)
                                 | ({32{sd_owner_gallery}} & gallery_addr)
                                 | ({32{sd_owner_wav}}     & wav_blk_addr)
                                 | ({32{sd_owner_rle}}     & rle_blk_addr)
                                 | ({32{sd_owner_img}}     & player_addr);
    // WAV 侧"SD 卡已初始化完成"：只要探针过了就允许它发起定位。
    //   注意不能接 sd_ok 以外的条件 —— audio_src_mux 用它决定要不要发 src_start。
    wire        sd_ready_audio   = sd_ok;
    sd_spi_ctrl #(.CLK_FREQ_HZ(25_000_000)) u_sd (
        .clk(clk_pixel), .rst_n(rst_n), .init_start(init_start), .init_done(init_done),
        .init_fail(init_fail), .err_code(sd_err), .blk_start(sd_arb_start),
        .blk_addr(sd_arb_addr), .blk_busy(sd_busy),
        .blk_done(sd_blk_done), .blk_err(sd_blk_err), .data_byte(sd_dbyte), .data_valid(sd_dvalid),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso));
    sd_probe #(.CLK_FREQ_HZ(25_000_000), .PROBE_DELAY_CYCLES(200_000)) u_probe (
        .clk(clk_pixel), .rst_n(rst_n), .init_start(init_start), .init_done(init_done),
        .init_fail(init_fail), .err_code(sd_err), .blk_start(probe_start), .blk_addr(probe_addr),
        .blk_busy(sd_busy), .blk_done(sd_blk_done), .blk_err(sd_blk_err),
        .data_byte(sd_dbyte), .data_valid(sd_dvalid), .sd_ok(sd_ok), .sd_fail(sd_fail), .err_latch(probe_err));
    // 图库自动扫描: sd_ok 上升沿启动，枚举根目录里 IMG001.BMP 起的连续素材，
    // 输出张数（0..31）与"图库就绪"标志，替换掉原先写死的 GALLERY_COUNT。
    // 注意 gallery_fail / gallery_err / gallery_first_req 的声明在仲裁段之前
    // （上面已声明），此处只做例化。
    gallery_probe #(.CLK_FREQ_HZ(25_000_000), .MAX_COUNT(5'd31)) u_gallery (
        .clk(clk_pixel), .rst_n(rst_n), .sd_ok(sd_ok), .rescan(rescan_req),
        .blk_start(gallery_start), .blk_addr(gallery_addr),
        .blk_done(sd_blk_done), .blk_err(sd_blk_err),
        .data_byte(sd_dbyte), .data_valid(sd_dvalid),
        .done(gallery_done), .fail(gallery_fail), .count(gallery_count),
        .first_img_req(gallery_first_req), .err_code(gallery_err),
        // 【t7-B 接上】SCI.RLE 的存在性与几何（gallery_probe.v:130-135）
        //   四根都是电平、都保持到复位或 rescan；顶层在上面的锁存块里消费。
        .rle_lba(gallery_rle_lba), .rle_size(gallery_rle_size),
        .rle_found(gallery_rle_found), .rle_fail(gallery_rle_fail));

    // ------------------------------------------------------------------
    //  科普视频解码器（RLE 帧直写帧缓存）
    // ------------------------------------------------------------------
    //  【数据通路】SD 块 → data_byte/data_valid → 解码 → ext_wr_* → image_player
    //    image_player 的 ext_* 外部写口在 ext_wr_mode=1 时接管 framebuf 写通道，
    //    把解码出的帧直接写进后台缓冲；换帧仍由 vblank_rise 统一提交（两路共用
    //    同一套翻页逻辑，不存在「视频帧与图片帧抢翻页」的窗口）。
    //
    //  【ext_no_fade 必须接 1（= rle_play_en）】
    //    image_player.v:578-579 `wire [7:0] fade_level = ext_no_fade ? 8'hFF : fade_alpha;`
    //    视频 5 fps 若走淡入淡出，每帧都要淡出到黑再淡入，帧率会被压成
    //    1/FADE_FRAMES —— 现象是「视频像幻灯片，每帧闪一下黑」。图片模式不受影响。
    //
    //  【sd_grant 必须组合、不打拍】
    //    rle_decoder.v:307-317 有长注释解释：blk_start 与 blk_addr 必须在同一拍
    //    被同一条件门控，否则会把别人的扇区当自己的数据解码（静默错帧）。
    //    sd_grant_rle 就是上面仲裁段那个组合式 sd_owner_rle，中间不能插寄存器。
    //
    //  【已知风险（不在本层修，登记备查）】
    //    blk_done / blk_err 是 sd_spi_ctrl 对所有消费者的**广播**。rle_decoder 在
    //    R_NEXT_BLK 等 grant 时若别人的块恰好完成，`if (blk_done)` 没有 req_sent
    //    门控（rle_decoder.v:681），会误认为自己的块到了。tb_rle_decoder 把
    //    sd_grant 恒接 1，所以没暴露。真正多路并发时理论上存在这个窗口。
    //    缓解：rle_play_en 只在科普模式为 1，而科普模式下 WAV 仍在播 BGM，
    //    所以 wav 抢到总线的机会是存在的 —— 这条要靠 t9 上板跑视频 + BGM 复核。
    // ------------------------------------------------------------------
    wire [15:0] rle_frame_idx;
    wire        rle_frame_ready;
    wire        rle_ext_wr_valid, rle_ext_wr_done, rle_ext_wr_ack, rle_ext_wr_busy;
    wire [20:0] rle_ext_wr_addr;
    wire [31:0] rle_ext_wr_data;
    wire [3:0]  rle_ext_wr_dm;
    wire [3:0]  rle_err_code;
    wire        rle_underrun;
    rle_decoder #(
        .CLK_FREQ_HZ(25_000_000), .FRAME_W(16'd640), .FRAME_H(16'd480),
        .JITTER_FRAMES(8'd3), .INIT_WR_BANK(1'b1), .LOOP_PLAY(1'b1), .BLK_BYTES(16'd512)
    ) u_rle (
        .clk(clk_pixel), .rst_n(rst_n),
        .blk_start(rle_blk_start), .blk_addr(rle_blk_addr),
        .blk_busy(sd_busy), .blk_done(sd_blk_done), .blk_err(sd_blk_err),
        .data_byte(sd_dbyte), .data_valid(sd_dvalid),
        .sd_grant(sd_grant_rle),                 // 组合，见上方注释
        .play_en(rle_play_en), .play_fps(8'd5),  // 视频 5 fps（用户规格）
        .file_lba(rle_lba_q), .file_size(rle_size_q),   // 锁存值，不是 gallery 组合值
        .frame_idx(rle_frame_idx),
        .ext_wr_done(rle_ext_wr_done), .ext_wr_valid(rle_ext_wr_valid),
        .ext_wr_addr(rle_ext_wr_addr), .ext_wr_data(rle_ext_wr_data),
        .ext_wr_dm(rle_ext_wr_dm),
        .ext_wr_ack(rle_ext_wr_ack), .ext_wr_busy(rle_ext_wr_busy),
        .err_code(rle_err_code), .underrun(rle_underrun),
        .want_blk(rle_want_blk));

    wire [15:0] image565;
    wire image_pixel_valid, image_ready, image_loading, image_failed;
    wire [3:0] image_error;
    wire [2:0] reader_status;
    // "曾经有过一帧有效图片"的粘滞标志（复位后一直保持 1）。
    // 用途：区分"上电还没出过图"（可以显示测试彩条）与"显示过图后 image_ready
    // 掉下来"（存储故障退帧/重装载窗口，必须出黑）。image_ready 一旦被故障
    // 清零，mux 若回落测试彩条，pattern_sel=0 的八色彩条第 0 条正是纯白
    // 24'hFF_FFFF（占 x∈[0,79]），上屏就是一条 80 像素宽的竖向白条。
    reg image_ever_ready;
    always @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) image_ever_ready <= 1'b0;
        else if (image_ready) image_ever_ready <= 1'b1;
    end
    // ------------------------------------------------------------------
    //  Key9 五档屏占比：ratio_map 查表 → 四个几何参数（t7-B 新增）
    // ------------------------------------------------------------------
    //  【为什么不是「一个模块一个消费者」而是「一组信号两个消费者」】
    //    ratio_map 的四个输出有两处消费者，且**必须是同一组信号**：
    //      ① image_window_mask.win_*  —— 位置门控（窗口外的有效位强制清零）
    //      ② image_player.win_*       —— 采样范围（pix_reader 的窗口内降采样）
    //    两处接成不同来源（例如一路接 ratio_map、另一路仍接 img_scaler 的
    //    out_w/out_h）会让「窗口画在哪」与「从哪儿取像素」错位 ——
    //    现象是画面被切掉一半，**综合、仿真、上板都不报任何错**。
    //    所以这里用中间 wire（k9_win_*）分别接两家，而不是把 u_ratio.win_w
    //    直接连到两个例化点上：将来有人只改一处时，中间这层会让他先看到。
    //
    //  【位宽：为什么必须显式补零】
    //    ratio_map 输出 win_w[10:0] / win_h[9:0] / win_off_x[10:0] / win_off_y[9:0]
    //    （640 / 480 都在 11 位 / 10 位以内，这是它的自然宽度）；
    //    而 image_window_mask 与 image_player 的 win_* 四个端口都是 [15:0]。
    //    Verilog 的端口位宽不匹配是**警告不是错误** —— 名字对、位宽错，
    //    vlog / elaborate / check_port_names 三关全绿。显式补零让位宽在源码里
    //    可数（{5'd0,...} 是 11→16，{6'd0,...} 是 10→16）。
    //
    //  【应急钳位为什么在顶层做，不写进 ratio_map】
    //    ratio_map.v:49-63 的接口约定：本模块不引 disp_mode 端口，钳位由顶层
    //    给出 ratio_sel_eff。档 4 的查表结果正是 640x480@(0,0)，所以钳到 3'd4
    //    就等于「强制全屏」；且**不改写 ratio_sel 寄存器** —— 退出应急后
    //    用户原先选的档位立刻恢复，不需要另存一份。
    //    （应急画面本身由 emerg_page 从 video_content_mux 的 2'd2 注入，
    //      不经过 image_window_mask，所以这条钳位只影响「退回日常/科普时」的几何。）
    // ------------------------------------------------------------------
    wire [10:0] rm_win_w, rm_win_off_x;
    wire [9:0]  rm_win_h, rm_win_off_y;
    wire [2:0]  ratio_sel_eff = (mode == 2'd2) ? 3'd4 : ratio_sel;
    ratio_map u_ratio (
        .ratio_sel(ratio_sel_eff),
        .win_w(rm_win_w), .win_h(rm_win_h),
        .win_off_x(rm_win_off_x), .win_off_y(rm_win_off_y));
    wire [15:0] k9_win_w     = {5'd0, rm_win_w};
    wire [15:0] k9_win_h     = {6'd0, rm_win_h};
    wire [15:0] k9_win_off_x = {5'd0, rm_win_off_x};
    wire [15:0] k9_win_off_y = {6'd0, rm_win_off_y};
    wire sdram_clk_w, sdram_cke_w, sdram_cs_n_w, sdram_ras_n_w, sdram_cas_n_w, sdram_we_n_w;
    wire [1:0] sdram_ba_w; wire [10:0] sdram_addr_w;
    wire [3:0] sdram_dm_w; wire [31:0] sdram_dq_w;
    // 首图装载: player_ctrl 复位后 img_index=0、loader_index=1，但它不会自己发
    // img_switch_req（见 player_ctrl 文件头【五】"上电首图"），必须由顶层补一个
    // 请求脉冲。gallery_first_req 正是"图库扫描完成且至少有 1 张"时的那一拍，
    // 用它接 load_req 比另做上电脉冲发生器更准 —— 它保证请求发出时卡里确实有图，
    // 且扫描用的 SD 事务已经全部结束（不会与装载抢总线）。
    wire player_load_req = switch_req || gallery_first_req;
    // ------------------------------------------------------------------
    //  【2026-10-28 修复】sd_ready 必须接播放段门（今称 sd_owner_playseg），不能接 sd_ok
    // ------------------------------------------------------------------
    //  故障现象: 上板后数码管稳定显示 d810（image_err=9 装载超时），
    //            LED D4/D5/D7 亮、D6(装载中) 灭。
    //
    //  根因链条：
    //    ① image_player 的 C_WAIT 只看 sd_ready && !blk_busy，**不看 load_req**
    //       （image_player.v:159，历史 image_dm_fix 版本同样如此）。
    //    ② 顶层原来把 .sd_ready 接成 sd_ok。sd_ok 在探针成功那一刻就拉高，
    //       但此时 gallery_probe 才刚开始扫描，sd_owner_gallery = 1。
    //    ③ 于是 image_player 在 sd_ok 后约 20 拍就冲进 C_LOAD，img_loader
    //       发出单拍 blk_start；而仲裁器 sd_arb_start 此刻选的是
    //       gallery_start —— 播放器的请求被**直接丢弃**，从未到达 sd_spi_ctrl。
    //    ④ img_loader 在 T_FATRD/T_DATRD 只等 blk_done，没有任何超时，
    //       且不会重发请求 → 永久挂死。
    //    ⑤ 4 秒后 image_player 的 LOAD_TIMEOUT 兜底，报 error_code=9 → 显示 d8。
    //
    //  为什么 image_dm_fix 诊断工程能出图: 它没有 gallery_probe，
    //  sd_owner_gallery 恒为 0，播放器从一上电就独占总线，竞态不存在。
    //
    //  sd_owner_playseg = sd_ok && (gallery_done || gallery_fail)，
    //  正好表达「图库扫描已完结、总线已归播放器」。用它做 sd_ready，
    //  播放器就会一直停在 C_WAIT 直到真正拿到总线，请求不会再被吞。
    // ------------------------------------------------------------------
    // 【v2 新增 src_w / src_h —— 这两根不能漏】
    //   image_player 内部 pix_reader 的行映射要按"源图逻辑尺寸"算：
    //     `src_ok = (src_w != 0) && (src_h != 0) && (src_h <= FRAME_LINES16)`
    //   悬空 = z → 判假 → `map_ident` 变 x → 整条行映射 x 传播 → 上板错行。
    //   这里接 640/480（BMP 原生尺寸），map_ident 成立走恒等旁路，
    //   等价于改造前的行为。科普视频同样是 640×480，所以这一个常量两处通用。
    //   ★ 绝不能把 img_scaler 的 scale_w/scale_h 接进来：那是"缩放后目标宽"，
    //     语义完全不同，接错会让 Key8 的抽样比整体算错（且不报错）。
    // 【v2 的 ext_* 外部写口】
    //   t7-A 全部不启用（ext_wr_mode = 0 → 其余端口一律无作用），
    //   视频直写通路要等 rle_decoder 在 t7-B 接上。
    image_player u_player (
        .pix_clk(clk_pixel), .rst_n_pix(rst_n), .sdr_clk(clk_sdr), .sdr_clk_sft(clk_sdr_sft),
        .rst_n_sdr(rst_sync_sdr[2]), .sd_ready(sd_owner_playseg), .sd_failed(sd_fail), .blk_busy(sd_busy),
        .load_req(player_load_req), .image_index(loader_index), .blk_start(player_start), .blk_addr(player_addr),
        .blk_done(sd_blk_done), .blk_err(sd_blk_err), .data_byte(sd_dbyte), .data_valid(sd_dvalid),
        .de(de), .scan_y(vblank ? 10'd480 : active_y), .rgb565(image565), .pixel_valid(image_pixel_valid),
        // 【t7-B】out_* 四个端口在本层已无消费者（Key9 改由 ratio_map 驱动
        //   image_window_mask 与 pix_reader），按 T1_TO_T7_WIRING.md §1.3 的裁定
        //   保留端口、本层空连接 —— 不删端口（那是 t4/storage 的域）。
        //   这四处空连接已登记进 scripts/check_port_names.py 的 EXPECTED_EMPTY，
        //   理由必须写在这里：将来若有人把它们接回去，白名单与代码会同时提醒。
        .out_w(), .out_h(), .out_off_x(), .out_off_y(),
        // 【t7-B】Key9 五根：窗口矩形 + 本拍列坐标。
        //   ★ 这四根与上面 u_image_mask 的 win_* 是**同一组 wire**（k9_win_*）。
        //   ★ active_x 必须接 video_timing_gen 的 active_x（与 de 同拍的真列号），
        //     绝不能接常量 0 —— 接 0 会让 pix_reader 内部的 map_key9_ident 恒真、
        //     win_bad 判据失真，Key9 按下去画面不变，但**综合告警全部消失、
        //     check_port_names.py 也 PASS**（名字对、位宽对、不是空括号）。
        //     这是本项目最阴的一条：告警消失了、功能也没了。
        .win_w(k9_win_w), .win_h(k9_win_h),
        .win_off_x(k9_win_off_x), .win_off_y(k9_win_off_y),
        .active_x(active_x),
        .image_ready(image_ready), .loading(image_loading), .failed(image_failed), .error_code(image_error),
        .reader_status(reader_status), .sdram_clk(sdram_clk_w), .sdram_cke(sdram_cke_w),
        .sdram_cs_n(sdram_cs_n_w), .sdram_ras_n(sdram_ras_n_w), .sdram_cas_n(sdram_cas_n_w),
        .sdram_we_n(sdram_we_n_w), .sdram_ba(sdram_ba_w), .sdram_addr(sdram_addr_w),
        .sdram_dm(sdram_dm_w), .sdram_dq(sdram_dq_w),
        .src_w(16'd640), .src_h(16'd480),
        // 【t7-B】外部写口从「全部禁用」改成接 u_rle 的真实输出。
        //   ext_wr_mode = rle_play_en（电平）：科普模式 + 卡上有 SCI.RLE 时才接管。
        //   image_player.v:166 `bmp_load_req = load_req && !ext_wr_mode` ——
        //   ext_wr_mode=1 时 BMP 装载请求被冻结，两路不会同时写 framebuf。
        //   ★ 切模式当拍写口就切换：若切出科普时 rle 正在写半帧，那半帧留在后台
        //     缓冲里，但前台已经换成图库画面，用户看不见 —— 可接受，不需要额外
        //     的「等帧写完再切」握手（那会引入一个跨模块的状态锁）。
        .ext_wr_mode(rle_play_en),
        .ext_wr_valid(rle_ext_wr_valid), .ext_wr_addr(rle_ext_wr_addr),
        .ext_wr_data(rle_ext_wr_data), .ext_wr_dm(rle_ext_wr_dm),
        .ext_wr_done(rle_ext_wr_done), .ext_no_fade(rle_play_en),
        .ext_wr_ack(rle_ext_wr_ack), .ext_wr_busy(rle_ext_wr_busy),
        .ext_frame_ready(rle_frame_ready),
        .ext_frame_sel(),                   // 2 位 output，本层无消费者，有意空连接
        .ext_loader_want_blk());
    // SiP SDRAM 在 FPGA 封装内部，不增加板级 SDRAM IO。
    EG_PHY_SDRAM_2M_32 u_sdram_sip (
        .clk(sdram_clk_w), .ras_n(sdram_ras_n_w), .cas_n(sdram_cas_n_w), .we_n(sdram_we_n_w),
        .addr(sdram_addr_w), .ba(sdram_ba_w), .dq(sdram_dq_w), .cs_n(sdram_cs_n_w),
        .dm0(sdram_dm_w[0]), .dm1(sdram_dm_w[1]), .dm2(sdram_dm_w[2]), .dm3(sdram_dm_w[3]), .cke(sdram_cke_w));
    // ------------------------------------------------------------------
    // Key8 分辨率档 → 抽样源宽（res_sel 的消费者，别让它悬空）
    // ------------------------------------------------------------------
    // 五档与 KEYMAP.md §9.3 一致：0→320×240 / 1→400×300 / 2→512×384
    //   3→576×432 / 4（默认）→640×480（不抽样）。
    // 为什么用 src_w 而不用 win_w：pix_mosaic 做的是**列抽样**（每 src_w/640 个
    //   源像素取一个），它要知道"源图逻辑宽度"；窗口位置/尺寸是 image_window_mask
    //   的职责（Key9 的 ratio_map→win_*），两条支路并联、互不从属。
    reg [15:0] res_src_w;
    always @(*) begin
        case (res_sel)
            3'd0:    res_src_w = 16'd320;
            3'd1:    res_src_w = 16'd400;
            3'd2:    res_src_w = 16'd512;
            3'd3:    res_src_w = 16'd576;
            default: res_src_w = 16'd640;
        endcase
    end

    // ------------------------------------------------------------------
    //  列抽样（Key8）：640 像素一行按比例抽稀，等价"降低横向分辨率"
    // ------------------------------------------------------------------
    // 【为什么 valid_in 必须接 image_pixel_valid（u_player.pixel_valid）】
    //   接 image_window_mask.pixel_valid_out 会构成组合自环：
    //   pix_mosaic.valid_in ← mask.pixel_valid_out ← mask.pixel_valid ← player…
    //   而 mask 的判决又依赖 active_x，vlog 不报错、波形上看着"也有输出"，
    //   实际是振荡。这是 T1_GEOM.md §6.1 明确记过的坑。
    // 【为什么和 image_window_mask 是并联不是串联】
    //   pix_mosaic 处理的是**像素内容**（16 位 RGB565），image_window_mask 处理
    //   的是**1 位有效位**（窗口位置门控）。两者没有上下游关系：先抽样后门控、
    //   先门控后抽样都对，但都不能把对方的输出当输入（后者根本没有像素端口）。
    // 【src_w 帧中变化是可接受的】
    //   按 Key8 的那一刻若正好在行中间，当前行会有一个相位跳变，下一行起正确。
    //   640→320 的抽样比是 1/2，肉眼在静止图上能看出半行，运动画面不可见。
    wire [15:0] img_pix565;
    wire        img_pix_valid;
    pix_mosaic u_mosaic (
        .clk(clk_pixel), .rst_n(rst_n),
        .active_x(active_x), .src_w(res_src_w),
        .rgb565_in(image565), .valid_in(image_pixel_valid),
        .rgb565_out(img_pix565), .valid_out(img_pix_valid));

    // RGB565 位复制扩展回 RGB888，与 de 同拍。
    // ★ 输入源是 pix_mosaic 抽样后的 img_pix565，不是 image_player 的原始 image565。
    //   pix_mosaic 会把一个源像素保持住若干拍（列抽样），这里再展成 888。
    wire [23:0] image888 = {img_pix565[15:11],img_pix565[15:13],img_pix565[10:5],img_pix565[10:9],
                           img_pix565[4:0],img_pix565[4:2]};
    // ------------------------------------------------------------------
    //  letterbox 屏蔽：把缩放窗口外的像素强制为黑
    // ------------------------------------------------------------------
    //  img_scaler 只输出目标窗口（out_w×out_h，左上角在 out_off_x/out_off_y）
    //  内的像素，帧缓存其余区域保持上一帧的旧内容。若不在这里屏蔽，缩小后的
    //  图片四周会漏出前一张图的黑边/残影。
    //  active_x/active_y 是像素时序发生器的行内/行间计数，与 de 同拍有效，
    //  正好是当前像素的绝对坐标；vblank 期 scan_y 已被顶层钳到 480，
    //  image_pixel_valid 此时必为 0，无需额外处理。
    //  屏蔽逻辑单独成模块，便于在 tb_image_window_mask 里逐点验证边界。
    wire image_pixel_shown;
    image_window_mask u_image_mask (
        .de(de), .active_x(active_x), .active_y(active_y),
        // 【t7-B】改接 Key9 的 ratio_map 档位窗口（原来接 img_scaler 的 out_*）。
        //   语义变化是**有意的**：原来是「每张 BMP 按自身尺寸居中 letterbox」，
        //   现在是「Key9 五档固定窗口」。t1 裁决把 Key9 落在 pix_reader 消费侧
        //   降采样（而不是在 img_scaler 里预缩放），所以位置门控必须跟采样范围
        //   用同一组档位值，否则两者错位（见上方 ratio_map 注释块）。
        .win_w(k9_win_w), .win_h(k9_win_h),
        .win_off_x(k9_win_off_x), .win_off_y(k9_win_off_y),
        .pixel_valid(image_pixel_valid), .pixel_valid_out(image_pixel_shown));
    wire [23:0] video_base;
    video_content_mux u_content_mux (
        .de(de), .mode(mode), .image_ready(image_ready),
        .image_ever_ready(image_ever_ready),
        .image_pixel_valid(image_pixel_shown), .image_rgb(image888),
        .pattern_rgb({pr,pg,pb}), .emerg_rgb(emerg_rgb), .rgb_out(video_base));
    // video_rgb_ovl = 经 video_overlay 做亮度/反色/OSD 叠加后的像素。
    // video_rgb     = 再经 osd_panel 叠加"参数面板"后的最终上屏像素。
    // 两级分开命名，是为了让"面板覆盖一切已有图层"这件事在连线上一目了然：
    // osd_panel 吃 video_rgb_ovl、吐 video_rgb，中间的优先级不需要读注释。
    wire [23:0] video_rgb_ovl;
    wire [23:0] video_rgb;
    // "资源不可用"的合并语义提前到这里：音频的播放状态与 LED 都要用它。
    wire sd_or_gallery_fail = sd_fail || gallery_fail;

    // =========================================================================
    // HDMI 1.4b 视频 + 音频发射链路
    // -------------------------------------------------------------------------
    // 【为什么必须换核，而不是给原来的核加音频】
    //   原来的 hdmi_tx.vhd 内部只是 Anlogic DVITransmitter 加密核的端口映射，
    //   该核实体只有 PCLK / 5xPCLK / HS / VS / DE / RGB / 4 条 TMDS —— 没有任何
    //   音频入口。DVI 协议本身也没有音频位置（音频走 HDMI 的数据岛期），所以
    //   "在 DVI 上叠音频"在协议层就不成立。带音频的发射核是 HDMI 1.4b 核。
    //
    // 【音频为什么不需要第二颗 PLL / 不做 I2S 回环】
    //   APUG092 文档明确：HDMI1.4b Transmitter Core 的 EDID / Video / Audio / ACR
    //   四个接口**全部工作在 Pixel Clock 域**。参考例程之所以接 12.288 MHz 的
    //   audio_mclk 并串一层 I2S 收发，是为了"演示 I2S 输入"这个接口形态，不是核的
    //   硬性要求。本工程直接把 48 kHz 样本在 clk_pixel 域给出，省掉一颗 PLL
    //   （EG4S20 只有 4 个 PLL，已用 2 个）与一整套跨域逻辑，风险面更小。
    //
    // 【EDID / DDC 的处理（如实声明）】
    //   本板 HDMI 座只引出 4 对 TMDS，没有把 DDC 的 SCL/SDA 接到 FPGA（依据：
    //   EG4S20_综合底板.pdf 的 HDMI 区块、板卡和引脚说明.pdf 3.3 节，
    //   以及参考工程 pin.adc 里 DDC 落在 P2/R2 而本板这两球并非 DDC）。
    //   因此本工程**不做 EDID 协商**：I_edid_read_trig 恒 0（从不发起读），
    //   核的 IIC master 输出悬空。核的视频/音频参数全部由例化参数静态给出，
    //   这与 APUG092 文档"EDID 读取是可选的显式动作"一致。
    //
    // 【TMDS 通道映射】
    //   ch0=蓝→D0、ch1=绿→D1、ch2=红→D2、clk→CLK（与参考例程的连接一一对应）。
    // =========================================================================
    wire [9:0]  tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;
    wire        video_user, video_valid, video_last;
    wire [23:0] video_data;
    wire        hdmi_video_locked;

    video_rgb_to_axis #(.H_ACTIVE(640)) u_axis (
        .clk(clk_pixel), .rst_n(rst_n), .vs(vs), .de(de), .rgb(video_rgb),
        .video_user(video_user), .video_valid(video_valid),
        .video_last(video_last), .video_data(video_data));

    // ---- 音频源：48 kHz / 24 bit PCM --------------------------------------
    // 拓扑（v2）：
    //   wav_stream_player u_wav ──sample_valid/sample_l──┐
    //                                                    ├─► 样本级 mux ─► vol_apply ─► 四消费者
    //   audio_tone_gen     u_tone ──audio_valid/left─────┘        ▲           ▲
    //                                                    wav.playing    vol_lvl[3:0]
    //
    // 【样本级 mux 为什么必须在顶层写】
    //   audio_src_mux.v 是**控制信号发生器**，它的端口里零个样本端口（只有
    //   src_sel / src_name / src_start / eff_audio_en）。ARCH.md:654-671 伪码里
    //   那个「WAV 未就绪 → 降级 tone_gen」的判决在实现里根本不存在。
    //   不补这三行，WAV 播放器就没有任何样本被送出（它接不出消费者）。
    //
    // 播放状态编码与 audio_tone_gen 内部的 localparam 一一对应，改一处必须改两处。
    localparam [2:0] ST_IDLE  = 3'd0;
    localparam [2:0] ST_SCAN  = 3'd1;
    localparam [2:0] ST_LOAD  = 3'd2;
    localparam [2:0] ST_READY = 3'd3;
    localparam [2:0] ST_AUTO  = 3'd4;
    localparam [2:0] ST_EMERG = 3'd5;
    localparam [2:0] ST_FAIL  = 3'd6;
    // =====================================================================
    // 播放状态机 —— 标准三段式有限状态机（FSM）
    // ---------------------------------------------------------------------
    // 改造前：单 always 内的优先级 if-else 链，状态量本身就是被赋值的寄存器，
    //         没有独立的次态信号 —— 属于「隐式 FSM」。
    // 改造后：严格按三段式拆分，形式与 pix_reader.v / framebuf_arbiter.v 一致。
    //
    //   第①段 状态寄存器  —— 只做 state <= next_state，不含任何判断逻辑
    //   第②段 次态组合逻辑 —— 只算 next_state，不写任何寄存器
    //   第③段 输出         —— 本模块的状态本身就是输出（Moore 型），
    //                         由 playback_state 直接驱动，无需额外输出段
    //
    // 【语义说明·必须看懂这一点】
    //   本 FSM 是 **Moore 型 + 全局事件优先级译码**：七个状态恰好对应七种
    //   "此刻系统最该处于的状态"，任意时刻的次态由当前输入唯一确定，
    //   存在完整的 else 兜底（→ ST_IDLE），因此**没有状态保持语义**。
    //   换言之 next_state 不依赖当前 state，只依赖输入 —— 这不是缺陷，
    //   而是"状态 = 事件优先级编码器"的正确实现：优先级排他，永远只有一个
    //   状态成立。把它写成三段式是为了：
    //     · 状态迁移与状态寄存彻底分离，加"保持型"迁移时只改第②段；
    //     · 次态可被波形/断言直接观测（playback_next），便于调试。
    //
    //   优先级（从上到下短路，顺序即业务优先级）：
    //     故障 > 应急 > 扫描 > 装载 > 轮播 > 就绪 > 空闲
    //   故障排最前是因为"没卡/没图"时最该先听见静音，其余几种都只是过程态。
    // =====================================================================

    // ---- 第①段：状态寄存器（唯一的时序逻辑，只搬运次态）-----------------
    reg [2:0] playback_state;   // 现态（对外保持原名/原位宽，下游与测试台均引用它）
    reg [2:0] playback_next;    // 次态（组合产生）
    always @(posedge clk_pixel or negedge rst_n) begin
        if(!rst_n) playback_state <= ST_IDLE;
        else       playback_state <= playback_next;
    end

    // ---- 第②段：次态组合逻辑（只做判断，不写寄存器）---------------------
    //   默认值先给 `playback_next = ST_IDLE`：既有 else 兜底，也给仿真器一个
    //   确定的初值，避免组合环告警。
    always @(*) begin
        playback_next = ST_IDLE;                       // 默认/兜底：空闲
        if(sd_or_gallery_fail || image_failed)
            playback_next = ST_FAIL;                   // 1. 故障最高优先
        else if(mode == 2)
            playback_next = ST_EMERG;                  // 2. 应急（模式 2 = MODE_EMERG）
        else if(sd_ok && !gallery_done)
            playback_next = ST_SCAN;                   // 3. 图库扫描中
        else if(image_loading)
            playback_next = ST_LOAD;                   // 4. 图片装载中
        else if(image_ready && auto_play)
            playback_next = ST_AUTO;                   // 5. 自动轮播中
        else if(image_ready)
            playback_next = ST_READY;                  // 6. 就绪待命
        // 7. 其余 → ST_IDLE（已由默认值给出，此处不重复赋值）
    end

    // ---- 第③段：输出段 ---------------------------------------------------
    //   Moore 型：输出只由现态决定，故无需独立逻辑；playback_state 本身
    //   已经是一个寄存器输出，直接供 audio_tone_gen 与状态显示使用。

    // ---------------------------------------------------------------------
    // 音频链 v2：tone_gen / wav_player → 样本 mux → vol_apply → 四个消费者
    // ---------------------------------------------------------------------
    // 【v1 → v2 变化】
    //   v1：`key_code==6` 直连翻转 audio_muted（本层自己消费 Key6），
    //       然后 audio_tone_gen 的 valid/left/right 直接送给四个消费者。
    //   v2：Key4 = 音频开关、Key7 = 音量，全部由 key_router 译码；本层不再有
    //       audio_muted 寄存器（删掉它 = 删掉 Key6 的第二个消费者）。
    // ---------------------------------------------------------------------

    // ---- 音频源选择（控制信号，非样本）--------------------------------------
    // audio_src_mux 只产出"现在该放哪个文件"（src_sel/src_name/src_start），
    // **它没有任何样本端口** —— 见文件头说明与 ARCH 伪码的差异。
    wire [1:0]  audio_src_sel;
    wire [87:0] audio_src_name;
    wire        audio_src_start;
    audio_src_mux u_audio_src (
        .clk(clk_pixel), .rst_n(rst_n),
        .mode(mode), .audio_en(audio_en_eff), .sd_ready(sd_ready_audio),
        .src_sel(audio_src_sel), .src_name(audio_src_name), .src_start(audio_src_start),
        .eff_audio_en());       // 有意空连接：音量的应急钳位以 key_router 为唯一权威

    // ---- WAV 流播放（BGM / NARR / ALARM）------------------------------------
    // `loop` 常 1：三个音频文件都是循环素材，播完回绕。
    // `sd_grant` 来自 SD 仲裁段（sd_owner_wav），必须组合给出、不打拍；
    //   打一拍会让 WAV 在授权那一拍看到 grant=0 而不发 blk_start，块请求丢失。
    //   （t7-B 还要等 rle_decoder 补上 sd_grant 端口，届时变三路，见 §5 #2。）
    // 注意 wav_blk_start / wav_want_blk / wav_blk_addr 的**声明在仲裁段之前**
    //   （Verilog-2001 先声明后使用），此处只做例化，不能再声明一遍。
    wire        wav_playing, wav_busy, wav_underrun;
    wire        wav_sample_valid;
    wire signed [23:0] wav_sample_l, wav_sample_r;
    wav_stream_player #(
        .CLK_FREQ_HZ(25_000_000), .SAMPLE_RATE(48_000), .FIFO_AW(10),
        .LOW_WM(256), .BLK_TIMEOUT(2_097_152), .CHAIN_MAX(4096)
    ) u_wav (
        .clk(clk_pixel), .rst_n(rst_n),
        .start(audio_src_start), .target_name(audio_src_name),
        .play_en(audio_en_eff), .loop(1'b1),
        .busy(wav_busy), .playing(wav_playing), .err_code(), .underrun(wav_underrun),
        .fifo_level(),
        .sd_grant(sd_grant_wav), .blk_start(wav_blk_start), .blk_addr(wav_blk_addr),
        .want_blk(wav_want_blk),
        .blk_busy(sd_busy), .blk_done(sd_blk_done), .blk_err(sd_blk_err),
        .data_byte(sd_dbyte), .data_valid(sd_dvalid),
        .sample_valid(wav_sample_valid),
        .sample_l(wav_sample_l), .sample_r(wav_sample_r));

    // ---- 音调发生器（WAV 不可用时的兜底，也是按键/告警音的来源）-------------
    wire               tone_valid;
    wire signed [23:0] tone_left, tone_right;
    audio_tone_gen #(
        .CLK_FREQ_HZ(25_000_000), .SAMPLE_RATE_HZ(48_000), .NOTE_HOLD_SAMPLES(24_000)
    ) u_tone (
        .clk(clk_pixel), .rst_n(rst_n), .playback_state(playback_state),
        .mute(1'b0),            // 开关统一由 audio_en_eff 在样本 mux 上游控制
        .audio_valid(tone_valid), .audio_left(tone_left), .audio_right(tone_right));

    // ---- ★ 样本级 mux：ARCH 伪码里有、实现里没有的那一段 -------------------
    // 选择位用 `wav_playing`（电平）而不是 `wav_sample_valid`（48 kHz 单拍脉冲）：
    //   用脉冲选源会在换源那一拍把波形截断，表现为周期性的"咔"声。
    wire               src_sample_valid = wav_playing ? wav_sample_valid : tone_valid;
    wire signed [23:0] src_sample_l     = wav_playing ? wav_sample_l     : tone_left;
    wire signed [23:0] src_sample_r     = wav_playing ? wav_sample_r     : tone_right;

    // ---- 音量（10 档 + 应急下限钳位）---------------------------------------
    // 插在**四个消费者之前且只插一次**。漏掉任何一个都是隐性 bug：
    //   ① HDMI 内嵌音频   → 调音量声音不变
    //   ② 3.5mm PWM 音频 → 调音量音量不变
    //   ③ 屏幕波形幅度   → 声音变小了但波形幅度不变（最难发现的一种）
    //   ④ audio_arc      → 只吃 valid，不吃样本（见下方说明）
    wire               audio_valid;
    wire signed [23:0] audio_left, audio_right;
    wire [3:0]         vol_eff_lvl;
    vol_apply #(.VOL_MAX(4'd9)) u_vol (
        .clk(clk_pixel), .rst_n(rst_n),
        .sample_valid(src_sample_valid), .sample_in(src_sample_l),
        .vol_lvl(vol_lvl), .mode(mode), .audio_en(audio_en_eff),
        .sample_valid_out(audio_valid), .sample_out(audio_left),
        .eff_lvl(vol_eff_lvl));
    // 右声道单独再过一次（vol_apply 是单声道模块）：
    //   本设计的音源都是单声道，右声道直接复制左声道即可（与工程既有约定一致）。
    //   若将来接入真立体声，这里要再例化一个 vol_apply，而不是直接复制。
    wire signed [23:0] audio_right_unused = audio_left;

    // HDMI 试听音量：有符号 PCM 再衰减 6 bit，幅度为原来的 1/64（约 -36 dB）。
    // 这一步是**接收端音量对齐**，与 vol_apply 的 10 档用户音量是两回事，不能合并。
    localparam HDMI_AUDIO_ATTEN_SHIFT = 6;
    wire signed [23:0] hdmi_audio_left  = audio_left  >>> HDMI_AUDIO_ATTEN_SHIFT;
    wire signed [23:0] hdmi_audio_right = audio_right_unused >>> HDMI_AUDIO_ATTEN_SHIFT;

    // ---- 像素后处理与 OSD 叠加（Key4/5/6/10 + v2 新增字幕开关）-------------
    // 放在音频之后例化，是因为电平条要拿 audio_left 的真实幅度画，而不是
    // 另外编一个动画 —— "看到的跳动"必须就是"听到的声音"。
    // 处理顺序: 亮度（在下游 brightness_apply）→ 反色 → OSD。
    //
    // 【v1 → v2：caption_en 从硬接 1'b1 改为 ticker_en_eff】
    //   v1 的注释理由是「16 个键已全部占满，字幕若要独立开关就得再抢一个键号，
    //   代价大于收益」——这是**旧 v1 需求遗留**（当时确实没有字幕键）。
    //   v2 的用户规格里 Key5 就是「底部字幕开关」，`key_router` 也已经在出
    //   `ticker_en` / `ticker_en_eff`（应急强制开）。所以这里必须改成接：
    //     `ticker_en_eff = emerg ? 1'b1 : ticker_en`
    //   行为：Key5 关 → 底部滚动带关；应急 → 强制显示（疏散信息不能被用户关掉）。
    //   ⚠ 注意 `osd_caption.caption_en` 现在的语义**只控底部滚动带**，
    //     标题行/状态行只受 `narr_en`（科普模式）影响，不受 Key5 影响。
    //
    // 【narr_en / frame_idx 的真值（t7-B 接上，取代 t7-A 的常量 0）】
    //   t7-A 接 `.narr_en(1'b0), .frame_idx(16'd0)` 有两个后果：
    //     ① 功能上：科普模式没有视频字幕（narr_subline 不工作）；
    //     ② 综合上：常量传播把**整个 narr_subline 连同 1 块 BRAM** 优化掉 ——
    //        这就是 t7-A `#bram 34` 里没有 narr 那 1 块的原因。
    //        接真值后 `#bram` 必须从 34 涨到 35，否则说明这段又被剪了。
    //
    //   ★ 为什么不能只写 `narr_en = m_science`：
    //     `narr_en=1` 会**同时关掉标题行 + 状态行两条静态 ASCII 带**（设计意图：
    //     科普模式只留视频字幕）；而 narr_subline 自己的
    //     `in_range = (frame_idx >= 4) && (frame_idx <= 624)`（rtl/osd/narr_subline.v）
    //     在帧号还是 0..3 时判假 → 输出空白。
    //     两者叠起来 = 刚进科普的那 4 帧（@5fps 约 0.8 s）**整层全黑**：
    //     标题没了、状态行没了、字幕也还没有。用户看到的是"进科普就黑一下"。
    //     所以 narr_en 必须与「帧号已经进入有效区间」同时成立。
    //
    //   ★ 为什么还要 `rle_frame_ready`：
    //     frame_idx 由 u_rle 维护，但**第一帧提交之前**它已经是 0（复位值），
    //     而 rle_play_en 可能在帧号还没动时就已经为 1。没有 rle_frame_ready
    //     门控的话，上面那条 frame_idx 判据挡得住（0..3 判假），但一旦 rle 开始
    //     推进帧号而帧还没真正上屏（前几帧在写后台缓冲），就会出现「字幕在跑、
    //     画面还是上一张图」。rle_frame_ready 是 image_player 真正翻完一帧的
    //     单拍脉冲（ext_frame_ready），用它把三者绑在一起。
    // ------------------------------------------------------------------
    wire narr_frame_ok = (rle_frame_idx >= 16'd4) && (rle_frame_idx <= 16'd624);
    wire narr_on       = m_science && rle_frame_ready && narr_frame_ok;
    video_overlay u_overlay (
        .pixel_clk(clk_pixel), .rst_n(rst_n),
        .de(de), .active_x(active_x), .active_y(active_y), .rgb_in(video_base),
        .bright_sel(bright_sel), .invert_en(invert_en),
        .grid_en(grid_en), .info_en(info_en),
        .level_en(level_en), .wave_en(wave_en),
        .caption_en(ticker_en_eff), .play_state(playback_state), .auto_play(auto_play),
        .narr_en(narr_on), .frame_idx(rle_frame_idx),   // t7-B 真值，见上
        .info_index(img_index), .info_mode(mode), .info_auto(auto_sw_sel),
        .audio_sample(audio_left), .audio_valid(audio_valid),
        .rgb_out(video_rgb_ovl));

    // ---- 参数面板（B3：按键调参数，画面同步显示参数）------------------------
    // 【为什么要新增这一级，而不是塞进 video_overlay】
    //   video_overlay 是纯组合的"图层叠加器"，输入全是 1 位开关 + 几个小向量，
    //   它不认识字符、不认识字模、也不该认识 —— 那是 OSD 层的职责。
    //   把文字通路（字表 + 字模 + 取模）独立成 rtl/osd/ 三个模块，好处是
    //   video_overlay 的 90 条仿真断言全部保持有效，回归面不扩大。
    //
    // 【为什么插在 video_overlay 之后】
    //   面板是用户按键主动召唤的 UI，被九宫格线或电平条盖住一角都是 bug 观感。
    //   放在最后一级 = 面板覆盖一切；面板关掉时逐像素不影响任何既有图层。
    //
    // 【谁触发面板】
    //   16 个键已全部占满，不能再抢键号（历史事故见 docs/progress.md）。
    //   所以用 osd_autopop 监视 7 个用户可调参数，任一变就弹 2.5 秒 ——
    //   "按 KEY6 调亮度"这个动作本身就同时完成了调参数 + 文字确认。
    //
    // 【t16：bright 位宽 3 → 4，且新增 vol_lvl / res_sel / ratio_sel 三项】
    //   key_router.bright_lvl / vol_lvl 都是 reg [3:0]、量程 0..9 十档。
    //   改造前这里接的是 `bright_sel`（= bright_lvl[2:0]，只到 7），后果有两层：
    //     ① osd_panel 显示 BRI 时档 8 印成 "0"、档 9 印成 "1"（显示错误）；
    //     ② osd_autopop 只监视 0..7 的变化 → 档 7→8、8→9 这两步不会自动弹面板，
    //        用户按了键却没有任何反馈。
    //   现在两项都吃全 4 位；vol_lvl / res_sel / ratio_sel 是本轮新增的三个参数项
    //   （Key7 音量 / Key8 分辨率 / Key9 屏占比），三根线顶层 :126-129 已声明、
    //   :146-147 已由 key_router 驱动，这里直接复用，不新增声明。
    //   ★ 但 video_overlay 那一路仍接 3 位 bright_sel —— 理由见 :163 与 :877 两处注释。
    wire panel_on;
    osd_autopop #(.CLK_FREQ_HZ(25_000_000), .HOLD_MS(2500)) u_osd_pop (
        .clk(clk_pixel), .rst_n(rst_n),
        .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),
        .res_sel(res_sel), .ratio_sel(ratio_sel),
        .invert_en(invert_en),
        .auto_sw_sel(auto_sw_sel), .info_mode(mode),
        .panel_on(panel_on));

    // =========================================================================
    // 亮度调节（Key6，10 档）——插在 video_overlay 之后、osd_panel 之前
    // =========================================================================
    // 【为什么放在这一级，而不是放回 video_overlay 里】
    //   v1 的亮度是 video_overlay 内部做的三处移位混合，副作用是"参数面板也被
    //   一起调暗"，结果最暗档位下面板文字几乎看不见 —— 而面板恰恰是用户调亮度
    //   时唯一要看的反馈，等于"调暗之后看不见自己调到了几档"。
    //   v2 把亮度搬到 overlay 下游、panel 上游：画面变暗、面板保持原亮度。
    //   同时 video_overlay 内部的亮度链整段删掉（`r_brt = r_in` 直通），
    //   信息条第 8/9/10 格的"亮度格"改由 bright_sel[2:0] 直接点亮，不再做衰减。
    //
    // 【★ 绝不能在这里打拍】
    //   brightness_apply 是纯组合（零寄存器）。一旦插入寄存器，`active_x/active_y`
    //   相对像素就会错 1 拍，osd_panel 画出来的面板会整体右移 1 像素 ——
    //   而且只在"有亮度档位"时出现（默认档也一样移），仿真波形抓不到，
    //   只有上板盯着面板左边框才能发现。
    //
    // 【de_out 为什么空连接】
    //   实测 `osd_panel.v:183` 的 `de` 只用于输出门控：
    //     `assign rgb_out = de ? (in_panel ? panel_rgb : rgb_in) : 24'd0;`
    //   它**不门控 active_x/active_y 计数**。而 brightness_apply.de_out 是
    //   `assign de_out = de;` 纯直通。所以 osd_panel.de 继续接顶层 de 即可，
    //   空连接 de_out 不是漏项。
    //
    // 【bright_lvl 是 4 位，两个消费者位宽不同】
    //   brightness_apply.bright_lvl 吃全 4 位（0..9 十档）；
    //   video_overlay.bright_sel  只吃低 3 位（只能表示 0..7，用于点亮信息条
    //   第 8/9/10 格 —— 那三个格子编码的是"档位高低"而不是精确值）。
    //   接反（把 4 位接给 3 位、或让 overlay 内部再衰减一次）= 双重变暗，
    //   而且只有暗档位看得出来，是典型的上板才发现的问题。
    //   ★ 但 osd_panel / osd_autopop 必须吃全 4 位 —— 它们要印 "BRI:8"、"BRI:9"
    //     这种十档数值，3 位只能到 7。t16 之前这两处也接的 3 位 bright_sel，
    //     是本次修掉的显示错误 + 自动弹窗漏档。
    wire [23:0] video_rgb_brt;
    brightness_apply u_bright (
        .de(de), .rgb_in(video_rgb_ovl), .bright_lvl(bright_lvl),
        .de_out(),                         // 见上：osd_panel.de 继续用顶层 de
        .rgb_out(video_rgb_brt));

    osd_panel u_osd_panel (
        .pixel_clk(clk_pixel), .rst_n(rst_n),
        .de(de), .active_x(active_x), .active_y(active_y), .rgb_in(video_rgb_brt),
        .panel_on(panel_on),
        .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),
        .res_sel(res_sel), .ratio_sel(ratio_sel),
        .invert_en(invert_en),
        .auto_sw_sel(auto_sw_sel), .info_mode(mode),
        .img_index(img_index), .gallery_count(gallery_count),
        .rgb_out(video_rgb));

    // ---- ACR（音频时钟再生）：告诉接收端"多少像素时钟对应一个音频采样" -----
    wire        acr_valid;
    wire [19:0] acr_cts, acr_n;
    audio_arc #(.ACR_N(6144)) u_arc (
        .clk(clk_pixel), .rst_n(rst_n), .audio_valid(audio_valid),
        .acr_valid(acr_valid), .acr_cts(acr_cts), .acr_n(acr_n));

    // ---- HDMI 1.4b 发射核 ---------------------------------------------------
    // 参数必须与 video_timing_gen 的时序完全一致（800×525），否则核内部重建的
    // 同步与外部视频流的相位永远对不上，O_video_locked 不会拉高。
    // VIDEO_TPG 必须 "Disable"：置 "Enable" 会让核改用内部测试图，外部 AXIS 流失效。
    // VIDEO_VIC=1 即 CEA-861 的 640×480@59.94/60。
    // I_rst 是**高有效**（与参考顶层 ~rst_n 接法一致），别直接接 rst_n。
    wire ddc_scl_unused;
    wire ddc_sda_unused;
    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"),
        .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2),  .VFP(10), .VBP(33), .VACTIVE(480),
        .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"), .VIDEO_VIC(1),
        .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
    ) u_hdmi_core (
        .I_pixel_clk(clk_pixel),
        .I_rst(~rst_n),
        .I_edid_read_trig(1'b0),          // 本板无 DDC：从不发起 EDID 读取
        .O_edid_read_valid(),
        .O_edid_read_data(),
        .I_axis_s_user(video_user),
        .I_axis_s_valid(video_valid),
        .I_axis_s_last(video_last),
        .I_axis_s_data(video_data),
        .O_axis_s_ready(),                // 文档：只在 last 之后拉低，行内恒可用
        .I_audio_valid(audio_valid),
        .I_audio_left_data(hdmi_audio_left),
        .I_audio_right_data(hdmi_audio_right),
        .I_acr_valid(acr_valid),
        .I_acr_cts(acr_cts),
        .I_acr_n(acr_n),
        .O_video_locked(hdmi_video_locked),
        .O_ddc_scl(ddc_scl_unused),
        .IO_ddc_sda(ddc_sda_unused),
        .O_ch0_tmds_data(tmds_ch0),
        .O_ch1_tmds_data(tmds_ch1),
        .O_ch2_tmds_data(tmds_ch2),
        .O_clk_tmds_data(tmds_clk)
    );

    // ---- TMDS 串化（核只给 10 bit 并行字，串行差分要自己做）----------------
    hdmi_phy u_phy (
        .I_pixel_clk(clk_pixel), .I_serial_clk(clk_5x), .I_rst(~rst_n),
        .I_tmds_ch0(tmds_ch0), .I_tmds_ch1(tmds_ch1),
        .I_tmds_ch2(tmds_ch2), .I_tmds_clk(tmds_clk),
        .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P),
        .O_tmds_ch2_p(HDMI_D2_P), .O_tmds_clk_p(HDMI_CLK_P));

    // =========================================================================
    // 面向用户的错误提示层（err_prompt）
    // -------------------------------------------------------------------------
    // 【改造前】数码管直接显示各模块内部的 1~9 错误码：
    //      dig3 = 故障类型码（1=SD / 2=图片 / 3=图库），dig2 = 该模块内部错误码
    //   用户看到 "13" 或 "25" 这样的两位数字，**必须查表才知道是什么意思**，
    //   而"我该做什么"这层信息完全没有 —— TASKS.md A8 记录的缺口即此。
    //   更糟的是 "卡读通了但里面一张图都没有" 这种情况：三个 fail 标志全为 0，
    //   数码管停在 "0000"、屏幕放测试图、蜂鸣器不响，用户只会以为设备坏了。
    //
    // 【改造后】err_prompt 把 5 个模块散落的内部码归并成 5 类"用户动作"，
    //   数码管高两位显示助记字母 + 子码：
    //      C0 请插卡（快速提示，sd_cd 硬件电平直接给出，不等 SD 探测）
    //      C1 请插卡（卡没响应）      C2 换一张卡（协议不兼容/非 SDHC）
    //      F1~F4 请格式化为 FAT32（MBR 签名错 / BPB 非法 / 簇链坏 / 定位失败）
    //      00 卡是好的但没有图片，请放入 IMG001.BMP 起的连续文件
    //      b1 图片格式不对（BMP 头解析失败）  b2 图片尺寸不是 640x480
    //      d1~d8 数据通路/存储故障（接触不良、读块失败、SDRAM、超时等）
    //   普通用户只需认**第一位字母**就知道该做什么；第二位留给维修人员细分。
    //
    // 【为什么错误提示优先于播放状态显示】
    //   数码管只有 4 位，既要显示"当前播到第几张"又要显示"出了什么错"。
    //   改造前是故障时把 dig3 换成故障类型码、正常时显示播放状态 —— 但这样
    //   故障码与播放状态码**混用同一个数字空间**（都占 dig3），
    //   用户看到 "1" 无法判断是"SD 故障"还是"正在扫描 SD"。
    //   现在改为：`err_active` 决定**整组切换** —— 有错时高两位显示 C/F/0/b/d
    //   助记字母（字母与数字天然可区分），无错时才显示播放状态数字。
    wire        err_active;
    wire [3:0]  prompt_hi, prompt_lo;
    wire        alarm_req;
    err_prompt #(.CLK_FREQ_HZ(25_000_000)) u_err (
        .clk(clk_pixel), .rst_n(rst_n),
        .sd_fail(sd_fail), .sd_err(probe_err), .sd_cd(sd_cd),
        .gallery_fail(gallery_fail), .gallery_err(gallery_err),
        .gallery_done(gallery_done), .gallery_count(gallery_count),
        .image_failed(image_failed), .image_err(image_error),
        .err_active(err_active), .prompt_hi(prompt_hi), .prompt_lo(prompt_lo),
        .alarm_req(alarm_req));

    buzzer_tone #(.CLK_FREQ_HZ(25_000_000)) u_buzz (
        .clk(clk_pixel), .rst_n(rst_n),
        // 优先级: 静音(Key15/P2) > 故障告警 > 应急 > 按键音。
        //   静音排最前是因为它是用户**显式**要求"别响"，其余三档都是设备自己想响；
        //   用户意志高于设备提示。静音只掐蜂鸣器；HDMI 内嵌音频与 3.5mm 由
        //   vol_apply.audio_en（Key4 = audio_en_eff）管，两条支路互不影响。
        //   故障告警排第二是因为它是"设备坏了"的唯一听觉通道（改造前完全不响）；
        //   应急模式是用户主动按 Key3 进入的，故障时用户更需要知道前者。
        // tone_sel 已由 2 位扩到 3 位：旧顶层把 2 位表达式接进来时高位自动补 0，
        //   故 min_top / bringup_top / 三个 diag_top 一行都不用改。
        // 为什么用 tone_sel=0 档而不是给 buzzer_tone 加 mute 端口:
        //   tone_sel 的 0 档本来就是"静音"（见 rtl/audio/buzzer_tone.v 的档位定义），
        //   为一个开关去改已验证模块的端口表，收益为零、回归风险非零。
        .tone_sel(beep_muted ? 3'd0 : (alarm_req ? 3'd3 : (m_emerg ? 3'd2 : 3'd1))),
        .trig(key_event), .buzzer_out(buzzer));
    // 模拟音频与 HDMI 内嵌音频共用同一份 PCM 样本（音视频联动的另一半：
    //   不是"两路各自发音"，而是"同一路样本两种输出方式"）。
    // ★ sample_in 必须是 vol_apply 之后（audio_left），不是音源原始样本：
    //   否则调音量时 HDMI 声音变小、3.5mm 口不受影响 —— 同一份素材两个音量。
    // ★ mute 接 1'b0：静音由 vol_apply.audio_en 在上游做成"逐位全 0"，
    //   这里再接一遍 audio_en 会让"关音量"与"关音频开关"混成同一个信号。
    pcm_to_pwm u_pwm_audio (
        .clk(clk_pixel), .rst_n(rst_n), .sample_valid(audio_valid),
        .sample_in(audio_left), .mute(1'b0), .pwm_out(audio_pwm));

    // LED[7:0] = 资源错误、装载、SDRAM锁定、HDMI锁定、应急、FIFO异常、轮播、图片就绪。
    // 第 7 位改用 err_prompt.err_active（原先直接或 sd_fail/gallery_fail/image_failed）：
    //   语义扩大为"存在任何面向用户的错误"，包含新增的"卡好但零张图"这类
    //   改造前**没有任何指示灯反映**的盲区。否则现场换一张没有 IMGnnn.BMP 的卡，
    //   灯全灭、屏幕放测试图，看起来和正常启动一模一样。
    // 第 4 位本次升级为 "PLL 锁定 且 发射核视频锁定"：只看 PLL 锁定的老语义无法
    //   区分"时钟有了但核没对齐"这种最难查的故障（插上线却不亮、PLL 灯却是亮的）。
    reg [1:0] sdram_lock_pix;
    always @(posedge clk_pixel or negedge rst_n) begin
        if(!rst_n) sdram_lock_pix <= 0;
        else sdram_lock_pix <= {sdram_lock_pix[0],sdram_locked};
    end
    assign led = {err_active, image_loading, sdram_lock_pix[1],
                  locked && hdmi_video_locked,
                  mode==2, |reader_status[1:0], auto_play, image_ready};
    wire [6:0] seg0, seg1, seg2, seg3;
    // 数码管高两位（dig3/dig2）在"有错"与"正常"两种口径间整组切换：
    //   有错 → dig3=助记字母类（C/F/0/b/d），dig2=类内子码
    //   正常 → dig3=播放状态（0空闲 1扫描 2装载 3就绪 4轮播 5应急），dig2=当前图号
    // 改造前两者共用同一个数字空间、靠"故障时分段覆盖"实现，用户无法区分
    // "1=SD故障" 与 "1=正在扫描SD"；改用字母后，**类型一眼可分**。
    wire [3:0] error_value = err_active ? prompt_lo : image_error;
    wire [3:0] state_value = err_active ? prompt_hi : {1'b0, playback_state};
    seg_decoder u_dec0 (.bin_data({1'b0,pattern_sel}), .seg_data(seg0));
    seg_decoder u_dec1 (.bin_data(loader_index[3:0]), .seg_data(seg1));
    seg_decoder u_dec2 (.bin_data(error_value), .seg_data(seg2));
    seg_decoder u_dec3 (.bin_data(state_value), .seg_data(seg3));
    seg_scan4 #(.CLK_FREQ_HZ(25_000_000), .SCAN_HZ(1000)) u_seg (
        .clk(clk_pixel), .rst_n(rst_n), .dig0({1'b0,seg0}), .dig1({1'b0,seg1}),
        .dig2({1'b0,seg2}), .dig3({1'b0,seg3}), .seg_data(seg_data), .seg_cs(seg_cs));
endmodule
