# 视频通路架构补充裁定（ARCH ADDENDUM · VIDEO PATH）

> 文档编号：`ARCH_ADDENDUM_VIDEO_PATH`
> 对应任务：t16（视频接入点裁定）
> 上游输入：用户 m00001 三项裁决（科普= RLE 视频 / 应急=平面示意图 / 屏占比与分辨率是全局显示参数）、队长 t16 任务书、t2 定稿 `ARCH.md`、t13 结构勘察、t15 合规勘察
> 下游消费者：t7 `rtl-engineer`（视频接入点）、t8（例化清单）、t11（SD 卡准备）、t12（合规复核）
> 状态：**定稿**。本文档所有数值均为定稿值，无不可执行占位符。

---

## 0. 一句话裁定

**视频复用图片路的 SDRAM 读出通路**，实现方式不是「把 `image_player` 重写成双模式」，而是**给 `image_player` 增加一个外部写端口**：`rle_decoder` 解码后与 `img_loader` 并列竞争同一个 `framebuf_arbiter`，共用同一个 `pix_reader` 与同一个 `sdram_ctrl_wrap`。补上这一条写口 mux（约 80 LUT）就复用了价值 2,255 le 的 `pix_reader` 与 231 le 的仲裁器。**逐项核算后的净资源变化是 −109 LUT / ±0 BRAM / ±0 DSP**（明细见 §11.1；同时废弃了 `science_page.v` 并与新建的 `emerg_page.v` 相抵）。

---

## 1. 裁定摘要（五条，逐条对应任务书的四问）

| 编号 | 裁定 | 对应任务书问号 | 资源影响 |
|---|---|---|---|
| **D1** | 视频**复用**图片路读出通路，不建独立通路 | 问 1 | 复用 `pix_reader`（2,255 le）+ `framebuf_arbiter`（231 le），避免 +2,180 LUT 直接爆预算 |
| **D2** | `image_player` 只加**外部写端口**（**12 个**新端口，含 1 个供顶层 SD 仲裁的 `ext_loader_want_blk`），内部 FSM 与 `pix_reader` **零改动** | 问 1 | **+97 LUT**（写口 2 选 1 mux +80、`commit_pending` 并列置位分支 +3、`ext_no_fade` 直通 +8、冻结 `load_req` +6） |
| **D3** | SDRAM **不分新地址区**：视频抖动缓冲就是 A/B 双缓冲本身，与 BMP 帧缓冲**地址完全重叠、模式互斥** | 问 2 | +0 word，零额外 SDRAM |
| **D4** | `science_page.v` **废弃**；用 `disp_mode` 延迟生效代替占位页，**零闪黑且不需要第四路 mux** | 问 3 + 任务书额外关切 | **−664 LUT / −1,044 le / ±0 BRAM**（该模块 BRAM 列为 0） |
| **D5** | `content_mux` 从「3 源」简化为「2 源 + mode 选择」，**应急图占用原有 `2'd2` 位置，不是第四路** | 问 4 + 任务书额外关切 | −30 LUT（删 `science_rgb` 输入与一个 case 分支） |

**净资源变化 = −109 LUT / ±0 BRAM / ±0 DSP**（逐项：`image_player` 写口 +97、`pix_mosaic` +40、`pix_reader` +30、`eff_src_w` +18、`content_mux` −30、删 `science_page` −664、新建 `emerg_page` +400）。**本文档给出的方案不增长 LUT 预算，反而腾出 109 LUT；BRAM 与 DSP 完全不变。**

---

## 2. 为什么必须复用图片路（否决独立通路的量化理由）

### 2.1 独立通路的最小代价 = 2,255 le，直接超预算

若为视频单建一条「`rle_decoder` → 独立 SDRAM 区 → 独立 `pix_reader` → `content_mux` 第四路」的通路，最小代价是复制一份 `pix_reader`：

| 模块 | le | lut | bram | dsp | 出处 |
|---|---|---|---|---|---|
| `u_reader`（`pix_reader`） | 2,255 | 2,180 | **0** | 0 | `reports/diag_key1_fifo_backpressure_20261101/area.txt` |
| `u_arb`（`framebuf_arbiter`） | 231 | 183 | **0** | 0 | 同上 |
| `u_sdram`（`sdram_ctrl_wrap`） | 484 | 399 | **0** | 0 | 同上 |

复制 `pix_reader` 一项就要 **+2,180 LUT**，而 LUT 余量（t7-B 集成综合实测）只有 **247**（19,353 / 19,600 = 98.74%，见 `RESOURCE_BUDGET.md` §3.4）。**2,180 > 247 —— 连余量都吃不下，独立通路在物理上不可行，不是"次优"，是"做不出来"。** 复制 `sdram_ctrl_wrap` 更不可能 —— 它独占 SDRAM 物理引脚。

> **引用纪律（务必按此读表）**：`area.txt` 的 `Report Hierarchy Area` 列顺序是 **`le | lut | ripple | seq | bram | dsp`**，不是 `le | lut | reg | bram | dsp`。本表只取 `le` / `lut` / `bram` / `dsp` 四列，中间两列（`ripple` 进位链、`seq` 时序单元）不出现在任何预算行里。**特别注意 `u_reader` 的 `271`、`u_arb` 的 `136`、`u_sdram` 的 `410`、`u_science_page` 的 `380` 全部是 `ripple` 或 `seq`，不是 BRAM** —— 这四个模块的 `bram` 列实际都是 **0**。全设计 17 个 BRAM9K 的分布是：`u_hdmi_tx_controller_wrapper` 14 个 + `u_player` 3 个。

### 2.2 `pix_reader` 与写入者完全无关（队长判断已核实，成立）

读 `rtl/storage/pix_reader.v` 全文核实：**地址推进只依赖 `active_y` 行号 + 行内 `pix_count` 计数，不读也不关心 SDRAM 里的内容是谁写进去的。**

- 状态机 `P_WAIT=0 / P_QUIET=1 / P_DRAIN=2 / P_RESTART=3 / P_READY=4 / P_RUN=5`；
- `blank = in_vblank || (active_y >= FRAME_LINES)`；
- `display_enable = (state == P_RUN) || ((state == P_READY) && de && (active_y == 0))`；
- 行首由 `active_y` 触发读组，行内按 `pix_count` 顺序推进，**没有任何"内容类型"分支**。

**结论：BMP 装载写入与 RLE 解压写入对它完全等价。** RLE 帧同为 640×480 时 `PIX_PER_LINE=640` / `FRAME_LINES=480` 一个都不用改。**队长这一判断经全文核实成立。**

### 2.3 `framebuf_arbiter` 的读基址本来就可运行期改

`rtl/storage/framebuf_arbiter.v` 已有：

```verilog
input  wire        rd_restart;      // 单拍：请求切换读窗口
input  wire [20:0] rd_base;         // 新读基址
output reg         rd_restart_done; // 单拍：切换完成
// 内部：rd_frame_base <= rd_base;
//       rd_frame_last <= rd_base + FRAME_WORDS - 4;
```

`FRAME_BASE` / `FRAME_WORDS` 只在仿真缺省时用，**真实读窗口跟随 `rd_base`**；写窗口在 `WR_ADDR_FROM_FIFO=1` 时跟随 FIFO 里打包的地址。两侧都不是编译期常量，说明当初就是按「多写者共享一块帧缓冲」设计的。

---

## 3. `image_player` 改造：外部写端口（D2）

### 3.1 改造原则：只加端口，不改内部 FSM

`image_player` 内部三个大件都在模块内例化（`rtl/storage/image_player.v`）：

| 行号 | 实例 | 作用 |
|---|---|---|
| `:347` | `img_loader #(.CHAIN_MAX(4096)) u_loader` | SD→BMP 解析→RGB565 |
| `:361` | `bmp_parser #(.CHECK_SIZE(0)) u_bmp` | BMP 头校验 |
| `:369` | `img_scaler #(.DST_W(WIDTH), .DST_H(HEIGHT)) u_scaler` | 缩小到容器尺寸 |
| `:398` | `async_fifo #(.DATA_WIDTH(57), .ADDR_WIDTH(FIFO_AW)) u_write_fifo` | 打包 `{addr, 2'b00, dm, data}`，pix_clk → sdr_clk |
| `:473` | `framebuf_arbiter #(.WR_ADDR_FROM_FIFO(1)) u_arb` | SDRAM 写读仲裁 |
| `:492` | `pix_reader #(.PIX_PER_LINE(WIDTH), .FRAME_LINES(HEIGHT)) u_reader` | 按扫描顺序读出 |
| `:500` | `fade_mixer u_fade` | 换图淡入淡出 |
| `:501` | `sdram_ctrl_wrap u_sdram` | SDRAM 物理接口 |

**改造点只有一处**：`u_arb` 的 `app_wr_*` 目前唯一来源是 `u_write_fifo` 的读出侧。新增 2 选 1 mux，让 `rle_decoder` 也能驱动它。

### 3.2 新增端口清单（12 个）

```verilog
// ---- 追加到 module image_player 端口表末尾 ----
    // 外部写通道（RLE 视频解压直写）。ext_wr_mode=0 时全部输入被忽略。
    input  wire        ext_wr_mode,       // 0=BMP 装载（现状）  1=RLE 直写
    input  wire        ext_wr_valid,      // 单拍写请求
    input  wire [20:0] ext_wr_addr,       // SDRAM 字地址（必须 4 字对齐组首）
    input  wire [31:0] ext_wr_data,       // 2 像素/word，高 16bit 为左像素
    input  wire [3:0]  ext_wr_dm,         // 字节掩码
    input  wire        ext_wr_done,       // 单拍：本帧最后一字已写完
    output wire        ext_wr_ack,        // 单拍：本次写已被 arbiter 接受
    output wire        ext_wr_busy,       // 高：arbiter 尚未回 ack，外部不得推进地址
    output wire        ext_frame_ready,   // 单拍：本帧已提交（vblank 翻页完成）
    output wire [1:0]  ext_frame_sel,     // 当前前台缓冲（0=A, 1=B），供外部诊断
    input  wire        ext_no_fade,       // 1=禁用淡入淡出（视频模式必须为 1）
    output wire        ext_loader_want_blk // 高：u_loader 正在请求 SD 块（供顶层四路仲裁）
);
```

**为什么 `ext_no_fade` 单独一个端口而不是复用 `ext_wr_mode`**：`ext_wr_mode` 是「写通道归属」，`ext_no_fade` 是「显示过渡策略」，两者在 `S_SCIENCE → S_DAILY` 的切换过程中会有 1~2 帧不一致（写通道已交还 BMP，但前台还停在视频最后一帧）。**耦合成一个信号会导致切回日常时第一张图带淡入淡出闪一下** —— 这是本文档拒绝的耦合。

### 3.3 内部改动清单（逐行级）

| 位置 | 现状 | 改法 | 增量 |
|---|---|---|---|
| `:473` 例化 | `.WR_ADDR_FROM_FIFO(1)` | 参数保持 1，新增 `wire wr_owner_ext = ext_wr_mode;` 与写口 mux | +80 LUT |
| `:442-443` 写完成判据 | `expect_words = pixels_sync[18:1]`；`writes_complete = (expect_words != 0) && (written == expect_words) && (write_settle == 15)` | **按 §18.1 修订**：视频路不进 `C_LOAD`/`C_COMMIT`（`load_req` 被冻结），因此不是「切换置位源」，而是**并列新增**一条置位分支 `else if (ext_wr_mode && ext_wr_done_sync) commit_pending <= 1'b1;`。`writes_complete` 本体不改 | +3 LUT |
| `:472` 读基址 | `assign rd_base = front_sync_sdr[1] ? FRAME_SPAN : 21'd0;` | **不改**（视频同样走 A/B 双缓冲） | 0 |
| `:500` 淡入淡出 | `fade_mixer u_fade` 由 `FADE_ON` 与 `fade_alpha` 驱动 | `fade_alpha` 在 `ext_no_fade=1` 时强制 `256`（直通），跳过 `F_OUT/F_IN` | +8 LUT |
| `:207-208 / :218-219` | `display_w <= scale_w` 等 | **不改**（视频不经过 `img_scaler`，但 `out_w/out_h` 只用于 `image_window_mask` 的旧接线，v2 已改由 `ratio_map` 驱动，见 ARCH `:401`） | 0 |
| `pix_reader` 例化 | `:492` | **零改动**（§2.2 已核实） | 0 |
| `img_loader` / `bmp_parser` / `img_scaler` | 现状 | **零改动**，仅在 `ext_wr_mode=1` 时冻结 `load_req` | +6 LUT |

**写口 mux 实现**：

```verilog
// ext_wr_mode=1 时外部接管 arbiter 写口；此时 BMP 装载的 FIFO 数据被搁置
// （async FIFO 有 ALMOST_FULL 背压，搁置不会丢数据，只是不推进）
wire        arb_wr_valid = ext_wr_mode ? ext_wr_valid : fifo_rd_valid;
wire [20:0] arb_wr_addr  = ext_wr_mode ? ext_wr_addr  : fifo_rd_addr;
wire [31:0] arb_wr_data  = ext_wr_mode ? ext_wr_data  : fifo_rd_data;
wire [3:0]  arb_wr_dm    = ext_wr_mode ? ext_wr_dm    : fifo_rd_dm;
assign      ext_wr_ack   = ext_wr_mode && (arb_wr_valid && app_wr_ack);
assign      ext_wr_busy  = ext_wr_mode && ext_wr_valid && !ext_wr_ack;
```

> **必须遵守**：`ext_wr_addr[1:0]` 恒为 `2'b00`。`framebuf_arbiter` 在 `WR_ADDR_FROM_FIFO=1` 模式下要求写地址是 **4 字对齐组首**（FIFO 打包时由 `{word_addr[20:2], 2'b00, ...}` 保证）；外部直接给地址时由 `rle_decoder` 自己保证（它按 4 字一组累加，天然对齐）。

### 3.4 所有权交接时序（谁先停、谁后启动）

**协议约定一句话**：`ext_wr_mode` 只能在 **`!loading` 且 `vblank_rise`** 这一拍切换，切换后至少保持 2 个 `vblank` 周期。

| 阶段 | 日常 → 科普（BMP 交还给 RLE） | 科普 → 日常（RLE 交还给 BMP） |
|---|---|---|
| ① 停旧 | `mode_changed` 后，顶层拉低 `load_req`，等 `image_player.loading == 0` | 顶层拉低 `rle_decoder.play_en`，等 `rle_decoder.want_blk == 0` 且 `sd_spi.blk_busy == 0` |
| ② 静默 | 等 **2 个 `vblank_rise`**（约 33.6 ms @59.52 Hz），确保 `framebuf_arbiter` 的写组流水排空 | 同 |
| ③ 交接 | `ext_wr_mode <= 1`、`ext_no_fade <= 1` | `ext_no_fade <= 0`、`ext_wr_mode <= 0`（**顺序不能反**：先开淡入淡出再交还，否则第一张 BMP 会硬切） |
| ④ 启动 | `rle_decoder.play_en <= 1` | 顶层恢复 `load_req` 脉冲 |
| ⑤ 生效 | 第一帧 `ext_wr_done` → `commit_pending` → `vblank_rise` → `front_sel` 翻到新帧 → 画面出现 | 同（`image_player` 原 `C_LOAD` 流程） |

**为什么必须等 `vblank_rise`**：`image_player` 现有换帧机制就是 `commit_pending` 后在 `vblank_rise = ext_vblank && !vblank_d`（`ext_vblank = (scan_y >= HEIGHT_IN)`）才翻 `front_sel`。若在行扫描中途切写通道，`framebuf_arbiter` 的 `wr_grp_active` 可能停在半组，`WR_STARVE_LIMIT=256` 会在 256 拍后强切写，导致**撕裂一帧**。等 vblank 是零成本的（33.6 ms 用户完全无感）。

**`sd_owner_video` 的归属变更**：ARCH `:447` 原设计把 `img_loader` 归在 `sd_owner_video` 下（注释「它在 `image_player` 内部，通过 `sd_owner_video` 的同一条路径复用」）。**本文档确认这条成立，并把 SD 读块的所有权从"按模块"改为"按 `ext_wr_mode`"**：

```verilog
// 顶层 SD 四路仲裁（替换 ARCH §6.2 的实现）
wire sd_owner_audio   = sd_ok && audio_want_blk;
wire sd_owner_rle     = sd_ok && rle_want_blk && !sd_owner_audio && (ext_wr_mode == 1'b1);
wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail
                        && !sd_owner_audio && !sd_owner_rle;
wire sd_owner_probe   = !sd_ok;
// BMP 装载的 SD 请求来自 image_player 内部 u_loader，其 want 信号经新端口引出：
//   output wire ext_loader_want_blk;   // = u_loader 正在请求 SD 块
wire sd_owner_img     = sd_ok && img_loader_want_blk && !sd_owner_audio
                        && !sd_owner_rle && !sd_owner_gallery && (ext_wr_mode == 1'b0);
```

`image_player` 因此**还要再加 1 个输出端口** `ext_loader_want_blk`（故 §3.2 定稿为 12 个新端口，不是 11 个）。

---

## 4. SDRAM 地址分区与所有权（D3）

### 4.1 关键更正：抖动缓冲不需要额外 SDRAM

任务书估算「RLE 视频抖动缓冲 8 帧 × 最坏 202 KB = 1.62 MB」。**这个估算的前提是「把 RLE 压缩码流缓存到 SDRAM」，本文档不采用这个前提。**

理由：若把压缩码流放 SDRAM，还需要一个「码流→解码→帧缓冲」的第二级管道，等于 SDRAM 里同时存在码流与帧两类数据，仲裁复杂度翻倍。**而采用「解压后直写帧缓冲」时，一帧在 SDRAM 里恒为 `FRAME_WORDS = 153,600` words，与 BMP 帧完全相同 —— 抖动缓冲就是 A/B 双缓冲本身。**

**抖动深度 = 2 帧 = 400 ms @5fps。** 这个深度是否够？算一下 SD 块延迟的最坏值：

| 项 | 数值 | 说明 |
|---|---|---|
| SD 单块 512 B @12.5 MHz SPI | 512 × 8 / 12.5 MHz = **328 μs** | `sd_spi_ctrl.v:SCK_FAST_DIV=1` → 25/2 = 12.5 MHz |
| 一帧最坏 202,431 B | 202,431 / 512 ≈ **396 块** | 实测 p95 194,003 B，取最大值 202,431 B |
| 一帧最坏耗时 | 396 × 328 μs ≈ **130 ms**（不含 FAT/仲裁开销） | 实测均值 129,852 B → 254 块 → 83 ms |
| 抖动深度 2 帧 @5fps | **400 ms** | 相对最坏 130 ms 有 **3.1 倍**裕度 |

**结论：2 帧抖动深度足够，不需要 8 帧。** 而且 2 帧是**物理下限**——不能少于 2 帧，否则前台帧正在显示时后台帧无处可写。**8 帧抖动缓冲（+3.5 MiB SDRAM）是过度设计，本文档不采用。**

### 4.2 SDRAM 地址分区表（8 MiB = 2M × 32bit = 2,097,152 words，21 位地址）

| 区域 | words 范围 | 字节 | 归属 | 模式 |
|---|---|---|---|---|
| 帧 A | `[0x00000, 0x257FF]`（0 ~ 153,599） | 614,400 B | `back/front` 交替 | BMP 与 RLE **共用**（模式互斥） |
| 帧 B | `[0x25800, 0x4AFFF]`（153,600 ~ 307,199） | 614,400 B | `back/front` 交替 | 同上 |
| 保留 | `[0x4B000, 0x1FFFFF]`（307,200 ~ 2,097,151） | 6.83 MiB | 未使用 | — |

- `FRAME_WORDS = 153,600`（= 640×480÷2），`FRAME_SPAN = FRAME_WORDS`；
- 读基址 `rd_base = front_sync_sdr[1] ? FRAME_SPAN : 21'd0`（`image_player.v:472`，**不改**）；
- **BMP 帧缓冲与 RLE 抖动缓冲完全重叠**，靠 `ext_wr_mode` 互斥，物理上任何时刻只有一种内容。

> 这也解释了为什么 WAV 播放**不需要** SDRAM：`wav_stream_player` 用 1024 深度同步 FIFO（1 BRAM9K），全程 25 MHz 同域，无需帧级缓冲（ARCH `:580`）。

### 4.3 为什么「音频优先级高」在地址上无冲突

ARCH §6.4 定的规则（音频 FIFO < 256 时抢占）在本文档方案下**更简单**：音频流根本不碰 SDRAM（只碰 SD 读块端口），因此音频与视频的冲突只发生在 **SD 总线上**，不发生在 SDRAM 上。SDRAM 侧只有视频写（3.07 MB/s @5fps 实测均值折算）与显示读（36.86 MB/s）两方，合计 39.93 MB/s = 24.96% 占用。**这是本方案相比「码流缓存进 SDRAM」方案的第三个结构性优势：SDRAM 零仲裁风险。**

---

## 5. `science_page.v` 去留：废弃（D4）

### 5.1 裁定：废弃，不留占位页

| 维度 | 保留为占位页 | **废弃（采用）** |
|---|---|---|
| 资源 | 继续占 1,044 le / 664 lut / 0 bram | **回收 664 LUT**（该模块 BRAM 列为 0，回收不了 BRAM；单看这一项 LUT 余量 247 → 911，最终口径见 `RESOURCE_BUDGET.md` §3.4） |
| mux 结构 | 需要 3 源（图片 / 科普页 / 应急）→ 再加视频=4 源 | **2 源 + mode 选择**（§6） |
| 回退时序 | 需新写「视频未就绪→科普页→视频就绪→切换」四态时序 + 验证 | **零新增**：`disp_mode` 延迟生效复用现有换帧机制 |
| 闪黑风险 | 切换瞬间需要额外验证 | **零风险**：显示的是上一帧真实内容，不是黑屏也不是静态页 |
| 用户价值 | 开机第一秒不是黑屏 | **同样满足**（见 §5.2），且显示的是真实图库内容 |
| 答辩 | 需要解释「为什么科普页还在」 | **可讲**：「回收 664 LUT 并把回退路径做成零新增逻辑」 |

`rtl/video/science_page.v` 是 **274 行 / 13,601 B**，内容（「认识 FPGA」等文字与 glyph 索引）**全部硬编码在模块内**（`function text_glyph(line, cell_idx)` + `science_font16` 字库），无外部文本接口。用户已明确科普模式为 RLE 视频，**该模块在 v2 中没有任何模式需要它**。

### 5.2 `disp_mode` 延迟生效：零闪黑的正确做法

**问题**：日常 → 科普切换时，`rle_decoder` 的第一帧还没填完，此时若立刻把 `mode` 切到 `2'd1`，`content_mux` 会输出空帧 → 闪黑。

**解法**：`mode_ctrl` 输出**两个**模式信号，并给 `content_mux` 接**后者**：

```verilog
// rtl/control/mode_ctrl.v 端口追加
output reg [1:0] mode;        // 用户意图（各模块用它判断行为）
output reg [1:0] disp_mode;   // 实际显示（只给 video_content_mux）

// 生效规则（三段式 FSM 的输出段）
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) disp_mode <= 2'd0;
    else case (mode)
        2'd0: disp_mode <= 2'd0;                     // 日常：立即生效（图片路一直有内容）
        2'd1: disp_mode <= rle_frame_ready_once ? 2'd1 : disp_mode;  // 科普：等第一帧写入完成
        2'd2: disp_mode <= 2'd2;                     // 应急：立即生效，不等任何外部条件
        default: disp_mode <= 2'd0;
    endcase
end
```

- `rle_frame_ready_once` 是 `rle_decoder` 第一帧的 `ext_frame_ready` 锁存位，在 `mode_changed` 进科普时清零。
- **应急不受延迟约束** —— `emerg_page.v` 是纯组合、零 SD 依赖，内容天然就绪（这也是应急优先级最高的实现体现）。
- **日常 → 科普的等待期显示什么**：`disp_mode` 还是 `2'd0`，`content_mux` 继续选图片路，**显示的是当前 A/B 帧里的真实图库内容**。用户看到的是「按了模式键，画面还是刚才那张图，约 130~400 ms 后视频开始播」。**这不是闪黑，是自然的加载过渡。**

**关键性质**：整条链路**没有新增任何状态机**，`disp_mode` 只是 `mode` 的一个门控寄存器（约 6 LUT）。相比「科普页占位 + 四态回退时序」，这是数量级的简化。

### 5.3 五档分辨率素材的去留（诚实说明）

`assets/v2/sdcard/RES320..RES576` 四套低分辨率原生 BMP 在本方案的 **P0 阶段不使用**（原因见 §7.3：Key8 走读出侧抽样，不靠换素材）。**素材保留在卡上，作为 P2 可选升级**（换素材画质优于抽样，但需要 `fat32_reader` 支持文件名前缀或子目录，改动见 §7.4）。**t4 的产出不浪费，只是排期靠后。**

---

## 6. `content_mux` 最终结构（D5，不是四路）

### 6.1 现状代码（`rtl/video/video_content_mux.v`，38 行全文）

```verilog
rgb_out = 24'd0;
if (de) case (mode)
    2'd2: rgb_out = 24'hFF_00_00;                     // 应急纯红
    2'd1: rgb_out = science_rgb;                      // 科普 → 静态图文页
    default: begin                                     // 0/3 图片路
        if (image_ready)           rgb_out = image_pixel_valid ? image_rgb : 24'd0;
        else if (image_ever_ready) rgb_out = 24'd0;    // 已显示过图又掉 ready：强制黑
        else                       rgb_out = pattern_rgb;  // 从未就绪：测试图案
    end
endcase
```

### 6.2 v2 结构（2 源 + mode 选择）

```verilog
module video_content_mux (
    input  wire        de,
    input  wire [1:0]  mode,          // 接 disp_mode，不是 mode
    input  wire        image_ready,
    input  wire        image_ever_ready,
    input  wire        image_pixel_valid,
    input  wire [23:0] image_rgb,     // 图片路（BMP 或 RLE 视频，由 ext_wr_mode 决定）
    input  wire [23:0] pattern_rgb,
    input  wire [23:0] emerg_rgb,     // 应急平面示意图（emerg_page）
    output reg  [23:0] rgb_out
);
always @(*) begin
    rgb_out = 24'd0;
    if (de) begin
        if (mode == 2'd2) begin
            rgb_out = emerg_rgb;                        // 应急：平面示意图
        end else if (image_ready) begin
            rgb_out = image_pixel_valid ? image_rgb : 24'd0;
        end else if (image_ever_ready) begin
            rgb_out = 24'd0;
        end else begin
            rgb_out = pattern_rgb;
        end
    end
end
endmodule
```

**删除 `science_rgb` 输入端口、删除 `2'd1` 分支。** 科普模式的视频像素**走 `image_rgb`** —— 它就是图片路的输出，与 BMP 完全同一条线。

### 6.3 「3 路变 4 路」的担心不成立

任务书担心「`emerg_page.v` 会成为第四个内容源，mux 从 3 路变 4 路」。**实际变化是 3 源 → 2 源**：

| 内容源 | v1 位置 | v2 位置 | 端口变化 |
|---|---|---|---|
| 图片（BMP） | `image_rgb`（default 分支） | `image_rgb`（default 分支） | 不变 |
| **视频（RLE）** | 无 | **并入 `image_rgb`**（同一个物理端口） | **不增端口** |
| 科普静态页 | `science_rgb`（`2'd1`） | **删除** | **−1 端口** |
| 测试图案 | `pattern_rgb`（回退） | `pattern_rgb`（回退） | 不变 |
| **应急平面图** | 无（原为硬编码 `24'hFF_00_00`） | `emerg_rgb`（`2'd2` 位置） | **+1 端口（占原硬编码的位置）** |

**净端口变化 = 0（−1 科普页 +1 应急图）。** mux 结构**只改一次**，不会出现「刚定完又要改」的情况。

---

## 7. Key8 / Key9 对视频与图片的作用域

### 7.1 Key9（屏占比）：对视频自动生效，零改动

`rtl/video/image_window_mask.v`（43 行，纯组合）的接口是：

```verilog
assign pixel_valid_out = de && pixel_valid && in_window;
```

它门控的是 **`pixel_valid` 这个 1 位有效位**，与像素内容、与产出该像素的模块**完全无关**。既然视频与 BMP 都从 `image_player` 的同一组端口 `rgb565 / pixel_valid` 输出，`image_window_mask` 对两者**天然等价生效**。

ARCH `:401` 已定 `win_w/win_h/win_off_*` 由 `ratio_map`（约 30 LUT）驱动，与 `image_player.out_*` 解耦。**因此 Key9 在科普模式生效是免费的，改动量为零。**

### 7.2 Key8（五档分辨率）：必须换落点（**与 ARCH §3.4 有实质冲突，见 §8**）

在科普模式生效的前提是「读出侧做分辨率变换」，因为 `SCI.RLE` **只有一支 640×480**，`assets/v2/sdcard/RES320..RES640` 里没有分档视频（实测：五个 `RES320`/`RES400`/`RES512`/`RES576`/`RES640` 目录各 7 个文件，全部是 6 张 BMP + 1 个 TXT）。

**采用的实现（零 BRAM、零 DSP）**：

| 方向 | 模块 | 做法 | 增量 |
|---|---|---|---|
| **水平** | 新增 `rtl/video/pix_mosaic.v` | 输入流按 Bresenham 抽样点更新保持寄存器 `hold_pixel`，输出流用同一索引 —— 因 `floor(n·src_w/640)` 单调不减且当它前进时输入流刚好到达该索引，**单寄存器即可，无需行缓存** | +40 LUT |
| **垂直** | 改 `rtl/storage/pix_reader.v` | 行地址生成从「`src_y = active_y`」改为「`src_y = floor(active_y·src_h/480)`」（Bresenham 累加器），同一源行会被读多次 —— 读带宽不变（仍 640×480 全尺寸读出），**零缓存** | +30 LUT |

**正确性验证（320×240 档，`src_w=320`）**：`n=0 → floor(0)=0`，`hold=in[0]`；`n=1 → floor(320/640)=0`，`hold` 保持 `in[0]`（第 1 个像素重复两次 ✅）；`n=2 → floor(640/640)=1`，`hold=in[1]` ✅。输出 640 个像素恰好覆盖 320 个源像素各两次，**边界无累积误差**（Bresenham 保证）。

**`pix_reader` 的改动范围**：新增两个输入端口 `src_w[15:0]` / `src_h[15:0]`，`PIX_PER_LINE` / `FRAME_LINES` 两个 `parameter` 保留为缺省值（不改端口语义）。内部只在行地址生成处加一个垂直 Bresenham 累加器，**行首/行内逻辑、FIFO、状态机零改动**。

### 7.3 为什么 P0 不做「换素材」方案

| 方案 | 改动 | 画质 | 排期 |
|---|---|---|---|
| **P0：读出侧抽样（采用）** | `pix_mosaic.v` +70 LUT，`fat32_reader` 零改动 | 马赛克（最近邻） | 立即 |
| P2：五档原生素材 | `fat32_reader` 需支持目录遍历或文件名前缀参数（现状 `rtl/storage/fat32_reader.v:599-614` 的 `always @(*)` 里 `exp_byte` 逐字节常量表写死为 `IMGnnn.BMP`，`:96` 端口只有 `img_index[8:0]`，取值 1~999）→ +80 LUT + 目录遍历状态机 | 文字清晰（t4 已产出） | 后续可选 |

**P0 采用抽样**：改动小、零 `fat32_reader` 风险、一套素材（`BURN640/` 6 张 BMP + `SCI.RLE`）通吃。**P2 换素材作为画质增强项记录，不进 t7 里程碑。**

### 7.4 三模式 × 两个显示参数的作用域表（推翻 ARCH `:903` 的「仅图片路」表述）

| 模式 | Key8 分辨率 | Key9 屏占比 | 实现路径 |
|---|---|---|---|
| `S_DAILY`（图片） | ✅ 生效（`pix_mosaic` + `pix_reader` 行映射） | ✅ 生效（`image_window_mask`） | 同一条图片路 |
| `S_SCIENCE`（视频） | ✅ 生效（同上） | ✅ 生效（同上） | **同一个** `image_player` 输出端口 |
| `S_EMERG`（平面图） | ✅ 生效（同上，`emerg_page` 输出也经图片路） | ✅ 生效（同上） | **同上** |

**关键**：`emerg_page.v` 的像素**也从 `image_player` 前的位置注入还是从 `content_mux` 注入**？

**裁定：`emerg_page` 从 `content_mux` 的 `2'd2` 位置注入（§6.2）**，因此它**不受** `image_window_mask` 与 `pix_mosaic` 影响 —— 应急阶段画面必须**全屏、满分辨率、最高对比度**，被屏占比裁成 1/2 窗口或马赛克化会直接损害画面中提示信息的可读性。

**但 `KEYMAP.md:185-186` 写「Key8/Key9 三模式全有效」，应急态下按 Key9 应有反应。** 处置：**应急态下 Key8/Key9 的按键仍被消费并更新 `res_sel/ratio_sel` 寄存器值（不吞 `key_event`），但 `disp_mode == 2'd2` 时 `ratio_map` 强制输出 `win_w=640, win_h=480, off=(0,0)`、`pix_mosaic` 强制旁路。退出应急后立刻恢复用户之前选的档位。** 这与 `KEYMAP.md §5.1` 音量「应急下限钳位」的处置方式完全同构（寄存器记用户值，输出端钳位），**不引入新的交互语义**。

---

## 8. 与既有 ARCH 章节的冲突更正表（**必须同步修订 t2 定稿**）

### 8.1 硬冲突：ARCH §3.4 `video_geom_map` 的连线在现 RTL 中不存在

ARCH `:82-90`（像素域框图）画的是：

```
u_video_geom_map ── src_x/src_y ──► u_image_player
                                   ──► u_science_page
                                   ──► u_test_pattern_gen
```

**但 `image_player` 的端口表里没有 `src_x` / `src_y` 输入**（`rtl/storage/image_player.v:20-46`）。它的像素输入侧只有 `de` 与 `scan_y[9:0]`；像素输出 `rgb565/pixel_valid` 是 `pix_reader` 按 **`active_y` 顺序整流出来的**，不接受任意坐标跳读。

**这条连线无法实现**，原因不是「没写」，而是**物理上不该有**：`pix_reader` 是流式预取（`LEVEL_HI=768` 水位、`RD_GROUP_CYCLES=13` 组首间隔），按任意 `src_x` 跳读会打断行预取并让 SDRAM 行缓冲命中率暴跌。

**修正**（本文档 §7.2 已给出实现）：`video_geom_map` 不作为「坐标映射送给源模块」，改为**读出侧的两个独立机制**：

| 原 ARCH §3.4 设计 | v2 修正 |
|---|---|
| `video_geom_map.v` 输出 `src_x/src_y` 给源模块 | 删除该模块的「坐标输出源模块」用途；拆成 `pix_mosaic.v`（水平抽样，读出侧）+ `pix_reader` 垂直行映射 |
| `src_de` 直通 `de` | 不需要（`pix_mosaic` 与数据同拍，不引入延迟） |
| `cfg_changed` 通知源模块清状态 | 改为通知 `pix_mosaic` 与 `pix_reader` 在 `frame_start` 清 Bresenham 累加器（与原 `:335` 的几何稳定策略一致） |

**净效果**：ARCH `:294-330`（§3.4 端口契约）需要**整体替换**为 `pix_mosaic.v` 的端口契约（本文档 §9.1）；`:261-282`（§3.2 取值表）的 `src_w/src_h` 数值**全部保留不变**，只是落点变了；`:331-338`（§3.5 几何稳定）的四条处置**全部仍然成立**。

### 8.2 软冲突：ARCH `:897` / `:903` 的「仅图片路」

- `:897` 与 `:903` 写「`image_mask` 只门控图片路」。**在「视频走图片路」的新结构下，这句话在字面上仍然成立**（视频的像素就是从图片路的那个端口出来的），但**语义上会误导读者的理解**（读者会以为视频不受 Key9 影响）。
- 处置：改为「**门控内容层（图片与视频共用的图片路输出端口），应急平面图除外**」，并在三模式作用域表（§7.4）中明确。

### 8.3 软冲突：ARCH §6.5 `rle_decoder` 端口契约

ARCH `:487-528` 的 `rle_decoder` 端口里有 `play_fps[7:0]` 输入和 `frame_ready` 输出。按本文档 §3.2，`frame_ready` 需要改名为 `ext_wr_done`（语义更准：它是「给出帧的最后一字」，不是「帧已上屏」），并新增 `ext_wr_ack` / `ext_wr_busy` 两个应答输入。**其余端口全部保留。**

### 8.4 冲突汇总表（供 t2 定稿修订直接执行）

| ARCH.md 行号 | 现内容 | 修订为 |
|---|---|---|
| `:62-64` | 存储域里 `u_rle_decoder` 独立写 SDRAM | 标注「写口经 `image_player.ext_wr_*` 借用 `u_framebuf_arbiter`」 |
| `:82-90` | `video_geom_map` 输出 `src_x/src_y` 给三个源模块 | 改为 `pix_mosaic`（水平）+ `pix_reader` 行映射（垂直），删掉 `video_geom_map` |
| `:89-90` | `u_science_page (科普图文页)` | **删除该行** |
| `:99-102` | mux「图片路 / 科普页 / 测试图」 | 改为「内容层（图片或视频）/ 测试图 / 应急图」 |
| `:154` | 科普 = `rle_decoder` | 保留，并补「像素经 `image_player` 的图片路输出端口」 |
| `:155` | 应急 = 红色警报画面 | 改为「应急平面示意图（`emerg_page`，FPGA 内实时栅格化）+ 锁定字幕」 |
| `:294-330` | `video_geom_map` 端口契约 | 整体替换为 `pix_mosaic` 端口契约 |
| `:448-450` | 三路 SD 仲裁（gallery 在 player 之后） | 改为 §3.4 的四路（audio / rle / gallery / img） |
| `:458-474` | §6.3 模式互斥表 | 补「视频与 BMP 共用 A/B 帧缓冲、靠 `ext_wr_mode` 互斥」 |
| `:487-528` | `rle_decoder` 端口 | `frame_ready` → `ext_wr_done`，新增 `ext_wr_ack` / `ext_wr_busy` |
| `:897` / `:903` | 「仅图片路」 | 改为「内容层（图片+视频），应急图除外」 |
| `:997-1003` | 例化 12 `u_pat`（坐标接 `src_x/src_y`）/ 13 `u_science_page`（坐标接 `src_x/src_y`）/ 17 `u_player`（改 `src_w/src_h`）/ 18 `u_rle` | 删第 13 项；第 12 项坐标不再来自 `video_geom_map`；第 17 项见 §3；第 18 项改接外部写口（见 §10） |

---

## 9. 新模块端口契约

### 9.1 `rtl/video/pix_mosaic.v`（新，约 40 LUT，纯组合 + 1 个保持寄存器）

```verilog
module pix_mosaic #(
    parameter H_ACTIVE = 11'd640,
    parameter V_ACTIVE = 10'd480
)(
    input  wire        pixel_clk,
    input  wire        rst_n,
    input  wire        de,
    input  wire [10:0] active_x,       // 输出域列坐标 0~639
    input  wire [15:0] src_w,          // 当前档源宽：320/400/512/576/640
    input  wire [15:0] rgb565_in,
    input  wire        valid_in,
    output reg  [15:0] rgb565_out,
    output wire        valid_out
);
```

**接口时序约定**：

- `valid_out` 是 `valid_in` 的**直通**（`assign valid_out = valid_in;`），不引入任何拍延迟；`rgb565_out` 与 `rgb565_in` **同拍**（在同一个 `pixel_clk` 上升沿后稳定）。
- **行内 Bresenham**：
  ```
  行首（active_x == 0）：x_acc <= 0;  hold <= rgb565_in;
  行内每拍：  x_acc <= x_acc + src_w;
             if (x_acc >= 640) begin x_acc <= x_acc - 640; hold <= rgb565_in; end
             rgb565_out <= hold;
  ```
  当 `src_w == 640` 时每拍都 `x_acc >= 640`（`640 >= 640`），`hold` 每拍更新 → **恒等旁路，零画质损失**。
- `src_w` 必须整除或由 Bresenham 自然对齐；五档 `src_w ∈ {320, 400, 512, 576, 640}` 全部合法（`320: 每 2 拍更新一次；400: 每 1.6 拍；512: 每 1.25 拍；576: 每 1.111 拍`）。
- **`disp_mode == 2'd2`（应急）时由顶层把 `src_w` 强制为 `640`** → 恒等旁路（§7.4 的钳位）。

### 9.2 `rtl/storage/pix_reader.v` 改动（+30 LUT，新增 2 个端口）

```verilog
// 追加到端口表
    input  wire [15:0] src_w,      // 当前档源宽（只用于垂直方向的行映射索引）
    input  wire [15:0] src_h       // 当前档源高：240/300/384/432/480
```

**改动点只有一处**：行地址生成

```verilog
// 现状（rtl/storage/pix_reader.v）：行首直接推进一行
//   row_addr <= row_addr + PIX_PER_LINE;

// v2：
wire [15:0] src_y_mapped = y_acc[15:8];   // Bresenham 垂直映射结果
always @(posedge clk_sdr or negedge rst_n_sdr) begin
    if (!rst_n_sdr) begin y_acc <= 16'd0; end
    else if (new_frame) begin y_acc <= 16'd0; end
    else if (row_advance) begin
        y_acc <= y_acc + src_h;
        // 当 y_acc >= 480 时才真正推进一行，否则重复读同一行
    end
end
// 仅当 (y_acc + src_h >= 480) 时 row_addr <= row_addr + PIX_PER_LINE，
// 并从 y_acc 中扣除 480 —— 即垂直 Bresenham，同一源行被读多次
```

- **状态机、FIFO、`P_*` 六个状态、`LEVEL_HI`/`RD_GROUP_CYCLES` 全部零改动**。
- `src_h == 480` 时 `y_acc + 480 >= 480` 恒成立 → 每行推进一次 → **恒等旁路**。
- **读带宽不变**：仍按 640×480 全尺寸读出（重复行是重复读，SDRAM 侧带宽 36.86 MB/s 已包含这个量级，实测占用 24.96%）。

### 9.3 `rtl/video/emerg_page.v`（新，约 400 LUT，纯组合零寄存器）

```verilog
module emerg_page (
    input  wire        de,
    input  wire [10:0] active_x,
    input  wire [9:0]  active_y,
    input  wire        blink,          // 1 Hz 方波，由 mode_ctrl 提供
    output reg  [23:0] rgb_out
);
```

**接口时序约定**：
- **纯组合**：`rgb_out` 与 `de/active_x/active_y/blink` 同拍，不引入延迟（与 `science_page.v` 的手法一致，`rtl/video/science_page.v` 就是 4 端口纯组合）。
- **像素内容**（t15 的 P0 方案）：外墙框 + 横走廊 + 房间分格竖线 + 当前位置实心块（青 `24'h00_C8_E0`）+ 2 个出口（亮绿加粗）+ 最近路线**直角折线（先横后竖）**。
- **绝不用斜线**（斜率会引入乘法器，DSP 只剩 10/29）。
- **文字不做进本模块** —— 大字提示走已有 `osd_caption.v` 的 `LINE_TICKER=4'd15`（应急态由 `mode_ctrl` 锁定字幕内容，Key5 无效）。
- **`blink` 只用于当前位置块的闪烁**；不需要闪烁时把 `blink` 恒接 `1'b1`（画面静止）。
- 资源：t15 口径 400~600 le；按 `science_page` 的 le→lut 折算比（664/1044 ≈ 0.64），400 le ≈ **256 lut**，取上限 600 le ≈ **384 lut**。**本文档按 +400 LUT 编预算（保守）。**

---

## 10. t8 例化清单变更（对应 ARCH `:982-1024` 的 39 项）

| 变更类型 | 数量 | 明细 |
|---|---|---|
| **删除** | 1 | `u_science_page`（ARCH `:998` 第 13 项） |
| **新增** | 2 | `u_pix_mosaic`（`pix_mosaic`，第 9.1 节）、`u_emerg_page`（`emerg_page`，第 9.3 节） |
| **端口扩展（例化处接线变更，实例数不变）** | 3 | `u_player`（+12 端口，§3.2）、`u_reader` 留在 `u_player` 内部但内部接线改（+2 端口 `src_w/src_h`）、`u_content_mux`（−1 `science_rgb` +1 `emerg_rgb`） |
| **接线变更（不改端口）** | 2 | `u_image_mask` 的 `win_*` 已由 `ratio_map` 驱动（ARCH `:401` 已定）；`u_axis` 不动 |
| **不变** | 31 | 其余（`u_pll` / `u_sdram_pll` / `u_key` / `u_kact`→`u_router` / `u_ctrl`→`u_mode` / `u_vtg` / `u_pat` / `u_sd` / `u_probe` / `u_gallery` / `u_sdram_sip` / `u_overlay` / `u_brt` / `u_osd_pop` / `u_osd_panel` / `u_arc` / `u_hdmi_core` / `u_phy` / `u_err` / `u_buzz` / `u_pwm` / `u_tone` / `u_wav` / `u_rle` / `u_vol` / `u_wave` / `u_ratio` / seg×4 / `u_seg` 等） |

**净实例数：39 − 1 + 2 = 40。**

**新增端口连线（顶层片段）**：

```verilog
// 视频 → 图片路写口借用
rle_decoder u_rle (
    .ext_wr_valid (rle_wr_valid), .ext_wr_addr  (rle_wr_addr),
    .ext_wr_data  (rle_wr_data),  .ext_wr_dm    (rle_wr_dm),
    .ext_wr_done  (rle_wr_done),  .ext_wr_ack   (rle_wr_ack),
    .ext_wr_busy  (rle_wr_busy),  // ... 其余端口见 ARCH §6.5
);

image_player #(.CHAIN_MAX(4096)) u_player (
    // ... 现有端口不变 ...
    .ext_wr_mode      (ext_wr_mode),        // 由 mode_ctrl 的交接 FSM 驱动
    .ext_wr_valid     (rle_wr_valid), .ext_wr_addr (rle_wr_addr),
    .ext_wr_data      (rle_wr_data),  .ext_wr_dm   (rle_wr_dm),
    .ext_wr_done      (rle_wr_done),  .ext_wr_ack  (rle_wr_ack),
    .ext_wr_busy      (rle_wr_busy),  .ext_frame_ready (rle_frame_ready),
    .ext_frame_sel    (),             .ext_no_fade (ext_no_fade),
    .ext_loader_want_blk (img_loader_want_blk)
);

video_content_mux u_content_mux (
    .de (de), .mode (disp_mode),
    .image_ready (image_ready), .image_ever_ready (image_ever_ready),
    .image_pixel_valid (img_pixel_valid), .image_rgb (img_rgb_24),
    .pattern_rgb (pattern_rgb),
    .emerg_rgb (emerg_rgb),                 // 新
    .rgb_out (content_rgb)
);

emerg_page u_emerg_page (
    .de (de), .active_x (active_x), .active_y (active_y),
    .blink (emerg_blink), .rgb_out (emerg_rgb)
);

pix_mosaic u_pix_mosaic (
    .pixel_clk (clk_pixel), .rst_n (rst_n), .de (img_pixel_valid),
    .active_x (img_pixel_x), .src_w (eff_src_w),
    .rgb565_in (img_rgb565), .valid_in (img_pixel_valid),
    .rgb565_out (mosaic_rgb565), .valid_out (mosaic_valid)
);
```

> **`eff_src_w`**：由 `(disp_mode == 2'd2) ? 16'd640 : res_src_w` 生成（应急钳位，§7.4），约 18 LUT。

---

## 11. 资源增量核算

### 11.1 逐项

| 项 | LUT | BRAM | DSP | 说明 |
|---|---|---|---|---|
| `image_player` 写口 mux + 交接控制 | **+80** | 0 | 0 | §3.3 |
| `image_player` `commit_pending` 并列置位分支（§18.1） | **+3** | 0 | 0 | §18.1，取代原「切换置位源」写法 |
| `image_player` 冻结 `load_req` | +6 | 0 | 0 | §3.3 |
| `image_player` `fade_alpha` 直通（`ext_no_fade`） | +8 | 0 | 0 | §3.3 `:500` |
| `pix_mosaic` | **+40** | 0 | 0 | §9.1，单寄存器 |
| `pix_reader` 垂直行映射 | **+30** | 0 | 0 | §9.2 |
| `eff_src_w` 应急钳位 | +18 | 0 | 0 | §10 |
| `content_mux` 简化（删 `science_rgb` 分支） | **−30** | 0 | 0 | §6.2 |
| **删除 `science_page.v`** | **−664** | **0** | 0 | `area.txt` 实测 664 lut / 1,044 le / bram 列 0 |
| `emerg_page.v` | **+400** | 0 | 0 | §9.3（保守上限） |
| **合计** | **−109** | **0** | **0** | 算式 `80+3+6+8+40+30+18−30−664+400 = −109`；净腾出 109 LUT，BRAM/DSP 不变 |

### 11.2 对 RESOURCE_BUDGET 的影响

> **口径提示（2026-11-02 更新）**：本节表格是 t16 当时的口径，写的是「在原 P0+P1 的 17,777 基础上做增量」，因此算出 17,668。但「原 P0+P1 的 17,777」里仍含被本 addendum 替换掉的 `video_geom_map +220` 与 `image_player` 改造 `+180`，直接叠加 −109 会把这两行重复计入一次。**`RESOURCE_BUDGET.md` §3.4 已按「逐行重建」重算；而 t7-B 集成综合实测出来后，当前唯一对外口径是 `19,353 / 19,600 = 98.74% / 余 247`（`reports/t7b_gate_area.txt`）** —— 预算口径的历史链（17,513 → 17,603 → 17,892）只作追溯，不再作为任何判据

| 指标 | 原预算（P0+P1 后，含待替换的两行） | 本 addendum 的净效果 | 变化 |
|---|---|---|---|
| LUT 增减 | — | **−109**（本 addendum 自身的净增减） | **−109** |
| LUT 余量（仅就本 addendum 而言） | 原基数 | **多出 109** | **+109** |
| BRAM | — | **±0** | 0 |
| DSP | — | **±0** | 0 |
| PLL / GCLK / IO | — | 不变 | 0 |

> **注**：`RESOURCE_BUDGET.md` §3.1 原列的 `video_geom_map.v +220 LUT` **对应本 addendum 的 `pix_mosaic +40` 与 `pix_reader +30`**，合计 +70，比原预算省 150 LUT。该行已在 `RESOURCE_BUDGET.md` v2.1 中拆成两行落地。

### 11.3 Hold 时序（+0.003 ns 贴边）的净影响

| 新增模块 | 寄存器数 | hold 影响 |
|---|---|---|
| `pix_mosaic` | 16 FF（`hold[15:0]`）+ 11 FF（`x_acc`） | 新增 2 条短路径，**同域同沿**，hold 风险可忽略 |
| `pix_reader` 行映射 | 16 FF（`y_acc`） | 同上 |
| `image_player` 写口 mux | 0（纯组合） | 不加 hold 检查路径 |
| `emerg_page` | 0（纯组合） | 不加 hold 检查路径 |
| `content_mux` | 0（纯组合） | 不加 hold 检查路径 |
| **删除 `science_page`** | 0（纯组合，但 **−664 LUT 组合逻辑**） | **组合逻辑减少 → setup 改善，hold 不变** |

**净结论**：新增寄存器仅 43 个，全部位于已有同域路径，hold 风险不高于现状；同时删掉 664 LUT 组合逻辑，**setup 反而改善**。M3 综合后仍需按 `RESOURCE_BUDGET.md` §5 的四条强制措施复验 `HWNS`。

---

## 12. 验收用例（给 t7 与 M2 仿真回归）

| 编号 | 用例 | 通过判据 |
|---|---|---|
| **V-01** | `pix_mosaic` 五档恒等性 | `src_w=640` 时 `rgb565_out == rgb565_in` 逐拍相等；`src_w=320` 时每 2 拍输出同值 |
| **V-02** | `pix_mosaic` 边界无累积误差 | 单行 640 拍输出中，`src_w=320` 恰有 320 次 `hold` 更新、`src_w=400` 恰 400 次、`src_w=576` 恰 576 次 |
| **V-03** | `pix_reader` 垂直行映射 | `src_h=240` 时同一源行被读 2 次（`rd_addr` 序列验证）；`src_h=480` 时每行读 1 次 |
| **V-04** | `rle_decoder` 解压正确性 | 对 `SCI.RLE` 前 6 帧解压，每帧 `sum(run) == 307200`；`run_len==0` 展开为 256 像素（**已用二进制证据锁死，见 §13 R-02**） |
| **V-05** | 写口交接无撕裂 | 日常↔科普切换 10 次，`ext_wr_mode` 切换后第一帧无部分写入（`framebuf_arbiter` 的 `wr_grp_active` 在切换前已落） |
| **V-06** | `disp_mode` 延迟生效无闪黑 | 日常→科普切换后 `disp_mode` 保持 `2'd0` 直到 `rle_frame_ready`，期间 `content_rgb` 恒为图片路有效像素（非全黑） |
| **V-07** | 应急钳位 | `disp_mode==2'd2` 时 `eff_src_w==640`、`ratio_map` 输出 `640/480/0/0` |
| **V-08** | `content_mux` 端口缩减 | 编译后 `science_rgb` 端口不存在；`emerg_rgb` 在 `mode==2'd2` 时直通 `rgb_out` |
| **V-09** | 音频不受影响 | 视频播放期间 `wav_stream_player` 的 `fifo_level` 不跌破 `LOW_WM`（`want_blk` 抢占生效） |
| **V-10** | 资源不超限 | TD 综合后 LUT ≤ 19,600 且 `SWNS ≥ 0` 且 `HWNS ≥ 0` |

**静默失败陷阱（必测）**：V-05 若失败，现象不是报错而是**画面偶发一条横向撕裂**，容易误判为显示器问题。仿真中必须在 `ext_wr_mode` 跳变前后各抓 2 帧波形人工确认。

---

## 13. 风险登记（本 addendum 引入或需要下游注意的）

| 编号 | 风险 | 概率 | 影响 | 应对 |
|---|---|---|---|---|
| **R-01** | `image_player` 改 12 个端口后，直接例化它的 **3 个** testbench 编译失败；改 `pix_reader` 端口后，**1 个** testbench 编译失败 | **高** | 中 | 实测（`sim/testbench/` 共 69 个 TB）：例化 `image_player` 的有 `tb_image_player.v:72`、`tb_display_content.v:47`、`tb_startup_ownership.v:50`；例化 `pix_reader` 的有 `tb_pix_reader.v:103`。t7 必须**同时**改这 4 个 TB 的例化（新增端口按 `.ext_wr_mode(1'b0)`、`.src_w(16'd640)`、`.src_h(16'd480)` 缺省接法），否则 M2 回归这 4 个套件全红。**这是本方案最容易被忽略的连带成本。** |
| **R-02** | `run_len==0` 语义若被误解为「无效条目」而非「256 像素」，整帧会缺像素 | 中 | 高 | 已用二进制证据锁死：前 6 帧共 2,371 次 `run_len==0`，按 0→256 映射后每帧 `sum==307200` 全部吻合（脚本验证，见 t16 勘察记录）。写进 `rle_decoder` 的 `err_code=3` 判据（`run_len` 超范围才算非法）。 |
| **R-03** | `fat32_reader` 期望名写死 `IMGnnn.BMP`（`rtl/storage/fat32_reader.v:599-614` 的 `always @(*)` 中 `exp_byte` 常量表：`5'd0..5'd2` = `'I','M','G'`、`5'd8..5'd10` = `'B','M','P'`；`:96` 端口只有 `img_index[8:0]` 无文件名参数），读不到 `SCI.RLE` | **确定发生** | 高 | **必须给 `fat32_reader` 加文件名模式参数**（见 R-04） |
| **R-04** | `img_loader` 的 `CHAIN_MAX=4096` 上限（`image_player.v:347`）对应 16 MiB；`SCI.RLE` 82,362,927 B ÷ 4096 B/簇 ≈ **20,108 簇** → 整文件读必撞 `E_CHAIN(4)` | **确定发生** | 高 | **不做整文件读**：`rle_decoder` 按**帧窗口**分段定位（每帧独立 12 B 头，可用 `SCI.IDX` 的偏移表或逐帧累加 `frame_offset`），每次只让 `fat32_reader` 定位到该帧起点所在簇，读满一帧就重新定位。`CHAIN_MAX` **不用改**。 |
| **R-05** | 视频模式下 `fade_mixer` 每帧翻转 `front_sel` 会淡黑闪烁 | 高（若不处理） | 中 | `ext_no_fade` 端口（§3.2），视频模式强制 `fade_alpha=256` |
| **R-06** | `disp_mode` 延迟生效后，若 `rle_decoder` 首帧永远不完成（SD 卡坏/文件缺失），界面**永远停在日常画面且用户按键"无反应"** | 中 | 中 | `mode_ctrl` 加 **2 s 超时**：超时后强制 `disp_mode <= 2'd1`，画面由 `image_ever_ready` 分支显示黑底 + `osd_caption` 报错行。**必须有超时，否则是"假死"体验。** |
| **R-07** | `pix_reader` 改端口后，`image_player` 内部例化（`:492`）漏接 `src_w/src_h` → 仿真 `x` 传播 | 中 | 高 | t7 例化时 `src_w`/`src_h` 必须显式接 `16'd640/16'd480`（日常默认档） |

---

## 14. 无悬空项声明

| 编号 | 声明 |
|---|---|
| C-01 | 视频接入点 = 复用图片路 SDRAM 读出通路，实现方式 = `image_player` 外部写端口。**非"重写 image_player"**。 |
| C-02 | `pix_reader` 零改动（除 §9.2 的垂直行映射两个端口）。**已全文核实其地址推进与写入者无关。** |
| C-03 | SDRAM 零新增分区：A/B 双缓冲 2×153,600 words = 1.17 MiB，与 BMP 完全重叠、靠 `ext_wr_mode` 互斥。**"8 帧 × 202 KB = 1.62 MB"的估算不采用，理由见 §4.1。** |
| C-04 | `science_page.v` **废弃**，回收 664 LUT / 1,044 le（该模块 BRAM 列为 0，无可回收 BRAM）。 |
| C-05 | 零闪黑靠 `disp_mode` 延迟生效，**不引入占位页、不引入新状态机**（仅 6 LUT 门控）。 |
| C-06 | `content_mux` **3 源 → 2 源**（删科普页 + 加应急图，净端口 0）。**不是四路。** |
| C-07 | Key9 对视频生效 = 零改动（`image_window_mask` 只门控 `pixel_valid`）。 |
| C-08 | Key8 对视频生效 = `pix_mosaic`（水平，+40 LUT）+ `pix_reader` 行映射（垂直，+30 LUT），零 BRAM、零 DSP。 |
| C-09 | Key8/Key9 在应急态**按键仍被消费**（不吞 `key_event`），但输出端钳位为满屏/满分辨率；退出后恢复用户档位。**与 `KEYMAP.md §5.1` 音量钳位同构。** |
| C-10 | ARCH §3.4 的 `video_geom_map → image_player` 连线 **在现 RTL 中不存在且不该存在**，必须整体替换（§8.1）。取值表数值不变。 |
| C-11 | `fat32_reader` 读不到 `SCI.RLE`（写死 `IMGnnn.BMP`）与 `CHAIN_MAX` 超限（20,108 簇 > 4,096）是**两个确定发生的阻塞项**，处置见 R-03 / R-04。 |
| C-12 | 净资源变化 **−109 LUT / ±0 BRAM / ±0 DSP**。方案不增长预算，反而腾出 109 LUT。 |
| C-13 | `RES320..RES576` 四套低分辨率素材在 P0 **不使用**（Key8 走读出侧抽样），保留作 P2 可选升级（画质更优，需 `fat32_reader` 支持文件名前缀）。 |
| C-14 | 应急平面图从 `content_mux` 的 `2'd2` 位置注入，**不经** `pix_mosaic` 与 `image_window_mask`（应急提示必须全屏满分辨率才可读）。 |
| C-15 | 端口扩展的连带成本（已实测）：`image_player` 3 个 TB（`tb_image_player.v:72` / `tb_display_content.v:47` / `tb_startup_ownership.v:50`）+ `pix_reader` 1 个 TB（`tb_pix_reader.v:103`）必须同步改例化（R-01），t7 排期必须计入。另：`tb_science_page.v` 与 `tb_science_font16.v` 随 `science_page.v` 废弃一并删除。 |
| C-16 | 本文档所有数值均可在 RTL 或 `area.txt` 中复核，无不可执行占位符。 |

---

## 15. 答辩口径（三句话）

> **① 为什么视频不能单独走一条路**：「SDRAM 的读出器是 2,255 个逻辑单元的大件，复制一份就超了预算。但它读的是『按扫描顺序取像素』，根本不管像素是谁写进去的 —— 所以我们让视频复用同一个读出器，只加了一条 80 个逻辑单元的写口开关。」
>
> **② 为什么科普模式没有静态页**：「用户明确要视频。留着静态页要多一路选源加一套回退时序，而那套时序用『先显示当前这张图，视频第一帧好了再切』就能免费替代 —— 用户看到的是自然加载，不是黑屏。顺手回收了 664 个逻辑单元。」
>
> **③ 为什么分辨率和屏占比在科普模式也有效**：「这两个是显示参数，不是图库参数。因为视频和图片走的是同一条像素通路，它们天然对两者同时生效 —— 这不是特例处理，是架构决定的。」

---

## 16. `science_page.v` 去留的最终裁定（回应队长 m00784 第一条）

### 16.1 结论：仍废弃，但「缺卡提示」不靠静态页，改由 `osd_caption` 状态行承载

队长的场景是对的：**SD 卡没插 / `SCI.RLE` 缺失 / RLE 解码报错时，科普模式不能是黑的**。但「保留 `science_page.v` 作占位页」不是唯一解，且是成本最高的解。三条路径对比：

| 方案 | 命中「显示稳定性」 | 资源 | mux 结构 | 回退时序 |
|---|---|---|---|---|
| A 保留 `science_page.v` | ✅ | 继续占 **664 LUT + 1,044 le** | 3 源 → **4 源**（图片/科普页/视频/应急），语义边界要重定 | 需新写「视频未就绪→科普页→视频就绪→切换」四态时序 |
| B 废弃 + `disp_mode` 延迟生效（§5.2 原方案） | ⚠️ **只覆盖「有卡但视频首帧未到」**，覆盖不了「完全没卡」 | −664 LUT | **2 源** | 零新增 |
| **C 废弃 + `disp_mode` 延迟生效 + `osd_caption` 状态行提示（采用）** | ✅ **两种场景全覆盖** | **−664 LUT，另 +5 LUT**（`osd_strings` 加一行 case） | **2 源** | 零新增 |

**为什么 B 覆盖不了「完全没卡」**：SD 没插时 `image_ready` 恒 0、`image_ever_ready` 恒 0，`content_mux` 落到第三级回退 `pattern_rgb`（`rtl/video/video_content_mux.v` 的 `default` 分支末句）—— 显示的是**测试图案**，不是黑屏，但也不是任何有意义的提示。

**方案 C 怎么补上这个洞**：`rtl/osd/osd_caption.v` 已有独立的 `state_line[3:0]` 输入通道（`caption_en` 管的是底部 ticker 的 `LINE_TICKER = 4'd15`，`state_line` 是另一条，取 2..7 落在屏幕上部，两者互不干扰）。把「科普模式未就绪」做成一行状态文本：

```verilog
// rtl/control/mode_ctrl.v 追加（纯组合选行号，零寄存器）
// 优先级：应急提示 > 科普缺卡 > 科普等待 > 当前模式行
always @(*) begin
    if (mode == 2'd1 && !image_ready)      state_line = 4'd14;  // "KEPU MODE - SD CARD NEEDED"
    else if (mode == 2'd1 && !rle_ready)   state_line = 4'd13;  // "KEPU MODE - LOADING"
    else                                   state_line = 4'd2;   // 现有日常状态行
end
```

`rtl/osd/osd_strings.v` 加两行 case（`10'd896` / `10'd832` 起，逐字符），约 **+5 LUT**。

- **零新增 mux 端口**：`osd_caption` 在 `video_overlay` 里，位置在 `content_mux` **之后**，所以它对「图片/测试图案/应急图」任何内容层都叠加生效。
- **零新增状态机**：`state_line` 本来就是个选行号的 mux，现在是四选一而非二选一。
- **零新增端口给 `content_mux`**：mux 保持 §6.2 的 2 源结构，**不会被改第二次**。

### 16.2 回答队长的结构问题：「S_SCIENCE 何时走视频、何时走静态页」

**这个判断不需要存在，因为静态页没有了。** 视频像素挂在 `image_rgb` 上（§6.2），永远走图片路；未就绪时由 `content_mux` 现有的三级回退（`image_ready` → `image_ever_ready` 强制黑 → `pattern_rgb` 测试图案）+ `osd_caption` 状态行叠加覆盖。**没有任何「上游 ready 信号决定选哪路」的分支** —— 这正是方案 C 比方案 A 少一套时序的地方。

### 16.3 与 `emerg_page.v` 的对称性（队长关心的「第四个内容源」）

| | `emerg_page.v` | 科普缺卡提示 |
|---|---|---|
| 载体 | **独立内容源**，从 `content_mux` 的 `2'd2` 注入 | **OSD 叠加层**，不占内容源 |
| 为什么不同 | 应急要求**全屏、满分辨率、最高对比度**（§7.4），必须绕过 `pix_mosaic` 与 `image_window_mask`，只能做成内容源 | 提示是**辅助信息**，不需要全屏也不该遮蔽内容 |
| 资源 | +400 LUT（`RESOURCE_BUDGET.md` P0 项） | +5 LUT |
| mux 影响 | 占原硬编码 `24'hFF_00_00` 的位置，**净端口变化 0**（§6.3） | **零** |

→ **`content_mux` 从 3 源变 2 源，不会出现「刚定完又要改」**。这条与 §6.3 一致，无需修订。

### 16.4 对 §5.1 对比表的修订

§5.1 表格中「用户价值」一行原写「同样满足（见 §5.2）」，范围过窄。**更正为**：满足，且覆盖面**大于**保留静态页（静态页只能提示「科普模式」四个字，无法区分「没插卡 / 正在加载 / 文件缺失」；状态行可以）。

---

## 17. `img_scaler` 定位与三问答复（回应队长 m00784 第二条）

### 17.1 首要事实：`img_scaler` 在**写路径**，与 Key8/Key9 的**读路径**不在同一侧

这是队长模型里缺的一块，也是三条追问的共同前提。`rtl/storage/image_player.v` 的完整像素管线：

```
SD 字节流 → img_loader(:347) → bmp_parser(:361) → img_scaler(:369)
          → scale_x/scale_y/scale565
          → word_addr = scale_y*WORDS_LINE + (scale_x>>1) + back_off   (:384)
          → async_fifo(:398) → framebuf_arbiter(:473) → SDRAM 写口
                                                     ↓
                     SDRAM 读口 → pix_reader(:492) → fade_mixer(:500) → rgb565/pixel_valid 出模块
```

→ **`img_scaler` 决定「什么内容被写进 SDRAM」；Key8/Key9 决定「SDRAM 内容怎么被读出来显示」。两侧物理隔离，不存在串联还是二选一的问题。**

### 17.2 逐条回答

**Q1「`video_geom_map` 与 `img_scaler` 是串联还是二选一？」**

**都不是 —— 二者根本不在同一条路径上。** 更准确地说：**`video_geom_map.v` 这个模块在最终方案里不存在**。

§8 已裁定 ARCH `:82-90` 画的 `u_geom ── src_x/src_y ──► u_image_player` 这条连线在现 RTL 中**不存在且不该存在**：`image_player` 端口表 `:20-46` 没有 `src_x/src_y`；`pix_reader` 是**流式预取**（`LEVEL_HI = 768`、`RD_GROUP_CYCLES = 13`），任意跳读会打断行预取、SDRAM 行缓冲命中率崩盘。所以「坐标反查式缩放」这条路本来就堵死。

改为**数据流抽样**（§7.2，两处、共 +70 LUT）：
- 水平：新增 `rtl/video/pix_mosaic.v`，单寄存器 `hold_pixel` + Bresenham 抽样点更新，**+40 LUT**；
- 垂直：`rtl/storage/pix_reader.v` 行地址生成加 `src_h` 垂直 Bresenham，同一源行读多次，**+30 LUT**。

**Q2「SD 卡只放 RES640，`img_scaler` 是否永远 1:1 旁路、是否该摘掉省 LUT？」**

**实测资源**：`area.txt` 的 `u_scaler` = **1,351 le / 958 lut / 0 bram / 4 dsp**（队长引的 1,381 le 是 `ripple` 或 `seq` 列的误读，正确值是 1,351 le）。

**裁定：保留，不摘。** 三条理由，按重要性排序：

1. **摘它要改三处判据，每处都是静默失败点。** `img_scaler` 不是纯装饰，它同时承担三个**控制信号**：
   - `:375` `.out_cfg_ok(scale_cfg_ok)` → `:285` `else if (!scale_cfg_ok || (pixel_count != scale_pixels)) begin failed <= 1'b1; error_code <= 4'd7;`（**像素数校验**）
   - `:375` `.out_pixels(scale_pixels)` → `:434` `pixels_meta/pixels_sync` → `:442` `expect_words = pixels_sync[18:1]` → `:443` `writes_complete`（**写完成判据**）
   - `:377-380` `out_w/out_h/out_off_*`（虽是旧接线，但摘掉要同步确认 `image_window_mask` 已完全改由 `ratio_map` 驱动）
   
   摘除意味着重写这三处，且失败模式是「好帧被误判成故障」或「写完成永不到来导致死等」—— 都是 M4 上板才暴露的静默失败。**省 958 LUT 换三个静默失败风险点，在余量 1,932 的情况下不划算。**

2. **它提供「任意尺寸 BMP 也能显示」的鲁棒性。** `img_scaler.v:24-38` 的设计意图是「把任意源尺寸映射到 640×480 内的最大内接矩形并居中」。若用户自己往卡里放一张非 640×480 的 BMP（很常见的演示动作），有 `img_scaler` 就能正常显示，摘掉就直接 `error_code=4`（宽高不符）。这正是赛规 1.5「显示稳定性与鲁棒性」的加分项。

3. **`bmp_parser` 的 `CHECK_SIZE` 参数默认是 1（严格）**，`image_player` 例化时传 `.CHECK_SIZE(0)`（宽松，`:361`）—— 这个「宽松」正是为了让 `img_scaler` 接手尺寸自适应。两者是配套设计，只摘一个会破功。

**唯一的例外**：若 M3 综合后 LUT 超 19,600，`img_scaler` 是**裁剪顺序里的第 7 位**（`RESOURCE_BUDGET.md` §4 的 C1~C6 之后），且必须同时改上述三处判据 + 把 `bmp_parser` 的 `.CHECK_SIZE` 改回 1。**这是有条件启用项，不是默认项。**

**Q3「如果二选一，切换信号谁给？」**

**不存在这个信号。** 见 Q1 —— 两者不在同一路径。队长担心的「两个缩放串联导致 DDA 要合并」，前提不成立。

### 17.3 否证队长的推论「`video_geom_map` 要同时承担分辨率缩放和屏占比缩放，不是 220 LUT 而是更多」

**实际是更少：70 LUT，不是 220，也不是更多。** 因为两件事的性质完全不同：

| 参数 | 本质 | 实现 | 增量 |
|---|---|---|---|
| Key8 分辨率 | **源域抽样**（同一目标像素取哪个源像素） | `pix_mosaic` 水平抽样 + `pix_reader` 垂直行映射 | **+70 LUT** |
| Key9 屏占比 | **窗口裁剪**（该目标像素是否显示） | `image_window_mask.v` 只门控 1 位 `pixel_valid`，**模块本体零改动**，只换 `win_*` 驱动源 | **+30 LUT**（`ratio_map`） |

- **屏占比不是缩放**。ARCH `:383` 原文「窗口内像素 **1:1 显示，不缩放**」—— 队长模型里把「屏幕大小」理解成了缩放，实际是裁窗口。
- **两者不共享 DDA**：抽样是「按目标坐标取源像素」，裁剪是「按目标坐标判是否可见」。前者改变像素值，后者清零像素值，天然正交、天然串行（先取值后判可见，顺序无所谓因为自变元相同—— ARCH `:388` 已论证）。
- **ARCH `:220` 的 `video_geom_map +220 LUT` 这一行作废**，替换为 `pix_mosaic +40` 与 `pix_reader +30`，**合计省 150 LUT**。这条已列在 §8 冲突更正表。

---

## 18. 「欠载保持上一帧」怎么保证读的是完整帧（回应队长 m00784 第三条③）

队长抓得准：ARCH 只说要「保持上一帧绝不插黑」，没说怎么保证读到的是**完整**帧。答案是**三重机制，且全部复用现有逻辑、零新增**。

### 18.1 第一重：写完成判据是「全帧 153,600 words 全部写入」

`rle_decoder` 在 `ext_wr_mode=1` 时只往**后台帧**（`back_sel = ~front_sel`，即 `FRAME_SPAN` 或 `0` 的另一半）写，**写满整帧的 `FRAME_WORDS = 153,600` 才发 `ext_wr_done` 单拍**。半帧、少一个 word 都不算完成。

`image_player` 侧的置位路径（与 BMP 的 `C_COMMIT` 路径**并列**，不是替换）：

```verilog
// rtl/storage/image_player.v 的 commit_pending 置位块（:203 之前的优先级链）
// 视频路：外部写满一整帧即置位 —— 与 BMP 的 C_COMMIT(:295-296) 并列
always @(posedge pix_clk or negedge rst_n_pix) begin
    if (!rst_n_pix)                          commit_pending <= 1'b0;
    else if (ext_wr_mode && ext_wr_done_sync) commit_pending <= 1'b1;   // ← 新增，+3 LUT
    else if (/* 原有分支：!image_ready / !FADE_ON&vblank_rise / FADE_ON 全黑点 */)
                                             commit_pending <= 1'b0;
    else if (state == C_COMMIT && complete_sync[1]) commit_pending <= 1'b1;  // 原有
end
```

> **注**：`§3.3` 原写「`commit_pending` 的置位源改为 `ext_wr_mode ? writes_complete_ext : writes_complete`」，那句只覆盖了 `C_COMMIT` 内部的分支选择，**不完整**——因为视频路根本不会进 `C_LOAD`/`C_COMMIT`（`load_req` 被冻结）。**以本节这段并列分支为准**，`§3.3` 该行按此修订，增量为 **+3 LUT**（不是 +12），§11.1 合计算式相应变为 `80+3+8+6+40+30+18-30-664+400 = -109`。

### 18.2 第二重：换帧只发生在垂直消隐期

`front_sel` 的翻转点只有三处，**全部被 `vblank_rise` 门控**：`:216`（无淡入淡出的常规换帧）、`:230`（淡出到全黑的换帧点）、`:206`（首帧，此时 `!image_ready`，没有旧帧可撕裂）。

`vblank_rise = ext_vblank && !vblank_d`（`:169`），`ext_vblank = (scan_y >= HEIGHT_IN)` —— 顶层把消隐编码成扫描行号越界。**消隐期翻转 = 有效区内读的必定是同一个 `front_sel`，不会读一半旧帧再读一半新帧。**

### 18.3 第三重：`pix_reader` 在消隐期完成「排空旧帧预取 + 重取新基址」

`rtl/storage/pix_reader.v` 的状态机在消隐期走完整四步（`:144-151`）：

| 状态 | 触发条件 | 作用 |
|---|---|---|
| `P_RUN` → `P_QUIET`（`:151`） | `blank` 有效（进消隐） | 关闭 `run_enable`，等在飞读数据落完（`ARM_QUIET_C = 16` 拍） |
| `P_QUIET` → `P_DRAIN`（`:145-146`） | `arm_count >= 16 && idle_sync` | 把 FIFO 里**旧帧的预取字**排空（`fifo_rd_en` 在 `P_DRAIN` 有效） |
| `P_DRAIN` → `P_RESTART`（`:147-148`） | `arm_count >= 8 && fifo_rd_empty && idle_sync`（`ARM_SETTLE_C = 8`） | 确认 FIFO 真空 |
| `P_RESTART` → `P_READY`（`:149`） | `done_sync != restart_seen` | 等 `framebuf_arbiter` 的 `rd_restart_done`，此时 `rd_frame_base <= rd_base` 已锁定新帧首（`framebuf_arbiter.v:223-224`） |
| `P_READY` → `P_RUN`（`:150`） | `blank_prev && !blank`（出消隐） | 放开预取，`run_enable` 使能 |

→ **`FRAME_SPAN` 的基址切换发生在 `P_RESTART`，而进入 `P_RUN` 之前 FIFO 已真空、基址已锁新值。这是现成逻辑，视频复用零改动**（§3.3 的 `:492 pix_reader 零改动` 一条成立）。

### 18.4 欠载时到底发生什么（逐拍还原）

| 时刻 | 写侧（`rle_decoder`） | 读侧（`pix_reader`） | 画面 |
|---|---|---|---|
| 帧 N 显示中 | 往后台帧写 RLE 解压数据 | `P_RUN`，按 `front_sel` 读前台帧 | 帧 N 完整 |
| SD 带宽不足，写侧慢 | 继续写（`ext_wr_busy` 高，`ext_wr_ack` 靠仲裁器回） | 同上 | 帧 N 完整（**不受写侧进度影响**） |
| 200 ms 到（5fps 预算），写侧还没写完 | 没发 `ext_wr_done` | 新一帧的 `P_QUIET` 到来，`rd_base` **仍是旧值** | **帧 N 保持** ← 这就是「保持上一帧」 |
| 写侧终于写满整帧 | 发 `ext_wr_done` → `commit_pending <= 1` | 下一个 `vblank_rise` 翻 `front_sel` | 帧 N+1 出现 |

**「保持上一帧」不需要任何额外逻辑** —— 它是「`ext_wr_done` 不来 ⇒ `commit_pending` 不置位 ⇒ `front_sel` 不翻」的**自然结果**。这与现有 BMP 装载「慢卡时画面停在上一张」的行为完全同构。

### 18.5 唯一的契约：整帧原子性

`rle_decoder` 一旦开始写后台帧，**必须写完 153,600 words 才允许放弃**；若中途因切模式/复位而放弃，**下一帧必须从头重写整帧，不得续写**。理由：`ext_wr_done` 的语义是「整帧就绪」，续写会让第二次的 `ext_wr_done` 覆盖一个内容混杂的帧（前半旧后半新）。

此契约由 `rle_decoder` 的 `frame_word_cnt` 计数器保证：`play_en` 拉低或 `ext_wr_mode` 撤销时，`frame_word_cnt` 强制清 0，`ext_wr_done` 不得发出。

### 18.6 修正一处带宽口径（自查发现）

§4.1 原写「抖动 2 帧 = 400 ms @5fps vs 最坏 130 ms（396 块 × 328 μs）有 3.1 倍裕度」，其中 **328 μs 用的是理论峰值 1.5625 MB/s，与同段「实用 1.25 MB/s」口径不一致**。更正为双口径：

| 口径 | 单块 512 B 耗时 | 最坏帧 396 块 | 2 帧抖动 400 ms 的裕度 |
|---|---|---|---|
| 理论峰值 1.5625 MB/s | 327.7 μs | **129.8 ms** | **3.08×** |
| **实用 1.25 MB/s（应采用）** | **409.6 μs** | **162.2 ms** | **2.47×** |

**结论不变（裕度 > 2×，2 帧抖动足够），但对外一律引实用口径 162 ms / 2.47×。**

---

## 19. 资源基线口径声明（回应队长 m00784 第四条）

工作区同时存在两份 `area.txt`，数值不同，**都真实**：

| 报告 | `#lut` | 时间 | 说明 |
|---|---|---|---|
| `reports/d810_fix_20261031/area.txt` | **15,123**（77.16%） | 2026-10-31 17:24 | 历史快照，**已作废**（只作口径差异引用，不作任何判据） |
| `reports/diag_key1_fifo_backpressure_20261101/area.txt` | **15,319**（78.16%） | 2026-11-01 18:47 | **唯一有效基线，全工程采用** |

差 196 LUT 来自 11-01 的 `diag_key1_fifo_backpressure` 修复（FIFO 背压 + 看门狗）。**两者都是 t5 开始前的快照，t5 的六个新模块（约 2,014 行）尚未综合，真实余量必然小于下表数值。**

本文档统一口径：**基线 15,319**。当前最终数字以 `RESOURCE_BUDGET.md` §3.4 为准 —— **t7-B 集成综合实测 19,353 / 19,600 = 98.74%，余 247**（2026-11-02 四次裁定；历史口径 17,892 / 91.29% / 余 1,708、17,603 / 89.81% / 余 1,997、17,513 / 89.35% / 余 2,087 均已同日被取代）。本文档 §11.2 的 17,668 是 t16 当时的增量口径，保留作历史记录（差异成因见 §11.2 口径提示）。引用时须注明「15,319 是 t5 前快照，t5 综合后须重算」，避免 t10 终审把 15,123 与 15,319 当成矛盾。

---

**文档结束。**