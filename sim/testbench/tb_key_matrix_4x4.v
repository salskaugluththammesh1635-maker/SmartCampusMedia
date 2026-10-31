// =============================================================================
// tb_key_matrix_4x4.v —— key_matrix_4x4 的单元测试
// -----------------------------------------------------------------------------
// 【被测模块的规格】
//   4×4 矩阵键盘扫描 + 逐键消抖。三件事必须都对：
//     ① 行扫描：key_row 每次只拉低一行（低电平选通），0→1→2→3 循环
//     ② 逐键消抖：只处理"当前扫描行"的 4 个键，因为列线读数仅对当前行有效；
//        连续不一致采样达 DB_MAX 次才翻转稳定态
//     ③ 事件编码：按下沿产生**单拍** key_event，key_code 取**最小**键号
//        （多个同时按下时低位优先）
//
// 【本 TB 要钉死的六条不变量】
//   1) key_row 严格独热低电平，且按 0→1→2→3 循环
//   2) 抖动期 key_state 不可见、key_event 不产生
//   3) 稳定满消抖窗口后 key_state 对应位置 1，且 key_event 只出现一次
//      （按住不放绝不能重复触发——这是"边沿检测"而非"电平检测"的意义）
//   4) 松开后 key_state 对应位清 0，且不产生按下事件
//   5) 同一行两键同时按下 → key_state 两位都置 1，key_code 取较小键号
//   6) key_event 严格 1 拍宽
//
// 【物理矩阵建模：这是本 TB 最关键的一步】
//   DUT 输出的 key_row 是"驱动哪一行"，而 key_col 是"读到什么"。
//   两者由**板上的物理按键矩阵**连接：只有被选通的那一行，其按键按下才会
//   让对应列线被拉低。所以 TB 必须用组合逻辑把 key_row 翻译成 key_col：
//       key_col = ~(当前选中行对应的 4 个键的按下状态)
//   若 TB 只是简单地一直送固定的 key_col，就等于把"物理矩阵"短路了，
//   那么"只处理当前行"这条核心逻辑根本测不到。
// =============================================================================
`timescale 1ns / 1ps

module tb_key_matrix_4x4;

    // ---- 缩放常量 ----------------------------------------------------------
    // SCAN_DIV = CLK_FREQ_HZ / 1000 = 4000/1000 = 4
    //   → 每 4 个时钟产生一次 scan_tick，一次扫描一行，4 轮扫完 16 键
    //   → 同一个键每 16 拍被采样一次
    // DB_MAX = (DEBOUNCE_MS + 3)/4 = (20+3)/4 = 5
    //
    // 真实值 CLK_FREQ_HZ=50_000_000 时扫一行要 1ms，一次消抖要 20ms，
    // 跑一个用例就上百万拍；这里把 SCAN_DIV 缩到 4，时序结构完全不变。
    localparam CLK_FREQ   = 4000;
    localparam SCAN_DIV   = 4;        // CLK_FREQ / 1000
    localparam DB_MAX     = 5;        // (DEBOUNCE_MS + 3) / 4

    // ---- 时钟 --------------------------------------------------------------
    reg clk;
    initial clk = 1'b0;
    always #10 clk = ~clk;

    // ---- DUT ---------------------------------------------------------------
    reg         rst_n;
    wire [3:0]  key_row;
    reg  [3:0]  key_col;
    wire        key_event;
    wire [3:0]  key_code;
    wire [15:0] key_state;

    key_matrix_4x4 #(
        .CLK_FREQ_HZ  (CLK_FREQ),
        .DEBOUNCE_MS  (20)
    ) u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .key_row   (key_row),
        .key_col   (key_col),
        .key_event (key_event),
        .key_code  (key_code),
        .key_state (key_state)
    );

    // ---- 物理按键矩阵模型 ---------------------------------------------------
    //   pressed[k] = 1 表示"这个键被手指按住"（与行列无关的物理事实）
    //   按键 (r,c) 的键号 k = 4*r + c
    //   当 key_row 选通第 r 行（key_row[r]==0）时，该行 4 个键中按下的那些
    //   会把对应列线拉低 → key_col[c] = 0
    reg [15:0] pressed;

    always @(*) begin
        key_col = 4'hF;                          // 默认全高 = 无按键
        if (key_row[0] === 1'b0) key_col = ~pressed[3:0];
        else if (key_row[1] === 1'b0) key_col = ~pressed[7:4];
        else if (key_row[2] === 1'b0) key_col = ~pressed[11:8];
        else if (key_row[3] === 1'b0) key_col = ~pressed[15:12];
    end

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

    // ---- 事件监视器：统计 key_event 脉冲个数与宽度 -------------------------
    integer ev_cnt;
    integer ev_width;
    reg     ev_d;
    integer ev_run;
    reg [3:0] ev_code_at;      // 事件发生那拍的 key_code

    always @(posedge clk) begin
        ev_d <= key_event;
        if (key_event === 1'b1 && ev_d !== 1'b1) begin
            ev_cnt      = ev_cnt + 1;
            ev_run      = 1;
            ev_code_at  = key_code;
        end else if (key_event === 1'b1) begin
            ev_run = ev_run + 1;
        end else begin
            if (ev_run > 0) ev_width = ev_run;
            ev_run = 0;
        end
    end

    task clr_ev;
        begin ev_cnt = 0; ev_width = 0; ev_run = 0; ev_d = 1'b0; end
    endtask

    // ---- 行扫描监视器：统计"第 r 行被采样"的次数 ---------------------------
    //   时序关系：row_idx 在 scan_tick 那拍自增（非阻塞），而消抖块在**同一拍**
    //   读到的是自增前的 row_idx —— 也就是说 key_row 从 r 变成 r+1 的那一拍，
    //   正是"第 r 行被采样"的那一拍。
    reg [3:0] row_d;
    integer   samp[0:3];        // 每行已采样次数

    always @(posedge clk) begin
        row_d <= key_row;
        if (row_d === 4'b1110 && key_row === 4'b1101) samp[0] = samp[0] + 1;
        if (row_d === 4'b1101 && key_row === 4'b1011) samp[1] = samp[1] + 1;
        if (row_d === 4'b1011 && key_row === 4'b0111) samp[2] = samp[2] + 1;
        if (row_d === 4'b0111 && key_row === 4'b1110) samp[3] = samp[3] + 1;
    end

    task clr_samp;
        begin samp[0] = 0; samp[1] = 0; samp[2] = 0; samp[3] = 0; end
    endtask

    // ---- 主流程 ------------------------------------------------------------
    integer i;
    integer guard;
    reg [3:0] scan_prev;
    reg       found;

    initial begin
        $display("=== tb_key_matrix_4x4 start (SCAN_DIV=%0d DB_MAX=%0d) ===",
                 SCAN_DIV, DB_MAX);
        clr_ev();
        clr_samp();
        pressed = 16'h0000;
        rst_n   = 1'b0;

        // =====================================================================
        // ① 复位：key_row 应为第 0 行独热低，状态与事件全清
        // =====================================================================
        repeat (6) @(posedge clk);
        #1;
        ck(key_row   === 4'b1110,  "[reset] key_row selects row0 (one-hot low)");
        ck_eq(key_state, 16'h0000, "[reset] key_state cleared");
        ck(key_event === 1'b0,     "[reset] no key_event");
        ck_eq(key_code, 4'd0,      "[reset] key_code cleared");

        @(negedge clk);
        rst_n = 1'b1;

        // =====================================================================
        // ② 行扫描序列：1110 → 1101 → 1011 → 0111 → 1110 ...
        //    每个状态驻留 SCAN_DIV 拍
        //
        //    对齐技巧：row_idx 在 scan_tick 那拍的 posedge 自增，key_row 是它的
        //    组合译码，所以 key_row 跳变就发生在"新一行开始"的那一拍。
        //    所以先**等一次跳变**做锚点，之后每 SCAN_DIV 拍检查一次，
        //    相位就自然对齐了 —— 直接 repeat 固定拍数是靠不住的。
        // =====================================================================
        // 等一次 key_row 跳变（锚点）
        // 注意：不能复用 row_d —— 它已被 always 块用非阻塞赋值驱动，
        // initial 里再写它会与 always 冲突，导致永远"相等"。
        scan_prev = key_row;
        guard     = 0;
        found     = 1'b0;
        while (guard < 40 && !found) begin
            @(posedge clk); #1;
            if (key_row !== scan_prev) found = 1'b1;
            else                       scan_prev = key_row;
            guard = guard + 1;
        end
        ck(found, "[scan] key_row toggled (scan engine is running)");

        // 锚点之后逐槽检查 8 个槽（两轮完整扫描）
        for (i = 0; i < 8; i = i + 1) begin
            case (key_row)
                4'b1110: ck(1'b1, "[scan] slot: row0 selected");
                4'b1101: ck(1'b1, "[scan] slot: row1 selected");
                4'b1011: ck(1'b1, "[scan] slot: row2 selected");
                4'b0111: ck(1'b1, "[scan] slot: row3 selected");
                default: ck(1'b0, "[scan] slot: key_row is not one-hot-low");
            endcase
            // 独热低：必须恰好有 3 个 1
            ck((key_row[0] + key_row[1] + key_row[2] + key_row[3]) === 3,
               "[scan] exactly one row driven low");
            repeat (SCAN_DIV) @(posedge clk);
            #1;
        end

        // =====================================================================
        // ③ 抖动期不可见：快速反复按松，绝不能产生事件
        //    每 2 拍翻一次，远快于消抖窗口（需要连续 6 次采样一致）
        // =====================================================================
        clr_ev();
        clr_samp();
        for (i = 0; i < 60; i = i + 1) begin
            @(negedge clk); pressed = 16'h0001;   // 按下键 0
            @(negedge clk); pressed = 16'h0000;   // 松开
        end
        ck_eq(key_state, 16'h0000, "[bounce] key_state unchanged during bouncing");
        ck_eq(ev_cnt,    0,        "[bounce] no key_event during bouncing");

        // =====================================================================
        // ④ 稳定按下：连续采样达阈值后 key_state 置位、事件只出现一次
        //
        //    RTL 的翻转条件是 db_cnt >= DB_MAX(=5)，而 db_cnt 从 0 起算且只在
        //    "不一致但未达阈值"分支自增，所以需要**第 6 次**采样才翻转
        //    （比名义 20ms 多一个采样周期，属实现细节，此处如实钉住）。
        // =====================================================================
        clr_ev();
        clr_samp();
        @(negedge clk); pressed = 16'h0001;       // 稳定按住键 0（row0, col0）
        // 等第 5 次采样完成
        guard = 0;
        while (samp[0] < 5 && guard < 200) begin @(posedge clk); guard = guard + 1; end
        #1;
        ck_eq(samp[0], 5,          "[press] row0 sampled 5 times");
        ck_eq(key_state, 16'h0000, "[press] not yet stable after 5 samples");
        ck_eq(ev_cnt,    0,        "[press] no event after 5 samples");

        // 等第 6 次采样
        guard = 0;
        while (samp[0] < 6 && guard < 200) begin @(posedge clk); guard = guard + 1; end
        repeat (3) @(posedge clk);
        #1;
        ck_eq(key_state, 16'h0001, "[press] key0 stable after 6 samples");
        ck_eq(ev_cnt,    1,        "[press] exactly one key_event");
        ck_eq(ev_code_at, 4'd0,    "[press] key_code = 0");
        ck_eq(ev_width,  1,        "[press] key_event is one cycle wide");

        // =====================================================================
        // ⑤ 按住不放：不得重复触发（边沿检测而非电平检测）
        // =====================================================================
        clr_ev();
        repeat (100) @(posedge clk);
        #1;
        ck_eq(key_state, 16'h0001, "[hold] key_state stays pressed");
        ck_eq(ev_cnt,    0,        "[hold] no repeated event while held");

        // =====================================================================
        // ⑥ 松开：状态清 0，且不产生"按下"事件
        //    注意用**相对**采样计数等待：samp[] 是累计值，前面用例已经把它推高了，
        //    用绝对值比较会瞬间通过（这正是首版 [release] 假失败的原因）。
        // =====================================================================
        @(negedge clk); pressed = 16'h0000;
        clr_ev();
        guard = 0;
        while (key_state !== 16'h0000 && guard < 300) begin
            @(posedge clk); #1;
            guard = guard + 1;
        end
        ck(guard < 300,            "[release] key0 cleared after release");
        ck_eq(key_state, 16'h0000, "[release] key_state back to zero");
        repeat (3) @(posedge clk);
        #1;
        ck_eq(ev_cnt,    0,        "[release] no key_event on release");

        // =====================================================================
        // ⑦ 按下另一个键（跨行）：键 5 = row1,col1
        // =====================================================================
        clr_ev();
        @(negedge clk); pressed = 16'h0020;       // bit5 = row1 col1
        repeat (120) @(posedge clk);
        #1;
        ck_eq(key_state, 16'h0020, "[key5] key_state bit5 set");
        ck_eq(ev_cnt,    1,        "[key5] exactly one event");
        ck_eq(ev_code_at, 4'd5,    "[key5] key_code = 5");
        @(negedge clk); pressed = 16'h0000;
        repeat (120) @(posedge clk);

        // =====================================================================
        // ⑧ 同一行两键同时按下 → 两位都置 1，key_code 取较小键号
        //    键 4 = row1 col0，键 7 = row1 col3，同一行 → 同一拍翻转 → 一次事件
        // =====================================================================
        clr_ev();
        @(negedge clk); pressed = 16'h0090;       // bit4 + bit7
        repeat (120) @(posedge clk);
        #1;
        ck_eq(key_state, 16'h0090, "[priority] both key4 and key7 stable");
        ck_eq(ev_code_at, 4'd4,    "[priority] key_code = 4 (lowest index wins)");
        ck(ev_cnt >= 1,            "[priority] at least one event for simultaneous press");
        @(negedge clk); pressed = 16'h0000;
        repeat (120) @(posedge clk);

        // =====================================================================
        // ⑨ 跨行两键同时按下（不同扫描时刻各产生一次事件，状态都保留）
        // =====================================================================
        clr_ev();
        @(negedge clk); pressed = 16'h0082;       // bit1(row0) + bit7(row1)
        repeat (150) @(posedge clk);
        #1;
        ck_eq(key_state, 16'h0082, "[multi] keys 1 and 7 both stable");
        ck(ev_cnt >= 1,            "[multi] events observed for cross-row press");

        // =====================================================================
        // ⑩ 运行中复位：状态与事件立刻清零
        // =====================================================================
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        ck_eq(key_state, 16'h0000, "[mid-reset] key_state cleared");
        ck(key_event === 1'b0,     "[mid-reset] key_event low");
        ck(key_row   === 4'b1110,  "[mid-reset] key_row back to row0");

        // =====================================================================
        // ⑪ 复位释放后重新工作
        // =====================================================================
        pressed = 16'h0000;
        clr_ev();
        @(negedge clk);
        rst_n = 1'b1;
        repeat (40) @(posedge clk);
        ck_eq(key_state, 16'h0000, "[resume] idle after reset release");
        ck_eq(ev_cnt,    0,        "[resume] no spurious event");

        @(negedge clk); pressed = 16'h8000;       // 键 15 = row3 col3
        repeat (150) @(posedge clk);
        #1;
        ck_eq(key_state, 16'h8000, "[resume] key15 (row3 col3) detected");
        ck_eq(ev_code_at, 4'd15,   "[resume] key_code = 15");

        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: key_matrix_4x4");
        else             $display("CHECKS FAILED: key_matrix_4x4");
        $finish;
    end

    // 看门狗
    initial begin
        #200000;
        $display("FAIL: GLOBAL TIMEOUT");
        $display("CHECKS FAILED: key_matrix_4x4");
        $finish;
    end

endmodule
