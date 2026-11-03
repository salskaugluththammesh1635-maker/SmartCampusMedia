# 全量回归报告（FULL REGRESSION REPORT）

> 任务：t9 / t27（合并）· 执行者：verifier · 日期：2026-11-03
> 环境：ModelSim `D:\Quartus_APP\modelsim_ase\win32aloem` · 厂商原语库 `D:\TD_6_24_APP\sim_release\eg4` · 仓库 `D:\FPGA_Compelate\SmartCampusMedia`
> 证据目录：`reports\plan_v2\_t9_work\`

---

## 摘要（先看这一段）

| 项 | 结果 |
|---|---|
| 全量回归 | **7 套件 / 62 case 全绿**，`FULL REGRESSION PASSED`，exit=0 |
| 断言总数 | **911,481**（改前改后**逐条一致**，未减 1 条） |
| 耗时 | 1,373 s（约 23 分钟） |
| A4 分母断言 | **7 个套件全部落地**，每条 gate 实跑输出见 §2 |
| A1 断言假报 | **四形态全部复现并修好**，自检脚本 `scripts\assert_real_products.py` RESULT: PASS |
| 端口名检查 | `NO_SUCH_PORT = 0`，exit=0 |
| lint | 67 文件，E0/E1/E2 全 0 |
| 待清理失效探针 | **12 个** tb 未挂任何套件（清单见 §5） |
| 上板验收清单 | **35 条**，交付 `docs\plan_v2\BOARD_ACCEPTANCE.md` |
| 未做到的事 | 见 §9「如实说明」 |

---

## 1. 全量回归结果表

命令（改前 / 改后各跑一次，**每次先删除整个 ReportRoot**）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  'D:\FPGA_Compelate\SmartCampusMedia\sim\scripts\run_full_regression.ps1' `
  -ReportRoot 'D:\FPGA_Compelate\reports\plan_v2\_t9_work\full_regression'
```

### 1.1 逐套件

| 套件 | 状态 | exit | 改前耗时 | 改后耗时 | 断言数 | case 数 | A4 gate 实跑输出 |
|---|---|---|---|---|---|---|---|
| unit | **PASSED** | 0 | 641 s | 628 s | 1,224 | **29 / 29** | `A4-GATE: ran=29 passed=29 expected=29` |
| frontend | **PASSED** | 0 | 181 s | 180 s | 56,433 | **21 / 21** | `A4-GATE: ran=21 passed=21 expected=21` |
| storage | **PASSED** | 0 | 5 s | 6 s | 226,012 | **4 / 4** | `A4-GATE: ran=4 passed=4 expected=4` |
| audio | **PASSED** | 0 | 281 s | 272 s | 24 | **2 / 2** | `A4-GATE: ran=2 passed=2 expected=2` |
| startup | **PASSED** | 0 | 3 s | 3 s | 19 | **2 / 2** | `A4-GATE: ran=2 passed=2 expected=2` |
| display | **PASSED** | 0 | 199 s | 185 s | 614,406 | **1 / 1** | `A4-GATE: ran=1 passed=1 expected=1` |
| image | **PASSED** | 0 | 103 s | 100 s | 13,363 | **3 / 3** | `A4-GATE: ran=3 passed=3 expected=3` |
| **合计** | **7/7 PASSED** | 0 | 1,414 s | **1,373 s** | **911,481** | **62 / 62** | **7 条 gate 全部正常输出** |

默认档 = **62 case**（unit 29 + frontend 21 + storage 4 + audio 2 + startup 2 + image 3 + display 1），与契约要求的 62 逐字吻合。
`-FullVga` 全开时为 **67 case**（storage +1 `tb_pix_reader_vga`、image +2 `image_player_full` / `image_player_single`）。

> **⚠️ 与契约的一处不符（如实记录）**：契约写「每 case 独立干净 work 库」，而 `run_full_regression.ps1` 的实际行为是**每个 suite 一个 work 库**（`<suite>\work`），suite 内 case 之间共用。改前改后两次运行的 work 库创建时间分别是 00:41:43 与 08:19:43，都从零建（ReportRoot 先整体删除），因此**不存在跨轮污染**，但**suite 内 case 间不隔离**这一点与契约字面不符。是否要改成每 case 一库，属 t9 之后的工程决策，本报告只如实标注。

### 1.2 unit 29 case 逐条（改前 = 改后）

```
lane_lvds_10_1        22      hdmi_phy              66      video_rgb_to_axis     54
audio_arc             41      video_timing_gen      18      test_pattern_gen     142
audio_waveform        76      audio_tone_gen        46      pcm_to_pwm            39
key_matrix_4x4        50      ax_debounce           31      seg_decoder           51
image_path_probe      54      hdmi_pll              13      sdram_pll             13
dmz_eg4s20_min_top    51      science_font16        49      sdram_frame_diag_top  37
brightness_apply      27      mode_ctrl             48      key_router            30
i2c_master            23      aht20_ctrl            32      thermal_guard         23
fat32_reader          64      gain_direction        13      vol_apply             41
audio_src_mux         24      wav_stream_player     46
```
`knownIssues` 全 0。合计 passLines = 1,224。

**与 t5 基线（`REGRESSION_BASELINE_V2.md`）的差异，三处增加全部有据**：

| case | t5 | 现在 | 差 | 依据 |
|---|---|---|---|---|
| `fat32_reader` | 52 | **64** | +12 | `sim\testbench\tb_fat32_reader.v`（45,389 B / 23:34:05）新增 `T27` 终态可重入（成功→成功，`:898`）与 `T28` 终态可重入（失败→成功，`:943`），即 t26 修复 fat32 终态自锁 bug 的配套用例 |
| `wav_stream_player` | 38 | **46** | +8 | `tb_wav_stream_player.v`（42,333 B / 23:23:29）同步扩写 |
| `gallery_probe` | 37 | **63** | +26 | `tb_gallery_probe.v`（36,927 B / 17:50:01）扩写 |

**断言数只增不减成立。**

### 1.3 frontend 21 case 逐条（改前 = 改后）

```
sd_protocol_default   62      sd_protocol_fast      64      sd_spi_ctrl           23
sd_probe              14      fat32_reader          64      gallery_probe         63
bmp_parser            37      img_loader            53      player_ctrl           94
err_prompt            49      buzzer_tone           23      key_action            42
video_overlay        106      video_content_mux     18      osd_caption           46
osd_param_text        78      osd_panel             63      osd_autopop           38
osd_caption_cjk    54587      narr_subline         895      fade_mixer            14
```
合计 56,433。

**两处数字与 captain 给的基线不一致，均已查清不是退化**：

- **`osd_param_text` 78 vs 98**：78 是回归脚本数的 `PASS:` 行数（`[regex]::Matches($c,'(?m)^\s*#?\s*PASS\b')` = 78、FAIL = 0）；98 是 tb 自己 `pass_cnt` 累加（日志尾部 `# tb_osd_param_text: 98 checks passed, 0 failed` + `# ALL CHECKS PASSED: osd_param_text`）。差异来源：`chk_line` 一次调用覆盖整行像素（26,857→24,624 B / 17:42:32 后 `pass_cnt = pass_cnt + 1` 只在 L192/L217/L252/L418 四处）。**改前改后两轮都是 78，故不是退化，是计数口径差异。**
- **`osd_caption` 46 vs 56**：这是**已知合法下降**。C06（6 条）+ C09（4 条）共 10 条滚动带用例整体迁入 `tb_osd_caption_cjk.v`，C07 一条「两边都空白」的假信心点已删，同时保留 2 条与滚速无关的复位不变量（`C09 reset clears scroll_px` / `scroll_div`）⇒ 56 − 10 − 1 + 1 = 46。**覆盖没减少，是迁移**：滚动带覆盖从「2 个位置抽样 640 点」升到「16 相位数千点 + 六段选 + 应急优先级 + Key5 三带独立门控」，即 `osd_caption_cjk` 的 54,587 项。

### 1.4 storage 4 case（走 `SUMMARY: checks= errors= cases=` 判据）

| case | checks | errors | cases |
|---|---|---|---|
| `tb_async_fifo` | 24 | **0** | 8 |
| `tb_framebuf_arbiter` | 71,023 | **0** | 15 |
| `tb_sdram_ctrl_wrap` | 154,771 | **0** | 12 |
| `tb_pix_reader` | **194** | **0** | **13** |

`tb_pix_reader` 的 **194 / 0 / 13** 与 captain 给的基线**逐字对上**。

> 这一条中途曾经红过：01:20:54 队友 rtl-storage 并行改 `rtl\storage\pix_reader.v` 与 `sim\testbench\tb_pix_reader.v`，我 01:14:54 那次编译撞上中间态（`tb_pix_reader.v(88): (vlog-2730) Undefined variable: 'active_y'`），01:27:28 落定后重跑得到 `checks=275 errors=16 cases=17`。captain 确认 `pix_reader.v` 已复原（24,701 B / MD5 `F498B59EAB01C1A84C29CB0B5F9E29AD`，我实测 match=True）。**我用干净库单独重跑，回到 194/0/13** ⇒ 之前的红是并行漂移，不是基线问题。

### 1.5 audio / startup / image / display

- **audio 2 case**：`hdmi_audio_path` 19 PASS 行、`pwm_audio_out_legacy` 5 PASS 行。
- **startup 2 case**：`startup_ownership` / `startup_ownership_legacy` 均 passed（legacy 走 `EXPECTED LEGACY HANDOFF FAILURE DETECTED` 反向标记）。
- **image 3 case**：`img_scaler` 187、`image_player` 11,365、`image_player_scaled` 1,811，errors 全 0。
- **display 1 case**：`SUMMARY: checks=614406 errors=0 missing=0 mismatched=0 frameIdentical=True`，`ALL CHECKS PASSED: display_content`；`displayed.ppm` 与 `expected.ppm` **哈希相同**。

---

## 2. A4：分母断言（本卡第一优先级）

### 2.1 缺口原状

七个套件**全部**只断言「没有失败」，**没有一个断言「跑够几个 case」**：
`$script:` 出现 0 次、`$fail.Count -eq 0` 形式 0 行、`$ran` 断言 0 行。
三个套件更弱：`run_image_regression.ps1` / `run_display_content.ps1` / `run_startup_ownership_regression.ps1` **靠 `throw` 让进程非零退出**，无 `$failed` 汇总、无 exit 语句。

> 后果：case 表被误删、或筛选条件写错导致一个都没跑，脚本照样打印通过。
> **只断言「失败为空」在「一个都没跑」时也成立，而「一个都没跑」正是最该报警的状态。**

### 2.2 落地方案

每个套件加三条 gate（插在 `$result.status=` / `$manifest.status=` 之前）：

```powershell
if ($script:A4Ran -eq 0) {
    Write-Output ('  A4-GATE: ran=0（一个 case 都没跑却要打印通过，这是最该报警的状态）'); $failed = $true }
if ($script:A4Ran -ne $ExpCaseCount) {
    Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' 与期望 case 数 ' + $ExpCaseCount + ' 不符（case 表被改过？）'); $failed = $true }
if ($script:A4Passed -ne $script:A4Ran) {
    Write-Output ('  A4-GATE: passed=' + $script:A4Passed + ' / ran=' + $script:A4Ran); $failed = $true }
Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' passed=' + $script:A4Passed + ' expected=' + $ExpCaseCount)
```

**期望 case 数是硬编码的，刻意不用 `@($cases).Count`** —— 后者是同源自证：case 表被误删时期望值会跟着一起变小，断言永远成立、永远抓不到。写进每个脚本的注释原文即此。

**计数器用 `$script:` 前缀**：将来若把主循环包进函数，函数里的 `+=` 改的是局部副本，外层判据永远看到 0 → 照样打印 PASS（`scripts\run_tb_baseline.ps1` 头注记着这坑）。

### 2.3 七个套件的期望值来源

| 脚本 | 期望 case 数 | 来源 |
|---|---|---|
| `run_unit_coverage_regression.ps1` | 29 | `$ExpCaseCount = 29` |
| `run_frontend_regression.ps1` | 21 | `$ExpCaseCount = 21` |
| `run_storage_regression.ps1` | `$(if ($Suite -eq 'All') { 4 } else { 1 }) + $(if ($FullVga) { 1 } else { 0 })` | **独立重算，不读 `$tests`** |
| `run_audio_regression.ps1` | 2 | `$ExpCaseCount = 2` |
| `run_startup_ownership_regression.ps1` | 2 | `$ExpCaseCount = 2`（用 `throw`） |
| `run_image_regression.ps1` | `3 + $(if ($FullVga) { 2 } else { 0 })` | 同上 |
| `run_display_content.ps1` | 1 | `$ExpCaseCount = 1`；`-Sweep` 分支另断言 `@($result.sweepCases).Count -eq 0` 时 throw（分母为 0 时 `candidate13Stable` 恒真是假绿） |
| `run_full_regression.ps1` | 7 | `$ExpSuiteCount = 7`（`-Suite` 时按命令行名单数） |

### 2.4 反证：A4 的判据自己也要被证明有效

`reports\plan_v2\_t9_work\refute_a4.py`，基线 sha256 `D6EC9667D1EDF478E1C119034B56C2F6390CCBFD9A2A5E80214CB490FB5EAA70`。

**注入前特征计数**：case 行 = **2**、`$ExpCaseCount = 2` 定义 = **1**。

| 变异 | 注入行 | 注入后计数 | 计数变化 | 脚本判定 | 命中的 gate |
|---|---|---|---|---|---|
| A：清空 case 表 | 52 / 53 | case 行 = **0** | **YES** | exit=1 | `A4-GATE: ran=0（一个 case 都没跑）` |
| B：`$ExpCaseCount` 2→3 | — | 定义 = **0** | **YES** | exit=1 | `A4-GATE: ran=2 与期望 case 数 3 不符` |

- 变异 B 特别有说服力：**两个 case 都 passed 之后才被拦住**，证明它真的在数分母，不是靠"没跑完"顺手报错。
- 恢复后复核 sha256 **逐字节相同（UNCHANGED）**。
- 变异体必须生成在 `sim\scripts\` 下：脚本用 `$PSScriptRoot` 反推 `$root`，放别处会因找不到 rtl/tb 报 vlog 失败，反证就变成"证明另一个东西坏了"。

### 2.5 ★ 落地过程中踩到 A4 自己那类坑（值得单列）

第一版计数器写成 `$script:ran` / `$script:passed`。**脚本作用域下 `$script:x` 就是 `$x` 本身**，而七个套件在循环里用裸 `$passed` 当"本 case 是否通过"的布尔量 ⇒ `$passed = $true` 之后 `$script:passed++` 报：

```
The '++' operator works only on numbers. The operand is a 'System.Boolean'.
```

`run_storage_regression.ps1` 实跑立刻 `STORAGE_EXIT=1`。

**「加分母断言」这件事本身踩进了它想防的那类坑：判据写错时表现为噪声，而不是表现为"判据坏了"。**
修法：全部改名 `$script:A4Ran` / `$script:A4Passed`（unit 23 处 / frontend 19 / storage 19 / audio 19 / startup 17 / image 19 / display 20 / full 15）。

### 2.6 改后全量复跑：断言数只增不减

**62 case 逐条数字与改前完全一致，asserts 总量 911,481 不变。** 逐套件对比脚本比对 `result.json` 的 `tests[]` 序列，输出「unit 29 case 逐条数字完全一致 / frontend 21 / storage 4 / audio 2 / image 3」；startup 无 `tests[]`（靠 PASS 行），其 console 输出 `startup_ownership: passed` / `startup_ownership_legacy: passed` 与改前相同，另加一条 `A4-GATE: ran=2 passed=2 expected=2`。

---

## 3. A1：断言假报的四个形态（全部复现并修好）

`project\t7b_assert_only.tcl` 的动因：2026-11-02 23:28 那轮 route 后**时序已过**（SWNS +0.113 / HWNS +0.012 / 0 违例端点），却因 `#bram` 正则要求 `N / M` 而实测格式是 `N out of M`，断言假报 `T7B_AREA_NO_BRAM` 并 exit 15，**在 bitgen 前把流程掐了**。

### 3.1 四形态与复现证据

| # | 形态 | 现象 | 复现证据 |
|---|---|---|---|
| ① | **格式漂移** | 正则写 `#bram\s+(\d+)\s*/\s*(\d+)`，TD 实吐 `#bram                      37   out of     64   57.81%` | 对 `reports\t7b_seed_seed7_area.txt` 实测：旧正则 `success=False`，新正则 `success=True, 37/64` |
| ② | **运行时加载旧版脚本** | 磁盘版 tcl 的 mtime 晚于该趟运行的启动时刻 ⇒ 跑的是旧脚本 | 见 `run_unit_coverage_regression.ps1` 头注 `:43-49` 的 ASCII-only 说明（**该头注已过期**，文件当前 BOM=True —— 文档与现实不符，本身也是盲区） |
| ③ | **读错文件** | `#slices` **不在**面积报告里，只在 `gate.qor` / `place.qor` / `route.qor` 的 `\| #slices \| N \|` | 对 `t7b_seed_seed7_area.txt` 与 `t7b3_rl45_area.txt` 实测 **`slices` 命中 0 行** |
| ④ | **报告被后续运行覆盖** | `reports\t7b3_rl45_area.txt` 被 attA 覆盖成 `#lut 16,400`，而最终位流是 `t7b_seed_seed7_area.txt` 的 `16,414`，**差 14** | 两份文件 mtime 差 11 分 09 秒（00:20:27 vs 00:31:36） |

### 3.2 报告溯源表（凡引用数值必须带 mtime）

| 文件 | 字节 | mtime | sha16 | 备注 |
|---|---|---|---|---|
| `reports\t7b_seed_seed7_area.txt` | 25,298 | **2026-11-03 00:31:36** | `04ED03A93052530A` | **最终位流对应** |
| `reports\t7b_seed_seed7_timing.txt` | 816,497 | 00:31:36 | `99D3BCEA43254559` | 最终位流对应 |
| `reports\t7b3_rl45_area.txt` | 25,852 | 00:20:27 | `FA8C7BA7F717BD20` | **已被覆盖，不得引用** |
| `reports\t7b3_rl45_timing.txt` | 825,359 | 00:20:27 | `8801B48D7BB0C581` | SWNS −0.194 那份（失败轮） |
| `reports\t7b3_rl45_gate_area.txt` | 17,035 | 00:13:54 | `3B17BFA92B269240` | gate 阶段 |
| `reports\hdmi_area.txt` | 25,308 | 2026-11-02 20:11:06 | `7DDE0829D51B1005` | 更旧 |
| `project\route.qor` | 1,313 | 00:31:24 | `EF74CB3924D3093A` | 最终 |
| `project\place.qor` | 1,741 | 00:30:33 | `C9AF10E6E0F6FFD9` | 最终 |
| `project\gate.qor` | 7,726 | 00:13:52 | `8E1A9346315D0BBA` | 最终 |

**会被下次运行覆盖的文件**（引用前必须核 mtime）：`reports\t7b3_rl45_*.txt`、`reports\hdmi_area.txt`、`project\gate.qor`、`project\place.qor`、`project\route.qor`、以及 `project\hdmi_td_Runs\phy_1\` 下的全部产物。

### 3.3 自检脚本 `scripts\assert_real_products.py`

设计：**只读真实产物，不 import_device / 不 open_project / 不碰 .al / 不碰 .v**，5 秒出结果。红了一定意味着断言逻辑或产物有问题，不会被 13 分钟的 TD 流程搅混。

正则与 `project\t7b_assert_only.tcl` 的 `check_area` / `check_timing` / `check_qor` 逐条对应：

```python
RE_BRAM  = re.compile(r'#bram\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)')   # ①格式漂移已兼容
RE_LUT   = re.compile(r'#lut\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)')
RE_SLICES_AREA = re.compile(r'#slices\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)\s*\(\s*([0-9.]+)%\s*\)')
RE_SLICES_QOR  = re.compile(r'\|\s*#slices\s*\|\s*([0-9]+)\s*\|')        # ③只在 qor 里
RE_SWNS  = re.compile(r'SWNS:\s+(-?[0-9.]+)ns,\s*STNS:')
RE_HWNS  = re.compile(r'HWNS:\s+(-?[0-9.]+)ns,\s*HTNS:')
```

**实跑结果（RESULT: PASS，exit=0）**：

```
=== 判据对真实产物（只读文件，不跑 TD） ===
  [PASS] area   seed7   {'bram': (37, 64), 'lut': (16414, 19600)}  (25298 B, 2026-11-03 00:31:36)
        INFO AREA_NO_SLICES（面积报告不含 #slices，这是正常的；去 .qor 读）
  [PASS] timing seed7   {'swns': 0.113, 'hwns': 0.011}  (816497 B, 2026-11-03 00:31:36)
  [PASS] qor    route   {'slices': 8591, 'slices_pct': 87.66}  (1313 B, 2026-11-03 00:31:24)
  [PASS] qor    place   {'slices': 8591, 'slices_pct': 87.66}  (1741 B, 2026-11-03 00:30:33)
```

**六条自带反证（判据自身有效性的证明）**：

| # | 反证内容 | 期望报错 | 结果 |
|---|---|---|---|
| A1-1 | 格式漂移：`#bram 37 of 64` | `AREA_NO_BRAM` | **PASS** |
| A1-2 | BRAM 回退：bram=17 | `BRAM_REGRESSED` | **PASS** |
| A1-3 | LUT 超限：lut=20000 | `LUT_OVER` | **PASS** |
| A1-4 | setup 违例：SWNS=−0.194 | `TIMING_SWNS_NEG` | **PASS** |
| A1-5 | hold 违例：HWNS=−0.011 | `TIMING_HWNS_NEG` | **PASS** |
| A1-6 | qor 缺 `#slices` 行 | `QOR_NO_SLICES` | **PASS** |

> 第一次跑时**六条反证全 PASS、真实产物四条全 FAIL** —— 原因是 `ROOT` 算错一层（`'..','..'` 指向 `D:\FPGA_Compelate\`，实际 `reports/` 与 `project/` 在 `D:\FPGA_Compelate\SmartCampusMedia\` 下）。修正后四条真实产物全 PASS。**这个中间态本身也是 A1 的一个实例：判据逻辑对、路径错，表现成"产物有问题"。**

---

## 4. 六条工具盲区：本次如何确认它们没骗我们

| # | 盲区 | 本次确认方式 | 结论 |
|---|---|---|---|
| ① | `lint_verilog.py` 只查 always 块级 E2，查不到 `assign` 级多驱动与重复声明 | **构造反例实测**：写 `assign y = a; assign y = b;`（assign 级多驱动）+ `wire t; wire t;`（重复声明），跑 lint → **E0/E1/E2 全 0、结论「通过」、exit=0**；同一对文件跑 vlog → **VLOG_EXIT=2**，报 `dup_decl.v(3): 't' already declared in this scope` | ✅ 盲区确认存在：**lint 全 0 不等于能编译**，更不等于功能对。真实 67 文件 lint 全 0（`检查文件数: 67 / E0 0 / E1 0 / E2 0 / 结论: 通过`，exit=0）**只能说明无损坏、无赋值混用、无 always 级多驱动** |
| ② | `vsim` 不带 `-do "run -all"` 会停在 `VSIM 1>`、零输出、退出码仍 0 | 七个套件的 vsim 调用**全部**带 `-do 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0'`；本次 62 case 全部有实际 PASS 行与 SUMMARY，**没有一个 case 出现「零输出但 exit=0」** | ✅ 本仓脚本已正确，无需修 |
| ③ | `vlog` 与 TD elaborate 都不报「命名端口不存在」，只在 vsim elaborate 报 `vsim-3063` | 跑 `scripts\check_port_names.py`：`modules parsed: 69 / instantiations scanned: 40`，**`NO_SUCH_PORT = 0`**，`UNKNOWN_MODULE = 2`（预期 2：`EG_PHY_SDRAM_2M_32 u_sdram_sip` + `hdmi_1_4b_transmitter_core_wrapper u_hdmi_core`，**意外 0**），`UNCONNECTED = 0`（意外 0），`EMPTY_CONN = 9 实例 / 22 端口`（有意 9、**意外 0**），self-check 15 条全 OK，**EXIT=0** | ✅ **NO_SUCH_PORT=0 是唯一硬判据，已通过**。`image_player u_player` 的 `out_w/out_h/out_off_x/out_off_y` 四条确在 `EXPECTED_EMPTY` 白名单（`check_port_names.py:256-261`，理由：Key9 改由 `ratio_map` 驱动后 `img_scaler` 四缩放结果本层无消费者） |
| ④ | tb 的 task 内循环变量与外层同名 → 外层循环提前终止、断言静默少跑 | 复核 `tb_osd_param_text.v`：`:87-89 integer pass_cnt; fail_cnt; i;`（全局）、`:122` `exp_len` 内 `integer k;`、`:154` `show_line` 内 `integer k;`、`:180` `chk_line` 内 `integer k;`、`:238` `chk_range_blank` 内 `integer k;` | ✅ **bug 已修**（各 task 用局部 `k`，全局 `i` 只在主流程 for 用），98 是真绿。注意回归脚本数到的是 78（`PASS:` 行），两者口径不同 |
| ⑤ | `.port()` 空括号被旧版 `check_port_names` 判成「已接」 | 同上第③项：`EMPTY_CONN = 9 实例 / 22 端口（有意 9；意外 0）`，白名单逐条列在 §4 输出里 | ✅ 现有 `EXPECTED_EMPTY` 白名单机制有效 |
| ⑥ | ★ **反证方法本身可能失效**（变异没真正注入，却报「计数没变」） | 跑 `scripts\_t7b_audit_refute.py`（对 `scripts\_t7b_static_audit.py` 自己做反证）：四条变异 A/B/C/D，每条都打印**注入前行号 / 注入前特征计数 / 注入后特征计数 / 计数确实变化 YES / 审计判定**；**匹配 0 行时打「变异无法注入」+「反证不成立（不是审计脚本漏判，是反证工具自己没注入）」并 continue**，恢复后复核计数回到基线 | ✅ **RESULT: PASS 四条反证全部成立，文件已完整恢复**（exit=0）。本条对应 A2③，`refute_a4.py` 与本脚本共用同一纪律：**必须同时给注入前后两个计数** |

### 4.1 补充：A5「参数化完成」的两步法实测

判据不是「旧数字搜不到了」，而是「**改参数必须变红、改回来必须变绿**」。用 `tb_video_overlay` + `osd_caption.v` 做三步：

| 步 | 改动 | 特征计数 | PASS / FAIL | 结论 |
|---|---|---|---|---|
| 基线 | 无 | — | **106 / 0** | 绿 |
| ① 只改 tb（`chk(n_hit > 100)` → `> 101`） | tb 单侧 | before=1, after=1 | **106 / 0** | ✅ 旧 RTL 下数字**一字不变**，证明 tb 改动没引入额外断言 |
| ② 改 RTL 参数（`TICKER_Y1` 463 → **400**） | RTL 单侧 | before=1, after=1 | **105 / 1** | ✅ **变红**，红条命中 `FAIL: V13 ticker band draws scrolling text` |
| ③ 改回原始 RTL | — | — | **106 / 0** | ✅ **变绿** |

**★ 意外发现（新盲区，建议入册）**：第②步最初把 `TICKER_Y1` 从 463 改成 **462**（只差 1 行），结果是 **106 / 0 全绿，抓不到**；改成 400 才变红。
⇒ **参数变异的幅度必须大于断言的观测窗口，否则「改了参数却没变红」会被误判成「参数化已失效」。** 这与 D 类「默认档恰好等于没测」同族：**小幅度变异等价于没变异。**

### 4.2 A3：假红与假绿并列

`tb_wav_stream_player.v:657` 的 `NAME_NARR` 曾写 12 字节而 `reg [87:0]` 只装 11 字节，超宽字面量截掉最高字节 `'V'` ⇒ 那条用例**从来没真正测过 NARR**。当前实测已修好：

```verilog
NAME_BGM  = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20, 8'h4D, 8'h47, 8'h42};  // 11 字节 "WAV     BGM"
NAME_NARR = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20, 8'h20, 8'h52, 8'h52, 8'h41, 8'h4E};  // 11 字节 "WAV     NARR"
```

**潜伏成因是「一直在红」而不是「一直在绿」** —— 假绿至少被人当好消息审视过；假红会被人当「已知问题」长期挂着，那段时间证明力全为零。

---

## 5. 待清理失效探针清单（12 个）

用 `sim\testbench\*.v` 全集与七个 `run_*.ps1` 的 `$sources` 做集合差，以下 12 个 tb **不被任何回归套件引用**：

| tb | 字节 | mtime | 性质 | 建议 |
|---|---|---|---|---|
| `tb_probe_burst.v` | 5,021 | 2026-10-19 13:03 | 头注自述「一次性诊断探针，不属于交付测试集，验证后可删」 | **可删** |
| `tb_probe_order.v` | 11,917 | 2026-11-02 18:18 | 同上；引用 `pix_reader` 已改名的内部信号 | **可删** |
| `tb_probe_pix.v` | 10,104 | 2026-11-02 18:19 | 同上 | **可删** |
| `tb_dbg_scaler.v` | 3,851 | 2026-10-29 22:52 | 头注「img_scaler 行相位临时诊断」 | **可删** |
| `tb_framebuf_realcore_concurrent.v` | 4,987 | 2026-10-31 22:51 | 「Focused real-core stress」 | 保留（真核压测，需 Questa） |
| `tb_image_window_mask.v` | 4,962 | 2026-10-30 00:08 | 独立单测，未挂套件 | 建议挂进 unit 套件 |
| `tb_seg_scan4.v` | 4,758 | 2026-10-06 21:46 | 独立单测，未挂套件 | 建议挂进 unit 套件 |
| `tb_dmz_eg4s20_bringup.v` | 11,676 | 2026-10-14 19:37 | `run_sim.bat` 跑它（非 ps1） | 保留 |
| `tb_fifo_fwft.v` | 24,292 | 2026-11-02 22:46 | 被 `scripts\run_tb_baseline.ps1` 引用 | 保留 |
| `tb_rle_decoder.v` | 38,727 | 2026-11-02 15:17 | **唯一使用相对 vector 路径 `../testbench/vectors/`**，全仓库 ps1/bat/do/md/tcl grep **零命中**，完全游离 | 建议挂进 unit 套件（它是唯一覆盖 `rle_decoder` 的 tb） |
| `tb_science_page.v` | 3,725 | 2026-10-29 20:36 | 仅出现在 `run_frontend_regression.ps1` 注释里，case 已摘除（t16 裁定 `science_page` 废弃） | **可删**（连同 `rtl\video\science_page.v` / `science_font16.v`，删不删归 t11） |
| `prim_sim_stub.v` | 3,788 | 2026-10-31 14:27 | 只定义 `EG_LOGIC_ODDR` / `EG_LOGIC_BUFG` / `EG_LOGIC_INV` 三个空壳，全树无引用 | **可删**（仿真走 TD 厂商库，不用它） |

> **不要为这些 tb 改 tb** —— 它们的红/绿都不在回归口径内。清单只做记录与建议。

---

## 6. 三条「分析对了、实现错了」的实例

三条同族，**分析层面的正确性不自动传递到实现层面**。

### 6.1 同一 `always` 块内状态互相依赖造成自相矛盾（t22）

t22 v1 里 `win_start_now` 依赖 `take_cnt == 0`，而 `take_cnt` **恰好也在同一个 always 块被清零** ⇒ 条件永远不成立。仿真能跑、逻辑读起来对、lint 与综合都不报错，只是**某条件永不成立**。

修法：首字判据改成 `win_row && h_pop && (take_cnt == 0)`，把清零挪到 `!de` 分支。

> 与「`$fail +=` 在 PowerShell 函数作用域失效」同族：**都是"看起来在改状态，实际改的是另一个东西"**。

### 6.2 帧平均守恒 ≠ 单行可实现（t22）

配额算法**帧平均完全正确**：一帧总和恒 153,600、`rem_mod` 序列正确、末态 `acc` 归零。但单行瞬时取字率是基线的 **2 倍**，FIFO 跟不上。

> **凡是「总量 / 平均值 / 守恒」类断言，必须同时给出「峰值 / 单周期 / 单行」类断言。**

### 6.3 判对的条目数 ≠ 可见的后果（t24）

`t_line[2]` 判错 177 / 373（47.5%），但：
- `line 4..7` 那 24 条判反像素**完全不变**（`ascii_px` 只取 `rep_data[5:0]`，低 6 位恒等）；
- `line 8..11` 那 153 条判反导致滚动字幕**整条熄灭**（不是错字母）。

真实症状 = **只坏一条滚动带、静态三带全对**，比「满屏乱字」隐蔽得多。**中间隔着一层数据通路消费方式。**

### 6.4 附：不清 `found` 就采到上一轮的 1（t26）

`out_data_begin` 两轮相同，用它区分不出新旧 —— 判据变量本身没有区分力。

> 这一条还派生出 §5 之外的一条**上板判据纪律**：`err_code` 全程 0 **不代表功能对**。fat32 终态自锁的真实症状是静默重播上一个文件，用户只感知「切了模式但音乐没变」。

---

## 7. 校验类判据的前置条件（captain 新增，本次采纳）

**核验他人交付物前，先确认工作树静止。**

检查清单：

1. 目标文件 mtime 是否在最近几分钟内（还在被改？）；
2. 是否有 `patch_*.py` / `fix_*.py` 在跑；
3. `sim\work_t*\` 下是否同时存在 `*_orig.v` 备份。

否则量到的是**中间态或备份**，而**中间态和备份在输出上和真值长得一模一样** —— 你没法从数值本身分辨自己量的是哪一份。这与「0 命中 vs 0 个文件」「分母必须报」是同一族。

**本次实例（我自己踩的）**：01:14:54 编译撞上 `pix_reader.v` 的中间态（`active_y` 未定义 / 重复声明），如果当时直接判定「tb_pix_reader 退化了」，就会把一个并行漂移写成回归缺陷。后来用干净库重跑回到 194/0/13。

---

## 8. 文档合规扫描：结论必须在写完当刻复跑

captain 踩的坑：用「安全功能」当示例词写进工程纪律文档，而它正是自验命令 B 的禁词之一 ⇒ 命令 B 从 1 行变 4 行（多出的 3 行全是那段代码块）。

**通用规则：反证 / 对照实验的示例词必须选不在自验禁词表内的串，否则报告本身会变成白名单污染源。**
更麻烦的一层：这类污染**只在写完之后才出现**，所以「改前 A=0 / B=1」的自验结论在「改后」就失效。**t9 若做任何文档合规扫描，扫描结论必须在写完当刻复跑一次，不能引用写入前的结论。**

---

## 9. 如实说明：本卡没做到 / 有偏差的事

| # | 项 | 状态 |
|---|---|---|
| 1 | 契约要求「**每 case 独立干净 work 库**」 | **未达成**。`run_full_regression.ps1` 实际是每 suite 一库（`<suite>\work`），suite 内 case 共用。改前改后两轮都从零建库、无跨轮污染，但 suite 内不隔离。改造成每 case 一库属工程决策，未在本卡范围内动。 |
| 2 | A2 的三种伪装 | **部分覆盖**：①激励没走到（`tb_fifo_fwft` 的 S4 已加，非本卡改动）②断言没执行（`tb_osd_param_text` 的 `k` 已修，非本卡改动）③缺陷没注入（`_t7b_audit_refute.py` 实跑 RESULT: PASS，见 §4⑥）。**本卡未新增 A2 的反证，只复核了既有实现。** |
| 3 | A5 参数化两步法 | **已完成**（§4.1 三步实测），但只对 `tb_video_overlay` + `osd_caption.v` 一对做，**未对全部 62 case 逐对验证**。 |
| 4 | `run_display_content.ps1` 的 `-Sweep` 分支 | 加了「sweep 扫到 0 个 gap 必须 throw」的 gate，但**本次未跑 `-Sweep` 模式**（默认主路径已跑）。 |
| 5 | `scripts\resolve_tb_deps.py` 的白名单缺口 | **发现未修**：`EG_PHY_SDRAM_2M_32` 不在 `KNOWN_UNRESOLVED` 里，导致 `tb_sdram_frame_diag_top` 的闭包解析报「意外未解析 1 个」→ `RESULT: FAIL`。该模块由厂商库 `D:\TD_6_24_APP\sim_release\eg4\eg_phy_sdram_2m_32.v` 提供，**属预期**。修它需改 `scripts\resolve_tb_deps.py`（在 t27 inScope 内），但本卡未改 —— **留给后续**。 |
| 6 | `run_unit_coverage_regression.ps1` 头注 `:43-49` | **文档与现实不符**：头注明写「本文件存为 UTF-8 无 BOM」，实测当前 **BOM=True**（t14 期间补过）。未改，只记录。 |
| 7 | 上板验证 | **一条都没跑**（板子未上电）。`BOARD_ACCEPTANCE.md` 全部条目为「已接线·未上板验证」，无一条写「已通过」。 |
| 8 | `docs\plan_v2\KEY9_RULING.md` | **文件不存在**（t28 未交付）。`BOARD_ACCEPTANCE.md` §0.2 按 captain 给的逐字口径写，并注明「若尚未落盘则以本节为准」。**定稿后需核对引文是否逐字一致。** |
| 9 | Key9 档位比口径 | captain 消息写「1/2、5/8、3/4、7/8、1（边长比）」，`ratio_map.v:86-129` 实测窗口 320×240 / 400×300 / 480×360 / 560×420 / 640×480 ⇒ **两者一致**（面积比 1/4、5/12、9/16、3/4、1 对应边长比 1/2、5/8、3/4、7/8、1）。已在 `BOARD_ACCEPTANCE.md` §0.2 标注这处换算。 |

---

## 10. 复现命令

```powershell
# 1) 全量回归（约 23 分钟）
$rep='D:\FPGA_Compelate\reports\plan_v2\_t9_work\full_regression'
if (Test-Path $rep) { Remove-Item -Recurse -Force $rep }
powershell -NoProfile -ExecutionPolicy Bypass -File `
  'D:\FPGA_Compelate\SmartCampusMedia\sim\scripts\run_full_regression.ps1' -ReportRoot $rep

# 2) A1 断言自检（5 秒，不跑 TD）
cd D:\FPGA_Compelate\SmartCampusMedia
$env:PYTHONIOENCODING='utf-8'
python scripts\assert_real_products.py          # 期望 RESULT: PASS, exit 0

# 3) 端口名检查（0 秒）
python scripts\check_port_names.py              # 期望 NO_SUCH_PORT = 0, exit 0

# 4) A2③ 反证工具自证
python scripts\_t7b_audit_refute.py             # 期望 RESULT: PASS, exit 0

# 5) lint
python scripts\lint_verilog.py rtl              # 期望 67 文件, E0/E1/E2 全 0, exit 0

# 6) A4 反证
python D:\FPGA_Compelate\reports\plan_v2\_t9_work\refute_a4.py   # 期望 RESULT: PASS
```

---

## 11. 改动清单

| 文件 | 改动 | 字节（改后） |
|---|---|---|
| `sim\scripts\run_unit_coverage_regression.ps1` | +A4 gate（29） | 22,555 |
| `sim\scripts\run_frontend_regression.ps1` | +A4 gate（21） | 17,614 |
| `sim\scripts\run_storage_regression.ps1` | +A4 gate（4/1 + FullVga） | 8,484 |
| `sim\scripts\run_audio_regression.ps1` | +A4 gate（2） | 6,917 |
| `sim\scripts\run_startup_ownership_regression.ps1` | +A4 gate（2，throw 形式）+ `$failed` | 4,160 |
| `sim\scripts\run_image_regression.ps1` | +A4 gate（3+FullVga） | 6,222 |
| `sim\scripts\run_display_content.ps1` | +A4 gate（1）+ Sweep 分母断言 | 16,921 |
| `sim\scripts\run_full_regression.ps1` | +`$ExpSuiteCount = 7`；title `18`→`29` | 14,997 |
| `scripts\assert_real_products.py` | **新建**（A1 自检 + 六条反证） | — |
| `reports\plan_v2\_t9_work\patch_a4_gate*.py` / `rename_a4_counters.py` / `refute_a4.py` | **新建**（补丁器与反证工具） | — |
| `docs\plan_v2\BOARD_ACCEPTANCE.md` | **新建**（35 条上板验收） | — |
| `reports\plan_v2\FULL_REGRESSION_REPORT.md` | **新建**（本文件） | — |

**所有 .ps1 改动后均复核**：`bom=True`、`ParseFile` 错误数 0、行尾保持原样（frontend / storage 是 CRLF，其余 LF）。

> 用 Python 补丁器而非 `edit` 工具的两个原因：①`edit` 会把 UTF-8 BOM 丢掉（实测改完前 3 字节变 `23 20 3D`，ParseFile 立刻报假语法错「The Try statement is missing its Catch or Finally block」/「Unexpected token '}'」）；②本仓行尾不统一，混着改会整文件翻行尾、diff 变「整个文件都改了」。
> 补丁器核心纪律 `must_replace()`：`if n != 1: raise SystemExit('PATCH-ABORT: %s 期望匹配 1 次，实际 %d 次')` —— **匹配 0 次绝不默默跳过**。

---

## 12. 证据目录

`D:\FPGA_Compelate\reports\plan_v2\_t9_work\`

| 子目录 / 文件 | 内容 |
|---|---|
| `full_regression\` | 改前全量回归（7 套件 / 62 case / 1,414 s） |
| `full_regression_after\` | 改后全量回归（7 套件 / 62 case / 1,373 s，含 7 条 A4-GATE） |
| `baseline_before_full_regression.txt` | 改前 summary 摘录（3,256 B） |
| `probe_sfd\` | `sdram_frame_diag_top` 单独复现（验证 9 分钟耗时、非卡死） |
| `pix_reader_clean\` | `tb_pix_reader` 干净库重跑 → 194/0/13 |
| `a5_param\` | A5 三步法（tb 变异 / RTL 变异 462 / RTL 变异 400 / 原始恢复） |
| `lint_blind\` | lint 盲区反例（`assign_multi_drive.v` / `dup_decl.v`） |
| `patch_a4_gate.py` / `patch_a4_gate_display.py` / `patch_a4_gate_full.py` | A4 补丁器 |
| `rename_a4_counters.py` | `$script:ran` → `$script:A4Ran` 改名器 |
| `refute_a4.py` | A4 反证（双计数） |
| `a5_mut.py` / `a5_mut_rtl.py` / `a5_mut_rtl2.py` | A5 变异器 |
