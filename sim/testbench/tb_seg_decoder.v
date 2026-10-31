// =============================================================================
// tb_seg_decoder.v —— 七段数码管段码译码器（seg_decoder）自检测试平台
// -----------------------------------------------------------------------------
// 【被评测对象】
//   rtl/common/seg_decoder.v：4 位十六进制数 → 7 段段码，【高电平点亮】。
//   段位约定 seg_data[6:0] = {g, f, e, d, c, b, a}。
//
// 【为什么这个模块必须单独测】
//   它是全链路最末端、最容易被忽略的一级，而且在 2026-10-17 上板时因
//   "高/低电平点亮"搞反导致显示全错（想显示 0 却只有 g 段亮）。
//   这类极性错误在仿真里 100% 可抓——前提是判据要逐段比对、不能只看"非零"。
//   因此本平台对 0~F 全部 16 个输入逐段与期望段码严格比对（=== 全员四态比较），
//   并额外验证"每个段码的位数与极性"这两个易错点。
//
// 【判据设计】
//   1) 真值表：16 个数码值逐一比对完整 7 位段码。
//   2) 段位分解：把期望段码拆成 a..g 七个 bool，逐个与 seg_data 的对应位比对。
//      —— 这样即使整体段码写对而位序（{g..a} 与 {a..g}）写反，也会被抓到，
//         因为位序写反时"显示 1"会变成 b、c 段的高低位互换。
//   3) 极性 sanity：0 的段码必须是 7'b011_1111（只有 g 灭）。
//      —— 这一条直接钉死"高电平点亮"这一历史坑。
//   4) 未定义输入（虽然 bin_data 只有 4 位，16 个值已全覆盖）：default 分支
//      永远走不到，因此不造用例，改为在注释里说明。
//
// 【覆盖说明】
//   bin_data 是 4 位，取值空间只有 16 个，本平台 16 个全部跑到 → 分支覆盖率 100%。
// =============================================================================
`timescale 1ns / 1ps

module tb_seg_decoder;

    // ---- 接口 --------------------------------------------------------------
    reg  [3:0] bin_data;
    wire [6:0] seg_data;

    seg_decoder u_dut (
        .bin_data (bin_data),
        .seg_data (seg_data)
    );

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    // ---- 期望段码表（与设计文档一致：高电平点亮，{g,f,e,d,c,b,a}）----------
    function [6:0] exp_seg;
        input [3:0] v;
        begin
            case (v)
                4'h0: exp_seg = 7'b011_1111;
                4'h1: exp_seg = 7'b000_0110;
                4'h2: exp_seg = 7'b101_1011;
                4'h3: exp_seg = 7'b100_1111;
                4'h4: exp_seg = 7'b110_0110;
                4'h5: exp_seg = 7'b110_1101;
                4'h6: exp_seg = 7'b111_1101;
                4'h7: exp_seg = 7'b000_0111;
                4'h8: exp_seg = 7'b111_1111;
                4'h9: exp_seg = 7'b110_1111;
                4'hA: exp_seg = 7'b111_0111;
                4'hB: exp_seg = 7'b111_1100;
                4'hC: exp_seg = 7'b011_1001;
                4'hD: exp_seg = 7'b101_1110;
                4'hE: exp_seg = 7'b111_1001;
                4'hF: exp_seg = 7'b111_0001;
                default: exp_seg = 7'b000_0000;
            endcase
        end
    endfunction

    // ---- 通用任务 ----------------------------------------------------------
    // 完整段码比对（四态严格比较）
    task expect_seg;
        input [3:0] v;
        reg   [6:0] e;
        begin
            bin_data = v;
            #1;
            e = exp_seg(v);
            checks = checks + 1;
            if (seg_data === e) begin
                $display("PASS: [truth-table] bin=%h seg=%b", v, seg_data);
            end else begin
                errors = errors + 1;
                $display("FAIL: [truth-table] bin=%h seg=%b expected=%b",
                         v, seg_data, e);
            end
        end
    endtask

    // 逐段（a..g）分解比对：抓位序错误
    task expect_per_segment;
        input [3:0] v;
        reg   [6:0] e;
        integer k;
        reg     ok;
        begin
            bin_data = v;
            #1;
            e  = exp_seg(v);
            ok = 1'b1;
            for (k = 0; k < 7; k = k + 1)
                if (seg_data[k] !== e[k]) ok = 1'b0;

            checks = checks + 1;
            if (ok) begin
                $display("PASS: [per-segment] bin=%h a..g=%b matches", v, seg_data);
            end else begin
                errors = errors + 1;
                $display("FAIL: [per-segment] bin=%h got=%b exp=%b", v, seg_data, e);
            end

            // 单独点名 g 段（bit6）：0 必须灭、8 必须亮——极性最容易错的两点
            checks = checks + 1;
            if (seg_data[6] === e[6]) begin
                $display("PASS: [segment-g] bin=%h g=%b", v, seg_data[6]);
            end else begin
                errors = errors + 1;
                $display("FAIL: [segment-g] bin=%h g=%b expected=%b",
                         v, seg_data[6], e[6]);
            end
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer v;

    initial begin
        $display("=== tb_seg_decoder : 7-segment decoder (active high) ===");

        bin_data = 4'h0;
        #1;

        // 1) 真值表全覆盖（16/16 输入空间）
        for (v = 0; v < 16; v = v + 1) expect_seg(v[3:0]);

        // 2) 逐段分解 + g 段极性
        for (v = 0; v < 16; v = v + 1) expect_per_segment(v[3:0]);

        // 3) 极性钉子：0 只有 g 灭（7'b011_1111），8 全亮（7'b111_1111）
        //    若把"高电平点亮"写成"低电平点亮"，这两条会立刻翻车
        bin_data = 4'h0; #1;
        checks = checks + 1;
        if (seg_data === 7'b011_1111) begin
            $display("PASS: [polarity] digit 0 lights a~f only, g off");
        end else begin
            errors = errors + 1;
            $display("FAIL: [polarity] digit 0 seg=%b expected=0111111", seg_data);
        end

        bin_data = 4'h8; #1;
        checks = checks + 1;
        if (seg_data === 7'b111_1111) begin
            $display("PASS: [polarity] digit 8 lights all seven segments");
        end else begin
            errors = errors + 1;
            $display("FAIL: [polarity] digit 8 seg=%b expected=1111111", seg_data);
        end

        // 4) 组合逻辑特性：无时钟依赖，输入回退后输出必须立刻跟随
        //    （防 latch —— 若有 latch，回到旧值时会保持住）
        bin_data = 4'h3; #1;
        bin_data = 4'hC; #1;
        checks = checks + 1;
        if (seg_data === 7'b011_1001) begin
            $display("PASS: [combinational] output tracks input without clock");
        end else begin
            errors = errors + 1;
            $display("FAIL: [combinational] seg=%b expected=0111001", seg_data);
        end

        // 5) 收尾
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: seg_decoder");
        else             $display("CHECKS FAILED: seg_decoder");
        $finish;
    end

endmodule
