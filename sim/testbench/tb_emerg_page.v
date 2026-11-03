`timescale 1ns / 1ps
// Unit testbench for emerg_page.
//
// The page is pure combinational, so the testbench simply parks active_x /
// active_y on a coordinate and compares rgb_out after a 1 ns settle delay.
// Besides the named point probes it runs one full-frame sweep that
//   1. writes a 640x480 P6 preview next to the simulation log,
//   2. counts pixels of every palette entry,
//   3. measures the bounding box of the route colour,
//   4. checks row by row that the route never leaves its two axis-aligned
//      bands - this is the structural proof that the polyline carries no
//      slope at all.
//
// Expected geometry (all ranges are half open, [lo, hi)):
//   position block  x [216,240) y [228,244)  -> 24 * 16 =   384 px cyan
//   exit A (north)  x [150,178) y [ 72, 86)  -> 28 * 14 =   392 px green
//   exit B (east)   x [559,575) y [222,250)  -> 16 * 28 =   448 px green
//   route horizontal x [162,216) y [234,238) -> 54 * 4  =   216 px amber
//   route vertical   x [162,166) y [ 86,236) -> 4  * 150 =  600 px amber
//   overlap of the two route arms             -> 4 * 2 =     8 px
//   route total                               -> 216 + 600 - 8 = 808 px amber
module tb_emerg_page;

    reg         de = 1'b1;
    reg  [10:0] active_x = 11'd0;
    reg  [9:0]  active_y = 10'd0;
    wire [23:0] rgb_out;

    integer errors = 0;
    integer checks = 0;
    integer fail   = 0;

    // Palette mirrors the localparams in the DUT; if a colour is retuned both
    // files must move together.
    localparam [23:0] C_BG    = 24'h0B_10_20;
    localparam [23:0] C_ROOM  = 24'h0F_19_27;
    localparam [23:0] C_CORR  = 24'h1B_2E_44;
    localparam [23:0] C_WALL  = 24'h46_63_82;
    localparam [23:0] C_DIV   = 24'h2A_44_60;
    localparam [23:0] C_POS   = 24'h00_C8_E0;
    localparam [23:0] C_EXIT  = 24'h3C_D8_5A;
    localparam [23:0] C_ROUTE = 24'hFF_D2_3C;

    integer x, y, fd;
    integer n_bg, n_room, n_corr, n_wall, n_div, n_pos, n_exit, n_route;
    integer route_minx, route_maxx, route_miny, route_maxy;
    integer row_min, row_max;
    integer band_bad;
    reg [23:0] pix;

    emerg_page dut (
        .de       (de),
        .active_x (active_x),
        .active_y (active_y),
        .rgb_out  (rgb_out)
    );

    task expect_rgb;
        input [10:0] tx;
        input [9:0]  ty;
        input [23:0] expected;
        input [8*80-1:0] label;
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

    task expect_count;
        input integer got;
        input integer expected;
        input [8*80-1:0] label;
        begin
            checks = checks + 1;
            if (got != expected) begin
                errors = errors + 1;
                $display("FAIL: %0s, got=%0d expected=%0d", label, got, expected);
            end else begin
                $display("PASS: %0s (%0d px)", label, got);
            end
        end
    endtask

    initial begin
        // ---------------------------------------------------------------- page
        expect_rgb(11'd10,  10'd10,  C_BG,   "page background outside the plan");
        expect_rgb(11'd320, 10'd460, C_BG,   "page background below the plan");
        expect_rgb(11'd320, 10'd40,  C_BG,   "page background above the plan");

        // --------------------------------------------------------- outer wall
        expect_rgb(11'd64,  10'd200, C_WALL, "outer wall, left edge");
        expect_rgb(11'd574, 10'd200, C_WALL, "outer wall, right edge");
        expect_rgb(11'd300, 10'd72,  C_WALL, "outer wall, top edge");
        expect_rgb(11'd300, 10'd407, C_WALL, "outer wall, bottom edge");
        expect_rgb(11'd67,  10'd200, C_WALL, "outer wall, left band is 4 px thick");
        expect_rgb(11'd571, 10'd200, C_WALL, "outer wall, right band is 4 px thick");
        expect_rgb(11'd300, 10'd75,  C_WALL, "outer wall, top band is 4 px thick");
        expect_rgb(11'd300, 10'd404, C_WALL, "outer wall, bottom band is 4 px thick");

        // ------------------------------------------------------------ interior
        expect_rgb(11'd68,  10'd200, C_ROOM, "room fill, 1 px inside the wall");
        expect_rgb(11'd100, 10'd300, C_ROOM, "room fill, lower row");
        expect_rgb(11'd128, 10'd150, C_DIV,  "partition vertical, upper row");
        expect_rgb(11'd129, 10'd150, C_DIV,  "partition vertical is 2 px wide");
        expect_rgb(11'd192, 10'd300, C_DIV,  "partition vertical, lower row");
        expect_rgb(11'd193, 10'd300, C_DIV,  "partition vertical, lower row, 2 px");
        expect_rgb(11'd130, 10'd150, C_ROOM, "no partition 1 px right of a divider");

        // ------------------------------------------------------------ corridor
        expect_rgb(11'd100, 10'd235, C_CORR, "main corridor fill");
        expect_rgb(11'd300, 10'd224, C_CORR, "main corridor, first row");
        expect_rgb(11'd300, 10'd247, C_CORR, "main corridor, last row");
        expect_rgb(11'd300, 10'd223, C_ROOM, "main corridor, 1 px above");
        expect_rgb(11'd160, 10'd150, C_CORR, "north branch corridor fill");
        expect_rgb(11'd150, 10'd150, C_ROOM, "1 px left of the branch corridor");
        expect_rgb(11'd176, 10'd150, C_ROOM, "1 px right of the branch corridor");

        // ------------------------------------------------------- position block
        expect_rgb(11'd227, 10'd235, C_POS,  "current position block centre");
        expect_rgb(11'd216, 10'd228, C_POS,  "current position, top-left corner");
        expect_rgb(11'd239, 10'd243, C_POS,  "current position, bottom-right corner");
        expect_rgb(11'd215, 10'd235, C_ROUTE, "route ends 1 px left of the position block");
        expect_rgb(11'd227, 10'd244, C_CORR,  "1 px below the position block is corridor");

        // --------------------------------------------------------------- exits
        expect_rgb(11'd160, 10'd78,  C_EXIT, "exit A marker centre");
        expect_rgb(11'd150, 10'd72,  C_EXIT, "exit A, top-left corner on the wall");
        expect_rgb(11'd177, 10'd85,  C_EXIT, "exit A, bottom-right corner");
        expect_rgb(11'd566, 10'd236, C_EXIT, "exit B marker centre");
        expect_rgb(11'd559, 10'd222, C_EXIT, "exit B, top-left corner");
        expect_rgb(11'd574, 10'd249, C_EXIT, "exit B, bottom-right corner");
        expect_rgb(11'd149, 10'd73,  C_WALL, "1 px left of exit A stays wall");
        expect_rgb(11'd178, 10'd73,  C_WALL, "1 px right of exit A stays wall");

        // --------------------------------------------------------------- route
        expect_rgb(11'd180, 10'd235, C_ROUTE, "route horizontal arm");
        expect_rgb(11'd164, 10'd150, C_ROUTE, "route vertical arm");
        expect_rgb(11'd164, 10'd235, C_ROUTE, "route right-angle corner");
        expect_rgb(11'd164, 10'd86,  C_ROUTE, "route reaches exit A");
        expect_rgb(11'd164, 10'd237, C_ROUTE, "route horizontal arm, last row");
        expect_rgb(11'd164, 10'd238, C_CORR,  "route does not bleed below its arm");
        expect_rgb(11'd161, 10'd150, C_CORR,  "1 px left of the route vertical arm");
        expect_rgb(11'd167, 10'd150, C_CORR,  "1 px right of the route vertical arm");
        expect_rgb(11'd300, 10'd200, C_ROOM,  "no diagonal: off-axis pixel stays room");

        // ------------------------------------------------------------- blanking
        de = 1'b0;
        expect_rgb(11'd227, 10'd235, 24'd0, "blanking forces black");
        expect_rgb(11'd160, 10'd78,  24'd0, "blanking forces black over an exit");
        de = 1'b1;

        // ------------------------------------------- full-frame structural sweep
        n_bg = 0; n_room = 0; n_corr = 0; n_wall = 0;
        n_div = 0; n_pos = 0; n_exit = 0; n_route = 0;
        route_minx = 9999; route_maxx = -1; route_miny = 9999; route_maxy = -1;
        band_bad = 0;

        fd = $fopen("emerg_page.ppm", "wb");
        if (fd == 0) begin
            errors = errors + 1;
            $display("FAIL: could not create emerg_page.ppm");
        end else begin
            $fwrite(fd, "P6\n640 480\n255\n");
            for (y = 0; y < 480; y = y + 1) begin
                row_min = 9999;
                row_max = -1;
                for (x = 0; x < 640; x = x + 1) begin
                    active_x = x;
                    active_y = y;
                    #1;
                    pix = rgb_out;
                    $fwrite(fd, "%c%c%c", pix[23:16], pix[15:8], pix[7:0]);
                    if (pix == C_BG)    n_bg    = n_bg + 1;
                    if (pix == C_ROOM)  n_room  = n_room + 1;
                    if (pix == C_CORR)  n_corr  = n_corr + 1;
                    if (pix == C_WALL)  n_wall  = n_wall + 1;
                    if (pix == C_DIV)   n_div   = n_div + 1;
                    if (pix == C_POS)   n_pos   = n_pos + 1;
                    if (pix == C_EXIT)  n_exit  = n_exit + 1;
                    if (pix == C_ROUTE) begin
                        n_route = n_route + 1;
                        if (x < row_min) row_min = x;
                        if (x > row_max) row_max = x;
                        if (x < route_minx) route_minx = x;
                        if (x > route_maxx) route_maxx = x;
                        if (y < route_miny) route_miny = y;
                        if (y > route_maxy) route_maxy = y;
                    end
                end
                // Axis-alignment proof, row by row. Above the corner row the
                // route may only occupy the 4 px vertical band; from the corner
                // row down it may only occupy the 4 px horizontal band.
                if (row_max >= 0) begin
                    if (y < 234) begin
                        if ((row_min < 162) || (row_max > 165)) band_bad = band_bad + 1;
                    end else begin
                        if ((row_min < 162) || (row_max > 215)) band_bad = band_bad + 1;
                    end
                end
            end
            $fclose(fd);
            checks = checks + 1;
            $display("PASS: full 640x480 page preview generated (emerg_page.ppm)");
        end

        expect_count(n_pos,   384,  "position block covers exactly 24x16 px");
        expect_count(n_exit,  840,  "two exit markers cover exactly 392 + 448 px");
        expect_count(n_route, 808,  "route covers exactly 216 + 600 - 8 px");
        checks = checks + 1;
        if (band_bad != 0) begin
            errors = errors + 1;
            $display("FAIL: route leaves its axis-aligned band on %0d row(s)", band_bad);
        end else begin
            $display("PASS: route stays inside two perpendicular 4 px bands on every row");
        end
        checks = checks + 1;
        if ((route_minx != 162) || (route_maxx != 215) ||
            (route_miny != 86)  || (route_maxy != 237)) begin
            errors = errors + 1;
            $display("FAIL: route bounding box (%0d,%0d)-(%0d,%0d) expected (162,86)-(215,237)",
                     route_minx, route_miny, route_maxx, route_maxy);
        end else begin
            $display("PASS: route bounding box (162,86)-(215,237)");
        end

        checks = checks + 1;
        if ((n_room == 0) || (n_corr == 0) || (n_wall == 0) || (n_div == 0)) begin
            errors = errors + 1;
            $display("FAIL: a structural layer is missing, room=%0d corridor=%0d wall=%0d divider=%0d",
                     n_room, n_corr, n_wall, n_div);
        end else begin
            $display("PASS: layers present, room=%0d corridor=%0d wall=%0d divider=%0d",
                     n_room, n_corr, n_wall, n_div);
        end

        checks = checks + 1;
        if ((n_room + n_corr + n_wall + n_div + n_pos + n_exit + n_route + n_bg) != 640 * 480) begin
            errors = errors + 1;
            $display("FAIL: palette does not cover the frame, sum=%0d expected=%0d",
                     n_room + n_corr + n_wall + n_div + n_pos + n_exit + n_route + n_bg,
                     640 * 480);
        end else begin
            $display("PASS: palette covers all 307200 pixels");
        end

        fail = errors;
        $display("SUMMARY: checks=%0d errors=%0d fail=%0d", checks, errors, fail);
        if (errors == 0) $display("ALL CHECKS PASSED: emerg_page");
        else $display("CHECKS FAILED: emerg_page");
        $finish;
    end

endmodule
