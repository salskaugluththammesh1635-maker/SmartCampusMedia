# B2 换帧转场（淡出到黑再淡入）— 设计与验证记录

> 日期：2026-10-29
> 任务：`TASKS.md` B2「图片转场（首选淡入淡出）」（`docs/project_definition.md`）
> 结论：转场已实现并通过三档仿真（8,270 / 8,263 / 1,228,817 条检查）、20 项前端回归、整帧逐像素回归、lint 与 TD 综合布线（setup +1.935 ns、hold +0.003 ns、bitgen 成功）。**验证档位：仿真 + 综合布线；未上板。**

---

## 一、先说清楚做了什么、没做什么

双缓冲本身（装载写后台帧、垂直消隐换帧首、失败保留旧帧）在 2026-10-27 的 S10 就已落地并有仿真证据，见[无缝双缓冲记录](seamless_double_buffer_2026-10-27.md)。它解决的是**撕裂**：换帧发生在消隐期，屏幕上不会出现上半张旧图、下半张新图。

但它不解决**突兀**：换帧那一瞬间画面直接跳变。B2 要补的就是这一段——给换帧加一个过渡。

**做的是**：淡出到黑 → 全黑时翻帧首 → 淡入。整段过渡由帧缓存的读出亮度系数控制，约 286 ms（`FADE_FRAMES=8`，59.5 Hz）。

**没做的是**：交叉溶解（两帧同时显示、按比例混合）。这是主动否决的，理由见第二节——不是省事，是这条路上有一堵结构性的墙。

---

## 二、为什么不是交叉溶解

"淡入淡出"最直觉的实现是交叉溶解：旧帧逐渐变透明、新帧逐渐显现，两帧像素按 `α` 加权求和。它效果最好，但在本工程里做不了。

### 2.1 带宽算术

| 项目 | 数值 |
|---|---|
| 输出像素率 | 640 × 480 × 59.52 Hz ≈ **18.3 M 像素/s** |
| 折算读字数（两像素一字） | **9.14 M 字/s** |
| SDRAM 时钟 | 40 MHz，单字宽 |
| 交叉溶解读需求 | 两路并发 → **18.3 M 字/s** |
| 叠加装载写需求 | 再 +9.14 M 字/s → 合计 **27.4 M 字/s** |

27.4 M 字/s 已经占掉 40 MHz 的 68%，而这只是平均值。`framebuf_arbiter` 还有 `RD_GROUP_CYCLES = 13` 的读组首间隔保护（相邻读组首至少隔 13 个 40 MHz 周期，对应真实核 325 ns 的节拍约束，见 `rtl/storage/framebuf_arbiter.v:18`），实际可用带宽比名义值更低。转场期正好是"边装新图边显示"的叠加窗口，读带宽翻倍必然把装载挤成饥饿。

### 2.2 结构代价比带宽更硬

`pix_reader` 只有一套 `rd_req / rd_ack / rd_data / rd_valid` 通路和一个读 FIFO，`framebuf_arbiter` 只有一个 `rd_addr` 寄存器和一组 `rd_frame_base / rd_frame_last` 回绕边界。要同时读两帧，得复制整套读通路、把仲裁器扩成双读口、重做信用记账与 `rd_restart` 语义。

那是**推翻一个已经验证过的结构**去换一个过渡效果，风险与收益不成比例。S10 的仿真证据（`overlap_cycles = 2,085,846`、`starve_cycles = 0`、`front_flips = 2`）建立在单读通路上，一旦改双读口，这些证据全部作废。

### 2.3 淡出到黑绕开了这两堵墙

关键观察：**如果混合的另一端恒为黑色，就永远只需要读一帧。**

- 淡出阶段：读旧帧，输出 = 旧帧 × α，α 从 1 降到 0；
- 全黑那一帧：读哪一帧都无所谓，因为乘数是 0；
- 淡入阶段：读新帧，输出 = 新帧 × α，α 从 0 升到 1。

翻帧点被安排在全黑那一拍，而全黑时两帧像素的加权和恒等于黑——**"翻帧"这件事在数学上不可见**。这正好复用已有的 `vblank_rise` 换帧机制，读带宽零增量、BRAM 零增量、仲裁器零改动。

代价是观感：淡出到黑再淡入，比交叉溶解"重"一点。对校园导览这类信息展示场景，这个取舍是划算的。

---

## 三、模块划分

| 模块 | 职责 | 类型 | 规模 |
|---|---|---|---|
| [`fade_mixer`](../../rtl/storage/fade_mixer.v) | RGB565 按亮度系数逐通道缩放 | 纯组合，零状态 | 237 LUT / 2 DSP / 0 寄存器 |
| [`image_player`](../../rtl/storage/image_player.v) 转场状态机 | 在垂直消隐推进 α、在全黑拍翻帧首 | 时序（2 位状态 + 8 位系数） | 并入既有状态机，无新增模块 |

**为什么混合器独立成文件**：它是纯组合、无状态、输入输出全是向量，可以脱离整条 SD → SDRAM 链路单独验证（`tb_fade_mixer` 14 条断言，毫秒级跑完）。而转场状态机必须和 `commit_pending` / `front_sel` / `vblank_rise` 待在一起——这些信号本来就属于 `image_player`，搬出去就要跨模块传一堆控制线。

**为什么 `image_player` 端口零改动**：`rgb565` 本来就是"当前该显示的像素"，现在它只是多了个亮度系数。顶层 `dmz_eg4s20_hdmi_top` 与两个 TB 例化点（`tb_image_player.v:65`、`tb_display_content.v:36`）都不需要补端口。

---

## 四、关键设计决策

### 4.1 `gain = level + 1`：让两端都精确

```verilog
wire [8:0] gain = {1'b0, level} + 9'd1;
wire [13:0] r_mul = r_in * gain;
assign rgb_out = {r_mul[12:8], g_mul[13:8], b_mul[12:8]};
```

- `level = 255` → `gain = 256`，`r_in × 256 >> 8 = r_in`，**逐位恒等**，不会在满档时留下 1 LSB 的偏暗；
- `level = 0` → `gain = 1`，各通道最多 6 位，右移 8 位必为 0，**精确全黑**，不会残留暗色。

如果直接用 `level` 当乘数，满档时 `255/256 ≈ 0.996`，红通道 31 → 30，整幅画面永久偏暗一档。加 1 是零成本的修正（一个 9 位加法器）。

### 4.2 必须逐通道缩放，绝不能把 RGB565 当 16 位整数右移

**这里踩过一个真实的坑**，而且和 `osd_panel` 的暗色玻璃底（`docs/b3_param_osd_2026-10-29.md` §3.2）是同一个坑：

```verilog
// 错误写法：把 16 位 RGB565 当一个整数缩放
assign rgb_out = rgb_in * level >> 8;   // 0xFFFF >> 8 = 0x00FF，红被压成蓝
```

纯白 `16'hFFFF` 右移 8 位得到 `16'h00FF`——绿色分量被挤进了红/蓝的位置，画面上的白色直接变成蓝色。RGB565 的三个通道是**打包在一个字里的三个独立数**，任何整体移位都会让高位通道的低位比特流进低位通道。

`tb_fade_mixer` 的 F03 用例专门守这条：`level=128` + `rgb_in=16'hF800`（纯红）必须输出 `16'h7800`——红通道缩放、蓝通道严格为 0。一旦写成整体移位，蓝通道会拿到非零值，F03 立刻失败。

**第二个坑**：初版 F03 忘了在赋值后加 `#1`，组合输出还没落定就读 `rgb_out`，读到 `0000` 报了个假失败。纯组合模块的 TB 断言前必须让组合逻辑落定——这条已写进 TB 注释。

### 4.3 混合器必须纯组合，与 `de` 同拍

`pix_reader` 的 `pix_rgb565` 是组合输出（`assign pix_rgb565 = !pix_valid ? 16'd0 : ...`），与 `de` 同拍无延迟。`video_content_mux` 依赖这个契约选像素。混合器若插一级寄存器，整幅画面右移一个像素、且第一列会拿到上一行最后一个像素——不是暗一点，是错位。

所以 `fade_mixer` 内部全部是 `assign`，`image_player` 里也是一行直连：

```verilog
wire [15:0] reader565;
pix_reader #(...) u_reader (..., .pix_rgb565(reader565), ...);
// 转场混合必须与 de 同拍：reader 是组合输出，中间不能插寄存器，否则像素整拍错位。
fade_mixer u_fade (.rgb_in(reader565), .level(fade_alpha), .rgb_out(rgb565));
```

### 4.4 系数只在垂直消隐推进

`fade_alpha` 若在行消隐甚至逐像素更新，同一帧内上下半部分亮度不同——屏幕上会出现一条横向的亮度台阶在滚动，比硬切换更难看。

所以 α 的每一次变化都挂在 `vblank_rise` 上，一帧一个台阶：

```verilog
if (vblank_rise) begin
    if (fade_alpha > FADE_STEP) fade_alpha <= fade_alpha - FADE_STEP;
    else fade_alpha <= 8'h00;
end
// 上一拍已把系数压到 0，这一次消隐就是全黑换帧点。
if ((fade_alpha == 8'h00) && vblank_rise) begin
    front_sel <= back_sel;
    commit_pending <= 1'b0;
    fade_state <= F_IN;
end else begin
    fade_state <= F_OUT;
end
```

注意第二段判的是**上一拍**的 `fade_alpha`：α 刚被压到 0 的那一帧，屏幕上显示的是全黑；下一拍消隐来时 α 仍是 0，此时翻帧首，新帧的第一帧就从 α=0 开始淡入。全黑帧正好夹在两段之间，翻帧完全不可见。

### 4.5 转场被打断时必须立刻回全亮，并撤掉挂起的提交

这条是读代码时才发现的隐患，不是猜的。`C_SHOW` 分支原来的重装逻辑是：

```verilog
C_SHOW, C_FAIL: if ((pending || load_req) && sd_ready && !blk_busy) begin
    ...
    if (FADE_ON && commit_pending) commit_pending <= 1'b0;   // ← 必须补这句
    fade_alpha <= 8'hFF;
    fade_state <= F_IDLE;
    ...
end
```

两个问题叠在一起：

1. **停在暗态**：转场进行到一半时用户按了下一张，若只重置 α 不重置状态，`fade_state` 还停在 `F_OUT`，下一帧的淡入逻辑根本不会执行——画面永久卡在暗态。
2. **提前翻帧**：转场期间 `commit_pending` 一直是 1（它要等全黑才清）。新请求进来时若不清它，这次提交会在**新帧装载到一半**的时候翻帧首——把半张新图翻到前台，屏幕上一半新一半旧。

看门狗分支（`error_code = 8/9`）同样补了 α 与状态的复位，否则故障恢复后画面也是暗的。

### 4.6 首帧不走转场

上电第一帧没有"上一帧"可淡出，硬走转场就是开机先黑 286 ms 再淡入。所以 `!image_ready` 分支直接提交、α 置满、状态回 `F_IDLE`：

```verilog
if (!image_ready) begin
    front_sel <= back_sel;
    image_ready <= 1'b1;
    commit_pending <= 1'b0;
    fade_alpha <= 8'hFF;
    fade_state <= F_IDLE;
end
```

---

## 五、过渡时长

`FADE_FRAMES = 8` → `FADE_STEP = 256 / 8 = 32`。逐帧推演（α 为每帧显示的亮度系数）：

| 消隐序号 | 阶段 | α | 说明 |
|---|---|---|---|
| 1 | F_OUT | 255 → 223 | 开始淡出 |
| 2~7 | F_OUT | 223 → 31 | 每帧降 32 |
| 8 | F_OUT | 31 → 0 | 压到全黑 |
| 9 | F_OUT → F_IN | 0 | **翻帧首**，全黑帧夹在中间 |
| 10 | F_IN | 0 → 32 | 开始淡入新帧 |
| 11~16 | F_IN | 32 → 224 | 每帧升 32 |
| 17 | F_IN → F_IDLE | 224 → 255 | 回到满亮，转场结束 |

17 个垂直消隐周期 × 16.8 ms ≈ **286 ms**。`FADE_FRAMES` 可调：4 → 约 150 ms（TB 用这个值压缩仿真时间），2 → 约 84 ms，1 → 关闭转场（等价 `FADE_EN = 0`）。

---

## 六、验证证据

### 6.1 单元：`tb_fade_mixer`

| 用例 | 判据 |
|---|---|
| F01 满档恒等 | `level=255` 时 `FFFF / 0000 / F800 / 07E0 / 001F / 8410` 逐位还原 |
| F02 零档全黑 | `level=0` 时全部输出 `0000` |
| F03 通道独立 | `level=128` + `F800` 必须输出 `7800`，防整体移位把红压进蓝 |
| F04 单调 | 256 档逐档扫，三通道都不许回退 |
| F05 逐通道公式 | `r_exp = (r5 × (i+1)) >> 8` 等，256 档全覆盖 |
| F06 中间档 | `level=128` + `FFFF` → `7BEF` |

**14 条检查，errors=0**，`ALL CHECKS PASSED: fade_mixer`。

### 6.2 集成：`tb_image_player` 三档

| 档位 | 命令 | checks | 转场观测 |
|---|---|---|---|
| 默认小尺寸 | `vsim work.tb_image_player` | **8,270** | `FADE: frames=4 flips_at_black=4 flips_in_grey=0 black_frames=8` |
| 单缓冲 | `vsim -gSEAMLESS=0 work.tb_image_player` | **8,263** | `FADE: frames=4 flips_at_black=0 flips_in_grey=0 black_frames=0` |
| FULL 640×480 | `vsim -gFULL=1 work.tb_image_player` | **1,228,817** | `FADE: frames=2 flips_at_black=1 flips_in_grey=0 black_frames=2` |

三档全部 `errors=0`，`starve_cycles=0`，`front_flips` 与 `flips_at_black` 一致——**每一次翻帧首都发生在全黑那一拍**，没有一次在灰色中途翻。

新增五条断言（`sim/testbench/tb_image_player.v:494-498`）：

```verilog
chk(fade_flip_bad == 0,"front buffer only flips while the frame is fully faded to black");
chk(fade_flip_ok >= 1,"the transition actually faded down to black before flipping");
chk(fade_black_frames >= 1,"at least one whole frame is displayed at full black");
chk(dut.fade_alpha == 8'hFF,"transition completes back to full brightness");
chk(dut.fade_state == 2'd0,"transition state machine returns to idle");
```

**这里也踩过一个坑**：首轮跑出 `flips_in_grey=2` 失败。加 TRACE 打印真实波形后才看清——`front_sel_d` 比 `front_sel` 晚一拍，而首帧提交时 `image_ready` 恰好在同一拍才置 1，观测块读到的是"已就绪"，于是把**首帧首次发布**误记成一次转场翻帧。RTL 一直是对的。修法是在 TB 里补一个 `image_ready_d`（与 `front_sel_d` 同步晚一拍），首帧发布时 `image_ready_d` 仍为 0，天然排除。

顺带修了 `task terminal` 的等待条件：原来只等 `loading || commit_pending`，淡入阶段这两个都是 0，会提前返回，导致 `check_frame` 比对到暗画面。现在加上 `|| (dut.fade_state != 2'd0)`。

### 6.3 回归与综合

| 项目 | 结果 |
|---|---|
| 前端回归 | **20/20 case 全通过**（含 `fade_mixer` 14 条） |
| 整帧逐像素回归 | `checks=614405 errors=0 missing=0 mismatched=0 frameIdentical=True` |
| `lint_verilog.py rtl` | 51 个文件，E0/E1/E2 全 0 |
| TD 综合布线 | `B2_FADE_TIMING_PASSED: setup=1.935 hold=0.003`，bitgen 成功（423,141 bits），位流 629,640 字节 |
| 组合环 | `There are 0 combinational loops.` |

顶层资源（`reports/b2_fade_20261029/area.txt`）：

```
#IO      41  / 188   21.81%
#lut  13502  / 19600 68.89%
#reg   5993  / 19600 30.58%
#bram9k  17 / 64     26.56%
#dsp     15 / 29     51.72%
```

`fade_mixer` 实例占用（`area.txt:203`）：

```
| u_fade | fade_mixer | 237 | 237 | 0 | 26 | 0 | 2 |
```

**237 LUT + 2 DSP + 0 寄存器**。DSP 是三个通道乘法的自然映射（`15/29` 从 13 增到 15），零寄存器意味着它确实没有在像素通路上插任何一拍。

### 6.4 关于"资源净增量"的说明

`reports/noise_sci_fix_20261029/area.txt` 与本次 `area.txt` **SHA 完全一致**，且其中已含 `u_fade` 行——该目录被早前一次流程运行覆盖刷新过，**不能当作 B2 之前的净基线**。所以本文只报 `fade_mixer` 实例行（237 LUT + 2 DSP）作为可信增量，不做顶层 LUT 的差减。

---

## 七、改动清单

**新增**

- `rtl/storage/fade_mixer.v`（30 行）
- `sim/testbench/tb_fade_mixer.v`（120 行）
- `project/flow_b2_fade.tcl`（35 行）
- `docs/fade_transition_2026-10-29.md`（本文）

**修改**

- `rtl/storage/image_player.v`：新增 `FADE_EN` / `FADE_FRAMES` 参数、`fade_state` / `fade_alpha` 寄存器、提交块重写、看门狗与重装分支补复位、reader 输出改接 `fade_mixer`
- `sim/testbench/tb_image_player.v`：新增 `FADE_FRAMES` 参数、`image_ready_d`、五项转场断言、`terminal` 等待条件、`FADE:` 统计行
- `sim/scripts/run_image_regression.ps1`：源列表加 `fade_mixer.v`
- `sim/scripts/run_frontend_regression.ps1`：源列表加 2 个文件，case 加 `fade_mixer`
- `sim/scripts/run_display_content.ps1`：源列表加 `fade_mixer.v`
- `scripts/sync_src.ps1`：登记 `rtl\storage\fade_mixer.v` → `project\hdmi\fade_mixer.v`
- `project/hdmi_td.al`：新增 `hdmi/fade_mixer.v`（`CompileOrder=47`）

**未改动**

- `rtl/top/dmz_eg4s20_hdmi_top.v` 的 B2 相关接线：`rgb565` 输出语义不变，顶层零改动
- `rtl/storage/framebuf_arbiter.v`、`rtl/storage/pix_reader.v`：单读通路结构完全保留

---

## 八、仍未完成

1. **未上板**。286 ms 的过渡在真实显示器上是否合适（会不会觉得拖沓、全黑帧是否真的看不见）只能上板判断。当前验证档位是**仿真 + 综合布线**。
2. **转场期间的显示内容**。淡出阶段显示的是旧帧——如果用户在轮播中途连按换图，会连续看到几次"暗下去又亮起来"。是否要做"转场中忽略新请求"的策略，取决于上板观感，本轮不做。
3. **`FADE_FRAMES` 是编译期参数**。运行时不可调（16 个键已全部占满，没有空闲键位）。若要可调，最省的做法是复用 B3 参数面板的入口，但需要额外状态位。
4. **不解决 KEY0/KEY1 切图白色噪点**。那是独立缺陷，根因未定位，见[交接报告](handover_2026-10-29_noise_unresolved.md)。转场只是把换帧点藏进全黑，不改变欠载像素的来源。
