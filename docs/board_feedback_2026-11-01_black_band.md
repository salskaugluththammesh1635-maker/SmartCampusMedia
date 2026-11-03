# 2026-11-01 板端反馈与黑带排查状态

## 本次板端反馈

用户报告：

| 项目 | 结果 |
|---|---|
| 黑带 | 黑色，出现位置随机，宽度约为屏幕的 1/7 |
| 白色碎线 | 未出现 |
| LED2 | 未亮 |
| 切图 | 约 1 秒 |
| 冷启动首图 | 5 次均正常 |
| 其余项目 | 暂无法测试 |

位流文件名、SHA-256、图片尺寸及 HDMI 采集帧未随反馈记录。因此不能确认本次板测运行的具体 RTL 构建，也不能把现象变化唯一归因于 FIFO 背压修复。

## 结论

**黑带根因仍未定位；本轮没有为黑带修改 RTL。** 旧交接中“读 FIFO 下溢可补黑一行”的假设与当前描述不完全吻合：若“约 1/7”指横带高度，640×480 画面约为 69 行；`RD_TIMEOUT=1024` 在 40 MHz 下约为 25.6 µs，量级约一行。并且 `rd_fault` 是粘滞故障，读重启要求 `!rd_fault`，不像只产生一次约 69 行、之后自行恢复的带状故障。

LED2 对应 `reader_status[1:0]`，即像素读 FIFO 溢出/下溢。下溢标志在偶像素发现 FIFO 空时粘滞置位。因此 LED2 未亮说明没有观察到这两种已接入 LED 的 FIFO 异常；**它不监测** `framebuf_arbiter.rd_fault`、返回数据地址、有效数据内容或帧首相位，不能排除读地址/数据错位。

黑带约 1/7 屏、白碎线消失、切图由约 2 秒降至约 1 秒，是本次反馈相对旧记录的变化。1 秒与完整 SD 装载加约 0.286 秒淡出/淡入相符，暂不把切图耗时列为缺陷。5/5 冷启动首图成功，记为启动复测通过；其它未测项目仍保持未验证。

## 当前源码回归

为让连续重载用例真正只统计后台加载期间，本轮修正了 `tb_display_content` 的计数边界：在 `loading` 上升沿清计数，并只在旧前台有效且后台装载期间统计有效像素和窗口屏蔽。之前计数跨首帧和所有后续帧累计，不能证明窗口在某次重载期间一直有效。

以下为当前工作树实跑结果：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\scripts\run_image_regression.ps1 -FullVga -ReportDir reports\handover_image_regression_20261101
powershell -NoProfile -ExecutionPolicy Bypass -File sim\scripts\run_display_content.ps1 -ReloadCount 2 -BmpPath assets\campus_media\sd_card\IMG001.BMP -Bmp2Path assets\campus_media\sd_card\IMG002.BMP -ReportDir reports\handover_black_band_model_20261101
powershell -NoProfile -ExecutionPolicy Bypass -File sim\scripts\run_display_content.ps1 -RealCore -DatasheetTiming -ReloadCount 2 -BmpPath assets\campus_media\sd_card\IMG001.BMP -Bmp2Path assets\campus_media\sd_card\IMG002.BMP -ReportDir reports\handover_black_band_realcore_current_20261101
```

| 回归 | 结果 | 说明 |
|---|---|---|
| `run_image_regression.ps1 -FullVga` | 5/5 用例通过，1,253,538 checks | 小图、缩放、完整 VGA、单缓冲 |
| `run_display_content.ps1 -ReloadCount 2` | 1,843,222 checks，0 错误 | 行为 SDRAM 模型，IMG001→IMG002→IMG001 |
| `run_display_content.ps1 -RealCore -DatasheetTiming -ReloadCount 2` | 1,843,224 checks，0 错误 | APUG011 加密核 + IS42s32200 引脚模型；逐帧像素比对 0 mismatch，FIFO underflow/overflow=0，`rd_fault`/`rd_timeout`=0 |

真实核回归通过表明当前可重复仿真没有重现黑带，不等于排除了真实板卡、实际 HDMI 接收画面或未建模电气/核边界上的故障。真实核回归的 SD 服务仍为模型，素材为两张 640×480 BMP。报告在 `reports/handover_black_band_realcore_current_20261101/real_core_datasheet/`。

关键源哈希：

| 文件 | SHA-256 |
|---|---|
| `rtl/storage/image_player.v` | `EF7C3C326AF26B8A749CA5977F2D343E5DBA8FBAC15EEFF31C665BE17F1F06AB` |
| `rtl/storage/pix_reader.v` | `24ED17EB17FCDF89186BB145554D2052372A11585394ACDB5F0220659B1DD844` |
| `rtl/storage/framebuf_arbiter.v` | `0D20790A05881786105B8CC629F519620D9589055343C7FDA14C2CFE76701C29` |
| `sim/testbench/tb_display_content.v` | `A6CDEDFCB5D14E9764EBC2A8DAE27A59F3990FA25A748116CD4012E15B2C7903` |

FIFO 背压候选位流 `reports/diag_key1_fifo_backpressure_20261101/smartcampus_media_fifo_backpressure_20261101.bit` 的 SHA-256 为 `9C81B5C5502848F53AD74B67E08E54E19966E8B010B4DA809B648E4D83651DF6`。这只是仓库候选文件身份；本次反馈没有记录实际烧录文件，不能认定板端版本与之相同。

## 下一步计划

1. 复测前记录板上实际 `.bit` 文件名和 SHA-256、使用的 SD 卡与素材分辨率。若不是上述候选位流，先烧录并确认该确切版本，避免版本混淆。
2. 在同一 640×480 素材和同一显示器下连续按 KEY1 至少 5 次；每次记录切图耗时、黑带是否出现、位置与高度、白线、LED2 和错误码。保留出现黑带时的完整画面照片/采集帧。
3. 若黑带在确认版本上仍出现，生成一次性诊断位流，分别记录像素 FIFO underflow/overflow、`u_arb.rd_fault`、读超时、`u_reader.state`、`pix_valid`、`rd_restart_done`、`front_sel` 及读地址基址。用 sticky 计数或可观察 LED/数码管状态避免肉眼错过瞬时事件；不先调 FIFO 阈值或写组间隔。
4. 按诊断结果分支：FIFO 状态置位则查预取/消费；`rd_fault` 或 restart 异常则查读重启、同步基址及读返回排空；这些都未置位但黑带持续时，再做板端 SDRAM 地址/返回数据观测和 HDMI 帧捕获，定位“有效但内容错误”的情况。
5. 当前工作树已有“显示窗口配置随前台帧一起提交”的改动，但本次素材为 640×480，全屏窗口且两图同尺寸；它不解释当前随机黑带，也未由本轮回归覆盖跨分辨率切换。跨分辨率窗口问题单独验证，不与本问题混为一谈。
6. 其它无法测试的功能继续标为未验证，不依据本次启动或切图结果推断通过。
