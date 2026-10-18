# 会话交接（2026-10-19 00:15）

> **为什么有这份文档**：原会话 `session-51d92e05` 累计 10816 条事件、解压文本 39.7MB、
> 压缩后仍约 564K token。每次请求需重发接近 1M token 的上下文，任何 provider 都会
> 在 5 分钟流空闲超时内吐不出首字（已实测 deepseek 官方与 coco-gpt 均卡死）。
> 上下文压缩 441 次启动仅 2 次成功，已无法自愈。**本会话作废，新会话以本文件开局。**

---

## 一、交接时必须知道的三件事

1. **代码进度没有丢**。最近一轮 SD 修复已在 `460163e` 提交，工作区干净（仅剩 18MB
   的 `reports/sd_spi_review_before.json` 未跟踪，那是审查工具快照，不要提交）。
2. **`project/hdmi_td.al` 被还原过一次**。会话末段 TD 打开工程时把
   `hdmi/sd_spi_ctrl.v`、`hdmi/sd_probe.v` 两个文件条目删掉了，而顶层确实例化了
   它们（MD5 与 `rtl/` 一致，第 419/441 行）。若带着这个改动综合，SD 逻辑会变成
   black box 不进 bit——这是"LED0 一直不亮"的重大嫌疑。已 `git checkout` 还原，
   **下次再发现 .al 少了这两个文件，立刻还原，不要提交。**
3. **真卡行为仍未验证**。所有修复目前只有仿真与 lint 证据，上板结论待做。

---

## 二、项目状态速览

| 阶段 | 状态 | 说明 |
|---|---|---|
| 一 板卡与工具确认 | ✅ | 管脚三源交叉验证完成，见 `constraints/dmz_eg4s20_bringup.adc` |
| 二 最小系统 | ✅ 仿真级 | ModelSim 全绿；`reports/sim_bringup_log.txt` |
| 三 HDMI 视频输出 | 🔶 | `hdmi_td.al` 综合布线通过、0 违例；**上板点亮待验证** |
| 四 资源读取 | 🔶 | SD SPI 控制器在修（当前焦点）；BMP 解析/SDRAM 帧缓存未开始 |
| 五~七 | ⬜ | 见 `docs/progress.md` |

当前顶层：`rtl/top/dmz_eg4s20_hdmi_top.v`（工程 `project/hdmi_td.al`），
已例化 SD 探针链路（块[11]，第 400~460 行）：`sd_spi_ctrl` + `sd_probe`，
探针结果用数码管显示：D4=PLL 锁定，D3=SD 失败指示，低两位=错误码。

---

## 三、当前技术焦点：SD SPI 控制器真机失败

### 三轮修复脉络（按时间）

| 轮次 | 上板现象 | 判定的根因 | 修复 | 结果 |
|---|---|---|---|---|
| 1（10-17 21:30） | err=7（读块 R1 超时） | 命令间 Ncc 不足 8 个 SCK | 发送器两段式补 Ncc | 变成 err=1 |
| 2（10-17 21:57/22:16） | err=1（CMD0 重试用尽） | Ncc 填充位放在了 CS 拉低之后，整帧错位；后改为 CS 高期间补足，再修 `ncc_ready` 未排除 CS 上升拍 | 块[1b] 引擎级 Ncc | 变成 err=2 |
| 3（本次 460163e） | err=2（CMD8/CMD55 异常）、LED0 灭 | ① ACMD41 被当成 40 位长应答（实际只有 R1 8 位）② 默认参数 65536 / 1048576 位在比较时被截成 0 ③ 位级边界（命令末位未发完就收应答、读块漏令牌首位） | `sd_spi_ctrl.v` 重写应答接收与读块；新增独立协议回归 `tb_sd_spi_protocol.v` | **未上板** |

### 关键认知（写进脑子里）

- **Ncc 修复不是已验证的真卡根因**，代码注释里已明确标注："片选高时保留 NCC_CYCLES
  个空时钟是本实现的命令间隔策略，不是已证实的真卡故障根因"。
- **旧仿真测不出协议缺陷**：原 testbench 的卡模型按错误格式应答（ACMD41 回长应答）、
  且把参数改小绕开了截断路径。新 `tb_sd_spi_protocol.v` 的卡模型不读 DUT 内部状态，
  用真实 R1/R3/R7 格式与默认参数，这一层才有诊断价值。
- **`{40'hFFFF_FFFF, 8'hXX}` 是位宽补零陷阱**：40 位宽的 0xFFFF_FFFF 高位补 0，
  出位变成 8 个 0 被当起始位。前导 1 的帧头必须写全位宽
  `{8'hFF, 32'hFFFF_FFFF, ...}`。
- **主机复位 ≠ 卡断电**：卡模型不随 `rst_n` 重置 idle/app 状态，这是真实行为。

---

## 四、未完成事项（按优先级）

### P0 — 必须立刻确认

1. **跑完三套 SD 仿真**，确认 `460163e` 的代码在仿真层是绿的：
   ```powershell
   Set-Location D:\FPGA_Compelate\SmartCampusMedia\sim\msim_work
   & D:\Quartus_APP\modelsim_ase\win32aloem\vlog.exe -quiet `
     ..\..\rtl\storage\sd_spi_ctrl.v ..\..\rtl\storage\sd_probe.v `
     ..\testbench\tb_sd_spi_protocol.v ..\testbench\tb_sd_spi_ctrl.v ..\testbench\tb_sd_probe.v
   foreach($t in @('tb_sd_spi_protocol','tb_sd_spi_ctrl','tb_sd_probe')){
     & D:\Quartus_APP\modelsim_ase\win32aloem\vsim.exe -c -do "run -all; quit -f" work.$t
   }
   ```
   要求：三套全 PASS，errors = 0。

2. **确认 `hdmi_td.al` 里 `hdmi/sd_spi_ctrl.v` 和 `hdmi/sd_probe.v` 两个条目在位**
   （第 53、61 行附近），CompileOrder 连续无缺口。

### P1 — 出 bit 并上板

3. **同步源码**（改过 rtl 必须跑，不要手工复制）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\sync_src.ps1
   ```
4. **headless 跑 TD 出 bit**（CWD 必须是工程目录）：
   ```powershell
   Set-Location D:\FPGA_Compelate\SmartCampusMedia\project
   & D:\TD_6_24_APP\bin\td_commands_prompt.exe flow_bit.tcl
   ```
   关注：SWNS/HWNS、0 违例、`hdmi_td_Runs\phy_1\hdmi_td.bit` 时间戳更新。

5. **上板实测**，按错误码定位（`sd_spi_ctrl.v` 头部注释有完整定义）：
   - 1 = CMD0 重试用尽 → CS/时钟极性/上电时序
   - 2 = CMD8/CMD55 异常 → CMD8 的 R7 或 CMD55 应答
   - 3 = ACMD41/CMD58 异常 → 初始化轮询或 OCR 校验
   - 4 = 非 SDHC · 5 = 令牌超时 · 6 = CRC16 · 7 = CMD17 应答
   - **注意**：若 LED0 仍灭且错误码为 0，优先怀疑 bit 里没有 SD 逻辑
     （即上面第 2 条的 .al 条目问题），而不是代码逻辑。

### P2 — 验证补强

6. turn 94 计划里还有一项未做：**中途复位测试**（卡保持供电、主机在初始化中途
   复位后重新走 CMD0）——`tb_sd_spi_protocol.v` 已含"卡不断电时主机复位"，需确认
   是否覆盖"初始化中途"这一更苛刻场景。
7. `reports/sd_protocol_default.log` / `sd_protocol_fast.log` 是上一轮两套分频下的
   协议回归日志，可作为对照基线。

---

## 五、硬性约束（改代码前必读 `docs/ai_handover.md`，这里只列最易踩的）

- **赋值规范**：时序块只用 `<=`，组合块只用 `=`，禁止混用、禁止多驱动。TD 会直接报错。
- **RTL 层禁用 `function`/`task`**（testbench 里的 `task` 保留）。
- **提交前必跑 lint**：`python scripts/lint_verilog.py rtl project/src`，E0/E1/E2 必须全 0。
- **改完 `rtl/` 跑 `scripts/sync_src.ps1`**，它做 MD5 增量同步 + 同步后 lint 双查。
- **编码**：`.bat` 纯 ASCII；`.ps1` UTF-8 带 BOM；`.v`/`.md`/`.py`/`.adc` UTF-8 无 BOM。
- **不得把未验证的内容写成已实现**；不得据照片猜管脚/时序。

---

## 六、环境速查

| 项 | 路径 / 值 |
|---|---|
| 工作区 | `D:\FPGA_Compelate\SmartCampusMedia` |
| 当前顶层 | `rtl/top/dmz_eg4s20_hdmi_top.v` |
| TD 工程 | `project/hdmi_td.al`（另一个旧工程 `bringup_td.al` 只含最小系统） |
| TD 命令行 | `D:\TD_6_24_APP\bin\td_commands_prompt.exe` |
| 出 bit 脚本 | `project/flow_bit.tcl` |
| 时序约束 | `constraints/dmz_eg4s20_hdmi.sdc` |
| 仿真器 | `D:\Quartus_APP\modelsim_ase\win32aloem\{vlog,vsim}.exe` |
| 仿真工作目录 | `sim/msim_work` |
| lint | `python scripts/lint_verilog.py rtl project/src` |
| 同步 | `scripts/sync_src.ps1` |
| git 远端 | 已配，`git push origin main` |

### 上板管脚速记（详见 `constraints/dmz_eg4s20_hdmi.adc`）

- HDMI：CLK_P=P1, D0_P=N1, D1_P=P4, D2_P=J3（LVDS33，无 DDC → DVI 兼容模式）
- SD（SPI）：SCK=F15, CS=F13, MOSI=F14, MISO=D14
- 音频 PWM：F3 ｜ 复位：E3（低有效）｜ 时钟：R7（50MHz）

---

## 六点五、验证状态（2026-10-19 00:18 实测）

ModelSim 10.1d 在 `D:\Quartus_APP\modelsim_ase\win32aloem\`，工作库 `sim\msim_work`。

| 测试平台 | 结果 | 说明 |
|---|---|---|
| `tb_sd_spi_protocol` | **ALL CHECKS PASSED**（11 项） | 本轮新增；真实 R1/R3/R7 格式 + 默认参数 + 卡不随 rst_n 复位 |
| `tb_sd_spi_ctrl` | **ALL CHECKS PASSED, errors = 0** | 含 T8 Ncc 间隔 ≥8 SCK、cmd0_timeout_o 周期性脉冲 |
| `tb_sd_probe` | **ALL CHECKS PASSED, errors = 0** | 探测 IDLE→READY / CMD17 双块 / RETRY / FATAL |
| `tb_seg_scan4` | **ALL CHECKS PASSED, errors = 0** | 数码管扫描无回归 |
| `tb_pwm_audio_out` | **ALL CHECKS PASSED, errors = 0** | 音频 PWM 无回归 |
| `tb_dmz_eg4s20_bringup` | **ALL CHECKS PASSED, errors = 0** | 视频/按键/网格无回归 |
| `scripts/lint_verilog.py` | 21 文件，**E0/E1/E2 全 0** | — |

**关于 `rtl/video/color_bar_ref.v`**：单独 `vlog` 编译会报
`Undefined variable: 'H_SYNC' / 'H_BP' / 'V_ACTIVE' / 'V_FP' / 'V_SYNC' / 'V_BP' / 'HS_POL'`
（第 129–130、232 行）——**已确认无害**：该文件第 3 行自述「参考件 · 未参与编译」，
没有任何模块例化它，也不在 `hdmi_td.al` 文件列表里。只是"全目录 vlog"会顺手编到它，
**仿真请只编 `tb` 需要的文件，或忽略这条报错**。

**TD 出 bit 时踩过的坑**：在 pwsh 里用双引号/单引号传含反斜杠的 tcl 路径给
`td_commands_prompt.exe`，`\f` 会被当成换页符吞掉（报
`couldn't read file "...projectlow_bit.tcl"`）。**必须用正斜杠**：
`td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/flow_bit.tcl`

## 七、给新会话的第一句话（建议直接粘）

> 读 `docs/ai_handover.md`、`docs/progress.md` 和 `docs/session_handover_2026-10-19.md`，
> 然后从"未完成事项 P0"开始：先跑三套 SD 仿真确认 `460163e` 是绿的，再检查
> `hdmi_td.al` 的 SD 文件条目是否完整，然后同步源码、headless 出 bit、给上板验证步骤。
> 不要重复上一轮的诊断，直接干活。

---

**最后一条提醒**：这个项目的历史会话已经因为上下文过大而不可用。新会话要注意
**不要整文件读大文件**（`reports/sd_spi_review_before.json` 有 18MB，`sim/msim_work`
下有上百 MB 的仿真中间文件），用 grep 定位后局部读，能显著延长会话寿命。
