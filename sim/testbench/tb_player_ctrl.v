// ============================================================================
// tb_player_ctrl —— player_ctrl（播放控制状态机）独立仿真（S7 轮播接入验证）
// ============================================================================
// DUT 工作在 25MHz（本系统 clk_pixel 的真实频率），参数显式传 .CLK_FREQ_HZ(25_000_000)。
//
// 【关于仿真时长】AUTO_TICKS = CLK_FREQ_HZ × AUTO_SW_S。若按 5 秒 @25MHz 仿真，
//   一次轮播就要 1.25 亿拍，整个 tb 需跑十几分钟且毫无信息量。因此把用例拆成两类:
//     · 逻辑类用例（切图/回绕/模式/边界）→ 与轮播间隔无关，用 dut_fast
//       （CLK_FREQ_HZ=250，间隔 250 拍）快速穷举，等价性来自"计数目标只影响时刻、
//       不影响推进规则"这一事实
//     · 计时类用例（U09）→ 必须用真实的 25MHz 参数跑满 25,000,000 拍，
//       用来实证 AUTO_SW_S=1 恰好等于 1.0 秒（而不是 2.0 秒）
//
// 验证项（18 个用例 / 85 条断言）:
//   U01 复位恢复:        复位后 index=0 / auto=0 / mode=日常 / LED=0 / 无切图脉冲
//   U02 手动下一张:      KEY1 使 index 0→1，切图脉冲恰好 1 次且为单拍
//   U03 手动上一张回绕:  在 index 0 按 KEY0 → 回绕到末张（gallery_count-1）
//   U04 末张下一张回绕:  在末张按 KEY1 → 回第 0 张
//   U05 无效键号:        key_code=9 / 7（未分配）→ 索引、模式、脉冲全不变
//   U06 模式循环:        KEY3: 日常→科普→应急→日常
//   U07 应急禁切图:      应急模式下 KEY0/KEY1/KEY2 全部无效
//   U08 应急直达:        KEY15 任意模式→应急，强制关轮播，LED bit1=1
//   U09 自动轮播计时:    AUTO_SW_S=1 @25MHz → 恰好 25,000,000 拍后切图
//   U10 满圈回绕序列:    连续 8 次自动切图，索引 0→1→…→7→0
//   U11 gallery_count=1: 单图库下索引恒为 0，不越界
//   U12 gallery_count=0: 空图库（valid=1 但 0 张）不得持续发切图请求、不得出 31
//   U13 gallery_valid=0: 图库未就绪时切图被抑制，就绪后恢复
//   U14 图库收缩保护:    index 5 + count 降为 3 → 回绕首图且只脉冲一次
//   U15 复位中途恢复:    倒计时中途复位 → 索引/使能清零，无残脉冲
//   U16 loader_index:    恒等于 img_index+1（0→IMG001.BMP，7→IMG008.BMP）
//   U17 参数对照:        同 tb 内并联一个 CLK_FREQ_HZ=50M 的实例，
//                        实证"参数写错 → 间隔翻倍"，固化"例化必须显式传参"
//   U18 切模式重置计时:  KEY3 切模式后 auto_cnt 归零（修复前漏发 auto_rst_req）
//
// 用法（工作目录 sim/msim_work）:
//   vlog -quiet ../../rtl/control/player_ctrl.v ../testbench/tb_player_ctrl.v
//   vsim -c -quiet -lib work -do "run -all; quit -f" tb_player_ctrl
// ============================================================================
`timescale 1ns/1ps

module tb_player_ctrl;

    // ---- 时钟: 25MHz（周期 40ns，与本系统 clk_pixel 一致）----
    localparam CLK_PERIOD = 40;             // ns
    reg clk;
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n;

    // ---- 共享激励 ----
    reg        key_event     = 1'b0;
    reg  [3:0] key_code      = 4'd0;
    reg  [4:0] gallery_count = 5'd8;
    reg        gallery_valid = 1'b1;

    // ========== DUT ① : 被测主体（真实参数，用于计时验证）==========
    wire [4:0] img_index;
    wire       img_switch_req;
    wire [8:0] loader_index;
    wire       auto_play_en;
    wire [1:0] mode;
    wire [3:0] status_led;

    player_ctrl #(
        .IMG_COUNT   (8),
        .AUTO_SW_S   (1),                  // 1 秒: 逻辑与 5 秒完全相同，只影响时长
        .CLK_FREQ_HZ (25_000_000)          // ← 本系统真实时钟，必须显式传
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_event      (key_event),
        .key_code       (key_code),
        .gallery_count  (gallery_count),
        .gallery_valid  (gallery_valid),
        .img_index      (img_index),
        .img_switch_req (img_switch_req),
        .loader_index   (loader_index),
        .auto_play_en   (auto_play_en),
        .mode           (mode),
        .status_led     (status_led)
    );

    // ========== DUT ② : 快时钟参数实例（同一 25MHz 时钟，把间隔缩到 250 拍）==========
    // 用途: 让轮播类用例能在微秒级完成穷举。f_tick 不是"另一个时钟"，
    //       而是把参数换算成更短的计数值——推进规则与真实参数完全同一条 RTL。
    wire [4:0] f_index;
    wire       f_switch;
    wire       f_auto;

    player_ctrl #(
        .IMG_COUNT   (8),
        .AUTO_SW_S   (1),
        .CLK_FREQ_HZ (250)                 // 250 拍 = 1 "秒"（仅用于加速仿真）
    ) dut_fast (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_event      (key_event),
        .key_code       (key_code),
        .gallery_count  (gallery_count),
        .gallery_valid  (gallery_valid),
        .img_index      (f_index),
        .img_switch_req (f_switch),
        .loader_index   (),
        .auto_play_en   (f_auto),
        .mode           (),
        .status_led     ()
    );

    // ========== DUT ③ : 参数对照实例（故意保留 50MHz 声明）==========
    // 目的: 同一个 25MHz 时钟下，参数写错的实例会把"1 秒"跑成"2 秒"。
    //       这不是为了证明某个 bug 存在，而是把"例化必须显式传参"固化进回归，
    //       防止将来有人在顶层漏传参而无人察觉（编译与综合都不会报错）。
    wire [4:0] x_index;
    wire       x_switch;
    wire       x_auto;

    player_ctrl #(
        .IMG_COUNT   (8),
        .AUTO_SW_S   (1),
        .CLK_FREQ_HZ (50_000_000)          // ← 故意与真实时钟不符
    ) dut_wrong_clk (
        .clk            (clk),
        .rst_n          (rst_n),
        .key_event      (key_event),
        .key_code       (key_code),
        .gallery_count  (gallery_count),
        .gallery_valid  (gallery_valid),
        .img_index      (x_index),
        .img_switch_req (x_switch),
        .loader_index   (),
        .auto_play_en   (x_auto),
        .mode           (),
        .status_led     ()
    );

    // ========================================================================
    // 检查工具
    // ========================================================================
    integer errors = 0;
    integer checks = 0;

    task chk;
        input         cond;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (cond) begin
                $display("PASS: %0s", name);
            end else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_eq32;                          // 带实际/期望值的比较，便于定位
        input [31:0]  got;
        input [31:0]  exp;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (got === exp) begin
                $display("PASS: %0s (got %0d)", name, got);
            end else begin
                $display("FAIL: %0s (got %0d, expect %0d)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ========================================================================
    // 监视器: dut 的切图脉冲计数 + "持续为高"违例（脉冲必须是单拍）
    // ========================================================================
    integer sw_pulses = 0;
    integer sw_stuck  = 0;
    reg     sw_d      = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_pulses <= 0;
            sw_stuck  <= 0;
            sw_d      <= 1'b0;
        end else begin
            sw_d <= img_switch_req;
            if (img_switch_req && !sw_d) sw_pulses <= sw_pulses + 1;
            if (img_switch_req &&  sw_d) sw_stuck  <= sw_stuck  + 1;
        end
    end

    // ========================================================================
    // 激励工具
    // ========================================================================
    // 按一次键: key_event 保持 1 拍（与 key_matrix_4x4 的单拍脉冲规格一致）
    task press_key;
        input [3:0] code;
        begin
            @(negedge clk);
            key_code  = code;
            key_event = 1'b1;
            @(negedge clk);
            key_event = 1'b0;
            key_code  = 4'd0;
            @(negedge clk);                 // 等 DUT 完成本拍更新再返回
        end
    endtask

    task do_reset;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);
        end
    endtask

    // ========================================================================
    // 主流程
    // ========================================================================
    integer   i;
    integer   t0_idx;
    integer   n_sw_before;
    integer   cyc;
    reg [4:0] seq [0:7];                    // U10 的索引序列快照

    initial begin
        rst_n = 1'b0;

        // ---------------- U01 复位恢复 ----------------
        $display("");
        $display("---- U01 reset recovery ----");
        repeat (4) @(negedge clk);
        chk_eq32({4'd0, img_index}, 32'd0,  "U01 img_index = 0 after reset");
        chk(auto_play_en   == 1'b0,         "U01 auto_play_en = 0 after reset");
        chk(mode           == 2'd0,         "U01 mode = NORMAL(0) after reset");
        chk(status_led     == 4'b0000,      "U01 status_led = 0 after reset");
        chk(img_switch_req == 1'b0,         "U01 no switch pulse after reset");
        chk_eq32({4'd0, loader_index}, 32'd1, "U01 loader_index = 1 (IMG001.BMP)");
        rst_n = 1'b1;
        @(negedge clk);

        // ---------------- U16 loader_index 映射（0 基 → 1 基）----------------
        $display("");
        $display("---- U16 loader_index = img_index + 1 ----");
        gallery_count = 5'd8;
        gallery_valid = 1'b1;
        chk_eq32({4'd0, loader_index}, 32'd1, "U16 index 0 -> loader 1 (IMG001.BMP)");
        press_key(4'd1);                                     // KEY1 下一张 → 1
        chk_eq32({4'd0, img_index},    32'd1, "U16 KEY1 moves img_index to 1");
        chk_eq32({4'd0, loader_index}, 32'd2, "U16 index 1 -> loader 2 (IMG002.BMP)");
        for (i = 0; i < 6; i = i + 1) press_key(4'd1);       // 累计 7 次 → 索引 7
        chk_eq32({4'd0, img_index},    32'd7, "U16 index = 7 after 7 x KEY1");
        chk_eq32({4'd0, loader_index}, 32'd8, "U16 index 7 -> loader 8 (IMG008.BMP)");

        // ---------------- U02 手动下一张 ----------------
        $display("");
        $display("---- U02 manual next ----");
        do_reset;
        gallery_count = 5'd8;
        n_sw_before = sw_pulses;
        press_key(4'd1);
        chk_eq32({4'd0, img_index}, 32'd1, "U02 KEY1 advances 0 -> 1");
        chk(sw_pulses == n_sw_before + 1,  "U02 exactly one switch pulse per KEY1");
        chk(sw_stuck == 0,                 "U02 switch request is a single-cycle pulse");

        // ---------------- U03 手动上一张 + 首张回绕 ----------------
        $display("");
        $display("---- U03 manual prev with wrap ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd0);                                     // 在 index 0 按上一张
        chk_eq32({4'd0, img_index}, 32'd7, "U03 KEY0 at index 0 wraps to last (7)");
        chk(sw_stuck == 0,                 "U03 prev switch request is single pulse");
        press_key(4'd0);
        chk_eq32({4'd0, img_index}, 32'd6, "U03 KEY0 at index 7 steps down to 6");

        // ---------------- U04 末张下一张回绕 ----------------
        $display("");
        $display("---- U04 next at last image ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd0);                                     // 0 → 7（末张）
        chk_eq32({4'd0, img_index}, 32'd7, "U04 precondition: index = 7");
        press_key(4'd1);                                     // 7 → 0
        chk_eq32({4'd0, img_index}, 32'd0, "U04 KEY1 at last wraps to 0");

        // ---------------- U05 无效键号 ----------------
        $display("");
        $display("---- U05 invalid key code ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd1);                                     // 先推到索引 1
        t0_idx      = img_index;
        n_sw_before = sw_pulses;
        press_key(4'd9);                                     // 未分配的键号
        chk_eq32({4'd0, img_index}, t0_idx, "U05 key_code=9 does not move index");
        chk(mode == 2'd0,                   "U05 key_code=9 does not change mode");
        chk(sw_pulses == n_sw_before,       "U05 key_code=9 emits no switch pulse");
        press_key(4'd7);                                     // 另一个未分配键号
        chk_eq32({4'd0, img_index}, t0_idx, "U05 key_code=7 does not move index");

        // ---------------- U06 模式循环 ----------------
        $display("");
        $display("---- U06 mode cycling ----");
        do_reset;
        gallery_count = 5'd8;
        chk(mode == 2'd0,          "U06 start in NORMAL(0)");
        press_key(4'd3);
        chk(mode == 2'd1,          "U06 NORMAL -> SCIENCE(1)");
        press_key(4'd3);
        chk(mode == 2'd2,          "U06 SCIENCE -> EMERGENCY(2)");
        chk(status_led[1] == 1'b1, "U06 LED bit1 = 1 in EMERGENCY");
        press_key(4'd3);
        chk(mode == 2'd0,          "U06 EMERGENCY -> NORMAL(0)");
        chk(status_led[1] == 1'b0, "U06 LED bit1 = 0 back in NORMAL");

        // ---------------- U07 应急模式禁止切图/轮播 ----------------
        $display("");
        $display("---- U07 emergency blocks switching ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd3); press_key(4'd3);                    // → 应急模式
        chk(mode == 2'd2, "U07 precondition: in EMERGENCY");
        t0_idx      = img_index;
        n_sw_before = sw_pulses;
        press_key(4'd1);
        chk_eq32({4'd0, img_index}, t0_idx, "U07 KEY1 blocked in EMERGENCY");
        press_key(4'd0);
        chk_eq32({4'd0, img_index}, t0_idx, "U07 KEY0 blocked in EMERGENCY");
        press_key(4'd2);
        chk(auto_play_en == 1'b0,           "U07 KEY2 cannot start auto in EMERGENCY");
        chk(sw_pulses == n_sw_before,       "U07 no switch pulse in EMERGENCY");

        // ---------------- U08 应急直达键（KEY15）----------------
        $display("");
        $display("---- U08 emergency direct key ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd2);                                     // 先开自动轮播
        chk(auto_play_en == 1'b1,  "U08 precondition: auto play on");
        press_key(4'd15);                                    // KEY15 应急直达
        chk(mode == 2'd2,          "U08 KEY15 jumps to EMERGENCY from NORMAL");
        chk(auto_play_en == 1'b0,  "U08 KEY15 forces auto play off");
        chk(status_led[1] == 1'b1, "U08 LED bit1 = 1 (emergency)");
        press_key(4'd15);                                    // 重复按应保持
        chk(mode == 2'd2,          "U08 KEY15 stays in EMERGENCY");

        // ---------------- U11 gallery_count = 1（单图库）----------------
        $display("");
        $display("---- U11 gallery_count = 1 ----");
        do_reset;
        gallery_count = 5'd1;
        chk_eq32({4'd0, img_index}, 32'd0, "U11 single image: index 0");
        press_key(4'd1);
        chk_eq32({4'd0, img_index}, 32'd0, "U11 KEY1 keeps index 0 (only one image)");
        press_key(4'd0);
        chk_eq32({4'd0, img_index}, 32'd0, "U11 KEY0 keeps index 0 (only one image)");
        chk(sw_stuck == 0,                 "U11 no stuck switch request");

        // ---------------- U12 gallery_count = 0（空图库）----------------
        $display("");
        $display("---- U12 gallery_count = 0 (empty gallery) ----");
        do_reset;
        gallery_count = 5'd0;
        gallery_valid = 1'b1;                                // 扫描完成但一张都没有
        repeat (20) @(negedge clk);
        chk_eq32({4'd0, img_index}, 32'd0, "U12 empty gallery keeps index 0");
        chk(sw_stuck == 0,                 "U12 empty gallery emits no stuck request");
        t0_idx = img_index;
        press_key(4'd1);
        chk_eq32({4'd0, img_index}, t0_idx, "U12 KEY1 with empty gallery does nothing");
        press_key(4'd0);
        chk_eq32({4'd0, img_index}, t0_idx, "U12 KEY0 with empty gallery does nothing");
        chk(img_index != 5'd31,            "U12 empty gallery never yields index 31");
        press_key(4'd2);
        chk(auto_play_en == 1'b0,          "U12 KEY2 cannot start auto on empty gallery");

        // ---------------- U13 gallery_valid = 0（图库未就绪）----------------
        $display("");
        $display("---- U13 gallery_valid = 0 ----");
        do_reset;
        gallery_count = 5'd8;
        gallery_valid = 1'b0;                                // 未就绪
        t0_idx = img_index;
        press_key(4'd1);
        chk_eq32({4'd0, img_index}, t0_idx, "U13 KEY1 ignored while gallery invalid");
        press_key(4'd0);
        chk_eq32({4'd0, img_index}, t0_idx, "U13 KEY0 ignored while gallery invalid");
        press_key(4'd2);
        chk(auto_play_en == 1'b0,           "U13 KEY2 ignored while gallery invalid");
        gallery_valid = 1'b1;                                // 就绪后恢复
        press_key(4'd1);
        chk_eq32({4'd0, img_index}, 32'd1, "U13 KEY1 works after gallery becomes valid");

        // ---------------- U14 图库收缩保护 ----------------
        $display("");
        $display("---- U14 gallery shrink protection ----");
        do_reset;
        gallery_count = 5'd8;
        for (i = 0; i < 5; i = i + 1) press_key(4'd1);       // 索引推到 5
        chk_eq32({4'd0, img_index}, 32'd5, "U14 precondition: index = 5");
        gallery_count = 5'd3;                                // 重新扫描后只剩 3 张
        gallery_valid = 1'b1;
        repeat (4) @(negedge clk);
        chk_eq32({4'd0, img_index}, 32'd0, "U14 shrink forces index back to 0");
        chk(sw_stuck == 0,                 "U14 shrink request is a single pulse");
        repeat (10) @(negedge clk);
        n_sw_before = sw_pulses;
        repeat (10) @(negedge clk);
        chk(sw_pulses == n_sw_before,      "U14 no repeated switch requests after shrink");

        // ---------------- U15 复位中途恢复 ----------------
        $display("");
        $display("---- U15 reset during countdown ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd2);                                     // 开自动轮播
        chk(auto_play_en == 1'b1, "U15 precondition: auto on");
        press_key(4'd1); press_key(4'd1);                    // 索引 2
        repeat (100) @(negedge clk);                         // 让倒计时跑一段
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        chk_eq32({4'd0, img_index}, 32'd0, "U15 reset clears index to 0");
        chk(auto_play_en == 1'b0,          "U15 reset clears auto play");
        rst_n = 1'b1;
        @(negedge clk);
        chk(img_switch_req == 1'b0,        "U15 no stray switch pulse right after reset");

        // ---------------- U10 满圈回绕序列（用 dut_fast，250 拍/张）----------
        $display("");
        $display("---- U10 full-cycle wrap under auto rotation ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd2);                                     // 两个实例同时开轮播
        chk(f_auto == 1'b1, "U10 fast instance auto play enabled");
        for (i = 0; i < 8; i = i + 1) begin
            cyc = 0;
            while (f_switch !== 1'b1 && cyc < 2000) begin
                @(negedge clk);
                cyc = cyc + 1;
            end
            seq[i] = f_index;                                // 切图当拍读新索引
            @(negedge clk);                                  // 越过脉冲
        end
        $display("  U10 sequence: %0d %0d %0d %0d %0d %0d %0d %0d",
                 seq[0], seq[1], seq[2], seq[3], seq[4], seq[5], seq[6], seq[7]);
        chk(seq[0] == 5'd1, "U10 auto seq[0] = 1");
        chk(seq[1] == 5'd2, "U10 auto seq[1] = 2");
        chk(seq[2] == 5'd3, "U10 auto seq[2] = 3");
        chk(seq[3] == 5'd4, "U10 auto seq[3] = 4");
        chk(seq[4] == 5'd5, "U10 auto seq[4] = 5");
        chk(seq[5] == 5'd6, "U10 auto seq[5] = 6");
        chk(seq[6] == 5'd7, "U10 auto seq[6] = 7 (last image)");
        chk(seq[7] == 5'd0, "U10 auto seq[7] = 0 (wrapped to first)");
        chk(sw_stuck == 0,  "U10 no stuck switch request during rotation");

        // ---------------- U09 自动轮播计时（真实 25MHz 参数，25,000,000 拍）----
        // 关键断言: AUTO_SW_S=1 @25MHz → 首张切换应发生在 25,000,000 拍附近。
        //   若 CLK_FREQ_HZ 误写为 50MHz，实测会是 50,000,000 拍 → 本项 FAIL。
        $display("");
        $display("---- U09 auto rotation countdown (25MHz, 25000000 cycles) ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd2);                                     // 开自动轮播
        chk(auto_play_en == 1'b1,  "U09 auto play enabled");
        chk(status_led[0] == 1'b1, "U09 LED bit0 = 1 while auto playing");
        n_sw_before = sw_pulses;
        cyc = 0;
        while ((sw_pulses == n_sw_before) && (cyc < 26_000_000)) begin
            @(negedge clk);
            cyc = cyc + 1;
        end
        $display("  U09: first auto switch at cycle %0d (expect ~25000000)", cyc);
        chk(sw_pulses == n_sw_before + 1, "U09 auto rotation produced a switch pulse");
        chk(cyc >= 24_999_990 && cyc <= 25_000_010,
            "U09 interval = 25,000,000 cycles = 1.0s @25MHz (not 2.0s)");
        chk_eq32({4'd0, img_index}, 32'd1, "U09 auto switch advanced 0 -> 1");

        // ---------------- U17 参数写错就会翻倍（同 tb 内对照实例）------------
        // 此刻真实实例已经切图；声明 50MHz 的错误实例要到 5,000 万拍才动
        $display("");
        $display("---- U17 wrong CLK_FREQ_HZ doubles the interval ----");
        chk(x_index  == 5'd0,  "U17 wrong-param instance still on image 0 @25M cycles");
        chk(x_switch == 1'b0,  "U17 wrong-param instance has not pulsed yet");
        chk(x_auto   == 1'b1,  "U17 wrong-param instance did enable auto play");

        // ---------------- U18 模式切换也重置轮播倒计时 ----------------
        // 块② 的注释写的是"任何手动操作都重置计时"，但修复前只有 KEY0/KEY1/KEY2
        // 三个分支发了 auto_rst_req，KEY3 漏了 —— 表现为：自动轮播跑到第 4.9 秒
        // 时按一下模式键，界面会在 0.1 秒后自行跳图。这里用层次引用直接观察
        // dut.auto_cnt 来固化"切模式必须清零计时"这一行为。
        $display("");
        $display("---- U18 mode switch resets rotation countdown ----");
        do_reset;
        gallery_count = 5'd8;
        press_key(4'd2);                                     // 开自动轮播
        chk(auto_play_en == 1'b1, "U18 precondition: auto play on");
        repeat (5000) @(negedge clk);
        $display("  U18: auto_cnt before mode key = %0d", dut.auto_cnt);
        chk(dut.auto_cnt > 32'd4000, "U18 countdown accumulated before mode switch");
        press_key(4'd3);                                     // KEY3 切模式
        chk(mode == 2'd1,            "U18 mode switched to SCIENCE(1)");
        $display("  U18: auto_cnt right after mode key = %0d", dut.auto_cnt);
        chk(dut.auto_cnt <= 32'd8,   "U18 mode switch resets countdown to ~0");
        chk(auto_play_en == 1'b1,    "U18 auto play survives NORMAL -> SCIENCE");

        // ---------------- 收尾 ----------------
        $display("");
        chk(sw_stuck == 0, "global: img_switch_req never held high for two cycles");
        $display("=== tb_player_ctrl: %0d checks, %0d error(s) ===", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: player_ctrl");
        else             $display("CHECKS FAILED: %0d error(s)", errors);
        $finish;
    end

endmodule
