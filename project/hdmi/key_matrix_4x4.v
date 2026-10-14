// =============================================================================
// key_matrix_4x4.v — 4×4 矩阵键盘扫描 + 逐键消抖 + 按下事件输出
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 输入层 —— 整个系统唯一的"人类意图入口"
//   工程归属 : bringup_td.al（最小系统）与 hdmi_td.al（HDMI）**两个工程共用**
//   数据流位置:
//       板上 4×4 矩阵键盘（16 个物理按键，仅用 8 根线）
//            ↓
//       【本模块】──→ key_event （单拍：某键"刚被按下"）
//            │      ──→ key_code  （4 位键号 0~15）
//            └─────→ key_state （16 位按键状态位图，调试观察用）
//            ↓
//       上层使用者:
//         player_ctrl（播放控制）  ← 用 key_event + key_code 判断按了哪个键
//         hdmi_top 的图案选择器     ← KEY4/KEY5 切换测试图案
//         buzzer_tone（提示音）     ← 用 key_event 触发"按键短鸣"
//   为什么需要它:
//     16 个按键若各占一根 IO 需要 16 根线；矩阵连接只需 4+4 = 8 根。
//     代价是"不能同时读出所有按键"—— 必须轮流扫描。本模块就是那台
//     "轮流扫描 + 消除机械抖动 + 输出可靠按键事件"的机器。
//
// 【二、本模块功能】
//   一句话职责: 扫描 4×4 矩阵键盘，消除机械抖动，在按键按下的瞬间输出
//               一个单拍脉冲 + 键号。
//   关键特性:
//     - 1ms/行扫描，4ms 走完一轮；每个键连续 5 轮（20ms）采样一致才确认
//     - **16 个键各自拥有独立消抖计数器**（不是共用一个全局计数器）
//     - 只输出"按下瞬间"的单拍事件：按住不放不会连续触发（防连发）
//     - 多键同时按下时取键号最小者（低位优先），行为确定可预期
//     - 列输入经两级触发器同步，消除异步信号带来的亚稳态风险
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  clk            : 系统时钟（本工程 25MHz）
//     输入  rst_n          : 低有效复位
//     输出  key_row[3:0]   : 行扫描驱动（低电平选通当前行）
//     输入  key_col[3:0]   : 列回读（板上 10k 上拉，按下 = 低）
//     输出  key_event      : 单拍脉冲，1 = 有键刚被按下
//     输出  key_code[3:0]  : 被按下的键号 0~15
//     输出  key_state[15:0]: 16 键的稳定状态位图（调试用）
//
//   内部逻辑块（共 6 块，按信号流顺序）:
//     [1] 1ms 节拍发生器      always @(posedge clk)   计数器 scan_cnt
//           功能: 产生 scan_tick（每 1ms 一个单拍脉冲）
//           输入: clk, rst_n                输出: scan_tick
//     [2] 行计数器 row_idx    always @(posedge clk)
//           功能: 0→1→2→3→0 循环，指明"当前扫描哪一行"
//           输入: scan_tick                 输出: row_idx[1:0]
//     [3] 行驱动译码          assign（组合）
//           功能: 把 row_idx 译成"仅当前行为低"的 4 位输出
//           输入: row_idx                   输出: key_row[3:0]
//     [4] 列输入两级同步      always @(posedge clk)   寄存器 col_s0/col_s1
//           功能: 异步列信号打两拍防亚稳态；取反后得 col_pressed
//           输入: key_col                   输出: col_pressed[3:0]
//     [5] 逐键消抖            always @(posedge clk)   寄存器组 col_stable/db_cnt
//           功能: 16 个键各自计数，连续 5 次一致才翻转稳定态
//           输入: col_pressed, scan_tick, row_idx   输出: col_stable[15:0]
//     [6] 边沿检测 + 优先级编码  always @(posedge clk) + function
//           功能: 找 col_stable 的上升沿 → 产生单拍 key_event；编码出最小键号
//           输入: col_stable                输出: key_event, key_code
//
//   【板级事实】来源: 走近FPGA 表1.1 + 核心板原理图 p4 KEY 区（已核实）
//     行 Key_Row[3:0] = E10, C10, F9, D9   （FPGA 输出，低电平选通行）
//     列 Key_Col[3:0] = E11, D11, C11, F10 （FPGA 输入，10k 上拉，按下为低）
//     键号: KEY(行 r, 列 c) = 4*r + c，即 KEY0 ~ KEY15
//     ⚠️ 行序存在来源冲突（底板例程写法为反序），本工程采用走近FPGA 顺序，
//        待上板实测核定；若不符，只需调整约束文件中 key_row 的四行即可
//
// 【四、设计思路与范式】
//   主要范式 : 线性序列机（LSM）—— 行扫描部分（row_idx 无条件循环 0→3）
//   次要范式（本模块是**复合范式的典型**，共 4 种叠加）:
//     - 计数器分频 : [1] 1ms 节拍发生器
//     - 打拍/移位  : [4] 两级同步器（防亚稳态）、[6] 上升沿检测
//     - 并行阵列   : [5] 16 个独立消抖计数器（for 展开为 16 份真实寄存器）
//     - 组合编码   : [3] 行驱动译码、[6] 优先级编码函数
//   为什么这样写（关键认知）:
//     1) **为什么需要消抖**: 机械触点在按下/松开瞬间会产生 5~10ms 的电平抖动，
//        不处理的话一次按键会被识别成十几次。硬件消抖（RC 电路）增加成本，
//        软件消抖（计数确认）几乎零成本 —— 这是数字设计的经典权衡。
//     2) **为什么每键独立计数器**: 若共用计数器，多键同时按下或按键时间重叠时
//        状态会互相干扰。独立计数器实现简单（一个 64 位向量装 16 个 4 位计数器）、
//        行为确定。
//     3) **为什么只在扫描当前行时更新计数器**（本模块最关键的一点）:
//        列线读数**仅对当前被拉低的那一行有效** —— 其他行没有回路，读到的永远
//        是"未按下"。若每轮全局更新 16 个键，未扫描行的计数器会被反复清零，
//        消抖永远无法完成。这正是本项目早期踩过的真实 bug（见 progress.md）。
//     4) **为什么输出单拍事件而非电平**: 上层（切图/切模式）需要的是"用户按了
//        一下"这个动作，而不是"键正被按着"这个状态。单拍脉冲让上层无需自己做
//        边沿检测，从根上避免重复触发。
//   关键写法要点:
//     - 时序块只用 `<=`、组合块只用 `=`（早期混用被安路 TD 直接报 ERROR）
//     - 状态变量只由一个 always 块驱动（col_stable/db_cnt 都只在一处赋值）
//     - `for` 循环在 FPGA 里是"写代码省事"，综合时会完全展开为并行硬件
//     - 用 `k[3:2]` 取行号、`k[1:0]` 取列号，把一维索引映射到二维矩阵
//   范式认读方法: 见 docs/design_patterns.md
// =============================================================================
`timescale 1ns / 1ps

module key_matrix_4x4 #(
    parameter CLK_FREQ_HZ = 50_000_000,  // 系统时钟频率(Hz)。用途: 把"1ms"换算成计数初值。
                                         //   换时钟（50MHz → 25MHz）只需改这里，逻辑一行不动
    parameter DEBOUNCE_MS = 20           // 按键消抖时长(ms)。机械触点抖动约 5~10ms，
                                         //   取 20ms 有 2 倍余量；值越大越抗抖但响应越迟钝
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire [3:0]  key_row,
    input  wire [3:0]  key_col,
    output reg         key_event,
    output reg  [3:0]  key_code,
    output reg  [15:0] key_state
);

    // ---- 扫描节拍派生常量（由上面的 parameter 自动算出，改参数时无需动这里）----
    localparam [15:0] SCAN_DIV = CLK_FREQ_HZ / 1000;
    //   ↑ 作用: 1ms 对应多少个时钟周期（50MHz→50000，25MHz→25000）
    //     用法: scan_cnt 数到 SCAN_DIV-1 时产生一次 scan_tick，即行扫描节拍
    localparam [3:0]  DB_MAX   = (DEBOUNCE_MS + 3) / 4;
    //   ↑ 作用: 消抖需要"连续采样一致"的次数
    //     推导: 每轮扫描耗时 4ms（4 行 × 1ms），即每个键每 4ms 被采样 1 次
    //           → 20ms 消抖 = 20/4 = 5 次
    //     说明: 加 3 是为了向上取整，避免整数除法截断导致实际消抖时间不足

    // ---- 1ms 节拍发生器（自由运行计数器，计满即产生单拍 scan_tick）----
    reg [15:0] scan_cnt;    // 【1ms 计时器】每来一个时钟沿 +1，数到 SCAN_DIV-1 归零
                            //   作用: 为整个模块提供统一的时间基准
                            //   位宽 16 位足够（25MHz 时需数到 25000 < 65536）
    wire       scan_tick = (scan_cnt == SCAN_DIV - 16'd1);
                            // 【单拍节拍脉冲】每 1ms 出现一个时钟周期的高电平
                            //   作用: 所有扫描动作（换行、消抖采样）都在它到来时发生

    // ================= always 块 ① / 共 6 块: 1ms 节拍计数器 =================
    // 功能: scan_cnt 自由运行计数，每数满一个 1ms 周期就归零，从而让
    //       scan_tick 周期性地产生单拍脉冲（整个模块的时间基准）
    // 输入: clk, rst_n        输出: scan_cnt（供 scan_tick 比较）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            scan_cnt <= 16'd0;
        else if (scan_tick)
            scan_cnt <= 16'd0;
        else
            scan_cnt <= scan_cnt + 16'd1;
    end

    // ---- 行计数 0~3：每个 scan_tick 前进一行，循环扫描 ----
    reg [1:0] row_idx;      // 【当前扫描行号】0→1→2→3→0 循环
                            //   作用: ① 决定 key_row 哪一行为低（即选中哪一行）
                            //         ② 决定本轮该更新哪 4 个键的消抖计数器
                            //            （见下方 `k[3:2] == row_idx` 的过滤条件）
    // ================= always 块 ② / 共 6 块: 行扫描推进 =================
    // 功能: 每个 1ms 节拍把行号加一（0→1→2→3→0），实现"轮流点亮每一行"
    // 输入: clk, rst_n, scan_tick      输出: row_idx
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            row_idx <= 2'd0;
        else if (scan_tick)
            row_idx <= row_idx + 2'd1;
    end

    // ---- 行驱动：组合译码，把当前行拉低（其余行保持高）----
    // 例: row_idx=0 → key_row = ~4'b0001 = 4'b1110（仅第 0 行为低）
    assign key_row = ~(4'b0001 << row_idx);

    // ---- 列输入两级同步（防亚稳态）----
    // 列线来自板上的机械触点与 10k 上拉，相对 FPGA 内部时钟是异步信号，
    // 直接采样可能产生亚稳态 → 用两级触发器打拍后再使用。
    // 复位值为 4'hF（全 1 = 未按下，与上拉电平一致）。
    reg [3:0] col_s0, col_s1;
                            // col_s0: 【第一级同步】直接采样 key_col
                            // col_s1: 【第二级同步】再打一拍，输出给后续逻辑
                            //   为什么要两级: 列线来自板上机械触点 + 10k 上拉，相对
                            //   FPGA 内部时钟是异步信号。第一级触发器可能进入亚稳态
                            //   （输出在 0/1 之间悬而不定），再打一拍后已完全稳定
    // ================= always 块 ③ / 共 6 块: 列输入两级同步 =================
    // 功能: 把异步的列信号打两拍，消除亚稳态后再交给后续逻辑使用
    //       第一拍 col_s0 直接采 key_col，第二拍 col_s1 采 col_s0
    // 输入: clk, rst_n, key_col        输出: col_s0, col_s1
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_s0 <= 4'hF;
            col_s1 <= 4'hF;
        end
        else begin
            col_s0 <= key_col;      // 第一级：同步
            col_s1 <= col_s0;       // 第二级：再打一拍，输出给后续逻辑
        end
    end

    wire [3:0] col_pressed = ~col_s1;      // 板级按下为低 → 取反后 1 = 按下

    // ---- 逐键消抖（本模块最核心的逻辑）----
    // col_stable: 16 位"已确认稳定状态"位图，bit k = 1 表示键 k 处于按下态
    // db_cnt    : 16 个键各自的 4 位计数器，键 k 占 db_cnt[k*4 +: 4]
    reg [15:0] col_stable;  // 【键状态位图】16 个键"已确认的稳定状态"
                            //   bit k = 1 表示键 k 当前处于按下态（已通过消抖确认）
                            //   作用: 它是 key_state 的直接来源，也是产生 key_event
                            //         的边沿检测基准（与上一拍比较得出"刚按下"）
    reg [63:0] db_cnt;      // 【16 个消抖计数器】每键 4 位，共 64 位
                            //   键 k 使用 db_cnt[k*4 +: 4] 这 4 位
                            //   作用: 累计"连续采样不一致"的次数，达到 DB_MAX(5) 就
                            //         翻转 col_stable[k]，即认可按键状态改变
                            //   位宽 4 位足够（DB_MAX=5，最大计到 15 不会溢出）

    integer k;              // 【for 循环变量】仅在 always 块的 for 语句中使用
                            //   注意: 综合时循环会被**完全展开**为 16 份并行逻辑，
                            //   它不是"软件循环"——不消耗额外时间，只是写起来省事
    // ============ always 块 ④ / 共 6 块: 逐键消抖（本模块核心）============
    // 功能: 每 1ms 检查"当前扫描行"的 4 个键，为 16 个键各自累计"连续采样
    //       不一致"的次数；达到 DB_MAX(5 次) 就正式翻转该键的稳定状态
    // 输入: clk, rst_n, scan_tick, col_pressed, row_idx
    // 输出: col_stable（16 位键状态位图）, db_cnt（16 个 4 位计数器）
    // ⚠️ 关键: 只处理 k[3:2] == row_idx 的键 —— 列线读数仅对当前扫描行有效
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_stable <= 16'd0;
            db_cnt     <= 64'd0;
        end
        else if (scan_tick) begin              // 每 1ms 检查一次（此刻正在扫描某一行）
            for (k = 0; k < 16; k = k + 1) begin
                // 键号 k = 4*行 + 列 → k[3:2] 取行号，k[1:0] 取列号
                if (k[3:2] == row_idx) begin   // 只处理"当前正在扫描的这一行"的 4 个键
                    if (col_pressed[k[1:0]] == col_stable[k]) begin
                        db_cnt[k*4 +: 4] <= 4'd0;               // 采样值与稳定态一致 → 计数清零
                    end
                    else if (db_cnt[k*4 +: 4] >= DB_MAX) begin
                        col_stable[k] <= col_pressed[k[1:0]];   // 连续不一致达阈值 → 正式翻转稳定态
                    end
                    else begin
                        db_cnt[k*4 +: 4] <= db_cnt[k*4 +: 4] + 4'd1;  // 不一致但未达阈值 → 继续计数
                    end
                end
                // 非当前行的键：本轮不更新（其列线读数无意义）
            end
        end
    end

    // 键状态位图输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            key_state <= 16'd0;
        else
            key_state <= col_stable;
    end

    // 按下沿检测 + 优先级编码（低位键优先）
    reg [15:0] col_stable_d;    // 【上一拍的键状态】用于与当前状态比较，找出"刚刚按下"的键
    wire [15:0] press_edge = col_stable & ~col_stable_d;
                                // 【按下沿标志】某位为 1 = 该键本拍由"未按下"变为"按下"
                                //   原理: 当前为 1 且上一拍为 0 → 正是上升沿
                                //   作用: 只对"刚按下"的键产生事件，按住不放不会重复触发
                                //         （这是"边沿检测"的标准写法：打一拍再比较）

    // ---- 优先级编码：从 16 位按键位图中取出"键号最小"的那一个 ----
    // 循环从最高位 (15) 遍历到最低位 (0)，每次发现置位就覆盖结果变量，
    // 因此最终保留的是**最后一次写入** = 最低位的键号 ✓（低位优先）
    // 例：键 2 与键 10 同时按下 → 返回 2
    function [3:0] prio_code;
        input [15:0] v;
        integer j;
        begin
            prio_code = 4'd0;
            for (j = 15; j >= 0; j = j - 1)
                if (v[j])
                    prio_code = j[3:0];
        end
    endfunction

    // ========== always 块 ⑥ / 共 6 块: 按下沿检测 + 键号编码 ==========
    // 功能: 把 col_stable 打一拍得到 col_stable_d，两者相与即"上升沿"
    //       （press_edge）；一旦检测到按下沿，就输出单拍 key_event 并给出键号
    // 输入: clk, rst_n, col_stable, press_edge
    // 输出: col_stable_d, key_event（单拍）, key_code
    // 说明: 每拍先把 col_stable_d 与 key_event 更新/清零，保证 key_event
    //       严格只维持一个时钟周期（不会被上层误认为"长按"）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_stable_d <= 16'd0;
            key_event    <= 1'b0;
            key_code     <= 4'd0;
        end
        else begin
            col_stable_d <= col_stable;
            key_event    <= 1'b0;
            if (press_edge != 16'd0) begin
                key_event <= 1'b1;
                key_code  <= prio_code(press_edge);
            end
        end
    end

endmodule
