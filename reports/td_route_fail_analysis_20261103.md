# TD route 失败机理分析（captain 独立核定）

> 日期：2026-11-03 23:08
> 起因：t10（verify-build）两次从 elaborate 重跑全流程均 `FAIL-route`，未产出新位流。
> 本文只做机理认定与方案取舍，不重跑 TD、不改 RTL。

---

## 一、失败不是"时序没收敛"，是"没地方插 hold buffer"

t10 run2 日志 `td_full_elaborate_defaultseed.log` 的完整时序轨迹（`PHY-1001` 行）：

| 行号 | Setup WNS | Setup TNS | FEP | Hold WNS | Hold TNS | FEP |
|---|---|---|---|---|---|---|
| 1728 | −2.133 | −21.193 | 27 | −0.012 | −0.033 | 5 |
| 1782 | −2.020 | −20.682 | 27 | −0.012 | −0.045 | 7 |
| 1811 | −0.379 | −0.762 | 3 | −0.012 | −0.045 | 7 |
| 1838 | −0.277 | −0.567 | 3 | −0.012 | −0.045 | 7 |
| **1865** | **+0.124** | **0.000** | **0** | −0.012 | −0.045 | 7 |

**route 的 detail routing 已经把 setup 收敛到 `+0.124 ns / TNS 0 / 0 违例`——比基线 `+0.113 ns` 还好。**

随后进入 `Stage 3 | Hold Fix`（第 1885 行），要为 7 个 hold 违例各插 1 个 buffer（第 1890–1905 行，共 8 个 buffer），失败于第 1939–1941 行：

```
PHY-8023 ERROR: Location: (x27y35_e2beg3), nets: u_rle/ramread0_syn_103 rst_n_dup_53
PHY-8023 ERROR: Location: (x29y35_local0), nets: u_rle/ramread0_syn_119 rst_n_dup_53_holdbuf0
RUN-8102 ERROR: Incremental route failed. ... resources used in your design exceed the device resource limitations
```

注意第 1940 行：`rst_n_dup_53_holdbuf0` —— 这是**刚为修 hold 而插入的新 buffer 节点**，它的下一跳就和另一根网抢同一个物理位置。**这是"增量布线在 89% 占用下无路可走"，不是时序预算不够。**

### 佐证：Hold Fix 之后的 place 阶段 QoR（第 1906–1935 行）

| 指标 | 值 |
|---|---|
| Setup WNS | **1757 ps**（25 MHz 域，即 40 MHz SDRAM 域之外的像素域更宽裕） |
| Setup TNS | 0 |
| 违例 S-EP | **0** |
| FMAX | 43.024 MHz |
| Hold WNS | **−11 ps** |
| Hold TNS | −121 |
| 违例 H-EP | **11** |
| `#slices` | 8768 / **89.47%** |
| `#RAMs` | 37 |
| `#DSPs` | 24 |
| Wire length | 796,125 |
| Top 1% tile util | 56（58.62%） |
| Over 100% util #tile | **0** |

**setup 全面转正、无违例；只剩 11 个 hold 端点、最差 −11 ps。** 换句话说：**只差 11 ps 的 hold，代价却是一个漂移不定的物理布线死结。**

### 两次失败的落点不同，证明是系统性而非偶发

| 跑次 | 冲突位置 | 冲突网 |
|---|---|---|
| run1（seed 7） | `(x20y5_local1)` | `u_vtg/active_x_b[3]` + `rst_n_dup_34` |
| run1（seed 7） | `(x21y4_local6)` | `u_axis/rgb[13]_syn_dup_8109` + `rst_n_dup_34` |
| run2（默认 seed） | `(x27y35_e2beg3)` | `u_rle/ramread0_syn_103` + `rst_n_dup_53` |
| run2（默认 seed） | `(x29y35_local0)` | `u_rle/ramread0_syn_119` + `rst_n_dup_53_holdbuf0` |

两次都要碰 `rst_n_dup_*`（高扇出复位网），但**编号不同**（34 vs 53）⇒ 换 seed 只是换了个死结位置，不是解决问题。

---

## 二、驳回 verify-build 推荐的方案 A

verify-build 最推荐 `T7B3_EXTRA='route fix_hold on'`（他称之为"关掉 hold fix"）。**这个方案是空操作**，两条独立证据：

1. **实测**：run2 的 `INFO-T7B3-EXTRA=` 为空（日志原文），`T7B3_EXTRA` 一个参数都没设，而日志第 1885 行照样出现 `Stage 3 | Hold Fix` ⇒ **`fix_hold` 默认值就是 `on`**。
2. **官方脚本**：`D:\TD_6_24_APP\doc\scripts\DefaultFlow.tcl:192-201` 与 `MultiSeed.tcl:108-117` 的写法是
   ```tcl
   set_param route fix_hold off   ;# 让 route 只做 setup
   route
   fix_hold                        ;# 然后单独跑 hold fix
   set_param route fix_hold on     ;# 复位参数
   ```
   **`on` 是"恢复默认"，不是"开启新特性"。** 真正的开关是 `off` + 独立的 `fix_hold` 命令。

⇒ 若照方案 A 原样重跑，**10 分钟换来逐字节相同的结果**（`#bram` / 面积 / 失败点全不变），必须驳回。

---

## 三、可行的三条路线（按性价比排序）

### 路线 1（推荐）：先留空位，再修 hold —— 用官方拥塞参数

**逻辑**：PHY-8023 是"没地方"，那就先让布局疏松一点。`#slices` 89.47% 是本轮 +2.28 pp 的净增量造成的，而本轮真实语义增量只有约 +193 LUT（其余 +233 是 `u_axis` 映射噪声）。

TD 官方 `doc/strategies/official_strategy_ph1.json` 的 `CongestionMedium` / `CongestionHigh` 组给出的正是这个工具：
```tcl
set_param place target_density    0.6      ;# CongestionHigh 值
set_param place target_density_pp 0.7
set_param place opt_max_density   50
set_param place ofv               70
set_param place enable_congestion_recovery on
set_param place enhanced_gp      on
set_param place non_crit_opt     on
set_param place post_place_opt   high
set_param route post_route_opt   high
```
只需取其中**最温和的一档**先试（`enable_congestion_recovery on` + `enhanced_gp on`），因为这些参数会**降低布局密度、可能牺牲 setup WNS**——但当前 setup 有 +1757 ps 富余，**完全输得起**。

**风险**：目标密度降低会让布线变长，setup 可能从 +1757 ps 掉到几百 ps 甚至负。但基线就是 +113 ps，只要不跌破 0 就仍可交付。

### 路线 2：用 `TimingUltra` 组一次性抬高 place/route 优化力度

```tcl
set_param place effort               high
set_param place opt_timing           high
set_param place aggressive_opt       21
set_param place aggr_neighbor_dist   5
set_param place enhanced_beeline_opt 3
set_param place timing_driven_mode   on
set_param place crit_path_opt        on
set_param place hfn_opt_effort       high
set_param place post_place_opt       high
set_param route post_route_opt       high
set_param route postrt_opt_extra_round 4
```

**风险**：`hfn_opt_effort high` 与 `crit_path_opt on` 会改写 `rst_n` 的复制策略——**这可能直接改变 `rst_n_dup_*` 的编号和扇出，正好命中本次冲突的两根网**。这条路线比路线 1 更"对症"，但改动面更大、更不可预测。

### 路线 3：砍掉这 11 ps 的 hold 需求本身

11 个 hold 违例的 endpin 全是 **`.sr`（set/reset）引脚**和 **BRAM 的 `addra/addrb` 地址引脚**：
- `rle_lba_q_reg[13]_syn_4.sr`、`u_rle/rd_ptr_reg[0]_syn_16.sr`（都是 `rst_n_dup_53`）
- `u_hdmi_core/.../u_w96_d1024_fifo/u_logic_ramfifo_syn_*.addrb[6]`
- `u_hdmi_core/.../u_w24_d1024_fifo/u_logic_ramfifo_syn_*.addra[11]` / `.addra[4]` / `.addrb[10]`
- `u_gallery/u_fat/data_byte[5]_dup_117` → `u_rle/ramread0_syn_1562.b[1]`
- `u_wav/s_lo[7]` → `u_wav/ramread0_syn_6.dia[7]`

**复位网上的 hold 违例，本质是"复位释放沿到达各触发器的时间差"**。SDC 里 `rst_n` 没有任何约束（全文只有 `create_clock` + `derive_clocks` + `set_clock_groups` + I2C 的 4 条 `set_false_path`）。但**给复位加 false_path 是掩盖问题**——复位释放异步、但释放偏差过大会造成真实的功能竞态（本工程已有"SDRAM 通路自杀式复位"的历史坑）。**不推荐。**

---

## 四、captain 的裁决

1. **驳回方案 A**（`route fix_hold on` 是 no-op，理由见 §二）。
2. **不走路线 3**（给复位加 false_path 属掩盖，违反本工程技术立场）。
3. **按路线 1 → 路线 2 的顺序试**，每趟用 `import_db` 跳过综合（省约 125 s/趟）。
4. **先补齐回归覆盖缺口**（`tb_rle_decoder` / `tb_image_window_mask` 不在任何套件内），这是与本问题无关但同样必须做的修复——`import_db` 用的是 run2 归档里的 gate.db，它对应的是**当前 RTL**（t10 之后无人改 .v，已用 mtime 核实），所以复用合法。
5. **若两轮都不成功**，退回"接受旧位流"并把本轮修复的验证全部落在仿真证据 + 代码审查上，向用户如实说明"新位流未能产出，本轮改动尚未上板"。

---

## 五、`import_db` 复用的合法性与陷阱

**合法性**：`reports/t10_verify_build_20261103_routefail/run2_defaultseed/t7b3_rl45_gate.db`（6,044,558 B）由 run2 在 `optimize_gate` 之后导出，对应 RTL 为当前工作树（t10 完成后 `rtl/` 无人改动，最新 mtime 仍是 t7 的 `21:39`）。`min_ripple_len=45` 已包含在内。

**陷阱（已由仓库历史踩过，见 `project/t7b_seed_full.tcl:78-107`）**：
- `import_db` 之后**必须补 `set_param rtl min_ripple_len 45`**，否则 `commit_param -step place` 会重算 place 参数时失去一致性（该文件注释明写："为了与 t7b_bit3.tcl 的环境一致，不影响结果，但让两次运行的 stdout 可以直接对比"）——**注意它只保证 stdout 可比，不保证结果相同**。
- `import_db` 之后**必须 `commit_param -step place`**，否则新设的 place 参数不会生效（`set_param` 只写进参数表，`commit_param` 才下发到引擎）。
- **参数是否生效必须看产物变化**，不能看 `PASS-set_param`——TD 不校验参数名，`PRJ-1106 : Update wild param ... succeed` 对任何拼写都回 succeed。可用判据：`place.qor` 的 `#slices` / `wire length` / 拥塞三项必须发生变化。

---

## 六、给 verify-build 的第二轮任务要点

| 项 | 内容 |
|---|---|
| 输入 | `run2_defaultseed/t7b3_rl45_gate.db`（不要用 run1 的 seed7 版） |
| 第 0 步 | **先补回归覆盖**：把 `tb_rle_decoder` 加进 `run_storage_regression.ps1`、`tb_image_window_mask` 加进 `run_image_regression.ps1`，各跑一遍确认 PASS，再动 TD |
| 路线 1 | `T7B3_EXTRA='place enable_congestion_recovery on place enhanced_gp on'` |
| 路线 2 | 若路线 1 的 PHY-8023 消失但 WNS 转负，或仍失败：改用 `TimingUltra` 的 `hfn_opt_effort high` + `crit_path_opt on` |
| 判定 | 每趟必须记录：Setup/Hold WNS+TNS+FEP、`#slices`+百分比、`#lut`、`#bram`、Wire length、Over-100% tile 数、是否出现 PHY-8023 |
| 红线 | `#bram` 必须仍为 37；位流必须真更新（记 MD5 与字节数）；不许用 `set_false_path` 掩盖 |
| 纪律 | 不改 RTL/TB 语义、不手工改 SDC、不 commit |
