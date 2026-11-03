# 任务总览与完成度

> 本文是**任务视角**的账本：每项功能做到哪一步、用什么证据支撑、还差什么才算完成。
> 想知道"为什么这样设计"看 [ARCHITECTURE.md](ARCHITECTURE.md)；想知道"现在能跑成什么样"看 [README.md](README.md)；想知道"测试怎么跑、数字怎么读"看 [TEST_COVERAGE.md](TEST_COVERAGE.md)。

**本版口径**：2026-11-04。用户报的 6 个上板问题已全部修复并出位流 `AA65465E…`（在 `reports/t10_r2_verify_build_20261103_PASS/`），**尚无该位流的板上反馈**。凡是标 🔶 或 ⬜ 的条目，都还没有跨过"上板目视确认"这一关。六项修复的根因与改动见 [六项修复交接](docs/handover_2026-11-04_six_issues_fixed.md)。

## 阅读说明：三档验证口径

同一个 ✅ 在不同行代表不同强度的证据，读表时必须先看"验证档位"这一列。

| 档位 | 含义 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| 仿真 | ModelSim 行为仿真通过，有明确 pass marker 与断言计数 | 逻辑功能符合设计契约 | 真实器件时序、板上电气行为 |
| 综合布线 | 安路 TD 完成 elaborate + 综合 + 布局 + 布线 + bitgen，时序报告无违例 | 设计可被工具接受、资源够用、静态时序结论成立 | 实际硬件是否工作 |
| 上板 | 下载 bit 到 DMZ-EG4S20 板卡后观察到预期现象 | 该 bit 在该板上确实工作 | 其他版本、长期稳定性 |

## 一、当前一句话结论

**一条完整通路已经跑通并上板出图**：SD 卡 → SPI/FAT32 → BMP 解析 →（可选缩放）→ 帧缓存写 → SiP SDRAM → 双缓冲读 → 转场 → HDMI 1.4b 输出，另带 16 键交互、字幕 OSD、参数面板、五类错误提示与音频（HDMI 内嵌 + 3.5 mm）。

**A 级基础功能全部实现，B/C 级扩展全部落地；当前短板不是功能，而是"最后一公里"的板端验收**——最新一版位流（六项修复版 `AA65465E…`）没上过板、长时运行没测过、KEY7~KEY15 没在板上按过、HDMI 音量没试听过。

**2026-11-04 本轮修完了用户报的 6 个上板问题**（音频无声+无可视化、像素偏移、缩放黑边、科普只有蓝条、字幕下黑条）。根因都在代码里，且全部可复核；但按上面的三档口径，它们目前只到「综合布线」档。

## 二、功能任务清单（A / B / C 分级）

### A 级：基础必做（9 项）

| 编号 | 任务 | 状态 | 验证档位 | 当前实现 | 缺口 |
|---|---|---|---|---|---|
| A1 | 系统启动流程 | ✅ | 上板 | PLL 锁定 → 三段式复位释放 → `sd_probe` 卡探测 → `gallery_probe` 图库扫描 → 首图自动装载；正式顶层已在板上显示卡内图片 | 启动握手曾因请求早于授权丢脉冲（板上 `d810`），已由 `pending` 锁存修复；**最新反馈冷启动 5/5 均出首图**。位流身份未随反馈记录，按该版本记录见[板端反馈](docs/board_feedback_2026-11-01_black_band.md) |
| A2 | 本地资源读取 | ✅ | 仿真 + 上板 | SD SPI 初始化与 CMD17、FAT32 分区/卷/根目录短名查找、BMP 头解析、RGB565 转换、扇区级背压 | 真卡兼容性只覆盖 MBR 分区卷与 LBA0 无分区卷两类；SDSC/exFAT/长文件名/目录递归不支持 |
| A3 | HDMI 视频显示（基线 640×480） | ✅ | 仿真 + 综合布线 + 上板 | `video_timing_gen` 生成 800×525@59.52 Hz，`video_rgb_to_axis` 接官方 HDMI 1.4b 核，`hdmi_phy` 4 路 10 bit 串化；测试图与图片按优先级选择 | 显示器连续锁定 ≥30 分钟的计时验收未做 |
| A4 | 基础音频输出 | 🔶 | 仿真 + 综合布线 | **内容音频（WAV 文件播放）已实现**：`audio_src_mux` 按模式选 BGM/NARR/ALARM，`wav_stream_player` 走 SD→FAT32→流式 PCM，`vol_apply` 10 档音量，`audio_tone_gen` 作兜底提示音。同一音源分两路——HDMI 内嵌（入口算术右移 **2** 位 = 1/4 ≈ −12.04 dB）与 `pcm_to_pwm` σ-Δ 送 3.5 mm（**不衰减**）；`audio_arc` 提供 ACR | **本轮修掉三个致命缺陷**：8.3 常量字节序写反（恒找不到 WAV）、16bit→24bit 未左移 8 位（−48.16 dB）、HDMI 衰减过深（串联 −102 dBFS）。**待上板试听**；HDMI 削波风险是审查列出的头号风险 |
| A5 | 按键交互（4×4 矩阵 16 键） | 🔶 | 仿真 + 上板（部分） | 16 键全部分配：KEY0～KEY6、KEY15 经 `player_ctrl`/顶层，KEY7～KEY14 收拢到唯一译码点 `key_action`；1 ms 行扫描 + 20 ms 消抖 | **KEY7～KEY14 只有仿真证据**（`tb_key_action` 42 条、`tb_video_overlay` 106 条）；键盘行序两处来源冲突未核定 |
| A6 | 日常播放模式 | 🔶 | 仿真 + 综合布线 + 上板（首图 + 切图） | 双缓冲无缝切换（装载写后台帧、垂直消隐换帧首、失败保留旧帧）、5 秒自动轮播、KEY9 屏占比、图库边界收缩保护；读欠载补黑 | **本轮修掉「四周露上一帧残影」**：`img_scaler` 只写 letterbox 窗口内、全设计无清屏，而 t7-B 让 `image_window_mask` 只按 Key9 档位判决 ⇒ 默认满屏档下什么都不屏蔽。现在 mask 取「Key9 档位 ∩ 本次图像自身窗口」的交集。另有 fade 分支 `display_*` 从不更新的隐藏缺陷（日常模式窗口永远停在首帧）。**待上板确认残影是否消失** |
| A7 | 科普与应急模式 | 🔶 | 仿真 + 诊断工程上板 | KEY2 三态循环（日常/科普/应急）、KEY3 应急直达。科普模式 = `.RLE` 视频流（SD 卡 `SCI.RLE`，5 fps）+ 中文字幕（`cjk16_font`）；应急 = 红屏 + 蜂鸣器 | **本轮修掉科普模式两个致命缺陷**：`rle_decoder` 的 `blk_done` 无 `req_sent` 门控（别人的块被当成自己的）、顶层 `narr_on` 用单拍脉冲 `rle_frame_ready`（占空比 2e-7）。另有 P1-a 可观测性：`err_prompt` 新增 rle 错误输入，失败不再静默。**待上板确认「画面是变的」** |
| A8 | 错误状态提示 | 🔶 | 仿真 + 上板（一类） | 数码管 DIG3/DIG2 整组切换：有错时助记字母（`C`/`F`/`0`/`b`/`d`）+ 类内子码；超时被拆成可区分的 `d8`（装载无进度）/`dA`（握手超时）/`dB`（等 SDRAM 初始化）/`dC`（等写完成）/`dd`（loader 未接收 start，10-31 新增）/`dE`（FAT 定位无进度，10-31 新增）；LED7 由 `err_prompt` 统一产生 | 上板只观察到过 `d810` 一类（**2026-10-31 晚加固版上板：`d810` 已不再复现，仅单次上板、未做 5 次统计**）；新增的 `dd`/`dE` 只有仿真证据（`tb_err_prompt` 49 条）；KEY10 重扫与异常素材的提示未逐项确认 |
| A9 | 稳定运行 | ⬜ | 无 | — | 未做长时间运行测试（目标 ≥2 小时），未做反复复位与热插拔测试。**这是唯一能暴露 0.27% 时序余量的手段**：升温后错误率上升 = 时序问题，现象完全不变 = 逻辑 bug |

### B 级：扩展功能（3 项）

| 编号 | 任务 | 状态 | 验证档位 | 说明 |
|---|---|---|---|---|
| B1 | 图层叠加与字幕 | ✅ | 仿真 + 综合布线 | 赛题要求的四项字幕全部落地：标题「SMART CAMPUS」、页面序号「IMG 07」、播放状态（PLAY/PAUSE/AUTO/WAITING/EMERGENCY/FAIL 随 `playback_state` 切换）、底部 64 字符滚动标语（约 69 秒一轮）。通路为 `rtl/osd/` 三层：`osd_strings`（字符码表，脚本生成）→ `osd_font8x16`（8×16 点阵 41 字形，脚本生成）→ `osd_caption`（坐标/滚动/序号替换）。叠加在 `video_overlay` 内，字幕带衬底压暗 1/4 保证任意画面上可读。`tb_osd_caption` 56 条断言 + 3057 点逐点比对零失配；`tb_video_overlay` 扩到 106 条。汉字仍不支持（需 16×16 点阵）。**未上板**，见 [设计记录](docs/b3_param_osd_2026-10-29.md) |
| B2 | 图片转场（淡入淡出） | ✅ | 仿真 + 综合布线 | 换帧走「淡出到黑 → 全黑时翻帧首 → 淡入」，全程约 286 ms（`FADE_FRAMES=8`，59.5 Hz）。`fade_mixer` 是纯组合逐通道缩放（237 LUT + 2 DSP + **0 寄存器**），`image_player` 内新增 2 位转场状态 + 8 位亮度系数，α **只在 `vblank_rise` 推进**。翻帧点安排在全黑那一拍，数学上不可见，因此只需一路读通路——这是主动否决交叉溶解的原因：两路并发读需 27.4 M 字/s（占 40 MHz 的 68%），且要复制整套 reader 与双读口仲裁器，会作废 S10 已验证的单读通路证据。`tb_fade_mixer` 14 条 + `tb_image_player` 三档全零错（`flips_in_grey=0`）。**未上板**，见 [设计记录](docs/fade_transition_2026-10-29.md) |
| B3 | 实时参数调节与 OSD | 🔶 | 仿真 | **v2 键位已重排**（旧文档写的「亮度 KEY7 / 反色 KEY8 / 倍率 KEY9」全部过期）：KEY4 音频开关、KEY5 滚动字幕、KEY6 亮度 10 档、KEY7 音量 10 档、KEY8 内部渲染分辨率 5 档、KEY9 屏占比 5 档、KEY10 音频可视化开关；KEY11~KEY15 为 P2 备用（`P2_EN=0` 不生效）。`osd_panel` 右上角实时显示参数，`osd_autopop` 参数变化自动弹 2.5 秒（不占键号）。参数不保存 |

### C 级：加分项（2 项）

| 编号 | 任务 | 状态 | 验证档位 | 说明 |
|---|---|---|---|---|
| C1 | 音频可视化 | 🔶 | 仿真 | `video_overlay` 内电平柱取 PCM 幅度绝对值映射到 0～127 像素；`audio_waveform` 波形层维护 64 点历史，每 8 像素一个样本。**无 FFT，不是频谱** | **本轮修掉波形塌成 1 像素的缺陷**：`hist` 只存 16bit 且预右移 8 位。现改 24bit + `Y_SHIFT=18`（24bit 满幅 ±8388607 `>>>18` = ±32 行，正好填满 `y∈[376,439]` 窗口）。⚠️ 真正让波形可见的是 `wav_stream_player` 的位深左对齐（F3），若 F3 回退则 F4 再好也是一条直线 |
| C2 | 图片自适应缩放 | ✅ | 仿真 + 综合布线 | `img_scaler` 串在 `bmp_parser` 与 `img_loader` 之间：按宽高比居中缩到 640×480 内（**只缩不放**，小图 1:1 居中），Bresenham **行列各一组** `(STEP,THRESH)` 抽稀（共用一组会让等比非整除尺寸丢行），目标尺寸由 21 位恢复余数除法器在帧头算一次；`image_player` 按缩放坐标寻址、按 `out_w*out_h` 折算字数判完成；`image_window_mask` 取「Key9 档位窗口 ∩ 本次图像自身窗口」的交集，在送显前屏蔽成黑。**目标宽必须 8 像素对齐**——`word_addr[20:2]` 截断 + 仲裁器四字突发组「组基址 + 相位」寻址要求行字数与行首字地址都落 4 字边界，仅偶数对齐会整帧错位（**禁止改成 16 对齐**：会把 `out_off_x` 量化误差上限从 7 放大到 15 像素）。验证：`tb_img_scaler` 161 条 + 变异测试 12/12、`tb_image_window_mask` **52 条**、`tb_bmp_parser` 37 条、`tb_image_player` 缩放档 1,811 条全通过。**未上板** |

## 三、工程任务清单（七阶段）

| 阶段 | 名称 | 状态 | 已完成的条目 | 阻塞出口的关键缺口 |
|---|---|---|---|---|
| 一 | 板卡与工具链确认 | ✅ | 引脚、时钟、工具链、官方 IP 来源均已确认并写入 `.adc`/`.sdc` | 遗留 2 项上板实测：键盘行序、SD MOSI/MISO 复用 |
| 二 | 最小系统验证 | 🔶 | PLL、复位、键盘、数码管、LED、蜂鸣器全部仿真通过，并随正式顶层上板工作 | 未逐项走查；拨码开关未做（与 ES8388 同球互斥） |
| 三 | HDMI 视频输出 | 🔶 | 时序生成、TMDS 串化、官方 1.4b 核集成、音频内嵌、约束与工程搭建均完成；**正式顶层已在板上出图** | 出口要求「显示器稳定锁定 ≥30 分钟」的计时验收未做 |
| 四 | 资源读取与帧缓存 | ✅ | SD/FAT32/BMP/仲裁/控制器/像素读取全部仿真通过；**完整链路 SD→BMP→SDRAM→HDMI 单图显示已上板达成**；SDRAM 域时序收敛（读 DQ +1.935 ns、写 DQ +5.630 ns） | 长时读回压力测试未做（读 DQ 是全设计最小余量，hold 也只有 3 ps） |
| 五 | 基础播放系统 | 🔶 | 双缓冲无缝切换、自动轮播+暂停、16 键全分配、用户化错误提示、运行时图库扫描均已实现并仿真 | 出口要求 A1～A9 全部通过，当前 A9 未开始、A4/A5/A6/A7/A8 仍为部分完成 |
| 六 | 扩展功能 | 🔶 | B1 字幕四要素、B2 换帧转场、B3 参数面板、C1 电平与波形、**C2 自适应缩放**全部实现并通过仿真 + 综合布线 | B1/B2/B3/C1/C2 五项均未上板验证；B1 汉字字幕未支持 |
| 七 | 工程验证与比赛材料 | ⬜ | — | 长时运行、异常注入、报告归档、演示脚本、答辩 PPT、演示视频、最终打包全部未开始 |

## 四、验收标准对照

### 基础验收（7 条）

| # | 标准 | 状态 | 说明 |
|---|---|---|---|
| 1 | 上电后自动进入播放界面 | ✅ | 正式顶层上板：扫描完成即装首图并出画面 |
| 2 | 多张预置图片连续播放 | 🔶 | 双缓冲切换与自动轮播已实现，板上只确认过首图与单图，多图连续未逐张走查 |
| 3 | 长时间运行无死机、无花屏 | ⬜ | 未测 |
| 4 | 错误卡或缺图时有提示且不死机 | 🔶 | 五类错误提示已仿真覆盖，板上观察到 `d810` 一类（2026-10-31 复测仍复现，待定位） |
| 5 | 音频与播放状态联动 | 🔶 | HDMI 内嵌音频随播放状态变音调，ACR 与 valid 连续；待试听确认 |
| 6 | 应急信息可触发、可退出 | 🔶 | 逻辑完成并仿真，红屏在诊断工程上板确认过；正式顶层未按过 KEY15 |
| 7 | 断电重启按预期恢复 | ⬜ | 未测 |

### 扩展验收（5 条）

| # | 标准 | 状态 | 说明 |
|---|---|---|---|
| 1 | 扩展功能确实运行在 FPGA 内 | 🔶 | B1/B2/B3/C1/C2 全部由 RTL 纯组合或状态机实现，无 CPU、无软核；五项均只有仿真 + 综合布线证据 |
| 2 | 现场可见、可演示 | 🔶 | 亮度/反色/九宫格/信息条/电平波形/字幕/转场/缩放均可见，但只有仿真证据，未在板上按过 |
| 3 | 基础功能不因扩展而失效 | 🔶 | `video_overlay` 位于显示通路末端、纯组合；`img_scaler`/`fade_mixer` 串在主通路但均有 `FADE_ON`/`CHECK_SIZE` 旁路；未做板上对照 |
| 4 | 有清晰的模块划分与验证记录 | ✅ | `rtl/` 分 13 个子目录（其中 `clock`/`memory` 为空），非空子目录 10 个，共 **68** 个 `.v/.vhd`（67 个 `.v` + `hdmi_tx.vhd`）；`sim/testbench/` **78** 个 TB、`sim/scripts/` **23** 个文件；逐条记录在 `docs/` 与 `reports/` |
| 5 | 能说明资源占用与时序稳定性影响 | ✅ | 当前交付（2026-11-03，25 MHz 像素域）：setup WNS **+0.109 ns** / hold WNS **+0.019 ns** / TNS 均 0 / **0 违例端点**（STA 覆盖 99.85%）；LUT **16,868/19,600 = 86.06%**、REG 8,709 = 44.43%、BRAM9K **37/64**、DSP 24/29 = 82.76%、PLL 2/4、GCLK 4/16、IO 43/188、slices 8,778 = 89.57%。**余量只有 0.27%，属零余量级**。逐版本对照见[硬证据](#五当前完成的硬证据) |

## 五、当前完成的硬证据

数字全部来自 `reports/` 下的 `result.json` / `timing.txt` / `area.txt`，不是估算。

### 5.1 行为仿真（2026-11-03 全量实跑）

| 套件 | ran/passed | 断言/检查数（第 1 轮口径） | 耗时 | 内容 |
|---|---|---|---|---|
| `unit` | 29 / 29 | 1,240 | 337 s | 29 个模块级 TB |
| `frontend` | 21 / 21 | 56,457 | 106 s | 键盘、播放控制、图像窗口、OSD、转场等 |
| `storage` | 5 / 5 | 226,360 | 6 s | 仲裁、控制器包装、像素读取、异步 FIFO、**RLE 解码（补入）** |
| `image` | 4 / 4 | 13,403 | 57 s | 播放器四档（含缩放档）、BMP 解析、缩放器、**窗口屏蔽（补入）** |
| `display` | 1 / 1 | 614,406 | 85 s | 整帧像素逐点比对（行为 SDRAM），`frameIdentical=True` |
| `audio` | 2 / 2 | 24 | 158 s | HDMI 音频路径与 PWM 输出 |
| `startup` | — | 19 | 2 s | 启动所有权交接，`discarded_player_requests=0` |
| **合计** | **7 / 7 套** | **911,909** | **752 s** | **全绿** |

> ⚠️ **这是两段证据拼接，不是一次跑完**：第 1 轮 22:10–22:22 跑七套（当时 storage 4/4、image 3/3），第 2 轮 23:21–23:23 补跑 storage 5/5、image 4/4（把两个孤儿 TB 加进套件后）。
> 11 个 `.v` + 9 个 tb 的 MD5 与第 1 轮逐一比对 **diff=0/20 IDENTICAL**，所以复用合法。证据见 [verify_build_20261103.md §10.1.1](reports/verify_build_20261103.md)。
> 上一版可核查基线是 **847,962 断言 / 857 s**（`summary.json`，2026-10-31 10:37:38）；此前多处引用的「848,063 / 1505 秒」在仓库内 grep **0 命中**，无出处。

### 5.2 关键专项证据

| 验证项 | 结果 | 证据 |
|---|---|---|
| 上板同图经真实加密 SDRAM 核 + 引脚模型 | **614,407 次检查**，0 错误、0 缺像素、0 错像素、0 引脚模型时序错误 | [content_release_result.json](reports/display_diag_20261028/evidence/content_release_result.json) |
| 刷新协议与故障恢复 | 5 场景、**161,949 次检查**，零错误 | [refresh_release_result.json](reports/display_diag_20261028/evidence/refresh_release_result.json) |
| 整帧保持与读回 | 保持 64 ms，物理 AREF 3843 次；两次读回共 307,200 字，零错误 | [retention_release_result.json](reports/display_diag_20261028/evidence/retention_release_result.json) |
| 读组间隔负向扫描 | **102 组合**，不安全对照被拒绝（<13 拍全失败） | [S13 记录](docs/display_fix_2026-10-29.md) |
| 启动所有权交接 | 9 条断言，`early_player_pulses=0`、`discarded_player_requests=0` | [startup_ownership.log](reports/startup_ownership_final/startup_ownership.log) |
| 缩放器变异测试 | **12/12** 变异全被捕获 | [c2_scaler_20261030](reports/c2_scaler_20261030/) |
| DQM 掩码仲裁回归 | 15 场景、**50,900 项**检查通过 | [arbiter/result.json](reports/dm_mask_fix/arbiter/result.json) |
| 静态检查 | `lint_verilog.py rtl` **67 个 .v**、`rtl project/src project/hdmi` **133 个 .v**，E0/E1/E2 全 0；`check_port_names` `NO_SUCH_PORT=0`；`check_key9_shared` PASS 10/10 | [README](README.md#七开发与复现) |
| 变异测试（本轮新增） | 三个变异全部 KILLED：fade 分支注释→6 错、`disp_*_sel` 恒取 `scale_*`→10 错、`in_image` 恒 1→14 错 | [review_20261103.md](reports/review_20261103.md) |
| TD 布通（本轮新增） | 四趟尝试，最终 `place hfn_opt_effort high place crit_path_opt on` → EXIT 0，238.9 s | [TD 布线失败分析](reports/td_route_fail_analysis_20261103.md) |
| 上板（正式顶层） | **成功出图**：修 SDRAM 读组节拍（12→13 拍）与刷新逻辑后，用户确认深色区周期白条解决 | [显示修复记录](docs/display_fix_2026-10-29.md) |

### 5.3 静态时序与资源（逐版本对照）

| 版本 | 位流 | SWNS | HWNS | 违例端点 | LUT | DSP |
|---|---|---|---|---|---|---|
| 40 MHz（S12 定频） | `project/hdmi_td_Runs/phy_1/hdmi_td.bit` | +1.935 | +0.011 | 0 | 10,009 | 13 |
| 显示修复 | `display_fix_20261029/hdmi_display_fix.bit` | +1.935 | +0.035 | 0 | 10,888 | — |
| B2 转场 | `b2_fade_20261029/hdmi_b2_fade.bit` | +1.935 | +0.003 | 0 | 13,502 | 15 |
| 烧录候选 | `flashable_20261030/smartcampus_media_20261030.bit` | +1.935 | +0.011 | 0 | 15,128 | 19 |
| 装载看门狗 | `watchdog_20261030/smartcampus_media_watchdog_20261030.bit` | +1.935 | +0.003 | 0 | 15,088 | 19 |
| FIFO 背压修复 | `diag_key1_fifo_backpressure_20261101/smartcampus_media_fifo_backpressure_20261101.bit` | +1.935 | +0.003 | 0 | 15,319 | 19 |
| t7-B 签收版（v2 重构，修复前） | `t7b_bit_v3_seed7_PASS/hdmi_td_v3_seed7.bit` | +0.113 | +0.011 | 0 | 16,414 | 24 |
| **六项修复（最新候选，待上板）** | `t10_r2_verify_build_20261103_PASS/hdmi_td_r2_hfn_AA65465E.bit` | **+0.109** | **+0.019** | **0** | **16,868** | **24** |

上表以最新版为准：LUT 16,868/19,600 = **86.06%**、REG 8,709/19,600 = 44.43%、DSP 24/29 = 82.76%、BRAM9K **37/64**、PLL 2/4、GCLK 4/16、IO 43/188、slices 8,778 = **89.57%**、wire length 1,801,952。

**实现代价**：从 S12 的 10,009 LUT 到 16,868 LUT，多出的 6,859 LUT 用于功能扩展（字幕、面板、缩放器、转场、看门狗、错误提示归并、FIFO 背压修复，以及 v2 重构引入的 WAV/RLE/中文字库/AHT20 等）。

> ⚠️ **注意时序口径已换**：S12 系列是 **40 MHz 存储域**的 +1.935 ns；t7-B 起统计的是**像素时钟 25 MHz**（40 ns 周期）的 WNS，两者不可直接比较。
> 且 t7-B 与六项修复版的 TD 布局布线参数不同（`hfn_opt_effort` 默认 `medium` vs `high`），**+0.113 → +0.109 不能解读为「RTL 让时序变差 4 ps」**。
> 余量仍是零余量级（0.109 ns / 40 ns = **0.27%**），详见 [TD 布线失败分析](reports/td_route_fail_analysis_20261103.md)。

## 六、尚未完成清单（按优先级）

### P0 — 阻塞"可交付"判定

1. **把 `AA65465E…`（六项修复版）烧进板子，按 [上板检查表](reports/board_check_20261103.md) 走一遍完整验收**：启动画面 → 3.5mm 音频 → HDMI 音频 → 正常尺寸图 → 缩小图 → KEY0/KEY1 连续快切 → 自动轮播 → KEY2/KEY3 科普页（判据是**画面必须是变的**）→ OSD 字幕 → 应急页 → 插入坏图确认错误码与恢复。**烧板前必须先按 `assets/v2/sdcard/BURN640/` 装配 SD 卡**（17 文件平铺到 FAT32 卡根，只拷 `RES640/` 会缺 10 个文件）。这是当前唯一真正卡住交付的事项。
2. **HDMI 音频试听**（现在是 1/4 ≈ −12.04 dB）。这是审查列出的**头号上板风险**：失效形态是**削顶/破音**而非没声音。音量偏小则把 `HDMI_AUDIO_ATTEN_SHIFT` 降到 1 或 0，削波则往上加。
3. **KEY7～KEY15 逐键板端确认**（目前只有仿真证据）。
4. **长时压测 ≥10 分钟**（**唯一能暴露 0.27% 时序余量的手段**：升温后错误率上升 = 时序问题；现象完全不变 = 逻辑 bug）。

### P1 — A 级必做缺口

1. 长时运行 ≥2 小时，含反复复位与断电重启（A9）。
2. 异常注入：坏 BMP、尺寸不符、空卡、拔卡、只读卡、零张图。
3. 多图走查（≥8 张，含缩放档与边界尺寸）。
4. 键盘行序与 SD MOSI/MISO 复用两项上板实测。
5. 音频与播放状态联动试听、SD 热插拔行为。

### P2 — 代码侧遗留（本轮刻意未修，均有记录）

1. `rtl/storage/rle_decoder.v:497` 的 `gap_tick` 撞车：`R_IDLE: if (gap_tick && !blk_busy)` 里 `gap_tick` 是**单周期脉冲**，撞上 WAV 块事务就整帧滑后 200 ms ⇒ 约 6% 帧抖动、帧率降到约 4.7 fps。**不是失效**。建议单独立项：tick 锁存 pending + 等 `!blk_busy` 起帧（`R_IDLE` 是所有帧的起点，改错风险高）。
2. `audio_tone_gen.v:142` 的 `ST_FAIL` 静音死锁：`sd_fail`/`gallery_fail`/`image_failed` 任一为 1 就钉在 `ST_FAIL`，连三角波兜底音都被掐掉。F1 修好后 WAV 能正常播，且 `ST_FAIL` 时数码管本就有错误码，故本轮未动。
3. 补 `audio_src_mux` → `wav_stream_player` 的**串联** testbench（全仓没有；顶层接线已核实正确，`tb_wav_stream_player.v` 已有完整假 FAT32 镜像，补起来成本低）。
4. `rle_decoder` 的 `R_ERR` 不自愈（现在至少**可见**了）。
5. B3 参数持久化（当前断电即丢）。

### P2b — B 级扩展上板复验

1. B1/B2/B3/C1/C2 全部上板复验。
2. **色深问题**：整条通路是 RGB565（色阶 R32/G64/B32），若用户说的"画质不佳"指色带，需换 RGB888 通路（帧缓存 600 KiB/帧 → 900 KiB/帧）。**这六项修复没有覆盖它**，需先与用户确认现象。

### P3 — C 级加分

1. FFT 频谱（当前只有电平柱与波形，不是频谱）。

### P4 — 阶段七比赛材料

长时运行报告归档、演示脚本、答辩 PPT、演示视频、最终打包。

## 七、2026-11-03 ~ 11-04 本轮新增与修复（六项上板问题）

用户报的 6 个现象 → 代码级根因 → 修复。完整推导见 [六项修复交接](docs/handover_2026-11-04_six_issues_fixed.md)。

| 现象 | 根因 | 涉及文件 |
|---|---|---|
| ①日常/科普无声 | **`audio_src_mux.v:34-36` 三个 8.3 常量字节序写反**（Verilog 拼接最左落最高位 ⇒ `[7:0]` 是 `'V'` 不是 `'B'`）⇒ FAT32 目录项比对恒不命中 ⇒ `err_code=4` 静默失败。**tb 用 parameter override 传了正确值，所以单元测试全绿** | `audio_src_mux.v` |
| ①声音过小 | `wav_stream_player.v:438-441` 16bit→24bit **只做符号扩展未左移 8 位**（−48.16 dB）；`HDMI_AUDIO_ATTEN_SHIFT` 原为 6（−36.12 dB）叠加 vol_apply 档 6 后共 −38.99 dB，串联后 **−102.45 dBFS** | `wav_stream_player.v`、顶层 |
| ①④无可视化 | `audio_waveform.v` 的 `hist` 只存 16bit 且预右移 8 位（`Y_SHIFT=18` 才是对的口径）⇒ 波形塌成 1 像素高。**注意：诊断报告原归因「256× 衰减」是错的**（`(s>>>8)>>>10` 与 `s>>>18` 数学恒等），真正来源是位深未左对齐 | `audio_waveform.v` |
| ②⑤像素偏移/黑边 | `img_scaler` 只写 letterbox 窗口内、**全设计无清屏**；t7-B 把 mask 窗口源换成 `k9_win_*` 而 `out_*` 变空连接 ⇒ 默认满屏档 `in_window` 恒真 ⇒ 四周露上一帧残影 | `image_window_mask.v`、`image_player.v`、顶层 |
| ②隐藏缺陷 | `image_player.v` 的 `display_*` **fade 分支一处都没更新**，而 `FADE_ON` 恒 1、`ext_no_fade=rle_play_en` ⇒ 日常模式窗口永远停在首帧。6 张素材全 640×480 掩盖了它 | `image_player.v` |
| ②测试说谎 | `tb_image_player.v` / `tb_display_content.v` 的 mask 接的是**旧线 `out_*`** ⇒ 验证的是出货配置里不存在的电路 | 两个 tb |
| ③科普只有蓝条（视频） | `rle_decoder.v` 的 `blk_done` 处理**没有 `req_sent` 门控**，而顶层 `sd_blk_done` 六处广播无 owner 门控 ⇒ 别人的 `blk_done` 被误判成自己的块 | `rle_decoder.v` |
| ③科普只有蓝条（字幕） | 顶层 `narr_on` 用 `rle_frame_ready` —— 那是**单拍脉冲**（占空比 2e-7，且落在消隐期） | `image_player.v`（新增 `ext_ever_framed`）、顶层 |
| ③失败静默 | `err_prompt.v` **没有任何 rle_* 输入**；`rle_err_code` 零消费者 ⇒ 图库正常时数码管显示 `playback_state`，看起来一切正常 | `err_prompt.v`、顶层 |
| ⑥字幕下黑条 | `video_overlay.v:213` 的 `px_info`（y=464..479 全宽、`24'h10_18_20`），因 `info_en` 硬接 1 而常驻；与字幕带 448..463 **严格相接 0 行间隙**，读成一条 | `video_overlay.v` |

**附带修掉的工程问题**：`tb_rle_decoder`（72 checks）与 `tb_image_window_mask`（52 checks）原本**不在任何回归套件里**，已补进 `run_storage`/`run_image`；`scripts/run_tb_baseline.ps1` 两条过期期望值与丢失的 UTF-8 BOM；`.gitignore` 补 `build_t*/`；新增 `project/t10_r2_flow.tcl`（带 `FAIL-T7B3_GATEDB_STALE` 硬断言）。

**TD 布线失败与解决**：第 1 轮两次全流程都在 route 阶段 `FAIL-route`，但 route 内部 setup 已到 **+0.124 ns / 0 违例**、只差 hold −0.012 ns；随后 `Stage 3 | Hold Fix` 插 buffer 时 `PHY-8023` 炸在高扇出复位网 `rst_n_dup_53` 上（89% slice 占用下无路可布）。**`route fix_hold on` 是 no-op**（`fix_hold` 默认就是 `on`）；「先疏松布局」被证伪（恶化到 90.23%）；最终 `place hfn_opt_effort high place crit_path_opt on` 通过 —— 它把 hold fix 从 8 条降到 4 条且 **0 条命中 `rst_n_dup_*`**。

## 八、2026-10-30 ~ 10-31 上一轮新增与修复

| 项 | 类型 | 内容 |
|---|---|---|
| `rtl/video/video_content_mux.v` | **缺陷修复** | 切图竖白条根因：`image_ready` 落下时回落到 `pattern_rgb`，而 `pattern_sel` 复位值 0 对应八色彩条第 0 条**纯白**（`test_pattern_gen.v:181`，占 `x∈[0,79]`），于是整屏出现一条 80 像素宽白条。新增 `image_ever_ready` 粘滞标志：首张图就绪后即使 `image_ready` 落下也补黑，不再回落彩条 |
| `rtl/storage/image_player.v` | **缺陷修复** | `d810` 根因：`C_WAIT` 只看 `sd_ready && !blk_busy`、不看 `load_req`，而 `gallery_first_req` 是单拍脉冲、此刻所有权还在图库扫描侧 → 请求被丢弃、从未到达 `sd_spi_ctrl` → 永久挂死 → 4 秒后 `LOAD_TIMEOUT` 报错 9。新增 `pending`/`pending_index` 锁存请求，在 `C_WAIT`/`C_SHOW`/`C_FAIL` 三处解 `sd_ready` 后消费 |
| `rtl/storage/image_player.v` | 加固 | `LOAD_TIMEOUT=100_000_000` 改为**按进度计时**：每 `blk_done` 清零，语义从"整帧 4 秒"变成"单扇区 4 秒无进度"，慢卡不再误判；`error_code` 分段 9（装载无进度）/11（等 SDRAM 初始化）/12（等写完成） |
| `rtl/storage/img_loader.v` | 加固 | 新增 `BLK_TIMEOUT=2,097,152`（≈84 ms @25 MHz），**必须大于** `sd_spi_ctrl` 的 `TOKEN_TIMEOUT=1,048,576`（≈42 ms）；超时报 `E_BLKTMO=4'd10` → 数码管 `dA` |
| `rtl/storage/img_scaler.v` / `image_window_mask.v` / `bmp_parser.v` | **功能补齐** | C2 自适应缩放全链：缩放器 + letterbox 屏蔽 + `CHECK_SIZE` 开关；顺带修掉商寄存器位宽不足（`DIV_BITS=21` 但寄存器只有 16 位 → `HDL-8007` / `img_scaler` 变黑盒） |
| `rtl/control/err_prompt.v` | 修改 | 超时类拆成 `d8`/`dA`/`dB`/`dC` 四个可区分码；五类归并与优先级不变 |
| `project/flow_c2_scaler.tcl` / `flow_flashable_20261030.tcl` / `flow_watchdog_20261030.tcl` | 新增 | C2、烧录候选、看门狗三个构建入口，均带 SWNS/HWNS 正则校验（负值 `exit 3`）与独立 `timing/area/coverage.txt` |
| `sim/testbench/tb_startup_ownership.v` / `tb_video_content_mux.v` | 新增/修改 | 启动交接 9 条、内容选择 10 条（原 8 条，其中一条把错误行为当契约已拆两组） |
| `docs/noise_root_cause_2026-10-30.md` | 新增 | 竖白条根因的完整推导与三条上板确认步骤 |
| `docs/c2_scaler_2026-10-30.md` | 新增 | 缩放器设计依据、8 像素对齐的由来、变异测试记录 |
| 位流 | 产物 | 新增 `diag_key1_fifo_backpressure_20261101/smartcampus_media_fifo_backpressure_20261101.bit`（629,640 B）；与历史位流一样不随 Git 发布 |

## 九、口径声明

1. 表里的 ✅ 只在"验证档位"一列声明的强度内成立，不是"整体完成"。
2. 行为模型通过 ≠ 真实加密 IP 通过；功能仿真通过 ≠ 时序收敛；综合布线通过 ≠ 已上板。
3. 每条历史记录绑定其对应源码与构建版本，后续改动后必须重新验证，不能引用旧结论。
4. 未跑的仿真不写"应该通过"；没上过的板不写"已验收"。
