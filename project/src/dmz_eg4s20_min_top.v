// =============================================================================
// dmz_eg4s20_min_top.v
// 功能: DMZ-EG4S20 阶段二"最小系统"上板自检顶层
//       —— 全部端口管脚均已核实（无 TODO）, 可立即综合/布线/下载
// 板级资源（来源: 走近FPGA 表1.1~1.6 + 核心板原理图 p2/p4, 全部已核实）:
//   clk=R7(50MHz)  rst_n_btn=E3(RSTn, 按下为低)  buzzer=H11(PNP, 低响)
//   矩阵键盘 行 E10/C10/F9/D9（输出扫描）, 列 E11/D11/C11/F10（输入, 上拉）
//   LED0~7 = B14/B15/B16/C15/C16/E13/E16/F16（高电平点亮）
//   数码管 段 A4/A6/B8/E8/A7/B5/A8/C8, 位选 C9/B6/A5/A3（段高亮, 位低选通）
// 上板可验证项:
//   1) 时钟与复位（数码管千位小数点 1Hz 闪烁 = 系统活着）
//   2) 4x4 矩阵键盘扫描 + 20ms 消抖（按键计数递增）
//   3) 数码管动态扫描（十进制按键计数 0000~9999）
//   4) LED 指示（高 4 位=最近键号, 低 4 位=计数个位）
//   5) 蜂鸣器提示音（每次按键短鸣）
// 未包含: 视频/HDMI/SD —— 依赖 MO 底板原理图核实（见 constraints 中 TODO 组）
// =============================================================================
`timescale 1ns / 1ps

module dmz_eg4s20_min_top (
    input  wire        clk,           // 50MHz, 球 R7
    input  wire        rst_n_btn,     // RSTn 按键, 球 E3, 低有效
    // 4x4 矩阵键盘
    output wire [3:0]  key_row,       // E10,C10,F9,D9（低电平扫描选通）
    input  wire [3:0]  key_col,       // E11,D11,C11,F10（上拉, 按下为低）
    // LED（高电平点亮）
    output wire [7:0]  led,           // B14,B15,B16,C15,C16,E13,E16,F16
    // 数码管（段高亮 / 位低选通）
    output wire [7:0]  seg_data,      // A4,A6,B8,E8,A7,B5,A8,C8
    output wire [3:0]  seg_cs,        // C9,B6,A5,A3
    // 蜂鸣器（低电平响）
    output wire        buzzer         // H11
);

    // -------------------------------------------------------------------------
    // 1. 矩阵键盘：扫描 + 消抖 + 按下事件
    // -------------------------------------------------------------------------
    wire        key_event;
    wire [3:0]  key_code;
    wire [15:0] key_state;

    key_matrix_4x4 #(
        .CLK_FREQ_HZ (50_000_000),
        .DEBOUNCE_MS (20)
    ) u_key (
        .clk       (clk),
        .rst_n     (rst_n_btn),
        .key_row   (key_row),
        .key_col   (key_col),
        .key_event (key_event),
        .key_code  (key_code),
        .key_state (key_state)
    );

    // -------------------------------------------------------------------------
    // 2. 按键计数（4 位 BCD, 0~9999）与最近键号
    //    用 BCD 计数器直接产生显示码, 免去二进制→BCD 转换逻辑
    // -------------------------------------------------------------------------
    reg [3:0] bcd3, bcd2, bcd1, bcd0;   // 千 百 十 个
    reg [3:0] last_key;

    always @(posedge clk or negedge rst_n_btn) begin
        if (!rst_n_btn) begin
            bcd3 <= 4'd0;
            bcd2 <= 4'd0;
            bcd1 <= 4'd0;
            bcd0 <= 4'd0;
            last_key <= 4'd0;
        end
        else if (key_event) begin
            last_key <= key_code;
            // BCD 递增（带进位）
            if (bcd0 != 4'd9) begin
                bcd0 <= bcd0 + 4'd1;
            end
            else begin
                bcd0 <= 4'd0;
                if (bcd1 != 4'd9) begin
                    bcd1 <= bcd1 + 4'd1;
                end
                else begin
                    bcd1 <= 4'd0;
                    if (bcd2 != 4'd9) begin
                        bcd2 <= bcd2 + 4'd1;
                    end
                    else begin
                        bcd2 <= 4'd0;
                        if (bcd3 != 4'd9)
                            bcd3 <= bcd3 + 4'd1;
                        else
                            bcd3 <= 4'd0;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. 1Hz 心跳（用于数码管千位小数点闪烁, 证明时钟/PLL 正常）
    // -------------------------------------------------------------------------
    reg [25:0] hb_cnt;
    reg        hb_flag;
    always @(posedge clk or negedge rst_n_btn) begin
        if (!rst_n_btn) begin
            hb_cnt  <= 26'd0;
            hb_flag <= 1'b0;
        end
        else if (hb_cnt >= 26'd24_999_999) begin   // 0.5s 翻转 → 1Hz 闪烁
            hb_cnt  <= 26'd0;
            hb_flag <= ~hb_flag;
        end
        else begin
            hb_cnt <= hb_cnt + 26'd1;
        end
    end

    // -------------------------------------------------------------------------
    // 4. 数码管显示: 千位(带心跳 DP) 百位 十位 个位 = 按键计数
    // -------------------------------------------------------------------------
    wire [6:0] seg3, seg2, seg1, seg0;
    seg_decoder u_dec3 (.bin_data (bcd3), .seg_data (seg3));
    seg_decoder u_dec2 (.bin_data (bcd2), .seg_data (seg2));
    seg_decoder u_dec1 (.bin_data (bcd1), .seg_data (seg1));
    seg_decoder u_dec0 (.bin_data (bcd0), .seg_data (seg0));

    seg_scan4 #(
        .CLK_FREQ_HZ (50_000_000),
        .SCAN_HZ     (1000)
    ) u_seg (
        .clk      (clk),
        .rst_n    (rst_n_btn),
        .dig0     ({1'b1, seg0}),        // 最右位: 个位（DP 灭）
        .dig1     ({1'b1, seg1}),        // 次右位: 十位
        .dig2     ({1'b1, seg2}),        // 次左位: 百位
        .dig3     ({~hb_flag, seg3}),    // 最左位: 千位（DP = 心跳, 低电平点亮）
        .seg_data (seg_data),
        .seg_cs   (seg_cs)
    );

    // -------------------------------------------------------------------------
    // 5. LED: 高 4 位 = 最近按键号, 低 4 位 = 计数个位
    // -------------------------------------------------------------------------
    assign led = {last_key, bcd0};

    // -------------------------------------------------------------------------
    // 6. 蜂鸣器: 每次按键短鸣 100ms（C5≈523Hz）
    // -------------------------------------------------------------------------
    buzzer_tone #(
        .CLK_FREQ_HZ (50_000_000)
    ) u_buzz (
        .clk        (clk),
        .rst_n      (rst_n_btn),
        .tone_sel   (2'd1),              // 按键音模式
        .trig       (key_event),
        .buzzer_out (buzzer)
    );

endmodule
