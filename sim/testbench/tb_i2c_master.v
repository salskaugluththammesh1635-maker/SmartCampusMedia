// ============================================================================
// 文件名  : tb_i2c_master.v
// 测试对象: rtl/sensor/i2c_master.v
// 运行方式: vsim -c -quiet -onfinish stop -do "run -all; quit -f -code 0" work.tb_i2c_master
// 通过标志: 打印 "ALL CHECKS PASSED: i2c_master"
// ============================================================================
// 【这个测试台验证什么】
//   i2c_master 是把「发 START / 写一字节 / 读一字节 / 发 STOP」翻译成两根线
//   电平序列的物理层。它的正确性不能只看自己吐出的 done 脉冲 —— done 对了
//   不代表线上时序对，从机可能根本认不出来。所以本 tb 自带一个**行为级 I2C
//   从机模型**（i2c_slave_model，见文件末尾），让主机真正对着一个"会应答的
//   器件"跑，再从从机侧反查主机发出的每一个字节。
//
// 【从机模型为什么用 25 MHz 采样而不是用 SCL 边沿当时钟】
//   最初版本用 `always @(posedge scl) / @(negedge scl) / @(posedge sda)` 三个
//   边沿块分头写状态，结果 bit_cnt / sda_low / active 这些寄存器各有 2~3 个
//   驱动点，Verilog 直接把它们求值成 X —— 表现为"从机收到的字节是对的，
//   但主机读回的 ACK 全是 X"，C03/C08 两个用例一个期望 1 一个期望 0 同时失败，
//   这就是多驱动点的典型指纹。改成**单一 25 MHz 时钟块 + 边沿检测**后，
//   所有状态只有一个驱动点，行为完全确定。
//   采样粒度足够：SCL 半周期 = 126 拍（25 MHz），边沿检测误差最多 1 拍。
//
// 【覆盖的场景（每条对应若干 PASS 行）】
//   C01 复位后总线空闲：SCL/SDA 均为释放态（高），busy=0
//   C02 START 条件：SCL 高电平期间 SDA 下降，从机识别到起始
//   C03 写地址字节 0x70：从机收到 0x70 且回 ACK
//   C04 写命令字节 0xAC（AHT20 触发测量）
//   C05 写参数字节 0x33 / 0x00：连续两字节均被接收
//   C06 STOP 条件：SCL 高电平期间 SDA 上升，从机识别到停止，busy 归零
//   C07 读事务：START + 0x71 + 读一字节（rd_nack=1）→ 收回从机预设值 0x18
//   C08 NACK 检测：写从机不认的地址 0x00 → 主机 wr_ack=0
//   C09 请求边沿检测：req 在 done 之后仍保持高电平，不得重复触发第二次传输
//   C10 busy 语义：START 之后为 1、STOP 之后为 0，写事务期间保持不变
//   C11 SCL 周期与参数换算一致（25 MHz / (4×63) ≈ 99.2 kHz，≤100 kHz）
//   C12 一个写字节恰好产生 9 个 SCL 上升沿（8 数据位 + 1 应答位），
//       且总线占用期间不出现多余上升沿（多余 = 从机会误判 STOP）
// ============================================================================
`timescale 1ns/1ps

module tb_i2c_master;

    // ------------------------------------------------------------------------
    // 时钟与复位
    // ------------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #20 clk = ~clk;            // 25 MHz，周期 40 ns

    // ------------------------------------------------------------------------
    // 被测模块端口
    // ------------------------------------------------------------------------
    reg         start_req, stop_req, wr_req, rd_req, rd_nack;
    reg  [7:0]  wr_data;
    wire        start_done, stop_done, wr_done, wr_ack, rd_done;
    wire [7:0]  rd_data;
    wire        scl_oe, sda_oe;
    wire        busy;

    // ------------------------------------------------------------------------
    // I2C 总线（三态 + 上拉）
    //   pullup 是 Verilog 内建原语，等价于真实板上的上拉电阻。
    //   没有它，两条线在无人驱动时是 z，从机模型读不到"空闲高"。
    // ------------------------------------------------------------------------
    tri  i2c_scl;
    tri  i2c_sda;
    pullup (i2c_scl);
    pullup (i2c_sda);

    assign i2c_scl = scl_oe ? 1'bz : 1'b0;
    assign i2c_sda = sda_oe ? 1'bz : 1'b0;

    i2c_master u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start_req  (start_req),
        .start_done (start_done),
        .stop_req   (stop_req),
        .stop_done  (stop_done),
        .wr_req     (wr_req),
        .wr_data    (wr_data),
        .wr_done    (wr_done),
        .wr_ack     (wr_ack),
        .rd_req     (rd_req),
        .rd_nack    (rd_nack),
        .rd_data    (rd_data),
        .rd_done    (rd_done),
        .scl_oe     (scl_oe),
        .sda_oe     (sda_oe),
        .sda_in     (i2c_sda),
        .busy       (busy)
    );

    // ------------------------------------------------------------------------
    // 从机模型
    // ------------------------------------------------------------------------
    wire [7:0]  slv_last_wr;
    wire        slv_got_start, slv_got_stop;
    wire [2:0]  slv_wr_cnt;
    wire [15:0] slv_start_cnt;
    reg  [7:0]  slv_rd_byte;

    i2c_slave_model #(.ADDR(7'h38)) u_slave (
        .clk       (clk),
        .scl       (i2c_scl),
        .sda       (i2c_sda),
        .last_wr   (slv_last_wr),
        .got_start (slv_got_start),
        .got_stop  (slv_got_stop),
        .wr_cnt    (slv_wr_cnt),
        .start_cnt (slv_start_cnt),
        .rd_byte   (slv_rd_byte)
    );

    // ------------------------------------------------------------------------
    // 记分板
    // ------------------------------------------------------------------------
    integer pass_cnt;
    integer fail_cnt;

    task chk;
        input         cond;
        input [639:0] msg;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s  (t=%0t)", msg, $time);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // 单步操作封装：发起请求 → 等 done → 释放请求
    //   每个 @(posedge clk) 之后加 #1 再采样：25 MHz 半周期 20 ns，#1 落在
    //   高电平期内部，既保证 DUT 的非阻塞赋值已全部生效（避开同一时间步的
    //   竞争），又不会跨过时钟沿。
    // ------------------------------------------------------------------------
    task do_start;
        begin
            @(negedge clk); start_req = 1'b1;
            @(posedge clk); #1;
            while (!start_done) begin @(posedge clk); #1; end
            @(negedge clk); start_req = 1'b0;
            @(negedge clk);
        end
    endtask

    task do_stop;
        begin
            @(negedge clk); stop_req = 1'b1;
            @(posedge clk); #1;
            while (!stop_done) begin @(posedge clk); #1; end
            @(negedge clk); stop_req = 1'b0;
            @(negedge clk);
        end
    endtask

    task do_wr;
        input  [7:0] dat;
        output       ack;
        begin
            @(negedge clk); wr_data = dat; wr_req = 1'b1;
            @(posedge clk); #1;
            while (!wr_done) begin @(posedge clk); #1; end
            ack = wr_ack;
            @(negedge clk); wr_req = 1'b0;
            @(negedge clk);
        end
    endtask

    task do_rd;
        input         nack;
        output [7:0]  dat;
        begin
            @(negedge clk); rd_nack = nack; rd_req = 1'b1;
            @(posedge clk); #1;
            while (!rd_done) begin @(posedge clk); #1; end
            dat = rd_data;
            @(negedge clk); rd_req = 1'b0;
            @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------------
    // SCL 上升沿计数与周期测量
    //   meas_en 只在一次"写字节"期间为 1，这样：
    //     · 计数窗口内恰好 9 个上升沿（8 数据位 + 1 应答位）
    //     · 记录到的两个相邻上升沿一定属于同一字节内相邻两位的相位 1，
    //       间隔严格等于一个 SCL 周期（4×QUARTER 拍）
    //   若不加窗口，最后两个上升沿可能跨 START/STOP，间隔不是 4×QUARTER。
    // ------------------------------------------------------------------------
    reg   meas_en;
    integer scl_rise_cnt;
    integer scl_rise_win;
    time  t_scl_rise1, t_scl_rise2;

    initial begin
        meas_en      = 1'b0;
        scl_rise_cnt = 0;
        scl_rise_win = 0;
        t_scl_rise1  = 0;
        t_scl_rise2  = 0;
    end

    always @(posedge i2c_scl) begin
        scl_rise_cnt = scl_rise_cnt + 1;
        if (meas_en) begin
            scl_rise_win = scl_rise_win + 1;
            t_scl_rise2  = t_scl_rise1;
            t_scl_rise1  = $time;
        end
    end

    // ------------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------------
    reg        ack_r;
    reg [7:0]  dat_r;
    integer    scl_period_ns;
    reg        busy_snap;
    reg [15:0] cnt_before;

    initial begin
        pass_cnt    = 0;
        fail_cnt    = 0;
        rst_n       = 1'b0;
        start_req   = 1'b0;
        stop_req    = 1'b0;
        wr_req      = 1'b0;
        rd_req      = 1'b0;
        rd_nack     = 1'b0;
        wr_data     = 8'h00;
        slv_rd_byte = 8'h18;      // AHT20 状态字节：bit4=已校准, bit3=就绪

        // ---- 复位保持 10 拍 ----
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5)  @(posedge clk);

        // ====================================================================
        // C01 复位后总线空闲
        // ====================================================================
        chk((i2c_scl === 1'b1) && (i2c_sda === 1'b1),
            "C01 idle bus: SCL and SDA both released high");
        chk(busy === 1'b0, "C01 idle bus: busy=0");

        // ====================================================================
        // C02 START 条件
        // ====================================================================
        do_start();
        chk(slv_got_start === 1'b1, "C02 START condition seen by slave");
        chk(busy === 1'b1,          "C02 busy raised after START");

        // ====================================================================
        // C03 写地址字节 0x70（AHT20 7 位地址 0x38 的写地址）
        // ====================================================================
        do_wr(8'h70, ack_r);
        chk(ack_r === 1'b1,        "C03 write 0x70: slave ACK");
        chk(slv_last_wr === 8'h70, "C03 write 0x70: slave received 0x70");

        // ====================================================================
        // C04 写命令字节 0xAC（AHT20 触发测量）
        // ====================================================================
        do_wr(8'hAC, ack_r);
        chk(ack_r === 1'b1,        "C04 write 0xAC: slave ACK");
        chk(slv_last_wr === 8'hAC, "C04 write 0xAC: slave received 0xAC");

        // ====================================================================
        // C05 写参数字节 0x33 / 0x00
        // ====================================================================
        do_wr(8'h33, ack_r);
        chk((ack_r === 1'b1) && (slv_last_wr === 8'h33),
            "C05 write 0x33: ACK and slave received 0x33");
        do_wr(8'h00, ack_r);
        chk((ack_r === 1'b1) && (slv_last_wr === 8'h00),
            "C05 write 0x00: ACK and slave received 0x00");

        // ====================================================================
        // C06 STOP 条件
        // ====================================================================
        do_stop();
        chk(slv_got_stop === 1'b1, "C06 STOP condition seen by slave");
        chk(busy === 1'b0,         "C06 busy cleared after STOP");
        chk((i2c_scl === 1'b1) && (i2c_sda === 1'b1),
            "C06 bus back to idle high after STOP");

        // ====================================================================
        // C07 读事务：START + 0x71 + 读一字节（NACK 收尾）
        // ====================================================================
        do_start();
        do_wr(8'h71, ack_r);
        chk(ack_r === 1'b1, "C07 write 0x71 (read address): slave ACK");
        do_rd(1'b1, dat_r);
        chk(dat_r === 8'h18, "C07 read one byte with NACK: got 0x18");
        do_stop();
        chk(busy === 1'b0, "C07 busy cleared after read transaction");

        // ====================================================================
        // C08 NACK 检测：写从机不认的地址 0x00
        //   从机模型只在收到 (ADDR<<1)|0 = 0x70 时应答，其余一律放手。
        //   主机必须在第 9 拍读到 SDA 为高 → wr_ack=0。
        // ====================================================================
        do_start();
        do_wr(8'h00, ack_r);
        chk(ack_r === 1'b0, "C08 write 0x00 (bad address): slave NACK detected");
        do_stop();

        // ====================================================================
        // C09 请求边沿检测：req 保持高电平，不得重复触发
        //   发起一次 START 后**不释放** start_req，等 400 拍（远超一个 START
        //   相位的 4×63=252 拍），检查从机收到的 START 次数只增加了 1。
        // ====================================================================
        cnt_before = slv_start_cnt;
        @(negedge clk); start_req = 1'b1;
        @(posedge clk); #1;
        while (!start_done) begin @(posedge clk); #1; end
        repeat (400) @(posedge clk);
        chk((slv_start_cnt - cnt_before) == 16'd1,
            "C09 held start_req: only ONE START issued (edge detect works)");
        @(negedge clk); start_req = 1'b0;
        @(negedge clk);
        do_stop();          // 收尾：把总线放回空闲

        // ====================================================================
        // C10 busy 语义 + C11 SCL 周期 + C12 上升沿个数（同一次写事务里一起测）
        // ====================================================================
        do_start();
        busy_snap    = busy;
        scl_rise_win = 0;
        t_scl_rise1  = 0;
        t_scl_rise2  = 0;
        meas_en      = 1'b1;
        do_wr(8'h70, ack_r);
        meas_en      = 1'b0;
        chk((busy_snap === 1'b1) && (busy === 1'b1),
            "C10 busy stays high across a write byte");

        // SCL 周期：QUARTER=63 拍/相位 → 一周期 4×63=252 拍 = 10080 ns
        scl_period_ns = t_scl_rise1 - t_scl_rise2;
        chk((scl_period_ns > 10040) && (scl_period_ns < 10120),
            "C11 SCL period is 252 clocks (99.2 kHz, within 100 kHz limit)");

        // 上升沿个数：一个写字节 = 8 数据位 + 1 应答位 = 9 个 SCL 上升沿。
        //   这条断言的价值：若 S_IDLE 在 busy=1 时错误地把 SCL 释放成高，
        //   就会凭空多出上升沿，从机会把它当成 STOP，事务当场作废 ——
        //   而 done 脉冲仍然照常输出，只看 done 根本发现不了。
        chk(scl_rise_win == 9,
            "C12 one byte produces exactly 9 SCL rising edges");

        // 顺带覆盖 AHT20 软复位命令 0xBE
        do_wr(8'hBE, ack_r);
        chk((ack_r === 1'b1) && (slv_last_wr === 8'hBE),
            "C10 write 0xBE (soft reset): ACK and slave received 0xBE");
        do_stop();
        chk(busy === 1'b0, "C10 busy cleared after final STOP");

        // ====================================================================
        // 汇总
        // ====================================================================
        repeat (20) @(posedge clk);
        $display("");
        $display("=================================================");
        $display(" tb_i2c_master: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        $display("=================================================");
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: i2c_master");
        end else begin
            $display("CHECKS FAILED: i2c_master (%0d failures)", fail_cnt);
        end
        $finish;
    end

    // ------------------------------------------------------------------------
    // 全局超时：正常流程约 60 us，给 3 ms 余量
    // ------------------------------------------------------------------------
    initial begin
        #3_000_000;
        $display("TIMEOUT: i2c_master simulation exceeded 3 ms");
        $display("CHECKS FAILED: i2c_master (timeout)");
        $finish;
    end

endmodule


// ============================================================================
// 行为级 I2C 从机模型（只服务本测试台）
// ============================================================================
// 【能力边界】
//   这不是一个完整的 I2C 从机：不支持时钟延展、不支持 10 位地址、不支持
//   多字节连续读。它只需做到一件事 —— **像一个 AHT20 那样应答**，让主机
//   有一个真正的对手，从而暴露"主机发错字节 / ACK 采样错拍 / 误发 STOP"
//   这类只看 done 脉冲发现不了的缺陷。
//
// 【地址规则】
//   7 位地址 ADDR 默认 0x38（AHT20）。写地址字节 = ADDR<<1 = 0x70，
//   读地址字节 = (ADDR<<1)|1 = 0x71。其余任何首字节一律 NACK。
//
// 【ACK 的驱动与撤销时机（本模型最关键的时序）】
//   I2C 规定从机只能在 SCL **低电平期**改变 SDA。ACK 必须在第 8 个 SCL
//   下降沿之后驱动、在第 9 个 SCL 高电平期被主机采到、到第 9 个下降沿才撤销。
//   若在第 9 个上升沿就撤销 ACK，SDA 会在 SCL 高电平期由低变高 ——
//   主机的 STOP 检测看到的正是"SCL 高时 SDA 上升"，会把一次正常的 ACK
//   误判成 STOP，整个事务作废。
//
// 【为什么整个模型只有一个时钟块】
//   边沿触发写法（@(posedge scl) / @(negedge scl) / @(posedge sda) 分开写）
//   会让 bit_cnt、sda_low、active 这些寄存器各自有 2~3 个驱动点，
//   Verilog 直接把它们求值成 X。本模型统一在 25 MHz 下采样、自己检测边沿，
//   所有状态只有一个驱动点，行为完全确定。
// ============================================================================
module i2c_slave_model #(
    parameter [6:0] ADDR = 7'h38
) (
    input  wire        clk,
    input  wire        scl,
    inout  wire        sda,
    output reg  [7:0]  last_wr,     // 最近收到的完整字节（供 tb 反查）
    output reg         got_start,   // 曾经收到 START（电平，不复位）
    output reg         got_stop,    // 曾经收到 STOP（电平，不复位）
    output reg  [2:0]  wr_cnt,      // 本次事务已收到的写字节数
    output reg  [15:0] start_cnt,   // START 次数（C09 用）
    input  wire [7:0]  rd_byte      // 主机读时本模型返回的字节
);

    reg sda_low;                    // 1 = 本模型拉低 SDA
    assign sda = sda_low ? 1'b0 : 1'bz;

    // ---- 上一拍的线状态，用于边沿检测 ----
    reg scl_d, sda_d;
    wire scl_rise = (scl === 1'b1) && (scl_d === 1'b0);
    wire scl_fall = (scl === 1'b0) && (scl_d === 1'b1);
    wire sda_rise = (sda === 1'b1) && (sda_d === 1'b0);
    wire sda_fall = (sda === 1'b0) && (sda_d === 1'b1);

    // ---- 协议状态 ----
    reg       active;               // 收到 START 之后为 1
    reg       rd_mode;              // 本次事务是读（首字节是读地址）
    reg       first_byte;           // 本次事务尚未收到首字节
    reg       ack_done;             // 第 8 个下降沿已驱动过 ACK，等第 9 个撤销
    reg [3:0] bit_cnt;              // 0..7 数据位，8 = 应答相位
    reg [7:0] shreg;                // 接收移位寄存器
    reg [7:0] tx_byte;              // 读模式下要输出的字节

    always @(posedge clk) begin
        // ---- 打拍记录线状态（供下一拍做边沿检测）----
        scl_d <= scl;
        sda_d <= sda;

        // ====================================================================
        // START：SCL 高电平期间 SDA 下降
        //   （重复起始也走这里：把本次事务的接收状态清空）
        // ====================================================================
        if (sda_fall && (scl === 1'b1)) begin
            active     <= 1'b1;
            bit_cnt    <= 4'd0;
            first_byte <= 1'b1;
            rd_mode    <= 1'b0;
            ack_done   <= 1'b0;
            sda_low    <= 1'b0;
            got_start  <= 1'b1;
            start_cnt  <= start_cnt + 16'd1;
            wr_cnt     <= 3'd0;
        end

        // ====================================================================
        // STOP：SCL 高电平期间 SDA 上升
        // ====================================================================
        if (sda_rise && (scl === 1'b1)) begin
            active   <= 1'b0;
            ack_done <= 1'b0;
            sda_low  <= 1'b0;
            got_stop <= 1'b1;
        end

        // ====================================================================
        // SCL 上升沿：采样一位
        //   第 9 个上升沿（bit_cnt==8）时主机正在采 ACK，本模型不动 SDA。
        //   读方向（rd_mode=1）本模型是发送方，**不采样**，否则 bit_cnt 会被
        //   写方向的计数逻辑污染，读数据的位序整体错位。
        // ====================================================================
        if (scl_rise && active && !rd_mode && (bit_cnt < 4'd8)) begin
            shreg   <= {shreg[6:0], sda};
            bit_cnt <= bit_cnt + 4'd1;
        end

        // ====================================================================
        // SCL 下降沿：驱动 ACK / 输出读数据位 / 撤销 ACK 并结算字节
        //   注意：所有对 SDA 的驱动都发生在这里 —— SCL 低电平期，
        //   符合 I2C "从机只能在 SCL 低时改变 SDA" 的规定。
        // ====================================================================
        if (scl_fall && active) begin
            if (rd_mode) begin
                // ---- 读方向：按位输出 ----
                //   第 1 位（bit7）已在应答撤销那一拍送上线，这里只负责
                //   后续 7 位。发满 8 位后放手，把总线让给主机发 ACK/NACK。
                if (bit_cnt < 4'd7) begin
                    sda_low <= ~tx_byte[7];
                    tx_byte <= {tx_byte[6:0], 1'b0};
                    bit_cnt <= bit_cnt + 4'd1;
                end else begin
                    sda_low <= 1'b0;
                end
            end else if (bit_cnt < 4'd8) begin
                // ---- 写方向的数据位窗口：放手，让主机送数据 ----
                sda_low <= 1'b0;
            end else begin
                // ---- 写方向的应答相位 ----
                if (!ack_done) begin
                    // 第 8 个下降沿：决定并驱动应答
                    //   首字节是地址 → 只有 (ADDR<<1)|0 才应答，其余 NACK
                    //   数据字节     → 一律应答
                    if (first_byte)
                        sda_low <= (shreg[7:1] == ADDR) ? 1'b1 : 1'b0;
                    else
                        sda_low <= 1'b1;
                    ack_done <= 1'b1;
                end else begin
                    // 第 9 个下降沿：撤销应答，结算本字节
                    ack_done <= 1'b0;
                    bit_cnt  <= 4'd0;
                    last_wr  <= shreg;
                    if (first_byte) begin
                        first_byte <= 1'b0;
                        rd_mode    <= shreg[0];
                        if (shreg[0]) begin
                            // 读事务：把返回字节的最高位**立刻**送上总线。
                            //   为什么必须在这一拍就送：下一拍 SCL 就会抬高，
                            //   主机在第一个 SCL 高电平期就要采到 bit7。
                            //   若等到下一个下降沿才驱动，第一位会被采成
                            //   上拉高电平，整个字节右移一位。
                            sda_low <= ~rd_byte[7];
                            tx_byte <= {rd_byte[6:0], 1'b0};
                        end else begin
                            sda_low <= 1'b0;
                        end
                    end else begin
                        wr_cnt  <= wr_cnt + 3'd1;
                        sda_low <= 1'b0;
                    end
                end
            end
        end
    end

    initial begin
        sda_low    = 1'b0;
        scl_d      = 1'b1;
        sda_d      = 1'b1;
        active     = 1'b0;
        rd_mode    = 1'b0;
        first_byte = 1'b1;
        ack_done   = 1'b0;
        bit_cnt    = 4'd0;
        shreg      = 8'd0;
        tx_byte    = 8'd0;
        last_wr    = 8'd0;
        got_start  = 1'b0;
        got_stop   = 1'b0;
        wr_cnt     = 3'd0;
        start_cnt  = 16'd0;
    end

endmodule
