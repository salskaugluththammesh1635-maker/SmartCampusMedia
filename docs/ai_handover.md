# 给 AI 的执行指令（ai_handover）

> 每次开启新会话协作时，把本文件全文粘贴给 AI，或让 AI 先读本文件。

---

你是本项目的 FPGA 系统架构与 RTL 开发助手。

## 项目名称

智播校园：基于 EG4S20 FPGA 的校园多媒体信息发布与应急提示终端。

项目必须严格遵守《全国大学生嵌入式芯片与系统设计竞赛 2026 FPGA 创新设计赛道选题指南》中
"选题一：基于安路 EG4S20 的 HDMI 多媒体播放系统"的要求（指南 PDF 位于工作区根目录）。

## 2026-10-26 会话状态快照（S7：KEY7～KEY14 键位分配，本节为最新事实基线）

> **先读 `TASKS.md`** 与 **`docs/keymap_2026-10-26.md`**：前者是任务总览，后者是 16 键键位表的唯一权威来源。
>
> 若要动**错误提示 / 数码管显示 / 蜂鸣器声音**，必须先读 **`docs/error_prompt_2026-10-27.md`**：
> 它是 A8 与 P1-9 的完整交接（5 类用户动作助记符表、告警音设计依据、`sd_cd` 只提示不重探的原因、未验证清单）。
> 错误码语义的唯一真相源是 `rtl/control/err_prompt.v` 的块③，**不要在别处复制那张映射表**。

1. **本轮改动**：把 `TASKS.md` A5 遗留的"16 键仅用 8 个"补完 —— KEY7～KEY14 全部编号到功能，
   且全部收拢到**唯一一个译码模块** `rtl/control/key_action.v`（142 行）。新增画面后处理模块
   `rtl/video/video_overlay.v`（185 行，纯组合）承接亮度/反色/OSD/音频电平条。
   详细设计、取舍理由与未验证项见 `docs/keymap_2026-10-26.md`。
2. **八个新键**：KEY7 亮度五档循环、KEY8 反色、KEY9 轮播倍率 ×1~×4、KEY10 图库重扫、
   KEY11 九宫格参考线、KEY12 底部信息条、KEY13 音频电平条、KEY14 蜂鸣器静音。
   **16 键到本轮为止全部分配完毕，无空键、无一键两用。**
3. **改动的既有模块（最小侵入）**：
   - `player_ctrl` 新增输入端口 `auto_sw_sel[1:0]`，轮播间隔由编译期常量变成运行时可缩放；
     `AUTO_TICKS` 显式 32 位，新增 `auto_target` 与 `auto_sw_sel_d`（改档当拍清计时器，避免"按一下连跳两张"）。
     **默认档 0 下 `auto_target == AUTO_TICKS`，逐拍等价于改造前**。它**不认识 KEY9**。
   - `gallery_probe` 新增输入端口 `rescan`，在唯一时序块内加一条终态重扫分支（前置条件 `rescan && sd_ok && (G_DONE||G_FAIL)`）。
   - `dmz_eg4s20_hdmi_top`：加 `key_action`/`video_overlay` 例化；`video_rgb` 改为经 `video_overlay`；
     蜂鸣器接法改为 `beep_muted ? 3'd0 : (alarm_req ? 3'd3 : (mode==2 ? 3'd2 : 3'd1))`。
   - `dmz_eg4s20_bringup_top`：同步键位表、补接 `loader_index` 与 `vblank`、`tone_sel` 由 2 位改正为 3 位。
4. **本轮实测通过**（ModelSim 10.1d 行为仿真，报告在 `reports/s7_keymap/frontend/`）：
   - 前端回归 **13 个用例全部 passed=True，exit 0**：sd_protocol_default 62、sd_protocol_fast 64、
     sd_spi_ctrl 23、sd_probe 14、fat32_reader 40、gallery_probe 37、bmp_parser 37、img_loader 43、
     player_ctrl 94、err_prompt 43、buzzer_tone 23、**key_action 40**、**video_overlay 64**
   - `tb_dmz_eg4s20_bringup` 全 PASS / `errors = 0`，并**消除了两条历史 ModelSim 警告**
     （`u_vtg` 缺 `vblank` 的 TFMPC、`u_buzz` 端口 3 vs 2 的 PCDPC）
   - `python scripts/lint_verilog.py rtl project/src project/hdmi`：**77 文件，E0/E1/E2 全 0**
   - `scripts/sync_src.ps1`：通过（11/41 个副本更新）
5. **仍未通过（不得含糊）**：
   - **八个新键从未上板按下**，全部结论只到仿真档。
   - **`video_overlay` 没有重新综合布线**，LUT 占用与关键路径影响未知。
   - SiP SDRAM 接口 setup WNS `-7.232ns` 未变；本轮改动全在 `clk_pixel` 域，**没有新增时序证据**。
   - 正式顶层 `dmz_eg4s20_hdmi_top` 仍无任何上板记录。
6. **上板第一步不是试新功能，而是先确认键盘行序**（`docs/pending_confirmations.md` 的未决冲突）。
   行序若反，`key_code` 整体错位，八个新键会成对互换。确认方法见 `docs/keymap_2026-10-26.md` 第八节；
   若确认反序，**只需改 `key_matrix_4x4` 内的行序映射**，`key_action` 的 8 个键号 `localparam` 不受影响。
7. **工程固定动作（本轮再次踩到的坑）**：
   - 新增 `.v` 必须同时改 `project/hdmi_td.al`，否则 TD 判 black box（历史上 commit `e41315a` 因此缺 12 个源）；
   - 新增 TB 必须同时加进 `sim/scripts/run_frontend_regression.ps1` 的 `$sources`，否则根本不会被编译；
   - 改完 `rtl/` 必跑 `scripts/sync_src.ps1`（自带 lint）。
8. **B 级/C 级进度更新（如实）**：B1 由 ⬜ 改 🔶（有九宫格/信息条/电平条，但**没有字符字形，显示不了文字字幕**，
   `rtl/osd/` 仍为空）；B3 由 ⬜ 改 🔶（亮度/反色/倍率运行时可调，但参数不保存、无菜单）；
   C1 由 ⬜ 改 🔶（电平柱跟随 PCM，但**没有 FFT，不是频谱**）。B2 仍 ⬜。
9. **不要把行为仿真通过说成综合通过或上板通过。**

## 2026-10-25 会话状态快照（S7 前置切片：图库自动扫描，历史基线）

> **先读 `TASKS.md`**：那里是"一共要做哪些任务、完成了什么、还剩什么"的单页总览，
> 含三档验证口径（仿真 / 综合布线 / 上板）的判定标准与 P0~P4 优先级清单。

1. **本轮改动**：新增 `rtl/storage/gallery_probe.v`（248 行）与 `sim/testbench/tb_gallery_probe.v`；
   改 `rtl/top/dmz_eg4s20_hdmi_top.v`（删除编译参数 `GALLERY_COUNT`，SD 仲裁由二选一扩成三段串行，
   首图装载脉冲改由扫描器提供）；`scripts/sync_src.ps1`、`sim/scripts/run_frontend_regression.ps1`
   各加一条映射/用例；**后段修复 `project/hdmi_td.al` 缺源（见第 5 条）**；新增 `TASKS.md` 任务总览。
   详细设计见 `docs/s7_gallery_probe_2026-10-25.md`。
2. **解决的工程问题**：图库张数原为编译参数 `GALLERY_COUNT = 5'd1`，换一批素材必须改参数、重新综合、
   重新下载 bit。现场插卡时张数未知，写死会有两种必然故障：卡里 3 张但参数 1 → 永远只看到首图；
   参数 3 但只有 1 张 → 第二轮落到不存在的文件上报错锁死。现在张数是运行时可测的事实。
3. **本轮实测通过**（ModelSim 10.1d）：
   - `tb_gallery_probe` W01~W07 共 7 场景 / 23 条 PASS / 0 error / 0 越界 LBA，仿真 1205040ns
   - 前端回归 9 个 case 全绿（`sim/scripts/run_frontend_regression.ps1`，报告 `reports/s7_gallery_probe/`）：
     sd_protocol 62/64、sd_spi_ctrl 23、sd_probe 14、fat32 40、**gallery_probe 23**、bmp 37、img_loader 43、player_ctrl 85
   - 变异测试 5/5 全部被杀死（脚本 `gp_work/mutate.py`，变异体见交付文档 §5）
   - `python scripts/lint_verilog.py rtl project/src`：58 文件（含两个工程副本），E0/E1/E2 全 0
   - ModelSim 全量编译 29 个 RTL .v 无诊断；**顶层 elaborate 在补齐 5 个厂商原语桩件后 exit 0、零错误**
     （此前一直无法 elaborate，本轮为此写了一次性桩件 `gp_work/stubs/`，不入库）
4. **仍未通过（不得含糊）**：
   - SiP SDRAM 接口 setup WNS `-7.232ns` 未变，本轮全在功能层，**没有新增时序证据**。
   - 行为模型 ≠ 真核；**没有上板**。图库扫描的上板表现（真卡目录遍历、换卡行为）未实测。
     **正式顶层 `dmz_eg4s20_hdmi_top` 至今没有任何上板记录**；唯一上板证据来自独立诊断工程 `image_dm_fix`。
5. **本轮后段追加修复（重要，推翻了本节早前的判断）**：`project/hdmi_td.al` **不是"只缺 gallery_probe 一项"**，
   而是自提交 `e41315a` 起就缺 **12 个模块源**（`sdram_pll`、`sdram_ctrl_wrap`、`async_fifo`、`fat32_reader`、
   `bmp_parser`、`img_loader`、`framebuf_arbiter`、`pix_reader`、`player_ctrl`、`sd_spi_ctrl`、`sd_probe`、
   `image_player`），加上本轮新增的 `gallery_probe` 共 13 个。实测 elaborate 报 6 条 `HDL-7144`
   + 6 条 `HDL-8007` 后 **exit 4 —— 正式顶层此前根本无法构建**。
   已修复（`.al` 扩到 26 个 `.v` + 4 个 `ip/local/sdram/` 文件，顶层 CompileOrder 改 200），
   修复后 **elaborate exit 0**，完整 `flow_s6_bit.tcl` 跑通（综合/布局/布线/bitgen 全 PASS）。
   详见 `docs/progress.md` 的 S7-0 章节。
6. **接口提示**：`gallery_probe` 端口为 `clk/rst_n/sd_ok`、`blk_start/blk_addr/blk_done/blk_err/data_byte/data_valid`
   （直通 `sd_spi_ctrl`）、`done/fail/count[4:0]/first_img_req/err_code[3:0]`。
   `count=0` 是**合法结果**（扫描完成但无图），与 `fail` 是两种终局。
7. **构建现状**：完整流程可跑，但 `S6_TIMING_FAILED: setup=-7.232 ns hold=0.023 ns`，脚本 exit 3，
   生成的 bit 仅作候选。**流程跑通 ≠ 时序收敛，不得混为一谈。**
8. **不要把行为模型通过说成综合通过、真核通过或上板通过。**

## 2026-10-21 会话状态快照（S6-2 读取链路契约修复，历史基线）

1. **本轮改动**：`rtl/storage/pix_reader.v`（282 行）、`rtl/storage/framebuf_arbiter.v`（233 行）、
   `rtl/storage/sdram_ctrl_wrap.v`（339 行）按官方四拍契约重写；对应三套 TB 同步重写
   （`tb_pix_reader.v` 311 行 / `tb_framebuf_arbiter.v` 676 行 / `tb_sdram_ctrl_wrap.v` 537 行）。
   详细缺陷清单与修法见 `docs/progress.md` 的 S6-2 章节。
2. **旧结论作废**：「旧 TB 全通过」不是证据。旧 `tb_framebuf_arbiter.v` 断言补拍 `dm=0`（极性反），
   旧 `tb_sdram_ctrl_wrap.v` 用单字地址 +1、没覆盖恒基址四拍组。**读旧报告前先看它的断言写的是什么。**
3. **本轮实测通过**（ModelSim 行为仿真）：
   - `tb_framebuf_arbiter` 15 场景 / 50900 检查 / 0 error
   - `tb_sdram_ctrl_wrap` 12 场景 / 154771 检查 / 0 error
   - `tb_pix_reader`（64×8）8 场景 / 108 检查 / 0 error
   - `tb_pix_reader`（640×480）5 场景 / 64 检查 / 0 error
   - `tb_image_player` 6202 检查；全尺寸 640×480 = 614404 检查 / 0 error
   - 前端 8 个 TB（SD 协议 62/64、sd_spi_ctrl 23、sd_probe 14、fat32 40、bmp 37、img_loader 43、player_ctrl 85 条 PASS）
4. **回归入口**：`sim/scripts/run_storage_regression.ps1 -Suite All|Fifo|Arbiter|Model|Pixels [-FullVga] -ReportDir <dir>`。
   每次建独立 work 库，通过条件是 `exit 0` + 精确 `ALL CHECKS PASSED: <top>` + `SUMMARY errors=0 cases>0`；
   运行前后比对 SHA256，**源码在运行中漂移则该轮证据作废并 exit 1**。
5. **仍未通过（不得含糊）**：
   - `readable-verilog-generator` 严格交付门禁 `delivery_ready=False`（三文件 296～580 条规则错误，
     主体是同行语义注释、端口命名/关键字、组合操作预算等机械性规则），报告在 `reports/s6_gate/`；
     仓库内没有任何 `*_spec.md`。
   - SiP SDRAM 接口时序 setup WNS `-7.232ns` 未变，本轮改动全在功能层，**没有新增时序证据**。
   - 行为模型 ≠ 真核：10 拍读延迟、8 拍刷新窗口、DM 方向已对齐，但器件建立/保持窗口与
     "跨刷新保持组内相位"仍是**模型假设**，官方只承诺"操作前避让"。
   - **没有上板**。
6. **不要把行为模型通过说成综合通过、真核通过或上板通过。**
7. **新接口**：`pix_reader` 增加 `rd_idle`（输入）、`rd_restart_done`（输入）、`rd_restart`（输出）、
   `rd_base`（输出）；`framebuf_arbiter` 增加 `rd_idle`、`rd_restart_done`、`wr_word_addr`、
   `WR_ADDR_FROM_FIFO`。改动上层前先读这两个文件的端口注释。

## 2026-10-06 会话状态快照（阶段一已收口，历史基线）

1. **实际平台**：用户自购"大拇指 DMZ-EG4S20"= **核心板（EG4S20BG256）+ MO 综合底板**。底板资料包在 `EG4S20/微处理器原理综合设计底板/`：底板原理图 `EG4S20_综合底板.pdf`、权威引脚说明 `板卡和引脚说明.pdf`、**11 个厂商实测例程**（`M0_Borad/M0_Borad/`，含全部 .adc 约束）。
2. **★管脚全部核实（三源交叉验证：核心板原理图 × 底板引脚说明 × 底板例程 adc）**，完整表见 `constraints/dmz_eg4s20_bringup.adc`：
   - **HDMI（板载 HDMI-019S 座，无需转接板）**：CLK_P=P1, D0_P=N1, D1_P=P4, D2_P=J3（LVDS33）；无 DDC → 不做 EDID，DVI 兼容模式固定分辨率输出
   - **VGA/RGB565（复用）**：R[4:0]+G[5:0]+B[4:0] 16 位，HS=M14, VS=P14；LCD 附加 DE=L16, CLK=L13, BL=M16
   - **SD 卡（板载 SPI 模式）**：SCK=F15, CS=F13, MOSI=F14, MISO=D14
   - **音频输出 = PWM（F3）+ 板载低通滤波 + 功放**（→3.5mm/喇叭）；**音频输入 = 麦克风+ADC**（CS=J6, SCK=H3, MISO=K5, RSTN=G6）
   - SDRAM=片内 2M×32bit（底板例程印证无管脚）；SPI Flash 配置脚 T3/R11/T10/P10
   - 键盘/数码管/LED/蜂鸣器与核心板记录一致（三方吻合）
3. **⚠️ 仅余 2 处来源冲突，待上板实测**（约束文件 §12 已标注）：① 键盘行序（走近FPGA vs 底板例程相反）；② SD MOSI/MISO（引脚说明 vs 例程相反，已采用引脚说明=SD SPI 标准）。
4. **合规性**：赛题 1.1 "推荐"HX4S20C 非强制；EG4S20BG256 为核心即合规。待办：向主办方报备。
5. **官方参考实现**：`project/reference/lab_ex4_tf + lab_ex5_i2s`（TF 卡 BMP→SDRAM 双缓冲→HDMI 1.4b + 48kHz HDMI 音频，SPI 读卡）；IP 文档在 `ip/reference/`（APUG092/APUG010/011/SoftFIFO）；**底板 HDMI 例程**（10_VGA_hdmi_tx_display_MB，与 DEMO31 同源，含 .al 工程实测通过）、**底板 SDRAM 例程**（7_SDRAM_as_BRAM/8_SDRAM_FIFO）。
6. **音频架构定案**：基础音频输出走 **HDMI 音频**（lab_ex5_i2s 路径，现场一根 HDMI 线出画面+声音）；底板 **PWM 音频（F3）作备用/应急提示音**；ES8388 为可选件（插上则拨码全废）。
7. **工具链**：TD 6.2.1 已安装；**首个工程 project/bringup_td.al 已综合+布局通过（IO=31 锁定）**；仿真 ModelSim 10.1d（sim/scripts/run_sim.bat）；**编码规范**：时序块仅 <=、组合块仅 =、禁多驱动，**提交 TD 前必跑 `python scripts/lint_verilog.py rtl project/src`**（E0 损坏/E1 混用/E2 多驱动）。
8. **RTL 现状**：最小系统（dmz_eg4s20_min_top，键盘→计数→数码管/LED/蜂鸣器）已通过 ModelSim 仿真 + TD 综合；完整 bringup 顶层（视频通路）仿真验证通过（PPM 图像目检）。数码管段码为**低电平点亮**（此前文档误记已更正）。
9. 本地文档基线：`docs/pending_confirmations.md`（第 1~7 节全确认）、`docs/official_examples.md`、`docs/project_definition.md`（§〇 赛规核实）、`docs/progress.md`（阶段一✅）。

## 硬性约束

0. **【编码规范·强制】Verilog 赋值规则**（2026-10-06 因 TD 报错新增，详见 progress.md 问题记录）：
   - 时序 `always @(posedge clk ...)` 块内 **只用非阻塞 `<=`**；
   - 组合 `always @(*)` 块内 **只用阻塞 `=`**；
   - **严禁同一变量在同一 always 块内混用两种赋值**——安路 TD 直接报
     `mixed blocking and non-blocking assignments ... is not supported` ERROR
     （ModelSim 只警告，易漏过）；混用时 NBA 会在时间步末覆盖阻塞赋值，还会造成
     隐藏功能缺陷（已发生：seg_scan4 位选恒全 1 → 数码管全灭）；
   - **严禁同一变量被多个 always 块驱动**（多驱动）；
   - 提交 TD 前必跑：`python scripts/lint_verilog.py rtl project/src`（E0/E1/E2 均须为 0）。

0b. **【接口规范·强制】**（2026-10-06 全 RTL 复审新增，详见 progress.md 代码审查记录）：
   - **同一按键不得被两个模块同时用作功能触发** —— 新增按键功能前先查
     `rtl/top/dmz_eg4s20_bringup_top.v` 顶部的键位分配表（已发生：KEY0/KEY1 曾被
     播放控制与图案切换同时占用，一次按键触发两种行为；TB 已加 T3b 防回归）；
   - **一个模块一个职责，不留死端口** —— 不为"将来可能用到"预留输出
     （已发生：`player_ctrl.seg_status` 16 位无人使用，且注释/实现/位定义三方不一致）；
   - **端口注释必须与实现一致**（位序、极性、位宽三项），复审会逐条核对；
   - **同步命令**：改完 `rtl/` 后执行 `scripts/sync_src.ps1`（增量同步到
     `project/src/` 并自动 lint 双查），**不要手工复制**。

0c. **【编码规范·强制】RTL 层不使用 `function` / `task`**（2026-10-16 依用户要求全量清除）：
   - **为什么**：Verilog 的 `function` 综合后本就是纯组合逻辑（由综合器内联展开），
     改写成显式 `always @(*)` 块**不改变任何综合结果**；但显式写法让逻辑直接体现在
     波形里（调试时能看清中间过程），也免去"读代码要跳到函数定义处对照"的认知负担；
   - **已清除的两处**（原实现 → 现写法）：
     - `rtl/input/key_matrix_4x4.v`：`prio_code()` 函数 → **块⑥ 组合 `always @(*)`**
       （中间值 `key_code_nxt`，for 循环展开为并行比较逻辑，块⑦ 再寄存输出）
     - `rtl/control/player_ctrl.v`：`next_idx()` / `prev_idx()` 函数 → **三个调用点
       就地内联三元表达式**（KEY1 下一张 / KEY0 上一张 / 轮播到点，回绕规则不变）
   - **唯一例外**：`sim/testbench/*.v` 中的 `task`（`press_key` / `check_pixel` /
     `check_blanking` / `dump_frame` / `chk`）**保留** —— 它们只在仿真中使用、不参与
     综合，封装的是重复的激励与检查序列，展开只会让 testbench 膨胀且更难维护；
   - **新代码要求**：RTL 中若需要"可复用的一小段运算"，一律就地写表达式，或另起一个
     组合 `always @(*)` 块，**不再使用 `function`**。

0d. **【工具脚本编码·强制】**（2026-10-16 因 `run_sim.bat` 无法执行新增）：
   - **判据：谁解析这个文件，就按谁的默认编码保存**；
   - **`.bat` / `.cmd` → 一律纯 ASCII（英文注释）**：cmd.exe 按控制台代码页（本机 936/GBK）
     解析批处理，UTF-8 **无 BOM** 的中文会让"每行末位汉字吞掉行尾 CR"，各行粘连、脚本整体
     失效（实测：`'lSim（默认路径' is not recognized as an internal or external command`）。
     GBK 虽能被 cmd 正确执行，但在 VS Code / GitHub / read 工具等 UTF-8 环境下显示乱码，
     故**不采用**；中文说明写进 `docs/` 或 `.do` 文件；
   - **`.ps1` → UTF-8 *带* BOM**：Windows PowerShell 5.1 按 ANSI 读无 BOM 文件，中文会变
     乱码并抛 `The string is missing the terminator`（已发生，见 `scripts/sync_src.ps1`）；
   - **`.v` / `.vhd` / `.md` / `.py` / `.adc` → UTF-8 无 BOM**（现状即如此，保持不变）；
   - 注意：用 Windows PowerShell 5.1 的 `Get-Content` 读 UTF-8 无 BOM 的中文文件会**显示**
     乱码（如 `鈥?瀹樻柟`），那是**显示假象而非文件损坏** —— 用 `read` 工具或
     `[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)` 复核，不要据此"修文件"。

1. 系统必须基于安路 EG4S 系列 FPGA（EG4S20BG256）。
2. 所有算法、控制逻辑和数据处理流程必须在 FPGA 中自主实现。
3. 不得使用额外处理器承担辅助控制、算法预处理或核心数据处理。
4. 项目必须是具有明确应用场景的音视频融合多媒体展示系统。
5. 必须包含视频显示、基础音频输出、交互控制或音视频联动。
6. 必须重视显示稳定性、鲁棒性和系统工程规范。
7. 所有扩展功能必须在基础功能稳定后实现。
8. 不得根据照片猜测管脚、时钟、电平标准或接口时序。
9. 涉及板卡连接和时序的内容必须以官方原理图、约束文件、工程和芯片资料为依据。
10. 不得把未验证的内容写成已实现或已确认。

## 项目应用场景

校园大厅、教学楼、实验室中的多媒体信息发布与应急提示。

三种模式：日常信息播放、校园科普展示、应急信息发布。

## 目标功能

基础：本地多媒体资源读取、图片解析和显示、SDRAM 帧缓存、HDMI 视频输出、
基础音频输出、按键交互、图片手动切换、自动轮播、播放和暂停、应急模式切换、
错误状态提示、音视频联动。

优先扩展：图层叠加和字幕、图片淡入淡出转场、实时参数调节和 OSD。

次级扩展：音频可视化、图片自适应缩放。

## 开发原则

1. 先验证官方 HDMI、存储器、音频和按键例程；
2. 先完成最小系统，再逐步增加功能；
3. 每次只增加一个主要模块；
4. 每个模块都需要仿真或上板验证；
5. 任何接口参数必须标注来源；
6. 发现板卡资料缺失时，先提出问题，不要自行假设；
7. 优先复用官方例程中的可靠模块；
8. 代码必须模块化、可综合、可仿真；
9. 解释 FPGA 并行处理、实时控制、低延迟显示和音画同步如何体现；
10. 输出内容必须区分"赛题要求""已验证事实""设计建议"和"待确认事项"。

## 每次交付必须包含

1. 本次完成内容；
2. 修改的文件；
3. 设计原理；
4. 接口和时序假设；
5. 验证方法；
6. 验证结果；
7. 未解决问题；
8. 下一步任务。

## 禁止事项

- 不得声称未实际验证的功能已经完成；
- 不得虚构管脚号、时钟频率、分辨率或音频参数；
- 不得在阶段一（板卡确认）完成前编写依赖具体管脚的最终工程；
- 不得把演示系统描述成具备真实消防/公共安全认证能力的设备。
