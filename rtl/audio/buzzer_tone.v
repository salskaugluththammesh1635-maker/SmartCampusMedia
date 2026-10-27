// =============================================================================
// buzzer_tone.v — 无源蜂鸣器驱动 + 提示音发生器
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 音频层（人机反馈通道）
//   工程归属 : bringup_td.al 与 hdmi_td.al **两个工程共用**
//   数据流位置:
//       key_event（按键事件） / mode（工作模式）
//            ↓
//       【本模块】──→ buzzer（单根 IO，输出方波）
//            ↓
//       板上 PNP 三极管 → 无源蜂鸣器 → 发声
//   为什么需要它:
//     人与设备的交互需要"听得到的反馈"。无源蜂鸣器的音调由**驱动频率**决定
//     （不像有源蜂鸣器只能发固定音），因此可用一根 IO 发出不同音高与节奏 ——
//     按键"嘀"一声、应急模式"急促蜂鸣"，都由这一个器件实现，无需额外音频器件。
//
// 【二、本模块功能】
//   一句话职责: 用一根 IO 驱动无源蜂鸣器，发出按键提示音、应急提示音与故障告警音。
//   关键特性:
//     - 四种模式由 tone_sel 选择: 0=静音 / 1=按键音(C5≈523Hz, 100ms) /
//       2=应急音(E6≈1319Hz, 250ms 响 / 250ms 停 自动循环) /
//       3=故障告警音(A4≈440Hz, 700ms 停 / 300ms 响 自动循环)
//     - **变量单驱动结构**: 每个寄存器只由一个 always 块赋值（防多驱动），
//       在此前提下按机制拆成 7 个互不交叉的块，各块职责单一
//     - 时钟频率参数化: 50MHz 换 25MHz 只需改参数，逻辑一行不动
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  clk         : 系统时钟（25MHz）
//     输入  rst_n       : 低有效复位
//     输入  tone_sel[2:0]: 音调模式选择（0=静音 / 1=按键音 / 2=应急音 / 3=故障告警）
//                          ↑ 2026-10-26 由 2 位扩到 3 位以容纳故障告警音；
//                            旧顶层把 2 位表达式接到 3 位端口时高位自动补 0，
//                            故 min_top / bringup_top / 三个 diag_top 无需改动，后向兼容。
//     输入  trig        : 单拍触发（按键事件，开启 100ms 发声窗口）
//     输出  buzzer_out  : 蜂鸣器驱动（**低电平响**，因板上为 PNP 驱动）
//
//   内部逻辑块（共 7 块；四个机制 + 各自计数/输出段，变量互不交叉）:
//     [1] 机制A 状态寄存器  always @(posedge clk)   FSM 第①段
//           功能: beep_state <= beep_next（只搬运，无判断）
//           输入: beep_next                          输出: beep_state
//     [2] 机制A 次态逻辑    always @(*)             FSM 第②段
//           功能: case(beep_state) 决定下一态；trig 在 B_BEEP 内可重触发
//           输入: trig, beep_cnt, beep_state          输出: beep_next
//     [3] 机制A 计数/输出   always @(posedge clk)   FSM 第③段
//           功能: beep_cnt 计数；beep_run 由现态译码（Moore 输出）
//           输入: trig, beep_run                     输出: beep_cnt, beep_run
//     [4] 机制B 应急音相位  always @(posedge clk)   **LSM**（含配套计数）
//           功能: emerg_cnt 推进一整圈，区间译码出 emerg_phase
//           输入: tone_sel（仅门控）                  输出: emerg_phase, emerg_cnt
//     [5] 机制D 告警音相位  always @(posedge clk)   **LSM**（含配套计数）
//           功能: alm_cnt 推进一整圈，区间译码出 alm_phase（先静后响）
//           输入: tone_sel（仅门控）                  输出: alm_phase, alm_cnt
//     [6] 机制C 方波半周期  always @(posedge clk)   **LSM**（含配套计数）
//           功能: half_cnt 数满 half_period 就翻转 sq_phase
//           输入: tone_sel/beep_run/emerg_on/alarm_on（仅门控）
//                                                    输出: sq_phase, half_cnt
//     [7] 输出取反          always @(posedge clk)
//           功能: buzzer_out <= ~sq（转换成低电平有效的板级极性）
//           输入: sq                                 输出: buzzer_out
//
//   【板级事实】来源: 走近FPGA 表1.5 + 核心板原理图 p4 BUZ 区（已核实）
//     无源蜂鸣器，PNP(MMBT3906) 驱动: FPGA 输出**低电平** → 三极管导通 → 发声
//     Buzzer_Out = 球 H11；音调由输出方波的频率决定
//
// 【四、设计思路与范式】
//   主要范式 : **标准线性序列机（LSM）×2**（应急音相位 + 方波半周期）
//   次要范式 : **标准有限状态机（FSM，三段式）**（按键音时间窗口）
//   这三种机制此前挤在一个 always 块里，导致本模块的范式归类存在定义分歧：
//     · 按 docs/design_patterns.md 对 LSM 的定义（计数器推进固定序列、
//       下一步唯一确定、转移不依赖外部输入），"响/停"交替与方波翻转
//       都是标准 LSM；
//     · 而旧文件头用"转移完全由计数器决定，因此不算状态机"把它排除，
//       归到一个模糊的"计数器 + 时间窗口"第三类，与上面的 LSM 定义冲突。
//   现在按唯一分界线（**下一个状态由谁决定**）把三种机制拆开，各自归位：
//
//     机制 A  按键音窗口   → FSM    转移含外部输入 trig
//     机制 B  应急音相位   → LSM    序列 E_MUTE → E_SOUND → E_MUTE …
//                                   只由 emerg_cnt 推进，下一步唯一确定
//     机制 C  方波半周期   → LSM    序列 SQ_LO → SQ_HI → SQ_LO …
//                                   只由 half_cnt 推进，下一步唯一确定
//
//   判断口诀（本项目统一口径）:
//     **删掉所有 input，这个块还能不能跑下去？**
//       能，且序列固定 → LSM；不能/去向改变 → FSM；都不涉及 → 其他范式。
//     对机制 B/C：删掉 tone_sel 后序列照跑（只是永远不使能），故为 LSM；
//     对机制 A：删掉 trig 后永远停在 B_IDLE，故为 FSM。
//     ↳ 注意区分「门控」与「转移条件」：tone_sel 只决定序列**走不走**，
//       不决定**下一步去哪**，所以它是门控，不使机制 B/C 变成 FSM。
//
//   为什么方波要这么写:
//     无源蜂鸣器要的是**方波**而不是"高电平"。产生方波的标准手法是：
//     用计数器数够半个周期就翻转一次输出，如此往复。核心公式：
//         f_out = f_clk / (2 × half_period)
//     反过来求计数初值: half_period = f_clk / (2 × f_out)
//     例: 50MHz 时钟产生 523Hz(C5) → half_period = 50_000_000/(2×523) ≈ 47801
//   关键写法要点:
//     1) **同一个变量只由一个 always 块驱动** —— 早期版本把 beep_cnt 分散在
//        两个块里赋值，造成多驱动（仿真出 X 态）。注意铁律的准确表述是
//        "变量单驱动"，而非"必须只有一个块"：在遵守单驱动的前提下按职责
//        拆块是安全且更易读的，本模块现在就是 5 个互不交叉的 always 块
//     2) 参数化换算而非硬编码常数: 用 CLK_FREQ_HZ 参与运算，换时钟不动逻辑
//     3) 复位时必须让输出停在"静音态"（buzzer_out = 1），否则上电瞬间
//        蜂鸣器会响一声
//   范式认读方法: 见 docs/design_patterns.md
// =============================================================================
`timescale 1ns / 1ps

module buzzer_tone #(
    parameter CLK_FREQ_HZ = 50_000_000   // 系统时钟频率(Hz)。作用: 把"目标音高(Hz)"和
                                         //   "时间窗口(ms)"换算成计数初值；
                                         //   换时钟（50MHz→25MHz）只改这里，逻辑一行不动
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] tone_sel,       // 0=静音 1=按键音 2=应急音 3=故障告警音
    input  wire       trig,           // 单拍触发（按键音窗口开启）
    output reg        buzzer_out      // 蜂鸣器驱动, 低=响
);
    // ===== 由 parameter 自动推导的计数初值（改音高/时长只需动这几行）=====
    // 方波频率公式: f_out = CLK_FREQ_HZ / (2 × HALF)  →  HALF = CLK_FREQ_HZ / (2 × f_out)
    localparam [31:0] HALF_C5  = CLK_FREQ_HZ / (2 * 523);
    //   ↑ 作用: C5 音（≈523Hz）的**半周期**计数值 —— 计满就翻转一次 sq 电平
    //     50MHz 时 ≈ 47801。用于"按键提示音"（音高适中、不刺耳）
    localparam [31:0] HALF_E6  = CLK_FREQ_HZ / (2 * 1319);
    //   ↑ 作用: E6 音（≈1319Hz）的半周期计数值
    //     50MHz 时 ≈ 18953。用于"应急提示音"（音更高、更急促，起警示作用）
    localparam [31:0] BEEP_TICKS  = CLK_FREQ_HZ / 10;
    //   ↑ 作用: 按键音的发声窗口长度 = 100ms 对应的时钟周期数
    //     （除以 10 即 0.1 秒；用整数除法而非小数乘法，便于综合）
    localparam [31:0] EMERG_HALF  = CLK_FREQ_HZ / 4;
    //   ↑ 作用: 应急音"响"段与"停"段各持续的时长 = 250ms 对应的时钟周期数
    //     完整循环 = 2 × EMERG_HALF = 500ms（250ms 响 + 250ms 停，自动往复）
    localparam [31:0] HALF_A4     = CLK_FREQ_HZ / (2 * 440);
    //   ↑ 作用: A4 音（≈440Hz，标准音高）的半周期计数值 —— 故障告警音用
    //     25MHz 时 ≈ 28409。比按键音低一个多八度，听感更"沉闷"
    localparam [31:0] ALARM_OFF   = (CLK_FREQ_HZ / 1000) * 700;
    //   ↑ 作用: 故障告警音的"静"段 = 700ms 对应的时钟周期数
    //     先静后响: 上电进入故障态不会立刻惊到用户，且与应急音的等长节奏错开
    localparam [31:0] ALARM_ON    = (CLK_FREQ_HZ / 1000) * 300;
    //   ↑ 作用: 故障告警音的"响"段 = 300ms 对应的时钟周期数
    //     完整循环 = 1000ms（700ms 静 + 300ms 响），每秒提醒一次，不吵人

    // ================= 机制划分（本次改造的核心）=========================
    // 改造前：三件事挤在同一个 always 块里，文件头把整个模块归为
    //         "计数器 + 时间窗口（可看作极简两状态序列，但不算状态机）"。
    // 问题：这与 docs/design_patterns.md 对 LSM 的定义（计数器推进固定序列、
    //       下一步唯一确定、转移不依赖外部输入）互相冲突 —— 按前者口径它
    //       确实是 LSM，按后者的"不算状态机"排除法又落在第三类。这就是
    //       所谓的「定义分歧」。
    // 改造后：按"下一步由谁决定"这条唯一分界线把它拆成三个机制，
    //         每个机制只归属一个范式，分歧消除：
    //
    //   机制 A  按键音窗口  → **标准两态 FSM（三段式）**
    //            转移含外部输入 trig，故属有限状态机。
    //   机制 B  应急音相位  → **标准线性序列机（LSM）**
    //            序列 E_MUTE → E_SOUND → E_MUTE …，只由 emerg_cnt 推进，
    //            下一步唯一确定；tone_sel 只是"是否运行"的门控，不决定去向。
    //   机制 C  方波半周期  → **标准线性序列机（LSM）**
    //            序列 SQ_LO → SQ_HI → SQ_LO …，只由 half_cnt 推进。
    //
    // 【写法铁律（比"单一 always 块"更准确的表述）】
    //   **同一个变量只由一个 always 块驱动**。早期版本把 beep_cnt 拆到两个块
    //   里赋值造成多驱动（仿真出 X 态），踩过这个坑。只要遵守"变量单驱动"，
    //   按职责拆成多个块是安全且更易读的 —— 本文件现在是 5 个时序块 +
    //   1 个组合块，各自变量互不交叉。
    // =====================================================================

    // ---- 机制 A：按键音窗口 —— 标准两态 FSM（三段式）--------------------
    localparam [0:0] B_IDLE = 1'b0;    // 窗口关闭：无按键音
    localparam [0:0] B_BEEP = 1'b1;    // 窗口打开：按键音发声

    reg [0:0]  beep_state;             // 现态（第①段寄存器）
    reg [0:0]  beep_next;              // 次态（第②段组合）
    reg [31:0] beep_cnt;               // 窗口剩余计数（第③段配套）

    // 第①段：状态寄存器 —— 只搬运次态，不含任何判断
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) beep_state <= B_IDLE;
        else        beep_state <= beep_next;
    end

    // 第②段：次态组合逻辑 —— 只做判断，不写任何寄存器
    //   B_BEEP 态里 trig 优先：改造前 `if (trig) begin beep_run<=1; beep_cnt<=0; end`
    //   是无条件重触发，即使窗口正要到期也必须重新开始 —— 这里显式保留，
    //   否则"到期那一拍恰好吃到 trig"就会丢一次按键音。
    always @(*) begin
        beep_next = beep_state;                              // 默认保持，防 latch
        case (beep_state)
            B_IDLE : if (trig)                       beep_next = B_BEEP;
            B_BEEP : if (trig)                       beep_next = B_BEEP;   // 重触发
                     else if (beep_cnt >= BEEP_TICKS - 1) beep_next = B_IDLE;
            default:                                 beep_next = B_IDLE;
        endcase
    end

    // 第③段：输出 + 计数 —— beep_run 是 Moore 输出，只由现态决定
    wire beep_run = (beep_state == B_BEEP);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                       beep_cnt <= 32'd0;
        else if (trig)                                    beep_cnt <= 32'd0;   // 重新触发
        else if (beep_run && (beep_cnt < BEEP_TICKS - 1)) beep_cnt <= beep_cnt + 32'd1;
    end

    // ---- 机制 B：应急音相位 —— 标准线性序列机（LSM）---------------------
    // 序列：E_MUTE（停 250ms）→ E_SOUND（响 250ms）→ E_MUTE …
    // 推进完全由 emerg_cnt 决定，本拍不看 tone_sel 之外的任何信号；
    // tone_sel 在此只充当"序列是否运行"的门控，不参与决定下一相去哪。
    localparam [0:0] E_MUTE  = 1'b0;   // 停段（同步于原 emerg_on=0）
    localparam [0:0] E_SOUND = 1'b1;   // 响段

    reg [0:0]  emerg_phase;
    reg [31:0] emerg_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emerg_phase <= E_MUTE;                   // 复位停在停段（不响）
            emerg_cnt   <= 32'd0;
        end
        else if (tone_sel == 2'd2) begin
            if (emerg_cnt >= (EMERG_HALF * 2) - 1)
                emerg_cnt <= 32'd0;                  // 走完一整圈，计数器归零
            else
                emerg_cnt <= emerg_cnt + 32'd1;
            // 相位由计数器区间唯一确定：这是 LSM 的"固定序列"本体
            emerg_phase <= (emerg_cnt < EMERG_HALF) ? E_SOUND : E_MUTE;
        end
        else begin
            emerg_phase <= E_MUTE;                   // 非应急音：序列复位到首步
            emerg_cnt   <= 32'd0;
        end
    end

    wire emerg_on = (emerg_phase == E_SOUND);
    // 【与改造前的等价性】改造前是 `emerg_on <= (emerg_cnt < EMERG_HALF)`，
    //   一个时序块内直接寄存；上面把同一个寄存动作改写成"显式相位枚举 +
    //   区间译码"，复位值同为 0（停段），每拍更新条件与算术完全一致，
    //   因此逐拍、逐边沿都与改造前相同，不存在相位偏移。

    // ---- 机制 D：故障告警音相位 —— 标准线性序列机（LSM）-----------------
    // 序列：A_REST（静 700ms）→ A_SOUND（响 300ms）→ A_REST …
    // 用途: err_prompt 判定出"用户需要处理的错误"并持续 1.5s 后请求鸣响，
    //       使故障不只体现在数码管上，还有听觉通道（改造前故障时全场静音）。
    // 【为什么与既有两种音都不同】三音必须在**音高**和**节奏**上都能区分，
    //   否则用户分不清"按了键""进了应急模式""设备坏了"：
    //     按键音    C5 523Hz，单次 100ms 短促        —— 交互确认
    //     应急音    E6 1319Hz，250ms 响/250ms 停循环  —— 高音急促，警示逃生
    //     故障告警  A4 440Hz， 300ms 响/700ms 停循环  —— 低音沉闷，警示故障
    //   低音+长间隔，听感"沉重拖沓"，与应急音的高音急促形成明显反差。
    localparam [0:0] A_REST  = 1'b0;   // 静段
    localparam [0:0] A_SOUND = 1'b1;   // 响段

    reg [0:0]  alm_phase;
    reg [31:0] alm_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alm_phase <= A_REST;                      // 复位停在静段（不响）
            alm_cnt   <= 32'd0;
        end
        else if (tone_sel == 3'd3) begin
            if (alm_cnt >= (ALARM_ON + ALARM_OFF) - 1)
                alm_cnt <= 32'd0;                     // 走完一整圈，计数器归零
            else
                alm_cnt <= alm_cnt + 32'd1;
            // 相位由计数器区间唯一确定（LSM 的"固定序列"本体）。
            // 注意区间取**后段为响**：上电首步落在静段，避免一到故障态就立刻响。
            alm_phase <= (alm_cnt >= ALARM_OFF) ? A_SOUND : A_REST;
        end
        else begin
            alm_phase <= A_REST;                      // 非故障音：序列复位到首步
            alm_cnt   <= 32'd0;
        end
    end

    wire alarm_on = (alm_phase == A_SOUND);

    // ---- 机制 C：方波半周期 —— 标准线性序列机（LSM）---------------------
    // 序列：SQ_LO（半周低）→ SQ_HI（半周高）→ SQ_LO …
    // 推进完全由 half_cnt 决定；sq_en 只是门控。
    localparam [0:0] SQ_LO = 1'b0;     // 本半周输出低
    localparam [0:0] SQ_HI = 1'b1;     // 本半周输出高

    reg [0:0]  sq_phase;
    reg [31:0] half_cnt;

    wire [31:0] half_period = (tone_sel == 3'd2) ? HALF_E6 :
                              (tone_sel == 3'd3) ? HALF_A4 : HALF_C5;
                            // 【当前音调的半周期值】按模式三选一:
                            //   模式 2（应急音）  → HALF_E6（高音，急促警示）
                            //   模式 3（故障告警）→ HALF_A4（低音，沉重警示）
                            //   其余（按键音等）  → HALF_C5（中音，柔和不刺耳）
                            //   作用: 方波发生器按它决定"数多少拍翻转一次相位"
    wire sq_en = (tone_sel == 3'd1 && beep_run) ||
                 (tone_sel == 3'd2 && emerg_on) ||
                 (tone_sel == 3'd3 && alarm_on);
                            // 【发声使能（门控，非序列转移）】
                            //   只决定"序列此刻走不走"，不决定"下一步去哪"

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq_phase <= SQ_LO;
            half_cnt <= 32'd0;
        end
        else if (sq_en) begin
            if (half_cnt >= half_period - 1) begin
                half_cnt <= 32'd0;
                sq_phase <= ~sq_phase;               // 数够半周期 → 翻到下一相
            end
            else begin
                half_cnt <= half_cnt + 32'd1;
            end
        end
        else begin
            half_cnt <= 32'd0;
            sq_phase <= SQ_LO;                       // 静音：停在低相位
        end
    end

    wire sq = sq_phase;    // 内部方波（高=发声）

    // ============ always 块 ⑥ / 共 6 块: 输出极性转换 ============
    // 功能: 把内部方波 sq 取反后送出。板上是 PNP 三极管驱动，FPGA 输出
    //       **低电平**时三极管才导通发声，故必须取反（内部约定 sq 高 = 发声）
    // 输入: clk, rst_n, sq            输出: buzzer_out
    // 说明: 复位值取 1（= 静音态）—— 否则上电瞬间蜂鸣器会"嘟"一声
    //       本块只驱动 buzzer_out，与上面各块无变量交叉，符合"变量单驱动"
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            buzzer_out <= 1'b1;
        else
            buzzer_out <= ~sq;
    end

endmodule
