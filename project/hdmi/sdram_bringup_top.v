// =============================================================================
// sdram_bringup_top.v — SDRAM 150MHz 链路 bring-up 验证顶层
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 顶层（验证专用，不进正式工程 hdmi_td.al）
//   工程归属 : project/sdram_bringup_td.al（独立验证工程）
//   数据流位置:
//       50MHz 晶振(球 R7)
//            ↓
//       sdram_pll ──→ 150MHz 0° + 150MHz 180°
//            ↓
//       本模块内的读写序列机（写 8 字 → 读回比对）
//            ↓
//       sdram_ctrl_wrap ──→ sdr_as_ram(加密核) ──→ EG_PHY_SDRAM_2M_32(SIP)
//            ↓
//       LED = 结果指示
//
// 【二、本模块存在的唯一理由】
//   阶段四 S5 引入了 `sdram_pll`（1050MHz VCO → 150MHz），但这颗 PLL
//   **从未在安路 TD 工具里真正综合过**。150MHz 是本工程最高的时钟频率，
//   若时序收敛不了，整个 SDRAM 帧缓存方案（S5/S6）都是空中楼阁。
//
//   本模块把风险前置：只放 PLL + SDRAM 核 + 极简读写序列机，跑一次 headless TD，
//   用**真实的综合/布局布线/时序报告**回答三个问题：
//     ① 1050MHz VCO 配置在 EG4S20 上能否被工具接受并锁定
//     ② 150MHz 时钟域的逻辑能否满足建立/保持时间
//     ③ 加密核 `sdr_as_ram` 能否正常进工程并连上 SIP 原语
//   任一为否，都要在写 S6 全链**之前**回头改架构，而不是等全链写完才发现。
//
// 【三、设计取舍：为什么用序列机而不是例化 framebuf_arbiter】
//   验证目标是 **PLL 与 SDRAM 核**，不是仲裁逻辑。序列机只有几十行，
//   时序报告里的关键路径能清晰归因到 SDRAM 控制器本身；若把 framebuf_arbiter
//   也塞进来，关键路径会混入仲裁逻辑，"时序不收敛到底是 PLL 问题还是仲裁器
//   问题"就说不清了。**验证工程要能定位问题，而不只是给出通过/不通过。**
//
// 【四、必须遵守的 SDRAM 控制器契约（来自 APUG011 手册）】
//   1. 每 4 拍构成一个突发组，**组内地址必须恒定**，组间步长 4（字地址）
//   2. `app_*_addr[1:0]` 必须恒 `2'b00`（本模块用 {beat[3], 2'b00} 保证）
//   3. 读写不可同时发生
//   4. `ref_vld` 为高期间必须停发命令
//   5. 读延迟固定 10 拍，返回时 `sdr_rd_en` 给出单拍有效标志
//
// 【五、复位策略】
//   PLL 锁定 + 按键复位 → 三级同步释放（与 hdmi_top 完全一致的范式）。
//   SDRAM 核的 `Rst` 是高有效，由 sdram_ctrl_wrap 内部做极性转换，
//   本模块只管给出低有效的 `rst_n`。
// =============================================================================
`timescale 1ns / 1ps

module sdram_bringup_top (
    input  wire        clk,        // 50MHz 系统时钟（球 R7）
    input  wire        rst_n_btn,  // 复位按键（球 E3，低有效）
    output wire [7:0]  led         // 验证结果指示
);

    // -------------------------------------------------------------------------
    // [1] PLL 复位延时：等晶振稳定后再放行 PLL
    // -------------------------------------------------------------------------
    reg [7:0] pll_rst_cnt;

    always @(posedge clk or negedge rst_n_btn) begin
        if (!rst_n_btn)
            pll_rst_cnt <= 8'd0;
        else if (!pll_rst_cnt[7])
            pll_rst_cnt <= pll_rst_cnt + 8'd1;
    end

    wire pll_reset = ~pll_rst_cnt[7];

    // -------------------------------------------------------------------------
    // [2] sdram_pll —— 1050MHz VCO → 150MHz 0° / 150MHz 180°
    // -------------------------------------------------------------------------
    wire clk_sdr;      // 150MHz 0°，SDRAM 控制器主时钟
    wire clk_sdr_sft;  // 150MHz 180°，给 SDRAM 器件采样用
    wire pll_locked;

    sdram_pll u_pll (
        .refclk        (clk),
        .reset         (pll_reset),
        .extlock       (pll_locked),
        .sdram_clk     (clk_sdr),
        .sdram_clk_sft (clk_sdr_sft)
    );

    wire rst_n_pll = pll_locked & rst_n_btn;

    // -------------------------------------------------------------------------
    // [3] 复位同步器：异步置位、同步释放（与 hdmi_top 同范式）
    // -------------------------------------------------------------------------
    reg [2:0] rst_sync;

    always @(posedge clk_sdr or negedge rst_n_pll) begin
        if (!rst_n_pll)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], 1'b1};
    end

    wire rst_n = rst_sync[2];

    // -------------------------------------------------------------------------
    // [4] sdram_ctrl_wrap —— 加密核封装
    // -------------------------------------------------------------------------
    wire        sdr_init_done;
    wire        sdr_ref_vld;
    wire        sdr_busy;

    wire        app_wr_en;
    wire [20:0] app_wr_addr;
    wire [31:0] app_wr_din;
    wire [3:0]  app_wr_dm;
    wire        app_rd_en;
    wire [20:0] app_rd_addr;
    wire        sdr_rd_en;
    wire [31:0] sdr_rd_dout;

    // 物理 SDRAM 引脚（由本模块底部的 SIP 原语接管，不出芯片）
    wire        sdram_clk_w;
    wire        sdram_cke_w;
    wire        sdram_cs_n_w;
    wire        sdram_ras_n_w;
    wire        sdram_cas_n_w;
    wire        sdram_we_n_w;
    wire [1:0]  sdram_ba_w;
    wire [10:0] sdram_addr_w;
    wire [3:0]  sdram_dm_w;
    wire [31:0] sdram_dq_w;

    sdram_ctrl_wrap #(
        .CLK_FREQ_HZ (150_000_000)
    ) u_sdram (
        .clk         (clk_sdr),
        .clk_sft     (clk_sdr_sft),
        .rst_n       (rst_n),
        .init_done   (sdr_init_done),
        .ref_vld     (sdr_ref_vld),
        .busy        (sdr_busy),
        .app_wr_en   (app_wr_en),
        .app_wr_addr (app_wr_addr),
        .app_wr_din  (app_wr_din),
        .app_wr_dm   (app_wr_dm),
        .app_rd_en   (app_rd_en),
        .app_rd_addr (app_rd_addr),
        .sdr_rd_en   (sdr_rd_en),
        .sdr_rd_dout (sdr_rd_dout),
        .sdram_clk   (sdram_clk_w),
        .sdram_cke   (sdram_cke_w),
        .sdram_cs_n  (sdram_cs_n_w),
        .sdram_ras_n (sdram_ras_n_w),
        .sdram_cas_n (sdram_cas_n_w),
        .sdram_we_n  (sdram_we_n_w),
        .sdram_ba    (sdram_ba_w),
        .sdram_addr  (sdram_addr_w),
        .sdram_dm    (sdram_dm_w),
        .sdram_dq    (sdram_dq_w)
    );

    // -------------------------------------------------------------------------
    // [5] 极简读写序列机
    //     流程: init_done → 写 8 字（2 个突发组）→ 读回 8 字逐个比对 → 判结果
    //     错误码: 1=初始化超时 2=写超时 3=读超时 4=数据不符
    //
    //     地址生成: beat[3] 决定当前在第 0 组还是第 1 组，
    //               组基址 = {beat[3], 2'b00}，组内 4 拍地址恒定
    //     这与 framebuf_arbiter 的地址推进方式完全一致，
    //     若此处写错，SDRAM 行为模型/真核都会读回错数据。
    // -------------------------------------------------------------------------
    localparam [1:0] T_IDLE  = 2'd0,
                     T_WRITE = 2'd1,
                     T_READ  = 2'd2,
                     T_DONE  = 2'd3;

    reg [1:0]  tst_st;
    reg [3:0]  beat;        // 0~8（8 为越界哨兵，表示本轮完成）
    reg [7:0]  tst_err;
    reg [3:0]  rd_cnt;      // 已收回的读数据个数
    reg [15:0] wait_cnt;

    // 读数据比对寄存器（先声明后使用；Verilog-2001 不允许多处声明）
    reg        rd_en_q;          // sdr_rd_en 打一拍，作为"比较结果可用"的节拍
    reg        rd_mismatch;      // 本拍收到的读数据与期望不符

    // 测试数据：低 4 位带序号、高半字为固定图案。
    // 序号参与生成 → 若地址线/列地址错位，读回的值必然不匹配。
    wire [3:0]  wr_idx = beat;
    wire [3:0]  rd_idx = rd_cnt;
    wire [31:0] wr_data = {16'hA500, wr_idx, 12'h5A0};
    wire [31:0] rd_expect = {16'hA500, rd_idx, 12'h5A0};

    assign app_wr_en   = (tst_st == T_WRITE) && (beat != 4'd8) && !sdr_ref_vld;
    assign app_wr_addr = {18'd0, beat[3], 2'b00};
    assign app_wr_din  = wr_data;
    assign app_wr_dm   = 4'h0;                  // 0 = 写（1 才是屏蔽）

    assign app_rd_en   = (tst_st == T_READ) && (beat != 4'd8) && !sdr_ref_vld;
    assign app_rd_addr = {18'd0, beat[3], 2'b00};

    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n) begin
            tst_st   <= T_IDLE;
            beat     <= 4'd0;
            tst_err  <= 8'd0;
            rd_cnt   <= 4'd0;
            wait_cnt <= 16'd0;
        end else begin
            case (tst_st)
                T_IDLE: begin
                    if (sdr_init_done) begin
                        tst_st   <= T_WRITE;
                        wait_cnt <= 16'd0;
                    end else if (wait_cnt == 16'hFFFF) begin
                        tst_err <= 8'd1;              // 初始化超时
                        tst_st  <= T_DONE;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                T_WRITE: begin
                    if (!sdr_ref_vld) begin
                        wait_cnt <= 16'd0;
                        if (beat == 4'd8) begin
                            tst_st <= T_READ;
                            beat   <= 4'd0;
                        end else begin
                            beat <= beat + 4'd1;
                        end
                    end else if (wait_cnt == 16'hFFFF) begin
                        tst_err <= 8'd2;              // 写阶段一直撞刷新
                        tst_st  <= T_DONE;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                T_READ: begin
                    if (!sdr_ref_vld) begin
                        wait_cnt <= 16'd0;
                        if (beat == 4'd8) begin
                            // 8 拍已发完，等最后一批数据回来
                            if (rd_cnt == 4'd8)
                                tst_st <= T_DONE;
                        end else begin
                            beat <= beat + 4'd1;
                        end
                    end else if (wait_cnt == 16'hFFFF) begin
                        tst_err <= 8'd3;              // 读阶段一直撞刷新
                        tst_st  <= T_DONE;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end

                    // 读数据回收与比对
                    // 【为什么用 rd_en_q / rd_mismatch 而不是直接比 sdr_rd_dout】
                    //   原写法把 32 位比较器直接串在 sdr_rd_dout → 状态机 → led 的
                    //   组合路径上。TD 实测该路径 8.56ns（其中净延迟 5.99ns）、
                    //   4 级 LUT，150MHz（6.666ns）下 SWNS = -2.102ns、Fmax 仅
                    //   114MHz。把比较结果打一拍后，32 位比较退化为
                    //   "寄存器 → 1 级 LUT → 寄存器"的短路径。
                    //   rd_mismatch 与 sdr_rd_dout 在同一拍求值，天然对齐。
                    if (rd_en_q) begin
                        if (rd_mismatch) begin
                            tst_err <= 8'd4;          // 数据不符
                            tst_st  <= T_DONE;
                        end else if (rd_cnt == 4'd7) begin
                            rd_cnt <= 4'd8;
                            tst_st <= T_DONE;         // 8 字全部正确
                        end else begin
                            rd_cnt <= rd_cnt + 4'd1;
                        end
                    end
                end

                T_DONE: begin
                    tst_st <= T_DONE;   // 停在终态，结果由 LED 保持显示
                end

                default: tst_st <= T_IDLE;
            endcase
        end
    end

    // 读数据比对：比较结果单独打一拍（见 T_READ 里的说明）。
    //   rd_expect 只由 rd_cnt 派生，是寄存器输出，不引入新的长路径。
    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n) begin
            rd_en_q     <= 1'b0;
            rd_mismatch <= 1'b0;
        end else begin
            rd_en_q     <= sdr_rd_en;
            rd_mismatch <= sdr_rd_en && (sdr_rd_dout != rd_expect);
        end
    end

    // -------------------------------------------------------------------------
    // [6] 结果指示（寄存器输出）
    //     led[0] = 1: 读写全通（唯一"成功"判据）
    //     led[1] = 1: PLL 已锁定（现场判断时钟，无需示波器）
    //     led[7:2]   : 错误码低 6 位（0 = 未出错）
    //
    //     【为什么 led 必须经寄存器输出】
    //       TD 实测：若把 tst_st / tst_err 直接组合驱动 led，
    //       从 u_sdram_sip.ipclk 到 led PAD 的路径达 8.56ns、4 级 LUT，
    //       150MHz 下 17 个端点建立时间违例（SWNS -2.102ns，Fmax 114MHz）。
    //       加一级寄存器后路径被切断，LED 的 1 拍延迟对肉眼毫无影响。
    // -------------------------------------------------------------------------
    wire tst_pass = (tst_st == T_DONE) && (tst_err == 8'd0);
    wire [7:0] led_next = {tst_err[5:0], pll_locked, tst_pass};

    reg [7:0] led_reg;

    always @(posedge clk_sdr or negedge rst_n) begin
        if (!rst_n) led_reg <= 8'd0;
        else        led_reg <= led_next;
    end

    assign led = led_reg;

    // -------------------------------------------------------------------------
    // [7] 片内 SDRAM SIP 原语
    //     EG4S20 的 SDRAM 是**封装内（SiP）**资源，不是板上外挂芯片：
    //     它的引脚不出芯片，因此 .adc 里**不需要**任何 SDRAM 管脚约束。
    //     这与官方参考设计 top.v 的做法完全一致（.cs_n(1'b0) / .cke(1'b1)）：
    //     此处 cs_n 由 sdram_ctrl_wrap 给出常量 0，cke 给出常量 1。
    // -------------------------------------------------------------------------
    EG_PHY_SDRAM_2M_32 u_sdram_sip (
        .clk   (sdram_clk_w),
        .ras_n (sdram_ras_n_w),
        .cas_n (sdram_cas_n_w),
        .we_n  (sdram_we_n_w),
        .addr  (sdram_addr_w),
        .ba    (sdram_ba_w),
        .dq    (sdram_dq_w),
        .cs_n  (sdram_cs_n_w),
        .dm0   (sdram_dm_w[0]),
        .dm1   (sdram_dm_w[1]),
        .dm2   (sdram_dm_w[2]),
        .dm3   (sdram_dm_w[3]),
        .cke   (sdram_cke_w)
    );

endmodule
