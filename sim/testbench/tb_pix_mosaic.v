// ============================================================================
// 文件名  : tb_pix_mosaic.v
// 目的    : 验证 rtl/video/pix_mosaic.v（Key8 五档水平抽样）
//           与 rtl/video/ratio_map.v（Key9 五档屏占比映射）
// 权威依据: docs/plan_v2/ARCH_ADDENDUM_VIDEO_PATH.md §7.2 / §7.4 / §9.1
//           reports/plan_v2/T7_MUST_TEST.md  V-01 / V-02
//           captain 裁决（addendum :462-469 伪码落后一拍，必须组合旁路）
// ============================================================================
// 【两条红线（本 tb 的全部价值集中在这两条上）】
//
//   ① src_w = 640（Key8 默认档 / 应急钳位档）时，rgb565_out 必须**逐拍
//      === rgb565_in**。不是"近似"、不是"看起来对"，是 640 拍里每一拍
//      都逐位相等。
//      失败现象：整幅画面**左移 1 像素**，右侧补出 1 列旧像素。
//      不报错、不黑屏、综合与静态时序全绿 —— 只有逐拍比对才抓得到。
//
//   ② src_w < 640 时，一行（640 拍）内出现的**不同源列数必须恰等于
//      src_w**（320 / 400 / 512 / 576 各验一次）。失败现象：马赛克块宽
//      不均匀，长行累积后右侧内容被拉长或截断。
//
// 【为什么要有"参考模型"这条独立的断言（比 ① ② 更狠）】
//   ①② 只约束"数量"和"640 旁路"，不约束"抽样点落在哪一拍"。若实现把
//   抽样点整体挪半拍（例如用非阻塞赋值取更新前的 hold），数量仍对、
//   640 档也仍可能对，但画面已经错了。
//   本 tb 因此另外用一个**数学式**参考模型（与 DUT 的寄存器累加式写法
//   完全不同）逐拍比对：
//
//       第 i 个抽样点出现在列位置  p_i = ceil(i * 640 / src_w)
//
//   i = 0..src_w-1，一共 src_w 个抽样点，与 ② 的数量断言互相印证。
//   这条断言能抓"整体左移/右移一拍"以及任何抽样位置偏移。
//
// 【抽样语义说明（避免后来者误判为 bug）】
//   本实现是**隔点抽取**，不是"像素重复放大"：
//     src_w=320 时输出 640 拍 = in[0],in[0],in[2],in[2],in[4],in[4]...
//     （每个源列占 2 拍，共 320 个不同源列）
//   而不是 floor(n*src_w/640) 那种"前段重复、后段跳变"的放大式映射。
//   两者都是自洽语义（captain 已判定不讨论优劣），本 tb 只按
//   "不同源列数 == src_w + 抽样位置 == ceil 公式"来判，抽取式与放大式
//   的差异不影响任何一条断言的结论；本工程实际实现是抽取式。
// ============================================================================
`timescale 1ns / 1ps

module tb_pix_mosaic;

    // ========================================================================
    // 段 1: 时钟与复位
    //   周期 10 ns（100 MHz）只为加快仿真；本模块全部行为以"拍"为单位，
    //   与工程实际 25 MHz 视频时钟无关。
    // ========================================================================
    localparam integer CLK_HALF = 5;
    localparam integer LINE_PIX = 640;      // 输出域一行有效像素数

    reg clk;
    reg rst_n;

    always #CLK_HALF clk = ~clk;

    // ========================================================================
    // 段 2: pix_mosaic 端口
    // ========================================================================
    reg  [10:0] active_x;
    reg  [15:0] rgb565_in;
    reg         valid_in;
    wire [15:0] rgb565_out;
    wire        valid_out;

    reg  [15:0] src_w_port;             // 直接驱动模式下的源宽
    reg         map_mode;               // 1 = 源宽由 ratio_map.win_w 驱动
    wire [15:0] src_w_eff;

    // ========================================================================
    // 段 3: ratio_map 端口
    // ========================================================================
    reg  [2:0]  ratio_sel;
    wire [10:0] win_w;
    wire [9:0]  win_h;
    wire [10:0] win_off_x;
    wire [9:0]  win_off_y;

    // ========================================================================
    // 段 4: 记分板
    // ========================================================================
    integer pass_cnt;
    integer fail_cnt;

    // 行内观测缓冲
    reg        val_seen [0:2047];       // 按输出值低 11 位建索引，去重用
    integer    take_pos [0:1023];       // 观测到的抽样位置（块首列）
    integer    n_take;                  // 观测到的块数
    reg [15:0] out_prev;                // 上一拍的输出，用于块宽统计

    // ========================================================================
    // 段 5: DUT 例化
    // ========================================================================
    assign src_w_eff = map_mode ? {5'b0, win_w} : src_w_port;

    pix_mosaic u_pix_mosaic (
        .clk        (clk),
        .rst_n      (rst_n),
        .active_x   (active_x),
        .src_w      (src_w_eff),
        .rgb565_in  (rgb565_in),
        .valid_in   (valid_in),
        .rgb565_out (rgb565_out),
        .valid_out  (valid_out)
    );

    ratio_map u_ratio_map (
        .ratio_sel (ratio_sel),
        .win_w     (win_w),
        .win_h     (win_h),
        .win_off_x (win_off_x),
        .win_off_y (win_off_y)
    );

    // ========================================================================
    // 段 6: 记分板 task
    // ========================================================================
    task chk;
        input             cond;
        input [8*192-1:0] msg;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end
            else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // ---- 参考模型：第 i 个抽样点的列位置 = ceil(i * 640 / src_w) ----
    //   刻意写成整数除法的数学式，与 DUT 的"寄存器累加 + 阈值比较"实现
    //   在写法上完全无关；两边只有语义一致才可能同时通过。
    function integer ref_pos;
        input integer idx;
        input integer sw;
        begin
            ref_pos = (idx * LINE_PIX + sw - 1) / sw;
        end
    endfunction

    // ========================================================================
    // 段 7: 行测试 task（核心）
    //   跑满一行 640 拍，做 7 条断言：
    //     L1 不同源列数 == src_w          （红线 ②）
    //     L2 抽样位置逐拍吻合参考模型      （抓整体偏移一拍）
    //     L3 valid_out 与 valid_in 逐拍直通（零延迟）
    //     L4 块宽落在 [floor(640/w), ceil(640/w)]
    //     L5 输出编码合法（高 5 位为 0 且低 11 位 <= 639）
    //     L6 输出序列单调不减（源列索引不回退）
    //     L7 观测块数 == src_w
    //   开头还插入 4 拍"行间消隐"（active_x=0 / valid_in=0 / 数据为垃圾），
    //   用来证明消隐期写入 hold 的垃圾值不会漏到下一行首像素。
    // ========================================================================
    task run_line_checked;
        input [15:0] sw;                        // 直接模式的源宽（map_mode=1 时忽略）
        integer k;
        integer sw_x;
        integer dist;
        integer ref_err;
        integer vld_err;
        integer x_err;
        integer mono_err;
        integer run_len;
        integer exp_i;
        integer w_min;
        integer w_max;
        integer w_lo;
        integer w_hi;
        begin
            // ---- 期望源宽：端到端模式下取 ratio_map 的输出 ----
            if (map_mode) sw_x = win_w;
            else          sw_x = sw;
            src_w_port = sw_x;

            // ---- 清统计 ----
            dist     = 0;
            ref_err  = 0;
            vld_err  = 0;
            x_err    = 0;
            mono_err = 0;
            exp_i    = 0;
            run_len  = 0;
            w_min    = 9999;
            w_max    = 0;
            n_take   = 0;
            for (k = 0; k < 2048; k = k + 1) begin
                val_seen[k] = 1'b0;
            end

            // ---- 行间消隐 4 拍（模拟 video_timing_gen：active_x 归零、
            //      de 拉低、行间像素总线是垃圾）----
            for (k = 0; k < 4; k = k + 1) begin
                @(negedge clk);
                active_x  = 11'd0;
                rgb565_in = 16'hDEAD;
                valid_in  = 1'b0;
                #1;
                if (valid_out !== 1'b0) begin
                    vld_err = vld_err + 1;
                end
            end

            // ---- 行内 640 拍 ----
            for (k = 0; k < LINE_PIX; k = k + 1) begin
                @(negedge clk);
                active_x  = k[10:0];
                rgb565_in = {5'b0, k[10:0]};    // 每个源列一个唯一编码
                valid_in  = 1'b1;
                #1;                             // 本拍组合输出已稳定

                // (L3) valid 直通，零延迟
                if (valid_out !== valid_in) begin
                    vld_err = vld_err + 1;
                end

                // (L5) 输出编码合法性
                if (rgb565_out[15:11] === 5'b0) begin
                    val_seen[rgb565_out[10:0]] = 1'b1;
                end
                else begin
                    x_err = x_err + 1;
                end
                if ({5'b0, rgb565_out[10:0]} > 16'd639) begin
                    x_err = x_err + 1;
                end

                // (L2) 参考模型逐拍比对（双向：该抽必须抽、不该抽必须不抽）
                if ((exp_i < sw_x) && (k == ref_pos(exp_i, sw_x))) begin
                    if (rgb565_out !== rgb565_in) begin
                        if (ref_err == 0) begin
                            $display("  首个抽样位置差异: k=%0d 期望抽样(源列%0d) 实际为保持值 %04h",
                                     k, exp_i, rgb565_out);
                        end
                        ref_err = ref_err + 1;
                    end
                    exp_i = exp_i + 1;
                end
                else if (rgb565_out === rgb565_in) begin
                    if (ref_err == 0) begin
                        $display("  首个抽样位置差异: k=%0d 期望保持 实际发生了抽样", k);
                    end
                    ref_err = ref_err + 1;
                end

                // (L4)(L6) 块宽统计 + 单调性
                if (k > 0) begin
                    if (rgb565_out < out_prev) begin
                        mono_err = mono_err + 1;
                    end
                    if (rgb565_out == out_prev) begin
                        run_len = run_len + 1;
                    end
                    else begin
                        if (run_len < w_min) w_min = run_len;
                        if (run_len > w_max) w_max = run_len;
                        if (n_take < 1024) take_pos[n_take] = k;
                        n_take = n_take + 1;
                        run_len = 1;
                    end
                end
                else begin
                    run_len = 1;
                    take_pos[0] = 0;
                    n_take = 1;
                end
                out_prev = rgb565_out;
            end

            // 行尾最后一块结算
            if (run_len < w_min) w_min = run_len;
            if (run_len > w_max) w_max = run_len;

            // (L1) 不同源列数
            for (k = 0; k < 640; k = k + 1) begin
                if (val_seen[k]) dist = dist + 1;
            end

            w_lo = LINE_PIX / sw_x;
            w_hi = (LINE_PIX + sw_x - 1) / sw_x;

            $display("");
            $display("--- 行测试: src_w=%0d  (模式=%0s) ---",
                     sw_x, map_mode ? "ratio_map 端到端" : "直接驱动");
            $display("    不同源列=%0d  块数=%0d  块宽=%0d..%0d(期望%0d..%0d)  ref_err=%0d",
                     dist, n_take, w_min, w_max, w_lo, w_hi, ref_err);
            if (n_take >= 12) begin
                $display("    实测抽样位置[0..11] = %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                         take_pos[0],  take_pos[1],  take_pos[2],  take_pos[3],
                         take_pos[4],  take_pos[5],  take_pos[6],  take_pos[7],
                         take_pos[8],  take_pos[9],  take_pos[10], take_pos[11]);
            end

            chk(dist == sw_x,                 "L1 行内不同源列数 == src_w");
            chk(ref_err == 0,                 "L2 抽样位置逐拍吻合 ceil(i*640/src_w) 参考模型");
            chk(vld_err == 0,                 "L3 valid_out 逐拍直通 valid_in（含消隐段）");
            chk((w_min >= w_lo) && (w_max <= w_hi), "L4 块宽落在 floor/ceil(640/src_w) 区间");
            chk(x_err == 0,                   "L5 输出编码合法（高 5 位 0 且低 11 位 <= 639）");
            chk(mono_err == 0,                "L6 输出源列索引单调不减");
            chk(n_take == sw_x,               "L7 观测块数 == src_w");
        end
    endtask

    // ========================================================================
    // 段 8: 恒等专项 task（红线 ①）
    //   src_w=640 时 640 拍逐拍 ===，不复用 run_line_checked 的统计逻辑，
    //   单独一条硬断言，失败信息给到具体拍号与两个值。
    // ========================================================================
    task run_line_identity;
        input [15:0] sw;
        integer k;
        integer err;
        begin
            map_mode   = 1'b0;
            src_w_port = sw;
            err = 0;
            $display("");
            $display("--- 恒等专项: src_w=%0d 逐拍比对 640 拍 ---", sw);
            for (k = 0; k < LINE_PIX; k = k + 1) begin
                @(negedge clk);
                active_x  = k[10:0];
                rgb565_in = {5'b0, k[10:0]};
                valid_in  = 1'b1;
                #1;
                if (rgb565_out !== rgb565_in) begin
                    if (err < 5) begin
                        $display("    恒等违例: k=%0d 期望 %04h 实际 %04h",
                                 k, rgb565_in, rgb565_out);
                    end
                    err = err + 1;
                end
            end
            chk(err == 0, "I1 src_w=640 逐拍 640/640 拍 === rgb565_in（V-01）");
        end
    endtask

    // ========================================================================
    // 段 9: ratio_map 五档检查（纯组合，无时钟）
    // ========================================================================
    task check_ratio;
        input [2:0]  sel;
        input [10:0] ew;
        input [9:0]  eh;
        input [10:0] eox;
        input [9:0]  eoy;
        integer area_pm;            // 面积千分比，integer 才能装下 640*480*1000
        begin
            ratio_sel = sel;
            #1;
            if ((win_w !== ew) || (win_h !== eh) || (win_off_x !== eox) || (win_off_y !== eoy)) begin
                $display("    档%0d 期望 %0dx%0d@(%0d,%0d) 实际 %0dx%0d@(%0d,%0d)",
                         sel, ew, eh, eox, eoy, win_w, win_h, win_off_x, win_off_y);
            end
            area_pm = (win_w * win_h * 1000) / 307200;
            $display("--- ratio_map 档%0d: %0dx%0d 偏移(%0d,%0d) 面积 %0d.%0d%% ---",
                     sel, win_w, win_h, win_off_x, win_off_y, area_pm / 10, area_pm % 10);
            chk(win_w === ew,          "R1 win_w 与档位表一致");
            chk(win_h === eh,          "R2 win_h 与档位表一致");
            chk(win_off_x === eox,     "R3 win_off_x 与档位表一致");
            chk(win_off_y === eoy,     "R4 win_off_y 与档位表一致");
            chk((win_off_x * 2 + win_w) == 640, "R5 水平居中不变式 2*off_x+win_w==640");
            chk((win_off_y * 2 + win_h) == 480, "R6 垂直居中不变式 2*off_y+win_h==480");
        end
    endtask

    // ========================================================================
    // 段 10: 主激励
    // ========================================================================
    integer s;

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        active_x  = 11'd0;
        src_w_port = 16'd640;
        rgb565_in = 16'h0000;
        valid_in  = 1'b0;
        map_mode  = 1'b0;
        ratio_sel = 3'd4;
        pass_cnt  = 0;
        fail_cnt  = 0;
        out_prev  = 16'h0000;

        $display("==============================================================");
        $display(" tb_pix_mosaic : pix_mosaic + ratio_map");
        $display(" 红线 ① src_w=640 逐拍恒等   ② 不同源列数 == src_w");
        $display("==============================================================");

        // ---- 复位释放 ----
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ====================================================================
        // R 组: ratio_map 五档（纯组合，档位表 = ARCH §7.4 / KEYMAP §Key9）
        // ====================================================================
        $display("");
        $display("=== R 组: ratio_map 五档映射 ===");
        check_ratio(3'd0, 11'd320, 10'd240, 11'd160, 10'd120);
        check_ratio(3'd1, 11'd400, 10'd300, 11'd120, 10'd90);
        check_ratio(3'd2, 11'd480, 10'd360, 11'd80,  10'd60);
        check_ratio(3'd3, 11'd560, 10'd420, 11'd40,  10'd30);
        check_ratio(3'd4, 11'd640, 10'd480, 11'd0,   10'd0);

        // 未定义档位（ratio_sel = 5/6/7）必须落到"全屏不裁切"，不能落成
        // 0x0 —— 后者会让 image_window_mask 把整个画面判成窗口外而全黑。
        $display("");
        $display("=== R 组: 未定义档位 default 行为 ===");
        check_ratio(3'd5, 11'd640, 10'd480, 11'd0, 10'd0);
        check_ratio(3'd7, 11'd640, 10'd480, 11'd0, 10'd0);

        // ====================================================================
        // V 组: pix_mosaic 五档抽样（红线 ②）
        //   顺序刻意从 640 开始 —— 默认档先过，任何"整体偏移"最先暴露。
        // ====================================================================
        $display("");
        $display("=== V 组: pix_mosaic 五档抽样（直接驱动） ===");
        map_mode = 1'b0;
        run_line_checked(16'd640);
        run_line_checked(16'd576);
        run_line_checked(16'd512);
        run_line_checked(16'd400);
        run_line_checked(16'd320);

        // ====================================================================
        // I 组: 红线 ① 恒等专项（单独硬断言）
        // ====================================================================
        $display("");
        $display("=== I 组: src_w=640 逐拍恒等（V-01） ===");
        run_line_identity(16'd640);

        // ====================================================================
        // S 组: 行间切换档位（模拟 Key8 连按 + 消隐期换档的重同步）
        //   每行都必须立刻按新档位抽样，不允许残留上一行的累加器状态。
        // ====================================================================
        $display("");
        $display("=== S 组: 行间切换档位重同步 ===");
        map_mode = 1'b0;
        run_line_checked(16'd400);
        run_line_checked(16'd320);
        run_line_checked(16'd576);
        run_line_checked(16'd640);

        // ====================================================================
        // E 组: 端到端 —— ratio_map.win_w 直接驱动 pix_mosaic.src_w
        //   验证两个模块的"源宽"语义天然一致（win_w 即 src_w，无需另设端口）
        // ====================================================================
        $display("");
        $display("=== E 组: ratio_map -> pix_mosaic 端到端联动 ===");
        map_mode = 1'b1;
        for (s = 0; s < 5; s = s + 1) begin
            ratio_sel = s[2:0];
            #1;
            run_line_checked(16'd0);
        end
        map_mode = 1'b0;

        // ====================================================================
        // N 组: 复位行为
        // ====================================================================
        $display("");
        $display("=== N 组: 复位 ===");
        valid_in = 1'b0;
        active_x = 11'd0;
        rst_n    = 1'b0;
        repeat (3) @(negedge clk);
        #1;
        chk(valid_out === 1'b0, "N1 复位期间 valid_out 为 0");
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        run_line_checked(16'd320);

        // ====================================================================
        // 结算
        // ====================================================================
        $display("");
        $display("==============================================================");
        $display("SUMMARY: checks=%0d pass=%0d fail=%0d", pass_cnt + fail_cnt, pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: pix_mosaic");
        end
        else begin
            $display("CHECKS FAILED: pix_mosaic");
        end
        $display("==============================================================");
        $finish;
    end

endmodule
