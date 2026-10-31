`timescale 1ns / 1ps
module tb_science_page;
    reg de = 1'b1;
    reg [10:0] active_x = 11'd0;
    reg [9:0] active_y = 10'd0;
    wire [23:0] rgb_out;
    integer errors = 0;
    integer checks = 0;
    integer title_pixels = 0;
    integer lesson_pixels = 0;
    integer x, y, fd;

    science_page dut (.de(de), .active_x(active_x), .active_y(active_y), .rgb_out(rgb_out));

    task expect_rgb;
        input [10:0] tx;
        input [9:0] ty;
        input [23:0] expected;
        input [8*100-1:0] label;
        begin
            active_x = tx;
            active_y = ty;
            #1;
            checks = checks + 1;
            if (rgb_out !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s at (%0d,%0d), got=%06h expected=%06h",
                         label, tx, ty, rgb_out, expected);
            end else begin
                $display("PASS: %0s", label);
            end
        end
    endtask

    initial begin
        expect_rgb(11'd0, 10'd120, 24'h07_12_26, "science page background");
        expect_rgb(11'd25, 10'd22, 24'h00_C8_E0, "science page header accent");
        expect_rgb(11'd50, 10'd160, 24'h13_30_4D, "data-path input block");
        expect_rgb(11'd170, 10'd191, 24'h52_CE_F2, "data-path arrow");
        expect_rgb(11'd25, 10'd302, 24'h00_C8_E0, "combinational lesson card");
        expect_rgb(11'd225, 10'd302, 24'h54_A8_FF, "sequential lesson card");
        expect_rgb(11'd425, 10'd302, 24'hA7_91_FF, "parallel-processing lesson card");

        for (y = 32; y < 64; y = y + 1)
            for (x = 48; x < 240; x = x + 1) begin
                active_x = x;
                active_y = y;
                #1;
                if (rgb_out == 24'hF4_F7_FF) title_pixels = title_pixels + 1;
            end
        checks = checks + 1;
        if (title_pixels < 200) begin
            errors = errors + 1;
            $display("FAIL: Chinese/FPGA title glyphs missing, pixels=%0d", title_pixels);
        end else begin
            $display("PASS: title glyph pixels=%0d", title_pixels);
        end

        for (y = 320; y < 390; y = y + 1)
            for (x = 46; x < 560; x = x + 1) begin
                active_x = x;
                active_y = y;
                #1;
                if (rgb_out == 24'hC6_D6_EA) lesson_pixels = lesson_pixels + 1;
            end
        checks = checks + 1;
        if (lesson_pixels < 500) begin
            errors = errors + 1;
            $display("FAIL: lesson text glyphs missing, pixels=%0d", lesson_pixels);
        end else begin
            $display("PASS: lesson text pixels=%0d", lesson_pixels);
        end

        // Save a full-frame preview along with the simulation for visual review.
        fd = $fopen("science_page.ppm", "wb");
        if (fd == 0) begin
            errors = errors + 1;
            $display("FAIL: could not create science_page.ppm");
        end else begin
            $fwrite(fd, "P6\n640 480\n255\n");
            for (y = 0; y < 480; y = y + 1)
                for (x = 0; x < 640; x = x + 1) begin
                    active_x = x;
                    active_y = y;
                    #1;
                    $fwrite(fd, "%c%c%c", rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
                end
            $fclose(fd);
            checks = checks + 1;
            $display("PASS: full 640x480 page preview generated");
        end

        de = 1'b0;
        expect_rgb(11'd320, 10'd200, 24'd0, "blanking forces black");
        $display("SUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: science_page");
        else $display("CHECKS FAILED: science_page");
        $finish;
    end
endmodule
