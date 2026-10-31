// Full-frame retention regression with the real APUG011 controller and vendor pin model.
// A 25MHz producer emits one 32-bit word each 96 clocks: six BMP bytes at
// 12.5MHz SPI (80ns/bit), in bottom-up BMP row order. Full four-word groups
// are released to the real production arbiter, matching image_player.
`timescale 1ns/1ps
module tb_sdram_frame_retention;
    parameter SPI_WORD_CYCLES=96;
    parameter READ_PASSES=2;
    parameter MIN_REFRESH_EDGES=1000;
    parameter HOLD_MS=64;
    localparam WORDS=153600, WORDS_LINE=320, GROUPS=38400;
    reg clk=0, pix_clk=0, rst_n=0;
    always #12.5 clk=~clk;
    always #20 pix_clk=~pix_clk;
    reg fifo_wr_en=0;
    reg [56:0] fifo_wr_data=0;
    wire fifo_full, fifo_empty;
    wire [56:0] fifo_out;
    reg [56:0] head=0;
    reg head_valid=0;
    wire wr_ack;
    wire fifo_pop=!fifo_empty && (!head_valid || wr_ack);
    integer produced=0, consumed=0, written=0;
    reg [15:0] prod_gray=0, prod_meta=0, prod_sync=0, cons_gray=0;
    reg [2:0] batch_left=0;
    wire [15:0] next_produced_group=(produced/4)+1;
    wire [15:0] next_consumed_group=(consumed/4)+1;
    wire wr_req=head_valid && (batch_left!=0);
    reg read_enable=0, rd_restart=0;
    reg [20:0] rd_base=0;
    integer issued_groups=0, returned=0, errors=0, pass=0;
    integer dark_pixels=0, black_pixels=0, white_pixels=0;
    integer refresh_cycles=0, refresh_edges=0;
    integer pin_refresh_commands=0;
    integer pin_runtime_commands=0, window_commands=0, window_checks=0;
    integer hold_pin_start=0, hold_app_start=0, refresh_coverage_errors=0;
    realtime last_pin_refresh=0.0, min_pin_gap=1000000000.0, max_pin_gap=0.0;
    realtime last_app_refresh=0.0, min_app_gap=1000000000.0, max_app_gap=0.0;
    realtime window_start=0.0;
    reg refresh_d=0;
    wire init_done, refresh, sdr_busy, arb_err, rd_idle, restart_done, refresh_error;
    wire rd_ack, rd_valid, raw_rd_valid;
    wire [31:0] rd_data, raw_rd_data;
    wire app_wr_en, app_rd_en;
    wire [20:0] app_wr_addr, app_rd_addr;
    wire [31:0] app_wr_data;
    wire [3:0] app_dm;
    wire rd_req=read_enable && (issued_groups<GROUPS);
    wire mem_clk, cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba;
    wire [10:0] addr;
    wire [3:0] dm;
    wire [31:0] dq;
    async_fifo #(.DATA_WIDTH(57),.ADDR_WIDTH(9)) fifo (
        .wr_clk(pix_clk),.wr_rst_n(rst_n),.wr_en(fifo_wr_en),.wr_data(fifo_wr_data),.wr_full(fifo_full),
        .rd_clk(clk),.rd_rst_n(rst_n),.rd_en(fifo_pop),.rd_data(fifo_out),.rd_empty(fifo_empty));
    always @(posedge pix_clk) if(rst_n && fifo_wr_en && !fifo_full) begin
        produced<=produced+1;
        if((produced%4)==3) prod_gray<=next_produced_group ^ (next_produced_group>>1);
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            head<=0;head_valid<=0;prod_meta<=0;prod_sync<=0;
            consumed<=0;cons_gray<=0;batch_left<=0;
        end else begin
            if(fifo_pop) begin head<=fifo_out;head_valid<=1;end
            else if(wr_ack) head_valid<=0;
            prod_meta<=prod_gray;prod_sync<=prod_meta;
            if(batch_left==0 && prod_sync!=cons_gray) batch_left<=4;
            else if(wr_ack) begin
                consumed<=consumed+1;
                if(batch_left==1) cons_gray<=next_consumed_group ^ (next_consumed_group>>1);
                batch_left<=batch_left-1;
            end
        end
    end
    framebuf_arbiter #(.WR_ADDR_FROM_FIFO(1),.FRAME_WORDS(WORDS)) arb (
        .clk(clk),.rst_n(rst_n),.sdr_init_done(init_done),.ref_vld(refresh),
        .wr_req(wr_req),.wr_word_addr(head[56:36]),.wr_data(head[31:0]),.wr_dm(head[35:32]),.wr_ack(wr_ack),
        .rd_req(rd_req),.rd_ack(rd_ack),.rd_data(rd_data),.rd_valid(rd_valid),.rd_idle(rd_idle),
        .rd_restart(rd_restart),.rd_base(rd_base),.rd_restart_done(restart_done),
        .app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),.app_wr_din(app_wr_data),.app_wr_dm(app_dm),
        .app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),.sdr_rd_en(raw_rd_valid),.sdr_rd_dout(raw_rd_data),.busy(),.err(arb_err));
    sdram_ctrl_wrap #(.SIM_MEM_WORDS(524288),.REFRESH_PERIOD(1250)) ctrl (
        .clk(clk),.clk_sft(~clk),.rst_n(rst_n),.init_done(init_done),.ref_vld(refresh),.busy(sdr_busy),.refresh_error(refresh_error),
        .app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),.app_wr_din(app_wr_data),.app_wr_dm(app_dm),
        .app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),.sdr_rd_en(raw_rd_valid),.sdr_rd_dout(raw_rd_data),
        .sdram_clk(mem_clk),.sdram_cke(cke),.sdram_cs_n(cs_n),.sdram_ras_n(ras_n),.sdram_cas_n(cas_n),
        .sdram_we_n(we_n),.sdram_ba(ba),.sdram_addr(addr),.sdram_dm(dm),.sdram_dq(dq));

    // All original vendor capacity and timing parameters are retained.
    IS42s32200 memory (.Dq(dq),.Addr(addr),.Ba(ba),.Clk(mem_clk),.Cke(cke),.Cs_n(cs_n),
        .Ras_n(ras_n),.Cas_n(cas_n),.We_n(we_n),.Dqm(dm));

    always @(posedge mem_clk) if(rst_n && {ras_n,cas_n,we_n}===3'b001) begin
        pin_refresh_commands=pin_refresh_commands+1;
        if(init_done) begin
            pin_runtime_commands=pin_runtime_commands+1;
            window_commands=window_commands+1;
            if(last_pin_refresh>0.0) begin
                if($realtime-last_pin_refresh<min_pin_gap) min_pin_gap=$realtime-last_pin_refresh;
                if($realtime-last_pin_refresh>max_pin_gap) max_pin_gap=$realtime-last_pin_refresh;
                if($realtime-last_pin_refresh<70.0 && refresh_coverage_errors<16)
                    $display("PIN_REF_SHORT gap_ns=%0.3f at_ns=%0.3f",$realtime-last_pin_refresh,$realtime);
            end
            last_pin_refresh=$realtime;
        end
    end
    // RGB888(24,24,48): (24>>3)<<11 | (24>>2)<<5 | (48>>3) = 18C6.
    function [15:0] pixel;
        input integer x,y;
        begin
            if(x<40 || x>=600 || y<40 || y>=440) pixel=16'hffff;
            else if(x>=140 && x<500 && y>=90 && y<390) begin
                if(x>=300 && x<340 && y>=140 && y<340) pixel=16'h0000;
                else pixel=16'hffff;
            end else pixel=16'h18c6;
        end
    endfunction
    function [31:0] pattern;
        input integer index;
        integer x,y;
        begin x=(index%WORDS_LINE)*2;y=index/WORDS_LINE;pattern={pixel(x+1,y),pixel(x,y)};end
    endfunction
    task count_pixel;
        input [15:0] value;
        begin
            case(value)
                16'h18c6:dark_pixels=dark_pixels+1;
                16'h0000:black_pixels=black_pixels+1;
                16'hffff:white_pixels=white_pixels+1;
            endcase
        end
    endtask
    always @(posedge clk) if(rst_n) begin
        refresh_d<=refresh;
        if(refresh) refresh_cycles=refresh_cycles+1;
        if(refresh && !refresh_d) begin
            refresh_edges=refresh_edges+1;
            if(init_done) begin
                if(last_app_refresh>0.0) begin
                    if($realtime-last_app_refresh<min_app_gap) min_app_gap=$realtime-last_app_refresh;
                    if($realtime-last_app_refresh>max_app_gap) max_app_gap=$realtime-last_app_refresh;
                end
                last_app_refresh=$realtime;
            end
        end
        if(init_done && window_start==0.0) window_start=$realtime;
        if(init_done && $realtime-window_start>=64000000.0) begin
            window_checks=window_checks+1;
            $display("REFRESH_WINDOW64 index=%0d physical_commands=%0d minimum=2048",window_checks,window_commands);
            if(window_commands<2048) refresh_coverage_errors=refresh_coverage_errors+1;
            window_commands=0;window_start=$realtime;
        end
        if(app_wr_en && !refresh) written=written+1;
        if(rd_ack) issued_groups=issued_groups+1;
        if(read_enable && rd_valid) begin
            if(rd_data!==pattern(returned)) begin
                if(errors<16) $display("MISMATCH pass=%0d word=%0d x=%0d y=%0d got=%08h expected=%08h",pass,returned,(returned%WORDS_LINE)*2,returned/WORDS_LINE,rd_data,pattern(returned));
                errors=errors+1;
            end
            count_pixel(rd_data[15:0]);count_pixel(rd_data[31:16]);
            returned=returned+1;
        end
        if(arb_err) $fatal(1,"Arbiter sticky fault");
        if(refresh_error !== 1'b0) $fatal(1,"Refresh scheduler sticky fault");
        if(refresh && (app_wr_en || app_rd_en)) $fatal(1,"Command accepted during refresh");
        if(app_wr_en && app_rd_en) $fatal(1,"Simultaneous read and write command");
        if(!app_wr_en && app_dm!==4'h0) $fatal(1,"Idle/read DQM must be zero");
    end
    integer y,wx,index,guard;
    initial begin
        $display("CONFIG sdr_mhz=40 pix_mhz=25 spi_mhz=12.5 cycles_per_word=%0d geometry=640x480 words=%0d palette=18c6,0000,ffff",SPI_WORD_CYCLES,WORDS);
        repeat(20) @(negedge pix_clk);rst_n=1;
        guard=0;while(!init_done && guard<200000) begin @(negedge clk);guard=guard+1;end
        if(!init_done) $fatal(1,"SDRAM initialization timeout");
        for(y=479;y>=0;y=y-1) begin
            for(wx=0;wx<WORDS_LINE;wx=wx+1) begin
                repeat(SPI_WORD_CYCLES-1) @(negedge pix_clk);
                index=y*WORDS_LINE+wx;
                if(fifo_full) $fatal(1,"SPI producer overflow");
                fifo_wr_data={index[20:2],2'b00,4'h0,pattern(index)};fifo_wr_en=1;
                @(negedge pix_clk);fifo_wr_en=0;
            end
            if(y%80==0) $display("LOAD_PROGRESS bottom_up_y=%0d produced=%0d consumed=%0d refresh_edges=%0d sim_time=%0t",y,produced,consumed,refresh_edges,$time);
        end
        guard=0;while(consumed<WORDS && guard<10000) begin @(negedge clk);guard=guard+1;end
        repeat(64) @(negedge clk);
        if(produced!=WORDS || consumed!=WORDS || written!=WORDS) $fatal(1,"Write counts differ: produced=%0d consumed=%0d written=%0d",produced,consumed,written);
        $display("WRITE_COMPLETE words=%0d refresh_edges=%0d sim_time=%0t",written,refresh_edges,$time);
        if(HOLD_MS>0) begin
            hold_pin_start=pin_runtime_commands;hold_app_start=refresh_edges;
            #(HOLD_MS*1000000.0);
            $display("HOLD_RESULT hold_ms=%0d physical_refreshes=%0d app_edges=%0d expected_per_64ms=2048",HOLD_MS,pin_runtime_commands-hold_pin_start,refresh_edges-hold_app_start);
            if(HOLD_MS==64 && pin_runtime_commands-hold_pin_start<2048) refresh_coverage_errors=refresh_coverage_errors+1;
        end
        for(pass=0;pass<READ_PASSES;pass=pass+1) begin
            @(negedge clk);rd_restart=1;@(negedge clk);rd_restart=0;
            guard=0;while(!restart_done && guard<10000) begin @(negedge clk);guard=guard+1;end
            if(!restart_done) $fatal(1,"Restart handshake timeout");
            returned=0;issued_groups=0;dark_pixels=0;black_pixels=0;white_pixels=0;read_enable=1;
            guard=0;while(returned<WORDS && guard<WORDS*64) begin @(negedge clk);guard=guard+1;end
            read_enable=0;repeat(64) @(negedge clk);
            $display("FRAME_RESULT pass=%0d returned=%0d groups=%0d errors=%0d dark_pixels=%0d black_pixels=%0d white_pixels=%0d refresh_edges=%0d sim_time=%0t",pass,returned,issued_groups,errors,dark_pixels,black_pixels,white_pixels,refresh_edges,$time);
            if(returned!=WORDS || issued_groups!=GROUPS || errors!=0 || dark_pixels!=116000 || black_pixels!=8000 || white_pixels!=183200) $fatal(1,"Full-frame readback failed");
        end
        $display("REFRESH_RESULT app_edges=%0d app_cycles=%0d pin_commands=%0d minimum_required=%0d",refresh_edges,refresh_cycles,pin_refresh_commands,MIN_REFRESH_EDGES);
        $display("REFRESH_GAPS pin_min_ns=%0.3f pin_max_ns=%0.3f app_min_ns=%0.3f app_max_ns=%0.3f windows64=%0d coverage_errors=%0d",min_pin_gap,max_pin_gap,min_app_gap,max_app_gap,window_checks,refresh_coverage_errors);
        if(refresh_edges<MIN_REFRESH_EDGES) $fatal(1,"Runtime refresh coverage is missing");
        if(min_pin_gap<70.0) $fatal(1,"Physical AREF spacing violates 70ns tRC");
        if(HOLD_MS!=64 || window_checks<1) $fatal(1,"The regression must exercise a full 64ms hold");
        if(HOLD_MS==64 && refresh_coverage_errors!=0) $fatal(1,"64ms refresh coverage failed");
        $display("RETENTION_RESULT frames=%0d words=%0d errors=%0d refresh_error=%b",READ_PASSES,READ_PASSES*WORDS,errors,refresh_error);
        $display("ALL CHECKS PASSED: sdram_frame_retention passes=%0d words_per_pass=%0d",READ_PASSES,WORDS);$finish;
    end
    initial begin #1000000000;$fatal(1,"Full frame global timeout");end
endmodule
