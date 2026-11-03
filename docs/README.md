# docs/ 索引

这个目录放的是**过程记录**：诊断推导、交接报告、评审意见、单次构建的验收记录。它和仓库根的几篇文档分工不同：

| 位置 | 性质 | 读法 |
|---|---|---|
| [README.md](../README.md) / [ARCHITECTURE.md](../ARCHITECTURE.md) / [TASKS.md](../TASKS.md) / [TEST_COVERAGE.md](../TEST_COVERAGE.md) / [CONTRIBUTING.md](../CONTRIBUTING.md) | **活文档**，随时更新到当前状态 | 想知道"现在是什么样"读这里 |
| `docs/`（本目录） | **历史记录**，带日期，写完之后基本不回改 | 想知道"当时为什么这么定"读这里 |

## 一条重要约定：历史记录不改写

带日期的文档记录的是**那一刻**的观察与结论。它们的价值恰恰在于可以被追溯：某个数字是哪次构建测出来的、某个判断当时基于什么证据。

因此这些文件**不随代码更新而重写**。如果后续结论推翻了它，做法是新增一篇并在这里标注"已被取代"，而不是修改原文——否则证据链断裂，读者会误以为当时的结论和现在一样。

需要看某个主题的最终结论时，请走法：先读活文档 → 再顺着这里的"当前结论所在"链接读对应历史记录。

## 活文档（与代码同步维护）

| 文件 | 内容 |
|---|---|
| [ai_handover.md](ai_handover.md) | 给 AI 协作者的执行指令：硬性编码约束、项目场景、目标功能、开发原则、每次交付必须包含什么、禁止事项。**接入这个仓库的 AI 应当先读它** |
| [project_definition.md](project_definition.md) | 项目定义与功能需求分级（A/B/C 级需求从哪来） |
| [pending_confirmations.md](pending_confirmations.md) | 待确认事项清单：键盘行序、SD MOSI/MISO 复用等需要实测核定的问题 |
| [design_patterns.md](design_patterns.md) | FPGA 设计范式速查，每条都指向本项目里的实例代码 |
| [official_examples.md](official_examples.md) | 官方例程与 IP 资源清单，以及哪些部分被本项目复用过 |
| [sd_spi_reference.md](sd_spi_reference.md) | SD 卡 SPI 模式技术参考（阶段四的设计依据） |
| [eram_sdram_reference.md](eram_sdram_reference.md) | SiP SDRAM（ERAM 接口）技术参考：引脚、时序、配置宏 |
| [phase4_architecture.md](phase4_architecture.md) | 阶段四架构：SD 卡图片播放系统的原始分层设计 |
| [sd_spi_ctrl_state_machine.pdf](sd_spi_ctrl_state_machine.pdf) | `sd_spi_ctrl` 状态机图（图形版，便于对照 RTL 阅读） |
| [science_font_attribution.md](science_font_attribution.md) | 科普页字形来源说明（配套 [OFL-NotoSansSC.txt](OFL-NotoSansSC.txt) 许可证原文） |
| [datasheet/](datasheet/) | B1 字幕模块的数据手册（LaTeX 源 + PDF + 配图） |

## 历史记录（按时间倒序）

### 2026-11-01

| 文件 | 回答什么问题 |
|---|---|
| [board_feedback_2026-11-01_black_band.md](board_feedback_2026-11-01_black_band.md) | 最新板端反馈：黑带仍在（随机位置、约屏幕 1/7），白色碎线消失、LED2 未亮、切图约 1 秒、冷启动首图 5/5。当前源码行为模型 + APUG011 真核连续双重载全帧回归通过但未复现黑带；解释 LED2 可排除与不能排除的范围，并给出版本核对、重复板测和诊断位流计划。黑带根因仍未定位 |

### 2026-10-31

| 文件 | 回答什么问题 |
|---|---|
| [handover_2026-10-31_key1_switch_glitch.md](handover_2026-10-31_key1_switch_glitch.md) | **`d810` 已不再复现、图片正常出图**，但 KEY1 切图暴露「一条横向黑带」+「细碎线条」+「每次约 2 s」三个现象。含三个描述各自排除了什么、7 条已排除项、写组首间隔假设的上板证伪，以及读侧/写侧/帧首候选。文中 LED2 二分判据已由 2026-11-01 新反馈细化：LED2 熄灭只排除可见 FIFO 溢出/下溢，不能排除读地址或返回内容错误；当前状态见[最新板端交接](board_feedback_2026-11-01_black_band.md) |
| [diag_key1_fifo_backpressure_2026-10-31.md](diag_key1_fifo_backpressure_2026-10-31.md) | 真实 APUG011 并发探针定位到写 FIFO 扇区中途溢出；新增扇区空间预留、真实写计数和 3 拍换向保护。真实核双图完整回归、2026-11-01 综合布线通过；新位流已生成，待上板确认 |
| [handover_2026-11-01_black_edge_switch_latency_theory.md](handover_2026-11-01_black_edge_switch_latency_theory.md) | 只做理论分析：区分 letterbox 黑框、读侧欠载横向黑带和淡出变黑；解释 KEY1 按下后约 20~24ms 的按键确认、后台完整装载、垂直消隐提交与约 0.286s 转场，以及约 2s 中尚未测量的剩余差额 |
| [board_test_d810fix_2026-10-31.md](board_test_d810fix_2026-10-31.md) | 这一版位流该怎么完整测：A~F 六阶段（d810 判决 5 min → 显示链路 → 图库装载含缩放 → 模式音频 → 异常注入 → 稳定性）、判读速查、可打印验收表、失败排查顺序。**与 10-27 版的差异（`bad_size` 判据已失效）在 §6.2** |
| [d810_fix_2026-10-31.md](d810_fix_2026-10-31.md) | 交接文档两处嫌疑为什么都对不上 `d8`、真正的四条成因链（组合译码当异步复位、start 未接收、归属中途被收回、FAT 定位无看门狗）、四处改法、新增仿真用例与验证证据。**当前加固所在，上板待办** |
| [handover_2026-10-31_d810_after_watchdog.md](handover_2026-10-31_d810_after_watchdog.md) | 烧了新位流后 `d810` 仍在、图片不出图（但字幕已上板工作）。含"为什么是 `d8` 不是 `dA`"的推断链、两处嫌疑、验证顺序与交付要求 |

### 2026-10-30

| 文件 | 回答什么问题 |
|---|---|
| [noise_root_cause_2026-10-30.md](noise_root_cause_2026-10-30.md) | 切图竖白条到底怎么来的：`video_content_mux` 在 `image_ready` 落下时回落纯白彩条；修法、验证与三条上板确认步骤。**当前结论所在** |
| [c2_scaler_2026-10-30.md](c2_scaler_2026-10-30.md) | C2 自适应缩放的完整设计依据：为什么只缩不放、为什么宽必须 8 像素对齐、变异测试怎么做的。**当前结论所在** |

### 2026-10-29

| 文件 | 回答什么问题 |
|---|---|
| [display_fix_2026-10-29.md](display_fix_2026-10-29.md) | 显示异常三个根因（读组首间隔 12→13 拍、刷新宏缺括号、核内自动刷新与手动刷新交叠）与上板确认过程。**当前结论所在** |
| [b3_param_osd_2026-10-29.md](b3_param_osd_2026-10-29.md) | B3 参数面板与自动弹出 OSD 的设计与验证 |
| [fade_transition_2026-10-29.md](fade_transition_2026-10-29.md) | B2 转场为什么选淡出到黑、否决交叉溶解的带宽算法。**当前结论所在** |
| [handover_2026-10-29_noise_unresolved.md](handover_2026-10-29_noise_unresolved.md) | 当时噪点尚未定位时的交接。**已被 [noise_root_cause_2026-10-30.md](noise_root_cause_2026-10-30.md) 取代** |

### 2026-10-28

| 文件 | 回答什么问题 |
|---|---|
| [handover_2026-10-28_display_diagnosis.md](handover_2026-10-28_display_diagnosis.md) | 显示屏异常画面（深色区周期白条）的诊断交接 |

### 2026-10-27

| 文件 | 回答什么问题 |
|---|---|
| [board_verification_2026-10-27.md](board_verification_2026-10-27.md) | 上板一次性验证方案：逐项要按什么键、看什么现象、怎么判通过 |
| [error_prompt_2026-10-27.md](error_prompt_2026-10-27.md) | 错误提示面向用户化：为什么把内部错误码归并成 5 类、码表怎么排 |
| [seamless_double_buffer_2026-10-27.md](seamless_double_buffer_2026-10-27.md) | 双缓冲无缝切换的实现与 7 条提交契约 |

### 2026-10-26

| 文件 | 回答什么问题 |
|---|---|
| [hdmi_audio_2026-10-26.md](hdmi_audio_2026-10-26.md) | HDMI 音频嵌入：换核的理由、ACR 计算、为什么音频没有独立时钟域 |
| [keymap_2026-10-26.md](keymap_2026-10-26.md) | KEY7～KEY14 键位分配与实现交接 |

### 2026-10-25 及更早

| 文件 | 回答什么问题 |
|---|---|
| [s7_gallery_probe_2026-10-25.md](s7_gallery_probe_2026-10-25.md) | 图库自动扫描 `gallery_probe` 的切片设计 |
| [s7_0_td_al_fix_2026-10-25.md](s7_0_td_al_fix_2026-10-25.md) | TD 工程缺源修复与正式顶层首次构建（`PRJ-8601` 那类坑的前身） |
| [s6_integration_2026-10-20.md](s6_integration_2026-10-20.md) | S6 全链集成交接 |
| [white_frame_2026-10-20.md](white_frame_2026-10-20.md) | 真卡单图纯白画面排查的第一轮 |
| [image_dm_fix_2026-10-20.md](image_dm_fix_2026-10-20.md) | 纯白画面的真正根因：读路径沿用了写掩码，读回数据被 DQM 屏蔽 |
| [image_path_diag_2026-10-20.md](image_path_diag_2026-10-20.md) | 完整图片通路的分段观测（observe-only 探针） |
| [image_readback_diag_2026-10-20.md](image_readback_diag_2026-10-20.md) | 数码管停在 `7711` 之后的整帧连续读回诊断 |
| [sd_card_2110_2026-10-20.md](sd_card_2110_2026-10-20.md) | SD 卡上板时数码管停在 `2110` 的排查 |
| [session_handover_2026-10-19.md](session_handover_2026-10-19.md) | 阶段早期的会话交接 |

## 不维护的原始材料

| 文件 | 为什么不动 |
|---|---|
| [progress.md](progress.md) | 188 KB 的逐条开发流水账，按时间倒序记录每天的问题/影响/处理/状态。它是**日志**不是文档：改写会丢失时间线，只增不改 |
| [OFL-NotoSansSC.txt](OFL-NotoSansSC.txt) | SIL Open Font License 原文。法律文本，必须逐字保留 |

## 新增一篇记录时

1. 文件名带日期：`<主题>_YYYY-MM-DD.md`；如果是长期维护的参考类文档则不带日期。
2. 开头写清**当时的仓库版本**（HEAD 短哈希或根文档口径日期）与**这篇要回答的问题**。
3. 数字必须能指回 `reports/` 下的具体文件，不要只写结论。
4. 结论被后续推翻时，不要改它——新增一篇，并在本索引对应行标注"已被 X 取代"。
