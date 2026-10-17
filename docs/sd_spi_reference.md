# SD 卡 SPI 模式技术参考（阶段四设计依据）

> 来源：官方底板例程逐行分析（subagent 摸底，2026-10-17）+ SD 物理层规范简化版（Simplified Physical Layer Spec v6.0）通用知识。
> 本文档是 `rtl/storage/` 自研 SD/FAT32 驱动的接口与协议依据。**官方例程缺陷清单见 §4，自研改造决策见 §5。**

## 1. 引脚裁决（历史存疑项销案）

官方约束 `EG4S20\微处理器原理综合设计底板\M0_Borad\M0_Borad\6_SD_Card_SPI - V2\sd_card.adc:3-6`（全 LVCMOS33）：

| 信号 | 引脚 | 方向 | 语义 |
|------|------|------|------|
| SD_clk | F15 | FPGA→卡 | SPI SCK |
| SD_cs  | F13 | FPGA→卡 | 片选，低有效 |
| SD_datain | F14 | FPGA→卡 | MOSI（CMD/DATA 出） |
| SD_dataout | D14 | 卡→FPGA | MISO（RESP/DATA 入） |

**裁决：MOSI=F14、MISO=D14。** 此前三源交叉中「引脚说明 MOSI=F14/MISO=D14」与「底板例程相反」的矛盾以此为准——引脚说明正确，另一来源错误。上板若仍不通再实测反证。

**硬件细节（原理图 PDF 交叉验证，subagent a6862805）：**
- 卡座 U3 microSD，VDD=3.3V（0.1µF 去耦 C11），无电平转换芯片（原理图 IC 清单无 TXB/LVC/245），SPI 直连。
- **上拉**：CMD/CLK/DAT0~DAT3/CD 共 7 线各挂 10.0kΩ 上拉至 3.3V（R22/R32~R37）→ SPI 开漏依赖上拉的模式天然满足。
- **卡检测脚存在**：卡座 pin9 CD → FPGA 引脚 **E15**（板卡手册 p13 引脚表该行留空，原理图补齐）。可用作「无卡」快速报错（CD 经 10k 上拉：无卡=1，插卡=0）。
- 官方手册对 SD 卡仅一句「板载 SPI 模式的 SD 卡卡槽，用于存储大容量数据」；FAT 格式/驱动方式未提及。

## 2. SD 卡 SPI 模式协议要点

- **模式**：SPI Mode 0（CPOL=0, CPHA=0）。FPGA 在 negedge 变换 MOSI，卡在 posedge 采样；FPGA 在 posedge 采样 MISO。
- **空闲电平**：CS=1 时 MOSI 必须持续 1（即 0xFF 填充），卡在此期间同步内部状态。
- **命令帧**：6 字节 = `{1'b0, cmd[5:0], arg[31:0], crc[6:0], 1'b1}`，MSB 先发。SPI 模式仅 CMD0 的 CRC 有校验（固定 0x95），其余可填 0xFF。
- **应答 R1**：单字节，bit7=0 为有效。0x01=空闲（in idle state），0x00=就绪。卡收到命令后先输出一串 0xFF，第一个 0 字节即 R1。
- **令牌**：读数据块起始令牌 0xFE；写数据块起始令牌同 0xFE。
- **SDHC/SDXC**：块长固定 512B，地址按块号（CMD17 参数 = 扇区号）；SDSC 按字节寻址且需 CMD16 设块长。**本设计只支持 SDHC/SDXC**（现代卡必然是）。
- **上电时序**：卡上电后需 ≥74 个时钟且 CS=1（即至少 1ms @ 74kHz+）才能接受 CMD0；**SPI 模式初始化时钟必须 ≤400kHz**，ACMD41 完成后才能切高速（官方例程直接用 25MHz 属违规偷跑，见 §4）。
- **ACMD41 的 HCS 位**（arg bit30）：置 1 表示主机支持 SDHC；卡响应 OCR bit30=1 表示卡是 SDHC。
- **初始化判定**：CMD8 响应 R7 的 `voltage accepted [19:16]==0001`（2.7-3.6V）+ echo 0xAA 回来，判定卡为 v2.0+。

## 3. 官方例程架构（摸底结论）

```
sd_test.v (154行, 顶层演示: 上电自动 INIT→WRITE块0→READ块0→IDLE)
 ├─ sd_initial.v (239行)  初始化状态机
 │   idle→send_cmd0→wait_01→waitb→send_cmd8→waita→send_cmd55→send_acmd41→init_done/init_fail
 ├─ sd_read.v (189行)     CMD17 单块读
 │   idle→read(发CMD17)→read_wait(等令牌)→read_done(CS拉高前15拍)→idle
 └─ sd_write.v (201行)    CMD24 单块写（演示性质，数据源为 cnt 自身）
 PLL: al_ip\pll.v 单路 25MHz（50M/2），全工程单时钟域，零跨域逻辑
 总线复用: 三实例的 CS/MOSI 按状态机状态组合逻辑二选一（sd_test.v:144-152）
```

可复用资产：
- **命令引擎模板**（sd_initial.v:121-132 发送 / v:44-74 接收）：48bit 常量寄存器逐位移位发送 + 「MISO 出现 0 后计 8bit」的 R1 捕获 + rx_valid 单拍脉冲。
- **读字节流接口**（sd_read.v:138-187）：每 8 个 posedge 拼 1 字节，mydata_o/myvalid_o 单拍脉冲，data_come 块起始脉冲——可直接挂 FIFO。

## 4. 官方例程缺陷清单（自研必须避开）

| # | 缺陷 | 位置 | 后果 |
|---|------|------|------|
| 1 | 全程 25MHz 无 ≤400kHz 初始化阶段 | sd_test.v:53-58 | 违反规范；部分旧卡/劣化卡无法识别 |
| 2 | 无 CMD16，隐含 SDHC-only 但未声明 | sd_initial.v 全文 | SDSC 静默失败 |
| 3 | init_fail 无限重试无上报 | sd_initial.v:233 | 卡死无法区分「慢」与「失败」 |
| 4 | CMD8 不匹配进 fail 后仅重试不降级 | 同上 | SDv1 卡永远失败 |
| 5 | R1 不校验、令牌不比对 0xFE、读等待无超时 | sd_read.v:54-69,154 | 总线异常时永久挂起 |
| 6 | 写路径 Data Response 不判 5bit 应答值 | sd_write.v | 写失败静默 |
| 7 | 输出在 negedge 块直接驱动 pad | 各文件 | 高速下 IO 时序无裕量（25M 尚可） |

## 5. 自研改造决策（阶段四实现约束）

1. **两阶段时钟**：初始化 ≤400kHz（25MHz 计数器分频 64 分频 = 390.6kHz），ACMD41 R1=0x00 后切 25MHz。用「SPI 时钟使能门控」实现（单时钟域 + 分频使能，不做真实门钟）。
2. **SDHC-only**：明确只支持 SDHC/SDXC（块寻址），CMD8 失败即报错停机（不支持 SDv1）。
3. **有限重试 + 错误码**：初始化整体超时（ACMD41 128 轮 × 上限）后锁死并输出 error 码到 LED/数码管。
4. **读路径健壮性**：R1 必须校验 0x00；令牌 0xFE 逐字节比对 + 100ms 超时；CRC 两字节丢弃（SPI 模式默认关闭 CRC 校验，无需处理）。
5. **多块读 CMD18**：图片按扇区连续读，用 CMD18 + STOP_TRANSMISSION(CMD12) 替代逐扇区 CMD17，减少命令开销。
6. **时钟域**：SD 驱动跑 25MHz clk_pixel 域（与显示同域，省 CDC）；用户接口侧（FAT32/取数）也在同域。单时钟域零 CDC。
7. **FAT32**：见 §6。

## 6. FAT32 只读实现规格（设计基线）

SDHC 卡出厂默认含 MBR + 一个 FAT32 分区（Windows 格式化行为）。本设计只读、只遍历、不写。

### 6.1 定位链
```
扇区0 (MBR) → 分区表项0偏移 0x1C6 处取 4B = 分区起始扇区 LBA
→ 分区第一个扇区 = VBR(BPB)：
   +0x0D  sectors_per_cluster (1B)
   +0x0E  reserved_sectors    (2B, 通常 32/38)
   +0x10  num_fats            (1B, 通常 2)
   +0x24  fat_size_sectors    (4B, FAT32 专用字段)
   +0x2C  root_cluster        (4B, 根目录簇号, 通常 2)
→ fat_begin  = partition_start + reserved_sectors
→ data_begin = fat_begin + num_fats × fat_size_sectors
→ 簇 N 起始扇区 = data_begin + (N - 2) × sectors_per_cluster
```

### 6.2 目录项解析
- 目录/数据区每 32B 一个目录项；短名项首字节 0x00=目录结束、0xE5=已删除。
- **长文件名（LFN）**：属性 0x0F 的项为 LFN 序列，按序号倒序拼 UTF-16 文件名；短名项（11B 8.3 格式）始终存在且为真名兜底。**实现策略：直接匹配短名**（素材文件统一命名为 `IMG001.BMP` 这类 8.3 短名，PC 拷入时短名确定），LFN 只需跳过。
- 文件项关键字段：+0x1A 首簇低16位、+0x14 首簇高16位（FAT32）、+0x1C 文件大小 4B。
- FAT 表：簇链为 `u32 next = fat[cluster]`；`>= 0x0FFFFFF8` 为链尾。

### 6.3 与播放器的接口
驱动向上层提供「按文件读流」原语：`open(name) → size/首簇`，`read_next_512B → data+valid`（内部走 FAT 簇链 + CMD18 连续读）。图片播放器按 512B 块消费 BMP 像素流。

## 7. 素材约定

- 格式：**BMP 24bit**，底-上行序（biHeight>0），无压缩。
- 命名：SD 卡根目录 `IMG001.BMP`、`IMG002.BMP` …（8.3 短名，解析器只匹配短名）。
- 生成工具：`scripts/make_test_bmps.ps1`（已生成 img1_640x480.bmp 921,654B / img2_320x240.bmp 230,454B 于 `assets/sd_images/`）。
- 解析器只读 54B 头的 4 个字段：+0x02 文件大小、+0x0A 数据偏移、+0x12 宽、+0x16 高；逐行读像素转 RGB888→RGB565。
