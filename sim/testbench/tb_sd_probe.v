// ============================================================================
// tb_sd_probe —— sd_probe + sd_spi_ctrl 联合仿真（S2 切片验证）
// ============================================================================
// 验证内容:
//   T1 无卡:      init_fail → sd_fail=1, err_latch=1（重试用尽）
//   T2 好卡:      初始化 → 读扇区0 → 第510/511字节=0x55/0xAA → sd_ok=1
//   T3 签名坏:    511 字节改成 0x00 → sd_fail=1, err_latch=8
//   T4 读块错误:  扇区0 令牌错 → sd_fail=1, err_latch=5
// 复用: 卡模型命令收集器 / 应答回放 / 数据回放与 tb_sd_spi_ctrl 同构，
//       但场景变量改为 probe_phase（驱动扇区 0 内容与错误注入）。
// 加速: SCK_INIT_DIV=2 / NCR_TIMEOUT=32 / TOKEN_TIMEOUT=65536 /
//       POWERUP_CYCLES=100 / PROBE_DELAY_CYCLES=300（默认 8ms 太长）。
// ============================================================================
`timescale 1ns/1ps

module tb_sd_probe;

    // ---- 时钟与复位（25MHz 周期 40ns）----
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg rst_n = 1'b0;

    // ---- DUT 连线 ----
    wire        init_start;
    wire        init_done, init_fail;
    wire [3:0]  err_code;
    wire        blk_start;
    wire [31:0] blk_addr;
    wire        blk_busy, blk_done, blk_err;
    wire [7:0]  data_byte;
    wire        data_valid;
    wire        sd_cs_n, sd_sck, sd_mosi;
    reg         sd_miso = 1'b1;     // 卡侧 MISO：无卡时被上拉呈高
    wire        sd_ok, sd_fail;
    wire [3:0]  err_latch;

    // ---- 场景控制 ----
    localparam PP_POWERUP = 3'd0,   // 上电静默：卡不应答
               PP_READY   = 3'd1,   // 好卡：全流程正常
               PP_BADSIG  = 3'd2,   // 签名坏：511 字节=0x00
               PP_ERRTOK  = 3'd3;   // 数据令牌错：发 0x05
    reg [2:0] probe_phase = PP_POWERUP;

    // ---- DUT: sd_spi_ctrl（参数加速）----
    sd_spi_ctrl #(
        .SCK_INIT_DIV   (2),
        .NCR_TIMEOUT    (32),
        .TOKEN_TIMEOUT  (65536),
        .POWERUP_CYCLES (100)
    ) dut_sd (
        .clk        (clk),
        .rst_n      (rst_n),
        .init_start (init_start),
        .init_done  (init_done),
        .init_fail  (init_fail),
        .err_code   (err_code),
        .blk_start  (blk_start),
        .blk_addr   (blk_addr),
        .blk_busy   (blk_busy),
        .blk_done   (blk_done),
        .blk_err    (blk_err),
        .data_byte  (data_byte),
        .data_valid (data_valid),
        .sd_cs_n    (sd_cs_n),
        .sd_sck     (sd_sck),
        .sd_mosi    (sd_mosi),
        .sd_miso    (sd_miso)
    );

    // ---- DUT: sd_probe（延迟加速）----
    sd_probe #(
        .PROBE_DELAY_CYCLES (300)
    ) dut_probe (
        .clk        (clk),
        .rst_n      (rst_n),
        .init_start (init_start),
        .init_done  (init_done),
        .init_fail  (init_fail),
        .err_code   (err_code),
        .blk_start  (blk_start),
        .blk_addr   (blk_addr),
        .blk_busy   (blk_busy),
        .blk_done   (blk_done),
        .blk_err    (blk_err),
        .data_byte  (data_byte),
        .data_valid (data_valid),
        .sd_ok      (sd_ok),
        .sd_fail    (sd_fail),
        .err_latch  (err_latch)
    );

    // ---- 检查工具 ----
    integer errors = 0;
    task chk;
        input        cond;
        input [511:0] name;   // 静态文本（ModelSim 10.1d 不支持动态字符串传参）
        begin
            if (cond) begin
                $display("PASS: %0s", name);
            end else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // ---- CRC16-CCITT LFSR 期望值计算（与 DUT 一致：含 MSB 反馈）----
    function [15:0] crc16_step;
        input [15:0] c;
        input        b;
        begin
            crc16_step = {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0000);
        end
    endfunction

    // ========================================================================
    // 卡模型 —— 命令收集器（CS 门控 + 帧头校验 + latch 停收）
    // ========================================================================
    reg        cmd_arm = 1'b0;      // 武装：CS 下降沿置位，收满 48 位撤销
    reg        cmd_latch = 1'b0;    // 停收标志：锁存后不再覆盖
    reg [47:0] cmd_shift;           // 命令帧移位
    reg [5:0]  cmd_bits;            // 已收位数
    reg [47:0] cmd_frame;           // 锁存的完整命令帧
    reg        cmd_new = 1'b0;      // 完整帧脉冲

    always @(posedge sd_sck or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            cmd_arm   <= 1'b0;
            cmd_bits  <= 6'd0;
            cmd_latch <= 1'b0;
            cmd_new   <= 1'b0;
        end else begin
            cmd_new <= 1'b0;
            if (cmd_arm && !cmd_latch) begin
                cmd_shift <= {cmd_shift[46:0], sd_mosi};
                if (cmd_bits == 6'd47) begin
                    cmd_frame <= {cmd_shift[46:0], sd_mosi};
                    cmd_bits  <= 6'd0;
                    cmd_latch <= 1'b1;              // 停收防填充位覆盖
                    cmd_new   <= 1'b1;
                end else begin
                    cmd_bits <= cmd_bits + 6'd1;
                end
            end
        end
    end

    // CS 下降沿武装
    always @(negedge sd_cs_n) begin
        cmd_arm   <= 1'b1;
        cmd_bits  <= 6'd0;
        cmd_shift <= 48'hFFFF_FFFF_FFFF;
        cmd_latch <= 1'b0;
    end

    // ========================================================================
    // 卡模型 —— 主控（应答组装）与回放引擎
    // ========================================================================
    // 应答帧装载（直接装 resp_shift，免中转变量旧值坑）
    // R1 型:  {8'h01, 40'd0} 位流 FF..01 → resp_bits=8
    // R7 型:  {8'h01, 32'h0000_01AA, 8'h87} → resp_bits=48
    // R3 型:  {8'h00, 32'hC000_FF80, 8'hFF} → resp_bits=48（busy=0, CCS=1）
    // CMD17R1:{8'h00, 40'd0} → resp_bits=8
    reg [47:0] resp_shift = 48'hFFFF_FFFF_FFFF;
    reg [6:0]  resp_bits  = 7'd0;

    // 数据回放状态
    reg [2:0]  tx_sel = 3'd0;       // 0 静默 / 1 应答 / 2 令牌 / 3 数据 / 4 CRC / 5 填充
    reg [3:0]  ncr_run   = 4'd0;    // Ncr 前导 1 拍数
    reg [47:0] r48_buf;             // 应答位流出移位
    reg [6:0]  r48_bits;
    reg [3:0]  tok_bits;            // 令牌位计数（0xFE = 4 个 1 后 4 个 0 → 低 4 位逐位）
    reg [12:0] data_idx_q;          // 数据字节索引 0~511
    reg [2:0]  bit_in_byte;         // 字节内位序 0=b7..7=b0
    reg [7:0]  byte_out;            // 当拍组合出位字节（组合局部变量，无延迟装载）
    reg [15:0] crc16_run;           // 回放期 CRC 累积
    reg [15:0] crc16_out;           // CRC 出位缓存
    reg [3:0]  crc_bit_q;           // CRC 位流出计数
    reg        bad_crc = 1'b0;      // 注入坏 CRC
    // 扇区 0 内容签名位
    reg [7:0]  sig509 = 8'h00, sig510 = 8'h55, sig511 = 8'hAA;

    // 主控: 消费完整命令帧，按场景组装应答
    always @(posedge clk) begin
        cmd_new <= 1'b0;
        if (cmd_new && probe_phase != PP_POWERUP && cmd_frame[47:46] == 2'b01) begin
            case (cmd_frame[45:40])
                6'd0:  begin // CMD0 → R1=0x01（idle）
                    resp_shift <= {8'h01, 40'd0};
                    resp_bits  <= 7'd8;
                    ncr_run    <= 4'd8;
                    tx_sel     <= 3'd1;
                end
                6'd8:  begin // CMD8 → R7（echo 0x01AA）
                    resp_shift <= {8'h01, 32'h0000_01AA, 8'h87};
                    resp_bits  <= 7'd48;
                    ncr_run    <= 4'd8;
                    tx_sel     <= 3'd1;
                end
                6'd55: begin // CMD55 → R1=0x01
                    resp_shift <= {8'h01, 40'd0};
                    resp_bits  <= 7'd8;
                    ncr_run    <= 4'd8;
                    tx_sel     <= 3'd1;
                end
                6'd41: begin // ACMD41 → R3（busy=0, CCS=1=SDHC）
                    resp_shift <= {8'h00, 32'hC000_FF80, 8'hFF};
                    resp_bits  <= 7'd48;
                    ncr_run    <= 4'd8;
                    tx_sel     <= 3'd1;
                end
                6'd17: begin // CMD17 → R1=0x00 + 场景决定的数据段
                    resp_shift <= {8'h00, 40'd0};
                    resp_bits  <= 7'd8;
                    ncr_run    <= 4'd8;
                    tx_sel     <= 3'd1;
                    // 数据段在应答回放结束后由 tx_sel 桥接逻辑启动
                    tok_bits   <= 4'd0;
                    data_idx_q <= 13'd0;
                    bit_in_byte<= 3'd0;
                    crc16_run  <= 16'd0;
                    crc_bit_q  <= 4'd0;
                    bad_crc    <= 1'b0;
                end
                default: ;
            endcase
        end
    end

    // 回放引擎（negedge SCK 出位 —— 与 DUT 上升沿采样对齐）
    always @(negedge sd_sck) begin
        case (tx_sel)
            3'd0: sd_miso <= 1'b1;                      // 静默高
            3'd1: begin                                 // Ncr + 应答
                if (ncr_run != 4'd0) begin
                    sd_miso <= 1'b1;
                    ncr_run <= ncr_run - 4'd1;
                end else if (resp_bits != 7'd0) begin
                    sd_miso   <= resp_shift[47];
                    resp_shift<= {resp_shift[46:0], 1'b0};
                    resp_bits <= resp_bits - 7'd1;
                end else begin
                    // 应答出完：CMD17 后按场景接数据段前导——
                    //   正常/坏签名: 填充段 8 个 1（真卡 R1 后 MISO 呈 0xFF）→ 令牌
                    //   错误令牌场景: 跳过填充直接 0x05（协议中读错误无专用响应令牌，
                    //     以 R1 后异常字节模拟，走 DUT 已验证的错误令牌路径）
                    if (cmd_frame[45:40] == 6'd17) begin
                        tx_sel <= (probe_phase == PP_ERRTOK) ? 3'd6 : 3'd5;
                    end else begin
                        tx_sel <= 3'd0;
                    end
                end
            end
            3'd5: begin                                 // 填充段: 8 个 1（一个字节）
                sd_miso <= 1'b1;
                tok_bits <= tok_bits + 4'd1;
                if (tok_bits == 4'd7) begin
                    tok_bits <= 4'd0;
                    tx_sel   <= 3'd2;                   // 正常令牌 0xFE
                end
            end
            3'd6: begin                                 // 错误令牌 0x05 = 0000_0101
                sd_miso <= (tok_bits == 4'd3) || (tok_bits == 4'd5)
                         || (tok_bits == 4'd7);
                tok_bits <= tok_bits + 4'd1;
                if (tok_bits == 4'd7) tx_sel <= 3'd0;   // 出完回静默（DUT 会报错）
            end
            3'd2: begin                                 // 数据令牌 0xFE
                sd_miso <= (tok_bits != 4'd7);          // bit7=0 其余 1 → 0xFE MSB first
                tok_bits <= tok_bits + 4'd1;
                if (tok_bits == 4'd7) begin
                    tx_sel <= 3'd3;                     // 转数据段
                end
            end
            3'd3: begin                                 // 数据 512B（索引直接映射字节内容）
                // 字节内容组合决定（不经过延迟装载的 cur_byte，避免出位用旧值）：
                //   0~509 = 索引低 8 位；510/511 = MBR 签名位
                byte_out = (data_idx_q == 13'd510) ? sig510 :
                           (data_idx_q == 13'd511) ? sig511 :
                                                      data_idx_q[7:0];
                sd_miso <= byte_out[3'd7 - bit_in_byte];
                // CRC 累积（含 MSB 反馈，与 DUT LFSR 一致）
                crc16_run <= {crc16_run[14:0], 1'b0}
                           ^ ((crc16_run[15] ^ byte_out[3'd7 - bit_in_byte]) ? 16'h1021 : 16'h0000);
                if (bit_in_byte == 3'd7) begin
                    bit_in_byte <= 3'd0;
                    if (data_idx_q == 13'd511) begin
                        // 末位装载 CRC（含本拍位）
                        crc16_out <= {crc16_run[14:0], 1'b0}
                                   ^ ((crc16_run[15] ^ byte_out[3'd7 - bit_in_byte]) ? 16'h1021 : 16'h0000);
                        tx_sel <= 3'd4;                 // 转 CRC 段
                    end
                    data_idx_q <= data_idx_q + 13'd1;
                end else begin
                    bit_in_byte <= bit_in_byte + 3'd1;
                end
            end
            3'd4: begin                                 // CRC16 出位
                sd_miso <= bad_crc ? ~crc16_out[15] : crc16_out[15];
                crc16_out <= {crc16_out[14:0], 1'b0};
                crc_bit_q <= crc_bit_q + 4'd1;
                if (crc_bit_q == 4'd15) begin
                    tx_sel   <= 3'd0;
                    crc_bit_q<= 4'd0;
                end
            end
            default: sd_miso <= 1'b1;
        endcase
    end

    // ========================================================================
    // 主流程
    // ========================================================================
    initial begin
        $display("==== tb_sd_probe start ====");
        // 复位
        repeat (10) @(posedge clk);
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        // sd_spi_ctrl 的 I_POWERUP（100 拍加速）+ probe 延迟（300 拍）
        wait (dut_probe.sd_ok == 1'b1 || dut_probe.sd_fail == 1'b1);
        repeat (100) @(posedge clk);

        // ---- T1: 无卡 → sd_fail, err_latch=1 ----
        $display("---- T1: no card ----");
        chk(dut_probe.sd_fail == 1'b1,            "T1 sd_fail asserted");
        chk(dut_probe.sd_ok   == 1'b0,            "T1 sd_ok clear");
        chk(dut_probe.err_latch == 4'd1,          "T1 err_latch==1 (retry exhaust)");
        $display("T1 err_latch=%0d", dut_probe.err_latch);

        // ---- T2: 好卡全流程 → sd_ok ----
        $display("---- T2: good card, MBR signature ----");
        rst_n = 1'b0; probe_phase = PP_READY;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        wait (dut_probe.sd_ok == 1'b1 || dut_probe.sd_fail == 1'b1);
        repeat (100) @(posedge clk);
        chk(dut_probe.sd_ok   == 1'b1,            "T2 sd_ok asserted");
        chk(dut_probe.sd_fail == 1'b0,            "T2 sd_fail clear");
        chk(dut_probe.err_latch == 4'd0,          "T2 err_latch==0");
        chk(dut_sd.init_done == 1'b1,             "T2 init_done");

        // ---- T3: 签名坏（511 字节=0x00）→ sd_fail, err_latch=8 ----
        $display("---- T3: bad signature ----");
        sig511 = 8'h00;
        rst_n = 1'b0; probe_phase = PP_BADSIG;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        wait (dut_probe.sd_ok == 1'b1 || dut_probe.sd_fail == 1'b1);
        repeat (100) @(posedge clk);
        chk(dut_probe.sd_fail == 1'b1,            "T3 sd_fail asserted");
        chk(dut_probe.err_latch == 4'd8,          "T3 err_latch==8 (bad signature)");
        sig511 = 8'hAA;                            // 恢复（干净）

        // ---- T4: 错误令牌 → sd_fail, err_latch=5 ----
        $display("---- T4: error token on sector 0 ----");
        rst_n = 1'b0; probe_phase = PP_ERRTOK;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        wait (dut_probe.sd_ok == 1'b1 || dut_probe.sd_fail == 1'b1);
        repeat (100) @(posedge clk);
        chk(dut_probe.sd_fail == 1'b1,            "T4 sd_fail asserted");
        chk(dut_probe.err_latch == 4'd5,          "T4 err_latch==5 (error token)");

        // ---- 收尾 ----
        $display("==== tb_sd_probe done, errors = %0d ====", errors);
        if (errors == 0) $display("*** ALL CHECKS PASSED ***");
        else             $display("*** CHECKS FAILED, errors = %0d ***", errors);
        $finish;
    end

    // 看门狗: 40ms（T3/T4 各含一次完整初始化+读块，加速参数下每次约 2~4ms）
    initial begin
        #40_000_000;
        $display("*** GLOBAL TIMEOUT ***");
        $display("*** CHECKS FAILED, errors = %0d ***", errors + 1);
        $finish;
    end

endmodule
