// ============================================================================
//  highway_draw.sv  --  the Guitar Hero highway renderer
// ============================================================================
//
//  WHAT THIS MODULE IS
//  -------------------
//  It is the "GPU" of the project. It takes the note chart (`slots`) and turns
//  it into a VGA picture: a 3D-looking highway with five coloured lanes and
//  notes sliding down it toward the player.
//
//  THE ONE IDEA YOU NEED
//  ---------------------
//  There is NO framebuffer. There is no memory holding the picture. A VGA
//  monitor is a beam that sweeps left-to-right, top-to-bottom, 640x480 times a
//  frame, and all we get to do is answer ONE question, over and over, 25
//  million times a second:
//
//        "The beam is at pixel (x, y) right now. What colour is it?"
//
//  So every single thing below exists to answer that question for one pixel,
//  using only cheap logic (adds, compares, shifts). No multiplies, no divides,
//  nothing stored. If you remember nothing else: this file is one giant
//  function from (x, y) -> (r, g, b).
//
//  THE PICTURE WE ARE DRAWING
//  --------------------------
//  The highway is a trapezoid: narrow at the top (far away, the "horizon"),
//  wide at the bottom (close to you, the "hit line"). Six boundary lines fan
//  out from top to bottom and carve it into five lanes.
//
//        y = TOP_Y = 64     +--+--+--+--+--+        <- far / horizon
//                          /  /   |   \  \
//                         /  /    |    \  \
//                        /  /     |     \  \
//        y = BOT_Y = 448 +--+------+------+--+      <- near / hit line
//                        ^  ^      ^      ^  ^
//                     edge 0  1    2    3  4  5     (6 boundaries, 5 lanes)
//
//  Notes travel UP in slot number and DOWN in screen position. Each lane is a
//  queue of 'slots'; slot 0 is at the hit line and the highest slot is at the
//  horizon. note_feeder shifts that queue toward 0 once per frame, which is
//  what makes the notes appear to fall toward you.
//
//  THE FIVE JOBS, IN ORDER
//  -----------------------
//    1. Where is the beam?                -> vga_sync gives us x, y
//    2. Where are the lane edges on this   -> STAGE 2/3, a running adder
//       row, and which lane is x in?          (a "DDA"), then compares
//    3. How far away is this row?          -> STAGE 4, a lookup table
//    4. Is there a note in that lane at    -> STAGE 6, read `slots`
//       that distance?
//    5. Paint it.                          -> STAGE 7/8
//
//  NOTHING HERE REMEMBERS ANYTHING ABOUT THE GAME. Every stage below is either
//  combinational or a per-scanline accumulator for the geometry. Held notes,
//  which you would think need memory ("am I inside a tail right now?"), do not:
//  note_feeder writes the tail into `slots` as actual cells, so this module
//  only ever has to look at the ONE cell under the beam and paint it. See
//  STAGE 6 for the four cell codes and what each one draws.
// ============================================================================

import highway_pkg::*;

module highway_draw (
    // ---- clock and reset ---------------------------------------------------
    input  logic clk50,                  // 50 MHz board clock
    input  logic rst,                    // synchronous, active high

    // ---- the note chart ----------------------------------------------------
    // Driven from outside by note_feeder. Two bits per cell:
    //   CELL_EMPTY    nothing here
    //   CELL_NOTE     a note to hit -- a tap, or the head of a hold. Rectangle.
    //   CELL_HOLD     tail body trailing behind a hold head. Thin line.
    //   CELL_HOLD_END the release marker at the end of a tail. Draws as NOTHING.
    // slots[lane][0]           = right at the hit line (closest to you)
    // slots[lane][N_SLOTS-1]   = far end of the highway (the horizon)
    input  logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots,
    input logic [N_LANES-1:0] frets,

    // ---- VGA out -----------------------------------------------------------
    output logic       hsync,
    output logic       vsync,
    output logic       frame_tick,       // one pulse per frame, drives the game
    output logic       vga_clk,          // 25 MHz pixel clock -> VGA_CLK pin
    output logic       blank_n,          // active low -> VGA_BLANK_N pin
    // Width comes from COLOR_BITS so the palette, this bus and the glow
    // accumulator can never disagree. Hardcoding [3:0] here while the
    // package said COLOR_BITS=8 is what produced the banding.
    output logic [COLOR_BITS-1:0] vga_r,
    output logic [COLOR_BITS-1:0] vga_g,
    output logic [COLOR_BITS-1:0] vga_b,

    // ---- game logic out ----------------------------------------------------
    // "IS THE USER SUPPOSED TO BE HOLDING A FRET RIGHT NOW?"
    // One bit per lane, high while lane L's tail is crossing the hit line. The
    // hit-detect FSM should use it like this:
    //
    //      holding_correctly = hold_line & fret;     // per lane
    //      missed_the_hold   = hold_line & ~fret;
    //
    // It is simply "is slot 0 a tail cell", so it only changes once per frame
    // when note_feeder shifts the queue -- it never flickers while the beam
    // scans, and it is safe to sample at any moment. It goes high the frame
    // AFTER the head crosses the line (strum first, then hold) and low when the
    // release marker arrives.
    output logic [N_LANES-1:0] hold_line
);

    // ------------------------------------------------------------------------
    //  TUNING KNOBS -- change these, nothing else, to restyle the notes
    // ------------------------------------------------------------------------

    // How thin a held-note TAIL is drawn, as a right-shift of the lane width.
    // The ribbon ends up 2*(lane_width >> TAIL_SHIFT) pixels wide:
    //      TAIL_SHIFT = 2  ->  half the lane  (chunky)
    //      TAIL_SHIFT = 3  ->  a quarter      (default, looks like Guitar Hero)
    //      TAIL_SHIFT = 4  ->  an eighth      (spaghetti)
    localparam int TAIL_SHIFT = 3;

    // How much darker a tail is than a note head. 1 = half brightness.
    localparam int TAIL_DIM_SHIFT = 1;

    // The geometry constants arrive from highway_pkg as plain `int` (32 bits).
    // We compare them against `y`, which is 10 bits. Making 10-bit copies here
    // keeps the comparisons the same width and keeps the linter quiet.
    localparam logic [9:0] TOP_ROW = 10'(TOP_Y);    // first row of the highway
    localparam logic [9:0] BOT_ROW = 10'(BOT_Y);    // last row = the hit line

    // Glow Stuff
    // How many scanlines tall the white glow is at the hit line
    localparam int GLOW_HEIGHT = 64;

    // ========================================================================
    //  STAGE 1 -- WHERE IS THE BEAM?
    // ========================================================================
    //  vga_sync owns the pixel clock and the sync pulses. All we want from it
    //  is the beam position (x, y) and `visible`, which is low during the
    //  blanking intervals (the off-screen margins the monitor needs).
    // ========================================================================

    logic [9:0] x, y;        // beam position. x = 0..639, y = 0..479 on screen
    logic       visible;     // 1 while the beam is in the visible 640x480 area

    vga_sync sync_unit (
        .clk50      (clk50),
        .rst        (rst),
        .hsync      (hsync),
        .vsync      (vsync),
        .x          (x),
        .y          (y),
        .visible    (visible),
        .frame_tick (frame_tick),
        .vga_clk    (vga_clk),
        .blank_n    (blank_n)
    );

    // ========================================================================
    //  STAGE 2 -- "A NEW ROW JUST STARTED" PULSE
    // ========================================================================
    //  Some of our maths needs to happen exactly ONCE per scanline, not once
    //  per pixel. The clock is 50 MHz but the pixel clock is 25 MHz, so x only
    //  changes every other clock cycle -- we cannot just use "x == 0", that
    //  would be true for two cycles in a row and we would add twice.
    //
    //  Fix: remember last cycle's x, and fire only on the EDGE where x became
    //  zero. One clock cycle wide, once per row. Clean.
    //
    //      x:         637  638  639    0    0    1    1  ...
    //      last_x:    637  637  638  639    0    0    1  ...
    //      new_line:   0    0    0    1    0    0    0      <- exactly one
    //
    //  IMPORTANT TIMING NOTE, used all over this file: when new_line fires, `y`
    //  has ALREADY advanced to the new row's number. So anything we compute on
    //  this pulse is "for the row we are just starting", and it lands in its
    //  flip-flop at x = 0 or 1 -- long before the beam reaches the highway,
    //  whose leftmost pixel is x = 32. Everything is settled in time.
    // ========================================================================

    logic [9:0] last_x;
    logic       new_line;

    always_ff @(posedge clk50) begin
        last_x <= x;
    end

    always_comb begin
        new_line = (x == 10'd0) && (last_x != 10'd0);
    end

    // ========================================================================
    //  STAGE 3 -- WHERE ARE THE SIX LANE EDGES ON THIS ROW?
    // ========================================================================
    //  Each boundary is a straight slanted line. The textbook way to find its x
    //  on row y is:
    //
    //      x = x_at_top + slope * (y - TOP_Y)          <-- needs a MULTIPLIER
    //
    //  Multipliers are expensive and we would need six of them. Instead we use
    //  a DDA (Digital Differential Analyser), which is a fancy name for a very
    //  dumb idea: keep a running total and add the slope to it once per row.
    //
    //      row TOP_Y:      acc = starting x
    //      every row after: acc = acc + slope
    //
    //  Six adders instead of six multipliers. Same answer, every row.
    //
    //  WHY Q8 FIXED POINT: a slope like "0.625 pixels per row" is not a whole
    //  number, and there are no fractions in hardware. So we store everything
    //  multiplied by 256 (that is what "Q8" means: 8 fractional bits). 0.625
    //  becomes 160. We add in that scaled world, then shift right by 8 at the
    //  very end to get back to real pixels. The fraction accumulates correctly
    //  instead of being thrown away each row, so the lines stay straight.
    //
    //  The constants come from tools/gen_highway_pkg.py, which worked out the
    //  trapezoid once, offline, in Python -- so the FPGA never has to.
    //
    //  SIGNED, because EDGE_STEP_Q8 is negative for the three left-hand
    //  boundaries (they move LEFT as you go down the screen) and positive for
    //  the three on the right. That is what makes the highway fan out.
    // ========================================================================

    logic signed [19:0] edge_acc [0:5];   // the six running totals, in Q8

    always_ff @(posedge clk50) begin
        if (rst) begin
            for (int i = 0; i < 6; i++) edge_acc[i] <= '0;
        end
        else if (new_line) begin
            if (y == TOP_ROW) begin
                // First row of the highway: LOAD the starting positions.
                for (int i = 0; i < 6; i++) begin
                    edge_acc[i] <= signed'(EDGE_TOP_Q8[i]);
                end
            end
            else if (y > TOP_ROW && y <= BOT_ROW) begin
                // Every row after that: ADD the slope. This is the whole trick.
                for (int i = 0; i < 6; i++) begin
                    edge_acc[i] <= edge_acc[i] + signed'(EDGE_STEP_Q8[i]);
                end
            end
            // Outside the highway we leave the accumulators alone; nothing
            // reads them there.
        end
    end

    // Back from Q8 to real screen pixels: drop the 8 fractional bits.
    // Bits [17:8] are the integer part, which is all a 640-wide screen needs.
    logic [9:0] edge_x [0:5];

    always_comb begin
        for (int i = 0; i < 6; i++) begin
            edge_x[i] = edge_acc[i][17:8];
        end
    end

    // ========================================================================
    //  STAGE 4 -- WHICH LANE IS THIS PIXEL IN, AND IS IT ON A WHITE LINE?
    // ========================================================================
    //  Now that we know where the six edges are on THIS row, placing the pixel
    //  is just a handful of compares. Lane L lives between edge L and edge L+1:
    //
    //      edge_x[0]   edge_x[1]   edge_x[2]   edge_x[3]   edge_x[4]  edge_x[5]
    //          |  lane 0  |  lane 1  |  lane 2  |  lane 3  |  lane 4  |
    // ========================================================================

    logic       row_in_range;  // is this scanline inside the highway at all?
    logic       in_highway;    // is this pixel inside the painted trapezoid?
    logic [2:0] lane_idx;      // 0..4, which lane. Junk unless in_highway.
    logic       on_outline;    // is this pixel part of the white wireframe?

    always_comb begin
        // --- vertical test: are we between the far edge and the hit line? ---
        row_in_range = (y >= TOP_ROW) && (y <= BOT_ROW);

        // --- horizontal test: which of the five lanes, if any? --------------
        // Defaults first, so every path assigns something (no accidental
        // latches, and no X's in simulation).
        in_highway = 1'b0;
        lane_idx   = 3'd0;

        if (row_in_range) begin
            if      (x >= edge_x[0] && x < edge_x[1]) begin in_highway = 1'b1; lane_idx = 3'd0; end
            else if (x >= edge_x[1] && x < edge_x[2]) begin in_highway = 1'b1; lane_idx = 3'd1; end
            else if (x >= edge_x[2] && x < edge_x[3]) begin in_highway = 1'b1; lane_idx = 3'd2; end
            else if (x >= edge_x[3] && x < edge_x[4]) begin in_highway = 1'b1; lane_idx = 3'd3; end
            else if (x >= edge_x[4] && x < edge_x[5]) begin in_highway = 1'b1; lane_idx = 3'd4; end
        end

        // --- the white wireframe --------------------------------------------
        // The six slanted lines: just light up the single pixel sitting exactly
        // on each boundary. You might expect gaps, since the line is slanted --
        // but each boundary moves at most 0.625 px per row, i.e. less than one
        // pixel, so consecutive rows are always touching. Solid line, one
        // comparison, no line-drawing algorithm needed.
        on_outline = 1'b0;

        if (row_in_range) begin
            for (int i = 0; i < 6; i++) begin
                if (x == edge_x[i]) on_outline = 1'b1;
            end
        end

        // The two horizontal lines that close the shape top and bottom.
        if ((y == TOP_ROW || y == BOT_ROW) && x >= edge_x[0] && x <= edge_x[5]) begin
            on_outline = 1'b1;
        end
    end

    // ========================================================================
    //  STAGE 5 -- HOW FAR AWAY IS THIS ROW? (the perspective)
    // ========================================================================
    //  In a 3D view, distance is NOT proportional to screen row. Rows near the
    //  horizon cover a huge amount of distance; rows near your face cover very
    //  little. The real formula involves a divide:
    //
    //      depth = q0 * up / (q0 - up)
    //
    //  We are not doing a divide per pixel. gen_highway_pkg.py evaluates that
    //  formula once for all 480 rows and bakes the answers into SLOT_LUT. At
    //  runtime this is a single table read -- a ROM lookup, basically free.
    //
    //      SLOT_LUT[y] top bit   = 1 if this row is inside the highway
    //      SLOT_LUT[y] lower bits = which depth slot the row belongs to
    //                               (0 = at the hit line, bigger = further)
    //
    //  THE WIDTHS COME FROM THE PACKAGE, ON PURPOSE. SLOT_BITS is how many bits
    //  a slot number needs and LUT_BITS is that plus one for the valid flag.
    //  Both are computed from N_SLOTS by the generator, so if you change the
    //  slot count these registers resize themselves. Hardcoding 6 and 7 here is
    //  what let N_SLOTS get bumped to 128 while the renderer could still only
    //  address 64 -- notes then spent a whole second crawling through slots
    //  nothing could draw. Don't put the numbers back in by hand.
    //
    //  A CAVEAT AT 128 SLOTS: the highway is only 384 scanlines tall, and the
    //  far end of the perspective squeezes slots very tightly, so 13 of the
    //  farthest slots (87, 94, 99, ... 125) get ZERO scanlines -- the generator
    //  prints a warning listing them. A note passing through one of those is
    //  invisible for that one frame, so expect a faint blink right at the
    //  horizon. It fixes itself as the note gets closer. Drop N_SLOTS back to
    //  64 if the blinking bothers you more than the shorter lookahead does.
    //
    //  THE FREE LUNCH: a note occupies exactly one slot. Slots near the horizon
    //  are only one or two scanlines tall; slots near the hit line are many
    //  scanlines tall. So a note automatically shrinks as it gets further away
    //  and grows as it comes at you, with zero extra maths. That is the entire
    //  3D effect, and it cost us one table.
    // ========================================================================

    logic [LUT_BITS-1:0]  slot_data;    // raw LUT word for this row
    logic                 slot_valid;   // top bit: row is inside the highway
    logic [SLOT_BITS-1:0] depth_slot;   // lower bits: how far away this row is

    always_comb begin
        // y[8:0] because SLOT_LUT has 480 entries and only needs 9 index bits.
        // The guard keeps us from reading off the end during blanking.
        slot_data  = (y < 10'(SCREEN_H)) ? SLOT_LUT[y[8:0]] : '0;

        slot_valid = slot_data[SLOT_BITS];        // the flag sits above the slot
        depth_slot = slot_data[SLOT_BITS-1:0];
    end

    // ========================================================================
    //  STAGE 6 -- WHAT IS IN THIS CELL, AND WHAT DOES THE PLAYER OWE US?
    // ========================================================================
    //  THE OLD VERSION OF THIS FILE HAD A TRACKER HERE: a per-lane "am I inside
    //  a hold?" bit that the beam updated as it scanned down the screen. It is
    //  gone, and good riddance. note_feeder now writes the tail into `slots` as
    //  real cells, one per frame, so there is nothing left to reconstruct. This
    //  module looks at ONE cell and paints it. That is the whole job.
    //
    //  THE FOUR CELL CODES, AND THE PICTURE THEY MAKE
    //
    //      CELL_NOTE      a note to hit -- tap or hold head. Full-width
    //                     rectangle, full brightness.
    //      CELL_HOLD      tail body. Thin dim line down the middle of the lane.
    //      CELL_HOLD_END  release marker. DRAWS AS NOTHING. It is not a note,
    //                     it is just where the tail stops.
    //      CELL_EMPTY     nothing.
    //
    //  A held note therefore looks like this coming down the highway -- the
    //  rectangle in front, a thin line trailing behind it, and nothing at all
    //  where the chart's second note sits:
    //
    //          horizon
    //            .              <- CELL_HOLD_END, invisible
    //            |              <- CELL_HOLD, thin line
    //            |
    //            |
    //          [===]            <- CELL_NOTE, the rectangle you strum
    //          hit line
    //
    //  The head crosses the hit line FIRST and the tail follows: you strum the
    //  rectangle, then keep holding while the line goes past.
    // ========================================================================

    // "The player should be holding this fret." Slot 0 is the cell sitting on
    // the hit line, so a tail cell there means a hold is in progress right now.
    // Pure combinational logic off the note queue -- no beam involvement, no
    // registers, nothing to get out of step with the feeder.
    always_comb begin
        for (int L = 0; L < N_LANES; L++) begin
            hold_line[L] = (slots[L][0] == CELL_HOLD);
        end
    end

    // ========================================================================
    //  STAGE 7 -- THE THIN RIBBON FOR TAILS
    // ========================================================================
    //  A note HEAD fills its lane edge to edge, like a fat brick. A tail should
    //  be a thin ribbon down the middle of the lane, so you can tell the two
    //  apart at a glance. This works out the middle slice of whichever lane the
    //  pixel is in:
    //
    //      edge_x[L]        lane_mid           edge_x[L+1]
    //          |---------------|-----|-------------|
    //          <-- band_half -->     <- band_half ->
    //                   [  the ribbon  ]
    //
    //  Because lane_w comes from the STAGE 3 accumulators, which narrow toward
    //  the horizon, the ribbon narrows with the lane for free. Shifts only --
    //  no divides.
    // ========================================================================

    logic [9:0] lane_l;       // left edge of the lane this pixel is in
    logic [9:0] lane_r;       // right edge
    logic [9:0] lane_w;       // width in pixels (shrinks toward the horizon)
    logic [9:0] lane_mid;     // centre
    logic [9:0] band_half;    // half the ribbon's width
    logic       in_tail_band; // is this pixel inside the ribbon?

    always_comb begin
        lane_l   = edge_x[lane_idx];
        lane_r   = edge_x[lane_idx + 3'd1];   // lane_idx maxes at 4, so index 5
        lane_w   = lane_r - lane_l;
        lane_mid = lane_l + (lane_w >> 1);    // >> 1 is divide by 2

        band_half = lane_w >> TAIL_SHIFT;
        // Up at the horizon a lane is only ~19 px wide, and 19 >> 3 = 2... but
        // if you crank TAIL_SHIFT up it can hit 0 and the tail vanishes. Floor
        // it at one pixel so a tail is always visible.
        if (band_half == 10'd0) band_half = 10'd1;

        // The obvious way to write this is:
        //      (x >= lane_mid - band_half) && (x <= lane_mid + band_half)
        // but these are UNSIGNED, so if the ribbon sits near the left of the
        // screen that subtraction wraps around to a huge number and the test
        // breaks. Adding to the left-hand side instead is the same comparison
        // with no wrap.
        in_tail_band = (x + band_half >= lane_mid) && (x <= lane_mid + band_half);
    end

    // ========================================================================
    //  STAGE 8 -- PAINT THE PIXEL
    // ========================================================================
    //  Everything above was gathering facts. This is the decision, and it is a
    //  priority chain: later `if`s paint over earlier ones, so the order IS the
    //  layering, back to front:
    //
    //      1. black background
    //      2. notes and tails
    //      3. the white wireframe on top of everything
    // ========================================================================

    logic [COLOR_BITS-1:0] draw_r, draw_g, draw_b;
    logic [1:0] note_cell;   // what is in this pixel's cell of the chart

    // Glow Stuff
    logic [9:0] glow_dist; 
    // COLOR_BITS:0 is NINE bits for an 8-bit colour: eight for the sum plus one
    // on top to catch the carry. Declared [COLOR_BITS-1:0] there is no carry bit
    // to test -- the overflow just vanishes and bright pixels wrap to dark.
    logic [COLOR_BITS:0] r_add, g_add, b_add;

    always_comb begin
        // ---- layer 1: background ------------------------------------------
        draw_r = '0;
        draw_g = '0;
        draw_b = '0;


        glow_dist = 10'd0;
        r_add     = '0;
        g_add     = '0;
        b_add     = '0;

        // ---- look up this pixel's cell -------------------------------------
        // "which lane"  x  "how far away"  ->  one cell of the chart.
        note_cell = CELL_EMPTY;
        if (in_highway && slot_valid) begin
            note_cell = slots[lane_idx][depth_slot];
        end

        // ---- layer 2: notes and tails --------------------------------------
        // Vertically, a cell fills its whole depth slot -- that is STAGE 5's
        // free perspective doing the work. Horizontally it depends on the code:
        //
        //    CELL_NOTE      full lane width, full brightness   (the rectangle)
        //    CELL_HOLD      thin ribbon, dimmed                (the tail)
        //    CELL_HOLD_END  nothing at all                     (release marker)
        //    CELL_EMPTY     nothing at all
        //
        // CELL_HOLD_END and CELL_EMPTY both fall through to the background set
        // above, so they need no branch of their own. That is deliberate: the
        // release marker is a position, not a graphic.
        if (note_cell == CELL_NOTE) begin
            draw_r = LANE_R[lane_idx];
            draw_g = LANE_G[lane_idx];
            draw_b = LANE_B[lane_idx];
        end
        else if (note_cell == CELL_HOLD && in_tail_band) begin
            draw_r = LANE_R[lane_idx] >> TAIL_DIM_SHIFT;
            draw_g = LANE_G[lane_idx] >> TAIL_DIM_SHIFT;
            draw_b = LANE_B[lane_idx] >> TAIL_DIM_SHIFT;
        end

        // Button Pressing Glow 
        // Is it in the highway, is the fret pressed, and is it in the glow area?
        if(in_highway && frets[lane_idx] && (y >= (BOT_ROW - 10'(GLOW_HEIGHT))) && (y <= BOT_ROW)) begin

            glow_dist = y - (BOT_ROW - 10'(GLOW_HEIGHT));

            // shift left by 2 maps our 0-64 distance to 0-256 (the 8-bit colour range)
            // Both sides are widened to 9 bits explicitly so the carry lands in
            // bit 8 and nothing is truncated on the way: the worst case is
            // 255 + 256 = 511, which is exactly what 9 bits holds.
            r_add = {1'b0, draw_r} + 9'(glow_dist << 2);
            g_add = {1'b0, draw_g} + 9'(glow_dist << 2);
            b_add = {1'b0, draw_b} + 9'(glow_dist << 2);

            // If the 9th bit (the carry) is set the sum went past 255, so clamp to
            // pure white instead of letting it wrap around to dark.
            // Test bit [COLOR_BITS] -- the carry. Testing [COLOR_BITS-1:0]
            // instead asks "are the low 8 bits non-zero", which is true for
            // almost every pixel and would paint the whole glow solid white.
            draw_r = r_add[COLOR_BITS] ? '1 : r_add[COLOR_BITS-1:0];
            draw_g = g_add[COLOR_BITS] ? '1 : g_add[COLOR_BITS-1:0];
            draw_b = b_add[COLOR_BITS] ? '1 : b_add[COLOR_BITS-1:0];
        end

        // ---- layer 3: the wireframe, last so it is always on top -----------
        if (on_outline) begin
            draw_r = '1;        // all ones, whatever COLOR_BITS is
            draw_g = '1;
            draw_b = '1;
        end
    end

    // ========================================================================
    //  STAGE 9 -- BLANKING
    // ========================================================================
    //  During the horizontal and vertical blanking intervals the beam is off
    //  the visible screen and the monitor demands black. Force the outputs to
    //  zero there; if you skip this you get smeared edges or no sync at all.
    // ========================================================================

    always_comb begin
        vga_r = visible ? draw_r : '0;
        vga_g = visible ? draw_g : '0;
        vga_b = visible ? draw_b : '0;
    end

endmodule
