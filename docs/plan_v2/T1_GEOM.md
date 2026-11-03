# t1 几何缩放两模块（pix_mosaic / ratio_map） —— 实现说明与验收数据

> 本文是 t1（Key8 五档分辨率抽样 + Key9 五档屏占比映射）的**实现落地文档**。
> 上位设计见 `ARCH_ADDENDUM_VIDEO_PATH.md` §7 / §9.1、`RESOURCE_BUDGET.md`、`reports/plan_v2/T7_MUST_TEST.md` V-01~V-02；
> 本文只记录**已经写进 RTL 的东西**及其验收数据，供 t8 集成、t10 终审、答辩材料直接引用。
>
> 全部数值都是本机实测（ModelSim ASE + TD 6.24 综合），不是估算。

---

## 1. 交付清单

### 1.1 新增 RTL（2 个）

| 文件 | 行数 | 职责 |
|---|---|---|
| `rtl/video/pix_mosaic.v` | 154 | Key8 水平方向 Bresenham 抽样（单保持寄存器，零行缓存） |
| `rtl/video/ratio_map.v` | 133 | Key9 五档 `ratio_sel` → `win_w/win_h/win_off_x/win_off_y` 纯组合查表 |

### 1.2 新增 testbench（1 个，实跑通过）

| tb | 行数 | 断言编号数 | 实跑断言数 | 覆盖 |
|---|---|---|---|---|
| `sim/testbench/tb_pix_mosaic.v` | 493 | **15**（L1~L7 / I1 / R1~R6 / N1） | **149** | 五档抽样 / 恒等红线 / 五档映射 / 行间切档 / 端到端联动 / 复位 |

> 断言编号 15 条是**断言模板数**；主激励把它们在不同档位、不同驱动路径上重复执行，
> 实跑判定 **149 次**（`SUMMARY: checks=149 pass=149 fail=0`）。

### 1.3 新增仿真脚本（2 个，非 RTL 交付物）

| 文件 | 作用 |
|---|---|
| `sim/scripts/run_t1_geom.ps1` | 定向仿真，判过口径：exit 0 + `ALL CHECKS PASSED: pix_mosaic` + 无失败特征串 |
| `sim/scripts/run_t1_mutant.ps1` | **变异反证**：用刻意写错的 pix_mosaic 喂同一份 tb，判过口径反着来（见 §5） |

### 1.4 面积测点（非交付物，仅为出 §3 的实测数据）

`project/t1_geom_area/` 下 5 个文件：`t1_geom_area_top.v`（含被测模块的 wrapper + 固定参考负载）、
`t1_geom.al`（TD 工程）、`flow_t1_area_{top,ref,mosaic,ratio}.tcl`（4 条面积流程）。

---

## 2. 功能语义

### 2.1 pix_mosaic 抽样语义 = **隔点抽取**（不是像素重复放大）

母带 `SCI.RLE` 实为单支 640×480。Key8 选 320 时，本模块在一行的 640 拍里
**只取 320 拍**、其余拍保持上一个样本值：

```
src_w = 320 → 输出 in[0], in[0], in[2], in[2], in[4], in[4] ...
```

第 i 个抽样点落在输出列

```
p_i = ceil(i * 640 / src_w)        i = 0 .. src_w-1
```

这与「按 `floor(n*w/640)` 做像素重复放大」是**两套自洽语义**（前者每个源列被完整显示
`w/640` 的比例、位置不偏不倚；后者是标准最近邻放大，同一源列会连续出现 `ceil` 次
且列宽在 `floor/ceil` 之间抖动）。本工程采用**抽取式**，
理由：只用一个保持寄存器即可实现，零行缓存，实测 36 纯 LUT（预算口径 64，见 §3.1）；
两种语义在验收红线（「行内不同源列数 == src_w」）下都成立，本选择不影响任何验收项。

### 2.2 ratio_map 档位表

| `ratio_sel` | 显示尺寸 | 偏移 (off_x, off_y) | 面积占比（精确） | TB 打印 |
|---|---|---|---|---|
| 0 | 320 × 240 | (160, 120) | 25.0000 % | 25.0 % |
| 1 | 400 × 300 | (120, 90) | 39.0625 % | 39.0 % |
| 2 | 480 × 360 | (80, 60) | 56.2500 % | 56.2 % |
| 3 | 560 × 420 | (40, 30) | 76.5625 % | 76.5 % |
| 4 | 640 × 480 | (0, 0) | 100.0000 % | 100.0 % |
| 5 / 6 / 7 | 640 × 480 | (0, 0) | 100.0000 % | 100.0 % |

> TB 打印的百分比用整数除法截断，故 39.0625 显示为 39.0、56.25 显示为 56.2、
> 76.5625 显示为 76.5 —— 与设计文档里的 39.1 / 56.3 / 76.6（四舍五入）**不矛盾**。

五档全部满足两条居中不变式，TB 独立断言（R5 / R6）：

```
2 * win_off_x + win_w == 640
2 * win_off_y + win_h == 480
```

**未定义档位 5~7 回落全屏 640×480@(0,0)**，而不是 `0×0`。理由：`image_window_mask`
用 `x_end = win_off_x + win_w` 做右边界，若输出 `0×0` 会把整个画面判成窗口外，
屏幕直接全黑 —— 而 `ratio_sel` 是寄存器输出，上电初值 / 按键抖动 / 在线调试误写
都可能短暂出现非法值。全屏回落是「档位没生效但画面照常显示」的可见无害故障。

---

## 3. 实测资源占用（TD 6.24 综合，器件 EG4S20BG256）

### 3.1 交付口径：独立测量值

被测模块单独作为顶层跑 `elaborate → optimize_rtl → optimize_gate → report_area`：

**先说清口径** —— TD 6.24 的面积报告里有**两个不同的 LUT 字段**，数值不等，必须先对齐
再和基线比：

| 字段 | 出处 | 含义 |
|---|---|---|
| `#Total_luts` | `LUT Statistics` 段 | LUT4/LUT5/LUT6 原语个数（纯查找表） |
| `#lut` | `Utilization Statistics` 段 | **本项目预算口径**，`RESOURCE_BUDGET.md` 的基线 15,319 就是这个字段 |

换算关系（**5 个数据点全吻合，含基线全设计本身**）：

```
#Total_luts = 层级表 top 行 lut  − ripple
Util #lut   = 层级表 top 行 lut  + ripple = #Total_luts + 2 × ripple
```

验证：基线 `diag_key1_fifo_backpressure_20261101/area.txt` 层级表 top 行
`lut = 13008`、`ripple = 2311`，`13008 + 2311 = 15319` —— **与报告里 `#lut` 的 15,319
逐位相同**。四个 T1 测点同样全部精确吻合。

`ripple` 是进位链（carry chain）用量，本模块来自 `x_acc + src_w − 640` 这个 16 位加减法。
两个模块的实测值按两种口径并列如下：

| 模块 | `#Total_luts`（纯 LUT） | 其中 LUT4 | 其中 LUT5 | ripple | `Util #lut`（**预算口径**） | 寄存器 |
|---|---|---|---|---|---|---|
| `pix_mosaic` | **36** | 35 | 1 | 14 | **64** | **16** |
| `ratio_map` | **14** | 14 | 0 | 0 | **14** | **0** |
| **合计** | **50** | 49 | 1 | 14 | **78** | **16** |

`pix_mosaic` 综合后 `#registers = 16`，而 RTL 里声明的寄存器是 `x_acc[15:0]` +
`hold[15:0]` = 32 位，说明综合器把其中一部分吸收进了 LUT 内部反馈结构（`hold` 在
`take` 为真时被 `rgb565_in` 覆盖、为假时自保持，是典型的带使能反馈，可映射到 LUT
的反馈路径）。这一点不影响功能，只说明「约 16 REG」是综合后的实际占用。

**与预算的对照（按 `Util #lut` 口径，与基线 15,319 同一字段）**：

| 项 | 预算 | 实测 | 差 |
|---|---|---|---|
| `pix_mosaic` | 约 40 LUT | **64** | **超 24** |
| `ratio_map` | 约 30 LUT | **14** | 省 16 |
| 合计 | — | **78** | — |

**对外报账必须给三个数，不能只给最悲观的那个**（T1 复核时 captain 指出：独立探针数字
会偏高，若只报 78，t8 集成后发现实际只涨 62 会误以为哪里漏接了）：

| 口径 | 数值 | 性质 |
|---|---|---|
| 独立探针（上面 §3.1 表） | **78** | **上限**。模块单独顶到顶层时 I/O 被拉成 pad、缺上层常量传播，偏大 |
| 同上下文 wrapper（下面 §3.2 的 `t1_geom_area_top`） | **62** | **更接近集成值**。两模块在同一上下文里合计 `Util #lut = 62`（`pix_mosaic` 34 + `ratio_map` 5 + glue 9） |
| t8 主工程 `#lut` 前后相减 | **待填**（记账日 2026-11-02） | **唯一权威**。见下方引用块 |

> **📌 待填真值（留痕，别忘了）**：上面第三行现在是空的。**t8 主工程综合完成后**，
> 由 **t8（rtl-integ）** 回来把「基线 `#lut` / 集成后 `#lut` / 增量」三个实测值填进本表，
> 并把 §8 结论表的「整体资源影响」行同步改成集成实测口径。
> 在填之前，78（上限）与 62（同上下文）**都是探针数，不是集成数** —— 对外引用时必须带上
> 这两个限定词，否则会重蹈「模块独立探针相加系统性高估」的坑。

基线 `RESOURCE_BUDGET.md`：LUT 15,319 / 19,600（78.16%），余量 4,281。**即便按最悲观的
上限 78 报账**，新增后为 15,397 / 19,600 = **78.56%**（**+0.40 个百分点**），只吃掉余量的
**1.8 %**，V-10 门禁（LUT ≤ 19,600）**不受影响**。按 62 计则是 +0.32 个百分点 —— 两种
口径下结论一致，V-10 均通过。

> ⚠️ **给 t8 / t10 的口径提醒（本节最重要的一条）**
>
> `RESOURCE_BUDGET.md §3.1/§3.2` 的逐行估算（`pix_mosaic +40` / `pix_reader +30` /
> `eff_src_w +18` …）与它的基线 15,319 **不是同一把尺子**。证据：本模块预算写「约 40 LUT」，
> 实测纯 LUT 是 36（差 4）、预算口径是 64（差 24）—— 逐行表显然按**纯 LUT** 口算的，
> 而基线 15,319 是 `Util #lut`。
>
> **可执行的结论只有一条**：t8 集成后请直接对**整设计跑一次 `report_area`**，用报告里的
> `#lut` 与 15,319 相减得到真实增量，**不要用逐行表累加去预测**。累加值会偏低约
> `2 × 全设计 ripple 增量`，本模块一项就低 28。
>
> 单看本模块：真实增量按预算是 40、按实测是 64。若把整个设计的 LUT 余量（4,281）当作
> 唯一硬约束，那么**即便 T1 全部按实测 78 计，也只吃掉余量的 1.8 %**，V-10 门禁
> （LUT ≤ 19,600）不受影响 —— 这一点在任何口径下结论都相同。
>
> 多出的 24 全部是 16 位加减法的进位链（`ripple = 14`）。想压回去只能把 `x_acc` 加减法
> 拆成两拍流水或改 8 位分段 —— **不建议**：为 24 LUT 引入拍延迟会破坏本模块
> 「与 `rgb565_in` 同拍」的核心性质，那是红线①的地基。

### 3.2 交叉参考：wrapper 场景

为了确认上表不是「综合器把该保留的逻辑优化掉了」，另跑了两个 wrapper 顶层，
两者带**一字不差的固定参考负载**（32 位环形移位寄存器 `ring_q`），唯一差别是
是否例化被测模块：

| 顶层 | 寄存器 | `#Total_luts` | `Util #lut` | 层级表（lut/ripple/seq） |
|---|---|---|---|---|
| `t1_geom_area_top`（含两模块） | 16 | 34 | 62 | top 48/14/57；`u_pix_mosaic` 34/14/16；`u_ratio_map` 5/0/0 |
| `t1_geom_area_ref`（不含） | 0 | 2 | 2 | top 2/0/30 |

> ⚠️ **差值法不可用**：`62 - 2 = 60` 不能当作两模块的实测面积（独立测量是 78）。
> `ref` 只带一个环形移位寄存器，被综合器优化到 0 寄存器 / 2 LUT，与 `top` 不是同口径
> 基准；`top` 里两模块的输出又被打了一拍寄存，组合逻辑被吸收进寄存器使能路径，因此
> 层级表里 `u_pix_mosaic=34`（而非 36/64）、`u_ratio_map=5`（而非 14）都只是**该场景下的
> 局部读数**，差值法因此低估 18 LUT。
> 交付口径一律取 §3.1 的独立测量值，本节仅作「量级无异常」的交叉印证。

### 3.2.1 §3.1 换算公式的正确用法 —— 两个禁止

§3.1 的 `Util #lut = 层级表 lut + ripple` 只在**单模块探针**上成立。用错场景会算出荒谬数字，
被 t10 审计时误判成「公式错了」：

| 用途 | 允许的方法 | **禁止**的方法 | 禁止的原因 |
|---|---|---|---|
| 验证公式本身 | 单模块探针（把模块单独顶到 top，附固定参考负载） | —— | —— |
| 算**集成增量** | 全局 `Utilization Statistics` 的 `#lut` **前后相减**（新的减 15,319） | ❌ **全局层级表 Σlut / Σripple 求和** | 全局层级表是**嵌套展开**的（70 行，父实例与子实例都列，`image_player` 底下还挂着 `img_scaler`/`pix_reader`/`fade_mixer`），**父子重复计数** |

实测反证（勿再重复踩）：对基线 `diag_key1_fifo_backpressure_20261101/area.txt` 的全局层级表
逐行求和得 `Σlut = 39,366`、`Σripple = 6,345`，无论 `Σlut − Σripple = 33,021` 还是
`Σlut + Σripple = 45,711`，**都远大于全局 `#lut = 15,319`** —— 差异全部来自父子重复计数。

> **两句话记住**：
> ① 验证公式 → 只能用**单模块探针**；
> ② 算集成增量 → 只能用**全局 `#lut` 前后相减**。
> 任何「照着层级表加一遍」的做法都会得到 39,366 这种数字，那不是公式的问题。

### 3.3 复现命令

```
D:/TD_6_24_APP/bin/td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/t1_geom_area/flow_t1_area_mosaic.tcl
D:/TD_6_24_APP/bin/td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/t1_geom_area/flow_t1_area_ratio.tcl
```

（路径必须用正斜杠；日志 `td_YYYYMMDD_HHMMSS.log` 落在该目录，
`reports/area_*.txt` 为 `report_area` 原始输出。）

---

## 4. 五档抽样实测数据

数据源：`tb_pix_mosaic.v` 的 L1~L7 逐行检查，实测于 `sim/work/t1_geom/transcript_pix_mosaic.txt`。

| `src_w` | 不同源列数（红线②） | 观测块数 | 块宽实测 | 块宽理论 | 抽样位置 `[0..11]` | 参考模型误差 |
|---|---|---|---|---|---|---|
| 640 | **640** | 640 | 1..1 | 1..1 | 0 1 2 3 4 5 6 7 8 9 10 11 | 0 |
| 576 | **576** | 576 | 1..2 | 1..2 | 0 2 3 4 5 6 7 8 9 10 12 13 | 0 |
| 512 | **512** | 512 | 1..2 | 1..2 | 0 2 3 4 5 7 8 9 10 12 13 14 | 0 |
| 480 | **480** | 480 | 1..2 | 1..2 | 0 2 3 4 6 7 8 10 11 12 14 15 | 0 |
| 400 | **400** | 400 | 1..2 | 1..2 | 0 2 4 5 7 8 10 12 13 15 16 18 | 0 |
| 320 | **320** | 320 | 2..2 | 2..2 | 0 2 4 6 8 10 12 14 16 18 20 22 | 0 |
| 560 | **560** | 560 | 1..2 | 1..2 | 0 2 3 4 5 6 7 8 10 11 12 13 | 0 |

- 「不同源列数 == `src_w`」列全部命中 → **红线②成立**，行内不累积误差。
- 「参考模型误差」= 与 TB 内独立实现的 `ceil(i*640/src_w)` 闭式解逐拍比对的失配数，
  全为 0。两侧写法完全不同（DUT 是寄存器累加，TB 是整数除法），同时通过才说明
  抽样**位置**也无误，而不只是数量对。
- `src_w = 640` 时块宽恒为 1 → 每拍都抽样，即**恒等旁路**（红线①，见 §5）。
- `src_w = 560` 只出现在 E 组（`ratio_map` 档 3 端到端），不在 V 组：Key8 的
  `res_sel` 五档是 640/576/512/400/320，560 是 Key9 的 `win_w` 之一。

---

## 5. 两条验收红线与「断言有牙」的证明

### 5.1 红线①：`src_w = 640` 逐拍恒等

`tb_pix_mosaic.v:337` 的 I1 断言：连续 640 拍逐拍比较

```verilog
if (rgb565_out !== rgb565_in) err = err + 1;
```

`SUMMARY: checks=149 pass=149 fail=0` → I1 通过，**640/640 拍全等**（不是近似）。

实现保证：`rgb565_out` 是**组合**赋值 `take ? rgb565_in : hold`，与 `rgb565_in` 同拍；
`valid_out` 是 `valid_in` 直通。模块不引入任何延迟。

### 5.2 红线②：`src_w < 640` 时不同源列数恰等于 `src_w`

见 §4 表格，320 / 400 / 512 / 576 / 480 / 560 全部命中。

### 5.3 变异反证 —— 这份 TB 真能抓到那个静默缺陷

需求背景：`ARCH_ADDENDUM_VIDEO_PATH.md:462-469` 的伪码把输出写成时序块里的
`rgb565_out <= take ? rgb565_in : hold;`。非阻塞赋值取的是**本拍更新前**的 hold，
而 `take` 又是在同一个时钟沿才判定 —— 输出整体**落后一拍**，`src_w = 640`
（Key8 默认档）时表现为画面整体左移 1 像素、右侧补 1 列残留像素，且**不报错、
不黑屏、综合与静态时序全绿**。

为了证明本 TB 不是「只会打印 PASS」，构造了变异体
`sim/work/mut_t1/pix_mosaic_mutant.v`（模块名故意也叫 `pix_mosaic`，**完全照抄伪码**，
端口与真身一致），用 `run_t1_mutant.ps1` 顶替真身编译进同一份 tb：

```
变异体结果: exit=0 CHECKS_FAILED=True I1抓到=True fail=80
[PASS] 反证成功：TB 抓到了伪码版本的"落后一拍"缺陷（I1 恒等断言失败）
```

同一份 tb 对伪码版本抓出 **80 项失败**（含 I1 恒等断言）。⇒ 断言**有牙**：
正确版本 149/149 全过、错误版本 80 项失败，区分度明确。

> 该变异体与 `run_t1_mutant.ps1` 位于 `sim/work/` 与 `sim/scripts/`，**不是交付 RTL**，
> 不参与工程编译，也不进入 `rtl/` 的任何目录。

---

## 6. 端口契约与集成须知（给 t8 / rtl-integ）

### 6.1 与 addendum §9.1 的差异（**以本实现为准**）

| 项 | addendum §9.1 (:440-457) | 本实现 | 理由 |
|---|---|---|---|
| 时钟名 | `pixel_clk` | `clk` | 任务书枚举为 `clk`；工程内其余 `rtl/video/` 模块统一叫 `clk` |
| `de` 输入 | 有 | **无** | 本模块是组合直通、零延迟，`de` 门控由下游 `video_content_mux` 完成；多一个 `de` 端口只会让 `valid_in` 与 `de` 出现两条语义重叠的使能路径 |
| 参数化 | `H_ACTIVE`/`V_ACTIVE` 参数 | `localparam OUT_W = 640` | 本设计只工作在「已定标到 640 宽」的视频域，参数化会多出未被覆盖的编译分支 |
| 输出类型 | `rgb565_out` 为 reg | **wire** | 必须是组合输出，否则红线①不可能成立（见 §5.3） |

**`valid_in` 的接法（2026-11-02 复核后修正，以此为准）**：接 `u_player.pixel_valid`
（即 `image_player` 的原始像素有效，**未经窗口门控**）。三点理由：

1. **接 `image_window_mask.pixel_valid_out` 会构成组合自环**：该输出已含 `in_window`，
   再回喂 `pix_mosaic.valid_in → valid_out → image_window_mask.pixel_valid`，
   在 `pixel_valid_out` 上形成组合环，综合器会报 loop。
2. **「窗口外也在抽样」不是缺陷**：`pix_mosaic` 的抽样相位只由
   `active_x`（`pix_mosaic.v:115` 的 `take = (active_x == 11'd0) || (x_acc >= OUT_W)`）
   与 `src_w` 决定，`valid_in` 在 `:122` 是 `assign valid_out = valid_in;` **纯直通**，
   不参与 `x_acc`/`hold` 任何赋值（`:133-152` 的时序块里没有它）。
   所以窗口外抽样、但被 mask 掉，是**设计意图**，抽样与门控正交。
3. **不要接 `de`**：`de` 是全行有效（含窗口外），它的语义比 `pixel_valid` 更宽，
   会把 `image_player` 在非图像区域给出的无效像素当成有效像素放行。

> 完整论证与拓扑图见 `docs/plan_v2/T1_TO_T7_WIRING.md` §5 问题① 与 §2.3。

### 6.2 两个模块之间的接线 —— **两者不是串联的（2026-11-02 修正）**

> ⚠️ **本节此前写错，已修正。** 原稿说「`ratio_map.win_w` **就是** `pix_mosaic.src_w`，
> 无需另设端口」—— 那是 Key9 还打算由 `pix_mosaic` 执行的旧设想（D 方案），
> 已被实测证否（见 `T1_TO_T7_WIRING.md` §5 问题③）。**`src_w` 与 `win_w` 是两个不同的量**：
> `src_w` 来自 Key8（`res_sel` 查表），`win_w` 来自 Key9（`ratio_sel` 经 `ratio_map`）。

正确接线：两个模块**并联**，各自服务不同的参数轴。

```verilog
// ---- Key8：分辨率五档 → 源宽/源高（查表 + 应急钳位，详见 §6.3 与 T1_TO_T7_WIRING.md §3）----
reg [15:0] res_src_w, res_src_h;
always @(*) begin
    case (res_sel)
        3'd0:    begin res_src_w = 16'd320; res_src_h = 16'd240; end
        3'd1:    begin res_src_w = 16'd400; res_src_h = 16'd300; end
        3'd2:    begin res_src_w = 16'd512; res_src_h = 16'd384; end
        3'd3:    begin res_src_w = 16'd576; res_src_h = 16'd432; end
        default: begin res_src_w = 16'd640; res_src_h = 16'd480; end
    endcase
end
wire [15:0] eff_src_w = (disp_mode == 2'd2) ? 16'd640 : res_src_w;   // Key8 应急钳位
wire [15:0] eff_src_h = (disp_mode == 2'd2) ? 16'd480 : res_src_h;

// ---- Key9：屏占比五档 → 窗口参数（纯组合，两路消费者）----
wire [10:0] rm_win_w, rm_win_off_x;
wire [9:0]  rm_win_h, rm_win_off_y;
ratio_map u_ratio_map (
    .ratio_sel (ratio_sel_eff),     // (disp_mode == 2'd2) ? 3'd4 : ratio_sel
    .win_w     (rm_win_w),
    .win_h     (rm_win_h),
    .win_off_x (rm_win_off_x),
    .win_off_y (rm_win_off_y)
);
// 11/10 → 16 位补零（数值上限 640 < 1024，补零无损）
wire [15:0] mask_win_w     = {{5{1'b0}}, rm_win_w};
wire [15:0] mask_win_off_x = {{5{1'b0}}, rm_win_off_x};
wire [15:0] mask_win_h     = {{6{1'b0}}, rm_win_h};
wire [15:0] mask_win_off_y = {{6{1'b0}}, rm_win_off_y};
// ★ 这四个 wire 必须同时喂给 image_window_mask（位置门控）与 pix_reader（窗口内降采样），
//   接成两个不同来源 → 窗口位置与采样范围错位 → 画面被切一半且不报错。

pix_mosaic u_pix_mosaic (
    .clk        (pixel_clk),
    .rst_n      (rst_n),
    .active_x   (active_x),
    .src_w      (eff_src_w),        // ← Key8，不是 win_w
    .rgb565_in  (img_rgb565),
    .valid_in   (img_pixel_valid),  // ← u_player.pixel_valid，见 §6.1
    .rgb565_out (pix_out),
    .valid_out  (pix_valid)
);
```

`ratio_map` 的输出宽度（11/10 位）比 `image_window_mask` 的 `win_*`（16 位）窄，
接线时必须显式补零（如上）。

**Key9 的执行者不是 `pix_mosaic`。** 2026-11-02 裁决：Key9 落在 `pix_reader`
的**消费侧降采样**（`src_col(n) = floor((n - off_x) * src_w / win_w)`），
因为水平缩小需要「源列已流过」时仍能取到它，而 `pix_mosaic` 的输入流与输出流共用
`active_x` 一把标尺、只有单寄存器 `hold`，物理上只能放大、不能缩小。
完整证否过程（含 bit-exact 对照表）见 `docs/plan_v2/T1_TO_T7_WIRING.md` §5 问题③。
**本模块（`pix_mosaic`）的语义与端口因此完全不变，149 条断言继续有效。**

### 6.3 应急态钳位 —— **顶层负责，本模块不引入 `disp_mode`**

`addendum :380` 规定：`disp_mode == 2'd2`（应急）时几何参数强制 640×480@(0,0)，
且**不吞按键**（按键照常更新 `ratio_sel`，退出应急立刻恢复用户原档位）。

正确做法是在顶层做一层**选择**而不是改写寄存器：

```verilog
wire [2:0] ratio_sel_eff = (disp_mode == 2'd2) ? 3'd4 : ratio_sel;
```

档 4 的查表结果正是 640×480@(0,0)，因此 `ratio_map` 与 `pix_mosaic` 都无需改动，
一行三目式即可满足"退出应急自动恢复"。**不要**把 `disp_mode` 塞进这两个模块：
钳位点必须与应急画面来源同源，且要同时影响 `win_*`、`pix_reader` 的垂直映射和
`content_mux` 的通路选择 —— 那是顶层职责。

> 另注：`emerg_page` 从 `content_mux` 的 `2'd2` 位置注入，**不受** `image_window_mask`
> 与 `pix_mosaic` 影响（addendum :378）。即应急画面本身不走这条图像路。

### 6.4 垂直方向与 Key9 降采样都不在本任务范围

Key8 的**垂直**抽样（行映射）由 `rtl/storage/pix_reader.v` 完成，属 t4 (rtl-storage)
文件域。本任务只交付水平方向。`reports/plan_v2/T7_MUST_TEST.md` 的 V-03 是
`pix_reader` 的必测项，不在本文覆盖范围内。

**Key9（屏占比）的「窗口内降采样」同样落在 `pix_reader`**（2026-11-02 裁决，
理由见 §6.2 末）。本文交付的 `ratio_map` 只负责**输出五档窗口参数并保证档位表正确**
（R1~R6 六条断言覆盖）与**未定义档位回落全屏**（避免 `image_window_mask` 判全屏窗外导致黑屏）；
窗口内取哪个源列、跳哪些源行，属 t4 的实现，其逐拍契约由 t4 的交付文档给出。

---

## 7. 门禁与复现

### 7.1 仿真

```
& D:\FPGA_Compelate\SmartCampusMedia\sim\scripts\run_t1_geom.ps1
```

实测输出：

```
SUMMARY: checks=149 pass=149 fail=0
ALL CHECKS PASSED: pix_mosaic
[PASS] tb_pix_mosaic 全部断言通过 (exit=0)
```

仿真时间 103111 ns（640 拍/行 × 多组激励 + 行间消隐）。

### 7.2 lint

在 `D:\FPGA_Compelate\SmartCampusMedia` 下：

```
python scripts\lint_verilog.py
```

实测输出：

```
检查文件数: 65
E0(文件损坏): 0    E1(赋值混用): 0    E2(多驱动): 0
结论: 通过（无损坏 / 无混用赋值 / 无多驱动）
```

任务书要求「58+ 文件」，实测合格。**文件数是活值**：lint 默认只扫 `rtl/` 目录
（`scripts/lint_verilog.py:143`，`targets = argv[1:] or ['rtl']`），团队其他成员在
并行新增文件，因此同一命令在不同时刻会打印 64 / 65 / … —— 判定只看
E0/E1/E2 三项是否为 0 与是否打印「结论: 通过」，不看文件数本身。
本次交付的 3 个文件对 E0/E1/E2 均无贡献：

- **E0**（分号后孤立标识符）：注释为纯 `//` 行注释，行尾从不出现裸标识符。
- **E1**（同一 always 块内 `=` 与 `<=` 混用）：`pix_mosaic` 唯一时序块全用 `<=`；
  `ratio_map` 唯一组合块全用 `=`。**不同** always 块之间不构成混用。
- **E2**（多驱动）：`pix_mosaic` 中 `x_acc`/`hold` 只由 1 个 always 块驱动，
  `rgb565_out`/`valid_out` 只由 `assign` 驱动（同一变量不同时出现在 `assign` 与时序块里）；
  `ratio_map` 四个输出只由 1 个组合块驱动。

### 7.3 脚本编码注意（环境坑，已修）

本机只有 Windows PowerShell 5.1（无 `pwsh` 命令）。**PS 5.1 按 ANSI/GBK 解析无 BOM
的 `.ps1`**，脚本内中文字符串会把引号吃掉导致 `ParserError`。两个脚本均已存为
**UTF-8 with BOM**。后续任何人改这两个脚本，请保持 BOM。

另：ModelSim ASE 写 transcript 用系统代码页（GBK），中文 `$display` 内容在 transcript
里会 mojibake（既有 `tb_brightness_apply.v` 等同现象）。判过依据
（`PASS:` / `FAIL:` / `SUMMARY:` / `ALL CHECKS PASSED:`）全部是 ASCII，不受影响；
阅读 transcript 时按 GBK 解码即可。

---

## 8. 结论

| 门禁项 | 要求 | 实测 | 结论 |
|---|---|---|---|
| 红线① `src_w=640` 逐拍恒等 | 全等 | 640/640 拍 === | **通过** |
| 红线② 不同源列数 == `src_w` | 320/400/512/576 各一次 | 4 档全部命中（另加 480/560） | **通过** |
| TB | `ALL CHECKS PASSED` + fail=0 | 149/149，fail=0 | **通过** |
| lint | 58+ 文件 E0/E1/E2 全 0 + 「结论: 通过」 | 65 文件，三项全 0，打印「结论: 通过」 | **通过** |
| pix_mosaic 面积 | 约 40 LUT / 16 REG | 纯 LUT 36 / 预算口径 64；REG 16 | 纯 LUT 低于预算，预算口径超 24（见 §3.1 口径说明） |
| ratio_map 面积 | 约 30 LUT | 14 LUT / 0 REG（两口径同为 14） | **低于预算** |
| 整体资源影响 | V-10：LUT ≤ 19,600 | 独立探针 78（上限）/ 同上下文 62 / 实际以 t8 `#lut` 相减为准；最悲观 78 时 78.56% | **通过**（三口径结论一致） |
| 断言有效性 | — | 变异反证 fail=80（含 I1） | **有牙** |
