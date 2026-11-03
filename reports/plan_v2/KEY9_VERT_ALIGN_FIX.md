# Key9 纵向裁剪对齐 —— 实测复核与断言交付

> 任务：t31（attempt 3，attempt_id `7a00e287-e752-4fa9-a64e-23e723eeed66`）
> 结论一句话：**纵向裁剪本来就是居中对齐的。本次交付的是把它钉住的断言与逐档实测证据，`rtl/storage/pix_reader.v` 一个字节都没改。**

## 0. 版本声明（行号引用基准）

本文所有行号引用一律基于下面两份**原件**，行号随文件改动会漂移，引用前请先核 MD5：

| 对象 | 路径 | 尺寸 | MD5 |
|---|---|---|---|
| RTL 本体 | `SmartCampusMedia/rtl/storage/pix_reader.v` | 24,820 B | `3CAD6F6BE9F59B1FB1376AD5945350E5` |
| tb 本体 | `SmartCampusMedia/sim/testbench/tb_pix_reader.v` | 40,430 B / 870 行 | `1385CE5F0FC13DF5ACDAE864FEA37CB0` |

**RTL 零改动的证据**：上表 MD5 `3CAD6F6BE9F59B1FB1376AD5945350E5` 与 captain 在任务卡里给出的开工基线逐字相同，且与本次收工时的实测值逐字相同。本次全部改动落在 tb 一个文件内。

本文严格区分两类叙述：

- **实测** —— 有仿真日志原文或命令退出码，可直接复跑。
- **推算** —— 纸面算术，未经仿真验证，只用于解释实测现象。

## 1. 问题原状与上级判断的更正

任务卡原假设：窗口里装的是源图**顶部**（源行 `0 .. win_h-1`），应为**居中**（源行 `win_off_y .. win_off_y+win_h-1`），因此需要「在非窗口面板行里把 `win_off_y × 320` 个字消费掉丢弃」。

这条假设在实测下不成立。我按「只观测、不改 RTL」的方式加了观测用例，`win_off_y=120`、`win_h=240` 时实测：

```
K9Y: first_panel_row=120 first_src_row=120 want_src_row=120 rows=240 align_bad=0
```

**窗口首行显示的就是源行 120，240 行逐行吻合。** captain 已复核并确认是他判断有误，错在把档 0 的特例当成了通例：

- 档 0（`win_w=320`）：`h_acc_next = h_acc + 320 - 320 = h_acc`，行首预载 320，因此 `h_acc >= win_w_eff` 恒真、**每拍取 1 字**。
- 档 1（`win_w=400`）：`h_acc_next = h_acc + 320 - 400 = h_acc - 80`，行首预载 400，400 拍内取满 320 字，节奏是**取 4 拍停 1 拍**。

**真正的契约是「窗口内恰好取满 320 字 = 一条源行」，不是「每拍取 1 字」。** 于是每个面板行恰好消耗一条源行，面板行 `k` 显示源行 `k`，纵向 1:1 天然对齐；窗口以外那些面板行也照样每行推进一条源行，队头走到窗口首行时已经正好推进了 `win_off_y` 条。

（原件 `pix_reader.v` 相关行：`:279` `h_take`、`:280` `h_pop = h_take && !fifo_rd_empty`、`:281` `take_word`、`:282-283` `h_acc_next`、`:289-293` 行首预载与累加。）

## 2. 本次交付

`rtl/storage/pix_reader.v` 保持 `24,820 B / MD5 3CAD6F6BE9F59B1FB1376AD5945350E5` 不动；只改 `SmartCampusMedia/sim/testbench/tb_pix_reader.v`（596 行 → 870 行），新增三组用例：

1. **五档纵向对齐用例** `k9y_tiers`：`win_off_y` 取 120 / 90 / 60 / 30 / 0，逐档断言 6 条 —— 首个窗口面板行号、窗口首行反查出的源行号、末行源行号、窗口内逐字比对错误数、窗口行数、`stat[0]` 上升沿数。小几何（默认 64×8）下 `win_off_y` 按 `LINES * off / 480` 等比退化，真实五档必须靠 `-FullVga` 跑。
2. **水平窗口档** `k9y_horiz_case`：`win_w = PIX_PER_LINE/2`、`win_off_x = PIX_PER_LINE/4`，证明水平降采样 DDA 不会改变「一窗口行 = 一条源行」这个推进关系。
3. **多帧浸泡** `k9y_soak`：连续 20 帧，每帧都重走一次 `P_RESTART`，因此每帧都是一次完整的「帧首从空 FIFO 补水到窗口首行」压力过程。逐帧核对首行源行号，漂移即打印 `K9Y_SOAK_DRIFT`；同时统计 FIFO 空拍数与 `stat[0]` 上升沿数。

配套改动两处：`parameter SOAK_FRAMES = 20;`，以及把 watchdog 帧预算从固定 24 帧改为 `24 + SOAK_FRAMES + 6 + 8`。**这里只放宽「测多久」，不放宽任何判据**——原预算在新增用例下会在合法用例中途触发 `FAILED: tb_pix_reader global timeout`。

## 3. 五档实测（-FullVga，真实 640×480）

运行参数即契约 verify 入口 `powershell -File sim\scripts\run_storage_regression.ps1 -Suite Pixels -FullVga` 的 VGA 那一趟：`PIX_PER_LINE=640 / LINES=480 / H_FP=16 / H_SYNC=96 / H_BP=48 / V_FP=10 / V_SYNC=2 / V_BP=33 / FIFO_AW=9 / LEVEL_HI=384 / STRESS=0`。

```
K9Y_TIER t=0 off_y=120 win_h=240 first_panel=120 first_src=120 last_panel=359 last_src=359 rows=240 align_bad=0 empty=0/307200 uf=0
K9Y_TIER t=1 off_y=90  win_h=300 first_panel=90  first_src=90  last_panel=389 last_src=389 rows=300 align_bad=0 empty=0/307200 uf=0
K9Y_TIER t=2 off_y=60  win_h=360 first_panel=60  first_src=60  last_panel=419 last_src=419 rows=360 align_bad=0 empty=0/307200 uf=0
K9Y_TIER t=3 off_y=30  win_h=420 first_panel=30  first_src=30  last_panel=449 last_src=449 rows=420 align_bad=0 empty=0/307200 uf=0
K9Y_TIER t=4 off_y=0   win_h=480 first_panel=0   first_src=0   last_panel=479 last_src=479 rows=480 align_bad=0 empty=0/307200 uf=0
K9Y_HORIZ: off_y=120 win_w=320 first_panel=120 first_src=120 last_src=359 rows=240 align_bad=0 empty=0/153600 uf=0
```

逐档对照任务卡判据（`first_src_row` 必须分别等于 `win_off_y`）：

| 档 | 窗口 | `win_off_y` | 判据要求 `first_src_row` | 实测 `first_src_row` | 实测 `last_src_row` | 窗口行数 | 窗口内错字 | FIFO 空拍 | `stat[0]` 上升沿 |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 320×240 | 120 | 120 | **120** | 359 | 240 | 0 | 0 / 307,200 | 0 |
| 1 | 400×300 | 90 | 90 | **90** | 389 | 300 | 0 | 0 / 307,200 | 0 |
| 2 | 480×360 | 60 | 60 | **60** | 419 | 360 | 0 | 0 / 307,200 | 0 |
| 3 | 560×420 | 30 | 30 | **30** | 449 | 420 | 0 | 0 / 307,200 | 0 |
| 4 | 640×480 | 0 | 0 | **0** | 479 | 480 | 0 | 0 / 307,200 | 0 |

五档全部命中：首行 `= win_off_y`、末行 `= win_off_y + win_h - 1`、窗口行数 `= win_h`、窗口内逐字比对零错。**`align_bad=0` 的含义是窗口内每一个出队字都与 `expected_pixel()` 逐字相等**，而 `expected_pixel` 是 tb 侧独立算的源图模型，不复用 DUT 任何表达式，因此这不是同义反复。

默认几何（64×8）的五档同样 `first_src == win_off_y` 成立，但 `win_off_y` 退化成 2 / 1 / 1 / 0 / 0（整数缩放），只能证明机制成立，不能证明真实档位数值——真实五档以上表为准。

## 4. 欠载与带宽：1.56% 的逐行口径缺口，34.6% 的整帧口径富余

captain 在恢复指令里点出我的观测用例存在盲区：`h_pop = h_take && !fifo_rd_empty`（原件 `:280`），**欠载那一拍 `h_pop=0`**，于是 `:282` 的三目走 false 分支 `h_acc + WORDS_LINE16` 而不是减去 `win_w_eff`——信用超前累积，那一行没取满 320 字，行内数据截短且错位会按行累积。他据此指出带宽结构上逐行口径需求 0.5 字/拍、供给 0.492 字/拍，需求高于供给约 1.56%，长期运行必然周期性欠载。这条要求我按真实补水节奏重跑并给出三种结果之一的处置。

**（推算，以下四个数是纸面算术，未经仿真）**

- 一帧时钟数 `H_TOTAL × V_TOTAL = 800 × 525 = 420,000`，25 MHz 下 16.8 ms。
- 一帧要取的字节数 `FRAME_WORDS = 153,600`，折算需求 `153,600 × 25 MHz / 420,000 = 9.143 M 字/秒`。
- SDRAM 侧供给上限按 `framebuf_arbiter.v:18 RD_GROUP_CYCLES = 13`、每读组 4 字、`sdr_clk` 40 MHz：`4 / 13 × 40 MHz = 12.308 M 字/秒`。
- **整帧口径**：`12.308 / 9.143 = 1.3462`，供给富余 34.6%。
- **逐行口径**：窗口内一行要 320 字 / 640 拍 = 0.5 字/拍，供给 `4/13 × 40/25 = 0.4923 字/拍`，缺口 **1.56%**。
- 两个口径不矛盾的机制：一帧有 `420,000 - 307,200 = 112,800` 拍消隐期，这期间 `fifo_rd_en` 由 `P_DRAIN` 分支保持（原件 `:174`），可以补水；所以逐行那 1.56% 的缺口由消隐期补偿，整帧角度看有 34.6% 的富余。**欠载只可能发生在「窗口内某一行正在取字」的瞬间，且能在随后消隐期补回来。**

**（实测）** 逐帧日志给出的旁证：`groups=38491`（多数帧，个别 38492）而 `FRAME_GROUPS=38400`，多出来的 91 组 = 364 字正是预取余量；`level_peak=378 < LEVEL_HI=384`，水位始终没到顶。

**（实测）浸泡结果**：

```
K9Y_SOAK: frames=20 drift=0 uf_frames=0 uf_edges=0
```

- `frames=20`：连续 20 帧，每帧都重走 `P_RESTART`，即 20 次独立的「从空 FIFO 补水到窗口首行」完整过程。
- `drift=0`：20 帧里首行源行号**从未**偏离 `win_off_y`。
- `uf_frames=0` / `uf_edges=0`：`stat[0]` 一次都没起来，即**全程未观测到欠载**。
- 同一用例在默认几何与 -FullVga 两趟都打印同一行，两趟一致。

**按 captain 给的三种结果对应处置，本次属于第 ① 种：实测未观测到欠载。** 因此：

- 报告如实写「实测未观测到欠载」，不写「不会有欠载」。
- **1.56% 的逐行结构性缺口记为已知理论风险**：它没有在 20 帧（约 336 ms 仿真时间）的浸泡里显现，但这不等于它不存在；若将来出现现场欠载，`h_pop` 那条信用分支（原件 `:280` / `:282`）是第一个要看的地方，而不是往 `pix_reader` 里加纵向门控。
- RTL 不改。

## 5. 基线对齐

契约 verify 第三条 `powershell -File sim\scripts\run_storage_regression.ps1 -Suite Pixels -FullVga` 实跑输出：

```
tb_pix_reader: passed; exit=0; checks=542; errors=0; cases=39; log=...\tb_pix_reader.log
tb_pix_reader_vga: passed; exit=0; checks=498; errors=0; cases=36; log=...\tb_pix_reader_vga.log
A4-GATE: ran=2 passed=2 expected=2
REG_EXIT=0
```

| 用例 | 开工基线 | 收工实测 | 增量 | 判定 |
|---|---|---|---|---|
| `tb_pix_reader`（64×8） | 194 / 0 / 13 | **542 / 0 / 39** | +348 checks / +26 cases | errors 恒为 0 |
| `tb_pix_reader_vga`（640×480） | 150 / 0 / 10 | **498 / 0 / 36** | +348 checks / +26 cases | errors 恒为 0 |

**关于任务卡里「加用例后应为 166」这个预期数字，需要说清楚差异**：166 是我上一轮单个 V-04 观测用例（16 条附加断言）的预期值。captain 在恢复指令里把要求扩大到「五档逐档 + 真实补水浸泡 ≥ 数十帧」，最终新增 26 个用例、348 条断言，因此 166 这个数不再适用，实测是 498。**错误数在两种几何下都严格为 0，且两条路径都打出了 `ALL CHECKS PASSED: tb_pix_reader`**——这是本卡最硬的证据。

档 4（`win_off_y=0 / win_h=480` 满屏恒等档）在 `-FullVga` 下 `first_src=0`、`last_src=479`、`rows=480`、`align_bad=0`，说明 `h_ident` 硬判旁路没有被新用例破坏：该档 `use_key9=0`，走的是改造前那条 `pix_valid_raw` 通路，判据逐字不变。

## 6. 反证：断言朝「失败时变红」的方向设计

**做法**（按纪律，全程在 `%TEMP%` 独立副本里做，`rtl/` 工作树与 tb 工作树都没碰）：把副本里两条 `k9y_first_src == k9y_off` 改成 `k9y_first_src == (k9y_off + 1)`，即**期望值故意写错 1 行**，重编译重跑。

**双计数（变异前后特征串命中数）**：

| 特征串 | 变异前 | 变异后 |
|---|---|---|
| `k9y_first_src == k9y_off` | **2** | **0** |
| `k9y_off + 1` | **0** | **2** |

两个数都变了，说明变异确实落到了文件里，不是「注入了但没生效」。

**变异后实跑结果**：

```
SUMMARY: checks=542 errors=6 cases=39 geometry=64x8
```

**6 条变红，5 档 + 1 个水平窗口档各一条**，逐条打印原文：

```
FAIL: first window row shows source row win_off_y (centered crop)   ← 档 0
FAIL: first window row shows source row win_off_y (centered crop)   ← 档 1
FAIL: first window row shows source row win_off_y (centered crop)   ← 档 2
FAIL: first window row shows source row win_off_y (centered crop)   ← 档 3
FAIL: first window row shows source row win_off_y (centered crop)   ← 档 4
FAIL: horizontal window keeps the horizontal DDA from shifting the row origin  ← 水平窗口档
```

**为什么是 6 条而不是更多**：浸泡用例的判据比对的是「首行源行号 == `k9y_off`」这一实测值，不受期望值变异影响，因此 20 帧浸泡的断言保持绿；这正好说明变异只打在期望侧、没有污染观测侧。

**恢复后贴绿**：变异副本已随 `%TEMP%` 清理，工作树从未改动，工作树本身的实测结果就是第 5 节那两行（`542 / 0 / 39` 与 `498 / 0 / 36`，`errors=0`）。**因此「恢复后贴绿」有且只有一份证据：本轮契约 verify 的实跑输出，不是另跑一次。**

**这条反证的意义**：如果不做，第 3 节那五档 `first_src=120/90/60/30/0` 只能证明「当前的数字是这些」，不能证明「换个数字会红」——而后者才是断言有效性的判据。反证证明这 6 条断言确实朝失败方向敏感，不是恒真的装饰。

## 7. 三条契约 verify 的实测

| # | 命令（逐字） | 结果 |
|---|---|---|
| 1 | `python scripts\lint_verilog.py rtl/storage` | 18 文件，**E0=0 / E1=0 / E2=0**，`LINT_EXIT=0` |
| 2 | `python scripts\check_port_names.py` | `RESULT: PASS`，`NO_SUCH_PORT=0`，`PORT_EXIT=0` |
| 3 | `powershell -File sim\scripts\run_storage_regression.ps1 -Suite Pixels -FullVga` | `tb_pix_reader 542/0/39`、`tb_pix_reader_vga 498/0/36`、`A4-GATE ran=2 passed=2 expected=2`、`REG_EXIT=0` |

## 8. 工程口径与禁词

- 本次修的是**裁剪对齐**——确切的说是把「本来已对齐」这件事钉上断言。**Key9 终口径仍是 `KEY9_RULING.md` 的「横向压缩 + 纵向 1:1 裁剪，不是等比缩小」**，本次不动那个口径。
- 纵向裁剪后窗口内显示的是源图的**中部连续 1:1 条带**（`win_off_y .. win_off_y+win_h-1`），行数 `= win_h` 不变，像素不缩放、不重采样。
- 未观测到欠载不等于不存在欠载，第 4 节把 1.56% 的逐行缺口与 34.6% 的整帧富余并列记录，供后续在真实硬件上复核。

## 9. 复现路径

1. 基线（改前状态）可用 `git stash` 或 checkout tb 的 HEAD 版本得到，命令与本节相同。
2. 跑契约入口：`cd /d D:\FPGA_Compelate\SmartCampusMedia && powershell -File sim\scripts\run_storage_regression.ps1 -Suite Pixels -FullVga`。该脚本自己在 `reports\s6_validation\` 下建库、`vlib work`、编译、跑两趟，并把每趟日志落到同名 `.log`。VGA 那一趟约 245 s。
3. 只看五档结果：`Select-String -Path reports\s6_validation\tb_pix_reader_vga.log -Pattern "^# K9Y"`。
4. 两个已知坑：①`-gXXX=nnn` 是 **vsim** 的参数不是 vlog 的，传给 vlog 会报 `(vlog-1902) Option "-gPIX_PER_LINE=640" is either unknown`；②`fifo_rd_empty` 是 DUT 内部 wire、不在端口表里，tb 里直接引用会报 `(vlog-2730) Undefined variable`，必须写 `dut.fifo_rd_empty`。
