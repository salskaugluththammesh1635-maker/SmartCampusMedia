# assets/v2 母版素材清单

> 本文件由 `scripts/gen_assets_v2_manifest.py` 自动生成，所有数值均为脚本从磁盘实测读取。
> 机器可读版本见同目录 [`MANIFEST.json`](MANIFEST.json)。

## 一、这套素材是干什么的

`assets/v2/masters/` 是**母版**：分辨率/时长都取到足够高，供 t4 阶段
派生五档分辨率素材包，而不是直接上板。上板产物落在 `assets/v2/derived/`
与 `assets/v2/sdcard/`。

```
assets/v2/
  masters/          <- 本清单描述的母版（t3 产出）
    images/         <- 6 张校园景点图
    audio/          <- 3 段 BGM + 1 段应急警报
    font/           <- 16x16 中文点阵数据
    video/          <- 旁白音轨 + 字幕 + 抽帧样张 + 带宽统计
  derived/          <- t4：五档分辨率素材包
  sdcard/           <- t4：SD 卡目录树
```

## 二、校园景点图（母版 1920×1440）

| 文件 | 场景 | 尺寸 | 大小 |
|---|---|---|---|
| `IMG001.png` | 智慧校园 / Smart Campus | 1920×1440 | 196,485 B |
| `IMG002.png` | 书香校园 / Scholarly Campus | 1920×1440 | 178,954 B |
| `IMG003.png` | 创客工坊 / Maker Workshop | 1920×1440 | 191,547 B |
| `IMG004.png` | 绿色校园 / Green Campus | 1920×1440 | 217,928 B |
| `IMG005.png` | 运动嘉年华 / Sports Carnival | 1920×1440 | 213,474 B |
| `IMG006.png` | 平安校园 / Safe Campus | 1920×1440 | 183,083 B |

**关键：这不是上采样。** 既有 `assets/campus_media/sd_card/IMG001..006.BMP`
只有 640×480，看似只能上采样；但本项目本来就有矢量绘制脚本
`scripts/generate_campus_media.py`（Pillow 几何绘制，逻辑坐标系 640×480）。
本任务保持逻辑坐标系不变，把**超采样倍数从 2 提到 6**，绘制后 LANCZOS
缩到 1920×1440 —— 得到的是**原生重渲染**，细节是画出来的，不是插值猜的。

证明同源的决定性证据：用原参数 + 原字体复现既有 640×480 成品，**6 张全部 `max|diff|=0`（逐像素完全一致）**。

`reference_upscaled/` 里的 6 张是**对照用**的上采样图（640×480 → 1920×1440），
**不是母版**。实测锐度（Laplacian 能量）：原生重渲染 3.257 vs 上采样 1.415，
比值 2.30×。

### 已知差异（有意为之，如实记录）

母版字体用 Noto Sans SC，与既有 BMP 使用的等线粗体不同，
文字笔画边缘差异像素（>24/255）占比 **3.28%–4.42%**，几何图形完全一致。
这是为了规避微软雅黑/黑体/等线的**专有字体授权风险**而做的取舍。

## 三、音频（48 kHz / 16 bit / 单声道）

| 文件 | 用途 | 时长 | 大小 | 循环 |
|---|---|---|---|---|
| `alarm_siren.wav` | 应急模式报警音（AHT20 高温联动/应急提示） | 6.00 s | 576,044 B | 是 |
| `bgm_focus.wav` | 科普模式背景音乐（讲解/字幕演示） | 48.00 s | 4,608,044 B | 是 |
| `bgm_serene.wav` | 日常模式背景音乐（开机/图库浏览） | 40.00 s | 3,840,044 B | 是 |
| `bgm_uplift.wav` | 科普/日常切换过渡背景音乐 | 36.00 s | 3,456,044 B | 是 |

**授权：全部为 numpy 程序化合成，无第三方版权。** 未使用任何采样、
音源库或现成音乐片段。合成方式：分解和弦 pad（3 个微失谐正弦产生
chorus）+ 一阶 RC 低通滤波 + ADSR 包络 + 淡入淡出。

### 循环建议（日常模式要循环播放）

- **`alarm_siren.wav`**：**必须循环**：单段仅 6.00 s，应急持续报警需 RTL 端整段循环播放。段内为整数个周期（14 个 0.42 s 段），循环点无相位跳变，可直接循环无需 crossfade
- **`bgm_focus.wav`**：同 bgm_serene：整段循环，首尾淡入淡出
- **`bgm_serene.wav`**：整段无缝循环：首尾各 1.2 s 淡入/淡出，循环播放时建议 crossfade 200 ms 或整段重播（淡入淡出保证无爆音）
- **`bgm_uplift.wav`**：同 bgm_serene：整段循环，首尾淡入淡出

### 实测声学参数（MANIFEST 中逐项记录）

| 文件 | peak | rms | 主频 | 敏感带 300–4 kHz |
|---|---|---|---|---|
| `alarm_siren.wav` | -2.98 dBFS | -6.67 dBFS | 756.0 Hz | 99.9% |
| `bgm_focus.wav` | -4.31 dBFS | -15.46 dBFS | 220.0 Hz | 15.6% |
| `bgm_serene.wav` | -4.31 dBFS | -15.3 dBFS | 261.6 Hz | 17.1% |
| `bgm_uplift.wav` | -4.31 dBFS | -15.57 dBFS | 73.4 Hz | 23.2% |

siren 敏感带占比 99.9%（警报能量集中于人耳最敏感频段，响度效率高）；
BGM 敏感带占比低（能量分布在全频段，作垫底音乐不抢旁白）。

> 口径说明：主频 = **整段文件 FFT 的峰值 bin**（附录常是某一和弦的根音或低音声部，如 serene 261.6=C4、uplift 73.4=D2 低音声部）。`gen_assets_v2_audio.py` 自检输出的是分段分析口径，两者都是真实测量，差异来自分析窗口不同，不是数据矛盾。

## 四、16×16 中文点阵字库

| 文件 | 说明 | 大小 |
|---|---|---|
| `cjk16_bitmap.hex` | 纯文本点阵（每行 4 位十六进制，可直接 $readmemh） | 37,200 B |
| `cjk16_bitmap.json` | 带元数据的完整点阵（字符/码位/每行位图/墨点统计） | 163,605 B |
| `cjk16_charset.txt` | 索引 ↔ 字符 ↔ 码位对照表 | 16,809 B |
| `cjk16_font.v` | Verilog case 表 ROM（工程惯例，TD 推断 ROM 更稳） | 317,543 B |
| `cjk16_preview.png` | PNG | 72,835 B |

覆盖 **465 个字形**（汉字 + 全角标点 + ℃/% + 数字 + 字幕里出现的半角字母符号），
每字 16 行 × 16 bit，**bit15 = 最左像素**，索引 = `{glyph_index, row}`。

### 索引冻结（重要，改字库前先读这段）

**索引 0..94 这 95 个字形是冻结段**，任何时候都不得重排或删除，新增字符只能从索引 95 往后追加。

原因是 RTL 会以 index 硬引用字库（`cjk16_font u_font (.glyph(idx), ...)`）。`cjk16_bitmap.hex` 的地址 = `index * 16 + row`，一旦重排，所有已写好的
索引常量全部指向错的字形 —— **屏幕会静默显示错字**：不报错、不变红、不崩溃，
只是字不对。这是最难定位的一类故障，所以宁可用冗余列表把前 95 字冻死。

新增部分按 **Unicode 码位升序**排列（便于人工查阅，且同批新增的索引稳定）。

### 字形覆盖是怎么定下来的（不是拍脑袋凑数）

不手工罗列汉字，而是**从磁盘上的真实文本反推并集**，每跑一次脚本就重新求一次：

| 需求来源 | 路径 | 用途 |
|---|---|---|
| 科普模式旁白字幕 | `assets/v2/sdcard/COMMON/SRT/NARR.SRT` | 18 条旁白全文 |
| 6 张校园图的滚动文案 | `assets/v2/masters/text/campus_ticker.txt` | 每图一段中文介绍 |
| 应急模式提示文案 | `assets/v2/masters/text/emergency_ticker.txt` | 消防通道疏散提示 |
| UI 固定文案 | `assets/v2/masters/text/ui_strings.txt` | 模式/参数/档位/单位 |
| OSD 短语表 | 脚本内 `OSD_PHRASES` | 冻结段来源 |

这样字库里每个字都对应屏幕上真实会出现的一处文本，不会白占 ROM；反过来，**改了文案却没重跑字库脚本 → 缺字 → 屏幕方块**，因此生成脚本自带覆盖率自检，缺一个字就判失败。

### 中文文案（同时供 OSD 滚动字幕与字库覆盖使用）

`assets/v2/masters/text/` 下三份文案，均为 **UTF-8 + LF**，与渲染出的字形一一对应：

- `campus_ticker.txt` —— 6 行，每行对应 `IMG001`~`IMG006` 的校园介绍滚动字幕，内容贴合各自画面（校门晨光 / 图书馆长窗与摊开的书 / 创客工坊芯片走线 / 风机与光伏板 / 看台与跑道 / 夜巡灯柱）
- `emergency_ticker.txt` —— 3 行应急模式消防通道提示，轮播
- `ui_strings.txt` —— UI 固定文案（模式名、参数名、档位、单位、状态词）

**降级说明**：`assets/v2/sdcard/COMMON/TICKER.TXT` 受 FAT32 8.3 短名 + 现有 `osd_strings.v` 纯 ASCII 字模限制，仍是 64 字节英文；中文滚动字幕要等 RTL 侧接入本字库（见 `SDCARD_LAYOUT.md` §11）。

`cjk16_font.v` 是 Verilog case 表 ROM，可直接接入 RTL；
**本任务只产出数据，不写 RTL**（接线由 t5/t6/t7 决定）。

### 字形来源与授权（答辩要点）

栅格化自 **Noto Sans SC Regular**（SIL Open Font License 1.1）。
**刻意不用微软雅黑(msyh)/黑体(simhei)/等线(Deng)** —— 这三者是微软专有
字体，随工程分发其点阵有授权风险。授权全文见 `docs/OFL-NotoSansSC.txt`，
说明见 `docs/science_font_attribution.md`。**只分发点阵数据，不分发字体文件。**

### 字重是逐档比出来的，不是随手取的

`NotoSansSC-VF.ttf` 是**可变字体**，默认实例是 **Thin (weight 100)**，
直接加载会得到 1px 细线，汉字骨架断裂。以笔画最密集的「幕 播 慧 智 园 模」
六字在 16×16 下比对墨点数：

| 字重 | 墨点数 | 观察 |
|---|---|---|
| Thin | 69~ | 骨架断裂，不可辨 |
| **Regular** | **83~105** | **结构清晰、有留白，可辨** ✓ |
| Medium | 102~121 | 偏重，部分横画开始并笔 |
| Bold | 131~146 | 糊连：「幕」顶部成实心横条 |

（该字体可用的命名实例只有 Thin/Light/Regular/Medium/Bold/Black，**没有 SemiBold**。）

## 五、视频相关

### 旁白音轨与字幕

- `narration.wav`：1ch / 16bit / 48000Hz / 6,053,100 帧 / 126.10625 s
  - 无需重采样（源已是 48kHz/16bit/单声道），原样复制
- `narration.srt`：18 条字幕，5 项校验全过（单调递增 / 无重叠 / end>start / 不超音频时长 / 文本非空）

### 带宽预算（t4 与架构的选型依据）

**前提：未压缩帧。** 源视频 640×480、60 fps、126.104 s、7,566 帧。

| 色深 | 单帧字节 | 1 fps | 5 fps | 30 fps | SDRAM 可存帧 |
|---|---|---|---|---|---|
| RGB888 | 921,600 B | 0.92 MB/s ✓ | 4.61 MB/s | 27.65 MB/s | 9 |
| RGB565 | 614,400 B | 0.61 MB/s ✓ | 3.07 MB/s | 18.43 MB/s | 13 |
| RGB332 | 307,200 B | 0.31 MB/s ✓ | 1.54 MB/s | 9.22 MB/s | 27 |

SD SPI 实用带宽按 **1.25 MB/s** 计。15 个「色深×帧率」组合里只有 3 个
落在带宽内，**全部是 1 fps** —— 640×480 未压缩全帧视频从 SD 卡播放不可行。

**RLE 游程压缩后（RGB565 量化，每秒抽 1 帧共 127 帧）**：

| 编码 | 每条目 | 均值 | 最小 | 最大 | p95 |
|---|---|---|---|---|---|
| rle8 | 3 B | 129,963 B | 3,600 B | 202,452 B | 194,024 B |
| rle16 | 4 B | 173,057 B | 20 B | 269,868 B | 258,636 B |

RLE 3 B/条目 的带宽账（vs SD SPI 1.25 MB/s）：

- @1 fps：均值 0.130 MB/s，最坏 0.202 MB/s ✓
- @2 fps：均值 0.260 MB/s，最坏 0.405 MB/s ✓
- @5 fps：均值 0.650 MB/s，最坏 1.012 MB/s ✓
- @8 fps：均值 1.040 MB/s，最坏 1.620 MB/s ✗

**结论：** 未压缩不可行（最高 1 fps）；引入 RLE 后 **5 fps 可用**
（均值 0.650 MB/s = SD 带宽 52%，最坏 1.012 MB/s = 81%）。
两张表**前提不同、不矛盾**：先算未压缩发现不可行，再用 RLE 提升 5 倍。

### 抽帧样张

`video/frames/` 下 7 张 PNG 样张，覆盖片头/正文/结尾，供看画面风格与色深。
**未导出整套帧序列**——那要等 `PLAN.md` 锁定帧率与色深，由 t4 按 PLAN 导出。

> 源 mp4 为 H.264 压缩，**FPGA 无解码能力**，不可作 SD 卡播放源，
> 只能作素材预览与答辩展示。

## 六、缺项与降级（如实记录）

### 校园图母版

**未使用上采样**。既有 IMG001..006.BMP 只有 640x480，但本项目有矢量绘制脚本 generate_campus_media.py，故以 6x 超采样原生重渲染得到 1920x1440，并由 verify_legacy_reproduction 逐像素复现既有 640x480 成品（6 张全部 max|diff|=0）证明二者同源。

**影响：** 无降级

### 应急音频 TTS 语音

**未附 TTS 语音**。本机 SAPI 不可用（System.Speech GetInstalledVoices() 抛 'Object reference not set to an instance of an object.'），且本任务禁用 ffmpeg、无网络，故应急音频只做纯双音 siren。

**影响：** 应急模式无语音播报，只有警报音；如需语音须在联网环境另行合成

### narration.wav 重采样

源文件已是 48kHz/16bit/单声道，**无需重采样**，已原样复制。脚本如实记录 action 字段，未假装执行过重采样。

**影响：** 无降级

### 视频播放

t3 **只做抽帧统计与样张，未导出整套帧序列**（等 t2 PLAN.md 锁定帧率/色深，由 t4 导出）。源 mp4 为 H.264 压缩，FPGA 无解码能力，**不可作为 SD 卡播放源**。

**影响：** 视频播放能力取决于 t4 导出的帧序列 + RLE 解码器

### 中文滚动字幕（OSD TICKER）

`assets/v2/sdcard/COMMON/TICKER.TXT` 目前仍是 **64 字节纯 ASCII 英文**（`SMART CAMPUS MEDIA - WELCOME - DAILY MODE ONLINE`）。原因是现有 `rtl/osd/osd_strings.v` 的字模只有 8x16 英文/数字 41 字符，且 TICKER 按 `col = (像素列 + 滚动偏移) & 6'b111111` 取 64 列，**64 = 2^6 是零逻辑成本的设计，改长度要动 RTL**。本目录的 16x16 中文字库（含 6 段贴合画面的校园介绍文案）已经准备好，但要等 RTL 侧把 TICKER 从 `osd_strings.v` 切到 `cjk16_font.v` 才能上屏。

**影响：** 中文滚动字幕**已备好文案与字形，暂未上屏**；当前屏幕上滚动的仍是英文标语

## 七、版权声明

- **images**：程序化绘制（generate_campus_media.py），无第三方图像素材
- **audio**：全部 numpy 程序化合成，未使用任何采样/音源库，无第三方版权
- **font_data**：点阵栅格化自 Noto Sans SC（SIL OFL 1.1），只分发点阵数据不分发字体文件；刻意规避微软雅黑/黑体/等线（专有字体）
- **narration**：本项目原创讲稿；语音由 edge_tts 合成
- **video_source**：H.264 视频由本项目脚本生成，仅作素材预览与统计来源

**全部素材无第三方版权风险**

## 八、可复现性

每个母版都有对应的生成脚本，重复运行产出相同结果（固定随机种子）：

| 脚本 | 产出 |
|---|---|
| `scripts/gen_assets_v2_images.py` | 6 张校园图母版 + 基准版 + 上采样对照 |
| `scripts/gen_assets_v2_audio.py` | 3 段 BGM + 1 段应急警报 |
| `scripts/gen_assets_v2_font.py` | 16×16 中文点阵（.v/.hex/.json/preview） |
| `scripts/gen_assets_v2_video.py` | 旁白音轨 + 字幕 + 抽帧样张 + 带宽统计 |
| `scripts/gen_assets_v2_manifest.py` | 本文件与 MANIFEST.json |

每个脚本都带**自检**（用 Pillow/wave/cv2/json 重新打开产物并打印校验结果），
运行时会打印 `[自检] 全部通过`。

