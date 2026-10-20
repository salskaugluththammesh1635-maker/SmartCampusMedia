// Diagnostic only: continuously read the loaded white / central-red image before
// releasing the display reader. This never writes memory or changes its contents.
`timescale 1ns/1ps
module image_readback_diag #(
    parameter WIDTH=640, HEIGHT=480,
    parameter RED_X0=220, RED_X1=420, RED_Y0=140, RED_Y1=340,
    parameter TIMEOUT_CYCLES=2000000
) (
    input wire clk, rst_n, writes_complete, ref_vld,
    output wire active, app_rd_en,
    output wire [20:0] app_rd_addr,
    input wire rd_valid,
    input wire [31:0] rd_data,
    output wire done,
    output reg mismatch, timed_out, red_seen
);
    localparam WORDS=WIDTH*HEIGHT/2, LINE_WORDS=WIDTH/2;
    localparam [1:0] WAIT_WR=0, SCAN=1, SETTLE=2, DONE=3;
    reg [1:0] state;
    reg [20:0] issued, returned;
    reg [9:0] word_x, row_y;
    reg [31:0] watchdog;
    reg [5:0] settle_count;
    reg sampled_valid, expected_red;
    reg [31:0] sampled_data;
    wire current_red = word_x >= RED_X0/2 && word_x < RED_X1/2 &&
                       row_y >= RED_Y0 && row_y < RED_Y1;
    assign active = state != DONE;
    assign done = state == DONE;
    assign app_rd_en = state == SCAN && issued < WORDS && !ref_vld;
    assign app_rd_addr = {issued[20:2],2'b00};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=WAIT_WR; issued<=0; returned<=0; word_x<=0; row_y<=0;
            watchdog<=0; settle_count<=0; sampled_valid<=0; expected_red<=0;
            sampled_data<=0; mismatch<=0; timed_out<=0; red_seen<=0;
        end else begin
            sampled_valid <= state == SCAN && rd_valid;
            if(state == SCAN && rd_valid) begin
                sampled_data<=rd_data; expected_red<=current_red;
                returned<=returned+1'b1;
                if(word_x == LINE_WORDS-1) begin word_x<=0; row_y<=row_y+1'b1; end
                else word_x<=word_x+1'b1;
                if(returned >= WORDS) mismatch<=1;
            end
            if(sampled_valid) begin
                if(sampled_data != (expected_red ? 32'hf800f800 : 32'hffffffff)) mismatch<=1;
                if(sampled_data[15:0] == 16'hf800 || sampled_data[31:16] == 16'hf800) red_seen<=1;
            end
            case(state)
                WAIT_WR: if(writes_complete) begin state<=SCAN; watchdog<=0; end
                SCAN: begin
                    watchdog<=watchdog+1'b1;
                    if(app_rd_en) issued<=issued+1'b1;
                    if(rd_valid) watchdog<=0;
                    if(returned == WORDS && !sampled_valid) begin state<=SETTLE; settle_count<=0; end
                    if(watchdog >= TIMEOUT_CYCLES) begin timed_out<=1; state<=SETTLE; settle_count<=0; end
                end
                SETTLE: begin
                    if(rd_valid) mismatch<=1;
                    if(settle_count == 31) state<=DONE;
                    else settle_count<=settle_count+1'b1;
                end
                default: state<=DONE;
            endcase
        end
    end
endmodule
