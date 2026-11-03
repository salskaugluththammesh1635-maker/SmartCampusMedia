# t26 fat32_reader 终态重入修复 —— 实现说明与验收数据

> 本文只记录已经写进 RTL 的东西及其验收数据，供 t9 回归、t10 终审、答辩材料直接引用。
> 全部数值都是本机实测（ModelSim ASE + 本工程既有回归脚本），不是估算。
> 记账日：2026-11-02。

---

## 1. Bug 精确描述

### 1.1 症状

`rtl/storage/fat32_reader.v` 的两个终态 `S_DONE`（`:448`）与 `S_FAIL`（`:464`）**都不看 `start`、也不改 `st`**。改前原文（`:447-475`，含注释）：

```verilog
// 终态自锁: 成功/失败都保持到下次 start 或整板复位
S_DONE: begin
    busy  <= 1'b0;
    found <= 1'b1;
end
S_FAIL: begin
    busy <= 1'b0;
    fail <= 1'b1;
end
default: st <= S_IDLE;
```

⇒ 一旦进入终态，唯一的出路是**整板复位**（`:238` 复位段）或不可达的 `default` 分支。

### 1.2 证据：全文件只有一处消费 `start`

改前 `start` 在 `rtl/storage/fat32_reader.v` 共出现 6 次，其中只有 **1 处是逻辑使用**：

| 行号 | 性质 |
|---|---|
| `:37`、`:46` | 文件头注释 |
| `:104` | 端口声明 `input wire start,` |
| `:144` | localparam 注释 |
| `:234` | always 块小标题注释 |
| **`:269`** | **唯一逻辑使用点**：`S_IDLE: if (start) begin` |

⇒ 只要不在 `S_IDLE`，`start` 就是一个被彻底忽略的输入。

### 1.3 为什么只有 `wav_stream_player` 中招

三处例化的复位策略不同 —— 这是一张「谁有兜底、谁没有」的对照表：

| 消费者 | 例化位置 | 复位来源 | 每轮是否复位 | 结果 |
|---|---|---|---|---|
| `gallery_probe` | `rtl/storage/gallery_probe.v:294` | `f32_rst_n = rst_n && !rst_req` | **是**（自杀式复位，每轮拉低一次） | 侥幸不中招 |
| `img_loader` | `rtl/storage/img_loader.v:567` | `loader_rst_pix`（装载窗口内复位） | **是** | 侥幸不中招 |
| `wav_stream_player` | `rtl/audio/wav_stream_player.v:285` | `.rst_n(rst_n)` | **否**（只在整板上电复位） | **中招** |

`wav_stream_player.v:712` 在 `W_IDLE` 里发 `fat_start <= 1'b1;`（单拍），本次修复前该脉冲在第二次换源时被终态吞掉。

### 1.4 真实症状比「报 E_BLKTMO」更糟：静默重播上一个文件

任务书原文预期是「等到 `BLK_TIMEOUT` 报 `E_BLKTMO`」。**实测不是。** 改前 TB 输出（`sim\work_t26\s_old_wav.log`）：

```
---- D02: source swap BGM -> NARR without reset ----
     after BGM: clu=4 size=1044 samples=500
     after NARR: clu=4 size=1044 samples=500 err=0      ← 又播了一遍 BGM，err 还是 0
```

机制：`fat_start` 被吞后 `fat_found` 保持上一轮的 1，`wav_stream_player.v:717` 的 `W_FATLOC` **进态即采电平**，于是直接锁存陈旧的 `wav_cluster=4 / wav_size=1044` 并跳过定位，把 BGM 重播一遍，`err_code` 全程为 0。

用户感知是「切了模式但音乐没变」——**比报错难定位得多**，因为没有任何错误码可以追。`E_BLKTMO` 只在 wav 侧走 `W_CHKSPC`/`W_FATRD` 路径（真正去读块）时才会触发，定位阶段不触发。

---

## 2. 修法：B1 → B4 的演进

任务书指定的是 B1，实测**不够**。下面按实测顺序记录。

### 2.1 B1（任务书原方案）—— 不够

```verilog
S_DONE: begin
    busy  <= 1'b0;
    if (start) begin
        st         <= S_IDLE;
        start_seen <= 1'b1;      // start 是单拍脉冲，需锁存
    end else begin
        found <= 1'b1;
    end
end
```

| TB | 结果 |
|---|---|
| `tb_fat32_reader` | **62 PASS / 0 FAIL** ✅ |
| `tb_wav_stream_player` | **4 FAIL** ❌ 症状与改前一致（静默重播） |

### 2.2 时序探针：B1 为什么不够（本卡核心证据）

用 `sim\work_t26\probe_wav.v`（`tb_wav_stream_player.v` 副本 + DBG 监视器）抓 D02 换源：

```
t=130283180000  wst=1(W_FATLOC) fst=4(S_DONE) fat_start=1 found=1   ← wav 在 fat_start 拉高的同一拍就在采 fat_found
t=130283220000  wst=2(W_CHKSPC) fst=0(S_IDLE)  fat_start=0 found=1   ← 下一拍 wav 已跳过 W_FATLOC
```

`wav_stream_player.v:717` 的 `W_FATLOC` 是「进态即采电平」；而 `found` 由寄存器驱动，非阻塞赋值要到下一个时钟沿之后才生效 —— **永远慢一拍**。

⇒ 任务书「坑 2」里担心的方向（清太快 → 调用方采到 0）在这个时序下不存在。真实风险相反：**不清 `found` → 调用方采到上一轮的 1**。这一条已由 captain 在 2026-11-02 按实测证据更正契约。

### 2.3 B2（错误写法，留作反面教材）

在同一 `always` 块里顺序写两条非阻塞赋值：

```verilog
found <= 1'b1;      // 被下面覆盖
found <= 1'b0;
```

⇒ 非阻塞赋值后者覆盖前者，`found` 恒为 0 → **17 errors**。同一 `always` 块里对同一变量两次非阻塞赋值必须改成 `if/else` 互斥。

### 2.4 B3（if/else 同拍清）—— 仍不够

```verilog
if (start) found <= 1'b0; else found <= 1'b1;
```

`found` 仍是寄存器输出，清除照样慢一拍 → fat 62/0 ✅、wav 仍 4 FAIL ❌。

### 2.5 B4（最终采用）—— 零延迟电平屏蔽

`found` / `fail` 从 `output reg` 改为 `output wire`，内部改由 `found_q` / `fail_q` 承载，输出端做组合屏蔽：

```verilog
// rtl/storage/fat32_reader.v，位于 assign out_spc = spc; 之后
wire term_reentry = start && ((st == S_DONE) || (st == S_FAIL));
assign found = found_q && !term_reentry;   // [t26] 电平屏蔽
assign fail  = fail_q  && !term_reentry;   // [t26] 电平屏蔽
```

效果：`start` 拉高的**那一拍**，`found` 立即变 0，调用方不可能采到旧值。且遵守任务书「坑 2」：**终态不清零** `found_q`/`fail_q`（清零职责仍只在 `S_IDLE`）。

| TB | 结果 |
|---|---|
| `tb_fat32_reader` | **64 PASS / 0 FAIL** ✅（62 + 监视器 2 条） |
| `tb_wav_stream_player` | **46 PASS / 0 FAIL** ✅（原 38 + 新增 8） |

### 2.6 为什么 `reg` 改 `wire` 对三个消费者不可见

三者全都只读电平、不做过程赋值：

- `wav_stream_player.v:286` `.fat_found(fat_found)` / `.fat_fail(fat_fail)`
- `gallery_probe.v:294` 同款连线
- `img_loader.v:567` 同款连线

实测验证：`run_image_regression.ps1` → `img_scaler` / `image_player` / `image_player_scaled` 三个 `passed=True`，exit=0（`sim\work_t26\rep_img`）。

---

## 3. 改动清单（`rtl/storage/fat32_reader.v`，42,276 B → 45,090 B）

### 3.1 端口类型

```
:119  output wire        found,          // 电平: 定位成功（保持）   ← [t26] 原 output reg
:120  output wire        fail,           // 电平: 定位失败（保持）   ← [t26] 原 output reg
```

### 3.2 新增内部寄存器（`:157-166` 附近）

```verilog
reg start_seen;        // [t26] 终态收到 start 后锁存，下一拍在 S_IDLE 完成启动
reg found_q;           // [t26] 内部结果寄存器（对外经 term_reentry 屏蔽）
reg fail_q;            // [t26] 同上
```

### 3.3 `S_IDLE` 启动条件与清零（`:288-296`）

```verilog
S_IDLE: begin
    if (start || start_seen) begin    // [t26] 原为 if (start)
        start_seen <= 1'b0;           // [t26] 启动这拍即清，避免残留到下一轮
        found_q  <= 1'b0;             // [t26] 原 found <= 1'b0
        fail_q   <= 1'b0;             // [t26] 原 fail  <= 1'b0
        err_code <= 4'd0;
        ...
```

**关于 captain 关心的漏洞（a）—— 「`S_IDLE` 的 `found_q` 清零没被破坏」**：
`term_reentry` 只覆盖 `st` 处于终态那一拍，第 N+1 拍 `st` 已回 `S_IDLE`、`term_reentry` 落回 0，此时 `found = found_q`。若 `found_q` 还留着上一轮的 1，调用方会采到旧值。
时序推演：第 N 拍 `start=1 && st==S_DONE` → `term_reentry=1` → `found=0`，**同一拍 `found_q <= 1'b0` 已提交**（见 §3.4 的 `if (start)` 分支），到第 N+1 拍 `found_q` 已经是 0，因此第 N+1 拍 `found = found_q = 0`。⇒ **没有「陈旧 1 泄漏」的一拍窗口**。
这条不是靠 tb 全绿推出来的，而是由 §4.2 的逐拍监视器在**改前 RTL 上抓到 40001 次泄漏、在改后 RTL 上为 0** 双向证明的。

### 3.4 两个终态（`:448-475`）

```verilog
// 终态自锁: 成功/失败都保持到下次 start 或整板复位
S_DONE: begin
    busy  <= 1'b0;
    // [t26] S_DONE 收到 start: 回 S_IDLE 重定位。
    //   结果寄存器必须**同拍**拉低：调用方（wav_stream_player）
    //   在 start 之后立刻采 fat_found，若保持上一轮的 1，
    //   它会锁存到陈旧的簇号/长度后直接跳过定位。
    //   用 if/else 互斥——同一 always 块里两次对同一变量赋非阻塞值
    //   会后者覆盖前者，写成顺序两条语句是错的。
    if (start) begin
        found_q    <= 1'b0;   // [t26] 同拍作废旧结果
        st         <= S_IDLE;
        start_seen <= 1'b1;
    end else begin
        found_q <= 1'b1;
    end
end
S_FAIL: begin
    busy <= 1'b0;
    // [t26] S_FAIL 收到 start: 回 S_IDLE 重定位。
    //   fail 同拍拉低，理由同 S_DONE（调用方立刻采电平）。
    if (start) begin
        fail_q     <= 1'b0;   // [t26] 同拍作废旧结果
        st         <= S_IDLE;
        start_seen <= 1'b1;
    end else begin
        fail_q <= 1'b1;
    end
end
```

`busy` 仍为 0（任务书要求「终态检查 start 且 st 只用寄存器同步推进」）—— 没有任何组合逻辑驱动 `st`。

### 3.5 关于 `start` 宽度（任务书「坑 1」的核实结果）

`wav_stream_player.v` 里 `fat_start` 全文件 5 处：`:234` 声明、`:286` 端口连接、`:386`/`:412` 默认与复位清零、**`:712 fat_start <= 1'b1;`**。`:412` 属于「默认单拍信号归零」段，每拍归零 ⇒ **`fat_start` 是标准单拍脉冲**，因此采用带 `start_seen` 锁存的方案（任务书方案 B），只在终态加 `st <= S_IDLE` 一行是不够的。

---

## 4. 双向反证

### 4.1 反证前的准备：修正 TB 自身的 bug

`sim/testbench/tb_wav_stream_player.v:657` 在我最初的注入里写成了 **12 字节**：

```verilog
// 错（12 字节，88 位只装得下 11 字节）
NAME_NARR = {8'h56,8'h41,8'h57,8'h20,8'h20,8'h20,8'h20,8'h20,8'h52,8'h52,8'h41,8'h4E};
```

`reg [87:0]` 只有 11 字节，超宽字面量把最高字节 `'V'` 截掉，实际传入 `A, W, sp, sp, sp, sp, R, R, A, N` —— **搜不到 NARR.WAV 是必然的**。修正后（去掉一个 `8'h20`，与 `NAME_BGM`/`NAME_NONE` 同款 11 字节）：

```verilog
// 对（11 字节）
NAME_NARR = {8'h56,8'h41,8'h57,8'h20,8'h20,8'h20,8'h20,8'h52,8'h52,8'h41,8'h4E};
```

**这个 bug 是本卡最有价值的副产品，必须写进 t9 盲区清单**：
它从写出来到被发现，`tb_wav_stream_player` 的 NARR 用例**从来没有真正测过 NARR**。而它能潜伏的原因不是「一直在绿」而是「**一直在红**」—— 红色被归因为 RTL 缺陷，于是没人怀疑测试本身。

> **假红与假绿并列**：长期失败的用例同样失去证明力 —— 反正它是红的，改什么都红。
> 我们在本工程里一直只防「假绿」，「假红」是这次才暴露出来的第二类盲区。

### 4.2 双向反证的可执行判据

> **RTL 不修时 TB 必须红，RTL 修好后 TB 必须绿。任一方向不成立，都得先怀疑 TB 自身。**

这是本工程第一次把「双向反证」写成可执行判据。之前只有单向（「注入错误必须变红」），本轮的经历（B4 让 `err` 从 0 变 6，我先怀疑 RTL，实际是自己的 `NAME_NARR` 打包错）正好补上了另一半。

### 4.3 四个数（同一套 TB，只换 RTL）

命令范式（`sim\work_t26\`，`$ms='D:\Quartus_APP\modelsim_ase\win32aloem'`）：

```powershell
cd sim\work_t26
& "$ms\vlib.exe" work
& "$ms\vlog.exe" -quiet ..\..\rtl\storage\fat32_reader.v ..\..\sim\testbench\tb_fat32_reader.v
& "$ms\vsim.exe" -c -quiet -onfinish stop -do "run -all; quit -f -code 0" work.tb_fat32_reader
& "$ms\vlog.exe" -quiet ..\..\rtl\audio\wav_stream_player.v ..\..\rtl\storage\fat32_reader.v ..\..\sim\testbench\tb_wav_stream_player.v
& "$ms\vsim.exe" -c -quiet -onfinish stop -do "run -all; quit -f -code 0" work.tb_wav_stream_player
```

切换 RTL 版本：`python sim\work_t26\patch_rtl.py restore`（回到改前 42,276 B）/ `python sim\work_t26\patch_rtl.py b4`（注入 B4 45,090 B）。

| RTL 版本 | `tb_fat32_reader` | `tb_wav_stream_player` |
|---|---|---|
| **改前**（42,276 B） | 57 PASS / **6 FAIL** ❌ | 42 PASS / **4 FAIL** ❌ |
| **改后 B4**（45,090 B） | **64 PASS / 0 FAIL** ✅ | **46 PASS / 0 FAIL** ✅ |

改前 6 条红（`# === tb_fat32_reader done, errors = 6 ===`）：

```
FAIL: T27b second start restarts the locator (S_DONE re-entrant)
FAIL: T27d round2 relocates IMG002 (clu 6, not the stale 5)
FAIL: T28b second start restarts the locator (S_FAIL re-entrant)
FAIL: T28c round2 reports found and clears fail
FAIL: T28d round2 finds IMG001 (clu 5)
FAIL: T28e round2 err_code cleared to 0
```

改前 4 条红（`# === tb_wav_stream_player: pass=42 fail=4 ===`）：`D02e` / `D02f` / `D02g` / `D02h`，伴随 `after NARR: clu=4 size=1044 samples=500 err=0`。

### 4.4 逐拍监视器：证明「没有陈旧结果泄漏」

`tb_fat32_reader.v` 新增（`patch_spy.py` 注入）：

```verilog
integer arm_spy, spy_hi_cnt, spy_viol_cnt, spy_seen;
reg [31:0] spy_expect_clu;

always @(negedge clk) begin
    if (arm_spy) begin
        if (start === 1'b1) spy_seen = 1;
        if (spy_seen && (found === 1'b1)) begin
            spy_hi_cnt = spy_hi_cnt + 1;
            if (first_cluster !== spy_expect_clu) begin
                spy_viol_cnt = spy_viol_cnt + 1;
                ...
            end
        end
    end
end
```

判据用 `first_cluster` 而不是 `out_data_begin`：IMG001 与 IMG002 同在一个数据区，`out_data_begin` 两轮相同，区分不出新旧；`first_cluster` 才是本轮定位的产物。

**采样时机有个坑**：`fire_start` 在 `negedge` 执行 `start = 1'b1`，监视器也在 `negedge` 采样，两者同刻抢跑。若监视器先跑会看到 `start` 还没拉高、`term_reentry=0`、`found` 仍是上一轮的 1，把「启动前」误判成「泄漏」（我第一次跑就吃到 `stale_violations=1`）。修法：先等观测到 `start=1`（`spy_seen` 一次性置位）才开始判定。

双向结果：

| RTL | `found_high_cycles` | `stale_violations` |
|---|---|---|
| **改前** | 40001 | **40001** ❌（每拍都是陈旧值，`first_cluster=5` 对 expected 6） |
| **改后 B4** | 1 | **0** ✅ |

配套两条断言：`T27f spy observed found=1 (monitor is live)`（**前提断言**：监视器一次都没看到 `found=1` 时 T27g 会因恒真而假绿）与 `T27g no cycle leaked a stale result`。

---

## 5. 回归与门禁

| 项 | 命令 | 结果 |
|---|---|---|
| lint | `python scripts\lint_verilog.py rtl` | `检查文件数: 67` / `E0: 0  E1: 0  E2: 0` / `结论: 通过（无损坏 / 无混用赋值 / 无多驱动）`，exit=0 |
| 端口名 | `python scripts\check_port_names.py` | `NO_SUCH_PORT = 0`；`UNKNOWN_MODULE = 2`（预期 2：`EG_PHY_SDRAM_2M_32` / `hdmi_1_4b_transmitter_core_wrapper`，意外 0）；`UNCONNECTED = 0`（意外 0）；`EMPTY_CONN = 9 实例 / 22 端口`（有意 9、意外 0）；`RESULT: PASS`，exit=0 |
| 图像回归 | `sim\scripts\run_image_regression.ps1 -ReportDir sim\work_t26\rep_img` | `img_scaler` / `image_player` / `image_player_scaled` 三个 `passed=True`，exit=0 |

---

## 6. 连带风险：共享实例的 `out_*` 未全锁（只记录，不修改）

`fat32_reader` 的 `out_data_begin` / `out_fat_begin` / `out_spc` 是 `assign`（`:219-221`），不是每次 `start` 清 0 —— `data_begin`/`fat_begin` 只在复位（`:243-244`）与 `ST_VBR` 阶段（`:353-354`）被赋值。本修复让重入成为常态后，「第二次 `start` 到 `ST_VBR` 重填之前的窗口」会真的出现，三个消费者对这三根信号的锁存完备性如下：

| 消费者 | `out_data_begin` / `out_fat_begin` / `out_spc` | 是否锁存 | 风险 |
|---|---|---|---|
| `gallery_probe` | `rle_lba` / `rle_size` **在 found 那拍锁存**（`:416-417`）；`out_fat_begin` 空接（`:294 .out_fat_begin()`） | 已锁 | 低 |
| `img_loader` | `:567-569` 三根全是**裸 wire** | **未锁** | **中** |
| `wav_stream_player` | `cur_cluster`（`:719`）与 `spc_shift`（`:721`）已锁；`data_begin` / `fat_begin` / `spc` 仍是裸 wire（`:237-238`、`:302-304`） | **部分未锁** | **中** |

三处都在本卡 outOfScope，**代码未动**。建议由后续卡（或 t10 终审）评估：是否需要在这两个消费者里把 `data_begin`/`fat_begin`/`spc` 也仿照 `gallery_probe` 的做法在 `found` 那拍锁存。

---

## 7. 还原路径（供 t9 复核做反证）

原始文件备份在 `sim\work_t26\fat32_reader_orig.v`（42,276 B）。一键还原：

```powershell
cd D:\FPGA_Compelate\SmartCampusMedia
python sim\work_t26\patch_rtl.py restore
python sim\work_t26\patch_rtl.py check    # 打印七个特征计数，全 0 即已回到改前
```

还原后核对：

```powershell
Get-FileHash rtl\storage\fat32_reader.v -Algorithm MD5
```

- 改前（还原态）：`42276` 字节，`patch_rtl.py check` 输出
  `{'start_seen_decl': 0, 'start_seen_set': 0, 'idle_cond': 0, 'done_reentry': 0, 'fail_reentry': 0, 'clear_in_term': 0, 'gated_found': 0}`
- 改后（B4）：`45090` 字节，同一命令输出
  `{'start_seen_decl': 1, 'start_seen_set': 2, 'idle_cond': 1, 'done_reentry': 1, 'fail_reentry': 1, 'clear_in_term': 2, 'gated_found': 2}`

`patch_rtl.py` 每次注入都从 `fat32_reader_orig.v` 重建，不叠加；每个锚点 `assert count == 1`，不匹配即抛错且**不写文件**。

---

## 8. 结论

| 项 | 结果 |
|---|---|
| 终态可重入（`S_DONE` / `S_FAIL` 收到 `start` 回 `S_IDLE`） | ✅ |
| `st` 只由寄存器同步推进，无组合驱动 | ✅ |
| 终态不重复清零（清零职责只在 `S_IDLE`） | ✅ |
| 调用方零延迟看到旧结果作废（`term_reentry` 组合屏蔽） | ✅ 逐拍监视器 40001 → 0 |
| `tb_fat32_reader` | ✅ 64 PASS / 0 FAIL（改前 57/6） |
| `tb_wav_stream_player` | ✅ 46 PASS / 0 FAIL（改前 42/4） |
| lint / 端口名 / 图像回归 | ✅ 全通过 |
| 未改 outOfScope（`wav_stream_player.v`、`gallery_probe.v`、`img_loader.v`、`project/`） | ✅ |
| 未运行 `scripts\sync_src.ps1` | ✅ |

**对 S2（三份 `fat32_reader` 时分复用，净收益约 1,300 LUT + 12 DSP）的必要性**：S2 会让同一个实例被反复 `start`，本修复是该改造的**前置条件**——没有终态重入，三份消费者共享一个实例时，第二个消费者永远拿不到定位结果。
