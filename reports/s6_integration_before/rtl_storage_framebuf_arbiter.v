// =============================================================================
// framebuf_arbiter.v — ERAM SDRAM 帧缓冲读写互斥调度器
// =============================================================================
// 【一、在整体系统中的功能】
//   所属层次 : 存储层 —— SDRAM 控制器的"交通警察"
//   工程归属 : project/hdmi_td.al（被 dmz_eg4s20_hdmi_top.v 例化）
//   数据流位置:
//       bmp_parser 像素流 → wr_fifo(25M→150M) → 【本模块】 → sdr_as_ram(150MHz)
//       sdr_as_ram(150MHz) → 【本模块】 → rd_fifo(150M→25M) → HDMI 像素侧
//
//   本模块整体工作在 **150MHz（Sdr_clk）单一时钟域**。跨时钟域由两侧
//   async_fifo 负责，本模块内部不做任何跨域处理。
//
// 【二、为什么必须有本模块】
//   ERAM 控制器有一条**硬限制**（见 docs/eram_sdram_reference.md §4）：
//   **读写不可同时**。同一条 32bit 数据总线，读周期与写周期必须完全分开。
//   而显示读流是"连续不断"的（每一拍都要出像素），写帧是"成块突发"的。
//   若让两者自由竞争，会出现三种故障：
//     ① 读被打断 → 显示侧 FIFO 下溢 → 画面出现横向撕裂/黑条
//     ② 写被打断 → 写了一半的帧被显示出来 → 上旧下新的"半帧混屏"
//     ③ 两者同时发请求 → 控制器行为未定义（官方明确不支持）
//   本模块把"谁在什么时候占用总线"集中到一个状态机里，保证任一时刻
//   只有一方向控制器发命令。
//
// 【三、地址与突发（关键的位宽语义，务必看清）】
//   `app_*_addr[20:0]` 是**字地址**（单位 = 32bit 字），不是单元地址。
//   控制器在同一个地址上按 4 拍突发顺序覆盖 `addr+0 .. addr+3` 四个字，
//   因此：
//     - `app_*_addr[1:0]` 必须恒为 `2'b00`
//     - **地址每 4 拍才能跳一次，且步长为 4**（不是 1）
//   一帧 = 640×480 = 307200 像素 = 153600 个 32bit 字（2 像素/字）
//        = **38400 个 4 拍突发组**，占用字地址 0 .. 153596（步长 4）
//   21 位字地址可寻址 2M 字 = 8MB，够放 **13 帧**（与手册一致）。
//
//   **组必须原子完成**：一旦开始一个 4 拍组，必须走完才允许切换方向；
//   否则控制器内部的突发计数器被打断，后续拍会落到错误的列地址上。
//   中途若 `ref_vld` 拉起，则原地暂停（保持组内进度），刷新结束后续上。
//
// 【四、调度策略（锁定的设计决策）】
//   **读优先 + 写插空 + 写饥饿保护**：
//     - 读流（显示侧）为**最高优先级**。
//       理由：显示断流是"可见故障"（撕裂），必须在任何情况下避免；
//       而写侧多等几十拍没人看得出来。
//     - 写流只在**读流空闲**时服务，且必须避让刷新窗口
//       `ref_vld`（Sdr_init_ref_vld）= 1 时控制器正在自刷新，
//       此时发任何命令都会被忽略甚至破坏刷新。
//     - **写饥饿保护**：若写侧等待超过 `WR_STARVE_LIMIT` 拍，则即便读侧
//       持续有请求也让写侧拿到一次完整突发组。没有这条，当读流持续满载
//       （例如高分辨率高刷新率）时写侧可能永远得不到服务，画面永远停在旧帧。
//
// 【五、接口契约（上游必须遵守）】
//   `wr_req` / `rd_req` 一旦被接受，**必须保持有效直到该 4 拍组结束**。
//   上游 async_fifo 天然满足（应用层按 512 字节扇区整块写入；显示读流在
//   有效区内连续）。若 `wr_req` 中途掉线，本模块会以 `wr_dm = 4'h0`
//   补完剩余拍（不写任何字节、不拉 `wr_ack`），保证控制器突发完整。
//   读侧无此退路（读不能"屏蔽"），因此读侧请求必须保持到组结束。
//
// 【六、接口说明】
//   写侧（来自 wr_fifo 的 150MHz 侧）:
//     wr_req   : 请求写（FIFO 非空）
//     wr_data  : 32bit 数据（含两个 RGB565 像素）
//     wr_dm    : 4bit 字节掩码（像素数为奇数时屏蔽高 16bit）
//     wr_ack   : 本模块接受本次写入，**与 app_wr_en 同拍**（FIFO 同拍出队）
//
//   读侧（送往 rd_fifo 的 150MHz 侧）:
//     rd_req   : 需要一个字
//     rd_data  : 读出的数据
//     rd_valid : 读数据有效（1 拍脉冲，**比控制器的 sdr_rd_en 晚一拍**，
//                与 rd_data 对齐；上层 FIFO 的写使能直接接它）
//
//   控制器原始端口（直接接 sdr_as_ram）:
//     app_wr_en/app_wr_addr/app_wr_din/app_wr_dm
//     app_rd_en/app_rd_addr
//     sdr_rd_en/sdr_rd_dout
//     ref_vld/sdr_init_done
//
//   状态回读:
//     busy : 控制器尚未初始化完成时为 1
//     err  : 调度异常锁存（正常工作时恒 0）
//
// 【七、设计陷阱与规避】
//   1) **`ref_vld` 是唯一流控**。`Sdr_busy` 官方标注"暂不使用"，不要拿它判。
//   2) **读命令发出后不能中途撤销**。`app_rd_en` 一旦拉高，数据必然返回；
//      用 `rd_outstanding` 保证切换方向前所有读命令都已回收，否则迟到的
//      读数据会串到下一次读上，导致整幅图错位。
//   3) **写通道无反压**：`app_wr_en` 拉高即写，因此本模块必须自己保证
//      在 `ref_vld` 期间绝不给 `app_wr_en`。
//   4) **不要在这里做跨时钟域**。`wr_req`/`wr_data`/`rd_req` 必须来自
//      async_fifo 的 150MHz 侧，不能直接接 25MHz 域信号。
// =============================================================================
`timescale 1ns / 1ps

module framebuf_arbiter #(
    parameter ADDR_WIDTH      = 21,        // 控制器字地址位宽
    parameter BUS_TURN_GAP    = 2,         // 读写方向切换间隔（拍）
    parameter WR_STARVE_LIMIT = 256,       // 写饥饿保护阈值（拍）
    parameter RD_TIMEOUT      = 1024,      // 读 outstanding 超时兜底（拍）
    parameter FRAME_BASE      = 21'd0,     // 帧缓冲基地址（字地址，须 4 字节对齐）
    parameter FRAME_WORDS     = 18'd153600 // 一帧的 32bit 字数 = 640*480/2
) (
    input  wire                  clk,           // 150MHz（Sdr_clk）
    input  wire                  rst_n,         // 低有效

    // ---------------- 控制器状态 ----------------
    input  wire                  sdr_init_done, // 控制器初始化完成
    input  wire                  ref_vld,       // Sdr_init_ref_vld：刷新中

    // ---------------- 写侧（来自 wr_fifo 的 150MHz 侧）----------------
    input  wire                  wr_req,        // 请求写一个字
    input  wire [31:0]           wr_data,       // 数据（两个 RGB565 像素）
    input  wire [3:0]            wr_dm,         // 字节掩码（奇数像素时屏蔽高 16bit）
    output wire                  wr_ack,        // 本模块已接受（组合输出，见下）

    // ---------------- 读侧（送往 rd_fifo 的 150MHz 侧）---------------
    input  wire                  rd_req,        // 需要一个字
    output reg  [31:0]           rd_data,       // 读出的数据
    output reg                   rd_valid,      // 读数据有效（1 拍脉冲）
    output wire                  rd_ack,        // 新突发组已启动（1 拍脉冲，供上游计数）

    // 读指针归位（帧同步）
    //
    //   本模块的读侧是自由流顺序读，内部 rd_addr 自己按组 +4 前进、
    //   到 FRAME_LAST 自动回卷。上游无法指定读哪一行，但**必须**能把指针拉回帧首：
    //   上电后本模块会立即开始读，而此时 SDRAM 内容尚未装入；
    //   若不能回位，读指针会永久停在乱码区，画面永远错位。
    //   上游在每帧开始前给 1 拍脉冲即可。
    input  wire                  rd_restart,    // 读指针重启（1 拍脉冲）
    input  wire [ADDR_WIDTH-1:0] rd_base,       // 重启后的读起始字地址

    // ---------------- 控制器原始端口 ----------------
    output reg                   app_wr_en,
    output reg  [ADDR_WIDTH-1:0] app_wr_addr,
    output reg  [31:0]           app_wr_din,
    output reg  [3:0]            app_wr_dm,
    output reg                   app_rd_en,
    output reg  [ADDR_WIDTH-1:0] app_rd_addr,
    input  wire                  sdr_rd_en,
    input  wire [31:0]           sdr_rd_dout,

    // ---------------- 状态 ----------------
    output wire                  busy,          // 尚未就绪
    output reg                   err            // 调度异常锁存
);

    // -------------------------------------------------------------------------
    // 状态编码
    // -------------------------------------------------------------------------
    localparam [1:0] A_IDLE = 2'd0,
                     A_WR   = 2'd1,
                     A_RD   = 2'd2,
                     A_GAP  = 2'd3;

    reg [1:0]            st;

    // 地址与组内拍计数
    reg [ADDR_WIDTH-1:0] wr_addr;      // 当前写突发组起始字地址（4 的倍数）
    reg [ADDR_WIDTH-1:0] rd_addr;      // 当前读突发组起始字地址
    reg [1:0]            wr_beat;      // 组内第几拍 0..3
    reg [1:0]            rd_beat;
    reg                  rd_rst_pend;   // 读指针重启待执行（rd_restart 被组占用时锁存）
    reg                  wr_grp_active;// 写组进行中
    reg                  rd_grp_active;// 读组进行中

    // 读 outstanding 计数（还有几条读命令没回来）
    reg [3:0]            rd_outstanding;

    // 读超时兜底计数：outstanding 在飞期间累加，归零时清零。
    // 若控制器因故不返回数据（接口错接、控制器卡死、上游误用），
    // 没有这条本模块会**永久卡在 A_RD**，整块屏黑掉且无法自恢复。
    // 超时后强制把 outstanding 归零并置 err，让调度继续走。
    reg [15:0]           rd_wait_cnt;

    // 间隔与饥饿
    reg [7:0]            gap_cnt;
    reg [15:0]           wr_starve;

    // 一帧的最后一个突发组起始地址
    localparam [ADDR_WIDTH-1:0] FRAME_LAST = FRAME_BASE + FRAME_WORDS - 18'd4;

    // 总线可用（刷新期间与未初始化时都不许发命令）
    wire bus_ok = sdr_init_done && !ref_vld;

    // 4 拍组的最后一拍（下一拍即组结束）
    wire wr_last_beat = (wr_beat == 2'd3);
    wire rd_last_beat = (rd_beat == 2'd3);

    // 本拍是否真的发出写命令：
    //   组已开始 → 必须补完；未开始 → 仅在有请求时开始
    //   （中途 wr_req 掉线也要补完，用 dm=0 避免写入垃圾）
    wire wr_fire = (st == A_WR) && bus_ok && (wr_grp_active || wr_req);
    wire wr_real = wr_fire && wr_req;     // 真的消费了 FIFO 数据

    // 本拍是否真的发出读命令：读组一旦开始必须补完
    wire rd_fire = (st == A_RD) && bus_ok && (rd_grp_active || rd_req) &&
                   (rd_outstanding != 4'd15);

    // 新突发组启动：rd_fire 成立且当前并非组进行中。
    // 上游据此精确计数已发起的 4 拍组数，从而刚好读满一行而不多读。
    assign rd_ack = rd_fire && !rd_grp_active;

    // 饥饿标志
    wire wr_starved = (wr_starve >= WR_STARVE_LIMIT);

    // -------------------------------------------------------------------------
    // wr_ack 是**组合输出**，与"数据被采样"同一拍
    //   这一点很关键：`app_wr_din` 是在 wr_fire 那一拍采样的，若 `wr_ack`
    //   作为寄存器晚一拍才有效，上游 FIFO 就要到下一拍才出队，于是第二拍
    //   采样到的仍是旧队头 → **同一个字被发两次**（实测：写 4 个字时
    //   mem[1] 收到的是 mem[0] 的数据）。
    //   改成组合后：采样与出队同拍，`app_wr_en`（寄存器）晚一拍输出，
    //   它输出的正是当时采到的那个队头字，二者天然对齐。
    // -------------------------------------------------------------------------
    assign wr_ack = wr_real;

    // 允许离开 A_WR：组已结束，且（写侧没需求了 / 读侧要总线且写未饿极）
    wire wr_may_exit = !wr_grp_active && (!wr_req || (rd_req && !wr_starved));

    // 读侧可能因控制器丢数据而永久卡在 A_RD —— 超时后强制推进
    wire rd_timeout = (rd_outstanding != 4'd0) && (rd_wait_cnt >= RD_TIMEOUT[15:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_wait_cnt <= 16'd0;
        end else if (rd_outstanding == 4'd0) begin
            rd_wait_cnt <= 16'd0;
        end else if (rd_wait_cnt != 16'hFFFF) begin
            rd_wait_cnt <= rd_wait_cnt + 16'd1;
        end
    end

    // 允许离开 A_RD：组已结束、所有读数据已回收（或已超时），且（读侧没需求了 / 写饿极）
    wire rd_may_exit = !rd_grp_active &&
                       ((rd_outstanding == 4'd0) || rd_timeout) &&
                       (!rd_req || wr_starved);

    // -------------------------------------------------------------------------
    // busy：控制器没初始化完就是忙
    // -------------------------------------------------------------------------
    assign busy = !sdr_init_done;

    // -------------------------------------------------------------------------
    // 写饥饿计数
    //   语义要点：「未被服务」指写出请求存在、总线可用、但本拍确实没有
    //   发出写命令。不能简单看 wr_req —— 写组进行中时 wr_req 可能一直为高
    //   （FIFO 一直非空），但那一刻总线正被读占用，计数的目的正是要捕捉
    //   这种"有需求但拿不到总线"的等待。
    // -------------------------------------------------------------------------
    wire wr_served = (wr_fire && wr_real) || wr_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_starve <= 16'd0;
        end else if (wr_served) begin
            wr_starve <= 16'd0;
        end else if (wr_req && bus_ok && wr_starve != 16'hFFFF) begin
            wr_starve <= wr_starve + 16'd1;
        end
    end

    // -------------------------------------------------------------------------
    // [1] 主状态机：只在组边界上做方向决策
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= A_IDLE;
        end else begin
            case (st)
                // ---------------------------------------------------------
                A_IDLE: begin
                    if (!bus_ok) begin
                        st <= A_IDLE;
                    end else if (wr_starved) begin
                        // 写已饿极：必须给写侧开路，否则读流满载会永久饿死写
                        st <= A_WR;
                    end else if (rd_req) begin
                        st <= A_RD;                 // 读优先
                    end else if (wr_req) begin
                        st <= A_WR;
                    end else begin
                        st <= A_IDLE;
                    end
                end

                // ---------------------------------------------------------
                // A_WR：刷新期间原地暂停，保持组内进度
                // ---------------------------------------------------------
                A_WR: begin
                    if (!bus_ok)      st <= A_WR;
                    else if (wr_may_exit) st <= A_GAP;
                    else              st <= A_WR;
                end

                // ---------------------------------------------------------
                // A_RD：同样原地暂停；组结束且数据回收完才走
                // ---------------------------------------------------------
                A_RD: begin
                    if (!bus_ok)          st <= A_RD;
                    else if (rd_may_exit) st <= A_GAP;
                    else                  st <= A_RD;
                end

                // ---------------------------------------------------------
                // A_GAP: 方向切换间隔，倒计时归零回 IDLE
                // ---------------------------------------------------------
                A_GAP: begin
                    if (gap_cnt == 8'd0) st <= A_IDLE;
                    else                 st <= A_GAP;
                end

                default: st <= A_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // [2] 写命令发出
    //     组内地址恒定；4 拍走完才把地址推进 4（跳过本组覆盖的 4 个字）。
    //     若中途 wr_req 掉线，剩余拍以 dm=0 补完（不写字节、不拉 wr_ack）。
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            app_wr_en     <= 1'b0;
            app_wr_addr   <= FRAME_BASE;
            app_wr_din    <= 32'd0;
            app_wr_dm     <= 4'hF;
            wr_addr       <= FRAME_BASE;
            wr_beat       <= 2'd0;
            wr_grp_active <= 1'b0;
        end else begin
            app_wr_en <= 1'b0;

            if (wr_fire) begin
                app_wr_en     <= 1'b1;
                app_wr_addr   <= wr_addr;
                app_wr_din    <= wr_real ? wr_data : 32'd0;
                app_wr_dm     <= wr_real ? wr_dm   : 4'h0;   // 补拍不写字节
                wr_grp_active <= !wr_last_beat;

                if (wr_last_beat) begin
                    wr_beat <= 2'd0;
                    // 一次跳 4 个字地址（addr[1:0] 恒 00）
                    wr_addr <= (wr_addr >= FRAME_LAST)
                               ? FRAME_BASE
                               : (wr_addr + {{(ADDR_WIDTH-3){1'b0}}, 3'd4});
                end else begin
                    wr_beat <= wr_beat + 2'd1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // [3] 读命令发出
    //     与写对称：组内地址恒定，4 拍后跳 4。
    //     允许流水化：outstanding 未满就可连续发，不必等数据回来。
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            app_rd_en     <= 1'b0;
            app_rd_addr   <= FRAME_BASE;
            rd_addr       <= FRAME_BASE;
            rd_beat       <= 2'd0;
            rd_grp_active <= 1'b0;
            rd_rst_pend   <= 1'b0;
        end else begin
            app_rd_en <= 1'b0;

            // 帧同步：只在组空闲时回位指针，避免把正在飞的组打断。
            // 组一旦启动就自维持到第 4 拍，中途改地址会让剩下几拍落到错误列地址。
            // 弧度：先把 rd_restart 锁存成 pending，
            //      等组真正空闲的那拍才执行重启。
            //      若写成直接 if (rd_restart && !rd_grp_active)，
            //      rd_restart 持续 2 拍中只要碰上一拍有组在飞，
            //      这次重启就被静默丢弃，读指针从此错位。
            if (rd_restart) rd_rst_pend <= 1'b1;

            if (rd_rst_pend && !rd_grp_active) begin
                rd_addr     <= rd_base;
                rd_beat     <= 2'd0;
                rd_rst_pend <= 1'b0;
            end else if (rd_fire) begin
                app_rd_en     <= 1'b1;
                app_rd_addr   <= rd_addr;
                rd_grp_active <= !rd_last_beat;

                if (rd_last_beat) begin
                    rd_beat <= 2'd0;
                    rd_addr <= (rd_addr >= FRAME_LAST)
                               ? FRAME_BASE
                               : (rd_addr + {{(ADDR_WIDTH-3){1'b0}}, 3'd4});
                end else begin
                    rd_beat <= rd_beat + 2'd1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // [4] 读数据捕获 + outstanding 计数
    //     rd_data/rd_valid 在 sdr_rd_en 后一拍对齐输出（寄存器输出）。
    //     outstanding：app_rd_en 加 1，sdr_rd_en 减 1。
    //     归零是切换方向的必要条件——否则迟到的读数据会串到下一次读上。
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data        <= 32'd0;
            rd_valid       <= 1'b0;
            rd_outstanding <= 4'd0;
        end else begin
            rd_valid <= 1'b0;
            if (sdr_rd_en) begin
                rd_data  <= sdr_rd_dout;
                rd_valid <= 1'b1;
            end

            if (rd_timeout) begin
                // 控制器未按时返回数据：放弃等待，强制清零让调度继续
                rd_outstanding <= 4'd0;
            end else begin
                case ({app_rd_en, sdr_rd_en})
                    2'b10: begin
                        // 饱和递增：绝不能回绕。
                        // rd_fire 的 `rd_outstanding != 4'd15` 是组合判据，
                        // 而 app_rd_en 要到下一拍才生效——若本拍已是 15，
                        // 15+1 会回绕成 0，于是 rd_wait_cnt 被清零、超时永远
                        // 不会触发，表现为"周期性地以为读全回来了"。
                        if (rd_outstanding != 4'd15)
                            rd_outstanding <= rd_outstanding + 4'd1;
                    end
                    2'b01:   rd_outstanding <= rd_outstanding - 4'd1;
                    default: rd_outstanding <= rd_outstanding;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // [5] 方向切换间隔计数
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gap_cnt <= 8'd0;
        end else if (st == A_GAP) begin
            if (gap_cnt != 8'd0) gap_cnt <= gap_cnt - 8'd1;
        end else begin
            gap_cnt <= BUS_TURN_GAP[7:0];
        end
    end

    // -------------------------------------------------------------------------
    // [6] 异常锁存
    //     真正会出问题的情形只有一个：在刷新窗口内发了命令。正常工作时
    //     `bus_ok` 已经挡住新命令，若仍发生说明有其它路径在驱动控制器端口。
    //     判据用 `ref_vld_d && ref_vld`（刷新已稳定至少一拍）：`ref_vld` 拉起
    //     的那一拍可能仍有上一拍决定好的 `app_*_en` 在途，那是正常的——
    //     命令早于刷新的仲裁决策，不属于违规。
    //     （不要在未初始化时就置 err——上电瞬间 FIFO 里可能已有数据，
    //       那是正常现象，`busy` 已经表达了"还没准备好"。）
    // -------------------------------------------------------------------------
    reg ref_vld_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_vld_d <= 1'b0;
            err       <= 1'b0;
        end else begin
            ref_vld_d <= ref_vld;
            if (ref_vld_d && ref_vld && (app_wr_en || app_rd_en)) begin
                err <= 1'b1;
            end
            if (rd_timeout) begin
                err <= 1'b1;      // 读超时也记为异常，便于上层统计
            end
        end
    end

endmodule
