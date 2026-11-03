# t10 验收报告：七套回归 + TD 综合布线出位流（v2 本轮修复批次）

> **⚠️ 本文档经历两轮。第 1 轮（attempt 1）TD 两次全流程均 FAIL-route、未产出位流；
> 第 2 轮（attempt 2）改用高扇出网优化参数后**已产出新位流并通过三条红线**。
> 阅读顺序建议：先读下面的「第二轮结论摘要」，再按需回看 §1–§9 的第一轮记录（其失败机理仍有价值），
> 最后读 §10 第二轮的完整数据与最终裁决。**

- 任务：t10「七套回归 + TD 综合布线出位流」
- 执行者：verify-build（团队 smartcampus-v2-fix）
- 执行时间：第 1 轮 2026-11-03 22:08 – 22:50；**第 2 轮 2026-11-03 23:08 – 23:40**（Asia/Shanghai）
- 代码基线：HEAD = `1ecae32`（docs: 补入 OSD 黑条诊断报告），工作树含本轮未提交改动
- 本轮改动范围：`rtl/` 11 个文件（+662 / −74 行）、`sim/testbench/` 9 个 TB、`project/hdmi` 12 个副本、6 篇文档
- **第 1 轮结论**：七套回归全绿（7/7，911,909 断言）；但 TD 两次全流程（seed7 与默认 seed）均在 route 阶段 FAIL，未产出位流。
- **第 2 轮最终结论（以本节为准）**：**七套回归全绿 + 两个孤儿 TB 已补进套件（storage 5/5、image 4/4）+ TD 从 gate.db 复跑全流程成功出位流。
  三条红线全部达标：Setup WNS +109 ps 为正、`#bram` 37、位流已更新（MD5 由 `59A6BACC…` 变为 `AA65465E…`）。**

## 第二轮结论摘要（最终裁决）

| 项目 | 结果 | 关键数据 |
|------|------|----------|
| 回归 | ✅ 全绿 | attempt 1 七套 7/7（911,909 断言）+ 第 2 轮补齐 2 个孤儿 TB（storage 5/5、image 4/4） |
| 回归可复用性 | ✅ 已证明 | 11 个 `.v` + 9 个 tb 的 MD5 与 attempt 1 **逐一比对 diff=0/20**，故回归证据复用、仅补跑新增覆盖 |
| TD 出位流 | ✅ **成功**（第 4 趟） | 路线 2 参数 `place hfn_opt_effort high place crit_path_opt on`，TD EXIT 0，耗时 239 s（复用了 gate.db，省约 125 s 综合） |
| 红线 ① Setup WNS | ✅ **+109 ps 为正** | 0 违例端点；Hold WNS **+19 ps**、0 违例端点（基线 +113 / +11） |
| 红线 ② `#bram` | ✅ **37/64** | 与基线一致，未退回 35；`#fifo9k`=0、`#bram32k`=0 |
| 红线 ③ 位流更新 | ✅ **已更新** | 648,264 B、2026-11-03 23:35:55、MD5 `AA65465E3F41E16C49E5EAE13D0EEC38`（基线 `59A6BACC…`） |
| 面积 | ⚠️ 高于预期但可接受 | `#lut` 16,868/19,600 = **86.06%**（基线 83.74%，+454）；`#reg` 8,709/19,600 = 44.43% |
| 位流归档 | ✅ | `reports/t10_r2_verify_build_20261103_PASS/hdmi_td_r2_hfn_AA65465E.bit` |

> **本报告的核心判断（第 2 轮更新）**：**已有可上板的新位流。**
> `project/hdmi_td_Runs/phy_1/hdmi_td.bit` 现在是 2026-11-03 23:35:55 用本轮工作树 RTL 综合布线出的位流，
> 含 t6/t7/t8/t9 全部修复，三条红线全过。上板验证可以开始。
> 仍需注意的边界见 §7「不能证明什么」——尤其：时序通过 ≠ 上板功能正确；回归通过 ≠ 真卡时序成立；
> I2C 在 SDC 里是 `set_false_path`，SWNS 对 I2C 物理可靠性**零证据**。

---

## 0. 执行边界声明

本任务**只做验收，不做修复**。全部操作可归为四类：

| 类别 | 具体动作 | 是否改动源码 |
|------|---------|-------------|
| 运行 | `sync_src.ps1`（2 次）、`lint_verilog.py`、`check_port_names.py`、`run_full_regression.ps1`、两个孤儿 TB 的 `vlib/vlog/vsim`、`td_commands_prompt.exe`（2 次全流程） | **否** |
| 复制 | 6 个 `rtl → project/hdmi` 副本（由 `sync_src.ps1` 执行，`rtl/` 侧只读）；TD 产物 → `reports/t10_verify_build_20261103_routefail/` | 副本，非源码 |
| 备份 | baseline qor/db、改动前的 `reports/t7b3_rl45_*.txt` → `D:\FPGA_Compelate\_t10_regression_20261103\` | 否 |
| 新建 | 本报告、归档目录、4 个辅助分析脚本（`dump_results.py` / `dump_tests.py` / `compare_baseline.py` / `diff_area_hier.py`，全在仓库外） | 新增，非修改 |

**没有做的事**（任务书边界）：

- ❌ 未修改任何 RTL / testbench 的语义（`git diff --stat -- rtl` 仍是队友的 `11 files changed, 662 insertions(+), 74 deletions(-)`，与本任务开始时一致）
- ❌ 未执行 `git commit` / `git add`
- ❌ 未上板
- ❌ 未自行调 TD 参数去「凑绿」（`route fix_hold on` / `post_route_opt high` 等合法开关**一个都没用**，只做了「与基线同参数（seed7）」和「默认 seed」两次客观测量）
- ❌ 未覆盖 `reports/t7b_bit_v3_seed7_PASS/`（该目录 9 个文件的时间戳全部保持 2026-11-03 00:xx，见 §6.4 与验证记录）

另需说明：`reports/s6_integration/**` 下的 6 个文件在 `git status` 里显示 `M`，
但它们的最后修改时间是 **2026-11-03 21:06–21:08**，早于本任务启动（22:08），
且本任务的 `-ReportRoot` 明确指向仓库外 ⇒ **不是本任务改的**，属队友此前跑 `run_frontend_regression` /
`run_image_regression` 时写回的现场日志。

---

## 1. 第 0 步：同步与静态检查（全部通过）

### 1.1 双工程副本同步 `scripts/sync_src.ps1`

```
=== 同步 主源 -> TD 工程副本 ===
...
同步完成: 6/71 个副本被更新          （exit 0）
```

被更新的 6 个副本（其余 65 个打印「[未变化]」）：

| # | 目标副本 | 对应源 |
|---|---------|--------|
| 1 | `project/hdmi/image_player.v` | `rtl/storage/image_player.v` |
| 2 | `project/hdmi/err_prompt.v` | `rtl/control/err_prompt.v` |
| 3 | `project/hdmi/audio_waveform.v` | `rtl/video/audio_waveform.v` |
| 4 | `project/hdmi/dmz_eg4s20_hdmi_top.v` | `rtl/top/dmz_eg4s20_hdmi_top.v` |
| 5 | `project/hdmi/audio_src_mux.v` | `rtl/audio/audio_src_mux.v` |
| 6 | `project/hdmi/wav_stream_player.v` | `rtl/audio/wav_stream_player.v` |

**幂等性复核**：TD 跑完之后再次执行，输出 `同步完成: 0/71 个副本被更新`（exit 0）
⇒ 整个 TD 过程没有反向污染 `rtl/`，后续所有结论建立在同一份源码上。

**MD5 逐文件核对**（`rtl/` vs `project/hdmi/`，10 个本轮相关文件全部 SAME）：

| 文件 | MD5（前 8 位） |
|------|---------------|
| `dmz_eg4s20_hdmi_top.v` | `F0AF1567` |
| `image_player.v` | `9E2F2227` |
| `rle_decoder.v` | `258AA29D` |
| `img_scaler.v` | `911F6540` |
| `image_window_mask.v` | `D515F7BC` |
| `video_overlay.v` | `BEEF8899` |
| `osd_panel.v` | `54C51DC5` |
| `audio_src_mux.v` | `6D85C0B8` |
| `wav_stream_player.v` | `62318E80` |
| `err_prompt.v` | `7E72B829` |

> 注：`audio_waveform.v` 的实际源路径是 `rtl/video/audio_waveform.v`（不是 `rtl/audio/`）。

### 1.2 Verilog lint

| 命令 | 文件数 | E0（损坏） | E1（混用赋值） | E2（多驱动） | 结论 |
|------|-------|-----------|---------------|-------------|------|
| `python scripts/lint_verilog.py rtl` | **67** | 0 | 0 | 0 | **通过** |
| `python scripts/lint_verilog.py rtl project/src project/hdmi` | **133** | 0 | 0 | 0 | **通过** |

**口径说明（重要）**：任务书写的是 `lint_verilog.py rtl project`。实际执行该形式会扫到 **445 个文件**并报
`E1=2 / E2=19`、`exit 1`。逐条核查后确认这是 `project/` 下的**历史探针遗留目录**，与回归无关：

- `project/t2_cjk16_missing/cjk16_probe_wrap.v`
- `project/t2_cjk16_probe/cjk16_probe_wrap.v`
- `project/t2_emerg_area/emerg_page_area_top.v`
- 以及 `project/backup_t2*` 等历史备份副本

`sync_src.ps1` 自身尾部（`:175-183`）用的也是 `rtl project/src project/hdmi` 三参数形式，并打印
「检查文件数: 133 / E0=0 E1=0 E2=0 / 通过」。**本报告以 133 文件口径为准**，并已在下文 §9 列为待清理项。

### 1.3 端口名检查 `scripts/check_port_names.py`

```
modules parsed        = 69
instantiations scanned = 40
NO_SUCH_PORT          = 0          ← 关键：无不存在端口
UNKNOWN_MODULE        = 2          （均预期）
UNCONNECTED           = 0
EMPTY_CONN            = 8 instances / 16 ports  （有意 8，意外 0）
RESULT: PASS
exit 0
```

两个 `UNKNOWN_MODULE` 均为黑盒 IP，符合预期：
`EG_PHY_SDRAM_2M_32 u_sdram_sip`、`hdmi_1_4b_transmitter_core_wrapper u_hdmi_core`。

8 个有意空连接（全部在白名单内）：
`u_key{key_state}`、`u_keyrouter{audio_en, osd_pop_req, osd_ticker_en, ...}`、`u_ctrl{mode, status_led}`、
`u_vtg{frame_start, hs}`、`u_thermal{oth_enter, oth_exit, temp_alive}`、
`u_player{ext_frame_sel, ext_loader_want_blk}`、`u_audio_src{eff_audio_en}`、`u_bright{de_out}`。

> **回归意义**：t7 把 `image_player` 的 `out_*` 四根从空连接接回 `img_win_*` 后，`EMPTY_CONN` 中的意外数为 0，
> 说明 t7 的接线修复**没有引入新的悬空端口**，也没有破坏原有白名单。

**第 0 步结论：三条静态检查全部通过，可以进入回归。**

---

## 2. 第 1 步：七套回归（7/7 全绿）

### 2.1 执行命令

```powershell
& .\sim\scripts\run_full_regression.ps1 `
    -ModelSimPath 'D:\Quartus_APP\modelsim_ase\win32aloem' `
    -PrimLibPath  'D:\TD_6_24_APP\sim_release\eg4' `
    -ReportRoot   'D:\FPGA_Compelate\_t10_regression_20261103'
```

- ReportRoot 建在**仓库外** `D:\FPGA_Compelate\_t10_regression_20261103`（脚本 `:23-25` 明确要求，仓库内不能建子目录）。
- 未使用 `-Suite` 子集参数，七套全跑。
- 启动 2026-11-03 22:10:16，结束 22:22:47，**driver 退出码 0**。

### 2.2 逐套结果（与基线逐项对照）

| 套件 | ran | passed | expected | 断言数（本次） | 耗时 | 基线 ran/passed | 基线断言 | 断言差 |
|------|-----|--------|----------|--------------|------|----------------|---------|-------|
| unit | **29** | **29** | 29 | **1,240** | 337 s | 16 / 16 | 752 | **+488** |
| frontend | **21** | **21** | 21 | **56,457** | 106 s | 20 / 20 | 829 | **+55,628** |
| storage | **4** | **4** | 4 | **226,360** | 6 s | 4 / 4 | 220,642 | +5,718 |
| audio | **2** | **2** | 2 | **24** | 158 s | 2 / 2 | 24 | 0 |
| startup | —（无 result.json） | **19 PASS 行** | — | **19** | 2 s | — | 12 | +7 |
| display | **1** | **1** | 1 | **614,406** | 85 s | 1 / 1 | 614,405 | **+1** |
| image | **3** | **3** | 3 | **13,403** | 57 s | 3 / 3 | 11,298 | **+2,105** |
| **合计** | — | **7 / 7 套** | **7** | **911,909** | **752 s** | 7 / 7 套 | 847,962 | **+63,947** |

```
================ FULL REGRESSION SUMMARY ================
unit       PASSED   exit=0  337s  asserts=1240     29 module unit testbenches
frontend   PASSED   exit=0  106s  asserts=56457    SD/FAT32/BMP/player/OSD
storage    PASSED   exit=0    6s  asserts=226360   SDRAM / framebuf / retention
audio      PASSED   exit=0  158s  asserts=24       audio tone / PWM / waveform path
startup    PASSED   exit=0    2s  asserts=19       startup ownership handoff
display    PASSED   exit=0   85s  asserts=614406   display content verification
image      PASSED   exit=0   57s  asserts=13403    image path regression
--------------------------------------------------------
suites: passed=7 failed=0 total=7  asserts=911909  elapsed=752s
A4-GATE: ran=7 passed=7 expected=7
FULL REGRESSION PASSED
```

**没有任何一套的 ran/passed 相对基线下降。** 三处上升均能归因到本轮/t16 的改动（见 §2.4）。

### 2.3 与任务书基线的三处口径差异（必须说明）

| # | 任务书写法 | 实测 | 差异原因 |
|---|-----------|------|---------|
| 1 | 「历史全量基线 **848,063 断言 / 约 1505 秒**」 | 本地唯一可查的旧 `summary.json` 是 **847,962 断言 / 857 秒**（`C:\Users\Koobee\AppData\Local\Temp\scm_full_regression\summary.json`，2026-10-31 10:37:38） | 在 `reports/*.md`、`docs/*.md` 内 grep `848,?063\|1505` **0 命中**，仓库里找不到这个数字的出处。二者相差 101 条断言、648 秒，说明任务书那个数字来自另一次更早/更全的全量跑。**本报告一律以 847,962 / 857 s 为「可核查的上一版基线」，以 911,909 / 752 s 为本次实测。** |
| 2 | 「fifo: passed（tb_async_fifo）」列为独立套件 | `run_full_regression.ps1` 里**没有 fifo 套件**；`tb_async_fifo` 落在 **storage** 套件内（`checks=24 cases=8`） | 套件划分与任务书假设不同，非缺失。`tb_async_fifo` 实际已跑且通过。 |
| 3 | 「storage: tb_async_fifo / tb_framebuf_arbiter / tb_sdram_ctrl_wrap / tb_pix_reader / **tb_pix_reader_vga**」共 5 个 | 实测只有 **4** 个 case | 脚本 `:59` 写明 `$ExpCaseCount = ($Suite -eq 'All' ? 4 : 1) + ($FullVga ? 1 : 0)`；`tb_pix_reader_vga` 需 `-FullVga` 开关。本次全量入口未传该开关（`result.json` 记 `fullVgaRequested=False`），属设计行为。**`tb_pix_reader` 主用例已跑（checks=542 cases=39）。** |

### 2.4 关键用例逐个核对（本轮改动落地的直接证据）

#### unit（29 个，断言 1,240）

`lane_lvds_10_1` 22 / `hdmi_phy` 66 / `video_rgb_to_axis` 54 / `audio_arc` 41 / `video_timing_gen` 18 /
`test_pattern_gen` 142 / **`audio_waveform` 80** / `audio_tone_gen` 46 / `pcm_to_pwm` 39 / `key_matrix_4x4` 50 /
`ax_debounce` 31 / `seg_decoder` 51 / `image_path_probe` 54 / `hdmi_pll` 13 / `sdram_pll` 13 /
`dmz_eg4s20_min_top` 51 / `science_font16` 49 / `sdram_frame_diag_top` 37 / `brightness_apply` 27 /
`mode_ctrl` 48 / `key_router` 30 / `i2c_master` 23 / `aht20_ctrl` 32 / `thermal_guard` 23 /
`fat32_reader` 64 / `gain_direction` 13 / `vol_apply` 41 / **`audio_src_mux` 36** / `wav_stream_player` 46

**t6 音频断言实测落地（任务书预期核对）**

`tb_audio_waveform`（checks 76→80，+4）：

```
# [magnitude] full-scale 24bit swing: y from 376 to 439 (span=64 rows)
# PASS: [magnitude] full-scale 24bit reaches >= +30 rows
# PASS: [magnitude] full-scale 24bit reaches <= -30 rows
# [magnitude] NARR peak after F3 left-align: sample=7465472 y_off=28
# PASS: [magnitude] NARR peak after left-align reaches >= 25 rows
# [magnitude] NARR peak WITHOUT left-align (regression guard): y_off=0
# PASS: [magnitude] un-aligned 16bit signal collapses to <= 1 row (guards F3)
# SUMMARY: checks=80 errors=0
# ALL CHECKS PASSED: audio_waveform
```

- 任务书预期「满幅 24bit ±8388607 → 高度 ≥±60 行」：实测 **span=64 行**（±32），断言阈值写的是 `>= 30`，**通过**。
- 任务书预期「16bit WAV 经 F3 左对齐 → ≥±30 行」：实测 NARR `y_off=28`（28 行），断言阈值写的是 `>= 25`，**通过**。
- ★ **口径差 1 条**：t6 报告记「新增 3 条」，实测总条数从 76 → **80（+4）**。多出的是 `[magnitude] NARR peak WITHOUT left-align (regression guard)` 这类**反向守卫断言**（证明「不做 F3 左对齐就塌成 1 行」），属 t6 报告未单列的守卫项。**不是加错了，是报告口径没算全。**

`tb_audio_src_mux`（checks 36，含 S13 段 12 条）：

```
# PASS: S04a daily   -> src_name == "BGM     WAV"
# PASS: S04b science -> src_name == "NARR    WAV"
# PASS: S04c emergency -> src_name == "ALARM   WAV"
# ---- S13: default parameter byte order (no override) ----
# PASS: S13a default BGM byte0 == 'B' (0x42), not 'V' (0x56)
# PASS: S13b default BGM byte1 == 'G'
# PASS: S13c default BGM byte2 == 'M'
# PASS: S13d default BGM byte3 == space
# PASS: S13e default BGM byte8 == 'W'
# PASS: S13f default BGM byte9 == 'A'
# PASS: S13g default BGM byte10 == 'V'
# PASS: S13h default BGM == 'BGM     WAV' on disk (all 11 bytes)
# PASS: S13i default NARR == 'NARR    WAV' on disk (all 11 bytes)
# PASS: S13j default NARR byte0 == 'N'
# PASS: S13k default ALARM == 'ALARM   WAV' on disk (all 11 bytes)
# PASS: S13l default ALARM byte0 == 'A'
```

任务书预期「不 override 例化时 `src_name[7:0] == 8'h42('B')`」：**S13a 精确命中**。

#### frontend（21 个，断言 56,457）

`sd_protocol_default` 62 / `sd_protocol_fast` 64 / `sd_spi_ctrl` 23 / `sd_probe` 14 / `fat32_reader` 64 /
`gallery_probe` 63 / `bmp_parser` 37 / `img_loader` 53 / `player_ctrl` 94 / **`err_prompt` 72** /
`buzzer_tone` 23 / `key_action` 42 / **`video_overlay` 107** / `video_content_mux` 18 / `osd_caption` 46 /
`osd_param_text` 78 / `osd_panel` 63 / `osd_autopop` 38 / `osd_caption_cjk` 54,587 / `narr_subline` 895 /
`fade_mixer` 14

**任务书预期核对**：`tb_video_overlay` **107 checks** ✅（t8 后，基线 106→107）。

三处变化归因：

| 用例 | 基线 | 本次 | 归因 |
|------|------|------|------|
| `video_overlay` | 106 | **107** | t8 把底条收窄为 `x∈[8,103], y∈[468,475]`，新增 1 条边界断言 |
| `osd_caption` | 56 | **46（−10）** | **不是回归退化**。`tb_osd_caption.v` 的 56 条来自 2026-10-31 10:27 那次跑（旧报告 `...\scm_full_regression\frontend\osd_caption.txt` 记 `checks: 56, all passed`），当时该文件尚未入库；它首次入库是 commit `451dd29`（10-31 15:58），随后在 commit `946f74f`（11-03 19:50，t16 的「补齐 v2 新增模块 testbench」）被改写 **+89 / −79 行**，checks 从 56 降为 46。本次 46 checks **全部通过**（`point-by-point comparisons: 2504` / `ALL CHECKS PASSED`），且 `rtl/osd/osd_caption.v` 本轮**未被修改**（`git status` 对它是干净的）⇒ 下降发生在 t16 的 TB 重写，与本轮 4 个修复无关。 |
| `osd_caption_cjk` 54,587 + `narr_subline` 895 | — | 新增 | t16 之后新增的两个大 TB；基线里没有 |

另：基线有 `science_page`（11 条），本次没有。`run_frontend_regression.ps1:41-43` 注释写明：
「science_page.v / science_font16.v 已从本套件摘除（2026-11-02，t16 裁定）。顶层 u_science_page 已删除，
这两个 .v 与 tb_science_page.v 都成了孤儿」⇒ 预期内的减法。

#### storage（4 个，断言 226,360）

`tb_async_fifo` checks=24 cases=8 / `tb_framebuf_arbiter` checks=71,023 cases=15 /
`tb_sdram_ctrl_wrap` checks=154,771 cases=12 / **`tb_pix_reader` checks=542 cases=39**

`tb_pix_reader` 从基线的 108 条涨到 542 条（+434）。这是历史遗留：commit `946f74f` 提交新 TB 时没有同步
`scripts/run_tb_baseline.ps1` 的 `-ExpectLine`，t7 任务已把该期望值更新为 542，本次实测**恰好 542，与脚本一致**。

#### audio（2 个，断言 24）

`hdmi_audio_path` passLines=19 / `pwm_audio_out_legacy` passLines=5。**与基线 24 条完全一致**。

> 说明：t6 新增的音频断言全部落在 `unit` 套件的 `tb_audio_waveform` 与 `tb_audio_src_mux` 里，
> `audio` 套件本身没有新增（它的 2 个 TB 未被本轮修改）。任务书预期「audio 套件会加 2 条」应理解为
> 「t6 会加 2 条音频相关断言」，实际落在 unit 套件，**总数上已包含**。

#### display（1 个，断言 614,406）

```json
status = passed
checks = 614406, errors = 0, missing = 0, mismatched = 0
pinModelErrors = 0
frameIdentical = True
elapsedSeconds = 84.5
bmp  = assets/sd_verify/good/IMG001.BMP  sha256 F7486BD0...
bmp2 = assets/sd_verify/good/IMG002.BMP  sha256 B1C95C85...
fixture = BMP1 bytes=921654 clusters=226 BMP2 bytes=921654 clusters2=226 width=640 height=480
byteGap = 1, reloadCount = 0, arbiterTurnGap = 3
pixelMHz = 25, sdramMHz = 40
seam = "real image_player RTL; modeled external sector service and behavioral SDRAM"
harnessSha256 = 273182AF...
```

**任务书预期核对**：`614,406 checks + frameIdentical=True` ✅（基线 614,405 → +1）。

★ **重要限制（必须与 §7 一起读）**：`seam` 字段自报
「real image_player RTL; **modeled external sector service and behavioral SDRAM**」
⇒ 这个套件的 SDRAM 与 SD 扇区服务是**行为模型**，不是真实 IP。它证明的是 image_player 的像素搬运逻辑正确，
**不能证明真实 SD 卡时序或真实 SDRAM 控制器时序成立**。

#### image（3 个，断言 13,403）

`img_scaler` checks=**187** / `image_player` checks=**11,405** / `image_player_scaled`（`-gSCALE=1`）checks=**1,811**

**任务书预期核对**：`tb_image_player 187 checks` —— 任务书写的是「tb_image_player 187」，
但**实测 187 是 `tb_image_player` 的名字对应到 `img_scaler` 的 checks 数**：

- `img_scaler` = 187
- `image_player` = 11,405
- `image_player_scaled` = 1,811

t7 报告里提到的「tb_image_player checks 从 59→91」，是**另一套计数口径**（t7 用 `chk` 计数 11405 里的一部分）。
**三者全部通过，无错误**，但任务书把 187 归到 `tb_image_player` 是口径笔误，实际 187 属 `img_scaler`。
`image_player` 从基线 9,300 → 11,405（+2,105），正是 t7 新增 `display_*` / `ext_wr_mode` 相关断言的结果。

### 2.5 ★ 两个「孤儿 TB」：不在任何套件里，已手工跑通

扫 `sim/scripts/*.ps1` 全部脚本，逐个核对 `sim/testbench/` 下的 **78 个** `tb_*.v`：
**68 个**能被至少一个脚本引用，**10 个完全没有**。未覆盖的 10 个是：
`tb_dbg_scaler`、`tb_dmz_eg4s20_bringup`、`tb_fifo_fwft`、`tb_framebuf_realcore_concurrent`、
**`tb_image_window_mask`**、`tb_probe_burst`、`tb_probe_order`、`tb_probe_pix`、**`tb_rle_decoder`**、`tb_seg_scan4`。

其中 **`tb_rle_decoder.v`（t9 新增）** 与 **`tb_image_window_mask.v`（t7 新增/扩充）** 是**本轮修复的直接验证者**，
却没被任何回归套件收录。为不让这两处成为盲区，**手工单独跑了一遍**（未修改任何 TB/RTL）：

| TB | 编译 | 仿真 | 结果 | 任务书预期 |
|----|------|------|------|-----------|
| `tb_image_window_mask` | exit 0 | exit 0 | `# SUMMARY: checks=52 errors=0` / `ALL CHECKS PASSED: image_window_mask` | （任务书未给；t7 报告记「断言 20→52」，**吻合**） |
| `tb_rle_decoder` | exit 0 | exit 0 | `# TB_RLE_DECODER SUMMARY: checks=72 errors=0`，8 个 CASE 全过 | **72 checks** ✅ |

`tb_rle_decoder` 的 8 个 CASE：frame pacing 500 / 真实 SCI.RLE 帧 0 / 帧 1 / 中止帧 / 坏 magic /
拒授权停驻 / **外来 blk_done 不推进**（t9 的 P0-A2 修复）/ 自己的 blk_done 完成块（t9 修复后正常路径）。

> **结论**：套件 7/7 绿 ≠ 本轮全部新 TB 都跑了。这两个是手工补跑的，**必须在 §9 列为待办补进
> `run_storage_regression.ps1` / `run_image_regression.ps1`**，否则下一轮回归会漏掉 t7/t9 的核心验证。

---

## 3. 第 2 步：TD 综合布线出位流（**FAIL，两次全流程均失败**）

### 3.1 为什么跑两次

任务书只要求一次。跑到 route 失败后补跑第二次，**目的不是凑绿，而是补齐报告 §4 必需的数据点**：

- 跑 #1 用 `place seed 7`（与基线同参数，基线 113 ps 就是 seed7 的成绩）；
- 跑 #2 用默认 seed（看本轮 RTL 在当前面积下能否布通）。

两次都是 **从 elaborate 重跑全流程**，**均未使用** `t7b_seed_full.tcl` 的旧 gate.db 捷径
（旧 gate.db 时间 2026-11-03 00:13:54，早于本轮全部 RTL 改动，用它出的位流不含任何本轮修复）。

### 3.2 执行命令

```powershell
# 跑 #1（22:23:16 启动）
$env:T7B3_EXTRA = 'place seed 7'
& 'D:\TD_6_24_APP\bin\td_commands_prompt.exe' `
  'D:/FPGA_Compelate/SmartCampusMedia/project/t7b_bit3.tcl'

# 跑 #2（22:33:39 启动）
Remove-Item Env:T7B3_EXTRA
& 'D:\TD_6_24_APP\bin\td_commands_prompt.exe' `
  'D:/FPGA_Compelate/SmartCampusMedia/project/t7b_bit3.tcl'
```

- 正本脚本 `project/t7b_bit3.tcl`（344 行，六条判据）。
- 路径用正斜杠（反斜杠会被当转义，`\f` 变换页符）；未用 `[file join]`（会报 `PRJ-8601`）。
- TD 版本 `V6.2.168116`，`td_commands_prompt.exe`。

### 3.3 跑 #1：elaborate 全流程 + place seed 7 → **FAIL-route，exit 9，耗时约 499 s**

阶段序列（**PASS 到 place，route 失败**）：

```
INFO-T7B3-TAG=rl45_place_seed_7
INFO-T7B3-RL=45
INFO-T7B3-EXTRA=place seed 7
PASS-import_device
PASS-open_project                    (PRJ-1401 : Successfully analyzed 64 source files.)
PASS-set_param rtl min_ripple_len 45
PASS-commit_param rtl
PASS-set_param place seed 7
PASS-commit_param place
PASS-elaborate                       (HDL-1200 : Current top model is dmz_eg4s20_hdmi_top
                                      HDL-1100 : Inferred 7 RAMs.)
PASS-read_adc
PASS-read_sdc
PASS-optimize_rtl                    (43.65 s wall)
PASS-optimize_gate                   (62.74 s wall)
PASS-report_area_gate
PASS-export_gate_db                  (t7b3_rl45_place_seed_7_gate.db  6,044,562 B)
PASS-place                           (74.26 s wall)
PASS-export_place_db                 (t7b3_rl45_place_seed_7_place.db 8,544,948 B)
FAIL-route                           ← exit 9
```

**route 失败详情（原样）**：

```
PHY-1001 : Routing violations:
PHY-8023 ERROR: Location: (x20y5_local1), nets: u_vtg/active_x_b[3] rst_n_dup_34
PHY-8023 ERROR: Location: (x21y4_local6), nets: u_axis/rgb[13]_syn_dup_8109 rst_n_dup_34
PHY-1001 : End of Routing Violations.
RUN-1003 : finish command "route -eco" in 84.198253s
RUN-8102 ERROR: Incremental route failed. Please check if the resources used in your design
            exceed the device resource limitations. ...
PHY-8023 ERROR: Location: (x20y5_local1), nets: u_vtg/active_x_b[3] rst_n_dup_34
PHY-8023 ERROR: Location: (x21y4_local6), nets: u_axis/rgb[13]_syn_dup_8109 rst_n_dup_34
RUN-1003 : finish command "route" in 313.790825s
FAIL-route
```

- 两次尝试（`route -eco` 84 s、全量 `route` 313 s）**都卡在同两处**，且都在同一根高扇出复位复制网
  `rst_n_dup_34` 上。
- route 规模：`8959 instances / 21,846 nets`（place 后）→ `8988 instances / 21,672 nets`，
  `TotalRouteNets 20477`，`final wirelength = 1.77757e+06`。
- route 内部 setup 轨迹：`−2.475 → −2.696 → −1.428`，**卡在 −1.428 ns 未收敛**（TNS −7.391，FEP 12）。

### 3.4 跑 #2：elaborate 全流程 + 默认 seed → **也是 FAIL-route，exit 9，耗时约 433 s**

阶段序列（前 18 条与跑 #1 相同，只是没有 `set_param place seed 7`）：

```
INFO-T7B3-TAG=rl45
INFO-T7B3-RL=45
INFO-T7B3-EXTRA=
...
PASS-set_param rtl min_ripple_len 45
PASS-commit_param rtl
INFO-extra_skipped: T7B3_EXTRA 为空，只做 min_ripple_len 基线
PASS-elaborate                       (HDL-1200 ... / HDL-1100 : Inferred 7 RAMs.)
PASS-read_adc
PASS-read_sdc
PASS-optimize_rtl                    (54.98 s)
PASS-optimize_gate                   (70.20 s)
PASS-report_area_gate
PASS-export_gate_db                  (t7b3_rl45_gate.db  6,044,558 B)
PASS-place                           (75.86 s)
PASS-export_place_db                 (t7b3_rl45_place.db 8,531,578 B)
FAIL-route                           ← exit 9  (227.58 s)
```

**route 失败详情（原样，与跑 #1 是**不同的两根网**）**：

```
PHY-8023 ERROR: Location: (x27y35_e2beg3), nets: u_rle/ramread0_syn_103 rst_n_dup_53
PHY-8023 ERROR: Location: (x29y35_local0), nets: u_rle/ramread0_syn_119 rst_n_dup_53_holdbuf0
RUN-8102 ERROR: Incremental route failed. ...
FAIL-route
```

### 3.5 ★ 关键发现：setup 其实已经收敛了，是 hold fix 打死了 route

跑 #2 的 route 内部时序轨迹（`PHY-1001 : Setup/Hold` 行）：

| 阶段 | Setup WNS | Setup TNS | Setup FEP | Hold WNS | Hold FEP |
|------|-----------|-----------|-----------|----------|----------|
| Routing Initialization | −2.133 | −21.193 | 27 | −0.012 | 5 |
| Phase 1 后 | −2.020 | −20.682 | 27 | −0.012 | 7 |
| Phase 2 后 | −0.379 | −0.762 | 3 | −0.012 | 7 |
| Rip-up/ReRoute 中段 | −0.277 | −0.567 | 3 | −0.012 | 7 |
| **route 优化结束** | **+0.124** | **0.000** | **0** | −0.012 | 7 |

**route 把 setup 从 −2.133 ns 一路优化到 +0.124 ns（TNS 归零、违例端点为 0）。**
此时只剩 hold −0.012 ns / 7 个违例端点，TD 自动进入 hold 修复，插了 **8 个 buffer**：

```
RUN-1001 : fix hold violation on net rst_n_dup_53 endpin rle_lba_q_reg[13]_syn_4.sr slack -6ps
RUN-1001 : fix hold violation on net .../u_logic_ramfifo_syn_26 endpin ...addrb[6] slack -4ps
RUN-1001 : fix hold violation on net .../u_w96_d1024_fifo/... slack -4ps
RUN-1001 : fix hold violation on net .../u_w24_d1024_fifo/... addra[11] slack -12ps
RUN-1001 : fix hold violation on net .../u_w24_d1024_fifo/... addra[4]  slack -11ps
RUN-1001 : fix hold violation on net .../u_w24_d1024_fifo/... addrb[10] slack -4ps
RUN-1001 : fix hold violation on net u_gallery/u_fat/data_byte[5]_dup_117 endpin u_rle/ramread0_syn_1562.b[1] slack -2ps
RUN-1001 : fix hold violation on net rst_n_dup_53 endpin u_rle/rd_ptr_reg[0]_syn_16.sr slack -6ps
RUN-1001 : fix hold violation on net u_wav/s_lo[7] endpin u_wav/ramread0_syn_6.dia[7] slack -11ps
```

其中 `rst_n_dup_53` 被插了 buffer（生成 `rst_n_dup_53_holdbuf0`）——
**而 `rst_n_dup_53` 与 `rst_n_dup_53_holdbuf0` 恰恰就是两条 PHY-8023 违例网**。
⇒ **hold 修复插 buffer 反而制造了不可布的物理违例，把已经收敛的 setup 结果一并废掉。**

跑 #1 也符合这个模式（`rst_n_dup_34` 打 `u_vtg/active_x_b[3]` 与 `u_axis/rgb[13]_syn_dup_8109`），
只是跑 #1 的 setup 在 route 内部就没收敛（−1.428），失败得更早。

> 这与 `reports/plan_v2/ONBOARD_RISK_MAP.md` 记录的「`fix_hold` 插 buffer 只恶化 setup」相呼应，
> 但本轮暴露出更严重的一面：**它还会直接制造 PHY-8023 布通性违例**。

### 3.6 拥塞：跑 #2 开局就 >100%

| 阶段 | top1 | top10 | top15 |
|------|------|-------|-------|
| 跑 #2 起点（place 后首帧） | **107.25%**（S 189.57 / N 173.79 / E 149.18 / W 110.09） | — | — |
| 跑 #2 第二帧 | 83.38% | — | — |
| 跑 #2 收敛后 | 59.12 – 65.60% | — | — |
| 跑 #1 起点 | 98.57%（S 160.55 / N 176.47 / E 136.79 / W 106.36） | 57.94 | 51.12 |
| 跑 #1 收敛后 | 59.25 – 63.15% | ~51.6 | ~49.9 |

**全设计 slices 占用逼近 90%，开局拥塞 >100%**，这是 route 失败的根本物理原因。
高扇出复位网（`rst_n_dup_*`）在这种密度下找不到可用的复制通道。

### 3.7 位流：**没有更新**

```
project/hdmi_td_Runs/phy_1/hdmi_td.bit
  648,264 B   2026-11-03 00:31:47   MD5 59A6BACC75613F5E953B7ED5A33E05E8
reports/t7b_bit_v3_seed7_PASS/hdmi_td_v3_seed7.bit
  648,264 B   2026-11-03 00:31:47   MD5 59A6BACC75613F5E953B7ED5A33E05E8   ← 完全相同
```

两次 TD 都在 route 阶段 exit 9，脚本在 `report_timing_summary` / `report_area` / `check_timing` / `bitgen`
**之前**就退出了。因此：

- 没有新的 `t7b3_*_{timing,area,coverage}.txt`
- `project/route.qor` 仍是 2026-11-03 00:31:24 的基线文件（route 失败不写）
- **位流是基线件，不能用于验证本轮任何修复**

---

## 4. 第 3 步：与基线逐项对比

### 4.1 gate 阶段（综合后，可完整对比）

**面积**（`reports/t7b3_rl45_gate_area.txt` vs `t7b3_rl45_place_seed_7_gate_area.txt`，
两份都是 17,035 B；两次跑的 gate 面积文件 **MD5 完全相同** `770ADC8D...`，证明 gate 阶段不受 place seed 影响）：

| 项 | 基线 | 本轮 | 差值 | 判定 |
|----|------|------|------|------|
| `#IO` | 43 / 188（22.87%） | 43 / 188（22.87%） | 0 | ✅ |
| **`#lut`** | **15,244 / 19,600（77.78%）** | **15,670 / 19,600（79.95%）** | **+426 / +2.17 pp** | ⚠️ 见 §4.5 |
| **`#reg`** | **8,298 / 19,600（42.34%）** | **8,517 / 19,600（43.45%）** | **+219 / +1.11 pp** | ⚠️ 见 §4.5 |
| **`#bram`** | **37 / 64（57.81%）** | **37 / 64（57.81%）** | **0** | ✅ **红线通过** |
| `#dsp` | 24 / 29（82.76%） | 24 / 29（82.76%） | 0 | ✅ |
| `#pad` | 47 / 188（25.00%） | 47 / 188（25.00%） | 0 | ✅ |
| `#pll` | 2 / 4（50.00%） | 2 / 4（50.00%） | 0 | ✅ |
| `#gclk` | 4 / 16（25.00%） | 4 / 16（25.00%） | 0 | ✅ |
| `#bram9k` | 37 | 37 | 0 | ✅ |
| `#fifo9k` | 0 | 0 | 0 | ✅ |
| `#bram32k` | 0 / 16（0.00%） | 0 / 16（0.00%） | 0 | ✅ |
| `#Total_luts` | 14,155 | 14,549 | +394 | — |
| `#lut4` | 11,730 | 12,000 | +270 | — |
| `#lut5` | 2,396 | 2,520 | +124 | — |
| `#lut6` | 29 | 29 | 0 | — |

**gate QoR**（`project/gate.qor` vs 基线 `reports/t7b_bit_v3_seed7_PASS/gate.qor`）：

| 项 | 基线 | 本轮（两次同值） | 差值 |
|----|------|-----------------|------|
| Setup WNS | −4,917 ps | **−3,458 ps** | **+1,459 ps（改善）** |
| Setup TNS | −118,949 ps | −62,832 ps | +56,117 ps（改善） |
| Num of violated S-EP | 39 | **37** | −2（改善） |
| Hold WNS | +471 ps | +471 ps | 0 |
| Hold TNS | 0 | 0 | 0 |
| `#registers` | 8,210 | 8,461 | **+251** |
| `#luts` | 14,155 | 14,549 | +394 |
| `#slices` | 530（5.41%） | **546（5.57%）** | +16 / +0.16 pp |
| `#RAMs` | 37 | 37 | 0 ✅ |
| `#DSPs` | 24 | 24 | 0 ✅ |

> gate 阶段的时序**比基线更好**（WNS +1,459 ps）。这说明本轮改动没有恶化综合级时序，
> 问题出在物理实现（place 撑大 + hold fix）。

### 4.2 place 阶段

**跑 #1（seed7，与基线同参数）**：

| 项 | 基线 place.qor | 跑 #1 place.qor | 差值 | 判定 |
|----|---------------|----------------|------|------|
| Setup WNS | +1,707 ps | **+1,857 ps** | +150 ps | 改善 |
| Setup TNS | 0 | 0 | 0 | ✅ |
| Num of violated S-EP | 0 | 0 | 0 | ✅ |
| FMAX | 42.931 MHz | 43.210 MHz | +0.279 MHz | 改善 |
| **Hold WNS** | **−11 ps** | **−41 ps** | **−30 ps** | ⚠️ 恶化 |
| **Hold TNS** | **−154 ps** | **−247 ps** | **−93 ps** | ⚠️ 恶化 |
| **Num of violated H-EP** | **14** | **17** | **+3** | ⚠️ 恶化 |
| **Wire length** | **719,610** | **786,194** | **+66,584（+9.3%）** | ⚠️ |
| **`#slices`** | **8,591（87.66%）** | **8,814（89.94%）** | **+223 / +2.28 pp** | ❌ **关键恶化** |
| `#RAMs` | 37 | 37 | 0 | ✅ |
| `#DSPs` | 24 | 24 | 0 | ✅ |
| Top 1% tile util | 56 | 56 | 0 | — |
| Top 1% tile avg util | 59.17% | 58.69% | −0.48 pp | — |
| Over 100% util #tile | 0 | 0 | 0 | — |

**跑 #2（默认 seed）**：

| 项 | 跑 #2 place.qor |
|----|----------------|
| Setup WNS | +1,757 ps |
| Setup TNS | 0 |
| violated S-EP | 0 |
| FMAX | 43.024 MHz |
| Hold WNS | −11 ps |
| Hold TNS | −121 ps |
| violated H-EP | 11 |
| Wire length | 796,125 |
| **`#slices`** | **8,768（89.47%）** |
| `#RAMs` / `#DSPs` | 37 / 24 |

> 两个 seed 的 place 结果都指向同一事实：**`#slices` 从 87.66% 涨到 89.47–89.94%**。
> 这是本轮所有物理阻塞的源头。

### 4.3 post-route 阶段：**无数据**

route 未完成，`update_timing -mode final` 未执行，脚本在写报告前 exit 9。

| 项 | 基线（seed7，Routed） | 本轮 |
|----|---------------------|------|
| Setup WNS | **+113 ps** | **无数据（route 未完成）** |
| Setup TNS | 0 | 无数据 |
| Num of violated S-EP | 0 | 无数据 |
| Hold WNS | **+11 ps** | 无数据 |
| Hold TNS | 0 | 无数据 |
| Num of violated H-EP | 0 | 无数据 |
| Wire length | 1,664,088 | route 中途 `1.77757e+06`（跑 #1）/ `1.81001e+06`（跑 #2），**最终未定** |
| `#slices`（route） | 8,591（87.66%） | 无数据 |
| `#lut`（route 后实测） | 16,414 / 19,600（83.74%） | 无数据 |
| `#reg`（route 后实测） | 8,441 / 19,600（43.07%） | 无数据 |
| `#le` | 16,795 | 无数据 |
| `#bram`（route 后实测） | 37 / 64 | 无数据（gate 已实测 37，见 §5.2） |
| STA coverage | 99.84%（Routed / Both Slow/Fast / CRPR Enabled） | 无数据 |

**替代表（run 内部最后一次 update_timing，仅供趋势判断，不能用于签核）**：

| 跑次 | 最后一次 route 内部 Setup WNS | TNS | FEP | Hold WNS | Hold FEP |
|------|---------------------------|-----|-----|----------|----------|
| 基线（改动前 seed7，`run_seed7.log`） | **+0.113** | 0.000 | 0 | −0.020 | 3 → 修完 +0.011 |
| 跑 #2（默认 seed） | **+0.124** | 0.000 | 0 | −0.012 | 7 → 修 hold 时炸 |
| 跑 #1（seed7） | **−1.428** | −7.391 | 12 | −0.020 | 3 |

> **这个表是本次最重要的诊断线索**：跑 #2 在 route 优化结束时的 setup（+0.124 ns）**比基线（+0.113 ns）还好**。
> 也就是说：**本轮 RTL 在功能与 setup 上都没有退化，卡住的是 hold 修复引发的布通性问题。**

### 4.4 与「本轮预期面积增量」的偏差分析

任务书预期 **+160 LUT / +512 REG**。实测 gate 级 **+426 LUT / +219 REG**：

| 项 | 预期 | 实测 | 偏差 |
|----|------|------|------|
| LUT | +160 | **+426** | **2.7 倍** |
| REG | +512 | **+219** | **43%** |

**逐实例归因**（对比两份 gate 面积报告的 "Report Hierarchy Area" 表，72 行/份）：

> **口径说明（captain 补，回应审查 SUG-2）**：本表的 dLUT **是同一阶段的两份报告相减**
> （`t10_verify_build_20261103_routefail/baseline_ref/t7b3_rl45_gate_area.txt`
> 的 gate 后基线 vs `t10_r2_verify_build_20261103_PASS/run_r2_hfn/gate_area.txt`
> 的 gate 后本轮），不是拿 gate 报告去减 route 报告。
>
> 之所以要专门声明，是因为本报告里同时存在 **四套不同口径的 `#lut` 数字**，
> 它们分属三个阶段，混减会得到互相矛盾的结论：
>
> | 口径 | 基线 | 本轮 | 差值 | 阶段 |
> |------|------|------|------|------|
> | gate 面积报告 `#lut` | 15,244 | 15,670 | **+426** | 综合（gate）后，§4.5 用的是这一组 |
> | gate 报告里的 `u_axis` | 2,246 | 2,479 | **+233** | 同上（表内 dLUT 的来源） |
> | route 后面积报告 `#lut` | 16,414 | 16,868 | **+454** | 布线（route）后，§10.5 用的是这一组 |
> | route 后 `u_axis` | 2,384 | 2,470 | **+86** | 同上 |
>
> 交叉相减（如 2,479 − 2,384 = +95，或 2,470 − 2,384 = +86）会得到不同的「u_axis 增量」，
> **这些数字都不是错的，但回答的是不同问题**：+233 回答「综合阶段 u_axis 涨了多少」，
> +86 回答「布线阶段 u_axis 涨了多少」。审查方看到的 +95 属于跨阶段混减。
>
> 另注：两份报告的列口径也不同 —— gate 报告是 7 列（`lut / ripple / ...`，
> 见上表 u_axis 行 `2246 | 0 | 28 | ...`，第 4 列为 ripple），
> route 后报告是 8 列（`lut / ripple / lut1 / ...`，u_axis 行 `2384 | 2384 | 0 | ...`）。
> **列数不同时不能按位置直接相减**，必须先对齐列名。

| 实例 | 模块 | dLUT | dSEQ | 归因 |
|------|------|------|------|------|
| **`u_axis`** | `video_rgb_to_axis` | **+233** | 0 | ★ **该文件本轮未修改**（`git status --short -- rtl/video/video_rgb_to_axis.v` 为空）⇒ 工具映射噪声 / 跨模块逻辑被合并进该层级，**不是本轮语义变化** |
| `u_player` | `image_player` | +85 | +67 | t7（`display_*_sel` 选择器 + `FRAME_W16/H16`） |
| `u_wav` | `wav_stream_player` | +46 | +7 | t6 |
| `u_scaler` | `img_scaler` | +33 | +23 | t7 |
| `u_seg` | `seg_scan4` | +17 | — | 工具 |
| `u_vol` | `vol_apply` | +9 | +2 | 工具 |
| HDMI core 链（`u_hdmi_core` / `u_hdmi_tx_controller_wrapper` / `u_hdmi_island_data_gen` / `U_audio_sample_packet_2_channel`） | — | 合计 +39 | +48 | 工具 |
| `u_rle` | `rle_decoder` | +8 | +3 | t9（P0-A2 门控，预期 +2，实测 +8） |
| `u_fat` | `fat32_reader` | +8 | +3 | 工具 |
| `u_gallery` | `gallery_probe` | +6 | — | t9（d6 显示分支） |
| `u_sd` | `sd_spi_ctrl` | +6 | — | 工具 |
| `u_loader` | `img_loader` | +5 | — | 工具 |
| `u_osd_panel` | `osd_panel` | **−12** | — | t8 底条收窄后少了一点逻辑 |
| `u_overlay` | `video_overlay` | −2 | **+128** | t6 的 hist 寄存器被工具归到该层级 |
| **`u_wave`** | `audio_waveform` | **0** | **+128** | t6 的 64×24bit hist（1536 位）**没有原样保留成独立寄存器**，只涨 128 个 flop（被 TD 合并），LUT 侧 0 |
| **`u_err`** | `err_prompt` | **−2** | 0 | t9 的 rle/wav 分支（任务书预期 +30）在 gate 层**几乎零成本**，被常量/条件优化吃掉 |

**结论**：

1. **没有失控的语义级膨胀**。+426 里有 **+233 落在未修改的 `u_axis`**（工具噪声），
   扣除后本轮真实语义增量约 **+193 LUT**，与预期 +160 同量级。
2. **REG 只有 +219 而非 +512**：t6 的 1536 位 hist 未被按位保留（TD 合并了常驻移位链），
   这是**预期之外的好消息**，不是缺陷——`tb_audio_waveform` 的 80 条断言证明波形行为正确。
3. 任务书给的两道「必须查清」阈值（LUT > 17,500 / REG > 9,500）**均未触发**
   （实测 15,670 / 8,517）。
4. **但 `#lut` 占用已从 77.78% 涨到 79.95%，slices 从 87.66% 涨到 89.94%**——
   余量被吃掉 2.28 个百分点，正好足以让 route 布不通。

### 4.5 与历史高面积时代的对比（澄清一个易混淆点）

`reports/t7b3_rl45_place_post_place_opt_high_area.txt` / `t7b3_rl45_route_post_route_opt_high_area.txt`
（11-02 20:27）记录过 **`#lut 18,473 / 94.25%`、`#bram 35`** 的更高面积状态。
那是 **min_ripple_len + 老版 RTL**（t7b_bit2 时代）的成绩，**不是当前基线**。
当前 79.95% 与它差 14.3 个百分点，**不能混为一谈**。

不过它提供了一个重要历史事实：**`t7b_bit2.tcl` 时代 route 是布通过的**
（`project/t7b_bit3.tcl` 头部注释 `:5` 记「place PASS（mslices 4801，留 99）→ route PASS → update_timing PASS」，
只是 SWNS −0.183 被 exit 12 拦下未 bitgen）。⇒ **本设计在 94% LUT 下也曾布通**，
说明布通性与"面积绝对值"不是简单线性关系，而是与**高扇出复位网的复制策略 + hold fix 是否插 buffer**强相关。

---

## 5. 三条红线的明确结论

### 5.1 红线 ①：Setup WNS 必须仍为正 → **无法签核（route 未完成）**，但趋势向好

- **正式结论**：**无数据**。`update_timing -mode final` 未执行，没有 post-route 时序报告。
- **趋势判断（不能替代签核）**：跑 #2 的 route 优化结束时 Setup **+0.124 ns / TNS 0 / 0 FEP**，
  比基线的 +0.113 ns 略好。⇒ **本轮改动没有把 setup 打坏**，任务书担心
  「t7 的 `in_image` 交集逻辑与 113 ps 零余量路径同一组合锥」的风险，**在本次两次跑中未观察到**
  （跑 #1 的 −1.428 是 seed7 下 route 优化不足，不是 in_image 引起的单点路径问题）。
- **因此不需要**执行任务书预设的「收窄 `in_image` 16bit 比较到 10/9 位」动作。

### 5.2 红线 ②：`#bram` 必须仍为 37 → **✅ 通过**

| 来源 | `#bram` | `#bram9k` | `#fifo9k` | `#bram32k` |
|------|---------|-----------|-----------|------------|
| 基线 gate | 37 / 64 | 37 | 0 | 0 / 16 |
| **本轮 gate（跑 #1）** | **37 / 64** | **37** | **0** | 0 / 16 |
| **本轮 gate（跑 #2）** | **37 / 64** | **37** | **0** | **0** |
| 基线 gate.qor `#RAMs` | 37 | — | — | — |
| 本轮 gate.qor `#RAMs` | 37 | — | — | — |
| 本轮 place.qor `#RAMs`（两次） | 37 | — | — | — |

- **是 37，不是 35** ⇒ `narr_subline` **没有**被常量传播剪掉。
- `#fifo9k = 0` 且 `#bram32k = 0` 且 `#bram9k = 37` ⇒ `u_pix_fifo` **没有**退回 LUTRAM
  （否则 `#lut` 会涨回 18,000 量级、`#bram` 会掉到 35 以下）。
- `HDL-1100 : Inferred 7 RAMs.` 在两次 elaborate 中都出现，与基线一致。
- ★ 注意：`project/t7b_bit3.tcl:250` 的底线是 35，**35 挡不住 pix_fifo 退回 LUTRAM**——
  本报告已人工确认是 **37**。

### 5.3 红线 ③：位流必须真的更新 → **❌ 未更新**

| 项 | 基线 | 本次 | 是否变化 |
|----|------|------|---------|
| 路径 | `project/hdmi_td_Runs/phy_1/hdmi_td.bit` | 同 | — |
| 大小 | 648,264 B | **648,264 B** | **否** |
| 时间戳 | 2026-11-03 00:31:47 | **2026-11-03 00:31:47** | **否** |
| MD5 | `59A6BACC75613F5E953B7ED5A33E05E8` | **`59A6BACC75613F5E953B7ED5A33E05E8`** | **否（逐字节相同）** |

⇒ **位流文件是基线件，不含本轮任何修复。**

---

## 6. 归档清单（每份产物的路径 + 时间戳 + 大小 + MD5）

归档根目录：`reports/t10_verify_build_20261103_routefail/`
（**未覆盖** `reports/t7b_bit_v3_seed7_PASS/`，后者原样保留作对比基线）

### 6.1 回归

| 相对路径 | 大小 | 时间戳 | MD5 |
|---------|------|--------|-----|
| `regression_summary.json` | 4,089 B | 2026-11-03 22:22:47 | `3C319A513956C2226AF90D9876212A1D` |
| `regression_driver_console.log` | 3,326 B | 2026-11-03 22:22:47 | `0CFD401EEF408A183B56CE2F0B790624` |

完整逐用例日志（67.3 MB）留在仓库外：`D:\FPGA_Compelate\_t10_regression_20261103\{unit,frontend,storage,audio,startup,display,image}\`

### 6.2 跑 #1（seed7，FAIL-route）

| 相对路径 | 大小 | 时间戳 | MD5 |
|---------|------|--------|-----|
| `run1_seed7/td_full_elaborate_seed7.log` | 350,086 B | 22:31:35 | `B366FA57280E88B22B882261E04F7F25` |
| `run1_seed7/t7b3_rl45_place_seed_7_gate_area.txt` | 17,035 B | 22:25:05 | `770ADC8D3C775BA213293AF437342B01` |
| `run1_seed7/gate.qor` | 7,748 B | 22:25:04 | `B602D0532F4F9D776E1A3595266C5FB3` |
| `run1_seed7/place.qor` | 1,741 B | 22:30:10 | `746361FD696C30D28A974489C80D468A` |
| `run1_seed7/t7b3_rl45_place_seed_7_gate.db` | 6,044,562 B | 22:25:06 | `401F297C727B7EFE7A880045A2621FFE` |
| `run1_seed7/t7b3_rl45_place_seed_7_place.db` | 8,544,948 B | 22:26:21 | `E6CE42A7FEEA712B876CF0BA56276B5F` |

**缺失**（route 失败未生成）：`t7b3_rl45_place_seed_7_timing.txt` / `_area.txt` / `_coverage.txt` / 位流

### 6.3 跑 #2（默认 seed，FAIL-route）

| 相对路径 | 大小 | 时间戳 | MD5 |
|---------|------|--------|-----|
| `run2_defaultseed/td_full_elaborate_defaultseed.log` | 272,698 B | 22:40:52 | `FFDCF0E4D9E36B76DB7760E56AE4EAD0` |
| `run2_defaultseed/t7b3_rl45_gate_area.txt` | 17,035 B | 22:35:47 | `770ADC8D3C775BA213293AF437342B01` |
| `run2_defaultseed/gate.qor` | 7,748 B | 22:35:46 | `B602D0532F4F9D776E1A3595266C5FB3` |
| `run2_defaultseed/place.qor` | 1,741 B | 22:39:24 | `EA5F1C8CB5230DF6D3339336701E604F` |
| `run2_defaultseed/t7b3_rl45_gate.db` | 6,044,558 B | 22:35:47 | `C6CC16642864F05F350D1B376BDB9070` |
| `run2_defaultseed/t7b3_rl45_place.db` | 8,531,578 B | 22:37:04 | `7E4468486715FAE1ED5D757655FD00FD` |

> **交叉验证价值**：`run1_seed7/gate.qor` 与 `run2_defaultseed/gate.qor` 的 **MD5 完全相同**
> （`B602D053...`），两份 gate 面积文件也完全相同（`770ADC8D...`）。
> 这证明 **gate 阶段不受 `place seed` 影响**，本轮面积增量是可复现的确定值。

### 6.4 基线参考副本（只读对比用，原目录未动）

| 相对路径 | 大小 | 时间戳 | MD5 | 来源 |
|---------|------|--------|-----|------|
| `baseline_ref/route.qor` | 1,313 B | 11-03 00:31:24 | `8A7559C2FD8DA1D58DE9810718B118C1` | `reports/t7b_bit_v3_seed7_PASS/` |
| `baseline_ref/place.qor` | 1,741 B | 11-03 00:30:33 | `8EC634E557C4B7E0F456EE1F202A2E06` | 同上 |
| `baseline_ref/gate.qor` | 7,726 B | 11-03 00:13:52 | `0CA6AE6F22467809FCBCDBF227FC8FF4` | 同上 |
| `baseline_ref/t7b3_rl45_gate_area.txt` | 17,035 B | 11-03 00:13:54 | `BDFDFB84081621CF804EAD8B1B37DB75` | `reports/` |
| `baseline_ref/t7b3_rl45_area.txt` | 25,852 B | 11-03 00:20:27 | `11F357F4B3D40CF2E3CE9A5D826961A0` | `reports/` |
| `baseline_ref/t7b3_rl45_timing.txt` | 825,359 B | 11-03 00:20:27 | `0AE24A87A8695526B32D50706C88AE97` | `reports/` |

> 最后两份是**改动前 RTL + 默认 seed 的全流程结果**（SWNS −0.194 / STNS −0.215 / 3 违例端点），
> 在跑 #2 之前已备份，未被覆盖。

### 6.5 仓库外的原始工作目录

`D:\FPGA_Compelate\_t10_regression_20261103\`（67.3 MB）：

- `summary.json` / `driver_console.log` / `unit|frontend|storage|audio|startup|display|image/`（逐用例日志）
- `td_full_elaborate_seed7.log` / `td_full_elaborate_defaultseed.log`
- `run1_seed7_routefail/` / `run2_defaultseed_routefail/`
- `baseline_project_snapshot/` / `prechange_defaultseed_reports/`
- 辅助脚本：`dump_results.py` / `dump_tests.py` / `compare_baseline.py` / `diff_area_hier.py`

---

## 7. 本结果能证明什么、不能证明什么

### 7.1 能证明

| # | 结论 | 证据强度 |
|---|------|---------|
| 1 | **本轮 4 个修复（t6 音频 / t7 视频 / t8 OSD 黑条 / t9 科普）的行为在 RTL 仿真层成立** | **强**。911,909 条断言 0 失败，其中 t6 的波形幅度/源名、t7 的 display 几何、t8 的底条边界、t9 的 RLE 门控各有专向断言 |
| 2 | **t7/t9 的核心新 TB（`tb_image_window_mask` 52 / `tb_rle_decoder` 72）也全绿** | **强**（手工单独跑，编译+仿真 exit 0） |
| 3 | **`narr_subline` 未被剪掉、`u_pix_fifo` 未退回 LUTRAM** | **强**。`#bram` 两次跑都是 37/64，`#fifo9k=0`、`#bram32k=0` |
| 4 | **本轮改动没有恶化综合级时序** | **强**。gate WNS 从 −4,917 ps 改善到 −3,458 ps（+1,459 ps） |
| 5 | **本轮改动没有超出预期量级的资源膨胀** | **中强**。+426 LUT 中 +233 落在未修改的 `u_axis`；真实语义增量约 +193 LUT，未触发 17,500 / 9,500 两道复核阈值 |
| 6 | **源码同步链是幂等的，TD 不污染 `rtl/`** | **强**。二次 sync 打印 `0/71` |
| 7 | **route 阻塞的物理原因可定位**：slices 87.66%→89.94%（+223）+ hold fix 插 8 个 buffer 打到高扇出复位网 `rst_n_dup_53` | **中强**。两次跑独立复现，两条 PHY-8023 都指向 `rst_n_dup_*`，且 `rst_n_dup_53_holdbuf0` 明确是 hold 修复产物 |

### 7.2 不能证明（**必须在评审和上板结论中明确**）

> **★ 时效声明（captain 补，回应审查 SUG-3）**：本节是**第 1 轮（route 失败）**的口径，
> 其中第 1、2、3、7 条已被第 2 轮的结果推翻 —— 第 2 轮已经出了位流
> （MD5 `AA65465E…` / 23:35:55）、已经签核 post-route 时序
> （Setup +109 ps / Hold +19 ps，双 0 违例）、也拿到了实现后的 `#lut`/`#reg`/`#slices`。
> **上板结论必须读 §10.7**，那一节才是第 2 轮的口径。
> 本节保留原文是为了留下「第 1 轮当时能证明什么」的记录，不是当前结论。

| # | 不能证明的事 | 原因 |
|---|-------------|------|
| 1 | **本轮修复在真实 FPGA 上功能正确** | **完全没有新位流**。当前 `hdmi_td.bit` 是 00:31:47 的基线件，上板只能验证旧 RTL |
| 2 | **post-route 时序成立** | route 未完成，`update_timing -mode final` 未执行，**无 SWNS/HWNS 签核数据** |
| 3 | **实现后的 #lut / #reg / #slices 最终值** | 同上。§4.1/4.2 给的是 gate / place 值，post-route 通常还会再涨 |
| 4 | **本轮改动是否引入 hold 恶化** | place 阶段 hold 违例从 14 涨到 17（跑 #1），但那是 place 估计值，不能等同于 final 结果 |
| 5 | **回归通过 = 真卡时序成立** | **不等价**。`display` 套件的 `seam` 字段自报 `modeled external sector service and behavioral SDRAM`——SDRAM 与 SD 扇区服务都是行为模型。真实 SD 卡时序、真实 SDRAM 控制器时序、真实 SPI 速率下的 RLE 流带宽，**一条都没被验证** |
| 6 | **I2C 物理可靠性** | SDC `project/hdmi/dmz_eg4s20_hdmi.sdc` 里 **4 条 `set_false_path` 全是 I2C**（`:118-121`，from/to `i2c_scl`、`i2c_sda`）。`SWNS` 对 I2C **零证据**。而且整个 SDC **只有一条 `create_clock`**（`:88`，25 MHz on `clk`），**无任何 `create_generated_clock`** ⇒ 所有派生时钟（HDMI 像素时钟、SDRAM 时钟等）的时序约束方式需要另行确认 |
| 7 | **上板 6 个现象是否已解决** | 全部依赖位流。本任务不上板，且没有可用新位流 |
| 8 | **回归覆盖率完整** | 至少 10 个 TB 不在任何套件里（见 §2.5），其中 2 个是本轮的核心验证者 |
| 9 | **面积增量完全归因** | `u_axis` 的 +233 LUT 出现在**未修改**的文件上，只有「工具映射噪声」这一推断，未做 TD 层逐个 LUT 溯源 |

---

## 8. 交给 captain 的决策项（**本任务不自行实施**）

> **⚠️ 本条已由第二轮实测裁决，保留原文仅作历史记录。**
> captain 随后给出关键更正：**选项 A（`route fix_hold on`）是空操作**——`fix_hold` 默认就是 on
> （`D:\TD_6_24_APP\doc\scripts\DefaultFlow.tcl:192-201` 的写法是 `set_param route fix_hold off` → `route` → `fix_hold` → `set_param route fix_hold on`，on = 恢复默认）。
> 第二轮实际走了**选项 D 的强化版**（`place hfn_opt_effort high` + `place crit_path_opt on`，取自 TimingUltra 组），
> **一次成功**，三条红线全过。完整数据见 §10。下表 A–E 仅保留第一轮的分析视角。

按 t10 任务书边界「若回归失败或 WNS 转负，报告并交给 captain 决定，**不要自己改代码去凑绿**」，
以下动作**全部未执行**，仅列出选项与依据：

| 选项 | 动作 | 依据 | 风险 |
|------|------|------|------|
| **A** | 用 `T7B3_EXTRA='route fix_hold on'`（`t7b_bit3.tcl:25` 已支持的合法通道）重跑 | 两次失败都发生在 TD 自动 hold fix 阶段；关掉它让 TD 不做插 buffer，可能避开 PHY-8023 | 若 hold 违例留在最终件里，位流在板上可能偶发亚稳态。**需先确认 −0.012 ns hold 风险是否可接受** |
| **B** | 降面积后再跑：把 t7 在 `image_window_mask` 的 `in_image` 16bit 比较收窄到 10/9 位（任务书预设手段） | 可回收 30–70 LUT | 本次数据显示 setup 不是瓶颈（跑 #2 route 内已到 +0.124），收窄比较器对 slices 占用的帮助有限；**优先级低于 A** |
| **C** | 换 place seed / 提高 place 与 route effort 重跑（多 seed 搜解） | 历史先例：seed=7 vs 默认对 slices 有 ±170 的影响 | 每个 seed 约 7–8 分钟；且**不解决 hold fix 插 buffer 的根因**，可能换两根网再失败 |
| **D** | 复核 `rst_n` 高扇出复位网的复制策略（`hfn_opt_effort`，`t7b_bit.tcl:47` 用过 `low`） | 两次失败 100% 落在 `rst_n_dup_*` | 需改 TD 参数或 RTL 复位策略；`t7b_bit2.tcl:12` 记录 `hfn_opt_effort low` 只把 place mslices 从 5306 降到 5276（−30，**判定无效**） |
| **E** | 接受"无位流"结论，本轮只交付回归证据，上板延后 | 回归是完整可信的成果 | 用户报的 6 个现象**一个都不会被验证** |

> **我的建议（仅供参考，决定权在 captain）**：优先试 **A**（`route fix_hold on`），
> 因为跑 #2 已经证明 setup 能收敛到 +0.124 ns，唯一的拦路虎就是 hold fix 阶段。
> 若 A 也不行，再叠加 **D**（复位网复制策略）。
>
> **⚠️ 该建议已被证伪**：A 是空操作（见本节开头），实际有效的是 D 的强化版 `hfn_opt_effort high`。

---

## 9. 待办 / 技术债（本任务发现，未实施）

> **第 1、2 项已在第二轮完成**（两个孤儿 TB 已补进套件并真跑通过），见 §10.1。

| # | 项 | 优先级 | 说明 |
|---|-----|--------|------|
| 1 | ~~把 `tb_rle_decoder.v` 补进 `run_storage_regression.ps1`~~ | ~~**高**~~ → ✅ **第二轮已完成** | t9 的核心验证者，当前完全不在回归里 |
| 2 | ~~把 `tb_image_window_mask.v` 补进 `run_image_regression.ps1`~~ | ~~**高**~~ → ✅ **第二轮已完成** | t7 的核心验证者，同上 |
| 3 | 清理 `project/t2_*`、`project/backup_t2*` 历史探针目录 | 中 | 会让 `lint_verilog.py rtl project` 报 E1=2/E2=19 |
| 4 | 统一 `lint_verilog.py` 的调用口径（`rtl project/src project/hdmi`） | 中 | 写进 CI 或文档，避免下次误判 |
| 5 | `project/t7b_bit3.tcl:250` 的 `#bram >= 35` 底线偏松 | 中 | 35 挡不住 pix_fifo 退回 LUTRAM，建议改成 `== 37` 或显式检查 `#fifo9k/#bram32k` |
| 6 | `reports/t7b_bit_v3_seed7_PASS/` 之外的历史 timing 报表格式不统一 | 低 | 部分 `*_timing.txt` 无 `SWNS:` summary 段，无法自动比对 |
| 7 | `tb_osd_caption.v` 的 checks 数与旧记录不可直接相减 | 低 | 该文件在 commit `451dd29`（10-31 15:58）首次入库、`946f74f`（11-03 19:50）被 t16 改写 +89/−79 行，checks 56→46；建议在基线表里标注 TB 版本号 |
| 8 | **第二轮新增**：`#lut` 已达 86.06%、`#slices` 89.57% | **高** | 距满仅 14% LUT 余量；下次改动（如再加工位）极可能重演布线失败。见 §10.6 |
| 9 | **第二轮新增**：`project/t10_r2_flow.tcl` 是临时脚本 | 中 | 复用 gate.db 的入口；若后续要复现，应正式并入 `t7b_bit3.tcl` 或写进文档 |
| 10 | **第二轮新增**：TD 的 `*.qor` 落在**当前工作目录**而非 `project/` | 中 | 用相对路径调 `report_qor` 时，cwd 决定落点；第一轮在仓库根留下 `place.qor`（已清理），第二轮改为 `cd project` 才取到正确数据 |
| 11 | 仍有 8 个孤儿 TB 未覆盖 | 低 | `tb_dbg_scaler` / `tb_dmz_eg4s20_bringup` / `tb_fifo_fwft` / `tb_framebuf_realcore_concurrent` / `tb_probe_burst` / `tb_probe_order` / `tb_probe_pix` / `tb_seg_scan4` |

---

## 附录 A：TD 两次跑的命令序列（去掉 43 条 `set_pin_assignment`）

> 说明：`t7b_bit3.tcl` 只显式发出 **25 条**命令（`open_project` / `set_param` / `commit_param` / `elaborate` /
> `read_adc` / `read_sdc` / `optimize_rtl` / `optimize_gate` / `report_area` / `export_db` / `place` / `route` /
> `update_timing` / `report_timing_summary` / `report_area` / `check_timing` / `bitgen`）。
> 下表中 `legalize_phy_inst` / `update_pll_param` / `start_timer` / `report_qor` / `place -eco` / `route -eco`
> **全部是 TD 引擎内部自动插入的**（`RUN-1002 : start command` 只是把它们也记进了日志），
> 不是脚本内容——已用 `Select-String -Path project\t7b_bit3.tcl -Pattern 'place -eco|route -eco|legalize_phy_inst|start_timer|update_pll_param|report_qor'`
> 核实，脚本内 **0 命中**。

```
import_device eagle_s20.db -package EG4S20BG256
open_project D:/FPGA_Compelate/SmartCampusMedia/project/hdmi_td.al
commit_param -step design
set_param rtl min_ripple_len 45
commit_param -step rtl
[跑 #1 独有，来自 T7B3_EXTRA] set_param place seed 7
[跑 #1 独有，来自 T7B3_EXTRA] commit_param -step place
elaborate -top dmz_eg4s20_hdmi_top
read_adc  D:/FPGA_Compelate/SmartCampusMedia/project/hdmi/dmz_eg4s20_hdmi.adc
set_pin_assignment ... × 43            ← 来自 .adc 的引脚约束，两次跑都是 43 条
read_sdc  D:/FPGA_Compelate/SmartCampusMedia/project/hdmi/dmz_eg4s20_hdmi.sdc
optimize_rtl
optimize_gate
--- 以下 TD 内部自动插入 ---
update_pll_param -module dmz_eg4s20_hdmi_top
report_qor -step gate -file gate.qor
report_area -io_info -file <reports>/t7b3_<tag>_gate_area.txt      ← 来自脚本
export_db <project>/t7b3_<tag>_gate.db                              ← 来自脚本
place                                                               ← 来自脚本
legalize_phy_inst
report_qor -step place -file place.qor
export_db <project>/t7b3_<tag>_place.db                             ← 来自脚本
route                                                               ← 来自脚本
place -eco -ignore_route_tracer        ← 跑 #1 有（route 报错后的自动 ECO 重试），跑 #2 无
report_qor -step place -file place.qor ← 跑 #1 有
route -eco                             ← 跑 #1 有
[脚本在 route 失败后 exit 9，以下均未执行]
update_timing -mode final
report_timing_summary
report_area
check_timing
bitgen -bit <project>/hdmi_td_Runs/phy_1/hdmi_td.bit
```

## 附录 B：seed 生效的判定

任务书要求「PASS-set_param 不能作为生效证据，必须看产物是否变化」。

- `T7B3_EXTRA='place seed 7'` 在跑 #1 中：
  - 日志有 `RUN-1002 : start command "set_param place seed 7"` + `PASS-set_param place seed 7` + `PASS-commit_param place`
  - **产物侧差异**：place 后 `#slices` **8,814（跑 #1 / seed7）vs 8,768（跑 #2 / 默认）**，差 **46**；
    Wire length **786,194 vs 796,125**，差 **9,931**；Hold TNS **−247 vs −121**。
  - **gate 阶段完全一致**（gate.qor 与 gate 面积文件 MD5 相同）⇒ 差异确实发生在 place 阶段，seed 真的生效了。
- 与基线 seed7 的对齐：跑 #1 的 place `#slices 8,814` 对基线 `8,591`（差 +223，是本轮 RTL 的面积增量），
  **同参数、可比**。

---

*报告生成：verify-build / t10 / 2026-11-03 22:50*
*本报告不含任何 RTL/TB 语义改动；未执行 `git commit`；未上板。*

---

# 第 2 轮（attempt 2）：补齐回归覆盖 + 找到可行布线路径 + 出位流

> 本轮起点：第 1 轮 TD 两次全流程均 FAIL-route。captain 复核后驳回了我第 1 轮推荐的
> 「选项 A：`route fix_hold on`」——理由是它**本来就是默认行为**（`DefaultFlow.tcl:192-201`
> 的 `set_param route fix_hold on` 只是恢复默认），并给出了新的路线 1 / 路线 2。
> 本轮按 captain 指令执行，**结果：路线 1 失败、路线 2 成功出位流**。

## 10.1 第 0 步：补齐两个孤儿 TB 的回归覆盖（已完成）

### 10.1.1 为什么能复用第 1 轮的回归证据

captain 要求「复用旧回归」必须可审计。做法：把本轮 11 个 `.v` + 9 个 `.tb` 的 MD5 与
第 1 轮记录逐一比对。

```
diff count = 0 / 20  → IDENTICAL, regression evidence reusable
```

- 实测清单：`_t10_round2_coverage/rtl_tb_md5.txt`（20 条，含路径与 MD5）
- 归档副本：`reports/t10_r2_verify_build_20261103_PASS/regression/rtl_tb_md5.txt`
- `rtl/` 最新 mtime = `rtl/video/audio_waveform.v` **2026-11-03 21:51:11**，
  早于第 1 轮启动（22:08）⇒ 期间无源码漂移。
- `git diff --stat -- rtl` 仍是 `11 files changed, 662 insertions(+), 74 deletions(-)`，
  与本轮开始时一致。

**因此：第 1 轮的七套回归结果（7/7、911,909 断言、752 s）继续有效，本轮只补跑新增覆盖。**

### 10.1.2 两个新 TB 的调用契约（决定了脚本怎么改）

| TB | 依赖 | 收尾标记 | summary 格式 | 难点 |
|----|------|----------|--------------|------|
| `tb_rle_decoder.v` | 只例化 `rle_decoder`；用 `../testbench/vectors/*.hex` **相对路径** | `RESULT: PASS` | `TB_RLE_DECODER SUMMARY: checks=N errors=N`（**无 cases=**） | 要求 cwd 是 `sim/` 的下一层目录，否则 `FATAL: cannot open ../testbench/vectors/...` |
| `tb_image_window_mask.v` | 无（纯组合自测） | `ALL CHECKS PASSED: image_window_mask` | `SUMMARY: checks=N errors=N`（**无 cases=**） | 只需把 summary 正则放宽到两段式 |

相对路径的 5 种解法实测（只有一种可行）：

1. cwd 设为任意目录 → `FATAL: cannot open ../testbench/vectors/sci_f0_640x480.hex`
2. `-do "cd {...}; run -all"` → `Cannot change directory while a simulation is in progress`
3. 先 `cd` 再 `vsim <abs>/work.tb_*` → `(vsim-19) Failed to access library 'work' at "work"`
4. `-modelsimini {花括号路径}` → `(vsim-7) Failed to open -modelsimini file "{...}"`；去掉花括号用反斜杠 → 路径被 Tcl 转义吃掉成 `D:FPGA_Compelate...`
5. ✅ **可行**：`vmap work <out>\work`（在 `<out>` 生成 `modelsim.ini`）+ `cd <repo>/sim/_regression_rle` + `vsim -modelsimini <正斜杠绝对路径>`

### 10.1.3 脚本改动（2 个文件，+64 / −9 行）

`sim/scripts/run_storage_regression.ps1`：
- `$sources` 新增 `rtl\storage\rle_decoder.v` 与 `sim\testbench\tb_rle_decoder.v`
- `$ExpCaseCount`：`{4}` → `{5}`（All 档）
- `$tests` 新增 `tb_rle_decoder`，带 `workCwd` / `marker='RESULT: PASS'` / `casesFallback=8`
- 主循环新增 `$runCwd` 分支：`vmap.exe work <out>\work` → `-modelsimini <out>/modelsim.ini`
- summary 判据新增 `$hasCases` + `$casesSeen`：无 `cases=` 时退回两段式正则并用 `casesFallback` 兜底

`sim/scripts/run_image_regression.ps1`：
- `$sources` 新增 `sim/testbench/tb_image_window_mask.v`
- `$ExpCaseCount = 3 + ...` → `4 + ...`
- `$cases` 新增 `image_window_mask`

### 10.1.4 ★ 改造中踩的两个坑（已解决，记录备查）

**坑 1：编码被破坏导致整个脚本 parse 失败。**
`run_storage_regression.ps1` 与 `run_image_regression.ps1` 原文件是 **UTF-8 with BOM**
（首字节 `239,187,191`）。用 `edit` 工具写入后 BOM 丢失，PowerShell 5.1
（`$PSVersionTable.PSVersion` = 5.1.26100.9711）于是按 GBK 解析中文注释里的全角标点，
报 `The string is missing the terminator` / `Missing closing '}'` / `Variable reference is not valid`。
**修法**：`git checkout --` 还原，改用 Python `io.open(..., encoding='utf-8-sig')` 读写，
写完回读首 3 字节确认 `[239,187,191]`。

**坑 2：两个文件的换行风格不同。**
storage 是 **CRLF**（211 个 CRLF / 0 个 lone LF），image 是 **LF**（0 CRLF / 115 lone LF）。
补丁片段必须按目标文件的实际风格归一化，否则 `if old not in text` 全部 MISS。

**坑 3（TD 侧）：`vmap` 的输出文件名固定是 `<cwd>/modelsim.ini`**，不可指定。
我先写成 `regression_work.ini`，导致 `vsim-7 Failed to open -modelsimini file`、
`tb_rle_decoder` 首次跑出 `checks=0`。改成 `modelsim.ini` 后通过。

### 10.1.5 补齐后的实测结果

**storage（5/5，exit 0）**

| TB | 状态 | checks | cases |
|----|------|--------|-------|
| tb_async_fifo | passed | 24 | 8 |
| tb_framebuf_arbiter | passed | 71,023 | 15 |
| tb_sdram_ctrl_wrap | passed | 154,771 | 12 |
| tb_pix_reader | passed | 542 | 39 |
| **tb_rle_decoder（新增）** | **passed** | **72** | **8** |

`A4-GATE: ran=5 passed=5 expected=5` ⇒ 断言总数 226,360 → **226,432**（+72）。

**image（4/4，exit 0）**

| TB | 状态 | checks |
|----|------|--------|
| img_scaler | passed | 187 |
| image_player | passed | 11,405 |
| image_player_scaled | passed | 1,811 |
| **image_window_mask（新增）** | **passed** | **52** |

`A4-GATE: ran=4 passed=4 expected=4` ⇒ 断言总数 13,403 → **13,455**（+52）。

> ★ 注意：`tb_rle_decoder` 的 72 checks 与任务书预期完全一致；`tb_image_window_mask` 的 52
> 也与 t7 报告「断言 20→52」吻合。这两个 TB **此前不在任何 `sim/scripts/*.ps1` 里**
> （第 1 轮 §2.5 已记录），本轮正式纳入。
> 仍有 **8 个孤儿 TB** 未覆盖（见 §9 第 11 项）。

- 产物：`_t10_round2_coverage/{storage,image}/`（含 result.json、各 TB log、modelsim.ini、vmap.log）
- 归档：`reports/t10_r2_verify_build_20261103_PASS/regression/{storage,image}_result_r2.json`

## 10.2 第 1 步 TD：路线 1（拥塞恢复）→ **失败**

**参数来源**：captain 指定 `D:\TD_6_24_APP\doc\strategies\official_strategy_ph1.json` 的
`CongestionMedium` 最温和一档。

> **⚠️ 事后核对发现参数归属与 captain 的表述不一致**：`enhanced_gp on` 在
> `CongestionHigh`（:357）与 `CongestionMedium`（:423）**两个块里都有**；
> 但 `enable_congestion_recovery on` **只出现在 `CongestionHigh`（:372），不在 `CongestionMedium`**。
> 即实际用的是「CongestionHigh 的一项 + CongestionMedium 的一项」的混搭，
> 不是纯 `CongestionMedium` 档。这不影响结论（结论是这条路走不通），但记录以便复现时对齐。

**命令**（`project/t10_r2_flow.tcl`，复用 run2 的 gate.db，cwd 在仓库根）：

```
T7B3_EXTRA = 'place enable_congestion_recovery on place enhanced_gp on'
td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/t10_r2_flow.tcl
```

**结果：TD EXIT 9（FAIL-route），耗时 365 s**

| 阶段 | 结果 |
|------|------|
| import_device / open_project / set_param rtl / commit | PASS |
| import_db（复用 gate.db 6,044,558 B） | PASS |
| set_param place ×2 / commit place | PASS |
| read_adc / read_sdc | PASS |
| place（68,511 ms） | PASS |
| **route** | **FAIL（PHY-8023 + RUN-8102）** |

**失败点（与第 1 轮的两趟都不同）**：

```
PHY-8023 ERROR: Location: (x30y24_local3), nets: u_gallery/u_fat/mux217_syn_2[15] u_gallery/u_fat/cap_clr_n28
RUN-8102 ERROR: Incremental route failed. ...
```

这次只有 **1 条** PHY-8023、只命中 **1 根网**（`u_gallery/u_fat/cap_clr_n28`），
不是 `rst_n_dup_*` —— 说明参数确实改变了布局，但**没解决"没地方"**。

**关键指标（反而恶化）**：

| 指标 | 路线 1 | 第 1 轮 run2（默认 seed） | 基线（seed7） |
|------|--------|---------------------------|---------------|
| place Setup WNS | +1,807 ps | +1,757 ps | +1,707 ps |
| place Hold WNS | −11 ps | −11 ps | −11 ps |
| place Hold TNS | **−176** | −121 | −154 |
| place 违例 H-EP | **16** | 11 | 14 |
| **place `#slices`** | **8,843（90.23%）** | 8,768（89.47%） | 8,591（87.66%） |
| Wire length | 804,654 | 796,125 | 719,610 |

⇒ **占用率从 89.47% 升到 90.23%，hold 违例从 11 个涨到 16 个**。
「先疏松布局」的假设被证伪：这两个参数在本设计上**增加了** slices 占用。

**流程耗时分解**：place 68,511 ms；route 未完成（`route -eco` 84 s 级后即失败）。

> **附带发现（取数 bug，已修）**：第 1 轮我在仓库根目录调用 TD，`report_qor -step place -file place.qor`
> 用的是相对路径，于是 `place.qor` 落在了**仓库根**而不是 `project/`，我读到的是上一趟的旧文件。
> 本轮已改为 `cd project` 后再调用，`*.qor` 正确落在 `project/`。仓库根的 `place.qor` 已删除。
> 这也解释了为什么第 1 轮「新 place.qor」的时间戳是 22:39:24（那是 run2 的）。

- 日志：`_t10_round2_coverage/td_r1_congestion.log`（244,662 B）
- 归档：`_t10_round2_coverage/r1_congestion/{place.qor,td_r1_congestion.log}`

## 10.3 第 2 步 TD：路线 2（高扇出网优化）→ **成功出位流**

**参数来源**：captain 指定的 `TimingUltra` 组中的两项
（`official_strategy_ph1.json:199-201` 的 `hfn_opt_effort high`、`:189-191` 的 `crit_path_opt on`）。
逻辑：`hfn_opt_effort` = 高扇出网优化力度，**会改写 `rst_n` 的复制策略**，
正对第 1 轮两次失败都落在 `rst_n_dup_34` / `rst_n_dup_53` 的现象。

**命令**（cwd = `project/`，复用 run2 的 gate.db）：

```
T7B3_EXTRA = 'place hfn_opt_effort high place crit_path_opt on'
td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/t10_r2_flow.tcl
```

**结果：TD EXIT 0，耗时 238.9 s，全流程 PASS**

完整 PASS 序列（可直接作为审计链）：

```
INFO-T7B3-TAG=rl45_place_hfn_opt_effort_high_place_crit_path_opt_on
INFO-T7B3-RL=45
INFO-T7B3-EXTRA=place hfn_opt_effort high place crit_path_opt on
INFO-T7B3-gate_db=6044558 bytes
PASS-import_device
PASS-open_project
PASS-set_param rtl min_ripple_len 45
PASS-commit_param rtl
PASS-import_db
PASS-set_param place hfn_opt_effort high
PASS-set_param place crit_path_opt on
PASS-commit_param place
PASS-commit_param place (post-import)
PASS-commit_param route (post-import)
PASS-read_adc
PASS-read_sdc
PASS-place                (INFO-place_ms=61536)
PASS-export_place_db
PASS-route                (INFO-route_ms=168436)
PASS-update_timing
PASS-report_timing
PASS-report_area
PASS-check_timing
T7B_SLICES-gate=546 (5.57%)
T7B_SLICES-place=8778 (89.57%)
T7B_SLICES-route=8778 (89.57%)
T7B_BRAM=37/64
T7B_LUT=16868/19600
T7B_TIMING_PASSED: setup=0.109 ns hold=0.019 ns
PASS-bitgen
T7B_BITFILE_OK: D:/FPGA_Compelate/SmartCampusMedia/project/hdmi_td_Runs/phy_1/hdmi_td.bit (648264 bytes)
```

### 10.3.1 参数是否真的生效（任务书要求：不能看 PASS-set_param）

按任务书的判别标准，**看产物变化**：

| 证据 | 路线 2 | 第 1 轮 run2（默认 seed） | 是否变化 |
|------|--------|---------------------------|----------|
| place Setup WNS | **+3,787 ps** | +1,757 ps | **+2,030 ps** ✅ |
| place FMAX | **47.141 MHz** | 43.024 MHz | **+4.1 MHz** ✅ |
| place Hold TNS | **−99** | −121 | −22 ✅ |
| place 违例 H-EP | **9** | 11 | −2 ✅ |
| place Wire length | 793,770 | 796,125 | −2,355 ✅ |
| place `#slices` | 8,778（89.57%） | 8,768（89.47%） | +10 |
| gate.qor | 与 run2 **同 MD5**（B602D053…） | — | 未变（符合预期：gate 不受 place 参数影响） |

⇒ `hfn_opt_effort high` + `crit_path_opt on` **确实生效**：place 阶段 WNS 提升 2,030 ps、
FMAX 提升 4.1 MHz、hold 违例减少 2 个。

### 10.3.2 ★ 为什么这次能布通（机理）

对比三次跑的 hold fix 落点：

| 跑 | hold fix 数量 | 落点 | 是否命中 `rst_n_dup_*` | 结果 |
|----|--------------|------|------------------------|------|
| 第 1 轮 run1（seed7） | 0（未列出） | — | 失败网是 `rst_n_dup_34` | FAIL-route |
| 第 1 轮 run2（默认 seed） | **8** | `rst_n_dup_53`、`u_w24/u_w96_fifo`、`u_rle/ramread0_syn_*`、`u_gallery/u_fat/data_byte[5]`、`u_wav/s_lo[7]` | **是（2 条）** | FAIL-route |
| **路线 2（hfn high）** | **4** | `u_hdmi_core/.../u_w96_d1024_fifo`、`u_hdmi_core/.../u_w24_d1024_fifo`、`u_player/u_loader/fifo_wr_dm[2]`、`u_player/loader_rst_sdr_dup_5` | **否（0 条）** | **PASS-route** |

路线 2 的 4 条 hold fix 全部落在 **HDMI core 内部的 FIFO 数据网**和 **player loader 的局部复位**上，
**没有一条落在全局 `rst_n` 高扇出复制网** —— 这正是 `hfn_opt_effort high` 的作用：
它让 TD 在 place 阶段就重新组织了高扇出复位网，使 route 阶段的 hold fix 不再需要去动 `rst_n_dup_*`，
从而避开了「刚插的 buffer 立刻抢同一走线位」的死结。

**结论：第 1 轮的失败机理判断（"89% 占用下没地方插 hold buffer，且插在 rst_n 复制网上必死"）
被本轮结果证实——不是 setup 时序问题，而是高扇出复位网的布局/缓冲策略问题。**

## 10.4 第 3 步：与基线逐项对比（最终数据）

### 10.4.1 时序对比

| 项目 | 基线（seed7，00:31） | **本轮（路线 2）** | 差值 | 判定 |
|------|---------------------|-------------------|------|------|
| **Setup WNS** | **+113 ps** | **+109 ps** | **−4 ps** | ✅ 仍为正 |
| Setup TNS | 0 | 0 | 0 | ✅ |
| violated S-EP | 0 | **0** | 0 | ✅ |
| **Hold WNS** | **+11 ps** | **+19 ps** | **+8 ps** | ✅ 改善 |
| Hold TNS | 0 | 0 | 0 | ✅ |
| violated H-EP | 0 | **0** | 0 | ✅ |
| Wire length | 1,664,088 | **1,801,952** | **+137,864（+8.3%）** | ⚠️ 变长 |
| STA coverage | 99.84% | **99.85%** | +0.01% | ✅ |
| Confidence | Routed | **Routed** | — | ✅ |
| Check Corner | Both (Slow and Fast) | **Both (Slow and Fast)** | — | ✅ |
| CRPR | Enabled | **Enabled** | — | ✅ |
| Total Endpoints | 15,676 | **16,284** | +608 | — |
| Paths Analyzed | 49,835,382 | **63,627,803** | +27.6% | — |
| 组合环 | — | **0**（`check_timing`） | — | ✅ |

**最差 setup 路径（本轮实测，必须记录）**：

```
Slack          : 0.109 ns
Begin Point    : u_overlay/u_caption/u_narr/addr[9]_syn_191.clk
End Point      : u_axis/video_data_reg[22]_syn_4.b[0]
Data Path Delay: 39.611 ns (cell 12.653 ns 31%, net 26.958 ns 69%)
Logic Level    : 32  (LUT5=16  LUT4=11  LUT2=3  LUT3=2)
Max Fanout     : 145
```

> ★ **重要更正**：任务书预判「最危险的是 t7 在 `image_window_mask` 新增的 `in_image` 交集逻辑」。
> **实测证明这个预判不成立** —— 本轮最差路径的起点是 **`u_overlay/u_caption/u_narr/addr[9]`**
> （中文字幕的 `narr_subline` 字模地址），终点是 `u_axis/video_data_reg[22]`，
> 与 `image_window_mask` 不在同一条路径上。
> 它属于 OSD 字幕链 → AXIS 发送链的组合锥（32 级、net 占 69%，是典型的布线延迟主导路径）。
> 若将来需要改善 setup，**应该动的是这条 narr→axis 路径，不是 mask 的 16bit 比较器**。

### 10.4.2 面积对比

| 资源 | 基线（post-route） | **本轮（post-route）** | 差值 | 占用量 |
|------|-------------------|----------------------|------|--------|
| `#IO` | 43/188 = 22.87% | **43/188 = 22.87%** | 0 | ✅ |
| **`#lut`** | **16,414/19,600 = 83.74%** | **16,868/19,600 = 86.06%** | **+454（+2.32 pt）** | ⚠️ |

> **★ 不可直接归因于 RTL 的提醒（captain 补，回应审查 SUG-1）**：
> 上表「基线」用的是 **TD 默认参数**（`hfn_opt_effort` 取默认 `medium`），
> 而「本轮」为了布通改用了 **`hfn_opt_effort high` + `crit_path_opt on`**
> （`td_r2_hfn.log:202` 有 `*` 标记）。**两轮的布局布线参数不同**，所以：
>
> - `#lut` 的 +454 **不能全部归给 RTL 改动** —— 其中有一部分是 `hfn_opt_effort high`
>   为了重组高扇出网（`rst_n_dup_*`）而多复制的逻辑与缓冲；
> - 同理，**Setup WNS 从 +113 ps 变成 +109 ps 不能解读为「RTL 让时序变差了 4 ps」**。
>   两轮参数不同，这 4 ps 的差异里混着工具策略的影响，方向甚至可能相反。
>
> 若要严格量化 RTL 的时序代价，正确做法是**用同一套 TD 参数**分别跑基线与本轮 RTL
> （代价：每次约 6 分钟，两次共约 12 分钟），本任务未做。
| **`#reg`** | **8,441/19,600 = 43.07%** | **8,709/19,600 = 44.43%** | **+268（+1.36 pt）** | ✅ |
| `#le` | 16,795 | **17,147** | +352 | — |
| `#lut only` | 8,354/16,795 = 49.74% | **8,438/17,147 = 49.21%** | +84 | — |
| `#reg only` | 381/16,795 = 2.27% | **279/17,147 = 1.63%** | −102 | ✅ |
| `#lut&reg` | 8,060/16,795 = 47.99% | **8,430/17,147 = 49.16%** | +370 | — |
| **`#bram`** | **37/64 = 57.81%** | **37/64 = 57.81%** | **0** | ✅ |
| `#bram9k` | 37 | **37** | 0 | ✅ |
| `#fifo9k` | 0 | **0** | 0 | ✅（未退回 LUTRAM） |
| `#bram32k` | 0/16 | **0/16** | 0 | — |
| **`#dsp`** | **24/29 = 82.76%** | **24/29 = 82.76%** | **0** | ✅ |
| `#pad` | 47/188 = 25% | **47/188 = 25%** | 0 | — |
| `#pll` | 2/4 = 50% | **2/4 = 50%** | 0 | — |
| `#gclk` | 4/16 = 25% | **4/16 = 25%** | 0 | — |
| **`#slices`（route）** | **8,591（87.66%）** | **8,778（89.57%）** | **+187（+1.91 pt）** | ⚠️ |

**与「本轮预期增量」的对照**：任务书预期约 **+160 LUT / +512 REG**。

- 实测 **+454 LUT**（预期 2.8×）、**+268 REG**（预期 52%）。
- 这个偏差在第 1 轮 §4.4 已经做过逐实例归因（`u_axis +233` 落在**未改动**的文件上、
  `u_wave` 的 1536 位 hist 只涨 128 flop 等），结论是「**无失控的语义级膨胀**，
  但 LUT 余量确实被吃掉」。
- 本轮叠加 `hfn_opt_effort high` 后，`#lut` 比第 1 轮 gate 阶段的 15,670 又涨到 16,868
  （+1,198）——其中相当部分是 TD 为降低扇出而做的**面积换时序**（`#reg` 也从 8,517 涨到 8,709）。
  **这是可控的、有意的权衡**：用 +454 LUT 换到了布通 + WNS 为正。

### 10.4.3 阶段对比（gate / place / route 三段齐全，这是第 1 轮缺的）

| 阶段 | 指标 | 基线（seed7） | 本轮（路线 2） | 差值 |
|------|------|--------------|---------------|------|
| gate | Setup WNS | −4,917 | **−3,458** | **+1,459** ✅ |
| gate | Setup TNS | −118,949 | **−62,832** | +56,117 ✅ |
| gate | violated S-EP | 39 | **37** | −2 ✅ |
| gate | Hold WNS | +471 | **+471** | 0 |
| gate | `#registers` | 8,210 | **8,461** | +251 |
| gate | `#luts` | 14,155 | **14,549** | +394 |
| gate | `#slices` | 530（5.41%） | **546（5.57%）** | +16 |
| gate | `#lut`（面积报告） | 15,244（77.78%） | **15,670（79.95%）** | +426 |
| gate | `#reg`（面积报告） | 8,298（42.34%） | **8,517（43.45%）** | +219 |
| place | Setup WNS | +1,707 | **+3,787** | **+2,080** ✅ |
| place | FMAX | 42.931 MHz | **47.141 MHz** | +4.21 ✅ |
| place | Hold WNS | −11 | **−11** | 0 |
| place | Hold TNS | −154 | **−99** | +55 ✅ |
| place | violated H-EP | 14 | **9** | −5 ✅ |
| place | Wire length | 719,610 | **793,770** | +74,160 |
| place | `#slices` | 8,591（87.66%） | **8,778（89.57%）** | +187 |
| **route** | **Setup WNS** | **+113** | **+109** | **−4** |
| **route** | **Hold WNS** | **+11** | **+19** | **+8** |
| route | Wire length | 1,664,088 | **1,801,952** | +137,864 |
| route | `#slices` | 8,591（87.66%） | **8,778（89.57%）** | +187 |

> **gate 阶段的数据是本轮与第 1 轮**共享**的（复用同一份 `t7b3_rl45_gate.db`，
> gate.qor 与 gate 面积文件 MD5 完全相同：`B602D053…` / `770ADC8D…`）。
> 因此 gate 行与 place/route 行不是同一次运行产出，但 RTL 与综合参数完全一致，可比。**

## 10.5 三条红线：最终结论

### 红线 ① Setup WNS 必须仍为正 → ✅ **通过（+109 ps）**

- Setup WNS = **+0.109 ns**，**0 违例端点**，Setup TNS = 0。
- Hold WNS = **+0.019 ns**，0 违例端点（比基线的 +0.011 还改善 8 ps）。
- 相对基线 +113 ps 只降了 **4 ps（3.5%）**，余量比例从 0.28% 降到 0.27%。
- **仍是零余量级设计**：SCK 时钟周期 40 ns，余量 0.109 ns 属于「工艺/温度/电压稍有漂移就可能翻转」的量级。
  `ONBOARD_RISK_MAP.md` 早已记录该设计的性质，本轮没有改善也没有恶化本质。
- **最差路径不是 `image_window_mask`**（任务书预判错误），而是
  `u_overlay/u_caption/u_narr/addr[9]` → `u_axis/video_data_reg[22]`（32 级逻辑、net 占 69%）。

### 红线 ② `#bram` 必须仍为 37 → ✅ **通过（37/64）**

- **人工确认是 37，不是 35**：`#bram 37 out of 64 57.81%`、`#bram9k 37`、`#fifo9k 0`、`#bram32k 0/16`。
- `#fifo9k = 0` 是关键：证明 `u_pix_fifo` **没有**退回 LUTRAM
  （若退回，`#lut` 会暴涨到 18,000 量级并吃掉全部余量）。
- `narr_subline` 未被常量传播剪掉（`#bram9k` 仍是 37，与基线一致）。
- gate / place / route 三个阶段都是 37。

### 红线 ③ 位流必须真的更新 → ✅ **通过（MD5 已变）**

| 项目 | 基线 | **本轮** | 判定 |
|------|------|----------|------|
| 路径 | `reports/t7b_bit_v3_seed7_PASS/hdmi_td_v3_seed7.bit` | **`project/hdmi_td_Runs/phy_1/hdmi_td.bit`** | — |
| 大小 | 648,264 B | **648,264 B** | ⚠️ 大小相同（同器件同配置，正常） |
| 时间戳 | 2026-11-03 00:31:47 | **2026-11-03 23:35:55** | ✅ 更新 23 小时 |
| **MD5** | `59A6BACC75613F5E953B7ED5A33E05E8` | **`AA65465E3F41E16C49E5EAE13D0EEC38`** | ✅ **不同** |
| 归档副本 | — | **`reports/t10_r2_verify_build_20261103_PASS/hdmi_td_r2_hfn_AA65465E.bit`** | ✅ |

> **大小相同（648,264 B）不代表内容相同**：这是 TD 对该器件的固定输出尺寸；
> 判定必须用 MD5，实测 MD5 已变 ⇒ **位流确实是用本轮 RTL 重新生成的**。

## 10.6 归档清单（第 2 轮）

归档根：`reports/t10_r2_verify_build_20261103_PASS/`（**未覆盖** `reports/t10_verify_build_20261103_routefail/`
与 `reports/t7b_bit_v3_seed7_PASS/`）

| 文件 | 大小 | 时间戳 | MD5 |
|------|------|--------|-----|
| `hdmi_td_r2_hfn_AA65465E.bit` | 648,264 | 2026-11-03 23:35:55 | `AA65465E3F41E16C49E5EAE13D0EEC38` |
| `run_r2_hfn/route.qor` | 1,313 | 2026-11-03 23:35:45 | `AC31D696889352B1BDA4502F872FB46F` |
| `run_r2_hfn/place.qor` | 1,741 | 2026-11-03 23:35:10 | `2019F012752FF9B01F9F05CDD8C5AC73` |
| `run_r2_hfn/gate.qor` | 7,748 | 2026-11-03 22:35:46 | `B602D0532F4F9D776E1A3595266C5FB3` |
| `run_r2_hfn/area.txt` | 14,088 | 2026-11-03 23:35:52 | `430DBF49C1F3DAA8BA18789D2C661ED9` |
| `run_r2_hfn/timing.txt` | 816,433 | 2026-11-03 23:35:52 | `0C5D9F1BFE2E86F6AD5BCE5ACBE023E7` |
| `run_r2_hfn/coverage.txt` | 53,705 | 2026-11-03 23:35:52 | `554941D45E68597267DC1ECD86D3941F` |
| `run_r2_hfn/gate_area.txt` | 17,035 | 2026-11-03 22:35:47 | `770ADC8D3C775BA213293AF437342B01` |
| `run_r2_hfn/t7b3_rl45_gate.db` | 6,044,558 | 2026-11-03 22:35:47 | `C6CC16642864F05F350D1B376BDB9070` |
| `run_r2_hfn/td_r2_hfn.log` | 213,090 | 2026-11-03 23:35:55 | `4D5581A0357040D2C349404B752CB23F` |
| `regression/summary_attempt1_full.json` | 4,089 | 2026-11-03 22:22:47 | — |
| `regression/driver_console_attempt1.log` | 3,326 | 2026-11-03 22:22:47 | — |
| `regression/storage_result_r2.json` | 7,769 | 2026-11-03 23:21:55 | — |
| `regression/image_result_r2.json` | 4,574 | 2026-11-03 23:23:15 | — |
| `regression/rtl_tb_md5.txt` | 1,277 | 2026-11-03 23:23:49 | — |
| `baseline_ref/{route,place,gate}.qor` | 1,313 / 1,741 / 7,726 | 2026-11-03 00:31:24 / 00:30:33 / 00:13:52 | `8A7559C2…` / `8EC634E5…` / `0CA6AE6F…` |
| `baseline_ref/area.txt` | 25,298 | 2026-11-03 00:31:36 | `B9C70FADDAC0BE70CD1E5C2A80917FF1` |
| `baseline_ref/timing.txt` | 816,497 | 2026-11-03 00:31:36 | `27F19FDD226936A2C8FA5C6B5BAF5439` |
| `baseline_ref/run_seed7.log` | 96,589 | 2026-11-03 00:31:47 | `7954707927FBB39D2810F35199171CD8` |
| `baseline_ref/hdmi_td_v3_seed7.bit` | 648,264 | 2026-11-03 00:31:47 | `59A6BACC75613F5E953B7ED5A33E05E8` |

共 **22** 个文件。仓库外原始工作目录：
- `D:\FPGA_Compelate\_t10_regression_20261103\`（第 1 轮，含两次 FAIL 的完整日志与 db）
- `D:\FPGA_Compelate\_t10_round2_coverage\`（第 2 轮，含 storage/image 回归、路线 1/2 日志、MD5 清单）

**未覆盖确认**：`reports/t7b_bit_v3_seed7_PASS/` 的 9 个文件时间戳仍全部是 2026-11-03 00:xx；
`reports/t10_verify_build_20261103_routefail/` 的 20 个文件时间戳仍全部是 2026-11-03 22:xx。

## 10.7 ★ 第 2 轮的「能证明 / 不能证明」（**上板结论必须读这一节**）

### 能证明

1. **未改动的 11 个 `.v` + 9 个 tb（MD5 逐一比对 diff=0/20）的回归证据有效**：
   七套 7/7、911,909 断言全绿；本轮补跑的两个孤儿 TB 也全绿（storage 5/5、image 4/4）。
2. **本轮 RTL 可以被综合、布局、布线到位流**：TD EXIT 0，`T7B_BITFILE_OK`。
3. **时序签核通过**：Setup WNS +109 ps / 0 违例，Hold WNS +19 ps / 0 违例，STA coverage 99.85%，
   Confidence=Routed，Both (Slow and Fast)，CRPR Enabled。
4. **位流确实是用本轮 RTL 生成的**：MD5 从 `59A6BACC…` 变为 `AA65465E…`，时间戳 23:35:55。
5. **`#bram` 37 未退化、`#fifo9k`=0**：`u_pix_fifo` 没有退回 LUTRAM，`narr_subline` 未被剪掉。
6. **第 1 轮的失败机理被证实并可复现地解决**：`hfn_opt_effort high` 把 hold fix 从
   `rst_n_dup_*` 上挪走（8 条→4 条、命中 rst_n 2 条→0 条），route 即通过。
7. **两个新增 TB 已纳入自动化回归**，以后 t7/t9 的修复不会再无覆盖。

### 不能证明（**必须写进上板结论**）

1. **时序通过 ≠ 上板功能正确**。SWNS +109 ps 只说明「按 TD 的时序模型能收敛」，
   不说明 HDMI 能出图、SD 卡能读、音频能响。
2. **回归通过 ≠ 真卡时序成立**。`tb_display_content` 用的是
   `real image_player RTL; modeled external sector service and behavioral SDRAM`
   （seam 字段原文），SDRAM 与 SD 卡的**真实模拟时序**没有在仿真中验证。
3. **I2C 在 SDC 里是 `set_false_path`**（`dmz_eg4s20_hdmi.sdc:118-121` 四条），
   **SWNS 对 I2C 的物理可靠性零证据**。AHT20 温湿度读取的正确性只能靠上板验证。
4. **余量仍是零余量级**（0.109 ns / 40 ns = 0.27%）。温度、电压、器件批次差异都可能翻转。
   `ONBOARD_RISK_MAP.md` 已记录：setup 可降频兜底（25→24 MHz 即 +1.78 ns），**hold 不能**。
5. **`#lut` 已到 86.06%、`#slices` 89.57%**。下一次任何加逻辑的改动都可能重演布线失败，
   且这次能过是因为 `hfn_opt_effort` 恰好把 hold fix 挪开了——**不是设计有了余量**。
6. **本轮未验证 `-SDRAM_SIM_MODEL` 之外的模型**；`hdl` 级仿真不含布线延迟。
7. **位流大小与基线完全相同（648,264 B）**。这是该器件的固定输出尺寸，
   但意味着「文件大小」不能作为位流内容的判别依据 —— 只能看 MD5。
8. **未做上板**（任务书边界）。用户报的 6 个现象是否真的修好，仍需上板按
   `docs/` 里的上板检查表逐条确认。
9. **`u_axis` 的 +233 LUT 落在本轮未修改的文件上**，属工具映射/跨模块合并的噪声，
   本轮未能归因到具体 RTL 语义 —— 若将来做面积优化，需要单独定位。
10. **本轮 gate 阶段复用了第 1 轮 run2 的 `gate.db`**（6,044,558 B / 22:35:47）。
    该 db 由**同一份 RTL + 同一套综合参数**产出（gate.qor 与 gate 面积文件 MD5 与第 1 轮一致），
    复用合法；但严格意义上「综合」不是本轮重跑的，**若审查方要求全程可视，需再跑一次完整流程
    （约 +125 s）**。

## 10.8 第 2 轮的最终裁决

| 验收项 | 结论 |
|--------|------|
| 七套回归 | ✅ 7/7 全绿（911,909 断言）+ 补齐 2 个孤儿 TB |
| lint / port check | ✅ lint 67 与 133 文件全 0；`NO_SUCH_PORT=0` / `RESULT: PASS` |
| TD 出位流 | ✅ **成功**（路线 2，TD EXIT 0） |
| 红线 ① Setup WNS 为正 | ✅ **+109 ps** |
| 红线 ② `#bram`=37 | ✅ **37/64**（`#fifo9k`=0） |
| 红线 ③ 位流已更新 | ✅ **MD5 `AA65465E…`** |
| 面积是否失控 | ⚠️ `#lut` +454（86.06%）、`#slices` +187（89.57%），**偏高但在预期偏差的解释范围内** |
| 交付边界 | ✅ 未改 RTL/TB 语义、未上板、未 `git commit`、未覆盖 `reports/t7b_bit_v3_seed7_PASS/` |

> **本任务的验收标准已全部满足。可以进入独立审查与上板验证阶段。**
> 上板前请务必让 reviewer 注意到 §10.7 的 10 条「不能证明」，
> 特别是：I2C 无时序证据、零余量、`#lut` 已 86%。

---

*第 2 轮追加：verify-build / t10 attempt 2 / 2026-11-03 23:40*
*本轮改动仅限 `sim/scripts/run_storage_regression.ps1`、`sim/scripts/run_image_regression.ps1`（补覆盖）与新增 `project/t10_r2_flow.tcl`（TD 入口）；未改任何 RTL/TB 语义。*
