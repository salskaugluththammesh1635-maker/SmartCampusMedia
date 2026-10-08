# 智播校园 SmartCampusMedia

> 基于安路 EG4S20 FPGA 的校园多媒体信息发布与应急提示终端
>
> 全国大学生嵌入式芯片与系统设计竞赛 2026 · FPGA 创新设计赛道 · 选题一：基于安路 EG4S20 的 HDMI 多媒体播放系统

## 项目简介

面向校园大厅、教学楼、实验室场景的多媒体信息发布终端，全部算法、控制逻辑与数据处理流程在 FPGA 内自主实现（无任何附加处理器）：

- **SD 卡资源读取**（SPI 模式，FAT32，640×480 24bit BMP）
- **片内 SDRAM 帧缓存**（EG4S20 内置 2M×32bit，双缓冲无缝切换）
- **HDMI 音视频输出**（TMDS 直出 + 48kHz 音频嵌入）
- **按键交互**（4×4 矩阵键盘：切图/轮播/模式/应急直达）
- **应急信息模式**（高优先级页面 + 蜂鸣器提示音）
- 扩展：OSD 字幕、转场特效、参数调节、音频可视化

三种工作模式：**日常信息播放 / 校园科普展示 / 应急信息发布**。

## 硬件平台

| 项目 | 说明 |
|---|---|
| FPGA | 安路 EG4S20BG256（19,600 LUT / 片内 SDRAM 2M×32bit / 4 PLL） |
| 核心板 | 大拇指 DMZ-EG4S20 |
| 底板 | MO 综合底板（板载 HDMI / VGA / RGB565 / SD 卡槽 / PWM 音频功放 / DAP-Link） |
| 工具链 | 安路 TD 6.2.1（评审环境版本）+ ModelSim（仿真） |

## 仓库结构

```
SmartCampusMedia/
├── rtl/                 # RTL 源码（自研 + 官方可复用模块移植）
│   ├── top/             #   顶层（最小系统 / 完整 bringup）
│   ├── video/           #   视频时序发生器 / 测试图发生器
│   ├── input/           #   4×4 矩阵键盘扫描消抖
│   ├── control/         #   播放控制状态机
│   ├── display/         #   数码管动态扫描
│   ├── audio/           #   蜂鸣器提示音
│   └── common/          #   公共模块（段码译码等）
├── sim/                 # 仿真 testbench 与脚本（ModelSim）
├── constraints/         # 管脚约束（.adc，全部管脚已三源交叉核实）
├── docs/                # 项目文档（板级事实/赛规核实/例程登记/进度）
├── project/             # TD 工程文件（bringup_td.al + src 副本 + Tcl 流程脚本）
├── reports/             # 验证证据（仿真日志 / 渲染图像）
└── scripts/             # 辅助脚本（Verilog 静态检查 lint 等）
```

> 注：官方参考资料（赛题包例程、IP 参考设计）仅本地保留，不入库。

## 快速开始

### 仿真（无需板卡）

```powershell
cd sim\scripts
.\run_sim.bat          # 一键编译+仿真，导出彩条/网格 PPM 帧图像
```

或手动：

```tcl
# ModelSim Tcl Console
do sim/scripts/sim_bringup.do
```

### 静态检查（提交 TD 前）

```powershell
python scripts\lint_verilog.py rtl project\src
# 检查: E0 文件损坏 / E1 阻塞非阻塞混用 / E2 多驱动（安路 TD 会报 ERROR 的问题）
```

### 综合（安路 TD 6.2.1）

1. 打开 `project/bringup_td.al`
2. 运行流程：`Read Design → Optimize RTL → Optimize Gate → Place → Route → Generate Bitstream`
3. 或在 Tcl Console：`source project/run_full_flow.tcl`

## 当前进度

| 阶段 | 状态 |
|---|---|
| 一、板卡与工具确认 | ✅ 完成（管脚三源交叉核实，详见 docs/pending_confirmations.md） |
| 二、最小系统验证 | 🔶 仿真通过（键盘/数码管/蜂鸣器/时序全 PASS）；待上板 |
| 三、HDMI 视频输出 | ⬜（RTL 预演完成：时序发生器+测试图已仿真验证） |
| 四、SD 卡读取与帧缓存 | ⬜（官方参考实现已解析待移植） |
| 五、基础播放系统 | ⬜ |
| 六、扩展功能 | ⬜ |
| 七、工程验证与比赛材料 | ⬜ |

详细进度见 [docs/progress.md](docs/progress.md)。

## 验证证据

- 仿真渲染结果（ModelSim 帧导出）：[reports/sim_out_colorbar.png](reports/sim_out_colorbar.png) / [reports/sim_out_grid.png](reports/sim_out_grid.png)
- 仿真日志：[reports/sim_bringup_log.txt](reports/sim_bringup_log.txt)

## 文档

| 文档 | 内容 |
|---|---|
| [docs/pending_confirmations.md](docs/pending_confirmations.md) | 板级事实清单（全部管脚+来源标注） |
| [docs/project_definition.md](docs/project_definition.md) | 项目定义 / 赛规核实 / 功能分级 A~C |
| [docs/official_examples.md](docs/official_examples.md) | 官方例程登记与移植评级 |
| [docs/progress.md](docs/progress.md) | 开发进度与问题记录 |
| [docs/ai_handover.md](docs/ai_handover.md) | AI 协作交接基线（每次会话先读） |

## 许可与声明

- 本仓库代码为参赛团队原创（除特别标注的"官方移植"模块，均注明来源）
- 官方参考资料（例程/IP/文档）版权归安路科技、康芯电子及大赛组委会所有，本仓库不入库
- 应急信息模式为演示定位，非安全认证设备
