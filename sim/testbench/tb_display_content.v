// Real BMP regression at the image_player boundary, derived from tb_image_player.
// FAT32, BMP parser, FIFOs, arbitration, SDRAM wrapper and pixel reader are real RTL.
// The sector service and SDRAM storage array are simulation models.
`timescale 1ns / 1ps
module tb_display_content #(parameter RD_GAP=1, parameter FUNCTIONAL_TIMING=1,
    parameter RELOAD_COUNT=0, parameter ARBITER_TURN_GAP=3, parameter DIAG_ONLY=0);
    localparam W=640, H=480, NSEC=4096;
    reg clk=0, sdr_clk=0, rst_n=0;
    always #20 clk=~clk;
    always #12.5 sdr_clk=~sdr_clk; // 40MHz, matching the production PLL
    wire blk_start;
    wire [31:0] blk_addr;
    reg blk_done=0, blk_err=0, data_valid=0;
    reg [7:0] data_byte=0;
    wire de, hs, vs, vblank;
    wire [10:0] x;
    wire [9:0] y;
    wire [15:0] rgb565;
    wire [15:0] out_w, out_h, out_off_x, out_off_y;
    wire pixel_valid, image_ready, loading, failed;
    wire pixel_shown;
    wire [3:0] error_code;
    wire [2:0] reader_status;
    reg load_req=0;
    reg [8:0] requested_index=9'd1;
    reg [7:0] disk[0:NSEC*512-1];
    reg [15:0] golden[0:W*H-1];
    reg [15:0] golden2[0:W*H-1];
    reg [1023:0] disk_file, golden_file, golden2_file, frame_file;
    integer checks=0, fails=0, missing=0, mismatched=0, sectors=0;
    integer underflow_events=0, overflow_events=0, rd_fault_events=0, rd_timeout_events=0;
    integer load_read_commands=0, load_write_commands=0, max_rd_wait=0;
    integer fifo_full_attempts=0, first_fifo_full_time=-1;
    integer diag_wr_ack=0, diag_app_wr=0;
    reg prev_underflow=0, prev_overflow=0, prev_rd_fault=0;
    integer mdl_state=0, mdl_i=0, mdl_gap=0;
    reg [31:0] mdl_lba=0;
    wire mem_clk, cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba;
    wire [10:0] addr;
    wire [3:0] dm;
    wire [31:0] dq;

    video_timing_gen timing (
        .pixel_clk(clk), .rst_n(rst_n), .hs(hs), .vs(vs), .de(de),
        .active_x(x), .active_y(y), .frame_start(), .vblank(vblank));
    image_player #(.WIDTH(W), .HEIGHT(H), .LOAD_TIMEOUT(100000000),
        .MEM_WORDS(524288), .SEAMLESS(1), .ARBITER_TURN_GAP(ARBITER_TURN_GAP)) dut (
        .pix_clk(clk), .rst_n_pix(rst_n), .sdr_clk(sdr_clk),
        .sdr_clk_sft(~sdr_clk), .rst_n_sdr(rst_n),
        .sd_ready(1'b1), .sd_failed(1'b0), .blk_busy(mdl_state != 0),
        .load_req(load_req), .image_index(requested_index), .blk_start(blk_start), .blk_addr(blk_addr),
        .blk_done(blk_done), .blk_err(blk_err), .data_byte(data_byte), .data_valid(data_valid),
        .de(de), .scan_y(vblank ? 10'd480 : y), .rgb565(rgb565), .pixel_valid(pixel_valid),
        .out_w(out_w), .out_h(out_h), .out_off_x(out_off_x), .out_off_y(out_off_y),
        .image_ready(image_ready), .loading(loading), .failed(failed), .error_code(error_code),
        .reader_status(reader_status), .sdram_clk(mem_clk), .sdram_cke(cke), .sdram_cs_n(cs_n),
        .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_ba(ba),
        .sdram_addr(addr), .sdram_dm(dm), .sdram_dq(dq),
        // v2 新增（T4）：外部写口全关，逻辑分辨率取容器尺寸（垂直映射恒等旁路）。
        .ext_wr_mode(1'b0), .ext_wr_valid(1'b0), .ext_wr_addr(21'd0), .ext_wr_data(32'd0),
        .ext_wr_dm(4'd0), .ext_wr_done(1'b0), .ext_no_fade(1'b0),
        .ext_wr_ack(), .ext_wr_busy(), .ext_frame_ready(), .ext_frame_sel(), .ext_loader_want_blk(),
        .src_w(16'd640), .src_h(16'd480),
        .win_w(16'd640), .win_h(16'd480), .win_off_x(16'd0), .win_off_y(16'd0),
        .active_x(x));

    image_window_mask u_reload_mask (
        .de(de), .active_x(x), .active_y(y),
        .win_w(out_w), .win_h(out_h), .win_off_x(out_off_x), .win_off_y(out_off_y),
        .pixel_valid(pixel_valid), .pixel_valid_out(pixel_shown));

`ifdef DISPLAY_REAL_CORE
    // The pin trace observes bank rotation every four app words. Do not infer
    // the app-to-bank mapping from older documentation when decoding commands.
    // A model bank indexes {row,column}, omitting the app's bank bits.
    // The back frame spans app addresses 153600..307199: per-bank index can
    // exceed 65535. Full 2048*256-word banks avoid a false out-of-range failure.
    IS42s32200 #(.mem_sizes(524287),
        .tAC(FUNCTIONAL_TIMING ? 1.0 : 5.5), .tHZ(FUNCTIONAL_TIMING ? 1.0 : 5.5),
        .tOH(FUNCTIONAL_TIMING ? 0.5 : 2.5), .tRAS(FUNCTIONAL_TIMING ? 0.0 : 49.0),
        .tRC(FUNCTIONAL_TIMING ? 0.0 : 70.0), .tRCD(FUNCTIONAL_TIMING ? 0.0 : 21.0),
        .tRP(FUNCTIONAL_TIMING ? 0.0 : 21.0), .tRRD(FUNCTIONAL_TIMING ? 0.0 : 14.0),
        .tDPL(FUNCTIONAL_TIMING ? 0.0 : 14.0)) memory (
        .Dq(dq), .Addr(addr), .Ba(ba), .Clk(mem_clk), .Cke(cke), .Cs_n(cs_n),
        .Ras_n(ras_n), .Cas_n(cas_n), .We_n(we_n), .Dqm(dm));
    integer app_min=2097151, app_max=0, pin_writes=0, pin_reads=0;
    always @(posedge sdr_clk) if (rst_n && dut.app_wr_en) begin
        if (dut.app_wr_addr < app_min) app_min=dut.app_wr_addr;
        if (dut.app_wr_addr > app_max) app_max=dut.app_wr_addr;
    end
    always @(posedge mem_clk) if (cke && !cs_n) begin
        if ({ras_n,cas_n,we_n} === 3'b100) pin_writes=pin_writes+1;
        if ({ras_n,cas_n,we_n} === 3'b101) pin_reads=pin_reads+1;
    end
`endif

    task check;
        input condition;
        input [8*120-1:0] label;
        begin
            checks=checks+1;
            if (condition !== 1'b1) begin
                fails=fails+1;
                if (fails <= 20) $display("FAIL: %0s t=%0t",label,$time);
            end
        end
    endtask

    task check_visible_frame;
        input integer expected_image;
        input integer save_ppm;
        integer frame_n, frame_fd;
        reg [15:0] expected_pixel;
        reg [7:0] r, green, b;
        begin
            while (!vblank) @(negedge clk);
            while (vblank) @(negedge clk);
            frame_fd=0;
            if (save_ppm) begin
                frame_fd=$fopen(frame_file,"wb");
                check(frame_fd != 0,"output PPM can be opened");
                if (frame_fd != 0) $fwrite(frame_fd,"P6\n640 480\n255\n");
            end
            frame_n=0;
            while (!vblank) begin
                if (de) begin
                    expected_pixel=expected_image ? golden2[y*W+x] : golden[y*W+x];
                    if (pixel_valid !== 1'b1) missing=missing+1;
                    if (rgb565 !== expected_pixel) begin
                        mismatched=mismatched+1;
                        if (mismatched <= 12)
                            $display("PIXEL_MISMATCH: image=%0d x=%0d y=%0d got=%h expected=%h valid=%b",
                                expected_image+1,x,y,rgb565,expected_pixel,pixel_valid);
                    end
                    check(pixel_valid,"every active pixel is valid");
                    check(rgb565 === expected_pixel,"display RGB565 equals expected BMP pixel");
                    r={rgb565[15:11],rgb565[15:13]};
                    green={rgb565[10:5],rgb565[10:9]};
                    b={rgb565[4:0],rgb565[4:2]};
                    if (save_ppm && frame_fd != 0) $fwrite(frame_fd,"%c%c%c",r,green,b);
                    frame_n=frame_n+1;
                end
                @(negedge clk);
            end
            if (frame_fd != 0) $fclose(frame_fd);
            check(frame_n==W*H,"all 307200 visible pixels were checked");
            check(!failed,"player remains healthy throughout the frame");
            $display("FRAME: index=%0d pixels=%0d underflow=%b overflow=%b rd_fault=%b",
                expected_image+1,frame_n,reader_status[0],reader_status[1],dut.u_arb.rd_fault);
        end
    endtask

    // Sticky reader and arbiter faults are counted independently. LED2 combines
    // overflow/underflow, whereas rd_timeout permanently latches the arbiter fault.
    always @(posedge clk) begin
        if (!rst_n) begin
            prev_underflow <= 1'b0;
            prev_overflow <= 1'b0;
        end else begin
            if (reader_status[0] && !prev_underflow) underflow_events=underflow_events+1;
            if (reader_status[1] && !prev_overflow) overflow_events=overflow_events+1;
            prev_underflow <= reader_status[0];
            prev_overflow <= reader_status[1];
        end
    end

    always @(posedge sdr_clk) begin
        if (!rst_n) prev_rd_fault <= 1'b0;
        else begin
            if ((dut.state == 4 || dut.state == 5) && image_ready) begin
                if (dut.app_rd_en) load_read_commands=load_read_commands+1;
                if (dut.app_wr_en) load_write_commands=load_write_commands+1;
            end
            if (dut.u_arb.rd_timeout) rd_timeout_events=rd_timeout_events+1;
            if (dut.u_arb.rd_fault && !prev_rd_fault) rd_fault_events=rd_fault_events+1;
            if (dut.u_arb.rd_wait_cnt > max_rd_wait) max_rd_wait=dut.u_arb.rd_wait_cnt;
            prev_rd_fault <= dut.u_arb.rd_fault;
        end
    end

    // Writer-side loss probe. img_loader emits fifo_wr_en without a ready
    // handshake; async_fifo silently ignores the write while full. Keep this
    // counter in the real image_player boundary so a reload can prove or
    // reject FIFO overflow without relying on display artifacts.
    always @(posedge clk) begin
        if (rst_n && dut.fifo_wr_en && dut.fifo_full) begin
            fifo_full_attempts=fifo_full_attempts+1;
            if (first_fifo_full_time < 0) first_fifo_full_time=$time;
        end
    end

    // Match the original integration bench's registered block-service handshake.
    always @(posedge clk) begin
        blk_done <= 0;
        blk_err <= 0;
        data_valid <= 0;
        if (!rst_n) begin mdl_state=0; mdl_i=0; mdl_gap=0; end
        else case (mdl_state)
            0: if (blk_start) begin
                sectors=sectors+1;
                if (blk_addr >= NSEC) begin
                    $display("FAIL: out-of-range sector %0d",blk_addr);
                    fails=fails+1; blk_err <= 1;
                end else begin
                    mdl_lba=blk_addr; mdl_i=0; mdl_gap=0; mdl_state=1;
                end
            end
            1: if (mdl_gap < RD_GAP) mdl_gap=mdl_gap+1;
               else begin
                   mdl_gap=0;
                   data_byte <= disk[mdl_lba*512+mdl_i];
                   data_valid <= 1;
                   mdl_i=mdl_i+1;
                   if (mdl_i == 512) mdl_state=2;
               end
            2: begin blk_done <= 1; mdl_state=0; end
            default: mdl_state=0;
        endcase
    end

    integer guard, n, g;
    integer reload_active_pixels, reload_mask_invalid;
    reg loading_d = 1'b0;
    always @(negedge clk) begin
        if (!rst_n) begin
            reload_active_pixels = 0;
            reload_mask_invalid = 0;
            loading_d = 1'b0;
        end else begin
            if (loading && !loading_d) begin
                // Measure only the current background reload, not boot or prior frames.
                reload_active_pixels = 0;
                reload_mask_invalid = 0;
            end else if (loading && image_ready && de) begin
                reload_active_pixels = reload_active_pixels + 1;
                if (!pixel_shown) reload_mask_invalid = reload_mask_invalid + 1;
            end
            loading_d = loading;
        end
    end
    initial begin
        disk_file="disk.hex"; golden_file="golden.hex"; golden2_file="golden2.hex"; frame_file="displayed.ppm";
        g=$value$plusargs("disk=%s",disk_file);
        g=$value$plusargs("golden=%s",golden_file);
        g=$value$plusargs("golden2=%s",golden2_file);
        g=$value$plusargs("frame=%s",frame_file);
        $readmemh(disk_file,disk);
        $readmemh(golden_file,golden);
        $readmemh(golden2_file,golden2);
        $display("DISPLAY_CONTENT: pixel_clock=25MHz SDRAM_clock=40MHz RD_GAP=%0d",RD_GAP);
        $display("CONFIG: reload_count=%0d",RELOAD_COUNT);
        $display("CONFIG: arbiter_turn_gap=%0d",ARBITER_TURN_GAP);
`ifdef DISPLAY_REAL_CORE
        $display("PIN_MODEL: APUG011 real encrypted core; bank_words=524288 FUNCTIONAL_TIMING=%0d",FUNCTIONAL_TIMING);
        $display("CONFIG: SDR_CLK_PERIOD=%0d SELF_REFRESH_INTERVAL=%0d",`SDR_CLK_PERIOD,`SELF_REFRESH_INTERVAL);
`endif
        repeat(8) @(negedge clk);
        rst_n=1;
        guard=0;
        while (!image_ready && !failed && guard<60000000) begin
            @(negedge clk); guard=guard+1;
        end
        check(image_ready && !failed,"real BMP is loaded and committed");
        $display("LOAD: cycles=%0d sectors=%0d ready=%b failed=%b error=%0d",guard,sectors,image_ready,failed,error_code);
        if (image_ready && !failed) begin
            if (!DIAG_ONLY) check_visible_frame(0,1);
            if (DIAG_ONLY) begin
                requested_index=9'd2;
                fifo_full_attempts=0; first_fifo_full_time=-1;
                @(negedge clk); load_req=1'b1;
                @(negedge clk); load_req=1'b0;
                guard=0;
                while (!dut.loader_busy && !dut.loader_fail && guard<30000000) begin
                    @(negedge clk); guard=guard+1;
                end
                while (!dut.loader_done && !dut.loader_fail && guard<30000000) begin
                    @(negedge clk); guard=guard+1;
                end
                while (!dut.writes_complete && !dut.loader_fail && guard<50000000) begin
                    @(negedge clk); guard=guard+1;
                end
                $display("DIAG_RELOAD: cycles=%0d state=%0d loader_busy=%b loader_done=%b loader_fail=%b pix_count=%0d fifo_full_attempts=%0d first_fifo_full_time=%0t produced=%0d consumed=%0d written=%0d expect=%0d writes_complete=%b prod_sync=%h consumed_gray=%h batch_left=%0d fifo_empty=%b",
                    guard,dut.state,dut.loader_busy,dut.loader_done,dut.loader_fail,dut.pixel_count,
                    fifo_full_attempts,first_fifo_full_time,dut.produced,dut.consumed,dut.written,
                    dut.expect_words,dut.writes_complete,dut.prod_sync,dut.consumed_gray,dut.batch_left,dut.fifo_empty);
                if (fifo_full_attempts!=0 || dut.pixel_count!=307200 || dut.produced!=153600 ||
                    dut.consumed!=153600 || dut.written!=153600 || !dut.writes_complete)
                    $fatal(1,"reload lost FIFO data or failed to finish SDRAM writes");
                $finish;
            end
            for (n=0; n<RELOAD_COUNT; n=n+1) begin
                // Exercise KEY1-like reloads with two distinct real BMPs. The first
                // reload targets IMG002; the next returns to IMG001.
                requested_index=(n % 2 == 0) ? 9'd2 : 9'd1;
                @(negedge clk); load_req=1'b1;
                @(negedge clk); load_req=1'b0;
                guard=0;
                while (((dut.state != 6) || loading || dut.commit_pending || (dut.fade_state != 0)) &&
                       !failed && guard<100000000) begin
                    @(negedge clk); guard=guard+1;
                end
                check(dut.state==6 && !loading && !dut.commit_pending && dut.fade_state==0,
                    "reload completes, commits, and finishes its fade within bound");
                check(!failed && image_ready,"old front buffer remains healthy during reload");
                check(reload_active_pixels > 100000,"old front frame remains visible while the back frame loads");
                check(reload_mask_invalid < 1000,"committed image window remains valid while the back frame loads");
                check(dut.selected_index==requested_index,"requested gallery index is committed");
                $display("RELOAD: index=%0d cycles=%0d sectors=%0d state=%0d failed=%b error=%0d written=%0d expect=%0d writes_complete=%b fifo_empty=%b batch_left=%0d",
                    requested_index,guard,sectors,dut.state,failed,error_code,dut.written,dut.expect_words,
                    dut.writes_complete,dut.fifo_empty,dut.batch_left);
                check_visible_frame(requested_index==2,0);
            end
            check(reader_status[1:0]==0,"reader reports no underflow or overflow across all loads");
            check(rd_timeout_events==0 && rd_fault_events==0,"arbiter read timeout/fault never occurs");
            if (RELOAD_COUNT > 0) begin
                check(load_read_commands>0,"front buffer is read while a back-buffer reload is active");
                check(load_write_commands>0,"back buffer is written while the front buffer remains displayed");
            end
        end
`ifdef DISPLAY_REAL_CORE
        $display("PIN_RESULT: app_write_min=%0d app_write_max=%0d pin_writes=%0d pin_reads=%0d mode=%h",app_min,app_max,pin_writes,pin_reads,memory.Mode_reg);
        if (RELOAD_COUNT == 0)
            check(app_min==153600 && app_max>=307196,"production back-buffer address range exercised");
        else
            check(app_min==0 && app_max>=307196,"both production back-buffer address ranges exercised");
        check(pin_writes>0 && pin_reads>0,"physical SDRAM read and write commands exercised");
`endif
        $display("SUMMARY: checks=%0d errors=%0d missing=%0d mismatched=%0d underflow=%0d overflow=%0d rd_fault=%0d rd_timeout=%0d load_reads=%0d load_writes=%0d max_rd_wait=%0d",
            checks,fails,missing,mismatched,underflow_events,overflow_events,rd_fault_events,
            rd_timeout_events,load_read_commands,load_write_commands,max_rd_wait);
        if (fails==0) $display("ALL CHECKS PASSED: display_content");
        else $display("CHECKS FAILED: display_content");
        $finish;
    end
    initial begin
        #(64'd2500000000 + (RELOAD_COUNT * 64'd5000000000));
        $display("CHECKS FAILED: display_content GLOBAL TIMEOUT");
        $finish;
    end
endmodule

`ifdef DISPLAY_REAL_CORE
// Minimal APUG011 read-boundary replay: two uniform physical rows replace the
// image/SD/FAT32/FIFO path; app read-group cadence comes from the failing trace.
module tb_display_core_replay #(parameter FUNCTIONAL_TIMING=1, parameter SHORT_GAP=12,
    parameter FIRST_GROUP=0, parameter GROUP_COUNT=16);
    reg clk=0, rst_n=0, rd_en=0;
    reg [20:0] rd_addr=0;
    always #12.5 clk=~clk;
    wire init_done, ref_vld, rd_valid;
    wire [31:0] rd_data;
    wire mem_clk, cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba;
    wire [10:0] addr;
    wire [3:0] dm;
    wire [31:0] dq;
    integer checks=0, fails=0, returned=0, pin_inactive=0, group_i, i, gap;
    reg [31:0] expected;
    sdram_ctrl_wrap u_sdram (
        .clk(clk),.clk_sft(~clk),.rst_n(rst_n),.init_done(init_done),.ref_vld(ref_vld),.busy(),
        .app_wr_en(1'b0),.app_wr_addr(21'd0),.app_wr_din(32'd0),.app_wr_dm(4'd0),
        .app_rd_en(rd_en),.app_rd_addr(rd_addr),.sdr_rd_en(rd_valid),.sdr_rd_dout(rd_data),
        .sdram_clk(mem_clk),.sdram_cke(cke),.sdram_cs_n(cs_n),.sdram_ras_n(ras_n),
        .sdram_cas_n(cas_n),.sdram_we_n(we_n),.sdram_ba(ba),.sdram_addr(addr),.sdram_dm(dm),.sdram_dq(dq));
    IS42s32200 #(.mem_sizes(524287),
        .tAC(FUNCTIONAL_TIMING ? 1.0 : 5.5),.tHZ(FUNCTIONAL_TIMING ? 1.0 : 5.5),
        .tOH(FUNCTIONAL_TIMING ? 0.5 : 2.5),.tRAS(FUNCTIONAL_TIMING ? 0.0 : 49.0),
        .tRC(FUNCTIONAL_TIMING ? 0.0 : 70.0),.tRCD(FUNCTIONAL_TIMING ? 0.0 : 21.0),
        .tRP(FUNCTIONAL_TIMING ? 0.0 : 21.0),.tRRD(FUNCTIONAL_TIMING ? 0.0 : 14.0),
        .tDPL(FUNCTIONAL_TIMING ? 0.0 : 14.0)) memory (
        .Dq(dq),.Addr(addr),.Ba(ba),.Clk(mem_clk),.Cke(cke),.Cs_n(cs_n),
        .Ras_n(ras_n),.Cas_n(cas_n),.We_n(we_n),.Dqm(dm));
    always @(posedge clk) if (rd_valid) begin
        expected=(FIRST_GROUP*4+returned<32) ? 32'hffffffff : 32'h18c618c6;
        checks=checks+1;
        if (rd_data !== expected) begin
            fails=fails+1;
            $display("FAIL: replay word=%0d app=%0d got=%h expected=%h",returned,166880+FIRST_GROUP*4+returned,rd_data,expected);
        end
        returned=returned+1;
    end
    always @(posedge mem_clk) if (cke && !cs_n && {ras_n,cas_n,we_n}!=3'b111) begin
        if ({ras_n,cas_n,we_n}==3'b101 &&
            ((ba==0 && !memory.Act_b0) || (ba==1 && !memory.Act_b1) ||
             (ba==2 && !memory.Act_b2) || (ba==3 && !memory.Act_b3))) pin_inactive=pin_inactive+1;
    end
    initial begin
        $display("CONFIG: SDR_CLK_PERIOD=%0d SELF_REFRESH_INTERVAL=%0d",`SDR_CLK_PERIOD,`SELF_REFRESH_INTERVAL);
        $display("REPLAY_CONFIG: first_group=%0d groups=%0d short_gap=%0d FUNCTIONAL_TIMING=%0d",FIRST_GROUP,GROUP_COUNT,SHORT_GAP,FUNCTIONAL_TIMING);
        repeat(8) @(negedge clk); rst_n=1;
        wait(init_done); repeat(20) @(negedge clk);
        for(i=0;i<256;i=i+1) begin
            memory.Bank0[162*256+i]=32'hffffffff; memory.Bank1[162*256+i]=32'hffffffff;
            memory.Bank2[162*256+i]=32'hffffffff; memory.Bank3[162*256+i]=32'hffffffff;
            memory.Bank0[163*256+i]=32'h18c618c6; memory.Bank1[163*256+i]=32'h18c618c6;
            memory.Bank2[163*256+i]=32'h18c618c6; memory.Bank3[163*256+i]=32'h18c618c6;
        end
        for(group_i=0;group_i<GROUP_COUNT;group_i=group_i+1) begin
            rd_addr=166880+(FIRST_GROUP+group_i)*4; rd_en=1;
            $display("REPLAY_APP: t=%t group=%0d addr=%0d ref=%b",$time,FIRST_GROUP+group_i,rd_addr,ref_vld);
            repeat(4) @(negedge clk); rd_en=0;
            gap=((GROUP_COUNT==2 && group_i==0) || (GROUP_COUNT!=2 && FIRST_GROUP+group_i==9)) ? SHORT_GAP : 13;
            repeat(gap-4) @(negedge clk);
        end
        repeat(100) @(negedge clk);
        checks=checks+1;
        if(returned!=GROUP_COUNT*4) begin fails=fails+1; $display("FAIL: replay returned=%0d expected=%0d",returned,GROUP_COUNT*4); end
        checks=checks+1;
        if(pin_inactive!=0) begin fails=fails+1; $display("FAIL: replay inactive bank reads=%0d",pin_inactive); end
        $display("SUMMARY: checks=%0d errors=%0d missing=%0d mismatched=%0d",checks,fails,GROUP_COUNT*4-returned,fails);
        if(fails==0) $display("ALL CHECKS PASSED: display_core_replay");
        else $display("CHECKS FAILED: display_core_replay");
        $finish;
    end
    initial begin #10000000; $display("CHECKS FAILED: display_core_replay GLOBAL TIMEOUT"); $finish; end
endmodule
`endif
