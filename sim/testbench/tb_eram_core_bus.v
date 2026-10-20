// Real APUG011 encrypted controller plus vendor SDRAM pin model.
// MODE 0=continuous, 1=sparse reverse groups, 2=sparse forward groups,
// MODE 3=continuous reverse groups, 4=continuous writes / sparse reads.
`timescale 1ns/1ps
module tb_eram_core_bus #(parameter MODE=0, WORDS=128);
    reg clk=0, rst_n=0;
    always #3.333 clk=~clk;
    reg wr_en=0, rd_en=0;
    reg [20:0] wr_addr=0, rd_addr=0;
    reg [31:0] wr_data=0;
    wire init_done, refresh, rd_valid;
    wire [31:0] rd_data;
    wire mem_clk, cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba;
    wire [10:0] addr;
    wire [3:0] dm;
    wire [31:0] dq;
    sdram_ctrl_wrap dut (
        .clk(clk), .clk_sft(~clk), .rst_n(rst_n), .init_done(init_done), .ref_vld(refresh), .busy(),
        .app_wr_en(wr_en), .app_wr_addr(wr_addr), .app_wr_din(wr_data), .app_wr_dm(4'b0000),
        .app_rd_en(rd_en), .app_rd_addr(rd_addr), .sdr_rd_en(rd_valid), .sdr_rd_dout(rd_data),
        .sdram_clk(mem_clk), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n),
        .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_ba(ba), .sdram_addr(addr), .sdram_dm(dm), .sdram_dq(dq));
    // Functional pin model only: the shipped -7 model's tAC=5.5ns does not
    // describe this SiP interface. Physical timing remains a separate failing gate.
    IS42s32200 #(.mem_sizes(4095), .tAC(1.0), .tHZ(1.0), .tOH(0.5),
        .tRAS(0.0), .tRC(0.0), .tRCD(0.0), .tRP(0.0), .tRRD(0.0), .tDPL(0.0)) memory (
        .Dq(dq), .Addr(addr), .Ba(ba), .Clk(mem_clk), .Cke(cke), .Cs_n(cs_n),
        .Ras_n(ras_n), .Cas_n(cas_n), .We_n(we_n), .Dqm(dm));
    function [31:0] pattern;
        input integer index;
        begin pattern=(index >= WORDS/4 && index < WORDS/2) ? 32'hf800f800 : 32'hffffffff; end
    endfunction
    integer returned=0, errors=0, red_words=0, white_words=0, refresh_seen=0;
    always @(posedge clk) begin
        if (rst_n && refresh) refresh_seen=refresh_seen+1;
        if (rst_n && rd_valid) begin
            if (rd_data === 32'hf800f800) red_words=red_words+1;
            if (rd_data === 32'hffffffff) white_words=white_words+1;
            if (rd_data !== pattern(returned)) begin
                if(errors<6) $display("MISMATCH mode=%0d index=%0d got=%h expected=%h",MODE,returned,rd_data,pattern(returned));
                errors=errors+1;
            end
            returned=returned+1;
        end
    end
    integer group_no, beat, base, guard;
    initial begin
        repeat(16) @(negedge clk); rst_n=1;
        guard=0;
        while(!init_done && guard<200000) begin @(negedge clk); guard=guard+1; end
        if(!init_done) $fatal(1,"SDRAM initialization timeout");
        for(group_no=0; group_no<WORDS/4; group_no=group_no+1) begin
            base=(MODE==1 || MODE==3) ? WORDS-4-group_no*4 : group_no*4;
            for(beat=0; beat<4; beat=beat+1) begin
                while(refresh) begin wr_en=0; @(negedge clk); end
                wr_en=1; wr_addr=base; wr_data=pattern(base+beat);
                @(negedge clk);
            end
            if(MODE==1 || MODE==2) begin wr_en=0; repeat(1000) @(negedge clk); end
        end
        wr_en=0; repeat(64) @(negedge clk);
        for(group_no=0; group_no<WORDS/4; group_no=group_no+1) begin
            for(beat=0; beat<4; beat=beat+1) begin
                while(refresh) begin rd_en=0; @(negedge clk); end
                rd_en=1; rd_addr=group_no*4;
                @(negedge clk);
            end
            if(MODE==4) begin rd_en=0; repeat(30) @(negedge clk); end
        end
        rd_en=0; guard=0;
        while(returned<WORDS && guard<10000) begin @(negedge clk); guard=guard+1; end
        repeat(32) @(negedge clk);
        $display("ERAM_RESULT mode=%0d returned=%0d errors=%0d red=%0d white=%0d refresh_clocks=%0d",
                 MODE,returned,errors,red_words,white_words,refresh_seen);
        if(returned!=WORDS || errors!=0) $fatal(1,"Real-core image-pattern readback failed");
        $display("ALL CHECKS PASSED: eram_core_bus"); $finish;
    end
    initial begin #2000000; $fatal(1,"Real-core simulation timeout"); end
endmodule
