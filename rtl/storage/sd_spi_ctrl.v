// ============================================================================
// 文件名：rtl/storage/sd_spi_ctrl.v
// 【一、在整体系统中的功能】
//   阶段四存储链最底层：SD SPI 引脚 ←→ 本模块 ←→ sd_probe / 后续 FAT32。
//   把卡端位级时序封装成初始化状态与单扇区 512 字节流；不解析文件系统。
// 【二、本模块功能】
//   SDHC-only 初始化：80 空时钟→CMD0→CMD8→CMD55/ACMD41 轮询→CMD58。
//   CMD8 返回 40 位 R7；ACMD41 只返回 8 位 R1（01=忙，00=就绪）；
//   CMD58 返回 40 位 R3，用 OCR[31] 和 OCR[30] 确认上电完成及块寻址能力。
//   CMD17 单块读：R1→按字节等待 FE→512 字节→CRC16→结束；全程只读。
//   初始化分频为 390.625kHz，完成后为 12.5MHz；无卡/错误均有界退出。
// 【三、接口与内部结构】
//   输入：clk/rst_n，init_start，blk_start/blk_addr，sd_miso。
//   输出：init_done/init_fail，err_code，blk_busy/blk_done/blk_err，
//         data_valid/data_byte，sd_cs_n/sd_sck/sd_mosi；详细位宽与极性见端口。
//   内部：①分频与命令间空时钟；②48 位命令发送；③8/40 位应答接收；
//         ④CMD0/CMD8 CRC7 常量；⑤共享事务引擎；⑥初始化状态机；
//         ⑦读块/CRC16 状态机；⑧片选与错误码合成。
//   err_code：1=CMD0 重试用尽；2=CMD8/CMD55 异常；3=ACMD41/CMD58 异常；
//             4=非 SDHC；5=令牌超时/错误；6=CRC16 错；7=CMD17 应答异常。
//   成功数据在 data_valid 拍输出；上层必须等待 blk_done 才认可整块校验结果。
// 【四、设计思路与范式】
//   两级 FSM：序列层决定发什么命令，事务层处理收发；全部在 clk 上升沿运行。
//   SPI mode 0：fall 更新 MOSI，rise 采 MISO；命令首位预置，直到第 48 个
//   rise 采到 stop 才结束发送，避免默认慢分频下提前把卡 DO 当应答。
//   CMD17 的 R1 由位接收器直接交给读块机，避免 FAST_DIV=1 时丢后续第一位；
//   后续按完整 8 位字节判 token，不以跨字节滑窗把 FF+错误 token 误判为 FE。
//   CRC16：多项式 0x1021、初值 0、MSB-first；参数上限用完整比较，禁止截断。
//   片选高时保留 NCC_CYCLES 个空时钟是本实现的命令间隔策略，不是已证实的
//   真卡故障根因；不假定“CS 低后绝对不允许 FF”。主机复位不等于卡断电。
//   规范依据：SDA Physical Layer Simplified Specification v9.10 §7.2.1、
//   §7.3.2.1/4/6；R3/R7 均为 R1+32 位载荷，不附带第六个 CRC 字节。
// ============================================================================
module sd_spi_ctrl #(
    parameter CLK_FREQ_HZ   = 25_000_000, // 主时钟频率（Hz），全系统统一 25MHz
    parameter SCK_INIT_DIV  = 32,         // 初始化 SCK 半周期拍数：25M/(2*32)=390.6kHz（卡要求 100~400kHz）
    parameter SCK_FAST_DIV  = 1,          // 读数据 SCK 半周期拍数：25M/(2*1)=12.5MHz（SPI 模式保守高速档）
    parameter NCR_TIMEOUT   = 128,        // 应答前导等待上限（位拍）：Ncr 最大 64 位，取 2 倍余量
    parameter ACMD41_LOOPS  = 65536,      // ACMD41 最大轮询次数；总时间还取决于 SCK 与应答延迟
    parameter TOKEN_TIMEOUT = 1_048_576,  // 令牌等待上限（位拍）：2^20 /12.5MHz≈83.89ms
    parameter RETRY_MAX     = 8,          // CMD0 重试上限：卡上电静默期偶发无应答，8 次足够
    parameter POWERUP_CYCLES = 131_071,  // 上电延时拍数（2^17-1 ≈ 5.24ms @25MHz；tb 可调小加速）
    parameter NCC_CYCLES    = 8           // 本实现片选高时的命令间空时钟数，支持 1~15
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
    reg         sck_r;        // SCK 内部翻转寄存器（使能期间每 DIV 拍翻转）
    reg         sck_d;        // sck_r 打一拍，供边沿检测
    wire        sck_rise;     // SCK 上升沿拍（1 拍脉冲）：MISO 采样锚点
    wire        sck_fall;     // SCK 下降沿拍（1 拍脉冲）：MOSI 更新锚点
    wire        sck_en;       // SCK 翻转使能（活动期间才跑，空闲保持低）
    reg  [5:0]  sck_div_r;    // 当前半周期拍数（init 成功后 INIT→FAST 切换）
    reg  [6:0]  cnt80;        // 上电 80 个 SCK 空周期计数

    // —— [2] 发送移位器 ——
    reg  [47:0] tx_shift;     // 命令帧移位寄存器（左移，bit47 先出）
    reg  [5:0]  tx_bit_cnt;   // 已 fall 移位次数（0~47，预置首 bit 不计数）
    reg         tx_active;    // 发送相有效（fall 拍移位）
    reg         tx_idle_d;    // tx_active 打一拍：接收相开启前的安全隔离
    reg         ncc_need;     // 上一条命令已结束、下一条仍需补 Ncc（CS 保持高时数 SCK）
    reg  [3:0]  ncc_cnt;      // 已补的 Ncc SCK 个数（数下降沿；满 NCC_CYCLES 后清 ncc_need）
    wire        ncc_ready;    // Ncc 已满足，允许拉低 CS 发下一条命令
    wire        cs_n_int;     // 内部 CS 合成值（初始化期取 cs_n_i、init_done 后取 cs_n_b）
    reg         cs_n_int_d;   // cs_n_int 打一拍，用于检测 CS 上升沿（一条命令窗口结束）
    wire        cs_rise;      // CS 由低变高 1 拍脉冲 = 命令窗口收尾，Ncc 计时起点

    // —— [3] 应答接收器 ——
    reg  [47:0] rx_shift;     // 应答移位寄存器（左移入）
    reg  [5:0]  rx_bit_cnt;   // 已接收位数
    reg         rx_wait;      // 正在等 MISO 变低（应答起始位）
    reg         rx_got;       // 已捕获起始位，正在收应答位
    reg  [7:0]  ncr_cnt;      // 应答等待计数（Ncr 超时用）
    reg         rx_done_ok;   // 应答正常收满 1 拍脉冲（交付引擎，信息即「成功」）
    reg         rx_done_to;   // 应答 Ncr 超时退出 1 拍脉冲（信息即「超时」）

    // —— [4] 命令 CRC 查表 ——
    reg  [6:0]  crc7_nxt;     // 按引擎寄存器 xact_cmd 译码的 CRC7 查表值（兼容保留）
    reg  [6:0]  crc7_of_idx;  // 按当拍扇入 cmd_idx_wire 译码的 CRC7 查表值（发起拍锁帧用）

    // —— [5] 事务引擎 ——
    reg  [5:0]  xact_cmd;     // 当前事务命令号（帧组装用）
    reg  [31:0] xact_arg;     // 当前事务参数
    reg         xact_r40;     // 1=收 40bit 应答（R3/R7），0=只收 R1（8bit）
    reg         xact_busy;    // 事务占用中（TX+RX 相）
    reg         xact_done;    // 事务完成 1 拍脉冲
    reg         xact_rx_ok;   // 应答起始位在 Ncr 时限内收到
    reg  [47:0] xact_rx;      // 右对齐应答：R1=[7:0]；R3/R7=[39:0]，载荷=[31:0]
    reg         xact_req_d;   // 请求状态打一拍：上升沿检测出「发起」脉冲
    wire        xact_req;     // 请求状态（TX 态即请求，TX 态持续期间状态机不动）
    wire        req_i_fire;   // 初始化序列机请求标志（命令扇入选择用）
    wire [5:0]  cmd_idx_wire; // 当前请求的命令号扇入
    wire [31:0] xact_arg_wire;// 当前请求的参数扇入
    wire        xact_r40_wire;// 当前请求的应答位宽扇入
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
    localparam [3:0] I_C41_RX  = 4'd10; // ACMD41 的 R1：01=继续初始化，00=就绪
    localparam [3:0] I_DONE    = 4'd11; // 初始化成功（保持电平）
    localparam [3:0] I_FAIL    = 4'd12; // 初始化失败（保持电平）
    localparam [3:0] I_C58_TX  = 4'd13; // CMD58 读取 OCR（仅 ACMD41 就绪后）
    localparam [3:0] I_C58_RX  = 4'd14; // R3 的 R1、OCR power-up、CCS 校验
    reg  [3:0]  st_init;      // 初始化序列状态
    reg  [3:0]  retry_cnt;    // CMD0 重试计数
    reg  [16:0] c41_loop;     // ACMD41 循环计数（上限 65536 需 17 位；卡内部初始化最长约 1s）
    reg  [16:0] pow_cnt;      // 上电延时计数（上限 POWERUP_CYCLES，默认≈5.24ms）
    reg         cs_n_i;       // 序列机私有片选（合成见块[8]）
    reg  [3:0]  err_code_i;   // 序列机私有错误码（合成见块[8]）

    // —— [7] 读块状态机 ——
    localparam [2:0] B_IDLE  = 3'd0;   // 空闲
    localparam [2:0] B_TX    = 3'd1;   // 拉低 CS 等待事务引擎发起 CMD17
    localparam [2:0] B_R1    = 3'd6;   // 已发起，等 R1 应答（0x00=接受）
    localparam [2:0] B_TOK   = 3'd2;   // 按字节对齐等待数据令牌 0xFE
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
    // 注意：sck_rise/sck_fall 检测的是内部 sck_r 的边沿（超前输出 sd_sck 一拍），
    // 收发器都以此拍为时序锚点——输出延迟 1 拍不影响协议（卡在下一个真实边沿动作）。
    assign sck_rise = sck_r & ~sck_d;
    assign sck_fall = ~sck_r & sck_d;
    // SCK 运行条件：事务发起拍 / 事务引擎占用 / 发送相 / 应答接收相 / 数据相 / 80 SCK 空闲周期
    // 注意 xact_start 必须计入：发起拍 xact_busy/tx_active 还是旧值 0（NBA 下一拍才
    // 生效），若 sck_en=0 会走空闲 else 分支——sck_d 被旧 sck_r 灌成 1 而 sck_r 清 0，
    // 下一拍制造假 fall 锚点，发送器误移位吞掉 start 位（本模块最深的一个坑）。
    assign sck_en   = xact_start | xact_busy | tx_active | rx_wait | rx_got | tok_active
                    | ncc_need | cs_rise | (st_init == I_SEND80);
    // 内部 CS 合成（与块[8]输出同一份表达式）：Ncc 计时需要观察 CS 上升沿，
    // 放在块[1b]之前定义，避免用到后面块[8] 的 assign。
    assign cs_n_int  = init_done ? cs_n_b : cs_n_i;
    assign cs_rise   = cs_n_int & ~cs_n_int_d;   // CS 由低变高 = 命令窗口收尾
    // 就绪条件同时排除 CS 上升拍，避免 ncc_need 尚未 NBA 更新时提前放行。
    // 输入：片选上升与空时钟计数；输出：命令请求门控 ncc_ready。
    assign ncc_ready = ~ncc_need & ~cs_rise;
    // 块[1b]：输入 CS 上升、sck_fall，输出 ncc_need/ncc_cnt。
    // 从真正的片选释放开始补空时钟，不能从 CMD17 的 R1 完成拍开始计时。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ncc_need   <= 1'b0;
            ncc_cnt    <= 4'd0;
            cs_n_int_d <= 1'b1;
        end else begin
            cs_n_int_d <= cs_n_int;      // CS 上升沿检测的延迟拍
            if (cs_rise) begin
                ncc_need <= 1'b1;        // 一条命令窗口收尾：下一条命令前必须补满 Ncc
                ncc_cnt  <= 4'd0;
            end else if (ncc_need && sck_fall) begin
                if (ncc_cnt == NCC_CYCLES - 1) begin
                    ncc_need <= 1'b0;    // 补满：放行下一条命令
                    ncc_cnt  <= 4'd0;
                end else begin
                    ncc_cnt <= ncc_cnt + 4'd1;
                end
            end
        end
    end
    // 块[1a]：SCK 翻转计数——使能期间每 sck_div_r 拍翻转一次，撤销后回低
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 6'd0;
            sck_r   <= 1'b0;
            sck_d   <= 1'b0;
            sd_sck  <= 1'b0;
        end else begin
            sck_d <= sck_r;
            sd_sck <= sck_r;         // 输出跟随内部翻转寄存器（滞后 1 拍，建立时间充裕）
            if (sck_en) begin
                if (xact_start) begin
                    // 事务发起拍强制 SCK 重启：上一事务/80 空周期的收尾 fall
                    // 可能落在发起拍之后（如 SEND80 的 fall#80 晚于 xact_start），
                    // 会被发送器误当命令帧第一个 fall——start 位没有任何 rise
                    // 采样到就被覆盖，整帧错位。此处复位相位并同步清 sck_d：
                    // 若 sck_r 原为 1，仅拉低 sck_r 会制造一次假 fall 锚点
                    // （sck_fall=~sck_r&sck_d 在下一拍变 1），发送器同样会误移位；
                    // sck_d 一并清零后下一拍 sck_fall=0，start 位安全等到 rise#1。
                    div_cnt <= 6'd0;
                    sck_r   <= 1'b0;
                    sck_d   <= 1'b0;
                end else if (div_cnt >= sck_div_r - 6'd1) begin
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
    // 块[2a]：命令帧发送——预置 start=0 → rise#1 卡采样 → fall#1 出 bit46 →
    //   rise#2 采样 → … → fall#47 出 bit0 → rise#48 采样，共 48 个上升沿，位序不漂移。
    // 输入：xact_start、命令帧、SCK 锚点；输出：MOSI、tx_active。
    // 命令间空时钟在块[1b]完成；此处只负责完整 48 位命令。
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
                // 用当拍组合扇入（cmd_idx_wire/xact_arg_wire/crc7_nxt of cmd_idx_wire），
                // 不能用 xact_cmd 寄存器——NBA 下一拍才更新，发出去的会是上一条命令的帧
                // （T2 实锤：CMD8 窗口重发了 CMD0 帧，卡对 echo 校验失败静默）。
                tx_shift   <= {2'b01, cmd_idx_wire, xact_arg_wire, crc7_of_idx, 1'b1};
                tx_bit_cnt <= 6'd0;
                tx_active  <= 1'b1;
                sd_mosi    <= 1'b0;      // 首位 start=0 立即上总线（关键：第一个边沿是 rise，不预置会漏发）
            end else if (tx_active && sck_fall && tx_bit_cnt < 6'd47) begin
                sd_mosi  <= tx_shift[46];          // 上一位已在 rise 被卡采样，fall 放下一位
                tx_shift <= {tx_shift[46:0], 1'b0};
                tx_bit_cnt <= tx_bit_cnt + 6'd1;
            end else if (tx_active && sck_rise && tx_bit_cnt == 6'd47) begin
                // 必须等第 48 个 rise 采到 stop=1 后才交出发送权；DIV32 下尤其重要。
                tx_active <= 1'b0;
                sd_mosi   <= 1'b1;
            end else if (!tx_active && !xact_busy) begin
                sd_mosi <= 1'b1;         // 空闲期 MOSI 保持高
            end
        end
    end

    // ------------------------------------------------------------------------
    // [3] 应答接收器：完整发送结束 → 等 MISO 变低 → 收 8/40bit → rx_done
    // ------------------------------------------------------------------------
    // 块[3a]：应答位接收与 Ncr 超时——发送相结束 + tx_idle_d 隔离 1 拍后，
    // 输入：tx_active/xact_busy、MISO/SCK；输出：右对齐应答及正常/超时完成脉冲。
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
                // 帧发送相 / 事务未占用：接收器保持复位态。
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
                        // 当前采到的是 R1 的 MSB=0；清零后再收剩余 7/39 位。
                        // 完成后 R1 右对齐至 [7:0]，R3/R7 右对齐至 [39:0]。
                        rx_shift   <= 48'd0;
                    end else if (ncr_cnt == NCR_TIMEOUT[7:0]) begin
                        rx_wait    <= 1'b0;
                        rx_done_to <= 1'b1; // 超时退出（rx_done_to 即超时信息）
                    end else begin
                        ncr_cnt <= ncr_cnt + 8'd1;
                    end
                end
            end else if (rx_got && sck_rise) begin
                rx_shift <= {rx_shift[46:0], sd_miso};
                // 首个 0 已收，剩余 7/39 次；计数从 0 开始，终值分别为 6/38。
                if (rx_bit_cnt == (xact_r40 ? 6'd38 : 6'd6)) begin
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
    // crc7_of_idx 按当拍扇入命令号译码（发起拍锁帧用）；crc7_nxt 按引擎寄存器
    // xact_cmd 译码（保留兼容，若后续有非发起拍引用）。
    always @(*) begin
        case (cmd_idx_wire)
            6'd0:    crc7_of_idx = 7'h4A;   // CMD0：帧尾字节 0x95
            6'd8:    crc7_of_idx = 7'h43;   // CMD8(arg=0x1AA)：帧尾字节 0x87
            default: crc7_of_idx = 7'h7F;   // 其余：CRC off，帧尾字节 0xFF
        endcase
    end
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
    // 请求条件：TX 态 + 本机 CS 已上总线（低）+ Ncc 已补满。
    // cs_n_i/cs_n_b 为 NBA 下一拍才生效，若 TX 态第一拍即发起，帧头 1~2 位会在 CS
    // 仍高期间发出，卡按 CS 门控采不到这些位——必须等 CS 真正上总线的下一拍才允许发起。
    // ncc_ready 门控：上一条命令结束后需在 CS 高期间补满 NCC_CYCLES 个 SCK，未满时
    // 状态机虽已进 TX 态，但 CS 不会拉低（见各 TX 态的 cs_n<=0 守卫），自然也不会发起。
    assign xact_req = (((st_init == I_C0_TX)  | (st_init == I_C8_TX)
                     |  (st_init == I_C55_TX) | (st_init == I_C41_TX)
                     |  (st_init == I_C58_TX)) & ~cs_n_i
                     | ((st_blk == B_TX) & ~cs_n_b)) & ncc_ready;
    assign req_i_fire = (st_init == I_C0_TX)  | (st_init == I_C8_TX)
                      | (st_init == I_C55_TX) | (st_init == I_C41_TX)
                      | (st_init == I_C58_TX);
    assign cmd_idx_wire = req_i_fire ? (st_init == I_C0_TX  ? 6'd0  :
                                        st_init == I_C8_TX  ? 6'd8  :
                                        st_init == I_C55_TX ? 6'd55 :
                                        st_init == I_C41_TX ? 6'd41 : 6'd58)
                                     : 6'd17;
    assign xact_arg_wire = req_i_fire ? (st_init == I_C8_TX  ? 32'h0000_01AA :
                                         st_init == I_C41_TX ? 32'h4000_0000 :
                                         32'd0)
                                      : blk_addr_r;
    // SPI：CMD8(R7)、CMD58(R3)是 R1+32bit；ACMD41 仅有 R1。
    assign xact_r40_wire = req_i_fire ? ((st_init == I_C8_TX) | (st_init == I_C58_TX))
                                      : 1'b0;
    // 块[5a]：事务主控——发起锁存、完成交付
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xact_cmd   <= 6'd0;
            xact_arg   <= 32'd0;
            xact_r40   <= 1'b0;
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
                xact_r40  <= xact_r40_wire;
                xact_busy <= 1'b1;
            end else if (rx_done_ok) begin
                xact_busy  <= 1'b0;
                xact_done  <= 1'b1;
                xact_rx_ok <= 1'b1;          // 正常收满：成功交付
                xact_rx    <= rx_shift;      // 收满拍 rx_shift 已是完整值
            end else if (rx_done_to) begin
                xact_busy  <= 1'b0;
                xact_done  <= 1'b1;
                xact_rx_ok <= 1'b0;          // 超时退出：失败交付（xact_rx 保留旧值）
            end
        end
    end

    // ------------------------------------------------------------------------
    // [6] 初始化：上电→80 SCK→CMD0→CMD8→(CMD55+ACMD41)×N→CMD58→DONE/FAIL
    // ------------------------------------------------------------------------
    // 块[6a]：输入事务应答/超时，输出下条命令状态、片选、初始化结果及分频。
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
                    if (pow_cnt == POWERUP_CYCLES[16:0]) begin
                        pow_cnt <= 17'd0;    // 计满≈5.24ms（参数），卡电源就绪
                        st_init <= I_IDLE;
                    end else begin
                        pow_cnt <= pow_cnt + 17'd1;
                    end
                end
                I_IDLE: begin
                    if (init_start) begin
                        cnt80 <= 7'd0;
                        retry_cnt <= 4'd0;   // 启动初始化时清零（每轮重试不清，才能数到 RETRY_MAX）
                        cs_n_i <= 1'b1;      // 空周期期间 CS 保持高
                        st_init <= I_SEND80;
                    end
                end
                I_SEND80: begin
                    cs_n_i <= 1'b1;
                    if (sck_rise) begin
                        if (cnt80 == 7'd79) begin
                            st_init   <= I_C0_TX;
                        end else begin
                            cnt80 <= cnt80 + 7'd1; // 80 个 SCK 同步空周期
                        end
                    end
                end
                I_C0_TX: begin
                    // Ncc 未补满时保持 CS 高（此时不拉低、也不发起）：SCK 在 ncc_need
                    // 驱动下继续空翻，卡借这段时钟完成上一条命令的内部收尾
                    if (ncc_ready) begin
                        cs_n_i <= 1'b0;      // CS 上总线（NBA 下一拍生效）
                    end
                    if (xact_start) begin    // 引擎在 CS 已低后自动发起，发起拍才转 RX
                        st_init <= I_C0_RX;
                    end
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
                            cnt80     <= 7'd0; // 每轮重试都给完整 80 个时钟，不能沿用 79
                            st_init   <= I_SEND80;
                        end
                    end
                end
                I_C8_TX: begin
                    if (ncc_ready) begin     // Ncc 补满后才拉低 CS（见 I_C0_TX 说明）
                        cs_n_i <= 1'b0;
                    end
                    if (xact_start) begin
                        st_init <= I_C8_RX;
                    end
                end
                I_C8_RX: begin
                    if (xact_done) begin
                        cs_n_i <= 1'b1;
                        // R7 共 40 位：R1=01、保留位=0、VHS=1、echo=AA，全字段校验。
                        if (xact_rx_ok && xact_rx[39:0] == 40'h01_0000_01AA) begin
                            st_init <= I_C55_TX;
                        end else begin
                            err_code_i <= 4'd2;   // 非 SDv2 卡（或电压不受支持）
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end
                    end
                end
                I_C55_TX: begin
                    if (ncc_ready) begin     // Ncc 补满后才拉低 CS（见 I_C0_TX 说明）
                        cs_n_i <= 1'b0;
                    end
                    if (xact_start) begin
                        st_init <= I_C55_RX;
                    end
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
                    if (ncc_ready) begin     // Ncc 补满后才拉低 CS（见 I_C0_TX 说明）
                        cs_n_i <= 1'b0;
                    end
                    if (xact_start) begin
                        st_init <= I_C41_RX;
                    end
                end
                I_C41_RX: begin
                    if (xact_done) begin
                        cs_n_i <= 1'b1;
                        if (xact_rx_ok && xact_rx[7:0] == 8'h00) begin
                            st_init <= I_C58_TX; // 仅 R1=00 代表就绪；OCR 必须另发 CMD58
                        end else if (xact_rx_ok && xact_rx[7:0] != 8'h01) begin
                            err_code_i <= 4'd3; // ACMD41 返回非法命令等异常 R1
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end else if (c41_loop >= ACMD41_LOOPS - 1) begin
                            // 比较完整参数；不能切成 16 位，否则默认 65536 会变成 0。
                            err_code_i <= 4'd3;
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end else begin
                            c41_loop <= c41_loop + 17'd1;
                            st_init  <= I_C55_TX; // R1=01 或无应答：有界重试
                        end
                    end
                end
                I_C58_TX: begin
                    if (ncc_ready) begin
                        cs_n_i <= 1'b0;
                    end
                    if (xact_start) begin
                        st_init <= I_C58_RX;
                    end
                end
                I_C58_RX: begin
                    if (xact_done) begin
                        cs_n_i <= 1'b1;
                        // R3 共 40 位：[39:32]=R1，[31:0]=OCR；无独立 CRC 尾字节。
                        if (!xact_rx_ok || xact_rx[39:32] != 8'h00 || !xact_rx[31]) begin
                            err_code_i <= 4'd3; // OCR 未就绪或 CMD58 应答异常
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end else if (!xact_rx[30]) begin
                            err_code_i <= 4'd4; // OCR.CCS=0：本实现不支持 SDSC
                            init_fail  <= 1'b1;
                            st_init    <= I_FAIL;
                        end else begin
                            sck_div_r <= SCK_FAST_DIV[5:0];
                            init_done <= 1'b1;
                            st_init   <= I_DONE;
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
    // 块[7a]：输入块请求/位应答/MISO，输出块握手、字节流、读块片选与 CRC16。
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
                        tok_shift    <= 8'hFF;   // 暂存清空；R1 结束后重新建立 token 字节边界
                        data_bit_cnt <= 13'd0;
                        crc_bit_cnt  <= 5'd0;
                        crc16_r      <= 16'd0;   // CRC 初值（每次块读重置）
                        crc16_rx     <= 16'd0;
                        err_code_b   <= 3'd0;    // 清上次错误码（TAIL 判定依赖）
                        st_blk       <= B_TX;
                    end
                end
                B_TX: begin
                    if (ncc_ready) begin     // Ncc 补满后才拉低 CS（同 I_C0_TX 说明）
                        cs_n_b <= 1'b0;
                    end
                    if (xact_start) begin    // 引擎在 CS 已低后自动发起 CMD17
                        st_blk <= B_R1;
                    end
                end
                B_R1: begin
                    // 直接消费位接收器的完成拍，省去 xact_done 的额外交付拍。
                    // FAST_DIV=1 时下个 rise 仅隔两个 clk；否则会丢掉令牌第一位。
                    if (rx_done_ok || rx_done_to) begin
                        if (rx_done_ok && rx_shift[7:0] == 8'h00) begin
                            tok_cnt    <= 20'd0;
                            tok_bits   <= 3'd0;
                            tok_shift  <= 8'd0;
                            tok_active <= 1'b1;
                            st_blk     <= B_TOK;
                        end else begin
                            err_code_b <= 3'd7; // CMD17 应答超时或 R1 非 00
                            st_blk     <= B_TAIL;
                        end
                    end
                end
                B_TOK: begin
                    if (sck_rise) begin
                        tok_cnt   <= tok_cnt + 20'd1;
                        tok_shift <= {tok_shift[6:0], sd_miso};
                        tok_bits  <= tok_bits + 3'd1;
                        // R1 后第一位即开始新字节；只在第 8 位判 token，禁止跨字节拼 FE。
                        if (tok_bits == 3'd7 && {tok_shift[6:0], sd_miso} == 8'hFE) begin
                            tok_bits <= 3'd0;
                            st_blk   <= B_DATA;
                        end else if (tok_bits == 3'd7 && {tok_shift[6:0], sd_miso} != 8'hFF) begin
                            err_code_b <= 3'd5; // 错误令牌或非法非 FF 字节
                            st_blk     <= B_TAIL;
                        end else if (tok_cnt >= TOKEN_TIMEOUT - 1) begin
                            // 终值为上限减 1；完整比较，不把默认 2^20 切片成 0。
                            err_code_b <= 3'd5;
                            st_blk     <= B_TAIL;
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
    assign sd_cs_n  = cs_n_int;      // 与块[1b] 的 Ncc 计时共用同一份合成值

endmodule
