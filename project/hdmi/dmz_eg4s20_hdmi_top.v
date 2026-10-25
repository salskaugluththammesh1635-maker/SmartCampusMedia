// 阶段四 S6 + 阶段五 S7 前置切片：SD/FAT32/BMP -> SiP SDRAM -> HDMI 图片播放顶层。
// S7 切片要点：图库张数不再由编译参数给定，改由 gallery_probe 在 SD 就绪后
//   runtime 扫描得出（见下方"三段严格串行"），换一批素材/换一张卡都不必重综合。
// 单缓冲装载期间显示测试图；上板结果须单独记录。管脚依据 constraints/。
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
    input  wire        sd_cd,          // E15, 卡插入检测（无卡=1 插卡=0，本版未用）
    // ---- PWM 音频输出（板载低通+功放，赛规基础要求③）----
    output wire        audio_pwm,      // F3，占空比调制信号
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
    // KEY0/1=上一张/下一张；KEY2=轮播；KEY3=模式；KEY15=应急；KEY4/5=测试图；KEY6=音频。
    reg [2:0] pattern_sel;
    always @(posedge clk_pixel or negedge rst_n) begin
        if(!rst_n) pattern_sel <= 0;
        else if(key_event && key_code==4) pattern_sel <= pattern_sel-1'b1;
        else if(key_event && key_code==5) pattern_sel <= pattern_sel+1'b1;
    end
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
        .gallery_count(gallery_count), .gallery_valid(gallery_done), .img_index(img_index),
        .loader_index(loader_index), .img_switch_req(switch_req), .auto_play_en(auto_play),
        .mode(mode), .status_led());
    wire hs, vs, de, vblank;
    wire [10:0] active_x; wire [9:0] active_y;
    video_timing_gen u_vtg (.pixel_clk(clk_pixel), .rst_n(rst_n), .hs(hs), .vs(vs), .de(de),
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
        .clk(clk_pixel), .rst_n(rst_n), .sd_ok(sd_ok),
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
    image_player u_player (
        .pix_clk(clk_pixel), .rst_n_pix(rst_n), .sdr_clk(clk_sdr), .sdr_clk_sft(clk_sdr_sft),
        .rst_n_sdr(rst_sync_sdr[2]), .sd_ready(sd_ok), .sd_failed(sd_fail), .blk_busy(sd_busy),
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
    wire [23:0] video_rgb = !de ? 24'd0 : ((mode==2) ? 24'hFF0000 :
        ((image_ready && image_pixel_valid) ? image888 : {pr,pg,pb}));
    hdmi_tx #(.FAMILY("EG4")) u_hdmi (
        .PXLCLK_I(clk_pixel), .PXLCLK_5X_I(clk_5x), .RST_N(rst_n),
        .VGA_HS(hs), .VGA_VS(vs), .VGA_DE(de), .VGA_RGB(video_rgb),
        .HDMI_CLK_P(HDMI_CLK_P), .HDMI_D2_P(HDMI_D2_P), .HDMI_D1_P(HDMI_D1_P), .HDMI_D0_P(HDMI_D0_P));
    buzzer_tone #(.CLK_FREQ_HZ(25_000_000)) u_buzz (
        .clk(clk_pixel), .rst_n(rst_n), .tone_sel(mode==2 ? 2'd2 : 2'd1), .trig(key_event), .buzzer_out(buzzer));
    reg audio_muted;
    always @(posedge clk_pixel or negedge rst_n) begin
        if(!rst_n) audio_muted <= 1'b0;
        else if(key_event && key_code==6) audio_muted <= ~audio_muted;
    end
    pwm_audio_out #(.CLK_FREQ_HZ(25_000_000)) u_audio (
        .clk(clk_pixel), .rst_n(rst_n), .mute(audio_muted), .audio_pwm(audio_pwm));

    // LED[7:0] = 图库故障、装载、SDRAM锁定、HDMI锁定、应急、FIFO异常、轮播、图片就绪。
    // 第 7 位(SD 失败)与第 0 位(图片失败)合并语义: 图库扫描失败同样是"资源不可用"，
    // 必须点亮同一个告警灯 —— 否则现场换一张没有 IMGnnn.BMP 的卡，灯全灭像是正常启动。
    wire sd_or_gallery_fail = sd_fail || gallery_fail;
    reg [1:0] sdram_lock_pix;
    always @(posedge clk_pixel or negedge rst_n) begin
        if(!rst_n) sdram_lock_pix <= 0;
        else sdram_lock_pix <= {sdram_lock_pix[0],sdram_locked};
    end
    assign led = {sd_or_gallery_fail || image_failed, image_loading, sdram_lock_pix[1], locked,
                  mode==2, |reader_status[1:0], auto_play, image_ready};
    wire [6:0] seg0, seg1, seg2, seg3;
    // 错误码优先级: 图库扫描失败 > SD 探针失败 > 图片装载失败。
    // 三者共用数码管第 2 位，用"谁先发生"的顺序给出可诊断的数字。
    wire [3:0] error_value = gallery_fail ? gallery_err : (sd_fail ? probe_err : image_error);
    seg_decoder u_dec0 (.bin_data({1'b0,pattern_sel}), .seg_data(seg0));
    seg_decoder u_dec1 (.bin_data(loader_index[3:0]), .seg_data(seg1));
    seg_decoder u_dec2 (.bin_data(error_value), .seg_data(seg2));
    seg_decoder u_dec3 (.bin_data(sd_fail ? 4'd1 : (gallery_fail ? 4'd3 : (image_failed ? 4'd2 : 4'd0))), .seg_data(seg3));
    seg_scan4 #(.CLK_FREQ_HZ(25_000_000), .SCAN_HZ(1000)) u_seg (
        .clk(clk_pixel), .rst_n(rst_n), .dig0({1'b0,seg0}), .dig1({1'b0,seg1}),
        .dig2({1'b0,seg2}), .dig3({1'b0,seg3}), .seg_data(seg_data), .seg_cs(seg_cs));
endmodule
