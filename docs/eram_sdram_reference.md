# 片内 SDRAM（ERAM 接口）技术参考（阶段四/帧缓冲设计依据）

> 来源：底板例程 `EG4S20\微处理器原理综合设计底板\M0_Borad\M0_Borad\7_SDRAM_as_BRAM\source_code\` 逐层分析 + `SmartCampusMedia/ip/reference/APUG011_基于ERAM接口实现的高性能SDRAM读写v1.2.pdf`（17 页，已全文提取）。
> 本文档是 `rtl/storage/` 帧缓冲子系统的接口与调度依据。

## 1. 硬件底账

- 器件：EG4S20 片内 SIP **EG_PHY_SDRAM_2M_32 = 2M × 32bit = 64Mbit**（4 bank × 2^11 row × 2^9 col × 32bit）。
- 控制方案：安路官方 **APUG011 ERAM 接口方案**（加密核，带 Mentor 仿真 key，ModelSim 可解密仿真）。
- 资源（TD5.6.2 实测 EG4S-MINI-DEV3）：LUT 447、REG 96、PLL 1、c0 Fmax 219MHz。

## 2. 三层结构

```
app_wrrd (明文 159 行)      用户侧激励/校验范例（递增数写入→读回比对，Check_ok=0 正确）
   ↓ 虚拟 ERAM 单口 RAM 风格接口
sdr_wrrd (加密)             读写引擎：wr/rd 请求 → ACT/READ/WRITE/PRECHARGE 命令序列 + 4-beat 突发
   ↓
sdr_init_ref (加密)         上电初始化 + 周期刷新（自刷新模式）
sdr_as_ram  (加密顶层)      例化二者，仲裁刷新与读写，输出 SDRAM 物理引脚
```

## 3. 用户接口表（sdr_as_ram 端口，app_wrrd 为驱动范例）

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| Sdr_clk | in | 1 | SDRAM 工作时钟（例程 150MHz，用户逻辑同时钟域） |
| Sdr_clk_sft | in | 1 | 同频 180° 相移时钟，仅供 SDRAM_CLK 引脚输出（源同步对齐） |
| Rst | in | 1 | 高有效 |
| Sdr_init_done | out | 1 | 初始化完成，操作前必须等待 |
| Sdr_init_ref_vld | out | 1 | **刷新进行中**：高=刷新中，必须等它变低才能读写（唯一流控） |
| Sdr_busy | out | 1 | 忙标志；PDF 表 3-1 注明"暂不使用"，以 Sdr_init_ref_vld 为准 |
| App_ref_req | in | 1 | 手动刷新请求（self_refresh_open=0 时才用，至少拉高 1 拍） |
| App_wr_en | in | 1 | 写使能，**无反压/无 ready**，拉高即写 |
| App_wr_addr | in | 21 | 写地址 |
| App_wr_din | in | 32 | 写数据 |
| App_wr_dm | in | 4 | 字节掩码，dm[0]↔din[7:0]；屏蔽时置 4'b1111 |
| App_rd_en | in | 1 | 读使能，**无反压** |
| App_rd_addr | in | 21 | 读地址 |
| Sdr_rd_en | out | 1 | 读数据有效 |
| Sdr_rd_dout | out | 32 | 读出数据 |

物理侧：SDRAM_CLK、SDR_RAS/CAS/WE、SDR_BA[1:0]、SDR_ADDR[10:0]、SDR_DM[3:0]、SDR_DQ[31:0]。

**实测核接口补充（2026-10-20）：DM 会透传到物理 DQM，读取也会被屏蔽。没有写命令时必须将 App_wr_dm 置 0；仅有效的全屏蔽补写拍置 F。** 旧仲裁器在读取期间置 F 导致管脚功能模型返回高阻；单项修正后整帧真实核仿真通过，板上仍待回测，见 [读取 DQM 修正](image_dm_fix_2026-10-20.md)。

## 4. 时序行为（关键约束）

- **读延迟固定 10 拍**：App_rd_en+addr 后，第 10 个 Sdr_clk 拍起 Sdr_rd_en/有效数据连续流出。
- **写通道拉高即写**，可无限连续；连续写要求 Sdr_clk ≥64MHz。
- **无半途 busy 挂起**：唯一打断是周期刷新（Sdr_init_ref_vld 拉高），范例做法是检测到刷新标志立即中止当前传输。
- **读写不可同时**（PDF 2.3 硬限制，"读写需独立互斥运行"）——帧缓冲设计核心约束。
- **地址映射**（源码注释 `//row[10:0],bank[1:0],col[7:0]`）：row=addr[20:10]、bank=addr[9:8]、col=addr[7:0]。
- **地址以 128bit（4×32bit）为单元**：app_*_addr[1:0] 必须恒 2'b00，任意跳变只允许发生在 [20:2]，即**每 4 拍才可跳一次地址**，4 拍内地址内部自增。读写长度尽量为 4 的倍数，非 4 倍数用掩码补齐。
- 范例校验逻辑只比对 dout 低 16 位。

## 5. 时钟方案

例程 clk_pll.v：50MHz 进 PLL → C1=150MHz 0°（Sdr_clk，用户逻辑同时钟域）+ C2=150MHz 180°（Sdr_clk_sft，仅出 SDRAM_CLK 引脚）。方案内部零 CDC。SDR_CKE 恒 1'b1（self_refresh_open=1 模式）。

> 对本工程的意义：**ERAM 方案必须自己开第二个时钟域（150MHz）**，与显示 25MHz 域之间用异步 FIFO 跨域——控制器侧无任何 CDC 设施，跨域是接入方的责任。PDF 注意事项 6：读数据可能因器件不同错 1 拍，需实测调整对齐。

## 6. 配置宏（global_def.v，编译期定死）

`DATA_WIDTH=32`、`ADDR_WIDTH=21`、`DM_WIDTH=4`、`ROW_WIDTH=11`、`BA_WIDTH=2`；
频率相关：`SDR_CLK_PERIOD=1000000000/150000000`、`SELF_REFRESH_INTERVAL=64000000/SDR_CLK_PERIOD/2**ROW_WIDTH`——**改频率必须同步改这两个宏**。位宽换 16bit 需全局替换宏（方案本身支持参数化，本工程固定 32bit）。

## 7. 640×480 帧缓冲可行性结论（已核算）

| 维度 | 结论 |
|---|---|
| 容量 | RGB565 单帧 640×480×16bit≈4.9Mbit，64Mbit 存 **13 帧**；双/三缓冲绰绰有余 ✓ |
| 带宽 | 控制器 150MHz×32bit=4.8Gbps 理论（PDF 实测持续读写≈理论值）；VGA 需 25.175M×16=400Mbps，占比 ~8%，加刷新打断（~1%）余量 ~10× ✓ |
| 读延迟 | 固定 10 拍 + 跨域 → 读出侧必须挂异步 FIFO 预取 |
| 读写冲突 | 不支持同时读写 → **消隐期成块写帧 + 读流让出** 的互斥调度 |
| 刷新 | 自刷新自动做，但用户必须避让 Sdr_init_ref_vld 窗口（写通道无反压，上层负责） |

## 8. 仿真可用性（已验证）

- 三个 .enc.v 均带 **MGC-VERIF-SIM-RSA-1/RSA-2 key_block**，ModelSim 可解密（历史 transcript：加密文件编译 0 错误）。
- 工程自带 `sim_do\sim.do` + SDRAM 模型 `source_code\model\IS42s32200.v`（已确认存在）。
- 运行期 8 个 "Error" 全是模型内部 $hold/$width/$period 时序检查（tb 时钟 12.5MHz 所致，第 947-957 行），**非加解密失败**，可忽略或放宽。
- 移植注意：① sim.do 第 4-5 行硬编码原作者路径 `F:/app/anlogic_app_demo/...` 必须改；② 例程 tb `PERIOD 80`=12.5MHz，与 PDF 5.2 节"顶层仿真 25MHz"不一致，以我们自己的 tb 为准。

## 9. 对本工程的设计输入（阶段四落点）

1. 新时钟域：ERAM 跑 150MHz（PLL C1/C2 加两路输出），与 25MHz 像素域之间异步 FIFO×2（读预取 FIFO + 写入 FIFO）。
2. 写帧调度：读流（显示侧）优先连续，写侧在行/帧消隐窗口成块突发；写前检查 Sdr_init_ref_vld。
3. 地址生成严格 4 拍一跳（addr[1:0]=00）；突发长度取 4 的倍数。
4. 双缓冲可选：64Mbit 容量允许 ping-pong 双帧（各 786KB×2，地址 0 / 0x60000 起）。
5. STA（2026-10-20 更正）：用 `derive_clocks` 派生 PLL 时钟，不重复定义输出。仅两颗独立 PLL 之间分异步组；同一 SDRAM PLL 的 0°/180°关系必须保留，SiP 读写路径也须接受检查。历史 bring-up 切断这两路后得到的正余量不能证明 SDRAM 接口时序通过。
