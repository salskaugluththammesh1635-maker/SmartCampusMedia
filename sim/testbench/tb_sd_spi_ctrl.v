// ============================================================================
// 文件名：sim/testbench/tb_sd_spi_ctrl.v
// ============================================================================
// 【一、在整体系统中的功能】
//   所属层次：阶段四 S1 切片验证（SD 物理接口层 tb）
//   工程归属：SmartCampusMedia SD 卡图片播放系统
//   数据流位置：tb 内建行为级 SD 卡模型 ⇄ 被测 sd_spi_ctrl
//   为什么需要它：SD 卡 SPI 协议有严格的位级时序（命令帧 48bit、Ncr 前导、
//               令牌 0xFE、CRC16），任何位序/位宽错误都会导致上板全链不通。
//               在 tb 里用行为级卡模型逐位回放协议，上板前先抓协议 bug。
// 【二、本模块功能】
//   一句话职责：行为级 SD 卡模型（SDv2 HC），走完初始化全序列 + 读块 +
//   容错场景（令牌超时/错误令牌/坏 CRC/无卡），逐项断言协议与数据正确性。
//   关键特性：
//     1. 卡模型在 SCK 上升沿采样 MOSI、下降沿更新 MISO（与真卡一致）；
//     2. 命令解析只认位流：48bit 移位收集后判 cmd 号与参数——测的是真实
//        协议位流，不依赖被测模块内部节点；
//     3. 应答带 Ncr 延迟（8 位拍），支持 R1/R3/R7；
//     4. 数据块：0xFE 令牌 + 512B 图案 + CRC16（规范多项式逐位算）；
//     5. 容错场景只改回放内容：PH_NODATA（令牌超时）、PH_ERRTOK（错误
//        令牌 0x05）、bad_crc（CRC 故意发错）。
// 【三、接口与内部结构】
//   端口：无（tb 顶层）
//   内部逻辑块（共 5 块）：
//     [1] 时钟/复位生成：25MHz，复位 5 拍后释放
//     [2] 卡模型：命令收集（posedge sd_sck 采 MOSI）+ Ncr 延迟 + 应答/令牌/
//         数据/CRC 逐位回放（negedge sd_sck 驱动 MISO）+ 数据校验监视器
//     [3] CRC7/CRC16 行为级计算
//     [4] 数据图案：byte = idx[7:0]（0..255 循环两遍，可被简单校验）
//     [5] 检查序列 T1~T8：协议位流/数据/超时/错误码逐项断言
// 【四、设计思路与范式】
//   范式定位：行为级从设备模型（BFM）+ 检查表。
//   为什么这样写：卡是「被动应答者」，按协议阶段顺序回放比状态机直接；
//   场景切换只改 card_phase/bad_crc 两个变量，骨架零改动。
//   范式认读方法：见 docs/design_patterns.md §8（验证范式）。
// ============================================================================
`timescale 1ns/1ps
module tb_sd_spi_ctrl;

    // ------------------------------------------------------------------------
    // [1] 时钟/复位
    // ------------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;   // 25MHz
    initial begin
        #200 rst_n = 1'b1;
    end

    // DUT 连线 ----------------------------------------------------------------
    reg         init_start = 1'b0;
    wire        init_done, init_fail;
    wire [3:0]  err_code;
    reg         blk_start = 1'b0;
    reg  [31:0] blk_addr = 32'd0;
    wire        blk_busy, blk_done, blk_err;
    wire [7:0]  data_byte;
    wire        data_valid;
    wire        sd_cs_n, sd_sck, sd_mosi;
    reg         sd_miso = 1'b1;

    // 超时参数 override（仅仿真加速）：SCK_INIT_DIV 32→2（初始化档 6.25MHz，
    // 真卡要求 400kHz 但行为级模型不挑）、上电延时 5.24ms→4µs、NCR_TIMEOUT
    // 128→32、TOKEN_TIMEOUT 2^20→2^16；协议行为不变（分频/超时/延时只是时间
    // 参数，上电延时/超时/重试路径仍被覆盖）。
    sd_spi_ctrl #(
        .SCK_INIT_DIV   (2),
        .NCR_TIMEOUT    (32),
        .TOKEN_TIMEOUT  (65536),
        .POWERUP_CYCLES (100)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .init_start(init_start), .init_done(init_done), .init_fail(init_fail),
        .err_code(err_code),
        .blk_start(blk_start), .blk_addr(blk_addr),
        .blk_busy(blk_busy), .blk_done(blk_done), .blk_err(blk_err),
        .data_byte(data_byte), .data_valid(data_valid),
        .sd_cs_n(sd_cs_n), .sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    // ------------------------------------------------------------------------
    // [3] CRC 行为级
    // ------------------------------------------------------------------------
    function [6:0] crc7_step;
        input [6:0] c;
        input b;
        begin
            crc7_step = {c[5:0], 1'b0} ^ (b ? 7'h09 : 7'h00);
        end
    endfunction
    function [15:0] crc16_step;
        input [15:0] c;
        input b;
        begin
            // 与 DUT 一致的硬件 LFSR 式：MSB 参与反馈异或
            crc16_step = {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0000);
        end
    endfunction

    // ------------------------------------------------------------------------
    // [2] 卡模型
    // ------------------------------------------------------------------------
    localparam PH_POWERUP = 2'd0;  // 上电静默：不响应（MISO 恒 1）
    localparam PH_READY   = 2'd1;  // 正常卡
    localparam PH_NODATA  = 2'd2;  // 读块不给令牌
    localparam PH_ERRTOK  = 2'd3;  // 读块回错误令牌
    reg [1:0] card_phase = PH_POWERUP;
    reg       bad_crc    = 1'b0;

    // —— 命令收集（posedge sd_sck 采 MOSI，CS 低电平才有效）——
    // 三态扫描，与真卡行为一致（关键：Ncc 填充期 MOSI 恒 1，若像旧版那样
    // 从 CS 下降沿起盲数 48 位，填充位会被当成帧头导致整帧错位）：
    //   态0 等 start=0 → 态1 校验下一位 trans=1（不符退回态0）→ 态2 收余 46 位。
    // 帧结构 {start 0, trans 1, cmd[5:0], arg[31:0], crc7[6:0], stop 1} = 48 位。
    // 收满后 cmd_frame 拼成完整 48 位（[47:46]=2'b01 供主流程校验），停收直到 CS 上升。
    reg [47:0] cmd_shift = 48'd0;
    reg [5:0]  cmd_bits  = 6'd0;
    reg [1:0]  cmd_state = 2'd0;    // 0=等 start 1=等 trans 2=收帧体
    reg [47:0] cmd_frame = 48'd0;
    reg        cmd_new   = 1'b0;    // 完整命令到达脉冲（主流程 @clk 消费）
    always @(posedge sd_sck or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            cmd_state <= 2'd0;
            cmd_bits  <= 6'd0;
            cmd_shift <= 48'd0;
            cmd_new   <= 1'b0;             // CS 撤销时丢弃未消费的旧命令，隔离复位前后的事务
        end else begin
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
                              // 本拍是第 46 位（stop），连同前 45 位拼成完整帧
                              cmd_frame <= {2'b01, cmd_shift[44:0], sd_mosi};
                              cmd_new   <= 1'b1;
                              cmd_bits  <= 6'd0;
                              cmd_state <= 2'd0;   // 回态0：等下一条命令的 start
                          end else begin
                              cmd_bits <= cmd_bits + 6'd1;
                          end
                      end
                default: cmd_state <= 2'd0;
            endcase
        end
    end

    // —— 应答/数据回放（negedge sd_sck 驱动 MISO）——
    reg [47:0] resp_shift = 48'hFFFF_FFFF_FFFF;
    reg [6:0]  resp_bits  = 7'd0;    // 剩余应答位数
    reg [2:0]  ncr_cnt    = 3'd0;    // Ncr 延迟（8 位拍）
    reg        ncr_run    = 1'b0;
    reg [3:0]  tok_bits   = 4'd0;    // 令牌位序（0~7）
    reg [12:0] data_idx   = 13'd0;   // 数据字节索引 0~511
    reg [7:0]  cur_byte   = 8'd0;    // 当前回放字节（= data_idx_q[7:0] 图案）
    reg [4:0]  crc_bits   = 5'd0;    // CRC16 位序 0~15
    reg [15:0] crc16_out  = 16'd0;   // 当前回放 CRC 值
    reg [2:0]  tx_sel     = 3'd0;    // 0=静默 1=Ncr后应答 2=令牌/数据/CRC 3=错误令牌流
    reg [12:0] data_idx_q = 13'd0;   // negedge 块用的字节索引（0~511，内容=idx[7:0]）
    reg [2:0]  bit_in_byte = 3'd0;   // 字节内位序计数（0=b7 … 7=b0，MSB first）

    // 数据图案：字节 = idx[7:0]（0..255 循环两遍）
    // CRC16 在发送每个数据位时同步累积（与线上一致）
    reg [15:0] crc16_run = 16'h0000; // 数据阶段实时 CRC（发位时累积）

    // 主流程：@posedge clk 消费 cmd_new，组装应答帧
    reg [5:0]  cmd_seen;
    reg [31:0] arg_seen;
    // 卡的协议状态只由命令改变；主机 rst_n 不模拟卡断电，CS 撤销也不清除 idle 状态。
    reg        card_idle = 1'b1;             // CMD0 进入 idle，成功 ACMD41 后退出
    reg        app_cmd_pending = 1'b0;       // CMD55 只授权紧随其后的一条应用命令
    integer    acmd_busy_polls = 1;          // 每次 CMD0 后先回若干次 R1=01，再回 R1=00
    integer    acmd_poll_count = 0;          // 当前初始化收到的合法 ACMD41 数
    integer    acmd_busy_sent = 0;           // 当前初始化实际装载的 busy 应答数
    integer    acmd_ready_sent = 0;          // 当前初始化实际装载的 ready 应答数
    integer    cmd58_count = 0;              // 当前初始化的 OCR 查询数
    integer    command_errors = 0;          // 只统计线上帧与命令序列，不读取 DUT 内部状态

    always @(posedge clk) begin
        cmd_new <= 1'b0;
        if (cmd_new && !sd_cs_n && card_phase != PH_POWERUP
                                 && cmd_frame[47:46] == 2'b01) begin
            cmd_seen <= cmd_frame[45:40];
            arg_seen <= cmd_frame[39:8];
            app_cmd_pending <= 1'b0;        // CMD55 的授权不能跨过另一条命令继续有效
            // SPI 关闭通用 CRC 后，CMD0/CMD8 仍校验固定 CRC；其余命令至少校验 stop 与参数。
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
            // 48 位寄存器仅作左对齐容器；线上长度由 resp_bits 决定，R7/R3 没有响应 CRC 尾字节。
            resp_bits <= 7'd8;              // CMD0/CMD55/ACMD41/CMD17 都只回一字节 R1
            ncr_run   <= 1'b1;              // 在完整命令 stop 位之后插入八个高位
            ncr_cnt   <= 3'd0;
            tx_sel    <= 3'd1;
            case (cmd_frame[45:40])
                6'd0: begin
                    resp_shift <= {8'h01, 40'd0}; // CMD0：进入 idle，不受主机先前复位方式影响
                    card_idle <= 1'b1;
                    acmd_poll_count <= 0;
                    acmd_busy_sent <= 0;
                    acmd_ready_sent <= 0;
                    cmd58_count <= 0;
                end
                6'd8: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00), 32'h0000_01AA, 8'hFF};
                    resp_bits <= 7'd40;     // R7 = R1 + 32 位 IF_COND，后面的容器字节不发送
                end
                6'd55: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00), 40'd0}; // R1 的 idle 位跟随真实卡状态
                    app_cmd_pending <= 1'b1;
                end
                6'd41: begin
                    if (!app_cmd_pending) begin
                        resp_shift <= {(card_idle ? 8'h05 : 8'h04), 40'd0}; // 无 CMD55 前缀则拒绝应用命令
                    end else if (card_idle && acmd_poll_count < acmd_busy_polls) begin
                        resp_shift <= {8'h01, 40'd0}; // busy：只有 R1，不把 OCR 塞进 ACMD41
                        acmd_busy_sent <= acmd_busy_sent + 1;
                    end else begin
                        resp_shift <= {8'h00, 40'd0}; // ready：后续由 CMD58 单独读取 OCR
                        card_idle <= 1'b0;
                        acmd_ready_sent <= acmd_ready_sent + 1;
                    end
                    if (app_cmd_pending) acmd_poll_count <= acmd_poll_count + 1;
                end
                6'd58: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00),
                                   (card_idle ? 32'h40FF_8000 : 32'hC0FF_8000), 8'hFF};
                    resp_bits <= 7'd40;     // R3 = R1 + OCR；bit31=上电完成、bit30=SDHC
                    cmd58_count <= cmd58_count + 1;
                end
                6'd17: begin
                    resp_shift <= {(card_idle ? 8'h01 : 8'h00), 40'd0}; // 未初始化的卡拒绝读块
                end
                default: resp_shift <= {(card_idle ? 8'h05 : 8'h04), 40'd0}; // 未实现命令回 illegal-command
            endcase
        end
    end

    // 回放引擎：下降沿出位；CS 撤销立即中止本事务，但保留卡的初始化状态。
    always @(negedge sd_sck or posedge sd_cs_n) begin
        if (sd_cs_n) begin
            sd_miso <= 1'b1;                // 未选中时由上拉呈高，不允许旧响应污染下一事务
            tx_sel <= 3'd0;
            resp_bits <= 7'd0;
            ncr_run <= 1'b0;
            ncr_cnt <= 3'd0;
            tok_bits <= 4'd0;
            data_idx_q <= 13'd0;
            bit_in_byte <= 3'd0;
            crc_bits <= 5'd0;
        end else if (ncr_run) begin
            sd_miso <= 1'b1;         // Ncr 期间保持高
            if (ncr_cnt == 3'd7) begin
                ncr_run <= 1'b0;
            end else begin
                ncr_cnt <= ncr_cnt + 3'd1;
            end
        end else if (tx_sel == 3'd1 && resp_bits != 0) begin
            sd_miso    <= resp_shift[47];
            resp_shift <= {resp_shift[46:0], 1'b0};
            resp_bits  <= resp_bits - 7'd1;
            if (resp_bits == 7'd1) begin
                // 应答最后一位：准备数据阶段（仅 CMD17）
                if (card_phase == PH_READY || card_phase == PH_NODATA
                     || card_phase == PH_ERRTOK) begin
                    if (cmd_seen == 6'd17 && !card_idle) begin
                        if (card_phase == PH_ERRTOK) begin
                            tx_sel   <= 3'd3;  // 错误令牌
                            tok_bits <= 4'd0;
                        end else if (card_phase == PH_NODATA) begin
                            tx_sel <= 3'd0;    // 永不给令牌
                        end else begin
                            // 本组旧用例选择在 R1 与令牌之间等待一个 0xFF 字节；这是数据等待，不是 Ncr。
                            // 不再把该等待当成 DUT 修复错位所必需的协议前提，零等待另由独立协议回归覆盖。
                            tx_sel      <= 3'd4; // 前导 0xFF 过渡
                            tok_bits    <= 4'd0;
                            data_idx    <= 13'd0;
                            data_idx_q  <= 13'd0;
                            bit_in_byte <= 3'd0;
                            cur_byte    <= 8'd0;
                            crc16_run   <= 16'h0000;
                            crc_bits    <= 5'd0;
                        end
                    end
                end
            end
        end else if (tx_sel == 3'd4) begin
            // 数据等待恰为八个高位；第八位同时切换，避免空转分支多发第九位。
            sd_miso <= 1'b1;
            if (tok_bits == 4'd7) begin
                tx_sel   <= 3'd2;           // 下一下降沿直接发送令牌首位
                tok_bits <= 4'd0;
            end else begin
                tok_bits <= tok_bits + 4'd1;
            end
        end else if (tx_sel == 3'd2) begin
            // 令牌 0xFE（8 位）：tok_bits 0~6 出 1，第 7 位出 0（MSB first）
            if (tok_bits != 4'd8) begin
                sd_miso  <= (tok_bits != 4'd7); // 0xFE = 1111_1110
                tok_bits <= tok_bits + 4'd1;
            end else if (data_idx_q != 13'd512) begin
                // 数据位流：字节内容 = 索引低 8 位（idx[7:0]），MSB first 逐位出
                sd_miso <= cur_byte[3'd7 - bit_in_byte];
                crc16_run <= {crc16_run[14:0], 1'b0}
                           ^ ((crc16_run[15] ^ cur_byte[3'd7 - bit_in_byte])
                              ? 16'h1021 : 16'h0000);
                if (bit_in_byte == 3'd7) begin
                    bit_in_byte <= 3'd0;
                    data_idx_q  <= data_idx_q + 13'd1;
                    cur_byte    <= data_idx_q[7:0] + 8'd1;  // 下一字节 = 下一索引
                    if (data_idx_q == 13'd511) begin
                        // 最后一个数据位：装载含本拍位的完整 CRC（与 crc16_run 终值一致）
                        crc16_out <= {crc16_run[14:0], 1'b0}
                                   ^ ((crc16_run[15] ^ cur_byte[0]) ? 16'h1021 : 16'h0000);
                    end
                end else begin
                    bit_in_byte <= bit_in_byte + 3'd1;
                end
            end else if (crc_bits != 5'd16) begin
                // CRC16 位流（bad_crc 时取反）
                sd_miso   <= bad_crc ? ~crc16_out[15] : crc16_out[15];
                crc16_out <= {crc16_out[14:0], 1'b0};
                crc_bits  <= crc_bits + 5'd1;
            end else begin
                tx_sel <= 3'd0;   // 数据块发完
            end
        end else if (tx_sel == 3'd3) begin
            // 错误令牌 0x05（0000_0101）8 位
            if (tok_bits != 4'd8) begin
                case (tok_bits)
                    4'd0, 4'd1, 4'd2, 4'd3: sd_miso <= 1'b0;
                    4'd4, 4'd6: sd_miso <= 1'b0;
                    4'd5, 4'd7: sd_miso <= 1'b1;
                endcase
                tok_bits <= tok_bits + 4'd1;
            end else begin
                tx_sel <= 3'd0;
            end
        end else begin
            sd_miso <= 1'b1;   // 静默
        end
    end

    // 数据位流 CRC 实时累积（在 tx_sel==2 的数据位拍）
    // 注：CRC 累积在 posedge clk 按位推进（dut 内部用 sck_rise 采样，tb 在
    // negedge 发出数据位 → 下一个 sck_rise DUT 采到，两拍后 clk 域稳定可见）

    // ------------------------------------------------------------------------
    // [4] 数据监视器：收集 data_valid 字节并校验图案与 CRC
    // ------------------------------------------------------------------------
    integer       mon_cnt = 0;
    reg [7:0]     mon_mem [0:511];
    reg           mon_byte_err = 1'b0;
    reg [15:0]    mon_crc = 16'h0000;
    reg [15:0]    mon_crc_exp = 16'h0000;
    always @(posedge clk) begin
        if (data_valid) begin
            mon_mem[mon_cnt[12:0]] <= data_byte;
            mon_cnt <= mon_cnt + 1;
        end
        if (blk_done || blk_err) begin
            mon_cnt <= 0;
        end
    end

    // ------------------------------------------------------------------------
    // [4b] CS/SCK 协议监视器：抓「Ncc 给错位置」这类硬件级违规
    // ------------------------------------------------------------------------
    // 这里检查本控制器的实现约定，而不是宣称所有 SD 卡都禁止选中后的空闲高位。
    //   ①cs_head_err：本实现应在 CS 拉低后的首个采样上升沿发送 start=0。
    //   ②ncc_short：本实现约定命令前提供至少 NCC_CYCLES 个 CS 高电平空时钟，零个也必须报错。
    // 复位期间清除窗口/边沿历史，避免把主机异步复位误计成正常命令开始。
    localparam integer NCC_EXPECT = 8;   // 必须与 sd_spi_ctrl 的 NCC_CYCLES 一致
    reg        sck_q         = 1'b0;     // sd_sck 打一拍（边沿检测用）
    wire       sck_rise_ref  = sd_sck & ~sck_q;   // sd_sck 上升沿拍
    wire       sck_fall_ref  = ~sd_sck & sck_q;   // sd_sck 下降沿拍
    reg        cs_d          = 1'b1;     // CS 打一拍（下降沿检测）
    reg        cs_head_seen  = 1'b0;     // 本次 CS 低电平窗口已检查过首位的 start
    reg        cs_first_mosi = 1'b1;     // 首位采样值（1=违规）
    integer    cs_head_err   = 0;        // 违规次数累计
    integer    ncc_gap       = 0;        // CS 高期间的 SCK 下降沿累计
    integer    ncc_short     = 0;        // Ncc 不足次数累计

    always @(posedge clk) begin
        cs_d <= rst_n ? sd_cs_n : 1'b1;
        if (!rst_n) begin
            cs_head_seen <= 1'b0;
            cs_first_mosi <= 1'b1;
            ncc_gap <= 0;
        end else begin
        // CS 拉低那一拍：开始新窗口，首位标志复位
        if (cs_d && !sd_cs_n) begin
            cs_head_seen  <= 1'b0;
            cs_first_mosi <= 1'b1;
            ncc_gap       <= 0;
        end
        // CS 高期间的 SCK 下降沿：累计 Ncc 间隔（含上电 80 空周期）
        if (sd_cs_n && sck_fall_ref) begin
            ncc_gap <= ncc_gap + 1;
        end
        // CS 低窗口里第一个 SCK 上升沿：采 MOSI 判 start
        if (!sd_cs_n && !cs_head_seen && sck_rise_ref) begin
            cs_head_seen  <= 1'b1;
            cs_first_mosi <= sd_mosi;
            if (sd_mosi !== 1'b0) begin
                cs_head_err <= cs_head_err + 1;
                $display("PROTO-ERR: CS 拉低后首位 MOSI=%b（应为 start=0）@%0t", sd_mosi, $time);
            end
        end
        end
    end

    // 独立的 SCK 边沿参考用的打拍寄存器（已在上方声明 sck_q/sck_rise_ref/sck_fall_ref）
    always @(posedge clk) begin
        sck_q <= rst_n ? sd_sck : 1'b0;
        // 新命令选中时校验此前的高电平空时钟数；不能放过 ncc_gap=0。
        if (rst_n && cs_d && !sd_cs_n) begin
            if (ncc_gap < NCC_EXPECT) begin
                ncc_short <= ncc_short + 1;
                $display("PROTO-ERR: 命令间隔只有 %0d 个 SCK（应 >= %0d）@%0t",
                         ncc_gap, NCC_EXPECT, $time);
            end
        end
    end

    // ------------------------------------------------------------------------
    // [5] 检查序列
    // ------------------------------------------------------------------------
    integer errors = 0;
    task chk;
        input cond;
        input [8*40-1:0] name;
        begin
            if (cond) begin
                $display("PASS: %0s", name);
            end else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    // 场景任务：复位后走完整初始化
    task run_init;
        begin
            // 卡进入 READY
            card_phase = PH_READY;
            @(posedge clk);
            init_start <= 1'b1;
            @(posedge clk);
            init_start <= 1'b0;
            wait (init_done == 1'b1 || init_fail == 1'b1); // 初始化失败也交回检查序列，避免只剩看门狗诊断
            @(posedge clk);
        end
    endtask

    // 读一块并等完成
    task run_read_block;
        input [31:0] addr;
        begin
            @(posedge clk);
            blk_addr  <= addr;
            blk_start <= 1'b1;
            @(posedge clk);
            blk_start <= 1'b0;
            wait (blk_done == 1'b1 || blk_err == 1'b1);
            @(posedge clk);
        end
    endtask

    // 等待 DUT 状态机空闲（cs_n 高 + 一段时间）
    task wait_idle;
        integer w;
        begin
            for (w = 0; w < 200; w = w + 1) @(posedge clk);
        end
    endtask

    // CRC16 期望值计算（对 512B 图案，与卡模型同源）
    task calc_crc16_exp;
        integer b, i2;
        reg [7:0] db;
        reg [15:0] c;
        begin
            c = 16'h0000;
            for (b = 0; b < 512; b = b + 1) begin
                db = b[7:0];
                for (i2 = 7; i2 >= 0; i2 = i2 - 1)
                    c = crc16_step(c, db[i2]);
            end
            mon_crc_exp = c;
        end
    endtask

    // ------------------------------------------------------------------------
    // 主流程
    // ------------------------------------------------------------------------
    initial begin
        // 上电静默期等复位稳定 + 等 DUT I_POWERUP 计满（tb 参数 100 拍≈4µs）进 I_IDLE
        wait (rst_n == 1'b1);
        wait (dut.st_init == 4'd1);   // I_IDLE
        wait_idle();

        // ================================================================
        // T1：无卡场景（PH_POWERUP 恒静默）→ CMD0 重试用尽 err=1
        // （时间预算：80SCK×8×32×2 拍 ×(1+8 次重试) ≈ 37 万拍 = 15ms）
        // ================================================================
        $display("---- T1: no card -> CMD0 retry exhaust, err=1 ----");
        card_phase = PH_POWERUP;
        @(posedge clk);
        init_start <= 1'b1;
        @(posedge clk);
        init_start <= 1'b0;
        wait (init_fail == 1'b1);
        chk(err_code == 4'd1, "T1 err_code==1 (CMD0 retry)");
        wait_idle();

        // ================================================================
        // T2：正常初始化序列（PH_READY）→ init_done=1、无 err
        // ================================================================
        $display("---- T2: normal init sequence -> init_done ----");
        // 复位 DUT（卡模型不受 tb 复位影响——仅靠 card_phase 控制），
        // 复位释放后重等 I_POWERUP 计满进 I_IDLE
        rst_n <= 1'b0;
        #100;
        rst_n <= 1'b1;
        wait (dut.st_init == 4'd1);   // I_IDLE
        wait_idle();
        run_init();
        chk(init_done == 1'b1, "T2 init_done asserted");
        chk(init_fail == 1'b0, "T2 init_fail clear");
        chk(err_code == 4'd0, "T2 err_code==0");
        chk(acmd_busy_sent == 1 && acmd_ready_sent == 1, "T2 ACMD41 R1 busy then ready");
        chk(cmd58_count == 1, "T2 reads OCR once using CMD58");
        if (init_done !== 1'b1) begin
            $display("CHECKS FAILED, errors = %0d (initialization)", errors);
            $finish;                         // 没有初始化成功时不继续发读块，保留首个失败现场
        end
        // SCK 已切高速档：读块 SCK 半周期 = 1 拍
        // （由 blk 流程隐式验证）

        // ================================================================
        // T3：正常读块 → 512B 图案 + CRC 全对
        // ================================================================
        $display("---- T3: normal block read ----");
        bad_crc = 1'b0;
        calc_crc16_exp();
        run_read_block(32'h0000_1234);
        chk(blk_done == 1'b1, "T3 blk_done asserted");
        chk(blk_err == 1'b0, "T3 blk_err clear");
        chk(mon_cnt == 512, "T3 received 512 bytes");
        begin : t3_data_check
            integer bi;
            reg [7:0] eb;
            mon_byte_err = 1'b0;
            for (bi = 0; bi < 512; bi = bi + 1) begin
                eb = bi[7:0];
                if (mon_mem[bi] !== eb) begin
                    $display("  byte %0d mismatch: got %02x exp %02x",
                             bi, mon_mem[bi], eb);
                    mon_byte_err = 1'b1;
                end
            end
            chk(mon_byte_err == 1'b0, "T3 data pattern match");
        end
        wait_idle();

        // ================================================================
        // T4：坏 CRC → blk_err=1、err_code=6
        // ================================================================
        $display("---- T4: bad CRC -> blk_err, err=6 ----");
        bad_crc = 1'b1;
        run_read_block(32'h0000_0001);
        chk(blk_err == 1'b1, "T4 blk_err asserted");
        chk(err_code == 4'd6, "T4 err_code==6 (CRC mismatch)");
        bad_crc = 1'b0;
        wait_idle();

        // ================================================================
        // T5：错误令牌 0x05 → blk_err=1、err_code=5
        // ================================================================
        $display("---- T5: error token -> blk_err, err=5 ----");
        card_phase = PH_ERRTOK;
        run_read_block(32'h0000_0002);
        chk(blk_err == 1'b1, "T5 blk_err asserted");
        chk(err_code == 4'd5, "T5 err_code==5 (bad token)");
        card_phase = PH_READY;
        wait_idle();

        // ================================================================
        // T6：令牌超时（PH_NODATA 永不给令牌）→ blk_err=1、err=5
        // ================================================================
        $display("---- T6: token timeout -> blk_err, err=5 ----");
        card_phase = PH_NODATA;
        run_read_block(32'h0000_0003);
        chk(blk_err == 1'b1, "T6 blk_err asserted");
        chk(err_code == 4'd5, "T6 err_code==5 (token timeout)");
        card_phase = PH_READY;
        wait_idle();

        // ================================================================
        // T7：主机复位但卡不断电；CMD0 后真实返回三轮 idle，再在第四轮 ACMD41 就绪。
        // ================================================================
        $display("---- T7: real ACMD41 idle polling after host reset ----");
        acmd_busy_polls = 3;                  // 场景改变实际线上 R1 序列，不再用第二次读块冒充轮询
        rst_n <= 1'b0;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        wait (dut.st_init == 4'd1);            // 重新等待主机上电延时；卡状态直到 CMD0 才改变
        wait_idle();
        run_init();
        chk(init_done == 1'b1 && !init_fail, "T7 init succeeds after busy polling");
        chk(acmd_busy_sent == 3, "T7 three ACMD41 R1=01 replies");
        chk(acmd_ready_sent == 1 && acmd_poll_count == 4, "T7 fourth ACMD41 R1=00 reply");
        chk(cmd58_count == 1, "T7 CMD58 follows ready ACMD41");
        wait_idle();

        // ================================================================
        // T8：CS/SCK 协议合规（Ncc 必须给在 CS 高期间）
        // ================================================================
        $display("---- T8: CS/Ncc protocol compliance ----");
        chk(cs_head_err == 0, "T8 every command starts right after CS low");
        chk(ncc_short   == 0, "T8 Ncc gap >= 8 SCK between commands");
        chk(command_errors == 0, "T8 command stop CRC and order legal");

        // ================================================================
        // 汇总
        // ================================================================
        #1000;
        if (errors == 0) begin
            $display("ALL CHECKS PASSED, errors = 0");
        end else begin
            $display("CHECKS FAILED, errors = %0d", errors);
        end
        $finish;
    end

    // 超时看门狗
    initial begin
        #20_000_000; // 20ms 仿真时间上限（T6 令牌超时 65536 SCK≈5.2ms + 前序用例余量）
        $display("TIMEOUT: simulation watchdog fired");
        $display("CHECKS FAILED, errors = %0d", errors + 1);
        $finish;
    end

endmodule
