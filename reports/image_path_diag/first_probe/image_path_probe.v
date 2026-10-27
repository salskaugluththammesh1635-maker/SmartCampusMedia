// Temporary white-frame diagnostic. Observes data without controlling the path.
// Each nibble: bit0=data seen, bit1=RGB565 F800 seen, bit2=nonwhite seen.
// Nibbles from left to right: BMP decode, SDRAM write, SDRAM return, pixel output.
`timescale 1ns/1ps
module image_path_probe (
    input wire pix_clk, rst_n_pix, sdr_clk, rst_n_sdr,
    input wire decode_valid,
    input wire [15:0] decode_pixel,
    input wire write_valid,
    input wire [31:0] write_data,
    input wire read_valid,
    input wire [31:0] read_data,
    input wire pixel_valid,
    input wire [15:0] pixel_data,
    output wire [15:0] stages
);
    function [3:0] pixel_flags;
        input [15:0] value;
        begin pixel_flags = {1'b0, value != 16'hffff, value == 16'hf800, 1'b1}; end
    endfunction
    reg [3:0] decode_seen, write_seen, read_seen, pixel_seen;
    reg [7:0] memory_meta, memory_sync;
    always @(posedge sdr_clk or negedge rst_n_sdr) begin
        if (!rst_n_sdr) begin write_seen <= 0; read_seen <= 0; end
        else begin
            if (write_valid)
                write_seen <= write_seen | pixel_flags(write_data[15:0]) | pixel_flags(write_data[31:16]);
            if (read_valid)
                read_seen <= read_seen | pixel_flags(read_data[15:0]) | pixel_flags(read_data[31:16]);
        end
    end
    // Only sticky flags cross domains. Resets follow the common storage-path reset.
    always @(posedge pix_clk or negedge rst_n_pix) begin
        if (!rst_n_pix) begin
            decode_seen <= 0; pixel_seen <= 0;
            memory_meta <= 0; memory_sync <= 0;
        end else begin
            memory_meta <= {write_seen, read_seen};
            memory_sync <= memory_meta;
            if (decode_valid) decode_seen <= decode_seen | pixel_flags(decode_pixel);
            if (pixel_valid) pixel_seen <= pixel_seen | pixel_flags(pixel_data);
        end
    end
    assign stages = {decode_seen, memory_sync, pixel_seen};
endmodule
