# S7 前置切片：图库自动扫描（gallery_probe）

> 日期：2026-10-25
> 阶段归属：阶段五「基础播放系统」的前置缺口补齐（多图片切换的**张数来源**）。
> 交付状态：**仿真闭环通过，未上板**。SiP 时序违例与本轮无关、也未改善。

---

## 1. 本次完成内容

在此之前，顶层 `dmz_eg4s20_hdmi_top` 的图库张数是**编译参数**：

```verilog
parameter [4:0] GALLERY_COUNT = 5'd1   // 已配置的连续素材数，1..31；尚未自动扫描图库
```

SD 卡是现场插的，张数事先不知道。写死张数在演示现场有两种必然故障：

| 现场情况 | 写死参数的表现 |
|---|---|
| 卡里 3 张，参数 = 1 | 按「下一张」永远只在 IMG001 上打转，后两张看不到 |
| 卡里 1 张，参数 = 3 | 第二轮落到不存在的文件，装载失败并锁在错误态 |

本轮把张数变成**运行时可测的事实**：

1. 新增 `rtl/storage/gallery_probe.v`——SD 链路就绪后，从 `IMG001.BMP` 起逐个探测根目录，
   遇到第一个缺失即停，输出连续素材数 `count[4:0]`（0..31）。
2. 顶层删除 `parameter GALLERY_COUNT`；`player_ctrl.gallery_count` 改接扫描结果，
   `gallery_valid` 改接扫描完成标志。
3. SD 总线仲裁由「探针 / 播放链路」二选一，扩成「探针 → 扫描器 → 播放链路」**三段严格串行**。
4. 扫描完成时由扫描器发 1 拍 `first_img_req`，接进 `image_player.load_req`——
   这正是 `player_ctrl.v` 文件头【五】明确要求顶层补的那个「首图装载脉冲」。
5. 图库失败纳入既有故障呈现：LED[7] 点亮，数码管第 4 位显示 `3`，第 3 位显示扫描错误码。

---

## 2. 修改的文件

| 文件 | 变更 | 说明 |
|---|---|---|
| `rtl/storage/gallery_probe.v` | **新增**（248 行） | 图库自动扫描器 |
| `sim/testbench/tb_gallery_probe.v` | **新增** | 7 场景自检 TB，marker `ALL CHECKS PASSED: gallery_probe` |
| `rtl/top/dmz_eg4s20_hdmi_top.v` | 修改 | 删 `GALLERY_COUNT`；三段 SD 仲裁；首图脉冲；LED/数码管接入 |
| `scripts/sync_src.ps1` | 修改 | 新增 `gallery_probe.v → project\hdmi\gallery_probe.v` 映射 |
| `sim/scripts/run_frontend_regression.ps1` | 修改 | `$sources` 加两个文件，`$cases` 加 `gallery_probe` |
| `README.md` | 修改 | 「SD 卡素材与按键」一节改为运行时自动扫描 |
| `scripts/make_test_bmps.ps1` | 修改 | 去掉「改 GALLERY_COUNT 再综合」的过时提示 |
| `docs/progress.md` | 修改 | 阶段五条目更新 + 本轮说明 |
| `docs/ai_handover.md` | 修改 | 新增 2026-10-25 会话状态快照（置顶为最新基线） |
| `docs/s7_gallery_probe_2026-10-25.md` | **新增** | 本文件 |
| `project/hdmi/gallery_probe.v`、`project/hdmi/dmz_eg4s20_hdmi_top.v` | 同步副本 | 由 `sync_src.ps1` 生成，不手工编辑 |

`project/image_dm_fix/`、`project/image_path_diag/`、`project/image_readback_diag/` 下的诊断顶层
仍有自己的 `GALLERY_COUNT`——它们是**历史诊断快照**，不在同步映射表里，本轮不动。

---

## 3. 设计原理

### 3.1 为什么是「连续才计数」

播放控制用的是 0 基连续索引（`img_index` 0..count-1，转成 1 基 `loader_index` 交给 `img_loader`）。
若卡里零散放了 `IMG005` 而没有 `IMG002`，把它当成「第 5 张」会让「下一张」落到空文件上。
因此规则定为：**只有 IMG001、IMG002 … 从 1 开始不间断才被认可，遇到第一个缺口立即截断**。

`count = 0` 是**合法结果**（扫描完成但一张图都没有），与 `fail` 是两种不同终局：
前者代表卡是好的、只是没素材；后者代表卡或文件系统有问题。上层必须分开处理，
`player_ctrl` 内部已有 `gallery_ok = gallery_valid && (gallery_count != 5'd0)` 这个区分。

### 3.2 为什么每轮都复位子模块，而不是改 `fat32_reader`

`rtl/storage/fat32_reader.v` 是**一次性定位器**：状态机终态 `S_DONE` / `S_FAIL` 只保持
`found` / `fail`，**没有回到 `S_IDLE` 的路径**（见该文件块①）。要连测 N 个文件名，
只有两条路：

| 方案 | 代价 |
|---|---|
| 改 `fat32_reader`，给它加「start 可从终态返回」 | 它是 S3 已验证模块，改动会牵动 `tb_fat32_reader` 的 21 个场景，需重跑全套 |
| **本模块给它一次性局部复位** `f32_rst_n = rst_n && !rst_req` | fat32_reader 零改动；代价是每轮重读 MBR+VBR+目录 |

选后者。25 MHz 下 31 张图约几十毫秒，相对上电流程可忽略；换来的是零跨轮状态、
任何一轮出错都不污染下一轮。

复位时序是 6 拍：前 4 拍保持低电平，第 5 拍释放，第 6 拍才发 `start`。
多等这一拍不是保守，是必要的——异步复位释放需经时钟沿采样，
「复位一释放就发 start」会被吞掉（`sd_probe` 在 POWERUP 期踩过同类坑）。

### 3.3 为什么 err=4 是正常终止

`fat32_reader` 把「目录遍历到结束标记都没找到」归为 `err_code = 4`。
在图库枚举的语境里，这恰好就是「连续区间到此结束」。
其余错误码（1=MBR 签名错、2=BPB 非法、3=簇链异常、5=底层读块失败、6=序号为 0）都是**真故障**，
必须进入 `fail` 终态并透传错误码，不能一律当成「没有图」。
这条区分是本模块最容易写错的地方，变异测试专门验证了它（见 §5 M1/M4）。

### 3.4 顶层的三段串行仲裁

三个模块共用一条 SD 块读总线，必须严格串行：

```
sd_ok == 0                → sd_probe（链路还没通）
sd_ok == 1 && !扫描结束    → gallery_probe（正在枚举图库）
sd_ok == 1 && 扫描结束     → image_player（播放链路独占）
```

对应代码：

```verilog
wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;
wire sd_owner_player  = sd_ok && !sd_owner_gallery;
wire        sd_arb_start = sd_owner_gallery ? gallery_start : (sd_owner_player ? player_start : probe_start);
wire [31:0] sd_arb_addr  = sd_owner_gallery ? gallery_addr  : (sd_owner_player ? player_addr  : probe_addr);
```

用 wire 多路选择而不是让三个模块各自驱动同一个 `blk_start`——后者是**多驱动**，
lint E2 会报，综合后也是不可预期的线与行为。

一个必须注意的实现细节：`gallery_fail` / `gallery_err` / `gallery_first_req` 的声明
必须**排在仲裁段之前**。Verilog-2001 要求先声明后使用，
把它们写在 `u_gallery` 例化旁边会直接导致 `vlog-2730 Undefined variable`。

---

## 4. 接口和时序假设

### 4.1 `gallery_probe` 端口

| 端口 | 方向 | 说明 |
|---|---|---|
| `clk` / `rst_n` | 入 | 25 MHz / 异步复位低有效 |
| `sd_ok` | 入 | 来自 `sd_probe` 的链路健康电平；**上升沿**启动扫描 |
| `blk_start` / `blk_addr[31:0]` | 出 | 直通 `fat32_reader` 的读块请求（1 拍脉冲 / 扇区号电平） |
| `blk_done` / `blk_err` | 入 | 读块握手，由 `sd_spi_ctrl` 经顶层仲裁提供 |
| `data_byte[7:0]` / `data_valid` | 入 | 块数据字节流 |
| `done` / `fail` | 出 | 两种终局电平，保持到复位 |
| `count[4:0]` | 出 | 连续素材数 0..`MAX_COUNT` |
| `first_img_req` | 出 | 扫描完成且 ≥1 张时给 1 拍脉冲 |
| `err_code[3:0]` | 出 | 失败原因，透传 `fat32_reader` 错误码表 |

参数：`CLK_FREQ_HZ = 25_000_000`（仅保持全工程一致，本模块不用它算时间）、
`MAX_COUNT = 5'd31`（5 位索引的物理上限）。

### 4.2 时序假设

- **`sd_ok` 上升沿是唯一启动条件**。用边沿而非电平，保证上电只扫一次；
  复位前的电平残留不会误触发第二轮。
- **`first_img_req` 只在进入终态的那一拍拉高**，`G_DONE` 态里不再重复。
  否则每拍都是「新请求」，`img_loader` 会被反复触发重载。
- **`count` 由 `hit_cnt` 直接 assign**，不复制第二份寄存器——避免多驱动风险。
- **`blk_busy` 接常量 0**：`fat32_reader` 内部未使用它（预留观察），
  真正的总线占用判断在顶层仲裁器。
- 扫描期间 SD 总线被独占，`image_player` 的 `blk_start` 在此期间不会被选中
  （它本身的 `load_req` 也要等 `!blk_busy` 且 `C_WAIT` 态才启动装载）。

---

## 5. 验证方法

### 5.1 自检 TB（`sim/testbench/tb_gallery_probe.v`）

复用 `tb_fat32_reader.v` 的扇区读取模型：`disk[]` 字节数组 + `build_gallery(n, skip)`
按场景重建 FAT32 镜像，不依赖任何外部文件。DUT 上限取 `MAX_COUNT = 5'd4`
（若取 31，就要在 16 扇区镜像里凑 31 个目录项，场景反而变脆）。

| 场景 | 构造 | 断言 |
|---|---|---|
| W01 | 3 张连续（IMG001~003） | `count==3`、`done==1`、`fail==0`、恰好 1 个 `first_img_req` 脉冲、卡模型空闲 |
| W02 | 空图库（只有 LFN + 卷标 + 目录结束） | `count==0`、`done==1`、`fail==0`、**0 个脉冲** |
| W03 | 5 张但上限 4 | `count==4`（到上限即停，不数第 5 张） |
| W04 | IMG002 缺失 | `count==1`（中间缺口截断） |
| W05 | `err_inject=1`（底层读块失败） | `fail==1`、`err_code==5`、0 个脉冲 |
| W06 | W01 完成后 `sd_ok` 保持高再等 400 拍 | `count` 不变、脉冲数仍为 1（不自激） |
| W07 | 复位后重扫 | `count==3`（终态可重复进入） |

脉冲计数用「基准差值」而不是清零：

```verilog
integer firq_pulses = 0, firq_base = 0;
always @(posedge clk) if (rst_n && gp_first_req) firq_pulses = firq_pulses + 1;
// 每场景开头: firq_base = firq_pulses;
// 断言: (firq_pulses - firq_base) == N
```

早期写 `firq_pulses = 0` 做重置会与这个 `always` 块形成双驱动，必须用基准差值。

另：TB 全程统计 `oob_hits`（越界 LBA 访问次数），收尾断言为 0。
任何一次越界读都说明 RTL 把非法簇号当成了有效簇号，即便最终错误码「恰好」相同也判失败。

### 5.2 变异测试（`gp_work/mutate.py`）

只跑 TB 通过是不够的——断言可能根本没鉴别力。为此对 RTL 做 5 处字符串替换，
每个变异体在独立目录编译运行，检查 TB 是否能杀死它：

| 变异体 | 改动 | 预期被杀 |
|---|---|---|
| M1-tolerant-eof | `if (f32_err == 4'd4)` → `if (1'b0)`（把「未找到」当故障） | W01/W02 |
| M2-no-limit | `if (probe_idx == MAX_COUNT)` → `if (1'b0)`（不设上限） | W03 |
| M3-pulse-repeat | `G_DONE` 里补 `first_img_req <= 1'b1`（每拍都请求） | W06 |
| M4-empty-first-req | 去掉 `if (hit_cnt != 5'd0)`（0 张也发脉冲） | W02 |
| M5-no-reset-child | `rst_req <= 1'b1` → `rst_req <= 1'b0`（不复位子模块） | W01/W04/W06/W07 |

### 5.3 静态检查与编译

- `python scripts/lint_verilog.py rtl project/src`（E0 分号后孤立标识符 / E1 阻塞非阻塞混用 / E2 多驱动）
- `scripts/sync_src.ps1`（含两个工程副本，共 58 文件，末尾自动跑 lint）
- ModelSim `vlog` 全量编译 29 个 RTL `.v`
- ModelSim `vsim` **elaborate 顶层**——这一步此前一直做不了，因为缺 5 个厂商原语
  （`EG_LOGIC_BUFG`、`EG_PHY_PLL`、`sdr_as_ram`、`EG_PHY_SDRAM_2M_32`、`hdmi_tx`）。
  本轮按实际例化写出方向精确的一次性桩件（`gp_work/stubs/`，**不入库**），
  才真正把 elab 跑到 exit 0。

### 5.4 回归

`sim/scripts/run_frontend_regression.ps1 -ReportDir reports/s7_gallery_probe`
（源码 SHA256 运行前后比对，漂移即作废）。

---

## 6. 验证结果

### 6.1 自检 TB

```
PASS: W01 count = 3            ...
ALL CHECKS PASSED: gallery_probe
=== tb_gallery_probe done, errors = 0 ===
```

- 23 条 PASS / 0 FAIL / 0 越界 LBA，仿真时长 1205040 ns，exit code 0。

### 6.2 变异测试

**5/5 全部被杀死**，每个变异体失败的场景与预期完全一致。
结论：TB 的断言真的有鉴别力，不是空跑。

### 6.3 前端回归（9 个 case 全绿）

| case | passLines |
|---|---|
| sd_protocol_default | 62 |
| sd_protocol_fast | 64 |
| sd_spi_ctrl | 23 |
| sd_probe | 14 |
| fat32_reader | 40 |
| **gallery_probe** | **23** |
| bmp_parser | 37 |
| img_loader | 43 |
| player_ctrl | 85 |

脚本 exit 0，报告在 `reports/s7_gallery_probe/`（该目录属仿真产物，不入库）。

### 6.4 静态检查与编译

- `lint_verilog.py`：58 文件，**E0=0 E1=0 E2=0**
- `vlog` 全量 29 个 RTL `.v`：**COMPILE OK，no diagnostics**
- `vsim` elaborate `dmz_eg4s20_hdmi_top`：**exit 0，零错误零警告**
  （30 多个例化的端口连接全部对上，含新增的 `u_gallery`）

---

## 7. 未解决问题

1. ~~`project/hdmi_td.al` 未加入 `gallery_probe.v` 源项。~~ **已在本轮后续修复，且问题比初判严重得多。**
   复查时发现 `.al` 自提交 `e41315a` 起就缺 **12 个模块源**（不止 `gallery_probe` 一项）：
   `sdram_pll`、`sdram_ctrl_wrap`、`async_fifo`、`fat32_reader`、`bmp_parser`、`img_loader`、
   `framebuf_arbiter`、`pix_reader`、`player_ctrl`、`sd_spi_ctrl`、`sd_probe`、`image_player`。
   实测 `flow_t2_elaborate.tcl` 报 6 条 `HDL-7144 instantiate unknown module` 与 6 条
   `HDL-8007 ... is a black box`，**elaborate exit 4 —— 正式顶层此前根本无法构建**。
   该问题已在同一轮修复（`.al` 从 9 个 `.v` 扩到 26 个，并补 4 个 `ip/local/sdram/` 文件），
   修复后 elaborate exit 0，完整综合/布局/布线/bitgen 全 PASS。详见
   [任务总览](../TASKS.md) §七。
2. **没有上板。** 真卡目录遍历、换卡后的扫描行为、真卡上 `err=4` 的判定，
   全部都只有行为级仿真证据。
3. **SiP SDRAM 接口 setup WNS `-7.232ns` 未变。** 本轮改动全在功能层，
   **没有新增任何时序证据**。这是发布阻塞项，与图库扫描无关，也不能声称已解决。
   （`.al` 修复后跑完整流程复测，WNS 仍为 −7.232 ns、TNS −335.004 ns，与修复前一致。）
4. **`color_bar_ref.v` 编译失败**（缺 `video_define.v` include 路径），
   属存量问题，未在本轮修复；全量编译时临时排除该文件。
5. `readable-verilog-generator` 严格门禁 `delivery_ready` 仍未通过
   （新文件按仓库既有风格书写，未按该工具的机械规则逐条对齐）。
6. 图库扫描期间 SD 总线被独占，若素材很多（接近 31 张）上电到首图显示的延迟会增加；
   仿真下无感，真卡上需实测确认这个延迟可接受。
7. **编码约束存量偏差**：硬性约束 0d 要求 `.ps1` 为 UTF-8 带 BOM，但仓库 14 个 `.ps1` 中
   只有 4 个带 BOM（`run_image_regression.ps1`、`run_sdram_frame_diag.ps1`、
   `run_sd_card_replay.ps1`、`run_storage_regression.ps1`）。本轮编辑的
   `scripts/sync_src.ps1`、`scripts/make_test_bmps.ps1`、`sim/scripts/run_frontend_regression.ps1`
   在 HEAD 中即为 no-BOM，本轮**保持原状未改编码**（避免只修三个文件造成新的不一致）。
   若要彻底合规，应一次性统一全部 `.ps1` 的 BOM 状态 —— 属独立清理任务。

---

## 8. 下一步任务

按 `docs/s6_integration_2026-10-20.md` §8 与阶段五出口准则，建议顺序：

1. 把 `gallery_probe.v` 加入 `project/hdmi_td.al` 并跑 TD 综合 —— **已在本轮完成**。
   `.al` 实际缺 12 个模块源（详见 §7 第 1 条），补全后跑完整流程：资源 LUT 8215/19600 = 41.91%
   （LUT-as-logic 5079/8852 = 57.38%）、IO 41/188、PLL 2/4、BRAM 6、DSP 13；
   时序 setup −7.232 ns / hold +0.023 ns，**与修复前完全一致，未新增违例**。
2. **上板验证图库扫描**：插 3 张连续卡 → 首图自动显示、KEY1/KEY0 能切到第 2/3 张；
   换 1 张卡复位 → 只有首图，「下一张」不动作也不报错。
3. **上板验证缺图截断**：卡上放 IMG001 + IMG003（缺 002）→ 只能看到 IMG001。
4. 之后才是阶段五其余条目（自动轮播上板、基础音频、音视频联动），
   以及 `docs/s6_integration_2026-10-20.md` §8 列的 HDMI 音频与双缓冲。
