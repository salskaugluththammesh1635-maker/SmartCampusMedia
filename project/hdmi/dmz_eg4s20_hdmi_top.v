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
    // 键位分配总表（同一按键不得被两个功能复用，见 docs/keymap_2026-10-26.md）
    //   KEY0/1/2/3/15 → player_ctrl（上一张/下一张/轮播/模式/应急直达）
    //   KEY4/5        → 本层 pattern_sel（测试图案上/下一张）
    //   KEY6          → 本层 audio_muted（音频静音，含 HDMI 内嵌与 3.5mm）
    //   KEY7~KEY14    → key_action 统一译码（本层不再单独消费这 8 个键号）
    // =========================================================================
    reg [2:0] pattern_sel;
    always @(posedge clk_pixel or negedge rst_n) begin
        if(!rst_n) pattern_sel <= 0;
        else if(key_event && key_code==4) pattern_sel <= pattern_sel-1'b1;
        else if(key_event && key_code==5) pattern_sel <= pattern_sel+1'b1;
    end
    // ---- 扩展键译码（KEY7~KEY14）----------------------------------------
    // 为什么单独做一个模块而不是在顶层继续写 if：顶层已经消费了 KEY0~KEY6，
    //   再往里塞 8 个键的译码会让"哪个键归谁"散落在多个 always 块里 ——
    //   项目历史上的 KEY0/KEY1 双占用事故正是这样产生的。收拢到唯一译码点后，
    //   顶层只需要按功能接信号，键号本身不再出现在顶层代码里。
    wire [2:0] bright_sel;      // KEY7  亮度档 0..4
    wire       invert_en;       // KEY8  反色
    wire [1:0] auto_sw_sel;     // KEY9  轮播倍率档 0..3
    wire       rescan_req;      // KEY10 图库重扫（单拍）
    wire       grid_en;         // KEY11 九宫格
    wire       info_en;         // KEY12 信息条
    wire       level_en;        // KEY13 音频电平条
    wire       beep_muted;      // KEY14 蜂鸣器静音
    key_action u_kact (
        .clk(clk_pixel), .rst_n(rst_n), .key_event(key_event), .key_code(key_code),
        .bright_sel(bright_sel), .invert_en(invert_en), .auto_sw_sel(auto_sw_sel),
        .rescan_req(rescan_req), .grid_en(grid_en), .info_en(info_en),
        .level_en(level_en), .beep_muted(beep_muted));
    wire sd_ok, sd_fail;
    wire [3:0] probe_err;
    wire [4:0] img_index;
    wire [8:0] loader_index;
    wire switch_req, auto_play;
    wire [1:0] mode;
    // 图库张数来自扫描器（runtime 实测），不再是编译参数：
    //   固定接常量的话，现场换一批素材就得重新综合 —— 这正是本次切片要消除的。
    wire [4:0] gallery_count;
    wire       gallery_done;
    player_ctrl #(.CLK_FREQ_HZ(25_000_000)) u_ctrl (
        .clk(clk_pixel), .rst_n(rst_n), .key_event(key_event), .key_code(key_code),
        .auto_sw_sel(auto_sw_sel),
        .gallery_count(gallery_count), .gallery_valid(gallery_done), .img_index(img_index),
        .loader_index(loader_index), .img_switch_req(switch_req), .auto_play_en(auto_play),
        .mode(mode), .status_led());
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
    // 仲裁: 探针未结束 → 探针；探针结束后扫描未结束 → 扫描器；否则 → 播放链路
    wire        sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;
    wire        sd_owner_player  = sd_ok && !sd_owner_gallery;
    wire        sd_arb_start     = sd_owner_gallery ? gallery_start : (sd_owner_player ? player_start : probe_start);
    wire [31:0] sd_arb_addr      = sd_owner_gallery ? gallery_addr  : (sd_owner_player ? player_addr  : probe_addr);
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
        .first_img_req(gallery_first_req), .err_code(gallery_err));

    wire [15:0] image565;
    wire image_pixel_valid, image_ready, image_loading, image_failed;
    wire [3:0] image_error;
    wire [2:0] reader_status;
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
    //  【2026-10-28 修复】sd_ready 必须接 sd_owner_player，不能接 sd_ok
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
    //  sd_owner_player = sd_ok && (gallery_done || gallery_fail)，
    //  正好表达「图库扫描已完结、总线已归播放器」。用它做 sd_ready，
    //  播放器就会一直停在 C_WAIT 直到真正拿到总线，请求不会再被吞。
    // ------------------------------------------------------------------
    image_player u_player (
        .pix_clk(clk_pixel), .rst_n_pix(rst_n), .sdr_clk(clk_sdr), .sdr_clk_sft(clk_sdr_sft),
        .rst_n_sdr(rst_sync_sdr[2]), .sd_ready(sd_owner_player), .sd_failed(sd_fail), .blk_busy(sd_busy),
        .load_req(player_load_req), .image_index(loader_index), .blk_start(player_start), .blk_addr(player_addr),
        .blk_done(sd_blk_done), .blk_err(sd_blk_err), .data_byte(sd_dbyte), .data_valid(sd_dvalid),
        .de(de), .scan_y(vblank ? 10'd480 : active_y), .rgb565(image565), .pixel_valid(image_pixel_valid),
        .image_ready(image_ready), .loading(image_loading), .failed(image_failed), .error_code(image_error),
        .reader_status(reader_status), .sdram_clk(sdram_clk_w), .sdram_cke(sdram_cke_w),
        .sdram_cs_n(sdram_cs_n_w), .sdram_ras_n(sdram_ras_n_w), .sdram_cas_n(sdram_cas_n_w),
        .sdram_we_n(sdram_we_n_w), .sdram_ba(sdram_ba_w), .sdram_addr(sdram_addr_w),
        .sdram_dm(sdram_dm_w), .sdram_dq(sdram_dq_w));
    // SiP SDRAM 在 FPGA 封装内部，不增加板级 SDRAM IO。
    EG_PHY_SDRAM_2M_32 u_sdram_sip (
        .clk(sdram_clk_w), .ras_n(sdram_ras_n_w), .cas_n(sdram_cas_n_w), .we_n(sdram_we_n_w),
        .addr(sdram_addr_w), .ba(sdram_ba_w), .dq(sdram_dq_w), .cs_n(sdram_cs_n_w),
        .dm0(sdram_dm_w[0]), .dm1(sdram_dm_w[1]), .dm2(sdram_dm_w[2]), .dm3(sdram_dm_w[3]), .cke(sdram_cke_w));
    // RGB565 位复制扩展回 RGB888，与 de 同拍。应急模式优先显示红屏并鸣叫。
    wire [23:0] image888 = {image565[15:11],image565[15:13],image565[10:5],image565[10:9],
                           image565[4:0],image565[4:2]};
    // video_base = 叠加前的最终画面（应急红屏 / 图片 / 测试图三选一）
    wire [23:0] video_base = !de ? 24'd0 : ((mode==2) ? 24'hFF0000 :
        ((image_ready && image_pixel_valid) ? image888 : {pr,pg,pb}));
    // video_rgb = 经 video_overlay 做亮度/反色/OSD 叠加后的实际上屏像素。
    // 先声明、后由下方 video_overlay 例化驱动（Verilog 的连线赋值与书写顺序无关）。
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

    // ---- 音频源：48 kHz / 24 bit PCM，音高与静音由播放状态决定 -------------
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

    // KEY6 静音开关：必须在音频模块例化之前声明（Verilog-2001 先声明后使用）。
    reg audio_muted;
    always @(posedge clk_pixel or negedge rst_n) begin
        if(!rst_n) audio_muted <= 1'b0;
        else if(key_event && key_code==6) audio_muted <= ~audio_muted;
    end

    wire               audio_valid;
    wire signed [23:0] audio_left, audio_right;
    audio_tone_gen #(
        .CLK_FREQ_HZ(25_000_000), .SAMPLE_RATE_HZ(48_000), .NOTE_HOLD_SAMPLES(24_000)
    ) u_tone (
        .clk(clk_pixel), .rst_n(rst_n), .playback_state(playback_state), .mute(audio_muted),
        .audio_valid(audio_valid), .audio_left(audio_left), .audio_right(audio_right));

    // ---- 像素后处理与 OSD 叠加（KEY7/8/11/12/13）---------------------------
    // 放在音频之后例化，是因为电平条要拿 audio_left 的真实幅度画，而不是
    // 另外编一个动画 —— "看到的跳动"必须就是"听到的声音"。
    // 处理顺序: 亮度 → 反色 → OSD，OSD 不受前两级影响（详见 video_overlay 头）。
    video_overlay u_overlay (
        .pixel_clk(clk_pixel), .rst_n(rst_n),
        .de(de), .active_x(active_x), .active_y(active_y), .rgb_in(video_base),
        .bright_sel(bright_sel), .invert_en(invert_en),
        .grid_en(grid_en), .info_en(info_en), .level_en(level_en),
        .info_index(img_index), .info_mode(mode), .info_auto(auto_sw_sel),
        .audio_sample(audio_left),
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
        .I_audio_left_data(audio_left),
        .I_audio_right_data(audio_right),
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
        // 优先级: 静音(KEY14) > 故障告警 > 应急 > 按键音。
        //   静音排最前是因为它是用户**显式**要求"别响"，其余三档都是设备自己想响；
        //   用户意志高于设备提示。静音只掐蜂鸣器，HDMI 内嵌音频与 3.5mm 由
        //   audio_muted（KEY6）管，两条支路互不影响。
        //   故障告警排第二是因为它是"设备坏了"的唯一听觉通道（改造前完全不响）；
        //   应急模式是用户主动按 KEY15 进入的，故障时用户更需要知道前者。
        // tone_sel 已由 2 位扩到 3 位：旧顶层把 2 位表达式接进来时高位自动补 0，
        //   故 min_top / bringup_top / 三个 diag_top 一行都不用改。
        // 为什么用 tone_sel=0 档而不是给 buzzer_tone 加 mute 端口:
        //   tone_sel 的 0 档本来就是"静音"（见 rtl/audio/buzzer_tone.v 的档位定义），
        //   为一个开关去改已验证模块的端口表，收益为零、回归风险非零。
        .tone_sel(beep_muted ? 3'd0 : (alarm_req ? 3'd3 : (mode==2 ? 3'd2 : 3'd1))),
        .trig(key_event), .buzzer_out(buzzer));
    // 模拟音频与 HDMI 内嵌音频共用同一份 PCM 样本（音视频联动的另一半：
    //   不是"两路各自发音"，而是"同一路样本两种输出方式"）。
    pcm_to_pwm u_pwm_audio (
        .clk(clk_pixel), .rst_n(rst_n), .sample_valid(audio_valid),
        .sample_in(audio_left), .mute(audio_muted), .pwm_out(audio_pwm));

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
