# t5 控制层与传感器链路 —— 实现说明与验收数据

> 本文是 t5（按键重排 + 三模式状态机 + 亮度 10 档 + AHT20 温度链路）的**实现落地文档**。
> 上位设计见 `PLAN.md` / `ARCH.md` / `KEYMAP.md`；本文只记录**已经写进 RTL 的东西**及其验收数据，
> 供 t8 集成、t10 终审、答辩材料直接引用。
>
> 全部数值都是本机实测或数据手册原文，不是估算。

---

## 1. 交付清单

### 1.1 新增 RTL（6 个）

| 文件 | 行数量级 | 职责 |
|---|---|---|
| `rtl/control/key_router.v` | ~360 | Key4~Key15 唯一译码器（一键一模块铁律的执行体） |
| `rtl/control/mode_ctrl.v` | ~230 | 日常 / 科普 / 应急三模式状态机 |
| `rtl/video/brightness_apply.v` | ~110 | 10 档亮度级（纯组合，零寄存器） |
| `rtl/sensor/i2c_master.v` | ~403 | I2C 主机物理层（100 kHz，开漏） |
| `rtl/sensor/aht20_ctrl.v` | ~730 | AHT20 协议层（触发 / 读 / CRC8 / 换算） |
| `rtl/sensor/thermal_guard.v` | ~180 | 传感器无关的「阈值 → 迟滞 → 联动」层 |

### 1.2 改动 RTL（1 个）

| 文件 | 改动 | 为什么 |
|---|---|---|
| `rtl/video/video_overlay.v` | 删除 :108-122 的 5 档亮度三目式，改直通 | 亮度移到 OSD 之后施加（赛规 1.4(4)「参数变化信息可读」） |
| ↑ 同上 | **`bright_sel` 端口保留不动** | 信息条第 8/9/10 格靠它画亮度格；删端口会连带删掉信息条显示 |
| ↑ 同上 | 增加 `osd_active_ovl` 输出 | 供上层做 OSD 掩码（v2 已按新裁决撤销，端口不存在） |

> **注**：`bright_sel` 在 v2 里只做信息条显示（接 `bright_lvl[2:0]`），**不再参与亮度运算**。
> 亮度数据通路的唯一实现是 `brightness_apply.v`。

### 1.3 新增 testbench（6 个，全部实跑通过）

| tb | 断言数 | 覆盖 |
|---|---|---|
| `sim/testbench/tb_key_router.v` | **30** | 10 档亮度 / 10 档音量 / 5 档分辨率 / 5 档屏占比 / 三开关 / 应急钳位 / osd_item 编码 |
| `sim/testbench/tb_mode_ctrl.v` | **48** | 三模式迁移、Key3 零延迟进应急、Key3 双按 2 s 确认退出、温度回落不自动退出 |
| `sim/testbench/tb_brightness_apply.v` | **27** | 10 档逐档数值 + 单调性 + 全值扫描 0..255 + 通道独立 + 消隐 |
| `sim/testbench/tb_i2c_master.v` | **23** | START/STOP/字节/ACK/NACK/开漏/SCL 周期/边缘触发 |
| `sim/testbench/tb_aht20_ctrl.v` | **32** | 量程端点 / **手册黄金向量 C16** / CRC 错 / NACK / 忙态 / 单拍脉冲 / 单调性 |
| `sim/testbench/tb_thermal_guard.v` | **23** | 有符号比较（负温）/ 迟滞 / 失联保持 / fail-safe |

**合计 185 项断言**，全部实跑通过。

### 1.4 改动 testbench（1 个）

| tb | 改动原因 |
|---|---|
| `sim/testbench/tb_video_overlay.v` | V03 段从「5 档亮度数值」改为「亮度直通契约」（反证亮度已移出）；V10 段期望值从 `24'h80_80_80` 改为 `24'h00_00_00`（只反色不调暗） |

回归结果：`=== tb_video_overlay: 106 checks, 0 error(s) ===`

### 1.5 约束文件

| 文件 | 改动 |
|---|---|
| `constraints/dmz_eg4s20_hdmi.adc` | 新增第 8 节：`i2c_scl`=D1 / `i2c_sda`=E1，均 LVCMOS33 / DRIVESTRENGTH=8 / **PULLTYPE=PULLUP** |
| `constraints/dmz_eg4s20_hdmi.sdc` | 新增 I2C 段：`i2c_scl` / `i2c_sda` 各 `set_false_path -from` / `-to`，共 4 条 |

---

## 2. 亮度 10 档数值表

### 2.1 方向约定（与既有硬件一致，**不得反向**）

现行 `rtl/video/video_overlay.v:108` 原是 `bright_sel == 3'd0 ? r_in`，即**档 0 就是最亮（旁路）**。
v2 保持这一方向：**档号递增 = 越来越暗**，`case` 的 `default` / 档 0 落到 32/32 旁路。
这样 Key6 的按键方向与老工程相同，迁移时语义不翻转。

> ⚠️ 注意与 `PLAN.md` §9.1 的旧稿差异：旧稿曾是「0=最暗」，已按本表订正。
> 与 `KEYMAP.md` §9.1 的现稿**完全一致**。

### 2.2 逐档表

| `bright_lvl` | 增益 | 百分比 | 移位加表达式（x 为 8 bit 通道值） | x=255 时的实际输出 |
|---|---|---|---|---|
| **0（复位值）** | **32/32** | **100 %** | `x`（旁路） | **255** |
| 1 | 29/32 | 90.6 % | `x - (x>>4) - (x>>5)` | 233 |
| 2 | 26/32 | 81.3 % | `x - (x>>3) - (x>>4)` | 209 |
| 3 | 23/32 | 71.9 % | `x - (x>>2) - (x>>5)` | 185 |
| 4 | 20/32 | 62.5 % | `x - (x>>2) - (x>>3)` | 161 |
| 5 | 16/32 | 50.0 % | `(x>>1)` | 127 |
| 6 | 13/32 | 40.6 % | `(x>>1) - (x>>4) - (x>>5)` | 105 |
| 7 | 10/32 | 31.3 % | `(x>>2) + (x>>4)` | 78 |
| 8 | 6/32 | 18.8 % | `(x>>3) + (x>>4)` | 46 |
| 9 | 3/32 | 9.4 % | `(x>>4) + (x>>5)` | 22 |

### 2.3 实现要点

- **零 DSP、零乘法器**：全部 10 档只用移位 + 1~2 个加减。
- **饱和截断**：内部用 9 位中间值 `reg [8:0] y`，`brt10 = y[8] ? 8'hFF : y[7:0]`。
  档位表达式都是「减」为主，理论上不会溢出；但档 7/8/9 是「加」，必须防进位。
- **纯组合零寄存器**：`brightness_apply.v` **没有 clk 端口**。
  若在此处插一拍寄存器（如某些设计草稿那样只打 `de` 与 `rgb`、**没打 `active_x/active_y`**），
  下游 `osd_panel` 靠 x/y 定位面板矩形会错开 1 拍 → **面板整体偏移一像素**。
  hold WNS 仅 +0.003 ns，任何多余的寄存器级都要慎重。
- **插入位置**：`video_overlay → brightness_apply → osd_panel → video_rgb_to_axis`。
  放在 `osd_panel` 之后会让参数面板一起变暗，违反赛规 1.4(4)；
  「字幕随画面调暗」可以接受，「参数面板必须不被调暗」。

### 2.4 音量表的反向提醒

`vol_lvl` 的方向与亮度**相反**：0 = 最轻（3/32），9 = 最响（32/32），复位 6（23/32）。
两张表的**增益数值集合完全相同**（3/32 … 32/32），只是**排列方向相反**。
因此 `vol_apply.v`（t6）**不能直接复用** `brightness_apply.v` 的 `case` 函数，需要各自写一份。
应急模式下 0/1/2 档钳位到 3 档，但 `vol_lvl` 寄存器本身仍记录用户选择的 0，退出应急自动恢复。

---

## 3. I2C 时序参数（`i2c_master.v`）

### 3.1 参数

| 参数 | 值 | 说明 |
|---|---|---|
| `CLK_FREQ_HZ` | 25,000,000 | 25 MHz 主时钟（像素时钟域，与视频同域，不新增时钟域） |
| `SCL_FREQ_HZ` | 100,000 | 标准模式 I2C |
| `QUARTER` | **63** 拍 | `(25e6 + 100e3×4 − 1) / (100e3×4)` 向上取整 |

### 3.2 为什么是 63 而不是 62

```
理想 QUARTER = 25_000_000 / (100_000 × 4) = 62.5
取 62 → SCL = 25e6 / (62×4) = 100,806 Hz  → 超出 100 kHz 标准模式上限 ✗
取 63 → SCL = 25e6 / (63×4) =  99,206 Hz  → 符合标准模式            ✓
```

**取整方向必须是向上**。这是标准模式 I2C 的硬指标，芯片手册标称 100 kHz 是上限不是标称值。

### 3.3 实测周期（tb_i2c_master C11）

```
一个完整 SCL 周期 = QUARTER × 4 = 63 × 4 = 252 拍
252 拍 × 40 ns/拍 = 10,080 ns = 10.08 µs
→ 实测 SCL 频率 = 99.21 kHz
判据：(scl_period_ns > 10040) && (scl_period_ns < 10120)  ✓ 通过
```

### 3.4 四相位结构

每 bit 分 4 个相位（`phase 0..3`），每相位 63 拍：

| 相位 | SCL | 数据线动作 |
|---|---|---|
| 0 | 低 | 准备 / 建立 |
| 1 | **高** | 数据稳定，从机采样 |
| 2 | **高** | 数据稳定，从机采样 |
| 3 | 低 | 变更数据 |

SCL 高电平 = 相位 1+2 = 126 拍 × 40 ns = **5.04 µs** ≥ 手册要求 t_HIGH ≥ 4.0 µs ✓
SCL 低电平 = 相位 0+3 = 126 拍 × 40 ns = **5.04 µs** ≥ 手册要求 t_LOW ≥ 4.7 µs ✓

### 3.5 开漏语义

FPGA 没有真开漏，用三态门：

```verilog
assign i2c_scl = scl_oe ? 1'bz : 1'b0;
assign i2c_sda = sda_oe ? 1'bz : 1'b0;
```

- `scl_oe = 1` → 释放（外部上拉拉高）
- `scl_oe = 0` → 拉低

**`PULLTYPE = PULLUP` 与开漏接法必须同时成立，缺一不可**：
外部没上拉 + 内部上拉关掉 → 总线永远为低 → 传感器完全无响应（现象是"读不到任何数据"，不是"时序错"）。

### 3.6 一处容易踩死的细节（已在 RTL 里修正并注释）

`S_IDLE` 在 `busy = 1` 时 **SCL / SDA 必须保持低**（`scl_oe_r = 0; sda_oe_r = 0`）。
否则 START 完成回 IDLE 那一拍 SCL 抬成高、SDA 抬成高，从机会误判 STOP，事务当场作废。

### 3.7 SDC 为什么用 `set_false_path` 而不是 `set_input_delay`

I2C 是异步准静态总线：SCL 半周期约 5.04 µs，FPGA 25 MHz 采样一步 40 ns，
采样点误差最多 1 拍 = 半周期的 **0.8 %**；AHT20 手册 `t_VD,DAT` 典型 250 ns。
用 SDC 去描述这种千倍余量只会制造**假违例**。

这与该 SDC 文件头记录的「拆组得到假绿」是同一种错误的镜像：那里是假绿，这里是假红。

---

## 4. AHT20 换算（零 DSP 推导）

### 4.1 公式约分（这一步是全部推导的关键）

```
手册：T(℃) = raw / 2^20 × 200 − 50
要 0.01 ℃ 分辨率：T_centi = (raw × 20000) / 2^20 − 5000

关键等价（精确相等，不是近似）：
     20000 / 1048576  =  1250 / 65536
即   （×20000 >> 20） ≡ （×1250 >> 16）
```

于是只需算 `raw × 1250 >> 16`，而 `1250 = 1024 + 128 + 64 + 32 + 2`：

```verilog
wire [30:0] t_mul = ({11'd0, t_raw} << 10) + ({11'd0, t_raw} << 7)
                  + ({11'd0, t_raw} << 6) + ({11'd0, t_raw} << 5)
                  + ({11'd0, t_raw} << 1);
t_centi_comb = $signed({1'b0, t_mul[30:16]}) - 16'sd5000;
```

**五位加法器，零乘法器、零 DSP。**

湿度同理：`10000 / 2^20 = 625 / 65536`，`625 = 512 + 64 + 32 + 16 + 1`。

### 4.2 位宽必须留意

`raw × 1250` 最大 = `1048575 × 1250 = 1,310,718,750 < 2^31 − 1`，**31 位足够**。

> ⚠️ 若按另一种等价写法 `×625 >> 15`，最大 `1048575 × 625 = 655,359,375`，需要 **30 位**。
> 曾有设计草稿把它写成 `wire [28:0]`（29 位），满量程截断后算出 3615 → 报 **−13.85 ℃**（实际 +149.99 ℃）。
> 失败方向同样是「报低温不触发应急」——**安全功能静默失效，是最坏的一类 bug**。
> 本实现用 `×1250 >> 16` 的 31 位形式，中间量留了 1 位余量，抗错改更强。

### 4.3 验证数据（全部实测）

| raw | raw×1250 | >>16 | `temp_centi_c` | 对应的物理温度 | 用例 |
|---|---|---|---|---|---|
| 0 | 0 | 0 | −5000 | −50.00 ℃ | C03 |
| 52428 | 65,535,000 | 999 | −4001 | −40.01 ℃（AHT20 标称下界 −40 ℃） | C04 |
| 524288 | 655,360,000 | 10000 | +5000 | +50.00 ℃ | C05 |
| 707790 | 884,737,500 | 13500 | +8500 | +85.00 ℃（AHT20 标称上界 85 ℃） | C06 |
| 1048575 | 1,310,718,750 | 19999 | +14999 | +149.99 ℃（满量程） | C07 |
| **196523**<br>`0x2FFAB` | **245,653,750** | **3748** | **−1252** | **−12.52 ℃**（真值 −12.5162 ℃，截断误差 0.0038 ℃） | **C16 / C16b** |

最后一行是**数据手册自己给的算例**（`ST = 0x2FFAB`，手册 p.12 原文
`T = (196523/1048576)*200-50 = -12.5℃`），已作为 `tb_aht20_ctrl.v` 的 **C16 / C16b**
两条用例固化并**实跑通过**：

```
C16  : chk(captured_temp == -16'sd1252, ...)   → PASS
C16b : chk(captured_temp <  16'sd0,    ...)   → PASS   ← 负数路径（借位减法，非符号位特判）
```

它比任何自造数据都有说服力：评委翻到手册 p.12 就能对上，不需要相信我们的推导。
`C16b` 单独验**符号路径**而不只验数值，是因为担心的失败方向是「负温被当成巨大正数
→ 高温报警误触发」——这条比数值错位更难从现象反推，必须显式覆盖。

> **实测确认**：`tb_aht20_ctrl.v` 中 `chk(` 调用点共 **32** 处，实跑 `PASS: 32 / FAIL: 0`。
> 即 C01a~C16b 全部 32 条断言**都在最终版本里跑过**，不是写完没跑。


### 4.4 为什么是 `temp_centi_c` 而不是 Q8.8

`temp_q8_8` 量程 = −128.00 ~ +127.996 ℃。而 AHT20 raw = 1048575 时 T = **+149.99 ℃**，
按 Q8.8 编码成 +38400 → **溢出成负数（0x95FF = −27137）** → 高温不触发应急。

`temp_centi_c`（0.01 ℃ 定点，16 位有符号）范围 −327.68 ~ +327.67 ℃，
AHT20 全量程 −40 ~ +150 ℃ 有 2.2 倍余量，且与未来 Plan B（`ntc_adc_ctrl`）的端口契约**完全一致**。

---

## 5. 三模式状态机（`mode_ctrl.v`）

| 项 | 实现 |
|---|---|
| 编码 | `M_DAILY = 2'd0` / `M_SCIENCE = 2'd1` / `M_EMERG = 2'd2` |
| Key2 循环 | 日常 ↔ 科普（应急下 Key2 被忽略） |
| Key3 进应急 | **零延迟直达**，任意模式有效 |
| Key3 退应急 | 双击确认，`CONFIRM_MS = 2000`（2 s 窗口内再按一次） |
| 温度进屋应急 | `thermal_guard.oth_en` 的**上升沿**（`temp_alarm & ~temp_alarm_d`） |
| 温度回落 | **不自动退出**。温度回落只解除"再次触发"条件，退出必须人工 Key3 双按 |
| 应急中温度再升 | 被忽略（已在应急态，不重复触发） |
| 退出后落点 | 强制回**日常**（不是回上一个模式） |

**为什么温度报警要取上升沿**：`thermal_guard` 输出的是电平（`oth_en` 保持），
若直接用电平做条件，每一拍都会重新触发一次进屋应急，`mode_changed` 脉冲会被淹掉。

**`emerg_src[1:0]`**：`SRC_NONE=0` / `SRC_KEY=1` / `SRC_TEMP=2`，供 OSD 显示"为什么进了应急"。

---

## 6. 应急钳位的实现方式（`key_router.v`）

应急模式下 Key4（音频）与 Key5（字幕）**锁 1**，但**不污染用户寄存器**：

```verilog
assign audio_en_eff  = emerg ? 1'b1 : audio_en;
assign ticker_en_eff = emerg ? 1'b1 : ticker_en;
```

`audio_en` / `ticker_en` 仍然忠实记录用户的选择（哪怕应急期间用户按了 Key4 试图关音频，
寄存器会被翻成 0，但 `_eff` 保持 1）。退出应急后自动恢复用户原值——不需要在任何地方做"备份/还原"。

**`ticker_en` 与 `viz_en` 是两个独立寄存器**，不是同一个信号的两个位。
这是硬要求：应急下需要表达「字幕锁开 + 可视化可关」这一组合，合并成一个 `osd_en` 就表达不出来。

应急下 Key7（音量）0/1/2 档→钳位到 3 档（13/32），理由：应急广播必须能被听见。

---

## 7. 验收数据汇总

### 7.1 lint（`python scripts\lint_verilog.py`）

```
$ python scripts\lint_verilog.py rtl
检查文件数: 58
E0(文件损坏): 0    E1(赋值混用): 0    E2(多驱动): 0
结论: 通过（无损坏 / 无混用赋值 / 无多驱动）
```

- **改造前基线：52 文件**；现在 **58 文件**（+6 个新模块），E0/E1/E2 三项全 0 保持不变。
- `rtl\sensor` 单独跑：3 文件 / E0=0 / E1=0 / E2=0 / 通过。

### 7.2 单元回归（`sim\scripts\run_unit_coverage_regression.ps1`）

```
& sim\scripts\run_unit_coverage_regression.ps1 -PrimLibPath 'D:\TD_6_24_APP\sim_release\eg4'
```

**24 个 case 全 passed=True / knownIssues=0 / exit code 0**。

新增 6 项实测断言数：

| case | passLines |
|---|---|
| `brightness_apply` | 27 |
| `mode_ctrl` | 48 |
| `key_router` | 30 |
| `i2c_master` | 23 |
| `aht20_ctrl` | 32 |
| `thermal_guard` | 23 |

既有 18 项全部无回归（`lane_lvds_10_1` 22 / `hdmi_phy` 66 / `video_rgb_to_axis` 54 /
`audio_arc` 41 / `video_timing_gen` 18 / `test_pattern_gen` 142 / `audio_waveform` 76 /
`audio_tone_gen` 46 / `pcm_to_pwm` 39 / `key_matrix_4x4` 50 / `ax_debounce` 31 /
`seg_decoder` 51 / `image_path_probe` 54 / `hdmi_pll` 13 / `sdram_pll` 13 /
`dmz_eg4s20_min_top` 51 / `science_font16` 49 / `sdram_frame_diag_top` 37）。

### 7.3 单独复跑命令（不含脚本，便于定位）

```powershell
$ms  = 'D:\Quartus_APP\modelsim_ase\win32aloem'
$root = 'D:\FPGA_Compelate\SmartCampusMedia'
$wd  = Join-Path $env:TEMP 'scm_aht20_tb'      # 每模块一个独立工作目录
Set-Location $wd
if (!(Test-Path 'work')) { & (Join-Path $ms 'vlib.exe') work }
& (Join-Path $ms 'vlog.exe') -quiet <rtl 文件> <tb 文件>
& (Join-Path $ms 'vsim.exe') -c -quiet -onfinish stop `
    -do 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0' `
    work.tb_xxx
```

**判据必须同时满足**：`exit=0` + 日志含 `ALL CHECKS PASSED: <name>` + 至少一行 `PASS:` +
无 `CHECKS FAILED|GLOBAL TIMEOUT|FAIL|TIMEOUT:|\*\* Error|Fatal`。

---

## 8. 调试中抓到的 5 个真 bug（lint 全查不出，值得写进答辩）

`lint_verilog.py` 只查 E0/E1/E2 三类**模式**，**不做语法解析**。
`lint` 全 0 **不等于**能编译，更不等于功能正确。以下 5 个全是靠 `vlog` + `vsim` 实际跑出来的。

### 8.1 `localparam` 逗号列表 → 语法错误 + 20 条假错误雪崩

Verilog-2001 的 `localparam` 是**独立语句**，逗号列表只允许出现在 module 参数表 `#(...)` 里。
写成 `localparam [4:0] S_A = 5'd0,` 逗号接续会被 ModelSim 拒绝，并连带报 20 条
`(vlog-2730) Undefined variable: 'S_CAL_START'` 之类的**假错误**（其实是第一条失败后的雪崩）。
排查时必须先修第一条，不要被后续 20 条带偏。

### 8.2 I2C ACK 极性接反（静默、最危险）

I2C 的 ACK 是**从机把 SDA 拉低**，所以 `sda_in = 0` 才是 ACK。
原实现 `wr_ack <= ack_bit;` 直接给线电平，导致「从机明明应答了、主机却报 NACK」。
**仿真不报错，上板表现是"传感器读不到数据"。** 正确写法 `wr_ack <= ~ack_bit;`。

### 8.3 CRC8 每字节少移 1 次

原写法「`crc_bit==0` 异或，1..7 移位，到 `crc_bit==8` 退出」= 每字节只移 **7** 次。
后果：本地 CRC 与芯片 CRC 永远不等 → 每轮都判 `ERR_CRC` → 温度永远不输出。
**不报错、不告警，常温下"看起来跑通了"。** 已改为 `crc_bit` 1..8 移位、到 `4'd9` 退出。

### 8.4 `retry_cnt` 无限重试

`S_TRG_START` 里无条件 `retry_cnt <= 2'd0`，而 `S_FAILED` 的分支是「`retry_cnt+1` → 回 `S_TRG_START`」，
于是每次重试都被清零 → 永远到不了 `RETRY_MAX` → **失败后无限重试永不放弃**。
现象：传感器没接时状态机在 `TRG_START…FAILED` 打转，`meas_tick` 一次都不来。

### 8.5 `err_code` 不清零 → 永久失败

`S_TRG_STOP` 判 `if (err_code != ERR_NONE) state <= S_FAILED;`，
而 `err_code` 一旦被某轮 NACK/CRC 置非零就**永久保持**，没有任何状态清它。
于是之后每轮哪怕 I2C 完全正常也照跳 `S_FAILED`，温度再也读不出、`sensor_fault` 再也清不掉。
**表现与"传感器一直坏"完全一样。** 修法：每轮开始（`S_TRG_START`）归零 `err_code`。

### 8.6 另一类：`i2c_wr_req` 连续写不断开的死锁

`i2c_master` 用**上升沿** `wr_pulse = wr_req & ~wr_req_d` 识别请求。
而 `aht20_ctrl` 在 `S_TRG_WR0→WR1→WR2→WR3` 连续四个写状态里都写 `i2c_wr_req <= 1'b1`，
req 全程保持高电平 → master 只发第一个字节，后面三个永远等不到新的上升沿 → **死锁**。

**单字节场景（读状态、软复位）恰好掩盖了它**，所以这个 bug 在写完模块时完全看不出来。
修法：`i2c_wr_req <= 1'b1;` → `if (!i2c_wr_done) i2c_wr_req <= 1'b1;`，让 done 那拍不置位，
下一拍清零，形成新的 0→1 上升沿。

**教训：多字节连续事务必须检查"请求信号有没有断开"。单字节能跑通会给出虚假信心。**

---

## 9. 留给 t8 集成的事项

| 事项 | 说明 |
|---|---|
| 顶层例化 | 删除顶层 `u_kact`（`key_action`）与 `u_ctrl`（`player_ctrl`）两个旧实例，`key_router` 成为唯一键消费者 |
| 亮度接线 | `bright_lvl[3:0]` → `brightness_apply.bright_lvl`；`bright_lvl[2:0]` → `video_overlay.bright_sel` |
| 温度链路 | `aht20_ctrl.temp_centi_c/temp_valid` → `thermal_guard` → `mode_ctrl.temp_alarm` |
| OSD 故障提示 | `sensor_fault` 目前只置信号、无用户可见反馈，需接 OSD 或 `err_prompt` |
| `video_overlay.v` 过时注释 | 3 处（t13 已定位）随集成一并修 |
| 复位极性 | 全部新模块统一 `rst_n` 低有效，与既有模块一致 |

---

## 10. 本文档的自我限定

- 所有断言数、lint 计数、黄金向量输出均为**本机实跑结果**，未做任何估算或推测。
- 温度换算表的每一行都可用 `raw × 1250 >> 16 − 5000` 手工复算验证。
- 数据手册引文出自 `D:\date sheet\AHT20.pdf`（ASAIR，2024 年 7 月版，15 页），
  全文抽取件在 `D:\FPGA_Compelate\_guide\aht20.txt`。
- 本文**不覆盖** t6（音频）/ t7（视频与几何映射）/ t8（顶层集成）的内容。
