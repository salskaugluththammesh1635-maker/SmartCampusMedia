# 双缓冲无缝切换实现交接（2026-10-27）

> **一句话**：`image_player` 从单帧缓冲改为**双缓冲无缝切换**——装载写后台帧、前台继续读旧帧，
> 写完整后等下一个垂直消隐再换帧首，重载期间屏幕**一帧不断**。`TASKS.md` A6 的缺口
> 「单缓冲，切图期间显示测试图，无双缓冲无缝切换」就此闭合。
> **全部证据为仿真档，从未上板；SiP SDRAM 150 MHz setup 违例（WNS −7.232 ns）未变，仍未构成可交付版本。**

---

## 一、本次要解决的问题

`TASKS.md` A6「日常播放模式」此前的缺口原文是：

> 未上板；单缓冲，切图期间显示测试图，无双缓冲无缝切换

`ARCHITECTURE.md` §8 取舍表第一行记录的是同一件事：

> | 单帧缓冲 | 装载期间显示测试图 | 切换有可见中断；重载失败不能保留上一帧 |

旧 `image_player` 的做法是：收到新图请求 → 拉低 `image_ready` → **共同复位整个存储数据通路**
（`img_loader`、`bmp_parser`、写 FIFO、`framebuf_arbiter`、`sdram_ctrl_wrap`、`pix_reader` 一起复位）
→ 从头装载 → 写完后重新提交。后果有两个：

1. **切换有可见中断**：复位期间 `pix_reader` 不供像素，顶层 `video_rgb` 回落到测试图，屏幕闪一下。
2. **重载失败丢画面**：新图读不出来（缺图、坏 BMP、SD 出错）时 `image_ready` 已经掉了，
   上一张能显示的图也没了，只剩测试图。

这两个问题都是「只有一个帧缓冲」逼出来的：要写新帧，就得先毁掉正在显示的那一帧。

---

## 二、方案：前后台分离 + 消隐期换帧首

SDRAM 里一帧 640×480 RGB565 占 153,600 个 32 bit 字（600 KiB），8 MiB 空间能放 13 帧。
既然只用了一帧，**用前两帧做乒乓**：

| 缓冲 | 起始字地址 | 角色 |
|---|---|---|
| 第 0 帧 | `0` | 前台或后台，由 `front_sel` 决定 |
| 第 1 帧 | `153600`（`FRAME_SPAN`） | 另一半 |

`front_sel` 是前台索引，`back_sel = ~front_sel` 是装载目标。于是：

- **装载永远写后台帧**，前台帧的读通路一个信号都不动 → 屏幕不断供；
- **提交只翻 `front_sel`**，且只在**垂直消隐上升沿**翻 → 换帧落在消隐内，可见区不撕裂；
- **装载失败保留旧帧**，`image_ready` 不掉 → 屏幕继续显示上一张。

这三个性质合起来就是「无缝」。

### 为什么改动能收敛在三个文件

勘察阶段的结论是：**写侧和读侧的地址通路本来就支持运行期基址**，真正缺的只是「谁来选基址」。

| 文件 | 改造前 | 改造后 | 改动量 |
|---|---|---|---|
| `rtl/storage/pix_reader.v` | `assign rd_base = FRAME_BASE;`（常量） | `rd_base` 改 **input** 端口，由上层驱动 | 2 行（端口方向 + 删 assign） |
| `rtl/storage/framebuf_arbiter.v` | 读侧 wrap 判据用编译期 `FRAME_LAST` | 新增 `rd_frame_base`/`rd_frame_last`，随 `rd_restart` 捕获的基址重算 | 9 行 |
| `rtl/storage/image_player.v` | 单缓冲 + 共同复位 | 双缓冲状态 + 复位解耦 + 提交挂起 | 142 行（含注释） |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | — | **零改动** | 0 行 |

写侧本来就不必改：`framebuf_arbiter` 在 `WR_ADDR_FROM_FIFO=1` 下写地址由 57 bit FIFO 携带
（`wr_word_addr`），`image_player` 只要在算 `word_addr` 时加个 `back_off` 偏移就行。

顶层零改动同样是有意的：双缓冲对外保持 `rgb565`/`pixel_valid`/`image_ready` 三个信号的语义不变，
把「缓冲」这件事完全封装在 `image_player` 内部。

---

## 三、逐模块改动

### 3.1 `pix_reader.v`：`rd_base` 由输出变输入

```verilog
// 改前
output wire [ADDR_WIDTH-1:0] rd_base,// 重启目标帧首，保持不变
...
assign rd_base = FRAME_BASE; // 请求期间与完成期间基址都稳定

// 改后
input wire [ADDR_WIDTH-1:0] rd_base,// 当前显示缓冲区首地址，由上层选定
```

其余 280 行（状态机、信用、跨域同步）**一行未动**。原因：重启基址的捕获发生在
`framebuf_arbiter` 的 `rd_base_hold`，`pix_reader` 只需要保证「`rd_restart` 那一拍 `rd_base` 稳定」。
`image_player` 用 `front_sync_sdr[1]` 两级同步后再驱动它，满足这个约束。

### 3.2 `framebuf_arbiter.v`：读侧回绕边界随捕获基址重算

```verilog
// 新增两个运行期量
reg [ADDR_WIDTH-1:0] rd_frame_base; // 运行期读帧首，随重启基址更新
reg [ADDR_WIDTH-1:0] rd_frame_last; // 运行期读帧末组首，随重启基址预计算

// rd_restart 那拍捕获（与 rd_base_hold 同拍）
if (rd_restart) begin
    rd_rst_pend <= 1'b1;
    rd_base_hold <= rd_base;
    // 读基址可在双缓冲下指向任意帧首，回绕边界必须随之预计算。
    rd_frame_base <= rd_base;
    rd_frame_last <= rd_base + FRAME_WORDS - 4;
end

// 读组推进的 wrap 判据
if (rd_addr >= rd_frame_last) rd_addr <= rd_frame_base;
else rd_addr <= rd_addr + 4;
```

**这是本次唯一一处「必须改」的既有逻辑缺陷**：改造前读侧 wrap 只认编译期 `FRAME_BASE = 0`，
读基址一旦设成 153600，第一组读完就会 `rd_addr >= FRAME_LAST`（153596）成立、
立刻回绕回 0 —— 也就是读后台帧时实际读到第 0 帧。

写侧 `wr_addr`/`FRAME_LAST` **完全未动**：`WR_ADDR_FROM_FIFO=1` 时它不参与真实地址，
只在 `WR_ADDR_FROM_FIFO=0` 的旧路径（`tb_framebuf_arbiter` 的部分用例）里生效。

### 3.3 `image_player.v`：双缓冲状态 + 复位解耦 + 提交挂起

#### 新增参数与缓冲索引

```verilog
parameter MEM_WORDS = 262_144,
parameter SEAMLESS = 1              // 1=双缓冲无缝切换，0=单帧缓冲

localparam [20:0] FRAME_SPAN = FRAME_WORDS; // 一帧占用的 32 位字数

reg front_sel;
reg commit_pending;                  // 后台帧已就绪，等垂直消隐再换帧首
wire back_sel = SEAMLESS ? ~front_sel : 1'b0;
wire [20:0] back_off = back_sel ? FRAME_SPAN : 21'd0;
wire [20:0] rd_base;                 // 当前显示帧首，rd_restart 那拍必须稳定
```

`SEAMLESS=0` 时 `back_sel` 恒为 0，读写都落在第 0 帧，行为与旧设计**逐拍等价**——
这是刻意保留的对照档，用来证明「新逻辑没有顺手改坏旧路径」。

#### 复位解耦（关键）

旧设计只有一套 `path_rst_pix`/`path_rst_sdr`，`path_enable = (state != C_WAIT) && (state != C_RESET)`。
装载一开始就复位整条存储通路，前台必然断供。现在拆成两套：

```verilog
// 装载通路每次重载都要清空；显示通路只在无有效帧时才复位，双缓冲不得打断前台。
wire loader_enable = (state != C_WAIT) && (state != C_RESET);
wire store_keep = SEAMLESS && image_ready;
wire store_enable = loader_enable || store_keep;
...
wire loader_rst_pix = loader_sync_pix[2];   // img_loader / bmp_parser / 写 FIFO 写侧 / 生产计数
wire loader_rst_sdr = loader_sync_sdr[2];   // 写 FIFO 读侧 / 队头寄存 / 消费计数
wire store_rst_pix  = store_sync_pix[2];    // pix_reader 像素侧
wire store_rst_sdr  = store_sync_sdr[2];    // framebuf_arbiter / sdram_ctrl_wrap / pix_reader sdr 侧
```

`store_enable = loader_enable || store_keep` 的含义：**只要已有在显帧，显示通路就一直保持释放**，
哪怕装载正在进行。这就是「装载期间旧帧不中断」的实现基础。

配套还拆了一处：`arb_error_sync` 原本跟着装载复位一起清，现在单独用 `rst_n_pix` 复位——
仲裁故障是粘滞的，只能靠整机复位清除，跟着装载清掉会让看门狗失效。

#### 提交挂起 + 消隐期换帧首

```verilog
localparam [9:0] HEIGHT_IN = HEIGHT;
wire ext_vblank = (scan_y >= HEIGHT_IN); // 顶层把消隐编码成扫描行号越界
reg vblank_d;
wire vblank_rise = ext_vblank && !vblank_d;

// C_COMMIT 不再直接置 image_ready，改为挂起
C_COMMIT: if (complete_sync[1]) begin
    commit_pending <= 1'b1; state <= C_SHOW;
end

// 挂起的提交在消隐上升沿（或首次装载）落地
if (commit_pending && (!image_ready || vblank_rise)) begin
    front_sel <= back_sel;
    image_ready <= 1'b1;
    commit_pending <= 1'b0;
end
```

`ext_vblank` 用的是顶层已有的 `scan_y(vblank ? 10'd480 : active_y)` 编码——
消隐期传 480，有效区传 `active_y`（0..479）。这个编码先例本来就在，不用改顶层。

`!image_ready` 这个条件是**首次装载直通**：还没画面可撕裂，不必等消隐，直接提交让第一张图尽快出来。

#### 读基址驱动

```verilog
reg [1:0] front_sync_sdr;            // 前台索引跨到 sdr 域，供读重启采样
always @(posedge sdr_clk or negedge rst_n_sdr) begin
    if (!rst_n_sdr) front_sync_sdr <= 2'd0;
    else front_sync_sdr <= {front_sync_sdr[0], front_sel};
end
...
assign rd_base = front_sync_sdr[1] ? FRAME_SPAN : 21'd0;
```

两级同步是必须的：`front_sel` 在 `pix_clk` 域翻转，`rd_base` 在 `sdr_clk` 域被
`framebuf_arbiter` 的 `rd_restart` 那拍采样。取 `[1]` 而非 `[0]` 是为了让基址变化**晚于**
`pix_reader` 侧看到 `front_sel` 变化，避免基址先变、重启后到的竞态。

#### 写地址加后台偏移

```verilog
wire [20:0] word_addr = pixel_y * WORDS_LINE + (pixel_x >> 1) + back_off;
```

一行改动，前后台地址互不重叠。

#### 失败语义分离

```verilog
C_SHOW, C_FAIL: if ((pending || load_req) && sd_ready && !blk_busy) begin
    ...
    // 双缓冲保留在显帧直到新帧提交；单帧必须立刻退掉，因为马上要覆盖它。
    if (!SEAMLESS) image_ready <= 1'b0;
    ...
end

// 看门狗
if ((loading && (timer >= LOAD_TIMEOUT)) || ((loading || image_ready) && arb_error_sync[1]) ||
    (((state == C_LOAD) || (state == C_COMMIT) || image_ready) && !sdr_online[1])) begin
    // 存储侧故障必须先退掉旧帧：显示通路共用复位靠 image_ready 释放，
    // 否则粘滞错误永远清不掉。装载侧失败则保留上一帧继续显示。
    if (!SEAMLESS || arb_error_sync[1] || !sdr_online[1]) image_ready <= 1'b0;
    failed <= 1'b1;
    error_code <= (arb_error_sync[1] || !sdr_online[1]) ? 4'd8 : 4'd9;
    commit_pending <= 1'b0;
    state <= C_FAIL;
end
```

这里有一个**不对称**，是刻意设计：

| 失败类型 | 错误码 | `image_ready` | 屏幕 |
|---|---|---|---|
| 装载侧（缺图/坏 BMP/像素数不足/超时） | 1~7、9 | **保持 1** | 继续显示上一帧 |
| 存储侧（仲裁错误、SDRAM 失锁） | 8 | **必须清 0** | 回落测试图 |

存储侧为什么必须清？因为 `pix_reader` 的 `rst_n_pix = store_rst_pix && image_ready`、
`reader_async_sdr = store_rst_sdr && image_ready`——**显示通路的复位释放依赖 `image_ready`**。
存储侧坏了如果不撤 `image_ready`，显示通路就一直不复位、粘滞错误永远清不掉，无法恢复。
装载侧失败不涉及显示通路，所以保留旧帧是安全且正确的。

---

## 四、验证证据

### 4.1 图像链回归（三档全绿）

`sim/scripts/run_image_regression.ps1 -FullVga`，报告在 `reports/s6_integration/simulation/`：

| 用例 | 参数 | 断言数 | 结果 | 无缝证据 |
|---|---|---|---|---|
| `image_player` | 默认（32×16 小图，快速） | 6205 | errors=0 | `front_flips=2 overlap_cycles=258005 starve_cycles=0` |
| `image_player_full` | `-gFULL=1`（真实 640×480） | 1,228,812 | errors=0 | `front_flips=2 overlap_cycles=2085846 starve_cycles=0` |
| `image_player_single` | `-gSEAMLESS=0`（单帧对照） | 6203 | errors=0 | `front_flips=0 overlap_cycles=0 starve_cycles=0` |

三个观测量的含义：

- `front_flips`：`front_sel` 翻转次数。双缓冲下每次成功重载**恰好翻一次**；
  单帧档必须**恒为 0**（`back_sel` 被 `SEAMLESS ? ~front_sel : 1'b0` 钉死）。
- `overlap_cycles`：`image_ready && dut.loading` 同时成立的拍数，即**「屏幕上已有帧，同时后台正在装载」的拍数**。
  这个数大于 0 才有「无缝」可言——单帧档必然是 0，因为装载前就掉了 `image_ready`。
- `starve_cycles`：上述拍数中 `de` 有效却没有像素的拍数，**必须为 0**。这是无缝的直接判据。

真实 640×480 下 `overlap_cycles = 2,085,846` 拍 ≈ 83 ms @25 MHz，即整整两帧多的装载过程
（`FULL` 用例连做两次重载）全程前台不断供。

### 4.2 新增的无缝断言（`tb_image_player.v` CASE 2）

```verilog
if (SEAMLESS) begin
    // 换帧必须在后台帧写完之后发生，且恰好一次。
    chk(front_changes == changes_before + 1,"seamless reload flips the front buffer exactly once");
    // 装载全程前台帧持续供给：这是"无缝"的直接证据。
    chk(seam_checked > 0,"reload overlaps the displayed frame, giving seamlessness a chance to break");
    chk(seam_gaps == 0,"front frame never starves while the back buffer loads");
end else begin
    chk(front_changes == changes_before,"single-buffer mode never flips the front selection");
end
```

第二条断言（`seam_checked > 0`）是防止「假通过」的关键：如果装载和显示完全不重叠，
`seam_gaps == 0` 会轻松通过但毫无意义。这条断言强制要求重叠**真的发生过**。

### 4.3 存储回归（`run_storage_regression.ps1 -Suite All`）

| 用例 | 断言数 | 场景数 | 结果 |
|---|---|---|---|
| `tb_async_fifo` | 24 | 8 | errors=0 |
| `tb_framebuf_arbiter` | 50,900 | 15 | errors=0 |
| `tb_sdram_ctrl_wrap` | 154,771 | 12 | errors=0 |
| `tb_pix_reader` | 108 | 8 | errors=0 |

`tb_framebuf_arbiter` 的参考模型同步改了读侧 wrap 判据（`captured_restart_base + FRAME_WORDS`），
否则 T13「捕获式重启」用例必红——旧判据写死 `FRAME_BASE`，新逻辑按捕获基址算。

### 4.4 静态检查

`python scripts/lint_verilog.py rtl` → 39 个文件，E0/E1/E2 全 0，通过。

---

## 五、测试台改动明细

| 文件 | 改动 | 原因 |
|---|---|---|
| `tb_image_player.v` | `terminal` 任务改为等 `(dut.loading \|\| dut.commit_pending)` 全清 | 双缓冲下 `image_ready` 常驻 1，不能再用它判装载结束 |
| `tb_image_player.v` | 新增 `front_changes`/`seam_checked`/`seam_gaps` 三个观测量，`seam_*` 跨复位累积 | 复位会把证据抹掉，改由用例取基准增量 |
| `tb_image_player.v` | CASE 3 改 `chk(SEAMLESS ? image_ready : !image_ready, ...)` | 双缓冲下装载侧失败应保留旧帧 |
| `tb_image_player.v` | CASE 9 同 CASE 3 处理 | 超时属装载侧失败 |
| `tb_image_player.v` | CASE 11 的 `path_rst_*` 改 `store_rst_*` | 原信号名已不存在，不改会编译失败 |
| `tb_image_player.v` | **`if(FULL) $finish` 块从 CASE 1 之后移到 CASE 2 之后** | 原来 FULL 用例跑完 CASE 1 就退出，**双缓冲断言被整个跳过**——这是最隐蔽的一处 |
| `tb_pix_reader.v` | `wire [20:0] rd_base` → `reg [20:0] rd_base = FRAME_BASE` | `rd_base` 变输入端口，需 TB 自己驱动 |
| `tb_framebuf_arbiter.v` | 读侧 wrap 判据改基于 `captured_restart_base` | 参考模型必须跟着 DUT 改 |
| `run_image_regression.ps1` | 新增 `image_player_single` 用例（`-gSEAMLESS=0`）；判定改用 `$case.marker` | 同一 TB 跑不同参数时，通过标记可能与用例名不同 |

> **踩到的坑**：`if(FULL) $finish` 在 CASE 1 之后，意味着改造前「FULL 全尺寸通过」这个结论
> 只覆盖了 CASE 1。这是既有测试台的结构问题，本次一并修正。

---

## 六、遗留与边界（如实记录）

1. **未上板**。全部证据为 ModelSim 仿真档。双缓冲的正确性依赖「垂直消隐上升沿可靠」，
   而顶层 `scan_y` 的消隐编码是既有机制（S9 之前就在用），但**真机上 `front_sel` 翻转
   与 `rd_restart` 的相对时序从未实测**。
2. **SiP SDRAM 150 MHz setup 违例未变**（WNS −7.232 ns / TNS −335.004 ns）。这是发布阻塞项，
   与本次改动无关，但意味着**本次改动没有经过真实布线后的时序验收**。
   新增逻辑全在 `sdr_clk` 域（`rd_frame_base`/`rd_frame_last` 两个寄存器 + 一个加法器），
   理论上不加剧该路径压力，但**没有实测数据支撑这个判断**。
3. **资源占用未重新测量**。新增约 2 个 21 bit 寄存器 + 一个 21 bit 加法器 + 若干跨域同步寄存器，
   预计增量极小，但**没有综合报告**。
4. **失败可见性变弱**。装载侧失败时屏幕仍显示旧帧，操作者无法从画面判断「这张没换成」，
   必须靠数码管 DIG2（错误码）或 LED（`sd_or_gallery_fail || image_failed`）。
   这是无缝的代价，已记入 `ARCHITECTURE.md` §8 取舍表。
5. **只支持 2 缓冲**。SDRAM 能放 13 帧，做成 N 缓冲需要另一套调度，本次不做。
6. **`tb_probe_order.v` / `tb_probe_pix.v` 无法加载是既有问题**，与本次无关：
   二者被 `.gitignore:54` 的 `sim/testbench/tb_probe_*.v` 排除（从未入库），
   且引用的 `dut.fifo_wr_data`/`dut.flush_sdr`/`dut.pix_cnt`/`dut.rd_cnt_s2`/`dut.wr_cnt`
   在 `pix_reader.v` 中早已不存在（`vsim-3043 Unresolved reference`）。
   `tb_probe_burst.v` 可加载但无自检标记，属纯探针。三者均不作为交付证据。

---

## 七、复现命令

```powershell
# 1) 静态检查
python scripts\lint_verilog.py rtl

# 2) 图像链三档回归（含无缝证据行）
powershell -ExecutionPolicy Bypass -File sim\scripts\run_image_regression.ps1 -FullVga

# 3) 存储链回归
powershell -ExecutionPolicy Bypass -File sim\scripts\run_storage_regression.ps1 -Suite All

# 4) 同步到 TD 工程副本
powershell -ExecutionPolicy Bypass -File scripts\sync_src.ps1
```

判据：三档均须 `errors=0`、含 `ALL CHECKS PASSED: <marker>`、
双缓冲档 `starve_cycles=0` 且 `overlap_cycles>0`、单帧档 `front_flips=0`。

---

## 八、文件清单

**修改（3 个 RTL）**

- `rtl/storage/image_player.v`：274 → 334 行
- `rtl/storage/framebuf_arbiter.v`：+9 行
- `rtl/storage/pix_reader.v`：+1 / −2 行

**修改（测试台与脚本）**

- `sim/testbench/tb_image_player.v`
- `sim/testbench/tb_framebuf_arbiter.v`
- `sim/testbench/tb_pix_reader.v`
- `sim/scripts/run_image_regression.ps1`

**修改（历史诊断工程的最小兼容修复，3 个文件各 2 行）**

`pix_reader` 的 `rd_base` 变输入后，这三个工程里原先靠 `pix_reader` 输出驱动的
`wire [20:0] rd_base;` 失去驱动源，各补一行固定为第 0 帧：

```verilog
wire [20:0] rd_base; // 单帧诊断工程固定第 0 帧；pix_reader 的基址已改为输入端口
assign rd_base = 21'd0;
```

- `project/image_path_diag/image_player_path_diag.v`
- `project/image_readback_diag/image_player_readback_diag.v`
- `project/image_dm_fix/image_player_dm_fix.v`

**修改（文档）**

- `ARCHITECTURE.md`：§5 地址公式与双缓冲布局、7 条无缝切换契约；§8 取舍表首行；§9 契约表
- `TASKS.md`：A6 缺口闭合；P1 第 8 条
- `README.md`：「帧缓存与提交机制」整段重写
- `docs/progress.md`：追加 S10 章节

**未改动**

- `rtl/top/dmz_eg4s20_hdmi_top.v`：零改动
- `rtl/control/player_ctrl.v`：零改动
