# SDRAM 域降到 40MHz 的时序收敛验证（2026-10-27）

## 结论

**SiP SDRAM 接口在 40MHz 下完全收敛。**

| 指标 | 150 MHz | 100 MHz | **40 MHz** |
|---|---|---|---|
| Setup WNS | −7.232 ns | −5.565 ns | **+1.935 ns** ✅ |
| Setup TNS | −335.004 ns | −231.925 ns | **0.000 ns** ✅ |
| Hold WNS | +0.019 ns | +0.019 ns | **+0.011 ns** ✅ |
| 读 DQ（clkc[2]→clkc[1]） | −7.232 ns（32 违例） | −5.565 ns（32 违例） | **+1.935 ns（0 违例）** ✅ |
| 写 DQ（clkc[1]→clkc[2]） | −3.537 ns（32 违例） | −2.001 ns（32 违例） | **+5.630 ns（0 违例）** ✅ |
| 内部逻辑域（clkc[1] 自身） | +0.326 ns | +2.604 ns | **+16.706 ns** ✅ |

全部 7 个 path group 违例端点数为 **0**。

## 为什么必须降到 40MHz：与频率无关的常数开销

150MHz 与 100MHz 两次实测的数据点反推出一个线性关系（两点互证）：

```
读路径 slack = T/2 − 10.565 ns     (T = 时钟周期)
写路径 slack = T/2 −  7.001 ns
```

| 频率 | T | T/2 | 读预测 | 读实测 | 写预测 | 写实测 |
|---|---|---|---|---|---|---|
| 150 MHz | 6.666 ns | 3.333 ns | −7.232 | **−7.232** ✓ | −3.668 | **−3.537** ✓ |
| 100 MHz | 10.000 ns | 5.000 ns | −5.565 | **−5.565** ✓ | −2.001 | **−2.001** ✓ |
| 40 MHz | 25.000 ns | 12.500 ns | **+1.935** | **+1.935** ✓ | **+5.499** | +5.630 ✓ |

这个常数里，5.000 ns 是 TD 对 SiP 硬核接口的固定惩罚（`input (hard ip) +5.000` / `output (hard ip) −5.000`），
其余是时钟树偏斜（读路径 Skew 4.172 ns）与封装内走线。**它们不随频率缩放**，
所以降频只能线性地买到 T/2 的增长。由此算出临界频率：

- 读路径需要 `T/2 ≥ 10.565` → `T ≥ 21.130 ns` → **f ≤ 47.33 MHz**（真正的瓶颈）
- 写路径需要 `T/2 ≥ 7.001` → `T ≥ 14.002 ns` → **f ≤ 71.42 MHz**

100MHz 处在两者之上，所以第一次降频后仍然为负；40MHz 留出了充裕余量。

## PLL 配置（VCO 保持 1000MHz 不变）

`rtl/storage/sdram_pll.v` 的 `EG_PHY_PLL` 参数：

| 参数 | 150 MHz（原始） | 100 MHz（第一次） | **40 MHz（最终）** |
|---|---|---|---|
| `REFCLK_DIV` | 4（50/4 = 12.5MHz） | 4 | 4 |
| `CLKC0_DIV` / `CPHASE` | 84 / 83 | 80 / 79 | **80 / 79**（12.5MHz 仅反馈） |
| `CLKC1_DIV` / `CPHASE` / `FPHASE` | 7 / 6 / 0 | 10 / 9 / 0 | **25 / 24 / 0**（40MHz 0°） |
| `CLKC2_DIV` / `CPHASE` / `FPHASE` | 7 / 2 / 4 | 10 / 4 / 0 | **25 / 11 / 4**（40MHz 180°） |
| VCO | 1050 MHz | 1000 MHz | **1000 MHz** |

相位编码公式（从官方 IP Generator 输出反推，两个样本验证）：

```
相位延时 = (CPHASE + 1) + FPHASE/8   个 VCO 周期
相移角度 = 延时 / CLKCx_DIV × 360°
```

- 180° 且 DIV 为偶数：`CPHASE = DIV/2 − 1`，`FPHASE = 0`
- 180° 且 DIV 为奇数：`CPHASE = (DIV−3)/2`，`FPHASE = 4`

40MHz 时 `DIV = 25`（奇数）→ `CPHASE = 11`、`FPHASE = 4`，验证 `(12 + 0.5)/25 = 0.5` → 180° ✓

40MHz 的推导已由 TD 自身确认（构建日志 `USR-1002`）：

```
create_generated_clock -name {u_sdram_pll/pll_inst.clkc[1]} ... -divide_by 1.2500 ...
create_generated_clock -name {u_sdram_pll/pll_inst.clkc[2]} ... -divide_by 1.2500 -phase 180 ...
```

即 50MHz ÷ 1.25 = 40MHz，且 180° 相位被正确识别。

## 连带修改清单

改 `sdram_pll` 频率时必须同步改这三处，否则刷新周期算错或参数不一致：

| 文件 | 改动 |
|---|---|
| [`ip/local/sdram/global_def.v`](../../ip/local/sdram/global_def.v) | `` `SDR_CLK_PERIOD `` → `1000000000/40000000` |
| [`rtl/storage/sdram_ctrl_wrap.v`](../../rtl/storage/sdram_ctrl_wrap.v) | `parameter CLK_FREQ_HZ = 40_000_000` |
| [`rtl/storage/sdram_bringup_top.v`](../../rtl/storage/sdram_bringup_top.v) | `.CLK_FREQ_HZ (40_000_000)` |

刷新自检：`SDR_CLK_PERIOD = 25 ns`，`SELF_REFRESH_INTERVAL = 64000000/25/2048 = 1250` 周期
= 31,250 ns（约 31 µs，远小于 SDRAM 的 64 ms 刷新窗口，安全）。

## 带宽核算

- 需求：640×480@60Hz × 24 位色 = `640 × 480 × 60 × 3 = 55.3 MB/s`
- 供给：40 MHz × 4 字节 = **160 MB/s**
- 富余 **2.9 倍**

## 资源占用（40MHz，`run.area`）

| 资源 | 用量 | 占比 |
|---|---|---|
| LUT | 10,009 / 19,600 | 51.07% |
| 寄存器 | 5,326 / 19,600 | 27.17% |
| LE | 10,849 | — |
| BRAM9K | 17 / 64 | 26.56% |
| DSP | 13 / 29 | 44.83% |
| PLL | 2 / 4 | 50.00% |
| GCLK | 4 / 16 | 25.00% |
| PAD | 45 / 188 | 23.94% |
| IO | 8 in / 33 out / 0 inout | 41 / 188 (21.81%) |

与 100MHz 版几乎一致（LUT 9989→10009、reg 5326→5326），降频不消耗额外资源。

## 约束文件未做任何妥协

[`constraints/dmz_eg4s20_hdmi.sdc`](../../constraints/dmz_eg4s20_hdmi.sdc) 的有效约束**一条都没改**：

```tcl
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
set_clock_groups -asynchronous \
    -group [get_clocks {u_pll/pll_inst.clkc[0] u_pll/pll_inst.clkc[2]}] \
    -group [get_clocks {u_sdram_pll/pll_inst.clkc[1] u_sdram_pll/pll_inst.clkc[2]}]
```

`clkc[1]` 与 `clkc[2]` 仍在**同一组**内，0°/180° 的真实相位关系完整保留。
本次收敛是**真实的物理修复**（降频），不是把路径移出分析视野。

## 已排除的三条捷径

1. **拆异步组**（`set_clock_groups` 把 0°/180° 分开）：能让报告「变好」到 +0.275 ns，
   但那只是把路径移出分析范围，接口本身没修好。仓库历史已有定论，不采用。
2. **加 `set_multicycle_path`**：理论上能放宽 setup 检查，但 Xilinx 的
   [MEGA65](https://raw.githubusercontent.com/MEGA65/mega65-core/f0e74a124c0c66622b49857356376f686614d25a/src/vhdl/mega65r4.xdc)
   工程实测过它反而引入 5.6 ns 无端延迟，属于跨品牌的反噬陷阱。
3. **`phys_opt` 优化**：实测 `-post_place -effort high` 让余量从 +0.275 降到 +0.178 ns，
   `-post_route -effort high` 在 TD v6.2.168116 上直接崩溃（`0xC0000005` 访问违规）。

## 复现方式

```powershell
cd D:\FPGA_Compelate
& D:/TD_6_24_APP/bin/td_commands_prompt.exe `
  D:/FPGA_Compelate/SmartCampusMedia/project/verify_timing_40mhz.tcl
```

产物落在 `reports/timing_40mhz_20261027/`：`run.timing`（745,631 B）、`run.ts`（62 B）、`run.area`（22,526 B）。

脚本本身**不判时序**（时序为负也 `exit 0`），必须读 `run.ts` 判断是否真正收敛。

## 遗留告警（与本次降频无关）

| 告警 | 数量 | 说明 |
|---|---|---|
| `PHY-5079` | **0** | clkc[2] 走 local routing —— 已由 BUFG 修复消除 |
| `USR-6135` | **0** | PLL 反馈走 local network —— 本次运行也已消失 |
| `PHY-7002` | 2 | `u_sdram_sip` 的布局位置约束未被遵守 |
| `SYN-5013` | 2 | `Sdr_init_ref_ba[1]` / `[0]` 未驱动（加密核内部） |
| `ERROR` | **0** | 全程无错误 |
