# V1_RESIDUE_SWEEP — v1 遗留注释与描述全仓扫描

> 报告编号：VS-V2-01
> 任务：t17（v1 遗留注释与描述全仓扫描：键表过时 / 档位范围过时 / 已废弃模块残留）
> 作者：spec-auditor
> **扫描快照时刻：2026-11-02T15:23:25（UTC+08:00 / China Standard Time）**
> **复核快照时刻：2026-11-02T15:31:10（UTC+08:00）**；**终态补扫时刻：2026-11-02T15:31:39（UTC+08:00）**；**顶层修复快照：2026-11-02T15:36:27（UTC+08:00）** —— 本报告所有行号以这四个时刻为准，逐条注明所属快照
> 纪律声明：本任务**只读 RTL**，唯一写入 = 本文件。未改动任何 `.v` / `.adc` / `.sdc` / `.tcl` / `.ps1`，未改动 `docs/plan_v2/` 下任何定稿正文。

---

## 1. 扫描方法与范围

### 1.1 扫描时刻与文件计数

| 项 | 值 |
|---|---|
| 扫描时刻 | **2026-11-02T15:23:25**（UTC+08:00，记作 S1） |
| 复核时刻 | 2026-11-02T15:31:10（S2）；终态补扫 15:31:39（S3）；**顶层修复快照 15:36:27（S4）** |
| 仓库根 | `D:\FPGA_Compelate`，RTL 根 `D:\FPGA_Compelate\SmartCampusMedia` |
| `rtl/` 下 `.v` 总数 | **67** |
| `sim/testbench/` 下 `.v` 总数 | **78** |
| `scripts/` 下文件总数 | **33**（含 `__pycache__` 2 项）；排除 `__pycache__` 后 **27** |
| v2 权威键表 | `D:\FPGA_Compelate\docs\plan_v2\KEYMAP.md`，411 行，v2.0 / 2026-11-01，自述「唯一权威键位来源」 |

`rtl/` 子目录 `.v` 计数：audio 7、clock 0、common 3、control 5、display 1、input 1、memory 0、osd 8、sensor 3、storage 18、top 3、video 18。

> 说明：t6 时期（2026-11-02 13:35 快照）`rtl/` 为 64 个 `.v`，此后 t7/t8/t16 新增 3 个（`brightness_apply.v` 更早、`pix_mosaic.v`/`ratio_map.v`/`emerg_page.v` 等），总数增至 67。**后续任何人重扫前必须重新计数，不可沿用本报告的 67。**

### 1.2 执行的 grep 命令与命中总数（大小写敏感，同一次快照）

| # | 模式 | 范围 | 命中数 | 文件数 |
|---|---|---|---|---|
| G1 | `KEY[0-9]` | `rtl/**/*.v` | **155** | 15 |
| G2 | `Key[0-9]` | `rtl/**/*.v` | **156** | 12 |
| G3 | `KEY[0-9]` | `sim/testbench/*.v` | **129** | 9 |
| G4 | `Key[0-9]` | `sim/testbench/*.v` | **98** | 7 |
| G5 | `key_code` | `rtl/**/*.v` | **74** | 8 |
| G6 | `key_code` | `sim/testbench/*.v` | **53** | 6 |
| G7 | `KEY[0-9]\|Key[0-9]\|key_code` | `scripts/*.ps1` | **4** | 3 |
| G8 | `16 个键\|16 键\|全部占满\|抢一个键号\|KEY7 亮度\|KEY8 反色\|KEY9 轮播\|0\.\.4\|0~4` | `rtl/**/*.v` | **55** | 17 |
| G9 | 同 G8 | `sim/testbench/*.v` | **18** | 8 |
| G10 | 同 G8 | `docs/plan_v2/*.md` | **24** | 10 |
| G11 | `key_action` | 全仓 | **141** | — |

**G1/G2/G3/G4 的命中逐条判读结果见 §2，无抽样。** G5/G6 的 127 条中，绝大多数是端口连接或 state 定义（`key_matrix_4x4.v:11` 的 `key_code[3:0]` 定义、各级模块的 `input wire [3:0] key_code` 端口），真正含「过时描述」的只有少数几条，已在 §2 逐条列出；其余为「物理定义正确、无需改」的，在本节汇总说明：

- `key_code` 在 `rtl/` 的 74 条按文件：`key_matrix_4x4.v` 15、`dmz_eg4s20_hdmi_top.v` 14、`player_ctrl.v` 12、`dmz_eg4s20_bringup_top.v` 11、`mode_ctrl.v` 7、`dmz_eg4s20_min_top.v` 6、`key_action.v` 6、`key_router.v` 3。
  - **正确 v2 用法（不改）**：`mode_ctrl.v` 7 条、`key_router.v` 3 条、`key_matrix_4x4.v` 15 条（逻辑键号 0~15 的物理定义，v2 铁律 2 明确保留）。
  - **过时**：`dmz_eg4s20_hdmi_top.v:93-94`（内嵌 v1 行号）、`player_ctrl.v` 12 条（v1 键号判定）、`dmz_eg4s20_bringup_top.v` 11 条（v1 键表）、`key_action.v` 6 条（已废弃模块本身）。详见 §2。
- `key_code` 在 `sim/testbench/` 的 53 条：`tb_key_router.v` 19、`tb_player_ctrl.v` 12、`tb_key_matrix_4x4.v` 12、`tb_mode_ctrl.v` 5、`tb_key_action.v` 4、`tb_dmz_eg4s20_bringup.v` 1。前三个 v2 TB 的命中是端口连接，**不改**；`tb_player_ctrl` / `tb_key_action` / `tb_dmz_eg4s20_bringup` 的命中属 v1 用例，见 §2 tb 段。
- `scripts/*.ps1` 的 4 条：`sync_src.ps1` 2（`:61` 注释 + `:64` 白名单项）、`make_test_bmps.ps1` 1、`prepare_board_verify_assets.ps1` 1（后两者为测试图案/素材生成脚本里的键名说明，非键位语义）。详见 §3.1。

### 1.3 v2 权威键表（判定基准，摘自 `docs/plan_v2/KEYMAP.md` §2.1/§2.2/§2.3）

| 键 | v2 功能 | 消费模块 | v1 同键原功能 |
|---|---|---|---|
| Key0 | 上一张 | `media_player.v` | 上一张 ✅ 不变 |
| Key1 | 下一张 | `media_player.v` | 下一张 ✅ 不变 |
| **Key2** | **模式循环** | `mode_ctrl.v` | 自动轮播开关 |
| **Key3** | **应急直达 / 应急确认退出（全状态有效）** | `mode_ctrl.v` | 模式循环 |
| **Key4** | **音频开关 `audio_en`** | `key_router.v` | 上一测试图案 |
| **Key5** | **底部滚动字幕开关 `ticker_en`** | `key_router.v` | 下一测试图案 |
| **Key6** | **亮度 10 档 `bright_lvl[3:0]`（0=最亮 32/32，9=最暗 3/32）** | `key_router.v` | 音频静音 |
| **Key7** | **音量 10 档 `vol_lvl[3:0]`** | `key_router.v` | 亮度 5 档 |
| **Key8** | **内部渲染分辨率 5 档 `res_sel[2:0]`** | `key_router.v` | 反色 |
| **Key9** | **屏占比 5 档 `ratio_sel[2:0]`** | `key_router.v` | 轮播倍率 |
| **Key10** | **音频可视化 `viz_en`** | `key_router.v` | 图库重扫 |
| Key11 | 图库重扫（P2） | `gallery_probe.v` | 九宫格 |
| Key12 | 测试图案循环（P2） | `video_overlay.v` / `test_pattern_gen.v` | 信息条 OSD |
| Key13 | 反色（P2） | `video_overlay.v` | 音频图层 4 态 |
| Key14 | 九宫格（P2） | `video_overlay.v` | 蜂鸣器静音 |
| Key15 | 蜂鸣器静音（P2） | `buzzer_tone.v` | 应急直达 |

**已从 v2 移除的三个键功能**（KEYMAP §2.3，是判定「过时」的重要依据，很多残留正是因为这三个功能已消失但注释仍在）：KEY2 自动轮播开关（改常开）、KEY9 轮播倍率（固定 3 s/张，降级项 **D-02**）、KEY12 信息条 OSD 开关（改参数变化自动弹出）。

**KEYMAP §8 权威 localparam**（`key_router.v` 已全部落地，是「正确 v2 值」的对照基准）：
`K_MODE=4'd2`、`K_EMERG=4'd3`、`K_AUDIO=4'd4`、`K_TICKER=4'd5`、`K_BRIGHT=4'd6`、`K_VOL=4'd7`、`K_RES=4'd8`、`K_RATIO=4'd9`、`K_VIZ=4'd10`、`K_RESCAN=4'd11`、`K_PATTERN=4'd12`、`K_INVERT=4'd13`、`K_GRID=4'd14`、`K_BEEP=4'd15`。

### 1.4 判读标准

- **过时** = 描述与 `docs/plan_v2/KEYMAP.md`（v2 定稿）或用户 m00001 原话矛盾。
- **历史说明** = 明确写了「v1 遗留 / 已废弃 / 以本块为准 / 旧 v1 需求遗留」之类限定语 → 归 ③ 保留。
- 每条格式：`文件:行号 | 原文片段（≤80 字）| 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派对象`。

---

## 2. 逐条清单（三分类）

**三类条数汇总（先给结论）：**

| 类别 | 条数 | 说明 |
|---|---|---|
| **① 必须改** | **46**（A-01 ~ A-46；其中 **A-44/A-45/A-29 已于 15:36:27 修复**，实存 **43 条待办**） | 会误导后来人改错代码（键号写错、位宽写错、档位范围写错、废弃模块被当成活模块），另有 2 条是**真接线错误**（A-44/A-45，编号保留作「接口漂移确实发生过」的案例） |
| **② 可改** | **12**（B-01 ~ B-12） | 纯措辞，不影响代码正确性 |
| **③ 保留** | **9**（C-01 ~ C-09） | 历史说明且有明确「v1/已废弃」标注 |

> 条数口径：按「可独立下发的修改动作」计数。① 里有 4 条是「一处多行」（`osd_autopop.v:9-18` 的 16 行键表算 1 条、`key_action.v:119-126` 的 8 行 localparam 算 1 条、`:45-57` 八键功能表算 1 条、`:102-111` 九行端口注释算 1 条），逐行原始命中数见 §1.2（G1~G11）。
> **① 的分布**：`rtl/` **38 条**（A-01~A-35 共 35 条 + A-44/A-45 两处接线 + A-46）、`sim/testbench/` **8 条**（A-36~A-43）—— 合计 46。
> **✅ 已关闭 3 条**（S4 快照 2026-11-02 15:36:27，rtl-integ 提交）：
> - **A-44 / A-45**（顶层 `osd_panel` / `osd_autopop` 端口漂移）—— 真正修好，`:909/:910` 与 `:860/:861` 已接 `.bright_lvl/.vol_lvl/.res_sel/.ratio_sel`；
> - **A-29**（`dmz_eg4s20_hdmi_top.v:845` 的「按 KEY7 调亮度」）—— 同一次提交顺手改成 `KEY6`。
>
> → **实存待办 43 条**。A-44/A-45 的编号刻意保留，它们是「t16 改端口 / t8 改顶层并行推进导致接口漂移」的证据，对 t11 交接文档有价值；后续人**不要照 S1 行号重复修一遍**。

### 2.1 ① 必须改（46 条编号，**43 待办 + 3 已修**）

#### 2.1.1 `rtl/control/key_action.v`（v1 遗留模块本体）—— 6 条

文件快照：**13,192 B / 2026-11-01 22:27:41 / 195 行**（15:31:10 复核未变）

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-01 | `:102-111` | `output reg [2:0] bright_sel,   // KEY7: 亮度档 0..4（4 = 最暗 50%）` 等 9 行端口注释 | v1 键号 + v1 五档；v2 亮度是 **Key6 十档 4 位**，本模块已废弃 | KEYMAP §2.1 Key6 `bright_lvl[3:0]`；§9.1 十档表 | 整段端口注释替换为：`// 【已废弃】本模块输出全部由 key_router.v 接管；端口注释保留仅供 v1 对照`，并把 `[2:0]/0..4/50%` 改为 `[3:0]/0..9` | rtl-integ + t11 |
| A-02 | `:119-126` | `localparam [3:0] K_BRIGHT = 4'd7;   // KEY7  亮度循环` … `K_BEEP = 4'd14;   // KEY14 蜂鸣器静音` | 8 个键号**全部**与 v2 不符：K_BRIGHT 7→6、K_INVERT 8→13、K_AUTOSW 9→已删、K_RESCAN 10→11、K_GRID 11→14、K_INFO 12→已删、K_LEVEL 13→已删、K_BEEP 14→15 | KEYMAP §8 十四个 localparam | 若保留文件：整块替换为 KEYMAP §8 的值并加 `// 【v2】键号以 KEYMAP §8 为准`；若删除文件：本条随之消失（推荐删除，见 §3.1） | t11（删文件） |
| A-03 | `:128` | `localparam [2:0] BRIGHT_MAX = 3'd4; // 亮度档上限（0..4 共 5 档）` | v2 亮度是 10 档 0..9 | KEYMAP §9.1 | 改为 `localparam [3:0] BRIGHT_MAX = 4'd9; // 亮度档上限（0..9 共 10 档）` | 同上 |
| A-04 | `:4` | `// 所属层次: 控制层 / KEY7~KEY14 扩展键位译码器` | v2 里不存在「KEY7~KEY14 扩展键译码器」这一角色 | KEYMAP §4.1「整块废弃，由 key_router.v 取代」 | 首行加 `// 【v1 遗留·已废弃 2026-11-02】本模块不再被主顶层例化，见 KEYMAP.md §4.1` | t11 |
| A-05 | `:45-57` | `// KEY7~KEY14 八个键的完整分配`（整段功能表） | 八键功能在 v2 里全部重排（亮度→Key6、反色→Key13、重扫→Key11、九宫格→Key14、蜂鸣器→Key15，信息条/电平条/轮播倍率已删） | KEYMAP §2.3 新旧对照 | 整段前加一行 `// ⚠ 下表是 v1 分配，v2 已全部重排，勿据此改代码（见 KEYMAP.md §2.3）` | t11 |
| A-06 | `:168` | 键位译码 always 块内的 `key_code` 比较注释 | 随 A-02 一并失效 | — | 随 A-02 | t11 |

#### 2.1.2 `rtl/control/player_ctrl.v` —— 4 条

文件快照：**34,815 B / 2026-11-01 22:41:21 / 477 行**

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-07 | `:34` | `//     KEY3  = 模式循环: 日常(0) → 科普(1) → 应急(2) → 日常 …` | v2 里模式循环是 **Key2**，Key3 是应急直达 | KEYMAP §2.1 Key2/Key3 | 改为 `//     KEY2  = 模式循环（v2：Key3 已改为应急直达）`；若本模块的 mode 输出已被 mode_ctrl 取代，整表加「v1 遗留」标注 | rtl-integ |
| A-08 | `:35` | `//     KEY15 = 应急直达（任意状态下按下立即进入应急模式）` | v2 里应急直达是 **Key3** | KEYMAP §2.1 Key3「全状态有效」 | 改为 `//     KEY3  = 应急直达（v2；v1 是 KEY15）` | rtl-integ |
| A-09 | `:223` | `localparam K_MODE   = 4'd3;            // KEY3  → 模式循环切换` | **会与 mode_ctrl 抢键号**：v2 的 Key3 = 应急，若 player_ctrl 仍按 K_MODE=4'd3 判定，按 Key3 会同时触发「应急」与「切模式」 | KEYMAP 铁律 1（一键一模块）+ §8 `K_MODE=4'd2` | 若本模块 mode 输出仍在用：改 `localparam K_MODE = 4'd2;`；若已被 mode_ctrl 取代：整行加 `// 【v2】本键已移交 mode_ctrl，此常量不再使用` 并确认无消费点 | rtl-integ |
| A-10 | `:224` | `localparam K_EMERG  = 4'd15;           // KEY15 → 应急直达（最高优先级，任意状态可用）` | 同上，v2 应急是 Key3 | KEYMAP §8 `K_EMERG=4'd3` | 改 `4'd3` 或标注移交 | rtl-integ |

> 附：`:36-38` 的「其余 11 个键（KEY4~KEY14）一律不由本模块译码 / KEY7~KEY14 统一由 rtl/control/key_action.v 译码」属 ②（措辞，见 B-03）。

#### 2.1.3 `rtl/osd/osd_autopop.v` —— 4 条（**本报告最严重的一处**）

文件快照：**t16 连改三轮** —— 15:23:25 为 5,756 B / 124 行 / mtime 2026-10-29 22:26:53；15:31:04 为 137 行；15:31:15 为 156 行；**终态 15:31:39 为 179 行 / mtime 2026-11-02 15:31:39**。下文行号以 **15:31:39 终态快照**为准（该文件头注释 `:9-18`、`:21`、`:31`、`:45`、`:51` 在四版之间行号未变，只有端口段从 `:72-75` 移到 `:105-111`）。

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-11 | `:9-18` | `//   本工程 16 个键**已经全部占满**：` 加 8 行 16 项 v1 键表（`KEY0/1 上一张/下一张 / KEY8 反色 / KEY2 轮播开关 / KEY9 轮播倍率 / KEY3 三态模式 / KEY10 图库重扫 / KEY4/5 测试图案 / KEY11 九宫格 / KEY6 音频静音 / KEY12 信息条 / KEY7 亮度 / KEY13 音频图层 / KEY14 蜂鸣器静音 / KEY15 应急直达`） | **16 个键里 14 个的语义已变**（只有 KEY0/KEY1 不变）；且 v2 后 Key11~Key15 是空闲备用，「全部占满」的立论前提已不存在（KEYMAP §4.2 点名要求改掉这句话）。t16 改了端口却没动这段 | KEYMAP §2.1/§2.2/§2.3 全表 | 整段 `:9-18` 替换为：`//   v2 有 Key0~Key10 共 11 个主功能键，Key11~Key15 为 P2 备用（P2_EN=0 时恒 0）。`<br>`//   本模块的触发源不靠"抢键号"，而是监视参数值变化（见【二】）。`<br>`//   完整键表见 docs/plan_v2/KEYMAP.md §2` | rtl-osd（t16 同批） |
| A-12 | `:31` | `//   于是"按 KEY7 调亮度"这个动作本身就同时完成了两件事：参数变了、画面` | v2 里调亮度是 **Key6**（Key7 是音量）——这句还紧跟 `:25-28` 新写的「监视 7 个参数」，新旧自相矛盾 | KEYMAP §2.1 Key6 | 「KEY7」→「Key6」 | rtl-osd |
| A-13 | `:51` | `//   变化不触发弹窗 —— 用户想看图号时按任意参数键即可，或直接开 KEY12。` | v2 里 **KEY12 信息条开关已被移除**（改参数变化自动弹出，KEYMAP §2.3） | KEYMAP §2.3「信息条 OSD 开关 → 移除按键，改为参数变化自动弹出」 | 删除「或直接开 KEY12」，改为「按键调任一参数即可让面板重新弹出」 | rtl-osd |
| **A-46** | `:45` | `//   osd_pop_req 目前只用于驱动 KEY12 信息条。` | **t16 新写的注释里的新增残留**：KEY12 信息条开关（v1 的 KEY12）在 v2 已整条移除，「信息条」现在是常显（顶层 `wire info_en = 1'b1;`），`osd_pop_req` 的真实消费者只剩图库重扫等场景 | KEYMAP §2.3 + 顶层 `dmz_eg4s20_hdmi_top.v:165` `info_en = 1'b1` | 改为 `//   osd_pop_req 在 v2 只剩少量消费者（如 Key11 图库重扫后的提示）；信息条已改常显（见顶层 info_en = 1'b1），不再由按键开关。` | rtl-osd（t16 同批） |

#### 2.1.4 `rtl/osd/osd_panel.v` —— 6 条（**t16 新写的注释里带旧键号，属新增残留**）

文件快照：**t16 正在改** —— 15:23:25 为 9,509 B / 185 行 / mtime 2026-10-29 22:31:33；15:30:28 为 **247 行**；15:31:10 为 **247 行 / mtime 2026-11-02 15:30:28**。下文行号以 **15:31:10 快照**为准。

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-14 | `:135` | `input  wire [3:0]  bright_lvl,    // KEY7 亮度档 0..9（0 = 最亮 32/32，9 = 最暗 3/32）` | **位宽和档位已改对，键号仍写 KEY7** —— t16 把 3 位改 4 位时顺手抄了旧键号 | KEYMAP §2.1 Key6 | 「KEY7」→「**Key6**」（大小写也统一为 v2 写法 `Key6`） | rtl-osd |
| A-15 | `:137` | `input  wire [2:0]  res_sel,       // Key7 分辨率档 0..4` | 分辨率是 **Key8**，不是 Key7 | KEYMAP §2.1 Key8 | 「Key7」→「Key8」 | rtl-osd |
| A-16 | `:138` | `input  wire [2:0]  ratio_sel,     // Key7 屏占比档 0..4` | 屏占比是 **Key9**，不是 Key7 | KEYMAP §2.1 Key9 | 「Key7」→「Key9」 | rtl-osd |
| A-17 | `:139` | `input  wire        invert_en,     // KEY8 反色` | v2 反色是 **Key13（P2 备用）** | KEYMAP §2.2 Key13 | 「KEY8」→「Key13（P2）」 | rtl-osd |
| A-18 | `:140` | `input  wire [1:0]  auto_sw_sel,   // KEY9 轮播倍率档 0..3` | **轮播倍率功能已被 v2 移除**（固定 3 s/张），端口保留只为不破坏接口 | KEYMAP §2.3 + 降级项 **D-02** | 改为 `// 【v2 已停用】轮播倍率档（D-02：固定 3 s/张，顶层恒接 2'd0）` | rtl-osd |
| A-19 | `:141` | `input  wire [1:0]  info_mode,     // KEY3 三态` | v2 里三态是 **Key2 模式循环**驱动的 `mode`，不是 Key3 | KEYMAP §2.1 Key2 | 改为 `// 模式（v2：由 Key2 模式循环驱动）` | rtl-osd |

> 注：15:23:25 快照的 `:79 bright_sel // KEY7 亮度档 0..4`（旧版核心一条）**已被 t16 在 15:29–15:30 之间改掉**（端口改名为 `bright_lvl`、位宽改 4 位），该条不再计入。但 **旧键号被原样带进了新注释**（A-14），这类「改名时抄旧注释」是本次扫描发现的最典型失效模式，值得在 t11 交付文档里点一句。

#### 2.1.5 `rtl/osd/osd_param_text.v` —— 6 条（同样是 t16 新注释带旧键号）

文件快照：**t16 连改两轮 + t19 后续改动** —— 15:23:25 为 13,380 B / 281 行 / mtime 2026-10-29 22:25:27；15:28:55 为 **324 行**；**17:43:21 复核为 325 行**（t19 同批动过 `gallery_probe.v` 与 `osd_param_text.v`）。下表 `:101-107` 六处在 324 行与 325 行两版上**行号一致，已逐行复核**。

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-20 | `:101` | `input  wire [3:0] bright_lvl,     // KEY7 亮度档 0..9（0 最亮，9 最暗）` | 同 A-14：档位改对了，键号仍 KEY7 | KEYMAP §2.1 Key6 | 「KEY7」→「Key6」 | rtl-osd |
| A-21 | `:103` | `input  wire [2:0] res_sel,        // Key7 分辨率档 0..4` | 分辨率是 Key8 | KEYMAP §2.1 Key8 | 「Key7」→「Key8」 | rtl-osd |
| A-22 | `:104` | `input  wire [2:0] ratio_sel,      // Key7 屏占比档 0..4` | 屏占比是 Key9 | KEYMAP §2.1 Key9 | 「Key7」→「Key9」 | rtl-osd |
| A-23 | `:105` | `input  wire       invert_en,      // KEY8 反色（非 0 才占列）` | 反色是 Key13（P2） | KEYMAP §2.2 Key13 | 「KEY8」→「Key13（P2）」 | rtl-osd |
| A-24 | `:106` | `input  wire [1:0] auto_sw_sel,    // KEY9 轮播倍率档 0..3（显示为 X1..X4，非 0 才占列）` | 轮播倍率已移除（D-02）；且 v2 顶层恒接 `2'd0` → 该列永远不亮，注释却按「可用参数」描述 | KEYMAP §2.3 / D-02 | 改为 `// 【v2 已停用 D-02】轮播倍率档（顶层恒 2'd0，此列恒不显示）` | rtl-osd |
| A-25 | `:107` | `input  wire [1:0] info_mode,      // KEY3 三态：0 日常 / 1 科普 / 2 应急` | 三态由 **Key2 模式循环**驱动 | KEYMAP §2.1 Key2 | 改为 `// 模式（Key2 驱动）：0 日常 / 1 科普 / 2 应急` | rtl-osd |

> 附：15:23:25 快照的 `:47-50`「为什么亮度显示 0..4 而不是 1..5」与 `:254`「`5'd4: char_code = dec_char({1'b0, bright_sel});  // BRI:n 0..4`」**已被 t16 在 15:28 之前重写**（现为 `:48` 的 `B = BRI brightness 亮度档 0..9`、`:288` 的「分辨率/屏占比：3 位 0..4」），不再计入。

#### 2.1.6 `rtl/video/video_overlay.v` —— 2 条

文件快照：**18,875 B / 2026-11-02 14:52:39 / 314 行**（t16 已改，15:31:10 复核未变）

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-26 | `:16` | `//   KEY7   bright_sel  图像层              5 档亮度（100/87.5/75/62.5/50%）` | v2 亮度是 **Key6 十档**，且**亮度运算已整段移出本模块**（改为直通，搬到下游 `brightness_apply.v`） | KEYMAP §2.1 Key6 / §9.1 十档表 | 改为 `//   Key6   bright_sel  （v2 已移出）亮度 10 档由下游 brightness_apply.v 执行，本模块该级直通` | rtl-osd |
| A-27 | `:61` | `//          7..9  = bright_sel[2:0]  （亮度档 0..4）` | 这 3 格是**档位的低 3 位二进制位图**，不是「档位值 0..4」；v2 档位是 0..9，8/9 只显示 mod 8 | KEYMAP §9.1 + 本模块 `:226-228`（`box_lit = bright_sel[0]/[1]/[2]`） | 改为 `//          7..9  = bright_sel[2:0]  （亮度档的**低 3 位二进制位图**；档 0..9 时 8/9 与 0/1 同图；第 4 位不显示，见 KEYMAP §4.1）` | rtl-osd |

#### 2.1.7 `rtl/top/dmz_eg4s20_hdmi_top.v` —— 2 条（**1 已修 + 1 待办**）

文件快照：S1 为 **70,930 B / 2026-11-02 15:24:37 / 1,047 行**（t8 已重写文件头，行号全新）；**S4 为 72,287 B / 2026-11-02 15:36:27 / 1,065 行**（修复 A-44/A-45 的同时也顺手改掉了 A-29，见下）。下文 `:843`/`:845` 两处在 S1 与 S4 之间**行号未变**。

| # | 位置 | 原文片段（S1） | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 / 状态 |
|---|---|---|---|---|---|---|
| A-28 | `:843` | `//   16 个键已全部占满，不能再抢键号（历史事故见 docs/progress.md）。` | v2 后 **Key11~Key15 是空闲备用**，「全部占满」不再成立；KEYMAP §4.2 点名要求改这句 | KEYMAP §2.2 + §4.2 | 改为 `//   v2 有 Key11~Key15 备用，但面板改由 osd_autopop 自动弹出（不需按键，见 KEYMAP §2.4）。` | rtl-integ（t7-B）· **仍未改（S4 复核 `:843` 原文一字未变）** |
| A-29 | `:845` | `//   "按 KEY7 调亮度"这个动作本身就同时完成了调参数 + 文字确认。` | v2 调亮度是 **Key6** | KEYMAP §2.1 Key6 | 「KEY7」→「Key6」 | ✅ **已修复（S4 15:36:27）**：`:845` 现为 `//   "按 KEY6 调亮度"…`，rtl/top 与 project/hdmi 副本一致 |

> **重要**：派单提到的旧行号 `:425-427` 与 `:831` 已随 t8 重写。原「16 个键已全部占满」的文字出现在**两处**：`:803`（**已改写为「v1 的注释理由是…这是旧 v1 需求遗留」→ ③ 保留，见 C-02**）与 `:843`（**仍是旧说法 → ① A-28，未修**）。`KEY7 调亮度` 原在 `:845`（A-29），**S4 已改为 KEY6**。
> 附带观察：文件内 `KEY6`/`Key6` 的其它出现（S4 `:126` `Key6 亮度 0..9`、`:710-713` v1→v2 说明、`:867` `亮度调节（Key6，10 档）`）**全部正确**，说明 rtl-integ 改顶层时是按 v2 键表逐条核过的。

#### 2.1.8 其他 `rtl/` 单点 —— 6 条

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-30 | `rtl/input/key_matrix_4x4.v:16` | `//         hdmi_top 的图案选择器     ← KEY4/KEY5 切换测试图案` | v2 里 Key4=音频、Key5=字幕；测试图案已合并到 **Key12（P2）** | KEYMAP §2.1 Key4/Key5、§2.2 Key12 | 改为 `//         key_router（Key4~Key15）← 本模块只出 key_event + key_code，不认功能` | verifier/rtl-integ |
| A-31 | `rtl/video/audio_waveform.v:2` | `// audio_waveform.v — 音频波形图层（KEY13 第三档）` | v2 波形层由 **Key10 `viz_en`** 单开关控制；KEY13 已是反色；「4 态循环的第三档」这一形态已被 D-03 取消 | KEYMAP §2.3（音频图层 4 态 → Key10 单开关）+ D-03 | 改为 `// audio_waveform.v — 音频波形图层（v2：由 Key10 = viz_en 单开关控制；v1 的 4 态循环见 D-03）` | rtl-osd |
| A-32 | `rtl/audio/pcm_to_pwm.v:34` | `input  wire               mute,         // 静音（KEY6）` | v2 音频开关是 **Key4**；KEY6 是亮度 | KEYMAP §2.1 Key4 | 改为 `// 静音（v2：Key4 音频开关）` | rtl-integ |
| A-33 | `rtl/audio/audio_tone_gen.v:39` | `input  wire        mute,             // 按键静音（KEY6）` | 同上 | KEYMAP §2.1 Key4 | 改为 `// 按键静音（v2：Key4）` | rtl-integ |
| A-34 | `rtl/storage/gallery_probe.v:39 / :52 / :106 / :211`（**S4+ 复核：第 4 处已移到 `:271`**，因 t19 同期改动该文件，346 行 / 17:40:45） | `//     · 可重扫（KEY10，2026-10-26 新增）` / `//     rescan(输入脉冲)  来自 key_action 的 KEY10 重扫请求` / `// —— 重新扫描请求（KEY10）——` / `// ---- 重扫请求（KEY10）: 只在两个终态被采纳 ----` | v2 重扫是 **Key11**，且信号源已从 `key_action.v` 改为 `key_router.v` | KEYMAP §2.2 Key11 + §2.3 | 4 处「KEY10」→「Key11」，`来自 key_action 的`→`来自 key_router 的`（消费者 gallery_probe 不变，仍正确）。**★ 本条已由 captain 转给 rtl-storage 的 t19，与 `target_name`/五个空连接输出同一批改，避免两次动同一文件** | rtl-storage（t19 同批） |
| A-35 | `rtl/top/dmz_eg4s20_bringup_top.v:29-36`（另含 `:181`、`:190`、`:232`、`:284/291/293/294/300/302`、`:385/393`） | `//   键位分配（同一按键不得被两个功能复用 …）:` 整块 v1 键表 + `key_action u_kact (` + `wire [2:0] bright_sel;  // 【亮度档位】0~4` | 这是 **bringup 顶层（独立调试工程）**，整块键表 + 键动作模块都停留在 v1；且它是**全仓唯一还在例化 `key_action` 的顶层** | KEYMAP §2 全表 | 若该工程仍在用：整块键表按 KEYMAP §2 重写（工作量≈重做）；若已归档：文件头加 `// 【v1 遗留·不再维护】本顶层是 2026-10-28 的仿真预演平台，键位与 v2 不符，勿参照` 并在 t11 交付文档登记 | rtl-integ（t7-B）+ t11 |

#### 2.1.9 `sim/testbench/` —— 8 条

| # | 位置 | 原文片段 | 过时原因 | 冲突的 v2 规格 | 建议改法 | 分派 |
|---|---|---|---|---|---|---|
| A-36 | `tb_key_action.v`（13629 B / 2026-10-28 17:47:35 / 304 行，44 处 `KEY[0-9]`：`:2 :10-16 :167-237 :247 :248 :261 :275-280 :298-299`） | `//  K02 KEY7 亮度…` 等整份 v1 用例 | 测的是**已废弃模块**；44 处全是 v1 键号 | KEYMAP §4.1 | 若删 `key_action.v` 则同步删除本 TB；若保留则文件头加「v1 遗留，随 key_action.v 归档」 | verifier（t14/t9） |
| A-37 | `tb_player_ctrl.v`（29852 B / 2026-10-26 23:42:33 / 590 行，43 处：`:16-22 :257-261 :271-272 :297-313 :355-360 :341-348`） | `press_key(4'd15)` / `U08 KEY15 应急直达` / `4'd9`「轮播」/ `4'd7`「亮度」/ `4'd14`「归 key_action」 | 硬编码 v1 键号：15=应急→Key3、3=模式→Key2、9=轮播→已删、7=亮度→Key6、14=蜂鸣器→Key15 | KEYMAP §8 | 用例重写（工作量中等）；短期至少在文件头加「v1 键号，v2 已重排」 | verifier |
| A-38 | `tb_video_overlay.v`（31046 B / 2026-11-01 21:50:17 / 676 行，22 处：`:6 :11-16 :277-279 :293-298 :322-327 :362-364 :382-388 :485-490 :539-544`） | `//   V03 KEY7 亮度五档:  100 / 87.5 / 75 / 62.5 / 50% 的精确像素值` 等 | V03 亮度五档已被 v2 十档取代且移出本模块；V04 KEY8→Key13、V05 KEY11→Key14、V06/V07/V08 KEY12/KEY13 已变 | KEYMAP §2.1/§2.3 | V03 用例改测「本模块亮度级已直通」（这是 v2 的真实契约）；V04~V08 键号更新 | verifier |
| A-39 | `tb_gallery_probe.v`（26124 B / 2026-10-26 23:40:55 / 581 行，7 处：`:61 :355 :503-504 :516 :538 :548`） | `// 重扫请求（KEY10 → gallery_probe.rescan）` 等 | 重扫是 Key11 | KEYMAP §2.2 | 7 处「KEY10」→「Key11」 | verifier |
| A-40 | `tb_hdmi_audio_path.v:264` | `chk(nonzero_cnt == 0, "T4.5 KEY6 mute zeroes samples");` | v2 音频开关是 Key4 | KEYMAP §2.1 Key4 | 字符串改 `"T4.5 Key4 mute zeroes samples"` | verifier |
| A-41 | `tb_osd_autopop.v:143` | `bright_sel = 3'd1;   // 模拟 KEY7 按一下` | v2 调亮度是 Key6；且 t16 已把该端口改名为 `bright_lvl` 4 位，本 TB 仍在写 `bright_sel = 3'd1` | KEYMAP §2.1 Key6 + t16 端口变更 | 改 `bright_lvl = 4'd1; // 模拟 Key6 按一下` | verifier |
| A-42 | `tb_dmz_eg4s20_bringup.v`（9 处：`:8-9 :244 :251 :254 :256 :263 :267 :270`） | v1 bringup 键表说明 | 同 A-35（bringup 顶层整体 v1） | — | 随 A-35 一并处置 | verifier |
| A-43 | `tb_video_content_mux.v`（8,837 B / **2026-11-02 14:59:07** / 168 行）—— 仅两处键号 | `:79 // 现场现象（KEY0/KEY1 切图时竖向白色碎条）就出在这里` / `:106 // 场景 A：刚按 Key2 进科普、视频首帧还没解出来` | 本任务把「含 KEY 字样的行」先列入待核。**复核结论：两处均正确** —— `:79` 是历史现象说明（KEY0/KEY1 语义 v2 未变）、`:106` 的「Key2 进科普」正是 v2 语义（Key2 = 模式循环） | KEYMAP §2.1 Key2 | **无需改**，verifier 复核确认后可关闭本条 | verifier |

#### 2.1.10 连带的两处「接口断裂」（本报告附带发现，非注释问题；**均已修复，留作案例**）

> **★ 状态：A-44 / A-45 已于 2026-11-02 15:36:27 由 rtl-integ 修复（S4 快照）。本小节的条目仍原样保留 —— 它们是「t16 改端口 / t8 改顶层」并行推进导致接口漂移确实发生过的证据，对 t11 交接文档有价值。判定请以 S4 为准，不要照 S1 的行号重复修一遍。**

| # | 位置（S1 → S4） | 事实（S1 15:23:25 时） | 影响 | S4 复核结果 | 状态 |
|---|---|---|---|---|---|
| A-44 | `rtl/top/dmz_eg4s20_hdmi_top.v:889-896` → **S4 `:905-914`** | `osd_panel u_osd_panel ( … .bright_sel(bright_sel), .invert_en(invert_en), .auto_sw_sel(auto_sw_sel), .info_mode(mode), …)` —— 但 t16 已把 `osd_panel` 端口改名为 **`bright_lvl[3:0]`** 并新增 `vol_lvl / res_sel / ratio_sel` | Verilog 里按名连接的**未知端口名会被忽略**，`.bright_sel(...)` 不再对应任何端口 → `bright_lvl` 输入悬空（Z），面板亮度显示失效且**编译不报错**（部分工具只告警） | **已修**：`:909 .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),` / `:910 .res_sel(res_sel), .ratio_sel(ratio_sel),` | ✅ **已修复 2026-11-02 15:36:27（rtl-integ）** |
| A-45 | `rtl/top/dmz_eg4s20_hdmi_top.v:847-851` → **S4 `:857-864`** | `osd_autopop #(…) u_osd_pop ( .clk, .rst_n, .bright_sel(bright_sel), .invert_en, .auto_sw_sel, .info_mode(mode), .panel_on)` —— 但 t16 已把 `osd_autopop` 输入改为 `bright_lvl / vol_lvl / res_sel / ratio_sel / invert_en / auto_sw_sel / info_mode`（7 个监视源） | 同上：`bright_sel` 端口不存在 → `bright_lvl` 悬空；且音量/分辨率/屏占比的变化**不会触发弹窗**（KEYMAP §2.4 要求「7 个键任一按下都弹」） | **已修**：`:860 .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),` / `:861 .res_sel(res_sel), .ratio_sel(ratio_sel),` | ✅ **已修复 2026-11-02 15:36:27（rtl-integ）** |

**S4 修复凭据（本报告实测，非转述）**：
- `SmartCampusMedia\rtl\top\dmz_eg4s20_hdmi_top.v` 与 `SmartCampusMedia\project\hdmi\dmz_eg4s20_hdmi_top.v` **均为 72,287 B / mtime 2026-11-02 15:36:27 / 1,065 行，SHA256 均为 `B24E5089D3903C556D8F3A1A514F7E4F77EDE2409C1B347295F8A0C5A475EA18`（字节一致）**。
- 第三路 `video_overlay` 仍接 3 位 `bright_sel`（S4 `:822 .bright_sel(bright_sel), .invert_en(invert_en),`）—— **这是正确的，不是漏改**：顶层 `:890-898` 新增了一整段说明「`brightness_apply.bright_lvl` 吃全 4 位（0..9 十档）；`video_overlay.bright_sel` 只吃低 3 位（只能表示 0..7，用于点亮信息条第 8/9/10 格 —— 那三个格子编码的是『档位高低』而不是精确值）。接反 = 双重变暗，而且只有暗档位看得出来」，与本报告 §3.4 的判断完全一致（`bright_sel[0]/[1]/[2]` 是位图不是数值）。
- 计数影响：① 编号 46 条中 **2 条已关闭**（A-44/A-45）。

> 原判断保留在此备查：A-44/A-45 是 t16（OSD 侧改端口）与 t8（顶层例化）并行推进时的典型接口漂移，**不是注释问题**，当时若不改，v2 的参数面板功能整体失效且不报错。

### 2.2 ② 可改（12 条，纯措辞）

| # | 位置 | 原文片段 | 为什么不影响代码 | 建议改法 | 分派 |
|---|---|---|---|---|---|
| B-01 | `rtl/input/key_matrix_4x4.v:70` | `//     键号: KEY(行 r, 列 c) = 4*r + c，即 KEY0 ~ KEY15` | 物理编号规则 v1/v2 一致（KEYMAP 铁律 2：逻辑键号与物理位置解耦） | 保持；可在末尾加「（键号的**功能**归属见 KEYMAP.md §2）」 | 不改或 rtl-integ |
| B-02 | `rtl/control/key_router.v:32` | `//   历史事故：改造前 KEY0/KEY1 曾被播放控制与测试图案选择器同时判定，` | 历史说明，无功能指向 | 保持原样 | — |
| B-03 | `rtl/control/mode_ctrl.v:21` | `//   歧义甚至多驱动 —— 这是本工程历史上真实发生过的事故（KEY0/KEY1 曾被` | 同上 | 保持原样 | — |
| B-04 | `rtl/control/player_ctrl.v:36-38` | `//        KEY4/KEY5 测试图案、KEY6 音频静音在顶层 hdmi_top 内直接消费；KEY7~KEY14 统一由 rtl/control/key_action.v 译码` | 描述的是「别的模块干什么」，本模块代码不依赖；但**指向的模块已废弃** | 改为 `// v2：Key4~Key15 统一由 key_router.v 译码（key_action.v 已废弃）` | rtl-integ |
| B-05 | `rtl/control/player_ctrl.v:42-43 / :58 / :178 / :181-182 / :241 / :263 / :274 / :285 / :321 / :423 / :427 / :432` | `// KEY9（轮播档位）是个例外形态…键位译码仍在 key_action 内` 等（12 处） | 讲的是 `auto_sw_sel` 端口语义，v2 里该端口仍存在（顶层恒接 2'd0） | 批量把「key_action」→「key_router（v2）」；「KEY9」→「Key9（v2 已停用 D-02）」 | rtl-integ |
| B-06 | `rtl/video/video_overlay.v:93` | `input  wire        wave_en,      // KEY13 4 态：波形层开关` | 端口名与功能仍有效（顶层接 `viz_en`），只是键号旧 | 改为 `// Key10（viz_en）：波形层开关` | rtl-osd |
| B-07 | `rtl/video/video_overlay.v:79 / :83 / :148 / :158 / :171 / :183 / :203 / :297` | `// —— KEY7 / KEY8: 图像层 ——`、`// 第三级-A: 九宫格参考线（KEY11）` 等 8 处分节标题 | 只是给段落起名，代码语义正确 | 批量替换键号：KEY7→Key6、KEY8→Key13、KEY11→Key14、KEY12→（已删）、KEY13→Key10 | rtl-osd |
| B-08 | `rtl/osd/osd_param_text.v:9` | `//   改造前参数只能靠 KEY12 的 12 格二进制位图条表达 ——` | 明确写「改造前」，属历史对比；但 KEY12 已不是信息条键 | 改为 `//   改造前参数只能靠 12 格二进制位图条（v1 的 KEY12 信息条开关）表达 ——` | rtl-osd |
| B-09 | `rtl/top/dmz_eg4s20_hdmi_top.v:93-94` | `//     :84/:85  key_code==4 / ==5 → pattern_sel（测试图案上/下一张）` `//     :402     key_code==6       → audio_muted（音频静音）` | 讲的是**已删代码**的 v1 行号，本身是历史说明（③），但内嵌行号在 v1 文件里才有效，当前文件 `:84` 是注释表、`:402` 已是别的内容 | 在 `:92` 前加 `//   （下列行号指 v1 版本 dmz_eg4s20_hdmi_top.v，当前文件已无对应代码）` | rtl-integ |
| B-10 | `rtl/storage/pix_reader.v:60 / :64-67 / :143 / :237 / :277` | `// 有效列号；Key9 水平窗口判据（v3）`、`// Key9 窗口宽：本步唯一驱动水平降采样的参数` 等 8 处 | 代码正确；只是把 Key9 说成「水平降采样驱动源」，与 ARCH §4「Key8=抽样、Key9=窗口」的分工表述重叠（本模块确实吃 `win_w`） | 改为 `// Key9 屏占比窗口（ratio_map 输出 win_*）`，避免与 Key8 抽样混淆 | rtl-storage |
| B-11 | `scripts/sync_src.ps1:61` | `# key_action 是 KEY7~KEY14 的唯一译码点（顶层不再单独消费这 8 个键号）；` | 白名单条目本身仍有效（文件还在同步） | 改为 `# 【v1 遗留】key_action.v 已废弃（KEYMAP §4.1），下一轮清理时连同本行一起删` | rtl-integ + t11 |
| B-12 | `scripts/sync_src.ps1:64` 白名单项 / `sim/scripts/run_frontend_regression.ps1:32 :40 :136` | `'rtl\control\key_action.v' = @('project\hdmi\key_action.v')`、`@{name='key_action'; top='tb_key_action'; …}` | 只是登记，不影响综合 | 与 §3.1 的删除决策绑定：删文件时同步删这 4 处登记 | rtl-integ + verifier |

### 2.3 ③ 保留（9 处，已有明确「v1/已废弃/历史」标注）

| # | 位置 | 原文（摘要） | 保留理由 |
|---|---|---|---|
| C-01 | `rtl/top/dmz_eg4s20_hdmi_top.v:83-99` | `// 键位分配总表（v2，见 docs/plan_v2/KEYMAP.md §8）` + 【v1 → v2 删掉了什么，为什么】 | **已是正确的 v2 版**，且明确标注 `v2` 与 `v1 → v2`；是本次扫描里最规范的样板 |
| C-02 | `rtl/top/dmz_eg4s20_hdmi_top.v:802-810` | `// 【v1 → v2：caption_en 从硬接 1'b1 改为 ticker_en_eff】` + 「v1 的注释理由是「16 个键已全部占满…」——这是**旧 v1 需求遗留**」 | 自带「旧 v1 需求遗留」限定语，正是「历史说明」标准形态 |
| C-03 | `rtl/top/dmz_eg4s20_hdmi_top.v:103-104` | `// 只认 K_MODE=3 / K_EMERG=15 两个 v1 键号，而 v2 的规格是 Key2/Key3` | 明确对比 v1/v2，属解释性历史说明 |
| C-04 | `rtl/top/dmz_eg4s20_hdmi_top.v:155-166` | `// ---- key_action 删除后的三个无替身信号（附录 C 裁定，逐条有理由）-----` | 明确写「key_action 删除后」，且逐条给出 D-02/D-03 降级项编号 |
| C-05 | `rtl/control/key_action.v:16-26` | `// 【v1 → v2 错位对照表】亮度 KEY7↔Key6、反色 KEY8↔Key13、轮播间隔 KEY9 已删除…` | 显式 v1/v2 对照表，是**判断其它残留的权威索引**，务必保留 |
| C-06 | `rtl/video/video_overlay.v:23-37` | `//   **KEY3 为什么需要常显标记**（2026-10-29 修复）` | 带日期与「修复」标注的历史段 |
| C-07 | `docs/plan_v2/KEYMAP.md:21-44` | `## 1. 现行键位（v1，2026-10-26 版，即将废弃）` 整张 v1 表 + `:44` 注 | 标题已写「v1…即将废弃」，且在 `docs/plan_v2/` 内属 arch-lead 域，本任务不改；这正是 v1 键表的**归档位置** |
| C-08 | `docs/plan_v2/KEYMAP.md:113-130` | §3「新旧对照」16 行表 +「16 键中仅 2 键（Key0/Key1）语义不变，14 键（87.5%）变更」 | 权威对照表，③ 保留 |
| C-09 | `sim/testbench/tb_video_content_mux.v:79` | 历史现象说明（v2 断言仍成立） | 解释性注释，无键号误导 |

> 另有大规模 ③ 保留但**不在本任务判定范围**的：`SmartCampusMedia/docs/` 下 `ai_handover.md`、`keymap_2026-10-26.md`、`progress.md`、`TASKS.md`、`ARCHITECTURE.md`、`board_verification_2026-10-27.md` 等历史归档文档（`key_action` 命中集中地）——**全部按归档只读处理，不动**。

---

## 3. 五项特别核对

### 3.1 `rtl/control/key_action.v` 的定位与去留

**结论：现在不是「完全无例化者」—— 全仓还有一个顶层在例化它，因此不能在 t11 直接删文件。**

`grep -rn 'key_action'` 全仓 141 处，按性质分：

| 性质 | 位置 | 判定 |
|---|---|---|
| **仍在例化的顶层** | `rtl/top/dmz_eg4s20_bringup_top.v:190  key_action u_kact (` | **唯一的活例化者**（bringup 调试顶层，mtime 2026-10-28 17:47:35） |
| 仓库根裁剪副本 | `_crop/dmz_top_with_hdmi_audio_off.v:79` / `:101` | 非 `rtl/` 域，归档副本 |
| 主顶层已删 | `rtl/top/dmz_eg4s20_hdmi_top.v` —— `u_kact` **0 命中**，只有 `:155-156` 的历史说明 | ✅ t8 已按 KEYMAP §4.1 删除 |
| 模块自述 | `rtl/control/key_action.v:2 :3 :28 :95 module key_action (` | 模块本体 |
| 取代声明 | `rtl/control/key_router.v:4`（「取代 rtl/control/key_action.v」） | ✅ 正确 |
| 纯注释引用 | `player_ctrl.v:38 :43 :58 :178 :181 :432`、`gallery_probe.v:52`、`video_overlay.v:31 :90` | 见 ①/② 各条 |
| **构建脚本仍登记** | `scripts/sync_src.ps1:61`（注释）+ **`:64` `'rtl\control\key_action.v' = @('project\hdmi\key_action.v')`** | 白名单未清 |
| **回归脚本仍跑它的 TB** | `sim/scripts/run_frontend_regression.ps1:32`（源列表）、`:40`（TB 列表）、**`:136` `@{name='key_action'; top='tb_key_action'; marker='ALL CHECKS PASSED: key_action'}`** | 回归仍在跑废弃模块 |
| TD 工程编译顺序 | `SmartCampusMedia/project/hdmi_td.al:262  <File Path="hdmi/key_action.v">`（第 29 位） | 仍参与编译 |
| 文档 | `docs/plan_v2/KEYMAP.md:34-41`（v1 历史表，③）、`:44`、`:140`；`RESOURCE_BUDGET.md:103/112/122`（当基线引用，③）；`T7_INTEGRATION_PLAN.md:199/580/611/662/737/738/1194`、`T1_TO_T7_WIRING.md:448`、`T5_CONTROL_SENSOR.md:411`、`REQ_GAP.md:19/303/304`（**仍描述「顶层还在用 u_kact」/「仅改 key_action.v 的译码表」→ 已过期，属 arch-lead 域**） |

**建议的去留方案（两选一，推荐方案 A）：**

- **方案 A（推荐）· 归档不删除**：`key_action.v` 与 `tb_key_action.v` 保留在树内，文件头加 `// 【v1 遗留·已废弃 2026-11-02】主顶层已改用 key_router.v（KEYMAP §4.1）；本文件仅供 bringup 调试工程与历史对照`；同时把 `sync_src.ps1:64` 白名单项与 `run_frontend_regression.ps1:136` 的用例**降级为可选**（加 `-SkipKeyAction` 开关或从默认列表移除）。理由：删文件要先改 `hdmi_td.al` 编译顺序与 bringup 顶层，风险大于收益；而「归档 + 标注」已能消除「后来人当活模块改」的风险。
- **方案 B · 彻底删除**：前置条件是先改 `rtl/top/dmz_eg4s20_bringup_top.v`（去掉 `:190` 例化、`:29-36` 键表、`:176-188` 八个 wire），再删 `sync_src.ps1:64`、`run_frontend_regression.ps1:32/40/136`、`hdmi_td.al:262` 四处登记，最后删 `key_action.v` + `tb_key_action.v` + `project/hdmi/key_action.v` 副本。**建议排在 t11，且必须先确认 bringup 工程是否仍在验收范围**（若 bringup 已归档，则可直接连 `dmz_eg4s20_bringup_top.v` 一起归档）。

### 3.2 `rtl/osd/osd_autopop.v` 头注释键表逐行对照

文件快照：**15:31:39 终态 / 179 行**（t16 已把端口扩为 7 监视源，但**文件头 `:9-18` 的键表一字未改**）。下表逐行对照（**16 行键表里 14 行过时，仅 KEY0/KEY1 正确**；`:9-18` / `:21` / `:31` / `:45` / `:51` 在 t16 的 124→137→156→179 四版之间行号未变，可放心引用）：

| 行 | v1 说法（原文） | v2 实际（KEYMAP） | 判定 |
|---|---|---|---|
| `:11` 左 | `KEY0/1  上一张/下一张` | Key0/Key1 上一张/下一张 | ✅ **正确** |
| `:11` 右 | `KEY8   反色` | Key8 = 分辨率 5 档；反色 → Key13(P2) | ❌ 过时 |
| `:12` 左 | `KEY2    轮播开关` | Key2 = **模式循环**；轮播开关已移除（改常开） | ❌ 过时 |
| `:12` 右 | `KEY9   轮播倍率` | Key9 = **屏占比 5 档**；轮播倍率已移除（D-02） | ❌ 过时 |
| `:13` 左 | `KEY3    三态模式` | Key3 = **应急直达/确认退出**；模式循环 → Key2 | ❌ 过时 |
| `:13` 右 | `KEY10  图库重扫` | Key10 = **音频可视化**；图库重扫 → Key11(P2) | ❌ 过时 |
| `:14` 左 | `KEY4/5  测试图案` | Key4 = **音频开关**、Key5 = **底部字幕开关**；测试图案 → Key12(P2) 合并单键 | ❌ 过时 |
| `:14` 右 | `KEY11  九宫格` | Key11 = **图库重扫**；九宫格 → Key14(P2) | ❌ 过时 |
| `:15` 左 | `KEY6    音频静音` | Key6 = **亮度 10 档**；音频 → Key4 | ❌ 过时 |
| `:15` 右 | `KEY12  信息条` | Key12 = **测试图案**；信息条开关**已移除**（改自动弹出） | ❌ 过时 |
| `:16` 左 | `KEY7    亮度` | Key7 = **音量 10 档**；亮度 → Key6 | ❌ 过时 |
| `:16` 右 | `KEY13  音频图层` | Key13 = **反色(P2)**；音频图层 → Key10 单开关（D-03） | ❌ 过时 |
| `:17` | `KEY14  蜂鸣器静音` | Key14 = **九宫格(P2)**；蜂鸣器静音 → Key15(P2) | ❌ 过时 |
| `:18` | `KEY15  应急直达` | Key15 = **蜂鸣器静音(P2)**；应急直达 → Key3 | ❌ 过时 |
| `:9` | `本工程 16 个键**已经全部占满**：` | v2：Key0~Key10 为主功能、**Key11~Key15 为空闲备用** | ❌ 过时（KEYMAP §4.2 点名） |
| `:20-21` | `再抢任何一个键都会违反"一个键号只有一个消费者"的既有原则` | 原则本身 v2 仍成立（铁律 1），但「再抢一个键」的前提消失 | ② 可改（保留原则、删前提） |
| `:31` | `按 KEY7 调亮度` | Key6 | ❌ 过时 → **A-12** |
| `:45` | `osd_pop_req 目前只用于驱动 KEY12 信息条`（t16 **新写**） | 信息条已改常显（顶层 `info_en = 1'b1`），KEY12 已是测试图案 | ❌ 过时 → **A-46（新增残留）** |
| `:51` | `或直接开 KEY12` | 信息条开关已移除 | ❌ 过时 → **A-13** |

**顺带记一句（不属本任务范围，但影响 t10 合规）**：KEYMAP §2.4 要求「Key6/Key7/Key8/Key9/Key4/Key5/Key10 任一按下，面板显示 2.5 s」。t16 已把本模块输入端扩到 `bright_lvl / vol_lvl / res_sel / ratio_sel / invert_en / auto_sw_sel / info_mode`（**终态 `:105-111`**，15:31:15 的 156 行版在 `:82-88`），但**仍无 `key_event` 输入**，所以「按下但值未变」（例如 9 档按到 0 之前的重复按同一档、或 Key4/Key5 这类开关类按键的某一侧）不会触发弹窗。这与 v2 规格的差距需 t10/t16 判定是否可接受（当前实现是「值变化触发」，覆盖了绝大多数用户可感场景）。

### 3.3 `rtl/osd/osd_panel.v` / `rtl/osd/osd_param_text.v` 的档位范围描述

**⚠ t16 正在实时修改这两个文件，观测到的 mtime 序列（同一次会话内）：**

| 文件 | 15:23:25 快照 | 中间态 | 终态快照 |
|---|---|---|---|
| `osd_panel.v` | 9,509 B / 185 行 / **2026-10-29 22:31:33** | 15:29:50 → 203 行；15:30:03 → 226 行 | **247 行 / 2026-11-02 15:30:28** |
| `osd_param_text.v` | 13,380 B / 281 行 / **2026-10-29 22:25:27** | — | **324 行 / 2026-11-02 15:28:55** |
| `osd_autopop.v` | 5,756 B / 124 行 / **2026-10-29 22:26:53** | 15:31:04 → 137 行；15:31:15 → 156 行 | **179 行 / 2026-11-02 15:31:39** |

→ **本报告三节的行号只能对应 15:23:25 / 15:28:55 / 15:30:28 / 15:31:39 这几个时刻；t16 落地后必须重扫**（`grep -n 'KEY[0-9]\|Key[0-9]' rtl/osd/*.v` 一行即可复核）。

**档位范围描述的现状（t16 终态快照）：**

| 项 | t16 之前（v1 残留） | t16 之后（当前） | 判定 |
|---|---|---|---|
| 亮度位宽 | `input wire [2:0] bright_sel`（3 位，只能表 0..7） | `input wire [3:0] bright_lvl`（4 位，0..9） | ✅ **已修正**（t16） |
| 亮度档位 | `// 0..4`（5 档） | `// 0..9（0 = 最亮 32/32，9 = 最暗 3/32）` | ✅ **已修正** |
| 亮度键号 | `// KEY7` | 仍写 `// KEY7`（`osd_panel.v:135`、`osd_param_text.v:101`） | ❌ **未修正 → A-14 / A-20** |
| 音量/分辨率/屏占比 | 不存在这三个参数 | t16 新增 `vol_lvl / res_sel / ratio_sel` 三个端口 | ✅ 新增；但注释键号写成 `Key7 / Key7 / Key7`（分别应为 Key7 / **Key8** / **Key9**）→ **A-15/A-16、A-21/A-22** |
| 反色键号 | `// KEY8` | 仍 `// KEY8`（应为 Key13） | ❌ → A-17 / A-23 |
| 轮播倍率 | `// KEY9 轮播倍率档 0..3` | 仍 `// KEY9 轮播倍率档`（应标 D-02 已停用） | ❌ → A-18 / A-24 |
| 三态键号 | `// KEY3 三态` | 仍 `// KEY3`（应为 Key2） | ❌ → A-19 / A-25 |
| 「为什么亮度显示 0..4」长注释 | `osd_param_text.v:47-50` | **已重写**为 `:47-51` 的 `B = BRI brightness 亮度档 0..9` 四行标签表（`:48` B / `:49` V / `:50` R / `:51` P） | ✅ 已修正 |
| 十进制显示逻辑 | `5'd4: dec_char({1'b0, bright_sel})`（3 位零扩展，最大只到 7） | `:286-291`：`5'd2: dec_char(bright_lvl)` / `5'd6: dec_char(vol_lvl)`（4 位全值）+ `:289` 注释「分辨率/屏占比：3 位 0..4，零扩展到 dec_char 的 4 位输入」 | ✅ 已修正 |

> **⚠ 本节行号的时效说明**：`osd_param_text.v` 在 15:28:55（324 行）之后又被 **t19** 于 **17:39:40 / 17:43:21（325 行）** 动过（同批改动含 `gallery_probe.v`）。上表 `:47-51`、`:101-107`、`:286-291` 三处引用已在 325 行版本上逐一复核**仍然正确**；但若 t19 之后继续编辑该文件，`grep -n 'KEY[0-9]\|Key[0-9]' rtl/osd/osd_param_text.v` 可一行复核。

> **t16 遗留的真实问题**：`osd_panel.v` / `osd_param_text.v` 的端口已改成 `bright_lvl[3:0]`，但**顶层 `dmz_eg4s20_hdmi_top.v:893` 仍写 `.bright_sel(bright_sel)`**（A-44），`osd_autopop` 例化（`:849`）同理（A-45）。这两处不改，t16 的改动等于没生效。

### 3.4 `rtl/video/video_overlay.v` 的 `bright_sel[0]/[1]/[2]`

**结论：`bright_sel[0]/[1]/[2]` 是「用 3 个格子编码亮度档的二进制位图」，不是「显示亮度档数值」—— 注释把它写得像后者，扩成 4 位会破坏 12 格布局。**

实测（文件快照 18,875 B / 2026-11-02 14:52:39 / 314 行）：

- `:58-63` 信息条位序表：`格号 0..4 = img_index[4:0]`、`5..6 = mode[1:0]`、**`7..9 = bright_sel[2:0]  （亮度档 0..4）`**、`10..11 = auto_sw_sel[1:0]`。
- `:213 wire [3:0] box_idx = bd_x[6:3];` —— 格号只有 4 位，**共 12 格（0..11）已排满**：0..4 图号、5..6 模式、7..9 亮度、10..11 倍率。
- `:226-228` `4'd7: box_lit = bright_sel[0];  4'd8: box_lit = bright_sel[1];  4'd9: box_lit = bright_sel[2];` —— **每一位点一个格子**，是二进制位图显示，不是数值显示。
- `:231 default: box_lit = 1'b0;  // 超出 12 格: 不画（右侧留白）`。
- 端口 `:80`：`input wire [2:0] bright_sel, // v2: 仅用于信息条亮度格显示（接 bright_lvl[2:0]）` —— 已注明「接 `bright_lvl[2:0]`」，与顶层 `:163 wire [2:0] bright_sel = bright_lvl[2:0];` 一致。

**三条必须留给 t16 的结论：**
1. **不能扩成 4 位**：`box_idx` 已占满 12 格（`auto_sw_sel[1:0]` 占 10..11），第 4 位没有格子可用；硬扩会把倍率格挤掉或越界。
2. **档 8/9 与档 0/1 显示相同**（`bright_lvl[2:0]` 截断），这是已知且可接受的降级：格子的语义是「档位高低的大致指示」，不是精确数值；精确数值由 `osd_param_text` 的 `B:n` 文本给出（`BRI` 列显示 0..9 全值）。
3. **注释要改**（A-27）：`:61` 的「（亮度档 0..4）」应改为「（亮度档的低 3 位二进制位图；档 0..9 时 8/9 与 0/1 同图）」，否则后来人会以为「这三位就是档位值，扩成 4 位更精确」而改错。

### 3.5 `docs/plan_v2/KEYMAP.md` 自身有无 v1 残留

文件快照：**411 行 / mtime 2026-11-02 14:43:20**。

**结论：无「未标注的」v1 残留。** 全部 70 处 `KEY[0-9]` 命中分三类，均有明确标注：

| 区段 | 内容 | 判定 |
|---|---|---|
| `:21-44` | `## 1. 现行键位（v1，2026-10-26 版，即将废弃）` 整张 16 行 v1 表 + `:44` 注「v1 的 16 个键位全部占用，无空闲键」 | ③ 保留（标题已标 v1+即将废弃，且是 v1 键表的**唯一归档位**） |
| `:50-130` | §2.1/§2.2/§2.3（v2 表 + 被移除功能表）、§3 新旧对照 16 行 | ✅ v2 权威正文，`KEYx` 出现是**对照左列**，不是残留 |
| `:277-314` | §8 权威 localparam（`K_MODE=4'd2` … `K_BEEP=4'd15`，14 行） | ✅ 全部 v2 正确值，与 `key_router.v:116-127` 逐值一致 |
| `:405 / :409` | §10 自检「16 个键是否全部有归属 \| 是。Key0~Key10 为 P0 主功能，Key11~Key15 为 P2 备用」 | ✅ **已明确否定了 v1 的「全部占满」说法** |

**唯一可改进处**（属 arch-lead 域，不属本任务）：`:44` 的「v1 的 16 个键位全部占用，无空闲键」建议加一句「（v2 起 Key11~Key15 改为 P2 备用，见 §2.2）」，因为该句单独被摘出来引用时仍会误导。

**KEYMAP 域内真正过期的是别的文档**（供 arch-lead 参考，本任务不改）：
- `docs/plan_v2/T7_INTEGRATION_PLAN.md:199 / :580 / :611 / :662 / :737 / :738 / :1194` —— 仍按「顶层还有 `u_kact`、key_action 是活模块」描述集成步骤。
- `docs/plan_v2/T1_TO_T7_WIRING.md:448`、`T5_CONTROL_SENSOR.md:411` —— 同上。
- `reports/plan_v2/REQ_GAP.md:19 / :303 / :304` —— 仍写「仅改 `key_action.v` 的译码表即可」，已被 v2（新建 `key_router.v`）取代。
- `docs/plan_v2/RESOURCE_BUDGET.md:103 / :112 / :122` —— 把 `key_action` 当资源基线（③ 可保留，但建议加「已废弃」注）。

---

## 4. 按文件域分派建议表

| 文件（域） | ① 必须改 | ② 可改 | ③ 保留 | 建议交给 | 备注 |
|---|---|---|---|---|---|
| `rtl/osd/osd_autopop.v` | **4**（A-11/12/13/46） | 0 | 0 | **rtl-osd（t16 同批合并）** | 头注释 16 行键表整段重写，最严重；t16 正在改，趁同一批最省。A-46 是 t16 本轮新写进 `:45` 的残留 |
| `rtl/osd/osd_panel.v` | **6**（A-14~A-19） | 0 | 0 | **rtl-osd（t16 同批）** | t16 新注释抄了旧键号，**趁收尾一并改**，否则新文件带着新残留 |
| `rtl/osd/osd_param_text.v` | **6**（A-20~A-25） | 1（B-08） | 0 | **rtl-osd（t16 同批）** | 同上 |
| `rtl/video/video_overlay.v` | **2**（A-26/27） | 9（B-06/B-07） | 1（C-06） | rtl-osd | `:61` 位图说明是最容易改错的一条 |
| `rtl/video/audio_waveform.v` | **1**（A-31） | 0 | 0 | rtl-osd | 单行 |
| `rtl/control/key_action.v` | **6**（A-01~A-06） | 0 | 1（C-05） | **t11（删文件/归档）** | 见 §3.1：先决定去留，再决定改不改注释 |
| `rtl/control/player_ctrl.v` | **4**（A-07~A-10） | 1（B-05，含 12 处） | 0 | rtl-integ | `K_MODE=4'd3`/`K_EMERG=4'd15` 有抢键号风险，**优先级高于纯注释** |
| `rtl/control/key_router.v` | 0 | 1（B-02） | 0 | — | **零 v1 残留**，可作为其它模块的样板 |
| `rtl/control/mode_ctrl.v` | 0 | 1（B-03） | 0 | — | 同上 |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | **1 待办**（A-28）+ **3 已修**（A-29 / A-44 / A-45，S4 15:36:27） | 1（B-09） | 3（C-01~C-04） | **rtl-integ（t7-B）** | A-44/A-45 不是注释而是接线错误，**已于 15:36:27 修复**；A-29 同批改掉；仅剩 A-28 一行（`:843` 的「16 个键已全部占满」） |
| `rtl/top/dmz_eg4s20_bringup_top.v` | **1**（A-35，含 19 处） | 0 | 0 | rtl-integ（t7-B）+ t11 | 若该工程已归档，改为「文件头加 v1 遗留标注」即可 |
| `rtl/storage/gallery_probe.v` | **1**（A-34，含 4 处） | 0 | 0 | rtl-storage | KEY10→Key11 |
| `rtl/storage/pix_reader.v` | 0 | 1（B-10，含 8 处） | 0 | rtl-storage | 低优先 |
| `rtl/input/key_matrix_4x4.v` | **1**（A-30） | 1（B-01） | 0 | verifier / rtl-integ | `:16` 一行 |
| `rtl/audio/pcm_to_pwm.v`、`audio_tone_gen.v` | **2**（A-32/A-33） | 0 | 0 | rtl-integ | 各一行 |
| `docs/plan_v2/*.md` | 0（`KEYMAP.md` 无未标注残留） | 0 | 2（C-07/C-08） | **arch-lead** | 真正过期的是 `T7_INTEGRATION_PLAN.md` / `T1_TO_T7_WIRING.md` / `T5_CONTROL_SENSOR.md` / `REQ_GAP.md` / `RESOURCE_BUDGET.md`（见 §3.5） |
| `sim/testbench/*.v` | **8**（A-36~A-43） | 0 | 1（C-09） | **verifier（t14/t9）** | `tb_key_action.v` 整份随 A-35 处置；`tb_player_ctrl.v` 需重写用例 |
| `scripts/sync_src.ps1`、`sim/scripts/run_frontend_regression.ps1` | **0（随 A-35 联动）** | 2（B-11/B-12） | 0 | rtl-integ + verifier | 与 §3.1 的去留决策绑定 |
| **合计** | **43 待办 + 3 已修 = 46** | **12** | **9** | — | A-44/A-45/A-29 已于 S4（15:36:27）关闭，编号保留作案例 |

### 4.1 建议的执行顺序（按风险/成本比排序）

1. **P0 · 接线类 —— ✅ 已修复（留作案例，不要重复修）**：A-44、A-45（顶层 `osd_panel` / `osd_autopop` 端口名与 t16 新端口不匹配，功能曾静默失效）→ **rtl-integ 已于 2026-11-02 15:36:27 修复**（S4：`:860`/`:909` 已接 `.bright_lvl/.vol_lvl/.res_sel/.ratio_sel`，rtl/top 与 project/hdmi 副本 72,287 B SHA256 一致）。保留作「接口漂移确实发生过」的案例，供 t11 交接文档引用。
2. **P0 · 抢键号类**：A-09、A-10（`player_ctrl` 的 `K_MODE=4'd3` / `K_EMERG=4'd15` 与 `mode_ctrl` 冲突，违反 KEYMAP 铁律 1）→ rtl-integ。注：t7-A 已把 `player_ctrl` 的 `key_event` 门控为 `key_event_media = key_event && (key_code==0 || key_code==1)`（顶层 `:195`），**功能上已隔离**，但常量本身仍是错的、会误导后来人。
3. **P1 · t16 同批**：A-14~A-25、A-46（osd 三文件 16 条，t16 正在改这几个文件，同一批改最省；其中 A-11 的头注释整段重写工作量最大，A-46 是 t16 本轮刚写进去的新残留）。
4. **P1 · 顶层与 bringup**：A-28（一行，`:843` 的「16 个键已全部占满」——**S4 复核后这是顶层唯一剩下的 v1 残留**）、A-35（bringup 整块，先确认归档状态）。A-29 已在 S4 同批修掉。
5. **P2 · 零散单点**：A-26/27、A-30~A-34（共 7 条，各 1~4 行）。
6. **P2 · 测试**：A-36~A-43（verifier 统一处理，`tb_player_ctrl.v` 与 `tb_key_action.v` 工作量大）。
7. **P3 · 文件去留**：§3.1 的方案 A/B 决策 + A-01~A-06 + B-11/B-12（t11 交付文档阶段一并处理）。

### 4.2 一条方法论建议（写进 t11 交接文档）

本次扫描发现的最典型失效模式是**「改名时抄旧注释」**：t16 把 `osd_panel` / `osd_param_text` / `osd_autopop` 的端口从 3 位 `bright_sel` 改成 4 位 `bright_lvl` 并新增三项，位宽、档位范围都改对了，但**键号被原样抄成 `KEY7`/`Key7`**（A-14、A-15、A-16、A-20、A-21、A-22 六条）。建议 t11 在交接文档里加一条硬规则：

> **凡改端口名/位宽，必须同时核对注释里的键号与档位范围；改完后跑 `grep -n 'KEY[0-9]\|Key[0-9]' <改动文件>` 逐行确认。**

---

## 附录 A · 本报告的行号基准与复现命令

| 快照 | 时刻 | 用途 |
|---|---|---|
| S1 | 2026-11-02T15:23:25 | 首次全量 grep（§1.2 的 G1~G11 计数，以及 `key_action.v` / `player_ctrl.v` / `video_overlay.v` / `dmz_eg4s20_hdmi_top.v` / `key_matrix_4x4.v` / `gallery_probe.v` / `audio_*.v` / `pcm_to_pwm.v` / `osd_autopop.v:9-18` 的行号） |
| S2 | 2026-11-02T15:31:10 | 复核快照（**t16 已改动的 `osd_panel.v` / `osd_param_text.v` / `osd_autopop.v` 三文件的行号以此为准**） |
| S3 | 2026-11-02T15:31:39 | 终态补扫（`osd_autopop.v` 定稿 179 行；新增 A-46；§2.1.3 / §3.2 / §3.3 已按此快照更新） |
| **S4** | **2026-11-02T15:36:27** | **顶层修复快照**（`rtl/top/dmz_eg4s20_hdmi_top.v` 与 `project/hdmi/` 副本均 72,287 B / 1,065 行 / SHA256 `B24E5089…5EA18`）。**A-44 / A-45 的判定以 S4 为准（已修复）**；A-44 的例化位置由 S1 的 `:889-896` 移到 `:905-914`，A-45 由 `:847-851` 移到 `:857-864` |

复现命令（PowerShell，大小写敏感）：

```powershell
$root='D:\FPGA_Compelate\SmartCampusMedia'
# 键号（大写 v1 写法）
Select-String -Path "$root\rtl\*\*.v" -Pattern 'KEY[0-9]' -CaseSensitive |
  Group-Object { Split-Path $_.Path -Leaf } | Sort-Object Count -Descending |
  ForEach-Object { "{0,-32} {1,3}" -f $_.Name,$_.Count }
# 键号（v2 写法）
Select-String -Path "$root\rtl\*\*.v" -Pattern 'Key[0-9]' -CaseSensitive |
  Group-Object { Split-Path $_.Path -Leaf } | Sort-Object Count -Descending |
  ForEach-Object { "{0,-32} {1,3}" -f $_.Name,$_.Count }
# 废弃模块
Select-String -Path "$root\rtl\*\*.v","$root\sim\testbench\*.v","$root\scripts\*.ps1" -Pattern 'key_action'
# 档位/占满类
Select-String -Path "$root\rtl\*\*.v" -Pattern '16 个键|16 键|全部占满|抢一个键号|0\.\.4|0~4' -CaseSensitive
```

行数口径：本报告一律用 `[System.IO.File]::ReadAllLines()` 的 1 基计数（**`Get-Content | Measure-Object` 对无换行尾行的文件会少算 1 行**）。

## 附录 B · 本任务纪律自检

| 项 | 结果 |
|---|---|
| 修改的 `.v` / `.adc` / `.sdc` / `.tcl` / `.ps1` | **0 个** |
| 修改的 `docs/plan_v2/` 定稿正文 | **0 个** |
| 本任务唯一写入 | `reports/plan_v2/V1_RESIDUE_SWEEP.md`（本文件） |
| 扫描期间 `rtl/osd/` 三文件的 mtime 变化 | 全部由 **t16** 造成（15:28~15:31，共 124→137→156→179 四版），本报告已按 S1/S2/S3 三快照标注，未对 t16 的中间态做任何判定 |
| 附注 | `D:\FPGA_Compelate\_sweep_tmp\`（本任务自建的 grep 输出中转目录）已在收尾时删除，未污染仓库 |
| 临时中转目录 | `_sweep_tmp/`（本任务生成 9 个 txt）→ **收尾时删除** |
