# HDMI 音频嵌入（A4 / 基础验收 5）

日期：2026-10-26
范围：把原来只有视频的 HDMI 输出改成**带内嵌音频**的 HDMI 1.4b 输出；把原来固定 440 Hz 的 PWM 测试音换成**按播放状态变化的真实 PCM**，并让 HDMI 内嵌音频与 3.5 mm 接口共用同一份样本。

---

## 1. 为什么原来的音频不算数

改造前的音频全貌只有两条线：

| 通路 | 实现 | 问题 |
|---|---|---|
| `buzzer_tone` | 蜂鸣器，按键音与应急间歇音 | 是"提示音"，不是内容音频 |
| `pwm_audio_out` | 固定 440 Hz DDS 方波，25 MHz/256 载波 PWM，KEY6 静音 | 只能证明引脚有信号；与画面、与 HDMI 完全无关 |

`hdmi_tx.vhd` 内部只是把一个 VHDL 加密核 `DVITransmitter` 做端口映射，**该核的端口里根本没有音频**（只有 `RED_I/GREEN_I/BLUE_I`、`HS_I/VS_I/VDE_I`、4 根 TMDS）。所以"在现有链路上加音频"是不可能的——必须换核。

## 2. 换核：`hdmi_tx` → `hdmi_1_4b_transmitter_core_wrapper`

选用 `D:\FPGA_Compelate\SmartCampusMedia\project\reference\lab_ex5_i2s\` 里那份 328,975 字节的官方加密核，依据：

- 参考工程 `HDMI1.4b_Transmitter_v1.0.al` 的 `<Family>EG4</Family>`、`<Device>EG4S20BG256</Device>` —— **与本板完全同器件**，加密核可直接复用。
- 核的四个接口里带 Audio（`I_audio_valid` / `I_audio_left_data[23:0]` / `I_audio_right_data[23:0]`）与 ACR（`I_acr_valid` / `I_acr_cts[19:0]` / `I_acr_n[19:0]`）。

派生出的接口契约（全部实测自加密核文件）：

```
I_rst              —— 高有效（参考顶层接 rst_all = ~rst_n | ~audio_pll_lock）
I_axis_s_user      —— 帧首单拍
I_axis_s_valid     —— 数据有效
I_axis_s_last      —— 行尾
O_axis_s_ready     —— 仅在 last 后拉低，故一行数据必须连续
I_edid_read_trig   —— 单拍触发一次 EDID 读（可选）
O_ddc_scl/IO_ddc_sda —— 核内部 IIC master
```

本工程例化参数（640×480 基线）：

```verilog
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE("EG"),
    .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
    .VTOTAL(525), .VSA(2),  .VFP(10), .VBP(33), .VACTIVE(480),
    .VIDEO_TPG("Disable"),      // 必须 Disable 才用外部视频
    .VIDEO_FORMAT("RGB"),
    .VIDEO_VIC(1),              // 640×480@60 → VIC 1
    .AUDIO_SAMPLE_RATE("48K"),
    .IIC_SCL_DIV(250)           // f_pixel/(2×250) = 50 kHz
) u_hdmi_core ( ... );
```

## 3. 新写的 6 个模块

官方核缺的是"喂给它的四路信号"，所以这 6 个模块都是胶合层，不是重复造轮子：

| 模块 | 行数 | 作用 | 关键设计点 |
|---|---|---|---|
| [`audio_tone_gen`](../../rtl/audio/audio_tone_gen.v) | 160 | 48 kHz / 24 bit PCM 音源 | 分数分频使能；8 音 LUT；三角波（比方波柔和，谐波按平方衰减）；**静音时仍发 `valid`**（核要求输入速率 = 采样率） |
| [`audio_arc`](../../rtl/video/hdmi/audio_arc.v) | 71 | ACR 包的 CTS/N | `ACR_N=6144`，`AUDIO_DIV=48`（每 48 样本一包）；`cts` 每拍自增、发包容错后清零 |
| [`video_rgb_to_axis`](../../rtl/video/hdmi/video_rgb_to_axis.v) | 81 | RGB+DE+VS → AXIS | VS 跳变后行首发一次 `user`；`x_cnt==639` 发 `last` |
| [`hdmi_phy`](../../rtl/video/hdmi/hdmi_phy.v) | 62 | 4 路 10 bit TMDS 串化 | 输入先全位反序 |
| [`lane_lvds_10_1`](../../rtl/video/hdmi/lane_lvds_10_1.v) | 87 | 单 lane 2 bit/拍移位 + ODDR | `EG_LOGIC_ODDR(d1=data[0], d0=data[1])`；串化域不复位（与官方一致） |
| [`pcm_to_pwm`](../../rtl/audio/pcm_to_pwm.v) | 69 | 24 bit PCM → 1 bit sigma-delta | 一阶噪声整形；静音输出恒 0（保持 F3 原语义） |

### 3.1 一个必须说清的坑：`x_cnt` 语义

官方参考的 `video_rgb_to_axis_640x480.v` 在行首那拍 `S_x_cnt<=0`，else 分支才 `+1`，导致 `last` 实际落在第 **641** 个像素。本工程版统一写成：

```verilog
x_cnt <= x_cnt + 1'b1;              // 行首那拍也 +1
if (x_cnt == (H_ACTIVE - 1)) video_last <= 1'b1;   // 第 640 像素发 last
```

这样 `last` 严格落在第 640 个有效像素上。

### 3.2 一个必须说清的坑：`I_rst` 极性与 lint

- 加密核 `I_rst` **高有效**，顶层写 `.I_rst(~rst_n)`。
- 项目 `scripts/lint_verilog.py` 禁止"同一 `always` 内混用 `=` 与 `<=`"（E1）。所以 `audio_tone_gen` 里分频累加的中间量写成 **wire**：

```verilog
wire [31:0] sample_acc_add = sample_acc + SAMPLE_RATE_HZ;
```

而不是照抄参考例程的阻塞式中间变量。

## 4. 音视频联动怎么落地的

顶层新增 `playback_state[2:0]`，优先级从高到低：

```
sd/gallery/image 故障 → ST_FAIL(6)   静音（别用噪音干扰排查）
mode == 2（应急）      → ST_EMERG(5)  C5/G4 交替告警
SD 未扫描完            → ST_SCAN(1)   C4 长鸣
图片装载中             → ST_LOAD(2)   E4
图片就绪 && 自动轮播   → ST_AUTO(4)   五音循环
图片就绪               → ST_READY(3)  G4
其余                   → ST_IDLE(0)   静音
```

**同一份 `audio_left` 同时送两处**：

```verilog
hdmi_1_4b_transmitter_core_wrapper ... .I_audio_left_data(audio_left) ...
pcm_to_pwm u_pwm_audio (... .sample_in(audio_left), .pwm_out(audio_pwm));
```

这就是"音视频联动"的实质——不是"有个声音在响"，而是"HDMI 里的声音和板子上 3.5 mm 里的声音是同一份数据，且内容由画面状态决定"。

### 4.1 可观测性

| 指示 | 改造前 | 改造后 |
|---|---|---|
| `led[3]` | `locked` | `locked && hdmi_video_locked`（能区分"时钟有了但核没对齐"） |
| 数码管第 3 位 | 仅故障码 1/2/3，正常显示 0 | 正常时直接显示 `playback_state` 0～6，板上可读"HDMI 里在发哪个状态的声音" |

## 5. 本板没有 DDC：如实声明

**已核实三处依据，结论是这块底板 HDMI 座只引出 TMDS 4 对差分：**

1. `EG4S20_综合底板.pdf` 第 0 页：U7 = AZ1045-04F（ESD 阵列）只接 `HDMI_CLK_P/N`、`HDMI_D0_P/N`、`HDMI_D1_P/N`、`HDMI_D2_P/N`、`HDMI_5V`；HDMI-019S 座上除 4 对差分 + 5V 外仅 P66 0 Ω 接 GND，**没有 SCL/SDA 网络到 FPGA**。
2. `板卡和引脚说明.pdf` §3.3「HDMI 输出」只列 4 个信号。
3. 参考工程 `pin.adc` 里 DDC 是 `HDMI_DDC_SCL=P2` / `HDMI_DDC_SDA=R2`（HX4S20C 板），**与本板完全不同，不可移植**。

因此本工程的处理是：

- 顶层 `O_ddc_scl` / `IO_ddc_sda` 接到内部悬空信号，**不引出为端口、不约束管脚**；
- `I_edid_read_trig` 固定 `1'b0`，从不发起 EDID 读；
- **不做 EDID 协商**，音频/视频信息包按参数静态构造。

这不影响核发流：EDID 读取是显式触发式的（`I_edid_read_trig` 单拍触发一次读 128 字节），文档里没有任何"读不到 EDID 就不能工作"的表述；核内部自建 Video Source 靠相位匹配机制与外部视频对齐，锁上后拉高 `O_video_locked`。

**待上板确认的唯一事项**：显示器能否正确解出音频。部分显示器在缺少 EDID 协商时仍能解音频（因为它默认用 ACR 恢复时钟），部分可能不出声——这条只有上板才能定论。

## 6. 时钟方案：为什么不加 12.288 MHz PLL

APUG092 文档原文：**"HDMI1.4b Transmitter Core 的四个接口 EDID Interface、Video Interface、Audio Interface 和 ACR Interface 都是工作在 Pixel Clock 时钟域下。"**

所以音频只需要"在 25 MHz 域按 48 kHz 节拍给样本"。官方 `lab_ex5_i2s` 那条例程之所以有 `PLL_HDMI_AUDIO` + `hdmi_audio_tone_i2s_64fs` + `I2S_receiver`，是为了**演示 I2S 输入这个功能**，不是核的硬性要求。而且那颗 PLL 也做不到精确 12.288 MHz（50 MHz 下 `FBCLK_DIV=3, CLKC2_DIV=61` 实际出 **12.295082 MHz**，偏差 +0.06%）。

本工程的选择：**不加第三颗 PLL、不做 I2S 收发回环**。省一颗 PLL（本板 EG4S20 只有 4 个，已用 2 个）、省一路跨域、与现有架构冲突最小。

## 7. 验证证据

### 7.1 仿真（已通过）

`sim/scripts/run_audio_regression.ps1`，2 个用例全绿、24 条 PASS：

```powershell
powershell -ExecutionPolicy Bypass -File sim/scripts/run_audio_regression.ps1
# hdmi_audio_path: passed=True; passLines=19
# pwm_audio_out_legacy: passed=True; passLines=5
```

`tb_hdmi_audio_path.v` 串起 `audio_tone_gen → audio_arc → pcm_to_pwm` 三级，实测数字：

| 检查项 | 期望 | 实测 |
|---|---|---|
| 采样率 | 48000/s | `valid=48000`，误差 0 |
| ACR N | 6144 | `acr_n === 20'd6144` |
| ACR 包率 | 1000/s | `acr=1000` |
| ACR 包间隔 | 25000 拍 | `gap=24999` |
| G4 音高 | 784 过零/秒 | `flips=785` |
| E4 音高 | 165 过零 | `flips=165` |
| C4 音高 | 131 过零 | `flips=131` |
| PWM 平均占空比 | ~50% | `490 permille` |
| ST_IDLE 静音 | valid 照发、样本恒 0 | `valid=4800 nonzero=0` |
| mute 后 PWM | 恒 0 | PASS |

### 7.2 综合布线（已通过，时序与基线一致）

```powershell
& D:/TD_6_24_APP/bin/td_commands_prompt.exe ./project/flow_s6_bit.tcl
# S6_PASS-optimize_rtl / optimize_gate / place / route
# S6_BIT_FLOW_DONE
# S6_TIMING_FAILED: setup=-7.232 ns hold=0.011 ns; bit is a candidate only  (exit 3)
```

> **构建时间绑定**：本表数字取自 `reports/s6_integration/build_hdmi_audio_rerun.txt`
> （`Run Date = Mon Oct 26 22:43:05 2026`，bit 产物 22:48:28）。首次构建
> `build_hdmi_audio.txt`（22:25:29 启动）早于 `rtl/audio/buzzer_tone.v` 的最后写入
> （22:30:38），那一版**用的是旧源码**，其资源/时序数字已作废，不再引用。

资源对比（`reports/s6_integration/area.txt`，基线取自 `git show :reports/s6_integration/area.txt`）：

| 项 | 改造前 | 改造后 | 变化 |
|---|---|---|---|
| LUT | 8215 (41.91%) | 9467 (48.30%) | +1252 |
| REG | 3773 (19.25%) | 5243 (26.75%) | +1470 |
| LE | 8852 | 10174 | +1322 |
| BRAM | 3 (4.69%) | 17 (26.56%) | **+14** |
| DSP | 13 (44.83%) | 13 (44.83%) | 0 |
| PLL | 2 (50%) | 2 (50%) | 0 |
| IO | 41 (21.81%) | 41 (21.81%) | 0 |

新模块自身占用（`area.txt` 分模块表，格式 `le / lut / ripple / seq / bram`）：

```
u_hdmi_core   le 1752  lut 1328  seq 1334  bram 14   ← 加密核（含 TMDS 编码与音频包插入）
  u_axis      le  231  lut  230  seq   85           ← video_rgb_to_axis
  u_tone      le  164  lut  117  seq   91           ← audio_tone_gen
  u_arc       le   61  lut   35  seq   45           ← audio_arc
  u_pwm_audio le   52  lut   26  seq   39           ← pcm_to_pwm
  u_phy       le   45  lut   36  seq   45           ← 4 lane 合计
    u_lane_ch0/1/2 + u_lane_clk = 16+12+12+5 LE
```

（`seq` 就是该实例的寄存器数。注意 `le` 列是"逻辑单元"，与 `lut` 列不是一回事，别混读。）

`u_hdmi_core` 一个实例就吃掉新增 LUT 的 98%、新增 BRAM 的全部 14 块 —— **这个代价换来的是"音频真的进了 TMDS 数据流"，不是软件模拟**。

**时序结论（关键）**：整体 WNS 仍是 **−7.232 ns**，且最差路径**与改造前完全同一路径**：

```
Begin Point : u_sdram_sip.dq[0]   (clk4 = u_sdram_pll clkc[2], 150 MHz 180°)
End Point   : u_sdram_sip_syn_1.bpad (clk1 = u_sdram_pll clkc[1], 150 MHz 0°)
Slack       : -7.232 ns   ← 改造前后数值相同
```

这是 SiP SDRAM 的器件接口路径，与本次音频改动**无因果关系**。本次改动**没有引入新的时序违例**——时序不收敛是既有问题（README 已记录，属 P0）。

两个版本的构建都给出**完全相同的 −7.232 ns 与完全相同的 Begin/End 端点**，这条路径从 `git show :reports/s6_integration/timing.txt` 的基线报告起就没变过。这也反向证明：音频通路全部落在 25 MHz 的 `clk_pixel` 域（clk0 SWNS **+24.731 ns**、clk2 125 MHz SWNS **+4.752 ns**，均为正裕量），**没有把时序压力加到已经失败的那个域上**。

### 7.3 上板（**未做**）

本轮没有任何上板证据。正式顶层从未上板，音频是否真的从显示器喇叭出来**尚未验证**。按项目的三档验证口径，此功能当前状态是"**仿真 + 综合布线通过，上板未验证**"，不能宣称"能出声"。

## 8. 边界与已知限制

1. **加密核无法仿真。** `hdmi_1_4b_transmitter_core_wrapper.enc.v` 是 Anlogic RSA + AES128-CBC 加密件，ModelSim ASE 无对应私钥，无法编译。因此仿真覆盖到"交给核的三组信号（AXIS / audio / ACR）正确"为止，**核内部行为（TMDS 编码、音频包插入、相位匹配）未被仿真验证**。
2. **音频内容是合成音，不是音乐文件。** 当前用 8 音 LUT + 三角波按状态选音高，没有 WAV/MP3 解码，也没有 SD 卡音频素材。
3. **无 DDC/EDID 协商**（见 §5），这是**硬件缺失**，不是软件偷懒。
4. **无音量控制。** KEY6 只有静音开关，没有音量分级。
5. **旧模块保留但不再使用。** `rtl/audio/pwm_audio_out.v` 与 `rtl/video/hdmi/hdmi_tx.vhd` 留在源码树里作历史参照与回退路径，但已不参与构建（`project/hdmi_td.al` 的 VHDL 段已清空）。它们的 testbench（`tb_pwm_audio_out.v`）仍纳入回归，保证回退路径不被破坏。

## 9. 文件清单

**新增 RTL**

- `rtl/audio/audio_tone_gen.v`
- `rtl/audio/pcm_to_pwm.v`
- `rtl/video/hdmi/audio_arc.v`
- `rtl/video/hdmi/video_rgb_to_axis.v`
- `rtl/video/hdmi/hdmi_phy.v`
- `rtl/video/hdmi/lane_lvds_10_1.v`

**新增仿真**

- `sim/testbench/tb_hdmi_audio_path.v`
- `sim/scripts/run_audio_regression.ps1`

**新增 IP（不入库，需自行从官方渠道获取）**

- `ip/local/hdmi/enc/hdmi_1_4b_transmitter_core_wrapper.enc.v`（328,975 字节）

**修改**

- `rtl/top/dmz_eg4s20_hdmi_top.v`（209 → 402 行）
- `project/hdmi_td.al`（新增 6 个 Verilog + 1 个加密核，VHDL 段清空）
- `scripts/sync_src.ps1`（新增 7 条映射，删除 5 条 DVI 相关条目）
- `README.md` / `TASKS.md` / `ARCHITECTURE.md`

**构建命令**

```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync_src.ps1          # 同步 + lint
powershell -ExecutionPolicy Bypass -File sim/scripts/run_audio_regression.ps1   # 仿真回归
& D:/TD_6_24_APP/bin/td_commands_prompt.exe ./project/flow_s6_bit.tcl   # 综合布线
```
