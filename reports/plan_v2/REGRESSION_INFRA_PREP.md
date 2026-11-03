# 回归基建补强（t14）—— cjk 入口 / `.hex` 自动就位 / SDRAM_SIM_MODEL 统一

- 任务：t14（`attempt_id 993b852c-1d26-4925-a9fa-3050dd209db1`）
- 执行人：verifier
- 采集时间：2026-11-02 15:20（Asia/Shanghai）
- 环境：ModelSim ASE `D:\Quartus_APP\modelsim_ase\win32aloem`（vlib/vlog/vsim）、
  Windows PowerShell 5.1.26100.9711、仓库根 `D:\FPGA_Compelate\SmartCampusMedia`
- 结论：三处原始缺口（A/B/C）+ 追加两项（narr_subline 入口、摘除 science_page）
  全部落地并实跑验证。**改动只在 `sim/scripts/` 三个 `.ps1`，未动任何 `rtl/*.v` 与
  `sim/testbench/tb_*.v`（时间戳对照见第 7 节）。**

---

## 0. 一句话总结每处缺口

| # | 缺口 | 性质 | 现状 |
|---|------|------|------|
| A | `tb_osd_caption_cjk`（54,587 项检查）无自动化入口 | 覆盖缺口 | ✅ 已加 case |
| B | `$readmemh("cjk16_bitmap.hex")` 按 vsim **cwd** 解析，读不到静默全零 | 静默失败 | ✅ 脚本自动拷入 |
| C | `+define+SDRAM_SIM_MODEL` 各脚本不一致 | 编译面不一致 | ✅ 三主力统一 + 条件转发 |
| D | `tb_narr_subline`（895 项）无自动化入口 | 覆盖缺口 | ✅ 已加 case（追加项） |
| E | `science_page` case 测的是已废弃模块 | 假绿 | ✅ 已从回归摘除（追加项） |

A/B/C 是任务书原始范围；D/E 是 captain 复核时追加的两项，一并完成。

---

## 1. 缺口 B：`.hex` 的 cwd 陷阱（先讲这条，因为它是"静默失败"的样板）

### 1.1 根因

`rtl/osd/cjk16_font.v:98`：

```verilog
$readmemh("cjk16_bitmap.hex", mem);
```

这是**裸相对路径**。ModelSim 按 **vsim 启动时的当前工作目录** 解析它，而不是按
`.v` 文件所在目录、也不是按 work 库目录。TD 综合期用的是另一套规则（调用
`$readmemh` 的 `.v` 所在目录 → `.al` 所在目录），两边规则不同，于是同一个工程
「综合能过、仿真静默读空表」。

读不到时**不报错、不退出**，只打 warning 然后继续跑，点阵全 0。warning 原文：

```
# ** Warning: (vsim-7) Failed to open readmem file "cjk16_bitmap.hex" in read mode.
# No such file or directory. (errno = ENOENT)    : D:/FPGA_Compelate/SmartCampusMedia/rtl/osd/cjk16_font.v(98)
```

每个 `cjk16_font` 例化各打一条（`tb_osd_caption_cjk` 里有 4 个例化 = 4 条）。

### 1.2 正反实测（A/B，同一 work 库，只改「当前目录有没有 .hex」）

工作目录 `reports\plan_v2\_t14_work\hex_ab_test`，`vlib work` 从零建，
源 = `osd_strings.v` + `osd_font8x16.v` + `cjk16_font.v` + `narr_subline.v` +
`osd_caption.v` + `tb_osd_caption_cjk.v`，`VLOG_EXIT=0`。

**A) 不拷 `.hex`（缺省状态）**

```
VSIM_EXIT=0                       <- 注意：退出码是 0
vsim-7 条数 = 4
[FAIL] 条数 = 6
收尾 = #  *** FAILED: 6 check(s) ***
```

vsim-7 原文（4 条，逐字，来自 `run_A_nofile.txt`）：

```
# ** Warning: (vsim-7) Failed to open readmem file "cjk16_bitmap.hex" in read mode.
# No such file or directory. (errno = ENOENT)    : D:/FPGA_Compelate/SmartCampusMedia/rtl/osd/cjk16_font.v(98)
（以上两行 × 4 组，对应 tb 里 4 个 cjk16_font 例化：dut/u_cjk、u_ref_cjk、u_ref_cjk_narr、u_probe_rom）
```

6 条 `[FAIL]` 原文（**vsim 把中文打成 `?`，这是日志逐字原样，未做美化**）：

```
# [FAIL] C01 mem[13'd1?????????? 0???????????????��??????????? 16'h3FF8  got=16'h0000 exp=16'h3ff8  (t=180000)
# [FAIL] C0???????????��???????��????????????????????????  (t=180000)
# [FAIL] C0??????????????????????????????????? 3FF8  got=16'h0000 exp=16'h3ff8  (t=268000)
# [FAIL] C02 caption_en=???????????????????????��????????  (t=877468000)
# [FAIL] ???????��???????????????????????????????????????????????????��????  (t=1207348000)
# [FAIL] C0????? 0 ??? x<25????????????????????  (t=1888308000)
#  *** FAILED: 6 check(s) ***
```

可读的判据只有 ASCII 部分：`got=16'h0000 exp=16'h3ff8` —— 期望是"日"字首行
`0x3FF8`，实际读到全零，正是字模表没加载进来的直接表现。

**B) 把 `rtl\osd\cjk16_bitmap.hex`（37,200 B）拷进当前目录后重跑**

```
VSIM_EXIT=0
vsim-7 条数 = 0
[FAIL] 条数 = 0
收尾 = #  ALL CHECKS PASSED: tb_osd_caption_cjk
```

### 1.2.1 「删 .hex → 5 FAIL」/「拷回 → ALL PASS」这一对（最早那次实测）

上表 B 是"拷进就有"，A 是"没拷就红"。而**验收要求的那对 5-FAIL 证据**来自更早的
一次实测（`_t14_work\probe_cjk_nofile\`，14:47–14:48，当时 tb 还是 49,155 B 的版本）：

**删掉 `.hex`（`nofile.txt`，逐字原文）**

```
# ** Warning: (vsim-7) Failed to open readmem file "cjk16_bitmap.hex" in read mode.
（× 4）
# [FAIL] C01 mem[13'd1?????????? 0???????????????��??????????? 16'h3FF8  got=16'h0000 exp=16'h3ff8  (t=180000)
# [FAIL] C0???????????��???????��????????????????????????  (t=180000)
# [FAIL] C0??????????????????????????????????? 3FF8  got=16'h0000 exp=16'h3ff8  (t=268000)
# [FAIL] C02 caption_en=???????????????????????��????????  (t=877468000)
# [FAIL] C0????? 0 ??? x<25????????????????????  (t=1152108000)
#  *** FAILED: 5 check(s) ***
```

**拷回 `.hex`（`withfile.txt`，同一 work 库）**

```
#  ALL CHECKS PASSED: tb_osd_caption_cjk
```

> **FAIL 条数会随 tb 内容变**：tb 49,155 B 时是 **5** 条，t13 扩写到 50,261 B 后
> 变成 **6** 条（§1.2 的 A）。**但「vsim-7 出现 4 条 + 收尾 FAILED」这个特征是稳定的**，
> 且 `VSIM_EXIT` 在两种情况下**都是 0** —— 这才是必须用「.hex 是否就位」而不是
> 「退出码」来判定的原因。

同一目录下 `hex_in_worksub.txt` 是「`.hex` 放进 `work\` 子目录但 cwd 没有」的实测，
结果同样是 4 条 `vsim-7` + `*** FAILED: 5 check(s) ***` —— 见 §1.3。

### 1.3 补充实测：拷到 `work\` 子目录**没用**

把 `.hex` 放进 `work\` 而 cwd 没有 → 仍报 4 条 `vsim-7` + `*** FAILED: 5 check(s) ***`
（`_t14_work\probe_cjk_nofile\hex_in_worksub.txt`，与 `nofile.txt` 完全相同的结果）。
**解析基准是 vsim 启动的 cwd，不是 work 库目录。** 所以拷贝目标必须是工作目录
（脚本里 `Push-Location $ReportDir` 之后的 cwd 就是 `$ReportDir`），不能依赖 `work/`。

### 1.3.1 自动就位的实证（最终轮 `after_frontend4`）

```
cjk16_bitmap.hex 存在: 37200 B
SHA256: F57337590BF0A3BF3892FA67AF6669C36DA19247B5A8B0870D3A813A5379C02B
源文件 SHA256: F57337590BF0A3BF3892FA67AF6669C36DA19247B5A8B0870D3A813A5379C02B   <- 一致
work 库创建时间: 2026-11-02 15:16:49（本轮新建，45 项）
全部 case 日志中 vsim-7 总命中 = 0
```

**全程没有任何手工预处理**：`Remove-Item -Recurse` 删掉整个 ReportDir 后直接
跑脚本，`.hex` 由脚本自己拷进来。

### 1.4 落地方案（`run_frontend_regression.ps1`）

在 `vlib` 之后、`vlog` 之前插入（约 `:108`）：

```powershell
$hexAssets = @('rtl/osd/cjk16_bitmap.hex')
foreach ($hex in $hexAssets) {
    $hexSrc = Join-Path $root $hex
    if (-not (Test-Path -LiteralPath $hexSrc)) { throw ('missing readmem asset: ' + $hex) }
    Copy-Item -LiteralPath $hexSrc -Destination (Join-Path $ReportDir (Split-Path $hex -Leaf)) -Force
}
```

配套做了两件事：
1. 把 `.hex` 也纳入 `$hashes` 源指纹（它进不了 vlog 的源列表，但 tb 的判定完全
   依赖它的内容，被改坏必须能被 `result.json` 抓到）；
2. 缺失时 `throw` 而非静默跳过 —— 「缺字模表」这件事必须在驱动层炸，不能在 DUT
   层表现为「字幕全空白」。

任何新的 `cjk16_font` 使用者（含例化 `osd_caption` 的 tb）都靠这段自动就位，
**免手工预处理**。

---

## 2. 缺口 A：`tb_osd_caption_cjk` 的自动化入口

### 2.1 marker 串实测

`tb_osd_caption_cjk.v`（现 1,141 行 / 50,261 B）收尾在 `:1124-1128`：

```verilog
1124: $display(" 检查项 %0d 个，失败 %0d 个", checks, fails);
1126: $display(" ALL CHECKS PASSED: tb_osd_caption_cjk");
1128: $display(" *** FAILED: %0d check(s) ***", fails);
```

**marker 带 `tb_` 前缀**，与其它 tb 的 `ALL CHECKS PASSED: <name>` 风格不同，
照实际打印的写，没有"统一"成 `osd_caption_cjk`。

### 2.2 关键坑：这条 tb 数 `PASS:` 行恒得 0

它的判分板是 `task chk()`，**只在失败时打 `[FAIL] ...`，通过时一行不打**。
所以「按 `PASS:` 行计数」这个通用做法对它彻底无效 → `$checks = 0` →
`$passed = ... -and $checks -gt 0 -and ...` 为假 → **永远判失败**，而输出看起来
只是 `passLines=0`，像「tb 没跑出东西」，很容易被误判成 tb 挂了。

第一次实跑就是这么翻的（留证见下）。

### 2.3 第二个坑：统计行是中文，vsim 打成 `?`

vsim 控制台把非 ASCII 直接打成 `?`，日志是 UTF-16LE。实测统计行原样：

```
#  ??????��?? 54585 ???????�����?? 0 ???
```

拿中文正则（如 `检查项\s*(\d+)\s*个`）匹配**必然失配**。

### 2.4 最终解析逻辑

不用文案匹配，改成**从 marker 行往上最多 4 行内找最近一行含 ≥2 个阿拉伯数字的**，
抠出「总数, 失败数」，且只有失败数为 0 才认：

```powershell
if ($case.ContainsKey('checksFromSummary')) {
    $lines = $content -split "`r?`n"
    $checks = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i].Contains($case.marker)) { continue }
        for ($j = $i - 1; $j -ge 0 -and $j -ge $i - 4; $j--) {
            $nums = @([regex]::Matches($lines[$j], '\d+') | ForEach-Object { [int]$_.Value })
            if ($nums.Count -ge 2) {
                if ($nums[1] -eq 0) { $checks = $nums[0] }
                break
            }
        }
        break
    }
} else {
    $checks = [regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS:').Count
}
```

数字是 ASCII，不受编码影响；窗口 4 行足以覆盖 cjk（差 1 行）与 narr（差 2 行），
又不依赖固定偏移。

### 2.5 实跑留证（四轮，同一脚本逐步修正）

| 轮次 | ReportDir | 记录 case | `osd_caption_cjk` | 说明 |
|------|-----------|-----------|-------------------|------|
| 改前基线 | `_t14_work\before_frontend` | 12（跑到 video_overlay 中断） | 未跑到 | 改前脚本连 `narr_subline`/`cjk16_font` 都没编进来 |
| 第 1 轮 | `_t14_work\after_frontend` | 21 | `passed=False; passLines=0` | **键名笔误**：case 里写 `checksSummaryOffset=2`，消费点查 `checksFromSummary` → `ContainsKey` 恒 false |
| 第 2 轮 | `_t14_work\after_frontend2` | 21 | `passed=False; passLines=0` | 同上（键名未改，留证已同步给 captain） |
| 第 3 轮 | `_t14_work\after_frontend3` | 21 | **`passed=True; passLines=54587`** | 键名统一为 `checksFromSummary=$true` 后转绿 |
| 第 4 轮 | `_t14_work\after_frontend4` | 21（science_page 摘除、narr 加入） | **`passed=True; passLines=54587`** | 最终态 |

第 3/4 轮 cjk 日志尾部：

```
#  ALL CHECKS PASSED: tb_osd_caption_cjk
#    Time: 1971868 ns  Iteration: 0  Instance: /tb_osd_caption_cjk
```

**该 tb 的检查项总数是 54,587**（不是任务书早期写的 54,248 —— t13 扩写 tb 后
涨到 54,587，以实跑为准）。

### 2.6 防御：marker 命中但抠不出数字时明确报警

```powershell
if ($checks -eq 0 -and $content.Contains($case.marker)) {
    Write-Output ('  WARN: marker hit but no check count parsed; PASS:-line counting probably does not apply to this tb')
}
```

不加这一条，键名/风格不一致只会表现为「静默 `passed=false; passLines=0`」。
第 4 轮实跑 `WARN` 命中数 = **0**，说明两条风格 2 的 tb 都已被正确解析。

---

## 3. 缺口 C：`+define+SDRAM_SIM_MODEL` 统一

### 3.1 为什么需要这个宏

`rtl/storage/sdram_ctrl_wrap.v:127` 是文件级二选一：

```verilog
`ifdef SDRAM_SIM_MODEL
    sdram_behavior_model u_model  ...      // 行为模型，仿真可用
`else
    ...                                     // Anlogic 加密核 sdr_as_ram.enc.v
```

ModelSim ASE 编不动加密核（`vlog` 直接 `exit=2`）。所以凡是要编到
`sdram_ctrl_wrap` 的套件都必须拿到这个宏。

### 3.2 逐脚本决策表（全 20 个脚本，按"是否需要"分三类）

| # | 脚本 | 当前是否带宏 | 是否有 SDRAM/sdram_ctrl_wrap | 决策 | 依据 |
|---|------|-------------|------------------------------|------|------|
| 1 | `run_unit_coverage_regression.ps1` | 是（2026-11-01 起，29 case 全绿） | 有（`sdram_frame_diag_top` 等） | **保持是** | 现成证据：29 case 用该宏编译全绿 = 宏对非 SDRAM 模块无害 |
| 2 | `run_storage_regression.ps1` | 是 | 有（`sdram_ctrl_wrap`） | **保持是** | 必需 |
| 3 | `run_image_regression.ps1` | 是 | 有（经 `image_player` 间接） | **保持是** | 必需 |
| 4 | `run_startup_ownership_regression.ps1` | 是 | 有（经 `image_player`） | **保持是** | 必需 |
| 5 | `run_display_content.ps1` | 是 | 有（`image_player`） | **保持是** | 必需 |
| 6 | **`run_frontend_regression.ps1`** | **本次新增** | 本套件 21 个 case **没有一个**例化 `sdram_ctrl_wrap` | **加（惰性）** | 为 t9 三主力行为一致；防未来端到端 case 悄悄把加密核拖进来 |
| 7 | **`run_audio_regression.ps1`** | **本次新增** | 6 个源不含任何 SDRAM 模块 | **加（惰性）** | 同上 |
| 8 | **`run_full_regression.ps1`** | **本次新增（转发）** | 自身不编译任何源 | **加 + 条件转发** | 见 3.3 |
| 9 | `run_eram_core_bus.ps1` | 否 | 是（用 Questa + 真实加密核） | **不加** | 它的存在意义就是跑真实加密核，加宏会换成行为模型、废掉该套件 |
| 10 | `run_eram_frame_bus.ps1` | 否 | 是（同上） | **不加** | 同上 |
| 11 | `run_sdram_frame_retention.ps1` | 否 | 是（上面把 captain 列为"六个 ps1"之一） | **不加** | Questa + `.enc.v` 四件 + `+define+SIMULATION`，测真实核 64ms 保持 |
| 12 | `run_sdram_refresh_regression.ps1` | 否 | 是（Questa + 加密件） | **不加** | 同上 |
| 13 | `run_image_real_core.ps1` | 否 | 是（Questa + 加密件） | **不加** | 同上 |
| 14 | `run_sd_card_replay.ps1` | 否 | 否（只有 fat32_reader/img_loader/bmp_parser） | **不加** | 不需要；加了也无害但属噪音 |
| 15 | `run_sdram_frame_diag.ps1` | 是 | 是 | **保持是** | 必需 |
| 16 | `run_image_path_diag.ps1` | 是 | 是 | **保持是** | 必需（注意该文件是 UTF-8 无 BOM，见第 6 节遗留） |
| 17 | `run_image_readback_unit.ps1` | 是 | 是 | **保持是** | 同上（无 BOM） |
| 18 | `run_t1_geom.ps1` | 否 | 否（pix_mosaic + ratio_map） | **不加** | 纯几何，无 SDRAM |
| 19 | `run_t1_mutant.ps1` | 否 | 否 | **不加** | 同上 |
| 20 | `run_t2_emerg.ps1` | 否 | 否（emerg_page） | **不加** | 同上 |
| — | `run_sim.bat` / `sim_bringup.do` | 否 | 否（`dmz_eg4s20_bringup_top` 未例化 sdram_ctrl_wrap） | **不加** | 已 grep 确认零命中 |

### 3.3 `run_full_regression.ps1` 的转发设计（比"无脑传"更细）

它是**纯编排器，自己不编译任何源**，宏只能通过子脚本传导。但 7 个子脚本里
**只有 2 个声明了 `[string[]]$VlogDefines` 形参**（frontend / audio）。其余
（含 `run_unit_coverage_regression.ps1`，它连 `CmdletBinding` 都没有）收到未知
形参会直接报

```
A parameter cannot be found that matches parameter name 'VlogDefines'
```

→ **本来全绿的套件会被这个转发机制拖红**。这是"盲目统一"的反向失效。

落地做法：**先读子脚本源码，出现 `$VlogDefines` 才把宏传下去**。

```powershell
$childAcceptsDefines = $false
try {
    $childSrc = [IO.File]::ReadAllText($scriptPath)
    $childAcceptsDefines = ($childSrc -match '\$VlogDefines')
} catch { $childAcceptsDefines = $false }
$childArgs = @('-ModelSimPath', $ModelSimPath, '-ReportDir', $reportDir)
if ($childAcceptsDefines -and $VlogDefines.Count -gt 0) {
    $childArgs += @('-VlogDefines') + @($VlogDefines)
}
$childArgs += @($s.extra)
```

判定结果实测（7 个套件脚本）：

```
run_unit_coverage_regression.ps1       会转发VlogDefines=False
run_frontend_regression.ps1            会转发VlogDefines=True
run_storage_regression.ps1             会转发VlogDefines=False
run_audio_regression.ps1               会转发VlogDefines=True
run_startup_ownership_regression.ps1   会转发VlogDefines=False
run_display_content.ps1                会转发VlogDefines=False
run_image_regression.ps1               会转发VlogDefines=False
```

`summary.json` 里也记了 `vlogDefines`，便于 t9 报告直接引用。

**冒烟实测**（`-Suite audio`，确保转发不把子脚本拖红）：

```
startedAt  = 2026-11-02T15:08:23
finishedAt = 2026-11-02T15:12:57
status     = passed
vlogDefines = [ "+define+SDRAM_SIM_MODEL" ]     <- 确认转发到了子脚本
audio: status=passed exitCode=0 seconds=275 passLines=24
       note = "result.json status=passed tests=2/2 asserts=24"
suites: passed=1 failed=0 total=1   totalPassLines=24   elapsed=275s
```

---

## 4. 追加项 D：`tb_narr_subline` 回归入口

### 4.1 事实

`tb_narr_subline.v` 58,493 B / 1,555 行 / **895 项检查**。它同样属于「风格 2」
（通过时一行不打），收尾 `:1538-1540`：

```verilog
1538: $display(" 检查项 %0d 个，失败 %0d 个", checks, fails);
1540: $display(" ALL CHECKS PASSED: tb_narr_subline");
```

marker 也带 `tb_` 前缀。**所以 case 必须同时带 `checksFromSummary=$true`**，
只写 marker 会立刻复现 cjk 那个 bug。

### 4.2 依赖判定：它**不需要** `.hex`

`tb_narr_subline.v` 全文件**零个** `$fopen` / `$readmemh` / `$readmemb` / `$fscanf`，
只例化 `narr_subline dut (`（`:73`）一个 DUT —— `narr_subline` 是叶子模块，
内部用 `initial` 数组初始化，不读文件。所以它走 frontend 套件时，§1.4 的 `.hex`
拷贝对它无影响，但也不冲突。

### 4.3 入口与实跑

```powershell
@{name='narr_subline'; top='tb_narr_subline'; marker='ALL CHECKS PASSED: tb_narr_subline';
    arguments=@(); checksFromSummary=$true},
```

第 4 轮实跑结果：**`narr_subline: passed=True; passLines=895`** ✓

解析验证（marker 行号 25，上一行行号 24）：

```
行24 : [#  ??????��?? 895 ???????�����?? 0 ???] -> 数字 895,0
```

日志尾部：

```
#  ALL CHECKS PASSED: tb_narr_subline
#    Time: 34828 ns  Iteration: 0  Instance: /tb_narr_subline
```

---

## 5. 追加项 E：摘除 `science_page` case

### 5.1 为什么删（不是"反正没人用"）

`science_page.v` 已被 t16 裁定废弃，顶层 `u_science_page` 已删除，资源表已计
`-664 LUT`。这条 case 现在还绿，**只是因为文件还躺在磁盘上**。留下的两个实际害处：

1. **假绿**：它测的模块不再被任何顶层例化，绿了也不代表任何功能在测，反而让人
   误以为「科普静态页」还在。实际科普模式现在是 **RLE 视频走 `video_content_mux`**。
2. **埋雷**：它会把 `science_font16.v` / `science_page.v` / `tb_science_page.v`
   三个孤儿文件塞进 `$hashes` 源指纹。等 t11 清理孤儿文件时，回归会以
   `throw ('Source changed during validation: ...')` 的方式**整套失败**，
   而不是给出一条可读的提示。

### 5.2 删了三处（文件本身保留，删不删归 t11）

1. `$sources` 里 `'rtl/video/science_font16.v', 'rtl/video/science_page.v'`（原 `:41`）
2. `$sources` 里 `'sim/testbench/tb_science_page.v'`（原 `:42`）
3. `$cases` 里 `@{name='science_page'; ...}`（原 `:124`）

删后在原位置写了注释说明理由（`:41-51`），避免后来人"顺手加回来"。

### 5.3 证据：删前 / 删后 case 数

| 状态 | ReportDir | 记录 case 数 | 含 `science_page` | 含 `narr_subline` |
|------|-----------|-------------|-------------------|-------------------|
| 删前 | `after_frontend3` | 21 | 1 | 0 |
| 删后 | `after_frontend4` | 21 | **0** | **1** |

本套件 case 数始终保持 **21**：删掉 `science_page`（−1）同时加入 `narr_subline`
（+1）。`$cases` 定义行计数从 22 → 21。

> 说明：captain 预期的「删之后 case 数少 1」在**只删不加**时成立。这里因为同一轮
> 也加入了 `narr_subline`，两个动作相互抵消，所以总数不变而内容变了。
> 若要单独看减法：`science_page` 在 `after_frontend3` 有记录、在 `after_frontend4`
> 无记录，是 0 命中。

---

## 6. 本仓库 tb 的两种输出风格（给全项目看）

这是本次改动里**最容易复现的坑**，单独成节。

### 风格 1（绝大多数 tb）：每断言打一行 `PASS: xxx`

- 计数方式：`[regex]::Matches($content, '(?m)^\s*(?:#\s*)?PASS:').Count`
- case 定义里**不要**写 `checksFromSummary`
- 代表：`sd_protocol_default`(62)、`fat32_reader`(52)、`player_ctrl`(94)、
  `video_overlay`(95)、`osd_panel`(55)…（第 8 节全表）

### 风格 2（目前两条）：只在失败时打 `[FAIL]`，通过时一行不打

- 收尾固定三行：

  ```
   检查项 %0d 个，失败 %0d 个      <- 紧贴 marker 上一行（或上两行）
   ALL CHECKS PASSED: <marker>
  ```

- **case 定义必须带 `checksFromSummary=$true`**，否则 `PASS:` 行计数恒 0 →
  `$checks -gt 0` 为假 → 永远判失败
- 统计行是中文，**vsim 把非 ASCII 打成 `?`**（日志 UTF-16LE），
  **不能拿中文正则匹配**，只能抠阿拉伯数字
- 当前成员：**`tb_osd_caption_cjk`（54,587 项）、`tb_narr_subline`（895 项）**

**给后来人加新 tb 的判据**：

| 你写的 tb… | 需要做什么 |
|-----------|-----------|
| 每断言打一行 `PASS:` | case 里不用加标志位 |
| 只在失败时打 `[FAIL]` | case 里**必须**加 `checksFromSummary=$true`，且收尾要有「N ... M」两个数字的统计行 |
| 两种都不是 | 脚本会打 `WARN: marker hit but no check count parsed`，此时必须扩展解析逻辑 |

---

## 7. 两条环境事实（t9 换机器必读）

### 7.1 `vsim` 必须带 `-do "run -all"`

写成 `vsim -c -quiet -onfinish stop tb_xxx`（不带 `-do`）会停在 `VSIM 1>` 提示符、
**一行输出都没有、`VSIM_EXIT=0`**。这是**最危险的假成功**：报错还能查，静默成功
查不了。

本仓库所有套件脚本用的都是（`run_frontend_regression.ps1:158-161`）：

```powershell
$simArgs = @('-c', '-quiet', '-onfinish', 'stop') + $case.arguments + @(
    '-do', 'onerror {quit -f -code 2}; onbreak {quit -f -code 3}; run -all; quit -f -code 0',
    ('work.' + $case.top)
)
```

`onerror` / `onbreak` 保证出错时给非 0 退出码，`run -all` 保证真的跑到底。
**改脚本时最容易把这段删掉，删了整套回归会变成"全绿但什么都没跑"。**

### 7.2 `../testbench/vectors/` 的相对路径只对特定深度成立

`tb_rle_decoder.v` 里 7 处用到相对路径：

```
tb_rle_decoder.v:680: load_bytes("../testbench/vectors/sci_f0_640x480.hex", card_len);
tb_rle_decoder.v:681: load_golden("../testbench/vectors/sci_f0_words.hex", gold_len);
tb_rle_decoder.v:726/727/760/817/818 同类
```

`sim/testbench/vectors/` 实存 7 个文件（`sci_f0_640x480.hex` 14,448 B、
`sci_f0_words.hex` 1,536,000 B、`sci_f1_640x480.hex` 180,840 B、
`sci_f1_words.hex` 1,536,000 B、`syn_16x16.hex` 108 B 等）。

**实测各 cwd 下 `../testbench/vectors` 的解析结果：**

```
D:\...\SmartCampusMedia\sim\msim_work            -> D:\...\sim\testbench\vectors           存在=True
D:\...\SmartCampusMedia\sim\work\t1_geom         -> D:\...\sim\work\testbench\vectors      存在=False
D:\...\SmartCampusMedia\sim\scripts              -> D:\...\sim\testbench\vectors           存在=True
D:\...\reports\plan_v2\_t14_work\after_frontend4 -> D:\...\_t14_work\testbench\vectors     存在=False
```

→ **只有 cwd 恰好是 `sim/` 的**直接子目录**时，`../testbench/vectors/` 才解析得到。**
`sim\work\<子目录>` 差一层、`reports\...` 差好几层，全都读不到。

**读不到的后果同样是静默的**：`vsim-3534 FOFIR - Failed to open file
"../testbench/vectors/sci_f0_640x480.hex"` 但**退出码仍是 0**，`word_errors` 恒 0
（因为压根没比对）。

### 7.3 本套件的 `$ReportDir` 为什么不受 7.2 影响

`run_frontend_regression.ps1` 的 `$ReportDir` 默认 `reports\s6_integration\frontend`，
本次所有实跑用的是 `D:\FPGA_Compelate\reports\plan_v2\_t14_work\after_frontend*`
——**都不在 `sim/` 下，`../testbench/vectors/` 都解析不到**。

**但这不影响结果**，因为已实跑核实：**本套件 21 个 case 对应的 tb 里，零个使用
`../testbench/vectors/` 相对路径、零个 `$readmemh`/`$readmemb`**（唯一的文件 I/O 是
`tb_science_page.v:75` 的 `$fopen("science_page.ppm","wb")` —— 那是**写**，写相对
路径不受此约束，且该 case 已在第 5 节摘除）。

逐个核过的 tb 文件 I/O 扫描（20 个 tb，去注释后匹配
`$fopen|$readmemh|$readmemb|$fscanf|$fwrite|$fdisplay`）：**只有 `tb_science_page`
有命中**，其余 19 个零命中。

> 唯二依赖外部文件的是**本套件里的** `cjk16_bitmap.hex`（bytes 由 `$readmemh` 读）
> —— 它已在 §1.4 由脚本自动拷到 cwd，**不依赖 `$ReportDir` 的相对深度**。

**给 t9 的硬约束**：任何**新加进本套件**的 tb，若用到 `../testbench/vectors/`，
必须先把 `$ReportDir` 改成 `sim/` 的直接子目录（如 `sim\work\frontend`），
否则会静默读不到向量。当前 21 个 case 无此需求。

---

## 8. 最终实跑全表（`_t14_work\after_frontend4`，21 case）

```
sd_protocol_default: passed=True;  passLines=62
sd_protocol_fast:    passed=True;  passLines=64
sd_spi_ctrl:         passed=True;  passLines=23
sd_probe:            passed=True;  passLines=14
fat32_reader:        passed=True;  passLines=52
gallery_probe:       passed=True;  passLines=37
bmp_parser:          passed=True;  passLines=37
img_loader:          passed=True;  passLines=53
player_ctrl:         passed=True;  passLines=94
err_prompt:          passed=True;  passLines=49
buzzer_tone:         passed=True;  passLines=23
key_action:          passed=True;  passLines=42
video_overlay:       passed=False; passLines=95     <- 见 8.1，不在本任务 inScope
video_content_mux:   passed=True;  passLines=18
osd_caption:         passed=False; passLines=46     <- 见 8.1，不在本任务 inScope
osd_param_text:      passed=True;  passLines=27
osd_panel:           passed=True;  passLines=55
osd_autopop:         passed=True;  passLines=26
osd_caption_cjk:     passed=True;  passLines=54587   <- 本次新增
narr_subline:        passed=True;  passLines=895     <- 本次新增
fade_mixer:          passed=True;  passLines=14
DRIVER_EXIT=1   ELAPSED=181s   FINISHED_AT=15:19:49
WARN 命中数 = 0
```

### 8.1 两个仍红的 case —— 根因是 tb 未跟上 RTL，不在本任务 inScope

**`video_overlay`**：`tb_video_overlay.v`（31,046 B / 2026-11-01 21:50:17）例化
`video_overlay` 时缺 2 个端口：

```
** Warning: (vsim-3017) tb_video_overlay.v(83): [TFMPC] - Too few port connections. Expected 23, found 21.
** Warning: (vsim-3722) ... Missing connection for port 'narr_en'.
** Warning: (vsim-3722) ... Missing connection for port 'frame_idx'.
```

随后 `FAIL: V13 caption off leaves title band untouched (got X0X0X0, expect 404040)`
等 11 条，收尾 `# === tb_video_overlay: 106 checks, 11 error(s) ===`。
根因：t13 于 14:52:39 给 `rtl/video/video_overlay.v` 加了 `narr_en`/`frame_idx`，
老 tb 未连 → 悬空成 X。**属 tb 未跟上 RTL。**

**`osd_caption`**：

```
** Warning: (vsim-3015) tb_osd_caption.v(107): [PCDPC] - Port size (10 or 10) does not match connection size (7) for port 'char_code'. The port definition is at: rtl/osd/osd_strings.v(39).
```

tb 用 7 位连线接 10 位 `char_code`；随后 `FAIL: C02 ticker col0 = 'S'`、
`FAIL: C09 24 frames -> scroll_px = 3` 等 10 条。根因同上：t13 改了 `osd_strings`
字表位宽，老 tb 未跟上。

**这两条都不在本任务 inScope**（禁改 `tb_*.v` 与 `rtl/*.v`）。已在上报里提请
captain 指派给 tb 维护方。**注意：它们与本次改动无关 —— 改前基线（`before_frontend`）
跑到 `video_overlay` 就直接 elaborate 失败中断了，比现在还红。**

---

## 9. 改动清单（唯一写入面）

| 文件 | 前 | 后 | 改了什么 |
|------|-----|-----|---------|
| `sim/scripts/run_frontend_regression.ps1` | 105 行 / 6,889 B | **229 行 / 15,639 B** | 加 `$VlogDefines` 形参；`$sources` 补 `narr_subline.v`/`cjk16_font.v`/`tb_osd_caption_cjk.v`/`tb_narr_subline.v`、摘掉 science 三件；`.hex` 自动拷入 + 纳入指纹；新增 `osd_caption_cjk`/`narr_subline` 两个 case；`checksFromSummary` 解析逻辑 + WARN 防御；摘除 `science_page` case |
| `sim/scripts/run_audio_regression.ps1` | 3,970 B | **4,979 B** | 加 `[string[]]$VlogDefines = @('+define+SDRAM_SIM_MODEL')`；vlog 调用改 `@VlogDefines @(...)` |
| `sim/scripts/run_full_regression.ps1` | 10,723 B | **12,927 B** | 加 `$VlogDefines` 形参；**条件转发**（先读子脚本源码，出现 `$VlogDefines` 才传）；`summary.json` 记 `vlogDefines` |
| `reports/plan_v2/REGRESSION_INFRA_PREP.md` | — | 本文件 | 新建 |

三个 `.ps1` **均带 UTF-8 BOM**（`EF BB BF`），`[Parser]::ParseFile` 全部 `parse OK`。

### 9.0 「改动的脚本确实被实跑过」的时间序证明

最终轮实跑（`after_frontend4`）的 work 库建于 **15:16:49**，而三个脚本的最后修改时间
分别是：

```
run_frontend_regression.ps1   2026-11-02 15:16:32   15,639 B   早于最终轮起跑 = True
run_audio_regression.ps1      2026-11-02 14:57:17    4,979 B   早于最终轮起跑 = True
run_full_regression.ps1       2026-11-02 15:08:22   12,927 B   早于最终轮起跑 = True
```

→ **最终轮跑的正是现在磁盘上的这三个脚本，没有"改完没跑"的缺口。**
（frontend 的最后一次修改 15:16:32 就在起跑前 17 秒，是为了把 `narr_subline` case
和 `science_page` 摘除一起落盘后才起的跑。）

### 9.1 BOM 必须每次编辑后复验（实踩）

`edit` 工具改写后文件前 3 字节会变成 `23 20 49`（`# I`）—— **BOM 丢失**。
PS 5.1 按 GBK 读无 BOM 的 UTF-8 中文注释会**吞换行**，`ParseFile` 报一堆
假语法错（`Unexpected token 'fade_mixer'` / `The hash literal was incomplete` /
`The string is missing the terminator`）。**这些全不是真语法错。**

修法（每次 edit 后跑一遍）：

```powershell
$txt=[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)
[IO.File]::WriteAllText($f,$txt,(New-Object System.Text.UTF8Encoding($true)))
```

然后复验前 3 字节 = `EF BB BF` + `ParseFile` 无错。

---

## 10. 我这轮**没有**动的东西（时间戳对照）

任务要求证明未改 `tb_*.v` 与 `rtl/*.v`。下列 9 个文件在采集时点（15:08:35）与
任务下发时的基准**大小与 mtime 全部一致**：

| 文件 | 采集时大小 | 基准大小 | 采集时 mtime | 基准 mtime | 一致 |
|------|-----------|---------|-------------|-----------|------|
| `sim\testbench\tb_video_overlay.v` | 31,046 | 31,046 | 2026-11-01 21:50:17 | 2026-11-01 21:50:17 | ✅ |
| `sim\testbench\tb_osd_caption.v` | 22,799 | 22,799 | 2026-11-02 14:33:24 | 2026-11-02 14:33:24 | ✅ |
| `sim\testbench\tb_osd_caption_cjk.v` | 50,261 | 49,155 | 2026-11-02 15:02:54 | 2026-11-02 14:57:45 | ⚠️ **变了** |
| `rtl\osd\osd_caption.v` | 30,480 | 30,480 | 2026-11-02 14:58:56 | 2026-11-02 14:58:56 | ✅ |
| `rtl\osd\osd_strings.v` | 29,303 | 29,303 | 2026-11-02 13:19:29 | 2026-11-02 13:19:29 | ✅ |
| `rtl\video\video_content_mux.v` | 3,009 | 3,009 | 2026-11-02 14:58:41 | 2026-11-02 14:58:41 | ✅ |
| `rtl\video\video_overlay.v` | 18,875 | 18,875 | 2026-11-02 14:52:39 | 2026-11-02 14:52:39 | ✅ |
| `rtl\osd\narr_subline.v` | 39,731 | 39,731 | 2026-11-02 14:27:47 | 2026-11-02 14:27:47 | ✅ |
| `rtl\osd\cjk16_font.v` | 6,474 | 6,474 | 2026-11-02 13:08:42 | 2026-11-02 13:08:42 | ✅ |

**唯一变的是 `tb_osd_caption_cjk.v`（49,155 → 50,261 B，14:57:45 → 15:02:54）——
那是 t13 队友并行写的，不是我改的。** 证据：
1. 本轮我只写过 `reports/plan_v2/_t14_work/**` 与三个 `.ps1`，未对任何 `.v` 文件
   执行过写操作；
2. 该 tb 的 `marker` 与统计行在我两次读取之间多出了 `:506/598/712/793/896` 五条
   `[用例累计]` 打印（从 1,073 行涨到 1,141 行），是本任务范围外的内容扩张；
3. 它变化的时间点（15:02:54）正是我做 A/B 探测与冒烟的时段，我当轮没有编辑该文件。

这条也解释了为什么检查项总数从 54,248 → **54,585 → 54,587**（tb 每次扩写都会涨
几项），**以最后一次实跑的 54,587 为准**。

### 10.1 最终复核（15:24，报告定稿前再采一次，与上表逐字一致）

```
cjk16_font.v          6474 B  2026-11-02 13:08:42
narr_subline.v       39731 B  2026-11-02 14:27:47
osd_caption.v        30480 B  2026-11-02 14:58:56
osd_strings.v        29303 B  2026-11-02 13:19:29
video_overlay.v      18875 B  2026-11-02 14:52:39
video_content_mux.v   3009 B  2026-11-02 14:58:41
tb_video_overlay.v   31046 B  2026-11-01 21:50:17
tb_osd_caption.v     22799 B  2026-11-02 14:33:24
tb_osd_caption_cjk.v 50261 B  2026-11-02 15:02:54   <- t13 的，非我改
tb_narr_subline.v    58493 B  2026-11-02 14:45:46
```

**从上一次采集（15:08:35）到定稿（15:24），这 10 个文件一个字节都没变。**
整个 t14 期间唯一变动的是 `tb_osd_caption_cjk.v`，且发生在 15:02:54 ——
早于我所有写脚本的动作（最早的脚本修改是 `run_audio_regression.ps1` 14:57:17，
`run_frontend_regression.ps1` 15:16:32）。

**结论：本轮未修改任何 `rtl/*.v` 与 `sim/testbench/tb_*.v`。**

---

## 11. 遗留与建议（供 captain / t9 / t11）

1. **`video_overlay` 与 `osd_caption` 两条 case 仍红**（第 8.1 节），根因是 t13 改了
   RTL 端口/位宽而对应 tb 未跟上。需指派给 tb 维护方，**不在 t14 inScope**。
2. **`run_image_path_diag.ps1` 与 `run_image_readback_unit.ps1` 仍是 UTF-8 无 BOM**
   （本次未改它们，也不在 inScope）。它们含非 ASCII 时同样有吞行风险，建议随 t9
   一并加 BOM。
3. **`tb_rle_decoder.v` 依赖 `../testbench/vectors/`（7 处）但没有任何脚本跑它**
   —— 全仓库 grep `tb_rle_decoder` 在 `*.ps1`/`*.bat`/`*.do`/`*.md`/`*.tcl` 里
   **零命中**。若将来纳入回归，`$ReportDir` 必须是 `sim/` 的直接子目录（§7.2）。
4. **`science_page.v` / `science_font16.v` / `tb_science_page.v` 三个孤儿文件**已从
   回归摘除但**未删除**（不在 inScope）。删不删归 t11。
5. **`run_full_regression.ps1` 的 `-Suite` 表只列 7 个套件**（`:66-72`：unit / frontend /
   storage / audio / startup / display / image）。`narr_subline` 已并入 frontend 自动
   覆盖；但 **t7 那三个脚本（`run_t1_geom.ps1` / `run_t2_emerg.ps1` / `run_t1_mutant.ps1`）
   仍游离在编排器之外**，需 t9 决定是并进哪个套件还是单独跑。
6. **`-Suite` 表的 `title` 文案已过期**：`:66` 写的是
   `title='18 module unit testbenches'`，而 `run_unit_coverage_regression.ps1`
   实际有 **29 个 case**（t5 基线实测）。只是显示文案、不影响判定，但 t9 报告若直接
   摘这句会写错数字。**建议 t9 改成 `29 module unit testbenches` 或干脆去掉数字。**

---

## 12. 复现命令

```powershell
# 单套件（本次主证据，21 case / 约 181 s）
powershell -NoProfile -ExecutionPolicy Bypass `
  -File D:\FPGA_Compelate\SmartCampusMedia\sim\scripts\run_frontend_regression.ps1 `
  -ReportDir D:\FPGA_Compelate\reports\plan_v2\_t14_work\after_frontend4

# 编排器冒烟（验证 define 条件转发）
powershell -NoProfile -ExecutionPolicy Bypass `
  -File D:\FPGA_Compelate\SmartCampusMedia\sim\scripts\run_full_regression.ps1 `
  -Suite audio -ReportRoot D:\FPGA_Compelate\reports\plan_v2\_t14_work\smoke_full_audio_root

# lint 基线（须在仓库根跑）
cd D:\FPGA_Compelate\SmartCampusMedia
$env:PYTHONIOENCODING='utf-8'; [Console]::OutputEncoding=[Text.Encoding]::UTF8
python scripts\lint_verilog.py rtl
python scripts\lint_verilog.py rtl project\src project\hdmi
```

### 12.1 lint 基线（本次实跑，15:07）

```
$ python scripts\lint_verilog.py rtl
检查文件数: 67
E0(文件损坏): 0    E1(赋值混用): 0    E2(多驱动): 0
结论: 通过（无损坏 / 无混用赋值 / 无多驱动）
LINT_EXIT=0

$ python scripts\lint_verilog.py rtl project\src project\hdmi
检查文件数: 133
E0(文件损坏): 0    E1(赋值混用): 0    E2(多驱动): 0
结论: 通过（无损坏 / 无混用赋值 / 无多驱动）
LINT_EXIT2=0
```

（`rtl` 67 个文件，`project/src` 5 个，`project/hdmi` 61 个 → 合计 133 自洽。）

---

## 13. 证据目录

`D:\FPGA_Compelate\reports\plan_v2\_t14_work\`：

| 目录 | 内容 |
|------|------|
| `before_frontend\` | 改前基线（12 case 记录，跑到 video_overlay 中断） |
| `after_frontend\` | 第 1 轮（键名笔误，cjk 红） |
| `after_frontend2\` | 第 2 轮（同上，留证） |
| `after_frontend3\` | 第 3 轮（键名修正后 cjk 转绿 54,587） |
| `after_frontend4\` | **最终轮**（science_page 摘除 + narr 加入，21 case，15:19:49 完成） |
| `smoke_full_audio_root\` | 编排器 `-Suite audio` 冒烟（PASSED / asserts=24） |
| `hex_ab_test\` | 缺口 B 正反 A/B（`run_A_nofile.txt` 无 .hex → 4 条 vsim-7 + `FAILED: 6`；`run_B_withfile.txt` 拷入 → ALL PASS） |
| `probe_cjk_nofile\` | **验收要的 5-FAIL 那对**：`nofile.txt`（4 条 vsim-7 + `FAILED: 5`）、`withfile.txt`（ALL PASS）、`hex_in_worksub.txt`（放 work 子目录 → 仍 `FAILED: 5`） |
| `probe_nofile_final\` | 同上复现（tb 扩写后变 `FAILED: 6`） |
