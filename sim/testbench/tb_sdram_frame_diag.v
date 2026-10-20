`timescale 1ns/1ps
module tb_sdram_frame_diag;
    reg clk = 0;
    always #3.333 clk = ~clk;
    reg rst_n = 0;
    reg [1:0] inject = 0;
    wire init_done, ref_vld, wr_en, rd_en, rd_valid;
    wire [20:0] wr_addr, rd_addr;
    wire [31:0] wr_data, rd_data;
    wire [3:0] wr_dm;
    wire complete, passed, writing, reading, mismatch, timed_out, all_ones, all_zeros;
    wire sampled_valid = rd_valid && inject != 3;
    wire [31:0] sampled_data = inject == 1 ? 32'hFFFFFFFF :
                              inject == 2 ? 32'h00000000 : rd_data;
    sdram_frame_bist #(.WORDS(153600), .TIMEOUT_CYCLES(4096)) dut (
        .clk(clk), .rst_n(rst_n), .init_done(init_done), .ref_vld(ref_vld),
        .app_wr_en(wr_en), .app_wr_addr(wr_addr), .app_wr_din(wr_data), .app_wr_dm(wr_dm),
        .app_rd_en(rd_en), .app_rd_addr(rd_addr), .rd_valid(sampled_valid), .rd_data(sampled_data),
        .complete(complete), .passed(passed), .writing(writing), .reading(reading),
        .mismatch(mismatch), .timed_out(timed_out), .all_ones(all_ones), .all_zeros(all_zeros));
    sdram_behavior_model #(.SIM_MEM_WORDS(262144), .REFRESH_PERIOD(79), .REF_VLD_CYCLES(8)) memory (
        .clk(clk), .rst_n(rst_n), .init_done(init_done), .ref_vld(ref_vld),
        .app_wr_en(wr_en), .app_wr_addr(wr_addr), .app_wr_din(wr_data), .app_wr_dm(wr_dm),
        .app_rd_en(rd_en), .app_rd_addr(rd_addr), .sdr_rd_en(rd_valid), .sdr_rd_dout(rd_data));
    integer errors = 0, checks = 0, guard, case_id;
    task check;
        input condition;
        input [511:0] message;
        begin
            checks = checks + 1;
            if (condition) $display("PASS: %0s", message);
            else begin errors = errors + 1; $display("FAIL: %0s", message); end
        end
    endtask
    initial begin
        for (case_id = 0; case_id < 4; case_id = case_id + 1) begin
            @(negedge clk);
            rst_n = 0;
            inject = case_id;
            repeat (5) @(negedge clk);
            rst_n = 1;
            guard = 0;
            while (!complete && guard < 1000000) begin
                @(negedge clk);
                guard = guard + 1;
            end
            repeat (3) @(negedge clk);
            check(complete, "frame test reaches a bounded terminal state");
            if (case_id == 0) begin
                check(passed && !mismatch && !timed_out, "all 153600 words compare correctly across refresh");
                check(dut.wr_index == 153600 && dut.rd_issue == 153600 && dut.rd_return == 153600,
                      "full frame issued and returned with exact counts");
                check(!all_ones && !all_zeros, "valid data is not classified as a constant bus");
            end else if (case_id == 1) begin
                check(!passed && mismatch && all_ones && !all_zeros && !timed_out,
                      "all-white readback is detected as data mismatch / all ones");
            end else if (case_id == 2) begin
                check(!passed && mismatch && all_zeros && !all_ones && !timed_out,
                      "all-zero readback is detected as data mismatch / all zeros");
            end else begin
                check(!passed && timed_out && !all_ones && !all_zeros,
                      "missing read-valid terminates with timeout");
            end
        end
        $display("SUMMARY: checks=%0d errors=%0d cases=4", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: sdram_frame_diag");
        else $fatal(1, "SDRAM diagnostic checker failed");
        $finish;
    end
endmodule
