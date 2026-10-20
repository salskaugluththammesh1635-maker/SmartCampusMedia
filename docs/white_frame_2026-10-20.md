# 真卡单图纯白画面排查（2026-10-20）

## 已取得的板上反馈

使用 `hdmi_sd_fat32_fix.bit`：LED4/5/0 亮、LED7 灭、数码管 `0010`，HDMI 为白底，但预期中央红块没有出现。用户随后测试 KEY15，应急红屏和间歇蜂鸣均正常。

这说明装载控制流程完成，HDMI 能输出红色。尚未证实图片经过真实 SDRAM 后的像素是否正确，不能仅凭 `image_ready` 判定存储内容正确，也不能把已有 SDRAM 行为模型通过当作实机读写通过。

先前读取的真卡根目录短名、文件大小、完整 FAT 簇链内容均已核对；`IMG001.BMP` 内容是白底中央红块，SHA256 为 `2CDABF23949A64533FC92A4DEE3A70A9556F882875A9BE9B74D7B017CFF0BD92`。真卡数据经真实 FAT/BMP 解析的回放已逐像素通过。板卡目前的纯白现象尚未在模型中复现。

## 独立 SDRAM 诊断

新增 `rtl/storage/sdram_frame_diag.v` 和独立工程 `project/sdram_frame_diag_td.al`。它不使用 SD、图片解析、帧 FIFO 或 HDMI，直接向同一 APUG011 加密核及 SiP SDRAM 写入 153600 个 32 位字，覆盖完整 640×480 RGB565 帧地址范围，再逐字读回比对。

测试图样同时依赖地址低位和高位，四字组内部保持组基址、组间增加 4，刷新时停止发命令，写完留出 32 拍静默窗口。比较结果先寄存再锁存错误，最后一项比较完成后才允许报告通过。初始化、写入及读出等待均有超时。

该工程独立于正式全链工程，未修改 `hdmi_sd_fat32_fix.bit`。旧 8 字 bring-up 中组基址使用 `beat[3]`，但 beat=0…7 时该位始终为 0，两个组会重叠；本次使用新自检器，不将旧 bit 当作读写正确性依据。

仿真入口：

```powershell
powershell -ExecutionPolicy Bypass -File sim/scripts/run_sdram_frame_diag.ps1
```

已实际运行，10 项检查、4 类场景、0 错误：完整 153600 字跨刷新读写正确；注入全 1 返回被判为 mismatch/all_ones；注入全 0 返回被判为 mismatch/all_zeros；屏蔽返回有效信号可有限超时退出。注入场景用于验证自检器能识别故障，不代表已复现实机根因。

构建入口：

```powershell
& D:\TD_6_24_APP\bin\td_commands_prompt.exe D:/FPGA_Compelate/SmartCampusMedia/project/flow_sdram_frame_diag.tcl
```

约束只创建 50MHz 输入时钟并自动派生 PLL 时钟，保留 SDRAM 0°/180°关系。时序失败时仍可生成诊断候选 bit，但脚本返回非零，不能把 bitgen 成功当作时序合格。

候选 bit 已完成综合、布局、布线和 bitgen，文件 629641 字节，SHA256 为 `563BA6BAE379F84A69AF83D010AC5A31C4FC8F98BEAA1F93A17EDE0C5A9433DE`。全部构建输入哈希保持一致；自检 150MHz 同域建立余量 +0.379ns、保持 +0.046ns，均无违例。SiP 两相接口建立余量 -3.582ns / -7.359ns，整体时序仍未通过。汇总证据在 `reports/sdram_white_diag/candidate.json`，该版本只用于诊断。

## 板上运行与结果

下载 `project/sdram_frame_diag_td_Runs/phy_1/sdram_frame_diag.bit`，按板卡复位键，等待约 1 秒。SD 卡可以留在板上，这个版本不访问它。该版本不驱动 HDMI、数码管或矩阵键盘；显示器无信号、数码管不显示是预期现象。

此诊断 bit 的 LED 定义与全链版本不同：

| LED | 含义 |
|---|---|
| 0 | 所有 153600 字读回比对正确，且没有超时 |
| 1 | SDRAM PLL 锁定 |
| 2 | 正在写入 |
| 3 | 正在读取 |
| 4 | 数据不符，保持到复位 |
| 5 | 等待超时，保持到复位 |
| 6 | 终态时，实际收到的读数据全部为 0xFFFFFFFF |
| 7 | 终态时，实际收到的读数据全部为 0x00000000 |

成功终态应仅 LED0/1 亮（0x03）。LED1/4 亮表示数据不符；若 LED6 同时亮则收到的数据全为 1（例如 0x52），LED7 同时亮则全为 0（例如 0x92）。LED5 可与其他故障标志同时出现。没有收到任何字时不报告“全 1”或“全 0”。

用户已反馈该诊断运行后仅 LED0/1 常亮，按此版本定义为整帧读回比对通过。这证明这一次独立、连续整帧自检的读写数据一致；不能据此认定稀疏图片写入、仲裁器、跨时钟 FIFO 和显示读回通路也正确，或认定静态时序已经通过。

下一步使用独立的完整图片通路观测工程，记录红色是否经过 BMP 解码、实际 SDRAM 写命令、SDRAM 读返回、最终 RGB565 像素四个边界，并单独记录进入 HDMI 发送器的图片红像素。详见 `docs/image_path_diag_2026-10-20.md`。
