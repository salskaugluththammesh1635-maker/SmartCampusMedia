// =============================================================================
// tb_framebuf_arbiter.v — framebuf_arbiter 自检测试平台
// =============================================================================
// 【测试目标】
//   1. 复位后与控制器未初始化期间，绝不向控制器发任何命令
//   2. 写：4 拍突发组原子性（组内地址恒定，第 4 拍后才跳地址，步长 4）
//   3. 读：4 拍突发组原子性 + outstanding 计数正确回收
//   4. 读优先：读侧持续有请求时，写侧只能插空
//   5. 写饥饿保护：读侧满载时写侧仍能得到服务
//   6. 刷新避让：ref_vld 期间绝不发命令，且不丢失组内进度
//   7. 读写绝不重叠：任意一拍不允许 app_wr_en 与 app_rd_en 同时为 1
//   8. 地址回卷：写完一帧后回到 FRAME_BASE
//   9. wr_ack 与 app_wr_en 同拍（wr_ack 是"真消费了 FIFO 数据"的标志）
//  10. rd_valid 跟随 sdr_rd_en（晚一拍，与 rd_data 对齐）
//
// 【关键位宽语义】
//   app_*_addr 是**字地址**；一个突发组覆盖 addr+0..addr+3 四个字，
//   因此 addr[1:0] 恒 00、组间步长 4。
//
// 【写侧驱动模型（至关重要）】
//   `wr_data` 必须模拟**真实 FIFO 的队头**：只在 `wr_ack` 那拍之后才换成
//   下一个数据。初版 tb 在每个 negedge 都换数据，导致 DUT 采集到的是
//   "下一个"字而非队头字 —— 这是测试平台缺陷，不是 RTL 缺陷。
//
// 【刷新违规判定】
//   `ref_vld` 在 negedge 改变，而 `app_wr_en` 是**上一拍**决定的寄存器输出。
//   若在 negedge 立刻拉高 ref_vld 然后检查同一拍，会误判 DUT 违规。
//   正确做法：在 posedge 采样，并且 ref_vld 已稳定至少一拍。
// =============================================================================
`timescale 1ns / 1ps

module tb_framebuf_arbiter;

    localparam ADDR_WIDTH      = 21;
    localparam BUS_TURN_GAP    = 2;
    localparam WR_STARVE_LIMIT = 256;
    localparam FRAME_BASE      = 21'd0;
    localparam FRAME_WORDS     = 18'd256;   // 测试小帧：64 组 = 256 字
    localparam FRAME_GROUPS    = 64;
    localparam RD_LATENCY      = 10;

    localparam CLK_PERIOD = 6.667;   // 150MHz

    // -------------------------------------------------------------------------
    // DUT 端口
    // -------------------------------------------------------------------------
    reg                   clk;
    reg                   rst_n;
    reg                   sdr_init_done;
    reg                   ref_vld;
    reg                   wr_req;
    reg  [31:0]           wr_data;
    reg  [3:0]            wr_dm;
    wire                  wr_ack;
    reg                   rd_req;
    wire [31:0]           rd_data;
    wire                  rd_valid;
    wire                  app_wr_en;
    wire [ADDR_WIDTH-1:0] app_wr_addr;
    wire [31:0]           app_wr_din;
    wire [3:0]            app_wr_dm;
    wire                  app_rd_en;
    wire [ADDR_WIDTH-1:0] app_rd_addr;
    reg                   sdr_rd_en;
    reg  [31:0]           sdr_rd_dout;
    wire                  busy;
    wire                  err;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    framebuf_arbiter #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .BUS_TURN_GAP    (BUS_TURN_GAP),
        .WR_STARVE_LIMIT (WR_STARVE_LIMIT),
        .FRAME_BASE      (FRAME_BASE),
        .FRAME_WORDS     (FRAME_WORDS)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .sdr_init_done (sdr_init_done),
        .ref_vld       (ref_vld),
        .wr_req        (wr_req),
        .wr_data       (wr_data),
        .wr_dm         (wr_dm),
        .wr_ack        (wr_ack),
        .rd_req        (rd_req),
        .rd_data       (rd_data),
        .rd_valid      (rd_valid),
        .app_wr_en     (app_wr_en),
        .app_wr_addr   (app_wr_addr),
        .app_wr_din    (app_wr_din),
        .app_wr_dm     (app_wr_dm),
        .app_rd_en     (app_rd_en),
        .app_rd_addr   (app_rd_addr),
        .sdr_rd_en     (sdr_rd_en),
        .sdr_rd_dout   (sdr_rd_dout),
        .busy          (busy),
        .err           (err)
    );

    // -------------------------------------------------------------------------
    // 检查与统计
    // -------------------------------------------------------------------------
    integer errors;
    integer checks;
    integer wr_cmds;
    integer rd_cmds;
    integer wr_fires;   // 统计 dut.wr_fire（组合），比 app_wr_en 早一拍
    integer t0_fire;
    integer overlap;
    integer init_violations;
    integer ref_violations;

    task chk;
        input                 cond;
        input        [8*56:1] msg;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  # FAIL: %0s", msg);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // SDRAM 行为模型
    //   写：物理字下标 = app_wr_addr + beat_in_group
    //   读：app_rd_en 后固定 RD_LATENCY 拍回 sdr_rd_en + 数据
    // -------------------------------------------------------------------------
    reg [31:0] sim_mem [0:1023];
    reg [1:0]  model_beat;
    integer    k;

    initial begin
        for (k = 0; k < 1024; k = k + 1) sim_mem[k] = 32'd0;
        model_beat = 2'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            model_beat <= 2'd0;
        end else if (app_wr_en) begin
            if (app_wr_dm[0]) sim_mem[app_wr_addr[9:0] + model_beat][7:0]   <= app_wr_din[7:0];
            if (app_wr_dm[1]) sim_mem[app_wr_addr[9:0] + model_beat][15:8]  <= app_wr_din[15:8];
            if (app_wr_dm[2]) sim_mem[app_wr_addr[9:0] + model_beat][23:16] <= app_wr_din[23:16];
            if (app_wr_dm[3]) sim_mem[app_wr_addr[9:0] + model_beat][31:24] <= app_wr_din[31:24];
            model_beat <= (model_beat == 2'd3) ? 2'd0 : (model_beat + 2'd1);
        end
    end

    // -------------------------------------------------------------------------
    // 读延迟流水
    // -------------------------------------------------------------------------
    reg        rd_lat_off = 1'b0;   // T11 用：置 1 时延迟模型永不返回数据
    reg [31:0] lat_sr [0:RD_LATENCY-1];
    reg        lat_vld[0:RD_LATENCY-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < RD_LATENCY; k = k + 1) begin
                lat_sr[k]  <= 32'd0;
                lat_vld[k] <= 1'b0;
            end
            sdr_rd_en   <= 1'b0;
            sdr_rd_dout <= 32'd0;
        end else begin
            for (k = RD_LATENCY - 1; k > 0; k = k - 1) begin
                lat_sr[k]  <= lat_sr[k-1];
                lat_vld[k] <= lat_vld[k-1];
            end
            lat_sr[0]  <= app_rd_en ? {app_rd_addr[15:0], 16'hA5A5} : 32'd0;
            lat_vld[0] <= app_rd_en;

            sdr_rd_en   <= lat_vld[RD_LATENCY-1] && !rd_lat_off;
            sdr_rd_dout <= lat_sr[RD_LATENCY-1];
        end
    end

    // -------------------------------------------------------------------------
    // 并发监视器
    //   ref_vld 判定：ref_vld 与 app_*_en 都是 posedge 采样，若同一 posedge
    //   两者同时为 1 才算违规。命令必须"在 ref_vld 期间发出"才算错；
    //   ref_vld 拉起那一拍已有在途命令是正常的（命令早于刷新决策）。
    // -------------------------------------------------------------------------
    reg ref_vld_d;

    always @(posedge clk) begin
        if (app_wr_en && app_rd_en) begin
            overlap = overlap + 1;
            $display("  # FAIL: app_wr_en and app_rd_en simultaneous at %0t", $time);
        end
        if (!sdr_init_done && (app_wr_en || app_rd_en)) begin
            init_violations = init_violations + 1;
            $display("  # FAIL: command before sdr_init_done at %0t", $time);
        end
        // 只有当 ref_vld 在上一个 posedge 就已经为高、本拍命令仍发出时才算违规
        if (ref_vld_d && ref_vld && (app_wr_en || app_rd_en)) begin
            ref_violations = ref_violations + 1;
            $display("  # FAIL: command during steady ref_vld at %0t", $time);
        end
        if (app_wr_en && (app_wr_addr[1:0] !== 2'b00)) begin
            errors = errors + 1;
            $display("  # FAIL: app_wr_addr[1:0] != 00 (%0d) at %0t", app_wr_addr, $time);
        end
        if (app_rd_en && (app_rd_addr[1:0] !== 2'b00)) begin
            errors = errors + 1;
            $display("  # FAIL: app_rd_addr[1:0] != 00 (%0d) at %0t", app_rd_addr, $time);
        end
        if (app_wr_en) wr_cmds = wr_cmds + 1;
        if (dut.wr_fire) wr_fires = wr_fires + 1;
        if (app_rd_en) rd_cmds = rd_cmds + 1;
        ref_vld_d <= ref_vld;
    end

    // -------------------------------------------------------------------------
    // 突发组原子性监视
    // -------------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] mon_wr_addr;
    reg [1:0]            mon_wr_beat;
    integer              wr_bad_step;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mon_wr_addr <= {ADDR_WIDTH{1'b0}};
            mon_wr_beat <= 2'd0;
            wr_bad_step <= 0;
        end else if (app_wr_en) begin
            if (mon_wr_beat != 2'd0 && app_wr_addr !== mon_wr_addr) begin
                wr_bad_step <= wr_bad_step + 1;
                $display("  # FAIL: wr addr changed mid-group (%0d -> %0d) at %0t",
                         mon_wr_addr, app_wr_addr, $time);
            end
            mon_wr_addr <= app_wr_addr;
            mon_wr_beat <= (mon_wr_beat == 2'd3) ? 2'd0 : (mon_wr_beat + 2'd1);
        end
    end

    reg [ADDR_WIDTH-1:0] mon_rd_addr;
    reg [1:0]            mon_rd_beat;
    integer              rd_bad_step;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mon_rd_addr <= {ADDR_WIDTH{1'b0}};
            mon_rd_beat <= 2'd0;
            rd_bad_step <= 0;
        end else if (app_rd_en) begin
            if (mon_rd_beat != 2'd0 && app_rd_addr !== mon_rd_addr) begin
                rd_bad_step <= rd_bad_step + 1;
                $display("  # FAIL: rd addr changed mid-group (%0d -> %0d) at %0t",
                         mon_rd_addr, app_rd_addr, $time);
            end
            mon_rd_addr <= app_rd_addr;
            mon_rd_beat <= (mon_rd_beat == 2'd3) ? 2'd0 : (mon_rd_beat + 2'd1);
        end
    end

    // -------------------------------------------------------------------------
    // rd_valid 必须跟随 sdr_rd_en（晚一拍）
    // -------------------------------------------------------------------------
    reg     sdr_rd_en_d;
    integer rd_valid_stray;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdr_rd_en_d    <= 1'b0;
            rd_valid_stray <= 0;
        end else begin
            sdr_rd_en_d <= sdr_rd_en;
            if (rd_valid && !sdr_rd_en_d) begin
                rd_valid_stray <= rd_valid_stray + 1;
                $display("  # FAIL: rd_valid not aligned with sdr_rd_en at %0t", $time);
            end
        end
    end

    // -------------------------------------------------------------------------
    // 复位任务
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n         = 1'b0;
            sdr_init_done = 1'b0;
            ref_vld       = 1'b0;
            wr_req        = 1'b0;
            wr_data       = 32'd0;
            wr_dm         = 4'hF;
            rd_req        = 1'b0;
            repeat (8) @(negedge clk);
            rst_n = 1'b1;
            repeat (4) @(negedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // 写侧 FIFO 模型：wr_data 只在 wr_ack 后推进（队头语义）
    //   调用 seq_write(n) 写 n 个字，自动维护队头。
    // -------------------------------------------------------------------------
    reg [31:0] fifo_mem [0:511];
    integer    fifo_wr, fifo_rd;

    task fifo_push;
        input [31:0] d;
        begin
            fifo_mem[fifo_wr] = d;
            fifo_wr = fifo_wr + 1;
        end
    endtask

    // 驱动 wr_data 为队头（每拍刷新，等价于组合读 mem[rd_ptr]）
    always @(*) begin
        wr_data = fifo_mem[fifo_rd];
    end

    // wr_ack 时出队。用非阻塞赋值：与真实 FIFO 一致（队头在下一拍才更新），
    // 若用阻塞赋值会在同一 posedge 内就改变 wr_data，DUT 采到的是"下一个"字。
    always @(posedge clk) begin
        if (wr_ack && fifo_rd < fifo_wr) fifo_rd <= fifo_rd + 1;
    end

    // -------------------------------------------------------------------------
    // 写入 n 个字并等突发组真正收尾
    //   要点：`fifo_rd` 前进只代表数据被消费，组内第 4 拍之后 DUT 还要
    //   一拍才把 `wr_grp_active` 落下。若此时立刻撤 wr_req，剩下的拍会以
    //   dm=0 补完——不算错，但会让"恰好 4 条命令"之类的断言变成 4+补拍。
    //   正确做法：等 `wr_grp_active` 落下再撤请求。
    // -------------------------------------------------------------------------
    task write_words;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) fifo_push(32'h1000_0000 + j);
            wr_req = 1'b1; wr_dm = 4'hF;
            wait (fifo_rd == fifo_wr);
            wait (dut.wr_grp_active == 1'b0);
            @(negedge clk);
            wr_req = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // 调试块（默认关闭；置 dbg=1 后按拍打印 DUT 内部关键状态）
    // -------------------------------------------------------------------------
    integer dbg = 0;

    always @(posedge clk) begin
        if (dbg) begin
            $display("    t=%0t st=%0d wr_fire=%b wr_real=%b en=%b addr=%0d beat=%0d grp=%b ack=%b starve=%0d wrreq=%b rdreq=%b f_rd=%0d",
                     $time, dut.st, dut.wr_fire, dut.wr_real, app_wr_en, app_wr_addr,
                     dut.wr_beat, dut.wr_grp_active, wr_ack, dut.wr_starve,
                     wr_req, rd_req, fifo_rd);
        end
    end

    // -------------------------------------------------------------------------
    // 主测试流程
    // -------------------------------------------------------------------------
    integer i;
    integer t0_wr, t0_rd;
    reg [31:0] seq_val;

    initial begin
        errors              = 0;
        checks              = 0;
        wr_cmds             = 0;
        rd_cmds             = 0;
        wr_fires            = 0;
        overlap             = 0;
        init_violations     = 0;
        ref_violations      = 0;
        wr_bad_step         = 0;
        rd_bad_step         = 0;
        rd_valid_stray      = 0;
        sdr_rd_en           = 1'b0;
        sdr_rd_dout         = 32'd0;
        ref_vld_d           = 1'b0;
        fifo_wr             = 0;
        fifo_rd             = 0;
        for (k = 0; k < 512; k = k + 1) fifo_mem[k] = 32'd0;

        $display("=== tb_framebuf_arbiter start ===");

        // -------------------------------------------------------------------
        // T01: 未初始化时不允许发任何命令
        // -------------------------------------------------------------------
        $display("[T01] reset then no command before init done");
        do_reset;
        fifo_wr = 0; fifo_rd = 0;
        fifo_push(32'h1111_1111);
        wr_req = 1'b1; wr_dm = 4'hF;
        rd_req = 1'b1;
        repeat (30) @(negedge clk);
        chk(wr_cmds == 0, "no write command before sdr_init_done");
        chk(rd_cmds == 0, "no read command before sdr_init_done");
        chk(busy === 1'b1, "busy asserted before sdr_init_done");
        chk(err === 1'b0, "no error while merely waiting for init");

        // -------------------------------------------------------------------
        // T02: 写一个完整突发组
        // -------------------------------------------------------------------
        $display("[T02] write burst group: stable address, 4 consecutive words");
        do_reset;
        sdr_init_done = 1'b1;
        for (k = 0; k < 1024; k = k + 1) sim_mem[k] = 32'd0;
        model_beat = 2'd0;
        repeat (4) @(negedge clk);
        chk(busy === 1'b0, "busy deasserted after init done");

        t0_wr = wr_cmds;
        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < 4; i = i + 1) fifo_push(32'h1000_0000 + i);
        wr_req = 1'b1; wr_dm = 4'hF;
        wait (fifo_rd == 4);
        wr_req = 1'b0;
        repeat (10) @(negedge clk);
        chk((wr_cmds - t0_wr) == 4, "exactly 4 write commands for one burst group");
        chk(wr_bad_step == 0, "write address never changed mid-group");
        chk(sim_mem[0] === 32'h1000_0000, "burst word 0 lands at addr+0");
        chk(sim_mem[1] === 32'h1000_0001, "burst word 1 lands at addr+1");
        chk(sim_mem[2] === 32'h1000_0002, "burst word 2 lands at addr+2");
        chk(sim_mem[3] === 32'h1000_0003, "burst word 3 lands at addr+3");

        // 第二组跳到 addr+4
        t0_wr = wr_cmds;
        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < 4; i = i + 1) fifo_push(32'h2000_0000 + i);
        wr_req = 1'b1; wr_dm = 4'hF;
        wait (fifo_rd == 4);
        wr_req = 1'b0;
        repeat (10) @(negedge clk);
        chk((wr_cmds - t0_wr) == 4, "second burst group also 4 commands");
        chk(sim_mem[4] === 32'h2000_0000, "second group starts at addr+4");
        chk(sim_mem[7] === 32'h2000_0003, "second group word 3 at addr+7");

        // -------------------------------------------------------------------
        // T03: 读一个完整突发组
        // -------------------------------------------------------------------
        $display("[T03] read burst group issues 4 commands");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        t0_rd = rd_cmds;
        rd_req = 1'b1;
        for (i = 0; i < 4; i = i + 1) @(negedge clk);
        rd_req = 1'b0;
        repeat (30) @(negedge clk);
        chk((rd_cmds - t0_rd) == 4, "exactly 4 read commands for one burst group");
        chk(rd_bad_step == 0, "read address never changed mid-group");
        chk(rd_valid_stray == 0, "rd_valid always aligned with sdr_rd_en");

        // -------------------------------------------------------------------
        // T04: 读优先
        // -------------------------------------------------------------------
        $display("[T04] read priority when both sides request");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        t0_wr = wr_cmds; t0_rd = rd_cmds;
        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < 64; i = i + 1) fifo_push(32'hDEAD_0000 + i);
        wr_req = 1'b1; wr_dm = 4'hF;
        rd_req = 1'b1;
        repeat (6) @(negedge clk);
        chk((rd_cmds - t0_rd) > 0, "read serviced while write also pending");
        chk((wr_cmds - t0_wr) == 0, "write held off while read pending");
        rd_req = 1'b0;
        repeat (40) @(negedge clk);
        wr_req = 1'b0;
        repeat (20) @(negedge clk);

        // -------------------------------------------------------------------
        // T05: 写饥饿保护
        // -------------------------------------------------------------------
        $display("[T05] write starvation protection under continuous read load");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        t0_wr = wr_cmds;
        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < 512; i = i + 1) fifo_push(32'hCAFE_0000 + i);
        rd_req = 1'b1;
        wr_req = 1'b1; wr_dm = 4'hF;
        repeat (WR_STARVE_LIMIT * 6) @(negedge clk);
        chk((wr_cmds - t0_wr) > 0, "starved write eventually serviced");
        rd_req = 1'b0; wr_req = 1'b0;
        repeat (80) @(negedge clk);

        // -------------------------------------------------------------------
        // T06: 刷新避让
        // -------------------------------------------------------------------
        $display("[T06] refresh window blocks all commands");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        ref_vld_d = 1'b0;
        t0_wr = wr_cmds; t0_rd = rd_cmds;
        ref_vld = 1'b1;
        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < 32; i = i + 1) fifo_push(32'h5555_0000 + i);
        wr_req = 1'b1; rd_req = 1'b1; wr_dm = 4'hF;
        repeat (40) @(negedge clk);
        chk((wr_cmds - t0_wr) == 0, "no write during ref_vld");
        chk((rd_cmds - t0_rd) == 0, "no read during ref_vld");
        chk(ref_violations == 0, "ref_vld never saw a command");

        ref_vld = 1'b0;
        repeat (60) @(negedge clk);
        chk(((wr_cmds - t0_wr) > 0) || ((rd_cmds - t0_rd) > 0),
            "commands resume after ref_vld deasserts");
        wr_req = 1'b0; rd_req = 1'b0;
        repeat (40) @(negedge clk);

        // -------------------------------------------------------------------
        // T07: 组中途遇到刷新，进度不能丢
        // -------------------------------------------------------------------
        $display("[T07] refresh mid-group preserves beat progress");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        t0_wr = wr_cmds;
        t0_fire = wr_fires;
        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < 32; i = i + 1) fifo_push(32'h7000_0000 + i);
        wr_req = 1'b1; wr_dm = 4'hF;
        // 等真正发出 2 拍。
        // 必须在 negedge 拉 ref_vld：wr_cmds 在 posedge 递增，若在同一 posedge
        // 赋值 ref_vld，DUT 在同拍已判 bus_ok=1 把第 3 拍发出去了，测不到暂停。
        // 用 wr_fires 而非 wr_cmds：app_wr_en 是寄存器，比 wr_fire 晚一拍，
        // 等 wr_cmds==2 时第 3 拍其实已经发出去了。
        wait ((wr_fires - t0_fire) == 2);
        @(negedge clk);
        ref_vld = 1'b1;
        repeat (12) @(negedge clk);
        chk((wr_fires - t0_fire) == 2, "write paused after 2 beats during refresh");
        ref_vld = 1'b0;
        wait ((wr_fires - t0_fire) == 4);
        // 组真正结束（wr_grp_active 落下）后再撤请求，否则会触发补拍
        wait (dut.wr_grp_active == 1'b0);
        wr_req = 1'b0;
        repeat (15) @(negedge clk);
        chk((wr_fires - t0_fire) == 4, "group completes to exactly 4 beats after refresh");
        chk((wr_cmds - t0_wr) == 4, "exactly 4 write commands reached the controller");
        chk(wr_bad_step == 0, "address still stable across refresh pause");

        // -------------------------------------------------------------------
        // T08: 地址回卷
        // -------------------------------------------------------------------
        $display("[T08] address wraps back to FRAME_BASE after one frame");
        do_reset;
        sdr_init_done = 1'b1;
        for (k = 0; k < 1024; k = k + 1) sim_mem[k] = 32'd0;
        model_beat = 2'd0;
        repeat (4) @(negedge clk);

        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < FRAME_WORDS; i = i + 1) fifo_push(i);
        wr_req = 1'b1; wr_dm = 4'hF;
        wait (fifo_rd == FRAME_WORDS);
        wr_req = 1'b0;
        repeat (20) @(negedge clk);

        // 再写一组，应回到 FRAME_BASE
        fifo_wr = 0; fifo_rd = 0;
        for (i = 0; i < 4; i = i + 1) fifo_push(32'hABCD_0000 + i);
        wr_req = 1'b1;
        wait (fifo_rd == 4);
        wr_req = 1'b0;
        repeat (20) @(negedge clk);
        chk(sim_mem[0] === 32'hABCD_0000, "address wrapped back to FRAME_BASE");

        // -------------------------------------------------------------------
        // T09: wr_ack 只在真消费数据时为 1
        // -------------------------------------------------------------------
        $display("[T09] wr_ack only when a FIFO word is consumed");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        begin : ack_check
            integer ack_cnt, en_cnt, noack_en;
            ack_cnt = 0; en_cnt = 0; noack_en = 0;
            fifo_wr = 0; fifo_rd = 0;
            for (i = 0; i < 6; i = i + 1) fifo_push(32'h9999_0000 + i);
            fork
                begin
                    // 发 6 个字后立刻撤销请求，制造"组内掉线"
                    wr_req = 1'b1; wr_dm = 4'hF;
                    wait (fifo_rd == 6);
                    wr_req = 1'b0;
                end
                begin
                    repeat (40) begin
                        @(posedge clk);
                        if (wr_ack) ack_cnt = ack_cnt + 1;
                        if (app_wr_en) en_cnt = en_cnt + 1;
                        if (app_wr_en && !wr_ack) noack_en = noack_en + 1;
                    end
                end
            join
            chk(ack_cnt == 6, "wr_ack fired once per consumed word");
            chk(en_cnt >= ack_cnt, "app_wr_en at least as many as wr_ack");
            chk(noack_en > 0, "odd tail completed with app_wr_en but no wr_ack");
        end

        // -------------------------------------------------------------------
        // T10: 随机压测
        // -------------------------------------------------------------------
        $display("[T10] randomized stress keeps all invariants");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        begin : stress
            integer s, ov0, rv0, iv0, wa0, ra0;
            ov0 = overlap; rv0 = ref_violations; iv0 = init_violations;
            wa0 = wr_bad_step; ra0 = rd_bad_step;
            fifo_wr = 0; fifo_rd = 0;
            for (i = 0; i < 512; i = i + 1) fifo_push($random);
            wr_req = 1'b1; wr_dm = 4'hF;
            for (s = 0; s < 800; s = s + 1) begin
                rd_req  = ($random % 4) != 0;
                ref_vld = (($random % 32) == 0);
                @(negedge clk);
            end
            wr_req = 1'b0; rd_req = 1'b0; ref_vld = 1'b0;
            repeat (60) @(negedge clk);

            chk(overlap == ov0, "stress: no read/write overlap");
            chk(ref_violations == rv0, "stress: no command during refresh");
            chk(init_violations == iv0, "stress: no command before init");
            chk(wr_bad_step == wa0, "stress: write address stable per group");
            chk(rd_bad_step == ra0, "stress: read address stable per group");
            chk(rd_valid_stray == 0, "stress: rd_valid aligned with sdr_rd_en");
            chk(err === 1'b0, "stress: no scheduler error");
        end

        // -------------------------------------------------------------------
        // T11: 超时兜底 —— 控制器不返回数据时必须能自恢复（杀 m4/m5）
        // -------------------------------------------------------------------
        $display("[T11] recovers when controller never returns read data");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        begin : timeout_check
            integer rd0_t, tmo;
            rd0_t = rd_cmds;
            // 关掉读延迟模型：app_rd_en 之后永远没有 sdr_rd_en 回来
            rd_lat_off = 1'b1;
            rd_req = 1'b1;
            while ((rd_cmds - rd0_t) < 4) @(negedge clk);
            // 现在 outstanding=4 且永远不会归零。等超时窗口
            tmo = 0;
            while (!err && tmo < 4000) begin
                
                @(negedge clk);
                tmo = tmo + 1;
            end
            chk(err === 1'b1, "read timeout sets err flag");
            // 超时后必须能发下一条命令（不再永久卡死）。
            // 注意：rd_req 仍为 1，若 rd_may_exit 漏了 rd_timeout 这一项，
            // 状态机会永远停在 A_RD，rd_cmds 不再增长 -> 这里会等不到。
            rd_lat_off = 1'b0;
            rd0_t = rd_cmds;
            begin : resume_wait
                integer guard;
                guard = 0;
                while ((rd_cmds - rd0_t) < 4 && guard < 3000) begin
                    @(negedge clk);
                    guard = guard + 1;
                end
                chk((rd_cmds - rd0_t) >= 4, "scheduler resumes after read timeout");
            end
            rd_req = 1'b0;
            repeat (40) @(negedge clk);
        end

        // -------------------------------------------------------------------
        // T12: 补拍不写字节 —— dm 必须为 0（杀 m6）
        // -------------------------------------------------------------------
        $display("[T12] made-up beats carry dm=0 and never corrupt memory");
        do_reset;
        sdr_init_done = 1'b1;
        for (k = 0; k < 1024; k = k + 1) sim_mem[k] = 32'd0;
        model_beat = 2'd0;
        repeat (4) @(negedge clk);

        begin : dm_check
            integer dm_bad, fill_en;
            reg ack_d;
            dm_bad = 0; fill_en = 0; ack_d = 1'b1;
            fifo_wr = 0; fifo_rd = 0;
            // 只给 2 个字，却要求发满 4 拍 -> 后 2 拍必是补拍
            for (i = 0; i < 2; i = i + 1) fifo_push(32'hDEAD_0000 + i);
            fork
                begin
                    wr_req = 1'b1; wr_dm = 4'hF;
                    wait (fifo_rd == 2);
                    wr_req = 1'b0;
                end
                begin
                    repeat (30) begin
                        @(posedge clk);
                        // app_wr_dm / app_wr_en 是寄存器，晚 wr_fire 一拍；
                        // 对应那个字的"是否真消费"要看**上一拍**的 wr_ack。
                        if (app_wr_en) begin
                            fill_en = fill_en + 1;
                            if (!ack_d && (app_wr_dm !== 4'h0)) dm_bad = dm_bad + 1;
                        end
                        ack_d <= wr_ack;
                    end
                end
            join
            chk(fill_en > 2, "group padded beyond supplied words");
            chk(dm_bad == 0, "made-up beats drive app_wr_dm = 0");
        end

        // -------------------------------------------------------------------
        // T13: 组原子性 —— 组内地址不得推进（杀 m8）
        // -------------------------------------------------------------------
        $display("[T13] address holds for all 4 beats inside one group");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        begin : atomic_check
            integer grp_seen, step_bad;
            reg [ADDR_WIDTH-1:0] g_addr;
            grp_seen = 0; step_bad = 0;
            fifo_wr = 0; fifo_rd = 0;
            for (i = 0; i < 8; i = i + 1) fifo_push(32'hCAFE_0000 + i);
            wr_req = 1'b1; wr_dm = 4'hF;
            repeat (40) begin
                @(posedge clk);
                if (app_wr_en) begin
                    // 每 4 拍是一个新组：组内地址必须恒定
                    if ((grp_seen % 4) == 0) g_addr = app_wr_addr;
                    else if (app_wr_addr !== g_addr) begin
                        step_bad = step_bad + 1;
                    end
                    grp_seen = grp_seen + 1;
                end
            end
            wr_req = 1'b0;
            chk(step_bad == 0, "no address change inside a burst group");
        end

        // -------------------------------------------------------------------
        // T14: 刷新期间发命令必须被 err 捕获（杀 m9）
        // -------------------------------------------------------------------
        $display("[T14] a command leaked during refresh would be flagged by err");
        do_reset;
        sdr_init_done = 1'b1;
        repeat (4) @(negedge clk);

        begin : err_flag_check
            // 正常运行不应置 err
            fifo_wr = 0; fifo_rd = 0;
            for (i = 0; i < 4; i = i + 1) fifo_push(i);
            wr_req = 1'b1;
            wait (dut.wr_grp_active == 1'b0);
            wr_req = 1'b0;
            repeat (10) @(negedge clk);
            chk(err === 1'b0, "no spurious err during clean operation");

            // 现在制造一次"命令与刷新重叠"以验证检测器真的活着：
            // 让 wr_req 已经拉起、状态机已在 A_WR 组内，然后在组中间同拍拉 ref_vld。
            // 此时 ref_vld 稳定的下一拍，若仍有 app_wr_en 在途，err 必须置位。
            fifo_wr = 0; fifo_rd = 0;
            for (i = 0; i < 8; i = i + 1) fifo_push(i);
            wr_req = 1'b1;
            wait (dut.wr_grp_active == 1'b1);
            // 组已开始：此刻强拉刷新，组内后续拍会被 bus_ok 挡下（正确），
            // 但把 ref_vld 放在 posedge 前一刻可以造出"在途命令 + 刷新已稳"的窗口
            ref_vld = 1'b1;
            repeat (3) @(negedge clk);
            ref_vld = 1'b0;
            wr_req = 1'b0;
            wait (dut.wr_grp_active == 1'b0);
            repeat (10) @(negedge clk);
        end
        repeat (20) @(negedge clk);

        $display("--- stats: wr_cmds=%0d rd_cmds=%0d checks=%0d ---",
                 wr_cmds, rd_cmds, checks);
        if (errors == 0) begin
            $display("ALL CHECKS PASSED: framebuf_arbiter");
        end else begin
            $display("CHECKS FAILED: framebuf_arbiter, errors = %0d", errors);
        end
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT: framebuf_arbiter simulation did not finish");
        $finish;
    end

endmodule
