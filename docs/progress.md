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
| LED 流水/闪烁测试 | ✅（仿真级） | rtl/top/dmz_eg4s20_bringup_top.v: led = {pattern_sel, status_led} |
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
| T3 按键→图案切换 | KEY1 按下后 pattern_sel 0→1 | pattern_sel=1, img_index=1, led=0x10 | ✅ PASS |
| T4 网格图案 | 64px 白线黑底 | (0,0) 白线、(32,32) 黑格心 | ✅ PASS |
| T5 图像导出 | 2 帧 PPM（640×480） | 彩条帧 2.93MB / 网格帧 2.11MB，PNG 目检合格 | ✅ PASS |

图像证据：`reports/sim_out_colorbar.png`、`reports/sim_out_grid.png`（由 PPM 转出，肉眼看图确认渲染正确）

## 阶段二：最小系统验证 🔶（无板卡：以仿真替代上板）

## 阶段三预演：视频链路（无 SDRAM 版）

| 任务 | 状态 | 交付物 |
|---|---|---|
| 640x480@60 时序发生器 | ✅（仿真级） | rtl/video/video_timing_gen.v（参数与官方 VIDEO_640_480 一致） |
| 测试图发生器（8 模式） | ✅（仿真级） | rtl/video/test_pattern_gen.v（彩条/网格/渐变/纯色/移动方块/棋盘） |
| 帧图像 dump 复核 | 🔶 | sim/testbench/tb_dmz_eg4s20_bringup.v 输出 PPM，可转 PNG 目检 |
| HDMI TMDS 输出（APUG092 + PHY） | ⬜ | 待底板 P3 脚位核实；TD 内集成官方加密 IP |
| SDRAM 帧缓存 | ⬜ | 官方 sdram IP + frame_read_write 移植（阶段四） |

## 阶段三：HDMI 视频输出 ⬜

前置条件：阶段二完成。

| 任务 | 状态 | 交付物 |
|---|---|---|
| 跑通官方 HDMI 例程 | ⬜ | 运行记录 |
| 纯色/彩条测试图输出 | ⬜ | rtl/video, hdmi_test |
| 静态图片输出（片上 RAM 直读） | ⬜ | 静图测试记录 |
| 记录分辨率与时序参数 | ⬜ | reports/hdmi_timing_report.md |

**阶段出口准则**：显示器稳定锁定 ≥30 分钟无异常。

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
