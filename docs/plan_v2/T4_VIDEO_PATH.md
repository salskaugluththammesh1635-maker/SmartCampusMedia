# T4 视频帧序列通路 —— 交付文档

> 任务：t4 — `rle_decoder.v` + `pix_reader` 行映射 + `image_player` 外部写口
> 执行：rtl-storage ｜ attempt_id `92d5aacf-6911-42c5-9f79-d2850bf64494`
> 依据：`docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md`（下称《附录》）§3/§4/§9.9/§13/§18、`docs/plan_v2/ARCH.md` §6.5/§6.7
> 日期：2026-11-02

---

## §0 一句话结论

科普模式从 SD 卡播放 RLE 视频帧序列的通路已打通：`rle_decoder` 从零新建，用**真素材** `SCI.RLE` 的前两帧逐字比对，153,600 个字全部与独立展开的金标准相符，零错字；`pix_reader` 加上垂直行映射、`image_player` 加上 12 个外部写端口，六个受影响 testbench 全部编译通过（四个全绿、两个探针 tb 编译零错），`lint` E0/E1/E2 全 0。

| 验证项 | 结果 |
|---|---|
| `lint_verilog.py rtl` | 67 文件，E0=0 E1=0 E2=0，退出码 0 |
| `lint_verilog.py sim/testbench/tb_pix_reader.v` | E0=0 E1=0 E2=0（与改造前基线一致） |
| `tb_rle_decoder` | **checks=30 errors=0**，PASS |
| `tb_pix_reader` | **checks=194 errors=0**，PASS（含 2 条 V-03 用例 + 3 条 Key9 用例，见 §15） |
| `tb_image_player` | **checks=11365 errors=0**，PASS（13 个既有 CASE 全过） |
| `tb_display_content` | **checks=614406 errors=0**，PASS |
| `tb_startup_ownership` | **checks=9 errors=0**，PASS |
| `tb_probe_order` / `tb_probe_pix` | 补端口后 `vlog` 退出码 0（探针 tb，无自检判据） |

---

## §1 交付清单

| # | 文件 | 大小 | 行数 | 性质 |
|---|---|---|---|---|
| 1 | `rtl/storage/rle_decoder.v` | 33,061 B | 674 | **新建**。RLE 解码 + SDRAM 写口 |
| 2 | `rtl/storage/pix_reader.v` | 24,701 B | 429 | 改造。+2 输入、+3 输出、垂直 DDA；**t12 追加** +6 端口（`active_x`/`win_*`/`out_valid`）与水平窗口降采样（§15） |
| 3 | `rtl/storage/image_player.v` | 32,278 B | 605 | 改造。+14 端口、写口 mux、翻帧分支 |
| 4 | `sim/testbench/tb_rle_decoder.v` | 24,464 B | 626 | **新建**。五组 CASE、真素材驱动 |
| 5 | `sim/testbench/tb_pix_reader.v` | 26,857 B | 587 | 改造。+V-03 用例、+逐像素映射校验；**t12 追加** Key9 三个用例（§15.5） |
| 6 | `sim/testbench/tb_image_player.v` | 39,666 B | 768 | 改造。仅补端口 |
| 7 | `sim/testbench/tb_display_content.v` | 22,041 B | 416 | 改造。仅补端口 |
| 8 | `sim/testbench/tb_startup_ownership.v` | 9,089 B | 161 | 改造。仅补端口 |
| 9 | `sim/testbench/tb_probe_order.v` | 10,598 B | 264 | 改造。仅补 `pix_reader` 端口（R-01 未列，grep 才发现的第二个例子） |
| 10 | `sim/testbench/tb_probe_pix.v` | 9,233 B | 273 | 改造。仅补 `pix_reader` 端口（同上） |
| 11 | `sim/testbench/vectors/*.hex` | 7 个文件 | — | 新建。真素材与合成向量 |

范围纪律：未触碰 `rtl/video/`、`rtl/osd/`、顶层 `rtl/top/dmz_eg4s20_hdmi_top.v`、`scripts/sync_src.ps1`。

---

## §2 rle_decoder 端口契约

```verilog
module rle_decoder #(
    parameter CLK_FREQ_HZ   = 25_000_000,
    parameter FRAME_W       = 16'd640,
    parameter FRAME_H       = 16'd480,
    parameter JITTER_FRAMES = 8'd3,
    parameter INIT_WR_BANK  = 1'b1,
    parameter LOOP_PLAY     = 1'b1,
    parameter BLK_BYTES     = 16'd512
)(
    input  wire        clk, rst_n,
    // SD 读块接口（与 sd_spi_ctrl 同域，25 MHz）
    output wire        blk_start,   // 与 blk_addr 同拍有效，保持到 blk_busy 拉高
                                    // t15 起为组合门控：blk_start_int && sd_grant（见 §16.3）
    output reg  [31:0] blk_addr,    // 扇区号 = file_lba + 块序号
    input  wire        blk_busy,
    input  wire        blk_done,    // 单拍：BLK_BYTES 字节已全部送达
    input  wire        blk_err,     // 单拍：块读失败
    input  wire [7:0]  data_byte,
    input  wire        data_valid,  // 与 data_byte 同拍，连续 BLK_BYTES 拍
    input  wire        sd_grant,    // t15：仲裁器「这一块让给你」电平，顶层组合给出
    // 控制
    input  wire        play_en,
    input  wire [7:0]  play_fps,    // 目标帧率，0 按 1 处理
    input  wire [31:0] file_lba,
    input  wire [31:0] file_size,
    output reg  [15:0] frame_idx,
    // SDRAM 外部写口（对接 image_player.ext_*）
    output reg         ext_wr_done, // 单拍：整帧 FRAME_WORDS 字全部写完
    output reg         ext_wr_valid,
    output reg  [20:0] ext_wr_addr,
    output wire [31:0] ext_wr_data, // 高 16bit = 右像素，低 16bit = 左像素
    output wire [3:0]  ext_wr_dm,   // 恒 4'h0（dm[n]=1 为屏蔽）
    input  wire        ext_wr_ack,
    input  wire        ext_wr_busy,
    // 状态
    output reg  [3:0]  err_code,    // 1=magic 2=尺寸 3=像素数 4=截断/块错
    output reg         underrun,
    output wire        want_blk     // 高：本模块正在等待 SD 块
);
```

端口命名以《附录》§3.2/§8.3 为准，**不是** ARCH §6.5 原稿：原稿的 `frame_ready` 已改名 `ext_wr_done`，并新增 `ext_wr_ack`/`ext_wr_busy` 两个输入。

### §2.1 与《附录》§3.2 的差异说明（13 行 vs 12 个）

《附录》§3.2 的端口块写了 13 行、正文说「12 个外部写端口」。差异在 `ext_frame_ready` 与 `ext_frame_sel` 这一对：前者是「本帧已提交」的单拍脉冲，后者是「当前前台缓冲」的电平。二者语义不同、都实现了，所以 `image_player` 侧实际新增 12 个 `ext_*` 端口 + 2 个 `src_w`/`src_h` 透传端口 = **14 个**。

### §2.2 内部结构（三个 `always` 块，单驱动纪律）

| 块 | 职责 |
|---|---|
| ① 块缓冲写口 | `blk_buf[0:511]` 写入，`blk_start && !blk_start_d` 清 `wr_ptr` |
| ② 主块 | RLE 展开器 push、4 深度字缓冲、外部写口、FSM |
| ③ 帧间看门狗 | `jitter_cnt` 累计跳帧，置 `wd_expired` |

展开器是**纯组合**（`exp_active/exp_half/exp_pair/exp_single/exp_push/exp_word`），刻意不用寄存器：早期版本用 `push_word <=` 寄存器后又想在同一个 `always` 块里写 `wmem[whead] <= push_word`，读到的是旧值。

**4 深度字缓冲是 P1 的基石**：只有 `wcount >= 4` 才开组，开组后 4 拍必然齐备，组绝不会半途中止，于是组基址天然 4 字对齐（详见 §6.2）。

---

## §3 RLE 帧格式

### §3.1 文件结构（每帧自带 12 字节头）

| 偏移 | 长度 | 字段 | 字节序 | 实测值（SCI.RLE 帧 0） |
|---|---|---|---|---|
| 0 | 4 B | magic `"SCMR"` | **大端**（ASCII） | `53 43 4D 52` |
| 4 | 2 B | width | **小端** | `80 02` = 640 |
| 6 | 2 B | height | **小端** | `E0 01` = 480 |
| 8 | 4 B | run_count | **小端** | `B0 04 00 00` = 1200 |
| 12 | 3×run_count | payload | — | — |

**这是混合字节序**：magic 是 ASCII 所以天然是「高字节在前」，而三个数值字段都是小端。这个不一致在 §6.1 造成了一个真实缺陷。

### §3.2 RLE 条目

每条 3 字节：`{rgb565[15:0], run_len[7:0]}`，其中 RGB565 **高字节在前**，`run_len == 0` 表示 **256**。

依据编码器源码而非推断：`scripts/gen_assets_v2_sdcard.py:389-390` 注释「条目格式 {rgb565[15:0], run_len[7:0]}，高字节在前，run_len==0 表示 256」，`:414-416` 的 `payload[:,0]=(vals>>8)&0xFF; payload[:,1]=vals&0xFF; payload[:,2]=(runs&0xFF)` 与之逐位一致。

### §3.3 字内打包

SDRAM 一个字装两个像素，**低 16bit = 左（偶列）像素，高 16bit = 右（奇列）像素**。

这一条与 ARCH 里「高 16bit = 左像素」的表述**相反**，实现以现有 RTL 为准：`rtl/storage/pix_reader.v:66` 注释「偶像素低半字、奇像素高半字」、`:159-160` 先出 `fifo_rd_data[15:0]` 再出 `word_hold[31:16]`，`rtl/storage/img_loader.v:105,530` 的 `fifo_wr_data <= {pix_rgb565, pix_lo}` 同构。若按 ARCH 的表述打包，画面会是**每一对相邻像素左右互换**——不报错、不黑屏，只是看起来像「画面轻微毛刺」。

### §3.4 dm 极性（`dm[n]=1` 为屏蔽）

`ext_wr_dm` 恒为 `4'h0`。全链路证据：

- `rtl/storage/sdram_ctrl_wrap.v:51,54`「`dm[n]=1` 表示屏蔽 `din[8n+7:8n]` 字节」「**以本文为准**，1=屏蔽，0=写入」
- `rtl/storage/sdram_ctrl_wrap.v:384-387` 行为模型 `if (!app_wr_dm[0]) mem[..][7:0] <= app_wr_din[7:0];`
- `rtl/storage/framebuf_arbiter.v:124` `app_wr_dm = wr_real ? wr_dm : (wr_fire ? 4'hF : 4'h0);`（组内补拍用 `4'hF` 全屏蔽）
- `rtl/storage/img_loader.v:106,539` `// 全写时为 4'h0`、`fifo_wr_dm <= 4'hC; // dm=1 屏蔽 → 只写 [15:0]`

写 `4'hF` 会让**整帧一个字都写不进去**，而 `ext_wr_done` 照常拉高——现象是「屏幕停在上一帧或全黑、零报错」，属最难查的一类。

---

## §4 12 端口连线表

### §4.1 `rle_decoder` ↔ `image_player`

| # | `image_player` 端口 | 方向 | 连接 | 说明 |
|---|---|---|---|---|
| 1 | `ext_wr_mode` | in | `ext_wr_mode`（顶层） | 0=BMP 装载（现状）1=RLE 直写 |
| 2 | `ext_wr_valid` | in | `rle_wr_valid` | 单拍写请求 |
| 3 | `ext_wr_addr[20:0]` | in | `rle_wr_addr` | 组首必须 4 字对齐 |
| 4 | `ext_wr_data[31:0]` | in | `rle_wr_data` | 高 16bit 右像素 |
| 5 | `ext_wr_dm[3:0]` | in | `rle_wr_dm` | 恒 `4'h0` |
| 6 | `ext_wr_done` | in | `rle_wr_done` | 单拍：整帧写完 |
| 7 | `ext_wr_ack` | **out** | `rle_wr_ack` | 单拍：本次写被仲裁器接受 |
| 8 | `ext_wr_busy` | **out** | `rle_wr_busy` | 高：未回 ack，外部不得推进地址 |
| 9 | `ext_frame_ready` | **out** | `rle_frame_ready` | 单拍：本帧已提交（vblank 翻页完成） |
| 10 | `ext_frame_sel[1:0]` | **out** | 悬空 | 当前前台缓冲；t8 可留给探针 |
| 11 | `ext_no_fade` | in | `ext_no_fade`（顶层） | **视频模式必须为 1** |
| 12 | `ext_loader_want_blk` | **out** | `img_loader_want_blk` | 高：`u_loader` 正在请求 SD 块 |
| 13 | `src_w[15:0]` | in | `eff_src_w`（ratio_map） | 透传给 `u_reader` |
| 14 | `src_h[15:0]` | in | `eff_src_h`（ratio_map） | 透传给 `u_reader` |

### §4.2 三条硬性质在实现中的落点

| 性质 | 落点 | 违反现象 |
|---|---|---|
| `ext_wr_addr[1:0]` 组首恒 `2'b00` | 4 深度字缓冲：`wcount>=4` 才开组 | 横向撕裂（易误判为显示器故障） |
| `ext_wr_busy` 高时不推进地址 | `do_pop = ext_wr_valid && ext_wr_ack`，地址只在 ack 时 `+1` | 丢字、地址错位 |
| 换帧必须等 `vblank_rise` | 复用既有 `commit_pending` 三条翻帧路径 | 换帧瞬间撕裂 |

`ext_wr_busy` 在本模块内部**不参与任何状态**：反压完全由「只在 ack 时推进」实现，`busy` 保持为对外可观测的握手信号。这一点写在文件头 `[4] P2`，因为接手者容易以为它是反压输入而去找不存在的使用点。

### §4.3 `image_player` 内部改动（8 处）

| # | 位置 | 改动 | 预算 |
|---|---|---|---|
| 1 | 端口表末尾 | +14 端口 | — |
| 2 | `:148` | `wire bmp_load_req = load_req && !ext_wr_mode;` | +6 |
| 3 | 主 `always` 块首 | `commit_pending` 优先级链最前插并列置位分支 | +3 |
| 4 | 三处翻帧点 | 各加 `ext_frame_ready_r <= 1'b1;` | — |
| 5 | `:252` | `!FADE_ON` → `!FADE_ON \|\| ext_no_fade`（视频走消隐硬切换） | +8 |
| 6 | 状态机 3 处 | `load_req` → `bmp_load_req`（视频模式冻结 BMP 装载） | 含上 |
| 7 | FIFO 消费 4 处 | `bmp_wr_ack = wr_ack && !ext_wr_mode`；`fifo_pop` 加 `!ext_wr_mode` | +80 |
| 8 | 写口 mux | `arb_wr_req/addr/data/dm` 四路 mux + ack/busy 生成 | 含上 |

合计约 **+97 LUT**，与《附录》§3.3 的预算一致。

---

## §5 pix_reader 行映射

### §5.1 新增端口

```verilog
input  wire [15:0] src_w,          // 当前档源宽（仅用于映射有效性判定）
input  wire [15:0] src_h,          // 当前档源高：240/300/384/432/480
output wire [15:0] src_y,          // 本行对应的源行号
output wire        src_row_hold,   // 高：本行不推进源行（重复上一源行）
output wire        map_ident       // 高：src_h==480，恒等旁路
```

### §5.2 与《附录》§9.2 伪代码的关键差异（必须记录）

《附录》§9.2 写的是「行地址生成处加垂直 Bresenham —— 仅当 `y_acc + src_h >= 480` 时才真正推进一行」。**这个伪代码在现有 RTL 里没有落点**：`pix_reader` 内部完全没有行地址寄存器，SDRAM 的顺序读地址由 `framebuf_arbiter` 内部的 `rd_addr` 每拍 `+4` 字自主推进（见 `rtl/storage/framebuf_arbiter.v` 的 `rd_addr` 更新与 `rd_frame_last` 回卷）。模块里既没有 `row_addr`，也没有 `new_frame`。

因此实际实现改为：**在像素域做垂直 DDA，输出映射结果而不改动像素通路**。

| 项 | 取值 |
|---|---|
| 累加器 | `reg [15:0] y_acc`（16 FF） |
| 推进点 | `line_last = de && (pix_count == PIX_PER_LINE-1)`，即每行最后一个有效像素 |
| 帧清零 | `new_frame = line_last && (active_y == FRAME_LINES-1)` |
| 判定 | `row_step = (y_sum >= FRAME_LINES)`，`y_new = row_step ? y_sum-480 : y_sum` |
| 输出 | `src_y_reg` 在整行内稳定，经行末更新后跨水平消隐送到下一行 |
| 非法保护 | `src_ok = (src_w!=0)&&(src_h!=0)&&(src_h<=FRAME_LINES)`，非法退回恒等 |

**没有做 FIFO 消费门控**。理由：《附录》明确要求「零缓存、读带宽不变」，而真正做到行重复需要一套消费节流（~~行缓存（BRAM 不够）~~ —— **括号里这句已作废，见下方更正框**）。本模块只负责产出 `src_y`/`src_row_hold`/`map_ident` 三个映射结果，行重复的生效点当时留在下游（`pix_mosaic`/`content_mux` 侧，属 t7 后续）。因此状态机、FIFO、`P_*` 六态、`LEVEL_HI`/`RD_GROUP_CYCLES` **全部零改动**，读带宽与改造前逐拍相同。

> 此差异已在 `rtl/storage/pix_reader.v` 文件头写明，避免后续读者按《附录》伪代码去找一个不存在的 `row_addr`。

> **⚠️ 更正（2026-11-02，t22 立项时 captain 复核推翻了上面那句括号里的判断）**：上文「真正的行重复需要行缓存（BRAM 不够）」这一说法**不成立，已作废**。五档等比缩小全部可行，**零 BRAM、零 DSP、无乘除**——窗口外那 `640 − win_w` 拍是空着的，正好用来把下一条源行读出来**直接丢弃**（配额式垂直跳行）。逐档验算见 §15.9 的表，五档余量分别是 0 / 48 / 53 / 34 / 恒等。第 2 步由 **t22** 承接，实现时按 §15.9 的配额累加器做法，不需要任何行缓存。此更正保留在原处，是因为该错误结论若流到 t11，会把「做不了」写进交付文档。**🕓 但本框的结论也已被取代**：`docs/plan_v2/KEY9_RULING.md` §2 实测证明五档等比缩小**物理不可行**（顺序 FIFO 需整帧缓存 76,800 字 = **267 块 BRAM9K**，全片仅 **64 块**），t28 已裁定不做。本框保留原文只为呈现认识演进，**不得作为方案依据**。


### §5.3 为什么推进点放在行末而不是行首

放在行首会让 `src_y` 在行内第一拍才更新，而 `pix_reader` 的 `word_hold`/FIFO 出队与 `de` 同拍，行首更新会产生一拍相位差。放在行末则 `src_y` 在整行内保持恒定，下游任何时刻采样都拿到同一值。

---

## §6 调试实录：五个缺陷与它们为什么「不报错」

这一节是本任务最有价值的部分。五个缺陷里**没有一个会让工具报错**，全部表现为画面异常或静默不工作。

### §6.1 帧头字段字节序拼反（两处）

`R_HDR_WH` 分支与原写法：

```verilog
// 错：拼成 0xE001 去比 0x01E0
if ((hdr_w != FRAME_W) || ({hdr_h[7:0], cur_byte} != FRAME_H))
// 对：cur_byte 是字段最后一个字节＝最高字节，必须拼在左侧
if ((hdr_w != FRAME_W) || ({cur_byte, hdr_h[7:0]} != FRAME_H))
```

`R_HDR_RUNCNT` 分支同一个错：`{hdr_runs[23:0], cur_byte}` 把真实 run 数 1200（`0x000004B0`）拼成 307200（`0x0004B000`）。

后果分别是：
- 高度错 → **每一帧都报 `err_code=2` 尺寸不符**，一帧都播不出来。
- run_count 错 → 解码器一路读到文件末尾才停，`err=4`，**从不进 `R_FRAME_END`、从不发 `ext_wr_done`**，屏幕永远停在上一帧。

两处都在 `rtl/storage/rle_decoder.v` 加了注释记录具体数字（`0xE001` vs `0x01E0`、`0x0004B000` = 307200），因为这个错误的形态是「看起来很像对的数字」。

### §6.2 写组只发 3 拍而非 4 拍

`group_left` 原为 `reg [1:0]`，装载 `2'd3`、减到 1 时收组 → 每组仅 3 拍。组基址每次只前进 3 个字，P1 失效；仲裁器仍按 `wr_base_hold` 内部数满 4 拍，于是**第 4 拍写到越界位置**。

改为 `reg [2:0] group_left`、装 `3'd4`、`group_left == 3'd1` 收组。现象会是「偶发一条横向撕裂」——正是任务书预警的那个。

### §6.3 `ext_wr_done` 电平化

`pack_done` 的定义是 `wr_done_cnt == FRAME_WORDS && !ext_wr_valid`，写完之后它会**持续多拍为真**。直接用它会得到电平而非脉冲，`image_player` 的 `commit_pending` 被反复置位 → 反复翻帧。加 `done_sent` 锁存解决。

### §6.4 `ext_wr_done_sync` 不能用 OR 打宽

`image_player` 侧原本写成 `ext_wr_done | ext_wr_done_d`（把脉冲打宽一拍抗组合直通）。但该分支位于 `commit_pending` 优先级链**最前**，恰好在 `vblank_rise` 那拍会压住翻帧，且会把已提交的帧重新置位。

改为上升沿检出：

```verilog
assign ext_wr_done_sync = ext_wr_done & ~ext_wr_done_d;
```

这样即使外部给的 `done` 过宽，也只产生一个脉冲。

### §6.5 声明位置晚于使用点

`vlog` 报 `(vlog-2730) Undefined variable: 'ext_frame_ready_r'` 等 5 个错误。原因是新增信号声明写在了写口 mux 段（`:531` 之后），而 `commit_pending` 块在 `:228` 就引用它们。已把 `ext_wr_done_d`/`ext_wr_done_sync`/`ext_frame_ready_r`/`reader_src_y`/`reader_row_hold`/`reader_map_ident` 统一上提到 `:159` 附近的声明区。

**这个错误合成工具同样会报**，不是仿真器特有，所以属于必须修的编译错误而非仿真问题。

### §6.6 testbench 侧五个缺陷（一并记录，避免后续重犯）

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | 向量路径 `"vectors/..."` | vsim 的 cwd 是 `sim/msim_work`，须 `"../testbench/vectors/..."` |
| 2 | `CLK_FREQ` 未缩放 | RTL 默认 25 MHz，首帧要等 5,000,000 拍；TB 改 `2_500` |
| 3 | `chk` 参数顺序与 29 个调用点相反 | 字符串被当条件（恒真）、条件被当标签 → **所有失败都打印成空标签** |
| 4 | 写组记账在 stall 拍误开组 | sink 每 5 拍停 1 拍，上升沿检测必须独立于 ack；且开组那拍可能同时是 ack |
| 5 | `localparam FRAME_WORDS = (FRAME_W*FRAME_H)>>1` | 16 位自决定位宽 → 640×480 截成 45056，`>>1` 得 **22528** |

第 3 条是这批里最危险的：它让「所有断言都通过」这个结论本身失效，因为失败信息是空字符串。修好后立刻暴露出第 5 条。

第 5 条的修法是 `localparam [31:0] FRAME_WORDS = ...`——`vlog` 对此零警告。

---

## §7 逐帧比对结论

### §7.1 真素材

| 项 | 值 |
|---|---|
| 文件 | `assets/v2/sdcard/BURN640/SCI.RLE` |
| 大小 | 82,362,927 B |
| 帧数 / 帧率 | 631 帧 / 5 fps |
| 单帧均值 / 最小 / 最大 | 130,528 / 3,612 / 203,484 B |
| 压缩比 | 0.2124 |

### §7.2 前六帧实测（python 独立解析）

| 帧 | 偏移 | 字节 | run 数 | 像素和 | 奇数 run | `run_len=0` 数 |
|---|---|---|---|---|---|---|
| 0 | 0 | 3,612 | 1,200 | 307,200 | 0 | **1,200** |
| 1 | 3,612 | 45,210 | 15,066 | 307,200 | 6,958 | 354 |
| 2 | 48,822 | 86,499 | 28,829 | 307,200 | 16,934 | 221 |
| 3 | 135,321 | 94,761 | 31,583 | 307,200 | 17,934 | 199 |
| 4 | 230,082 | 101,073 | 33,687 | 307,200 | 19,186 | 201 |
| 5 | 331,155 | 107,814 | 35,934 | 307,200 | 20,344 | 196 |

每帧 `sum(run) == 307,200` 全部成立（V-04 判据）。

**帧 0 是个特殊样本**：1,200 个 run 全部等于 256，因此专门覆盖 `run_len==0 → 256`。
**帧 1 是另一半**：15,066 个 run 里 6,958 个是奇数长度，专门覆盖「奇偶半字跨 run 拼接」这条最难对的路径。

### §7.3 逐字比对结果

金标准由 python 独立展开同一份 `SCI.RLE` 得到（`sci_f0_words.hex` / `sci_f1_words.hex`，各 153,600 行），**与 RTL 不共享任何代码**：

```
CASE: real SCI.RLE frame 0 (1200 runs, every run_len=0 meaning 256)
LOAD: card_len=3612 gold_len=153600
FRAME0: groups=38400 beats=153600 word_errors=0
CASE: real SCI.RLE frame 1 (15066 runs, odd lengths exercise the half-word carry)
FRAME1: groups=38400 beats=153600 word_errors=0
```

`word_errors=0` 是逐字 `!==` 比对的结果，不是抽样。`groups=38400 = 153,600/4`，即每个写组恰好 4 拍，P1 逐组成立。

### §7.4 节拍实测（供带宽评估）

| 项 | 值 |
|---|---|
| 帧 0 `ext_wr_done` 完成 | 10,600,040,000 ps = 10.6 ms = **265,001 拍** |
| 帧 1 完成（复位起算） | 24,046,080,000 ps = 24.05 ms = **601,152 拍** |
| 最坏帧预算 | 24 ms |
| @5 fps 预算 | 200 ms |
| **裕度** | **≥ 8 倍** |

帧 1 是 45,210 B / 89 块、run 数是帧 0 的 12.5 倍，仍只用掉 12% 的帧预算。

---

## §8 受影响 testbench 的修复说明

《附录》§13 R-01 列出 3 个例化 `image_player` 的 tb + 1 个例化 `pix_reader` 的 tb。实测**多出两个**：`tb_probe_order.v:115` 与 `tb_probe_pix.v:135` 也例化了 `pix_reader`，R-01 的清单没覆盖到（它们当时不在 grep 结果里，因为 `pix_reader` 写在小写多空格的行首、且这两个 tb 未纳入 git）。合计修复 6 个：

| # | tb | 例化点 | 处理 |
|---|---|---|---|
| 1 | `tb_image_player.v` | `:72` 例化 `image_player` | 补 14 端口 |
| 2 | `tb_display_content.v` | `:47` 例化 `image_player` | 补 14 端口 |
| 3 | `tb_startup_ownership.v` | `:50` 例化 `image_player` | 补 14 端口 |
| 4 | `tb_pix_reader.v` | `:114` 例化 `pix_reader` | 补 5 端口 + V-03 用例 |
| 5 | `tb_probe_order.v` | `:115` 例化 `pix_reader` | 补 5 端口（R-01 未列） |
| 6 | `tb_probe_pix.v` | `:135` 例化 `pix_reader` | 补 5 端口（R-01 未列） |

### §8.1 统一接法（新增端口按缺省值接）

```verilog
// 例化 image_player 的 3 个 tb，一律追加在 .sdram_dq 之后
.ext_wr_mode(1'b0), .ext_wr_valid(1'b0), .ext_wr_addr(21'd0), .ext_wr_data(32'd0),
.ext_wr_dm(4'd0), .ext_wr_done(1'b0), .ext_no_fade(1'b0),
.ext_wr_ack(), .ext_wr_busy(), .ext_frame_ready(), .ext_frame_sel(), .ext_loader_want_blk(),
.src_w(...), .src_h(...)
```

`src_w`/`src_h` 按各自的几何取值以保持恒等旁路：

| tb | `src_w` / `src_h` | 理由 |
|---|---|---|
| `tb_image_player.v` | `W` / `H` | 与本 tb 的 `WIDTH`/`HEIGHT` 一致 |
| `tb_display_content.v` | `16'd640` / `16'd480` | 该 tb 是 640×480 真实 BMP 回归 |
| `tb_startup_ownership.v` | `16'd32` / `16'd16` | 该 tb 用 `WIDTH(32) HEIGHT(16)`，若接 640/480 会让 `src_h > FRAME_LINES` 触发非法退回 |

### §8.2 `tb_pix_reader.v` 的实质新增

不只补端口，还加了 V-03 的判据：

- 新增 `src_w`/`src_h` 可控寄存器（默认 = 几何本身，即恒等）
- 新增逐像素映射校验 `always @(posedge clk_pix)`，比对 `src_y !== ((active_y * src_h) / LINES)`，首错打印
- 新增两个用例：`vertical_map_identity`（`src_h = LINES`）与 `vertical_map_half`（`src_h = LINES/2`，`LINES >= 2` 保护），末尾恢复恒等档，保证后续用例行为与改造前一致

**反证（证明断言不是摆设）**：把 RTL 的判定故意改成 `y_sum > FRAME_LINES`（差一），重跑：

```
MAP_MISMATCH y=1 src_y=0 expected=1 src_h=8 hold=1 ident=1
FAIL: identity src_h matches floor(active_y*src_h/FRAME_LINES)
MAP_MISMATCH y=2 src_y=0 expected=1 src_h=4 hold=1 ident=0
FAIL: half src_h matches floor(active_y*src_h/FRAME_LINES)
SUMMARY: checks=139 errors=2
FAILED: tb_pix_reader errors=2
```

断言确实变红，说明它能抓住差一错误。反证后已还原 RTL（现 `row_step = (y_sum >= FRAME_LINES)`，lint 复验通过）。

**关于 `tb_pix_reader.v` 的 lint 归零**：这个 tb 在改造前是 E0/E1/E2 全 0（`git show HEAD:sim/testbench/tb_pix_reader.v` 实测），所以新增代码不能带进任何 E2。踩到两个坑并已修掉：

1. `scripts/lint_verilog.py` 的 `strip_comments()` 只剥注释、**不剥字符串**，`find_blocks()` 因此会把字符串里出现的 `always` 当成新 always 块的起点，造出一个与后面块重叠的假块，从而把合法的单驱动误报成 E2。原本 `:261` 的标签 `"group acknowledgement always names a real command"` 就触发了这个坑 —— 改词为 `"group acknowledgement must name a real command"`，并在该行上方留了注释说明。
2. 像素校验 always 与 V-03 映射校验 always 原本是两个独立 `posedge clk_pix` 块，而 `find_blocks()` 同样会把 `$display` 格式串里的裸标识符（`y`/`src_y`/`expected`/`src_h`/`hold`/`ident`）当成赋值，于是三个计数器被判定为"多块驱动"。**修法不是改判据，而是把两个观测块合并成一个 `posedge clk_pix` 块**（两者都是纯观测计数，语义上可共存），并把格式串里的裸词改成 `ay`/`sy`/`exp_y`/`sh`/`hl`/`idn`。合并后 `lint` 归零，`tb_pix_reader` 复跑仍是 **checks=139 errors=0 / ALL CHECKS PASSED**，判据一条没放宽。

**`tb_probe_order.v` / `tb_probe_pix.v` 的 lint 状态（如实说明）**：补完端口后这两个 tb 各有 4 条 / 2 条 E2（`frame`/`data`/`wbin`/`arb_addr` 与 `level`/`arb_rd_addr`）。已用「把我加的 7 行删掉再 lint」的方式验证——**这些 E2 在补端口之前就存在**（是探针 tb 自身的多 always 块写法），不是本任务引入，也不在本任务验收口径内（任务书要求的 lint 全 0 指 `rtl/` 域）。两个文件补端口后 `vlog` 退出码 0，编译通过。

### §8.3 `tb_display_content` 需要向量文件

该 tb 用 `$readmemh` 读 `disk.hex`/`golden.hex`/`golden2.hex`，默认路径在当前目录下不存在。正确跑法（沿用历史回归的夹具）：

```
vsim -c -quiet -lib work -gRD_GAP=1 -gRELOAD_COUNT=0 \
  +disk=<repo>/reports/diag_key1_baseline2/disk.hex \
  +golden=<repo>/reports/diag_key1_baseline2/golden.hex \
  +golden2=<repo>/reports/diag_key1_baseline2/golden2.hex \
  -do "run -all; quit -f" tb_display_content
```

缺 `+golden2` 会 `(vsim-7) Failed to open readmem file`，然后 `LOAD: cycles=4185 ... failed=1 error=1` —— 看起来像 RTL 装载失败，实际只是夹具路径没给。

### §8.4 `tb_image_player` / `tb_startup_ownership` 的编译依赖

两个 tb 都例化了 `image_window_mask`，`tb_startup_ownership` 还例化 `gallery_probe`。编译时必须带上：

```
rtl/video/image_window_mask.v    （tb_image_player、tb_startup_ownership）
rtl/storage/gallery_probe.v      （tb_startup_ownership）
```

否则报 `(vsim-3033) Instantiation of 'image_window_mask' failed. The design unit was not found.`——这是**编译依赖缺失**，与端口改动无关。

---

## §9 验收用例对照

| 用例 | 判据 | 结果 |
|---|---|---|
| V-03 垂直行映射 | `src_h=480` 每行读 1 次；小档同一源行读多次 | PASS（2 条新增用例 + 反证） |
| V-04 解压正确性 | SCI.RLE 前 6 帧每帧 `sum(run)==307200` | PASS（6/6） |
| V-04 逐字比对 | 前 2 帧 153,600 字全等 | PASS（`word_errors=0`） |
| — 写组对齐 | 每个写组开组时 `ext_wr_addr[1:0]==0` | PASS（`align_errors=0`） |
| — 写组长度 | 每组恰好 4 拍 | PASS（`groups=38400`） |
| — dm 极性 | 每拍 `ext_wr_dm == 4'h0` | PASS（`dm_errors=0`） |
| — 整帧原子性 | `play_en` 中途拉低不发 `done`、地址回到帧基址 | PASS |
| — 坏 magic | 进 `R_ERR`、`err_code=1`、`underrun=1` | PASS |
| — 帧率分频 | `gap_tick` 周期 = `CLK_FREQ/play_fps` | PASS（`measured=500 expected=500`） |
| Key9 恒等档（t12） | `win_w=640/win_h=480/off_x=0` 逐拍与改造前 `===` | PASS（`compared=512`、`mismatches=0`，全覆盖非抽样） |
| Key9 半屏档（t12） | 一行内取字恰为一行字数、源列步进恒 2、首列源列 0 | PASS（`takes_per_row=[32..32]`、`in_bad=0`、`src_step_bad=0`） |
| Key9 非整除档（t12） | `win_w=48`（4:3）仍恰好取满一整行 | PASS（`takes_per_row=[32..32]`、`in_bad=0`、`spread_bad=0`） |
| Key9 窗口外（t12） | 每拍 `out_valid===0` 且 `pix_rgb565===0` | PASS（`out_bad=0`） |
| Key9 反证（t12） | 故意写坏 `h_acc_next` 后断言变红 | PASS（3 条同时红，恢复后全绿） |

### §9.1 V-05（写口交接无撕裂）未在本任务验证

V-05 要求「日常↔科普切换 10 次无横向撕裂」，需要顶层 `ext_wr_mode` 的交接时序（《附录》§3.4），属 **t8 集成**范围。本任务交付的是 12 端口与内部 mux，交接状态机不在范围内。已在 §10 列出 t8 必须守的时序。

---

## §10 给 t8 集成的约束清单

1. **`ext_no_fade` 在视频模式必须为 1**。为 0 时每帧都会走淡入淡出，帧率被压到 1/FADE_FRAMES。
2. **切换只能在 `!loading && vblank_rise` 那拍**，且切换后至少保持 2 个 vblank 周期（约 33.6 ms）。行扫描中途切写通道会让 `wr_grp_active` 停半组，`WR_STARVE_LIMIT=256` 在 256 拍后强切写 → 撕裂一帧。
3. **方向顺序不可反**：日常→科普 `ext_wr_mode<=1` 同时 `ext_no_fade<=1`；科普→日常必须**先** `ext_no_fade<=0` **再** `ext_wr_mode<=0`。反过来会让切回日常的第一张图闪一次淡入淡出。
4. **SD 四路仲裁**按《附录》§3.4 的 `sd_owner_rle`/`sd_owner_img` 表达式接，`ext_loader_want_blk` 直接给 `img_loader_want_blk`。
5. **`ext_wr_addr` 对齐判据**：`rle_decoder` 每拍 `+1`，组内低 2 位走 1,2,3，只在组首为 0。断言应写「开组时 `[1:0]==0`」，**不要**按 `T7_MUST_TEST.md:27` 的字面「每拍为 0」去断言，那会在功能完全正确时报错。
6. **欠载保持上一帧是自然结果**：`ext_wr_done` 不来 ⇒ `commit_pending` 不置位 ⇒ `front_sel` 不翻 ⇒ 画面保持帧 N。零额外逻辑。
7. **「连续 3 帧欠载自动降 2 fps」未实现，且已定案不做**（设计目标未落地，不是缺陷）。`underrun` 只作标志上报、零消费者；欠载时画面**保持上一帧**（`rle_decoder.v:29`），不插黑、不撕裂、不降帧。2 fps 只是带宽核算的**假设工况**，不是承诺下限。终口径见 `DELIVERY_GUIDE.md` §3.6 / §6.1 D-05。

---

## §11 资源与风险

### §11.1 资源

| 模块 | 变化 | 与预算 |
|---|---|---|
| `rle_decoder` | 新建 | 见下 |
| `pix_reader` | +16 FF、若干 LUT（垂直 DDA）；t12 追加 +16 FF（`h_acc`）与水平 DDA | 预算 +30 LUT（垂直）；Key9 水平另计 +100~140 |
| `image_player` | +97 LUT | 预算 +97 |

`rle_decoder` 新建占用（估算，待 t8 综合实测）：约 250~300 LUT（含 512×8 块缓冲 + 4×32 字缓冲 + FSM + 展开器），**无额外 BRAM**（`blk_buf` 是分布式 RAM，512×8 = 4,096 bit）。

Key9 第 1 步（t12）在 `pix_reader` 内新增的是纯加法/比较/条件减逻辑（`h_acc` 累加器 + 比较器 + 取半字 mux），**零乘法零除法、不占 DSP**。这正是不采用「运行时除法 `(y-off_y)*src_h/win_h`」的原因——现工程 DSP 只剩 10 个（19/29），真除法器会吃光并拖慢时序。

### §11.2 风险

| # | 风险 | 状态 |
|---|---|---|
| R-05 | 视频模式 `ext_no_fade` 未置 1 | 已实现直通，待 t8 接线 |
| R-07 | `pix_reader` 端口漏接 → 仿真 x 传播 | 已显式接 `.src_w(src_w)/.src_h(src_h)` |
| — | 段码 `src_h > 480` → 映射越界 | 已加 `src_ok` 钳位退回恒等 |
| — | 末块短读 | 已加 `at_eof = (pos_cnt >= file_size)` 保护 |
| — | 溢出 run 死锁 | `pixel_done` 时无条件清 `run_left`/`px_half` |
| — | Key9 `win_w < 320` 装不下一整行 | `win_bad` 拒绝并退回恒等档 |
| — | Key9 拍间隔误判为「每 2 拍取 1」 | 已在 §15.8 记录：窗口宽 = 每行字数时每拍必取，源列步进才是 2 |

---

## §12 复现命令

```powershell
# lint
cd D:\FPGA_Compelate\SmartCampusMedia
python scripts\lint_verilog.py rtl                     # 67 文件 E0/E1/E2 = 0
python scripts\lint_verilog.py sim\testbench\tb_rle_decoder.v
python scripts\lint_verilog.py sim\testbench\tb_pix_reader.v

# rle_decoder
cd sim\msim_work
& 'D:\Quartus_APP\modelsim_ase\win32aloem\vlog.exe' -quiet `
    ..\..\rtl\storage\rle_decoder.v ..\..\sim\testbench\tb_rle_decoder.v
& 'D:\Quartus_APP\modelsim_ase\win32aloem\vsim.exe' -c -quiet `
    -lib work -do "run -all; quit -f" tb_rle_decoder     # RESULT: PASS

# pix_reader（注意必须带 +define+SDRAM_SIM_MODEL，否则 sdram_ctrl_wrap 会去
# 例化安路加密核 sdr_as_ram，报 (vsim-3033) ... not found / VSIM_EXIT=12）
& 'D:\Quartus_APP\modelsim_ase\win32aloem\vlog.exe' -quiet +define+SDRAM_SIM_MODEL `
    ..\..\rtl\common\async_fifo.v ..\..\rtl\video\video_timing_gen.v `
    ..\..\rtl\storage\framebuf_arbiter.v ..\..\rtl\storage\sdram_ctrl_wrap.v `
    ..\..\rtl\storage\pix_reader.v ..\..\sim\testbench\tb_pix_reader.v
& 'D:\Quartus_APP\modelsim_ase\win32aloem\vsim.exe' -c -quiet `
    -lib work -do "run -all; quit -f" tb_pix_reader        # 194 checks / 0 errors
```

`sim/work_t4` 库建不出来（`(vlib-35) Failed to create directory. File exists.`），一律用现成的 `sim/msim_work`，或另建一个干净目录 `vlib work` 从零重建（推荐后者做最终验收，排除过期库干扰）。

---

## §13 结论

`rle_decoder` 在真素材上逐字正确，`pix_reader` 与 `image_player` 的端口扩展完成且不改变既有行为（`tb_image_player` 的 13 个既有 CASE 全过可作旁证），六个受影响的 testbench 全部编译通过（四个全绿、两个探针 tb 只补端口），`rtl` 全域 lint 全 0。t7 从本任务起不再被阻塞；剩余工作是 t8 的顶层接线与交接时序（§10）以及随后的 TD 综合验证。

t12 追加的 Key9 水平窗口降采样（§15）在 `tb_pix_reader` 上以 **194 条断言全绿**收尾，恒等档逐拍全覆盖比对 512 拍零差异、半屏档每行取字恰为一行字数且源列步进恒 2、窗口外双零违例 0，反证时三条断言同时变红。**垂直跳行（第 2 步）未实现**，`win_h`/`win_off_y` 端口已声明待用。

## §14 端口冻结清单（供 t8 直接引用）

以下签名自本任务起**冻结**，t8 接线按此写死，不再变更：

```verilog
// rtl/storage/rle_decoder.v —— 25 个端口（t4 的 24 个 + t15 的 sd_grant）
module rle_decoder #(
    parameter CLK_FREQ_HZ   = 25_000_000,
    parameter FRAME_W       = 16'd640,
    parameter FRAME_H       = 16'd480,
    parameter JITTER_FRAMES = 8'd3,
    parameter INIT_WR_BANK  = 1'b1,
    parameter LOOP_PLAY     = 1'b1,
    parameter BLK_BYTES     = 16'd512
)(
    input  wire        clk, rst_n,
    output wire        blk_start,                 // 组合门控 sd_grant，与 blk_addr 同拍有效（t15）
    output reg  [31:0] blk_addr,                  // 扇区号电平
    input  wire        blk_busy, blk_done, blk_err,
    input  wire [7:0]  data_byte,
    input  wire        data_valid,
    input  wire        sd_grant,                  // t15：仲裁器「这一块让给你」电平
    input  wire        play_en,
    input  wire [7:0]  play_fps,
    input  wire [31:0] file_lba, file_size,
    output reg  [15:0] frame_idx,
    output reg         ext_wr_done,               // 单拍：整帧写完
    output reg         ext_wr_valid,
    output reg  [20:0] ext_wr_addr,
    output wire [31:0] ext_wr_data,
    output wire [3:0]  ext_wr_dm,                 // 恒 4'h0（dm[n]=1 屏蔽）
    input  wire        ext_wr_ack, ext_wr_busy,
    output reg  [3:0]  err_code,
    output reg         underrun,
    output wire        want_blk
);

// rtl/storage/pix_reader.v 新增部分（其余端口不变）
// —— t4 阶段（垂直行映射，已落盘）
    input  wire [15:0] src_w, src_h,
    output wire [15:0] src_y,
    output wire        src_row_hold, map_ident
// —— t12 阶段（Key9 水平窗口降采样，已落盘，见 §15）
    input  wire [10:0] active_x,
    input  wire [15:0] win_w, win_h, win_off_x, win_off_y,
    output wire        out_valid

// rtl/storage/image_player.v 新增部分（追加在 sdram_dq 之后，其余端口不变）
    input  wire        ext_wr_mode, ext_wr_valid,
    input  wire [20:0] ext_wr_addr,
    input  wire [31:0] ext_wr_data,
    input  wire [3:0]  ext_wr_dm,
    input  wire        ext_wr_done,
    output wire        ext_wr_ack, ext_wr_busy, ext_frame_ready,
    output wire [1:0]  ext_frame_sel,
    input  wire        ext_no_fade,
    output wire        ext_loader_want_blk,
    input  wire [15:0] src_w, src_h
```

**Key9 端口状态**：`pix_reader` 侧已落盘（t12 第 1 步，见 §15）；`image_player` 侧的 `win_w/win_h/win_off_x/win_off_y/active_x/out_valid` 尚未加，届时按**纯透传**处理（`src_w/src_h` 同款做法，不接内部信号），`active_x` 由 `video_timing_gen` 经顶层送入 `image_player` 再转 `pix_reader`。本节上列 `image_player` 签名因此不受 Key9 影响，t8 可先按此接线。

---

## §15 Key9 第 1 步：`pix_reader` 水平窗口降采样（t12）

> 任务 t12，attempt_id `ec47ed52-40fe-4bd5-95d1-5f93ffe7189d`。只做水平，垂直跳行留待第 2 步。

### §15.1 要解决的问题

用户原话「Key9 切换屏幕大小（1/2 到 1，5 档）」。**终口径以 `docs/plan_v2/KEY9_RULING.md` §1 为准，本文件不重复表述**：横向是 `pix_reader` 消费侧降采样（等比压缩），纵向是 **1:1 裁剪**（不跳行）⇒ 非满屏档为「**横向压缩 + 纵向裁剪**」，**不是等比缩小**；纵向跳行已由 t22 实测否决、t28 裁定不做（`KEY9_RULING.md` §2：需 267 块 BRAM9K，全片 64 块）。曾试过在 `pix_mosaic` 里把 Bresenham 模数从常量 640 换成运行时 `win_w`，逐拍 bit-exact 实测证否：窗口内采到的是源列 160..479 原样直通（`ref_err` 319/320）。根因是 `pix_mosaic` 处在「第 k 拍输入源列 k、第 k 拍输出目标列 k」的流式旁路里，缩小要求输出列 `160+j` 显示源列 `2j`——`j<160` 时源列已流过（要整行缓存），`j>160` 时源列还没到（要等待），单寄存器 hold 只能重复「刚过去的像素」，取不到「更早流过的列」。

因此缩小落在 `pix_reader` 的**消费侧**：它是 SDRAM 顺序读之后唯一的「消费节奏」控制点（读地址由 `framebuf_arbiter` 自主推进，见 §5.2）。

### §15.2 为什么带宽不涨

一个 SDRAM 字含两个相邻像素（偶列低半字、奇列高半字），一行 640 列 = **320 字**。降采样档窗口内**每拍消耗 1 字、只用低半字**，`win_w` 拍正好消耗完 320 字；窗口外 `640-win_w` 拍**零消耗**。一行总消耗恒为 320 字，与改造前逐拍相同，`LEVEL_HI=768` 字（≈2.4 行）余量充足。

### §15.3 实现（`rtl/storage/pix_reader.v`）

```verilog
	localparam [15:0] LINE_PIX16  = PIX_PER_LINE;       // 一行像素数
	localparam [15:0] WORDS_LINE16 = PIX_PER_LINE / 2;  // 一行字数（= 窗口内取字配额）

	assign h_ident   = (win_w >= LINE_PIX16) && (win_off_x == 16'd0);
	assign win_bad   = (win_w == 16'd0) || (win_w < WORDS_LINE16) ||
	                   ((win_off_x + win_w) > LINE_PIX16);
	assign map_key9_ident = h_ident && (win_h == FRAME_LINES16);
	assign use_key9  = !h_ident && !win_bad;      // 恒等档与非法参数都退回原通路
	assign win_w_eff = use_key9 ? win_w : LINE_PIX16;
	assign in_win_x  = use_key9 && de && display_enable &&
	                   (active_x16 >= win_off_x) && (active_x16 < win_end_x);
	assign h_take    = in_win_x && (h_acc >= win_w_eff);
	assign h_pop     = h_take && !fifo_rd_empty;  // 真的取到字才算扣信用
	assign take_word = use_key9 ? h_take : take_even;
	assign h_acc_next = h_pop ? (h_acc + WORDS_LINE16 - win_w_eff)
	                          : (h_acc + WORDS_LINE16);

	always @(posedge pix_clk or negedge rst_n_pix) begin
		if (!rst_n_pix)                 h_acc <= 16'd0;
		else if (!de || !display_enable) h_acc <= win_w_eff;  // 行首/帧首预载满信用
		else if (in_win_x)              h_acc <= h_acc_next;  // 窗口外保持满载不动
	end
```

输出侧（`pix_valid` 走新通路，`out_valid` 与它逐拍相等）：

```verilog
	assign out_valid = use_key9 ? h_pop : pix_valid_raw;
	assign pix_valid = out_valid;
	assign pix_rgb565 = use_key9 ?
		(out_valid ? fifo_rd_data[15:0] : 16'd0) :
		(!out_valid ? 16'd0 :
		(pix_count[0] ? word_hold[31:16] : fifo_rd_data[15:0]));
```

### §15.4 五档 DDA 手算核对

`h_acc` 行首预载 `win_w`，每拍加 `WORDS_LINE16`（=320），取字时减 `win_w`。`win_w` 拍内取字次数恰为 320：

| 档 | `win_w` | 每拍取字概率 | `win_w` 拍内取字数 | 是否整除 |
|---|---|---|---|---|
| 0 | 320 | 1（每拍） | 320 | 是（`h_acc` 恒为 320） |
| 1 | 400 | 4/5 | 320 | 是（每 5 拍取 4） |
| 2 | 480 | 2/3 | 320 | 是 |
| 3 | 560 | 4/7 | 320 | 是 |
| 4 | 640 | — | 恒等旁路 | — |

五档都是精确整除，无累积漂移；`win_w < 320` 被 `win_bad` 拒绝（每拍至多取 1 字，窗口窄于 320 列装不下一整行）。

### §15.5 三个必验数（实测输出）

```
CASE: key9 identity with win_w=64 win_off_x=0
K9_IDENT: compared=512 mismatches=0
CASE: key9 half window win_w=32 win_off_x=16
K9_HALF: rows=8 takes_per_row=[32..32] in_cycles=256 in_bad=0 out_cycles=256 out_bad=0 row_bad=0 spread_bad=0 gap=[1..1] src_step_bad=0
CASE: key9 fraction window win_w=48 win_off_x=8
K9_FRAC: rows=8 takes_per_row=[32..32] in_cycles=384 in_bad=0 out_cycles=128 out_bad=0 row_bad=0 spread_bad=0 gap=[1..2] src_step_bad=0
SUMMARY: checks=194 errors=0 cases=13 geometry=64x8
ALL CHECKS PASSED: tb_pix_reader
```

| 验收项 | 实测 | 判定 |
|---|---|---|
| ① 恒等档逐拍 `===` | `compared=512`（= 64×8 全覆盖，非抽样）、`mismatches=0` | PASS |
| ② 一行不同源列数恰为一行字数、步进恒 2 | `takes_per_row=[32..32]`、`row_bad=0`、`in_bad=0`（每个输出像素都对上 `expected_pixel(2k, y)`）、`src_step_bad=0` | PASS |
| ③ 窗口外双零 | `out_cycles=256`、`out_bad=0` | PASS |

小几何（64×8）与真实几何（640×480）的 `win_w`/`WORDS_LINE16` 关系相同（都是 `win_w == 320`、每拍必取），故结论可直接外推。

### §15.6 两条最有价值的判据（建议保留并推广）

- **「窗口内/外拍数 × 行数」**：`in_cycles == win_w × LINES`、`out_cycles == (PIX_PER_LINE − win_w) × LINES`。这两条能抓住「某一行少取一个字」这种累积漂移，比任何比例类判据都强。
- **恒等档全覆盖比对**：`ident_cycles == PIX_PER_LINE × LINES`，证明恒等性不是抽样而是逐拍。

### §15.7 反证（证明断言不是摆设）

把 `rtl/storage/pix_reader.v` 的 `h_acc_next` 故意改成 `(h_acc + WORDS_LINE16 - win_w_eff + 16'd1)`（多 1），重跑：

```
K9_FRAC: rows=8 takes_per_row=[33..33] in_cycles=384 in_bad=232 out_cycles=128 out_bad=0 row_bad=8 spread_bad=8 gap=[1..2] src_step_bad=0
FAIL: fraction window still takes exactly PIX_PER_LINE/2 per row
FAIL: fraction window keeps strictly increasing source columns
FAIL: fraction window take positions follow the DDA segments
SUMMARY: checks=194 errors=3
FAILED: tb_pix_reader errors=3
```

**三条断言同时变红**（`row_bad=8` = 每行都多取 1 字、`in_bad=232` = 后续源列全错位、`spread_bad=8` = 取字位置偏离 DDA 段）。恢复后复跑 `checks=194 errors=0`，`lint rtl` 67 文件 E0/E1/E2 全 0。

> 注意：`win_w=32` 的半屏档（`h_acc_next` 恒等）抓不到这个错，**只有非整除档（`win_w=48`）能暴露**。这也是必须同时保留整除档与非整除档用例的原因。

### §15.8 调试中踩到的三个 tb 侧坑（都属「静默错」一族）

1. **`k9_gap_max` 初值 `-1` 被无符号求值吃掉**。`active_x` 是 `[10:0]` 无符号，`(active_x - k9_prev_x)` 混合表达式按无符号求值，`-1` 变成 `32'hFFFF_FFFF`，`k9_gap > 32'hFFFF_FFFF` 恒假 → `k9_gap_max` 一次都没更新（实测 `gap=[1..-1]` 末尾那个 `-1` 就是证据）。**修法：初值改 `0`，并把差值先存进 `integer k9_gap` 再比较**。这是本项目同一族错误的第三次（前两次：`osd_caption.v` 的 `{3'b011, idx_ones}` 位宽错、`tb_rle_decoder.v` 的无位宽 `localparam` 截断成 22,528）。
2. **「拍间隔」与「源列步进」被写进同一条断言**。`win_w == WORDS_LINE16`（320）时 `h_acc_next = h_acc`，窗口内**每拍必取**，所以 `active_x` 相邻差恒为 **1**；而源列步进是 **2**（每个字只输出低半字=偶列）。两者是不同事实，必须分开判：`chk(k9_gap_min == 1 && k9_gap_max == 1, ...)` + `chk(k9_src_step_bad == 0, ...)`。**若为了让它变绿去改 RTL 让拍间隔变 2，结果是每行只取 160 字、只画源列 0,4,8,… 的左半屏 —— 真退化。**
3. **`assign` 级多驱动与重复声明，`lint` 与 `vlog` 都查不出**。`pix_reader.v` 曾同时存在 `wire pix_valid_raw;`（前置声明）与 `wire pix_valid_raw = ...;`（带初值再声明一次）→ `(vlog-2388) already declared`；以及 `out_valid` 两处 `assign` → 多驱动。用最小探针实测：`lint_verilog.py` 报 E0=0/E1=0/E2=0「通过」、`vlog` 退出码 0，**两个工具都静默**。唯一可靠判据是 `vsim` 实跑。

### §15.9 第 2 步（垂直跳行）的状态

**已定案，不做**（t22 实测否决、t28 裁定；终口径见 `docs/plan_v2/KEY9_RULING.md` §1）。现状陈述（中性事实）：`win_h`/`win_off_y` 端口已声明并接入判据（`map_key9_ident` 用 `win_h` 做全局恒等标志），但不驱动任何逻辑，因此**非满屏档是「横向压缩 + 纵向裁剪」，不是等比缩小**。**这不是「未实现」，是「物理上限约束下的主动取舍」** —— 顺序 FIFO 需整帧缓存 240×320 = 76,800 字 = **267 块 BRAM9K**（16 位一字也要 133 块、RGB565 只存需跳过行也要 67 块），全片仅 **64 块**；**267 是下界，不是估值**。

~~第 2 步的做法（**配额式垂直跳行，零 BRAM / 零 DSP / 无乘除**）~~ ← **🕓 该估算已作废，仅存作认识演进**（`KEY9_RULING.md` §2 实测：被丢弃的偶数行必须在整帧流过去之前留住，窗口外那 `640 − win_w` 拍只够读、不够存）。原文如下：每面板行消耗 `320 × (s_j − s_{j−1})` 字，其中窗口内 `win_w` 拍消耗 320 字、窗口外 `640−win_w` 拍消耗剩下的 `320×(Δ−1)` 字（整行读出后直接丢弃）。逐档核算见下表，**档 0 是零余量**（窗口外可用 320 拍、需丢 320 字，一拍算术误差就让整帧错行）：

| 档 | `win_w×win_h` @off | Δ=480/win_h | 窗口内耗字 | 窗口外需丢 | 窗口外可用拍 | 余量 |
|---|---|---|---|---|---|---|
| 0 | 320×240 @(160,120) | 2.0 | 320 | 320 | 320 | **0** |
| 1 | 400×300 @(120,90) | 1.6 | 320 | 192 | 240 | 48 |
| 2 | 480×360 @(80,60) | 4/3 | 320 | 107 | 160 | 53 |
| 3 | 560×420 @(40,30) | 8/7 | 320 | 46 | 80 | 34 |
| 4 | 640×480 @(0,0) | 1.0 | 320 | 0 | 0 | 恒等（硬判绕过） |

**五档全部可行**——窗口外那 `640 − win_w` 拍本来就是空的，正好用来把下一条源行读出来丢掉。**不需要行缓存**（早前「行重复必须缓存 ≈1 块 BRAM9K、纯跳行带宽不成立」的结论已作废，见 §5.2 的更正框）。

`row_extra = s_j − s_{j−1} − 1`（0 或 1）必须**用与 `src_y` 同一套 DDA 派生**，不能另算一套。实现上用**一个垂直配额累加器**（每窗口行开始装载配额、每取一字减一、减到 0 停；配额值做成 5 个常量或一个 case，零乘法零除法），窗口内复用既有 `h_acc` 信用 DDA，窗口外按同一节奏取字但丢弃。非窗口行不取字、FIFO 保持——`framebuf_arbiter` 读到 FIFO 满自然停，这是既有流控，不用新做。

---

## §16 `rle_decoder` 的 SD 总线仲裁端口 `sd_grant`（t15）

> 任务 t15，attempt_id `085f7837-894f-470f-b9cb-4901ad897296`。

### §16.1 为什么必须加这个端口

顶层把 SD 总线扩成五路仲裁（`probe > gallery > wav > rle > bmp`）。加这个端口之前，`rle_decoder` 是**无条件**拉 `blk_start`、无条件给 `blk_addr` 的：一旦与 `wav_stream_player` 并行，同一拍两个消费者都会把自己的扇区号放上总线，`sd_spi_ctrl` 取谁取决于布线——最常见的表现是**把 WAV 扇区当游程解码**，几百字节后 `err_code=4`、屏上花屏或停帧。日志里只有一行错误码，反推不到「抢总线」这个原因。

### §16.2 三个信号的语义（与 `wav_stream_player` 完全一致）

| 信号 | 方向 | 语义 |
|---|---|---|
| `want_blk` | 出，电平 | 「我需要总线」。**必须提前拉高**，不能等到真要发请求那一拍才拉，否则仲裁器至少晚一拍才给 grant。 |
| `sd_grant` | 入，电平 | 「仲裁器把这一块让给你」。由顶层组合给出（`sd_owner_rle = sd_owner_playseg && !wav_want_blk && rle_want_blk`），**没有打拍**。 |
| `blk_start` | 出，与 `blk_addr` 同拍 | 「本模块发起的读块请求」。**必须与 `sd_grant` 相与**，见 §16.3。 |

`want_blk` 的现有实现已经满足「提前拉高」：

```verilog
assign want_blk = play_en && !eof_stop &&
                  (state != R_FRAME_END) && (state != R_ERR) &&
                  ((state == R_NEXT_BLK) || !blk_ready);
```

`!blk_ready` 让它在「当前块还剩若干字节、下一块马上就要」时就已为高，比进 `R_NEXT_BLK` 早一整块的时间，因此不需要为了提前而额外加状态。

### §16.3 `blk_start` 必须是组合门控，不能是寄存器输出（本节最重要的一条）

**错误写法**（只把 `sd_grant` 加进 FSM 判定条件）：

```verilog
if (!req_sent && sd_grant) begin
    blk_start <= 1'b1;      // 拍 N 判定 grant，拍 N+1 才输出
    blk_addr  <= file_lba + blk_index;
    req_sent  <= 1'b1;
end
```

时序推演：拍 N 判定时 `sd_grant=1`；拍 N+1 `blk_start` 才为 1，而这一拍 `sd_grant` 可能已经掉低（顶层仲裁是**组合**的，音频随时能抢走）。此时顶层 `sd_arb_start = |(sd_owner_* & blk_start)` 里 `sd_owner_rle=0`，这一位根本不参与归并 → `sd_spi_ctrl` 收不到 `blk_start`；而 RTL 已经把 `req_sent` 置 1，认为请求发出去了 → 永远等不到 `blk_done` → **死等**。`tb` 里 `sd_grant` 恒接 1 时永远测不出来。

**正确写法**（寄存器保持语义不变，外面与 `sd_grant` 相与）：

```verilog
output wire blk_start;          // 端口类型改为 wire
reg         blk_start_int;      // 内部仍用寄存器保持「保持到 blk_busy」的语义

assign blk_start = blk_start_int && sd_grant;
```

效果：`sd_grant` 掉低那拍 `blk_start` 立刻变 0，`sd_spi_ctrl` 不会启动；`sd_grant` 恢复那拍 `blk_start` 又变 1，`sd_spi_ctrl`（只在 `init_done && blk_start` 那一拍响应）看到干净的单拍请求。全程 `req_sent` 不需要回退，因为请求**没有丢**，只是被延迟到 grant 有效的那些拍。

同一处还有两处配套改动：块缓冲写口 `blk_start_d <= blk_start_int;`、以及 `if (blk_start_int && !blk_start_d) wr_ptr <= 10'd0;`——两者都改用 `blk_start_int` 而不是门控后的 `blk_start`，否则 grant 抖动会把块缓冲的写指针重置多次。

### §16.4 为什么这里不需要 `wav_stream_player` 那样的 pending 锁存

| 维度 | `wav_stream_player` | `rle_decoder` |
|---|---|---|
| 请求脉冲来源 | 内部 `fat32_reader` 的 `S_REQ` 态，**只抬一个时钟**就进下一态，脉冲不可控 | 自己的 FSM 走到 `R_NEXT_BLK` 才发，**可原地等** |
| 脉冲丢了会怎样 | `fat32_reader` 永远等 `blk_done` → 死等超时，现象是「卡里明明有这个文件却报超时」 | 同左，但因为可原地等，不会发生 |
| 需要的机制 | 锁存 `fr_req_pending`，拿到 grant 那拍再发干净单拍（`fr_issue = blk_owner_fat && sd_grant && fr_req_pending`） | 无 pending，`req_sent` 只记录「本块脉冲已发过」，不是 pending 锁存 |

**别照抄 pending**：`req_sent` 已经是 FSM 内的状态标志，再加一层锁存会让「FSM 与锁存对哪一块 outstanding 的判断可能不一致」，是纯粹的状态重复。

### §16.5 等待 grant 无超时（有意为之）

`R_NEXT_BLK` 里 `sd_grant` 为低时 FSM 原地停，**不设超时计数、不跳 `R_ERR`**。理由：仲裁器对每个电平请求最终都会服务；唯一「永远拿不到 grant」的情况是对端模块死了，那是顶层看门狗的职责。本地超时反而会把「总线慢」变成「静默冻帧且一直报 no error」，更难诊断。

### §16.6 tb 侧的三条断言与一条元断言

`sim/testbench/tb_rle_decoder.v` 的 SD 总线仲裁模型与监视器：

| 断言 | 判据 | 抓什么 |
|---|---|---|
| P1 | `blk_start && !sd_grant` → `grant_violations++` | **电平性质**，不是边沿性质。只在上升沿查会漏掉「FSM 在拍 N 判定、请求在 N+1 出现、而 grant 恰在 N+1 掉低」这个真实危险，也就是 §16.3 那个死等。 |
| P2 | `blk_start` 上升那拍 `blk_addr === file_lba + dut.blk_index` | 地址与脉冲描述同一块，不会差一拍 |
| P3 | `req_sent` 上升后 20000 拍内必须出现 `blk_start && sd_grant` 的拍，否则 `grant_pulse_missing++` + `GRANT_LOST` | 请求不丢（不是「一拍内必发」，因为组合 grant 可以被抢走，延迟是允许的） |
| **元断言** | `grant_low_cycles > 100` | **保证上面三条不是空真**。`sd_grant` 一旦被写坏成恒 1，P1 永远绿——这正是本任务第一版 `checks=30 errors=0` 却打了 4 条 `GRANT_VIOLATION` 的根因 |

tb 的 grant 生成器必须**真会掉低**，并且要有一个竞争消费者。第一版的生成器有两个缺陷：①`sd_grant` 从 `blk_active` 来、`blk_active` 又从 `blk_start` 来，构成 `sd_grant → blk_start → blk_active → sd_grant` 的环（真仲裁器看的是**请求** `want_blk`，不是「对方已经发出去了」）；②没有竞争者，grant 从不掉低，§16.3 那条性质根本不可测。修好后的生成器：

```verilog
// 竞争消费者：wav_stream_player 周期性抢总线（顶层仲裁是组合的，随时能抢走）
wav_want <= (wav_phase < WAV_WIN);

always @(posedge clk or negedge rst_n) begin
    if (blk_done)                    blk_active <= 1'b0;
    else if (blk_start && sd_grant)  blk_active <= 1'b1;   // 拿到手的块保持到完成
    if (grant_force_low)                                  sd_grant <= 1'b0;
    else if (blk_active)                                  sd_grant <= 1'b1;
    else if (wav_want)                                    sd_grant <= 1'b0;
    else if (want_blk && (grant_phase >= GRANT_LOW_WIN))  sd_grant <= 1'b1;
    else                                                  sd_grant <= 1'b0;
end
```

`blk_active` 用 `blk_start && sd_grant`（而不是 `blk_start`）置位，既是「承诺」又不是环：request 决定 grant，grant 与 request 共同决定 commitment，commitment 决定后续 grant。

### §16.7 实测（干净库 `sim/_t15_run`，`vlib work` 重建）

```
vlog rle_decoder.v + sd_spi_ctrl.v + fat32_reader.v + tb_rle_decoder.v  → VLOG_EXIT=0
vsim -c -quiet -lib work -do "run -all; quit -f" tb_rle_decoder          → VSIM_EXIT=0
# PACING: measured=500 expected=500
# FRAME0: groups=38400 beats=153600 word_errors=0
# GRANT0: violations=0 addr=0 missing=0 waits=8 long_denials=8 low=259699 high=5489
# FRAME1: groups=38400 beats=153600 word_errors=0
# GRANT1: violations=0 addr=0 missing=0 waits=62 long_denials=60 low=547205 high=55296
# HEADER: state=7 err_code=1
# CASE: a withheld grant parks the request instead of claiming the bus
# GRANT: latency=1 low_max=601 waits=65 long_denials=63
# FRAME_DELAYED: groups=38400 beats=153600 word_errors=0
# TB_RLE_DECODER SUMMARY: checks=58 errors=0
# RESULT: PASS
```

基线未退化：`FRAME0`/`FRAME1` 各 `beats=153600 word_errors=0`、`HEADER: state=7 err_code=1`。`checks` 从 30 涨到 58。`low_max=601` 说明最长拒授 601 拍，`latency=1` 说明释放后一拍内发脉冲。

### §16.8 两处反证（都做过，证明断言不是摆设）

**反证一：去掉 `blk_start` 的组合门控**（`assign blk_start = blk_start_int && sd_grant;` → `= blk_start_int;`）：

```
# GRANT_VIOLATION t=4540940000 blk_start high while sd_grant is low
# FAIL: blk_start is only raised on a cycle where sd_grant is high
# GRANT1: violations=96 addr=0 missing=0
# FAIL: frame 1 saw no blk_start without a grant either
# FAIL: blk_start never rises without sd_grant
# TB_RLE_DECODER SUMMARY: checks=58 errors=3
```

**3 条变红，`violations` 累计到 96 次**。注意：如果 P1 只查上升沿（第一版写法），这条反证**不会变红**——这正是把 P1 从边沿改成电平的原因。恢复后复跑 `checks=58 errors=0`。

**反证二：把 tb 的 `sd_grant` 写回恒 1**（元断言的作用）：

```
# FAIL: the decoder really parked in R_NEXT_BLK waiting for a grant
# FAIL: sd_grant really goes low (the checks above are not vacuous)
# GRANT0: violations=0 addr=0 missing=0 waits=0 long_denials=0 low=33 high=264970
# FAIL: the request stays parked for the whole denial
# FAIL: a denial window of at least three cycles was seen
# FAIL: a granted request pulses within one cycle
# FAIL: the granted pulse carries the sector of the block it asks for
# FAIL: the delayed frame writes 153600 words
# FAIL: at least one block request had to wait for the grant
# FAIL: at least one denial lasted three cycles or more
# FAIL: the grant really does go low (generator is not tied to 1)
# TB_RLE_DECODER SUMMARY: checks=58 errors=10
```

**10 条变红**，其中 `low=33`（复位后那几拍）证明元断言真的在数 `sd_grant` 的低电平拍数。这一条尤其重要：**没有元断言，`sd_grant` 恒 1 的 tb 会报 `errors=0` 全绿，而 P1 是空真**。

### §16.9 tb 侧另有两处判据在加竞争消费者后才暴露

1. **CASE 3 的「abort 恰好切一组」判据过严**：有竞争总线时 abort 可能正好落在两组之间，那一组都没切（`abort_partial == 0` 也合法）。改成 `abort_partial <= 1`。这不放宽判据——`framebuf_arbiter` 会自己补齐该组的 4 个总线槽（补拍 `DM=4'hF` 全屏蔽），截断组不留下半截数据；而且该帧永不发 `ext_wr_done`、永不被提交，屏上什么都不会出现。
2. **P3 不能要求「长拒后下一拍必发」**：组合 grant 可以被音频在下一拍抢走，延迟是合法行为。改成「`req_sent` 上升后 20000 拍内必须有落在 grant 高电平期的脉冲」，把「请求丢失导致的死等」与「合法延迟」区分开，并给出具名失败 `GRANT_LOST` 而不是等全局看门狗超时。

### §16.10 教训小结

- **`$display` 打印了违例但没进 `chk()`，等于没测**。第一版打了 4 条 `GRANT_VIOLATION`，`SUMMARY: checks=30 errors=0` 照样报绿。断言必须**朝失败时变红的方向**设计。
- **元断言不是冗余**。凡「某性质在参数取极值时自动成立」的场合，都要配一条证明参数真的动过的断言（这里 `grant_low_cycles > 100`）。
- **寄存器输出 + 组合仲裁 = 一拍漏洞**。凡是「下游组合归并、上游寄存器输出」的握手，都要在输出端做组合门控，而不是只在上游判定条件里加门控。

---

## §17 `file_lba` / `file_size` 的产出：`gallery_probe` 兼探 `SCI.RLE`（t19 已实现）

> **状态：已实现并验证完毕（t19，2026-11-02）。方案 A 落地，B/C 因 DSP 物理超限被否决。**
> 本节前半保留 t15 时的「缺口记录」原貌（历史价值：说明当时为什么卡住），后半是落地实现与资源实测。

### §17.1 缺口（t15 时记录，现已闭合）

`rle_decoder.file_lba[31:0]` 与 `file_size[31:0]` 在**全 rtl 里没有任何模块产出**。t7-A 因此不能例化 `u_rle`：接常量 0 会让解码器去读扇区 0（引导扇区），判 magic 失败 → `err_code=1`，屏上表现是「科普模式永远停在第一帧图库画面」，日志里只有一行错误码，反推不到 LBA 算错。

三个候选方案（资源数字来自 `reports/diag_key1_fifo_backpressure_20261101/area.txt` 层级表：`u_gallery` 里 `u_fat` = 805 lut / 179 reg / 6 dsp；`u_loader` 里 `u_fat` = 821 lut / 179 reg / 6 dsp；当前 LUT **19,353/19,600 = 98.74%，余 247**（t7-B 集成综合实测，见 `RESOURCE_BUDGET.md` §3.4）；DSP 24/29）：

| 方案 | 做法 | 增量 | 评价 |
|---|---|---|---|
| **A** | 让 `gallery_probe` 兼探 `SCI.RLE`，把 `fat32_reader` 的 `file_size/first_cluster/out_data_begin/out_fat_begin/out_spc` 五个输出引出来（现全部空连接，`gallery_probe.v:179/:183`） | **+30~60 LUT / 0 DSP** | 复用现成实例。`done` 晚一轮（多一次 FAT32 定位，发生在开机扫描期，用户不可见）。**（2026-11-02 captain 已定为唯一方案，t19 派给 rtl-storage：四输出 `rle_lba`/`rle_size`/`rle_found`/`rle_fail`，≤60 LUT、零 DSP、零 BRAM；等探针实测后并入第四版口径。）** |
| **B** | 顶层加第四份 `fat32_reader` | **+800~850 LUT / +179 reg / +6 DSP** | 🔴 **已物理超限，不再作为候选**：LUT 余量仅剩 247，且更硬的是 **DSP 24 + 6 = 30 > 29，综合直接失败**（t7-B 实测已 24/29，2026-11-02 更正；原按预算 19 算得 25/29 = 86.2% 是错的）。LUT 侧总量约 20,153~20,203 / 102.8%~103.1%，**连硬上限都超了** |
| **C** | `rle_decoder` 内部例化 `fat32_reader` | 同 B | 破坏 `rle_decoder` 的「纯字节流消费者」职责边界，tb 的 `sd_grant` 生成器要重写 |

换算本身极便宜（`fat32_reader.v:118-138` 已输出全部原料，`img_loader.v:191-195` 与 `wav_stream_player.v:311-313` 逐字同构）：

```verilog
wire [31:0] clu_off     = first_cluster - 32'd2;
wire [34:0] clu_off_shl = {3'd0, clu_off} << out_spc;   // spc 恒 2 的幂，VBR 阶段已校验
wire [31:0] file_lba    = out_data_begin + clu_off_shl[31:0];
```

**当前状态（t15 时）：等 captain 裁决（A / B / C / 暂不动）**。在裁决前 t7-A 只跑 elaborate + optimize_rtl，`u_rle` 及其 25 根线全部推到 t7-B。t15 本身**不实现任何方案**，只记录缺口。

> 裁决结果（2026-11-02）：**采纳方案 A**，派 t19 给 rtl-storage 实现。B/C 永不作候选，硬理由见上表：DSP 余量只剩 5 个（24/29），`fat32_reader` 每份 6 个 DSP，再来一份就是 30 > 29，**综合直接失败**——这不是「资源紧张」而是「物理上放不下」。

### §17.2 方案 A 的实现（t19）

`gallery_probe.v` 从 289 行扩到 **461 行 / 32,845 B / MD5 `1451AD6697035B7474E19485B4E11B96`**。
（行数与字节数含 captain 要求补写的 `name_sel` 证据注释；注释不影响综合，`#lut` 复跑仍是 1260。）四个新输出（全部**电平**，保持到复位或 rescan）：

```verilog
output reg  [31:0] rle_lba,      // SCI.RLE 起始扇区号（rle_found=0 时恒 0）
output reg  [31:0] rle_size,     // SCI.RLE 字节数（rle_found=0 时恒 0）
output reg         rle_found,    // 1 = 卡上确实存在 SCI.RLE；上层必须靠这一位判断
output reg         rle_fail      // 1 = 探测时遇到真故障（不是"没找到"）
```

**四个输出都声明为 `reg` 而不是 `wire`**：它们的值在 `G_RUN` 的 RLE 轮里被锁存，用 `always` 块赋值，避免再引一层组合网络。这一选择本身也省了 LUT（见 §17.4）。

#### 关键设计一：不新增状态，在 `G_ARST ↔ G_RUN` 之间复用一轮

FSM 仍是原来的 **5 态**（`G_IDLE=0, G_ARST=1, G_RUN=2, G_DONE=3, G_FAIL=4`），没有 `G_RLE`。

复用的依据：换探测目标（`rle_probe` 0→1）与发 `f32_start` 之间已经隔着一个 `G_ARST`（`rst_cnt` 数到 5 才发 start，6 拍间隔），而 `target_name` 每拍在 `G_ARST` 里刷新，所以新短名比 start 早 6 拍稳定。原来的「枚举完图库 → 去 DONE」改成了「枚举完图库 → 再探一轮 SCI.RLE → 才去 DONE」。

```verilog
// G_RUN 现在有三个分支
if (rle_phase) begin               // ① RLE 轮的结果
    if (f32_found && rle_spc_bad) begin rle_fail <= 1'b1; st <= G_DONE; end
    else if (f32_found)  begin rle_found<=1; rle_lba<=rle_lba_c; rle_size<=f32_size; st<=G_DONE; end
    else if (f32_fail)   begin if (f32_err != 4'd4) rle_fail <= 1'b1; st <= G_DONE; end
end
else if (f32_found) begin          // ② 图库命中第 probe_idx 张
    hit_cnt <= probe_idx;
    if (probe_idx == MAX_COUNT) begin first_img_req<=1; rle_probe<=1; rle_phase<=1; rst_cnt<=0; st<=G_ARST; end
    else begin probe_idx <= probe_idx + 1'b1; rst_cnt <= 3'd0; st <= G_ARST; end
end
else if (f32_fail) begin           // ③ 图库没这张
    if (f32_err == 4'd4) begin     //    err=4 = 文件不存在，是正常情形
        if (hit_cnt != 0) first_img_req <= 1'b1;
        rle_probe <= 1'b1; rle_phase <= 1'b1; rst_cnt <= 3'd0; st <= G_ARST;
    end else begin err_code <= f32_err; st <= G_FAIL; end   // 真故障：不探 RLE 了
end
```

**三种 RLE 结果的区别是本节最重要的语义**（对齐 §17.3 的接线约束）：

| 情形 | `f32_found` / `f32_fail` | `rle_found` | `rle_fail` | `st` 去向 |
|---|---|---|---|---|
| 找到 SCI.RLE | found=1 | **1** | 0 | `G_DONE` |
| 卡上没放视频（err=4） | fail=1, err=4 | **0** | **0** | `G_DONE`（**不进 G_FAIL**） |
| 文件在但 spc 非法 | found=1, `rle_spc_bad` | 0 | **1** | `G_DONE` |
| 读卡/DIR 真故障 | fail=1, err≠4 | 0 | **1** | `G_DONE` |
| 图库阶段就真故障 | fail=1, err≠4 | 0 | 0（未探） | `G_FAIL` |

「卡上没放视频」**不是错误**——这是最常见的出厂态（用户不放视频就该正常用图库）。所以它必须 `rle_fail=0` 且不改变 `err_code`、不把整个 `gallery_probe` 判失败。

#### 关键设计二：簇号 → LBA 换算（与 `img_loader.v:191-195` 同构，但收窄到 24 位）

```verilog
wire [23:0] rle_clu_off = f32_first[23:0] - 24'd2;   // 簇号 ≥2，24 位覆盖 16M 簇
wire [2:0]  rle_spc_shf;                             // FAT32 合法 spc 是 2^0..2^7
wire [23:0] rle_clu_shl;
wire [31:0] rle_lba_c;
wire        rle_spc_bad = (f32_spc == 8'd0) || ((f32_spc & (f32_spc - 8'd1)) != 8'd0);

assign rle_spc_shf = { f32_spc[7]|f32_spc[6]|f32_spc[5]|f32_spc[4],
                       f32_spc[7]|f32_spc[6]|f32_spc[3]|f32_spc[2],
                       f32_spc[7]|f32_spc[5]|f32_spc[3]|f32_spc[1] };
assign rle_clu_shl = rle_clu_off << rle_spc_shf;
assign rle_lba_c   = f32_data_beg + {8'd0, rle_clu_shl};
```

三点值得记下来：

1. **`rle_spc_shf` 用位译码而不是比较器链**。原写法（`img_loader.v` 同款）是 7 个 8 位 `>=` 比较器串起来，实测 43 LUT。因为 FAT32 的 `spc` 合法值**必然**是 2 的幂，`log2(spc)` 就是「置位那一比特的下标」，于是可以直接用三个 OR 门拼出三位结果：`bit0 = 有 bit1/3/5/7 任一置位`、`bit1 = 有 bit2/3/6/7`、`bit2 = 有 bit4/5/6/7`。3 个 LUT4 顶掉 7 个比较器。
2. **`rle_spc_bad` 比 captain 原要求（`spc > 128`）更严**：拦**所有非 2 的幂**（含 0）。理由：比较器链对 255 这类非法值会老老实实译成移位 7，LBA 算错但**一路不报错**，现场现象是「视频永远停在第一帧」，从现象反推不到是 `spc` 坏。非法值统一 `rle_fail<=1`，让上层把视频路关掉。
3. **24 位而非 32 位**：`rle_clu_off` 只需覆盖到「卡容量 / 簇大小」。SD 卡上限 4 GB = 8,388,608 扇区 = 23 位，取 24 位留 1 位余量。移位结果 ≤ 2^23 同样落在 24 位内。这一步把桶形移位器从 35×4 降到 24×3。

#### 关键设计三：双模 `target_name`

```verilog
localparam [87:0] RLE_NAME = { 8'h45, 8'h4C, 8'h52,        // 'R' 'L' 'E' → 扩展名
                               8'h20, 8'h20, 8'h20, 8'h20, 8'h20,   // 5 个填空
                               8'h49, 8'h43, 8'h53 };      // 'S' 'C' 'I' → 主名
...
reg [87:0] name_sel;    // 在 G_ARST 每拍刷新
...
.target_name(name_sel),
```

`fat32_reader` 的 `name_auto = (target_name[7:0] == 8'h00)`：给 0 = 按 `img_index` 自动拼 `IMGnnn.BMP`，给非 0 = 通用模式按 8.3 短名精确匹配。所以 `rle_probe` 只切这一个输入。

**`name_sel` 是寄存器不是组合三目**，这是 captain 的降本建议之一。但实测收益远小于预估（见 §17.4）：88 位「常量 vs 常量 0」的 2 选 1 被综合器优化成 FF 的 D 端直连，几乎不花 LUT，改寄存器只省 9。

**`G_ARST` 里刷 `name_sel` 为什么不缺一拍**：`rle_probe` 从不在 `G_ARST` 期间改变——它在 `G_RUN` 的两个分支里与 `st <= G_ARST` **同拍**赋值（`rle_probe<=1` 或 `rle_probe<=0`），`G_ARST` 分支内没有任何 `rle_probe <=`。所以进 `G_ARST` 第一拍时 `rle_probe` 已是本轮目标，`name_sel` 当拍就刷对，而 `f32_start` 要到 `rst_cnt` 数到 5 才拉高。**不存在「刷之前先拿错名字」的窗口，因此不需要 `f32_start_d` 上升沿检测。**

#### 关键设计四：`out_fat_begin` 为什么仍然不接

`fat32_reader` 有五个输出，本模块只接了四个（`first_cluster` / `file_size` / `out_data_begin` / `out_spc`），`out_fat_begin` 保持空连接。理由不是「用不上」，而是**接了也没有消费者**：

`rle_decoder` 按 `file_lba + blk_index` 顺序读扇区，**从不走簇链**（SCI.RLE 由生成脚本写成连续区段）。本模块对外只承诺两件事：文件从哪个扇区开始（`rle_lba`）、有多长（`rle_size`）。FAT 表起始扇区没有任何模块需要。凑齐输出再悬空只会新增 `HDL-5314`/`HDL-5323` 告警。将来真要支持碎片化文件，正确做法是在 `rle_decoder` 侧接 FAT 表，而不是从这里引一根没人用的线。

### §17.3 给顶层集成（t8）的三条硬约束

这三条已由 captain 转给 rtl-integ，**接错了现象全是「不报错」的那种**：

1. **不能用 `rle_lba == 0` 判断「没有视频」**。扇区 0 是合法扇区（虽然不可能是文件起点，但约定比巧合重要）。**必须看 `rle_found`**：`rle_found=1` 才把 `rle_lba`/`rle_size` 送进 `rle_decoder`。
2. **「卡上没有 SCI.RLE」= `rle_found=0 && rle_fail=0`，是正常情形**，不报错、不点错误灯、不阻止图库正常播出。只有 `rle_fail=1` 才单独上报（视频模式不可用）。
3. **`rescan` 瞬间 `rle_*` 四根会被清 0 一拍**（`rescan` 分支无条件清零）。顶层必须**锁存**并在 `!rle_play_en` 时门控——否则重启扫描的同一个瞬间，正在播放的视频会看到 `rle_found` 掉低、`rle_lba` 变 0，表现为「按 KEY10 重扫时视频闪一下黑屏」。

### §17.4 资源实测：8 个变体，结论是 +266 LUT

探针工程独立建在 `project/t19_probe/`，每个变体一套 `.al` + `flow_<tag>.tcl`，全部 `EXIT=0` 且打印 `PROBE_DONE-<tag>`：

> **口径说明（必读，否则对不上数）**：**`old` 是 `git HEAD:rtl/storage/gallery_probe.v` 的逐字副本（286 行），不是「删了某一行」的版本。** HEAD 版的 `fat32_reader` 例化里**本来就没有 `target_name` 端口**——那个端口是 t19 才加的；所以不存在「old 删了一行」这回事，t19 新增的这个端口本身就是 +266 的一部分。**`old3` 才是同端口严格对照**：`git show HEAD:` 原版 + 只把 `.target_name(88'd0)` 显式接常量 0。实测 `old` 与 `old3` 的 `#lut` **完全相同（都是 994）**，证明「把新端口接常量 0」不改变基线，994 是可信的对照起点。

| 变体 | 改动 | `#Total_luts` | `#lut` | `#reg` | `#bram` | `#dsp` |
|---|---|---|---|---|---|---|
| `old3` | **基线（严格对照）**：`git show HEAD:` 原版逐字副本（286 行）+ 只把 `.target_name(88'd0)` 显式接常量 0 | 578 | **994** | 526 | 0 | 6 |
| `new` | **当前 RTL（完整）** | 802 | **1260** | 641 | 0 | **6** |
| `new2` | 去掉「移位器 + 加法器」：`assign rle_lba_c = f32_data_beg;` | 701 | 1117 | 593 | 0 | 6 |
| `new4` | 只去加法器、保留移位器：`assign rle_lba_c = {8'd0, rle_clu_shl};` | 768 | 1192 | 641 | 0 | 6 |
| `new3` | `target_name` 回退成组合三目、删掉 `name_sel` | 811 | 1269 | 640 | 0 | 6 |
| `new6` | 去掉非法 spc 守卫：`wire rle_spc_bad = 1'b0;` | — | 1252 | 641 | 0 | 6 |
| `new5` | 移位器换乘法器：`rle_clu_off * f32_spc[7:0]` | 734 | 1200 | 641 | 0 | **8** ❌ |
| `new8` | 串行移位：新增 `G_LBA` 态 + `reg [30:0] sh_acc` + `reg [2:0] sh_cnt` | 772 | 1230 | 676 | 0 | 6 |

同端口 wrapper 口径（`wrap_old` / `wrap_new`，19 端口完全一致、pad 集对齐 15 in / 111 out）：`#lut` **994 → 1260**，与裸模块口径**逐字相同**，都是 **+266**。`#bram` 0→0、`#dsp` 6→6，两条硬判据通过。

**单变量归因**（把 266 拆开）：

| 来源 | LUT | 依据 |
|---|---|---|
| 24×3 桶形移位器 | ≈ **68** | `new` 1260 − `new4` 1192 |
| 32 位加法器（`f32_data_beg + …`） | ≈ **75** | `new4` 1192 − `new2` 1117 |
| 其余（4 个新输出 + FSM 三分支 + `rle_probe/rle_phase` + `name_sel` 使能网络 + `rle_spc_bad`） | ≈ **123** | `new2` 1117 − `old3` 994 |

**两个「想当然的估算」被实测推翻**，记在这里避免后来人重算：

- **「88 位组合三目 ≈ 88 LUT」→ 实测只有 9**（`new3` 1269 vs `new` 1260）。`RLE_NAME` 是编译期常量、`rle_probe` 只有 1 位，综合器把「常量 A 与常量 0 之间的 88 位 2 选 1」直接化成 88 个 FF 的 D 端常量网络，几乎不花 LUT。改成寄存器版反而要付 `name_sel` 自己的 88 个使能门，净省只有 9。
- **「移位器 35×4 → 24×3 省 117」→ 实测移位器省 68，剩下的 75 是加法器**。加法器之所以贵，是因为 `f32_data_beg` 与 `rle_lba_c` 都是 32 位，要一条完整进位链。

**两条「换资源」路线都被否决**：

- `new5` 乘法器：省 60 LUT，但 `#dsp` **6→8**。违反「零 DSP」硬约束，**未合入**。
- `new8` 串行移位：省 30 LUT，但多 1 个状态、多 35 个 FF，且把一个纯组合路径变成跨拍路径（时序验证面变大）。性价比过低，**未合入**。

**结论与裁决（2026-11-02 captain 拍板：接受 +266，不裁剪）**：

`+266` 无法在不引入 DSP、不新增状态机、不牺牲功能正确性的前提下压到 108；而三条「裁剪」都拿**刚定的正确性**换一个百分比，换来的故障形态恰好都是最难查的一类（不报错、现象离根因很远）：

| 裁剪项 | 省 | 代价 |
|---|---|---|
| 去掉非法 spc 守卫 | −8 | 坏卡静默算错 LBA → 视频永远停首帧、无错误码 |
| `rle_size` 砍成 24 位 | −10 | 直接截断 82 MB 的真素材 SCI.RLE（现在这份素材就会坏） |
| `rle_lba` 砍成 24 位 | −8 | 顶层 rtl-integ 已按 32 位接线，要返工 |

**因此裁决：接受 +266，不裁剪。**

> **⚠️ 这个 266 怎么记、怎么算（2026-11-02 captain 明确，改过一次的地方，别再算错）**：
> **不要把 266 加到 17,892 上**（更不能加到 19,353 上）。那正是此前被纠正过的「差分之差」—— `17,892 + 266 = 18,158` 这个数**既不是实测、也不是有效总量**：17,892 里含 P0/P1 各行的外推误差，266 又只是单模块探针增量，两者相加等于「在一个不准的基数上硬加一个不同量纲的增量」。**这个算式不得出现在任何对外材料里。**
> 正确做法：**t7-B 集成综合实测已经把 266 与 399 全部含在内**（`u_gallery` 939 → 1,181，Δ +242；`u_narr` 0 → 352），故这两项**无需再单独并入任何口径**。当前唯一对外口径就是 **19,353 / 98.74% / 余 247**。
> **当前对外口径是 t7-B 实测 19,353 / 98.74% / 余 247**（2026-11-02 四次裁定）。266 只记在 `RESOURCE_BUDGET.md` §3.2b（模块级实测，标「本表无此项」）作方法论记录。

> **⚠️ 风险口径（t10/t11 引用时必须用这个说法，不得写「余量充裕」）**
> - **硬上限 19,600 才是红线；92%（即 18,032）是布线与 WNS 预警线**，不是不可逾越的墙。**若 t7-B 全局相减后落在 18,200~18,500（约 93%），预警条款即已触发**，一律写「可行，但按 `RESOURCE_BUDGET.md` §4.1 表序（自上而下，C1 先上）准备 C1~C6 裁剪预案」，**不得写「余量充裕」**。
> - `+266` 是**模块级探针增量，不是主工程口径**。真正的判定要等 t7-B 用同一个 tcl、同一套选项跑两次全局 `#lut` 相减。为省 8~10 LUT 去砍功能，省下的立刻会被「差分之差」吃掉，而代价是永久的。
> - t7-A 实测 17,299（`optimize_gate` 阶段；**该报告被常量传播剪过，不得当基线**，见 `RESOURCE_BUDGET.md` §3.7 反例四）里**缺五项**（逐项在 `reports/t7a_gate_area.txt` 里 grep 过）：`narr_subline` +399（被 `.narr_en(1'b0)` 常量传播整块剪掉，全报告 `narr` 0 命中）、`rle_decoder` +360（`u_rle` 0 命中，未接入）、`ratio_map` +18（`u_ratio` 0 命中，未接入）、t16 参数面板 +80~150（尚未做）、以及本模块的 **t19 增量 +266**（`u_gallery` 在报告里是 741 lut，但那还是 t19 之前的版本）。**注意 `audio_src_mux` 已在 t7-A 里（`u_audio_src` = 3 lut），不要再当成缺失项。** t7-B 落地后总量大概率落在 **18,200 ~ 18,500（约 93%）**。
> - 正确表述是：**「可行，但按 `RESOURCE_BUDGET.md` §9 预警条款准备 C1~C6 裁剪预案」**。

### §17.5 验证

| 项 | 结果 |
|---|---|
| `lint_verilog.py rtl`（契约 verify 命令） | 67 文件，**E0=0 E1=0 E2=0，退出码 0** |
| `lint_verilog.py sim/testbench/tb_gallery_probe.v` | E0=0 E1=0 E2=0 |
| `tb_gallery_probe` | **14 个用例，63 条 PASS，`ALL CHECKS PASSED: gallery_probe` / `=== tb_gallery_probe done, errors = 0 ===`** |
| `tb_startup_ownership` | **`SUMMARY: checks=16 errors=0 gallery_blocks=6 player_blocks=1 early_player_pulses=0 discarded_player_requests=0`**，`ALL CHECKS PASSED: startup_ownership`（改动前 `checks=9`） |
| `tb_key_action` | **`42 checks, 0 error(s)`，`ALL CHECKS PASSED: key_action`**（与改动前逐字相同） |

**关于 `tb_key_action` 的如实说明**：受影响清单里列了它，但全仓 grep `gallery_probe u_` / `gallery_probe dut` 在 `tb_key_action.v` 里 **0 命中**——它只例化 `key_action dut`（`:50`），`:68` 只是在**注释**里提到「下游 `gallery_probe` 按电平 + 状态机采样」。所以它不受本次端口变化影响。仍然跑它并贴结果，是因为**「跑一个与本次改动无关的 tb 报全绿」比不跑更容易误导**：它的绿不能算本次改动的证据，只能算「未波及」的旁证。真正例化 `gallery_probe` 的 tb 全仓只有 2 个（`tb_gallery_probe.v:76`、`tb_startup_ownership.v:50`），另两个例化点是顶层 `dmz_eg4s20_hdmi_top.v` / `dmz_eg4s20_bringup_top.v`（不在本卡 inScope）。

新增的 4 个用例（`tb_gallery_probe.v`，W01 也补了「没有 SCI.RLE 时四个输出全 0」的 4 条断言）：

| 用例 | 场景 | 关键断言 |
|---|---|---|
| **W11** | 图库（3 张）+ SCI.RLE 同时存在 | `count==3`、`rle_found==1`、`rle_lba==14`（=7+(9−2)<<0）、`rle_size==82362927` |
| **W12** | 换卡 rescan 重探（簇号 9→12） | rescan 瞬间 `rle_lba==0`；完成后 `rle_lba==17`、`rle_size==1234567` |
| **W13** | 卡上只有视频、一张图都没有 | `count==0`、无 `first_img_req`、`rle_found==1`、`rle_lba==14` |
| **W14** | **每簇 2 扇区（`gal_spc=2`）** | `rle_lba==21`（=7+(9−2)<<1）、**`rle_lba != 14`**（不是漏移位的值） |

**W14 是唯一能抓「漏移位」的用例**——理由见 §17.6。

`tb_startup_ownership` 的修改是本节唯一一处「改了既有断言」，按 captain 要求**不放宽、改为显式承认并加强**。原来只有一条 `chk(gallery_done && sd_owner_player, "SD ownership transfers only after gallery completion")`，在 `first_img_req` 上升沿后 1 拍立刻检查。t19 起 `done` 被 RLE 探测轮推迟一轮，这条必然变红（首跑实测 `checks=9 errors=1`）。改成 7 条：

```verilog
chk(!gallery_done,        "gallery done is deferred by the SCI.RLE probe round");
chk(sd_owner_gallery,     "SD ownership still held by the gallery during the RLE probe round");
while (!gallery_done && !gallery_fail && guard < 5000) @(posedge clk);
chk(guard<5000 && gallery_done, "gallery completes after the SCI.RLE probe round");
chk(sd_owner_player,      "SD ownership transfers only after gallery completion");
chk(gallery_rle_found === 1'b0, "card without SCI.RLE reports not found");
chk(gallery_rle_fail  === 1'b0, "missing SCI.RLE is not reported as a failure");
chk(gallery_rle_lba   === 32'd0, ...);
chk(gallery_rle_size  === 32'd0, ...);
```

**前两条是这次修改的价值所在**：它们把「RLE 轮真的插在中间」钉死——脉冲当拍 `done` 必须仍为 0、SD 所有权仍在 `gallery_probe` 手里。将来若有人把 RLE 轮删掉或提前到别的位置，这两条会红。如果只是把等待循环放宽（不动断言），这个性质就永久失去覆盖。

### §17.6 反证：为什么必须有 W14

captain 本次给反证升了规矩：**每条反证必须同时给「变异前特征计数」和「变异后特征计数」，只有两数不同才算数**；只贴「红了 N 条」视为未完成。

**反证 A：漏掉 spc 移位**（captain 指定的那条）

```verilog
// 注入前
assign rle_clu_shl = rle_clu_off << rle_spc_shf;
// 注入后
assign rle_clu_shl = rle_clu_off;   // MUTATION-2: shift dropped
```

| 特征串 | 注入前计数 | 注入后计数 |
|---|---|---|
| `<< rle_spc_shf` | **1** | **0** |
| `rle_clu_off <<` | **1** | **0** |
| `rle_clu_off >>` | **0** | **0** |
| `MUTATION-2` | **0** | **1** |

结果：`CHECKS FAILED: 2 error(s)`，红两条 —— `FAIL: W14 rle_lba applies the spc shift`、`FAIL: W14 rle_lba is not the unshifted value`，`W14 rle_lba=14`。

**反证 B：左移改右移**（我多做的一条，用来排除「变异被综合优化掉」的可能）

```verilog
assign rle_clu_shl = rle_clu_off >> rle_spc_shf;   // 语义错，但不会被折叠
```

| 特征串 | 注入前计数 | 注入后计数 |
|---|---|---|
| `<< rle_spc_shf` | **1** | **0** |
| `>> rle_spc_shf` | **0** | **1** |

结果：`CHECKS FAILED: 1 error(s)`，红 `FAIL: W14 rle_lba applies the spc shift`，`W14 rle_lba=10`（右移结果，既不等于 21 也不等于 14）。这条证明右移变异不会在综合时被消掉、且被同一条断言抓住。

还原后：`<< rle_spc_shf` 恢复 1、`>> rle_spc_shf` 回到 0、`MUTATION` 归 0，MD5 回到 `F80A582139F2860C2E84B6DA9A3E3F50`，tb 复跑 `ALL CHECKS PASSED` / `errors = 0` / `W14 rle_lba=21`。

> **★ 最重要的观察：注入「漏移位」后 W11 / W12 / W13 全部仍然 PASS。**
> 实测 `W11 rle_lba=14`、`W12 rle_lba=17`、`W13 rle_lba=14` ——三个都对。原因：**这三个用例的镜像都是 `spc=1`，移位量 0，漏移位与原式恰好等价**。
> 也就是说：**如果没有 W14 这个 `spc=2` 的用例，这个 bug 在 tb 里完全不可见**，而它上板后的现象是「视频起始扇区算错 → 读到别的簇 → magic 判错 → 永远停在第一帧」。这是「断言必须朝失败时变红的方向设计」的又一实例：一个只在「参数等于某个特殊值」时才失效的 bug，宁可多写一个把参数推离特殊值的用例，也不要把三个特殊值用例当成覆盖足够。

反证的标准做法（本工程统一姿势）：`Copy-Item` 备份 → python 精确替换（`assert t.count(old) == 1`，且先计数后替换）→ 跑 tb → `Move-Item -Force` 还原 → 再用 python 复查计数确认还原。**先计数再替换**这一步是这次新加的：它同时给出了双计数里的「变异前」那一栏。

### §17.7 探针方法学（给后来人）

1. **`.al` 工程文件和 `flow_*.tcl` 用 python 生成**，模板见 `project/t19_probe/flow_new3.tcl`：`import_device eagle_s20.db -package EG4S20BG256` → `open_project` → `elaborate -top gallery_probe` → `foreach step {optimize_rtl optimize_gate}` → `report_area -file reports/area_<tag>.txt`。每个 `catch` 都要 `puts "PROBE_FAIL-<step>"` 并 `exit <非0>`，否则失败会静默变成「跑完了但没数据」。
2. **`td_commands_prompt.exe` 必须传相对文件名**：先 `Push-Location` 到 tcl 所在目录，再 `& $td "flow_new3.tcl"`。传绝对路径会被 tcl 当转义吃掉（实测报 `couldn't read file "C:UsersKoobeeAppDataLocalTemp..."`）。
3. **tcl 必须 ASCII、无 BOM、LF 换行**（python 侧 `encoding="ascii", newline="\n"`）。带 BOM 会报 `invalid command name "锘縫uts"`。
4. **单变量对照**：每一个变体只改一处，其余与原版逐字相同（包括注释）。改两处就只能得到「合计」，本轮 8 个变体才把 266 拆成 68 / 75 / 123。
5. **同端口 wrapper 校验**：裸模块口径受 pad 数量影响（`#IO` 60 vs 126），必须再做一轮「两侧端口完全一致的 wrapper」来确认 `#lut` 差值不受 IO 干扰。本轮两个口径都是 +266，才敢下结论。
6. **基线必须可复算**：报告里写清 `old3` 是怎么来的（`git show HEAD:rtl/storage/gallery_probe.v` 逐字副本 286 行 + 一行 `.target_name(88'd0)`）。只说「原版」而不说是从哪个 commit 取的、改了什么，后来人复算对不上 994 就无法判断是本轮数据错还是自己的方法错。**另（rtl-storage 主动更正，2026-11-02）：`old` 是 HEAD 原版逐字副本，HEAD 版 `fat32_reader` 例化本来就没有 `target_name` 端口（该端口是 t19 才加的）—— 不存在「old 相对原版删了一行」这种说法，`old3` 才是同端口、新旧逻辑的严格对照。**

### §17.8 为什么「按位宽线性估」一定会低估（三个实测反例）

本节是这次 t19 最有复用价值的产出，**比 +266 这个数字重要**。三个反例同属一类错误：给带**变址 / 多路选择 / 长进位链**的结构，按「位宽 × 单价」线性做增量估算。

#### 反例一：`narr_subline` —— 预算 +110，实测 +399（低估 3.6 倍）

`RESOURCE_BUDGET.md:152` 的实测记录：探针 `project/t13_narr_probe/` 双跑对照，`area_a.txt`（wrapper 只例化一个 `narr_subline`）`#lut 436`，`area_ref.txt`（空壳 wrapper）`#lut 37`，**差值 399**。

低估的根因（原文照录）：漏算 `base[sel] + col` 的**变址读地址生成** —— `base[]` 是 10 位 × 18 项常量表，但它喂的是**可变地址的 BRAM 读口**，综合器不能当纯 ROM 折叠，而是综合成 18 选 1 的 10 位多路器 + 加法器（200+ LUT）；另 18 路并行 `frame_idx >= start[i]` 比较 + 归约求 `sel` 也比原估的 50 贵。

> **判据**：只要「常量表 + 变量下标」出现在**存储器地址**上，就不能按 ROM 算，要按「N 选 1 多路器」算。

#### 反例二：`brightness_apply` —— 外推 120，实测 94（这次是高估，但错因同类）

`RESOURCE_BUDGET.md:134` 记的原估依据是「对照 `video_overlay` 内 5 档亮度约占其 631 le 的 1/8 ≈ 79，扩到 10 档 × 1.7 ≈ 135」。这个外推的**基数后来消失了**：`video_overlay.v:133-135` 的内部 5 档衰减已删净（`wire [7:0] r_brt = r_in;` 三通道直通），那个 79 不再存在。t7-A 实测 94。

> **判据**：拿另一个模块的比例外推，必须确认那个基数在**当前版本**还存在。比例外推比线性外推更脆，因为它把「两个模块结构相似」当成了前提。

#### 反例三：`gallery_probe` 的 `target_name` 与移位器（本轮，双错）

| 项 | captain 估 | 实测 | 偏差 |
|---|---|---|---|
| 88 位组合三目 `target_name` | +88 | **+9** | 高估 9.8 倍 |
| 移位器 35×4 → 24×3 | 省 117 | 省 **68** | 高估 1.7 倍 |
| （未预估）32 位加法器 | — | **75** | 完全漏项，比移位器还贵 |

**为什么 `target_name` 只值 9 个 LUT**：`RLE_NAME` 是编译期常量、`rle_probe` 只有 1 位，所以「常量 A 与常量 0 之间的 88 位 2 选 1」被综合器化成 88 个 FF 的 D 端常量网络，几乎不花 LUT。反过来，改成寄存器版要付 `name_sel` 自己的 88 个使能门，净省只有 9。

**为什么加法器占 75**：`f32_data_beg` 与 `rle_lba_c` 都是 32 位，要一条完整进位链。线性估算法会把它算成「32 个全加器」，但实际在 LUT4 架构上一条 32 位进位链还要付出布线级联的代价。

> **判据（三条合并）**：
> 1. **对「常量 × 1 位选择」不要按位宽估** —— 综合器会把它化成 FF 的 D 端常量，成本可能低一到两个数量级。**唯一可靠办法是探针实测**。
> 2. **对「变址读存储器 / 多路选择」要按 N 选 1 算，不要按 ROM 算**。
> 3. **对「多位数算术」要把进位链单独列一行**，它经常是块里最贵的一项，而人在分解结构时最容易漏掉它（因为它在源码里只是一个 `+`）。

**结论**：资源估算的正确粒度是「**结构类型 × 数量**」，不是「位宽 × 单价」。凡是新增里含有变址、多路选择、长进位链中任意一项，**必须在写预算时就标成「待探针」而不是给一个数字**——给一个错的数字比给「未知」更有害，因为它会被当成口径继续往上累加（`narr_subline` 的 110 就是这么进了 P1 小计，又被实测 399 推翻的）。

### §17.9 「默认档恰好等于没测」—— 一个通用陷阱

本节来自 §17.6 那个观察，captain 判定可推广为全项目准则，纳入 t9 与 t11。

**现象**：注入「漏掉 spc 移位」这个 bug 后，`W11` / `W12` / `W13` **依然全部 PASS**，三条的 `rle_lba` 分别是 14 / 17 / 14，**全都是正确的值**。原因：这三个用例的测试镜像都是 `spc=1`，移位量恒为 0，漏移位与原式**恰好等价**。

原始输出留档如下（`sim/_t19_run2`，注入变异体时 W11/W12/W13 的输出与下面逐字相同，只有 W14 变红）：

```
#   W11: count=3 rle_found=1 rle_lba=14 rle_size=82362927
# PASS: W11 rle_lba equals data_begin + (cluster-2)<<spc_shift
#   W12: count=2 rle_lba=17 rle_size=1234567
# PASS: W12 rle_lba follows the new first cluster
#   W13: count=0 rle_found=1 rle_lba=14
# PASS: W13 rle_lba correct on a video-only card
#   W14: count=3 rle_lba=21 rle_size=777
# PASS: W14 rle_lba applies the spc shift
# PASS: W14 rle_lba is not the unshifted value
```

（上面这份是**还原后**的正常输出。注入变异体时前 6 行完全不变、`W14` 两行变红，`rle_lba=14`。）

**推广成准则**：

> **任何移位 / 缩放 / 变址参数，至少有一个用例必须取非平凡值**——移位量 > 0、缩放比 ≠ 1、偏移 ≠ 0、簇大小 ≠ 1。默认档跑绿**不证明那段逻辑存在**。

这不是孤例，本工程已有同族三例：

| 例 | 默认档 | 「默认档」掩盖了什么 |
|---|---|---|
| t19 `rle_lba` 移位 | `spc=1` → 移位 0 | 漏移位与原式等价，W11/W12/W13 全绿 |
| t12 Key9 水平降采样 | `win_w == WORDS_LINE16` | 恒等档每拍必取，`h_acc` 的 DDA 偏差不可见；必须加 `win_w=48/off=8` 的「分数窗口」档才抓得到 |
| t15 `sd_grant` 门控 | tb 里 `sd_grant` 恒 1 | 门控 RTL 删掉仍全绿；必须加一个竞争消费者（`wav_want` 周期 37/窗 11）才让 grant 真的掉低 |

**与 Key9「恒等档要硬判绕过」的关系**（同一件事的两面）：
- Key9 里 `win_w == 640 && off_x == 0` 时 RTL **主动绕过**降采样逻辑（`h_ident`），这是**功能**上正确的做法（省得在恒等档白算）；
- 但「绕过」意味着**恒等档的测试根本碰不到那段逻辑**，所以必须**单独**用非恒等档断言。
- 一句话：**RTL 里可以为了省资源而绕过默认档，测试里绝不能用默认档来代替覆盖。**

**写用例时的自检句**：这个参数取默认值时，被测的那行代码**真的执行了吗**？如果答案里出现「等于」「恰好」「退化」这类词，就必须再加一个非默认档用例。

### §17.10 复现性（8 个变体全部留档）

| 项 | 内容 |
|---|---|
| 探针根目录 | `SmartCampusMedia/project/t19_probe/` |
| 每个变体的工程文件 | `t19_<tag>.al`（tag ∈ `old` / `old3` / `new` / `new2` / `new3` / `new4` / `new5` / `new6` / `new8` / `wo` / `wn`，共 11 个 `.al`，**均未删除**） |
| 每个变体的流程脚本 | `flow_<tag>.tcl`（11 个，**均未删除**），内容一致，只差 `.al` 文件名与输出文件名 |
| 变体源码 | `<tag>/gallery_probe.v`（每个变体一套；`fat32_reader.v` 统一复用 `new/fat32_reader.v`，MD5 `ADF4A939273698CFE6706AA7A83DCAD2`，与 `rtl/` 一致） |
| 面积报告 | `reports/area_<tag>.txt`（11 份，**均未删除**） |
| TD 原始日志 | `td_<tag>.log`（含 `PROBE_PASS-open_project` / `-elaborate` / `-optimize_rtl` / `-optimize_gate` / `PROBE_DONE-<tag>` 五步标记） |
| **单次耗时** | **约 12 秒**（`Measure-Command` 实测一轮完整 flow：`import_device` → `open_project` → `elaborate` → `optimize_rtl` → `optimize_gate` → `report_area`，实测 11.8 s）。8 个变体合计约 1.6 分钟，加 wrapper 两个变体共约 2 分钟 |

**后来人要复验其中某一个变体的最短路径**（三条命令）：

```powershell
cd D:\FPGA_Compelate\SmartCampusMedia\project\t19_probe
D:\TD_6_24_APP\bin\td_commands_prompt.exe flow_new4.tcl        # 换 tag 即可，约 12 秒
Select-String -Path reports\area_new4.txt -Pattern "^#lut |^#reg |^#dsp |^#bram "
```

**要先确认的事项（否则跑不通）**：
1. `tcl` 必须 ASCII / 无 BOM / LF 换行 —— 现存 11 个 `.tcl` 都是按此生成的，**不要用记事本另存为 UTF-8**。
2. 必须**先 `cd` 到 `t19_probe`** 再传**相对文件名**（`flow_new4.tcl`），传绝对路径会被 tcl 当转义吃掉。
3. `import_device eagle_s20.db -package EG4S20BG256` 依赖 TD 安装目录下的器件库，只能在装了 TD 6.2.168116 的机器上跑。

**复现性三问（环境 / 命令 / 输入从哪来）**：

| 问 | 答 |
|---|---|
| **环境** | Windows + Anlogic Tang Dynasty **V6.2.168116**（`D:\TD_6_24_APP\bin\td_commands_prompt.exe`），器件 `EG4S20BG256`。仿真用 ModelSim **ASE**（`D:\Quartus_APP\modelsim_ase\win32aloem\{vlib,vlog,vsim}.exe`），无 iverilog。python 3.13（`C:\Users\Koobee\AppData\Local\Programs\Python\Python313\python.exe`），只用于生成 `.al`/`tcl` 与跑 `scripts/lint_verilog.py`。 |
| **命令** | 探针见上三条；仿真见下面「三个 tb 的复跑命令」。两者都**不含隐藏步骤**——没有 `make`、没有环境变量、没有先跑别的脚本。 |
| **输入从哪来** | ① 面积探针：输入就是 `project/t19_probe/<tag>/gallery_probe.v` + `new/fat32_reader.v`，**全部随仓库留档**，不依赖任何外部数据。② `tb_gallery_probe`：16 扇区 SD 卡镜像由 tb 内部的 `build_gallery` **运行时构造**（`disk[]` 数组），不读外部文件，所以没有「镜像丢了就跑不了」的问题。③ 用例里的数字：`rle_sz = 82362927` 取自真素材 `assets/v2/sdcard/BURN640/SCI.RLE` 的实际字节数（82,362,927 B / 631 帧 / 5 fps），其余（簇号 9/12、`rle_sz` 1234567/777）是为覆盖分支人为取的，**不是**真卡值，tb 内注释已写明。 |

**三个 tb 的复跑命令**（每个都要在**新建目录**里先 `vlib work`，不要复用旧库）：

```powershell
# A) tb_gallery_probe —— 只需 3 个文件，不需要 SDRAM 宏
vlib work
vlog -quiet rtl/storage/gallery_probe.v rtl/storage/fat32_reader.v sim/testbench/tb_gallery_probe.v
vsim -c -quiet -lib work -do "run -all; quit -f" tb_gallery_probe
#   期望：ALL CHECKS PASSED: gallery_probe / === tb_gallery_probe done, errors = 0 ===（63 条 PASS）

# B) tb_startup_ownership —— 14 个源文件，必须带 +define+SDRAM_SIM_MODEL
vlib work
vlog -quiet +define+SDRAM_SIM_MODEL rtl/storage/gallery_probe.v rtl/storage/fat32_reader.v `
  rtl/storage/img_loader.v rtl/storage/img_scaler.v rtl/storage/bmp_parser.v `
  rtl/storage/fade_mixer.v rtl/storage/framebuf_arbiter.v rtl/storage/pix_reader.v `
  rtl/storage/sdram_ctrl_wrap.v rtl/storage/image_player.v rtl/common/async_fifo.v `
  rtl/video/image_window_mask.v rtl/video/video_timing_gen.v sim/testbench/tb_startup_ownership.v
vsim -c -quiet -lib work -do "run -all; quit -f" tb_startup_ownership
#   期望：SUMMARY: checks=16 errors=0 gallery_blocks=6 player_blocks=1

# C) tb_key_action —— 与本次改动无关，仅作「未波及」旁证
vlib work
vlog -quiet rtl/control/key_action.v sim/testbench/tb_key_action.v
vsim -c -quiet -lib work -do "run -all; quit -f" tb_key_action
#   期望：=== tb_key_action: 42 checks, 0 error(s) ===
```

**★ 模块真实路径（拼命令行前先看这里，我为此浪费过三轮）**：`img_scaler.v` / `bmp_parser.v` / `fade_mixer.v` 在 **`rtl/storage/`**（不是在 `rtl/video/`）；`async_fifo.v` 在 **`rtl/common/`**（不是在 `rtl/storage/`）；`image_window_mask.v` / `video_timing_gen.v` 在 `rtl/video/`；`key_action.v` 在 `rtl/control/`。路径猜错的表现是 `(vlog-7) Failed to open design unit file` + `VLOG_EXIT=2`，随后 `vsim` 报一串 `(vsim-3033) Instantiation of '…' failed`——**看起来像 RTL 缺模块，实际是命令行写错**。

**一个已知的不一致（如实记录，不要当 bug 修）**：`new/` 变体最初拷贝于注释补写**之前**（31,235 B / MD5 `F80A5821…`），补写 `name_sel` 证据注释后我把它同步成了当前 RTL 逐字副本（32,845 B / MD5 `1451AD66…`），并**重跑了一次 `flow_new.tcl` 确认 `#lut` 仍是 1260**——注释不影响综合，这一步同时是一次「差分之差」的自校验。所以现在 `new/` 与 `rtl/` 的 MD5 完全一致；若后来人看到 `area_new.txt` 与 `area_wn.txt` 完全相同（都是 1260），那是**设计如此**（wrapper 口径只对齐 pad、不改变逻辑）。
---

## §18 `u_pix_fifo` 1,634 LUT / 0 BRAM 的根因，与 S1 降本评估（**已于 t25 落地并出 route 实测，见 §18.14**）

> 本节是 t19 之后的一次只读核算（不属于任何任务卡，未改动 `rtl/` 任何文件）。它回答的问题是：同一份 `rtl/common/async_fifo.v`，为什么 `u_pix_fifo` 是 1,634 LUT / 0 BRAM，而 `u_write_fifo` 是 73 LUT / 3 BRAM？以及「能不能不付代价地把它换成 BRAM」。

### §18.1 结论（可直接引用）

> `u_pix_fifo` 1,634 LUT / 0 BRAM 的根因是 `async_fifo.v:130` 的异步组合读（`assign rd_data = mem[rd_bin[...]]`），结构上无法映射 BRAM。`project/fifo_probe/` 多变体实测：同尺寸只改读法 `a_async32 2,317 → b_sync32 80`（−2,237 LUT / +2 BRAM）；`pix_reader` 整体当 top 且参数对齐主工程例化（`FIFO_AW=9 / LEVEL_HI=384`）时 `pix9_async 2,746 → pix9_fwft 539`（−2,207 LUT / +2 BRAM，`#reg` 218 不变）。**折算主工程诚实区间 1,024~1,634（中值 1,300）** —— 下界只消阵列可严格论证，上界整个 leaf 归零不可能。FWFT 版替换进完整 elab 后 `tb_pix_reader 194/0/13`、`tb_image_player 11365/0`、`tb_display_content 614406/0` **三条基线逐字不变**；`u_write_fifo` BRAM 4→4（+11 LUT 噪声级）。**该优化当时实测可行但未执行** —— place 失败当时已由 `rtl min_ripple_len ≥ 30` 解决（`#lut` 19,353→17,645 / 90.03%）。**⚠ 该结论已于 t25 被推翻并落地**：`optimize_gate` 后的 17,610 不是 route 后的真实值（route 后 18,473 / 94.25%），S1 已于 t25 落地，实测全局 `#lut` 17,535 → 15,501（−2,034）、`#bram` 35 → 37。**本节其余内容（根因、探针、诚实区间的推导方法）仍然有效，只有「是否执行」这一句作废。详见 §18.14。**

### §18.2 根因：唯一变量是「读出是否打拍」，不是位宽、不是容量、不是 `ram_style` 属性

`rtl/common/async_fifo.v`（242 行）的关键行：

```verilog
:88   reg  [DATA_WIDTH-1:0] mem [0:DEPTH-1];          // 没有任何 ram_style 属性
:123  always @(posedge wr_clk) ... mem[wr_bin] <= wr_data;   // 写在 wr_clk 域
:130  assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];   // ←← 异步组合读，这一行是根因
```

`:42` 的原作者注释已经自认「`rd_data` 是 `mem[rd_bin]` 的**异步**组合输出，`rd_en=1` 且 `rd_empty=0` 时当拍即可取用」。

这一行决定了 TD 的推断结果。主工程 `%TEMP%\t7b_td_bit.log` 第 608-619 行是铁证：

```
608: SYN-1027 : Infer Logic DRAM(u_player/u_reader/u_pix_fifo/ramread0_syn_4) read 512x32, write 512x32
609: SYN-1026 : Infer Logic BRAM(u_player/u_write_fifo/ramread0_syn_4)
613: SYN-1027 : Infer Logic DRAM(u_rle/ramread0_syn_4) read 512x8, write 512x8
615: SYN-1026 : Infer Logic BRAM(u_wav/ramread0_syn_4)
619: SYN-1023 : Infer 3 Logic DRAMs, 4 Logic BRAMs.
```

`u_wav/fifo_mem`（16 × 1024 = 16,384 bit，**同步读**：`wav_stream_player.v:420 fifo_q <= $signed(fifo_mem[rd_ptr]);`）→ **BRAM**；`u_pix_fifo`（32 × 512 = 16,384 bit，**异步读**）→ **DRAM（LUTRAM）**。**总 bit 完全相同，唯一变量就是读法。**

三条被排除的猜测：

| 猜测 | 实测 | 判定 |
|---|---|---|
| 「容量超过某个阈值所以进不了 BRAM」 | 16,384 bit 完全相同，一个进去一个进不去 | 否 |
| 「57 位非标准宽度被特殊处理」 | `p57_async`（57 位、异步）也是 **0 BRAM / 4,196 LUT**，比 32 位更糟 | 否 |
| 「层级表把子模块重复计入父级」 | 对 `u_axis` 成立（层级表 1,491 vs 实测 23），但对 `u_pix_fifo` 不成立（它是 leaf，无子项） | 部分 |

层级表本身确实不可全信（Σlut 45,864 远大于全局 19,353）；但 `u_pix_fifo` 的 1,634 是真的，已由探针独立复现。

### §18.3 四组基准对照（`project/fifo_probe/`，32位档 32×512、16位档 16×1024，总容量恒为 16,384 bit）

| tag | 配置 | `#lut` | `#Total_luts` | `#reg` | `#bram` | `#dsp` |
|---|---|---|---|---|---|---|
| `a_async32` | 32bit/512，异步组合直出 | **2,317** | 763 | 80 | **0** | 0 |
| `b_sync32` | 32bit/512，读出改预取寄存器 | **80** | 62 | 80 | **2** | 0 |
| `c_async16` | 16bit/1024，异步直出 | **2,354** | 800 | 88 | **0** | 0 |
| `d_sync16` | 16bit/1024，读出改预取寄存器 | **89** | 71 | 88 | **2** | 0 |

→ **位宽不是变量**（16 位异步 2,354 反而比 32 位 2,317 更高）；**唯一变量就是「读出是否打拍」**；`#bram` 0→2、`#dsp` 恒 0。

另跑的三组变体说明同一件事：

| tag | 它回答的问题 | `#lut` | `#bram` |
|---|---|---|---|
| `p32_attr` | 加 `(* ram_style = "block" *)` 能不能强制 BRAM | **2,317** | **0** ← 与不加属性逐字相同，**属性路线死路** |
| `p32_d256` | 降深度能不能逼出 BRAM | 1,177 | 0 ← 只是线性减半，不能 BRAM 化 |
| `p57_async` | 57 位异步（回答「u_write_fifo 会不会也坠落」） | **4,196** | **0** |
| `axis` | `video_rgb_to_axis` 单模块（核层级表那行） | **23** | 0 ← 层级表写 1,491，确实是假象 |

### §18.4 组合逃逸探针（决定 FWFT 能不能用在 `pix_reader` 上下文的直接证据）

`rtl/storage/pix_reader.v:188` 是 `assign pix_rgb565 = out_valid ? fifo_rd_data[15:0] : 16'd0;` —— mem 读出值**组合直达输出端口**。如果「打拍」会因为延迟一拍破坏这条组合路径，那么整个 S1 方案就不成立。探针结果：

| 变体 | `#lut` | `#Total_luts` | `#bram` |
|---|---|---|---|
| `e_esc_async`（异步 + 逃逸） | **1,212** | 426 | 0 |
| `f_esc_reg`（打拍 + 逃逸） | 87 | 69 | 1 |
| `g_esc_fwft`（FWFT + 逃逸） | **99** | 81 | **1** |

→ **组合逃逸不阻止进 BRAM**（只 1 块而非 2，因为只有低 16 位被消费、高半字被优化掉）。

### §18.5 模块级同口径探针（决定性证据）

把 **`pix_reader` 整个当 top**（不是裸 FIFO wrapper），并把参数对齐主工程例化值 `FIFO_AW=9 / LEVEL_HI=384`（`rtl/storage/image_player.v:605` 覆盖了 `pix_reader.v:42/43` 的 10/768 缺省）：

| 变体 | `#lut` | `#Total_luts` | `#reg` | `#bram` |
|---|---|---|---|---|
| `pix9_async`（现状，主工程口径） | **2,746** | 954 | 218 | 0 |
| `pix9_fwft` | **539** | 283 | 218 | **2** |

缺省参数档（10/768，对应 1024 深）：`pix_async 5,053 / 1,717 / 229 / 0` → `pix_fwft 587 / 323 / 229 / 4`。

→ 同 top 单变量差 **−2,207 LUT / +2 BRAM**，而 **`#reg` 218→218 完全不变**（格雷码/同步器一个没少）—— 这一条直接证实了「改 FWFT 只消阵列、不消控制逻辑」。

### §18.6 折算主工程：诚实区间 1,024 ~ 1,634（中值 1,300）

主工程 `u_pix_fifo` 实测 **1,634** leaf LUT，拆成：**阵列 1,024**（16,384 bit ÷ 16 bit/LUT4）+ **控制约 610**（指针/格雷码/同步器/空满比较/写使能译码）。改 FWFT 后阵列→2 块 BRAM（**确定消失**），控制 610 **不会消失**。所以：

- **下界 1,024**（只消阵列，可严格论证）
- **上界 1,634**（整个 leaf 归零，不可能）
- **诚实区间 1,024 ~ 1,634，中值约 1,300**

探针 −2,207 比主工程大的原因：裸上下文里异步读的 **512 选 1 读多路树 ≈ 500 LUT** 被单独计费；而主工程里 `fifo_rd_data` 的消费者只有两处（`pix_reader.v:188` 与 `:370`），那棵树已被上层优化掉一部分。

**一个必须记下的算术细节**：place 的 mslice 预算不能用 `/4`（那是「4 LUT/mslice 理想打包」），实测打包率是 **3.647**（`19,353 ÷ 5,306`）。按实测打包率：

```
19,353 − 1,300 = 18,053   ÷ 3.647 = 4,950  >  4,900  ✗ 差 50
19,353 − 1,634 = 17,719   ÷ 3.647 = 4,858  ≤  4,900  ✓
19,353 − 1,024 = 18,329   ÷ 3.647 = 5,026  >  4,900  ✗ 差 126
```

→ **只有降幅接近上界才能单独过线**。这也是为什么「拿探针的 −2,207 直接当主工程降幅」会高估，而「按 `80/2,317 = 3.5%` 等比缩」会更大幅高估（隐含假设控制逻辑也跟着缩）。

### §18.7 FWFT 等价性：逐拍等价，但验证过程里发现了一次「假绿」

改法（在 `async_fifo` 内部，对外端口不变）：

```verilog
// 原：assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];
reg [DATA_WIDTH-1:0] rd_data_r;
always @(posedge rd_clk or negedge rd_rst_n)
    if (!rd_rst_n) rd_data_r <= {DATA_WIDTH{1'b0}};
    else           rd_data_r <= mem[rd_bin_next[ADDR_WIDTH-1:0]];   // 采「次态」地址
assign rd_data = rd_data_r;
```

`rd_bin_next = (rd_en && !rd_empty) ? rd_bin + 1 : rd_bin`（`:181`）。采次态地址时，本周期 `rd_data_r` 恒等于「当前队头」；`rd_en` 拉高后 `rd_bin` 前进、寄存器同拍采到新队头 → 下周期自动换新值。**对外逐拍等价**。

验证（`project/fifo_probe/fwft_tb/tb_fifo_fwft.v`，两个 DUT 同激励并行跑，`wr_clk 5 ns` / `rd_clk 7 ns` 异相，DW=8/AW=4）：

```
SECT: S1 / S2 / S3 / S4
S4: consumed 1658 words under continuous mode
SUMMARY: checks=1658 errors=0 wrote=1658 read=1658
ALL CHECKS PASSED: tb_fifo_fwft
```

**★ 这里有一个必须留档的教训：第一版 tb 是假绿的。** S1~S3（写一个读一个 / 填满后排空再补写 / 40 轮随机）都写成「先等 `rd_empty` 掉低、再在下一个 posedge 才拉 `rd_en`」，**恰好绕开了最危险的那拍**（`rd_empty` 刚掉低的同一拍就取数），`checks=146` 全绿但证明力为零。必须加 **S4**：`rd_en = cs_mode ? (pull_en && !rd_empty_0) : rd_en_manual`（组合驱动，`pix_reader` 真实用法）+ 写侧用 7 位 LFSR 真并发写入（`fork/join`，约 50% 写入率，3000 拍）。

这是「默认档恰好等于没测」（§17.9）的第 4 例，且是最隐蔽的一类 —— 它不是因为参数取默认值，而是因为**激励的时序恰好避开了边界**。同族四例：§17.9 的 t19 `spc=1` / t12 `win_w ≡ WORDS_LINE16` / t15 `sd_grant` 恒 1，加上本条。

**两条变异反证（双计数，按全项目反证新规矩）**：

| 变异 | 注入前特征计数 | 注入后特征计数 | 结果 |
|---|---|---|---|
| **MUTATION-1**：采 `rd_bin` 而非 `rd_bin_next`（教科书式 FWFT 写错法） | `rd_bin_next` 命中 **1** / `MUTATION-1` **0** | `rd_bin_next` **6** / `MUTATION-1` **1** | **errors=2162**（checks=1658），首错 `FAIL: rd#147 data differs orig=5d fwft=56`（落后一项） |
| **MUTATION-2**：`else if (!rd_empty) rd_data_r <= …`（空时不刷新） | guarded 命中 **1** / `MUTATION-2` **0** | guarded **1** / `MUTATION-2` **1** | **errors=74**，首错 `rd#177 orig=58 fwft=5b` |

两条变异都**只在 S4 存在时才被抓到**。还原后 `MUTATION-2`=0 / guarded=0，复跑 `checks=1658 errors=0` 全绿。

### §18.8 三条基线逐字不变（文件级替换，`rtl/` 零改动）

把 FWFT 版 `async_fifo.v` 替换进完整 elab，**其余源文件逐一相同**：

| tb | 现状 | FWFT | 判定 |
|---|---|---|---|
| `tb_pix_reader` | `checks=194 errors=0 cases=13 geometry=64x8` | **逐字相同** | ✅ |
| `tb_image_player` | `checks=11365 errors=0` | **逐字相同** | ✅ |
| `tb_display_content` | `checks=614406 errors=0 mismatched=0 underflow=0 overflow=0 max_rd_wait=9` | **逐字相同** | ✅ |

做法：`sim/_pr_base|_pr_fwft`、`sim/_ip_base|_ip_fwft`、`sim/_dc_base|_dc_fwft` 各建干净库（`vlib work` 必建），**只有 `async_fifo.v` 换成 `project/fifo_probe/b_sync32/async_fifo.v`**。这是文件级替换，**不是「改 RTL 红了再回滚」**。
补充：`tb_display_content` 需 plusargs `+disk/+golden/+golden2` 指向 `reports/diag_key1_baseline2/{disk,golden,golden2}.hex`；`tb_image_player` 必须带上 `rtl/storage/fat32_reader.v`；编译必须 `+define+SDRAM_SIM_MODEL`。

### §18.9 `u_write_fifo`（57 位）：不受影响，实测确认

参数照抄 `rtl/storage/image_player.v:28/35` 与 `:483-490`（`DATA_WIDTH=57 / ADDR_WIDTH=9 / ALMOST_FULL_MARGIN=96`），wrapper 模拟 `:478` 的 `else if (fifo_pop) write_head <= fifo_out;`：

| | `#lut` | `#Total_luts` | `#reg` | `#bram` |
|---|---|---|---|---|
| `p57_now`（现状） | 87 | 63 | 80 | **4** |
| `p57_fwft`（改后） | 98 | 74 | 80 | **4** |

→ **BRAM 4→4 不变，+11 LUT（噪声级）**。「为省 LUT 把一个已经在 BRAM 里的 FIFO 踢回 LUTRAM」这种回退不会发生。

### §18.10 为什么当时不执行（**已于 t25 落地，见 §18.14**）

place 失败已经用其他手段解决：`rtl-integ` 跑了 `min_ripple_len` 四档扫描（官方三参数 `set_param rtl min_ripple_len N` + `commit_param -step rtl`）：

| `min_ripple_len` | `#Total_luts` | `#lut` | gate `slices%` | `mslices` | place |
|---|---|---|---|---|---|
| 基线 | 11,282 | 19,353 | 41.03% | 5,306 | FAIL |
| 8 | 11,372 | 19,039 | — | 5,151 | FAIL |
| 18 | 12,433 | 18,062 | 28.57% | 4,956 | FAIL |
| **30** | **13,885** | **17,744（90.53%）** | **19.54%** | **4,849** | **PASS** |
| **45** | **15,020** | **17,645（90.03%）** | **13.24%** | **4,801** | **PASS** |

机制就是把进位链形式的 LUT（ripple 8,071）转成 LUT4/LUT5 形式：`#lut` 19,353→17,645（90.03%，回到 92% 软红线以下），gate slices 从 41.03% 降到 13.24%，`#Total_luts` 反涨到 15,020 —— **一个功能都没砍**。`place.qor`：`Setup WNS +1357 / FMAX 42.296 MHz / #slices 9,593 / 97.89%`。

因此 S1 当时从「必需」降为「备选优化」，**当时**不执行，三条理由：

1. place 已过，S1 的边际收益从「救活流程」变成「留更多余量」，不值得在出位流前夜改一个被 `u_write_fifo` 共用的模块；
2. 实测诚实区间中值 1,300 已**不再是过线的必要条件**；
3. `rtl/common/async_fifo.v` 全工程两处共用，改它有风险面 —— `p57_async` 换上下文就不能进 BRAM，说明 TD 的 BRAM 推断并不稳定。

**保留为什么有价值**：`project/fifo_probe/` 是「同一份代码在不同上下文里差 26 倍」的**唯一单变量证据**；FWFT 三条基线逐字不变的验证也保留：未来真需降本时**直接可用，不用重做**。

> **⚠ 本节结论已于 t25 被推翻并落地。** 上面三条理由在当时成立，但被两件后发生的事实击穿：①`optimize_gate` 后的 17,610 / 89.85% **不是** route 后的真实值，route 插 buffer 要占 LUT 槽位，**route 后实测 18,473 / 94.25%，真实余量只剩 1,127 而不是 1,955**；②13 组参数实验（含 `min_ripple_len` 之外的全部选项）已穷尽，`net` 段无一下降，且最差路径七组实验里每次不同（`u_narr/addr[9]` / `u_vtg/active_x_reg[1]` / `u_rle/frame_idx_b2[15]`），说明 clk0 域普遍贴临界、必须整体降总量而非调参数。**S1 已于 t25 落地，实测全局 `#lut` 17,535 → 15,501（−2,034）、`#bram` 35 → 37，三条基线逐字不变。详见 §18.14。**

### §18.11 `rle_decoder.v:225` 的 `blk_buf`：已评估，不做

`reg [7:0] blk_buf [0:BLK_BYTES_V-1];`（512 × 8 = 4,096 bit），`:282` 附近 `cur_byte = blk_buf[rd_ptr]` 是异步读，同样无法映射 BRAM。估算 4,096 bit ÷ 16 = **约 256 LUT**。

**结论：不做。** 理由与 S1 同：`#lut` 已降到 90.03%（17,645 / 余量 1,955），256 LUT 的量级对余量不构成威胁；而换成 BRAM 会引入**1 拍读延迟**，而 `blk_buf` 的读口在 `R_PAYLOAD` 里是「读字节 → 判 run → 拼字 → 推写口」紧凑链路上，动它会打乱 t4 已验证的时序。

### §18.12 复现与采坑（后来人必读）

探针全部在 `SmartCampusMedia/project/fifo_probe/`：`fifo_<tag>.al` + `flow_<tag>.tcl` + `<tag>/*.v` + `reports/area_<tag>.txt` + `td_*.log`，单次约 12 s。最短复验：

```powershell
cd D:\FPGA_Compelate\SmartCampusMedia\project\fifo_probe
D:\TD_6_24_APP\bin\td_commands_prompt.exe flow_pix9_fwft.tcl
Select-String -Path reports\area_pix9_fwft.txt -Pattern "^#lut |^#Total_luts|^#reg |^#bram |^#dsp "
```

三个踩过的坑（表现都不像真正原因）：

1. **`.al` 里的 `<File Path="a_async32/...">` 目录前缀没替换** → 两次跑的是同一份源、读数完全一样，差点当成「结论」。**教训：探针读数完全相同时，先怀疑工程没换源，而不是先怀疑结论。**
2. **模板只对主串 `.format()` 没对子串 `.format()`** → 生成文件里留着 `{hi}` / `{dw}` 字面 → TD 报 `HDL-8007 ERROR: syntax error near ''d'` + `PRJ-8644 ERROR: Failed to analyze source file(s).`，而 tcl 的 `catch` 只吐空 `PROBE_FAIL-open_project: `。**冒号后为空 = 综合器分析失败，不是工程文件坏。**
3. **`.al` 里 `<File Path>` 与 `<MODULE>` 要一起改** → 否则 `.al` 里留着不存在的路径，表现为 `PRJ-7001 CRITICAL-WARNING: Can't find this file` + `HDL-8001 ERROR: Incorrect top-level module name "pix_reader", please reset`。**真实原因是源文件没进工程，不是 top 名字错。**

变体总数：`project/fifo_probe/` 下共 **22 个** `.al` + 22 份 `reports/area_<tag>.txt`（`axis` / `a_async32` / `b_sync32` / `c_async16` / `d_sync16` / `e_esc_async` / `f_esc_reg` / `g_esc_fwft` / `p32` / `p32_attr` / `p32_d256` / `p32_fwft` / `p32_fwft2` / `p32_reg` / `p57` / `p57_async` / `p57_fwft` / `p57_now` / `pix9_async` / `pix9_fwft` / `pix_async` / `pix_fwft`），逐个可重跑。

### §18.13 这段结论落字之后，两件必须知道的事

1. **`rtl/storage/rle_decoder.v` 只加了注释，代码零改动，已实测。** 在 `blk_buf` 声明处（原 `:225`）补了一段「已评估：不换 BRAM」的说明（机制同 §18、预估 −256 LUT、当前余量 1,955 不构成威胁、换 BRAM 会引入 1 拍读延迟而打乱 t4 已验证的写组时序）。文件 37,685 → **38,377 B / 750 行**（原 742 行，+8 行全是 `//`）。验证三件：与 `project/hdmi/rle_decoder.v`（未同步的旧副本）逐行去掉注释后 **448 行代码完全相同**；`lint_verilog.py rtl` 67 文件 E0/E1/E2 全 0；`tb_rle_decoder` 复跑 **`checks=58 errors=0`**（FRAME0 / FRAME1 / FRAME_DELAYED 各 `beats=153600 word_errors=0 groups=38400`）。
2. **这次注释没有进到正在出的位流里，因此位流不作废。** `project/hdmi_td.al` 里写的是 `<File Path="hdmi/rle_decoder.v">`（同理 `hdmi/async_fifo.v`、`hdmi/pix_reader.v`），即 TD 编译的是 `project/hdmi/` 下的副本，**不是 `rtl/`**。需要把这段注释带进交付产物时要跑一次 `scripts/sync_src.ps1`（不在本条目的文件域内，未执行）。此刻 `project/hdmi/rle_decoder.v` 仍是 37,685 B / MD5 `65FD8681…`，与 `rtl/` 已不同（仅注释）。

## §18.14 S1 落地：`async_fifo` 改 FWFT 同步读（t25，已实测）

> 本节是 §18.10 那三条「当时不执行」理由被击穿之后的正式落地记录。触发原因写在 §18.10 末尾的警示框里：`optimize_gate` 后的 17,610 / 89.85% 不是 route 后的真实值，route 后实测 18,473 / 94.25%，真实余量只剩 1,127。
>
> **一句话结论（可引用）**：`rtl/common/async_fifo.v` 的读出由「异步组合读」改为「同步读 + FWFT 预取寄存器」后，`u_pix_fifo` 由 **1,641 LUT / 0 BRAM** 变为 **82 LUT / 2 BRAM**（route 后实测），全局 `#lut` 由 **17,535 / 89.46%** 降到 **16,649 / 84.94%**，`#bram` 35 → 37，`#dsp` 保持 24；route 后 **SWNS +0.113ns / HWNS +0.012ns / 0 violating endpoints**，`4364 mslices / 4900 = 89.1%`，place、route 均 PASS。三条仿真基线（`tb_pix_reader` 194 / `tb_image_player` 11365 / `tb_display_content` 614406）**逐字不变**，`u_write_fifo` 全程 **3 块 BRAM**（没掉回 LUTRAM）。详见 §18.14.7。

### §18.14.0 先给一条四套独立构建互相验证的证据链

本节所有绝对数字的可信度，不依赖任何单次报告，而依赖下面这张表。**四个时间点、四套互不相同的 TD 工程，`#lut` 与 `#reg` 逐字吻合**：

| 构建 | 生成时刻 | `#lut` | `u_pix_fifo` | OSD 状态 | FIFO 状态 |
|---|---|---|---|---|---|
| `reports/t7b3_rl45_place_hfn_opt_effort_high_gate_area.txt` | 22:12:21 | **17,610** | 1,642 / 0 bram | 旧（t24 未做） | 旧（异步读） |
| `project/t24_osd_probe/reports/area_old_gate.txt` | 22:46:09 | **17,610** | 1,642 / 0 bram | 旧 | 旧 |
| `project/t24_osd_probe/reports/area_new_gate.txt` | 22:49:50 | **17,535** | 1,641 / 0 bram | 新（`osd_strings` 改 BRAM） | 旧 |
| `project/t25_fifo_probe/reports/area_old.txt` | 23:11:23 | **17,535** | 1,641 / 0 bram | 新 | 旧 |
| `project/t25_fifo_probe/reports/area_new.txt` | 23:15:08 | **15,501** | **80 / 2 bram** | 新 | **新（FWFT）** |
| `reports/t7b3_rl45_gate_area.txt`（rtl-integ 全流程） | 23:21:49 | **15,501** | **80 / 2 bram** | 新 | **新（FWFT）** |

读法五句话：

1. **第 1 行 = 第 2 行**（17,610 逐字相同）⇒ t24 探针工程的 old 分支与 t7-B 全流程是同一基线，探针工程没有引入额外偏差。
2. **第 3 行 = 第 4 行**（17,535 逐字相同）⇒ t25 探针工程的 old 分支与 t24 探针工程的 new 分支是同一基线。
3. **第 2 行 − 第 3 行 = 75** ⇒ t24（OSD 组合 ROM 改 BRAM）的实测增量，与 t24 自己的报告一致。
4. **第 4 行 − 第 5 行 = 2,034** ⇒ t25（本任务）的实测全局降幅。
5. **第 6 行 = 第 5 行**（`#lut` / `#Total_luts` / `#reg` / `#bram` / `#dsp` 五个全局数 + `u_pix_fifo` / `u_write_fifo` / `u_reader` / `u_player` 四行层级表，**逐字相同**）⇒ **降幅不是探针工程的产物**。第 5 行用的是 `t25_new.al` + `t25_fifo_probe/new/async_fifo.v`，第 6 行用的是 `project/hdmi_td.al` + `project/hdmi/async_fifo.v`，**两个不同的 TD 工程文件、两套不同的源目录**，拿到同一个结果。

因此「t24 与 t25 可加」不是假设，是实测：两者的测度里含有相同的 t24 基线，差值直接相减即可。**任何人复算这些数，只要拿到这六份文件就够了，不需要重跑 TD。**

> **第 6 行是本节的第三方验证。** 它由 `rtl-integ` 独立跑出（不是本任务，用的是 `project/t7b3_run.log` 那趟全流程），且是在本任务探针之后约 6 分钟生成。**它证明的是：主工程拿到的是同一个 15,501，不是探针工程的假象。**

> **⚠ 关于 17,610 与 `reports/t7b3_*` 那几个 18,4xx：**它们不是矛盾，是**版本差一个 t24**。`rtl/osd/osd_strings.v` 改于 22:27:32，而全工程最新三份 route 报告（18,448 @ 22:23:26、18,476 @ 22:23:01、18,473 @ 20:27:29）全部生成于 22:27 之前或与之无关的旧轮次。**17,610 − 75 = 17,535 逐字吻合**，这正是上表第 2、3 行的差。

### §18.14.1 改动对照（`rtl/common/async_fifo.v`）

文件：`242 行 / 11,880 B / MD5 EAE207CA8712E7E2` → **`299 行 / 16,237 B / MD5 14139BF173A6B5AB`**。**对外端口逐字不变**：`wr_clk / wr_rst_n / wr_en / wr_data / wr_full / wr_almost_full` + `rd_clk / rd_rst_n / rd_en / rd_data / rd_empty`，参数 `DATA_WIDTH` / `ADDR_WIDTH` / `ALMOST_FULL_MARGIN` 全部保留；`rd_data` 仍是 `output wire`（内部 `reg` + `assign` 引出，端口类型不变）。

功能性改动只有三处，其余全是注释：

| # | 位置 | 改前 | 改后 |
|---|---|---|---|
| 1 | `:119` | `reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];` | `(* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];`（属性只是提示，见 §18.14.3） |
| 2 | `:163-185` | `assign rd_data = mem[rd_bin[ADDR_WIDTH-1:0]];`（异步组合读） | `always @(posedge rd_clk or negedge rd_rst_n)`：复位 `rd_data_r <= {DATA_WIDTH{1'b0}}`，否则 **`rd_data_r <= mem[rd_bin_next[ADDR_WIDTH-1:0]];`** |
| 3 | `:187` | —— | `assign rd_data = rd_data_r;` |

新增一个寄存器 `reg [DATA_WIDTH-1:0] rd_data_r;`（`:131`）。

**★ 采样地址必须是次态 `rd_bin_next`，不能是当前态 `rd_bin`。** 论证：`rd_bin_next`（`:238`，`(rd_en && !rd_empty) ? rd_bin + 1 : rd_bin`）在**上一拍**被采样，而上一拍的 `rd_bin_next` 恰好就是这一拍的 `rd_bin` ⇒ `rd_data_r` 在任意拍恒等于 `mem[rd_bin]`，即「当前队头」。**逐拍等价，不是近似。**

### §18.14.2 为什么必须是 FWFT，而不是 naive 同步读

`pix_reader.v:187-190` 是**同拍组合消费**：

```verilog
assign pix_rgb565 = use_key9 ? (out_valid ? fifo_rd_data[15:0] : 16'd0)
                             : (!out_valid ? 16'd0
                                : (pix_count[0] ? word_hold[31:16] : fifo_rd_data[15:0]));
```

`out_valid`（`:185`）= `use_key9 ? h_pop : pix_valid_raw`；`h_pop`（`:279`）= `h_take && !fifo_rd_empty`；`fifo_rd_en`（`:174`）= `!fifo_rd_empty && (... || take_word)`。**同一拍里 `fifo_rd_en` 拉高出队、`pix_rgb565` 同时把 `fifo_rd_data` 送输出端口。**

若改成普通同步读（读口打一拍、`rd_data` 表示「上一拍的队头」）：

- 现象是**整幅图右移 1 像素**；
- 且**不报任何编译/综合/时序错**——`vlog` 干净、`lint` 全 0、TD 综合照过。

也就是说：这是一类「只在屏幕上看得出来」的错。FWFT（first-word-fall-through，预取寄存器常指队首）是让「同步读」在**不影响消费端时序**的前提下拿到 BRAM 的唯一做法。

**副作用成本**：`+DATA_WIDTH` 个 FF（32 位档 +32，57 位档 +57），零额外组合逻辑。实测全局 `#reg` 8,242 → 8,295（**+53**），与「两份 FIFO 各加预取寄存器、但原 `mem` 读出通路的组合逻辑反向减少」吻合。

### §18.14.3 为什么不能「只加 `ram_style` 属性」，必须改读法

这条是答辩直接答案，**有单变量实测**（`project/fifo_probe/`，三份报告）：

| 变体 | 读法 | 属性 | `#lut` | `#bram` |
|---|---|---|---|---|
| `p32` | 异步组合读 | 无 | **2,317** | **0** |
| `p32_attr` | 异步组合读 | `(* ram_style = "block" *)` | **2,317** | **0** |
| `p32_fwft` | FWFT 预取寄存器 | 无 | **69** | **2** |

**`p32` 与 `p32_attr` 逐字相同** ⇒ 属性对异步读**完全无效**。同一位宽、同一属性，唯一差别是读法，`#lut` 差 **2,248**、`#bram` 差 **2**。

原因：`ram_style` 是**综合指导（hint）不是命令**。BRAM（含 LUTRAM/DRAM 推断）的前提是「读口由时钟沿驱动」（`always @(posedge clk) dout <= mem[addr]`）。`assign rd_data = mem[addr]` 是纯组合路径，综合器只能摊成 LUT 阵列 —— 属性写了也只会被忽略。

**另一条同族警示**（`p57_async`，57 位档、异步组合读）= **4,196 `#lut` / 0 `#bram`**，比 32 位档更糟。同一份代码换上下文就可能掉回 LUTRAM，说明**没有任何静态检查能保证「它一定进 BRAM」**，只能靠综合报告核实（这正是 TD 的 `SYN-1027 : Infer Logic DRAM(...)` / `SYN-1026 : Infer Logic BRAM(...)` 两行日志的用处）。

### §18.14.4 实测降幅：三个数并列，不互相替代

**同一 tcl、同一 `min_ripple_len 45` + `commit_param -step rtl`、同一 66 文件源列表，唯一变量是 `async_fifo.v` 换源。** 两趟各 212 s / 214 s，`PROBE_DONE-old` / `PROBE_DONE-new`，退出码 0，七条产物断言全 PASS。

| 指标 | old（异步组合读） | new（FWFT 同步读） | Δ |
|---|---|---|---|
| **`u_pix_fifo` `#lut`** | **1,641** | **80** | **−1,561** |
| **`u_pix_fifo` `#bram`** | **0** | **2** | **+2** |
| **全局 `#lut`** | **17,535 / 89.46%** | **15,501 / 79.09%** | **−2,034** |
| 全局 `#Total_luts` | 14,910 | 14,412 | −498 |
| 全局 `#reg` | 8,242 / 42.05% | 8,295 / 42.32% | +53 |
| 全局 `#bram` | 35 / 54.69% | **37 / 57.81%** | **+2** |
| 全局 `#dsp` | 24 / 82.76% | 24 / 82.76% | **0** |
| `u_reader`（pix_reader）`#lut` | 2,112 | 227 | −1,885 |
| `u_player`（image_player）`#lut` | 6,534 | 4,428 | −2,106 |
| `u_write_fifo` `#lut` | 67 | 84 | +17 |
| **`u_write_fifo` `#bram`** | **3** | **3** | **0（契约要求「不得 < 3」，满足）** |

**三个数必须并列写，任何一个单独拿出来都会误导：**

1. **leaf 降 1,561**（`u_pix_fifo` 1,641 → 80）。这个数落在 §18.6 推导的 **1,024 ~ 1,634** 区间内（靠上沿），与预测一致。
2. **全局降 2,034**（`#lut` 17,535 → 15,501）。比 leaf 多 473。
3. **多出的 473 有明确机制，不是测量噪声**：`rd_data` 原本是 **512 选 1 的组合读多路树**，而 `fifo_rd_data` 有**两个消费者**（`pix_reader.v:188` 的 `pix_rgb565` 与 `:370` 的另一条）——综合器要为这条组合路径做**扇出复制与二次选择**。改成寄存器输出后整条组合锥消失，下游的选择/复制逻辑跟着被优化掉：`u_reader` 自身 **−324**（2,112 → 227，其中 1,561 是 fifo、324 是自己的选择逻辑）、`u_player` 自身 **−221**（6,534 → 4,428，其中 1,885 是 reader、221 是自己的）。

这正是 §18.4「组合逃逸探针」单独测过的现象（`e_esc_async` 1,212 vs `g_esc_fwft` 99，同样 32 位档、同样有逃逸）。**探针当时就预告了「逃逸不阻止进 BRAM，但会让上游多付一笔」，只是主工程里这笔被摊到了 `u_reader` / `u_player` 自己的账上。**

> **⚠ 口径提醒（给 t10 / t11）**：§18.6 的「诚实区间 1,024~1,634」是 **`u_pix_fifo` 这个 leaf 的降幅区间**，不是全局降幅区间。**写报告时若只引全局 2,034 而说「与预测区间相符」，会被读者当成模型错了；正确写法是「leaf 降 1,561（与预测区间 1,024~1,634 相符），全局降 2,034，多出的 473 来自上游组合锥消失」。**

### §18.14.5 三条基线 + `u_write_fifo` 反证 + 假绿 tb 的教训

**三条基线在改后 RTL 上直接复跑，逐字不变，一个 tb 都没改：**

| tb | 改动前 | 改动后 | 判定 |
|---|---|---|---|
| `tb_pix_reader` | `SUMMARY: checks=194 errors=0 cases=13 geometry=64x8` | **逐字相同** | ✅ |
| `tb_image_player` | `SUMMARY: checks=11365 errors=0` | **逐字相同** | ✅ |
| `tb_display_content` | `SUMMARY: checks=614406 errors=0 missing=0 mismatched=0 underflow=0 overflow=0 rd_fault=0 rd_timeout=0 max_rd_wait=9` | **逐字相同** | ✅ |

契约明确「红了回滚重来、不许改 tb 适配」，实际结果是一条断言都不需要动 —— 这是 FWFT 逐拍等价的最硬证据（比任何面积数字都重要）。

`u_write_fifo`（57 位、`ADDR_WIDTH=9`、`ALMOST_FULL_MARGIN=96`）**没有掉回 LUTRAM**：主工程实测 `#bram 3 → 3`、`#lut 67 → 84`（+17，噪声级）。模块级探针同结论：`p57_now` **87 `#lut` / 4 `#bram`** → `p57_fwft` **98 `#lut` / 4 `#bram`**（+11、4→4）。「为省 1,561 赔掉 `u_write_fifo` 的 4 块 BRAM」这种回退没有发生。

**★ 假绿 tb 的教训（t9 要的原型案例，原文保留）**

新建的 `sim/testbench/tb_fifo_fwft.v`（527 行）最初只写了 S1~S3 三个场景：

- **S1**：空 FIFO 上「写一个 → 读一个」8 次；
- **S2**：填满 `DEPTH-2` 后排空到空，再立即写 4 个继续读；
- **S3**：40 轮随机填充/排空，空隙 0~5 拍。

首跑 **`checks=146 errors=0` 全绿** —— 但**证明力为零**。因为三个场景都是「先等 `rd_empty` 掉低、再在下一个 `posedge` 拉 `rd_en`」，**恰好绕开了最危险的窗口**：`rd_empty` 刚掉低的**同一拍**就取数（`pix_reader` 的真实用法是组合驱动 `rd_en`）。

补上 **S4** 后才具备证明力：`rd_en = cs_mode ? (pull_en && !rd_empty_0) : rd_en_manual`（组合驱动，与 `pix_reader.v:174` 同形）+ 写侧 7 位 LFSR 真并发写入（`fork/join` 两个 initial 块，约 50% 写入率，3000 拍）。最终 **`SUMMARY: checks=1658 errors=0 wrote=1658 read=1658`**。

两条变异反证（都只在 S4 存在时才被抓到）：

| 变异 | 改动 | 注入前特征计数 | 注入后特征计数 | 结果 |
|---|---|---|---|---|
| `MUTATION-1` | 采当前态 `rd_bin` 而非次态 `rd_bin_next` | `rd_bin_next` 命中 1 / `MUTATION-1` 0 | `rd_bin_next` 6 / `MUTATION-1` **1** | **`errors=2162`**，首错 `FAIL: rd#147 data differs orig=5d fwft=56`（fwft 落后一项） |
| `MUTATION-2` | `else if (!rd_empty) rd_data_r <= ...`（空时不刷新） | guarded 1 / `MUTATION-2` 0 | guarded 1 / `MUTATION-2` **1** | **`errors=74`**，首错 `FAIL: rd#177 data differs orig=58 fwft=5b` |

还原后 `MUTATION-1`=0、`MUTATION-2`=0、guarded=0、复跑 `checks=1658 errors=0` 全绿。

**这是「默认档恰好等于没测」的又一实例**（与 §17.9 的 `spc=1`、t12 的 `win_w ≡ WORDS_LINE16`、t15 的 `sd_grant` 恒 1 同族）：一个绿得漂亮的 tb 可能根本没走到关键路径。**S4 段在正式 tb 里必须保留，不许因为「跑得慢」删掉。**

### §18.14.6 为什么必须单独跑探针，而不能引用现有报告推算

**全工程最新三份 route 级面积报告，没有一份包含 FWFT**：

| 报告 | 生成时刻 | `#lut` |
|---|---|---|
| `t7b3_rl45_place_post_place_opt_high_area.txt` | 20:27:29 | 18,473 |
| `t7b3_rl45_gate_mapper_lut_delay_2200_..._route_effort_routability_area.txt` | 22:23:26 | 18,448 |
| `t7b3_rl45_place_hfn_opt_effort_high_area.txt` | 22:23:01 | 18,476 |

而 `project/hdmi/async_fifo.v`（TD 实际编译的副本）是 **22:43:21** 才同步成 FWFT 版的。⇒ **这三份报告的 18,4xx / 94% 全部是旧读法的值。**

所以：

1. 任何「已经降了 1,561 / 2,034」的说法，**只能来自本节这趟探针**，或来自 rtl-integ 在这之后跑的全流程；
2. 反过来，任何引用 18,4xx 说「还是 94%、余量不够」的说法，也**已经作废**；
3. 探针工程只跑到 `optimize_gate`（不跑 place/route），单趟 **212 s**，两趟串行约 7 分钟 —— 比跑一趟全流程（约 15 分钟）便宜一半以上，且它是全流程的**输入前提**：若 FWFT 实际没进 BRAM、或 `u_write_fifo` 掉回 LUTRAM，让全流程先跑就等于白跑 15 分钟还要重跑推翻。

### §18.14.7 route 后实测：时序全正、三个门槛全过（不是推算，是实测）

> **本小节已由推算改为实测。** 上一版本写的是「gate 后余 2,369 / 2,531 / 4,099，即使 +2,000 也过」，那是外推；现在 rtl-integ 的全流程（`project/t7b_bit3.tcl`，`min_ripple_len 45`）已把 gate → place → route → `update_timing` 全跑完，用的是真数。

#### gate → route 的两级实测

| 指标 | gate（`reports/t7b3_rl45_gate_area.txt`，23:21:49） | **route（`reports/t7b3_rl45_area.txt`，23:28:39）** | gate→route |
|---|---|---|---|
| `#lut` | 15,501 / 79.09% | **16,649 / 84.94%** | **+1,148** |
| `#reg` | 8,295 / 42.32% | 8,456 / 43.14% | +161 |
| `#bram` | 37 / 57.81% | **37 / 57.81%** | **0** |
| `#dsp` | 24 / 82.76% | 24 / 82.76% | 0 |
| `u_pix_fifo` | 80 / **2 bram** | **82 / 2 bram** | +2 |
| `u_write_fifo` | 84 / **3 bram** | **78 / 3 bram** | −6 |
| `u_reader` | 227 | 282 | +55 |
| `u_player` | 4,428 | 5,102 | +674 |

**三个门槛按 route 实测值全部通过：**

| 判据 | 阈值 | route 后余量 | 备注 |
|---|---|---|---|
| place 硬门槛 | 17,870 | **1,221** | `4,900 mslices × 3.647` 打包率 |
| 92% 软红线 | 18,032 | **1,383** | 布线与 WNS 预警线，非硬红线 |
| 硬上限 | 19,600 | **2,951** | 这才是物理红线 |

`4364 mslices / 4900 = 89.1%`（改前 **5,306 = 108.3%，place 直接 FAIL**）；`#slices 8,752 / 89.31%`；`Congestion Over 100% util #tile = 0`。

#### route 后时序：全项目第一次 `SWNS` 与 `HWNS` 同时为正

`reports/t7b3_rl45_timing.txt`：

```
SWNS: 0.113ns, STNS: 0.000ns
HWNS: 0.012ns, HTNS: 0.000ns
Max : SWNS 0.113ns, STNS 0.000ns, 0 Viol Endpoints, 15727 Total Endpoints
Min : HWNS 0.012ns, HTNS 0.000ns, 0 Viol Endpoints, 15727 Total Endpoints
```

route QoR：`Setup WNS +113ps / Setup TNS 0 / violated S-EP 0`、`Hold WNS +12ps / Hold TNS 0 / violated H-EP 0`。契约要求 `SWNS >= 0 && HWNS >= 0`，**已满足**（改前 `SWNS −0.183`）。

#### ★ gate→route 增量 +1,148，比预想的 +2,000 小

上一轮（基线 17,610）的 gate→route 增量是 **+863**；这一轮（基线 15,501）是 **+1,148**。**基线小了 2,109，增量反而大了 285** —— 印证「route 插 buffer 的数量与时序违例数量相关，不是与 LUT 总量线性相关」。这也说明**不能简单按比例外推**：`+863 / 17,610 = 4.9%`，`+1,148 / 15,501 = 7.4%`，比例外推会低估。

#### 位流为什么没出：一处正则假报，与 RTL 无关

`project/t7b_bit3.tcl` 里的产物断言 `T7B_AREA_NO_BRAM` 的正则写的是 `#bram\s+(\d+)\s*/\s*(\d+)`（要求 `N / M`），而 TD 的面积报告实际输出永远是 `#bram                      37   out of     64   57.81%`（带 `out of`）。于是：

- 文件存在、非空、`#bram 37 out of 64` 明明白白在文件里，`PASS-report_area` 已打印；
- 断言却报 `T7B_AREA_NO_BRAM: ... 里找不到 '#bram N / M' 行` 并 `exit 15`，**在 bitgen 之前把流程掐掉**。

`grep T7B_AREA_NO_BRAM` 命中 `project/t7b_bit3.tcl:53` / `:223` / `:228` 三处，修好的是 `:227` 那一处（已改成 `(?:/|out\s+of)`），**触发的是没同步改的另一处**。

> **★ 这条要写进 t9 的纪律清单：「断言假报与漏报一样危险」。** 漏报让 bug 流过测试；**假报把已经成功的结果判成失败，让人去查一个不存在的问题** —— 这次代价是「RTL 明明已经时序全正、place/route 全 PASS、三个门槛全过，位流却没出来」。判据本身（`#bram` 下限）是对的，错的是**读不到就报错**而不是**读不到就报「格式变了，请核正则」**。产物断言应当区分「数值不达标」（真失败）与「解析失败」（断言自身缺陷），后者的文案里必须出现「解析」二字，否则排查方向会被文案带偏。

**修完正则重跑一遍即可出位流，RTL 一行不用动。** 本节的数值全部来自这次已经跑完的 route，重跑不会改变它们。

### §18.14.8 复现（两条命令 + 五份产物）

工程根 `SmartCampusMedia/project/t25_fifo_probe/`：`t25_old.al` / `t25_new.al`（各 66 个 `<File Path>`，由 `project/hdmi_td.al` 生成：工程根下移、`hdmi/` → `../hdmi/`、`../ip/` → `../../ip/`、`async_fifo` 那一项换源）+ `flow_old.tcl` / `flow_new.tcl`（ASCII 无 BOM、LF）+ `old/async_fifo.v`（11,880 B / 242 行）+ `new/async_fifo.v`（16,237 B / 299 行，与 `rtl/common/async_fifo.v` 逐字相同，MD5 `14139BF173A6B5AB`）+ `reports/area_old.txt` / `reports/area_new.txt`。

```powershell
cd D:\FPGA_Compelate\SmartCampusMedia\project\t25_fifo_probe
D:\TD_6_24_APP\bin\td_commands_prompt.exe flow_new.tcl
Select-String -Path reports\area_new.txt -Pattern "^#lut |^#Total_luts|^#reg |^#bram |^#dsp |u_pix_fifo|u_write_fifo"
```

三个前提（都踩过）：①tcl 必须 ASCII 无 BOM 且 LF，中文注释会 `UnicodeEncodeError` 或让 TD 报 `invalid command name`；②`td_commands_prompt.exe` 必须 `cd` 到 tcl 目录后传**相对文件名**（绝对路径的反斜杠被 tcl 当转义吃掉）；③起探针前先 `Get-Process td_commands_prompt` 确认为 0，且空闲内存 ≥ 1,000 MB（本机实测单趟峰值 931 MB，两个并行会吃满）。

