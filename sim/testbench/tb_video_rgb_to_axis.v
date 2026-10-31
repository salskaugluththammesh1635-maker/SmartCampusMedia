// =============================================================================
// tb_video_rgb_to_axis.v —— video_rgb_to_axis 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块的规格】
//   把 DVI 风格的 (de, vs, rgb) 翻译成 HDMI 1.4b 发射核要的 AXIS 视频流：
//     video_user  —— 帧起始，只在整个帧的第一个有效像素处拉高一拍
//     video_valid —— 等于 de（寄存一拍后直通）
//     video_last  —— 行尾，每行第 H_ACTIVE 个有效像素处拉高一拍
//     video_data  —— 24bit RGB（寄存一拍后直通）
//
// 【本 TB 要钉死的三条不变量】
//   1) user 每帧只出现一次，且必须落在"帧内第一行的第一个像素"，不是每个行首
//   2) last 必须精确落在第 H_ACTIVE-1 号像素（0 基），早一拍/晚一拍都会让
//      发射核等不到行尾，整帧对齐失败 —— 这是本模块最容易写错的地方
//   3) valid/data 与 de/rgb 同拍直通（寄存器直通，无额外节拍错位）
//
// 【为什么用 vs 翻转来定义"新的一帧"】
//   RTL 里 frame_arm 在复位时置 1，之后只有 vs 跳变才重新置 1。所以：
//     复位后第一个行首   → 发 user
//     同一帧后续行首     → 不发 user
//     vs 跳变后的行首     → 发 user
//   这三条就是"每帧一次"的全部含义，必须逐条验证。
//
// 【两个实例】
//   u_real  H_ACTIVE=640  按真实分辨率跑完整行，验证 640 的边界算术
//   u_small H_ACTIVE=8    小分辨率快速验证 (H_ACTIVE-1) 参数化是否正确
//     如果 RTL 里把 (H_ACTIVE - 1) 误写成 H_ACTIVE 或硬编码 639，
//     小实例会立刻暴露。
// =============================================================================
`timescale 1ns / 1ps

module tb_video_rgb_to_axis;

    // ---- 时钟（25MHz 像素时钟，周期 40ns）----------------------------------
    reg clk;
    initial clk = 1'b0;
    always #20 clk = ~clk;

    // ---- 主实例（H_ACTIVE=640）--------------------------------------------
    reg        rst_n;
    reg        vs_a;
    reg        de_a;
    reg [23:0] rgb_a;
    wire       user_a;
    wire       valid_a;
    wire       last_a;
    wire [23:0] data_a;

    video_rgb_to_axis #(.H_ACTIVE(640)) u_real (
        .clk         (clk),
        .rst_n       (rst_n),
        .vs          (vs_a),
        .de          (de_a),
        .rgb         (rgb_a),
        .video_user  (user_a),
        .video_valid (valid_a),
        .video_last  (last_a),
        .video_data  (data_a)
    );

    // ---- 小实例（H_ACTIVE=8）----------------------------------------------
    reg        vs_b;
    reg        de_b;
    reg [23:0] rgb_b;
    wire       user_b;
    wire       valid_b;
    wire       last_b;
    wire [23:0] data_b;

    video_rgb_to_axis #(.H_ACTIVE(8)) u_small (
        .clk         (clk),
        .rst_n       (rst_n),
        .vs          (vs_b),
        .de          (de_b),
        .rgb         (rgb_b),
        .video_user  (user_b),
        .video_valid (valid_b),
        .video_last  (last_b),
        .video_data  (data_b)
    );

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    task ck(input integer cond, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    // 带数值的失败信息，便于定位（只在失败时打印细节）
    task ck_eq(input integer got, input integer exp, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s  (got %0d, expected %0d)", label, got, exp);
            end
        end
    endtask

    task ck_data(input [23:0] got, input [23:0] exp, input [8*100-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s  (got %h, expected %h)", label, got, exp);
            end
        end
    endtask

    // ---- 驱动一拍：在下降沿给输入，在上升沿采输出 --------------------------
    //   RTL 用 posedge clk 采样，所以下降沿改输入、上升沿后 #1 观察，
    //   观察到的正是"本拍输入经过寄存器后的结果"，不受竞争影响。
    task px_real(input d, input [23:0] c);
        begin
            @(negedge clk);
            de_a  = d;
            rgb_a = c;
            @(posedge clk);
            #1;
        end
    endtask

    task px_small(input d, input [23:0] c);
        begin
            @(negedge clk);
            de_b  = d;
            rgb_b = c;
            @(posedge clk);
            #1;
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    integer user_cnt;
    integer last_cnt;
    reg [23:0] expect_rgb;

    initial begin
        $display("=== tb_video_rgb_to_axis start ===");

        // 初值
        rst_n = 1'b0;
        vs_a  = 1'b1;
        de_a  = 1'b0;
        rgb_a = 24'h000000;
        vs_b  = 1'b1;
        de_b  = 1'b0;
        rgb_b = 24'h000000;

        // =====================================================================
        // ① 复位保持：所有输出必须清干净
        // =====================================================================
        repeat (4) @(posedge clk);
        #1;
        ck(user_a  === 1'b0,          "[reset] video_user cleared");
        ck(valid_a === 1'b0,          "[reset] video_valid cleared");
        ck(last_a  === 1'b0,          "[reset] video_last cleared");
        ck_data(data_a, 24'h000000,   "[reset] video_data cleared");
        ck(user_b  === 1'b0,          "[reset] small instance user cleared");
        ck(last_b  === 1'b0,          "[reset] small instance last cleared");

        @(negedge clk);
        rst_n = 1'b1;

        // =====================================================================
        // ② 消隐期间：valid 必须严格跟随 de=0
        // =====================================================================
        px_real(1'b0, 24'h123456);
        ck(valid_a === 1'b0,          "[blank] valid low while de low");
        ck(user_a  === 1'b0,          "[blank] no user in blanking");
        ck(last_a  === 1'b0,          "[blank] no last in blanking");
        px_real(1'b0, 24'hABCDEF);
        ck(valid_a === 1'b0,          "[blank] valid stays low");

        // =====================================================================
        // ③ 复位后第一行：user 只在第 0 号像素出现一次
        //    RTL 复位时 frame_arm=1，所以不需要 vs 跳变就该发 user
        // =====================================================================
        px_real(1'b1, 24'hFF0000);
        ck(user_a  === 1'b1,          "[row0] user on first pixel after reset");
        ck(valid_a === 1'b1,          "[row0] valid high with de");
        ck(last_a  === 1'b0,          "[row0] no last on first pixel");
        ck_data(data_a, 24'hFF0000,   "[row0] data passthrough on first pixel");

        user_cnt = 1;   // 已计第 0 号像素的 user
        last_cnt = 0;

        // 第 1..638 号像素：既不能有 user，也不能有 last
        // 中间抽查几个点的数据直通
        for (i = 1; i < 639; i = i + 1) begin
            expect_rgb = {i[7:0], i[15:8], 8'h5A};
            px_real(1'b1, expect_rgb);
            if (user_a === 1'b1) user_cnt = user_cnt + 1;
            if (last_a === 1'b1) last_cnt = last_cnt + 1;
            // 抽查：第 1、第 320、第 638 号像素
            if (i == 1)   ck_data(data_a, expect_rgb, "[row0] data passthrough px1");
            if (i == 320) ck_data(data_a, expect_rgb, "[row0] data passthrough px320");
            if (i == 638) begin
                ck_data(data_a, expect_rgb, "[row0] data passthrough px638");
                ck(last_a === 1'b0, "[row0] no last on px638 (one cycle early)");
            end
        end

        // 第 639 号像素：必须发 last
        px_real(1'b1, 24'h00FF00);
        ck(last_a  === 1'b1,          "[row0] last on px639 (H_ACTIVE-1)");
        ck(user_a  === 1'b0,          "[row0] no user on px639");
        ck_data(data_a, 24'h00FF00,   "[row0] data passthrough px639");
        if (user_a === 1'b1) user_cnt = user_cnt + 1;
        last_cnt = last_cnt + 1;

        ck_eq(user_cnt, 1,            "[row0] exactly one user pulse in row");
        ck_eq(last_cnt, 1,            "[row0] exactly one last pulse in row");

        // =====================================================================
        // ④ 同一帧的第二行：绝不能有 user（frame_arm 已被清掉）
        // =====================================================================
        px_real(1'b0, 24'h000000);
        ck(valid_a === 1'b0,          "[row1] valid low in row gap");
        ck(last_a  === 1'b0,          "[row1] last cleared in row gap");
        ck(user_a  === 1'b0,          "[row1] user cleared in row gap");

        px_real(1'b1, 24'h00FFFF);
        ck(user_a  === 1'b0,          "[row1] NO user on second row of same frame");
        ck(valid_a === 1'b1,          "[row1] valid high");
        ck_data(data_a, 24'h00FFFF,   "[row1] data passthrough");

        user_cnt = 0;
        last_cnt = 0;
        for (i = 1; i < 639; i = i + 1) begin
            px_real(1'b1, {i[7:0], 8'h00, i[15:8]});
            if (user_a === 1'b1) user_cnt = user_cnt + 1;
            if (last_a === 1'b1) last_cnt = last_cnt + 1;
        end
        px_real(1'b1, 24'h0000FF);
        ck(last_a === 1'b1,           "[row1] last on px639");
        ck_eq(user_cnt, 0,            "[row1] zero user pulses across whole row");

        // =====================================================================
        // ⑤ vs 跳变后：新一帧的第一行必须重新发 user
        // =====================================================================
        px_real(1'b0, 24'h000000);
        @(negedge clk);
        vs_a = 1'b0;                    // 场同步跳变
        @(posedge clk);
        #1;
        px_real(1'b0, 24'h000000);      // 再等一拍让 frame_arm 稳定置位
        ck(user_a === 1'b0, "[vs] no user in blanking after vs toggle");

        px_real(1'b1, 24'h777777);
        ck(user_a === 1'b1, "[vs] user fires again on first pixel of new frame");
        ck_data(data_a, 24'h777777, "[vs] data passthrough on new frame first pixel");

        // 这一帧的第二个行首仍然不能有 user
        px_real(1'b0, 24'h000000);
        px_real(1'b1, 24'h888888);
        ck(user_a === 1'b0, "[vs] second row of new frame still has no user");

        // =====================================================================
        // ⑥ vs 只跳变一次就足够：连续帧都各自发一次 user
        // =====================================================================
        px_real(1'b0, 24'h000000);
        @(negedge clk);
        vs_a = 1'b1;                    // 再翻回去
        @(posedge clk);
        #1;
        px_real(1'b0, 24'h000000);
        px_real(1'b1, 24'h999999);
        ck(user_a === 1'b1, "[vs] user fires on frame after second vs toggle");

        // =====================================================================
        // ⑦ 短行（提前拉低 de）：last 不能出现，且下一行要重新从 0 计起
        //    这条专门验证 x_cnt 在消隐期确实被清零
        // =====================================================================
        px_real(1'b0, 24'h000000);
        px_real(1'b0, 24'h000000);
        user_cnt = 0;
        for (i = 0; i < 300; i = i + 1) begin
            px_real(1'b1, 24'h111111);
            if (last_a === 1'b1) user_cnt = user_cnt + 1;
        end
        ck_eq(user_cnt, 0, "[short] no last pulse in a 300-pixel short row");

        px_real(1'b0, 24'h000000);      // 回到消隐
        px_real(1'b0, 24'h000000);

        // 下一行是完整 640 像素：last 仍然必须精确落在第 639 号
        last_cnt = 0;
        user_cnt = 0;
        for (i = 0; i < 639; i = i + 1) begin
            px_real(1'b1, 24'h222222);
            if (last_a === 1'b1) last_cnt = last_cnt + 1;
            if (user_a === 1'b1) user_cnt = user_cnt + 1;
        end
        ck_eq(last_cnt, 0, "[short] x_cnt restarted: no early last after short row");
        ck_eq(user_cnt, 0, "[short] no spurious user on this row");
        px_real(1'b1, 24'h333333);
        ck(last_a === 1'b1, "[short] last still lands exactly on px639");

        // =====================================================================
        // ⑧ 小实例 H_ACTIVE=8：验证 (H_ACTIVE-1) 的参数化
        //    若 RTL 误写成硬编码 639，这里第 7 号像素不会出 last
        // =====================================================================
        // 小实例同样在复位后第一拍就该发 user（frame_arm=1）
        user_cnt = 0;
        last_cnt = 0;
        for (i = 0; i < 8; i = i + 1) begin
            px_small(1'b1, {8'hA0, 8'hB0, i[7:0]});
            if (user_b === 1'b1) user_cnt = user_cnt + 1;
            if (last_b === 1'b1) last_cnt = last_cnt + 1;
            if (i == 0) ck(user_b === 1'b1, "[small] user on px0 of 8-pixel row");
            if (i == 6) ck(last_b === 1'b0, "[small] no last on px6");
            if (i == 7) ck(last_b === 1'b1, "[small] last on px7 (H_ACTIVE-1=7)");
        end
        ck_eq(last_cnt, 1, "[small] exactly one last pulse in an 8-pixel row");
        ck_eq(user_cnt, 1, "[small] exactly one user pulse in first row");

        // 小实例第二行：无 user，last 仍在第 7 号
        px_small(1'b0, 24'h000000);
        px_small(1'b1, 24'hC0C0C0);
        ck(user_b === 1'b0, "[small] no user on second row");
        for (i = 1; i < 8; i = i + 1) px_small(1'b1, 24'hC0C0C0);
        ck(last_b === 1'b1, "[small] last on px7 of second row");
        ck_data(data_b, 24'hC0C0C0, "[small] data passthrough");

        // =====================================================================
        // ⑨ 运行中复位：输出必须立刻清零
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        ck(user_a  === 1'b0, "[mid-reset] user cleared");
        ck(valid_a === 1'b0, "[mid-reset] valid cleared");
        ck(last_a  === 1'b0, "[mid-reset] last cleared");
        ck_data(data_a, 24'h000000, "[mid-reset] data cleared");

        // 复位释放后 user 应该再次出现（frame_arm 被复位重新置 1）
        // 注意：这里必须先把 de 拉回 0 再释放复位 —— 真实系统里复位释放总是
        // 发生在消隐期。若 de 在复位期间一直是高电平，释放后的第一拍就会立刻
        // 消费掉 frame_arm，此后即便再出现 0→1 的 de 上升沿也不会发 user。
        @(negedge clk);
        de_a  = 1'b0;
        rst_n = 1'b1;
        px_real(1'b0, 24'h000000);
        px_real(1'b1, 24'hF0F0F0);
        ck(user_a === 1'b1, "[resume] user fires after reset release");
        ck_data(data_a, 24'hF0F0F0, "[resume] data passthrough");

        // =====================================================================
        // 汇总
        // =====================================================================
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: video_rgb_to_axis");
        else             $display("CHECKS FAILED: video_rgb_to_axis");
        $finish;
    end

endmodule
