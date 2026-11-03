// -----------------------------------------------------------------------------
// emerg_page - emergency-mode floor-plan page for the 640x480 RGB stream.
//
// The page is rasterized in real time inside the FPGA: every pixel is derived
// from its own (active_x, active_y) coordinate by plain combinational compares.
// No image data path is involved, so the plan is still displayed when the
// SD card is absent, unreadable, or not formatted. Character text is not drawn
// here - it is supplied by the existing OSD caption layer, which keeps this
// module free of any read-only character table: zero BRAM, zero DSP, zero
// timing element, zero state machine.
//
// Content (single floor, P0 set):
//   * outer wall frame, 4 px thick
//   * one horizontal main corridor plus one north branch corridor
//   * room partitions: 2 px verticals, different pitch above and below
//   * current position: solid cyan block inside the main corridor
//   * two exits: solid bright-green blocks sitting in the wall openings
//   * route to the nearest exit: right-angled polyline, horizontal first and
//     then vertical. It is strictly axis-aligned by construction - no slope is
//     ever evaluated, so no multiplier and therefore no DSP is inferred.
//
// Port list is intentionally the same four ports as science_page.v so the
// content mux can swap the two pages with a plain 2:1 selection.
// -----------------------------------------------------------------------------
module emerg_page (
    input  wire        de,
    input  wire [10:0] active_x,
    input  wire [9:0]  active_y,
    output reg  [23:0] rgb_out
);

    // ---------------------------------------------------------------- palette
    localparam [23:0] C_BG    = 24'h0B_10_20;  // page background, outside plan
    localparam [23:0] C_ROOM  = 24'h0F_19_27;  // room fill
    localparam [23:0] C_CORR  = 24'h1B_2E_44;  // corridor floor
    localparam [23:0] C_WALL  = 24'h46_63_82;  // outer wall frame
    localparam [23:0] C_DIV   = 24'h2A_44_60;  // room partition
    localparam [23:0] C_POS   = 24'h00_C8_E0;  // current position, cyan
    localparam [23:0] C_EXIT  = 24'h3C_D8_5A;  // exits, bright green
    localparam [23:0] C_ROUTE = 24'hFF_D2_3C;  // route, amber

    // ------------------------------------------------------- plan outline
    // Outer wall: x in [64, 575), y in [72, 408). The frame is 4 px thick on
    // every side, so the walkable interior is x in [68, 571), y in [76, 404).
    localparam [10:0] PX0 = 11'd64;
    localparam [10:0] PX1 = 11'd575;
    localparam [9:0]  PY0 = 10'd72;
    localparam [9:0]  PY1 = 10'd408;

    wire x_in_plan = (active_x >= PX0) && (active_x < PX1);
    wire y_in_plan = (active_y >= PY0) && (active_y < PY1);
    wire in_plan   = x_in_plan && y_in_plan;

    wire wall_v = (active_x < (PX0 + 11'd4)) || (active_x >= (PX1 - 11'd4));
    wire wall_h = (active_y < (PY0 + 10'd4)) || (active_y >= (PY1 - 10'd4));
    wire wall   = in_plan && (wall_v || wall_h);

    // ------------------------------------------------------------ corridors
    // Main corridor runs the full interior width at y in [224, 248); the north
    // branch corridor climbs from the main corridor to the top wall opening at
    // x in [152, 176).
    wire y_main_corr = (active_y >= 10'd224) && (active_y < 10'd248);
    wire y_upper     = (active_y >= 10'd76)  && (active_y < 10'd224);
    wire y_lower     = (active_y >= 10'd248) && (active_y < 10'd404);
    wire x_interior  = (active_x >= 11'd68)  && (active_x < 11'd571);
    wire x_branch    = (active_x >= 11'd152) && (active_x < 11'd176);

    wire corridor = (y_main_corr && x_interior) || (y_upper && x_branch);
    wire room     = in_plan && (y_upper || y_lower) && !corridor;

    // ------------------------------------------------------------ partitions
    // Partitions are plain vertical slices: above the corridor every 128 px,
    // below the corridor every 128 px offset by 64 px, so the two rows of
    // rooms never line up. Both patterns are single 7-bit comparisons.
    wire div_upper = (active_x[6:0] < 7'd2);
    wire div_lower = (active_x[6:0] == 7'd64) || (active_x[6:0] == 7'd65);
    wire divider   = x_interior &&
                     ((y_upper && div_upper) || (y_lower && div_lower));

    // ------------------------------------------------------ current position
    wire pos_block = (active_x >= 11'd216) && (active_x < 11'd240) &&
                     (active_y >= 10'd228) && (active_y < 10'd244);

    // ----------------------------------------------------------------- exits
    // Exit A is the north opening at the top of the branch corridor; exit B is
    // the east opening at the far end of the main corridor. Both are solid
    // 4 px-thick bright-green blocks that overwrite the wall band, so they read
    // as openings rather than as wall.
    wire exit_a = (active_x >= 11'd150) && (active_x < 11'd178) &&
                  (active_y >= 10'd72)  && (active_y < 10'd86);
    wire exit_b = (active_x >= 11'd559) && (active_x < 11'd575) &&
                  (active_y >= 10'd222) && (active_y < 10'd250);
    wire exit_mark = exit_a || exit_b;

    // ----------------------------------------------------------------- route
    // Manhattan route from the current position to exit A (the nearer of the
    // two): run west along the corridor centreline y in [234, 238), then turn
    // north up the branch corridor centreline x in [162, 166).
    wire route_h = (active_y >= 10'd234) && (active_y < 10'd238) &&
                   (active_x >= 11'd162) && (active_x < 11'd216);
    wire route_v = (active_x >= 11'd162) && (active_x < 11'd166) &&
                   (active_y >= 10'd86)  && (active_y < 10'd236);
    wire route   = route_h || route_v;

    // -------------------------------------------------------------- rendering
    // Single priority cascade, back to front: rooms, corridor, partitions,
    // walls, route, position, exits.
    always @* begin
        rgb_out = C_BG;
        if (!de) begin
            rgb_out = 24'd0;
        end else begin
            if (room)      rgb_out = C_ROOM;
            if (corridor)  rgb_out = C_CORR;
            if (divider)   rgb_out = C_DIV;
            if (wall)      rgb_out = C_WALL;
            if (route)     rgb_out = C_ROUTE;
            if (pos_block) rgb_out = C_POS;
            if (exit_mark) rgb_out = C_EXIT;
        end
    end

endmodule
