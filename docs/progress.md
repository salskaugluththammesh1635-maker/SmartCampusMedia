# 开发阶段进度表（progress）

> **2026-10-27 最新状态（S12）★全部时序收敛**：SDRAM 域**两次降频 150 → 100 → 40 MHz** 后，全设计静态时序收敛——**SWNS +1.935 ns、STNS 0.000 ns、HWNS +0.011 ns，7 个 path group 全部 0 违例**，`flow_s6_bit.tcl` 打印 `S6_TIMING_PASSED` 并返回 **EXIT 0**（150 MHz 时是 `S6_TIMING_FAILED` / EXIT 3），`project/hdmi_td_Runs/phy_1/hdmi_td.bit` 已是时序收敛后的正式位流（629,640 B，2026-10-27 21:12）。
>
> **关键推理（两次实测反推常数开销）**：第一次降到 100 MHz 仍为负（读 DQ −5.565 ns、写 DQ −2.001 ns），但**内部逻辑域是 +2.604 ns、0 违例**。用 150/100 MHz 两个数据点互证，得到与频率无关的常数开销：**读 `slack = T/2 − 10.565 ns`、写 `slack = T/2 − 7.001 ns`**（预测值与实测误差 < 0.2 ns），由此算出临界频率 **读 47.33 MHz / 写 71.42 MHz**。40 MHz（T/2 = 12.5 ns）预测读 +1.935 / 写 +5.499，实测读 **+1.935** / 写 **+5.630**，完全吻合。
>
> **约束文件一条未改**：`constraints/dmz_eg4s20_hdmi.sdc` 的有效约束仍是原 3 条，`clkc[1]` 与 `clkc[2]` 仍在同一时钟组，0°/180° 相位关系完整保留。这次是**真实降频**，不是把路径移出分析视野。代价是带宽 600 → 160 MB/s，仍是 640×480@60Hz 需求（55.3 MB/s）的 2.9 倍。**仍未上板**（详见文末 [S12 章节](#s12sdram-降频到-40mhz-后时序全部收敛2026-10-27)）。
>
> **2026-10-27 状态（S11）**：修掉 `sdram_pll` 的真缺陷——C1（当时 150 MHz 0°）与 C2（当时 150 MHz 180°）输出**没有走全局时钟网**，只给 C0 补了 BUFG。给 C1/C2 各补一级 `EG_LOGIC_BUFG` 后，`clkc[1]` 自身域 setup 余量 **+0.240 → +0.326 ns**（Fmax 155.618 → **157.729 MHz**），`PHY-5079`（时钟走 local routing）归零，`#gclk` 2→4。**150 MHz 逻辑本身已经收敛（2590 端点 0 违例）**，剩下的 WNS −7.232 ns 全部属于 SiP 接口组，已定性为 TD 硬核模型的建模口径问题（半周期预算 3.333 ns < hard-ip 固定惩罚 5.000 ns，通路为空 slack 也必负，`Logic Level=0`、`net 延迟 0.000 ns`）。**同时复验了历史结论**：三组对照实验证明"拆异步组"得到的 +0.275 ns 是假绿，0°/180° 必须留在同一时钟组。（详见文末 [S11 章节](#s11sdram-时钟网络修复与时序收敛定性2026-10-27)）
>
> **2026-10-27 状态（S10）**：`image_player` 完成**双缓冲无缝切换**，`TASKS.md` A6 的缺口「单缓冲，切图期间显示测试图」闭合。装载写后台帧、前台继续读旧帧，写完整后等垂直消隐换帧首；重载期间屏幕一帧不断，装载失败保留上一帧。改造面仅 3 个 RTL（`pix_reader` 的 `rd_base` 改 input、`framebuf_arbiter` 读侧回绕边界改为运行期量、`image_player` 加双缓冲状态与复位解耦），**顶层与 `player_ctrl` 零改动**。图像链三档全绿（真实 640×480 断言 1,228,812 条，`overlap_cycles=2085846`、`starve_cycles=0`），存储回归 4 套全绿，lint E0/E1/E2 全 0（详见文末 [S10 章节](#s10双缓冲无缝切换2026-10-27)）。
>
> **2026-10-26 状态（S9）**：KEY7～KEY14 八个键全部编号到功能，收拢到唯一译码点 `key_action`，画面侧新增纯组合 `video_overlay`（亮度/反色/九宫格/信息条/音频电平条）。前端回归 **13 个用例全绿**（新增 `key_action` 40 条、`video_overlay` 64 条），lint E0/E1/E2 全 0，`bringup_top` 的两条历史 ModelSim 警告已消除。**八个新键从未上板，未重新综合布线，键盘行序仍未确认**（详见文末 [S9 章节](#s9key7key14-键位分配与画面后处理2026-10-26)）。
>
> **2026-10-21 状态**：`pix_reader` / `framebuf_arbiter` / `sdram_ctrl_wrap` 的读取链路按官方四拍契约重写，旧 TB 的极性错误与"地址变化即组首"假设一并纠正；三套存储 TB + 全尺寸 640×480 + image_player 全链 + 前端 8 个 TB 全部本轮实测通过（详见文末 [S6-2 章节](#s6-2读取链路的契约缺陷修复与可复现回归2026-10-21)）。**仍未上板，SiP 时序违例未变，严格交付门禁未通过**。
>
> **2026-10-20 状态**：阶段四 S6 全链已经集成到 `dmz_eg4s20_hdmi_top`，完整 640×480 图片和异常恢复均有 ModelSim 自检证据。新增 `image_player`，接入 `pix_reader`、播放控制和第二颗 SDRAM PLL；单缓冲装载期间回落测试图。TD 已可出候选 bit，但 SDRAM 接口与相关 150MHz 路径的时序尚未完成验收，不能标为 S6 上板完成。当前细节、命令及结果见 [S6 集成交接](s6_integration_2026-10-20.md)。
>
> **历史结论更正**：本文件较早的 SDRAM bring-up “+0.104ns/0 违例”使用了将同一 PLL 的 0°/180°时钟分成异步组的约束，遗漏 SiP 读写路径，不能作为接口时序已通过的证据。当前 SDC 保留该相位关系并报告实际违例。以下旧记录作为历史保留，按日期和验证范围阅读。

> 状态图例：⬜ 未开始 | 🔶 进行中 | ✅ 已完成 | ⛔ 阻塞
>
> **2026-10-06 更新（四次）★阶段一收口**：用户提供了《微处理器原理综合设计底板》资料包
> （底板原理图 PDF + 权威《板卡和引脚说明》+ 11 个厂商实测例程含全部 .adc 约束）。
> **全部外设管脚核实完毕**并写入 `constraints/dmz_eg4s20_bringup.adc`：HDMI（P1/N1/P4/J3 LVDS33，
> 板载 HDMI-019S 座+ESD，**无需转接板**，无 DDC）、VGA/RGB565（16 位+HS/VS/DE/CLK/BL，两组复用）、
> SD 卡（板载 SPI 模式：F15/F13/F14/D14）、音频输出（**PWM=F3 + 板载功放**）、音频输入（麦克风+ADC SPI）。
> 底板自带 HDMI 显示例程（与官方 DEMO31 同源，实测通过）与 SDRAM 例程（印证片内 SDRAM）。
> TD 6.2.1 已装、首个工程已综合+布局（IO=31 锁定）。**阶段一完成，仅余 2 处来源冲突待上板实测**（键盘行序、SD MOSI/MISO）。
> 音频架构定案：**基础音频走 HDMI 音频**（官方 lab_ex5_i2s 路径），底板 PWM 音频作备用，ES8388 降为可选件。
>
> **2026-10-06 更新（三次）**：用户暂无板卡，转入"先写代码"模式。已交付阶段二/三预演 RTL：
> 视频时序发生器、8 模式测试图发生器、4x4 矩阵键盘消抖扫描、播放控制状态机、4 位数码管扫描、
> 蜂鸣器提示音、最小系统顶层，以及对应 testbench（ModelSim）。修复了 3 处自研代码缺陷。
>
> **2026-10-06 更新（二次）**：赛规精读完成并固化进 project_definition.md §〇；官方参赛样例 lab_ex4_tf/lab_ex5_i2s 已解压至 project/reference/（436 文件）并完成架构解析；官方例程确认读卡用 SPI 模式。
>
> **2026-10-06 更新（一次）**：阶段一资料核实基本完成。板级事实已回写 pending_confirmations.md。

## 阶段一：板卡与工具确认 ✅（已完成，2 项上板实测校验随阶段二进行）

实际平台：自购大拇指 DMZ-EG4S20 核心板 + MO 综合底板。

| 任务 | 状态 | 交付物 |
|---|---|---|
| 获取板卡原理图、管脚约束、官方例程 | ✅ | 核心板全套 + **底板资料包**（原理图 PDF/引脚说明 PDF/11 例程）+ 官方赛题包，全部本地化 |
| 填写 pending_confirmations.md 第 1~7 节 | ✅ | **全部"已确认"**；管脚级核实写入 constraints/dmz_eg4s20_bringup.adc（HDMI/VGA/SD/音频/键盘/LED/数码管/蜂鸣器/拨码/Flash/ADC） |
| 精读赛规并核实合规性 | ✅ | project_definition.md §〇 |
| 登记官方例程与 IP 资源 | ✅ | docs/official_examples.md；project/reference/ + ip/reference/ + **底板 11 例程**（M0_Borad/） |
| 确认 TD 工具版本 | ✅ | TD 6.2.1 |
| 首个 TD 工程 + 编译链路 | ✅ | project/bringup_td.al：**综合+布局完成，IO=31 全部锁定，无 ERROR**（之前 seg_scan4 混用赋值/seg_decoder 损坏字符两问题已修复） |
| 管脚三源交叉验证 | ✅ | 核心板原理图 × 底板引脚说明 × 底板例程 adc 三方一致（数码管/键盘/LED/时钟全吻合）|
| 向主办方报备自购平台 | ⬜ | 用户执行 |

**阶段出口准则**：pending_confirmations.md 第 1~7 节全部"已确认" ✅ 达成。
**遗留 2 项上板实测**（不阻塞开发，随阶段二最小系统一并校验）：① 键盘行序（两来源相反）；② SD MOSI/MISO（引脚说明 vs 例程相反，已采用引脚说明=SD SPI 标准）。

### 阶段一沉淀的关键事实（开发速查）

| 外设 | 管脚/结论 | 来源 |
|---|---|---|
| HDMI（板载座） | CLK_P=P1, D0_P=N1, D1_P=P4, D2_P=J3（LVDS33）；无 DDC → 不做 EDID | 引脚说明 3.3 + 例程实测 |
| VGA/RGB565 | R[4:0]+G[5:0]+B[4:0] 共 16 位（与 LCD FPC 复用），HS=M14, VS=P14, DE=L16, CLK=L13, BL=M16 | 引脚说明 3.1 |
| SD 卡（板载 SPI） | SCK=F15, CS=F13, MOSI=F14, MISO=D14 | 引脚说明 3.6 |
| 音频输出 | **PWM=F3**（板载低通+功放→3.5mm/喇叭）；HDMI 音频为演示首选 | 引脚说明 3.5 |
| 音频输入 | 麦克风+ADC：CS=J6, SCK=H3, MISO=K5, RSTN=G6 | 引脚说明 3.4 |
| SDRAM | 片内 2M×32bit，无管脚（底板例程印证） | 底板例程 7_/8_ |
| SPI Flash | NCS=T3, DCLK=R11, MOSI=T10, MISO=P10（配置专用脚） | 底板例程 9_ |
| 触摸屏（LCD FPC） | TP_CS=N16, MOSI=N14, MISO=P16, SCK=P15, PEN=L12, RES=M11 | 引脚说明 3.1.1 |
| 底板 HDMI 例程 | 10_VGA_hdmi_tx_display_MB（与 DEMO31 同源，含 .al 工程+仿真 do，实测通过） | M0_Borad/ |

## 阶段二：最小系统验证 🔶（仿真已完成；上板验证条件已齐备）

前置条件：阶段一完成（管脚已核实部分可直接约束；底板相关项待原理图）。

| 任务 | 状态 | 交付物 |
|---|---|---|
| 时钟/复位验证（PLL 锁定指示） | 🔶 | 顶层以 50M/2 分频产生像素时钟（仿真与 RGB 目检阶段）；上板 PLL 待 TD 工程添加 |
| LED 流水/闪烁测试 | ✅（仿真级） | rtl/top/dmz_eg4s20_bringup_top.v: `led = {1'b0, pattern_sel, status_led}`（8 位） |
| 按键消抖与事件测试 | ✅（仿真级） | rtl/input/key_matrix_4x4.v（逐键消抖 + 按下沿事件 + 低位优先编码） |
| 数码管显示测试 | ✅（仿真级） | rtl/display/seg_scan4.v + rtl/common/seg_decoder.v（官方移植） |
| 拨码开关读取测试 | ⬜ | 待底板/声卡冲突决策后实施（注意与 ES8388 同球互斥） |
| 键盘→播放控制闭环 | ✅（仿真级） | rtl/control/player_ctrl.v（上一张/下一张/播放暂停/模式/应急） |
| 蜂鸣器提示音 | ✅（仿真级） | rtl/audio/buzzer_tone.v（按键音 C5 / 应急音 E6 断续） |

**阶段出口准则**：全部板级 IO 行为与原理图一致，测试记录写入 reports/。（当前以仿真验证替代，上板后补实测）

### 仿真验证记录（2026-10-06，ModelSim 10.1d）

命令：`sim\scripts\run_sim.bat`（或 `vsim -c -do "run -all" work.tb_dmz_eg4s20_bringup`）
结果：**ALL CHECKS PASSED，errors = 0**，日志 `reports/sim_bringup_log.txt`

| 检查项 | 期望 | 实测 | 状态 |
|---|---|---|---|
| T1 帧时序 | 640x480@60（≈59.5Hz） | 70ms 内 5 帧，hs 周期 32µs | ✅ PASS |
| T2 彩条色带 | 白/黄/青/绿/品红/红/蓝/黑各 80px | x=40 白、x=120 黄、x=360 品红、x=600 黑 | ✅ PASS |
| T2 消隐期 | RGB 全零 | 全零 | ✅ PASS |
| T3a 按键→图案切换 | KEY5 按下后 pattern_sel 0→1 | pattern_sel=1, img_index=0, led=0x10 | ✅ PASS |
| T3b 按键→切图（防误触发） | KEY1 按下后 img_index 0→1 且图案不变 | img_index=1, pattern_sel 保持 1 | ✅ PASS |
| T4 网格图案 | 64px 白线黑底 | (0,0) 白线、(32,32) 黑格心 | ✅ PASS |
| T5 图像导出 | 2 帧 PPM（640×480） | 彩条帧 2.93MB / 网格帧 2.11MB，PNG 目检合格 | ✅ PASS |

图像证据：`reports/sim_out_colorbar.png`、`reports/sim_out_grid.png`（由 PPM 转出，肉眼看图确认渲染正确）

## 阶段三预演：视频链路（无 SDRAM 版）

| 任务 | 状态 | 交付物 |
|---|---|---|
| 640x480@60 时序发生器 | ✅（仿真级） | rtl/video/video_timing_gen.v（参数与官方 VIDEO_640_480 一致） |
| 测试图发生器（8 模式） | ✅（仿真级） | rtl/video/test_pattern_gen.v（彩条/网格/渐变/纯色/移动方块/棋盘） |
| 帧图像 dump 复核 | 🔶 | sim/testbench/tb_dmz_eg4s20_bringup.v 输出 PPM，可转 PNG 目检 |
| HDMI TMDS 输出（APUG092 + PHY） | ⬜ | 管脚已核实（CLK=P1/D0=N1/D1=P4/D2=J3, LVDS33；**板载 HDMI 座, 无需转接板**）；实现可选底板例程 `hdmi_tx` 或官方 APUG092 |
| SDRAM 帧缓存 | ⬜ | 官方 sdram IP + frame_read_write 移植（阶段四） |

## 阶段三：HDMI 视频输出 ⬜

前置条件：阶段二完成。

| 任务 | 状态 | 交付物 |
|---|---|---|
| **HDMI 实现路径选型** | ✅ | 确认两条路径：①官方 DVITransmitter 加密核（阶段三采用，底板例程同源）②自研 TMDS（已确认 `SF2_LOGIC_HS_OSERDES` 原语可用 + `sim_release/eg4` 提供仿真库，留作后续替换以提升自主性） |
| **PLL 时钟设计** | ✅ | `rtl/video/hdmi/hdmi_pll.v`：50MHz → 25MHz 像素 + **125MHz 串化（严格 5 倍）**。参数依据官方 tx_pll.v 结构推导：VCO = 25×40 = 1000MHz，C0=1000/40=25MHz（BUFG 反馈+像素），C2=1000/8=125MHz |
| **HDMI 顶层** | ✅ | `rtl/top/dmz_eg4s20_hdmi_top.v`：全系统**单一时钟域**（25MHz 像素时钟），含 PLL/复位同步器/键盘/测试图/数码管/LED/蜂鸣器，PLL 锁定指示输出到 LED[4] |
| **HDMI 约束** | ✅ | `constraints/dmz_eg4s20_hdmi.adc`：35 个 IO，含 HDMI 四对差分 `CLK=P1/D0=N1/D1=P4/D2=J3`（LVDS33） |
| **TD 工程搭建** | ✅ | `project/hdmi_td.al`（手写工程文件）：**26 Verilog + 5 VHDL（含 4 个官方加密核）+ 1 ADC**，CompileOrder 按依赖排序。**2026-10-25 修复**：此前该文件自提交 `e41315a` 起只列 9 个 Verilog 源，而顶层例化了 12 个彼时缺失的模块（`sdram_pll`、`sdram_ctrl_wrap`、`async_fifo`、`fat32_reader`、`bmp_parser`、`img_loader`、`framebuf_arbiter`、`pix_reader`、`player_ctrl`、`sd_spi_ctrl`、`sd_probe`、`image_player`），elaborate 报 6 条 `HDL-7144` + 6 条 `HDL-8007` 后 exit 4 —— **正式顶层此前根本无法构建**。补全后 elaborate exit 0 |
| **工程同步机制** | ✅ | `scripts/sync_src.ps1` 升级为**双工程同步**（bringup_td + hdmi_td），带 MD5 增量比对与同步后 lint 双查 |
| 静态检查 | ✅ | lint 26 文件：E0/E1/E2 全 0；ModelSim 语法检查：新增 2 模块编译通过 |
| **TD 综合布线** | ✅ | 2026-10-25 修复 `.al` 后跑通完整 `flow_s6_bit.tcl`：`S6_PASS-optimize_rtl` → `optimize_gate` → `place` → `route` → `S6_BIT_FLOW_DONE`。**注意：流程跑通不等于时序收敛**，`S6_TIMING_FAILED: setup=-7.232 ns hold=0.023 ns`，脚本 exit 3，bit 仅作候选 |
| 上板点亮 | ⬜ | 显示器稳定锁定 ≥30 分钟无异常。**正式顶层至今无上板记录**（唯一上板证据来自独立诊断工程 `image_dm_fix`） |
| 记录分辨率与时序参数 | ⬜ | reports/hdmi_timing_report.md |

**阶段出口准则**：显示器稳定锁定 ≥30 分钟无异常。

**技术风险与备选方案**：
1. **加密核 license**：若 TD 报 license 错误 → 改走自研 TMDS（OSERDES + 自写 8b/10b 编码器）
2. **PLL 不锁定**：若 LED[4] 不亮 → 用 TD IP Generator 重新生成 PLL（GUI 自动计算环路参数）
3. **25MHz vs 25.175MHz**：偏差 0.7%（场频 59.58Hz），绝大多数显示器可接受；若某显示器不锁定，改用 PLL 生成 25.175MHz 近似值

## 阶段四：资源读取与帧缓存 ⬜

前置条件：阶段三完成。

| 任务 | 状态 | 交付物 |
|---|---|---|
| SD 卡初始化与扇区读取 | ✅ 仿真通过 | `rtl/storage/sd_spi_ctrl.v`、`tb_sd_spi_protocol`/`tb_sd_spi_ctrl`/`tb_sd_probe` |
| FAT32 短名定位与簇链遍历 | ✅ 仿真通过 | `rtl/storage/fat32_reader.v`、`tb_fat32_reader` |
| BMP 解析（24 位非压缩起步） | ✅ 仿真通过 | `rtl/storage/bmp_parser.v`、`tb_bmp_parser` |
| 跨时钟域 FIFO | ✅ 仿真通过 | `rtl/common/async_fifo.v`、`tb_async_fifo` |
| SDRAM 帧缓存写入/读出（仲裁层） | 🔶 仿真通过，未上板 | `rtl/storage/framebuf_arbiter.v`、`tb_framebuf_arbiter` |
| SDRAM 控制器封装（加密核 ⇄ 行为模型） | 🔶 仿真通过，已综合（150MHz 收敛） | `rtl/storage/sdram_ctrl_wrap.v`、`tb_sdram_ctrl_wrap` |
| SDRAM 专用 150MHz 时钟 | ✅ TD 综合收敛（SWNS +0.104ns，Fmax 152.4MHz） | `rtl/storage/sdram_pll.v`、`sdram_bringup_top`、`progress.md` §S5-4 |
| 完整链路：SD→BMP→SDRAM→HDMI | ⬜ | 单图显示记录 |

**阶段出口准则**：单张图片完整、无失真显示。

## 阶段五：基础播放系统 ⬜

前置条件：阶段四完成。

| 任务 | 状态 | 交付物 |
|---|---|---|
| 多图片切换（上一张/下一张） | 🔶 | `gallery_probe` 图库自动扫描 + `player_ctrl` 切图逻辑已仿真通过；切图的实际装载尚未上板 |
| 自动轮播 + 播放/暂停 | 🔶 | `player_ctrl` 轮播定时器与暂停逻辑已仿真通过（tb_player_ctrl 94 条 PASS），且轮播间隔可经 KEY9 运行时缩放；未上板 |
| 基础音频输出 | ⬜ | rtl/audio, audio_test |
| 音视频联动（页面→音频关联） | ⬜ | 联动记录 |
| 错误状态提示（缺图/格式错） | 🔶 | 图库扫描失败/装载失败已映射到 LED[7] 与数码管第 4 位（1=SD、2=装载、3=图库）；未上板 |
| 状态显示（数码管/LED/画面状态栏） | 🔶 | LED 8 位与 4 位数码管已接线（含图库失败码）；未上板 |

**阶段出口准则**：基础验收标准 A1~A9 全部通过（见 project_definition.md 第六节）。

> **图库自动扫描已补齐（2026-10-25，S7 前置切片）**：原顶层用编译参数 `GALLERY_COUNT=1` 写死张数，换卡必须重新综合。新增 `rtl/storage/gallery_probe.v`，在 `sd_ok` 上升沿后从 `IMG001.BMP` 起逐个探测根目录，遇第一个缺失即停（err=4 视为正常结束），上限 31 张，输出 `count` 给 `player_ctrl.gallery_count`、`done` 给 `gallery_valid`，并在完成时发 1 拍 `first_img_req` 装载首图（满足 `player_ctrl` 文件头【五】对顶层的首图脉冲要求）。`parameter GALLERY_COUNT` 已从顶层删除。SD 总线仲裁由二选一扩成 `sd_probe → gallery_probe → image_player` 三段严格串行。**仿真已闭环，仍未上板。**

## 阶段六：扩展功能 🔶

前置条件：阶段五出口准则通过。**每加一项必须回归验证基础功能。**

| 任务 | 状态 | 交付物 |
|---|---|---|
| B1 图层叠加与字幕 | 🔶 | `rtl/video/video_overlay.v`：九宫格参考线（KEY11）、底部 12 格信息条（KEY12）、右侧音频电平条（KEY13）。**只有位图块，没有字符字形，显示不了文字字幕**；`rtl/osd/` 仍为空。未上板 |
| B2 淡入淡出转场 | ⬜ | rtl/video/transition, 转场测试 |
| B3 实时参数调节与 OSD | 🔶 | 亮度五档（KEY7）、反色（KEY8）、轮播倍率 ×1~×4（KEY9）均运行时可调；参数值经 KEY12 信息条可见。**不保存、无菜单入口**。未上板 |
| C1 音频可视化（音量柱起步） | 🔶 | `video_overlay` 内电平柱直接取 PCM 幅度（取绝对值后映射 bit[20:14] 到 0~127 像素），KEY13 开关。**无 FFT，不是频谱**。未上板 |
| C2 图片自适应缩放（视余力） | ⬜ | 缩放模块 |

> **本轮（2026-10-26，S9）把 B1/B3/C1 从零起点推到"有第一层实现"**：三个能力合并在一个纯组合模块 `video_overlay` 里完成，
> 零 BRAM、零新增时钟域、零寄存器。它们共用的关键是"像素坐标 + 当前参数 → 输出颜色"这一条纯组合通路。
> **三项都只有仿真证据，且都没有重新综合布线。**

**阶段出口准则**：至少 B1+B2 稳定完成且回归通过。

## 阶段七：工程验证与比赛材料 ⬜

前置条件：阶段六完成（或达到可交付状态）。

| 任务 | 状态 | 交付物 |
|---|---|---|
| 长时间运行测试（≥2h 轮播+音频） | ⬜ | reports/verification_report.md |
| 异常注入（坏卡/缺图/拔插显示） | ⬜ | 异常测试记录 |
| 资源占用与时序收敛报告 | ⬜ | reports/resource_report.md, timing_report.md |
| 演示脚本与彩排 | ⬜ | demo/demo_script.md |
| 设计报告与答辩 PPT | ⬜ | docs/defense_outline.md + PPT |
| 演示视频 | ⬜ | demo/ |
| 最终打包提交 | ⬜ | 提交包 |

---

## 代码审查记录（第四轮 · 全 RTL 复审，2026-10-06）

**范围**：`rtl/` 全部 11 个 .v + 2 个 testbench（逐行复审，非抽查）
**回归结果**：lint E0/E1/E2 全 0 → 11 模块 ModelSim 编译零错误零警告 → `tb_seg_scan4` 全 PASS → `tb_dmz_eg4s20_bringup` 全 PASS（含新增 T3b 防误触发检查）

| 编号 | 级别 | 位置 | 问题与修复 |
|---|---|---|---|
| R1 | 🔴 blocker | bringup_top | LED 拼接仅 7 位 `{pattern_sel, status_led}` 赋给 8 位端口 → `led[7]` 恒 0 + 位宽告警。改为 `{1'b0, pattern_sel, status_led}` |
| R2 | 🔴 blocker | bringup_top | **一键双功能**：`player_ctrl` 用 KEY0/KEY1 切图，顶层又用其切图案 → 一次按键触发两种行为。图案切换改用 **KEY4/KEY5**；TB 新增 T3b 专门验证 KEY1 不再误触发图案 |
| R3 | 🟠 major | player_ctrl | `img_index` 越界：SD 重扫描后 `gallery_count` 变小，旧索引可能 ≥ 图数。在主控 else-if 链末新增最低优先级分支：越界时回绕到 0 并重发切图请求 |
| R4 | 🟠 major | video_timing_gen | `frame_start` 在 `v_cnt == V_ACT_START` 的行末发出 = 有效区**第一行末尾**（晚一整行），与"有效区首行前"注释语义不符。改为 `V_ACT_START - 1` 的行末 |
| R5 | 🟠 major | player_ctrl | `seg_status[15:0]` 为死信号（bringup_top 未使用），且位定义/注释/实现三方不一致。移除该端口（YAGNI）；将来 SD 状态显示时改加 4 位 `sd_status` |
| R6 | 🟡 minor | player_ctrl | `status_led` 注释称 bit0=auto / bit1=应急，实现却是 bit1=auto / bit2=应急。实现改为 `{2'b00, emerg, auto}`，与注释一致 |
| R7 | 🟡 minor | 4 处 | 数码管注释仍写"段高亮"，实为**低电平点亮**。min_top ×2 / bringup_top ×1 / seg_scan4 ×1 全部更正 |
| R8 | 🟡 minor | seg_scan4 | `SCAN_HZ` 注释写"每位刷新率"，实为整轮刷新率（每位 = SCAN_HZ/4）。注释更正 |
| R9 | 🔧 改进 | scripts/ | rtl→src 手工同步的技术债：新增 **`scripts/sync_src.ps1`**（MD5 增量比对 + 同步后自动 lint 双查；UTF-8 BOM 确保 Windows PowerShell 5.1 可执行）。首次运行即发现 `key_matrix_4x4.v` 两边本已不一致——印证该债务真实存在 |

**有意保留未改（附理由）**：

- `bringup_top` 中 `img_switch_req` / `auto_play_en` / `key_state` 暂未使用 → 属**预留接口**（阶段四接帧缓存、阶段六接 OSD），综合器会自动优化掉，已加注释说明；
- `test_pattern_gen` 渐变亮度范围仅 0~79（偏暗）→ 视觉优化项，不影响功能，阶段三美化时再调；
- 复位未做同步释放 → 注释已说明原因，上板若发现抖动问题再补。

**新增协作规范**（已同步写入 `ai_handover.md` 硬性约束）：

> 同一按键不得被两个模块同时用作功能触发；新增按键功能前先查 `bringup_top` 顶部的键位分配表。

## 代码规范变更（第五轮 · 清除 RTL 中的 function，2026-10-16）

**用户要求**：「把代码中的函数都删掉」
**范围**：`rtl/` 全部 .v + 两个 TD 工程副本

**删除清单（2 处、共 3 个函数）**：

| 位置（原） | 原实现 | 现写法 | 综合结果 |
|---|---|---|---|
| `rtl/input/key_matrix_4x4.v` L251-260 | `function [3:0] prio_code` —— for 遍历 16 位按键位图，低位优先取键号 | **块⑥ 组合 `always @(*)`** 算出 `key_code_nxt`，块⑦ 时序寄存为 `key_code` | 完全等价 |
| `rtl/control/player_ctrl.v` L173-178 | `function [4:0] next_idx` / `prev_idx` —— 带环绕的索引推进 | 三个调用点（KEY1 下一张 / KEY0 上一张 / 轮播到点）**就地内联三元表达式** | 完全等价 |

**为什么删（三条理由）**：

1. Verilog `function` 综合后本就是**纯组合逻辑**（由综合器内联展开），改写成显式
   `always @(*)` 或就地表达式**不改变任何综合结果** —— 已由本轮回归实测确认；
2. 显式写法让逻辑**直接体现在波形里**：原 `prio_code` 的编码过程在波形窗口中完全不可见，
   现在 `key_code_nxt` 是可见的中间节点，调试时能直接看出"哪一位赢出"；
3. 免去"读一段代码要跳到文件别处对照函数定义"的认知负担，赋值右侧即是完整语义。

**配套改动（保持文档-代码一致）**：

- `key_matrix_4x4.v`：内部逻辑块 **6 → 7 块**（新增块⑥ 组合优先级编码；原块⑥"按下沿检测"
  顺延为块⑦），文件头块清单与【四、设计思路与范式】的 `[6] 优先级编码函数` 条目同步更新；
- `player_ctrl.v`：内部逻辑块描述 "共 3 块 + 2 个函数" → "共 2 块 + 1 处内联表达式"，
  并新增"图号推进规则"注释段（含 `gallery_count - 1` 下溢的安全前提说明）；
- `docs/design_patterns.md`：组合逻辑范式实例 `prio_code 函数` →
  `块⑥ 优先级编码（组合 always + for 展开）`；
- `docs/ai_handover.md`：新增硬性约束 **0c**（RTL 层不使用 `function`/`task`）。

**有意保留（附理由）**：`sim/testbench/*.v` 中 5 个 `task`（`press_key` / `check_pixel` /
`check_blanking` / `dump_frame` / `chk`）**保留不删** —— 它们只在仿真中使用、**不参与综合**，
且封装的是一次激励/检查序列（如 `press_key` 含矩阵扫描 + 消抖等待全过程），展开只会让
testbench 膨胀数倍且更难维护。

**回归结果（2026-10-16）**：

- `scripts/lint_verilog.py`：26 个文件，**E0/E1/E2 全 0**；
- `scripts/sync_src.ps1`：2/20 个副本更新（两个工程的 `key_matrix_4x4.v`）；
- ModelSim 编译：**0 错误 0 警告**；`tb_dmz_eg4s20_bringup` → **ALL CHECKS PASSED, errors = 0**
  - T3a `KEY5 → pattern_sel=1` —— 验证块⑥ 组合优先级编码 → 块⑦ 寄存 的完整链路；
  - T3b `KEY1 → img_index=1`，且 `pattern_sel` 保持 1、`mode=0` —— 验证内联三元表达式的
    图号推进正确，同时复验"一键双功能"问题未回归。

## 代码审查（第五轮 · 阶段三 HDMI 深度审查，2026-10-17）

完整报告见 **[code_review_round5.md](code_review_round5.md)**。核心结论：

- **blocker×2 全修**：① SDC 缺失 → 新增 `constraints/dmz_eg4s20_hdmi.sdc` 挂进
  `hdmi_td.al`，时序分析从"50MHz 单域虚假全绿"变为 **3 时钟域全分析、0 违例**
  （clk_pixel 25MHz / clk_5x 125MHz / clk 50MHz，SWNS 5.895ns，1750 路径）；
  ② 音频缺失（赛规基础要求③）登记为 blocker，本轮不实施（A1 待决策）。
- **赛规对照表**落成（5 基础项 + 5 扩展项逐条对标）；"报备自购平台"待办
  **撤销**（赛规 p.34 明文自购合法）。
- 工具链沉淀：TD 6.2 的 `rename_clock` 双语法均失效（USR-8124/8125/8130），
  需用 `create_generated_clock` 命名（USR-6122 override 警告为预期）；手写
  `.al` 的 `<LABEL>` 必须留空；headless 跑 TD 时 CWD 必须是工程目录。
- 待办优先级：A1 音频决策 > A2 ChipWatcher 抓信号 > A3 HDMI 上板 > A4 收尾。

## A1 音频闭环（PWM 快速通路，2026-10-16）

用户拍板"先 PWM 快速闭环"（HDMI 音频/换 APUG092 链列入扩展加分阶段再评审）。

- 新增 `rtl/audio/pwm_audio_out.v`：DDS 相位累加（FTW = FREQ_HZ×2³²/CLK_FREQ_HZ，
  440Hz→75594）+ 一行三元三角波表（phase_acc[31] 方向位取反 = 下降半周，替代
  256 点 ROM）+ 8bit PWM 载波（f_clk/256≈97.7kHz 带外）。含四层注释体系。
- 顶层 `dmz_eg4s20_hdmi_top.v` 新增块 [10] 与端口 `audio_pwm`（球 F3，
  LVCMOS33，IO 35→36）；`constraints/dmz_eg4s20_hdmi.adc` §5b；`hdmi_td.al`
  登记 CompileOrder 5（hdmi_pll 8、top 14 顺延）。
- 仿真 `sim/testbench/tb_pwm_audio_out.v`：T1 复位静音 / T2 音高 20/20 周期 /
  T3 单调性 0 违例 / T4 占空比跟踪（窗口落波谷跳过）/ T4b 平均占空比 49% /
  T5 mute —— **全 PASS**；tb 踩坑：ModelSim 10.1d 的 `$sformatf` 结果不能隐式
  转 packed task 参数，数值统计改 `$display` + chk 传静态文本。
- headless 重跑全流程 PASS：SWNS 6.421ns / HWNS 0.030ns / **0 违例**
  （clk_pixel fanout 279、clk_5x fanout 32），音频模块零时序代价。
- `sync_src.ps1` 补 pwm_audio_out 映射（首轮 headless 报 black box 即此漏项）；
  SDC 映射上一轮已加，A4 收尾完成。
- 赛规基础要求③：❌→✅（测试音级，音乐播放待阶段五资源通路）。

## S2 上板 err=7 根因：SD 命令间隔 Ncc 违规（2026-10-17）

用户首烧 S2 探针后数码管次右位报 7（读块 R1 超时）。逐层排查结论：

- **现象**：LED D4=locked 正常、D3=sd_fail、错误码 7；初始化链 CMD0/CMD8/
  ACMD41 全通（否则码 1~3），只有 CMD17 被卡吞掉。
- **根因**：SD 规范 Ncc 要求两条命令之间至少 8 个 SCK 时钟（CS 保持低，
  卡靠这段时钟完成内部命令状态复位）。实测我们的间隙 SCK **停着不翻**
  （sck_en 无来源）、时长仅约 360ns → 卡数到的时钟沿 = 0 个 → CMD17
  整帧被丢弃 → MISO 恒高 → Ncr 超时 → err 7。
- **为什么仿真测不出**：tb 卡模型从不检查 Ncc。这是本模块唯一无法靠
  ModelSim 暴露的时序约束——**协议合规性缺陷只能靠真卡暴露**。
- **修复**：`sd_spi_ctrl.v` 新增参数 `NCC_CYCLES = 8`，块[2a] 发送器改
  「Ncc 填充段 + 帧发送段」两段式：xact_start 拍锁帧但不上总线，SCK
  空翻满 8 个下降沿后才预置 start=0。两个关键约束：
  ①**数 fall 不数 rise**——数 rise 时预置的 start 位会在紧随的 fall 被
  移走而没有 rise 采样，整帧错位 1 位；
  ②接收器复位条件补 `ncc_run`——填充段 tx_active=0 而 xact_busy=1，
  若放行会让 ncr_cnt 多计 56 拍逼近 NCR_TIMEOUT 上限产生误超时。
- 修复只动发送器层，三处序列机（初始化/读块）全链受益；慢速 INIT 相
  （390.6kHz）因 Ncc 数的是 SCK 周期数而非 clk 拍数，自动同样合规。

**踩坑教训（重要）**：`{40'hFFFF_FFFF, 8'hXX}` 是位宽补零陷阱——40 位
宽的 0xFFFF_FFFF 高位补 0，出位变成 8 个 0 被当成起始位。前导 1 的帧头
必须写全位宽值 `{8'hFF, 32'hFFFF_FFFF, ...}`。

验证：lint 32 文件 E0/E1/E2=0；tb_sd_spi_ctrl T1~T7、tb_sd_probe T1~T4、
tb_seg_scan4、tb_pwm_audio_out、tb_dmz_eg4s20_bringup 全绿；
STA SWNS 6.295ns / HWNS 0.038ns / 0 违例；新 bit 629,640B。

## S2 上板 err=1：Ncc 填充位置错误（2026-10-17 晚）

err=7 修复上板后现象变为 **err=1（CMD0 重试用尽）**——比 err=7 更早失败，
说明干预点确实命中了命令帧，但方向错了。

- **根因一（8753d82）**：上一版把 Ncc 的 8 个填充 SCK 放在 **CS 已拉低之后**
  （发送器两段式）。真卡把填充位当成 CS 拉低后的头一个字节流，整条命令位序
  错位，连 CMD0 都无应答。修正为引擎级约束：**Ncc 必须在 CS 保持高期间补足**。
- **根因二（f620729）**：`ncc_ready = ~ncc_need` 在 CS 刚变高的那一拍仍为 1
  （块[1b] 的 `ncc_need` 是 NBA，下一拍才生效），状态机立刻又把 CS 拉低，
  CS 只高了 1 拍、Ncc 一个时钟都没补。修正：就绪判定**排除 CS 上升沿**。

## S2 上板 err=2：ACMD41 应答格式与默认参数截断（2026-10-19，460163e）

err=1 修复后现象变为 **err=2（CMD8/CMD55 异常）、LED0 仍灭**。本轮改用独立协议
回归逐条证伪，暴露三类缺陷（均属"仿真测不出、真卡才暴"）：

| # | 缺陷 | 机理 | 修复 |
|---|---|---|---|
| 1 | ACMD41 应答格式 | SD 规范中 ACMD41 **只返回 R1（8 位）**，旧实现按 40 位长应答接收，卡在 R1 之后给出的位被误当载荷，初始化判据整体偏移。**既有仿真的卡模型按同样错误格式应答，所以"仿真通过"是假绿** | 应答接收器按 `xact_r40` 区分：CMD8/CMD58 收 40 位，ACMD41 只收 R1 |
| 2 | 默认参数截断 | `ACMD41_LOOPS=65536` 需 17 位、`TOKEN_TIMEOUT=1048576` 需 21 位，比较时被 16/20 位切片截成 **0** → 默认参数下等价"立即超时"。仿真改小参数恰好绕开 | `c41_loop` 用 17 位；参数上限**完整比较**，禁止截断 |
| 3 | 位级边界 | ① 48 位命令未等第 48 个 rise 采到 stop 就交出发送权，慢分频下提前把卡 DO 当应答；② CMD17 的 R1 与读块机之间丢令牌首位（`FAST_DIV=1`）；③ 令牌用跨字节滑窗判定，会把 `FF`+错误令牌误判成 `FE` | 命令发送等第 48 个 rise；R1 由位接收器直连读块机；令牌按完整 8 位字节判定 |

**新增独立回归 `sim/testbench/tb_sd_spi_protocol.v`**（本轮关键资产）：

- 卡模型使用真实 R1/R3/R7 格式与**默认参数**（`LOOP_LIMIT=65536`、
  `TOKEN_LIMIT=1048576`、`POWERUP_DELAY=131071`），不读 DUT 内部状态；
- 卡模型**不随 `rst_n` 复位** idle/app 状态——复现"主机复位 ≠ 卡断电"的真实行为；
- 覆盖：命令期间 DO 被拉低不误判为应答、传输中途复位、初始化轮询收敛、
  载荷阶段复位后主机恢复、连续 FF 令牌超时、非 SDHC 拒绝、帧与参数合法性。

**验证（2026-10-19 00:18，ModelSim 10.1d）**：

- `tb_sd_spi_protocol` → **ALL CHECKS PASSED**（11 项）
- `tb_sd_spi_ctrl` → **ALL CHECKS PASSED, errors = 0**（含 T8 Ncc 间隔 ≥8 SCK）
- `tb_sd_probe` → **ALL CHECKS PASSED, errors = 0**
- `python scripts/lint_verilog.py rtl project/src` → 21 文件，**E0/E1/E2 全 0**

**同时修正的工程问题**：`project/hdmi_td.al` 曾丢失 `hdmi/sd_spi_ctrl.v`、
`hdmi/sd_probe.v` 两个文件条目（TD 打开工程时被清理），而顶层第 419/441 行
明确例化了它们 → 综合会得到 black box，**SD 逻辑根本不进 bit**。已还原。
排查"LED0 灭"时必须先确认这两个条目在位，否则代码再对也无效。

**bit 已重新生成并复核**（2026-10-19 00:16:49）：
`project/hdmi_td_Runs/phy_1/hdmi_td.bit` 629640 字节；TD 日志
`project/td_20261019_001625.log` 显示流程走完，
`SWNS: 6.254, STNS: 0.000, Hold WNS: 0.038, FEP: 0`，0 违例。
`reports/hdmi_area.txt` 层次表证明 SD 逻辑**确实进了 bit**（非 black box）：
`u_sd | sd_spi_ctrl | le=535 lut=447 seq=333`、`u_probe | sd_probe | le=72 lut=58 seq=53`。
整体：IO 41/188，#lut 1586/19600（8.09%），#reg 866，#bram 0，#dsp 0，#pll 1，#gclk 1。
管脚：SD=SCK F15 / CS F13 / MOSI F14 / MISO D14；HDMI=P1/N1/P4/J3（LVDS33）；
音频 F3；复位 E3；时钟 R7（50MHz）。

**仍未验证**：真卡上板行为（本轮无人在板边。上板步骤见
`docs/session_handover_2026-10-19.md`）。

## P2-6：新增「初始化中途主机复位」回归 T12（2026-10-19）

旧界面缺口：`tb_sd_spi_protocol.v` 原有 T7 是初始化**完成后**的热复位，
T9 是**传输中途**复位，而「初始化过程之中被硬复位」一直是空白。

**新增内容**（`sim/testbench/tb_sd_spi_protocol.v`）：

1. 新增 `rerun_initialization` task（**不复位主机**，只等 `POWERUP_DELAY+10` 拍后发
   `init_start` 并等终态）。若复用 `start_initialization`，它开头的 `rst_n=0`
   会把 T12 制造的「中途现场」二次清掉，测不到真正的中途恢复。
   `start_initialization` 原样保留。
2. T12 五轮：分别在「80 空时钟窗口」与「第 1..4 个命令窗口 + 24 拍」处打断，
   再拉低 `rst_n` 五拍后释放，然后重跑初始化并读一个块；
   `card_idle`/`busy_polls`/`ncr_bytes` 按 scenario 交替变化。
3. T12 头部注释明确边界：本场景检验的是**主机侧**（序列机 / 事务引擎 / 分频器
   能否从任意中途状态经硬复位恢复干净并重建字节边界），
   **不以卡被动就绪为前提**——因为重跑初始化必然先发 CMD0（GO_IDLE_STATE）
   把卡拉回 idle，“卡不断电所以 CMD8 会收到 R1=00”的推断不成立。

**实跑（ModelSim 10.1d）**：默认参数 `ALL CHECKS PASSED`；
`-gINIT_DIV={1,2,3,4} -gLOOP_LIMIT=16 -gTOKEN_LIMIT=2048 -gPOWERUP_DELAY=100` 下**各 62 PASS / 0 FAIL**。

## T12 变异测试：能力边界的诚实记录（2026-10-19）

目的：验证 T12 是否真能杀欠陷，而非永远假绿。全部在独立库 `mutlib_N` 中编译，
跑 `-gINIT_DIV=2 -gLOOP_LIMIT=16 -gTOKEN_LIMIT=2048 -gPOWERUP_DELAY=100`，完成后已全部删除。

| # | 变异（均针对 `rtl/storage/sd_spi_ctrl.v`） | 结果 |
|---|---|---|
| mut1 | 删 `tx_bit_cnt <= 6'd0;` | 62 PASS 0 FAIL（未杀死）|
| mut2 | 复位不释放读块片选 `cs_n_b <= cs_n_b` | 23 PASS **9 FAIL**（由 T1–T4 杀死，非 T12）|
| mut3 | 复位时 `tx_active` 保留 | 0 FAIL（未杀死）|
| mut4 | 复位时 `cs_n_i` 保留 | 0 FAIL（未杀死）|
| mut5 | 复位时 `xact_busy` 保留 | 0 FAIL（未杀死）|
| mut6 | 复位时 `div_cnt` 保留（SCK 相位残留）| 0 FAIL（未杀死）|
| mut7 | 复位时 `rx_shift` 保留 | 0 FAIL（未杀死）|
| mut8 | 复位时 `tx_shift`/`tx_bit_cnt` 保留 | 0 FAIL（未杀死）|
| mut9 | 删 `st_init <= I_POWERUP;` | **3 FAIL**（T5 SDSC、T6 R7、T11 无卡，非 T12）|
| mut10 | 删 `st_blk <= B_IDLE;` | **8 FAIL**（T1/T4/T9/T10 等块读与传输中途复位，非 T12）|

**结论（不得美化）**：T12 全过，但**没有任何一个变异体是被 T12 单独或首个捕获的**。
mut9/mut10 由既有 T5/T6/T9/T10/T11 捕获，mut2 由 T1–T4 捕获，其余 6 个变异被 RTL
中其它路径自然吸收。即：T12 目前具备**回归防回退**价值（守护「中途复位可恢复」
不被后续改坏），但**尚未证明能独立发现新缺陷**。
不得据此写「T12 证明中途复位健壮」这类超出证据的话。

**测试计数陷阱（吹遭过，勿重犯）**：用 `Select-String -Pattern '^# FAIL|CHECKS FAILED|TIMEOUT'`
统计得到 `FAIL_lines=3` 的误报——`CHECKS FAILED` 中的 `CHECKS` 也会匹配 `ALL CHECKS PASSED`。
正确做法是 `Where-Object { $_ -like '*# FAIL:*' }` 精确匹配。


## S3 fat32_reader：FAT32 短名定位与簇链遍历（2026-10-19，8da42df）

### 实现
`rtl/storage/fat32_reader.v`（541 行）按 `docs/phase4_architecture.md` 的 S3 切片实现：

1. **MBR**：读 LBA 0，取分区表项 0 的起始 LBA（绝对偏移 454~457，低字节在前），
   校验签名 `0x55AA`。
2. **VBR/BPB**：读分区起始扇区，取 `+0x0D` sectors_per_cluster、
   `+0x0E` reserved_sectors、`+0x10` num_fats、`+0x24` fat_size_sectors、
   `+0x2C` root_cluster，校验签名与 spc 合法性（非 0 且为 2 的幂）。
   换算 `fat_begin = part + reserved`、`data_begin = fat_begin + num_fats × fat_size`。
3. **根目录**：遍历 32B 目录项，按 `IMGnnn.BMP` 的 8.3 短名逐字节匹配
   （大小写不敏感），跳过 LFN(0x0F)、卷标(0x08)、目录(0x10) 与已删除项(0xE5)。
   命中后取 `+0x14` 首簇高 16 位、`+0x1A` 首簇低 16 位、`+0x1C` 文件大小。
4. **簇链**：本簇内扇区读尽后沿 FAT 表取下一簇，深度受 `FAT_CHAIN_MAX`
   限制（默认 64），防死循环。

**错误码**：1=MBR 签名错 2=VBR/BPB 非法 3=簇链异常 4=未找到
5=底层读块失败 6=参数非法（img_index=0）。

### 两个正交状态维度
- `st` = S_IDLE / S_REQ / S_RX / S_EVAL / S_DONE / S_FAIL —— 块级握手
- `stage` = ST_MBR / ST_VBR / ST_DIR / ST_FAT —— 语义阶段

**S_EVAL 为什么是必要的第 5 态**：块数据在 always 块②捕获、主序列机在块①
判定，若在 `blk_done` 那一拍直接判定，读到的是上一拍的捕获寄存器值。
隔一拍再判定才能看到完整数据。

### 其他实现要点
- `cap_clr` 是跨块清零脉冲，捕获寄存器只由块②驱动，主序列机绝不直接赋值
  （避免 E2 多驱动）。
- `name_hit`（本项命中）与 `dir_hit`（本块命中）必须分开：一个 512B 目录扇区
  有 16 个 32B 项，命中项在前、后续项仍会把 `name_hit` 清掉，所以块级另记
  `dir_hit`（只由 `cap_clr` 清）。
- `nm_bad` 必须在**每个 32B 项的首字节处重新赋值**，否则前一项的"不符"会
  保留到后面所有项，导致永远不命中。
- 序号拆分**不用除法**（`img_index/100` 会引出 9 位除法器），改用「逐级减
  100/10」比较减法链（always 块③）。
- 共 4 个 always 块：①主序列机 ②字节捕获 ③序号拆分 ④短名期望译码。

### 验证
`sim/testbench/tb_fat32_reader.v`（625 行）：17 个场景 / **30 项检查全 PASS**。
内置扇区读取模型顶替 `sd_spi_ctrl`，磁盘镜像由 `build_image()` 现场构造，
不依赖外部镜像文件，可在任意机器复跑。

场景清单：T01 正常命中、T02 小写短名、T03 目录项不算文件、T04 序号不存在、
T05 目录跨簇、T06 LFN/卷标跳过、T07 MBR 签名坏、T08 VBR 签名坏、T09 spc=0、
T10 spc=3（非 2 的幂）、T11 目录簇链尾提前结束、T12 FAT[2]=0、T13 底层读块
失败、T14 序号 0、T15 分区 LBA=0、T16 首簇高 16 位非零、T17 FAT 项落在保留区。

参数扫描 `-gFAT_CHAIN_MAX={2,4,8,16,32,64}` 各 30 PASS / 0 FAIL。

### 变异测试：11/11 全部杀死
与 T12 的 0/10 形成对照。变异体全部针对 `rtl/storage/fat32_reader.v`：

| # | 变异 | 被谁杀死 |
|---|---|---|
| m1 | 分区表偏移 454 → 450 | T01（19 项 FAIL）|
| m2 | 漏 MBR 签名高字节 | T01（23 项 FAIL）|
| m3 | 属性掩码 0x18 → 0x08（漏目录位）| T03 |
| m4 | 短名比较改成大小写敏感 | T02 |
| m5 | 项首字节不重置 nm_bad | 越界检测（addr=268435197）|
| m6 | FAT 链尾阈值 0x0FFFFFF8 → 0x0FFFFFF0 | T17 |
| m7 | 簇首扇区少减 2 | T05 |
| m8 | spc 非法检查放宽 | T09 |
| m9 | 文件名不认大写 'I' | T01 |
| m10 | 不回填首簇高 16 位 | T16 |
| m11 | 去掉保留区上界拦截 | 越界检测（addr=268435445）|

### 变异测试暴露并修正的真实缺陷与 tb 缺口（重要）
这一轮变异测试的价值不在"11/11 全杀"，而在它逼出了 5 个真问题：

1. **RTL 真实缺陷**：原 `ST_FAT` 只拦 `fat_entry < 2`，未拦
   `0x0FFFFFF0~0x0FFFFFF7` 保留区。该类值既非有效簇号（FAT32 规范上界
   `0x0FFFFFEF`）也非 EOC（下沿 `0x0FFFFFF8`），会被当成有效簇号，
   算出 `data_begin + (N-2)×spc` 是一个天文 LBA。已补上界拦截。
2. **tb 缺口**：分区起始 LBA 原取 1，字节序 `01 00 00 00` 与「偏移 450 处
   分区类型+CHS」值域高度混淆，RTL 把 454 错写成 450 也能读出近似结果。
   → 改取 4。
3. **tb 缺口**：FAT 链尾原全用 `0x0FFFFFFF`，未覆盖 EOC 区间下沿。
   → SC_CHAINEND 改用 `0x0FFFFFF8`，新增 SC_RSV 用 `0x0FFFFFF0`。
4. **tb 缺口**：首簇原全 < 65536，高 16 位恒 0，把
   `hit_clu_hi[15:8]` 的赋值删掉也不会产生任何差异。
   → 新增 SC_HICLU 用 `0x01010005`（高 16 位两个字节都非零）。
   第一次改成 `0x00010005` 仍不够——高字节仍是 0x00，m10 继续存活。
5. **tb 缺口（最关键）**：卡模型对越界 LBA 静默返回垃圾数据，导致
   「读到越界数据 → 簇链耗尽 → 撞 FAT_CHAIN_MAX 兜底」这条错误路径
   最终也报 err=3，与正确的「FAT 项拦截」**无法区分**。断言只看错误
   码不足以证明拦截生效。→ 增加越界检测断言 `oob_hits == 0`。

### 全量回归
| 测试平台 | PASS |
|---|---|
| tb_sd_spi_protocol | 62 |
| tb_sd_spi_ctrl | 23 |
| tb_sd_probe | 14 |
| tb_fat32_reader | 30 |

lint：34 文件 `E0=0 E1=0 E2=0`。

### 配套修正
`scripts/sync_src.ps1` 增加 `rtl\storage\fat32_reader.v → project\hdmi\fat32_reader.v`
同步条目。原脚本无此条目，会导致主源无法进入 TD 工程（`project/hdmi/` 下
根本没有该文件），属于「加了源文件却忘了同步」的同类欠账，与
`55a92e9` 修掉的 `sd_spi_ctrl.v` 落后问题同源。

### 边界说明
- **尚未上板验证**：S3 的验证方式按架构文档就是「仿真（盘镜像文件作模拟卡）」，
  全链上板要等 S6。
- **顶层尚未例化**：`dmz_eg4s20_hdmi_top.v` 里只有 `u_sd` 与 `u_probe`，
  没有 `u_fat32`。这是有意的——S6 全链才需要接入，提前接入会增大 bit 面积
  却无法在上板前验证收益。
- **未覆盖路径**：FAT 备份副本（num_fats>1 时只读第一份）、长文件名（LFN
  只做跳过不解析）、跨扇区的 32B 目录项（512/32=16 整除，不会跨界）。

## S4 bmp_parser：BMP 头解析与 24bit→RGB565 转换（2026-10-19）

### 实现
`rtl/storage/bmp_parser.v`（384 行），5 个 always 块：
1. 主序列机第一段 + 2. 第二段：`ST_IDLE / ST_HDR / ST_VALIDATE / ST_PIX` 四态
2. 行尺寸推导（组合逻辑）：`row_bytes = {img_w[14:0],1'b0} + img_w`（= 3×宽），填充 `(4-row_bytes%4)%4`
3. RGB565 打包：`{R[7:3], G[7:2], B[7:3]}`
4. 行坐标反算

头字段偏移：`+0x00` 签名、`+0x0A` 数据偏移、`+0x12` 宽、`+0x16` 高、`+0x1C` 位深、`+0x1E` 压缩方式。
错误码：1=签名非 BM 2=非 24bit 3=有压缩 4=宽高不符 5=行对齐异常 6=数据偏移越界。

**校验为什么要攒到 off_cnt=54 一次性做**：边收边判会让错误码依赖字节到达顺序，且签名、位深、压缩、宽高之间没有先后依赖，一次性判定更清晰。

### 素材陷阱（重要）
`assets/sd_images/img1_640x480.bmp`（rowbytes=1920）与 `img2_320x240.bmp`（rowbytes=960）**行字节数都是 4 的倍数，填充恒为 0**。只用这两张素材做验证，行填充逻辑写错了也发现不了。因此 tb 全部用**现场构造的、宽度不是 4 的倍数的图**：322（pad=2）、321（pad=1）、323（pad=3）。

### 验证：17 个场景 / 38 项检查
`sim/testbench/tb_bmp_parser.v`。黄金图案 `golden_rgb888(gx,gy) = {gx[7:0], gy[7:0], gx[7:0]^gy[7:0]}`——对 x、y 都敏感，行/列互换不会碰巧相同；`golden_rgb565` 按 `{rgb[23:19], rgb[15:10], rgb[7:3]}` 打包。逐像素比对，T01 的 307200 个像素全部一致。

| 用例 | 场景 | 结果 |
|---|---|---|
| T01 | 640×480 自底向上 pad=0 | PASS |
| T02 | 322×240 pad=2 | PASS |
| T03 | 321×120 pad=1 | PASS |
| T04 | 323×60 pad=3 | PASS |
| T05 | 320×240 自顶向下（h<0，不翻转）| PASS |
| T06 | data_off=78（跳过 24 字节间隙）| PASS |
| T07 | 签名两个字节都错 → err=1 | PASS |
| T07b | 仅第二签名字节错、首字节仍是 B → err=1 | PASS |
| T08 | 16bpp → err=2 | PASS |
| T09 | 压缩 BMP → err=3 | PASS |
| T10 | 宽高同时不符 → err=4 | PASS |
| T10b | 仅宽度不符、高度正确 → err=4 | PASS |
| T11 | data_off=50 < 54 → err=6 | PASS |

### 仿真暴露的 2 个 RTL 真缺陷
1. **`data_off > 54` 时的间隙字节被当成像素消费**（T06 发现）。从偏移 54 到 `data_off-1` 之间是调色板/对齐区，原实现直接把它们当 BGR 消费，整幅图向右平移 `(data_off-54)/3` 个像素且颜色错位。修法：新增 `reg [31:0] skip_left`，ST_VALIDATE 通过时置 `data_off-54`，ST_PIX 里优先递减跳过，打包条件加 `skip_left == 0`。
2. **自顶向下布局（height<0）被无条件翻转**（T05 发现）。原实现恒做 `pix_y = img_h-1-src_y`，未区分 `top_down`。修法：新增 `reg top_down`，在取绝对值**之前**锁存 `f_raw_h[31]`，组装改 `pix_y <= top_down ? src_y : (img_h - 1 - src_y)`。
   **注意**：自顶向下的图若被错误翻转，每行像素的**内容仍然正确**，只有坐标断言能抓到——这是仅靠颜色比对发现不了的。

另有 3 个 tb 自身缺陷：`pix_y * img_w` 在位宽 16 的上下文中乘积截断（640 宽到第 103 行溢出，产生 24 万条假"像素重复"）；全局超时不足；负高度写进 32 位字段时没做符号扩展（-240 变成 65296）。

### 变异测试：12/12 全部杀死
| # | 变异 | 结果 |
|---|---|---|
| m1 | 签名只查 B 不查 M | 首轮**存活** → 补 T07b 后杀死 |
| m2 | 不校验位深 | 杀死 |
| m3 | 不校验压缩方式 | 杀死 |
| m4 | 不校验宽高 | 首轮**存活** → 补 T10b 后杀死 |
| m5 | 不跳过 data_off 间隙 | 杀死 |
| m6 | 忽略高度符号（恒翻转）| 杀死 |
| m7 | 行填充恒 0 | 杀死 |
| m8 | RGB565 的 G 取 5 位 | 杀死 |
| m9 | B/G 分量位置互换 | 杀死 |
| m10 | 高度取绝对值有误 | 杀死 |
| m11 | 不校验 data_off 下界 | 杀死 |
| m12 | 行末不推进 src_y | 杀死 |

**两个存活变异体的教训**：T07 让签名两个字节同时错、T10 让宽高同时错——只要 RTL 检查了其中任一项就会失败，于是"只查一个"的变异体存活。**凡是"多条件同时校验"的 RTL，必须补"只错一项"的定向用例**，否则覆盖是假的。

### 回归
| tb | 检查项 | 结果 |
|---|---|---|
| `tb_sd_spi_protocol` | 63 | ALL CHECKS PASSED |
| `tb_sd_spi_ctrl` | 23 | ALL CHECKS PASSED |
| `tb_sd_probe` | 11 | ALL CHECKS PASSED |
| `tb_fat32_reader` | 30 | ALL CHECKS PASSED |
| `tb_bmp_parser` | 38 | ALL CHECKS PASSED |

`python scripts/lint_verilog.py rtl project/src` → 23 个文件，E0=0 E1=0 E2=0。

### 边界
- **尚未上板**，未与真实 SD 卡联调。
- 顶层尚未例化 `fat32_reader` / `bmp_parser`，按设计 S6 才接入。
- `project/hdmi_td.al` 尚未加入两个新文件的条目，`scripts/sync_src.ps1` 已补同步条目（工程副本已同步，`git hash-object` 两侧一致）。
- LFN 长文件名只跳过不解析；只支持 24bit 未压缩 BMP；宽高必须等于参数 `exp_w/exp_h`。

## S5-1 async_fifo：格雷码跨时钟域 FIFO（2026-10-19）

### 为什么 S5 从这个模块开始
S5 要接 ERAM SDRAM，而控制器跑 150MHz、HDMI 像素域跑 25MHz，两域由**两颗独立 PLL**
各自锁定、无任何相位关系。跨域直接传多拍数据必然出现亚稳态采样，表现为**随机花屏**——
偶发、不可复现、看画面根本定位不到。async_fifo 是这条链上唯一的合法跨域通道，
所以先做它、先把它测透。

### 实现
`rtl/common/async_fifo.v`，参数 `DATA_WIDTH=16`、`ADDR_WIDTH=9`。经典 Cummings 结构：
- 指针多 1 位（`PTR_W = ADDR_WIDTH+1`），最高位区分"空"与"满"
- 格雷码 `gray = bin ^ (bin>>1)`，跨域时每次只变 1 bit
- 满判定：`wr_gray_next == {~(rd_gray_wr2[PTR_W-1:PTR_W-2]), rd_gray_wr2[PTR_W-3:0]}`（高 2 位取反）
- 空判定：`rd_gray_next == wr_gray_rd2`
- 两级同步器：`rd_gray→wr 域`、`wr_gray→rd 域`，各打两拍
- `wr_full`/`rd_empty` 均为**寄存器输出**，代价是少用 1 个存储单元，换来判定无毛刺
- 存储用分布式 RAM，`rd_data` 为异步组合输出，读出无额外延迟

调试中发现 Verilog-2001 要求**信号先声明后使用**：`mem` 的写块用到 `wr_bin`，
若 `wr_bin` 声明在后会报 `Undefined variable` 并连带报重复声明。已把全部内部信号
集中声明在 `localparam` 之后。

### 验证：8 个场景 / 26 项检查
`sim/testbench/tb_async_fifo.v`。**时钟刻意取无整数倍关系的 37.5ns 与 13ns**
（≈26.7MHz 与 ≈76.9MHz）——若用 25MHz/50MHz 这种整倍关系，相位固定，某些 CDC
缺陷会因为"总是采在稳定窗口"而测不出来。

| 用例 | 场景 | 结果 |
|---|---|---|
| T01 | 复位后 wr_full=0、rd_empty=1 | PASS |
| T02 | 单写单读，数据正确 | PASS |
| T03 | 写满（额外请求被挡）+ 全排空，接受数==读出数 | PASS |
| T04 | 写读并发流式 300 字 | PASS |
| T05 | 空时读，指针不推进 | PASS |
| T06 | 满时写，写指针冻结、数据不被覆盖 | PASS |
| T07 | 只复位读侧，写侧已缓存数据仍可见 | PASS |
| T08 | 写读两侧随机间隔 400 字压力 | PASS |

核心断言（[A1][A2]）：**格雷码每次跳变必须只差 1 bit**。实测 `gray-code err = 0`。

### 一个设计错误的诊断过程（值得记录）
初版 tb 断言"读出的第 n 个数据必须等于 n"，跑出 `got 23 want 17` 之类的失配。
一度怀疑 RTL 丢数，实际是**测试模型错了**：FIFO 满时 `wr_en` 被 `wr_full` 挡掉，
那些编号**本来就没进 FIFO**，不该出现在读侧。强行要求 `read[n]==n` 等于把
"满时正确丢弃"误判成数据错误。

改成正确的不变量后全绿：
- (a) 读出的编号**严格递增**（FIFO 先进先出的本质，乱序即数据错乱）
- (b) **不重复**（重复 = 指针回绕 bug）
- (c) 收尾断言 **`rd_cnt == wr_cnt`**（最有力的丢数检测）

另有一处 Verilog 陷阱：格雷码断言最初用 `case (xor)` 列 `(1<<0)|(1<<1)|...`，
但 `|` 是**按位或**，那些值会算成 31，case 只匹配 0 或 31，导致所有合法单 bit
跳变都被误报。改为显式 for 循环逐位计数。

### 变异测试：9/10 杀死，1 个存活（原理性局限）
| # | 变异 | 结果 |
|---|---|---|
| m1 | 二进制指针直接跨域，不做格雷码 | **杀死** 761 项（[A1] 报 2~3 bits 跳变）|
| m2 | 满判定不反转高 2 位 | 杀死 5 项 |
| m3 | 同步器只留一级 | **存活** |
| m4 | 满时仍推进写指针 | 杀死 10 项 |
| m5 | 空时仍推进读指针 | 杀死 18 项 |
| m6 | 复位后 rd_empty 初值给 0 | 杀死 1 项 |
| m7 | 写存储地址用格雷码指针 | 杀死 12 项 |
| m8 | 读地址用格雷码指针 | 杀死 12 项 |
| m9 | 写使能不看 wr_full | 杀死 5 项 |
| m10 | 满判定用二进制比较 | 杀死 9 项 |

**m3 存活的原因是原理性的，不是 tb 疏漏**：Verilog 功能仿真**不建模亚稳态**，
两级同步器改成一级在任何功能测试里都不会有行为差异。这类缺陷只能靠 STA
（跨域路径时序约束）或门级仿真覆盖，本项目的验证手段到此为止。**不得据此
宣称"CDC 完全验证通过"**。

### 回归
| tb | 检查项 | 结果 |
|---|---|---|
| `tb_sd_spi_protocol` | 63 | ALL CHECKS PASSED |
| `tb_sd_spi_ctrl` | 23 | ALL CHECKS PASSED |
| `tb_sd_probe` | 11 | ALL CHECKS PASSED |
| `tb_fat32_reader` | 30 | ALL CHECKS PASSED |
| `tb_bmp_parser` | 38 | ALL CHECKS PASSED |
| `tb_async_fifo` | 26 | ALL CHECKS PASSED |

`python scripts/lint_verilog.py rtl project/src` → 24 个文件，E0=0 E1=0 E2=0。

### 边界
- **尚未上板**，尚未与 ERAM 控制器联调。
- 顶层尚未例化，`.al` 尚未加条目（按设计 S6 才接入）。
- 深度取 512（`ADDR_WIDTH=9`）需按帧缓冲突发长度在 S5 集成时复核。
- m3 类缺陷（同步器级数）不在功能仿真覆盖范围内，需 STA 兜底。

## S5-2 framebuf_arbiter：SDRAM 帧缓冲读写仲裁（2026-10-19）

### 这个模块要解决什么
SDRAM 控制器的 `app_wr_*` / `app_rd_*` 两组端口**不能同时使用**，且有一个硬性约束：
`app_*_addr[1:0]` 必须恒为 `2'b00`，**每 4 拍才能跳一次地址**。这条约束决定了仲裁器
不能"逐拍轮换"——它必须把 4 拍当作**一个不可分割的组**整体调度，否则突发计数器
被打断，后续拍会落到错误列地址上。

同时，写入侧（`bmp_parser` → `wr_fifo`）和读出侧（`rd_fifo` → HDMI 像素流）的速率
并不相等，必须保证：
1. 写不被读彻底饿死（否则整帧刷新被卡住）
2. 读不被写挤掉（否则屏幕出现可见撕裂）
3. 控制器刷新（`ref_vld`）期间绝对不能发命令，但**组内进度不能丢**

### 实现
`rtl/storage/framebuf_arbiter.v`。4 状态 `A_IDLE / A_WR / A_RD / A_GAP`，
6 个 always 块：主状态机、写命令发出、读命令发出、读数据捕获 + outstanding 计数、
方向切换间隔、异常锁存。

参数：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `ADDR_WIDTH` | 21 | 控制器字地址位宽 |
| `BUS_TURN_GAP` | 2 | 读写方向切换间隔（拍） |
| `WR_STARVE_LIMIT` | 256 | 写饥饿保护阈值（拍） |
| `RD_TIMEOUT` | 1024 | 读 outstanding 超时兜底（拍） |
| `FRAME_BASE` | 21'd0 | 帧缓冲基地址（字地址，须 4 字节对齐） |
| `FRAME_WORDS` | 18'd153600 | 一帧的 32bit 字数 = 640×480/2 |

**组原子性**：`wr_grp_active` / `rd_grp_active` 标志 + `wr_last_beat` / `rd_last_beat`
组完成判据。中途 `ref_vld` 拉起时**原地暂停**（保持组内进度），刷新结束续上。

**地址步长必须是 4，不是 1**。`app_*_addr` 是**字地址**，一个 4 拍组覆盖
`addr+0..addr+3`，所以组间步长 `wr_addr + {{(ADDR_WIDTH-3){1'b0}}, 3'd4}`，
回卷判据 `wr_addr >= FRAME_LAST`，其中 `FRAME_LAST = FRAME_BASE + FRAME_WORDS - 18'd4`。

帧尺寸核算：640×480 = 307200 像素，RGB565 每 32bit 字装 2 像素 → **153600 字/帧**
（需 18 位）= **38400 个 4 拍突发组**。21 位字地址可寻址 2M 字 = 8MB，够放 **13 帧**，
与 `eram_sdram_reference.md` 手册记载一致。

### 仿真暴露的 4 个真 RTL 缺陷

#### 缺陷 1：`wr_ack` 寄存器输出导致数据重复发送（严重）
现象：向 FIFO 压入 4 个字，`sim_mem` 里第 2 个字收到的却是第 1 个字的数据。
最小复现 `tb_mini2.v` 打印命令发出瞬间的地址与数据：

```
ISSUE#1 addr=0 din=10000000 dm=f (f_rd=0, wr_data=10000000)
ISSUE#2 addr=0 din=10000000 dm=f (f_rd=1, wr_data=10000001)   ← 重复了第 1 个字
ISSUE#3 addr=0 din=10000001 dm=f (f_rd=2, wr_data=10000002)
ISSUE#4 addr=0 din=10000002 dm=f (f_rd=3, wr_data=10000003)
```

机制：`app_wr_din` 在 `wr_fire` 那一拍采样 FIFO 队头；但 `wr_ack` 原来是寄存器
（`wr_ack <= wr_real`），要**下一拍**才有效，上游 FIFO 也到下一拍才出队。于是第 2 拍
采样时队头还没前进，同一个字被发两次。

修法：`wr_ack` 改为**组合输出** —— 端口由 `output reg` 改 `output wire`，删掉 always
块里的 `wr_ack <= 1'b0` 与 `wr_ack <= wr_real`，加 `assign wr_ack = wr_real;`。
修复后 4 条命令地址全为 0、数据依次 `10000000/10000001/10000002/10000003`。

#### 缺陷 2：写饥饿保护被优先级顺序废掉
`A_IDLE` 原判序 `rd_req` 先于 `wr_req || wr_starved`，读侧持续满载时写侧**永远轮不到**，
饥饿计数涨到阈值也无用。改为 `wr_starved` 最先判：

```verilog
A_IDLE: if (!bus_ok)       st <= A_IDLE;
        else if (wr_starved) st <= A_WR;    // 写饿极：强制开路
        else if (rd_req)     st <= A_RD;    // 读优先
        else if (wr_req)     st <= A_WR;
        else                 st <= A_IDLE;
```

实测（`tb_mini3.v`，读满载 2000 拍同时 `wr_req=1`）：`wr_cmds` 从 0 增长到 **29**，
`starve` 在 0~257 之间锯齿，每约 256 拍让出一次完整 4 拍组。

#### 缺陷 3：`rd_outstanding` 无超时兜底，会永久卡死
`rd_may_exit` 要求 `rd_outstanding == 0`。若控制器因故不返回数据（接口错接、控制器
卡死、上游误用），状态机**永久卡在 A_RD**，整块屏黑掉且无法自恢复。
`tb_mini3` 中 `rdreq=0` 后 `st=2` 一直不变、`starve` 涨到 772 即为证。

修法：新增 `RD_TIMEOUT` 参数与 `rd_wait_cnt` 计数，

```verilog
wire rd_timeout = (rd_outstanding != 4'd0) && (rd_wait_cnt >= RD_TIMEOUT[15:0]);
wire rd_may_exit = !rd_grp_active &&
                   ((rd_outstanding == 4'd0) || rd_timeout) &&
                   (!rd_req || wr_starved);
```

超时分支强制 `rd_outstanding <= 4'd0`，异常锁存块同步 `err <= 1'b1`。

#### 缺陷 4：`rd_outstanding` 位宽回绕，超时永远不触发
`rd_outstanding` 是 4 位，最大 15。`rd_fire` 的准入条件是 `rd_outstanding != 4'd15`，
但这是**组合**判据，而 `app_rd_en` 是寄存器、要到下一拍才生效。于是当本拍已是 15 时，
`app_rd_en` 仍会发出，`15 + 1` **回绕成 0**。

后果极其隐蔽：`rd_outstanding` 归零 → `rd_wait_cnt` 被清零 → `rd_timeout` 永远不成立。
表现在 T11 探针里就是 `outstanding` 在 4/11/1/8/15/5 之间周期性跳动、`wait_cnt`
最大只到 14，看上去"读总在正常返回"，实际是计数器自己把自己清零了。

修法：递增改饱和递增，

```verilog
2'b10: begin
    if (rd_outstanding != 4'd15)
        rd_outstanding <= rd_outstanding + 4'd1;
end
```

这个缺陷只有**超时用例**能抓到——正常读路径下控制器总会返回数据，回绕和正常递减
在外部行为上无法区分。

### 验证：14 个场景 / 45 项检查
`sim/testbench/tb_framebuf_arbiter.v`。测试用小帧 `FRAME_WORDS = 18'd256`（64 组）、
`RD_LATENCY = 10`、`CLK_PERIOD = 6.667`。

| 用例 | 场景 | 结果 |
|---|---|---|
| T01 | 未初始化时禁发一切命令 | PASS |
| T02 | 写突发组原子性 + 数据落位 | PASS |
| T03 | 读突发组发 4 条命令 | PASS |
| T04 | 读写同请求时读优先 | PASS |
| T05 | 读满载下写饥饿保护生效 | PASS |
| T06 | 刷新窗口内禁发命令 | PASS |
| T07 | 组中途刷新，进度不丢 | PASS |
| T08 | 写满一帧后地址回卷到 `FRAME_BASE` | PASS |
| T09 | `wr_ack` 只在真消费数据时为 1 | PASS |
| T10 | 随机压测 800 拍，全部不变量成立 | PASS |
| T11 | 控制器永不返回数据时能超时自恢复 | PASS |
| T12 | 补拍携带 `dm=0`，不污染存储 | PASS |
| T13 | 组内 4 拍地址恒定 | PASS |
| T14 | 正常操作不误报 `err` | PASS |

测试平台关键设计：写侧必须模拟**真实 FIFO 的队头**——`wr_data` 只在 `wr_ack` 那拍
之后才换成下一个数（`always @(*) wr_data = fifo_mem[fifo_rd];`，`if (wr_ack) fifo_rd <= fifo_rd + 1;`）。
若像初版那样每个 negedge 都换 `wr_data`，DUT 采到的是"下一个"字，会看到全体错一位的假失败。

### 变异测试：11/13 杀死，2 个存活且**如实记录为等价/防御性变异**

| # | 变异 | 结果 |
|---|---|---|
| m1 | 组间步长 4→1 | KILLED(242)，`app_wr_addr[1:0] != 00` |
| m2 | `wr_ack` 恒 0 | KILLED（超时），FIFO 队头不前进，`wait(fifo_rd==N)` 永久等待 |
| m3 | 去掉饥饿保护 | KILLED，`starved write eventually serviced` |
| m4 | `rd_may_exit` 去掉 `\|\| rd_timeout` | **SURVIVED** |
| m5 | `rd_timeout` 恒 0 | KILLED(2) |
| m6 | 补拍不屏蔽 `dm` | KILLED，`made-up beats drive app_wr_dm = 0` |
| m7 | 回卷阈值放宽 4 字 | KILLED，`address wrapped back to FRAME_BASE` |
| m8 | `wr_grp_active` 恒 0 | KILLED，`group padded beyond supplied words` |
| m9 | 刷新违规检测恒假 | **SURVIVED** |
| m10 | `bus_ok` 不看 `ref_vld` | KILLED(52)，`command during steady ref_vld` |
| m11 | 饥饿计数不累加 | KILLED |
| m12 | `rd_grp_active` 恒 0 | KILLED，`exactly 4 read commands for one burst group` |
| m13 | outstanding 递增去掉饱和判据 | KILLED，`read timeout sets err flag` |

**m4 存活原因（等价变异）**：超时本身会把 `rd_outstanding` 强制清零，所以下一拍
`rd_outstanding == 0` 已经成立，离开 A_RD 的条件照样满足。`|| rd_timeout` 在
功能上冗余，只影响 1 拍延迟，外部不可观测。**保留它是为了意图明确**（万一将来
改动了超时清零逻辑，这一项仍然是有效的兜底），但它确实无法用黑盒测试杀死。

**m9 存活原因（防御性 tripwire）**：这是"刷新期间不该有命令"的**断言式检测**，
RTL 正确时命令根本漏不出去，黑盒测试无法制造这个场景。要杀死它只能主动注入故障
或做白盒代码审查。保留它的价值在于：若将来有人改坏了 `bus_ok`，`err` 会立刻亮起，
比"屏幕偶尔花一下"容易定位得多。

**教训**：变异测试报告必须区分「存活 = 测试不够强」与「存活 = 等价变异 / 防御性代码」。
把后者写成前者会导致无意义地堆测试；把前者写成后者则是自欺。

### 边界说明
- **尚未上板**：SDRAM 加密核（`sdr_as_ram.enc.v` 等）需要 MGC-VERIF-SIM-RSA key 才能
  仿真解密，本模块的验证完全基于**行为级 SDRAM 模型**（10 拍固定读延迟、按字写入）。
  真实控制器的 `Sdr_busy` / `Sdr_init_ref_vld` 握手尚未联调。
- **顶层尚未例化** `framebuf_arbiter`，`.al` 也尚未加入条目（按设计 S6 才接入全链）。
- **`BUS_TURN_GAP` 未做最优性验证**：当前取 2 拍，真实 SDRAM 的 tRTW/tWTR 约束需在
  上板时用示波器/ILA 复核。



## S5-3 sdram_ctrl_wrap：SDRAM 控制器封装与仿真/综合双路径（2026-10-19）

### 为什么需要这一层
安路 APUG011 的 SDRAM 控制器以**加密核**形式提供（`sdr_as_ram.enc.v` 等四个文件），
直接接进工程有三个障碍：

1. **参数是 `` `define `` 不是 `parameter`**。`global_def.v` 里
   `DATA_WIDTH=32 / ADDR_WIDTH=21 / DM_WIDTH=4 / ROW_WIDTH=11 / BA_WIDTH=2`
   以及两个频率相关宏 `SDR_CLK_PERIOD = 1000000000/150000000`、
   `SELF_REFRESH_INTERVAL = 64000000/`SDR_CLK_PERIOD/2**`ROW_WIDTH`。
   **改频率必须同步改前两个宏**，散落在工程各处极易漏改（漏改不报错，
   只是刷新周期算错、数据静默变错）。
2. **不定义 `SIMULATION` 宏无法仿真**。官方 `top.v` 里 SDRAM 引脚直接连
   `EG_PHY_SDRAM_2M_32` SIP 原语，仿真时没有模型驱动会一直 X 态。
3. **命名风格与本工程不一致**（`App_wr_en` 这类下划线混合大小写，
   本工程统一小写 + `_n` 后缀）。

本模块把这三件事集中处理。上层（`framebuf_arbiter` 及以上）只看到干净的小写接口。

### 仿真 / 综合的分流机制（关键设计决策）
用编译宏 `SDRAM_SIM_MODEL` 二分：

| 路径 | 实例化 | 需要加密核 | 谁在用 |
|------|--------|-----------|--------|
| 综合（不定义宏） | `sdr_as_ram` 加密核 + `EG_PHY_SDRAM_2M_32` | 是 | `project/hdmi_td.al` |
| 仿真（`+define+SDRAM_SIM_MODEL`） | 本文件底部的 `sdram_behavior_model` | **否** | `sim/scripts/run_sim.bat` |

**为什么不用 `` `ifdef SIMULATION `` 塞在同一个文件里**：加密核的 `.v` 文件本身
包含 `` `pragma protect `` 段，ModelSim 没拿到 RSA key 会**在编译期**报错退出，
`` `ifdef `` 救不了——`vlog` 处理那个文件时就要解密。所以必须做到"仿真时根本
不编译加密核"，这只能靠**文件级二选一**（仿真库不含 `.enc.v`）+ 本文件用宏
分流实例化。两边共用同一份源码，不会出现"综合的和仿真的不是同一份代码"。

### 行为模型与真核的时序等价性
`sdram_behavior_model` 刻意模仿真核的可观测行为：

- 上电后有 `INIT_CYCLES`（默认 64 拍）初始化期，期间 `init_done=0`
- **读延迟固定 10 拍**（与 `docs/eram_sdram_reference.md` §4 一致）
- 写立即生效，`dm[n]=1` 表示**屏蔽**对应字节（与 APUG011 同向）
- 周期性拉 `ref_vld` 模拟自刷新，持续 `REF_VLD_CYCLES` 拍
- **刷新期间忽略一切读写命令**（真核要求"用户必须避让"，模型选择"忽略"而不是
  "缓存"——这样上层若漏了避让会**丢数据**而非侥幸通过，更容易在仿真里暴露）

### 接口契约（沿用 APUG011，写进文件头注释）
1. 读延迟固定 10 拍，器件差异可能 ±1 拍，上板需实测对齐
2. 写通道**无反压**：`app_wr_en` 拉高即写，调用方须自己避让刷新窗口
3. **读写不可同时**
4. `app_*_addr[1:0]` 必须恒 `2'b00`，每 4 拍才可跳一次地址
5. `ref_vld` 是**唯一流控**；`sdr_busy` 官方标注"暂不使用"
6. `app_wr_dm` 语义：`1=屏蔽`、`0=写`（全写时置 `4'b0000`）。
   **注意**：`docs/eram_sdram_reference.md` §3 表格里有一处表述方向相反，
   以本模块文件头注释为准（已核对官方 `app_wrrd.v` 用的是 `4'b0000`）

### 验证：`tb_sdram_ctrl_wrap`，12 场景 / 102 项检查
| # | 场景 | 结果 |
|---|------|------|
| T01 | 复位后 `init_done=0`、`busy=1` | PASS |
| T02 | 初始化完成后 `init_done=1`、`busy=0` | PASS |
| T03 | 写 4 拍组后逐字读回，数据一致 | PASS |
| T04 | **读延迟实测 = 10 拍**（手册硬指标） | PASS |
| T05 | `dm` 逐字节屏蔽（`1110`/`0111` 两种） | PASS |
| T06 | 刷新期间写命令被忽略（数据保持原值） | PASS |
| T07 | 刷新期间读命令不返回有效数据 | PASS |
| T08 | `ref_vld` 周期性出现，持续 `REF_VLD_CYCLES` 拍 | PASS |
| T09 | 64 地址全区扫描写读 + 地址 0/1 独立性 | PASS |
| T10 | 复位中途重新初始化后恢复正常读写 | PASS |
| T11 | `init_done` 保持低够久（覆盖 `INIT_CYCLES`） | PASS |
| T12 | 背靠背连续读，数据不串拍 | PASS |

### 测试平台踩到的 4 个坑（都不是 RTL 问题，但会让结论失真）
1. **刷新周期设 100 拍太密**，100+ 次读写必然有几次撞进 8 拍的刷新窗口被丢弃，
   报出 `xxxxxxxx` 的"假失败"。改为**双实例**：主实例 `REFRESH_PERIOD=500000`
   （极稀疏），另起 `dut_fast`（`REFRESH_PERIOD=100`）专测刷新语义。
   这比给主 tb 加重试逻辑更干净——**不要为了掩盖参数不当去改被测语义**。
2. **裸 `while` 没有 guard**：某个变异体让 `ref_vld` 永不拉高时，
   `while (!f_ref_vld) @(posedge clk);` 死等，整轮仿真超时 20ms 才结束，
   表现为 `TIMEOUT` 而不是 `FAIL`，难以诊断。全部改为
   `while (cond && i < 5000) begin @(posedge clk); i = i + 1; end` + 后置断言。
3. **T07 检查窗口错位**：读延迟 10 拍，但只在 8 拍的刷新窗口内查 `sdr_rd_en`，
   命令若被接受，数据要 10 拍后才出来——**漏掉整整一条错误路径**。
   改为跨"刷新窗口 + 12 拍"检查。
4. **T12/背靠背读**：读延迟模型是移位链，取 `rd_lat_data[0]` 还是 `[1]`
   在"每次读写之间隔很多拍"的用例里完全看不出差别（链里只有一个有效数据在飞）。
   只有**连续发**才能暴露"取到相邻拍数据"。补 T12 后该变异体被杀死。

### 变异测试：12 个变异体，11 杀死 / 1 存活（已核实为等价变异）
| # | 变异 | 结果 |
|---|------|------|
| m01 | 读延迟 10→9（少打一拍） | KILLED（87 FAIL） |
| m02 | `dm` 语义反相（`dm[n]=1` 表示写） | KILLED（79 FAIL） |
| m03 | 刷新期间仍接受写 | KILLED T06 |
| m04 | 刷新期间仍接受读 | KILLED T07（**补窗口后**） |
| m05 | `ref_vld` 永不拉高 | KILLED（6 FAIL） |
| m06 | `init_done` 恒 1（跳过初始化） | KILLED T11（**补 `INIT_CYCLES` 检查后**） |
| m07 | `busy` 极性反相 | KILLED T01 |
| m08 | 写地址高位置零（只留低 8 位） | KILLED T12 |
| m09 | 写只存低 16 位 | KILLED（81 FAIL） |
| m10 | 复位不清 `rd_lat` 移位链 | **SURVIVED**（等价变异） |
| m11 | `ref_vld` 持续时间双倍 | KILLED T08 |
| m12 | 读数据错一拍（取队首下一位） | KILLED T12（**补背靠背读后**） |

**m10 存活原因（已实证等价）**：复位只发生在仿真开头，此时移位链里本来就是 0；
且链中的 X 态会经 `if (sdr_rd_en)` 隐式转假值，外部不可观测。实证方法：
把 `INIT_CYCLES` 压到 4（< `RD_LATENCY`），对比原始 RTL 与 m10 的 FAIL 数——
两者都是 1（且是同一条 `init duration at least INIT_CYCLES`，属参数副作用
而非 m10 引起）。故判为等价变异，**保留原写法是为了让复位语义完整**。

**第一轮 4 个存活（m04/m06/m12 + m05 超时）全部靠补定向用例杀死**，
再次验证"变异测试的价值在于暴露测试缺口，而不只是给 RTL 打分"。

### 边界说明（不得越界表述）
- **未上板**：本模块的行为模型只保证时序契约，真核的实际读延迟、突发行为、
  刷新窗口宽度需上板用逻辑分析仪或 `sd_probe` 式探针实测确认。
- **未综合验证**：`sdram_ctrl_wrap` 的综合路径（含 `sdr_as_ram` 加密核）
  尚未进 `project/hdmi_td.al`，`sdram_pll` 的 150MHz 也未在 TD 里跑过。
  两者都必须跑一次 headless 出 bit 才能算通过。
- **`dm` 语义有一处文档冲突**（见上文接口契约第 6 条），以官方 RTL 为准，
  但 `docs/eram_sdram_reference.md` §3 的表述应择机修正。
- **行为模型不是真核的位真复制**：地址映射（row/bank/col）在模型里被简化为
  线性索引，真核的 bank 切换惩罚、预充电时序均未建模。因此
  **不能用本模型评估带宽/性能**，只能验证功能与时序契约。

## S5-4：SDRAM 150MHz 链路 bring-up 与 PLL 真缺陷（2026-10-19）

本节回答阶段四最大的前置风险：**150MHz 时钟域到底能不能在 EG4S20 上收敛**。
结论：**能**，但过程中发现并修掉了两个会让整个 SDRAM 帧缓存方案失效的真缺陷，
且第一次跑出"0 违例"时是**假绿**——关键时钟根本没被 STA 分析。

### 一、为什么必须单独建验证工程

把 PLL + SDRAM 核与键盘、数码管、HDMI 一起综合，时序报告的关键路径会混入无关逻辑，
"150MHz 收敛不了到底是 PLL 配置错还是别的逻辑拖累"就说不清。
单独综合时工程里只有 PLL + SDRAM 核 + 几十行序列机，任何时序问题都能直接归因。
新增文件：

| 文件 | 作用 |
|------|------|
| `rtl/storage/sdram_bringup_top.v` | 验证专用顶层：PLL 复位延时 + `sdram_pll` + 三级复位同步 + `sdram_ctrl_wrap` + 极简读写序列机 + `EG_PHY_SDRAM_2M_32` SIP 原语 |
| `project/hdmi/sdram_bringup_td.adc` | 仅 10 个管脚（clk=R7、rst_n_btn=E3、led[7:0]）；**无 SDRAM 管脚** |
| `project/hdmi/sdram_bringup_rw.sdc` | 50MHz 主时钟 + `derive_clocks` + 时钟组声明 |
| `project/sdram_bringup_td.al` | 独立 TD 工程（7 个 Verilog + ADC + SDC） |
| `project/flow_sdram_bringup.tcl` | headless 综合→布局→布线→STA→bitgen |

### 二、真缺陷 1：`sdram_pll` 的 150MHz 0° 输出根本没接上

对照官方 `clk_pll.v` 逐线追踪发现（修复前）：

| 信号 | 官方 `clk_pll.v` | 本工程修复前 | 后果 |
|------|------------------|--------------|------|
| `clkc` 拼接 | `{open, open, clk2_out, clk1_out, clk0_buf}` | `{open, open, sdram_clk_sft, open, clk0_buf}` ← **C1 是 open** | 150MHz 0° 悬空 |
| `sdram_clk` 来源 | 应来自 C1 | 实际来自 `EG_LOGIC_BUFG(.i(clk0_buf))` = **C0 12.5MHz** | 对外输出频率错 12 倍 |
| `fbclk` | `clk0_out`（C0 经 BUFG） | `sdram_clk`（被复用） | 反馈信号被绑死到错误网络 |

后果：整个 SDRAM 子系统会跑在 **12.5MHz**，刷新周期算错 12 倍，必然丢数据。
修复后：

```verilog
wire clk0_buf;   // C0 原始输出
wire clk0_out;   // C0 经 BUFG 的 12.5MHz（仅反馈）
wire clk1_raw;   // C1 = 150MHz 0°
wire clk2_raw;   // C2 = 150MHz 180°
EG_LOGIC_BUFG bufg_feedback (.i(clk0_buf), .o(clk0_out));
assign sdram_clk     = clk1_raw;
assign sdram_clk_sft = clk2_raw;
// .fbclk(clk0_out), .clkc({clk4_unused, clk3_unused, clk2_raw, clk1_raw, clk0_buf})
```

**这条缺陷的教训**：注释里写着"C1 = 150MHz 0° 供 SDRAM 控制器"，
代码里 C1 却是 `open`。**注释不能当证据，必须逐线对照官方参考设计**。

### 三、真缺陷 2：SDC 里的 `create_generated_clock` 与 `derive_clocks` 冲突，导致 150MHz 从未进入 STA

初版 SDC 想给 PLL 输出起好记的名字（`clk_sdr` / `clk_sdr_sft`），
在 `derive_clocks` 之后又写了 `create_generated_clock`。TD 报三层连锁失败：

```
USR-6122 CRITICAL-WARNING: Clock definition problem.
          Clock clk_sdr override clock u_pll/pll_inst.clkc[1],
          as two clocks are defined on the same target pin.
USR-8159 CRITICAL-WARNING: Command create_generated_clock ... fails.
USR-8130 CRITICAL-WARNING: No clock match the pattern: clk_sdr.
```

后果极具欺骗性：**Clock Summary 里只有 50MHz 和 12.5MHz，150MHz 完全不见**，
`Timing Status` 显示 `SWNS: 9.211ns`（漂亮的正值），
但那是 50MHz 域的结论，**150MHz 域根本没被分析**。

修复：`derive_clocks` 已能从 `EG_PHY_PLL` 的 `CLKC*_DIV`/`CLKC*_CPHASE` 正确反推频率
（日志可见 `multiply_by 3.0000` / `phase 180`），**直接用派生的原始名字**，
不要再 `create_generated_clock`。`set_clock_groups` 也用原始名字：

```
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[1]}] \
    -group [get_clocks {u_pll/pll_inst.clkc[2]}]
```

修复后 Clock Summary 正确出现四颗时钟，`USR-6122/8130/8159` 计数归零，
**STA coverage 从 95.33% 升到 98.66%**。

### 四、真缺陷 3：LED 输出未寄存，150MHz 下 17 个端点违例

时钟进 STA 之后立刻暴露：**SWNS = -2.102ns，STNS = -11.328ns，Fmax 仅 114.05MHz**。
关键路径：

```
Begin: u_sdram_sip.ipclk（SDRAM SIP 读出时钟，150MHz）
End  : led[2]_syn_4.do[0]（LED 输出 PAD）
Data Path Delay : 8.564ns（cell 2.575ns 30% / net 5.989ns 70%）
Logic Level     : 4（LUT5×3 + LUT4×1）
```

即 **32 位读数据比较器直接串在 SDRAM 读出 → 状态机 → LED 引脚**的组合路径上。
修复两处（`rtl/storage/sdram_bringup_top.v`）：

1. 读数据比较结果单独打一拍：新增 `rd_en_q` / `rd_mismatch` 寄存器，
   在 `T_READ` 里改用 `if (rd_en_q) ... if (rd_mismatch) ...`，
   32 位比较退化为"寄存器 → 1 级 LUT → 寄存器"的短路径。
2. LED 输出加一级寄存器：`led_reg <= {tst_err[5:0], pll_locked, tst_pass}; assign led = led_reg;`，
   LED 的 1 拍延迟对肉眼毫无影响。

### 五、收敛结果（实测）

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 150MHz SWNS | **-2.102ns** | **+0.104ns** |
| 150MHz HWNS | +0.054ns | **+0.151ns** |
| 150MHz Fmax（R-Period） | **114.05MHz** | **152.39MHz** |
| 建立违例端点 | **17 个** | **0 个** |
| STA coverage | 95.33% | **98.66%** |
| `USR-6122/8130/8159` | 各 2 条 | **0** |

```
Timing Status
    SWNS: 0.104ns, STNS: 0.000ns
    HWNS: 0.151ns, HTNS: 0.000ns
Clock Summary
    clk0: 150.015MHz  fanout=178  u_pll/pll_inst.clkc[1]
    clk2: 150.015MHz  fanout=1    u_pll/pll_inst.clkc[2]
    clk3:  12.500MHz  fanout=0    u_pll/pll_inst.clkc[0]
```

资源：`#IO 10/188`、`#lut 160/19600 (0.82%)`、`#reg 194`、`#bram 0`、`#pll 1/4`、`#gclk 1/16`。
层次表证明 SDRAM 加密核确实进了 bit（不是空盒）：
`u_sdram / u_sdr_as_ram / le=154 lut=49 seq=141`、`u_pll le=1`。

### 六、仍需上板确认的点（未验证，不得写成已实现）

1. **PLL 是否真的锁定**：`led[1] = pll_locked`，上板看灯即可判断。
   TD 侧的 `BIT-1002 PLL setting string = 0010` + 时序收敛只能说明配置被接受，不能说明硬件锁得住。
2. **SDRAM 读写是否真的通**：`led[0] = 测试通过`。仿真用的是行为模型，
   行为模型按手册时序实现，**不能替代真器件的建立/保持窗口**。
3. **`PHY-5079` 时钟局部布线**：`clkc[2]`（150MHz 180°，扇出 1，只送 `SDRAM_CLK` 引脚）
   被标为使用局部布线资源。扇出 1 时通常可接受，但要在板上用示波器看
   `SDRAM_CLK` 完整性；若读写偶发失败，优先怀疑这条。
4. **150MHz 的余量只有 0.104ns**（约 1.5%）。S6 全链把 `framebuf_arbiter`、
   `async_fifo`、`bmp_parser` 都挂到 150MHz 后，**必须重新跑 STA 确认不退化**。
   本次结论只覆盖"PLL + SDRAM 核 + 极简序列机"这个最小拓扑。

## S6-2：读取链路的契约缺陷修复与可复现回归（2026-10-21）

本节记录 `pix_reader` / `framebuf_arbiter` / `sdram_ctrl_wrap` 三个模块的修复。
**起因是旧的自检全部通过，但通过的是自洽的错误模型**：旧 TB 按"注册命令 + 地址变化
即新组首拍"的假设写检查，把真实的四拍契约写反了。修复方向不是"让仿真通过"，
而是先把契约对齐官方 `app_wrrd.v` 与 APUG011，再让 TB 检查契约。

### 一、查实的契约缺陷（都不是风格问题）

| # | 位置 | 缺陷 | 后果 |
|---|------|------|------|
| A | `sdram_ctrl_wrap.v` 行为模型 | 四拍组内每一拍都按 `app_*_addr` 写同一个字 | 组内四拍互相覆盖，只有最后一拍落地 |
| B | 同上（读） | 用"地址变化"猜组首拍 | 组内地址恒定时判不出新组，错拍被掩盖 |
| C | `framebuf_arbiter.v` + 旧 TB | 断流补拍用 `DM=0`，旧 TB 还要求补拍 `dm=0` | 补拍真写零，覆盖帧内容；**旧 TB 极性是反的** |
| D | `framebuf_arbiter.v` | 重启 pending 期间仍可能发 `rd_ack`，且未锁存 `rd_base` | 假握手，重启目标不确定 |
| E | `framebuf_arbiter.v` | 信用只有 4 bit 且会饱和 | 在飞计数漏计，水位判断失真 |
| F | `framebuf_arbiter.v` | 注册后的 `app_*` 比 `wr_ack` 晚一拍 | `ref_vld` 上升后下一拍模型拒收，而 FIFO 已消费、拍已前进 → **静默丢数** |
| G | `framebuf_arbiter.v` | 看门狗只在计数为 0 时清零 | 连续正常回包超过 1024 拍就报假超时 |
| H | `framebuf_arbiter.v` | 持续有新读组时不停开新组 | 返回永不排空，写侧饿死 |

**F 是其中最危险的一条**：它不会在任何"每拍都对齐"的 TB 里暴露，只在刷新边界
（`ref_vld` 恰好落在命令与注册之间）丢一个字，而丢字表现为整帧图像缓慢错位。

### 二、修复后的统一接受契约

1. `app_wr_en/app_rd_en`、`wr_ack/rd_ack`、拍计数、FIFO 出队在**同一边沿**成立，
   不再"先注册命令、下一拍再发"。这是 F 的根因修法。
2. 组首一次预留四拍信用；`rd_outstanding` 扩到 5 bit（最多 31），新组要求 `<=27`。
3. 写饿死时先**停止开新读组**，等在飞返回与输出排空后再换向，而不是硬插写命令。
4. 断流补拍统一 `DM=4'hF`（全屏蔽），读与空闲期 `DM=0`（放开 DQM）。
5. 重启先捕获 `rd_base`，要求 `pending && !组 && O==0 && !rd_valid && !fault && bus_ok`
   才应用，应用时给出单拍 `rd_restart_done`；新增 `rd_idle` 供上层判断"确实静默"。
6. 无回包超时置 `rd_fault` 粘滞到系统复位，保留未收计数，**不伪造清零、不报 idle**；
   零计数收到陌生返回置故障但不下溢。

### 三、`pix_reader` 的逐帧重新对齐

旧实现假设"消隐期足够长 + 单次 ARM 就永久对齐"，且用 `active_y >= FRAME_LINES`
判消隐。实测 `rtl/video/video_timing_gen.v:195-209` 的 `de/active_x/active_y` 同拍寄存，
**消隐时 `active_y` 归零**，因此旧判据在真实顶层永不成立。

新实现改为状态机 `P_WAIT → P_QUIET → P_DRAIN → P_RESTART → P_READY → P_RUN`：

- 用 `in_vblank` 锁存"已见最后有效行末、尚未见下一帧首像素"，兼容消隐坐标归零与
  原始行计数两种输入；
- 每帧在消隐期停请求 → 等 `rd_idle` → 读空 FIFO → 握手重启 → 确认 `done` →
  消隐期预填 → 帧首消费，**不再指望"一次对齐永久有效"**；
- 消费计数 `rd_count` 走格雷码跨域，水位 = `issued_count - 同步后的出队数`，
  含已承诺但未回包的四个字；
- FIFO 两侧**只接系统复位**，运行中不再单侧复位指针（旧代码的单侧复位"自愈"
  在异步 FIFO 上本就不成立，已删除该宣称）；
- `P_READY` 用组合 `display_enable` 桥接帧首第一像素，避免首像素延后一拍。

### 四、验证证据（本轮实测，非历史引用）

三套 TB 全部重写，检查项对准契约而非对准旧实现：

| 套件 | 场景 | 检查 | 结果 | 证据 |
|------|------|------|------|------|
| `tb_framebuf_arbiter` | 15 | 50900 | 0 error | `reports/s6_final/tb_framebuf_arbiter.log` |
| `tb_sdram_ctrl_wrap` | 12 | 154771 | 0 error | `reports/s6_final/tb_sdram_ctrl_wrap.log` |
| `tb_pix_reader` | 8 | 108 | 0 error | `reports/s6_final/tb_pix_reader.log` |
| `tb_pix_reader_vga`（640×480） | 5 | 64 | 0 error | `reports/s6_final_vga/tb_pix_reader_vga.log` |
| `tb_image_player` | — | 6202 | 0 error | `reports/s6_final_image/image_player.txt` |
| `tb_image_player` 全尺寸 640×480 | — | 614404 | 0 error | `reports/s6_final_image_full/` |
| 前端 8 个 TB | 62/64/23/14/40/37/43/85 条 PASS | — | 全通过 | `reports/s6_final_frontend/result.json` |

上表右列是本机仿真产物。本轮新增的报告目录（`reports/s6_final*`、`reports/s6_gate/`）按 `.gitignore`
的 `*.json`、`*.log`、`work/` 规则**不纳入版本控制**（仓库里已跟踪的 `reports/*.json` 是早期强制加入的历史证据）；
克隆仓库后按下文命令重跑即可复现同样的检查数与通过标记。

回归入口（新建，替换原来依赖 PATH、不建库、不按 FAIL 退出的旧脚本）：

```powershell
& .\sim\scripts\run_storage_regression.ps1 -Suite All      -ReportDir reports\s6_final
& .\sim\scripts\run_storage_regression.ps1 -Suite Pixels -FullVga -ReportDir reports\s6_final_vga
```

该 runner 每次建独立 `work` 库，编译非 0 绝不跑旧库，通过条件为
`exit 0` + 精确 `ALL CHECKS PASSED: <top>` 标记 + `SUMMARY` 中 `errors=0 && cases>0`，
且日志无 FAIL/Error/timeout；运行前后比对源码 SHA256，**运行期间源码漂移则本轮证据
作废并退出 1**（已真实发生一次：子代理并发写 TB 导致 `reports/s6_vga` 那一轮作废重跑）。

静态检查：`python scripts/lint_verilog.py rtl\storage\{pix_reader,framebuf_arbiter,sdram_ctrl_wrap}.v`
→ 3 files，E0=E1=E2=0。同步：`scripts/sync_src.ps1` → `0/35 个副本被更新` + lint 通过。

### 五、仍未通过、不得含糊的部分

1. **`readable-verilog-generator` 严格交付门禁未通过**。三份源码各自 296～580 条
   规则错误，主体是 `comments.procedural_assignment`（过程赋值缺同行语义注释）、
   `naming.port_prefix`/`ports.no_kind_keyword`（端口命名与 `wire/reg` 关键字）、
   `comb_operation_budget`（组合操作预算）、`format.tab_indent` 等**机械性风格规则**。
   报告在 `reports/s6_gate/*_gate.{json,md}`，`delivery_ready=False`（该目录同样不纳入版本控制，重跑方法见
   `generated_deliverable_gate` 的 `--json/--markdown` 参数）。
   要让门禁转绿需要对整文件重命名与逐行补注释，属于大范围机械改动，
   与本轮"最小有据修复"相冲突，因此**如实记为未通过，不以功能仿真通过冒充规范通过**。
   全仓库当前没有任何 `*_spec.md`。
2. **行为模型不等于真核**。`sdram_behavior_model` 只对齐了可观测时序（10 拍读延迟、
   8 拍刷新窗口、DM 高低有效方向），不覆盖真器件的建立/保持窗口、跨刷新相位保持。
   "组内相位在刷新后保留"仍是**模型假设**，官方只承诺"操作前避让"。
3. **SiP 时序仍是发布阻塞项**。上一节的 `-7.232ns` 全局 setup 违例没有被本轮修复触及；
   本轮改动全部在功能层，**没有新增任何时序证据**。
4. **没有上板**。本轮结论限于 ModelSim 行为仿真。

## S7-0：TD 工程缺源修复与正式顶层首次构建（2026-10-25）

本节记录一个**长期存在但未被发现**的工程缺陷，以及修复后的完整构建结果。

### 缺陷：`project/hdmi_td.al` 缺 12 个模块源

`project/hdmi_td.al` 是正式图片工程（顶层 `dmz_eg4s20_hdmi_top`）的工程文件。
它从提交 `e41315a`（feat: integrate SD-to-HDMI image playback）起就只列 9 个 Verilog 源，
而顶层此后陆续例化了 12 个模块，全部不在源列表里：

`sdram_pll`、`sdram_ctrl_wrap`、`async_fifo`、`fat32_reader`、`bmp_parser`、`img_loader`、
`framebuf_arbiter`、`pix_reader`、`player_ctrl`、`sd_spi_ctrl`、`sd_probe`、`image_player`。

（`gallery_probe` 于 2026-10-25 新增，是第 13 个缺失项。）

**实测症状**（`td_commands_prompt.exe ./project/flow_t2_elaborate.tcl`）：

```
HDL-7144 CRITICAL-WARNING: instantiate unknown module sdram_pll in hdmi/dmz_eg4s20_hdmi_top.v(45)
HDL-7144 CRITICAL-WARNING: instantiate unknown module player_ctrl in hdmi/dmz_eg4s20_hdmi_top.v(80)
HDL-7144 CRITICAL-WARNING: instantiate unknown module sd_spi_ctrl in hdmi/dmz_eg4s20_hdmi_top.v(116)
HDL-7144 CRITICAL-WARNING: instantiate unknown module sd_probe in hdmi/dmz_eg4s20_hdmi_top.v(122)
HDL-7144 CRITICAL-WARNING: instantiate unknown module gallery_probe in hdmi/dmz_eg4s20_hdmi_top.v(131)
HDL-7144 CRITICAL-WARNING: instantiate unknown module image_player in hdmi/dmz_eg4s20_hdmi_top.v(152)
HDL-8007 ERROR: sdram_pll is a black box ...   (共 6 条)
```

elaborate **exit 4** —— 正式顶层此前**根本无法构建**。

### 为什么之前没被发现

`reports/s6_build.txt`（2026-10-20 01:56）显示当时 analyze 了 25 个 `.v`，含全部模块。
那份 log 早于 `e41315a`（18:43）的提交，说明 `.al` 是在该提交里被误删源项的。
此后没有任何一次构建记录是针对**当前** `.al` 跑的，缺陷因此一直潜伏。
此前交付文档里「只需人工加 gallery_probe 一项」的判断是错的。

### 修复

`project/hdmi_td.al`：

1. 在 `hdmi_pll.v`（CompileOrder 9）之后、`dmz_eg4s20_hdmi_top.v` 之前，插入 13 个业务模块
   （CompileOrder 100~112）。
2. 顶层 `dmz_eg4s20_hdmi_top.v` 的 CompileOrder 由 14 改为 **200**（确保排在所有子模块之后）。
3. 新增 4 个 `ip/local/sdram/` 文件：`global_def.v`、`sdr_wrrd.enc.v`、`sdr_init_ref.enc.v`、
   `sdr_as_ram.enc.v`（CompileOrder 300~303，路径 `../ip/local/sdram/xxx`）。
4. 新增节点统一 `UsedInSyn/UsedInP&R=true`、`BelongTo=design_1`。

**注意**：`.al` 里的 `UsedInP&R` 含未转义 `&`，标准 XML 解析器会拒绝
（`'>' is an unexpected token ... Line 16`）。这是 TD 原文件的既有格式，TD 自身可解析，**不要"修复"它**。

### 修复后的完整构建结果

`flow_t2_elaborate.tcl`：**elaborate exit 0**，6 个 unknown module 全部消失。

`flow_s6_bit.tcl` 全流程：

```
S6_PASS-optimize_rtl
S6_PASS-optimize_gate
S6_PASS-place
S6_PASS-route
S6_BIT_FLOW_DONE
S6_TIMING_FAILED: setup=-7.232 ns hold=0.023 ns; bit is a candidate only
```

**流程 exit 3 是时序判定失败，不是构建失败。** 生成的 bit：`project/hdmi_td_Runs/phy_1/hdmi_td.bit`（629,640 B）。

资源占用（`reports/s6_integration/area.txt`）：

| 项目 | 占用 | 总量 | 比例 |
|---|---|---|---|
| IO | 41 | 188 | 21.81% |
| LUT | 8215 | 19600 | 41.91% |
| LUT-as-logic | 5079 | 8852 | 57.38% |
| LUT&reg | 3136 | 8852 | 35.43% |
| PLL | 2 | 4 | 50% |
| BRAM | 6 | — | — |
| DSP | 13 | — | — |

时钟域 LUT 分布：`u_pll/clkc[0]` 25MHz 用 3179 LUT-as-logic + 1024 LUT-as-dram + 3 BRAM + 13 DSP；
`clkc[2]` 125MHz 用 27；`u_sdram_pll/clkc[1]` 150MHz 用 267。

### 边界说明（不得含糊）

1. **时序未收敛**：setup WNS −7.232 ns、TNS −335.004 ns，hold WNS +0.023 ns。
   修复 `.al` **没有改变**这个数字，本轮不产生任何新的时序证据。
2. **仍无正式顶层上板记录**。唯一上板证据来自独立诊断工程 `image_dm_fix`。
3. 存量 TD 告警（均非本轮引入）：
   `PHY-7002 CRITICAL-WARNING: Instance u_sdram_sip location (12, 12)/(164, 288) is not honored`、
   `PHY-5079 CRITICAL-WARNING: Marked 1 clock net(s) utilize the local routing resources`、
   `USR-6135 CRITICAL-WARNING: The feedback path of PLL u_pll/pll_inst is on local network`（`u_sdram_pll` 同）。

## S8：HDMI 音频嵌入（2026-10-26）

把只有视频的 HDMI 输出改成带内嵌音频的 HDMI 1.4b 输出，并用按播放状态变化的 PCM 替换原来固定 440 Hz 的 PWM 测试音。完整论述见 [HDMI 音频嵌入](hdmi_audio_2026-10-26.md)。

### 换核（唯一可行路径）

原 `hdmi_tx.vhd` 只是把 VHDL 加密核 `DVITransmitter` 做端口映射，**该核端口里没有音频**（`RED_I/GREEN_I/BLUE_I`、`HS_I/VS_I/VDE_I`、4 根 TMDS），无法"在现有链路上加音频"。改用 `project/reference/lab_ex5_i2s/` 里的 `hdmi_1_4b_transmitter_core_wrapper.enc.v`（328,975 B），依据是参考工程 `HDMI1.4b_Transmitter_v1.0.al` 为 `<Family>EG4</Family>` / `<Device>EG4S20BG256</Device>`，**与本板同器件**。

例化参数：`HTOTAL=800 HSA=96 HFP=16 HBP=48 HACTIVE=640 / VTOTAL=525 VSA=2 VFP=10 VBP=33 VACTIVE=480 / VIDEO_TPG="Disable" / VIDEO_VIC=1 / AUDIO_SAMPLE_RATE="48K" / IIC_SCL_DIV=250`。

### 新增 6 个模块

| 模块 | 作用 | 关键点 |
|---|---|---|
| `rtl/audio/audio_tone_gen.v` | 48 kHz / 24 bit PCM 音源 | 分数分频使能；8 音 LUT；三角波；**静音时仍发 valid** |
| `rtl/video/hdmi/audio_arc.v` | ACR 包 CTS/N | `ACR_N=6144`，`AUDIO_DIV=48` |
| `rtl/video/hdmi/video_rgb_to_axis.v` | RGB+DE+VS → AXIS | VS 跳变后行首发 `user`，`x_cnt==639` 发 `last` |
| `rtl/video/hdmi/hdmi_phy.v` | 4 路 10 bit TMDS 串化 | 输入先全位反序 |
| `rtl/video/hdmi/lane_lvds_10_1.v` | 单 lane 2 bit/拍移位 | `EG_LOGIC_ODDR(d1=data[0], d0=data[1])` |
| `rtl/audio/pcm_to_pwm.v` | PCM → 1 bit sigma-delta | 静音输出恒 0 |

顶层 `rtl/top/dmz_eg4s20_hdmi_top.v` 由 209 行增至 402 行：删除 `hdmi_tx`，接入上述六模块，新增 `playback_state[2:0]` 七态状态机驱动音高（音视频联动），`audio_left` 同一份样本同时送 HDMI 核与 `pcm_to_pwm`。

### 时钟方案（不加第三颗 PLL）

APUG092 文档原文："HDMI1.4b Transmitter Core 的四个接口 EDID Interface、Video Interface、Audio Interface 和 ACR Interface 都是工作在 Pixel Clock 时钟域下。" 因此音频只需在 25 MHz 域按 48 kHz 节拍给样本，`audio_tone_gen` / `audio_arc` 直接跑 `clk_pixel`。官方例程的 12.288 MHz PLL + I2S 回环只是演示"I2S 输入"功能，且那颗 PLL 实际出 12.295082 MHz（+0.06%）。

### 本板无 DDC（硬件事实，非软件取舍）

三处核实：① `EG4S20_综合底板.pdf` 第 0 页 U7(AZ1045-04F ESD 阵列) 只接 4 对差分 + HDMI_5V，无 SCL/SDA 到 FPGA；② `板卡和引脚说明.pdf` §3.3 只列 4 个信号；③ 参考工程 `pin.adc` 的 DDC 是 `P2/R2`（HX4S20C 板），不可移植。处理：`O_ddc_scl`/`IO_ddc_sda` 内部悬空、不引出端口、不约束管脚；`I_edid_read_trig` 固定 `1'b0`；**不做 EDID 协商**，信息包按参数静态构造。

### 验证证据

**仿真（通过）**：`sim/scripts/run_audio_regression.ps1`，2 用例全绿、24 条 PASS。

```
hdmi_audio_path: passed=True; passLines=19
pwm_audio_out_legacy: passed=True; passLines=5
```

`tb_hdmi_audio_path.v` 实测：采样率 `valid=48000`（误差 0）、`acr_n=6144`、ACR `acr=1000` 包/秒、包间隔 `gap=24999` 拍、G4 过零 `flips=785`（理论 784）、E4 `165`、C4 `131`、PWM 占空比 `490 permille`、ST_IDLE `valid=4800 nonzero=0`。

**综合布线（通过，时序与基线同一路径）**：

```
S6_PASS-optimize_rtl / optimize_gate / place / route
S6_BIT_FLOW_DONE
S6_TIMING_FAILED: setup=-7.232 ns hold=0.011 ns; bit is a candidate only
```

**构建时间绑定**：以下数字取自 `reports/s6_integration/build_hdmi_audio_rerun.txt`（`Run Date = Mon Oct 26 22:43:05 2026`，bit 产物 22:48:28）。首次构建 `build_hdmi_audio.txt`（22:25:29 启动）早于 `rtl/audio/buzzer_tone.v` 最后写入（22:30:38），那一版用的是旧源码，数字已作废。

加密核被 TD 正确读入：日志有 `HDL-1007 : analyze verilog file hdmi/enc/hdmi_1_4b_transmitter_core_wrapper.enc.v` 与带全部参数的 `elaborate module hdmi_1_4b_transmitter_core_wrapper(...)`。

资源对比：

| 项目 | 改造前 | 改造后 | 变化 |
|---|---|---|---|
| LUT | 8215 (41.91%) | 9467 (48.30%) | +1252 |
| REG | 3773 (19.25%) | 5243 (26.75%) | +1470 |
| LE | 8852 | 10174 | +1322 |
| BRAM | 3 | 17 | **+14** |
| DSP / PLL / IO | 13 / 2 / 41 | 13 / 2 / 41 | 0 |

新模块自身占用（`area.txt` 分模块表，列序 `le / lut / ripple / seq / bram`）：`u_hdmi_core` le 1752 / lut 1328 / seq 1334 / bram 14（加密核），`u_axis` 231/230/85，`u_tone` 164/117/91，`u_arc` 61/35/45，`u_pwm_audio` 52/26/39，`u_phy` 45/36/45（`u_lane_ch0/1/2 + u_lane_clk` 分别 16/12/12/5 LE）。**加密核一个实例吃掉新增 LUT 的 98% 与全部 14 块 BRAM。**

**时序结论**：WNS 仍是 −7.232 ns，且最差路径与改造前**完全同一路径同一数值**：

```
Begin Point : u_sdram_sip.dq[0]        (u_sdram_pll clkc[2], 150 MHz 180°)
End Point   : u_sdram_sip_syn_1.bpad   (u_sdram_pll clkc[1], 150 MHz 0°)
Slack       : -7.232 ns
```

这是 SiP SDRAM 器件接口路径，与本次音频改动无因果关系。**本次改动没有引入新的时序违例。**

### 边界说明（不得含糊）

1. **加密核无法仿真**：Anlogic RSA + AES128-CBC 加密件，ModelSim ASE 无对应私钥无法编译。仿真只覆盖到"交给核的 AXIS / audio / ACR 三组信号正确"为止，核内部行为（TMDS 编码、音频包插入、相位匹配）**未被仿真验证**。
2. **上板未做**：正式顶层从未上板，音频是否真从显示器出来**未验证**。三档口径下状态是"仿真 + 综合布线通过，上板未验证"，不能宣称"能出声"。
3. **音频是合成音**：8 音 LUT + 三角波，无 WAV/MP3 解码、无 SD 卡音频素材。
4. **无音量控制**：KEY6 只有静音开关。
5. **旧模块保留但不构建**：`rtl/audio/pwm_audio_out.v`、`rtl/video/hdmi/hdmi_tx.vhd` 留在源码树作历史参照与回退路径；`project/hdmi_td.al` 的 VHDL 段已清空。

### 证据链影响

`scripts/check_image_path_diag.py` 现在报 `evidence_invalid`（`Changed input: rtl/audio/buzzer_tone.v`、`rtl/control/player_ctrl.v`、`rtl/top/dmz_eg4s20_hdmi_top.v` 等）。**这是预期的失效，不是回归**：该脚本把 2026-10-20 那次诊断构建的 SHA256 绑死在源码上，本次改动让旧证据按设计自动失效——这正是"证据链原则"要求的。诊断工程 `image_dm_fix` 的结论仍然是它当时那版代码的结论，未被本次改动推翻，也不能用来为本次改动背书。

## S9：KEY7～KEY14 键位分配与画面后处理（2026-10-26）

把 `TASKS.md` A5 遗留的"16 键仅用 8 个"补完：KEY7～KEY14 八个键全部编号到功能，并顺势补上 B1/B3/C1 三项空白任务的第一层实现。完整论述（含逐键设计理由、取舍、上板前须知）见 [键位分配与实现交接](keymap_2026-10-26.md)。

### 新增 2 个模块

| 模块 | 行数 | 作用 | 关键点 |
|---|---|---|---|
| `rtl/control/key_action.v` | 142 | KEY7～KEY14 的**唯一**译码点 | 只有 1 个时序 always 块；8 个键号写成 `localparam`；`rescan_req` 在块首无条件清 0 做成单拍脉冲 |
| `rtl/video/video_overlay.v` | 185 | 亮度五档 / 反色 / 九宫格 / 信息条 / 音频电平条 | **纯组合零寄存器**，与输入同拍；处理顺序 亮度→反色→OSD，OSD 不受前两级影响；全关时 `rgb_out === rgb_in` |

### 改动的既有模块（最小侵入）

- `rtl/control/player_ctrl.v`：新增输入 `auto_sw_sel[1:0]`。原轮播间隔是编译期常量 `AUTO_TICKS`，现改为
  `wire [31:0] auto_target = (sel==1)?(T<<1):(sel==2)?(T+(T<<1)):(sel==3)?(T<<2):T;`，判据由 `auto_cnt == AUTO_TICKS-1`
  改成 `auto_cnt == auto_target-1`。新增 `auto_sw_sel_d` 检测改档并在当拍清计时器（否则从 ×4 的 15 s 按到 ×1 的 5 s
  会当场跳一张，用户感觉"按一下连跳两张"）。**默认档 0 下 `auto_target == AUTO_TICKS`，逐拍等价于改造前。**
  ×3 写成 `T+(T<<1)` 而非 `T*3`，避免推乘法器；上限 5 s × 4 = 500,000,000 < 2²⁹。
- `rtl/storage/gallery_probe.v`：新增输入 `rescan`，在**唯一**时序块内加一条前置分支
  `if (rescan && sd_ok && ((st==G_DONE)||(st==G_FAIL)))` → 清 `done/fail/err_code`、回 `G_ARST` 重扫。
  三个条件缺一不可：`sd_ok` 保证没插卡时按键无副作用；`st` 必须是终态保证扫描中按键被忽略
  （否则两个扫描序列交叠，`probe_idx`/`hit_cnt` 被写脏，张数变成随机值）。
- `rtl/top/dmz_eg4s20_hdmi_top.v`：加 `key_action` / `video_overlay` 例化；`video_rgb` 由直接表达式改成
  `video_base` → `video_overlay` → `video_rgb`；蜂鸣器改为 `beep_muted ? 3'd0 : (alarm_req ? 3'd3 : (mode==2 ? 3'd2 : 3'd1))`。
- `rtl/top/dmz_eg4s20_bringup_top.v`：同步键位表；补接历史上漏掉的 `loader_index` 与 `vblank`；
  `tone_sel` 由 2 位常量改正为 3 位（`buzzer_tone` 的该端口本来就是 3 位）。

### 验证证据

**仿真（通过）**：前端回归 13 个用例全部 `passed=True`、exit 0，报告在 `reports/s7_keymap/frontend/`：

```
sd_protocol_default: passed=True; passLines=62
sd_protocol_fast:    passed=True; passLines=64
sd_spi_ctrl:         passed=True; passLines=23
sd_probe:            passed=True; passLines=14
fat32_reader:        passed=True; passLines=40
gallery_probe:       passed=True; passLines=37
bmp_parser:          passed=True; passLines=37
img_loader:          passed=True; passLines=43
player_ctrl:         passed=True; passLines=94
err_prompt:          passed=True; passLines=43
buzzer_tone:         passed=True; passLines=23
key_action:          passed=True; passLines=40
video_overlay:       passed=True; passLines=64
```

- `tb_key_action.v`（新增 298 行）9 个用例 K01～K09 / 40 条断言：复位默认值、五档循环、反色翻转、四位回绕、
  重扫**恰好 1 拍脉冲且从不连续两拍为高**、四个开关独立、无关键号（KEY0~KEY6/KEY15）按下后 8 个输出全不变、
  互不干扰、复位恢复。
- `tb_video_overlay.v`（新增 425 行）10 个用例 V01～V10 / 64 条断言，**无时钟驱动**，全部"设坐标 → `#1` → 采样"，
  268 ns 跑完。关键：V03 五档亮度实测 `255→255/224/192/161/127`、`128→128/112/96/80/64`、`64→64/56/48/40/32`；
  V06 电平条 `sample=524288` → `level_top=348`、`2097151` → `253`、零样本只剩 `y=380` 一行；
  V10 **最暗 + 反色下 OSD 四元素颜色一字不变，同时图像层 `FF→80` 确实被调暗又反色**。
- `tb_player_ctrl.v`：补 U19（`dut_fast` 实测 ×1 间隔 240~260 拍、×4 间隔 985~1015 拍）、U20（层次引用
  `dut.auto_target` 断言 25M/50M/75M/100M 四档阈值）；U05 改名"非本模块键号"并补 `key_code=14`。
- `tb_gallery_probe.v`：补 W08（终态重扫 → `count` 由 2 变 4、`first_img_req` 恰好 1 拍）、
  W09（**扫描中 rescan 必须被忽略**，`count` 仍为 3）、W10（失败态重扫 → `count=3`、`err=0`）。
- `tb_dmz_eg4s20_bringup`：全 PASS / `errors = 0`，并消除了两条历史 ModelSim 警告
  （`u_vtg` 缺 `vblank` 的 TFMPC、`u_buzz` 端口 3 vs 2 的 PCDPC）。

**静态检查（通过）**：`python scripts/lint_verilog.py rtl project/src project/hdmi` → 77 文件，E0/E1/E2 全 0。
`scripts/sync_src.ps1` 通过（11/41 个副本更新）。

### 边界说明（不得含糊）

1. **八个新键从未上板按下**。全部结论只到仿真档。
2. **没有重新综合布线**：`video_overlay` 是大块组合比较逻辑，LUT 占用与关键路径影响**未知**；
   SiP SDRAM 接口 WNS 仍为 −7.232 ns（本轮改动全在 `clk_pixel` 域，不碰 150 MHz 路径，**没有新增时序证据**）。
3. **信息条不是字幕**：12 个格位显示的是二进制位图块，不是字符。真正的文字字幕需要字模 ROM 与逐行扫描，
   `rtl/osd/` 至今为空。B1 只完成了"图层叠加"这一半。
4. **音频电平条不是频谱**：只取 PCM 幅度画柱，没有 FFT。C1 只完成"幅度可视化"。
5. **参数不保存**：亮度/反色/倍率掉电即恢复默认。

### 工程教训（本轮再次踩到）

- 新增 `.v` 必须同时改 `project/hdmi_td.al`，否则 TD 判 black box（历史 commit `e41315a` 因此缺 12 个源）；
- 新增 TB 必须同时加进 `sim/scripts/run_frontend_regression.ps1` 的 `$sources`，否则根本不会被编译；
- 该回归脚本判定中还含一条正则 `FAIL\b`：**TB 里任何以 `FAIL` 开头的打印行都会让整例判失败**，即使用例本身通过。

## S10：双缓冲无缝切换（2026-10-27）

`TASKS.md` A6 的缺口「未上板；单缓冲，切图期间显示测试图，无双缓冲无缝切换」就此闭合。
`image_player` 从单帧缓冲改为**双缓冲无缝切换**：装载写后台帧、前台继续读旧帧，
写完整后等下一个垂直消隐再换帧首。重载期间屏幕一帧不断，装载失败保留上一帧。
完整论述（含方案推导、逐模块改动、失败语义不对称的原因）见
[双缓冲无缝切换实现交接](seamless_double_buffer_2026-10-27.md)。

### 改造面：3 个 RTL，顶层零改动

| 文件 | 改动 | 要点 |
|---|---|---|
| `rtl/storage/pix_reader.v` | +1/−2 行 | `rd_base` 由 `output`（`assign rd_base = FRAME_BASE`）改为 **input**，由上层选帧 |
| `rtl/storage/framebuf_arbiter.v` | +9 行 | 新增 `rd_frame_base`/`rd_frame_last`，读侧回绕边界随 `rd_restart` 捕获的基址重算 |
| `rtl/storage/image_player.v` | 274 → 334 行 | 双缓冲索引、复位解耦、提交挂起、失败语义分离 |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | **0 行** | 对外保持 `rgb565`/`pixel_valid`/`image_ready` 语义不变，缓冲封装在模块内 |

**写侧一行未改**：`framebuf_arbiter` 在 `WR_ADDR_FROM_FIFO=1` 下写地址由 57 bit FIFO 携带，
`image_player` 只需在 `word_addr` 上加 `back_off` 偏移。

### 核心设计：两处必须改，两处必须拆

1. **读侧 wrap 判据（必须改）**：改造前 `if (rd_addr >= FRAME_LAST) rd_addr <= FRAME_BASE;`
   只认编译期 `FRAME_BASE = 0`。读基址设成 153600 后，第一组读完 `rd_addr >= 153596` 立刻成立，
   回绕回 0 —— 即读后台帧时实际读到第 0 帧。改为 `rd_frame_last`/`rd_frame_base` 运行期量。
2. **复位必须拆（必须拆）**：旧设计 `path_rst_pix`/`path_rst_sdr` 一套复位同时管
   `img_loader`/`bmp_parser`/双 FIFO/`framebuf_arbiter`/`sdram_ctrl_wrap`/`pix_reader`，
   装载一开始就断供前台。拆为 `loader_rst_*`（随装载启停）与 `store_rst_*`
   （`store_enable = loader_enable || (SEAMLESS && image_ready)`，已有在显帧就保持释放）。
3. **`arb_error_sync` 单独用 `rst_n_pix` 复位**：仲裁故障粘滞，跟着装载清掉会让看门狗失效。
4. **提交挂起**：`C_COMMIT` 只置 `commit_pending`，等 `vblank_rise`（或首次装载 `!image_ready`）
   才 `front_sel <= back_sel`，换帧落在消隐内不撕裂。

### 失败语义刻意不对称

| 失败类型 | 错误码 | `image_ready` | 屏幕 |
|---|---|---|---|
| 装载侧（缺图/坏 BMP/像素数/超时） | 1~7、9 | **保持 1** | 继续显示上一帧 |
| 存储侧（仲裁错误、SDRAM 失锁） | 8 | **必须清 0** | 回落测试图 |

存储侧必须清的原因是 `pix_reader` 的 `rst_n_pix = store_rst_pix && image_ready`、
`reader_async_sdr = store_rst_sdr && image_ready` —— **显示通路的复位释放依赖 `image_ready`**，
不撤则粘滞错误永远清不掉。装载侧不涉及显示通路，保留旧帧安全。

`SEAMLESS=0` 退回单帧缓冲，`back_sel` 恒 0、读写都落第 0 帧，**逐拍等价于改造前**，
保留作对照档以证明新逻辑没改坏旧路径。

### 验证证据

**仿真（通过）**：`run_image_regression.ps1 -FullVga` 三档全绿，报告在 `reports/s6_integration/simulation/`：

| 用例 | 断言数 | 结果 | 无缝证据 |
|---|---|---|---|
| `image_player`（32×16 快速） | 6205 | errors=0 | `front_flips=2 overlap_cycles=258005 starve_cycles=0` |
| `image_player_full`（真实 640×480） | 1,228,812 | errors=0 | `front_flips=2 overlap_cycles=2085846 starve_cycles=0` |
| `image_player_single`（`-gSEAMLESS=0` 对照） | 6203 | errors=0 | `front_flips=0 overlap_cycles=0 starve_cycles=0` |

- `overlap_cycles` = 「已有在显帧且后台正在装载」的拍数。**大于 0 才有无缝可言**，
  单帧档必然为 0。真实尺寸下 2,085,846 拍 ≈ 83 ms @25 MHz。
- `starve_cycles` = 上述拍中 `de` 有效却无像素的拍数，**必须为 0**，这是无缝的直接判据。
- 新增断言（CASE 2）：`front_changes == changes_before + 1`（恰好翻一次）、
  `seam_checked > 0`（**防假通过**：装载与显示必须真的重叠过）、`seam_gaps == 0`。

**存储回归（通过）**：`run_storage_regression.ps1 -Suite All` →
`tb_async_fifo` 24 项、`tb_framebuf_arbiter` 50,900 项/15 场景、`tb_sdram_ctrl_wrap` 154,771 项、
`tb_pix_reader` 108 项，全部 errors=0。`tb_framebuf_arbiter` 参考模型的读侧 wrap 判据同步改为
`captured_restart_base + FRAME_WORDS`（旧判据写死 `FRAME_BASE`，不改则 T13 必红）。

**静态检查（通过）**：`python scripts\lint_verilog.py rtl` → 39 文件，E0/E1/E2 全 0。

### 工程教训

- **`if(FULL) $finish` 位置错误会静默跳过断言**：`tb_image_player.v` 的 FULL 分支原本在 CASE 1
  之后就 `$finish`，意味着改造前「FULL 全尺寸通过」只覆盖了 CASE 1，新加的双缓冲断言被整个跳过。
  已把该块移到 CASE 2 之后。**这类「测试台结构性漏测」比断言写错更难发现**——它不报错、不告警，
  只是少跑了。
- **`wire` 改 `reg` 时，所有例化点都要查**：`pix_reader.rd_base` 变输入端口后，
  除 3 个自研 TB 外，还有 3 个历史诊断工程（`project/image_*_diag/`、`project/image_dm_fix/`）
  里 `wire [20:0] rd_base;` 失去驱动源。这些工程不走 `sync_src.ps1`，容易漏。
- **`edit` 工具会丢 UTF-8 BOM**：`run_image_regression.ps1` 原带 BOM，编辑后 BOM 丢失，
  而 Windows PowerShell 5.1 在无 BOM 时按 GBK 解析，文件内 28 个中文字符会变乱码。
  已用 `UTF8Encoding($true)` 补回。**改带中文的 `.ps1` 后必须查 BOM。**
- `tb_probe_order.v`/`tb_probe_pix.v` 无法加载是**既有问题**（被 `.gitignore:54` 的
  `sim/testbench/tb_probe_*.v` 排除、且引用的 `dut.fifo_wr_data` 等信号早已不存在），
  与本次改动无关，不作为交付证据。

### 遗留

1. **未上板**；**SiP SDRAM 150 MHz setup 违例未变**（WNS −7.232 ns），本次改动未经过真实布线后时序验收。
2. 资源占用未重新测量（新增约 2 个 21 bit 寄存器 + 1 个加法器 + 跨域同步寄存器，预计增量极小）。
3. **失败可见性变弱**：装载侧失败时屏幕仍显旧帧，须靠数码管 DIG2/LED 判故障。这是无缝的代价。
4. 只支持 2 缓冲；SDRAM 能放 13 帧，N 缓冲需另一套调度，本次不做。

## S11：SDRAM 时钟网络修复与时序收敛定性（2026-10-27）

任务目标：解决正式顶层 `dmz_eg4s20_hdmi_top` 的时序收敛问题，起点是布线后
**setup SWNS −7.232 ns / STNS −335.004 ns**、64 个违例端点全部集中在 SiP SDRAM 接口。

### 一、先把违例拆开看：64 个端点其实分属两件事

`reports/s6_integration/timing.txt` 的 7 个 Path Group 里，只有三组有故事：

| Path Group | 修复前 SWNS | 修复前 STNS | 违例端点 | 性质 |
|---|---|---|---|---|
| `clkc[1] → clkc[1]` Self | +0.240 ns | 0 | **0 / 2590** | 真实 150 MHz 逻辑，已收敛但余量薄 |
| `clkc[2] → clkc[1]` | **−7.232 ns** | −231.424 ns | 32 / 32 | SiP 接口读回 |
| `clkc[1] → clkc[2]` | **−3.537 ns** | −103.580 ns | 32 / 48 | SiP 接口写出 |

后两组同属一颗 PLL 的 0°/180° 双相时钟。**关键发现：`clkc[1]` 自身域早就收敛了**，
所以"150 MHz 收敛不了"这个说法本身是错的——收敛不了的是接口组，两者根因完全不同。

### 二、真缺陷：C1/C2 输出没有走全局时钟网

`rtl/storage/sdram_pll.v` 原来只有 C0 经 `bufg_feedback` 进 BUFG（且兼作 PLL 反馈），
真正驱动 844 个负载的 **C1（150 MHz 0°）** 和送 SDRAM_CLK 的 **C2（150 MHz 180°）**
直接从 PLL 引到端口，由布局器自行决定走什么网络。后果在报告里可以直接读到：

| 现象 | 证据 |
|---|---|
| C1 走普通布线，延迟 2.410 ns | Clock Summary `clk1` fanout 869，路径 launch 段 `net u_sdram_pll/clk1_raw 2.410ns` |
| C2 被判 local routing | **`PHY-5079` CRITICAL-WARNING**：CTS Local Wire Summary 显示 `clkc[2] → u_sdr_as_ram/SDRAM_CLK`，fanout 1，LocalWireNum 1 |
| 两颗 PLL 反馈都走 local network | **`USR-6135` CRITICAL-WARNING ×2**：补偿延迟不可预测 |

修复：给 C1、C2 各补一级 `EG_LOGIC_BUFG`。

```verilog
wire clk1_buf, clk2_buf;
EG_LOGIC_BUFG bufg_clk1 (.i (clk1_raw), .o (clk1_buf));
EG_LOGIC_BUFG bufg_clk2 (.i (clk2_raw), .o (clk2_buf));
assign sdram_clk     = clk1_buf;
assign sdram_clk_sft = clk2_buf;
```

**不能给 C0 再加第二个 BUFG**——一个 PLL 通道只能进一个 BUFG，C0 已通过 `bufg_feedback` 进去了。

收益（`clkc[1]` 自身域）：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| Setup WNS | +0.240 ns | **+0.326 ns** |
| Min Period / Fmax | 6.426 ns / 155.618 MHz | **6.340 ns / 157.729 MHz** |
| 违例端点 | 0 / 2590 | 0 / 2590 |
| `PHY-5079` / `USR-6135` | 1 / 2 | **0 / 0** |
| `#gclk` | 2 / 16 | **4 / 16** |

修复后报告明确显示时钟走 GCLK：
`net (fo=1) u_sdram_pll/clk1_raw → GCLK x039y070z2 u_sdram_pll/bufg_clk1.clko 0.000ns`。

### 三、接口违例为什么改 RTL 无解

`clkc[2] → clkc[1]` 最差路径（修复后仍是最差）：

```
Begin : u_sdram_sip.dq[0]                   (clkc[2] rise @3.333)
          PAD x040y041      3.816 ns
          launch edge               @9.165 ns
          input (hard ip)   +5.000 ns   ← TD 对 SiP 硬核的固定惩罚
End   : u_sdram_sip_syn_1.bpad → sdr_wrrd.enc.v 的 Sdr_rd_dout[0]  (clkc[1] rise @6.666)

Budget          3.333 ns
Data Path Delay 6.453 ns  （cell 100%，net 0.000%）
Logic Level     0
Max Fanout      0
Clock Skew      4.172 ns
```

**预算 3.333 ns（半个周期），单项 hard-ip 惩罚 5.000 ns。5 > 3.333，通路为空 slack 也必负。**
`Logic Level = 0`、`net 延迟 0.000 ns`——数据通路上没有任何组合逻辑可以优化。
另一方向 `clkc[1] → clkc[2]` 同构，惩罚项是 `output (hard ip) −5.000 ns`。

物理含义：DQ 的实际采样者是封装内的 SDRAM 器件，读回的 DQ 由安路加密核 `sdr_wrrd`
内部自行重采样，RTL 层并不存在"0° 触发器直接采 180° 域 DQ"的路径。这是 TD 的 SiP
硬核接口模型在 150 MHz 下的建模口径问题。

旁证：2026-10-20 那次真机跑出红块、整帧比较通过的诊断工程，
`reports/image_dm_fix/candidate.json` 里 `setup_wns_ns` 同样是 **−7.232**、`timing_passed: false`、
`status: "functional_board_pass_reported_timing_failed"`——负余量并未阻止硬件工作。

### 四、三组对照实验：拆异步组是假绿（复验历史结论）

仓库既有立场（`README.md:183`、本文件 S5-4）明确禁止把 0°/180° 声明为异步组。
本轮一度按"拆组"方式做过，SWNS 从 −7.232 变成 +0.275，看着像修好了。
为了区分"BUFG 修复的功劳"和"拆组动作的功劳"，补做了第三组对照：

| 实验 | RTL | 时钟组 | SWNS | STNS |
|---|---|---|---|---|
| ① 原始 | C1/C2 无 BUFG | 0°/180° 同组 | −7.232 ns | −335.004 ns |
| ② 拆组 | C1/C2 **加 BUFG** | 0°/180° **拆异步** | +0.275 ns | 0.000 ns |
| ③ 对照 | C1/C2 **加 BUFG** | 0°/180° **同组** | −7.232 ns | −335.004 ns |

**实验 ③ 是决定性的**：加了 BUFG 之后，只要保留 0°/180° 分析，接口余量**一个数字都不变**。
所以实验 ② 里那个 +0.275 ns 全部来自把路径移出分析范围，与 BUFG 无关、与接口无关。
**结论与历史一致：0°/180° 必须留在同一时钟组，不得再用拆组方式让报告变绿。**

最终 SDC 因此回退为原始 5 条有效约束，只在文件头补充了上述调查结论，
避免后来者重走这条路。

### 五、两条已实测排除的优化手段

| 手段 | 结果 | 结论 |
|---|---|---|
| `phys_opt -post_place -effort high` | SWNS 0.275 → **0.178 ns**（更差） | 它为全局重布线腾资源，反而打散了那条依赖短走线的路径 |
| `phys_opt -post_route -effort high` | **`0xC0000005` 崩溃**，流程在 PASS-route 后中断 | TD 6.2.168116 缺陷，不要用 |

### 六、收敛后的真实瓶颈

`clkc[1]` 自身域最差路径（`final.timing`）：

```
u_player/u_reader/rd_gray_meta_reg[10] → u_player/u_reader/u_pix_fifo/ramread0_syn_5216.e[0]
Data Path Delay 5.995 ns  （cell 1.107 = 18%，net 4.888 = 82%）
Logic Level 4（LUT4/LUT3/LUT2/DRAM 各 1）
Skew 0.136   Max Fanout 35   Slack +0.326
```

**82% 是走线延迟，逻辑层级只有 4**——这条路径靠布局收紧，不靠改逻辑。
后续若要拉大余量，方向是 `set_seed_param` 多种子布局择优，而不是重构 `pix_reader`。

### 七、遗留

1. ~~**接口组仍报 −7.232 ns**~~ → **已在 S12 通过降频到 40 MHz 解决**（见下一节）。
   本节当时的判断"真实解法只有两条：补 `set_input_delay`/`set_output_delay` 重新建模，或用 `set_multicycle_path`"**只对了一半**：
   两条路都无法让 150 MHz 下的接口组收敛，因为 5.000 ns 的硬核惩罚已经超过半周期预算 3.333 ns，
   重新建模只能改变"报不报红"，改变不了物理事实。真正的解法是**降低时钟频率，给足预算**。
2. 余量 +0.326 ns 只占 6.666 ns 周期的 4.9%，Skew 0.480 ns 偏大。若追求更大余量，
   可跑多种子布局择优。（S12 降频后该路径余量已变为 +16.706 ns，这个问题自然消解。）
3. `u_sdram_sip` 位置约束仍未被遵守（`PHY-7002` ×2，期望 (12,12) 与 (164,288)），
   不影响时序，属整洁性问题。**该项至今仍然存在**（40 MHz 构建中计数仍为 2）。

验证入口：`project/verify_timing_final.tcl`，产物在 `reports/timing_final_20261027/`。

---

## S12：SDRAM 降频到 40MHz 后时序全部收敛（2026-10-27）

> 本节是阶段四「SDRAM 接口时序」这一长期阻塞项的收口记录。
> 从 S11 的「已定性为硬核模型口径问题」，走到「真实收敛、位流 EXIT 0」。
> **关键点：SDC 一条约束都没改，改的是时钟频率。**

### 一、决策链

| 时间 | 决策 | 依据 |
|---|---|---|
| S11 收尾 | 确认 150 MHz 下接口组数学无解 | 5.000 ns 硬核惩罚 > 半周期 3.333 ns |
| 2026-10-27 | **方案 A：降到 100 MHz**（用户选择） | 安路社区实测「ODDR→OPAD→SDRAM→DQ→IDDR 约 5 ns」「实用主频不超过 100 MHz」 |
| 100 MHz 实测后 | **再降到 40 MHz**（用户选择） | 100 MHz 仍为负，反推出常数开销与临界频率 |

**为什么没有走另外三条路**（全部实测排除，详见 README「已排除的捷径」）：

1. **拆异步组**：得到 SWNS +0.275 ns / STNS 0 是全绿，但三组对照实验证明——
   加了 BUFG 却保留 0°/180° 同组时，接口组数字**一个都不变**（−7.232 / −335.004）。
   即拆组只是把路径移出分析视野，不是修好。仓库历史上已因此翻过一次车（+0.104 ns 假绿）。
2. **`phys_opt`**：`-post_place -effort high` 反而从 0.275 掉到 0.178 ns（为全局重布线腾资源，
   打散了依赖短走线的路径）；`-post_route` 在 TD 6.2.168116 上直接崩溃（`0xC0000005`）。
3. **`set_multicycle_path`**：官方 SWUG200 §5.3.4.6 确实给了这个用法，
   但 MEGA65 项目（Xilinx Artix-7 + SDRAM）的 xdc 注释实测记录「导致 5.6 ns 无端延迟，反而阻止时序收敛」。
   跨品牌反噬案例，不采用。

### 二、100 MHz 实测：为什么还不够

`reports/timing_100mhz_20261027/run.ts`：

```
SWNS: -5.565ns, STNS: -231.925ns.
HWNS: 0.019ns, HTNS: 0.000ns.
```

逐组结果（关键三组）：

| Path Group | SWNS | STNS | 违例端点 |
|---|---|---|---|
| `clkc[1]→clkc[1]`（内部逻辑） | **+2.604** | 0.000 | 0 / 2581 |
| `clkc[2]→clkc[1]`（读 DQ） | **−5.565** | −178.080 | **32 / 32** |
| `clkc[1]→clkc[2]`（写 DQ） | **−2.001** | −53.845 | **32 / 48** |

**内部逻辑域余量大好（+2.604 ns，0 违例）**——这排除了"设计本身太慢"的可能，
把矛头精确指向 SiP 接口。降频让全部违例从 −7.232/−3.537 改善到 −5.565/−2.001，但仍然为负。

### 三、常数开销：把两个数据点变成一条公式

用 150 MHz 与 100 MHz 两组实测反推（`slack` 与 `T/2` 呈线性，截距即常数开销）：

| 路径 | 150 MHz（T/2 = 3.333 ns） | 100 MHz（T/2 = 5.000 ns） | 反推公式 |
|---|---|---|---|
| 读 DQ | −7.232 | −5.565 | **slack = T/2 − 10.565** |
| 写 DQ | −3.537 | −2.001 | **slack = T/2 − 7.001** |

两点互证误差 < 0.2 ns。常数 10.565 ns 的构成：
**5.000 ns 的 TD 硬核接口模型惩罚 + 4.172 ns 时钟树偏斜 + 1.393 ns 封装走线**。

由此得临界频率：

- 读 DQ 收敛条件 `T/2 ≥ 10.565` → **T ≥ 21.130 ns → f ≤ 47.33 MHz**（瓶颈）
- 写 DQ 收敛条件 `T/2 ≥ 7.001` → **T ≥ 14.002 ns → f ≤ 71.42 MHz**

**100 MHz 位于两者之上，必然仍红；要真收敛必须 ≤ 47 MHz。**

### 四、40 MHz 参数与实测

VCO 保持 **1000 MHz 不变**（只改 C1/C2 分频比，环路滤波无需重验）：

| 参数 | 150 MHz | 100 MHz | **40 MHz** |
|---|---|---|---|
| `CLKC1_DIV` | 7 | 10 | **25** |
| `CLKC1_CPHASE` / `FPHASE` | 6 / 0 | 9 / 0 | **24 / 0** |
| `CLKC2_DIV` | 7 | 10 | **25** |
| `CLKC2_CPHASE` / `FPHASE` | 2 / 4 | 4 / 0 | **11 / 4** |
| `CLKC0_DIV`（12.5 MHz 反馈） | 84 | 80 | **80** |

相移编码公式（用两个官方样本验证过）：
**相位延时 = (CPHASE + 1) + FPHASE/8 个 VCO 周期；相移角度 = 延时 / CLKCx_DIV × 360°**
- C1：DIV=25，CPHASE=24 → (25)/25 = 1.0 整圈 → 0° ✓
- C2：DIV=25（奇数），CPHASE=11 + FPHASE=4 → (12+0.5)/25 = 0.5 → 180° ✓
- 偶数 DIV 的 180° 写法：`CPHASE = DIV/2 − 1, FPHASE = 0`

TD 自身确认（构建日志 `USR-1002`）：
```
create_generated_clock -name {u_sdram_pll/pll_inst.clkc[1]} ... -divide_by 1.2500 ...
create_generated_clock -name {u_sdram_pll/pll_inst.clkc[2]} ... -divide_by 1.2500 -phase 180 ...
```
50 / 1.25 = 40 MHz，180° 相位被正确识别。

**实测**（`reports/timing_40mhz_20261027/run.ts`）：

```
SWNS: 1.935ns, STNS: 0.000ns.
HWNS: 0.011ns, HTNS: 0.000ns.
Period Check WNS: 0.000ns
```

预测读 +1.935 / 写 +5.499，实测读 **+1.935** / 写 **+5.630** —— 完全吻合。

逐 Path Group（**7 组全部 0 违例**）：

| Path Group | Min Period | Fmax | SWNS | STNS | 违例 / 端点 |
|---|---|---|---|---|---|
| `clkc[0]→clkc[0]` | 19.838 | 50.408 MHz | +20.162 | 0.000 | 0 / 8379 |
| `clkc[1]→clkc[1]` | 8.294 | 120.570 MHz | **+16.706** | 0.000 | 0 / 2578 |
| `clkc[2]→clkc[2]` | — | — | +6.113 | 0.000 | 0 / 74 |
| `clkc[0]→clkc[2]` | — | — | +6.554 | 0.000 | 0 / 32 |
| `clk→clk` | 2.910 | 343.643 MHz | +17.090 | 0.000 | 0 / 8 |
| `clkc[1]→clkc[2]`（写 DQ） | 13.740 | 72.780 MHz | **+5.630** | 0.000 | **0 / 48** |
| `clkc[2]→clkc[1]`（读 DQ） | 21.130 | 47.326 MHz | **+1.935** | 0.000 | **0 / 32** |

**读 DQ 的 +1.935 ns 是全设计最小余量**（上板应优先验证该路径稳定性）。

### 五、决定性证据：延迟是常数，只有预算在变

读 DQ 最差路径在三个频率下的 `Data Path Delay` **完全相同**：

```
Begin: u_sdram_sip.dq[0]        (clkc[2])
  PAD x020y071                    1.660
  PLL clkc[2]                    -2.201
  net SDRAM_CLK (fo=1)            2.557
  PAD x040y041                    3.816
  launch edge                     T/2
  input (hard ip)                +5.000   ← TD 硬核模型固定惩罚
  PAD(reg) x000y059               1.453
  Arrival
End:   u_sdram_sip_syn_1.bpad → sdr_wrrd.enc.v 的 Sdr_rd_dout[0]  (clkc[1])
  Data Path Delay              6.453 ns  （cell 100% / net 0.000）
  Clock Skew                   4.172 ns
  Logic Level                  0        ← 数据通路上没有任何组合逻辑
```

| 频率 | T/2 | Data Path Delay | Slack |
|---|---|---|---|
| 150 MHz | 3.333 | **6.453** | −7.232 |
| 100 MHz | 5.000 | **6.453** | −5.565 |
| 40 MHz | 12.500 | **6.453** | +1.935 |

`Logic Level 0` + `net 延迟 0.000` 说明这条路径上**没有任何可优化的逻辑**。
这就是"改 RTL 无效、只有给足预算有效"的硬证据。

### 六、连带修改清单（降频必须同步改三处）

| 文件 | 位置 | 改动 |
|---|---|---|
| `ip/local/sdram/global_def.v` | 第 11 行 | `` `define SDR_CLK_PERIOD 1000000000/40000000 `` |
| `rtl/storage/sdram_ctrl_wrap.v` | 第 76 行 | `parameter CLK_FREQ_HZ = 40_000_000` |
| `rtl/storage/sdram_bringup_top.v` | 第 136 行 | `.CLK_FREQ_HZ (40_000_000)` |

**刷新自检**：`SDR_CLK_PERIOD = 25 ns`，
`SELF_REFRESH_INTERVAL = 64000000/25/2048 = 1250` 周期 = **31,250 ns ≈ 31 µs**
（远小于 SDRAM 64 ms 刷新窗口，安全）。

### 七、代价与带宽核算

| 频率 | 理论带宽 | 相对 640×480@60Hz 需求（55.3 MB/s） | 接口余量 |
|---|---|---|---|
| 150 MHz | 600 MB/s | 10.8× | −7.232 ns ❌ 数学无解 |
| 100 MHz | 400 MB/s | 7.2× | −5.565 ns ❌ |
| **40 MHz** | **160 MB/s** | **2.9×** | **+1.935 ns ✅** |

**代价是带宽从 600 降到 160 MB/s，但仍富余 2.9 倍，功能无损失。**
换成"能用"而不是"看起来通过"，是这次取舍的核心。

### 八、资源占用（降频不消耗额外资源）

来源 `reports/timing_40mhz_20261027/area.txt`：

| 资源 | 用量 | 占比 |
|---|---|---|
| LUT | 10,009 / 19,600 | **51.07%** |
| 寄存器 | 5,326 / 19,600 | **27.17%** |
| LE | 10,849 | — |
| BRAM9K | 17 / 64 | 26.56% |
| DSP | 13 / 29 | 44.83% |
| PLL | 2 / 4 | 50.00% |
| GCLK | 4 / 16 | 25.00% |
| IO | 41 / 188 | 21.81% |

与 100 MHz 版（LUT 9,989 / reg 5,326）几乎一致 —— **降频不消耗额外资源**。

### 九、位流生成

`project/flow_s6_bit.tcl` 完整走完综合→布局→布线→bitgen，并自检时序：

```
S6_PASS-optimize_rtl / S6_PASS-optimize_gate / S6_PASS-place / S6_PASS-route
BIT-1004 : Generate bits file .../hdmi_td.bit
S6_BIT_FLOW_DONE
S6_TIMING_PASSED          ← 150 MHz 时这里是 S6_TIMING_FAILED
EXIT 0                    ← 150 MHz 时是 EXIT 3
```

产物：`project/hdmi_td_Runs/phy_1/hdmi_td.bit`，**629,640 B，2026-10-27 21:12:30**。
`reports/s6_integration/timing.txt` 745,631 B / `area.txt` 22,526 B / `coverage.txt` 37,478 B 同步刷新。

### 十、约束文件状态（重要）

**`constraints/dmz_eg4s20_hdmi.sdc` 的有效约束一条都没改**，仍是：

```tcl
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[0] u_pll/pll_inst.clkc[2]}] \
    -group [get_clocks {u_sdram_pll/pll_inst.clkc[1] u_sdram_pll/pll_inst.clkc[2]}]
```

`clkc[1]` 与 `clkc[2]` **仍在同一时钟组**，0°/180° 相位关系完整保留在分析中。
这次收敛不是靠约束口径，是靠真实降低频率 —— 所以每个数字都可信。

文件头新增了约 60 行注释，记录两次降频的完整推理（三组对照实验、常数开销公式、
临界频率、为什么不用 multicycle/拆组刷绿、连带修改清单）。

### 十一、告警变化

| 告警 | 150 MHz 构建 | 40 MHz 构建 |
|---|---|---|
| `PHY-5079`（时钟走 local routing） | 0（S11 已修） | **0** |
| `USR-6135`（PLL 反馈走 local network） | 2 | **0** |
| `PHY-7002`（u_sdram_sip 位置未遵守） | 2 | 2（遗留） |
| `SYN-5013`（undriven net） | 2 | 2（遗留） |
| ERROR | — | **0** |

### 十二、遗留与下一步

1. **正式顶层仍未上板**。当前位流是时序收敛后的正式位流（EXIT 0 / `S6_TIMING_PASSED`），
   但从未上过板，结论须按「时序通过 + 未做硬件验证」陈述。
   上板后应优先验证**读 DQ 路径**（+1.935 ns 是全设计最小余量）：连续换图、长时轮播。
2. **SDRAM 频率回调的可行性**。临界频率读 47.33 MHz，理论上 47 MHz 也能收敛。
   上板后做长时读回压力测试，再决定是否回调到更高频率（带宽换余量）。
3. **物理时序余量需示波器实测**。安路社区提到「时钟提前 2.666 ns 时读时序 bug 基本消失」，
   说明该接口的物理时序与工具报告之间存在偏移，静态时序通过不等于眼图合格。
4. `PHY-7002` ×2（`u_sdram_sip` 位置约束期望 (12,12) 与 (164,288) 未被遵守），
   不影响时序，属整洁性问题。

验证入口：`project/verify_timing_40mhz.tcl`，产物在 `reports/timing_40mhz_20261027/`，
分析见 `reports/timing_40mhz_20261027/README.md`。

**上板验证入口：`docs/board_verification_2026-10-27.md`**

该文档把本文档中所有 🔶/⬜ 条目编排成一份可一次跑完的分阶段手册：时钟 → HDMI 显示 →
SD 与图库 → 应急与静音 → SDRAM 稳定性 → 音频，另加键盘行序与 SD MOSI/MISO 两项核定。
全部判据只落在板子上真实可观测的五个通道（HDMI 屏、8 个 LED、4 位数码管、蜂鸣器、
3.5 mm 音频），因为顶层 17 个端口没有 UART、也没有 JTAG 观测口。

SD 卡素材由 `scripts/prepare_board_verify_assets.ps1` 一键生成四套
（`good` / `bad_size` / `bad_bmp` / `empty`），分别对应「正常图库」「宽高不符」
「签名损坏」「零张图」四种期望结果。

---

## 问题记录

| 日期 | 问题 | 影响 | 处理 | 状态 |
|---|---|---|---|---|
| 2026-10-27 | **`sdram_pll` 的 C1/C2 输出没有走全局时钟网**：只有 C0 经 `bufg_feedback` 进 BUFG，驱动 844 个负载的 C1 走普通布线（延迟 2.410 ns），C2 被判 local routing | `PHY-5079` + `USR-6135` 两条 CRITICAL-WARNING；`clkc[1]` 自身域余量仅 +0.240 ns | C1/C2 各补一级 `EG_LOGIC_BUFG`；`#gclk` 2→4、余量 +0.240→+0.326 ns、两条 CRITICAL-WARNING 归零 | ✅ 已修复 |
| 2026-10-27 | **曾一度用"拆异步组"让 WNS 从 −7.232 变成 +0.275**，与仓库既有立场冲突 | 若不复验就会把假绿写进交付证据，重蹈"＋0.104 ns"的覆辙 | 补做第三组对照实验：加 BUFG 但保留 0°/180° 同组 → 接口余量一个数字都不变，证明 +0.275 全部来自拆组；SDC 回退为同组 | ✅ 已纠正 |
| 2026-10-27 | **`phys_opt -post_route -effort high` 在 TD 6.2.168116 上崩溃**（`0xC0000005`） | 流程在 PASS-route 后中断，报告不生成 | 从 `verify_timing_fix2.tcl` 删除该步；`-post_place` 实测反而更差（0.275→0.178），两者均弃用 | ✅ 已规避 |
| 2026-10-27 | **`project/flow_sdc.tcl` 用 `[file normalize [info script]]` 推导工程目录** | 命令行调用时 `info script` 返回空串，`open_project` 收到空路径报 `PRJ-8601`，exit 2 | 新建 `verify_timing_final.tcl`，绝对路径写死且用正斜杠（TD 会吞反斜杠）；`flow_sdc.tcl` 只在 TD GUI 里 `source` 才可用 | ✅ 已规避 |
| 2026-10-27 | **`img_loader` 把 `bmp_parser` 的细分错误码全合并为 `E_BMPHDR`**：`img_loader.v:76` 只接一根 `bmp_hdr_fail` 单拍，`img_loader.v:395-397` 一律置 `err_code <= 4'd2`；`image_player.v:227` 的 `.err_code()` 还是空连接 | 现场无法区分「非 BM 签名」「非 24 bit」「宽高不符」等具体原因——`bad_size` 与 `bad_bmp` 两张异常卡在数码管上都显示 `b1` | 上板诊断按「BMP 头或尺寸不合规」统一理解，不要指望靠数码管分辨子类；若要区分得把 `bmp_parser.err_code` 单独引到顶层，属增强而非当前缺陷。已写入 `docs/board_verification_2026-10-27.md` §2.5 | 🔶 已知简化 |
| 2026-10-27 | **`tb_image_player.v` 的 `if(FULL) $finish` 放在 CASE 1 之后** | 改造前「FULL 全尺寸通过」实际只覆盖 CASE 1；本次新加的双缓冲断言被整个静默跳过，日志仍打印 `ALL CHECKS PASSED` | 把 `$finish` 块移到 CASE 2 之后，FULL 档现在跑两个 CASE。**这类结构性漏测不报错、不告警，只是少跑** | ✅ 已修复 |
| 2026-10-27 | **`pix_reader.rd_base` 由 `output` 改 `input` 后，3 个历史诊断工程失去驱动源** | `project/image_path_diag/`、`project/image_readback_diag/`、`project/image_dm_fix/` 的 `wire [20:0] rd_base;` 悬空；这些工程不走 `sync_src.ps1`，主 RTL 回归不会发现 | 三处各补一行 `assign rd_base = 21'd0;`（单帧诊断固定第 0 帧） | ✅ 已修复 |
| 2026-10-27 | **`edit` 工具丢 UTF-8 BOM**：`run_image_regression.ps1` 编辑后 BOM 消失，文件含 28 个中文字符 | Windows PowerShell 5.1 在无 BOM 时按 GBK 解析，中文注释变乱码（与 2026-10-16 `run_sim.bat` 同一类坑，方向相反） | 用 `UTF8Encoding($true)` 重写补回 BOM，`Parser::ParseFile` 复验 0 错误 | ✅ 已修复 |
| 2026-10-26 | **KEY7～KEY14 八个键从未分配**（`TASKS.md` A5 缺口） | 硬件焊着 16 键只有 8 个可用，交互维度受限；B1/B3/C1 三项任务零起点 | 新增 `key_action`（唯一译码点）+ `video_overlay`（纯组合后处理）；`player_ctrl` 加 `auto_sw_sel`、`gallery_probe` 加 `rescan` | ✅ 已修复（仿真档） |
| 2026-10-26 | **`dmz_eg4s20_bringup_top` 长期带两条 ModelSim 警告**：`u_vtg` 漏接 `vblank`（TFMPC 9 vs 8）、`u_buzz` 的 `tone_sel` 用 2 位常量接 3 位端口（PCDPC） | 警告不影响功能但污染仿真输出，新警告容易被忽略；`tone_sel` 位宽错还可能因补齐逻辑被综合器优化出意外行为 | 补 `wire vblank` 并接线；`tone_sel` 改正为 `wire [2:0]`。重跑后两条警告消失 | ✅ 已修复 |
| 2026-10-25 | **`project/hdmi_td.al` 缺 12 个模块源**（自 `e41315a` 起） | 正式顶层 elaborate 报 6 条 `HDL-7144` + 6 条 `HDL-8007`，exit 4，**根本无法构建** | 补全 13 个业务模块 + 4 个 `ip/local/sdram/` 文件，顶层 CompileOrder 改 200；elaborate exit 0、全流程 PASS | ✅ 已修复 |
| 2026-10-25 | **图库张数是编译参数 `GALLERY_COUNT`** | 换卡必须改参数重综合；参数与实际张数不符必然出故障（多张但配 1 → 只看到首图；配多但只有 1 张 → 落空文件报错锁死） | 新增 `gallery_probe` 运行时扫描；删除 `GALLERY_COUNT` 参数 | ✅ 已修复 |
| 2026-10-21 | **`sdram_ctrl_wrap` 行为模型四拍组内每拍都写同一地址** | 组内数据互相覆盖，只有最后一拍落地 | 组内按"组首锁存的 base + 拍序号"寻址，读写各自独立的组首寄存器与相位；不再用"地址变化"推断组首 | ✅ 已修复 |
| 2026-10-21 | **`framebuf_arbiter` 断流补拍用 `DM=0`（真写零），旧 TB 还断言这一错误极性** | 补拍覆盖帧内容；旧 TB 通过只说明模型自洽 | 补拍统一 `DM=4'hF` 全屏蔽；TB 改为检查"补拍后原内容不变" | ✅ 已修复 |
| 2026-10-21 | **`app_*` 注册后比 `wr_ack` 晚一拍** | `ref_vld` 上升后下一拍模型拒收，而 FIFO 已消费、拍已前进 → 刷新边界静默丢字，表现为整帧缓慢错位 | 命令、握手、拍计数、FIFO 出队改为同一边沿；组合接受路径不再打拍 | ✅ 已修复 |
| 2026-10-21 | **`pix_reader` 用 `active_y >= FRAME_LINES` 判消隐** | `video_timing_gen` 消隐时 `active_y` 归零，判据在真实顶层永不成立 | 改为锁存"已见最后有效行末、未见下一帧首像素"的 `in_vblank`，兼容两种消隐坐标 | ✅ 已修复 |
| 2026-10-21 | **旧 TB 全部 PASS 但规格是错的**（补拍极性反、单字地址+1、没有覆盖恒基址四拍组） | 旧"验证通过"不构成有效证据，掩盖 A～H 八类缺陷 | 三套 TB 重写对齐官方契约；新增 SHA256 绑定的回归 runner，源码漂移即判本轮证据失效 | ✅ 已修复 |
| 2026-10-21 | **`readable-verilog-generator` 严格交付门禁未通过**（三文件 296～580 条规则错误，主体为同行注释/端口命名/组合预算） | 若声称"规范通过"即为虚假陈述 | 如实记录 `delivery_ready=False` 与报告路径；不为例行改名与补注释而破坏最小修复范围 | 🔶 已知未通过 |
| 2026-10-06 | 自购板无板载 HDMI 接口，而赛题选题一要求 HDMI 多媒体播放 | 阶段三无法直接开展 | 底板标注图证实底板引出 HDMI 排母 P3（TMDS 直出有 BANK1 12 对 LVDS 支撑）；待底板原理图核实脚位，必要时自制/选购 HDMI 转接小板 | 🔶 降级为转接板核实 |
| 2026-10-06 | 核心板无 SD 卡电路，资源读取方案待定 | 阶段四资源读取方案待定 | 底板标注图证实底板带 **SD 卡槽且硬件支持 SDIO**；待底板原理图核实引脚，SDIO 4-bit 优先 | 🔶 降级为脚位核实 |
| 2026-10-06 | 插入 ES8388 声卡后拨码开关 SW0~SW7 全部不可用（同球复用 A9~A14,B10,B12） | 人机交互少 8 个开关 | 交互设计改为 4×4 矩阵键（16 键）为主；底板自带音频输入/输出/喇叭接口，音频链路可在 ES8388 声卡与底板音频之间二选一（待底板原理图定） | ✅ 已规避 |
| 2026-10-06 | 入门文档时钟管脚表标 R7，核心板原理图 BANK2 全局时钟丝印（FPGA_GCLK1）位置辨识存在歧义 | 约束文件时钟脚可能写错 | 首个点灯工程以 R7 起步，上板实测复核；同时向硬木课堂确认 | 🔶 跟进中 |
| 2026-10-06 | 板载 Flash 仅 M25P16（2MB），无法承载多张 BMP+音频资源 | 资源存储方案受限 | 改用底板 SD 卡作资源主存储（SDIO 优先），Flash 仅存固件 | ✅ 已规避 |
| 2026-10-06 | 尚未获得《底板原理图》——HDMI P3 脚位、SDIO 引脚、底板音频电路、VGA 电路全部待核实 | 阶段一收口阻塞 | 已向用户提出索取；官方例程确认 SD 用 SPI 模式驱动，进一步降低对底板 SDIO 细节的依赖 | ⛔ 阻塞（唯一硬件项） |
| 2026-10-06 | **seg_scan4.v 阻塞/非阻塞赋值混用** → TD 报 `mixed blocking and non-blocking assignments` ERROR；且非阻塞 NBA 会在时间步末覆盖阻塞赋值，导致位选恒为 4'b1111（**数码管实际全灭**） | 综合失败 + 数码管功能失效（ModelSim 仿真未暴露：TB 只查了视频未查数码管） | 改为"组合算 next 值 + 时序统一寄存"标准结构；新增单元测试 `sim/testbench/tb_seg_scan4.v`（已 PASS）与静态检查 `scripts/lint_verilog.py` | ✅ 已修复 |
| 2026-10-06 | **player_ctrl.v 中 auto_cnt 被两个 always 块驱动**（多驱动） | 综合错误 / 仿真 X 态 | 主控块改为产生 `auto_rst_req` 单拍请求，定时块独占计数；lint 复验 E2=0 | ✅ 已修复 |
| 2026-10-06 | **工程副本 `src/seg_decoder.v` 第 14 行末尾多出孤立字符 `S`**（文件损坏）→ TD 报 `syntax error near '4' in src/seg_decoder.v(15)`（报错位置有误导性） | 综合中断 | 用规范版本重写该模块（段码数值与官方完全一致 + 组合块改用阻塞赋值）；`lint_verilog.py` 新增 **E0 文件损坏检测**（已抓出该字符） | ✅ 已修复 |
| 2026-10-06 | **数码管段码极性记录错误**：文档/注释此前记为"高电平点亮"，实际为**低电平点亮**（0=亮，全 1=灭）；连带 `seg_scan4.v` 默认值 `8'h00` 在低有效语义下是"全亮"而非注释所称"全灭" | 潜在显示异常（消影失效/全亮）+ 文档失真 | 交叉验证官方 `seg_decoder` 段码表（`0`→`7'b100_0000` 仅 G 灭）与 `seg_scan` 空位填全 1 确认为低有效；默认值/复位值改为 `8'hFF`；更正全部文档与注释 | ✅ 已修复 |
| 2026-10-06 | 官方例程 TF 卡脚（A12~A14/B14）与自购板拨码/LED 冲突，无法照抄 pin.adc | 管脚约束需全重写 | 已确立"逻辑可移植/管脚不可移植"边界并登记 official_examples.md §五差异表 | ✅ 已明确 |
| 2026-10-06 | 官方例程数码管 6 位、独立按键 2 个，自购板为 4 位数码管 + 4×4 矩阵键 | 显示/交互模块需适配 | 移植时用矩阵扫描替换 key1/key2，seg_scan 按 4 位改写；列入 official_examples.md §五 | ✅ 已明确 |
| 2026-10-16 | **`sim/scripts/run_sim.bat` 编码错误**：文件为 UTF-8 **无 BOM** 且含中文注释，而本机控制台代码页为 **936(GBK)** → cmd 按 GBK 解析 UTF-8 中文字节时，末位汉字吞掉行尾 `CR`，各行被粘连（报错如 `'lSim（默认路径' is not recognized as an internal or external command`、`'rorlevel' is not recognized`），脚本完全无法执行 | 一键仿真入口失效（命令行调用必失败；双击同样失败） | **改为纯 ASCII 英文注释**（不用 GBK：GBK 虽能被 cmd 正确执行，但在 VS Code / GitHub / 任何 UTF-8 环境下显示为乱码，read 工具甚至无法读取）。文件头加 `[IMPORTANT] KEEP THIS FILE ASCII-ONLY` 警告并说明失效机理；顺手补上 `vsim` 退出码检查（原脚本只查编译退出码）。中文说明保留在 `docs/` 与 `sim_bringup.do` | ✅ 已修复 |
