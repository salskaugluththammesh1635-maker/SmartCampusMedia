# T31 复核报告：Key9 纵向裁剪「不改 RTL、只补证据」的改向是否成立

| 项 | 值 |
|---|---|
| 复核人 | verifier |
| 复核对象 | t31（实现者 rtl-storage） |
| 复核性质 | review round 1（不是重做 t31） |
| 复核时间 | 2026-11-03 12:16（Asia/Shanghai） |
| 写入范围 | 本文件是唯一写入；`rtl/` 与 `sim/` 零字节改动（证据见 §8） |
| 复核结论 | **verdict: pass** |

---

## §0 结论摘要

**verdict: pass。** t31 把「修 Key9 纵向裁剪错位」改成「RTL 零改动 + 把性质钉上断言 + 留证据」，这个改向成立；补的那套断言确实能抓住错位。

三问的答案：

1. **RTL 真零改动？** 是。`rtl/storage/pix_reader.v` 实测 24,820 B / MD5 `3CAD6F6BE9F59B1FB1376AD5945350E5`，与开工基线逐字相同。`git diff` 显示的 450 增 / 281 删是历史漂移，不是 t31 引入（见 §2）。
2. **新增断言真能抓错位？** 能。夹具 `expected_pixel()` 与被测代码不同源（`1009` / `211` / `73` 三个夹具常量在 DUT 全文 0 命中）；`k9y_align_bad` 在五档纵向用例上**逐像素**比对、在水平窗口档上**逐出队字**比对，实测分母 307,200 与 153,600 全部非零（见 §3）。
3. **反证 6 条有没有「碰巧变红」？** 没有。六条逐一对应六个用例的首行断言，且同档其余五条断言实测全绿 —— 不存在「别的断言先红掩盖首行断言」的情形（见 §4）。

第四问（供给节奏）的口径建议见 **§5**：`未在真实供给节奏下验证` 这个说法**不成立**，应改写为「读组节奏已覆盖，未覆盖的是 SDRAM 加密真核与 BMP 写入路径」。

---

## §1 复核对象、方法与判据来源

### 1.1 两个文件（开工基线与实测逐字对照）

| 文件 | 字节 | MD5 | UTF-8 行数 | mtime | 与基线 |
|---|---|---|---|---|---|
| `rtl/storage/pix_reader.v` | 24,820 | `3CAD6F6BE9F59B1FB1376AD5945350E5` | 450 | 2026-11-03 09:51:57 | **逐字相同** |
| `sim/testbench/tb_pix_reader.v` | 40,430 | `1385CE5F0FC13DF5ACDAE864FEA37CB0` | 870 | 2026-11-03 10:48:12 | **逐字相同** |

采集命令：

```powershell
Get-FileHash -Algorithm MD5 'D:\FPGA_Compelate\SmartCampusMedia\rtl\storage\pix_reader.v'
Get-FileHash -Algorithm MD5 'D:\FPGA_Compelate\SmartCampusMedia\sim\testbench\tb_pix_reader.v'
[System.IO.File]::ReadAllLines($p,[System.Text.Encoding]::UTF8).Count
```

> 行号一律用 `ReadAllLines(..., UTF8)` 取。本仓有 UTF-8 无 BOM 的中文文件，`Get-Content` 默认按 GBK 解码会把行数算错，不能用来数行号。

### 1.2 本报告引用的版本声明

- 源码行号一律指 **`pix_reader.v` 本体 450 行版**（MD5 `3CAD6F6B…`）。
- tb 行号一律指 **`tb_pix_reader.v` 本体 870 行版**（MD5 `1385CE5F…`）。

### 1.3 判据来源（不采信任务卡数字，一律回读原始日志）

| 证据 | 路径 | 大小 / 时间 |
|---|---|---|
| 五档真几何实测 | `reports/s6_validation/tb_pix_reader_vga.log` | 13,366 B / 2026-11-03 12:03:29 |
| 小几何干净基线 | `sim/_t31_d/transcript` | 5,873 B / 2026-11-03 10:48:24 |
| 改动前 -FullVga 老基线 | `sim/_t31_probe/transcript` | 3,379 B / 2026-11-03 09:56:50 |
| 反证变异体运行日志 | `%TEMP%/t31_refute/work_lib/transcript` | 6,538 B / 2026-11-03 10:53:07 |

---

## §2 问一：`pix_reader.v` 是否真零改动

### 2.1 结论

**是零改动。** MD5 与开工基线逐字相同（§1.1），mtime 09:51:57 早于 tb 的 10:48:12，说明 t31 的改动只落在 tb 上。

### 2.2 `git diff` 为什么显示 450 / 281 —— 这不是 t31 引入的

```powershell
cd D:\FPGA_Compelate\SmartCampusMedia
git diff --numstat -- rtl/storage/pix_reader.v sim/testbench/tb_pix_reader.v
```

实测输出（与 captain 给的数字逐字一致）：

```
450	281	rtl/storage/pix_reader.v
563	5	sim/testbench/tb_pix_reader.v
```

而 `git show HEAD:rtl/storage/pix_reader.v` 只有 **265 行**，且 `Select-String 'use_key9|win_off_y'` 在 HEAD 版里 **0 命中** —— HEAD 那份是不含 Key9 支路的远古版本。差异来自 t4 / t20 / t22 / t28 的累积漂移（本仓库长期未提交），与 t31 无关。

**判据只能是「与开工基线 MD5 相同」，不是「与 git HEAD 相同」。** 用 HEAD 当基线会把别人的历史改动记到本卡头上。

### 2.3 「不用改」这个判断在结构上站得住

`pix_reader.v`（450 行版）里 `win_off_y` 全文只出现 **1 次**、`win_h` 只出现 **3 次**，且全部是端口声明与注释，逻辑里零消费者：

- `:65 input wire [15:0] win_h` 注释「只参与满屏判据；纵向 1:1 裁剪，不缩放」
- `:67 input wire [15:0] win_off_y` 注释「只参与满屏判据；纵向不缩放」
- 逐行统计：`win_off_y` lines=1 / `win_h` lines=3 / `win_w` lines=23（`Select-String` 计数）

⇒ 纵向位置完全由「行末触发源行推进」决定，与 `win_off_y` 无关。所以「窗口第 k 行显示源行 k」是结构性质，不是巧合；在非窗口行丢弃 `win_off_y × 320` 字的方案**确实不需要做**。

### 2.4 h_acc 信用累加器的真实契约（captain 认错的那条）

`:282-283`：

```verilog
assign h_acc_next = h_pop ? (h_acc + WORDS_LINE16 - win_w_eff) :
                           (h_acc + WORDS_LINE16);
```

`:258-259`：`localparam [15:0] LINE_PIX16 = PIX_PER_LINE;` / `localparam [15:0] WORDS_LINE16 = PIX_PER_LINE / 2; // 一行 320 字，等于窗口内必须取的字数`

契约：窗口内每列信用 +320，阈值 `win_w_eff`，**真正取到字才减 `win_w_eff`** ⇒ 取字率恒为 320 / win_w ⇒ 恰好 `win_w` 列取满一整行的 320 字。档 0（`win_w = 320`）时 `h_acc_next = h_acc + 320 − 320 = h_acc` 恒真、退化成「每拍取 1 字」，那是特例；档 1（`win_w = 400`）是「取 4 拍停 1 拍」。

实测佐证（`tb_pix_reader_vga.log`）：

```
:36 K9_HALF: rows=480 takes_per_row=[320..320] in_cycles=153600 in_bad=0 out_cycles=153600 out_bad=0 row_bad=0 spread_bad=0 gap=[1..1] src_step_bad=0
:39 K9_FRAC: rows=480 takes_per_row=[320..320] in_cycles=230400 in_bad=0 out_cycles=76800 out_bad=0 row_bad=0 spread_bad=0 gap=[1..2] src_step_bad=0
```

480 行里 `takes_per_row` 恒为 320、`src_step_bad=0` ⇒ 每个面板行恰好消耗一条源行，档 1 的 `gap=[1..2]` 正是「取 4 停 1」。

---

## §3 问二：新增断言真能抓错位

### 3.1 夹具 `expected_pixel()` 与被测代码不同源（不是同源同错）

`tb_pix_reader.v`（870 行版）`:211-218`：

```verilog
function [15:0] expected_pixel;
  input integer x;
  input integer y;
  if (row_only) expected_pixel = y * 211 + frame_seed * 1009;
  else          expected_pixel = x * 73 + y * 211 + frame_seed * 1009;
endfunction
```

在 `pix_reader.v`（450 行版）全文 grep 三个夹具常量：`1009` **0 命中**、`\b211\b` **0 命中**、`\b73\b` **0 命中**。

⇒ 夹具公式是 tb 独立定义的（`x*73 + y*211 + seed*1009`），DUT 里根本没有这组数。**判据不是拿 DUT 的表达式复算 DUT 的输出**，captain 担心的「参考模型与被测代码同源同错」在这里不成立。

补充：`:226-233` 的 `fill_frame` 把夹具写进 `u_ctrl.u_model.mem[address]`（SDRAM 行为模型的存储阵列），是**由 tb 独立生成**的，不读 DUT 任何数据或指针；`:225` 还先断言 `chk(!de, "fixture updates occur outside visible pixels")` 保证写夹具发生在可见区之外。

### 3.2 `align_bad == 0` 的覆盖范围：窗口内每个字 / 每个像素都真的比了

`align_bad` 有两条来源，按档位二选一：

**（甲）满屏恒等档**（五档纵向用例走这条，`k9y_horiz = 0`）— tb `:423-429`：

```verilog
if ((active_x >= win_off_x) && (active_x < (win_off_x + win_w))) begin
  k9y_win_cycles = k9y_win_cycles + 1;
  if (pix_valid === 1'b1)
    if (pix_rgb565 !== expected_pixel(active_x, active_y)) k9y_align_bad = k9y_align_bad + 1;
end
```

逐**像素**比对，分母 = 一帧全部可见像素 = 640 × 480 = **307,200**。

**（乙）水平窗口档**（`k9y_horiz = 1`）— tb `:378-380`：

```verilog
if (out_valid === 1'b1)
  if (pix_rgb565 !== expected_pixel(k9y_word * 2, active_y)) k9y_align_bad = k9y_align_bad + 1;
```

逐**出队字**比对（`k9y_word` 是窗口内第几次取字），分母 = 640×480/2 的一半窗口 = **153,600**。

实测分母非零且全部通过（`tb_pix_reader_vga.log:41-51`）：

```
:41 K9Y_TIER t=0 off_y=120 win_h=240 first_panel=120 first_src=120 last_panel=359 last_src=359 rows=240 align_bad=0 empty=0/307200 uf=0
:43 K9Y_TIER t=1 off_y=90  win_h=300 first_panel=90  first_src=90  last_panel=389 last_src=389 rows=300 align_bad=0 empty=0/307200 uf=0
:45 K9Y_TIER t=2 off_y=60  win_h=360 first_panel=60  first_src=60  last_panel=419 last_src=419 rows=360 align_bad=0 empty=0/307200 uf=0
:47 K9Y_TIER t=3 off_y=30  win_h=420 first_panel=30  first_src=30  last_panel=449 last_src=449 rows=420 align_bad=0 empty=0/307200 uf=0
:49 K9Y_TIER t=4 off_y=0   win_h=480 first_panel=0   first_src=0   last_panel=479 last_src=479 rows=480 align_bad=0 empty=0/307200 uf=0
:51 K9Y_HORIZ: off_y=120 win_w=320 first_panel=120 first_src=120 last_src=359 rows=240 align_bad=0 empty=0/153600 uf=0
```

`empty=0/307200` 这一项尤其重要：它说明窗口内**没有一次空拍**（`dut.fifo_rd_empty` 从未为高），所以 307,200 次比对是真的逐像素比了，不是「大部分拍都没数据所以没比」。

### 3.3 首/末行反查不复用 DUT 表达式

tb `:382-398`（水平档）/ `:405-422`（满屏档）：只在 `k9y_word == 0` 且 `active_y` 是窗口首行或末行时，用

```verilog
for (k9y_li = 0; k9y_li < (LINES + 1); k9y_li = k9y_li + 1)
  if (pix_rgb565 === expected_pixel(0, k9y_li)) ...
```

把**实际输出的像素**反查成源行号，记 `k9y_first_src` / `k9y_last_src`。反查走 `expected_pixel(0, k9y_li)`，同样不用 DUT 的 `src_y` 或任何 DUT 内部信号（`:360-366` 注释明写「反查不许复用 DUT 表达式，一律走 expected_pixel」）。

> 这一点值得单独记：tb 里确实有层级引用 `dut.fifo_rd_empty`（`:370`），但那是**只读观测**（统计空拍），不参与任何判据的期望值计算。

### 3.4 五档与水平档的判据强度

五档（`k9y_tiers`，tb `:667-718`）把 `win_w = PIX_PER_LINE`（满屏宽度）、`win_off_x = 0`，于是 `h_ident = 1`、`use_key9 = 0`，走**逐像素通路**（不经过水平降采样 DDA）—— 这使纵向判据与水平机制解耦，是本卡最强的一条设计。

水平档（`k9y_horiz_case`，tb `:721-760`）故意把 `win_w` 收窄到半屏（`PIX_PER_LINE / 2`）、`win_off_x = PIX_PER_LINE / 4`，专门验证「水平 DDA 的取 4 停 1 节奏不影响行推进」—— 对应断言文案「horizontal window keeps the horizontal DDA from shifting the row origin」。

20 帧浸泡（`k9y_soak`，tb `:767-815`）实测 `K9Y_SOAK: frames=20 drift=0 uf_frames=0 uf_edges=0` ⇒ 连续 20 帧首行都钉在 `win_off_y`，无漂移、无粘滞欠载。

---

## §4 问三：反证 6 条逐条判读 —— 有没有「碰巧变红」

### 4.1 六条红的清单（`%TEMP%/t31_refute/work_lib/transcript`）

变异：`chk(k9y_first_src == k9y_off,` → `chk(k9y_first_src == (k9y_off + 1),`，命中 2 处（五档循环内 1 处 + 水平档 1 处，但五档循环跑 5 次，所以共触发 6 条）。

```
t=0 off_y=2 win_h=4 first_panel=2 first_src=2 last_panel=5 last_src=5 rows=4 align_bad=0 empty=0/512 uf=0
FAIL: first window row shows source row win_off_y (centered crop)
t=1 off_y=1 win_h=5 first_panel=1 first_src=1 last_panel=5 last_src=5 rows=5 align_bad=0 empty=0/512 uf=0
FAIL: first window row shows source row win_off_y (centered crop)
t=2 off_y=1 win_h=6 first_panel=1 first_src=1 last_panel=6 last_src=6 rows=6 align_bad=0 empty=0/512 uf=0
FAIL: first window row shows source row win_off_y (centered crop)
t=3 off_y=0 win_h=7 first_panel=0 first_src=0 last_panel=6 last_src=6 rows=7 align_bad=0 empty=0/512 uf=0
FAIL: first window row shows source row win_off_y (centered crop)
t=4 off_y=0 win_h=8 first_panel=0 first_src=0 last_panel=7 last_src=7 rows=8 align_bad=0 empty=0/512 uf=0
FAIL: first window row shows source row win_off_y (centered crop)
K9Y_HORIZ: off_y=2 win_w=32 first_panel=2 first_src=2 last_src=5 rows=4 align_bad=0 empty=0/256 uf=0
FAIL: horizontal window keeps the horizontal DDA from shifting the row origin
```

收尾 `# SUMMARY: checks=542 errors=6 cases=39 geometry=64x8` / `# FAILED: tb_pix_reader errors=6`。

六条 = 五档各一条 + 水平档一条，**与变异位置一一对应，没有多也没有少**。

### 4.2 逐条排除「碰巧变红」——四条独立证据

**证据 1：档间计数器全部清零，没有跨档残留。**
tb `:686-697`（五档每轮开头）把 12 个计数器全部重置，其中 `k9y_first_panel = -1; k9y_first_src = -1; k9y_last_panel = -1; k9y_last_src = -1;`。水平档 `:732-742` 同样清零。
⇒ 每档的 `first_src` 是本档独立测量值，不是上一档的遗留。档 0 读到 2、档 1 读到 1、档 3 读到 0，各不相同，正说明是各档独立测出来的。

**证据 2：同档其余五条断言实测全绿 —— 不存在「被别的条件先红掩盖」。**
每档六条断言（tb `:705-715`）分别用六个不同计数器：

| 断言（tb 行号） | 用到的计数器 | 实测值 vs 期望 |
|---|---|---|
| `:705` first window row is the panel row win_off_y | `k9y_first_panel` | 2/1/1/0/0 vs off_y 2/1/1/0/0 → **绿** |
| **`:707` first window row shows source row win_off_y** | `k9y_first_src` | 2/1/1/0/0 vs 变异后期望 3/2/2/1/1 → **红** |
| `:709` last window row shows source row win_off_y+win_h-1 | `k9y_last_src` | 5/5/6/6/7 vs 5/5/6/6/7 → **绿** |
| `:711` every window row shows its own source row | `k9y_align_bad` | 全 0 → **绿** |
| `:713` checked window covers exactly win_h rows | `k9y_rows` | 4/5/6/7/8 vs win_h 4/5/6/7/8 → **绿** |
| `:714` no sticky underflow | `k9y_underflow_edges` | 全 0 → **绿** |

captain 特别点到的两档，答案是否定的（没有被掩盖）：
- **档 0（真几何 `win_h=240` / 小几何 `win_h=4`）**：`rows=4` 与 `win_h=4` 相等 ⇒ 行数断言绿，红只能来自 `:707`。
- **档 3（真几何 `win_h=420` / 小几何 `win_h=7`）**：`rows=7` 与 `win_h=7` 相等 ⇒ 行数断言绿；`off_y=0` 时变异后期望为 1 而实测 0 ⇒ 首行断言独立变红。

**证据 3：`k9y_first_src` 只写一次、且写入条件与期望值无关。**
tb `:388-391`（水平档）/ `:411-414`（满屏档）的赋值带 `k9y_first_src < 0` 守卫 ⇒ 整个用例只记第一次反查结果。反查命中条件是 `pix_rgb565 === expected_pixel(0, k9y_li)`，与 `k9y_off` 这个期望值没有关系。
⇒ 变异只改「比较的右边」，不改「测量方式」，红是被比出来的，不是测量被干扰。

**证据 4：反证副本除那两处变异外与工作树逐字相同（变异是唯一变量）。**
把 `%TEMP%/t31_refute/tb_pix_reader.v` 里的 `chk(k9y_first_src == (k9y_off + 1),` 反向替换回 `chk(k9y_first_src == k9y_off,`（命中 2 处），得到 39,560 B；与工作树 `sim/testbench/tb_pix_reader.v`（40,430 B / 870 行）逐行 `Compare-Object` **差异 0 行**。
（字节差 39,560 vs 40,430 来自 BOM 与行尾编码，行内容无差异。）

### 4.3 注入前后双计数（项目硬规矩）

`%TEMP%/t31_refute/mutate.py`（528 B）全文要点：

```python
old = "chk(k9y_first_src == k9y_off,"
new = "chk(k9y_first_src == (k9y_off + 1),"
n = t.count(old)
print("MUTATION-EXPECTED-BEFORE=%d" % n)
assert n == 2, n
t = t.replace(old, new)
assert t.count(new) == 2
assert t.count(old) == 0
```

`assert n == 2` 保证「匹配 0 行必须报错退出、不许默默跳过」；注入后还断言新串恰好 2 处、旧串 0 处。⇒ 这次反证**不是**「什么也没注入」的那种假 PASS。

---

## §5 第四问：供给节奏覆盖口径（本卡需要给出的判断）

### 5.1 结论

**`未在真实供给节奏下验证` 这个说法不成立，应改写。** 理由：tb 的**读通路确实经过真例化的 `framebuf_arbiter`**，`RD_GROUP_CYCLES=13` 的读组节奏是生效的；只有**写侧**用了行为模型夹具。

### 5.2 事实链

tb `:170-182` 真例化仲裁器，并把读侧信号全部接到 DUT：

```verilog
framebuf_arbiter #(.FRAME_WORDS(FRAME_WORDS), .WR_STARVE_LIMIT(32)) u_arb (
  ... .rd_req(rd_req), .rd_data(rd_data), .rd_valid(rd_valid), .rd_ack(rd_ack),
      .rd_restart(rd_restart), .rd_base(rd_base), .rd_idle(rd_idle),
      .rd_restart_done(rd_restart_done) ...
);
```

`framebuf_arbiter.v`（269 行）`:18 parameter RD_GROUP_CYCLES = 13, // 相邻读组首的最小周期数`，`:9` 头注「APUG011 的间歇读组首至少相隔 13 拍；12 拍间隔已在真核复现漏 ACT」；`:135-136` 的 `rd_group_wait` 递减就是这条节奏的实现。

⇒ 仲裁器不是 tb 里的空壳或旁路，`pix_reader` 的每一个读请求都要过 `rd_group_wait == 0` 这道闸。

**写侧**才是夹具：`:231 u_ctrl.u_model.mem[address] = word_data;` 直接预置 SDRAM 行为模型。而 `sdram_ctrl_wrap.v` 的 `:127 \`ifdef SDRAM_SIM_MODEL` 分支例化 `sdram_behavior_model`（`:133-135`），`SDRAM_SIM_MODEL` 由编译命令行给出（回归脚本统一 `+define+SDRAM_SIM_MODEL`）。

### 5.3 为什么纸面推算不是「缺口」而是「解释」

实现者写了「1.56% 逐行缺口 + 34.6% 整帧富余（消隐期 `P_DRAIN` 补水）」的推算并标「未经仿真」。**这份推算不是必需的证据，因为实测已经把结论给出来了**：

- `tb_pix_reader_vga.log:41-49` 五档全部 `empty=0/307200` ⇒ 真实几何 + 真实读组节奏下，窗口内**零空拍**，供给没有缺口。
- `K9_HALF in_cycles=153600 out_cycles=153600` / `K9_FRAC in_cycles=230400 out_cycles=76800`（`:36` / `:39`）⇒ 取字与出字的周期账在 320 与 480 两档都对得上。
- `K9Y_SOAK: frames=20 drift=0 uf_frames=0 uf_edges=0` ⇒ 20 帧连续无粘滞欠载。

⇒ 纸面推算的角色是「解释为什么够」，不是「替代缺失的仿真」。

### 5.4 建议写进交付文档的口径（可直接引用）

> Key9 纵向 1:1 裁剪的供给余量已由 `tb_pix_reader` 的 `-FullVga` 用例在真实几何（640×480、`FIFO_AW=9`、`LEVEL_HI=384`）下实测覆盖：读通路经过真例化的 `framebuf_arbiter`（`RD_GROUP_CYCLES=13`，间歇读组首保护生效），五档窗口内空拍计数均为 `0/307200`，20 帧浸泡 `drift=0 / uf_frames=0 / uf_edges=0`。未覆盖的是 SDRAM 加密真核与 BMP→`img_loader` 的写入路径，属 `-RealCore` 那一趟的验证范围，与本卡结论无关。

### 5.5 但有一条必须如实标注（见 §7 第 1 条）

`sdram_behavior_model` 的读延迟与真核是否一致，本卡无法从现有数据确认。

---

## §6 低危观察（不影响 verdict）

1. **tb 里有三个声明后零使用的变量**（T31 新段遗留）：`k9y_probe_done`（`:100`）、`k9y_rows_bad`（`:101`）、`k9y_row`（`:93`），全文各只出现 1 次（即声明行本身）。不影响判据有效性，属可清理项。
2. **两份 SUMMARY 数字口径不同，引用时必须带几何与 STRESS 开关**：

| 日志 | 几何 / 开关 | SUMMARY |
|---|---|---|
| `sim/_t31_d/transcript` | 默认小几何 64×8，`STRESS=1` | `checks=542 errors=0 cases=39` |
| `reports/s6_validation/tb_pix_reader_vga.log` | `-FullVga` 640×480，`STRESS=0` | `checks=498 errors=0 cases=36` |
| `sim/_t31_probe/transcript`（改动前） | `-FullVga`，tb 149 行版 | `checks=166 errors=0 cases=11` |

差 3 个 FRAME / 2 个 CASE 正好是 `STRESS=0` 关掉的那一段（`concurrent_masked_writes` / `underflow_recovery` / `system_reset_recovery`）。**任务卡的 `542 / 39` 是小几何那一趟，不是 `-FullVga` 那一趟** —— 两套数字都对，但混用会算错。
3. **`-FullVga` 那趟有两条 vsim 端口连接告警**（`tb_pix_reader.v(156)` 的 `u_vtg` 缺 `vblank`、`(169)` 的 `u_ctrl` 缺 `refresh_error`，`vsim-3017` + `vsim-3722`）。这两条告警在本卡改动前的老基线（`sim/_t31_probe/transcript`）里就存在，不是 t31 引入；且被测的 `pix_reader` 端口是接全的（`u_arb` 与 `dut` 无 missing 告警）。属 tb 里两个辅助模型的既有未接端口。
4. **`%TEMP%/t31_refute/` 与 `%TEMP%/t31_probe/` 未清理**（前者 39,572 B 变异体 + work 库，后者空目录）。本卡收尾时已删除（见 §8.3）。
5. **`sim/` 下留了三个 t31 工作目录**（`sim/_t31_probe`、`sim/_t31_d`、`sim/_t31_v`）与一个辅助脚本 `sim/_t31_fix_le.py`。它们都在 `sim/` 内、不被任何回归脚本引用，属可清理项；本卡不删（在 outOfScope 的 `sim/` 里），列为后续清理建议。
6. **`sim/_t31_fix_le.py` 记录了一条工具假阳性**：tb 里 `for (k9y_li = 0; k9y_li <= LINES; ...)` 会被 `scripts/lint_verilog.py` 判成非阻塞赋值（词法判据把 `<= 数字` 当 `<=` 运算符），因此改写成 `k9y_li < (LINES + 1)`。这与 t25 的 `if (mismatch <= 8)` 是同一类假阳性；**绕过写法可以，但这条假阳性本身应在工具侧记录**。

---

## §7 我无法从现有数据确认的

1. **`sdram_behavior_model` 的读延迟是否与 SDRAM 加密真核一致。** 现有 `-FullVga` 那趟走的是 `+define+SDRAM_SIM_MODEL` 的行为模型；真核要在 `-RealCore` 那趟（Questa + `sdr_as_ram.enc.v` 等四个加密件）才跑到。若真核读延迟更长，`empty=0/307200` 这个结论不必然迁移到真核上。**这不影响「纵向对齐」这条结论**（对齐由行推进决定，与读延迟无关），但影响「供给零空拍」这条。
2. **`-FullVga` 那趟是 `STRESS=0`。** 也就是说「真实几何 + 并发写压力 + 欠载恢复」这三者没有同时跑过：小几何那趟有 `STRESS=1`，真几何那趟没有。两者的交集（真几何下的并发写/欠载恢复）未被覆盖。
3. **`tb_pix_reader_vga.log` 是不是当前工作树代码跑出来的，我只能间接确认。** 该日志 mtime 12:03:29 晚于 tb 的 10:48:12 与 DUT 的 09:51:57，且日志里的行号（`$finish` 在 `tb_pix_reader.v(860)`）与工作树 870 行版一致；但我没有独立的源哈希随日志留档。**若需要强证据，应在回归脚本里像 `run_image_regression.ps1` 那样把源 SHA256 写进 result.json。**
4. **我没有重跑 `-FullVga` 那一趟。** 本卡是只读复核，重跑会写 `sim/` 或 `reports/`，超出 inScope；五档数字是我从既有日志回读的（§3.2 已贴原文）。
5. **`align_bad` 是否覆盖「窗口外不该出字」**。它只统计窗口内的比对（`:376` / `:423` 的 `in_win_x` 条件），窗口外是否漏字由 `k9y_rows`（行数）与 `:290` 的整帧 `pixels_checked` 断言间接覆盖，但没有一条断言直接说「窗口外零输出」。属判据的边界，不是缺陷。
6. **`k9y_empty_cycles` 的统计口径**是「`check_k9y && de` 期间 `dut.fifo_rd_empty` 为高的拍数」，不含消隐期。所以 `empty=0` 只说明可见区内无空拍，不说明消隐期也满。

---

## §8 校验命令、结果与「零改动」证据

### 8.1 任务卡要求的两条 verify

```
> python scripts\lint_verilog.py rtl/storage
检查文件数: 18
E0(文件损坏): 0    E1(赋值混用): 0    E2(多驱动): 0
结论: 通过（无损坏 / 无混用赋值 / 无多驱动）
LINT_EXIT=0
```

```
> python scripts\check_port_names.py
self-check: PASS
modules parsed: 69  instantiations scanned: 40
*** NO_SUCH_PORT = 0 (全部端口名都存在) ***
    UNKNOWN_MODULE = 2（其中预期 2：IP/加密件；意外 0）
    UNCONNECTED    = 0（其中预期未接 0；意外未接 0）
    EMPTY_CONN     = 9 个实例 / 22 个端口（其中有意空连接 9；意外空连接 0）
RESULT: PASS
PORTNAME_EXIT=0
```

> `lint_verilog.py` 只查 always 块级多驱动、不查 `assign` 级多驱动与重复声明，且对 `<= 数字` 有假阳性（§6 第 6 条）。所以「lint 全 0」不能单独当「能编译」的证据 —— 本卡的编译证据是 `_t31_d` / `tb_pix_reader_vga.log` 那几趟真实 `vlog` + `vsim`。

### 8.2 复核前后两文件 MD5（零改动证据）

| 文件 | 复核前 MD5 | 复核后 MD5 | 判定 |
|---|---|---|---|
| `rtl/storage/pix_reader.v` | `3CAD6F6BE9F59B1FB1376AD5945350E5` | `3CAD6F6BE9F59B1FB1376AD5945350E5` | 未变 |
| `sim/testbench/tb_pix_reader.v` | `1385CE5F0FC13DF5ACDAE864FEA37CB0` | `1385CE5F0FC13DF5ACDAE864FEA37CB0` | 未变 |

`git status --porcelain` 在复核前后无新增项（本卡的唯一新增文件是 `reports/plan_v2/T31_REVIEW.md`，在 `reports/` 下，不在 `rtl/` 或 `sim/`）。

### 8.3 `%TEMP%` 清理

删除前确认过路径与内容：

```
%TEMP%/t31_refute/  -> mutate.py(528 B) + tb_pix_reader.v(39,572 B, 变异体) + work_lib/
%TEMP%/t31_probe/   -> 空目录
```

已删除。删除前已把变异体反向替换验证为「与工作树逐行 0 差异」（§4.2 证据 4），因此不丢失任何独有信息。

---

## §9 复核结论与建议

**verdict: pass。** t31 的改向（从「改 RTL」改成「补证据 + 钉断言」）成立：

- 「纵向 1:1 天然对齐」在结构上有依据（`win_off_y` / `win_h` 在 DUT 逻辑里零消费者，纵向只由行末推进决定），不是为省事找的理由。
- 补的断言确实能抓错位：夹具独立、逐像素/逐字比对、分母非零、反证六条一一对应且无「碰巧变红」。
- 证据链完整：五档真几何数字可从原始日志逐字回读，反证副本可完整还原。

三条建议（都不阻塞本卡）：

1. 交付文档里关于供给余量的表述按 **§5.4** 那句改写；`未在真实供给节奏下验证` 这个说法不要再用。
2. 引用 `tb_pix_reader` 的 checks/cases 数字时**必须带几何与 STRESS 开关**（§6 第 2 条），否则 `542/39` 与 `498/36` 会互相打脸。
3. 把「回归日志应随源 SHA256 留档」补进回归脚本（§7 第 3 条）—— 目前只能靠 mtime 间接判断日志与代码的对应关系。
