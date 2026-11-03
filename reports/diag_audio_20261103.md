# 音频链路诊断报告（日常/科普无声 + 全程无音频可视化）

- 日期：2026-11-03
- 任务：t2「诊断：日常/科普无声 + 全程无音频可视化」
- 位流基线：`project/hdmi_td_Runs/phy_1/hdmi_td.bit`（648,264 B，2026-11-03 00:31，**从未上板**）
- 方法：静态源码走查 + ModelSim ASE 10.1d 行为仿真（不改任何 `.v`，不上板）
- 行号口径：`read` 工具行号（文件含 CR-only 行尾，PowerShell `(Get-Content).Count` 偏小，勿混用）

> ### 行号快照声明（重要，先读）
>
> 本报告所有行号取自 **2026-11-03 21:15 的工作树快照**，当时 `rtl/top/dmz_eg4s20_hdmi_top.v` = **1391 行**（同日早先的版本依次是 1256 行、1287 行；v2 修复期间被其他成员持续改动，**行号已经漂移过两次**）。下表「本快照行号」列已按 1391 行版重新核对。
>
> 若你读到时行号对不上，**不要怀疑结论，请用下表的关键字 grep 重新定位**——所有结论都锚在代码语义上，不锚在行号上：
>
> | 想找的东西 | grep 关键字 | 本快照行号（1391 行版） |
> |---|---|---|
> | HDMI 衰减位数 | `HDMI_AUDIO_ATTEN_SHIFT =` | `:1065` |
> | 样本级 mux（`wav_playing` 选源） | `src_sample_valid = wav_playing` | `:1039` |
> | `audio_src_mux` 例化（无 override） | `audio_src_mux u_audio_src` | `:994` |
> | `wav_stream_player` 例化 | `wav_stream_player #(` | `:1010` |
> | `err_code` / `fifo_level` 空连接 | `\.err_code\(\)` / `\.fifo_level\(\)` | `:1017` / `:1018` |
> | `tone_gen` 例化 | `audio_tone_gen #(` | `:1029` |
> | `vol_apply` 例化 | `vol_apply #\(\.VOL_MAX` | `:1052` |
> | `video_overlay` 例化（波形/样本入口） | `video_overlay u_overlay` | `:1127` |
> | `.wave_en` / `.audio_sample` 连接 | `\.wave_en\(wave_en\)` / `\.audio_sample\(audio_left\)` | `:1132` / `:1136` |
> | `audio_arc` 例化 | `audio_arc #\(\.ACR_N` | `:1227` |
> | HDMI 核（吃衰减后样本） | `\.I_audio_left_data\(hdmi_audio_left\)` | `:1257` |
> | 蜂鸣器 | `buzzer_tone #\(` | `:1336` |
> | `tone_sel` 三档选择 | `\.tone_sel\(beep_muted` | `:1349` |
> | `pcm_to_pwm`（吃未衰减样本） | `pcm_to_pwm u_pwm_audio` | `:1357` |
> | LED 位定义（LED7 = `err_active`） | `assign led =` | `:1373` |
> | DIG3/DIG2 双口径 | `error_value = err_active` | `:1382`（`state_value` 在 `:1383`） |
> | ST_FAIL 优先级 | `playback_next = ST_FAIL` | `:960`（`= ST_IDLE` 兜底在 `:958`） |
> | `sd_or_gallery_fail` | `sd_or_gallery_fail =` | `:859` |
> | `wave_en` 来源 | `wire\s+wave_en\s+=` | `:167` |
> | `level_en` 永久 0（D-03） | `wire\s+level_en\s+=` | `:166` |
> | `sd_ready_audio` | `sd_ready_audio =` | `:450` |
> | `key_router` 例化（`.P2_EN`） | `\) u_keyrouter \(` / `\.P2_EN` | `:142` / `:141` |
>
> 其它被引用的 RTL 文件分两类：
>
> - **本快照中未被改动**（`git status` 干净，行号可直接使用）：`audio_src_mux.v`、`wav_stream_player.v`、`audio_tone_gen.v`、`vol_apply.v`、`audio_waveform.v`、`fat32_reader.v`、`gallery_probe.v`、`key_router.v`、`sd_probe.v`、`sd_spi_ctrl.v`、`audio_arc.v`、`brightness_apply.v`、`buzzer_tone.v`、`pcm_to_pwm.v`。
> - **本快照中已被其他成员改动**（行号已按 21:15 快照重新核对，但仍可能继续漂移）：`video_overlay.v`（348 行）、`osd_panel.v`、`image_player.v`、`err_prompt.v`。引用处均已按改后行号校准；若再漂移，请 grep 语义关键字（如 `failed <=`、`err_active = 1'b1`、`px_info =`、`px_wave ?`）。

---

## 0. 结论摘要（先看这一段）

**「没声音」不是一个原因，是四层原因叠在一起；「没有可视化」是一个独立的第五层原因。**

| # | 根因 | 层 | 影响 |
|---|---|---|---|
| R1 | `audio_src_mux` 的 8.3 短名常量字节序写反 → FAT32 目录项首字节比对恒失败 → `err_code=4` → WAV 从未播放过 | RTL 逻辑 | 三个 WAV（BGM/NARR/ALARM）全部定位失败 |
| R2 | 失败后 `src_started` 粘滞 + `W_FAIL` 不自恢复 → 永久沉默，切模式换源才重试一次 | RTL 逻辑 | 失败即锁死 |
| R3 | `wav_stream_player.v:438` 16 bit → 24 bit 只做符号扩展、**未左移 8 位** → WAV 比 `tone_gen` 低 48.2 dB | RTL 逻辑 | 即使 R1 修好，WAV 仍几乎听不见 |
| R4 | `HDMI_AUDIO_ATTEN_SHIFT=6`（−36.12 dB）× `vol_apply` 档 6（−2.87 dB）= **−38.99 dB**，叠加音源本身电平后 HDMI 侧落到 −43…−54 dBFS | 参数调校 | HDMI 内嵌音频不可能听见 |
| R5 | `audio_waveform` 幅度换算两级右移（`hist<=audio_sample[23:8]` + `Y_SHIFT=10`）= **256× 额外衰减** → 真实 16 bit 样本波形塌成 **1 像素高水平线** | RTL 逻辑 | 波形层永久不可见，**与音频通路是否修好无关** |
| R6 | `playback_state` 被 `sd_fail / gallery_fail / image_failed` 钉在 `ST_FAIL` → `tone_gen` 兜底音也被静音（`silent=1`）→ 连三角波都没有 | RTL 逻辑（依赖现场） | 卡有任何问题 = 全静音死锁 |
| R7 | **现场素材**：`RES640/` 零 WAV；只有 `BURN640/`（需把**内容**平铺到卡根）才有 WAV | 现场素材 | 卡没烧对 = R1 修好也无 WAV 可放 |

**关键澄清（与 captain 核实一致）：用户在应急模式听到的声音来自蜂鸣器（H11），不是音频通路。**
顶层 `rtl/top/dmz_eg4s20_hdmi_top.v:1336-1350` 的 `buzzer_tone` 是本地振荡器合成，不经过 SD/WAV/`vol_apply`/HDMI 音频/`pcm_to_pwm` 任何一环。
⇒ 现象①「日常/科普没声音」与现象④「应急有声但没可视化」**是同一根因**（音频通路在所有模式下都是死的），不是两个独立问题。

---

## 1. 分层判定表（现象 → 根因层 → 证据 → 是否只能上板确认）

| 现象 | 根因层 | 证据（文件:行号） | 只能上板确认？ |
|---|---|---|---|
| 日常/科普 HDMI 无声 | 参数调校 R4 + RTL R1/R2/R3 | 顶层 `:1065-1067`；`audio_src_mux.v:34-36`；`wav_stream_player.v:438` | 否（可静态判定 + 仿真复现） |
| 日常/科普 3.5mm 无声 | RTL R6（ST_FAIL 静音死锁）/ H3（`wav_playing` 卡死）或硬件 | `dmz_eg4s20_hdmi_top.v:859/:960`；`audio_tone_gen.v:142`；`wav_stream_player.v:591-595/:445-455` | **是**（需看 LED7 + DIG3 字母判断，见 §6.6 判定树 / §7） |
| 应急有声 | **蜂鸣器，非音频通路** | 顶层 `:1336-1350`（`tone_sel = m_emerg ? 3'd2`）；`buzzer_tone.v:288-297` | 否 |
| 应急无可视化 | R5（波形层独立缺陷） | `audio_waveform.v:41/:75` | 否（仿真已复现：6..10 行） |
| 全程无可视化 | R5 + `wave_en` 正常 | `audio_waveform.v:41/:75`；`key_router.v:161`；顶层 `:167` | 否 |
| 卡上无 WAV | 现场素材 R7 | `assets/v2/sdcard/RES640/`（7 文件，零 WAV）；`BURN640/MANIFEST.TXT` | **是**（需用户自查卡内容） |

**「卡对了能不能出声」**：修完 R1/R3/R4 后，PWM 支路（3.5mm）能正常出声；HDMI 支路修 R4 后也能。R5 必须单独修，波形不会自己出现。
**「卡没对导致无声」**：R7 使 WAV 不可能播放（但 `tone_gen` 兜底音仍在，除非同时命中 R6）；R6 使连兜底音都消失。

**「完全没声音」的三种互斥解释**（H1 只 HDMI 衰减 / H2 FSM 静音 / H3 `wav_playing` 卡死）已在 §6.6 合并成一棵判定树，每种都给出源码依据与上板分流判据。**注意 `ST_FAIL` 在数码管上显示为字母而非数字 6**（顶层 `:1382-1383`），详见 §6.6 与 §7 第 1 步。

---

## 2. 必答问题逐条回答

### 问题 1：日常模式下 WAV 到底有没有在播？

**答：没有。从来没播过。**

#### 1.1 SD 仲裁不会饿死 WAV（这一层是干净的）

`rtl/top/dmz_eg4s20_hdmi_top.v`：

```
:412  wire sd_owner_probe   = !sd_ok;
:413  wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;
:417  wire sd_owner_playseg = sd_ok && (gallery_done || gallery_fail);
:429  wire sd_owner_wav     = sd_owner_playseg && wav_want_blk;
:430  wire sd_owner_rle     = sd_owner_playseg && !wav_want_blk && rle_want_blk;
:431  wire sd_owner_img     = sd_owner_playseg && !wav_want_blk && !rle_want_blk;
:436  wire sd_grant_wav     = sd_owner_wav;
```

播放段（`playseg`）内部优先级：**WAV > RLE > BMP**。`gallery` 只在图库扫描期（`!gallery_done && !gallery_fail`）占线，扫描结束后 WAV 最高优先。
⇒ **WAV 不会被 gallery / rle / image_player 饿死。** 这一层不是问题。

#### 1.2 真正的原因：8.3 短名常量字节序写反（决定性）

`rtl/audio/audio_src_mux.v:34-36`：

```verilog
parameter [87:0] NAME_BGM   = {"BGM",  40'h20_20_20_20_20, "WAV"},
parameter [87:0] NAME_NARR  = {"NARR", 32'h20_20_20_20,    "WAV"},
parameter [87:0] NAME_ALARM = {"ALARM",24'h20_20_20,       "WAV"};
```

Verilog 拼接的**最左操作数落在最高位**，所以 `target_name[7:0]` 是**最右**那个字节：

```
target_name[7:0]   = "WAV" 的 'V' = 0x56     ← 被当作「名字第 0 字节」
target_name[15:8]  = 'A'
target_name[23:16] = 'W'
target_name[31:24..63:32] = 空格
target_name[71:64] = 'M'
target_name[79:72] = 'G'
target_name[87:80] = 'B'
```

即常量实际表达的是 **`"VAW     MGB"`**，不是 `"BGM     WAV"`。

而 `rtl/storage/fat32_reader.v:106-116` 的契约注释写得很清楚：

```
target_name[7:0] = 第 0 字节（名字首字符）
例: "IMG001  BMP" / "BGM     WAV" / "SCI     RLE" / "NARR    SRT"
```

比对逻辑在 `rtl/storage/fat32_reader.v:683`：

```verilog
5'd0:    exp_byte = target_name[7:0];      // offset 0 期望 'V'=0x56
```

而磁盘上 `BGM.WAV` 的目录项 offset 0 是 `'B'(0x42)` ⇒ `rtl/storage/fat32_reader.v:582-583` 的

```verilog
nm_bad <= (data_byte != exp_byte) && (data_byte != (exp_byte | 8'h20));
```

恒为真 ⇒ `name_hit` 永不成立 ⇒ 目录扫完（`dir_end`）⇒ `err_code <= 4'd4` ⇒ `st <= S_FAIL`（`fat32_reader.v:396-398`）
⇒ `wav_stream_player.v:733` `err_code <= E_NOTFOUND` ⇒ `st <= W_FAIL` ⇒ `busy<=0; playing<=0`。

**三个名字（BGM / NARR / ALARM）全部反序，所以三个 WAV 全部找不到。**

#### 1.3 仿真实证（已跑通）

新增 tb：`_diag_audio/tb_name_order.v`（仓库外诊断目录，不进位流）
同一 FAT32 镜像（LBA0=MBR / LBA4=VBR / LBA5,6=FAT / LBA7=DIR0，根目录第 0 项为 LFN 干扰项、第 1 项为 `"BGM     WAV"`，首簇 4、长度 1044），两个 `fat32_reader` 实例分别吃 **`audio_src_mux` 默认 parameter** 与 **override 正确常量**：

```
[name] default bytes(0..10) = 'VAW     MGB'   [7:0]=0x56
[s1] found=0 fail=1 err_code=4 busy=0 (cycles=1553)
[s1] file_size=0 first_cluster=0

[name] override bytes(0..10) = 'BGM     WAV'   [7:0]=0x42
[s2] found=1 fail=0 err_code=0 busy=0 (cycles=1552)
[s2] file_size=1044 first_cluster=4

SUMMARY: errors=0
ALL CHECKS PASSED: name_order
```

复现命令：

```powershell
cd D:\FPGA_Compelate\_diag_audio
vlib work_name
vlog -work work_name ..\SmartCampusMedia\rtl\audio\audio_src_mux.v `
     ..\SmartCampusMedia\rtl\storage\fat32_reader.v tb_name_order.v
vsim -c -quiet work_name.tb_name_order -do "run -all; quit -f"
```

（注意：ModelSim ASE 10.1d 的 `vsim` **不支持 `-work` 选项**，会报 `(vish-3296) Unknown option '-work'`。）

#### 1.4 为什么单元测试全绿却上板失败（重要）

`sim/testbench/tb_audio_src_mux.v:44-50` 里 tb 自己定义了**正确的倒序**常量，并在 `:67-69` 通过 **parameter override** 传进 DUT：

```verilog
// tb_audio_src_mux.v:33   ★ 字节序：target_name[7:0] 是第 0 字节（主名首字符）
// tb_audio_src_mux.v:46   "BGM" 倒序
localparam [87:0] NAME_BGM = {8'h56, 8'h41, 8'h57, 5*8'h20, 8'h4D, 8'h47, 8'h42};
```

`sim/testbench/tb_wav_stream_player.v:655` 同理。**所有单元 tb 都用 override 绕过了 RTL 里写反的默认值，因此全绿**；而顶层 `dmz_eg4s20_hdmi_top.v:994-998` 例化 `audio_src_mux` 时**没有 override**，实际综合进位流的是反序常量。

⇒ 这是「单元 tb 全绿、上板无声」的完整解释。**测试台与 RTL 的默认值不一致，是这次漏检的根因。**

#### 1.5 第二层：失败后永久不重试

`rtl/audio/wav_stream_player.v:889-893`：

```verilog
W_FAIL: begin
    // 停在 W_FAIL 等上层重新 start。不自动重试。
    busy   <= 1'b0;
    playing <= 1'b0;
```

`rtl/audio/audio_src_mux.v:113-121`：

```verilog
if (src_sel_d != sel_c)      src_started <= 1'b0;   // 只有源变化才清零
else if (sd_ready && !src_started) begin
    src_start   <= 1'b1;
    src_started <= 1'b1;
end
```

`src_started` 是粘滞标志，**只有 `sel_c` 变化才清零**。⇒ WAV 一旦失败，即使 SD 卡后来就绪、文件后来可读，**也永远不会再发 `start`**。
唯一能重试的动作是**切换模式**（`sel_c` 从 BGM 变 ALARM 或变 NARR）。这精确解释了「切到应急后换源重新 start」的行为差异。

---

### 问题 2：−36.12 dB 是不是听不见的直接原因？

**答：对 HDMI 支路是「必要但不充分」的一层；对 3.5mm 支路完全不适用。**

#### 2.1 量化（全部可复算）

| 量 | 值 | 出处 |
|---|---|---|
| 24 bit 有符号满幅 | ±8,388,608（2²³） | — |
| `audio_tone_gen` 三角波幅度 | ±2,097,152 = 0.25 FS = **−12.04 dBFS** | `audio_tone_gen.v:135-138`（`tri_centered >>> 2`） |
| `vol_apply` 复位档 6 增益 | 23/32 = 0.71875 = **−2.87 dB** | `vol_apply.v:103-128`（`vol_gain` 表，档 6 在 `:122`）；`key_router.v:156`（复位 6） |
| `HDMI_AUDIO_ATTEN_SHIFT=6` | 1/64 = **−36.12 dB** | 顶层 `:1065` |
| **HDMI 支路总衰减（音源以外）** | 0.71875/64 = 0.01123 = **−38.99 dB** | 上两行相乘 |
| PWM/3.5mm 支路总衰减 | 0.71875 = **−2.87 dB**（**无 >>>6**） | 顶层 `:1357-1359` 吃未衰减 `audio_left` |

#### 2.2 叠加音源本身电平后，HDMI 侧落到什么程度

素材实测（解析 `assets/v2/sdcard/BURN640/*.WAV` 全部 data chunk 样本，非抽样）：

| 文件 | peak | RMS |
|---|---|---|
| `BGM.WAV`（1,920,000 样本） | 19953 = −4.31 dBFS(16bit) | 5631 = −15.30 dBFS(16bit) |
| `NARR.WAV`（6,053,100 样本） | 29162 = −1.01 dBFS(16bit) | 2283 = −23.14 dBFS(16bit) |
| `ALARM.WAV`（288,000 样本） | 23260 = −2.98 dBFS(16bit) | 15207 = −6.67 dBFS(16bit) |
| `audio_tone_gen` 三角波（24 bit） | −12.04 dBFS(24bit) | **−16.81 dBFS**（三角波 RMS = 幅度/√3 = 0.25/1.732） |

**关键：16 bit 样本若只做符号扩展（R3 未修）而不左移 8 位，它在 24 bit 域里的数值等于 16 bit 原值 ⇒ 比 MSB 对齐再低 48.16 dB（2^8）。** 所以下表分两列：现状（R3 未修）与「假设 R3 已修」。

⇒ **HDMI 内嵌音频实际到达显示器的电平（dBFS，以 24 bit 满幅 2²³ 为 0 dB）**：

| 音源 | 现状 RMS（R3 未修） | 现状峰值 | 修 R3 后 RMS | 修 R3 后峰值 |
|---|---|---|---|---|
| BGM（日常） | **−102.45** | −91.46 | −54.29 | −43.30 |
| NARR（科普） | **−110.29** | −88.16 | −62.13 | −40.00 |
| ALARM（应急） | **−93.82** | −90.13 | −45.66 | −42.09 |
| tone 三角波（不受 R3 影响） | **−55.80** | −51.03 | −55.80 | −51.03 |

算式（以 BGM 为例）：`−15.30 − 48.16(R3) − 2.87(档6) − 36.12(>>>6) = −102.45`。
R3 修好后：`−15.30 − 2.87 − 36.12 = −54.29`。
tone 不经 R3：`−16.81 − 2.87 − 36.12 = −55.80`。

⇒ **PWM/3.5mm 实际电平**（无 `>>>6`，也**不经 R3 之外的额外处理**——注意 `pcm_to_pwm` 吃的是 `audio_left`，仍受 R3 影响）：

| 音源 | 现状 RMS（R3 未修） | 修 R3 后 RMS |
|---|---|---|
| BGM | −66.33 | −18.17 |
| NARR | −74.17 | −26.01 |
| ALARM | −57.70 | −9.54 |
| tone | −19.68 | −19.68 |

算式同 HDMI 表，**只去掉 `−36.12(>>>6)` 这一项**：BGM 现状 = `−15.30 − 48.16(R3) − 2.87(档6)` = −66.33；修 R3 后 = `−15.30 − 2.87` = −18.17。
⇒ **关键分流依据**：现状下 3.5mm 支路的 `tone_gen` 兜底音是 **−19.68 dBFS**（不经 R3），属于**明确可闻**的正常音量；WAV 则是 −57.7…−74.2 dBFS（很小声、听不清内容）。
所以：**若插上 3.5mm 喇叭后连"提示音/三角波"都听不到，问题就不在幅度，而在 R6（ST_FAIL 静音）或 H3（`wav_playing` 卡死）或功放硬件** —— 这是 §7 第 2 步的核心分流依据。

#### 2.3 「典型 HDMI 显示器音量下能否听见」的判据（不凭感觉）

判据链（**用「修 R3 后」的乐观值 −54.29 dBFS，即给对手最有利的假设**）：
1. 显示器内建喇叭（典型 2×2 W，1 m 处）在**音量 100%**、输入 0 dBFS 正弦时约 **80–85 dB SPL**。取乐观值 85 dB SPL。
2. 输入 −54.29 dBFS ⇒ 声压 ≈ 85 − 54.29 = **30.7 dB SPL**。
3. 办公室/教室环境底噪典型 **45–55 dB SPL**（空调 + 电脑风扇 + 人声）。
4. ⇒ 节目声压比环境噪声**低 15–25 dB**，被完全掩蔽。人耳要分辨内容，节目需比底噪高约 6–10 dB。

即使把 0 dBFS 假设提高到 95 dB SPL（大功率电视），−54.29 dBFS ⇒ 40.7 dB SPL，**仍低于底噪**。
而现状（R3 未修，−102.45 dBFS）在任何设备上都是**数字静音级**——连"极小声音"都算不上。

⇒ **R3 与 R4 是串联的两层，任何一层单独存在都足以让 HDMI 无声。**
- R3 单独：16 bit 样本当 24 bit 用 ⇒ 相对 MSB 对齐损失 **48.16 dB**（WAV 峰值 19953 在 24 bit 域只占 0.24% FS，而 tone 占 25% FS，两者差约 40 dB）。
- R4 单独：tone 也被压到 −55.80 dBFS RMS，不可闻。
- 两者叠加：WAV 落到 −102 dBFS。

同时：**PWM 支路（3.5mm，引脚 F3）没有 `>>>6` 这层衰减**，修 R3 后 BGM 到 −18.17 dBFS、tone 到 −19.68 dBFS，是**正常可闻音量**。即使 R3 未修，tone 兜底音也已经能听到。
⇒ 若用户只从显示器听、没插 3.5mm 喇叭，则「没声音」是**测量方式 + 参数过保守**的组合，不是通路死。这一点必须让用户在上板时分开测。

#### 2.4 该不该改、改成多少

**该改。** 理由：`vol_apply` 已经提供 10 档用户音量权威（档 9 = 100% 直通），再叠一层编译期硬编码衰减，等于把音量权威拆成两处、且其中一处不可调。

| 方案 | `HDMI_AUDIO_ATTEN_SHIFT` | 总衰减（含档 6） | tone 峰值 | 评价 |
|---|---|---|---|---|
| 现状 | 6 | −38.99 dB | −51.03 dBFS | 不可闻 |
| 折中 | **2**（−12.04 dB） | −14.91 dB | −27.04 dBFS | 有削顶余量，推荐 |
| 直通 | **0** | −2.87 dB | −15.06 dBFS | 音量权威唯一，但满档可能削顶 |

**推荐 `2`**：给 `tone_gen` 的 ±0.25 FS 和 WAV 的 ±1.0 FS 都留 12 dB 余量，避免官方核入口削顶（`vol_apply.v:131-136` 已在 ±2²³ 饱和，但核内部可能有额外处理）。

**必须先确认官方核的满幅容忍度再定 0**：`docs/hdmi_audio_2026-10-26.md:3/:113-122/:249` 只记录了「用户要求音量调到很小」这一动机，**没有给出核的满幅规范**；`ip/local/hdmi/enc/hdmi_1_4b_transmitter_core_wrapper.enc.v` 是 Anlogic 加密核，内部不可读。若无法查证 APUG092，就按 `2` 走，并在上板时用满档（`vol_lvl=9`）试听确认无削顶。

#### 2.5 改 `HDMI_AUDIO_ATTEN_SHIFT` 会不会影响 ACR？

**不会。** `rtl/video/hdmi/audio_arc.v:26-31` 的端口只有 `clk / rst_n / audio_valid / acr_valid / acr_cts / acr_n` —— **它只吃 `audio_valid`，不吃样本值**。衰减只作用于 `:1066-1067` 的 `hdmi_audio_left/right`，与 `audio_valid` 无关。

---

### 问题 3：音频可视化为什么完全不可见？

**答：三个候选里 (a)(c) 排除，(b) 确认为根因，但具体机理不是「采不到」，而是「幅度被压了 256 倍」。**

#### 候选 (a)：`wave_en` 实际为 0？——**排除**

- `rtl/control/key_router.v:161` 复位段：`viz_en <= 1'b1;`（上电即 1）
- 顶层 `:130 wire viz_en;` → `:149 .viz_en(viz_en)` → `:167 wire wave_en = viz_en;` → `:1132 .wave_en(wave_en)`
- `key_router.v:256-259` 只有 Key10 才翻转 `viz_en`，且 `K_TICKER` 只动 `ticker_en` 不动 `viz_en`
- **`.P2_EN(1'b0)`（顶层 `:141-153`）只影响 Key11–15**（`rescan / pattern / invert / grid / beep_muted`），**不影响 `viz_en`**
- 顶层**没有任何**把 `wave_en` 强制置 0 的路径

⇒ `wave_en` 上电即为 1，候选 (a) **排除**。

#### 候选 (b)：幅度换算 / 采样节拍——**确认，但机理与假设不同**

**(b-1) 「`audio_valid` 是 48 kHz 单拍、波形按 25 MHz 采样会采不到」——排除**

`rtl/video/audio_waveform.v:65-77`：

```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ... end
    else if (audio_valid) begin
        for (i = HISTORY-1; i > 0; i = i - 1)
            hist[i] <= hist[i-1];
        hist[0] <= audio_sample[23:8];
    end
end
```

`hist` 是**寄存器数组**，只在 `audio_valid` 单拍时移位；像素扫描（`audio_waveform.v:89-103`）是**组合读** `hist[idx]`。两者同在 `clk_pixel` 域，**不存在跨域或采不到的问题**。
⇒ 假设 (b-1) **排除**。

**(b-2) 「取的是 `mag_abs` 包络而非瞬时样本」——排除**

`video_overlay.v` 里的 `mag_abs` / `level_h` 只用于**电平条**（`px_level`，`video_overlay.v:185-187`），而**电平条被 `level_en = 1'b0` 永久关闭**（顶层 `:166`，注释标为 D-03 降级项）。
波形层用的是**独立例化的 `audio_waveform`**（`video_overlay.v:197-208`），端口直连 `audio_sample(audio_left)` 与 `audio_valid(audio_valid)`，**不经过 `mag_abs`**。
⇒ 假设 (b-2) **排除**。

**(b-3) 真正的根因：两级右移 = 256× 额外衰减**

`rtl/video/audio_waveform.v`：

```verilog
:41   parameter integer Y_SHIFT = 10,      // 幅度缩放: 样本 >>> Y_SHIFT
:62   reg signed [15:0] hist [0:HISTORY-1];
:75   hist[0] <= audio_sample[23:8];       // ← 第一级：24bit 只留高 16 位（右移 8）
:93   wire signed [15:0] y_curr_s = Y_CENTER_S + (s_curr >>> Y_SHIFT);  // ← 第二级：再右移 10
```

**合计右移 18 位 = 256× 额外衰减**，且 `hist` 本身只有 16 bit，无法表达 24 bit 满幅。

#### 仿真实测（关键证据）

**tb A：`_diag_audio/tb_wave_amp_diag.v`**（静态幅度映射，`Y_SHIFT=10`、`Y_CENTER=408`、`wave_en=1`、`de=1`、窗口 x=64..575 共 512 px）

| 场景 | 送入 `audio_sample` | `hist[0]` | `y_off` | 帧扫描 y 范围 | 高度 | 点亮像素 |
|---|---|---|---|---|---|---|
| A1 BGM peak | 19953（符号扩展） | 77 | 0 | 408..408 | **1** | 512 |
| A2 NARR peak | 29162 | 113 | 0 | 408..408 | **1** | 512 |
| A3 ALARM peak | −23260 | −91 | −1 | 407..407 | **1** | 512 |
| A4 16bit 满幅 | 32767 | 127 | 0 | 408..408 | **1** | 512 |
| A5 16bit 最负 | −32768 | −128 | −1 | 407..407 | **1** | 512 |
| B1 tone_gen + | +2097152 | 8192 | +8 | — | — | — |
| B2 tone_gen − | −2097152 | −8192 | −8 | — | — | — |
| C1 若 WAV 左移 8 位对齐（19953<<8） | 5107968 | 19953 | +19 | 427..427 | 1（静态） | 512 |
| C2 若 NARR 左移 8 位 | 7465472 | 29162 | +28 | 436..436 | 1（静态） | 512 |

**⇒ 真实 16 bit WAV 样本（无论多响）在现 RTL 下，波形恒为 `y=408` 的 1 像素水平线。**
**⇒ 即使把 WAV 通路改成 16 bit << 8 对齐 24 bit 满幅，仍只有 ±19…28 行（因为 `Y_SHIFT=10` 又把 24 bit 值压了 1024 倍）。**

**tb B：真实素材驱动（`_diag_audio/tb_wave_real.v`，`$readmemh` 读 BGM.WAV 中段第 200000 起 4096 样本，min=−6568 max=6461）**

| 条件 | `hist` 范围 | y 偏移 | 帧扫描高度 | 像素 |
|---|---|---|---|---|
| 现 RTL | −10…19 | −1…0 | **2** | 520 |
| 若左移 8 位 | −2471…4881 | −3…+4 | **8** | 568 |

**tb C：三级真串联（`_diag_audio/tb_audio_chain_diag.v`，`audio_tone_gen` → `vol_apply` → `audio_waveform`，4 个场景）**

| 场景 | `audio_left` 范围 | `hist[0]` 范围 | 帧扫描高度 | 像素 |
|---|---|---|---|---|
| S1 日常 `ST_AUTO` vol=6 | −1507328…−291398 | −5888…−1139 | **7** | 608 |
| S2 应急 `ST_EMERG` vol=6 | −1507328…314508 | −5888…1228 | **10** | 632 |
| S3 应急 vol=0（钳到 3） | −851968…177765 | −3328…694 | **6** | 584 |
| S4 日常 vol=9（最响） | −2097152…−405424 | −8192…−1584 | **9** | 640 |

对照行（若 `hist` 保留完整 24 bit）：S1 会到 −1472…−285（span 1188 行，**远超 64 行窗口**）、S2 −1472…307、S3 −832…173、S4 −2048…−396。
⇒ 证明两级右移把 ±2.1e6 的 tone 压成 **6…10 行**。

**⚠ 注意：S2（应急）也只有 10 行。** ⇒ 波形不可见**不是日常模式特有**，应急模式同样不可见。这与用户「应急也没可视化」一致。

#### 候选 (c)：坐标被遮挡？——**彻底排除**

| 层 | y 范围 | 证据 |
|---|---|---|
| 波形 | **376…439**（Y_CENTER=408 ± 32 满幅） | `audio_waveform.v:40`、`video_overlay.v:189-193` 注释 |
| 字幕滚动带 | 448…463 | `osd_caption.v`（`TICKER_Y0=448`） |
| 底部信息条 | **468…475**（x 8…103） | `video_overlay.v:233-234`（2026-11-03 已从全宽 y≥464 收窄为 96×8） |
| OSD 参数面板 | y ≤ 65 | `osd_panel.v:113-114/:154-160`（`PANEL_Y0=8`，`LINES=2'd3`、`PAD=5` → `PANEL_Y1 = 8+5+3*16-1+5 = 65`） |

优先级链 `video_overlay.v:336-346`：

```verilog
px_grid ? 24'h00_FF_00 : px_sci ? 24'h00_C8_E0 : px_box_on ? 24'h40_E0_D0 :
px_level ? 24'h20_FF_20 : px_wave ? wave_rgb :
px_info ? 24'h10_18_20 : px_caption ? 24'hF0_F0_F0 : img_final
```

`px_wave` 排在 `px_info` / `px_caption` **之前**（更高优先），且 y 区间三者互不重叠。
`brightness_apply.v:126-127` 是纯组合（不加拍、不改坐标）；`osd_panel.v:246` 只在 `panel_on` 且 `in_panel` 时覆盖。

⇒ 候选 (c) **彻底排除**。

#### 问题 3 的总结论（回答 captain 的「修好音频后波形会不会自动出现」）

**不会。`audio_waveform` 有一个独立的幅度换算缺陷（R5），与音频通路无关。**
- 波形门控 `wave_en` 正常（=1）
- 波形时序正常（`hist` 在 `clk_pixel` 域、`audio_valid` 单拍移位，无跨域问题）
- 波形几何正常（窗口、连线、优先级都对，仿真 76 项全过）
- **唯一坏的是幅度换算：`hist[0] <= audio_sample[23:8]` 与 `Y_SHIFT=10` 两级右移，把真实 16 bit 样本压成 1 像素线**

#### 为什么现成的 `tb_audio_waveform.v` 全绿却测不出这个缺陷

`sim/testbench/tb_audio_waveform.v` 是**按现实现写的**，把 256× 预缩放当成了规格：

```verilog
:59   localparam integer Y_STEP = 1 << Y_SHIFT;    // = 1024
:241-251  push_sample(24'sh12_3456); 期望 hist[0]===16'h1234   // 证明 hist 取 [23:8]
:275-278  注释：「hist 只存 audio_sample[23:8]，想让 hist[0]=V 必须送 audio_sample=V<<8；
          若按低 16 位的量级送 0x000200 实际只得到 hist=2，y 仍旧是 200
          —— 首版就是栽在这个 256 倍的换算上」
:282      push_sample(Y_STEP*256);      // 才能得到 1 行偏移
:306      push_sample(24'sh7F_FF00);    // 才能到 Y_TOP
```

⇒ tb 送的是 `0x7FFF00`（= 32767 << 8），**不是真实 WAV 的 0x007FFF**。因此 `_final_tb_audio_waveform.log` 里那 60+ 条 PASS（含 `[ymap] full positive amplitude reaches Y_TOP (439)`）**证明不了上板可见性**。

---

### 问题 4：应急模式的声音来自哪里？

**答：来自蜂鸣器（引脚 H11），既不是 `ALARM.WAV`，也不是 `tone_gen`。**

#### 4.1 蜂鸣器通道（用户实际听到的）

`rtl/top/dmz_eg4s20_hdmi_top.v:1336-1350`：

```verilog
buzzer_tone #(.CLK_FREQ_HZ(25_000_000)) u_buzz (
    .tone_sel(beep_muted ? 3'd0 : (alarm_req ? 3'd3 : (m_emerg ? 3'd2 : 3'd1))),
    .trig(key_event),
    .buzzer_out(buzzer));            // buzzer = 顶层 output，引脚 H11（:28）
```

`rtl/audio/buzzer_tone.v`：
- `buzzer_tone.v:21-23` 档位定义：0=静音 / 1=按键音 C5≈523 Hz（100 ms）/ **2=应急音 E6≈1319 Hz（250 ms 响 / 250 ms 停）** / 3=故障告警音 A4≈440 Hz（700 ms 停 / 300 ms 响）
- `buzzer_tone.v:288-297` `half_period = (tone_sel==3'd2) ? HALF_E6 : ...`；`sq_en = (tone_sel==3'd2 && emerg_on) || ...`
- **本地振荡器合成，不经过 SD / WAV / `vol_apply` / HDMI 音频 / `pcm_to_pwm` 任何一环**

⇒ 用户听到的「应急有声」是 E6 的 250 ms 断续蜂鸣，**与音频通路无关**。

#### 4.2 `tone_gen` 在应急下也本该出声（但通常被 ST_FAIL 掐掉）

`rtl/audio/audio_tone_gen.v:113-123`：

```verilog
ST_EMERG: note_idx = hold_cnt[13] ? 3'd7 : 3'd4;   // C5 / G4 交替
```

#### `audio_tone_gen.v:142`：`silent` 判据

```verilog
wire silent = mute || (playback_state == ST_IDLE) || (playback_state == ST_FAIL);
```

**`ST_EMERG` 不在静音判据里** ⇒ 应急模式下 `tone_gen` 本该输出 C5/G4 交替三角波（±2.1e6），送到 HDMI 与 PWM。
但顶层 FSM 优先级（`rtl/top/dmz_eg4s20_hdmi_top.v:957-971` 的 `always @(*)` 次态块）是：

```verilog
playback_next = ST_IDLE;                        // 默认兜底
if (sd_or_gallery_fail || image_failed) ST_FAIL;  // ← 最高优先级
else if (mode == 2)                     ST_EMERG;
else if (sd_ok && !gallery_done)        ST_SCAN;
...
```

⇒ **只要 `sd_fail` / `gallery_fail` / `image_failed` 任一为 1，`playback_state` 就钉在 `ST_FAIL`，`ST_EMERG` 永远进不去**，`tone_gen` 的 `silent=1`，三角波被静音为全 0。
而蜂鸣器走 `m_emerg`（模式信号）而非 `playback_state`，**不受影响** ⇒ 完全解释了「应急有声、但音频通路依旧没声」。

#### 4.3 这一条区分了「WAV 通路坏了」和「只是日常没声」

| 假设 | 若成立，应急模式应表现为 | 实测/推断 |
|---|---|---|
| WAV 通路坏了，`tone_gen` 正常 | 应急有 C5/G4 三角波（PWM 可闻） | 未验证（需上板听 3.5mm） |
| **`playback_state` 钉在 ST_FAIL** | **应急只有蜂鸣器，`tone_gen` 也被静音** | **与用户现象一致** |
| `ALARM.WAV` 被播放 | 应急听到的是 ALARM 素材（−6.67 dBFS 的语音/警报） | **不可能**：R1 使 ALARM.WAV 也定位失败 |

⇒ 用户现象（应急只有蜂鸣器）**同时指向 R6（ST_FAIL 静音死锁）与 R1（WAV 全失败）**，而不是「只是日常没声」。

---

## 3. 因果链（每环附 文件:行号）

### 3.1 日常/科普「没声音」的完整链条

```
[现场] 卡上无 WAV（只烧了 RES640）或烧成子目录
   └─ R7  assets/v2/sdcard/RES640/ 只有 6 BMP + MANIFEST；BURN640/MANIFEST.TXT 要求"内容"平铺到根
        ↓ 即使卡上有 WAV，下面仍然全部成立 ↓
[RTL] audio_src_mux 8.3 常量字节序反序
   └─ R1  rtl/audio/audio_src_mux.v:34-36  {"BGM", 40'h20×5, "WAV"} → target_name[7:0]='V'
          rtl/storage/fat32_reader.v:683       offset 0 期望 target_name[7:0]='V'
          rtl/storage/fat32_reader.v:582-583   磁盘 offset 0 是 'B'(0x42) → nm_bad 恒真
          rtl/storage/fat32_reader.v:396-398   目录扫完 → err_code=4 → S_FAIL
        ↓
[RTL] wav_stream_player 进入 W_FAIL
   └─ R1  rtl/audio/wav_stream_player.v:733   fat_fail → err_code=E_NOTFOUND(6) → st<=W_FAIL
          rtl/audio/wav_stream_player.v:889-893  busy<=0; playing<=0; 停在 W_FAIL
        ↓
[RTL] src_started 粘滞，永不重试
   └─ R2  rtl/audio/audio_src_mux.v:113-121  只有 src_sel_d!=sel_c 才清零 src_started
        ↓
[结果] wav_playing 恒 0 → 样本 mux 选 tone_gen
   └─ 顶层 :1039-1041  src_sample_l = wav_playing ? wav_sample_l : tone_left
        ↓
[分支 A] playback_state 正常（SCAN/LOAD/READY/AUTO）
   └─ tone_gen 出声（−12.04 dBFS）
        ├─ PWM/3.5mm：−14.91 dBFS → 正常可闻
        └─ HDMI：−12.04 −2.87 −36.12 = −51.03 dBFS → **不可闻**（R4）
[分支 B] playback_state = ST_FAIL（sd_fail/gallery_fail/image_failed）
   └─ R6  顶层 :859/:960 → ST_FAIL；audio_tone_gen.v:142 silent=1
        └─ audio_valid 仍 48 kHz，但样本全 0 → **两路都静音**
        ↓
[结果] 用户「日常/科普没声音」；应急只有蜂鸣器（H11，独立通道）
```

### 3.2 「全程无可视化」的独立链条

```
wave_en = viz_en = 1（key_router.v:161，顶层 :167）              ← 门控正常
        ↓
audio_waveform 接收 audio_left / audio_valid（顶层 :1136）
        ↓
hist[0] <= audio_sample[23:8]（audio_waveform.v:75）             ← 第一级右移 8 位
        ↓
y_curr_s = Y_CENTER_S + (s_curr >>> 10)（audio_waveform.v:93）   ← 第二级右移 10 位
        ↓
真实 16bit WAV 样本（|x|≤32767）→ hist ≤ 127 → >>>10 = 0
        ↓
y_curr 恒 = 408 → 帧扫描 height=1，pixels=512
        ↓
[结果] 屏幕上是 y=408 的 1 像素黄色水平线（24'hFF_FF_40），肉眼几乎不可辨
```

即使音频通路完全修好，只要 R5 不改，波形**仍然**是 1 像素线。

---

## 4. 分级修复建议

### 4.1 必改（阻塞「有声 + 有波形」）

| 编号 | 改动 | 文件:行 | 改动面 | 需重跑综合？ |
|---|---|---|---|---|
| **F1** | 修正 8.3 常量字节序 | `rtl/audio/audio_src_mux.v:34-36` | 1 文件 3 行 | 是 |
| **F3** | WAV 16bit → 24bit 左移 8 位对齐 | `rtl/audio/wav_stream_player.v:438-441` | 1 文件 4 行 | 是 |
| **F4** | 修正波形幅度换算 | `rtl/video/audio_waveform.v:41/:62/:75` | 1 文件 3 处 | 是 |
| **F5** | HDMI 衰减 6 → 2（或 0） | `rtl/top/dmz_eg4s20_hdmi_top.v:1065` | 1 文件 1 行 | 是 |

> **注：原先列为 F2 的「`gallery_probe.v` RLE 常量字节序」经仿真证伪，已撤销。** 详见 §4.4。

**F1 具体写法**（要 `target_name[7:0]` = 首字符，必须倒序）：

```verilog
// 88 bit = 11 字节；Verilog 拼接最左操作数是最高位 ⇒ 书写顺序必须与目录项字节顺序相反
parameter [87:0] NAME_BGM   = {8'h56, 8'h41, 8'h57, 40'h20_20_20_20_20, 8'h4D, 8'h47, 8'h42},             // "BGM     WAV"
parameter [87:0] NAME_NARR  = {8'h56, 8'h41, 8'h57, 32'h20_20_20_20,    8'h52, 8'h52, 8'h41, 8'h4E},       // "NARR    WAV"
parameter [87:0] NAME_ALARM = {8'h56, 8'h41, 8'h57, 24'h20_20_20,       8'h4D, 8'h52, 8'h41, 8'h4C, 8'h41}; // "ALARM   WAV"
```

（更可读的等价写法：`{"V","A","W", 40'h20_20_20_20_20, "M","G","B"}` —— 但要加注释说明这是**倒序**，否则下一个人又会改回来。）

> 上面三条常量已用 `_diag_audio/tb_fix_constants.v` 逐字节展开核对过（把常量按 `offset k ← NAME[k*8 +: 8]` 还原成 11 字节字符串，与磁盘目录项名比对），结果见 §4.5。

**F3 具体写法**（WAV 是 16 bit，`tone_gen` 是 24 bit 满幅的 0.25，两者差 48.2 dB；不修则 WAV 声音比提示音小 48 dB）：

```verilog
sample_l <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};   // 16bit → 24bit 左对齐
sample_r <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};
hold_l   <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};
hold_r   <= {{8{fifo_q[15]}}, fifo_q[15:0], 8'h00};
```

注意：这会同步改变 `sim/testbench/tb_wav_stream_player.v:635-639` 的 `exp_samp()` 期望值，**tb 必须一起改**（见 §5）。

**F4 三个可选方案**：

- **方案 4a（不可行，列出以便排除）**：`hist` 保持 16 bit，只把 `Y_SHIFT` 从 `10` 改小。
  ✗ 不行 —— `hist[0] <= audio_sample[23:8]` 已经把 16 bit 样本（`0x007FFF`）压成 7 bit（`0x7F`），`hist` 里根本没有幅度信息，改 `Y_SHIFT` 救不回来。必须同时改 `hist` 的取位，见 4b / 4c。

- **方案 4b（推荐，语义最正确）**：`hist` 改 24 bit，`Y_SHIFT` 改 `17`（24 bit 满幅 ±8388607 `>>>` 17 = ±64 行，正好占满 64 行窗口）。
  ```verilog
  reg signed [23:0] hist [0:HISTORY-1];       // 24 bit
  hist[0] <= audio_sample;                    // 全 24 bit，不预缩放
  wire signed [23:0] y_curr_s = Y_CENTER_S + (s_curr >>> Y_SHIFT);  // Y_SHIFT=17
  ```
  代价：`hist` 从 64×16 bit = 1024 bit 涨到 64×24 bit = 1536 bit（+512 个 REG）。
  `audio_waveform.v:28` 注释称「EG4S20 当前余量 REG 16k 空闲、LUT 12k 空闲」，**512 个 REG 完全可承受**。

- **方案 4c（省资源，但要接受 tone 与 WAV 幅度不一致的观感）**：`hist` 保持 16 bit 且**取位不变**（`hist[0] <= audio_sample[23:8]`），只把 `Y_SHIFT` 从 `10` 改为 **`8`**。
  - 修完 F3 后，16 bit WAV 在 24 bit 域里是 MSB 对齐的 ⇒ `audio_sample[23:8]` 就是原始 16 bit 样本 `x`（±32767）⇒ `>>>8` = ±127 行，**超出 64 行窗口，会削顶**。
  - tone_gen ±2 097 152 ⇒ `[23:8]` = ±8192 ⇒ `>>>8` = ±32 行，正好满幅。
  ⇒ 必须再加一级饱和/钳位（`hist` 写入前把 |x| 限到 16383 以内），改动反而更多。**仅在 4b 的资源评估不通过时才考虑。**

**结论：推荐方案 4b**（`hist` 24 bit + `Y_SHIFT=17`），它让 WAV 与 tone 的比例关系保持真实、无需任何钳位：
- 修完 F3 后 WAV 满幅 ≈ 1.0 FS（`32767<<8 = 8 388 352`，`>>>17` = 64）→ 占满 64 行窗口
- tone 0.25 FS（±2 097 152 `>>>17` = ±16）→ ±16 行，**实测的 S2/S4 那 6…10 行会变成约 33 行跨度，明显可见**

**F5 取值**：见 §2.4。推荐 `2`，若确认官方核能容忍满幅则可用 `0`。

### 4.2 权衡项（建议做，但可延后）

| 编号 | 改动 | 文件:行 | 说明 |
|---|---|---|---|
| **T1** | `src_started` 加超时重试 | `rtl/audio/audio_src_mux.v:101-125` | 失败后永久不重试是设计缺陷。建议加一个 ~1 s 计数器，超时后清 `src_started` 重发 `start`。改动面 1 文件 ~10 行 |
| **T2** | `wav_stream_player` 的 `err_code` / `playing` / `underrun` 接到可观测点 | 顶层 `:1017/:1018` | 现在三根线全部空连接（`.err_code()`、`.fifo_level()`），上板时**完全看不到 WAV 为什么失败**。建议至少把 `wav_underrun` 接 LED、`err_code` 接数码管低位 |
| **T3** | `ST_FAIL` 不静音 `tone_gen` | `rtl/audio/audio_tone_gen.v:142` | 现在卡一坏就全静音，用户无法判断"是没卡还是没声"。建议改为 `silent = mute || (playback_state == ST_IDLE)`，让 FAIL 也有告警三角波（配合蜂鸣器 A4 更明确） |
| **T4** | 测试台去掉 parameter override | `sim/testbench/tb_audio_src_mux.v:67-69`、`tb_wav_stream_player.v:559-560/:655` | 正是 override 掩盖了 RTL 默认值的 bug。建议**保留 override 用例**，但**新增一条不 override 的端到端用例** |
| **T5** | 现场素材打包脚本 | `assets/v2/sdcard/` | `RES640/` 零 WAV 是陷阱。建议在每个 RES 目录里也放一份 WAV，或在 MANIFEST 里显式警告 |

### 4.3 不要改的

- **`buzzer_tone`**：工作正常，是应急可闻性的唯一来源。
- **`audio_src_mux.v:93` 的 `eff_audio_en` 应急强制出声**：派生信号手法正确（不改寄存器，只改组合输出）。
- **`audio_arc` 的 ACR_N=6144 / AUDIO_DIV=48**：见 §6.5，数值正确。
- **`gallery_probe.v:151-156` 的 `RLE_NAME`**：**字节序是对的，不要动。** 见 §4.4。

### 4.4 撤销的假设：`RLE_NAME` 字节序（原 F2，经仿真证伪）

我一度推断 `gallery_probe.v:154-156` 的 `RLE_NAME` 与 `audio_src_mux` 同根因、也写反了。**这个推断是错的，已用仿真证伪。**

`_diag_audio/tb_rle_name_order.v` 把 RTL 里的常量逐字节复制过来，按 `fat32_reader` 的契约（`offset k ← target_name[k*8 +: 8]`）展开，与磁盘 "SCI     RLE" 的 11 字节比对：

```
[rle ] RLE_NAME bytes(0..10) = 'SCI     RLE'   [7:0]=0x53
[disk] SCI.RLE bytes(0..10) = 'SCI     RLE'
PASS: RLE_NAME[7:0]=0x53 ('S') matches disk offset 0
PASS: RLE_NAME matches 'SCI     RLE' on disk (byte order CORRECT)
SUMMARY: errors=0
ALL CHECKS PASSED: rle_name_order
```

**为什么它是对的而 `NAME_BGM` 是错的**：`RLE_NAME` 的书写顺序本身就是**从高字节到低字节倒着写的** —— 最左边是扩展名 `'E','L','R'`（高位），最右边是主名首字符 `'S','C','I'`（低位 0x53）。注释写「'R' 'L' 'E' → 扩展名」指的是**语义**（这三个字节是扩展名），不是书写顺序。所以 `RLE_NAME[7:0] = 0x53 = 'S'`，恰好正确。

而 `NAME_BGM = {"BGM", 40'h20×5, "WAV"}` 是**正序**书写（最左 `'B'` 落最高位），所以 `target_name[7:0] = 'V'`，错了。

**⇒ 结论修正：`gallery_probe` 的 RLE 定位没有字节序问题。用户现象③「RLE 视频完全没工作」另有原因，不属本任务范围（归 t3），但本报告明确指出：不是字节序。** 这条对 t3 很重要 —— 别去改一个本来就对的地方。

### 4.5 修复常量本身的校验（`tb_fix_constants.v`，已跑通）

§4.1 给出的三条常量**不能靠肉眼相信**——本报告初稿就写错过 `NAME_NARR` 与 `NAME_ALARM` 两条（当时把 `'R','R','A','N'` 写成了 `'R','R','A'` + 缺一个字节，`ALARM` 同理）。因此新增纯常量 tb `_diag_audio/tb_fix_constants.v`：把常量按 `fat32_reader` 契约（`offset k ← name[k*8 +: 8]`）展开成 11 字节字符串，与磁盘目录项名**逐字节**比对（大小写不敏感规则同 `rtl/storage/fat32_reader.v:582`），同时把**现行错误写法**也展开做对照。

实测输出（`vsim -c -quiet work_fix.tb_fix_constants`）：

```
[FIX ] BGM  :  bytes(0..10) = 'BGM     WAV'   [7:0]=0x42  [87:80]=0x56
[FIX ] NARR :  bytes(0..10) = 'NARR    WAV'   [7:0]=0x4e  [87:80]=0x56
[FIX ] ALARM:  bytes(0..10) = 'ALARM   WAV'   [7:0]=0x41  [87:80]=0x56
[BUG ] BGM  :  bytes(0..10) = 'VAW     MGB'   [7:0]=0x56  [87:80]=0x42
[BUG ] NARR :  bytes(0..10) = 'VAW    RRAN'   [7:0]=0x56  [87:80]=0x4e
[BUG ] ALARM:  bytes(0..10) = 'VAW   MRALA'   [7:0]=0x56  [87:80]=0x41
PASS: FIX_BGM   matches disk 'BGM     WAV'
PASS: FIX_NARR  matches disk 'NARR    WAV'
PASS: FIX_ALARM matches disk 'ALARM   WAV'
PASS: FIX_BGM[7:0]   == 0x42 ('B')
PASS: FIX_NARR[7:0]  == 0x4E ('N')
PASS: FIX_ALARM[7:0] == 0x41 ('A')
PASS: BUG_BGM   does NOT match disk (reproduces the bug)
PASS: BUG_NARR  does NOT match disk (reproduces the bug)
PASS: BUG_ALARM does NOT match disk (reproduces the bug)
PASS: BUG_BGM[7:0] == 0x56 ('V') = last char of extension
SUMMARY: checks=10 errors=0
ALL CHECKS PASSED: fix_constants
```

**⇒ §4.1 的三条常量已逐字节验证正确；现行三条已逐字节验证必不命中。** 修复实施时请**照抄 §4.1 的常量原文**，不要凭"把字符串倒过来"心算（本报告已证明心算会错）。

---

## 5. 需仿真验证的 tb 与期望断言

### 5.1 已跑通的诊断 tb（仓库外 `_diag_audio/`，不进位流）

| tb | 验证目标 | 实测结果 |
|---|---|---|
| `tb_name_order.v` | 默认 parameter vs override 的目录匹配 | 默认 `err_code=4 fail=1`；override `found=1 err_code=0`。**证明 R1** |
| `tb_rle_name_order.v` | `gallery_probe.RLE_NAME` 字节序 | `bytes(0..10)='SCI     RLE'`、`[7:0]=0x53`、与磁盘逐字节全等 → **字节序正确，原 F2 假设撤销**（§4.4） |
| `tb_wave_amp_diag.v` | 静态幅度映射 | 真实 16bit 样本 height=**1**；tone ±2.1e6 → ±8 行。**证明 R5** |
| `tb_wave_real.v` | 真实 BGM 样本驱动 | 现 RTL height=**2**；若左移 8 位 height=8 |
| `tb_audio_chain_diag.v` | tone→vol→wave 三级串联 | 4 场景 height=**6/10/6/9**。**证明应急也不可见** |
| `tb_fix_constants.v` | §4.1 给出的三条修复常量是否真的对 | FIX 三条展开为 `'BGM     WAV'` / `'NARR    WAV'` / `'ALARM   WAV'`（逐字节全等）；BUG 三条展开为 `'VAW     MGB'` 等（必不命中）。`checks=10 errors=0`。**证明 F1 的写法可直接照抄**（§4.5） |

### 5.2 修复后必须新增/修改的 tb（建议交给 t6 回归任务）

| tb 名 | 期望断言 | 覆盖的修复 |
|---|---|---|
| `tb_audio_src_mux.v`（**新增不 override 的 case**） | `u_dut.NAME_BGM[7:0] == 8'h42`（'B'）；`src_name[7:0] == 8'h42` | F1 |
| `tb_wav_stream_player.v`（**改 `exp_samp`**） | `exp_samp = {8{raw[15]}}, raw[15:0], 8'h00`；`s_val[k] == k*100 << 8` | F3 |
| `tb_wav_e2e_default.v`（新增） | 用**默认 parameter** 的 `audio_src_mux` + 真实 FAT32 镜像：`found=1`、`playing=1`、`sample_valid` 有脉冲、`sample_l != 0`、`err_code==0` | F1+F3 端到端 |
| `tb_audio_waveform.v`（**新增真实幅度 case**） | `push_sample(24'sh00_7FFF)`（= 32767，**不乘 256**）→ 帧扫描 `height >= 20`；`push_sample(24'sh7F_FF00)` → `y == Y_TOP` | F4 |
| `tb_audio_waveform_chain.v`（新增） | 串联 `tone_gen → vol_apply → audio_waveform`，`ST_AUTO` + `vol=6` → `height >= 25` | F4 |
| `tb_hdmi_audio_path.v`（**新增幅度断言**） | 抓 `u_top.hdmi_audio_left`，断言 `|hdmi_audio_left| >= |audio_left| >>> 2`（即衰减 ≤ 12 dB） | F5 |

### 5.3 无法在本会话跑的部分

- `sim/scripts/run_audio_regression.ps1` 与 `run_unit_coverage_regression.ps1` **在本会话不可用**：它们写 `reports\s6_integration\audio\compile.txt` 与 `result.json`，该路径在沙箱下 `Access denied`（`[sandbox: file access denied under workspace-write mode]`），脚本 `[exit code: 1]`。
  ⇒ 只能自建 tb 在 `_diag_audio\`（仓库外）里跑。**修复后的正式回归请由有写权限的成员执行。**
- 顶层整体仿真（`dmz_eg4s20_hdmi_top`）需要 Anlogic 原语库（`D:\TD_6_24_APP\sim_release\eg4`：`eg_logic_io.v`、`eg_phy_glbl.v`、`eg_phy_pll.v`、`eg_logic_clk.v`、`eg_phy_sdram_2m_32.v`）与 `+define+SDRAM_SIM_MODEL`，本次未跑。

---

## 6. captain 追加 5 点核查结果

### 6.1 `>>>6` 是否是第二重根因？

**是，但仅限 HDMI 支路。** 见 §2.1–2.4 完整量化。
- HDMI：−38.99 dB 固定衰减 → BGM 到 −54.29 dBFS → **不可能听见**
- 3.5mm（`pcm_to_pwm`，吃未衰减 `audio_left`，顶层 `:1357-1359`）：−2.87 dB → **正常可闻**
- 建议改 `2`（−12.04 dB），**不要直接改 0 除非确认官方核满幅容忍度**
- **不影响 ACR**（`audio_arc.v:26-31` 只吃 `audio_valid`）

### 6.2 `wav_playing` 恒 0 时 `tone_gen` 会不会接管？会不会全静音且 `err_code=0`？

**会接管。** `wav_playing=0` → 顶层 `:1039-1041` 选 `tone_valid/tone_left/tone_right` → tone 正常输出。
**不会全静音**，除非 `playback_state ∈ {ST_IDLE, ST_FAIL}`（`audio_tone_gen.v:142`）。
**`err_code` 在顶层是空连接**（`:1017 .err_code()`），上板不可见 —— 这是 T2 建议要修的观测性问题，不是"err_code=0 导致无声"。

### 6.3 `vol_apply` 档 6 的实际增益？

**23/32 = 71.875% = −2.87 dB**，不是接近 0。
`rtl/audio/vol_apply.v:103-128` 表值（`function signed [23:0] vol_gain`）：档 0..9 = {3,6,10,13,16,20,23,26,29,32}/32。
档 6 的表达式 `y = x - (x>>>2) - (x>>>5)` = `x - 0.25x - 0.03125x` = `0.71875x` ✓。
方向：**档 0 最轻（3/32 = −20.6 dB），档 9 最响（32/32 = 0 dB）**，与亮度方向相反。
`key_router.v:156` 复位 `vol_lvl <= 4'd6`，注释写"约 50%"但实际是 71.875%（注释有误，不影响功能）。

### 6.4 `src_start` 若 `sd_ready` 永不到达会不会永不启动且不报错？

**会永不启动，但不完全"不报错"。**
- `audio_src_mux.v:104-125`：`sd_ready=0` ⇒ `src_started` 保持 0，`src_start` 永不发 ⇒ `wav_stream_player` 停在 `W_IDLE`（`wav_stream_player.v:668-715`），`busy=0`、`playing=0`、**`err_code=0`** ⇒ **完全静默失败**。
- 但 `sd_ready_audio = sd_ok`（顶层 `:450`），而 `sd_ok` 只要 MBR 扇区 0 签名 `0xAA55` 正确就为 1（`sd_probe.v:153`）。**几乎所有卡都有 MBR 签名**，所以 `sd_ok` 大概率成立。
- 真正会卡住的是 `fat32_reader` 的 FAT32 签名校验（`fat32_reader.v:339-349`）：非 FAT32（exFAT/NTFS）→ `err_code=1/2` → `W_FAIL`（此时会报错，只是顶层看不到）。
- ⇒ **`sd_ready` 不是主要风险点，FAT32 格式才是。** 但仍建议按 T1 加超时重试，避免任何一侧卡死导致永久静默。

### 6.5 `audio_arc` 静音时是否仍正常发 ACR 包？

**正常。**
- `audio_arc.v:28` 端口只有 `audio_valid`，**不看样本值**
- `audio_tone_gen.v:152` `audio_valid <= sample_en`（恒按 48 kHz 出，**静音也出**）
- `vol_apply.v:155` `sample_valid_out <= sample_valid`（恒 48 kHz 透传）
- `audio_arc.v:40-68`：
  ```verilog
  localparam [7:0] AUDIO_DIV = ACR_N >> 7;   // 6144 >> 7 = 48
  wire div_tick = audio_valid && (div_cnt == AUDIO_DIV - 1'b1);
  ```
  `div_cnt` 只在 `audio_valid` 时推进（`audio_arc.v:46-53`），而 **`cts_cnt` 每拍都 +1**（`if (audio_valid) ... else cts_cnt <= cts_cnt + 1'b1`）—— `cts_cnt` 是**像素时钟计数**，不是样本计数。
  48 个 `audio_valid` @ 48 kHz = 1 ms；1 ms @ 25 MHz = 25000 个像素时钟。
  ⇒ 每包 `acr_cts = cts_cnt + 1 = 25000`、`acr_n = 6144`。
  校验：`128 × fs = f_pixel × N / CTS` ⇒ `128 × 48000 = 25e6 × 6144 / 25000` ⇒ `6,144,000 = 6,144,000` ✓ **数值正确。**
- ⇒ **显示器端会判定"有音频流"，只是样本全 0 或极小。** 这解释了为什么显示器可能显示"有信号"但听不到声。

### 6.6 完整判定树（H1 / H2 / H3 + R6 合并）

把「完全没声音」的四种互斥解释合成一棵树。**每一个叶子都能由源码静态确定，只有"H1 还是 H3"需要上板分流。**

```
[前提] audio_valid 恒 48 kHz（audio_tone_gen.v:152 / vol_apply.v:155），
       ACR 恒正常（§6.5）⇒ 接收端一定"看到音频流"，所以"没声音"必然是样本幅度问题或全 0。

├─ H2  playback_state ∈ {ST_IDLE, ST_FAIL}
│   └─ audio_tone_gen.v:142  silent = mute || ST_IDLE || ST_FAIL  ⇒ 样本恒 0
│       ├─ R6-a  ST_FAIL：sd_fail / gallery_fail / image_failed 任一为 1
│       │        顶层 :859 sd_or_gallery_fail；:960 最高优先级 → ST_FAIL
│       │        sd_fail 粘滞（sd_probe.v:93 P_FAIL 终态、:166 sd_fail<=1）
│       │        image_player.failed 粘滞（:362/:386/:388/:394/:434 置 1，仅 :253/:411 清 0）
│       └─ R6-b  ST_IDLE：image_ready=0 且 sd_ok=0（连 SD 都没探通）
│   ⇒ 两路（HDMI + 3.5mm）全静音，波形也恒为 0 幅度的一条线
│   ⇒ 【上板唯一可靠判据：LED7 亮 + 数码管 DIG3 显示助记字母，见下方"注意"】
│
├─ H3  wav_playing = 1，但 FIFO 从未拿到 PCM 字节
│   └─ wav_stream_player.v:591-595  进 ID_DATA 头就 playing<=1（此时零字节）
│       :432  if (fifo_cnt != {(FIFO_AW+1){1'b0}}) 不成立 → sample_l 保持复位值 0
│       :445-455  ever_played=0 → underrun 不置位（所以连 underrun 灯都不亮）
│       顶层 :1039-1041  wav_playing=1 把样本 mux 锁死在 WAV 侧 → 输出恒 0
│   ⇒ 两路全静音；err_code 可能为 0；**tone_gen 被 mux 屏蔽，不会兜底**
│   ⇒ 与 H2 的区别：H3 下 LED7 灭、数码管正常（err_active=0）
│
└─ H1  playback_state ∈ {ST_SCAN, ST_LOAD, ST_READY, ST_AUTO, ST_EMERG} 且 wav_playing=0
    └─ 样本 mux 选 tone_gen（顶层 :1039-1041），tone 幅度 ±2 097 152 = −12.04 dBFS
        ├─ 3.5mm（pcm_to_pwm 吃未衰减 audio_left，顶层 :1357-1359）：−14.91 dBFS
        │   ⇒ **正常可闻**。若 3.5mm 也没声，则不是 H1，回到 H2/H3
        └─ HDMI（顶层 :1066-1067 再 >>>6）：−51.03 dBFS（tone）
            ⇒ **不可闻**（§2.3 判据：约 30 dB SPL，被 45–55 dB SPL 底噪掩蔽）
    ⇒ **H1 是"只有 HDMI 无声、3.5mm 有声"的唯一解释**，也是 R4 的直接证据
```

**注意（校正 captain 流程里的一处不可达判据）：`数码管 DIG3 显示 6` 在本工程里不可能出现。**
`rtl/top/dmz_eg4s20_hdmi_top.v:1382-1383`：

```verilog
wire [3:0] error_value = err_active ? prompt_lo : image_error;
wire [3:0] state_value = err_active ? prompt_hi : {1'b0, playback_state};
```

DIG3 只在 `err_active == 0` 时显示 `playback_state`。而 `rtl/control/err_prompt.v:201/:231/:273` 把 `sd_fail / gallery_fail / image_failed` 三个条件**全部**映射为 `err_active = 1'b1` —— 这三者正是 `ST_FAIL` 的三个触发条件（顶层 `:960`）。
⇒ **`ST_FAIL` ⇒ `err_active=1` ⇒ DIG3 显示助记字母（C/F/b/d），永远不会显示 `6`。**
⇒ 判 ST_FAIL 要看：**LED7（`err_active`，顶层 `:1373`）亮 + DIG3 是字母**，而不是找数字 6。
⇒ 另外 `err_prompt.v:406-416` 的"零张图"分支（`gallery_done && gallery_count==0`）也置 `err_active=1`、显示 `00`，此时 `playback_state` 通常是 `ST_IDLE` —— 这是 R6-b 的典型现场。

---

## 7. 上板「一分钟判别流程」（给用户）

> 这张表决定下一步查什么，比任何代码改动都重要。**必须先测再改。**

### 第 0 步：确认卡内容（30 秒）

1. 把卡插电脑，**根目录**（不是子目录）里应该有：`BGM.WAV`、`NARR.WAV`、`ALARM.WAV`、`IMG001.BMP`…`IMG006.BMP`、`SCI.RLE`、`TICKER.TXT` 等 **17 个文件平铺**。
2. 如果根目录只有一个 `BURN640` 文件夹 → **错了**，要把 `BURN640` 里的**内容**拷到根。
3. 如果根目录只有 6 张 BMP → **错了**，用的是 `RES640/` 那套，**没有任何 WAV**。

### 第 1 步：看数码管与 LED（10 秒）

> **先记住一个源码事实（顶层 `:1382-1383`）**：DIG3 只在 `err_active == 0` 时显示 `playback_state`，一旦有错就整组切成助记字母。而 `ST_FAIL` 的三个触发条件（`sd_fail`/`gallery_fail`/`image_failed`）**每一个都会把 `err_active` 拉高**（`err_prompt.v:201/:231/:273`）⇒ **`ST_FAIL` 时 DIG3 显示的是字母，绝不会显示 `6`**。所以"找数字 6"是查不到的，请看 LED7。

| 现象 | 含义 | 下一步 |
|---|---|---|
| **LED7 亮** + DIG3 显示字母（`C` / `F` / `0` / `b` / `d`） | `err_active=1`，有面向用户的错误 | 记录 DIG3 字母 + DIG2 子码，查 §7.2 对照表。**若确认是 `sd_fail`/`gallery_fail`/`image_failed`，则 `playback_state` 必为 `ST_FAIL` ⇒ R6 静音死锁成立** |
| **LED7 亮** + DIG3/DIG2 显示 `00` | "卡读通了但零张图"（`err_prompt.v:406-416`） | `playback_state` 通常停在 `ST_IDLE` ⇒ 同样没有兜底音（R6-b） |
| **LED7 灭** + DIG3 显示 `0` | `ST_IDLE`，`sd_ok=0` 且 `image_ready=0` | 也没有兜底音；查 `sd_ok`（`sd_probe.v:153`）与 `image_ready` |
| **LED7 灭** + DIG3 显示 `1..5` | 正常过程态（1扫描 2装载 3就绪 4轮播 5应急） | 兜底音 `tone_gen` **应该存在** ⇒ 若仍无声，是 R4（HDMI 衰减）或 H3（`wav_playing` 卡死） |

### 第 2 步：分别听两路（30 秒）

| 测量结果 | 说明什么 | 修什么 |
|---|---|---|
| **HDMI 有声、3.5mm 无声** | `>>>6` 不是问题，问题在 PWM/功放硬件 | 查 F3 引脚与功放供电 |
| **HDMI 无声、3.5mm 有声** | **`>>>6` 是根因**（R4 / H1） | 改 `HDMI_AUDIO_ATTEN_SHIFT`（F5） |
| **两路都无声 + LED7 亮 / DIG3 是字母** | FSM 锁死 `ST_FAIL` → `tone_gen` 被静音（R6） | 查卡（R6 + R7），见 §7.2 |
| **两路都无声 + LED7 灭 / DIG3 = 1..5** | 兜底音本该有 ⇒ `wav_playing` 卡死（H3）或通路更上游断了 | 查 `wav_playing` / `err_code`（需先做 T2 观测点） |

### 第 3 步：波形

| 现象 | 说明 |
|---|---|
| 屏幕 y≈408 有一条 1 像素黄色横线 | **R5 确认**（`audio_waveform` 幅度塌陷），与音频无关 |
| 完全看不到任何黄色 | 检查是否按了 Key10 把 `viz_en` 关掉 |

### 7.2 `err_prompt` 错误码对照（供上板读数码管）

| 助记 | 含义 | 关联模块 |
|---|---|---|
| `C` | 卡（Card）相关：`sd_fail` / `sd_cd` | `sd_probe.v:93/:166` |
| `F` | 失败（Fail）：`gallery_fail` / `image_failed` | `gallery_probe.v:454`；`image_player.v:362/:386/:388/:394/:434` |
| `0` | 无错误 / 计数 | — |
| `b` | 块（Block）读错误 | `sd_spi_ctrl.v:721`；`fat32_reader.v:296-333` |
| `d` | 数据（Data）错误 | `fat32_reader.v` 各 err_code |

**注意：`wav_stream_player.err_code` 在顶层是空连接（`:1017`），WAV 的失败原因（1..9）当前无法从数码管看到。** 这是 T2 建议要补的观测点。

---

## 8. 未验证项与风险（如实标注）

| 项 | 状态 | 说明 |
|---|---|---|
| HDMI 发射核对满幅 PCM 的容忍度 | **未验证** | `ip/local/hdmi/enc/*.enc.v` 是 Anlogic 加密核，内部不可读；`docs/hdmi_audio_2026-10-26.md` 未记录满幅规范。F5 取 `2` 是保守选择，取 `0` 需上板试听 |
| 显示器内建喇叭的实际灵敏度 | **假设值** | §2.3 用 80–85 dB SPL @ 0 dBFS @ 1 m 估算；实际因型号差异 ±10 dB。但即使取 95 dB SPL 仍低于底噪，结论不变 |
| `tone_gen` 三角波在长观测窗内的直流对称性 | **未验证** | 串联仿真 S1/S4 中 `audio_left` 全为负值（max < 0），说明观测窗内未覆盖正半周。不影响"波形塌陷"结论，但若要精确定量波形中心偏移需更长观测窗 |
| 顶层整体仿真 | **未跑** | 需 Anlogic 原语库 + `SDRAM_SIM_MODEL`，本次未执行 |
| `RES640/` 是否应含 WAV | **未验证** | 需产品侧确认 `RES640` 的定位（纯图片集 vs 完整素材集） |
| 现场卡的实际内容 | **只能用户自查** | §7 第 0 步 |
| 3.5mm 功放硬件是否正常 | **只能上板确认** | 需示波器看 F3 引脚 PWM 波形 |

---

## 9. 附：本次诊断的仿真产物与可复现命令

### 9.1 目录

```
D:\FPGA_Compelate\_diag_audio\        ← 仓库外（仓库根是 D:\FPGA_Compelate\SmartCampusMedia）
├── tb_name_order.v                    ← R1 字节序证明（audio_src_mux 的 8.3 常量）
├── tb_rle_name_order.v                ← gallery_probe RLE_NAME 字节序核对（证明是对的，撤销 F2）
├── tb_wave_amp_diag.v                 ← R5 静态幅度映射
├── tb_wave_real.v                     ← R5 真实素材驱动
├── tb_audio_chain_diag.v              ← R5 三级串联
├── bgm_mid.hex                        ← BGM.WAV 中段 4096 样本
├── work_name\  work_rle\  work_wave\  work_chain\ ← ModelSim 编译库
└── logs\                              ← 运行日志
```

### 9.2 复现命令

```powershell
cd D:\FPGA_Compelate\_diag_audio

# R1：audio_src_mux 的 8.3 常量字节序
vlib work_name
vlog -work work_name ..\SmartCampusMedia\rtl\audio\audio_src_mux.v `
     ..\SmartCampusMedia\rtl\storage\fat32_reader.v tb_name_order.v
vsim -c -quiet work_name.tb_name_order -do "run -all; quit -f"

# 撤销的 F2：gallery_probe 的 RLE_NAME 字节序（纯常量比对，不需 RTL）
vlib work_rle
vlog -work work_rle tb_rle_name_order.v
vsim -c -quiet work_rle.tb_rle_name_order -do "run -all; quit -f"

# F1 修复常量自校验（纯常量比对，不需 RTL）
vlib work_fix
vlog -work work_fix tb_fix_constants.v
vsim -c -quiet work_fix.tb_fix_constants -do "run -all; quit -f"

# R5：幅度映射
vlib work_wave
vlog -work work_wave ..\SmartCampusMedia\rtl\video\audio_waveform.v tb_wave_amp_diag.v
vsim -c -quiet work_wave.tb_wave_amp_diag -do "run -all; quit -f"

# R5：三级串联
vlib work_chain
vlog -work work_chain ..\SmartCampusMedia\rtl\audio\audio_tone_gen.v `
     ..\SmartCampusMedia\rtl\audio\vol_apply.v `
     ..\SmartCampusMedia\rtl\video\audio_waveform.v tb_audio_chain_diag.v
vsim -c -quiet work_chain.tb_audio_chain_diag -do "run -all; quit -f"
```

### 9.3 环境备注

- ModelSim ASE 10.1d 的 `vsim` **不支持 `-work` 选项**（报 `(vish-3296) Unknown option '-work'`），必须写成 `vsim -c -quiet work_xxx.tb_xxx`。
- 控制台 GBK 会把中文断言文字显示成 `???`，诊断 tb 一律用英文消息。
- `reports\` 目录在本会话**不可写**（`[sandbox: file access denied under workspace-write mode]`），但 `write` 工具可创建文件、不可删除。
  ⇒ 本报告由 `write` 工具创建；同目录下遗留一个 6 字节的 `reports\_probe_audio.md` 探针文件**无法删除**，请 captain 或后续有写权限的成员清理。

---

## 10. 一句话给 captain

**音频通路在所有模式下都是死的（不是应急特殊），有四层独立原因（R1 名字字节序 / R2 失败不重试 / R3 WAV 未左移 8 位 / R4 HDMI −38.99 dB 固定衰减），外加现场素材 R7 与 ST_FAIL 静音死锁 R6；波形不可见是完全独立的第五层原因 R5（`hist[23:8]` + `Y_SHIFT=10` 两级右移 = 256× 衰减，实测真实 16 bit 样本只剩 1 像素线）。修完 R1/R3/R4 后 3.5mm 与 HDMI 都能出声；但波形必须单独修 R5，否则永远不会出现。**
