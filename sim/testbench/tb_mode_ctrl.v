// ============================================================================
// 文件名  : tb_mode_ctrl.v
// 目的    : 验证 rtl/control/mode_ctrl.v 的三模式状态机
// 权威依据: docs/plan_v2/ARCH.md §2（状态转移表 / 迟滞 / 确认窗口）
//           docs/plan_v2/KEYMAP.md §5（三模式作用域矩阵）
// ============================================================================
// 【测试策略】
//   这是全工程唯一带"安全语义"的状态机，测试重点不是"能不能切"，而是
//   **"该拒绝的时候有没有拒绝"**。所以用例分成四组：
//
//   组 A · 正常切换（C01~C03）
//     复位态、Key2 日常↔科普、mode_changed 单拍。
//
//   组 B · 应急进入的零延迟（C04、C16、C17）
//     Key3 从日常/科普都能进，温度上升沿也能进。进入必须**当拍生效**，
//     不允许有确认、不允许有延时 —— 这是安全功能的基本要求。
//
//   组 C · 应急期间的拒绝语义（C05、C06、C13、C14）
//     这是关键组：
//       - Key2 不能切走（否则用户能从应急"逃逸"到日常，警报还在响但
//         画面已经正常，现场会认为故障排除）
//       - 其他参数键不影响模式
//       - **温度回落不自动退出**（最危险的一条：如果自动退出，一次
//         传感器掉线就能让整机悄悄退回日常）
//       - 已应急时温度再次上升沿不重复触发
//
//   组 D · 退出的双按确认（C07~C10、C20）
//     第 1 次按 Key3 只武装不退出；窗口内第 2 次才退出；窗口超时后
//     重新计数。退出强制回日常（不是科普）。
//
//   另外全程监视 mode_changed 的脉冲宽度（C18），确保它是单拍而非
//   持续高 —— 持续高会让下游"模式变化时启动视频流"反复触发。
//
// 【参数覆盖】
//   CONFIRM_CYCLES 由 (CLK_FREQ_HZ/1000)*CONFIRM_MS = 50,000 拍缩短到
//   20 拍，仿真时间从 2 ms 降到 0.8 us，判决逻辑一字不改。
//   STALE 类的参数本模块没有，温度迟滞在 thermal_guard.v 里测。
// ============================================================================
`timescale 1ns / 1ps

module tb_mode_ctrl;

    localparam integer CLK_PERIOD   = 40;    // 25 MHz
    localparam integer CONF_CYCLES  = 20;    // 覆盖后的确认窗口（原 50,000）

    // 模式编码
    localparam [1:0] M_DAILY   = 2'd0;
    localparam [1:0] M_SCIENCE = 2'd1;
    localparam [1:0] M_EMERG   = 2'd2;

    // 键号
    localparam [3:0] K_MODE    = 4'd2;
    localparam [3:0] K_EMERG   = 4'd3;
    localparam [3:0] K_BRIGHT  = 4'd6;

    // ---- DUT 端口 ----
    reg        clk;
    reg        rst_n;
    reg        key_event;
    reg  [3:0] key_code;
    reg        temp_alarm;

    wire [1:0] mode;
    wire       emerg_latched;
    wire [1:0] emerg_src;
    wire       confirm_armed;
    wire       mode_changed;
    wire       daily_mode;
    wire       science_mode;
    wire       emerg_mode;

    // ---- 记分板 ----
    integer pass_cnt;
    integer fail_cnt;

    task chk;
        input         cond;
        input [511:0] msg;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // ========================================================================
    // DUT（CONFIRM_CYCLES 覆盖为 20 拍）
    // ========================================================================
    mode_ctrl #(
        .CLK_FREQ_HZ    (25_000_000),
        .CONFIRM_MS     (2000),
        .CONFIRM_CYCLES (CONF_CYCLES)
    ) u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .key_event     (key_event),
        .key_code      (key_code),
        .temp_alarm    (temp_alarm),
        .mode          (mode),
        .emerg_latched (emerg_latched),
        .emerg_src     (emerg_src),
        .confirm_armed (confirm_armed),
        .mode_changed  (mode_changed),
        .daily_mode    (daily_mode),
        .science_mode  (science_mode),
        .emerg_mode    (emerg_mode)
    );

    // ========================================================================
    // 时钟
    // ========================================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ========================================================================
    // mode_changed 脉冲监视
    //   mchg_cnt  : 累计脉冲个数（每次按键后核对增量）
    //   mchg_wide : 连续两拍为高的次数（必须为 0，证明是单拍）
    // ========================================================================
    integer mchg_cnt;
    integer mchg_wide;
    reg     mchg_d;

    initial begin
        mchg_cnt  = 0;
        mchg_wide = 0;
        mchg_d    = 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mchg_cnt  <= 0;
            mchg_wide <= 0;
            mchg_d    <= 1'b0;
        end else begin
            if (mode_changed) mchg_cnt <= mchg_cnt + 1;
            if (mode_changed && mchg_d) mchg_wide <= mchg_wide + 1;
            mchg_d <= mode_changed;
        end
    end

    // ========================================================================
    // 按键 task：在 negedge 驱动，避开 posedge 采样竞争
    // ========================================================================
    task press_key;
        input [3:0] k;
        begin
            @(negedge clk);
            key_event = 1'b1;
            key_code  = k;
            @(negedge clk);
            key_event = 1'b0;
            key_code  = 4'd0;
        end
    endtask

    // 只发一路温度报警电平（模拟 thermal_guard 的输出）
    task set_temp_alarm;
        input v;
        begin
            @(negedge clk);
            temp_alarm = v;
        end
    endtask

    // ========================================================================
    // 主激励
    // ========================================================================
    integer mchg_before;
    integer i;

    initial begin
        pass_cnt   = 0;
        fail_cnt   = 0;
        rst_n      = 1'b0;
        key_event  = 1'b0;
        key_code   = 4'd0;
        temp_alarm = 1'b0;

        // 复位保持几个周期
        repeat (5) @(posedge clk);
        #1;

        // ================================================================
        // 组 A · 正常切换
        // ================================================================

        // ---- C01 复位态 ----
        chk(mode == M_DAILY,       "C01a 复位: mode = 日常");
        chk(emerg_latched == 1'b0, "C01b 复位: emerg_latched = 0");
        chk(confirm_armed == 1'b0, "C01c 复位: confirm_armed = 0");
        chk(daily_mode == 1'b1 && science_mode == 1'b0 && emerg_mode == 1'b0,
                                   "C01d 复位: 译码输出只有 daily_mode 有效");

        @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // ---- C02 Key2 日常 → 科普 ----
        mchg_before = mchg_cnt;
        press_key(K_MODE);
        #1;
        chk(mode == M_SCIENCE, "C02a Key2: 日常 -> 科普");
        // mchg_cnt 在 posedge 采样的是**上一拍**的 mode_changed（非阻塞语义），
        // 所以计数滞后一个时钟。这里多等 2 拍再核对，否则会误报。
        repeat (2) @(posedge clk);
        #1;
        chk(mchg_cnt == mchg_before + 1, "C02b Key2: mode_changed 恰好一个脉冲");
        chk(science_mode == 1'b1, "C02c 译码: science_mode = 1");

        // ---- C03 Key2 科普 → 日常 ----
        press_key(K_MODE);
        #1;
        chk(mode == M_DAILY, "C03 Key2: 科普 -> 日常（两态循环，不进应急）");

        // ================================================================
        // 组 B · 应急进入的零延迟
        // ================================================================

        // ---- C04 Key3 日常 → 应急（当拍生效）----
        press_key(K_EMERG);
        #1;
        chk(mode == M_EMERG,        "C04a Key3: 日常 -> 应急（零延迟）");
        chk(emerg_latched == 1'b1,  "C04b Key3: emerg_latched 置位");
        chk(emerg_src == 2'd1,      "C04c Key3: emerg_src = 按键");
        chk(confirm_armed == 1'b0,  "C04d 刚进入应急: confirm_armed = 0（未武装）");

        // ================================================================
        // 组 C · 应急期间的拒绝语义
        // ================================================================

        // ---- C05 应急下 Key2 被忽略 ----
        //   mchg_cnt 是"上一拍"的计数（posedge 采样 + 非阻塞），必须等上一
        //   事件（C04 进应急）的脉冲被计入后再取基准，否则会把 C04 的
        //   脉冲误算成 C05 的。
        repeat (2) @(posedge clk);
        mchg_before = mchg_cnt;
        press_key(K_MODE);
        #1;
        chk(mode == M_EMERG, "C05a 应急下 Key2: 模式不变（不能切走）");
        repeat (2) @(posedge clk);
        #1;
        chk(mchg_cnt == mchg_before, "C05b 应急下 Key2: 不发 mode_changed");

        // ---- C06 应急下参数键被忽略 ----
        press_key(K_BRIGHT);
        #1;
        chk(mode == M_EMERG, "C06 应急下 Key6: 模式不变（参数键不影响模式）");

        // ---- C11 温度上升沿进应急（先回日常再测）----
        //   退出应急：Key3 双按
        press_key(K_EMERG);      // 第 1 次：武装
        #1;
        press_key(K_EMERG);      // 第 2 次：退出
        #1;
        chk(mode == M_DAILY, "C11-pre 双按 Key3: 退出应急回日常");
        chk(emerg_latched == 1'b0, "C11-pre2 退出后 emerg_latched 清除");
        chk(emerg_src == 2'd0, "C11-pre3 退出后 emerg_src 清 0");

        // 温度上升沿
        set_temp_alarm(1'b1);
        repeat (3) @(posedge clk);
        #1;
        chk(mode == M_EMERG,   "C11a 温度上升沿: 自动进应急");
        chk(emerg_src == 2'd2, "C11b 温度进入: emerg_src = 温度");

        // ---- C12 温度持续高电平不重复触发 ----
        repeat (2) @(posedge clk);
        mchg_before = mchg_cnt;
        repeat (10) @(posedge clk);
        #1;
        chk(mchg_cnt == mchg_before, "C12 温度电平保持: 不重复发 mode_changed（边沿检测生效）");
        chk(emerg_src == 2'd2,       "C12b 温度电平保持: emerg_src 未被反复改写");

        // ---- C13 温度回落不自动退出（最关键的一条）----
        set_temp_alarm(1'b0);
        repeat (20) @(posedge clk);
        #1;
        chk(mode == M_EMERG,        "C13a 温度回落: **不自动退出**应急（锁存语义）");
        chk(emerg_latched == 1'b1,  "C13b 温度回落: emerg_latched 仍为 1");

        // ---- C14 已应急时温度再次上升沿：被忽略 ----
        repeat (2) @(posedge clk);
        mchg_before = mchg_cnt;
        set_temp_alarm(1'b1);
        repeat (5) @(posedge clk);
        #1;
        chk(mode == M_EMERG,         "C14a 应急中温度再升: 模式不变");
        chk(mchg_cnt == mchg_before, "C14b 应急中温度再升: 不发 mode_changed");
        set_temp_alarm(1'b0);
        repeat (3) @(posedge clk);

        // ================================================================
        // 组 D · 退出的双按确认
        // ================================================================

        // ---- C07 第 1 次按 Key3：只武装，不退出 ----
        press_key(K_EMERG);
        #1;
        chk(mode == M_EMERG,        "C07a 应急中 Key3 第 1 次: 模式不变");
        chk(confirm_armed == 1'b1,  "C07b 应急中 Key3 第 1 次: confirm_armed = 1");

        // ---- C08 窗口内第 2 次：退出，且强制回日常 ----
        press_key(K_EMERG);
        #1;
        chk(mode == M_DAILY,        "C08a 窗口内 Key3 第 2 次: 退出到日常（不回科普）");
        chk(emerg_latched == 1'b0,  "C08b 退出: emerg_latched 清除");
        chk(confirm_armed == 1'b0,  "C08c 退出: confirm_armed 清除");

        // ---- C09 窗口超时：武装自动解除 ----
        press_key(K_EMERG);          // 先进应急
        #1;
        press_key(K_EMERG);          // 第 1 次按：武装
        #1;
        chk(confirm_armed == 1'b1,   "C09a 武装成功");
        // 等待超过窗口（20 拍），多等 10 拍确保超时
        repeat (CONF_CYCLES + 10) @(posedge clk);
        #1;
        chk(confirm_armed == 1'b0,   "C09b 窗口超时: confirm_armed 自动解除");
        chk(mode == M_EMERG,         "C09c 窗口超时: 仍在应急（未退出）");

        // ---- C10 超时后再按：重新计为"第 1 次"，不退出 ----
        press_key(K_EMERG);
        #1;
        chk(mode == M_EMERG,         "C10a 超时后再按: 仍不退出（重新武装）");
        chk(confirm_armed == 1'b1,   "C10b 超时后再按: confirm_armed 重新置 1");
        press_key(K_EMERG);
        #1;
        chk(mode == M_DAILY,         "C10c 再按一次: 退出成功");

        // ---- C16 科普下 Key3 → 应急 ----
        press_key(K_MODE);           // 日常 → 科普
        #1;
        chk(mode == M_SCIENCE, "C16-pre 已进入科普");
        press_key(K_EMERG);
        #1;
        chk(mode == M_EMERG, "C16 Key3: 科普 -> 应急");
        press_key(K_EMERG);
        #1;
        press_key(K_EMERG);
        #1;
        chk(mode == M_DAILY, "C16b 从科普进入的应急，退出后回**日常**（不回科普）");

        // ---- C17 科普下温度上升沿 → 应急 ----
        press_key(K_MODE);
        #1;
        chk(mode == M_SCIENCE, "C17-pre 已进入科普");
        set_temp_alarm(1'b1);
        repeat (3) @(posedge clk);
        #1;
        chk(mode == M_EMERG, "C17 科普下温度上升沿: 进应急");
        set_temp_alarm(1'b0);
        repeat (3) @(posedge clk);
        press_key(K_EMERG);
        #1;
        press_key(K_EMERG);
        #1;

        // ================================================================
        // C18 mode_changed 全程都是单拍
        // ================================================================
        chk(mchg_wide == 0, "C18 mode_changed 全程单拍（无连续两拍为高）");
        $display("  共发生 %0d 次 mode_changed 脉冲", mchg_cnt);

        // ================================================================
        // C19 译码输出唯一性（任意时刻三选一）
        // ================================================================
        begin : dec_blk
            integer d_ok;
            d_ok = 1;
            for (i = 0; i < 3; i = i + 1) begin
                case (i)
                    0: begin press_key(K_MODE); end
                    1: begin press_key(K_MODE); end
                    default: begin press_key(K_EMERG); end
                endcase
                #1;
                if ((daily_mode + science_mode + emerg_mode) != 1'b1) begin
                    d_ok = 0;
                    $display("  译码违例: mode=%0d d/s/e=%b%b%b",
                             mode, daily_mode, science_mode, emerg_mode);
                end
            end
            chk(d_ok == 1, "C19 译码: daily/science/emerg 任意时刻恰好一个为 1");
        end
        // 清回日常
        press_key(K_EMERG);
        #1;
        press_key(K_EMERG);
        #1;

        // ================================================================
        // C20 复位能清掉一切
        // ================================================================
        press_key(K_EMERG);
        #1;
        @(negedge clk);
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        chk(mode == M_DAILY,        "C20a 复位: mode 回日常");
        chk(emerg_latched == 1'b0,  "C20b 复位: emerg_latched 清 0");
        chk(confirm_armed == 1'b0,  "C20c 复位: confirm_armed 清 0");
        chk(temp_alarm == 1'b0 || mode == M_DAILY, "C20d 复位: 温度电平不残留影响");

        // ================================================================
        // 结算
        // ================================================================
        $display("");
        $display("tb_mode_ctrl: pass=%0d fail=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: mode_ctrl");
        end else begin
            $display("CHECKS FAILED: mode_ctrl");
        end
        $finish;
    end

    // 全局超时
    initial begin
        #2_000_000;
        $display("GLOBAL TIMEOUT: mode_ctrl");
        $finish;
    end

endmodule
