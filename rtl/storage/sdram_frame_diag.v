// Board-only frame-sized SDRAM diagnostic. Does not use SD, HDMI or frame FIFOs.
`timescale 1ns/1ps
module sdram_frame_bist #(
    parameter WORDS = 153600,
    parameter TIMEOUT_CYCLES = 30000000
) (
    input wire clk, rst_n, init_done, ref_vld,
    output wire app_wr_en,
    output wire [20:0] app_wr_addr,
    output wire [31:0] app_wr_din,
    output wire [3:0] app_wr_dm,
    output wire app_rd_en,
    output wire [20:0] app_rd_addr,
    input wire rd_valid,
    input wire [31:0] rd_data,
    output wire complete, passed, writing, reading,
    output reg mismatch, timed_out, all_ones, all_zeros
);
    localparam [2:0] INIT=0, WRITE=1, SETTLE=2, READ=3, DONE=4;
    reg [2:0] state;
    reg [20:0] wr_index, rd_issue, rd_return;
    reg [31:0] watchdog;
    reg [5:0] settle_count;
    reg compare_valid, compare_bad;
    function [31:0] pattern;
        input [20:0] index;
        begin pattern = 32'hA55A_5AA5 ^ {index[15:0], index[20:5]}; end
    endfunction
    assign writing = state == WRITE;
    assign reading = state == READ;
    assign app_wr_en = writing && wr_index < WORDS && !ref_vld;
    assign app_rd_en = reading && rd_issue < WORDS && !ref_vld;
    assign app_wr_addr = {wr_index[20:2], 2'b00};
    assign app_rd_addr = {rd_issue[20:2], 2'b00};
    assign app_wr_din = pattern(wr_index);
    assign app_wr_dm = 4'b0000;
    assign complete = state == DONE;
    assign passed = complete && !mismatch && !timed_out && rd_return == WORDS;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= INIT;
            wr_index <= 0;
            rd_issue <= 0;
            rd_return <= 0;
            watchdog <= 0;
            settle_count <= 0;
            mismatch <= 0;
            timed_out <= 0;
            all_ones <= 0;
            all_zeros <= 0;
            compare_valid <= 0;
            compare_bad <= 0;
        end else begin
            // Pipeline the 32-bit comparison before latching the sticky result.
            compare_valid <= reading && rd_valid && rd_return < WORDS;
            if (compare_valid && compare_bad) mismatch <= 1;
            if (reading && rd_valid) begin
                if (rd_return < WORDS) begin
                    compare_bad <= rd_data != pattern(rd_return);
                    all_ones <= (rd_return == 0 || all_ones) && rd_data == 32'hFFFFFFFF;
                    all_zeros <= (rd_return == 0 || all_zeros) && rd_data == 32'h00000000;
                    rd_return <= rd_return + 1'b1;
                end else mismatch <= 1;
            end
            if (!complete) begin
                watchdog <= watchdog + 1'b1;
                if (app_wr_en || app_rd_en || (reading && rd_valid)) watchdog <= 0;
                case (state)
                    INIT: if (init_done) begin state <= WRITE; watchdog <= 0; end
                    WRITE: if (app_wr_en) begin
                        wr_index <= wr_index + 1'b1;
                        if (wr_index == WORDS-1) begin state <= SETTLE; settle_count <= 0; end
                    end
                    SETTLE: begin
                        settle_count <= settle_count + 1'b1;
                        if (settle_count == 31) begin state <= READ; watchdog <= 0; end
                    end
                    READ: begin
                        if (app_rd_en) rd_issue <= rd_issue + 1'b1;
                        // Include the last registered comparison before reporting pass.
                        if (rd_return == WORDS && !compare_valid) state <= DONE;
                    end
                    default: state <= DONE;
                endcase
                if (watchdog >= TIMEOUT_CYCLES) begin timed_out <= 1; state <= DONE; end
            end
        end
    end
endmodule

module sdram_frame_diag_top (
    input wire clk, rst_n_btn,
    output wire [7:0] led
);
    reg [7:0] pll_delay;
    always @(posedge clk or negedge rst_n_btn) begin
        if (!rst_n_btn) pll_delay <= 0;
        else if (!pll_delay[7]) pll_delay <= pll_delay + 1'b1;
    end
    wire sdr_clk, sdr_shift, locked;
    sdram_pll u_pll (.refclk(clk), .reset(!pll_delay[7]), .extlock(locked),
        .sdram_clk(sdr_clk), .sdram_clk_sft(sdr_shift));
    wire async_reset_n = rst_n_btn && locked;
    reg [2:0] reset_pipe;
    always @(posedge sdr_clk or negedge async_reset_n) begin
        if (!async_reset_n) reset_pipe <= 0;
        else reset_pipe <= {reset_pipe[1:0], 1'b1};
    end
    wire rst_n = reset_pipe[2];
    wire init_done, ref_vld, wr_en, rd_en, rd_valid;
    wire [20:0] wr_addr, rd_addr;
    wire [31:0] wr_data, rd_data;
    wire [3:0] wr_dm;
    wire complete, passed, writing, reading, mismatch, timed_out, all_ones, all_zeros;
    sdram_frame_bist u_bist (
        .clk(sdr_clk), .rst_n(rst_n), .init_done(init_done), .ref_vld(ref_vld),
        .app_wr_en(wr_en), .app_wr_addr(wr_addr), .app_wr_din(wr_data), .app_wr_dm(wr_dm),
        .app_rd_en(rd_en), .app_rd_addr(rd_addr), .rd_valid(rd_valid), .rd_data(rd_data),
        .complete(complete), .passed(passed), .writing(writing), .reading(reading),
        .mismatch(mismatch), .timed_out(timed_out), .all_ones(all_ones), .all_zeros(all_zeros));
    wire mem_clk, cke, cs_n, ras_n, cas_n, we_n;
    wire [10:0] addr;
    wire [1:0] ba;
    wire [3:0] dm;
    wire [31:0] dq;
    sdram_ctrl_wrap u_memory (
        .clk(sdr_clk), .clk_sft(sdr_shift), .rst_n(rst_n), .init_done(init_done),
        .ref_vld(ref_vld), .busy(), .app_wr_en(wr_en), .app_wr_addr(wr_addr),
        .app_wr_din(wr_data), .app_wr_dm(wr_dm), .app_rd_en(rd_en), .app_rd_addr(rd_addr),
        .sdr_rd_en(rd_valid), .sdr_rd_dout(rd_data), .sdram_clk(mem_clk), .sdram_cke(cke),
        .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n), .sdram_we_n(we_n),
        .sdram_ba(ba), .sdram_addr(addr), .sdram_dm(dm), .sdram_dq(dq));
    EG_PHY_SDRAM_2M_32 u_sip (
        .clk(mem_clk), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .addr(addr), .ba(ba),
        .dq(dq), .cs_n(cs_n), .dm0(dm[0]), .dm1(dm[1]), .dm2(dm[2]), .dm3(dm[3]), .cke(cke));
    reg [7:0] led_reg;
    always @(posedge sdr_clk or negedge rst_n) begin
        if (!rst_n) led_reg <= 0;
        else led_reg <= {complete && all_zeros, complete && all_ones, timed_out,
                         mismatch, reading, writing, locked, passed};
    end
    assign led = led_reg;
endmodule
