# T1 → T7 接线指引（pix_mosaic / ratio_map 集成说明书）

> **本文只写接线，不改任何 RTL。** 写给 t7（rtl-integ）在集成时直接照做，
> 免得对着 `ARCH_ADDENDUM_VIDEO_PATH.md` §9.1 的旧端口契约去猜。
>
> 所有端口、行号、位宽都是**对着当前磁盘上的真实代码**逐条核过的，不是照抄文档。
> 依据文件：`rtl/video/pix_mosaic.v`（154 行）、`rtl/video/ratio_map.v`（133 行）、
> `rtl/top/dmz_eg4s20_hdmi_top.v`（现状 40,676 B）、`rtl/video/image_window_mask.v`（43 行）、
> `rtl/control/key_router.v`、`rtl/control/mode_ctrl.v`、`rtl/storage/image_player.v`。
>
> 实测数据见 `docs/plan_v2/T1_GEOM.md`（149 条断言全绿、变异反证 fail=80、TD 面积）。
>
> **修订记录**：2026-11-02 第二版 —— Key9 的去向由 captain 裁决为
> 「`pix_reader` 消费侧降采样」（原文中「`win_w` 就是 `src_w`」的旧设想已删除，
> 其证否过程见 §5 问题③）。`pix_mosaic` / `ratio_map` 两个模块本身**未做任何改动**。

---

## 0. 先说四条最容易踩的坑（读完这一段再往下看）

| # | 坑 | 事实 | 后果 |
|---|---|---|---|
| ① | 按 addendum §9.1 例化 `pix_mosaic` | 该处端口是 `pixel_clk` + 有 `de`；**实际实现是 `clk`、无 `de`** | 编译直接报「端口不存在」，不是仿真出错 |
| ② | 把 `pix_mosaic` 与 `image_window_mask` **串联** | `image_window_mask` 没有像素端口（只有 1 位 `pixel_valid`），**物理上无法串在像素通路上** | 接线时无处可插，会卡住。正确拓扑见 §2 |
| ③ | `ratio_map` 输出直接连线到 `win_*` | `ratio_map` 输出 **11/10 位**，`image_window_mask` 的 `win_*` 是 **16 位**（`:25-28`） | 功能能跑，但位宽告警会被 t10 审计挑出来。必须显式补零 |
| ④ | `ratio_map` 的 `win_*` 分别从两处取给两个下游 | Key9 有**两个**消费者：`image_window_mask`（位置门控）与 `pix_reader`（窗口内降采样），**必须接同一组 `mask_win_*`** | 接成两个不同来源 → 窗口位置与采样范围错位 → 画面被切一半，**不报任何错**。见 §1.2 末 |

---

## 1. 两个模块的例化模板（可直接粘贴）

### 1.1 `pix_mosaic` —— 输出**必须**是 wire

```verilog
// ---------------------------------------------------------------------------
//  Key8 水平抽样（rtl/video/pix_mosaic.v，154 行）
//  ⚠️ rgb565_out / valid_out 在模块内声明为 output wire（组合输出），
//     顶层连接到 wire 即可，**不要**接到 reg，也不要给它加输出寄存器。
//     加一拍输出延迟 = 像素整体右移 1 像素，同时把「与 rgb565_in 同拍」
//     这条红线（V-01）直接破坏。
// ---------------------------------------------------------------------------
wire [15:0] img_pix565;      // 抽样后的像素
wire        img_pix_valid;   // 抽样后的像素有效（直通，与输入同拍）

pix_mosaic u_pix_mosaic (
    .clk        (clk_pixel),      // 注意：端口名是 clk，不是 pixel_clk
    .rst_n      (rst_n),
    .active_x   (active_x),       // video_timing_gen 输出，0..639，消隐期为 0
    .src_w      (eff_src_w),      // 16 位；由 res_sel 查表并经应急钳位，见 §3
    .rgb565_in  (image565),       // image_player.rgb565（原始输出，未打拍）
    .valid_in   (image_pixel_valid),  // 见 §5 问题①：接哪一路的取舍
    .rgb565_out (img_pix565),     // wire
    .valid_out  (img_pix_valid)   // wire
);
// 本模块**没有** de 端口。addendum §9.1 里的 .de(...) 一定不要写。
```

### 1.2 `ratio_map` —— 纯组合，输出是 reg，接 16 位要补零

```verilog
// ---------------------------------------------------------------------------
//  Key9 屏占比映射（rtl/video/ratio_map.v，133 行，纯组合 0 寄存器）
//  输出位宽：win_w / win_off_x = 11 位，win_h / win_off_y = 10 位。
//  下游 image_window_mask 的四个 win_* 端口全是 16 位 ⇒ 必须显式补零。
// ---------------------------------------------------------------------------
wire [10:0] rm_win_w;
wire [9:0]  rm_win_h;
wire [10:0] rm_win_off_x;
wire [9:0]  rm_win_off_y;

ratio_map u_ratio_map (
    .ratio_sel  (ratio_sel_eff),   // 经应急钳位的档位，见 §3
    .win_w      (rm_win_w),
    .win_h      (rm_win_h),
    .win_off_x  (rm_win_off_x),
    .win_off_y  (rm_win_off_y)
);

// ---- 位宽补零（11→16 / 10→16）：显式写，别依赖隐式补零 ----
wire [15:0] mask_win_w     = {{5{1'b0}}, rm_win_w};      // 11 → 16
wire [15:0] mask_win_off_x = {{5{1'b0}}, rm_win_off_x};  // 11 → 16
wire [15:0] mask_win_h     = {{6{1'b0}}, rm_win_h};      // 10 → 16
wire [15:0] mask_win_off_y = {{6{1'b0}}, rm_win_off_y};  // 10 → 16
```

#### ⚠️ `ratio_map` 的输出有**两个**消费者，必须接同一组信号

Key9 落在两个地方（captain 2026-11-02 裁决，见 §5 问题③）：

| 消费者 | 吃哪几个信号 | 干什么 |
|---|---|---|
| `image_window_mask` | `win_w / win_h / win_off_x / win_off_y` | **位置门控** —— 决定窗口外打黑（有效位通路） |
| `pix_reader`（t4 新增端口） | `win_w / win_h / win_off_x / win_off_y` | **窗口内降采样** —— 决定窗口内每列/每行取哪个源列/源行 |

> **必须让这两个消费者接到同一组 `mask_win_*` 信号。**
> 如果接成两个不同来源（例如 mask 接 `ratio_map`、reader 接 `image_player.out_*`），
> 后果是**窗口位置与采样范围错位**：窗口框在中间 320×240，但 pix_reader 按整屏 640×480
> 排布源列 → 画面被切一半（下半/右半黑），**不报任何错**，只有看屏幕才发现。
> 这是本文件里最容易在集成时踩的一个「静默错误」，请把 `mask_win_*` 四个 wire 同时接到两边。

### 1.3 `image_window_mask` 的改动（只改 `win_*` 四个接线，端口不动）

```verilog
// 现状（rtl/top/dmz_eg4s20_hdmi_top.v:273-277）win_* 接的是 image_player 的 out_*
// v2：改接 ratio_map（addendum :342 已定「与 image_player.out_* 解耦」）
image_window_mask u_image_mask (
    .de              (de),
    .active_x        (active_x),
    .active_y        (active_y),
    .win_w           (mask_win_w),        // ← 由 ratio_map 驱动（补零后）
    .win_h           (mask_win_h),        // ←
    .win_off_x       (mask_win_off_x),    // ←
    .win_off_y       (mask_win_off_y),    // ←
    .pixel_valid     (img_pix_valid),     // ← 见 §5 问题①
    .pixel_valid_out (image_pixel_shown)
);
// ⚠️ 改接之后 image_player 的 out_w/out_h/out_off_x/out_off_y 这四个端口
//    在本层就没有消费者了。不要删端口（那是 t4 的域），空连接即可：
//       .out_w(), .out_h(), .out_off_x(), .out_off_y(),
//    ★ 语义问题已于 2026-11-02 由 captain 裁决（走 pix_reader 消费侧降采样），
//      结论见 §5 问题③。这里只需照抄接线即可，不要再自行判断。
```

---

## 2. 接入位置：正确拓扑是**并联**，不是串联

### 2.1 像素链现状（`dmz_eg4s20_hdmi_top.v` 实测行号）

```
image_player u_player  (:242)
   ├─ .rgb565(image565)              (:247)
   ├─ .pixel_valid(image_pixel_valid) (:247)
   └─ .out_w/.out_h/.out_off_x/.out_off_y  (:248)
        │
        ├──────────────────────► image888（RGB565→RGB888 位复制扩展，:260）
        │                              │
        │                              ▼
        │                        video_content_mux u_content_mux (:279)
        │                              │
        │                              ▼
        │                        video_overlay u_overlay (:429)
        │                              │
        │                              ▼
        │                        osd_panel u_osd_panel (:462)
        │                              │
        │                              ▼
        │                        video_rgb_to_axis u_axis (:325)
        │
        └── image_window_mask u_image_mask (:273)
                  └─ .pixel_valid_out(image_pixel_shown) ──► content_mux.image_pixel_valid
```

### 2.2 插入 `pix_mosaic` 的位置

**`pix_mosaic` 插在 `u_player.rgb565` 与 `image888` 之间** —— 即像素数据流上，
`image_player` 之后、`video_content_mux` 之前：

```
u_player.rgb565 ──► pix_mosaic ──► img_pix565 ──► image888 ──► content_mux.image_rgb
                          ▲
u_player.pixel_valid ─────┘（见 §5 问题①）

video_timing_gen.active_x ────► pix_mosaic.active_x   （u_vtg 输出，:127 例化）
eff_src_w ────────────────────► pix_mosaic.src_w      （参见 §3.1）
clk_pixel / rst_n ────────────► pix_mosaic.clk / .rst_n
```

### 2.3 ⚠️ 与 captain 口述的一处拓扑纠正（必须记录）

captain 的指示原文是「应在 `image_window_mask` 门控**之后**、`video_content_mux` **之前**」。
这句话的**语义**是对的（抽样作用于像素内容，门控作用于 1 位有效位，两者作用域不重叠），
但**拓扑**上不可能成立：

> `rtl/video/image_window_mask.v:22-30` 的端口里**没有任何像素端口** ——
> 输入是 `de / active_x / active_y / win_w / win_h / win_off_x / win_off_y / pixel_valid`，
> 输出只有一个 `pixel_valid_out`（1 位）。它压根不搬运像素。

所以 `pix_mosaic` 与 `image_window_mask` 是**同一级的并联两条支路**，各自处理一半：

| 支路 | 处理对象 | 位置 |
|---|---|---|
| `pix_mosaic` | **像素内容**（`rgb565` 16 位） | `u_player.rgb565` → `image888` 之间 |
| `image_window_mask` | **像素有效位**（`pixel_valid` 1 位） | `u_player.pixel_valid` → `content_mux.image_pixel_valid` |

两条支路都汇入 `video_content_mux`（一条进 `image_rgb`、一条进 `image_pixel_valid`），
**这就是「`image_window_mask` 之后、`content_mux` 之前」的准确物理形态**。

> **给答辩/审计的一句话**：Key8 改的是「这一行从母带里取哪些点」（内容通路），
> Key9 改的是「哪些点算数」（有效位通路：`image_window_mask` 决定窗口外打黑），
> 二者正交，**所以能同时生效且互不干扰**。
>
> 补充（2026-11-02 裁决后）：Key9 除了「哪些点算数」还要决定「窗口内怎么排布」，
> 后者落在 `pix_reader` 的消费侧降采样，见 §5 问题③。三条支路仍互不重叠：
> 内容抽取（`pix_mosaic`）／窗口门控（`image_window_mask`）／窗口内节奏（`pix_reader`）。

---

## 3. 应急钳位：三行，**全部在顶层做**

### 3.1 代码

```verilog
// ===========================================================================
//  应急态（mode == 2'd2）几何钳位
//  依据：ARCH_ADDENDUM_VIDEO_PATH.md:380
//        「应急态下 Key8/Key9 按键仍被消费并更新 res_sel/ratio_sel 寄存器值
//         （不吞 key_event），但 disp_mode == 2'd2 时 ratio_map 强制输出
//         640/480/(0,0)、pix_mosaic 强制旁路。退出应急立刻恢复用户之前选的档位。」
//  与 KEYMAP §5.1 音量「应急下限钳位」完全同构。
// ===========================================================================

// 第 1 行：Key8 —— res_sel 查表得源宽/源高（KEYMAP §9.3）
reg [15:0] res_src_w, res_src_h;
always @(*) begin
    case (res_sel)
        3'd0:    begin res_src_w = 16'd320; res_src_h = 16'd240; end
        3'd1:    begin res_src_w = 16'd400; res_src_h = 16'd300; end
        3'd2:    begin res_src_w = 16'd512; res_src_h = 16'd384; end
        3'd3:    begin res_src_w = 16'd576; res_src_h = 16'd432; end
        default: begin res_src_w = 16'd640; res_src_h = 16'd480; end
    endcase
end

// 第 2 行：Key8 应急钳位 —— 强制 640 = 恒等旁路（addendum :469）
//   src_w=640 时 take 每拍为真，rgb565_out 逐拍 === rgb565_in，零画质损失
wire [15:0] eff_src_w   = (disp_mode == 2'd2) ? 16'd640 : res_src_w;
wire [15:0] eff_src_h   = (disp_mode == 2'd2) ? 16'd480 : res_src_h;

// 第 3 行：Key9 应急钳位 —— 档位 4 的查表结果正是 640x480@(0,0)
wire [2:0]  ratio_sel_eff = (disp_mode == 2'd2) ? 3'd4 : ratio_sel;
```

### 3.2 为什么只在顶层做，模块内不做

| 理由 | 说明 |
|---|---|
| **寄存器记用户值，输出端钳位** | 用户选的档位必须原样留在 `res_sel` / `ratio_sel` 里。若把钳位写进模块内部去改写这两个寄存器，退出应急后用户的档位就丢了 —— 而这正是 `KEYMAP §5.1` 音量应急下限的处置方式：`vol_apply` 内部算 `eff_lvl_w`，`vol_lvl` 寄存器不动（`rtl/audio/vol_apply.v:89`） |
| **不吞按键** | 应急期间按 Key8/Key9 必须仍有反馈（OSD 弹参数），只是不改变画面 |
| **钳位点与「应急画面来源」同源** | 应急图从 `content_mux` 的 `2'd2` 位置注入（addendum :378），它**不经过** `pix_mosaic` 与 `image_window_mask`。钳位逻辑跟着 `disp_mode` 走，一处即可覆盖全部消费者 |
| **模块保持单一职责** | `pix_mosaic` 只认 `src_w`、`ratio_map` 只认 `ratio_sel`，两个模块都不需要知道「什么是应急」。TB 因此也不用覆盖 4 种 `disp_mode` × 5 档的笛卡尔积（省 20 个用例） |

### 3.3 ⚠️ 前置依赖：`mode_ctrl` 目前**没有** `disp_mode` 输出

实测 `rtl/control/mode_ctrl.v:73-93` 的输出只有：
`mode[1:0]`、`emerg_latched`、`emerg_src[1:0]`、`confirm_armed`、`mode_changed`、
`daily_mode`、`science_mode`、`emerg_mode` —— **没有 `disp_mode`**。

addendum §5.2（`:236-249`）要求追加 `output reg [1:0] disp_mode`，其生效规则是
「`mode==2'd2` 时**无条件**立即跟随」。因此：

> **应急态下 `mode == 2'd2` 与 `disp_mode == 2'd2` 等价**（相差不超过 1 拍，且应急图
> 是纯组合零 SD 依赖，1 拍不可见）。t7 若尚未给 `mode_ctrl` 加 `disp_mode`，
> **临时用 `mode` 替代是安全的**；但最终应与 addendum 对齐，避免 t10 审计时口径不一。
>
> 注意 `mode_ctrl` 的 `disp_mode` 还依赖 `rle_decoder` 的 `rle_frame_ready_once`
> （t4 的域），这个信号没到位之前**不要**强行加 `disp_mode`。

> **📌 欠账（留痕，别忘了）**
> **临时用 `mode` 替代 `disp_mode`。**待 t4 交出 `rle_frame_ready_once` 之后，
> 由 **rtl-integ（t7）** 把 §3.1 里三处 `disp_mode` 换回真正的 `disp_mode` 信号。
> 记账日：2026-11-02。换回前 `mode` 与 `disp_mode` 在应急态等价，功能不受影响。

---

## 4. 完整接线速查表

| 来源 | 目标 | 位宽处理 | 备注 |
|---|---|---|---|
| `key_router.res_sel[2:0]` | §3.1 查表 → `eff_src_w[15:0]` | 无 | **注意：顶层当前没有例化 `key_router`**（见 §6） |
| `eff_src_w` | `pix_mosaic.src_w` | 16 ✓ | |
| `eff_src_h` | `image_player.src_h` | 16 ✓ | 顶层的 `u_player` 例化现在**没接** `.src_w/.src_h`（t4 新增端口） |
| `eff_src_w` | `image_player.src_w` | 16 ✓ | 同上 |
| `image565` | `pix_mosaic.rgb565_in` | 16 ✓ | |
| `img_pix565` | `image888` 的位复制扩展输入 | 16 ✓ | 原 `image565` 的消费点改为它（`:260`） |
| `key_router.ratio_sel[2:0]` | `ratio_sel_eff` → `ratio_map.ratio_sel` | 3 ✓ | |
| `ratio_map.win_w[10:0]` | `image_window_mask.win_w[15:0]` | **11→16 补零** | |
| `ratio_map.win_off_x[10:0]` | `image_window_mask.win_off_x[15:0]` | **11→16 补零** | |
| `ratio_map.win_h[9:0]` | `image_window_mask.win_h[15:0]` | **10→16 补零** | |
| `ratio_map.win_off_y[9:0]` | `image_window_mask.win_off_y[15:0]` | **10→16 补零** | |
| `mask_win_w`（同一组） | `pix_reader.win_w`（t4 新增端口） | 16 ✓（**已补零的那组**） | ★ 必须与上面 mask 接**同一组信号**，见 §1.2 末 |
| `mask_win_h`（同一组） | `pix_reader.win_h`（t4 新增端口） | 16 ✓ | ★ 同上 |
| `mask_win_off_x`（同一组） | `pix_reader.win_off_x`（t4 新增端口） | 16 ✓ | ★ 同上 |
| `mask_win_off_y`（同一组） | `pix_reader.win_off_y`（t4 新增端口） | 16 ✓ | ★ 同上 |
| `img_pix_valid` | `image_window_mask.pixel_valid` | 1 ✓ | 见 §5 问题① |
| `pixel_valid_shown` | `video_content_mux.image_pixel_valid` | 1 ✓ | 不变 |

---

## 5. 三个必须在集成前想清楚的问题（① 有结论、② 可接受、③ 已裁决）

### 问题① `pix_mosaic.valid_in` 接 `image_pixel_valid` 还是 `pixel_valid_shown`？

**结论：对本模块的抽样行为来说，接哪个都一样。** 这是可以证明的，不是猜测：

> `pix_mosaic.v:115` 的抽样判定是 `wire take = (active_x == 11'd0) || (x_acc >= OUT_W);`
> —— 相位只由 `active_x`（全行推进，不受窗口门控影响）与 `src_w` 决定。
> `valid_in` 在 `:122` 是 `assign valid_out = valid_in;` **纯直通**，
> 它**不参与** `x_acc` / `hold` 的任何赋值（`:133-152` 的时序块里没有 `valid_in`）。

所以**抽样结果恒定**，两种接法只差「下游看到的有效位是哪一路」：

| 接法 | `valid_out` 语义 | 后果 |
|---|---|---|
| A：接 `u_player.pixel_valid`（**推荐**） | 未经窗口门控 | `valid_out` 送进 `image_window_mask.pixel_valid`，窗口门控仍由 mask 一处完成，**职责不重叠** |
| B：接 `u_image_mask.pixel_valid_out` | 已经过窗口门控 | 形成 `mask → mosaic → mask` 的**环**（mosaic 的 valid 又进 mask），TD 会报组合环 |

> ⚠️ **接法 B 会成环**：`image_window_mask.pixel_valid_out` 已经含 `in_window` 项，
> 再回喂 `pix_mosaic.valid_in` → `valid_out` → `image_window_mask.pixel_valid`，
> 在 `pixel_valid_out` 上构成组合自环。**必须用接法 A。**

captain 提到的「接错的表现是『窗口外的像素也被抽样，但反正被 mask 掉了』看起来正常」——
这正是接法 A，而且它**就是正确的**：抽样与门控正交，窗口外抽样被 mask 掉是设计意图，
不是缺陷。真正的错法是接法 B（组合环）。

### 问题② `src_w` 在帧中途变化（用户按 Key8）会怎样？

**行为：下一行首自动按新档位抽样，不会累积误差，但当前行会「半行旧档 + 半行新档」。**

证据链：
- `pix_mosaic.v:133-152` 的行首分支是 `active_x == 11'd0` → `x_acc <= src_w`（重装载）+
  `hold <= rgb565_in`。`key_router.v:258` 明确「`res_sel` 在 `key_event` 后同一拍更新，
  下游下一拍看到新值」，**没有跨时钟域**。
- `video_timing_gen.v:207` `active_x <= de_c ? (h_cnt - H_ACT_START) : 11'd0;`
  —— 消隐期 `active_x` 恒 0，会反复命中行首分支，因此 `x_acc` 在每一行都被重新装载。
- ⇒ 换档发生在行中途时，本行已输出的部分用旧 `src_w`、后续用新 `src_w`：**该行会有一处
  相位跳变**（最多 1 个像素列的重复/丢失），下一行起完全正确。

判断：**可接受**。理由：换档是人手按键（≥100 ms 间隔），一行的相位跳变在 60 Hz 下
不可见；且 `addendum:404` 提到的 `cfg_changed → frame_start 清累加器` 那一套握手，
本实现的「行首重装载」已经覆盖了它的功能，**不需要额外端口**。
若 t7 追求帧级干净，可把 §3.1 的 `res_src_w` 打一拍并只在 `frame_start` 锁存 ——
但那是**优化项**，不是缺陷修复，且会多 16 个寄存器。

### 问题③ `src_w`（Key8）与 `win_w`（Key9）语义重叠 —— **已裁决（2026-11-02）：走 `pix_reader` 消费侧降采样**

两个参数都落在「宽度」上，但它们控制的不是同一件事：

| 参数 | 出处 | 干什么 | 执行者 |
|---|---|---|---|
| `src_w`（= `eff_src_w`） | Key8 → `res_sel` → 查表 | 决定从**母带**里抽多少个水平点（内容抽样 + 放大） | `pix_mosaic`（本文件 §1.1） |
| `win_w` | Key9 → `ratio_sel` → `ratio_map` | 决定**显示窗口**多宽 + 窗口内怎么排布源像素 | `image_window_mask`（位置门控）+ **`pix_reader`（窗口内降采样）** |

#### 为什么不能只改 `image_window_mask.win_*`（B 方案被否）

把 `win_*` 从 `image_player.out_*` 改接 `ratio_map` 之后，`win_*` 的含义从
「当前这张 BMP 缩放后的实际内容矩形」变成「用户选的固定窗口矩形」。
若只做这一改，**Key9 就从「把图缩小」变成了「把图裁掉一部分」**：

> 一张 640×480 的 BMP，用户按 Key9 选档 0（320×240 @ (160,120)）：
> 只显示中间 320×240 一块，其余全黑 = **裁剪**，建筑被切掉一半。

用户原话是「Key9 是切换**屏幕大小**（1/2 到 1 分 5 档）」。裁剪不是「屏幕变小」，
是「镜头拉近」。**B 不可接受。**

#### 为什么不是「让 `pix_mosaic` 做窗口相对重采样」（D 方案被否，实测证否）

曾设计过一版 D：把 `pix_mosaic` 的 Bresenham 模数从常量 `OUT_W=640` 换成运行时
`win_w`、行首判据从 `active_x == 0` 换成 `active_x == off_x`，试图让读侧一步完成
「把整幅源图压进 `win_w`」。**逐拍 bit-exact 模拟后证否**，两个层次的障碍：

**障碍一：那个写法实际行为就是 B（裁剪）。** 按 D 的伪代码模拟：

| `src_w` | `win_w` | `off_x` | 窗口内实际采到的源列 | 理想 `floor((n-off_x)·src_w/win_w)` | `ref_err` |
|---|---|---|---|---|---|
| 640 | 640 | 0 | 0..639 顺序 | 0..639 | **0** ✓ |
| 640 | 320 | 160 | **160..479 原样直通** | 0,2,4,…,638 | **319/320** ✗ |

根因在重装载行 `if (active_x == off_x) x_acc <= src_w;`：装进去就是 640，
下一拍判据 `x_acc >= win_w` 即 `640 >= 320` **恒真**，于是每拍都 take、`hold` 永不生效，
累加器完全没参与抽样，退化成直通。**缩小方向（`src_w >= win_w`）先天满足这个条件，
这个写法只能放大、不能缩小。**

**障碍二（根本）：输入流与输出流共用 `active_x` 一把标尺。**
`pix_mosaic` 的位置决定「第 k 拍输入的源列是 k，第 k 拍输出的目标列也是 k」。
要让输出列 `off_x+j` 显示源列 `2j`：`j < off_x` 时源列**已经流过**（要取它必须存进缓存）；
`j > off_x` 时源列**还没到**（要取它必须等待）。单寄存器 `hold` 只能重复
**刚过去的那个**像素（放大），**取不到更早已流过的列**（缩小）。真要缩小必须缓存整行
（640×16 = 10,240 bit），而这正是 `pix_mosaic`「零行缓存、单寄存器」定位所排除的 ——
这是**采样定理级别**的不可行，换任何 Bresenham 写法都绕不过。

> 附带：captain 原拟的「端点对齐」（第 319 个输出列取源列 639）与 Bresenham 固有偏差
> 冲突 —— `floor(319×640/320) = 638`。要端点精确到 639 需改用 forced-endpoint
> 形式（模数 `(src_w-1)/(win_w-1)`），那会同时破坏 `n=0` 取源列 0 的另一处定点，
> **两个端点无法在单一 Bresenham 上同时精确对齐**。已裁定：**放弃强制端点，
> 统一以 `floor` 模型为唯一参考**，且参考模型公式两份代码用同一个
> （`pix_mosaic` 注释里的 `ceil(i*640/src_w)`，不要各写一套，否则将来对不上无法判断谁错）。

#### 最终方案：Key9 落 `pix_reader` 的**消费侧降采样**

`pix_reader` 掌握 FIFO 读使能，行内**可以任意决定每拍出队几个字**，所以它能做缩小；
`pix_mosaic` 掌握内容变换，做抽样放大。两者正交，各归其位。

关键事实（SDRAM 存储格式）：**一个字 = 两个相邻像素（偶低奇高），一行 640 像素 = 320 字。**
Key9 档 0 要「320 窗口显示完整的 640 列、每 2 列取 1」，取的正是像素 0,2,4,…,638 ——
**全在每个字的低半字里**。于是窗口内每拍消耗 1 字、只用低半字，320 拍耗完 320 字，
**一行总消耗量仍是 320 字，SDRAM 读带宽一点不涨**。
一般 N:M 只是把「每 2 像素出 1 字」换成按 Bresenham 出队，
与 `pix_reader` 现有的垂直 DDA（`pix_reader.v:163-199`，行末推进 `src_y = floor(active_y·src_h/480)`）
是**同一套算法在两个维度上**。

数学：目标列 `n`，窗口 `[off_x, off_x+win_w)`，源列
```
src_col(n) = floor( (n - off_x) * src_w / win_w )
```
- `win_w=640, off_x=0, src_w=640` → `src_col = n`，**恒等**（Key8/Key9 都默认时零变化）
- `win_w=320, off_x=160, src_w=640`（Key9 档 0）→ 整幅 640 宽压进 320 宽 →
  **整图缩小一半、居中、内容完整** ← 这才是「屏幕大小 1/2」
- `win_w=320, src_w=320`（再叠 Key8 档 0）→ 源先抽稀再缩小 → 更糊 → **两键正交**

#### 答辩口径（可直接讲）

> **Key8 改「取哪些点」，Key9 改「哪些点算数」。** 前者是内容变换（`pix_mosaic` 抽样放大），
> 后者是消费侧节奏（`pix_reader` 在窗口内决定每列/每行消耗哪个源像素，
> `image_window_mask` 决定窗口外打黑）。二者正交，所以能同时生效且互不污染。

#### 职责边界（避免写冲突，务必遵守）

| 谁 | 改什么 |
|---|---|
| **t1（rtl-geom）** | `pix_mosaic.v` / `ratio_map.v` **保持原样**，语义不变（149 条断言继续有效）。本文件只提供接线指引 |
| **t4（rtl-storage）** | `pix_reader.v` 加窗口内降采样（水平 + 垂直同源改造） |
| **t7（rtl-integ）** | 按本文件接线；`ratio_map` 的 `win_*` **同一组信号**同时喂 `image_window_mask` 与 `pix_reader` |

### 问题③附：像素级契约**不在本文件**（由 t4 补齐）

> **本节留空，等 t4（rtl-storage）补。**
>
> 「窗口内具体取哪个源列、跳过哪根源行」的逐拍契约，写在 t4 的交付文档里
> （`docs/plan_v2/` 下 t4 的实现说明）。原因：`pix_reader.v` 正在由 t4 改造，
> 由我（t1）写这段会和他的实现打架、且我无法验证他的最终出队时序。
>
> **留给 t4 必须交代的三条**（t7 集成时要能用它们自检）：
> 1. `win_w=640, off_x=0, src_w=640` 时逐拍恒等（不得有整体偏移）；
> 2. `win_w=320, off_x=160, src_w=640` 时窗口内不同源列数恰为 320，
>    且与闭式模型 `floor((n-160)*640/320)` 逐拍 `ref_err=0`；
> 3. `win_w=320, src_w=320` 时不同源列数恰为 320，且画面与
>    `win_w=640, src_w=320` 一致（证明两键正交、不互相污染）。
>
> 记账日：2026-11-02。

---

## 6. 集成前的现状盘点（t7 开工时会发现「不对劲」的三处）

| # | 现状事实 | 影响 |
|---|---|---|
| ① | `rtl/control/key_router.v`（含 `res_sel:90` / `ratio_sel:91`）**尚未被顶层例化**。顶层 `dmz_eg4s20_hdmi_top.v` 里 `key_router` 出现 **0 次**，`mode_ctrl` 也 **0 次** | 顶层仍在用 v1 的 `key_action u_kact`（`:101`）+ `player_ctrl u_ctrl`（`:116`，其 `:121` 输出 `mode`）。t7 要新增 `u_router` 与 `u_mode` 两个实例，并把 Key7~Key15 的译码从 `u_kact` 迁走 |
| ② | `u_player` 例化（`:242-253`）**没有接** `.src_w/.src_h` | 这两个是 t4 新增的端口（`image_player.v:79-80`），不接的话垂直行映射不生效（`pix_reader` 内部 `src_ok=0` 会退回恒等映射） |
| ③ | `u_content_mux` 例化（`:279-283`）**仍然有** `.science_rgb(science_rgb)` | v2 要改成 `.emerg_rgb(...)`（addendum §6.2，3 源→2 源）。这条属 t2/t7 交界，不属 T1 |

---

## 7. 集成自检清单（编译通过后按顺序核，5 分钟）

```
□ 1. pix_mosaic 例化里**没有** .de(...)，端口名是 .clk 不是 .pixel_clk
□ 2. img_pix565 / img_pix_valid 声明为 wire（不是 reg）
□ 3. ratio_map 四个输出到 image_window_mask 之间，四个 {{N{1'b0}}, ...} 补零都在
□ 4. image_window_mask 的 .pixel_valid 接的是 img_pix_valid，**不是** pixel_valid_shown（否则组合环）
□ 5. image888 的输入是 img_pix565，不是原来的 image565
□ 6. u_player 已接 .src_w(eff_src_w) / .src_h(eff_src_h)
□ 7. ratio_sel_eff / eff_src_w 两个三目钳位都在，且用 disp_mode（或临时 mode）
□ 8. mask_win_w/h/off_x/off_y 四个 wire 同时接到 image_window_mask 与 pix_reader
      （**同一组**；接成两个来源 → 画面被切一半且不报错，见 §1.2 末）
□ 9. 跑 scripts\lint_verilog.py → E0/E1/E2 全 0、打印「结论: 通过」
□ 10. 综合后 report_area，用 Utilization 段的 #lut 与 15,319 相减得真实增量
       （**不要**用层级表逐行累加，见 T1_GEOM.md §3.2.1）
```

---

## 8. 参考

| 内容 | 文件 |
|---|---|
| T1 实现说明 / 149 条断言 / 五档抽样数据表 / 面积双口径 | `docs/plan_v2/T1_GEOM.md` |
| Key8/Key9 档位权威表 | `docs/plan_v2/KEYMAP.md` §9.3、§9.4 |
| 像素链与 mux 结构 | `docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md` §6、§7 |
| 应急钳位裁定 | 同上 `:380`；`KEYMAP.md §5.1`（同构先例） |
