// ============================================================================
// 【一、在整体系统中的功能】
//   本文件是阶段四（SD 卡图片播放）S2 切片的**探针模块**，位于
//   "顶层 → sd_probe → sd_spi_ctrl → SD 卡"这条存储验证链的最上层。
//   工程归属: SmartCampusMedia 阶段四存储子系统。
//   数据流位置: sd_probe 是 sd_spi_ctrl 的唯一用户 —— 它按固定顺序驱动
//   "初始化 → 读扇区 0 → 校验 MBR 签名"三步，把链路健康状态凝练成
//   sd_ok / sd_fail 两个电平 + err_latch 错误码，供顶层 LED/数码管指示。
//   为什么需要它: S2 里程碑要求"上板读到 MBR 签名 0x55AA 灯亮"——
//   需要一段最小但完整的驱动序列把 SPI 链路跑通；这段序列机的正确性
//   直接决定 S3~S7（FAT32/BMP/帧缓冲）能否建立在可信的读块服务上。
//
// 【二、本模块功能】
//   一句话职责: 复位释放后延时发起 SD 卡初始化与扇区 0 读取，
//   检查第 510/511 字节是否为 MBR 签名 0x55 0xAA，输出健康状态。
//   关键特性:
//     · 单次执行: 上电跑一遍即停（成功/失败都锁定），不复位不重试
//       （S2 最小闭环；上电重试留给 S6 容错设计）；
//     · 内置 8ms 上电延迟，覆盖 sd_spi_ctrl 内部约 5.24ms 的
//       I_POWERUP 上电静默期（该期间 init_start 会被吞，见 tb 实测教训）；
//     · 签名检查只锁存第 510/511 两个字节，不缓存整块 512B。
//
// 【三、接口与内部结构】
//   参数:
//     CLK_FREQ_HZ         主时钟频率，全系统统一 25MHz
//     PROBE_DELAY_CYCLES  复位释放后的延迟拍数（默认 8ms@25MHz，> 5.24ms 上电期）
//   端口一览（全部对接 sd_spi_ctrl 同名端口，方向相对本模块而言）:
//     clk/rst_n           主时钟 25MHz / 异步复位低有效
//     init_start(输出脉冲) 启动初始化
//     init_done(输入电平)  初始化成功      init_fail(输入电平) 初始化失败
//     err_code[3:0](输入)  sd_spi_ctrl 错误码电平（1=无卡重试用尽 2=CMD8 …）
//     blk_start(输出脉冲)  启动读块        blk_addr[31:0](输出) 扇区号
//     blk_busy(输入电平)   读块进行中
//     blk_done(输入脉冲)   读块完成        blk_err(输入脉冲)   读块失败
//     data_byte[7:0](输入) 块数据字节      data_valid(输入脉冲) 字节有效
//     sd_ok(输出电平)      签名正确，链路健康
//     sd_fail(输出电平)    任一环节失败
//     err_latch[3:0](输出) 失败原因锁存（init 后保持 sd_spi_ctrl 的 err_code；
//                          读块失败时 5=错误令牌 6=CRC 错 7=应答错）
//   内部逻辑块（共 2 块，按信号流顺序）:
//     [1] 探针序列机   always @(posedge clk)（P_WAIT→P_INIT→P_RD→P_DATA→终态）
//     [2] 签名字节捕获 always @(posedge clk)（data_valid 时锁存 510/511 两字节）
//
// 【四、设计思路与范式】
//   范式定位: 有限状态机（FSM）—— 6 态线性主线，每态等待一个握手事件。
//   为什么这样写: probe 的本质是"按协议顺序走流程"，每个状态对应流程的
//   一个阶段，事件（done/fail/err 脉冲）驱动转移；与 sd_spi_ctrl 内部
//   两个序列机（初始化/读块）层层嵌套，构成"流程 → 事务 → 位流"三级。
//   关键写法要点:
//     · init_start/blk_start 都是 1 拍脉冲：在状态里先给 1 再无条件回 0，
//       避免"停留在某态时脉冲被反复拉高"；
//     · PROBE_DELAY 必须大于 sd_spi_ctrl 的 POWERUP 上电静默期，否则
//       init_start 落在 I_POWERUP 态被吞（tb 实测教训，勿删延迟）；
//     · 签名捕获独立于序列机（计数到 510/511 才锁存），使主 FSM 在
//       P_DATA 态只关心 blk_done/blk_err 两个事件，职责单一。
//   范式认读方法: 见 docs/design_patterns.md §3（FSM）。
// ============================================================================
module sd_probe #(
    parameter CLK_FREQ_HZ        = 25_000_000, // 主时钟频率（Hz），全系统统一 25MHz
    parameter PROBE_DELAY_CYCLES = 200_000     // 复位释放后延迟拍数: 8ms@25MHz
                                               //   必须大于 sd_spi_ctrl 的 POWERUP
                                               //   静默期（默认约 5.24ms），否则脉冲被吞
)(
    input  wire        clk,         // 主时钟 25MHz
    input  wire        rst_n,       // 异步复位，低有效
    // —— 对接 sd_spi_ctrl：初始化服务 ——
    output reg         init_start,  // 脉冲: 启动初始化（仅拉高 1 拍）
    input  wire        init_done,   // 电平: 初始化成功
    input  wire        init_fail,   // 电平: 初始化失败
    input  wire [3:0]  err_code,    // 电平: sd_spi_ctrl 错误码（本模块只读）
    // —— 对接 sd_spi_ctrl：读块服务 ——
    output reg         blk_start,   // 脉冲: 启动读一块
    output reg  [31:0] blk_addr,    // 电平: 扇区号（S2 固定读 0 = MBR）
    input  wire        blk_busy,    // 电平: 读块进行中（本模块未用，预留观察）
    input  wire        blk_done,    // 脉冲: 块读完成
    input  wire        blk_err,     // 脉冲: 块读失败
    input  wire [7:0]  data_byte,   // 电平: 块数据字节
    input  wire        data_valid,  // 脉冲: data_byte 有效
    // —— 结果输出 ——
    output reg         sd_ok,       // 电平: 扇区 0 签名 0x55AA 正确，链路健康
    output reg         sd_fail,     // 电平: 初始化/读块/签名任一环节失败
    output reg  [3:0]  err_latch    // 电平: 失败原因（进入终态时锁存）
);

    // ------------------------------------------------------------------------
    // 状态编码（localparam，见 docs/design_patterns.md §3）
    // ------------------------------------------------------------------------
    localparam [2:0] P_WAIT = 3'd0, // 上电延迟: 等 PROBE_DELAY_CYCLES 拍
                     P_INIT = 3'd1, // 等 init_done / init_fail
                     P_RD   = 3'd2, // 发 blk_start（扇区 0）
                     P_DATA = 3'd3, // 等 blk_done / blk_err
                     P_OK   = 3'd4, // 终态: 签名正确，sd_ok 恒 1
                     P_FAIL = 3'd5; // 终态: 任一环节失败，sd_fail 恒 1

    // —— [1] 探针序列机 ——
    reg  [2:0]  st;         // 【状态寄存器】P_* 六态
    reg  [17:0] delay_cnt;  // 【上电延迟计数器】P_WAIT 态递增
                            //   18 位够装 200_000（2^18=262144）
                            //   值必须 > sd_spi_ctrl POWERUP 期，否则脉冲被吞
    reg  [8:0]  byte_cnt;   // 【字节计数】data_valid 拍递增，0~511（块[2]用）
    reg  [7:0]  sig_lo2;    // 【第 510 字节】MBR 签名低字节（期望 0x55，块[2]锁存）
    reg  [7:0]  sig_hi;     // 【第 511 字节】MBR 签名高字节（期望 0xAA，块[2]锁存）
    reg         sig_lo;     // 【签名低字节标记】已锁存第 510 字节（本模块未读，
                            //   捕获工作由块[2]独立完成；保留用于调试扩展）

    // ------------- always 块 ① / 共 2 块: 探针主序列机 ----------------
    // 功能: 按协议顺序走 "延迟 → 初始化 → 读扇区 0 → 校验签名" 流程，
    //       每态等待一个握手事件，成功/失败进入锁定终态
    // 输入: init_done/init_fail/blk_done/blk_err + 签名字节（sig_hi/sig_lo）
    // 输出: st、init_start、blk_start、blk_addr、sd_ok、sd_fail、err_latch
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= P_WAIT;
            delay_cnt  <= 18'd0;
            init_start <= 1'b0;
            blk_start  <= 1'b0;
            blk_addr   <= 32'd0;
            sd_ok      <= 1'b0;
            sd_fail    <= 1'b0;
            err_latch  <= 4'd0;
            sig_lo     <= 1'b0;
        end else begin
            // 默认值: 两个脉冲信号只维持 1 拍，各状态分支按需再拉高
            init_start <= 1'b0;
            blk_start  <= 1'b0;
            case (st)
                // 上电延迟: 覆盖 sd_spi_ctrl 的 I_POWERUP 静默期，
                // 避免 init_start 在其进入 I_IDLE 前被吞
                P_WAIT: begin
                    if (delay_cnt == PROBE_DELAY_CYCLES[17:0]) begin
                        delay_cnt  <= 18'd0;
                        init_start <= 1'b1;             // 发起初始化（1 拍脉冲）
                        st         <= P_INIT;
                    end else begin
                        delay_cnt <= delay_cnt + 18'd1;
                    end
                end
                // 等初始化结果: sd_spi_ctrl 的 init_done/init_fail 是电平信号
                P_INIT: begin
                    if (init_done) begin
                        blk_addr <= 32'd0;              // 扇区 0 = MBR
                        blk_start<= 1'b1;               // 发起读块（1 拍脉冲）
                        st       <= P_DATA;
                    end else if (init_fail) begin
                        err_latch <= err_code;          // 锁存失败码（如 1=无卡）
                        st        <= P_FAIL;
                    end
                end
                // 读块进行中: 等完成/失败脉冲；字节数据由块[2]独立捕获
                P_DATA: begin
                    if (blk_done) begin
                        if (sig_hi == 8'hAA && sig_lo2 == 8'h55) begin
                            sd_ok <= 1'b1;              // MBR 签名 0x55AA 正确
                            st    <= P_OK;
                        end else begin
                            err_latch <= 4'd8;          // 自定义: 签名不符
                            st        <= P_FAIL;
                        end
                    end else if (blk_err) begin
                        err_latch <= err_code;          // 5=错误令牌 6=CRC 7=应答
                        st        <= P_FAIL;
                    end
                end
                // 终态自锁: 成功/失败都保持，直到整板复位
                P_OK:   sd_ok   <= 1'b1;
                P_FAIL: sd_fail <= 1'b1;
                default: st <= P_WAIT;
            endcase
        end
    end

    // —— [2] 签名字节捕获 ——
    // （byte_cnt / sig_lo2 / sig_hi 声明在块[1]声明区——vlog 要求先声明后引用）

    // ------------- always 块 ② / 共 2 块: MBR 签名字节捕获 ----------------
    // 功能: data_valid 每拍收 1 字节，独立计数，只在 510/511 两拍锁存
    // 输入: data_valid, data_byte        输出: byte_cnt、sig_lo2、sig_hi
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt <= 9'd0;
            sig_lo2  <= 8'd0;
            sig_hi   <= 8'd0;
        end else if (data_valid) begin
            if (byte_cnt == 9'd510) begin
                sig_lo2  <= data_byte;              // 第 510 字节 → 0x55 期望
                byte_cnt <= byte_cnt + 9'd1;
            end else if (byte_cnt == 9'd511) begin
                sig_hi  <= data_byte;               // 第 511 字节 → 0xAA 期望
                byte_cnt <= 9'd0;                   // 块收完回零（防溢出残留）
            end else begin
                byte_cnt <= byte_cnt + 9'd1;
            end
        end
    end

endmodule
