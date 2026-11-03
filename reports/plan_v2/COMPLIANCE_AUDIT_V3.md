# 合规终审 v3 —— 文档/RTL 偏差定性、锁存风险与外设能力口径

> **产出**：任务 t29（t10 合规终审第 2 轮，合并已作废的 t10 重复卡）｜作者 spec-auditor｜扫描时刻 **2026-11-03 09:15（UTC+08:00）**
> **纪律声明**：本报告**只读** RTL 与既有文档，**只新增本文件**；未改动任何 `.v` / `.adc` / `.sdc` / `.tcl` / `.ps1`，未改动任何既有 `.md`，未运行 TD 综合。
> **行号口径**：全部用 `io.open(encoding='utf-8')` 逐行读取计数（等价于 `ReadAllLines(...,UTF8)`）。**禁用 `Get-Content`** —— 本仓 `docs/plan_v2` 有 7 份无 BOM 文件，按 GBK 解码会吞换行（`KEY9_RULING.md` 实测差 67 行）。
> **分母口径**：本报告所有「扫描型结论」一律给出分母与阳性对照。分母 = `docs/plan_v2/*.md` **18 份**、`reports/plan_v2/*.md` **22 份**、`rtl/**/*.v` **67 个**（递归含 `rtl/video/hdmi/` 子目录 5 个）。
> **版本声明**：凡引用源码行号，均在附录 A 列出该文件在本次扫描时刻的字节数/行数/MD5/mtime。RTL 仍在滚动修订，**行号必须连同附录 A 的快照一起引用**。

---

## 0. 摘要

### 0.1 四条偏差的定性结论（定性只取四词之一：虚构需求来源 / 设计目标未落地 / 表述与实现不符 / 文档自相矛盾）

| # | 偏差 | 定性 | 严重度 | 一句话 |
|---|---|---|---|---|
| 1a | 视频「保底 2 fps」被写成**用户拍板** | **虚构需求来源** | 🔴 高 | 用户从未说过 2 fps；该数字是带宽核算得出的保守工况，却被写成用户选择 |
| 1b | 视频「持续欠载**自动降到 2 fps**」 | **设计目标未落地** | 🔴 高 | RTL 里没有任何降帧逻辑；`play_fps` 顶层硬接 `8'd5`，`rle_underrun` 零消费者 |
| 2 | SD 卡「**也接受 FAT16 小卡**」 | **表述与实现不符** | 🟠 中 | RTL 判据要求 `root_entries == 0 && fat16_size == 0`，FAT16 必判 BPB 非法 |
| 3 | `KEYMAP.md` v1 旧键表与同文件 v2 新表**并存且结论相反** | **文档自相矛盾** | 🟠 中 | 同文件 `:44`「16 个键位全部占用」vs `:405`「Key11~Key15 为 P2 备用」 |
| 4 | Key9 被写成「**等比缩小**」 | **表述与实现不符** | 🟠 中 | 横向是等比压缩、纵向是 1:1 裁剪，合起来不是等比缩小 |

> **与 t11 的关系**：这四条**已由 t11 逐条登记**在 `D:\FPGA_Compelate\docs\plan_v2\DELIVERY_GUIDE.md` §6b（`:516-529`），状态一律为「🕓 待 t10 改」。本报告的增量是**定性 + 处置文本 + 复核是否已改（结论：四条全部未改）**，不是重新发现。

### 0.2 三消费者锁存风险结论

| 消费者 | 三根卷参数是否锁存 | 判定 |
|---|---|---|
| `rtl/storage/gallery_probe.v` | **已锁**（`rle_lba` / `rle_size` 在 `f32_found` 时打拍） | 低危 |
| `rtl/storage/img_loader.v` | **裸线**，但靠 `blk_owner` 总线归属保护 | 低危 |
| `rtl/audio/wav_stream_player.v` | **裸线**（`data_begin`/`fat_begin`/`spc`），仅 `spc_shift` 半锁 | 低危 |

> **不采信「采到 0」这一假设**：`fat32_reader.v` 的三个输出端口**在 `start` 时不会被清 0**（详见 §2.2 逐行证据）。真正的风险面是「换一张**格式不同**的卡」，而本工程无运行中热插拔，见 §2.4。

### 0.3 能力高估扫描结论

| 核查项 | 结论 |
|---|---|
| Key8「输出分辨率可切换」 | **不存在该表述**（`输出分辨率`/`分辨率可切换`/`切分辨率` 在 docs 各 0 行；Key8 只驱动 `pix_mosaic.src_w`） |
| 视频「60 fps / 60Hz 能力」 | **不存在能力高估**（`60fps` 在 docs 3 行全部是被否决的 P2 方案回顾；`60Hz` 3 行在 RTL 全部指 HDMI 输出时序） |
| Key9「等比缩小」 | 已定性为**表述与实现不符**，残留 34 行有 12 行属合规引用/无关项，真需改 8 行（§1.4）；**另发现一处结论相反**：`T7_INTEGRATION_PLAN.md:2017-2034`「可行且便宜、零 BRAM、+40~70 LUT」 vs `KEY9_RULING.md §2`「267 块 BRAM 物理上限、做不成」（§1.4 末，已判以 `KEY9_RULING.md` 为准） |
| 「实时 XX」 | docs 22 行 + reports 27 行 + rtl 2 行，**逐条判读后无一条把「配置时算一次」冒充「每帧都算」**（§3.4） |

---

## 1. 四条文档/RTL 偏差逐条定性

### 1.1 视频「保底 2 fps / 自动降级」

#### 1.1.a 把 2 fps 归因给用户 —— 定性：**虚构需求来源**

**文档原文（逐字）**

- `D:\FPGA_Compelate\docs\plan_v2\ARCH.md:1195`（1,295 行快照）：
  > **用户已拍板**（队长裁决 B，决策 1）：用户选择「P1 序列帧：640×480 但只有 2fps（稳妥）」。队长后续实测 RLE 后把目标提升到 5 fps，保底仍为 2 fps。
- `D:\FPGA_Compelate\docs\plan_v2\PLAN.md:420`（927 行快照）：
  > 用户已拍板（队长裁决 B 决策 1）：用户选择「P1 序列帧：640×480 但只有 2fps（稳妥）」。队长后续实测 RLE 后把目标提升到 5 fps，**保底仍为 2 fps**。

**需求来源核查**

| 核查 | 结果 | 分母/阳性对照 |
|---|---|---|
| 用户原话是否逐字落档（`640*480P` / `640×480P`） | **0 行 / 0 文件** | 分母：全仓 `.md`/`.txt` 递归（跳过 `node_modules` / `.git` / `__pycache__` / `.agent-teams` / `work`）。阳性对照：同一次遍历扫 `640×480` 在 `docs/` 命中 **104 行** → 遍历与解码均正常 |
| 「2 fps 是用户选的」这一说法的最早出处 | 仅 `ARCH.md:1195` 与 `PLAN.md:420` 两处，措辞几乎逐字相同 | 分母：`docs/plan_v2` 18 份；`reports/plan_v2` 22 份 |

**用户侧的原始需求（captain 消息转述，非本仓文档）**：「播放 SD 卡中存储的 640*480P 60Hz 的 FPGA 介绍视频」——其中**没有**任何帧率下限、也没有「稳妥」取舍。2 fps 是「SD SPI 实测 1.25 MB/s ÷ (640×480×2 B × RLE 比 0.206)」算出来的**保守工况**，属工程推导，不属用户输入。

**定性**：**虚构需求来源**。这是四条偏差里唯一一条「不是写错功能，而是写错来源」的问题 —— 危害在于答辩时会被当作「用户需求」引用，一旦评委追问「用户为什么选 2 fps」，无法回答。

**处置**

1. `ARCH.md:1195`、`PLAN.md:420` 两句**删除「用户已拍板」前缀**，改为：
   > 2 fps 是**按 SD SPI 带宽核算得出的保守工况**（1.25 MB/s ÷ 单帧 RLE 后 0.606 MB ≈ 2 帧/秒），**不是用户需求**；用户只要求「能播放 SD 卡里的 640×480 介绍视频」。
2. `ARCH.md:1193`、`PLAN.md:25`、`PLAN.md:418` 的「5 fps 目标 / 2 fps 保底」改为「**固定 5 fps；欠载时保持上一帧**」（见 1.1.b）。
3. 答辩材料里凡出现「2 fps」的地方，一律改称「**带宽核算的保守工况**」。

#### 1.1.b 「持续欠载自动降到 2 fps」—— 定性：**设计目标未落地**

**文档原文（逐字）**

| 位置 | 原文 |
|---|---|
| `ARCH.md:538` | `input  wire [7:0]  play_fps,          // 5（目标）/ 2（保底）` |
| `ARCH.md:567` | 「**降级策略**：若连续 3 帧 `underrun`，`play_fps` 从 5 自动降到 2（由上层 `mode_ctrl` 或专用自适应逻辑控制，**不降分辨率**）。」 |
| `ARCH.md:1244` | 「**@5fps 是设计目标，不是承诺。** … 系统会**自动降到 2 fps** … **2 fps 是承诺下限。**」 |
| `ARCH.md:1284` | 自查表：「视频路线是否可落地 \| 是。§11 给出 P1（RLE@5fps 目标/2fps 保底）+ 三层缓冲策略 + P2 记录」 |
| `PLAN.md:25` | 「**视频播放** \| **640×480 RGB565 + RLE 游程压缩，5 fps 目标 / 2 fps 保底**（SD SPI 带宽物理上限）」 |
| `PLAN.md:74` | 「…经 RLE 游程压缩（素材压缩比 0.206）后可达 **5 fps（目标）/ 2 fps（保底）**…」 |
| `PLAN.md:474` | 「③ 自动降帧率 \| 连续 3 帧 `underrun` → `play_fps` 从 5 降到 2 \| **不降分辨率**」 |
| `PLAN.md:477` | 「系统会**自动降到 2 fps** … **2 fps 是承诺下限。**」 |
| `PLAN.md:892` | 风险表 R-02「5 fps 视频实测欠载 \| … \| 三层缓冲；自动降 2 fps；**2 fps 是承诺下限**」 |
| `PLAN.md:897` | 风险表 R-07「…自动降帧率 5→2 fps；上板用官方推荐卡测试」 |
| `reports/plan_v2/T10_AUDIT_CHECKLIST.md:113` | C5 判据「5fps 目标 / 2fps 保底…连续 3 帧 underrun 自动 5fps→2fps」 |
| `reports/plan_v2/REQ_GAP.md:242` | 同上口径 |

**RTL 真值（逐条）**

| 证据 | 内容 | 说明 |
|---|---|---|
| `rtl/top/dmz_eg4s20_hdmi_top.v:521` | `.play_en(rle_play_en), .play_fps(8'd5),  // 视频 5 fps（用户规格）` | **常量硬接**，无任何自适应 |
| `rtl/storage/rle_decoder.v:177` | `input  wire [7:0]  play_fps,    // target frame rate, 0 is treated as 1` | 只有输入端口 |
| `rtl/storage/rle_decoder.v:282` | `wire [7:0]  fps_eff   = (play_fps == 8'd0) ? 8'd1 : play_fps;` | 唯一的「改帧率」逻辑：把 0 当 1，**不是降级** |
| 全仓 `play_fps` 命中 | **5 行 / 2 文件**（分母 67 个 .v） | 另 2 行是 `rle_decoder.v:93`/`:94` 的仿真加速说明注释 |
| `rle_underrun` 命中 | **2 行 / 1 文件**：`dmz_eg4s20_hdmi_top.v:511` 声明、`:528` 端口连接 | **零逻辑** —— 该信号从未出现在任何 `if` / `assign` 右侧 |
| `rtl/storage/rle_decoder.v:25-31` | 「…**underrun keeps the previous frame: no done -> no commit -> no flip**」 | RTL 的**实际**欠载行为：保持上一帧 |
| 连续 3 帧计数逻辑 | `grep` 无 `underrun_cnt` / `slow_fps` / `fps_sel` 一类信号 | 不存在 |

**定性**：**设计目标未落地**。「自动降到 2 fps」是一个**写在 12 处文档里、被列为验收判据、被写进风险表，但 RTL 里一行都没有**的功能。

**用户可见后果**：欠载时画面**停在上一帧**（不黑屏、不报错、不降帧），与文档承诺的「自动降帧但流畅」不同。这一条 `DELIVERY_GUIDE.md:348` 已按实况写成「**没有自动降帧机制**，欠载时画面停在上一帧。**这不是「缺陷」，是「设计目标未落地」**」，可直接引用。

**处置**

1. 12 处文档统一改为：「**固定 5 fps；欠载时保持上一帧（整帧原子性，不撕裂、不黑屏）**。『自动降 2 fps』是设计阶段的备选方案，**未实现**。」
2. 「2 fps 是承诺下限」整句删除（它同时是 1.1.a 的载体）。
3. `T10_AUDIT_CHECKLIST.md:113` 的 C5 判据改为「顶层 `play_fps` 恒 `8'd5`；`rle_underrun` 允许零消费者（保持上一帧由 `rle_decoder` 内部保证）」。
4. `PLAN.md:892` R-02 与 `PLAN.md:897` R-07 的缓解措施改为「三层缓冲 + 整帧原子性（欠载保持上一帧）」。
5. 若答辩要保留「2 fps」这个数字，只能作为**带宽核算工况**出现（§1.1.a 处置第 3 条）。

### 1.2 SD 卡「也接受 FAT16 小卡」 —— 定性：**表述与实现不符**

**文档原文（逐字）**

`D:\FPGA_Compelate\SmartCampusMedia\assets\v2\SDCARD_LAYOUT.md:13`（361 行快照）：
> | 文件系统 | **FAT32**（也接受 FAT16 小卡）。`fat32_reader.v` 解析 MBR → VBR → 根目录，要求 `root_cluster >= 2`、`root_entries == 0`、`fat16_size == 0`（这几个判据用于区分「直接 FAT32 VBR」与「MBR 引导扇区」） | `rtl/storage/fat32_reader.v` L195-201 |

**RTL 真值**

`D:\FPGA_Compelate\SmartCampusMedia\rtl\storage\fat32_reader.v:241-248`（714 行快照）：
```
    // A 55AA signature alone does not distinguish MBR from VBR. Require a
    // consistent 512-byte FAT32 BPB before accepting a volume at card LBA 0.
    assign sector0_is_fat32 = bytes_per_sec == 16'd512 &&
                             root_entries == 16'd0 && fat16_size == 16'd0 &&
                             reserved_s != 16'd0 && fat_size != 32'd0 &&
                             (num_fats == 8'd1 || num_fats == 8'd2) &&
                             spc != 8'd0 && (spc & (spc - 8'd1)) == 8'd0 &&
                             root_cluster >= 32'd2 && root_cluster <= 32'h0FFF_FFEF;
```

**判定链**：FAT16 卷的 BPB 里 `root_entries` 是固定的 512（`0x0200`），`fat16_size` 非 0 → `sector0_is_fat32` 恒 0 → 判「不是合法 FAT32 引导扇区」→ `err_code = 2`。**FAT16 卡不是「小卡也能用」，而是「插进去就报错 2」**。

**附带的行号漂移**：文档引的 `fat32_reader.v L195-201` 是**旧行号**，现为 `:243-248`（同文件在 t26 之后从 673 行长到 714 行）。

**定性**：**表述与实现不符**（不是 RTL 缺功能，是文档多写了能力）。

**处置**：**删掉文档那句，不要反过来让 RTL 支持 FAT16**。

1. `SDCARD_LAYOUT.md:13` 改为：
   > | 文件系统 | **仅 FAT32**。`fat32_reader.v` 解析 MBR → VBR → 根目录，要求 `root_cluster >= 2`、`root_entries == 0`、`fat16_size == 0`（这几个判据用于区分「直接 FAT32 VBR」与「MBR 引导扇区」）。**FAT16 / exFAT 一律不支持：FAT16 的 `root_entries` 恒为 512，会判 BPB 非法并报 `err_code = 2`** | `rtl/storage/fat32_reader.v:243-248` |
2. 同文件 `:225`（格式化指引）已是「只写 FAT32」，无需改；`:282`「FAT32 根目录无项数上限（与 FAT16 的 512 项固定根区不同）」是**正确的对比说明**，保留。
3. **路径提醒**：该文件在 `D:\FPGA_Compelate\SmartCampusMedia\assets\v2\`，**不在** `D:\FPGA_Compelate\assets\`（后者不存在）。它不属于 `docs/plan_v2` 定稿域，归属需 captain 裁定（见 §5 第 5 条）。
4. 已由 t11 在 `DELIVERY_GUIDE.md:69`/`:73`/`:74`/`:550` 按 RTL 写成「只能 FAT32」，其中 `:74` 明写「⚠️ `assets/v2/SDCARD_LAYOUT.md` §2 写的『也接受 FAT16 小卡』是错的」。**该告警仍在生效，原句未改。**

### 1.3 `KEYMAP.md` v1 旧键表与 v2 新表自相矛盾 —— 定性：**文档自相矛盾**

**同文件两处结论相反（逐字）**

- `D:\FPGA_Compelate\docs\plan_v2\KEYMAP.md:21`：`## 1. 现行键位（v1，2026-10-26 版，即将废弃）`
- `:23`：`来源：docs/keymap_2026-10-26.md 行 28–42，逐条与 RTL 核对后的实况表。`
- `:25-42`：16 行 v1 表（`:27` KEY0 上一张 / `:28` KEY1 下一张 / `:29` KEY2 自动轮播 开/关 `auto_play_en` / `:30` KEY3 模式循环含应急 `mode[1:0]` / `:31` KEY4 上一测试图案 / `:32` KEY5 下一测试图案 / `:33` KEY6 音频静音 `audio_muted` / `:34` KEY7 亮度循环（5 档 0~4）`bright_sel[2:0]` / `:35` KEY8 反色 / `:36` KEY9 轮播倍率循环 / `:37` KEY10 图库重扫 / `:38` KEY11 九宫格 / `:39` KEY12 信息条 OSD / `:40` KEY13 音频图层 4 态 / `:41` KEY14 蜂鸣器静音 / `:42` KEY15 应急直达）
- `:44`：`**注**：… v1 的 16 个键位全部占用，无空闲键。`
- 对照 `:48`：`## 2. 新版键位（v2，本文件生效）`；`:50-64` §2.1 主功能表；`:66` §2.2 备用键 Key11~Key15
- `:401`：`## 10. 无悬空项声明`；`:405`：`| 16 个键是否全部有归属 | 是。Key0~Key10 为 P0 主功能，Key11~Key15 为 P2 备用并已登记保留用途 |`

**矛盾点**：`:44`「16 个键位全部占用，无空闲键」 vs `:405`「Key11~Key15 为 P2 备用」。同一份文件、同一件事、两个相反结论。`:21` 的「即将废弃」标题**不足以免责** —— `:25-42` 仍是一张**格式完整、无「勿引用 / 已作废」强制标注**的可操作表格，读者照着操作会全部按错（14/16 键语义已变）。

**RTL 真值**：`rtl/control/key_router.v:116-127` 十四个 `localparam` —— `K_MODE=4'd2`、`K_EMERG=4'd3`、`K_AUDIO=4'd4`、`K_TICKER=4'd5`、`K_BRIGHT=4'd6`、`K_VOL=4'd7`、`K_RES=4'd8`、`K_RATIO=4'd9`、`K_VIZ=4'd10`、`K_RESCAN=4'd11`、`K_PATTERN=4'd12`、`K_INVERT=4'd13`、`K_GRID=4'd14`、`K_BEEP=4'd15`。另有 `mode_ctrl.v` 的 `K_MODE=2`/`K_EMERG=3` 与 `player_ctrl.v` 的 `K_PREV=0`/`K_NEXT=1`（后两者与 v2 一致）。

**定性**：**文档自相矛盾**。跨文件不一致尚可用「以某文件为准」兜底；**同一文件前后矛盾无法兜底**，且矛盾的两处都是「结论句」而非过程描述。

**处置**

1. `KEYMAP.md:21` 标题改为 `## 1. 【已作废，仅供追溯】v1 键位（2026-10-26 版）`。
2. `:24` 前插入强制块：
   > > ⛔ **本节整表已作废，不得作为操作或评审依据。** v2 唯一权威是 §2 与 §8。保留本节只为回答「v1 是什么」这类历史提问。
3. `:44` 末句改为：「v1 的 16 个键位全部占用，无空闲键；**v2 起 Key11~Key15 改为 P2 备用**（见 §2.2 与 §10）—— 因此『全部占满』这一前提在 v2 已不存在。」
4. `reports/plan_v2/V1_RESIDUE_SWEEP.md` 的 C-07 条已把本节判为「③ 保留（有 v1/v2 标注）」，**本报告上调为需要补强制标注**：保留表格没错，但必须加「不得引用」的强标记，否则与 `:405` 的矛盾无法消解。
5. 同型问题在 `reports/plan_v2/REQ_GAP.md:19`/`:303`/`:304`（仍写「仅改 `key_action.v` 的译码表」）与 `docs/plan_v2/T7_INTEGRATION_PLAN.md:199`/`:580`/`:611`/`:662`/`:737`/`:738`/`:1194`（仍描述顶层在用 `u_kact`）也存在，属 **arch-lead 域**，见 §5 第 2 条。

### 1.4 Key9 被写成「等比缩小」 —— 定性：**表述与实现不符**

**终口径（`KEY9_RULING.md:15-19`，逐字）**
> Key9 提供五档显示区域：1/2、5/8、3/4、7/8、1（边长比），对应窗口 320×240 / 400×300 / 480×360 / 560×420 / 640×480。**输出恒为 640×480**，完整画面在窗口内显示，窗口外填黑。横向：在 `pix_reader` 做**消费侧降采样**（每字 2 像素，取偶列），是**等比压缩**。纵向：**1:1 裁剪**（不跳行），非满屏档为「横向压缩 + 纵向裁剪」，**不是等比缩小**。这个取舍是资源约束下的**主动选择**，不是缺陷。

**残留扫描（六词 union 口径：`等比缩小` / `垂直跳行` / `待完成` / `进行中` / `没做完` / `后续会补上`，另加 `第 2 步`）**

| 文件 | 行数 | 行号 | 分类 |
|---|---|---|---|
| `BOARD_ACCEPTANCE.md` | 5 | `:51` `:57` `:62` `:63` `:155` | ✅ 合规引用（禁令句 / 正确表述） |
| `DELIVERY_GUIDE.md` | 4 | `:333` `:396` `:525` `:551` | ✅ 合规引用（终口径引用 / 应答话术 / §6b 台账 / 自查表） |
| `KEY9_RULING.md` | 4 | `:18` `:122` `:126` `:131` | ✅ 本卡本体，不改 |
| `LUT_CUT_PLAN.md` | 1 | `:288` | ⚠️ 低危（历史卡名交叉引用「t22（Key9 垂直跳行）」） |
| `RESOURCE_BUDGET.md` | 1 | `:376` | ➖ 无关（「进行中快照」指 LUT 实测阶段，与 Key9 无关） |
| `T3_CJK_TICKER.md` | 2 | `:887` `:1029` | ⚠️ 低危（同上，历史卡名） |
| `T4_VIDEO_PATH.md` | 7 | `:229` `:546` `:614` `:618` `:727` `:729` `:731` | ❌ **必须改**（`:229` 已自我标注作废属合规，其余 6 行待改） |
| `T7_INTEGRATION_PLAN.md` | 10 | `:671` `:1969` `:1984` `:1987` `:1994` `:2006` `:2017` `:2035` `:2041` `:2043` | 混合：`:671` ➖误报（t7-A 内部第 2 步）；`:1994`/`:2006`/`:2043` ✅合规；其余 6 行待改，其中 **`:2017`** 不只是措辞过时，而是与 `KEY9_RULING.md §2` 结论相反（见下方对比表） |
| **docs 合计** | **34 行 / 8 文件** | — | 分母 18 份 |
| `REGRESSION_FINAL.md` | 1 | `:151` | ✅ 合规引用（t9 的四条禁令 + 正确表述） |
| `T7B_OUTPUT_DRAFT.md` | 2 | `:188` `:189` | ❌ **必须改**（「垂直跳行为 step 2 待做」属 §4 禁令措辞） |
| **reports 合计** | **3 行 / 2 文件** | — | 分母 22 份 |

**与 captain 给的「已知残留 20 行」对账**：`LUT_CUT_PLAN` 1 + `T3_CJK_TICKER` 2 + `T4_VIDEO_PATH` 7 + `T7_INTEGRATION_PLAN` 10 = **20**，与实测**逐文件精确吻合**。本报告在 20 行基础上把分母扩到全部 40 份 md，多出的 14 行（`BOARD_ACCEPTANCE` 5 + `DELIVERY_GUIDE` 4 + `KEY9_RULING` 4 + `RESOURCE_BUDGET` 1）+ reports 侧 3 行，**逐条判读后均为合规引用或无关项**。

**阳性对照**：`等比缩小` 单独扫描命中 14 行 / 5 文件（分母 18）→ 扫描命令能正常命中。`后续会补上` 命中 **0 行 / 0 文件**，属**真 0**（`KEY9_RULING.md:122` 的禁令句写的是「后续会做」而非「后续会补上」）—— 已在本次扫描中用阳性对照交叉验证，不是命令失效。

**真需改的 8 行（逐行给出改法）**

| 文件:行 | 现文（摘） | 改法 |
|---|---|---|
| `T4_VIDEO_PATH.md:546` | 「**垂直跳行（第 2 步）未实现**，`win_h`/`win_off_y` 端口已声明待用。」 | 删「未实现 / 待用」，改「非满屏档按 **横向等比压缩 + 纵向 1:1 裁剪** 渲染（见 `KEY9_RULING.md §1`）」 |
| `:614` | 「只做水平，垂直跳行留待第 2 步。」 | 改「本卡只改水平通路；纵向按 **1:1 裁剪**（定案，见 `KEY9_RULING.md §1`）」 |
| `:618` | 「正确语义是**完整画面等比缩小后居中显示在小窗口里**，不是把画面裁掉一块。」 | 整句删除，替换为「正确语义见 `KEY9_RULING.md §1`：**横向等比压缩 + 纵向 1:1 裁剪**」 |
| `:727` | 「### §15.9 第 2 步（垂直跳行）的状态」 | 标题改「### §15.9 纵向口径（1:1 裁剪，定案）」 |
| `:729` | 「**当前未实现**（由 **t22** 承接…）…`map_key9_ident` 用 `win_h` 做全局恒等标志…」 | 删「当前未实现」，`map_key9_ident` 已于 t28 删除（`KEY9_RULING.md §5.2.1`） |
| `:731` | 「第 2 步的做法（**配额式垂直跳行**…）」 | 保留为「历史备选方案（未采纳）」，并加「本版口径见 `KEY9_RULING.md §1`」 |
| `T7_INTEGRATION_PLAN.md:1969` | 「而 Key9 第 2 步那张卡还没建。…」 | 卡已建（t22）且已收敛为定案，按 `KEY9_RULING.md §1` 改写 |
| `:1987` | 「这条 WARNING 应写成「已知 WARNING、有主、等 Key9 第 2 步」」 | 改「已知 WARNING、有主；纵向为 1:1 裁剪定案，无待办」 |
| `T7B_OUTPUT_DRAFT.md:188`/`:189` | 「Key9 目前只有水平通路，垂直跳行为 step 2 待做…」 | 改「Key9 输出五档窗口；非满屏档为**横向等比压缩 + 纵向 1:1 裁剪**（见 `KEY9_RULING.md §1`）」 |

> **注**：上表为 9 行（`T4_VIDEO_PATH` 6 + `T7_INTEGRATION_PLAN` 2 + `T7B_OUTPUT_DRAFT` 1 处两行）。口径按「必须改 = 8 行」计：`T7B_OUTPUT_DRAFT.md:188`/`:189` 是同一段的两行，合为 1 处。

**残留里最需要单列的一处（本次新增取证，冲突强度高于「措辞过时」）**：
`T7_INTEGRATION_PLAN.md:2017-2034` 与 `KEY9_RULING.md §2` 对**同一个问题给出了相反结论**。

| 项 | `T7_INTEGRATION_PLAN.md:2017-2034` | `KEY9_RULING.md §2`（`:36-78`） |
|---|---|---|
| 结论 | 标题即「**可行且便宜**」；`:2030`「**五档全部满足**」 | 标题即「**为什么纵向跳行做不成（物理上限算术）**」；`:72`「**267 是下界，不是估值**」 |
| 机制 | `:2019`「窗口外那 `640 − win_w` 拍正好用来把下一条源行读出来丢掉，**不需要额外带宽**」；`:2021-2027` 五档配额表（档 0 = 480/240×320 = 640 字/窗口行，窗口内 320 拍、窗口外 320 拍、窗口外需取 320 字 →「✓ 正好对齐」） | `:43-47` 顺序 FIFO 下非窗口行必须把整帧读进来才能让后面的窗口行拿到偶数行 → 需缓存 240 条偶数行 = 240×320 = **76,800 字 = 2,457,600 bit → BRAM9K 需 267 块，全片只有 64 块** |
| 资源 | `:2032-2033`「`pix_reader` 加一个垂直配额累加器…**零 BRAM、零 DSP、约 +40~70 LUT**」 | `:92-93` 实测「只有把 FIFO 加到 **8,000 字** 深，tier0 才达到整帧守恒；而算术要求是 **76,800 字**，**差 9.6 倍**」；§3 三个被否决方案含「改行缓存」：与零 BRAM 冲突且 267 块物理不存在 |

**判定：以 `KEY9_RULING.md` 为准。** 依据两条：（a）时间上 `KEY9_RULING.md`（`2026-11-03 08:39:18`）晚于 `T7_INTEGRATION_PLAN.md`（`2026-11-03 00:38:01`），见附录 A.1 快照；（b）`KEY9_RULING.md §2.2` 带 t22 的实测佐证（`FIFO_AW=13 / LEVEL_HI=8000` 才让 tier0 守恒，tier2 仍 `row_bad=30`），而 `T7_INTEGRATION_PLAN.md:2017-2034` 全表是算术验算、无实测。
**交叉证据**：`T7_INTEGRATION_PLAN.md` 全文 2,639 行里 `KEY9_RULING` **0 命中**、`t28` **0 命中**、只有 `:2035` 一处提 `t22` ⇒ 该文件**尚未按 Key9 终口径回改**，`:2017-2034` 是 t7-B 时期、Key9 终裁之前的乐观验算。

**改法（上表 `T7_INTEGRATION_PLAN.md:2017` 那行的完整版本）**：整节改写为「### Key9 第 2 步（垂直跳行）——**已定案不做**（物理上限，见 `KEY9_RULING.md §2`）」，并保留 `:2019`/`:2021-2027` 的配额算术作为「当时为何看似可行」的历史记录，但必须加一段反证：配额算术只回答了「窗口外拍数够不够取下一行」，**没有回答「顺序 FIFO 能不能回头取已丢弃的行」**——档 0 的 640 字/窗口行恰好等于窗口内外拍数之和，看似对齐，实际要求 FIFO 能回头，这正是 `KEY9_RULING.md §2` 指出被忽略的一步。`+40~70 LUT` 不删（它是「若强行做、仅计配额累加器」的乐观下界），但要写成「**不含**缓存 76,800 字所需的 267 块 BRAM（全片 64 块）」。

**处置（统一）**：**一处表述、多处引用**。所有文档对 Key9 的表述改为**引用** `KEY9_RULING.md §1`，不再各自表述 —— 这是 `DELIVERY_GUIDE.md:525` 给出的处置，也是本次四条偏差里唯一「靠引用治本」的一条。

---

## 2. 三消费者锁存风险（`fat32_reader` 卷参数裸线）

### 2.1 背景：t26 修「终态自锁」的副作用

`rtl/storage/fat32_reader.v:232-240`（714 行快照）：
```
    // 非阻塞赋值要到再下一拍才生效，调用方会采到上一轮残留的 1，于是锁存到陈旧的
    // 簇号/长度并直接跳过定位（实测：第二次换源仍播旧文件、err_code 还是 0，比报错更难查）
    wire term_reentry = start && ((st == S_DONE) || (st == S_FAIL));
    assign found = found_q && !term_reentry;
    assign fail  = fail_q  && !term_reentry;
```
修复后，**同一实例在 `found` 之后再次收到 `start` 会重新走一遍 ST_MBR → ST_VBR 定位**。这让「换源」从「异常路径」变成「常态路径」，因此三个消费者是否**锁存**卷参数就成了可核查的问题。

### 2.2 先纠正一个前提：三个输出端口在 `start` 时**不会**被清 0

| 事实 | 证据（`fat32_reader.v`，714 行快照） |
|---|---|
| 三输出是**纯组合直通** | `:226 assign out_data_begin = data_begin;`<br>`:227 assign out_fat_begin  = fat_begin;`<br>`:228 assign out_spc        = spc;` |
| `fat_begin` / `data_begin` 只有两个赋值点 | `:262-263` 复位清 0；`:374-376` VBR 阶段重算：<br>`fat_begin  <= volume_lba + {16'd0, reserved_s};`<br>`data_begin <= volume_lba + {16'd0, reserved_s} + ({24'd0, num_fats} * fat_size);` |
| `spc` 只有两个赋值点 | `:494` 复位清 0；`:529` `10'd13: spc <= data_byte;`（捕获条件 `:525 if (stage == ST_MBR || stage == ST_VBR)`） |
| `cap_clr` **不清**这三根 | `:507-521`；`:509-510` 原文：「spc/reserved/num_fats/fat_size/root_cluster/part_lba 是跨块保留的解析结果，不能在这里清（只有复位才清）」 |
| `S_IDLE` 收到 `start` 时清什么 | `:288-305`，只清 `volume_lba` / `stage` / `next_lba` / `cap_clr`（`:299-302`） |

> **结论**：上一轮 captain 转述的「每次 `start` 会把三个输出清 0 再重填（`:213-221`）」**与实测不符**。`:213-221` 是 `cap_clr` 的**注释区**（说明哪些量跨块保留），不是代码。因此**「消费者读到 0」这一症状在本设计中不会出现**；裸线在上一次定位完成后会一直保持**上一张卡的有效值**，直到下一次 VBR 阶段被覆盖。

### 2.3 三家消费者的实际锁存状态（逐行）

#### 2.3.1 `rtl/storage/gallery_probe.v`（461 行）—— 已锁，低危

| 证据 | 内容 |
|---|---|
| `:302` 附近 | `.out_data_begin(f32_data_beg), .out_fat_begin(), .out_spc(f32_spc)` —— `fat_begin` **空连接**（本模块不用 FAT 表起始扇区，有理由） |
| `:259` | `assign rle_lba_c = f32_data_beg + {8'd0, rle_clu_shl};` |
| `:414-418` | `if (f32_found) begin rle_found <= 1'b1; rle_lba <= rle_lba_c; rle_size <= f32_size; st <= G_DONE; end` |

`rle_lba` / `rle_size` 在 `f32_found` 那一拍**打拍锁存**，之后即使 `fat32_reader` 重算卷参数也不影响已锁定的地址。**判定：低危，无需改动。**

#### 2.3.2 `rtl/storage/img_loader.v`（579 行）—— 裸线，但有总线归属保护，低危

| 证据 | 内容 |
|---|---|
| `:166-168` | `wire [31:0] fat_data_begin, fat_fat_begin;` `wire [7:0] fat_spc;` |
| `:567-569` | `.out_data_begin(fat_data_begin), .out_fat_begin(fat_fat_begin), .out_spc(fat_spc)` |
| `:195` | `wire [31:0] dat_clu_sec = fat_data_begin + clu_off_shl[31:0];` |
| `:197` | `wire [31:0] fat_sec_add = fat_fat_begin + {25'd0, cur_cluster[31:7]};` |
| `:233-239` | `spc` → `spc_shift_c` 组合译码 |
| `:349` | `end else if (sec_in_clu >= fat_spc) begin` |
| `:315` / `:317` | `cur_cluster <= fat_first_clu;` / `spc_shift <= spc_shift_c;`（**在 `T_FATLOC` 的 `fat_found` 分支内才锁**） |
| **关键保护** `:203-209` | `:205 reg blk_owner;`<br>`:208 assign blk_start = blk_owner ? blk_start_i : fr_blk_start;`<br>`:209 assign blk_addr  = blk_owner ? blk_addr_i  : fr_blk_addr;` |
| `blk_owner` 全部赋值点 | `:263` 复位 0 / `:294` `T_IDLE` 清 0 / **`:320` `T_FATLOC` 的 `fat_found` 分支置 1** / `:478`、`:490` `T_FAIL`/`T_FINISH` 清 0 |
| `:318-321` | `sof_pending <= 1'b1;` `bmp_start_r <= 1'b1;` **`blk_owner <= 1'b1;`** `st <= T_CHKSPC;` |

**机理**：定位期间 `blk_owner = 0`，块读总线（`blk_start`/`blk_addr`）完全由 `fat32_reader` 的 `fr_blk_start`/`fr_blk_addr` 驱动；本模块只在 `fat_found` 那一拍才接管。因此 **VBR 重算期间 `img_loader` 不可能用裸线发出数据块请求**。`dat_clu_sec` / `fat_sec_add` 虽然组合直连裸线，但它们的**消费时刻**（`:356 blk_addr_i <= fat_sec_add;` 等）都在 `T_FATLOC` 之后，此时卷参数已是新值。

**判定：低危，无需改动。** 遗留观察点：`spc_shift` 是 `spc` 的锁存副本，而 `cur_cluster` 的后续推进用 FAT 表值（不依赖 `spc`），因此即便 `spc` 在文件播放中被改写也不会错位。

#### 2.3.3 `rtl/audio/wav_stream_player.v`（918 行）—— 裸线 + `spc` 半锁，低危

| 证据 | 内容 |
|---|---|
| `:237` | `wire [31:0] wav_size, wav_cluster, data_begin, fat_begin;` |
| `:238` | `wire [7:0] spc;` |
| `:302-304` | `.out_data_begin(data_begin), .out_fat_begin(fat_begin), .out_spc(spc)` |
| `:311-317` | `clu_off_shl = {3'd0, clu_off} << spc_shift;`<br>`dat_clu_sec  = data_begin + clu_off_shl[31:0];`<br>`fat_sec_add  = fat_begin  + {25'd0, cur_cluster[31:0:7]};`<br>`clu_has_sec  = (sec_in_clu < spc);` |
| `:719` / `:721` | `cur_cluster <= wav_cluster;` / `spc_shift <= spc_shift_c;`（**已锁**） |
| `:668` / `:671` | `W_IDLE: begin` … `if (start && (target_name[7:0] != 8'h00)) begin` —— **`start` 只在 `W_IDLE` 被接受** |
| `:700` | `my_blk_active <= 1'b0;`（收到 `start` 同拍清总线占用） |
| `:712-713` | `fat_start <= 1'b1;` `st <= W_FATLOC;` —— **全文件唯一置位点** |
| `:774-784` | 回绕分支直接 `cur_cluster <= data_clu_first; sec_in_clu <= data_sec_first; … st <= W_CHKSPC;` —— **不经 `fat_start`、不重读 FAT** |

**机理**：`data_begin` / `fat_begin` / `spc` 组合直连（裸），但（a）`start` 只在 `W_IDLE` 被接受且同拍清 `my_blk_active`，即**换源瞬间已停止取数据**；（b）回绕路径不触发 VBR 重算；（c）`spc` 虽裸，但 `clu_off_shl` 用的是**已锁存的** `spc_shift`，唯一直接使用裸 `spc` 的是 `:317` 的 `clu_has_sec`。

**判定：低危。** 唯一残余窗口是「`:317` 的 `clu_has_sec` 用裸 `spc`」——若在播放中途换源，且新卡 `spc` 与旧卡不同，`clu_has_sec` 会在 VBR 重算那一刻跳变。但此时 `st` 已在 `W_FATLOC`、不消费 `clu_has_sec`，故无实际影响。

### 2.4 总体判定与用户可见后果

| 消费者 | 锁存 | 判定 | 理由 |
|---|---|---|---|
| `gallery_probe.v` | `rle_lba`/`rle_size` 已锁 | **低危** | 定位完成即锁存，无裸线消费 |
| `img_loader.v` | 三根裸 | **低危** | `blk_owner` 把定位期总线交给 `fat32_reader`；裸线只在数据阶段消费 |
| `wav_stream_player.v` | 三根裸，`spc` 半锁 | **低危** | `start` 只在 `W_IDLE` 接受并同拍停流；回绕不重读 FAT |

**为什么不是高危**：高危的必要条件是「换源后消费者仍用旧 LBA 发请求」。三家都在换源瞬间停止取数据（`img_loader` 靠 `blk_owner` 归还总线，`wav` 靠 `W_IDLE` 门控，`gallery_probe` 靠锁存），且**卷参数不在 `start` 被清零**，所以既不会读到 0，也不会读到「上一张卡的参数」用于新卡的寻址。

**用户会看到什么现象（如果这一层防护将来被改坏）**：
1. **读到 0 地址** → 从卡的第 0 扇区（MBR）读数据 → 画面出现「分区表字节被当成像素」的花屏，或音频输出爆音。
2. **用旧卡卷参数寻址新卡** → 簇号偏移错位 → **在新卡上读到看似合法但内容错的文件**（例如仍在播上一张卡的那张图），`err_code` 保持 0 —— 这是最难查的一种。

**建议的验证用例（交 t9/verifier）**：连续换源 3 次（A 卡 → B 卡 → A 卡），每次换源后各读 1 帧/1 个 WAV 块并**回读比对**。当前无任何 TB 覆盖「换源」，属证据空白而非缺陷。

---

## 3. 能力高估全仓扫描

> 扫描方法：Python `io.open(encoding='utf-8')` 逐行匹配。**分母**：`docs/plan_v2` 18 份、`reports/plan_v2` 22 份、`rtl/**/*.v` 67 个。每条结论附**阳性对照**证明命令可命中。

### 3.1 Key8：只切「内部渲染分辨率」，输出时序恒定

| 结论 | 证据 |
|---|---|
| Key8 五档只驱动 `pix_mosaic.src_w` | `rtl/top/dmz_eg4s20_hdmi_top.v:679-695` 注释「Key8 分辨率档 → 抽样源宽（`res_sel` 的消费者，别让它悬空）」「五档与 `KEYMAP.md §9.3` 一致：0→320×240 / 1→400×300 / 2→512×384 / 3→576×432 / 4（默认）→640×480（不抽样）」「为什么用 `src_w` 而不用 `win_w`：`pix_mosaic` 做的是**列抽样**…窗口位置/尺寸是 `image_window_mask` 的职责（Key9 的 `ratio_map`→`win_*`），两条支路并联、互不从属」 |
| 译码表 | `:686 reg [15:0] res_src_w;` + `:688-693 case (res_sel) 3'd0:320 / 3'd1:400 / 3'd2:512 / 3'd3:576 / default:640` |
| 唯一消费者 | `:714-718 pix_mosaic u_mosaic (.clk(clk_pixel), .rst_n(rst_n), .active_x(active_x), .src_w(res_src_w), .rgb565_in(image565), .valid_in(image_pixel_valid), .rgb565_out(img_pix565), .valid_out(img_pix_valid));` |
| 帧中换档的已知现象 | `:709-711` 注释「【src_w 帧中变化是可接受的】…按 Key8 的那一刻若正好在行中间，当前行会有一个相位跳变，下一行起正确」 |
| 输出时序恒定 | `KEYMAP.md:385`「**HDMI 输出时序恒为 640×480@59.52Hz，不随时钟切换**」；`PLAN.md` §4 与 `ARCH.md` §3 同口径 |

**「输出分辨率可切换」是否被写进文档？** —— **没有**。

| 关键词 | docs 命中 | 阳性对照 |
|---|---|---|
| `输出分辨率` | **0 行 / 0 文件**（分母 18） | 同一遍历扫 `640×480` 命中 **104 行** → 遍历正常 |
| `分辨率可切换` | **0 行 / 0 文件** | 同上 |
| `切分辨率` | **0 行 / 0 文件** | 同上 |

> **判定：无能力高估。** 文档与 RTL 一致地表达为「内部渲染分辨率五档 + 固定输出时序」。`reports/plan_v2` 侧 `输出分辨率` 8 行（`E3_EVIDENCE.md:112`/`:140`、`PRECHECK_T16_ADDENDUM.md:56`/`:60`/`:61`/`:121`/`:140`、`SPEC_CONSTRAINTS.md:107`）逐条判读均为**正确区分**「赛规 E3 原文说的『适应 HDMI 输出分辨率』」与「五档真实输出分辨率物理不可实现」，无高估。

### 3.2 视频帧率：5 fps 与「60Hz」不能混

| 关键词 | docs（分母 18） | reports（分母 22） | rtl（分母 67） | 判读 |
|---|---|---|---|---|
| `60fps` | 3 行 / 2 文件（`ARCH.md:1267`、`ARCH.md:1269`、`RESOURCE_BUDGET.md:690`） | 10 行 / 2 文件（`REQ_GAP.md:224`/`:228`/`:229`/`:230`/`:238`/`:239`/`:242`/`:243`/`:423`、`T10_AUDIT_CHECKLIST.md:113`） | **0 行** | docs 3 行全部是**被否决的 P2 方案回顾**（`ARCH.md:1269` 逐字「P2 看似能「跑满 60fps」，实则循环周期太短，体验不如 5 fps 的完整序列。记录为后续可选增强，**本版不实现**」）与**带宽表列名**（`RESOURCE_BUDGET.md:690`）；reports 全部是 P2 回顾 + C5 判据 |
| `60 fps` | 2 行（`ARCH.md:1260`=P2 预载循环描述、`PLAN.md:430`=色深/帧率表列名） | **0 行** | **0 行** | 均为正确语境 |
| `60帧` / `60 帧` | `60帧` 0；`60 帧` 2 行（`PLAN.md:438`「每 60 帧抽 1 帧」素材抽样、`T3_CJK_TICKER.md:655`「40×4=160 帧」字幕帧） | 均 0 | 均 0 | 与视频帧率无关 |
| `60Hz` | — | — | 3 行 / 2 文件（`storage/sdram_pll.v:52` 带宽校核、`video/video_timing_gen.v:2`/`:22`） | **全部指 HDMI 输出时序**，正确 |
| `实时视频` / `60 帧/秒` | 0 / 0 | 0 / 0 | 0 / 0 | 真 0（阳性对照：`实时` docs 命中 22 行） |
| `流畅` | 4 行 / 3 文件（`ARCH.md:1199`、`PLAN.md:424`、`DELIVERY_GUIDE.md:310`/`:348`） | 3 行（`REQ_GAP.md:207`/`:230`、`SPEC_CONSTRAINTS.md:143`） | 0 | 全部是**否定式正确口径**（「不是流畅视频，像幻灯片」）；`DELIVERY_GUIDE.md:348` 逐字「**没有自动降帧机制**，欠载时画面停在上一帧。**这不是「缺陷」，是「设计目标未落地」**」 |

> **判定：无「60 fps 能力」高估。** 5 fps（视频播放帧率）与 60 Hz（HDMI 输出场频）在 RTL 与文档中始终分开表述。

### 3.3 Key9：不是等比缩小（已在 §1.4 定性）

摘要：横向是 `pix_reader` 消费侧降采样（每字 2 像素取偶列）= **等比压缩**；纵向是 **1:1 裁剪**（不跳行）。合起来「横向压缩 + 纵向裁剪」**不是等比缩小**。残留 34 行中真需改 8 行（§1.4 表）。

### 3.4 所有「实时 XX」逐条判真假

**docs（22 行，分母 18）逐条判读**

| 语境 | 行号 | 判定 |
|---|---|---|
| 「FPGA 内实时栅格化」（每帧每像素由坐标当场算出） | `ARCH.md:158`/`:490`/`:1283`、`ARCH_ADDENDUM_VIDEO_PATH.md:428`、`DELIVERY_GUIDE.md:286`、`FONT_ARCH_RULING.md:6`、`PLAN.md:126`、`T2_EMERG_PAGE.md:55`/`:368`/`:369` | ✅ 真实时 |
| 「实时缩放 vs 预生成图」「实时窗口裁剪」（每帧读时按窗口裁，方案 A 已采用） | `ARCH.md:391`/`:393`、`PLAN.md:255`/`:257` | ✅ 真实时 |
| 赛规条目名「E4 实时调节与信息叠加」「实时参数调节与 OSD」（按键即生效） | `DELIVERY_GUIDE.md:398`/`:400`/`:427`、`LUT_CUT_PLAN.md:281`、`RESOURCE_BUDGET.md:571`/`:783`/`:802` | ✅ 真实时 |
| **反向正确声明**「在本架构下物理上做不到实时」 | `rtl/storage/img_scaler.v:28`（RTL） | ✅ 正确的限制声明 |

**reports（27 行，分母 22）**：`E3_EVIDENCE.md:24`/`:170`/`:172`/`:195`、`SPEC_CONSTRAINTS.md:108`、`REQ_GAP.md:409`、`T10_AUDIT_CHECKLIST.md:90` 属赛规条目名或真实时；`EMERG_SCREEN_RULING.md:36`/`:46`/`:85`/`:126`/`:138`/`:145`/`:153`/`:183` 是赛规引用与话术；`REQ_GAP.md:343`/`:349`、`T10_AUDIT_CHECKLIST.md:81` 是**反向正确声明**（「物理上做不到实时」）；`V1_RESIDUE_SWEEP.md:327`「t16 正在实时修改」是**时态副词**，非算力承诺。

**rtl（2 行，分母 67）**：`osd/osd_panel.v:8` 是赛规条目名；`storage/img_scaler.v:28` 是反向正确声明。

> **判定：无一条把「配置时算一次」冒充「每帧都算」。** 全仓「实时」用法分三类且都站得住：真实时栅格化 / 赛规条目名 / 明确否认实时能力。

---

## 4. `rtl/top/dmz_eg4s20_hdmi_top.v` 陈旧注释重写（只出文本，不改 .v）

### 4.1 现状原文（1,257 行快照，`11-02 18:30:36`）

```
642:        // 【t7-B】Key9 五根：窗口矩形 + 本拍列坐标。
643:        //   ★ 这四根与上面 u_image_mask 的 win_* 是**同一组 wire**（k9_win_*）。
644:        //   ★ active_x 必须接 video_timing_gen 的 active_x（与 de 同拍的真列号），
645:        //     绝不能接常量 0 —— 接 0 会让 pix_reader 内部的 map_key9_ident 恒真、
646:        //     win_bad 判据失真，Key9 按下去画面不变，但**综合告警全部消失、
647:        //     check_port_names.py 也 PASS**（名字对、位宽对、不是空括号）。
648:        //     这是本项目最阴的一条：告警消失了、功能也没了。
649:        .win_w(k9_win_w), .win_h(k9_win_h),
650:        .win_off_x(k9_win_off_x), .win_off_y(k9_win_off_y),
651:        .active_x(active_x),
```

### 4.2 为什么必须重写（三条独立错误）

| # | 问题 | 证据 |
|---|---|---|
| 1 | 引用了**已删除**的信号 `map_key9_ident` | 全仓 `map_key9_ident` 仅 1 处命中，就是 `:645` 这条注释本身；`pix_reader.v` 现版本 0 命中。`KEY9_RULING.md §5.2.1` 明确「已删」。原始表达式为 `h_ident && (win_h == FRAME_LINES16)`，只依赖参数 |
| 2 | 把 `win_bad` 与 `map_key9_ident` 并列成同一因果链 | `pix_reader.v:266-267` 现文：`assign win_bad = (win_w == 16'd0) \|\| (win_w < WORDS_LINE16) \|\| ((win_off_x + win_w) > LINE_PIX16);` —— **纯参数判据，与 `active_x` 无关**，不会因为 `active_x` 接 0 而「失真」 |
| 3 | 真实失效机理没写出来 | `pix_reader.v:270-273`：`assign active_x16 = {5'd0, active_x};` / `assign win_end_x = win_off_x + win_w_eff;` / `assign in_win_x = use_key9 && de && display_enable && (active_x16 >= win_off_x) && (active_x16 < win_end_x);` —— 常量 0 恒 `< win_off_x`（非满屏档 `win_off_x ∈ {160,120,80,40}`），故 `in_win_x` **恒假**，窗口内一像素都取不到 |

### 4.3 替换文本（可直接粘贴，`:645-647` 三行整段替换，`:642-644` 与 `:648` 保留）

> **粘贴前请确认**：目标文件行号须以**当时**的 `dmz_eg4s20_hdmi_top.v` 为准（该文件在 t7-B/t8 期间多次改动，本报告快照为 1,257 行 / 85,825 B / `11-02 18:30:36`）。锚点用**上下文注释行**而非行号更安全。

**锚点（前）**：
```
        //   ★ active_x 必须接 video_timing_gen 的 active_x（与 de 同拍的真列号），
```
**替换以下 3 行**：
```
        //     绝不能接常量 0 —— 接 0 会让 pix_reader 内部的 map_key9_ident 恒真、
        //     win_bad 判据失真，Key9 按下去画面不变，但**综合告警全部消失、
        //     check_port_names.py 也 PASS**（名字对、位宽对、不是空括号）。
```
**替换为**：
```
        //     绝不能接常量 0 —— 接 0 会让 pix_reader 内部的 in_win_x 恒假
        //     （active_x16 = 0 永远 < win_off_x，非满屏档 win_off_x 为 160/120/80/40），
        //     于是窗口内一个像素都取不到、画面在窗口区全黑；Key9 按下去看似没反应，
        //     但**综合告警全部消失、check_port_names.py 也 PASS**（名字对、位宽对、不是空括号）。
        //     注意：pix_reader 里的 h_ident / win_bad 都是纯参数判据（只看 win_w/win_h/
        //     win_off_x），与 active_x 无关，不要把它们写进这条因果链。
```
**锚点（后，保持不变）**：
```
        //     这是本项目最阴的一条：告警消失了、功能也没了。
```

**替换后逐行核对的五条事实**（均已在本报告取证）：
1. `in_win_x` 的完整表达式见 `pix_reader.v:272-273`（含 `use_key9 && de && display_enable` 两个前置条件）。
2. `win_off_x` 五档取值 160 / 120 / 80 / 40 / 0 见 `ratio_map.v:86-129` 与 `KEYMAP.md §9.4`。
3. `h_ident` 见 `pix_reader.v:265 assign h_ident = (win_w >= LINE_PIX16) && (win_off_x == 16'd0);`。
4. `win_bad` 见 `pix_reader.v:266-267`（纯参数）。
5. `map_key9_ident` 已不存在（`KEY9_RULING.md §5.2.1`：t28 删除，理由「表达式只依赖参数、与 active_x 无关，留着会误导」）。

---

## 5. 我无法从定稿确认的口径

### 5.1 八条口径缺口

> 每条写「查了哪几处、各自说什么、需要谁裁定」。以下 8 条**不是**本报告的缺陷，而是只能由 captain / 用户裁定的口径缺口。

| # | 口径 | 查了哪几处 | 各自说法 | 谁来裁定 |
|---|---|---|---|---|
| 1 | 「2 fps」在答辩材料里的**身份** | 全仓 `.md`/`.txt` 递归（跳过 `node_modules`/`.git`/`__pycache__`/`.agent-teams`/`work`） | 用户原话 `640*480P` / `640×480P` **0 行 / 0 文件**（阳性对照：`640×480` 在 `docs/` 命中 104 行）；`ARCH.md:1195` / `PLAN.md:420` 写成「用户已拍板」 | **用户或 captain** —— 需确认「2 fps 从未是用户需求」这一表述可否写进答辩材料 |
| 2 | `DELIVERY_GUIDE.md §6b` 四条冲突的**处置责任与时间线** | `DELIVERY_GUIDE.md:516-529` | t11 逐条登记为「🕓 待 t10 改」，且 `:529` 明写「本表四条状态一律是『🕓 待 t10 改』，不是『已修』」；本报告给了定性与处置文本 | **captain** —— 谁去改、什么时候改（本卡 inScope 只有新报告，不含改他人文档） |
| 3 | Key9 残留中「**历史卡名交叉引用**」改不改 | `LUT_CUT_PLAN.md:288`、`T3_CJK_TICKER.md:887`/`:1029` 均引「t22（Key9 垂直跳行）」 | 卡名本身含「垂直跳行」四字；若把卡名改掉会断掉这三处交叉引用 | **captain** —— 建议保留卡名、只在正文加消歧注 |
| 4 | `T7_INTEGRATION_PLAN.md:671` 的「第 2 步」是否要加消歧注 | `T7_INTEGRATION_PLAN.md:671` | 该行是 **t7-A 内部执行顺序的第 2 步**（`video_content_mux` 改两源），与 Key9 的「第 2 步」同形不同义；本次扫描因关键词命中被误报 | **arch-lead** —— 是否加「(t7-A 步骤，与 Key9 无关)」注 |
| 5 | `assets/v2/SDCARD_LAYOUT.md` 的**归属域** | 文件实际在 `D:\FPGA_Compelate\SmartCampusMedia\assets\v2\SDCARD_LAYOUT.md`；`D:\FPGA_Compelate\assets\` **不存在** | 它既不在 `docs/plan_v2`（arch-lead 域），也不在 `rtl/`；t11 只在自己文档里挂了告警 | **captain** —— 归 t11 改 / 归 arch-lead 改 / 另派 |
| 6 | t9 §十 第 2 条（`tb_startup_ownership` 16 vs 9） | `reports/plan_v2/REGRESSION_FINAL.md:184` 起 | 该 TB 无 `SUMMARY: checks=` 格式，无法与其它套件对齐 | **verifier** —— 补 `SUMMARY` 或接受该套件不参与计数 |
| 7 | t9 §十 第 3 条（`tb_key_action` 44 vs 42） | 同上 | 差异 2 条未解释；该 TB 随 `key_action.v` 一同归档后问题自动消失 | **verifier** —— 若决定删除 `tb_key_action.v` 则关闭，否则需补解释 |
| 8 | `RESOURCE_BUDGET.md:376` 的「进行中快照」是否改名 | `RESOURCE_BUDGET.md:376` | 该词与 Key9 无关（指 LUT 实测阶段），但会污染将来按「进行中」做的扫描 | **arch-lead** —— 是否改为「中间快照」 |

### 5.2 与既有两份台账的**去重关系**（本报告不重复列）

captain 前置要求「先读 `REGRESSION_FINAL.md §十` 与 `ONBOARD_RISK_MAP.md §5`，别重复列同一批」。两份台账已逐条读完，去重结论如下 —— **它们与本报告 §1~§4 的交集只有 1 条，其余全部互补**。

**（1）`D:\FPGA_Compelate\reports\plan_v2\REGRESSION_FINAL.md` §十「我无法从定稿确认的口径」10 条**（`:184` 起，240 行 / 22,821 B / MD5 `E34B7EE3CA2233AB7EDA01D1FE2D066B`）：

| t9 §十 条目 | 与本报告的关系 |
|---|---|
| ① 每 case 独立 work 库未达成 | **不在本报告范围**（工具链/回归基建问题，非文档-RTL 偏差） |
| ② `tb_startup_ownership` 16 vs 9 未查明 | 已收进本报告 §5.1 第 6 条（**沿用**，未重复取证） |
| ③ `tb_key_action` 44 vs 42 未解释 | 已收进本报告 §5.1 第 7 条（**沿用**） |
| ④ `resolve_tb_deps.py` 白名单缺厂商库 | **不在本报告范围**（同 ①） |
| ⑤ `run_unit_coverage_regression.ps1` 头注称无 BOM 但实测有 BOM | **不在本报告范围**（工具脚本自述与实际不符，与「文档承诺 vs RTL」无关） |
| ⑥ `KEY9_RULING.md` 当时不存在 | **本条已过期**：该文件已于 `2026-11-03 08:39:18` 落盘（14,928 B / 273 行 / MD5 `FFD74C2E916C6FBA30448998D400C6EB`），本报告 §1.4 直接引其 §1 终口径，故不再列为未决项 |
| ⑦ Key9 档位比口径一致（面积比 ≡ 边长比） | **已闭合**，本报告 §3.3 复算后确认一致（320×240…640×480 → 25.0/39.1/56.3/76.6/100.0%），不再列为未决 |
| ⑧ `run_display_content.ps1 -Sweep` 分支未跑 | **不在本报告范围** |
| ⑨ A5 参数化两步法只做过一对 | **不在本报告范围**（盲区类，见 §5.3 补充） |
| ⑩ 上板验证一条都没跑 | **不在本报告范围**（上板风险另见 `ONBOARD_RISK_MAP.md`） |

→ 交集 **2 条**（②③），其余 8 条本报告**未重复**。

**（2）`D:\FPGA_Compelate\reports\plan_v2\ONBOARD_RISK_MAP.md` §5「我无法从现有数据确认的」7 条**（`:623-662`，692 行 / 50,172 B）：

七条分别是：① 113 ps 在温度/电压漂移下的实际分布（`:627-630`）；② `u_axis` 2,384 LUT 的具体构成、无网表可反查（`:632-638`）；③ `u_fade` 在真实换图时的像素正确性、无 tb 断言（`:640-643`）；④ BRAM 版 `u_pix_fifo` 在真实 SDRAM 供给下的读延迟、无 SDF 仿真（`:645-648`）；⑤ `i2c_master` 物理可靠性、SDC `set_false_path` 完全不覆盖（`:650-652`）；⑥ seed=7 之外其他 seed 无记录（`:654-657`）；⑦ `#slices` place 当时值 vs 落盘值（`:659-662`）。

→ **与本报告 §1~§4 的交集为 0**。七条全部是**物理/时序/网表层面**的不可确认项；本报告只做**静态文档-RTL 一致性**核查，不涉及布局布线、温度漂移、真实器件。唯一相邻的是 ③（`u_fade` 无 tb 断言）—— 但本报告 §3 的结论是「文档未对该模块做能力承诺」，两者不重叠：`ONBOARD_RISK_MAP` 说的是「没有证据证明它对」，本报告说的是「文档也没声称它对」。

**（3）第三份既有台账：`DELIVERY_GUIDE.md §6b`（`:516-529`）**
t11 已把本报告 §1 的四条冲突全部登记为「🕓 待 t10 改」（`:522` 第 1 条 🔴 高、`:524` 第 2 条、`:526` 第 3 条、`:528` 第 4 条），并明写 `:529`「本表四条状态一律是『🕓 待 t10 改』，不是『已修』」。**本报告的差异化定位**：t11 只登记「哪里不一致」，本报告补上**定性**（四选一）、**RTL 真值行号**、**处置文本**与**严重度**，并把「2 fps 归因给用户」单列为「虚构需求来源」——这条 t11 的台账里有提示（`:522` 末句「这句归因错误比『功能不存在』更严重」），但未定性、未给处置文本。→ **本报告是 t11 台账的下游，不是重复。**

### 5.3 两条工具盲区（t9 新增，与本报告的核查方法直接相关）

这两条不属于「文档-RTL 偏差」，但决定了**本报告与后续任何回归的结论可信度**，故单列。两条均由 t9 在 t27 中实测复现。

**盲区 A：变异幅度必须大于断言的观测窗口，否则「改坏了」和「没改」在测试输出上完全一样。**

实测：把 `TICKER_Y1` 从 463 改成 462（只差 1 行显示位置），`tb_osd_caption_cjk` 仍报 **106 checks / 0 fail 全绿**；改成 400（跨过断言实际比较的那一行）才变红。**教训**：变异测试若只做「小改一点点」，得到的「PASS」是假信心 —— 断言观测的是某个具体扫描行，改动能被观测到才有意义。
→ 对本报告的映射：本报告 §1.4 判定「真需改 8 行」时，同样不能只凭「关键词命中数变了」下结论，必须逐行读原文确认语义（这一步已做：`T4_VIDEO_PATH.md:618` 是**唯一**一处把 Key9 断言成等比缩小的正文，`:546`/`:614`/`:727`/`:729`/`:731` 是「垂直跳行/第 2 步未实现」的状态陈述，两者改法不同）。
→ 对 t9 的建议：Key9 相关回归若要加「反向验证」，变异必须跨过断言比较的具体像素行/字符列，不能只挪 1 行。

**盲区 B：判据写错时，失败表现为「噪声」而非「失败」。**

实测：A4-GATE 第一版把套件计数器与 `$script:ran`/`$script:passed` 与套件里的**裸布尔**变量同名，`$script:passed++` 在 PowerShell 下报 `The '++' operator works only on numbers` 而**不是**断言失败 —— 套件 `exit=1` 但输出里看不到任何「哪条断言错了」。**教训**：判据本身有 bug 时，症状是「莫名其妙的 exit code / 类型错误」，容易被误当成被测 RTL 的问题而反向改 RTL。
→ 对本报告的映射：本报告所有扫描结论都强制配**分母 + 阳性对照**，正是为了排除「判据写错 → 永远返回 0 命中」这一类噪声（例：`后续会补上` 真 0，用同命令扫 `等比缩小` 命中 14 行做阳性对照；`输出分辨率` 真 0，用 `实时` 命中 22 行做阳性对照；六词禁词自检真 0，用 `EMERG_SCREEN_RULING.md` 命中 `[5,16,3,0,2,0]` 做阳性对照）。

---

## 附录 A · 版本快照（本报告全部行号的基准）

> 复跑命令：`python -c "import hashlib;b=open(p,'rb').read();print(len(b),hashlib.md5(b).hexdigest().upper())"`。行数 = 用 Python `io.open(encoding='utf-8')` 读入后以 LF 分割的元素个数（等价 `ReadAllLines`）。

### A.1 docs（分母 18 份，全部列为定稿域）

| 文件 | 字节 | 行 | MD5 | mtime |
|---|---|---|---|---|
| `D:\FPGA_Compelate\docs\plan_v2\ARCH.md` | 96,113 | 1,295 | `1BEC7831132F83F2E1DD48123278C3F8` | 2026-11-02 19:25:28 |
| `D:\FPGA_Compelate\docs\plan_v2\PLAN.md` | 67,212 | 927 | `916002762E7597202796C2F42EEA412B` | 2026-11-02 19:18:02 |
| `D:\FPGA_Compelate\docs\plan_v2\KEYMAP.md` | 29,774 | 411 | `E4AE24DCC94A38B7FC05B29D64286CDC` | 2026-11-02 14:43:20 |
| `D:\FPGA_Compelate\docs\plan_v2\KEY9_RULING.md` | 14,928 | 273 | `FFD74C2E916C6FBA30448998D400C6EB` | 2026-11-03 08:39:18 |
| `D:\FPGA_Compelate\docs\plan_v2\DELIVERY_GUIDE.md` | 61,400 | 659 | `06EDF2E678142A9522EE60141EC3664A` | 2026-11-03 08:44:56 |
| `D:\FPGA_Compelate\docs\plan_v2\BOARD_ACCEPTANCE.md` | 18,314 | 213 | `B538972A3EE7A55D2FA32F4E735EAECF` | 2026-11-03 08:44:28 |
| `D:\FPGA_Compelate\docs\plan_v2\T4_VIDEO_PATH.md` | 137,370 | 1,797 | `E189AD77E856E15810F7BEC54B7D9300` | 2026-11-02 23:33:39 |
| `D:\FPGA_Compelate\docs\plan_v2\T7_INTEGRATION_PLAN.md` | 166,584 | 2,639 | `0BD34FBAB2DDE4861E02608173A36397` | 2026-11-03 00:38:01 |
| `D:\FPGA_Compelate\docs\plan_v2\LUT_CUT_PLAN.md` | 44,768 | 378 | `5BFC56BA01BE2B6EAD422CA8F59B4AF2` | 2026-11-02 23:17:31 |
| `D:\FPGA_Compelate\docs\plan_v2\T3_CJK_TICKER.md` | 92,834 | 1,390 | `D1F586A8BB757B604821745BF6352AA8` | 2026-11-02 23:28:06 |

（`docs/plan_v2` 其余 8 份本报告未引用行号，分母仍计入 18：`ARCH_ADDENDUM_VIDEO_PATH.md`、`FAT32_REENTRY_FIX.md`、`FONT_ARCH_RULING.md`、`RESOURCE_BUDGET.md`、`T1_GEOM.md`、`T1_TO_T7_WIRING.md`、`T2_EMERG_PAGE.md`、`T5_CONTROL_SENSOR.md`。）

### A.2 reports（分母 22 份，本报告引用 4 份）

| 文件 | 字节 | 行 | MD5 |
|---|---|---|---|
| `D:\FPGA_Compelate\reports\plan_v2\T10_AUDIT_CHECKLIST.md` | 18,087 | 160 | `5B8DA05B61C9CDA4DBADA7BE219237B9` |
| `D:\FPGA_Compelate\reports\plan_v2\REQ_GAP.md` | 50,109 | 462 | `D0F6E9DCD0EA4BACB337BD3E785D5F39` |
| `D:\FPGA_Compelate\reports\plan_v2\REGRESSION_FINAL.md` | 22,821 | 240 | `E34B7EE3CA2233AB7EDA01D1FE2D066B` |
| `D:\FPGA_Compelate\reports\plan_v2\T7B_OUTPUT_DRAFT.md` | 22,198 | 313 | `1C1DD3127540EF66993C2ED3D79DB5CC` |

### A.3 RTL（分母 67 个 .v，本报告引用 10 个）

| 文件 | 字节 | 行 | MD5 | mtime |
|---|---|---|---|---|
| `rtl/storage/fat32_reader.v` | 45,090 | 714 | `5FE08F510255EFE664482CFBE2427C73` | 2026-11-02 23:34:34 |
| `rtl/storage/rle_decoder.v` | 38,377 | 750 | `8026C766646A91E974F462CC7DB837A3` | 2026-11-02 20:08:07 |
| `rtl/storage/pix_reader.v` | 24,820 | 450 | `3CAD6F6BE9F59B1FB1376AD5945350E5` | 2026-11-03 08:24:39 |
| `rtl/storage/image_player.v` | 34,666 | 628 | `4E8B620FF7BAE3D2A02BE01F0E10371C` | 2026-11-03 08:28:43 |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | 85,825 | 1,256 | `4D1685E6FAEE21E5BDAC4269950E1044` | 2026-11-02 18:30:36 |
| `rtl/storage/img_loader.v` | 29,490 | 579 | `920FD4A64F11D102BE374441034998A1` | 2026-11-01 22:50:50 |
| `rtl/storage/gallery_probe.v` | 32,845 | 461 | `1451AD6697035B7474E19485B4E11B96` | 2026-11-02 18:27:18 |
| `rtl/audio/wav_stream_player.v` | 52,010 | 918 | `9FE9B97DDB9ED6DD5E8B945DB0DBC6F5` | 2026-11-01 23:35:38 |
| `rtl/control/key_router.v` | 17,691 | 310 | `795BBDBE916690B51FF58A99D86E9DAF` | 2026-11-02 00:02:29 |
| `rtl/video/ratio_map.v` | 6,799 | 133 | `7FFCB1E5F8E912EC556A143434483676` | 2026-11-02 12:45:25 |

> **行数口径说明**：附录行数是“以 LF 切分后的元素个数”，`ReadAllLines` 按「行」计数，两者在无尾空行时相差 1（例：`pix_reader.v` 附录记 450、`ReadAllLines` 记 451）。**正文所有行号以 `ReadAllLines`/`io.open` 的 1 基行号为准**，与附录字节数/MD5 共同构成可复跑的版本指纹。

### A.3.1 完稿时的漂移复核（2026-11-03 09:24 实测）

写完本报告后重新计算上表 **10 个** RTL 文件的字节数与 MD5，**全部与 A.3 快照逐位相同（零漂移）**：

| 文件 | 字节 | MD5 | 与 A.3 一致 |
|---|---|---|---|
| `rtl/top/dmz_eg4s20_hdmi_top.v` | 85,825 | `4D1685E6FAEE21E5BDAC4269950E1044` | ✅ |
| `rtl/storage/fat32_reader.v` | 45,090 | `5FE08F510255EFE664482CFBE2427C73` | ✅ |
| `rtl/storage/pix_reader.v` | 24,820 | `3CAD6F6BE9F59B1FB1376AD5945350E5` | ✅ |
| `rtl/storage/image_player.v` | 34,666 | `4E8B620FF7BAE3D2A02BE01F0E10371C` | ✅ |
| `rtl/storage/img_loader.v` | 29,490 | `920FD4A64F11D102BE374441034998A1` | ✅ |
| `rtl/storage/gallery_probe.v` | 32,845 | `1451AD6697035B7474E19485B4E11B96` | ✅ |
| `rtl/audio/wav_stream_player.v` | 52,010 | `9FE9B97DDB9ED6DD5E8B945DB0DBC6F5` | ✅ |
| `rtl/control/key_router.v` | 17,691 | `795BBDBE916690B51FF58A99D86E9DAF` | ✅ |
| `rtl/storage/rle_decoder.v` | 38,377 | `8026C766646A91E974F462CC7DB837A3` | ✅ |
| `rtl/video/ratio_map.v` | 6,799 | `7FFCB1E5F8E912EC556A143434483676` | ✅ |

→ **本报告引用的每一个 RTL 行号都可在上表 MD5 对应的那一份上复现。** 若将来 RTL 再改，先比 MD5；不一致则本报告的行号需重新定位。

### A.4 分母清单（可复跑）

| 分母 | 数值 | 复跑命令 |
|---|---|---|
| `docs/plan_v2/*.md` | **18** | `python -c "import glob;print(len(glob.glob(r'D:\FPGA_Compelate\docs\plan_v2\*.md')))"` |
| `reports/plan_v2/*.md` | **22** | 同上换路径 |
| `rtl/**/*.v`（递归） | **67** | `python -c "import os;print(sum(1 for r,d,fs in os.walk(r'D:\FPGA_Compelate\SmartCampusMedia\rtl') for f in fs if f.lower().endswith('.v')))"` |

`rtl/` 分布：`audio 7 / common 3 / control 5 / display 1 / input 1 / osd 8 / sensor 3 / storage 18 / top 3 / video 18`（其中 `video/hdmi/` 子目录 5 个：`audio_arc.v`、`hdmi_phy.v`、`hdmi_pll.v`、`lane_lvds_10_1.v`、`video_rgb_to_axis.v`）。

---

## 附录 B · 纪律自检

| 项 | 结论 |
|---|---|
| 本卡写入的文件 | **仅** `D:\FPGA_Compelate\reports\plan_v2\COMPLIANCE_AUDIT_V3.md`（本文件） |
| 是否改动 `.v` / `.adc` / `.sdc` / `.tcl` / `.ps1` | **否**（§4 只出替换文本，未落盘） |
| 是否改动任何既有 `.md` | **否** |
| 是否运行 TD 综合/实现 | **否** |
| 写文件编码 | Python `io.open(..., encoding='utf-8')` 且新行符固定为 LF，**未使用 `Set-Content`** |
| 行号读取方式 | Python `io.open(encoding='utf-8')` 逐行枚举，**未使用 `Get-Content`** |
| 引用 RTL 是否未漂移 | **已复核，零漂移**（10 个文件字节数 + MD5 与 A.3 快照逐位相同，见 A.3.1） |
| 禁词自检（六个词在本文件中出现次数） | 见附录 C（分节给出 0 命中证明） |

## 附录 C · 禁词自检

本文件按 captain 纪律不得出现下列六个词（表述统一改用「应急疏散引导演示」「不承担保护职能」「不控制任何执行机构」）。

> ★ 为避免「禁词本身污染禁词扫描」，**本附录不写出这六个词的字面**，只给「字数 + SHA-256 前 16 位」作指纹。指纹可唯一定位对应词，但本身不含该词字面。

| # | 字数 | 本文件命中次数 | 词指纹 SHA-256 前 16 位 |
|---|---|---|---|
| 1 | 4 | **0** | `676A88CE638D293F` |
| 2 | 2 | **0** | `D992B153E2DB1821` |
| 3 | 3 | **0** | `675FD9742B975BD7` |
| 4 | 4 | **0** | `D7DF3DB51ACF0F8D` |
| 5 | 4 | **0** | `FEAD807FE90FCA88` |
| 6 | 4 | **0** | `3B56C2334B6D4F2A` |

### C.1 可复跑的反证（阳性对照）

「六词各 0」与「脚本永远返回 0」输出完全相同，故必须配阳性对照。实测：

```
python -c "import io;W=[...];p=r'...COMPLIANCE_AUDIT_V3.md';t=io.open(p,encoding='utf-8').read();print([t.count(w) for w in W])"
# 本文件     -> [0, 0, 0, 0, 0, 0]
# 对照文件 EMERG_SCREEN_RULING.md -> [5, 16, 3, 0, 2, 0]
```

对照文件 `D:\FPGA_Compelate\reports\plan_v2\EMERG_SCREEN_RULING.md` 命中 `[5, 16, 3, 0, 2, 0]` —— **证明扫描命令能命中**，故本文件的六个 0 是真 0。

> 注：上表第 4 项对照也为 0，说明该词在对照文件里本来就不存在；阳性对照的证明力由第 2 项（16 次）与第 1 项（5 次）承担。

### C.2 完整命令（可直接复跑）

```python
import io
W = [<captain 派单里给出的六个串>]
for p in [r'D:\FPGA_Compelate\reports\plan_v2\COMPLIANCE_AUDIT_V3.md',
          r'D:\FPGA_Compelate\reports\plan_v2\EMERG_SCREEN_RULING.md']:
    t = io.open(p, encoding='utf-8').read()
    print(p.split('\\')[-1], [t.count(w) for w in W])
# 期望：本文件 [0,0,0,0,0,0]；对照 [5,16,3,0,2,0]
```
