// ============================================================================
// 文件名  : i2c_master.v
// 所在位置: rtl/sensor/i2c_master.v
// 所属层次: 传感器层 / I2C 总线物理层（主机）
// 作者    : 智播校园项目组
// 更新时间: 2026-11-01
// ============================================================================
// 【一】系统功能
//   智播校园（SmartCampusMedia）在「应急」模式下要根据环境温度联动：机箱内
//   温度过高时强制切到应急画面并拉响蜂鸣器。测温芯片是 AHT20（温湿度一体，
//   I2C 接口），挂在底板 40 针排母的 D1/E1 两个复用球上。
//
//   本模块只做**I2C 总线物理层**：把「发一个 START / 写一个字节 / 读一个字节 /
//   发一个 STOP」翻译成 SCL/SDA 两根线上的电平序列。它不知道 AHT20 是什么，
//   也不知道温度怎么算 —— 那是 aht20_ctrl 的职责。
//
// 【二】为什么要分成「物理层 / 器件驱动 / 阈值联动」三层
//   赛规对「成品模块是否含处理器」有追问风险（见 reports/plan_v2/
//   SPEC_CONSTRAINTS.md §3.1 的 L1/L2/L3 分类）。备选方案 B 是 EG4S20 片内
//   8 通道 SAR ADC + NTC 10k + 两个无源电阻，外部零芯片。A/B 两案要能靠一个
//   mux 切换，就要求**上层的「阈值 → 迟滞 → 联动」逻辑与具体传感器无关**。
//   分层边界（三层，各管一件事）：
//     i2c_master.v     ← 本文件。只认 I2C 电气时序，不认任何器件。
//     aht20_ctrl.v     ← 认 AHT20 的寄存器序列（0xBE/0x71/0xAC）、CRC8、温度换算。
//     thermal_guard.v  ← 只认「温度数值 + 有效脉冲」，不认底下是 AHT20 还是 NTC。
//   换成方案 B 时，只需把 aht20_ctrl 换成 sar_ntc_ctrl，thermal_guard 与
//   下游联动逻辑一行都不用改。
//
// 【三】接口与时序
//   事务模型（一次完整传输 = START → 若干字节 → STOP）：
//     start_req ──→ start_done
//     wr_req/wr_data ──→ wr_done/wr_ack     （wr_ack=1 表示从机回 ACK）
//     rd_req/rd_nack ──→ rd_done/rd_data    （rd_nack=1 表示本字节读完后主机回 NACK）
//     stop_req  ──→ stop_done
//   busy 在 start_done 之后拉高、stop_done 之后拉低，表示「总线被本主机占用」。
//   ★ 请求信号是**电平 + 上升沿有效**：发起方把 req 拉高并保持到对应 done 出现，
//     然后**必须释放**（拉低至少 1 拍）才能发起下一次请求。
//     为什么是电平而不是单拍脉冲：从 IDLE 到真正开始执行之间隔着相位同步，
//     单拍脉冲会在这段时间里消失，主机根本看不到。
//     为什么还要「上升沿有效」：一个电平请求在 done 之后仍然维持高电平时，
//     状态机回到 IDLE 会把它当成**新的一次**请求，于是一个写字节被发送两遍。
//     本模块因此对四个 req 各做一次延迟比较（见下面 req 边沿检测），
//     只有 0→1 跳变才被接受。发起方只要在 done 后释放 req，语义就是
//     「一次拉高 = 一次操作」，不会重复触发。
//
// 【四】开漏输出为什么是「释放」语义而不是「驱动高」
//   I2C 是开漏总线，任何设备只能「拉低」或「放手」，高电平靠外部上拉电阻。
//   若 FPGA 主动驱动高电平，从机拉低时就变成两个推挽对打，长期会烧 IO。
//   因此本模块输出 scl_oe / sda_oe 两个「使能」：
//     scl_oe = 1 → 释放（高阻，外部上拉为高）
//     scl_oe = 0 → 拉低
//   顶层接法（必须是三态，不能写成 assign scl = scl_oe）：
//     assign i2c_scl = scl_oe ? 1'bz : 1'b0;
//     assign i2c_sda = sda_oe ? 1'bz : 1'b0;
//   引脚约束里 .adc 必须给 PULLTYPE = PULLUP，否则总线上没有上拉、永远读不到高。
//
// 【五】时钟分频与速率
//   SCL 周期 = 4 × QUARTER 个 clk，四个相位分别对应
//     phase0 = SCL 低（数据改变窗口）
//     phase1 = SCL 高（数据稳定，从机采样）
//     phase2 = SCL 高（主机采样从机数据）
//     phase3 = SCL 低（保持）
//   QUARTER 用**向上取整**而不是向下：向下取整会让实际 SCL 超过标称值。
//   25 MHz / (4×62) = 100.8 kHz 已经超出标准模式 100 kHz 上限；取 63 得
//   99.2 kHz，留出裕量。AHT20 手册支持到 400 kHz，100 kHz 是最保守的档位，
//   长排线（D1/E1 到排母）上的边沿更干净。
//   参数化后换主频（例如以后换 50 MHz）只需改 CLK_FREQ_HZ，不必动逻辑。
//
// 【六】为什么用「相位计数 + 状态机」而不是「移位寄存器串行输出」
//   本设计每位占 4 个相位，相位由 q_cnt 计数到 QUARTER 推进。这样：
//     1) SCL 的占空比恒为 50%，且与数据位严格对齐，不会因为状态切换抖动；
//     2) 从机采样点（phase1/phase2 的 SCL 高电平期）与主机采样点分离，
//        读字节时主机在 phase2 采样，此时从机数据早已稳定；
//     3) 加宽 QUARTER 只影响速度，不影响任何功能，便于 tb 里把 QUARTER 调小
//        加速仿真（tb 里把 SCL_FREQ_HZ 调大即可）。
// ============================================================================
module i2c_master #(
    parameter integer CLK_FREQ_HZ = 25_000_000, // 主时钟频率（Hz）
    parameter integer SCL_FREQ_HZ = 100_000     // 目标 SCL 频率（Hz），AHT20 支持 ≤400k
) (
    input  wire        clk,          // 主时钟（本工程 25 MHz）
    input  wire        rst_n,        // 异步复位，低有效
    // —— 事务边界 ——
    input  wire        start_req,    // 电平请求：发起 START
    output reg         start_done,   // 单拍：START 已发出
    input  wire        stop_req,     // 电平请求：发起 STOP
    output reg         stop_done,    // 单拍：STOP 已发出，总线释放
    // —— 写字节（主机 → 从机）——
    input  wire        wr_req,       // 电平请求：发送 wr_data
    input  wire [7:0]  wr_data,      // 待发送字节（MSB 先出）
    output reg         wr_done,      // 单拍：字节已发完且收到应答位
    output reg         wr_ack,       // 与 wr_done 同拍有效：1=ACK（从机应答），0=NACK
    // —— 读字节（从机 → 主机）——
    input  wire        rd_req,       // 电平请求：接收一个字节
    input  wire        rd_nack,      // 采样于 rd_req 有效期间：1=本字节后主机回 NACK
    output reg  [7:0]  rd_data,      // 与 rd_done 同拍有效：收到的字节
    output reg         rd_done,      // 单拍：字节已收完且应答位已发出
    // —— 开漏引脚（1=释放/高，0=拉低；顶层必须接三态）——
    output wire        scl_oe,
    output wire        sda_oe,
    input  wire        sda_in,       // SDA 回读（从机应答与数据都从这里读）
    // —— 状态 ——
    output reg         busy          // 1 = 总线被本主机占用（START 之后、STOP 之前）
);

    // ========================================================================
    // 参数换算
    //   QUARTER = clk 每相位拍数，向上取整（见文件头【五】）
    //   例：25 MHz / (100 kHz × 4) = 62.5 → 63，实际 SCL = 99.2 kHz
    // ========================================================================
    localparam integer QUARTER_RAW = (CLK_FREQ_HZ + SCL_FREQ_HZ * 4 - 1) / (SCL_FREQ_HZ * 4);
    localparam integer QUARTER     = (QUARTER_RAW < 1) ? 1 : QUARTER_RAW;
    // 相位计数位宽：QUARTER 最大 1023（对应 SCL ≥ 6.1 kHz @25 MHz），够覆盖
    // 任何合理的 I2C 速率；固定 10 位而不引 $clog2，避免个别综合器对系统函数
    // 在参数表达式里的支持差异。
    localparam integer QW = 10;

    // ========================================================================
    // 状态编码
    //   S_ACKRX = 写字节之后接收从机应答
    //   S_ACKTX = 读字节之后发送主机应答（最后一字节回 NACK，其余回 ACK）
    // ========================================================================
    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_TX    = 3'd2,
                     S_ACKRX = 3'd3,
                     S_RX    = 3'd4,
                     S_ACKTX = 3'd5,
                     S_STOP  = 3'd6;

    reg [2:0]      state;
    reg [1:0]      phase;        // 0..3，四相位
    reg [QW-1:0]   q_cnt;        // 相位内计数
    reg [3:0]      bit_idx;      // 0..7 位序
    reg [7:0]      tx_shift;     // 发送移位寄存器（MSB 先出）
    reg [7:0]      rx_shift;     // 接收移位寄存器
    reg            ack_bit;      // 从机应答采样值

    // 相位结束：本相位最后一拍。用于推进 bit_idx / 切换状态。
    //   写成 wire 而不是在 always 里重复比较，是为了让"什么时候进下一拍"
    //   只有一个定义点，改 QUARTER 时不会漏改某处。
    wire phase_last = (q_cnt == QUARTER - 1);
    wire phase_end  = (phase == 2'd3) && phase_last;
    wire phase_mid  = (phase == 2'd2) && (q_cnt == {QW{1'b0}});

    // ========================================================================
    // 请求边沿检测（见文件头【三】的 ★ 段）
    //   四个 req 各打一拍，只有 0→1 跳变被接受。
    //   为什么必须有这一层：状态机每次做完一个操作都回到 S_IDLE，若发起方
    //   在 done 之后仍把 req 保持为高，S_IDLE 会把它当成一次新的请求，
    //   于是一个字节被发送两遍、或者 STOP 被发两次（第二次 STOP 会破坏
    //   后续事务的起始条件）。加边沿检测后语义变成「一次拉高 = 一次操作」，
    //   对发起方更宽容（不释放也不会重复触发），但正确用法仍是 done 后释放。
    // ========================================================================
    reg start_req_d, stop_req_d, wr_req_d, rd_req_d;
    wire start_pulse = start_req & ~start_req_d;
    wire stop_pulse  = stop_req  & ~stop_req_d;
    wire wr_pulse    = wr_req    & ~wr_req_d;
    wire rd_pulse    = rd_req    & ~rd_req_d;

    // ========================================================================
    // 引脚电平推导（纯组合，不寄存）
    //   为什么组合：SCL/SDA 的每一次翻转都必须与 phase 严格同拍。如果寄存一拍，
    //   SCL 高电平期就会整体后移一个 clk，从机在错误的边沿采样，读回全错。
    //   该块是 scl_oe / sda_oe 的**唯一**驱动点（满足 lint 的 E2 规则）。
    // ========================================================================
    reg scl_oe_r;
    reg sda_oe_r;

    always @(*) begin
        // 默认：两线都释放（总线空闲时为高）
        scl_oe_r = 1'b1;
        sda_oe_r = 1'b1;

        case (state)
            // ---- START: SCL 高电平期间 SDA 由高变低 ----
            //   phase0 两线保持高；phase1 拉低 SDA（此刻 SCL 仍高 → 起始条件）；
            //   phase2 起拉低 SCL，为第一位数据做准备。
            S_START: begin
                if (phase >= 2'd1) scl_oe_r = 1'b1;   // 前两相位 SCL 高
                if (phase >= 2'd2) scl_oe_r = 1'b0;   // 后两相位 SCL 低
                if (phase >= 2'd1) sda_oe_r = 1'b0;   // SDA 在 SCL 高时下降
            end

            // ---- 发送一位: SCL 低时改数据，SCL 高时数据稳定 ----
            S_TX: begin
                scl_oe_r = ((phase == 2'd1) || (phase == 2'd2)) ? 1'b1 : 1'b0;
                sda_oe_r = tx_shift[7] ? 1'b1 : 1'b0;
            end

            // ---- 接收从机应答位: SDA 必须释放，由从机拉低 ----
            S_ACKRX: begin
                scl_oe_r = ((phase == 2'd1) || (phase == 2'd2)) ? 1'b1 : 1'b0;
                sda_oe_r = 1'b1;
            end

            // ---- 接收一位: SDA 同样释放 ----
            S_RX: begin
                scl_oe_r = ((phase == 2'd1) || (phase == 2'd2)) ? 1'b1 : 1'b0;
                sda_oe_r = 1'b1;
            end

            // ---- 发送主机应答: ACK = 拉低 SDA，NACK = 放手 ----
            S_ACKTX: begin
                scl_oe_r = ((phase == 2'd1) || (phase == 2'd2)) ? 1'b1 : 1'b0;
                sda_oe_r = rd_nack ? 1'b1 : 1'b0;
            end

            // ---- STOP: SCL 高电平期间 SDA 由低变高 ----
            //   phase0 SCL 低 SDA 低；phase1 抬高 SCL；phase2 释放 SDA（→ 停止条件）。
            S_STOP: begin
                scl_oe_r = (phase >= 2'd1) ? 1'b1 : 1'b0;
                sda_oe_r = (phase >= 2'd2) ? 1'b1 : 1'b0;
            end

            // ---- 空闲: 分两种情形，必须分开处理 ----
            //   ① 总线空闲（busy=0）：两线都释放，总线回到"空闲高"。
            //   ② 总线被占用（busy=1，刚做完 START / 刚发完一个字节，正在等
            //      下一个请求）：**SCL 必须保持低、SDA 保持低**。
            //      这一条是本模块最容易写错的地方：如果空闲态一律释放两线，
            //      那么 START 完成回到 S_IDLE 的那一拍，SCL 会被抬成高、
            //      SDA 也被抬成高 —— 从机的边沿检测会把这当成 **STOP 条件**，
            //      事务当场作废，后续所有字节都被忽略。
            //      同理，字节之间 SDA 保持低也不会被误采样：从机只在 SCL
            //      上升沿采样，而占用期间 SCL 一直是低。
            default: begin
                if (busy) begin
                    scl_oe_r = 1'b0;    // SCL 保持低
                    sda_oe_r = 1'b0;    // SDA 保持低（由下一个状态接管）
                end else begin
                    scl_oe_r = 1'b1;    // 释放
                    sda_oe_r = 1'b1;    // 释放
                end
            end
        endcase
    end

    assign scl_oe = scl_oe_r;
    assign sda_oe = sda_oe_r;

    // ========================================================================
    // 主状态机（唯一的时序块）
    //   本块是 state / phase / q_cnt / bit_idx / 各 done 脉冲的唯一驱动点。
    //   全部使用非阻塞赋值（lint E1 要求同一 always 块内不得混用）。
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            phase      <= 2'd0;
            q_cnt      <= {QW{1'b0}};
            bit_idx    <= 4'd0;
            tx_shift   <= 8'd0;
            rx_shift   <= 8'd0;
            ack_bit    <= 1'b1;
            busy       <= 1'b0;
            start_done <= 1'b0;
            stop_done  <= 1'b0;
            wr_done    <= 1'b0;
            wr_ack     <= 1'b1;
            rd_data    <= 8'd0;
            rd_done    <= 1'b0;
            start_req_d <= 1'b0;
            stop_req_d  <= 1'b0;
            wr_req_d    <= 1'b0;
            rd_req_d    <= 1'b0;
        end else begin
            // ---- 四个 done 脉冲默认回零：它们只在对应状态结束时置一拍 ----
            start_done <= 1'b0;
            stop_done  <= 1'b0;
            wr_done    <= 1'b0;
            rd_done    <= 1'b0;

            // ---- 请求边沿检测打拍（无条件跟随输入，供下一拍比较）----
            start_req_d <= start_req;
            stop_req_d  <= stop_req;
            wr_req_d    <= wr_req;
            rd_req_d    <= rd_req;

            // ---- 四相位节拍：q_cnt 到顶就翻相位 ----
            if (phase_last) begin
                q_cnt <= {QW{1'b0}};
                phase <= phase + 2'd1;      // 2 位自然回绕 3→0
            end else begin
                q_cnt <= q_cnt + 1'b1;
            end

            case (state)
                // ------------------------------------------------------------
                // 空闲：等 START / 字节 / STOP 请求
                //   空闲时强制 phase=0、q_cnt=0，保证每次事务都从相位 0 起步。
                //   这两条赋值写在节拍推进之后，因此会覆盖本拍的计数结果。
                // ------------------------------------------------------------
                S_IDLE: begin
                    phase   <= 2'd0;
                    q_cnt   <= {QW{1'b0}};
                    bit_idx <= 4'd0;

                    if (!busy) begin
                        // 总线空闲：只接受 START
                        if (start_pulse) begin
                            busy  <= 1'b1;
                            state <= S_START;
                        end
                    end else begin
                        // 总线已占用：STOP 优先（任何异常都能靠 STOP 收尾）
                        if (stop_pulse) begin
                            state <= S_STOP;
                        end else if (wr_pulse) begin
                            tx_shift <= wr_data;
                            state    <= S_TX;
                        end else if (rd_pulse) begin
                            state    <= S_RX;
                        end
                    end
                end

                // ------------------------------------------------------------
                // START：4 个相位走完即完成
                // ------------------------------------------------------------
                S_START: begin
                    if (phase_end) begin
                        start_done <= 1'b1;
                        state      <= S_IDLE;
                    end
                end

                // ------------------------------------------------------------
                // 发送一位：SCL 低时移位，8 位发完转去收应答
                // ------------------------------------------------------------
                S_TX: begin
                    if (phase_end) begin
                        if (bit_idx == 4'd7) begin
                            bit_idx <= 4'd0;
                            state   <= S_ACKRX;
                        end else begin
                            bit_idx  <= bit_idx + 4'd1;
                            tx_shift <= {tx_shift[6:0], 1'b0};
                        end
                    end
                end

                // ------------------------------------------------------------
                // 收从机应答
                //   采样点：phase2 的第一拍（SCL 已高电平半个相位，数据稳定）。
                //   QUARTER ≥ 2 时采样值与"相位结束时的 ack_bit"必然一致；
                //   默认 QUARTER = 63，远大于 2。
                //
                //   ★ 极性：I2C 的应答是"从机把 SDA 拉低"，所以 **SDA 为低
                //     （sda_in=0）才代表 ACK**。ack_bit 直接存线电平，输出
                //     wr_ack 时取反，使对外语义符合本模块的端口注释
                //     「wr_ack=1 表示从机回 ACK」。这两句必须成对出现，
                //     少一个取反就会出现"从机明明应答了、主机却报 NACK"
                //     或者"从机没应答、主机却当成成功"的静默错误 ——
                //     两种错误都不会有任何仿真报错，只会在板子上表现为
                //     "传感器读不到数据"。
                // ------------------------------------------------------------
                S_ACKRX: begin
                    if (phase_mid) begin
                        ack_bit <= sda_in;
                    end
                    if (phase_end) begin
                        wr_done <= 1'b1;
                        wr_ack  <= ~ack_bit;
                        state   <= S_IDLE;
                    end
                end

                // ------------------------------------------------------------
                // 接收一位：8 位收完转去发主机应答
                // ------------------------------------------------------------
                S_RX: begin
                    if (phase_mid) begin
                        rx_shift <= {rx_shift[6:0], sda_in};
                    end
                    if (phase_end) begin
                        if (bit_idx == 4'd7) begin
                            bit_idx <= 4'd0;
                            state   <= S_ACKTX;
                        end else begin
                            bit_idx <= bit_idx + 4'd1;
                        end
                    end
                end

                // ------------------------------------------------------------
                // 发主机应答：rd_nack=1 → 放手（NACK），否则拉低（ACK）
                // ------------------------------------------------------------
                S_ACKTX: begin
                    if (phase_end) begin
                        rd_data <= rx_shift;
                        rd_done <= 1'b1;
                        state   <= S_IDLE;
                    end
                end

                // ------------------------------------------------------------
                // STOP：4 个相位走完释放总线
                // ------------------------------------------------------------
                S_STOP: begin
                    if (phase_end) begin
                        stop_done <= 1'b1;
                        busy      <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
