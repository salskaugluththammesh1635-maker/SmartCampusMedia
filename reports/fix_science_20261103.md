# 科普模式 RLE 视频与中文字幕修复报告（问题③「只剩一条蓝条」）

- 任务：t9 / SmartCampusMedia v2
- 日期：2026-11-03
- 依据：`reports/diag_science_20261103.md`（t5 诊断）＋ 本报告第 4 节的实测复算
- 结论摘要：**两个互相独立的 P0 都已修复并回归通过**；但「卡上没有 SCI.RLE」是素材装配问题，
  代码修不了，本次改为让它**在数码管上可见（d6）**。详见第 7 节。

---

## 0. 一句话结论

| | 修复前 | 修复后 |
|---|---|---|
| 视频画面 | 一帧都不出（`R_ERR` 永不自愈） | 归属门控后不再被 WAV 的块完成误触发，可按 5 fps 逐帧解码上屏 |
| 中文字幕 | 一个像素都不出（`narr_on` 占空比 2e-7 且落在 de=0） | 用 `ext_ever_framed` 电平驱动，真的翻过一帧后立即常亮，可逐帧推进 |
| 失败可见性 | 完全静默（数码管照显 `4`=PLAY） | 数码管显示 `bE/dE/d0/d1/d5/d6`，蜂鸣器告警 |

**但**：若 SD 卡上 `SCI.RLE` 根本没拷进去（`assets/v2/sdcard/RES640/` 目录正好就是这种情况——
只有 6 张 BMP，没有 `SCI.RLE`），则无论 RTL 怎么修都不会有画面。修复后这种情形会显示 **`d6`**。
这是本次上板最可能的现场成因，详见 7.1。

---

## 1. 断点定位表（哪一级断了 → 改成什么）

按信号从后往前逐级核对（L0 是素材，L1..L8 是 RTL）：

| 级 | 环节 | 原实现 / 断点 | 结论 | 改成什么 | 文件:行 |
|---|---|---|---|---|---|
| L0 | SD 卡素材 | `assets/v2/sdcard/RES640/` 只有 6 张 BMP，**无 `SCI.RLE`**（`BURN640/` 才有） | **断（代码修不了）** | 不改 `gallery_probe`「没找到不算故障」语义；改为在科普模式下显示 `d6` 提示 | 顶层 `:576-581`、`err_prompt.v:352-392` |
| L1 | `rle_lba_vld` 锁存 | `gallery_done && gallery_rle_found && !gallery_rle_fail && !rle_lba_vld` | 逻辑正确，但受 L0 钳制 | 未改（正确） | 顶层 `:367-385` |
| L2 | `rle_play_en` | `rle_lba_vld && m_science && (gallery_done \|\| gallery_fail)` | 逻辑正确，但受 L1/L0 钳制 | 未改（正确） | 顶层 `:396` |
| L3 | `sd_grant_rle` 仲裁 | `sd_owner_playseg && !wav_want_blk && rle_want_blk`，`sd_arb_start` 按 owner 掩码 OR | **逻辑正确**（WAV 绝对优先是设计意图，不是缺陷） | 未改（正确） | 顶层 `:430/:437/:441/:446` |
| L4 | `blk_start` 握手 | `assign blk_start = blk_start_int && sd_grant;`，`blk_addr <= file_lba + blk_index` 与请求同拍 | **逻辑正确** | 未改（正确） | `rle_decoder.v:682-688` |
| **L5** | **`blk_done`/`blk_err` 归属** | `if (blk_done) …` / `else if (blk_err) …`，**无任何归属判据**。而 `blk_done` 是 `sd_spi_ctrl` 对**五路消费者**的广播 | **P0-A2 断点** | `if (req_sent && blk_done)` / `else if (req_sent && blk_err)` | `rle_decoder.v:705`、`:712`（注释 `:689-704`） |
| L6 | 帧提交 | `ext_wr_done` → `commit_pending` → 三处翻帧点置 `ext_frame_ready_r` | 逻辑正确 | 未改（正确） | `image_player.v:271-341` |
| **L7** | **字幕使能 `narr_on`** | `m_science && rle_frame_ready && narr_frame_ok`，把**每帧 1 个 40 ns 的单拍脉冲**当持续电平用 | **P0-B 断点** | 新增 `ext_ever_framed` 粘滞电平，`narr_on = m_science && rle_ever_framed && narr_frame_ok` | `image_player.v:82/193/265/273/302/314/341/612`；顶层 `:516`、`:761`、`:1126` |
| **L8** | 失败可见性 | `rle_err_code`/`rle_underrun` 只声明、只接输出、**零消费者**；`err_prompt` 无任何 `rle_*` 端口 | **P1-a 断点** | `err_prompt` 新增 `rle_bad`/`rle_err`，顶层做三档来源合成 | `err_prompt.v:123-124`、`:352-392`；顶层 `:575-581`、`:1332` |

### 1.1 P0-A2 的失效链（为什么它必然发生，不是"理论窗口"）

```
科普模式下 NARR.WAV 同时在流（audio_src_mux.v:70 MODE_SCIENCE → SRC_NARR）
  → WAV 的块完成也拉 blk_done（sd_spi_ctrl 只有一条广播线）
  → 顶层 sd_owner_rle 被 WAV 抢占（WAV 绝对优先），RLE 停在 R_NEXT_BLK 等 grant
  → 这期间 WAV 的 blk_done 到达，rle_decoder 误认为"我的块好了"
  → blk_index++（实际没读到那块）→ 之后按错块号读 → 解错字节
  → 帧头对不上 → err_code 1/2/4 → R_ERR
  → R_ERR 里没有回 R_IDLE 的路径 → 永不自愈
```
一帧平均 255 块（实测 130527.6 B/帧 ÷ 512 B ≈ 255），第一帧内几乎必然撞车。

### 1.2 P0-B 的量化依据

- `ext_frame_ready` 每帧只有 **1 个像素时钟（40 ns）** 为高：5 fps 下占空比 = 40 ns / 200 ms ≈ **2e-7**（精确到 1/416800）。
- 且三个置位点都在 `vblank_rise`（顶层把消隐编码成 `scan_y = 480` 传入）→ 脉冲落在 **de=0** 区间，
  而 `video_overlay.v` 的 `rgb_out = de ? rgb_mixed : 24'd0` 会把该区间整段输出黑。
- 副作用：`narr_en=0` 时 overlay 会**关掉整个字幕层**（含 `narr_subline` 的标题/状态行），
  而 `frame_idx` 0..3 期间又没有字幕内容 → 早期实现下字幕层"全程全黑"是必然结果，不是偶发。

**顶层边沿检测救不了**：拿到的仍然是单拍脉冲。粘滞位必须做在 `image_player` 内部，与
`ext_frame_ready_r` 并列生成。

---

## 2. 几处关键设计取舍的理由

### 2.1 归属门控用 `req_sent`，不新引入 `my_blk_active`

`rle_decoder` 的 `blk_start_int` 只在 `R_NEXT_BLK` **一个状态**发出，`req_sent` 从发出那一刻
置位、到 done/err/帧结束/复位才清零，期间不会回到 `R_NEXT_BLK`——语义正好是
"这块是我发的、我还在等它完成"。功能上与被 `wav_stream_player` 采用的 `my_blk_active`
范式等价，但作用域更窄、少一个需要同步的标志。

`wav_stream_player` 之所以需要 `my_blk_active`，是因为它的 `blk_start` 是**电平持续型**
且要跨多个状态识别归属（`wav_stream_player.v:210/335-336/344`）。两者不是同一场景。

### 2.2 为什么 `blk_err` 必须一起加门控

只挡 `blk_done` 不挡 `blk_err` 的话，**别人的块失败**仍会把本模块的 `req_sent` 清掉，
并把 FSM 直接打进 `R_ERR`（同样永不自愈）。两个分支必须成对处理。

`req_sent = 0` 期间收到的 done/err 被安全忽略：FSM 停在 `R_NEXT_BLK` 原地等 grant
（`!req_sent && !sd_grant` 的停车语义不变），不会死锁。这一点由 CASE 6A 断言覆盖。

### 2.3 粘滞位为什么必须做在 `image_player` 内部

顶层只能看到 `ext_frame_ready` 这个单拍信号，做边沿检测得到的仍是单拍。只有
`image_player` 知道"哪一拍真的翻了帧"，因此：

- `reg ext_ever_framed_r` 与 `ext_frame_ready_r` 并列（`image_player.v:193`）；
- 复位清（`:265`）；
- 三个翻帧点（首帧提交 `:302`、`!FADE_ON || ext_no_fade` 硬切换 `:314`、fade 全黑翻帧 `:341`）
  各置 1；
- **`if (!ext_wr_mode) ext_ever_framed_r <= 1'b0;`（`:273`）**——退出视频/科普即清；
- `assign ext_ever_framed = ext_ever_framed_r;`（`:612`）。

### 2.4 为什么必须保留 `frame_idx >= 4` 与 `<= 624`

- `>= 4`：进入科普的前 4 帧里 `narr_subline` 还没有内容（段 0 从 `frame_idx=4` 开始）。
  若此时 `narr_en=1`，overlay 的字幕层会打开但输出空白/全遮，把标题与状态行一起关掉 → 整层全黑。
- `<= 624`：素材共 631 帧，留 6 帧余量；回绕到 0 时判据变假（字幕短暂关闭）是设计意图，
  避免用上一轮的尾部字幕错配到新一轮开头。

两条约束在改动中**明确保留**，注释也写明保留理由（顶层 `:1099-1125`）。

### 2.5 为什么 `rle_underrun` 刻意不接进 `err_prompt`

`underrun` 的语义是"这一帧没按时起新帧"（`JITTER_FRAMES=3` 帧 ≈ 600 ms 无新帧），
属**性能抖动**而非故障。接进 `err_prompt` 会让数码管整组切成错误显示、把播放状态盖掉，
用户会误以为设备一直在报错。真正的解码/读卡失败走 `rle_err_code`（粘滞，`!play_en` 才清）。
抖动问题见 8.1（P2）。

### 2.6 为什么没有改 `R_IDLE` 的 `gap_tick`（P2，遗留）

`rle_decoder.v:497` `R_IDLE: if (gap_tick && !blk_busy && !eof_stop)`：`gap_tick` 是**单周期脉冲**，
而 `!blk_busy` 是全局条件（不含"这个 busy 是不是我的"）。撞上 WAV 块事务（约 6.4% 时间）
时这一拍就白丢，整帧滑后 200 ms → 实测 5 fps 会退化成约 4.7 fps 抖动。

**本次不改**，理由：①它不导致"完全不出画面"，只在已经出画面后影响帧率均匀性；
②`R_IDLE` 是所有帧的起点，改错会引入"卡在某帧"的新风险，高于当前收益；
③captain m00122 明确授权"只做 P0、P2 写进报告"。留给后续单独处理（建议方案：
把 `gap_tick` 改成"见 tick 即锁存 pending，等 `!blk_busy` 再起帧"，或在 `req_sent` 期间
暂存 tick）。

---

## 3. 带宽 / 帧率算术（用真实素材实测，不估算）

### 3.1 实测原始数据

用脚本顺序解析 `assets/v2/sdcard/BURN640/SCI.RLE`（帧头 12 B = magic(4)+W(2)+H(2)+runs(4)，
body = runs×3）：

```
frames=631  consumed=82362927  total=82362927  exact=True
avg=130527.6 B/frame   min=3612   max=203484 (max_idx=269)
```

`exact=True` 说明该文件可以**按顺序完整解析、无填充**，这正是解码器
`blk_addr = file_lba + blk_index` 顺序读整条流的可行性依据 → **不需要引入 `SCI.IDX`**
（`SCI.IDX` 在 RTL 中确实完全未被引用，只有两处注释提到它）。

> 对诊断报告的一处更正：报告里写作"峰值 134787 B（帧 625）"。实测 **帧 625 = 134787 B 是对的，
> 但全 631 帧的最大值是 203484 B（帧 269）**。下面按 203484 B 这个更坏的值重算，结论不变。

### 3.2 总线能力

`sd_spi_ctrl.v:37` `SCK_FAST_DIV = 1` → SCK = 25 MHz / 2 = **12.5 MHz** → **1.5625 MB/s**。
单块 512 B = 512×8 / 12.5e6 = **327.7 µs ≈ 0.328 ms**。

### 3.3 逐项占用（帧周期 200 ms = 5 fps）

| 项目 | 字节数 | 传输时间 | 占 200 ms |
|---|---|---|---|
| 平均帧 × 631 | 130527.6 | 83.5 ms | **41.8 %** |
| NARR 音频（48 kHz×16 bit×单声道×0.2 s） | 19200 | 12.3 ms | 6.1 % |
| **平均帧 + 音频** | — | 95.8 ms | **47.9 %** |
| 最坏帧（203484 B） | 203484 | 130.2 ms | 65.1 % |
| **最坏帧 + 音频** | — | 142.5 ms | **71.3 %** |

- 平均每帧块数 = 130527.6 / 512 ≈ **255 块**，255 × 0.328 ms ≈ **83.6 ms**（与 41.8% 一致）。
- **全 631 帧中，加上音频后超过 200 ms 的帧数 = 0。**
- 631 帧 @5 fps = **126.2 s**；整文件纯顺序读 52.7 s。

### 3.4 结论

**带宽不是瓶颈，5 fps 保持不动。** 最坏帧仍有 28.7% 余量。不需要降帧率、
不需要预压缩、不需要降分辨率。真正的节拍风险是 2.6 里的 `gap_tick` 单拍撞车（P2）。

---

## 4. 改动文件清单（含行号范围）

### 4.1 RTL（4 个文件）

#### `rtl/storage/rle_decoder.v`（+20 行）

| 行号 | 内容 |
|---|---|
| `:689-704` | 新增 16 行中文注释：广播语义、`req_sent` 语义正对、为何不引入第二套标志、不加门控的完整失效链、为何 `blk_err` 必须一起加、`req_sent=0` 期间安全性 |
| `:705` | `if (req_sent && blk_done) begin`（原 `if (blk_done) begin`） |
| `:712` | `end else if (req_sent && blk_err) begin`（原 `else if (blk_err) begin`） |

两个分支体**逐字未改**；`:497` 的 `R_IDLE` 条件未改（见 2.6）。

#### `rtl/storage/image_player.v`（+36 行，现 664 行）

| 行号 | 内容 |
|---|---|
| `:75-81` | 新增 7 行端口注释（单拍脉冲当电平常用的占空比与 de=0 问题、顶层边沿检测无效、清零语义） |
| `:82` | `output wire ext_ever_framed,` |
| `:193` | `reg ext_ever_framed_r;`（紧跟 `reg ext_frame_ready_r;`） |
| `:265` | 复位清 `ext_ever_framed_r <= 1'b0;` |
| `:269-273` | 每拍默认后 `if (!ext_wr_mode) ext_ever_framed_r <= 1'b0;` + 5 行注释（不清 0 会导致退回日常再进科普时第一帧前就开字幕） |
| `:302` | 首帧提交分支置位 |
| `:314` | `!FADE_ON \|\| ext_no_fade` 硬切换（`vblank_rise`）置位 |
| `:341` | fade 全黑翻帧分支置位 |
| `:610-612` | `assign ext_ever_framed = ext_ever_framed_r;` + 3 行注释 |

**未触碰 t7（video-engineer）在 fade 分支补的 `display_w/h/off_x/off_y` 四行赋值**：
t7 的注释在 `:324-333`、四行 `display_* <= scale_*` 在 `:334-337`，均原样保留；
我的置位只加在它们之后的 `:341`（`ext_frame_ready_r <= 1'b1;` 的下一行）。

#### `rtl/control/err_prompt.v`（+69 行，现 436 行）

| 行号 | 内容 |
|---|---|
| `:117-122` | 新增 9 行注释（零消费者导致故障静默、优先级位置） |
| `:123` | `input wire rle_bad,` |
| `:124` | `input wire [3:0] rle_err,` |
| `:352` | `end else if (rle_bad) begin`（插在 `image_failed` 分支 `endcase` 之后、`gallery_done && count==0` 之前） |
| `:353-368` | 子码对照注释（1→bE 魔数 / 2→dE 几何 / 3→d0 run 表 / 4→d1 读卡 / 5→d5 簇链 / 6→d6 卡上无文件 / 其他→d9），并说明为何 4 用 `d1` 而不是 `d4`、为何新 `d5/d6` 与 image_player 的 `d5/d6` 数字重复但语义不同（前者只在科普视频层出现，且图片层失败会被上行分支抢先） |
| `:369-405` | `err_active = 1'b1;` + `case (rle_err)` 7 个分支实现（每支都写清用户动作） |
| `:406-422` | 后续两支的注释改为「第 5 优先: 卡是好的但一张图都没有（**t9 起让位给视频层**，本支从第 4 顺延到第 5）」「第 6 优先: 探测还没跑完但卡座报告无卡」 |

**优先级顺序**：`sd_fail > gallery_fail > image_failed > rle_bad > 零张图 > sd_cd`。
段码表（`project/hdmi/seg_decoder.v:86-102`）只支持 `0..9 / A / b / C / d / E / F`，
所以魔数错用 `b`+`E`、几何错用 `d`+`E`——`E` 是唯一还能表达"格式/几何"语义的字母
（没有 `r`/`P`/`n`）。

#### `rtl/top/dmz_eg4s20_hdmi_top.v`（+177 行，现 1391 行）

| 行号 | 内容 |
|---|---|
| `:496-510` | 原「已知风险（不在本层修，登记备查）」整段**改写**为「blk_done / blk_err 广播问题的处理（2026-11-03 t9 已修，原风险登记作废）」。逐条写明：①`rle_decoder` 已加 `req_sent` 门控、其余四路原本就有归属判据；②**原注释写的缓解理由是错的、已删除**：「科普模式下 WAV 仍在播 BGM」不成立——`audio_src_mux.v:70` 是 `MODE_SCIENCE: sel_c = SRC_NARR`，NARR 更短、循环更频繁，抢总线只会更凶；正是这条错误前提把 P0 低估成"理论窗口" |
| `:514-516` | `wire rle_ever_framed;` + 3 行注释 |
| `:542-586` | 新增可观测性整段（45 行）：`rle_scan_settled`（`:575`）、`rle_meta_fault`（`:576`）、`rle_absent`（`:577-578`）、`rle_bad`（`:579`）、`rle_err_view`（`:580-581`）；上方 40 行注释（`:543-574`）说明为何必须补、为何用组合不打拍（`err_code` 本身粘滞且 `!play_en` 清 0）、为何把"卡上没有 SCI.RLE"也纳进来（**不改 `gallery_probe` 语义**，只在 `m_science` 下提示）、以及 `rle_underrun` 刻意不接的理由（`:582-586`） |
| `:750-761` | u_player 例化新增 `.ext_ever_framed(rle_ever_framed),` + 12 行注释（为何不能用顶层边沿检测、为何清零条件放 image_player 内） |
| `:1099-1125` | narr 段注释整体重写：标注原实现「把单拍脉冲当电平用，等价于字幕永远不显示」、占空比 1/416800、置位落在 vblank(de=0)、`video_overlay.v` 的 `rgb_out = de ? rgb_mixed : 24'd0`；**明确保留** `frame_idx>=4` 与 `<=624` 两条约束及理由 |
| `:1125` | `wire narr_frame_ok = (rle_frame_idx >= 16'd4) && (rle_frame_idx <= 16'd624);`（未变） |
| `:1126` | `wire narr_on = m_science && rle_ever_framed && narr_frame_ok;`（原为 `rle_frame_ready`） |
| `:1296-1310` | 数码管说明注释新增【t9 新增 视频层】14 行：`bE` 魔数 / `dE` 几何 / `d0` run 表 / `d1` 读卡 / `d5` 簇链 / `d6` 卡上没有 SCI.RLE（注明是本次现场最可能成因、只在科普模式出现） |
| `:1328-1332` | u_err 例化新增 `.rle_bad(rle_bad), .rle_err(rle_err_view),` + 3 行注释 |

### 4.2 testbench（3 个文件）

#### `sim/testbench/tb_rle_decoder.v`（904 → 1015 行，+117 行）

| 行号 | 内容 |
|---|---|
| `:110-130` | 新增 `reg inject_done/inject_err/card_mute`、`wire blk_done_bus = blk_done \| inject_done`、`wire blk_err_bus = blk_err \| inject_err` + 14 行注释（广播语义、为何需要一个能在"别人的块"上打脉冲的注入口） |
| `:189-191` | `integer own_idx_snapshot`、`reg [2:0] own_state_snapshot`（快照变量） |
| `:210-213` | DUT 连接改为 `.blk_done(blk_done_bus), .blk_err(blk_err_bus)` |
| `:342` | SD 卡模型改为 `end else if (blk_start && !card_busy_r && !card_mute) begin`（`card_mute=1` 时卡不理请求，让用例自己决定这一块的成败） |
| `:912-994` | **新增 CASE 6**（14 条 chk）：6A `grant_force_low=1; card_mute=1;` → 等 `state==R_NEXT_BLK` → 断言 parked/`req_sent==0` → 注入单拍 `inject_done` → 断言 `blk_index` 不变、`state` 不变、`req_sent` 仍 0、`err_code==0`；再注入 `inject_err` → 断言**不进 `R_ERR`**、`blk_index` 不变。6B 释放 grant、等 `req_sent==1` → 注入单拍 `inject_done` → 断言 `req_sent` 清、`blk_index` 恰 +1、`state != R_NEXT_BLK` |

原 58 条断言（CASE 0..5）一行未动。

#### `sim/testbench/tb_err_prompt.v`（327 → 375 行，+50 行）

- 头注：C7 优先级改为 `sd_fail > gallery_fail > image_failed > rle_bad > 零张图 > sd_cd`；新增 C12 说明。
- `:59-60` `reg rle_bad = 1'b0; reg [3:0] rle_err = 4'd0;`
- `:85-88` DUT 新增 `.rle_bad(rle_bad), .rle_err(rle_err),`（注释：不接会悬空为 z，组合逻辑吃 X 后整个提示层输出 X）。
- `:152` `clear_all` 任务新增清零。
- `:247-273` **新增 C12 视频层分类**（8 条）：`1→bE`、`2→dE`、`3→d0`、`4→d1`、`5→d5`、`6→d6`、default→`d9`、`rle_bad=0` 后必须回到无提示（`:271-273`）。
- `:301`、`:316-320` C7 优先级链扩充（加入 `rle_bad=1; rle_err=4'd4`，并新增「撤掉 `image_failed` → 视频层接管 `d1`」「撤掉 `rle_bad` → 才轮到 C0」两条）。

#### `sim/testbench/tb_image_player.v`（787 → 909 行，+140 行）

| 行号 | 内容 |
|---|---|
| `:46-61` | 新增 `reg ext_wr_mode_r/ext_wr_done_r/ext_no_fade_r`、`wire ext_ever_framed` + 12 行注释（为何 `valid/addr/data/dm` 仍接 0：本 case 只验证提交/电平语义，不写像素） |
| `:100-108` | DUT 连接改为 `ext_wr_mode(ext_wr_mode_r)`/`ext_wr_done(ext_wr_done_r)`/`ext_no_fade(ext_no_fade_r)`/`ext_ever_framed(ext_ever_framed)` |
| `:834-897` | **新增 CASE 15**（6 条断言）：`:857` 进模式前必须 `ext_ever_framed==0`；`:861` 进模式 200 拍无 done → 仍 0；`:879` 注入单拍 done → 20k 拍内变 1；`:884-888` 连采 600 次必须 600 次为 1（证明是**电平**不是单拍）；`:892` `ext_wr_mode` 落下即回 0；`:895` 再等 200 拍仍为 0 |

> CASE 15 的判据刻意用**粘滞位本身**而不是 `front_sel` 翻转：在 `SEAMLESS=0` 的 case 里
> `back_sel` 恒 0、`front_sel` 不翻转，但提交照样发生——用 `front_sel` 会假失败。

### 4.3 派生产物（`scripts/sync_src.ps1` 自动同步）

`project/hdmi/` 下 5 个副本被更新并逐对校验哈希 `SAME`：
`image_player.v`、`img_scaler.v`、`err_prompt.v`、`dmz_eg4s20_hdmi_top.v`、`rle_decoder.v`。

> `img_scaler.v` 的差异经逐行比对**只是注释措辞不同**（rtl 侧是「dst_w 与 out_off_x 都强制
> 取 8 的倍数（不是偶数）」的新版，project 侧是旧的「dst_w 强制取偶数」），无逻辑差异；
> 且 `rtl/storage/img_scaler.v` 属 t7 域，本次未修改其逻辑。

### 4.4 编码纪律自检

- 全部新写/改动文件 **BOM = false**（首字节 `47 47 20` = `"// "`，非 `EF BB BF`）。
- 行尾：`rtl/storage/image_player.v`（LF=664/CRLF=664）与 `sim/testbench/tb_image_player.v`
  （LF=876/CRLF=876）是 **CRLF**——`git ls-files --eol` 显示这两个文件在仓库里**本来就是
  `i/crlf w/crlf`**，保持原样即一致；其余改动文件（`dmz_eg4s20_hdmi_top.v`、
  `rle_decoder.v`、`err_prompt.v`、`tb_rle_decoder.v`、`tb_err_prompt.v`）均为**纯 LF**。
- 未使用 PowerShell `Set-Content` 写文件。

---

## 5. 验证命令与原始输出

> 环境事实：本机**没有 `pwsh` 命令**（`pwsh : The term 'pwsh' is not recognized`），
> 全部 `.ps1` 用 `& .\xx.ps1` 调用。ModelSim ASE 10.1d 位于
> `D:\Quartus_APP\modelsim_ase\win32aloem`。

### 5.1 `python scripts\lint_verilog.py rtl`

```
检查文件数: 67
E0(文件损坏): 0    E1(赋值混用): 0    E2(多驱动): 0
结论: 通过（无损坏 / 无混用赋值 / 无多驱动）
```

### 5.2 `python scripts\check_port_names.py`

```
*** NO_SUCH_PORT = 0 (全部端口名都存在) ***
    UNKNOWN_MODULE = 2（其中预期 2：IP/加密件；**意外 0**）
    UNCONNECTED    = 0（其中预期未接 0；**意外未接 0**）
    EMPTY_CONN     = 9 个实例 / 18 个端口（其中有意空连接 9；**意外空连接 0**）

--- UNKNOWN_MODULE 明细 ---
  EG_PHY_SDRAM_2M_32                       u_sdram_sip    预期(IP/加密件)
  hdmi_1_4b_transmitter_core_wrapper       u_hdmi_core    预期(IP/加密件)

--- EMPTY_CONN 有意空连接（白名单，不参与判定）---
  key_matrix_4x4                           u_key          {key_state}
  key_router                               u_keyrouter    {audio_en,osd_item,osd_pop_req,ticker_en}
  player_ctrl                              u_ctrl         {mode,status_led}
  video_timing_gen                         u_vtg          {frame_start,hs}
  thermal_guard                            u_thermal      {oth_enter,oth_exit,temp_alive}
  image_player                             u_player       {ext_frame_sel,ext_loader_want_blk}
  audio_src_mux                            u_audio_src    {eff_audio_en}
  wav_stream_player                        u_wav          {err_code,fifo_level}
  brightness_apply                         u_bright       {de_out}

RESULT: PASS
```

### 5.3 `& .\sim\scripts\run_storage_regression.ps1 -Suite Pixels`

```
tb_pix_reader: passed; exit=0; checks=542; errors=0; cases=39; log=reports\s6_validation\tb_pix_reader.log
A4-GATE: ran=1 passed=1 expected=1
```
`reports\s6_validation\result.json`：`"status": "passed", "ran": 1, "passedCount": 1, "expectedCaseCount": 1`。
日志内：`# SUMMARY: checks=542 errors=0 cases=39 geometry=64x8` / `# ALL CHECKS PASSED: tb_pix_reader`。

> **与任务书的差异（如实说明）**：任务书写「checks=194 errors=0 cases=13」，实测是
> **checks=542 / errors=0 / cases=39**。原因：`run_storage_regression.ps1:83-86` 的 `Pixels`
> 套件只挂 `tb_pix_reader` **一个 case**（`$ExpCaseCount = (Suite -eq 'All') ? 4 : 1`），
> 542/39 是 tb **内部**的断言数与几何档数，不是 case 数。即：本轮 `errors=0` 与任务书一致，
> 但 checks/cases 的计数口径不同，请以本报告实测为准。

### 5.4 `tb_rle_decoder`（无现成 ps1，手工 vsim）

工作目录必须是 `sim/` 的**子目录**，才能让 `../testbench/vectors/*.hex` 相对路径成立：

```powershell
cd D:\FPGA_Compelate\SmartCampusMedia\sim\_rle_t9
& 'D:\Quartus_APP\modelsim_ase\win32aloem\vlib.exe' work
& 'D:\Quartus_APP\modelsim_ase\win32aloem\vlog.exe' -quiet ..\..\rtl\storage\rle_decoder.v ..\testbench\tb_rle_decoder.v
& 'D:\Quartus_APP\modelsim_ase\win32aloem\vsim.exe' -c -quiet -onfinish stop `
    -do "onerror {quit -f -code 2}; run -all; quit -f -code 0" work.tb_rle_decoder
```

输出（`sim\_rle_t9\run.txt` 尾部）：

```
# CASE: a withheld grant parks the request instead of claiming the bus
# GRANT: latency=1 low_max=601 waits=65 long_denials=63
# FRAME_DELAYED: groups=38400 beats=153600 word_errors=0
# CASE: a foreign blk_done must not advance the block index
# OWNERSHIP: idx=0 state=5 after foreign done+err
# CASE: our own blk_done still completes the block
# OWNERSHIP: own done -> idx=1 state=1
# ==============================================
# TB_RLE_DECODER SUMMARY: checks=72 errors=0
# RESULT: PASS
# ==============================================
```

- `checks=72`（原 58 + CASE 6 的 14 条）。原 58 条全部保持通过。
- `OWNERSHIP: idx=0 state=5 after foreign done+err` → 外来 done+err 之后 `blk_index` 仍是 0、
  `state` 仍停在 5（`R_NEXT_BLK`），**证明门控生效**。
- `OWNERSHIP: own done -> idx=1 state=1` → 自己那块完成则正常推进（`state=1`=`R_HDR_MAGIC`）。
- `FRAME_DELAYED … word_errors=0` → 门控没有破坏正常帧的逐字节正确性。

### 5.5 `& .\sim\scripts\run_image_regression.ps1`

```
img_scaler: passed=True; exit=0; checks=187
image_player: passed=True; exit=0; checks=11374
image_player_scaled: passed=True; exit=0; checks=1811
A4-GATE: ran=3 passed=3 expected=3
```
日志关键行：
- `image_player.txt`：`# CASE 15: ext_ever_framed is a level that needs a real flip and clears on exit`
  + `# SUMMARY: checks=11374 errors=0` + `# ALL CHECKS PASSED: image_player`
- `image_player_scaled.txt`：`# SUMMARY: SCALED 96x64 checks=1811 errors=0` + `# ALL CHECKS PASSED: image_player_scaled`

（CASE 15 在 `image_player` 与 `image_player_scaled` 两个 case 里都执行。）

### 5.6 `& .\sim\scripts\run_frontend_regression.ps1`

```
ran=21 passed=21 expected=21 status=passed
A4-GATE: ran=21 passed=21 expected=21
```
21 个 case 全 `passed=True`：`sd_protocol_default`、`sd_protocol_fast`、`sd_spi_ctrl`、`sd_probe`、
`fat32_reader`、`gallery_probe`、`bmp_parser`、`img_loader`、`player_ctrl`、**`err_prompt`**、
`buzzer_tone`、`key_action`、`video_overlay`、`video_content_mux`、`osd_caption`、`osd_param_text`、
`osd_panel`、`osd_autopop`、**`osd_caption_cjk`**、**`narr_subline`**、`fade_mixer`。

任务书点名的 4 个 tb 的通过标记（原始行）：

```
err_prompt.txt       : # === tb_err_prompt done, errors = 0 ===
                       # *** ALL CHECKS PASSED ***
narr_subline.txt     : #  ALL CHECKS PASSED: tb_narr_subline
osd_caption_cjk.txt  : #  ALL CHECKS PASSED: tb_osd_caption_cjk
```
（`tb_startup_ownership` 见 5.7。）

新增可观测性断言的原始输出（`err_prompt.txt`，C12 全部 8 条）：

```
# PASS: C12 rle_err=1 magic mismatch -> bE (hi=b lo=e)
# PASS: C12 rle_err=2 geometry -> dE (hi=d lo=e)
# PASS: C12 rle_err=3 run count -> d0 (hi=d lo=0)
# PASS: C12 rle_err=4 truncated/block -> d1 (hi=d lo=1)
# PASS: C12 rle_err=5 fat chain -> d5 (hi=d lo=5)
# PASS: C12 rle_err=6 SCI.RLE absent -> d6 (hi=d lo=6)
# PASS: C12 rle_err=default -> d9 (hi=d lo=9)
# PASS: C12 rle_bad=0 -> prompt cleared (hi=0 lo=0)
```

### 5.7 `& .\sim\scripts\run_startup_ownership_regression.ps1`

```
startup_ownership: passed
startup_ownership_legacy: passed
A4-GATE: ran=2 passed=2 expected=2
```

### 5.8 额外做的顶层全量编译冒烟（证明综合层可编译）

`sim/_top_t9` 下：

```powershell
vlib work
vlog -quiet -work work +incdir+..\..\rtl\video +incdir+..\..\rtl\common +define+SDRAM_SIM_MODEL `
  <rtl 下全部 .v（排除 rtl/video/color_bar_ref.v）> `
  ..\..\project\hdmi\enc\hdmi_1_4b_transmitter_core_wrapper.enc.v
```
结果：**`vlog exit=0`（零错误零警告阻断）**。

> 排除 `rtl/video/color_bar_ref.v` 是正确做法：它是历史参考件，内含
> `#include "video_define.v"` 而该文件不存在，从未参与综合与任何回归。

---

## 6. 上板验证判据（由用户执行）

前提：SD 卡根目录必须放 `assets/v2/sdcard/BURN640/` 的**全部 17 个文件**
（含 `SCI.RLE` 82 MB 与 `NARR.WAV` 12 MB）。**不要放 `RES640/`**——那个目录没有 `SCI.RLE`。

### 6.1 第一步：确认素材装配正确（这一步错了后面全白搭）

上电进入**日常模式**，等图库扫描完成（数码管 `state` 位显示播放状态、8 个 LED 正常）。
若数码管出现 **`d6`**（`hi=d lo=6`）→ **卡上没有 `SCI.RLE`**，请重新拷 `BURN640/` 目录。

### 6.2 第二步：切入科普模式，确认视频在放

按模式键切到科普（数码管 `state`=4=PLAY，LED 上 `mode==2` 位亮）：

| 观察点 | 期望 | 若不符 → 对应断点 |
|---|---|---|
| 屏幕主体 | **出现 RLE 视频画面，约 5 fps 逐帧推进**（不是静止图） | 无画面：看数码管 |
| 数码管 | 保持 `4`（PLAY），**不出现错误码** | 出现 `bE`=魔数不符 / `dE`=几何不符 / `d0`=run 表坏 / `d1`=读卡失败 / `d5`=簇链不连续 / `d6`=卡上无文件 |
| LED `image_ready` 位 | 常亮 | — |
| 帧率均匀性 | 允许**偶发卡顿**（P2 的 `gap_tick` 撞车，约 6% 帧滑后 200 ms）。若**每帧都严重卡顿**才需要进一步查 | 8.1 |

**关键判据：画面必须是"变的"**。若画面内容始终不变，说明只出了第一帧后卡在 `R_ERR`
或视频通路没跑起来——此时数码管一定会给出错误码（这正是本次 P1-a 的价值）。

### 6.3 第三步：确认中文字幕在推进

同一屏上方（字幕区）：

| 观察点 | 期望 |
|---|---|
| 第一帧上屏前 | **不应有字幕**（若字幕比画面先出现 = 粘滞位清零逻辑坏了） |
| 第 4 帧起 | 中文字幕出现，且**随时间逐帧推进**（`narr_subline` 共 533 项正文，631 帧分摊） |
| 字幕与画面的时序 | 字幕应跟着视频帧走，不是"卡在第一句" |
| 停在最后一帧后 | 字幕短暂消失再回绕（`frame_idx > 624` 判据） |

> 判据"字幕在推进"：连续观察 30 秒以上，字幕内容应明显换过多句。
> 若字幕**完全不出**：查 `rle_ever_framed`（视频是否真的翻过帧）。
> 若字幕**一直不动**：查 `rle_frame_idx` 是否在递增（即视频是否在放）。

### 6.4 第四步：确认 NARR 音频在响

- 科普模式下应听到**旁白（NARR.WAV）**，不是 BGM。
- 旁白与字幕应大致同步（两者都按 `frame_idx` 推进）。
- 若**只有画面没有声音**：属 t6/audio 域（`audio_src_mux.v:70` 的 `MODE_SCIENCE → SRC_NARR`）。

### 6.5 第五步：确认失败可观测（回归验证 P1-a）

故意把卡上的 `SCI.RLE` 改名或删掉，重新上电进科普：

| 期望 |
|---|
| 屏幕退化为静态科普页 + 滚动字幕（**这是设计允许的**，`gallery_probe` 不报 fail） |
| 数码管显示 **`d6`**（`hi=d lo=6`），且**只在科普模式出现**；切回日常/应急必须恢复正常显示 |
| 蜂鸣器按 `err_prompt` 时序告警（1.5 s 静默后响 3 s） |

### 6.6 第六步：确认不回归其它模式

- 日常模式：图片正常（像素偏移/画质问题属 t7，不在本次范围）。
- 应急模式：正常出图 + 有声。
- 从科普切回日常再切回科普：
  - 第二次进科普，**画面第一帧上屏之前不得先出字幕**（验证 `!ext_wr_mode` 清零）。

---

## 7. 必须上板才能确认的项（仿真无法覆盖）

### 7.1 【最重要】SD 卡上到底有没有 `SCI.RLE`

- 仓库里 `assets/v2/sdcard/RES640/` = **6 张 BMP + MANIFEST.TXT，没有 `SCI.RLE`、没有 `NARR.WAV`**；
  `assets/v2/sdcard/BURN640/` = 17 个文件（含 `SCI.RLE` 82362927 B、`NARR.WAV` 12106244 B）。
- 诊断报告判断：现场最可能就是把 `RES640/` 拷进了卡。**代码修不了这一点**——
  `gallery_probe` 的「没找到 `SCI.RLE` 不算故障」是正确设计（允许退化成静态页），
  本次只在科普模式下把它显示成 `d6`。
- **验收判据**：上板看到画面 = 素材装配正确；看到 `d6` = 素材没拷对。

### 7.2 WAV 与 RLE 的真实并发抢总线

`tb_rle_decoder` 虽然模拟了第二个消费者（`wav_want`）抢授权，并且现在也能注入"外来
`blk_done`"，但**真实 `sd_spi_ctrl` 的时序、真实卡的块延迟分布、`fat32_reader` 的真实簇链
访问模式**都只能在板上验证。仿真能保证的是"归属判据正确"，不能保证"真实环境下
`req_sent` 的置位/清零窗口与卡的 done 脉冲严丝合缝"。

**验收判据**：科普模式连续播放 > 2 分钟（≥ 600 帧，正好覆盖一整轮 631 帧），
画面不冻结、数码管不出现 `d1`。

### 7.3 `ext_ever_framed` 在真实 vblank 时序下的表现

仿真里 `vblank_rise` 由 `scan_y` 驱动，与真实 `video_timing_gen` 的消隐期时序可能差 1~2 拍。
若粘滞位置位窗口与 `front_sel` 提交窗口错开，会出现"字幕比画面早一帧/晚一帧"。
**这只影响字幕与画面的相对时序（1 帧 = 200 ms），不影响"有没有字幕"。**

**验收判据**：6.3 里"第一帧上屏前不得有字幕"这一条。

### 7.4 数码管 `bE`/`dE` 的可读性

`d6`/`d0`/`d1`/`d5` 都是既有字符，一定可读。但 `bE`（魔数错）与 `dE`（几何错）是我新组合的
两位助记，**需要人眼确认在 4 位数码管上不会被误读成 `b8`/`d8`**（`seg_decoder` 里
`E=0x79`、`8` 未实现，理论上不会混，但仍需上板看一眼）。

### 7.5 帧率是否真的 ≈5 fps

仿真用 `CLK_FREQ=2500`（缩小 10000 倍）来让 `gap_tick` 可仿，所以**帧率在仿真里没有意义**。
真实帧率由 `play_fps=5` + `gap_tick` 分频 + 总线占用共同决定（第 3 节算术给出理论值）。
**验收判据**：用秒表掐 631 帧一轮 ≈ **126 s**（允许 ±10%）。

---

## 8. 遗留风险与移交

### 8.1 P2：`gap_tick` 单拍撞车（**本次未修，按 captain m00122 授权**）

- 位置：`rtl/storage/rle_decoder.v:497` `R_IDLE: if (gap_tick && !blk_busy && !eof_stop)`
- 机制：`gap_tick` 是单周期脉冲，`!blk_busy` 是全局条件（不区分 busy 属主）。
  撞上 WAV 块事务（约占 6.4% 时间）时这一拍被丢弃，整帧滑后 200 ms。
- 影响：5 fps → 约 4.7 fps 的**抖动**，不是失效。
- 为何不修：`R_IDLE` 是所有帧的起点，改错会引入"卡在某帧"的新风险，高于当前收益。
- 建议方案：把 `gap_tick` 改成"见 tick 即锁存 pending，等 `!blk_busy` 再起帧"。

### 8.2 P3：`R_ERR` 不自愈（**本次未修**）

`rle_decoder.v:716-720` 的 `R_ERR` 只清请求，永远回不到 `R_IDLE`；只有 `!play_en`
（退出科普）才复位。这是原设计（"出一次错就停，避免刷屏"），但配合 8.1 之外的任何
偶发错误都要求用户手动切模式才能恢复。

本次不改，但**现在至少可见**（数码管会显示错误码，不再是静默）。

### 8.3 移交给 t7（video-engineer）：科普视频沿用日常 BMP 的缩放窗口

`image_player` 的 ext 写口在视频模式下**不更新** `scale_w/h/off_x/off_y`（`ext_wr_*` 只写像素，
不写几何），所以 RLE 视频上屏时沿用日常图片那一套缩放/偏移。若日常模式的缩放档位不是
"整屏铺满"，科普视频也会被同样缩放/偏移 —— 这与问题②⑤（图片偏移、黑边）是同源。
**本次按 captain 指令未动 ext 写口的 scale 逻辑**，移交 t7 一并处理。

### 8.4 `SCI.RLE` 必须物理连续

解码器按 `blk_addr = file_lba + blk_index` **顺序**读整条流（不解析簇链），
所以卡上该文件必须物理连续。格式化后一次性拷入通常满足；碎片化会读到别的数据 →
`bE`（魔数错）或 `dE`（几何错）。**这不是代码能修的**，需要用户按"格式化 → 一次拷全"操作。

---

## 9. 交付物清单

| 文件 | 类型 |
|---|---|
| `rtl/storage/rle_decoder.v` | 修改（+20） |
| `rtl/storage/image_player.v` | 修改（+36） |
| `rtl/control/err_prompt.v` | 修改（+69） |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | 修改（+177） |
| `sim/testbench/tb_rle_decoder.v` | 修改（+117） |
| `sim/testbench/tb_err_prompt.v` | 修改（+50） |
| `sim/testbench/tb_image_player.v` | 修改（+140） |
| `project/hdmi/{rle_decoder,image_player,err_prompt,dmz_eg4s20_hdmi_top,img_scaler}.v` | sync_src 同步产物 |
| `reports/fix_science_20261103.md` | 本报告 |

**未做**（按任务边界）：不重跑 TD 综合布线（留给 verify-build）、不上板、
未改 `rtl/audio/`、`rtl/osd/`、`rtl/video/pix_mosaic.v`、`rtl/storage/img_scaler.v` 的逻辑、
未改 `gallery_probe` 的「没找到不算故障」语义、未引入 `SCI.IDX`、未动 `rle_decoder` 的解码算法。
