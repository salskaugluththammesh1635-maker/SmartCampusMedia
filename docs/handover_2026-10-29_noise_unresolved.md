# 换图白色噪点未解决：交接报告

更新时间：2026-10-29

## 结论先行

现场复验确认：按 **KEY0 / KEY1 切换图片时仍然出现白色噪点**。用户已经烧录当前交付位流，因此“没有烧录最新位流”目前不是首要假设。

此前的修复只解决了一个较窄的条件：`image_ready=1` 且 `image_pixel_valid=0` 时，`video_content_mux` 输出黑色，避免回退到白色测试彩条。该修复通过了独立选择器仿真，但没有覆盖真实 `pix_reader → SDRAM/FIFO → 顶层 HDMI` 链路，也不能拦截“像素被错误标成 valid、但数据本身不稳定/错误”的情况。当前问题应继续按帧切换、读 FIFO 对齐和 SDRAM 读写竞争排查。

## 当前板上复现

- 操作：按 KEY0 或 KEY1 切换图片。
- 现象：切图时仍出现白色噪点/亮色竖向碎条，随后图片恢复。
- 当前位流：`reports/noise_sci_fix_20261029/hdmi_noise_sci_fix.bit`
- 文件大小：629,640 B
- SHA256：`767021A3E18AF1F2DA7AF9468E407C02A8AE64288E3491848C25CDFA76115EE0`
- 当前位流包含：双缓冲图片链路、欠载像素补黑选择器、独立科普页、HDMI 低音量衰减。

## 现有显示链路

```text
KEY0/KEY1
  → player_ctrl.img_index / img_switch_req
  → image_player（后台装载另一帧，commit_pending 等待垂直消隐）
  → framebuf_arbiter / SDRAM
  → pix_reader（SDRAM 返回 FIFO、像素奇偶和 pix_valid）
  → image565 → image888
  → video_content_mux
  → video_overlay
  → video_rgb_to_axis
  → HDMI 发射核
```

相关文件：

- `rtl/control/player_ctrl.v`
- `rtl/storage/image_player.v`
- `rtl/storage/framebuf_arbiter.v`
- `rtl/storage/pix_reader.v`
- `rtl/video/video_content_mux.v`
- `rtl/video/hdmi/video_rgb_to_axis.v`
- `rtl/top/dmz_eg4s20_hdmi_top.v`

修改 `rtl/` 后需要运行 `scripts/sync_src.ps1`，并核对 `project/hdmi` 镜像和 `.al` 源文件清单。

## 已完成且不能当作现场结论的验证

- 前端回归：15/15，用例累计 631 条 PASS。
- Verilog lint：85 个文件，E0/E1/E2 均为 0。
- Tang Dynasty 构建与 bitgen：退出码 0。
- 静态时序：setup WNS +1.935 ns，hold WNS +0.011 ns，TNS 均为 0。
- `tb_video_content_mux` 只验证了合成的 `image_ready/image_pixel_valid` 输入组合；它没有驱动真实 `pix_reader`、异步 FIFO、SDRAM 返回、提交换帧和 KEY0/KEY1 切换时序。
- `manifest.json` 的 `boardValidated` 仍为 `false`；现在有了用户现场反馈，不能继续把仿真通过描述成噪点已解决。

## 当前最值得优先验证的点

### 1. `pix_reader` 的 valid 与数据稳定性

`rtl/storage/pix_reader.v` 中：

- `pix_valid` 是组合信号，依据 `display_enable`、`pix_count[0]`、`word_valid` 和 FIFO 空标志生成。
- `pix_rgb565` 直接取 FIFO 队头或 `word_hold`。
- `fifo_rd_en` 在偶像素拍出队；`pix_count` 在 `de` 下继续递增，即使 FIFO 缺字也会继续推进。

需要用时钟级测试确认：在 FIFO 空、刚恢复、帧首重启、读写竞争和偶/奇像素交界时，`pix_valid=1` 的每一拍是否确实对应稳定的 16 位数据。尤其要确认“错误数据但 valid 仍为 1”的路径。

### 2. 双缓冲提交与读端重新对齐

`image_player.v` 在 `SEAMLESS=1` 时保持 `image_ready=1`，后台装载新帧期间继续显示旧帧；`commit_pending` 在垂直消隐中切换 `front_sel`。读端随后依靠 `pix_reader` 的消隐、排空、`rd_restart`、FIFO 预填重新定位。

需要验证切换时序是否满足以下不变量：

1. `front_sel` 变化前，后台帧已完整写入且所有写命令已落盘。
2. `front_sel` 变化后，读端在输出新帧第一像素前已完成旧 FIFO 排空和新帧预填。
3. 对齐期间输出只能是黑色或明确的旧/新帧像素，不能把未定义 FIFO 队头作为有效像素。

### 3. 输出是否在帧边界切换

`video_content_mux` 和 `video_overlay` 当前是组合像素逻辑，`video_rgb_to_axis` 在像素时钟沿捕获 `rgb` 与 `de`。虽然 KEY0/KEY1 本身不改变 `mode`，但图片源在活动帧内可能发生提交/重启。建议为“图片源切换/读端重新对齐”增加明确的 frame-boundary 或 vblank 门控，并在门控窗口输出黑色，直到新源有效。

不要只在 mux 上继续增加静态颜色条件；必须在真实 top-level seam 上覆盖切图事件。

## 建议的最小回归用例

新增一个时钟级测试，至少连接 `video_timing_gen`、`image_player` 的读端或等价 `pix_reader`、`video_content_mux` 和 `video_rgb_to_axis`。测试应：

1. 让旧帧和新帧使用容易区分的固定像素值。
2. 在活动显示期间产生 KEY0/KEY1 对应的 `load_req`。
3. 模拟后台写入完成、`commit_pending`、垂直消隐、`front_sel` 切换和读 FIFO 重新预填。
4. 在切换窗口人为插入 SDRAM 返回延迟/欠载。
5. 逐像素断言：输出只能属于旧帧、新帧、科普页、应急红屏或黑色；不得出现测试彩条或未定义亮色。
6. 检查偶/奇像素顺序、每行首尾、帧首第一像素和切换后完整一帧。

建议同时把 `image_ready`、`image_pixel_valid`、`reader_status`、`rd_restart`、`rd_restart_done`、`front_sel`、`commit_pending` 和 FIFO 空/水位写入波形。

## 可行的修复方向

优先评估“原帧保持 + 帧边界原子切换”方案：

- 新帧未完成提交前，持续显示旧帧。
- 提交只发生在垂直消隐。
- 读端重启、排空和预填未完成前，输出黑色。
- 只有在新帧首地址、FIFO 和像素奇偶均确认对齐后，才恢复新帧输出。

如果波形证明 `pix_valid` 与 FIFO 数据存在错拍，应先修正 `pix_reader` 的出队/数据有效合同，再决定 mux 的颜色策略。若波形证明 SDRAM 写入仍会影响前台读帧，则继续检查 `framebuf_arbiter` 的读写仲裁和双缓冲地址是否始终不重叠。

## 交接边界

- 不要重置或批量同步工作区中与本问题无关的既有改动。
- 不要把 `reports/noise_sci_fix_20261029/` 的仿真、构建和静态时序结果当作板上通过证据。
- 当前用户已经确认：最新位流已烧录，KEY0/KEY1 切图噪点仍存在。
- 下一位执行者应先建立能复现“切图亮点”的时钟级回归，再修改 RTL；修复后必须重新生成位流并在板上复验。

