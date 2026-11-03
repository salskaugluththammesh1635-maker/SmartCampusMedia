# KEYMAP — 16 键最终映射表（v2 重构版）

> 文件：`docs/plan_v2/KEYMAP.md`
> 版本：v2.0 · 2026-11-01 · 作者：architect
> 状态：**唯一权威键位来源**。本文件生效后，`docs/keymap_2026-10-26.md` 自动降级为历史归档（只读，不再修改）。
> 上级文档：`docs/plan_v2/PLAN.md`（主计划书）、`docs/plan_v2/ARCH.md`（架构书）
> 赛规依据：`reports/plan_v2/SPEC_CONSTRAINTS.md` §1.1 / §2 / §3；需求裁决：`reports/plan_v2/REQ_GAP.md` §6 C1~C9

---

## 0. 阅读须知（三条铁律）

**铁律 1 · 一键一模块**：同一个 `key_code` 在整份工程中**只能被一个模块消费**。任何键在顶层出现第二处 `key_event && key_code == N` 判定，即为违规（会造成多驱动或语义歧义，TD 综合报错或行为不可预测）。

**铁律 2 · 逻辑键号与物理位置解耦**：`rtl/input/key_matrix_4x4.v` 输出的 `key_code[3:0]`（0~15）是本文件与全部下游 RTL 之间的**唯一接口**。物理行列扫描顺序（`key_row`/`key_col` 的排布）与逻辑键号无耦合关系 —— 见 §6 关于行序资料冲突的处置。

**铁律 3 · 消费点登记**：每个键号必须在 §2 表中登记唯一的「消费模块」与「信号名」。新增键功能必须回到本文件登记，禁止在 RTL 里临时加判定。

---

## 1. v1 历史键位（2026-10-26 版）—— **已废弃，仅供追溯，不得引用**

来源：`docs/keymap_2026-10-26.md` 行 28–42，逐条与 RTL 核对后的实况表。**⚠️ 本表是 v1 历史快照，已废弃、不得引用** —— 现行键位见 **§2.1 主功能键（Key0~Key10）** 与 §2.2 备用键（Key11~Key15），RTL 真值见 `rtl/control/key_router.v:116-127`（`K_AUDIO=4'd4` … `K_BEEP=4'd15`）。保留本表**只为追溯「哪些 v1 功能被移除」**（见 §2.3），不得作为任何实现或验收的依据。

| 键号 | 物理位置 KEY(r,c) | 消费模块（RTL 文件） | 功能 | 输出信号 |
|---|---|---|---|---|
| KEY0 | KEY(0,0) | `rtl/control/player_ctrl.v` | 上一张图片 | `img_index--`（EV_PREV） |
| KEY1 | KEY(0,1) | `rtl/control/player_ctrl.v` | 下一张图片 | `img_index++`（EV_NEXT） |
| KEY2 | KEY(0,2) | `rtl/control/player_ctrl.v` | 自动轮播 开/关 | `auto_play_en`（EV_PLAY） |
| KEY3 | KEY(0,3) | `rtl/control/player_ctrl.v` | 模式循环 日常→科普→应急→日常 | `mode[1:0]`（EV_MODE） |
| KEY4 | KEY(1,0) | `rtl/top/dmz_eg4s20_hdmi_top.v` | 上一测试图案 | `pattern_sel--` |
| KEY5 | KEY(1,1) | `rtl/top/dmz_eg4s20_hdmi_top.v` | 下一测试图案 | `pattern_sel++` |
| KEY6 | KEY(1,2) | `rtl/top/dmz_eg4s20_hdmi_top.v` | 音频静音 开/关 | `audio_muted` |
| KEY7 | KEY(1,3) | `rtl/control/key_action.v` | 亮度循环（5 档 0~4） | `bright_sel[2:0]` |
| KEY8 | KEY(2,0) | `rtl/control/key_action.v` | 反色 开/关 | `invert_en` |
| KEY9 | KEY(2,1) | `rtl/control/key_action.v` | 轮播倍率循环 | `auto_sw_sel[1:0]` |
| KEY10 | KEY(2,2) | `rtl/control/key_action.v` → `rtl/storage/gallery_probe.v` | 图库重扫（单拍） | `rescan_req` |
| KEY11 | KEY(2,3) | `rtl/control/key_action.v` | 九宫格辅助线 开/关 | `grid_en` |
| KEY12 | KEY(3,0) | `rtl/control/key_action.v` | 信息条 OSD 开/关 | `info_en` |
| KEY13 | KEY(3,1) | `rtl/control/key_action.v` | 音频图层 4 态循环 关→电平→波形→电平+波形 | `level_en` / `wave_en` |
| KEY14 | KEY(3,2) | `rtl/control/key_action.v` | 蜂鸣器静音 开/关 | `beep_muted` |
| KEY15 | KEY(3,3) | `rtl/control/player_ctrl.v` | 应急直达（最高优先级） | `state <= S_EMERG`（EV_EMERG） |

**注**：v1 文档表格漏列 KEY14（蜂鸣器静音），但 `rtl/control/key_action.v` 中确实存在 `K_BEEP = 4'd14`，本表已补全。v1 的 16 个键位全部占用，无空闲键。

---

## 2. 新版键位（v2，本文件生效）

### 2.1 主功能键（Key0~Key10，P0 必做）

| 键号 | 物理位置 | 消费模块（新/改） | 功能 | 输出信号 | 作用域 |
|---|---|---|---|---|---|
| **Key0** | KEY(0,0) | `rtl/control/media_player.v`（原 `player_ctrl.v` 裁剪） | 上一张图片 | `img_index--` | 日常 / 科普；应急无效 |
| **Key1** | KEY(0,1) | `rtl/control/media_player.v` | 下一张图片 | `img_index++` | 日常 / 科普；应急无效 |
| **Key2** | KEY(0,2) | `rtl/control/mode_ctrl.v`（新） | 模式循环 日常→科普→日常 | `mode_cycle_req` | 日常 / 科普；应急无效 |
| **Key3** | KEY(0,3) | `rtl/control/mode_ctrl.v`（新） | 应急直达 / 应急确认退出 | `emerg_key_req` | **全状态有效**（含应急内） |
| **Key4** | KEY(1,0) | `rtl/control/key_router.v`（新） | 音频输出 开/关 | `audio_en` | 日常 / 科普；**应急强制开** |
| **Key5** | KEY(1,1) | `rtl/control/key_router.v` | 底部滚动字幕 开/关 | `ticker_en` | 日常 / 科普；**应急强制开** |
| **Key6** | KEY(1,2) | `rtl/control/key_router.v` | 亮度 10 档递增循环（0→1→…→9→0） | `bright_lvl[3:0]` | 全状态有效 |
| **Key7** | KEY(1,3) | `rtl/control/key_router.v` | 音量 10 档递增循环（0→1→…→9→0） | `vol_lvl[3:0]` | 全状态有效 |
| **Key8** | KEY(2,0) | `rtl/control/key_router.v` | 内部渲染分辨率 5 档循环 | `res_sel[2:0]` | 全状态有效 |
| **Key9** | KEY(2,1) | `rtl/control/key_router.v` | 屏占比 5 档循环（1/2→5/8→3/4→7/8→1→1/2） | `ratio_sel[2:0]` | 全状态有效 |
| **Key10** | KEY(2,2) | `rtl/control/key_router.v` | 音频可视化图层 开/关 | `viz_en` | 全状态有效（应急可关） |

### 2.2 备用键（Key11~Key15，P2 可选，资源不足时整体裁掉）

| 键号 | 物理位置 | 保留用途（登记值） | 计划消费模块 | 优先级 |
|---|---|---|---|---|
| Key11 | KEY(2,3) | SD 卡热插拔后**图库重扫**（原 KEY10 功能迁移） | `rtl/storage/gallery_probe.v`（`rescan_req`） | P2 |
| Key12 | KEY(3,0) | **测试图案循环**（产线自检 / 演示用，原 KEY4+KEY5 合并为单键循环） | `rtl/video/test_pattern_gen.v`（`pattern_sel[2:0]`） | P2 |
| Key13 | KEY(3,1) | **反色显示**（强光环境演示辅助，原 KEY8 功能迁移） | `rtl/video/video_overlay.v`（`invert_en`） | P2 |
| Key14 | KEY(3,2) | **九宫格辅助线**（几何对齐调试，原 KEY11 功能迁移） | `rtl/video/video_overlay.v`（`grid_en`） | P2 |
| Key15 | KEY(3,3) | **蜂鸣器静音**（演示时关闭提示音，原 KEY14 功能迁移） | `rtl/audio/buzzer_tone.v`（`beep_muted`） | P2 |

**备用键纪律**：
- Key11~Key15 在 P0/P1 阶段**不实现**，`key_router.v` 对其输出恒 0 的寄存器（保持编译期可综合，不产生悬空）。
- 若资源裁剪触发 P2（见 `RESOURCE_BUDGET.md` §4），**从 Key15 倒序整块移除**，每移除一个回收约 40 LUT。
- 备用键的具体用途在此登记后不得在 RTL 中改用其他功能，避免与本文档失同步。

### 2.3 被移除的 v1 功能及去向

| v1 功能 | v1 键号 | v2 处置 | 理由 |
|---|---|---|---|
| 自动轮播开关 | KEY2 | **移除按键，改为日常模式常开** | 「校园媒体终端」的默认行为就是循环播放；赛规 1.3 未要求可控。`auto_play_en` 在 `mode == DAILY` 时恒 1，科普/应急恒 0 |
| 轮播倍率 | KEY9 | **移除按键，固定为 3 s/张**（`auto_sw_sel[1:0]` 顶层固定接 `2'd0`）| 用户需求未涉及；固定值减少一个状态变量。此项登记为降级项 **D-02**（见 `RESOURCE_BUDGET.md` §3.6） |
| 信息条 OSD 开关 | KEY12 | **移除按键，改为参数变化自动弹出** | 见下方 §2.4。更符合赛规 1.4(4)「按键调节亮度后，参数变化信息可读」——自动弹出比手动开关更直接满足 |
| 音频图层 4 态循环 | KEY13 | **拆分为 Key10 单开关**（波形图层） | 波形图层由 Key10 (`viz_en`) 控制；**电平条（`level_en`）固定 `1'b0` 停用** —— 降级项 **D-03**（见 `RESOURCE_BUDGET.md` §3.6 与 `ARCH.md` §7.4）。早期草稿曾写「电平条随音频常开」，已裁定废止：电平条只是同一路音频的零维表示，信息量被波形层严格包含，两层同开会叠两条反映同一件事的图层 |
| 音频静音 | KEY6 | **功能保留，迁移到 Key4**（音频开关） | 语义从「静音」升级为「音频输出开关」，与用户需求「音频开关」一致 |
| 亮度 5 档 | KEY7 | **升级为 10 档，迁移到 Key6** | 用户 m00001 要求 10 档 |
| 反色 | KEY8 | 迁移到 Key13（P2 备用） | 非用户需求，非赛规要求，降级 |
| 上一/下一测试图案 | KEY4/KEY5 | 合并为单键循环，迁移到 Key12（P2 备用） | 两键占位过多，合并 |
| 九宫格 | KEY11 | 迁移到 Key14（P2 备用） | 纯调试功能 |
| 图库重扫 | KEY10 | 迁移到 Key11（P2 备用） | 使用频率低，但换卡场景确有价值 |
| 蜂鸣器静音 | KEY14 | 迁移到 Key15（P2 备用） | 演示辅助 |
| 模式循环 | KEY3 | 迁移到 **Key2** | 用户需求指定 Key2 |
| 应急直达 | KEY15 | 迁移到 **Key3** | 用户需求指定 Key3 |

### 2.4 参数 OSD 自动弹出（替代 v1 的 KEY12 信息条开关）

**设计**：Key6（亮度）/ Key7（音量）/ Key8（分辨率）/ Key9（屏占比）/ Key4（音频）/ Key5（字幕）/ Key10（可视化）任一按键按下时，`osd_panel` 自动显示 2.5 s，内容为当前全部参数的数值。

**实现**：复用既有 `rtl/osd/osd_autopop.v`（`HOLD_MS = 2500`），把触发源从「参数值变化」扩展为「上述 7 个键的 `key_event` 或参数值变化」。**零新增资源**（该模块已存在，仅扩展输入）。

**赛规价值**：赛规 1.4(4) 原文要求「按键调节亮度后，参数变化信息可读」。自动弹出使这一条**无需用户额外操作即可满足**，比手动开关更稳。

---

## 3. 新旧对照总表（一眼看冲突面）

| 键号 | v1 功能 | v2 功能 | 变更类型 |
|---|---|---|---|
| Key0 | 上一张 | 上一张 | ✅ **不变** |
| Key1 | 下一张 | 下一张 | ✅ **不变** |
| Key2 | 自动轮播开关 | **模式循环** | ⚠️ 冲突（占用 v1 的 Key3 功能） |
| Key3 | 模式循环 | **应急直达** | ⚠️ 冲突（占用 v1 的 Key15 功能） |
| Key4 | 上一测试图案 | **音频开关** | ⚠️ 冲突（全新功能） |
| Key5 | 下一测试图案 | **底部字幕开关** | ⚠️ 冲突（全新功能） |
| Key6 | 音频静音 | **亮度 10 档** | ⚠️ 冲突（占用 v1 的 Key7 功能） |
| Key7 | 亮度 5 档 | **音量 10 档** | ⚠️ 冲突（全新功能） |
| Key8 | 反色 | **分辨率 5 档** | ⚠️ 冲突（全新功能） |
| Key9 | 轮播倍率 | **屏占比 5 档** | ⚠️ 冲突（全新功能） |
| Key10 | 图库重扫 | **音频可视化开关** | ⚠️ 冲突（占用 v1 的 Key13 部分功能） |
| Key11 | 九宫格 | 备用（图库重扫） | ⚠️ 冲突 |
| Key12 | 信息条 OSD | 备用（测试图案） | ⚠️ 冲突 |
| Key13 | 音频图层 4 态 | 备用（反色） | ⚠️ 冲突 |
| Key14 | 蜂鸣器静音 | 备用（九宫格） | ⚠️ 冲突 |
| Key15 | 应急直达 | 备用（蜂鸣器静音） | ⚠️ 冲突 |

**冲突统计：16 键中仅 2 键（Key0/Key1）语义不变，14 键（87.5%）变更。** 这是一次**全面重排**，不存在「部分兼容」的可能 —— 任何按 v1 键位写死的注释、文档、演示脚本、答辩材料都必须同步更新。

---

## 4. 迁移影响面（逐文件）

### 4.1 需要改动的 RTL 文件

| 文件 | 改动性质 | 具体影响 |
|---|---|---|
| `rtl/control/key_action.v` | **整块废弃，由 `key_router.v` 取代** | 原 `K_BRIGHT/K_INVERT/K_AUTOSW/K_RESCAN/K_GRID/K_INFO/K_LEVEL/K_BEEP` 八个 localparam 全部失效；`bright_sel[2:0]` 从 5 档扩为 `bright_lvl[3:0]` 10 档；`wave_en`/`level_en` 拆分由 `viz_en` + 常开电平条取代 |
| `rtl/control/player_ctrl.v` | **裁剪为 `media_player.v`** | 移除 `K_PLAY`/`K_MODE`/`K_EMERG` 三个键判定与 `EV_PLAY`/`EV_MODE`/`EV_EMERG` 三个事件；`mode[1:0]` 输出改由 `mode_ctrl.v` 驱动（本模块降级为纯图片浏览子状态机）；保留 `K_PREV`/`K_NEXT` 与 `img_index`/`auto_play_en`（日常恒 1） |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | **中等改动** | ① 删除 KEY4/KEY5 的 `pattern_sel` 增减逻辑（约 8 行）；② 删除 KEY6 的 `audio_muted` 翻转逻辑（约 4 行）；③ 新增 `key_router` / `mode_ctrl` / `video_geom_map` / `brightness_apply` / `vol_apply` / `i2c_master` / `aht20_ctrl` / `rle_decoder` / `media_player` 例化；④ `caption_en` 从硬接 `1'b1` 改为受 `ticker_en` 与 `mode` 控制；⑤ 像素通路插入 `brightness_apply`（在 `video_overlay` 之后、`osd_panel` 之前）；⑥ `u_image_mask` 的 `win_*` 输入从 `image_player.out_*` 改接 `ratio_map`（**位置不变，仍在 `video_content_mux` 之前**） |
| `rtl/video/video_overlay.v` | **小幅改动** | `bright_sel[2:0]` 输入改接 `bright_lvl[2:0]`（**不得恒接 3'd0** —— 它还要点亮信息条第 8/9/10 格，见 §4.3）；模块内 5 档衰减运算整体移除，避免与 `brightness_apply.v` 二次衰减；`caption_en` 语义不变但源改为 `ticker_en` |
| `rtl/video/science_page.v` | **小幅改动** | `active_x`/`active_y` 输入改接 `video_geom_map` 输出的 `src_x`/`src_y`（端口名不变，仅顶层连线变更，**模块内部零改动**） |
| `rtl/video/test_pattern_gen.v` | **小幅改动** | 同上，坐标输入改接 `src_x`/`src_y` |
| `rtl/storage/image_player.v` | **中等改动** | 新增 `src_w`/`src_h` 输入（逻辑分辨率），`pix_reader` 的行列步进由固定 `PIX_PER_LINE=640` 改为按 `src_w` 映射 |
| `rtl/video/audio_waveform.v` | **小幅改动** | `wave_en` 输入改接 `viz_en`（由 Key10 驱动） |

> ⚠️ **`video_overlay.v` 的 `bright_sel[2:0]` 不得恒接 `3'd0`**
>
> `rtl/video/video_overlay.v:211-213` 的 `box_lit` 用 `bright_sel[0]/[1]/[2]` 三位点亮信息条第 8/9/10 格。若把 `bright_sel` 恒接 `3'd0`，这**三格会恒灭**，信息条功能退化。
>
> 正确接法：`.bright_sel(bright_lvl[2:0])` —— **亮度衰减数据通路拆掉（避免与 `brightness_apply.v` 二次衰减），但 `bright_sel` 仍作显示用途保留**。两个用途在同一信号上共存，互不冲突。

### 4.2 需要同步的文档

| 文件 | 同步内容 |
|---|---|
| `docs/keymap_2026-10-26.md` | **冻结为历史归档**，文件头加一行「⚠️ 本表已于 2026-11-01 被 `docs/plan_v2/KEYMAP.md` v2.0 取代，仅作历史记录，请勿据此编码」 |
| `README.md` | 按键说明章节整段替换 |
| `rtl/top/dmz_eg4s20_hdmi_top.v` 文件头注释 | 键位表注释整段替换（当前注释声称「16 个键已全部占满」，v2 后 Key11~Key15 为空闲备用） |
| `rtl/top/bringup_top.v` 文件头（若存在键位注释） | 同步 |
| 答辩材料 / 演示脚本 | 全部按键流程重写 |

### 4.3 不受影响的部分

以下模块**不含任何键号判定**，无需改动：`rtl/input/key_matrix_4x4.v`、`rtl/storage/{sd_spi_ctrl,fat32_reader,bmp_parser,img_loader,img_scaler,pix_reader,framebuf_arbiter,sdram_ctrl_wrap,sd_probe,gallery_probe,fade_mixer}.v`、`rtl/video/{video_timing_gen,video_content_mux,image_window_mask,video_rgb_to_axis}.v`、`rtl/osd/*`、`rtl/audio/{audio_tone_gen,pwm_audio_out,pcm_to_pwm,buzzer_tone}.v`、`rtl/video/hdmi/*`。

---

## 5. 三模式下的按键作用域矩阵

`✓` = 有效；`✗` = 按键被忽略（不产生任何状态变化，但**不吞掉 key_event**，`key_event` 仍为单拍脉冲供其他逻辑观察）；`锁` = 强制为固定值且按键无效。

| 键 | 日常 DAILY | 科普 SCIENCE | 应急 EMERG | 说明 |
|---|---|---|---|---|
| Key0 上一张 | ✓ | ✓ | ✗ | 应急锁画面 |
| Key1 下一张 | ✓ | ✓ | ✗ | 应急锁画面 |
| Key2 模式循环 | ✓ | ✓ | ✗ | 应急下不能切走，必须走 Key3 确认退出 |
| Key3 应急直达 | ✓（进入） | ✓（进入） | ✓（确认退出） | 唯一全状态有效的键 |
| Key4 音频开关 | ✓ | ✓ | **锁 1** | 应急广播必须出声，不允许静音 |
| Key5 字幕开关 | ✓ | ✓ | **锁 1** | 应急字幕是必需输出（提示文案），不可关 |
| Key6 亮度 | ✓ | ✓ | ✓ | 应急时允许调亮（现场光照差异大），10 档全开 |
| Key7 音量 | ✓ | ✓ | ✓ | 应急时允许调音量（但不能关到 0，见 §5.1） |
| Key8 分辨率 | ✓ | ✓ | ✓ | 纯视觉参数，无安全影响 |
| Key9 屏占比 | ✓ | ✓ | ✓ | 纯视觉参数，无安全影响 |
| Key10 可视化 | ✓ | ✓ | ✓ | 不影响必需输出，允许关闭 |
| Key11~15 备用 | ✓ | ✓ | ✓ | P2，实现后同样全状态有效 |

### 5.1 Key7 音量在应急模式下的下限保护

应急模式下 `vol_lvl` 循环到 0 时，**实际输出增益钳位到档位 3（13/32 = 40.6%）**，而非真正的 0。理由：应急广播静音等同于功能失效，与 Key4 强制开同理。

实现点：`rtl/audio/vol_apply.v` 内部
```verilog
wire [3:0] eff_lvl = (mode == MODE_EMERG && vol_lvl < 4'd3) ? 4'd3 : vol_lvl;
```
`vol_lvl` 寄存器本身仍记录用户选择的 0，退出应急后自动恢复用户的 0 档（不篡改用户设置）。

### 5.2 为什么 Key5 与 Key10 必须独立（给 RTL 的明确禁令）

**禁令**：`rtl/control/key_router.v` 中 `ticker_en` 与 `viz_en` **必须是两个独立的寄存器，禁止合并为一个 `osd_en` 或 `layer_en`**。

理由：两者语义完全不同 ——
- `ticker_en` 控制**底部滚动字幕条**（`osd_caption.v` 的 `TICKER_Y0=448..TICKER_Y1=463` 区域），承载**文本信息**（日常=校园介绍，科普=视频字幕，应急=应急提示文案）。
- `viz_en` 控制**音频波形图层**（`audio_waveform.v` 的 `X0=64..X1=576, Y_CENTER=200` 区域），承载**音频可视化**（赛规 1.4(5) 扩展加分项）。

两者在屏幕上的位置、内容类型、赛规归属全部不同。合并会导致：应急模式下要求「字幕锁开 + 可视化可关」这一组合**无法表达**（一个开关不可能同时是「强制 1」和「可切 0」）。这是本设计中最容易被误合并的一对信号，特此单列。

### 5.3 应急强制开的唯一权威：`key_router` 的 `*_eff`（给 RTL 的接线禁令）

矩阵里「锁 1」的两格（Key4 音频、Key5 字幕）由 `key_router.v` 的两个输出实现：

```verilog
// rtl/control/key_router.v:307-308
assign audio_en_eff  = emerg ? 1'b1 : audio_en;    // Key4，应急强制出声
assign ticker_en_eff = emerg ? 1'b1 : ticker_en;   // Key5，应急强制显示
```

| 信号 | 权威源 | 分发目标 | 禁令 |
|---|---|---|---|
| `audio_en_eff` | `key_router.v:307` | `audio_src_mux.audio_en`（及 PWM 层的 `~audio_playing` 判据） | **`audio_src_mux.eff_audio_en`（`audio_src_mux.v:93`）与它逻辑恒等，但它是重复实现 —— 该输出不接、不入顶层逻辑。** 两处各写一遍 = 双源真相，将来改一处忘一处就会出现「按 Key4 静音了但应急还是不出声」或反之 |
| `ticker_en_eff` | `key_router.v:308` | **`video_overlay.caption_en`** | **顶层必须接这一根，不能硬接 `1'b1`。** 现状 `dmz_eg4s20_hdmi_top.v:435` 是 `.caption_en(1'b1)`（v1 遗留，当时 16 个键已占满、没有独立字幕开关），v2 已有 Key5，硬接 `1'b1` 会让 Key5 屏幕无反应 —— 这是 t7 必须改的接线项之一 |

> `caption_en` 在 `osd_caption.v` 内部**同时门控** `caption_pixel`（`:219 if (caption_en)` 包住整个槽位选择）与 `caption_band`（`:258 wire band_on = caption_en && ...`），故两者不可能不同步 —— 顶层只需接 `caption_en` **一根线**；`caption_band` 是 `video_overlay.v:266-267` 的内部 wire `px_cap_band`，顶层既看不到也不需要接。

### 5.4 科普视频字幕的来源（Key5 在科普模式下的语义）

矩阵里 Key5 在科普模式记为「✓」，控制的是**科普视频字幕**。它与日常模式的校园介绍滚动字幕**共用同一根 `ticker_en` / 同一个滚动带区域**（`TICKER_Y0=448..TICKER_Y1=463`），区别只在数据源：

| 模式 | 滚动带数据源 | 说明 |
|---|---|---|
| 日常 | `osd_strings.v` 的 `seg_line`（line 8..13 六段校园介绍，`index_val` 选段） | 循环滚动，一轮 68.8 s |
| **科普** | **`narr_subline.v` 的 `narr_code[8:0]`（18 段，`rle_decoder.frame_idx` 驱动）** | 见 `ARCH.md` §9.4。**Key5 关掉时视频字幕与静态三条 ASCII 带一起消失，科普模式的画面与音频不受影响** |
| 应急 | `osd_strings.v` 的 line 14/15（应急文案 104 字拆两行，`emg_half` 整轮翻转） | **优先级最高**，`ticker_en` 被 `ticker_en_eff` 强制为 1 |

> **科普字幕的文案改不了 SD 卡**：18 段字幕在 `narr_subline.v` 的 BRAM 里（编译期由 `narration.srt` 生成），改文案必须重新生成并重新综合。SD 卡上的 `TICKER.TXT` 是协议占位，**运行时不读取**（详见 `t11` 交付文档）。

---

## 6. 物理行列与逻辑键号的解耦处置

`docs/pending_confirmations.md` 第 77/115 行记录：4×4 矩阵行序在两份早期资料（「走近 FPGA」教程 vs 底板例程）中**相反**，当前 `rtl/input/key_matrix_4x4.v` 采用 `key_row = E10,C10,F9,D9` / `key_col = E11,D11,C11,F10`。

**处置原则**：
1. 本文件定义的 Key0~Key15 是**逻辑键号**，与物理行列无关。
2. 物理行列顺序的正确性由**上板逐键实测**确认（列入 `PLAN.md` 阶段 M5 上板清单第 3 项）。
3. 若实测发现行序颠倒，**唯一修改点是 `rtl/input/key_matrix_4x4.v` 的扫描顺序或顶层 `key_row`/`key_col` 引脚分配**，本文件与 `key_router.v` **一行不改**。
4. 这条解耦是本设计对「行序资料冲突」这一历史遗留风险的结构性防御 —— 无论哪份资料正确，键位表都稳定。

---

## 7. `key_router.v` 端口契约（供 ARCH.md §5 引用）

```verilog
module key_router #(
    parameter CLK_FREQ_HZ = 25_000_000,
    parameter OSD_HOLD_MS = 2500
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        key_event,
    input  wire [3:0]  key_code,
    input  wire [1:0]  mode,            // 来自 mode_ctrl：0=日常 1=科普 2=应急

    output reg  [3:0]  bright_lvl,      // 0~9，复位 0（100% 最亮，与 video_overlay 现行 bright_sel=0 语义一致）
    output reg  [3:0]  vol_lvl,         // 0~9，复位 6（约 50%）
    output reg  [2:0]  res_sel,         // 0~4，复位 4（640×480 原生）
    output reg  [2:0]  ratio_sel,       // 0~4，复位 4（满屏 1）
    output reg         audio_en,        // 复位 1
    output reg         ticker_en,       // 复位 1
    output reg         viz_en,          // 复位 1
    output reg         osd_pop_req,     // 单拍：任一参数键按下或参数变化
    output reg  [4:0]  osd_item,        // 当前弹出项索引（0~6）

    // P2 备用键输出（未实现时恒 0）
    output reg         rescan_req,      // Key11 单拍
    output reg  [2:0]  pattern_sel,     // Key12
    output reg         invert_en,       // Key13
    output reg         grid_en,         // Key14
    output reg         beep_muted       // Key15
);
```

**接口时序约定**：
- `key_event` 是**单拍脉冲**（`key_matrix_4x4.v` 保证，DEBOUNCE_MS=20），本模块不产生 `key_event`。
- `bright_lvl` / `vol_lvl` / `res_sel` / `ratio_sel` 在 `key_event` 后**同一拍内**更新（`clk` 上升沿），下游模块在下一拍看到新值。无跨时钟域。
- `osd_pop_req` 是**单拍脉冲**，与参数更新同拍或滞后 1 拍均可（`osd_autopop.v` 内部有 `HOLD_MS` 计数器，不要求严格对齐）。
- 全部输出在 `rst_n` 低时复位到 §7 注释中的复位值，**异步复位**（与工程其余模块一致）。
- `mode` 输入仅在 Key4/Key5 的强制开逻辑与 Key7 的音量钳位中参与判定；`mode` 变化到输出生效延迟 1 拍。

---

## 8. 键位表可直接翻成 Verilog 的判定表

供 `key_router.v` 的 `case (key_code)` 直接使用：

```verilog
localparam K_PREV     = 4'd0;   // Key0  上一张（media_player 消费，不在此模块）
localparam K_NEXT     = 4'd1;   // Key1  下一张（media_player 消费，不在此模块）
localparam K_MODE     = 4'd2;   // Key2  模式循环（mode_ctrl 消费，不在此模块）
localparam K_EMERG    = 4'd3;   // Key3  应急直达/确认（mode_ctrl 消费，不在此模块）
localparam K_AUDIO    = 4'd4;   // Key4  音频开关
localparam K_TICKER   = 4'd5;   // Key5  底部字幕开关
localparam K_BRIGHT   = 4'd6;   // Key6  亮度 10 档
localparam K_VOL      = 4'd7;   // Key7  音量 10 档
localparam K_RES      = 4'd8;   // Key8  分辨率 5 档
localparam K_RATIO    = 4'd9;   // Key9  屏占比 5 档
localparam K_VIZ      = 4'd10;  // Key10 音频可视化开关
localparam K_RESCAN   = 4'd11;  // Key11 图库重扫（P2）
localparam K_PATTERN  = 4'd12;  // Key12 测试图案（P2）
localparam K_INVERT   = 4'd13;  // Key13 反色（P2）
localparam K_GRID     = 4'd14;  // Key14 九宫格（P2）
localparam K_BEEP     = 4'd15;  // Key15 蜂鸣器静音（P2）
```

**消费模块归属（铁律 1 的执行清单）**：

| 键 | 唯一消费模块 | 其他模块是否可以读该键？ |
|---|---|---|
| Key0 / Key1 | `media_player.v` | 否 |
| Key2 / Key3 | `mode_ctrl.v` | 否 |
| Key4~Key15 | `key_router.v` | 否 |

**跨模块禁止**：`mode_ctrl.v` 不得直接读 `key_code == K_BRIGHT`，`media_player.v` 不得读 `key_code == K_MODE`。每个模块只解码属于自己的一组键号，其余 `key_code` 值走 `default: ;`。

---

## 9. 键位档位值表（Key6/Key7/Key8/Key9 的取值）

### 9.1 Key6 亮度 10 档（`bright_lvl[3:0]`，**0 = 最亮（100%），9 = 最暗（9.4%）**）

> **方向约定（与既有硬件一致，不得反向）**：现行 `rtl/video/video_overlay.v:108` 的 `bright_sel == 3'd0 ? r_in` 表示**档 0 就是最亮（旁路）**。v2 保持这一方向：**档号递增 = 越来越暗**，`case` 的 `default`/档 0 落到 32/32 旁路。这样 Key6 的按键方向与老工程相同，迁移时语义不翻转。

| `bright_lvl` | 增益（k/32） | 百分比 | 移位加表达式（x 为 8bit 通道值） |
|---|---|---|---|
| **0（复位值）** | **32/32** | **100%** | `x`（旁路） |
| 1 | 29/32 | 90.6% | `x - (x>>4) - (x>>5)` |
| 2 | 26/32 | 81.3% | `x - (x>>3) - (x>>4)` |
| 3 | 23/32 | 71.9% | `x - (x>>2) - (x>>5)` |
| 4 | 20/32 | 62.5% | `x - (x>>2) - (x>>3)` |
| 5 | 16/32 | 50.0% | `(x>>1)` |
| 6 | 13/32 | 40.6% | `(x>>1) - (x>>4) - (x>>5)` |
| 7 | 10/32 | 31.3% | `(x>>2) + (x>>4)` |
| 8 | 6/32 | 18.8% | `(x>>3) + (x>>4)` |
| 9 | 3/32 | 9.4% | `(x>>4) + (x>>5)` |

全部 10 档仅用**移位 + 1~2 个加减**实现，**零 DSP、零乘法器**。

### 9.2 Key7 音量 10 档（`vol_lvl[3:0]`，**0 = 最轻（9.4%），9 = 最响（100%）**）

> **方向与亮度表相反，必须注意**：亮度是「档 0 最亮」（迁就既有硬件 `bright_sel=0` 语义），音量是「档 0 最轻、档 9 最响」（迁就用户对音量的直觉：往大调是加号）。两张表的**增益数值集合完全相同**（3/32 … 32/32），只是**排列方向相反**。RTL 实现时 `vol_apply.v` 与 `brightness_apply.v` 不能直接共用同一个 `case` 函数，需要各自的 case 顺序。

| `vol_lvl` | 增益（k/32） | 百分比 | 应急下 |
|---|---|---|---|
| 0 | 3/32 | 9.4% | → 钳位到 3 |
| 1 | 6/32 | 18.8% | → 钳位到 3 |
| 2 | 10/32 | 31.3% | → 钳位到 3 |
| 3 | 13/32 | 40.6% | ✅ 应急下限 |
| 4 | 16/32 | 50.0% | ✅ |
| 5 | 20/32 | 62.5% | ✅ |
| 6（复位值） | 23/32 | 71.9% | ✅ |
| 7 | 26/32 | 81.3% | ✅ |
| 8 | 29/32 | 90.6% | ✅ |
| 9 | 32/32 | 100% | ✅ |

施加对象为 24bit signed 音频样本 `sample_in`：

```verilog
sample_out = (sample_in * k) >>> 5;   // 算术右移，保持符号
```

同样用移位加实现（24bit 加法器 × 2），零 DSP。

### 9.3 Key8 内部渲染分辨率 5 档（`res_sel[2:0]`）

| `res_sel` | 逻辑分辨率 | 放大比 | `src_w` | `src_h` |
|---|---|---|---|---|
| 0 | 320×240 | 2.00× | 320 | 240 |
| 1 | 400×300 | 1.60× | 400 | 300 |
| 2 | 512×384 | 1.25× | 512 | 384 |
| 3 | 576×432 | 1.11× | 576 | 432 |
| 4（默认） | 640×480 | 1.00×（旁路） | 640 | 480 |

**注**：五档全部为 4:3，窗口尺寸与偏移**逐档以 `docs/plan_v2/KEY9_RULING.md` §1 为准**（1/2、5/8、3/4、7/8、1，对应 320×240 / 400×300 / 480×360 / 560×420 / 640×480），本文件不重复表述。**⚠️ 渲染结果是「横向等比压缩 + 纵向 1:1 裁剪」，不是等比缩小** —— 纵向跳行已由 t22 实测否决、t28 裁定不做（物理上限：需 267 块 BRAM9K，全片仅 64 块），理由见 `KEY9_RULING.md` §2。**HDMI 输出时序恒为 640×480@59.52Hz，不随时钟切换** —— 详见 `PLAN.md` §4 与 `ARCH.md` §3。

### 9.4 Key9 屏占比 5 档（`ratio_sel[2:0]`）

| `ratio_sel` | 占比 | `win_w` | `win_h` | `win_off_x` | `win_off_y` |
|---|---|---|---|---|---|
| 0 | 1/2 | 320 | 240 | 160 | 120 |
| 1 | 5/8 | 400 | 300 | 120 | 90 |
| 2 | 3/4 | 480 | 360 | 80 | 60 |
| 3 | 7/8 | 560 | 420 | 40 | 30 |
| 4（默认） | 1（满屏） | 640 | 480 | 0 | 0 |

全部为整数，可直接作为 `image_window_mask.v` 的 `win_w`/`win_h`/`win_off_x`/`win_off_y` 输入。

---

## 10. 无悬空项声明

| 项 | 结论 |
|---|---|
| 16 个键是否全部有归属 | 是。Key0~Key10 为 P0 主功能，Key11~Key15 为 P2 备用并已登记保留用途 |
| 是否存在未定义键号 | 否。`key_code` 0~15 全部覆盖 |
| 物理行序冲突是否阻塞 | 否。见 §6，逻辑键号与物理行列解耦 |
| 是否与赛规冲突 | 否。赛规 P4「4 组输入按键」是板卡资源描述，无按键数量上限条款；P5 明确把「键盘」列为 40Pin 外扩官方用途（依据见 `SPEC_CONSTRAINTS.md` §2） |
| Key5 与 Key10 是否已解耦 | 是。见 §5.2 的明确禁令 |
| 应急模式下的按键行为是否全部定义 | 是。见 §5 作用域矩阵，11 个键位全部有明确取值 |
| 参数 OSD 是否仍需专用键 | 否。改为自动弹出，见 §2.4 |
