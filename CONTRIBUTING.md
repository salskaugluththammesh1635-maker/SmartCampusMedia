# 贡献指南

感谢你关注 SmartCampusMedia。本仓库是一个 Verilog/FPGA 项目，目标是可复现、可验证的校园多媒体播放终端。提交改动前请先读这份说明。

## 开发环境

| 依赖 | 说明 |
|---|---|
| 安路 TD | 综合与布局布线。工程基线为 TD 6.2.1，仓库脚本默认路径为 `D:/TD_6_24_APP`，可通过脚本参数覆盖 |
| ModelSim | 行为仿真。默认路径 `D:/Quartus_APP/modelsim_ase/win32aloem`，可用 `-ModelSimPath` 覆盖 |
| Python 3 | 静态检查与工程生成脚本 |
| PowerShell | 同步、回归与构建入口脚本 |

官方加密 IP 不随仓库发布，运行综合流程前须自行准备 `ip/local/sdram/` 与 `ip/local/hdmi/enc/`，详见 [README](README.md#3-官方-ip-与综合)。只跑行为仿真不需要这些文件。

## 提交前必做

```powershell
powershell -ExecutionPolicy Bypass -File scripts/sync_src.ps1
python scripts/lint_verilog.py rtl project/src project/hdmi
```

`sync_src.ps1` 会把 `rtl/` 同步到 TD 使用的 `project/src` 与 `project/hdmi` 副本，并在结束时自动跑 lint。**不要手工复制这两个副本目录**，它们由脚本生成。

lint 检查三类阻断项：E0 文件编码损坏、E1 时序块用阻塞赋值或组合块用非阻塞赋值、E2 多驱动。三者必须为 0。

## 编码规范

- 时序块 `always @(posedge clk ...)` 只用非阻塞赋值 `<=`；组合块只用阻塞赋值 `=`。
- 同一信号不得在多个 `always` 块中驱动。
- RTL 层不使用 Verilog `function` / `task`（testbench 例外）。
- 每新增一个主模块，先写同目录的 `_spec.md` 规格说明与 WaveDrom 时序图，再写 RTL。
- `.v` / `.md` / `.py` / `.adc` 存为 UTF-8 无 BOM；`.ps1` 存为 UTF-8 带 BOM；`.bat` / `.cmd` 纯 ASCII。
- 端口方向、位宽、注释须与实现一致；不要保留未连接的死端口。

## 验证要求

功能仿真通过不等于设计正确。提交 pull request 时，请在描述中附上：

1. 你运行的回归命令与报告目录；
2. 每个 testbench 的通过标记与检查项数量；
3. 如果改动了时序路径，附上布线后 timing 报告的 setup/hold WNS。

行为仿真入口见 [README](README.md#2-行为仿真)。回归脚本会校验明确的 `ALL CHECKS PASSED: <top>` 标记并比对源码哈希，不会仅凭仿真器退出码判定成功。

**不要声称以下内容，除非你确实执行并保留了证据：**

- 未运行的仿真「应该通过」；
- 行为模型仿真通过 = 真实加密 IP 通过；
- 功能仿真通过 = 时序收敛或已上板验证。

## 提交信息

采用 Conventional Commits 前缀：`feat:`、`fix:`、`docs:`、`refactor:`、`test:`、`chore:`。一次提交聚焦一件事，说明改动动机而不只是改动内容。

## 许可证

向本仓库提交贡献即表示你同意该贡献以 [MIT License](LICENSE) 发布。请只提交你有权授权的代码：不要提交来源不明或带有限制性许可的第三方 IP、参考设计或文档。
