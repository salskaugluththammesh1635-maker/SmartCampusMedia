# 上板风险地图 —— t7-B 已签收位流（seed=7）的物理风险与排查顺序

> **本文定位**：只回答一个问题 —— *把这块板子第一次上电，最可能在哪里出问题、按什么顺序查最省时间*。
> 本文不改任何 `.v`、不碰 `project/`、不重跑综合，全部内容由**已落盘的产物文件 + 源码逐行阅读**得出。
> **口径声明**：每个数值后面括号里是来源文件名与其 mtime；引用源码行号时在括号里给出该文件的版本指纹
> （行数 / 字节 / MD5 前 12 位），因为同一文件在不同任务里行号变过，不声明版本的行号引用是不可复核的。
> 凡属推理而非实测的结论，行内显式标注「**以下是推理，不是实测**」。
>
> **一句话结论**：位流时序通过，**余量为 0.28%（113 ps / 40 ns），属零余量级**；且该余量集中在一条
> 36 级组合路径上，该路径的起点不是像素数据而是**坐标信号**，跨 `u_emerg → u_overlay/u_caption/u_strings
> → u_osd_panel → u_axis` 四个模块。上板风险的主轴是「OSD/字幕这条组合链能不能在温度与电压漂移下守住
> 113 ps」，而不是「某个模块逻辑对不对」。

---

## §1 违例路径的物理性质

### 1.1 全局时序结论（route 后，已签收位流）

| 指标 | 数值 | 来源 |
|---|---|---|
| Setup WNS | **113 ps**（0 Viol Endpoints） | `reports/t7b_bit_v3_seed7_PASS/route.qor`（2026-11-03 00:31:24） |
| Hold WNS | **11 ps**（0 Viol Endpoints） | 同上 |
| Setup TNS / Hold TNS | 0 / 0 | 同上 |
| 周期预算 | clk0 = 25.000 MHz，C-Period **40.000 ns**，R-Period **39.887 ns**（R-Freq 25.071 MHz） | `t7b_seed_seed7_timing.txt`（2026-11-03 00:31:36） |
| STA coverage | **99.84%**（Confidence: Routed，Corner: Both(Slow and Fast)，CRPR Enabled） | `t7b_seed_seed7_coverage.txt`（(不存在)） |
| 分析规模 | clk0：15,676 Total Endpoints / 49,835,382 Paths Analyzed | `t7b_seed_seed7_timing.txt`（2026-11-03 00:31:36） |

⇒ 余量占比 = 0.113 / 40.000 = **0.28%**。**时序通过，余量为 0.28%，属零余量级。**

### 1.2 最差路径的逐段构成（第 1 条，slack 0.113 ns）

来源：`t7b_seed_seed7_timing.txt`（2026-11-03 00:31:36）第一条 setup 路径，逐段统计由本报告的只读脚本解析该文件得出。

| 项目 | 实测值 |
|---|---|
| Begin Point | `u_axis/rgb[13]_syn_5126.clk` |
| End Point | `u_axis/video_data_reg[5]_syn_4.a[1]` |
| Data Path Delay | **39.535 ns**（cell **14.490 ns / 36%**，net **25.045 ns / 64%**） |
| Logic Level | **36**（LUT5 ×23、LUT4 ×5、LUT2 ×5、LUT3 ×3） |
| Max Fanout | **88** |
| Clock Skew | 0.136 ns |
| Clock Uncertainty | 0.100 ns（default uncertainty；sdc uncertainty = 0.000） |
| 段数 | 36 个 net 段 + 36 个 LUT 段 |

**净延迟分布极不均匀**：36 个 net 段里，只有 **5 段** ≥1.0 ns，合计 **7.734 ns = net 总量的 31%**：

| 延时 | fanout | net 名 |
|---|---|---|
| **2.000 ns** | 66 | `u_axis/rgb[6]_syn_60` |
| 1.719 ns | 4 | `u_axis/rgb[6]_syn_184` |
| 1.474 ns | 7 | `u_axis/rgb[13]_syn_108` |
| 1.367 ns | 9 | `u_axis/rgb[13]_syn_106` |
| 1.174 ns | 7 | `u_axis/rgb[13]_syn_404` |

最高扇出的三段分别是 `u_overlay/u_caption/rep_data[0]_dup_9`（**fo=88**，0.559 ns）、
`u_emerg/active_x[5]_dup_12`（fo=74，0.528 ns）、`u_axis/rgb[13]_syn_dup_3442`（fo=74，0.741 ns）。

#### 1.2.1 `cell 36% / net 64%` 说明什么：主因是**布线/布局**，不是逻辑深度

结论：**余量不足的主因是布线（net）而非逻辑级数（cell）**。判据有三条，逐条可核：

**判据一（比例本身）**：net 占 64%（25.045 ns / 39.535 ns）。若是逻辑深度主导，比例应反过来
（cell 占多数）。同一条路径上 36 个 LUT 段平均只有 **14.344 / 36 ≈ 0.40 ns** 每段 ——
**每级 LUT 都很快，慢的是级与级之间的走线**。

**判据二（对比同设计的第二条路径，这是最硬的判据）**：Top-10 第 7 条
（`u_player/u_scaler/div_den_reg[3]` → `u_player/u_scaler/c2_rem[13]`，slack 0.386 ns）
**逻辑级数是 37，比最差路径还多 1 级**，但它不是最差 —— 因为它的 net 延迟是 **23.511 ns**，
比最差路径的 25.045 ns 少 1.534 ns。
⇒ **逻辑级数多 1 级的路径反而更好，说明级数不是决定因素，net 才是。**

**判据三（工艺能力上限）**：若把 25.045 ns 折算成「36 段走线平均」，每段 **0.696 ns**。
在 EG4S20（25 MHz、8,591 slices / 87.66% 高占用）上，这个单段延迟**已经接近跨片区走线的量级**。
**以下是推理，不是实测**：一次跨半个芯片的 net 在不同 corner 下的波动幅度大于 113 ps，
所以「把逻辑级数从 36 降到 18」预期只能改善 cell 部分（14.490 ns 的一半 ≈ 7 ns），
而 net 部分（64%）不会等比例下降，甚至会因为布局改变而上升。

**这条判据的实践含义**：不要把 0.28% 归因于「OSD 逻辑写得太深」。逻辑深度是诱因（它让路径变长、
把布局拉散），但**直接吃余量的是布线**。这也解释了为什么路线 C（插流水线）的风险最高、
收益最不确定（见 §4）。

#### 1.2.2 `Hold WNS +0.011 ns` 与 `Setup WNS +0.113 ns` 哪个更危险

结论：**Hold 更危险，而且危险的不是 11 ps 这个数，是「hold 只能用插 buffer 修」这个机制。**

理由分三层：

1. **Setup 违例可以靠降频掩盖，hold 不能。** Setup 的余量与周期直接相关：把 clk0 从 25 MHz 降到
   24 MHz，周期从 40 ns 变 41.667 ns，最差路径的 slack 从 +0.113 ns 变成 +1.780 ns —— 立刻安全。
   但 **hold 违例与时钟周期无关**（它检查的是同一时钟沿前后两个寄存器的竞争），降频一点帮助都没有。
   这块板子的 HDMI 输出必须恒 25 MHz（`video_timing_gen` 的 640×480@59.52 由 PLL 固定），
   连「降频」这个万能兜底都不存在。

2. **`fix_hold` 插的 buffer 只增不减地恶化 setup。** 这点在本次交付里可以直接看到因果：
   `place.qor`（2026-11-03 00:30:33）报 `Hold WNS −11 ps / TNS −154 / violated H-EP 14`；
   `route.qor`（2026-11-03 00:31:24）报 `Hold WNS +11 ps / violated H-EP 0`。
   ⇒ hold 被修好了，代价是插了 6 条 hold buffer（`run_seed7.log` 2026-11-03 00:31:47 第 1118-1129 行）。
   本次这 6 条 buffer 落在 `u_player/u_loader/fifo_wr_data[*]`、`u_wav/s_lo[*]`、
   `u_hdmi_island_data_gen/.../u_w96_d1024_fifo` —— **都不在最差路径上**，
   所以 setup 没有被进一步恶化（修复前后 setup 都是 0.113 ns）。

3. **但下一次不一定这么幸运。** 本次 hold 违例的 14 个端点离最差 setup 路径很远；
   若某次改动让 hold 违例落在 §2.1 那条 36 级链的端点附近，`fix_hold` 插的 buffer 会直接推高
   那条链的 net 延迟 —— 而它只剩 113 ps。这正是官方 `MultiSeed.tcl` 要提供 `drHoldFix` 模式的原因
   （见 §4 路线 B）：**先把 `fix_hold` 关掉跑 route，看 setup 能到什么水平，再单独补 hold**，
   这样至少能区分「setup 余量被逻辑吃掉」和「setup 余量被 hold 修复吃掉」。

⇒ **判读口径**：0.113 ns 是「还没被 hold 修复侵蚀」的数；0.011 ns 是「已经修复完、剩 11 ps 余量」的数。
两个都不是 0，但 **hold 的 11 ps 只有 setup 的 1/10，且它一旦复发就没有降频兜底**。

#### 1.2.3 `wire length 1,664,088` 与 `#slices 8,591 / 87.66%` 意味着什么

| 指标 | place 阶段 | route 阶段 | 变化 |
|---|---|---|---|
| Wire length | **719,610** | **1,664,088** | **× 2.31** |
| #slices | 8,591 / 87.66% | 8,591 / 87.66% | 不变 |
| Setup WNS | +1707 ps（未布线估计） | **+113 ps** | 塌掉 94% |

来源：`place.qor`（2026-11-03 00:30:33）/ `route.qor`（2026-11-03 00:31:24）。

**判读**：布线总长度在 route 阶段涨了 2.31 倍，而 slice 占用率一点没变（8,591 / 87.66%）——
说明 **route 是在一个已经很满的布局里做绕线**，不是「布局宽松、绕线轻松」。
87.66% 的 slice 占用率意味着只剩 **12.34%** 的空片（约 1,200 slices 量级）可用作连线通道。

**以下是推理，不是实测**：这个占用量级下，加一级流水线不会「凭空」多出逻辑资源 ——
新增的寄存器（24 位 `video_data` 若插一级就是 24 个 FF）需要占用 slice 里的 FF，
而 87.66% 的 slice 里已经塞了 8,441 个 reg（`#reg 8,441 / 43.07%`）。
**FF 余量是够的**（43%），但**布线通道余量很紧**（12.34% 空片），
新插的寄存器会迫使重布局，而重布局正是把 +1707 ps 变成 −3,296 ps 的那个动作。

**若上板实测不稳，加一级流水线的代价（三条）**：

1. **LUT 代价小、时序代价不可预测**：寄存器本身几乎不占 LUT（它就是 FF），
   但要拆的是「一条 36 级链」，拆点选在哪里、拆完后两端布局怎么变，都要重跑才知道。
2. **必须同步延迟的伴随信号**：`de`、`active_x[10:0]`、`active_y[9:0]`、`video_valid`、
   `video_last`、`video_user` 全部要跟着打一拍（这是 `video_rgb_to_axis.v` 81 行 / 3776 B / MD5 BF7C793BF99F 的端口清单），
   否则像素与坐标错拍 —— 那会从「时序问题」变成「显示错位问题」，比现在更糟。
3. **重跑风险**：整套 `optimize_rtl → optimize_gate → place → route → bitgen` 全流程，
   且**不能保证一次过** —— 本次交付为了拿到 +113 ps 已经用了 seed=7（前面 seed 1~6 无记录，见 §5）。

### 1.3 这条路径**不是像素数据路径**，是「坐标 → 字符码 → 像素」的组合链

按 net 段归属的模块分布（同一条路径上）：

| 归属 | 段数 |
|---|---|
| `u_axis/rgb*` | **28** |
| `u_overlay/u_caption/u_strings/line_sel` | 3 |
| `u_emerg/active_x` | 1 |
| `u_overlay/u_caption/u_strings/col` | 1 |
| `u_overlay/u_caption/u_strings/sel0_syn_2042` | 1 |
| `u_overlay/u_caption/rep_data` | 1 |
| `u_osd_panel/rgb_out_b1` | 1 |

**关键证据**：起点寄存器名叫 `u_axis/rgb[13]_syn_5126`，但它的 clk2q 输出 net 名是
`u_emerg/active_x[5]_dup_12`，源行标注 `hdmi/emerg_page.v(27)` ——
而 `rtl/video/emerg_page.v`（123 行 / 6427 B / MD5 3D47E4C5DE72）第 27 行正是 `input wire [10:0] active_x,`。

⇒ 这个寄存器**在功能上是 `emerg_page` 的 `active_x[5]` 的一个副本**，被工具放到了 `u_axis` 的边界内并
沿用了 `u_axis/rgb[13]` 的命名前缀。**以下是推理，不是实测**：TD 在 `optimize_gate` 阶段做了跨层次
边界重构，把 `emerg_page → osd_strings → osd_caption → osd_panel → u_axis` 这一整条组合锥吸收进了
`u_axis` 边界，因此路径上 28/36 段都带 `u_axis/` 前缀，而其中绝大多数逻辑的**源头在 OSD 层**。

这条推理有独立的旁证（实测）：把 `video_rgb_to_axis` 单独当顶层综合，代价只有 **20 lut / 3 ripple / 40 seq**
（`project/t21_axis_probe/reports/area_mod.txt`，2026-11-02 19:40:10），
而主工程层级表里 `u_axis` 是 **2,384 lut / 0 ripple / 157 seq**
（`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36）—— **差 100 倍以上**。
`rtl/video/hdmi/video_rgb_to_axis.v`（81 行 / 3776 B / MD5 BF7C793BF99F）全文只有 3 个 1 位寄存器 + 11 位计数器 +
一个 `x_cnt == H_ACTIVE-1` 比较器 + 24 位数据寄存器，源码层面**不可能**产生 2,384 个 LUT。

`gate.qor` 的 Rent 表也从侧面印证：`u_axis` Rent **0.67**（全场最高，阈值 0.7 才报）、
Cell **2,274**、Pin **10,973**、Term **859**（`gate.qor`，2026-11-03 00:13:52）——
一个 8 端口模块不可能有 859 个边界端点。

### 1.4 为什么组合深度会到 36 级

链路里每一级都是**纯组合**（逐文件实测，版本指纹见括号）：

| 模块 | 行数 | `always @` 块数 | `reg` 声明数 | `assign` 数 |
|---|---|---|---|---|
| `rtl/osd/osd_strings.v`（464 行 / 29751 B / MD5 876194DE97AB） | 465 | 1（`always @(*)`） | 1 | 0 |
| `rtl/osd/osd_panel.v`（247 行 / 14594 B / MD5 6E653F547C02） | 248 | **0** | **0** | 1 |
| `rtl/osd/osd_caption.v`（586 行 / 34543 B / MD5 DFD82C9EF027） | 587 | 6 | 17 | 2 |
| `rtl/video/emerg_page.v`（123 行 / 6427 B / MD5 3D47E4C5DE72） | 124 | 1（`always @*`） | 1 | 0 |
| `rtl/video/video_overlay.v`（320 行 / 19901 B / MD5 037711D55D4A） | 321 | 2 | 2 | 1 |
| `rtl/video/hdmi/video_rgb_to_axis.v`（81 行 / 3776 B / MD5 BF7C793BF99F） | 82 | 1 | 7 | 0 |

- `osd_panel.v` 有 **0 个 always、0 个 reg**，全靠 `assign` —— 它本身是一整片组合逻辑。
- `osd_strings.v` 是一个 465 行的 `case ({line_sel, col})` 大查表（`always @(*)`，输出 9 位 `char_code`）。
- `emerg_page.v` 的 `always @*`（第 108 行起）是一条 7 级 `if` 优先级级联（`room → corridor → divider →
  wall → route → pos_block → exit_mark`），每级都是坐标比较。
- 这些模块之间**没有任何寄存器**隔开，直到 `u_axis` 的 `video_data` 寄存器（第 57 行 `video_data <= rgb;`）。

⇒ 一条从 `active_x` 出发、穿过「字符码查表 → 字模 → 像素选择 → 内容复用 → 输出寄存器」的组合链，
在 25 MHz（40 ns）下要吃掉 39.535 ns。**以下是推理，不是实测**：其中 25.045 ns 是布线（占 64%），
说明这条链的**物理跨度**（跨四个模块、8,591 slices / 87.66% 的高占用率）和**逻辑深度**共同决定了它，
单纯减少逻辑级数（比如查表改 ROM）未必能等比例改善，因为 net 延迟占比更高。

---

## §2 敏感位置排序

按「一旦翻车，用户最先看到什么」排序，不按模块重要性。

### 2.1 第一敏感位：OSD/字幕这条 36 级组合链（即 §1 那条路径）

- 物理位置：`u_emerg` / `u_overlay/u_caption/u_strings` / `u_osd_panel` → 全部被吸收进 `u_axis` 边界。
- 余量：**113 ps**，占周期 0.28%。
- 受影响的用户可见现象（**以下是推理，不是实测**）：坐标类信号晚到 → 字符码/字模取错 → 画面局部字符
  错位、字幕串行、应急平面图的房间/走廊边界错一列。**不会黑屏、不会报错、tb 也抓不到**（tb 在理想时序下跑）。
- 为什么它是第一位：全工程 Top-10 setup 路径里 **9 条**起点是同一个寄存器
  `u_axis/rgb[13]_syn_5126`（第 7 条例外是 `u_player/u_scaler/div_den_reg[3]`，slack 0.386 ns），
  slack 分布在 0.113 ~ 0.468 ns。**以下是推理，不是实测**：这是「一个起点寄存器扇出到 24 位
  `video_data` 每一位」的结构 —— 一条路径失败会同时影响多个颜色位，表现为错色而非单点。

### 2.2 第二敏感位：`u_player`（全场最大单块，且它底下挂着三个「新硬件」）

**先纠正一个数字口径问题（本项目的已知陷阱）**：本卡任务描述里引用的
「`u_player` 7,124 le / 6,936 lut，全场最大单块，占 42%」这组数字，来自
`reports/t7b3_rl45_place_hfn_opt_effort_high_area.txt`（mtime **2026-11-02 22:23:01**）——
那是 rl45 + place hfn opt effort high 的一次**中间实验**，当时 `u_pix_fifo` 还是 LUTRAM 实现
（该报告 `u_reader` = 2,202 lut / 0 bram）。**它已被最终交付报告覆盖**：

| 来源 | mtime | u_player le / lut / ripple / seq / bram / dsp | u_reader |
|---|---|---|---|
| `t7b3_rl45_place_hfn_opt_effort_high_area.txt` | 2026-11-02 22:23:01 | 7,124 / 6,936 / 63 / 2,836 / **3** / 12 | 2,202 lut / 0 bram |
| `t7b3_rl60_area.txt`（2026-11-02 20:45:30） | 2026-11-02 20:45:30 | 7,112 / 6,959 / 36 / 2,858 / 3 / 12 | 2,185 lut / 0 bram |
| **`t7b_seed_seed7_area.txt`（2026-11-03 00:31:36，最终交付）** | **2026-11-03 00:31:36** | **4,836 / 4,607 / 63 / 2,836 / 5 / 12** | **238 lut / 2 bram** |

⇒ **交付位流里 `u_player` 是 4,836 le / 4,607 lut**，占顶层 16,795 le 的 **28.8%**
（`4,836 / 16,795`）—— 仍是全场最大单块，但不是 7,124。
两者差 1,376 lut / 2,288 le，**差额的来源就是 t25 把 `u_pix_fifo` 从 LUTRAM 改成 BRAM**
（`u_reader` 2,202 → 238 lut，省 1,964 lut；同时 `bram` 从 3 涨到 5）。
这个数字变化本身是好事，但它说明 **本卡之前引用的 42% 是过期报告的数**。

**为什么 `u_player` 是第二敏感**：它是全场最大单块，且底下的子模块**每一个都在最近三周被改过**：

| 子模块 | le / lut / ripple / seq / bram / dsp | 最近改动 |
|---|---|---|
| `u_loader` | 1,646 / 1,540 / 63 / 1,022 / 0 / 6（内含 `u_fat` 958 / 888 / 45 / 655） | t26 改了 `u_fat` 的 `found`/`fail` 输出端口类型（`output reg` → `output wire`） |
| `u_scaler` | 1,347 / 1,347 / 0 / 361 / 0 / 4 | 未改，但是 21 位除法器（见 §2.4） |
| `u_bmp` | 414 / 397 / 0 / 303 | — |
| `u_sdram` | 498 / 471 / 0 / 460 | — |
| **`u_reader`** | **238 / 217 / 0 / 186 / 2 bram**（内含 `u_pix_fifo` 48 / 48 / 0 / 43 / 2 bram） | t25 改 FWFT + BRAM（见 §2.6） |
| **`u_fade`** | **33 / 33 / 0 / 1 / 0 / 1 dsp** | t7-B 第一次真进综合（见 §2.5） |
| `u_arb` | 164 / 151 / 0 / 129 | — |
| `u_write_fifo` | 83 / 83 / 0 / 73 / 3 bram | — |

**上板判读**：图片通路出问题时，**不要一上来就怀疑 `u_player` 整体**，
按 §3 步骤 10 的证伪实验先区分「应急平面图对不对」（`emerg_page` 不经过 `u_player`）——
若应急图正常而图片异常，才进 `u_player`，再按「缩放档位 → Key8 是否非满档」二分到 `u_scaler`。

### 2.3 第三敏感位：`u_wav`（最大的音频块，含**第 3 份** `fat32_reader`）

- 资源：`u_wav` **2,308 le / 2,125 lut / 119 ripple / 1,259 seq / 2 bram / 6 dsp**
  （`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36），占顶层 **13.7%**（2,308 / 16,795 le），是第三大块。
- 它内部有自己的一份 `u_fat`：**1,079 le / 956 lut / 85 ripple / 641 seq**。
- **为什么敏感**：全工程有 **三份** `fat32_reader` 实例（`u_wav/u_fat`、`u_gallery/u_fat` 1,055 le、
  `u_player/u_loader/u_fat` 958 le），**只有 `u_wav` 这份接的是整板复位**
  （`wav_stream_player.v` 的 `.rst_n(rst_n)`）。
  ⇒ 另外两份靠「自杀式复位」每轮重启，这份不能 —— 所以 t26 的终态自锁在这里是**唯一会暴露**的。
- **这是 t26 修复的第一次上板**。修复前的用户可见症状**不是报错**，而是
  **静默重播上一个文件**（`err_code` 全程 0）：`fat32_reader` 进 `S_DONE/S_FAIL` 后不再理会 `start`，
  `wav_stream_player` 读到的是上一轮陈旧的 `wav_cluster` / `wav_size`。
  t26 改成「`found`/`fail` 组合电平屏蔽」后，`tb_fat32_reader` 62/0、`tb_wav_stream_player` 46/0。
- **注意 ripple 119**：它和 `u_gallery/u_fat`（85）、`u_player/u_loader`（63）是全场 ripple 最大的三处之一，
  说明这三处有大量 16/32 位加减法进位链（`#lut` 口径里进位链被双计，见 §1.1 的 `#lut` 83.74%）。

### 2.4 第四敏感位：`u_player/u_scaler` 的 21 位除法器

- 路径：`u_player/u_scaler/div_den_reg[3]_syn_4.clk` → `u_player/u_scaler/c2_rem[13]_syn_581.a[0]`，
  slack **0.386 ns**、Logic Level **37**、Max Fanout **58**
  （`t7b_seed_seed7_timing.txt`，2026-11-03 00:31:36）。
- 用户可见现象：图片缩放（Key8 五档 + 非 640×480 源图）出现一列/一行错位。
- 它是 Top-10 里**唯一不经过 u_axis** 的路径，且逻辑级数比最差路径还多 1 级（37 vs 36），
  只是 net 延迟小（23.511 ns vs 25.045 ns）才没成为最差。

### 2.5 第五敏感位：`u_fade`（fade_mixer）—— 已接线但**从未上过板**

- 源码：`rtl/storage/fade_mixer.v`（30 行 / 1781 B / MD5 634FC30A8BD6）30 行，纯组合，3 个 5/6 位乘法器。
- 资源：`u_fade` **33 lut / 0 ripple / 1 seq / 0 bram / 1 dsp**（`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36）。
- 例化：`rtl/storage/image_player.v`（628 行 / 34666 B / MD5 4E8B620FF7BA）第 617 行
  `fade_mixer u_fade (.rgb_in(reader565), .level(fade_level), .rgb_out(rgb565));`
- **关键事实（源码实测，直接影响上板怎么验）**：`fade_level` 由 `ext_no_fade` 决定
  （`image_player.v` 第 572 行 `wire [7:0] fade_level = ext_no_fade ? 8'hFF : fade_alpha;`），
  而顶层 `rtl/top/dmz_eg4s20_hdmi_top.v`（1256 行 / 85825 B / MD5 4D1685E6FAEE）第 668 行把它接成 `.ext_no_fade(rle_play_en)`。
  ⇒ **科普模式（`rle_play_en=1`）下 `fade_level` 恒 `8'hFF`，淡入淡出被整段旁路（硬切）；
  只有日常模式（`rle_play_en=0`）才真正走 `fade_alpha` 渐变。**
  这条不是 bug（是 t7-B 刻意的「视频模式不淡入淡出」），但它意味着：
  **验 `u_fade` 必须切到日常模式按 Key0/Key1**，在科普模式按是验不到的（那里是硬切，无论 `u_fade` 好坏都一样）。
- 覆盖缺口：`tb_video_overlay` 106 条断言**不覆盖 `fade_mixer` 本身**（它例化在 `image_player` 内部）；
  现有 tb 只覆盖 `image_player` 的换帧时序。

### 2.6 第六敏感位：`u_pix_fifo`（t25 改 FWFT + BRAM）—— 上一版位流没有的新硬件

- 资源：`u_reader` **238 lut / 0 ripple / 186 seq / 2 bram**，其中 `u_pix_fifo` **48 lut / 43 seq / 2 bram**
  （`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36）。
- 与上一版的差别：**t25 之前 `u_pix_fifo` 是 LUTRAM 实现** —— `reports/t7b3_rl60_area.txt`
  （2026-11-02 20:45:30）里 `u_pix_fifo` 是 **1,650 lut / 0 bram**、`u_reader` 2,185 lut。
- 为什么敏感：BRAM 的读延迟（同步读，1 拍）与 LUTRAM（异步读，0 拍）**行为不同**。
  `tb_pix_reader` 194 条断言验的是**逻辑正确性**（在 tb 里 BRAM 由行为模型给出正确数据），
  **不验 BRAM 上板时序**。上板若出现「画面右侧一条竖带错位/黑边」，先怀疑这里。

### 2.7 第七敏感位：`narr_subline`（1 块 BRAM，科普字幕段表）

- 资源：`u_overlay/u_caption` **203 lut / 27 seq / 16 bram**，其中 `u_narr` **121 lut / 13 seq / 1 bram**
  （`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36）。
- 它是 `#bram` 从 34 涨到 37 的三处之一（另两处是 `cjk16` 与 `pix_fifo`）。
- 为什么敏感：`narr_en` 在 t7-A 是常量 0（整块被常量传播剪掉），t7-B 才接真值 —— **这是它第一次进综合**。
  顶层（`dmz_eg4s20_hdmi_top.v` 1256 行 / 85825 B / MD5 4D1685E6FAEE）第 1008 行
  `wire narr_frame_ok = (rle_frame_idx >= 16'd4) && (rle_frame_idx <= 16'd624);`。
- 上板现象（**以下是推理，不是实测**）：科普模式字幕不出现 / 出现但停在第 1 段不推进。

### 2.8 不在敏感列表里的两个模块（避免上板时误查）

- **`u_axis` 本身**：它 2,384 lut 是**跨边界吸收的容器**，不是逻辑源头。上板若怀疑「u_axis 有问题」，
  实际要查的是 §2.1 的 OSD 组合链。改 `video_rgb_to_axis.v` 源码不会省任何 LUT
  （独立综合只有 20~23 lut，见 §1.3 旁证）。
- **I2C**：见 §3 步骤 4，它在 SDC 里是 `set_false_path`，时序工具根本不检查它，
  「WNS 通过」不构成 I2C 可靠的任何证据。

---

## §3 上板排查顺序（按「第一个 10 分钟内会看到什么」组织）

每步给：**现象 / 判定 / 最省事的证伪实验**。顺序设计的核心原则是
**先用 5 秒可见的现象，一次性排除掉一整类问题**，不要一上来就查 u_axis。

### 步骤 0（上电前，桌面）：确认 D1/E1 排针上没有插 SPI 串口屏

- **现象**：如果插着，I2C 两根线被外部器件拉低/干扰。
- **判定**：`project/hdmi/dmz_eg4s20_hdmi.adc`（2026-11-01 21:51:06）第 130-131 行
  `set_pin_assignment { i2c_scl } { LOCATION = D1; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }`，
  `i2c_sda` 同（E1）。该文件的引脚复用声明（第 107-128 行）写明 D1/E1 原为 SPI 串口屏的 SCL/SDA，
  本工程不例化 SPI 屏驱动，因此可安全复用。
- **证伪实验**：拔掉排针上的 SPI 屏模组再上电。**这是唯一必须在插电前做的检查。**

### 步骤 1（0~5 秒）：HDMI 有没有画面

- **现象**：显示器识别到 640×480@60 并显示内容（图库图 / 彩条 / 应急平面图）。
- **判定**：有画面 ⇒ 时钟树（`u_pll` 2 个 PLL、4 个 GCLK）、HDMI PHY、`u_hdmi_core` 全部通路正常。
  这一条同时排除了「PLL 没锁」「位流没烧进去」「PHY 引脚错」三类问题。
- **证伪实验**：若黑屏，先量 `clk`（球 R7）有无 50 MHz；再量 TMDS 四对差分有无输出。
  不要先查 RTL。

### 步骤 2（5~15 秒）：日常模式下按 Key0/Key1 换图，看有没有**渐变**

- **现象**：画面从旧图淡出到黑、再淡入新图（约 8 帧 = 0.13 s）。
- **判定**：**必须确认当前是日常模式**（`rle_play_en=0`）。见 §2.5：
  科普模式下 `ext_no_fade=1`，`fade_level` 恒 `8'hFF`，是硬切 —— 在那里看到「没有渐变」是**预期行为**，
  不是 `u_fade` 坏了。
- **为什么第二步就做**：这是 `u_fade` 的**唯一验证窗口**，而它是 t7-B 才第一次进综合的模块
  （33 lut / 1 dsp）。通过即同时证明「顶层 `ext_no_fade` 接线正确」+「`u_fade` 乘法器正常」两件事。
- **证伪实验**：若日常模式下也是硬切，先查顶层第 668 行 `.ext_no_fade(rle_play_en)` 是否接反；
  再查 `image_player.v` 第 572 行 `fade_level` 三目。
  **不要**去改 `fade_mixer.v` 的 `gain = level + 1`（那是为了 level=255 时精确还原原值，改了就出偏色）。

### 步骤 3（15~40 秒）：切科普模式，看视频字幕

- **现象**：科普模式播放 SCI.RLE 视频，底部/中部出现中文字幕，随帧号推进。
- **判定**：字幕出现且推进 ⇒ `narr_subline`（1 块 BRAM）+ `narr_frame_ok` 门控 + `osd_caption` 全部正常。
- **证伪实验**：若字幕不出现，先确认 `rle_frame_idx` 是否已进入 4~624
  （顶层第 1008 行 `narr_frame_ok`）。若 frame_idx 一直是 0，问题在 `u_rle` 的帧提交，不在字幕。
- **注意**：这一步同时验证了「`#bram` 37 里那 1 块 narr BRAM 是真的活的」——
  它是 t7-B 的产物断言（`t7b_bit3.tcl` 第 250 行 `if {$bram_used < 35}` 就是防这个）。

### 步骤 4（40~60 秒）：看温度读数（AHT20）

- **现象**：屏幕上出现温度值，且 10 秒内变化幅度合理（室温下 ±0.5 ℃ 内）。
- **判定**：`u_aht20` **373 lut / 14 ripple / 159 seq** + `u_i2c` **78 lut / 55 seq**
  （`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36）工作正常；IO 上 `i2c_scl`(D1) / `i2c_sda`(E1) 均带
  `DRIVESTRENGTH = 8 / PULLTYPE = PULLUP`（`dmz_eg4s20_hdmi.adc`，2026-11-01 21:51:06）。
- **判定纪律**：`project/hdmi/dmz_eg4s20_hdmi.sdc`（2026-11-01 21:52:29）第 118-121 行有
  `set_false_path -from [get_ports {i2c_scl}]` / `-to` / `-from {i2c_sda}` / `-to`。
  ⇒ **I2C 通路被时序工具排除在外，「SWNS 0.113 ns 通过」对 I2C 的物理可靠性零证据。**
  读数偶发错（比如每几次错一个字节）时，**不要查 WNS**，去查：上拉电阻是否焊了、飞线是否过长、
  是否有 100 kHz 以上的干扰源。
- **证伪实验**：把 `i2c_scl` 用示波器抓一下，看 9 个 SCL 脉冲是否完整、ACK 位是否被拉低。

### 步骤 5（1~2 分钟）：Key8 分辨率五档

- **现象**：按 Key8 循环 320×240 → 400×300 → 512×384 → 576×432 → 640×480，画面横向分辨率随之变化
  （低档位画面变「块状」，因为是列抽样）。
- **判定**：`u_mosaic`（pix_mosaic）**34 lut / 20 seq**（`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36）。
  五档都能切、且 640 档与切换前完全一致（恒等旁路）。
- **证伪实验**：若某档画面**整体左移 1 像素**，那是 pix_mosaic 的经典缺陷（组合旁路写成了时序），
  但在 t1 已用 149 条断言 + 变异反证（fail=80）钉死，**上板不应复现**。若真出现，直接回 t1 的 tb。

### 步骤 6（2~3 分钟）：Key9 屏占比五档

- **现象**：窗口从满屏缩到 1/2、5/8、3/4、7/8。
- **判定**：`u_image_mask` + `ratio_map` + `u_reader` 的水平降采样。**注意纵向是裁剪不是等比缩小** ——
  窗口变小时看到的是原图的**中间部分**，不是整幅缩小。这是 2026-11-03 定案的终口径
  （见 `docs/plan_v2/KEY9_RULING.md`）。
- **证伪实验**：若窗口位置与内容错位（比如窗口在中间但显示的是左上角），说明 `win_*` 那组信号
  没有同时喂给 `u_image_mask` 与 `u_reader` 两个消费者（这是 `T1_TO_T7_WIRING.md` §1.2 点名的静默错误）。

### 步骤 7（3~5 分钟）：音频（BGM / NARR 换源）

- **现象**：日常模式放 BGM，切科普模式应换成 NARR 旁白（**不是继续放 BGM**）。
- **判定**：`u_wav` **2,308 lut / 119 ripple / 1,259 seq / 2 bram / 6 dsp**
  （`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36），内含 2 份 `u_fat`（`u_wav` 下 1,079 lut、`u_gallery` 下 1,055 lut）。
- **这是 t26 修复的第一次上板**：修复前 `fat32_reader` 在 `S_DONE/S_FAIL` 终态自锁，
  第二次换源会**静默重播上一个文件**（`err_code` 全程 0）。t26 改成组合电平屏蔽后
  `tb_fat32_reader` 62/0、`tb_wav_stream_player` 46/0。
- **证伪实验**：若切模式后音乐没变，立刻怀疑换源没生效 —— 这**正是**修复前的症状。
  若报错音/静音，查 `err_code`（`E_BLKTMO=8` / `E_NOTFOUND=6`）。

### 步骤 8（5~8 分钟）：SD 卡图库

- **现象**：Key0/Key1 能遍历卡上所有 BMP；拔插卡后能重扫（Key11，P2 键）。
- **判定**：`u_gallery` **1,229 lut / 54 ripple / 734 seq**、`u_player/u_loader` 1,646 lut、`u_bmp` 414 lut
  （`t7b_seed_seed7_area.txt`，2026-11-03 00:31:36）。
- **证伪实验**：若图库只认出部分图，先看卡是不是 FAT32（`fat32_reader` 只支持 FAT32）。

### 步骤 9（10 分钟以上）：连续运行稳定性

- **现象**：连续跑 30 分钟以上，画面/字幕/温度无偶发错误。
- **判定**：这是**唯一能暴露 113 ps 零余量问题**的测试。板子温度上升 → 延迟变大 → 若某条路径正好在
  边界上，会出现「跑 5 分钟没事、跑 20 分钟字幕错一个字」的现象。
- **证伪实验**：若怀疑是时序而非逻辑，把室温升高（或用热风筒轻吹 FPGA）复现；
  若升温后错误率明显上升 ⇒ 时序余量问题，与 RTL 逻辑无关，去 §4 选路线。
  **若升温后现象完全不变，那是逻辑 bug，不要浪费时间在时序上。**

### 步骤 10（仅在出现「错色/局部错位」时）：定位到 §2.1

- **现象**：画面某几条竖带颜色不对、或 OSD 字符局部错位，且**不随模式变化**。
- **判定**：`u_axis` 那条 36 级路径（§1）。因为 24 位 `video_data` 的每一位都由同一批起点驱动
  （Top-10 里 9 条同起点），错色会成组出现。
- **证伪实验**：切到应急模式（Key3）。应急平面图是纯几何绘制（`emerg_page.v` 7 级 if 级联），
  如果**应急模式也错**，说明是 §2.1 的坐标链；如果**只有图片/字幕错、应急平面图完全正确**，
  问题在 `u_player`（§2.2）或 `u_reader`/`u_pix_fifo`（§2.6）。

---

## §4 三条备选路线

三条都**需要重跑综合/布局/布线/bitgen，因此都会替换已签收位流**
（当前位流 `hdmi_td_v3_seed7.bit`，648,264 B，2026-11-03 00:31:47）。

### 路线 A：继续抬 `min_ripple_len`

**代价**：一次 `optimize_rtl + optimize_gate + place + route + bitgen` 全流程。
实测阶段耗时（`run_seed7.log`，2026-11-03 00:31:47，seed=7 那一趟的真实 wall time）：
`place` **103.68 s**（日志第 801 行）、`route` **250.36 s**（第 1260 行）、`bitgen` **7.90 s**（第 1371 行）
—— 三段合计约 6 分钟；再加上 `elaborate + optimize_rtl + optimize_gate` 与重跑 `report_*`，
**单趟全流程按 10~15 分钟估**（以下是推理，不是实测：synthesize 段的 wall time 未从日志单独提取）。

**实测数据（`reports/` 下，均为 gate 阶段面积）**：

| min_ripple_len | Util #lut | 占比 | 层级表 top lut / ripple / seq | 来源（mtime） |
|---|---|---|---|---|
| 8 | **19,039** | 97.14% | 16,204 / 2,835 / 8,331 | `t7b_syn2_rtl_min_ripple_len_8_area.txt`（2026-11-02 19:51:04） |
| 18 | **18,062** | 92.15% | 16,246 / 1,816 / 8,331 | `..._18_area.txt`（2026-11-02 19:45:52） |
| 30 | **17,744** | 90.53% | 16,813 / 931 / 8,331 | `..._30_area.txt`（2026-11-02 19:51:36） |
| 45 | **17,645** | 90.03% | 17,331 / 314 / 8,331 | `..._45_area.txt`（2026-11-02 19:52:00） |
| 60 | **18,563** | 94.71% | 18,398 / **165** / 8,498 | `t7b3_rl60_area.txt`（2026-11-02 20:45:30） |
| 45（最终，+seed7） | **16,414** | 83.74% | 16,100 / 314 / 8,467 | `t7b_seed_seed7_area.txt`（2026-11-03 00:31:36） |

**关键反证一：低档直接撞硬件门槛（`PHY-9009`，mslices 上限 4,900）**

`#lut`（面积）不是唯一的门槛，`place` 阶段还有一个更硬的限制：**mslice 数不得超过 4,900**，
超了直接 `PHY-9009 ERROR` 终止流程。逐档实测（日志取自 `%TEMP%`，文件名 + 行号见下）：

| min_ripple_len | mslices（place `RUN-1001`） | 判定 | 日志 |
|---|---|---|---|
| 8 | **5,151** | **PHY-9009 超限，流程中止** | `t7b_ripple_B_rl8.log:1210`（错误在 `:1218`） |
| 18 | **4,956** | **PHY-9009 超限，流程中止** | `t7b_syn2_rtl_min_ripple_len_18.log:1208`（错误在 `:1216`） |
| 30 | **4,849** | 通过（余 51） | `t7b_ripple_D_rl30.log` |
| 45 | **4,801** | 通过（余 99） | `t7b_ripple_E_rl45.log:1211` |
| 45 + seed 7（**最终交付**） | **4,278（place）/ 4,306（route）** | 通过（余 622 / 594） | `run_seed7.log`（2026-11-03 00:31:47）第 456 行 / 第 834 行 |

`PHY-9009` 原文（`t7b_ripple_B_rl8.log:1218`）：
```
PHY-9009 ERROR: Design's mslice number = 5151, exceeds the limit 4900. There are more MSlices
exceeding the limit of the device. You can try using 'report_area' in console to check the
resource utilization of the device and results of Optimize Gate stage. And you can try modifying
the design or changing the strategy of syn and rerunning it.
```
⇒ **rrl 8 与 18 连布局都进不去。「抬 min_ripple_len 让 #lut 变小」这条单调性在 8→18 段是真的，
但这两档根本跑不完流程 —— 面积表的 19,039 / 18,062 是「physics 上不可交付」的数。**
真正可交付的只有 30 / 45 两档，而 45 更好（4,801 < 4,849，且 #lut 17,645 < 17,744）。

**关键反证二：rl=60 面积反弹，且时序更差**
- 面积单调性只在 8→18→30→45 成立；**rl=60 反弹到 18,563 / 94.71%**，且 ripple 从 314 掉到 165
  —— ripple 减半、LUT 反涨 2,163。「抬 min_ripple_len 一定更好」是假的，**45 是实测拐点**。
- **rl45 单独跑的那次 route 是失败的**。`reports/t7b3_rl45_timing.txt`（2026-11-03 00:20:27）报
  `SWNS: -0.194ns, STNS: -0.215ns` / `HWNS: 0.011ns`。rl60 那次更差：
  `SWNS: -0.689ns, STNS: -2.286ns` / `HWNS: -0.011ns, HTNS: -0.020ns`（`t7b3_rl60_timing.txt`，2026-11-02 20:45:30）。
  ⇒ **抬 min_ripple_len 只改善面积，不保证时序；最终能过是靠 seed=7 重跑。**

**补充：其它 rl45 变体的时序全为负**（同目录、按 mtime 排序，全部 SWNS < 0）：

| 变体 | SWNS / STNS | HWNS / HTNS | 文件（mtime） |
|---|---|---|---|
| rl45 + place post_place_opt high | **−0.183 / −0.485** | −0.020 / −0.053 | `t7b3_rl45_place_post_place_opt_high_timing.txt`（2026-11-02 20:27:28） |
| rl45 + route post_route_opt high | −0.183 / −0.485 | −0.020 / −0.053 | `..._route_post_route_opt_high_timing.txt`（20:27:28，与上一条 MD5 相同 `12D02886A3E1E222C174A1CA6DC4D5A1`） |
| rl45（route 后） | −0.183 / −0.485 | −0.020 / −0.053 | `t7b3_rl45_route_post_route_opt_high_timing.txt`（20:27:29，MD5 `1E0258D0B5F1A31FFC83B3A18C6C948D`） |
| rl45 + place hfn opt effort high | **−0.373 / −1.226** | −0.011 / −0.013 | `t7b3_rl45_place_hfn_opt_effort_high_timing.txt`（22:23:00） |
| rl45 + mapper lut_delay 2200 + merge tiny_lut + route routability | **−1.192 / −9.036** | −0.009 / −0.020 | `t7b3_rl45_gate_mapper_..._timing.txt`（22:23:25） |
| rl45（最终一轮，seed 未固定） | −0.194 / −0.215 | +0.011 / 0.000 | `t7b3_rl45_timing.txt`（**2026-11-03 00:20:27**） |

⇒ **在 seed 固定的那几趟里，没有任何一次 rl45 变体的 SWNS 转正。**唯一转正的是
`seed=7` 那一趟（+0.113）。这条证据把「路线 A 能救 113 ps」的期待压到很低：
参数搜索在 route 阶段反复落负，**3.296 ns 的赤字是靠布线拓扑（seed）拉回来的，不是靠综合参数**。

**风险**：低（纯工具参数，不动 RTL）。**但它解决的是面积，不是 113 ps 的余量。**

**是否动已签收位流**：是。

### 路线 B：扫 place seed

**代价**：每个 seed 一次 place + route（不重跑综合）。实测阶段耗时（`run_seed7.log`，2026-11-03 00:31:47）：
`place` **103.68 s** + `route` **250.36 s** ≈ **6 分钟/seed**（不含 bitgen）；
若只跑到 place（`project/t7b_seed_probe.tcl`，4,334 B / 139 行，打印 `SEED_SLICES=` / `SEED_LUT=` /
`SEED_PLACE_SWNS=` / `SEED_PLACE_HWNS=`），**约 2 分钟/seed，省 2/3 时间**。

**⚠️ 但 probe 筛 seed 有一个已实测的陷阱**：`place.qor`（2026-11-03 00:30:33）报 **Setup WNS +1707 ps**，
而同一趟 route 完只有 **+113 ps** —— **place 阶段的 SWNS 与 route 后的 SWNS 相差 15 倍**，
且方向都可能是错的（本次是「place 很棒、route 悲剧、再拉回来」）。
⇒ **用 `SEED_PLACE_SWNS` 排序 seed 是不可靠的**：它只能筛掉「place 就很差」的 seed，
不能识别「place 好但 route 会崩」的 seed。真要筛，判据应放宽到「place SWNS > 1.5 ns 才进全流程」，
否则等于用一把刻度差 15 倍的尺子选。

**官方多 seed 流程**：`D:\TD_6_24_APP\doc\scripts\MultiSeed.tcl`（TD 6.24 自带），
`project/t7b_seed_full.tcl`（8,456 B / 270 行）第 10 行注释说明本项目参照的是该脚本第 62 行的写法
（`set_param place seed $seed`，本项目在 `t7b_seed_full.tcl:94-107` 加上 `commit_param -step place`）。

**实测依据**：place 阶段 `Setup WNS +1707 ps` 但 `Hold WNS −11 ps`、`violated H-EP 14`
（`place.qor`，2026-11-03 00:30:33）；seed=7 跑完 route 后变成 `Setup +113 ps` / `Hold +11 ps` / `0/0 违例`
（`route.qor`，2026-11-03 00:31:24）。⇒ seed 影响的是**布线拓扑**，进而影响 hold 与 setup。

**一处必须更正的说法**：先前口头讨论里出现过「fix_hold 吃掉 1,594 ps setup 余量」这个推断，**那是错的**，
以日志为准。`run_seed7.log`（2026-11-03 00:31:47）的时间线是：

1. place 结束：`Setup WNS +1707 ps`（`place.qor`）—— 这是**未布线的估计值**。
2. route 的 Stage 2.3.2「Update Timing」（Normal Nets Routing 之后）报
   `Setup: WNS(ns) = -3.296, TNS = -44.816, FEP = 23 | Hold: WNS = -0.020, FEP = 3`（日志第 962 行）。
   ⇒ **真实布线延迟一上来就把 +1707 ps 变成 −3,296 ps**，与 hold 修复无关。
3. Stage 2.4.1.1 Setup TimeOptimization + 多轮 Rip-up & ReRoute，逐步拉回：
   `-2.025` → `-2.031` → `-0.634` → **`+0.113`**（日志第 1011 / 1040 / 1067 / 1093 行）。
4. 之后才做 hold 修复：日志第 1118-1129 行共 **6 条** `1 hold-buffer to be created`（涉及
   `u_hdmi_island_data_gen/.../u_w96_d1024_fifo`、`u_player/u_loader/fifo_wr_data[11]/[14]`、
   `u_wav/s_lo[2]/[5]/[7]`），第 1184 行 `All hold violations are fixed.`，
   setup 值**保持 0.113 ns 不变**。

⇒ 正确的因果是：**place 阶段的 +1707 ps 是乐观估计（未布线）；route 真实布线暴露 −3.296 ns；
靠 setup 优化与拆线重布拉回 +113 ps；hold 修复只插了 6 个 buffer，没有消耗 setup 余量。**

**`drHoldFix` 模式（官方为此专门提供的开关，本卡任务描述点名要求说明）**

`MultiSeed.tcl` 第 99-119 行的 `opt_route_fun` 里，当 `drHoldFix == on` 时：

```tcl
if { [string equal $drHoldFix on] } {
  set_param route fix_hold off      ;# ① 先关掉自动 hold 修复
  set_param flow qor_monitor off
}
route                                ;# ② 跑 route，此时 setup 是「纯 setup 优化」的结果
if { [string equal $drHoldFix on] } {
  if { [string equal $filter on] } { flow_continue_check -step route -wns $routeSwns -name ${prj_name} }
  fix_hold                           ;# ③ 再单独补 hold
  set_param route fix_hold on
  set_param flow qor_monitor on
  report_qor -step route -file route.qor
}
```

**机制**：默认流程是 `route` 内部把 setup 优化与 hold 修复混在一起做，**无法区分「setup 余量被逻辑/
布线吃掉」还是「被 hold buffer 吃掉」**。`drHoldFix on` 把两者拆成两步，于是：
- 若 `route`（关 fix_hold）后 SWNS 就接近 0 → 余量是被**逻辑/布线**吃掉的，补 hold 只会更糟；
- 若 `route` 后 SWNS 明显为正、`fix_hold` 一跑就塌 → 余量是被 **hold buffer** 吃掉的。

**对本次交付的适用性（以下是推理，不是实测）**：本趟 `place.qor` 报 `Hold WNS −11 ps / violated H-EP 14`，
`route.qor` 报 `Hold +11 ps / 0 违例`，日志第 1118-1129 行显示只插了 **6 条** hold buffer，
且 setup 在 hold 修复前后**都是 0.113 ns**（第 1093 行与最终值相同）。
⇒ **本次 hold 修复没有侵蚀 setup**，`drHoldFix` 换不来余量；它的价值在于**未来复现时的诊断**，
不是本次的救命手段。若将来某次 route 出现「setup 差一点点、hold 违例也很多」，那时才值得试它。

**风险**：中。seed 是启发式随机种子，**换 TD 版本或改任何 RTL 都会失效**，结果不可复现。
收益也可能为零（不同 seed 可能都在 0.1 ns 量级）。另一处风险：`#bram` 在两个 seed 间可能不同
—— rl45 系列是 **35**、最终 seed7 是 **37**（`t7b3_rl45_area.txt`（2026-11-03 00:20:27）vs `t7b_seed_seed7_area.txt`）。
**以下是推理，不是实测**：`bram` 数不同说明综合器对 `u_pix_fifo` 用 BRAM 还是 LUTRAM 的选择会随 seed 变，
而 t25 正是靠「强制 BRAM」省下 1,964 lut —— **若某个 seed 选了 LUTRAM，`#lut` 会涨回 18,000 量级并可能撞 19,600**。
`project/t7b_bit3.tcl` 第 250 行的 `if {$bram_used < 35} { exit 16 }` 就是为防这个，但底线是 35 而不是 37，
**扫描 seed 时必须同时检查 `#bram` 是否仍为 37**。

**是否动已签收位流**：是。

### 路线 C：在 OSD 组合链里加流水线

**代价**：必须改 `.v`（在 `osd_strings` / `osd_caption` / `osd_panel` 之间插寄存器），
且**所有下游时序对齐信号要同步延迟**（`de`、`active_x`、`active_y`、`video_valid`、`video_last`、
`video_user` 都要跟着打拍），否则像素与坐标错拍 —— 那是比时序更严重的功能错误。

**收益上限（以下是推理，不是实测）**：36 级 → 18 级，按 net/cell 比例粗估可释放约 15~18 ns，
但 net 延迟（25.045 ns，64%）里有一部分是**布线跨度**而非逻辑级数，插寄存器会改变布局、
未必线性改善。

**风险**：**最高**。要重跑 `tb_video_overlay`（106 条）、`tb_osd_caption`（46 条）、
`tb_osd_caption_cjk`、`tb_display_content`（614,406 条）等全部相关 tb；且 `osd_strings.v`
是**自动生成文件**（其文件头第 40-43 行写明「自动生成，勿手改，改文案请改
`assets/v2/masters/text/` 后重跑 `scripts/gen_osd_strings.py --emit`」），
手工插流水线会在下次生成时被覆盖。

**是否动已签收位流**：是，且会动 RTL 基线。

### 三条路线的选择建议（以下是推理，不是实测）

- **若上板一切正常**：三条都不做。113 ps 在实验室常温下已被 30 分钟稳定性测试覆盖，
  为它重跑位流属于「用一个未验证的改动替换一个已验证的改动」。
- **若出现「升温后偶发错」**：先走 **B（扫 seed）**，因为它不动 RTL、不改面积、
  且 `t7b_seed_probe.tcl` 只到 place 就能筛。A 只改善面积，对 113 ps 帮助不确定
  （rl45 那次 route 反而 −0.194 ns）。
- **若出现「常温下也稳定复现错色/错位」**：那不是时序问题，**三条路线都别走**，
  回 §3 步骤 10 的证伪实验定位到具体模块。
- **C 只在 A、B 都无效且确认是逻辑深度所致时才考虑**，因为它是唯一会动 RTL 基线、
  且会碰自动生成文件的路线。

---

## §5 我无法从现有数据确认的

这一节列出**凭现有落盘产物和源码读不出来的东西**。上板前若有条件，这些是应该补的。

1. **113 ps 在温度/电压漂移下的实际分布**。TD 的 STA 用的是 Slow/Fast 两个 corner
   （`t7b_seed_seed7_timing.txt` 报 `Check Corner: Both(Slow and Fast)`，2026-11-03 00:31:36），
   但没有片上温度/电压扫描数据。**以下是推理，不是实测**：113 ps 对应 40 ns 的 0.28%，
   若工艺/电压 corner 的实际偏差大于此值，室温通过不代表高温通过。

2. **`u_axis` 那 2,384 LUT 的具体构成**。已确认它是跨边界吸收（独立综合 20~23 lut，
   见 §1.3），但**具体哪些模块的哪些逻辑被拉进去、各占多少**，需要门级网表反查。
   本次尝试过：`project/hdmi_td_Runs/syn_1/` 与 `phy_1/` 下只有
   `.bit/.prj/.tcl/run.log/flow.status/settings.cfg`，全仓 `*.vm/*.vo/*.vg` 搜索结果为空
   ⇒ **无网表可用，此项无法从现有数据确认**。
   替代证据是 Rent 表（`gate.qor`：`u_axis` Cell 2,274 / Term 859 / Rent 0.67）与
   路径 net 名的模块前缀分布（§1.3），但那是间接的。

3. **`u_fade` 在真实换图时的像素正确性**。`fade_mixer` 的 `gain = level + 1` 设计上保证
   level=255 时逐位还原、level=0 时全黑（源码第 19-20 行注释），但**没有任何 tb 断言验证
   `fade_mixer` 本身的输出**（它例化在 `image_player` 内部，现有 tb 只看换帧时序）。
   ⇒ 「淡入淡出时中间帧的颜色对不对」目前**无自动化证据**，只能上板肉眼看。

4. **BRAM 版 `u_pix_fifo` 的读延迟在真实 SDRAM 供给下的表现**。`tb_pix_reader` 194 条断言
   在行为模型下通过，但 BRAM 同步读（1 拍）与上一版 LUTRAM 异步读（0 拍）的差异
   **只在真实时序下才体现**。现有数据无法回答「BRAM 版在 SDF 反标后是否仍与 194 条断言一致」——
   没做过 SDF 仿真。

5. **`i2c_master` 的物理可靠性**。SDC 里是 `set_false_path`（`dmz_eg4s20_hdmi.sdc`，2026-11-01 21:52:29），
   时序工具完全跳过它。上拉电阻的实际阻值、飞线长度、AHT20 模块自带上拉的并联效应，
   都不在任何落盘文件里。**这是本报告里唯一「时序通过」完全不覆盖的功能。**

6. **seed=7 之外的其他 seed 的结果**。仓库里只有 `t7b_seed_seed7_*` 一套完整产物
   （`reports/t7b_seed_seed7_area.txt` / `_timing.txt` / `_place_area.txt` / `_place_timing.txt`），
   **没有 seed 1~6 的记录**。因此「seed 7 是好运气还是中等水平」无法判断，
   路线 B 的收益上限也就无法预估。

7. **`#slices` 的「当时值 vs 落盘值」**。`project/t7b_bit3.tcl` 第 277-281 行的注释已记录这个坑：
   磁盘上的 `place.qor` 会被 route 阶段重写（该注释举例：日志里 place 当时报 8,746 / 89.24%，
   而落盘的 `place.qor` 是 8,752 / 89.31%）。本次读到的 `place.qor`（2026-11-03 00:30:33）与 `route.qor`
   （2026-11-03 00:31:24）**都是 8,591 / 87.66%**，两个阶段的 `#slices` 完全一样 —— 这个巧合本身说明
   落盘值至少在本趟没有被改写污染，但**我没有做逐行比对来证明这一点**。
   可复核的替代口径是 `run_seed7.log`（2026-11-03 00:31:47）里的 `RUN-1001` 行：
   **place 阶段 `4278 mslices, 4277 lslices`**（第 456 行）、**route 阶段 `4306 mslices, 4279 lslices`**
   （第 834 行、第 846 行）。注意 `mslices` 与 `#slices` **不是同一个量**，不可混用 ——
   `mslices` 是 M-slice 的物理占用数（4,900 是硬门槛，见 §4 路线 A），`#slices` 是逻辑 slice 计数。

8. **`#bram` 会随 seed / 综合策略在 35 与 37 之间摆动，这直接决定 `#lut` 是 16,414 还是 18,000 量级**。
   实测（同一份 RTL、同一个 min_ripple_len=45）：

   | 报告 | mtime | #bram | u_reader lut | u_pix_fifo lut |
   |---|---|---|---|---|
   | `t7b3_rl45_area.txt`（2026-11-03 00:20:27） | 2026-11-03 00:20:27 | **35** | 238 | 48（但整档 bram 少 2） |
   | `t7b_seed_seed7_area.txt`（2026-11-03 00:31:36，最终交付） | 2026-11-03 00:31:36 | **37** | 238 / 2 bram | 48 / 2 bram |

   **以下是推理，不是实测**：`#bram` 35 与 37 的差就是 `u_pix_fifo` 那 2 块 BRAM 有没有被用上；
   t25 省下的 1,964 lut 完全依赖于它。`project/t7b_bit3.tcl` 第 250 行只设了
   `if {$bram_used < 35} { exit 16 }` 这条底线 —— **底线 35 挡不住「35 但 pix_fifo 退回 LUTRAM」这种情况**。
   ⇒ 我无法从现有数据判断「35 档的 `#lut` 是多少」，只能确认最终交付的 37 档 `#lut` 是 16,414。

9. **`reports/` 目录下存在多份同名不同内容的报告，`%TEMP%` 里的运行日志更是不在版本控制内**。
   本轮实测到两个具体例子：
   - `reports/t7b3_rl45_area.txt` **被多次覆盖**：2026-11-02 23:43 是 `u_fade 35 lut`，
     2026-11-03 00:05 / 00:20 都是 `u_fade 34 lut`，但**顶层 `#lut` 值在两次之间也变过**
     （这也是本卡任务描述里那条「`t7b3_rl45_area.txt` 被覆盖成 16,400」提醒的同类现象）。
   - `t7b3_rl45_place_post_place_opt_high_timing.txt` 与
     `t7b3_rl45_place_post_place_opt_high_route_post_route_opt_high_route_fix_hold_on_timing.txt`
     **MD5 完全相同**（`12D02886A3E1E222C174A1CA6DC4D5A1`）—— 文件名声称跑了两个不同流程，
     文件内容一模一样，说明其中一次没有真正执行或用错了产物路径。
   - 本报告 §4 引用的 `mslices` 数据，来源是 `%TEMP%` 下的 `t7b_ripple_B_rl8.log`（2026-11-02 19:53:07）、
     `t7b_syn2_rtl_min_ripple_len_18.log`（2026-11-02 19:47:02）、`t7b_ripple_D_rl30.log`（2026-11-02 19:55:09）、
     `t7b_ripple_E_rl45.log`（2026-11-02 19:55:14）—— **这些文件不在仓库里，清理临时目录就永久消失**。
     ⇒ 若将来要复核 §4 的 `PHY-9009` 结论，必须先确认这四个日志还在；建议由 t9 把它们归档到
     `reports/` 下（本卡 inScope 只有一份报告，不能搬运）。

---

## §6 附：本文引用的文件清单与版本指纹

| 文件 | 版本 / mtime |
|---|---|
| `rtl/video/hdmi/video_rgb_to_axis.v` | 81 行 / 3776 B / MD5 BF7C793BF99F |
| `rtl/video/emerg_page.v` | 123 行 / 6427 B / MD5 3D47E4C5DE72 |
| `rtl/osd/osd_strings.v` | 464 行 / 29751 B / MD5 876194DE97AB |
| `rtl/osd/osd_caption.v` | 586 行 / 34543 B / MD5 DFD82C9EF027 |
| `rtl/osd/osd_panel.v` | 247 行 / 14594 B / MD5 6E653F547C02 |
| `rtl/video/video_overlay.v` | 320 行 / 19901 B / MD5 037711D55D4A |
| `rtl/storage/image_player.v` | 628 行 / 34666 B / MD5 4E8B620FF7BA |
| `rtl/storage/fade_mixer.v` | 30 行 / 1781 B / MD5 634FC30A8BD6 |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | 1256 行 / 85825 B / MD5 4D1685E6FAEE |
| `project/hdmi/dmz_eg4s20_hdmi.sdc` | 2026-11-01 21:52:29 |
| `project/hdmi/dmz_eg4s20_hdmi.adc` | 2026-11-01 21:51:06 |
| `reports/t7b_bit_v3_seed7_PASS/route.qor` | 2026-11-03 00:31:24 |
| `reports/t7b_bit_v3_seed7_PASS/place.qor` | 2026-11-03 00:30:33 |
| `reports/t7b_bit_v3_seed7_PASS/gate.qor` | 2026-11-03 00:13:52 |
| `reports/t7b_bit_v3_seed7_PASS/t7b_seed_seed7_timing.txt` | 2026-11-03 00:31:36 |
| `reports/t7b_bit_v3_seed7_PASS/t7b_seed_seed7_area.txt` | 2026-11-03 00:31:36 |
| `reports/t7b_bit_v3_seed7_PASS/t7b_seed_seed7_coverage.txt` | (不存在) |
| `reports/t7b_bit_v3_seed7_PASS/run_seed7.log` | 2026-11-03 00:31:47 |
| `reports/t7b_bit_v3_seed7_PASS/hdmi_td_v3_seed7.bit` | 2026-11-03 00:31:47 |

> 位流指纹（**交付物本体**）：`project/hdmi_td_Runs/phy_1/hdmi_td.bit`，
> 648,264 B，mtime 2026-11-03 00:31:47，**MD5 `59A6BACC75613F5E953B7ED5A33E05E8`**。
> 同一份产物在 `reports/t7b_bit_v3_seed7_PASS/hdmi_td_v3_seed7.bit` 也有一份留档
> （648,264 B，2026-11-03 00:31:47）。**两份已做过 MD5 逐字节比对：完全相同**，
> 即 `59A6BACC75613F5E953B7ED5A33E05E8` 就是烧录进 EG4S20BG256 的那一份。
>
> 本文全部数值均从上述文件读出，未做任何外推；凡外推均已标注「以下是推理，不是实测」。
