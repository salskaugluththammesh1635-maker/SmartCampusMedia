// ============================================================================
// 【一、在整体系统中的功能】
//   阶段四 SD 物理层的独立协议回归；只连接真实 SPI 引脚与字节服务接口。
// 【二、本模块功能】
//   使用标准 SPI R1(8 位)/R3、R7(40 位)应答，检查默认参数、完整块读、
//   非 SDHC 拒绝、初始化轮询、错误令牌、CRC 与卡不断电时的主机复位。
// 【三、接口与内部结构】
//   无外部端口；主机激励、单进程卡模型、字节监视器彼此独立。
//   卡模型不读取 DUT 内部状态，也不会随 rst_n 重置卡的 idle/app 状态。
// 【四、设计思路与范式】
//   行为级 SPI 从设备：上升沿收 MOSI，下降沿后延时 2ns 送 MISO；
//   CRC 由整字节算法计算，不复用 RTL 的逐位反馈实现。
// ============================================================================
`timescale 1ns/1ps
module tb_sd_spi_protocol;
    parameter INIT_DIV = 32;           // 使用真实初始化分频；也可覆盖为 2 加速交叉回归
    parameter LOOP_LIMIT = 65536;      // 默认值必须覆盖，避免 16 位切片掩盖缺陷
    parameter TOKEN_LIMIT = 1048576;   // 默认值必须覆盖，避免 20 位切片掩盖缺陷
    parameter POWERUP_DELAY = 131071;  // 默认上电等待；快速回归可覆盖为 100
    reg clk = 1'b0;                    // 25MHz 主时钟
    reg rst_n = 1'b0;                  // 仅复位主机，不替卡断电
    reg init_start = 1'b0;             // 初始化请求脉冲
    reg blk_start = 1'b0;              // 块读取请求脉冲
    reg [31:0] blk_addr = 32'd0;        // 请求的逻辑扇区号
    wire init_done, init_fail;         // 初始化终态
    wire [3:0] err_code;               // 控制器错误码
    wire blk_busy, blk_done, blk_err;  // 块读取握手
    wire [7:0] data_byte;              // 返回字节
    wire data_valid;                   // 字节有效脉冲
    wire sd_cs_n, sd_sck, sd_mosi;      // 主机引脚
    reg sd_miso = 1'b1;                // 卡输出；空闲为上拉高
    integer errors = 0;                // 回归失败总数
    integer received = 0;              // 本块已收到字节数
    integer byte_errors = 0;           // 本块数据不符次数
    integer cmd0_seen = 0;             // 实际收到的 CMD0 次数
    integer cmd41_seen = 0;            // 实际收到的 ACMD41 次数
    integer cmd58_seen = 0;            // 实际收到的 CMD58 次数
    integer cmd17_seen = 0;            // 实际收到的 CMD17 次数
    integer command_errors = 0;        // 命令帧/参数错误次数
    integer busy_polls = 2;            // ACMD41 首若干次返回 idle=1
    integer polls = 0;                 // 当前卡初始化轮询次数
    integer ncr_bytes = 1;             // 命令响应前导 FF 字节数
    integer token_fill = 1;            // R1 与 token 之间的 FF 字节数
    reg card_present = 1'b1;           // 模拟插卡/无卡
    reg card_idle = 1'b1;              // 卡自己的 idle 状态，不随主机复位清零
    reg app_pending = 1'b0;            // CMD55 已接收，下一条应为 ACMD41
    reg high_capacity = 1'b1;          // OCR.CCS 模拟值
    reg bad_r7 = 1'b0;                 // 错误的电压/echo 返回
    reg bad_crc = 1'b0;                // 块 CRC 错误注入
    reg error_token = 1'b0;            // 数据错误令牌注入
    reg bad_signature = 1'b0;          // 扇区签名错误注入（保留联合探针场景）
    reg low_during_command = 1'b0;     // 发送命令时 DO 拉低，检验主机不提前收应答
    reg no_token = 1'b0;               // R1 后持续 FF，检验真实默认令牌超时
    reg [31:0] last_lba = 32'd0;       // 卡收到的真实扇区号
    reg [47:0] command_frame;          // 实际引脚收到的 48 位命令帧
    reg [15:0] send_crc;               // 卡发送的块 CRC
    reg [7:0] send_data;               // 当前要发送的数据字节
    integer bit_no;                    // 命令位循环下标
    integer byte_no;                   // 数据字节循环下标
    integer fill_no;                   // 前导填充循环下标
    integer scenario;                  // 主机复位交叉场景编号

    // 功能：产生独立主时钟。输入：时间；输出：clk。
    always #20 clk = ~clk;

    sd_spi_ctrl #(
        .SCK_INIT_DIV(INIT_DIV),
        .ACMD41_LOOPS(LOOP_LIMIT),
        .TOKEN_TIMEOUT(TOKEN_LIMIT),
        .POWERUP_CYCLES(POWERUP_DELAY)
    ) dut (
        .clk(clk), .rst_n(rst_n), .init_start(init_start),
        .init_done(init_done), .init_fail(init_fail), .err_code(err_code),
        .blk_start(blk_start), .blk_addr(blk_addr), .blk_busy(blk_busy),
        .blk_done(blk_done), .blk_err(blk_err),
        .data_byte(data_byte), .data_valid(data_valid),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    // 行为级期望数据：非零首字节，末两字节固定为扇区签名。
    function [7:0] expected_byte;
        input integer index;
        begin
            if (index == 510) expected_byte = 8'h55;
            else if (index == 511) expected_byte = bad_signature ? 8'h00 : 8'hAA;
            else expected_byte = index[7:0] ^ 8'hA6;
        end
    endfunction

    // 整字节 CRC16/XMODEM 算法；与 RTL 的按位输入反馈结构独立。
    function [15:0] crc_byte;
        input [15:0] previous;
        input [7:0] value;
        reg [15:0] c;
        integer j;
        begin
            c = previous ^ {value, 8'd0};
            for (j = 0; j < 8; j = j + 1)
                c = c[15] ? (c << 1) ^ 16'h1021 : (c << 1);
            crc_byte = c;
        end
    endfunction

    task check;
        input condition;
        input [8*100-1:0] name;
        begin
            if (condition) $display("PASS: %0s", name);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s at %0t", name, $time);
            end
        end
    endtask

    // 只在真实下降沿之后改变卡输出；片选撤销即终止当前字节。
    task send_byte;
        input [7:0] value;
        integer j;
        begin : send_one
            for (j = 7; j >= 0; j = j - 1) begin
                @(negedge sd_sck or posedge sd_cs_n);
                if (sd_cs_n) disable send_one;
                #2 sd_miso = value[j];
                @(posedge sd_sck or posedge sd_cs_n);
                if (sd_cs_n) disable send_one;
            end
        end
    endtask

    // 卡模型只按引脚收帧；不引用任何 dut.* 节点，不接主机复位。
    initial begin : card_model
        forever begin
            wait (!sd_cs_n);
            begin : selected
                command_frame = 48'd0;
                if (low_during_command) #2 sd_miso = 1'b0;
                // SPI 允许前导 1；扫描命令起始 0，再接收其余 47 位。
                begin : find_start
                    forever begin
                        @(posedge sd_sck or posedge sd_cs_n);
                        if (sd_cs_n) disable selected;
                        if (!sd_mosi) disable find_start;
                    end
                end
                for (bit_no = 46; bit_no >= 0; bit_no = bit_no - 1) begin
                    @(posedge sd_sck or posedge sd_cs_n);
                    if (sd_cs_n) disable selected;
                    command_frame[bit_no] = sd_mosi;
                end
                if (!card_present) begin
                    wait (sd_cs_n);
                    disable selected;
                end
                if (command_frame[47:46] !== 2'b01 || !command_frame[0]) begin
                    command_errors = command_errors + 1;
                    $display("CARD: malformed command %012x", command_frame);
                    wait (sd_cs_n);
                    disable selected;
                end
                for (fill_no = 0; fill_no < ncr_bytes; fill_no = fill_no + 1)
                    send_byte(8'hFF);
                if (sd_cs_n) disable selected;
                case (command_frame[45:40])
                    0: begin
                        cmd0_seen = cmd0_seen + 1;
                        if (command_frame !== 48'h400000000095)
                            command_errors = command_errors + 1;
                        card_idle = 1'b1;
                        app_pending = 1'b0;
                        polls = 0;
                        send_byte(8'h01);
                    end
                    8: begin
                        if (command_frame !== 48'h48000001AA87)
                            command_errors = command_errors + 1;
                        send_byte(8'h01);
                        send_byte(8'h00);
                        send_byte(8'h00);
                        send_byte(bad_r7 ? 8'h02 : 8'h01);
                        send_byte(8'hAA); // R7 正好 40 位，无 CRC 尾字节
                    end
                    55: begin
                        app_pending = 1'b1;
                        send_byte(card_idle ? 8'h01 : 8'h00);
                    end
                    41: begin
                        cmd41_seen = cmd41_seen + 1;
                        if (!app_pending || command_frame[39:8] !== 32'h40000000)
                            command_errors = command_errors + 1;
                        app_pending = 1'b0;
                        polls = polls + 1;
                        if (polls > busy_polls) card_idle = 1'b0;
                        send_byte(card_idle ? 8'h01 : 8'h00); // 仅 R1，不附 OCR
                    end
                    58: begin
                        cmd58_seen = cmd58_seen + 1;
                        send_byte(card_idle ? 8'h01 : 8'h00);
                        send_byte(high_capacity ? 8'hC0 : 8'h80);
                        send_byte(8'hFF);
                        send_byte(8'h80);
                        send_byte(8'h00); // R3 正好 40 位，OCR[31:0]
                    end
                    17: begin
                        cmd17_seen = cmd17_seen + 1;
                        last_lba = command_frame[39:8];
                        send_byte(card_idle ? 8'h01 : 8'h00);
                        if (!card_idle) begin
                            if (no_token) begin
                                while (!sd_cs_n) send_byte(8'hFF);
                                disable selected;
                            end
                            for (fill_no = 0; fill_no < token_fill; fill_no = fill_no + 1)
                                send_byte(8'hFF);
                            send_byte(error_token ? 8'h05 : 8'hFE);
                            if (!error_token) begin
                                send_crc = 16'd0;
                                for (byte_no = 0; byte_no < 512; byte_no = byte_no + 1) begin
                                    if (sd_cs_n) disable selected;
                                    send_data = expected_byte(byte_no);
                                    send_crc = crc_byte(send_crc, send_data);
                                    send_byte(send_data);
                                end
                                if (bad_crc) send_crc = send_crc ^ 16'h0001;
                                send_byte(send_crc[15:8]);
                                send_byte(send_crc[7:0]);
                            end
                        end
                    end
                    default: begin
                        command_errors = command_errors + 1;
                        send_byte(8'h04);
                    end
                endcase
                // 卡应答后的 DO 释放也只发生在下降沿，不让最后一位提前回高。
                @(negedge sd_sck or posedge sd_cs_n);
                sd_miso = 1'b1;
                wait (sd_cs_n);
            end
            sd_miso = 1'b1;
        end
    end

    // 功能：检查字节流，输入 data_valid/data_byte，输出计数及不符次数。
    always @(posedge clk) begin
        if (rst_n && data_valid) begin
            if (data_byte !== expected_byte(received)) byte_errors = byte_errors + 1;
            received = received + 1;
        end
    end

    task start_initialization;
        integer elapsed;
        begin
            @(negedge clk) rst_n = 1'b0;
            init_start = 1'b0;
            blk_start = 1'b0;
            #200;
            @(negedge clk) rst_n = 1'b1;
            repeat (POWERUP_DELAY + 10) @(negedge clk);
            init_start = 1'b1;
            @(negedge clk) init_start = 1'b0;
            elapsed = 0;
            while (!init_done && !init_fail && elapsed < 1000000) begin
                @(negedge clk);
                elapsed = elapsed + 1;
            end
            check(init_done || init_fail, "initialization reaches terminal state");
        end
    endtask

    task read_block;
        input [31:0] lba;
        integer elapsed;
        begin
            received = 0;
            byte_errors = 0;
            @(negedge clk) begin
                blk_addr = lba;
                blk_start = 1'b1;
            end
            @(negedge clk) begin
                blk_start = 1'b0;
                blk_addr = ~lba; // 必须使用锁存地址，不能跟随输入继续改变
            end
            elapsed = 0;
            while (!blk_done && !blk_err && elapsed < 3000000) begin
                @(negedge clk);
                elapsed = elapsed + 1;
            end
            check(blk_done || blk_err, "block read reaches terminal state");
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin : test_sequence
        $display("SD SPI strict protocol: INIT_DIV=%0d LOOP_LIMIT=%0d TOKEN_LIMIT=%0d",
                 INIT_DIV, LOOP_LIMIT, TOKEN_LIMIT);
        $display("T1: standard SPI R7/R1/CMD58 and default timeout parameters");
        start_initialization;
        check(init_done && !init_fail, "standard SDHC initialization succeeds");
        check(cmd41_seen >= 3, "ACMD41 polls idle cards rather than treating R1 as OCR");
        check(cmd58_seen != 0, "CMD58 reads OCR after ACMD41 ready");
        if (init_done) begin
            read_block(32'h12345678);
            check(received == 512 && byte_errors == 0, "default token timeout permits 512 correct bytes");
            check(last_lba == 32'h12345678, "CMD17 uses latched sector address");
            check(err_code == 0, "good block CRC accepted");
        end
        $display("T2: no FF padding between R1 and data token");
        token_fill = 0;
        if (init_done) begin
            read_block(32'd1);
            check(received == 512 && byte_errors == 0 && err_code == 0,
                  "immediate FE token preserves byte alignment");
        end
        $display("T3: error token after FF must not become a sliding-window false FE");
        token_fill = 2;
        error_token = 1'b1;
        if (init_done) begin
            read_block(32'd2);
            check(err_code == 5 && received == 0, "error token 05 rejected before data bytes");
        end
        error_token = 1'b0;
        bad_crc = 1'b1;
        $display("T4: CRC mismatch");
        if (init_done) begin
            read_block(32'd3);
            check(err_code == 6 && received == 512, "bad CRC reports error 6 after 512 bytes");
        end
        bad_crc = 1'b0;
        $display("T5: unsupported OCR.CCS=0");
        high_capacity = 1'b0;
        start_initialization;
        check(init_fail && err_code == 4, "SDSC rejected using CMD58 OCR.CCS");
        high_capacity = 1'b1;
        bad_r7 = 1'b1;
        $display("T6: R7 voltage mismatch");
        start_initialization;
        check(init_fail && err_code == 2, "R7 voltage field validated, not just AA echo");
        bad_r7 = 1'b0;
        $display("T7: repeated host resets do not power-cycle the card");
        for (scenario = 0; scenario < 6; scenario = scenario + 1) begin
            ncr_bytes = 1 + (scenario % 8);
            busy_polls = scenario % 3;
            start_initialization;
            check(init_done && !init_fail && !card_idle, "warm host reset reinitializes live card");
        end
        $display("T8: slow divider must finish command stop before capturing DO low");
        low_during_command = 1'b1;
        ncr_bytes = 1;
        busy_polls = 1;
        start_initialization;
        check(init_done && !init_fail, "DO low during command is not mistaken for response");
        low_during_command = 1'b0;
        $display("T9: reset in a live 512-byte transfer, card remains powered");
        if (init_done) begin
            received = 0;
            byte_errors = 0;
            @(negedge clk) blk_start = 1'b1;
            @(negedge clk) blk_start = 1'b0;
            wait (received >= 16 || blk_err);
            check(received >= 16, "mid-transfer reset scenario actually reaches payload");
            start_initialization;
            check(init_done && !init_fail, "host recovers after payload-phase reset");
            if (init_done) begin
                read_block(32'd4);
                check(received == 512 && byte_errors == 0 && err_code == 0,
                      "fresh block after reset has correct alignment and CRC");
            end
        end
        $display("T10: default token wait is bounded, not truncated to zero");
        no_token = 1'b1;
        if (init_done) begin
            read_block(32'd5);
            check(err_code == 5 && received == 0, "continuous FF ends at token timeout");
        end
        no_token = 1'b0;
        $display("T11: missing card exits CMD0 retry loop");
        card_present = 1'b0;
        start_initialization;
        check(init_fail && err_code == 1, "no card reports CMD0 retry exhaustion");
        card_present = 1'b1;
        check(command_errors == 0, "all commands have valid frames and required arguments");
        if (LOOP_LIMIT <= 8) begin
            $display("T8: ACMD41 stays idle until loop limit");
            busy_polls = LOOP_LIMIT + 2;
            start_initialization;
            check(init_fail && err_code == 3, "ACMD41 bounded idle polling reports error 3");
        end
        #1000;
        if (errors == 0) begin
            $display("ALL CHECKS PASSED: strict SD SPI protocol");
            $finish;
        end else begin
            $display("CHECKS FAILED: strict SD SPI protocol errors=%0d", errors);
            $stop;
        end
    end

    // 功能：限制整组回归时长，避免错误状态下仿真无限等待。
    initial begin
        #500000000;
        $display("TIMEOUT: strict SD SPI protocol watchdog");
        $stop;
    end
endmodule
