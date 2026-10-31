// Real BMP regression at the image_player boundary, derived from tb_image_player.
// FAT32, BMP parser, FIFOs, arbitration, SDRAM wrapper and pixel reader are real RTL.
// The sector service and SDRAM storage array are simulation models.
`timescale 1ns / 1ps
module tb_display_content #(parameter RD_GAP=1, parameter FUNCTIONAL_TIMING=1);
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
    wire [3:0] error_code;
    wire [2:0] reader_status;
    reg [7:0] disk[0:NSEC*512-1];
    reg [15:0] golden[0:W*H-1];
    reg [1023:0] disk_file, golden_file, frame_file;
    integer checks=0, fails=0, missing=0, mismatched=0, sectors=0;
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
        .MEM_WORDS(524288), .SEAMLESS(1)) dut (
        .pix_clk(clk), .rst_n_pix(rst_n), .sdr_clk(sdr_clk),
        .sdr_clk_sft(~sdr_clk), .rst_n_sdr(rst_n),
        .sd_ready(1'b1), .sd_failed(1'b0), .blk_busy(mdl_state != 0),
        .load_req(1'b0), .image_index(9'd1), .blk_start(blk_start), .blk_addr(blk_addr),
        .blk_done(blk_done), .blk_err(blk_err), .data_byte(data_byte), .data_valid(data_valid),
        .de(de), .scan_y(vblank ? 10'd480 : y), .rgb565(rgb565), .pixel_valid(pixel_valid),
        .out_w(out_w), .out_h(out_h), .out_off_x(out_off_x), .out_off_y(out_off_y),
        .image_ready(image_ready), .loading(loading), .failed(failed), .error_code(error_code),
        .reader_status(reader_status), .sdram_clk(mem_clk), .sdram_cke(cke), .sdram_cs_n(cs_n),
        .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_ba(ba),
        .sdram_addr(addr), .sdram_dm(dm), .sdram_dq(dq));

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

    integer guard, n, fd, g;
    reg [15:0] expected;
    reg [7:0] r, green, b;
    initial begin
        disk_file="disk.hex"; golden_file="golden.hex"; frame_file="displayed.ppm";
        g=$value$plusargs("disk=%s",disk_file);
        g=$value$plusargs("golden=%s",golden_file);
        g=$value$plusargs("frame=%s",frame_file);
        $readmemh(disk_file,disk);
        $readmemh(golden_file,golden);
        $display("DISPLAY_CONTENT: pixel_clock=25MHz SDRAM_clock=40MHz RD_GAP=%0d",RD_GAP);
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
            // Begin at a complete visible frame after commit and FIFO prefill.
            while (!vblank) @(negedge clk);
            while (vblank) @(negedge clk);
            fd=$fopen(frame_file,"wb");
            check(fd != 0,"output PPM can be opened");
            $fwrite(fd,"P6\n640 480\n255\n");
            n=0;
            while (!vblank) begin
                if (de) begin
                    expected=golden[y*W+x];
                    if (pixel_valid !== 1'b1) missing=missing+1;
                    if (rgb565 !== expected) begin
                        mismatched=mismatched+1;
                        if (mismatched <= 12)
                            $display("PIXEL_MISMATCH: x=%0d y=%0d got=%h expected=%h valid=%b",x,y,rgb565,expected,pixel_valid);
                    end
                    check(pixel_valid,"every active pixel is valid");
                    check(rgb565 === expected,"display RGB565 equals actual BMP pixel");
                    r={rgb565[15:11],rgb565[15:13]};
                    green={rgb565[10:5],rgb565[10:9]};
                    b={rgb565[4:0],rgb565[4:2]};
                    $fwrite(fd,"%c%c%c",r,green,b);
                    n=n+1;
                end
                @(negedge clk);
            end
            $fclose(fd);
            check(n==W*H,"all 307200 visible pixels were checked");
            check(reader_status[1:0]==0,"reader reports no underflow or overflow");
            check(!failed,"player remains healthy throughout the frame");
        end
`ifdef DISPLAY_REAL_CORE
        $display("PIN_RESULT: app_write_min=%0d app_write_max=%0d pin_writes=%0d pin_reads=%0d mode=%h",app_min,app_max,pin_writes,pin_reads,memory.Mode_reg);
        check(app_min==153600 && app_max>=307196,"production back-buffer address range exercised");
        check(pin_writes>0 && pin_reads>0,"physical SDRAM read and write commands exercised");
`endif
        $display("SUMMARY: checks=%0d errors=%0d missing=%0d mismatched=%0d",checks,fails,missing,mismatched);
        if (fails==0) $display("ALL CHECKS PASSED: display_content");
        else $display("CHECKS FAILED: display_content");
        $finish;
    end
    initial begin
        #(64'd2500000000);
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
