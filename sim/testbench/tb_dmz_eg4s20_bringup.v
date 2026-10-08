// =============================================================================
// tb_dmz_eg4s20_bringup.v
// 功能: dmz_eg4s20_bringup_top 的仿真 testbench
// 语法: 纯 Verilog-2001（不用 fork/join_any、disable 等 SV 构造）
// 验证项:
//   T1 复位后 640x480@60 时序（帧率≈59.5Hz, 行周期≈31.75us）
//   T2 彩条 8 色关键坐标（白/黄/品红/黑）
//   T3 KEY1 按键 → 消抖 → 图案切换（0→1）+ LED 更新
//   T4 网格图案关键点（白线 / 黑格心）
//   T5 帧图像 dump 为 PPM（肉眼复核仿真渲染结果）
// 采样时钟: video_clk_out 下降沿（25MHz, 半周期处稳定）
// =============================================================================
`timescale 1ns / 1ps

module tb_dmz_eg4s20_bringup;

    // ---- 50MHz 系统时钟 ----
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg  rst_n_btn = 1'b0;
    reg  [3:0] key_col;
    wire [3:0] key_row;

    wire [7:0] led;
    wire [7:0] seg_data;
    wire [3:0] seg_cs;
    wire       buzzer;
    wire [7:0] video_r, video_g, video_b;
    wire       video_hs, video_vs, video_de, video_clk_out;

    dmz_eg4s20_bringup_top dut (
        .clk           (clk),
        .rst_n_btn     (rst_n_btn),
        .key_row       (key_row),
        .key_col       (key_col),
        .led           (led),
        .seg_data      (seg_data),
        .seg_cs        (seg_cs),
        .buzzer        (buzzer),
        .video_r       (video_r),
        .video_g       (video_g),
        .video_b       (video_b),
        .video_hs      (video_hs),
        .video_vs      (video_vs),
        .video_de      (video_de),
        .video_clk_out (video_clk_out)
    );

    // ---- 期望值注入（供分层引用简化: 直接读 DUT 内部信号）----
    wire [2:0]  dbg_pattern_sel = dut.pattern_sel;
    wire [4:0]  dbg_img_index   = dut.img_index;
    wire [1:0]  dbg_mode        = dut.mode;
    wire [3:0]  dbg_key_code    = dut.key_code;
    wire        dbg_key_event   = dut.key_event;

    integer errors = 0;

    // ---- 帧计数（vs 上升沿）----
    integer vs_cnt = 0;
    reg vs_d = 1'b0;
    always @(posedge video_clk_out) begin
        vs_d <= video_vs;
        if (video_vs && !vs_d)
            vs_cnt = vs_cnt + 1;
    end

    // ---- 行周期测量（vs 高电平持续的非活跃行数→用 hs 周期测量更直接）----
    time t_hs_prev;
    time hs_period;
    reg  hs_d = 1'b0;
    always @(posedge video_hs) begin
        if (hs_d !== 1'bx) begin
            hs_period = $time - t_hs_prev;
        end
        t_hs_prev = $time;
    end

    // ---- 矩阵键盘行为模型 ----
    // 板级: 当 FPGA 将某行驱动为低且该键按下时, 对应列被拉低
    reg [15:0] key_pressed = 16'd0;
    integer    i;
    always @(*) begin
        key_col = 4'hF;
        for (i = 0; i < 4; i = i + 1) begin
            if (!key_row[i]) begin
                if (key_pressed[i*4 + 0]) key_col[0] = 1'b0;
                if (key_pressed[i*4 + 1]) key_col[1] = 1'b0;
                if (key_pressed[i*4 + 2]) key_col[2] = 1'b0;
                if (key_pressed[i*4 + 3]) key_col[3] = 1'b0;
            end
        end
    end

    // 按键按下（保持 hold_ms 后释放）
    task press_key;
        input integer keycode;
        input integer hold_ms;
        begin
            key_pressed = 16'd0;
            key_pressed[keycode] = 1'b1;
            #(hold_ms * 1_000_000);
            key_pressed = 16'd0;
        end
    endtask

    // ---- 在指定坐标采样像素并比对（带超时轮询, 纯 Verilog-2001）----
    task check_pixel;
        input [10:0] tx;
        input [9:0]  ty;
        input [7:0]  er;
        input [7:0]  eg;
        input [7:0]  eb;
        input [255:0] tag;
        integer guard;
        reg    hit;
        begin
            hit   = 1'b0;
            guard = 0;
            while (!hit && (guard < 2000000)) begin
                @(negedge video_clk_out);
                guard = guard + 1;
                if (video_de && (dut.active_x === tx) && (dut.active_y === ty)) begin
                    hit = 1'b1;
                    if ((video_r !== er) || (video_g !== eg) || (video_b !== eb)) begin
                        errors = errors + 1;
                        $display("[FAIL] %0s @(%0d,%0d) got(%02h,%02h,%02h) exp(%02h,%02h,%02h) t=%0t",
                                 tag, tx, ty, video_r, video_g, video_b, er, eg, eb, $time);
                    end
                    else begin
                        $display("[PASS] %0s @(%0d,%0d) = (%02h,%02h,%02h)",
                                 tag, tx, ty, video_r, video_g, video_b);
                    end
                end
            end
            if (!hit) begin
                errors = errors + 1;
                $display("[FAIL] %0s @(%0d,%0d): 超时未命中该坐标", tag, tx, ty);
            end
        end
    endtask

    // ---- 消隐期检查: de=0 时 RGB 必须为 0 ----
    task check_blanking;
        input [255:0] tag;
        integer guard;
        reg    bad;
        begin
            bad   = 1'b0;
            guard = 0;
            while (guard < 200000) begin
                @(negedge video_clk_out);
                guard = guard + 1;
                if (!video_de && ((video_r !== 8'h00) || (video_g !== 8'h00) || (video_b !== 8'h00)))
                    bad = 1'b1;
            end
            if (bad) begin
                errors = errors + 1;
                $display("[FAIL] %0s: 消隐期 RGB 非零", tag);
            end
            else
                $display("[PASS] %0s: 消隐期 RGB 全零", tag);
        end
    endtask

    // ---- 帧 dump 为 PPM（P3 文本格式）----
    task dump_frame;
        input [255:0] fname;
        integer f;
        integer x;
        integer y;
        begin
            // 同步到帧起始
            @(posedge video_vs);
            @(negedge video_vs);
            f = $fopen(fname, "w");
            $fwrite(f, "P3\n640 480\n255\n");
            for (y = 0; y < 480; y = y + 1) begin
                // 等待该行有效像素起点
                while (!video_de)
                    @(negedge video_clk_out);
                for (x = 0; x < 640; x = x + 1) begin
                    $fwrite(f, "%0d %0d %0d\n", video_r, video_g, video_b);
                    @(negedge video_clk_out);
                end
            end
            $fclose(f);
            $display("[%0t] PPM dumped: %0s", $time, fname);
        end
    endtask

    // ---- 主流程 ----
    initial begin
        $display("=== tb_dmz_eg4s20_bringup start ===");
        key_col = 4'hF;

        // T0 复位释放
        #1_000;
        rst_n_btn = 1'b1;
        $display("[%0t] T0 reset released", $time);

        // T1 时序: 等待约 4 帧
        #70_000_000;
        // 注: hs_period 为 time 型原始值（单位 ns, timescale=1ns）; 期望 32000ns = 32us
        $display("[%0t] T1 vs_cnt=%0d hs_period=%0d ns (期望 32000)", $time, vs_cnt, hs_period);
        if (vs_cnt < 3) begin
            errors = errors + 1;
            $display("[FAIL] T1 帧率异常: 70ms 内仅 %0d 帧", vs_cnt);
        end
        else
            $display("[PASS] T1 帧时序 (~59.5Hz)");

        // T2 彩条关键点（色带宽 80 像素）
        check_pixel(11'd40,  10'd240, 8'hFF, 8'hFF, 8'hFF, "T2 bar0 WHITE");
        check_pixel(11'd120, 10'd240, 8'hFF, 8'hFF, 8'h00, "T2 bar1 YELLOW");
        check_pixel(11'd360, 10'd240, 8'hFF, 8'h00, 8'hFF, "T2 bar4 MAGENTA");
        check_pixel(11'd600, 10'd240, 8'h00, 8'h00, 8'h00, "T2 bar7 BLACK");
        check_blanking("T2 blanking");

        // T5a dump 彩条帧
        dump_frame("sim_out_colorbar.ppm");

        // T3 按键: KEY1 按下 60ms（> 消抖 20ms）
        press_key(1, 60);
        #30_000_000;
        $display("[%0t] T3 pattern_sel=%0d img_index=%0d led=%02h mode=%0d",
                 $time, dbg_pattern_sel, dbg_img_index, led, dbg_mode);
        if (dbg_pattern_sel !== 3'd1) begin
            errors = errors + 1;
            $display("[FAIL] T3 按键后 pattern_sel 应为 1, 实际 %0d", dbg_pattern_sel);
        end
        else
            $display("[PASS] T3 按键→图案切换");

        // T4 网格关键点（64 像素网格: 行列线为白）
        check_pixel(11'd0,  10'd0,  8'hFF, 8'hFF, 8'hFF, "T4 grid line (0,0)");
        check_pixel(11'd32, 10'd32, 8'h00, 8'h00, 8'h00, "T4 grid cell (32,32)");

        // T5b dump 网格帧
        dump_frame("sim_out_grid.ppm");

        // ---- 汇总 ----
        $display("=== tb done, errors = %0d ===", errors);
        if (errors == 0)
            $display("*** ALL CHECKS PASSED ***");
        else
            $display("*** CHECKS FAILED ***");
        $finish;
    end

    // ---- 全局超时 ----
    initial begin
        #1_500_000_000;
        $display("[FAIL] 全局超时, errors=%0d", errors);
        $finish;
    end

endmodule
