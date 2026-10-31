// =============================================================================
// tb_audio_arc.v —— audio_arc 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块的规格】
//   生成 HDMI 音频时钟再生包（ACR）的 CTS / N 参数对。接收端用它们从 TMDS
//   时钟还原出 48 kHz：
//       f_audio = f_pixel * N / (128 * CTS)
//
//   两个计数器分工完全不同，这是本模块最容易被误解的地方：
//     div_cnt —— 只在 audio_valid 时自增，数到 AUDIO_DIV-1 产生 div_tick
//                （= 每 AUDIO_DIV 个音频样本发一次 ACR 包）
//     cts_cnt —— **无论 audio_valid 是高是低，每个时钟都自增**
//                （= 用像素时钟"测量"真实经过的时间，这才是 CTS 的语义）
//
// 【本 TB 要钉死的五条不变量】
//   1) acr_n 恒等于 ACR_N 参数（HDMI 规范对 48kHz 家族固定 6144）
//   2) acr_valid 严格每 AUDIO_DIV 个音频样本出现一次，且只有 1 拍宽
//   3) **acr_cts 必须等于"两次 ACR 包之间经过的像素时钟数"**
//      —— 这一条直接验证 cts_cnt 在 audio_valid=0 期间也在计数。
//         若有人把 cts_cnt 误写进 audio_valid 分支，本条立刻失败。
//   4) audio_valid 无效期间不能产生 acr_valid，且 div_cnt 进度不能丢
//   5) 复位把 cts_cnt/div_cnt 归零、acr_n 复位为 ACR_N
//
// 【两个实例的用意】
//   u_real  ACR_N=6144 → AUDIO_DIV=48  按真实参数跑，验证 48 的节拍
//   u_fast  ACR_N=128  → AUDIO_DIV=1   退化为"每个样本都发包"，
//     这能验证 div_tick 的比较边界（div_cnt == AUDIO_DIV-1 = 0）没写错：
//     若误写成 AUDIO_DIV，u_fast 会变成每 2 个样本发一次，立刻暴露。
//
// 【监视器为什么在 negedge 采样】
//   DUT 用 posedge 寄存，TB 若也在 posedge 读输出，读到的是"更新前"的旧值，
//   所有计数都会晚一拍、导致满屏假失败。改到 negedge 采样，读到的是本拍
//   posedge 更新后的稳定值，计数与 DUT 状态严格同拍对齐。
// =============================================================================
`timescale 1ns / 1ps

module tb_audio_arc;

    localparam ACR_N_REAL = 6144;
    localparam ACR_N_FAST = 128;
    localparam DIV_REAL   = 48;      // ACR_N_REAL >> 7
    localparam DIV_FAST   = 1;       // ACR_N_FAST >> 7

    // ---- 时钟（25MHz 像素时钟）--------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #20 clk = ~clk;

    // ---- 主实例（真实参数）-------------------------------------------------
    reg         rst_n;
    reg         audio_valid;
    wire        acr_valid;
    wire [19:0] acr_cts;
    wire [19:0] acr_n;

    audio_arc #(.ACR_N(ACR_N_REAL)) u_real (
        .clk         (clk),
        .rst_n       (rst_n),
        .audio_valid (audio_valid),
        .acr_valid   (acr_valid),
        .acr_cts     (acr_cts),
        .acr_n       (acr_n)
    );

    // ---- 快速实例（AUDIO_DIV=1）-------------------------------------------
    reg         audio_valid_f;
    wire        acr_valid_f;
    wire [19:0] acr_cts_f;
    wire [19:0] acr_n_f;

    audio_arc #(.ACR_N(ACR_N_FAST)) u_fast (
        .clk         (clk),
        .rst_n       (rst_n),
        .audio_valid (audio_valid_f),
        .acr_valid   (acr_valid_f),
        .acr_cts     (acr_cts_f),
        .acr_n       (acr_n_f)
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

    // ---- 监视器（negedge 采样，与 DUT 状态同拍对齐）------------------------
    integer clk_cyc;         // 全局时钟计数（negedge 递增）
    integer pkt_cnt;         // 包总数
    integer pkt_width;       // 最近一次 acr_valid 脉冲宽度
    integer acr_run;         // 当前脉冲已连续为高的拍数
    reg     acr_d;           // 上一拍 acr_valid
    integer last_cts;        // 最近一个包的 acr_cts
    integer pkt_cyc;         // 最近一个包发生的时钟号
    integer pkt_gap;         // 最近两个包之间的时钟数
    integer cts_mismatch;    // acr_cts 与实测间隔不符的次数

    // 快实例（u_fast）需要独立的一套统计 —— 两个实例的输出互不相干
    integer pkt_cnt_f;
    integer pkt_width_f;
    integer last_cts_f;
    integer acr_run_f;
    reg     acr_d_f;

    always @(negedge clk) begin
        clk_cyc = clk_cyc + 1;
        if (!rst_n) begin
            acr_d   = acr_valid;
            acr_run = 0;
            acr_d_f   = acr_valid_f;
            acr_run_f = 0;
        end else begin
            // ---- 主实例 ----
            if (acr_valid === 1'b1 && acr_d !== 1'b1) begin
                pkt_cnt  = pkt_cnt + 1;
                acr_run  = 1;
                last_cts = acr_cts;
                if (pkt_cnt > 1) begin
                    pkt_gap = clk_cyc - pkt_cyc;
                    // CTS 语义：acr_cts 必须等于两个包之间的时钟数
                    if (acr_cts !== pkt_gap) cts_mismatch = cts_mismatch + 1;
                end
                pkt_cyc = clk_cyc;
            end else begin
                if (acr_run > 0) pkt_width = acr_run;
                acr_run = 0;
            end
            acr_d = acr_valid;

            // ---- 快实例 ----
            if (acr_valid_f === 1'b1 && acr_d_f !== 1'b1) begin
                pkt_cnt_f  = pkt_cnt_f + 1;
                acr_run_f  = 1;
                last_cts_f = acr_cts_f;
            end else begin
                if (acr_run_f > 0) pkt_width_f = acr_run_f;
                acr_run_f = 0;
            end
            acr_d_f = acr_valid_f;
        end
    end

    task clr_stats;
        begin
            pkt_cnt = 0; pkt_width = 0; acr_run = 0;
            last_cts = 0; pkt_gap = 0; cts_mismatch = 0;
            pkt_cyc = clk_cyc;
            pkt_cnt_f = 0; pkt_width_f = 0; acr_run_f = 0; last_cts_f = 0;
        end
    endtask

    // 给 n 个连续 audio_valid 样本（每拍一个）
    task feed_n(input integer n);
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin
                @(negedge clk); audio_valid = 1'b1;
                @(posedge clk);
            end
        end
    endtask

    // 把 div_cnt 对齐到已知状态（=0）。
    //   注意：不能简单地"喂满 DIV_REAL 个样本"就以为对齐了 —— 若起点不是 0，
    //   喂 48 个样本后会停在"起点偏移"上，是平移而不是归零。正确做法是
    //   **一直喂到看见一个包**：div_tick 那拍 div_cnt 必然被复位成 0。
    task feed_until_packet;
        integer guard;
        begin
            if (audio_valid !== 1'b1) begin
                @(negedge clk); audio_valid = 1'b1;
            end
            guard = 0;
            while (guard < (2*DIV_REAL + 4)) begin
                @(posedge clk);
                guard = guard + 1;
                @(negedge clk);
                if (acr_valid === 1'b1) guard = 2*DIV_REAL + 4;  // 见到包即退出
            end
            audio_valid = 1'b0;
            repeat (2) @(posedge clk);   // 让 acr_valid 回落、监视器更新 acr_d
        end
    endtask

    // 稀疏一轮：DIV_REAL 个样本，样本间隔恰好 8 个时钟（模拟 48kHz 远低于 25MHz）
    task sparse_round;
        integer t;
        begin
            for (t = 0; t < DIV_REAL; t = t + 1) begin
                @(negedge clk); audio_valid = 1'b1;
                @(posedge clk);
                @(negedge clk); audio_valid = 1'b0;
                repeat (7) @(posedge clk);
            end
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    integer guard;

    initial begin
        $display("=== tb_audio_arc start (DIV_REAL=%0d DIV_FAST=%0d) ===",
                 DIV_REAL, DIV_FAST);
        clk_cyc       = 0;
        clr_stats();
        rst_n         = 1'b0;
        audio_valid   = 1'b0;
        audio_valid_f = 1'b0;

        // =====================================================================
        // ① 复位值
        // =====================================================================
        repeat (5) @(posedge clk);
        #1;
        ck(acr_valid === 1'b0,              "[reset] acr_valid low");
        ck_eq(acr_cts, 20'd0,               "[reset] acr_cts cleared");
        ck_eq(acr_n,   ACR_N_REAL,          "[reset] acr_n = ACR_N (6144)");
        ck_eq(acr_n_f, ACR_N_FAST,          "[reset] fast instance acr_n = 128");
        ck(acr_valid_f === 1'b0,            "[reset] fast instance acr_valid low");

        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        clr_stats();

        // =====================================================================
        // ② 空闲期（audio_valid 恒 0）：绝不能发包
        // =====================================================================
        repeat (500) @(posedge clk);
        #1;
        ck_eq(pkt_cnt, 0,                   "[idle] no ACR packet while audio_valid=0");
        ck(acr_valid === 1'b0,              "[idle] acr_valid stays low");

        // =====================================================================
        // ③ 逐拍给 audio_valid：第 DIV_REAL 个样本才出现第一个包
        //    div_cnt 从 0 起，div_tick 条件是 div_cnt == DIV_REAL-1 = 47，
        //    所以第 48 个 audio_valid 才是第一个包。
        // =====================================================================
        clr_stats();
        for (i = 1; i <= DIV_REAL - 1; i = i + 1) begin
            @(negedge clk); audio_valid = 1'b1;
            @(posedge clk); #1;
            if (i == 1)  ck_eq(pkt_cnt, 0, "[div] no packet on 1st audio sample");
            if (i == 24) ck_eq(pkt_cnt, 0, "[div] no packet at sample 24");
            if (i == 47) ck_eq(pkt_cnt, 0, "[div] no packet at sample 47 (one early)");
        end
        // 第 48 个样本
        @(negedge clk); audio_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);   // 让监视器看到并记账
        ck_eq(pkt_cnt, 1,                   "[div] first packet exactly on sample 48");
        ck_eq(acr_n, ACR_N_REAL,            "[div] acr_n = 6144 in packet");
        ck(acr_valid === 1'b1,              "[div] acr_valid high on packet cycle");

        // 再走两轮，确认节拍稳定（包间隔 48 拍 → acr_cts=48）
        clr_stats();
        for (i = 0; i < DIV_REAL * 3; i = i + 1) begin
            @(negedge clk); audio_valid = 1'b1;
            @(posedge clk);
        end
        @(negedge clk); audio_valid = 1'b0;
        repeat (3) @(posedge clk);
        ck_eq(pkt_cnt, 3,                   "[div] 3 packets in 144 continuous samples");
        ck_eq(last_cts, DIV_REAL,           "[cts] acr_cts = 48 when packets are back-to-back");
        ck_eq(pkt_width, 1,                 "[div] acr_valid pulse is 1 cycle wide");
        ck_eq(cts_mismatch, 0,              "[cts] acr_cts matches measured packet gap");

        // =====================================================================
        // ④ 暂停 audio_valid：期间不得发包，且 div_cnt 进度必须保留
        //    先给 47 个样本（差 1 个就发包），再长时间空闲，
        //    然后补最后 1 个样本 → 应立刻发包。这证明 div_cnt 只在
        //    audio_valid 时自增，空闲期不会把进度冲掉。
        // =====================================================================
        feed_until_packet;
        clr_stats();
        for (i = 0; i < DIV_REAL - 1; i = i + 1) begin
            @(negedge clk); audio_valid = 1'b1;
            @(posedge clk);
        end
        @(negedge clk); audio_valid = 1'b0;
        ck_eq(pkt_cnt, 0,                   "[pause] no packet after 47 samples");
        repeat (200) @(posedge clk);
        #1;
        ck_eq(pkt_cnt, 0,                   "[pause] no packet during 200 idle cycles");
        // 补最后 1 个样本 → 立即发包（进度没被空闲期冲掉）
        @(negedge clk); audio_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        ck_eq(pkt_cnt, 1,                   "[pause] div_cnt progress preserved across idle");

        // =====================================================================
        // ⑤ CTS 语义：稀疏 audio_valid（模拟 48kHz 远低于像素时钟）
        //    每 8 拍才来一个 audio_valid，则 48 个样本横跨约 380 拍，
        //    acr_cts 必须同量级（而不是 48）—— 这是"用像素时钟测量"的核心证据。
        //    acr_cts 的绝对值含一段固定偏移（对齐点到第一个样本的空闲拍数），
        //    所以用区间判据；精确一致性由 cts_mismatch（acr_cts === 实测包间隔）钉死。
        // =====================================================================
        feed_until_packet;                       // div_cnt 归 0
        clr_stats();
        sparse_round;
        guard = 0;
        while (pkt_cnt < 1 && guard < 100) begin @(negedge clk); guard = guard + 1; end
        ck_eq(pkt_cnt, 1,                   "[cts] sparse round produced exactly one packet");
        ck(last_cts > 300,                  "[cts] acr_cts far above 48 under sparse audio_valid");
        ck(last_cts >= 340 && last_cts <= 400,
                                            "[cts] acr_cts in 48-samples-over-8-clock-gaps range");

        // 再跑一轮稀疏，验证包间隔的周期性（两轮耗时相同 → acr_cts 重复）
        sparse_round;
        guard = 0;
        while (pkt_cnt < 2 && guard < 100) begin @(negedge clk); guard = guard + 1; end
        ck_eq(pkt_cnt, 2,                   "[cts] second sparse packet observed");
        ck(pkt_gap >= 340 && pkt_gap <= 400,
                                            "[cts] measured packet gap in sparse-feed range");
        ck_eq(cts_mismatch, 0,              "[cts] acr_cts == measured gap for sparse packets");

        // =====================================================================
        // ⑥ 快速实例（AUDIO_DIV=1）：每个 audio_valid 都发包
        //    若 RTL 把 div_tick 的比较写错成 div_cnt == AUDIO_DIV，
        //    这里会变成每 2 个样本一次。
        //    快实例有独立的计分器 pkt_cnt_f / last_cts_f。
        // =====================================================================
        clr_stats();
        for (i = 0; i < 5; i = i + 1) begin
            @(negedge clk); audio_valid_f = 1'b1;
            @(posedge clk);
            @(negedge clk); audio_valid_f = 1'b0;
            @(posedge clk);
        end
        @(negedge clk);
        ck_eq(pkt_cnt_f, 5,                 "[fast] DIV=1: one packet per audio sample");
        ck_eq(acr_n_f, ACR_N_FAST,          "[fast] acr_n stays 128");
        ck_eq(last_cts_f, 2,                "[fast] cts = 2 for packets 2 clocks apart");
        ck_eq(pkt_cnt, 0,                   "[fast] main instance unaffected by fast feed");

        // 不给 audio_valid 就不发包
        clr_stats();
        repeat (50) @(posedge clk);
        ck_eq(pkt_cnt_f, 0,                 "[fast] no packet without audio_valid");

        // =====================================================================
        // ⑦ 运行中复位：计数与输出全部归零，acr_n 恢复参数值
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        ck(acr_valid === 1'b0,              "[mid-reset] acr_valid cleared");
        ck_eq(acr_cts, 20'd0,               "[mid-reset] acr_cts cleared");
        ck_eq(acr_n,   ACR_N_REAL,          "[mid-reset] acr_n back to 6144");
        ck_eq(acr_n_f, ACR_N_FAST,          "[mid-reset] fast acr_n back to 128");

        // 复位期间给 audio_valid 也不能发包
        clr_stats();
        @(negedge clk); audio_valid = 1'b1;
        repeat (60) @(posedge clk);
        #1;
        ck_eq(pkt_cnt, 0,                   "[mid-reset] no packet while reset asserted");
        @(negedge clk); audio_valid = 1'b0;

        // =====================================================================
        // ⑧ 复位释放后重新计数
        //    注意：复位释放后第一个包的 acr_cts 天然包含"复位到首个样本"之间的
        //    空闲拍数（cts_cnt 从复位起就一直在数），所以不能拿它比 48。
        //    要验证"背靠背时 CTS=48"，必须看**第二个**包：两包之间恰好 48 拍。
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);
        clr_stats();
        for (i = 0; i < DIV_REAL; i = i + 1) begin     // 第一轮 → 包 1
            @(negedge clk); audio_valid = 1'b1;
            @(posedge clk);
        end
        guard = 0;
        while (pkt_cnt < 1 && guard < 100) begin @(negedge clk); guard = guard + 1; end
        ck_eq(pkt_cnt, 1,                   "[resume] packet returns after reset release");
        ck(last_cts > DIV_REAL,             "[resume] 1st post-reset cts includes idle clocks since reset");

        for (i = 0; i < DIV_REAL; i = i + 1) begin     // 第二轮紧接 → 包 2
            @(negedge clk); audio_valid = 1'b1;
            @(posedge clk);
        end
        @(negedge clk); audio_valid = 1'b0;
        guard = 0;
        while (pkt_cnt < 2 && guard < 100) begin @(negedge clk); guard = guard + 1; end
        ck_eq(pkt_cnt, 2,                   "[resume] second packet follows");
        ck_eq(last_cts, DIV_REAL,           "[resume] 2nd packet cts = 48 (back-to-back)");
        ck_eq(cts_mismatch, 0,              "[resume] acr_cts == measured gap after reset");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: audio_arc");
        else             $display("CHECKS FAILED: audio_arc");
        $finish;
    end

    initial begin
        #400000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("CHECKS FAILED: audio_arc");
        $finish;
    end

endmodule
