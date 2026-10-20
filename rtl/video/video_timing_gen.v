// =============================================================================
// video_timing_gen.v — 640×480@60Hz 视频时序发生器
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 视频层 —— 整条视频通路的"节拍源"，一切像素数据的时空基准
//   工程归属 : project/hdmi_td.al（被 dmz_eg4s20_hdmi_top.v 例化为 u_vtg）
//   数据流位置:
//       hdmi_pll 提供的 25MHz 像素时钟
//            ↓
//       【本模块】──→ hs / vs      行场同步（可直接送显示器/HDMI）
//            │      ──→ de          数据有效（告诉下游"此刻的像素是真的"）
//            │      ──→ active_x/y  有效区内像素坐标 0~639 / 0~479
//            └─────→ frame_start  帧起始脉冲（预留给阶段四双缓冲切换）
//            ↓
//       test_pattern_gen（用 de + 坐标决定每个像素的颜色）
//   为什么需要它:
//     显示器不认"随便输出的像素"，只认带同步信号的规范像素流：每行要有行同步
//     脉冲、每帧要有场同步脉冲，且同步段宽度与前后沿长度都必须符合 VESA 标准。
//     时序错一点，显示器就黑屏或花屏。本模块就是产生这套"时空坐标系"的源头。
//
// 【二、本模块功能】
//   一句话职责: 按 VESA 640×480@60Hz 标准产生行/场同步信号与有效区像素坐标。
//   关键特性:
//     - 全参数化: H/V 的 ACTIVE/FP/SYNC/BP 与极性均为 parameter，换分辨率
//       只改参数、逻辑一行不动（对比官方 color_bar 用 `ifdef 宏选择分辨率）
//     - 同步信号用组合译码（段宽精确到 1 像素、无毛刺逻辑依赖）；
//       de 与坐标用寄存器输出且**同拍更新**，保证与下游组合逻辑严格对齐
//     - frame_start 定位在"有效区首行开始前"，供未来双缓冲切换使用
//
// 【三、接口与内部结构】
//   端口一览:
//     输入  pixel_clk  : 像素时钟 25MHz（上板由 hdmi_pll 产生）
//     输入  rst_n      : 低有效复位
//     输出  hs         : 行同步（组合输出，负极性，宽 96 像素）
//     输出  vs         : 场同步（组合输出，负极性，宽 2 行）
//     输出  de         : 数据有效（寄存器输出，1 = 当前像素属于可见区）
//     输出  active_x   : 有效区内 X 坐标 0~639（寄存器输出）
//     输出  active_y   : 有效区内 Y 坐标 0~479（寄存器输出）
//     输出  frame_start: 帧起始单拍脉冲（寄存器输出）
//
//   内部逻辑块（共 4 块）:
//     [1] 行计数器 h_cnt        always @(posedge pixel_clk or negedge rst_n)
//           功能: 0 → 799 循环计数，代表"当前在一行中的第几个像素"
//           输入: pixel_clk, rst_n            输出: h_cnt[10:0]
//     [2] 场计数器 v_cnt        always @(posedge pixel_clk or negedge rst_n)
//           功能: 0 → 524 循环计数，**仅在行末递增**（代表"当前是第几行"）
//           输入: pixel_clk, rst_n, h_cnt     输出: v_cnt[9:0]
//     [3] 同步与有效区译码      assign（组合逻辑）
//           功能: 由 h_cnt/v_cnt 直接比较译码出 h_sync_act / v_sync_act / de_c
//           输入: h_cnt, v_cnt                输出: hs, vs, de_c
//     [4] 输出寄存器组          always @(posedge pixel_clk or negedge rst_n)
//           功能: 把 de_c、坐标、帧脉冲寄存一拍，使三者严格同拍输出
//           输入: de_c, h_cnt, v_cnt          输出: de, active_x, active_y, frame_start
//
//   【时序参数】（来源: 官方 lab_ex5_i2s/SD/color_bar.v L42-53，已核实）
//     H: SYNC=96, BP=48, ACTIVE=640, FP=16  → TOTAL = 800
//     V: SYNC=2,  BP=33, ACTIVE=480, FP=10  → TOTAL = 525
//     HS/VS 负极性（VESA 标准）
//     行内次序: [同步段][后沿][有效区][前沿]
//     （与官方 color_bar 的"FP 在行首"写法相位不同，但段宽与总线数一致，
//       接收端可正常锁定 —— 已通过仿真的帧率与行周期测量验证）
//
// 【四、设计思路与范式】
//   主要范式 : 线性序列机（LSM）—— **本项目最经典的 LSM 案例**
//   次要范式 : 组合译码（由计数值译码出同步信号）+ 打拍（输出寄存器组）
//   为什么这样写（关键认知）:
//     视频时序的本质是一台"二维秒表"：像素时钟每来一拍，横向计数器走一步；
//     一行走满（800 拍）就进位到场计数器；一场走满（525 行）就回到开头。
//     整个过程**没有任何条件分支** —— 无论画面内容是什么，时序都必须一模一样，
//     所以它是最纯粹的线性序列机，而非状态机。
//   关键写法要点:
//     1) 嵌套计数: 行计满作为场计数的使能（`if (h_cnt == H_TOTAL-1)`），
//        这是 LSM 实现"二维序列"的标准手法
//     2) 同步信号用组合译码: `assign hs = ~(h_cnt < H_SYNC)` ——
//        直接由计数值比较得出，段宽精确到 1 个像素
//     3) de 与坐标必须**同拍寄存**: 若 de 寄存而坐标不寄存（或反之），
//        像素与坐标会错开一拍 → 整幅图偏移 1 像素（本项目踩过这个坑）
//     4) 消隐期坐标强制归零: `de_c ? (h_cnt - H_ACT_START) : 11'd0` ——
//        既保证 de=0 时坐标无意义，又避免计数器无谓翻转（省功耗、少毛刺）
//   与 FSM 的区分: 若把"下一步"改成依赖输入的分支，它就变成状态机了 ——
//     但视频时序恰恰**不能**依赖输入，否则画面会随内容变形
//   范式认读方法: 见 docs/design_patterns.md
// =============================================================================
`timescale 1ns / 1ps

module video_timing_gen #(
    // ========== 行时序参数（单位: 像素）==========
    parameter H_ACTIVE = 11'd640,   // 行有效像素数（= 横向分辨率）。640×480 模式取 640
    parameter H_FP     = 11'd16,    // 行前沿 Front Porch: 有效区结束 → 行同步开始之间的空像素数
                                    //   （给显示器留出"提前量"，是 VESA 时序标准的固定组成部分）
    parameter H_SYNC   = 11'd96,    // 行同步脉冲宽度（像素数）。640×480@60 标准值 = 96
    parameter H_BP     = 11'd48,    // 行后沿 Back Porch: 行同步结束 → 有效区开始之间的空像素数
                                    //   （显示器在这段时间里完成行起始定位与电平恢复）
    // ========== 场时序参数（单位: 行）==========
    parameter V_ACTIVE = 10'd480,   // 场有效行数（= 纵向分辨率）
    parameter V_FP     = 10'd10,    // 场前沿: 有效区结束 → 场同步开始之间的空行数
    parameter V_SYNC   = 10'd2,     // 场同步脉冲宽度（行数）。640×480@60 标准值 = 2
    parameter V_BP     = 10'd33,    // 场后沿: 场同步结束 → 有效区开始之间的空行数
    // ========== 同步极性 ==========
    parameter HS_POL   = 1'b0,      // 行同步极性: 0 = 负极性（低电平有效）, 1 = 正极性
                                    //   VESA 640×480@60 用负极性（与官方例程参数一致）
    parameter VS_POL   = 1'b0       // 场同步极性: 同上。极性填错会导致显示器无法锁定
)(
    input  wire        pixel_clk,    // 像素时钟 25.175MHz（上板由 PLL 产生）
    input  wire        rst_n,        // 低有效复位
    output wire        hs,           // 行同步
    output wire        vs,           // 场同步
    output reg         de,           // 数据有效
    output reg  [10:0] active_x,     // 有效区 X 0~639
    output reg  [9:0]  active_y,     // 有效区 Y 0~479
    output reg         vblank,       // 垂直消隐，与 de 同拍，不受水平消隐影响
    output reg         frame_start   // 帧起始单拍脉冲（有效区首行前）
);

    // ===== 由上面的 parameter 自动推导的派生常量（改分辨率时无需手动改这里）=====
    // 视频时序的"四段式"约定: 一行 = [同步段][后沿][有效区][前沿]
    // 因此"有效区起点" = 同步宽 + 后沿宽；下面这些常量让译码表达式自解释。
    localparam H_TOTAL     = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 一行总像素数（含消隐）= 800
                                                                //   行计数器数到这个值就归零
    localparam V_TOTAL     = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 一帧总行数（含消隐）= 525
                                                                //   场计数器数到这个值就回到第 0 行
    localparam H_ACT_START = H_SYNC + H_BP;                     // 有效区在一行中的起始像素 = 144
                                                                //   即"同步段+后沿"结束的位置
    localparam H_ACT_END   = H_ACT_START + H_ACTIVE;            // 有效区在一行中的结束位置 = 784（不含）
                                                                //   用于判断 h_cnt 是否仍处于可见区
    localparam V_ACT_START = V_SYNC + V_BP;                     // 有效区在一帧中的起始行号 = 35
    localparam V_ACT_END   = V_ACT_START + V_ACTIVE;            // 有效区在一帧中的结束行号 = 515（不含）

    reg [10:0] h_cnt;       // 【行内像素计数器】0 ~ 799（H_TOTAL-1）
                            //   每个像素时钟 +1，到 799 归零并进位到 v_cnt
                            //   作用: 相当于"横向秒表"——既用于译码行同步信号，
                            //         也用于算出当前像素的有效区坐标 active_x
    reg [9:0]  v_cnt;       // 【帧内行计数器】0 ~ 524（V_TOTAL-1）
                            //   仅在行末（h_cnt 到 799）递增，到 524 归零
                            //   作用: 相当于"纵向秒表"——译码场同步信号，并算出 active_y

    // ============ always 块 ① / 共 3 块: 行计数器（横向秒表）============
    // 功能: 每个像素时钟加一，数到 H_TOTAL-1（799）归零，如此循环
    //       它是"横向时间轴"—— 行同步信号、有效区判定、active_x 全由它派生
    // 输入: pixel_clk, rst_n            输出: h_cnt
    // 说明: "数满即归零"正是线性序列机的特征：走完一圈自动从头，无任何条件分支
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n)
            h_cnt <= 11'd0;
        else if (h_cnt == H_TOTAL - 1)
            h_cnt <= 11'd0;
        else
            h_cnt <= h_cnt + 11'd1;
    end

    // =========== always 块 ② / 共 3 块: 场计数器（纵向秒表）===========
    // 功能: 仅在**行末**（h_cnt 计到 799）递增一次，数到 V_TOTAL-1（524）归零
    //       它是"纵向时间轴"—— 场同步信号与 active_y 由它派生
    // 输入: pixel_clk, rst_n, h_cnt      输出: v_cnt
    // 说明: "行计满作为场计数的使能"是线性序列机实现**二维嵌套序列**的标准手法
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n)
            v_cnt <= 10'd0;
        else if (h_cnt == H_TOTAL - 1)
            v_cnt <= (v_cnt == V_TOTAL - 1) ? 10'd0 : (v_cnt + 10'd1);
    end

    // 同步信号（组合译码, 段宽精确）
    wire h_sync_act = (h_cnt < H_SYNC);
                            // 【行同步"有效段"标志】当前像素位于行同步脉冲内
                            //   判据: 行内前 96 个像素（H_SYNC=96）
    wire v_sync_act = (v_cnt < V_SYNC);
                            // 【场同步"有效段"标志】当前行位于场同步脉冲内
                            //   判据: 帧内前 2 行（V_SYNC=2）
    assign hs = HS_POL ? h_sync_act : ~h_sync_act;
                            // 【行同步输出】按 HS_POL 决定极性
                            //   负极性(HS_POL=0) → 有效段输出低电平（VESA 640×480 用此）
    assign vs = VS_POL ? v_sync_act : ~v_sync_act;
                            // 【场同步输出】同上，极性由 VS_POL 决定

    // 有效区判定
    wire h_act = (h_cnt >= H_ACT_START) && (h_cnt < H_ACT_END);
                            // 【行内处于可见区】当前像素落在 144~783 之间
                            //   即 [同步段+后沿] 之后、前沿之前的那 640 个像素
    wire v_act = (v_cnt >= V_ACT_START) && (v_cnt < V_ACT_END);
                            // 【帧内处于可见区】当前行落在 35~514 之间（共 480 行）
    wire de_c  = h_act && v_act;
                            // 【数据有效原始标志】行与场同时处于可见区 → 当前像素是真的
                            //   注意: 这是"下一拍"要寄存进 de 的值（组合中间量）

    // ========== always 块 ③ / 共 3 块: 输出寄存器（同拍对齐）==========
    // 功能: 把组合译码得到的 de_c、以及由 h_cnt/v_cnt 算出的有效区坐标，
    //       **在同一个时钟沿一起寄存**，保证 de / active_x / active_y 严格同拍
    // 输入: pixel_clk, rst_n, de_c, h_cnt, v_cnt
    // 输出: de, active_x, active_y, frame_start
    // ⚠️ 为什么必须同拍: 下游 test_pattern_gen 是组合逻辑，它依据"这一拍"的
    //    de/坐标决定像素颜色。若 de 与坐标错开一拍，整幅图会向右偏移 1 个像素
    //    （本项目早期正是如此，已修复并记入 docs/progress.md）
    // 说明: 消隐期把坐标强制归零 —— 功能上非必需（de=0 时下游不采信），
    //       但可避免计数器无谓翻转，减少功耗与毛刺
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            de          <= 1'b0;
            vblank      <= 1'b1;
            active_x    <= 11'd0;
            active_y    <= 10'd0;
            frame_start <= 1'b0;
        end
        else begin
            de          <= de_c;
            vblank      <= !v_act;
            active_x    <= de_c ? (h_cnt - H_ACT_START) : 11'd0;
            active_y    <= de_c ? (v_cnt - V_ACT_START) : 10'd0;
            // 帧起始脉冲: 在"有效区首行开始前"的最后一个像素位置发出
            // （即 v_cnt = V_ACT_START-1 的行末）。修复前用 V_ACT_START,
            //  实际落在有效区第一行的行末 —— 晚了一整行, 与注释语义不符。
            frame_start <= (v_cnt == V_ACT_START - 10'd1) && (h_cnt == H_TOTAL - 1);
        end
    end

endmodule
