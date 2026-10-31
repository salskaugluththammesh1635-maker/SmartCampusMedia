// Real-core refresh cadence, drain handshake, watchdog and reset recovery.
`timescale 1ns/1ps
module tb_sdram_refresh_config;
    localparam integer PERIOD_NS=`SDR_CLK_PERIOD;
    localparam integer INTERVAL_CYCLES=`SELF_REFRESH_INTERVAL;
    localparam integer WINDOW_CYCLES=64000000/25;
    reg clk=0,rst_n=0;
    always #12.5 clk=~clk;
    wire init_done,refresh,refresh_error,mem_clk,cke,cs_n,ras_n,cas_n,we_n;
    wire [31:0] dq,app_wr_din,sdr_rd_dout;
    wire [20:0] app_wr_addr,app_rd_addr;
    wire [3:0] app_wr_dm;
    wire app_wr_en,app_rd_en,sdr_rd_en,wr_ack,rd_ack,arb_error;
    reg wr_req=0,rd_req=0;
    framebuf_arbiter arb(.clk(clk),.rst_n(rst_n),.sdr_init_done(init_done),.ref_vld(refresh),
        .wr_req(wr_req),.wr_word_addr(21'd0),.wr_data(32'h12345678),.wr_dm(4'd0),.wr_ack(wr_ack),
        .rd_req(rd_req),.rd_data(),.rd_valid(),.rd_ack(rd_ack),.rd_restart(1'b0),.rd_base(21'd0),
        .rd_idle(),.rd_restart_done(),.app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),
        .app_wr_din(app_wr_din),.app_wr_dm(app_wr_dm),.app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),
        .sdr_rd_en(sdr_rd_en),.sdr_rd_dout(sdr_rd_dout),.busy(),.err(arb_error));
    sdram_ctrl_wrap dut(.clk(clk),.clk_sft(~clk),.rst_n(rst_n),.init_done(init_done),
        .ref_vld(refresh),.refresh_error(refresh_error),.busy(),
        .app_wr_en(app_wr_en),.app_wr_addr(app_wr_addr),.app_wr_din(app_wr_din),.app_wr_dm(app_wr_dm),
        .app_rd_en(app_rd_en),.app_rd_addr(app_rd_addr),.sdr_rd_en(sdr_rd_en),.sdr_rd_dout(sdr_rd_dout),
        .sdram_clk(mem_clk),.sdram_cke(cke),.sdram_cs_n(cs_n),.sdram_ras_n(ras_n),.sdram_cas_n(cas_n),
        .sdram_we_n(we_n),.sdram_ba(),.sdram_addr(),.sdram_dm(),.sdram_dq(dq));

    integer checks=0,errors=0,cases=0;
    task check;
        input condition;
        input [1023:0] description;
        begin
            checks=checks+1;
            if(condition!==1'b1) begin
                errors=errors+1;
                $display("FAIL: %0s at %0.3f ns",description,$realtime);
                $display("SUMMARY: checks=%0d errors=%0d cases=%0d",checks,errors,cases);
                $fatal(1,"Refresh regression check failed");
            end
        end
    endtask
    task wait_init;
        integer remaining;
        begin
            remaining=200000;
            while(!init_done && remaining>0) begin @(negedge clk);remaining=remaining-1;end
            check(init_done,"real SDRAM initialization completes");
        end
    endtask
    task wait_run;
        integer remaining;
        begin
            remaining=4000;
            while((dut.refresh_state!=0 || refresh) && remaining>0) begin
                @(negedge clk);remaining=remaining-1;
            end
            check(dut.refresh_state==0 && !refresh,"refresh returns to RUN");
        end
    endtask

    integer pin_count=0,app_edges=0,accepted_reads=0;
    reg previous_refresh=0,window_active=0;
    realtime last_ref=0.0,first_ref=0.0,min_gap=1.0e12,max_gap=0.0,window_start=0.0;
    always @(posedge mem_clk) begin
        if(rst_n && init_done && cke && !cs_n && {ras_n,cas_n,we_n}===3'b001) begin
            pin_count=pin_count+1;
            if(window_active) begin
                if(first_ref==0.0) first_ref=$realtime;
                if(last_ref>0.0) begin
                    if($realtime-last_ref<min_gap) min_gap=$realtime-last_ref;
                    if($realtime-last_ref>max_gap) max_gap=$realtime-last_ref;
                end
                last_ref=$realtime;
            end
        end
    end
    always @(posedge clk) begin
        if(!rst_n) previous_refresh<=0;
        else begin
            previous_refresh<=refresh;
            if(init_done && refresh && !previous_refresh) app_edges=app_edges+1;
            if(init_done && app_rd_en) accepted_reads=accepted_reads+1;
            if(init_done && refresh)
                check(!(app_wr_en || app_rd_en || wr_ack || rd_ack),"refresh blocks arbiter command acceptance");
        end
    end
    integer guard,pin_start,app_start,read_start,watchdog_cycles;
    initial begin
        cases=cases+1;
        $display("CASE 1: macro configuration");
        $display("MACRO_CONFIG period_ns=%0d interval_cycles=%0d minus_ten=%0d",PERIOD_NS,INTERVAL_CYCLES,`SELF_REFRESH_INTERVAL-10);
        check(PERIOD_NS==25 && INTERVAL_CYCLES==625 && (`SELF_REFRESH_INTERVAL-10)==615,
            "refresh macro substitution preserves arithmetic grouping");
        repeat(16) @(negedge clk);rst_n=1;
        wait_init;

        cases=cases+1;
        $display("CASE 2: idle 64 ms physical refresh coverage");
        pin_start=pin_count;app_start=app_edges;window_start=$realtime;window_active=1;
        repeat(WINDOW_CYCLES) @(negedge clk);
        window_active=0;
        $display("REFRESH_WINDOW duration_ns=64000000 physical_commands=%0d app_edges=%0d min_gap_ns=%0.3f max_gap_ns=%0.3f datasheet_rows=2048",
            pin_count-pin_start,app_edges-app_start,min_gap,max_gap);
        check(pin_count-pin_start>=2048,"at least 2048 physical AREF commands per 64 ms");
        check(app_edges-app_start>=2048,"refresh availability covers every refresh transaction");
        check(min_gap>=70.0,"physical AREF spacing meets 70 ns and excludes adjacent 25 ns AREF");
        check(max_gap<=31250.0,"physical AREF maximum gap meets 31250 ns row retention budget");
        check(first_ref-window_start<=31250.0 && $realtime-last_ref<=31250.0,
            "refresh cadence covers both 64 ms window boundaries");
        check(!refresh_error && !arb_error,"idle refresh completes without sticky errors");

        cases=cases+1;
        $display("CASE 3: pending read returns hold the refresh drain window");
        wait_run;
        // Delay actual valid returns after accepting one complete four-word group.
        // Replay four valid beats below to release the controlled drain stall.
        force dut.sdr_rd_en=1'b0;
        read_start=accepted_reads;rd_req=1;
        guard=100;
        while(!rd_ack && guard>0) begin @(negedge clk);guard=guard-1;end
        check(rd_ack,"arbiter starts the read group used for drain injection");
        @(negedge clk);rd_req=0;
        guard=100;
        while(accepted_reads-read_start<4 && guard>0) begin @(negedge clk);guard=guard-1;end
        check(accepted_reads-read_start==4 && dut.read_pending==4,"four accepted reads remain pending");
        guard=1000;
        while(!refresh && guard>0) begin @(negedge clk);guard=guard-1;end
        check(refresh,"refresh is asserted before outstanding returns drain");
        wr_req=1;rd_req=1;pin_start=pin_count;
        repeat(128) begin
            @(negedge clk);
            check(refresh && dut.read_pending==4,"ref_vld remains high while four returns are pending");
            check(!dut.manual_request,"manual refresh waits for pending returns");
            check(!(app_wr_en || app_rd_en || wr_ack || rd_ack),"waiting requests cannot enter the drain window");
            check(!refresh_error && !arb_error,"drain stall below watchdog limits remains healthy");
        end
        check(pin_count==pin_start,"no physical AREF is emitted before returns drain");
        wr_req=0;rd_req=0;
        force dut.sdr_rd_en=1'b1;
        repeat(4) @(negedge clk);
        release dut.sdr_rd_en;
        check(dut.read_pending==0,"four delayed valid beats drain all accepted reads");
        guard=1000;
        while(!dut.manual_request && guard>0) begin
            check(refresh,"ref_vld stays high through the quiet interval");
            @(negedge clk);guard=guard-1;
        end
        check(dut.manual_request,"drained transaction permits the manual refresh request");
        wait_run;
        check(pin_count>pin_start && !refresh_error && !arb_error,"refresh completes after the pending reads drain");
        $display("REFRESH_DRAIN pending_reads=4 blocked_cycles=128 physical_commands=%0d",pin_count-pin_start);

        cases=cases+1;
        $display("CASE 4: missing core refresh handshake trips sticky watchdog");
        force dut.core_ref=1'b0;
        guard=1000;
        while(dut.refresh_state!=3 && guard>0) begin @(negedge clk);guard=guard-1;end
        check(dut.refresh_state==3 && dut.refresh_watchdog==0,"manual request enters WAIT_HI with watchdog zero");
        watchdog_cycles=0;
        repeat(1024) begin
            @(negedge clk);watchdog_cycles=watchdog_cycles+1;
            check(!refresh_error && refresh,"watchdog counts the full 1024-cycle threshold before faulting");
        end
        check(dut.refresh_watchdog==1024,"watchdog reaches the 1024-cycle threshold");
        @(negedge clk);watchdog_cycles=watchdog_cycles+1;
        check(refresh_error && refresh,"missing core_ref sets refresh_error at the watchdog threshold");
        // Complete the observed handshake; the error must survive recovery to RUN.
        force dut.core_ref=1'b1;
        repeat(2) @(negedge clk);
        force dut.core_ref=1'b0;
        repeat(2) @(negedge clk);
        release dut.core_ref;
        check(dut.refresh_state==0,"injected handshake recovery returns the state machine to RUN");
        wr_req=1;rd_req=1;
        repeat(64) begin
            @(negedge clk);
            check(refresh_error && refresh,"refresh_error and command block remain sticky after core recovery");
            check(!(app_wr_en || app_rd_en || wr_ack || rd_ack),"sticky refresh fault blocks waiting commands");
        end
        wr_req=0;rd_req=0;
        $display("REFRESH_WATCHDOG threshold_cycles=1024 fault_observed_cycles=%0d sticky_cycles=64",watchdog_cycles);

        cases=cases+1;
        $display("CASE 5: reset clears the fault and resumes physical refresh");
        rst_n=0;#1;
        check(!refresh_error && dut.read_pending==0,"reset clears refresh fault and pending reads");
        repeat(16) @(negedge clk);rst_n=1;
        wait_init;
        pin_start=pin_count;app_start=app_edges;guard=2000;
        while(pin_count-pin_start<2 && guard>0) begin
            @(negedge clk);guard=guard-1;
            check(!refresh_error && !arb_error,"refresh remains healthy after reset");
        end
        wait_run;
        check(pin_count-pin_start>=2 && app_edges-app_start>=2,"reset recovery produces new physical refresh transactions");
        check(!refresh_error,"refresh fault remains cleared after recovered transactions");
        $display("REFRESH_RESET physical_commands=%0d app_edges=%0d",pin_count-pin_start,app_edges-app_start);
        $display("SUMMARY: checks=%0d errors=%0d cases=%0d",checks,errors,cases);
        $display("ALL CHECKS PASSED: sdram_refresh_config");$finish;
    end
    initial begin #100000000;$fatal(1,"Refresh regression global timeout");end
endmodule
