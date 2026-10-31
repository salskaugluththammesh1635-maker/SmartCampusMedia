# 贡献指南

本仓库是一个 Verilog/FPGA 项目：可复现、可验证的校园多媒体播放终端。它没有 CPU、没有软核，所有行为都由 RTL 状态机实现，因此**"看起来能跑"和"确实能跑"之间的差距很大**。提交改动前请先读这份说明。

## 先读哪几篇

| 想了解 | 读 |
|---|---|
| 项目能做什么、当前状态、怎么烧板 | [README.md](README.md) |
| 模块为什么这样切、跨域和存储怎么设计 | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 每项功能做到哪一步、还差什么 | [TASKS.md](TASKS.md) |
| 测试怎么跑、数字怎么读、哪些结论能下 | [TEST_COVERAGE.md](TEST_COVERAGE.md) |
| 历史诊断与交接记录 | [docs/README.md](docs/README.md) |

## 开发环境

| 依赖 | 说明 |
|---|---|
| 安路 TD | 综合与布局布线。最近构建使用 TD v6.2.168116；默认安装路径 `D:/TD_6_24_APP`。各入口的路径配置以脚本参数或 Tcl 内容为准 |
| ModelSim / Questa | 行为回归通常用 ModelSim 10.1d；真实加密核及串化器验证使用 Questa 2022.1。入口分别使用 `-ModelSimPath` / `-QuestaPath` 等参数 |
| Python 3 | 静态检查与工程生成脚本 |
| PowerShell | 同步、回归与构建入口脚本 |

官方加密 IP **不随仓库发布**，运行综合流程前须自行准备 `ip/local/sdram/` 与 `ip/local/hdmi/enc/`，详见 [README](README.md#七开发与复现)。只跑不含官方核的行为模型回归不需要这些文件；真实核内容、刷新、保持与串化器验证需要本地官方 IP 与对应仿真库。

## 提交前必做

```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync_src.ps1
python scripts/lint_verilog.py rtl project/src project/hdmi
```

`sync_src.ps1` 把 `rtl/` 同步到 TD 使用的 `project/src`、`project/hdmi` 副本，并把受版本管理的 `ip/config/sdram/global_def.v` 同步到 `ip/local/sdram/global_def.v`，结束时自动跑 lint。

**目录真源只有 `rtl/`、`constraints/`、`ip/config/`**——`project/src`、`project/hdmi`、`ip/local/` 全部由脚本生成，不要手工改。漏掉同步而只改副本，是这类工程最常见的"改了没生效"来源：TD 编译的是副本，不是 `rtl/`。

lint 检查三类阻断项，必须全 0：**E0** 文件编码损坏、**E1** 时序块用阻塞赋值或组合块用非阻塞赋值、**E2** 多驱动。

## 编码规范

- 时序块 `always @(posedge clk ...)` 只用非阻塞赋值 `<=`；组合块只用阻塞赋值 `=`。
- 同一信号不得在多个 `always` 块中驱动。
- RTL 层不使用 Verilog `function` / `task`（testbench 例外）。
- 每新增一个主模块，先写同目录的 `_spec.md` 规格说明与 WaveDrom 时序图，再写 RTL。
- `.v` / `.md` / `.py` / `.adc` 存为 UTF-8 **无 BOM**；`.ps1` 存为 UTF-8 **带 BOM**；`.bat` / `.cmd` 纯 ASCII。`.v` 带 BOM 会让 ModelSim 报 `unexpected non-printable character 0xef`。
- 端口方向、位宽、注释须与实现一致；不要保留未连接的死端口。
- 由脚本生成的 RTL（`osd_font8x16.v`、`osd_strings.v`）**不手改**，改生成器 `scripts/gen_osd_*.py` 后重新生成。

## 新增一个模块的完整顺序

1. 写 `rtl/<分组>/<module>_spec.md`：端口表、时序图、与相邻模块的握手约定。
2. 写 `rtl/<分组>/<module>.v`，端口注释与 spec 一致。
3. 在 `scripts/sync_src.ps1` 的映射表里登记（否则副本不会更新）。
4. 若进 TD 工程，还要把文件补进 `project/hdmi_td.al` 的源清单。
5. 写 `sim/testbench/tb_<module>.v`，并把它加入对应回归脚本。
6. 跑 `python scripts/lint_verilog.py` + 至少一套受影响的回归。

第 3、4 步最容易漏，症状都是"仿真过了、综合里找不到模块"（`HDL-1007: module remains a black box`）。

## 验证要求

功能仿真通过不等于设计正确。提交 pull request 时请在描述中附上：

1. 你运行的回归命令与报告目录；
2. 每个 testbench 的通过标记与检查项数量；
3. 如果改动了时序路径，附上布线后 timing 报告的 setup/hold WNS。

回归脚本会校验明确的 `ALL CHECKS PASSED: <top>` 标记并比对源码哈希，**不会仅凭仿真器退出码判定成功**。判定口径、七套回归范围与写 TB 的经验见 [TEST_COVERAGE.md](TEST_COVERAGE.md)。

**不要声称以下内容，除非你确实执行并保留了证据：**

- 未运行的仿真"应该通过"；
- 行为模型仿真通过 = 真实加密 IP 通过；
- 功能仿真通过 = 时序收敛，或 = 已上板验证。

文档更新须区分**当前状态**与**历史测量**：有日期的诊断、时序报告保留当时数据并链接后续结论；上板显示确认、音频试听、按键核定与长时验收分别记录，不能互相替代。当前交付位流及其哈希以 [README](README.md) 与对应构建的 `manifest.json` 为准。

## 提交信息

采用 Conventional Commits 前缀：`feat:`、`fix:`、`docs:`、`refactor:`、`test:`、`chore:`。一次提交聚焦一件事，说明**改动动机**而不只是改动内容。

## 许可证

向本仓库提交贡献即表示你同意该贡献以 [MIT License](LICENSE) 发布。请只提交你有权授权的代码：不要提交来源不明或带有限制性许可的第三方 IP、参考设计或文档。
