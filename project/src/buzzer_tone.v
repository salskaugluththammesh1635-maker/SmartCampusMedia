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
//   一句话职责: 用一根 IO 驱动无源蜂鸣器，发出按键提示音与应急提示音。
//   关键特性:
//     - 三种模式由 tone_sel 选择: 0=静音 / 1=按键音(C5≈523Hz, 100ms) /
//       2=应急音(E6≈1319Hz, 250ms 响 / 250ms 停 自动循环)
//     - **单 always 块结构**: 全部内部寄存器只在一个块内赋值（防多驱动）
//     - 时钟频率参数化: 50MHz 换 25MHz 只需改参数，逻辑一行不动
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  clk         : 系统时钟（25MHz）
//     输入  rst_n       : 低有效复位
//     输入  tone_sel[1:0]: 音调模式选择（0=静音 / 1=按键音 / 2=应急音）
//     输入  trig        : 单拍触发（按键事件，开启 100ms 发声窗口）
//     输出  buzzer_out  : 蜂鸣器驱动（**低电平响**，因板上为 PNP 驱动）
//
//   内部逻辑块（共 2 块）:
//     [1] 声源状态机          always @(posedge clk)   （一个块内含三个子功能）
//           a) 按键音窗口: trig 到达后 beep_run 置 1，维持 BEEP_TICKS(100ms) 后清零
//              输入: trig                            输出: beep_run, beep_cnt
//           b) 应急音相位: 以 EMERG_HALF(250ms) 为半周期循环，产生"响/停"交替
//              输入: tone_sel                        输出: emerg_on, emerg_cnt
//           c) 方波发生器: 在发声窗口内按 half_period 翻转 sq
//              输入: tone_sel, beep_run, emerg_on    输出: sq, half_cnt
//     [2] 输出取反            always @(posedge clk)
//           功能: buzzer_out <= ~sq（转换成低电平有效的板级极性）
//           输入: sq                              输出: buzzer_out
//
//   【板级事实】来源: 走近FPGA 表1.5 + 核心板原理图 p4 BUZ 区（已核实）
//     无源蜂鸣器，PNP(MMBT3906) 驱动: FPGA 输出**低电平** → 三极管导通 → 发声
//     Buzzer_Out = 球 H11；音调由输出方波的频率决定
//
// 【四、设计思路与范式】
//   主要范式 : 计数器/分频器 —— 方波由"半周期计数翻转"产生
//   次要范式 : 时间窗口控制（可看作极简的两状态序列：响 / 停）
//   为什么这样写:
//     无源蜂鸣器要的是**方波**而不是"高电平"。产生方波的标准手法是：
//     用计数器数够半个周期就翻转一次输出，如此往复。核心公式：
//         f_out = f_clk / (2 × half_period)
//     反过来求计数初值: half_period = f_clk / (2 × f_out)
//     例: 50MHz 时钟产生 523Hz(C5) → half_period = 50_000_000/(2×523) ≈ 47801
//   关键写法要点:
//     1) **单一 always 块驱动全部内部寄存器** —— 早期版本把 beep_cnt 分散在
//        两个块里赋值，造成多驱动（仿真出 X 态）。"一个状态变量只由一个块
//        负责"是 FPGA 设计的铁律
//     2) 参数化换算而非硬编码常数: 用 CLK_FREQ_HZ 参与运算，换时钟不动逻辑
//     3) 复位时必须让输出停在"静音态"（buzzer_out = 1），否则上电瞬间
//        蜂鸣器会响一声
//   与 FSM 的区别: 这里的"响/停"虽然看起来像状态，但其转移完全由**计数器**
//     决定（数到 250ms 就切），不依赖任何外部输入，因此归类为"计数器 +
//     时间窗口"而非状态机
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
    input  wire [1:0] tone_sel,       // 0=静音 1=按键音 2=应急音
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

    reg [31:0] beep_cnt;      // 按键音剩余窗口计数
    reg [31:0] emerg_cnt;     // 应急音相位计数
    reg [31:0] half_cnt;      // 方波半周期计数
    reg        sq;            // 内部方波（高=发声）
    reg        beep_run;      // 按键音进行中
    reg        emerg_on;      // 应急音响段

    wire [31:0] half_period = (tone_sel == 2'd2) ? HALF_E6 : HALF_C5;
                            // 【当前音调的半周期值】按模式二选一:
                            //   模式 2（应急音）  → HALF_E6（高音，急促警示）
                            //   其余（按键音等）  → HALF_C5（中音，柔和不刺耳）
                            //   作用: 方波发生器按它决定"数多少拍翻转一次 sq"

    // ========= always 块 ① / 共 2 块: 声源状态（窗口 + 相位 + 方波）=========
    // 功能: 一个块内顺序完成三件事（共用同一套时钟与复位）:
    //       ① 按键音窗口: trig 触发 beep_run，计数满 100ms 后自动清零
    //       ② 应急音相位: 以 250ms 为半周期，产生 emerg_on 的"响/停"交替
    //       ③ 方波发生器: 在发声窗口内按 half_period 翻转 sq
    // 输入: clk, rst_n, tone_sel, trig
    // 输出: beep_cnt, beep_run, emerg_cnt, emerg_on, half_cnt, sq
    // 说明: 采用"单一 always 块管全部状态"的结构 —— 早期版本把 beep_cnt 拆到
    //       两个块里赋值，造成多驱动（仿真出 X 态），是本项目踩过的坑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beep_cnt  <= 32'd0;
            emerg_cnt <= 32'd0;
            half_cnt  <= 32'd0;
            sq        <= 1'b0;
            beep_run  <= 1'b0;
            emerg_on  <= 1'b0;
        end
        else begin
            // ---- 按键音窗口（trig 触发, 持续 100ms）----
            if (trig) begin
                beep_run <= 1'b1;
                beep_cnt <= 32'd0;
            end
            else if (beep_run) begin
                if (beep_cnt >= BEEP_TICKS - 1)
                    beep_run <= 1'b0;
                else
                    beep_cnt <= beep_cnt + 32'd1;
            end

            // ---- 应急音相位（250ms 响 / 250ms 停, 自动循环）----
            if (tone_sel == 2'd2) begin
                if (emerg_cnt >= (EMERG_HALF * 2) - 1)
                    emerg_cnt <= 32'd0;
                else
                    emerg_cnt <= emerg_cnt + 32'd1;
                emerg_on <= (emerg_cnt < EMERG_HALF);
            end
            else begin
                emerg_cnt <= 32'd0;
                emerg_on  <= 1'b0;
            end

            // ---- 方波发生（仅发声窗口内切换）----
            if ((tone_sel == 2'd1 && beep_run) ||
                (tone_sel == 2'd2 && emerg_on)) begin
                if (half_cnt >= half_period - 1) begin
                    half_cnt <= 32'd0;
                    sq       <= ~sq;
                end
                else begin
                    half_cnt <= half_cnt + 32'd1;
                end
            end
            else begin
                half_cnt <= 32'd0;
                sq       <= 1'b0;      // 静音
            end
        end
    end

    // ============ always 块 ② / 共 2 块: 输出极性转换 ============
    // 功能: 把内部方波 sq 取反后送出。板上是 PNP 三极管驱动，FPGA 输出
    //       **低电平**时三极管才导通发声，故必须取反（内部约定 sq 高 = 发声）
    // 输入: clk, rst_n, sq            输出: buzzer_out
    // 说明: 复位值取 1（= 静音态）—— 否则上电瞬间蜂鸣器会"嘟"一声
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            buzzer_out <= 1'b1;
        else
            buzzer_out <= ~sq;
    end

endmodule
