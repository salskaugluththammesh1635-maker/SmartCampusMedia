# 科普模式「只有一条蓝条」信号链诊断报告

- 任务：t5（smartcampus-v2-fix），诊断「科普模式与日常模式唯一区别是屏幕上方多一条蓝条」
- 日期：2026-11-03
- 范围：**只诊断，未改任何 .v，未上板**
- 结论摘要：**看到蓝条 = 模式切换成功 + RLE 视频帧从未提交 + 字幕层被单拍脉冲门控**。这是两个彼此独立的缺陷叠加，不是一个。
  - 缺陷 A（视频通路，致命）：`rle_play_en` 恒 0（卡上素材缺失路径）或 `rle_decoder` 因 SD 广播 `blk_done` 误归属而死锁在 `R_ERR`（结构缺陷，且不自愈、不报错）。
  - 缺陷 B（字幕通路，致命且独立）：`narr_on = m_science && rle_frame_ready && narr_frame_ok`，而 `rle_frame_ready` 是**单拍脉冲**且出现在**垂直消隐期**，因此字幕层每帧只被使能 1 个 40 ns 周期、且落在 `de=0` 区间 —— **即使视频完全正常，中文字幕也永远不会显示**。

---

## 0. 先确认「蓝条」是什么（关键洞察验证：成立）

| 事实 | 依据 |
|---|---|
| 蓝条几何 = 顶部 8 行通栏 + 左上 24×24 方块（合成 L 形） | `rtl/video/video_overlay.v:173-175`：`wire px_sci = (info_mode == 2'b01) && ((active_y <= 10'd7) \|\| ((active_x <= 11'd23) && (active_y <= 10'd31)));` |
| 颜色 = 青蓝 `24'h00_C8_E0` | `rtl/video/video_overlay.v:337`（`rgb_mixed` 选择链里的 `px_sci ? 24'h00_C8_E0`） |
| 由 `info_mode == 2'b01` 驱动，即 `mode == 1`（M_SCIENCE） | 顶层 `rtl/top/dmz_eg4s20_hdmi_top.v:1018` `.info_mode(mode)`；`rtl/control/mode_ctrl.v:99-101` `M_SCIENCE=2'd1` |
| 设计目的就是「任何画面内容下都可见、让操作者判断按键是否生效」 | `rtl/video/video_overlay.v:163-171` 注释（`:168` 原文"任何画面内容下都可见"） |
| 科普与日常**共用同一条图像分支**（mux 只区分 emerg） | `rtl/video/video_content_mux.v`：`mode==2'd2 → emerg_rgb`；`default`（0 和 1）→ `image_ready ? (image_pixel_valid ? image_rgb : 24'd0) : (image_ever_ready ? 24'd0 : pattern_rgb)` |

⇒ **推论（与用户描述逐字吻合）**：`mode==1` 已生效（蓝条出现），但图像层仍是**上一次日常模式装载的那张 BMP**（`image_ready` 保持 1、`front_sel` 从未被 RLE 翻动）。所以"科普与日常唯一区别是多一条蓝条"不是巧合，而是"图像层没换过、只多画了一个模式标记"的必然外观。

---

## 1. 信号链追查表

> 「该为 1 吗」= 设计意图；「实际」分两种现场情形：**(甲) 卡上无 SCI.RLE**、**(乙) 卡上素材齐全但总线误归属**。两种情形最终都是同一个可见结果。

| # | 级别 | 信号 / 状态 | 该为 1 吗 | 实际（甲：卡上缺 SCI.RLE） | 实际（乙：素材齐全） | 依据（文件:行号） |
|---|---|---|---|---|---|---|
| 1 | 模式 | `m_science` (`mode==2'd1`) | 1 | **1** ✅ | **1** ✅ | `rtl/control/mode_ctrl.v:99-101,167-178`；顶层 `:117-123` |
| 2 | 探测 | `gallery_rle_found` | 1 | **0** ❌ | 1 ✅ | `rtl/storage/gallery_probe.v:399-422`（`f32_found → rle_found<=1`）；`:151-156` `RLE_NAME="SCI"+5空格+"RLE"` |
| 3 | 探测 | `gallery_rle_fail` | 0 | 0（"没找到"不算故障） | 0 | `gallery_probe.v:407-421`：`f32_fail` 时仅当 `f32_err != 4'd4` 才置 `rle_fail`；`fat32_reader.v:397` err=4 = 目录项结束/没找到 |
| 4 | 探测 | `gallery_done` | 1 | **1**（图库扫完就置位） | 1 | `gallery_probe.v:453` `G_DONE: done <= 1'b1;` |
| 5 | 锁存 | `rle_lba_vld` | 1 | **0** ❌ 死锁 | 1 ✅ | 顶层 `:379-383`：`else if (gallery_done && gallery_rle_found && !gallery_rle_fail && !rle_lba_vld) rle_lba_vld <= 1'b1;` —— 缺 `rle_found` 就永远进不去 |
| 6 | 使能 | `rle_play_en` | 1 | **0** ❌ | 1 ✅ | 顶层 `:396` `wire rle_play_en = rle_lba_vld && m_science && (gallery_done \|\| gallery_fail);` |
| 7 | 解码器 | `u_rle.play_en` | 1 | **0** ❌ | 1 ✅ | 顶层 `:521` `.play_en(rle_play_en)` |
| 8 | 解码器 | `rle_decoder.state == R_IDLE` 起帧 | 是 | 否（`:480-492` `!play_en` 大复位把它按在 R_IDLE 并清 `err_code`） | 是 | `rle_decoder.v:480-492`、`:496-513` |
| 9 | 总线 | `rle_want_blk` | 1 | **0**（`play_en=0`） | 1 | `rle_decoder.v:311-313`：`want_blk = play_en && !eof_stop && ... && ((state==R_NEXT_BLK) \|\| !blk_ready)` |
| 10 | 仲裁 | `sd_owner_rle` / `sd_grant_rle` | 1 | **0** | 1（WAV 让出时） | 顶层 `:430` `sd_owner_rle = sd_owner_playseg && !wav_want_blk && rle_want_blk;`；`:437` `sd_grant_rle = sd_owner_rle`（组合，不打拍） |
| 11 | 总线 | `blk_start` 到 `sd_spi_ctrl` | 脉冲 | 无 | 有 | `rle_decoder.v:325` `assign blk_start = blk_start_int && sd_grant;`；`:682-688` |
| 12 | 总线 | **`blk_done` 归属** | 只认自己的 | 无事务 | **误认 WAV 的块完成** ❌ | `rle_decoder.v:689` `if (blk_done) begin blk_ready<=1; rd_ptr<=0; blk_index<=blk_index+1; ... end` —— **无 `req_sent` / 无归属门控**；顶层 `:496-502` 已书面登记该风险 |
| 13 | 解码 | 帧头 magic 校验 | 通过 | — | **失败 → `err_code=1` → `R_ERR` 永锁** ❌ | `rle_decoder.v:522-525`；`:716-720` `R_ERR` 只清请求、**永不自愈**（只有 `!play_en` 才能退出） |
| 14 | 解码 | `pack_done`（整帧 153600 字写完） | 1 | **0** | **0** | `rle_decoder.v:295-296` `pack_done = (wr_done_cnt == FRAME_WORDS) && !ext_wr_valid && !done_sent;` |
| 15 | 解码 | `ext_wr_done`（帧提交脉冲） | 1 | **0** | **0** | `rle_decoder.v:473-475` `if (pack_done) ext_wr_done <= 1'b1;` |
| 16 | 上屏 | `image_player` 提交入口 | 触发 | **不触发** | **不触发** | `rtl/storage/image_player.v:271-272` `if (ext_wr_mode && ext_wr_done_sync) commit_pending <= 1'b1;` —— **整条 RLE 上屏链的唯一入口** |
| 17 | 上屏 | `image_ready` / `front_sel` | 翻新帧 | **保持日常 BMP** | **保持日常 BMP** | `image_player.v:274-297`（首帧 `!image_ready` 直接提交；之后必须 `vblank_rise`）；`ext_wr_mode=0` 后 `rd_base` 仍指旧 front |
| 18 | 上屏 | `rle_frame_idx` | 递增 | **恒 0** | **恒 0** | `rle_decoder.v:705-714` 只在 `R_FRAME_END` 里 `+1`；从没进过该态 |
| 19 | 字幕 | `rle_frame_ready` | 1 | **0** | **0** | 顶层 `:670` `.ext_frame_ready(rle_frame_ready)`；`image_player.v:576` `assign ext_frame_ready = ext_frame_ready_r;` |
| 20 | 字幕 | `narr_frame_ok` | 1 | **0**（`frame_idx=0 < 4`） | **0** | 顶层 `:1008` `narr_frame_ok = (rle_frame_idx >= 16'd4) && (rle_frame_idx <= 16'd624);`；`narr_subline.v:183` 同判据 |
| 21 | 字幕 | `narr_on` | 电平 1 | **0** | **0** | 顶层 `:1009` `narr_on = m_science && rle_frame_ready && narr_frame_ok;` |
| 22 | 字幕 | 字幕字形输出 | 有 | 空白 `9'h1FF` | 空白 | `narr_subline.v:64-66,183-190`；`osd_caption.v:202` `narr_active = narr_en && !ticker_emergency`；`:423` `src_data = narr_active ? narr_code : raw_code` |
| 23 | 音频 | `NARR.WAV` 播放源 | 选中 | 选中但文件缺失 | 选中 | `rtl/audio/audio_src_mux.v:70` `MODE_SCIENCE: sel_c = SRC_NARR;` |

### 1.1 第 12 级为什么是「结构缺陷」而不是偶发

`rle_decoder.v:689` 的 `if (blk_done)` 与同态的请求分支（`:682-688`）是**两条独立 if**，`blk_done` 分支不看 `req_sent`、也不看 `blk_busy`。而顶层把 `sd_blk_done` 作为**广播线**直连五个消费者，**无 owner 门控**：

```
rtl/top/dmz_eg4s20_hdmi_top.v:322-323   wire sd_busy, sd_blk_done, sd_blk_err, sd_dvalid; wire [7:0] sd_dbyte;
        :454-455  u_sd      .blk_done(sd_blk_done) .blk_err(sd_blk_err) .data_valid(sd_dvalid)
        :460-461  u_probe   同上
        :469-470  u_gallery 同上
        :518-519  u_rle     同上
        :632-634  u_player  同上
        :921-922  u_wav     同上
```

对照其它消费者**都做了归属门控**，只有 `rle_decoder` 没有：

- `rtl/audio/wav_stream_player.v:210` `reg my_blk_active;`；`:335-336` `bus_locked = (st==W_FATLOC) || (((st==W_FATRD)||(st==W_DATRD)) && my_blk_active);`；`:344-345` `byte_in = data_valid && my_blk_active && (W_DATRD||W_FATRD);`
- `rtl/storage/img_loader.v:376/433/446`：靠状态机（`T_FATRD`/`T_DATRD`）门控 `data_valid`
- `rtl/storage/gallery_probe.v:291-292`：把 `blk_busy` 接常量 0，且只在自身 `G_RUN` 消费

**⇒ `rle_decoder` 是全部五个 SD 消费者里唯一不做归属门控的模块。**

在科普模式下这个缺陷**必然被触发**，因为 NARR.WAV 同时在流：

```
rtl/audio/wav_stream_player.v:340   assign want_blk = play_en && (bus_locked || want_more);   // 电平，非脉冲
rtl/top/dmz_eg4s20_hdmi_top.v:430   sd_owner_rle = sd_owner_playseg && !wav_want_blk && rle_want_blk;   // WAV 绝对优先
```

RLE 在 `R_NEXT_BLK` 停车等 grant（`:676-681` 注释明言"no timeout, no R_ERR"）时，WAV 的块正好完成 → `blk_done` 单拍脉冲被 RLE 认成自己的 → `blk_index++`、`blk_ready<=1`、回 `resume_state` 去解一段**根本不属于本块的字节** → 必出 `err_code` 1/2/3/4 → 进 `R_ERR`（1/2/4 永锁）或 `R_IDLE` 重来（3，但 `blk_index` 已错位，下次必出 1）→ **永久失效**。

一帧要 255 个块（见 §2），WAV 每 5.3 ms 抢一次总线 —— **第一帧内就几乎必然发生**。这与"一帧都没出现过"完全一致，也与"tb 全过、上板全死"完全一致（`tb_rle_decoder` 把 `sd_grant` 恒接 1、且没有 WAV 竞争者，见 §4）。

> 顶层 `:496-502` 的登记里写「缓解：rle_play_en 只在科普模式为 1，而科普模式下 WAV 仍在播 BGM」—— 这条缓解理由是**错的**：`audio_src_mux.v:70` 在 `MODE_SCIENCE` 选的是 `SRC_NARR`（NARR.WAV），不是 BGM。科普模式恰恰是"两个消费者都最活跃"的模式，冲突概率最高。

### 1.2 第 5 级：图库失败会连带把 RLE 一起锁死

`rle_lba_vld` 的锁存条件里含 `gallery_done`（顶层 `:379`），而 `gallery_done` 只在 `G_DONE` 置位（`gallery_probe.v:453`），`G_FAIL` 只置 `fail`（`:454`）。所以：

```
图库 G_FAIL  ⇒  gallery_done 恒 0  ⇒  rle_lba_vld 恒 0  ⇒  rle_play_en 恒 0
```

顶层 `:396` 里 `(gallery_done || gallery_fail)` 这一项**救不了它**（它只作用于 `rle_play_en`，而 `rle_lba_vld` 已经是 0）。这条死锁路径在 `rtl/storage/fat32_reader.v` 的所有 FAT 层错误上都会命中（err=1 非 MBR、err=2 BPB/簇大小非法、err=3 簇链异常、err=5/7 读块失败）。特别地：**FAT16 卷的 `fat_size`（偏移 36）为 0 → `:365` 直接 err=2 → 图库 G_FAIL → 视频永久死**（本设计只支持 FAT32，`fat32_reader.v:360-386`）。

### 1.3 第 19 级：字幕被单拍脉冲门控（独立致命缺陷）

```
rtl/storage/image_player.v:74    output wire ext_frame_ready,   // 单拍：本帧已提交（vblank 翻页完成）
rtl/storage/image_player.v:258   ext_frame_ready_r <= 1'b0;     // 单拍脉冲，下面三处翻帧点置位
rtl/storage/image_player.v:296   if (vblank_rise) begin ... ext_frame_ready_r <= 1'b1; end
rtl/storage/image_player.v:576   assign ext_frame_ready = ext_frame_ready_r;
rtl/top/dmz_eg4s20_hdmi_top.v:1009   wire narr_on = m_science && rle_frame_ready && narr_frame_ok;
```

`rle_frame_ready` 是**每帧 1 个 `clk_pixel` 周期（40 ns）的单拍脉冲**，且置位点在 `vblank_rise`（`ext_vblank = scan_y >= 480`，顶层 `:635` 传 `vblank ? 10'd480 : active_y`）—— 即**垂直消隐期**。

⇒ `narr_on` 每帧高 40 ns、每秒高 5 次、占空比 2×10⁻⁷；且这 40 ns 落在 `de = 0` 区间，`video_overlay.v:318` `assign rgb_out = de ? rgb_mixed : 24'd0;` 直接输出黑。

⇒ **即使 §1.1 的总线问题全部修好、视频正常播放，中文字幕依然一个像素都不会出现。** 顶层 `:1000-1006` 的注释把 `rle_frame_ready` 当成"帧已上屏"的**电平**指标来用，实际它是**事件脉冲** —— 这是接口语义误用，不是参数调错。

同一条链上还有第二个坑：`narr_en` 一旦为 1 会**同时关掉标题行 + 状态行**两条静态 ASCII 带（`osd_caption.v:250/263` `title_band && !narr_en` / `state_band && !narr_en`），而 `narr_subline` 在 `frame_idx 0..3` 判假输出空白（`:183`）。顶层 `:984-998` 的注释正是为此把 `narr_frame_ok` 加进来 —— 方向对，但漏掉了"`rle_frame_ready` 是脉冲"这一点。

### 1.4 失败为什么完全静默

`rtl/control/err_prompt.v` 端口只有 `sd_*`、`gallery_*`、`image_*` 三组，**没有任何 `rle_*` 输入**。而顶层：

```
rtl/top/dmz_eg4s20_hdmi_top.v:510-511   wire [3:0] rle_err_code; wire rle_underrun;
rtl/top/dmz_eg4s20_hdmi_top.v:528       .err_code(rle_err_code), .underrun(rle_underrun)
```

`rle_err_code` / `rle_underrun` 在顶层**只声明、只接 u_rle 输出，零消费者**（全文件 grep 仅此两处 + 例化连线）。⇒ RLE 的 1=magic / 2=geometry / 3=像素数 / 4=块错 全部不上数码管、不上 LED、不鸣蜂鸣器。

同时 `err_prompt` 的优先级里没有 RLE，图库正常时数码管显示的是 `playback_state`：

```
rtl/top/dmz_eg4s20_hdmi_top.v:1248   wire [3:0] state_value = err_active ? prompt_hi : {1'b0, playback_state};
rtl/top/dmz_eg4s20_hdmi_top.v:857-872  科普模式（mode==1）+ image_ready + auto_play → ST_AUTO(4)
```

⇒ 现场读数是「4 = PLAY」，**看起来一切正常**。这是本问题最难定位的原因：失败被设计成了不可观测。

---

## 2. 带宽与帧率算术（回答"5 fps 能否达到"）

| 项 | 计算 | 结果 |
|---|---|---|
| SPI 时钟 | `sd_spi_ctrl.v:37` `SCK_FAST_DIV=1` → 25 MHz / (2×1) | **12.5 MHz** |
| SPI 裸带宽 | 12.5 Mbit/s ÷ 8 | **1.5625 MB/s** |
| SCI.RLE 总长 | 实测 `82362927 B`（631 帧，`MANIFEST.TXT` 亦记 82362927） | 78.55 MiB |
| 平均每帧字节 | 82362927 ÷ 631 | **130 528 B/帧** |
| 峰值帧字节 | `SCI.IDX` 帧 625 = 134787 B（帧 0 仅 3612 B，帧 2 已 86499 B） | 134 787 B |
| 5 fps 所需码率 | 130528 × 5 | **652 640 B/s = 0.653 MB/s** |
| 占 SPI 裸带宽 | 0.653 / 1.5625 | **41.8%** |
| 单块耗时 | 512 B @12.5 MHz = 4096 bit ÷ 12.5e6 = 0.328 ms，加 CMD17/响应/令牌/CRC/CS 约 15 B ≈ 0.010 ms | **≈ 0.34 ms** |
| 每帧块数 | 130528 ÷ 512 | **255 块** |
| 每帧总线占用 | 255 × 0.34 ms | **≈ 87 ms / 200 ms = 43.5%** |
| 整条文件读一遍 | 82362927 ÷ 1.5625e6 | **52.7 s** |
| 631 帧 @5 fps 播放时长 | 631 ÷ 5 | **126.2 s** |
| 音频（NARR.WAV） | 48 kHz × 16 bit × 1 ch = 96 KB/s；512 B/块 → 187.5 块/s × 0.34 ms | **63.8 ms/s = 6.4%** |
| 音视频合计占空 | 43.5% + 6.4% | **≈ 50%（2 倍余量）** |

**结论（问题 4）**：
1. `SCI.IDX` **在 RTL 中完全未被引用** —— 全仓 grep `IDX` 只命中 `rle_decoder.v:41` 与 `:99` 两处**注释**。解码器按 `blk_addr <= file_lba + blk_index`（`rle_decoder.v:684`）**顺序读整条文件流**，与 `gallery_probe.v:270-277` 的注释一致。IDX 只是 PC 端工具产物。
2. 52.7 s 是**把 631 帧全读一遍**的时间，不是每帧耗时。播放是流式的：每 200 ms 只需 130 KB，占空 43.5%。**5 fps 在带宽上完全可行**，带宽不是瓶颈。
3. 真正的节拍风险不在带宽，而在 `rle_decoder.v:497`：`R_IDLE: if (gap_tick && !blk_busy && !eof_stop)`。`gap_tick` 是**单周期脉冲**（`gap_sum >= CLK_HZ`，`:282-284`，25 MHz/5 fps = 每 5 000 000 拍一次），而 `blk_busy` 是**全局总线忙**。若这唯一一拍恰好撞上 WAV 的块事务（占空 6.4%），该次起帧被跳过、`gap_acc` 归零（`:402-404`），**整整再等 200 ms**。⇒ 约 6% 的帧会整体滑后一帧周期，平均帧率 ≈ 4.7 fps 且抖动明显。这不是"完全不工作"，但需要一起修（改成"待起帧"标志而不是单拍条件）。

---

## 3. 卡上素材核验（回答"SCI.RLE 真的在卡上吗"）

**仓库侧（亲测）**：`assets/v2/sdcard/BURN640/` 17 个文件齐全，含

```
SCI.RLE   82 362 927 B    640×480 RGB565 frames=631 fps=5
SCI.IDX       22 801 B    "ASCII frame offset table (tool only)"
NARR.WAV  12 106 244 B    48k/16bit/1ch, 126.106 s, loop=0
NARR.SRT       2 177 B    compile-time ROM source
NARR.IDX         498 B    ASCII cue timeline for OSD
IMG001-006.BMP  各 921 654 B  640×480 24bit BI_RGB
ALARM/BGM/BGM2/BGM3.WAV, TICKER.TXT(64 B), MANIFEST.TXT(1729 B)
```

`BURN640/MANIFEST.TXT` 自身声明：**"copy this directory CONTENT to FAT32 card root; layout: FLAT - root only"**。

**素材格式正确性（亲测）**：`SCI.RLE` 前 12 字节 = `53 43 4D 52 80 02 E0 01 B0 04 00 00` → magic `"SCMR"`、w=`0x0280`=640、h=`0x01E0`=480、run_count=`0x000004B0`=1200，与 `rle_decoder.v:40-41` 注释"Measured frame 0 … runs 0x000004B0 (1200)"**逐字吻合**。

**索引自洽性（亲测）**：`SCI.IDX` 633 行，帧 0 offset=0/3612 B、帧 1 offset=3612/45210 B、帧 2 offset=48822/86499 B、帧 625 offset=81798555/134787 B、帧 630 offset=82341513/21414 B。末帧结束 `82341513 + 21414 = 82362927` = 文件大小，**逐字节自洽**。⇒ **素材本身没坏。**

**⚠ 高危误操作（最可能的现场成因）**：`assets/v2/sdcard/RES640/` 里**只有 6 张 BMP + MANIFEST.TXT，没有 SCI.RLE / WAV / SRT**；`RES320/400/512/576` 同构。而 `assets/v2/sdcard/MANIFEST.TXT`（`# COUNT 63`、`# TOTAL 236577803`）是**全卡汇总清单**，把 BURN640、COMMON、RES320…640 全部列在一起。

⇒ 如果用户把 **RES640 目录**（名字带分辨率、看起来最像"要烧的素材"）拷进卡根，或者把 **BURN640 目录本身**（而不是它的内容）拷进卡根，卡上就**没有 SCI.RLE**。此时：

- `gallery_probe` 探 `SCI.RLE` 得 `f32_err=4`（没找到）→ `rle_found=0`、`rle_fail=0`（`gallery_probe.v:407-421`：err==4 不算故障）→ `G_DONE`
- 顶层 `:379` 锁存条件缺 `gallery_rle_found` → `rle_lba_vld` 恒 0 → `rle_play_en` 恒 0
- `u_rle` 被 `!play_en` 大复位按住（`rle_decoder.v:480-492`），连 `err_code` 都被清 0
- **数码管不报任何错**（§1.4），画面保持日常 BMP + 蓝条

**这与用户看到的现象 100% 吻合，且是零成本可验证的一条**（见 §6 现场自查步骤）。

---

## 4. 仿真证据（tb_rle_decoder 亲自复跑）

- 测试台：`sim/testbench/tb_rle_decoder.v`（904 行，`sim/scripts` 下**没有任何脚本引用它**，需手工 vlog/vsim）
- 工具：ModelSim ASE 10.1d（`D:\Quartus_APP\modelsim_ase\win32aloem\`）
- 复跑命令（工作目录 `D:\FPGA_Compelate\_t5_rle_check\run`，向量按 tb 相对路径铺到 `../testbench/vectors/`）：

```
vlib work
vlog -quiet -work work rtl/storage/rle_decoder.v sim/testbench/tb_rle_decoder.v
vsim -c -quiet -lib work -do "run -all; quit -f" tb_rle_decoder
```

- 实测输出（与历史记录 `sim/_t4_recheck/transcript` 逐字一致）：

```
PACING: measured=500 expected=500
LOAD: card_len=3612 gold_len=153600
FRAME0: groups=38400 beats=153600 word_errors=0
GRANT0: violations=0 addr=0 missing=0 waits=8 long_denials=8 low=259699 high=5489
FRAME1: groups=38400 beats=153600 word_errors=0
GRANT1: violations=0 addr=0 missing=0 waits=62 long_denials=60 low=547205 high=55296
HEADER: state=7 err_code=1
GRANT: latency=1 low_max=601 waits=65 long_denials=63
FRAME_DELAYED: groups=38400 beats=153600 word_errors=0
TB_RLE_DECODER SUMMARY: checks=58 errors=0
RESULT: PASS
$finish : tb_rle_decoder.v(893)   Time: 36089560 ns
```

**58 项断言，0 失败**；真实素材帧 0（1200 runs）与帧 1（15066 runs）逐字节 0 错。

**但这正是问题所在**：tb 把 `sd_grant` 恒接 1（或可控单源），**没有第二个 SD 消费者**，因此 §1.1 的 `blk_done` 误归属与 §2 的 `gap_tick && !blk_busy` 撞车**在 tb 里根本不可能暴露**。⇒ **解码算法与 ext 写口本身无缺陷；缺陷 100% 在顶层集成层。** 这也解释了为什么"RTL 仿真全过、上板全死"。

（附：更早的 `sim/_captain_rle/transcript` 里曾有 `GRANT_VIOLATION ... blk_start rose without sd_grant` ×4，是当时补 `blk_start = blk_start_int && sd_grant` 门控的由来；现行 `_t4_recheck` 的 `violations=0` 是修复后复测。说明这一带历史上已被"打地鼠"修过一次，但**归属门控这一课没补**。）

---

## 5. 根因判定与分级修复建议

### 5.1 根因判定

| 等级 | 根因 | 影响 | 证据 |
|---|---|---|---|
| **P0** | `rle_decoder.v:689` 的 `if (blk_done)` **无归属门控**，叠加顶层 `sd_blk_done` 广播 + NARR.WAV 竞争 ⇒ 误判后 `R_ERR` 永锁 | 视频**一帧都出不来** | §1.1；顶层 `:496-502` 自登记 |
| **P0** | `narr_on` 用 `rle_frame_ready`（**单拍脉冲，且落在消隐期**）作电平门控 | **字幕永远不显示**（与视频是否修好无关） | §1.3；`image_player.v:74/258/296/576` + 顶层 `:1009` |
| **P1** | 卡上缺 `SCI.RLE` 时 `rle_lba_vld` 恒 0，且**全链静默** | 视频/字幕全无，且无法自诊断 | §1.2、§1.4、§3 |
| **P1** | `rle_err_code` / `rle_underrun` **零消费者** | 所有 RLE 失败不可观测 | §1.4；`err_prompt.v` 无 `rle_*` 端口 |
| **P2** | 图库 `G_FAIL` 连带 `rle_lba_vld` 死锁（条件含 `gallery_done`） | FAT 层任何错误都会把视频一起锁死 | §1.2；顶层 `:379` vs `gallery_probe.v:453-454` |
| **P2** | `R_IDLE` 起帧被 `gap_tick`（单拍）&& `!blk_busy`（全局）联合门控 | 约 6% 帧滑后 200 ms，帧率 4.7 fps + 抖动 | §2；`rle_decoder.v:497,402-404` |
| **P3** | `R_ERR` 永不自愈（只有 `!play_en` 能退出） | 一次瞬态错误 = 永久黑屏 | `rle_decoder.v:716-720` |
| **P3** | `SCI.RLE` 必须**物理连续**（`blk_addr = file_lba + blk_index`，不走簇链） | 文件碎片化 → magic 失败 → 永久黑屏 | `rle_decoder.v:684`；`gallery_probe.v:270-277` 注释 |
| **P3** | `image_player` 的 `ext` 写口**不更新 `scale_w/scale_h/scale_off_*`** | 视频帧按"上一次 BMP 缩放器输出"的窗口显示 | `image_player.v:277-280` 取 `scale_*`；`:452-455` `out_w/h/off` 取 `display_*` |

> 关于最后一条：`ext_wr_mode` 只写帧缓存、不写 `display_w/h/off_x/y`（那是 `scale_w/h/off_*` 的镜像，由 BMP 缩放器产生）。科普模式下 BMP 装载被冻结（`image_player.v:167` `bmp_load_req = load_req && !ext_wr_mode`），所以 `scale_*` 停在日常模式最后一张图的值。若日常图是"带黑边自适应缩放"的结果，视频帧会沿用同一套窗口/偏移 —— 这是现象⑤（黑边）与现象②（像素偏移）在科普模式下的连带来源，修 RLE 通路时需一并确认。

### 5.2 分级修复建议（供后续修复任务使用，本任务不改）

**P0-a 给 `rle_decoder` 补归属门控**（最小改动、最高收益）
- 在 `rle_decoder.v` 增加 `reg my_blk_active;`：`:682-688` 发出请求时置 1，`:689` 收到自己的 `blk_done` 时清 0。
- 把 `:689` 改成 `if (blk_done && my_blk_active)`，`:696` 改成 `else if (blk_err && my_blk_active)`。
- 与 `wav_stream_player.v:210/335-336/344-345` 的既有写法保持一致（同仓已有范式，审查时好对齐）。
- 更彻底的做法：顶层把 `sd_blk_done`/`sd_blk_err`/`sd_dvalid` 也做成**按 owner 门控**再分发（`sd_owner_*` 已经存在，`&` 一下即可），这样一次修好五个消费者。但这会动顶层与四个模块的连线，建议作为 P0-a 的后续加固，不要和首次修复混在一起。

**P0-b 修 `narr_on` 的语义**
- 顶层用一个"帧已上屏"的**电平/粘滞位**替换 `rle_frame_ready`，例如
  `reg rle_live; if (rle_frame_ready) rle_live <= 1'b1; if (!rle_play_en) rle_live <= 1'b0;`
  然后 `narr_on = m_science && rle_live && narr_frame_ok;`
- 注意保持 `:984-998` 注释里的两个约束：① `frame_idx 0..3` 期间必须为 0（否则标题/状态行被关掉、字幕还没有 → 整层全黑）；② 只能在真正翻过至少一帧之后为 1（否则"字幕在跑、画面还是上一张图"）。
- 同时必须确认 `narr_subline` 那块 BRAM 没被常量传播剪掉（`#bram` 应从 34 涨到 35）。

**P1-a 让 RLE 失败可观测**
- 给 `err_prompt` 增加 `rle_err[3:0]` / `rle_underrun` 输入，映射到一组新的助记（如 `4'hE` = 视频错误，配 `1..4` 子码），优先级放在 `image_failed` 之后。
- 或者低成本方案：把 `rle_err_code` 接到 LED / 数码管的备用段（顶层 `:1238-1252`），至少让"卡上没视频"和"解码失败"可区分。

**P1-b 卡上素材自查（零代码改动）**
- 现场确认 SD 卡**根目录**下直接有 `SCI.RLE`（82 362 927 B）、`NARR.WAV`（12 106 244 B）、`IMG001.BMP`…，而不是 `BURN640\SCI.RLE` 或 `RES640\...`。
- 确认卷是 **FAT32**、簇大小 2 的幂（FAT16/exFAT 直接 err=2）。
- 确认 `SCI.RLE` **物理连续**（素材脚本写入时应保证；若用户手工拷入后做过删除/整理，可能被碎片化 → magic 失败）。

**P2 解除图库→视频的死锁**
- 顶层 `:379` 的锁存条件去掉 `gallery_done` 的强依赖，改为"RLE 探测轮结束即可"（`gallery_probe` 已有 `rle_phase` 完成的语义），或让 `G_FAIL` 时也置 `done`。

**P2 修起帧节拍**
- `rle_decoder.v:497` 改成"待起帧"标志：`gap_tick` 只置 `frame_pending`，`R_IDLE` 里 `if (frame_pending && !blk_busy)` 再起帧，避免被总线忙吞掉整整一个帧周期。

**P3 让 `R_ERR` 可自愈**
- `R_ERR` 里加"重试计数 + 回到 `R_IDLE`"（或至少在 `play_en` 仍为 1 时每 N 帧重试一次），避免一次瞬态错误导致永久黑屏。

---

## 6. 科普模式「应该长什么样」与当前缺失项（问题 5）

| 要素 | 设计要求 | 当前状态 | 卡在哪一级 |
|---|---|---|---|
| 视频（RLE 631 帧 @5 fps 循环） | 全屏 640×480 RGB565 动画 | **完全没有**（显示的是日常 BMP） | 甲情形：第 5 级 `rle_lba_vld`；乙情形：第 12 级 `blk_done` 误归属 → 第 13 级 `R_ERR` |
| 中文字幕（NARR.SRT → narr_subline，18 段，帧 4..624） | 随视频帧号切换的 2 行字幕 | **完全没有** | 第 19-21 级：`narr_on` 被单拍脉冲门控（**独立缺陷，与视频无关**） |
| NARR 音频（NARR.WAV 126.1 s） | 科普讲解音 | 源已选中（`audio_src_mux.v:70`），文件在 BURN640 包内 | 若卡上缺 `NARR.WAV` → `wav_stream_player` 定位失败；否则应能播（与现象①"科普没声音"同源，属另一任务范围） |
| 蓝条（模式标记） | 顶部 8 行 + 左上 24×24 方块，`00C8E0` | **正常显示** ✅ | — |
| 标题行 / 状态行 | 科普模式下**故意关闭**（让位给视频字幕） | 已关闭（`osd_caption.v:250/263`） | 设计如此 |

**净结论**：科普模式现在只有"蓝条 + 上一张日常 BMP"，**视频、字幕、NARR 音频三样全部缺失**；其中视频与字幕是两条**互相独立**的致命缺陷，必须分别修，不能指望修好一条另一条就好了。

---

## 7. 现场快速自查（用户可执行，按信息量排序）

1. **看 SD 卡根目录**：是否有 `SCI.RLE`（约 78.5 MB）？若只有 `IMG00*.BMP`，说明拷错了目录（应把 `BURN640/` 的**内容**拷到卡根，不是把 `BURN640` 或 `RES640` 目录拷进去）。→ 若如此，这是本次现象最可能的直接成因。
2. **看卡的文件系统**：必须是 FAT32、簇大小 2 的幂（Windows 格式化默认 exFAT，**不行**）。
3. **看数码管**：科普模式下若显示 `4`（PLAY）而不是任何 `d*`/`F*`/`b*` 错误码 —— 说明错误被 §1.4 吞掉了，不能据此判定"一切正常"。
4. **切模式观察**：日常→科普，若画面内容完全不变（只多蓝条），说明 `front_sel` 从未被 RLE 翻动 = 视频帧从未提交（本报告的核心结论）。

---

## 8. 附：本次诊断的取证清单（可复核）

- 源码：`rtl/top/dmz_eg4s20_hdmi_top.v`（1256 行，85825 B，mtime 2026-11-02 18:30:36，诊断期间未改动）、`rtl/storage/rle_decoder.v`（750 行）、`rtl/storage/image_player.v`（628 行）、`rtl/storage/gallery_probe.v`、`rtl/storage/fat32_reader.v`、`rtl/storage/sd_spi_ctrl.v`、`rtl/storage/sd_probe.v`、`rtl/audio/wav_stream_player.v`、`rtl/audio/audio_src_mux.v`、`rtl/video/video_overlay.v`、`rtl/video/video_content_mux.v`、`rtl/osd/osd_caption.v`、`rtl/osd/narr_subline.v`、`rtl/control/err_prompt.v`、`rtl/control/key_router.v`、`rtl/control/mode_ctrl.v`
- 素材：`assets/v2/sdcard/BURN640/{SCI.RLE,SCI.IDX,MANIFEST.TXT,NARR.WAV}`、`assets/v2/sdcard/MANIFEST.TXT`、`assets/v2/sdcard/RES640/`
- 仿真：`sim/testbench/tb_rle_decoder.v` + `sim/testbench/vectors/sci_f{0,1}_640x480.hex`、`sci_f{0,1}_words.hex`；复跑产物在 `D:\FPGA_Compelate\_t5_rle_check\`
- 同步性提醒：`project/hdmi/image_player.v`(11-02 18:27) 与 `project/hdmi/pix_reader.v`(11-02 14:29) **落后于** `rtl/` 下的同名文件（11-03 08:28 / 09:51）；位流在 `project/hdmi_td_Runs/{best_result,phy_1}/hdmi_td.bit`。修复后必须重新综合，且要确认烧的是新位流。
