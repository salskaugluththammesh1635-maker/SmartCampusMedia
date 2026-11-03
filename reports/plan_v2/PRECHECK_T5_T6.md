# t5 / t6 已落盘 RTL 口径偏差预检（只读）

- 预检人：spec-auditor（赛规核对官）
- 预检时间：2026-11-01 22:05 ~ 22:20
- 任务：t13，attempt_id `f658a5fe-1814-438a-8c46-e47357b1af7e`
- 判定标尺：`docs/plan_v2/` 四份定稿（PLAN.md / ARCH.md / KEYMAP.md / RESOURCE_BUDGET.md）**原文**，不采信任何转述；另加 captain 追加判据⑫⑬⑭（赛规与用户原话为标尺）。

## 0. 结论汇总

| # | 判据 | 结论 |
|---|---|---|
| 1 | 亮度链路纯组合零寄存器 | ✅ 符合 |
| 2 | 亮度档位方向（0=最亮） | ✅ 符合 |
| 3 | 音量档位方向（0=最轻，与亮度相反） | ⏳ 未落盘 |
| 4 | `bright_sel` 保留且接 `bright_lvl[2:0]` | ⚠️ 可疑（端口与接法正确，但模块内 3 处注释仍是改造前口径） |
| 5 | 温度输出契约 `temp_centi_c` | ✅ 符合 |
| 6 | 迟滞方向（≥45 触发 / ≤40 解除） | ✅ 符合 |
| 7 | 传感器故障不触发应急 | ⚠️ 可疑（语义正确，但 `sensor_fault` 无人消费，OSD 无法显示故障） |
| 8 | Key5 字幕 / Key10 可视化 两个独立寄存器 | ✅ 符合 |
| 9 | 复位值（亮度 0 / 音量 6 / 字幕 1 / 可视化 1） | ✅ 符合 |
| 10 | 应急锁存（仅 Key3 双按退出） | ✅ 符合 |
| 11 | 一键一模块（新模块之间无重叠） | ✅ 符合（但顶层旧模块未移除，见 §13） |
| ⑫ | 应急画面 = 整屏纯红 | ⚠️ **需求缺口**（非 RTL 擅改，ARCH/PLAN 原文即如此） |
| ⑬ | 科普模式 = 静态 `science_page` vs 定稿 RLE 视频 | ⏳ **待裁**（t16 由 architect 裁定） |
| ⑭ | 屏占比作用域仅图片路 vs KEYMAP 三模式全有效 | ⚠️ **需求缺口**（与用户原话不符） |

统计：✅ 7 条，⚠️ 4 条（判据 4、7、⑫、⑭），⏳ 2 条（判据 3、⑬），❌ 0 条。

> **没有 ❌**：t5 已落盘的 RTL 在「与 `docs/plan_v2` 定稿一致性」这一维度上没有写错的地方。所有 ⚠️ 都属「定稿本身与用户需求/赛规的距离」或「接口未接通、属 t8 集成范围」，不是 rtl-engineer 擅改。

## 1. 被检文件清单（实测字节数 + 时间戳）

| 文件 | 字节数 | 最后修改 |
|---|---|---|
| `rtl/control/key_router.v` | 17,691 | 2026-11-01 21:45:28 |
| `rtl/control/mode_ctrl.v` | 14,128 | 2026-11-01 21:42:10 |
| `rtl/video/brightness_apply.v` | 8,632 | 2026-11-01 21:44:44 |
| `rtl/video/video_overlay.v` | 18,591 | 2026-11-01 21:45:03 |
| `rtl/video/video_content_mux.v` | 1,642 | 2026-10-30 00:03 |
| `rtl/video/image_window_mask.v` | 2,460 | 2026-10-30 00:08 |
| `rtl/video/science_page.v` | 13,601 | — |
| `rtl/video/science_font16.v` | 26,227 | — |
| `rtl/sensor/i2c_master.v` | 21,948 | 2026-11-01 21:21:17 |
| `rtl/sensor/aht20_ctrl.v` | 36,191 | 2026-11-01 22:09:59 |
| `rtl/sensor/thermal_guard.v` | 11,238 | 2026-11-01 21:13:08 |
| `rtl/storage/image_player.v` | 26,033 | 2026-11-01 20:21:55 |
| `rtl/storage/img_scaler.v` | 27,563 | 2026-10-30 10:07 |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | 40,676 | 2026-10-31 16:55 |
| `rtl/control/err_prompt.v` | 20,666 | 2026-10-31 16:55 |
| `constraints/dmz_eg4s20_hdmi.adc` | 10,166 | 2026-11-01 21:51:06 |
| `reports/watchdog_20261030/area.txt` | 24,544 | 2026-10-30 22:50 |

未落盘（⏳，t6/t7 尚未开工）：`media_player.v`、`vol_apply.v`、`video_geom_map.v`、`rle_decoder.v`、`sar_adc_wrap.v`、`sar_ntc_ctrl.v`、`audio_src_mux.v`、`wav_stream_player.v` —— 逐个 `Get-ChildItem -Recurse -Filter` 全 RTL 树均无命中。

---

## 2. 判据 1 —— 亮度链路纯组合零寄存器 ✅ 符合

**定稿依据**：`docs/plan_v2/ARCH.md:928-980`（§9.3 端口契约：5 输入→2 输出，`assign de_out = de`、`assign rgb_out = de ? {...} : 24'd0`，明确「不做打拍」）；`RESOURCE_BUDGET.md:125`（REG +24 → 0）。

**实测** `rtl/video/brightness_apply.v`（131 行）：

```verilog
L126:     assign de_out  = de;
L127:     assign rgb_out = de ? { brt10(r_in, bright_lvl),
L128:                            brt10(g_in, bright_lvl),
L129:                            brt10(b_in, bright_lvl) } : 24'd0;
```

- 零寄存器、零 `always @(posedge clk)` 数据通路，与定稿完全一致。
- 文件头 `L33-44` 自行论证了「打拍只延 `de`/`rgb` 没延 `active_x`/`active_y` → 下游 `osd_panel` 用坐标定位，面板会整体右移/下移一像素」——这正是定稿给出的第一条理由，实现者理解到位。
- 中间量用 9 位 `reg [8:0] y` + 饱和 `brt10 = y[8] ? 8'hFF : y[7:0]`，防改表后 8 位静默回绕；**零 DSP 零乘法器**（本工程 DSP 余量只剩 10/29），符合 `RESOURCE_BUDGET.md` 预算。

**结论**：✅ 符合，无需改。

## 3. 判据 2 —— 亮度档位方向（0 = 最亮 32/32）✅ 符合

**定稿依据**：`ARCH.md:945-960`（`brt10` case 反序）；`KEYMAP.md:302-317`（§9.1 标题「0 = 最亮（100%），9 = 最暗（9.4%）」+ 方向约定块）；`KEYMAP.md:237`（`bright_lvl` 复位由 9 改 0）；`PLAN.md:305-330`。历史依据：改造前 `video_overlay.v:108` 是 `bright_sel == 3'd0 ? r_in`，即 0 = 直通 = 最亮。

**实测** `brightness_apply.v`：

```verilog
L104:         case (bright_lvl)
L105:             4'd0: y = {1'b0, x};                                    // 32/32 = 100%
   ...
L114:             default: y = {1'b0,(x>>4)} + {2'b00,(x>>5)};             // 3/32 = 9.4%
L115:         endcase
```

十档表 `x = 255` 列实测：**255 > 233 > 209 > 185 > 161 > 127 > 105 > 78 > 46 > 22** 严格递减，档 0 最亮、档 9 最暗，与 `PLAN.md:332-334` 的三点验收值（档 0→255、档 5→127、档 9→23）逐点吻合。

**结论**：✅ 符合，无需改。

## 4. 判据 3 —— 音量档位方向（0 = 最轻，与亮度相反）⏳ 未落盘

`rtl/audio/vol_apply.v` 全树搜索无命中，t6 尚未开工，按契约**标 ⏳ 未落盘，不报 ❌**。

**给 t6 的提示（不计入本轮判定）**：`ARCH.md:671-680` 的 `vol_apply` case 方向**本来就是对的**（`4'd0: 3/32` … `default: 32/32`），与亮度表正好相反。`PLAN.md:347`、`KEYMAP.md:321-336` 都警告过「两模块不得共用同一 case 函数」。若 t6 抄了 `brightness_apply.v` 的 case，方向会反 → 按 Key7 到档 0 输出 1.000 增益（放大 10.67 倍），答辩现场灾难。`PLAN.md:351-361` 已备 `tb_volume_direction.v` 两行相邻断言，建议 t6 一并落地。

## 5. 判据 4 —— `bright_sel` 保留且接 `bright_lvl[2:0]` ⚠️ 可疑（注释过时）

**定稿依据**：`ARCH.md:1008`（§10 第 23 行「不得恒接 3'd0」）、`ARCH.md:103-111`、`KEYMAP.md:149-153`（§4.3 警告块）。定稿理由：`u_overlay` 内部 5 档衰减已移除防二次衰减，`bright_sel` 改为只作信息条第 8/9/10 格显示。

**实测** `rtl/video/video_overlay.v`：

正确部分（✅）：

```verilog
L133:     wire [7:0] r_brt = r_in;        // v2: 直通（亮度已移至 brightness_apply.v）
L134:     wire [7:0] g_brt = g_in;
L135:     wire [7:0] b_brt = b_in;
L80:      input  wire [2:0] bright_sel,   // v2: 仅用于信息条亮度格显示（接 bright_lvl[2:0]），亮度数据通路已移至 brightness_apply.v
L224:         4'd7 : box_lit = bright_sel[0];
L225:         4'd8 : box_lit = bright_sel[1];
L226:         4'd9 : box_lit = bright_sel[2];
```

- 端口保留 ✅、内部衰减已删 ✅、`box_lit` 三格接线 ✅，全部符合定稿。

**⚠️ 偏差（3 处过时注释，描述改造前行为）**：

| 行号 | 实际文本 | 问题 |
|---|---|---|
| `video_overlay.v:16` | `//   KEY7   bright_sel  图像层              5 档亮度（100/87.5/75/62.5/50%）` | 5 档已被 10 档取代，且数据通路已移出本模块 |
| `video_overlay.v:34` | `//     原始像素 → 亮度缩放 → 反色 → 叠加 OSD → 输出` | 处理顺序里仍含「亮度缩放」，实际已直通 |
| `video_overlay.v:61` | `//          7..9  = bright_sel[2:0]  （亮度档 0..4）` | 档位是 0..9 十档，不是 0..4 五档 |

**风险等级**：低。纯注释、不影响综合与仿真，但会误导 t8 集成者与 t10 终审者，且文件头 `L114-115` 明明已写对（「位置在本模块下游、osd_panel 上游」），前后自相矛盾。

**建议改法**（由 rtl-engineer 在 t8 顺手改，spec-auditor 不改文件）：
- `:16` → 改为 `//   KEY6   bright_sel  信息条亮度格        仅显示，数据通路见 brightness_apply.v`
- `:34` → 删「亮度缩放」环节，或加注 `（v2 亮度已移出本模块）`
- `:61` → 改为 `（亮度档 0..9，v2 仅列表显示）`

## 6. 判据 5 —— 温度输出契约 `temp_centi_c` ✅ 符合

**定稿依据**：captain m00549 / m00562 裁决 + `reports/plan_v2/PLAN_B_NTC_ADC.md` §4.3（本仓库权威口径）。单位 0.01 ℃、`signed [15:0]`、25.00 ℃ = `16'sd2500`。

**实测** `rtl/sensor/aht20_ctrl.v`（36,191 B / 711 行）：

```verilog
L125:     output reg  signed [15:0] temp_centi_c,   // 温度，单位 0.01 ℃
L126:     output reg         temp_valid,            // 单拍：本拍 temp_centi_c 有效
L221:     // raw × 1250 = (raw<<10) + (raw<<7) + (raw<<6) + (raw<<5) + (raw<<1)
L225:     wire [30:0] t_mul = ({11'd0, t_raw} << 10)
L239:     wire signed [15:0] t_centi_comb = $signed({1'b0, t_mul[30:16]}) - 16'sd5000;
L655:             temp_centi_c <= t_centi_comb;
```

- 单位、符号、位宽全部正确 ✅。
- **换算实现比 t12 文档方案更稳**：用 `raw × 1250 >> 16` 而非 `raw × 625 >> 15`。文件头 `L56` 记载 `20000 / 1048576 = 1250 / 65536（精确相等，不是近似！）`，`L68` 记载 `raw 最大 1048575，× 1250 = 1,310,718,750 < 2^31 → 31 位够`。两者数学等价（`1250/65536 = 625/32768`），但 `>>16` 的中间位宽到 31 位，比 30 位多 1 位余量，抗错改能力更强。
- 湿度另用 `h_mul [29:0]` = `raw × 625`、`h_centi_comb = h_mul[29:16]`，同样精确。
- **全树搜 `temp_q8_8` / `16'sh2D00`：0 命中** ✅ 没有被否决的旧格式残留。

**结论**：✅ 符合，无需改。

## 7. 判据 6 —— 迟滞方向（≥45.00 ℃ 触发 / ≤40.00 ℃ 解除）✅ 符合

**定稿依据**：`PLAN_B_NTC_ADC.md` §4.4、`AHT20_COMPLIANCE_PACK.md` §4；captain 指定 `TH_HIGH = 16'sd4500` / `TH_LOW = 16'sd4000`。

**实测** `rtl/sensor/thermal_guard.v`（173 行）：

```verilog
L90:  parameter signed [15:0] TH_HIGH = 16'sd4500,  // 45.00 ℃ 及以上 → 进入高温
L91:  parameter signed [15:0] TH_LOW  = 16'sd4000,  // 40.00 ℃ 及以下 → 退出高温
L120: wire signed [15:0] temp_s = temp_centi_c;
L122: wire enter_hit = temp_valid && !oth_en && (temp_s >= TH_HIGH);
L123: wire exit_hit  = temp_valid &&  oth_en && (temp_s <= TH_LOW);
```

- 方向正确（进入用 `>=`，退出用 `<=`，迟滞带 5.00 ℃）✅。
- `L115-118` 显式记载了 `$signed` 的必要性：「负温度（-40 ℃ = 0xF060）按无符号是 61536 会被误判为极高温度」——这正是 `temp_centi_c` 采用补码后最容易踩的坑，实现者已规避。
- 迟滞带宽裕度：5 ℃ ÷ 0.58 ℃（RSS 误差）= **8.6 倍误差预算**，不会因量化抖动反复进出。

**结论**：✅ 符合，无需改。

## 8. 判据 7 —— 传感器故障不触发应急 ⚠️ 可疑（语义对、接口断链）

**定稿依据**：`AHT20_COMPLIANCE_PACK.md` §4 与 `PLAN_B_NTC_ADC.md` §3.7「故障只置 `sensor_fault`，应急模式靠 Key3 手动直达兜底」；captain 明确「不要因传感器故障导致设备自己切模式」。

**实测** `thermal_guard.v`：

- **语义正确** ✅：模块**根本没有** `sensor_fault` 输入端口；失联时（`L154-160`）只把 `temp_alive <= 1'b0`，`oth_en` **保持不变**。文件头 `L77-80` 写明「宁可维持现状让人工处理，也不要因传感器故障导致设备自己切模式」。
- **⚠️ 接口断链**：`aht20_ctrl.v` 输出了 `sensor_fault`(L143)、`meas_tick`(L144)、`humid_centi`/`humid_valid`(L127-128)、`cal_ok`/`sensor_ok`/`err_code`/`busy`(L131-134)，但 `thermal_guard.v` 只吃 `temp_centi_c` + `temp_valid`，**不接 `sensor_fault`、不接 `meas_tick`**，改用自有 `STALE_CYCLES = 50_000_000`（25 MHz 下 2 秒）计数器判存活。

**后果**：
1. `aht20_ctrl.sensor_fault` 无人消费 → OSD 无法显示「传感器异常」，评委演示时若 AHT20 掉线，屏幕上什么都看不出来，只有「温度不再变化」这一隐性现象。
2. `meas_tick` 无人消费 → 与 `temp_valid` 语义冗余，可视为设计冗余（不构成错误）。

**风险等级**：中。属功能可观测性缺口，不影响安全逻辑本身（故障时不会误切应急，这是对的），但演示时若传感器异常无法自证。

**建议改法**（t8 顶层，由 rtl-engineer 执行）：
- 最小改动：把 `aht20_ctrl.sensor_fault` 接到 `osd_panel` 的一个告警格，或接到 `err_prompt`（该模块已有 5 类用户动作助记，加一类 `S = Sensor` 即可）。
- 备选改动：给 `thermal_guard` 增 `sensor_fault` 输入，只在失联时与 `temp_alive` 一起拉告警位，**仍不改变 `oth_en`**（保持「故障不切模式」的定稿语义）。

## 9. 判据 8 —— Key5 字幕 / Key10 可视化 两个独立寄存器 ✅ 符合

**定稿依据**：`KEYMAP.md` §5 作用域矩阵（Key5 应急「锁 1」、Key10 应急「✓ 允许关闭」）；`key_router.v` 文件头 `L53-62` 记录禁令。

**实测** `rtl/control/key_router.v`：

```verilog
L93:      output reg         ticker_en,       // 复位 1
L94:      output reg         viz_en,          // 复位 1
L195-201: K_TICKER 分支 → 只有 ticker_en <= ~ticker_en;
L256-260: K_VIZ    分支 → 只有 viz_en    <= ~viz_en;
L307:     assign audio_en_eff  = emerg ? 1'b1 : audio_en;
L308:     assign ticker_en_eff = emerg ? 1'b1 : ticker_en;
```

- 两个独立寄存器 ✅；应急强制开通过 `*_eff` 派生信号实现，**不污染**用户寄存器（退出应急后恢复用户原值）——比直接改写寄存器更正确。
- 文件头 `L53-62` 专列禁令与理由：若合并成一个寄存器，「应急强制开字幕 + 波形允许关」这一组合**无法表达**。与 `KEYMAP.md:181-182`（Key4/Key5 应急锁 1）和 `:187`（Key10 应急 ✓）三方一致 ✅。

**结论**：✅ 符合，无需改。

## 10. 判据 9 —— 复位值 ✅ 符合

**定稿依据**：`KEYMAP.md:237-243`（`bright_lvl` 复位 0 / `vol_lvl` 复位 6 / `audio_en`/`ticker_en`/`viz_en` 复位 1 / 四个档位 `SEL5_MAX` = 4）；`PLAN.md:804`（M4 上板清单第 19 项）。

**实测** `key_router.v`：

```verilog
L155:             bright_lvl <= 4'd0;      // 0 = 最亮 32/32
L156:             vol_lvl    <= 4'd6;      // 约 50%
L157:             res_sel    <= SEL5_MAX;  // 复位 640×480 原生档
L158:             ratio_sel  <= SEL5_MAX;  // 复位满屏
L160:             ticker_en  <= 1'b1;
L161:             viz_en     <= 1'b1;
```

逐项与定稿一致 ✅（`audio_en` 复位 1 见 `L159`）。

**结论**：✅ 符合，无需改。

## 11. 判据 10 —— 应急锁存（仅 Key3 双按退出）✅ 符合

**定稿依据**：`ARCH.md` §2.2 状态转移表；`KEYMAP.md:177-180`（Key0/1/2 应急 ✗、Key3「✓（确认退出）」唯一全状态有效）；`mode_ctrl.v` 文件头 `L32-37`、`L56-60`。

**实测** `rtl/control/mode_ctrl.v`（257 行）：

```verilog
L215-235:  M_EMERG 分支只有 key_event && (key_code == K_EMERG) 一个入口
           if (confirm_armed) → 退出回 M_DAILY，清 emerg_latched
           else               → confirm_armed <= 1'b1; confirm_cnt <= 32'd0;
L232-234:  // Key2 与温度变化在此分支被有意忽略
L149-158:  确认窗口（CONFIRM_MS = 2000）超时自动解除武装
L218-224:  退出强制回 M_DAILY（非科普）
```

- 唯一出口 = Key3 双按 ✅；Key2 与温度回落均不能退出 ✅；`temp_alarm` 只在 DAILY/SCIENCE 用**上升沿**触发进入（`L120` `wire temp_alarm_rise = temp_alarm & ~temp_alarm_d;`，`L179`/`L203`），应急态内不复触发 ✅。
- 退出回 `M_DAILY` 而非 `M_SCIENCE` 有明文理由（`L56-60` 决策 3）：回科普需重新从 SD 装载视频，会有数秒黑屏——**在应急解除的场合这是正确的产品判断** ✅。

**结论**：✅ 符合，无需改。

## 12. 判据 11 —— 一键一模块（新模块之间无重叠）✅ 符合

**实测**：
- `mode_ctrl.v:109-110` 只认 `K_MODE = 4'd2` / `K_EMERG = 4'd3`。
- `key_router.v:116-127` 认 Key4~Key15（`K_AUDIO = 4'd4` … `K_BEEP = 4'd15`），`L294-296` `default: begin // 有意留空：不是本模块的键，不做任何动作。 end`。
- Key0/Key1 归 `media_player`（尚未落盘），`key_router.v:28-30` 分工清单写明。

**新模块之间：无重叠 ✅**。

**⚠️ 但顶层存在旧模块，构成真实冲突风险（属 t8 范围，非 t5 错误）**，见 §13。

## 13. 顶层集成必须处理的 3 处旧模块冲突（⏳ t8 范围）

**实际测量** `rtl/top/dmz_eg4s20_hdmi_top.v`（40,676 B / 2026-10-31 16:55）：

| 位置 | 现状 | 与新模块的冲突 |
|---|---|---|
| `:101` | `key_action u_kact (` | `rtl/control/key_action.v:86` `K_BRIGHT = 4'd7` vs `key_router.v:118` `K_BRIGHT = 4'd6` |
| `:116` | `player_ctrl #(.CLK_FREQ_HZ(25_000_000)) u_ctrl (` | `rtl/control/player_ctrl.v:223` `K_MODE = 4'd3` vs `mode_ctrl.v:109` `K_MODE = 4'd2`；`:224` `K_EMERG = 4'd15` vs `mode_ctrl.v:110` `K_EMERG = 4'd3` |
| `:84-85` | `key_code == 4/5` 直连 `pattern_sel` | 与 `key_router.v:116` `K_AUDIO = 4'd4` / `:117` `K_TICKER = 4'd5` 抢同一 key_code |
| `:402` | `key_code == 6` 直控 `audio_muted` | 与 `key_router.v:118` `K_BRIGHT = 4'd6` 抢同一 key_code |

**后果**：若 t8 忘记移除旧实例，同一 `key_code` 会被两个模块消费——正是 `key_router.v:32-35` 记载的历史事故形态（KEY0/KEY1 曾被播放控制与图案选择器争用，表现为「按一下切两张图」）。

**建议**：t8 顶层删除 `u_kact`、`u_ctrl` 两个实例，并把 `:84-85`、`:402` 两处 `key_code ==` 直连逻辑改为消费 `key_router` 的输出（`pattern_sel`、`bright_lvl`/`audio_en`）。

**另**：`brightness_apply` / `key_router` / `mode_ctrl` / `thermal_guard` / `aht20_ctrl` / `i2c_master` **均未被顶层例化**（全树搜模块名，除自述与注释外无实例化命中）→ 属 t8 集成范围，标 ⏳。

## 14. 判据 ⑫ —— 应急画面 = 整屏纯红 ⚠️ 需求缺口

**实测** `rtl/video/video_content_mux.v:18`：

```verilog
2'd2: rgb_out = 24'hFF_00_00;
```

**判定：⚠️ 需求缺口，不是 RTL 错误。** `docs/plan_v2/ARCH.md:155` 写「应急发布 | 红色警报画面（`24'hFF_00_00`）+ 大字提示」，`PLAN.md:126` 写「红色警报画面 + 大字提示」——RTL 与定稿**完全一致**，是「一致的错」，非 rtl-engineer 擅改。

**与用户原话的距离**：用户 m00001「图层上显示**最近的消防通道**」。纯红屏给不出任何空间信息。

**从赛规角度是否构成评分风险（本预检的独立判断）**：

- 赛规 P14 §1.2（`guide.txt` L529）把「应急信息发布」列为赛题**应用场景举例** —— 这是选题价值的背书，不是功能条款；赛规全文搜 `应急|消防|疏散|安全` **仅此 1 处命中**，无任何安全功能明文要求。
- 赛规 P15 §1.5 一、基础要求（`guide.txt` L569-573）第一项是「**（1）核心功能完整性**」。用户需求是参赛作品的「完整性」标尺：缺了「消防通道」这一条，三模式里的应急模式就只剩「变红 + 大字」，与普通告警器无差别。
- **结论：构成评分风险，但落在「核心功能完整性」，不在任何安全条款。** 风险等级 **中偏高** —— 因为三模式是用户需求的主骨架，应急模式是三模式里唯一有「外部可验证价值」的一环，做得最薄。
- 补充：`ARCH.md:155`/`PLAN.md:126` 的「字幕源 = 消防通道提示（锁定，不可关）」表明设计者**已经意识到**要在字幕层给通道路线文字，但底层画面（纯红）没有空间信息，文字与画面脱节。

**建议**：见 `reports/plan_v2/EMERG_SCREEN_RULING.md`（t15 产出，已随本预检同批交付）——结论是「必须补平面示意图」，并给出 `emerg_page.v` 的合规论证与答辩口径。

**建议改 ARCH/PLAN 措辞（由 captain/architect 执行，本预检不改）**：
- `ARCH.md:155` → 画面源改为「应急平面示意图（`emerg_page`，FPGA 内实时栅格化）+ 大字提示」，并同步 `§6.5` 补 `emerg_page` 端口契约。
- `PLAN.md:126` → 同上。

## 15. 判据 ⑬ —— 科普模式：静态 `science_page` vs 定稿 RLE 视频 ⏳ 待裁定

**实测** `video_content_mux.v:19`：`2'd1: rgb_out = science_rgb;` → 接 `rtl/video/science_page.v`（静态 FPGA 原理科普页）。

**定稿** `ARCH.md:154`：「`2'd1` | `S_SCIENCE` | 科普展示 | SD RLE 视频序列帧（`rle_decoder`）」。

**缺口**：`rle_decoder` 在 `ARCH.md:89-101` 的像素源框图里**不存在**；只有 §6.5 的端口契约，且输出全是 SDRAM **写**（`wr_req/wr_addr/wr_data/wr_dm/wr_en`）——「写进 SDRAM 之后由谁读出、接 mux 哪一路」，ARCH 未写。

**判定：⏳ 待裁，本预检不下结论。** 理由：captain m00965 明确要求「遇到这条就标 ⏳待裁定，不要自己下结论」，已派 architect 做 t16。若 spec-auditor 与 architect 各给一个答案，会污染 t8 集成输入。

**给 t16 的三点硬约束（作为输入，不构成裁定）**：
1. 用户已裁决「科普模式 = RLE 视频帧序列」（captain m00982 裁决 B），静态 `science_page.v` 不再是科普模式正常内容。
2. `assets/v2/sdcard/BURN640/SCI.RLE` 已存在（82,362,927 B，`MANIFEST.TXT` 记 `SCMR RGB565 frames=631 fps=5`），素材侧已就绪。
3. 视频走 SDRAM 帧缓存，而 `image_player` 已占 `MEM_WORDS = 262_144`（`image_player.v:13`，即 1 MB 双缓冲）。视频与图库若共用同一 SDRAM 区域需明确仲裁；若分区域，需给出 `video_geom_map` / `img_scaler` 基址不冲突的证据。

## 16. 判据 ⑭ —— 屏占比作用域 ⚠️ 需求缺口（精确落点已给出）

**矛盾三方**：
- `ARCH.md:903`：「`u_image_mask` … 屏占比裁剪，**仅图片路**」；`:897`：「只门控图片路的 `pixel_valid`」。
- `KEYMAP.md:186`：「| Key9 屏占比 | ✓ | ✓ | ✓ | 纯视觉参数，无安全影响 |」——三模式全有效。
- 用户 m00001：「Key9 是切换屏幕大小（1/2 到 1 分 5 档）」——**没区分图片和视频**。

**精确落点（captain 明确要求的行号）**：

`res_sel` / `ratio_sel` 在**全 RTL 树中只出现在 `rtl/control/key_router.v` 一个文件**，无任何消费者：

| 文件:行号 | 内容 |
|---|---|
| `key_router.v:15` | `//     Key8  ──► res_sel     内部渲染分辨率 5 档` |
| `key_router.v:16` | `//     Key9  ──► ratio_sel   屏占比 5 档` |
| `key_router.v:90` | `output reg  [2:0]  res_sel,         // 0~4，复位 4（640×480 原生）` |
| `key_router.v:91` | `output reg  [2:0]  ratio_sel,       // 0~4，复位 4（满屏）` |
| `key_router.v:157-158` | 复位赋值 `res_sel <= SEL5_MAX; ratio_sel <= SEL5_MAX;` |
| `key_router.v:237-238` | `res_sel <= (res_sel >= SEL5_MAX) ? 3'd0 : (res_sel + 3'd1);` |
| `key_router.v:247-248` | `ratio_sel <= (ratio_sel >= SEL5_MAX) ? 3'd0 : (ratio_sel + 3'd1);` |

**结构证据（为什么当前必然只作用于图片路）**：
- `rtl/video/image_window_mask.v`（2,460 B）端口只有 `de / active_x / active_y / win_w / win_h / win_off_x / win_off_y / pixel_valid → pixel_valid_out`，是 43 行纯组合门控，**结构上无法**影响非图片路。
- 顶层 `dmz_eg4s20_hdmi_top.v:273-276` 把 `.win_w(image_out_w)` 等接到 `image_player` 的 `out_w/out_h/out_off_*`（`:248`），而 `image_player.v:377-380` `assign out_w = display_w;`，`display_w` 由 `img_scaler` 的 `scale_w` 打拍而来（`L374`、`L207-210`/`L218-221`）。**`image_player.v` 内没有任何 `ratio_sel`/`res_sel` 输入端口**（L20-L46 端口表已逐条核对）。
- 即：Key8/Key9 目前**按下去没有任何画面变化**，连图片路都没有接上（`ratio_sel` 尚无消费者）。

**判定：⚠️ 需求缺口，且是双重缺口**：
1. **接线缺口**（t7/t8 范围）：`ratio_sel`/`res_sel` 尚未接到任何模块，键是「空键」。
2. **作用域缺口**（t16 裁定范围）：即使按 `ARCH.md:903` 接法接到 `image_window_mask`，科普模式（视频路）按 Key9 仍无反应，与 `KEYMAP.md:186` 的「✓✓✓」和用户原话不符。

**与用户需求谁一致**：`KEYMAP.md:186`（三模式全有效）与用户原话一致；`ARCH.md:903`（仅图片路）与用户原话不一致。**但注意**：屏占比作用于视频路在实现上不是免费的——`image_window_mask` 只能门控 `pixel_valid`，要让视频路也进窗口，必须把窗口逻辑上提到 `content_mux` **之前**并对三路源统一门控，或加一级统一的窗口 mask（约 40~60 LUT）。这是 t16 需要权衡的成本。

**风险等级**：中。Key9 是用户 10 个键里明确点名的一个，且答辩必演示。

**建议**（供 t16 参考，不构成裁定）：优先满足用户原话——把 `image_window_mask` 从「图片路专用」升级为「统一输出窗口」，位置在 `content_mux` 之后、`overlay` 之前，只门控内容层（图片/科普/应急三路），**不裁 OSD**。这样 Key9 三模式全有效，且不破坏「OSD 必须始终可读」这条 E4 硬约束。

---

## 17. 附：本轮顺带核实且结论为「符合」的两项 `i2c_master.v` 检查

| 项 | 实测 | 判定 |
|---|---|---|
| 端口签名 | `L77-104`：`start_req/start_done/stop_req/stop_done/wr_req/wr_data/wr_done/wr_ack/rd_req/rd_nack/rd_done/rd_data/scl_oe/sda_oe/sda_in/busy` | ✅ 与 `aht20_ctrl.v:111-122` 的原语接口**逐个对应**，可直接对接 |
| 速率 | `L78-79` `CLK_FREQ_HZ=25_000_000` / `SCL_FREQ_HZ=100_000`；`L111-112` `QUARTER = ceil(25e6/(100e3*4)) = 63` → 实测 SCL = 25e6/(4*63) = **99.2 kHz** | ✅ 未超 AHT20 标准模式 100 kHz，且文件头 `L63-66` 说明了「为什么用向上取整（向下取整会超标准）」 |

**另**：`constraints/dmz_eg4s20_hdmi.adc` 已新增 I2C 约束（`:130-131`）`set_pin_assignment { i2c_scl } { LOCATION = D1; ... PULLTYPE = PULLUP; }` / `{ i2c_sda } { LOCATION = E1; ... PULLTYPE = PULLUP; }` —— 与 t12 定稿一致 ✅，且 `PULLUP` 符合 `i2c_master.v:55` 的硬要求（否则总线读不到高）。**Plan B（片内 ADC）的 CH1 = M10 约束尚未加入，属 t8/t7 范围 ⏳。**

---

## 18. 待办汇总（按责任方）

| 责任方 | 事项 | 来源 |
|---|---|---|
| rtl-engineer（t8） | 删除顶层 `u_kact`、`u_ctrl` 两个旧实例；改接 `:84-85`/`:402` 的 `key_code ==` 直连 | §13 |
| rtl-engineer（t8） | 把 `sensor_fault` 接到 OSD 或 `err_prompt` | §8 |
| rtl-engineer（t8） | 顺手修 `video_overlay.v` 3 处过时注释 | §5 |
| rtl-engineer（t7/t8） | `ratio_sel`/`res_sel` 接上消费者；Plan B `adc_ch1 = M10` 约束 | §16 |
| rtl-engineer（t6） | `vol_apply` 方向必须与 brightness **相反**，落 `tb_volume_direction.v` | §4 |
| architect（t16） | 裁定判据⑬（科普视频通路接入点）与判据⑭（屏占比作用域） | §15、§16 |
| captain / architect | 改 `ARCH.md:155` + `PLAN.md:126` 应急画面措辞 | §14 |
| captain | 决定判据⑫的补做方案（见 `EMERG_SCREEN_RULING.md`） | §14 |

---

## 19. 只读声明

本预检为只读，未修改任何文件。未对 `.v` / `.adc` / `.sdc` / `.tcl` 执行任何写操作，未修改 `docs/plan_v2/` 四份定稿，未创建除本文件以外的任何文件。所有引用均来自上表 §1 所列文件的实际读取（含行号、字节数、时间戳），未采信任何转述。
