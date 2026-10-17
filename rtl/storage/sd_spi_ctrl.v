// ============================================================================
// 文件名：rtl/storage/sd_spi_ctrl.v
// ============================================================================
// 【一、在整体系统中的功能】
//   所属层次：阶段四存储子系统最底层（SD 物理接口层）
//   工程归属：SmartCampusMedia SD 卡图片播放系统
//   数据流位置：SD 卡引脚(sd_cs_n/sd_sck/sd_mosi/sd_miso) ←→ 本模块
//              ←→ fat32_reader（下游 S3 切片接入；S1/S2 阶段由 tb 顶替）
//   为什么需要它：SD 卡 SPI 模式以位流收发，命令/应答/数据块各有独立位级
//               时序（Ncr 应答前导、令牌 0xFE、CRC16 尾部）。把位级细节
//               封装在此，上层只见「初始化好了吗」「读一块 512B」。
// 【二、本模块功能】
//   一句话职责：SD 卡 SPI 驱动器——上电初始化（CMD0→CMD8→CMD55+ACMD41
//   循环，SDHC-only）+ 单块读（CMD17，512 字节流式输出 + CRC16 校验）。
//   关键特性：
//     1. 全逻辑单一 25MHz 时钟域（项目铁律），SCK 由分频计数器翻转产生；
//     2. 两阶段时钟：初始化 SCK≈390.6kHz（CLK/64），init_done 后自动切
//        12.5MHz（CLK/2）；
//     3. 每一处等待都有超时上限（Ncr 应答前导 / ACMD41 循环 / 数据令牌 /
//        CMD0 重试），卡不插或不响应时状态机自行走出并报 err_code，绝不
//        挂死（赛规基础要求②「显示稳定性与鲁棒性」在驱动层的落地）；
//     4. SPI mode 0：MOSI 在 SCK 下降沿拍更新（卡在上升沿采样），MISO 在
//        SCK 上升沿拍采样（卡在下降沿送出后已稳定）；
//     5. 驱动权单一化：初始化序列机与读块机各自驱动私有 cs/err 寄存器，
//        输出端用 wire 合成（lint E2 多驱动检查的合规做法）。
// 【三、接口与内部结构】
//   端口一览：
//     clk         in  1    主时钟 25MHz（全系统单一时钟域）
//     rst_n       in  1    异步复位，低有效
//     init_start  in  1    脉冲：启动初始化序列（上电后调用一次）
//     init_done   out 1    电平：初始化成功（此后才可 blk_start）
//     init_fail   out 1    电平：初始化失败（err_code 有效，须复位重来）
//     err_code    out 4    电平：错误码（0 正常，编码见下）
//     blk_start   in  1    脉冲：启动读一个 512B 块（init_done 后有效）
//     blk_addr    in  32   电平：目标扇区号（SDHC 按扇区寻址）
//     blk_busy    out 1    电平：读块进行中
//     blk_done    out 1    脉冲：512B 已全部流出且 CRC 校验通过
//     blk_err     out 1    脉冲：读块失败（err_code 标明原因）
//     data_byte   out 8    电平：块数据字节流（data_valid 拍可读）
//     data_valid  out 1    脉冲：data_byte 有效（每字节 1 拍）
//     sd_cs_n     out 1    SD 卡片选，低有效
//     sd_sck      out 1    SPI 时钟（初始化 390.6kHz / 读块 12.5MHz）
//     sd_mosi     out 1    FPGA→卡 串行数据
//     sd_miso     in  1    卡→FPGA 串行数据
//   err_code 编码：1=CMD0 重试用尽 2=CMD8/CMD55 应答异常（非 SDv2）
//                 3=ACMD41 循环超时 4=卡非 SDHC（OCR.CCS=0）
//                 5=数据令牌超时/错误令牌 6=CRC16 比对失败
//                 7=CMD17 应答非 0x00
//   内部逻辑块（共 8 块，按信号流顺序）：
//     [1] SCK 分频发生器 always：div_cnt 环形计数翻转 sck_r；sck_d 打拍
//         出 sck_rise（MISO 采样锚点）/sck_fall（MOSI 更新锚点）。
//     [2] 发送移位器 always：xact_start 拍预置帧首 bit48（start=0）上总线，
//         此后每个 sck_fall 拍输出下一位——保证卡在第一个上升沿采到的
//         就是 bit47，位序不漂移；48 位 = 预置 1 次 + fall 移位 47 次。
//     [3] 应答接收器 always：发送相结束并隔 1 拍（tx_idle_d 防止把最后一个
//         命令位的回显误当应答起始位）→ 等 MISO 变低（Ncr 超时保护）→
//         按 8/48bit 收入 rx_shift → 双脉冲交付：rx_done_ok=正常收满、
//         rx_done_to=Ncr 超时（信息在脉冲本身，替代共享 ok 标志）。
//     [4] 命令 CRC 查表 always(*)：CMD0=0x4A（帧尾 0x95）、CMD8=0x43
//         （帧尾 0x87）、其余 SPI 模式 CRC off=0x7F（帧尾 0xFF）。
//     [5] 事务引擎 always：监视请求状态（初始化 TX 态 / 读块 B_TX 态），
//         请求上升沿自动锁存命令帧并驱动收发流程，rx_done 时交付应答——
//         序列机只表达「我要发哪条命令」，怎么收发全部在此层复用。
//     [6] 初始化序列机 always：POWERUP→SEND80→CMD0(重试≤8)→CMD8(R7
//         echo 校验)→(CMD55+ACMD41)×N（判 OCR busy 位[39]与 CCS[38]）
//         →DONE（切高速时钟）/FAIL，每步都有失败出口与错误码。
//     [7] 读块状态机 always：CMD17→R1==0x00→字节对齐滑窗等令牌 0xFE
//         （非 0xFE 且高位为 0 即错误令牌）→512 字节按位流出（每 8 位出
//         data_valid）→CRC16 逐位 LFSR 累积→尾部 16 位比对→TAIL 收尾。
//     [8] 输出合成（组合 assign）：sd_cs_n/err_code 由两个序列机的私有
//         寄存器按「init_done 前归序列机、之后归读块机」合成，规避多驱动。
//   上电时序：复位后 pow_cnt 计满（≈5.2ms）等 init_start → 先发 80 个
//   SCK 空周期（cs=1、MOSI=1，卡内部同步）→ 进入 CMD0。
// 【四、设计思路与范式】
//   范式定位：有限状态机（两层级联：序列机决定「先发哪条命令」，事务引擎
//   决定「一条命令怎么收发」）+ 线性序列机（位级收发计数）+ 计数器/分频
//   （SCK 翻转生成）+ 打拍/移位（边沿检测、应答移位、rx_gate 防误采）。
//   为什么这样写：官方例程 sd_initial.v/sd_read.v 把「发哪条」「怎么发」
//   「怎么收」耦合在一个大 case 里，每条命令一套状态、无超时（卡不插就
//   永久停在 wait 态）、negedge 时钟域（双沿域不利综合与 STA）。本设计
//   两层拆分后新增命令只在序列机加状态、事务引擎零改动；全链超时保证
//   任何卡状态都能自行走出；单沿采样（只认 sck_rise/sck_fall 锚点）让
//   整个驱动处于一个时钟域，时序约束简单。
//   关键写法要点：
//     1. 命令帧 = {start 0, trans 1, cmd[5:0], arg[31:0], crc7, stop 1}
//        共 48bit，MSB 先发；首 bit 在事务发起拍预置上总线（关键：翻转式
//        SCK 的第一个边沿是上升沿，若不在发起拍预置，bit47 会被卡漏采）；
//     2. ACMD41 结果不判「R1==0」而判 OCR：R3 应答 = 48bit 左移入 rx_shift，
//        字节流 {R1, 0xC0|0x80, 0x00, 0x00, 0x00, 0xFF}，OCR[31:24] 落
//        [39:32]——OCR[31]（busy 完成位）即 rx[39]、OCR[30]（CCS）即 rx[38]；
//        官方例程按 R1 字节判是语义混乱的写法；
//     3. R7 校验取 echo 回显字节：应答字节流第 5 字节 = arg 低字节 0xAA
//        的回显，左移入后落 [15:8]；
//     4. 令牌检测按字节对齐滑窗：R1 应答本身 8 位对齐，后续卡数据按字节
//        边界输出，滑窗每 8 位判一次 {tok_shift[6:0], miso}==0xFE，比
//        「等第一个 0」更稳（0xFE 的 MSB 是 1，首位检测法会错位）；
//     5. CRC16：多项式 0x1021、初值 0x0000、MSB first 逐位异或，数据相
//        每个采样位都参与，尾部 16 位与本地值比对；
//     6. 翻转式分频：div_cnt 每 DIV 拍翻转 sck_r，SCK=CLK/(2×DIV)，故
//        INIT_DIV=32 → 390.6kHz、FAST_DIV=1 → 12.5MHz。
//   范式认读方法：见 docs/design_patterns.md §3（FSM）/§2（LSM）/§4（计数器）。
// ============================================================================
module sd_spi_ctrl #(
    parameter CLK_FREQ_HZ   = 25_000_000, // 主时钟频率（Hz），全系统统一 25MHz
    parameter SCK_INIT_DIV  = 32,         // 初始化 SCK 半周期拍数：25M/(2*32)=390.6kHz（卡要求 100~400kHz）
    parameter SCK_FAST_DIV  = 1,          // 读数据 SCK 半周期拍数：25M/(2*1)=12.5MHz（SPI 模式保守高速档）
    parameter NCR_TIMEOUT   = 128,        // 应答前导等待上限（位拍）：Ncr 最大 64 位，取 2 倍余量
    parameter ACMD41_LOOPS  = 65536,      // ACMD41 循环上限：每轮约 300 拍，65536 轮约 0.8s（Nid 规范 1s）
    parameter TOKEN_TIMEOUT = 1_048_576,  // 数据令牌等待上限（位拍）：2^20 @12.5MHz≈0.34s（Nac 规范 100ms）
    parameter RETRY_MAX     = 8           // CMD0 重试上限：卡上电静默期偶发无应答，8 次足够
)(
    input  wire        clk,          // 主时钟 25MHz
    input  wire        rst_n,        // 异步复位，低有效
    input  wire        init_start,   // 脉冲：启动初始化
    output reg         init_done,    // 电平：初始化成功
    output reg         init_fail,    // 电平：初始化失败
    output wire [3:0]  err_code,     // 电平：错误码（两个序列机私有寄存器合成）
    input  wire        blk_start,    // 脉冲：启动读一块
    input  wire [31:0] blk_addr,     // 电平：扇区号
    output reg         blk_busy,     // 电平：读块进行中
    output reg         blk_done,     // 脉冲：块读完成
    output reg         blk_err,      // 脉冲：块读失败
    output reg  [7:0]  data_byte,    // 电平：块数据字节
    output reg         data_valid,   // 脉冲：data_byte 有效
    output wire        sd_cs_n,      // 片选低有效（两个序列机私有寄存器合成）
    output reg         sd_sck,       // SPI 时钟
    output reg         sd_mosi,      // FPGA→卡 串行数据
    input  wire        sd_miso       // 卡→FPGA 串行数据
);

    // ------------------------------------------------------------------------
    // 内部信号声明（按逻辑块分组）
    // ------------------------------------------------------------------------
    // —— [1] SCK 分频发生器 ——
    reg  [5:0]  div_cnt;      // SCK 半周期分频计数（0~DIV-1 环形，翻转点即边沿）
    reg         sck_r;        // SCK 寄存器输出（使能期间每 DIV 拍翻转）
    reg         sck_d;        // sck_r 打一拍，供边沿检测
    wire        sck_rise;     // SCK 上升沿拍（1 拍脉冲）：MISO 采样锚点
    wire        sck_fall;     // SCK 下降沿拍（1 拍脉冲）：MOSI 更新锚点
    wire        sck_en;       // SCK 翻转使能（活动期间才跑，空闲保持低）
    reg  [5:0]  sck_div_r;    // 当前半周期拍数（init 成功后 INIT→FAST 切换）
    reg  [6:0]  cnt80;        // 上电 80 个 SCK 空周期计数

    // —— [2] 发送移位器 ——
    reg  [47:0] tx_shift;     // 命令帧移位寄存器（左移，bit47 先出）
    reg  [5:0]  tx_bit_cnt;   // 已 fall 移位次数（0~46，预置首 bit 不计数）
    reg         tx_active;    // 发送相有效（fall 拍移位）
    reg         tx_idle_d;    // tx_active 打一拍：接收相开启前的安全隔离

    // —— [3] 应答接收器 ——
    reg  [47:0] rx_shift;     // 应答移位寄存器（左移入）
    reg  [5:0]  rx_bit_cnt;   // 已接收位数
    reg         rx_wait;      // 正在等 MISO 变低（应答起始位）
    reg         rx_got;       // 已捕获起始位，正在收应答位
    reg  [7:0]  ncr_cnt;      // 应答等待计数（Ncr 超时用）
    reg         rx_done_ok;   // 应答正常收满 1 拍脉冲（交付引擎，信息即「成功」）
    reg         rx_done_to;   // 应答 Ncr 超时退出 1 拍脉冲（信息即「超时」）

    // —— [4] 命令 CRC 查表 ——
    reg  [6:0]  crc7_nxt;     // 当前命令的 CRC7 组合查表值

    // —— [5] 事务引擎 ——
    reg  [5:0]  xact_cmd;     // 当前事务命令号（帧组装用）
    reg  [31:0] xact_arg;     // 当前事务参数
    reg         xact_r48;     // 1=收 48bit 应答（R3/R7），0=只收 R1（8bit）
    reg         xact_busy;    // 事务占用中（TX+RX 相）
    reg         xact_done;    // 事务完成 1 拍脉冲
    reg         xact_rx_ok;   // 应答起始位在 Ncr 时限内收到
    reg  [47:0] xact_rx;      // 应答原始 48bit（R1 落 [7:0]；R3 OCR 载荷落 [39:8]，R7 echo 落 [15:8]）
    reg         xact_req_d;   // 请求状态打一拍：上升沿检测出「发起」脉冲
    wire        xact_req;     // 请求状态（TX 态即请求，TX 态持续期间状态机不动）
    wire        req_i_fire;   // 初始化序列机请求标志（命令扇入选择用）
    wire [5:0]  cmd_idx_wire; // 当前请求的命令号扇入
    wire [31:0] xact_arg_wire;// 当前请求的参数扇入
    wire        xact_r48_wire;// 当前请求的应答位宽扇入
    wire        xact_start;   // 请求上升沿 = 发起脉冲

    // —— [6] 初始化序列机 ——
    localparam [3:0] I_POWERUP = 4'd0;  // 上电延时等待
    localparam [3:0] I_IDLE    = 4'd1;  // 等 init_start
    localparam [3:0] I_SEND80  = 4'd2;  // 发 80 个 SCK 空周期
    localparam [3:0] I_C0_TX   = 4'd3;  // CMD0 事务进行中（引擎自动发起）
    localparam [3:0] I_C0_RX   = 4'd4;  // CMD0 应答判定（期望 0x01）
    localparam [3:0] I_C8_TX   = 4'd5;  // CMD8 事务进行中（arg=0x1AA）
    localparam [3:0] I_C8_RX   = 4'd6;  // CMD8 应答判定（R7 echo 校验）
    localparam [3:0] I_C55_TX  = 4'd7;  // CMD55 事务进行中（ACMD 前导）
    localparam [3:0] I_C55_RX  = 4'd8;  // CMD55 应答判定（期望 0x01）
    localparam [3:0] I_C41_TX  = 4'd9;  // ACMD41 事务进行中（arg HCS=1）
    localparam [3:0] I_C41_RX  = 4'd10; // ACMD41 应答判定（OCR busy/CCS）
    localparam [3:0] I_DONE    = 4'd11; // 初始化成功（保持电平）
    localparam [3:0] I_FAIL    = 4'd12; // 初始化失败（保持电平）
    reg  [3:0]  st_init;      // 初始化序列状态
    reg  [3:0]  retry_cnt;    // CMD0 重试计数
    reg  [16:0] c41_loop;     // ACMD41 循环计数（上限 65536 需 17 位；卡内部初始化最长约 1s）
    reg  [16:0] pow_cnt;      // 上电延时计数（2^17 拍 @25MHz≈5.2ms）
    reg         cs_n_i;       // 序列机私有片选（合成见块[8]）
    reg  [3:0]  err_code_i;   // 序列机私有错误码（合成见块[8]）

    // —— [7] 读块状态机 ——
    localparam [2:0] B_IDLE  = 3'd0;   // 空闲
    localparam [2:0] B_TX    = 3'd1;   // CMD17 事务进行中
    localparam [2:0] B_TOK   = 3'd2;   // 字节对齐滑窗等数据令牌 0xFE
    localparam [2:0] B_DATA  = 3'd3;   // 512 字节数据流出
    localparam [2:0] B_CRC   = 3'd4;   // 尾部 CRC16 接收（16 位）
    localparam [2:0] B_TAIL  = 3'd5;   // 收尾（拉 CS、出 done/err）
    reg  [2:0]  st_blk;       // 读块状态
    reg  [31:0] blk_addr_r;   // 扇区号锁存
    reg  [19:0] tok_cnt;      // 数据相位拍计数（超时上限 TOKEN_TIMEOUT）
    reg  [2:0]  tok_bits;     // 字节内位计数（模 8 自然回绕）
    reg  [7:0]  tok_shift;    // 令牌/数据字节移位累积
    reg  [12:0] data_bit_cnt; // 数据位总计数（0~4095）
    reg  [4:0]  crc_bit_cnt;  // CRC16 接收位计数（0~15）
    reg         tok_active;   // 数据相有效（令牌+数据+CRC 期间 SCK 运行）
    reg         cs_n_b;       // 读块机私有片选（合成见块[8]）
    reg  [2:0]  err_code_b;   // 读块机私有错误码（合成见块[8]）

    // —— [8] CRC16 校验器 ——
    reg  [15:0] crc16_r;      // 本地 CRC16 计算寄存器（多项式 0x1021）
    reg  [15:0] crc16_rx;     // 卡发来的 CRC16（尾部 16 位收入）
    wire        crc_fb;       // CRC 反馈位 = 移位最高位 ^ 当前行位

    // ------------------------------------------------------------------------
    // [1] SCK 分频发生器：翻转式分频 + 边沿检测
    // ------------------------------------------------------------------------
    // 边沿锚点组合定义：rise=SCK 刚升高（MISO 采样），fall=SCK 刚降低（MOSI 更新）
    assign sck_rise = sck_r & ~sck_d;
    assign sck_fall = ~sck_r & sck_d;
    // SCK 运行条件：事务引擎占用 / 发送相 / 应答接收相 / 数据相 / 80 SCK 空周期
    assign sck_en   = xact_busy | tx_active | rx_wait | rx_got | tok_active
                    | (st_init == I_SEND80);
    // 块[1a]：SCK 翻转计数——使能期间每 sck_div_r 拍翻转一次，撤销后回低
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 6'd0;
            sck_r   <= 1'b0;
            sck_d   <= 1'b0;
        end else begin
            sck_d <= sck_r;
            if (sck_en) begin
                if (div_cnt >= sck_div_r - 6'd1) begin
                    div_cnt <= 6'd0;
                    sck_r   <= ~sck_r;   // 翻转点：半周期到
                end else begin
                    div_cnt <= div_cnt + 6'd1;
                end
            end else begin
                div_cnt <= 6'd0;
                sck_r   <= 1'b0;         // 空闲强制回低（SPI mode 0 空闲电平）
            end
        end
    end

    // ------------------------------------------------------------------------
    // [2] 发送移位器：发起拍预置首 bit，此后 fall 拍移位
    // ------------------------------------------------------------------------
    // 块[2a]：48bit 命令帧发送——时序为「预置 bit47 → rise#1 卡采样 →
    // fall#1 出 bit46 → rise#2 采样 → … → fall#47 出 bit0 → rise#48 采样」，
    // 共 48 个上升沿，位序不漂移。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift   <= 48'd0;
            tx_bit_cnt <= 6'd0;
            tx_active  <= 1'b0;
            tx_idle_d  <= 1'b0;
            sd_mosi    <= 1'b1;
        end else begin
            tx_idle_d <= tx_active;      // 接收相开启前的 1 拍隔离
            if (xact_start) begin
                // 锁存帧：{start 0, trans 1, cmd, arg, crc7, stop 1}
                tx_shift   <= {2'b01, xact_cmd, xact_arg, crc7_nxt, 1'b1};
                tx_bit_cnt <= 6'd0;
                tx_active  <= 1'b1;
                sd_mosi    <= 1'b0;      // 首位 start=0 立即上总线（关键：第一个边沿是 rise，不预置会漏发）
            end else if (tx_active && sck_fall) begin
                sd_mosi  <= tx_shift[46];            // 下一位（bit47 已在上一 rise 被卡采样）
                tx_shift <= {tx_shift[46:0], 1'b0};  // 左移 1 位对齐下一位（读 [46] 出 bit46→bit45→…）
                if (tx_bit_cnt == 6'd46) begin
                    tx_active <= 1'b0;   // 预置 1 次 + fall 47 次 = 48 位发完
                    sd_mosi   <= 1'b1;   // 应答期 MOSI 回高（dummy 0xFF）
                end else begin
                    tx_bit_cnt <= tx_bit_cnt + 6'd1;
                end
            end else if (!tx_active && !xact_busy) begin
                sd_mosi <= 1'b1;         // 空闲期 MOSI 保持高
            end
        end
    end

    // ------------------------------------------------------------------------
    // [3] 应答接收器：安全隔离 → 等 MISO 变低 → 收 8/48bit → rx_done
    // ------------------------------------------------------------------------
    // 块[3a]：应答位接收与 Ncr 超时——发送相结束 + tx_idle_d 隔离 1 拍后，
    // 每个 sck_rise 采样 MISO：变低即起始位，随后收 xact_r48 位。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_shift   <= 48'd0;
            rx_bit_cnt <= 6'd0;
            rx_wait    <= 1'b0;
            rx_got     <= 1'b0;
            ncr_cnt    <= 8'd0;
            rx_done_ok <= 1'b0;
            rx_done_to <= 1'b0;
        end else begin
            rx_done_ok <= 1'b0;
            rx_done_to <= 1'b0;
            if (tx_active || !xact_busy) begin
                // 发送相 / 事务未占用：接收器保持复位态
                rx_wait <= 1'b0;
                rx_got  <= 1'b0;
                ncr_cnt <= 8'd0;
            end else if (!rx_wait && !rx_got && !tx_idle_d) begin
                rx_wait <= 1'b1;         // 发送结束隔 1 拍后才开启（防最后命令位回显误采）
                ncr_cnt <= 8'd0;
            end else if (rx_wait) begin
                if (sck_rise) begin
                    if (!sd_miso) begin
                        rx_wait    <= 1'b0;
                        rx_got     <= 1'b1; // 起始位捕获
                        rx_bit_cnt <= 6'd0;
                        rx_shift   <= {47'd0, sd_miso};
                    end else if (ncr_cnt == NCR_TIMEOUT[7:0]) begin
                        rx_wait    <= 1'b0;
                        rx_done_to <= 1'b1; // 超时退出（rx_done_to 即超时信息）
                    end else begin
                        ncr_cnt <= ncr_cnt + 8'd1;
                    end
                end
            end else if (rx_got && sck_rise) begin
                rx_shift <= {rx_shift[46:0], sd_miso};
                if (rx_bit_cnt == (xact_r48 ? 6'd47 : 6'd7)) begin
                    rx_got     <= 1'b0;
                    rx_done_ok <= 1'b1;  // 应答收满交付（rx_done_ok 即成功信息）
                end else begin
                    rx_bit_cnt <= rx_bit_cnt + 6'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // [4] 命令 CRC 查表（组合）：CMD0/CMD8 固定 CRC，其余 SPI 模式 CRC off
    // ------------------------------------------------------------------------
    always @(*) begin
        case (xact_cmd)
            6'd0:    crc7_nxt = 7'h4A;   // CMD0：帧尾字节 0x95
            6'd8:    crc7_nxt = 7'h43;   // CMD8(arg=0x1AA)：帧尾字节 0x87
            default: crc7_nxt = 7'h7F;   // 其余：CRC off，帧尾字节 0xFF
        endcase
    end

    // ------------------------------------------------------------------------
    // [5] 事务引擎：请求状态上升沿 → 自动发起 → rx_done 交付
    // ------------------------------------------------------------------------
    // 请求编码：初始化序列机各 TX 态 / 读块机 B_TX 态。状态即请求——
    // 序列机把状态摆到 TX 态，引擎检测上升沿自动锁存命令并驱动收发，
    // 完成后序列机在 RX 态等 xact_done 判定（同拍状态已转走，不会重发）。
    // 请求/扇入 assign 见声明区（vlog 要求先声明后引用，集中管理）。
    assign xact_start = xact_req & ~xact_req_d;   // 请求上升沿 = 发起脉冲
    // 命令扇入：初始化序列机优先（读块只在 init_done 后被放进 B_TX，天然互斥）
    assign xact_req = (st_init == I_C0_TX)  | (st_init == I_C8_TX)
                    | (st_init == I_C55_TX) | (st_init == I_C41_TX)
                    | (st_blk  == B_TX);
    assign req_i_fire = (st_init == I_C0_TX)  | (st_init == I_C8_TX)
                      | (st_init == I_C55_TX) | (st_init == I_C41_TX);
    assign cmd_idx_wire = req_i_fire ? (st_init == I_C0_TX  ? 6'd0  :
                                        st_init == I_C8_TX  ? 6'd8  :
                                        st_init == I_C55_TX ? 6'd55 : 6'd41)
                                     : 6'd17;
    assign xact_arg_wire = req_i_fire ? (st_init == I_C8_TX  ? 32'h0000_01AA :
                                         st_init == I_C41_TX ? 32'h4000_0000 :
                                         32'd0)
                                      : blk_addr_r;
    assign xact_r48_wire = req_i_fire ? ((st_init == I_C8_TX) | (st_init == I_C41_TX))
                                      : 1'b0;
    // 块[5a]：事务主控——发起锁存、完成交付
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xact_cmd   <= 6'd0;
            xact_arg   <= 32'd0;
            xact_r48   <= 1'b0;
            xact_busy  <= 1'b0;
            xact_done  <= 1'b0;
            xact_rx_ok <= 1'b0;
            xact_rx    <= 48'd0;
            xact_req_d <= 1'b0;
        end else begin
            xact_done  <= 1'b0;
            xact_req_d <= xact_req;
            if (xact_start) begin
                xact_cmd  <= cmd_idx_wire;
                xact_arg  <= xact_arg_wire;
                xact_r48  <= xact_r48_wire;
                xact_busy <= 1'b1;
            end else if (rx_done_ok) begin
                xact_busy  <= 1'b0;
                xact_done  <= 1'b1;
                xact_rx_ok <= 1'b1;          // 正常收满：成功交付
                xact_rx    <= rx_shift;      // 收满拍 rx_shift 已是完整值
            end else if (rx_done_to) begin
                xact_busy  <= 1'b0;
                xact_done  <= 1'b1;
                xact_rx_ok <= 1'b0;          // 超时退出：失败交付
            end
        end
    end

    // ------------------------------------------------------------------------
    // [6] 初始化序列机：上电→80 SCK→CMD0→CMD8→(CMD55+ACMD41)×N→DONE/FAIL
    // ------------------------------------------------------------------------
    // 块[6a]：序列主控——所有等待都有出口，失败带错误码停机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_init   <= I_POWERUP;
            retry_cnt <= 4'd0;
            c41_loop  <= 17'd0;
            pow_cnt   <= 17'd0;
            cnt80     <= 7'd0;
            init_done <= 1'b0;
            init_fail <= 1'b0;
            err_code_i<= 4'd0;
            sck_div_r <= SCK_INIT_DIV[5:0];
            cs_n_i    <= 1'b1;
        end else begin
            case (st_init)
                I_POWERUP: begin
                    init_done <= 1'b0;
                    init_fail <= 1'b0;
                    if (pow_cnt == {17{1'b1}}) begin
                        pow_cnt <= 17'd0;    // 计满≈5.2ms，卡电源就绪
                        st_init <= I_IDLE;
                    end else begin
                        pow_cnt <= pow_cnt + 17'd1;
                    end
                end
                I_IDLE: begin
                    if (init_start) begin
                        cnt80 <= 7'd0;
                        cs_n_i <= 1'b1;      // 空周期期间 CS 保持高
                        st_init <= I_SEND80;
                    end
                end
                I_SEND80: begin
                    cs_n_i <= 1'b1;
                    if (sck_rise) begin
                        if (cnt80 == 7'd79) begin
                            retry_cnt <= 4'd0;
                            st_init   <= I_C0_TX;
                        end else begin
                            cnt80 <= cnt80 + 7'd1; // 80 个 SCK 同步空周期
                        end
                    end
                end
                I_C0_TX: begin
                    cs_n_i  <= 1'b0;         // 命令期间 CS 拉低（引擎自动发起）
                    st_init <= I_C0_RX;
                end
                I_C0_RX: begin
                    if (xact_done) begin
                        cs_n_i <= 1'b1;      // R1 收完释放 CS
                        if (xact_rx_ok && xact_rx[7:0] == 8'h01) begin
                            st_init <= I_C8_TX;
                        end else if (retry_cnt == RETRY_MAX[3:0]) begin
                            err_code_i <= 4'd1;   // CMD0 重试用尽
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end else begin
                            retry_cnt <= retry_cnt + 4'd1;
                            st_init   <= I_SEND80; // 重新给空周期再试
                        end
                    end
                end
                I_C8_TX: begin
                    cs_n_i  <= 1'b0;
                    st_init <= I_C8_RX;
                end
                I_C8_RX: begin
                    if (xact_done) begin
                        cs_n_i <= 1'b1;                        // R7 应答帧布局：[47:40] R1、[31:16] voltage accepted、[15:8] echo
                        // （48bit 左移入 rx_shift，最后 8 位恰好落 [15:8]）
                        if (xact_rx_ok && xact_rx[15:8] == 8'hAA) begin
                            st_init <= I_C55_TX;
                        end else begin
                            err_code_i <= 4'd2;   // 非 SDv2 卡（或电压不受支持）
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end
                    end
                end
                I_C55_TX: begin
                    cs_n_i  <= 1'b0;
                    st_init <= I_C55_RX;
                end
                I_C55_RX: begin
                    if (xact_done) begin
                        cs_n_i <= 1'b1;
                        if (xact_rx_ok && xact_rx[7:0] == 8'h01) begin
                            st_init <= I_C41_TX;
                        end else begin
                            err_code_i <= 4'd2;   // CMD55 应答异常
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end
                    end
                end
                I_C41_TX: begin
                    cs_n_i  <= 1'b0;
                    st_init <= I_C41_RX;
                end
                I_C41_RX: begin
                    if (xact_done) begin
                        cs_n_i <= 1'b1;
                        if (!xact_rx_ok) begin
                            // 应答超时：继续轮询（卡忙时偶发丢弃）
                            if (c41_loop == ACMD41_LOOPS[15:0]) begin
                                err_code_i <= 4'd3;
                                init_fail  <= 1'b1;
                                st_init    <= I_FAIL;
                            end else begin
                                c41_loop <= c41_loop + 17'd1;
                                st_init  <= I_C55_TX;
                            end
                        end else if (xact_rx[39] == 1'b1) begin
                            // R3 应答字节流 {R1, 0xC0, 0x00, 0x00, 0x00, 0xFF}：
                            // byte1=[39:32] 承载 OCR[31:24] → OCR[31]=rx[39]、CCS=OCR[30]=rx[38]
                            if (xact_rx[38] == 1'b1) begin
                                sck_div_r <= SCK_FAST_DIV[5:0]; // 切高速时钟
                                init_done <= 1'b1;
                                st_init   <= I_DONE;
                            end else begin
                                err_code_i <= 4'd4;   // OCR[30]=0：SDSC 不支持
                                init_fail  <= 1'b1;
                                st_init    <= I_FAIL;
                            end
                        end else begin
                            // OCR[31]=0：卡仍在初始化，继续轮询
                            if (c41_loop == ACMD41_LOOPS[15:0]) begin
                                err_code_i <= 4'd3;
                                init_fail  <= 1'b1;
                                st_init    <= I_FAIL;
                            end else begin
                                c41_loop <= c41_loop + 17'd1;
                                st_init  <= I_C55_TX;
                            end
                        end
                    end
                end
                I_DONE: begin
                    init_done <= 1'b1;       // 电平保持，等复位
                end
                I_FAIL: begin
                    init_fail <= 1'b1;       // 电平保持，等复位
                end
                default: begin
                    st_init <= I_IDLE;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // [7] 读块状态机：CMD17→R1==0x00→令牌 0xFE→512B 流出→CRC16→TAIL
    // ------------------------------------------------------------------------
    // 块[7a]：读块主控——blk_start 仅在 init_done 且空闲时被接受
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_blk       <= B_IDLE;
            blk_addr_r   <= 32'd0;
            blk_busy     <= 1'b0;
            blk_done     <= 1'b0;
            blk_err      <= 1'b0;
            tok_cnt      <= 20'd0;
            tok_bits     <= 3'd0;
            tok_shift    <= 8'd0;
            data_bit_cnt <= 13'd0;
            crc_bit_cnt  <= 5'd0;
            tok_active   <= 1'b0;
            data_valid   <= 1'b0;
            data_byte    <= 8'd0;
            crc16_r      <= 16'd0;
            crc16_rx     <= 16'd0;
            cs_n_b       <= 1'b1;
            err_code_b   <= 3'd0;
        end else begin
            blk_done   <= 1'b0;
            blk_err    <= 1'b0;
            data_valid <= 1'b0;
            case (st_blk)
                B_IDLE: begin
                    blk_busy <= 1'b0;
                    if (init_done && blk_start) begin
                        blk_addr_r   <= blk_addr;
                        blk_busy     <= 1'b1;
                        tok_active   <= 1'b0;
                        tok_bits     <= 3'd0;
                        tok_shift    <= 8'hFF;   // 滑窗预填 0xFF（令牌前导态）
                        data_bit_cnt <= 13'd0;
                        crc_bit_cnt  <= 5'd0;
                        crc16_r      <= 16'd0;   // CRC 初值（每次块读重置）
                        crc16_rx     <= 16'd0;
                        err_code_b   <= 3'd0;    // 清上次错误码（TAIL 判定依赖）
                        st_blk       <= B_TX;
                    end
                end
                B_TX: begin
                    cs_n_b <= 1'b0;          // 数据接收期间 CS 保持低（引擎自动发起 CMD17）
                    if (xact_done) begin
                        if (xact_rx_ok && xact_rx[7:0] == 8'h00) begin
                            tok_cnt    <= 20'd0;
                            tok_active <= 1'b1;
                            st_blk     <= B_TOK;
                        end else begin
                            err_code_b <= 3'd7; // CMD17 应答非 0x00
                            st_blk     <= B_TAIL;
                        end
                    end
                end
                B_TOK: begin
                    if (sck_rise) begin
                        if (tok_cnt == TOKEN_TIMEOUT[19:0]) begin
                            err_code_b <= 3'd5; // 令牌等待超时
                            st_blk     <= B_TAIL;
                        end else begin
                            tok_cnt   <= tok_cnt + 20'd1;
                            tok_shift <= {tok_shift[6:0], sd_miso};
                            tok_bits  <= tok_bits + 3'd1;   // 模 8 回绕
                            if (tok_bits == 3'd7) begin
                                // 字节对齐判定：R1 收完即字节对齐，每 8 位判一次
                                if ({tok_shift[6:0], sd_miso} == 8'hFE) begin
                                    tok_bits <= 3'd0;
                                    st_blk   <= B_DATA;
                                end else if (tok_shift[6] == 1'b0) begin
                                    // 高位为 0 的字节是错误令牌 0x0X（当前字节 MSB=滑动前 tok_shift[6]）
                                    err_code_b <= 3'd5;
                                    st_blk     <= B_TAIL;
                                end
                                // 0xFF：仍是前导，继续滑窗
                            end
                        end
                    end
                end
                B_DATA: begin
                    if (sck_rise) begin
                        tok_shift    <= {tok_shift[6:0], sd_miso};
                        crc16_r      <= {crc16_r[14:0], 1'b0}
                                      ^ (crc_fb ? 16'h1021 : 16'd0);
                        data_bit_cnt <= data_bit_cnt + 13'd1;
                        tok_bits     <= tok_bits + 3'd1;    // 模 8 回绕
                        if (tok_bits == 3'd7) begin
                            data_byte  <= {tok_shift[6:0], sd_miso};
                            data_valid <= 1'b1;
                            if (data_bit_cnt == 13'd4095) begin
                                tok_bits <= 3'd0;
                                tok_cnt  <= 20'd0;
                                st_blk   <= B_CRC; // 4096 位数据完，收 CRC16
                            end
                        end
                    end
                end
                B_CRC: begin
                    if (sck_rise) begin
                        crc16_rx <= {crc16_rx[14:0], sd_miso};
                        if (crc_bit_cnt == 5'd15) begin
                            st_blk <= B_TAIL;    // 16 位 CRC 收满，去比对
                        end else begin
                            crc_bit_cnt <= crc_bit_cnt + 5'd1;
                        end
                    end
                end
                B_TAIL: begin
                    cs_n_b    <= 1'b1;       // 收尾释放 CS
                    tok_active<= 1'b0;
                    if (err_code_b == 3'd0 && crc16_r == crc16_rx) begin
                        blk_done <= 1'b1;    // 数据+CRC 全部通过
                    end else begin
                        if (err_code_b == 3'd0) begin
                            err_code_b <= 3'd6; // CRC 比对失败
                        end
                        blk_err <= 1'b1;
                    end
                    st_blk <= B_IDLE;
                end
                default: st_blk <= B_IDLE;
            endcase
        end
    end
    // CRC 反馈位：数据相每个采样位与移位寄存器最高位异或
    assign crc_fb = crc16_r[15] ^ sd_miso;

    // ------------------------------------------------------------------------
    // [8] 输出合成：初始化期归序列机、init_done 后归读块机（规避多驱动）
    // ------------------------------------------------------------------------
    // init_done/init_fail 都是保持电平：init_fail 时读块机错误码必为 0（复位值），
    // init_done 后序列机不再写错误码——两路私有寄存器在时间上天然互斥。
    assign err_code = init_done ? {1'b0, err_code_b} : err_code_i;
    assign sd_cs_n  = init_done ? cs_n_b : cs_n_i;

endmodule
