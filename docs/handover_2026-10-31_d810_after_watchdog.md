# 上板复测：`d810` 仍在，图片通路未出图（2026-10-31）

> 交接对象：下一个接手修改的 AI / 开发者。
> 本文只记录**板上实测现象**与**由此可推出的结论**，不改写任何历史记录。
> 前一版相关记录：`docs/handover_2026-10-28_display_diagnosis.md`（显示数据修复）、
> `docs/progress.md` 第 2454 行（`d810` 首次定案）、`docs/noise_root_cause_2026-10-30.md`（切图白条）。

---

## 一、实测现象（2026-10-31 16:09，肉眼 + 照片）

| 观测点 | 结果 | 含义 |
| --- | --- | --- |
| 屏幕 | 8 色彩条铺满 + 字幕叠加可见 | 视频时序、HDMI、OSD 全部正常；但**图像通路没出图** |
| 字幕 | `SMART CAMPUS` / `FAIL` / 底部滚动 `SMART CAMPUS MEDIA CENTER -- WELCOME -- ONLINE NOW` / 右上 `IMG 0…` | **B1 字幕系统首次在实板确认工作**（此前只有仿真证据） |
| LED | 只有 **D4 / D5 / D7** 亮，其余全灭 | 见下表逐位解读 |
| 数码管 | **`d810`** | `d`=数据通路类、`8`=子码、`1`=图号、`0`=测试图序号 |

LED 逐位（映射见 `rtl/top/dmz_eg4s20_hdmi_top.v:427`
`assign led = {err_active, image_loading, sdram_lock_pix[1], hdmi/video lock, 应急, 读FIFO异常, 轮播, image_ready}`）：

| 位 | 名称 | 板上状态 | 说明 |
| --- | --- | --- | --- |
| LED7 | `err_active` | **亮** | 有错误提示在生效，与 `d810` 一致 |
| LED6 | 装载中 `image_loading` | 灭 | **已经不在装载态**——说明装载已失败退出（`C_FAIL`） |
| LED5 | SDRAM PLL 锁定 | **亮** | SDRAM 时钟正常 |
| LED4 | HDMI PLL + 核视频锁定 | **亮** | 视频链路正常 |
| LED3 | 应急模式 | 灭 | 不是应急态 |
| LED2 | 读 FIFO 异常 | 灭 | 仲裁器没报错 |
| LED1 | 自动轮播 | 灭 | 播放状态是 FAIL，没进轮播 |
| LED0 | 图片就绪 `image_ready` | 灭 | **前台没有一张完整帧**，所以 mux 一直在出测试彩条 |

补充：屏幕上**没有**那条"80 像素宽竖向白条"。但注意——`image_ever_ready` 从未置 1 时，
`video_content_mux` 本来就该整屏出彩条（`rtl/top/dmz_eg4s20_hdmi_top.v:153-156`、
`rtl/video/video_content_mux.v` 的 `image_ever_ready` 分支），
**因此这次复测不能作为"白条已修复"的证据**，只能说明没有出现不该出现的漏白。

---

## 二、这段时间里唯一的好消息

**`osd_caption` / `osd_font8x16` / `osd_strings` 在真实硬件上完整工作**：
标题行、状态行（`FAIL` 由 `playback_state` 驱动）、64 字符滚动标语、右上 `IMG` 序号，
四路文字的字符点阵、滚动位移、衬底压暗、y 带划分全部正确，没有错位、没有撕裂。

这意味着 B1（字幕）的验收口径可以从"仿真 + 综合布线"升级为"**已上板**"，
只剩 A 级里的图片通路没解决。修改代码时**不必再怀疑 OSD 与字幕通路**。

---

## 三、由 `d810` 推出的关键结论（这次最有价值的一条）

`d810` 拆开是：类别 `d` + 子码 `8` + 图号 `1` + 测试图 `0`。

按 `rtl/control/err_prompt.v` 的映射表，`d8` ← `image_failed` 且 `error_code == 9`；
而 `error_code = 9` 在 `rtl/storage/image_player.v:274-277` 的定义是：

```
error_code <= (arb_error_sync[1] || !sdr_online[1]) ? 4'd8 :
              (state == C_MEM)    ? 4'd11 :
              (state == C_COMMIT) ? 4'd12 : 4'd9;
```

也就是"既不是 SDRAM 错误、也不是 SDRAM 初始化超时、也不是写完成超时"的
**兜底 4 秒无进展**（`LOAD_TIMEOUT = 100_000_000` @25 MHz，`image_player.v:12`，
计时器每完成一个扇区被 `blk_done` 清零，`image_player.v:265`）。

### 3.1 为什么这个码本身就排除了半个故障面

如果故障是"块读请求已经发出，但 `sd_spi_ctrl` 不回 `blk_done`"，
那么 `img_loader` 自己的看门狗会先开火：
`BLK_TIMEOUT = 2_097_152`（≈84 ms @25 MHz，`img_loader.v:28`），
在 `T_FATRD`/`T_DATRD` 分别判在 `img_loader.v:301` 与 `img_loader.v:350`，
报 `E_BLKTMO = 4'd10` → 数码管应当是 **`dA`**，而不是 `d8`。

**板上出现的是 `d8` 而不是 `dA`，这是一条硬约束**：故障发生在
`img_loader` 还没进入"等块"状态之前，或者它压根没被启动。

### 3.2 于是嫌疑收敛到两处

**嫌疑 A：`img_loader` 卡在 `T_FATLOC`（等 `fat_found` / `fat_fail`），这一段没有任何看门狗。**

- `img_loader.v:216-230` 的 `T_FATLOC` 只判 `fat_found` / `fat_fail`，**没有任何超时分支**。
- 该阶段的块请求由 `fat32_reader` 发出（`blk_owner <= 1'b0`，`img_loader.v:168/199`；
  `assign blk_start = blk_owner ? blk_start_i : fr_blk_start;`，`img_loader.v:120`）。
- `blk_wait_cnt` 直到 `T_CHKSPC` 发出第一个自有请求时才被置 0 起算
  （`img_loader.v:252`、`img_loader.v:259`），所以**定位阶段天然不受 `BLK_TIMEOUT` 保护**。
- 一旦上游把 `fr_blk_start` 吞掉，`fat32_reader` 永远等不到 `blk_done`，
  `fat_found`/`fat_fail` 都不来，`img_loader` 静默挂死，最后由 `image_player` 的 4 秒兜底报 9。
  **与板上现象完全吻合。**

**嫌疑 B：`loader_start` 没到，`img_loader` 停在 `T_IDLE`。**

- 启动靠 `img_loader.v:200` 的 `start` 单拍信号（顶层 `image_player` 的 `C_START` 产生）。
- `T_IDLE` 里没有超时，`image_player` 在 `C_LOAD` 里只等 `loader_done`/`loader_fail`，
  同样没有任何 `blk_done` 会把计时器清零 → 4 秒后报 9。
- **症状与嫌疑 A 完全一致**，需要靠探针或波形才能区分。

### 3.3 上游为什么会"吞请求"——重点怀疑仲裁器的第三分支

`rtl/top/dmz_eg4s20_hdmi_top.v:124-127`：

```verilog
wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;
wire sd_owner_player  = sd_ok && !sd_owner_gallery;
wire sd_arb_start     = sd_owner_gallery ? gallery_start
                      : (sd_owner_player ? player_start : probe_start);
```

这个写法有一个**静默陷阱**：当 `sd_ok` 因为任何原因短暂为 0 时，
`sd_owner_gallery` 与 `sd_owner_player` 同时为 0，选择器落到**第三分支 `probe_start`**，
播放器的 `blk_start` 被整条丢弃——而 `image_player` 在 `C_LOAD` 期间**不会复查 `sd_ready`**
（只有 `C_WAIT` 和 `C_SHOW`/`C_FAIL` 复查，`image_player.v:213`、`image_player.v:248`）。
于是请求被吞、没有 `blk_done`、`img_loader` 停在 `T_FATLOC`、4 秒后 `d8`。

2026-10-28 那轮把 `.sd_ready` 从 `sd_ok` 改成 `sd_owner_player`（顶层 `:179`）
只解决了"启动那一刻"的交接（`tb_startup_ownership` 9 条断言覆盖的就是这件事），
**没有解决"装载途中 `sd_ok` 或所有权再次变化"**。这是本次与上次现象相同、
但成因可能不同的地方，必须分开验证。

---

## 四、接手后的验证顺序（建议按此顺序做，不要跳）

### 第 1 步：先用探针确认挂在哪一段（免上板，优先做）

在 `rtl/top/dmz_eg4s20_hdmi_top.v` 里临时例化已有的
`rtl/storage/image_path_probe.v`（observe-only，4 个粘滞观察点，输出 16 bit `stages`），
只接不改逻辑，观察：

1. `image_player` 的 `state` 是否进过 `C_LOAD`（进了 → 嫌疑 B 排除）；
2. `img_loader` 的 `st` 是否进过 `T_FATLOC`；
3. `fat_found` / `fat_fail` 是否曾经为 1（都为 0 → 确认卡在定位阶段）；
4. `sd_owner_player` 在装载期间是否掉过 0（掉了 → 命中 3.3 的仲裁陷阱）。

如果不想重新综合，最低成本的替代办法：把 `error_code` 挪到 DIG0 显示
（顶层 `:598-606` 现在是 `pattern_sel`），再把 `img_loader` 的 `st` 接到不用的 LED 位上
（LED3 应急位在非应急态空闲，可临时借用）。**记住这只是临时观测，别把临时改动提交进生产顶层。**

### 第 2 步：补两个看门狗（无论根因是 A 还是 B 都该补）

1. **`T_FATLOC` 超时**：给 `img_loader` 加一个定位阶段计时器，
   超过 `BLK_TIMEOUT` 量级就报新码（例如 `E_FATLMO = 4'd11`，注意与
   `image_player` 的 11/12 语义别撞车，`err_prompt.v` 里要有对应助记），
   让"定位阶段挂死"从 4 秒 `d8` 变成 84 ms 的独立可观测码。
2. **`C_LOAD` 期间复查 `sd_ready`**：`image_player.v` 的 `C_LOAD`
   增加 `if (!sd_ready) → 退回 C_WAIT（保留 pending）`，
   别让"总线被别人拿走"表现成"等一个永远不会来的 `blk_done`"。

### 第 3 步：修仲裁器的第三分支

`sd_arb_start` 的三目链应当显式处理"两个 owner 都不是"的情形，
不要让它默默落到 `probe_start`。可选做法：

- 播放器一旦进入 `C_LOAD` 就不再让出总线（给 `sd_owner_player` 加粘滞位），或
- 第三分支改成一个明确的 `1'b0` 并在同时拉高错误标志（让请求变"看得见的拒绝"而不是"静默丢弃"）。

### 第 4 步：补一条仿真回归，把这次的静默挂死变成硬失败

在 `sim/testbench/tb_image_player.v` 或新 TB 里构造：**`blk_start` 被上游吞掉**
（例如让 `blk_done` 永不返回），断言：

- 报错必须在 `BLK_TIMEOUT` 量级内出现（`dA` 一类），**不允许**熬到 `LOAD_TIMEOUT` 才报 9；
- `error_code` 必须能区分"块读超时"与"请求没被接受"。

现有 `tb_image_player` 的三档（8,270 / 8,263 / 1,228,817 条检查）跑的是正常通路，
**覆盖不到这个场景**——这正是 10-28 与 10-31 两次都在板上而不是在仿真里暴露的原因。

---

## 五、交接时必须知道的环境事实

- 本轮上板用的是 **2026-10-30 之后的新位流**，含 C2 缩放（`img_scaler`）、B2 转场（`fade_mixer`）、
  OSD 字幕、切图白条修复（`image_ever_ready`）、装载看门狗、启动交接修正。
  这些改动此前**从未在实板上验证过**——上一版确认能出图的位流是
  `reports/display_fix_20261029/hdmi_display_fix.bit`（2026-10-29 08:14），它早于上述全部改动。
- 因此本次故障**也可能是 10-29 → 10-30 之间引入的回归**，
  特别是 `img_scaler` 串进 `bmp_parser → img_loader` 之间后新增的握手段
  （`image_player.v:292-321` 的三个例化）。二分排查时，
  先把 `image_player` 里 `img_scaler` 旁路成直通（`src_*` 直连 `dst_*`）
  或在 `image_player` 参数里关掉缩放，看是否恢复出图，**这是最快的二分点**。
- 位流与证据目录：
  `reports/watchdog_20261030/smartcampus_media_watchdog_20261030.bit`（10-30 22:50，
  setup +1.935 ns / hold +0.003 ns），`reports/flashable_20261030/`（15:39，hold +0.011 ns）。
- 源码真源只有 `rtl/`、`constraints/`、`ip/config/`；`project/hdmi`、`project/src` 是脚本副本，
  改完必须跑 `scripts/sync_src.ps1`。

---

## 六、修改完成后的交付要求

1. `powershell -ExecutionPolicy Bypass -File scripts/sync_src.ps1`
2. `python scripts/lint_verilog.py rtl project/src project/hdmi` → E0/E1/E2 必须全 0
3. 至少跑通 `sim/scripts/run_image_regression.ps1 -FullVga` 与
   `run_unit_coverage_regression.ps1`，附通过标记与检查数
4. 重新综合并附布线后 **setup/hold WNS 与违例端点数为 0** 的输出
5. **上板复验**：屏幕上必须出现卡内图片（不是彩条），数码管回到无错误状态，
   LED0（`image_ready`）常亮；然后才可以在 README/TASKS 里把 A6 写成 ✅

### 明确禁止

- 不得以"仿真通过"或"综合布线通过"宣称本次问题已修复——本次故障的两次复现都在板上。
- 不得为了消灭 `d810` 而把 `err_prompt` 的映射改成其它码（那是掩盖观测，不是修复）。
- 不得删改 `docs/progress.md` 里 10-28 的定案记录；新结论请另起一篇并互相引用。
