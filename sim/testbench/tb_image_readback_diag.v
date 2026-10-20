// Check the readback checker at its actual SDRAM command / return boundary.
`timescale 1ns/1ps
module tb_image_readback_diag;
    localparam WORDS=64;
    reg clk=0, rst_n=0, committed=0;
    always #3.333 clk=~clk;
    wire init_done, refresh, issue, valid, active, done, bad, timeout, red;
    wire [20:0] address;
    wire [31:0] data;
    reg [1:0] injection=0;
    integer returned=0, errors=0, checks=0, index, guard;
    wire [31:0] checked_data = injection==1 ? 32'hffffffff :
        ((injection==2 && returned==WORDS-1) ? 32'h00000000 : data);
    image_readback_diag #(.WIDTH(16), .HEIGHT(8),
        .RED_X0(4), .RED_X1(12), .RED_Y0(2), .RED_Y1(6), .TIMEOUT_CYCLES(128)) dut (
        .clk(clk), .rst_n(rst_n), .writes_complete(committed), .ref_vld(refresh),
        .active(active), .app_rd_en(issue), .app_rd_addr(address),
        .rd_valid(valid && injection!=3), .rd_data(checked_data), .done(done),
        .mismatch(bad), .timed_out(timeout), .red_seen(red));
    sdram_behavior_model #(.SIM_MEM_WORDS(128), .INIT_CYCLES(8), .REFRESH_PERIOD(37)) memory (
        .clk(clk), .rst_n(rst_n), .init_done(init_done), .ref_vld(refresh),
        .app_wr_en(1'b0), .app_wr_addr(21'd0), .app_wr_din(32'd0), .app_wr_dm(4'd0),
        .app_rd_en(issue), .app_rd_addr(address), .sdr_rd_en(valid), .sdr_rd_dout(data));
    always @(posedge clk) begin
        if(!rst_n) returned<=0;
        else if(valid) returned<=returned+1;
    end
    task check;
        input condition; input [8*100-1:0] message;
        begin
            checks=checks+1;
            if(condition!==1'b1) begin errors=errors+1; $display("FAIL: %0s",message); end
        end
    endtask
    task run_case;
        input [1:0] kind;
        begin
            @(negedge clk); rst_n=0; committed=0; injection=kind;
            for(index=0; index<WORDS; index=index+1)
                memory.mem[index]=((index/8)>=2 && (index/8)<6 && (index%8)>=2 && (index%8)<6) ?
                    32'hf800f800 : 32'hffffffff;
            repeat(4) @(negedge clk); rst_n=1;
            wait(init_done); repeat(3) @(negedge clk);
            check(!done && !issue,"checker does not read before the writes are committed");
            committed=1; guard=0;
            while(!done && guard<1000) begin @(negedge clk); guard=guard+1; end
            check(done && !active,"readback reaches bounded terminal and releases memory");
            case(kind)
                0: check(!bad && !timeout && red,"correct frame across refresh passes comparison");
                1: check(bad && !timeout && !red,"all-white readback fails with no red observed");
                2: check(bad && !timeout && red,"a mismatch in the final word is included");
                3: check(timeout && !red,"missing return-valid produces timeout without a false red flag");
            endcase
        end
    endtask
    initial begin
        run_case(0); run_case(1); run_case(2); run_case(3);
        $display("SUMMARY: checks=%0d errors=%0d",checks,errors);
        if(errors==0) $display("ALL CHECKS PASSED: image_readback_unit");
        else $fatal(1,"Readback checker failed");
        $finish;
    end
endmodule
