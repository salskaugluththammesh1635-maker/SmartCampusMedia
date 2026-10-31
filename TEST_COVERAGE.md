# 测试覆盖总览（TEST_COVERAGE）

这份文档回答三个问题：**现在有哪些测试、每个 RTL 模块被谁测、怎么一键跑完。**

- 覆盖结论与运行方式见本文件；
- 测试背后的设计契约与架构见 [ARCHITECTURE.md](ARCHITECTURE.md)；
- 任务完成度见 [TASKS.md](TASKS.md)；
- 逐条开发记录见 [开发进度](docs/progress.md)。

> 本文按 **2026-10-31** 的仓库状态更新。所有数字都来自本轮实跑的 `result.json`，不是估算。

---

## 一、一句话结论

`rtl/` 下 **54 个 module 中有 53 个已被至少一个 testbench 例化验证**，剩下的 `color_bar`
是官方例程参考件（全仓从未被任何 RTL 例化），不参与构建，因此不为它写 TB。

一键跑全部 7 个套件：

```powershell
powershell -ExecutionPolicy Bypass -File sim/scripts/run_full_regression.ps1
```

只跑本次新增的 18 个模块级 TB：

```powershell
powershell -ExecutionPolicy Bypass -File sim/scripts/run_unit_coverage_regression.ps1
```

两个脚本都需要安路 TD 的官方仿真库（见第五节），默认路径 `D:\TD_6_24_APP\sim_release\eg4`，
可用 `-PrimLibPath` 覆盖。

---

## 二、本轮新增的 18 个 testbench

这 18 个 TB 填补的是"RTL 里有模块、`sim/testbench/` 里没有对应用例"的缺口。
每个 TB 只针对一个模块，全部位于 `sim/testbench/`，共约 6000 行。

| # | testbench | 被测模块 | 覆盖要点 | 断言数 | 已登记缺陷 |
|---|---|---|---|---|---|
| 1 | `tb_lane_lvds_10_1.v` | `rtl/video/hdmi/lane_lvds_10_1.v` | 10bit 串行化的位序（MSB 先出）、2bit/串行周期、d0/d1 上下沿分工、字间不串位 | 22 | — |
| 2 | `tb_hdmi_phy.v` | `rtl/video/hdmi/hdmi_phy.v` | 4 通道 10bit **全位反序**、四通道互不串扰、时钟通道 TMDS 图案 | 66 | — |
| 3 | `tb_seg_decoder.v` | `rtl/common/seg_decoder.v` | 16 个输入的七段真值表、逐段分解、极性（高电平点亮）、纯组合无 latch | 51 | — |
| 4 | `tb_video_timing_gen.v` | `rtl/video/video_timing_gen.v` | 800×525 全帧时序、DE 计数 307200、hs/vs 脉宽、`frame_start` 周期、HS_POL/VS_POL 参数 | 18 | — |
| 5 | `tb_test_pattern_gen.v` | `rtl/video/test_pattern_gen.v` | 8 种图案逐点核对（彩条/网格/渐变/纯色/方块/棋盘）、消隐期全黑、方块 40 步不变量扫描 | 142 | — |
| 6 | `tb_video_rgb_to_axis.v` | `rtl/video/hdmi/video_rgb_to_axis.v` | `user`/`last` 的 DE 上升沿与像素计数语义、`H_ACTIVE` 参数化、短行不错发 last | 54 | — |
| 7 | `tb_ax_debounce.v` | `rtl/common/ax_debounce.v` | 抖动抑制、可重触发定时器、计数器饱和、高有效复位极性 | 31 | — |
| 8 | `tb_key_matrix_4x4.v` | `rtl/input/key_matrix_4x4.v` | 行扫描独热低、20ms 消抖的**第 6 次采样**才翻转、按住不重复触发、同行/跨行多键优先级 | 50 | — |
| 9 | `tb_audio_arc.v` | `rtl/video/hdmi/audio_arc.v` | ACR 包每 48 样本一发、`acr_cts` 用**像素时钟**测量音频节拍（稀疏输入下 = 384 拍） | 41 | — |
| 10 | `tb_audio_tone_gen.v` | `rtl/audio/audio_tone_gen.v` | 8 种音名的相位增量、48kHz 分数分频、三角波逐样本、mute 优先级、AUTO 五音循环 | 46 | — |
| 11 | `tb_pcm_to_pwm.v` | `rtl/audio/pcm_to_pwm.v` | σ-Δ 占空比跟随直流输入、零阶保持、静音、极性、进位根因护栏 | 39 | — |
| 12 | `tb_audio_waveform.v` | `rtl/video/audio_waveform.v` | 64 点历史移位、x→样本索引映射、8 像素对齐、y 区间逐列扫描 | 76 | — |
| 13 | `tb_image_path_probe.v` | `rtl/storage/image_path_probe.v` | 三站 sticky 标记、跨域两级同步、**两个时钟域复位互不干扰** | 54 | — |
| 14 | `tb_hdmi_pll.v` | `rtl/video/hdmi/hdmi_pll.v` | 25MHz 与 125MHz 严格 5 倍关系（周期实测 40ns / 8ns） | 13 | — |
| 15 | `tb_sdram_pll.v` | `rtl/storage/sdram_pll.v` | 两路 40MHz、0°/180° **电平互补**（不依赖绝对延迟）、锁定 | 13 | — |
| 16 | `tb_dmz_eg4s20_min_top.v` | `rtl/top/dmz_eg4s20_min_top.v` | **整链集成**：键盘→消抖→BCD→段码→动态扫描→LED→蜂鸣器（含 tone_sel 位宽根因钉子） | 51 | — |
| 17 | `tb_science_font16.v` | `rtl/video/science_font16.v` | 40 个 16×16 字形、607 个填充行、字形签名互不相同、可肉眼核对的钉子值 | 49 | — |
| 18 | `tb_sdram_frame_diag_top.v` | `rtl/storage/sdram_frame_diag.v`（第二个 module） | **整链集成**：50MHz→PLL→控制器→153600 字写读比对→LED 编码 | 37 | — |

合计 **853 条断言**，`known_issues` 全为 0（三个缺陷已修复，断言已转为硬判据）。

---

## 三、测试发现的真实 RTL 缺陷（已全部修复）

这些是**测试发现的、RTL 里真实存在的缺陷**，不是测试写错了。三个缺陷都已在 RTL 中修复，
对应的断言已从"XFAIL 登记"翻转为**硬断言**——一旦有人改回去会立刻 FAIL。

TB 仍保留 `known_issues` 计数器（缺陷复现时单独记账、不判失败；缺陷消失时反而计
`errors` 提醒更新登记表），当前所有 TB 的 `known_issues` 均为 **0**。

### 3.1 `pcm_to_pwm` 的 σ-Δ 反馈取错位 —— 音频恒定无声（P0）

`rtl/audio/pcm_to_pwm.v:62`：

```verilog
pwm_q <= acc_next[31];      // 取的是截断和的 bit31
```

一阶 σ-Δ 的反馈必须取**进位**（33 位和的 bit32）。数学上
`acc(n+1) = (acc(n) + x) mod 2^32`，这个 `mod` 就是"减掉 y·2^32"，所以 y 必须是进位。

两者不等价：

- 进位 = 1 ⟺ `acc + x >= 2^32`
- bit31 = 1 ⟺ `(acc + x) mod 2^32 >= 2^31`

而 `x = {sample + 2^23, 8'b0}` 恒为 256 的倍数、`acc` 从 0 起，于是 `acc` 的所有取值都落在
"256 的倍数"这个等距点集上，该点集恰好对 2^31 对称 → **bit31 恒有一半时间为 1，任何直流输入
都输出 50% 占空比**，音频等于恒定无声。

TB 用"两种解释同时算出来对照"的方式把根因钉死（选 x = 0xC0000000 即 +1/4 FS，周期 4 拍、
4096 拍窗口下分别是 3072 与 2048，都是整数无舍入误差）：

```
[rootcause] dut_high=2048  bit31_model=2048  carry_model=3072  law=3072
PASS: [rootcause] DUT duty == bit31-of-sum interpretation (this is the bug)
PASS: [rootcause] carry interpretation yields the correct 75% duty
```

**已修复**：`reg [32:0] acc;` / `wire [32:0] acc_next = {1'b0, acc[31:0]} + {1'b0, sample_ext};` /
`pwm_q <= acc_next[32];`。修复后 TB 实测 `dut_high=3072`（= 设计律 3/4），
原 `bit31_model=2048` 的 50% 行为已消失，`known_issues` 从 8 归零。

### 3.2 `test_pattern_gen` 移动方块回程下溢 —— 方块飞出画面

`rtl/video/test_pattern_gen.v` 的边界翻转判据：

```verilog
if ((box_x + BOX_SIZE) >= (H_ACTIVE - BOX_SIZE)) box_dx <= 1'b0;
else if (box_x == 0)                            box_dx <= 1'b1;
```

回程时 `box_dx` 已为 0，箱体每步减 64。当 `box_x` 由 64 减到 0 的那一步，判据看的是**更新前**
的 64（≠0），`dx` 不会翻回 1；下一步执行 `0 - 64`，**11 位无符号下溢成 1984**，方块飞出画面。
y 轴同理下溢成 960（10 位）。实测 y 轴第 15/16 步、x 轴第 19/20 步溢出。

**为什么正向走位测不出来**：只有走到回程末端才暴露。所以 TB 用"不变量扫描"而非逐点核对——
每步用 32 像素网格（方块 64×64 必然命中）扫全屏找方块色，找不到即违反不变量。

**已修复**：`else if (box_x <= BOX_SIZE) box_dx <= 1'b1;`（y 轴同理 `box_y <= BOX_SIZE`）。
修复后 40 步不变量扫描全部通过，`known_issues` 从 5 归零。

### 3.3 `dmz_eg4s20_min_top` 蜂鸣器位宽缺陷 —— 按键完全不出声（P0）

`rtl/top/dmz_eg4s20_min_top.v`：

```verilog
.tone_sel (2'd1)        // 端口是 3 位
```

`buzzer_tone` 的 `tone_sel` 是 **3 位**（`rtl/audio/buzzer_tone.v:117`），这里接成 2 位常量。
**ModelSim 实测：端口连接处的位宽不匹配是 z 扩展，不是零扩展**：

- `2'd1` 接 3 位端口 → 内部看到 `3'bz01` → `(sel == 3'd1)` 求值为 **x**
- `3'd1` 接 3 位端口 → `3'b001` → 比较得 1
- 但 `assign assigned = 2'd1;`（3 位线网）→ `001`，**assign 语句是正常零扩展**

结论：**只有端口连接处是 z 扩展**。`vlog` 编译 0 warning、`-novopt` 重跑结果相同，排除优化假象。

后果链：`tone_sel = 3'bz01` → `sq_en` 恒为 x → 方波永不翻转 → **按键蜂鸣器完全无声**，
这是硬件上真实存在的现象，不只是仿真问题。

**已修复**：`.tone_sel (3'd1)`。实测 `tone_sel=001 sq_en=1`，按键后 500000 拍内
`edges=10`（原版 edges=0），`known_issues` 从 2 归零。

> 注意 `rtl/audio/buzzer_tone.v` 第 21 行附近的注释曾写"2 位表达式接到 3 位端口时高位自动补 0，
> 故 min_top 无需改动"——该注释与实测不符，是这条缺陷长期未被发现的原因。

---

## 四、覆盖矩阵：54 个 module 逐一对照

`rtl/` 下共 54 个 module 定义（含同一文件内的多个 module）。下表是实测的"模块 → 例化它的 testbench"。

### 4.1 本轮新增 TB 覆盖的模块（18 个）

见第二节表格，不再重复。

### 4.2 由既有 testbench 覆盖的模块（35 个）

| 模块 | 主要 testbench |
|---|---|
| `async_fifo` | `tb_async_fifo` |
| `bmp_parser` | `tb_bmp_parser` |
| `buzzer_tone` | `tb_buzzer_tone` + `tb_dmz_eg4s20_min_top` |
| `dbg_scaler` | `tb_dbg_scaler` |
| `err_prompt` | `tb_err_prompt` |
| `fade_mixer` | `tb_fade_mixer` |
| `fat32_reader` | `tb_fat32_reader` |
| `framebuf_arbiter` | `tb_framebuf_arbiter`（7 套 TB 复用） |
| `gallery_probe` | `tb_gallery_probe`、`tb_probe_burst`、`tb_probe_order`、`tb_probe_pix` |
| `image_player` | `tb_image_player` 等 3 套 |
| `image_window_mask` | `tb_image_window_mask` |
| `img_loader` | `tb_img_loader` |
| `img_scaler` | `tb_img_scaler` |
| `key_action` | `tb_key_action` |
| `osd_autopop` | `tb_osd_autopop` |
| `osd_caption` | `tb_osd_caption` |
| `osd_panel` | `tb_osd_panel` |
| `osd_param_text` | `tb_osd_param_text` |
| `osd_strings` | `tb_osd_caption`（间接） |
| `pix_reader` | `tb_pix_reader` |
| `player_ctrl` | `tb_player_ctrl` |
| `science_page` | `tb_science_page` |
| `sd_probe` | `tb_sd_probe` |
| `sd_spi_ctrl` | `tb_sd_spi_ctrl`、`tb_sd_spi_protocol` |
| `sdram_behavior_model` | 多套存储 TB（`+define+SDRAM_SIM_MODEL` 内联） |
| `sdram_ctrl_wrap` | `tb_sdram_ctrl_wrap`（10 套 TB 复用） |
| `sdram_frame_bist` | `tb_sdram_frame_diag` |
| `seg_scan4` | `tb_seg_scan4` + `tb_dmz_eg4s20_min_top` |
| `startup_ownership` | `tb_startup_ownership` |
| `video_content_mux` | `tb_video_content_mux` |
| `video_overlay` | `tb_video_overlay` |
| `dmz_eg4s20_bringup_top` | `tb_dmz_eg4s20_bringup` |
| `bmp`/`frame` 相关 BFM | 内联在各 TB 中 |

### 4.3 没有 TB 的模块（1 个，已评估后决定不补）

| 模块 | 文件 | 结论 |
|---|---|---|
| `color_bar` | `rtl/video/color_bar_ref.v` | 官方 `lab_ex5_i2s` 例程的彩条源，**全仓从未被任何 RTL 例化**（仅 3 处注释提及）。它 `include "video_define.v"`，靠 `ifdef VIDEO_1280_720` 等 8 组宏选分辨率，默认 1280×720。项目实际用的是 `video_timing_gen` + `test_pattern_gen`，八色彩条已由 `tb_test_pattern_gen` 覆盖。属参考资料，不为它写 TB。 |

### 4.4 无法整链仿真的顶层（2 个）

| 顶层 | 原因 | 替代覆盖 |
|---|---|---|
| `dmz_eg4s20_hdmi_top` | 例化 `ip/local/hdmi/enc/hdmi_1_4b_transmitter_core_wrapper.enc.v`，该加密文件在 ModelSim ASE 10.1d 下 `vlog` 会**挂死**（只反复打印 `** Warning: ...(130): in protected region.`，300s 超时后被迫 kill） | 由 18 个单元 TB + 前端/存储/音频/显示/图像 5 套子系统回归组合覆盖 |
| `sdram_bringup_top` | 依赖真实加密 SDRAM 核 | `tb_sdram_frame_diag_top` 覆盖同一条 PLL→控制器→BIST 链（用内联行为模型） |

---

## 五、为什么需要安路官方仿真库

`lane_lvds_10_1` / `hdmi_phy` 例化 `EG_LOGIC_ODDR`，两个 PLL 例化 `EG_PHY_PLL`。
这些是安路原语，必须用官方行为模型：

**库目录**：`D:\TD_6_24_APP\sim_release\eg4\`（30 个文件）

### 5.1 必需文件与用途

| 文件 | 提供什么 | 谁需要 |
|---|---|---|
| `eg_logic_io.v` | `EG_LOGIC_ODDR` 等 IO 原语 | lane / hdmi_phy |
| `eg_phy_glbl.v` | `module glbl`（提供 `glbl.gsrn` 全局复位） | 所有用到 ODDR / PLL 的 TB |
| `eg_phy_pll.v` | `EG_PHY_PLL`（1197 行**真实分频模型**，不是空壳） | hdmi_pll / sdram_pll / diag_top |
| `eg_logic_clk.v` | `EG_LOGIC_BUFG`（**注意：不在 eg_logic_io.v 里**） | 两个 PLL |
| `eg_phy_sdram_2m_32.v` | `EG_PHY_SDRAM_2M_32`（加密，但 diag_top 在 `ifdef` 外例化它） | sdram_frame_diag_top |

### 5.2 `glbl` 必须作为第二个顶层传入

`eg_logic_io.v` 里有 `tri1 gsr_n = glbl.gsrn;`。没有 `glbl` 模块时 `gsr_n` 是 `x`，会传染整条链路；
而 `glbl` 自己的复位在 `#10` 之后才释放。所以：

```powershell
vsim ... work.tb_lane_lvds_10_1 glbl     # 末尾必须带 glbl
```

否则 `gsrn` 恒 0、DUT 永远处于复位态。本仓库有 5 个 TB 需要这样跑：
`lane_lvds_10_1`、`hdmi_phy`、`hdmi_pll`、`sdram_pll`、`sdram_frame_diag_top`。

### 5.3 官方模型的两个"正常噪声"

- `eg_phy_pll.v` 加载时打印大量
  `# ****** : The Attribute CLKCx_DIV on pll instance ... is set to N. Legal values ... 1 to 128.`
  ——这是**参数范围提示，不是错误**，不要当失败。
- `sdram_frame_diag_top` 运行时有一条
  `** Warning: (vsim-3722) ... [TFMPC] - Missing connection for port 'refresh_error'.`
  ——端口未连接提示，无害。

---

## 六、如何解读测试结果

### 6.1 判定口径

每个 TB 结尾都会打印两行：

```
SUMMARY: checks=<总数> errors=<失败数> known_issues=<已登记缺陷数>
ALL CHECKS PASSED: <module>        （或 CHECKS FAILED: <module>）
```

脚本判定"通过"需要**同时满足**四条：退出码 0、日志里含 `ALL CHECKS PASSED: <module>`、
`PASS:` 行数 > 0、日志里不含 `CHECKS FAILED` / `GLOBAL TIMEOUT` / `FAIL:` / `** Error`。

`known_issues` 单独计数，不影响通过判定，但会写进 `result.json`，让已登记缺陷在报告里保持可见。

### 6.2 七套回归的范围

`run_full_regression.ps1` 依次跑：

| 套件 | 脚本 | 覆盖 |
|---|---|---|
| `unit` | `run_unit_coverage_regression.ps1` | **18 个模块级 TB**（本轮新增，853 断言） |
| `frontend` | `run_frontend_regression.ps1` | SD 协议 / FAT32 / BMP / 播控 / 键位 / OSD |
| `storage` | `run_storage_regression.ps1` | SDRAM / 帧缓存仲裁 / 64ms 保持 |
| `audio` | `run_audio_regression.ps1` | HDMI 音频通路 / PWM 音频 |
| `startup` | `run_startup_ownership_regression.ps1` | 启动所有权交接 |
| `display` | `run_display_content.ps1` | 显示内容逐像素验证 |
| `image` | `run_image_regression.ps1` | 图像装载通路 |

每套件在独立子 PowerShell 进程里跑，控制台输出重定向到各自 `console.log`，
结果汇总到 `$ReportRoot\summary.json`。默认报告目录在 `$env:TEMP` 下
（`scm_full_regression`），用 `-ReportRoot` 指定别处。

### 6.3 最近一次全量实跑结果（2026-10-31）

```
unit       PASSED   exit=0        677s  asserts=853     18 module unit testbenches
frontend   PASSED   exit=0        195s  asserts=829     SD/FAT32/BMP/player/OSD
storage    PASSED   exit=0          5s  asserts=220642  SDRAM / framebuf / retention
audio      PASSED   exit=0        311s  asserts=24      audio tone / PWM / waveform path
startup    PASSED   exit=0          2s  asserts=12      startup ownership handoff
display    PASSED   exit=0        172s  asserts=614405  display content verification
image      PASSED   exit=0        142s  asserts=11298   image path regression
--------------------------------------------------------
suites: passed=7 failed=0 total=7  asserts=848063  elapsed=1505s
FULL REGRESSION PASSED
```

`unit` 套件的耗时几乎全在 `sdram_frame_diag_top` 上：17 个 TB 时整套只要 72 秒，
加上它（385k 拍、约 10 分钟）后变成约 680 秒。其余 17 个 TB 都压在千拍量级。
`audio` 套件的 24 条是真实值——它只有 `tb_hdmi_audio_path`（19 条）与
`tb_pwm_audio_out`（5 条）两个用例，不是统计漏算。

### 6.4 三档验证口径

本项目严格区分三种"通过"（详见 [TASKS.md](TASKS.md) §阅读说明）：

| 档位 | 含义 |
|---|---|
| 仿真 | ModelSim 行为仿真通过，有明确 pass marker 与断言 |
| 综合布线 | 安路 TD 完成 elaborate + 综合 + 布局 + 布线 + bitgen |
| 上板 | 下载 bit 到 DMZ-EG4S20 板卡后观察到预期现象 |

**本文件全部内容都属于第一档"仿真"**。仿真通过不能证明真实器件时序，也不能证明板上电气行为。

---

## 七、写新 testbench 时的可复用经验

这些是写这 18 个 TB 过程中踩出来的坑，都已固化在代码注释里。

### 7.1 判据设计

- **相位模板匹配优于找字首**。串行流里字与字首尾相接、没有空隙，"非零且前一拍为零"的锚点法
  对含连续 0 的字会数出多个假锚点。正确做法是对相位 `p = 0..PERIOD-1` 逐个试，存在某个 p
  使全部样本匹配即通过——这能自动吸收 1~2 拍装载延迟。
- **测量宽度/周期前必须先 arming**。复位期的低电平不是同步脉冲，会被误当成脉宽；
  先见到一次高电平再开始计量。
- **缺陷要"诊断"而非"断言"**。把两种可能的解释同时算出来并列打印（DUT 实测 vs 模型 A vs
  模型 B vs 设计律），比单条 FAIL 有说服力得多。
- **不要从被测 RTL 源码反抽期望表**。同源数据会一起改错，看似全绿实则零验证。正确做法是
  独立硬编码可肉眼核对的钉子值 + 不依赖期望表的结构判据。
- **跨域延迟不能按固定拍数假设**，期望值必须由"快照时同步器各级的实际状态"推导。

### 7.2 TB 与 DUT 的时序配合

- **监视器采样沿要与 DUT 相反**。DUT 在 `posedge` 寄存，监视器就在 `negedge` 采；
  否则所有计数晚一拍，表现为满屏假失败。
- **非阻塞赋值生效前读不到新值**。在 `@(posedge clk)` 检测到事件后，驱动信号在同一沿用
  非阻塞更新，此刻 NBA 尚未生效——必须再等半拍到 `negedge` 才能读到新值。
- **跨时钟域的观测要同步**。若观测时钟与信号寄存时钟不同频（如 50MHz 观测 40MHz 的 LED），
  必须等几个目标时钟沿再采样。
- **TB 临时变量不得复用被 `always` 驱动的信号**，否则 `initial` 里的赋值与 `always` 冲突、
  比较永远成立。
- **等待状态变化要用相对条件**（`while (sig !== target && guard < n)`），不要用累计计数器
  的绝对值。

### 7.3 参数缩放

`localparam` 不能用 `vsim -g` 覆盖。要缩短仿真时间，改它**依赖的 parameter**：

| TB | 真实值 | 缩放后 | 效果 |
|---|---|---|---|
| `tb_ax_debounce` | `FREQ=50, MAX_TIME=20` → 1,000,000 拍 | `FREQ=1, MAX_TIME=1` → 1000 拍 | 时间缩短 1000 倍，时序结构不变 |
| `tb_key_matrix_4x4` | `CLK_FREQ_HZ=50_000_000` → 扫一行 1ms | `4000` → 扫一行 4 拍 | 同理 |
| `tb_audio_tone_gen` | `CLK_FREQ_HZ=25_000_000, SAMPLE_RATE_HZ=48_000` | `100 / 25` | 每 4 拍一个样本 |

### 7.4 环境细节

- **`$display` 一律用英文标签**。ModelSim 在 GBK 控制台下会把中文打成 `?`/乱码；
  中文解释写在注释里。
- **`$sscanf` 在本版 ModelSim 不可用**（恒返回 0），`$fgets` 与 `$readmemh` 可用。
- **写 .v 文件必须无 BOM**。用 `[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($false))`；
  `Set-Content -Encoding utf8` 会带 BOM，ModelSim 报
  `near "?": syntax error, unexpected non-printable character 0xef`。
- **PowerShell 脚本要写成纯 ASCII**。仓库脚本是无 BOM UTF-8，PowerShell 5.1 按 GBK 读，
  多字节中文注释会吞掉后面的引号/花括号，产生莫名的 `Unexpected token` 语法错。
  改完必须校验 `nonAscii = 0` 且 `[Parser]::ParseFile` 的 parse errors = 0。
- **32 位 `integer` 乘法会静默溢出**。`ofs * WIN` 这类 2^24 × 4096 的量级必须用 `real`
  或先除后乘，否则期望值变 0，表现为整组断言全 FAIL 但 DUT 看着正常。
- **Verilog 保留字**不能作变量名：`tri`、`reg`、`wire`、`and`、`or`、`not`、`buf`、
  `pull0/pull1`、`supply0/supply1`、`time`、`small/medium/large`、`strong0/1`、`weak0/1` 等。
- **`u_inst.signal` 只能引用实例内部信号**，不能引用例化时接的 TB 顶层信号。
- **无符号 `wire` 做有符号比较会退化**。`wire [23:0] x` 与负常量比较时整体变无符号，
  要么手工符号扩展，要么把端口声明成 `signed`。

---

## 八、复现命令

```powershell
# 全套（7 个套件）
powershell -ExecutionPolicy Bypass -File sim/scripts/run_full_regression.ps1

# 只跑 18 个模块级 TB
powershell -ExecutionPolicy Bypass -File sim/scripts/run_unit_coverage_regression.ps1

# 指定 ModelSim 与官方库路径
powershell -ExecutionPolicy Bypass -File sim/scripts/run_full_regression.ps1 `
  -ModelSimPath 'D:\Quartus_APP\modelsim_ase\win32aloem' `
  -PrimLibPath  'D:\TD_6_24_APP\sim_release\eg4' `
  -ReportRoot   'D:\reports\full'
```

`result.json` / `summary.json` 里绑定了每轮所有源文件的 SHA256；
运行期间源码被改动即判定该轮证据失效。
