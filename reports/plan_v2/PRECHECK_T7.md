# PRECHECK_T7 — t7 四个新模块的验收清单与已知陷阱

> **本文性质**：t7 尚未落盘，本文是**交付前自检清单 + 已知陷阱表**，不是事后评分。
> 落盘后 captain 会派我按同一份清单**实核一遍**（那时是「预检」变「实核」）。
> **用途**：①给 rtl-engineer 交付前逐条自检；②给 t9 回归挑重点。
> 因此每条判据都必须回答「**怎么验**」——跑哪个 tb / 看哪根波形 / 抓哪一帧，不能只写「应该等于 X」。

**基线口径**（全文行号以撰写时刻实测为准）：

- `docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md` = **910 行 / 68,367 B / 2026-11-01 23:46:24**
- `docs/plan_v2/ARCH.md` = **1,177 行 / 81,889 B**（architect 23:44 改过一轮，行号已漂移，本文所有引用均当场重取）
- `SmartCampusMedia/rtl/top/dmz_eg4s20_hdmi_top.v` = **617 行 / 40,676 B**
- 资源基线 = `reports/diag_key1_fifo_backpressure_20261101/area.txt`（243 行 / 24,544 B / 2026-11-01 18:47:51，captain m01957 裁定为唯一对外报账基线）

**判定等级**：🔴 阻断（不通过不许交付） / 🟡 建议（记录即可，不挡交付） / ⏳ 未落盘

---

## §0 汇总表

| 组 | 编号 | 判据 | 等级 | 定稿出处 |
|---|---|---|---|---|
| 1 `pix_mosaic` | P-01 | `src_w=640` 逐拍恒等 `rgb565_out === rgb565_in` | 🔴 | addendum `:469`（**结论错误，见 §1.0**）、`:461` |
| | P-02 | `src_w<640` 单行 640 拍内不同源列数 == `src_w`（320/400/512/576 各一次） | 🔴 | addendum `:470` |
| | P-03 | 行首 `active_x==0` 必须取新像素 | 🔴 | addendum `:464`（意图正确） |
| | P-04 | 应急态顶层强制 `src_w=640` | 🔴 | addendum `:471` |
| 2 `pix_reader` | R-01 | `src_h=480` 时 `src_y === active_y` 恒等 | 🔴 | addendum `:502` |
| | R-02 | `src_h<480` 时同源行读多次、读带宽不变 | 🔴 | addendum `:503` |
| | R-03 | `PIX_PER_LINE`/`FRAME_LINES` 缺省值保留 | 🟡 | addendum `:501` |
| | R-04 | `image_player.v:492` 内部例化漏接 `src_w`/`src_h` → x 传播 | 🔴 | addendum `:663` R-07 |
| 3 `rle_decoder` | L-01 | 条目 3 字节 `{rgb565[15:0], run_len[7:0]}`，高字节先 | 🔴 | ARCH `:562` |
| | L-02 | **`run_len=0` 表 256** | 🔴 | ARCH `:562` / `:636`；addendum `:658` R-02 |
| | L-03 | 帧头 `SCMR` magic + w/h/run_count，每帧独立 12 B 头 | 🔴 | ARCH `:630-638` |
| | L-04 | 欠载保持上一帧，**绝不插黑** | 🔴 | ARCH `:565`；addendum `:661` R-05 |
| | L-05 | 连续 3 帧欠载降 2fps、不降分辨率 | 🟡 | **ARCH `:567`**（定稿有，captain m01992 记错） |
| | L-06 | `ext_wr_addr[1:0]` 恒 `2'b00` | 🔴 | addendum `:140` |
| | L-07 | 整帧原子性：`ext_wr_done` 只在 153,600 words 全写完时单拍 | 🔴 | ARCH `:564`；addendum `:564`/`:875` |
| 4 `ratio_map` | M-01 | 五档窗口值正确 | 🔴 | ARCH `:383-387` |
| | M-02 | 应急态强制 640×480/off 0,0 | 🔴 | addendum `:380`；ARCH `:387` |
| | M-03 | `ratio_sel` 复位 4 = 满屏 | 🔴 | `key_router.v:157-158` |
| 5 `emerg_page` | E-01 | 纯组合（零寄存器、零 BRAM、零时钟） | 🔴 | addendum `:518` |
| | E-02 | **禁止斜线** | 🔴 | addendum `:520` |
| | E-03 | 文字走 `osd_caption`，不内嵌字形 ROM | 🔴 | addendum `:521` |
| | E-04 | 从 `content_mux` 的 `2'd2` 注入，不经 `pix_mosaic`/`image_window_mask` | 🔴 | addendum `:378` |
| | E-05 | 应急态按键仍被消费（不吞键） | 🔴 | addendum `:380` |
| 6 **t8 集成差异** | I-01 | 4 个既有 TB 必须同步改例化 | 🔴 | addendum `:657` R-01（**数目有误，见 §6.1**） |
| | I-02 | `video_content_mux.mode` 改接 `disp_mode` 而非 `mode` | 🔴 | 本文 §6.2（addendum 未列） |
| | I-03 | `bright_lvl[3:0]` 分两路，`video_overlay` 不得接回衰减 | 🔴 | `video_overlay.v:132-135`（t5 已拆） |
| | I-04 | 删 `u_kact`/`u_ctrl`，键号冲突 | 🔴 | `dmz_eg4s20_hdmi_top.v:101`/`:116` |

**统计：🔴 阻断 25 条 / 🟡 建议 2 条（R-03、L-05） / ⏳ 未落盘 5 个模块文件本身。**

逐组 🔴 计数：组1 `pix_mosaic` 4 条（P-01~P-04）/ 组2 `pix_reader` 3 条（R-01、R-02、R-04）/ 组3 `rle_decoder` 6 条（L-01~L-04、L-06、L-07）/ 组4 `ratio_map` 3 条（M-01~M-03）/ 组5 `emerg_page` 5 条（E-01~E-05）/ 组6 t8 集成 4 条（I-01~I-04）。

---

## §1 `pix_mosaic.v`（新，约 40 LUT）

### §1.0 ★ 先读这条：定稿伪码是错的，不得照抄

`ARCH_ADDENDUM_VIDEO_PATH.md:462-469` 的伪码：

```
行首（active_x == 0）：x_acc <= 0;  hold <= rgb565_in;
行内每拍：  x_acc <= x_acc + src_w;
           if (x_acc >= 640) begin x_acc <= x_acc - 640; hold <= rgb565_in; end
           rgb565_out <= hold;
```

`:469` 宣称「当 `src_w == 640` 时每拍都 `x_acc >= 640`，`hold` 每拍更新 → 恒等旁路，零画质损失」。

**这是错的。** 按非阻塞赋值语义逐拍推演（比较用旧 `x_acc`、输出用旧 `hold`）：

| `src_w` | 伪码输出前 8 拍 | 期望 | 首失配 |
|---|---|---|---|
| 640 | `[0,0,1,2,3,4,5,6]` | `[0,1,2,3,4,5,6,7]` | n=1 |
| 320 | `[0,0,1,2,3,4,5,6]` | 见 P-02 | n=1 |
| 400/512/576 | 同上落后一拍 | — | n=1 |

**根因**：`rgb565_out <= hold` 写在 `if` 之后，非阻塞下取的是**更新前**的 `hold` → 整体落后一拍；`src_w=640` 第 0 拍 `x_acc(旧)=0 < 640` 不更新 `hold`，输出初值 0 而非 `in[0]`。

**后果**：P-01/P-02 必红；且 `src_w=640`（Key8 空档）时**画面整体左移一像素**——不报错、不崩溃，只是画质悄悄变差，属典型静默失败。

**正确实现（已验证）**：

```verilog
wire        take = (active_x == 11'd0) || (x_acc + src_w >= 16'd640);
assign valid_out  = valid_in;
assign rgb565_out = valid_in ? (take ? rgb565_in : hold) : 16'd0;
always @(posedge pixel_clk or negedge rst_n) begin
    if (!rst_n) begin x_acc <= 16'd0; hold <= 16'd0; end
    else if (de && valid_in) begin
        if (active_x == 11'd0) begin x_acc <= src_w - 16'd640 + src_w; hold <= rgb565_in; end
        else if (take)         begin x_acc <= x_acc + src_w - 16'd640; hold <= rgb565_in; end
        else                   begin x_acc <= x_acc + src_w; end
    end
end
```

关键：**输出走组合旁路 `take ? rgb565_in : hold`，不能用寄存的 `hold`**。

> **不要纠缠「理想最近邻」的定义**（`floor(n·w/640)` 那套推导混用了「像素重复放大」与「隔点抽取」两套语义）。判据只认 P-01/P-02 两条可执行红线。

### §1.1 P-01 🔴 `src_w=640` 逐拍恒等

- **现象**：`src_w=640` 时 `rgb565_out` 与 `rgb565_in` 必须**同一拍**逐位相等。
- **怎么验**：新建 `sim/testbench/tb_pix_mosaic.v`。喂随机 `rgb565_in`，`valid_in` 恒 1，`de` 恒 1，`src_w=16'd640`，跑满 2 行（1,280 拍）。每拍断言 `#1 rgb565_out === rgb565_in`。
- **失败长什么样**：整体落后一拍（`out[n] == in[n-1]`），屏上表现为**画面左移 1 像素**；`src_w=640` 是 Key8 的第 5 档（默认档），**默认状态就是错的**，最容易被当成「图片本来就这样」。

### §1.2 P-02 🔴 `src_w<640` 源列数守恒

- **现象**：单行 640 拍内，`take` 有效的次数（即不同源列数）必须**恰好等于 `src_w`**。
- **怎么验**：同一个 tb 加 4 个 case：`src_w` = 320 / 400 / 512 / 576，各跑 1 行（640 拍），统计 `take` 上升次数。断言 `count == src_w`。
- **失败长什么样**：`count != src_w` → 要么丢列（画面右侧出现重复旧列），要么多列（画面右侧内容被截掉）。屏上表现为**马赛克块宽度不均匀**，肉眼很难判断，必须靠断言。

### §1.3 P-03 🔴 行首强制取新像素

- **现象**：`active_x == 0` 那一拍必须输出 `rgb565_in`（不是 `hold`）。
- **怎么验**：P-01/P-02 的 tb 里额外断言 `active_x==0` 时 `rgb565_out === rgb565_in`。
- **失败长什么样**：每行第 0 列显示上一行最后一列的残留 → 屏上是一条**垂直的错位竖线**（左边缘），逐行相同。

### §1.4 P-04 🔴 应急态强制 `src_w=640`

- **现象**：`disp_mode == 2'd2` 时顶层把 `src_w` 强制为 640 → 恒等旁路。
- **怎么验**：顶层集成后（t8）跑一次三模式切换，抓 `disp_mode`、`src_w` 两根波形，确认 `disp_mode==2` 期间 `src_w==640` 恒成立。
- **失败长什么样**：应急平面图被马赛克化 → **疏散路线变成虚线**，这是最严重的一类（信息不可读）。

---

## §2 `pix_reader.v` 行映射（改动 +30 LUT，新增 2 端口）

### §2.1 R-01 🔴 `src_h=480` 恒等

- **现象**：`src_h == 480` 时 `src_y_mapped === active_y`（每行推进一次，与现状完全一致）。
- **怎么验**：扩展 `sim/testbench/tb_pix_reader.v`（现 103 行例化处），加 `src_w=16'd640, src_h=16'd480`，跑 1 帧，逐行断言 `row_addr` 步进 == `PIX_PER_LINE`。
- **失败长什么样**：行序错乱 → 画面上下颠倒或撕裂；或每行被读两次 → 帧率减半但画面看似正常。

### §2.2 R-02 🔴 同源行读多次、带宽不变

- **现象**：`src_h<480`（240/300/384/432）时同一源行被读多次，但**总读次数仍为 480 次/帧**（不是 `src_h` 次）。
- **怎么验**：`src_h=240` 跑 1 帧，统计 `rd_req` 次数 == 480×（每行读组数）；并断言连续两行的 `row_addr` 相同（重复读）。
- **失败长什么样**：若误做成「只读 `src_h` 行」，画面下半部会重复上半部或黑掉；若读带宽变了，`pix_reader` 的 `LEVEL_HI`/`FIFO_AW` 水位会失衡 → 间歇性黑屏。

### §2.3 R-03 🟡 `PIX_PER_LINE`/`FRAME_LINES` 缺省值保留

- **现象**：`parameter PIX_PER_LINE = 640`、`FRAME_LINES = 480` 缺省值不得改动（`image_player.v:492` 靠它们传参）。
- **怎么验**：`git diff` 看 `pix_reader.v` 端口区，确认只加 `src_w`/`src_h` 两个 input，未动 parameter。
- **失败长什么样**：若把 `PIX_PER_LINE` 改成 `src_w`，`framebuf_arbiter` 的 4 字对齐组会跨行 → 整帧错位（同 `tb_img_scaler.v:410-414` 记载的 T08 现象）。

### §2.4 R-04 🔴 `image_player.v:492` 内部例化漏接

- **现象**：`image_player.v:492` 的 `pix_reader #(...) u_reader (` 必须显式接 `.src_w(16'd640)` / `.src_h(16'd480)`（日常默认档）。
- **怎么验**：`grep -n "src_w\|src_h" rtl/storage/image_player.v` 确认 492 行起的例化块内两端口都在。
- **失败长什么样**：**仿真 x 传播、上板画面错行**（addendum `:663` R-07 原文）。这条是「不接也能编译」的——Verilog 允许端口缺省悬空，**综合工具不一定报错**，只在仿真/上板时炸。

---

## §3 `rle_decoder.v`

### §3.1 L-01 🔴 条目格式

- **现象**：每条 3 字节 `{rgb565[15:0], run_len[7:0]}`，**先收 2 字节 RGB565（高字节先），再收 1 字节 run_len**。
- **怎么验**：`tb_rle_decoder.v` 喂手工构造的 2 条 payload，断言解出的 `(rgb565, run_len)` 与手算一致。
- **失败长什么样**：字节序反了 → 颜色错乱（红蓝互换），但**像素数正确**，容易被误判为「BMP 解析问题」。

### §3.2 L-02 🔴 `run_len = 0` 表 256（最容易写错的一条）

- **现象**：`run_len == 0` 展开为 **256 个像素**，不是「无效条目」也不是 0。
- **定稿出处**：`ARCH.md:562`「**run_len = 0 表示 256**（避免单独转义字节）」；格式表 `ARCH.md:636` 同；二进制证据见 addendum `:658` R-02（前 6 帧共 2,371 次 `run_len==0`，按 0→256 映射后每帧 `sum==307200` 全部吻合）。
- **怎么验**：`tb_rle_decoder.v` 构造一帧只含 `run_len=0` 条目的 payload，断言输出像素数 == 256×条目数；并断言整帧 `sum(run) == 307200`。
- **失败长什么样**：按 0 处理 → 该 run 消失，**整帧缺像素**（画面右下角变黑或最后几行缺失）；按「非法条目」处理 → 触发 `err_code=3`，视频整段不播。`err_code=3` 的判据是 `run_len` **超范围**才算非法，不是 `run_len==0`。

### §3.3 L-03 🔴 帧头格式

- **现象**：每帧自带 12 B 头：`0..3` magic `"SCMR"`（0x53 0x43 0x4D 0x52）、`4..5` width 640 小端、`6..7` height 480 小端、`8..11` run_count 小端。
- **定稿出处**：`ARCH.md:630-638`（格式表）+ `:638`「多帧文件：上述结构**逐帧重复**，第 N 帧偏移由前 N-1 帧 `run_count` 累加得到（`rle_decoder` 维护 `frame_offset` 累加器）」。
- **怎么验**：拿真实 `SCI.RLE` 的前 12 字节做断言（`53 43 4D 52` + `80 02` + `E0 01` + run_count）；再断言第 2 帧偏移 == 12 + 3×run_count[0]。
- **失败长什么样**：magic 错 → `err_code=1`（能报错，属好的失败）；**偏移算错 → 从第 2 帧起全花屏**，第 1 帧却完全正常，极易误判为「SD 卡读坏」。

### §3.4 L-04 🔴 欠载保持上一帧，绝不插黑

- **现象**：`underrun=1` 时**保持上一帧**（不插黑、不清屏），`pix_reader` 继续读旧帧内容。
- **定稿出处**：`ARCH.md:565`「`underrun = 1` 时**保持上一帧**（不插黑、不清屏）」；addendum `:661` R-05 是另一件事（`fade_mixer` 淡黑）。
- **怎么验**：tb 里人为让 `data_valid` 停 2 帧，断言 `ext_wr_done` 不产生、`front_sel` 不翻转、`pix_reader` 输出仍是旧帧内容。
- **失败长什么样**：插黑 → 屏上**每帧闪一次黑**，5fps 下是 5Hz 频闪，观感极差但不像 bug（像「视频本来就是黑的」）。

### §3.5 L-05 🟡 连续 3 帧欠载降 2fps

> **★ 更正 captain m01992**：captain 说「这个『3』的唯一出处是 addendum §13 R-02，属风险缓解措施而不是功能契约；`ARCH.md` 与 `PLAN.md` 里只有『5fps 目标 / 2fps 保底』两档口径，没有『3 帧』这个阈值」——**这个判断不成立**。
>
> **实测 `ARCH.md:567` 原文**：「**降级策略**：若连续 3 帧 `underrun`，`play_fps` 从 5 自动降到 2（由上层 `mode_ctrl` 或专用自适应逻辑控制，**不降分辨率**）。」
>
> 该条位于 `ARCH.md` **§6.5 `rle_decoder.v` 端口契约**（节标题 `:515`）的「接口时序约定」列表内，与 L-01/L-02/L-04 同级——**它是功能契约，不是风险缓解**。addendum §13 里根本没有 R-02 以外的降级表述（R-02 讲的是 `run_len==0`）。captain 记错了两件事：①出处（不在 addendum §13）②性质（是契约不是缓解）。

- **现象**：连续 3 帧 `underrun` 后 `play_fps` 5→2，分辨率不变。
- **怎么验**：tb 里连造 3 帧欠载，断言第 3 帧后 `play_fps == 8'd2`，且 `FRAME_W/FRAME_H` 未变。
- **等级说明**：**判 🟡 建议而非 🔴 阻断**——理由采纳 captain 的判断逻辑（自适应降级策略不是用户需求也不是赛规要求，`rle_decoder` 即使没有降帧机制，只要 L-04 做对，最坏情况是掉到 SD 带宽允许的实际帧率，功能仍可用）。**不要让它挡住 t7。**
- **失败长什么样**：不降 → SD 带宽紧张时持续欠载、帧率抖动（观感不稳但可用）；降了但降分辨率 → 违反定稿明文「不降分辨率」。

### §3.6 L-06 🔴 `ext_wr_addr[1:0]` 恒 `2'b00`

- **现象**：`ext_wr_addr[1:0]` 永远为 `2'b00`（`framebuf_arbiter` 在 `WR_ADDR_FROM_FIFO=1` 下要求 4 字对齐组首）。
- **定稿出处**：addendum `:140`「**必须遵守**：`ext_wr_addr[1:0]` 恒为 `2'b00`…4 字对齐组首…外部直接给地址时由 `rle_decoder` 自己保证（它按 4 字一组累加，天然对齐）」。
- **怎么验**：tb 里对每次 `ext_wr_valid` 断言 `ext_wr_addr[1:0] === 2'b00`。
- **失败长什么样**：**画面错位半行 / 偶发横向撕裂，不报错**（addendum `:647` 对 V-05 的原话：「容易误判为显示器问题」）。

### §3.7 L-07 🔴 整帧原子性

- **现象**：`ext_wr_done` 只在**整帧 153,600 words 全部写完**时单拍置高；`play_en` 拉低或模式切走时 `frame_word_cnt` **强制清 0** 且**不得**发出 `ext_wr_done`。
- **定稿出处**：`ARCH.md:564`、addendum `:564` 与 `:875`（§18.5「唯一契约：整帧原子性」）。
- **怎么验**：tb 里让一帧写到 100,000 words 时拉低 `play_en`，断言 `ext_wr_done` 未产生且 `frame_word_cnt` 归 0；恢复后重写必须**从头**写满 153,600。
- **失败长什么样**：允许续写 → 后台帧被两帧内容混合，屏上表现为**上下两半来自不同帧**的「拼接图」，只在切模式瞬间出现一帧，极难复现。

---

## §4 `ratio_map.v`

### §4.1 M-01 🔴 五档窗口值

| `ratio_sel` | 占比 | `win_w` | `win_h` | `win_off_x` | `win_off_y` | 面积占比 |
|---|---|---|---|---|---|---|
| `3'd0` | 1/2 | 320 | 240 | 160 | 120 | 25.0% |
| `3'd1` | 5/8 | 400 | 300 | 120 | 90 | 39.1% |
| `3'd2` | 3/4 | 480 | 360 | 80 | 60 | 56.3% |
| `3'd3` | 7/8 | 560 | 420 | 40 | 30 | 76.6% |
| `3'd4` | 1 | 640 | 480 | 0 | 0 | 100% |

- **定稿出处**：`ARCH.md:383-387`（表体）+ `KEYMAP.md:358-368`（§9.4 同值）。全部为整数，可直接作为 `image_window_mask.v` 的输入（`KEYMAP.md:368`）。
- **怎么验**：纯组合模块，直接写 tb 遍历 5 个 `ratio_sel`，断言 5 组输出等于上表。
- **失败长什么样**：偏移算成 `(640-win_w)/2` 但用了有符号/位宽截断 → 窗口偏左或偏上，黑边左右不对称（肉眼可辨，属好的失败）。

### §4.2 M-02 🔴 应急态强制满屏

- **现象**：`disp_mode == 2'd2` 时 `ratio_map` 输出 `640/480/0/0`，忽略 `ratio_sel`。
- **定稿出处**：addendum `:380`「应急态按键仍消费、寄存器仍记录、输出端钳位，退出恢复，与 `KEYMAP.md §5.1` 音量下限钳位完全同构」；`ARCH.md:387` 满屏行。
- **怎么验**：tb 里 `ratio_sel=3'd0` 且 `disp_mode=2'd2`，断言输出 `640/480/0/0`；再断言 `ratio_sel` 寄存器**仍为 0**（不吞键、不改值）。
- **失败长什么样**：应急画面被裁成 1/2 窗口 → 疏散图只占屏幕 1/4，**信息不全**（最严重）；或直接改写了 `ratio_sel` → 退出应急后屏占比没恢复。

### §4.3 M-03 🔴 `ratio_sel` 复位 4 = 满屏

- **现象**：复位值 `SEL5_MAX = 3'd4`（满屏）。
- **定稿出处**：`key_router.v:157-158` `ratio_sel <= SEL5_MAX;`（现状已对，`ratio_map` 不得改这个语义）。
- **怎么验**：t8 集成后上电抓 `ratio_sel`，应为 4。
- **失败长什么样**：上电就是 1/2 窗口 → 用户以为「屏幕坏了」。

---

## §5 `emerg_page.v`

### §5.1 E-01 🔴 纯组合（零寄存器、零 BRAM、零时钟）

- **现象**：模块端口只有 `de/active_x/active_y/blink → rgb_out`，**无 `clk`、无 `rst_n`**；内部零 `always @(posedge ...)`、零 BRAM 推断。
- **定稿出处**：addendum `:518`「纯组合：`rgb_out` 与 `de/active_x/active_y/blink` 同拍，不引入延迟（与 `science_page.v` 的手法一致，`rtl/video/science_page.v` 就是 4 端口纯组合）」。
- **怎么验**：`grep -c "posedge\|negedge\|clk\|rst_n" rtl/video/emerg_page.v` 应为 0；综合后 area.txt 该实例 `bram` 列 == 0。
- **失败长什么样**：插了寄存器 → 画面整体右/下移 1 像素；插了 BRAM → 有 1 拍读延迟，与 OSD 不同拍 → **字幕与背景错位一行**。

### §5.2 E-02 🔴 禁止斜线

- **现象**：所有线条只能是水平或垂直；**路线必须是直角折线（先横后竖）**。
- **定稿出处**：addendum `:519-520`「最近路线**直角折线（先横后竖）**」「**绝不用斜线**（斜率会引入乘法器，DSP 只剩 10/29）」。
- **怎么验**：审查 RTL 是否出现任何形如 `a*x + b*y` 的比较；综合后 DSP 增量为 0。
- **失败长什么样**：DSP 超限 → 综合失败（属好的失败）；若勉强塞进 LUT，则 LUT 暴涨挤掉其他模块。

### §5.3 E-03 🔴 文字走 `osd_caption`，不内嵌字形 ROM

- **现象**：本模块内**不得**有字形 ROM / `case` 字模表；大字提示由 `osd_caption.v` 的 `LINE_TICKER=4'd15` 承载。
- **定稿出处**：addendum `:521`「**文字不做进本模块** —— 大字提示走已有 `osd_caption.v` 的 `LINE_TICKER=4'd15`（应急态由 `mode_ctrl` 锁定字幕内容，Key5 无效）」。
- **怎么验**：`grep -c "font\|glyph\|bitmap" rtl/video/emerg_page.v` 应为 0。
- **失败长什么样**：内嵌字形 → 多 284 lut（`science_font16` 实测）+ 与 t14 的 `cjk16` 字库方案重复投入；且 `emerg_page` 资源从 +400 涨到 +700，LUT 余量告急。

### §5.4 E-04 🔴 从 `content_mux` 的 `2'd2` 注入

- **现象**：`emerg_page` 的像素经 `video_content_mux` 的 `mode==2'd2` 分支进入，**不经过** `pix_mosaic` 与 `image_window_mask`。
- **定稿出处**：addendum `:378`「裁定：`emerg_page` 从 `content_mux` 的 `2'd2` 位置注入（§6.2），因此它**不受** `image_window_mask` 与 `pix_mosaic` 影响」。
- **怎么验**：t8 集成后抓波形，`disp_mode==2` 时 `image_window_mask.pixel_valid_out` 不得影响 `content_mux` 的 `2'd2` 输出。
- **失败长什么样**：若串在 mask 之后，应急画面被屏占比裁掉；若串在 mosaic 之后，疏散图被马赛克化。

### §5.5 E-05 🔴 应急态按键仍被消费（不吞键）

- **现象**：应急态下 Key6/Key7/Key8/Key9 的 `key_event` 仍被 `key_router` 消费、寄存器仍更新，只在**输出端钳位**；退出应急后恢复用户设定值。
- **定稿出处**：addendum `:380`「应急态按键仍消费、寄存器仍记录、输出端钳位，退出恢复，与 `KEYMAP.md §5.1` 音量下限钳位完全同构，不引入新的交互语义」。
- **怎么验**：tb 里进应急态 → 连按 Key8 三次 → 退出 → 断言 `res_sel` 已从 4 变成 2（说明按键被记了），而应急期间画面始终满屏。
- **失败长什么样**：吞键 → 退出应急后 `res_sel` 还是 4，用户会以为「按键坏了」；这条**只在「进应急→按几次→退出」的复合序列下暴露**，单步测试抓不到。

---

## §6 t8 集成差异判据（只有集成时才暴露）

### §6.1 I-01 🔴 既有 TB 必须同步改例化

> **★ 更正 addendum `:657` R-01**：定稿称「`image_player` 3 个 TB + `pix_reader` **1 个** TB」。我扫了 `sim/testbench/` 全部 **73 个** `.v` 文件，实测：
>
> | 被例化模块 | 定稿称 | **实测** | 文件:行号 |
> |---|---|---|---|
> | `image_player` | 3 | **3 ✅** | `tb_image_player.v:72`、`tb_display_content.v:47`、`tb_startup_ownership.v:50` |
> | `pix_reader` | 1 | **3 ❌** | `tb_pix_reader.v:103`、**`tb_probe_order.v:115`**、**`tb_probe_pix.v:135`** |
>
> → **实际要改 6 个 TB，不是 4 个。** 漏掉 `tb_probe_order.v` / `tb_probe_pix.v` 的后果：t9 回归时这两个套件静默 x 传播，或直接编译失败。

- **现象**：`image_player` 加 12 个 `ext_wr_*` 端口、`pix_reader` 加 2 个端口后，所有例化它们的 TB 都要同步改。
- **怎么验**：`grep -rln "image_player\s*#\|pix_reader\s*#" sim/testbench/` 应恰好列出上述 6 个文件，且每个文件都能 `iverilog -o /dev/null` 通过编译。
- **缺省接法**（addendum `:657` 建议）：`.ext_wr_mode(1'b0)`、`.src_w(16'd640)`、`.src_h(16'd480)`。
- **失败长什么样**：Verilog 允许端口缺省悬空，**编译可能通过但仿真 x 传播** → t9 回归大面积假红，排查会误以为是新模块的 bug。

### §6.2 I-02 🔴 `video_content_mux.mode` 改接 `disp_mode`（**addendum 未列，我补充**）

- **现象**：顶层 `dmz_eg4s20_hdmi_top.v:280` 现在是 `.mode(mode)`；t8 必须改成 `.mode(disp_mode)`。
- **为什么隐蔽**：接错的现象是「**按 Key2 切科普，画面立刻变化**」而不是「等首帧」——**看起来像正常工作**。只有对着 SD 卡慢速读的场景才暴露：视频第一帧还没解码完，`content_mux` 已经切到 `2'd1` 分支，而 `image_ready` 此时仍指向旧的 BMP → 屏幕上出现「日常图片 + 科普模式标记」的混合态，或直接黑屏 130~400 ms。
- **怎么验**：t8 集成后抓 `mode`、`disp_mode`、`rle_frame_ready_once` 三根波形，断言 `disp_mode` 的 0→1 跳变时刻**晚于** `rle_frame_ready_once`；并断言 `content_mux.mode` 端口接的是 `disp_mode`（`grep -n "\.mode(" dmz_eg4s20_hdmi_top.v` 应指向 `disp_mode`）。
- **失败长什么样**：切模式瞬间闪黑/花屏 130~400 ms（`ARCH_ADDENDUM:254` 的等待期本应显示旧 A/B 帧真实图库内容，接错就变成黑屏）。

### §6.3 I-03 🔴 `bright_lvl[3:0]` 分两路，`video_overlay` 不得接回衰减

- **现象**：`brightness_apply` 收 `bright_lvl[3:0]`（10 档）；`video_overlay.bright_sel` 收 `bright_lvl[2:0]`（只用于信息条第 8/9/10 格显示）。
- **关键事实**：`video_overlay.v:132-135` **t5 已把 5 档衰减整体拆除**，现为直通：
  ```verilog
  // v2: 直通（亮度已移至 brightness_apply.v）
  wire [7:0] r_brt = r_in;
  wire [7:0] g_brt = g_in;
  wire [7:0] b_brt = b_in;
  ```
  端口注释（`:80-81`）也写明「v2: 仅用于信息条亮度格显示（接 `bright_lvl[2:0]`），亮度数据通路已移至 `brightness_apply.v`」。
- **风险**：若 t8 谁把衰减逻辑接回去（或把 `bright_sel` 又串到数据通路），就是**双重变暗**——且双重变暗在亮档（档 0~3）不明显、暗档（档 7~9）才明显，**容易被当成「亮度档位曲线不好」而不是 bug**。
- **怎么验**：`grep -n "r_brt\s*=" rtl/video/video_overlay.v` 应仍为 `r_in` 直通；顶层 `bright_sel` 接 `bright_lvl[2:0]`、`brightness_apply` 接 `bright_lvl[3:0]`；上板按 Key6 逐档走一遍，档 9 应仍能看清参数面板文字（E4 红线）。
- **失败长什么样**：档 9 画面全黑或面板文字不可读 → 直接违反赛规 1.4(4)「参数变化信息可读」。

### §6.4 I-04 🔴 删 `u_kact`/`u_ctrl`，键号冲突

- **现象**：顶层 `dmz_eg4s20_hdmi_top.v:101` 仍例化 `key_action u_kact (`、`:116` 仍例化 `player_ctrl #(...) u_ctrl (`；t8 必须删掉这两个旧实例。
- **键号冲突对照**：`key_action.v:86` `K_BRIGHT = 4'd7` vs 新 `key_router.v:118` `K_BRIGHT = 4'd6`；`player_ctrl.v:223` `K_MODE = 4'd3` vs `mode_ctrl.v:109` `K_MODE = 4'd2`；`player_ctrl.v:224` `K_EMERG = 4'd15` vs `mode_ctrl.v:110` `K_EMERG = 4'd3`。
- **另有 3 处直连消费**：`dmz_eg4s20_hdmi_top.v:84-85`（`key_code==4/5` 直连 `pattern_sel`）、`:402`（`key_code==6` 直控 `audio_muted`）——同样要清除。
- **怎么验**：`grep -n "u_kact\|u_ctrl\|key_action\|player_ctrl" dmz_eg4s20_hdmi_top.v` 应为 0 命中；上板逐键测试，**按一下只动一处**。
- **失败长什么样**：同一 `key_code` 被两个模块消费 → 历史上出现过「按一下切两张图」（`key_router.v:32-35` 记载的事故）。

---

## §7 我无法从定稿确认的口径（供 captain 收口）

| # | 口径 | 我的核查结果 | 建议处置 |
|---|---|---|---|
| Q1 | 「连续 3 帧欠载降 2fps」的出处与性质 | **定稿有，且是契约不是缓解**：`ARCH.md:567`（§6.5 端口契约「接口时序约定」第 8 条）原文「若连续 3 帧 `underrun`，`play_fps` 从 5 自动降到 2…**不降分辨率**」。captain m01992 称「唯一出处是 addendum §13 R-02、属风险缓解」**不成立**（addendum §13 的 R-02 讲的是 `run_len==0`，与降帧无关） | **无需补定稿**；captain 撤回该判断即可。等级已按 captain 的理由降为 🟡（理由本身成立：自适应降级不是用户需求/赛规要求，不挡 t7） |
| Q2 | `pix_reader` 例化点数目 | 定稿 `ARCH_ADDENDUM:657` R-01 称 **1 个**，实测 **3 个**（多出 `tb_probe_order.v:115`、`tb_probe_pix.v:135`） | **建议补进定稿**（把 R-01 的「4 个 TB」改为「6 个 TB」）；这是 t9 回归会踩的实坑 |
| Q3 | `video_content_mux.mode` 改接 `disp_mode` | **addendum 全文未列**（§6.2 只给了 v2 结构，没写顶层连线变更；§8.4 冲突表也未列 `dmz_eg4s20_hdmi_top.v:280`） | **建议补进定稿**（addendum §10 t8 例化清单变更表） |
| Q4 | `bright_lvl[3:0]` 到 `video_overlay.bright_sel[2:0]` 的截位 | 定稿多处说「接 `bright_lvl[2:0]`」（`KEYMAP.md:143`、`ARCH.md` §9.2），但**没说截位后信息条第 8/9/10 格在档 8/9 时的显示**（`bright_lvl[2:0]` 在档 8=3'b000、档 9=3'b001，格 8/9/10 的 `box_lit` 会与档 0/1 完全相同） | **建议补进定稿**或明确接受「档 0/8 显示相同、档 1/9 显示相同」。这是 OSD 显示精度问题，不影响功能 |

---

## §8 rtl-engineer 交付前自检 8 条

按顺序打勾，**前 4 条不过不要提交**：

1. ☐ `pix_mosaic.v` 的 `rgb565_out` 走**组合旁路** `take ? rgb565_in : hold`，**没有**照抄 addendum `:462-468` 的伪码；`tb_pix_mosaic.v` 的 P-01（`src_w=640` 逐拍相等）与 P-02（`src_w<640` 源列数 == `src_w`）全绿。
2. ☐ `pix_reader.v` 只加 `src_w`/`src_h` 两个 input，**未动** `PIX_PER_LINE`/`FRAME_LINES` 缺省值；`image_player.v:492` 的内部例化**已显式接** `.src_w(16'd640)` / `.src_h(16'd480)`。
3. ☐ `rle_decoder.v` 的 `run_len==0` 展开为 **256**（不是 0、不是非法）；`ext_wr_addr[1:0]` 恒 `2'b00`；`ext_wr_done` 只在 153,600 words 全写完时单拍。
4. ☐ 6 个既有 TB 的例化**全部同步改完**（`tb_image_player.v:72`、`tb_display_content.v:47`、`tb_startup_ownership.v:50`、`tb_pix_reader.v:103`、`tb_probe_order.v:115`、`tb_probe_pix.v:135`），且都能编译通过。
5. ☐ `ratio_map.v` 五档窗口值与 `ARCH.md:383-387` 逐字一致；应急态输出 `640/480/0/0` 且**不改写** `ratio_sel` 寄存器。
6. ☐ `emerg_page.v` **无 `clk`/`rst_n`/`posedge`/`negedge`**、无字形 ROM、无斜线（无 `x*y` 类乘法）。
7. ☐ 每个新模块都有对应 tb（`tb_pix_mosaic.v` / `tb_ratio_map.v` / `tb_emerg_page.v` / `tb_rle_decoder.v` 至少各 1 个），且 `sim/scripts` 的回归列表已加入。
8. ☐ 交付时在 commit message 或 `docs/` 里写明：**哪些判据已过、哪些标 🟡 暂缓、哪些是「定稿未覆盖需 captain 裁定」**（对应本文 §7 四条）。

---

## §9 只读声明与文件清单

**本预检为只读，未修改任何文件。** 未改 `SmartCampusMedia/rtl`、`constraints`、`sim`、`docs/plan_v2` 任何一行，未改任何 `.v` / `.adc` / `.sdc` / `.tcl`。

实际读取的文件（字节数 / 行数，均为撰写时刻实测）：

| 文件 | 字节 | 行数 | 用途 |
|---|---|---|---|
| `docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md` | 68,367 | 910 | 新模块端口契约（§9.1/§9.2/§9.3）、V-xx 用例、R-01~R-07 |
| `docs/plan_v2/ARCH.md` | 81,889 | 1,177 | §6.5 `rle_decoder` 契约、§4.1 五档屏占比、§9 八级链路 |
| `docs/plan_v2/KEYMAP.md` | 26,601 | 383 | §9.3 Key8 / §9.4 Key9 五档表、`bright_sel` 接法 |
| `docs/plan_v2/RESOURCE_BUDGET.md` | 41,475 | 481 | E2/E5 归属、双线性不可行口径 |
| `SmartCampusMedia/rtl/top/dmz_eg4s20_hdmi_top.v` | 40,676 | 617 | `u_kact`/`u_ctrl` 现状、`content_mux.mode` 接线 |
| `SmartCampusMedia/rtl/video/video_overlay.v` | 18,591 | 311 | `:132-135` 直通行（I-03 依据） |
| `SmartCampusMedia/rtl/storage/image_player.v` | 26,033 | — | `:492` 内部例化（R-04 依据） |
| `SmartCampusMedia/rtl/storage/pix_reader.v` | 13,863 | 282 | 现状端口表与状态机 |
| `SmartCampusMedia/rtl/storage/img_scaler.v` | — | 530 | 缩小算法与放大不可行论证（E3 参考） |
| `SmartCampusMedia/rtl/control/key_router.v` | 17,691 | — | `ratio_sel`/`res_sel` 复位值 |
| `SmartCampusMedia/rtl/control/mode_ctrl.v` | 14,140 | — | `CONFIRM_MS`/`disp_mode` 相关 |
| `SmartCampusMedia/sim/testbench/*.v` | — | 73 个文件 | 扫例化点（I-01 / Q2 依据） |
| `SmartCampusMedia/reports/diag_key1_fifo_backpressure_20261101/area.txt` | 24,544 | 243 | 资源基线 |

---

**文档结束。**
