# 2026-10-29 显示数据修复与验收记录

本文记录代码修复、冻结后回归和最终重建证据，以及下一次同图上板验收所需步骤。**仿真与最终 TD 重建已通过；2026-10-29 用户下载测试后反馈“问题解决了”，板上显示异常已确认消失**。

## 架构

SD 卡经 SPI 扇区服务、FAT32 定位和 BMP 解析，将 640×480 的 24 位图像转换为 RGB565，经 FIFO 与 40 MHz SDRAM 四字组仲裁写入双帧缓冲，再由像素读取器供给 25 MHz 视频时序、叠加层、TMDS 编码和 DDR 串行输出，形成 HDMI 画面。

## 现场事实与历史结论更正

- 重新查看[原照片](../../_crop/screen_now.png)后，中央白框内的黑色数字 **1 实际可见**。历史[显示诊断交接](handover_2026-10-28_display_diagnosis.md)和[AI 交接](ai_handover.md)中“黑色数字看不见”的结论需要更正，不能继续将其作为故障事实。
- 可以确认的异常是：应连续呈现深蓝色的区域出现了周期性窄白条。验证输入为 [good/IMG001.BMP](../assets/sd_verify/good/IMG001.BMP)，它本身没有这些白条；不能用另一个同名的彩条 BMP 替代此图。该输入 SHA256 为 `F7486BD0E4D7DD3FCC92C0CB2C5CAAD9063BD41E574930DA8F4103DEC9D07A8A`，见[正式原图回归记录](../reports/display_diag_20261028/evidence/content_release_result.json)。
- 用户本轮最新回答：按 **KEY4 / KEY5** 切换后画面没有变化。这是当前会话提供的线索；按键矩阵与实际键码尚未核定，不能据此绝对排除 fallback 到内置测试图案的可能性，也没有独立板端采样记录。
- 原照片不能绑定到本轮最终重建位流。仿真修复和照片异常之间的物理因果关系，仍需用相同素材下载复测确认。

## 已确认的问题与实现

### 读组首间隔从 12 拍增加到 13 拍

APUG011 真实加密核在特定 bank / row 边界上，两个完整四字读组的组首相隔 12 个 40 MHz 周期时，会返回有效信号但漏掉必要的 bank ACT。最小复现从第 9 组开始，只读两组：后组 4 个字在引脚模型回读为 `xxxxxxxx`（未知值，期望 `18c618c6`），另有 1 次 inactive-bank 检查失败；这个最小复现没有直接返回 `ffffffff`，不能把模型的 X 等同于照片中的白像素。当前干净测试框架复跑得到 12 拍 10 次检查 / 5 错、退出码 1（预期负测试）；改为 13 拍并启用数据手册时序后 10 次检查 / 0 错、退出码 0。分别见 [12 拍当前源失败记录](../reports/display_diag_20261028/evidence/gap12_release_negative_result.json)、[失败逐字日志](../reports/display_diag_20261028/evidence/gap12_release_negative_simulation.txt)、[13 拍当前源通过记录](../reports/display_diag_20261028/evidence/gap13_release_positive_result.json)及[通过日志](../reports/display_diag_20261028/evidence/gap13_release_positive_simulation.txt)。

[102 场景扫描](../reports/display_diag_20261028/evidence/read_group_gap_sweep_result.json)覆盖首组 6～11、组首间隔 4～20 拍，其中 18 个小于 13 拍的场景失败，所有不小于 13 拍的场景通过。因此“扫描通过”表示 13 拍候选门槛稳定，并非 102 个间隔组合全部无错。[仲裁器](../rtl/storage/framebuf_arbiter.v)默认 `RD_GROUP_CYCLES=13`，限制下一组首拍，保持已开始的四拍组连续；40 MHz 下 13 拍为 325 ns。

### 刷新宏的表达式分组错误

旧刷新宏缺少必要括号，宏代入真实核表达式后变为 `SELF_REFRESH_INTERVAL=0`，减 10 后为 `-10`，并不是历史交接所写的有效 1250 拍。这个问题由[宏替换负测试](../reports/display_diag_20261028/evidence/refresh_macro_red_simulation.txt)直接检出。

现在使用项目拥有的[统一 SDRAM 配置](../ip/config/sdram/global_def.v)，为周期和刷新表达式完整加括号：40 MHz 对应周期 25 ns，按 32 ms / 2048 行得到 625 拍名义请求间隔，为 64 ms 保持规范留下事务排空和握手余量。不能只看宏数值推断刷新已经发生，需同时统计物理 AREF。

### 自动刷新交叠产生相邻 25 ns 的双 AREF

即使已经提交完整四字组，真实核自动刷新与事务尾部交叠仍会发出相隔 25 ns 的两条 AREF，违反模型的 70 ns `tRC`。见[单完整写组最小复现](../reports/display_diag_20261028/evidence/duplicate_refresh_red_simulation.txt)。单纯补括号或延长读组间隔不能解决此问题。

[SDRAM 包装器](../rtl/storage/sdram_ctrl_wrap.v)关闭核的自动刷新，改用手动请求：刷新到期后等待读写四字组都完成，在组边界拉高 `ref_vld` 阻止新组；等待已接受的读返回排空，并保持 **16 拍静默**，再发送单拍手动刷新请求，等待 `core_ref` 起落后恢复命令。等待排空、静默、刷新握手和故障期间都保持命令阻塞。

刷新握手看门狗阈值为 1024 拍。当前寄存实现先计到 1024，随后一个等待边沿置位粘滞 `refresh_error`；故障不会因核握手恢复而自行清除，须复位。[image_player](../rtl/storage/image_player.v)将刷新错误与仲裁错误一起同步，进入 SDRAM 错误码 **8**。

另已修复重试时 `C_RESET` 仍看到旧同步故障的问题：重试进入本地复位阶段时，旧故障尚未完全穿过同步链，原监测逻辑会立刻再次终止重试；现在在 `C_RESET` 阶段等待复位生效，后续阶段继续检查真实故障。专门负测试为 8271 次检查 / 2 错，修复后双缓冲 8265 次、单缓冲 8263 次检查均零错，见 [red 结果](../reports/display_diag_20261028/evidence/retry_red_result.json)、[red 日志](../reports/display_diag_20261028/evidence/retry_red_simulation.txt)及[正式 green 结果](../reports/display_diag_20261028/evidence/image_release_result.json)。源码已冻结，并将原有文件恢复为 HEAD 的 CRLF 行尾；冻结后统一终验和最终 TD 重建已通过。

## 已有回归证据及覆盖边界

`release` 是冻结后正式终验入口，以下五项均已通过：原图内容、播放器与重试、刷新协议、64 ms 保持、存储全套与 VGA。便于仓库复查的小型结果和关键日志归档在 `evidence`，下表优先链接该目录；本地完整实验目录仍保留在 `release` 和先前各目录。各报告保存参与验证的源文件哈希，构建清单核对了五项正式回归与最终构建所用输入的一致性。

| 验证范围 | 已有结果 | 来源 |
| --- | --- | --- |
| 原始 IMG001 完整显示链，真实 SDRAM 核与引脚存储模型，启用数据手册时序，最终冻结后验证 | `ByteGap=15`，614407 次检查，0 错误、0 缺像素、0 像素不符，输出帧与参考完全一致，引脚模型错误为 0；25 MHz 像素域每 16 拍供 1 字节，等效 12.5 MHz SPI 位率 | [正式结果](../reports/display_diag_20261028/evidence/content_release_result.json)、[日志](../reports/display_diag_20261028/evidence/content_release_simulation.txt)；[本地完整 release](../reports/display_diag_20261028/release/content/real_core_datasheet/result.json) |
| 同一原图，早期快供数及 SPI 等效供数对照 | `ByteGap=1` 与 `ByteGap=15` 均为 614407 次检查、零错、输出帧完全一致；属于最终冻结之前的记录 | 本地 [final 快供数](../reports/display_diag_20261028/final/real_core_datasheet/result.json)、[spi_rate](../reports/display_diag_20261028/final/spi_rate/real_core_datasheet/result.json) |
| 真实核整帧写入、64 ms 保持、连续两次回读 | 写入 153600 个 32 位字；两次回读共 307200 字，0 数据错误，`refresh_error=0`；64 ms 保持期有 3843 条物理 AREF；全运行最小 / 最大 AREF 间隔为 16650 / 16950 ns | [正式结果](../reports/display_diag_20261028/evidence/retention_release_result.json)、[明细](../reports/display_diag_20261028/evidence/retention_release_simulation.txt) |
| 刷新握手、排空、看门狗与复位恢复 | 5 场景、161949 次检查、0 错误；空闲 64 ms 有 3843 条 AREF，间隔 16650 ns；4 个挂起读返回阻塞 128 拍后排空恢复；故障保持至复位 | [正式结果](../reports/display_diag_20261028/evidence/refresh_release_result.json)、[日志](../reports/display_diag_20261028/evidence/refresh_release_simulation.txt) |
| 播放器、故障重试与整帧集成 | 双缓冲 8265、FULL 1228812、单缓冲 8263 次检查，各项通过 | [正式结果](../reports/display_diag_20261028/evidence/image_release_result.json) |
| 存储行为回归与 VGA 像素读取 | FIFO 24 / 8 场景，仲裁 65739 / 15，SDRAM 模型 154771 / 12，像素读取 108 / 8，完整 VGA 64 / 5；五项均零错 | [正式结果](../reports/display_diag_20261028/evidence/storage_release_result.json) |
| 行为模型原图回归，清理临时探针后 | 614405 次检查，0 错误，输出帧完全一致；显式指定不存在 BMP 时立即报错，默认素材缺失时提示生成方法 | [content_model_clean](../reports/display_diag_20261028/content_model_clean/result.json) |
| HDMI 编码到生产串行输出 RTL 与厂商 ODDR 模型 | 原图 RGB565 扩展后，比较 1299794 个四通道字 / 51991760 bit，0 串行字错误；独立 TMDS 逆解码检查 623986 像素，含 2 个完整帧，0 像素错误、0 非法视频符号 | [serializer 原图结果](../reports/display_diag_20261028/evidence/serializer_content_result.json)、[日志](../reports/display_diag_20261028/evidence/serializer_content_simulation.txt) |

64 ms 刷新判据为至少 2048 条物理 AREF、相邻间隔至少 70 ns，单行平均预算 31250 ns；空闲回归同时检查窗口两端，保持回归还覆盖加载和回读时的刷新。保持测试使用独立生成的整帧数据图案，原始 BMP 内容正确性由前两项覆盖。

serializer 另外扫描 0～7000 ps、步长 1000 ps 的时钟相位，并在两个时钟边界之外多次复位；8 个场景共检查 34822 个四通道字、1392880 bit，零错，单 bit 注入负测试能检出错误。详见[范围说明](../reports/display_diag_20261028/serializer_content/README.md)。该验证覆盖生产 `hdmi_phy` / `lane_lvds_10_1`、真实编码核和厂商原语模型；没有覆盖 FPGA 实际 IO、电气时序、PCB、线缆、显示器，音频 / ACR 输入关闭。内容回归的 SD 扇区服务也由模型提供，不能替代实际 SD SPI 和卡介质验证。

## 最终位流与构建记录

目标位流：[reports/display_fix_20261029/hdmi_display_fix.bit](../reports/display_fix_20261029/hdmi_display_fix.bit)。构建入口为 [flow_display_fix.tcl](../project/flow_display_fix.tcl)，它生成独立的位流、面积、时序和覆盖报告。

| 最终重建项目 | 状态 |
| --- | --- |
| `C_RESET` 重试修复与源码 | 修复完成、冻结后终验通过；基于 HEAD `e1fae5b479b7f1a0bb19735837eab2fcceac2f60` 并包含工作区改动，构建期间输入快照采于 2026-10-29 08:13:20 |
| 修复后同源终验报告与构建输入 | 上述 `release` 五项全通过；44 个构建输入前后哈希未变，见[构建清单](../reports/display_fix_20261029/manifest.json)、[输入快照](../reports/display_fix_20261029/sources_before.json) |
| TD 最终重建完成时间 | 2026-10-29 08:14:50（本地时区）；TD v6.2.168116，退出码 0；[构建日志](../reports/display_fix_20261029/build.txt) |
| 位流大小、SHA256 | 629640 B；`3543915A5DD726293FBC1AF6E49D830F3E9A61E9BDA34551198CBF73A68EFEB1` |
| 最终时序 | SWNS 1.935 ns，HWNS 0.035 ns，STNS / HTNS 均为 0；[时序报告](../reports/display_fix_20261029/timing.txt) |
| 最终面积、时序覆盖 | LUT 10888 / 19600，REG 5825 / 19600，BRAM 17 / 64；时序覆盖 99.87%；[面积](../reports/display_fix_20261029/area.txt)、[覆盖](../reports/display_fix_20261029/coverage.txt) |
| 下载与同图物理验收结果 | 2026-10-29 用户反馈“问题解决了”；此为现场人工确认，未新增板端采样日志 |

下载时应核对上述最终重建的时间、大小和哈希，避免误用先前 00:50 生成的同名位流。

TD 仍报告既有的 `PHY-7002` SDRAM SIP 位置约束告警、两路 PLL 本地反馈路径告警，以及部分外部 IO 延迟约束缺失；完整明细保存在构建日志和覆盖报告中。上表的时序通过针对当前约束覆盖的路径，不能替代实际板端显示验收。

## 下载、复位和同图验收

1. 若素材未生成，在仓库根目录运行 `powershell -ExecutionPolicy Bypass -File scripts/prepare_board_verify_assets.ps1`。将 `assets/sd_verify/good/` 中的连续 IMG 文件复制到 FAT32 SDHC 卡根目录，确认 `IMG001.BMP` 是深蓝底、白框、黑色 1 的原图，并与上文哈希核对。
2. 在 TD 下载工具选择上述最终确认的 `hdmi_display_fix.bit` 并下载，记录位流哈希和下载时间。临时 SRAM 下载可用于本次对照；需要断电后保持时再按[板端验证手册](board_verification_2026-10-27.md)写 SPI Flash。
3. 插入同一张卡，执行板上硬件复位，等待首图装载完成。若采用临时 SRAM 位流，断电会丢失本次下载，需重新下载后再验收。
4. 首先核对原图结构与中央黑色 1，然后观察上下深蓝区域是否连续、周期白条是否消失；保持显示至少数秒并再次复位重试，记录是否出现 SDRAM 错误 8。按 KEY4 / KEY5 做与旧现象相同的对照，记录实际反应，不以图案切换代替像素内容验收。
5. 保留包含整屏和数码管状态的新照片，关联素材哈希、位流哈希和复位步骤；在本节填写物理结果后，才能确认现场问题已经修复。

## 复核命令

以下命令从仓库根目录运行。除最后的 serializer 诊断外，新结果写入独立目录以保留已有证据。真实核回归需要脚本内指定的本机 Questa / AMS 环境，serializer 还需要 TD 原语模型与 Python。

```powershell
# 原图内容，行为 SDRAM 模型
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_display_content.ps1 -ReportDir reports/display_recheck/model

# 原图内容，真实核 + 数据手册时序；分别覆盖快供数与 SPI 等效供数
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_display_content.ps1 -RealCore -DatasheetTiming -ReportDir reports/display_recheck/full
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_display_content.ps1 -RealCore -DatasheetTiming -ByteGap 15 -ReportDir reports/display_recheck/spi_rate

# 读组边界：13 拍正测试；改成 12 拍应能复现旧核边界问题并返回失败
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_display_content.ps1 -RealCore -CoreReplay -ReplayFirstGroup 9 -ReplayGroups 2 -ReplayShortGap 13 -ReportDir reports/display_recheck/gap13
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_display_content.ps1 -RealCore -CoreReplay -SweepReadGaps -ReportDir reports/display_recheck/gap_sweep

# 刷新协议及 64 ms 整帧保持
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_sdram_refresh_regression.ps1 -ReportDir reports/display_recheck/refresh
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_sdram_frame_retention.ps1 -ReportDir reports/display_recheck/retention

# 播放器重试 / FULL 与存储全套
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_image_regression.ps1 -FullVga -ReportDir reports/display_recheck/image
powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_storage_regression.ps1 -Suite All -FullVga -ReportDir reports/display_recheck/storage

# 原图通过生产串行 RTL：该诊断脚本会重写其 image_phase0 结果目录
powershell -NoProfile -ExecutionPolicy Bypass -File reports/display_diag_20261028/serializer_content/run.ps1 -Image -PhasePs 0
```

其中 `SweepReadGaps` 的最终通过条件为所有不小于 13 拍的候选间隔都通过；较短间隔的失败被保留为边界证据。serializer 独立诊断目录中的结果应先归档再重跑。
