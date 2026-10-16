# 开发阶段进度表（progress）

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
| **TD 工程搭建** | ✅ | `project/hdmi_td.al`（手写工程文件）：8 Verilog + 5 VHDL（含 4 个官方加密核）+ 1 ADC，CompileOrder 按依赖排序 |
| **工程同步机制** | ✅ | `scripts/sync_src.ps1` 升级为**双工程同步**（bringup_td + hdmi_td），带 MD5 增量比对与同步后 lint 双查 |
| 静态检查 | ✅ | lint 26 文件：E0/E1/E2 全 0；ModelSim 语法检查：新增 2 模块编译通过 |
| **TD 综合布线（进行中）** | 🔶 | 待用户在 TD 中打开 `hdmi_td.al` 跑 Read Design，验证：①加密核 license ②VHDL/Verilog 混合编译 ③PLL 配置可综合 |
| 上板点亮 | ⬜ | 显示器稳定锁定 ≥30 分钟无异常 |
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
| SD 卡初始化与扇区读取 | ⬜ | rtl/storage, storage_test |
| BMP 解析（24 位非压缩起步） | ⬜ | rtl/storage, bmp_parser_test |
| SDRAM 帧缓存写入/读出 | ⬜ | rtl/memory, framebuffer_test |
| 完整链路：SD→BMP→SDRAM→HDMI | ⬜ | 单图显示记录 |

**阶段出口准则**：单张图片完整、无失真显示。

## 阶段五：基础播放系统 ⬜

前置条件：阶段四完成。

| 任务 | 状态 | 交付物 |
|---|---|---|
| 多图片切换（上一张/下一张） | ⬜ | basic_player |
| 自动轮播 + 播放/暂停 | ⬜ | basic_player |
| 基础音频输出 | ⬜ | rtl/audio, audio_test |
| 音视频联动（页面→音频关联） | ⬜ | 联动记录 |
| 错误状态提示（缺图/格式错） | ⬜ | 错误路径测试记录 |
| 状态显示（数码管/LED/画面状态栏） | ⬜ | rtl/display |

**阶段出口准则**：基础验收标准 A1~A9 全部通过（见 project_definition.md 第六节）。

## 阶段六：扩展功能 ⬜

前置条件：阶段五出口准则通过。**每加一项必须回归验证基础功能。**

| 任务 | 状态 | 交付物 |
|---|---|---|
| B1 图层叠加与字幕 | ⬜ | rtl/osd, osd_test |
| B2 淡入淡出转场 | ⬜ | rtl/video/transition, 转场测试 |
| B3 实时参数调节与 OSD | ⬜ | 亮度/速度调节 + 参数显示 |
| C1 音频可视化（音量柱起步） | ⬜ | rtl/audio/audio_visualizer |
| C2 图片自适应缩放（视余力） | ⬜ | 缩放模块 |

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

## 问题记录

| 日期 | 问题 | 影响 | 处理 | 状态 |
|---|---|---|---|---|
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
