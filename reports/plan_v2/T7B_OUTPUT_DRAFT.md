# t7 最终 output（定稿）

> 本文件是 t7 的正式 `output`。分 `## t7-A（已完成，可复验）` / `## t7-B（已完成）` 两段。
> **定稿依据 = 最终交付位流（v3 / seed=7，2026-11-03 00:31:47）的实测数**，
> 不是过程中任何一轮的中间态。历史轮的数一律带「历史」标签保留，不删。
> 定稿时刻：2026-11-03 00:4x +08:00

---

## t7-A（已完成，可复验）

**t7-A 三条判据已全部闭合，captain 已书面验收通过。**

### 交付面
顶层 `rtl/top/dmz_eg4s20_hdmi_top.v` 已例化 11 个新模块各 1 次：
`mode_ctrl u_mode` / `key_router u_keyrouter` / `emerg_page u_emerg` / `i2c_master u_i2c` /
`aht20_ctrl u_aht20` / `thermal_guard u_thermal` / `pix_mosaic u_mosaic` / `brightness_apply u_bright` /
`audio_src_mux u_audio_src` / `wav_stream_player u_wav` / `vol_apply u_vol`。

关键裁决落地：
- 删 `u_kact`（`key_action`）；`u_ctrl`（`player_ctrl`）保留，`.key_event` 改接
  `key_event_media = key_event && (key_code == 4'd0 || key_code == 4'd1)`（**加法门控，绝不用 `4'hF` 哨兵 —— 那等于 Key15 应急直达**）
- 删三处键号直连（原 `:84/:85` `key_code==4/5` → `pattern_sel`；`:402` `key_code==6` → `audio_muted`）
- `science_page` → `emerg_page`；`video_content_mux` 改两源（删 `science_rgb`、加 `emerg_rgb`，`2'd2: rgb_out = emerg_rgb;` + `default` 兜底）
- 传感器链：新增 `output wire i2c_scl`（D1）+ `inout wire i2c_sda`（E1）+ 三态 `assign i2c_scl = scl_oe ? 1'bz : 1'b0;`。
  **`sensor_fault` 绝不接 `temp_alarm`**（传感器坏 ≠ 着火）；`temp_alarm` 接 `oth_en` 电平、不接 `oth_enter` 单拍
- `brightness_apply` 插在 `video_overlay`→`osd_panel` 之间（**纯组合绝不打拍**，打拍会让面板右移 1 像素）
- SD 仲裁扩为**五路独热**：`probe > gallery > playseg{wav > rle > img}`

### t7-A 实测三判据
| # | 命令 | 结果 |
|---|---|---|
| ① | `flow_t7a_elaborate.tcl` | `EXIT=0` / 81 s；`PASS-import_device` → `PRJ-1401 : Successfully analyzed 64 source files.` → `PASS-open_project/elaborate/read_adc/read_sdc/optimize_rtl/report_area`；`HDL-8007`=0 / `HDL-5105`=0 / `ERROR`=0 / `CRITICAL`=0 / `WARNING`=39 / `FAIL-`=0 |
| ② | `t7a_gate_area.tcl` | `EXIT=0` / 6,943 s；同上 + `PASS-optimize_gate`；`WARNING`=55（增量全是 `optimize_gate` 的 `SYN-5011`/`SYN-5013` 原厂 IP 固有） |
| ③ | `reports/t7a_gate_area.txt` | `#lut 17,299/19,600 (88.26%)` / `#reg 7,713 (39.35%)` / `#bram 34/64 (53.12%)` / `#dsp 24/29 (82.76%)` / `#pll 2/4` / `#gclk 4/16` |

**口径纪律**：`#lut 15,319` 是 place/route 后基线、`17,299` 是 optimize_gate 后，**阶段不同，不许写「涨了 1,980」**。

---

## t7-B（已完成）

### 四项接线（captain 已逐行复核通过）
1. **`ratio_map` 双消费者**：`rm_win_w/rm_win_h/rm_off_x/rm_off_y` → 四根补零 `k9_win_*` → **同一组信号**同时接
   `image_window_mask.win_*`（位置门控）与 `image_player.win_*`（采样范围）。位宽 `{5'd0,rm_win_w}` / `{6'd0,rm_win_h}` 显式补零。
   `image_player.out_w/h/off_x/off_y` 四根按 `T1_TO_T7_WIRING.md §1.3` 裁定**空连接不删端口**。
   应急钳位在顶层：`wire [2:0] ratio_sel_eff = (mode == 2'd2) ? 3'd4 : ratio_sel;`
2. **`u_rle` 例化**：`gallery_probe` 四输出**锁存**（`rle_lba_q`/`rle_size_q` + `rle_lba_vld`）后送 `rle_decoder`，
   因为 `gallery_probe` 在 `G_ARST` 期间把 `rle_*` 全清 0，直接组合送会让 `u_rle` 瞬间读扇区 0（MBR）解出垃圾魔数。
   用 `rle_found` 判存在性（**不能用 `lba==0`，扇区 0 合法**）。`u_player.ext_*` 从「全部禁用」改接真实 RLE 写口。
3. **`narr_en`/`frame_idx` 真值**：
   `wire narr_frame_ok = (rle_frame_idx >= 16'd4) && (rle_frame_idx <= 16'd624);`
   `wire narr_on = m_science && rle_frame_ready && narr_frame_ok;`
   （`narr_en=1` 会同时关掉标题行+状态行两带；`narr_subline` 的 `in_range` 在帧号 0..3 判假 → 刚进科普的 4 帧会整层全黑）
4. **SD 五路仲裁** `probe > gallery > wav > rle > playseg`，`sd_grant` 组合不打拍。

### ★ 交付配置（**五个条件，缺一不可复现**）

```
① set_param rtl min_ripple_len 45   +   commit_param -step rtl
② set_param place seed 7            +   commit_param -step place
③ t24   —— OSD 砍组合锥（osd_caption.v / osd_strings.v）
④ t25   —— u_pix_fifo 改 FWFT 同步读（async_fifo.v）
⑤ t26   —— fat32_reader 终态自锁修复（fat32_reader.v）
```

①② 是 TD 参数，**必须走三参数 `set_param <step> <param> <val>` + `commit_param -step <step>`**
（`-run` 通道已证伪，见「第七条工具盲区」）。③④⑤ 是 RTL 改动，全部已 sync 进 `project/hdmi/`。
**时序阶段的三组参数（`place post_place_opt high` / `route post_route_opt high` / `route fix_hold on`）一个都没加** —— 实测与基线逐字相同。

### ★ 最终位流的七个核心数（v3 / seed=7）

| # | 数 | 值 | 来源 |
|---|---|---|---|
| 1 | **`#lut`** | **16,414 / 19,600 = 83.74%** | `reports\t7b_seed_seed7_area.txt`（00:31:36） |
| 2 | **`#reg`** | **8,441 / 19,600 = 43.07%** | 同上（`#le 16,795`） |
| 3 | **`#bram`** | **37 / 64 = 57.81%** | 同上（`#bram9k 37` / `#bram32k 0/16`） |
| 4 | **`#dsp`** | **24 / 29 = 82.76%** | 同上（**余 5，仍是余量最紧的**） |
| 5 | **`SWNS` / `HWNS`** | **+0.113 ns / +0.011 ns** | `reports\t7b_seed_seed7_timing.txt`（00:31:36） |
| 6 | **`Fmax`** | **25.071 MHz**（需求 25.000） | 同上 |
| 7 | **位流** | **648,264 B / `59A6BACC75613F5E953B7ED5A33E05E8`** | `project\hdmi_td_Runs\phy_1\hdmi_td.bit`（00:31:47） |

**⚠ 引用陷阱（必读）**：`reports\t7b3_rl45_area.txt` 已被后续尝试**覆盖**过 ——
它 00:20:27 落盘时是 **attA 那趟**的 `#lut 16,400`，**不是最终位流的数**。
凡是引「最终位流的资源」，一律写 **`route 后 #lut 16,414 / 83.74%（来源：reports\t7b_seed_seed7_area.txt，2026-11-03 00:31:36）`**。
**两个数差 14，写错就是硬伤。**

**三项容易漏报、但必须报的**：
- **`0 Viol Endpoints`**（setup 与 hold 都是 0）。`STNS 0.000` 只能说明「总松弛量为 0」，
  **`Viol 0` 才说明「一条都没有」**，两者不能互推。
- **`49,835,382 Paths Analyzed` / `15,676 Total Endpoints`** —— 近 5,000 万条路径**全分析过**，不是抽样。
- **`#slices` 必须给三份 `.qor` 的数，且注明来源**：
  `gate.qor 530 / 5.41%`、`place.qor 8,591 / 87.66%`、`route.qor 8,591 / 87.66%`。
  **`#slices` 从来不在面积报告里**（`report_area` 的 Utilization 段只有
  `#lut / #reg / #le / #bram / #dsp / #pad / #pll / #gclk`），只在 `report_qor` 的两列表格里。

**`#slices` 两个阶段差 16 倍**：`gate.qor` 的 530 是**综合后估算**（`#MACROs 97 / #insts in MACRO 530`，
与日志 `RUN-0007 : ... 341 mslices, 189 lslices` 的 `341+189=530` 对上）；
`route.qor` 的 8,591 是**物理布局布线后实际占用**。**拿 530 或 5.41% 论证「器件还很空」是错的。**

> ★ `place.qor` 会被 route 阶段**重写**：要「place 当时值」只能 grep 日志，要「最终落盘值」才读 `place.qor`。

### ★ 时序：通过，但**零余量级（0.28%）**

```
SWNS: 0.113ns, STNS: 0.000ns      Max: 0 Viol Endpoints
HWNS: 0.011ns, HTNS: 0.000ns      Min: 0 Viol Endpoints
Fmax: 25.071MHz                   （需求 25 MHz）
15,676 Total Endpoints / 49,835,382 Paths Analyzed
```

`route.qor` 全貌：`Setup WNS 113 / Setup TNS 0 / Hold WNS 11 / Hold TNS 0 / Wire length 1,664,088 / #slices 8,591 / 87.66%`。
`place.qor`：`Setup WNS 1,707 / Hold WNS −11`（**place 时 hold 还是负的，route 后修成正的**）。

| 项 | 值 |
|---|---|
| 需求 | 25.000 MHz（周期 40.000 ns） |
| 实测 | **25.071 MHz** |
| 频率余量 | **0.071 MHz = 0.28%** |
| 对应 slack | `SWNS +0.113 ns / 40 ns = 0.28%`（两式同源，互相印证） |

**三个前提条件必须一起写，缺一个就是不诚实**：
1. 这组结果是 **`min_ripple_len 45` + `place seed 7` + t24 + t25 + t26** 五者共同达成的，
   **任何一项回退都会跌破零**（v2 就是活证据：只多了 t26 那 1 个 LUT，`SWNS` 从 +0.113 掉到 −0.194）。
2. **温度、电压、器件批次都没有余量。** 室温真机验证过才算数（转 t9 上板清单）。
3. **不许写「时序有余量」「时序充裕」**，只能写「**时序通过，余量为 0.28%，属零余量级**」。

### 新最差路径：**clk0 域普遍贴近临界，压掉一条另一条会顶上来**

四轮的最差路径**四次换人**：

| 轮次 | Begin Point | End Point | Level | Fanout | cell | net | `Data Path Delay` |
|---|---|---|---|---|---|---|---|
| v1 失败轮 | `u_overlay/u_caption/u_narr/addr[9]_syn_208` | `u_axis/video_data_reg[6]` | 36 | 144 | 15.253 | 24.650 | 39.903 |
| v1 通过轮 | `u_player/fade_alpha_reg[0]_syn_24` | `u_axis/video_data_reg[11]_syn_4` | 31 | 89 | 14.100 | 25.507 | 39.903 |
| v2 失败 | `u_ctrl/img_index_reg[4]_syn_12` | `u_axis/video_data_reg[6]_syn_4` | 34 | 152 | 13.863 | 26.051 | 39.914 |
| **attB-1 通过（交付）** | **`u_axis/rgb[13]_syn_5126`** | **`u_axis/video_data_reg[5]_syn_4`** | **36** | **88** | **14.490** | **25.045** | **39.535** |

**正确表述**：t24/t25/t26/seed 把原来那条压下去了，**现在顶上来的是另一条本来排第二、第三的路径**。
逻辑级数 36、扇出 88、cell 14.490 都是好数；**net 绝对值的大小不具可比性，因为根本不是同一条路径。**
**结论是「clk0 域（5,047 个触发器、25 MHz、Fmax 24.879~25.071 MHz）普遍贴近临界，单点结构优化不能稳定达成」**，
不是「某条路径 net 涨了」。

> ★ 交付轮起点 `u_axis/rgb[13]_syn_5126` 落在 **`u_axis` 内部** —— 这正是那个「边界吸收 1,491 LUT」的模块
> （`video_rgb_to_axis`）。说明**被吸收进来的逻辑现在成了瓶颈**，这是 t24/t25 降总量的必然副作用，不是新问题。

> ★ **关于 v1 与 attB-1 的 `SWNS` 数值完全相同（都 +0.113）**：这是**纯属巧合**，
> `Data Path Delay` 相差 **0.368 ns**。**本文档不解释这个巧合的成因** ——
> 手算 `Slack = Budget − delay − skew − uncertainty` 代入两轮都对不上实测值（说明公式缺项，TD 内部还含其它修正项）。
> **为了解释一个巧合去编机制，是「凭表达式推断视觉后果」那类错误的同族。**

### 「net/段 是描述性指标，不是优化目标」

- 在参数实验里，net/段 是**有解释力的** —— 同一套布局算法的不同设置，net 变长必然变差。
- 但 **seed 是不同布局算法起点**，两者不是一回事。同一个 net/段 数值可以对应通过或不通过
  （v2 0.789 失败 vs attB-1 0.715 通过，而 v1 0.850 也通过）。
- 所以正确的说法是：**net/段 是描述性指标（描述这条路径长什么样），不是优化目标（不能拿它当判据去调参数）。**
  判据永远是 `SWNS ≥ 0 && HWNS ≥ 0`。

### 位流

```
project/hdmi_td_Runs/phy_1/hdmi_td.bit
  648,264 B
  2026-11-03 00:31:47
  MD5 = 59A6BACC75613F5E953B7ED5A33E05E8
```

对照 v1：`648,264 B / MD5 60A434605DAB867D5004371BC4B305E1`（**MD5 不同 ⇒ 确是新生成的**）。
归档：`reports\t7b_bit_v3_seed7_PASS\`（位流 + 三份 qor + 四份报告 + `run_seed7.log`）。
历史轮：`reports\t7b_bit_v1_t26_before\`（v1，无 t26）/ `reports\t7b_bit_v2_t26_swneg\`（v2，时序失败）。

**含 t26 的硬证据（不能只看时序过）**：
```
project\hdmi\fat32_reader.v  term_reentry = 3   ✅
rtl\storage\fat32_reader.v   term_reentry = 3   ✅
两者 MD5 均为 5FE08F510255EFE664482CFBE2427C73  ✅ 逐字节相同
45,090 B（v1 那版是 42,276 B / ADF4A93927）
```
**v1 为什么不算交付**：缺 t26 的症状是「用户切一次模式，音乐就不换了 —— 静默重播上一个文件、`err_code` 全程 0」。
**位流能跑 ≠ 位流是对的。**

### 功能条目：`fade_mixer` 从 t7-A 的 4 LUT 涨到 t7-B 的 365 LUT
t7-A 时 `fade_level` 是常量、乘法被折叠成直通，所以**用户需求「Key1/Key0 切换要做淡入淡出」直到 t7-B 才第一次真正进综合**；
t7-A 的位流按 Key1 是硬切。→ **转 t9 上板验收清单，判据写成「能看到渐变过渡，不是硬切」**。

### Key9 现状（中性事实陈述，措辞不得改）
> Key9 目前只有水平通路，垂直跳行为 step 2 待做；当前非满屏档渲染结果为**横向压缩 + 纵向裁剪**
> （窗口内显示源图中间 `win_h` 行），不是等比缩小。

**不得写**「带宽不成立」「需要行缓存」（captain 已逐档验算推翻：窗口外那 320 拍正好用来把下一条源行读出来丢掉，五档全部满足配额）。

**素材规格约束**：本工程 SD 卡素材统一 640×480（`BURN640/` 六张），故不触发；换成非 640×480 的 BMP 时
`img_scaler` 会按自身比例居中，而窗口 mask 用 `ratio_map` 的偏移 —— 两者会错开、画面被切一块且不报错。**不改 RTL**。

### 判据工具（t7-B 新增两个）
| 工具 | 查什么 | 基线 |
|---|---|---|
| `scripts/check_port_names.py` | 端口**名**交叉比对（69 module / 40 例化）+ `EMPTY_CONN` / `UNCONNECTED` 白名单 | `RESULT: PASS` / `EXIT=0`；`NO_SUCH_PORT=0` / `UNKNOWN_MODULE=2（预期 2；意外 0）` / `UNCONNECTED=0` / `EMPTY_CONN=9 实例 22 端口（有意 9；意外 0）` |
| `scripts/check_key9_shared.py` | Key9 四根几何的**结构**（单一驱动源 → 单一中间 wire → 两处消费者），10 条断言 K1~K10 | `RESULT: PASS (10/10)` / `EXIT=0` |

**为什么需要第二个工具**：`check_port_names.py` 只比对端口名，下面两类它一律 PASS（实测）：
- `.active_x(active_x)` → `.active_x(11'd0)`（名字对、位宽对、非空括号）→ Key9 静默失效、告警全消失
- `{5'd0, rm_win_w}` → `{2'd0, rm_win_w}`（补零位宽写错）→ 窗口边界算错、画面被切一块不报错

**四条反证全部实跑，双计数齐全**（按 captain 定的全项目口径：必须贴变异注入前后的特征计数）：

| # | 注入变异 | 注入前 | 注入后 | 结果 |
|---|---|---|---|---|
| A | `.win_w(k9_win_w)` → `.win_w()` | 2 | 0 | `check_key9_shared` FAIL 2/10（红 K6/K7）；`check_port_names` FAIL / EXIT=1 / 意外空连接=2 |
| B | `.active_x(active_x)` → `.active_x(11'd0)` | 8 | 0 | `check_key9_shared` FAIL 2/10（红 K8/K9）；**`check_port_names` PASS（已知盲区，靠前者补）** |
| C | `{5'd0, rm_win_w}` → `{2'd0, rm_win_w}` | 1 | 0 | `check_key9_shared` FAIL 2/10（红 K3/K4）；**`check_port_names` PASS（已知盲区）** |
| D | 整条删掉 `.vol_lvl(vol_lvl),` | 4 | 3 | `check_port_names` FAIL / EXIT=1 / 意外未接=1 |

### 三道门（sync 前后各跑一次，全部通过）
1. `python scripts\check_port_names.py` → PASS / EXIT=0
2. `powershell -File scripts\sync_src.ps1 -NoLint` → `SYNC_EXIT=0`；
   `project/hdmi/` = **60 个 .v + 1 个 .hex**（`cjk16_bitmap.hex` 37,200 B 在位）；rtl 与副本 MD5 不一致 = **0**
3. sync 后再跑校验器 → 仍 PASS / EXIT=0
- `python scripts\lint_verilog.py rtl\` → 67 文件 / E0=0 / E1=0 / E2=0 / 通过
- 全量 vlog（61 .v，`+define+SDRAM_SIM_MODEL`，干净库）→ `VLOG_EXIT=0`
- 四条 tb 基线全绿、数字与基线**逐字一致**：
  `tb_fifo_fwft checks=1658 errors=0` / `tb_pix_reader checks=194 errors=0 cases=13` /
  `tb_image_player checks=11365 errors=0` / `tb_display_content checks=614406 errors=0`

### 出位流：**已完成**（v3 / seed=7）

**22 条 `PASS-*` 序列**（`$LASTEXITCODE = 0`，wall 373.2 s）：
```
PASS-import_device → PASS-open_project
→ PASS-set_param rtl min_ripple_len 45 → PASS-commit_param rtl
→ PASS-set_param place seed 7 → PASS-commit_param place
→ PASS-elaborate → PASS-read_adc → PASS-read_sdc
→ PASS-optimize_rtl → PASS-optimize_gate → PASS-report_area_gate → PASS-export_gate_db
→ PASS-place → PASS-export_place_db → PASS-route → PASS-update_timing
→ PASS-report_timing → PASS-report_area → PASS-check_timing
→ T7B_BRAM=37/64 / T7B_LUT=16414/19600
→ T7B_TIMING_PASSED: setup=0.113 ns hold=0.011 ns
→ PASS-bitgen → T7B_BITFILE_OK: 648264 bytes
```

**为什么必须贴全序列**：TD 的 `catch` 拿到的 `$emsg` 恒为空串，只能靠自己 `puts` 的 `PASS-*` 逐条判。少一条就说明那一步没跑到。

**五次尝试完整表（答辩材料）**：

| 尝试 | 改动 / 参数 | gate `#lut` | route `#lut` | `#slices` gate/route | `SWNS` | `STNS` | `HWNS` | `Fmax` | Viol S-EP | 结果 |
|---|---|---|---|---|---|---|---|---|---|---|
| **v1** | rl45 + t24 + t25（**无 t26**） | 15,501 | 16,649 | 530 / 8,752 | **+0.113** | 0.000 | +0.012 | 25.071 | 0 | ✅ 通过但**功能不全** |
| **v2** | 上面 + **t26** | 15,244 | 16,400 | 530 / 8,590 | **−0.194** | −0.215 | +0.011 | 24.879 | 3 | ❌ 失败 |
| **attA** | 原样重跑 v2 | 15,244 | 16,400 | 530 / 8,590 | −0.194 | −0.215 | +0.011 | 24.879 | 3 | ❌ 与 v2 **逐字节相同** |
| **attB-1** | v2 + **`place seed 7`** | 15,244 | **16,414** | 530 / **8,591** | **+0.113** | 0.000 | **+0.011** | **25.071** | **0** | ✅ **通过，出片** |
| attB-2/3 | 其它 seed | — | — | — | — | — | — | — | — | ⏹ 按「中途 `SWNS ≥ 0` 立刻停」未执行 |

> **gate 数字是共享的，不是凑的**：attB-1 走 `import_db t7b3_rl45_gate.db`（attA 那趟的产物）跳过综合，
> `seed` 只影响 place 之后。所以 v2 / attA / attB-1 的 gate 行**都是 15,244**，route 行才有差别。
> **这是 `import_db` 的必然结果**，不写明白读者会以为「三次综合出同一个数」是巧合。

**v2 的悖论（最值得记住的一条）**：gate `#lut` −257、route `#lut` −249、`#slices` −162，
**每一项资源都更少，`SWNS` 却从 +0.113 掉到 −0.194（−0.307 ns）**。
t26 改的是 `u_wav/u_fat` 的 `found`/`fail`/`term_reentry`（1 个 LUT + 两个 AND），与最差路径**毫无拓扑关系**。

**attA 回答了「是不是随机的」**：原样重跑 v2，`reports\t7b3_rl45_area.txt`、`project\route.qor`
（**连布局坐标都一样**）与 v2 **逐字节相同**，只有 timing 报告因 `Generated:` 时间戳行不同。
⇒ **TD 是纯确定性的：同一输入必然得到同一输出。** v1→v2 不是「随机跳」，
是 t26 那 1 个 LUT 让综合器**换了一个盆地**，新盆地恰好差 0.307 ns。
⇒ seed 扫描从「撞运气」变成「**确定性地探索不同盆地**」。

### 历史记录：t7-B 接线完成时（t24/t25/t26 之前）的中间态

> 保留不删，用于答辩时说明「每一项修复都有对应的重跑」。

```
reports/t7b2_gate_area.txt（optimize_gate 后）
#Total_luts 14,985   #lut 17,610 / 19,600 (89.85%)   #reg 8,242 (42.05%)
#bram 35 / 64 (54.69%)   #dsp 24 / 29 (82.76%)
```
- **`#bram 34 → 35` 达成**，这是 `narr_en` 接真值、`narr_subline` 的 1 块 BRAM 不再被常量传播剪掉的**唯一硬证据**
  （t25 之后进一步 35 → 37）
- **`#lut = #Total_luts + ripple`**（`14,985 + 2,625 = 17,610`）。**「`#Total_luts` 只有 14,985」不能用来论证 LUT 还很空** ——
  真正占器件槽位的是 `#lut`，`ripple`（进位链形式占用的槽位）同样是物理资源。
- 该轮 `route` 后 **`SWNS −0.183 ns` / `HWNS −0.020 ns`**，未过门禁、未生成位流。
  根因：`Data Path Delay 39.903 ns = cell 15.253 (38%) + net 24.650 (62%)`，
  `Logic Level 36` → **cell 0.42 ns/级正常，net 0.70 ns/段异常**；place `+1,357 ps` → route `−183 ps`，
  **布线吃掉约 1,540 ps，差值全在 net**。

### 第七条工具盲区：「参数名不存在的失败模式：PASS 但零效果」

TD **不校验参数名**（`PRJ-1106 : Update wild param ... succeed` 什么都接受），
所以 **`PASS-set_param` / `PRJ-1105 succeed` 不能作为「参数生效」的证据**。

- 错误写法：`set_param -run phy_1 place <p> <v>` —— **写进 `.al` 但不改引擎**（五次运行 `OPT-1001 ... with medium effort` 全 medium）。
- 错误写法：`flow enable_seed <N>` —— **TD 6.24 全安装目录 0 命中**，正确是 `set_param place seed <N>`
  （出处 `doc\scripts\MultiSeed.tcl:62`）。若照错的跑，会拿到四条 `PASS-set_param`，
  然后四个种子出**四份逐字节相同的结果**，结论会是「seed 全不过，得动代码」—— **而真相是参数名根本不存在。**
  **连报错都没有，只是什么都没发生。**
- 唯一生效写法：`set_param <step> <param> <val>` + `commit_param -step <step>`（官方 `DefaultFlow.tcl:77` / `:137`），
  且它**不写 `.al`**。

**唯一证据是「产物变了」**：`t7b_seed_probe.tcl`（~2 min，只到 place）实测 seed=7 vs 默认：
`RUN-1001 mslices 4,286 → 4,278` / `place.qor #slices 8,590 → 8,585` / place `Setup WNS 1,757 → 1,707`。
**「先做 2 分钟探针确认参数真的生效，再花 6 分钟跑全程」是标准动作。**

### 可复现脚本（**留在 `project/`，是「这个位流怎么来的」的证据**）

| 脚本 | 用途 | 耗时 |
|---|---|---|
| `project\t7b_bit3.tcl` | 全流程（从 elaborate 起，含约 214 s 综合） | ~11 min |
| **`project\t7b_seed_probe.tcl`** | 只到 place + manhattan 时序，**验 seed 是否真生效** | **~2 min** |
| **`project\t7b_seed_full.tcl`** | **从 `t7b3_rl45_gate.db` 载入（跳综合），place→route→timing→bitgen** | **~6 min** |
| `project\t7b_assert_only.tcl` | 对已存在真实产物跑断言（面积 + 时序 + 三份 qor），不 `import_device` | ~5 s |

完整推导与全部实验记录见 `docs/plan_v2/T7_INTEGRATION_PLAN.md` **§4.1f.9**（最终收敛）
与 **§4.1f.1~§4.1f.8**（为什么一开始过不去）；五次尝试的独立记录见 `reports/plan_v2/T7B_ATTEMPT_TABLE.md`。
