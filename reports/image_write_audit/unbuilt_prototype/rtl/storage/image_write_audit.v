// Diagnostic only. Audit accepted image writes against the known bottom-up BMP
// (white with a central red rectangle), without changing any memory command.
`timescale 1ns/1ps
module image_write_audit #(
    parameter WIDTH=640, HEIGHT=480,
    parameter RED_X0=220, RED_X1=420, RED_Y0=140, RED_Y1=340
) (
    input wire clk, rst_n, writes_complete, write_valid,
    input wire [20:0] write_addr,
    input wire [31:0] write_data,
    input wire [3:0] write_dm,
    output wire [3:0] status
);
    localparam WORDS=WIDTH*HEIGHT/2, LINE=WIDTH/2;
    reg [17:0] count;
    reg [20:0] expected_addr;
    reg [9:0] word_x, row_y;
    reg sampled_valid, sampled_red;
    reg [20:0] sampled_addr, sampled_expected_addr;
    reg [31:0] sampled_data;
    reg [3:0] sampled_dm;
    reg address_bad, data_bad, protocol_bad, complete;
    assign status={protocol_bad, data_bad, address_bad, complete};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            count<=0; expected_addr<=(HEIGHT-1)*LINE; word_x<=0; row_y<=HEIGHT-1;
            sampled_valid<=0; sampled_red<=0; sampled_addr<=0; sampled_expected_addr<=0;
            sampled_data<=0; sampled_dm<=0; address_bad<=0; data_bad<=0; protocol_bad<=0; complete<=0;
        end else begin
            // Sample both sides first so wide comparisons cannot extend the
            // application's write command path at 150MHz.
            sampled_valid<=write_valid;
            if(write_valid) begin
                sampled_addr<=write_addr;
                sampled_expected_addr<={expected_addr[20:2],2'b00};
                sampled_data<=write_data; sampled_dm<=write_dm;
                sampled_red<=word_x>=RED_X0/2 && word_x<RED_X1/2 && row_y>=RED_Y0 && row_y<RED_Y1;
                if(count<WORDS) count<=count+1'b1;
                else protocol_bad<=1;
                if(word_x==LINE-1) begin
                    word_x<=0; row_y<=row_y-1'b1;
                    expected_addr<=expected_addr-(2*LINE-1);
                end else begin word_x<=word_x+1'b1; expected_addr<=expected_addr+1'b1; end
            end
            if(sampled_valid) begin
                if(sampled_addr!=sampled_expected_addr) address_bad<=1;
                if(sampled_data!=(sampled_red ? 32'hf800f800 : 32'hffffffff)) data_bad<=1;
                if(sampled_dm!=0) protocol_bad<=1;
            end
            // Commit is at least 15 clocks after the last application write.
            // Also wait for our own comparison stage before publishing status.
            if(writes_complete && !sampled_valid && !write_valid) begin
                complete<=1;
                if(count!=WORDS) protocol_bad<=1;
            end
        end
    end
endmodule
