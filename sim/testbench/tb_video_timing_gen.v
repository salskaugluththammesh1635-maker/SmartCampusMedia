// =============================================================================
// tb_video_timing_gen.v —— VESA 640×480@60 视频时序发生器自检测试平台
// -----------------------------------------------------------------------------
// 【被评测对象】
//   rtl/video/video_timing_gen.v：产生 hs / vs / de / active_x / active_y /
//   vblank / frame_start 七路时序信号，是整条显示链路的"时间基准"。
//
// 【被测的全部功能点】（对应 RTL 的 5 个 always 块 + 4 条组合译码）
//   ① h_cnt 行计数器：0..799 循环（H_TOTAL = 640+16+96+48 = 800）
//   ② v_cnt 场计数器：0..524 循环，仅行末递增（V_TOTAL = 480+10+2+33 = 525）
//   ③ hs 行同步：负极性，低电平在 h_cnt ∈ [0,96)
//   ④ vs 场同步：负极性，低电平在 v_cnt ∈ [0,2)（= 2 整行 = 1600 拍）
//   ⑤ de 数据有效：h_act && v_act 打一拍寄存
//   ⑥ active_x / active_y：与 de 严格同拍寄存（本项目早期踩过"整幅右移 1 像素"
//      的相位 bug，本平台的核心判据之一就是钉死这个同拍关系）
//   ⑦ vblank 场消隐：有效区外为 1
//   ⑧ frame_start：v_cnt = 34 的行末发一拍（有效区首行之前一个像素位置）
//   ⑨ HS_POL / VS_POL 参数：用第二个实例化反转极性，验证"两实例严格互补"
//
// 【测量窗口怎么对齐 —— 整个平台的地基】
//   frame_start 在 v_cnt=34 / h_cnt=799 发出并寄存，因此 frame_start=1 的
//   那一拍 h_cnt 已经归 0、v_cnt 已经变成 35 = 有效区首行。从它**下一拍**
//   开始，恰好是 480 行 × 800 拍 = 384000 拍的有效区窗口。窗口内可下精确断言：
//     · de 总数 = 307200（= 640×480）      · de 上升沿数 = 480（= 行数）
//     · 每行 de 拍数 = 640                  · 行首 active_x = 0
//     · 行内 active_x 逐拍 +1               · 行号 active_y = 0..479
//     · vblank 恒 0                          · hs 每行一个 96 拍低脉冲
//   窗口结束后（此刻 v_cnt 正好走到 515 = 有效区末行末）依次是 10 行前肩
//   和 2 行场同步，因此**窗口后的第一个 vs 低电平就是完整的一帧同步脉冲**，
//   正好用来测宽度 = 1600 拍。这也是本平台把 hs 与 vs 分开测量阶段的原因：
//   vs 在窗口内恒为高，测不到；hs 在窗口内每行都有，窗口外反而要重算期望值。
//
// 【为什么这些判据是"决定性"的】
//   任何一处相位错开一拍（de 与坐标不同拍、hs 位置偏移、帧长算错一个像素），
//   都会让上面某条计数或递增关系直接不成立。这不是"看起来对"，
//   而是"差一拍就必错"。
//
// 【仿真开销】
//   窗口 384000 拍 + 帧首尾 ≈ 45 万拍，像素周期取 10ns（只影响波形时间轴，
//   不影响判据），ModelSim 十几秒内跑完。
// =============================================================================
`timescale 1ns / 1ps

module tb_video_timing_gen;

    // ---- 时序常量（与 RTL 默认参数一致）------------------------------------
    localparam PIX_HALF   = 5;                 // 像素周期 10ns（仿真速度考量）
    localparam H_ACTIVE   = 640;
    localparam H_FP       = 16;
    localparam H_SYNC     = 96;
    localparam H_BP       = 48;
    localparam V_ACTIVE   = 480;
    localparam V_FP       = 10;
    localparam V_SYNC     = 2;
    localparam V_BP       = 33;

    localparam H_TOTAL    = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 800
    localparam V_TOTAL    = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525
    localparam FRAME_CYC  = H_TOTAL * V_TOTAL;                 // 420000
    localparam WIN_CYC    = H_ACTIVE * V_ACTIVE;               // 307200 拍有效像素
    localparam WIN_LINES  = V_ACTIVE * H_TOTAL;                // 384000 拍窗口
    localparam VS_WIDTH   = V_SYNC * H_TOTAL;                  // 1600 拍低电平

    // ---- 时钟与复位 --------------------------------------------------------
    reg pixel_clk;
    initial begin pixel_clk = 1'b0; forever #PIX_HALF pixel_clk = ~pixel_clk; end

    reg rst_n;

    // ---- 被测模块（默认极性 HS_POL=0 / VS_POL=0）--------------------------
    wire        hs, vs;
    wire        de;
    wire [10:0] active_x;
    wire [9:0]  active_y;
    wire        vblank;
    wire        frame_start;

    video_timing_gen u_dut (
        .pixel_clk   (pixel_clk),
        .rst_n       (rst_n),
        .hs          (hs),
        .vs          (vs),
        .de          (de),
        .active_x    (active_x),
        .active_y    (active_y),
        .vblank      (vblank),
        .frame_start (frame_start)
    );

    // ---- 极性对照实例（HS_POL=1 / VS_POL=1）-------------------------------
    // 与 u_dut 同时钟同复位 → 内部计数器完全同步 → 两路同步信号必须严格互补
    wire        hs_pol, vs_pol;

    video_timing_gen #(
        .HS_POL (1'b1),
        .VS_POL (1'b1)
    ) u_pol (
        .pixel_clk   (pixel_clk),
        .rst_n       (rst_n),
        .hs          (hs_pol),
        .vs          (vs_pol),
        .de          (),
        .active_x    (),
        .active_y    (),
        .vblank      (),
        .frame_start ()
    );

    // ---- 计分 --------------------------------------------------------------
    integer checks;
    integer errors;
    initial begin checks = 0; errors = 0; end

    // ---- 阶段 A：有效区窗口统计（mon_en 控制）-----------------------------
    reg     mon_en;
    reg     mon_done;
    integer mon_cnt;
    integer de_cnt;
    integer row_cnt;
    integer row_de;             // 当前行已统计的 de 拍数
    reg     row_started;        // 本行是否已经开始（首行行首不能判行长）
    integer exp_row;
    reg [9:0] exp_row_v;
    reg [10:0] x_prev;
    reg     de_d;
    integer x_start_err;
    integer x_step_err;
    integer y_err;
    integer row_len_err;
    integer vblank_hi;
    integer x_max;

    // 窗口内的 hs 统计
    // hs_armed：见一次 hs 高电平后才开始测宽度。
    // 因为窗口起点落在某一行的 h_cnt=0/1，此刻 hs 已处于低电平——这是被窗口
    // 截断的残段，不能当成完整脉冲来量宽度。
    reg     hs_armed;
    integer hs_low_w;
    integer hs_bad_w;
    integer hs_pulse_w;

    initial begin
        mon_en      = 1'b0;
        mon_done    = 1'b0;
        mon_cnt     = 0;
        de_cnt      = 0;
        row_cnt     = 0;
        row_de      = 0;
        row_started = 1'b0;
        exp_row     = 0;
        exp_row_v   = 10'd0;
        x_prev      = 11'd0;
        de_d        = 1'b0;
        x_start_err = 0;
        x_step_err  = 0;
        y_err       = 0;
        row_len_err = 0;
        vblank_hi   = 0;
        x_max       = 0;
        hs_armed    = 1'b0;
        hs_low_w    = 0;
        hs_bad_w    = 0;
        hs_pulse_w  = 0;
    end

    // ---- 阶段 B：窗口后的 vs 统计（vs_en 控制）----------------------------
    reg     vs_en;
    reg     vs_done;
    integer vs_low_run;
    integer vs_width_meas;
    integer vs_fall_cnt;
    integer vs_pulse_cnt;

    initial begin
        vs_en        = 1'b0;
        vs_done      = 1'b0;
        vs_low_run   = 0;
        vs_width_meas= -1;
        vs_fall_cnt  = 0;
        vs_pulse_cnt = 0;
    end

    // ---- 全局：帧节拍与极性互补 --------------------------------------------
    integer cycle_cnt;
    integer frame_start_cnt;
    integer fs_first;
    integer fs_last;
    integer pol_err;

    initial begin
        cycle_cnt       = 0;
        frame_start_cnt = 0;
        fs_first        = -1;
        fs_last         = -1;
        pol_err         = 0;
    end

    // ---- 主监视器 ----------------------------------------------------------
    always @(posedge pixel_clk) begin
        cycle_cnt = cycle_cnt + 1;

        // frame_start 计数与时刻（跨帧自由运行）
        if (frame_start === 1'b1) begin
            frame_start_cnt = frame_start_cnt + 1;
            if (fs_first < 0) fs_first = cycle_cnt;
            fs_last = cycle_cnt;
        end

        // 极性互补：u_pol 必须与 u_dut 严格相反（全程零容忍）
        if (hs !== ~hs_pol) pol_err = pol_err + 1;
        if (vs !== ~vs_pol) pol_err = pol_err + 1;

        // ---- 阶段 A：窗口内 ----
        if (mon_en) begin
            // de / 坐标 / vblank
            if (de === 1'b1) begin
                de_cnt = de_cnt + 1;
                if (active_x > x_max) x_max = active_x;

                if (de_d !== 1'b1) begin
                    // 行首
                    row_cnt = row_cnt + 1;
                    if (active_x !== 11'd0)     x_start_err = x_start_err + 1;
                    if (row_started && (row_de !== H_ACTIVE))
                                                row_len_err = row_len_err + 1;
                    if (active_y !== exp_row_v) y_err       = y_err + 1;
                    exp_row     = exp_row + 1;
                    exp_row_v   = exp_row_v + 10'd1;
                    row_de      = 0;
                    row_started = 1'b1;
                end else begin
                    if (active_x !== (x_prev + 11'd1)) x_step_err = x_step_err + 1;
                end

                row_de = row_de + 1;
                x_prev = active_x;
            end else begin
                // 窗口完全落在有效区内，场消隐不该出现
                if (vblank !== 1'b0) vblank_hi = vblank_hi + 1;
            end

            // 窗口内 hs：每行一个低脉冲，宽度必须精确 96 拍
            // 窗口首拍 h_cnt=0/1 时 hs 已经是低电平（被窗口截断的残段），
            // 因此要先见到一次高电平（hs_armed=1）才开始计量完整脉冲
            if (hs === 1'b0) begin
                if (hs_armed) hs_low_w = hs_low_w + 1;
            end else begin
                if (hs_armed && (hs_low_w > 0)) begin
                    hs_pulse_w = hs_pulse_w + 1;
                    if (hs_low_w !== H_SYNC) hs_bad_w = hs_bad_w + 1;
                end
                hs_low_w = 0;
                hs_armed = 1'b1;
            end

            de_d    = de;
            mon_cnt = mon_cnt + 1;
            if (mon_cnt == WIN_LINES) begin
                mon_en   = 1'b0;
                mon_done = 1'b1;
                vs_en    = 1'b1;   // 窗口结束后开始接管 vs 测量
            end
        end

        // ---- 阶段 B：窗口后测 vs ----
        // 窗口结束时 v_cnt = 515（有效区末行末），之后 10 行前肩 + 2 行同步，
        // 因此这里遇到的第一个 vs 低电平就是完整的一帧同步脉冲
        if (vs_en) begin
            if (vs === 1'b0) begin
                if (vs_low_run == 0) vs_fall_cnt = vs_fall_cnt + 1;
                vs_low_run = vs_low_run + 1;
            end else begin
                if (vs_low_run > 0) begin
                    vs_width_meas = vs_low_run;
                    vs_pulse_cnt  = vs_pulse_cnt + 1;
                    vs_low_run    = 0;
                    if (vs_pulse_cnt >= 2) begin
                        vs_en   = 1'b0;
                        vs_done = 1'b1;
                    end
                end
            end
        end
    end

    // ---- 通用判据任务 ------------------------------------------------------
    task expect_int;
        input integer    got;
        input integer    exp;
        input [8*56-1:0] label;
        begin
            checks = checks + 1;
            if (got === exp) begin
                $display("PASS: %0s | %0d", label, got);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s | got=%0d expected=%0d", label, got, exp);
            end
        end
    endtask

    task expect_zero;
        input integer    got;
        input [8*56-1:0] label;
        begin
            checks = checks + 1;
            if (got === 0) begin
                $display("PASS: %0s | no violation", label);
            end else begin
                errors = errors + 1;
                $display("FAIL: %0s | %0d violations", label, got);
            end
        end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    initial begin
        $display("=== tb_video_timing_gen : VESA 640x480@60 timing ===");

        rst_n = 1'b0;
        repeat (20) @(posedge pixel_clk);

        // 1) 复位态：所有时序信号必须静止在安全值
        checks = checks + 1;
        if ((de === 1'b0) && (active_x === 11'd0) && (active_y === 10'd0) &&
            (vblank === 1'b1) && (frame_start === 1'b0)) begin
            $display("PASS: [reset] de=0 x=0 y=0 vblank=1 frame_start=0");
        end else begin
            errors = errors + 1;
            $display("FAIL: [reset] de=%b x=%0d y=%0d vblank=%b fs=%b",
                     de, active_x, active_y, vblank, frame_start);
        end

        rst_n = 1'b1;

        // 2) 等第一个 frame_start 作为窗口对齐点，其下一拍即有效区首行首拍
        wait (frame_start === 1'b1);
        @(posedge pixel_clk);
        mon_en = 1'b1;

        wait (mon_done);

        // ---- 阶段 A 判据（有效区窗口）----
        expect_int(de_cnt, WIN_CYC,   "[active-area] total de pixels per frame");
        expect_int(row_cnt, V_ACTIVE, "[active-area] de rising edges (rows)");
        expect_zero(x_start_err,      "[active-x] row start always 0");
        expect_zero(x_step_err,       "[active-x] increments by 1 inside a row");
        expect_zero(y_err,            "[active-y] row index 0..479");
        expect_zero(row_len_err,      "[de] each row has 640 valid pixels");
        expect_int(x_max, H_ACTIVE-1, "[active-x] max column index");
        expect_zero(vblank_hi,        "[vblank] stays 0 inside active area");
        expect_zero(hs_bad_w,         "[hs] low pulse width is exactly 96");
        // 窗口覆盖 480 行，但第一行的 hs 低段被窗口起点截断（不计量），
        // 因此完整脉冲数为 479 —— 这不是缺脉冲，而是窗口边界的必然结果
        expect_int(hs_pulse_w, V_ACTIVE-1, "[hs] complete pulses per 480-line window");

        // ---- 阶段 B 判据（窗口后的 vs）----
        wait (vs_done);
        expect_int(vs_width_meas, VS_WIDTH, "[vs] low pulse width is 2 full lines");
        expect_int(vs_pulse_cnt, 2,         "[vs] two pulses observed after window");

        // ---- 跨帧判据 ----
        // 两次 frame_start 间隔 = 800 × 525 = 420000 拍（此时已过 2 帧）
        expect_int(fs_last - fs_first, FRAME_CYC,
                   "[frame] period between frame_start pulses");
        expect_zero(pol_err, "[polarity] HS_POL/VS_POL inversion is exact");

        // frame_start 单拍宽（不是长脉冲）
        checks = checks + 1;
        if (frame_start === 1'b0) begin
            $display("PASS: [frame_start] single-cycle pulse (not held)");
        end else begin
            errors = errors + 1;
            $display("FAIL: [frame_start] pulse still high after one cycle");
        end

        // 3) 复位可中途打断：计数器必须归零、输出回安全态
        rst_n = 1'b0;
        repeat (3) @(posedge pixel_clk);
        checks = checks + 1;
        if ((de === 1'b0) && (active_x === 11'd0) && (active_y === 10'd0) &&
            (vblank === 1'b1)) begin
            $display("PASS: [mid-reset] counters cleared, outputs safe");
        end else begin
            errors = errors + 1;
            $display("FAIL: [mid-reset] de=%b x=%0d y=%0d vblank=%b",
                     de, active_x, active_y, vblank);
        end
        rst_n = 1'b1;

        // 4) 复位后 frame_start 必须能重新出现（自恢复）
        @(posedge pixel_clk);
        wait (frame_start === 1'b1);
        $display("PASS: [resume] frame_start reappears after reset");
        checks = checks + 1;

        // 5) 收尾
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: video_timing_gen");
        else             $display("CHECKS FAILED: video_timing_gen");
        $finish;
    end

endmodule
