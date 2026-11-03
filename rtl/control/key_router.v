// ============================================================================
// 文件名  : key_router.v
// 所在位置: rtl/control/key_router.v
// 所属层次: 控制层 / 按键路由（取代 rtl/control/key_action.v）
// 权威依据: docs/plan_v2/KEYMAP.md §7（端口契约逐字实现）、§8（键号判定表）、
//           §9（档位值表）、§5（三模式作用域矩阵）、§5.1（应急音量下限）
// ============================================================================
// 【一】系统功能
//   16 个按键里的 **Key4~Key15** 全部在这里译码，输出一组"参数寄存器"：
//
//     Key4  ──► audio_en    音频输出开关
//     Key5  ──► ticker_en   底部滚动字幕开关
//     Key6  ──► bright_lvl  亮度 10 档（0→…→9→0 循环）
//     Key7  ──► vol_lvl     音量 10 档（0→…→9→0 循环）
//     Key8  ──► res_sel     内部渲染分辨率 5 档
//     Key9  ──► ratio_sel   屏占比 5 档
//     Key10 ──► viz_en      音频可视化图层开关
//     Key11~Key15           P2 备用（默认不实现，寄存器恒 0）
//
//   另外每个参数键按下时同时发一个 osd_pop_req 单拍脉冲，让参数面板自动
//   弹出 2.5 s —— 这是赛规 1.4(4)「按键调节亮度后，参数变化信息可读」的
//   直接实现：用户不需要额外按任何键，调完立刻看得见数值。
//
// 【二】一键一模块（KEYMAP.md 铁律 1，本工程的头号纪律）
//   每个 key_code 在整份工程中**只能被一个模块消费**。分工如下，写在
//   本文件里作为执行清单，任何后续改动都必须先改 KEYMAP.md 再改代码：
//
//     Key0 / Key1  ──► media_player.v（上一张 / 下一张）
//     Key2 / Key3  ──► mode_ctrl.v   （模式循环 / 应急直达确认）
//     Key4~Key15   ──► 本模块
//
//   历史事故：改造前 KEY0/KEY1 曾被播放控制与测试图案选择器同时判定，
//   表现为"按一下切两张图、图案也跟着变"。这类 bug 的根源不是写错逻辑，
//   而是**归属没定死**。所以本模块对其他键号一律 `default: ;` 放行，
//   绝不越界。
//
// 【三】三模式作用域（KEYMAP.md §5 的实现）
//   ┌──────────┬────────┬────────┬──────────────────────────────────┐
//   │ 键       │ 日常   │ 科普   │ 应急                             │
//   ├──────────┼────────┼────────┼──────────────────────────────────┤
//   │ Key4 音频│ 可切   │ 可切   │ **锁 1**（广播必须出声）         │
//   │ Key5 字幕│ 可切   │ 可切   │ **锁 1**（承载应急疏散提示）     │
//   │ Key6 亮度│ 可切   │ 可切   │ 可切（现场光照差异大）           │
//   │ Key7 音量│ 可切   │ 可切   │ 可切，但输出钳位到档 3（§5.1）   │
//   │ Key8 分辨率 / Key9 屏占比 / Key10 可视化：全状态可切            │
//   └──────────┴────────┴────────┴──────────────────────────────────┘
//
//   注意"锁 1"的实现方式：**寄存器仍然记录用户的选择**，只在输出端做钳位。
//   这样应急退出后，用户原来关掉的音频/字幕会**自动恢复关闭**，不会被
//   应急模式偷偷改掉设置。若直接写 `audio_en <= 1'b1`，用户回来会发现
//   "我明明关了怎么又开了"，是典型的隐蔽状态污染。
//
// 【四】为什么 ticker_en 与 viz_en 必须是两个独立寄存器（KEYMAP §5.2 禁令）
//   ticker_en 控制**底部滚动字幕条**（osd_caption.v 的 TICKER_Y0=448 区域），
//   承载文本信息：日常=校园介绍，科普=视频字幕，应急=应急疏散提示。
//   viz_en 控制**音频波形图层**（audio_waveform.v 的 Y_CENTER=200 区域），
//   承载音频可视化，是赛规 1.4(5) 的加分项。
//
//   两者在屏幕位置、内容类型、赛规归属上完全不同。一旦合并成一个
//   `osd_en`，应急模式下"字幕强制开 + 波形允许关"这个组合就**无法表达**
//   —— 一个开关不可能同时是"强制 1"和"可切 0"。这是本设计里最容易被
//   误合并的一对信号，特此在代码里单列警告。
//
// 【五】P2 备用键的资源纪律（KEYMAP §2.2）
//   Key11~Key15 在 P0/P1 阶段不实现。参数 P2_EN 默认 0：
//     - P2_EN = 0 时，这五个键的译码分支存在（编译期可综合、无悬空），
//       但写回值被强制为 0，功能不生效，不占额外资源（综合器会把
//       恒 0 的寄存器优化掉）。
//     - P2_EN = 1 时全部启用，用于产线自检与演示。
//   若资源裁剪触发 P2（RESOURCE_BUDGET.md §4），从 Key15 倒序整块移除。
// ============================================================================
module key_router #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer OSD_HOLD_MS = 2500,
    parameter         P2_EN       = 1'b0        // P2 备用键总开关，默认关闭
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 按键（key_matrix_4x4 输出，key_event 为单拍脉冲）----
    input  wire        key_event,
    input  wire [3:0]  key_code,

    // ---- 模式（来自 mode_ctrl，用于应急钳位）----
    input  wire [1:0]  mode,            // 0=日常 1=科普 2=应急

    // ---- 参数寄存器 ----
    output reg  [3:0]  bright_lvl,      // 0~9，复位 0（**0 = 最亮 32/32**，9 = 最暗 3/32）
    output reg  [3:0]  vol_lvl,         // 0~9，复位 6（约 50%）
    output reg  [2:0]  res_sel,         // 0~4，复位 4（640×480 原生）
    output reg  [2:0]  ratio_sel,       // 0~4，复位 4（满屏）
    output reg         audio_en,        // 复位 1
    output reg         ticker_en,       // 复位 1
    output reg         viz_en,          // 复位 1

    // ---- 参数面板自动弹出请求 ----
    output reg         osd_pop_req,     // 单拍：任一参数键按下
    output reg  [4:0]  osd_item,        // 0=音频 1=字幕 2=亮度 3=音量
                                        // 4=分辨率 5=屏占比 6=可视化

    // ---- 应急钳位后的实际输出（顶层直接用这两个，不必各处重算）----
    output wire        audio_en_eff,
    output wire        ticker_en_eff,

    // ---- P2 备用键输出（P2_EN=0 时恒 0）----
    output reg         rescan_req,      // Key11 图库重扫（单拍）
    output reg  [2:0]  pattern_sel,     // Key12 测试图案循环
    output reg         invert_en,       // Key13 反色
    output reg         grid_en,         // Key14 九宫格
    output reg         beep_muted       // Key15 蜂鸣器静音
);

    // ========================================================================
    // 键号（KEYMAP.md §8，逐字）
    // ========================================================================
    localparam [3:0] K_AUDIO    = 4'd4;    // Key4  音频开关
    localparam [3:0] K_TICKER   = 4'd5;    // Key5  底部字幕开关
    localparam [3:0] K_BRIGHT   = 4'd6;    // Key6  亮度 10 档
    localparam [3:0] K_VOL      = 4'd7;    // Key7  音量 10 档
    localparam [3:0] K_RES      = 4'd8;    // Key8  分辨率 5 档
    localparam [3:0] K_RATIO    = 4'd9;    // Key9  屏占比 5 档
    localparam [3:0] K_VIZ      = 4'd10;   // Key10 音频可视化开关
    localparam [3:0] K_RESCAN   = 4'd11;   // Key11 图库重扫（P2）
    localparam [3:0] K_PATTERN  = 4'd12;   // Key12 测试图案（P2）
    localparam [3:0] K_INVERT   = 4'd13;   // Key13 反色（P2）
    localparam [3:0] K_GRID     = 4'd14;   // Key14 九宫格（P2）
    localparam [3:0] K_BEEP     = 4'd15;   // Key15 蜂鸣器静音（P2）

    // 档位上限
    localparam [3:0] LVL_MAX    = 4'd9;    // 亮度/音量 10 档：0~9
    localparam [2:0] SEL5_MAX   = 3'd4;    // 分辨率/屏占比 5 档：0~4
    localparam [2:0] PAT_MAX    = 3'd4;    // 测试图案 5 档（P2）

    // osd_item 编码
    localparam [4:0] ITEM_AUDIO   = 5'd0;
    localparam [4:0] ITEM_TICKER  = 5'd1;
    localparam [4:0] ITEM_BRIGHT  = 5'd2;
    localparam [4:0] ITEM_VOL     = 5'd3;
    localparam [4:0] ITEM_RES     = 5'd4;
    localparam [4:0] ITEM_RATIO   = 5'd5;
    localparam [4:0] ITEM_VIZ     = 5'd6;

    // 模式编码（与 mode_ctrl 一致）
    localparam [1:0] M_EMERG    = 2'd2;

    wire emerg = (mode == M_EMERG);

    // ========================================================================
    // 主译码（唯一时序块，全非阻塞，复位全量，满足 lint E1/E2）
    //   osd_pop_req / rescan_req 都是单拍脉冲，在块首统一清 0，
    //   避免"某次分支忘了清"造成的长脉冲（会导致面板一直弹出）。
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bright_lvl  <= 4'd0;        // 复位**最亮**（32/32）。0=最亮是既有硬件语义
            vol_lvl     <= 4'd6;        // 复位约 50%，既有工程的中位音量
            res_sel     <= SEL5_MAX;    // 复位 640×480 原生档（无放大，路径最短）
            ratio_sel   <= SEL5_MAX;    // 复位满屏
            audio_en    <= 1'b1;        // 复位开
            ticker_en   <= 1'b1;        // 复位开
            viz_en      <= 1'b1;        // 复位开
            osd_pop_req <= 1'b0;
            osd_item    <= ITEM_BRIGHT;
            rescan_req  <= 1'b0;
            pattern_sel <= 3'd0;
            invert_en   <= 1'b0;
            grid_en     <= 1'b0;
            beep_muted  <= 1'b0;
        end else begin
            // ---- 单拍脉冲默认清零 ----
            osd_pop_req <= 1'b0;
            rescan_req  <= 1'b0;

            if (key_event) begin
                case (key_code)
                    // ============================================================
                    // Key4 音频开关
                    //   应急模式下不接受切换（KEYMAP §5「锁 1」）：
                    //   寄存器保持用户值不变，退出应急后自动恢复用户设置。
                    // ============================================================
                    K_AUDIO: begin
                        if (!emerg) begin
                            audio_en    <= ~audio_en;
                            osd_item    <= ITEM_AUDIO;
                            osd_pop_req <= 1'b1;
                        end
                        // 应急：忽略，但 osd_pop_req 也不发 —— 否则用户按了没反应
                        //       却弹出面板说"音频 开"，反而误导。
                    end

                    // ============================================================
                    // Key5 底部字幕开关（同理锁 1）
                    //   注意：这里只控制 ticker_en，绝不碰 viz_en（§四 禁令）。
                    // ============================================================
                    K_TICKER: begin
                        if (!emerg) begin
                            ticker_en   <= ~ticker_en;
                            osd_item    <= ITEM_TICKER;
                            osd_pop_req <= 1'b1;
                        end
                    end

                    // ============================================================
                    // Key6 亮度 10 档递增循环 0→1→…→9→0
                    //   **方向：0 = 最亮(32/32) → 9 = 最暗(3/32)**，越按越暗，
                    //   循环回 0 时跳回最亮。
                    //   为什么是这个方向而不是"越按越亮"：改造前
                    //   video_overlay.v:108 是 `bright_sel == 3'd0 ? r_in`，
                    //   硬件语义 0 就是直通=最亮。若反序，老用户升级后会觉得
                    //   "按键方向反了"，且既有 tb_video_overlay 的档位断言失效。
                    //   全状态有效：应急时也允许调亮（现场光照差异大）。
                    // ============================================================
                    K_BRIGHT: begin
                        bright_lvl  <= (bright_lvl >= LVL_MAX) ? 4'd0
                                                              : (bright_lvl + 4'd1);
                        osd_item    <= ITEM_BRIGHT;
                        osd_pop_req <= 1'b1;
                    end

                    // ============================================================
                    // Key7 音量 10 档递增循环
                    //   全状态有效。应急模式下档位仍可到 0，但实际增益由
                    //   vol_apply.v 钳位到档 3（KEYMAP §5.1）—— 钳位不在这里做，
                    //   因为本模块输出的是"用户选择的档位"，语义必须纯粹。
                    // ============================================================
                    K_VOL: begin
                        vol_lvl     <= (vol_lvl >= LVL_MAX) ? 4'd0
                                                            : (vol_lvl + 4'd1);
                        osd_item    <= ITEM_VOL;
                        osd_pop_req <= 1'b1;
                    end

                    // ============================================================
                    // Key8 内部渲染分辨率 5 档 0→1→2→3→4→0
                    // ============================================================
                    K_RES: begin
                        res_sel     <= (res_sel >= SEL5_MAX) ? 3'd0
                                                             : (res_sel + 3'd1);
                        osd_item    <= ITEM_RES;
                        osd_pop_req <= 1'b1;
                    end

                    // ============================================================
                    // Key9 屏占比 5 档 1/2→5/8→3/4→7/8→1→1/2
                    // ============================================================
                    K_RATIO: begin
                        ratio_sel   <= (ratio_sel >= SEL5_MAX) ? 3'd0
                                                               : (ratio_sel + 3'd1);
                        osd_item    <= ITEM_RATIO;
                        osd_pop_req <= 1'b1;
                    end

                    // ============================================================
                    // Key10 音频可视化图层开关（可关，不承载安全信息）
                    // ============================================================
                    K_VIZ: begin
                        viz_en      <= ~viz_en;
                        osd_item    <= ITEM_VIZ;
                        osd_pop_req <= 1'b1;
                    end

                    // ============================================================
                    // Key11~Key15：P2 备用
                    //   P2_EN=0 时写回值被强制为常量，综合器可优化掉整个分支，
                    //   不产生悬空、不占资源，但代码结构完整保留。
                    // ============================================================
                    K_RESCAN: begin
                        rescan_req <= P2_EN ? 1'b1 : 1'b0;
                    end

                    K_PATTERN: begin
                        pattern_sel <= P2_EN
                                     ? ((pattern_sel >= PAT_MAX) ? 3'd0
                                                                 : (pattern_sel + 3'd1))
                                     : 3'd0;
                    end

                    K_INVERT: begin
                        invert_en <= P2_EN ? ~invert_en : 1'b0;
                    end

                    K_GRID: begin
                        grid_en <= P2_EN ? ~grid_en : 1'b0;
                    end

                    K_BEEP: begin
                        beep_muted <= P2_EN ? ~beep_muted : 1'b0;
                    end

                    // ============================================================
                    // Key0~Key3 属于 media_player / mode_ctrl，本模块放行。
                    // 这个 default 是"一键一模块"纪律的物理体现，不要删。
                    // ============================================================
                    default: begin
                        // 有意留空：不是本模块的键，不做任何动作。
                    end
                endcase
            end
        end
    end

    // ========================================================================
    // 应急钳位输出（KEYMAP §5「锁 1」的输出端实现）
    //   用 wire 而非另开寄存器：钳位是纯组合的"投影"，不引入状态。
    //   这样应急进入/退出的瞬间输出立即跟随，无需等待一个时钟沿。
    // ========================================================================
    assign audio_en_eff  = emerg ? 1'b1 : audio_en;
    assign ticker_en_eff = emerg ? 1'b1 : ticker_en;

endmodule
