# KEY1 切图异常诊断：FIFO 扇区背压与 SDRAM 换向（2026-10-31，11-01 更新）

## 结论

KEY1 切图失败的主要原因是图片装载端的背压粒度不够：`img_loader` 只在扇区开始时检查 FIFO 是否已满，但一个 512 字节扇区开始后会连续产生像素，扇区中途 FIFO 满时 `async_fifo` 会静默忽略写入。真实核探针复现了这一点：像素已经解析完 `307200` 个，但只收到 `110435` 个写字，随后播放器永久停在 `C_COMMIT`，与现场切图黑带/白线相符。

修复在写 FIFO 的写时钟域从同步读指针计算保守占用量，新增 `wr_almost_full` 输出。图片播放器为每个扇区预留 96 个字，`img_loader` 在扇区边界等待空间恢复；96 大于一个 512 字节 24-bit BMP 扇区最多产生的约 86 个 32-bit 字，覆盖跨域和拼字流水余量。`written` 同时改为只统计真实 `wr_ack`，避免仲裁器补拍被误计为已写数据。

真实 APUG011 并发探针还显示原 `BUS_TURN_GAP=2` 会产生 `Bank is not Activated for Read`。将生产默认值提高到 3 拍后，gap=3 的真实核完整切图回归无该模型错误；这与此前只改写组首间隔的无效实验是独立变量。

## 验证证据

| 测试 | 结果 |
|---|---|
| `python scripts/lint_verilog.py rtl project/src project/hdmi` | 103 文件，E0/E1/E2 全 0 |
| `run_storage_regression.ps1 -ReportDir reports/diag_storage_after_fifo2` | async FIFO、仲裁、SDRAM wrapper、像素读取全部通过 |
| 真实核 FIFO 探针，gap=4，修复前 | `fifo_full_attempts=43165`，`produced=110435`，`written=110004`，目标 `153600`，卡在 `C_COMMIT` |
| 真实核 FIFO 探针，gap=4，修复后 | `fifo_full_attempts=0`，`produced=consumed=written=153600`，`writes_complete=1` |
| 真实核完整重载，gap=3 | `1,228,815` checks，0 errors，0 missing，0 mismatched，`frameIdentical=True` |
| 行为模型连续 `IMG001→IMG002→IMG001` | `1,843,218` checks，0 errors，0 FIFO/读超时异常 |

真实核报告：[`reports/diag_key1_realcore_fifo_gap3_final/real_core_functional/`](../reports/diag_key1_realcore_fifo_gap3_final/real_core_functional/)。

## 构建结果（2026-11-01）

已使用 Tang Dynasty 6.2.168116 对正式工程 `project/hdmi_td.al` 重新综合、布局布线并生成独立位流：

- 位流：[`smartcampus_media_fifo_backpressure_20261101.bit`](../reports/diag_key1_fifo_backpressure_20261101/smartcampus_media_fifo_backpressure_20261101.bit)（629,640 B）
- 构建入口：[`flow_fifo_backpressure_20261101.tcl`](../project/flow_fifo_backpressure_20261101.tcl)
- 最终时序：setup **+1.935 ns**、hold **+0.003 ns**、TNS 0、违例端点 **0**
- 资源：LUT 15,319/19,600（78.16%）、BRAM9K 17/64、DSP 19/29、PLL 2/4
- SHA-256：`9C81B5C5502848F53AD74B67E08E54E19966E8B010B4DA809B648E4D83651DF6`
- 报告：[`timing.txt`](../reports/diag_key1_fifo_backpressure_20261101/timing.txt)、[`area.txt`](../reports/diag_key1_fifo_backpressure_20261101/area.txt)、[`coverage.txt`](../reports/diag_key1_fifo_backpressure_20261101/coverage.txt)

位流已生成，可用于开发板下载；**尚未上板验证**，不能据此确认黑带/白线已在实板消失。`coverage.txt` 仍记录 PLL 本地反馈路径和外部 IO 延迟覆盖缺项，烧录后需按下列步骤做板端验收。

## 上板动作

烧录上述 2026-11-01 FIFO 背压修复位流后，至少连续按 KEY1 5 次，记录是否仍有黑带/白线；同时观察 LED2。若仍有现象，保留按键次数、黑带行位置、颜色和 LED2 状态，继续区分存储器件边界问题与显示读相位问题。
