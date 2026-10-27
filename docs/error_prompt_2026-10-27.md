# 错误提示面向用户化（A8 / P1-9）

日期：2026-10-27（跨 10-26 夜间完成）
范围：把数码管上"必须查表才看得懂"的内部错误码，改造成**面向用户动作的助记符提示**；
为蜂鸣器补上**故障告警音**（改造前故障时完全不响）；首次启用 `sd_cd` 卡检测引脚。
对应 `TASKS.md` 的 A8 遗留项与 P1 第 9 条：「错误提示面向用户化（"请插卡 / 请格式化 / 图片尺寸不符"）」。

---

## 1. 为什么原来的错误提示不算数

改造前的错误提示是"把内部码搬上数码管"，共三处缺陷：

| 位置 | 改造前 | 问题 |
|---|---|---|
| 数码管 dig3 | `sd_fail ? 1 : gallery_fail ? 3 : image_failed ? 2 : playback_state` | 故障类型码与播放状态码**共用同一个数字空间**。用户看到 `1`，无法判断是"SD 故障"还是"正在扫描 SD" |
| 数码管 dig2 | `gallery_fail ? gallery_err : sd_fail ? probe_err : image_error` | 原始码 1~9 的语义**取决于哪个模块报的**：同样是 `3`，在 `sd_probe` 是 "ACMD41/CMD58 异常"、在 `img_loader` 是 "底层读块失败"、在 `gallery_probe` 是 "簇链异常"。用户根本记不住 |
| 蜂鸣器 | `.tone_sel(mode==2 ? 2'd2 : 2'd1)` | **故障时完全不响**。设备坏了这件事没有任何听觉通道，"没插卡"和"正常启动"在声音上无法区分 |

还有一处**最严重的盲区**（改造前连指示灯都没有）：

> 卡读通了、文件系统也正常，但根目录里**一张 `IMGnnn.BMP` 都没有**。
> 此时 `sd_fail = gallery_fail = image_failed = 0`，`gallery_probe` 走的是 `done + count=0`
> 这条**合法终局**（见 `rtl/storage/gallery_probe.v`：`f32_err == 4` 是正常终止，不是 `fail`）。
> 结果：数码管停在 `0000`、屏幕放测试图、蜂鸣器不响、LED 全灭 ——
> 现场维护人员会直接判断"设备坏了"，而实际上只需要往卡里拷几张图。

## 2. 改造方案：新增 `err_prompt` 归并层

新建 `rtl/control/err_prompt.v`（335 行），单一职责：**把 5 个模块散落的内部码，归并成 5 类"用户动作"**。
它不下发任何控制信号，只产出三个显示/发声量，因此对既有数据通路零侵入。

```
             sd_probe ──sd_fail/sd_err──┐
          gallery_probe ──fail/err─────┤
                          ──done/count─┼──> err_prompt ──err_active──> LED[7]
        image_player ──failed/err──────┤            ├──prompt_hi/lo─> 数码管 dig3/dig2
              卡座 sd_cd ──────────────┘            └──alarm_req────> buzzer_tone 档位 3
```

### 2.1 五位助记符编码（受硬件硬约束）

助记字母的选型不是自由的：`rtl/common/seg_decoder.v` 只实现了 **0~9 / A / b / C / d / E / F 共 16 个字符**，
没有 `P`、`n`、`r`。所以常见的 "Picture"、"No card" 这类词根本显示不出来，只能在这 16 个字符里挑。

| dig3 | dig2 | 含义 | 用户动作 | 触发来源 |
|---|---|---|---|---|
| `C` | `0` | 卡座报告无卡 | 插卡 | `sd_cd[1] == 1`（硬件电平，最快） |
| `C` | `1` | 卡没响应（CMD0 重试用尽） | 插紧 / 换卡 | `sd_err == 1` |
| `C` | `2` | 协议不兼容、非 SDHC | 换一张卡 | `sd_err == 2/3/4` |
| `F` | `1` | MBR 扇区签名不是 `0x55AA`（未分区） | 格式化为 FAT32 | `sd_err == 8`、`gallery_err == 1` |
| `F` | `2` | VBR/BPB 非法 | 格式化为 FAT32 | `gallery_err == 2` |
| `F` | `3` | FAT 簇链异常 | 格式化为 FAT32 | `gallery_err == 3` |
| `F` | `4` | FAT32 定位失败 | 格式化为 FAT32 | `image_err == 1` |
| `0` | `0` | **卡正常但零张图片** | 拷入 `IMG001.BMP` 起的连续文件 | `gallery_done && count == 0` |
| `b` | `1` | BMP 头解析失败（非 BM / 非 24bit / 有压缩 / 宽高不符） | 换图或重新导出 | `image_err == 2` |
| `b` | `2` | 实际像素数 ≠ 640×480 | 缩放到 640×480 | `image_err == 7` |
| `d` | `1` | 错误令牌 / CRC / 应答错 | 擦拭金手指、换卡 | `sd_err == 5/6/7` |
| `d` | `2`~`d8` | 底层读块、SDRAM、超时、FIFO 无空间等 | 检修（非用户可解） | `gallery_err == 5/6`、`image_err == 3/4/5/8/9` |
| `C/F/b/d` | `9` | 命中 `default` 分支 | 记录该值反馈开发 | 未映射码的防御性兜底 |

**关键设计：第一位字母就决定用户该做什么，第二位只是同类别内的细分。**
普通用户只需认第一位（`C` 插卡 / `F` 格式化 / `0` 放图 / `b` 换图 / `d` 报修），
第二位留给维修人员定位。这解决了"原始码语义随上报模块变化"的问题。

### 2.2 为什么"有错整组切换"，而不是"故障时覆盖一位"

改造前是"故障时把 dig3 换成故障类型码"，正常时显示播放状态 —— 两者混用同一数字空间。
改造后改为 `err_active` 决定**整组切换**：

```verilog
wire [3:0] error_value = err_active ? prompt_lo : image_error;        // dig2
wire [3:0] state_value = err_active ? prompt_hi : {1'b0, playback_state}; // dig3
```

有错时高两位显示**字母**，无错时显示**数字**。字母与数字天然可分，用户不会再把
"1 = SD 故障" 和 "1 = 正在扫描 SD" 搞混。无错时 dig2 仍显示 `image_error`，与改造前行为一致。

### 2.3 优先级

高 → 低：`sd_fail` > `gallery_fail` > `image_failed` > `gallery_done && count==0` > `sd_cd`。
与顶层 `playback` FSM 的"故障 > 应急 > 扫描 > 装载 > …"口径一致。

> `image_error == 6` 是 `image_player` 对 `sd_failed` 的透传，此时 `sd_fail` 必为 1，
> 会被更高优先级接住。保留该分支仅为防御性兜底。

### 2.4 `sd_cd` 为什么只做提示、不触发重探

`sd_cd`（E15，无卡=1，10k 上拉）在 `constraints/dmz_eg4s20_hdmi.adc` 里**早已分配**，
但改造前 RTL 一行都没用它，端口注释还写着"本版未用"。本次首次启用，只做一件事：

> `sd_probe` 要等 `PROBE_DELAY_CYCLES`（200 000 拍 ≈ 8 ms）才开始，初始化失败还有 CMD0 重试，
> 用户要等**数秒**才有反应；而 `sd_cd` 是硬件电平，上电即有。用它可**立刻**给出 "C0 请插卡"。

真正的"拔插卡后自动重探"本次**没做**，原因是它需要给 `sd_spi_ctrl` / `sd_probe` /
`gallery_probe` / `image_player` 造一条独立复位树：`sd_spi_ctrl` 的 `I_DONE` / `I_FAIL`
是注释明确写着的"电平保持，等复位"自锁终态（`rtl/storage/sd_spi_ctrl.v:589-594`），
**不改复位就无法重试**。该改动跨 4 个模块 + 跨时钟域，风险远高于本次范围。
"重试"单独列为 P1 第 7 条（SD 热插拔恢复），见第 9 节。

## 3. 告警音：`buzzer_tone` 新增第 4 种模式

改造前的 `buzzer_tone` 只有三种模式（`tone_sel` 为 2 位）：`0` 静音 / `1` 按键音 / `2` 应急音。
本次扩为 3 位并新增 `3` = 故障告警音。

**后向兼容（重要）**：2 位表达式接 3 位端口时高位自动补 0，且既有比较常量 `2'd1` / `2'd2`
在 3 位上下文里等于 `3'd1` / `3'd2`。因此 `dmz_eg4s20_min_top`、`dmz_eg4s20_bringup_top`、
`image_dm_fix` / `image_path_diag` / `image_readback_diag` 三个 diag 工程 —— **一行都没改**。

### 3.1 三种声音的可区分性

| 模式 | 音高 | 节奏 | 语义 |
|---|---|---|---|
| `1` 按键音 | C5 523 Hz | 单次 100 ms | 交互确认（"按到了"） |
| `2` 应急音 | E6 1319 Hz | 250 ms 响 / 250 ms 停 | 高音急促 = 警示**逃生** |
| `3` 故障告警 | A4 440 Hz | 700 ms 停 / 300 ms 响 | 低音沉闷 = 警示**设备故障** |

三个维度都拉开：**音高**（低/高/中低）、**节奏**（单次/快交替/慢交替）、**占空比**（—/50%/30%）。
现场即使在嘈杂环境里也能分辨"该跑"还是"该修"。

### 3.2 告警音为什么"延迟 1.5 秒、只响 3 秒"

`err_prompt` 的告警时序（`CLK_FREQ_HZ = 25 MHz`）：

```
ALARM_DELAY = CLK_FREQ_HZ * 3 / 2 = 37_500_000   // 1.5 s 静默观察期
ALARM_HOLD  = CLK_FREQ_HZ * 3     = 75_000_000   // 3   s 鸣响期
ALARM_TOTAL = ALARM_DELAY + ALARM_HOLD           // 4.5 s 一个周期，数到此值饱和不回绕
```

设计理由：

1. **延迟 1.5 s**：若一上电无卡就立刻长鸣，用户先被吵到而不是先看到提示；且上电瞬间 SD 尚未探测，过早报警容易误报。
2. **只响 3 s**：本设备是**无人值守**的校园媒体屏。若告警音无限循环，没人来处理的后果就是整栋楼一直听滴滴声 ——
   那比"完全不响"更糟，用户会直接把蜂鸣器拆掉，**告警通道彻底失效**。故设计为"响一段就停"：
   听到的人过来看一眼数码管，而数码管会把问题一直摆在那里（视觉通道长期有效，听觉通道只负责"叫人"）。
3. **错误消失即清零**：拔卡/换卡/放图后错误解除，`alarm_cnt` 归零；下次再出问题重新从 0 计满 ——
   **每一次新的故障都会重新响一遍，不会漏报**。

## 4. 顶层接线（`rtl/top/dmz_eg4s20_hdmi_top.v`，402 → 497 行）

| 位置 | 改造前 | 改造后 |
|---|---|---|
| 端口注释 L34 | `sd_cd, // 本版未用` | `sd_cd, // E15, 卡插入检测（无卡=1 插卡=0）` |
| 新增 | — | `err_prompt #(.CLK_FREQ_HZ(25_000_000)) u_err (...)`（L437-444） |
| `u_buzz.tone_sel` | `mode==2 ? 2'd2 : 2'd1` | `beep_muted ? 3'd0 : (alarm_req ? 3'd3 : (mode==2 ? 3'd2 : 3'd1))` |
| `led[7]` | `sd_or_gallery_fail \|\| image_failed` | `err_active` |
| 数码管 dig2 | `error_value`（原始码） | `err_active ? prompt_lo : image_error` |
| 数码管 dig3 | `state_value`（故障类型码/状态） | `err_active ? prompt_hi : {1'b0, playback_state}` |

**蜂鸣器优先级：静音(KEY14) > 故障告警 > 应急 > 按键音。**
静音排最前，因为它是用户**显式**要求"别响"，其余三档都是设备自己想响 —— 用户意志高于设备提示。
静音用的是 `tone_sel = 0`（本就是静音档），而不是给 `buzzer_tone` 加 `mute` 端口：
为一个开关去改已验证模块的端口表，收益为零、回归风险非零。

**`led[7]` 语义扩大**：从"某个 fail 标志为 1"扩大到"存在任何面向用户的错误"，
从而把"卡好但零张图"这个改造前**没有任何指示灯反映**的盲区也纳入。
否则现场换一张没有 `IMGnnn.BMP` 的卡，灯全灭、屏幕放测试图，看起来和正常启动一模一样。

> `wire sd_or_gallery_fail = sd_fail || gallery_fail;`（L188）**保留未删**，
> 仍被 `playback` FSM（L276）使用，两条通路职责不同。

## 5. 接口与时序假设

1. **`err_prompt` 与 `sd_probe` / `gallery_probe` / `image_player` 同为 `clk_pixel`（25 MHz）域**，
   全部输入直连，不做跨域同步。这是既有顶层的事实（这几个模块都挂在 `clk_pixel` 上），本次沿用。
2. **`sd_cd` 是唯一的外部异步输入**，模块内做两级同步（`cd_sync <= {cd_sync[0], sd_cd}`），
   **只同步不去抖**：该信号由 10 kΩ 上拉拉稳，机械抖动只造成提示短暂跳变（无害），
   且它只驱动"显示"、不驱动任何控制通路，加去抖的收益为零。
3. **`err_active` / `prompt_hi` / `prompt_lo` / `alarm_req` 都是组合输出**（块③纯组合译码，块首统一给默认值），
   因此与输入**同拍变化**，无延迟。数码管扫描器（1 kHz）采样不敏感。
4. **`alarm_cnt` 饱和不回绕**：`if (alarm_cnt < ALARM_TOTAL) alarm_cnt <= alarm_cnt + 1;` ——
   数到末端后保持不动，故每个故障只响一轮；`err_active` 归零时立即清零。
5. **赋值规范**：时序块只用 `<=`、组合块只用 `=`、每变量只由一个 `always` 块驱动
   （`scripts/lint_verilog.py` 的 E1/E2 规则零容忍）。`err_prompt` 共 3 个 `always` 块，
   `buzzer_tone` 共 7 个，变量集合互不相交。
6. **`tone_sel` 位宽由 2 扩到 3**：按 Verilog 规则，2 位表达式接 3 位端口高位补 0；
   既有静态常量 `2'd1` / `2'd2` 在 3 位比较上下文中零扩展为 `3'd1` / `3'd2`，语义不变。

## 6. 验证方法与结果

### 6.1 已实测通过（ModelSim 10.1d 行为仿真）

| 验证项 | 命令 / 入口 | 结果 |
|---|---|---|
| `err_prompt` 单元 | 前端回归 `err_prompt` 用例 | **43 checks / 0 error**，`*** ALL CHECKS PASSED ***` |
| `buzzer_tone` 单元 | 前端回归 `buzzer_tone` 用例 | **23 checks / 0 error**，四种模式与三种半周期均断言 |
| **前端回归全套** | `powershell -File sim/scripts/run_frontend_regression.ps1 -ReportDir <可写目录>` | **13 个用例全部 passed=True，exit code 0**：sd_protocol_default 62、sd_protocol_fast 64、sd_spi_ctrl 23、sd_probe 14、fat32_reader 40、gallery_probe 37、bmp_parser 37、img_loader 43、player_ctrl 94、**err_prompt 43**、**buzzer_tone 23**、key_action 40、video_overlay 64 |
| 静态检查 | `python scripts/lint_verilog.py rtl project/src project/hdmi` | **77 文件，E0=0 E1=0 E2=0**，exit 0 |
| 源码同步 | `powershell -File scripts/sync_src.ps1` | 通过，automatic lint 双查全 0 |
| 顶层单文件编译 | `vlog rtl/top/dmz_eg4s20_hdmi_top.v` | exit 0，无告警 |

`tb_err_prompt`（313 行，`sim/testbench/tb_err_prompt.v`）覆盖 11 组场景 C1~C11：

| 组 | 覆盖内容 |
|---|---|
| C1 | 复位后无错误、无提示、无告警音 |
| C2 | SD 侧 9 个错误码的全部分支（含 `default`） |
| C3 | 图库侧 6 个错误码的全部分支（含 `default`） |
| C4 | 图片侧 9 个错误码的全部分支（含 `default`） |
| C5 | **零张图** → 显示 `00` |
| C6 | `sd_cd` 无卡抢先提示、插回后提示消失 |
| C7 | 三级优先级的抢占关系（sd > gallery > image） |
| C8 | 静默期 1/3、2/3、3/3 三个采样点均**不**响 |
| C9 | 延迟后起响、鸣响期内保持、周期后停止、**停止后不重复**、视觉提示仍在 |
| C10 | 错误清除后不响；新故障重新进入静默期并再次鸣响（**不漏报**） |
| C11 | 七张图时不产生任何提示（不误报） |

`tb_buzzer_tone`（269 行）覆盖 8 组 B1~B8：复位静音 / 模式 0 忽略 `trig` /
模式 1 有限窗口后自停 / 模式 1 窗口内可重触发 / 模式 2 无 `trig` 自动响停交替 /
模式 3 先静 700 ms 后响 300 ms / 三种半周期互不相同（±15% 容差）/ 切回模式 0 立即静音。

### 6.2 未验证（不得含糊）

- **全部结论只到行为仿真档，没有任何上板证据。** 正式顶层 `dmz_eg4s20_hdmi_top` 至今零上板记录。
- **`sd_cd` 的真实极性未实测**：代码按"无卡=1 / 插卡=0"实现（依据 `constraints/dmz_eg4s20_hdmi.adc`
  注释与 10 kΩ 上拉），但**从未在真机上插拔验证**。若极性反，`C0` 提示会变成"有卡时提示无卡"。
- **蜂鸣器三种音在真实蜂鸣器上的可区分性未验证**：仿真只测了半周期数值，
  实际蜂鸣器（无源 vs 有源）的频响、3.3 V 驱动下的音量差异均未实测。
- **`err_prompt` 未做综合布线**：LUT 占用、关键路径影响未知。它含 `case` 译码 + 32 位计数器，
  规模不大但需以实际综合报告为准。
- **`buzzer_tone` 扩位后的顶层未见 elaborat 级告警复查**（仅单文件 `vlog` 通过）。

## 7. 文件改动清单

### RTL

| 文件 | 改动 |
|---|---|
| [`rtl/control/err_prompt.v`](../rtl/control/err_prompt.v) | **新增**（335 行）。错误归并 + 告警时序 |
| [`rtl/audio/buzzer_tone.v`](../rtl/audio/buzzer_tone.v) | 278 → 336 行。`tone_sel` 2→3 位；新增机制 D（告警音相位 LSM）、`HALF_A4`/`ALARM_OFF`/`ALARM_ON` |
| [`rtl/top/dmz_eg4s20_hdmi_top.v`](../rtl/top/dmz_eg4s20_hdmi_top.v) | 402 → 497 行。例化 `u_err`；`u_buzz.tone_sel` 改 3 位四级优先级；`led[7]` 改 `err_active`；数码管 dig2/dig3 整组切换；`sd_cd` 端口注释 |

### 仿真

| 文件 | 改动 |
|---|---|
| [`sim/testbench/tb_err_prompt.v`](../sim/testbench/tb_err_prompt.v) | **新增**（313 行），43 条断言 |
| [`sim/testbench/tb_buzzer_tone.v`](../sim/testbench/tb_buzzer_tone.v) | **新增**（269 行），23 条断言 |
| [`sim/testbench/tb_player_ctrl.v`](../sim/testbench/tb_player_ctrl.v) | 三处 DUT 例化各补 `.auto_sw_sel(2'd0)`（并行改动新增端口后未接，导致悬空为 `x`） |

### 工程与脚本

| 文件 | 改动 |
|---|---|
| [`project/hdmi_td.al`](../project/hdmi_td.al) | 已含 `<File Path="hdmi/err_prompt.v">`（CompileOrder 113）。**漏加就是 black box** |
| [`scripts/sync_src.ps1`](../scripts/sync_src.ps1) | 新增映射 `rtl/control/err_prompt.v` → `project/hdmi/` |
| [`sim/scripts/run_frontend_regression.ps1`](../sim/scripts/run_frontend_regression.ps1) | `$sources` 补 2 个 RTL + 2 个 TB；`$cases` 补 `err_prompt` / `buzzer_tone`（**新 TB 不加进 `$sources` 根本不会被编译**） |

### 文档

| 文件 | 改动 |
|---|---|
| [`docs/error_prompt_2026-10-27.md`](error_prompt_2026-10-27.md) | **本文件（新增）** |
| [`TASKS.md`](../TASKS.md) | A8 行改写；P1 第 9 条划线并注明完成 |

## 8. 给下一个会话的操作要点

1. **想改提示文案/分类，只改 `err_prompt.v` 的块③** —— 那是唯一的分类真相源，
   顶层与 TB 都不含任何错误码语义。
2. **想加第 6 类提示**：先确认 `seg_decoder.v` 里有你要的字符，没有就先扩段码表，
   再动 `err_prompt` 的 `localparam`。**不要假设字母表是全的。**
3. **想改响铃时长**：只改 `ALARM_DELAY` / `ALARM_HOLD` 两个 `localparam`（都是"秒 × `CLK_FREQ_HZ`"），
   逻辑一行不动。改完必须同步改 `tb_err_prompt.v` 的 `ALARM_DELAY`/`ALARM_HOLD` 派生值。
4. **不要为了"更酷"把告警音改成无限循环** —— 第 3.2 节的三条理由是这个设计的全部依据。
5. **新增任何 `.v` 都要走三件套**：`project/hdmi_td.al` 加 `<File>`、`sync_src.ps1` 加 `$map`、
   回归脚本加 `$sources`（和 `$cases`）。

## 9. 未解决与下一步

| # | 事项 | 归属 | 说明 |
|---|---|---|---|
| 1 | **`sd_cd` 极性上板确认** | 最高优先 | 只需插拔一次卡观察数码管是否显示 `C0`。**极性反了要改 `err_prompt` 里 `cd_sync[1]` 的判断** |
| 2 | **拔插卡后自动重新探测** | P1-7 | 需给 `sd_spi_ctrl`/`sd_probe`/`gallery_probe`/`image_player` 造独立复位树。`sd_spi_ctrl.v:589-594` 的 `I_DONE`/`I_FAIL` 是自锁终态，不改复位无法重试 |
| 3 | 上板验证三种提示音可区分 | A8 | 仿真只测半周期，真实蜂鸣器频响未测 |
| 4 | `err_prompt` 综合与静态时序 | P0 | 未综合；SDRAM 侧 setup WNS `-7.232 ns` 与本次无关但未变 |
| 5 | 提示码表未进 README | 文档 | 用户手册性质，等上板确认极性后再定稿 |
| 6 | `bmp_parser` 的 5 个细分被 `img_loader` 压平 | 可选 | 目前统一显示 `b1`，若想区分"非 24bit"与"尺寸不符"，需给 `img_loader` 加宽 `err_code` 或另开一路 |
