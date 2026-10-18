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
    // 卡模型 —— 命令收集器（三态扫描：等 start → 校验 trans → 收帧体）
    // ========================================================================
    // 与 tb_sd_spi_ctrl.v 同款。关键：DUT 现在每条命令前插 Ncc 填充段
    // （MOSI 恒 1 空翻 8 个 SCK），若像旧版那样从 CS 下降沿起盲数 48 位，
    // 填充位会被当成帧头 → 整帧错位 → 卡对合法命令静默。
    reg [1:0]  cmd_state = 2'd0;    // 0=等 start 1=等 trans 2=收帧体
    reg [47:0] cmd_shift;           // 命令帧移位
    reg [5:0]  cmd_bits;            // 已收位数
    reg [47:0] cmd_frame;           // 锁存的完整命令帧
    reg        cmd_new = 1'b0;      // 完整帧脉冲

    always @(posedge sd_sck or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            cmd_state <= 2'd0;
            cmd_bits  <= 6'd0;
            cmd_shift <= 48'd0;
            cmd_new   <= 1'b0;
        end else begin
            cmd_new <= 1'b0;
            case (cmd_state)
                2'd0: if (!sd_mosi) begin
                          cmd_state <= 2'd1;   // 采到 start 位
                          cmd_shift <= 48'd0;
                          cmd_bits  <= 6'd0;
                      end
                2'd1: cmd_state <= sd_mosi ? 2'd2 : 2'd0;  // trans 必须为 1
                2'd2: begin
                          cmd_shift <= {cmd_shift[44:0], sd_mosi};
                          if (cmd_bits == 6'd45) begin
                              cmd_frame <= {2'b01, cmd_shift[44:0], sd_mosi};
                              cmd_bits  <= 6'd0;
                              cmd_state <= 2'd0;   // 回态0：等下一条命令
                              cmd_new   <= 1'b1;
                          end else begin
                              cmd_bits <= cmd_bits + 6'd1;
                          end
                      end
                default: cmd_state <= 2'd0;
            endcase
        end
    end

    // ========================================================================
    // 卡模型 —— 主控（应答组装）与回放引擎
    // ========================================================================
    // 应答左对齐装入 48 位容器，但线上只发 resp_bits 位；R7/R3 都没有响应 CRC 尾字节。
    // R1：8 位；CMD8/R7：{01, 000001AA} 共 40 位；CMD58/R3：{00, C0FF8000} 共 40 位。
    // ACMD41 只回 8 位 R1，先 idle=01 再 ready=00；CMD55 的 idle 位跟随卡的实际状态。
    reg [47:0] resp_shift = 48'hFFFF_FFFF_FFFF;
    reg [6:0]  resp_bits  = 7'd0;

    // 数据回放状态
    reg [2:0]  tx_sel = 3'd0;       // 0 静默 / 1 应答 / 2 令牌 / 3 数据 / 4 CRC / 5 填充
    reg [3:0]  ncr_run   = 4'd0;    // Ncr 前导 1 拍数
    reg [47:0] r48_buf;             // 应答位流出移位
    reg [6:0]  r48_bits;
    reg [3:0]  tok_bits;            // 令牌位序 0~7：0xFE 为七个 1 后一个 0，MSB first
    reg [12:0] data_idx_q;          // 数据字节索引 0~511
    reg [2:0]  bit_in_byte;         // 字节内位序 0=b7..7=b0
    reg [7:0]  byte_out;            // 当拍组合出位字节（组合局部变量，无延迟装载）
    reg [15:0] crc16_run;           // 回放期 CRC 累积
    reg [15:0] crc16_out;           // CRC 出位缓存
    reg [3:0]  crc_bit_q;           // CRC 位流出计数
    reg        bad_crc = 1'b0;      // 注入坏 CRC
    // 扇区 0 内容签名位
    reg [7:0]  sig509 = 8'h00, sig510 = 8'h55, sig511 = 8'hAA;

    // 主机复位不代表卡断电：协议状态保留到 CMD0，CS 撤销仅中止当前回放。
    reg        card_idle = 1'b1;            // 真实卡状态：CMD0 进入 idle，ACMD41 ready 后清除
    reg        app_cmd_pending = 1'b0;      // CMD55 仅授权下一条应用命令
    integer    acmd_poll_count = 0;         // 每次 CMD0 后累计合法 ACMD41 轮数
    integer    acmd_busy_sent = 0;          // 本轮初始化实际回过的 R1=01 数量
    integer    acmd_ready_sent = 0;         // 本轮初始化实际回过的 R1=00 数量
    integer    cmd58_count = 0;             // 本轮初始化实际 OCR 查询数量
    integer    command_errors = 0;         // 仅基于线上命令位流的合法性计数

    // 主控：消费完整命令帧，按 SPI 应答格式与当前卡状态组装回放。
    always @(posedge clk) begin
        cmd_new <= 1'b0;
        if (cmd_new && !sd_cs_n && probe_phase != PP_POWERUP
                                 && cmd_frame[47:46] == 2'b01) begin
            app_cmd_pending <= 1'b0;        // 不允许旧 CMD55 授权跨过另一条命令
            if (cmd_frame[0] !== 1'b1
                || (cmd_frame[45:40] == 6'd0
                    && (cmd_frame[39:8] !== 32'd0 || cmd_frame[7:0] !== 8'h95))
                || (cmd_frame[45:40] == 6'd8
                    && (cmd_frame[39:8] !== 32'h0000_01AA || cmd_frame[7:0] !== 8'h87))
                || (cmd_frame[45:40] == 6'd55 && cmd_frame[39:8] !== 32'd0)
                || (cmd_frame[45:40] == 6'd41 && !app_cmd_pending)
                || (cmd_frame[45:40] == 6'd58
                    && (cmd_frame[39:8] !== 32'd0 || card_idle))) begin
                command_errors <= command_errors + 1;
                $display("PROTO-ERR: 非法命令或顺序 cmd=%0d frame=%012x @%0t",
                         cmd_frame[45:40], cmd_frame, $time);
            end
            resp_bits <= 7'd8;              // R1 默认为八位，只有 CMD8/CMD58 扩成四十位
            ncr_run <= 4'd8;                // 八个高位均在完整命令 stop 位之后发送
            tx_sel <= 3'd1;
            case (cmd_frame[45:40])
                6'd0: begin
                    resp_shift <= {8'h01, 40'd0}; // CMD0 进入 idle，并开始新的初始化计数
                    card_idle <= 1'b1;
                    acmd_poll_count <= 0;
                    acmd_busy_sent <= 0;
                    acmd_ready_sent <= 0;
                    cmd58_count <= 0;
                end
                6'd8: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00), 32'h0000_01AA, 8'hFF};
                    resp_bits <= 7'd40;     // R7 无额外 CRC，容器末八位不发送
                end
                6'd55: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00), 40'd0}; // idle/ready 下分别回 01/00
                    app_cmd_pending <= 1'b1;
                end
                6'd41: begin
                    if (!app_cmd_pending) begin
                        resp_shift <= {(card_idle ? 8'h05 : 8'h04), 40'd0}; // 缺 CMD55 时回 illegal-command
                    end else if (card_idle && acmd_poll_count == 0) begin
                        resp_shift <= {8'h01, 40'd0}; // 第一轮 busy，强制 DUT 真实再次发 CMD55+ACMD41
                        acmd_busy_sent <= acmd_busy_sent + 1;
                    end else begin
                        resp_shift <= {8'h00, 40'd0}; // 第二轮 ready；OCR 留给单独 CMD58
                        card_idle <= 1'b0;
                        acmd_ready_sent <= acmd_ready_sent + 1;
                    end
                    if (app_cmd_pending) acmd_poll_count <= acmd_poll_count + 1;
                end
                6'd58: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00),
                                   (card_idle ? 32'h40FF_8000 : 32'hC0FF_8000), 8'hFF};
                    resp_bits <= 7'd40;     // R3 的 bit31=上电完成，bit30=SDHC
                    cmd58_count <= cmd58_count + 1;
                end
                6'd17: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00), 40'd0}; // 未初始化时只回 idle，不接数据
                    tok_bits <= 4'd0;
                    data_idx_q <= 13'd0;
                    bit_in_byte <= 3'd0;
                    crc16_run <= 16'd0;
                    crc_bit_q <= 4'd0;
                    bad_crc <= 1'b0;
                end
                default: resp_shift <= {(card_idle ? 8'h05 : 8'h04), 40'd0}; // 模型不支持的命令显式拒绝
            endcase
        end
    end

    // 回放引擎：下降沿出位；CS 变高立即丢弃剩余响应/数据，避免主机复位后旧位流串入。
    always @(negedge sd_sck or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            sd_miso <= 1'b1;                // 未选中时不驱动低电平，模型中由上拉呈高
            tx_sel <= 3'd0;
            resp_bits <= 7'd0;
            ncr_run <= 4'd0;
            tok_bits <= 4'd0;
            data_idx_q <= 13'd0;
            bit_in_byte <= 3'd0;
            crc_bit_q <= 4'd0;
        end else begin
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
                    if (resp_bits == 7'd1) begin
                        // 在发送 R1 最后一位时桥接；不额外保持该位一整拍，避免插入第九个响应位。
                        if (cmd_frame[45:40] == 6'd17 && !card_idle) begin
                            tx_sel <= (probe_phase == PP_ERRTOK) ? 3'd6 : 3'd5;
                        end else begin
                            tx_sel <= 3'd0;
                        end
                    end
                end
            end
            3'd5: begin                                 // 数据等待：本组用例选择八个高位，不把它误称为 Ncr
                sd_miso <= 1'b1;
                tok_bits <= tok_bits + 4'd1;
                if (tok_bits == 4'd7) begin
                    tok_bits <= 4'd0;
                    tx_sel   <= 3'd2;                   // 正常令牌 0xFE
                end
            end
            3'd6: begin                                 // 错误令牌 0x05 = 0000_0101
                sd_miso <= (tok_bits == 4'd5) || (tok_bits == 4'd7); // MSB first 的 0000_0101，不能多置 bit4
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
        chk(acmd_busy_sent == 1 && acmd_ready_sent == 1, "T2 ACMD41 busy then ready");
        chk(cmd58_count == 1,                    "T2 OCR queried using CMD58");

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

        // ---- 收尾：帧合法性来自引脚位流，不以 DUT 内部节点作为期望答案。----
        chk(command_errors == 0,                 "command stop CRC and order legal");
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
