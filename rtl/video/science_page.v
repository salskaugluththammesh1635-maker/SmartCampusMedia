// Built-in 640x480 FPGA and digital-logic lesson. This page is generated
// entirely in RTL, so science mode works without SD-card images or CPU code.
module science_page (
    input  wire        de,
    input  wire [10:0] active_x,
    input  wire [9:0]  active_y,
    output reg  [23:0] rgb_out
);
    reg [3:0] line_id;
    reg [3:0] cell_id;
    reg [3:0] font_x;
    reg [3:0] font_y;
    reg text_hit;
    wire [5:0] glyph;
    wire [15:0] glyph_pixels;
    wire glyph_on = glyph_pixels[4'd15 - font_x];

    function [5:0] text_glyph;
        input [3:0] line;
        input [3:0] cell_idx;
        begin
            text_glyph = 6'd0;
            case (line)
                4'd0: case (cell_idx) // 认识 FPGA
                    4'd0: text_glyph = 6'd1; 4'd1: text_glyph = 6'd2;
                    4'd2: text_glyph = 6'd37; 4'd3: text_glyph = 6'd38;
                    4'd4: text_glyph = 6'd39; 4'd5: text_glyph = 6'd40;
                    default: text_glyph = 6'd0;
                endcase
                4'd1: case (cell_idx) // 数字系统
                    4'd0: text_glyph = 6'd3; 4'd1: text_glyph = 6'd4;
                    4'd2: text_glyph = 6'd5; 4'd3: text_glyph = 6'd6;
                    default: text_glyph = 6'd0;
                endcase
                4'd2: case (cell_idx) // 逻辑并行
                    4'd0: text_glyph = 6'd7; 4'd1: text_glyph = 6'd8;
                    4'd2: text_glyph = 6'd9; 4'd3: text_glyph = 6'd10;
                    default: text_glyph = 6'd0;
                endcase
                4'd3: case (cell_idx) // 输入
                    4'd0: text_glyph = 6'd11; 4'd1: text_glyph = 6'd12;
                    default: text_glyph = 6'd0;
                endcase
                4'd4, 4'd7: case (cell_idx) // 组合逻辑
                    4'd0: text_glyph = 6'd13; 4'd1: text_glyph = 6'd14;
                    4'd2: text_glyph = 6'd7; 4'd3: text_glyph = 6'd8;
                    default: text_glyph = 6'd0;
                endcase
                4'd5: case (cell_idx) // 寄存器
                    4'd0: text_glyph = 6'd15; 4'd1: text_glyph = 6'd16;
                    4'd2: text_glyph = 6'd17;
                    default: text_glyph = 6'd0;
                endcase
                4'd6: case (cell_idx) // 输出
                    4'd0: text_glyph = 6'd11; 4'd1: text_glyph = 6'd18;
                    default: text_glyph = 6'd0;
                endcase
                4'd8: case (cell_idx) // 输入决定输出
                    4'd0: text_glyph = 6'd11; 4'd1: text_glyph = 6'd12;
                    4'd2: text_glyph = 6'd33; 4'd3: text_glyph = 6'd34;
                    4'd4: text_glyph = 6'd11; 4'd5: text_glyph = 6'd18;
                    default: text_glyph = 6'd0;
                endcase
                4'd9: case (cell_idx) // 时序逻辑
                    4'd0: text_glyph = 6'd19; 4'd1: text_glyph = 6'd20;
                    4'd2: text_glyph = 6'd7; 4'd3: text_glyph = 6'd8;
                    default: text_glyph = 6'd0;
                endcase
                4'd10: case (cell_idx) // 时钟沿保存状态
                    4'd0: text_glyph = 6'd19; 4'd1: text_glyph = 6'd21;
                    4'd2: text_glyph = 6'd22; 4'd3: text_glyph = 6'd23;
                    4'd4: text_glyph = 6'd16; 4'd5: text_glyph = 6'd24;
                    4'd6: text_glyph = 6'd25;
                    default: text_glyph = 6'd0;
                endcase
                4'd11: case (cell_idx) // 并行处理
                    4'd0: text_glyph = 6'd9; 4'd1: text_glyph = 6'd10;
                    4'd2: text_glyph = 6'd35; 4'd3: text_glyph = 6'd36;
                    default: text_glyph = 6'd0;
                endcase
                4'd12: case (cell_idx) // 多个单元
                    4'd0: text_glyph = 6'd26; 4'd1: text_glyph = 6'd27;
                    4'd2: text_glyph = 6'd28; 4'd3: text_glyph = 6'd29;
                    default: text_glyph = 6'd0;
                endcase
                4'd13: case (cell_idx) // 同时计算
                    4'd0: text_glyph = 6'd30; 4'd1: text_glyph = 6'd19;
                    4'd2: text_glyph = 6'd31; 4'd3: text_glyph = 6'd32;
                    default: text_glyph = 6'd0;
                endcase
                default: text_glyph = 6'd0;
            endcase
        end
    endfunction

    // Title, subtitle, four-stage data path, and three lesson cards.
    always @* begin
        text_hit = 1'b0;
        line_id = 4'd0;
        cell_id = 4'd0;
        font_x = 4'd0;
        font_y = 4'd0;
        if ((active_x >= 11'd48) && (active_x < 11'd240) &&
            (active_y >= 10'd32) && (active_y < 10'd64)) begin
            text_hit = 1'b1; line_id = 4'd0;
            cell_id = (active_x - 11'd48) >> 5;
            font_x = ((active_x - 11'd48) >> 1) & 4'hF;
            font_y = (active_y - 10'd32) >> 1;
        end else if ((active_y >= 10'd76) && (active_y < 10'd92) &&
                     (active_x >= 11'd64) && (active_x < 11'd128)) begin
            text_hit = 1'b1; line_id = 4'd1;
            cell_id = (active_x - 11'd64) >> 4;
            font_x = (active_x - 11'd64) & 4'hF;
            font_y = active_y - 10'd76;
        end else if ((active_y >= 10'd76) && (active_y < 10'd92) &&
                     (active_x >= 11'd148) && (active_x < 11'd212)) begin
            text_hit = 1'b1; line_id = 4'd2;
            cell_id = (active_x - 11'd148) >> 4;
            font_x = (active_x - 11'd148) & 4'hF;
            font_y = active_y - 10'd76;
        end else if ((active_y >= 10'd184) && (active_y < 10'd200)) begin
            font_y = active_y - 10'd184;
            if ((active_x >= 11'd84) && (active_x < 11'd116)) begin
                text_hit = 1'b1; line_id = 4'd3;
                cell_id = (active_x - 11'd84) >> 4;
                font_x = (active_x - 11'd84) & 4'hF;
            end else if ((active_x >= 11'd214) && (active_x < 11'd278)) begin
                text_hit = 1'b1; line_id = 4'd4;
                cell_id = (active_x - 11'd214) >> 4;
                font_x = (active_x - 11'd214) & 4'hF;
            end else if ((active_x >= 11'd375) && (active_x < 11'd423)) begin
                text_hit = 1'b1; line_id = 4'd5;
                cell_id = (active_x - 11'd375) >> 4;
                font_x = (active_x - 11'd375) & 4'hF;
            end else if ((active_x >= 11'd518) && (active_x < 11'd550)) begin
                text_hit = 1'b1; line_id = 4'd6;
                cell_id = (active_x - 11'd518) >> 4;
                font_x = (active_x - 11'd518) & 4'hF;
            end
        end else if ((active_y >= 10'd320) && (active_y < 10'd336)) begin
            font_y = active_y - 10'd320;
            if ((active_x >= 11'd46) && (active_x < 11'd110)) begin
                text_hit = 1'b1; line_id = 4'd7;
                cell_id = (active_x - 11'd46) >> 4;
                font_x = (active_x - 11'd46) & 4'hF;
            end else if ((active_x >= 11'd246) && (active_x < 11'd310)) begin
                text_hit = 1'b1; line_id = 4'd9;
                cell_id = (active_x - 11'd246) >> 4;
                font_x = (active_x - 11'd246) & 4'hF;
            end else if ((active_x >= 11'd446) && (active_x < 11'd510)) begin
                text_hit = 1'b1; line_id = 4'd11;
                cell_id = (active_x - 11'd446) >> 4;
                font_x = (active_x - 11'd446) & 4'hF;
            end
        end else if ((active_y >= 10'd350) && (active_y < 10'd366)) begin
            font_y = active_y - 10'd350;
            if ((active_x >= 11'd46) && (active_x < 11'd142)) begin
                text_hit = 1'b1; line_id = 4'd8;
                cell_id = (active_x - 11'd46) >> 4;
                font_x = (active_x - 11'd46) & 4'hF;
            end else if ((active_x >= 11'd246) && (active_x < 11'd358)) begin
                text_hit = 1'b1; line_id = 4'd10;
                cell_id = (active_x - 11'd246) >> 4;
                font_x = (active_x - 11'd246) & 4'hF;
            end else if ((active_x >= 11'd446) && (active_x < 11'd510)) begin
                text_hit = 1'b1; line_id = 4'd12;
                cell_id = (active_x - 11'd446) >> 4;
                font_x = (active_x - 11'd446) & 4'hF;
            end
        end else if ((active_y >= 10'd374) && (active_y < 10'd390) &&
                     (active_x >= 11'd446) && (active_x < 11'd510)) begin
            text_hit = 1'b1; line_id = 4'd13;
            cell_id = (active_x - 11'd446) >> 4;
            font_x = (active_x - 11'd446) & 4'hF;
            font_y = active_y - 10'd374;
        end
    end

    assign glyph = text_glyph(line_id, cell_id);
    science_font16 u_font (.glyph(glyph), .row(font_y), .pixels(glyph_pixels));

    wire header = (active_x >= 11'd24) && (active_x < 11'd616) &&
                  (active_y >= 10'd20) && (active_y < 10'd104);
    wire flow_panel = (active_x >= 11'd24) && (active_x < 11'd616) &&
                      (active_y >= 10'd126) && (active_y < 10'd274);
    wire box0 = (active_x >= 11'd48) && (active_x < 11'd164) &&
                (active_y >= 10'd154) && (active_y < 10'd230);
    wire box1 = (active_x >= 11'd190) && (active_x < 11'd302) &&
                (active_y >= 10'd154) && (active_y < 10'd230);
    wire box2 = (active_x >= 11'd332) && (active_x < 11'd444) &&
                (active_y >= 10'd154) && (active_y < 10'd230);
    wire box3 = (active_x >= 11'd474) && (active_x < 11'd590) &&
                (active_y >= 10'd154) && (active_y < 10'd230);
    wire box_border =
        (box0 && ((active_x == 11'd48) || (active_x == 11'd163) ||
                  (active_y == 10'd154) || (active_y == 10'd229))) ||
        (box1 && ((active_x == 11'd190) || (active_x == 11'd301) ||
                  (active_y == 10'd154) || (active_y == 10'd229))) ||
        (box2 && ((active_x == 11'd332) || (active_x == 11'd443) ||
                  (active_y == 10'd154) || (active_y == 10'd229))) ||
        (box3 && ((active_x == 11'd474) || (active_x == 11'd589) ||
                  (active_y == 10'd154) || (active_y == 10'd229)));
    wire arrow = (active_y >= 10'd190) && (active_y <= 10'd192) &&
        (((active_x >= 11'd166) && (active_x <= 11'd186)) ||
         ((active_x >= 11'd308) && (active_x <= 11'd328)) ||
         ((active_x >= 11'd450) && (active_x <= 11'd470)));
    wire cards = (active_x >= 11'd24) && (active_x < 11'd616) &&
                 (active_y >= 10'd300) && (active_y < 10'd452);
    wire card0 = (active_x >= 11'd24) && (active_x < 11'd216);
    wire card1 = (active_x >= 11'd224) && (active_x < 11'd416);
    wire card2 = (active_x >= 11'd424) && (active_x < 11'd616);
    wire card_border = cards &&
        ((active_x == 11'd24) || (active_x == 11'd215) ||
         (active_x == 11'd224) || (active_x == 11'd415) ||
         (active_x == 11'd424) || (active_x == 11'd615) ||
         (active_y == 10'd300) || (active_y == 10'd451));
    wire card_top = (active_y >= 10'd300) && (active_y < 10'd304) &&
                    (card0 || card1 || card2);
    wire logic_shape =
        (((active_y == 10'd412) || (active_y == 10'd428)) &&
         (active_x >= 11'd46) && (active_x <= 11'd78)) ||
        (((active_x >= 11'd78) && (active_x <= 11'd112) &&
          (active_y >= 10'd404) && (active_y <= 10'd436)) &&
         ((active_x == 11'd78) || (active_x == 11'd111) ||
          (active_y == 10'd404) || (active_y == 10'd435))) ||
        ((active_y >= 10'd418) && (active_y <= 10'd420) &&
         (active_x >= 11'd112) && (active_x <= 11'd166));
    wire register_shape =
        ((active_y >= 10'd407) && (active_y <= 10'd437) &&
         (active_x >= 11'd278) && (active_x <= 11'd358) &&
         ((active_x == 11'd278) || (active_x == 11'd357) ||
          (active_y == 10'd407) || (active_y == 10'd437))) ||
        ((active_y >= 10'd418) && (active_y <= 10'd420) &&
         ((active_x >= 11'd258) && (active_x <= 11'd278) ||
          (active_x >= 11'd358) && (active_x <= 11'd385)));
    wire parallel_shape =
        (((active_y == 10'd408) || (active_y == 10'd422) ||
          (active_y == 10'd436)) &&
         (active_x >= 11'd446) && (active_x <= 11'd588)) ||
        (((active_x == 11'd466) || (active_x == 11'd506) ||
          (active_x == 11'd546)) &&
         ((active_y == 10'd406) || (active_y == 10'd407) ||
          (active_y == 10'd408) || (active_y == 10'd422) ||
          (active_y == 10'd436)));

    always @* begin
        rgb_out = 24'h07_12_26;
        if (!de) begin
            rgb_out = 24'd0;
        end else begin
            if (header) rgb_out = 24'h10_24_3C;
            if ((active_x >= 11'd24) && (active_x < 11'd30) &&
                (active_y >= 10'd20) && (active_y < 10'd104))
                rgb_out = 24'h00_C8_E0;
            if (flow_panel) rgb_out = 24'h0C_1E_34;
            if (box0 || box1 || box2 || box3) rgb_out = 24'h13_30_4D;
            if (box_border || arrow) rgb_out = 24'h52_CE_F2;
            if (cards) rgb_out = 24'h10_22_39;
            if (card_border) rgb_out = 24'h2B_49_65;
            if (card_top) begin
                if (card0) rgb_out = 24'h00_C8_E0;
                else if (card1) rgb_out = 24'h54_A8_FF;
                else rgb_out = 24'hA7_91_FF;
            end
            if (logic_shape || register_shape || parallel_shape)
                rgb_out = 24'h52_CE_F2;
            if (text_hit && (glyph != 6'd0) && glyph_on) begin
                if (line_id == 4'd0) rgb_out = 24'hF4_F7_FF;
                else rgb_out = 24'hC6_D6_EA;
            end
            if (active_y >= 10'd466) rgb_out = 24'h04_0C_18;
        end
    end
endmodule
