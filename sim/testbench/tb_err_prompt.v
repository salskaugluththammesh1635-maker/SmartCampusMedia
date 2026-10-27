// =============================================================================
// tb_err_prompt.v — 面向用户的错误提示归并单元测试
// -----------------------------------------------------------------------------
// 背景:
//   改造前数码管直接显示各模块内部的 1~9 错误码，用户必须查表才知道含义，
//   且"卡读通了但一张图都没有"这种情况三个 fail 标志全为 0、蜂鸣器不响，
//   用户只会以为设备坏了（TASKS.md A8 记录的缺口）。
//   err_prompt.v 把 5 个模块的错误码归并成 5 类"用户动作"助记字母，
//   并驱动一段"延迟 1.5s、只响 3s"的故障告警音。本 TB 用于锁死这两件事。
//
// 参数取小值（CLK_FREQ_HZ=100）让告警时序在仿真里快速跑完:
//   ALARM_DELAY=150 拍、ALARM_HOLD=300 拍、ALARM_TOTAL=450 拍
//
// 【为什么断言 tag 用 ASCII 而注释用中文】
//   ModelSim ASE 10.1d 的 $display 把字符串按单字节处理，UTF-8 中文会被
//   拆成乱码（同一项目里 tb_seg_scan4 等既有 TB 也有此现象）。tag 是
//   **给人和 CI 读的**，乱码会让回归日志失去可读性，故 tag 一律 ASCII，
//   中文说明留在本文件的注释里（.v 文件按要求 UTF-8 无 BOM，read 工具正常）。
//
// 验证项:
//   C1  复位后无错误、无告警
//   C2  SD 层分类: err=1→C1 / 2,3,4→C2 / 8→F1 / 5,6,7→d1 / 其它→C9
//   C3  图库层分类: err=1→F1 / 2→F2 / 3→F3 / 5→d2 / 6→d3 / 其它→d9
//   C4  图片层分类: err=2→b1 / 7→b2 / 1→F4 / 3,4,5,8,9→d4,d5,d6,d7,d8
//   C5  "卡好但零张图"→ 00 且 err_active=1（改造前完全无提示的盲区）
//   C6  sd_cd 无卡抢先提示 → C0
//   C7  优先级: sd_fail > gallery_fail > image_failed
//   C8  告警延迟: 刚出错后的 ALARM_DELAY 拍内 alarm_req 必须为 0
//   C9  告警窗口: 延迟后拉高，满 ALARM_TOTAL 拍后自动停止且不再重复
//   C10 错误消失后计数清零；再次出错会重新响一轮（不漏报）
//   C11 正常态（有图可播）不产生任何提示
//
// 运行: vsim -c -do "run -all" work.tb_err_prompt
// =============================================================================
`timescale 1ns / 1ps

module tb_err_prompt;

    // ---- 时钟与复位 ----
    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50MHz 仿真时钟（周期只影响壁钟时间）

    reg rst_n = 1'b0;

    // ---- DUT 输入 ----
    reg        sd_fail       = 1'b0;
    reg  [3:0] sd_err        = 4'd0;
    reg        sd_cd         = 1'b0;    // 0=插卡 1=无卡
    reg        gallery_fail  = 1'b0;
    reg  [3:0] gallery_err   = 4'd0;
    reg        gallery_done  = 1'b0;
    reg  [4:0] gallery_count = 5'd0;
    reg        image_failed  = 1'b0;
    reg  [3:0] image_err     = 4'd0;

    // ---- DUT 输出 ----
    wire       err_active;
    wire [3:0] prompt_hi, prompt_lo;
    wire       alarm_req;

    // 参数取 100Hz，使 ALARM_DELAY=150 / ALARM_HOLD=300 / ALARM_TOTAL=450
    localparam integer FREQ        = 100;
    localparam integer ALARM_DELAY = FREQ * 3 / 2;               // 150
    localparam integer ALARM_HOLD  = FREQ * 3;                   // 300
    localparam integer ALARM_TOTAL = ALARM_DELAY + ALARM_HOLD;   // 450

    err_prompt #(.CLK_FREQ_HZ(FREQ)) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .sd_fail       (sd_fail),
        .sd_err        (sd_err),
        .sd_cd         (sd_cd),
        .gallery_fail  (gallery_fail),
        .gallery_err   (gallery_err),
        .gallery_done  (gallery_done),
        .gallery_count (gallery_count),
        .image_failed  (image_failed),
        .image_err     (image_err),
        .err_active    (err_active),
        .prompt_hi     (prompt_hi),
        .prompt_lo     (prompt_lo),
        .alarm_req     (alarm_req)
    );

    // ---- 助记字母期望值（与 err_prompt 内部编码一致）----
    localparam [3:0] CH_CARD   = 4'hC;
    localparam [3:0] CH_FORMAT = 4'hF;
    localparam [3:0] CH_NONE   = 4'h0;
    localparam [3:0] CH_BMP    = 4'hB;
    localparam [3:0] CH_DATA   = 4'hD;

    integer errors = 0;

    // ---- 断言工具 ----
    // 输出格式必须是行首 "PASS: " / "FAIL: " —— 回归脚本
    // sim/scripts/run_frontend_regression.ps1 用正则 `^\s*(?:#\s*)?PASS:`
    // 统计通过条数、用 `^\s*(?:#\s*)?FAIL\b` 判定失败。
    // 写成 "[PASS] xxx" 会让方括号挡住行首匹配，导致 passLines=0 而误判为未通过。
    task chk(input cond, input [1023:0] tag);
        begin
            if (cond) $display("PASS: %0s", tag);
            else begin
                $display("FAIL: %0s", tag);
                errors = errors + 1;
            end
        end
    endtask

    // ---- 提示码断言: 一次比对 err_active / 字母类 / 子码 ----
    task chk_prompt(input exp_active, input [3:0] exp_hi, input [3:0] exp_lo,
                    input [1023:0] tag);
        begin
            if ((err_active === exp_active) &&
                (prompt_hi  === exp_hi) &&
                (prompt_lo  === exp_lo))
                $display("PASS: %0s (hi=%h lo=%h)", tag, prompt_hi, prompt_lo);
            else begin
                $display("FAIL: %0s expected active=%b hi=%h lo=%h, got active=%b hi=%h lo=%h",
                         tag, exp_active, exp_hi, exp_lo,
                         err_active, prompt_hi, prompt_lo);
                errors = errors + 1;
            end
        end
    endtask

    // ---- 等 n 个时钟上升沿 ----
    task wait_cycles(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    // ---- 清空全部错误源（回到"一切正常"）----
    task clear_all;
        begin
            @(negedge clk);
            sd_fail = 1'b0; sd_err = 4'd0; sd_cd = 1'b0;
            gallery_fail = 1'b0; gallery_err = 4'd0;
            gallery_done = 1'b0; gallery_count = 5'd0;
            image_failed = 1'b0; image_err = 4'd0;
            @(negedge clk);
        end
    endtask

    initial begin
        $display("=== tb_err_prompt start ===");
        $display("ALARM_DELAY=%0d ALARM_HOLD=%0d ALARM_TOTAL=%0d (CLK_FREQ_HZ=%0d)",
                 ALARM_DELAY, ALARM_HOLD, ALARM_TOTAL, FREQ);

        // ================= C1 复位态 =================
        rst_n = 1'b0;
        wait_cycles(5);
        @(negedge clk);
        rst_n = 1'b1;
        wait_cycles(3);
        chk_prompt(1'b0, 4'h0, 4'h0, "C1 reset: no error, no prompt");
        chk(alarm_req === 1'b0, "C1 reset: no alarm tone");

        // ================= C2 SD 层分类 =================
        // err=1: CMD0 重试用尽 → C1（没插卡/没插到底）
        @(negedge clk); sd_fail = 1'b1; sd_err = 4'd1;
        @(negedge clk);
        chk_prompt(1'b1, CH_CARD, 4'd1, "C2 sd_err=1 -> C1 insert card");
        // err=2/3/4: 协议不兼容 → C2（换卡）
        @(negedge clk); sd_err = 4'd2; @(negedge clk);
        chk_prompt(1'b1, CH_CARD, 4'd2, "C2 sd_err=2 -> C2 replace card");
        @(negedge clk); sd_err = 4'd3; @(negedge clk);
        chk_prompt(1'b1, CH_CARD, 4'd2, "C2 sd_err=3 -> C2 replace card");
        @(negedge clk); sd_err = 4'd4; @(negedge clk);
        chk_prompt(1'b1, CH_CARD, 4'd2, "C2 sd_err=4 SDSC -> C2 replace card");
        // err=8: MBR 签名非 0x55AA → F1（请格式化）
        @(negedge clk); sd_err = 4'd8; @(negedge clk);
        chk_prompt(1'b1, CH_FORMAT, 4'd1, "C2 sd_err=8 -> F1 format FAT32");
        // err=5/6/7: 令牌/CRC/应答错 → d1（接触不良或卡损）
        @(negedge clk); sd_err = 4'd5; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd1, "C2 sd_err=5 -> d1 data path");
        @(negedge clk); sd_err = 4'd6; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd1, "C2 sd_err=6 -> d1 data path");
        @(negedge clk); sd_err = 4'd7; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd1, "C2 sd_err=7 -> d1 data path");
        // err=0（兜底，sd_probe 实际不会给 0）→ C9
        @(negedge clk); sd_err = 4'd0; @(negedge clk);
        chk_prompt(1'b1, CH_CARD, 4'd9, "C2 sd_err=default -> C9");

        // ================= C3 图库层分类 =================
        clear_all;
        @(negedge clk); gallery_fail = 1'b1; gallery_err = 4'd1;
        @(negedge clk);
        chk_prompt(1'b1, CH_FORMAT, 4'd1, "C3 gallery_err=1 MBR sig -> F1");
        @(negedge clk); gallery_err = 4'd2; @(negedge clk);
        chk_prompt(1'b1, CH_FORMAT, 4'd2, "C3 gallery_err=2 VBR/BPB -> F2");
        @(negedge clk); gallery_err = 4'd3; @(negedge clk);
        chk_prompt(1'b1, CH_FORMAT, 4'd3, "C3 gallery_err=3 fat chain -> F3");
        @(negedge clk); gallery_err = 4'd5; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd2, "C3 gallery_err=5 read block -> d2");
        @(negedge clk); gallery_err = 4'd6; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd3, "C3 gallery_err=6 bad arg -> d3");
        @(negedge clk); gallery_err = 4'd0; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd9, "C3 gallery_err=default -> d9");

        // ================= C4 图片层分类 =================
        clear_all;
        @(negedge clk); image_failed = 1'b1; image_err = 4'd2;
        @(negedge clk);
        chk_prompt(1'b1, CH_BMP, 4'd1, "C4 image_err=2 bmp header -> b1");
        @(negedge clk); image_err = 4'd7; @(negedge clk);
        chk_prompt(1'b1, CH_BMP, 4'd2, "C4 image_err=7 pixel count -> b2");
        @(negedge clk); image_err = 4'd1; @(negedge clk);
        chk_prompt(1'b1, CH_FORMAT, 4'd4, "C4 image_err=1 fat32 locate -> F4");
        @(negedge clk); image_err = 4'd3; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd4, "C4 image_err=3 read block -> d4");
        @(negedge clk); image_err = 4'd4; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd5, "C4 image_err=4 fat chain -> d5");
        @(negedge clk); image_err = 4'd5; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd6, "C4 image_err=5 fifo full -> d6");
        @(negedge clk); image_err = 4'd8; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd7, "C4 image_err=8 sdram -> d7");
        @(negedge clk); image_err = 4'd9; @(negedge clk);
        chk_prompt(1'b1, CH_DATA, 4'd8, "C4 image_err=9 timeout -> d8");

        // ================= C5 卡好但零张图（改造前的交互盲区）=================
        clear_all;
        @(negedge clk); gallery_done = 1'b1; gallery_count = 5'd0;
        @(negedge clk);
        chk_prompt(1'b1, CH_NONE, 4'd0, "C5 zero images -> 00 add IMGnnn.BMP");

        // ================= C11 正常态（扫描到图，可播放）=================
        @(negedge clk); gallery_count = 5'd7;
        @(negedge clk);
        chk_prompt(1'b0, 4'h0, 4'h0, "C11 seven images -> no prompt");

        // ================= C6 sd_cd 无卡抢先提示 =================
        clear_all;
        @(negedge clk); sd_cd = 1'b1;       // 无卡（硬件电平，上电即有）
        wait_cycles(3);                     // 两级同步需要 2 拍
        chk_prompt(1'b1, CH_CARD, 4'd0, "C6 no card -> C0 prompt before probe");
        @(negedge clk); sd_cd = 1'b0;
        wait_cycles(3);
        chk_prompt(1'b0, 4'h0, 4'h0, "C6 card back -> C0 prompt cleared");

        // ================= C7 优先级链 =================
        // 同时给出四个来源，应只显示 sd_fail
        @(negedge clk);
        sd_fail = 1'b1; sd_err = 4'd8;              // F1
        gallery_fail = 1'b1; gallery_err = 4'd3;    // F3
        image_failed = 1'b1; image_err = 4'd7;      // b2
        sd_cd = 1'b1;                               // C0
        @(negedge clk);
        chk_prompt(1'b1, CH_FORMAT, 4'd1, "C7 priority sd_fail wins -> F1");
        // 撤掉 sd_fail，图库应接管
        @(negedge clk); sd_fail = 1'b0;
        @(negedge clk);
        chk_prompt(1'b1, CH_FORMAT, 4'd3, "C7 then gallery_fail -> F3");
        // 撤掉图库，图片层接管
        @(negedge clk); gallery_fail = 1'b0;
        @(negedge clk);
        chk_prompt(1'b1, CH_BMP, 4'd2, "C7 then image_failed -> b2");

        // ================= C8/C9/C10 告警时序 =================
        clear_all;
        wait_cycles(2);
        // 起一个 SD 故障，逐拍观察 alarm_req 何时拉高
        @(negedge clk); sd_fail = 1'b1; sd_err = 4'd1;
        // 延迟期内必须安静（抽 3 个时间点检查）
        wait_cycles(ALARM_DELAY / 3);
        chk(alarm_req === 1'b0, "C8 delay 1/3: no alarm yet");
        wait_cycles(ALARM_DELAY / 3);
        chk(alarm_req === 1'b0, "C8 delay 2/3: no alarm yet");
        wait_cycles(ALARM_DELAY / 3);
        chk(alarm_req === 1'b0, "C8 delay 3/3: no alarm yet");
        // 再等一小段，应已进入鸣响期
        wait_cycles(20);
        chk(alarm_req === 1'b1, "C9 alarm starts after delay window");
        // 鸣响期内保持
        wait_cycles(ALARM_HOLD / 2);
        chk(alarm_req === 1'b1, "C9 alarm held during hold window");
        // 走完整个周期后必须自动停止
        wait_cycles(ALARM_HOLD);
        chk(alarm_req === 1'b0, "C9 alarm stops after full period");
        // 关键: 停止后不能自己重新响（饱和不回绕），否则无人值守时会一直吵
        wait_cycles(ALARM_TOTAL);
        chk(alarm_req === 1'b0, "C9 no repeat after stop (saturated)");
        chk_prompt(1'b1, CH_CARD, 4'd1, "C9 visual prompt still present");

        // C10 错误消失 → 计数清零；再次出错 → 重新响一轮
        @(negedge clk); sd_fail = 1'b0;
        wait_cycles(3);
        chk(alarm_req === 1'b0, "C10 error cleared: no alarm");
        @(negedge clk); sd_fail = 1'b1; sd_err = 4'd1;
        wait_cycles(ALARM_DELAY / 2);
        chk(alarm_req === 1'b0, "C10 new fault re-enters quiet window");
        wait_cycles(ALARM_DELAY);
        chk(alarm_req === 1'b1, "C10 new fault alarms again (no missed alert)");

        // ================= 汇总 =================
        clear_all;
        wait_cycles(3);
        $display("=== tb_err_prompt done, errors = %0d ===", errors);
        if (errors == 0) $display("*** ALL CHECKS PASSED ***");
        else             $display("*** CHECKS FAILED ***");
        $finish;
    end

    // ---- 全局超时保护 ----
    initial begin
        #5_000_000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("*** CHECKS FAILED ***");
        $finish;
    end

endmodule
