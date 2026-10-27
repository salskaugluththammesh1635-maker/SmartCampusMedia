// =============================================================================
//  pix_reader.v  ——  SDRAM 帧缓冲 → HDMI 像素读出
// =============================================================================
// 【一、在系统中的位置】
//   存储层 —— S5/S6 全链的最后一环。
//     framebuf_arbiter(读侧) ──本模块──→ async_fifo ──→ dmz_eg4s20_hdmi_top
//        150MHz 顺序读              跨域缓冲          25MHz 像素域
//
// 【二、核心设计：一次性对齐 + 稳态自由流】
//
//   本节记录**两次失败之后**才定下来的架构，勿轻易推翻。
//
//   失败 1（行握手）：原设计每行发 80 组突发、数满就停、等下一行重启。
//     与 framebuf_arbiter 语义根本冲突 —— 它的读侧是**自由流顺序读**，
//     rd_addr 每组 +4、到 FRAME_LAST 自动回卷，**没有地址输入端口**，
//     上游无法指定读哪一行；停下时最多 15 个组在飞会继续补完，
//     行首重启又要等 A_IDLE→A_RD 加 10 拍读延迟，而行消隐期只有 6.4us。
//     实测 rd_reqs 在 1 / 651 / 165142 / 174593 之间乱跳，无一正确。
//
//   失败 2（每帧复位 FIFO）：改为「消隐期两侧同时复位 FIFO + 归零计数器」。
//     但异步 FIFO 的写侧、读侧复位窗口**无法真正重叠**（写侧受 clk_sdr
//     同步延迟约束、读侧受 pix_clk 约束），复位后格雷码指针的**圈数**
//     不同步，rd_empty / wr_full 判定永久错乱。实测证据：
//       [F1] FLUSH t=15360955000 arb_rd_addr=396 wrc=22916 rdc=0 lvl=22916 empty=1
//     水位 22916 远超 FIFO 深度 512，物理上不可能 —— 计数器与内部指针已脱钩。
//
//   最终架构：
//     1) **异步 FIFO 运行时绝不复位**，只接系统复位。两侧格雷码指针永远
//        连续演进，空/满判定始终可信。
//     2) **一次性对齐**：复位后第一个垂直消隐期做一次 ARM 序列
//        （停请求 → 排空 FIFO → 单拍 rd_restart 让读指针归位 FRAME_BASE），
//        之后永久自由流，不再对齐。
//     3) 稳态下「每帧产生的字数」与「每帧消费的字数」都恰好是 153600
//        （640×480/2），一帧正好 38400 个 4 字突发组。framebuf 读指针
//        每帧整转一圈，与显示帧边界**自然保持相位**，因此一次对齐之后
//        不需要任何周期性干预。
//     4) 消隐期**不读 FIFO**（除 ARM 排空外）。这是失败 1/2 期间一直没抓到的
//        真凶：24 行消隐期里把下一行的预取数据当残留读掉，行首必然空。
//        实测基线 [R1]~[R15] 全是 empty=1，第 16 个像素才见到数据。
//
// 【三、时钟域】
//   clk_sdr (150MHz) —— 接仲裁器，写 FIFO
//   pix_clk (25MHz)  —— 接 video_timing_gen，读 FIFO、输出像素
//   内部逻辑块（共 6 块）：
//     [1] pix 域 ARM 序列机（一次性对齐）
//     [2] pix 域像素计数与消费
//     [3] clk_sdr 域写 FIFO 与水位数
//     [4] 跨域同步器（arm 门控、restart 脉冲）
//     [5] 像素 FIFO
//     [6] 像素输出（组合）
//
// 【四、设计约束（见 docs/ai_handover.md）】
//   - 时序块只用 <=，组合块只用 =
//   - 不使用 function / task
//   - 每个 always 块单一驱动源，避免多驱动
//   - 所有 reg/wire 先声明后使用
// =============================================================================
`timescale 1ns / 1ps

module pix_reader #(
    parameter ADDR_WIDTH   = 21,        // SDRAM 字地址位宽
    parameter FRAME_BASE   = 21'd0,     // 帧缓冲基地址（字地址）
    parameter PIX_PER_LINE = 640,       // 每行像素数（须为偶数）
    parameter Y_WIDTH      = 10,        // 行号位宽
    parameter FRAME_LINES  = 480,       // 帧高（行数），active_y 超出即消隐期
    parameter FIFO_AW      = 10,        // 像素 FIFO 深度 = 2^FIFO_AW（1024 字 ≈ 3.2 行）
    parameter LEVEL_HI     = 768,       // FIFO 水位上限（字），约 2.4 行
    parameter ARM_QUIET_C  = 256,       // ARM 静默等待拍数（须大于在飞读组最长回溯）
    parameter ARM_SETTLE_C = 32         // FIFO 读空后再确认的拍数
) (
    // ---------------- 150MHz 域（SDRAM / 仲裁器侧）----------------
    input  wire                    clk_sdr,
    input  wire                    rst_n_sdr,

    output wire                    rd_req,      // 向仲裁器请求读
    input  wire                    rd_ack,      // 新突发组已启动（1 拍脉冲，仅统计用）
    input  wire [31:0]             rd_data,     // 读出数据
    input  wire                    rd_valid,    // 读出有效（1 拍脉冲）

    output wire                    rd_restart,  // 读指针归位（单拍脉冲，仅 ARM 时一次）
    output wire [ADDR_WIDTH-1:0]   rd_base,     // 归位目标地址

    // ---------------- 25MHz 域（像素输出侧）----------------
    input  wire                    pix_clk,
    input  wire                    rst_n_pix,

    input  wire                    de,          // 数据使能
    input  wire [Y_WIDTH-1:0]      active_y,    // 当前行号，>= FRAME_LINES 为消隐期

    output wire [15:0]             pix_rgb565,  // RGB565 像素（组合，与 de 同拍）
    output wire                    pix_valid,   // 与 pix_rgb565 同拍、与 de 同相

    output wire [2:0]              stat         // [0]=underflow [1]=overflow [2]=已对齐
);

    // -------------------------------------------------------------------------
    // 常量
    // -------------------------------------------------------------------------
    localparam [15:0] LEVEL_HI_W   = LEVEL_HI;
    localparam [9:0]  ARM_QUIET_W  = ARM_QUIET_C;
    localparam [9:0]  ARM_SETTLE_W = ARM_SETTLE_C;

    localparam [2:0] ARM_IDLE    = 3'd0;   // 正常运行（已对齐或尚未开始首个消隐期）
    localparam [2:0] ARM_QUIET   = 3'd1;   // 停请求+停写，等在飞读组全部落地
    localparam [2:0] ARM_DRAIN   = 3'd2;   // 排空 FIFO
    localparam [2:0] ARM_RESTART = 3'd3;   // 发单拍 restart
    localparam [2:0] ARM_HOLD    = 3'd4;   // 等仲裁器真正停下
    localparam [2:0] ARM_WAITACT = 3'd5;   // 等显示期开始（消隐期不放开）

    // -------------------------------------------------------------------------
    // 信号声明（全部前置，Verilog-2001 先声明后使用）
    // -------------------------------------------------------------------------
    // —— pix_clk 域 ——
    reg  [2:0]   arm_st;           // ARM 序列机状态（3 位：0..5）
    reg  [9:0]   arm_cnt;          // ARM 计时
    reg          arm_rst_tog;      // 重启请求（toggle，跨到 clk_sdr 取单拍）
    reg          armed;            // 已完成一次性对齐
    reg          blank_d;          // 消隐标志打一拍，用于取上升沿
    reg  [15:0]  rd_cnt;           // 已消费字数
    reg  [10:0]  pix_cnt;          // 行内像素计数
    reg  [31:0]  word_hold;        // 当前字锁存（奇像素取高半字）
    reg          underflow_lat;    // 下溢粘滞标志
    wire         blank;            // 消隐期电平
    wire         arm_gate;         // ARM 期间禁止请求
    wire         fifo_rd_en;
    wire [31:0]  fifo_rd_data;
    wire         fifo_rd_empty;

    // —— clk_sdr 域 ——
    reg  [15:0]  wr_cnt;           // 已写入 FIFO 字数
    reg  [15:0]  rd_cnt_s1;
    reg  [15:0]  rd_cnt_s2;
    reg          arm_gate_s1;
    reg          arm_gate_s2;
    reg          arm_tog_s1;
    reg          arm_tog_s2;
    reg          arm_tog_s3;
    reg          overflow_lat;
    reg          fifo_wr_en;
    reg  [31:0]  fifo_wr_data;
    wire         fifo_wr_full;
    wire [15:0]  level;
    wire         arm_pulse;

    // -------------------------------------------------------------------------
    // [1] pix_clk 域：一次性 ARM 序列机
    //
    //    只在**首个**垂直消隐期运行一次，把状态复位到确定的起点：
    //      ARM_QUIET   —— 拉低请求，等在飞的读组全部落地
    //      ARM_DRAIN   —— 把 FIFO 里残留的字排空（读掉丢弃）
    //      ARM_RESTART —— toggle 一次，跨到 clk_sdr 取单拍脉冲给仲裁器
    //
    //    为什么"排空"而不是"复位 FIFO"：见文件头的失败 2。
    //    排空后 wr_cnt 与 rd_cnt 同步前进了相同的量，level 自然回 0，
    //    而格雷码指针保持连续，空/满判定不受任何扰动。
    // -------------------------------------------------------------------------
    assign blank    = (active_y >= FRAME_LINES);
    assign arm_gate = (arm_st != ARM_IDLE);

    always @(posedge pix_clk or negedge rst_n_pix) begin
        if (!rst_n_pix) begin
            arm_st      <= ARM_IDLE;
            arm_cnt     <= 10'd0;
            arm_rst_tog <= 1'b0;
            armed       <= 1'b0;
            blank_d     <= 1'b0;
        end else begin
            blank_d <= blank;

            case (arm_st)
                ARM_IDLE: begin
                    arm_cnt <= 10'd0;
                    // 复位后首个消隐期上升沿触发一次，之后永不再触发
                    if (!armed && blank && !blank_d) begin
                        arm_st <= ARM_QUIET;
                    end
                end

                ARM_QUIET: begin
                    if (arm_cnt >= ARM_QUIET_W) begin
                        arm_cnt <= 10'd0;
                        arm_st  <= ARM_DRAIN;
                    end else begin
                        arm_cnt <= arm_cnt + 10'd1;
                    end
                end

                ARM_DRAIN: begin
                    // 判据 = 「FIFO 空」且「仲裁器完全静止」且「持续 ARM_SETTLE_W 拍」。
                    //
                    // 三次实测证明只看 fifo_rd_empty 不够：
                    //   run1 got=2800 → 队头 x=10（差 5 个字）
                    //   run2 got=a800 → 队头 x=42（差 21 个字）
                    // 偏移量每次不同 ⇒ 是**随机在飞量**，不是固定错位。
                    // ARM_QUIET 只保证不再发新请求，但仲裁器 rd_outstanding
                    // 最多 15 条命令在飞、且 rd_grp_active 可能仍为 1，
                    // 这些数据会在随后 10+ 拍陆续写进 FIFO。
                    // 必须等 arb_quiet（输入端口）稳定为 1 才计数。
                    if (arb_quiet && fifo_rd_empty) begin
                        if (arm_cnt >= ARM_SETTLE_W) begin
                            arm_cnt     <= 10'd0;
                            arm_st      <= ARM_RESTART;
                            arm_rst_tog <= ~arm_rst_tog;
                        end else begin
                            arm_cnt <= arm_cnt + 10'd1;
                        end
                    end else begin
                        arm_cnt <= 10'd0;   // 任何一个条件不满足就重新计时
                    end
                end

                // 注意：RESTART 之后**不能立刻回 IDLE**。
                // 此时仍处于消隐期，若马上放开 rd_req，150MHz 侧会在剩下的
                // 几十行消隐期里把 FIFO 灌满（水位到 LEVEL_HI 就停，约 768 字
                // ≈ 2.4 行），而 pix 侧这期间不消费 —— 一旦进入显示期，
                // 头 2.4 行全是"提前读出来的将来数据"，整幅画面纵向错位。
                // 实测证据：first bad at (x=0,y=0) got=2800 exp=0000（偏 40 行）。
                // 因此必须等到**显示期开始**（blank 落回 0）才放开请求。
                ARM_RESTART: begin
                    if (!blank) begin
                        arm_st <= ARM_IDLE;
                        armed  <= 1'b1;
                    end
                end

                default: begin
                    arm_st <= ARM_IDLE;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // [2] pix_clk 域：像素计数与消费
    //
    //   **关键**：消隐期不读 FIFO（除 ARM 排空外）。
    //   曾经的写法 `!fifo_rd_empty && (!de || pix_cnt[0]==0)` 会在消隐期
    //   把下一行的预取数据当"残留"读掉，导致每行前 13~16 个像素恒为 0000。
    //   实测：T01 first bad at (x=22,y=7) got=6007 exp=5807。
    // -------------------------------------------------------------------------
    assign fifo_rd_en = !fifo_rd_empty &&
                        ( ((!arm_gate) && de && (pix_cnt[0] == 1'b0)) ||
                          (arm_st == ARM_DRAIN) );

    always @(posedge pix_clk or negedge rst_n_pix) begin
        if (!rst_n_pix) begin
            rd_cnt        <= 16'd0;
            pix_cnt       <= 11'd0;
            word_hold     <= 32'd0;
            underflow_lat <= 1'b0;
        end else begin
            // ---- 消费计数 + 字锁存 ----
            if (fifo_rd_en) begin
                rd_cnt    <= rd_cnt + 16'd1;
                word_hold <= fifo_rd_data;
            end

            // ---- 行内像素计数：de 期间 +1，消隐期清 0 ----
            if (!de) pix_cnt <= 11'd0;
            else     pix_cnt <= pix_cnt + 11'd1;

            // ---- 下溢检测：该取字却没数据 ----
            if (de && (pix_cnt[0] == 1'b0) && !arm_gate && fifo_rd_empty)
                underflow_lat <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // [3] clk_sdr 域：写 FIFO + 水位数
    //
    //   rd_req 只由水位决定，不做任何行/帧分割 —— 仲裁器是自由流顺序读，
    //   上游唯一能控制的就是"读多快"。ARM 期间由 arm_gate_s2 强制拉低。
    // -------------------------------------------------------------------------
    assign rd_req  = !arm_gate_s2 && (level < LEVEL_HI_W);
    assign rd_base = FRAME_BASE;

    // 水位：已写入 − 已消费（16 位回绕减法）。
    // rd_cnt_s2 比实际晚 2~3 拍 clk_sdr，因此水位估算**偏大**，
    // 结果是 rd_req 提前拉低、少填一些 —— 对防溢出是安全方向。
    assign level = wr_cnt - rd_cnt_s2;

    // 跨域重启脉冲：toggle 同步到 clk_sdr 后取边沿，得到 1 拍脉冲。
    assign arm_pulse  = arm_tog_s2 ^ arm_tog_s3;
    assign rd_restart = arm_pulse;

    always @(posedge clk_sdr or negedge rst_n_sdr) begin
        if (!rst_n_sdr) begin
            fifo_wr_en   <= 1'b0;
            fifo_wr_data <= 32'd0;
            wr_cnt       <= 16'd0;
            rd_cnt_s1    <= 16'd0;
            rd_cnt_s2    <= 16'd0;
            arm_gate_s1  <= 1'b0;
            arm_gate_s2  <= 1'b0;
            arm_tog_s1   <= 1'b0;
            arm_tog_s2   <= 1'b0;
            arm_tog_s3   <= 1'b0;
            overflow_lat <= 1'b0;
        end else begin
            fifo_wr_en <= 1'b0;        // 默认不写，只在有效且不满时置高

            // ---- 跨域同步 ----
            arm_gate_s1 <= arm_gate;
            arm_gate_s2 <= arm_gate_s1;
            arm_tog_s1  <= arm_rst_tog;
            arm_tog_s2  <= arm_tog_s1;
            arm_tog_s3  <= arm_tog_s2;

            // ---- 消费计数回同步（pix_clk → clk_sdr）----
            rd_cnt_s1 <= rd_cnt;
            rd_cnt_s2 <= rd_cnt_s1;

            // ---- 写 FIFO ----
            // 注意：wr_cnt 必须跟随**实际写入**（fifo_wr_en 的下一拍生效），
            // 不能跟 rd_valid。否则计数比 FIFO 内容多 1 字，
            // 表现为整幅画面永久错位（曾实测 T05 偏 8 像素 = 4 字）。
            if (rd_valid) begin
                if (!fifo_wr_full) begin
                    fifo_wr_en   <= 1'b1;
                    fifo_wr_data <= rd_data;
                end else begin
                    // 水位控制失灵才会走到这里，置位供上层观测
                    overflow_lat <= 1'b1;
                end
            end

            if (fifo_wr_en) begin
                wr_cnt <= wr_cnt + 16'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // [4] 像素 FIFO
    //
    //   **运行时绝不复位**（只接系统复位）。这是本文件最关键的约束：
    //   两侧复位窗口无法重叠，复位会让格雷码指针圈数不同步，
    //   空/满判定永久错乱。所有对齐都通过"排空 + 重设读指针"完成。
    // -------------------------------------------------------------------------
    async_fifo #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (FIFO_AW)
    ) u_pix_fifo (
        .wr_clk   (clk_sdr),
        .wr_rst_n (rst_n_sdr),
        .wr_en    (fifo_wr_en),
        .wr_data  (fifo_wr_data),
        .wr_full  (fifo_wr_full),
        .rd_clk   (pix_clk),
        .rd_rst_n (rst_n_pix),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .rd_empty (fifo_rd_empty)
    );

    // -------------------------------------------------------------------------
    // [5] 像素输出：**组合**，必须与 de 同拍有效
    //
    //   若写成寄存器输出，pix_rgb565 会比 de 晚一拍，
    //   HDMI 发送器采到上一拍的值 —— 逐像素比对必然全错，
    //   上板表现为整幅画面右移一个像素。
    // -------------------------------------------------------------------------
    assign pix_valid  = de;
    assign pix_rgb565 = (!de)                ? 16'd0
                      : (pix_cnt[0] == 1'b0) ? (fifo_rd_empty ? 16'd0 : fifo_rd_data[15:0])
                                             : word_hold[31:16];

    // -------------------------------------------------------------------------
    // [6] 状态汇总（各异常位由各自时钟域驱动，组合成 stat 以避免多驱动）
    // -------------------------------------------------------------------------
    assign stat = {5'd0, armed, overflow_lat, underflow_lat};

endmodule
