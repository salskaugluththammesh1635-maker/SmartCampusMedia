// =============================================================================
// tb_dmz_eg4s20_min_top.v —— 最小系统顶层整链集成测试
// -----------------------------------------------------------------------------
// 【被测对象】
//   rtl/top/dmz_eg4s20_min_top.v
//   端口: clk(50MHz) / rst_n_btn(低有效) / key_row[3:0](出) / key_col[3:0](入)
//         led[7:0](出) / seg_data[7:0](出) / seg_cs[3:0](出) / buzzer(出)
//
// 【为什么这个顶层值得做整链仿真】
//   全项目三个顶层里，只有本模块**不含加密 IP、不依赖 PLL**：
//     - dmz_eg4s20_hdmi_top 含 HDMI 加密核（ModelSim ASE 下 vlog 会挂死）
//     - sdram_bringup_top   依赖真实加密 SDRAM 核
//   所以这是唯一能把"键盘扫描 → 消抖 → 事件 → BCD 计数 → 段码译码 →
//   动态扫描输出 → 蜂鸣器"整条链路一次性打通验证的入口。子模块各自单测
//   都绿，并不等于接线正确（端口接反、位序颠倒、参数不一致都只在整链暴露）。
//
// 【整链验证的核心断言（都是"跨模块契约"，单测永远测不到）】
//   1) 物理按键 → led[7:4] 必须等于该键的键号（key_matrix → BCD → LED 接线）
//   2) 每次按键 → led[3:0] 递增 1（key_event 确实驱动了 BCD 计数器）
//   3) 段码输出必须等于"当前 BCD 数字经 seg_decoder 译码"的结果
//      （seg_decoder → seg_scan4 的位序：dig0=个位、dig3=千位，接反了立刻暴露）
//   4) 蜂鸣器：无按键时静止，按键后 100ms 窗口内必须起振
//      ↳ **已修复缺陷，现为回归护栏**：min_top 曾把 3 位 tone_sel 端口接成
//        2 位常量（rtl/top/dmz_eg4s20_min_top.v:251 `.tone_sel (2'd1)`），
//        ModelSim 对端口处位宽不匹配做 z 扩展 → tone_sel=3'bz01 →
//        buzzer_tone 的 sq_en 恒为 x → 按键完全无声。RTL 已改成 3'd1。
//   5) 动态扫描：seg_cs 任一时刻最多一位为低，且一轮扫完四位都出现过
//
// 【仿真时间预算】
//   顶层把 CLK_FREQ_HZ=50_000_000 写死在子模块例化里（不可由 -g 覆盖），
//   所以时间尺度是真实的：
//     - 扫一行        = SCAN_DIV = 50_000_000/1000 = 50_000 拍
//     - 扫完四行      = 200_000 拍
//     - 一个键消抖    = (DB_MAX+1)=6 次采样 × 200_000 = 1.2M 拍 = 24ms
//     - 蜂鸣窗口      = 100ms
//   本 TB 用 20ns 时钟（50MHz），总仿真约 100ms / 5M 拍。
//   1Hz 心跳要 25M 拍（0.5s）才翻转，故全程 hb_flag 恒 0 —— 这里只做断言
//   "总时长不足 0.5s 时 dig3 的 DP 位必须为 0"，避免误判。
// =============================================================================
`timescale 1ns / 1ps

module tb_dmz_eg4s20_min_top;

    localparam CLK_HALF  = 10;          // 50MHz
    localparam SCAN_CYC  = 50000;       // 一轮四位数码管扫描
    localparam KEY_WAIT  = 4000000;     // 单次按键最长等待（80ms，含 6 次采样余量）

    // 段码期望表（与 seg_decoder 真值表一致，{g,f,e,d,c,b,a} 高电平点亮）
    localparam [6:0] SEG0 = 7'b011_1111;
    localparam [6:0] SEG1 = 7'b000_0110;
    localparam [6:0] SEG2 = 7'b101_1011;
    localparam [6:0] SEG3 = 7'b100_1111;
    localparam [6:0] SEG4 = 7'b110_0110;
    localparam [6:0] SEG5 = 7'b110_1101;
    localparam [6:0] SEG6 = 7'b111_1101;
    localparam [6:0] SEG7 = 7'b000_0111;
    localparam [6:0] SEG8 = 7'b111_1111;
    localparam [6:0] SEG9 = 7'b110_1111;

    reg         clk       = 1'b0;
    reg         rst_n_btn = 1'b0;
    reg  [3:0]  key_col   = 4'hF;
    wire [3:0]  key_row;
    wire [7:0]  led;
    wire [7:0]  seg_data;
    wire [3:0]  seg_cs;
    wire        buzzer;

    integer checks       = 0;
    integer errors       = 0;
    // 已登记的 RTL 缺陷（XFAIL）：与 errors 分开计数，不计入失败，
    // 但必须在 SUMMARY 里显式报出，避免缺陷被"全绿"吞掉。
    integer known_issues = 0;

    always #(CLK_HALF) clk = ~clk;

    // -------------------------------------------------------------------------
    // 物理键盘矩阵模型
    //   真实硬件里 key_row 是"行选通"输出，按下哪一行哪一列的键，就把
    //   对应列拉低。若 TB 只送固定 key_col，就等于短路了物理矩阵，
    //   "只处理当前扫描行"这条核心逻辑根本验不到。
    // -------------------------------------------------------------------------
    reg [15:0] pressed = 16'h0000;      // pressed[k]=1 表示键 k 被按住, k=4*行+列

    always @(*) begin
        key_col = 4'hF;
        if (key_row[0] === 1'b0)      key_col = ~pressed[3:0];
        else if (key_row[1] === 1'b0) key_col = ~pressed[7:4];
        else if (key_row[2] === 1'b0) key_col = ~pressed[11:8];
        else if (key_row[3] === 1'b0) key_col = ~pressed[15:12];
    end

    dmz_eg4s20_min_top u_top (
        .clk       (clk),
        .rst_n_btn (rst_n_btn),
        .key_row   (key_row),
        .key_col   (key_col),
        .led       (led),
        .seg_data  (seg_data),
        .seg_cs    (seg_cs),
        .buzzer    (buzzer)
    );

    // -------------------------------------------------------------------------
    // 计分器
    // -------------------------------------------------------------------------
    task ck(input cond, input [8*96-1:0] label);
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s", label);
            end
        end
    endtask

    task ck_int(input integer got, input integer exp, input [8*96-1:0] label);
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", label);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s (got %0d expected %0d)", label, got, exp);
            end
        end
    endtask

    // 已登记缺陷专用计分：期望"失败"，失败时记 known_issues 而不记 errors。
    // 若哪天 RTL 修好了、这条反而通过，则记 errors —— 提示登记表该更新了。
    task ck_known(input cond, input [8*96-1:0] label);
        begin
            checks = checks + 1;
            if (!cond) begin
                known_issues = known_issues + 1;
                $display("KNOWN ISSUE: %0s", label);
            end
            else begin
                errors = errors + 1;
                $display("FAIL: %0s (registered defect no longer reproduces; update the known-issue list)", label);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 数码管扫描采集器
    //   seg_data/seg_cs 是 DUT 在 posedge 寄存的，故在 negedge 采稳定值。
    //   记录每一位被选中时实际输出的段码，以及各被选中的次数。
    //
    //   seg_cs 的合法值有两类：
    //     - 独热低（1110/1101/1011/0111）：正在点亮某一位，正常扫描
    //     - 全高（1111）：复位值 / dig_idx 越界时的默认值，属"全部熄灭"
    //   非法值是"两位及以上同时为低"——那会出现重影。
    //   另外单独统计"扫描启动之后还出现全高"的次数：扫描启动后若还出现
    //   全高，说明扫描引擎会周期性全灭，屏幕会闪。
    // -------------------------------------------------------------------------
    reg [7:0] cap0, cap1, cap2, cap3;
    integer   hit0, hit1, hit2, hit3;
    integer   scan_violations;          // seg_cs 出现多位同时为低的次数
    integer   blank_after_start;        // 扫描启动后出现全高的次数
    reg       scan_started;

    initial begin
        cap0 = 8'h00; cap1 = 8'h00; cap2 = 8'h00; cap3 = 8'h00;
        hit0 = 0; hit1 = 0; hit2 = 0; hit3 = 0;
        scan_violations = 0;
        blank_after_start = 0;
        scan_started = 1'b0;
    end

    always @(negedge clk) begin
        if (rst_n_btn === 1'b1) begin
            case (seg_cs)
                4'b1110: begin cap0 = seg_data; hit0 = hit0 + 1; scan_started = 1'b1; end
                4'b1101: begin cap1 = seg_data; hit1 = hit1 + 1; scan_started = 1'b1; end
                4'b1011: begin cap2 = seg_data; hit2 = hit2 + 1; scan_started = 1'b1; end
                4'b0111: begin cap3 = seg_data; hit3 = hit3 + 1; scan_started = 1'b1; end
                4'b1111: begin if (scan_started) blank_after_start = blank_after_start + 1; end
                default: scan_violations = scan_violations + 1;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 蜂鸣器边沿统计（posedge clk 域，与 DUT 同沿但只做计数，不影响判据时序）
    // -------------------------------------------------------------------------
    integer buzz_edges = 0;
    reg     buzz_d     = 1'b0;
    always @(posedge clk) begin
        if (buzzer !== buzz_d) begin
            buzz_edges = buzz_edges + 1;
            buzz_d     = buzzer;
        end
    end

    // -------------------------------------------------------------------------
    // 等待一次按键事件
    //   key_event 是模块内部信号，通过层次引用观察（不改变 DUT 行为）。
    //   超时返回 0，由调用方判定失败。
    // -------------------------------------------------------------------------
    task wait_key(output ok);
        integer guard;
        begin
            ok = 1'b0;
            guard = 0;
            while ((guard < KEY_WAIT) && (u_top.key_event !== 1'b1)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (u_top.key_event === 1'b1) ok = 1'b1;
            // key_event 与它驱动的 last_key/bcd 都在同一个 posedge 用非阻塞赋值
            // 更新，而本进程是在时钟沿的 active 区恢复执行的，此刻 NBA 尚未
            // 生效。必须再等半个周期，让 led / 段码反映新值，否则读到的是
            // 上一拍的旧值（表现为"事件检测到了，但计数没变"的假失败）。
            @(negedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // 等待一整轮数码管扫描，让 cap0..cap3 反映当前 BCD 状态
    // -------------------------------------------------------------------------
    task wait_scan_round;
        integer i;
        begin
            for (i = 0; i < SCAN_CYC; i = i + 1) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // 核对四位段码 = 当前 BCD 数字的译码结果
    //   dig0..dig3 在 RTL 里是 {DP, segN}，DP 位（bit7）本测试全程应为 0，
    //   因为 1Hz 心跳要 0.5s 才翻转，而本仿真总时长不足 0.5s。
    // -------------------------------------------------------------------------
    function [6:0] seg_of(input [3:0] d);
        case (d)
            4'd0: seg_of = SEG0;  4'd1: seg_of = SEG1;
            4'd2: seg_of = SEG2;  4'd3: seg_of = SEG3;
            4'd4: seg_of = SEG4;  4'd5: seg_of = SEG5;
            4'd6: seg_of = SEG6;  4'd7: seg_of = SEG7;
            4'd8: seg_of = SEG8;  default: seg_of = SEG9;
        endcase
    endfunction

    task check_digits(input [3:0] d3, input [3:0] d2, input [3:0] d1, input [3:0] d0,
                      input [8*72-1:0] tag);
        begin
            ck(cap0 === {1'b0, seg_of(d0)},
               {tag, ": digit0 (units) segment code"});
            ck(cap1 === {1'b0, seg_of(d1)},
               {tag, ": digit1 (tens) segment code"});
            ck(cap2 === {1'b0, seg_of(d2)},
               {tag, ": digit2 (hundreds) segment code"});
            ck(cap3 === {1'b0, seg_of(d3)},
               {tag, ": digit3 (thousands) segment code, heartbeat DP clear"});
            if (cap0 !== {1'b0, seg_of(d0)}) begin
                $display("      digit0 got %08b expected 0_%07b", cap0, seg_of(d0));
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // 按下一个键并等待事件
    // -------------------------------------------------------------------------
    task press_key(input [3:0] k, output ok);
        begin
            pressed = (16'h0001 << k);
            wait_key(ok);
        end
    endtask

    // -------------------------------------------------------------------------
    // 主流程
    // -------------------------------------------------------------------------
    reg     ok;
    integer buzz_before;

    initial begin
        $display("=== dmz_eg4s20_min_top integration test ===");

        // ---------------------------------------------------------------------
        // [1] 复位
        // ---------------------------------------------------------------------
        rst_n_btn = 1'b0;
        pressed   = 16'h0000;
        #(CLK_HALF * 200);

        ck(led === 8'h00, "[reset] led is cleared (no key, count 0)");
        ck(seg_data === 8'h00, "[reset] segment data is blank");
        ck(seg_cs === 4'b1111, "[reset] no digit selected");
        // 蜂鸣器是 PNP 驱动，**高电平=静音**（buzzer_tone 内部 buzzer_out <= ~sq，
        // 且复位值刻意取 1，避免上电瞬间"嘎"一声）。所以静音判据是 1 而不是 0。
        ck(buzzer === 1'b1, "[reset] buzzer is muted (active-low drive, idle high)");

        rst_n_btn = 1'b1;
        #(CLK_HALF * 400);

        // ---------------------------------------------------------------------
        // [2] 键盘扫描引擎在跑（key_row 必须变化且独热低）
        // ---------------------------------------------------------------------
        begin : scan_alive
            reg [3:0] prev;
            reg       toggled;
            integer   i;
            integer   ones;
            toggled = 1'b0;
            prev    = key_row;
            for (i = 0; i < 300000; i = i + 1) begin
                @(posedge clk);
                if (key_row !== prev) toggled = 1'b1;
                prev = key_row;
            end
            ck(toggled === 1'b1, "[scan] key_row toggles (scan engine is running)");
            // 独热低：恰好一个 0
            ones = key_row[0] + key_row[1] + key_row[2] + key_row[3];
            ck_int(ones, 3, "[scan] key_row is one-hot low");
        end

        // ---------------------------------------------------------------------
        // [3] 动态扫描输出
        // ---------------------------------------------------------------------
        ck_int(scan_violations, 0, "[seg] seg_cs never has two digits low at once (no ghosting)");
        ck_int(blank_after_start, 0, "[seg] no full-blank state once scanning started");
        ck(hit0 > 0, "[seg] digit0 was selected at least once");
        ck(hit1 > 0, "[seg] digit1 was selected at least once");
        ck(hit2 > 0, "[seg] digit2 was selected at least once");
        ck(hit3 > 0, "[seg] digit3 was selected at least once");

        // 初始计数 0000
        check_digits(4'd0, 4'd0, 4'd0, 4'd0, "[seg] after reset");

        // ---------------------------------------------------------------------
        // [4] 无按键时蜂鸣器必须静止
        // ---------------------------------------------------------------------
        buzz_before = buzz_edges;
        begin : quiet
            integer i;
            for (i = 0; i < 300000; i = i + 1) @(posedge clk);
        end
        ck_int(buzz_edges - buzz_before, 0, "[buzz] stays silent while no key is pressed");

        // ---------------------------------------------------------------------
        // [5] 按下键 0：整链从键盘到 LED / 数码管 / 蜂鸣器
        // ---------------------------------------------------------------------
        press_key(4'd0, ok);
        ck(ok === 1'b1, "[key] key 0 press produces a key event");
        ck(led[7:4] === 4'd0, "[key] led high nibble shows key code 0");
        ck(led[3:0] === 4'd1, "[key] led low nibble shows count 1");

        // 蜂鸣器起振（100ms 窗口内）
        //
        // 【已修复缺陷 #3，现为回归护栏】min_top 曾把 3 位的 tone_sel 端口接成
        // 2 位常量：rtl/top/dmz_eg4s20_min_top.v:251   .tone_sel (2'd1)
        // ModelSim 对"端口连接处的位宽不匹配"做的是 **z 扩展而不是零扩展**
        // （assign 语句则是正常零扩展，两者行为不同，已用最小复现确认）：
        //   2'd1 → 3 位端口 ⇒ sel = 3'bz01 ⇒ (sel == 3'd1) 求值为 x
        // 于是 buzzer_tone 内部 sq_en 恒为 x，方波永不翻转，按键完全无声。
        // RTL 已改为 .tone_sel (3'd1)；修复前 edges=0，修复后 edges=10。
        // 这里保留"现象 + 根因"两条断言，一旦有人把位宽改回去就会立刻失败。
        buzz_before = buzz_edges;
        begin : beep
            integer i;
            for (i = 0; i < 500000; i = i + 1) @(posedge clk);
        end
        $display("INFO: [buzz] tone_sel=%b sq_en=%b beep_run=%b edges=%0d",
                 u_top.u_buzz.tone_sel, u_top.u_buzz.sq_en,
                 u_top.u_buzz.beep_run, buzz_edges - buzz_before);
        ck(buzz_edges - buzz_before >= 2,
           "[buzz] toggles after key press (beep window open)");
        // 根因钉子：tone_sel 必须恰好等于 3'd1 才算接线正确（修复前是 3'bz01）。
        ck(u_top.u_buzz.tone_sel === 3'd1,
           "[buzz] tone_sel port receives a clean 3'd1");

        // 数码管：个位变 1，其余仍 0
        wait_scan_round;
        check_digits(4'd0, 4'd0, 4'd0, 4'd1, "[seg] after first key");

        pressed = 16'h0000;
        #(CLK_HALF * 100);

        // ---------------------------------------------------------------------
        // [6] 再按两个不同的键：键号更新、计数递增到 3
        // ---------------------------------------------------------------------
        press_key(4'd5, ok);
        ck(ok === 1'b1, "[key] key 5 press produces a key event");
        ck(led[7:4] === 4'd5, "[key] led high nibble shows key code 5");
        ck(led[3:0] === 4'd2, "[key] led low nibble shows count 2");

        pressed = 16'h0000;
        #(CLK_HALF * 100);

        press_key(4'd15, ok);
        ck(ok === 1'b1, "[key] key 15 press produces a key event");
        ck(led[7:4] === 4'd15, "[key] led high nibble shows key code 15");
        ck(led[3:0] === 4'd3, "[key] led low nibble shows count 3");

        wait_scan_round;
        check_digits(4'd0, 4'd0, 4'd0, 4'd3, "[seg] after three keys");

        pressed = 16'h0000;
        #(CLK_HALF * 100);

        // ---------------------------------------------------------------------
        // [7] 按住不放不得重复计数（事件是边沿触发，不是电平触发）
        // ---------------------------------------------------------------------
        begin : hold_key
            integer i;
            pressed = 16'h0001 << 7;        // 键 7
            wait_key(ok);
            ck(ok === 1'b1, "[hold] key 7 press produces a key event");
            ck(led[3:0] === 4'd4, "[hold] count advances to 4");
            // 继续按住 3M 拍（远超一个消抖窗口），不应再产生新事件
            for (i = 0; i < 3000000; i = i + 1) @(posedge clk);
            ck(u_top.key_event !== 1'b1, "[hold] holding a key does not re-trigger");
            ck(led[3:0] === 4'd4, "[hold] count stays at 4 while held");
        end

        pressed = 16'h0000;
        #(CLK_HALF * 100);

        // ---------------------------------------------------------------------
        // [8] 运行中复位：全部回到初始态
        // ---------------------------------------------------------------------
        rst_n_btn = 1'b0;
        #(CLK_HALF * 200);
        ck(led === 8'h00, "[reset] led clears on mid-run reset");
        ck(buzzer === 1'b1, "[reset] buzzer muted on mid-run reset (active-low drive)");
        ck(seg_data === 8'h00, "[reset] segment data blank on mid-run reset");
        ck(seg_cs === 4'b1111, "[reset] no digit selected on mid-run reset");

        rst_n_btn = 1'b1;
        #(CLK_HALF * 400);

        // ---------------------------------------------------------------------
        // [9] 复位后重建：计数重新从 1 开始
        // ---------------------------------------------------------------------
        press_key(4'd2, ok);
        ck(ok === 1'b1, "[resume] key 2 press produces a key event after reset");
        ck(led[7:4] === 4'd2, "[resume] led high nibble shows key code 2");
        ck(led[3:0] === 4'd1, "[resume] count restarts at 1 after reset");

        wait_scan_round;
        check_digits(4'd0, 4'd0, 4'd0, 4'd1, "[resume] after reset");

        pressed = 16'h0000;
        #(CLK_HALF * 100);

        // ---------------------------------------------------------------------
        // 汇总
        // ---------------------------------------------------------------------
        $display("SUMMARY: checks=%0d errors=%0d known_issues=%0d", checks, errors, known_issues);
        if (errors == 0) $display("ALL CHECKS PASSED: dmz_eg4s20_min_top");
        else             $display("CHECKS FAILED: dmz_eg4s20_min_top");
        $finish;
    end

    initial begin
        #400000000;                     // 400ms 上限（本测试约需 100ms）
        $display("FAIL: GLOBAL TIMEOUT");
        $display("SUMMARY: checks=%0d errors=%0d known_issues=%0d", checks, errors + 1, known_issues);
        $display("CHECKS FAILED: dmz_eg4s20_min_top");
        $finish;
    end

endmodule
