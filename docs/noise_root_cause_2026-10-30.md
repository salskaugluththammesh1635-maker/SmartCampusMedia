# 画面白色噪点根因定位与修复（2026-10-30）

## 现场现象

按 KEY0/KEY1 切换图片时，画面上出现白色噪点 / 亮色竖向碎条，随后图片恢复正常。
`docs/handover_2026-10-29_noise_unresolved.md` 记录了该现象在 2026-10-29 的位流上仍然存在，
此前的 mux 欠载补黑、科普页接入、前端回归全绿都没有消掉它。

## 根因

`rtl/video/video_content_mux.v` 在 `image_ready == 0` 时回落到 `pattern_rgb`（测试彩条）：

```verilog
if (image_ready) rgb_out = image_pixel_valid ? image_rgb : 24'd0;
else             rgb_out = pattern_rgb;      // <-- 白色来源
```

而 `pattern_sel` 在顶层 `dmz_eg4s20_hdmi_top.v` 复位为 0，只有 KEY4/KEY5 会改它。
`pattern_sel == 0` 对应 `test_pattern_gen` 的八色彩条，其第 0 条正是纯白：

- `rtl/video/test_pattern_gen.v:181` → `3'd0: begin rgb_r = 8'hFF; rgb_g = 8'hFF; rgb_b = 8'hFF; end // 白`
- 该条占 `x ∈ [0, 79]`（8 条竖条，每条 80 像素宽）

`image_ready` 唯一的掉落路径是 `image_player.v` 的故障退帧块：SDRAM 仲裁器读超时/意外返回
（`arb_error`）、SDRAM 掉线（`!sdr_online`）或装载超时（`LOAD_TIMEOUT`）都会把
`image_ready` 清 0。切图时要重新装载 153600 字，这段时间里任何一次读故障都会让
mux 回落到彩条，**上屏就是一条 80 像素宽的竖向白条** —— 与现场描述的
"白色噪点 / 亮色竖向碎条"形态完全吻合。

关键点是：这个白色不是"噪声"，是**有确定形态的测试图案**。它在切图窗口里被短暂选中，
所以看起来像噪点闪一下。

## 修复

### 1. `rtl/video/video_content_mux.v`：区分"从未出过图"与"出过图后掉下来"

新增端口 `image_ever_ready`，回落彩条只允许在上电后还没显示过任何图片时发生：

```verilog
if (image_ready)
    rgb_out = image_pixel_valid ? image_rgb : 24'd0;
else if (image_ever_ready)
    rgb_out = 24'd0;              // 出过图后掉下来：强制黑，绝不出彩条
else
    rgb_out = pattern_rgb;        // 上电首图前：保留测试彩条
```

保留彩条回落是有意的：上电后、SD 卡扫描完成前屏幕需要有个可辨认的画面，
这也是原有行为。真正有害的是"已经显示过图片，然后又掉回彩条"。

### 2. `rtl/top/dmz_eg4s20_hdmi_top.v`：粘滞标志

```verilog
reg image_ever_ready;
always @(posedge clk_pixel or negedge rst_n) begin
    if (!rst_n) image_ever_ready <= 1'b0;
    else if (image_ready) image_ever_ready <= 1'b1;
end
```

只在 `clk_pixel` 域使用，不需要跨时钟同步。

### 3. `sim/testbench/tb_video_content_mux.v`：纠正被锁死的错误契约

原测试台把错误行为当成了正确契约：

```verilog
image_ready = 1'b0;
expect_rgb(24'hFF_FF_FF, "test pattern is used before any image is ready");
```

这条断言要求"没图时输出纯白彩条"，任何修复 mux 的方案都会让它失败。
现在拆成两组：

- `image_ever_ready=1` + `image_ready=0` → 必须出黑（新增 3 条断言，覆盖掉帧与 mode=3）
- `image_ever_ready=0` + `image_ready=0` → 仍然是彩条（保留原行为，2 条断言）

断言总数从 8 条增加到 10 条。

## 顺带修掉的阻塞缺陷

`rtl/storage/img_scaler.v` 的除法器商寄存器位宽不足，导致整个工程无法 elaborate：

```
HDL-8007 ERROR: index 20 is out of range [15:0] for 'c1_quo' in hdmi/img_scaler.v(213)
HDL-1007 : module 'img_scaler' remains a black box due to errors in its contents
```

`DIV_BITS = 21`，但 `c1_quo/c2_quo/c3_quo` 和 `div_quo1/2/3` 只声明了 16 位，
而恢复余数法从第 `DIV_BITS-1 = 20` 位开始试商，索引必然越界。
已把商寄存器全部改为 `[DIV_BITS-1:0]`，复位值同步改为 `{DIV_BITS{1'b0}}`。
有效商仍在低 16 位（DSTW/DSTH 不超过 640/480），高位只作移位占位，
下游 `> DSTH/DSTW` 的钳位保证截断安全。

同时把 `img_scaler.v` 和 `image_window_mask.v` 补进 `scripts/sync_src.ps1` 与
`project/hdmi_td.al` 的源文件清单 —— 这两个模块已被例化但此前没有登记，
构建时会直接报"模块未定义"。

## 验证

| 项目 | 结果 |
|---|---|
| 前端回归 | 20/20 用例通过，`video_content_mux` 10 条断言全 PASS |
| 静态检查 | 103 个文件，E0/E1/E2 = 0 |
| 位流构建 | `NOISE_SCI_FIX_TIMING_PASSED: setup=1.935 hold=0.003` |
| 时序 | setup WNS +1.935ns，hold WNS +0.003ns，0 违例 |
| 新位流 | `reports/noise_sci_fix_20261029/hdmi_noise_sci_fix.bit`，629640 B |
| SHA256 | `7DB596F872C1768CDCFF4362DE42509B050BB3F26F250986F078BCDD1B04AEDE` |

## 仍需板上确认

本次修复消除的是"切图窗口里闪竖向白条"这一条确定性路径，仿真与静态时序都只覆盖到
RTL 层。`manifest.json` 的 `boardValidated` 仍为 false，需要上板复验：

1. 烧录新位流，反复按 KEY0/KEY1 切换，确认不再出现竖向白条；
2. 观察 LED0（直接就是 `image_ready`）：如果切图时它仍在闪灭，说明 SDRAM 读故障
   还在发生 —— 白条不会再有，但掉帧会表现为短暂黑屏，那是另一个问题；
3. 如果 LED0 稳定常亮而仍有异常像素，则问题不在 mux，需要转向
   `framebuf_arbiter` 的读数据通路（此时 `image_ready` 未掉落，
   `image565` 的脏值会经位复制成白色）。

## 未覆盖的风险

`hold WNS +0.003ns` 几乎为零。虽然本次构建 0 违例，但保持时间余量这么小意味着
温度/电压漂移下可能出现偶发采样错误 —— 这类故障的表现是随机亮点，与本次修复的
"固定形态竖向白条"不是同一回事，但同属"画面噪点"的现场感受。若要彻底排除，
需要重新约束或降低相关路径的时钟频率。
