# ARCH — v2 系统架构书

> 文件：`docs/plan_v2/ARCH.md`
> 版本：v2.0 · 2026-11-01 · 作者：architect
> 上游：`docs/plan_v2/PLAN.md`（主计划书）、`reports/plan_v2/SPEC_CONSTRAINTS.md`、`reports/plan_v2/REQ_GAP.md`
> 下游：`docs/plan_v2/KEYMAP.md`、`docs/plan_v2/RESOURCE_BUDGET.md`
> 本文职责：给出**模块划分、端口契约、接口时序、像素通路、数据流与仲裁**，使 RTL 编码可以逐模块直接落地，无需再问设计问题。

---

## 0. 架构总览（一句话）

**以「三模式状态机」为唯一模式权威，以「像素几何映射 + 亮度后置」为核心像素通路改造，以「SD 四路仲裁 + RLE/WAV 双流」为存储子系统，以「传感器无关的阈值迟滞联动层」为应急触发，全部在既有 25 MHz / 40 MHz / 125 MHz 三时钟域内完成，零新增 PLL、零新增 DSP。**

---

## 1. 顶层数据流总图

```
                       ┌──────────────────────────────────────────────┐
                       │            clk = 50 MHz (R7)                 │
                       │   u_pll (hdmi_pll)      u_sdram_pll          │
                       │   VCO=1000MHz           VCO=800MHz           │
                       │   C0=25MHz(像素)        C0/C1=40MHz(SDRAM)   │
                       │   C2=125MHz(串化)       C2=200MHz(SDRAM串化) │
                       └──────────────────────────────────────────────┘

  ┌─────────── 输入域 (25 MHz) ────────────────────────────────────────────┐
  │  key_row[3:0] ──► u_key (key_matrix_4x4) ──► key_event / key_code[3:0] │
  │                                                    │                   │
  │                     ┌──────────────────────────────┼─────────────┐     │
  │                     ▼                              ▼             ▼     │
  │            u_mode_ctrl          u_key_router     u_media_player        │
  │            (Key2/Key3)          (Key4~Key15)     (Key0/Key1)           │
  │                │ mode[1:0]          │ 参数总线        │ img_index       │
  │                │ emerg_latched      │                │                 │
  │                └────────┬───────────┴────────────────┘                 │
  │                         ▼                                              │
  │              ┌──────────────────────┐    ┌───────────────────────┐     │
  │   AHT20 ────►│ u_aht20_ctrl         │───►│ u_temp_hyst_link      │     │
  │  SCL=D1      │ u_i2c_master(100kHz) │    │ (阈值→迟滞→联动，      │     │
  │  SDA=E1      │ 0xBE/0x71/0xAC       │    │  与传感器无关)         │     │
  │              └──────────────────────┘    └───────────┬───────────┘     │
  │  [Plan B] NTC ┄┄► u_sar_adc_wrap ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┘                 │
  │                                                       │ temp_alarm    │
  │                                                       ▼                │
  │                                              (并入 mode_ctrl 的应急触发)│
  └────────────────────────────────────────────────────────────────────────┘

  ┌─────────── 存储域 (25 MHz 主机 + 40 MHz SDRAM) ────────────────────────┐
  │                                                                        │
  │  SD 卡 (SPI 12.5 MHz)                                                  │
  │    │                                                                   │
  │    ▼                                                                   │
  │  u_sd (sd_spi_ctrl) ── 单一读块端口 blk_start/blk_addr/blk_done/data    │
  │    │                                                                   │
  │    ▼                                                                   │
  │  ┌──────────────── SD 四路独热仲裁 (sd_owner_*) ─────────────────┐     │
  │  │ 优先级: ①音频 ②视频 ③图库扫描 ④图片装载                        │     │
  │  └───┬──────────┬──────────────┬──────────────┬─────────────────┘     │
  │      ▼          ▼              ▼              ▼                        │
  │  u_wav_      u_rle_         u_gallery      u_img_loader               │
  │  stream_     decoder        _probe         (→ u_bmp_parser            │
  │  player      (RLE→RGB565)                  → u_img_scaler)            │
  │      │            │                                                    │
  │      │            ▼                                                    │
  │      │      u_framebuf_arbiter ◄──► u_sdram_ctrl_wrap (40MHz)          │
  │      │            │                                                    │
  │      │            ▼                                                    │
  │      │      u_pix_reader (→ async FIFO → 25MHz)                        │
  │      ▼                                                                 │
  │  audio FIFO (25↔40MHz CDC)                                             │
  └────────────────────────────────────────────────────────────────────────┘

  ┌─────────── 像素域 (25 MHz, 恒定 640×480@59.52Hz) ──────────────────────┐
  │                                                                        │
  │  u_vtg (video_timing_gen)                                              │
  │    └─► de / active_x[10:0] / active_y[9:0] / hs / vs / frame_start      │
  │                              │                                         │
  │                              ▼                                         │
  │   ┌────────────────────────────────────────────────────┐               │
  │   │ u_image_player (SDRAM 读 RGB565)                   │               │
  │   │   内部 u_pix_reader 垂直行映射 ◄── res_sel         │               │
  │   │   帧基址 A/B 双缓冲；换帧只在 vblank               │               │
  │   │   欠载时保持上一帧（不插黑）                       │               │
  │   └──────────────────────────┬─────────────────────────┘               │
  │                              ▼                                         │
  │   ┌────────────────────────────────────────────────────┐               │
  │   │ u_mosaic (pix_mosaic, 新增) ◄── res_sel            │               │
  │   │   读出侧【水平】抽样：Bresenham + hold             │               │
  │   │   src_w=640 时恒等旁路（零延迟直通）               │               │
  │   └──────────────────────────┬─────────────────────────┘               │
  │                              ▼                                         │
  │   ┌────────────────────────────────────────────────────┐               │
  │   │ u_image_mask ◄── ratio_sel (Key9)                  │               │
  │   │   门控【内容层】pixel_valid（图片+视频）           │               │
  │   │   应急平面图【除外】                               │               │
  │   │   屏占比 1/2·5/8·3/4·7/8·1                         │               │
  │   └──────────────────────────┬─────────────────────────┘               │
  │                    ▼  image_rgb + image_pixel_valid                    │
  │   ┌────────────────────────────────────────────────────┐               │
  │   │ u_content_mux  mode[1:0] 选源                      │               │
  │   │   ◄── 内容层（图片或视频，已门控）                 │               │
  │   │   / 测试图 / 应急图                                │               │
  │   └──────────────────────────┬─────────────────────────┘               │
  │                              ▼                                        │
  │   ┌──────────────────────────────────────────────────────────┐        │
  │   │ u_overlay (video_overlay)                                 │        │
  │   │   · invert_en / grid_en / info_en（P2）                    │        │
  │   │   · level_en（D-03 停用，固定 1'b0）                      │        │
  │   │   · wave_en ◄── viz_en (Key10)                            │        │
  │   │   · caption_en ◄── ticker_en_eff (Key5)                   │        │
  │   │   · bright_sel ◄── bright_lvl[2:0]，【仅】点亮信息条第       │        │
  │   │     8/9/10 三格；内部 5 档衰减运算已移除（防二次衰减）        │        │
  │   └──────────────────────────┬───────────────────────────────┘        │
  │                              ▼                                        │
  │   ┌──────────────────────────────────────────────────────────┐        │
  │   │ u_brightness_apply  ◄── bright_lvl[3:0] (Key6, 10 档)      │        │
  │   │   【位置关键】overlay 之后、osd_panel 之前；纯组合零寄存器   │        │
  │   └──────────────────────────┬───────────────────────────────┘        │
  │                              ▼                                        │
  │   ┌──────────────────────────────────────────────────────────┐        │
  │   │ u_osd_panel (osd_panel)  ◄── u_osd_autopop 参数自动弹出     │        │
  │   │   面板文字不参与亮度衰减（信息可读性）                       │        │
  │   └──────────────────────────┬───────────────────────────────┘        │
  │                              ▼                                        │
  │   u_axis (video_rgb_to_axis) ──► u_hdmi_core ──► u_phy ──► HDMI       │
  └────────────────────────────────────────────────────────────────────────┘

  ┌─────────── 音频域 ─────────────────────────────────────────────────────┐
  │                                                                        │
  │  音源三选一:                                                           │
  │    ① u_tone (audio_tone_gen)  状态提示音（IDLE/SCAN/READY/AUTO/EMERG/FAIL）│
  │    ② u_wav_stream_player      SD 卡 WAV 流（48kHz/16bit/单声道）        │
  │    ③ 静音                                                              │
  │         │                                                              │
  │         ▼                                                              │
  │   u_vol_apply  ◄── vol_lvl[3:0] (Key7, 10 档) + mode 钳位              │
  │         │                                                              │
  │         ├──► u_pcm_to_pwm ──► audio_pwm (F3) ──► 板载功放              │
  │         ├──► u_audio_arc (ACR) ──► HDMI 音频包                          │
  │         └──► u_audio_waveform ◄── viz_en (Key10) ──► 波形图层           │
  │                                                                        │
  │   u_buzz (buzzer_tone) ◄── tone_sel ◄── beep_muted (Key15, P2)         │
  └────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 三模式状态机（`rtl/control/mode_ctrl.v`）

### 2.1 状态定义

| 编码 | 状态 | 语义 | 画面源 | 音频源 | 字幕源 |
|---|---|---|---|---|---|
| `2'd0` | `S_DAILY` | 日常展示 | SD 图库循环（`image_player`） | WAV 背景音乐（若无则状态音） | 校园介绍滚动字幕 |
| `2'd1` | `S_SCIENCE` | 科普展示 | SD RLE 视频序列帧（`rle_decoder` 解码写入，像素**经 `image_player` 的图片路输出端口**上屏） | WAV 解说音频 | **科普视频字幕（`narr_subline.v`，`frame_idx` 驱动的 ROM 表，18 段，见 §9.4）**；静态三条 ASCII 带由 `narr_en` 关闭 |
| `2'd2` | `S_EMERG` | 应急发布 | **应急平面示意图（`emerg_page`，FPGA 内实时栅格化，零 SD 依赖）** + 大字提示 | 警报音（`siren`）+ 强制开 | 锁定提示字幕（**锁定，不可关**；措辞按 `SAFETY_WORDING_RULING.md` A 类） |

### 2.2 状态转移表

| 当前态 | 事件 | 条件 | 次态 | 附带动作 |
|---|---|---|---|---|
| `S_DAILY` | Key2 `key_event` | `key_code == 4'd2` 且非应急 | `S_SCIENCE` | `img_index` 保持；启动视频流；`osd_pop_req` |
| `S_SCIENCE` | Key2 `key_event` | `key_code == 4'd2` | `S_DAILY` | 停止视频流；恢复图库循环 |
| `S_DAILY` | Key3 `key_event` | `key_code == 4'd3` | `S_EMERG` | **立即锁存** `emerg_latched <= 1` |
| `S_SCIENCE` | Key3 `key_event` | `key_code == 4'd3` | `S_EMERG` | 同上 |
| `S_DAILY` | `temp_alarm` 上升沿 | 温度 ≥ 阈值且迟滞计数满足 | `S_EMERG` | 同上 + `emerg_src <= SRC_TEMP` |
| `S_SCIENCE` | `temp_alarm` 上升沿 | 同上 | `S_EMERG` | 同上 |
| `S_EMERG` | **Key3 `key_event`** | `emerg_confirm_window` 满足（见 §2.4） | `S_DAILY` | 清 `emerg_latched`；**强制回到日常**（不回科普） |
| `S_EMERG` | 其他任何按键 | — | `S_EMERG` | 全部忽略（除 Key6/7/8/9/10 的视觉参数） |
| `S_EMERG` | 温度回落 | **不自动退出** | `S_EMERG` | 见 §2.3 迟滞设计 |
| `S_EMERG` | 复位 `rst_n` | — | `S_DAILY` | — |

**关键设计决策 1 · 应急优先且锁存**：`emerg_latched` 一旦置位，**只有 Key3 显式确认才能清除**。温度回落**不自动退出**，因为「警报响过后自己停了」在现场是极危险的信号（用户会以为故障已排除）。

**关键设计决策 2 · 退出必须回日常**：应急退出后**强制回 `S_DAILY`**，不回 `S_SCIENCE`。理由：应急前若在科普模式，视频流已被打断（SDRAM 缓冲被应急画面占用），回科普需要重新装载，会有数秒黑屏；回日常可立即出图。

### 2.3 温度迟滞设计（`temp_hyst_link.v`，与传感器无关）

| 参数 | 值 | 说明 |
|---|---|---|
| `TEMP_HIGH_C` | **45 ℃**（`16'd450`，0.1 ℃ 单位） | 触发阈值。工业级 FPGA 环境上限 85 ℃，但校园终端机箱内 45 ℃ 已属异常 |
| `TEMP_LOW_C` | **40 ℃**（`16'd400`） | 回落阈值，与触发阈值差 5 ℃ |
| `HYST_CNT_UP` | **3 次连续读数** | 触发需连续 3 次超阈值（测温周期 1 s → 3 s 确认），抗单次毛刺 |
| `HYST_CNT_DN` | **5 次连续读数** | 回落需连续 5 次低于阈值（5 s），更保守 |
| `MEAS_PERIOD` | **1 s** | AHT20 测温周期（芯片本身支持 ≥ 2 Hz） |

**迟滞状态机**（`temp_hyst_link.v` 内部，三态）：

| 状态 | 语义 | 转移条件 |
|---|---|---|
| `H_NORMAL` | 正常，`temp_alarm = 0` | `temp_now > TEMP_HIGH_C` 且 `cnt_up == 3` → `H_ALARM` |
| `H_ALARM` | 报警，`temp_alarm = 1` | `temp_now < TEMP_LOW_C` 且 `cnt_dn == 5` → `H_COOLING` |
| `H_COOLING` | 已回落但未清锁存，`temp_alarm = 0` | `temp_now > TEMP_HIGH_C` 且 `cnt_up == 3` → `H_ALARM`（重新报警） |

**注意**：`H_COOLING` 的 `temp_alarm = 0` 但 `mode_ctrl` 的 `emerg_latched` **仍为 1**。也就是说：**温度回落只关掉「再次触发」的条件，不解除应急锁存**。解除锁存唯一路径 = Key3 确认。这符合 §2.2 的决策 1。

### 2.4 应急退出确认窗口

**设计**：在 `S_EMERG` 下按 Key3，不是立即退出，而是启动一个 **2 s 确认窗口**：

| 阶段 | 行为 |
|---|---|
| 第 1 次按 Key3 | `confirm_armed <= 1`，`confirm_timer <= 2s`；OSD 显示「再按一次确认退出应急」 |
| 窗口内（2 s）第 2 次按 Key3 | 退出到 `S_DAILY` |
| 窗口超时（2 s 无第 2 次） | `confirm_armed <= 0`，仍留 `S_EMERG` |

**理由**：应急状态下的一次误触不应解除警报。这是「锁存」语义的完整实现 —— 进入零延迟（不设确认），退出需双重确认（防误触）。

**答辩口径**：「应急进入是即时的（Key3 或高温自动），退出需要连按两次确认，且温度回落不会自动解除 —— 这是**告警类人机交互的通用惯例**：进入零延迟、退出需消抖。」

### 2.5 `mode_ctrl.v` 端口契约

```verilog
module mode_ctrl #(
    parameter CLK_FREQ_HZ   = 25_000_000,
    parameter CONFIRM_MS    = 2000,       // 应急退出确认窗口
    parameter TEMP_HIGH_0C1 = 16'd450,    // 45.0 ℃
    parameter TEMP_LOW_0C1  = 16'd400,    // 40.0 ℃
    parameter HYST_CNT_UP   = 4'd3,
    parameter HYST_CNT_DN   = 4'd5
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_event,
    input  wire [3:0]  key_code,
    input  wire        temp_alarm,      // 来自 temp_hyst_link（已含迟滞）

    output reg  [1:0]  mode,            // 0=日常 1=科普 2=应急
    output reg         emerg_latched,   // 应急锁存标志（调试/OSD 用）
    output reg  [1:0]  emerg_src,       // 0=无 1=按键 2=温度
    output reg         confirm_armed,   // 应急退出确认已武装
    output reg         mode_changed     // 单拍：模式变化（供 OSD 与视频流启停）
);
```

**接口时序约定**：
- `key_event` 为单拍脉冲；`key_code` 在 `key_event` 当拍有效。
- `mode` 在 `key_event` 后**同一拍**更新（`clk` 上升沿），下游在下一拍可见。
- `mode_changed` 是**单拍脉冲**，在 `mode` 变化的同一拍置高。
- `temp_alarm` 是电平信号（非脉冲），来自 `temp_hyst_link`，已含 3/5 次迟滞。`mode_ctrl` 只需检测其**上升沿**。
- 全部输出异步复位到 `mode = 2'd0`、`emerg_latched = 0`。

---

## 3. 五档分辨率方案（N1：内部渲染分辨率 + 固定输出时序）

### 3.1 为什么必须走 N1

**硬约束链**（逐条来自实测）：

1. `rtl/video/hdmi/hdmi_pll.v` 当前 `DYNCFG="DISABLE"`、`FEEDBK_PATH="CLKC0_EXT"`、`CLKC0_DIV=40`，**只输出 25 MHz 单档**。TD 的 `EG_PHY_PLL` 原语**不支持运行时动态重配置分频**（无 DYNCFG 接口时）。
2. 要切像素时钟必须**重配置 PLL** → 重锁定（数百 μs 至数 ms）→ HDMI 链路失锁 → 显示器黑屏重同步。用户会看到闪黑，**体验不可接受**。
3. `hdmi_pll.v` 文件头已注明：25.175 MHz 无法由 50 MHz 整数分频得到（所需 VCO 超芯片上限 ~1200 MHz），故取 25 MHz，偏差 0.7%，场频 59.58 Hz。
4. 高分辨率候选全部超限：
   - 800×600@60 需 40 MHz 像素时钟 → VCO 需 1200 MHz（**恰在上限临界**，且串化需 200 MHz）
   - 1024×768@60 需 65 MHz → **双重超限**
   - 1280×720@60 需 74.25 MHz → **双重超限**
5. 芯片共 4 颗 PLL，已用 2 颗（`hdmi_pll` + `sdram_pll`）。**新增第 3 颗 PLL 也解决不了** —— 问题不是 PLL 数量，是「切换时必然重锁定」。

**结论：N1 是唯一物理可行解。** Key8 切的是**内部渲染分辨率**，HDMI 输出时序**恒定 640×480@59.52 Hz / 25 MHz**。

### 3.2 五档取值表（可直接翻成 Verilog parameter）

```verilog
// 落点：水平抽样在 rtl/video/pix_mosaic.v（读出侧），垂直行映射在 rtl/storage/pix_reader.v
// 两者共用同一张 res_sel → src_w/src_h 译码表（下表的 src_w/src_h 数值全部保留不变）
localparam [2:0] RES_SEL_MAX = 3'd4;
// res_sel : src_w, src_h, scale_num, scale_den（放大比 = scale_num/scale_den）
// res_sel=0: 320×240, 2/1
// res_sel=1: 400×300, 8/5
// res_sel=2: 512×384, 5/4
// res_sel=3: 576×432, 10/9
// res_sel=4: 640×480, 1/1（旁路）
```

| `res_sel` | 内部渲染分辨率 | 放大比 | `src_w` | `src_h` | 水平步进（DDA 增量） | 垂直步进 | 相对 640×480 的数据量 |
|---|---|---|---|---|---|---|---|
| `3'd0` | 320×240 | 2.00× | 320 | 240 | `+0.5` 源像素/输出像素 | `+0.5` | 1/4 |
| `3'd1` | 400×300 | 1.60× | 400 | 300 | `+0.625` | `+0.625` | 0.391 |
| `3'd2` | 512×384 | 1.25× | 512 | 384 | `+0.8` | `+0.8` | 0.64 |
| `3'd3` | 576×432 | 1.111× | 576 | 432 | `+0.9` | `+0.9` | 0.81 |
| `3'd4`（默认） | **640×480** | **1.00×（旁路）** | **640** | **480** | `+1.0` | `+1.0` | **1.0** |

**五档全部 4:3**，全部由 640×480 的简单分数缩放得到（1/2、5/8、4/5、9/10、1），**分母均为小整数**，DDA 累加器可实现。

### 3.3 为什么不用 426×320

队长裁决 A 曾建议 426×320。**本文档改为 400×300，理由**：

- 426×320 **不是 4:3**（426/320 = 1.3313，标准 4:3 = 1.3333，偏差 0.15%），放大到 640×480 会产生**非均匀像素宽度**（前 213 列每列 1.5 像素，后 213 列每列 1.5 像素，但中间有取整误差累积），出现**可见的列宽不均**。
- 400×300 **是标准 4:3**（400/300 = 1.3333 精确），放大比 1.6 = 8/5，DDA 增量 `0.625 = 5/8`，**精确无累积误差**。
- 400×300 与 426×320 的数据量差异 < 2%，**视觉收益远大于代价**。

**这是对队长建议的微调，理由已写明，非擅自改动。**

### 3.4 端口契约：读出侧抽样放大（`pix_mosaic.v` + `pix_reader` 行映射）

> **本节已按 `ARCH_ADDENDUM_VIDEO_PATH.md` §8.1 / §9.1 / §9.2 整体替换。**
> v1 曾设计 `video_geom_map.v` 输出 `src_x/src_y` 送给三个源模块 —— **该连线在现 RTL 中不存在且不该存在**：
> `image_player` 端口表（`rtl/storage/image_player.v:20-46`）没有 `src_x/src_y` 输入，像素输入侧只有 `de` 与 `scan_y[9:0]`；
> `pix_reader` 是流式预取（`LEVEL_HI=768` 水位、`RD_GROUP_CYCLES=13` 组首间隔），按任意 `src_x` 跳读会打断行预取、SDRAM 行缓冲命中率暴跌。
> **v2 改为「读出侧抽样」两条独立机制，合计 +70 LUT（原估 +220，省 150）。**

**（1）水平：`rtl/video/pix_mosaic.v`（新，约 40 LUT，纯组合 + 1 个保持寄存器）**

```verilog
module pix_mosaic #(
    parameter H_ACTIVE = 11'd640,
    parameter V_ACTIVE = 10'd480
)(
    input  wire        pixel_clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [10:0] active_x,       // 输出域列坐标 0~639
    input  wire [15:0] src_w,          // 当前档源宽：320/400/512/576/640
    input  wire [15:0] rgb565_in,
    input  wire        valid_in,
    output reg  [15:0] rgb565_out,
    output wire        valid_out
);
```

**接口时序约定**：

- `valid_out` 是 `valid_in` 的**直通**（`assign valid_out = valid_in;`），不引入任何拍延迟；`rgb565_out` 与 `rgb565_in` **同拍**。
- **行内 Bresenham**：
  ```
  行首（active_x == 0）：x_acc <= 0;  hold <= rgb565_in;
  行内每拍：  x_acc <= x_acc + src_w;
             if (x_acc >= 640) begin x_acc <= x_acc - 640; hold <= rgb565_in; end
             rgb565_out <= hold;
  ```
  当 `src_w == 640` 时每拍都满足 `640 >= 640` → `hold` 每拍更新 → **恒等旁路，零画质损失**。
- `src_w ∈ {320, 400, 512, 576, 640}` 全部合法（分别每 2 / 1.6 / 1.25 / 1.111 / 1 拍更新一次 `hold`）。
- **`disp_mode == 2'd2`（应急）时由顶层把 `src_w` 强制为 `640`** → 恒等旁路（§7.4 的钳位）。

**（2）垂直：`rtl/storage/pix_reader.v` 行映射（+30 LUT，新增 2 个端口）**

```verilog
// 追加到端口表
    input  wire [15:0] src_w,      // 当前档源宽（只用于垂直方向的行映射索引）
    input  wire [15:0] src_h       // 当前档源高：240/300/384/432/480
```

**改动点只有一处**：行地址生成加垂直 Bresenham —— 仅当 `y_acc + src_h >= 480` 时才真正推进一行并从 `y_acc` 中扣除 480，否则**重复读同一源行**；`new_frame` 时 `y_acc <= 0`。

- **状态机、FIFO、`P_*` 六个状态、`LEVEL_HI` / `RD_GROUP_CYCLES` 全部零改动**。
- `src_h == 480` 时 `y_acc + 480 >= 480` 恒成立 → 每行推进一次 → **恒等旁路**。
- **读带宽不变**：仍按 640×480 全尺寸读出（重复行是重复读），SDRAM 侧带宽 36.86 MB/s 已含此量级，实测占用 24.96%。

### 3.5 几何稳定策略

| 风险 | 处置 |
|---|---|
| 切档瞬间画面撕裂 | `res_sel` 变化只在**下一帧起始**（`frame_start`）生效；本帧继续用旧 `src_w/src_h` |
| Bresenham 累加器跨帧残留 | 每帧 `frame_start` 强制 `x_acc <= 0, y_acc <= 0`（`pix_mosaic` 与 `pix_reader` 各自清自己那个） |
| 切档时 SDRAM 读地址跳变 | `pix_reader` 的 `rd_base` 不变（帧基址与分辨率无关），仅行内步进变化 |
| 显示器看到时序抖动 | **不可能** —— 输出时序恒定，`video_timing_gen` 参数不变 |

### 3.6 答辩口径（一句话）

> 「Key8 切换的是**内部渲染分辨率**，HDMI 输出始终是 640×480@60Hz。这是主动选择：TD 的 PLL 不支持运行时重配置，切真实像素时钟会导致 HDMI 失锁闪黑。所以我们把分辨率做成渲染档位，用**读出侧抽样放大**（水平 `pix_mosaic` + 垂直 `pix_reader` 行映射）拉回 640×480 —— 这套机制**非整数倍也支持**（400×300 是 1.6×、576×432 是 1.111×），用户看到的是画质变化，不是黑屏。」

---

## 4. 五档屏占比（`rtl/video/image_window_mask.v` 复用 + `ratio_map`）

### 4.1 取值表

```verilog
// ratio_sel → win_w, win_h, win_off_x, win_off_y（全部整数，等比居中）
// 0: 1/2  → 320×240, off(160,120)
// 1: 5/8  → 400×300, off(120, 90)
// 2: 3/4  → 480×360, off( 80, 60)
// 3: 7/8  → 560×420, off( 40, 30)
// 4: 1    → 640×480, off(  0,  0)  ← 默认满屏
```

| `ratio_sel` | 占比 | `win_w` | `win_h` | `win_off_x` | `win_off_y` | 面积占比 |
|---|---|---|---|---|---|---|
| `3'd0` | 1/2 | 320 | 240 | 160 | 120 | 25.0% |
| `3'd1` | 5/8 | 400 | 300 | 120 | 90 | 39.1% |
| `3'd2` | 3/4 | 480 | 360 | 80 | 60 | 56.3% |
| `3'd3` | 7/8 | 560 | 420 | 40 | 30 | 76.6% |
| `3'd4` | 1 | 640 | 480 | 0 | 0 | 100% |

> **关于「3/8」笔误**：用户需求原文含「3/8」，但五档为 1/2、5/8、3/4、7/8、1 时**单调递增且分母统一为 8**（4/8、5/8、6/8、7/8、8/8），不存在 3/8 的位置。经 t1 裁决（`REQ_GAP.md`）与队长确认，判定为笔误，采用上述五档。

### 4.2 实时缩放 vs 预生成图：两方案取舍

| 维度 | 方案 A：实时窗口裁剪（**采用**） | 方案 B：预生成五套素材 |
|---|---|---|
| 实现 | `image_window_mask.v`（**已存在，41 LUT**）+ `ratio_map` 组合译码（约 30 LUT） | 每张图预生成 5 个尺寸 → SD 卡素材 ×5，或 SDRAM 存 5 份 |
| 资源 | **+30 LUT，0 BRAM** | 素材 5×（SD 卡 6 张图 × 5 = 30 个文件），或 SDRAM 5×600KB = 3MB |
| 切换延迟 | **1 帧**（下一个 `frame_start` 生效） | 需重新装载，**数百 ms** |
| 画质 | 窗口外为黑（或填充色），窗口内**原始像素不缩放**（1:1 显示） | 窗口内是缩放后的图，可能有插值损失 |
| 素材制作 | 零额外工作 | 每张图 5 个尺寸，**t4 素材包工作量 ×5** |
| 结论 | ✅ **采用** | ❌ 否决 |

**关键澄清（必须写进答辩材料）**：**屏占比与分辨率是两条正交的链路，不叠加缩放**。

- Key9（屏占比）控制 `image_window_mask` 的**窗口大小**，窗口内像素**1:1 显示，不缩放**。窗口外是黑边。
- Key8（分辨率）控制**读出侧抽样**（水平 `pix_mosaic` + 垂直 `pix_reader` 行映射），全屏范围内生效。
- 两者串联时的效果：读出侧按 `src_w×src_h` 抽样放大到 640×480 目标栅格（以**目标**坐标 `active_x/active_y` 为自变量决定该拍输出哪个源像素），再由 `image_window_mask` 裁剪到 `win_w×win_h` 窗口（Key9 决定）。

**为什么「先放大后裁剪」成立、且与物理连线顺序不矛盾**：

- `pix_mosaic` 与 `pix_reader` 行映射都是**流式抽样**（不是像素缓存）：它们的自变量是**输出域**的 `active_x` / `active_y`，逐拍决定「这一拍该重复哪个源像素 / 该重复哪一行」，因此放大发生在**整个 640×480 目标栅格**上；`image_window_mask` 用同一个 `active_x/active_y` 判断该目标像素是否落在窗口内。二者自变量相同，等价于「全屏放大后再取子窗口」——这就是所谓的先放大后裁剪，与模块在连线上的先后无关。
- 物理连线顺序仍是 `源（图片或视频）→ pix_mosaic（水平抽样）→ image_mask（窗口门控）→ content_mux → overlay`，与现有顶层 `dmz_eg4s20_hdmi_top.v:273-283` 的 `image_window_mask → video_content_mux(.image_pixel_valid)` 位置一致。**`image_mask` 只在 `overlay` 之前、只门控内容层（图片与视频共用的图片路输出端口）的 `pixel_valid`，应急平面图除外，绝不裁 OSD**。
- 若反向（先裁剪窗口再放大），窗口尺寸必须同时整除 `src_w`（320/400/512/576/640）与 640 —— `win_w` 取值 320/400/480/560 对 `src_w` 取值 320/400/512/576/640 **无法全部整除**（400/512、480/512、560/576 三处均除不尽），会产生边界像素重复或缺失。**先放大后裁剪**则 `win_w` 永远是 640 的整数分数（320=640/2、400=640×5/8、480=640×3/4、560=640×7/8、640=640/1），全部整除，无边界误差。

### 4.3 `image_window_mask.v` 复用说明

**现状**（`rtl/video/image_window_mask.v`，43 行，纯组合零寄存器）：
```verilog
assign pixel_valid_out = de && pixel_valid && in_window;
// in_window 用 x_end = {1'b0,win_off_x} + {1'b0,win_w} 加法判上界
// （避免 win_w=0 时减法回绕）
```

**v2 改动**：**模块本体零改动**。仅顶层连线把 `win_w/win_h/win_off_x/win_off_y` 从 `image_player.out_w/out_h/out_off_x/out_off_y` 改为新的 `ratio_map` 组合译码输出。

**为什么这样接**：`image_player` 当前输出的 `out_w/out_h/out_off_x/out_off_y` 来自 `img_scaler`，语义是「BMP 源图缩小后的显示尺寸」（例如源图 1280×960 缩到 640×480 时 `out_w=640`）。这与「屏占比窗口」语义不同 —— 屏占比是**用户可控的显示窗口**，与源图尺寸无关。因此必须解耦，由 `ratio_map` 独立驱动。

**`ratio_map` 实现**（可放在顶层或并入 `key_router.v`，约 30 LUT）：
```verilog
always @(*) begin
    case (ratio_sel)
        3'd0: begin win_w = 16'd320; win_h = 16'd240; win_off_x = 16'd160; win_off_y = 16'd120; end
        3'd1: begin win_w = 16'd400; win_h = 16'd300; win_off_x = 16'd120; win_off_y = 16'd 90; end
        3'd2: begin win_w = 16'd480; win_h = 16'd360; win_off_x = 16'd 80; win_off_y = 16'd 60; end
        3'd3: begin win_w = 16'd560; win_h = 16'd420; win_off_x = 16'd 40; win_off_y = 16'd 30; end
        default: begin win_w = 16'd640; win_h = 16'd480; win_off_x = 16'd  0; win_off_y = 16'd  0; end
    endcase
end
```

---

## 5. 键位路由层（`rtl/control/key_router.v`）

端口契约与档位表**已在 `docs/plan_v2/KEYMAP.md` §7 / §9 完整给出**，本节只补架构层面的三条约定：

1. **单点译码**：`key_router.v` 是 Key4~Key15 的**唯一** `key_code` 解码点。`mode_ctrl.v` 只解码 Key2/Key3，`media_player.v` 只解码 Key0/Key1。跨模块禁止解码他人键号（详见 `KEYMAP.md` §8）。
2. **参数总线**：`bright_lvl[3:0]` / `vol_lvl[3:0]` / `res_sel[2:0]` / `ratio_sel[2:0]` / `audio_en` / `ticker_en` / `viz_en` 七个输出构成「显示与音频参数总线」，由顶层分发给各消费模块。**禁止在消费模块内部再存一份副本**（否则会出现两处状态不同步）。
3. **P2 备用键**：`rescan_req` / `pattern_sel[2:0]` / `invert_en` / `grid_en` / `beep_muted` 五个输出在 P0/P1 阶段**恒 0**（寄存器保留但 case 分支不实现），保证综合时无悬空、可一键启用。

---

## 6. 存储子系统与四路仲裁

### 6.1 现状（`rtl/top/dmz_eg4s20_hdmi_top.v`）

```verilog
wire sd_owner_probe   = !sd_ok;
wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;
wire sd_owner_player  = sd_ok && (gallery_done || gallery_fail);
```

三路独热后 OR 成 `sd_arb_start` / `sd_arb_addr`。**注释明确**：`sd_spi_ctrl` 只有一个读块端口，三方同时驱动 `blk_start/blk_addr` 就是多驱动，TD 直接报错；且扫描与装载并行会造成 SD 事务交错（真卡表现为 CRC 错误/超时）。

### 6.2 v2 扩展为四路

```verilog
// 优先级：①音频 ②视频 ③图库扫描 ④图片装载
wire sd_owner_audio   = sd_ok && audio_want_blk;                        // 最高
wire sd_owner_video   = sd_ok && video_want_blk && !sd_owner_audio;     // 次高
wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail
                        && !sd_owner_audio && !sd_owner_video;
wire sd_owner_probe   = !sd_ok;                                         // 初始化阶段独占
```

**仲裁规则**：
- `!sd_ok` 时 `sd_owner_probe` 独占（SD 初始化必须独占总线）。
- `sd_ok` 后，`audio` > `video` > `gallery`。
- `img_loader`（图片装载）**不参与仲裁** —— 它在 `image_player` 内部，通过 `sd_owner_video` 的同一条路径复用（见 §6.3）。

### 6.3 图片装载与视频流的共享策略

**问题**：`image_player` 当前内部有 `img_loader`（走 SD 读 BMP）与 `pix_reader`（走 SDRAM 读帧）。v2 新增 `rle_decoder` 也要走 SD 读 RLE 流。三者都要 SD 读块端口。

**方案**：**模式互斥，不并发**。

| 模式 | SD 占用者 | 说明 |
|---|---|---|
| `S_DAILY` | `img_loader`（换图时） | 一次装载 921,654 B ≈ 0.74 s，装载完成后 SD 空闲 |
| `S_SCIENCE` | `rle_decoder` + `wav_stream_player` | 视频流 + 音频流持续占用 |
| `S_EMERG` | 无 | 应急平面图为 FPGA 内实时栅格化，零 SD 依赖，不读 SD |

**SDRAM 侧同样互斥：视频与 BMP 共用 A/B 帧缓冲**（`ARCH_ADDENDUM_VIDEO_PATH.md` §4）。

- 视频**不做独立分区、不做 8 帧抖动缓冲**：解压后的帧直接写进 `image_player` 现有的 A/B 双缓冲，**每帧恒为 153,600 words**（640×480 RGB565 打包成 2 像素/word）。
- 互斥靠 `ext_wr_mode` 一个信号：`ext_wr_mode == 0` 时写口归 `img_loader`（BMP），`== 1` 时归 `rle_decoder`（视频）。两者**永不同时写**，因此地址空间可完全重叠。
- 地址表：帧 A `[0x00000, 0x257FF]`、帧 B `[0x25800, 0x4AFFF]`、其余 `[0x4B000, 0x1FFFFF]` 保留未用。

**切换时的状态清理**：`mode_changed` 脉冲触发时：
1. 当前占用者释放 SD（`blk_start` 拉低，等待 `blk_busy` 落）
2. 新占用者延迟 2 拍后再申请（避免同一拍交接）
3. `rle_decoder` 的帧头状态机复位到 `R_IDLE`，`frame_word_cnt` 清 0（**整帧原子性契约**，见 §6.5）
4. `image_player` 的前台帧保持不变（不清屏，避免闪黑）

### 6.4 音频优先级的具体实现

**音频欠载 = 爆音（用户立即察觉）；视频欠载 = 卡一帧（几乎无感）。**

| 模块 | 水位信号 | 抢占阈值 |
|---|---|---|
| `wav_stream_player` | `fifo_level[9:0]` | `< 256`（25% of 1024）时 `audio_want_blk = 1` |
| `rle_decoder` | `frame_buf_level[7:0]` | `< 3 帧` 时 `video_want_blk = 1` |

**仲裁粒度**：以 **512 B 块**为单位（`sd_spi_ctrl` 的最小读单元）。音频块之间允许视频插队，保证音频 FIFO 不会连续两次被延迟超过 512 B × 2 = 1.02 ms（对应 48 kHz 下的 49 个样本，FIFO 深度 1024 足够覆盖）。

### 6.5 `rle_decoder.v` 端口契约

```verilog
module rle_decoder #(
    parameter CLK_FREQ_HZ  = 25_000_000,
    parameter FRAME_W      = 16'd640,
    parameter FRAME_H      = 16'd480,
    parameter JITTER_FRAMES = 8'd3        // SDRAM 抖动缓冲帧数
)(
    input  wire        clk,
    input  wire        rst_n,

    // SD 读块接口（与 sd_spi_ctrl 直连，经顶层仲裁）
    output reg         blk_start,
    output reg  [31:0] blk_addr,
    input  wire        blk_busy,
    input  wire        blk_done,
    input  wire        blk_err,
    input  wire [7:0]  data_byte,
    input  wire        data_valid,

    // 控制
    input  wire        play_en,           // mode == S_SCIENCE
    input  wire [7:0]  play_fps,          // 目标帧率；本工程恒接 8'd5，无自动降级
    input  wire [31:0] file_lba,          // 视频文件起始 LBA（来自 FAT32）
    input  wire [31:0] file_size,         // 字节数
    output reg  [15:0] frame_idx,         // 当前帧号
    output reg         ext_wr_done,       // 单拍：整帧写入 image_player 帧缓冲完成

    // 写口：接到 image_player 的外部写端口（ext_wr_*），不直接连 framebuf_arbiter
    output reg         ext_wr_valid,
    output reg  [20:0] ext_wr_addr,
    output reg  [31:0] ext_wr_data,       // 2 像素/word
    output reg  [3:0]  ext_wr_dm,
    input  wire        ext_wr_ack,
    input  wire        ext_wr_busy,

    // 状态
    output reg  [3:0]  err_code,          // 1=magic 错 2=尺寸不符 3=run_len 非法 4=文件截断
    output reg         underrun,          // 欠载：保持上一帧
    output wire        want_blk           // 仲裁请求（= audio 未占用时）
);
```

**接口时序约定**：
- **SD 读块握手**：`blk_start` 与 `blk_addr` 同拍有效，保持到 `blk_busy` 拉高；`blk_done` 或 `blk_err` 单拍脉冲；`data_valid` 与 `data_byte` 同拍，连续 512 拍（一个块）。
- **帧头解析**：`R_IDLE → R_HDR_MAGIC → R_HDR_W/H → R_HDR_RUNCNT → R_PAYLOAD → R_NEXT_BLK`。
- **RLE 条目格式**：每条 3 字节 `{rgb565[15:0], run_len[7:0]}`，**run_len = 0 表示 256**（避免单独转义字节）。解析顺序：先收 2 字节 RGB565（高字节先），再收 1 字节 run_len。
- **写口归属**：`ext_wr_*` 接到 `image_player` 新增的 12 个外部写端口（`ARCH_ADDENDUM_VIDEO_PATH.md` §3.2），由 `image_player` 内部的 `framebuf_arbiter` 统一仲裁 SDRAM，**`rle_decoder` 不直接驱动 SDRAM**。每 2 个解压像素拼 1 个 32bit word（高 16bit = 左像素），`ext_wr_valid` 与 `ext_wr_data/addr/dm` 同拍；`ext_wr_ack` 由 `image_player` 返回，**未收到 ack 前不得推进地址**；`ext_wr_busy` 用于反压（内部 FIFO 接近满）。
- **整帧原子性（`ext_wr_done` 语义）**：`ext_wr_done` 必须是「整帧 153,600 words 全部写进帧缓冲」的单拍信号，**不允许续写**。`play_en` 拉低或模式切走时，`frame_word_cnt` **强制清 0** 且不得发出 `ext_wr_done`；否则第二次部分覆盖会得到混杂帧。
- **欠载策略**：`underrun = 1` 时**保持上一帧**（不插黑、不清屏）。`pix_reader` 继续读旧帧内容。
- **帧率控制**：`ext_wr_done` 后启动帧间隔定时器（`CLK_FREQ_HZ / play_fps`），到期才允许解析下一帧。
- **降级策略（未实现，已定案不做）**：初版曾设定「连续 3 帧 `underrun` → `play_fps` 从 5 降到 2」，**该逻辑从未在 RTL 实现** —— 顶层 `dmz_eg4s20_hdmi_top.v:521` 把 `.play_fps` 硬接常量 `8'd5`，`rle_underrun` 零消费者。欠载时的真实行为是**保持上一帧**（见上一条）。

### 6.6 `wav_stream_player.v` 端口契约

```verilog
module wav_stream_player #(
    parameter CLK_FREQ_HZ = 25_000_000,
    parameter SAMPLE_RATE = 48_000,
    parameter FIFO_AW     = 10,           // 1024 深度
    parameter LOW_WM      = 10'd256       // 25% 水位触发 SD 请求
)(
    input  wire        clk,
    input  wire        rst_n,

    // SD 读块接口（最高优先级）
    output reg         blk_start,
    output reg  [31:0] blk_addr,
    input  wire        blk_busy,
    input  wire        blk_done,
    input  wire        blk_err,
    input  wire [7:0]  data_byte,
    input  wire        data_valid,

    // 控制
    input  wire        play_en,           // mode != S_EMERG && audio_en
    input  wire [31:0] file_lba,
    input  wire [31:0] file_size,
    output reg  [3:0]  err_code,          // 1=RIFF 错 2=fmt 非 PCM 3=非 16bit 4=非 48kHz 5=截断

    // 音频输出（24bit signed，对齐工程既有格式）
    output reg         sample_valid,
    output reg  signed [23:0] sample_l,
    output reg  signed [23:0] sample_r,

    output wire        want_blk,          // 仲裁请求（最高优先级）
    output wire [9:0]  fifo_level
);
```

**接口时序约定**：
- **WAV 头解析**：`W_IDLE → W_HDR_RIFF → W_HDR_FMT → W_HDR_DATA → W_STREAM`。仅支持 `PCM (audio_format=1)` / 16 bit / 48 kHz / 单声道（双声道时取左声道复制到右）。
- **采样节拍**：`sample_valid` 严格按 `CLK_FREQ_HZ / SAMPLE_RATE = 25e6 / 48e3 = 520.833` 产生 —— 用 20 位累加器（`acc += 48000; if (acc >= 25000000) ...` 不现实，改用 `acc += 48000` 与 `25000000` 比较会溢出）。**实际实现**：相位累加器 `phase += 48000`（17 bit），当 `phase >= 25_000_000` 时溢出（25e6 < 2^25，用 25 bit 累加器），溢出即产生一个 `sample_valid`，余数保留。平均周期 = 25e6/48e3 = 520.8333 拍，**长期无累积误差**。
- **FIFO 跨域**：写侧 25 MHz（SD 域），读侧 25 MHz（采样节拍同域，**同频**）。因此**不需要 CDC**！这是重要简化 —— `wav_stream_player` 全程在 25 MHz 域内，FIFO 是同步 FIFO（1 个 BRAM9K 即可，1024 × 16bit）。
  > 更正 `RESOURCE_BUDGET.md` §3.2 的表述：`wav_stream_player` 的 FIFO **不需要异步**，2 个 BRAM 的预算仍成立（1024×16 位 = 1 个 BRAM9K，留 1 个给双缓冲头）。
- **欠载**：FIFO 空时输出 `sample_valid = 0`（静音），不输出噪声。
- **`want_blk`**：`fifo_level < LOW_WM` 且 `play_en` 且 `file_remaining > 0` 时置高。

### 6.7 SD 卡文件布局（v2 素材规范）

```
SD 卡根目录/
├── IMG001.BMP ~ IMG006.BMP        640×480×24bit 无压缩，各 921,654 B（日常图库，复用现状）
├── VIDEO/
│   └── SCI.RLE                    科普视频，640×480 RGB565 RLE 序列帧
├── AUDIO/
│   ├── BGM.WAV                    日常背景音乐，48kHz/16bit/单声道
│   └── NARRATION.WAV              科普解说，48kHz/16bit/单声道，126.1 s = 12,106,244 B
└── SRT/
    └── NARRATION.SRT              科普字幕时间轴（18 条，编译期转成 ROM 表 + 1 块 BRAM9K，不运行时解析）
```

**`.RLE` 文件格式**（必须写进格式文档）：

| 偏移 | 长度 | 字段 | 值 |
|---|---|---|---|
| 0 | 4 | `magic` | `"SCMR"`（0x53 0x43 0x4D 0x52） |
| 4 | 2 | `width` | 640（小端） |
| 6 | 2 | `height` | 480（小端） |
| 8 | 4 | `run_count` | 本帧条目数（小端） |
| 12 | 3×run_count | `payload` | 每条 `{rgb565[15:0], run_len[7:0]}`，**run_len = 0 表示 256** |

**多帧文件**：上述结构**逐帧重复**（每帧自带 12 B 头），便于随机定位与错误恢复。第 N 帧的偏移由前 N-1 帧的 `run_count` 累加得到（`rle_decoder` 维护 `frame_offset` 累加器）。

---

## 7. 音频子系统

### 7.1 现状

- `rtl/audio/audio_tone_gen.v`：状态提示音（`playback_state[2:0]` 驱动，`NOTE_HOLD_SAMPLES=24000` → 0.5 s/音），输出 24bit signed `audio_left` / `audio_right`。
- `rtl/audio/pwm_audio_out.v`：440 Hz 单音 PWM（**当前顶层未用**，顶层用的是 `pcm_to_pwm`）。
- `rtl/audio/pcm_to_pwm.v`：一阶 sigma-delta，24bit signed → PWM，输出到 `audio_pwm`（F3）。
- `rtl/audio/buzzer_tone.v`：蜂鸣器（H11），`tone_sel` 三态（1=按键音 2=应急音 3=故障音）。
- **无任何音频文件播放能力。**

### 7.2 v2 音源选择矩阵

**`audio_src_mux.v` 不是样本级 mux，是控制信号发生器。** 它一个音频样本都不碰，只产出三样东西：`src_sel[1:0]`（播哪个 WAV）、`src_name[87:0]`（`BGM.WAV` / `NARR.WAV` / `ALARM.WAV` 三个 11 字符短名常量，供 `wav_stream_player` 传给 `fat32_reader` 做 target_name 匹配）、`src_start`（源变化且 `sd_ready` 时打一拍启动脉冲）。三个源**全是 WAV 文件**，没有 `SRC_TONE`、没有 `SRC_NONE`。

```verilog
// rtl/audio/audio_src_mux.v（已实现，约 30 LUT）
localparam [1:0] MODE_DAILY = 2'd0, MODE_SCIENCE = 2'd1, MODE_EMERG = 2'd2;
localparam [1:0] SRC_BGM     = 2'd0, SRC_NARR    = 2'd1, SRC_ALARM = 2'd2;

always @(*) begin
    case (mode)
        MODE_SCIENCE: sel_c = SRC_NARR;      // 科普：NARR.WAV 解说
        MODE_EMERG:   sel_c = SRC_ALARM;     // 应急：ALARM.WAV 警报
        default:      sel_c = SRC_BGM;       // 日常：BGM.WAV 背景音乐
    endcase
end
// 未定义模式值（3）保守回落到 BGM，而不是"不出声"——出声比沉默更容易被发现
assign eff_audio_en = (mode == MODE_EMERG) ? 1'b1 : audio_en;
```

| 模式 | 音源 | Key4 是否有效 | WAV 未就绪时 |
|---|---|---|---|
| 日常 | WAV 背景音乐（`BGM.WAV`） | ✅ 有效 | **静音**，由 `SD NEEDED` 状态行提示 |
| 科普 | WAV 解说（`NARRATION.WAV`） | ✅ 有效 | **静音**，由 `KEPU MODE - SD CARD NEEDED` 状态行提示 |
| 应急 | 警报音（`ALARM.WAV`） | ❌ **强制开** | **静音**（同上；应急画面不依赖音频） |

> **口径纠正（2026-11-02）**：本节早期草稿写过「WAV 未就绪时降级为 `audio_tone_gen` 状态音」「应急音可用 `tone_sel=3`」——**该降级路径在 RTL 里不存在，也不打算实现**。`audio_src_mux` 只有 WAV 三选一，没有 `wav_ready` 输入、没有 `SRC_TONE`/`SRC_NONE`。要补降级需新增 `wav_ready` 端口 + 样本级二选一，属 t7 之后的增量，不在本期范围；缺卡/未就绪一律静音 + 状态行提示。
>
> **`eff_audio_en` 与 `key_router.audio_en_eff` 是同一件事的两份实现**：`key_router.v:307` 的 `audio_en_eff = emerg ? 1'b1 : audio_en` 与 `audio_src_mux.v:93` 逻辑恒等。**唯一权威是 `key_router.audio_en_eff`**，它同时覆盖静音键与应急强制开；`audio_src_mux.eff_audio_en` 这个输出**不接、不入顶层逻辑**（见 `KEYMAP.md` 作用域矩阵）。`ticker_en_eff`（`key_router.v:308`）同理。

### 7.3 10 档音量实现（`vol_apply.v`）

```verilog
module vol_apply (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               sample_valid,
    input  wire signed [23:0] sample_in,
    input  wire [3:0]         vol_lvl,      // 0~9
    input  wire [1:0]         mode,
    output reg                sample_valid_out,
    output reg  signed [23:0] sample_out
);
    // 应急下限钳位：vol_lvl < 3 时强制 3（见 KEYMAP.md §5.1）
    wire [3:0] eff_lvl = (mode == 2'd2 && vol_lvl < 4'd3) ? 4'd3 : vol_lvl;

    // 增益 k/32（与亮度表同构），24bit signed 算术右移保持符号
    reg signed [23:0] gain_out;
    always @(*) begin
        case (eff_lvl)
            4'd0: gain_out = (sample_in >>> 4) + (sample_in >>> 5);           //  3/32
            4'd1: gain_out = (sample_in >>> 3) + (sample_in >>> 4);           //  6/32
            4'd2: gain_out = (sample_in >>> 2) + (sample_in >>> 4);           // 10/32
            4'd3: gain_out = (sample_in >>> 1) - (sample_in >>> 4) - (sample_in >>> 5); // 13/32
            4'd4: gain_out = (sample_in >>> 1);                               // 16/32
            4'd5: gain_out = sample_in - (sample_in >>> 2) - (sample_in >>> 3);// 20/32
            4'd6: gain_out = sample_in - (sample_in >>> 2) - (sample_in >>> 5);// 23/32
            4'd7: gain_out = sample_in - (sample_in >>> 3) - (sample_in >>> 4);// 26/32
            4'd8: gain_out = sample_in - (sample_in >>> 4) - (sample_in >>> 5);// 29/32
            default: gain_out = sample_in;                                    // 32/32
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_valid_out <= 1'b0;
            sample_out       <= 24'sd0;
        end else begin
            sample_valid_out <= sample_valid;
            sample_out       <= gain_out;
        end
    end
endmodule
```

**零 DSP**：全部用算术右移 + 24bit 加减（约 120 LUT）。输出打一拍（`sample_out` 寄存器）。

### 7.4 音频可视化源切换（`audio_waveform.v` 升级）

**现状**：`rtl/video/audio_waveform.v`（参数 `X0=64, X1=576, Y_CENTER=200, Y_SHIFT=9, HISTORY=64`）已实现波形绘制，由 `wave_en` 控制，实测 437 le / 413 lut。

**v2 改动**：
1. `wave_en` 输入改接 `viz_en`（Key10）。
2. **电平条图层停用（`level_en` 固定接 `1'b0`）** —— 见下方「降级项 D-03」。
3. **可视化采样源**：当前 `audio_sample` 来自 `audio_left`（`audio_tone_gen` 输出）。v2 改为来自 `vol_apply` 的输出（即**用户实际听到的信号**），这样波形幅度会随 Key7 音量变化 —— 更符合「音频可视化」的直觉。

> **降级项 D-03：音频电平条图层停用**
>
> 旧 v1 的 KEY13 是「电平条 → 波形 → 关」4 态循环，把电平条和波形当成同一个可视化的两档。v2 把音频可视化收成一个键：**Key10 = `viz_en`，只管波形层**（`audio_waveform.v`，449 le / 416 lut，`X0=64 / X1=576 / Y_CENTER=200`）。电平条这一档在新键表里没有归属（Key0~Key10 已被 m00117 键表占满），故**固定 `level_en = 1'b0` 停用**，`video_overlay` 里 `px_level` 那一路（`24'h20FF20` 绿条）恒不亮。
>
> **为什么保留波形层、弃电平条**：波形层才是用户要的「音频可视化」——它带 64 点历史缓冲、能看出节拍与包络；电平条只是同一路信号的零维表示（一个当前幅度值），信息量与波形层严格包含关系。两者同时存在时，屏幕上会叠两条反映同一件事的图层，占像素而不增信息。
>
> 注意：本项与本节早期草稿「电平条改为随音频常开」**结论相反**，以本块为准（草稿把电平条当成「有声音」的廉价反馈，但 v2 已有波形层承担该语义）。资源侧电平条停用**不产生可回收的 LUT**（`px_level` 那一路跟着 `level_en` 常量 0 被综合器裁掉，量级 < 10 LUT，不单独立账）。

**接线**（顶层）：
```verilog
video_overlay u_overlay (
    ...
    .audio_sample (vol_sample_out),     // 改：来自 vol_apply，而非 audio_left
    .audio_valid  (vol_sample_valid),
    .wave_en      (viz_en),             // 改：来自 Key10
    .level_en     (1'b0),               // 改：D-03，电平条图层停用
    ...
);
```

### 7.5 应急模式禁静音的实现点

**三个独立实现点，缺一不可**（这是「防御性三重保险」，因为应急静音是不可接受的失效）：

| 层 | 实现位置 | 逻辑 |
|---|---|---|
| ① 按键层 | `key_router.v` | `audio_en` 寄存器在 `mode == 2` 时**不响应 Key4**（case 分支前置 `mode != 2` 条件） |
| ② 音源层 | `audio_src_mux.v` | `mode == 2` 时 `eff_audio_en = 1'b1`，无视 `audio_en` 寄存器值 |
| ③ 输出层 | `vol_apply.v` | `mode == 2` 时 `vol_lvl < 3` 钳位到 3，**永远不会输出真正的 0 增益** |
| ④ PWM 层 | 顶层 `pcm_to_pwm.mute` | `mute = (mode == 2) ? 1'b0 : (beep_muted \| ~audio_playing)`，应急时恒不静音 |

**验证要求**（写进 t7 验收）：仿真用例必须覆盖「应急模式 + 按 Key4 + vol_lvl=0」的组合，断言 `audio_pwm` 输出非恒定电平。

---

## 8. AHT20 温湿度传感器链路

### 8.1 合规定位（结论已在 t1 给出，此处只列实现）

`reports/plan_v2/REQ_GAP.md` 判定 (a)：**AHT20 不算额外处理器，合规，风险中**。四条依据：
1. 无指令集 / 无程序存储 / 不可编程，仅 `0xAC`（触发测量）/ `0x71`（读状态）/ `0xBE`（软复位）三条硬连线命令；
2. 赛规 P5 明确允许复杂度更高的 OV5640 摄像头模块；
3. 极端解释会导致 SD 卡 / HDMI 显示器也违规，使赛题无法实现；
4. 20bit 原始量的**全部处理在 RTL 内完成**（换算、迟滞、联动）。

### 8.2 引脚与电气

| 信号 | FPGA 球 | 方向 | 复用关系 |
|---|---|---|---|
| `aht_scl` | **D1** | 输出（开漏模拟） | `docs/pending_confirmations.md:46`：「SPI 屏 SCL=D1」 |
| `aht_sda_i` | **E1** | 输入 | 同上：「SDA=E1」 |
| `aht_sda_o` | **E1** | 输出（开漏模拟） | 同上（双向共用 E1） |

> ⚠️ **必须标注**：D1/E1 该排针**本项目不用作 SPI 显示**，专用于 AHT20 温湿度传感器。接线图、引脚表、ADC 文件、答辩材料四处都要写。

**开漏实现**（FPGA 无真开漏，用三态 + 外部上拉模拟）：

```verilog
// rtl/sensor/i2c_master.v 内的引脚驱动
assign aht_scl    = scl_low  ? 1'b0 : 1'bz;   // scl_low=1 拉低，否则高阻（外部 4.7k 上拉到 3.3V）
assign aht_sda_o  = sda_low  ? 1'b0 : 1'bz;
wire   aht_sda_in = aht_sda_i;                 // 输入直接读引脚（外部上拉保证空闲为高）
```

**外部电路**（接线图必须画）：
- `SCL` 与 `SDA` 各接一个 **4.7 kΩ 上拉电阻到 3.3 V**
- AHT20 的 `VDD` 接 3.3 V，`GND` 接 GND，`VDD` 与 `GND` 之间接 **100 nF 去耦电容**
- AHT20 的 `ADDR` 引脚（若有）接地 → I2C 地址 **0x38**（7 位）

**输入同步**（时序强制措施，见 `RESOURCE_BUDGET.md` §5.3）：
```verilog
// rtl/sensor/i2c_master.v 内
reg sda_sync0, sda_sync1;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin sda_sync0 <= 1'b1; sda_sync1 <= 1'b1; end
    else        begin sda_sync0 <= aht_sda_in; sda_sync1 <= sda_sync0; end
end
```

### 8.3 I2C 主机参数（`i2c_master.v`）

| 参数 | 值 | 推导 |
|---|---|---|
| `CLK_FREQ_HZ` | 25,000,000 | 25 MHz 主时钟 |
| `SCL_FREQ_HZ` | 100,000 | 标准模式 I2C |
| `DIV` | **250** | 25e6 / 100e3 / 2（半周期分频）= 125；实际用 `QUARTER = 25e6/(100e3*4) = 62`，每 62 拍翻转一次相位 |
| 时序 | 25 MHz / 100 kHz = 250 拍/周期，四相（低-上升-高-下降）各 62~63 拍 | |

### 8.4 AHT20 命令序列（`aht20_ctrl.v`）

| 步骤 | 动作 | 字节序列 | 等待 |
|---|---|---|---|
| 1 | 上电软复位 | `0xBE` | 20 ms |
| 2 | 读状态字 | 写 `0x71` → 读 1 字节 | — |
| 3 | 触发测量 | `0xAC 0x33 0x00` | **80 ms** |
| 4 | 读状态字（轮询 busy） | 写 `0x71` → 读 1 字节，bit[7] = busy | 最多 100 ms |
| 5 | 读 6 字节数据 | 读 6 字节 | — |

**数据解析**（全部用移位加，**零 DSP**）：
```
状态字节 = data[0]，bit[7]=busy，bit[3]=已校准
湿度 raw = {data[1], data[2], data[3][7:4]}          // 20 bit
温度 raw = {data[3][3:0], data[4], data[5]}          // 20 bit

湿度 %RH = raw_h * 100 / 2^20 = raw_h * 100 >> 20
温度 ℃  = raw_t * 200 / 2^20 - 50 = (raw_t * 200 >> 20) - 50

其中 ×200 = ×(128 + 64 + 8) = (raw<<7) + (raw<<6) + (raw<<3)  —— 三个移位相加，零乘法器
     ×100 = ×(64 + 32 + 4)   = (raw<<6) + (raw<<5) + (raw<<2)  —— 三个移位相加
```
**输出格式**：`temp_0c1[15:0]` = 温度 ×10（例如 25.3 ℃ → 253），`humi_0c1[15:0]` = 湿度 ×10。

### 8.5 `aht20_ctrl.v` 端口契约

```verilog
module aht20_ctrl #(
    parameter CLK_FREQ_HZ   = 25_000_000,
    parameter SCL_FREQ_HZ   = 100_000,
    parameter MEAS_PERIOD_MS = 1000,
    parameter RESET_MS      = 20,
    parameter CONVERT_MS    = 80
)(
    input  wire        clk,
    input  wire        rst_n,

    // I2C 物理接口（开漏）
    output wire        scl,
    output wire        sda_o,
    input  wire        sda_i,

    // 测量结果（0.1 单位，供 temp_hyst_link 使用）
    output reg  [15:0] temp_0c1,
    output reg  [15:0] humi_0c1,
    output reg         data_valid,      // 单拍：新读数有效
    output reg  [3:0]  err_code,        // 1=复位超时 2=状态读失败 3=转换超时 4=CRC/校准位异常 5=NACK
    output reg         sensor_ok        // 首次成功读数后置 1
);
```

**接口时序约定**：
- `scl` / `sda_o` 是**开漏驱动**（`1'bz` 表示释放），外部上拉。
- `sda_i` 在模块内部**先经 2 级同步**再使用。
- 测量周期 `MEAS_PERIOD_MS = 1000`，即每 1 s 一次完整序列（复位只在上电时做一次，之后循环步骤 3~5）。
- `data_valid` 是**单拍脉冲**，`temp_0c1` / `humi_0c1` 在**同一拍**已更新为新值。
- `sensor_ok = 0` 时 `temp_0c1` 保持上次值（或初值 250 = 25.0 ℃），`temp_hyst_link` 应**忽略** `data_valid = 0` 的周期。
- 全部输出异步复位。

### 8.6 `temp_hyst_link.v` 端口契约（与传感器无关）

```verilog
module temp_hyst_link #(
    parameter TEMP_HIGH_0C1 = 16'd450,   // 45.0 ℃
    parameter TEMP_LOW_0C1  = 16'd400,   // 40.0 ℃
    parameter HYST_CNT_UP   = 4'd3,
    parameter HYST_CNT_DN   = 4'd5
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] temp_0c1,         // 恒来自 aht20_ctrl（Plan B 不实施）
    input  wire        data_valid,       // 单拍

    output reg         temp_alarm,       // 电平：报警中（已含迟滞）
    output reg  [1:0]  hyst_state,       // 0=正常 1=报警 2=已回落
    output reg  [15:0] temp_hold         // 最近有效读数（供 OSD 显示）
);
```

**关键设计**：本模块**不关心数据来自 AHT20 还是 NTC ADC**（历史论证）。**Plan B 已裁决不实施**（用户 2026-11-02，RC-V2-01），故本项目 `temp_0c1` / `data_valid` 恒由 `aht20_ctrl` 驱动，**不需要那个切换 mux（约 10 LUT）**；迟滞逻辑与应急联动照原样实现。

### 8.7 Plan B：片内 SAR ADC + NTC（论证备查，已裁决不实施）

> **状态：不实施。** 用户 2026-11-02 裁决「只用 AHT20，NTC 不走」，本方案**不进入 RTL、不进 `.adc`、不占 IO、不新增 ADC 约束行、不进 M3 门禁**。以下内容保留为**答辩问答用的备查论证**，不得作为实施方案引用。裁决与影响面记录见 `reports/plan_v2/REQUIREMENT_CHANGELOG_V2.md`（RC-V2-01），完整推导见 `reports/plan_v2/PLAN_B_NTC_ADC.md`。

**原触发条件（已不成立）**：~~若 AHT20 采购不到，或赛前合规审查判定 AHT20 不可用~~ —— 该触发条件**已不成立**：用户 2026-11-02 裁决只保留 AHT20，即使 AHT20 失效也不切换到 NTC 方案（单传感器降级风险见 `reports/plan_v2/REQUIREMENT_CHANGELOG_V2.md` §5）。

| 项 | 内容 |
|---|---|
| 传感器 | NTC 10 kΩ（B=3950）热敏电阻 |
| 电路 | 3.3 V — NTC — 节点 — R1 10 kΩ — GND（分压），节点接 ADC 输入；可选并联 100 nF 滤波 |
| ADC | EG4S20 片内 8 通道 SAR ADC：**12 bit / 有效 8 bit / 1 MSPS**，与用户 IO 复用（`TN304_1.3` 原文） |
| 温度换算 | NTC 非线性，用**分段线性查表**（约 16 段，覆盖 0~80 ℃），每段 2 个端点值 + 线性插值。RTL 约 150 LUT，零 DSP |
| 精度 | ±2 ℃（足够，因为阈值是 45 ℃，迟滞 5 ℃） |
| 资源 | 约 200 LUT（ADC 包装 + 查表），比 AHT20 链路（600 LUT）**更省** |
| 合规性 | **零争议** —— 纯无源器件 + 片内 ADC，无任何外部芯片 |
| IO | 1 个模拟输入引脚（比 AHT20 少 1 个） |

**Plan B 的取舍（历史论证备查）**：精度低（±2 ℃ vs ±0.3 ℃）、需要模拟电路调试、片内 ADC 与用户 IO 复用需查手册确认可用通道。但**合规性无懈可击**。

**结论：不实施。** 经用户 2026-11-02 裁决，本方案仅作论证备查，不投入实现、不占 IO、不新增 ADC 约束行；相关推导保留用于答辩问答。

---

## 9. 像素通路详解（含亮度位置的关键论证）

### 9.1 完整链路（从源到 HDMI）

```
源 → 水平抽样(pix_mosaic) → 窗口裁剪(内容层) → 内容合成 → 叠加层 → 亮度 → 参数面板 → AXIS → HDMI
```

> **`u_image_mask` 在 `u_overlay` 之前**（与现有顶层 `dmz_eg4s20_hdmi_top.v:273-283` 接线一致）：
> `image_window_mask → video_content_mux(.image_pixel_valid) → video_overlay(.rgb_in) → …`。
> 它**只门控内容层（图片与视频共用的图片路输出端口）的 `pixel_valid`**，输出是 1 位有效位而非 RGB 通路，**无法也不得串在 OSD 之后** ——
> 否则字幕（y∈[464,479]）、波形（x∈[616,631]）、电平条（贴右边）会全部落到 1/2 窗口（x∈[160,479]、y∈[120,359]）之外被裁成黑。

| 级 | 模块 | 输入 | 输出 | 说明 |
|---|---|---|---|---|
| 1 | 源 | `u_image_player`（SDRAM 读 RGB565→RGB888，BMP 或 RLE 视频共用此端口） / `u_test_pattern_gen` | RGB565/RGB888 | 内容二选一（`u_science_page` 已废弃，见 `ARCH_ADDENDUM_VIDEO_PATH.md` §5） |
| 2 | `u_mosaic`（`pix_mosaic`） | RGB565 + `active_x` + `res_sel`→`src_w` | RGB565 | **Key8 水平抽样，读出侧 Bresenham；`src_w=640` 恒等旁路** |
| 3 | `u_image_mask` | 像素 + `ratio_sel` 窗口 + `image_pixel_valid` | 1 位 `pixel_valid_out` | **屏占比裁剪，门控内容层（图片+视频），应急平面图除外**；窗口外 `image_ready` 置 0 → content_mux 出黑。**在 overlay 之前** |
| 4 | `u_content_mux` | 三路 RGB888（内容层 / 测试图 / 应急图）+ `mode` + 已门控的 `image_pixel_valid` | RGB888 | `mode==2` 出 `emerg_rgb`，`mode==1` 出内容层（视频），其他出图库 |
| 5 | `u_overlay` | RGB888 + `viz_en`/`ticker_en`/`level_en`/`invert_en`/`grid_en`/`bright_lvl[2:0]` | RGB888 | 字幕、波形、电平条、反色、九宫格；`bright_sel` 仅用于信息条亮度格显示 |
| 6 | **`u_brightness_apply`** | RGB888 + `bright_lvl[3:0]` | RGB888 | **10 档亮度，位置关键；纯组合零寄存器** |
| 7 | `u_osd_panel` | RGB888 + `panel_on` | RGB888 | 参数面板（**不参与亮度衰减**） |
| 8 | `u_axis` | RGB888 + `de`/`vs` | AXIS 流 | `H_ACTIVE=640` |
| 9 | `u_hdmi_core` → `u_phy` | AXIS | TMDS | — |

### 9.2 亮度为什么必须在第 6 级（overlay 之后、osd_panel 之前）

**赛规依据**：`SPEC_CONSTRAINTS.md` §4 记录赛规 1.4(4) 原文要求「按键调节亮度后，**参数变化信息可读**」。

**逐级分析**：

| 亮度放哪 | 后果 | 判定 |
|---|---|---|
| 第 5 级（`video_overlay` 内部，**现状**） | 亮度与字幕/波形在同一个模块，**字幕会被一起调暗**；调到最暗档（9.4%）时字幕几乎不可见 → **违反 1.4(4)** | ❌ 现状必须改 |
| **第 6 级（`overlay` 之后、`osd_panel` 之前，v2 采用）** | 画面（含字幕、波形）被调暗，**参数面板不受影响** → 用户按下 Key6 时，画面变暗但面板文字清晰可读 → **满足 1.4(4)** | ✅ **采用** |
| 第 7 级（`osd_panel` 之后） | 面板也被调暗 → 同样违反 1.4(4) | ❌ |
| 图源侧（`image_mask` 所在位置，`content_mux` 之前） | 窗口外黑边被调亮（黑变灰）→ 视觉异常；且测试图/应急图路径不受该级控制 | ❌ |

**为什么字幕被调暗是可接受的**：字幕（`ticker_en`）是**内容**的一部分，随画面一起变暗符合「显示亮度」的直觉；参数面板是**UI 反馈**，必须始终可读。这个区分正是 1.4(4) 的立法意图 —— 「参数变化信息」指的是**参数值本身**，不是画面内容。

> **屏占比（Key9）不裁 OSD**：屏占比只作用于「内容层」（图片与视频共用的图片路输出端口，应急平面图除外），字幕/波形/电平条/参数面板始终全屏可用。这是用户 m00001「字幕叠加在画面上、可视化在字幕上方」这条需求的直接要求。

### 9.3 `brightness_apply.v` 端口契约

> **纯组合零寄存器**（与 `image_window_mask.v`（43 行纯组合）、`fade_mixer.v`（21 行纯组合）风格一致）。
> 理由详见本节末「为什么不做打拍」。

```verilog
module brightness_apply (
    input  wire [23:0] rgb_in,          // 来自 u_overlay
    input  wire        de,              // 与 rgb_in 同拍
    input  wire [3:0]  bright_lvl,      // 0~9（Key6），0=最亮，9=最暗
    output wire [23:0] rgb_out,         // 送 u_osd_panel
    output wire        de_out           // 与 rgb_out 同拍，纯连线
);
    wire [7:0] r_in = rgb_in[23:16];
    wire [7:0] g_in = rgb_in[15:8];
    wire [7:0] b_in = rgb_in[7:0];

    // 10 档移位加（表见 KEYMAP.md §9.1），零 DSP；档 0 = 100% 最亮，档 9 ≈ 9.4% 最暗
    function [7:0] brt10;
        input [7:0] x;
        input [3:0] lvl;
        begin
            case (lvl)
                4'd0:    brt10 = x;                                      // 32/32 = 100%
                4'd1:    brt10 = x - (x >> 4) - (x >> 5);                 // 29/32 = 90.6%
                4'd2:    brt10 = x - (x >> 3) - (x >> 4);                 // 26/32 = 81.3%
                4'd3:    brt10 = x - (x >> 2) - (x >> 5);                 // 23/32 = 71.9%
                4'd4:    brt10 = x - (x >> 2) - (x >> 3);                 // 20/32 = 62.5%
                4'd5:    brt10 = (x >> 1);                                // 16/32 = 50.0%
                4'd6:    brt10 = (x >> 1) - (x >> 4) - (x >> 5);          // 13/32 = 40.6%
                4'd7:    brt10 = (x >> 2) + (x >> 4);                     // 10/32 = 31.3%
                4'd8:    brt10 = (x >> 3) + (x >> 4);                     //  6/32 = 18.8%
                default: brt10 = (x >> 4) + (x >> 5);                     //  3/32 =  9.4%
            endcase
        end
    endfunction

    assign de_out  = de;                 // 纯连线，零延迟，与 active_x/active_y 天然对齐
    assign rgb_out = de ? {brt10(r_in, bright_lvl),
                           brt10(g_in, bright_lvl),
                           brt10(b_in, bright_lvl)} : 24'd0;
endmodule
```

**为什么不做打拍（三条理由）**：

1. **`active_x`/`active_y` 无法一起打**。下游 `u_osd_panel` 用 `active_x/active_y` 定位面板。若只打 `de`/`rgb` 而不打坐标，面板会错开 1 拍 → **整体右移/下移一像素**；若要打就必须 `de`/`active_x`/`active_y`/`rgb` 四者一起打，端口从 5 个膨胀到 7 个，且必须强约束「下游一律使用本模块输出的坐标」，把简单模块做成易错模块。
2. **纯组合不给 Hold 添风险**。hold WNS 仅 **+0.003 ns**，新增寄存器会有新的 hold 检查路径。纯组合只加组合延迟，加深的是 setup 路径（当前 SWNS **+1.935 ns**，余量充足）。
3. **有先例且风格统一**。`image_window_mask.v`（43 行纯组合）与 `fade_mixer.v`（21 行纯组合）都在像素通路上，工程既有惯例就是「像素通路上的轻量处理做纯组合」。

**时序核算**：`u_overlay` 631 le 组合 + `u_brightness_apply` 约 140 le（4 级：移位 → 加减 → 加减 → mux）→ `u_osd_panel` 组合，25 MHz 周期 40 ns，收敛无压力。若 M3 综合实测该路径 SWNS 转负，再退化为打拍方案（并把 `de`/`active_x`/`active_y`/`rgb` 四者同步寄存），此为**有据的兜底路径**，不是悬空项。`u_axis`（`video_rgb_to_axis`）**在 `osd_panel` 之后**，与本模块不串联。

### 9.4 科普视频字幕的行源与段选（`narr_subline.v`，t8 裁定）

> **背景**：用户需求 m00001 原文「下方图层 OSD 叠加的字幕换成视频字幕」。但截至 t8，`osd_caption.v` 的 16 行文本**全部占满**：line 0..7 = ASCII 三条静态带（`SMART CAMPUS` / `PLAY·AUTO·PAUSE` / `IMG #3`）、line 8..13 = 六段中文校园介绍（`LINE_SEG0 = 4'd8`）、line 14..15 = 应急疏散文案 104 字拆两行（`LINE_EMG0 = 4'd14`，`emg_half` 每滚完一轮翻转）。**没有一行留给科普字幕** —— 功能被 `PLAN.md` §5 与 §6.3 承诺，却没有落点。

#### 9.4.1 四条设计约束（先定边界，再谈实现）

| # | 约束 | 依据 |
|---|---|---|
| 1 | **只用 1 行（line 16）即可，不需要第二行** | 滚动带一行的容量是 `COLS = 64 列`（`ticker_src = active_x + scroll_px`、`ticker_col = ticker_src[9:4]`，`scroll_px` 回绕 1023 → 文本循环滚动），不是「一屏 40 字」。最长第 12 条 53 汉字 + 全角标点 = 57 字符 < 64 列，单行放得下 |
| 2 | **不能用 `osd_strings` 的 LUT case** | 该模块是 `case ({line_sel, col})` 的纯组合 ROM，16 行 × 64 列 = 1,024 条目。若把 18 段字幕塞进去（`TOTAL_LINES` 16→34），条目翻倍到 2,176、生成源文件约 170 KB，**LUT 实现不可接受**。字幕改走 BRAM |
| 3 | **`line_sel` 保持 4 位不动** | 扩到 5 位要改 `osd_strings` 端口、`gen_osd_strings.py` 的 `TOTAL_LINES`、以及 `case` 键宽（10→11 位）。既然只需要 1 行、且这行走独立 BRAM 数据源，就**不碰 `osd_strings`** |
| 4 | **不新增顶层信号线去取 `player_ctrl` 帧计数** | 驱动源用 `rle_decoder.frame_idx[15:0]` —— 它就是「已解码的帧序号」@5 fps，与 `narration.wav` 的时间轴天然同源（全片 631 帧 / 126.2 s vs 音频 126.106 s）。`player_ctrl` 的帧计数是播放器层面的计数，欠载/暂停时会与音频脱节 |

#### 9.4.2 `narr_subline.v` 结构

| 项 | 取值 |
|---|---|
| 存储 | **1 块 BRAM9K**：`reg [8:0] mem [0:562]`（1024 深 × 9 位配置，**实用 563 深**） |
| 深度来源 | 18 段文本 `len()`（含全角标点）之和 = 16+24+39+38+23+43+24+29+46+25+37+**57**+34+23+30+44+18+13 = **563** |
| 编码 | `code[8:0]`：`0..464` = 字库字形索引（`cjk16_charset.txt` 共 465 字形，narration.srt 去重 253 字符**缺字 0**，探测脚本已核）；**`9'h1FF` = 空**（段尾填充，渲染为空白）；**不存 CJK 标志位**（字幕带恒走 `cjk16_font` 中文路径，见 9.4.4） |
| 段基址表 | 18 项 `base[sel]` 常量（10 位 cumsum），约 **25 LUT** |
| 段选 | `sel` = 满足 `start[i] <= frame_idx` 的**最大 i**（18 路并行比较 + 优先级编码，约 **50 LUT**） |
| 越界 gate | `frame_idx < 4`（首句 0.8 s 前）与 `frame_idx > 624`（片尾 6 帧）时输出 `9'h1FF`，约 **10 LUT** |
| 读口 | BRAM 同步读 1 拍，与 `cjk16_font` 的 1 拍对齐，约 **9 LUT** |
| **LUT 合计** | **约 94** |
| 输出 | `output [8:0] narr_code`；`output narr_valid`（段间为 0 但保持上一段的码，见 9.4.5） |

**18 段的帧号表（`floor(t × 5)`，编译期由 `narration.srt` 换算，不运行时解析）**：

| # | 帧区间 | 字符数 | # | 帧区间 | 字符数 |
|---|---|---|---|---|---|
| 0 | 4 – 19 | 16 | 9 | 317 – 337 | 25 |
| 1 | 21 – 42 | 24 | 10 | 339 – 375 | 37 |
| 2 | 52 – 89 | 39 | 11 | **385 – 438** | **57（最长）** |
| 3 | 92 – 126 | 38 | 12 | 441 – 472 | 34 |
| 4 | 136 – 158 | 23 | 13 | 482 – 498 | 23 |
| 5 | 161 – 199 | 43 | 14 | 500 – 530 | 30 |
| 6 | 201 – 221 | 24 | 15 | 540 – 584 | 44 |
| 7 | 231 – 258 | 29 | 16 | 594 – 613 | 18 |
| 8 | 260 – 307 | 46 | 17 | 615 – 624 | 13 |

#### 9.4.3 `osd_caption.v` 改造（B-lite 方案，+16 LUT）

新增两个输入端口：

```verilog
input wire        narr_en,    // 科普视频字幕使能（来自 video_overlay 的 (info_mode == 2'b01)）
input wire [15:0] frame_idx,  // 视频帧号（来自 rle_decoder.frame_idx）
```

`narr_en` **一个信号兼两用**：

1. **关掉三条静态带**（`SMART CAMPUS` / `PLAY·AUTO·PAUSE` / `IMG #3`）—— 科普模式下屏幕在播 FPGA 介绍视频，右上角却挂着「第 3 张图」，语义错乱；标题行「SMART CAMPUS」与状态行「PLAY」同属图库语义，一并关掉。
   - 做法：`:219 if (caption_en)` 块内，`title_band` 与 `state_band`（含 `index_band`）的判定各乘 `&& !narr_en`；`:258 band_on` 里对应的两条同乘 `!narr_en`（保证衬底压暗也同步消失，不留半透明空框）。
2. **把滚动带的数据源切到 `narr_subline`** —— 滚动带在 `:340` 的 `rep_code` 二选一之前分流：`narr_en` 时 `narr_code[8:0]` **直连** `cjk16_font.glyph`，**跳过 ASCII 占位符替换**（`#`/`*` → 数字的两处逻辑对字幕无意义，字幕文案里不含这两个字符）。

**优先级（从高到低）**：应急滚动（`ticker_emergency = (state_line == STATE_EMERGENCY)`，走 `osd_strings` line 14/15）> 科普视频字幕（`narr_en`）> 日常校园介绍（`seg_line`）。**应急永远最高** —— 即使 `narr_en` 异常为 1，应急文案也不会被视频字幕顶掉。

**LUT 成本**：静态带 gate +4 / 滚动带二选一 +10 / 扇出 +2 = **+16**。

#### 9.4.4 为什么字幕带恒走中文路径

`osd_caption.v:416-420` 的现实现是**按带选路、不按字符码**：

```verilog
wire glyph_on_cjk  = t_on_q && is_cjk_q && cjk_px[~t_bit_q[3:0]];
wire glyph_on_ascii = t_on   && ascii_px[~t_bit[2:0]];
assign caption_pixel = ticker_band ? glyph_on_cjk : glyph_on_ascii;
```

滚动带（`ticker_band`）本来就只取 `cjk16_font` 的输出，三条静态带只取 `osd_font8x16`。所以字幕数据源换成 `narr_subline` 后，**码宽 9 位直接进 `cjk16_font.glyph`，不需要再加 CJK 标志位、也不需要 ASCII 回退分支** —— 字库已核 465 字形覆盖 srt 全部 253 个不同字符（含 `F P G A` 等 23 个非汉字，它们在中文字库里也有全角字形）。

#### 9.4.5 三条边界行为（易漏，写死）

| 情形 | 行为 | 理由 |
|---|---|---|
| `frame_idx < 4`（首句 0.8 s 之前） | **无字幕**（`9'h1FF`） | `frame_idx` 复位后 0~3 帧不满足任何 `start[i] <= frame_idx`（最小 `start[0] = 4`），若不 gate 会落 `sel = 0` 把第一句提前闪出来 |
| `frame_idx > 624`（片尾 6 帧 / 124.9~126.2 s） | **熄灭** | 第 17 段止于 624，之后无内容 |
| 段间空隙（如 20、43~51 帧） | **保持上一段** | 与 `emg_half` 的整轮翻转不同（那是 68.8 s 一轮，远长于一句 3~10 s，不能用来切句）；空隙保持能让句子停留到下一句开始，观感连续 |

> **`caption_band` 的衬底压暗保留**：科普模式下滚动带仍会被压暗 1/4（`img_capped = {2'b00, r_inv[7:2], ...}`）。这**不是 bug、不删** —— 白字压在视频亮画面上需要降底才读得清。压暗只在四块矩形内生效（滚动带 `y∈[448,463]` 全宽、标题 `y∈[16,31]×x∈[32,127]`、图号 `y∈[16,31]×x∈[576,623]`、状态行 `y∈[48,63]×x∈[32,103]`），配置 `narr_en` 后只剩滚动带那一块。

#### 9.4.6 回归成本（t9 复跑对照用）

`tb_osd_caption.v`（557 行）与 `tb_osd_caption_cjk.v`（792 行）**assert 语句数均为 0**（像素比对 / VCD 波形型，靠打印与波形判定），端口全是具名例化。新增两输入只需在各例化处补两行默认值：

```verilog
.narr_en   (1'b0),      // 新增端口默认值：关闭科普字幕
.frame_idx (16'd0),     // 新增端口默认值
```

`tb_video_overlay.v`（676 行）同理（`video_overlay` 内部把 `narr_en` 接到 `u_caption`）。**现有比对逐拍结果不变** —— 因为 `narr_en = 1'b0` 时静态带门控恒真、滚动带走原 `osd_strings` 路径，与原行为逐比特一致。

---

## 10. 顶层例化清单（v2 全量，按数据流排序）

| # | 实例名 | 模块 | 状态 | 时钟域 | 备注 |
|---|---|---|---|---|---|
| 1 | `u_pll` | `hdmi_pll` | 不变 | 50 MHz in | VCO=1000, C0=25, C2=125 |
| 2 | `u_sdram_pll` | `sdram_pll` | 不变 | 50 MHz in | 40 MHz |
| 3 | `u_key` | `key_matrix_4x4` | 不变 | 25 MHz | — |
| 4 | `u_mode_ctrl` | `mode_ctrl` | **新增** | 25 MHz | Key2/Key3/温度；输出 `mode`/`disp_mode`/`state_line`/`blink` |
| 5 | `u_krouter` | `key_router` | **新增（取代 `u_kact`）** | 25 MHz | Key4~Key15 |
| 6 | `u_media` | `media_player` | **改（原 `u_ctrl`）** | 25 MHz | Key0/Key1 |
| 7 | `u_aht20` | `aht20_ctrl` | **新增** | 25 MHz | SCL=D1, SDA=E1 |
| 8 | `u_i2c` | （`aht20_ctrl` 内部例化） | **新增** | 25 MHz | — |
| 9 | `u_hyst` | `temp_hyst_link` | **新增** | 25 MHz | 传感器无关 |
| 10 | `u_vtg` | `video_timing_gen` | 不变 | 25 MHz | 640×480@59.52 |
| 11 | `u_mosaic` | `pix_mosaic` | **新增**（取代并不存在的 `u_geom`） | 25 MHz | Key8 五档**水平**抽样；接在 `u_player` 输出之后、`u_image_mask` 之前 |
| 12 | `u_pat` | `test_pattern_gen` | 不变 | 25 MHz | 坐标直连 `active_x/active_y`（不再经 `src_x/src_y`） |
| 13 | `u_sd` | `sd_spi_ctrl` | 不变 | 25 MHz | 12.5 MHz SCK |
| 14 | `u_probe` | `sd_probe` | 不变 | 25 MHz | — |
| 15 | `u_gallery` | `gallery_probe` | 不变 | 25 MHz | — |
| 16 | `u_player` | `image_player` | **改（`src_w/src_h` + 12 个 `ext_wr_*` 外部写口）** | 25+40 MHz | 内部 `u_reader` 追加 `src_w/src_h` 做**垂直**行映射 |
| 17 | `u_rle` | `rle_decoder` | **新增** | 25 MHz | 科普视频；写口接 `u_player` 的 `ext_wr_*`，**不直接驱动 SDRAM** |
| 18 | `u_wav` | `wav_stream_player` | **新增** | 25 MHz | 音频流 |
| 19 | `u_sdram_sip` | `EG_PHY_SDRAM_2M_32` | 不变 | 40 MHz | 视频与 BMP 共用 A/B 帧缓冲 |
| 20 | `u_image_mask` | `image_window_mask` | 改接线（**位置不变**） | 25 MHz | Key9 五档；物理位置在 `u_content_mux` **之前**，门控**内容层** `pixel_valid`（应急图除外），`win_*` 改接 `u_ratio` |
| 21 | `u_ratio` | `ratio_map`（组合译码） | **新增为独立实例** | 25 MHz | 约 30 LUT；`ratio_sel` → `win_w/win_h/win_off_x/win_off_y`；应急强制 640/480/0/0 |
| 22 | `u_content_mux` | `video_content_mux` | **改（3 源 → 3 源，语义变）** | 25 MHz | 删 `science_rgb` 输入、新增 `emerg_rgb` 输入；不再有科普静态页分支 |
| 23 | `u_emerg_page` | `emerg_page` | **新增** | 25 MHz | 应急平面示意图，纯组合零寄存器，**不经** `u_mosaic` 与 `u_image_mask` |
| 24 | `u_overlay` | `video_overlay` | 改接线 | 25 MHz | 内部 5 档衰减移除；`bright_sel` 接 `bright_lvl[2:0]`（**不得恒接 3'd0**，还需点亮信息条第 8/9/10 格） |
| 25 | `u_brt` | `brightness_apply` | **新增** | 25 MHz | Key6 10 档；overlay 之后、osd_panel 之前；**纯组合零寄存器** |
| 26 | `u_osd_pop` | `osd_autopop` | 改触发源 | 25 MHz | 参数自动弹出 |
| 27 | `u_osd_panel` | `osd_panel` | 改输入 | 25 MHz | 面板**不参与亮度衰减** |
| 28 | `u_axis` | `video_rgb_to_axis` | 不变 | 25 MHz | — |
| 29 | `u_tone` | `audio_tone_gen` | 不变 | 25 MHz | 状态音 |
| 30 | `u_vol` | `vol_apply` | **新增** | 25 MHz | Key7 10 档；应急下限钳位到档 3 |
| 31 | `u_amux` | `audio_src_mux` | **新增** | 25 MHz | 三选一 |
| 32 | `u_arc` | `audio_arc` | 不变 | 25 MHz | ACR_N=6144 |
| 33 | `u_hdmi_core` | `hdmi_1_4b_transmitter_core_wrapper` | 不变 | 25+125 MHz | — |
| 34 | `u_phy` | `hdmi_phy` | 不变 | 125 MHz | — |
| 35 | `u_err` | `err_prompt` | 不变 | 25 MHz | — |
| 36 | `u_buzz` | `buzzer_tone` | 改接线 | 25 MHz | Key15 P2 |
| 37 | `u_pwm_audio` | `pcm_to_pwm` | 改接线 | 25 MHz | 接 `vol_apply` 输出 |
| 38 | `u_wave` | （`video_overlay` 内部例化） | 改接线 | 25 MHz | `viz_en` |
| 39 | `u_dec0~3` | `seg_decoder` ×4 | 不变 | 25 MHz | — |
| 40 | `u_seg` | `seg_scan4` | 不变 | 25 MHz | — |
| 41 | `u_narr` | `narr_subline` | **新增** | 25 MHz | （`osd_caption` 内部例化）科普视频字幕行源，18 段 × 紧凑 563 深 × 9 bit 存 1 块 BRAM9K；`.frame_idx()` 来自 `u_rle` 的 `frame_idx[15:0]` |

**实例数口径（2026-11-02 重新核对，两套数并存不是笔误）**：

- **表内行数 = 41 行**（`u_dec0~3` 占 1 行但含 4 个实例，`u_i2c` 与 `u_wave`、`u_narr` 标为「内部例化」仍列行）
- **物理实例数 = 44 个**（41 行 + `u_dec0~3` 多出的 3 个）
- 早期版本写的「净实例数：39 − 1 + 2 = 40」是**表里还没补进 `u_mode_ctrl` / `u_rle` / `u_wav` / `u_vol` / `u_amux` / `u_brt` 六项时的快照**，现已作废，不要再用 40 或 43 这两个数。

逐项对账（相对 v1 的 39 个实例口径）：

| 变更 | 数量 | 明细 |
|---|---|---|
| 删除 | 1 | `u_science_page`（科普模式改为 RLE 视频，静态科普页废弃；`reports` 口径回收 664 lut / 1,044 le） |
| 新增（v2 新模块） | 8 | `u_mode_ctrl`（`mode_ctrl`）、`u_rle`（`rle_decoder`）、`u_wav`（`wav_stream_player`）、`u_vol`（`vol_apply`）、`u_amux`（`audio_src_mux`）、`u_brt`（`brightness_apply`）、`u_emerg_page`（`emerg_page`）、`u_ratio`（`ratio_map` 改为显式实例，便于单测） |
| 新增（t8 裁定） | 1 | `u_narr`（`narr_subline`，科普视频字幕行源，见 §9.4） |
| 1:1 更换 | 2 | `u_kact`（`key_action`）→ `u_krouter`（`key_router`）、`u_ctrl`（`player_ctrl`）→ `u_media`（`media_player`） |
| 1:1 更换 | 1 | `u_geom`（`video_geom_map`，**RTL 中从未存在**）→ `u_mosaic`（`pix_mosaic`）；垂直方向并入 `u_player` 内部的 `u_reader` |
| 端口/接线扩展 | 7 | `u_player`（+12 `ext_wr_*` + `src_w/src_h`）、`u_image_mask`（`win_*` 改接 `u_ratio`）、`u_content_mux`（`−science_rgb` / `+emerg_rgb`）、`u_overlay`（减内部衰减 + `narr_en` + `frame_idx` 透传 + `level_en(1'b0)` + `caption_en` 改接 `ticker_en_eff`）、`u_pwm_audio`（接 `u_vol`）、`u_tone`（与 `u_wav` 抢线，见下）、`u_amux`（`src_name` 接 `u_wav`） |
| 其余不变 | 28 | — |

> **样本级二选一没有实例行**：`u_tone`（`audio_tone_gen`）与 `u_wav`（`wav_stream_player`）共用 `audio_valid / audio_left / audio_right` 三根线，中间是**顶层级三行组合选择**（`wav_playing ? wav : tone`），不新增模块文件、不占实例行，故不列进上表。t7 落地时直接写在 `rtl/top/dmz_eg4s20_hdmi_top.v` 的赋值区。
>
> **关于「39 项」的口径**：v1 表里的 `video_geom_map` 是一个**只存在于文档、从未写进 RTL** 的模块（见 §3.4 警告块）。v2 用 `pix_mosaic` + `pix_reader` 行映射真正实现它，实例数上仍是 1 个（`u_mosaic`）。

---

## 11. 视频播放路线（P1 序列帧 + RLE，已确认）

### 11.1 结论

**640×480 RGB565，RLE 游程压缩，固定 5 fps。**

**帧率口径**：初版文档曾设定「5 fps 目标 / 持续欠载时自动降到 2 fps」，**该自动降级逻辑从未在 RTL 实现**（`dmz_eg4s20_hdmi_top.v:521` 把 `.play_fps` 硬接常量 `8'd5`；`rle_underrun` 接出来但零消费者，见 `:511` / `:528`）。当前实现是**固定 5 fps**，欠载时**停在上一个已显示帧、不插黑、不撕裂**（`rle_decoder.v:29`）。「2 fps」只是带宽核算里的一个假设工况（见 §11.3 的两行 @2fps 数据），**不是系统能力，也不是承诺下限**。

### 11.2 白话说明（必须原样进答辩材料）

> 「科普模式的视频是**满分辨率 640×480**，但帧率只有 **5 帧/秒**，看起来像幻灯片切换，不是流畅视频。这是 **SD 卡 SPI 接口的物理带宽上限**决定的 —— 不是实现偷懒。我们做了游程压缩（因为素材是大片纯色的 PPT 风格动画，压缩比 0.206），把帧率从 1 fps 提到 5 fps，但这已经是这条 SPI 线的极限。」

### 11.3 带宽与容量完整账

| 项 | 数值 | 推导 |
|---|---|---|
| 单帧未压缩 | 614,400 B | 640 × 480 × 2 B（RGB565） |
| RLE 均值 | **129,852 B** | captain 实测 127 帧抽样，RLE 3B/run |
| RLE 最坏 | **202,431 B** | 同上，p95 = 194,003 B |
| RLE 最优 | 1,440 B | 纯色页 |
| 压缩比 | **0.206** | 129,852 / 614,400 |
| **@2fps 均值** | **0.260 MB/s** | 129,852 × 2 |
| **@2fps 最坏** | 0.405 MB/s | 202,431 × 2 |
| **@5fps 均值** | **0.649 MB/s** | 129,852 × 5 |
| **@5fps 最坏** | **1.012 MB/s** | 202,431 × 5 |
| @8fps 均值 | 1.039 MB/s | 越界（83%），不取 |
| @8fps 最坏 | 1.619 MB/s | **越界（130%）**，不取 |
| 音频（48kHz/16bit/单声道） | 0.096 MB/s | 48,000 × 2 |
| **合计 @5fps 均值** | **0.745 MB/s** | 占实用带宽 **59.6%** ✅ |
| **合计 @5fps 最坏** | **1.108 MB/s** | 占 **88.6%** ⚠️ 临界 |
| **合计 @2fps 均值** | **0.356 MB/s** | 占 **28.5%** ✅ |

### 11.4 缓冲与欠载策略（临界值的应对）

**问题**：@5fps 最坏帧 + 音频 = 88.6% 占用，余量仅 11.4%。若遇到连续最坏帧，会欠载。

**应对（三层）**：

| 层 | 措施 | 参数 |
|---|---|---|
| ① 抖动缓冲 | **就是 A/B 双缓冲本身**（不另设分区、不缓存压缩码流）：解压后整帧直写 `image_player` 的帧缓冲，每帧恒 **153,600 words** | 帧 A `[0x00000,0x257FF]`、帧 B `[0x25800,0x4AFFF]`、其余 `[0x4B000,0x1FFFFF]` 保留。**抖动深度 2 帧 = 400 ms @5fps**，相对最坏帧 162.2 ms（实用口径：396 块 × 409.6 μs）有 **2.47 倍裕度**（理论口径 129.8 ms → 3.08 倍） |
| ② 欠载保持上一帧 | `underrun = 1` 时 `pix_reader` 继续读旧帧，**不插黑、不清屏** | 理由：插黑会让「帧率不足」变成肉眼可见的闪烁；保持上一帧只是略卡 |
| ③ ~~自动降帧率~~ **（设计目标未落地，已作废）** | ~~连续 3 帧 `underrun` → `play_fps` 从 5 降到 2~~ —— **该逻辑从未在 RTL 实现**（`play_fps` 顶层硬接 `8'd5`，`rle_underrun` 零消费者）；欠载时的真实行为见 ② | 不需要这一层：② 已保证「不插黑、不撕裂」，且不降分辨率（降分辨率会连锁影响 Key8 五档与读出侧抽样的倍率） |

**「欠载保持上一帧」怎么保证读到的是完整帧（三重机制，全部为既有逻辑）**：

| 重 | 机制 | 位置 |
|---|---|---|
| 一 | **全帧写完成判据**：`ext_wr_done` 只在整帧 153,600 words 全部写完时单拍置高；`play_en` 拉低或模式切走强制清 `frame_word_cnt`，不发 `ext_wr_done`（整帧原子性） | `rle_decoder` |
| 二 | **换帧只发生在垂直消隐**：`front_sel` 的三处翻转点全部被 `vblank_rise = ext_vblank && !vblank_d` 门控，读到一半不可能切 bank | `image_player` |
| 三 | **消隐期五状态清场**：`P_RUN → P_QUIET → P_DRAIN → P_RESTART → P_READY → P_RUN`，`P_DRAIN` 等 FIFO 排空（`ARM_SETTLE_C=8`）、`P_RESTART` 等 `rd_restart_done` 锁新 `rd_frame_base`，进 `P_RUN` 前 FIFO 已真空 | `pix_reader` + `framebuf_arbiter` |

> 因此「欠载时保持上一帧」**不需要任何额外逻辑**：`ext_wr_done` 不来 → `commit_pending` 不置位 → `front_sel` 不翻 → 读侧继续读旧帧。与「BMP 慢卡停在上一张」同构。

**风险声明（必须写进 PLAN 风险章节）**：
> **固定 5 fps。** 若上板实测发现 5 fps 持续欠载（例如 SD 卡质量差、块读取延迟超预期），系统的行为是**停在上一个已显示帧、不插黑、不撕裂**（`rle_decoder.v:29`），**不会自动降帧**。初版文档曾写过「自动降到 2 fps / 2 fps 是承诺下限」，那是**设计目标未落地** —— 该逻辑从未在 RTL 实现，已作废。带宽核算里的 @2fps 一行只是**假设工况**，不是系统能力。

### 11.5 为什么不用 JPEG / MJPEG

| 理由 | 数据 |
|---|---|
| 无现成 JPEG 解码 RTL | 工程内无任何 JPEG 相关模块 |
| 自研 LUT 需求 | 基线 JPEG 解码器（Huffman + IDCT + 上采样）≈ **20,000+ LUT** |
| 可用 LUT 余量 | **247（1.26%）** —— t7-B 集成综合实测 19,353/19,600 = 98.74%；或 **4,281**（当前基线 15,319 口径） |
| 缺口 | **81 倍**（20,000 ÷ 247）/ **4.7 倍**（20,000 ÷ 4,281，相对当前基线） |
| DSP 需求 | IDCT 需 8~16 个乘法器，**DSP 余量仅 10 个** |

**结论：JPEG 物理不可行。** RLE 是唯一能用 < 400 LUT 换到 5 倍压缩的方案。

### 11.6 P2 增强（记录，不实现，不进里程碑）

**SDRAM 预载循环**：把整段 RLE 视频（或解压后的 11 帧 RGB565）预载进 SDRAM，之后循环播放，可达 60 fps。

| 项 | 数值 |
|---|---|
| 11 帧 RGB565 未压缩 | 11 × 614,400 B = **6.76 MB** |
| SDRAM 剩余可用 | **6.83 MB**（扣除双帧缓冲后） |
| 资源代价 | 需把 `pix_reader` 的 `rd_base` 改为可切换多帧，约 +200 LUT；SDRAM 几乎占满，无余量给其他用途 |
| 为什么不做 | ① 占满 SDRAM 使任何后续扩展（更多图片、更长视频）不可能；② 11 帧 @60fps = 0.18 s 循环，视觉上是「抖动的 0.18 秒」，**体验反而更差**；③ 预载 6.76 MB 需 5.4 s（按 1.25 MB/s），启动延迟不可接受 |

**结论：P2 看似能「跑满 60fps」，实则循环周期太短，体验不如 5 fps 的完整序列。记录为后续可选增强，本版不实现。**

---

## 12. 无悬空项声明

| 项 | 结论 |
|---|---|
| 三模式状态机是否有完整转移表 | 是。§2.2 覆盖 10 种转移，含温度自动触发与 Key3 双确认退出 |
| 应急退出条件与迟滞是否明确 | 是。§2.3 温度迟滞（45/40 ℃，3/5 次）+ §2.4 Key3 双按确认 2 s 窗口；温度回落不自动退出 |
| 16 键是否有最终映射 | 是。见 `KEYMAP.md` §2，含新旧对照与迁移影响面 |
| 五档分辨率是否有可直接翻成 parameter 的表 | 是。§3.2 给出 `src_w/src_h/放大比/DDA 增量` 五档完整表 |
| 多像素时钟方案是否给出 | 是。§3.1 论证 N1（固定输出时序）为唯一可行解，§8 论证零新增 PLL |
| 五档屏占比是否有定义 | 是。§4.1 给出 `win_w/win_h/off_x/off_y` 五档表 |
| 实时缩放 vs 预生成图是否取舍 | 是。§4.2 六维对比，采用实时窗口裁剪（+30 LUT vs 素材 ×5） |
| 视频路线是否可落地 | 是。§11 给出 P1（RLE @固定 5 fps，欠载保持上一帧）+ 三层缓冲策略 + P2 记录 |
| 音频路线是否可落地 | 是。§7 给出 WAV 流播放 + 10 档音量 + 可视化源切换 + 应急禁静音四重保险 |
| AHT20 方案是否完整 | 是。§8 给出引脚（D1/E1 复用标注）、开漏实现、上拉、命令序列、换算（零 DSP）、迟滞；**Plan B（NTC）已裁决不实施**（RC-V2-01），§8.7 仅作论证备查 |
| 每个新模块是否有端口清单 | 是。`mode_ctrl`(§2.5) / `pix_mosaic`(§3.4) / `pix_reader` 行映射(§3.4) / `rle_decoder`(§6.5) / `wav_stream_player`(§6.6) / `aht20_ctrl`(§8.5) / `temp_hyst_link`(§8.6) / `brightness_apply`(§9.3) / `emerg_page`(`ARCH_ADDENDUM_VIDEO_PATH.md` §9.3) / `key_router`(`KEYMAP.md` §7) / `vol_apply`(§7.3 代码) / `audio_src_mux`(§7.2 代码) / `cjk16_font`(`FONT_ARCH_RULING.md` §7.8) |
| 每个新模块是否有时序约定 | 是。每个端口契约后均附「接口时序约定」小节 |
| 亮度位置是否有论证 | 是。§9.2 四级对比，采用第 6 级（`overlay` 之后、`osd_panel` 之前），保证参数面板不被调暗 |
| 是否引用了既有模块而非重造 | 是。`video_overlay` / `osd_caption` / `fade_mixer` / `audio_waveform` / `video_timing_gen` / `image_window_mask` / `fat32_reader` / `img_scaler` / `image_player` / `player_ctrl` / `key_matrix_4x4` / `osd_autopop` / `osd_panel` / `pcm_to_pwm` / `audio_arc` 全部复用，§10 例化清单逐项标注「不变/改接线/新增」 |
| 是否说明了不新增 PLL | 是。§3.1 + `RESOURCE_BUDGET.md` §5.4 |
| 是否说明了不新增 DSP | **措辞已更正（2026-11-02）**：不再是「不新增」。`RESOURCE_BUDGET.md` §3.4 新增「DSP 实测纠正」块 —— 算法层确实全部用移位加 / 组合查表（成立），但 t7-A 实测 **24/29 = 82.76%（+5）**，来源是 `wav_stream_player` 内部第 3 份 `fat32_reader`（每份 6 DSP），属预算表结构性漏项。§3.5 双线性插值（+12）否决理由不变且更硬：24 + 12 = 36 > 29。**DSP 硬上限 29、余 5，任何再增 DSP 的方案必须报 captain 复核** |
| 资源口径是否有唯一来源 | 是。**当前唯一对外口径是 t7-B 集成综合实测 `19,353 / 19,600 = 98.74% / 余 247`**（`reports/t7b_gate_area.txt`，2026-11-02 18:57:07，`optimize_gate` 阶段）：`#Total_luts 11,282 + ripple 8,071 = #lut 19,353`（**`#Total_luts` 是独立查找表逻辑，`ripple` 是加法/比较进位链占用的 LUT 槽位 —— 两者都是真实逻辑，不是「开销」**）；REG **8,305（42.37%）**、BRAM **35/64（54.69%）**、DSP **24/29（82.76%，余 5）**、IO **43/188**。口径经**四次裁定**：17,513（11-01）→ 17,603 → 17,892（均为预算表内部纠正）→ **19,353（全设计集成综合实测，同一条纪律的终点形态）**；更早的差分凑数那批一律只允许出现在 `RESOURCE_BUDGET.md` §3.4 的「口径差异说明」段作历史引用，`docs/plan_v2/` 其余位置与任何对外材料不得出现 |
  **t7-A 中间快照（2026-11-02 17:39:02 重跑版，不作口径）**：LUT 17,299（88.26%）、REG 7,713（39.35%）、BRAM 34、DSP 24、IO 43。**该报告是在顶层 6 处常量驱动下取的，被常量传播剪掉了约 +2,054 LUT**（`u_rle` 未例化、`narr_en` 接常量 0、`fade_level` 常量等），**不得当基线引用** —— 详见 `RESOURCE_BUDGET.md` §3.7 反例四。**注意阶段：基线 15,319 是 place/route 后，t7-A 的 17,299 是 optimize_gate 后，t7-B 的 19,353 也是 optimize_gate 后但已无常量驱动，三者阶段与前提均不同。**
| 是否有已登记的功能降级 | 是。三项，见 `RESOURCE_BUDGET.md` §3.6：**D-01** 单传感器无冗余（只用 AHT20，Plan B 不实施，AHT20 失效时只剩 Key3 双按手动入口，进 t11 已知降级项）｜**D-02** 自动轮播倍率不可调（`auto_sw_sel` 固定 `2'd0`）｜**D-03** 音频电平条图层停用（`level_en` 固定 `1'b0`，见 §7.4） |