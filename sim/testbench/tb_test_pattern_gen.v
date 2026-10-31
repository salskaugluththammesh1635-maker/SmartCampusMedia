// =============================================================================
// tb_test_pattern_gen.v —— 8 种测试图案发生器（test_pattern_gen）自检测试平台
// -----------------------------------------------------------------------------
// 【被评测对象】
//   rtl/video/test_pattern_gen.v：按 pattern_sel 把 (active_x, active_y) 译成
//   24 bit RGB。上板时这是"显示器有没有信号、三路 TMDS 有没有接错"的唯一判据，
//   所以 8 种图案每一种都必须单独钉死。
//
// 【被测的全部功能点】
//   ① 默认黑：de=0 时 rgb 必须是 0（消隐期必须黑，否则显示器锁不住）
//   ② 图案 0 八色彩条：每带 80px，白/黄/青/绿/品红/红/蓝/黑
//   ③ 图案 1 网格：active_x[5:0]==0 或 active_y[5:0]==0 → 白
//   ④ 图案 2/3/4 单色渐变：rgb = {active_x[10:3]}（只驱动各自的通道）
//   ⑤ 图案 5 纯色：user_color 拆成 [23:16]/[15:8]/[7:0]
//   ⑥ 图案 6 移动方块：方块内绿(00/FF/00)、方块外深蓝(00/00/20)；
//      每帧末（de && active_x=639 && active_y=479）frame_cnt+1，
//      满 60 帧时移动一步并在边界翻转方向
//   ⑦ 图案 7 棋盘：active_x[4] ^ active_y[4] → 白
//   ⑧ 未知 pattern_sel（default 分支）→ 黑
//
// 【判据设计要点】
//   · 色条：不只测带中心，还测**每条带的两个边界像素**（x=79/80、159/160 …），
//     因为比较链的边界条件写错是这类代码最常见的一类 bug。
//   · 渐变：测 x=0 和 x=639 两端 + 若干中间点，同时验证"另外两个通道恒 0"
//     ——漏清零会让渐变图案带上染色，肉眼很难发现但上板一定偏色。
//   · 网格/棋盘：测边界与周期，特别是 x[5:0]==0 与 x[5:0]==63 两个位置，
//     前者是线、后者不是线，一次比对就能确认周期是 64 而不是 63/65。
//   · 移动方块：这是模块里唯一有时序状态的图案。用"每帧末打一拍"的方式
//     驱动 60 个帧末脉冲（de=1 + 末像素坐标），再检查 box_x 是否正好移动
//     了一步，并把 20 步走完验证左右/上下边界的往返翻转。
//   · 所有坐标比对都用 === 四态严格比较，x/z 也会被抓住。
//
// 【为什么不用真实帧时序跑】
//   本模块的图案生成是纯组合；移动方块只依赖 (de, active_x, active_y) 上的
//   "帧末"这一条件。因此用"每帧只打一拍照样"的方式驱动，能完整覆盖状态机，
//   却把仿真时间从几十万拍压到几十拍。真实帧时序的时序正确性由
//   tb_video_timing_gen 独立负责。
// =============================================================================
`timescale 1ns / 1ps

module tb_test_pattern_gen;

    // ---- 参数（与 RTL 默认一致）-------------------------------------------
    localparam H_ACTIVE = 640;
    localparam V_ACTIVE = 480;
    localparam BAR_W    = 80;      // 640 / 8
    localparam BOX_SIZE = 64;

    // ---- 接口 --------------------------------------------------------------
    reg         pixel_clk;
    reg         rst_n;
    reg         de;
    reg  [10:0] active_x;
    reg  [9:0]  active_y;
    reg  [2:0]  pattern_sel;
    reg  [23:0] user_color;
    wire [7:0]  rgb_r, rgb_g, rgb_b;

    test_pattern_gen u_dut (
        .pixel_clk   (pixel_clk),
        .rst_n       (rst_n),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .pattern_sel (pattern_sel),
        .user_color  (user_color),
        .rgb_r       (rgb_r),
        .rgb_g       (rgb_g),
        .rgb_b       (rgb_b)
    );

    initial begin pixel_clk = 1'b0; forever #5 pixel_clk = ~pixel_clk; end

    // ---- 计分 --------------------------------------------------------------
    // checks  : 全部断言数
    // errors  : 真实失败数（必须为 0 才算通过）
    // known_issues : 已登记的 RTL 缺陷（XFAIL），单独计数、不计入 errors
    integer checks;
    integer errors;
    integer known_issues;
    initial begin checks = 0; errors = 0; known_issues = 0; end

    // ---- 通用判据任务 ------------------------------------------------------
    task expect_rgb;
        input [7:0]      er;
        input [7:0]      eg;
        input [7:0]      eb;
        input [8*60-1:0] label;
        begin
            #1;   // 等组合逻辑稳定
            checks = checks + 1;
            if ((rgb_r === er) && (rgb_g === eg) && (rgb_b === eb)) begin
                $display("PASS: %0s | rgb=%h_%h_%h", label, rgb_r, rgb_g, rgb_b);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s | got=%h_%h_%h expected=%h_%h_%h",
                         label, rgb_r, rgb_g, rgb_b, er, eg, eb);
            end
        end
    endtask

    // 在给定坐标上按当前 pattern_sel 取色
    task at;
        input [10:0]     x;
        input [9:0]      y;
        input [7:0]      er;
        input [7:0]      eg;
        input [7:0]      eb;
        input [8*60-1:0] label;
        begin
            de       = 1'b1;
            active_x = x;
            active_y = y;
            expect_rgb(er, eg, eb, label);
        end
    endtask

    // 打一个"帧末"脉冲：de=1 且位于末像素
    task frame_end;
        begin
            de       = 1'b1;
            active_x = H_ACTIVE - 1;
            active_y = V_ACTIVE - 1;
            @(posedge pixel_clk);
            #1;
            de       = 1'b0;
            active_x = 11'd0;
            active_y = 10'd0;
            @(posedge pixel_clk);
            #1;
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    integer k;
    reg [7:0]  gx;
    integer    bx;
    integer    gi, gj;
    reg        box_visible_seen;

    initial begin
        $display("=== tb_test_pattern_gen : 8 selectable video patterns ===");

        rst_n       = 1'b0;
        de          = 1'b0;
        active_x    = 11'd0;
        active_y    = 10'd0;
        pattern_sel = 3'd0;
        user_color  = 24'h00_00_00;
        repeat (4) @(posedge pixel_clk);
        rst_n = 1'b1;
        #1;

        // =====================================================================
        // ① 消隐期必须全黑（与图案选择无关）
        // =====================================================================
        de = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            pattern_sel = i[2:0];
            active_x    = 11'd100;
            active_y    = 10'd100;
            expect_rgb(8'h00, 8'h00, 8'h00, "[blanking] rgb black when de=0");
        end

        // =====================================================================
        // ② 图案 0：八色彩条，每带 80 像素
        //    测每带中心 + 每带左右边界，边界条件是这类比较链的高发 bug 区
        // =====================================================================
        pattern_sel = 3'd0;
        at(11'd0,   10'd100, 8'hFF, 8'hFF, 8'hFF, "[bar0] white  x=0");
        at(11'd40,  10'd100, 8'hFF, 8'hFF, 8'hFF, "[bar0] white  x=40 center");
        at(11'd79,  10'd100, 8'hFF, 8'hFF, 8'hFF, "[bar0] white  x=79 last");
        at(11'd80,  10'd100, 8'hFF, 8'hFF, 8'h00, "[bar1] yellow x=80 first");
        at(11'd120, 10'd100, 8'hFF, 8'hFF, 8'h00, "[bar1] yellow x=120 center");
        at(11'd159, 10'd100, 8'hFF, 8'hFF, 8'h00, "[bar1] yellow x=159 last");
        at(11'd160, 10'd100, 8'h00, 8'hFF, 8'hFF, "[bar2] cyan   x=160 first");
        at(11'd200, 10'd100, 8'h00, 8'hFF, 8'hFF, "[bar2] cyan   x=200 center");
        at(11'd239, 10'd100, 8'h00, 8'hFF, 8'hFF, "[bar2] cyan   x=239 last");
        at(11'd240, 10'd100, 8'h00, 8'hFF, 8'h00, "[bar3] green  x=240 first");
        at(11'd280, 10'd100, 8'h00, 8'hFF, 8'h00, "[bar3] green  x=280 center");
        at(11'd319, 10'd100, 8'h00, 8'hFF, 8'h00, "[bar3] green  x=319 last");
        at(11'd320, 10'd100, 8'hFF, 8'h00, 8'hFF, "[bar4] magenta x=320 first");
        at(11'd360, 10'd100, 8'hFF, 8'h00, 8'hFF, "[bar4] magenta x=360 center");
        at(11'd399, 10'd100, 8'hFF, 8'h00, 8'hFF, "[bar4] magenta x=399 last");
        at(11'd400, 10'd100, 8'hFF, 8'h00, 8'h00, "[bar5] red    x=400 first");
        at(11'd440, 10'd100, 8'hFF, 8'h00, 8'h00, "[bar5] red    x=440 center");
        at(11'd479, 10'd100, 8'hFF, 8'h00, 8'h00, "[bar5] red    x=479 last");
        at(11'd480, 10'd100, 8'h00, 8'h00, 8'hFF, "[bar6] blue   x=480 first");
        at(11'd520, 10'd100, 8'h00, 8'h00, 8'hFF, "[bar6] blue   x=520 center");
        at(11'd559, 10'd100, 8'h00, 8'h00, 8'hFF, "[bar6] blue   x=559 last");
        at(11'd560, 10'd100, 8'h00, 8'h00, 8'h00, "[bar7] black  x=560 first");
        at(11'd600, 10'd100, 8'h00, 8'h00, 8'h00, "[bar7] black  x=600 center");
        at(11'd639, 10'd100, 8'h00, 8'h00, 8'h00, "[bar7] black  x=639 last");
        // 彩条与 y 无关（纯横向分带）—— 抽一条纵向验证
        at(11'd120, 10'd0,   8'hFF, 8'hFF, 8'h00, "[bar1] yellow  y=0");
        at(11'd120, 10'd479, 8'hFF, 8'hFF, 8'h00, "[bar1] yellow  y=479");

        // =====================================================================
        // ③ 图案 1：64 像素网格（白线黑底）
        //    关键：x[5:0]==0 是线，x[5:0]==63 不是线 —— 一次就能分辨周期是 64
        // =====================================================================
        pattern_sel = 3'd1;
        at(11'd0,   10'd0,   8'hFF, 8'hFF, 8'hFF, "[grid] origin line intersection");
        at(11'd64,  10'd0,   8'hFF, 8'hFF, 8'hFF, "[grid] vertical line x=64");
        at(11'd128, 10'd37,  8'hFF, 8'hFF, 8'hFF, "[grid] vertical line x=128");
        at(11'd576, 10'd37,  8'hFF, 8'hFF, 8'hFF, "[grid] vertical line x=576");
        at(11'd37,  10'd64,  8'hFF, 8'hFF, 8'hFF, "[grid] horizontal line y=64");
        at(11'd37,  10'd448, 8'hFF, 8'hFF, 8'hFF, "[grid] horizontal line y=448");
        at(11'd63,  10'd37,  8'h00, 8'h00, 8'h00, "[grid] x=63 is background");
        at(11'd37,  10'd63,  8'h00, 8'h00, 8'h00, "[grid] y=63 is background");
        at(11'd1,   10'd1,   8'h00, 8'h00, 8'h00, "[grid] x=1,y=1 background");
        at(11'd65,  10'd65,  8'h00, 8'h00, 8'h00, "[grid] x=65,y=65 background");

        // =====================================================================
        // ④ 图案 2/3/4：单色横向渐变，只有对应通道驱动，另两通道恒 0
        // =====================================================================
        pattern_sel = 3'd2;
        at(11'd0,   10'd0, 8'h00, 8'h00, 8'h00, "[grad-r] x=0    -> 0");
        at(11'd8,   10'd0, 8'h01, 8'h00, 8'h00, "[grad-r] x=8    -> 1");
        at(11'd320, 10'd0, 8'h28, 8'h00, 8'h00, "[grad-r] x=320  -> 0x28");
        at(11'd632, 10'd0, 8'h4F, 8'h00, 8'h00, "[grad-r] x=632  -> 0x4F");
        at(11'd639, 10'd0, 8'h4F, 8'h00, 8'h00, "[grad-r] x=639  -> 0x4F (clamped)");

        pattern_sel = 3'd3;
        at(11'd0,   10'd0, 8'h00, 8'h00, 8'h00, "[grad-g] x=0    -> 0");
        at(11'd8,   10'd0, 8'h00, 8'h01, 8'h00, "[grad-g] x=8    -> 1");
        at(11'd320, 10'd0, 8'h00, 8'h28, 8'h00, "[grad-g] x=320  -> 0x28");
        at(11'd639, 10'd0, 8'h00, 8'h4F, 8'h00, "[grad-g] x=639  -> 0x4F");

        pattern_sel = 3'd4;
        at(11'd0,   10'd0, 8'h00, 8'h00, 8'h00, "[grad-b] x=0    -> 0");
        at(11'd8,   10'd0, 8'h00, 8'h00, 8'h01, "[grad-b] x=8    -> 1");
        at(11'd320, 10'd0, 8'h00, 8'h00, 8'h28, "[grad-b] x=320  -> 0x28");
        at(11'd639, 10'd0, 8'h00, 8'h00, 8'h4F, "[grad-b] x=639  -> 0x4F");

        // 渐变与 y 无关
        at(11'd320, 10'd479, 8'h00, 8'h00, 8'h28, "[grad-b] y independent");

        // =====================================================================
        // ⑤ 图案 5：纯色（user_color 三通道拆分）
        // =====================================================================
        pattern_sel = 3'd5;
        user_color  = 24'h12_34_56;
        at(11'd0,   10'd0, 8'h12, 8'h34, 8'h56, "[solid] 0x123456");
        at(11'd639, 10'd479, 8'h12, 8'h34, 8'h56, "[solid] 0x123456 corner");

        user_color  = 24'hFF_00_FF;
        at(11'd200, 10'd200, 8'hFF, 8'h00, 8'hFF, "[solid] 0xFF00FF");

        user_color  = 24'h00_00_00;
        at(11'd200, 10'd200, 8'h00, 8'h00, 8'h00, "[solid] 0x000000");

        user_color  = 24'hFF_FF_FF;
        at(11'd200, 10'd200, 8'hFF, 8'hFF, 8'hFF, "[solid] 0xFFFFFF");

        // =====================================================================
        // ⑥ 图案 6：移动方块（唯一带时序状态的图案）
        //    起点 box_x=0, box_y=0, 尺寸 64 → 方块内 (0..63, 0..63)
        // =====================================================================
        pattern_sel = 3'd6;
        rst_n = 1'b0;
        repeat (2) @(posedge pixel_clk);
        rst_n = 1'b1;
        #1;

        at(11'd0,   10'd0,   8'h00, 8'hFF, 8'h00, "[box] top-left corner inside");
        at(11'd63,  10'd63,  8'h00, 8'hFF, 8'h00, "[box] bottom-right inside");
        at(11'd32,  10'd32,  8'h00, 8'hFF, 8'h00, "[box] center inside");
        at(11'd64,  10'd32,  8'h00, 8'h00, 8'h20, "[box] x=64 outside -> navy");
        at(11'd32,  10'd64,  8'h00, 8'h00, 8'h20, "[box] y=64 outside -> navy");
        at(11'd200, 10'd200, 8'h00, 8'h00, 8'h20, "[box] far outside -> navy");

        // --- 节拍：59 帧不动，第 60 帧才移动一步 ---
        // frame_cnt 的判定是 "== 59 时清零并移动"，故要打满 60 次帧末
        for (i = 0; i < 59; i = i + 1) frame_end;
        at(11'd0,   10'd0,   8'h00, 8'hFF, 8'h00, "[box] after 59 frames: still at (0,0)");
        at(11'd64,  10'd64,  8'h00, 8'h00, 8'h20, "[box] after 59 frames: (64,64) still outside");

        for (i = 0; i < 1; i = i + 1) frame_end;   // 第 60 帧
        at(11'd64,  10'd64,  8'h00, 8'hFF, 8'h00, "[box] step1: moved to (64,64)");
        at(11'd127, 10'd127, 8'h00, 8'hFF, 8'h00, "[box] step1: far corner inside");
        at(11'd63,  10'd63,  8'h00, 8'h00, 8'h20, "[box] step1: (63,63) now outside");

        // --- 正向累加：step2 (128,128) ... step6 (384,384) ---
        for (i = 0; i < 60*4; i = i + 1) frame_end;   // 到 step5
        at(11'd320, 10'd320, 8'h00, 8'hFF, 8'h00, "[box] step5: (320,320) inside");
        at(11'd383, 10'd383, 8'h00, 8'hFF, 8'h00, "[box] step5: (383,383) corner inside");

        for (i = 0; i < 60; i = i + 1) frame_end;     // step6
        at(11'd384, 10'd384, 8'h00, 8'hFF, 8'h00, "[box] step6: (384,384) inside");
        at(11'd447, 10'd447, 8'h00, 8'hFF, 8'h00, "[box] step6: (447,447) corner inside");

        // --- step7：y 触界（旧值 384 + 64 = 448 ≥ 416）→ dy 翻转为"减" ---
        for (i = 0; i < 60; i = i + 1) frame_end;
        at(11'd448, 10'd448, 8'h00, 8'hFF, 8'h00, "[box] step7: (448,448) inside");
        at(11'd511, 10'd479, 8'h00, 8'hFF, 8'h00, "[box] step7: reaches bottom edge");

        // --- step8：y 反向退回 384，x 仍正向到 512（证明两轴独立）---
        for (i = 0; i < 60; i = i + 1) frame_end;
        at(11'd512, 10'd384, 8'h00, 8'hFF, 8'h00, "[box] step8: (512,384) inside");
        at(11'd448, 10'd448, 8'h00, 8'h00, 8'h20, "[box] step8: y reversed, (448,448) outside");

        // --- step9：x 触界（旧值 512 + 64 = 576 ≥ 576）→ dx 翻转为"减" ---
        for (i = 0; i < 60; i = i + 1) frame_end;
        at(11'd576, 10'd320, 8'h00, 8'hFF, 8'h00, "[box] step9: (576,320) at right edge");
        at(11'd639, 10'd383, 8'h00, 8'hFF, 8'h00, "[box] step9: reaches right edge");

        // --- step10：x 反向退回 512 ---
        for (i = 0; i < 60; i = i + 1) frame_end;
        at(11'd512, 10'd256, 8'h00, 8'hFF, 8'h00, "[box] step10: (512,256) inside");
        at(11'd576, 10'd320, 8'h00, 8'h00, 8'h20, "[box] step10: (576,320) now outside");

        // =====================================================================
        // ⑥-b 不变量：方块在任意时刻都必须落在 640×480 画面内
        //
        //   规格语义是"方块在画面内往返移动"，所以任何一步画面里都必须能找
        //   到方块色。用 32 像素网格稀疏扫描（方块 64×64，网格必然命中）。
        //
        //   【本项检查抓到的真实 RTL 缺陷 —— 已修复，现为回归护栏】
        //   修复前 rtl/video/test_pattern_gen.v 的边界翻转判据是：
        //       if ((box_x + BOX_SIZE) >= (H_ACTIVE - BOX_SIZE)) box_dx <= 1'b0;
        //       else if (box_x == 0)                            box_dx <= 1'b1;
        //   回程时 box_dx 已为 0，箱体每次减 64。当 box_x 由 64 减到 0 的那一步，
        //   判据看的是**更新前**的 64（不等于 0），因此 dx 不会翻回 1；
        //   下一拍执行 0 - 64，11 位无符号下溢为 1984，方块飞出画面。
        //   y 轴同理，10 位下溢为 960。实测：y 在第 15 步溢出、x 在第 19 步溢出。
        //   已修复为 `else if (box_x <= BOX_SIZE)` / `box_y <= BOX_SIZE`。
        //
        //   这类缺陷只在回程末端暴露，正向走位测试完全看不出来——正因如此
        //   本项按"不变量扫描"而非"逐点核对"来写：每步用 32 像素网格扫全屏
        //   找方块色，找不到即判定方块飞出画面。修复后 40 步全部可见。
        // =====================================================================
        box_visible_seen = 1'b0;
        for (i = 0; i < 40; i = i + 1) begin
            for (gi = 0; gi < 480; gi = gi + 32) begin
                for (gj = 0; gj < 640; gj = gj + 32) begin
                    de       = 1'b1;
                    active_x = gj[10:0];
                    active_y = gi[9:0];
                    #1;
                    if ((rgb_r === 8'h00) && (rgb_g === 8'hFF) && (rgb_b === 8'h00))
                        box_visible_seen = 1'b1;
                end
            end
            checks = checks + 1;
            if (box_visible_seen) begin
                $display("PASS: [box] visible on screen at step %0d", i + 11);
            end else begin
                // 修复后任何一步都必须在画面内找到方块；找不到就是真失败
                // （历史缺陷：第 15 步起 y 下溢、第 19 步起 x 下溢，方块飞出画面）
                errors = errors + 1;
                $display("FAIL: [box] NOT visible anywhere on screen at step %0d (coord underflow?)", i + 11);
            end
            box_visible_seen = 1'b0;
            for (gi = 0; gi < 60; gi = gi + 1) frame_end;
        end

        // =====================================================================
        // ⑦ 图案 7：16 像素棋盘（x[4] ^ y[4]）
        // =====================================================================
        pattern_sel = 3'd7;
        at(11'd0,   10'd0,   8'h00, 8'h00, 8'h00, "[checker] (0,0) dark");
        at(11'd0,   10'd16,  8'hFF, 8'hFF, 8'hFF, "[checker] (0,16) light");
        at(11'd16,  10'd0,   8'hFF, 8'hFF, 8'hFF, "[checker] (16,0) light");
        at(11'd16,  10'd16,  8'h00, 8'h00, 8'h00, "[checker] (16,16) dark");
        at(11'd8,   10'd8,   8'h00, 8'h00, 8'h00, "[checker] (8,8) dark");
        at(11'd15,  10'd15,  8'h00, 8'h00, 8'h00, "[checker] (15,15) dark");
        at(11'd31,  10'd0,   8'hFF, 8'hFF, 8'hFF, "[checker] (31,0) light");
        at(11'd639, 10'd479, 8'h00, 8'h00, 8'h00, "[checker] (639,479) dark: bit4 xor = 0");

        // =====================================================================
        // ⑧ 未知 pattern_sel 走 default → 黑
        //    图案值是 3 位，0..7 已全覆盖；这里把 de=0 与 default 的语义分开验证：
        //    default 分支在 Verilog 里不可达（case 已穷举 3 bit），
        //    因此改为验证"de=0 时无论 pattern_sel 为何都黑"这一等价安全网。
        // =====================================================================
        de = 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            pattern_sel = i[2:0];
            active_x    = 11'd320;
            active_y    = 10'd240;
            expect_rgb(8'h00, 8'h00, 8'h00, "[default] black when de=0");
        end

        // =====================================================================
        // 收尾
        // =====================================================================
        $display("SUMMARY: checks=%0d errors=%0d known_issues=%0d",
                 checks, errors, known_issues);
        if (errors == 0) $display("ALL CHECKS PASSED: test_pattern_gen");
        else             $display("CHECKS FAILED: test_pattern_gen");
        $finish;
    end

endmodule
