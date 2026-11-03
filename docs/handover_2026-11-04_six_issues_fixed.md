# 交接：六项上板问题修复（2026-11-04）

> **交接对象**：下一位接手的 AI 或人。
> **接手前必读**：[ai_handover.md](ai_handover.md)（项目总纲与硬性约束）→ 本文件 → [上板检查表](../reports/board_check_20261103.md)。
> **状态**：代码已全部提交并推送（`50468ad`），**位流已生成但一次都没上过板**。所以本文所有「已修复」都只到「仿真 + 综合布线」为止，不含板端确认。

---

## 0. 一句话现状

用户报了 6 个上板问题，全部定位到代码级根因并修复；七套回归 911,909 断言全绿；TD 四趟后成功出位流（Setup WNS **+109 ps** / Hold **+19 ps** / 0 违例）；**新位流 `AA65465E…` 还没上板**，所以「修好了」这三个字目前没有板端证据。

**下一步只有一个动作：按 [上板检查表](../reports/board_check_20261103.md) 烧 `AA65465E…` 并逐条回填。**

---

## 1. 基线锚点（回退用）

| 项 | 值 |
|---|---|
| 本轮开始时的回退基线 | `1ecae325ff5ae054bf05001f291a52e0116bcf9b`（t1 建立，v2 工作树全量入库） |
| 本轮结束 | `50468ad`，`origin/main` 一致，工作树干净 |
| 修复前位流（**不要烧错**） | `59A6BACC75613F5E953B7ED5A33E05E8`，648,264 B，2026-11-03 00:31:47 |
| 修复后位流 | **`AA65465E3F41E16C49E5EAE13D0EEC38`**，648,264 B，2026-11-03 23:35:55 |
| 位流位置 | `project/hdmi_td_Runs/phy_1/hdmi_td.bit`；归档副本 `reports/t10_r2_verify_build_20261103_PASS/hdmi_td_r2_hfn_AA65465E.bit` |

> ⚠️ **两版位流大小完全相同（648,264 B）**，这是该器件的固定输出尺寸。**判别只能看 MD5，不能看文件大小或时间戳**。

本轮 6 个提交：

```
50468ad docs(plan_v2): 补齐 v2 规划文档体系（此前全部缺失）        47 files +27,628
6b32281 docs(reports): 本轮六项修复的诊断、实施、验证与审查证据     28 files +35,216/-26
c214a53 docs: 同步键位表、8 像素对齐与缩放算法的描述               6 files   +34/-23
0a7a2de build: 补回归覆盖缺口、修脚本编码、新增可复用的 TD 布线入口  5 files  +352/-13
01518db test: 补齐上述六项修复的 testbench 断言与覆盖缺口           9 files  +837/-103
ccee236 fix(rtl): 修复用户上板反馈的六项问题                      23 files +1,333/-163
```

---

## 2. 六项修复：根因 → 改动 → 证据

### ① 日常/科普没有声音

**根因（主因，R1）**：`rtl/audio/audio_src_mux.v:34-36` 三个 8.3 短名常量**字节序写反**。

Verilog 拼接**最左操作数落最高位**，所以 `{"BGM", 40'h20_20_20_20_20, "WAV"}` 的 `[7:0]` 是 `'V'`(0x56)，而 `rtl/storage/fat32_reader.v:683` 的 `5'd0: exp_byte = target_name[7:0];`（`:684-693` 依次 `[15:8]`…`[87:80]`）拿它当**目录项第 0 字节**逐字节比对 ⇒ 永远不命中 ⇒ `err_code=4` ⇒ `W_FAIL` ⇒ 静默无声。

**为什么单元 tb 全绿却上板无声**（这是本项目最值得记住的一课）：`tb_audio_src_mux.v:67-69` 与 `tb_wav_stream_player.v:559-560` 都用 **parameter override 传了正确常量**，绕过 RTL 默认值；而顶层 `dmz_eg4s20_hdmi_top.v:994` 例化**不 override** ⇒ 综合进的是错的那份。

**修法**（`rtl/audio/audio_src_mux.v:72-74`，三条必须**倒序**）：

```verilog
parameter [87:0] NAME_BGM   = {8'h56, 8'h41, 8'h57, 40'h20_20_20_20_20, 8'h4D, 8'h47, 8'h42},  // "BGM     WAV" 3+5+3
parameter [87:0] NAME_NARR  = {8'h56, 8'h41, 8'h57, 32'h20_20_20_20,    8'h52, 8'h52, 8'h41, 8'h4E},  // "NARR    WAV" 4+4+3
parameter [87:0] NAME_ALARM = {8'h56, 8'h41, 8'h57, 24'h20_20_20,       8'h4D, 8'h52, 8'h41, 8'h4C, 8'h41}  // "ALARM   WAV" 5+3+3
```

`:30-71` 加了 42 行注释，含三条警告：「⚠ 下一个人请不要改回正序」「三个名字空格数 5/4/3 各不相同，第一版修复稿照抄 5 个空格拼出 12/13 字节被静默截断」「tb 用 parameter override 所以测不出默认值错误」。

**次因（R3）**：`rtl/audio/wav_stream_player.v:462-465` 的 16bit→24bit **只做符号扩展、没左移 8 位** ⇒ WAV 比提示音低 **48.16 dB**。改为 `{{8{fifo_q[15]}}, fifo_q[15:0], 8'h00}`（`sample_l`/`sample_r`/`hold_l`/`hold_r` 四处）。

**次因（R4）**：顶层 `HDMI_AUDIO_ATTEN_SHIFT` 原为 6（−36.12 dB），叠加 `vol_apply` 档 6（23/32 = −2.87 dB）后 **−38.99 dB**；再叠 R3 就是 **−102.45 dBFS**。改为 **2**（−12.04 dB）。注释 `:1108-1116` 写明「为什么不是 0」：加密 IP 无法从源码确认满幅容忍度，改 0 等于用未知削波风险换响度；取 2 留 4 倍余量。

**可观测性（T2）**：顶层原来 `.err_code()` / `.fifo_level()` 全是空连接，上板完全看不到 WAV 为何失败。现在接出 `wav_bad`/`wav_err` → `err_prompt.v:421` 新增分支，九档子码。

### ① 全程没有音频可视化

**根因（R5，独立缺陷）**：`rtl/video/audio_waveform.v` 的 `hist[0] <= audio_sample[23:8]`（预丢低 8 位）+ `Y_SHIFT = 10`。

**注意**：诊断报告原本把这里归因为「256× 额外衰减」，**这个归因是错的** —— `(s>>>8)>>>10` 与 `s>>>18` 数学恒等（算术右移组合律），t6 用 `tb_wave_ab.v` 同输入喂新旧 DUT 逐像素比对证明完全一致。**波形看不见的真正来源是 R3（位深未左对齐）**：F3 若回退，F4 再好也是一条直线。

**修法**：`hist` 改 `reg signed [23:0]`、`Y_SHIFT = 18`、`hist[0] <= audio_sample`（全 24bit）、中间量全部 24bit。

**`Y_SHIFT = 18` 不是 17**：窗口半高 ±32 行，24bit 满幅 ±8388607 `>>>18` = ±32 正好填满 `y∈[376,439]`；`>>>17` 得 ±64 会画出窗口外被 `in_window` 裁掉。

F4 的真正价值不是「让波形变大」，而是：①24bit 全精度入史不再预丢低 8 位 ②消除「上游必须已右移 8 位」的隐式耦合 ③参数语义变成「总位移 = Y_SHIFT」可被 tb 直接断言。

### ④ 应急模式有声但没有音频可视化

**与①是同一根因**，不单独修。

应急的「滴滴」声是 `rtl/audio/buzzer_tone.v` 由**本地振荡器合成**的，引脚 H11，**完全不经过** SD/WAV/vol_apply/HDMI/pcm_to_pwm 任何一环。所以它能响**从来不能证明音频通路是好的** —— 这是排查时最容易走错的一步。

### ② 日常模式图片像素位置偏移 + ⑤ 自适应缩放黑边

**这两个是同一个 bug。**

失效链：
1. `img_scaler` 只写自己居中窗口内的像素，窗口外**不写**（文件头 §六-3 明说「必须由顶层按 `out_w/out_h/out_off_x/out_off_y` 屏蔽」）；
2. 全设计**没有任何清帧缓存为黑的逻辑** ⇒ 窗口外永远是上一帧内容；
3. `image_window_mask` 本该屏蔽，但 t7-B 把窗口源从 `img_scaler.out_*` 换成 `ratio_map.k9_win_*`，而 `out_*` 在顶层 `:641` 变成**四端口空连接**；
4. 默认 Key9 = 满屏 ⇒ `in_window` 恒真 ⇒ 什么都不屏蔽 ⇒ 四周露旧帧残影（视觉上既像偏移又像一堆黑边）。

**修法一**：`rtl/video/image_window_mask.v`（43→72 行）新增 `img_w/img_h/img_off_x/img_off_y` 四个端口，改成**交集**：

```verilog
assign pixel_valid_out = de && pixel_valid && in_window && in_image;
```

两个半开区间，**上界一律用加法**（`img_x_end = {1'b0,img_off_x}+{1'b0,img_w}`）——用减法时 `win_w=0` 会回绕成 `off-1`，反而把一整片判成窗口内。`img_w=0` 表示「还没提交过任何帧」，此时 `in_image` 恒假、画面保持黑色。

**修法二**：顶层 `:719-720` 把 `out_*` 接回，`:843-844` 接上 `img_*`；**`win_*` 仍接 `k9_win_*` 不动**（这是补回职责，不是回退 t7-B —— 回退会让 Key9 五档全失效）。`scripts/check_key9_shared.py` PASS 10/10 证明 K6/K7/K10 未被破坏。

**修法三（我独立发现的隐藏 bug）**：`rtl/storage/image_player.v` 的 `display_*` 原本有**三处**赋值点，**fade 分支一处都没有**。而 `FADE_ON` 在出货配置恒为 1（`:32 parameter FADE_EN = 1`、`:33 FADE_FRAMES = 8` ⇒ `:109 localparam FADE_ON = FADE_EN && (FADE_FRAMES > 1)`），`ext_no_fade = rle_play_en` ⇒ **科普走硬切（会更新）、日常走 fade（永远停在首帧）**。6 张素材全 640×480 掩盖了它；一旦 mask 真正参与裁剪且换成 RES400/512/576，就会**只错日常模式**。

现在加了 `:203-206` 四路选择器 `disp_w_sel/h_sel/x_sel/y_sel = ext_wr_mode ? FRAME_W16/FRAME_H16/16'd0/16'd0 : scale_w/...`，`display_*` **四处**赋值点（`:276-279` 复位 / `:312-315` 首帧 / `:328-331` 消隐硬切 / `:354-357` fade）全部统一取 `disp_*_sel`。

**修法四（让测试不再说谎）**：`tb_image_player.v:134-138` 与 `tb_display_content.v:68-72` 原本接的是旧线 `out_*` —— **它们在验证出货配置里根本不存在的电路**，这就是「仿真全绿、上板有黑边」的直接原因。已改成 `img_*`。

> ⚠️ `img_scaler` 的 **8 像素对齐一处未动**（`:188 {src_w_r[15:3],3'b000}` / `:189 & 16'hFFF8` / `:284` / `:406`）。**禁止改成 16 像素对齐** —— 那会把 `out_off_x` 的量化误差上限从 7 放大到 15 像素，恰好加重「像素偏移」。只改了 `:75-77` 的注释（偶数 → 8 的倍数）。

### ③ 科普模式与日常模式唯一区别是多一条蓝条

**这不是一个缺陷，是两个互相独立的致命缺陷。**

蓝条本身是 `rtl/video/video_overlay.v:173-175` 的 `px_sci`（顶部 8 像素通栏 + 左上 24×24 方块 = "L" 形，色 `24'h00_C8_E0`），**设计目的就是「任何画面内容下都可见」的模式指示灯** —— 它不会消失，也不是 bug。真正的两个缺陷是：

**缺陷 A（视频通路全断）**：`rtl/storage/rle_decoder.v` 的 `R_NEXT_BLK` 状态里，`:689` 的 `if (blk_done) begin ... end` 是**与请求分支并列的第二个独立 if，完全没有 `req_sent` 门控**。

而顶层 `sd_blk_done` 在 `:455/:460/:469/:518/:634/:921` **六处直连各消费者，无 owner 门控**。`rle_decoder` 是五个 SD 消费者里**唯一不做归属门控的**（对照 `rtl/audio/wav_stream_player.v:210` 的 `reg my_blk_active`，那是本工程已有的范式）。

仲裁是 `sd_owner_wav = ... && wav_want_blk; sd_owner_rle = ... && !wav_want_blk && rle_want_blk;` ⇒ **WAV 绝对优先**，RLE 停车等 grant 的窗口必然存在，别人的 `blk_done` 一到就被误判成自己的块。

**修法**：`:705` `if (req_sent && blk_done)`、`:712` `else if (req_sent && blk_err)`，分支体逐字未改。

> ⚠️ **顶层 `:496-502` 原本的风险登记写错了**：原文说「科普模式下 WAV 仍在播 BGM，所以 wav 抢总线只是理论窗口」。但 `rtl/audio/audio_src_mux.v:70` 是 `MODE_SCIENCE: sel_c = SRC_NARR` —— 科普下播的是 **NARR.WAV**（126.106 s、loop=0），比 BGM 更短、抢总线更频繁。**正是这条错误前提把 P0 低估成了「理论窗口」**。该段已整段改写。

**缺陷 B（字幕被单拍脉冲门控）**：顶层原 `wire narr_on = m_science && rle_frame_ready && narr_frame_ok;`，而 `rle_frame_ready` 在 `rtl/storage/image_player.v:74` 的端口注释就写着「**单拍**：本帧已提交（vblank 翻页完成）」。

⇒ `narr_on` 占空比约 **2e-7**，且那个拍落在 `de=0` 的消隐期。**即使视频修好，中文字幕也不会出现。**

**修法**：`image_player.v` 新增 `ext_ever_framed` 粘滞电平位（端口 `:82`、reg `:213`、复位 `:285`、清零 `:293 if (!ext_wr_mode)`、三处置位 `:322`/`:334`/`:361` 与 `ext_frame_ready_r` 严格同拍、`assign :632`）；顶层 `:1185` 改为 `wire narr_on = m_science && rle_ever_framed && narr_frame_ok;`（保留 `frame_idx >= 4` 与 `<= 624` 两条约束）。

**为什么失败完全静默**：`err_prompt.v` 原本端口只有 `sd_*`/`gallery_*`/`image_*`，**没有任何 rle_* 输入**；`rle_err_code`/`rle_underrun` 在顶层只声明、只接输出、**零消费者**。图库正常时数码管显示 `playback_state`（科普=4 PLAY），看起来一切正常。

**修法（P1-a，比修 bug 本身更重要）**：`err_prompt.v` 新增 `rle_bad`/`rle_err`，三档合成（`rle_err_code!=0` / `rle_meta_fault` / `rle_absent`），子码 1→bE、2→dE、3→d0、4→d1、5→d5、6→d6、default→d9。

### ⑥ OSD 字幕下方的黑条

**不是字幕衬底**（`osd_caption.v` 的 y=448..463 压暗带），是 `rtl/video/video_overlay.v:213` 的 `px_info` —— **y=464..479 全宽 640、固定 `24'h10_18_20`、亮度 6.3%**，因为顶层 `:165` `info_en = 1'b1` 硬接，所以常驻不可关。

**为什么用户会把它读成「字幕下方的黑条」**：字幕带 448..463 与信息条 464..479 **严格相接、0 行间隙**，合计 32 行 = 屏幕最底部 1/15。

**为什么只有 Key9 第 5 档才看得见**：`ratio_map` 档 0..3 的窗口底边是 359/389/419/449 ⇒ y≥450 本来就纯黑，只有 100% 全屏时才露出来。这与用户说「全屏看的时候最碍事」吻合。

**修法**（`:233-234`，唯一功能行）：

```verilog
wire px_info = info_en && (active_y >= 10'd468) && (active_y <= 10'd475) && (active_x >= 11'd8) && (active_x <= 11'd103);
```

黑面积 10240 → 768 px（**−92.5%**），距字幕留 4 行间隙。

> ⚠️ **实施边界（最容易踩的坑）**：`rgb_mixed` 里 `px_info`(`:313`) 的优先级**高于** `px_caption`(`:314`)。y 下界若误写 <464（比如 460），`0x10_18_20` 会直接盖掉字幕笔画 ⇒ **字幕整个消失**，而不是「多一圈暗底」。**468 是必须 ≥464 的安全下界。**

**为什么不直接把 `info_en` 接 0**：12 格是**双态编码** —— 亮 = 青 `0x40E0D0`、灭 = **露出 `px_info` 的暗底**。删掉暗底后灭格变成图像色，图像比 0x40E0D0 亮时 0/1 无法区分 ⇒ 信息条失效。而它是赛规 E4「参数变化信息呈现」的载体。

**为什么不删字幕衬底带**：它是图像 ×1/4（不是纯黑），保留画面明暗层次；去掉后 `0xF0F0F0` 白字在亮画面上对比度 ≈ 1:1 不可读。

**附带收益（我没预见到的）**：收窄后 `px_info` 的几何与 `px_box_win` 完全一致，于是 `:241` 改成 `wire px_box_win = px_info;`，**省掉 4 个比较器 + 3 个与门**。

---

## 3. TD 为什么失败两次（这段最值得记住）

第 1 轮 TD 从 elaborate 重跑两次全流程，**两次都在 route 阶段 `FAIL-route`（exit 9）**，bitgen 从未执行。

**但 setup 不是瓶颈**。run2 的 route 内部已经把 setup 优化到 **`Setup: WNS(ns) = 0.124, TNS(ns) = 0.000, FEP = 0 | Hold: WNS(ns) = -0.012, TNS(ns) = -0.045, FEP = 7`** —— **比基线 +0.113 还好，0 setup 违例**。

随后进 `Stage 3 | Hold Fix`，为 7 个 hold 违例各插 1 buffer（共 8 个），炸在：

```
PHY-8023 ERROR: Location: (x27y35_e2beg3), nets: u_rle/ramread0_syn_103 rst_n_dup_53
PHY-8023 ERROR: Location: (x29y35_local0), nets: u_rle/ramread0_syn_119 rst_n_dup_53_holdbuf0
RUN-8102 ERROR: Incremental route failed. Please check if the resources used in your design exceed...
```

**关键在第二行**：`rst_n_dup_53_holdbuf0` 是**刚刚为修 hold 插入的新节点**，它的下一跳立刻和另一根网抢同一物理位置。

⇒ **不是时序预算不够，是 89% slice 占用下增量布线无路可走。**

两次失败分别落在 `rst_n_dup_34` 和 `rst_n_dup_53` 两根**不同**的网上 —— 换 seed 只是换个死结位置。

**走过的弯路（都要记住）**：

1. **`route fix_hold on` 是 no-op，不要试**。`run2` 日志里 `INFO-T7B3-EXTRA=` 为空却照样出现 `PHY-1001 : Stage 3 | Hold Fix` ⇒ **`fix_hold` 默认值就是 `on`**。官方 `DefaultFlow.tcl:192-201` 的写法是 `set_param route fix_hold off` → `route` → `fix_hold` → `set_param route fix_hold on`，**`on` 是「恢复默认」不是「开启特性」**。

2. **「先疏松布局」被证伪**。路线1 `place enable_congestion_recovery on place enhanced_gp on` 反而恶化：`#slices` 8,768→8,843 = 90.23%、H-EP 11→16、Hold TNS −121→−176。

3. **最终有效的是路线2**：`place hfn_opt_effort high place crit_path_opt on` → TD EXIT 0，238.9 s，全流程 PASS。机理是它把 hold fix 从 8 条降到 4 条，**且 0 条命中 `rst_n_dup_*`**（全落在 HDMI core 内部 FIFO 数据网 + player loader 局部复位）。

4. **不要给 `rst_n` 加 `set_false_path`**。那是把问题移出视野而不是修复。SDC 文件头 `:76-80` 记录了历史立场：「同一 PLL 的 0°/180° 有确定相位关系，不得声明为异步组，历史 bring-up 曾用拆组得到过『+0.104 ns / 0 违例』的假绿」。

**复用 `gate.db` 的合法通道**：`project/t10_r2_flow.tcl`（275 行）可以从 gate.db 起跑 place/route/bitgen，省约 125 s。但它有**硬断言**：

- 前提成立 → 打印 `PASS-T7B3_gatedb_fresh`；
- 前提不成立（gate.db 比 `rtl/*.v` 旧）→ `FAIL-T7B3_GATEDB_STALE` + `exit 32`，**拒绝产出位流**。

设计理由：本工程踩过两次「验证了出货配置里不存在的电路」，共同点是「跑起来全绿、结果无效」。**硬编码路径不构成一次性脚本；真正决定可复用性的是它会不会在前提不成立时静默出错。**

---

## 4. 时序与资源：现在的真实情况

| 项 | 基线（11-03 00:31） | 本轮（11-03 23:35） |
|---|---|---|
| Setup WNS | +113 ps | **+109 ps** |
| Hold WNS | +11 ps | **+19 ps** |
| TNS / 违例端点 | 0 / 0 | 0 / 0 |
| `#lut` | 16,414（83.74%） | **16,868（86.06%）** |
| `#reg` | 8,441（43.07%） | **8,709（44.43%）** |
| `#bram` | 37 | **37** ✅ |
| `#slices` | 8,591（87.66%） | **8,778（89.57%）** |
| Wire length | 1,664,088 | 1,801,952 |

**最差路径换了入口，但没换性质**：

- 基线：`u_axis/rgb[13]_syn_5126`（功能上是 `emerg_page` 的 `active_x[5]` 副本）→ `u_axis/video_data_reg[5]`，39.535 ns，**36 级**，net 64%，Max Fanout 88。
- 本轮：`u_overlay/u_caption/u_narr/addr[9]` → `u_axis/video_data_reg[22]`，39.611 ns，**32 级**，net **69%**，Max Fanout **145**。

**`osd_strings.v` / `narr_subline.v` / `osd_caption.v` 本轮全部未改动**（git status 干净、mtime 都是 11-02 22:27:32）⇒ **最差路径与 t9 无因果关系**，只是布线拓扑重排。

最贵的一段是 `u_strings/col[2]_syn_dup_1197`，**单根网 2.632 ns（占整条 39.611 ns 的 6.6%）**，扇出 145 —— 来自 `osd_strings.v` 那 465 行 `case ({line_sel, col})` 大查表。

**反常但自洽**：逻辑级数**少 4 级**（36→32），slack 反而**差 4 ps**。再次印证「吃余量的是布线不是逻辑深度」。**将来要提升时序，该动 `osd_strings` 的扇出，不是插流水线。**

**三条不能说的话**：
- ❌ 不能说「时序比基线好」——+113→+109 是**不同 TD 参数**下的数字，不能解读为「RTL 让时序变差 4 ps」。
- ❌ 不能说「面积增量全归因于 RTL」——两轮 `hfn_opt_effort` 参数不同（默认 `medium` vs `high`）。
- ❌ 不能说「`u_axis` +233 LUT 有出处」——那是 gate 阶段报告的数字，其中 +233 落在本轮**未修改**的 `u_axis` 上，属工具映射噪声。⚠️ **不要拿 gate 阶段报告去减 route 阶段报告**（会得到 2384→2479=+95 这种跨阶段混减），两份报告的列数也不同（7 列 vs 8 列），**不能按位置相减**。

---

## 5. 回归：911,909 断言

| 套件 | ran/passed | 断言数 | 耗时 |
|---|---|---|---|
| unit | 29 / 29 | 1,240 | 337 s |
| frontend | 21 / 21 | 56,457 | 106 s |
| storage | 4 / 4 | 226,360 | 6 s |
| audio | 2 / 2 | 24 | 158 s |
| startup | 19 PASS 行 | 19 | 2 s |
| display | 1 / 1 | 614,406 | 85 s |
| image | 3 / 3 | 13,403 | 57 s |
| **合计** | **7 / 7 套** | **911,909** | **752 s** |

> ⚠️ **这是两段证据拼接，不要说成「一次跑完七套」**：第 1 轮 22:10–22:22 跑七套（当时 storage 4/4、image 3/3），第 2 轮 23:21–23:23 补跑 storage 5/5、image 4/4（因为把两个孤儿 TB 加进了套件）。11 个 `.v` + 9 个 tb 的 MD5 与第 1 轮逐一比对 **diff=0/20 IDENTICAL**，所以复用合法。

**修掉的覆盖缺口**：`tb_rle_decoder`（72 checks，t9 核心）和 `tb_image_window_mask`（52 checks，t7 核心）原本**不在任何回归套件里**，已补进 `run_storage_regression.ps1` 与 `run_image_regression.ps1`。

**变异验证（证明断言不是写空的）**：三个变异全部 KILLED —— m1「fade 分支四行注释掉」→ errors=6、m2「`disp_*_sel` 恒取 `scale_*`」→ errors=10、m3「`in_image` 恒 1」→ errors=14。

> **m1 第一轮没被杀死（11376 全绿）**，因为当时所有用例的源图尺寸都等于容器尺寸 —— **与上板「6 张素材全 640×480」是同构掩盖**。CASE16 就是为杀它补的。这个教训值得反复看：**测试用例的尺寸分布如果和真实素材一样单一，测试就会和现场一样瞎。**

---

## 6. 上板时必须先做的事

### 6.1 SD 卡（否则一切无效）

**必须按 `assets/v2/sdcard/BURN640/` 装配**（17 个文件），把**内容平铺**到 FAT32 卡根目录。

`RES640/` 只有 6 张 BMP，**零音频、零视频** —— 只拷它就会缺 10 个文件（`ALARM.WAV`/`BGM.WAV`/`BGM2.WAV`/`BGM3.WAV`/`NARR.IDX`/`NARR.SRT`/`NARR.WAV`/`SCI.IDX`/`SCI.RLE`/`TICKER.TXT`），结果是科普显示 `d6`、音频进 `ST_FAIL` **完全静音连三角波兜底音都没有**。

三条硬约束：**仅 FAT32**（FAT16 会被判 BPB 非法，错误码 2）/ **平铺根目录不递归** / **8.3 短名全大写**。

快速自查：根目录 17 个文件，`IMG001.BMP` = **921,654 B**，`SCI.RLE` = **82,362,927 B**。

### 6.2 烧哪个位流

**`AA65465E3F41E16C49E5EAE13D0EEC38`**（23:35:55）。

烧 `59A6BACC…`（00:31:47）就是**修复前**的位流，[上板检查表](../reports/board_check_20261103.md) 里的所有判据都不适用。

### 6.3 验证顺序（按风险排）

1. **3.5mm 耳机口** —— 判 F1+F3，**不受 HDMI 衰减影响**。这是隔离「音频通路是否活了」的唯一干净办法。
2. **HDMI** —— 判 F5。若破音/削波，把 `HDMI_AUDIO_ATTEN_SHIFT` 从 2 调回 3 或 4。
3. **日常默认档** —— 判②⑤。看四边是否还露上一张图残影；OSD 第 1 行应为 `B:0 V:6 R:4 P:4`（第 10 列 = R(Key8)、第 14 列 = P(Key9)）。
4. **科普模式** —— 判③。**判据是「画面必须是变的」**，不是「有画面」。蓝条会一直在，那是模式指示灯。
5. **OSD 字幕** —— 判③⑥。字幕带正下方不再有通栏深色底；左下角仍有 12 个方块（亮 = 青绿 0x40E0D0、灭 = 深蓝黑 0x101820）。
6. **应急模式** —— 判④。可视化应当出现（与①同根因）。

**然后连续跑 10 分钟以上** —— 这是**唯一能暴露 113 ps 零余量的测试**。升温后错误率上升 = 时序余量问题；现象完全不变 = 逻辑 bug，别在时序上浪费时间。

---

## 7. 已知未修 / 不能声称

### 未修（已记录，不是遗漏）

| 项 | 位置 | 影响 | 为什么这次不修 |
|---|---|---|---|
| `gap_tick` 撞车 | `rtl/storage/rle_decoder.v:497` `R_IDLE: if (gap_tick && !blk_busy)` | `gap_tick` 是**单周期脉冲**，撞上 WAV 块事务就整帧滑后 200 ms ⇒ 约 6% 帧抖动、帧率降到约 4.7 fps | `R_IDLE` 是所有帧的起点，改错风险高。建议单独立项：tick 锁存 pending + 等 `!blk_busy` 起帧 |
| `R_ERR` 不自愈 | `rle_decoder.v` | 出错后需重启 | 现在至少**可见**了（P1-a 已做） |
| `ST_FAIL` 静音死锁 | `audio_tone_gen.v:142` `silent = mute \|\| (playback_state == ST_IDLE) \|\| (playback_state == ST_FAIL)` | `sd_fail`/`gallery_fail`/`image_failed` 任一为 1 ⇒ 钉在 `ST_FAIL` ⇒ **连三角波兜底音都被掐掉** | F1 修好后 WAV 能正常播，用户不会再停 `ST_FAIL`；且 `ST_FAIL` 时数码管本就有错误码 |
| 音频串联无 tb | 全仓 | 没有任何 tb 把 `audio_src_mux` 与 `wav_stream_player` 串起来 | 顶层接线已核实正确（`:997 .src_name` → `:1025 .target_name`），且 `tb_wav_stream_player.v` 已有完整假 FAT32 镜像，补起来成本低 |
| `docs/plan_v2` 曾有漂移 | `KEYMAP.md` §2.1 | 计划把 Key0/Key1 消费者命名为 `media_player.v`，实现落在 `player_ctrl.v` | 功能与键号一致，仅文件名不同。已在本轮 commit 信息里记录 |

### 不能声称

1. **不能说 6 项全解决** —— 你说的②里如果有「画质不佳」（色带、渐变不连续），那是**另一回事**：整条通路是 **RGB565 16bit**（色阶只有 R32/G64/B32），六项修复都没覆盖它。需要你确认这个现象具体是什么样。
2. **不能说「已证明正确」** —— 只能说「可以上板试」。
3. **不能说时序/面积完全归因** —— 见 §4 三条。
4. **不能说 I2C 已验证** —— `dmz_eg4s20_hdmi.sdc:118-121` 四条 `set_false_path`，**SWNS 对 I2C 物理可靠性零证据**。AHT20 读数偶发错不要去查 WNS，去查上拉电阻/飞线/干扰源。
5. **不能说顶层被仿真覆盖** —— 全仓**没有任何 tb 例化顶层**（`tb_dmz_eg4s20_min_top.v:11` 注释解释：含 HDMI 加密核，ASE 下 vlog 挂死）。所以 `HDMI_AUDIO_ATTEN_SHIFT = 2` 这层只能靠试听判断，**这是审查列出的头号上板风险**。

### 头号风险：`HDMI_AUDIO_ATTEN_SHIFT = 2`

失效形态是**削顶/破音**，不是「没声音」—— 最难定位。

判据链：全仓无 tb 例化顶层 → 加密 IP 满幅容忍度未知 → 历史已错一次（原值 6 造成串联 −87 dB）→ 现在取 2 留 4 倍（+12 dB）余量。

**上板若音量偏小 → 降到 1 或 0；若削波 → 往上加。** 注释 `:1108-1116` 已写明这个调法。

---

## 8. 环境与操作约定（踩过的坑）

1. **本环境没有 `pwsh` 命令**，必须用当前 shell 直接调脚本（`& ".\scripts\sync_src.ps1"`）。
2. **`cd` 后相对路径会错误解析到 `D:\FPGA_Compelate`**，一律用绝对路径。`git` 需先 `Push-Location $proj`。
3. **读源码必须显式 UTF-8**：本项目 `.v` 含大量中文注释，PowerShell 5.1 的 `Get-Content` **默认按 GBK 解码**，`rtl/top/dmz_eg4s20_hdmi_top.v`（1454 行）会被读成 **909 行**。用 `Get-Content -Encoding UTF8` 或 `[System.IO.File]::ReadAllLines`。`Select-String` 的行号是对的。
4. **写 `.ps1` 必须保留 BOM**：`scripts/run_tb_baseline.ps1` 曾因我改它时丢了 3 字节 BOM，PS 5.1 按 GBK 解析中文注释导致 **parseErrors=4**（`line 22/44 Missing ')' in function parameter list.`、`line 197 The string is missing the terminator`）。用 Python `utf-8-sig` 读写。
5. **禁用 PowerShell `Set-Content`** 写源码/文档（本工程已毁过三次文件）。用 Python 显式 `encoding="utf-8", newline="\n"`，写完回读断言 BOM 与 CRLF 计数。
6. **`sync_src.ps1` 输出「同步完成: 0/71 个副本被更新」是计数显示 bug**，文件实际同步了 —— 以 MD5 为准。
7. **`lint_verilog.py rtl project` 会扫 445 文件并报错**（因 `project/t2_*` 历史探针目录）。正确口径是 `lint_verilog.py rtl project/src project/hdmi`（133 文件全 0）。
8. **TD 不要用 `[file join]` 拼路径给 `open_project`**（报 `PRJ-8601`），用 `$prjdir/name` 正斜杠。
9. **TD 不校验参数名**（`PRJ-1106 : Update wild param ... succeed` 什么都接受），**「PASS-set_param」不能作为生效证据**，必须看产物是否变化。
10. **单趟 TD 全流程约 587 s**（optimize_rtl 89 + optimize_gate 124 + place 104 + route 250 + 20），必须后台跑或 `timeoutMs` 设到 1,800,000。

---

## 9. 临时目录（已清 / 保留）

**已删**（138.6 MB + 12.8 MB）：
- `D:\FPGA_Compelate\_diag_audio`、`_t6_sim`、`_review_t11_rl`、`_review_t11_ip`/`_m1`/`_m2`、`_t10_rle_cwdtest`
- `D:\FPGA_Compelate\v2base.git`（**119.79 MB**，是当初沙箱不能写 `.git` 时的镜像，已无必要）
- `SmartCampusMedia\build_t7`（14.86 MB，已加进 `.gitignore` 的 `build_t*/`）

**刻意保留**（报告里明确引用了这些路径，删了会断链）：
- `D:\FPGA_Compelate\_t10_regression_20261103`（67.3 MB，第 1 轮两次 FAIL 的完整日志与 db）
- `D:\FPGA_Compelate\_t10_round2_coverage`（4.2 MB）
- `D:\FPGA_Compelate\_t5_rle_check`（3.47 MB，`diag_science_20261103.md:204/317` 引用）

**工作区根目录还留着一批更早的临时目录**（`_t3_verify`/`_t4_verify`/`_probe_fw`/`_crop`/`work`/`gp_work` 等，共约 300 MB），都是本轮之前产生的，未动。

---

## 10. 文档地图

| 想了解 | 看 |
|---|---|
| 项目总纲、硬性约束、开发原则 | [ai_handover.md](ai_handover.md) |
| 六个问题的**上板判据**（每问给「修好了/没修好」双列） | [board_check_20261103.md](../reports/board_check_20261103.md) |
| 六项修复的**实施细节与证据** | [fix_audio](../reports/fix_audio_20261103.md) / [t7_impl](../reports/t7_impl_20261103.md) / [fix_science](../reports/fix_science_20261103.md) |
| 四项诊断的**根因分析** | [diag_audio](../reports/diag_audio_20261103.md) / [diag_video](../reports/diag_video_20261103.md) / [diag_osd](../reports/diag_osd_20261103.md) / [diag_science](../reports/diag_science_20261103.md) |
| **独立审查**（73 项核对、变异复现、风险排序、不能声称清单） | [review_20261103.md](../reports/review_20261103.md) |
| **回归与综合证据**（逐套数字、TD 四趟、§10.7 能证明/不能证明） | [verify_build_20261103.md](../reports/verify_build_20261103.md) |
| TD 布线失败的机理分析 | [td_route_fail_analysis_20261103.md](../reports/td_route_fail_analysis_20261103.md) |
| v2 架构书 / 计划书 / 键位表 | [docs/plan_v2/](plan_v2/)（本轮刚补进来，此前全部缺失） |
| 上板风险总图（113 ps 那条路径的完整分析） | [reports/plan_v2/ONBOARD_RISK_MAP.md](../reports/plan_v2/ONBOARD_RISK_MAP.md) |

---

## 11. 接手后建议的第一步

1. 烧 `AA65465E…`，按 [board_check_20261103.md](../reports/board_check_20261103.md) 走完 §0（SD 卡自查）→ §1（开机 0~5s）→ §2（六问逐条）。
2. 把实测结果**回填到该检查表的双列判据里**，标注「上板实测」—— 这是审查给出的前置条件 C4。
3. 如果某一项没修好，先看 [review_20261103.md](../reports/review_20261103.md) §5 的上板顺序（它按「能否隔离变量」排过），再看对应诊断报告的「不确定项」章节。
4. 如果连续运行 10 分钟后才开始出错 → 走 [td_route_fail_analysis_20261103.md](../reports/td_route_fail_analysis_20261103.md) §三 的路线 2（扫 seed），**不要动 RTL**。
5. 只有常温下稳定复现错色/错位，才回到模块级定位。
