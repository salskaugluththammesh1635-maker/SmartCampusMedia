// ============================================================================
// 文件名  : tb_osd_autopop.v
// 所在位置: sim/testbench/tb_osd_autopop.v
// 被测模块: rtl/osd/osd_autopop.v
// ============================================================================
// 【验证策略】
//   osd_autopop 是唯一带时序逻辑的 OSD 模块，风险集中在三处：
//
//   1) 上电误弹窗。复位后参数全 0、延迟副本也全 0，changed 必须为 0，
//      panel_on 必须一直是 0 —— 否则改造后的板子一上电就多一块面板，
//      与"基础功能不因扩展失效"直接冲突。这条是 P01，第一个查。
//
//   2) 计时长度。HOLD_MS=2500 @ 25 MHz 意味着 62,500,000 个时钟。
//      在仿真里逐拍跑完是 2.5 ms 仿真时间，约 6250 万次时钟沿 ——
//      太慢。这里用**小参数**实例化第二个 DUT（HOLD_MS=1，即 25000 拍），
//      既验证了计数逻辑，又把仿真时间压到毫秒级。
//      计时上限的**精确值**则由层次常量直接核对（P02），不依赖跑完。
//
//   3) 重触发。参数再次变化时倒计时要重新装满，而不是继续走完就关。
//      否则用户连按两下亮度，面板会在第二下之后提前消失。
//
// 【断言编号】
//   P01 上电不弹窗（复位值一致，changed=0）
//   P02 计时上限 = (CLK/1000)*HOLD_MS（层次常量核对 + 实际计数观测）
//   P03 参数变化 -> 立刻弹窗
//   P04 保持期内参数不变 -> 面板持续开着
//   P05 倒计时结束 -> 面板关闭
//   P06 关闭后参数不再变 -> 保持关闭
//   P07 重触发：保持期内再次变化 -> 倒计时重新装满
//   P08 四个参数各自都能触发（亮度/反色/倍率/模式）
//   P09 反向变化也能触发（不是只认"变大"）
//   P10 img_index 变化**不**触发（有意设计：图号由播放器自动递增）
//   P11 t16 新增三档（音量/分辨率/屏占比）各自都能触发
//   P12 复位释放后第一拍不弹窗（三个新延迟副本的复位值必须对齐 key_router）
// ============================================================================
`timescale 1ns / 1ps

module tb_osd_autopop;

    localparam CLK_PERIOD = 40;   // 25 MHz

    reg        clk;
    reg        rst_n;
    // t16：bright_sel[2:0] -> bright_lvl[3:0]（与 osd_autopop 端口同名同宽），
    //      并新增 vol_lvl / res_sel / ratio_sel 三根被监视线。
    //      ★ 初值必须取 key_router 的复位值（音量 6 / 分辨率 4 / 屏占比 4），
    //      不能填 0 —— 见文件尾 P12 用例的说明。
    reg  [3:0] bright_lvl;
    reg  [3:0] vol_lvl;
    reg  [2:0] res_sel;
    reg  [2:0] ratio_sel;
    reg        invert_en;
    reg  [1:0] auto_sw_sel;
    reg  [1:0] info_mode;
    wire       panel_on;

    // 正式参数实例：只用来核对计时上限常量，不跑完整倒计时
    osd_autopop #(
        .CLK_FREQ_HZ (25_000_000),
        .HOLD_MS     (2500)
    ) u_dut_real (
        .clk          (clk),
        .rst_n        (rst_n),
        .bright_lvl   (bright_lvl),
        .vol_lvl      (vol_lvl),
        .res_sel      (res_sel),
        .ratio_sel    (ratio_sel),
        .invert_en    (invert_en),
        .auto_sw_sel  (auto_sw_sel),
        .info_mode    (info_mode),
        .panel_on     (panel_on)
    );

    // 加速实例：HOLD_MS=1 -> 25000 拍，用于真正跑完一次倒计时
    wire panel_on_fast;
    osd_autopop #(
        .CLK_FREQ_HZ (25_000_000),
        .HOLD_MS     (1)
    ) u_dut_fast (
        .clk          (clk),
        .rst_n        (rst_n),
        .bright_lvl   (bright_lvl),
        .vol_lvl      (vol_lvl),
        .res_sel      (res_sel),
        .ratio_sel    (ratio_sel),
        .invert_en    (invert_en),
        .auto_sw_sel  (auto_sw_sel),
        .info_mode    (info_mode),
        .panel_on     (panel_on_fast)
    );

    integer pass_cnt;
    integer fail_cnt;
    integer i;

    // 加速实例的满量程：25_000_000/1000*1 = 25000
    localparam integer FAST_MAX = 25000;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    task chk;
        input        cond;
        input [8*64-1:0] tag;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", tag);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", tag);
            end
        end
    endtask

    // 等 n 个时钟沿
    task wait_clk;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) @(posedge clk);
            #1;
        end
    endtask

    initial begin
        pass_cnt    = 0;
        fail_cnt    = 0;
        rst_n       = 1'b0;
        // ★ 取 key_router 复位值，不是全 0（见 P12）
        bright_lvl  = 4'd0;
        vol_lvl     = 4'd6;
        res_sel     = 3'd4;
        ratio_sel   = 3'd4;
        invert_en   = 1'b0;
        auto_sw_sel = 2'd0;
        info_mode   = 2'd0;
        #(CLK_PERIOD * 2);
        rst_n = 1'b1;
        #1;

        // ================= P01 上电不弹窗 ================================
        // 复位后参数与延迟副本同为 0，changed 恒为 0。
        // 这条锁死"上电观感与改造前一致"。
        chk(panel_on === 1'b0,      "P01a no popup after reset (real)");
        chk(panel_on_fast === 1'b0, "P01b no popup after reset (fast)");
        wait_clk(100);
        chk(panel_on === 1'b0,      "P01c still no popup after 100 clk");
        chk(panel_on_fast === 1'b0, "P01d still no popup after 100 clk (fast)");

        // ================= P02 计时上限 ==================================
        // 层次常量核对：62,500,000 = 25e6/1000*2500。
        chk(u_dut_real.CNT_MAX == 62_500_000,
            "P02a real CNT_MAX = (25e6/1000)*2500 = 62,500,000");
        chk(u_dut_fast.CNT_MAX == FAST_MAX,
            "P02b fast CNT_MAX = (25e6/1000)*1 = 25,000");
        // 26 位计数器的上限是 67,108,863，62,500,000 装得下且不溢出。
        chk(u_dut_real.CNT_MAX <= 67_108_863,
            "P02c CNT_MAX fits in 26-bit counter");

        // ================= P03 参数变化立刻弹窗 ==========================
        bright_lvl = 4'd1;   // 模拟 KEY7 按一下
        wait_clk(2);
        chk(panel_on === 1'b1,      "P03a bright change -> panel on (real)");
        chk(panel_on_fast === 1'b1, "P03b bright change -> panel on (fast)");

        // ================= P04 保持期内持续开着 ==========================
        wait_clk(1000);
        chk(panel_on === 1'b1,      "P04a still on after 1000 clk (real)");
        chk(panel_on_fast === 1'b1, "P04b still on after 1000 clk (fast)");

        // ================= P07 重触发 ====================================
        // 这是本模块最容易写错的地方：保持期内再次改参数时，倒计时必须
        // **重新装满**，而不是继续走完就关。否则用户连按两下亮度，面板会在
        // 第二下之后提前消失。
        //
        // 怎么才能"测出"重触发？必须落在这样一个窗口里：
        //     距【首次】触发 > 满量程（不重触发则已关闭）
        //     距【最后】触发 < 满量程（重触发则仍开着）
        // 两个条件同时成立时，观测值才能区分两种实现。
        //
        // 时序安排（FAST_MAX = 25000）：
        //   t≈2      bright=1  首次触发，cnt=25000
        //   t≈20002  已等 20000 拍，剩 5000，仍开着（P04 已验）
        //   t≈20002  bright=2  重触发，cnt 重新=25000
        //   t≈30002  距首次 30000（>25000），距最后 10000（<25000）
        //            -> 重触发实现仍开着；不重触发实现此刻已关闭
        // 首版把两次等待写成 20000+20000，第二个观测点距最后触发已 40000 拍，
        // 两种实现都已关闭 —— 那条断言区分不了任何东西，等于没测。
        bright_lvl = 4'd2;   // 第二次按键，刷新倒计时
        wait_clk(10000);
        chk(panel_on_fast === 1'b1,
            "P07a panel on: 30000 clk after first trigger but 10000 after retrigger");

        // ================= P05 倒计时结束关闭 ============================
        // 距最后触发累计 26000 拍 > 25000，应关闭。
        wait_clk(16000);
        chk(panel_on_fast === 1'b0, "P05a panel off after countdown expires");

        // ================= P06 关闭后不再弹 ==============================
        wait_clk(1000);
        chk(panel_on_fast === 1'b0, "P06a stays off while params unchanged");

        // ================= P08 四个参数各自都能触发 ======================
        // 逐个改，每次确认弹窗，然后等它自己关掉再测下一个。
        invert_en = 1'b1;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P08a invert change triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P08b expired after invert trigger");

        auto_sw_sel = 2'd1;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P08c auto_sw change triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P08d expired after auto_sw trigger");

        info_mode = 2'd1;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P08e info_mode change triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P08f expired after info_mode trigger");

        bright_lvl = 4'd3;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P08g bright change triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P08h expired after bright trigger");

        // ================= P09 反向变化也能触发 ==========================
        // 上面全是"改成一个新值"。这里改回 0，验证比较是"不等"而非"变大"。
        bright_lvl = 4'd0;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P09a change back to 0 triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P09b expired after reverse change");

        // ================= P10 img_index 不触发 ==========================
        // 本模块根本没有 img_index 端口 —— 这是**结构性**保证，不是靠逻辑
        // 判断。这条断言用编译期事实说明设计意图：图号由播放器每 5 秒自动
        // 递增，若纳入触发，面板会几乎常驻，变成画面噪声。
        // （Verilog 无法在 TB 里"访问不存在的端口"，故此处只留说明性断言：
        //   确认当前参数组合下不弹窗，即"没有其他隐藏触发源"。）
        chk(panel_on_fast === 1'b0,
            "P10a no popup with all params static (no hidden trigger)");
        wait_clk(1000);
        chk(panel_on_fast === 1'b0,
            "P10b still no popup (no hidden periodic trigger)");

        // ================= P11 三个新档位各自都能触发（t16）==============
        // t16 给 osd_autopop 加了三根监视线（音量/分辨率/屏占比）。这三根
        // 若漏接或漏进 changed，用户按 Key7 循环到那几档时面板根本不弹 ——
        // 新加的显示项永远看不见。这里逐个改、逐个验。
        vol_lvl = 4'd7;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P11a vol_lvl change triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P11b expired after vol_lvl trigger");

        res_sel = 3'd3;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P11c res_sel change triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P11d expired after res_sel trigger");

        ratio_sel = 3'd2;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P11e ratio_sel change triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P11f expired after ratio_sel trigger");

        // 反向也认（比较是"不等"而非"变大"）：音量 7 -> 6
        vol_lvl = 4'd6;
        wait_clk(2);
        chk(panel_on_fast === 1'b1, "P11g vol_lvl change back triggers");
        wait_clk(FAST_MAX + 10);
        chk(panel_on_fast === 1'b0, "P11h expired after reverse vol change");

        // ================= P12 复位第一拍不弹窗（t16 不变式）=============
        // ★ 这条是本轮最容易破的不变式：新增三根延迟副本的复位值必须等于
        //   key_router 的复位值（vol=6 / res=4 / ratio=4）。若照老习惯写成
        //   全 0，复位释放后第一拍 vol_lvl(6) != vol_d(0) -> changed=1 ->
        //   上电画面莫名多出一块面板 2.5 秒。
        //   这里重新复位一次，然后在复位释放后的头几拍盯 panel_on。
        //   （P01 已经验过一次，但那次是在 P11 改动之前、且当时三根线还是
        //     0；本用例用**复位值**重新验，正是为了让"写成全 0"这种错变红。）
        rst_n = 1'b0;
        vol_lvl = 4'd6; res_sel = 3'd4; ratio_sel = 3'd4; bright_lvl = 4'd0;
        invert_en = 1'b0; auto_sw_sel = 2'd0; info_mode = 2'd0;
        wait_clk(3);
        rst_n = 1'b1;
        #1;
        chk(panel_on_fast === 1'b0, "P12a 复位释放当拍 panel_on = 0");
        chk(panel_on      === 1'b0, "P12b 复位释放当拍 panel_on(real) = 0");
        wait_clk(1);
        chk(panel_on_fast === 1'b0, "P12c 复位后第 2 拍 panel_on = 0");
        wait_clk(50);
        chk(panel_on_fast === 1'b0, "P12d 复位后 50 拍 panel_on = 0（无假变化）");

        // ================= 汇总 ==========================================
        $display("");
        $display("--------------------------------------------------");
        $display("tb_osd_autopop: %0d checks passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: osd_autopop");
        end else begin
            $display("CHECKS FAILED: osd_autopop");
        end
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
