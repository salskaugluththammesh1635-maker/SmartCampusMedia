// ============================================================================
// 文件名  : aht20_ctrl.v
// 所在位置: rtl/sensor/aht20_ctrl.v
// 所属层次: 传感器层 / AHT20 数字温湿度芯片驱动（A 方案）
// 作者    : 智播校园项目组
// 更新时间: 2026-11-01
// ============================================================================
// 【一】系统功能
//   本模块是「应急模式高温联动」链路的**上游**：定期从 AHT20 温湿度芯片
//   读回原始数据，换算成 0.01 ℃ / 0.01 %RH 的定点数，交给 thermal_guard
//   做阈值与迟滞判决。
//
//        i2c_master ──→ 【本模块】 ──→ thermal_guard ──→ 应急联动
//        (物理层)       (协议+换算)      (阈值判决)
//
//   分层的关键在于：thermal_guard 只吃「温度数值 + 有效脉冲」，不认识 AHT20。
//   因此把本模块整体替换成 NTC + 片内 SAR ADC 的驱动（t12 的 Plan B）时，
//   thermal_guard 与它下游的应急联动逻辑一行都不用改。
//
// 【二】AHT20 的通信流程（严格按数据手册）
//   芯片 7 位 I2C 地址 0x38 → 写地址字节 0x70、读地址字节 0x71。
//
//   ① 上电等待：手册要求上电后 40 ms 内不通信，本模块留 100 ms 余量。
//   ② 读状态（0x71 读 1 字节）：状态字节 bit3 = 校准使能标志（CAL）。
//      bit3=1 表示芯片已完成校准，可以正常测量；bit3=0 需要发软复位。
//      这一步不能省：AHT20 上电后要自己跑一次校准，校准时读回的温湿度
//      是无效值。跳过状态检查直接测量，第一次读数大概率是垃圾。
//   ③ 触发测量：写 0xAC 0x33 0x00 三个字节（命令码 + 两个参数）。
//   ④ 等待测量：手册 p.11 §5.2 要求等待 80 ms 测量完成，本模块等 80 ms
//      （MEAS_WAIT_CYCLES = 2_000_000 @ 25 MHz）。
//      ★ 这个 80 ms 一个周期都不能省。手册 p.12 注明确警告：发出测量命令
//        （0xAC 0x33 0x00）后未延时 80 ms，状态字 bit7 可能仍为 1，此时读回
//        的是**前一次测量命令**的温湿度数据 —— 不报错、数值也"像正常值"，
//        只是整条温度曲线延迟一拍加上去，极难从现象反推。
//      注：手册 p.6 §2.3 另要求"采集数据周期应大于 1 秒/1 次"，
//      故 PERIOD_CYCLES = 25_000_000（1 s）符合规格。
//   ⑤ 读结果：读 7 字节 = 6 字节数据 + 1 字节 CRC8。
//   ⑥ CRC8 校验：多项式 x^8+x^5+x^4+1 = 0x31，初始值 0xFF，
//      覆盖前 6 个数据字节，与第 7 字节比较。
//   ⑦ 换算：见【四】。
//   ⑧ 周期：默认 1 s 一次（参数 PERIOD_CYCLES）。
//
// 【三】6 字节数据的位域（手册 Table 8）
//     byte0 : 状态字节（bit7=忙, bit3=已校准）
//     byte1 : 湿度 [19:12]
//     byte2 : 湿度 [11:4]
//     byte3 : 湿度 [3:0] 在高 4 位，温度 [19:16] 在低 4 位  ← 注意是共享字节
//     byte4 : 温度 [15:8]
//     byte5 : 温度 [7:0]
//   所以：
//     湿度 raw = {byte1, byte2, byte3[7:4]}   （20 位）
//     温度 raw = {byte3[3:0], byte4, byte5}   （20 位）
//   byte3 同时承载湿度的低 4 位与温度的高 4 位，是这块芯片最容易读错的地方：
//   把 byte3 整字节都算进湿度（或都算进温度）会让两个量都错得离谱，
//   而且错得很"像正常值"（湿度偏高、温度跳变），极难从现象反推。
//
// 【四】换算公式与"为什么不用乘法器"
//   手册：  T(℃)   = raw/2^20 × 200 - 50
//           RH(%)  = raw/2^20 × 100
//   要 0.01 ℃ 分辨率：
//           T_centi = (raw × 20000) >> 20 - 5000
//   直接把 20000/2^20 约掉：
//           20000 / 1048576 = 1250 / 65536   （精确相等，不是近似！）
//   于是：
//           T_centi = (raw × 1250) >> 16 - 5000
//   而 1250 = 1024 + 128 + 64 + 32 + 2，可以用四次移位加法实现，
//   **完全不需要 DSP 乘法器**。这一点很重要：本工程 DSP 余量只有 10/29
//   （见 reports/plan_v2/RESOURCE_BUDGET.md），能省一个是一个。
//   同理湿度：
//           10000 / 1048576 = 625 / 65536     （同样精确）
//           RH_centi = (raw × 625) >> 16
//           625 = 512 + 64 + 32 + 16 + 1
//
//   位宽核算（避免溢出，这是定点换算最容易翻车的地方）：
//     温度：raw 最大 1048575（20 位），× 1250 = 1,310,718,750 < 2^31 → 31 位够
//           右移 16 位后最大 20000 → 15 位，减 5000 后范围 -5000 ~ +15000
//           → 16 位有符号（-32768 ~ +32767）足够，与 thermal_guard 的
//             temp_centi_c[15:0] 契约一致
//     湿度：raw 最大 1048575，× 625 = 655,359,375 < 2^30 → 30 位够
//           右移 16 位后最大 10000（即 100.00 %RH）
//
// 【五】错误处理与重试
//   本模块定义了 4 种错误，err_code 为电平保持（直到下一次成功才清）：
//     ERR_NACK   = 1  从机不应答（排线松、地址错、芯片没上电）
//     ERR_CRC    = 2  CRC8 校验失败（总线干扰、时序临界）
//     ERR_TIMEOUT= 3  状态检查反复失败（芯片未校准且软复位无效）
//     ERR_BUSY   = 4  读回的状态字节 bit7 一直为忙（测量卡死）
//   连续失败达到 RETRY_MAX 次就放弃本轮，等下一个周期再来 —— 绝不死循环
//   重试，否则一次偶发干扰会让整条链路卡住，OSD 上的"传感器异常"提示
//   反而永远不出现。
//
// 【六】为什么周期读而不是中断读
//   AHT20 没有中断引脚（只有 SDA/SCL/VCC/GND 四根线），只能靠主机轮询。
//   1 s 一次的周期对机箱温度这种慢变量完全够用（热时间常数以分钟计），
//   同时把 I2C 占用压到最低（一次事务约 3 ms，占空比 0.3%）。
// ============================================================================
module aht20_ctrl #(
    // ---- 时钟与节拍（单位：clk 拍）----
    parameter integer CLK_FREQ_HZ      = 25_000_000,   // clk 频率
    parameter integer POWERUP_CYCLES   = 2_500_000,    // 上电等待 100 ms
    parameter integer MEAS_WAIT_CYCLES = 2_000_000,    // 测量等待 80 ms
    parameter integer RESET_WAIT_CYCLES= 500_000,      // 软复位后等待 20 ms
    parameter integer PERIOD_CYCLES    = 25_000_000,   // 测量周期 1 s
    // ---- 重试上限 ----
    parameter integer RETRY_MAX        = 3,
    // ---- 芯片 I2C 地址（7 位）与命令码（按数据手册）----
    parameter [6:0]   DEV_ADDR         = 7'h38,
    parameter [7:0]   CMD_TRIGGER      = 8'hAC,        // 触发测量
    parameter [7:0]   CMD_TRIG_P0       = 8'h33,       // 触发参数 0
    parameter [7:0]   CMD_TRIG_P1       = 8'h00,       // 触发参数 1
    parameter [7:0]   CMD_SOFT_RESET    = 8'hBE,       // 软复位
    parameter [7:0]   CRC_POLY          = 8'h31        // CRC8: x^8+x^5+x^4+1
) (
    input  wire        clk,              // 25 MHz clk_pixel
    input  wire        rst_n,            // 异步复位，低有效

    // ---- 上游：i2c_master 原语接口 ----
    output reg         i2c_start_req,
    input  wire        i2c_start_done,
    output reg         i2c_stop_req,
    input  wire        i2c_stop_done,
    output reg         i2c_wr_req,
    output reg  [7:0]  i2c_wr_data,
    input  wire        i2c_wr_done,
    input  wire        i2c_wr_ack,       // 1=从机应答
    output reg         i2c_rd_req,
    output reg         i2c_rd_nack,      // 1=本字节读完后主机回 NACK
    input  wire        i2c_rd_done,
    input  wire [7:0]  i2c_rd_data,

    // ---- 下游：传感器无关的温度契约（见 thermal_guard 文件头【三】）----
    output reg  signed [15:0] temp_centi_c,   // 温度，单位 0.01 ℃
    output reg         temp_valid,            // 单拍：本拍 temp_centi_c 有效
    output reg  [15:0] humid_centi,           // 湿度，单位 0.01 %RH（备用显示）
    output reg         humid_valid,           // 单拍：本拍 humid_centi 有效

    // ---- 状态与诊断 ----
    output reg         cal_ok,           // 芯片已校准（电平）
    output reg         sensor_ok,        // 最近一轮测量成功（电平）
    output reg  [3:0]  err_code,         // 错误码（见【五】），0=无错
    output reg         busy,             // 正在执行一次事务（电平）

    // ---- 传感器无关契约（与 ntc_adc_ctrl 端口完全一致，见文件头【三】）----
    //   sensor_fault : 1 = 数据不可信（CRC 错 / 超时 / 超量程 / 未校准）
    //                  ★ 上级 thermal_guard **不得因 sensor_fault 触发应急模式**，
    //                    只做显示告警。传感器坏掉就把屏幕锁死在应急画面，
    //                    是比"没有高温联动"严重得多的失效。
    //   meas_tick    : 单拍，每完成一轮测量尝试（无论成功失败）拉高一次，
    //                  供上层观察"传感器还活着"（thermal_guard 的存活计数用）
    output reg         sensor_fault,
    output reg         meas_tick
);

    // ========================================================================
    // 状态编码
    //   每个状态对应一个 I2C 原语操作或一段等待。用显式状态而不是
    //   "微指令 ROM"，是因为状态数只有 20 个左右，展开写更好核对；
    //   ROM 方案省不了多少逻辑，却让"这一步到底发了什么"变得要查表。
    // ========================================================================
    //   ★ 可综合性提醒：Verilog-2001 的 `localparam` 是**一条一条独立语句**，
    //     不能像 `parameter` 那样用逗号把多条拼成一组（逗号列表只允许出现在
    //     module 参数表 `#(...)` 里）。写成组会报
    //     `near "localparam": syntax error, unexpected localparam`。
    //     故这里每条后面都是分号。
    // ========================================================================
    localparam [4:0] S_POWERUP   = 5'd0;    // 上电等待 100 ms
    localparam [4:0] S_CAL_START = 5'd1;    // 读状态：START
    localparam [4:0] S_CAL_WR    = 5'd2;    // 读状态：写 0x71
    localparam [4:0] S_CAL_RD    = 5'd3;    // 读状态：读 1 字节（NACK 收尾）
    localparam [4:0] S_CAL_STOP  = 5'd4;    // 读状态：STOP
    localparam [4:0] S_CAL_JUDGE = 5'd5;    // 判断 CAL 位
    localparam [4:0] S_RST_START = 5'd6;    // 软复位：START
    localparam [4:0] S_RST_WR0   = 5'd7;    // 软复位：写 0x70
    localparam [4:0] S_RST_WR1   = 5'd8;    // 软复位：写 0xBE
    localparam [4:0] S_RST_STOP  = 5'd9;    // 软复位：STOP
    localparam [4:0] S_RST_WAIT  = 5'd10;   // 软复位后等待 20 ms
    localparam [4:0] S_TRG_START = 5'd11;   // 触发：START
    localparam [4:0] S_TRG_WR0   = 5'd12;   // 触发：写 0x70
    localparam [4:0] S_TRG_WR1   = 5'd13;   // 触发：写 0xAC
    localparam [4:0] S_TRG_WR2   = 5'd14;   // 触发：写 0x33
    localparam [4:0] S_TRG_WR3   = 5'd15;   // 触发：写 0x00
    localparam [4:0] S_TRG_STOP  = 5'd16;   // 触发：STOP
    localparam [4:0] S_MEAS_WAIT = 5'd17;   // 等测量完成 80 ms
    localparam [4:0] S_RD_START  = 5'd18;   // 读结果：START
    localparam [4:0] S_RD_WR     = 5'd19;   // 读结果：写 0x71
    localparam [4:0] S_RD_BYTE   = 5'd20;   // 读结果：逐字节（7 次）
    localparam [4:0] S_RD_STOP   = 5'd21;   // 读结果：STOP
    localparam [4:0] S_CRC_UPD   = 5'd22;   // CRC8 逐位更新（每字节 8 拍）
    localparam [4:0] S_CHECK     = 5'd23;   // CRC 比对 + 换算
    localparam [4:0] S_PERIOD    = 5'd24;   // 周期等待 1 s
    localparam [4:0] S_FAILED    = 5'd25;   // 本轮放弃，转入周期等待

    // ---- 错误码 ----
    localparam [3:0] ERR_NONE    = 4'd0;
    localparam [3:0] ERR_NACK    = 4'd1;
    localparam [3:0] ERR_CRC     = 4'd2;
    localparam [3:0] ERR_TIMEOUT = 4'd3;
    localparam [3:0] ERR_BUSY    = 4'd4;

    // ---- 读结果字节数：6 数据 + 1 CRC ----
    localparam [2:0] RD_TOTAL    = 3'd7;

    // ========================================================================
    // 状态寄存器与计数器（全部在本模块唯一的时序块里驱动）
    // ========================================================================
    reg [4:0]  state;
    reg [31:0] wait_cnt;         // 通用等待计数器
    reg [2:0]  byte_idx;         // 读字节序号 0..6
    reg [3:0]  crc_bit;          // CRC 逐位更新的位计数 0..7
    reg [7:0]  crc_rx;           // 从芯片读到的 CRC 字节
    reg [7:0]  crc_calc;         // 本地计算的 CRC8
    reg [1:0]  retry_cnt;        // 本轮重试次数
    reg [1:0]  cal_try;          // 校准检查重试次数
    reg [7:0]  status_byte;      // 最近一次读到的状态字节

    // ---- 6 个数据字节（用独立 reg 而不是数组：综合后时序与资源都更可预期，
    //      也避免个别综合器对"数组 + 非恒定索引"的处理差异）----
    reg [7:0]  rb0, rb1, rb2, rb3, rb4, rb5;

    // ========================================================================
    // 定点换算（纯组合，见【四】）
    //   t_raw / h_raw 直接从字节里拼，不额外寄存 —— 它们只在 S_CHECK 用到，
    //   寄存反而多一拍延迟。
    // ========================================================================
    wire [19:0] t_raw = {rb3[3:0], rb4, rb5};          // 温度 20 位
    wire [19:0] h_raw = {rb1, rb2, rb3[7:4]};          // 湿度 20 位

    // raw × 1250 = (raw<<10) + (raw<<7) + (raw<<6) + (raw<<5) + (raw<<1)
    //   每一项都扩展到 31 位后相加，避免中间结果被截断。
    //   截断是本类换算最隐蔽的 bug：综合器不会报错，仿真在常温下也正常，
    //   只有温度接近量程端点时才出现"读数跳变"。
    wire [30:0] t_mul = ({11'd0, t_raw} << 10)
                      + ({11'd0, t_raw} <<  7)
                      + ({11'd0, t_raw} <<  6)
                      + ({11'd0, t_raw} <<  5)
                      + ({11'd0, t_raw} <<  1);

    // raw × 625 = (raw<<9) + (raw<<6) + (raw<<5) + (raw<<4) + raw
    wire [29:0] h_mul = ({10'd0, h_raw} <<  9)
                      + ({10'd0, h_raw} <<  6)
                      + ({10'd0, h_raw} <<  5)
                      + ({10'd0, h_raw} <<  4)
                      + ({10'd0, h_raw});

    // >> 16 后减 5000（温度偏置 -50.00 ℃）
    wire signed [15:0] t_centi_comb = $signed({1'b0, t_mul[30:16]}) - 16'sd5000;
    wire        [15:0] h_centi_comb = h_mul[29:16];

    // ========================================================================
    // CRC8 下一拍的组合值（多项式 0x31，MSB 先出）
    //   写成 wire 而不是在时序块里写 if/else，是为了让"CRC 到底怎么算"
    //   有一个可以单独对照手册看的定义点。
    // ========================================================================
    wire [7:0] crc_shift = crc_calc[7] ? ((crc_calc << 1) ^ CRC_POLY)
                                      : (crc_calc << 1);

    // 当前正在做 CRC 的字节（byte_idx 指向"下一个要读的字节"，
    // 因此刚读完的字节是 byte_idx-1；这里用 crc_bit==0 的时刻锁存）
    reg [7:0] crc_byte;
    always @(*) begin
        case (byte_idx)
            3'd1: crc_byte = rb0;
            3'd2: crc_byte = rb1;
            3'd3: crc_byte = rb2;
            3'd4: crc_byte = rb3;
            3'd5: crc_byte = rb4;
            3'd6: crc_byte = rb5;
            default: crc_byte = 8'h00;
        endcase
    end

    // ========================================================================
    // 主状态机（唯一的时序块）
    //   全部非阻塞赋值，满足 lint E1。
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_POWERUP;
            wait_cnt       <= 32'd0;
            byte_idx       <= 3'd0;
            crc_bit        <= 4'd0;
            crc_rx         <= 8'd0;
            crc_calc       <= 8'hFF;      // CRC8 初始值 0xFF
            retry_cnt      <= 2'd0;
            cal_try        <= 2'd0;
            status_byte    <= 8'd0;
            rb0            <= 8'd0;
            rb1            <= 8'd0;
            rb2            <= 8'd0;
            rb3            <= 8'd0;
            rb4            <= 8'd0;
            rb5            <= 8'd0;
            i2c_start_req  <= 1'b0;
            i2c_stop_req   <= 1'b0;
            i2c_wr_req     <= 1'b0;
            i2c_wr_data    <= 8'd0;
            i2c_rd_req     <= 1'b0;
            i2c_rd_nack    <= 1'b0;
            temp_centi_c   <= 16'sd0;
            temp_valid     <= 1'b0;
            humid_centi    <= 16'd0;
            humid_valid    <= 1'b0;
            cal_ok         <= 1'b0;
            sensor_ok      <= 1'b0;
            err_code       <= ERR_NONE;
            busy           <= 1'b0;
            // 复位即置故障：上电后第一轮测量成功前，数据都是不可信的。
            // 若复位给 0（"无故障"），上层会在传感器根本没应答的那 100 ms 里
            // 以为一切正常 —— fail-safe 的方向必须是"默认不可信"。
            sensor_fault   <= 1'b1;
            meas_tick      <= 1'b0;
        end else begin
            // ---- 所有请求默认回零：它们只在对应状态里置一拍 ----
            i2c_start_req <= 1'b0;
            i2c_stop_req  <= 1'b0;
            i2c_wr_req    <= 1'b0;
            i2c_rd_req    <= 1'b0;
            temp_valid    <= 1'b0;
            humid_valid   <= 1'b0;
            meas_tick     <= 1'b0;

            case (state)
                // ------------------------------------------------------------
                // 上电等待（见【二】①）
                // ------------------------------------------------------------
                S_POWERUP: begin
                    busy <= 1'b0;
                    if (wait_cnt >= POWERUP_CYCLES[31:0] - 32'd1) begin
                        wait_cnt <= 32'd0;
                        state    <= S_CAL_START;
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                // ------------------------------------------------------------
                // 读状态：START
                // ------------------------------------------------------------
                S_CAL_START: begin
                    busy          <= 1'b1;
                    i2c_start_req <= 1'b1;
                    if (i2c_start_done) begin
                        state <= S_CAL_WR;
                    end
                end

                // 读状态：写读地址 0x71（(DEV_ADDR<<1)|1）
                S_CAL_WR: begin
                    i2c_wr_data <= {DEV_ADDR, 1'b1};
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) begin
                            // 从机不应答：排线松/芯片没上电/地址错
                            err_code <= ERR_NACK;
                            state    <= S_CAL_STOP;
                        end else begin
                            state <= S_CAL_RD;
                        end
                    end
                end

                // 读状态：读 1 字节，NACK 收尾（只读一个字节）
                S_CAL_RD: begin
                    i2c_rd_nack <= 1'b1;
                    i2c_rd_req  <= 1'b1;
                    if (i2c_rd_done) begin
                        status_byte <= i2c_rd_data;
                        state       <= S_CAL_STOP;
                    end
                end

                S_CAL_STOP: begin
                    i2c_stop_req <= 1'b1;
                    if (i2c_stop_done) begin
                        state <= S_CAL_JUDGE;
                    end
                end

                // ------------------------------------------------------------
                // 判断校准位（状态字节 bit3）
                //   bit3=1 → 已校准，可以测量
                //   bit3=0 → 发软复位后重试，最多 RETRY_MAX 次
                // ------------------------------------------------------------
                S_CAL_JUDGE: begin
                    if (status_byte[3]) begin
                        cal_ok    <= 1'b1;
                        err_code  <= ERR_NONE;
                        cal_try   <= 2'd0;
                        state     <= S_TRG_START;
                    end else if (cal_try >= RETRY_MAX[1:0]) begin
                        // 反复软复位都校不准 → 判超时，转入周期等待
                        //   cal_ok 保持 0，下游据 err_code/cal_ok 显示"传感器异常"
                        cal_ok   <= 1'b0;
                        err_code <= ERR_TIMEOUT;
                        cal_try  <= 2'd0;
                        state    <= S_FAILED;
                    end else begin
                        cal_try <= cal_try + 2'd1;
                        state   <= S_RST_START;
                    end
                end

                // ------------------------------------------------------------
                // 软复位：写 0xBE（见【二】②）
                // ------------------------------------------------------------
                S_RST_START: begin
                    i2c_start_req <= 1'b1;
                    if (i2c_start_done) begin
                        state <= S_RST_WR0;
                    end
                end

                S_RST_WR0: begin
                    i2c_wr_data <= {DEV_ADDR, 1'b0};   // 写地址 0x70
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) begin
                            err_code <= ERR_NACK;
                            state    <= S_RST_STOP;
                        end else begin
                            state <= S_RST_WR1;
                        end
                    end
                end

                S_RST_WR1: begin
                    i2c_wr_data <= CMD_SOFT_RESET;
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) err_code <= ERR_NACK;
                        state <= S_RST_STOP;
                    end
                end

                S_RST_STOP: begin
                    i2c_stop_req <= 1'b1;
                    if (i2c_stop_done) begin
                        wait_cnt <= 32'd0;
                        state    <= S_RST_WAIT;
                    end
                end

                // 软复位后等 20 ms 让芯片重新校准
                S_RST_WAIT: begin
                    if (wait_cnt >= RESET_WAIT_CYCLES[31:0] - 32'd1) begin
                        wait_cnt <= 32'd0;
                        state    <= S_CAL_START;      // 回到读状态复查
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                // ------------------------------------------------------------
                // 触发测量：写 0xAC 0x33 0x00（见【二】③）
                //   ★ 这里踩过第二个真实的坑：最初在本状态里无条件写
                //     `retry_cnt <= 2'd0`。而 S_FAILED 的分支是
                //     「retry_cnt+1 → 回 S_TRG_START 重试」，于是每一次
                //     重试都被 S_TRG_START 清零 —— retry_cnt 永远等于 0，
                //     永远达不到 RETRY_MAX，失败后**无限重试、永不放弃**。
                //     表现：传感器根本没接时，仿真里状态机永远在
                //     TRG_START…FAILED 之间打转，meas_tick 一次都不来，
                //     sensor_fault 也永远停在第一个状态。
                //     现在 retry_cnt 只在「新的一轮完整周期开始时」清零，
                //     即 S_PERIOD 发起下一轮前（见 S_PERIOD）。
                // ------------------------------------------------------------
                S_TRG_START: begin
                    crc_calc      <= 8'hFF;          // 每轮测量重置 CRC
                    // ★ 第三个真实的坑：err_code 必须在新一轮触发前清掉。
                    //   原本这里不清，于是 S_TRG_STOP 的判断
                    //   `if (err_code != ERR_NONE) state <= S_FAILED;`
                    //   一旦某轮出现过 NACK/CRC 错，err_code 就**永久保持**
                    //   那个非零值 —— 之后每一轮哪怕 I2C 完全正常，
                    //   S_TRG_STOP 也照样跳 S_FAILED，永远走不到 S_MEAS_WAIT，
                    //   温度再也读不出来，sensor_fault 再也清不掉。
                    //   表现与"传感器一直坏"完全一样，但芯片其实早恢复了：
                    //   tb 里 C08d / C09c / C11c 三条"恢复后故障归零"全挂，
                    //   C14/C15 全挂，就是这个原因。
                    //   err_code 的语义是"**最近一轮**的错误码"，不是锁存，
                    //   因此每轮开始必须归零。
                    err_code      <= ERR_NONE;
                    i2c_start_req <= 1'b1;
                    if (i2c_start_done) begin
                        state <= S_TRG_WR0;
                    end
                end

                S_TRG_WR0: begin
                    i2c_wr_data <= {DEV_ADDR, 1'b0};   // 0x70
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) begin
                            err_code <= ERR_NACK;
                            state    <= S_TRG_STOP;
                        end else begin
                            state <= S_TRG_WR1;
                        end
                    end
                end

                S_TRG_WR1: begin
                    i2c_wr_data <= CMD_TRIGGER;        // 0xAC
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) begin
                            err_code <= ERR_NACK;
                            state    <= S_TRG_STOP;
                        end else begin
                            state <= S_TRG_WR2;
                        end
                    end
                end

                S_TRG_WR2: begin
                    i2c_wr_data <= CMD_TRIG_P0;        // 0x33
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) begin
                            err_code <= ERR_NACK;
                            state    <= S_TRG_STOP;
                        end else begin
                            state <= S_TRG_WR3;
                        end
                    end
                end

                S_TRG_WR3: begin
                    i2c_wr_data <= CMD_TRIG_P1;        // 0x00
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) err_code <= ERR_NACK;
                        state <= S_TRG_STOP;
                    end
                end

                S_TRG_STOP: begin
                    i2c_stop_req <= 1'b1;
                    if (i2c_stop_done) begin
                        if (err_code != ERR_NONE) begin
                            state <= S_FAILED;         // 写命令阶段就失败了
                        end else begin
                            wait_cnt <= 32'd0;
                            state    <= S_MEAS_WAIT;
                        end
                    end
                end

                // ------------------------------------------------------------
                // 等测量完成 80 ms（见【二】④）
                // ------------------------------------------------------------
                S_MEAS_WAIT: begin
                    if (wait_cnt >= MEAS_WAIT_CYCLES[31:0] - 32'd1) begin
                        wait_cnt <= 32'd0;
                        byte_idx <= 3'd0;
                        state    <= S_RD_START;
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                // ------------------------------------------------------------
                // 读结果：START + 0x71 + 7 字节（见【二】⑤）
                // ------------------------------------------------------------
                S_RD_START: begin
                    i2c_start_req <= 1'b1;
                    if (i2c_start_done) begin
                        state <= S_RD_WR;
                    end
                end

                S_RD_WR: begin
                    i2c_wr_data <= {DEV_ADDR, 1'b1};   // 0x71
                    if (!i2c_wr_done) i2c_wr_req <= 1'b1;
                    if (i2c_wr_done) begin
                        if (!i2c_wr_ack) begin
                            err_code <= ERR_NACK;
                            state    <= S_RD_STOP;
                        end else begin
                            state <= S_RD_BYTE;
                        end
                    end
                end

                // 逐字节读：byte_idx 0..5 回 ACK（还要继续读），
                //            byte_idx 6 回 NACK（最后一个字节，读完收手）
                //   为什么第 6 个要 NACK：若全部回 ACK，芯片会继续吐下一个
                //   字节，随后的 STOP 就变成"在数据中途强行停止"，
                //   芯片内部状态可能不干净，下一次事务容易出错。
                S_RD_BYTE: begin
                    i2c_rd_nack <= (byte_idx == 3'd6) ? 1'b1 : 1'b0;
                    i2c_rd_req  <= 1'b1;
                    if (i2c_rd_done) begin
                        case (byte_idx)
                            3'd0: rb0 <= i2c_rd_data;
                            3'd1: rb1 <= i2c_rd_data;
                            3'd2: rb2 <= i2c_rd_data;
                            3'd3: rb3 <= i2c_rd_data;
                            3'd4: rb4 <= i2c_rd_data;
                            3'd5: rb5 <= i2c_rd_data;
                            3'd6: crc_rx <= i2c_rd_data;
                            default: ;
                        endcase
                        if (byte_idx == 3'd6) begin
                            byte_idx <= 3'd0;
                            state    <= S_RD_STOP;
                        end else begin
                            // 进入 CRC 更新：本字节先参与 CRC，再读下一个
                            crc_bit  <= 4'd0;
                            byte_idx <= byte_idx + 3'd1;
                            state    <= S_CRC_UPD;
                        end
                    end
                end

                S_RD_STOP: begin
                    i2c_stop_req <= 1'b1;
                    if (i2c_stop_done) begin
                        state <= S_CHECK;
                    end
                end

                // ------------------------------------------------------------
                // CRC8 逐位更新（见【二】⑥）
                //   每个字节要处理 **1 次异或 + 8 次移位**，共 9 拍。
                //   ★ 这里踩过一次真实的坑：最初写成「crc_bit==0 异或，
                //     1..7 移位，到 8 就退出」，等于**每字节只移了 7 次**。
                //     少一次移位不会报错、不会告警，常温下读出的温度也
                //     "看起来对"——但本地算出的 CRC 与芯片给的 CRC 永远不等，
                //     于是每一轮都被判成 CRC 错、永远不输出温度。
                //     现改为 crc_bit 1..8 移位、到 9 才退出，共 8 次移位。
                //
                //   串行 8 拍而不是组合一次算完，是为了省 LUT：
                //   组合版要 8 级级联 XOR（约 40 个 LUT），串行版只要
                //   一个 8 位寄存器加两个 XOR（约 12 个 LUT），代价是
                //   每字节多 8 拍 —— 7 字节共 56 拍 = 2.2 μs，相对 1 s 的
                //   测量周期完全可以忽略。
                // ------------------------------------------------------------
                S_CRC_UPD: begin
                    if (crc_bit == 4'd0) begin
                        // 第一个位周期：先把本字节异或进寄存器
                        crc_calc <= crc_calc ^ crc_byte;
                        crc_bit  <= 4'd1;
                    end else if (crc_bit == 4'd9) begin
                        // 1 次异或 + 8 次移位全部做完，回到读下一字节
                        crc_bit <= 4'd0;
                        state   <= S_RD_BYTE;
                    end else begin
                        crc_calc <= crc_shift;
                        crc_bit  <= crc_bit + 4'd1;
                    end
                end

                // ------------------------------------------------------------
                // CRC 比对 + 定点换算（见【二】⑥⑦、【四】）
                // ------------------------------------------------------------
                S_CHECK: begin
                    if (crc_calc != crc_rx) begin
                        // CRC 失败：数据不可信，绝不输出
                        //   ★ 这一条是安全相关的：宁可这一轮没有温度读数
                        //   （thermal_guard 会因为 temp_valid 不来而保持原状态），
                        //   也不能把被干扰的垃圾数据当成真值送出去 ——
                        //   一次错误的"45 ℃"会让设备误进应急模式，
                        //   一次错误的"25 ℃"会让真实高温被忽略。
                        err_code     <= ERR_CRC;
                        sensor_ok    <= 1'b0;
                        sensor_fault <= 1'b1;
                        state        <= S_FAILED;
                    end else if (rb0[7]) begin
                        // 状态字节 bit7=忙：芯片还在测量，本轮作废
                        err_code     <= ERR_BUSY;
                        sensor_ok    <= 1'b0;
                        sensor_fault <= 1'b1;
                        state        <= S_FAILED;
                    end else begin
                        // 成功：输出温度与湿度
                        temp_centi_c <= t_centi_comb;
                        temp_valid   <= 1'b1;
                        humid_centi  <= h_centi_comb;
                        humid_valid  <= 1'b1;
                        sensor_ok    <= 1'b1;
                        err_code     <= ERR_NONE;
                        sensor_fault <= 1'b0;   // 只有这一处能清故障标志
                        meas_tick    <= 1'b1;    // 一轮成功测量完成
                        retry_cnt    <= 2'd0;
                        state        <= S_PERIOD;
                    end
                end

                // ------------------------------------------------------------
                // 周期等待 1 s
                // ------------------------------------------------------------
                S_PERIOD: begin
                    busy <= 1'b0;
                    if (wait_cnt >= PERIOD_CYCLES[31:0] - 32'd1) begin
                        wait_cnt <= 32'd0;
                        state    <= S_TRG_START;
                    end else begin
                        wait_cnt <= wait_cnt + 32'd1;
                    end
                end

                // ------------------------------------------------------------
                // 本轮失败：计数重试，未达上限就立刻再试一次
                //   立刻重试而不是等满 1 s，是因为 I2C 干扰、CRC 偶发失败
                //   这类错误通常几毫秒后就消失；等 1 s 会让温度更新出现
                //   明显的空窗。达到上限才退回周期等待，避免死循环。
                // ------------------------------------------------------------
                S_FAILED: begin
                    busy <= 1'b0;
                    // 进入本状态即说明本轮至少有一次失败：故障标志置起。
                    //   这条兜住了 S_CHECK 之外的全部失败路径（NACK / 超时 /
                    //   未校准），否则那些路径只会置 err_code 而 sensor_fault
                    //   仍停在 0，上层会以为数据可信。
                    sensor_fault <= 1'b1;
                    if (retry_cnt >= RETRY_MAX[1:0]) begin
                        retry_cnt <= 2'd0;
                        wait_cnt  <= 32'd0;
                        meas_tick <= 1'b1;   // 重试用尽 = 一轮尝试结束，报一次节拍
                        state     <= S_PERIOD;
                    end else begin
                        retry_cnt <= retry_cnt + 2'd1;
                        wait_cnt  <= 32'd0;
                        state     <= S_TRG_START;
                    end
                end

                default: state <= S_POWERUP;
            endcase
        end
    end

endmodule
