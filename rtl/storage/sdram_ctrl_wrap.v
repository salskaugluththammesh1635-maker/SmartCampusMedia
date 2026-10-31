// =============================================================================
// sdram_ctrl_wrap.v — ERAM SDRAM 控制器封装（加密核 ⇄ 行为模型的二选一外壳）
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 存储层 —— SDRAM 帧缓冲子系统的"底层通道"
//   工程归属 : project/hdmi_td.al（被 dmz_eg4s20_hdmi_top.v 例化）
//   数据流位置:
//       framebuf_arbiter → 【本模块】 → sdr_as_ram（安路 APUG011 加密核）
//                                          → EG_PHY_SDRAM_2M_32（片内 SIP）
//
// 【二、为什么需要这一层封装】
//   安路 APUG011 加密核（`sdr_as_ram`）有三个接入障碍：
//     ① **参数是宏不是 parameter**：`global_def.v` 里 `DATA_WIDTH`/`ADDR_WIDTH`/
//        `ROW_WIDTH` 等都是 `define`，改一个必须同步改频率相关的两个宏
//        （`SDR_CLK_PERIOD`、`SELF_REFRESH_INTERVAL`），直接散落在工程各处
//        极易漏改。
//     ② **不定义 `SIMULATION` 宏就无法仿真**：官方 top.v 里 SDRAM 引脚是
//        `inout` 直接连到 FPFA 管脚，仿真时没有模型驱动会一直 X 态。
//     ③ **位宽与命名风格与本工程不一致**：加密核用 `App_wr_en` 这类下划线
//        混合大小写，本工程统一小写 + `_n` 后缀的低有效约定。
//   本模块把这三件事集中处理：工程配置头统一宏、仿真/综合在这里分流、
//   命名在这里转换。上层（framebuf_arbiter 及以上）只看到干净的小写接口。
//
// 【三、仿真与综合的分流机制（关键）】
//   用编译宏 `SDRAM_SIM_MODEL` 控制实例化哪一侧：
//     - **综合**（不定义该宏，默认）：例化真正的加密核 `sdr_as_ram`，
//       SDRAM 引脚引到顶层，由 `EG_PHY_SDRAM_2M_32` SIP 原语接管。
//     - **仿真**（`+define+SDRAM_SIM_MODEL`）：例化本文件底部的 `sdram_behavior_model`，
//       它用一块 `reg [31:0] mem [0:...]` 模拟存储阵列，读延迟固定 10 拍、
//       写立即生效、按 `REFRESH_PERIOD` 周期拉 `ref_vld`。
//       仿真时**不需要**加密核、不需要 RSA key、不需要 `eg_phy_sdram_2m_32.v`。
//
//   为什么不在同一个文件里用 `ifdef SIMULATION`：
//     加密核的 `.v` 文件本身**包含 `pragma protect` 段**，ModelSim 没拿到
//     key 会直接报错退出（整个库都编不过）。用 `ifdef` 也救不了——因为
//     `vlog` 在**编译期**就要处理那个文件。所以必须做到"仿真时根本不编译
//     加密核"，这只能靠**文件级二选一**（仿真库不含 `.enc.v`）+ 这里用
//     参数分流实例化。
//     实际做法：综合走 `.al` 工程（含 `.enc.v`），仿真走 `sim/scripts/run_sim.bat`
//     （不含 `.enc.v`，编译时加 `+define+SDRAM_SIM_MODEL`）。两边共用同一份源码。
//
// 【四、控制器接口契约（沿用 APUG011，务必遵守）】
//   1) **读延迟固定 10 拍**：`app_rd_en` 拉高后第 10 个 `clk` 升起 `sdr_rd_en`
//      与有效 `sdr_rd_dout`。器件差异可能导致±1 拍，上板需实测对齐。
//   2) **写通道无反压**：`app_wr_en` 拉高即写，本模块不提供 ready。
//      调用方（framebuf_arbiter）必须自己保证不在刷新窗口内发写命令。
//   3) **读写不可同时**：同一条数据总线，读周期与写周期必须完全分开。
//   4) 四字组的首址必须对齐，组内地址由首址累加。上层仲裁器选择四拍恒基址；
//      官方可读驱动也使用基址+拍号，不能把“每拍低两位都为零”写成硬核要求。
//   5) **`ref_vld` 是唯一流控**：包含组边界排空和手动刷新窗口；高时不接受命令。
//   6) **`app_wr_dm` 语义**：`dm[n]=1` 表示**屏蔽** `din[8n+7:8n]` 字节。
//      全写时置 `4'b0000`（注意：官方例程 `app_wrrd.v` 里用的是 `4'b0000`，
//      与 `docs/eram_sdram_reference.md` §3 表格里写的"屏蔽时置 4'b1111"
//      表述方向相反，**以本处为准**：1=屏蔽，0=写）。
//      加密核把 DM 也送到物理 DQM，读出同样受它屏蔽；没有写命令时必须置 0。
//
// 【五、时钟】
//   本模块工作在 `sdram_clk`（40MHz，`sdram_pll` 的 C1 输出）单一时钟域。
//   `sdram_clk_sft`（同频 180°）**只透传给加密核的 `Sdr_clk_sft`**，
//   本模块内部**绝不用它驱动任何逻辑**（否则等于自造一个时钟域）。
//
// 【六、设计陷阱与规避】
//   1) **频率改动的连带修改**：`CLK_FREQ_HZ` 改了，`ip/config/sdram/global_def.v` 里的
//      `SDR_CLK_PERIOD` 与 `SELF_REFRESH_INTERVAL` 必须同步改，否则刷新
//      周期算错，SDRAM 会静默丢数据（不是报错，是数据悄悄变错）。
//   2) **不要在仿真模式下依赖引脚**：定义 `SDRAM_SIM_MODEL` 后物理引脚端口全部悬空，
//      顶层不应把它们接到实际管脚约束上。
//   3) **复位必须够长**：`sdr_as_ram` 上电初始化要跑几千拍（PRECHARGE 全
//      bank + 8 次 REFRESH + 模式寄存器写），期间 `sdr_init_done=0`。
//      本模块的 `busy` 直接反映这个状态，上层必须等 `busy` 落下才发命令。
//   4) **`Rst` 是高有效**（与工程其余部分低有效相反），这里已转换。
// =============================================================================
`timescale 1ns / 1ps

module sdram_ctrl_wrap #(
    parameter CLK_FREQ_HZ      = 40_000_000,   // sdram_clk 频率
    parameter SIM_MEM_WORDS    = 262_144,      // 仿真模型容量（字数），默认 1MB = 1/8 帧缓冲
    parameter REFRESH_PERIOD   = 4_096         // 仿真模型多久拉一次 ref_vld（拍）
) (
    input  wire        clk,          // 40MHz（sdram_pll C1）
    input  wire        clk_sft,      // 40MHz 180°（sdram_pll C2），只透传
    input  wire        rst_n,        // 低有效

    // ---------------- 控制器状态 ----------------
    output wire        init_done,    // 初始化完成，可以开始读写
    output wire        ref_vld,      // 刷新进行中（高 = 必须避让）
    output wire        busy,         // = !init_done | ref_vld
    output wire        refresh_error, // 刷新握手超时/意外读返回，粘滞至复位

    // ---------------- 用户侧（接 framebuf_arbiter）----------------
    input  wire        app_wr_en,
    input  wire [20:0] app_wr_addr,
    input  wire [31:0] app_wr_din,
    input  wire [3:0]  app_wr_dm,
    input  wire        app_rd_en,
    input  wire [20:0] app_rd_addr,
    output wire        sdr_rd_en,
    output wire [31:0] sdr_rd_dout,

    // ---------------- 物理 SDRAM 引脚（仅综合模式有效）----------------
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [1:0]  sdram_ba,
    output wire [10:0] sdram_addr,
    output wire [3:0]  sdram_dm,
    inout  wire [31:0] sdram_dq
);

    // -------------------------------------------------------------------------
    // 复位极性转换：工程约定 rst_n 低有效，加密核 Rst 高有效
    // -------------------------------------------------------------------------
    wire sdr_rst = ~rst_n;

    // -------------------------------------------------------------------------
    // busy 的正向语义：加密核给的是 init_done，这里补一个 busy 方便上层
    // -------------------------------------------------------------------------
    assign busy = ~init_done | ref_vld;

    // SDR_CKE 始终有效：周期 AUTO REFRESH 不需要将 CKE 拉低。
    assign sdram_cke = 1'b1;
    assign sdram_cs_n = 1'b0;

`ifdef SDRAM_SIM_MODEL
    assign refresh_error = 1'b0;
    // =========================================================================
    // 仿真路径：行为模型，不需要加密核
    // =========================================================================
    sdram_behavior_model #(
        .SIM_MEM_WORDS  (SIM_MEM_WORDS),
        .REFRESH_PERIOD (REFRESH_PERIOD)
    ) u_model (
        .clk          (clk),
        .rst_n        (rst_n),
        .init_done    (init_done),
        .ref_vld      (ref_vld),
        .app_wr_en    (app_wr_en),
        .app_wr_addr  (app_wr_addr),
        .app_wr_din   (app_wr_din),
        .app_wr_dm    (app_wr_dm),
        .app_rd_en    (app_rd_en),
        .app_rd_addr  (app_rd_addr),
        .sdr_rd_en    (sdr_rd_en),
        .sdr_rd_dout  (sdr_rd_dout)
    );

    // 仿真时物理引脚悬空（顶层不要约束它们）
    assign sdram_clk   = clk_sft;
    assign sdram_ras_n = 1'b1;
    assign sdram_cas_n = 1'b1;
    assign sdram_we_n  = 1'b1;
    assign sdram_ba    = 2'b00;
    assign sdram_addr  = 11'd0;
    assign sdram_dm    = 4'h0;
    assign sdram_dq    = 32'bz;

`else
    // =========================================================================
    // 综合路径：安路 APUG011 加密核
    // =========================================================================
    // 自动刷新请求与四字组尾交叠时，真实核会输出相邻 25 ns 的两条 AREF，
    // 违反 tRC。改走官方手动请求端口：只在完整组结束、读返回排空并静默
    // 16 拍后提交单拍请求，再等核的刷新标志起落。ref_vld 在组边界提前
    // 阻止新组，既不截断已接受的组，也不丢弃命令。
    localparam [2:0] R_RUN=0, R_QUIET=1, R_ISSUE=2, R_WAIT_HI=3, R_WAIT_LO=4;
    // 32 ms / 2048 行，给 64 ms 保持要求留出事务排空与握手的余量。
    localparam REFRESH_INTERVAL = CLK_FREQ_HZ / 64_000;
    reg [2:0] refresh_state;
    reg [15:0] refresh_count;
    reg refresh_due;
    reg [1:0] refresh_wr_phase, refresh_rd_phase;
    reg [5:0] read_pending;
    reg [4:0] quiet_count;
    reg [10:0] refresh_watchdog;
    reg refresh_fault;
    wire core_ref;
    wire groups_complete = (refresh_wr_phase == 0) && (refresh_rd_phase == 0);
    wire stop_new = refresh_due && groups_complete;
    wire manual_request = (refresh_state == R_ISSUE) && !refresh_fault;
    assign ref_vld = core_ref || (refresh_state != R_RUN) || stop_new || refresh_fault;
    assign refresh_error = refresh_fault;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_state <= R_RUN;
            refresh_count <= 0;
            refresh_due <= 1'b0;
            refresh_wr_phase <= 0;
            refresh_rd_phase <= 0;
            read_pending <= 0;
            quiet_count <= 0;
            refresh_watchdog <= 0;
            refresh_fault <= 1'b0;
        end else begin
            if (app_wr_en && init_done && !ref_vld) refresh_wr_phase <= refresh_wr_phase + 1'b1;
            if (app_rd_en && init_done && !ref_vld) refresh_rd_phase <= refresh_rd_phase + 1'b1;
            case ({app_rd_en && init_done && !ref_vld, sdr_rd_en})
                2'b10: read_pending <= read_pending + 1'b1;
                2'b01: if (read_pending != 0) read_pending <= read_pending - 1'b1;
                default: ;
            endcase
            if (!init_done) begin
                refresh_count <= 0;
                refresh_due <= 1'b0;
                refresh_state <= R_RUN;
            end else begin
                if (refresh_count < REFRESH_INTERVAL-1) refresh_count <= refresh_count + 1'b1;
                else refresh_due <= 1'b1;
                case (refresh_state)
                    R_RUN: if (stop_new) begin refresh_state <= R_QUIET; quiet_count <= 0; end
                    R_QUIET: if (read_pending != 0 || app_rd_en || app_wr_en || !groups_complete)
                        quiet_count <= 0;
                    else if (quiet_count == 15) refresh_state <= R_ISSUE;
                    else quiet_count <= quiet_count + 1'b1;
                    R_ISSUE: refresh_state <= R_WAIT_HI;
                    R_WAIT_HI: if (core_ref) refresh_state <= R_WAIT_LO;
                    R_WAIT_LO: if (!core_ref) begin
                        refresh_state <= R_RUN; refresh_due <= 1'b0; refresh_count <= 0;
                    end
                    default: refresh_state <= R_RUN;
                endcase
            end
            if ((refresh_state == R_WAIT_HI) || (refresh_state == R_WAIT_LO)) begin
                if (refresh_watchdog < 1024) refresh_watchdog <= refresh_watchdog + 1'b1;
                else refresh_fault <= 1'b1;
            end else refresh_watchdog <= 0;
            if (init_done && sdr_rd_en && (read_pending == 0) && !app_rd_en)
                refresh_fault <= 1'b1;
        end
    end

    // Sdr_busy 本模块不使用，但必须显式接出。Verilog-2001 要求先声明后使用。
    wire sdr_busy_unused;

    sdr_as_ram #(
        .self_refresh_open (1'b0)
    ) u_sdr_as_ram (
        .Sdr_clk           (clk),
        .Sdr_clk_sft       (clk_sft),
        .Rst               (sdr_rst),

        .Sdr_init_done     (init_done),
        .Sdr_init_ref_vld  (core_ref),
        .Sdr_busy          (sdr_busy_unused),

        .App_ref_req       (manual_request),
        .App_wr_en         (app_wr_en),
        .App_wr_addr       (app_wr_addr),
        .App_wr_dm         (app_wr_dm),
        .App_wr_din        (app_wr_din),

        .App_rd_en         (app_rd_en),
        .App_rd_addr       (app_rd_addr),
        .Sdr_rd_en         (sdr_rd_en),
        .Sdr_rd_dout       (sdr_rd_dout),

        .SDRAM_CLK         (sdram_clk),
        .SDR_RAS           (sdram_ras_n),
        .SDR_CAS           (sdram_cas_n),
        .SDR_WE            (sdram_we_n),
        .SDR_BA            (sdram_ba),
        .SDR_ADDR          (sdram_addr),
        .SDR_DM            (sdram_dm),
        .SDR_DQ            (sdram_dq)
    );

`endif

endmodule


// =============================================================================
// sdram_behavior_model — SDRAM 控制器行为模型（仅仿真）
// =============================================================================
// 行为验证用模型，不是加密核的周期等价替代；真核与上板仍须单独验证：
//   - 上电后有 INIT_CYCLES 拍的初始化期，期间 init_done=0
//   - 读延迟**固定 10 拍**（与手册 §4 一致）
//   - 写立即生效（与真核"拉高即写"一致）
//   - 周期性拉 ref_vld 模拟自刷新，严格持续 REF_VLD_CYCLES 拍
//   - 组内暂停保留已接受拍的相位，仅是本模型假设，不是已核实的真核保证
//   - SIM_MEM_WORDS 必须为二的幂；数组低位索引按仿真容量镜像回绕
//   - **刷新期间忽略一切读写命令**（真核是"用户必须避让"，模型选择
//     "忽略"而不是"缓存"，这样上层如果漏了避让会**丢数据**而不是侥幸通过，
//     更容易在仿真里暴露问题）
// =============================================================================
module sdram_behavior_model #(
    parameter SIM_MEM_WORDS  = 262_144,
    parameter REFRESH_PERIOD = 4_096,
    parameter INIT_CYCLES    = 64,
    parameter REF_VLD_CYCLES = 8,
    parameter RD_LATENCY     = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    output reg         init_done,
    output reg         ref_vld,
    input  wire        app_wr_en,
    input  wire [20:0] app_wr_addr,
    input  wire [31:0] app_wr_din,
    input  wire [3:0]  app_wr_dm,
    input  wire        app_rd_en,
    input  wire [20:0] app_rd_addr,
    output wire        sdr_rd_en,
    output wire [31:0] sdr_rd_dout
);

    // 存储阵列：按字地址索引，超出 SIM_MEM_WORDS 的部分丢弃（回绕）
    reg [31:0] mem [0:SIM_MEM_WORDS-1];

    localparam MEM_AW = $clog2(SIM_MEM_WORDS);

    reg [15:0] init_cnt;
    reg [31:0] ref_cnt;
    reg        ref_active;

    // 读延迟移位链
    reg [31:0] rd_lat_data [0:RD_LATENCY-1];
    reg        rd_lat_vld  [0:RD_LATENCY-1];

    // 每四个实际接受的命令锁存一次首址；组内暂停不推进相位。
    // 读写独立计数，连续两组同址和帧首重启均不依赖地址变化。
    reg [1:0] wr_phase, rd_phase;
    reg [20:0] wr_group_base, rd_group_base;
    wire [20:0] wr_eff_addr = (wr_phase == 0) ? app_wr_addr :
                             wr_group_base + {19'd0, wr_phase};
    wire [20:0] rd_eff_addr = (rd_phase == 0) ? app_rd_addr :
                             rd_group_base + {19'd0, rd_phase};

    // 读输出直连移位链队首：保证 app_rd_en 之后**第 10 拍**即有效
    // （若再用一级寄存器会变成第 11 拍，与手册不符）
    assign sdr_rd_en   = rd_lat_vld[0];
    assign sdr_rd_dout = rd_lat_data[0];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_done   <= 1'b0;
            ref_vld     <= 1'b0;
            init_cnt    <= 16'd0;
            ref_cnt     <= 16'd0;
            ref_active  <= 1'b0;
            wr_phase <= 2'd0;
            rd_phase <= 2'd0;
            wr_group_base <= 21'd0;
            rd_group_base <= 21'd0;
            for (i = 0; i < RD_LATENCY; i = i + 1) begin
                rd_lat_data[i] <= 32'd0;
                rd_lat_vld[i]  <= 1'b0;
            end
        end else begin
            // ---------- 初始化计数 ----------
            if (init_cnt < INIT_CYCLES)
                init_cnt <= init_cnt + 16'd1;
            else
                init_done <= 1'b1;
            // ---------- 周期刷新 ----------
            if (!ref_active) begin
                if (ref_cnt >= REFRESH_PERIOD) begin
                    ref_cnt    <= 32'd0;
                    ref_active <= 1'b1;
                    ref_vld    <= 1'b1;
                end else begin
                    ref_cnt <= ref_cnt + 32'd1;
                end
            end else begin
                if (ref_cnt >= REF_VLD_CYCLES-1) begin
                    ref_active <= 1'b0;
                    ref_vld    <= 1'b0;
                    ref_cnt    <= 32'd0;
                end else begin
                    ref_cnt <= ref_cnt + 32'd1;
                end
            end

            // ---------- 写：立即生效，dm 逐字节屏蔽 ----------
            // dm[n]=1 表示屏蔽对应字节（与 APUG011 一致）
            if (app_wr_en && init_done && !ref_vld) begin
                if (wr_phase == 0) wr_group_base <= app_wr_addr;
                wr_phase <= wr_phase + 2'd1;
                if (!app_wr_dm[0]) mem[wr_eff_addr[MEM_AW-1:0]][7:0]   <= app_wr_din[7:0];
                if (!app_wr_dm[1]) mem[wr_eff_addr[MEM_AW-1:0]][15:8]  <= app_wr_din[15:8];
                if (!app_wr_dm[2]) mem[wr_eff_addr[MEM_AW-1:0]][23:16] <= app_wr_din[23:16];
                if (!app_wr_dm[3]) mem[wr_eff_addr[MEM_AW-1:0]][31:24] <= app_wr_din[31:24];
            end

            // ---------- 读：10 拍固定延迟 ----------
            // 移位链：每拍把队首推出，新命令插到队尾
            for (i = 0; i < RD_LATENCY-1; i = i + 1) begin
                rd_lat_data[i] <= rd_lat_data[i+1];
                rd_lat_vld[i]  <= rd_lat_vld[i+1];
            end
            rd_lat_data[RD_LATENCY-1] <= mem[rd_eff_addr[MEM_AW-1:0]];
            rd_lat_vld[RD_LATENCY-1] <= app_rd_en && init_done && !ref_vld;
            if (app_rd_en && init_done && !ref_vld) begin
                if (rd_phase == 0) rd_group_base <= app_rd_addr;
                rd_phase <= rd_phase + 2'd1;
            end

        end
    end

endmodule
