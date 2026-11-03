# t8 集成前回归基线快照（REGRESSION_BASELINE_V2）

| 项 | 值 |
|---|---|
| 任务 | t5 —— t8 集成前的回归基线快照（只读 RTL，只写本报告） |
| 采样时间 | 2026-11-02 12:24 ~ 12:58（+08:00） |
| 仓库根 | `D:\FPGA_Compelate\SmartCampusMedia` |
| 报告路径 | `D:\FPGA_Compelate\reports\plan_v2\REGRESSION_BASELINE_V2.md` |
| git HEAD | `7163c66`（工作区未提交变更 175 项 —— 基线以文件树指纹为准，不以 commit 为准） |
| 结论 | **基线成立**：61 个既有 case + 3 个 t7 定向 case 全绿（0 失败），lint 0 错，综合/时序基线唯一有效目录已锁定 |

> **重要前提：本仓库有队友并行写入。** 采样期间 `rtl/` 的 `.v` 文件数从 61（12:24）→ 62（12:36）→ 64（12:51）→ 65（12:54）持续变化。因此下面每一项基线都带**时间戳 + 文件树指纹**。任何人复跑对比时，若文件树指纹不同，差异不能直接归因于 t8，必须先扣除队友的并发改动。

---

## 0. 文件树指纹（唯一可复现的"基线身份"）

指纹算法：对该目录下所有 `.v` 递归取 `相对路径:SHA256(小写)` 行，按字符串排序后用换行拼接，再取 SHA256。

| 方向 | 文件数 | 字节数 | 树指纹（SHA256） | 采样时刻 |
|---|---:|---:|---|---|
| `rtl/` | **65** | 978,175 | `83d954c70e5df5aa7d1ebbf0c82b3ef498e8d34d0094a9c123ce343ab99fcdb2` | 12:53:34 |
| `project\hdmi\` | **46** | 1,020,422 | `69559e6ce38aca8ed11aa1eefde6e21b8b1d392a871bbd76b53170a2e77386f7` | 12:53:34 |
| `project\src\` | 5 | 71,234 | `a1312e7194caff7c758a6a2a6eb28eb95acb4b48e09ff30cc7835d46994bebe8` | 12:53:34 |
| `sim\testbench\` | **75** | 1,219,821 | `9f5132cc14de752c155f67054c6f91ef277a5949b63121ce44a5fc1e36ca0f4a` | 12:53:34 |
| `ip\` | 7 | 403,267 | `dc05f0aa2ac0d4b5130f9ac93ce3c90a71a0f48f5d7373e5cb72a1d7c62af9f1` | 12:53:34 |

> 指纹只覆盖 `.v`。`.hex` 等数据文件不在指纹内，单独在 5.2 节比对（`cjk16_bitmap.hex` 37,200 B / SHA256 `F57337590BF0A3BF3892FA67AF6669C36DA19247B5A8B0870D3A813A5379C02B`）。

**回归运行时实际被测的树**（比上面更早，是仿真真正跑的时候的快照）：

| 目录 | 文件数 | 字节数 | 树指纹 | 采样时刻 |
|---|---:|---:|---|---|
| `rtl/` | 64 | 972,296 | `b83ba753fce7093066954d45e355158dbb4b7acf08b01ac373c3ca223e412d4e` | 12:51:06 |
| `sim\testbench\` | 75 | 1,219,821 | `9f5132cc14de752c155f67054c6f91ef277a5949b63121ce44a5fc1e36ca0f4a` | 12:51:06 |

两者差异只来自 12:53:10 新增的 `rtl\osd\cjk16_font.v`（5,879 B，尚未被任何模块例化）。**它不影响 61 个 case 的任何结果**（已 grep 确认 `cjk16_font` 仅在自身文件内出现）。

采样期间 rtl 的 4 个新增件（均为队友 t7/t21 产出）：

| 文件 | 时间 | 大小 | 有无 tb | 是否已进 7 套件 |
|---|---|---:|---|---|
| `rtl\video\emerg_page.v` | 12:36:34 | 6,427 B | `tb_emerg_page.v`（12:39:28） | 否（走 t7 自己的 `run_t2_emerg.ps1`） |
| `rtl\video\pix_mosaic.v` | 12:44:54 | 8,429 B | `tb_pix_mosaic.v`（12:43:39） | 否（走 `run_t1_geom.ps1`） |
| `rtl\video\ratio_map.v` | 12:45:25 | 6,799 B | 无（被 pix_mosaic 的 tb 一起编译） | 否 |
| `rtl\osd\cjk16_font.v` | 12:53:10 | 5,879 B | 无 | 否 |

---

## 1. 基线表 A —— 仿真回归（61 个 case，实际复跑）

### 1.1 怎么跑的（可复现命令）

**核心纪律：每个套件一个全新的 `-ReportDir`。** 7 个套件脚本内部都是 `if (-not (Test-Path work)) { vlib work }`，即**复用已存在的 work 库**；给同一个 ReportDir 重跑会命中上一次的编译产物，跑出与 RTL 无关的假失败/假通过。因此每条命令前先删目录：

```powershell
$root='D:\FPGA_Compelate\SmartCampusMedia'
$base='D:\FPGA_Compelate\reports\plan_v2\_t5_work\suite_unit'
if(Test-Path $base){ Remove-Item -Recurse -Force $base }
New-Item -ItemType Directory -Force -Path $base | Out-Null
& powershell -NoProfile -ExecutionPolicy Bypass -File `
    "$root\sim\scripts\run_unit_coverage_regression.ps1" -ReportDir $base
```

七个套件脚本（均在 `SmartCampusMedia\sim\scripts\`）：

| 套件脚本 | case 数 | 需要的额外开关 |
|---|---:|---|
| `run_unit_coverage_regression.ps1` | 29 | 自动；5 个 case 需 vsim 命令行追加第二顶层 `glbl` |
| `run_frontend_regression.ps1` | 20 | 无 |
| `run_storage_regression.ps1` | 4 | 无 |
| `run_audio_regression.ps1` | 2 | 无 |
| `run_startup_ownership_regression.ps1` | 2 | 无 |
| `run_image_regression.ps1` | 3 | 无 |
| `run_display_content.ps1` | 1 | 无（`-RealCore` 走 Questa，本次不用） |
| **合计** | **61** | |

**work 库干净性实证**（每个 work 目录的创建时间都在跑该套件的那一分钟内，且跑前已删目录）：

| 套件 | work 库新建时刻 | work 项数 | 跑完时刻 |
|---|---|---:|---|
| suite_unit | 12:39:07 | 85 | 12:50:09 |
| suite_frontend | 12:39:12 | 44 | 12:42:23 |
| suite_storage | 12:39:16 | 13 | 12:39:21 |
| suite_audio | 12:39:19 | 9 | 12:44:05 |
| suite_startup | 12:39:23 | 17 | 12:39:25 |
| suite_image | 12:39:26 | 18 | 12:41:05 |
| suite_display | 12:39:37 | 17 | 12:42:34（177.8 s） |

证据全部落盘在 `D:\FPGA_Compelate\reports\plan_v2\_t5_work\`（13 个子目录，27.6 MB）：

| 目录 | work 库新建时刻 | 文件数 | 字节数 |
|---|---|---:|---:|
| `anchor_vol_apply` | 12:38:21 | 16 | 159,345 |
| `anchor_wav_stream_player` | 12:38:32 | 21 | 559,163 |
| `anchor_audio_src_mux` | 12:38:48 | 16 | 111,697 |
| `suite_unit` | 12:39:07 | 446 | 5,341,481 |
| `suite_frontend` | 12:39:12 | 233 | 4,939,752 |
| `suite_storage` | 12:39:16 | 61 | 1,108,195 |
| `suite_audio` | 12:39:19 | 39 | 206,197 |
| `suite_startup` | 12:39:23 | 78 | 1,159,688 |
| `suite_image` | 12:39:26 | 85 | 1,605,108 |
| `suite_display` | 12:39:37 | 82 | 12,413,238 |
| `anchor_t7_pix_mosaic` | 12:56:36 | 18 | 152,135 |
| `anchor_t7_emerg_page` | 12:56:37 | 14 | 1,067,704 |
| `anchor_t7_mutant` | 12:56:39 | 18 | 153,991 |

各套件目录含 `driver_stdout.txt` + transcript + 每 case 日志；frontend/storage/audio/image/display 另有 `result.json`。

### 1.2 结果总表

**总计：61 个 case，全部 passed，driver 全部 exit=0，失败 0；累计 PASS 断言行 2,120 条。**

| 套件 | case 数 | 通过 | 失败 | PASS 断言行合计 |
|---|---:|---:|---:|---:|
| unit（`run_unit_coverage_regression.ps1`） | 29 | 29 | 0 | **1,204** |
| frontend（`run_frontend_regression.ps1`） | 20 | 20 | 0 | **855** |
| storage（`run_storage_regression.ps1`） | 4 | 4 | 0 | 25（仅 `tb_async_fifo`；其余三 case 走 SUMMARY 判据） |
| audio（`run_audio_regression.ps1`） | 2 | 2 | 0 | 24 |
| startup（`run_startup_ownership_regression.ps1`） | 2 | 2 | 0 | 12 |
| image（`run_image_regression.ps1`） | 3 | 3 | 0 | 走 SUMMARY 判据 |
| display（`run_display_content.ps1`） | 1 | 1 | 0 | 走 SUMMARY 判据 |
| **合计** | **61** | **61** | **0** | **2,120** |

### 1.3 unit 套件逐 case（29/29）

| # | case | PASS 行 | 判据 |
|---:|---|---:|---|
| 1 | lane_lvds_10_1 | 22 | marker + PASS 行（需 `glbl` 第二顶层） |
| 2 | hdmi_phy | 66 | 同上（需 `glbl`） |
| 3 | video_rgb_to_axis | 54 | marker + PASS 行 |
| 4 | audio_arc | 41 | marker + PASS 行 |
| 5 | video_timing_gen | 18 | marker + PASS 行 |
| 6 | test_pattern_gen | 142 | marker + PASS 行 |
| 7 | audio_waveform | 76 | marker + PASS 行 |
| 8 | audio_tone_gen | 46 | marker + PASS 行 |
| 9 | pcm_to_pwm | 39 | marker + PASS 行 |
| 10 | key_matrix_4x4 | 50 | marker + PASS 行 |
| 11 | ax_debounce | 31 | marker + PASS 行 |
| 12 | seg_decoder | 51 | marker + PASS 行 |
| 13 | image_path_probe | 54 | marker + PASS 行 |
| 14 | hdmi_pll | 13 | marker + PASS 行（需 `glbl`） |
| 15 | sdram_pll | 13 | marker + PASS 行（需 `glbl`） |
| 16 | dmz_eg4s20_min_top | 51 | 整机集成 |
| 17 | science_font16 | 49 | marker + PASS 行 |
| 18 | sdram_frame_diag_top | 37 | 需 `glbl` + 厂商 SDRAM 模型 |
| 19 | brightness_apply | **27** | v2 控制层 |
| 20 | mode_ctrl | **48** | v2 控制层 |
| 21 | key_router | **30** | v2 控制层 |
| 22 | i2c_master | **23** | v2 传感层 |
| 23 | aht20_ctrl | **32** | v2 传感层 |
| 24 | thermal_guard | **23** | v2 传感层 |
| 25 | fat32_reader | **52** | t6 音频 |
| 26 | gain_direction | **13** | t6 音频 |
| 27 | **vol_apply** | **41** | **锚点 ✓** |
| 28 | **audio_src_mux** | **24** | **锚点 ✓** |
| 29 | **wav_stream_player** | **38** | **锚点 ✓** |

`known_issues` 全部为 0。

### 1.4 frontend 套件逐 case（20/20）

sd_protocol_default 62、sd_protocol_fast 64、sd_spi_ctrl 23、sd_probe 14、fat32_reader 52、gallery_probe 37、bmp_parser 37、img_loader 53、player_ctrl 94、err_prompt 49、buzzer_tone 23、key_action 42、video_overlay 106、science_page 11、video_content_mux 10、osd_caption 56、osd_param_text 27、osd_panel 55、osd_autopop 26、fade_mixer 14。

> `sd_protocol_default` 与 `sd_protocol_fast` 是**同一个 top（`tb_sd_spi_protocol`）配不同 `-g` 参数**跑两遍，故必须按 2 个 case 计。

### 1.5 storage / audio / startup / image / display（走 SUMMARY 判据的 10 个 case）

| 套件 | case | checks | errors | cases | marker |
|---|---|---:|---:|---:|---|
| storage | tb_async_fifo | 24 | 0 | 8 | `ALL CHECKS PASSED: async_fifo` |
| storage | tb_framebuf_arbiter | 71,023 | 0 | 15 | 同构 |
| storage | tb_sdram_ctrl_wrap | 154,771 | 0 | 12 | 同构 |
| storage | tb_pix_reader | 108 | 0 | 8 | 同构 |
| audio | hdmi_audio_path | — | 0 | — | `ALL CHECKS PASSED: hdmi_audio_path`（PASS 行 19） |
| audio | pwm_audio_out_legacy | — | 0 | — | `ALL CHECKS PASSED, errors = 0`（PASS 行 5） |
| startup | startup_ownership | — | 0 | — | `ALL CHECKS PASSED: startup_ownership`（PASS 行 9） |
| startup | startup_ownership_legacy | — | — | — | **`EXPECTED LEGACY HANDOFF FAILURE DETECTED: startup_ownership`**（PASS 行 3） |
| image | img_scaler | 187 | 0 | — | `ALL CHECKS PASSED: img_scaler` |
| image | image_player | 11,365 | 0 | — | `ALL CHECKS PASSED: image_player` |
| image | image_player_scaled | 1,811 | 0 | — | `ALL CHECKS PASSED: image_player` |
| display | display_content | **614,406** | 0 | — | `ALL CHECKS PASSED: display_content` |

`display_content` 完整判据行（整机端到端，是最强的一条）：

```
# SUMMARY: checks=614406 errors=0 missing=0 mismatched=0 underflow=0 overflow=0
           rd_fault=0 rd_timeout=0 load_reads=0 load_writes=0 max_rd_wait=9
# ALL CHECKS PASSED: display_content
status=passed   frameIdentical=True（displayed.ppm 与 expected.ppm 哈希相同）  elapsed=177.8 s
```

夹具在跑的过程中由脚本内嵌 C# 生成：`disk.hex` 6,291,456 B、`golden.hex`/`golden2.hex` 各 1,536,000 B、`expected.ppm` 921,615 B。依赖 `assets\sd_verify\good\IMG001.BMP` 与 `IMG002.BMP`（各 921,654 B，已确认存在）。

> **`startup_ownership_legacy` 的通过条件与其它 case 相反**：它必须打印"检测到预期的 legacy 交接失败"。任何人看到这条日志里的 FAILURE 字样都不要当成回归失败。

### 1.6 三个跨版本锚点（手工干净库单独复验，不经套件脚本）

为防止"套件脚本自身判据写松了导致假绿"，这三个锚点**用全新手工 work 库各跑一遍**（先 `Remove-Item -Recurse` 再 `vlib work`），结果与套件完全一致：

| 锚点 case | 要求 | 实测 | 结论 |
|---|---|---|---|
| `tb_vol_apply` | 41 pass / 0 fail | `# === tb_vol_apply: pass=41 fail=0 ===` + `ALL CHECKS PASSED: vol_apply` | ✓ 对上 |
| `tb_wav_stream_player` | 38 / 0 | `# === tb_wav_stream_player: pass=38 fail=0 ===` | ✓ 对上 |
| `tb_audio_src_mux` | 24 / 0 | `# === tb_audio_src_mux: pass=24 fail=0 ===` | ✓ 对上 |

命令模板（源文件用绝对路径正斜杠）：

```
vlib.exe work
vlog.exe -quiet <源文件...>
vsim.exe -c -quiet -onfinish stop -do "onerror {quit -f -code 2}; run -all; quit -f -code 0" work.<top>
```

**依赖顺序坑（t8 后改顶层时最容易复发）**：`wav_stream_player.v:279` 例化了 `fat32_reader`，所以编译列表里 `rtl\storage\fat32_reader.v` 必须在 `rtl\audio\wav_stream_player.v` 之前。套件脚本已正确排序；手工跑时漏了会得到 `Instantiation of 'fat32_reader' failed`。

### 1.7 t7 新增的 3 个定向 case（不属于上面的 61，但已实测纳入基线）

| case | top | checks | 结果 | 干净 work 库 |
|---|---|---:|---|---|
| t1 几何 | `tb_pix_mosaic` | 149 | `SUMMARY: checks=149 pass=149 fail=0`，marker `pix_mosaic` | ✓ 12:52 新建 |
| t1 变异反证 | `tb_pix_mosaic`（`pix_mosaic_mutant.v`） | 149 | `checks=149 pass=69 **fail=80**` —— **期望失败，反证成功** | ✓ 新建 |
| t2 应急页 | `tb_emerg_page` | 57 | `SUMMARY: checks=57 errors=0 fail=0`，marker `emerg_page` | ✓ 新建 |

> `run_t1_mutant.ps1` 的通过定义与常规相反：**变异体必须被抓到（fail>0 且命中 `FAIL: I1`）才算通过**。它当前的 fail=80、退出码 0 是正确的。

这三个 case（`run_t1_geom.ps1` / `run_t1_mutant.ps1` / `run_t2_emerg.ps1`，均在 12:51-12:52 由 t7 建立）**没有被 `run_full_regression.ps1` 收录**，t8 之后要单独跑。

### 1.8 基线里记录的 11 个孤儿 testbench（不在任何套件里，t8 后要人工判断）

`prim_sim_stub.v`（3,788 B，只定义三个空壳原语，**全树无引用，是死文件**）、`tb_dbg_scaler`、`tb_dmz_eg4s20_bringup`、`tb_emerg_page`（t7 新，见 1.7）、`tb_framebuf_realcore_concurrent`、`tb_image_window_mask`、`tb_pix_mosaic`（t7 新，见 1.7）、`tb_probe_burst`、`tb_probe_order`、`tb_probe_pix`、`tb_seg_scan4`。

---

## 2. 基线表 B —— lint

命令（工作目录 `SmartCampusMedia`，`python` 3.13.15）：

```powershell
$env:PYTHONIOENCODING='utf-8'; [Console]::OutputEncoding=[Text.Encoding]::UTF8
python scripts\lint_verilog.py rtl                              # 默认目标
python scripts\lint_verilog.py rtl project\src project\hdmi     # = sync_src.ps1:141 的原样调用
```

| 命令 | 检查文件数 | E0 文件损坏 | E1 赋值混用 | E2 多驱动 | 结论行 | exit |
|---|---:|---:|---:|---:|---|---:|
| `lint_verilog.py rtl` | **65** | 0 | 0 | 0 | `结论: 通过（无损坏 / 无混用赋值 / 无多驱动）` | 0 |
| `lint_verilog.py rtl project\src project\hdmi` | **116** | 0 | 0 | 0 | 同上 | 0 |

采样时刻 12:54:32。文件数自洽核对：`rtl` 65 + `project\src` 5 + `project\hdmi` 46 = **116**，与第二条命令报的数字完全一致。

三条检查的含义（`scripts/lint_verilog.py`，179 行）：
- **E0**：分号后出现孤立标识符（文件被截断/损坏，如 `...;S`）；
- **E1**：同一 `always` 块内混用 `=` 与 `<=`（TD 直接报 ERROR）；
- **E2**：同一变量被多个 `always` 块驱动。

> 控制台是 GBK 时中文输出会乱码（`����ļ���: 65` 之类），**这不是文件损坏**。必须先设 `PYTHONIOENCODING=utf-8`。判定一律看 `E0/E1/E2` 三个数字和 `结论:` 行，不看是否乱码。

---

## 3. 基线表 C —— 综合资源

**唯一有效目录：`reports\diag_key1_fifo_backpressure_20261101\`**

| 文件 | 大小 | 修改时间 | SHA256 |
|---|---:|---|---|
| `area.txt` | 24,544 B | 2026-11-01 18:47:51 | `4D7068F427F8BD554BFCA0356BBD1606C528C2CA36CEB75B3995295EAFFD75B4` |
| `timing.txt` | 790,153 B | 2026-11-01 18:47:51 | `D65FFD097DFE6738A47FA170020B5A4FEEBCFA66E7AB4C241DC83E9B8E084483` |
| `coverage.txt` | 56,057 B | — | — |
| `smartcampus_media_fifo_backpressure_20261101.bit` | 629,640 B | — | — |

`area.txt:2` → `***Report Model: dmz_eg4s20_hdmi_top Device: EG4S20BG256***`

### 3.1 资源占用（只引 le / lut / bram / dsp 四列含义明确的指标）

| 指标 | 已用 / 总量 | 利用率 | area.txt 行号 | 余量 |
|---|---|---:|---|---:|
| `#lut` | **15,319 / 19,600** | **78.16 %** | :11 | **+4,281** |
| `#le` | 16,039 | — | :13 | +3,561 |
| `#reg` | 6,390 / 19,600 | 32.60 % | :12 | +13,210 |
| `#bram` | **17 / 64** | **26.56 %** | :17 | +47 |
| `#bram9k` | 17 | — | :18 | — |
| `#fifo9k` | 0 | — | :19 | — |
| `#bram32k` | 0 / 16 | 0.00 % | :20 | +16 |
| `#dsp` | **19 / 29** | 65.52 % | :21 | +10 |
| `#IO` | 41 / 188 | 21.81 % | :5（in 8 / out 33 / inout 0 见 :6-:8） | +147 |
| `#pad` | 45 / 188 | 23.94 % | :22 | — |
| `#pll` | 2 / 4 | 50 % | :26 | +2 |
| `#gclk` | 4 / 16 | 25 % | :27 | +12 |

`#le` 的构成（`:14-:16`）：`#lut only` 9,649（60.16 %）、`#reg only` 720（4.49 %）、`#lut&reg` 5,670（35.35 %）。

### 3.2 为什么只引这四列 —— `ripple` 列不是触发器数

`area.txt:174-178` 的 Report Hierarchy Area 表头是 `|Instance|Module|le|lut|ripple|seq|bram|dsp|`，顶层行 `:178`：

```
| top | dmz_eg4s20_hdmi_top | 16039 | 13008 | 2311 | 6416 | 17 | 19 |
```

顶层 `lut` 列写 **13008**，而 Utilization 段 `:11` 写的是 **15319**，差额 2311 恰好等于 `ripple` 列。反证：`u_science_page`（`science_page`，纯组合逻辑、无时钟）在层级表里记 `ripple 380`。**纯组合模块不可能有 380 个触发器**，故 `ripple` 是某种"可重构/被折叠逻辑"的计数，绝不等于 FF 数。

**规范：本基线只引 `le` / `lut` / `bram` / `dsp` 四列。凡看到某份报告用 ripple 当寄存器数，那份报告的资源分析不可信。**

### 3.3 顶层与主要子实例（`le / lut / ripple / seq / bram / dsp`）

顶层 `dmz_eg4s20_hdmi_top`：`16039 / 13008 / 2311 / 6416 / 17 / 19`

| 实例 | 模块 | le | lut | bram | dsp |
|---|---|---|---:|---:|---:|---:|
| `u_player` | `image_player` | 7,511 | 6,137 | 3 | 13 |
| ├ `u_reader` | `pix_reader` | 2,255 | 2,180 | — | — |
| ├ `u_pix_fifo` | `async_fifo` | 1,684 | 1,672 | — | — |
| ├ `u_loader` | `img_loader` | 2,003 | 1,476 | — | — |
| ├ `u_scaler` | `img_scaler` | 1,351 | 958 | — | — |
| ├ `u_sdram` | `sdram_ctrl_wrap` | 484 | 399 | — | — |
| ├ `u_bmp` | `bmp_parser` | 442 | 328 | — | — |
| ├ `u_arb` | `framebuf_arbiter` | 231 | 183 | — | — |
| └ `u_fade` / `u_write_fifo` | `fade_mixer` / `async_fifo` | 201 / 81 | 201 / 63 | — | — |
| `u_hdmi_core` | — | 1,701 | 1,302 | 14 | 0 |
| `u_axis` | `video_rgb_to_axis` | 1,569 | 1,568 | 0 | 0 |
| `u_gallery` | `gallery_probe` | 1,051 | 833 | 0 | 6 |
| └ `u_fat` | `fat32_reader` | 1,023 | 805 | 0 | 6 |
| `u_science_page` | `science_page` | 1,044 | 664 | 0 | 0 |
| └ `u_font` | `science_font16` | 284 | 284 | — | — |
| `u_overlay` | `video_overlay` | 631 | 520 | — | — |
| ├ `u_wave` | `audio_waveform` | 449 | 416 | — | — |
| └ `u_caption` | `osd_caption` | 56 | 41 | — | — |
| `u_sd` | `sd_spi_ctrl` | 619 | 537 | — | — |
| `u_buzz` | `buzzer_tone` | 293 | 199 | — | — |
| `u_osd_panel` | `osd_panel` | 227 | 176 | — | — |
| `u_key` | `key_matrix_4x4` | 194 | 189 | — | — |
| `u_tone` | `audio_tone_gen` | 168 | 126 | — | — |
| `u_vtg` | `video_timing_gen` | 129 | 87 | — | — |
| `u_pat` | `test_pattern_gen` | 127 | 81 | — | — |
| `u_ctrl` | `player_ctrl` | 121 | 104 | — | — |
| **`u_kact`** | **`key_action`** | **8** | **8** | — | — |
| `u_err` | `err_prompt` | 88 | 57 | — | — |
| `u_image_mask` | `image_window_mask` | 82 | 41 | — | — |
| `u_seg` | `seg_scan4` | 95 | 84 | — | — |
| `u_probe` | `sd_probe` | 62 | 54 | — | — |
| `u_arc` | `audio_arc` | 63 | 36 | — | — |
| `u_pwm_audio` | `pcm_to_pwm` | 51 | 26 | — | — |
| `u_phy` | `hdmi_phy` | 47 | 38 | — | — |
| `u_pll` / `u_sdram_pll` | `hdmi_pll` / `sdram_pll` | 0 | 0 | — | — |

> 这一列就是 t8 要动的两处：`u_kact`（8 le）和 `u_ctrl`（121 le / 104 lut）会被删掉，所以**删实例本身的资源回收只有约 129 le / 112 lut**，t8 后 LUT 净增量几乎全来自新例化的模块。

### 3.4 时钟域 LUT 分布（`area.txt:134-142`）

| # | 时钟 | 频率 | LUT as Logic | LUT as Dram | BRAM | DSP |
|---:|---|---:|---:|---:|---:|---:|
| 1 | `clk` | 50 MHz | 8 | 0 | 0 | 0 |
| 2 | `u_pll/pll_inst.clkc[0]` | 25 MHz | 6,150 | 1,024 | 17 | 19 |
| 3 | `u_pll/pll_inst.clkc[2]` | 125 MHz | 33 | 0 | 0 | 0 |
| 4 | `u_sdram_pll/pll_inst.clkc` | 40 MHz | 338 | 0 | 3 | 0 |

时钟资源扇出（`:145-152`）：`u_pll/clk0_buf` 3,371、`u_sdram_pll/clk1_raw` 905、`u_phy/u_lane_ch0/I_serial_clk` 30、`clk_dup_1` 7。

> **BRAM 17 块的归属很清楚**：25 MHz 域 17 块（全部来自 `u_player` 的 3 + `u_hdmi_core` 的 14），40 MHz 域 3 块。`u_player` 内的 `u_pix_fifo`（async_fifo）用的是分布式逻辑而非 BRAM9K。

---

## 4. 基线表 D —— 时序（`timing.txt`）

| 指标 | 基线值 | 行号 | t8 后门槛（T7_MUST_TEST V-10） |
|---|---|---:|---|
| 工具 | Tang Dynasty v6.2.168116 | :1 | — |
| Top Model | `dmz_eg4s20_hdmi_top` | :5 | 不变 |
| Device | `EG4S20BG256` | :6 | 不变 |
| STA coverage | **99.90 %** | :8 | 不得下降 |
| 约束文件 | `project/hdmi/dmz_eg4s20_hdmi.sdc` | :9 | 不变 |
| Confidence | Routed | :10 | 必须是 Routed（不能是 Estimated） |
| Check Corner | Both (Slow and Fast) | :11 | 不变 |
| **Setup WNS（SWNS）** | **+1.935 ns** | :27 | **≥ 0** |
| **Hold WNS（HWNS）** | **+0.003 ns** | :28 | **≥ 0**（注意余量只有 3 ps） |
| STNS / HTNS | 0.000 ns / 0.000 ns | :27-:28 | — |
| Period Check WNS | 0.000 ns | :29 | — |
| Max 路径 | SWNS 7.042 ns，**0** 违规端点 / 10,498 端点 / 1,631,137 条路径 | :79 | 违规端点必须为 0 |
| Min 路径 | HWNS 0.003 ns，**0** 违规端点 | :80 | 违规端点必须为 0 |

逐时钟（`:77-82`）：

| 时钟 | 频率 | SWNS | HWNS | 扇出 |
|---|---:|---:|---:|---:|
| clk0 | 25 MHz | 7.042 | 0.003 | 3,371 |
| clk1 | 40 MHz | **1.935** | 0.014 | 905 |
| clk2 | 125 MHz | 5.305 | 0.239 | 30 |
| clk3 | 50 MHz | 16.681 | — | — |
| clk4 | 40 MHz | — | 12.374 | 1 |
| clk5 | 12.5 MHz | 0 | 0 | 0 |

> **HWNS 只有 3 ps 是最脆的一环。** 全局 SWNS=1.935 是 40 MHz 域拖出来的，而 25 MHz 域自己的 SWNS 有 7.042 ns 富余。t8 若在 40 MHz（SDRAM）域插逻辑，比在 25 MHz 域危险得多。

`coverage.txt` 的 14 项检查：no clock 0、clock definition 0、dummy node **3**、invalid constraint 0、pll/clock buffer **2**、combinational loops 0、soft fifo timing exception 0、no path 0、shadowed/ignored 0、no input delay **7**、no output delay **33**、partial input 0、partial output 0、abnormal input delay **32**。

> 加粗的 6 项非零是既有状态（不是本次引入），t8 后对比时应**保持不变**；若 `dummy node` 或 `pll/clock buffer` 数量上升，说明新模块引入了未约束的时钟网络。

### 4.1 不要引用的旧 area.txt

`reports\` 下还有 7 份更旧的 area.txt，**均为过期数据，不得引用**：`key1_fix_20261031`（24,136 B / 10-31 20:23:51）、`d810_fix_20261031`（24,136 B）、`watchdog_20261030`（24,544 B）、`flashable_20261030`（24,670 B）、`c2_scaler_20261030`（24,136 B）、`noise_sci_fix_20261029`（24,544 B）、`b2_fade_20261029`（23,864 B）。

---

## 5. 基线表 E —— 文件清单与同步缺口

### 5.1 `rtl/` vs `project/hdmi/` 的 .v 差额（自己数的，不是「差 16 个」）

采样 12:54:57：

| 目录 | .v 数 |
|---|---:|
| `rtl/`（递归） | **65** |
| `project/hdmi/`（递归） | **46** |
| **差额** | **19** |

差额 19 = 仅 `rtl/` 有的 **20** 个 − 仅 `project/hdmi/` 有的 **1** 个。

**仅 `rtl/` 有（20 个）**：
`rtl\sensor\aht20_ctrl.v`、`rtl\audio\audio_src_mux.v`、`rtl\common\ax_debounce.v`、`rtl\video\brightness_apply.v`、`rtl\osd\cjk16_font.v`、`rtl\video\color_bar_ref.v`、`rtl\top\dmz_eg4s20_bringup_top.v`、`rtl\top\dmz_eg4s20_min_top.v`、`rtl\video\emerg_page.v`、`rtl\sensor\i2c_master.v`、`rtl\storage\image_path_probe.v`、`rtl\storage\image_readback_diag.v`、`rtl\control\key_router.v`、`rtl\control\mode_ctrl.v`、`rtl\video\pix_mosaic.v`、`rtl\video\ratio_map.v`、`rtl\storage\sdram_frame_diag.v`、`rtl\sensor\thermal_guard.v`、`rtl\audio\vol_apply.v`、`rtl\audio\wav_stream_player.v`

**仅 `project/hdmi/` 有（1 个）**：`project\hdmi\enc\hdmi_1_4b_transmitter_core_wrapper.enc.v`（加密件，本就不该在 rtl/ 出现）

> 差额会随队友写入继续变：12:24 时是 15，12:51 时是 18，12:54 是 19。**任何引用"差额 N"的说法都必须带时间戳。** 当前口径：**19（20 缺 − 1 多）**。

### 5.2 `sync_src.ps1` 的 `$map` 缺口（t8 前必须补齐）

`scripts\sync_src.ps1`（147 行）用 `[ordered]` 哈希 `$map` 登记"主源 → 目标副本"，其中：`:41 'rtl\storage\sd_spi_ctrl.v' = @('project\hdmi\sd_spi_ctrl.v')`、`:43 'rtl\storage\fat32_reader.v' = @('project\hdmi\fat32_reader.v')`、`:89 'rtl\top\dmz_eg4s20_hdmi_top.v' = @('project\hdmi\dmz_eg4s20_hdmi_top.v')`、`:97 'rtl\top\dmz_eg4s20_min_top.v' = @('project\src\dmz_eg4s20_min_top.v')`。同步完自动跑 `:141 python scripts\lint_verilog.py rtl project\src project\hdmi`（除非 `-NoLint`）。

**`rtl/` 的 65 个 .v 中有 19 个完全不在 `$map`**：

```
rtl\audio\audio_src_mux.v          rtl\storage\image_path_probe.v
rtl\audio\vol_apply.v              rtl\storage\image_readback_diag.v
rtl\audio\wav_stream_player.v      rtl\storage\sdram_frame_diag.v
rtl\common\ax_debounce.v           rtl\top\dmz_eg4s20_bringup_top.v
rtl\control\key_router.v           rtl\video\brightness_apply.v
rtl\control\mode_ctrl.v            rtl\video\color_bar_ref.v
rtl\osd\cjk16_font.v               rtl\video\emerg_page.v
rtl\sensor\aht20_ctrl.v            rtl\video\pix_mosaic.v
rtl\sensor\i2c_master.v            rtl\video\ratio_map.v
rtl\sensor\thermal_guard.v
```

其中 **t8 会直接例化的**：`key_router`、`mode_ctrl`、`brightness_apply`、`i2c_master`、`aht20_ctrl`、`thermal_guard`、`vol_apply`、`audio_src_mux`、`wav_stream_player`、`emerg_page`、`ratio_map`、`pix_mosaic`、`cjk16_font` —— 共 13 个。**不补进 `$map`，TD 综合必报 undefined module。**

**另外 `$map` 里没有任何 `.hex` 条目**，而 `cjk16_font.v` 用了 `$readmemh("cjk16_bitmap.hex", mem)`（`:88`），路径是**不带目录前缀的相对路径**，语义为"综合/仿真的当前工作目录"。当前的现状是：

| 路径 | 状态 |
|---|---|
| `rtl\osd\cjk16_bitmap.hex`（37,200 B，7,440 行 = 465 字形 × 16 行） | 存在 |
| `assets\v2\masters\font\cjk16_bitmap.hex` | 存在（与上者 SHA256 完全相同：`F57337590BF0A3BF3892FA67AF6669C36DA19247B5A8B0870D3A813A5379C02B`） |
| `project\hdmi\cjk16_bitmap.hex` | **缺失** |
| `project\hdmi\osd\cjk16_bitmap.hex` | **缺失** |

> 这就是「BRAM 仍是 17」这个怀疑项的根本原因：`.hex` 不在综合工作目录里，`$readmemh` 静默装全零，综合器据全零判"常量存储器"直接优化掉，**BRAM 计数不涨、也不报任何错**，上板现象是字幕区全空白。

### 5.3 其它计数

| 项 | 数 |
|---|---:|
| `rtl/` 行数（所有 .v） | 14,410 行 |
| `rtl\top\dmz_eg4s20_hdmi_top.v` | 450 行，**31 个例化**（含 4 个 `seg_decoder`、1 个 `EG_PHY_SDRAM_2M_32`、1 个 `hdmi_1_4b_transmitter_core_wrapper`）；实例名 31 个全唯一，无重名。文件最后改动 2026-10-31 16:55:31（40,676 B）→ **t8 尚未动过顶层** |
| `sim/` 全树 .v | 91（`testbench` 75 + `msim_work` 4 + `mut_scaler` 11 + `mut_t1` 1） |
| `sim\testbench\` 中 `tb_*.v` | 74（另 1 个 `prim_sim_stub.v`） |
| `sim\scripts\*.ps1` | 20 个 |
| `ip/` .v | 7 |
| 模块名重复定义 | **0**（`rtl/` + `sim/testbench/` 共 139 个 `module` 定义，139 个唯一名） |

---

## 6. t8 集成后怎么做对比（照着做，不要临时发挥）

### 6.1 对比前先确认"身份一致"

```powershell
# 1) 打指纹，和本报告第 0 节比对
$root='D:\FPGA_Compelate\SmartCampusMedia'
foreach($d in @('rtl','project\hdmi','sim\testbench')){
  $fs=Get-ChildItem (Join-Path $root $d) -Recurse -File -Filter *.v
  $l=($fs|%{ "$($_.FullName.Substring($root.Length+1).Replace('\','/')):$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }|Sort-Object) -join "`n"
  "{0,-14} {1,3} 文件  指纹 {2}" -f $d,$fs.Count,([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($l))).Replace('-','').ToLower())
}
```

### 6.2 仿真对比（**唯一正确的做法：每套件一个新 ReportDir**）

```powershell
$root='D:\FPGA_Compelate\SmartCampusMedia'
foreach($s in @('unit_coverage','frontend','storage','audio','startup_ownership','image','display_content')){
  $d="D:\FPGA_Compelate\reports\plan_v2\_t8_work\suite_$s"
  if(Test-Path $d){ Remove-Item -Recurse -Force $d }      # ← 这一步不能省
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\sim\scripts\run_${s}_regression.ps1" -ReportDir $d
}
```

对比口径（逐条核对，缺一条都不算通过）：

| # | 判据 | 基线值 |
|---:|---|---|
| 1 | 7 套件 driver exit 全 0 | 是 |
| 2 | case 总数 | **61**（unit 29 + frontend 20 + storage 4 + audio 2 + startup 2 + image 3 + display 1） |
| 3 | 失败 case | **0** |
| 4 | 三个锚点 | vol_apply **41/0**、wav_stream_player **38/0**、audio_src_mux **24/0** |
| 5 | `display_content` SUMMARY | checks ≥ **614,406**、errors=0、`frameIdentical=True` |
| 6 | `image_player` / `image_player_scaled` / `img_scaler` checks | **11,365** / **1,811** / **187**，errors 全 0 |
| 7 | `tb_framebuf_arbiter` / `tb_sdram_ctrl_wrap` checks | **71,023** / **154,771**，errors 全 0 |
| 8 | `startup_ownership_legacy` | 必须命中 `EXPECTED LEGACY HANDOFF FAILURE DETECTED`（这条"失败"是对的） |
| 9 | t7 三件（单独跑） | pix_mosaic 149/149、mutant pass=69 **fail=80**（期望）、emerg_page 57/0 |
| 10 | 各 case 的 `known_issues` | 全 0 |

> checks 数**只允许持平或上升**，不允许下降。checks 变少通常意味着某个断言分支被条件绕过（静默失效），比直接 FAIL 更危险。

### 6.3 lint 对比

```powershell
cd D:\FPGA_Compelate\SmartCampusMedia
$env:PYTHONIOENCODING='utf-8'
python scripts\lint_verilog.py rtl
python scripts\lint_verilog.py rtl project\src project\hdmi
```

判据：两次都 **exit=0**、`E0=E1=E2=0`、结论行是 `结论: 通过（无损坏 / 无混用赋值 / 无多驱动）`。文件数会因 t8 新增模块而变（基线 65 / 116），**文件数变化正常，E0/E1/E2 变化不正常**。

### 6.4 综合 + 时序对比

```powershell
# TD 综合产出新目录后，与基线目录逐文件比
$base='D:\FPGA_Compelate\SmartCampusMedia\reports\diag_key1_fifo_backpressure_20261101'
$new ='<t8 新的 diag 目录>'
Select-String -Path "$new\area.txt" -Pattern '#lut|#le|#reg|#bram|#dsp|#IO|#pll|#gclk'
Select-String -Path "$new\timing.txt" -Pattern 'SWNS|HWNS|STA coverage|Confidence'
```

| 指标 | 基线 | t8 后判据 |
|---|---:|---|
| `#lut` | 15,319 / 19,600（78.16 %） | ≤ 19,600 且增幅记录在案 |
| `#le` | 16,039 | ≤ 19,600 |
| `#reg` | 6,390 | 记录（预计因新模块上升） |
| `#bram` | 17 / 64 | **必须 > 17**（cjk16_font 至少 +13）；≤ 64 |
| `#dsp` | 19 / 29 | ≤ 29 |
| `#IO` | 41 / 188 | 记录（sensor 引脚可能 +2） |
| `#pll` / `#gclk` | 2 / 4、4 / 16 | ≤ 4 / ≤ 16 |
| **SWNS** | **+1.935 ns** | **≥ 0** |
| **HWNS** | **+0.003 ns** | **≥ 0** |
| STA coverage | 99.90 % | ≥ 99.90 % |
| Confidence | Routed | 必须是 Routed |
| 违规端点 | 0 / 0 | 必须 0 / 0 |
| timing 约束文件 | `project/hdmi/dmz_eg4s20_hdmi.sdc` | 不变 |

**对比方法必须做的三件事**：

1. **同一 top、同一 device、同一 sdc**。若新报告 `area.txt:2` 的 `Report Model` 不是 `dmz_eg4s20_hdmi_top` 或 Device 不是 `EG4S20BG256`，整份报告作废，不能拿来比。
2. **只比 `le` / `lut` / `bram` / `dsp` 四列**（顶层行还用 `seq`）。**绝不用 `ripple` 列当触发器数**——顶层 `lut` 列 13008 vs Utilization 15319 的差额 2311 恰好等于 ripple，而纯组合的 `science_page` 却记 `ripple 380`，两处反证。
3. **层级表要对得上"谁涨了"**。若 `#lut` 涨了但层级表里找不到对应实例增长，说明涨幅发生在顶层胶合逻辑（多半是 key_code 直连没清干净或新老实例并存），要当缺陷查。

### 6.5 文件清单对比

```powershell
$root='D:\FPGA_Compelate\SmartCampusMedia'
"rtl={0}  project\hdmi={1}  差额={2}" -f `
  (Get-ChildItem "$root\rtl" -Recurse -File -Filter *.v).Count, `
  (Get-ChildItem "$root\project\hdmi" -Recurse -File -Filter *.v).Count, `
  ((Get-ChildItem "$root\rtl" -Recurse -File -Filter *.v).Count - (Get-ChildItem "$root\project\hdmi" -Recurse -File -Filter *.v).Count)
```

基线：`rtl=65`、`project\hdmi=46`、差额 **19**（20 缺 − 1 多）。

`sync_src.ps1` 跑完后，应满足：
- 5.2 节列的 19 个文件**全部**出现在 `project\hdmi\`（`dmz_eg4s20_bringup_top.v` / `dmz_eg4s20_min_top.v` 除外，它们去 `project\src\`）；
- `project\hdmi\cjk16_bitmap.hex` 存在且 37,200 B；
- **`rtl/` 与 `project/hdmi/` 的 .v 差额收敛到 1**（只剩那个 `.enc.v`）。

---

## 7. t8 后「优先怀疑」清单（按出现概率排序，逐条给了判定方法）

### ① LUT 涨幅超 2,500 —— 优先怀疑"新老实例并存"或"删得不干净"

- **基线**：15,319 / 19,600，余量 **4,281**（21.84 %）。
- **门槛**：t8 后 `#lut` 增量 **> 2,500** 就必须停下来查，不能拿"新模块多"糊过去。
- **为什么是这个数**：t8 新增的模块里，逻辑最重的是 `wav_stream_player`（719 行）、`aht20_ctrl`（590 行）、`i2c_master`（313 行）、`key_router`（223 行）、`mode_ctrl`（197 行）、`vol_apply`（128 行）、`audio_src_mux`（105 行）。而这些模块的既有仿真资源特征都很轻（`u_kact` 8 le、`u_ctrl` 121 le），删除旧实例只回收约 **129 le / 112 lut**。2,500 已经接近余量的 58 %，越过它几乎一定不是"正常增长"。
- **判定**：拿新 area.txt 的层级表逐个实例比基线 3.3 节的表。**若某个新增实例的 lut 超过 1,500，先查它是不是被反复例化**；**若总 `#lut` 涨了 2,500 而层级表增量之和不到 1,000，差额在顶层胶合逻辑** —— 几乎必然是 `u_kact` / `u_ctrl` 没删干净，或者 `key_code==4/5/6` 直连没撤。
- **交叉验证**：`PRECHECK_T5_T6.md` 已指明 `rtl\top\dmz_eg4s20_hdmi_top.v:101 key_action u_kact (` 与 `:116 player_ctrl #(.CLK_FREQ_HZ(25_000_000)) u_ctrl (` 必须删；`:84`、`:85`、`:402` 三处 `key_code==4/5/6` 直连必须撤（会与 `key_router` 的 `K_AUDIO=4 / K_TICKER=5 / K_BRIGHT=6` 抢键）。**这三处任一残留，LUT 未必涨，但行为一定错**，所以清单里单独列一条给它们。

### ② BRAM 仍然是 17 —— 说明 `.hex` 没进 BRAM

- **基线**：17 / 64（`#bram9k` 17、`#fifo9k` 0）。
- **判据**：t8 引入 `cjk16_font`（8192 × 16 bit 字库）后，`#bram` **必须明显大于 17**。按深度 8192 ÷ 512 = 16 段（512×18 配置）需 **16 块**；按数据量 119,040 bit ÷ 9,216 bit/块需 13 块。**取大者 16**。所以期望值在 `33 / 64`（+16）附近，退一步至少 `30 / 64`（+13）。
- **若仍是 17**，按这个顺序查（前三项都是"静默失败"，不报错）：
  1. **`.hex` 不在综合工作目录**。`cjk16_font.v:88` 是 `$readmemh("cjk16_bitmap.hex", mem)`，路径无目录前缀 = 当前工作目录。**当前 `project\hdmi\cjk16_bitmap.hex` 不存在**（见 5.2），必须由 `sync_src.ps1` 补同步。
  2. **`sync_src.ps1` 的 `$map` 没登记这个 `.hex`**。当前 `$map` 里**一个 `.hex` 都没有**。
  3. **全零数据被综合器优化掉**。若 `.hex` 缺失，`$readmemh` 静默装全零，综合器判"常量存储器"直接删，BRAM 计数不涨且**无任何报错**；上板现象是字幕区全空白。
  4. **`ram_style = bram` 属性位置失效**。`cjk16_font.v:84` 是 `reg [15:0] mem [0:8191] /* synthesis ram_style = bram */;`。若被人改成别的写法或属性被工具忽略，会摊成寄存器 —— 这种情况**LUT 会暴涨而 BRAM 不涨**，和 ① 联手出现。
- **反向核对**：如果 BRAM 涨到 33 而 LUT 也涨了 2,000 以上，说明字库**同时**进了 BRAM 又摊了一部分逻辑，查 `cjk16_font` 的读地址译码。
- **还有一个自检口子**：`cjk16_font.v:58-60` 的注释说明唯一可靠自检是 `tb_osd_caption_cjk.v` 的 V-11 断言 —— 读 `glyph=0, row=1` 必须等于 `16'h3FF8`（"日"字第 1 行），读到 `16'h0000` 即路径没解析到，按硬失败处理。**这个 TB 目前还不存在**（`sim\testbench\` 里没有 `tb_osd_caption_cjk.v`），t8/t21 补上它之前，`.hex` 是否真装上只能靠 BRAM 计数间接判断。

### ③ 老 tb 退化 —— 优先怀疑"端口/inline 例化变了而 TB 没跟上"

- **基线**：61 case + t7 三件，全绿（见第 1 节）。
- **退化最可能的形态**（按发生概率）：
  1. **`vlog` 直接失败**（`Instantiation of 'xxx' failed`）。通常是 `sync_src.ps1` 的 `$map` 没补齐，或编译列表少了新模块的源文件。t8 新增例化的 13 个模块见 5.2。
  2. **编译顺序错**：`wav_stream_player.v:279` 例化 `fat32_reader`，**`fat32_reader.v` 必须排在 `wav_stream_player.v` 之前**。
  3. **TB 里的 inline 例化过期**：`T7_MUST_TEST.md` V-18 已点名四个 TB 需要改例化 —— `sim\testbench\tb_image_player.v:72`、`tb_display_content.v:47`、`tb_startup_ownership.v:50`、`tb_pix_reader.v:103`。**这四处没改，t8 后这四个 case 必然失败**，而且失败信息会指向 DUT 端口不匹配，容易误判成 RTL 坏了。
  4. **`glbl` 第二顶层被漏掉**：`lane_lvds_10_1`、`hdmi_phy`、`hdmi_pll`、`sdram_pll`、`sdram_frame_diag_top` 这 5 个 case 的 vsim 命令行必须追加第二个顶层 `glbl`。漏了的表现是 `gsrn` 不释放、**DUT 永远在复位、所有断言超时** —— 看起来像 RTL 死了，其实只是仿真调用少了一个参数。
  5. **checks 数悄悄下降**：见 6.2 的 #5-#7 阈值。比 FAIL 更危险，一定要逐 case 对数，不要只看"全绿"。

- **判定**：先跑 `git stash`/对比基线树指纹，确认改动只来自 t8；再按上面 5 条顺序排查。**任何"老 tb 红了"在排除这 5 条之前，都不许改 RTL。**

### ④ TD 报 undefined module —— 说明 `sync_src.ps1` 的 `$map` 没补齐

- **基线缺口**：`rtl/` 的 65 个 .v 中 **19 个不在 `$map`**（清单见 5.2），其中 t8 会直接例化的 **13 个**：`key_router`、`mode_ctrl`、`brightness_apply`、`i2c_master`、`aht20_ctrl`、`thermal_guard`、`vol_apply`、`audio_src_mux`、`wav_stream_player`、`emerg_page`、`ratio_map`、`pix_mosaic`、`cjk16_font`。
- **判定**：TD 报错文本里出现 `undefined module: <名字>` 时，直接在 5.2 的 19 行清单里 grep 该名字。命中 = `$map` 缺口；没命中 = 是别的模块真的没写或文件名拼错。
- **修法**：往 `scripts\sync_src.ps1` 的 `$map` 里按现有格式补条目，例如
  `'rtl\control\key_router.v' = @('project\hdmi\key_router.v')`
  `.hex` 也要单独补一条（目标 `project\hdmi\cjk16_bitmap.hex`）。改完跑一次 `sync_src.ps1`（它会自动跑 lint），然后核对 6.5 节的判据：**`rtl/` 与 `project/hdmi/` 的 .v 差额应收敛到 1**（只剩 `enc\hdmi_1_4b_transmitter_core_wrapper.enc.v`）。
- **注意**：这是一个**闭环自检**——如果 t8 后差额还是 19，说明 `$map` 一个都没补；如果差额变成 1 但 TD 还报 undefined module，说明缺的是 `.hex` 或 `project\src\` 分支。

### ⑤ 附带一条：时序余量只剩 3 ps，别在 40 MHz 域加逻辑

- 基线 HWNS = **+0.003 ns**（40 MHz 域 clk1 的 hold），全局 SWNS 1.935 ns 也是被这个域拖出来的。25 MHz 域自己 SWNS 有 7.042 ns 富余。
- **t8 若把新逻辑挂到 40 MHz（SDRAM）域，几乎必破 hold。** 新模块（key_router / mode_ctrl / sensor / audio 路径）全部属于 25 MHz 像素域或独立慢速域，挂载位置必须保持这个划分。
- 判定：新 timing.txt 里 `:27/:28` 的 SWNS/HWNS 任一为负 = V-10 不通过，且要先看 clk1 那一行。

---

## 8. 采样期间的额外发现（供 t8 参考，不属于基线本身）

1. **`run_t2_emerg.ps1` 有编码隐患，会让"干净库"纪律失效。** 该文件是 UTF-8 **无 BOM**，含 240 个非 ASCII 字节；Windows PowerShell 5.1 用 GBK 读它时会**吞掉换行**，把注释和代码并到一行。实测：GBK 解码后 48 行（正确应为 51 行），`Remove-Item -Recurse -Force (Join-Path $WorkDir 'work')` 这句**被并进注释里、完全没执行**（AST 里 `Remove-Item` 命令数 = 0，对照 `run_t1_geom.ps1` 有 BOM，计数 = 1）。后果：该脚本自己声称"干净重建库"，实际**复用旧 work 库**。
   - 同样问题在 `run_t1_geom.ps1`（有 BOM，安全）与 `run_t1_mutant.ps1`（有 BOM，安全）上不存在。
   - **风险面**：`sim\scripts\` 20 个脚本里，无 BOM 且含非 ASCII 的只有 `run_t2_emerg.ps1` 与 `run_frontend_regression.ps1` 两个；后者行数未变（106 → 106），但**建议一并加 BOM**。
   - 本文档第 6.2 节的对比流程**在外面自己删目录**，因此不受这条影响；但直接跑 `run_t2_emerg.ps1` 的人会中招。
2. **7 套件脚本内部全是 `if (-not (Test-Path work)) { vlib work }`，没有一个会清库。** 这是任务里"过期 work 库跑出假失败"的根源。`run_full_regression.ps1` 也不清库。**跑任何回归都必须每次给全新 `-ReportDir`。**
3. **`t7` 的三个套件没进 `run_full_regression.ps1`**，t8 之后要单独跑（见 1.7）。
4. **`prim_sim_stub.v` 是死文件**（3,788 B，定义 `EG_LOGIC_ODDR`/`EG_LOGIC_BUFG`/`EG_LOGIC_INV` 三个空壳，全树无任何引用）。仿真实际走的是 TD 厂商库 `D:\TD_6_24_APP\sim_release\eg4`。不要因为它存在就以为仿真不依赖厂商库。
5. **`cjk16_font.v` 目前还没有被任何模块例化**（grep 全 rtl 与全部 tb，只命中它自己的文件头注释）。t21 中文滚动字幕还没接进 RTL，所以当前 BRAM=17 是正常的，`$.readmemh` 也还没被综合器看到。

---

## 9. 环境（复现必须一致）

| 项 | 值 |
|---|---|
| ModelSim | `D:\Quartus_APP\modelsim_ase\win32aloem`（`vlib.exe` / `vlog.exe` / `vsim.exe` / `vsimk.exe` 均在） |
| 厂商原语库 | `D:\TD_6_24_APP\sim_release\eg4`（30 个 .v；套件用到 `eg_logic_io.v`、`eg_phy_glbl.v`、`eg_phy_pll.v`、`eg_logic_clk.v`、`eg_phy_sdram_2m_32.v` 五个，**必须绝对路径且排在编译列表最前**） |
| Python | 3.13.15 |
| PowerShell | 5.1.26100.9711（Desktop），**脚本里的中文注释要求文件带 BOM** |
| 统一宏 | `+define+SDRAM_SIM_MODEL`（对整个编译生效，对其它 TB 无害） |
| 综合报告目录 | `reports\diag_key1_fifo_backpressure_20261101` |
| 证据目录 | `reports\plan_v2\_t5_work\`（13 个子目录，27.6 MB） |
