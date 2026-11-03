// ============================================================================
// 文件名  : mode_ctrl.v
// 所在位置: rtl/control/mode_ctrl.v
// 所属层次: 控制层 / 三模式状态机
// 权威依据: docs/plan_v2/ARCH.md §2（状态机与端口契约）
//           docs/plan_v2/KEYMAP.md §2.1 / §5（Key2、Key3 的唯一消费模块）
// ============================================================================
// 【一】系统功能
//   本模块是整个终端「行为」的总闸门。它只做一件事：决定当前是
//   **日常(DALY) / 科普(SCIENCE) / 应急(EMERG)** 三种模式中的哪一种，
//   并把这个决定广播给画面、音频、字幕三条支路。
//
//        Key2 ──┐
//        Key3 ──┼──►【本模块】──► mode[1:0] ──► video_content_mux / vol_apply / caption
//   AHT20 温度 ──┘
//
// 【二】一键一模块（KEYMAP.md 铁律 1）
//   本模块只解码 **Key2（模式循环）** 与 **Key3（应急直达/确认退出）** 两个
//   键号，其余 key_code 一律走 default 不处理。Key0/Key1 归 media_player，
//   Key4~Key15 归 key_router。任何键号被两个模块同时消费，都会造成语义
//   歧义甚至多驱动 —— 这是本工程历史上真实发生过的事故（KEY0/KEY1 曾被
//   播放控制与图案选择器争用），所以这条纪律在代码里用显式注释守住。
//
// 【三】状态转移（ARCH.md §2.2 的逐行实现）
//   ┌─────────┬────────────────────┬──────────┬──────────────────────────┐
//   │ 当前态  │ 事件               │ 次态     │ 附带动作                 │
//   ├─────────┼────────────────────┼──────────┼──────────────────────────┤
//   │ DAILY   │ Key2               │ SCIENCE  │ mode_changed 单拍        │
//   │ SCIENCE │ Key2               │ DAILY    │ mode_changed 单拍        │
//   │ DAILY   │ Key3               │ EMERG    │ emerg_latched=1, src=按键│
//   │ SCIENCE │ Key3               │ EMERG    │ 同上                     │
//   │ DAILY   │ temp_alarm 上升沿  │ EMERG    │ emerg_latched=1, src=温度│
//   │ SCIENCE │ temp_alarm 上升沿  │ EMERG    │ 同上                     │
//   │ EMERG   │ Key3（第 1 次）    │ EMERG    │ confirm_armed=1, 起 2s 窗│
//   │ EMERG   │ Key3（窗口内第 2 次）│ DAILY  │ 清 emerg_latched         │
//   │ EMERG   │ Key2 / 其他键      │ EMERG    │ 全部忽略                 │
//   │ EMERG   │ 温度回落           │ EMERG    │ **不自动退出**           │
//   └─────────┴────────────────────┴──────────┴──────────────────────────┘
//
// 【四】三个设计决策与它们的理由
//
//   决策 1 · 进入零延迟，退出要双按
//     应急是即时响应动作，「该响没响」的代价远大于「误响一次」。所以进入
//     走单次按键或单次温度报警（零延迟、不确认）；退出却要 Key3 连按
//     两次且限时 2 s。这是告警类人机交互的通用惯例：拉响是瞬时动作，
//     复位必须是有意识的操作。
//     若只按一次就退出，现场一次误触（比如擦屏、搬动）就会让警报停掉，
//     而现场的观众会认为「故障已排除」—— 这是最危险的失效模式。
//
//   决策 2 · 温度回落不自动退出应急
//     温度回落只说明「芯片那一路的报警条件消失了」，不等于「事件已处理」。
//     如果自动退出，一次传感器排线松动（温度读数消失 → thermal_guard 按
//     fail-safe 保持报警电平，但若实现成 fail-open 就会清掉）就能让整机
//     悄悄退回日常模式。故锁存只能由人清除。
//
//   决策 3 · 退出强制回日常，不回科普
//     应急前若在科普模式，SDRAM 的视频缓冲已被应急画面占用；退出后若
//     回科普，需要重新从 SD 卡装载视频流，会有数秒黑屏。回日常可以立即
//     从图库出图（图库缓冲独立且常驻）。用户看到的是「恢复显示」而不是
//     「又黑了一下」。
//
// 【五】为什么不在这里做温度迟滞
//   迟滞（阈值、连续 N 次确认）属于「传感器无关的判决层」，已由
//   rtl/sensor/thermal_guard.v 实现，本模块只接收它输出的 temp_alarm 电平
//   并检测上升沿。这样替换传感器（AHT20 → 片内 SAR ADC + NTC）时，
//   本模块一行都不用改 —— 这是 captain 要求的 A/B 双方案可切换结构。
// ============================================================================
module mode_ctrl #(
    parameter integer CLK_FREQ_HZ    = 25_000_000,                    // clk 频率
    parameter integer CONFIRM_MS     = 2000,                          // 退出确认窗口
    parameter integer CONFIRM_CYCLES = (CLK_FREQ_HZ / 1000) * CONFIRM_MS
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 按键（key_matrix_4x4 输出，单拍脉冲）----
    input  wire        key_event,
    input  wire [3:0]  key_code,

    // ---- 温度报警（来自 thermal_guard，电平，已含迟滞）----
    input  wire        temp_alarm,

    // ---- 模式输出 ----
    output reg  [1:0]  mode,            // 0=日常 1=科普 2=应急
    output reg         emerg_latched,   // 应急锁存（只能由 Key3 双按清除）
    output reg  [1:0]  emerg_src,       // 0=无 1=按键 2=温度
    output reg         confirm_armed,   // 退出确认已武装（OSD 提示用）
    output reg         mode_changed,    // 单拍：模式变化（供 OSD 与视频流启停）

    // ---- 模式译码输出（纯组合，避免下游各自写比较式）----
    output wire        daily_mode,
    output wire        science_mode,
    output wire        emerg_mode
);

    // ========================================================================
    // 模式编码（与 ARCH.md §2.1 一致）
    // ========================================================================
    localparam [1:0] M_DAILY   = 2'd0;
    localparam [1:0] M_SCIENCE = 2'd1;
    localparam [1:0] M_EMERG   = 2'd2;

    // 应急来源
    localparam [1:0] SRC_NONE  = 2'd0;
    localparam [1:0] SRC_KEY   = 2'd1;
    localparam [1:0] SRC_TEMP  = 2'd2;

    // 键号（KEYMAP.md §8）
    localparam [3:0] K_MODE    = 4'd2;   // Key2 模式循环
    localparam [3:0] K_EMERG   = 4'd3;   // Key3 应急直达 / 确认退出

    // ========================================================================
    // 温度报警上升沿检测
    //   thermal_guard 输出的是电平（报警持续期间一直为 1）。若直接用电平
    //   做进入条件，应急期间每拍都会重新置 emerg_latched；虽然结果相同，
    //   但 emerg_src 会被反复改写，且一旦将来有人在 else 分支里加了动作，
    //   就会变成每拍触发一次。用上升沿检测消除这个隐患。
    // ========================================================================
    reg  temp_alarm_d;
    wire temp_alarm_rise = temp_alarm & ~temp_alarm_d;

    // ========================================================================
    // 确认窗口计时
    //   confirm_armed=1 时开始倒计时，归零则自动解除武装。计时器只在
    //   武装状态被清时复位，避免重复倒数导致的窗口漂移。
    // ========================================================================
    reg [31:0] confirm_cnt;

    // ========================================================================
    // 主状态机（唯一时序块，全非阻塞，满足 lint E1）
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode          <= M_DAILY;
            emerg_latched <= 1'b0;
            emerg_src     <= SRC_NONE;
            confirm_armed <= 1'b0;
            confirm_cnt   <= 32'd0;
            mode_changed  <= 1'b0;
            temp_alarm_d  <= 1'b0;
        end else begin
            // ---- 默认：mode_changed 是单拍脉冲 ----
            mode_changed <= 1'b0;
            temp_alarm_d <= temp_alarm;

            // ================================================================
            // 确认窗口倒计时（与状态机并行的一个小定时器）
            // ================================================================
            if (confirm_armed) begin
                if (confirm_cnt >= CONFIRM_CYCLES[31:0] - 32'd1) begin
                    confirm_armed <= 1'b0;       // 超时自动解除武装
                    confirm_cnt   <= 32'd0;
                end else begin
                    confirm_cnt <= confirm_cnt + 32'd1;
                end
            end else begin
                confirm_cnt <= 32'd0;
            end

            // ================================================================
            // 模式转移
            // ================================================================
            case (mode)
                // ------------------------------------------------------------
                // 日常
                // ------------------------------------------------------------
                M_DAILY: begin
                    if (key_event && (key_code == K_MODE)) begin
                        // Key2：日常 → 科普
                        mode         <= M_SCIENCE;
                        mode_changed <= 1'b1;
                    end else if (key_event && (key_code == K_EMERG)) begin
                        // Key3：零延迟直达应急
                        mode          <= M_EMERG;
                        emerg_latched <= 1'b1;
                        emerg_src     <= SRC_KEY;
                        confirm_armed <= 1'b0;   // 进入时不武装退出确认
                        mode_changed  <= 1'b1;
                    end else if (temp_alarm_rise) begin
                        // 高温自动进应急
                        mode          <= M_EMERG;
                        emerg_latched <= 1'b1;
                        emerg_src     <= SRC_TEMP;
                        confirm_armed <= 1'b0;
                        mode_changed  <= 1'b1;
                    end
                end

                // ------------------------------------------------------------
                // 科普
                // ------------------------------------------------------------
                M_SCIENCE: begin
                    if (key_event && (key_code == K_MODE)) begin
                        // Key2：科普 → 日常
                        mode         <= M_DAILY;
                        mode_changed <= 1'b1;
                    end else if (key_event && (key_code == K_EMERG)) begin
                        mode          <= M_EMERG;
                        emerg_latched <= 1'b1;
                        emerg_src     <= SRC_KEY;
                        confirm_armed <= 1'b0;
                        mode_changed  <= 1'b1;
                    end else if (temp_alarm_rise) begin
                        mode          <= M_EMERG;
                        emerg_latched <= 1'b1;
                        emerg_src     <= SRC_TEMP;
                        confirm_armed <= 1'b0;
                        mode_changed  <= 1'b1;
                    end
                end

                // ------------------------------------------------------------
                // 应急：只有 Key3 双按能退出，其余事件全部忽略
                // ------------------------------------------------------------
                M_EMERG: begin
                    if (key_event && (key_code == K_EMERG)) begin
                        if (confirm_armed) begin
                            // 窗口内第 2 次 → 退出，强制回日常（决策 3）
                            mode          <= M_DAILY;
                            emerg_latched <= 1'b0;
                            emerg_src     <= SRC_NONE;
                            confirm_armed <= 1'b0;
                            confirm_cnt   <= 32'd0;
                            mode_changed  <= 1'b1;
                        end else begin
                            // 第 1 次 → 武装确认窗口
                            //   注意此时不等 mode_changed，模式没变。
                            confirm_armed <= 1'b1;
                            confirm_cnt   <= 32'd0;
                        end
                    end
                    // Key2 与温度变化在此分支被有意忽略：
                    //   - Key2 不能让用户从应急「切走」（KEYMAP §5）
                    //   - 温度回落不自动退出（决策 2）
                end

                default: begin
                    mode          <= M_DAILY;
                    emerg_latched <= 1'b0;
                    emerg_src     <= SRC_NONE;
                    confirm_armed <= 1'b0;
                    mode_changed  <= 1'b1;
                end
            endcase
        end
    end

    // ========================================================================
    // 模式译码（纯组合）
    //   下游若需要「应急时强制开音频」这类判定，直接用 emerg_mode，
    //   不必每处都写 `mode == 2'd2` —— 少一个写错的机会。
    // ========================================================================
    assign daily_mode   = (mode == M_DAILY);
    assign science_mode = (mode == M_SCIENCE);
    assign emerg_mode   = (mode == M_EMERG);

endmodule
