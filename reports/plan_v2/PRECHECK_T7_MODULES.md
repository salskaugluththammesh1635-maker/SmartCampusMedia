# t7 四模块口径预检 · PRECHECK_T7_MODULES

| 项 | 内容 |
|---|---|
| 文档编号 | PC-T7M-01 |
| 任务 | t6 第二件事（t7 四模块口径预检） |
| 作者 | spec-auditor |
| 编写时间 | 2026-11-02 12:57 +08:00（Asia/Shanghai） |
| 判据来源 | `reports/plan_v2/T7_MUST_TEST.md`（103 行 / 14,590 B）的 V-01~V-18 + 本任务追加 4 条（P-1~P-4） |
| 纪律声明 | 本文**只读不写**：不修改任何 `.v` / `.adc` / `.sdc` / `.tcl`。所有 ⚠️ 条目附「可粘贴处置文本」，交由对应模块 owner 执行。 |
| 快照时刻 | **全部文件状态取样于 2026-11-02 12:53–12:57**。t1/t2/t4 正在并行落盘，本文件是**时间点快照**，`⏳` 条目应在对应 owner 交付后重跑。 |

---

## 0. 汇总

### 0.1 判定统计

| 判定 | 条数 | 编号 |
|---|---|---|
| ✅ 通过 | **10** | V-01、V-02、V-12、**V-15**、V-16、V-17、P-1、P-2、**P-3**、P-4 |
| ⚠️ 需处置 | **5** | **V-11**（判据「`ext_wr_addr[1:0]` 恒 `2'b00`」与实现的逐字地址语义**冲突**，见 §2）、**V-05**（`ext_wr_mode` 切换无写组互锁 → 丢写/错址窗口最长 3 拍）、**M-3**（`image_player` 缺 `CHAIN_MAX` 参数 → t8 照抄 addendum 片段会编译失败）、M-1（`emerg_page` 缺 `blink` 端口）、M-2（`ratio_map` 11/10 位 → `image_window_mask` 16 位需显式零扩展） |
| ❌ 不通过 | **0** | —（**A-8 `ext_wr_dm` 极性缺陷已在 13:30:25 快照修复**，见 §9；该条曾为阻塞级，现已闭环，仅保留留档价值） |
| ⏳ 未落盘 / 待集成 | **10** | **V-04**（`rle_decoder.v` 已落盘且 `run_len`/帧原子性写法正确，但 `tb_rle_decoder.v` **MISS** → 无实测证据）、V-03、V-06、V-07、V-08、V-09、V-10、V-13、V-14、V-18 —— 注：V-03 虽列 ⏳ 但 RTL 侧已 ✅，**真正的 ⏳ 是「无仿真证据」** |
| **合计判据** | **25** | 10 ✅ + 5 ⚠️ + 0 ❌ + 10 ⏳ = 25 = 18 条（V-01~V-18）+ 4 条追加（P-1~P-4）+ 3 条附带判据（M-1~M-3）；§3 与 §7 各含一个 P-3 小节（重复引用同一判据），故正文有 26 个判据小节 |

> **本版为终版（13:26 修订，ModelSim 复跑确认）**。与 12:57 初版相比的关键变化：t4 在 12:58 落了改造后 `pix_reader.v`（360 行）、在 13:06 落了改造后 `image_player.v`（599 行）、在 **13:14 落了 `rle_decoder.v`（本版审计快照 635 行 / 13:22:49，仍在滚动修订）**，§2 与 §3 的条目由「⏳ 未落盘」升级为**可判**，并且**曾出现的 ❌ 均已在各自迭代内自愈**（详见下方「曾出现并已修复的缺陷」）。
>
> **13:26 这一轮改了什么**：① `rle_decoder.v` 静态审计完成 → **P-3 / V-15 由 ⏳ 升 ✅**（`run_len==0 → 9'd256` 与整帧 `ext_wr_done` 单拍两处均已逐行核对），**V-04 仍 ⏳**（`tb_rle_decoder.v` MISS）；② **V-11 由 ⏳ 改 ⚠️，且问题出在判据侧不在实现侧**（`T7_MUST_TEST.md:27` 要求「每拍 `ext_wr_addr[1:0]==0`」，但设计是逐 word 递增，照原判据写 TB 会误报）；③ 新增 3 条附带发现 **A-7（`err_code=3` 契约与实现语义冲突）、A-8（`ext_wr_dm=4'hF` 极性反了 = 阻塞级，视频帧写不进 SDRAM）、A-9（加密 SDRAM 模型 ModelSim 编译失败 = 阻断 t9 回归）**。
>
> **⚠️ 两个必须立刻知道的高危项**（不在 25 条判据内，但会直接毁掉上板效果；**均已在 13:30 快照内闭环**）：
> - **A-8（曾为阻塞级，13:30:25 已修复）**：`rle_decoder.v` 曾在 `13:22:49` 快照上写 `assign ext_wr_dm = 4'hF;`（注释还写「all four bytes written」）—— 全链路是**高有效屏蔽**（`sdram_ctrl_wrap.v:51`「`dm[n]=1` 表示屏蔽」、`framebuf_arbiter.v:124` 补拍用 `4'hF`、`img_loader.v:106`「全写时为 `4'h0`」），所以 `4'hF` = **四个字节全屏蔽** → 每个 word 都写不进 SDRAM，且**不报任何错**（字数照常累加、`ext_wr_done` 照常拉高），屏上只表现为「停在旧帧或全黑」。**现状：13:30:25 快照 `:265 assign ext_wr_dm = 4'h0;` 已改正，`:139` 端口注释同步改为「always 4'h0 … (dm[n]=1 masks)」，并在 `:260-264` 留下极性与 `img_loader` 同源的说明。** 保留本条是为了不让 t9 漏掉「写后读回比对」用例。
> - **A-9（阻断回归，仍未解）**：`sdr_as_ram.enc.v` 加密核在 ModelSim ASE 下 `vlog exit=2`（`` Macro `DATA_WIDTH is undefined `` / `in protected region`），`tb_pix_reader`/`tb_image_player` 端到端跑不起来。**出路：所有 TB 统一带 `+define+SDRAM_SIM_MODEL`**，走 `sdram_ctrl_wrap.v:127` 的 `sdram_behavior_model`（纯 Verilog、含 dm 掩码行为）。
>
> **⚠️ 口径提醒（重要）**：本节统计的是**「RTL 侧是否成立」**，不是「是否已实测通过」。10 条 ✅ 分两类：
> - **真跑过仿真的 4 条**：V-01、V-02、P-1、P-2 —— 依据 `tb_pix_mosaic.v`（`# SUMMARY: checks=149 pass=149 fail=0`）与 `tb_emerg_page.v`（`# SUMMARY: checks=57 errors=0 fail=0`），13:15 已复跑确认。
> - **静态审计通过的 6 条**：V-12、**V-15**、V-16、V-17、**P-3**、P-4 —— RTL 已落地、`grep` 驱动数审计通过，但 `tb_image_player.v`（13:09 版）对新端口**只做「例化填常量」级别的接入、无激励无断言**，`tb_rle_decoder.v` 则 **MISS**，「实测通过」要等 t9 补 TB 才算数。
>
> **曾出现并已修复的缺陷（留档，供 verifier 复核时不误判）**：`image_player.v` 在 **13:04:04 快照**上曾有 4 处实质缺陷——① `pix_reader` 例化（当时 `:571-577`）漏接全部 5 根新增线 ② `:544 fade_level` 是死代码（`u_fade` 仍接 `fade_alpha`）③ `:74 ext_frame_ready` 悬空无驱动 ④ `ext_wr_done` 未接 `commit_pending`。**13:06:29 快照已全部修复**（`:578-579` 五根线接上、`:588 u_fade` 改接 `fade_level`、`:548-549 assign ext_frame_ready = ext_frame_ready_r`、`:244 if (ext_wr_mode && ext_wr_done_sync) commit_pending <= 1'b1`）。因此**本终版不保留任何 ❌**，但这条时间线必须写清楚，否则后人对不上版本。
>
> **这 4 处缺陷为什么差点漏掉（方法论留档）**：`vlog image_player.v` 与 `vlog +lint=all` **都 exit 0、零 warning** —— 悬空 input 在 Verilog 里不告警，死代码 wire 也不告警。**「编译通过」不能作为 V-12/V-17 的证据，必须做 grep 驱动数审计**（声明次数 vs 使用次数）。
>
> 纪律说明：任务书「还没落盘的标 ⏳，不报 ❌」——`tb_rle_decoder.v` 仍 MISS，故 **V-04 保持 ⏳**（代码已落盘且写法正确，只是没有 TB 证明）；`rle_decoder.v` 已落盘，故 V-11 / P-3 / V-15 转为可判，其中 **V-11 判 ⚠️**（判据与实现语义冲突，非实现缺陷，见 **§2**）。
>
> **13:30 收尾补正**：① §7 的 P-3（追加判据视角）由 ⏳ 同步升为 ✅，与 §3 的 P-3 判定一致（两处是同一判据的两个视角，不是两条判据）；② V-09 的 ⏳ 理由从「视频播放路径尚不存在（`rle_decoder` MISS）」改为「视频路径 RTL 已齐，但 t8 顶层尚未把 `u_rle`/`u_player`/`u_audio` 接进同一条 SDRAM 仲裁，且 A-9 阻断端到端仿真」——避免下游误读为「t4 还没交付」。

### 0.2 判据统计修正说明

任务书说「判据以 T7_MUST_TEST.md 的 **16 条**为准」，实测该文件列的是 **V-01 ~ V-18 共 18 条**：
- V-01 ~ V-10 来自 `ARCH_ADDENDUM_VIDEO_PATH.md` §12（`T7_MUST_TEST.md:70-76` 有编号来源对应表）；
- V-11 ~ V-18 为 t18 追加（同表）。
- 另：V-05/V-11/V-12/V-13 与 V-01 一起被 `T7_MUST_TEST.md:15` 列为「静默失败项」。

**本文按实际 18 条覆盖**（V-01~V-18），另加 4 条追加判据（P-1~P-4）与 3 条静态审计中发现的附带判据（M-1~M-3），**合计 25 条**（与 §0.1 统计表一致）。

> **任务书「16 条」的口径来源推测**：`T7_MUST_TEST.md` §12 原定 V-01~V-16，t18 追加 V-17/V-18 后未同步更新任务书。**以文件实列的 18 条为准**，避免漏判两条静默失败项（V-17 端口漏接、V-18 编译回归）。

### 0.3 文件落盘状态（**13:35 复核快照**，取代 12:57 初版、13:06 与 13:14 中间版）

> 行数以 `[System.IO.File]::ReadAllLines` 计（`Get-Content` 对无换行尾行会少算，两者本文件内相差 1 行属正常，引用行号一律以 `ReadAllLines` 的 1 基计数为准）。

| 文件 | 大小 | mtime | 行数 | 状态 |
|---|---|---|---|---|
| `rtl/video/pix_mosaic.v` | 8,429 B | 11-02 12:44:54 | 154 | ✅ 落盘 |
| `rtl/video/ratio_map.v` | 6,799 B | 11-02 12:45:25 | 133 | ✅ 落盘 |
| `rtl/video/emerg_page.v` | 6,427 B | 11-02 12:36:34 | 123 | ✅ 落盘 |
| `rtl/storage/rle_decoder.v` | **31,810 B** | **11-02 13:30:25**（本文件最初审计快照为 13:22:49 / 635 行） | **658** | ✅ **已落盘**（t4 在滚动修订，行号随版本漂移，**引用须带快照时间**；见 §0.3.1 行号对照）；`run_len==0→9'd256`、`ext_wr_addr` 逐字递增、整帧 `ext_wr_done` 单拍均成立；**A-8（`ext_wr_dm` 极性）已在 13:30:25 快照修复**（`:265 = 4'h0`） |
| `rtl/storage/pix_reader.v` | **18,478 B** | **11-02 12:58:26** | **360** | ✅ **改造后版本已落盘**（含 `src_w`/`src_h`/`src_y`/`src_row_hold`/`map_ident`） |
| `rtl/storage/image_player.v` | **31,861 B** | **11-02 13:06:29** | **599** | ✅ **改造后版本已落盘**（`ext_*` 12 个端口齐全、`pix_reader` 五根线已接、`ext_frame_ready` 已驱动、`ext_wr_done→commit_pending` 已接） |
| `sim/testbench/tb_pix_mosaic.v` | 21,677 B | 11-02 12:43:39 | 493 | ✅ 落盘（ModelSim `checks=149 pass=149 fail=0`） |
| `sim/testbench/tb_emerg_page.v` | 12,651 B | 11-02 12:39:28 | 262 | ✅ 落盘（ModelSim `checks=57 errors=0 fail=0`） |
| `sim/testbench/tb_ratio_map.v` | — | — | — | **⏳ MISS**（`ratio_map` 目前靠 `tb_pix_mosaic.v:109-115` 的例化 + `:344-368` 的 `check_ratio` 五档断言间接覆盖，**尚无专属 TB**） |
| `sim/testbench/tb_rle_decoder.v` | — | — | — | **⏳ MISS** |
| `rtl/osd/osd_ticker.v` | — | — | — | **⏳ MISS**（t3 待交付；V-13 的滚动带依赖它） |
| `rtl/osd/osd_strings.v` | **29,303 B**（原 8,335 B） | **11-02 13:19:29** | **455**（原 156） | ⚠️ **t3 已大改但 V-13 文案仍未写**（13:35 复核：grep `SD NEEDED`/`KEPU LOAD`/`NEEDED` = 0 命中）；`:18-20` 表结构 line 0..7 ASCII / line 8..13 六段中文介绍 / line 14..15 应急疏散（104 字），**line 13/14 已被吃掉** |
| `rtl/osd/osd_caption.v` | **20,868 B**（原 12,431 B） | **11-02 13:18:08** | **393**（原 291） | ✅ t3 已改；9 列可见宽度不变（`STATE_X0=32` / `STATE_X1=103`） |
| `sim/testbench/tb_image_player.v` | **39,666 B** | **11-02 13:09:02** | **768** | ⚠️ **t4 已更新但只做了「端口接常量」级别**：`ext_no_fade` / `ext_wr_mode` / `ext_wr_valid` / `ext_frame_ready` / `ext_wr_done` / `src_w` / `src_h` **各仅 1 处**（= 例化里填了一次，无激励、无断言）→ 外部写口与淡入旁路**仍属语义零覆盖** |
| `sim/testbench/tb_pix_reader.v` | **14,643 B** | **11-02 13:11:34** | **380** | ✅ **t4 已加 V-03 用例**：`src_h` 20 处、`map_ident` 8 处、`src_y` 7 处、`src_w` 3 处、`src_row_hold` 3 处（含 `src_h = LINES/2` 半高用例）—— 但**跑不起来**（A-9 加密 SDRAM 模型阻断） |
| `rtl/video/video_content_mux.v` | 1,642 B | **10-30 00:03:42** | 38 | ⏳ **未动**（V-08 未做：`science_rgb` 仍在、`emerg_rgb` 不存在、`mode==2'd2` 仍输出 `24'hFF_00_00` 纯红） |
| `rtl/control/mode_ctrl.v` | 14,140 B | **11-02 00:01:23** | 257 | ⏳ **未动**（V-06 `disp_mode`、V-14 2 s 超时均无落点） |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | 40,676 B | **10-31 16:55:31** | 616 | ⏳ **未动**（t8 未开始；`pix_mosaic`/`ratio_map`/`emerg_page`/`rle_decoder` 全部未接线） |
| `rtl/osd/cjk16_font.v` | **6,474 B** | **11-02 13:08:42** | **108** | ✅ t3 已落盘（V-13 相关，但 `osd_strings.v` 文案仍未写） |

### 0.3.1 `rle_decoder.v` 行号对照（该文件在本预检期间持续修订，务必按快照引用）

t4 在 13:14 → 13:30 之间又改了三版（541 → 635 → 658 行）。本文件 §3 / §7 的正文引用的是 **13:22:49 / 635 行**快照；若读者手上是 **13:30:25 / 658 行**版本，按此表换算（**语义未变，仅行号平移**）：

| 内容 | 13:22:49（635 行） | 13:30:25（658 行） |
|---|---|---|
| 文件格式注释「`run_len == 0` means 256 pixels」 | `:35-37` | `:37-39` |
| 写口契约 P1「at every write-group start」+ TB 作者提示 | `:43`、`:41-50` | `:45`、`:43-50` |
| 写口契约 P2「busy 高时地址不得推进」 | — | `:51-53` |
| 4 深缓冲的对齐论证（frame_base + 4k） | `:56-62` | `:56-69` |
| 设计陷阱 6 条（含 TB 可改小 `CLK_FREQ_HZ`） | `:58-78` | `:71-95` |
| `module rle_decoder #(` | `:88` | `:105` |
| `ext_wr_addr` 端口注释 | `:120` | `:137` |
| `ext_wr_dm` 端口注释（**A-8 修复点**） | `:134`（曾写「always 4'hF」） | `:139`（「always 4'h0 … (dm[n]=1 masks)」） |
| `err_code` 端口注释（**A-7 冲突点**） | `:126` | `:143` |
| `FRAME_WORDS = FRAME_PIXELS >> 1` | `:136` | `:153` |
| `BANK_A_BASE` / `BANK_B_BASE` | `:137-138` | `:154-155` |
| `reg [8:0] run_left`（**P-3 关键位宽**） | `:178` | `:195` |
| `pack_done` / `pixel_done` | `:216` | `:237-239` |
| 组合展开器 `exp_active/exp_half/exp_pair/exp_single/exp_word` | — | `:241-251` |
| `assign want_blk` | `:219-221` | `:253-255` |
| **`assign ext_wr_dm`（A-8 本体）** | `:255`（`4'hF`，错） | `:265`（`4'h0`，对） |
| 复位段 | `:251-290` | `:316-339` |
| `run_left/px_half` 展开更新 | `:487-499` | `:350-360` |
| 写口 always（`ext_wr_addr <= frame_go ? frame_base : …`） | `:317` | `:383` |
| 写口 `ext_wr_addr <= ext_wr_addr + 21'd1` | `:320` | `:385` |
| 写口开新组（`wcount >= 4` → `group_left <= 4`） | `:329-333` | `:394-396` |
| **`if (pack_done) ext_wr_done <= 1'b1;`（V-15 唯一置位点）** | `:336` | `:400` |
| `done_sent` 锁存（防二次 done） | — | `:402` |
| `!play_en` 分支（**不置 done**） | `:341-353` | `:407-419` |
| `frame_base`/`frame_go` 置位（**每帧从 bank 基址重写**） | `:418-419` | `:435-436` |
| `run_count == 0 → err_code 3` | `:457-460` | `:524-527` |
| 帧满丢弃多余像素（防死锁） | `:479-483` | `:549-552` |
| `px_half \|\| !pixel_done → err_code 3` | `:508-511` | `:556-559` |
| `pack_done → 翻 bank + R_FRAME_END` | `:504-507` | `:560-563` |
| **`run_left <= (cur_byte==0) ? 9'd256 : …`（P-3 本体）** | `:521-528`（`:525`） | `:570-577`（`:574`） |
| `R_FRAME_END` | `:564-573` | `:613-621` |
| `R_ERR` | `:575-579` | `:624-628` |
| 欠载看门狗 always（只置标志） | `:517-532` | `:641-656` |

> **本表同时是「引用行号必须带快照」的实证**：同一份 RTL 在 16 分钟内行号整体平移了约 15~20 行。**凡本文件其它章节出现的 `rle_decoder.v:<行号>`，一律以 13:22:49 快照为准，换算时查此表。**

### 0.4 ModelSim 实测结果（本预检唯一「跑过」的证据）

模拟器：`D:\Quartus_APP\modelsim_ase\win32aloem\`（`vlib` / `vlog` / `vsim` 可用；**iverilog 与 verilator 均未安装**）。

| 套件 | 命令 | 结果 |
|---|---|---|
| `tb_pix_mosaic` | `vlog pix_mosaic.v ratio_map.v tb_pix_mosaic.v` + `vsim -c -quiet -do "run -all; quit -f" tb_pix_mosaic` | **`# SUMMARY: checks=149 pass=149 fail=0`**、**`# ALL CHECKS PASSED: pix_mosaic`**、`$finish at tb_pix_mosaic.v(490)` |
| `tb_emerg_page` | `vlog emerg_page.v tb_emerg_page.v` + `vsim -c -quiet -do "run -all; quit -f" tb_emerg_page` | **`# SUMMARY: checks=57 errors=0 fail=0`**、**`# ALL CHECKS PASSED: emerg_page`** |

> **命令坑（供后续 verifier 复用）**：`vsim -c -run -all` 会报 `Unknown option '-run'` 并 exit 1。必须写成 `vsim -c -quiet -do "run -all; quit -f" <tb>` 或给 `-do` 脚本。模拟器路径 `D:\Quartus_APP\modelsim_ase\win32aloem\`（`vlib`/`vlog`/`vsim` 可用；**`iverilog` 与 `verilator` 本机均未安装**）。
>
> **尚未能跑的**：`tb_rle_decoder.v`（MISS）、`tb_ratio_map.v`（MISS）；`tb_image_player.v` / `tb_pix_reader.v` / `tb_display_content.v` / `tb_startup_ownership.v` / `tb_probe_order.v` / `tb_probe_pix.v` 六份**尚未用改造后 RTL 重编译**（t9 任务）。本报告对这几份只做**静态审计**（grep 端口用法），未跑仿真。

### 0.5 独立综合实测（12:42–12:50 期间 t1/t2 提供，本预检重大更新）

**新增：t7 六份交付里，已有 3 个模块拿到了真实综合面积**（此前全部只能写「按预算」）。报告路径与数值见 **§8.1.B** 与 §11 引用清单。

| 模块 | 实测 lut | 实测 le | bram | dsp | addendum 预算 | 结论 |
|---|---|---|---|---|---|---|
| `ratio_map` | **14** | 14 | 0 | 0 | +30（`:342`） | 省 16 |
| `pix_mosaic` | **50~64** | — | 0 | 0 | +40（`:601`）/ +70（`:363`） | 落在两预算之间 |
| `emerg_page` | **339** | 339 | 0 | 0 | +400（`:523`） | 省 61（15%），`#reg only 0` 实证零寄存器 |

**三条口径纪律（务必照做）**：
1. 这 3 份是**模块单独作 top 的独立综合**（`Report Model: ratio_map` / `pix_mosaic` / `emerg_page`），`Device: EG4S20BG256`、LUT 总数 19,600 —— 与 baseline 同器件同口径，但**不能与全设计的 15,319 直接相加**。
2. `project/t1_geom_area/gate.qor` 的 `Setup WNS = 2147483647` / `Hold WNS = 2147483647` 是「**无约束**」哨兵值（该目录没有 SDC），**不得解读成时序余量无穷大，更不能拿去当 V-10 的 SWNS/HWNS 证据**。
3. 其余未综合模块（`rle_decoder` / 改造后 `pix_reader` / `image_player` 外部写口 / `eff_src_w` / `brightness_apply` / `cjk16` 字库）**仍只能写「按预算/外推」**，见 §8.1.C。

---

## 1. pix_mosaic / ratio_map（t1 · rtl-geom）

### V-01 ✅ `pix_mosaic` 五档恒等性

| 项 | 内容 |
|---|---|
| **判定** | ✅ **通过（已实测）** |
| **出处** | `rtl/video/pix_mosaic.v:115`、`:117`、`:122`；`sim/testbench/tb_pix_mosaic.v:337` |
| **理由** | ① `:115 wire take = (active_x == 11'd0) \|\| (x_acc >= OUT_W);` ② `:117 assign rgb565_out = take ? rgb565_in : hold;` —— **组合 assign**，`src_w=640` 时 `take` 每拍为真，`rgb565_out` 逐拍等于 `rgb565_in`，不存在落后一拍 ③ `:122 assign valid_out = valid_in;` valid 直通无延迟 ④ ModelSim 实测 `tb_pix_mosaic.v:337` 的 I1 专项 `chk(err==0, "I1 src_w=640 逐拍 640/640 拍 === rgb565_in（V-01）")` 通过，全部 149 条断言 pass=149/fail=0 ⑤ 实测打印 `src_w=640 块宽 1..1、不同源列 640`。 |
| **补充** | 该文件的文件头 `:21-35` 主动点名「不能照抄 `ARCH_ADDENDUM_VIDEO_PATH.md :462-469` 的伪码…正确写法是组合旁路」——**作者已知坑并在注释里留了防复发说明**，这是很好的工程习惯。 |

### V-02 ✅ `pix_mosaic` 边界无累积误差

| 项 | 内容 |
|---|---|
| **判定** | ✅ **通过（已实测）** |
| **出处** | `rtl/video/pix_mosaic.v:145` `:150`；`sim/testbench/tb_pix_mosaic.v:298`（L1）、`:304`（L7） |
| **理由** | ① 边界更新用 `x_acc <= x_acc + src_w - OUT_W;`（`:145`），**减而非取模**，无累积误差 ② L1 `dist == sw_x`（单行内不同源列数恰为 `src_w`）+ L7 `n_take == sw_x`（`hold` 更新次数恰为 `src_w`）双判据 ③ ModelSim 实测：`src_w=640→640`、`560→560`、`320→320`，`ref_err=0` 全部五档 ④ 抽样位置实测吻合 ceil 参考模型：`src_w=320` 时 `[0..11] = 0 2 4 6 8 10 12 14 16 18 20 22`，正是 `p_i = ceil(i·640/src_w)`。 |
| **注意** | TB 的 `:138-144 ref_pos` 用 `(idx*LINE_PIX + sw - 1)/sw` 做参考模型，**这是 TB 内部的整数除法，不是 DUT 的**；DUT 本身零除法（见 P-2 的运算符普查）。这两件事不要混。 |

### V-07 ⏳ 应急钳位（`eff_src_w == 640` 且 ratio_map 输出 640/480/0/0）

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **半落盘**：`ratio_map` 侧可验，`eff_src_w` 侧未落盘 |
| **出处（已落盘半）** | `rtl/video/ratio_map.v:117-122`（档 4 = 640/480/0/0）、`:68-74`（端口）；`sim/testbench/tb_pix_mosaic.v:361-364`（R1~R4 档位表比对） |
| **出处（缺的半）** | 全 `rtl/` grep `res_src_w` / `16'd576` / `16'd512` = **0 命中** |
| **理由** | ① `ratio_map` 五档已正确实现，档 4 = `11'd640 / 10'd480 / 11'd0 / 10'd0`（`:117-122`），且 `:124-129` 的 `default` **也回落到 640/480/0/0**（不是 0×0，避免 `image_window_mask` 全裁黑）——这个 default 选择是对的 ② 但 addendum `:583` 要求的 `eff_src_w = (disp_mode==2'd2) ? 16'd640 : res_src_w` 中，**`res_src_w` 这个 3→16 位译码表（五档 640/576/512/400/320）在整个 `rtl/` 里根本不存在**：`res_sel` 只在 `rtl/control/key_router.v:15`（注释）、`:90`（端口声明）、`:157`（复位）、`:237-238`（循环）出现，没有任何译码 ③ 应急钳位还需 `disp_mode`，而 `rtl/control/mode_ctrl.v` **没有 `disp_mode` 输出**（见 V-06），故整条链路未闭合。 |
| **归属** | `res_src_w` 译码 + `eff_src_w` 生成 → **t8（rtl-integ）**；`ratio_map` 本体 → t1 已完成 |

### M-2 ⚠️ `ratio_map` 输出位宽与 `image_window_mask` 输入位宽不一致

| 项 | 内容 |
|---|---|
| **判定** | ⚠️ **需处置（不是错，是 t8 接线必须显式零扩展）** |
| **出处** | `rtl/video/ratio_map.v:68-74`（`win_w[10:0]` / `win_h[9:0]` / `win_off_x[10:0]` / `win_off_y[9:0]`）vs `rtl/video/image_window_mask.v:25-28`（`win_w[15:0]` / `win_h[15:0]` / `win_off_x[15:0]` / `win_off_y[15:0]` —— **16 位**） |
| **理由** | ① `ratio_map` 选 11/10 位是**刻意的紧凑选择**（最大 640 需 10 位、加偏移 160 后 11 位足够），与 `tb_pix_mosaic.v:76-79` 的 wire 声明完全一致，**不存在截断** ② 但 `image_window_mask` 的四个输入是 16 位，Verilog 隐式位宽扩展在**赋给更窄**时才告警，这里是「窄赋宽」→ 零扩展，工具不报错但**综合日志无提示**，属于「静默正确但没人验证过」 ③ addendum `:342` 只写「win_* 由 ratio_map 驱动」，没写位宽适配责任方。 |
| **可粘贴处置文本（给 t8 / rtl-integ）** | ```verilog
// ratio_map 输出为 11/10 位紧凑口径，image_window_mask 输入为 16 位。
// 这里显式零扩展，不依赖隐式位宽扩展（隐式扩展在 TD 综合日志里不告警，属于静默路径）。
wire [15:0] win_w16     = {5'd0,  win_w};      // ratio_map.win_w[10:0]
wire [15:0] win_h16     = {6'd0,  win_h};      // ratio_map.win_h[9:0]
wire [15:0] win_off_x16 = {5'd0,  win_off_x};  // ratio_map.win_off_x[10:0]
wire [15:0] win_off_y16 = {6'd0,  win_off_y};  // ratio_map.win_off_y[9:0]
image_window_mask u_image_mask (
    .de(de), .active_x(active_x), .active_y(active_y),
    .win_w(win_w16), .win_h(win_h16), .win_off_x(win_off_x16), .win_off_y(win_off_y16),
    .pixel_valid(image_pixel_valid), .pixel_valid_out(image_pixel_shown)
);
```<br>**LUT 成本：0**（纯连线位拼接）。 |

### M-1 ⚠️ `emerg_page` 缺 `blink` 端口（偏离 addendum 5 端口契约）

| 项 | 内容 |
|---|---|
| **判定** | ⚠️ **需处置（模块自身自洽且全绿，但契约不符，t8 照抄 addendum 会编译失败）** |
| **出处（现状）** | `rtl/video/emerg_page.v:25-30`（**只有 4 个端口**：`de` / `active_x[10:0]` / `active_y[9:0]` / `rgb_out[23:0]`）；`sim/testbench/tb_emerg_page.v` 全文 `blink` **0 命中** |
| **出处（契约）** | `docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md:508-514`（端口契约 **5 个**，含 `input wire blink, // 1 Hz 方波，由 mode_ctrl 提供`）、`:522`（「blink 只用于当前位置块闪烁，不需要时恒接 1'b1」）；`reports/plan_v2/EMERG_SCREEN_RULING.md:242`（「出口闪烁：由外部提供 blink 输入信号…t8 需提供 blink 源」）；`ARCH_ADDENDUM:570-573` 顶层例化片段含 `.blink (emerg_blink)` |
| **理由** | ① 模块本体**完全正确**：ModelSim 实测 `checks=57 errors=0 fail=0`、`ALL CHECKS PASSED`，像素内容与 `EMERG_SCREEN_RULING` 全部对齐 ② 缺 `blink` 是**有意的设计取舍**，`:22-23` 注释明写「Port list is intentionally the same four ports as `science_page.v`」——即作者为了顶层替换时端口「drop-in 兼容」而砍掉了 blink ③ 但代价是 **t8 如果照抄 `ARCH_ADDENDUM:570-573` 的例化片段会直接编译失败**（`.blink(emerg_blink)` 找不到端口）④ 且「当前位置块闪烁」这个设计意图现在无处实现，「出口闪烁」（`EMERG_SCREEN_RULING:242`）也随之丢了——**这是功能缺口，不只是端口名问题**。 |
| **可粘贴处置文本（二选一，建议 A）** | **方案 A（推荐，改 RTL 补齐 blink，约 +2 LUT）**：给 `rtl/video/emerg_page.v` 端口区加一行并在渲染级联里门控位置块：<br>```verilog
input  wire        blink,       // 1 Hz 方波；当前位置块闪烁使能（恒接 1'b1 则不闪）
```<br>渲染 `:113-119` 级联中把位置块那一级改成：<br>```verilog
if (pos_block && blink) rgb_out = C_POS;   // blink=1'b1 时常亮，等价原行为
```<br>同时 `tb_emerg_page.v` 的 DUT 例化处补 `.blink(1'b1)`（保持现有 57 条断言全部不变），并**追加一条新用例**：`blink=1'b0` 时位置块 384 px 全部回落到 C_ROOM。t8 再提供 `emerg_blink` 源（由 `mode_ctrl` 或顶层 1 Hz 分频产生）。<br><br>**方案 B（保 4 端口，放弃闪烁）**：在 `ARCH_ADDENDUM:508-514` 与 `:570-573` 的**报告侧登记勘误**（不改 addendum 正文），并明确写入 t8 接线说明：`emerg_page` 用 4 端口，**不接 blink**，当前位置块为常亮；t8 不得照抄 addendum 片段。此方案零 RTL 改动，但要接受「无闪烁」这一功能降级，并需同步 `EMERG_SCREEN_RULING.md:242` 的「出口闪烁」承诺作废。 |

---

## 2. pix_reader / image_player（t4 · rtl-storage）

### V-03 ⏳ `pix_reader` 垂直行映射（RTL 已落盘且算法正确，**但零测试覆盖 + 下游无人消费**）

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **未验收**（代码已在，两条证据都缺：① 没有 TB 断言 ② 映射结果没有下游消费者） |
| **出处** | `rtl/storage/pix_reader.v`（**360 行 / 18,478 B / mtime 2026-11-02 12:58:26**，已由 t4 改造）：新增端口 `:61 input wire [15:0] src_w,` `:62 input wire [15:0] src_h,` `:63 output wire [15:0] src_y,` `:64 output wire src_row_hold,` `:65 output wire map_ident`；实现 `:173 assign src_ok = (src_w != 16'd0) && (src_h != 16'd0) && (src_h <= FRAME_LINES16);`、`:175 src_h_eff = src_ok ? src_h : FRAME_LINES16;`、`:176 map_ident = (src_h_eff == FRAME_LINES16);`、`:177 line_last = de && (pix_count == LAST_PIX);`、`:178 new_frame = line_last && (active_y == FRAME_LINES - 1);`、`:179 row_advance = line_last && !new_frame;`、`:180 y_sum = {1'b0, y_acc} + {1'b0, src_h_eff};`、`:181 row_step = (y_sum >= FRAME_LINES);`、`:182 y_new = row_step ? (y_sum - FRAME_LINES) : y_sum;`、`:186-204` 时序（`row_advance` 时 `y_acc <= y_new[15:0]`，`row_step` 分支 `src_y_reg <= src_y_reg + 16'd1; src_row_hold_reg <= 1'b0;`，否则 `src_row_hold_reg <= 1'b1;`）；**测试证据**：`sim/testbench/tb_pix_reader.v`（11,386 B / 312 行 / mtime 10-29 08:11:37）全文 grep `src_w\|src_h\|src_y\|src_row_hold\|map_ident` = **0 命中**；**消费证据**：`image_player.v:583-585` 把三根观测线接成内部 wire，注释明写「本模块不消费，留给顶层探针/仿真观测，未接时综合掉」 |
| **理由** | ① 算法本身正确：16 位 DDA `y_acc += src_h`、溢出即 `>=480` 时减 480 并进位一行，精确等价于 `src_y = floor(active_y * src_h / 480)`，**零乘法零除法零移位**（符合 `+30 LUT` 预算）② 非法档位有兜底：`src_w=0` 或 `src_h>480` 时 `src_ok=0` → `src_h_eff=480` 恒等映射，不会越界 ③ **判 ⏳ 的两个硬原因**：**（a）** `tb_pix_reader.v` 完全没有新端口的用例，`src_h=240` 时应「同一源行被读 2 次」这条断言**一行都没有**；**（b）** `src_row_hold` 目前**没有任何消费者** —— 行重复的真正生效点在下游（`content_mux` / `pix_mosaic` 按 `src_row_hold` 决定是否复用上一行），而 `video_content_mux.v` 仍是 10-30 的旧版，没有该端口 → 现在即使把 `src_h=240` 接上，屏上也是**逐行抽取而非行复制**（每行只亮一次、纵向条纹），功能等于没做 ④ `pix_reader.v:26-32` 的作者注释已自陈这一落点差异：「现 RTL 中 SDRAM 顺序读地址由 framebuf_arbiter 内部 rd_addr 每次 +4 字自主推进，本模块不存在 row_addr / new_frame 信号，故 addendum 的『row_addr <= row_addr + PIX_PER_LINE』无落点。垂直行重复的真正生效点在下游消费侧」——**与 addendum `:497-498` 的原设计不同，属已登记的口径变更（见 §9 A-2）**。 |
| **可粘贴处置文本（给 t8）** | ```verilog
// 行重复（src_h<480）必须在 content_mux 侧落地，否则 pix_reader 的映射白算：
// 方案 A（推荐 · 约 +24 LUT）：给 video_content_mux 增加输入
//     input wire img_row_hold,
//   并在 default 分支的图像路径里：
//     image_rgb_eff = img_row_hold ? row_saved_rgb : image_rgb;
//   其中 row_saved_rgb 在「上一拍有效且 img_row_hold=0」时锁存一行（640 拍 × 16bit
//   需要行缓存 —— 若 BRAM 不够，退回方案 B）。
// 方案 B（0 BRAM）：不改 content_mux，改 pix_reader 直接输出「重复读」——
//   让 src_row_hold=1 时把本行数据多扫一遍（pix_valid 照常、active_y 不变），
//   即把垂直缩放做在扫描侧而非采样侧；代价是 SDRAM 读带宽 ×2（需重新核 V-09/V-15）。
// 方案 C：把 src_h 的下限钉死为 480（不支持垂直缩放），并在 t8 报告与
//   RESOURCE_BUDGET 里删掉「垂直行映射」这一项，只保留水平 pix_mosaic。
``` |
| **归属** | t4（pix_reader 已交）+ t8（消费侧未做）；verifier 在 t9 补 `tb_pix_reader.v` 的 `src_h=240` 用例后可改判 ✅。 |

### V-05 ⚠️ 写口交接无撕裂（通道已落地，但缺「写组互锁」）

| 项 | 内容 |
|---|---|
| **判定** | ⚠️ **端口已全、路径已通，但 `ext_wr_mode` 跳变拍与 `framebuf_arbiter` 的四拍写组之间没有互锁** |
| **出处** | `rtl/storage/image_player.v`（599 行 / mtime 13:06:29）：写口 mux `:535-540`（`arb_wr_req = ext_wr_mode ? ext_wr_valid : write_request;` / `arb_wr_addr = ext_wr_mode ? ext_wr_addr : write_head[56:36];` / `assign ext_wr_ack = ext_wr_mode && arb_wr_req && wr_ack;` / `assign ext_wr_busy = ext_wr_mode && ext_wr_valid && !ext_wr_ack;`）；BMP 侧四路组合门控 `:148 bmp_load_req = load_req && !ext_wr_mode;`、`:439 bmp_wr_ack = wr_ack && !ext_wr_mode;`、`:440 fifo_pop = !ext_wr_mode && ...`、`:468 write_request = write_head_valid && (batch_left != 0) && !ext_wr_mode;`；arbiter 例化 `:552-562`（`framebuf_arbiter #(.WR_ADDR_FROM_FIFO(1), ...) u_arb (.wr_req(arb_wr_req), .wr_word_addr(arb_wr_addr), ... .wr_ack(wr_ack),`）；arbiter 内部 `rtl/storage/framebuf_arbiter.v:63 reg wr_grp_active; // 写组尚未走完`、`:121-122 assign app_wr_addr = WR_ADDR_FROM_FIFO ? (wr_grp_active ? wr_base_hold : wr_word_addr) : wr_addr;`、`:190-204` 写组推进（`:198 wr_grp_active <= !wr_last_beat;`）、`:19 WR_GROUP_CYCLES = 13` |
| **理由** | ① V-05 要求的「`wr_grp_active` 在 `ext_wr_mode` 跳变那一拍**已为 0**」，`image_player` 侧只做了**组合门控**（BMP 的 `write_request` 在 `ext_wr_mode=1` 当拍即被掐断），但**已进入的 4 拍写组不会立刻退出** —— `wr_grp_active` 是 arbiter 内部 reg，要等 `wr_last_beat` 才清零，最长还会吃掉 3 拍。② 这 1~3 拍里 `app_wr_addr` 被锁成 `wr_base_hold`（`:122` 三目），外部 `ext_wr_addr` 被**忽略**；而 `ext_wr_ack`（`:539`）只看 `wr_ack`，`wr_ack` 又只反映「总线写入成功」，**不区分这一拍写的是谁的地址** → RLE 侧以为写进去了，实际写到了旧组基址，表现为**丢写 / 错址**（屏上局部错行）。③ `ext_wr_busy`（`:540`）只覆盖 `ext_wr_valid && !ext_wr_ack`，**不含写组互锁**，故按 `ext_wr_busy` 握手也挡不住这个窗口。④ `wr_grp_active` 未对外暴露（全文件仅 `framebuf_arbiter.v` 内 7 处），V-05 若按字面断言「在端口上观测」，在顶层不可见，只能看内部波形。 |
| **可粘贴处置文本（给 t4 / t8）** | ```verilog
// 方案 A（改 image_player，推荐 · 约 +8 LUT）：
//   在 ext_wr_mode 上升沿后插入 1 个「空拍握手」——首拍先给 ext_wr_valid=1 且
//   ext_wr_addr 不变，等 ext_wr_ack 为 1 才推进地址；若首拍被组基址吞掉，
//   ack 仍会回，故还需回读校验或用下面的 B 方案。
// 方案 B（改 arbiter，最彻底 · 约 +12 LUT）：
//   给 framebuf_arbiter 增加输入 wire wr_abort_group，
//   并在 image_player 里 assign wr_abort_group = ext_wr_mode;
//   arbiter 内：always @(posedge clk) if (wr_abort_group) wr_grp_active <= 1'b0;
//   // 语义：外部接管写口时立即放弃未走完的 BMP 写组，BMP 侧本就会被冻结。
// 方案 C（不改 RTL，只改验收判据）：
//   把 V-05 断言从「跳变拍 wr_grp_active==0」改为
//   「从 ext_wr_mode 置 1 起 4 拍内不得出现 ext_wr_ack=1」，并在 TB 里
//   真值表比对该 4 拍的 app_wr_addr，确认无外部数据落到旧组基址。
``` |
| **状态** | 属**设计缺口而非实现错误**，t4 已按 addendum 把通路打通；本项须在 t8 集成前定口径（B 方案最省事且可测）。 |

### V-17 ✅ 端口漏接无 X 传播

| 项 | 内容 |
|---|---|
| **判定** | ✅ **五根新增线已全部显式接上**（12:58 版曾漏接，13:06:29 版已修） |
| **出处** | `rtl/storage/pix_reader.v`（360 行 / 12:58:26）新增端口 `:61 input wire [15:0] src_w,` `:62 input wire [15:0] src_h,` `:63 output wire [15:0] src_y,` `:64 output wire src_row_hold,` `:65 output wire map_ident`；`rtl/storage/image_player.v`（599 行 / 13:06:29）内部例化 `:571 pix_reader #(...) u_reader (` → **`:578 .src_w(src_w), .src_h(src_h),`**、**`:579 .src_y(reader_src_y), .src_row_hold(reader_row_hold), .map_ident(reader_map_ident),`**，三个观测 wire 在 `:583-585` 声明 |
| **理由** | ① 判据要求「必须显式接 `.src_w` / `.src_h`」，现已满足；`:576-577` 的注释直接写出整改依据：「【v2】R-07：新增端口必须显式接线。顶层五档源高经本模块透传，漏接会让 src_h 悬空成 x 并向整条像素通路扩散」——作者已知 R-07 并落实 ② **12:58–13:04 期间的真实缺陷已留档**：`:554`（当时的行号）只接了 17 根旧线，`.src_w/.src_h/.src_y/.src_row_hold/.map_ident` 五根全缺；`vlog` 与 `vlog +lint=all` **都 exit 0 零 warning** —— 悬空 input 在 Verilog 里不告警，这是本条判据存在的意义 ③ 现 `<pix_reader>` 的 `src_ok`（`pix_reader.v:173`）在 `src_w/src_h` 为 0 时会退回 `FRAME_LINES16` 恒等兜底，故即使漏接也不会崩，只会**静默失去行映射** —— 「不报错但功能消失」正是静默失效 ④ 遗留风险：`reader_src_y/reader_row_hold/reader_map_ident` 三个输出注释写「本模块不消费，留给顶层探针/仿真观测」，即**行映射结果目前无人使用**，V-03 的「同一源行被读 2 次」必须靠下游（`pix_mosaic` 或 `content_mux`）按 `src_row_hold` 复用上一行才成立，见 V-03 与 A-2。 |
| **遗留** | `image_player` 侧 `src_w/src_h` 现直接来自端口 `:79-80`，顶层须由 `eff_src_w`/`eff_src_h` 驱动（V-07），不要在 t8 里漏成常数组。 |

### V-11 ⚠️ `ext_wr_addr[1:0]` 恒为 `2'b00`（**判据本身写错了：实现是逐字递增，「每拍为 0」必然失败**）

| 项 | 内容 |
|---|---|
| **判定** | ⚠️ **需处置 —— 缺陷在判据侧，不在实现侧**（`rle_decoder.v` 的地址生成符合设计意图，`T7_MUST_TEST.md:27` 的断言按字面写会在功能完全正确时 `$error`） |
| **出处** | 判据：`reports/plan_v2/T7_MUST_TEST.md:27`「`if (ext_wr_valid && (ext_wr_addr[1:0] !== 2'b00)) $error("V-11 未对齐 addr=%h", ext_wr_addr);`」<br>实现：`rtl/storage/rle_decoder.v`（**635 行 / 13:22:49 快照，仍在滚动修订**）`:120 output reg [20:0] ext_wr_addr, // word address, 4-word aligned at group start`、`:317/:320 ext_wr_addr <= ext_wr_addr + 21'd1;`（逐 word +1）、`:329-333`「`wcount >= 3'd4` 才开新组，`group_left <= 2'd3`」、`:137-138 BANK_A_BASE = 21'd0 / BANK_B_BASE = FRAME_WORDS[20:0]（=76800，4 整除）`<br>仲裁器：`rtl/storage/framebuf_arbiter.v:121-122 assign app_wr_addr = WR_ADDR_FROM_FIFO ? (wr_grp_active ? wr_base_hold : wr_word_addr) : wr_addr;`、`:197 if (!wr_grp_active) wr_base_hold <= wr_word_addr;`、`:95 wr_last_beat = (wr_beat == 2'd3);`、`:198 wr_grp_active <= !wr_last_beat;` |
| **理由** | ① 判据要求「**每一拍** `ext_wr_valid=1` 时 `ext_wr_addr[1:0]` 必须为 `2'b00`」，但 `rle_decoder` 的地址是**逐 word 递增**的：一个 4 拍写组内低 2 位必然是 `0,1,2,3` → **按原判据写 TB，功能完全正确也会在组内第 2 拍起恒报错** ② 真正需要保证的性质不是「每拍为 0」而是「**每个写组首拍为 0**」：仲裁器只在 `!wr_grp_active` 时把外部地址采样进 `wr_base_hold`（`framebuf_arbiter.v:197`），组内 3 拍的自增地址由仲裁器自己的 `wr_addr` 产生，**外部 `ext_wr_addr` 在后 3 拍被完全忽略** ③ 该性质已由构造保证：`BANK_A_BASE = 0`、`BANK_B_BASE = FRAME_WORDS = 76,800`，两者都被 4 整除；`rle_decoder.v:329` 只在 `wcount >= 4` 时开组，故新组基址 = `frame_base + 4k`，**永远不会出现非对齐组首**（文件头 `:56-62` 作者已写清这条论证，但 `:43` 的 `P1` 表述是「at the start of a write group」，与 `T7_MUST_TEST.md:27` 的「每拍」不是一回事）④ 不是实现缺陷，故不判 ❌；也不能判 ✅（判据未勘误，TB 无法按现状写）。 |
| **可粘贴处置文本（给 verifier / t9，二选一）** | ```text
方案 A（推荐，改判据，0 RTL 成本）：
  把 T7_MUST_TEST.md:27 的断言改成「写组首拍对齐」，两种等价写法任选：
    // A1 靠仲裁器内部信号（需层次化引用）
    always @(posedge clk) if (dut.u_player.u_arb.wr_grp_start && (ext_wr_addr[1:0] !== 2'b00))
        $error("V-11 组首未对齐 addr=%h", ext_wr_addr);
    // A2 纯端口可观测写法（不引内部信号）：valid 上升沿那拍必是组首
    reg ext_wr_valid_d;
    always @(posedge clk) ext_wr_valid_d <= ext_wr_valid;
    always @(posedge clk) if (ext_wr_valid && !ext_wr_valid_d && (ext_wr_addr[1:0] !== 2'b00))
        $error("V-11 组首未对齐 addr=%h", ext_wr_addr);
  并追加一条正向断言：组内递增值必须严格 +1，即 ext_wr_valid && ext_wr_valid_d 时 ext_wr_addr == ext_wr_addr_d + 1。

方案 B（不改判据，改实现）：让 rle_decoder 每拍都送组基址、由仲裁器自己 +1
  —— 即去掉 :320 的逐拍自增，改为「仅在开新组时置 frame_base 起的组基址」。
  代价：失去「组内 ack 乱序也能对齐」的自证性，且要重验 ext_wr_addr 与 wr_done_cnt 的耦合，不推荐。
``` |
| **归属** | 判据勘误 → t9（verifier）；RTL 侧无需改动 |

### V-12 ✅ `ext_no_fade` 在视频模式恒为 1（**RTL 已闭环；但判据断言本身有口径错，须勘误后再跑**）

| 项 | 内容 |
|---|---|
| **判定** | ✅ **RTL 侧闭环**（端口 + 旁路路径都已落地）；但 `T7_MUST_TEST.md:28` 的断言口径错，**照抄会永远失败**，见「口径勘误」与「可粘贴处置文本」 |
| **出处** | `rtl/storage/image_player.v`（599 行 / mtime 13:06:29）：`:76 input wire ext_no_fade, // 1=禁用淡入淡出，视频模式必须为 1`；**`:544 wire [7:0] fade_level = ext_no_fade ? 8'hFF : fade_alpha;`**；**`:588 fade_mixer u_fade (.rgb_in(reader565), .level(fade_level), .rgb_out(rgb565));`**；不淡黑分支 `:259 end else if (!FADE_ON \|\| ext_no_fade)` → `:262 if (vblank_rise)` 硬切换、`:269 ext_frame_ready_r <= 1'b1;`；`rtl/storage/fade_mixer.v:21 wire [8:0] gain = {1'b0, level} + 9'd1;`、`:29 assign rgb_out = {r_mul[12:8], g_mul[13:8], b_mul[12:8]};` |
| **理由** | ① `fade_level` 现**已被使用**：`:588` 的 `.level()` 接的是 `fade_level` 而不是 `fade_alpha` —— 13:02:36 / 13:04:04 两版曾出现「`fade_level` 声明了但 `u_fade` 仍接 `fade_alpha`」的死代码缺陷（全文件仅 1 处出现），13:06:29 已修，留档见 §0.1「曾出现并已修复的缺陷」② 当 `ext_no_fade=1` 时 `level=8'hFF` → `gain = 9'd256` → `r_mul[12:8]` 精确等于 `r_in`、`g_mul[13:8]` 等于 `g_in`、`b_mul[12:8]` 等于 `b_in`，**三通道逐位还原、零台阶**，即「视频模式恒 1 = 完全旁路淡入淡出」③ `:259` 分支另给一道保险：`ext_no_fade=1` 时连「淡出到黑」都不走，直接 `vblank_rise` 硬切换，不存在「旁路了淡化但仍淡黑」的半吊子状态 ④ **口径勘误（必改，否则 TB 恒失败）**：`T7_MUST_TEST.md:28` 写 `if (ext_wr_mode && (fade_alpha !== 9'd256)) $error(...);`，但 `fade_alpha` 是 **8 位**信号（`reg [7:0] fade_alpha`，取值 0~255），与 9 位常量比较时会先零扩展成 9 位，**永远不可能等于 256 → 断言在正确实现上也会恒真触发**。真正取到 256 的是 `fade_mixer.v:21` 内部的 `gain`，不是 `fade_alpha`。 |
| **可粘贴处置文本（给 verifier / t4）** | ```verilog
// 口径勘误（已留档于本报告 §0.1）：
//   fade_alpha 是 8 位，直通值 255（8'hFF）；
//   9'd256 是 fade_mixer.v:21 内部 gain = level + 1 之后的量，
//   不是 fade_alpha 的取值范围。
// 把 T7_MUST_TEST.md:28 的断言改成：
always @(posedge clk)
    if (ext_wr_mode && (fade_alpha !== 8'hFF))
        $error("V-12 淡入淡出未旁路：fade_alpha=%0d（应为 255）", fade_alpha);
// 更强的等价断言（直接看最终生效值，避免 fade_alpha 被别处改写时漏判）：
always @(posedge clk)
    if (ext_wr_mode && (dut.u_fade.level !== 8'hFF))
        $error("V-12 未旁路：fade_mixer.level=%0d", dut.u_fade.level);
``` |
| **反向用例（T7_MUST_TEST 明确要求必做）** | 强制 `ext_no_fade=0` 且 `ext_wr_mode=1`，在 8 帧内必须观察到 `fade_alpha` 出现 `< 255` 的台阶，以证明旁路确实依赖 `ext_no_fade` 而非巧合。此用例 `sim/testbench/tb_image_player.v`（**13:09:02 版 / 39,666 B / 768 行**）**仍无**：该版虽已把 `ext_no_fade` / `ext_wr_mode` / `ext_wr_valid` / `ext_frame_ready` / `ext_wr_done` / `src_w` / `src_h` 各接了一次（**每个仅 1 处 = 例化填常量，无激励、无断言**） → RTL 已 ✅，**反向用例仍缺**，须由 verifier 在 t9 补。 |

### M-3 ⚠️（补充登记）`image_player` 缺 `CHAIN_MAX` 对外参数 —— t8 照抄 addendum 例化片段会编译失败

| 项 | 内容 |
|---|---|
| **判定** | ⚠️ **`CHAIN_MAX` 只存在于子模块 `img_loader`，未提升为 `image_player` 的参数** |
| **出处** | `rtl/storage/image_player.v`（599 行 / mtime 13:06:29）参数表 `:25-36` 全部 10 个：`:26 WIDTH = 640`、`:27 HEIGHT = 480`、`:28 FIFO_AW = 9`、`:29 LOAD_TIMEOUT = 100_000_000`、`:30 MEM_WORDS = 262_144`、`:31 SEAMLESS = 1`、`:32 FADE_EN = 1`、`:33 FADE_FRAMES = 8`、`:34 ARBITER_TURN_GAP = 3`、`:35 FIFO_SECTOR_RESERVE = 96` —— **无 `CHAIN_MAX`**；全文 `CHAIN_MAX` 仅命中 **`:395 img_loader #(.CHAIN_MAX(4096)) u_loader (`**（写在内部子模块例化上，硬编码）；`docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md:550` 的 t8 例化片段写 `image_player #(.CHAIN_MAX(4096)) u_player (...)` |
| **理由** | ① `image_player` 的端口/参数表里没有 `CHAIN_MAX`，t8 若照抄 addendum `:550-559` 的片段，ModelSim/TD 都会报 **「Unknown parameter CHAIN_MAX」→ 直接编译失败**（t8 属 R-01 类风险，会连带 `tb_image_player.v` / `tb_display_content.v` / `tb_startup_ownership.v` / `tb_probe_*.v` 一起挂）② 语义上 `CHAIN_MAX` 是 `img_loader` 的 FAT 簇链上限（决定跨多少个不连续簇能拼成一帧），`image_player` 只在 `:395` 把常量 4096 透传下去；把 4096 提到顶层参数**不改变任何行为**，只是让 addendum 的例化片段合法 ③ 另注意：`project/hdmi/` 老副本里 `img_loader.v:62 parameter CHAIN_MAX = 255`、`fat32_reader.v:85 parameter FAT_CHAIN_MAX = 64` —— **`CHAIN_MAX`（4096）与 `FAT_CHAIN_MAX`（64）是两个不同参数，别混**。 |
| **可粘贴处置文本（给 t4，二选一）** | ```verilog
// 选项 1（推荐 · 0 LUT，只加一行参数声明，与 addendum 片段兼容）：
module image_player #(
    parameter WIDTH = 640,
    /* ... 原参数 ... */
    parameter FIFO_SECTOR_RESERVE = 96,
    parameter CHAIN_MAX = 64              // 【v2】FAT 簇链上限，透传给内部 img_loader；
                                          // 顶层可覆盖成 4096，不改变缺省行为
) ( ... );
// 并把 :395 改成：
img_loader #(.CHAIN_MAX(CHAIN_MAX)) u_loader (

// 选项 2（不改 RTL）：t8 例化时**不要**写 #(.CHAIN_MAX(4096))，
// 只写 #(.WIDTH(640), .HEIGHT(480))，并在 t8 报告里登记
// 「addendum :550 的 CHAIN_MAX 已在 image_player 内部硬编码为 4096，顶层不再暴露」。
``` |
| **归属** | t4 定口径；t8 落线前必须确认（否则 t8 一编译就停）。属 **R-04**（addendum `:661`，CHAIN_MAX=4096 撞链）的相关项。 |

---

## 3. rle_decoder（t4 · rtl-storage）

> **快照提醒**：本节三个条目（V-04 / P-3 / V-15）的行号均以 **13:22:49 / 635 行**快照为准。t4 随后又改到 **13:30:25 / 658 行**（与本预检并行推进），语义未变、行号整体平移约 15~20 行，**换算请查 §0.3.1 的对照表**。`tb_rle_decoder.v` 在 13:35 复核仍 **MISS**。

### V-04 ⏳ 解压正确性（`sum(run)==307200`、`run_len==0 → 256`）

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **代码已落盘且静态审计通过，但没有 TB → 无实测证据**（`sim/testbench/tb_rle_decoder.v` **MISS**，13:25 复核） |
| **出处** | 实现：`rtl/storage/rle_decoder.v`（**635 行 / 11-02 13:22:49 快照，仍在滚动修订**）；契约：`docs/plan_v2/ARCH.md:515-567`（`:518-556` 端口表、`:553` err_code 定义、`:562` run_len 语义、`:563` 两像素拼 word、`:564` 整帧原子性、`:565` 欠载保持、`:566-567` 帧率与降档）；TB：`sim/testbench/tb_rle_decoder.v` **MISS** |
| **理由** | ① 判据三重：前 6 帧 `sum(run) == 307200`、`run_len==0` 展开为 256 像素（addendum `:656` 锁死前 6 帧共 2,371 次）、`err_code=3` 只在 `run_len` **超范围**时置位（`0` 不是非法值）② **静态侧三条都已核对成立**：`run_left` 是 `[8:0]`（`:178`，可表示 256）、`:525 run_left <= (cur_byte == 8'd0) ? 9'd256 : {1'b0, cur_byte};`、`:492-495` 每 word 吃 2 像素且奇数余量走 `px_half`（`:487-499`，一个 word 既不写两次也不丢）③ **唯一硬缺口是没有专属 TB**：`tb_rle_decoder.v` 至今 MISS，`sum(run)==307200` 与「前 6 帧 2,371 次 `run_len==0`」这两条**必须跑仿真才能证明**，静态审计代替不了 → 判 ⏳ 不判 ✅ ④ 另注意 `err_code=3` 的语义与契约有冲突，已在 §9「附带发现 A-7」单列，**这会直接影响本条第二项的判定口径**。 |
| **另需先解决的阻断项** | 若要用现有 `tb_pix_reader`/`tb_image_player` 一并做端到端，会遇到**加密 SDRAM 模型无法在 ModelSim ASE 编译**的问题（`sdr_as_ram.enc.v` 报 `Macro \`DATA_WIDTH is undefined` 与 `in protected region`，vlog exit=2）——已在 §9「附带发现 A-9」记录；`rle_decoder` 的纯解码 TB 不例化 SDRAM，可先走这条路。 |

### P-3 ✅ `run_len = 0` 是否按 256 处理

| 项 | 内容 |
|---|---|
| **判定** | ✅ **源码语义正确**（与 §7 的 P-3 是同一判据，此处为详版；两处判定一致） |
| **出处（实现）** | `rtl/storage/rle_decoder.v`（635 行 / 13:22:49 快照）：`:178 reg [8:0] run_left;`（**9 位，能表示到 256**）、**`:521-528 case (ent_idx) ... default: run_left <= (cur_byte == 8'd0) ? 9'd256 : {1'b0, cur_byte};`**（快照内行号 `:525`）、`:35-37` 文件头「`3 * run_count` bytes, each entry `{rgb565[15:0], run_len[7:0]}`… **run_len == 0 means 256 pixels**」、`:492-499` 展开路径（`run_left >= 2` 一次吐 2 像素；余 1 像素存 `px_lo` + `px_half`，由下一个 run 首像素补成整 word） |
| **出处（契约）** | `docs/plan_v2/ARCH.md:562`「**`run_len = 0` 表示 256**」；`T7_MUST_TEST.md:37`（同判据的验收表述）；`ARCH.md:565`（欠载保持上一帧） |
| **理由** | ① `run_len` 是 8 位字节（0~255），**0 必须被展开成 256 像素**；实现用 9 位 `run_left` + 三元选择 `(cur_byte == 8'd0) ? 9'd256 : {1'b0, cur_byte}`，**这是唯一正确写法之一，已核对** ② 若写成 `reg [7:0] run_left` 则 `9'd256` 会被截成 0 → 每个 0-run 静默少画 256 像素（屏上「横向条纹错位」），属静默失效 ③ `px_half` 的奇偶处理也一并核对：`:487-491` 补半个 word 时 `run_left <= run_left - 9'd1`、`:492-495` 整 word 时 `- 9'd2`、`:496-499` 只剩 1 像素时存 `px_lo` 并清零 —— **一个 word 既不会写两次也不会丢** ④ **本条只判「源码里 0 的语义怎么写」，不要求跑仿真**，故判 ✅ 而非 ⏳；但 `sum(run)==307200` 的**结果**仍需 TB 证明，那条留在 V-04（⏳）。 |
| **⚠️ 但 `err_code=3` 的语义同时** | `rle_decoder.v:126` 端口注释写「`1=magic 2=geometry 3=pixel count 4=truncated/block error`」，而 `ARCH.md:553` 契约写「**3=`run_len` 非法**」。**实现里根本不存在「run_len 超范围」这个错误源**（8 位字节 0~255 全合法）——这是契约与实现的语义冲突，须在 t10 前统一，详见 §9「附带发现 A-7」。**不影响本条 P-3 判定**（0→256 本身是对的）。 |

---

## 4. video_content_mux（t8 · rtl-integ）

### V-08 ⏳ `content_mux` 端口缩减

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **未动**（t8 范围，且**当前已确认不符合**——但不报 ❌，因为归属未到） |
| **出处** | `rtl/video/video_content_mux.v:11`（`input wire [23:0] science_rgb,` 仍在）、`:18`（`2'd2: rgb_out = 24'hFF_00_00;` 应急仍是**纯红屏**，不是 emerg_page）、`:19`（`2'd1: rgb_out = science_rgb;`）；顶层 `rtl/top/dmz_eg4s20_hdmi_top.v:133`（`wire [23:0] science_rgb;`）、`:135`（`science_page u_science_page (... .rgb_out(science_rgb));`）、`:283`（`.science_rgb(science_rgb)`） |
| **理由** | ① 判据要求「`science_rgb` 必须不存在、`emerg_rgb` 在 `mode==2'd2` 时直通 `rgb_out`」——当前**两项都不满足**：`science_rgb` 活着、`emerg_rgb` 不存在、`mode==2'd2` 出纯红 ② 这是 t8 的交付内容（addendum `:531` 删 `u_science_page`、`:561-568` 改 `video_content_mux` 例化），**现属未开工而非实现错误**，按任务书纪律标 ⏳ |
| **归属** | t8（rtl-integ）。落地要点：`science_rgb` 用 `emerg_rgb` 替换（端口数 3→3 不变），`2'd2: rgb_out = emerg_rgb;`。注意 `T7_MUST_TEST.md:47` 的说法是「`science_rgb` 必须不存在」，实测该端口在 `:11`，删它同时要删顶层 `:133`/`:135`/`:283` 三处。 |

---

## 5. mode_ctrl / osd（t8 / t3）

### V-06 ⏳ `disp_mode` 延迟生效无闪黑

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **未落盘** |
| **出处** | `rtl/control/mode_ctrl.v`（14,140 B / mtime 11-02 00:01:23）全文 grep `disp_mode` / `rle_frame_ready` / `frame_ready` = **0 命中**；端口区 `:73-93` 只有 `clk` / `rst_n` / `key_event` / `key_code[3:0]` / `temp_alarm` / `mode[1:0]` / `emerg_latched` / `emerg_src[1:0]` / `confirm_armed` / `mode_changed` / `daily_mode` / `science_mode` / `emerg_mode` |
| **理由** | ① V-06 需要 `disp_mode` 这个**延迟一档**的信号（`mode` 立刻变、`disp_mode` 等 `rle_frame_ready` 才变），当前 RTL 完全没有 ② `mode_ctrl.v:45` 有一处「2 s」注释，但那是**退出应急的双按确认窗**，不是 V-14 的首帧超时——**两者不要混** ③ 顶层 `dmz_eg4s20_hdmi_top.v:121` 与 `:280` 现都直接接 `.mode(mode)`，t8 需改成 `.mode(disp_mode)`（addendum `:561-568`）。 |
| **归属** | t8。落地点：`mode_ctrl` 增 `disp_mode[1:0]` 输出 + `rle_frame_ready` 输入 + 2 s 超时（与 V-14 同一处改动）。 |

### V-14 ⏳ R-06 的 2 s 超时确实生效

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **未落盘** |
| **出处** | 同 V-06：`rtl/control/mode_ctrl.v` 无 `rle_frame_ready`、无 `disp_mode`、无首帧超时逻辑；判据依据 `T7_MUST_TEST.md:46` 与 `ARCH_ADDENDUM:660` 原话「**必须有超时，否则是"假死"体验**」 |
| **理由** | ① 失效场景很具体：SD 卡坏 / `SCI.RLE` 缺失时按 Key2 进科普 → 若 `disp_mode` 永远等不到 `rle_frame_ready`，界面**停在日常画面且后续按键"无反应"**，用户判定为死机 ② 要求：2 s 后 `disp_mode` 强制为 `2'd1`，且 `osd_caption` 报出错误行 ③ 与 V-06 是**同一次改动**的两面（一个管「正常路径不闪黑」、一个管「异常路径不假死」），必须一起做、一起测。 |
| **归属** | t8。**建议把 V-06 + V-14 合并成一个 TB 用例组**（正常 3 拍内就绪 / 永不就绪 2 s 超时），避免只测好路径。 |

### V-13 ⏳ 三条状态行文案在 9 列内互不相同（**行号分配口径已变，需先裁决再落地**）

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **文案仍未落地**；且 t3 新版 `osd_strings.v` 已把 line 8..15 全部占用，**V-13 原定的 line 13/14 已被吃掉** → 须先定行号再谈断言（**13:35 复核仍 0 命中**） |
| **出处** | `rtl/osd/osd_strings.v`（**29,303 B / 455 行 / mtime 11-02 13:19:29**，已被 t3 从 156 行大改）：`:18-20` 新表结构注释「line 0..7 ASCII 静态带：标题 / 序号 / PLAY..FAIL 六个状态；**line 8..13 六段中文校园介绍，IMG n（n=1..6）对应 line 7+n**；**line 14..15 应急疏散文案：三段共 104 字（36+32+36，不含 2 个分隔空格），拆两行由 osd_caption 每滚完一轮交替显示**」，`:23` 还写「三组行不能互换：坐标常量与 t_line 的译码都按这个分配写死」；实测条目：line 0 `:47-57`（`SMART CAMPUS`）、line 1 `:60-64`（`IMG #*`）、line 2 `:67-70`（`PLAY`，4 字符）、line 3 `:73-77`（`PAUSE`）、line 4 `:80-83`（`AUTO`）、line 5 `:86-92`（`WAITING`）、line 6 `:95-103`（`EMERGENCY`，9 字符 10'd384-392）、line 7 `:106-109`（`FAIL`）、line 8 起 `:112` 是中文（`'黎' 10'h3CD` 等，10'd512 起）；**全文 grep `SD NEEDED` / `KEPU LOAD` / `SD_NEEDED` / `KEPU` = 0 命中**；`rtl/osd/osd_caption.v`（19,757 B / 377 行 / 13:07:18）：`:108 input wire [3:0] state_line, // 状态行行号，取 2..7（越界则显示空白）`、`:128 STATE_X0 = 11'd32`、`:129 STATE_X1 = 11'd103`、`:134 localparam [3:0] STATE_EMERGENCY = 4'd6;`、`:189 ticker_emergency = (state_line == STATE_EMERGENCY);` |
| **理由** | ① V-13 原判据要求 `state_line = 4'd14`（`SD NEEDED`）/ `4'd13`（`KEPU LOAD`）/ `4'd2`（日常 `PLAY`）三组 `col=0..8` 的 `char_code` 序列两两不等 ② **t3 的新版把 line 13 给了中文校园介绍第 6 段、line 14/15 给了应急疏散文案**，`osd_caption.v:108` 的注释甚至把 `state_line` 收窄成「取 2..7」→ **line 13/14 现在已不是状态行**，V-13 按原行号跑必然读到中文段落 ③ 好消息：三条文案的长度在 9 列内**天然可分**（`SD NEEDED` 9 字符、`KEPU LOAD` 9 字符、`PLAY` 4 字符，第 0 列就分成 `SD` / `KE` / `PL`），**文案设计本身是对的**，只是行号要重新分配 ④ `osd_strings.v:6` 仍写「由 `scripts/gen_osd_strings.py` 生成，请勿手工编辑」（脚本 `scripts/gen_osd_strings.py` 18,898 B / 13:00:05）→ 文案改动必须改脚本后重生成，不能直接编辑 `.v`。 |
| **可粘贴处置文本（给 arch-lead / t3，二选一，需裁决）** | ```text
方案 甲（保留 V-13 原行号，挪中文）：
  line 0..7  ASCII 静态带（不变）
  line 8..13 六段中文介绍 → 改为 line 8..13 不动，
  但把「SD NEEDED」「KEPU LOAD」放进 line 2..7 的空槽：
    line 2 = PLAY（现状保留）
    line 3 = PAUSE
    line 4 = AUTO
    line 5 = WAITING
    line 6 = EMERGENCY
    line 7 = FAIL
  → 无空槽可用；故必须新增行或用 line 2..7 的复用分支（state_line 由 video_overlay 译码，
    同一个 line 号在不同 mode 下内容不同 —— 但 osd_strings 是按 (line,col) 纯查表，
    做不到「同 line 不同内容」）→ 方案甲不可行。

方案 乙（推荐 · 改判据行号，不动 t3 已交付的中文表）：
  在 osd_strings 里新增两行 line 16 / line 17（当前只用 0..15，line_sel 是 4 位 → 上限 15，
  故需把 line_sel 扩到 5 位，约 +2 LUT，并同步改 osd_caption.v:108 的位宽）：
    line 16 = "SD NEEDED"（9 字符）
    line 17 = "KEPU LOAD"（9 字符）
  然后 V-13 断言改为：
    state_line == 5'd16 → "SD NEEDED"
    state_line == 5'd17 → "KEPU LOAD"
    日常态仍用 line 2 → "PLAY"
  三条在 col=0..8 的 char_code 序列两两不等（第 0 列即分 `S`/`K`/`P`）。

方案 丙（最省事 · 把三条并进一条滚动带）：
  不新增行，改为复用 line 15 的 TICKER 机制：三条状态文案作为 ticker 的三个固定段，
  由 ticker_en / state_line 选择起始偏移。V-13 判据相应改为
  「三条状态在 ticker 缓冲区的起始偏移不同，且各自 9 列内无重叠」。
``` |
| **归属** | arch-lead 定行号（方案乙或丙）→ t3 改 `scripts/gen_osd_strings.py` 重生成 `osd_strings.v` → 本预检重跑。**在行号定下来之前，V-13 只能保持 ⏳，不能判 ❌。** |
| **旁证** | 可见宽度 9 列已实测确认：`osd_caption.v:128` `STATE_X0 = 11'd32`、`:129` `STATE_X1 = 11'd103` → `(103−32+1) = 72 px ÷ 8 px/字 = 9 列`，`:241` 的状态带判断与 `:256 band_state_x` 一致。 |

---

## 6. 跨模块 / 集成类

### V-09 ⏳ 音频不受影响

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **待集成**（需视频链路跑起来才有意义） |
| **出处** | `rtl/audio/wav_stream_player.v:73`（`parameter LOW_WM = 256`）、`:89`（`output reg [9:0] fifo_level`）、`:95`（`output wire want_blk`）、`:332`（`wire need_dat = more_data && clu_has_sec && (fifo_cnt < LOW_WM[FIFO_AW:0]);`）、`:340`（`assign want_blk = play_en && (bus_locked || want_more);`）、`:421`（`fifo_level <= fifo_cnt[9:0];`） |
| **理由** | ① 判据「视频播放期间 `fifo_level` 不跌破 `LOW_WM`」——抢占机制（`want_blk` 优先级）在 RTL 里已存在 ② 视频播放路径**在 RTL 侧已齐**（`rle_decoder.v` 13:14 已落盘），但 **t8 顶层尚未把 `u_rle` / `u_player` / `u_audio` 共用同一条 SDRAM 仲裁**接线（`dmz_eg4s20_hdmi_top.v` 仍是 10-31 旧版），且 A-9 阻断端到端仿真，故无并发争用可测 ③ 故 ⏳。t8 落线 + A-9 解除后需抓 10 s `fifo_level` 最小值。 |

### V-10 ⏳ 资源不超限

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **待 TD 综合**（且**新增模块全部未经综合**） |
| **出处** | 基线：`SmartCampusMedia/reports/diag_key1_fifo_backpressure_20261101/area.txt`（`:11` `:13` `:17` `:21` `:156` `:162` `:188` `:205` `:216`）；LUT 上限 19,600 见 `T7_MUST_TEST.md:49`；增量预算见 `docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md:591-603`（表）与 `:607`（权威口径提示）；三个新模块实测见 §8.1.B 所列四份 `project/t1_geom_area|t2_emerg_area` 报告 |
| **口径（铁律）** | 只引 `SmartCampusMedia/reports/diag_key1_fifo_backpressure_20261101/area.txt` 的 **le / lut / bram / dsp** 四列，**不引 ripple**。该表头在 `:156`：`\|Instance\|Module\|le\|lut\|ripple\|seq\|bram\|dsp\|`（注意**多一列 seq**，引用时不要错位）。 |
| **基线实测值（可引用，均取自上述快照）** | `:11 #lut 15319 / 19600 78.16%`；`:13 #le 16039`；`:17 #bram 17 / 64 26.56%`；`:21 #dsp 19 / 29 65.52%`；层级：`:216 \| u_science_page \| science_page \| 1044 le \| 664 lut \| … \| 0 bram \| 0 dsp`、`:188 \| u_image_mask \| image_window_mask \| 82 le \| 41 lut \| … \| 0 \| 0`、`:205 \| u_reader \| pix_reader \| 2255 le \| 2180 lut \| … \| 0 \| 0`、`:162 \| u_ctrl \| player_ctrl \| 121 le \| 104 lut` |
| **新增模块的资源 —— 已有 3 个实测，其余 5 类只能「按预算/外推」** | **【2026-11-02 12:42–12:50 新增实测，t1/t2 独立综合】**<br>• `ratio_map` **14 lut / 14 le / 0 bram / 0 dsp**（`project/t1_geom_area/reports/area_ratio.txt`）← 预算 +30，**省 16**<br>• `pix_mosaic` **50~64 lut / 0 bram / 0 dsp**（`project/t1_geom_area/reports/area_mosaic.txt`：`#lut 64`，层级表 lut 列 50）← 预算 +40 / +70 之间<br>• `emerg_page` **339 le = 339 lut / 0 bram / 0 dsp**（`project/t2_emerg_area/reports/area.txt`，`#lut only 339 out of 339 100.00%`、`#reg only 0`）← 预算 +400，**省 61**，且实测证明**零寄存器**<br>详见 §8.1.B。<br><br>**【仍无实测，必须写「按预算/外推」】**<br>• `pix_reader` 行映射 **+30 LUT**（addendum `:353`）<br>• `image_player` 写口 mux **+80**、`commit_pending` **+3**、冻结 `load_req` **+6**、fade 直通 **+8**（`:596` 一带）<br>• `eff_src_w` 生成 **+18**（`:583`）<br>• `rle_decoder` / `brightness_apply` / `cjk16` 字库 —— addendum 未给单项数字，**无预算可用**<br>• `video_content_mux` **−30**、删 `science_page` **−664**（后者是 `:216` 的**实测** 664 lut，可引）<br><br>**【按预算的净额】** addendum `:591-603` 合计 **−109 LUT**（算式 80+3+6+8+40+30+18−30−664+400）。若把 §8.1.B 的三个实测值代入（`pix_mosaic` 取 50、`ratio_map` 取 14、`emerg_page` 取 339）：**80+3+6+8+50+30+18−30−664+339 = −160 LUT** → 比预算**更乐观 51 LUT**。**该新算式仍是「混合口径」（3 项实测 + 6 项预算），引用时必须逐项标注。** |
| **理由** | ① 判据「`LUT ≤ 19,600` 且 `SWNS ≥ 0` 且 `HWNS ≥ 0`」必须 TD 综合后才有数 ② **t7 六份交付里已有 3 个模块拿到独立综合实测**（`ratio_map` 14 / `pix_mosaic` 50~64 / `emerg_page` 339，见上表与 §8.1.B），但**这 3 份不是全 top 综合，也不能直接与 15,319 相加**；`rle_decoder` / 改造后的 `pix_reader` 行映射 / `image_player` 外部写口 / `eff_src_w` 译码 / `brightness_apply` / `cjk16` 字库**仍一个都没综合过**——所以现在**任何「资源没问题」的整体结论都是空口** ③ 特别提醒：`T7_MUST_TEST.md:49` 自己已声明基线快照「是 t5 开始前状态，t5 六模块 2,014 行尚未计入」——即**真实起点已高于 15,319**，V-10 的实际余量比表面更紧 ④ addendum `:607` 另给一个更保守的权威口径：「`RESOURCE_BUDGET.md` §3.4 已按逐行重建重算为 **17,513 / 89.35% / 余 2,087**（P0 +449、P1 +1,745，含中文字库 +240）—— 那才是权威口径」。**两个口径差 2,194 LUT**，V-10 判定时必须明确用哪个，建议用 17,513 那个（更保守）⑤ **`SWNS/HWNS ≥ 0` 不能用 t1/t2 的 `gate.qor` 顶替**：那两份是模块级综合且无 SDC，`Setup WNS = 2147483647` 是「无路径」哨兵值，不是余量。 |
| **归属** | t8 综合后由 verifier 判 |

### V-15 ✅ 帧原子性（整帧 153,600 words）

| 项 | 内容 |
|---|---|
| **判定** | ✅ **源码侧成立**（静态审计通过，非仿真证明） |
| **出处** | 判据 `T7_MUST_TEST.md:40`；依据 `ARCH_ADDENDUM:873-879`（§18.5）、`ARCH.md:564`（「整帧原子性（`frame_word_cnt` 强制清 0 不续写）」）<br>实现 `rtl/storage/rle_decoder.v`（635 行 / 13:22:49 快照）：`:136 localparam [31:0] FRAME_WORDS = FRAME_PIXELS >> 1;`（640×480 → 153,600）、`:216 wire pack_done = (wr_done_cnt == FRAME_WORDS[17:0]) && !ext_wr_valid;`、**`:336 if (pack_done) ext_wr_done <= 1'b1;`（整个文件里 `ext_wr_done` 唯一的置位点，且是单拍脉冲）**、`:504-507` 只有 `!px_half && pixel_done && pack_done` 才翻 bank 并进 `R_FRAME_END`、`:508-511` 字数不足置 `err_code<=4'd3` 并回 `R_IDLE`（**不发 done**）、`:341-353` `!play_en` 分支不置 done、`:418-419 frame_base <= (wr_bank == 2'd1) ? BANK_B_BASE : BANK_A_BASE; frame_go <= 1'b1;`（**每帧从 bank 基址重写，不续写**）、`:361-368` `if (!play_en || frame_go) ... ext_wr_addr <= frame_go ? frame_base : ext_wr_addr;`、`:479-483` 帧满后丢弃多余像素但继续走 run 计数（防死锁） |
| **理由** | ① 判据要求「一旦开始写后台帧必须写满 153,600 words；中途放弃时下一帧必须从 `FRAME_BASE` 重写，**不得续写**」② **实现满足**：`ext_wr_done` 只在 `wr_done_cnt == 153,600` 且最后一个 word 已被 ack（`!ext_wr_valid`）时打一拍；任何异常路径（字数不符 / 文件截断 / `!play_en` / `blk_err`）都**不清零也不置 done**，而是回 `R_IDLE` 并在下一帧从 `frame_base` 重新起算 `ext_wr_addr` 与 `wr_done_cnt`（`:361-368` 的 `frame_go` 分支同时清了 `wr_done_cnt`/`wtail`/`whead`/`wcount`）→ **不存在跨帧续写** ③ 失效现象本该很隐蔽（上下半帧属于不同帧号，每行都完整、不像撕裂，易被误判成素材问题），但实现把三处计数**都绑在同一个 `frame_go` 清零事件**上，结构性排除了这种可能 ④ **仍是静态结论**：`tb_rle_decoder.v` MISS，所以「实测 ✅」要等 t9；按本报告口径（RTL 侧是否成立）判 ✅，与 §0.1 的 ✅ 分类「静态审计通过」一致。 |

### V-16 ✅ `fat32_reader` 能读到 `SCI.RLE`

| 项 | 内容 |
|---|---|
| **判定** | ✅ **已闭环（实测有代码 + 有 TB 覆盖）** |
| **出处** | `rtl/storage/fat32_reader.v`（42,276 B / mtime 11-01 22:50:44 / 673 行）：`:105 input wire [8:0] img_index`、`:117 input wire [87:0] target_name`、`:211 wire name_auto = (target_name[7:0] == 8'h00);`、`:273`、`:639-671`（双模 `exp_byte`：`:642-652` 按 `target_name` 逐字节比对；`else` 分支 `:657-667` 按序号拼 `IMGnnn.BMP`）、`:533-547`（首字节预筛已统一到 `exp_byte`，注释「只改一处会漏的失效模式消失」）；TB：`sim/testbench/tb_fat32_reader.v:41`（`reg [87:0] target_name = 88'd0;`）、`:66`（`.target_name(target_name)`）、`:524-539`（`task fire_start_name`）、**`:806-814`（T24：SCI.RLE 以小写 `sci.rle` 存储，found，first cluster = 7，size = 82,362,927）**、`:816-821`（T25 缺名 `err=4`）、`:823-828`（T26 自动模式防回归） |
| **理由** | ① 判据「必须加文件名模式参数后才能读到 `SCI.RLE`」——**已经加了**：`target_name[87:0]` 是 11 字符 × 8 位的通用 8.3 名输入，`name_auto` 为 0 时走精确名匹配 ② TB 里有专门的 SCI.RLE 用例（T24），且特意构造了**小写 `sci.rle`** 的目录项——**这连 FAT 大小写不敏感的行为一起验了** ③ 另保留自动模式（T26）防回归，说明改动是「加模式」而不是「换模式」，对既有图片路径零破坏。 |
| **⚠️ 必须登记的行号漂移** | `T7_MUST_TEST.md:50` 引的是 **`fat32_reader.v:599-614`（`exp_byte` 常量表写死 `IMGnnn.BMP`）与 `:96`（端口只有 `img_index[8:0]`）**——**这是旧版行号，已被整改**。现文件 673 行：`exp_byte` 双模在 `:639-671`、`target_name` 端口在 `:117`。`ARCH_ADDENDUM:657`（R-03）与 `:364`（P2 方案）引的也是同一组旧行号。**结论：V-16 判 ✅，但判据文档与 addendum 的行号需要勘误**，否则后续 verifier 会照着旧行号找不到东西、误判成「没做」。 |

### V-18 ⏳ 四个既有 TB 编译通过

| 项 | 内容 |
|---|---|
| **判定** | ⏳ **待改造后复验**（当前它们对**旧版** RTL 仍能编译，改造后需改 6 个不是 4 个） |
| **出处** | 判据列的 4 个：`sim/testbench/tb_image_player.v:72`、`tb_display_content.v:47`、`tb_startup_ownership.v:50`、`tb_pix_reader.v:103` |
| **实测：实际要改 6 个** | 另有 **`sim/testbench/tb_probe_order.v:115`**（`pix_reader #(`）与 **`sim/testbench/tb_probe_pix.v:135`**（`pix_reader #(`）也直接例化了 `pix_reader` → `pix_reader` 加 `src_w`/`src_h` 端口后，这两个 TB 同样会编译失败 |
| **理由** | ① `T7_MUST_TEST.md:52` 与 addendum `:655`（R-01）都只说「4 个 TB」，**实测是 6 个**——这正是 addendum 自己说的「本方案最容易被忽略的连带成本」，而它自己就漏算了 2 个 ② 建议缺省接法统一为 `.src_w(16'd640), .src_h(16'd480)`（等价旧行为），`image_player` 类 TB 再加 `.ext_wr_mode(1'b0)` / `.ext_no_fade(1'b0)` ③ 当前这 6 个 TB 对**旧版** RTL 可编译（尚未改坏），故判 ⏳ 而非 ❌。 |
| **可粘贴处置文本（给 verifier 的回归清单）** | ```text
t7 改造后必须重新编译并跑通的 TB（6 个，不是 4 个）：
  sim/testbench/tb_image_player.v     :72   image_player 例化 → 补 .ext_wr_mode/.ext_no_fade/.src_w/.src_h
  sim/testbench/tb_display_content.v   :47   image_player 例化 → 同上
  sim/testbench/tb_startup_ownership.v :50   image_player 例化 → 同上
  sim/testbench/tb_pix_reader.v       :103   pix_reader 例化 → 补 .src_w(16'd640)/.src_h(16'd480)
  sim/testbench/tb_probe_order.v      :115   pix_reader 例化 → 同上   ← 判据文档漏列
  sim/testbench/tb_probe_pix.v        :135   pix_reader 例化 → 同上   ← 判据文档漏列
``` |

---

## 7. 追加判据 P-1 ~ P-4（本任务书指定）

### P-1 ✅ `pix_mosaic` 是否照抄了 `ARCH_ADDENDUM:462-469` 的落后一拍伪码

| 项 | 内容 |
|---|---|
| **判定** | ✅ **未照抄，实现正确** |
| **出处** | `rtl/video/pix_mosaic.v:115`、`:117`、`:122`；对照 `docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md:443-457`（端口，`:454 output reg [15:0] rgb565_out` ← 坏源头）、`:461-471`（伪码，`:467 rgb565_out <= hold;` ← 落后一拍实体）、`:469`（自称 src_w==640 恒等，与 `:467` 自相矛盾） |
| **判据核对** | 任务书给的判据说「**源码里 `rgb565_out` 必须是组合赋值 `assign`，不能是时序块里的 `<=`**」——实测：<br>• `:117` `assign rgb565_out = take ? rgb565_in : hold;` —— **是 `assign`，组合** ✅<br>• `rgb565_out` 在端口区 **`:90` 声明为 `output wire [15:0]`** —— **是 `wire` 不是 `reg`**，从语言层面就排除了时序块赋值的可能 ✅<br>• 全文时序块 `:133-152` 只赋 `x_acc` 与 `hold` 两个内部寄存器，**没有任何一句给 `rgb565_out` 赋值** ✅ |
| **理由** | ① 这是本预检里**最关键的一条**：addendum 的伪码是错的，照抄会让 `src_w=640` 默认档整体左移 1 像素、右侧补 1 列旧像素，屏上极难察觉 ② 实现者不仅写对了，还在文件头 `:21-35` 写了大段说明点名「不能照抄 `:462-469` 的伪码…正确写法是组合旁路」，`:25` 还写清了失效现象「输出整体**落后一拍**」——**防复发注释到位** ③ ModelSim 实测 149/149 全过，含 I1 的 640 拍逐拍恒等。 |
| **遗留建议（不阻塞）** | `ARCH_ADDENDUM_VIDEO_PATH.md:461-471` 的伪码本身**仍是错的**，该文件是定稿正文，本次不改。但**建议在 t10/t11 的勘误表里登记**，否则下一轮会有人照着 addendum 重犯。文案：<br>「`ARCH_ADDENDUM_VIDEO_PATH.md:461-471` 伪码有落后一拍缺陷（`:467 rgb565_out <= hold;`），实现须用组合旁路 `assign rgb565_out = take ? rgb565_in : hold;` 且 `rgb565_out` 声明为 `wire`。正确实现见 `rtl/video/pix_mosaic.v:115-122`。」 |

### P-2 ✅ `emerg_page` 是否出现斜线或乘法

| 项 | 内容 |
|---|---|
| **判定** | ✅ **无斜线、无乘法、无除法、无移位** |
| **出处** | `rtl/video/emerg_page.v:25-30`（4 端口）、`:33-40`（调色板 localparam）、`:45-56`（外墙）、`:62-69`（走廊）、`:75-78`（分格竖线）、`:81-82`（当前位置）、`:89-92`（出口）、`:99-103`（路线）、`:108-121`（单个 `always @*`） |
| **运算符普查（去注释后全文扫描）** | `*` = **0 处**（唯一的 `*` 是 `:108` 的 `always @*` 敏感表，不是乘号）；`/` = **0 处**；`<<` / `>>` = **0 处**；`%` = **0 处**。**全部是范围比较与位切片。** |
| **几何为何无斜线** | ① 分格竖线 `:75-78` 用 `div_upper = (active_x[6:0] < 7'd2);` / `div_lower = (active_x[6:0]==7'd64)||(active_x[6:0]==7'd65);` —— **7 位比较**，零乘法 ② 路线 `:99-103` 全部轴对齐：`route_h` 是 `y[234,238)` 且 `x[162,216)`、`route_v` 是 `x[162,166)` 且 `y[86,236)` —— **先横后竖的直角折线**，正是 `ARCH_ADDENDUM:519`「最近路线直角折线先横后竖」与 `:520`「绝不用斜线」的要求 ③ 出口 `:89-92`、当前位置 `:81-82` 都是矩形范围比较。 |
| **理由** | ① 判据来源：`ARCH_ADDENDUM:520`「**绝不用斜线**（斜率会引入乘法器，DSP 只剩 **10/29**）」、`EMERG_SCREEN_RULING.md:234`（同义）、`:241`（「路线改成连续箭头链…两组三角形范围比较实现，仍无乘法」）② 实测 DSP 余量：baseline `area.txt:21` `#dsp 19 / 29 65.52%` → **剩 10 个**，确实没有余量给斜率乘法 ③ **资源口径已升级为实测（2026-11-02 12:42 后不必再外推）**：`project/t2_emerg_area/reports/area.txt` 给出 `emerg_page` **lut 339 / le 339 / bram 0 / dsp 0**，且 `#lut only 339 out of 339 100.00%`、`#reg only 0`、`#lut&reg 0` —— **零 DSP 由综合报告直接证实**（不只是 grep 结论），**零寄存器也同时印证了「纯组合」** ④ addendum `:523` 的「按 +400 LUT 编预算」已被实测覆盖：**实际 339 LUT，比预算省 61（15%）**。 |
| **TB 侧佐证** | `sim/testbench/tb_emerg_page.v:202-208` 有「逐行轴对齐带证明」：`y<234` 时只许 `x∈[162,165]`，否则只许 `x∈[162,215]`（`:219-224`），路线包围盒 `(162,86)-(215,237)`（`:226-233`）——**用 TB 反证了没有斜线**，这比 grep 更硬。ModelSim 实测 `checks=57 errors=0 fail=0`。 |

### P-3 ✅ `rle_decoder` 的 `run_len=0` 是否按 256 处理

| 项 | 内容 |
|---|---|
| **判定** | ✅ **源码语义正确**（`rle_decoder.v` 13:22:49 快照 / 635 行；静态审计，非仿真证明） |
| **出处** | 实现 = `rtl/storage/rle_decoder.v:178 reg [8:0] run_left;`（**9 位，能装 256**）、`:521-528` 的 `default:` 分支 `run_left <= (cur_byte == 8'd0) ? 9'd256 : {1'b0, cur_byte};`、`:35-37` 文件格式注释「run_len == 0 表示 256 像素」、`:492-499` 奇偶展开路径；契约 = `docs/plan_v2/ARCH.md:562`、验收 = `T7_MUST_TEST.md:37` |
| **理由** | ① 判据「`0` 必须展开成 256 像素」，实现用 **9 位计数器 + 三元赋值**，是唯一不会截断的写法之一，已逐行核对；② 若 `run_left` 写成 `[7:0]`，`9'd256` 会被截成 0 → 该 run **静默少画 256 像素**（横向条纹错位），不报任何错；③ `px_half` 奇偶配对同时核对：奇 run 会把末像素存入 `px_lo` 等下一个 run 拼 word（`:496-500`），`sum(run)==307200` 不会被破坏；④ 本条只判「源码里 `0` 的语义编码」，故 ✅；`sum(run)==307200` 的**结果**证据仍归 V-04 ⏳（TB MISS） |
| **⚠️ 同时登记** | `err_code=3` 的**语义**与 `ARCH.md:553` 契约不一致，见 §9 **A-7**（不影响本条判定，但会让 t10 照契约误判实现） |

### P-4 ✅ `image_player` 的 `ext_no_fade` 在视频模式是否恒 1（**RTL 侧成立；断言口径须勘误**）

| 项 | 内容 |
|---|---|
| **判定** | ✅ **RTL 侧闭环**（端口与旁路路径均已落地）；但判据断言 `9'd256` 有口径错，且 TB 零覆盖 |
| **出处** | 详见 §2「V-12」（本报告 `:227` 起）：`rtl/storage/image_player.v`（599 行 / 13:06:29）`:76 input wire ext_no_fade`、`:544 wire [7:0] fade_level = ext_no_fade ? 8'hFF : fade_alpha;`、`:588 fade_mixer u_fade (.level(fade_level))`、`:259 else if (!FADE_ON \|\| ext_no_fade)` 走 `vblank_rise` 硬切换不淡黑；`rtl/storage/fade_mixer.v:21 wire [8:0] gain = {1'b0, level} + 9'd1;` |
| **理由** | ① `ext_no_fade=1` → `level=255` → `gain=256` → 三通道逐位还原、零台阶，语义成立；② `:259` 分支另给一道保险：不淡黑，直接 `vblank_rise` 硬切换；③ **t8 必须保证顶层把 `ext_no_fade` 恒接 `1'b1`**（或接 `disp_mode` 的常量组合），不得留给键位/拨码，否则「视频模式恒 1」在顶层被破坏——addendum `:550-559` 的例化片段已引出该线，t8 只接线不做逻辑；④ **口径勘误（必改）**：`T7_MUST_TEST.md:28` 写 `fade_alpha !== 9'd256`，但 `fade_alpha` 是 8 位（0~255），该断言在正确实现上也会恒真触发 → 应改 `8'hFF`；⑤ **测试仍缺**：`sim/testbench/tb_image_player.v`（762 行 / 10-31 16:58:49）grep `ext_no_fade\|ext_wr_mode\|ext_wr_valid\|ext_frame_ready` = **0 命中**，含 T7_MUST_TEST 要求的「强制 `ext_no_fade=0` 看 `<255` 台阶」反向用例也没有 → 须 verifier 在 t9 补 TB 后才能把 P-4 从「RTL ✅」升级为「实测 ✅」。 |


---

## 8. 资源口径速查（引用本文件时的铁律）

> **全局声明（先读这条）**：本文件全部「处置方案 / 选项 / 方案 A·B·C」里出现的 LUT 数字（如 M-1 的「约 +2 LUT」、V-03 的「约 +24 LUT」、V-05 的「约 +8 / +12 LUT」、M-3 的「0 LUT」、V-13 的「约 +2 LUT」、M-2 的「LUT 成本 0」）**一律是按预算/外推的估算值，不是综合实测**——这些改动方案一个都还没落地、更没综合过。下文 §8.1.A / §8.1.B 里的数字才是实测，§8.1.C 列出的模块则连实测都不存在。

### 8.1 可以引用的实测值（唯一许可来源）

#### 8.1.A 全 top 基线（引用时必须用这一份）

`SmartCampusMedia/reports/diag_key1_fifo_backpressure_20261101/area.txt`，**只取 le / lut / bram / dsp 四列**，不取 ripple（表头 `:156` 有 8 列，多一个 seq，见 §6 V-10）。

| 模块 | le | lut | bram | dsp | 出处 |
|---|---|---|---|---|---|
| （全设计汇总） | 16,039 | **15,319 / 19,600（78.16%）** | **17 / 64（26.56%）** | **19 / 29（65.52%）** | `:13` / `:11` / `:17` / `:21` |
| `science_page` | 1,044 | **664** | 0 | 0 | `:216` |
| `pix_reader`（改造前版） | 2,255 | **2,180** | 0 | 0 | `:205` |
| `image_window_mask` | 82 | **41** | 0 | 0 | `:188` |
| `player_ctrl` | 121 | **104** | — | — | `:162` |

> 另一份快照 `reports/watchdog_20261030/area.txt` 给 `science_page` 1052 le / 672 lut（`EMERG_SCREEN_RULING.md:99` 引用），与上表差 8 le / 8 lut。**引用时须注明快照来源**，不要混用。另 `EMERG_SCREEN_RULING.md:208` 提醒：「reg 列对纯组合模块也非零（`science_page` 380），该列不是触发器数量」——同理，**le 列也不等于 LUT 列**。

#### 8.1.B 【2026-11-02 12:42–12:50 新增实测】t1/t2 独立综合结果

**这是本预检期间 t1（rtl-geom）与 t2（rtl-emerg）各自跑出来的独立综合报告**，`Device: EG4S20BG256`，LUT 总数均为 19,600（与基线同器件同口径）。它们**不是全 top 综合**（是被测模块单独作为 top 综合），因此**不能直接与 §8.1.A 的全设计 15,319 相加**，但**可以替换 addendum 的「按预算」数字**。

| 模块 | 报告 | lut | le | bram | dsp | 与 addendum 预算对比 |
|---|---|---|---|---|---|---|
| `ratio_map` | `project/t1_geom_area/reports/area_ratio.txt`（`Report Model: ratio_map`） | **14** | 14 | **0** | **0** | 预算 **+30**（addendum `:342`）→ **实测 14，省 16** ✅ |
| `pix_mosaic` | `project/t1_geom_area/reports/area_mosaic.txt`（`Report Model: pix_mosaic`） | **64**（汇总 `#lut 64`；层级表 `top` 行的 lut 列为 **50** —— 两列口径不同，引用取区间 **[50, 64]**，保守用 50） | —（该报告未单列 le，不臆造） | **0** | **0** | 预算 **+40**（addendum `:601`）/ **+70**（`:363`）→ **实测 50~64，落在两者之间** ⚠️ |
| `emerg_page` | `project/t2_emerg_area/reports/area.txt` / `area_plain.txt`（`Report Model: emerg_page`） | **339** | 339 | **0** | **0** | 预算 **+400**（addendum `:523`，按 le→lut 0.64 外推）→ **实测 339 le / 339 lut**（`#le 339`，`#lut only 339 out of 339 100.00%` → **纯 LUT 无寄存器**）✅ |

**口径说明（三条必须一起讲，否则会误导）**：

1. **`emerg_page` 实测 339 le = 339 lut**：`#le 339` + `#lut only 339 out of 339 100.00%` + `#reg only 0` + `#lut&reg 0` —— 该模块**全部是纯组合 LUT，一个寄存器都没有**，这直接印证了 P-2 的「纯组合零寄存器」结论。addendum `:523` 的预算 +400 LUT **偏保守 61 LUT**（15%），结论：**emerg_page 不超过预算**。
2. **`pix_mosaic` 的两个口径都出现**：单模块独立综合 `area_mosaic.txt` 的 `#lut 64`（含 `#ireg 16` 的输入寄存器被算进 LUT 统计），而同文件层级表 `|top |pix_mosaic |50 |14 |32 |0 |0 |` 的 lut 列是 **50**。在「全 top + 已有负载」的集成语境下，addendum 的 +40 更接近真实增量（独立综合因无扇出共享而偏大）。**取 50 作保守值、40 作乐观值，区间 [+40, +64]。**
3. **`ratio_map` 实测 14 LUT 远低于预算 30**：因为五档 case 被综合器优化成共享比较器。**这是真实利好，可以用。**

**t1/t2 的时序门禁（`gate.qor`）**：`Setup WNS = 2147483647`（= 无路径，即该目录综合无时序约束，不是「时序完美」）、`Num of violated S-EP 0`、`Hold WNS 2147483647`。**这个 `2147483647` 是「无约束」的哨兵值，不得解读成「时序余量无穷大」，也不得作为 V-10 的 SWNS/HWNS 证据**——V-10 的 SWNS/HWNS 必须在**全 top 带 SDC** 的综合里取。

#### 8.1.C 仍然只能写「按预算 / 外推」的模块（`area.txt` 全扫 0 命中，且 t1/t2 也没综合过）

`brightness_apply` / `rle_decoder` / `cjk16` 字库 / `pix_reader`（**改造后的行映射版**，现 19 处命中但那是改造前版）/ `image_player` 的外部写口改动 / `eff_src_w` 译码器 / `video_content_mux` 的端口改动。

**凡提到这些模块的 LUT，必须写明「按预算」或「外推」，不得当实测讲。**

> 已知冲突点保留：`pix_mosaic` 在 addendum `:363` 写 +70、`:601` 写 +40，两处不一致；现已有实测（§8.1.B）可覆盖二者，引用时**优先引实测并注明报告路径**。


---

## 9. 附带发现（不属 t7 判据，但会影响 t8 集成 / t9 回归）

| 编号 | 发现 | 出处 | 处置 |
|---|---|---|---|
| A-1 | **`sync_src.ps1` 白名单缺口 18 个**（`$map` 51 条 vs `rtl/` 64 个 `.v`），含 t7 新增的 `emerg_page.v` / `pix_mosaic.v` / `ratio_map.v`。`RESOURCE_BUDGET.md:502` 仍写「45 vs 61，差 16 个」，计数已过期 | `SmartCampusMedia/scripts/sync_src.ps1`（148 行）；`RESOURCE_BUDGET.md:444`（§9.1 门禁第 0 条）、`:502` | t8 前必须补齐，否则新增模块**不会进综合**（静默缺模块） |
| A-2 | **`res_src_w` 3→16 位译码器完全不存在** | 全 `rtl/` grep `res_src_w` / `16'd576` / `16'd512` = 0 命中 | t8 新建（约 +18 LUT，**按预算**） |
| A-3 | **`pix_mosaic` 端口命名与 addendum 不一致**：RTL 是 `.clk/.rst_n/.active_x/.src_w/.rgb565_in/.valid_in/.rgb565_out/.valid_out`（`pix_mosaic.v:82-91`），addendum `:575-580` 写 `.pixel_clk(...) .de(...)` 无 `.rst_n` | 两处对照 | **以 RTL 为准**（TB 与 RTL 已一致，`tb_pix_mosaic.v:98-107`）。t8 照抄 addendum 会编译失败——与 M-1 同类问题 |
| A-4 | **`osd_ticker.v` MISS** | `rtl/osd/` 下不存在 | t3 待交付 |
| A-5 | **`osd_strings.v` 由脚本生成**（`:6`「由 `scripts/gen_osd_strings.py` 生成，请勿手工编辑」） | `rtl/osd/osd_strings.v:6` | V-13 的文案改动必须改生成脚本后重生成，不能直接编辑 `.v` |
| A-6 | **`ARCH_ADDENDUM` 已从 T7_MUST_TEST 的基准 908 行漂移到 909 行**（现 68,367 B / mtime 11-01 23:46:24，而 `T7_MUST_TEST.md:89-101` 声明基准是 908 行 / 67,337 B / mtime 11-01 22:53:50） | 两者对照 | 后续引 addendum 行号须注明漂移 |
| **A-7（新）** | **`err_code = 3` 的语义，契约与实现不一致**：契约 `ARCH.md:553` 与 `T7_MUST_TEST.md:37` 都写「3 = `run_len` 非法 / 超范围」，但 `rle_decoder.v:126` 端口注释写「`3=pixel count`」，实际置位点是 `:458`（`run_count == 0`）与 `:509`（**像素总数与帧几何不符**）；而**实现里根本不存在「run_len 超范围」这个错误源**（`run_len` 是 8 位字节，0~255 全合法，最大展开 256） | `rtl/storage/rle_decoder.v:126`、`:458`、`:509`；`docs/plan_v2/ARCH.md:553`；`reports/plan_v2/T7_MUST_TEST.md:37` | **建议按实现修正契约**（推荐）：把 `ARCH.md:553` 与 `T7_MUST_TEST.md:37` 的「3=`run_len` 非法」改为「**3 = 像素数不符（含 `run_count == 0`）**」，并在 t10 合规审计前登记为「契约勘误」。理由：`run_len` 物理上不可能超范围，契约这条描述本身不成立；实现的两处触发点都指向「帧几何不匹配」，语义自洽。**否则 t10 会照契约判实现错。** |
| **A-8（曾阻塞级 · 13:30:25 已修复）** | **`rle_decoder` 的 `ext_wr_dm` 极性曾反 → 视频帧一个字节都写不进 SDRAM**。全链路是**高有效屏蔽**（`dm[n]=1` 表示屏蔽）：`sdram_ctrl_wrap.v:51` 原文「`dm[n]=1` 表示**屏蔽**」、`:384-387 if (!app_wr_dm[n]) mem[...] <= ...`、`framebuf_arbiter.v:30`「高有效字节屏蔽」、`:124 app_wr_dm = wr_real ? wr_dm : (wr_fire ? 4'hF : 4'h0)`（**补拍用 4'hF = 全屏蔽**）、`img_loader.v:106`「全写时为 4'h0」、`:539 fifo_wr_dm <= 4'hC; // dm=1 表示屏蔽 → 只写 [15:0]`。**13:22:49 快照**的 `rle_decoder.v:134` 写「always **4'hF**, all four bytes written」、`:255 assign ext_wr_dm = 4'hF;` → **真数据 beat 也全字节屏蔽**。`image_player.v:538` 直通无取反（`.wr_dm(arb_wr_dm)` 在 `:556`），故掩码原样送到 `sdram_ctrl_wrap` | `rtl/storage/rle_decoder.v`（**13:22:49 快照 `:134`、`:255`（缺陷）；13:30:25 快照 `:139`、`:265`（修复），并在 `:260-264` 留了极性说明）；`rtl/storage/sdram_ctrl_wrap.v:51`、`:384-387`；`rtl/storage/framebuf_arbiter.v:30`、`:124`；`rtl/storage/img_loader.v:106`、`:539`；`rtl/storage/image_player.v:538`、`:556` | **已闭环**：`13:30:25` 快照 `:265 assign ext_wr_dm = 4'h0;`、`:139` 端口注释同步改为「always 4'h0 … (dm[n]=1 masks)」，`:260-264` 还写明「img_loader 用同一极性（全写 4'h0、只写低半字 4'hC）」。**但「已修好」不能被任何编译/仿真告警证明**（字数照常累加、`ext_wr_done` 照常拉高），**t9 必须把「写后读回比对 SDRAM 内容」列为必测** |
| **A-9（新 · 阻断 t9 回归）** | **加密 SDRAM 模型无法在 ModelSim ASE 下编译**：`tb_pix_reader` / `tb_image_player` 一类端到端 TB elaborate 时报 `** Error: (vsim-3033) sdram_ctrl_wrap.v(268): Instantiation of 'sdr_as_ram' failed. The design unit was not found.`；补入 `ip/local/sdram/sdr_as_ram.enc.v` 后 `vlog` 报 `(vlog-2163) Macro \`DATA_WIDTH is undefined`（`:42`）与 `in protected region` / `syntax error in protected region`（`:109`），**vlog exit=2** | `%TEMP%\t6_pr_verify2` 实测（vlog/vsim 均在 `D:\Quartus_APP\modelsim_ase\win32aloem\`） | 两条出路：① **编译时定义 `SDRAM_SIM_MODEL`** —— `sdram_ctrl_wrap.v:127 `ifdef SDRAM_SIM_MODEL` 分支例化的是纯 Verilog 的 `sdram_behavior_model`（`:289-406`，含 `:384-387` 的 `dm` 掩码行为），**完全不碰加密核**；t9 的所有 TB 应统一带 `+define+SDRAM_SIM_MODEL` 编译（这也是 A-8 的唯一可验证路径）② 或用 TD 自带仿真器。**注意**：`iverilog` / `verilator` 本机均未安装，`vsim -c -run -all` 会报 `Unknown option '-run'`，必须写成 `vsim -c -quiet -do "run -all; quit -f" <tb>` |

---

## 10. 重跑清单（本预检的待补项 · 13:35 状态）

| 优先级 | 编号 | 当前卡点 | 谁来解 |
|---|---|---|---|
| **P0** | **V-04** | 代码已落盘且静态审计通过（`run_left[8:0]`、`9'd256` 展开、`px_half` 奇偶处理全部核对成立），但 `sim/testbench/tb_rle_decoder.v` **MISS** → `sum(run)==307200` 与前 6 帧 2,371 次 `run_len==0` 无实测证据 | t4 交付 TB / verifier(t9) 补跑 |
| **P0** | ~~**A-8（阻塞级）**~~ **已闭环** | `13:22:49` 快照的 `rle_decoder.v:255 assign ext_wr_dm = 4'hF` 在全链路「高有效屏蔽」语义下 = **全字节屏蔽**；`13:30:25` 快照已改 `:265 assign ext_wr_dm = 4'h0;` | 已由 rtl-storage 修复；**t9 仍必须加「写后读回比对」用例**（此缺陷不被任何编译/仿真告警抓到） |
| **P0** | **A-9（阻断 t9 回归，新）** | `sdr_as_ram.enc.v` 加密核 ModelSim ASE 编译失败（`vlog exit=2`），`tb_pix_reader`/`tb_image_player` 端到端跑不起来 | 所有 TB 统一带 `+define+SDRAM_SIM_MODEL` 走 `sdram_behavior_model`（`sdram_ctrl_wrap.v:127`） |
| **P0** | **V-11** | **判据本身写错**（要求每拍 `ext_wr_addr[1:0]==0`，实际逐字递增），RTL 侧无需改动 | 判据勘误 → verifier(t9)，按 §2 V-11 的方案 A 改写断言 |
| **P0** | V-03 | RTL 已✅（`pix_reader.v:61-65` + `:173-204`，`tb_pix_reader.v` 13:11 已加两个用例），但 ① 仿真被 A-9 阻断 ② `src_row_hold` **无下游消费者** | verifier(t9) 带 `SDRAM_SIM_MODEL` 重跑 + t8 落地消费（见 V-03 处置方案 A/B/C） |
| **P0** | V-05 | `ext_wr_mode` 跳变与 arbiter 四拍写组**无互锁**（最长吃 3 拍，丢写/错址） | t4 或 t8 按 §2 V-05 的 A/B/C 三方案之一处置 |
| **P1** | V-12、P-4、V-17、M-3 | **RTL 侧已✅/⚠️**；剩两件事：① 改 `T7_MUST_TEST.md:28` 的 `9'd256`→`8'hFF` 口径勘误 ② `tb_image_player.v` 补外部写口 + `ext_no_fade=0` 反向用例 ③ M-3 的 `CHAIN_MAX` 参数由 t4 定口径 | verifier + t4 |
| **P1** | V-08、V-06、V-14、V-07、M-2 | t8 顶层集成未开始（`video_content_mux.v` / `mode_ctrl.v` / 顶层 `dmz_eg4s20_hdmi_top.v` 均仍是 10-30~11-02 00:01 的旧版） | t8 落线后重跑 |
| **P1** | V-13 | `osd_strings.v` 已是 t3 新版（**455 行 / 13:19:29 / 29,303 B**），但**三条状态行文案仍无**（13:35 复核：grep `SD NEEDED`/`KEPU LOAD`/`NEEDED` = 0 命中）；且 line 8..15 已被「六段中文校园介绍 + 两行应急疏散」占用（`:18-20` + `:23`「三组行不能互换」），**与原 V-13 的行号设计冲突**，须先定口径 | t3 + arch-lead 定行号分配 |
| **P2** | V-18 | 需改的是 **6 个** TB 不是 4 个（多 `tb_probe_order.v:115`、`tb_probe_pix.v:135`）；`tb_pix_reader.v`（13:11 版）已加 V-03 用例但跑不起来，`tb_image_player.v`（13:09 版）对新端口只填常量、**语义仍零覆盖** | 全部落盘 + A-9 解除后统一重编译 |
| **P2** | V-09、V-10 | 端到端集成 + **全 top 带 SDC** 的 TD 综合（`gate.qor` 的 `2147483647` 哨兵不可用） | t9 回归 |

---

## 11. 引用清单

| 文件 | 引用位置 |
|---|---|
| `rtl/video/pix_mosaic.v` | `:82-91` `:90` `:98` `:103-104` `:115` `:117` `:122` `:133-152` `:140-141` `:145-146` `:150` `:21-35` `:75-77` |
| `rtl/video/ratio_map.v` | `:68-74` `:86-131` `:89-94` `:96-101` `:103-108` `:110-115` `:117-122` `:124-129` `:49-63` |
| `rtl/video/emerg_page.v` | `:22-30` `:33-40` `:45-56` `:62-69` `:75-78` `:81-82` `:89-92` `:99-103` `:108-121` |
| `rtl/video/video_content_mux.v` | `:11` `:18` `:19`（全文 38 行） |
| `rtl/video/image_window_mask.v` | `:25-28` `:42` |
| `rtl/storage/pix_reader.v` | **新版 360 行**：`:16-32` `:36-46` `:47-68` `:61-65` `:163-204` `:173` `:175-182` `:186-204`（改造前旧版 282 行仅作 §2 V-03 的历史对照，**行号已作废**） |
| `rtl/storage/image_player.v` | **新版 599 行**：`:25-36` `:65-80` `:148` `:244-245` `:259-262` `:395` `:439-440` `:468` `:516-521` `:530` `:535-540` `:544` `:548-549` `:552-562` `:571` `:576-585` `:588`（改造前旧版 511 行行号 `:9-18` `:60` `:191` `:492-498` `:500` **已全部作废**，勿再引用） |
| `rtl/storage/framebuf_arbiter.v` | `:13` `:19` `:21` `:28` `:30` `:41` `:43` `:58` `:63` `:95` `:101-106` `:112` `:119-122` `:123-124` `:178` `:190-204`（`:124` 的 `4'hF` 是全仓 dm 语义的锚点） |
| `rtl/storage/rle_decoder.v` | **635 行 / 13:22:49 快照（仍在滚动修订，行号随后续提交漂移，引用须带快照时间）**：`:31-37` `:43` `:55-58` `:113-117` `:120-128` `:126` `:134` `:136-138` `:157`（`[8:0] run_left`）`:178` `:216` `:255` `:268` `:283-287` `:293` `:317` `:320` `:329-333` `:336` `:341-353` `:361-368` `:385` `:418-419` `:424-435` `:457-464` `:467` `:479-483` `:487-499` `:504-511` `:521-528` `:531` `:548-561` `:564-573` `:575-579`。**`:255 assign ext_wr_dm = 4'hF` 是 A-8 阻塞级缺陷** |
| `rtl/storage/sdram_ctrl_wrap.v` | `:51`（`app_wr_dm` 语义原文）`:127`（`SDRAM_SIM_MODEL` 分支）`:132-148` `:289` `:303` `:379-387`（dm 掩码行为模型）`:240-268`（加密核例化，A-9 阻断点） |
| `rtl/storage/img_loader.v` | `:106`（`fifo_wr_dm // 全写时为 4'h0`）`:514` `:520` `:531` `:539`（`:539 dm=4'hC → 只写 [15:0]`，BMP 通路的 dm 极性参照） |
| `rtl/storage/fade_mixer.v` | `:14` `:21` `:22-24` `:26-28` `:29`（`level=255 → gain=256` 逐位还原的编码基准） |
| `rtl/storage/fat32_reader.v` | `:105` `:117` `:211` `:273` `:533-547` `:639-671`（673 行） |
| `rtl/audio/wav_stream_player.v` | `:73` `:89` `:95` `:332` `:340` `:421` |
| `rtl/control/mode_ctrl.v` | `:45` `:73-93` |
| `rtl/control/key_router.v` | `:15` `:90` `:91` `:157` `:237-238` |
| `rtl/osd/osd_caption.v` | **新版 393 行 / 20,868 B / 13:18:08**：`:108` `:128-129` `:134` `:189` `:241` `:256`（旧版 291 行的 `:86` `:106-107` 等行号已作废） |
| `rtl/osd/osd_strings.v` | **新版 455 行**：`:6` `:18-21` `:47-57` `:60-64` `:67-70` `:73-77` `:80-83` `:86-92` `:95-103` `:106-109` `:112`（旧版 156 行的 `:22-31` `:30` `:94-108` **已作废**） |
| `scripts/gen_osd_strings.py` | 全文（18,898 B / 13:00:05）——`osd_strings.v` 的唯一合法修改入口 |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | `:121` `:133` `:135` `:273-283` `:280` |
| `sim/testbench/tb_pix_mosaic.v` | `:76-79` `:98-107` `:109-115` `:138-144` `:298-304` `:337` `:361-366` `:490` |
| `sim/testbench/tb_emerg_page.v` | `:202-208` `:219-233`（262 行） |
| `sim/testbench/tb_fat32_reader.v` | `:41` `:66` `:524-539` `:806-814` `:816-821` `:823-828` |
| `sim/testbench/`（V-18 六个 TB） | `tb_image_player.v:72` `tb_display_content.v:47` `tb_startup_ownership.v:50` `tb_pix_reader.v:103` `tb_probe_order.v:115` `tb_probe_pix.v:135` |
| `docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md` | `:342` `:352-353` `:357` `:363` `:378-380` `:443-457` `:454` `:461-471` `:467` `:469` `:477-478` `:488` `:497-498` `:505` `:508-514` `:518-523` `:531-537` `:550-583` `:591-603` `:607` `:647-661` `:655-657` `:660-661` `:873-879` |
| `docs/plan_v2/ARCH.md` | `:342` `:515-567` `:518-556` `:553` `:562-567` `:563-564` `:636` |
| `reports/plan_v2/T7_MUST_TEST.md` | `:15` `:25-52` `:46-52` `:49` `:70-76` `:82-83` `:89-101` |
| `reports/plan_v2/EMERG_SCREEN_RULING.md` | `:99` `:208` `:234` `:241-242` |
| `reports/diag_key1_fifo_backpressure_20261101/area.txt` | `:5` `:11` `:13` `:17` `:21` `:156` `:162` `:188` `:205` `:216` |
| `scripts/sync_src.ps1` | `$map` 51 条（148 行） |
| `docs/plan_v2/RESOURCE_BUDGET.md` | `:444` `:502` |
| `reports/watchdog_20261030/area.txt` | `science_page` 1052 le / 672 lut（另一快照口径，见 §8.1.A 注） |
| **`SmartCampusMedia/project/t1_geom_area/reports/area_ratio.txt`** | 全文（`ratio_map` **实测 14 lut / 14 le / 0 bram / 0 dsp**） |
| **`SmartCampusMedia/project/t1_geom_area/reports/area_mosaic.txt`** | 全文（`pix_mosaic` **实测 50~64 lut / 0 bram / 0 dsp**） |
| **`SmartCampusMedia/project/t1_geom_area/reports/area_top.txt`** | 层级表 `t1_geom_area_top` / `u_pix_mosaic` / `u_ratio_map` 三行 |
| **`SmartCampusMedia/project/t1_geom_area/gate.qor`** | `Setup WNS` / `Hold WNS`（**`2147483647` = 无约束哨兵，不可当余量**） |
| **`SmartCampusMedia/project/t2_emerg_area/reports/area.txt`** | 全文（`emerg_page` **实测 339 lut / 339 le / 0 bram / 0 dsp**、`#reg only 0`） |
| **`SmartCampusMedia/project/t2_emerg_area/reports/area_plain.txt`** | 同上（纯文本版，交叉核对用） |
| `reports/plan_v2/REQUIREMENT_CHANGELOG_V2.md` | 同级文档（t6 第一件事产物，AHT20 单传感器裁决落档） |
