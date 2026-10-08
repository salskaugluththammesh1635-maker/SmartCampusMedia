// =============================================================================
// tb_seg_scan4.v — 4 位数码管动态扫描单元测试（快速, 无视频干扰）
// 背景: 原实现存在"阻塞/非阻塞混用"缺陷 —— seg_cs <= 4'b1111 会在时间步末
//       覆盖掉 seg_cs[0] = 1'b0 的效果, 导致位选恒为 4'b1111（数码管全灭）。
//       安路 TD 综合器直接报 ERROR 才暴露此问题。本 TB 用于锁死该缺陷。
// 验证项:
//   C1 位选任一刻只有 1 位为低（独热低）, 且四种状态都出现
//   C2 每位对应的段码与该位输入一致（seg_data 与 seg_cs 同拍）
//   C3 扫描节拍正确（每位约 250us, 整轮约 1ms）
// 运行: vsim -c -do "run -all" work.tb_seg_scan4
// =============================================================================
`timescale 1ns / 1ps

module tb_seg_scan4;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50MHz

    reg  rst_n = 1'b0;

    // 4 个可区分的段码
    localparam [7:0] D0 = 8'h11;
    localparam [7:0] D1 = 8'h22;
    localparam [7:0] D2 = 8'h44;
    localparam [7:0] D3 = 8'h88;

    wire [7:0] seg_data;
    wire [3:0] seg_cs;

    seg_scan4 #(
        .CLK_FREQ_HZ (50_000_000),
        .SCAN_HZ     (1000)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .dig0     (D0),                 // 最右位
        .dig1     (D1),
        .dig2     (D2),
        .dig3     (D3),                 // 最左位
        .seg_data (seg_data),
        .seg_cs   (seg_cs)
    );

    integer errors = 0;

    // ---- 统计与采样 ----
    integer cnt0 = 0, cnt1 = 0, cnt2 = 0, cnt3 = 0, cnt_none = 0, cnt_multi = 0;
    reg [7:0] got0 = 8'h00, got1 = 8'h00, got2 = 8'h00, got3 = 8'h00;

    always @(posedge clk) begin
        if (rst_n) begin
            case (seg_cs)
                4'b1110: begin cnt0 = cnt0 + 1; got0 = seg_data; end   // COM0 最右
                4'b1101: begin cnt1 = cnt1 + 1; got1 = seg_data; end
                4'b1011: begin cnt2 = cnt2 + 1; got2 = seg_data; end
                4'b0111: begin cnt3 = cnt3 + 1; got3 = seg_data; end
                4'b1111: cnt_none = cnt_none + 1;                       // 全不选通
                default: cnt_multi = cnt_multi + 1;                     // 多位同时选通 → 错误
            endcase
        end
    end

    // ---- 任务: 检查与报告 ----
    task chk;
        input cond;
        input [255:0] tag;
        begin
            if (cond) begin
                $display("[PASS] %0s", tag);
            end
            else begin
                errors = errors + 1;
                $display("[FAIL] %0s", tag);
            end
        end
    endtask

    initial begin
        $display("=== tb_seg_scan4 start ===");
        #1000;
        rst_n = 1'b1;
        $display("[%0t] reset released", $time);

        // 观察 5ms（覆盖约 5 个完整扫描轮: 每位 250us, 一轮 1ms）
        #5_000_000;

        $display("--- 统计（5ms 窗口）---");
        $display("  COM0(1110) 计数=%0d 段码=%02h (期望 %02h)", cnt0, got0, D0);
        $display("  COM1(1101) 计数=%0d 段码=%02h (期望 %02h)", cnt1, got1, D1);
        $display("  COM2(1011) 计数=%0d 段码=%02h (期望 %02h)", cnt2, got2, D2);
        $display("  COM3(0111) 计数=%0d 段码=%02h (期望 %02h)", cnt3, got3, D3);
        $display("  全不选通(1111) 计数=%0d", cnt_none);
        $display("  多位同时选通 计数=%0d", cnt_multi);

        // C1: 独热低 + 四种状态均出现
        chk(cnt_multi == 0, "C1a 位选始终独热低（无多位同时选通）");
        chk((cnt0 > 0) && (cnt1 > 0) && (cnt2 > 0) && (cnt3 > 0), "C1b 四个位选状态均出现");

        // C2: 段码与位对应
        chk(got0 === D0, "C2a COM0 段码 = dig0");
        chk(got1 === D1, "C2b COM1 段码 = dig1");
        chk(got2 === D2, "C2c COM2 段码 = dig2");
        chk(got3 === D3, "C2d COM3 段码 = dig3");

        // C3: 每位的占空比约 1/4（各计数接近相等）
        chk((cnt0 > 50000) && (cnt0 < 70000), "C3a COM0 计数在 50k~70k（约 1ms/4 窗口）");
        chk((cnt1 > 50000) && (cnt1 < 70000), "C3b COM1 计数在 50k~70k");
        chk((cnt2 > 50000) && (cnt2 < 70000), "C3c COM2 计数在 50k~70k");
        chk((cnt3 > 50000) && (cnt3 < 70000), "C3d COM3 计数在 50k~70k");

        $display("=== tb_seg_scan4 done, errors = %0d ===", errors);
        if (errors == 0)
            $display("*** ALL CHECKS PASSED ***");
        else
            $display("*** CHECKS FAILED ***");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[FAIL] 全局超时 errors=%0d", errors);
        $finish;
    end

endmodule
