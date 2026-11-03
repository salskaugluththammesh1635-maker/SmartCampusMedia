# T7 顶层集成规格书（t7-A / t7-B）

> 编写：rtl-integ　日期：2026-11-02
> 依据：`rtl/top/dmz_eg4s20_hdmi_top.v`（616 行 / 40,676 B，mtime 2026-10-31 16:55:31）、
> `docs/plan_v2/` 现有 12 份文档、以及本轮逐文件实测的端口表。
> **本文档所有端口名、位宽、行号均为实测，不是 ARCH 记忆**。凡与 `ARCH.md` 原稿冲突处，
> 一律以本文档为准并在 §2.9 列出差异（照 ARCH 原稿写例化会编译不过）。

---

## 0. 本文档要解决的问题

t7 的目标是把 14 个新模块接进顶层。但**接线本身不是风险** —— 接错了综合器会报错，
仿真会红。真正的风险是三类**不报错、位流照出、报告全绿、功能静默缺失**的失效：

| 类型 | 典型现象 | 谁会发现 |
|---|---|---|
| **白名单漏文件** | TD 报 `undefined module`，或者更糟：编译过了但用的是旧版文件 | 只有人眼看日志 |
| **信号无驱动 / 多消费者** | 综合器给常量，功能没了 | **没人** |
| **`$readmemh` 找不到 .hex** | 全零 BRAM，所有中文变空白 | **没人** |

本文档的每一节都针对这三类，而不是针对"把线连对"。

---

## 1. 两条静默失败链路（t7 之前必须先确认已堵死）

### 1.1 链路一：`sync_src.ps1` 白名单

TD 编译的是 `project/hdmi/` 下的**副本**，不是 `rtl/`。副本由
`scripts/sync_src.ps1` 生成，而它的 `$map` 是一个**显式有序哈希表白名单**。

> **不在 `$map` 里的源文件永不复制。** TD 根本看不到它。
> 报错只表现为 `undefined module`；而如果旧副本还在（上一版同步留下的），
> 编译会**成功**，用的是旧版文件 —— 改了 RTL 但现象不变，最费时间的一类。

**已处置（t7 准备阶段，2026-11-02 完成）**：

| 项 | 补前 | 补后 |
|---|---|---|
| `$map` hashtable 条目 | 51 | **66** |
| 其中 `.v` key | 48 | **62**（新增 14） |
| 其中 `.hex` key | 0 | **1**（新增，全新文件类型） |
| `rtl/` 下 .v 被覆盖 | 46 / 66 | **60 / 66**（剩 6 个是无人例化的孤儿，见下） |
| AST 解析错误 | — | **0**（`[Parser]::ParseFile` 实测） |
| 重复 key | — | **0** |

补进去的 14 个 .v（→ `project\hdmi\<同名>`）：
`key_router` / `mode_ctrl` / `brightness_apply` / `aht20_ctrl` / `i2c_master` /
`thermal_guard` / `pix_mosaic` / `ratio_map` / `rle_decoder` / `emerg_page` /
`cjk16_font` / `audio_src_mux` / `vol_apply` / `wav_stream_player`。

**故意不加的 6 个**（全 rtl 零例化，加了只是让 TD 多编无用文件）：
`ax_debounce.v` / `image_path_probe.v` / `image_readback_diag.v` /
`sdram_frame_diag.v` / `color_bar_ref.v` / `dmz_eg4s20_bringup_top.v`。

> ⚠️ **t7-A 开工前必须先跑一次 `powershell -ExecutionPolicy Bypass -File scripts\sync_src.ps1`。**
> **✅ 已于 2026-11-02 执行完毕**（`-NoLint`，EXIT=0，「同步完成: 28/71 个副本被更新」）。
> 执行前 `.al` 曾一度指向 14 个磁盘上不存在的文件，TD 表现为「64 个条目、只 analyzed 49 个」
> —— 这个中间态本身就是链路一的活证据：**它只报 `PRJ-7001 CRITICAL-WARNING`，不中止**。
> 同步后实测：`project/hdmi/` = **60 个 .v + 1 个 `.hex`**，`.al` 里指向的文件全部存在
> （唯一例外是历史遗留的 `hdmi/sdram_bringup_top.v`：在 `$map` 里但不在 `.al` 里，不属 t7）。

### 1.2 链路二：`cjk16_bitmap.hex` 的查找路径

`rtl/osd/cjk16_font.v` 里写的是 `$readmemh("cjk16_bitmap.hex", mem)` —— **没有目录前缀**。

TD `$readmemh` 的路径查找顺序：
1. **调用它的源文件所在目录**（即 `project/hdmi/`，因为 `cjk16_font.v` 副本在那儿）
2. `.al` 所在目录（`project/`）

所以 `.hex` 必须和 `cjk16_font.v` **同目录落进 `project/hdmi/`**。

> **漏掉不报错。** 综合期找不到文件，最坏情况是静默产生**全零 BRAM**：
> 屏幕上所有中文变空白，`status` 报告全绿。
> 唯一的机器可判据是综合后 `#bram` 必须涨（见 §4 自检 #1）。

**已处置**：`$map` 新增 `'rtl\osd\cjk16_bitmap.hex' = @('project\hdmi\cjk16_bitmap.hex')`
（37,200 B / 7,440 行，465 字形 × 16 行，首末行均为 `0000`）。
**`.hex` 不进 `.al` 的 `<Source_Files>`** —— 它不是编译单元，只靠同目录查找。

### 1.3 `.al` 的 `<Source_Files>` 同步

| 项 | 补前 | 补后（实测） |
|---|---|---|
| `<Verilog>` 段 `<File Path>` 条目 | 49 | **64** |
| 其中 `hdmi/*` | 45 | **60**（原 45 + 新增 15：14 模块 + `narr_subline`） |
| 其中 `../ip/local/sdram/*.enc.v` | 4 | 4 |
| `CompileOrder` | 1..49 | **1..64 连续无缺号、0 重复** |
| **全文** `<File Path>` 开/闭 | 51/51 | **66/66**（= Verilog 段 64 + 约束段 2：`hdmi/dmz_eg4s20_hdmi.adc` / `.sdc`） |

> **为什么是 15 个新增而不是 14**：`rtl/osd/narr_subline.v`（t13 新建，39,731 B / 1,250 行）
> 与 cjk16 完全是同一类白名单缺口 —— 它既不在 `$map` 也不在 `.al`，而 `osd_caption.v:384`
> 例化了它。漏掉 = TD 报 `undefined module narr_subline`。**已一并补齐**（`CompileOrder=64`）。

备份：`project/hdmi_td.al.bak_t7prep`（20,054 B，MD5 `E2297DE03FE156485CEC331D63098D74`）。

> **验 `.al` 不要用严格 XML 解析器。** `<Attr Name="UsedInP&R" .../>` 里的裸 `&` 是
> TD 自有写法，**备份同样解析失败**。判据用：
> ①`<File\s+Path="[^"]*">` 计数 ②`</File>` 计数 ③两者配平 ④`CompileOrder` 连续性
> ⑤最终验收仍是 TD `open_project`。

---

## 2. 接线清单

### 2.0 时钟与复位域（先立规矩，后面每一行都靠它）

| 域 | 信号 | 来源 | 复位 |
|---|---|---|---|
| 像素域 | `clk_pixel` (25 MHz) | `hdmi_pll u_pll` | `rst_n = rst_sync_pix[2]` |
| 像素域 5 倍频 | `clk_5x` (125 MHz) | `hdmi_pll` | 同上 |
| SDRAM 域 | `clk_sdr` / `clk_sdr_sft` | `sdram_pll u_sdram_pll` | `rst_sync_sdr[2]` |
| 板级参考 | `clk` (50 MHz) | 外部 R7 | `rst_n_btn`（E3） |

**t7 的所有新模块都落在 `clk_pixel` 域**，唯一例外是 `image_player` 内部的
SDRAM 域（已由它自己处理，顶层不用管）。

- `i2c_master` / `aht20_ctrl` / `thermal_guard`：`clk_pixel`（`aht20_ctrl.v:114` 注释明确
  `clk` 是 25 MHz clk_pixel；`thermal_guard.v:97` 同）。
- `rle_decoder` / `wav_stream_player` / `vol_apply` / `audio_src_mux`：`clk_pixel`。
  `RESOURCE_BUDGET.md:278` 明确 `wav_stream_player` **全程 25 MHz 单时钟域，无 CDC**。
- `pix_mosaic`：端口名是 **`clk`**（不是 `pixel_clk`），接 `clk_pixel`。
- `brightness_apply` / `emerg_page` / `ratio_map` / `video_content_mux`：**纯组合，无时钟**。

### 2.1 新增的顶层端口

顶层现在**没有任何 i2c 信号**（全文只有 `:310` 的 DDC 注释、`:484-485` 的
`ddc_scl_unused`/`ddc_sda_unused`、`:491` 的 `.IIC_SCL_DIV(250)`）。必须新增两个：

```verilog
    // ---- AHT20 温湿度传感器（I2C，开漏 + 外部上拉）----
    output wire        i2c_scl,        // D1（.adc:130 已约束 LVCMOS33/8mA/PULLUP）
    inout  wire        i2c_sda         // E1（.adc:131 同上，双向）
```

端口方向说明（`.sdc:124` 的注释已给出规范写法）：

```verilog
    wire        scl_oe, sda_oe, i2c_sda_in;
    assign i2c_scl    = scl_oe ? 1'bz : 1'b0;   // 1=释放（外部上拉抬高）0=拉低
    assign i2c_sda    = sda_oe ? 1'bz : 1'b0;
    assign i2c_sda_in = i2c_sda;                 // SDA 回读：从机 ACK 与数据都从这里进
```

> `i2c_scl` 只输出不回读（本设计不需要时钟延展）。
> **`PULLTYPE=PULLUP` 与开漏接法缺一不可** —— 少一个，总线永远是低电平，
> `aht20_ctrl` 会一直 `err_code != 0`、`sensor_fault=1`，且**不影响任何其他功能**，
> 所以很容易被当成"传感器坏了"而放过。

`.sdc:118-121` 已有四条 `set_false_path` 覆盖这两个端口，不用再加。

### 2.2 `mode_ctrl` —— 模式的唯一权威

```
mode_ctrl #(.CLK_FREQ_HZ(25_000_000), .CONFIRM_MS(2000)) u_mode (
    .clk(clk_pixel), .rst_n(rst_n),
    .key_event(key_event), .key_code(key_code),
    .temp_alarm(temp_alarm),                    // ← thermal_guard.oth_en（电平！）
    .mode(mode), .emerg_latched(emerg_latched), .emerg_src(emerg_src),
    .confirm_armed(confirm_armed), .mode_changed(mode_changed),
    .daily_mode(), .science_mode(), .emerg_mode());
```

| 输出 | 位宽 | 接给谁 | 说明 |
|---|---|---|---|
| `mode[1:0]` | 2 | `video_content_mux.mode`、`video_overlay.info_mode`、`osd_panel.info_mode`、`osd_autopop.info_mode`、`buzzer_tone.tone_sel` 的 `mode==2` 判断、`led[3]` | 0=日常 1=科普 2=应急 |
| `emerg_latched` | 1 | 可选：`led` 或 OSD 状态行 | 应急已锁存（电平） |
| `emerg_src[1:0]` | 2 | 可选：OSD 文本「按键/温度」 | 0=无 1=按键 2=温度 |
| `confirm_armed` | 1 | 可选：OSD 提示「再按一次退出」 | 双按确认窗口内为 1 |
| `mode_changed` | 1 | `rle_decoder` 复位首帧标志（t7-B） | **单拍** |
| `daily_mode`/`science_mode`/`emerg_mode` | 1 each | `audio_src_mux.mode` 之外的组合译码 | 组合译码，= `mode==0/1/2` |

> ⚠️ **`temp_alarm` 必须接 `thermal_guard.oth_en`（电平），不要接 `oth_enter`（单拍）。**
> `mode_ctrl.v:120` 内部自己做了 `temp_alarm_rise = temp_alarm & ~temp_alarm_d`，
> 它要的是**电平**。接单拍会让上升沿检测永远采不到 → 高温永不触发应急。
>
> ⚠️ **`aht20_ctrl.sensor_fault` 绝不能接 `temp_alarm`。**
> `aht20_ctrl.v:145-147` 注释写得很明确：「上级 thermal_guard 不得因 sensor_fault
> 触发应急模式」。传感器坏 ≠ 着火。接了会让终端进应急并且**退不出来**（降温也不退，
> 因为根本没读数）。

### 2.3 `key_router` —— 11 个功能键（Key4~Key14）的唯一译码点

```
key_router #(.CLK_FREQ_HZ(25_000_000), .OSD_HOLD_MS(2500), .P2_EN(1'b0)) u_keyrouter (
    .clk(clk_pixel), .rst_n(rst_n),
    .key_event(key_event), .key_code(key_code),
    .mode(mode),                                // ← mode_ctrl.mode（应急钳位用）
    .bright_lvl(bright_lvl), .vol_lvl(vol_lvl), .res_sel(res_sel), .ratio_sel(ratio_sel),
    .audio_en(), .ticker_en(),                  // 被 _eff 取代，有意空连接（附录 A #5/#6）
    .viz_en(viz_en),
    .osd_pop_req(), .osd_item(),                // 有意空连接（§5 #7）
    .audio_en_eff(audio_en_eff), .ticker_en_eff(ticker_en_eff),
    .rescan_req(), .pattern_sel(),              // P2_EN=0 → 恒 0，见下
    .invert_en(), .grid_en(), .beep_muted());
```

16 个输出的完整归属见 **附录 A**（删 `key_action` 时按那张表逐项划）。

**`key_router` 的键号表（`key_router.v:116-127`，实测照抄）：**

| 键 | 常量 | 功能 | `P2_EN` |
|---|---|---|---|
| Key4 | `K_AUDIO=4'd4` | 音频开关 | — |
| Key5 | `K_TICKER=4'd5` | 底部字幕开关 | — |
| Key6 | `K_BRIGHT=4'd6` | 亮度 10 档 | — |
| Key7 | `K_VOL=4'd7` | 音量 10 档 | — |
| Key8 | `K_RES=4'd8` | 分辨率 5 档 | — |
| Key9 | `K_RATIO=4'd9` | 屏占比 5 档 | — |
| Key10 | `K_VIZ=4'd10` | 音频可视化开关 | — |
| Key11 | `K_RESCAN=4'd11` | 图库重扫 | **P2** |
| Key12 | `K_PATTERN=4'd12` | 测试图案循环 | **P2** |
| Key13 | `K_INVERT=4'd13` | 反色 | **P2** |
| Key14 | `K_GRID=4'd14` | 九宫格 | **P2** |
| Key15 | `K_BEEP=4'd15` | 蜂鸣器静音 | **P2** |

> **注意 Key12 与 `player_ctrl.K_NEXT` 不冲突**：`key_router` 的 Key12 是测试图案，
> `player_ctrl` 只认 Key0/Key1（经 `key_event_media` 门控），两者互不干扰。
> 但 **`K_BEEP=4'd15` 与 `player_ctrl.K_EMERG=4'd15` 数值相同** —— 这是
> `key_event_media` 门控必须存在的第二个理由（否则 Key15 会同时被两家消费）。

`P2_EN=1'b0` 的后果（必须知道，否则会去查"为什么 Key11~15 没反应"）：
`rescan_req` / `pattern_sel` / `invert_en` / `grid_en` / `beep_muted` **恒 0**
（`key_router.v:268/272/279/283/287` 五处 `P2_EN ? ... : 1'b0`）。
这是 t7-A 的既定状态，不是 bug。

> ⚠️ **`pattern_sel` 恒 0 会让 `test_pattern_gen` 永远停在图案 0**，
> 而 `seg_decoder u_dec0`（`:609`）也就永远显示 `0`。这是预期行为
> （用户规格里没有"测试图案"这个键），上板验收时**不要把它当成故障**。
> 若 t8 要恢复，把 `P2_EN` 改 `1'b1` 即可 —— 但那时要重新确认 Key11~15
> 不会与 `player_ctrl`/`mode_ctrl` 抢键。

### 2.4 控制/传感器链（3 个模块，一条直线，没有分支）

```
key_router ──pattern_sel──► test_pattern_gen.pattern_sel + seg_decoder u_dec0（:609）
                       │     （P2_EN=0 → 恒 0，Key11~15 备用不接，见 §2.3）
i2c_master u_i2c ◄────► aht20_ctrl u_aht20 ──temp_centi_c/temp_valid──► thermal_guard u_thermal
   (clk_pixel)              (clk_pixel)                                    (clk_pixel)
   scl_oe/sda_oe             err_code[3:0]                                 oth_en ──► mode_ctrl.temp_alarm
   sda_in ◄ i2c_sda          sensor_fault ──► 空连接（§5 #4，严禁接 temp_alarm）
```

```
i2c_master #(.CLK_FREQ_HZ(25_000_000), .SCL_FREQ_HZ(100_000)) u_i2c (
    .clk(clk_pixel), .rst_n(rst_n),
    .start_req(i2c_start_req), .start_done(i2c_start_done),
    .stop_req(i2c_stop_req),   .stop_done(i2c_stop_done),
    .wr_req(i2c_wr_req), .wr_data(i2c_wr_data), .wr_done(i2c_wr_done), .wr_ack(i2c_wr_ack),
    .rd_req(i2c_rd_req), .rd_nack(i2c_rd_nack), .rd_done(i2c_rd_done), .rd_data(i2c_rd_data),
    .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_in(i2c_sda_in), .busy(i2c_busy));

aht20_ctrl #(.CLK_FREQ_HZ(25_000_000)) u_aht20 (
    .clk(clk_pixel), .rst_n(rst_n),
    .i2c_start_req(i2c_start_req), .i2c_start_done(i2c_start_done),
    .i2c_stop_req(i2c_stop_req),   .i2c_stop_done(i2c_stop_done),
    .i2c_wr_req(i2c_wr_req), .i2c_wr_data(i2c_wr_data),
    .i2c_wr_done(i2c_wr_done), .i2c_wr_ack(i2c_wr_ack),
    .i2c_rd_req(i2c_rd_req), .i2c_rd_nack(i2c_rd_nack),
    .i2c_rd_done(i2c_rd_done), .i2c_rd_data(i2c_rd_data),
    .temp_centi_c(temp_centi_c), .temp_valid(temp_valid),
    .humid_centi(humid_centi), .humid_valid(humid_valid),
    .cal_ok(cal_ok), .sensor_ok(sensor_ok), .err_code(sensor_err),
    .busy(sensor_busy), .sensor_fault(sensor_fault), .meas_tick(meas_tick));

thermal_guard #(.TH_HIGH(16'sd4500), .TH_LOW(16'sd4000), .STALE_CYCLES(50_000_000)) u_thermal (
    .clk(clk_pixel), .rst_n(rst_n),
    .temp_centi_c(temp_centi_c), .temp_valid(temp_valid),
    .oth_en(temp_alarm), .oth_enter(), .oth_exit(), .temp_alive(temp_alive));
```

**参数取值依据**（写死在这里，不要在例化处另编数字）：
`SCL_FREQ_HZ=100_000` → `i2c_master` 内部 `QUARTER=63` 拍，实测 SCL 99.21 kHz。
写成 400k 需要重新核 `QUARTER`，现值会超速。
`TH_HIGH=45.00℃` / `TH_LOW=40.00℃` 是回差（迟滞），不是"两个阈值任选"。
`STALE_CYCLES=50_000_000` = 25 MHz 下 2 s（`aht20_ctrl` 测量周期 1 s 的 2 倍余量）。

`temp_centi_c` 是 **`signed [15:0]`，单位 0.01℃**（−12.52℃ = `-1252`）。
上位若要做比较，必须用 `$signed()`，否则 −12.52℃ 会被当成 64384 这个大正数。

### 2.5 视频几何链（Key8 分辨率 + Key9 屏占比）

```
res_sel[2:0] ──查表──► res_src_w[15:0] ┐
                    res_src_h[15:0]     ├─► eff_src_w / eff_src_h ──► pix_mosaic.src_w
mode==2 ───────────────────────────────┘        （应急强制 640×480）

ratio_sel[2:0] ──► ratio_map u_ratio ──► rm_win_w[10:0] ┐
                                          rm_win_h[9:0]  │ 显式补零
                                          rm_win_ox[10:0]├──► mask_win_w[15:0] ─┬─► image_window_mask.win_w
                                          rm_win_oy[9:0] ┘  mask_win_h[15:0]     ├─► image_window_mask.win_h
                                                            mask_win_ox[15:0]    ├─► image_window_mask.win_off_x
                                                            mask_win_oy[15:0]    └─► （t7-B）pix_reader.win_off_y
```

**这批线的两条硬约束（漏掉都不报错）：**

**① `ratio_map` 输出 11/10 位，`image_window_mask` 输入 16 位 → 必须显式补零。**

```verilog
    wire [10:0] rm_win_w,  rm_win_ox;
    wire [9:0]  rm_win_h,  rm_win_oy;
    wire [15:0] mask_win_w  = {{5{1'b0}}, rm_win_w};
    wire [15:0] mask_win_h  = {{6{1'b0}}, rm_win_h};
    wire [15:0] mask_win_ox = {{5{1'b0}}, rm_win_ox};
    wire [15:0] mask_win_oy = {{6{1'b0}}, rm_win_oy};
```

不补零 Verilog 会自动零扩展 —— **那是侥幸**。一旦有人在 `ratio_map` 里改成 12 位，
高位会静默截断，窗口宽度永远是 2047 而不是 640。

**② `ratio_map` 的 `win_*` 有两个消费者，两路必须接同一组信号。**

| 消费者 | 何时接 | 用哪几根 |
|---|---|---|
| `image_window_mask`（位置门控） | **t7-A 就接** | `win_w` / `win_h` / `win_off_x` / `win_off_y` 全部 4 根（16 位，直连 `mask_win_*`） |
| `pix_reader`（窗口内降采样） | **t7-B**（端口已在 `pix_reader` 落地，但 `image_player` 透传层未落盘，见 §5 #1） | `win_w` / `win_h` / `win_off_x` / `win_off_y`（**也是 16 位，与 mask 完全同款**）+ `active_x[10:0]` |

> `pix_reader.v` 实测（2026-11-02 14:24:32 版）的 `win_*` 是 **`[15:0]`**，
> 不是早先冻结清单写的 `[10:0]`/`[9:0]`。所以 `mask_win_*` **一组信号可以同时喂两个消费者**，
> 中间不需要任何位宽转换。`use_key9` 是它内部 wire（`:256` `assign use_key9 = !h_ident;`），**不是端口**。

> 接成两个来源（比如 mask 接 `ratio_map`、reader 接 `image_player.out_w`）的现象是
> **画面被切一半**，不报错。这是 T1_TO_T7_WIRING §1.3 记的第一号坑。

`res_sel` 查表（`KEYMAP.md` §9.3，与 `ratio_map` 档位表独立）：

| `res_sel` | 逻辑分辨率 | 说明 |
|---|---|---|
| 0 | 320 × 240 | 1/4 面积 |
| 1 | 400 × 300 | 约 5/12 |
| 2 | 512 × 384 | 约 9/16 |
| 3 | 576 × 432 | 约 3/4 |
| 4（默认） | 640 × 480 | 全屏 |

`ratio_map` 实测档位（`ratio_map.v:86-131`，非法档 5..7 回落全屏）：

| `ratio_sel` | `win_w` | `win_h` | `win_off_x` | `win_off_y` |
|---|---|---|---|---|
| 0 | 320 | 240 | 160 | 120 |
| 1 | 400 | 300 | 120 | 90 |
| 2 | 480 | 360 | 80 | 60 |
| 3 | 560 | 420 | 40 | 30 |
| 4 / default | 640 | 480 | 0 | 0 |

> ⚠️ 注意 `res_sel` 与 `ratio_sel` 的**档位表不一样**（`res_sel=2` 是 512×384，
> `ratio_sel=2` 是 480×360）。两张表故意不同：前者是逻辑分辨率（缩放源尺寸），
> 后者是显示窗口（屏幕上占多大）。抄错表不会报错，只会让画面比例不对。

`pix_mosaic` 例化（**注意 `valid_in` 接 `pixel_valid` 而不是 `pixel_valid_shown`**）：

```verilog
    wire [15:0] img_pix565;
    wire        img_pix_valid;
    pix_mosaic u_mosaic (
        .clk(clk_pixel), .rst_n(rst_n),
        .active_x(active_x), .src_w(eff_src_w),
        .rgb565_in(image565), .valid_in(image_pixel_valid),
        .rgb565_out(img_pix565), .valid_out(img_pix_valid));
```

> 接 `pixel_valid_shown` 会形成**组合环**（shown 由 mask 算，mask 的输入经 mux 回到
> pix_mosaic 的输出路径）。`T1_TO_T7_WIRING.md` §5 问题① 已定性。
>
> `pix_mosaic` 本体**不是纯组合**：它有 2 个寄存器 `x_acc`（列权重累加器）与
> `hold`（保持像素），`rgb565_out = take ? rgb565_in : hold`（`pix_mosaic.v:117`）；
> `valid_out` 是纯直通（`:122`）。所以 `valid_out` 与 `rgb565_out` **同拍**，
> 上层不需要为 `valid` 另加延迟对齐。

### 2.6 像素链主通路（含 `brightness_apply` 插入点）

```
u_player(242) ─► pix_mosaic ─► img_pix565 ─► image888 ┐
                                                       ├─► u_content_mux(279) ─► video_base
u_emerg_page ─────────────────────► emerg_rgb ─────────┘
                                                                                   │
      video_base ─► u_overlay(429) ─► video_rgb_ovl ─► [u_bright] ─► video_rgb_brt ─► u_osd_panel(462) ─► video_rgb ─► u_axis(325) ─► HDMI
```

**改动（行号级）：**

| 位置 | 现在 | 改成 |
|---|---|---|
| `:288` | `wire [23:0] video_rgb_ovl;` | 不动（仍是 `u_overlay` 输出） |
| 新增 | — | `wire [23:0] video_rgb_brt;` |
| `:464` | `.rgb_in(video_rgb_ovl)` | `.rgb_in(video_rgb_brt)` |
| `:260` | `wire [23:0] image888 = {image565[15:11], ...}` | 输入源从 `image565` 改为 **`img_pix565`** |
| `:282` | `.image_pixel_valid(image_pixel_shown)` | 不变（mask 输出） |
| `:283` | `.science_rgb(science_rgb)` | 改为 `.emerg_rgb(emerg_rgb)` |

```verilog
    brightness_apply u_bright (
        .de         (de),
        .rgb_in     (video_rgb_ovl),
        .bright_lvl (bright_lvl),       // key_router.bright_lvl[3:0]，4 位全接，0..9
        .de_out     (),                 // 空连接，见下方说明
        .rgb_out    (video_rgb_brt));
```

**三个必须遵守的点：**

1. **`brightness_apply` 绝不能被改成带寄存器。**
   它是纯组合（`brightness_apply.v:126-129` 三条 `assign`）。加一级寄存器会让下游
   `osd_panel` 的 `active_x/active_y` 相对像素错 1 拍 → 参数面板整体右移 1 像素，
   **且只在非 0 档位下出现**（不同档位组合逻辑深度不同，时序收敛点不同）。
   仿真无延迟，抓不到。

2. **`.de_out` 可以空连接 —— 已读源码确认。**
   `osd_panel.v:183` 的唯一 `de` 用法是
   `assign rgb_out = de ? (in_panel ? panel_rgb : rgb_in) : 24'd0;`，
   **只做输出门控，不门控 `active_x` 计数**。`brightness_apply.de_out === de`（纯直通），
   所以 `osd_panel.de` 继续接顶层 `de` 即可。

3. **`bright_lvl` 是 4 位 0..9，要分给两个消费者，位宽不同：**

   | 消费者 | 接法 | 用途 |
   |---|---|---|
   | `brightness_apply.bright_lvl` | `bright_lvl[3:0]`（**4 位全接**） | 真正衰减（10 档） |
   | `video_overlay.bright_sel` | `bright_lvl[2:0]`（**只接低 3 位**） | 只画信息条第 8/9/10 格（`video_overlay.v:224-226`） |

   接反 = **双重变暗**，而且只有暗档看得出来（亮档两处都接近 ×1）。
   `video_overlay` 内部 5 档衰减已删干净（`:132-133` 现在是 `wire [7:0] r_brt = r_in;`），
   但不要试图"恢复"它。

**`brightness_apply` 10 档实测值**（`brt10` 函数，`:99-119`，相对满量程 32）：

| 档 | 表达式 | 亮度 | 档 | 表达式 | 亮度 |
|---|---|---|---|---|---|
| 0 | `x` | 32/32 | 5 | `x>>1` | 16/32 |
| 1 | `x-(x>>4)-(x>>5)` | ≈29/32 | 6 | `(x>>1)-(x>>4)-(x>>5)` | ≈14/32 |
| 2 | `x-(x>>3)-(x>>4)` | ≈26/32 | 7 | `(x>>2)+(x>>4)` | 10/32 |
| 3 | `x-(x>>2)-(x>>5)` | ≈21/32 | 8 | `(x>>3)+(x>>4)` | 6/32 |
| 4 | `x-(x>>2)-(x>>3)` | ≈18/32 | 9（default） | `(x>>4)+(x>>5)` | 3/32 |

> **方向：0 = 最亮。** 与音量**相反**（音量 0 = 9.4% 最轻、9 = 100%）。
> 这两个方向是相反的，写死在这里免得上板后怀疑按键接反。

### 2.7 `video_content_mux` 改两源（t16 裁定）

**改后的完整文件（29 行，原 38 行）：**

```verilog
// Final pixel-source selection for the HDMI display.
// v2 两源形态：
//   mode 0 / 1 / 3 = 图像路（图库 BMP 与科普 RLE 视频共用同一 SDRAM 读出通路，
//                    由 image_ready / image_pixel_valid 决定当前有没有内容）
//   mode 2         = 应急疏散图 emerg_page（不再是纯红 24'hFF_00_00）
module video_content_mux (
    input  wire        de,
    input  wire [1:0]  mode,
    input  wire        image_ready,
    input  wire        image_ever_ready,
    input  wire        image_pixel_valid,
    input  wire [23:0] image_rgb,
    input  wire [23:0] pattern_rgb,
    input  wire [23:0] emerg_rgb,
    output reg  [23:0] rgb_out
);
    always @* begin
        rgb_out = 24'd0;
        if (de) begin
            case (mode)
                2'd2: rgb_out = emerg_rgb;
                default: begin
                    // A committed frame owns the source selection. During a
                    // short read-side underflow, black is safer than leaking
                    // a white test-pattern pixel into the new frame.
                    if (image_ready)
                        rgb_out = image_pixel_valid ? image_rgb : 24'd0;
                    else if (image_ever_ready)
                        rgb_out = 24'd0;
                    else
                        rgb_out = pattern_rgb;
                end
            endcase
        end
    end
endmodule
```

净变化：**−1 个端口（`science_rgb`）+1 个端口（`emerg_rgb`）= 0**。
删掉 `2'd1` 分支是因为科普模式改由 `rle_decoder → image_player 外部写口 →
同一 SDRAM 读出通路` 承载，走的就是 `default` 分支的 `image_ready` / `image_pixel_valid`。

`emerg_page` 例化（与 `science_page` 同四端口，平级替换）：

```verilog
    wire [23:0] emerg_rgb;
    emerg_page u_emerg (
        .de(de), .active_x(active_x), .active_y(active_y), .rgb_out(emerg_rgb));
```

> `emerg_page` **不经** `pix_mosaic` / `image_window_mask`（应急必须全屏满分辨率），
> 直接进 `video_content_mux` 的 `2'd2` 分支。这是 `ARCH_ADDENDUM_VIDEO_PATH.md` §7.4 的裁定。

**连带删除（三处同删，漏一处留下悬空线）：**
`:133` `wire [23:0] science_rgb;` / `:134-135` `science_page u_science_page (...)` / `:283` `.science_rgb(science_rgb)`。

### 2.8 音频链（样本级 mux 必须在顶层补）

**现状（`audio_src_mux.v` 是控制信号发生器，不是样本 mux）：**

它的端口里**零个样本端口**，只有 `src_sel[1:0]` / `src_name[87:0]` / `src_start` /
`eff_audio_en`。`ARCH.md:654-671` 伪码里那个「WAV 未就绪 → 降级 tone_gen」的判决
**实现不存在**。必须在顶层级补。

**修正后的音频拓扑：**

```
wav_stream_player u_wav ──sample_valid/sample_l──┐
                                                 ├─► [样本 mux] ─► vol_apply u_vol ─► 四消费者
audio_tone_gen     u_tone ──audio_valid/audio_left┘        ▲            ▲
                                                    wav.playing        vol_lvl[3:0]
```

```verilog
    // ★ 样本级 mux：ARCH 伪码里有、实现里没有的那一段
    wire               src_sample_valid = wav_playing ? wav_sample_valid : tone_audio_valid;
    wire signed [23:0] src_sample_l     = wav_playing ? wav_sample_l     : tone_audio_left;
    wire signed [23:0] src_sample_r     = wav_playing ? wav_sample_r     : tone_audio_right;

    vol_apply #(.VOL_MAX(4'd9)) u_vol (
        .clk(clk_pixel), .rst_n(rst_n),
        .sample_valid(src_sample_valid), .sample_in(src_sample_l),
        .vol_lvl(vol_lvl), .mode(mode), .audio_en(audio_en_eff),
        .sample_valid_out(audio_valid), .sample_out(audio_left),
        .eff_lvl(vol_eff_lvl));
```

> 用 `wav_stream_player.playing`（电平）当选择位，**不要用 `sample_valid`**
> （那是每 48 kHz 一拍的脉冲，用它选源会导致波形在换源那一拍被截断）。
>
> `audio_en_eff` 用**有效版本**（`key_router` 内部 `emerg ? 1'b1 : audio_en`），
> 应急态强制有声。`audio_src_mux.eff_audio_en` 输出**不接** ——
> 以 `key_router` 为唯一权威，两个 eff 并联会让"应急强制开"出现两个来源。

**`vol_apply` 的三个（其实四个）消费者，漏一个都是隐性 bug：**

| # | 消费者 | 接什么 | 漏接的表现 |
|---|---|---|---|
| ① | `hdmi_audio_left/right = audio_left >>> 6` → `u_hdmi_core.I_audio_left_data` | `audio_left`（**vol 之后**） | 调音量声音不变 |
| ② | `pcm_to_pwm u_pwm_audio.sample_in` | `audio_left`（**vol 之后**） | 3.5mm 口音量不变 |
| ③ | `video_overlay.audio_sample` | `audio_left`（**vol 之后**） | **调音量声音变小但屏幕波形幅度不变** |
| ④ | `audio_arc u_arc.audio_valid` | `audio_valid`（只吃 valid，不吃样本） | ACR 不工作，接收端可能无声音 |

> ④ 单独强调：`audio_arc.v` 的 `cts_cnt` **在 `!audio_valid` 时也继续 +1**
> （它用像素时钟测音频时钟）。所以 `audio_valid` 必须保持 **48 kHz 匀速**，
> **不能接成门控**（比如 `audio_en & audio_valid`）—— 接成门控会让 ACR 的 CTS 计数
> 与真实采样率脱钩，接收端表现为"有声音但隔几秒断一下"。

`HDMI_AUDIO_ATTEN_SHIFT = 6`（`:408`）保留不动。**方向**：先 `vol_apply` 衰减，
再 `>>>6`（−36 dB）。两个衰减串联是原有设计（HDMI 试听音量偏低是刻意的）。

### 2.9 端口名差异表（照 ARCH 原稿写会编译不过）

| 模块 | `ARCH.md` / 早期文档写的 | **实测（以此为准）** |
|---|---|---|
| `image_player` | `ext_wr_req` | **`ext_wr_valid`**（单拍写请求） |
| `image_player` | `ext_wr_en` | **`ext_wr_done`**（单拍：本帧最后一字已写完） |
| `image_player` | `ext_frame_start` | **`ext_frame_sel[1:0]` + `ext_frame_ready`** |
| `image_player` | — | 新增 `ext_no_fade`（1=禁用淡入淡出，**视频模式必须为 1**） |
| `image_player` | — | 新增 `ext_loader_want_blk`（高=内部 img_loader 正在要 SD 块） |
| `pix_mosaic` | `pixel_clk` | **`clk`**，且**无 `de` 端口** |
| `audio_arc` | `rtl/audio/audio_arc.v` | **`rtl/video/hdmi/audio_arc.v`** |
| `err_prompt` | `rtl/osd/` 或 `rtl/video/` | **`rtl/control/err_prompt.v`** |
| `audio_waveform` | `rtl/audio/` | **`rtl/video/audio_waveform.v`** |
| `pwm_audio_out` | 顶层例化它 | 顶层例化的是 **`pcm_to_pwm`**（`:582`）；`pwm_audio_out.v` 存在但无人例化 |
| `cjk16_font` | 顶层例化 | **不顶层例化**，唯一例化点是 `osd_caption.v:358` |

> 最后一行决定了件数：14 个新文件里，顶层要例化的是 **13 个**（`cjk16_font` 由
> `osd_caption` 内部例化）。这就是"13 个新模块"这个数字的来源。

---

## 3. 删除清单与顺序

### 3.1 为什么必须是「先建后删」

`key_action` 有 9 个输出，`key_router` 只覆盖其中 6 个。如果先删 `u_kact` 再接线，
会**同时**出现 9 根无驱动信号：综合器给它们赋常量，位流照出，报告全绿，
功能静默缺失 —— 而且没法判断哪根出了问题。

反过来按下面的顺序，每勾一项都是「新驱动接管 → 旧驱动仍能工作」的**叠加态**，
中间任何时候出问题都能立刻定位到是哪一项。

### 3.2 可勾选清单（全勾完才能删 `u_kact`(101) / `u_ctrl`(116)）

```
[ ] 1. bright_sel[2:0]      → key_router.bright_lvl[3:0]
                               （4 位全接 brightness_apply.bright_lvl；
                                video_overlay.bright_sel 只吃低 3 位）
[ ] 2. invert_en            → key_router.invert_en
[ ] 3. auto_sw_sel[1:0]     → 固定 2'd0                          （裁定 1，D-02）
[ ] 4. grid_en              → key_router.grid_en
[ ] 5. info_en              → 固定 1'b1                          （裁定 2）
[ ] 6. level_en             → 固定 1'b0                          （裁定 3，D-03）
[ ] 7. wave_en              → key_router.viz_en
[ ] 8. beep_muted           → key_router.beep_muted
[ ] 9. rescan_req           → key_router.rescan_req
[ ] 10. pattern_sel[2:0]    → key_router.pattern_sel（P2_EN=0 → 恒 0）
                               （同时删 :84 / :85 两条抢 KEY4/KEY5 的直连）
[ ] 11. audio_muted(:399-403) → key_router.audio_en_eff
                               （同时删 :402 抢 KEY6 的直连）
[ ] 12. caption_en(1'b1)    → key_router.ticker_en_eff
                               （同时改掉 :422-428 的过时注释）
```

### 3.3 三条「无替身」信号的裁定（不占新键）

`key_action` 的 9 个输出里，`key_router` 没有 `auto_sw_sel` / `info_en` / `level_en`
的替身。Key0~Key10 已满，Key11~15 按 `KEYMAP.md` 保留备用，**不给它们新占键号**：

| 信号 | 裁定 | 消费点 | 后果 | 降级项 |
|---|---|---|---|---|
| `auto_sw_sel[1:0]` | **固定 `2'd0`** | `player_ctrl.v:183` 输入 / `:248 auto_target`、`osd_autopop.v:74`、`osd_panel.v:81`、`video_overlay.v:90` | `auto_target = AUTO_TICKS`（×1），**轮播完整保留，只倍率不可调** | **D-02** |
| `info_en` | **固定 `1'b1`** | `video_overlay` 的 `px_info` 层（`24'h101820` 底衬） | 信息条常开。`osd_autopop` 已有 `HOLD_MS(2500)` 自动隐藏 | — |
| `level_en` | **固定 `1'b0`** | `video_overlay` 音频电平条 | 电平条关闭。可视化由 Key10 = `viz_en` 单管波形层（`audio_waveform.v`，449 le / 416 lut） | **D-03** |

> `level_en` / `wave_en` 旧设计是**同一个 KEY13 的 4 态循环**（电平条 → 波形 → 关）。
> 新需求把可视化拆成 Key10 = `viz_en` 单独管波形层，**电平条这一档没有归属**。

### 3.4 `pattern_sel` 的隐藏消费者（改接后不要动这行）

`:609` `seg_decoder u_dec0 (.bin_data({1'b0,pattern_sel}), .seg_data(seg0));`

数码管 dig0 显示当前测试图案序号。改接 `key_router.pattern_sel` 后**这行不用动**。
但如果有人以为 `pattern_sel` 只喂 `test_pattern_gen` 而把它接了别的，数码管就会和屏幕不一致。

> **t7-A 的实际形态**：`P2_EN=1'b0` → `key_router.pattern_sel` **恒 0**
> （`key_router.v:272` `pattern_sel <= P2_EN ? ... : ...`）。
> 所以 `test_pattern_gen` 与数码管 dig0 **都固定停在图案 0**。
> 这是预期行为（用户规格里没有"测试图案"键），**上板看到 dig0 恒显示 `0` 不是故障**。
>
> **`pattern_sel` 仍然是 `reg [2:0]`，声明与 `u_dec0` 那行都保留** ——
> 只是驱动源从「顶层 `:84/:85` 手写增减」换成「`key_router` 的输出（恒 0）」。
> 不要因为"恒 0"就把它连到 `3'd0` 常量：一旦 t8/t10 打开 `P2_EN`，
> 常量会让 Key12 永久失效而没人发现。

### 3.5 `u_science_page` 的删除（与 `key_router` 无关，可独立做）

三处同删（漏一处留悬空线，行号已实测核对）：

| 行号 | 原文 | 动作 |
|---|---|---|
| `:133` | `wire [23:0] science_rgb;` | 删除 |
| `:134-135` | `science_page u_science_page (.de(de), .active_x(active_x), .active_y(active_y), .rgb_out(science_rgb));` | 删除（**整体两行**） |
| `:283` | `.pattern_rgb({pr,pg,pb}), .science_rgb(science_rgb), .rgb_out(video_base));` | `.science_rgb(science_rgb)` 改成 `.emerg_rgb(emerg_rgb)`（**这一行不是删，是改**，因为 `u_content_mux` 同时在这一行例化） |

> ⚠️ `science_rgb` 的 `wire` 声明在 **`:133`**（不是 `:135`）；`:134-135` 是例化的两行。
> 删的时候要连 `:134` 的 `science_page u_science_page (` 和 `:135` 的四个端口一起删，
> **只删 `:133` 会留下孤儿例化**，TD 报 `undefined module science_page`（前提是它还在 `.al` 里）；
> 若 `science_page.v` 还在 `.al` 里则**根本不报错**，只是多占 664 LUT —— 静默失败。

删完 `rtl/video/science_page.v`（13,601 B）与 `rtl/video/science_font16.v`（26,227 B）
成为孤儿文件。它们**仍在** `$map` 和 `.al` 里 —— **保留原件不删不报错**，
综合器会优化掉未例化模块（LUT 回收 664），但 `.al` 条目会让 TD 多编一个文件。

| 时机 | 动作 |
|---|---|
| t7-A | 只删顶层三处引用，`.al` 不动 |
| **t7-B 出位流时** | 再决定是否从 `.al` 移除这三条：`hdmi/key_action.v`(order 29)、`hdmi/science_font16.v`(order 38)、`hdmi/science_page.v`(order 39) |

> 若从 `.al` 移除 `science_page.v`，必须同步删 `scripts/run_frontend_regression.ps1:67`
> 的 `science_page` case 与对应 tb，否则回归脚本会报找不到源文件。

### 3.6 执行顺序（t7-A 内部）

```
第 1 步  跑 sync_src.ps1（把 14 个 .v + 1 个 .hex 落进 project/hdmi/）
第 2 步  video_content_mux 改两源 + emerg_page 例化 + 三处 science 引用删除
第 3 步  接 mode_ctrl / key_router（12 项逐项勾，见 §3.2）
第 4 步  接 brightness_apply（§2.6）
第 5 步  u_player 接 .src_w(16'd640) / .src_h(16'd480)
第 6 步  player_ctrl 加 key_event_media 门控（§5 #3）
第 7 步  音频链：样本 mux 三行 + vol_apply + 四消费者改接（§2.8）
第 8 步  传感器链：i2c_master / aht20_ctrl / thermal_guard（§2.4）+ i2c 顶层端口与三态
第 9 步  pix_mosaic 接进像素链 + ratio_map 接 image_window_mask（§2.5）
第 10 步 删 u_kact / u_ctrl（此时 §3.2 应全部勾完）
第 11 步 改 tb_video_content_mux.v:67-71（§4.3 #24-#26）
第 12 步 elaborate -top dmz_eg4s20_hdmi_top + optimize_rtl（不做 bitgen）
```

> **第 5 步不能跳过。** `image_player.v:79-80` 有 `src_w[15:0]` / `src_h[15:0]`，
> `pix_reader` 例化处（`:587`）已接上，但顶层 `u_player`(`:242`) **还没接**。
> 悬空输入 = z → `src_ok = (src_w != 0) && (src_h != 0) && ...` 判假 →
> `map_ident` 变 x → **整条行映射 x 传播 → 上板错行**。
> `img_scaler` 缩放后走 `out_w/out_h` 另一条路，**绝不能把 `scale_w` 接给 `src_w`**
> （那根是"缩放后目标宽"，接错 Key8 抽样比算错）。
> 日常图库与科普视频**都是 640×480**，所以直接接常量即可。

> **第 6 步是 `u_ctrl` 保留的唯一前提。** 不做这一步直接删/留 `u_ctrl`，
> Key2 会同时被 `player_ctrl`（播放/暂停）和 `mode_ctrl`（模式循环）消费，
> Key3 会同时被 `player_ctrl`（模式循环）和 `mode_ctrl`（应急直达）消费 ——
> **按一次动两下，其中一个是最高优先级的应急**。见 §5 #3。

**t7-A 明确不做（留给 t7-B）：**
- `ratio_map.win_*` → `pix_reader.win_*` 的第二路（`pix_reader` 端口已就绪，
  缺 `image_player` 的透传层，§5 #1）
- `rle_decoder.sd_grant` 与五路 SD 仲裁（`rle_decoder` 尚未加端口，§5 #2）
- 任何 `bitgen`

---

## 4. 自检清单（每条都能判真假）

### 4.1 综合期（机器判据，t7-A 第 12 步 + t7-B）

| # | 检查项 | 通过判据 | 失败判据 | 硬/软 | **t7-A 实测（2026-11-02 17:40，含 t16）** | **t7-B 实测（2026-11-02 20:11，`min_ripple_len 45`，route 后）** |
|---|---|---|---|---|---|---|
| 1 | `#bram` | **≥ 33**（=17+16 字库），t7-B 目标 **35** | **仍是 17 = 硬失败**（`.hex` 没进 BRAM 或被优化成常量全零） | **硬** | **34 / 64（53.12%）** ✅ 见下 | **35 / 64（54.69%）** ✅ **判据达成**（34→35 = `narr_en` 接真值） |
| 2 | `#lut` | 15,319 → 约 17,500（±300） | **> 18,800** = 字库掉进分布式 RAM（回查 §1.2 与 `ram_style`） | 硬 | **17,299 / 19,600（88.26%）** ✅ | **18,473 / 19,600（94.25%）** ⚠ 见 §4.1f（gate 阶段 17,645；route 后涨到 18,473） |
| 3 | `#dsp` | 19，不变 | 变了 = 某模块乘法没被推断成移位 | 软 | **24 / 29（82.76%，+5）** ⚠ 见下 | **24 / 29（82.76%）** 不变 ✅ |
| 3b | `#reg` | 6,390 基线，t7-A 允许上涨 | 无硬门禁（离 19,600 还有 11,887） | 软 | **7,713 / 19,600（39.35%）** | **8,478 / 19,600（43.26%）** |
| 4 | `#pll` | 2，不变 | 变了 = 有人给新模块加了时钟 | 硬 | **2 / 4** ✅ | **2 / 4** ✅ |
| 5 | TD 文件计数 | `PRJ-1401: Successfully analyzed 64 source files` | **49** = 没跑 `sync_src.ps1`（§1.1） | 硬 | **64** ✅ | **64** ✅ |
| 6 | elaborate | 输出含 `PASS-elaborate` | 任何 `FAIL-` / `HDL-8007` / `HDL-5105` | 硬 | `PASS-elaborate` / `PASS-optimize_rtl` / `PASS-optimize_gate` 全在，四类 FAIL 计数 **0** ✅ | 同上，全 PASS；`HDL-8007`=0 / `HDL-5105`=0 / `ERROR`=0 ✅ |
| 7 | 多驱动 | 无 `multiple driver` 类告警 | 有 = SD 总线或 `blk_start` 被两方驱动（见 §5 #2） | 硬 | 无 ✅ | 无 ✅ |
| 8 | `place` | 输出 `PASS-place`，mslices ≤ 4,900 | `PHY-9009 ... exceeds the limit 4900` | **硬** | 不跑到 place | **4,805 mslices**（route 后 4,792）✅ 见 §4.1f |
| 9 | 时序 | `SWNS >= 0` 且 `HWNS >= 0`，然后才 bitgen | 任一为负 = FAIL，**不许放宽** | **硬** | 不跑到 route | ⚠ **SWNS −0.183 ns / HWNS −0.020 ns，Fmax 24.886 MHz** —— 见 §4.1f.6 与 §5 #1e |

> **⚠️ `#bram` 判据是 ≥33，不是 32。** 这个数字有分歧，先钉死：
> captain 在派单里举例说「`#bram` 应为 32 而不是 17」，但 `RESOURCE_BUDGET.md:474-484`
> 的门禁第 2 条原文是「必须从 17 涨到 **≥ 33（+16）**」。两者取其一必须现在定。
>
> 算一下：`cjk16_font` 是**8192 深 × 16 位**（地址 `{glyph[8:0], row[3:0]}` = 13 位），
> 按 512×18 容量除算得 `8192 / 512 = 16` 块，但**探针实测落地 15 块**（`project/t2_cjk16_probe/reports/area_a.txt`/`area_b.txt`/`area_c.txt` 三种写法均 `#bram 15`，2026-11-02 更正）。**基线 17 块 + 字库 15 块 = 32**，科普字幕 `narr_subline` 再 +1 到 **33**（M3 门禁值）。
> 所以 **17+16=33 是下限，32 说明少了一块**（某块被合并或被裁），32 不能算通过。
>
> 若 `#bram` 落在 33，`wav_stream_player` 的 2 块抖动缓冲**还没算进去** ——
> 它在 t7-B 才接 SD 端口（§5 #2），届时目标值变 **35**。
> 也就是说：**t7-A 期望 33~34，t7-B 期望 35。** 只要 ≥33 就说明 `.hex` 真的进了 BRAM。

> （原始推算「17+16=33」里的第 16 块按探针实测只有 15 块，所以 t7-A 落 32；
> 实测 34 是因为 `wav_stream_player` 的 2 块已经在 t7-A 接上了。）
>
> **✅ t7-A 实测落点 = 34**（2026-11-02 17:39，`reports/t7a_gate_area.txt`，含 t16 接线后复跑）。分解验证：
> `u_overlay/u_caption/u_cjk`(cjk16_font) = **15 块**，`u_player`(image_player 内部
> `u_write_fifo`) = **3 块**，`u_wav`(wav_stream_player) = **2 块**，`u_hdmi_core` = **14 块**。
> 15+3+2+14 = **34**。→ `.hex` 确实进了 BRAM（否则 `u_cjk` 那 15 块不会出现）。
>
> **⚠️ 但 34 不是「33 + 1」，要把账对清 —— 少的那一块是 `narr_subline`：**
> t7-A 阶段 `osd_caption.narr_en` 接的是常量 `1'b0`，整条科普旁白字库
> （`narr_subline` 的 `reg [8:0] mem [0:1023]`，`ram_style = bram`，理论 1 块）
> **被综合器当作不可达逻辑整体优化掉**，所以它既不在 `#bram` 里、也不在层次报告里
> （层次报告 grep `narr` **0 命中**，可复核）。
> **⇒ t7-B 接上 `narr_en`（变真值）后，`#bram` 应从 34 涨到 35。**
> 若 t7-B 之后仍是 34，说明 `narr_subline` 的字库没落到 BRAM（掉进分布式 RAM 或常量展开），
> 那时 `#lut` 会异常上涨，两者合起来看。
>
> 顺带排除一种误判：`HDL-5314 net 'mem' does not have a driver in hdmi/narr_subline.v(195)`
> 与 `cjk16_font.v(84)` 是**同一类告警**，都是「`mem` 由 `initial`/`$readmemh` 装载、
> 没有普通驱动源」，属正常；`cjk16_font` 那条也在，而它的 15 块 BRAM 确实落地了 ——
> 所以这条告警**不能**当作「字库没进 BRAM」的证据。

> **⚠️ t7-A 阶段口径变更（2026-11-02 17:40 追加）**：`wav_stream_player` 在 t7-A
> 就已接上 SD 端口（它自带 `sd_grant`，不依赖 t19），所以那 2 块抖动缓冲**已经在 34 里**。
> 于是 t7-A 期望值应为 **34**（不是 33~34 区间），t7-B 目标 **35**（+`narr_subline` 1 块）。

> **⚠️ `#dsp` 从 19 涨到 24 / 29（82.76%），只剩 5 个 —— 这是 t7-A 之后最紧的资源，比 LUT 紧得多。**
> 逐项实测（`reports/t7a_gate_area.txt` 层次报告）：`fat32_reader` **三份各 6 个**，
> 分别挂在 `u_gallery`(704 lut / 6 dsp)、`u_player/u_loader`(791 lut / 6 dsp)、
> `u_wav`(757 lut / 6 dsp)；另有 `u_player/u_scaler`(img_scaler **4**) 与
> `u_player/u_fade`(fade_mixer **1**)。三份 fat32 = 18 + 4 + 1 = **23**，实测 24（差 1 在顶层零散逻辑里）。
> 基线 19 里只有前两份 `fat32_reader`（12）+ scaler(4) + fade(1) = 17 + 2 零散。
> **⇒ 净增的 +5 主体就是 v2 新增的第三份 `fat32_reader`（`wav_stream_player` 内部 `u_fat`，6 个）。**
>
> **★★ 由此得出一条硬约束（t7-B 必读）：`rle_decoder` 绝不能再挂第四份 `fat32_reader`。**
> 三份已经吃掉 18/29，第四份 +6 → **30 > 29，直接布不下**（不是"很紧"，是**不可能**）。
> 这正是 §5 #2 那三个方案里 **只有「从 `gallery_probe.u_fat` 引出 `out_*` 五个输出」
> （+30~60 LUT、**+0 DSP**）可行**的硬原因：
> 另两个方案（顶层第四份 / `rle_decoder` 内部例化）不仅 +800 LUT，
> 还要 **+6 DSP** —— 无论 LUT 怎么省都过不了 DSP 这关。

### 4.1b 三判据的完整 stdout（captain 要求，2026-11-02 17:40 补）

**① `project\flow_t7a_elaborate.tcl`**（日志 `%TEMP%\t7a_td_t16b.log`，102,440 B，**EXIT=0 / 81 s**）：
```
PASS-import_device
PRJ-1401 : Successfully analyzed 64 source files.
PASS-open_project
PASS-elaborate
PASS-read_adc
PASS-read_sdc
PASS-optimize_rtl
PASS-report_area
```
计数：`HDL-8007`=0 / `HDL-5105`=0 / `ERROR`=0 / `CRITICAL`=0 / `WARNING`=39 / `FAIL-`=0。

**② `project\t7a_gate_area.tcl`**（日志 `%TEMP%\t7a_gate_t16.log`，131,536 B，**EXIT=0 / 6,943 s**）：
```
PASS-import_device
PRJ-1401 : Successfully analyzed 64 source files.
PASS-open_project
PASS-elaborate
PASS-read_adc
PASS-read_sdc
PASS-optimize_rtl
PASS-optimize_gate
PASS-report_area
```
计数：`HDL-8007`=0 / `HDL-5105`=0 / `ERROR`=0 / `CRITICAL`=0 / `WARNING`=55 / `FAIL-`=0。

> **为什么必须贴 `PASS-*` 序列**：TD 的 `catch` 拿到的 `$emsg` 恒为空串
> （rtl-emerg 在 `project/t2_cjk16_missing/` 用两个对照 tcl 实测过），
> 「脚本 exit 0 且打印 DONE」**不等于**每一步都成功。唯一能分辨的是
> `PASS-<step>` 序列 + 有没有 `FAIL-` / `HDL-8007` / `HDL-5105`。

### 4.1c ★ 一个必须记住的判据陷阱：`vlog` 查不出「命名端口不存在」

**2026-11-02 17:30 实测**（`C:\Users\Koobee\AppData\Local\Temp\t7_probe_portname\`）：
一个只有 `bright_lvl` 端口的模块，被 `sub u_sub (.clk(clk), .bright_sel(bright_sel), .q(q));` 例化：

| 工具 | 结果 |
|---|---|
| `vlog` | **`VLOG_EXIT=0`，零 Error 零 Warning，连一条提示都没有** |
| `vsim`（elaborate） | `VSIM_EXIT=12`；`# ** Error: (vsim-3063) topi.v(2): Port 'bright_sel' not found in the connected module (2nd connection).` |

⇒ **`VLOG_EXIT=0` 不能证明端口名对得上。** 这是 t7-A 期间差点漏掉的一整类缺陷：
t16 把 `osd_panel.bright_sel` 改名成 `bright_lvl` 后，顶层仍写 `.bright_sel(bright_sel)`，
`vlog` 全绿、`elaborate` 也不报（TD 按隐式网处理）——**只有 `vsim` 或下面的交叉校验能抓**。

**替代判据（推荐，秒级）**：`C:\Users\Koobee\AppData\Local\Temp\chk_ports3.py`
（解析 `rtl/` 全部 69 个 module 的端口表，再扫顶层 38 个例化的命名端口，交叉比对）。
t7-A 实测结果：**`NO_SUCH_PORT = 0`**（全部端口名都存在）；自检 15 项全 OK。
另两条 `UNKNOWN_MODULE` 是 `EG_PHY_SDRAM_2M_32` 与
`hdmi_1_4b_transmitter_core_wrapper`（IP / 加密件，源码不在 `rtl/` 内），属正常。

> t7-B 每改完一次顶层，**必须跑这个校验器**（或 `vsim -c` 加载顶层），
> 不能只靠 `vlog` 全绿就宣布接线正确。

**两个必须跑的时机**（2026-11-02 captain 确认为硬要求）：
1. 任何一次改完顶层例化（端口改名 / 增删端口 / 新例化模块）；
2. **跑完 `scripts\sync_src.ps1` 之后再跑一次** —— TD 编的是 `project/hdmi/` 副本，
   副本与 `rtl/` 不一致时（同步漏了、或有人手改副本）本脚本的结论**对 TD 不成立**。
   （2026-11-02 实踩：改完接线跑 TD 得 `PASS-elaborate`，实际编的是 15:24 的旧副本。）

**脚本的退出码已改成可判**：`0` = `NO_SUCH_PORT` 为 0 且自检通过；
`1` = 有端口名对不上、或自检失败、或出现**意外的** `UNKNOWN_MODULE`。

> **★ `UNCONNECTED` 也有白名单（2026-11-02 captain 要求补）**：与 `UNKNOWN_MODULE` 同理 ——
> 一条「预期内的非零」混在提示里，人会习惯性无视整段 `UNCONNECTED`，
> 那时候真漏接也看不出来。当前唯一白名单条目：
> `('gallery_probe', 'u_gallery', 'rle_lba', 'rle_size', 'rle_found', 'rle_fail')` ——
> t19 新增的四个输出，t7-B 例化 `u_rle` 时才接。
> **t7-B 接完请把这一条从白名单删掉** —— 删时会看到它从「预期 4」
> 变「意外 0」再到「无此条」，那就是对的。

**当前完整输出**（`python scripts\check_port_names.py`，2026-11-02 17:5x）：
```
*** NO_SUCH_PORT = 0 (全部端口名都存在) ***
    UNKNOWN_MODULE = 2（其中预期 2：IP/加密件；**意外 0**）
    UNCONNECTED    = 1（其中预期未接 1；**意外未接 0**）
RESULT: PASS        ← 退出码 0
```

**三条反证已验证均能正确判 FAIL**（且逐条列出原因，不再只报「自检未通过」）：
| 反证输入 | 结果 |
|---|---|
| 漏接一个非白名单端口 | `RESULT: FAIL` / 原因「意外 UNCONNECTED = 1」/ `EXIT=1` |
| 端口名不存在 | `RESULT: FAIL` / 原因「NO_SUCH_PORT = 1」/ `EXIT=1` |
| 真实工程 | `RESULT: PASS` / `EXIT=0` |

> **白名单写死在脚本里**：`EG_PHY_SDRAM_2M_32`（原厂 SDRAM 软核）与
> `hdmi_1_4b_transmitter_core_wrapper`（HDMI 加密件）属**预期、不是待修项**，
> 输出里会标成「预期(IP/加密件)」。除这两个之外出现任何
> `UNKNOWN_MODULE`，才说明有人例化了 `rtl/` 里没有的模块 —— 那才是真问题。
> （为什么不直接把这两条从输出里隐藏：留着可见，将来真多出一个未知模块时能一眼看出来。）

### 4.1d ★★ 校验器被反证抓出的四条自身缺陷

这条留档是为了提醒：**写一个新判据工具时，工具本身也需要反证测试**。

> ⚠ **分类不能混**：下表前三条是 **脚本本身的缺陷**（修脚本），
> 第四条是 **测试方法的缺陷**（脚本没错，是反证构造失效）。
> 不标注分类的话，将来有人会以为校验器还有四个 bug。

| # | 类别 | 缺陷 | 怎么发现的 | 现象如果没发现 |
|---|---|---|---|---|
| 1 | 脚本 | 解析 `input wire pix_clk, rst_n_pix,` 这种**一条声明列多名**时截断在第一个逗号 | 第一版跑出 **13 条 `NO_SUCH_PORT`**，全是 `image_player` 的 `rst_n_pix`/`out_h`/`sdram_cke` 等**真端口** | 会把 13 个正常端口当错误去"修"，把对的代码改坏 |
| 2 | 脚本 | `ROOT` 硬编码为工程路径，**完全忽略命令行参数** | 反证测试（指向一个故意错接的临时目录）**返回了 `PASS` / `EXIT=0`** | 测试命令会永远绿，而真实工程改坏了也不知道 |
| 3 | 脚本 | `.port()` **空括号被当成「已接」**（captain 抓到，详见 §4.1e） | 把 4 处 `.vol_lvl(vol_lvl)` 改成 `.vol_lvl()` 后仍返回 `PASS` / `EXIT=0` | 「偷懒修法」最自然的写法就是 `.port()`；t7-B 写 `.win_w()` 会一路绿到上板，Key9 按下画面不变 |
| 4 | **测试方法**← **不是脚本缺陷** | **反证构造本身失效**：整行删除正则在「行内并列」上一个也没匹配到，变异根本没注入 | 反证 4 第一版报 `PASS`，但副本里 `.vol_lvl` 计数**仍是 4**（没变）—— 数一数发现注入失败 | 会把「变异没注入」当成「判据不灵」，去修一个根本没错的脚本（详见 §4.1e-5） |

> **通用教训**：一个「永远返回通过」的判据工具，比没有工具更危险 ——
> 它会让人放弃本来会做的人工核对。任何新判据都必须配一个
> **已知会失败的输入**做反证（这与 `T3_CJK_TICKER.md` §9.6「断言要朝失败时变红的方向设计」
> 是同一条纪律：那次是 `!==` 在 `mem=xxxx` 时把未装载统计成 7440 个非零行反而通过）。


### 4.1e ★★★ 第五条盲区：`.port()` 空括号会被当成「已接」（captain 抓到，2026-11-02）

**复现**（把 4 处 `.vol_lvl(vol_lvl)` 全改成 `.vol_lvl()`）：
```
改动前  .vol_lvl(vol_lvl)  出现 4 次
改动后  .vol_lvl()        出现 4 次
结果    RESULT: PASS / EXIT=0        ← 漏了！
对照    整条删掉 .vol_lvl(vol_lvl),   → RESULT: FAIL / EXIT=1   ← 能抓到
```

**根因**（原 `:171-180`）：`re.match(r'\s*\.\s*(\w+)\s*\(', part)` 只看「有没有
`.名字(`」，**不看括号里有没有东西** → `vol_lvl` 被算进 `used`，
不会进 `missing`，`UNCONNECTED` 逻辑就覆盖不到。

**为什么这条最危险**：Verilog 里 `.port()` 是**合法语法**，等价于「不接」
（input 悬空为 `z`）。而**「偷懒修法」最自然的写法就是 `.port()`** ——
t7-B 里如果有人写 `.win_w()` 而不是 `.win_w(k9_win_w)`：
`check_port_names` 判 PASS → `vlog` 不报（§4.1c）→ TD `elaborate` 也不报（当隐式网）
→ **一路绿到上板**，现象是 Key9 按下去画面不变
（`win_w` 恒 0 → `in_win_x` 恒假 → 整屏黑边）。

**修法**：把空括号单独归一类 `EMPTY_CONN`，**不计入 `used`**（这样它同时也会进
`missing`，被 `UNCONNECTED` 逻辑覆盖）：
```python
pe = re.match(r'\s*\.\s*(\w+)\s*\(\s*\)\s*$', part)   # 先判空括号
if pe:
    pn = pe.group(1); empty.add(pn)
    if pn not in mod_ports[mod]:
        problems.append(("NO_SUCH_PORT", mod, inst, pn + "  (空括号但模块无此端口)"))
    continue
pm = re.match(r'\s*\.\s*(\w+)\s*\(', part)              # 再判正常连接
...
if empty:
    problems.append(("EMPTY_CONN", mod, inst, ",".join(sorted(empty))))
missing = mod_ports[mod] - used - empty
```

**白名单 `EXPECTED_EMPTY`**：顶层现有 **21 处有意空连接**（脚本能扫到的，另有 3 处
在 `hdmi_core` 上但它是加密件、脚本跳过，合计 24）：
`key_matrix_4x4 u_key{.key_state}` / `key_router u_keyrouter{.audio_en,.ticker_en,.osd_pop_req,.osd_item}` /
`player_ctrl u_ctrl{.mode,.status_led}` / `video_timing_gen u_vtg{.hs,.frame_start}` /
`thermal_guard u_thermal{.oth_enter,.oth_exit,.temp_alive}` /
`image_player u_player{.ext_wr_ack,.ext_wr_busy,.ext_frame_ready,.ext_frame_sel,.ext_loader_want_blk}` /
`audio_src_mux u_audio_src{.eff_audio_en}` / `wav_stream_player u_wav{.err_code,.fifo_level}` /
`brightness_apply u_bright{.de_out}` / `hdmi_core u_hdmi_core{.O_edid_read_valid,.O_edid_read_data,.O_axis_s_ready}`。

> **白名单的价值不在「列出来」，而在「以后新增的空连接必须显式进白名单」**
> —— t7-B 每加一根线都会被这里提醒一次。新增一条前请先在顶层写好理由注释。

**四条反证**（2026-11-02 18:0x 实测）：
| 反证输入 | 期望 | 实测 |
|---|---|---|
| `.vol_lvl(vol_lvl)` ×4 → `.vol_lvl()` ×4 | FAIL | `意外空连接 4` / **EXIT=1** ✅（报出 `vol_apply u_vol` / `osd_autopop u_osd_pop` / `osd_panel u_osd_panel` / `key_router u_keyrouter` 四个实例） |
| 从 `EXPECTED_EMPTY` 临时删掉 `key_router` 条目 | FAIL | `意外空连接 1` / **EXIT=1** ✅（证明白名单按端口精确匹配，不是按模块整体放行） |
| `.src_w(16'd640)` → `.src_w()` | FAIL | `意外空连接 1` / **EXIT=1** ✅（报出 `image_player u_player`） |
| **对照**：整条删掉 `:783` 的 `.vol_lvl(vol_lvl),`（连名字都不写） | FAIL | `意外未接 1` / **EXIT=1** ✅（两种写法都能抓到了） |
| 真实工程 | PASS | `EMPTY_CONN = 9 个实例 / 21 个端口（有意 9；意外 0）` / **EXIT=0** ✅ |

> **口径提醒**：`UNCONNECTED`（连名字都不写）与 `EMPTY_CONN`（写了名字但空括号）
> 在 Verilog 里语义**基本等价**，但一个能抓一个抓不到 ——
> **「两种写法一严一松」的判据比完全没判据更容易骗人。**

修复后的**双向验证**（2026-11-02 17:52 实测）：
- 反证（`sub` 只有 `bright_lvl`，被 `.bright_sel()` 例化）→ `NO_SUCH_PORT = 1`、`RESULT: FAIL`、**`EXIT=1`** ✅
- 正测（真实工程）→ `NO_SUCH_PORT = 0`、`RESULT: PASS`、**`EXIT=0`** ✅


### 4.1e-5 ★★★「反证方法本身也需要自检」（captain 升格为第六条工具盲区，比前五条更根本）

**事件**：我做上面表格里那个「对照」反证时，第一版用的是**整行删除**：
```powershell
# 失败的写法（不要照抄）
$c -replace '(?m)^\s*\.vol_lvl\(vol_lvl\),\r?\n', ''
```
但顶层那四处全部是**行内并列**：
```verilog
146:  .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),
783:  .vol_lvl(vol_lvl), .mode(mode), .audio_en(audio_en_eff),
860:  .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),
909:  .bright_lvl(bright_lvl), .vol_lvl(vol_lvl),
```
正则一个也没匹配上，副本里 `.vol_lvl` 计数**仍是 4** ——
于是那次输出的 `RESULT: PASS / EXIT=0` 是**变异根本没注入**，**不是脚本漏判**。

改成只删 `:783` 那一处的 `-replace '\.vol_lvl\(vol_lvl\), \.mode', '.mode'`，
计数 **4 → 3**，立即 `RESULT: FAIL / EXIT=1`。

> **为什么它比前五条更根本**：前五条说的是「**判据失灵**」，
> 这一条说的是「**你以为你在做反证，其实什么也没注入**」。
> 两者的表现形式**完全一样**（都是 `PASS`），**无法从事后结果区分**。
> 它直接推翻了我们一直在用的那句「反证注入后若红的条数明显少于预期，
> 第一反应是 tb 根本没跑到那条」—— 那个规则**默认了「变异一定注入了」**，
> 而这一条说明**这个前提本身会失效**。

**通用规则（captain 2026-11-02 定口径，全项目执行）**：
> 每条反证必须**同时给出两个数**：
> ① **变异注入前的特征计数**（如「`.vol_lvl(vol_lvl)` 出现 4 次」）
> ② **变异注入后的特征计数**（如「`.vol_lvl()` 出现 4 次」）。
> **只有两个数不同，这次反证才算数。**
> 只贴「注入后 RED 了 N 条」而不贴注入前后计数的反证，**一律视为未完成**。

> **captain 自述**：他自己的四条反证之所以没踩到，是因为改的是**短片段**
> （`.panel_on(panel_on)` → `.panel_onx(panel_on)`），替换点唯一且能直接数出现次数 ——
> **「不是我聪明，是我碰巧用了不会失配的写法」**。
> 而「整行删除」才是大家自然会写的写法。

**进 t9 清单时的写法**：写成「**反证方法本身需要自检**」，
**不要**写成「注意正则别写错」这种细节提示 —— 前者是方法论，后者只是一条易忘的技巧。
### 4.1f ★★★ `place` 失败：mslice 5,306 > 上限 4,900 —— 定量化与十组参数排查（2026-11-02 实跑）

t7-B 第一次跑 `t7b_bit.tcl`，前八步全 PASS，第九步 `place` 硬失败：

```
PHY-9009 ERROR: Design's mslice number = 5306, exceeds the limit 4900.
There are more MSlices exceeding the limit of the device. You can try using
'report_area' in console to check the resource utilization of the device and
results of Optimize Gate stage. And you can try modifying the design or
changing the strategy of syn and rerunning it.
```

看到 `#lut 19353 / 19600 (98.74%)` 时，第一反应必然是「逻辑写太多了，要砍功能」。
**这个反应是错的** —— 本次排查证明真正可控的是「LUT 以什么形式存在」，不是「LUT 有多少个」。

> **⚠ 本节在 2026-11-02 19:3x 曾有一个错误版本**（标题写「mslice 打包密度被 HFN 复制腰斩」，并把 `set_param -run` 写成生效通道）。
> 两处都已被实跑推翻，现版本是修正后的。**错误归因的完整记录保留在 §4.1f.3，不要跳过它** —— 它比正确结论更有教学价值。

#### 4.1f.1 先把算术立起来（全节唯一硬判据）

```
器件 LUT 槽位总数   = 19,600
mslice 上限         = 19,600 ÷ 4 = 4,900        （每 mslice 最多 4 个 LUT 槽位）
实测 place mslices  = 5,306
⇒ 打包率            = 19,353 ÷ 5,306 = 3.647 槽位/mslice
⇒ 要过 place 需要   #lut ≤ 4,900 × 3.647 ≈ 17,870
```

交叉验算（独立来源，不是同一份报告）：`report_qor` 报 `#slices 4021 / 41.03%` ⇒ `4021 ÷ 0.4103 = 9,800 = 4,900 + 4,900`，与上式 4,900 完全一致。

**这条算术推出两个结论**：

1. 要过 `place`，`#lut` 必须从 19,353 砍到约 **17,870**，即砍掉 **约 1,480 个槽位**。
2. 即使把打包率提到理论完美值 4.000，`19,353 ÷ 4 = 4,838` —— 只剩 62 个 mslice 余量，**等于过不了 route**。所以「想办法把打包率提上去」这条路本身不成立。

> **`#lut` 的口径（必须写清，否则数字会被误读）**：`#lut = #Total_luts + ripple`，本轮 `11,282 + 8,071 = 19,353`。
> `#Total_luts` 是独立查找表逻辑，`ripple` 是进位链把 LUT 内部专用通道也占掉的槽位。**两者都是真实逻辑**，
> 不能用「`#Total_luts` 只有 11,282」来论证 LUT 还很空。

#### 4.1f.2 5,306 到底在哪一行产生的（观测点）

`place` 日志里 `mslices` 只出现四次：

| 行 | 阶段 | mslices |
|---|---|---|
| `:153` | Stage 1.1 Build Design | 2,651 |
| `:157` | Stage 1.1 去冗余后 | 2,651 |
| `:194` | Stage 1.3 Initialize Clock | 2,651 |
| **`:424`** | **Stage 2.8.1 Packing** | **5,306** |
| `:432` | `PHY-9009 ERROR` | 5,306 |

Packing 段原文（`:411-424`）：

```
PHY-1001 : Stage 2.8 | Place Packing
PHY-1001 : Stage 2.8.1 | Packing
SYN-4007 : Packing 0 MUX to BLE ...
SYN-4008 : Packed 0 MUX and 0 SEQ to BLE.
SYN-4007 : Packing 11282 LUT to BLE ...
SYN-4008 : Packed 11282 LUT and 4775 SEQ to BLE.
SYN-4003 : Packing 3976 remaining SEQ's ...
SYN-4005 : Packed 3007 SEQ with LUT/SLICE
SYN-4006 : 3869 single LUT's are left
SYN-4006 : 969 single SEQ's are left
SYN-4011 : Packing model "dmz_eg4s20_hdmi_top" (AL_USER_NORMAL) with 12251/16457 primitive instances ...
RUN-1001 : There are total 10797 instances
RUN-1001 : 5306 mslices, 5306 lslices, 102 pads, 35 brams, 24 dsps
```

**可核对的事实三条**：

1. 2,651 → 5,306 的跃变**发生在 Stage 2.8.1 Packing**，`Stage 2.7.1` 阶段日志里没有任何 mslice 数字。
2. 打包日志明确报出 **`3869 single LUT's are left`** —— 3,869 个 LUT 找不到配对；配不成对的 LUT 会独占 mslice 槽位，这是打包率从 4.25 掉到 3.647 的直接来源。
3. `Packed 11282 LUT and 4775 SEQ to BLE` / `Packed 3007 SEQ with LUT/SLICE` —— 打包是 LUT 与 SEQ 混合进行的。

> **⚠ 一个容易犯的算术错误（我自己犯过，这里留档）**：不能写「2,651 + 3,869 ≈ 5,306」。
> `2,651 + 3,869 = 6,520 ≠ 5,306`。2,651 是 **gate 阶段的 mslice 数**，3,869 是 **packing 阶段剩余的单个 LUT 数**，
> 两者不是同一计数维度，不能相加。mslice 最终数目由 BLE 打包模型（LUT/SEQ 混合、mslice 内槽位分配）决定，
> 只知道 3,869 不足以反推 5,306。**本节只断言上表三条可核对事实，不给出「分解公式」。**

#### 4.1f.3 错误归因记录（HFN 复制说，已被实测推翻）

初版把根因写成「`Stage 2.7.1 Synthesize High-fanout Net` 的 HFN 复制把 LUT 打散」。**这是错的**，反证如下。

`%TEMP%\t7b_ab_base.log:352-364` 的 HFN 统计表原文：

```
RUN-1001 : HFN opt statistic
  DriverCell type  |  HFN count  |  Duplicated count
        REG        |     37      |        541
       LUT6/LUT5/LUT4/LUT3/LUT2 | 0 |      0
        TOTAL      |     37      |        541
OPT-1001 : End high-fanout net optimization;  18.543414s wall
```

**只复制了 37 个源、541 个副本**，与 2,655 个 mslice 的差**差一个数量级**；且 Stage 2.7.1 全程没有任何 mslice 数字（见 §4.1f.2 表）。

⇒ 「HFN 复制把打包密度打散」这句话从今天起**不许再写进任何报告**。

为什么这个错误归因很危险：它指向的修复手段（`hfn_opt_effort`）实测**完全无效**（见 §4.1f.5 第 2、3 组）。
如果按它去调参数，会连续烧掉几小时而看不出任何变化，最后误判成「这板子就是装不下」。

#### 4.1f.4 参数通道：四种写法，只有一种生效（第七条工具盲区）

| 写法 | 是否写进 `.al` | 是否改变引擎行为 | 证据 |
|---|---|---|---|
| `set_param -run phy_1 place <p> <v>` | **写** | **不改** | 五次运行 `OPT-1001 ... with medium effort` 全 medium；`.al` 里 `<PlaceProperty><effort>high</effort>` 在位也没用 |
| `.al` 手写 `<RtlProperty><min_ripple_len>18</...>` | 在文件里 | **不改** | 基线 19,353 就是带着它跑出来的 |
| `set_param <step> <p> <v>`（无 `commit_param`） | 不写 | 不改 | — |
| **`set_param <step> <p> <v>` + `commit_param -step <step>`** | **不写**（`.al` MD5 一字节未变） | **改** ✅ | `OPT-1001` 档位词随之变化 |

官方语法出处 `D:\TD_6_24_APP\doc\scripts\DefaultFlow.tcl`：`:77` `set_param <step> <param> <val>`（三参数，**没有 `-run`**）；
`opt_place_fun` = `commit_param -step place` → `place`；`opt_gate_fun` = `commit_param -step gate` → `optimize_gate`；
`:65` `load_run_param -run ${alRun}` 是**唯一**带 `-run` 的参数类命令。

三条反证（`project\t7b_param_validate.tcl`，日志 `%TEMP%\t7b_validate.log`）：

| 反证 | 注入 | TD 反应 | 说明 |
|---|---|---|---|
| 参数名瞎写 | `set_param -run phy_1 place pack_mode_typo_xyz more_lut_pair` | `PRJ-1106 : Update wild param ... succeed.` | **不校验参数名** |
| 取值瞎写 | `set_param -run phy_1 place pack_mode this_value_does_not_exist` | `PRJ-1105 : Update param ... succeed.` | **不校验取值** |
| step 名瞎写 | `set_param -run phy_1 place_typo_xyz pack_mode more_lut_pair` | `PRJ-9004 ERROR: Step place_typo_xyz is not valid.` | 只校验 step 名 |

⇒ **`PRJ-1105 ... succeed` / `PASS-set_param` 绝对不能作为「参数生效」的证据。**
唯一有效证据是引擎自己的行为描述行（如 `OPT-1001 ... with <X> effort`）。

> **⚠ 事故留档**：`t7b_param_validate.tcl` 第一版直接对着真工程跑，把假值 `pack_mode = this_value_does_not_exist`
> **持久化写进了 `project\hdmi_td.al:582`**（`set_param -run` 会落盘）。已从 `hdmi_td.al.bak_t7b_place`
> （25,398 B / MD5 `AE3BA64CB5FB128B7DFD741D40DFD4F0`）恢复，污染现场留 `hdmi_td.al.bak_polluted_1901`。
> **规矩：反证脚本一律在工程副本上跑，绝不碰真工程 `.al`。**

#### 4.1f.5 十组单变量实验（全表，含失败的）

| 组 | 参数 | 跑法 | `#Total_luts` | `#lut` | gate slices% | single LUT | place mslices | place 后 WNS | place |
|---|---|---|---|---|---|---|---|---|---|
| 基线 | （无） | 全流程 | 11,282 | 19,353 (98.74%) | 41.03% | 3,869 | **5,306** | — | ❌ 超 406 |
| — | `hfn_opt_effort low` | import_db | 11,282 | 19,353 | 41.03% | 4,066 | 5,276 | — | ❌ 超 376 |
| — | `hfn_opt_effort high` | import_db | 11,282 | 19,353 | 41.03% | 3,830 | 5,313 | — | ❌ 超 413 |
| — | `pack_mode more_lut_pair` | import_db | 11,282 | 19,353 | 41.03% | 3,869 | 5,306 | — | ❌ 与基线逐字相同 |
| — | `shifter_style shifter_reg` | 全流程 | 11,282 | 19,353 | 41.03% | 3,869 | 5,306 | — | ❌ 与基线逐字相同 |
| A | `gate mapper_lut_delay 1600` | 全流程 | — | — | 41.03% | 3,592 | 5,237 | — | ❌ 超 337 |
| B | `rtl min_ripple_len 8` | 全流程 | 11,372 | 19,039 | 38.97% | 3,906 | 5,151 | — | ❌ 超 251 |
| C | `rtl min_ripple_len 18` | 全流程 | 12,433 | 18,062 (92.15%) | 28.57% | 4,701 | 4,956 | — | ❌ 超 56 |
| **D** | **`rtl min_ripple_len 30`** | 全流程 | 13,885 | **17,744 (90.53%)** | 19.54% | 5,753 | **4,849** | **−1,973 ps** | ✅ 留 51 |
| **E** | **`rtl min_ripple_len 45`** | 全流程 | 15,020 | **17,645 (90.03%)** | 13.24% | 6,642 | **4,801** | **+1,357 ps** | ✅ 留 99 |

**五条结论**：

1. `hfn_opt_effort` **通道确实通了**（`low` → single LUT 涨到 4,066 / mslices 降到 5,276；`high` → single LUT 降到 3,830 / mslices 涨到 5,313 —— **两数反向变化**，排除了「被接受但被忽略」和「无关因素碰巧」两种解释），**但效果为零**：最好只降 30，距需要的 376 差一个数量级。
2. `pack_mode more_lut_pair` / `shifter_style shifter_reg` **输出与基线逐字相同** ⇒ TD 6.24 上这两个参数无效。
3. **`min_ripple_len` 是唯一有效的，且单调**：8 → 5,151 / 18 → 4,956 / 30 → 4,849 / 45 → 4,801。
4. **机制不是「拆东墙补西墙」，是「换存在形式」**：`#Total_luts` 从 11,282 **涨**到 15,020，而 `#lut` 从 19,353 **降**到 17,645 —— 把进位链形式占掉的槽位（ripple）转成独立 LUT4/LUT5。这正是 §4.1f.1 算术里「砍 1,480 槽位」唯一被实现出来的途径。
5. 打包率同时改善：`19,353 ÷ 5,306 = 3.647` → `17,645 ÷ 4,801 = 3.675`。

#### 4.1f.5b 时序阶段的参数：三组全试，结果**逐字相同**

`place` 通过后卡在时序（`SWNS −0.183 ns` / `HWNS −0.020 ns`）。captain m02634 判断这是**布线拥塞把单元拉散**
（主违例路径 `cell 15.253ns ÷ 36 级 = 0.42 ns/级` 正常，`net 24.650ns ÷ 35 段 = 0.70 ns/段` 异常），
所以试的是 place/route 侧参数（不是砍 RTL）。三组并行跑，每组独立 log：

| 组 | 额外参数 | `#lut` | place mslices | route mslices | single LUT | **place 耗时** | **route 耗时** | SWNS | HWNS |
|---|---|---|---|---|---|---|---|---|---|
| 基线（`t7b_bit2.tcl`） | 无 | 18,473 | 4,805 | 4,792 | 6,766 | **72.35 s** | — | −0.183 | −0.020 |
| V1_ppo | `place post_place_opt high` | 18,473 | 4,805 | 4,792 | 6,766 | **183.79 s** | 458.77 s | −0.183 | −0.020 |
| V2_pro | `route post_route_opt high` | 18,473 | 4,805 | 4,792 | 6,766 | **184.18 s** | 459.85 s | −0.183 | −0.020 |
| V3_all | 上面两条 + `route fix_hold on` | 18,473 | 4,805 | 4,792 | 6,766 | **183.23 s** | 459.51 s | −0.183 | −0.020 |

**参数确实进了引擎**（这不是「参数没生效」，证据三条）：

1. 参数表回读显示 `Settings` 列已偏离默认值：`post_place_opt | high | auto | *`（带 `*` 标记 = 非默认）、`fix_hold | on | on`（默认本来就是 on，显式写死无变化）。
2. **place 耗时从 72.35 s 涨到 183.79 s（2.54 倍）**、route 从无到 458.77 s —— 引擎确实多做了迭代，不是忽略了参数。
3. 三组之间 place 耗时互不相同（183.79 / 184.18 / 183.23），说明参数**分别**起了作用。

**但所有结果量逐字相同**：`4,805 / 4,792 mslices`、`6,766 single LUT`、`SWNS −0.183`、`HWNS −0.020`。

⇒ **结论：`post_place_opt` / `post_route_opt` / `fix_hold` 这组参数对本题无效。** 引擎花了 2.5 倍时间做优化，
但优化空间为零 —— 说明 **`place` 已经把能做的做完了，剩下的 0.183 ns 不是「优化不够努力」**。

这与 captain m02634 的判断（拥塞导致 net 拉长）不矛盾：**拥塞是结果，不是可调参数能解决的**。
net 0.70 ns/段 的根源是 `#lut 18,473 / 19,600 = 94.25%` 的填充率把布线资源挤干了 ——
**唯一有效的手段是降 LUT**（即 §5 #1e 的备选：`u_pix_fifo` 改同步读，−1,577 LUT，或 t24 的 RTL 方案）。

#### 4.1f.5c 全参数实验总表（13 组，答辩材料）

**这张表是「逐个用日志证据否掉」的完整记录**。captain m02634 要求保留 —— 答辩时「试了十三组、每组都有数字」比「一次就成功」可信。

| # | 参数组合 | `#Total_luts` | `#lut` | single LUT | place mslices | place 后 WNS | 最终 SWNS | 最终 HWNS | 结论 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **基线（无参数）** | 11,282 | 19,353 (98.74%) | 3,869 | **5,306** | — | — | — | place FAIL 超 **406** |
| 2 | `place hfn_opt_effort low` | 11,282 | 19,353 | 4,066 | 5,276 | — | — | — | place FAIL 超 376 |
| 3 | `place hfn_opt_effort high` | 11,282 | 19,353 | 3,830 | 5,313 | — | — | — | place FAIL 超 413 |
| 4 | `place pack_mode more_lut_pair` | 11,282 | 19,353 | 3,869 | 5,306 | — | — | — | **逐字同基线** |
| 5 | `rtl shifter_style shifter_reg` | 11,282 | 19,353 | 3,869 | 5,306 | — | — | — | **逐字同基线** |
| 6 | `gate mapper_lut_delay 1600` | — | — | 3,592 | 5,237 | — | — | — | place FAIL 超 337 |
| 7 | `rtl min_ripple_len 8` | 11,372 | 19,039 | 3,906 | 5,151 | — | — | — | place FAIL 超 251 |
| 8 | `rtl min_ripple_len 18` | 12,433 | 18,062 | 4,701 | 4,956 | — | — | — | place FAIL 超 **56** |
| 9 | `rtl min_ripple_len 30` | 13,885 | 17,744 | 5,753 | **4,849** | **−1,973 ps** | — | — | place PASS，但 WNS 负 |
| **10** | **`rtl min_ripple_len 45`** ★ | 14,985 | **18,473** | 6,766 | **4,805** | **+1,357 ps** | **−0.183** | **−0.020** | **place PASS；时序差 0.183 ns** |
| 11 | `rtl min_ripple_len 60` | 15,316 | 17,643 | 6,896 | 4,786 | — | **−0.689** | −0.011 | **时序更差（−0.689）** |
| 12 | `rl45` + `gate mapper_lut_delay 2200` + `gate merge_tiny_lut on` | **14,360** | **16,985 (86.66%)** | 6,105 | 4,796 | — | — | — | **route FAIL**（`PHY-8023` 拥塞） |
| 13 | `rl45` + `place post_place_opt high` | 14,985 | 18,473 | 6,766 | 4,805 | — | −0.183 | −0.020 | **逐字同 #10** |
| 14 | `rl45` + `route post_route_opt high` | 14,985 | 18,473 | 6,766 | 4,805 | — | −0.183 | −0.020 | **逐字同 #10** |
| 15 | `rl45` + 上面两条 + `route fix_hold on` | 14,985 | 18,473 | 6,766 | 4,805 | — | −0.183 | −0.020 | **逐字同 #10** |
| 16 | `rl45` + `place hfn_opt_effort high` | 14,985 | 17,610 | 6,772 | 4,827 | — | **−0.373** | −0.011 | **负优化（恶化 0.190）** |
| 17 | `rl45` + #12 全部 + `route effort routability` | **14,360** | **16,985 (86.66%)** | 6,105 | 4,796 | — | **−1.192** | −0.009 | **route PASS 但时序最差** |

**四条从表里读出来的硬结论**：

1. **`min_ripple_len` 是唯一能降 `#lut` 的旋钮**（#7~#11 单调：19,039 → 18,062 → 17,744 → 18,473 → 17,643）。
   注意 **#10 的 `#lut 18,473` 比 #9 的 17,744 高** —— 因为 gate 阶段口径变了（`#Total_luts` 从 13,885 涨到 14,985），
   两个数的和才是真占用。**跨组比较必须同时看 `#Total_luts` 与 `#lut`，只看一个会得出错误结论。**
2. **`hfn_opt_effort` 通道通了但效果为零**（#2/#3：single LUT 反向变化 4,066 ↔ 3,830，mslices 反向 5,276 ↔ 5,313，说明参数真的生效了；但最好只降 30，距需要 376 差一个数量级）。
   **到了时序阶段它变成负优化**（#16：SWNS −0.183 → −0.373，见 §4.1f.5d）。
3. **`pack_mode` / `shifter_style` 在 TD 6.24 上完全无效**（#4/#5 与基线逐字相同）。
4. **时序阶段的三组 place/route 参数全部无效**（#13~#15 与 #10 逐字相同），且 place 耗时涨 2.54 倍 —— 引擎确实多做了迭代，但**优化空间为零**。
   相反 **#11（rl60）把 setup 从 −0.183 恶化到 −0.689**、**#12 直接 route 失败**、**#16 恶化到 −0.373**、**#17 恶化到 −1.192** ——
   说明「多给优化资源」不但没用，还可能更差。**`place` 阶段已经把能做的做完了。**

> **⚠ #12 值得单独记一笔**：它是**唯一把 gate 阶段 `#lut` 压到 16,985（86.66%）** 的组合（`#Total_luts` 也从 14,985 降到 14,360），
> 但 route 报 `PHY-8023 ERROR: Location: (x29y33_local3), nets: u_player/timer[24] u_player/u_arb/app_wr_en` + `RUN-8102 ERROR: Incremental route failed`。
> **面积最小 ≠ 能布线** —— `merge_tiny_lut` 把小 LUT 合并后单元更集中，反而在局部造成拥塞。
> #17 配 `route effort routability` 后 route 通过了，但时序恶化到 −1.192 —— **routability 模式能解拥塞，代价是 net 更长**。

#### 4.1f.5d 降扇出/降逻辑层级这条路，实测是**负相关**（关键诊断）

七组参数的主违例路径完整诊断量。**这是全文档最有诊断价值的一张表** ——
它回答的是「布线拥塞能不能靠 place 参数救」，答案是**不能，而且会反噬**。

| 组 | SWNS | HWNS | Data Path Delay | cell | net | Logic Level | **cell/级** | **net/段** | **Max Fanout** |
|---|---|---|---|---|---|---|---|---|---|
| **#10 基线 rl45** | **−0.183** | −0.020 | 39.903 ns | 15.253 (38%) | 24.650 (62%) | 36 | 0.424 | **0.704** | **144** |
| #13 `post_place_opt high` | −0.183 | −0.020 | 39.903 | 15.253 | 24.650 | 36 | 0.424 | 0.704 | 144 |
| #14 `post_route_opt high` | −0.183 | −0.020 | 39.903 | 15.253 | 24.650 | 36 | 0.424 | 0.704 | 144 |
| #15 上面 + `fix_hold on` | −0.183 | −0.020 | 39.903 | 15.253 | 24.650 | 36 | 0.424 | 0.704 | 144 |
| #11 `rl60` | −0.689 | −0.011 | 40.409 | 16.724 | 23.685 | 35 | 0.478 | 0.697 | **127** |
| #16 `hfn_opt_effort high` | **−0.373** | −0.011 | 40.093 | **14.094** | **25.999** | 35 | **0.403** | **0.765** | **138** |
| #17 #12 + `route routability` | **−1.192** | −0.009 | 40.912 | 14.604 | **26.308** | **33** | 0.443 | **0.822** | **121** |

**读表三条**：

1. **`hfn_opt_effort high`（#16）把扇出从 144 降到 138、逻辑层级从 36 降到 35、cell 从 15.253 降到 14.094 ns（−1.159 ns）** ——
   **但 net 从 24.650 涨到 25.999 ns（+1.349 ns）**，net/段 从 0.704 升到 0.765。
   降扇出的 cell 收益被 net 恶化全部吃掉还倒亏 0.190 ns。**这是负优化，不是「效果有限」。**
2. **#17 把 Max Fanout 压到 121、Logic Level 压到 33（全七组最低），但 net/段 升到 0.822（全七组最高）。**
   ⇒ **「逻辑层级最少 + 扇出最小」与「net 最短」在这颗器件上是反相关的。**
   机制：HFN 复制/合并小 LUT 让单元更集中 → 局部拥塞 → 布线绕远 → net 变长。
3. **七组的 Begin/End 点全都不同**：

| 组 | Begin Point | End Point |
|---|---|---|
| #10 基线 | `u_overlay/u_caption/u_narr/addr[9]_syn_208` | `u_axis/video_data_reg[6]` |
| #11 rl60 | `u_overlay/u_caption/u_narr/addr[9]_syn_214` | `u_axis/video_data_reg[22]` |
| #16 hfn_high | **`u_vtg/active_x_reg[1]`** | **`u_axis/rgb[4]_syn_60`** |
| #17 routability | **`u_rle/frame_idx_b2[15]`** | `u_axis/video_data_reg[20]` |

   ⇒ **每次换参数，最差路径就换一条。** 说明整个 clk0 域（5,047~5,175 个触发器、25 MHz、Fmax 24.277~24.886 MHz）
   **普遍贴近临界，不是某一条路径拖后腿**。这直接推出两个结论：
   - 针对单条路径做结构性优化（若只针对 `osd_strings` 那条）收益有限；
   - **必须整体降 LUT**（§5 #1e 与附录 A0 的 `u_pix_fifo` 方案）。

**判据「net 段是否从 0.70 ns/段降下来」的答案：七组全部没有。** 最低是 #11 的 0.697（降 0.007，噪声级），其余全部**上升**（#16 0.765 / #17 0.822）。


#### 4.1f.6 选 30 还是 45：中间态 WNS 陷阱

D 组（30）余量 51 个 mslice，E 组（45）余量 99 个 —— 按「够用就好」的直觉该选 30。
**但 D 组 place 后 WNS 是 −1,973 ps，E 组是 +1,357 ps。**

**陷阱**：只看 `place` 是否 PASS，D 组也 PASS（4,849 ≤ 4,900），会以为选它更省资源。
但 place 阶段 WNS 已经 −1,973 ps，说明这条路在物理上收敛不了 —— **`place` 通过 ≠ 设计可实现**。
选 E（45）不是「多花资源」，是**唯一能继续往下走的解**。

反过来也说明另一件事：`min_ripple_len` 增大不只省面积，**同时改善时序**（−1,973 → +1,357，差 3,330 ps）。
这与「面积换时序」的直觉相反，原因是 ripple 进位链本身就是关键路径。

#### 4.1f.7 迭代成本（为什么这件事在时间上成立）

| 步骤 | 实测耗时 |
|---|---|
| `optimize_rtl` | 89.15 s |
| `optimize_gate` | **94.21 s** |
| `place` | 72.35 s（`import_db` 单独跑 60.7 s） |
| 全流程 `t7b_bit.tcl`（到 place 失败为止） | **4.3 min** |
| 全流程到出位流（`t7b_bit2.tcl`，含 route/时序） | **784.9 s ≈ 13 min** |

> **⚠ 口径更正**：本节初版写「`optimize_gate` ≈ 1.9 h」。**错了** —— 那是 t7-A 时 `t7a_gate_area.tcl` 全流程的量级，
> 不是单步 `optimize_gate`。实测单步 **94.21 s**。这个更正很关键：初版据此认为「参数试错太贵、不值得做」，
> 实际十组实验总共只花了约 45 分钟。

`t7b_bit2.tcl` / `t7b_bit3.tcl` 在 `optimize_gate` 之后立刻 `export_db`，`place` 之后再导一份 ——
`place` 失败可从 gate db 重跑（60 s），`route` 失败可从 place db 重跑。

#### 4.1f.8 本节的判据

| # | 判据 | 怎么判真假 |
|---|---|---|
| F1 | `#lut` 与 mslice 的比值能算出来，且与 `report_qor` 的 `slices%` 交叉验算一致 | `19,353 ÷ 5,306 = 3.647`；`4021 ÷ 0.4103 = 9,800 = 4,900×2`。两式算不出同一个 4,900 → 取错行 |
| F2 | mslice 5,306 能在 `Stage 2.8.1 Packing` 之后抓到，且 `Stage 2.7.1` 前后没有 mslice 数字 | grep `mslices` 只应命中 4 处（见 §4.1f.2 表）；若在 2.7.1 抓到数，说明日志版本不同 |
| F3 | 参数生效性用引擎行为行判，不用 `PRJ-1105` | `OPT-1001 ... with <X> effort` 的 `<X>` 必须变化；`PRJ-1105 succeed` 与生效**无关** |
| F4 | `min_ripple_len` 的效果必须同时看 `#lut` **和** `#Total_luts` | 有效时两数**反向**变化（`#lut` 降、`#Total_luts` 涨）；同向变化说明参数没进引擎 |
| F5 | 选参数时 `place` 后 WNS 必须一起看 | D 组 `place` PASS 但 WNS −1,973 ps；只判 `place` PASS 会选错 |
| F6 | 位流阶段的时序判据不放宽 | `SWNS >= 0 && HWNS >= 0` 两条同时成立才 bitgen；差 0.183 ns 也是 FAIL |

**答辩叙事**（如果被问「为什么砍到 17,645 还能保住功能」）：不是砍功能，是**改 LUT 的存在形式** ——
把 8,071 个被进位链占用的槽位（ripple）转成独立 LUT，`#Total_luts` 反而从 11,282 涨到 15,020。
功能一个没少，`#bram` 还从 34 涨到 35（`narr_en` 接真值后 `narr_subline` 的 1 块 BRAM 不再被常量传播剪掉）。


#### 4.1f.9 ★★★ 最终收敛：`seed=7`（2026-11-03 00:31 实测，**交付位流**）

前面 §4.1f.1~§4.1f.8 讲的是「为什么一开始过不去」，本节是**最终通过并交付的那一次**，
以及从第一次通过（v1）到最终交付（v3）之间**又发生的四次转折**。

> **先纠正一处引用陷阱**：`reports\t7b3_rl45_area.txt` 已被后续尝试**覆盖**过，
> 它 00:20:27 落盘时是 **attA 那趟**的 `#lut 16,400`，**不是最终位流的数**。
> 凡是引「最终位流的资源」，一律写
> **`route 后 #lut 16,414 / 83.74%（来源：reports\t7b_seed_seed7_area.txt，2026-11-03 00:31:36）`**。
> `t7b3_rl45_*` 三份若被引用，必须带「那是 v1 或 attA 那趟」的标签。**两个数差 14，写错就是硬伤。**

##### 一、交付配置（**五个条件，缺一不可复现**）

```
① set_param rtl min_ripple_len 45   +   commit_param -step rtl
② set_param place seed 7            +   commit_param -step place
③ t24   —— OSD 砍组合锥（osd_caption.v / osd_strings.v）
④ t25   —— u_pix_fifo 改 FWFT 同步读（async_fifo.v）
⑤ t26   —— fat32_reader 终态自锁修复（fat32_reader.v）
```

- ①② 是 TD 参数，**必须走三参数 `set_param <step> <param> <val>` + `commit_param -step <step>`**
  （§4.1f.4：`-run` 通道已证伪）。
- ③④⑤ 是 RTL 改动，全部已 sync 进 `project/hdmi/`。
- **时序阶段的三组参数（`place post_place_opt high` / `route post_route_opt high` /
  `route fix_hold on`）一个都没加** —— §4.1f.5b 已实测与基线逐字相同。
- **复现位流只需这五行**。少任何一条，`SWNS` 都会落到别的数上（见第二节的五次尝试）。

##### 二、五次尝试完整表（**这张表本身就是答辩材料**）

| 尝试 | 改动 / 参数 | gate `#lut` | route `#lut` | `#slices` gate/route | `SWNS` | `STNS` | `HWNS` | `Fmax` | Viol S-EP | 结果 |
|---|---|---|---|---|---|---|---|---|---|---|
| **v1** | rl45 + t24 + t25（**无 t26**） | 15,501 (79.09%) | 16,649 (84.94%) | 530 / 8,752 | **+0.113** | 0.000 | +0.012 | 25.071 | 0 | ✅ 通过（但**功能不全**，见下） |
| **v2** | 上面 + **t26** | 15,244 (77.78%) | 16,400 (83.67%) | 530 / 8,590 | **−0.194** | −0.215 | +0.011 | 24.879 | 3 | ❌ 失败 |
| **attA** | 原样重跑 v2 | 15,244 | 16,400 | 530 / 8,590 | −0.194 | −0.215 | +0.011 | 24.879 | 3 | ❌ 与 v2 **逐字节相同** |
| **attB-1** | v2 + **`place seed 7`** | 15,244 (77.78%) | **16,414 (83.74%)** | 530 / **8,591** | **+0.113** | 0.000 | **+0.011** | **25.071** | **0** | ✅ **通过，出片** |
| attB-2/3 | 其它 seed | — | — | — | — | — | — | — | — | ⏹ 按「中途 `SWNS ≥ 0` 立刻停」未执行 |

**v1 为什么不算交付**：它是在 t26 之前出的片。`rtl\storage\fat32_reader.v` 当时是
**42,276 B / MD5 `ADF4A93927…`**，`term_reentry` 命中 **0**；t26 修好的是
**45,090 B / `5FE08F510255EFE664482CFBE2427C73`**，命中 **3**。
**缺 t26 的症状是：用户切一次模式，音乐就不换了 —— 静默重播上一个文件、`err_code` 全程 0。**
这正是「位流能跑 ≠ 位流是对的」，所以必须重跑。

**v2 的悖论**（本节最值得记住的一条）：

| 项 | v1 | v2 | Δ |
|---|---|---|---|
| gate `#lut` | 15,501 | **15,244** | −257 |
| route `#lut` | 16,649 | **16,400** | −249 |
| route `#slices` | 8,752 | **8,590** | −162 |
| `SWNS` | +0.113 | **−0.194** | **−0.307** |

**每一项资源都更少，时序却更差 0.307 ns。** t26 改的是 `u_wav/u_fat` 的
`found`/`fail`/`term_reentry`（1 个 LUT + 两个 AND），与最差路径**毫无拓扑关系**。

**attA 回答了「是不是随机的」**：原样重跑 v2，
`reports\t7b3_rl45_area.txt`、`project\route.qor`（**连布局坐标都一样**）与 v2
**逐字节相同**，只有 `t7b3_rl45_timing.txt` 因 `Generated:` 时间戳行不同。
⇒ **TD 是纯确定性的：同一输入必然得到同一输出。**
v1→v2 不是「随机跳」，是 t26 那 1 个 LUT 让综合器**换了一个盆地**，新盆地恰好差 0.307 ns。
⇒ 于是 seed 扫描从「撞运气」变成「**确定性地探索不同盆地**」。

##### 三、最终位流的七个核心数（v3 / seed=7）

| # | 数 | 值 | 来源 |
|---|---|---|---|
| 1 | **`#lut`** | **16,414 / 19,600 = 83.74%** | `reports\t7b_seed_seed7_area.txt`（00:31:36） |
| 2 | **`#reg`** | **8,441 / 19,600 = 43.07%** | 同上（`#le 16,795`） |
| 3 | **`#bram`** | **37 / 64 = 57.81%** | 同上（`#bram9k 37` / `#bram32k 0/16`） |
| 4 | **`#dsp`** | **24 / 29 = 82.76%** | 同上（**余 5，仍是余量最紧的**） |
| 5 | **`SWNS` / `HWNS`** | **+0.113 ns / +0.011 ns** | `reports\t7b_seed_seed7_timing.txt`（00:31:36） |
| 6 | **`Fmax`** | **25.071 MHz**（需求 25.000） | 同上 `:76` |
| 7 | **位流** | **648,264 B / `59A6BACC75613F5E953B7ED5A33E05E8`** | `project\hdmi_td_Runs\phy_1\hdmi_td.bit`（00:31:47） |

**三项容易漏报、但必须报的**：

- **`0 Viol Endpoints`**（setup 与 hold 都是 0）。
  `STNS 0.000` 只能说明「总松弛量为 0」，**`Viol 0` 才说明「一条都没有」**，两者不能互推。
- **`49,835,382 Paths Analyzed` / `15,676 Total Endpoints`** —— 近 5,000 万条路径**全分析过**，不是抽样。
- **`#slices` 必须给三份 `.qor` 的数，且注明来源**：
  `gate.qor 530 / 5.41%`、`place.qor 8,591 / 87.66%`、`route.qor 8,591 / 87.66%`。
  **`#slices` 从来不在面积报告里**（`report_area` 的 Utilization 段只有
  `#lut / #reg / #le / #bram / #dsp / #pad / #pll / #gclk`），只在 `report_qor` 的两列表格里。

> **gate 数字是共享的，不是凑的**：attB-1 走 `import_db t7b3_rl45_gate.db`（00:13:54，attA 那趟的产物）
> 跳过综合，`seed` 只影响 place 之后。所以 v2 / attA / attB-1 的 gate 行**都是 15,244**，
> 而 route 行才有差别（16,400 → 16,414）。**这是 `import_db` 的必然结果，必须写明白**，
> 否则读者会以为「三次综合出同一个数」是巧合。

##### 四、`#slices` 的两个阶段差 16 倍，这一条必须写下来

`gate.qor` 的 `#slices 530 / 5.41%` 是**综合后估算**（此时还没打包，
`#MACROs 97 / #insts in MACRO 530`，与日志 `RUN-0007 : ... 341 mslices, 189 lslices` 的 `341+189=530` 对上）；
`route.qor` 的 `#slices 8,591 / 87.66%` 是**物理布局布线后实际占用**。
**拿 530 或 5.41% 去论证「器件还很空」是错的** —— 真实占用是 87.66%。
这与 §4.1f.1 那条「`#Total_luts` 只有 11,282 不能论证 LUT 还很空」是同一类陷阱：
**同一个名字在不同阶段是两个不同的量。**

> ★ 另一个坑：磁盘上的 `place.qor` 会被 route 阶段**重写**。
> 本轮 `place.qor`（00:30:33）与 `route.qor`（00:31:24）的 `#slices` 都是 8,591，
> 但**要「place 当时值」只能 grep 日志**，要「最终落盘值」才读 `place.qor`。报告里必须注明用的是哪个。

##### 五、时序（判据一个字没让）

```
SWNS: 0.113ns, STNS: 0.000ns      Max: 0 Viol Endpoints
HWNS: 0.011ns, HTNS: 0.000ns      Min: 0 Viol Endpoints
Fmax: 25.071MHz                   （需求 25 MHz）
15,676 Total Endpoints / 49,835,382 Paths Analyzed
```

`route.qor` 全貌：`Setup WNS 113 / Setup TNS 0 / Hold WNS 11 / Hold TNS 0 /
Wire length 1,664,088 / #slices 8,591 / 87.66%`。
`place.qor`：`Setup WNS 1,707 / Hold WNS −11`（**place 时 hold 还是负的，route 后修成正的**）。

###### ★ `Fmax 25.071 MHz` 必须单列 —— 这是**零余量级通过**

| 项 | 值 |
|---|---|
| 需求 | 25.000 MHz（周期 40.000 ns） |
| 实测 | **25.071 MHz** |
| 频率余量 | **0.071 MHz = 0.28%** |
| 对应 slack | `SWNS +0.113 ns / 40 ns = 0.28%`（两式同源，互相印证） |

**三个前提条件必须一起写，缺一个就是不诚实**：

1. 这组结果是 **`min_ripple_len 45` + `place seed 7` + t24 + t25 + t26** 五者共同达成的，
   **任何一项回退都会跌破零**（v2 就是活证据：只多了 t26 那 1 个 LUT，`SWNS` 从 +0.113 掉到 −0.194）。
2. **温度、电压、器件批次都没有余量。** 室温真机验证过才算数（转 t9 上板清单）。
3. **不许写「时序有余量」「时序充裕」**，只能写「**时序通过，余量为 0.28%，属零余量级**」。

> 这一类诚实表述在答辩里是加分项 —— 评委见过太多「时序通过、余量充裕」
> 然后上板偶发黑屏的东西。写「0.28% 零余量」反而证明你真读了报告。

###### 新最差路径：**clk0 域普遍贴近临界，压掉一条另一条会顶上来**

四轮的最差路径**四次换人**：

| 轮次 | Begin Point | End Point | Level | Fanout | cell | net | `Data Path Delay` |
|---|---|---|---|---|---|---|---|
| v1 失败轮（§5 #1e） | `u_overlay/u_caption/u_narr/addr[9]_syn_208` | `u_axis/video_data_reg[6]` | 36 | 144 | 15.253 | 24.650 | 39.903 |
| **v1 通过轮** | `u_player/fade_alpha_reg[0]_syn_24` | `u_axis/video_data_reg[11]_syn_4` | 31 | 89 | 14.100 | 25.507 | 39.903 |
| v2 失败 | `u_ctrl/img_index_reg[4]_syn_12` | `u_axis/video_data_reg[6]_syn_4` | 34 | 152 | 13.863 | 26.051 | 39.914 |
| **attB-1 通过（交付）** | **`u_axis/rgb[13]_syn_5126`** | **`u_axis/video_data_reg[5]_syn_4`** | **36** | **88** | **14.490** | **25.045** | **39.535** |

**正确表述**：t24/t25/t26/seed 把原来那条压下去了，**现在顶上来的是另一条本来排第二、第三的路径**。
逻辑级数 36、扇出 88、cell 14.490 都是好数；**net 绝对值的大小不具可比性，因为根本不是同一条路径。**
**结论是「clk0 域（5,047 个触发器、25 MHz、Fmax 24.879~25.071 MHz）普遍贴近临界，
单点结构优化不能稳定达成」**，不是「某条路径 net 涨了」。这两句话在答辩桌上的命运完全不同 ——
前一句是设计特征，后一句是自相矛盾。

> ★ 交付轮起点 `u_axis/rgb[13]_syn_5126` 落在 **`u_axis` 内部** —— 这正是那个
> 「边界吸收 1,491 LUT」的模块（`video_rgb_to_axis`）。说明**被吸收进来的逻辑现在成了瓶颈**，
> 这是 t24/t25 降总量的必然副作用，不是新问题。

##### 六、位流

```
project/hdmi_td_Runs/phy_1/hdmi_td.bit
  648,264 B
  2026-11-03 00:31:47
  MD5 = 59A6BACC75613F5E953B7ED5A33E05E8
```

对照 v1：`648,264 B / MD5 60A434605DAB867D5004371BC4B305E1`（**MD5 不同 ⇒ 确是新生成的**）。
归档：`reports\t7b_bit_v3_seed7_PASS\`（位流 + 三份 qor + 四份报告 + `run_seed7.log`）。
v1/v2 的历史记录分别在 `reports\t7b_bit_v1_t26_before\` 与 `reports\t7b_bit_v2_t26_swneg\`。

**含 t26 的硬证据（不能只看时序过）**：

```
project\hdmi\fat32_reader.v  term_reentry = 3   ✅
rtl\storage\fat32_reader.v   term_reentry = 3   ✅
两者 MD5 均为 5FE08F510255EFE664482CFBE2427C73  ✅ 逐字节相同
45,090 B（v1 那版是 42,276 B / ADF4A93927）
```

##### 七、seed 为什么有效：**换盆地，不是降 net**

| 轮次 | Level | Fanout | cell | net | net/段 | `Data Path Delay` | 结果 |
|---|---|---|---|---|---|---|---|
| v1 通过 | 31 | 89 | 14.100 | 25.507 | 0.850 | 39.903 ns | +0.113 |
| v2 失败 | 34 | 152 | 13.863 | 26.051 | **0.789** | 39.914 ns | −0.194 |
| **attB-1 通过** | **36** | **88** | **14.490** | **25.045** | **0.715** | **39.535 ns** | **+0.113** |

**attB-1 的逻辑级数是三轮最高（36），net 是三轮最低（25.045）；
而 v2 的 net/段 0.789 反而比 v1 的 0.850 更低。**
真正决定通过的是 `Data Path Delay` 与 40 ns budget 的差：
v1 39.903（差 0.097）、attB-1 39.535（差 0.465）、v2 39.914（超 0.194）。
**三者相差不到 0.4 ns，落在布线器的求解精度里。**

> **关于 v1 与 attB-1 的 `SWNS` 数值完全相同（都 +0.113）**：
> 这是**纯属巧合**，`Data Path Delay` 相差 **0.368 ns**。
> **本文档不解释这个巧合的成因** —— 手算 `Slack = Budget − delay − skew − uncertainty`
> 代入两轮的 cell/net/skew 都对不上实测值（说明公式缺项，TD 内部还含其它修正项）。
> **为了解释一个巧合去编机制，是 t24「凭表达式推断视觉后果」那类错误的同族。**

###### 「net/段 是描述性指标，不是优化目标」

**这句话要精确，不能写成「net/段 不可靠」**：

- 在 §4.1f.5d 那**七组参数实验**里，net/段 是**有解释力的** ——
  同一套布局算法的不同设置，net 变长必然变差。
- 但 **seed 是不同布局算法起点**，两者不是一回事。
  同一个 net/段 数值可以对应通过或不通过（v2 0.789 失败 vs attB-1 0.715 通过，而 v1 0.850 也通过）。
- 所以正确的说法是：**net/段 是描述性指标（描述这条路径长什么样），
  不是优化目标（不能拿它当判据去调参数）。**
  判据永远是 `SWNS ≥ 0 && HWNS ≥ 0`。

##### 八、★★ 「参数名不存在的失败模式：PASS 但零效果」（第七条盲区的第二个变体）

captain 曾建议用 `flow enable_seed <N>` 做 seed 扫描。**实测 TD 6.24 全安装目录 0 命中**：

```
enable_seed 在 D:\TD_6_24_APP 全目录（*.json,*.tcl,*.xml,*.txt,*.scf）命中 = 0
'set_param place seed' 命中 = 1
  doc\scripts\MultiSeed.tcl:62: set_param place seed $seed
```

**正确写法是 `set_param place seed <N>`（place 段）。**

**为什么这个错误最隐蔽**：TD **不校验参数名**
（`PRJ-1106 : Update wild param ... succeed` 什么都接受），所以
`PASS-set_param` / `PRJ-1105 succeed` **不能作为「参数生效」的证据**。
若照 `flow enable_seed` 跑，会拿到四条 `PASS-set_param`，
然后四个种子出**四份逐字节相同的结果**，
最后结论会是「seed 全不过，得动代码」—— **而真相是参数名根本不存在。**
**连报错都没有，只是什么都没发生。** 这是「工具报绿但东西是错的」最隐蔽的变体。

**唯一的证据是「产物变了」**：

| 证据类型 | 具体 | 判据 |
|---|---|---|
| 布局结果 | `RUN-1001 mslices` | 4,286 → **4,278**（seed=7） |
| 布局结果 | `place.qor` 的 `#slices` | 8,590 → **8,585** |
| 时序 | `place.qor` 的 `Setup WNS` | 1,757 → **1,707** |

**「先做 2 分钟的探针确认参数真的生效，再花 6 分钟跑全程」这个做法要成为标准动作**：
`project\t7b_seed_probe.tcl`（只到 place + manhattan 时序，~2 min）就是这个探针。
**不做探针直接跑全程，等于用 6 分钟买一个「不知道参数有没有生效」的结果。**

> 同族还有三条：§4.1f.4 的 `set_param -run`（写进 `.al` 但不改引擎）、
> 本节第十条的 `#bram` 正则（断言假报）、以及 `#slices` 读错文件。
> **共同点：都是「以为自己验证了，其实验证的是一个不存在的通道」。**

##### 九、告警计数（要会区分大小写）

```
HDL-8007  = 0      HDL-5105 = 0      PHY-9009 = 0      WARNING = 50
grep -i CRITICAL = 12   ← 误计
grep    CRITICAL =  4   ← 真实
```
**`grep CRITICAL` 得 12 是错的**：其中 8 条是小写标题行 `RUN-1001 :   Top critical paths`，
只有 4 条是真正的 `CRITICAL-WARNING`，且**全是原厂固有**：

| 消息码 | 条数 | 内容 |
|---|---|---|
| `PHY-7002` | 2 | `Instance u_sdram_sip location (12,12) / (164,288) is not honored`（SDRAM 硬核位置不被采纳，ECO 时会移） |
| `USR-6135` | 2 | `The feedback path of PLL u_pll / u_sdram_pll is on local network`（PLL 反馈走 local 网） |

**判据**：这 4 条在 t7-A 阶段（§4.1）就已经存在，条数不变 ⇒ 不是本轮引入的。

##### 十、★★ 第六类盲区的活标本：**断言假报把「已经成功」判成失败**

本轮第一次跑（23:28）时，`route` 后时序其实**已经过了**（`SWNS +0.113 / HWNS +0.012`），
但脚本报 `T7B_AREA_NO_BRAM` 并 `exit 15`，**没走到 bitgen，没出位流**。

**根因**：`#bram` 正则要求 `#bram N / M`，而 TD 实际吐的是 `#bram 37   out of     64   57.81%`。
文件在、行在、值也对（37/64），断言却判「找不到」。

**三次假报形态各不相同**：

| # | 形态 | 具体 | 修法 |
|---|---|---|---|
| 1 | **格式** | `#bram` 正则要求 `N / M`，TD 实际吐 `N out of M` | 正则改 `#bram\s+([0-9]+)\s*(?:/|out\s+of)\s*([0-9]+)`，`#lut` 同步 |
| 2 | **运行时版本** | 报告 mtime 晚于 TD 启动时刻（读到上一轮的文件） | 断言前先核 mtime |
| 3 | **读错文件** | `#slices` **不在面积报告里**，只在 `project/<step>.qor` 里 | 改读取路径读三份 qor，**不改断言去凑** |

**为什么这条比之前的盲区更值得记**：
前面几条盲区（`vlog` 不报端口名、`vlog` 不报缺模块、`PRJ-1105 succeed` 不代表生效）
都是**漏报** —— 放过了坏的。这一条是**假报** —— 把好的判成坏的。
**危害同样大**：如果当时直接信了这条红，就会去查「为什么 TD 没生成面积报告」，
而真因是自己的正则写错了格式。**假报会让人花时间去修一个不存在的问题。**

**修法与验证（三层，缺一不可）**：

1. **正则同时接受两种格式**（见上表第 1 行）。
2. **`#slices` 改为遍历 `{gate place route}` 读 `$prjdir/<step>.qor`**，
   逐份打 `T7B_SLICES-<step>=N (P%)`；三份都解析不到才留 `INFO-T7B_SLICES`。
3. **新建 `project\t7b_assert_only.tcl`**：只对**已存在的真实报告**跑断言逻辑，
   不 `import_device`、不 `open_project`、不碰 `.al`、不碰任何 `.v`，5 秒出结果。
   实测 `RESULT: PASS`，把 gate / route / timing / 三份 qor 全解出来。
   **然后才重跑全流程。**

> **进 t9 的规矩**：断言假报与断言漏报是同一类缺陷的两个方向。
> 两者都只能靠「**拿真实产物喂它**」来验证 ——
> 不能靠「跑一遍 11 分钟的流程看它红不红」，因为**红的时候你分不清是产物坏了还是断言坏了**。
> `t7b_assert_only.tcl` 就是这个验证的最小载体。

##### 十一、本节判据（F7~F11，在 F1~F6 之后继续编号）

| # | 判据 | 怎么判真假 |
|---|---|---|
| F7 | 报 `#slices` 必须同时给 gate 与 route 两个阶段，并注明来源是 `.qor` | gate `530 / 5.41%`、route `8,591 / 87.66%`。只给一个数会让人以为「器件只用了一成」 |
| F8 | 时序通过后 `net` 段可以比失败轮更差 | 失败轮 net 24.650、通过轮 25.045。判据是 `SWNS/HWNS ≥ 0`，不是 net 绝对值 |
| F9 | `grep CRITICAL` 必须区分大小写 | 不区分得 12（含 8 条 `Top critical paths` 标题），区分得 4（全是原厂固有） |
| F10 | 断言本身必须先拿真实产物验过 | 断言脚本改完，先用 `t7b_assert_only.tcl` 对现存报告跑一遍；直接进 11 分钟流程验证等于「用流程当单元测试」 |
| **F11** | **参数生效必须拿「产物变了」证明，不能拿 `PASS-set_param` 证明** | 先跑 2 分钟的 `t7b_seed_probe.tcl` 看 `mslices`/`#slices`/`place WNS` 三个数变没变。TD 不校验参数名，`PRJ-1106 succeed` 什么都接受 |

##### 十二、可复现脚本（**留在 `project/`，是「这个位流怎么来的」的证据**）

| 脚本 | 用途 | 耗时 |
|---|---|---|
| `project\t7b_bit3.tcl` | 全流程（从 elaborate 起，含约 214 s 综合） | ~11 min |
| **`project\t7b_seed_probe.tcl`** | 只到 place + manhattan 时序，**验 seed 是否真生效** | **~2 min** |
| **`project\t7b_seed_full.tcl`** | **从 `t7b3_rl45_gate.db` 载入（跳综合），place→route→timing→bitgen** | **~6 min** |
| `project\t7b_assert_only.tcl` | 对已存在真实产物跑断言（面积 + 时序 + 三份 qor），不 `import_device` | ~5 s |

`t7b_seed_full.tcl` 关键设计：`T7B_SEED` 环境变量 → `regexp {^[0-9]+$}` 净化 →
`regsub -all {[^A-Za-z0-9_.-]}` 净化 tag → 兜底自检；
`#bram`/`#lut` 用**双格式正则** `\s*(?:/|out\s+of)\s*`；
`#bram < 35` → `T7B_BRAM_REGRESSED` exit 16；
`#slices` 遍历三份 qor；
时序断言 `SWNS`/`HWNS` 解析失败给 `T7B_TIMING_REPORT_INVALID` exit 11
（与 `T7B_TIMING_FAILED` exit 12 分开 —— 「报告格式变了」和「时序真没过」处置完全不同）。


### 4.2 文本期（grep 即可判，t7-A 第 12 步后）

| # | 检查 | 判据 |
|---|---|---|
| 8 | `science_rgb` 在顶层 | **0 命中**（端口、wire、例化全删干净） |
| 9 | `24'hFF_00_00` 在 `rtl/` | **0 命中**（只剩 `tb_video_content_mux.v` 里作为"防退化"的反例常量） |
| 10 | `u_kact` / `key_action` 在顶层 | **0 命中** |
| 11 | `auto_sw_sel` 在顶层 | 只剩 `2'd0` 常量赋值与 4 个消费者端口，**无 `key_action` 驱动** |
| 12 | `caption_en` | `key_router.ticker_en_eff`，**不再出现 `1'b1`** |
| 13 | `.src_w` / `.src_h` 在 `u_player` | 各出现 1 次，值 `16'd640` / `16'd480` |
| 14 | `brightness_apply` | `:464` 是 `.rgb_in(video_rgb_brt)`，**不是 `video_rgb_ovl`** |
| 15 | `i2c_scl` / `i2c_sda` | 顶层端口声明 + `assign ... = *_oe ? 1'bz : 1'b0;` 各 1 处 |
| 16 | `mode_ctrl.temp_alarm` | 接 `thermal_guard.oth_en`，**不是 `oth_enter`**、**不是 `sensor_fault`** |
| 17 | `lint_verilog.py` | `E0=0 / E1=0 / E2=0`，结论「通过」 |
| 18 | `hdmi_td.al` | `<File Path>` 开 **66** / 闭 **66**；`<Verilog>` 段 **64**；`CompileOrder` 1..64 连续、max=**64** |
| 19 | `sync_src.ps1` AST | parse errors 0；hashtable 条目 **67**（63 `.v` + 1 `.hex` + 3 约束）；`rtl\*` 62；dup keys 0 |
| 20 | `project/hdmi/` 目录 | **60 个 .v + 1 个 `cjk16_bitmap.hex`**（37,200 B） |
| **21** | **TODO 归零（仅 t7-B）** | `grep -c "TODO(t7-B)" rtl/top/dmz_eg4s20_hdmi_top.v` = **0** |
| **22** | **无哨兵键值** | `grep -n "4'hF\|4'hf\|4'd15" rtl/top/dmz_eg4s20_hdmi_top.v` **0 命中**（`4'hF` = K_EMERG，详见 §5 #3 禁令） |
| **23** | **`sensor_fault` 不接 alarm** | `grep -n "sensor_fault" rtl/top/dmz_eg4s20_hdmi_top.v` 只出现在 `aht20_ctrl` 例化的 `.sensor_fault(...)` 一处，**不得出现在 `mode_ctrl` 或 `thermal_guard` 附近** |

### 4.3 仿真期（t7-A 第 11 步）

| # | 检查 | 判据 |
|---|---|---|
| 24 | `tb_video_content_mux.v` 断言数 | 10 → **12**（新增 2 条测两源语义） |
| 25 | `mode=2` 时 `rgb_out === emerg_rgb` **且 `rgb_out !== 24'hFF_00_00`** | 两条都过。后半句是**防退化**：把 `emerg_rgb` 接成常量红，前半句照样成立 |
| 26 | `mode=1`（科普） | `disp_mode` 未生效时输出图库内容，生效后输出视频首帧，**中间不出现彩条也不出现黑屏** |
| 27 | 回归 marker | `ALL CHECKS PASSED: video_content_mux` |
| 28 | 前端回归 20 case | 全 pass（若删了 `science_page` case 则为 19 case） |

#### 4.3b ★ 端口改名/增删后，**必须对每个例化点跑一次 vsim 加载**（t16 追加，2026-11-02 17:5x 实测）

`vlog` 通过不代表 tb 能加载 —— 这条在 t7-A 期间已经吃过一次（§4.1c），
t16 又在**测试台侧**独立复现了一遍，两次的机理完全相同：

| 场景 | `vlog` | `vsim`（加载，连 `run` 都不用跑） |
|---|---|---|
| `osd_panel.bright_sel` → `bright_lvl` 后，`tb_osd_panel.v` 仍写 `.bright_sel(bright_sel)` | **`VLOG_EXIT=0`**，零 Error 零 Warning | `# ** Error: (vsim-3063) Port 'bright_sel' not found in the connected module` → `# Error loading design` → **`VSIM_EXIT=12`** |
| `osd_autopop` 从 4 口扩到 7 口后，`tb_osd_autopop.v` 仍只接 4 口 | **`VLOG_EXIT=0`** | `# ** Warning: (vsim-3017) Too few port connections. Expected 17, found 14` + 后续 `Error loading design` |

**⇒ 判据（成本 1 秒，能抓到一整类静默缺陷）：**

```powershell
# 每改完一次端口（模块侧或例化侧），对每个受影响的 tb 跑一次加载：
vsim -c -quiet -do "quit -f" work.<tb名>     # 不 run -all，只看能不能加载
# 通过判据：没有 "Error loading design"、没有 vsim-3063 / vsim-3017，EXIT=0
```

**为什么 `vlog` 抓不到**：Verilog-2001 允许命名端口连接与模块端口表不一致（历史包袱，
`vlog` 只在**位置连接**时报错）。而 TD 的 `elaborate` 对顶层按「隐式网」处理，
也不报错 —— 所以这条缺陷**只有 `vsim` 加载、或 §4.1c 那个端口交叉校验器能抓**。
两端都要用：模块侧改端口跑 §4.1c 校验器，例化侧（tb / 顶层）改完跑本节的 vsim 加载。

**t16 实测断言数（三个 tb，改前 → 改后，只增不减）：**

| tb | 改前 | 改后 | 增量说明 |
|---|---|---|---|
| `tb_osd_param_text.v` | **47** | **98** | +51：V02 亮度十档、V12 音量十档、V13 分辨率五档、V14 屏占比五档、V15 互不串扰、`chk_range_blank` 条件列组两向 |
| `tb_osd_panel.v` | **55** | **63** | +8：P12 八条（用「16 行点阵指纹」而不是亮像素个数，防止两个不同字形个数相同而假通过） |
| `tb_osd_autopop.v` | **26** | **38** | +12：P11 八条（音量/分辨率/屏占比各自触发 + 过期）、P12 四条（复位释放后第一拍 `panel_on` 必须为 0） |

> **改后断言数为什么不能只看总数**：`tb_osd_param_text` 一度报「58 checks / 0 failed」，
> 但那个数是**虚的** —— `chk_line` 用了全局循环变量 `i`，而 V02 的 `for (i = 0; i < 10; ...)`
> 一进 `chk_line` 就被改成 22、直接退出循环，十档只测了第 0 档。修成 `chk_line` 内部
> 用独立 `integer k` 之后，同一份 RTL 的断言数从 58 涨到 98，全绿。
> **⇒ 判据是「断言数只增不减」，但「断言数正确」还得靠反证来证明（见 §4.3c）。**

> **不许**用"把红的断言注释掉"来让回归变绿。`:68` / `:71` 这两条旧断言测的是
> 「静态科普页」和「纯红应急屏」，**这两个功能已被 t16 与用户裁决替换掉了**，
> 所以它们不再成立是**正确的**，必须改成测新语义，而不是删掉。

#### 4.3c 反证（「把功能改坏，断言必须变红」——t16 实测记录）

全绿只证明「没抓到问题」，不证明「能抓到问题」。t16 对每条新增能力都做了一次定向反证：

| # | 注入的破坏 | 期望变红的断言 | 实测结果 | 恢复后 |
|---|---|---|---|---|
| 1 | `osd_param_text.v` 的 `5'd2: dec_char(bright_lvl);` 改回 `dec_char({1'b0, bright_lvl[2:0]});`（= t16 之前的 3 位窄口） | V02 BRI=8 / BRI=9 | **`94 checks passed, 4 failed`**：`V02 BRI=8`、`V02 BRI=9`、`V11b combo params`、`V15c 六项同时非默认` 全红 | 恢复后 `98 / 0` |

> 那 4 条红得很有说服力：档 8 应显 `"B:8 ..."`、实际印成 `"B:0 ..."`；档 9 应显 `"B:9 ..."`、
> 实际印成 `"B:1 ..."` —— 正是 §2.3 描述的失效链。V11b/V15c 顺带变红是因为它们也把
> `bright_lvl` 设到 8/9。

**反证的两条纪律（两次踩坑换来的）：**

1. **注入之后先确认「新代码真的编进去了」**，再怀疑「断言不够狠」。
   t13 有一次反证没变红，排查半小时才发现是 `Set-Content -Encoding UTF8` 给 `.v` 文件
   写进了 BOM，`vlog` 直接报 `near "?: syntax error, unexpected non-printable character 0xef`
   —— 库根本没用新代码，`vsim` 跑的还是旧库。
   **判据：注入后 `vlog` 必须 `EXIT=0`，且 `$finish` 的行号/断言数与上一版不同。**
2. **改 `.v` 一律用 Python 写（`encoding="utf-8", newline="\n"`），不用 PowerShell 的
   `Out-File` / `Set-Content`** —— 后者会带 BOM 或 CRLF，两个都能让 TD/vlog 报出与
   真实缺陷无关的错。

#### 4.3d ★★★「默认档恰好等于没测」——参数型逻辑的测试纪律（t19 反证换来的，2026-11-02）

`t19` 给 `gallery_probe` 注入「漏移位」bug 后，`W11` / `W12` / `W13` **依然全 PASS** ——
它们的 `rle_lba` 分别是 14 / 17 / 14，全都正确。原因：这三个用例的 `spc = 1`，
移位量 = 0，**漏移位恰好等价于正确移位**。只有 `W14`（`spc = 4`，非平凡值）能抓到这个 bug。

| 用例 | `spc` | 移位量 | 漏移位 bug 下的结果 | 能抓到吗 |
|---|---|---|---|---|
| `W11` | 1 | 0 | `rle_lba` = 14（正确） | ❌ 全绿 |
| `W12` | 1 | 0 | `rle_lba` = 17（正确） | ❌ 全绿 |
| `W13` | 1 | 0 | `rle_lba` = 14（正确） | ❌ 全绿 |
| **`W14`** | **4** | **非 0** | 偏移算错 | ✅ **抓到了** |

**推广成规则（t9 复跑与 t11 答辩材料各引一次）**：

> **「默认档恰好等于没测」** —— 任何**移位 / 缩放 / 变址 / 偏移**参数，
> **至少要有一个用例取非平凡值**（移位量 > 0、缩放比 ≠ 1、偏移 ≠ 0、`spc` ≠ 1），
> 否则「默认档全绿」并不证明那段逻辑存在，只证明它被绕过了。
>
> **诊断口诀**：一条断言在注入 bug 后不变红，先问「这个用例的参数是不是恰好让 bug 失效」，
> 再怀疑「断言写得不狠」。（与 §4.3c 纪律 1 同源：先确认注入真的生效，再怀疑断言。）

**这与 Key9「恒等档」是同一件事的两面**：Key9 的**恒等档**（`ratio_sel = 4`，比例 **1/1**，
`win_w = 640` / `win_off_x = 0`）被 RTL **主动绕过**降采样逻辑 ——
`T4_VIDEO_PATH.md:629-633`：`assign h_ident = (win_w >= LINE_PIX16) && (win_off_x == 16'd0);`、
`assign use_key9 = !h_ident && !win_bad;`。所以恒等档必须**单独**断言「与改造前逐拍 `===`」
（`T4_VIDEO_PATH.md:457` 的 `compared=512`、`mismatches=0`）；
而 **档 0**（`ratio_sel = 0`，比例 1/2，`win_w = 320`、`win_off_x = 160`，源列步进 `Δ = 2`，
走 Bresenham 正常路径）**必须单独断言** —— 它碰不到恒等档那条直通路径，恒等档也碰不到它这条降采样路径。
**两个档位通路完全不同，只测其中一个等于没测另一个**：只测非恒等档，永远证明不了「恒等档真的没被改动」；
只测恒等档，永远证明不了「降采样逻辑存在」。这是本工程最容易被「全绿」骗过去的地方。

### 4.3c ★★★ 第三条「工具自己坏了」的活标本：依赖解析器把关键字拆成两个词

**背景**：`scripts/resolve_tb_deps.py` 是我为修 §4.3b 那个坑写的 ——
从 tb 出发递归解析例化闭包，输出完整源文件清单。
它第一次跑出来是这样（`tb_pix_reader`）：

```
=== 未解析（可能是 IP/加密件/原语，需人工确认）===
  cas
  ch
  endcase
  expected_pixe
  fo
  i
  repea
  scan_fram
  sdr_as_ram          ← 这个是真的（加密件）
  whil
```

**10 条里 9 条是垃圾，唯一真的 IP 被淹在噪音里。**

### 根因：正则把关键字拆成了两半

```python
# 原正则（三个缺陷叠加）
r'^\s*([A-Za-z_]\w*)\s*(?:#\s*\([^;]*?\)\s*)?([A-Za-z_]\w*)\s*\('
```

| # | 缺陷 | 后果 | 实例 |
|---|---|---|---|
| 1 | **没有 `\b` 词边界** | `[A-Za-z_]\w*` 可以回溯，把 `for` 拆成 `mod=fo` + `inst=r` | `for (y = 0; ...)` → `fo` / `r`；`chk(...)` → `ch` / `k`；`scan_frame(` → `scan_fram` / `e`；`while (` → `whil` / `e`；`repeat (` → `repea` / `t` |
| 2 | **`\s*` 允许跨行** | `endcase` 独占一行、下一行是 `if (...)`，被拼成 `mod=endcase` + `inst=if` | `rtl\storage\framebuf_arbiter.v:260` / `rtl\storage\sdram_ctrl_wrap.v:204` |
| 3 | **`SKIP_WORDS` 只查 `mod` 不查 `inst`** | 缺陷 2 拼出来的 `inst='if'` 恰好匹配 `^[a-z]+\d*$` 这个实例名过滤，被放过 | 同上 |

**注意缺陷 2 与缺陷 3 是串联的**：只有 2 的话 `endcase` 会进 `SKIP_WORDS` 被挡；
只有 3 的话 `\s*` 不跨行就不会拼出 `if`。**两个一起才漏。**

### 修法：三道独立防线

```python
r'^[ \t]*([A-Za-z_]\w*)\b[ \t]*(?:#[ \t]*\([^;]*?\)[ \t]*)?([A-Za-z_]\w*)\b[ \t]*\('
#  ↑ 只在本行内      ↑ 词边界             ↑ 词边界
if mod in SKIP_WORDS or inst in SKIP_WORDS:      # ← 两个都查
    continue
```

外加 `SKIP_WORDS` 补全 20 个 Verilog 关键字（`endcase` / `while` / `repeat` /
`endfunction` / `always_ff` / `logic` / `int` …）。

### 反证：逐道拆防线，看拆到第几道才翻转

单点反证在这里**不成立** —— 三道防线任意两道都在时，拆掉第三道不会翻转。
**这正是「冗余防线让单变量反证失效」的教科书案例**，所以反证要写成「逐道拆除」：

| 拆到第几道 | 剩余防线 | 意外未解析 | RESULT |
|---|---|---|---|
| 基线（0 道） | 3 道全在 | **0** | PASS |
| D1：拆 `\b`（改回 `\s*` 跨行版） | 2 道 | **0** | PASS（防线 2/3 挡住） |
| D2：再拆 `endcase` 关键字 | 1 道（`inst` 检查） | **0** | PASS（防线 3 挡住） |
| **D3：再拆 `inst` 检查** | **0 道** | **1**（`endcase`） | **FAIL** |

`project\...` 无、纯 python 脚本 `scripts\_refute_resolver_c.py`，实跑
`RESULT: PASS / REFUTE_C3_EXIT=0`。

**这张表的说服力比「注入变异 → 变红」强得多**：它同时证明了
① 这个 bug 真实存在（全拆就翻转）② 三道防线各自有效（拆一道不翻转）。

### 另外四条反证（`KNOWN_UNRESOLVED` 白名单）

captain m03158 要求「解析闭包遇到 IP/加密件必须显式列白名单，不能静默跳过」。
原来只是打印一段「需人工确认」，**默认放行** —— 这与「漏了一个 rtl 文件」症状完全一样。
改后区分「预期 / 意外」，意外就 `EXIT=1`。四条反证全部双计数：

| # | 变异 | 注入前 | 注入后 | 结果 |
|---|---|---|---|---|
| 基线 | — | 闭包 7 / 预期 1 / 意外 0 | — | PASS / EXIT=0 |
| A | 清空 `KNOWN_UNRESOLVED` | 预期 1 / 意外 0 | 预期 0 / 意外 1 | **FAIL / EXIT=1** ✅ |
| B | 去掉 `\b` | 意外 0 | 意外 8 | **FAIL / EXIT=1** ✅ |
| D | `RTL_DIRS` 去掉 `rtl`（模拟漏目录） | 闭包 7 | 闭包 2 / 意外 4 | **FAIL / EXIT=1** ✅ |

修复后四个 tb 的闭包与修复前**逐字一致**（3 / 7 / 14 / 14）：
`tb_fifo_fwft` 3、`tb_pix_reader` 7、`tb_image_player` 14、`tb_display_content` 14，
全部 `RESULT: PASS / EXIT=0`。**闭包没变，变的是「能不能区分正常与漏抓」。**

### 进 t9 的规矩

> **写解析器/审计器这类工具时，第一个反证不是「喂一个坏输入看它报不报错」，
> 而是「确认你的反证真的改变了被测量的那个量」。**
> 本轮 `_t7b_audit_refute.py` 就踩过一次：正则里把 `$` 写成 `\\\$`（字面反斜杠+$），
> 源文件里根本没有反斜杠 ⇒ 变异匹配 0 行 ⇒ 报告「计数没变」，
> **看起来像审计脚本漏判，实际是反证工具自己没注入。**
> 所以反证工具必须内置一条硬规则：**变异匹配 0 行时直接报错退出，不许默默跳过。**



### 4.4 上板期（t9 验收用，t7-A 不做）

| # | 按键/条件 | 期望现象 | 若失败说明什么 |
|---|---|---|---|
| 29 | Key6 连按 10 次 | 画面从全亮到很暗，10 档；**参数面板不受调暗影响** | 面板也变暗 = 亮度插错位置（插到 `osd_panel` 之后了） |
| 30 | Key7 连按 | 音量 10 档；**屏幕波形幅度跟着变** | 波形不变 = `vol_apply` 漏接消费者③（§2.8） |
| 31 | Key5 | 底部滚动字幕开/关 | 无法关 = `caption_en` 还接 `1'b1` |
| 32 | Key2 | 日常 ↔ 科普 | 无变化 = `key_router.mode` 没接 `mode_ctrl.mode` |
| 33 | Key3 | 立即进应急疏散图（**不是纯红**） | 纯红 = `video_content_mux` 没改两源 |
| 34 | 应急下 Key3 双按 2 s | 退出应急，回到日常 | 退不出 = 确认窗口参数错 |
| 35 | 吹风机吹到 >45℃ | 自动进应急，`led[3]` 亮 | 不进 = `temp_alarm` 接了单拍或 `sensor_fault` |
| 36 | 拔掉 AHT20 | **不进应急**，温度停止更新 | 进了应急 = `sensor_fault` 误接 `temp_alarm`（§2.4） |
| 37 | 数码管 dig0 | 显示图案序号，与屏幕图案**一致** | 不一致 = `pattern_sel` 被接了别的（§3.4） |

---

## 5. 待定项（**2026-11-02 已全部裁决**，逐条结论在下方；剩余依赖 rtl-storage 落盘）

> 本节最初是「7 项待定，不要猜」。captain 已于 2026-11-02 逐条给结论，
> 现每项保留：**原问题 → 实测证据 → 裁决 → t7-A/t7-B 各自动作**。
> 仍有两项依赖 rtl-storage 落盘（#1 的透传层、#2 的 `sd_grant`），
> 它们是 **t7-B 的前置**，不阻塞 t7-A。

### #1 `pix_reader` 的 Key9 端口——**已落盘；缺的是 `image_player` 的透传层**

> **本节已于 2026-11-02 晚更正**：早先写「9 个 Key9 端口未落盘」已被 rtl-storage 的实现推翻。
> 实际状态是**端口已在 `pix_reader` 里实现，但 `image_player` 没把线接出来**。
> 这个更正很重要：症结从「等人写端口」变成「等人加透传口」，t7-B 的阻塞点不同。

**实测（2026-11-02 14:24:32 版，23,342 B / 434 行）`rtl/storage/pix_reader.v` 端口：**

```
input  [15:0] win_w, win_h, win_off_x, win_off_y   ← 全部 16 位（不是 11/10 位）
input  [10:0] active_x                            ← Key9 水平窗口判据
output        out_valid                           ← 窗口内有效；满屏档与 pix_valid 逐拍一致
output [2:0]  stat
```

两处与早先冻结清单不同，**以本表为准**：

| 早先冻结清单 | 实际 |
|---|---|
| `win_w[10:0]` / `win_h[9:0]` / `win_off_x[10:0]` / `win_off_y[10:0]` | **全 `[15:0]`** |
| `use_key9` 是端口 | **是内部 wire**（`:146` 声明，`:256` `assign use_key9 = !h_ident;`） |
| `h_acc` / `v_acc` 是端口 | **内部寄存器**，不引出 |

因为 `pix_reader.win_*` 已经是 16 位，而 `image_window_mask.win_*` 也是 16 位，
**两者可以直接共用同一组 `mask_win_*`，中间不需要再做位宽适配**（§2.5 硬约束②的实现反而更简单）。

**真正的缺口：`image_player` 有两层没接**（第 3 条已撤回，不是缺口）。

1. `image_player.v:37-80` 端口表里 **0 个 `win_*`、0 个 `active_x`**，
   只有 `src_w[15:0]` / `src_h[15:0]`（`:79-80`）。
2. `image_player.v:580-590` 内部例化 `pix_reader u_reader` 时，只接了
   `.src_w(src_w) / .src_h(src_h) / .src_y / .src_row_hold / .map_ident / .de / .active_y`，
   **`.win_w / .win_h / .win_off_x / .win_off_y / .active_x` 未接**（悬空成 z）。
   —— TD 的 `HDL-5317`（`win_off_y[15]`）与 `HDL-5323`（`active_x[10]`）两条告警就是这个，预期内，t20 一接就消失。
3. ~~`:589` `.pix_valid(pixel_valid)` 接错了~~ —— **这条已撤回**。
   `pix_reader.v:185-186` 是 `assign out_valid = ...; assign pix_valid = out_valid;`（同一表达式），
   所以 `.pix_valid(pixel_valid)` **就是在接 `out_valid`**，语义完全一致，无需修改。
   （早先写的「窗口外像素仍算 valid」是把 `pix_valid_raw` 与 `out_valid` 的关系读错了：
   `pix_valid_raw` 才是未经 Key9 降采样的原始值，它只在 `:183` 内部用，从未出端口。）

**要 rtl-storage 补的（三选一，仍需他确认，t7-A 不碰）：**

| 方案 | 内容 | 顶层动作 |
|---|---|---|
| **透传**（★已裁定，但收窄为 **5 根全 input**） | `image_player` 加 `win_w/win_h/win_off_x/win_off_y[15:0]` + `active_x[10:0]`，内部纯转给 `u_reader`。**不加 `out_valid`**（`pix_valid` 与它逐拍恒等，见 #1b），**也不拆** `.pix_valid(pixel_valid)` | 顶层把一组 `k9_win_*` + `active_x` 送进去 |
| 内部常量 | `image_player` 内部把 `win_*` 接成满屏常量 640/480/(0,0)，`active_x` 由内部 `de` 计数派生 | 顶层 **Key9 失效**（需求缺失） |
| 顶层绕过 | 顶层直接例化 `pix_reader`，`image_player` 去掉内部实例 | 动 `image_player` 的 SDRAM 仲裁，风险最大 |

### #1b ★ rtl-storage 已定稿的端口（2026-11-02 最终：**5 根，全 input，没有 `key9_out_valid`**）

> **★★ 口径变更（captain m01560，以此为准）**：t20 已收窄为 **5 根全 input**。
> 早先议过的第 6 根 `out_valid` / `key9_out_valid` **不存在、也不需要**。

**为什么不需要第六根**（我独立复核过，成立）：
```verilog
pix_reader.v:185-186
assign out_valid = use_key9 ? h_pop : pix_valid_raw;
assign pix_valid = out_valid;          // 同一表达式，逐拍恒等
```
`pix_reader.v:182` 注释原文亦写「`out_valid` 与 `pix_valid` 由同一表达式驱动，逐拍恒等」。
而 `image_player.v:50` 的 `output wire pixel_valid` 全文只出现在 `:50`（声明）与
`:589`（`.pix_valid(pixel_valid)`），**无任何其他驱动**（`fade_mixer` 只改 `reader565 → rgb565` 不动 valid；
`:422` 的 `bmp_pixel_valid` 是另一条写路径）。

⇒ **`image_player.pixel_valid` 已经就是 `pix_reader.out_valid`**。再引一根 `key9_out_valid`
会让顶层存在两个逐拍恒等的信号 —— 正是本文档反对的「各自起一套 wire 再分别赋同一表达式」的变种。
**t7-B 接线时：`u_player.pixel_valid` 就当作 `pix_reader.out_valid` 用，不要去找一根新的 valid。**

**最终端口（5 根，全 `input`）**：

```verilog
    input  wire [15:0] win_w,        // Key9 窗口宽（纯透传给 pix_reader）
    input  wire [15:0] win_h,        // Key9 窗口高
    input  wire [15:0] win_off_x,    // 窗口左上角列
    input  wire [15:0] win_off_y,    // 窗口左上角行
    input  wire [10:0] active_x,     // 当前扫描列，video_timing_gen → 顶层 → 本模块 → pix_reader
```

> **也不要求**把 `.pix_valid(pixel_valid)` 拆成 `.pix_valid()` + `.out_valid(pixel_valid)` ——
> 语义等价但改了一条已验收的连线，会让 `tb_pix_reader` 的 194 条基线失去可比性。

**两个消费者同源的收紧写法**（rtl-storage 建议，比原计划更严）：
顶层**只由 `ratio_map` 驱动一组 net**（`k9_win_w` / `k9_win_h` / `k9_win_off_x` / `k9_win_off_y`），
`u_player.win_*` 与 `image_window_mask` **都接这同一组 net**。
**不要各自起一套 wire 再分别赋同一表达式** —— 否则将来谁改了一处就错位，
现象是「画面被切一半、不报错」。

**为什么现在还不能接**：这 5 根在 t12（Key9 第 1 步）的契约里**明确列在 outOfScope**，
而 Key9 第 2 步那张卡还没建。rtl-storage 不能自己给自己派活、也不能改 outOfScope 文件。
**captain 已建 t20 派给他（已 amend 收窄为 5 根）**，工作量：端口表 5 行 + 例化 5 行，
但要重跑三个已例化它的 tb（`tb_image_player` 11,365 checks / `tb_display_content` 614,406 / `tb_startup_ownership` 9）。

**两个消费者同源的收紧写法**（rtl-storage 建议，比原计划更严）：
顶层**只由 `ratio_map` 驱动一组 net**（`k9_win_w` / `k9_win_h` / `k9_win_off_x` / `k9_win_off_y`），
`u_player.win_*` 与 `image_window_mask` **都接这同一组 net**。
**不要各自起一套 wire 再分别赋同一表达式** —— 否则将来谁改了一处就错位，
现象是「画面被切一半、不报错」。

### #1c ★ `pix_reader.v:266` 的 `map_key9_ident` 是「有主的已知 WARNING」，不是遗留

rtl-storage 确认：`assign map_key9_ident = h_ident && (win_h == FRAME_LINES16);` 全文件只此一处引用、
无声明、无消费者，TD 报 `HDL-1007 : undeclared symbol 'map_key9_ident'` 是**准确的**。
**但不清除**，理由：①`pix_reader.v` 已被 captain 冻结（t12 completed，`checks=194 errors=0` 是新基线）；
②**Key9 第 2 步（垂直跳行）正好要用这根线**做「全局恒等」判据（水平恒等 && `win_h==480`），
届时会补 `wire map_key9_ident;` 声明并真正消费它。

> **报告表述统一口径**：这条 WARNING 应写成「已知 WARNING、有主、等 Key9 第 2 步」，
> **不得**归入无人认领的遗留项。

→ **t7-A 完全不碰这块**（`image_player` 现在正在被 rtl-storage 改，碰了就是冲突）。
**t7-B 开工前必须先拿到 rtl-storage 的答复。** 详见 §5 #2 的 `sd_grant` —— 两件事同一个作者，
可以一次问清。

### #1d ★ Key9 当前只做了水平通路：非满屏档是「横向压缩 + 纵向裁剪」，不是等比缩小

**这是 t7-B 交付时必须如实说明的一条**（captain 2026-11-02 定口径，措辞不许改）。

#### 现状（事实陈述）

Key9 屏占比五档在 t7-B 已完整接线并生效：`ratio_sel` → `ratio_map` → 四根 `k9_win_*`
→ 同时驱动 `image_window_mask`（位置门控）与 `image_player`（采样范围）。**水平方向是真的在缩放**：
`pix_reader` 用信用 DDA 在窗口内取满 320 字，窗口宽度 320/400/480/560/640 对应五档，横向按比例抽样。

垂直方向**还没有**做跳行。当前非满屏档的实际渲染结果是：

> **横向压缩 + 纵向裁剪** —— 窗口内显示的是源图**中间 `win_h` 行**，上下两侧被裁掉，不是等比缩小。

用户看到的现象：画面变窄了、也变矮了（窗口小了），但**画面内容没有整体缩小**，而是左右压扁 + 上下裁掉。
满屏档（档 4，640×480@(0,0)）走恒等旁路，**完全不受影响**，所以默认档看不出任何差异。

#### 为什么现在没做（中性事实，不要写成「做不到」）

`pix_reader.v` 里已经有一套垂直 DDA，但它是为**「源高 < 480 的放大」**设计的（行重复），
方向与 Key9 需要的**缩小**（跳行）相反，所以它的 `src_y` / `src_row_hold` 输出在 `image_player` 层
**零消费者**（`image_player.v` 没有把这两根引到端口上）。这不是缺陷，是两件事本来就不是同一个用途。

#### Key9 第 2 步（垂直跳行）—— ⛔ **本小节结论已被推翻，仅存作历史**

> **🕓 本小节是 t22 之前的估算，已被 t22 实测与 t28 裁定取代。终口径见 `docs/plan_v2/KEY9_RULING.md` §2。**
> 结论从「可行且便宜 / 零 BRAM / +40~70 LUT」反转为「**物理不可行**」：顺序 FIFO 无法在流中「回头」取被丢弃的偶数行，必须整帧缓存 240×320 = 76,800 字 = 2,457,600 bit → **267 块 BRAM9K**，而全片只有 **64 块**（16 位一字也要 133 块，RGB565 只存需跳过行也要 67 块）。**267 是下界，不是估值。**
> 下面的表格与代价估算**保留原文**，只为记录当时的推理路径；**不得作为方案依据，也不得引用其中的 +40~70 LUT**。

关键认识：**窗口外那 `640 − win_w` 拍正好用来把下一条源行读出来丢掉**，不需要额外带宽。

| 档 | 窗口 | 每窗口行配额（字） | 窗口内拍数 | 窗口外拍数 | 窗口外需取（字） | 是否够 |
|---|---|---|---|---|---|---|
| 0 | 320×240 @(160,120) | 480/240×320 = 640 | 320 | 320 | 320 | ✓ 正好对齐 |
| 1 | 400×300 @(120,90) | 480/300×320 = 512 | 400 | 240 | 192 | ✓ 192 ≤ 240 |
| 2 | 480×360 @(80,60) | 480/360×320 = 426.7 | 480 | 160 | 106.7 | ✓ |
| 3 | 560×420 @(40,30) | 480/420×320 = 365.7 | 560 | 80 | 45.7 | ✓ |
| 4 | 640×480 @(0,0) | 320 | 640 | 0 | 0 | ✓ 恒等旁路 |

档 0 是零余量但对齐（240 窗口行 × 640 字 = 153600 字 = 正好一整帧 640×480/2），
其余四档都有余量。~~**五档全部满足。**~~ ← **这句已作废**。

代价：~~`pix_reader` 加一个垂直配额累加器，**零 BRAM、零 DSP、约 +40~70 LUT**~~ ← **这个估算已作废**。
真实代价见 `KEY9_RULING.md` §2：**267 块 BRAM9K**（全片 64 块），不是「零 BRAM」；「窗口外那 `640 − win_w` 拍够用」这个前提**在顺序 FIFO 下不成立** —— 被丢弃的偶数行必须在整帧流过去之前留住，而窗口外的拍数只够读、不够存。

> **t22 已实测否决、t28 已裁定不做。** t7-B 的交付口径是「**水平通路完整 + 纵向 1:1 裁剪**」，终口径见 `docs/plan_v2/KEY9_RULING.md` §1；**不得写成「垂直待做 / 后续会补」**（中性措辞同样禁止，见该文件 §4）。

#### ★ 措辞纪律（captain 明确要求，不许换说法）

| 可以写 | 绝对不要写 |
|---|---|
| 「Key9 目前只有水平通路，垂直跳行为 step 2 待做」 | ~~「带宽不成立」~~（早先的错判，已被 captain 逐档验算推翻） |
| 「当前非满屏档渲染结果为**横向压缩 + 纵向裁剪**」 | ~~「需要行缓存」~~（跳行方案零 BRAM） |
| 「`pix_reader` 的垂直 DDA 是放大用的，方向相反，故在 `image_player` 层零消费者」 | ~~「等比缩小已实现」~~ |

#### 素材规格约束（交付报告必须写）

本工程 SD 卡素材**统一 640×480**（`BURN640/` 六张），故不触发下面的问题：

> 换成**非 640×480** 的 BMP 时，`img_scaler` 会按**图片自身比例**居中缩放，
> 而窗口 mask 用的是 `ratio_map` 的档位偏移 —— **两者会错开，画面被切一块，且不报任何错**。

**t7-B 不改 RTL 处理这件事**，只作为已知前提登记：素材必须统一 640×480。
（根因：`image_player.out_w/h/off_x/off_y` 这四根本来就是 `img_scaler` 的几何输出，
t7-B 按 `T1_TO_T7_WIRING.md` §1.3 裁定改为空连接，`ratio_map` 接管窗口几何。
两套几何体系并存，只有在「源图尺寸 == 640×480」时它们的结论才一致。）


### #1e ★★ 时序收口（**历史记录，已由 §4.1f.9 收口**）：`min_ripple_len 45` 让 place 通过，但 route 后仍差 0.183 ns

> **本节是失败轮的历史记录，保留不删。**
> 最终收敛过程与交付位流见 **§4.1f.9**（`min_ripple_len 45` + `place seed 7` + t24 + t25 + t26，
> `SWNS +0.113 / HWNS +0.011`，位流 MD5 `59A6BACC75613F5E953B7ED5A33E05E8`）。
> 本节下面写的「正在验证的三个参数组」结论是：**三组与基线逐字相同，全部无效**（详见 §4.1f.5b）。
> 读本节时请把它当成「为什么当时过不去」，而不是「现在的状态」。

**这是 t7-B 出位流的最后一个门。** 2026-11-02 20:11 实测（`t7b_bit2.tcl`，`min_ripple_len 45`）：

```
PASS-import_device → PASS-open_project → PASS-set_param rtl min_ripple_len 45
→ PASS-commit_param rtl → PASS-elaborate → PASS-read_adc → PASS-read_sdc
→ PASS-optimize_rtl → PASS-optimize_gate → PASS-report_area_gate
→ PASS-export_gate_db → PASS-place → PASS-route → PASS-update_timing
→ PASS-report_timing → PASS-report_area → PASS-check_timing
→ T7B_TIMING_FAILED: setup=-0.183 ns hold=-0.020 ns      （exit 12，未 bitgen）
```

#### 违规全貌（`reports/t7b2_timing.txt`，814,995 B）

| 项 | 值 |
|---|---|
| `SWNS` / `STNS` | **−0.183 ns** / −0.485 ns |
| `HWNS` / `HTNS` | **−0.020 ns** / −0.053 ns |
| 违规端点 | setup **5 个** / hold **3 个**（共 15,874 个端点，184,776,198 条路径） |
| `Fmax` | **24.886 MHz**（需求 25 MHz，**差 0.114 MHz**） |
| 违规路径组 | 全部在 `u_pll/pll_inst.clkc[0] -> u_pll/pll_inst.clkc[0]` |
| 该时钟 | `clk0: 25.000 MHz, Fanout 5047`（其余五路时钟全部 0 违规：40 MHz/908、125 MHz/30、50 MHz/10、40 MHz/1、12.5 MHz/0） |
| Slack 分布 | −0.183 / −0.149 / −0.071 / −0.070 / −0.012 / **+0.063** / +0.269 / +0.293 / +0.324 / +0.327 |

**关键判断**：place 结束 WNS 是 **+1,357 ps**，route 后变 **−183 ps** —— **布线吃掉约 1,540 ps**。
place 用估计延迟，route 用真实延迟。⇒ 该优化的是 **place/route 的时序驱动强度**，不是再动 `min_ripple_len`
（45 已是实测最优面积点，再往上只多花资源）。

#### 三条 CRITICAL 全是原厂固有，不是本次引入

| 计数 | 内容 | 性质 |
|---|---|---|
| `PHY-7002` ×1 | `Instance u_sdram_sip location (12, 12) is not honored` | SDRAM 硬核固定位置，原厂 IP 固有 |
| `USR-6135` ×2 | `The feedback path of PLL u_pll/pll_inst (及 u_sdram_pll/pll_inst) is on local network` | PLL 反馈路径，原厂 IP 固有 |

其余计数：`HDL-8007`=0 / `HDL-5105`=0 / `ERROR`=0 / `WARNING`=47 / `PHY-9009`=0。

#### 正在验证的三个参数组（`project/t7b_bit3.tcl`）

captain m02510 定的手段顺序，**时序判据不许放宽**（`HWNS` 基线本来只有 +0.003 ns，−0.020 ns 是真违规）：

| 实验 | 额外参数（全部走 `set_param` + `commit_param`） | 目的 |
|---|---|---|
| V1_ppo | `place post_place_opt high` | 提高 place 后的时序优化强度，减少留给 route 的欠账 |
| V2_pro | `route post_route_opt high` | route 后追加时序优化迭代 |
| V3_all | `place post_place_opt high` + `route post_route_opt high` + `route fix_hold on` | 三管齐下（`fix_hold` 官方默认 on，显式写死） |

**六条判据（缺一不可）**：① PASS 序列到 `PASS-bitgen` ② `SWNS >= 0` **且** `HWNS >= 0` ③ `#bram == 35`
④ `#lut`（route 后口径）⑤ 位流大小 ⑥ Fmax。

> **备选手段（若三组都不行，按此顺序）**：`place opt_timing high` → `pr_strategy` 换策略
> → `route effort routability` → 结构优化（`u_pix_fifo` 1,634 LUT 改同步读落 BRAM，实测探针 −1,577 LUT，
> 见 §5 #8）。**任何情况下都不放宽时序判据**。


### #2 SD 总线第五路消费者——**无仲裁入口，必须裁决**

现在顶层是**五路独热仲裁**（本书写作时的旧形态是三路；t7-A 已按本节结论扩为五路）：

```verilog
wire sd_owner_probe    = !sd_ok;                                      // 最高：卡探测
wire sd_owner_gallery  = sd_ok && !gallery_done && !gallery_fail;     // 次高：首图入场
wire sd_owner_playseg  = sd_ok && (gallery_done || gallery_fail);      // 播放段（三条共用一个门）
wire sd_owner_wav      = sd_owner_playseg && wav_want_blk;             // 音频 > 视频 > 图片
wire sd_owner_rle      = sd_owner_playseg && !wav_want_blk &&  rle_want_blk;
wire sd_owner_img      = sd_owner_playseg && !wav_want_blk && !rle_want_blk;
wire sd_grant_wav      = sd_owner_wav;
wire sd_grant_rle      = sd_owner_rle;
```

> 注意 `u_player.sd_ready` 接的是 **`sd_owner_playseg`**（不是旧的 `sd_owner_player`）。
> 改这个名字是因为播放段现在有三种消费者（WAV / RLE / BMP），`u_player` 的 `sd_ready`
> 语义是「播放段时段内、卡可用」，与「这一拍总线归我」是两件事 —— 混用会让
> `img_loader` 在 WAV 持总线时误以为可以发块请求（即 2026-10-28 修过的 `d810` 那个坑的变体）。

`sd_spi_ctrl`（`:168`）**只有一个读块端口**，三方以上的 `blk_start`/`blk_addr` 直接相或
= 多驱动 = TD 报错（这个会被抓到）。但新链路带来两个新消费者，问题不在多驱动：

| 消费者 | 有 `sd_grant` 输入？ | 能否被现有仲裁挡住 |
|---|---|---|
| `wav_stream_player` | **有**（`.sd_grant`，`:92`） | 能 |
| **`rle_decoder`** | 原本**没有**（grep `grant` 0 命中）→ **t15 已补第 27 端口** | 补后能 |

`rle_decoder.v:253-255` 的 `want_blk` 直接由内部状态产生，`:607` 在 `R_NEXT_BLK` 里
无条件 `blk_start <= 1'b1`、`:608` `blk_addr <= file_lba + blk_index`。
**它发起读块时既不请求许可也不看总线是否被占。**

> 危险形态：`blk_start` 被相或进 `sd_arb_start` 后，总线会真的响应它，
> 但 `sd_arb_addr` 此刻选的是别人的地址 → **读到别人的扇区，静默错帧**。
> 这个是**静默失败**，必须在上板前解决。

**★ 已裁决（captain，2026-11-02）：选路径 1 —— `rle_decoder` 加第 27 个端口 `sd_grant`，
正式解除其 26 端口冻结。**

路径 2 与路径 3 都被否掉，理由记在这里（防止后来人重开）：

- **路径 3（物理隔离）不成立**：用户 m00001 原文「音频页换成视频音频」=
  科普模式的音频就是 `NARR.WAV` 旁白，不是背景音乐。所以科普模式下
  `rle_decoder`（视频帧）与 `wav_stream_player`（NARR.WAV）**必须同时持有 SD 总线**。
  路径 3 会让科普模式彻底没声音。
- **路径 2（`blk_start` 反压）不是"一拍窗口风险"，是必然发生的静默错帧**：
  `rle_decoder.v:607` 在 `R_NEXT_BLK` 无条件拉 `blk_start`、`:608` 无条件给
  `blk_addr = file_lba + blk_index`。若这一拍仲裁给了 `wav`，总线的 `blk_addr`
  是 WAV 的扇区号，而 `rle_decoder` 会**老老实实把这 512 字节当成自己的游程数据解码**
  → 解出来的像素是垃圾 / 触发 `err_code=4`，屏上表现为「某几帧花屏或卡帧」，
  日志里什么都看不出来。

**给 rtl-storage 的实现要求（原文，可直接抄进它的契约）：**

```verilog
// rtl/storage/rle_decoder.v 新增一个输入（第 27 个端口）
input wire sd_grant,   // 与 wav_stream_player 同款协议：高=允许发起 blk_start
```

1. `R_NEXT_BLK` 里改成 `if (sd_grant) begin blk_start <= 1'b1; blk_addr <= file_lba + blk_index; end`
   （即 `blk_start` **只在被许可时产生**）
2. **`sd_grant` 掉低时状态机必须停在 `R_NEXT_BLK` 等，不能超时跳 `R_ERR`** ——
   等待期间 `frame_idx` / `ext_wr_*` 全部冻结，**不写半个帧**
3. 「一拍窗口」必须堵死：`sd_grant` 由仲裁器**组合**给出（不是打拍后的）→
   `assign rle_grant = rle_want_blk && !wav_want_blk && ...;`，
   这样 `blk_start` 与 `blk_addr` 在同一拍被同一条件门控，不存在错位
4. 加一条断言：`blk_start` 为高的每一拍，`rle_grant` 必为高（`assert(!blk_start || sd_grant)`）

**顶层五路独热仲裁（t7-B 接）**，优先级已给定，**照抄**：

```verilog
wire sd_owner_probe   = !sd_ok;                                              // 最高，探测
wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;             // 首图入场
wire sd_owner_wav     = sd_ok && gallery_done && wav_want_blk;               // 音频优先于视频
wire sd_owner_rle     = sd_ok && gallery_done && !wav_want_blk && rle_want_blk;
wire sd_owner_player  = sd_ok && gallery_done && !wav_want_blk && !rle_want_blk;  // 换图 IMGnnn.BMP
```

**为什么音频优先于视频**：音频欠载 = 爆音/断续（用户立刻听得见）；视频欠载 = 卡一帧
（200 ms 里丢一帧几乎看不出来，而且 `rle_decoder` 有 `underrun` 输出可作提示）。
带宽对得上：@5fps 视频 0.649 MB/s + 音频 0.096 MB/s = **0.745 MB/s vs 实用 1.25 MB/s（60%）**，
且 `rle_decoder` 一帧只占 10~24 ms，200 ms 周期里其余时间总线全空，
音频的 512 B 块（约 328 µs）随时能插进去。

**注意 `sd_grant` 是组合信号，不能打拍。** 若打一拍，`blk_start` 与 `blk_addr`
就会出现在不同拍上 —— 那正是路径 2 要避免的错帧。

**落地状态（2026-11-02 15:05 更新）**：

| 项 | 状态 | 证据 |
|---|---|---|
| `rle_decoder.sd_grant` 第 27 端口 | **✅ 已落盘**（rtl-storage，t15） | `rle_decoder.v:157` 之后 `:173 input wire sd_grant`；`:165-172` 注释完整 |
| `R_NEXT_BLK` 门控实现 | **✅ 已落盘** | `:661-667` `if (!req_sent && sd_grant) begin blk_start <= 1'b1; blk_addr <= file_lba + blk_index; req_sent <= 1'b1; end else if (blk_busy) blk_start <= 1'b0;` |
| 顶层三选一独热仲裁 | **✅ 已落盘** | `dmz_eg4s20_hdmi_top.v` 仲裁段：`sd_owner_playseg` / `sd_owner_wav` / `sd_owner_rle` / `sd_owner_img`，`sd_grant_wav` / `sd_grant_rle` 均**组合给出、未打拍** |
| **`rle_decoder` 顶层例化** | **⛔ t7-B**（前置未满足） | 见下 |

**⛔ t7-A 不例化 `u_rle` 的真正原因（不是"留给 t7-B"那么轻松）**：
`rle_decoder` 有两个输入**全 rtl 没有任何模块产出**：

```
file_lba[31:0]   // 目标 .RLE 文件的第一个扇区号
file_size[31:0]  // 文件字节长度
```

`grep -rn "file_lba" rtl/` 只有 `rle_decoder.v`(4 处，全是用) 与 `wav_stream_player.v`(2 处，同样是端口)，
**零生产**。`fat32_reader` 的输出是 `first_cluster`（簇号）而不是扇区号
（`:122-123` `file_size` / `first_cluster`，`:136-138` `out_data_begin` / `out_fat_begin` / `out_spc`），
簇→扇区换算目前只在两个模块内部各自做（`img_loader.v:191-195`、`wav_stream_player.v:312-313`）：

```verilog
wire [31:0] clu_off     = cur_cluster - 32'd2;
wire [34:0] clu_off_shl = {3'd0, clu_off} << spc_shift;
wire [31:0] dat_clu_sec = fat_data_begin + clu_off_shl[31:0];
```

**若现在例化 `u_rle` 并把 `file_lba` 接 0，症状是「科普模式永远解不出帧、`err_code` 会报 1（magic 错）
或 4（截断），屏幕上 `disp_mode` 永远停在 0」—— 一个不会崩、不会报综合错、但功能彻底不通的活死人。**
所以 t7-A **不例化**，只在顶层留一段注释 + TODO。三个可选处置（需 captain 或 rtl-storage 定）：

| 方案 | 做法 | 代价 |
|---|---|---|
| A. rtl-storage 补包装模块 | 新建 `rtl/storage/rle_file_locator.v`：内含一个 `fat32_reader`（`target_name = "SCI     RLE"`）+ spc 译码 + 一条加法，输出 `file_lba`/`file_size` | 约 20~40 LUT + `$map`/`.al` 各加一条 |
| B. 顶层自己搭 | 顶层例化第三个 `fat32_reader` + 同样的 spc 译码（`img_loader.v:231-241` 的 8 档 case） | 顶层多约 25 行、多一路 SD 请求（需再进仲裁） |
| C. 从 `SCI.IDX` 取偏移 | `SCI.IDX` 已有每帧原始字节偏移（`rle_decoder.v:53` 引用过），但**那也需要先定位 `SCI.IDX` 的扇区**，等于把问题推后一层 | **不可行，别走** |

**这一项在 t7-A 里的表现**：顶层 `dmz_eg4s20_hdmi_top.v` **不含 `u_rle`**，故 `rle_want_blk` /
`rle_blk_start` / `rle_blk_addr` 三根线**已声明、已进仲裁式、但恒为 0**（无驱动）。
`elaborate` 不会报错（未驱动 wire 只报 warn），三选一仲裁退化成两选一，行为等价于 t7-A 之前。

TODO 必须写成可 grep 的形式（**t7-A 实际只有这两条**）：

```verilog
// TODO(t7-B): 例化 rle_decoder u_rle —— 前置是 file_lba/file_size 的来源（见 T7_INTEGRATION_PLAN.md §5 #2）
// TODO(t7-B): video_overlay.narr_en / frame_idx 换成 (m_science && video_playing) / rle frame_idx@5fps
```

t7-B 收尾时 `grep -c "TODO(t7-B)" rtl/top/dmz_eg4s20_hdmi_top.v` **必须归零**（§4.2 #21）。

### #2b ★ `gallery_probe` 四输出的三条硬约定（rtl-storage 回复，接线前必读）

`rle_lba` / `rle_size` / `rle_found` / `rle_fail` 端口名与语义**不再改**。但接线时有三条坑：

1. **不能用 `rle_lba == 0` 当「没有视频」的判据** —— 扇区 0 是合法值（引导扇区）。
   必须看 `rle_found`：`rle_found=0` 时 `rle_lba`/`rle_size` 恒 0，但反过来不成立。
2. **「卡上没有 SCI.RLE」与「探测出错」是两件事**：
   - 前者 = `rle_found=0 && rle_fail=0`，**属正常情形**，不应报错（屏上表现 = 科普模式没视频可播）；
   - 后者 = `rle_fail=1`（读块失败等真故障），单独上报。
3. **`rescan` 拉起时本模块会重探 RLE**（换卡后 LBA 会变），
   `rle_*` 四根在 `G_ARST` 期间被清 0 再刷新 —— 顶层若在 rescan 瞬间采样会看到**一拍的 0**。
   所以**必须用 `rle_lba_q`/`rle_size_q` 锁存 + `!rle_play_en` 门控**，
   不能拿组合值直接送 `u_rle`。（captain 已给过这套写法。）

### #3 `media_player` 不存在——`player_ctrl` 保留，键事件门控到 Key0/Key1

`ARCH.md:1025` / `:1073` 写「`u_ctrl`(player_ctrl) → `u_media`(media_player)」是 1:1 更换，
但 **`media_player` 模块从未交付**（`Get-ChildItem -Recurse -Filter '*media*'` 只命中
`.bit` 和 `.py`）。

`player_ctrl`(`:116`) 现在驱动 6 根线：
`img_index[4:0]` / `loader_index[8:0]` / `switch_req` / `auto_play` / `mode[1:0]` / `status_led`。
其中 `img_index` → `osd_panel` / `osd_autopop` / `video_overlay.info_index`，
`loader_index` → `u_player.image_index` 与数码管 dig1，
`switch_req` → `u_player.load_req`，`auto_play` → 轮播开关 + `led[1]`。
**删掉 `u_ctrl` 这 6 根线全部失去驱动。**

更麻烦的是**键号冲突**（两套编码不一样）：

| 键 | `player_ctrl`（`:220-224`） | `mode_ctrl`（`:109-110`） | 冲突 |
|---|---|---|---|
| 0 | `K_PREV` 上一张 | — | — |
| 1 | `K_NEXT` 下一张 | — | — |
| 2 | `K_PLAY` 播放/暂停 | **`K_MODE` 模式循环** | **直接冲突** |
| 3 | `K_MODE` 模式循环 | **`K_EMERG` 应急直达** | **直接冲突** |
| 15 | `K_EMERG` 应急直达 | — | 与 `key_router` P2 区重叠 |

而且 **`key_router` 根本不输出 Key0/Key1/Key2**（它的 16 个输出里没有
prev/next 媒体控制）—— 所以 Key0/Key1 只能由 `player_ctrl`
（或未来的 `media_player`）消费。

**★ 已裁决（captain，2026-11-02）：`player_ctrl` 保留，`key_event` 改为只放行 Key0/Key1
的门控版本（`key_event_media`），`key_code` 原样送入。**

`auto_play_en` 复位值 `1'b0` 且唯一翻转源 `K_PLAY`（Key2）被门控掉 → **永久保持 0**，
即「纯手动 Key0/Key1 翻页」，**与用户 m00001 规格逐字一致**。
`player_ctrl.mode` 输出空连接，`mode` 由 `mode_ctrl` 提供。
**无降级项**（原 D-05 撤销），仅在附录 C「与用户规格对照」记
「无播放/暂停键、无自动轮播（规格未要求）」。

**这不是降级，是按用户规格实现。** 用户 m00001 的完整键表是 Key0~Key10，
里面**没有播放/暂停键，也没有轮播开关键** —— 所以 `player_ctrl` 的
`K_PLAY=2` / `K_MODE=3` / `K_EMERG=15` 三处键号本来就不该存在：

| `player_ctrl` 内部键号 | 用户规格里的同一个键 | 处理 |
|---|---|---|
| `K_PLAY=2` 播放/暂停 | Key2 = **模式循环**（`mode_ctrl.K_MODE`） | 轮播开关本来就不该有按键 → 门控掉 |
| `K_MODE=3` 模式循环 | Key3 = **应急直达**（`mode_ctrl.K_EMERG`） | 冲突消灭 → 门控掉 |
| `K_EMERG=15` 应急直达 | Key11~15 = 备用，不接 | 门控掉 |

**正确实现（加法，不是减法）：**

```verilog
    // 只放行 Key0 / Key1 给 player_ctrl，其余键事件在**事件层**就过滤掉
    wire key_event_media = key_event && (key_code == 4'd0 || key_code == 4'd1);

    player_ctrl #(.CLK_FREQ_HZ(25_000_000)) u_ctrl (
        ...
        .key_event (key_event_media),   // ← 只这一根线改动
        .key_code  (key_code),          // ← 原样送入，不加任何哨兵
        ...
    );
```

理由：`player_ctrl.v:333-341` 的译码全是 `if (key_event && (key_code == K_xxx))`，
**`key_event` 是最高层的使能**，把它按掉就等于该键在这个模块里不存在；
`key_code` 的值保持原样、不加任何哨兵，天然没有「哨兵撞上真键号」的风险。
**加法只放行明确要的，将来加新键也漏不了；减法要枚举所有不该来的键，加一个就漏一个。**

> ### ★★ 禁令：不得用 `4'hF` 或任何 4 位值当「无效键」哨兵
>
> `player_ctrl.v:220-224` 的 `localparam K_EMERG = 4'd15;` —— **`4'hF == 4'd15` 就是
> `K_EMERG`（应急直达）**。`key_code` 是 `[3:0]`，**0..15 全被 Key0~Key15 占满，
> 没有任何空闲值可以当哨兵**。
>
> 若写成 `key_code_media = (key_code==2||key_code==3||key_code==15) ? 4'hF : key_code;`，
> 会把「屏蔽掉的键」**变成 Key15 应急直达** —— 按 Key2 切模式会触发应急，
> 按 Key3 应急也会触发应急，看起来"能用"，实际是把两个键的功能对调成同一个，
> 而且是最高优先级的那个。**这是典型的静默错误，仿真也抓不到（它"确实"动了）。**
>
> 另：该模块**没有 `K_NONE` 常量**，因为它的译码结构是「一串 if 匹配具体键号，
> 全不匹配则 `ev = EV_NONE`」（`:347-348`），本身不需要哨兵。**别加。**

**关于应急期间按 Key0/Key1（可选门控，t7 决定：不加）：**
`player_ctrl` 自己不知道系统处于应急（它内部的 `state` 与 `mode_ctrl.mode` 是两套东西）。
应急时 `content_mux.mode=2` 走 `emerg_page`，图库内容本来就不显示，所以按 Key0/Key1
改了 `img_index` 也看不见 —— **功能上无害，只是内部状态被改了**，
退出应急后可能停在与进入前不同的图上。

**t7 采用简单版**（不加 `&& (mode != 2'd2)`）：少一根跨模块线、少一个耦合点，
退出应急后换一张图用户不会察觉。
（若 t10 要求"退出应急后图不变"，加门控 `key_event_media = key_event && (key_code==0||key_code==1) && (mode != 2'd2);` 即可，一行。）

### #4 `sensor_fault` 的上屏路径——无端口

`err_prompt`（`rtl/control/err_prompt.v:95-122`）的端口里**没有温度/传感器相关项**，
`osd_caption` / `osd_panel` 也没有。`aht20_ctrl.sensor_fault` 现在无处可去。

| 方案 | 做法 | 代价 |
|---|---|---|
| A | `sensor_fault` 空连接 + TODO 注释 | 传感器坏了用户完全不知道（温度停在最后一个值） |
| B | 改 `err_prompt` 加一个输入 | 动已验证模块（90+ 条断言），回归面扩大 |
| C | 塞进 `osd_caption` 的 `state_line` 文本 | 要改 `osd_strings` 字表，且要新增码位 |

**★ 已裁决（captain，2026-11-02）：采用 A**（空连接 + 注释 + 记降级项 **D-04**），
把 B/C 留给 t10 合规终审裁决。
理由：修 `err_prompt` 端口的收益（一个罕见故障的提示）小于动已验证模块的风险。

**★ 但比「能不能看见」更重要的一条安全性要求：**

```verilog
    // sensor_fault 不进 mode_ctrl，只做 OSD 提示（本 t7 阶段空连接）
    // 传感器坏 ≠ 着火。接错会让终端进应急并且退不出来。
    .sensor_fault(sensor_fault)   // → 当前空连接，t7-A 保留 wire 但不接任何消费者
```

1. `aht20_ctrl.sensor_fault` 为 1 时，`thermal_guard` 必须**继续正常工作**
   （它靠 `temp_alive` 的 2 s 超时自我保护，见 `thermal_guard.v:75-81`：
   失联时**保持 `oth_en` 不变**，不主动进也不主动退）。
2. `mode_ctrl.temp_alarm` **绝对不能**因为 fault 而被拉高。
   → 若有人「顺手」把 fault 接到 alarm 上，就是「传感器坏了 → 永久应急模式 → 退不出去」
   （降温也不退，因为根本没读数）。**这是比"没有高温联动"严重得多的失效。**

### #5 `disp_mode` 延迟生效——无实现

`ARCH_ADDENDUM_VIDEO_PATH.md` §5.2 要求 `content_mux.mode` 接一个 `disp_mode`
（进科普时等 `rle_decoder` 首帧 `ext_frame_ready` 才切，等待期显示图库内容，零闪黑）。
但 **`mode_ctrl` 没有 `disp_mode` 输出**（grep 0 命中），`rle_decoder` 的
`ext_frame_ready` 也还没有被锁存成 `rle_frame_ready_once`。

**★ 已裁决（captain，2026-11-02）：t7-A 临时用 `mode` 直连**
（`T1_TO_T7_WIRING.md` §3.3 已定性：相差 ≤1 拍、不可见）。
**记账日 2026-11-02，不记降级项**，等 t4 交出 `rle_frame_ready_once` 后由 t7 换回真 `disp_mode`。

理由：用 `mode` 直连拿不到「零闪黑」，但**没有 R-06 那个「首帧永不到达 → 界面假死」的风险**。
两害相权，现在这个更好。

> **★ 给 T10 的一句话（原文，请照抄进合规终审意见）：**
> **「若 T10 要求实现真 `disp_mode`，必须同时实现 2 s 超时强制切，否则不得实现。」**
>
> 这句话的作用是防止 T10 只提「要零闪黑」不提「要超时」，让后来人做出一个会假死的版本。

### #6 `osd_caption.caption_en` 语义冲突：`ticker_en_eff` → `caption_en`

`osd_caption.caption_en` 是**字幕层总开关**（`osd_caption.v:219` `if (caption_en)`、
`:258` `band_on = caption_en && (...)`），它同时覆盖三条带：
ticker（`y=448..463`）/ title / state_band。

所以按 Key5 关字幕会**连带关掉标题行与状态行**。而用户 m00001 的原话是
**「底部字幕开关」—— 只有底部那一条**。Key5 关掉标题行和状态行是**需求偏差**，
不是可接受的降级。

**★ 已裁决（captain，2026-11-02）：不降级，D-06 撤销。**

修法（全部在 `rtl/osd/osd_caption.v` 一个文件内，且正好与 t13 的 B-lite 改造同一段代码）：
把 `caption_en` 从「总开关」降为「只关滚动带」。

```verilog
// :219 原：if (caption_en) begin ... 三条带全在里面
// 改为分支各自带条件：
if (ticker_band && caption_en) begin
    // 滚动带：受 Key5 控制（科普模式下它就是视频字幕，同样受 Key5 控制）
end else if (title_band && !narr_en) begin
    // 标题行：不受 Key5 影响
end else if (state_band && !narr_en) begin
    // 状态行：不受 Key5 影响
end

// :258 band_on 同步改为
assign band_on = (ticker_band && caption_en) ||
                 (title_band && band_title_x && !narr_en) ||
                 (state_band  && band_state_x  && !narr_en);
```

（`narr_en` 是 arch-lead 裁定的 B-lite 新端口，正在由 t13 加。`ticker_band` 里的
`active_x` 分支保持原样。）

净收益：① 消灭 D-06 ② 与 B-lite 改的是同一段代码，不会二次动刀
③ 语义变成「Key5 只关底部滚动带」，与用户原文逐字对上，答辩时可以照抄需求原文。

→ **t7-A 照常接 `ticker_en_eff → video_overlay.caption_en`，不需要任何额外动作。**
`osd_caption` 的改动由 rtl-osd 在 t13 完成，t7 只在 `video_overlay.caption_en` 这根线上接。

> **⚠️ 顺序约束**：`narr_en` 端口添加（t13）必须先于 t7-A 的 elaborate，
> 否则 `osd_caption` 还是旧语义，Key5 会连带关标题/状态行。
> 若 t13 未落盘而 t7-A 必须开工，则 **t7-A 允许暂时接 `1'b1`（字幕全开）**，
> 等 t13 落盘后再改成 `ticker_en_eff` —— 但这会让「Key5 无效」，必须记在 t7-A 的回报里。

### #7 `osd_autopop` 没有 `osd_pop_req` 输入

`key_router.osd_pop_req`（单拍）与 `osd_item[4:0]` 目前**无消费者**：
`osd_autopop` 只监视「用户可调参数」的变化，**没有键事件输入**。

> **★ 2026-11-02 t16 更正（原文已过期，勿照旧文复核）**：t16 之前 `osd_autopop.v:65-78`
> 只监视 `bright_sel / invert_en / auto_sw_sel / info_mode` **四个**参数。t16 把
> `bright_sel[2:0]` 换成 `bright_lvl[3:0]` 并追加 `vol_lvl[3:0]` / `res_sel[2:0]` /
> `ratio_sel[2:0]`，现在是**七个**：
>
> ```verilog
> wire changed = (bright_lvl != bright_d) || (vol_lvl != vol_d) ||
>                (res_sel != res_d) || (ratio_sel != ratio_d) ||
>                (invert_en != invert_d) || (auto_sw_sel != autosw_d) ||
>                (info_mode != mode_d);
> ```
>
> 少这三个的后果是「按 Key7/Key8/Key9 参数变了、面板却不弹」，属 E4 缺口 ——
> t16 已补齐。**复位值必须与被监视信号在 key_router 里的复位值逐个对齐**
> （`bright_d=4'd0 / vol_d=4'd6 / res_d=3'd4 / ratio_d=3'd4`），若照老写法全 0，
> 上电第一拍 `changed=1`、面板会自己弹 2.5 s。`tb_osd_autopop.v` 的 P12a~P12d
> 四条断言专守这个不变式。

**★ 已裁决（captain，2026-11-02）：保持现状，不记降级项、不写 TODO。**

`osd_autopop` 已经在监视那**七个**参数的变化（参数一变自动弹 2.5 s）。
**用户按 Key6/Key7/Key8/Key9 改参数时必然触发这七根线中的一根**，
所以「按键即弹」这个 E4 加分项的功能**已经实现了**，只是触发源是「参数变化」
而不是「键事件」—— 后者反而更准（参数没变就不弹）。

`key_router.osd_pop_req` / `osd_item[1:0]` **有意空连接**：

```verilog
    .osd_pop_req(),    // 有意空连接：参数变化驱动已覆盖（§5 #7）
    .osd_item(),       // 有意空连接：同上
```

**不要写 TODO** —— 写了 TODO 将来会有人去接，接上反而会出现
「按了键但参数没变也弹一次」的多余弹窗。

---

## 附录 A0：时序收口备选手段 —— `u_pix_fifo` 改同步读（1,634 LUT → BRAM）

**这一条只在 §5 #1e 的三组时序参数全部失败时才用**，记录在此备查（captain m02510 已把它降为「时序过了之后的余量优化」）。

### 事实

`pix_reader.v:438` 例化了 `async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(FIFO_AW)) u_pix_fifo`，
它是全工程**唯一**的 `async_fifo` 实例。TD 综合时把它推断成了**分布式 RAM（LUTRAM）**：

```
SYN-1027 : Infer Logic DRAM(u_player/u_reader/u_pix_fifo/ramread0_syn_4) read 512x32, write 512x32
SYN-1026 : Infer Logic BRAM(u_player/u_write_fifo/ramread0_syn_4)
SYN-1027 : Infer Logic DRAM(u_rle/ramread0_syn_4) read 512x8, write 512x8
SYN-1027 : Infer Logic DRAM(u_rle/ramread1_syn_4) read 4x32, write 4x32
SYN-1026 : Infer Logic BRAM(u_wav/ramread0_syn_4)
SYN-1023 : Infer 3 Logic DRAMs, 4 Logic BRAMs.
```

**面积表实测：`u_pix_fifo` = 1,634 LUT**（`reports/t7b_gate_area.txt` 层次报告）。

### 为什么它落不进 BRAM（唯一差别已定位）

`u_pix_fifo` 是 **32 × 512 = 16,384 bit**，`u_wav` 的 `fifo_mem` 是 **16 × 1024 = 16,384 bit** —— **容量完全相同**，
一个进了 BRAM、一个掉进 LUTRAM。差别只有一处：

| 模块 | 读口写法 | 推断结果 |
|---|---|---|
| `rtl/common/async_fifo.v:130` | `assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];`（**异步组合读**） | DRAM（LUTRAM） |
| `wav_stream_player.v:420` | 同步读（`always @(posedge clk)` 里赋值） | BRAM |

### 改动与代价

把 `async_fifo` 的读口改成同步读（加一拍延迟），BRAM 就能吃下它。**代价是跨时钟域 FIFO 多一拍读延迟** ——
`pix_reader` 的消费端是 `image_player` 的像素通路，需要确认多一拍不影响 `de` 对齐。

**实测探针结果：−1,577 LUT**（1,634 → 约 57）。这对 `#lut 18,473 / 19,600` 是**决定性的余量**。

> **为什么放最后**：它改的是 `rtl/common/async_fifo.v`（**t12 已冻结的 `pix_reader` 的上游**），
> 会动 `tb_pix_reader` 的 194 条基线。如果时序参数能解决，就不碰它。

## 附录 A：`key_router` 输出的完整归属

> **先说清一个数：`key_router` 实测是 16 个 output + 5 个 input**（`key_router.v:77-110`：
> input `clk`(:77)、`rst_n`(:78)、`key_event`(:81)、`key_code[3:0]`(:82)、`mode[1:0]`(:85)，
> output 见下表 16 行）。
> 派单里说「17 个 output」是**把 `mode` 输入算进去了**。按 17 个数会以为少了一个，
> 实际不差 —— 下表 16 行就是全部。

删 `key_action` 时按这张表逐项划掉（**表里只要还有一项没接，删了就是无驱动**）。

| # | `key_router` 输出 | 位宽 | 接给谁 | t7-A 状态 |
|---|---|---|---|---|
| 1 | `bright_lvl[3:0]` | 4 | `brightness_apply.bright_lvl`（全 4 位）+ `video_overlay.bright_sel`（低 3 位） | 接 |
| 2 | `vol_lvl[3:0]` | 4 | `vol_apply.vol_lvl` | 接 |
| 3 | `res_sel[2:0]` | 3 | 查表 → `eff_src_w/eff_src_h` → `pix_mosaic.src_w` | 接 |
| 4 | `ratio_sel[2:0]` | 3 | `ratio_map.ratio_sel` | 接 |
| 5 | `audio_en` | 1 | （被 `_eff` 取代，本线空连接） | 空 |
| 6 | `ticker_en` | 1 | （被 `_eff` 取代，本线空连接） | 空 |
| 7 | `viz_en` | 1 | `video_overlay.wave_en` | 接 |
| 8 | `osd_pop_req` | 1 | **有意空连接**（参数变化驱动已覆盖，见 §5 #7） | 空 |
| 9 | `osd_item[4:0]` | 5 | **有意空连接**（同上） | 空 |
| 10 | `audio_en_eff` | 1 | `vol_apply.audio_en` + `audio_src_mux.audio_en`（**唯一权威**） | 接 |
| 11 | `ticker_en_eff` | 1 | **`video_overlay.caption_en`** | 接 |
| 12 | `rescan_req` | 1 | **`gallery_probe.rescan`**（顶层 `:184`，不是 `player_ctrl`） | 接 |
| 13 | `pattern_sel[2:0]` | 3 | `test_pattern_gen.pattern_sel` + `seg_decoder u_dec0`（`:609`，**两处**） | 接 |
| 14 | `invert_en` | 1 | `video_overlay.invert_en` | 接 |
| 15 | `grid_en` | 1 | `video_overlay.grid_en` | 接 |
| 16 | `beep_muted` | 1 | `buzzer_tone.tone_sel` 的 `beep_muted ? 3'd0 : ...`（`:578`） | 接 |

> 另有一个 **input** `mode[1:0]` ← `mode_ctrl.mode`（用于应急钳位），见 §2.3。
>
> `P2_EN=1'b0` 时第 12/13/14/15/16 项**恒 0**（`key_router.v:268/272/279/283/287`
> 五处 `P2_EN ? ... : 1'b0`）。这是 t7-A 既定状态：Key11~15 备用功能全部关闭，不会误动作。
> **Key4/Key5 的键号归 `key_router` 了**（`K_AUDIO=4'd4` / `K_TICKER=4'd5`，
> `key_router.v:116-117`）—— 所以顶层 `:84`/`:85` 那两条 `key_code==4/5` 抢 `pattern_sel`
> 的直连**必须删**，否则一次按键动两个参数。

## 附录 B：`mode_ctrl` 与 `player_ctrl` 的键号差异（易错点）

| 键号 | `mode_ctrl`（`:109-110`） | `player_ctrl`（`:220-224`） |
|---|---|---|
| 2 | `K_MODE` 模式循环（日常 ↔ 科普） | `K_PLAY` 播放/暂停（轮播开关） |
| 3 | `K_EMERG` 应急直达 + 双按 2 s 退出 | `K_MODE` 模式循环 |
| 15 | — | `K_EMERG` 应急直达 |

**两套编码不同，同一个物理键在两个模块里含义不同。**

t7-A 的解法是 **`key_event` 事件层门控**（**不是 `key_code` 屏蔽**）：

```verilog
wire key_event_media = key_event && (key_code == 4'd0 || key_code == 4'd1);
```

`player_ctrl` 只收到 Key0/Key1 的事件，它内部的 `K_PLAY=2` / `K_MODE=3` / `K_EMERG=15`
三个分支**永远不会被触发**，两套编码自然解耦，`key_code` 的值一个字节都不用改。

> **★★ 绝对不要写成 `key_code = (…) ? 4'hF : key_code;` 的哨兵形式。**
> `4'hF == 4'd15 == K_EMERG` —— `key_code` 是 `[3:0]`，0..15 全被 Key0~Key15 占满，
> 没有空闲值。用 `4'hF` 当哨兵会把被屏蔽的键**变成应急直达**，
> 而且这个错误仿真抓不到（它"确实"触发了动作，只是动作错了）。

## 附录 C：降级项登记 + 与用户规格的对照

### C.1 降级项（真正丢了功能的）

| 编号 | 内容 | 记录位置 | 用户可感知度 | 归属 |
|---|---|---|---|---|
| **D-01** | AHT20 单传感器无冗余，传感器失效则温度触发失效（应急只剩 Key3） | t6 已落档 | 中 | t6 |
| **D-02** | 轮播间隔倍率不可调（`auto_sw_sel` 固定 `2'd0`，×1） | §3.3 | 低（轮播本身完整） | arch-lead |
| **D-03** | 音频电平条关闭（`level_en` 固定 `1'b0`），可视化只留波形层 | §3.3 | 低（Key10 仍有可视化） | arch-lead |
| **D-04** | 传感器故障（`sensor_fault`）不上屏 | §5 #4 | 低（罕见；且**不允许**因此触发应急） | 本裁决 |

> **D-05 空出来不用**（原「轮播开关/上一张/下一张降级」已撤销 —— §5 #3 定为按用户规格实现）。
> **D-06 撤销**（原「Key5 连带关标题/状态行」已被 t13 的 B-lite 修法消灭 —— §5 #6）。

### C.2 与用户规格的对照（**不是降级项**，只是说明"规格本来就没要求"）

| 项 | 用户 m00001 规格 | 实现 | 说明 |
|---|---|---|---|
| 播放/暂停键 | **未要求** | 无（`key_event_media` 门控掉 `K_PLAY`） | 规格里 Key0~Key10 没有这个键 |
| 自动轮播 | **未要求** | `auto_play_en` 复位 0，永久保持 0 | 纯手动 Key0/Key1 翻页，**正是规格要的行为** |
| `disp_mode` 零闪黑 | 未要求（这是 ARCH 的性能优化） | 暂用 `mode` 直连（§5 #5） | 拿不到零闪黑，但也没有假死风险 |

---

**文档结束。**

本文件是 **t7-A 的执行依据**。§5 七个待定项**已于 2026-11-02 全部裁决完毕**（captain 逐条给结论），落地状态：

| §5 | 结论 | t7-A 动作 |
|---|---|---|
| #1 `pix_reader` Key9 | 端口已落盘；缺 `image_player` 透传层（待 rtl-storage） | **不碰** |
| #2 SD 第五路 | 路径 1：`rle_decoder` 加 `sd_grant`（待 rtl-storage） | 悬空 + TODO |
| #3 `media_player` | `player_ctrl` 保留 + `key_event_media` 门控 | **接** |
| #4 `sensor_fault` | A 方案（空连接），记 D-04，**严禁接 `temp_alarm`** | 空连接 |
| #5 `disp_mode` | 暂用 `mode` 直连，记账 2026-11-02 | `mode` 直连 |
| #6 `caption_en` | 不降级，D-06 撤销，由 t13 改 `osd_caption` | 接 `ticker_en_eff` |
| #7 `osd_pop_req` | 保持参数变化驱动，**有意空连接、不写 TODO** | 空连接 |

> 仍有 2 项**依赖 rtl-storage 落盘**（#1 的透传层、#2 的 `sd_grant`），
> 它们是 **t7-B 的开工前置**，不是 t7-A 的阻塞项。
> 除此之外不得用推测填空 —— 每一处都对应一类静默失败。
