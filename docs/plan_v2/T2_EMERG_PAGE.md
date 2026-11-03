# t2 应急模式平面示意图（emerg_page）—— 实现说明与验收数据

> 本文是 t2（`rtl/video/emerg_page.v` 应急平面示意图 + testbench + 定向回归入口）的**实现落地文档**。
> 上位设计见 `PLAN.md` / `ARCH.md` / `ARCH_ADDENDUM_VIDEO_PATH.md`；分层裁意见 `reports/plan_v2/EMERG_SCREEN_RULING.md`；本文只记录**已经写进 RTL 的东西**及其验收数据，供 t7 接线、t8 集成、t9 回归、t10 终审、t11 答辩材料直接引用。
> 全部数值都是本机实测（仿真 / TD 6.2 post-route 报告）或代码本身可核对的常量，不是估算；凡不是实测的地方会显式标「外推」。

---

## 1. 交付清单

### 1.1 新增 RTL（1 个）

| 文件 | 行数 | 职责 |
|---|---|---|
| `rtl/video/emerg_page.v` | 123 | 640×480 应急平面示意图，纯组合、零寄存器、零 BRAM、零 DSP、零时钟、零状态机 |

### 1.2 改动 RTL

无。**未改动** `rtl/video/video_content_mux.v`（`2'd2` 分支的接线由 t7 负责，本模块只保证端口契约）。

### 1.3 新增 testbench（1 个）

| tb | 断言数 | 覆盖 |
|---|---|---|
| `sim/testbench/tb_emerg_page.v` | **57** 行 `# PASS:`（49 个像素点断言 + 7 个结构/计数断言 + 1 条全帧预览生成记录；`SUMMARY` 报 `checks=57 errors=0 fail=0`） | 外墙四条边及四条边各自 4 px 厚度、房间填充、上下两排分格竖线（各 2 px）及相邻留白、主走廊首末行与上下边界、北支走廊左右边界、当前位置块中心/两角/与路线的相接关系、两个出口的中心与角点与两侧留墙、路线横臂/竖臂/直角拐点/抵达出口/末行/不渗出/左右邻点、消隐全黑、全帧 640×480 扫描（层计数 + 路线包围盒 + 逐行轴对齐证明）、调色板覆盖全帧 |

### 1.4 新增回归入口（1 个，独立脚本）

| 文件 | 说明 |
|---|---|
| `sim/scripts/run_t2_emerg.ps1` | t2 定向回归：重建库 → `vlog` 编译 `emerg_page.v` + `tb_emerg_page.v` → `vsim` 跑 `tb_emerg_page` → 判过口径 `exit 0` + 出现 `ALL CHECKS PASSED: emerg_page` + 无失败特征串 |

> **为什么是独立脚本而不是改 `run_frontend_regression.ps1`**：团队八个成员的文件域互不重叠，`sim/scripts/run_frontend_regression.ps1` 是集成回归域（t7/t9）。本任务按 `sim/scripts/run_t1_geom.ps1` 的既有先例新增独立入口，不动共享文件。
> t9 若要并入总回归，只需在 `run_frontend_regression.ps1` 的 `$sources` 增加两行、`$cases` 增加一行：
> ```powershell
> # $sources
> 'rtl/video/emerg_page.v',
> 'sim/testbench/tb_emerg_page.v',
> # $cases
> @{name='emerg_page'; top='tb_emerg_page'; marker='ALL CHECKS PASSED: emerg_page'; arguments=@()},
> ```

### 1.5 交付文档

即本文件。

---

## 2. 模块定位（答辩可直接引用）

`emerg_page.v` 把「应急模式」从一整屏纯红，换成一张**楼层平面示意图**：楼层外墙、走廊、房间分格、当前位置、两个出口，以及一条从当前位置到最近出口的直角折线路线。

值得讲的是它的**实现方式与失效边界**，而不是算法复杂度：

> 这张图不是一张图片。仓库里没有它的位图，SD 卡里也没有它的文件，整个工程没有任何一行代码把它从外部读进来。640×480 的每一个像素，都是在这一帧的那一拍，用它自己的行列坐标（`active_x` / `active_y`）当场算出来的——比较、与或、查表都不需要，只有坐标范围比较。这就是 FPGA 内实时栅格化。
>
> 因此它的可用性边界与存储链路完全解耦：**SD 卡拔了、卡坏了、卡没格式化、FAT32 表被写乱、图片文件全丢，这张平面示意图照样显示，疏散路线照样画出来**。它和按键、按键状态机、模式切换在同一个时钟域里，切到应急模式的下一帧就有内容，不需要等任何存储访问。
>
> 这也是它在整个工程里的定位：不是又一个炫技的特效，而是用来演示「多源驱动的显示系统在存储链路失效时仍然保有可读画面」这一条稳定性要求。赛事对显示类作品的要求里，能显示、切得动、画面可读是硬指标；本模块把「最坏情况下屏幕上还有结构化信息」这件事，做成了一个 339 个逻辑单元、0 块 BRAM、0 个 DSP、0 个寄存器的组合电路。

配套文字（标题、路线说明等大字提示）**不在本模块里画**：文字由既有 OSD 字幕层（`rtl/osd/osd_caption.v` 及 t3 的中文扩展）承担，本模块只出图形。这样字库的进度不会卡住应急页上线，本模块也不需要任何字形 ROM。

---

## 3. 逐区块像素判定式

坐标全部为**半开区间 `[lo, hi)`**，取值域 `active_x[10:0] ∈ [0,640)`、`active_y[9:0] ∈ [0,480)`。下表每一行的判定式都与 `rtl/video/emerg_page.v` 中的 `wire` 一一对应，可直接对照源码核对。

### 3.0 调色板（`localparam`）

| 名称 | 值 | 用途 |
|---|---|---|
| `C_BG` | `24'h0B_10_20` | 页面底色（外墙矩形以外） |
| `C_ROOM` | `24'h0F_19_27` | 房间填充 |
| `C_CORR` | `24'h1B_2E_44` | 走廊地面 |
| `C_WALL` | `24'h46_63_82` | 外墙框 |
| `C_DIV` | `24'h2A_44_60` | 房间分格竖线 |
| `C_POS` | `24'h00_C8_E0` | 当前位置（青） |
| `C_EXIT` | `24'h3C_D8_5A` | 出口（亮绿） |
| `C_ROUTE` | `24'hFF_D2_3C` | 疏散路线（琥珀） |

> `C_POS` 与 `C_EXIT` 沿用 `reports/plan_v2/EMERG_SCREEN_RULING.md` §5 的指定值（青 `00C8E0` / 亮绿系高对比），其余为配合本页深色底新增。

### 3.1 外墙矩形与外墙框

| 量 | 判定式 | 像素数 |
|---|---|---|
| `x_in_plan` | `active_x >= 11'd64 && active_x < 11'd575` | — |
| `y_in_plan` | `active_y >= 10'd72 && active_y < 10'd408` | — |
| `wall_v` | `active_x < 11'd68 \|\| active_x >= 11'd571` | — |
| `wall_h` | `active_y < 10'd76 \|\| active_y >= 10'd404` | — |
| `wall` | `x_in_plan && y_in_plan && (wall_v \|\| wall_h)` | 6 712 − 224 = **6 488** |

- 外墙矩形 `x[64,575) × y[72,408)` = 511 × 336 = 171 696 px。
- 框厚恒为 4 px（四条边各自实测 4 px，见 §7 的 `outer wall, * band is 4 px thick` 四条断言）。
- 墙内可通行区 `x[68,571) × y[76,404)` = 503 × 328 = 164 984 px。
- 6 712 − 224 的 224 px 是两个出口标记压在墙带上的部分（28×4 + 4×28），出口优先级高于墙，故从墙计数中扣除。

### 3.2 走廊

| 量 | 判定式 | 像素数 |
|---|---|---|
| `y_main_corr` | `active_y >= 10'd224 && active_y < 10'd248` | — |
| `y_upper` | `active_y >= 10'd76 && active_y < 10'd224` | — |
| `y_lower` | `active_y >= 10'd248 && active_y < 10'd404` | — |
| `x_interior` | `active_x >= 11'd68 && active_x < 11'd571` | — |
| `x_branch` | `active_x >= 11'd152 && active_x < 11'd176` | — |
| `corridor` | `(y_main_corr && x_interior) \|\| (y_upper && x_branch)` | **13 904** |

- 主走廊：满宽横带 24 px 高，`24 × 503 = 12 072` px。
- 北支走廊：`24 × 148 = 3 552` px。
- 两者毛面积 15 624 px，减去被更高优先级图层覆盖的 1 720 px（路线竖臂在支走廊内的 552 px、路线在主走廊内的 256 px、当前位置块 384 px、出口 B 在主走廊内的 288 px、出口 A 压在支走廊顶部 10 行的 240 px）= **13 904**，与仿真计数逐位一致。

### 3.3 房间与分格竖线

| 量 | 判定式 | 像素数 |
|---|---|---|
| `room` | `x_in_plan && y_in_plan && (y_upper \|\| y_lower) && !corridor` | **147 152** |
| `div_upper` | `active_x[6:0] < 7'd2`（即 `x mod 128 ∈ {0,1}`） | — |
| `div_lower` | `active_x[6:0] == 7'd64 \|\| active_x[6:0] == 7'd65`（即 `x mod 128 ∈ {64,65}`） | — |
| `divider` | `x_interior && ((y_upper && div_upper) \|\| (y_lower && div_lower))` | **2 120** |

- 分格全部是**纯竖线**，宽 2 px；上排（走廊以上）节距 128 px，下排（走廊以下）节距 128 px 且整体偏移 64 px，所以两排房间**永远不会对齐**，平面图一眼能看出是「上排房间 / 下排房间」而不是一张网格。
- 上排 8 条竖线 × 148 行 = 1 184 px；下排 6 条竖线 × 156 行 = 936 px；合计 **2 120** px，与仿真计数一致。
- 判定式只用**位选 + 单比较**（`active_x[6:0]` 与本位常量比），没有除法、没有取模运算、没有乘法器。

### 3.4 当前位置块

| 量 | 判定式 | 像素数 |
|---|---|---|
| `pos_block` | `active_x ∈ [216,240) && active_y ∈ [228,244)` | **384** |

24 × 16 px 实心青色块，落在主走廊带内（`y[228,244) ⊂ y[224,248)`），横向位置偏向支走廊一侧，符合「人在走廊里、离北侧出口更近」的构图。

### 3.5 两个出口

| 量 | 判定式 | 像素数 |
|---|---|---|
| `exit_a`（北墙开口） | `active_x ∈ [150,178) && active_y ∈ [72,86)` | 28 × 14 = **392** |
| `exit_b`（东墙开口） | `active_x ∈ [559,575) && active_y ∈ [222,250)` | 16 × 28 = **448** |
| `exit_mark` | `exit_a \|\| exit_b` | **840** |

两个出口都是「骑在墙上」的实心亮绿块：出口 A 覆盖北墙内 4 px 并向下伸入支走廊 10 px，出口 B 覆盖东墙 4 px 并向左伸入主走廊 12 px。因为出口的渲染优先级高于外墙，视觉上是**墙体上开了口子**，而不是在墙面上贴了两个绿点。两个出口互相远置（一个正上方、一个最右侧），路线「到最近的出口」才有意义。

### 3.6 疏散路线（直角折线）

| 量 | 判定式 | 像素数 |
|---|---|---|
| `route_h` | `active_y ∈ [234,238) && active_x ∈ [162,216)` | 54 × 4 = 216 |
| `route_v` | `active_x ∈ [162,166) && active_y ∈ [86,236)` | 4 × 150 = 600 |
| `route` | `route_h \|\| route_v` | **808** |

- 先横后竖：从当前位置块左边缘（`x=216`）出发沿走廊中心线向西（`y[234,238)`，4 px 宽），到 `x[162,166)` 处**直角转弯**，再向北沿支走廊中心线（`x[162,166)`）一直到出口 A 下沿（`y=86`）。
- 两臂重叠只有 `x[162,166) × y[234,236)` = 8 px，故并集 = 216 + 600 − 8 = **808** px。
- **无斜线的结构性保证**：折线由两个互相垂直的矩形并集构成，判定式里**没有任何乘法、没有任何形如 `a*x + b*y` 的比较**。testbench 另有逐行扫描断言（§7），证明每一行的路线像素要么落在 4 px 竖带内、要么落在 4 px 横带内，不存在跨带的中间像素——这是「不可能出现斜线」的实测证据，而不只是源码写法的口头保证。

### 3.7 渲染优先级（单 `always @*` 级联）

```
rgb_out = C_BG                 // 默认值（外墙矩形以外）
if (!de) rgb_out = 24'd0       // 消隐期强制黑
else 依次覆盖：room → corridor → divider → wall → route → pos_block → exit_mark
```

后者覆盖前者，共 7 层。全帧层计数与总面积的自洽校验：

```
147 152 + 13 904 + 6 488 + 2 120 + 384 + 840 + 808 = 171 696 = 511 × 336（外墙矩形面积）
```

即**外墙矩形内部没有留下任何底色像素**，平面图是满的；剩下 `307 200 − 171 696 = 135 504` px 全是页面底色 `C_BG`。testbench 里有断言逐项核对这个和（见 §7 的 `palette covers all 307200 pixels`）。

---

## 4. 端口契约与集成约定（给 t7 的接线说明）

```verilog
module emerg_page (
    input  wire        de,
    input  wire [10:0] active_x,
    input  wire [9:0]  active_y,
    output reg  [23:0] rgb_out
);
```

**严格四端口**，与 `rtl/video/science_page.v` 完全同构，`video_content_mux` 可以用一次 2:1 选择在科普页和应急页之间切换，不需要任何额外握手或时序适配。

### 4.1 与 addendum 五端口方案的取舍（需记录在案）

`docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md` §9.3 给的是**五端口**（多一个 `input wire blink`，用于出口闪烁）。本次按任务书的硬禁令实现**四端口**，理由：

1. **P1 的出口闪烁本身不实施**（`EMERG_SCREEN_RULING.md` 把闪烁列为 P1，「需外部 blink 输入、t8 提供 blink 源」）。为本轮不实施的功能预埋端口，会让端口契约与实现不一致，反而成为终审的疑点。
2. **纯组合、零时钟是本模块最值钱的性质**。引入 `blink` 就引入了一个外部时序输入，`emerg_page` 不再是「只依赖本像素坐标」的函数，PRECHECK 的 E-01「纯组合」验收项会从「结构性成立」退化成「依赖外部信号的行为约定」。
3. 后端要加闪烁时，改动是**纯增量的**：加一个 `input wire blink` 端口、在 `exit_mark` 的覆盖条件里与上 `blink`（或做两档亮度），不影响任何现有判定式，也不影响 t7 现有的四端口连线（Verilog 允许例化时悬空新端口，只需同步 tb）。

**给 t7 的例化写法**（不写 `.blink`）：

```verilog
emerg_page u_emerg_page (
    .de       (disp_de),
    .active_x (disp_x),
    .active_y (disp_y),
    .rgb_out  (emerg_rgb)
);
```

`disp_de` / `disp_x` / `disp_y` 必须与 `science_page`、`video_overlay` 用的是**同一组**显示时序信号（同一拍、未打拍、未插寄存器），否则 OSD 字幕层按 x/y 定位会与图形错开。

### 4.2 不做什么（明确边界）

| 项 | 决定 | 依据 |
|---|---|---|
| 内嵌中文字形 ROM | **不做**。文字走 `osd_caption` 字幕层 | 任务书硬禁令；好处是字库延误不阻塞应急页上线，本模块 0 BRAM |
| 斜线 / 圆弧 / 任意角度箭头 | **不做**。路线严格横 + 竖 | 斜率计算要乘法器，DSP 全片只剩 10/29；且 `EMERG_SCREEN_RULING` 明确要求直角折线 |
| 多套平面图可切换 | **不做** | `EMERG_SCREEN_RULING` 明确不建议（判为「为了丰富而丰富」） |
| 出口闪烁 / 路线箭头链（P1） | **不做**，需外部 `blink` | 见 §4.1 |
| 动画、状态机、多帧缓存 | **不做** | 静态示意图已满足信息密度要求；零寄存器是资源与可验证性的双重优势 |

---

## 5. 资源实测（TD 6.2，非外推）

### 5.1 测量方法（可复现）

`emerg_page` 是纯组合模块，**没有 clk 端口**。TD 6.2 的 `report_area` 只在设计含至少一个寄存器时才打印 `#le` 行，所以测量分三步做：

| 步骤 | 顶层 | 用途 | 产物 |
|---|---|---|---|
| ① 综合级 | `emerg_page` | 看综合后 cell 数与 LUT 分布 | `project/t2_emerg_area/reports/area.txt`、`area_plain.txt` |
| ② 全流程（place + route） | `emerg_page` 本身 | 拿到 post-route 的 `#le` / `#lut` / `#bram` / `#dsp` | `project/t2_emerg_area/reports/area_bare_full.txt` |
| ③ 对照 | `emerg_page_area_top`（仅测量用的 wrapper，非交付 RTL） | 交叉核对 le 归属（wrapper 只多一个 24 位输出寄存器） | `project/t2_emerg_area/reports/area_top_full.txt` |

- 工程文件：`project/t2_emerg_area/t2_emerg.al`（`HardWare = EG4 / EG4S20BG256`，源码表里只有 `emerg_page.v` 与测量用 wrapper `emerg_page_area_top.v` 两个文件，`TOP_MODULE` 由各 tcl 用 `elaborate -top` 指定）。
- 流程脚本：`project/t2_emerg_area/flow_t2_area.tcl` / `flow_t2_area2.tcl` / `flow_t2_area_wrap.tcl` / `flow_t2_full_top.tcl` / `flow_t2_full_bare.tcl`。
- 运行方式（**注意**：必须用 `td_commands_prompt.exe`，且 tcl 路径用**正斜杠**；`td.exe -batch -script` 在本机会弹窗挂死）：
  ```
  D:\TD_6_24_APP\bin\td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/t2_emerg_area/flow_t2_full_bare.tcl
  ```
- 工具版本：TD 6.2.168116，器件库 `eagle_s20.db`，器件 `EG4S20BG256`。
- **探针工程不是交付物**：`project/t2_emerg_area/` 只为本节测数而建，其中 `t2_emerg.al` 已被仓库 `.gitignore` 的 `*.al` 规则忽略（`.gitignore:9`），`*.log / *.qor / *.rpt` 同样忽略；`emerg_page_area_top.v` 是仅测量用的 wrapper，**不进综合顶层、不参与上板**。测量的源码副本与 `rtl/video/emerg_page.v` 逐字节一致（`Get-FileHash` 两边同为 `15BCEE51…AECFFF8`），因此本节数字对得上交付 RTL。t8 复核时可按上面同一套 tcl 重跑。

### 5.2 实测结果

**本交付口径**（与 `reports/watchdog_20261030/area.txt:221` 里 `science_page` 1052 / 672 / 380 / 44 的引用口径相同，取 `Report Hierarchy Area` 行）：

| 模块 | le | lut | ripple | seq | bram | dsp |
|---|---|---|---|---|---|---|
| **`emerg_page`** | **339** | **194** | **145** | **0** | **0** | **0** |
| 对照：`science_page`（含 292 le 的字形 ROM `science_font16`） | 1052 | 672 | 380 | 44 | 0 | 0 |
| 对照：`science_font16` | 292 | 292 | 0 | 0 | 0 | 0 |

TD 的 `Utilization Statistics` 汇总行（全设计口径，顶层就是 `emerg_page` 本身）：

```
#lut                      339   out of  19600    1.73%
#reg                        0   out of  19600    0.00%
#le                       339
  #lut only               339   out of    339  100.00%
#bram                       0   out of     64    0.00%
#bram32k                    0   out of     16    0.00%
#dsp                        0   out of     29    0.00%
#pll                        0   out of      4    0.00%
#gclk                       0   out of     16    0.00%
```

综合级 LUT 分布（`area_plain.txt`）：`#Total_luts 49`（`lut4 = 41`、`lut5 = 8`、`lut6 = 0`）。

> **口径提醒（引用时别混用）**：
> ① `#le` 是把 LUT 与寄存器打包进 LE 后的计数，所以 `le(339) > hierarchy lut(194)`，两者不是同一件事；`ripple` 是进位链级数，**不是触发器数**，不要当 `seq` 用。
> ② 按 `EMERG_SCREEN_RULING` 的口径约束，对外只引用 `le / lut / bram / dsp` 四列；`reg` 列对纯组合模块也会打印非零（本模块综合后的 `#reg` 为 0，但**不要**拿 reg 列去论证「零触发器」，该性质由 `seq = 0` 与源码无 `posedge` 共同证明）。
> ③ 探针工程 ③（wrapper 顶层）给出 `le 337`、`u_emerg_page` 单独行也是 `le 337 / lut 192 / seq 0`，与 ② 的 339/194 相差 2，来源是不同上下文下的 LUT 打包差异。**对外报 339/194（bare 顶层，无包装开销）**，337 作为交叉核对记录保留。

### 5.3 与预算的对比

| 口径 | 值 | 出处 |
|---|---|---|
| 分层裁给的 P0 预算 | +400 ~ 600 le | `EMERG_SCREEN_RULING.md` §5 |
| `ARCH_ADDENDUM_VIDEO_PATH.md` 编进顶层的预算 | +400 LUT | addendum §10 |
| **本次实测** | **le 339 / lut 194** | 本文 §5.2（TD 6.2 post-route，本机实测） |

结论：**实测低于 P0 预算下限**（339 < 400），LUT 口径 194 约为 addendum 预算（+400 lut）的 49 %。原因很直接——本模块不含任何字形 ROM（那是 `science_page` 1052 le 里最大的一块，占了 292 le），全部产出都是十几条坐标比较 + 7 层优先级覆盖，没有存储、没有乘法、没有寄存器。

对全局资源的影响：

| 资源 | 全局现状（`reports/watchdog_20261030/area.txt`） | 本模块增量 | 增量后 |
|---|---|---|---|
| lut | 15 088 / 19 600（77.0 %） | +194（hierarchy 口径）/ +339（`#lut` 汇总口径） | 仍在 19 600 硬上限内 |
| bram | 17 / 64 | **0** | 17 / 64 |
| dsp | 19 / 29 | **0**（无乘法器） | 本模块增量 0；**但全工程 t7-A 实测已到 24 / 29（余 5）**，见 `RESOURCE_BUDGET.md` §3.4「DSP 实测纠正」块 —— 「剩余 10 个」是 t7-A 之前的预算口径，已作废 |

> t8 集成时以**真实综合快照**为准复核一遍。本模块是新增模块里唯一已经拿到 post-route 实测值的（此前 `reports/plan_v2/E3_EVIDENCE.md:214-215` 记录的现象是「新增模块全部不在任何综合快照里、19 份 area.txt 全 0 命中」，本任务先把 `emerg_page` 这一项补成了实测值）。

### 5.4 时序

`emerg_page` 本体**没有时钟**，不产生任何时序路径。wrapper 顶层（③）的 `report_timing_summary` 给出 `SWNS: 0.000ns, STNS: 0.000ns / HWNS: 0.000ns, HTNS: 0.000ns`，该数字只对那个测量用 wrapper 有意义，**不代表**本模块在顶层里的时序贡献；实际影响要看 t8 把 `emerg_rgb` 接进 `video_content_mux` 后的整链 WNS。

---

## 6. 验证证据

### 6.1 定向仿真（门禁项）

```
$ powershell -NoProfile -ExecutionPolicy Bypass -File sim/scripts/run_t2_emerg.ps1
...
# SUMMARY: checks=57 errors=0 fail=0
# ALL CHECKS PASSED: emerg_page
[PASS] tb_emerg_page 全部断言通过 (exit=0)
```

- 断言总数 **57**，`errors = 0`、`fail = 0`。
- 仿真时间 307 249 ns（全帧 640×480 逐点扫描 × 1 ns settle），`$finish` 在 `sim/testbench/tb_emerg_page.v:259`。
- 全帧扫描同时写出 `emerg_page.ppm`（P6，921 615 字节 = 15 字节头 + 640×480×3），可作为视觉复核产物；把 PPM 转 PNG 后目视确认：外墙框、横走廊与北支走廊、上下错位房间分格、青色当前位置块、两处亮绿出口、琥珀色直角路线全部正确，**画面中不存在任何斜线**。
- 实测层计数：`room = 147 152`、`corridor = 13 904`、`wall = 6 488`、`divider = 2 120`、`pos = 384`、`exit = 840`、`route = 808`，逐项与 §3 的解析值一致。
- 路线包围盒实测 `(162,86)-(215,237)`，与判定式给出的 `x ∈ [162,216)`、`y ∈ [86,238)` 的闭包一致。

### 6.2 逐行轴对齐证明（无斜线的实测证据）

tb 的全帧扫描在每一行记录路线像素的最小/最大 x：

- `y < 234`（拐点以上）：只允许 `row_min ≥ 162 && row_max ≤ 165`（4 px 竖带）；
- `y ≥ 234`（拐点及以下）：只允许 `row_min ≥ 162 && row_max ≤ 215`（4 px 横带）。

任何跨带的中间像素都会让 `band_bad` 计数增加并判 FAIL。实测 `band_bad = 0`，输出 `PASS: route stays inside two perpendicular 4 px bands on every row`。这是**对「没有斜线」的直接测量**，不依赖阅读源码。

### 6.3 lint（门禁项）

```
$env:PYTHONIOENCODING="utf-8"; python scripts\lint_verilog.py rtl
检查文件数: 65
E0(文件损坏): 0    E1(赋值混用): 0    E2(多驱动): 0
结论: 通过（无损坏 / 无混用赋值 / 无多驱动）
```
exit code 0。`检查文件数` 会随团队并行新增的模块增长（t2 期间从 62 涨到 65），不构成门禁差异；门禁只要求 E0/E1/E2 全 0。

### 6.4 结构与资源禁令自检（逐条实测）

| 检查项 | 命令 | 实测 |
|---|---|---|
| 无时钟/无复位/无边沿 | `grep -c "posedge\|negedge\|clk\|rst_n" rtl/video/emerg_page.v` | **0 / 0 / 0 / 0** |
| 无字形 ROM | `grep -c "font\|glyph\|bitmap" rtl/video/emerg_page.v` | **0 / 0 / 0** |
| 唯一组合过程块 | `grep -c "always" rtl/video/emerg_page.v` | 1 处 `always @*`（第 108 行），无 `always @(posedge/negedge)` |
| 无乘法器 | `Select-String -Path rtl\video\emerg_page.v -Pattern '\*'` | 命中的 7 行全部是非运算：6 行为文件头的 `*` 列表符号（L13-L18），1 行为 L108 的 `always @*`。**正文无任何 `*` 算术运算** |
| BRAM | TD area 报告 | 0 / 64 |
| DSP | TD area 报告 | 0 / 29（全片剩余 10 个不动） |
| 端口数 | 源码 | 4（`de` / `active_x` / `active_y` / `rgb_out`） |

`output reg [23:0] rgb_out` 中的 `reg` 是 Verilog 语法要求（组合 `always` 的过程赋值目标），综合后 `seq = 0`、`#reg = 0`，不构成触发器。

---

## 7. 已知边界与遗留项

| 项 | 状态 | 说明 |
|---|---|---|
| 出口闪烁 / 路线箭头链（P1） | 未实施 | 需外部 `blink` 源；`blink` 由 t8 提供时再评估。加端口是纯增量改动（§4.1） |
| 内嵌字形 ROM（P2） | 未实施 | 文字由 `osd_caption` 字幕层承担，本模块 0 BRAM |
| 多套平面图 | 未实施 | `EMERG_SCREEN_RULING` 明确不建议 |
| `run_frontend_regression.ps1` 并入 | 留给 t9 | 本任务按文件域边界新增独立入口 `run_t2_emerg.ps1`；并入所需的 3 行已写在 §1.4 |
| `video_content_mux` 的 `2'd2` 接线 | 留给 t7 | 本模块只保证四端口契约；`2'd2` 分支目前仍是 `24'hFF_00_00` 纯红，**接线前应急画面仍是纯红屏** |
| 顶层整链时序与面积 | 留给 t8 | §5.3 的资源增量需在真实综合快照里复核；本文的 339 le 是模块级实测 |

---

## 8. 措辞基线（引用本文时请沿用）

- 画面叫「应急平面示意图」「应急疏散提示」；模式叫「应急模式」。
- 实现方式对外一律说「**FPGA 内实时栅格化**」（每个像素由自身行列坐标当场算出）。
- 实现方式只写「FPGA 内实时栅格化」，**不要**写成「由软件脚本离线生成位图再烧入」一类的说法——那会被听成「带额外处理器」，正对着合规红线。
- 本模块是「显示稳定性 / 鲁棒性」的展示点（存储链路失效时仍有可读画面），不承载任何保障性功能，也不要往「保障生命财产」的方向描述。
- 措辞依据：`reports/plan_v2/SAFETY_WORDING_RULING.md`、`reports/plan_v2/EMERG_SCREEN_RULING.md` §10。
