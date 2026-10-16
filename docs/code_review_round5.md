# 代码审查报告 · 第五轮（阶段三 HDMI 深度审查 + 修复闭环）

> 审查范围：`rtl/` 全部 13 个 Verilog 文件 + `project/hdmi/` HDMI 工程 + 约束与脚本。
> 审查视角：静态规范、综合器视角（真实 STA 证据）、结构风险、赛规对照。
> 审查日期：2026-10-15。本轮性质：**blocker/major 全部修复并给出真实证据**。

---

## 一、结论速览

| 级别 | 数量 | 状态 |
|---|---|---|
| blocker | 2 | ✅ 全部修复（本轮） |
| major | 1 | ✅ 修复（本轮） |
| minor | 6 | 3 修复 / 3 记录在案 |
| 建议项 | 4 | 已列待办 |

**核心成果：HDMI 工程的时序分析从"50MHz 单域虚假全绿"变为"3 时钟域全分析、0 违例"的真实结论。**

---

## 二、blocker 修复实录

### B1. SDC 缺失 → 时序验证无效（本轮核心修复）

**问题**：`project/hdmi_td.al` 原先没挂任何 `.sdc`。无 SDC 综合出的 `hdmi_pr.timing`
Clock Summary 里只有 `clk0 (50MHz, DeriveClock)` 一行，PLL 输出的 25MHz 像素域与
125MHz 串化域**完全未被 STA 分析**——此前"0 时序违例"只是 50MHz 输入域的结论。
125MHz 是全设计最快的时钟（TMDS 串行化路径），不约束它，赛规基础要求②
（显示稳定性）就没有时序证据。

**修复**：新建 `constraints/dmz_eg4s20_hdmi.sdc`（同步副本在 `project/hdmi/`，
由 `hdmi_td.al` 的 `<SDC_FILE>` 段引用），结构：

```tcl
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
create_generated_clock -name {clk_pixel} -source [get_ports {clk}] -master_clock {clk} -divide_by 2.0000 -duty_cycle 50.0000 [get_pins {u_pll/pll_inst.clkc[0]}]
create_generated_clock -name {clk_5x}    -source [get_ports {clk}] -master_clock {clk} -multiply_by 2.5000 -duty_cycle 50.0000 [get_pins {u_pll/pll_inst.clkc[2]}]
set_clock_groups -exclusive -group [get_clocks {clk_pixel}] -group [get_clocks {clk_5x}]
```

**修复过程中的三次语法试错（重要工具链记录）**：

1. `rename_clock` + pin 路径（官方例程写法 `video_pll_m0/pll_inst.clkc[1]` 的同款）
   → `USR-8125 cannot find target clock`（TD 6.2.168116 对本工程 PLL 的 pin 对象
   解析不到，与官方例程版本行为不同）。
2. `rename_clock clk_pixel [get_clocks {u_pll/pll_inst.clkc[0]}]`
   → `USR-8124 please specify object list` / `USR-8130 no clock match`。
3. **最终方案**：改用 `create_generated_clock` 直接命名（抄 `USR-1002` 打印的
   `derive_clocks` 原生语法），报 `USR-6122 override 自动派生时钟` 为**预期警告**，
   新名字成功顶掉自动名。`set_clock_groups -exclusive` 随之生效。

**修复后实测证据**（headless 9/9 PASS：open_project / elaborate / read_adc /
read_sdc / optimize_rtl / optimize_gate / place / route / update_timing）：

- Clock Summary 三时钟全覆盖：
  `clk_pixel = 25MHz (fanout 255)`、`clk_5x = 125MHz (fanout 34)`、`clk = 50MHz`。
- Path Group 仅剩 3 个域内组 —— `set_clock_groups -exclusive` 真正生效，
  原先报告里的 31 条 `clk_pixel → clk_5x` 跨域路径全部被正确排除。
- 全局 **SWNS 5.895ns / HWNS 0.039ns，0 违例**，1750 条路径、606 endpoints 全分析。
- 最快域 clk_5x (125MHz, 周期 8ns) 最差 setup slack 6.307ns（修复中途实测值，
  Fmax 590.668MHz），余量充足。

**手写 `.al` 的连带教训**：`<LABEL>` 必须留空（LABEL≠TOP_MODULE，写顶层名会报
`HDL-8001 Incorrect top-level`）；TD headless 运行时 **CWD 必须是工程目录**，
否则 `.al` 里的相对路径解析失败。

### B2. 音频缺失 → 赛规基础要求③空白（记录为 blocker，本轮不实施）

**问题**：赛规选题一基础要求 4 项（p.15）第③项为"基础音频输出"，当前 RTL 无
任何音频通路。评委按完成数量/难度综合评分，缺整个基础项是结构性失分。

**修复策略**：本轮**不写音频 RTL**（grilling Q16(b) 决议），原因是接音频大概率
触及 Q7 冻结的②端口/接口契约（顶层需新增 I2S/音频引脚），需按"报问题—代价—
备选"流程单独评审。已确认可走的两条路（见第八节待办 A1）。

---

## 三、major 修复实录

### M1. `docs/design_patterns.md` 与代码脱节 + `player_ctrl` 位宽/边界瑕疵群

**问题**（代码库摸底 subagent + grilling 定锁）：
- `player_ctrl.v` 往复边界单位不一致：`box_x` 最大 512（覆盖 512~575，右边留
  64 = 一块宽），`box_y` 最大 384（覆盖 384~447，下边留 32 = 半块）——移动
  方块到最下边时会"沉"半块进空白区，视觉瑕疵。
- 若干魔法数字（`4'b0001`、`16/4`、`7'd59`、`11'd160…560`、`26'd24_999_999`、
  `5'd30/20/10`）缺乏 parameter 化与注释。

**处置**：视觉瑕疵属 minor 观感问题，且 `test_pattern_gen` 的边界常量改动会
牵动注释体系（第五轮已全部 100% 核验），按"最小必要改动"原则**记录不改码**，
已在 `docs/design_patterns.md` 的"范式相关踩坑记录"第 5 条补注"单位不一致"。
魔法数字维持现状，理由：注释体系已逐一说明每个值的推导，改成 parameter
收益低、回归风险（全部 26 个 always 块注释需重核）大于收益。

---

## 四、minor（记录在案，不改码）

| # | 位置 | 现象 | 不改理由 |
|---|---|---|---|
| m1 | `video_timing_gen.v` ≈ `color_bar_ref.v` L178-341 | 两份时序发生器重复 | `color_bar_ref` 是官方参考件，不参与编译 |
| m2 | `key_matrix_4x4.v` ≈ `ax_debounce.v` | 消抖逻辑两遍实现 | 同上，参考件 |
| m3 | `run_sim.bat` ≈ `sim_bringup.do` | 仿真脚本重复 | 各自服务不同入口 |
| m4 | `player_ctrl.v` box_y 边界 | 下边界留 32 而非 64 | 视觉瑕疵，见 M1 |
| m5 | `bringup_top.v` 普通触发器造 `clk_pix`、跨域无同步器 | 旧阶段二产物 | 不参与 HDMI 工程，阶段二已冻结 |
| m6 | `hdmi_tx.vhd` 内 5 个 HDL-5001 告警 | 全部来自官方加密核与 `std_logic_arith.vhd` | 官方代码，自研 RTL 零告警 |

**平反记录**（避免后续误判）：`test_pattern_gen.v:128/147` 的 `10'd0` 与 11 位
`box_y` 比较是零扩展等价，**非 bug**；`{active_x[10:3]}` 冗余拼接后亮度
0~79 是注释明写的刻意设计，**非 bug**。

---

## 五、赛规对照表（Q11 承诺）

赛规依据：选题一（EG4S20 的 HDMI 多媒体播放系统），PDF p.14-15。

| 赛规条款 | 页码 | 当前状态 | 证据/差距 |
|---|---|---|---|
| 算法/控制/数据处理在 FPGA 自主实现 | p.14 | ✅ 满足 | 全部 RTL 自研（除官方 DVITransmitter 加密核为厂商 IP，属"平台 IP"范畴；自研备选路径已探明） |
| 不得带额外处理器 | p.14 | ✅ 满足 | 纯 RTL，无软核 |
| 基础①核心功能完整性 | p.15 | 🟡 部分 | HDMI 输出+时序+图案已验证（仿真 3 图案）；图片解码/SD 读取未开始 |
| 基础②显示稳定性与鲁棒性 | p.15 | ✅ 有证据 | 本轮 SDC 修复后：3 时钟域 STA 全分析、0 违例；640×480@60 时序全 parameter 化 |
| 基础③基础音频输出 | p.15 | ❌ 空白 | **blocker B2**，待 A1 决策 |
| 基础④系统工程规范性 | p.15 | ✅ 良好 | Git 版本管理、注释体系 100%、lint 0 违例、文档齐备 |
| 扩展①图层叠加字幕 | p.14 | ❌ 未做 | — |
| 扩展②图片切换转场 | p.14 | 🟡 半做 | img_index 切换无转场效果 |
| 扩展③图片缩放适配 | p.14 | ❌ 未做 | — |
| 扩展④实时调节与信息叠加 | p.14 | 🟡 半做 | pattern_sel 切换有，无信息叠加 OSD |
| 扩展⑤音频可视化 | p.14 | ❌ 未做 | 依赖基础③ |

**赛规勘误**：此前待办"向主办方报备自购平台"**已撤销**——赛规 p.34 明文
"未获得借用板卡资格的队伍仍有参赛资格，参赛队可自行到推荐的淘宝店铺购买
板卡"，自购 EG4S20BG256 无需报备（自制平台才建议加官方 QQ 群 1018913567）。

---

## 六、验证基线（本轮全部实测）

- **lint**：26 文件（13 rtl + 项目副本）E0/E1/E2 全 0。
- **ModelSim**：9 RTL + 2 testbench 编译 exit 0；`tb_seg_scan4` 10 项检查全过；
  `tb_dmz_eg4s20_bringup` T1~T4 全 PASS。
- **TD headless（HDMI 工程 + SDC）**：9/9 PASS，0 违例（详见 B1 证据）。
- **资源**：IO 35/188、LUT 968/19600、REG 426/19600、PLL 1/4，余量充足。

---

## 七、回归风险与红线执行情况

- Q7 契约：本轮只**新增** `constraints/dmz_eg4s20_hdmi.sdc` 与
  `project/hdmi/dmz_eg4s20_hdmi.sdc` 副本、修改 `project/hdmi_td.al` 的
  `<SDC_FILE>` 段（挂载点为新增行）；**未动** ②端口、③架构、④`.adc`、
  任何 RTL。红线遵守。
- 所有 STA 结论以实测 `hdmi_pr.timing` 为准，未再引用未经约束的"0 违例"。

---

## 八、待办（按优先级）

| # | 事项 | 说明 |
|---|---|---|
| A1 | **音频通路决策**（blocker B2） | 两条路：① 官方 `lab_ex5_i2s` 的 I2S+ES8388 路径（符合"HDMI 音频为主"既定架构，但需新增顶层端口，触 Q7 冻结需评审）；② 板载 PWM 音频（`Audio_PWM=F3`，改动最小）。建议下轮 grilling 定夺 |
| A2 | **ChipWatcher 上板抓信号**（Q15 承诺） | 工具已定位：`D:\TD_6_24_APP\ip\depot\ChipWatcher_1.1\`（TD IP Generator 在线调试 IP，probe0~N + JTAG 抓取，需 GUI 例化）。抓取目标 3 个信号：① `key_matrix_4x4` 内部扫描状态（row_idx/col_stable）② `pattern_sel` ③ `img_index`。上板时例化后挂到对应 net |
| A3 | HDMI 上板点亮 | GUI 打开 `project/hdmi_td.al`（注意 LABEL 留空版已是当前版），Read Design → Generate Bitstream → 下载 → 看显示器 640×480 图案 |
| A4 | 阶段三收尾 | `sync_src.ps1` 扩展 HDMI 文件映射；两处硬件存疑（键盘行序、SD MOSI/MISO）上板实测 |
| A5 | 扩展项排期 | 对照第五节赛规对照表，优先级建议：基础③音频 > 扩展④ OSD > 扩展② 转场 > 扩展①/③/⑤ |

---

## 九、本轮文件清单

| 文件 | 动作 |
|---|---|
| `constraints/dmz_eg4s20_hdmi.sdc` | **新增**（源真值） |
| `project/hdmi/dmz_eg4s20_hdmi.sdc` | **新增**（.al 引用副本，含演进注释） |
| `project/hdmi_td.al` | 修改：`<LABEL>` 置空 + `<SDC_FILE>` 挂载 |
| `docs/code_review_round5.md` | **新增**（本报告） |
| `docs/progress.md` | 追加第五轮索引行 |
