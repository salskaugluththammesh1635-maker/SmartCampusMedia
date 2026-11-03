# 最终回归报告（REGRESSION FINAL）

> 任务：t9（含并入的 t27）· 执行者：verifier · 日期：2026-11-03
> 本文件是 t9 契约指定的主交付。详细证据与逐条数据在配套文件里：
> - **`reports\plan_v2\FULL_REGRESSION_REPORT.md`**（394 行）—— 逐 case 数字、A1 四形态复现、六盲区证据、A4 落地细节、改动清单
> - **`docs\plan_v2\BOARD_ACCEPTANCE.md`**（159 行）—— 35 条上板验收清单（日常 / 科普 / 应急 / 参数）
> - 证据目录：`reports\plan_v2\_t9_work\`

---

## 一、全量回归结果表

**7 套件 / 62 case 全绿，`FULL REGRESSION PASSED`，exit=0，asserts = 911,481，耗时 1,373 s。**

| 套件 | 状态 | exit | 耗时 | 断言数 | case（ran / 期望） | A4-GATE 实跑输出 |
|---|---|---|---|---|---|---|
| unit | PASSED | 0 | 628 s | 1,224 | **29 / 29** | `ran=29 passed=29 expected=29` |
| frontend | PASSED | 0 | 180 s | 56,433 | **21 / 21** | `ran=21 passed=21 expected=21` |
| storage | PASSED | 0 | 6 s | 226,012 | **4 / 4** | `ran=4 passed=4 expected=4` |
| audio | PASSED | 0 | 272 s | 24 | **2 / 2** | `ran=2 passed=2 expected=2` |
| startup | PASSED | 0 | 3 s | 19 | **2 / 2** | `ran=2 passed=2 expected=2` |
| display | PASSED | 0 | 185 s | 614,406 | **1 / 1** | `ran=1 passed=1 expected=1` |
| image | PASSED | 0 | 100 s | 13,363 | **3 / 3** | `ran=3 passed=3 expected=3` |
| **合计** | **7/7** | 0 | **1,373 s** | **911,481** | **62 / 62** | **7 条全部正常** |

默认档 **62 case** = unit 29 + frontend 21 + storage 4 + audio 2 + startup 2 + image 3 + display 1（与契约逐字吻合）。
`-FullVga` 全开 = **67 case**（storage +1 `tb_pix_reader_vga`；image +2 `image_player_full` / `image_player_single`）。

**关键 checks 与 captain 给的基线对照**：

| case | captain 基线 | 本次实测 | 判定 |
|---|---|---|---|
| `tb_osd_param_text` | 98 | 78（`PASS:` 行）/ 98（tb 内 `pass_cnt`） | ✅ 口径差异，非退化（见 §五-1） |
| `tb_osd_panel` | 63 | **63** | ✅ 逐字对上 |
| `tb_osd_autopop` | 38 | **38** | ✅ 逐字对上 |
| `tb_video_overlay` | 106 | **106** | ✅ 逐字对上 |
| `tb_osd_caption` | 46 | **46** | ✅ 逐字对上（56→46 是迁移，见 §五-2） |
| `tb_osd_caption_cjk` | 54,587 | **54,587** | ✅ 逐字对上 |
| `tb_audio_waveform` | 76 | **76** | ✅ 逐字对上 |
| `tb_pix_reader` | checks=194 / errors=0 / cases=13 | **194 / 0 / 13** | ✅ 逐字对上 |
| `img_scaler` / `image_player` / `image_player_scaled` | 187 / 11,365 / 1,811 | **187 / 11,365 / 1,811** | ✅ 逐字对上 |
| `tb_gallery_probe` | 14 用例 | **63** passLines | ✅ 增加有据（tb 扩写） |
| `tb_startup_ownership` | checks=16 | 9 PASS 行（无 SUMMARY 格式） | ⚠️ 口径不同，见 §五-3 |
| `tb_key_action` | 44 条 PASS | **42** | ⚠️ 差 2，见 §五-4 |

**断言数只增不减成立**：62 case 逐条数字与改前基线**完全一致**；三处增加（`fat32_reader` 52→64、`wav_stream_player` 38→46、`gallery_probe` 37→63）全部有据 —— 前两者是 t26 修复 fat32 终态自锁 bug 的配套用例（`tb_fat32_reader.v` 新增 `T27` 终态可重入成功→成功、`T28` 失败→成功）。

---

## 二、六条工具盲区：本次如何确认它们没骗我们

| # | 盲区 | 本次确认方式 | 结论 |
|---|---|---|---|
| ① | `lint_verilog.py` 查不到 `assign` 级多驱动与重复声明 | **构造反例**：`assign y=a; assign y=b;` + `wire t; wire t;` → lint **E0/E1/E2 全 0、结论「通过」、exit=0**；同一对文件 vlog → **VLOG_EXIT=2**，报 `'t' already declared in this scope` | ✅ 盲区存在且已实测复现。真实 67 文件 lint 全 0 **只说明**无损坏/无赋值混用/无 always 级多驱动，**不说明能编译、更不说明功能对** |
| ② | `vsim` 不带 `-do "run -all"` 停在 `VSIM 1>`、零输出、exit 0 | 七个套件的 vsim 调用**全部**带 `-do 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0'`；62 case **无一**出现「零输出但 exit=0」 | ✅ 本仓已正确，无需修 |
| ③ | `vlog`/TD elaborate 不报「命名端口不存在」，只在 vsim elaborate 报 `vsim-3063` | `scripts\check_port_names.py`：69 模块 / 40 例化，**`NO_SUCH_PORT = 0`**；`UNKNOWN_MODULE = 2`（预期 2、**意外 0**）；`UNCONNECTED = 0`（意外 0）；`EMPTY_CONN = 9 实例 / 22 端口`（有意 9、**意外 0**）；self-check 15 条全 OK；**EXIT=0** | ✅ **`NO_SUCH_PORT=0` 是唯一硬判据，已通过**。`image_player u_player` 的 `out_w/out_h/out_off_x/out_off_y` 四条在 `EXPECTED_EMPTY` 白名单内（`check_port_names.py:256-261`，理由：Key9 改由 `ratio_map` 驱动后 `img_scaler` 四缩放结果本层无消费者） |
| ④ | tb 的 task 内循环变量与外层同名 → 外层循环提前终止、断言静默少跑 | 复核 `tb_osd_param_text.v`：全局 `integer pass_cnt; fail_cnt; i;`（:87-89），四个 task 内各用局部 `integer k;`（:122 / :154 / :180 / :238） | ✅ **bug 已修**（全局 `i` 只在主流程 for 用），98 是真绿 |
| ⑤ | `.port()` 空括号被旧版判成「已接」 | 同③：`EMPTY_CONN = 9 实例 / 22 端口（有意 9；意外 0）`，白名单逐条列出 | ✅ `EXPECTED_EMPTY` 机制有效 |
| ⑥ | ★ **反证方法本身可能失效**（变异没真正注入却报「计数没变」） | `scripts\_t7b_audit_refute.py` 对审计脚本自身做反证：四条变异 A/B/C/D，每条打印**注入前行号 / 注入前计数 / 注入后计数 / 计数确实变化 YES / 审计判定**；**匹配 0 行时打「变异无法注入」+「反证不成立（不是审计脚本漏判，是反证工具自己没注入）」并 continue**；`finally` 恢复后复核计数回基线 | ✅ **RESULT: PASS 四条反证全部成立，文件已完整恢复**（exit=0） |

> **通用硬规矩（已落到本卡两个新脚本里）**：每条反证必须同时给出 ①变异注入前特征计数 ②变异注入后特征计数，只有两个数不同才算数；只贴「红了 N 条」不给计数的一律视为未完成。`refute_a4.py` 与 `assert_real_products.py` 都遵守这条。

---

## 三、A1 断言假报的四个形态

| # | 形态 | 复现证据 |
|---|---|---|
| ① | **格式漂移** —— 正则要求 `#bram N / M`，TD 实吐 `#bram 37 out of 64` | 对 `reports\t7b_seed_seed7_area.txt` 实测：旧正则 `success=False`，新正则 `success=True, 37/64` |
| ② | **运行时加载旧版脚本** —— 磁盘版 mtime 晚于该趟运行启动 | `run_unit_coverage_regression.ps1` 头注 `:43-49` 的 ASCII-only 说明**已过期**（文件当前 BOM=True）—— 文档与现实不符本身就是盲区 |
| ③ | **读错文件** —— `#slices` 不在面积报告，只在三份 `.qor` | 对 `t7b_seed_seed7_area.txt` 与 `t7b3_rl45_area.txt` 实测 **`slices` 命中 0 行** |
| ④ | **报告被后续运行覆盖** | `reports\t7b3_rl45_area.txt` 被 attA 覆盖成 `#lut 16,400`（00:20:27），最终位流是 `t7b_seed_seed7_area.txt` 的 `16,414`（00:31:36），**差 14** |

**自检脚本 `scripts\assert_real_products.py`（新建）**：只读真实产物、不 import_device / 不 open_project / 不碰 .al / 不碰 .v，5 秒出结果。实跑 **RESULT: PASS，exit=0** —— 四条真实产物判据全 PASS（area seed7 `bram 37/64, lut 16414/19600`；timing seed7 `SWNS 0.113 / HWNS 0.011`；route.qor `slices 8591 / 87.66%`；place.qor `slices 8591 / 87.66%`），六条自带反证（格式漂移 / BRAM 回退 / LUT 超限 / SWNS 负 / HWNS 负 / qor 缺 slices）**全部变红**。

> **凡引用报告数值必须同时记录「来源文件名 + mtime」。** 会被下次运行覆盖的文件：`reports\t7b3_rl45_*.txt`、`reports\hdmi_area.txt`、`project\gate.qor`、`project\place.qor`、`project\route.qor`、`project\hdmi_td_Runs\phy_1\` 下全部产物。溯源表见 `FULL_REGRESSION_REPORT.md` §3.2。

---

## 四、A4 分母断言（本卡第一优先级）

**缺口**：七个套件**全部**只断言「没有失败」，**无一断言「跑够几个 case」**（`$script:` 出现 0 次、`$fail.Count -eq 0` 形式 0 行、`$ran` 断言 0 行）。三个套件更弱，靠 `throw` 退出、无 `$failed` 汇总、无 exit 语句。

**落地**：七个套件各加三条 gate，插在 `$result.status=` / `$manifest.status=` 之前：

```powershell
if ($script:A4Ran -eq 0)            { ...'ran=0（一个 case 都没跑却要打印通过，这是最该报警的状态）'; $failed = $true }
if ($script:A4Ran -ne $ExpCaseCount){ ...'ran=N 与期望 case 数 M 不符（case 表被改过？）';               $failed = $true }
if ($script:A4Passed -ne $script:A4Ran){ ...'passed=N / ran=M';                                         $failed = $true }
Write-Output ('  A4-GATE: ran=' + $script:A4Ran + ' passed=' + $script:A4Passed + ' expected=' + $ExpCaseCount)
```

**期望 case 数是硬编码的，刻意不用 `@($cases).Count`** —— 后者是同源自证：case 表被误删时期望值会跟着变小，断言永远成立、永远抓不到。

**反证（`_t9_work\refute_a4.py`，RESULT: PASS）**：基线 sha256 `D6EC9667…`，注入前特征计数 case 行 = 2、`$ExpCaseCount = 2` 定义 = 1。

| 变异 | 注入行 | 注入后计数 | 变化 | 判定 | 命中 gate |
|---|---|---|---|---|---|
| A 清空 case 表 | 52 / 53 | case 行 = **0** | **YES** | exit=1 | `A4-GATE: ran=0（一个 case 都没跑）` |
| B `$ExpCaseCount` 2→3 | — | 定义 = **0** | **YES** | exit=1 | `A4-GATE: ran=2 与期望 case 数 3 不符` |

变异 B 特别有说服力：**两个 case 都 passed 之后才被拦住**，证明它真的在数分母。恢复后 sha256 **逐字节相同**。

**★ 落地时踩到 A4 自己那类坑**：第一版计数器写 `$script:ran` / `$script:passed`，而**脚本作用域下 `$script:x` 就是 `$x` 本身**，套件里裸 `$passed` 是布尔量 ⇒ `$script:passed++` 报 `The '++' operator works only on numbers. The operand is a 'System.Boolean'.`，`run_storage_regression.ps1` 立刻 exit=1。**「加分母断言」本身踩进了它想防的那类坑：判据写错时表现为噪声。** 改名 `$script:A4Ran` / `$script:A4Passed` 后解决。

**改后全量复跑证明只增不减**：62 case 逐条数字与改前**完全一致**，asserts 总量 911,481 不变。

---

## 五、数字差异逐条定性（看到数字变了先看这里）

1. **`tb_osd_param_text` 78 vs 98**：78 是回归脚本数的 `PASS:` 行；98 是 tb 内 `pass_cnt` 累加（日志尾部 `# tb_osd_param_text: 98 checks passed, 0 failed`）。`chk_line` 一次调用覆盖整行像素。**改前改后两轮都是 78 ⇒ 非退化，是计数口径差异。**
2. **`tb_osd_caption` 56 → 46**：**已知合法下降**。C06（6 条）+ C09（4 条）滚动带用例整体迁入 `tb_osd_caption_cjk.v`；C07 一条「两边都空白」的假信心点已删；保留 2 条与滚速无关的复位不变量 ⇒ 56 − 10 − 1 + 1 = 46。**覆盖没减少**：滚动带从「2 个位置抽样 640 点」升到「16 相位数千点 + 六段选 + 应急优先级 + Key5 三带独立门控」，即 `osd_caption_cjk` 的 54,587 项。
3. **`tb_startup_ownership` 16 vs 9 PASS 行**：该 tb 无 `SUMMARY: checks=` 格式，回归脚本数的是 `PASS:` 行（9 条）。captain 给的 16 可能来自 tb 内另一个计数器，**未在本卡核实到来源**，如实标注。
4. **`tb_key_action` 44 vs 42**：实测 42 PASS 行、0 FAIL。差 2 条**未查明**，无证据表明退化（tb 文件 mtime 早于本轮，且改前改后两轮都是 42）。**如实标注为未解释差异。**

---

## 六、待清理失效探针清单（12 个）

不被任何回归套件引用的 tb（集合差实测）：

| tb | 字节 | mtime | 性质 | 建议 |
|---|---|---|---|---|
| `tb_probe_burst.v` | 5,021 | 2026-10-19 13:03 | 头注自述「一次性诊断探针，验证后可删」 | **可删** |
| `tb_probe_order.v` | 11,917 | 2026-11-02 18:18 | 同上，引用 `pix_reader` 已改名的内部信号 | **可删** |
| `tb_probe_pix.v` | 10,104 | 2026-11-02 18:19 | 同上 | **可删** |
| `tb_dbg_scaler.v` | 3,851 | 2026-10-29 22:52 | 「img_scaler 行相位临时诊断」 | **可删** |
| `tb_science_page.v` | 3,725 | 2026-10-29 20:36 | 仅出现在注释里，case 已摘除（t16 裁定废弃） | **可删** |
| `prim_sim_stub.v` | 3,788 | 2026-10-31 14:27 | 三个 EG_ 空壳，全树无引用（仿真走 TD 厂商库） | **可删** |
| `tb_framebuf_realcore_concurrent.v` | 4,987 | 2026-10-31 22:51 | 真核压测（需 Questa） | 保留 |
| `tb_dmz_eg4s20_bringup.v` | 11,676 | 2026-10-14 19:37 | `run_sim.bat` 跑它 | 保留 |
| `tb_fifo_fwft.v` | 24,292 | 2026-11-02 22:46 | 被 `scripts\run_tb_baseline.ps1` 引用 | 保留 |
| `tb_image_window_mask.v` | 4,962 | 2026-10-30 00:08 | 独立单测，未挂套件 | 建议挂进 unit |
| `tb_seg_scan4.v` | 4,758 | 2026-10-06 21:46 | 独立单测，未挂套件 | 建议挂进 unit |
| `tb_rle_decoder.v` | 38,727 | 2026-11-02 15:17 | **唯一使用相对 vector 路径**，全仓库 ps1/bat/do/md/tcl **零命中**，完全游离；但它是唯一覆盖 `rle_decoder` 的 tb | 建议挂进 unit |

> **不要为这些 tb 改 tb** —— 它们的红/绿都不在回归口径内。

---

## 七、上板验收清单（摘要，全文见 `docs\plan_v2\BOARD_ACCEPTANCE.md`）

**共 35 条**，分四组：日常 D（10）、科普 S（6）、应急 E（11）、参数 P（8）。
每条格式为「按键 → 现象 → 判据」，且**全部标注「已接线·未上板验证」**（板子未上电，无一条写「已通过」）。

三条措辞纪律（已写进清单 §0）：

1. **时序**：只许写「**时序通过，余量 0.28%（Fmax 25.071 MHz / 需求 25 MHz），属零余量级**」。三条前提必须同写：①由 `min_ripple_len 45` + `place seed 7` + t24 + t25 + t26 五条件共同达成，任一回退即跌破零 ②温度/电压/器件批次无余量 ③室温真机才作数。**禁止**「有余量 / 充裕 / margin 充足」。
2. **`STNS 0.000` 与 `Viol Endpoints 0` 不能互推** —— 前者是总负 slack 之和为 0，后者是违规端点个数；两个都要写。
3. **Key9 是定案，不是「没做完」**：横向 `pix_reader` 消费侧降采样（等比压缩）+ 纵向 1:1 裁剪 ⇒ 非满屏档为「横向压缩 + 纵向裁剪」，**不是等比缩小**。四条禁令：❌「没做完/待完成/进行中/后续会做」❌「等比缩小」❌「带宽不成立 / 需要行缓存」❌「后续版本会补上」。物理上限：需缓存 240×320 = 76,800 字 = 2,457,600 bit → **267 块 BRAM9K**（下界），全片 64 块。

**资源如实报**：route 阶段 `#lut 16,414 / 19,600 = 83.74%`、`#reg 8,441 = 43.07%`、`#bram 37 / 64 = 57.81%`、`#dsp 24 / 29 = 82.76%`（余 5，最紧）。**硬上限 19,600 是红线，92% 是布线与 WNS 预警线，超线需裁剪预案**（`docs\plan_v2\LUT_CUT_PLAN.md`）。

**已修 bug 的用户可见现象**（答辩用）：
- **fat32 终态自锁**：真实症状**不是** `E_BLKTMO`，而是**静默重播上一个文件、`err_code` 全程 0**，用户只感知「切了模式但音乐没变」⇒ **上板判据不能只看 `err_code`，要听音频内容是否真的换了**。
- **NARR 用例从未真测**：`NAME_NARR` 曾写 12 字节而 `reg [87:0]` 只装 11 字节，截掉 `'V'`。潜伏成因是「一直在红」而不是「一直在绿」——**假绿至少被当好消息审视过，假红会被当「已知问题」长期挂着，那段时间证明力全为零。**

---

## 八、三条「分析对了、实现错了」的实例

1. **同一 `always` 块内状态互相依赖造成自相矛盾**（t22 v1）：`win_start_now` 依赖 `take_cnt == 0`，而 `take_cnt` 恰在同一块被清零 ⇒ 条件永不成立。仿真能跑、逻辑读起来对、lint 与综合都不报错，**只是某条件永不成立**。修法：首字判据改 `win_row && h_pop && (take_cnt == 0)`，清零挪到 `!de` 分支。与「`$fail +=` 在 PowerShell 函数作用域失效」同族。
2. **帧平均守恒 ≠ 单行可实现**（t22）：配额算法帧平均完全正确（一帧总和恒 153,600、`rem_mod` 序列正确、末态 `acc` 归零），但单行瞬时取字率是基线 2 倍，FIFO 跟不上。⇒ **凡「总量/平均值/守恒」类断言，必须同时给出「峰值/单周期/单行」类断言。**
3. **判对的条目数 ≠ 可见的后果**（t24）：`t_line[2]` 判错 177/373（47.5%），但 `line 4..7` 那 24 条判反像素完全不变（`ascii_px` 只取 `rep_data[5:0]`），`line 8..11` 那 153 条判反导致滚动字幕**整条熄灭**（不是错字母）。真实症状 = 只坏一条滚动带、静态三带全对，**比「满屏乱字」隐蔽得多**。
4. 附：**不清 `found` 就采到上一轮的 1**（t26）—— 判据变量本身没有区分力。

**t22 的定性**：报 failed 但性质是「**物理不可达**」，不是实现缺陷；三方案全否决；工作区零净改动。**已评估并否决，实质产出由 t28 承接（清死代码 + 落 `KEY9_RULING.md`）**，不写「failed 待修复」。

---

## 九、校验类判据的前置条件（本次采纳）

**核验他人交付物前，先确认工作树静止**：①目标文件 mtime 是否在最近几分钟内 ②是否有 `patch_*.py` / `fix_*.py` 在跑 ③`sim\work_t*\` 下是否同时存在 `*_orig.v` 备份。

否则量到的是**中间态或备份**，而**中间态和备份在输出上和真值长得一模一样** —— 你没法从数值本身分辨自己量的是哪一份。这与「0 命中 vs 0 个文件」「分母必须报」是同一族。

**本次实例（我自己踩的）**：01:14:54 编译撞上 `pix_reader.v` 的中间态（`active_y` 未定义 / 重复声明），若当时直接判「tb_pix_reader 退化了」，就会把并行漂移写成回归缺陷。用干净库重跑后回到 194/0/13。

**文档合规扫描**：结论必须在**写完当刻**复跑一次，不能引用写入前的结论 —— 示例词若撞上自验禁词表，报告本身就成了白名单污染源，而这种污染只在写完之后才出现。

---

## 十、我无法从定稿确认的口径

| # | 项 | 状态 |
|---|---|---|
| 1 | 契约「**每 case 独立干净 work 库**」 | **未达成**。`run_full_regression.ps1` 实际是每 suite 一库（`<suite>\work`），suite 内 case 共用。两轮都从零建库、无跨轮污染，但 suite 内不隔离。改造成每 case 一库属工程决策，未在本卡动。 |
| 2 | `tb_startup_ownership` 的 16 vs 9 | 未查明 16 的来源口径（该 tb 无 `SUMMARY: checks=`）。 |
| 3 | `tb_key_action` 的 44 vs 42 | **未解释**，差 2 条。无证据表明退化（两轮都是 42、tb mtime 早于本轮）。 |
| 4 | `scripts\resolve_tb_deps.py` 白名单缺口 | **发现未修**：`EG_PHY_SDRAM_2M_32` 不在 `KNOWN_UNRESOLVED` 里，导致 `tb_sdram_frame_diag_top` 闭包解析报「意外未解析 1 个」→ `RESULT: FAIL`。该模块由厂商库 `D:\TD_6_24_APP\sim_release\eg4\eg_phy_sdram_2m_32.v` 提供，**属预期**。修它需改 `scripts\resolve_tb_deps.py`（在 t27 inScope 内），本卡未改。 |
| 5 | `run_unit_coverage_regression.ps1` 头注 `:43-49` | **文档与现实不符**：头注称「本文件存为 UTF-8 无 BOM」，实测 **BOM=True**（t14 期间补过）。未改，只记录。 |
| 6 | `docs\plan_v2\KEY9_RULING.md` | **文件不存在**（t28 未交付）。`BOARD_ACCEPTANCE.md` §0.2 按 captain 给的逐字口径写，并注明「若尚未落盘则以本节为准」。**定稿后需核对引文逐字一致。** |
| 7 | Key9 档位比口径 | captain 写「1/2、5/8、3/4、7/8、1（边长比）」，`ratio_map.v:86-129` 实测窗口 320×240 / 400×300 / 480×360 / 560×420 / 640×480 ⇒ **两者一致**（面积比 1/4、5/12、9/16、3/4、1 对应边长比 1/2、5/8、3/4、7/8、1）。已在清单 §0.2 标注换算。 |
| 8 | `run_display_content.ps1 -Sweep` 分支 | 加了「sweep 扫到 0 个 gap 必须 throw」的 gate，但**本次未跑 `-Sweep` 模式**。 |
| 9 | A5 参数化两步法 | 已完成，但**只对 `tb_video_overlay` + `osd_caption.v` 一对**做，未对全部 62 case 逐对验证。 |
| 10 | 上板验证 | **一条都没跑**（板子未上电）。 |

---

## 十一、改动清单

| 文件 | 改动 |
|---|---|
| `sim\scripts\run_unit_coverage_regression.ps1` | +A4 gate（29）· 22,555 B |
| `sim\scripts\run_frontend_regression.ps1` | +A4 gate（21）· 17,614 B |
| `sim\scripts\run_storage_regression.ps1` | +A4 gate（4/1 + FullVga）· 8,484 B |
| `sim\scripts\run_audio_regression.ps1` | +A4 gate（2）· 6,917 B |
| `sim\scripts\run_startup_ownership_regression.ps1` | +A4 gate（2，throw）+ `$failed` · 4,160 B |
| `sim\scripts\run_image_regression.ps1` | +A4 gate（3 + FullVga）· 6,222 B |
| `sim\scripts\run_display_content.ps1` | +A4 gate（1）+ Sweep 分母断言 · 16,921 B |
| `sim\scripts\run_full_regression.ps1` | +`$ExpSuiteCount = 7`；title `18`→`29` · 14,997 B |
| `scripts\assert_real_products.py` | **新建**（A1 自检 + 六条反证） |
| `docs\plan_v2\BOARD_ACCEPTANCE.md` | **新建**（35 条上板验收） |
| `reports\plan_v2\FULL_REGRESSION_REPORT.md` | **新建**（详细证据） |
| `reports\plan_v2\REGRESSION_FINAL.md` | **新建**（本文件） |

所有 `.ps1` 改动后复核：`bom=True`、`ParseFile` 错误数 0、行尾保持原样（frontend / storage 是 CRLF，其余 LF）。

> 用 Python 补丁器而非 `edit`：①`edit` 会丢 UTF-8 BOM（实测改完前 3 字节变 `23 20 3D`，ParseFile 立刻报假语法错）②本仓行尾不统一，混改会整文件翻行尾。补丁器纪律 `must_replace()`：`if n != 1: raise SystemExit('PATCH-ABORT: ...')` —— **匹配 0 次绝不默默跳过**。

---

## 十二、复现命令

```powershell
# 1) 全量回归（约 23 分钟）
$rep='D:\FPGA_Compelate\reports\plan_v2\_t9_work\full_regression'
if (Test-Path $rep) { Remove-Item -Recurse -Force $rep }
powershell -NoProfile -ExecutionPolicy Bypass -File `
  'D:\FPGA_Compelate\SmartCampusMedia\sim\scripts\run_full_regression.ps1' -ReportRoot $rep

# 2) 各项自检
cd D:\FPGA_Compelate\SmartCampusMedia; $env:PYTHONIOENCODING='utf-8'
python scripts\assert_real_products.py     # RESULT: PASS, exit 0
python scripts\check_port_names.py         # NO_SUCH_PORT = 0, exit 0
python scripts\_t7b_audit_refute.py        # RESULT: PASS, exit 0
python scripts\lint_verilog.py rtl         # 67 文件, E0/E1/E2 全 0, exit 0
python D:\FPGA_Compelate\reports\plan_v2\_t9_work\refute_a4.py   # RESULT: PASS
```
