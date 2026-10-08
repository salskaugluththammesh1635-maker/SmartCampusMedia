# 官方例程与 IP 资源清单（official_examples）

> 建立日期：2026-10-06。来源：`HX4S20_Contest_202606/`（官方赛题一资料包）。
> 用途：阶段三/四/五开发前登记官方可借鉴资源，明确"逻辑可移植 / 管脚不可移植"边界。

## 一、核心结论

1. **`lab_ex5_i2s`（康芯包）是本项目的官方参考实现**，功能与赛题一基线完全对齐：TF 卡 BMP 读取 → SDRAM 双缓冲 → HDMI 显示 → HDMI 音频（I2S）→ 按键切图/轮播。
2. HDMI 发送采用官方 **APUG092 HDMI1.4b Transmitter IP**（有独立参考设计包），SDRAM 采用官方 **APUG010/011** 参考设计，FIFO 用 **IPUG012 Soft FIFO**——全部有本地文档与源码。
3. 所有例程的 **.adc 管脚约束一律不可移植**（HX4S20C 板级外设与自购 DMZ-EG4S20 完全不同）；**RTL 逻辑与架构可移植**，移植点仅限与板级器件耦合的管脚/引出接口。

## 二、lab_ex5_i2s 源码结构登记（500 文件中 src 部分关键项）

| 模块文件（lab_ex5_i2s/src/user_source/hdl_source/） | 功能 | 移植价值 |
|---|---|---|
| `hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v` | 官方 HDMI 1.4b 发送核封装 | ★★★ 直接复用 |
| `hdmi_phy_warpper.v` / `lane_lvds_10_1.v` | TMDS PHY 封装 / 10:1 LVDS 串化器 | ★★★ 直接复用（PHY 与 EG4S20 IO 原语相关） |
| `hdmi_audio_tone_i2s_64fs.v` / `hdmi_audio_tone_pcm_scale.v` | HDMI 音频 I2S 64fs 生成 / PCM 缩放 | ★★★ 直接复用 |
| `I2S_receiver.v` | I2S 接收 | ★★ 参考 |
| `i2s_rom_player_single_pll_fix64_rom_ip.v` | ROM 音频播放器（MIF 索引） | ★★ 参考（测试音路径） |
| `SD/spi_master.v` | SPI 主控制器 | ★★★ 直接复用 |
| `SD/sd_card_cmd.v` / `sd_card_sec_read_write.v` / `sd_card_top.v` | SD 命令层 / 初始化+扇区读写 / 顶层 | ★★★ 直接复用（SPI 模式） |
| `SD/sd_card_bmp.v` / `bmp_read.v` | BMP 文件解析/文件头搜索 | ★★★ 直接复用 |
| `SD/frame_read_write.v` / `frame_fifo_write.v` / `frame_fifo_read.v` | 帧缓存读写 + 异步 FIFO | ★★★ 直接复用 |
| `SD/sdram.v`（IP）+ `include/sdr_*.enc.v` | 片内 SDRAM 控制器（APUG 参考设计） | ★★★ 直接复用 |
| `SD/video_timing_data.v` / `video_define.v` / `video_delay.v` | 640×480 时序参数/定义/延迟 | ★★★ 直接复用 |
| `SD/color_bar.v` | 彩条测试图 | ★★★ 直接复用 |
| `SD/ax_debounce.v` / `key_remove_shakes.v` | 按键消抖 | ★★★ 直接复用 |
| `startup_pulse.v` | POR：PLL 全锁定后放行启动（防上电花屏） | ★★★ 直接复用 |
| `audio_arc_calculate.v` | **音频可视化计算**（对应扩展项⑤） | ★★ 阶段六扩展用 |
| `IP/sys_pll.*` / `IP/video_pll.*` | 系统 PLL / 视频 PLL（像素时钟+5x） | ★★★ 参数化重建（IP 需在 TD 内重新生成） |
| `IP/afifo_16_256.*` / `afifo_32_16_256.*` / `afifo_16_32_256.*` | 异步 FIFO IP（16↔32bit 深度256） | ★★★ 参数化重建 |
| `constraints_source/pin.adc` / `timing.sdc` | **HX4S20C 板管脚/时序约束** | ✗ 管脚不可移植；sdc 时序框架可参考 |
| `td_project/lab_ex5_i2s_v1.0.al` | TD 6.2.1 工程文件 | ★★ 参考（工程结构与 IP 配置） |

辅助工具（lab_ex4_tf/doc/convert/）：
- `convert_images_to_bmp.py`：任意图片批量转 640×480 24bit 无压缩 BMP；
- `sync_to_sd.py`：SD 卡安全同步（破坏旧文件头，防物理扇区残留读错）。

## 三、DEMO 包（DEMO_TD版本6.2.1.zip，36 实验）与本项目的关联

| DEMO | 关联 | 备注 |
|---|---|---|
| `31_hdmi_tx_display_A/B` | HDMI 彩条（APUG092 最小例） | 顶层含 VGA 同步输出调试端口；`hdmi_tx` 模块带 `FAMILY("EG4")` 参数，官方明确支持 EG4S20 |
| `18_sd_card_audio` | SD 卡读写（SPI 模式教学版） | sd_card_cmd 状态机详解（CMD0→CMD8→CMD55+ACMD41→CMD17/18） |
| `20_i2sound_wm8731` | WM8731 声卡 I2S 例程 | HX4S20C 板载 codec；自购板若用 ES8388 则逻辑框架可参考、寄存器序列需换 ES8388 |
| `10_PLL_TEST` / `11_消抖` / `23_SCAN_4X4KEY` | PLL / 消抖 / 4×4 键盘扫描 | 阶段二直接参考 |
| `13_music`（乐曲演奏）/ `27_DAC_SIN` | 蜂鸣器/DAC 发声 | 阶段二蜂鸣器测试参考 |

## 四、IP 参考设计文档包（6_EG4S20数据手册/设计的IP参考设计文档.zip）

| 文件 | 说明 |
|---|---|
| `APUG092_HDMI1.4b_Transmitter_V1.0.zip` | 官方 HDMI 发送 IP 参考设计（lab_ex4/5 用的 V1.4 与其同源） |
| `APUG010_sdram_read_write_with_local_bus_reference_design_V1.1.zip` | 本地总线方式 SDRAM 读写参考设计 |
| `APUG011_high_performance_sdram_read_write_reference_design_v1.2.zip` + PDF | ERAM 接口高性能 SDRAM 读写参考设计 |
| `IPUG012_Soft_FIFO用户手册_v3.0.pdf` | Soft FIFO 用户手册 |
| `APUG010_Local bus总线的SDRAM读写v1.1.pdf` | 同上文档版 |

## 五、官方例程硬件前提 vs 自购板差异（移植改造点）

| 官方假设（HX4S20C） | 自购 DMZ-EG4S20 实际 | 移植改造 |
|---|---|---|
| HDMI_B 接口（板载 A/B 双口） | 底板 HDMI 排母引出（TMDS 差分对直出，需转接） | ① 核实底板 P3 脚位；② pin.adc 重写 TMDS 4 对差分管脚，IOSTANDARD=LVDS33 |
| TF 卡槽（板载，SPI 引出脚 A12~A14/B14） | 底板 SD 卡槽（硬件支持 SDIO，引出待核实） | 若底板为 SDIO 布线：先用 SPI 模式兼容卡（SD 协议 SPI 模式通用），或改写为 SDIO 控制器（工作量大，二期评估）；pin.adc 按底板实际脚重写 |
| 50M 时钟 R7、复位键 A2 | 50M 时钟 R7（文档表），复位 RSTn=E3 低有效 | sys_clk 不变；rst 改 E3 |
| 按键 key1/key2 | 4×4 矩阵键盘 | 用矩阵扫描模块替换独立按键输入，消抖模块保留 |
| 片内 SDRAM 2M×32bit | 同（EG4S20 片上资源一致） | 无需改造 |
| 数码管 8 位 | 4 位共阴 | 状态显示模块按 4 位改写（seg_scan/seg_decoder 可复用） |

## 六、官方例程验证过的关键参数（阶段三/四直接引用）

1. 图片规格：**640×480、24-bit RGB、非压缩 BMP**，FAT32 格式化 TF 卡 [来源: lab_ex4_tf/代码说明.md §2]；
2. 交互：key1 手动下一张、key2 自动轮播开关 [来源: lab_ex4_tf/代码说明.md §1]；
3. 可靠性机制：POR（全部 PLL 锁定后才启动）+ SD 读取 1 秒超时防死锁 [来源: lab_ex4_tf/代码说明.md §1.6/1.7]；
4. HDMI 输出走 HDMI_B 口，APUG092 V1.4 核 [来源: lab_ex4_tf/代码说明.md §3/§4]；
5. 音频：I2S 64fs，测试音经 ROM 播放器（MIF 由 `wav_to_mif.py` 生成，48kHz）[来源: lab_ex5_i2s/src 文件清单]。
