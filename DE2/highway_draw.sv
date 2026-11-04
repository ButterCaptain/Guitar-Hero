import highway_pkg::*;

module highway_draw (
    input  logic       clk50,
    input  logic       rst,
    // The note buffer, driven from outside. slots[lane][0] is the hit line,
    // slots[lane][N_SLOTS-1] is the far end of the highway.
    input  logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots,
    output logic       hsync,
    output logic       vsync,
    output logic       frame_tick,
    output logic [3:0] vga_r,
    output logic [3:0] vga_g,
    output logic [3:0] vga_b
);

    // Wires from vga_sync module
    logic [9:0] x, y;
    logic       visible;

    // Instantiate your VGA sync
    vga_sync sync_unit (
        .clk50(clk50),
        .rst(rst),
        .hsync(hsync),
        .vsync(vsync),
        .x(x),
        .y(y),
        .visible(visible),
        .frame_tick(frame_tick)
    );

    // We need a pulse exactly once per row to update our math.
    // x changes every 2 clock cycles, so we check when it resets to 0.
    logic [9:0] last_x;
    logic       new_line;

    always_ff @(posedge clk50) begin
        last_x <= x;
    end

    always_comb begin
        new_line = (x == 0 && last_x != 0);
    end

    // Drawing the lines with a set slope (step under EDGE_TOP_Q8)
    // 6 accumulators to track the X coordinates of the lane boundaries
    logic signed [19:0] edge_acc [0:5];

    always_ff @(posedge clk50) begin
        if (rst) begin
            for (int i = 0; i < 6; i++) edge_acc[i] <= 0;
        end
        else if (new_line) begin
            // new_line pulses on the FIRST cycle of a row, at which point y is
            // already the new row's number. So we load on row TOP_Y itself and
            // only start adding from the row after it.
            if (y == TOP_Y) begin
                for (int i = 0; i < 6; i++) begin
                    edge_acc[i] <= signed'(EDGE_TOP_Q8[i]);
                end
            end
            else if (y > TOP_Y && y <= BOT_Y) begin
                // For every row inside the highway, add the STEP slope to make it fan out
                for (int i = 0; i < 6; i++) begin
                    edge_acc[i] <= edge_acc[i] + signed'(EDGE_STEP_Q8[i]);
                end
            end
        end
    end

    // Convert the Q8 math back to normal integers for the screen (shift right by 8)
    logic [9:0] edge_x [0:5];
    always_comb begin
        for (int i = 0; i < 6; i++) begin
            edge_x[i] = edge_acc[i][17:8];
        end
    end

    // collision
    logic       in_highway;   // pixel is inside the painted area of the trapezoid
    logic [2:0] lane_idx;
    logic       on_outline;   // pixel sits on one of the 6 boundary lines
    logic       row_in_range; // this scanline is between the top and bottom edges

    always_comb begin
        // Checks if we are in the vertical range for the highway
        row_in_range = (y >= TOP_Y) && (y <= BOT_Y);

        // Boolean statement to make sure the note is in the highway or off screen
        in_highway = 1'b0;

        // Which lane it is in 
        // Example : | Lane 1 | Lane 2 | Lane 3 | etc...
        lane_idx   = 3'd0;

        // chcek if the x and y is in the highway or in a lane.
        if (row_in_range) begin
            if      (x >= edge_x[0] && x < edge_x[1]) begin in_highway = 1'b1; lane_idx = 3'd0; end
            else if (x >= edge_x[1] && x < edge_x[2]) begin in_highway = 1'b1; lane_idx = 3'd1; end
            else if (x >= edge_x[2] && x < edge_x[3]) begin in_highway = 1'b1; lane_idx = 3'd2; end
            else if (x >= edge_x[3] && x < edge_x[4]) begin in_highway = 1'b1; lane_idx = 3'd3; end
            else if (x >= edge_x[4] && x < edge_x[5]) begin in_highway = 1'b1; lane_idx = 3'd4; end
        end

        // The 6 fan lines. Each boundary moves at most 0.625 px per scanline, so
        // marking the single pixel x == edge_x[i] on every row draws a solid,
        // gap-free line 
        on_outline = 1'b0;

        // Set outline to true only if we are over a pixel that is on the edge.
        if (row_in_range) begin
            for (int i = 0; i < 6; i++) begin
                if (x == edge_x[i]) on_outline = 1'b1;
            end
        end

        // Plus the horizontal top and bottom edges that close the shape.
        if ((y == TOP_Y || y == BOT_Y) && x >= edge_x[0] && x <= edge_x[5]) begin
            on_outline = 1'b1;
        end
    end

    // LUT for Depth
    // SLOT_LUT turns a screen row into a depth slot. Bit 6 says the row is
    // inside the highway vertically; bits 5:0 are the slot number, 0 = nearest.
    logic [6:0] slot_data; // Raw value pulled form LUT
    logic       slot_valid; // This is just telling us current pixel (x,y) is actallyin inside the highway
    logic [5:0] depth_slot; // Tell us how far away (in 3D space) the current pixel is.

    always_comb begin
        // Goes to LUT and grabs the number from the SLOT_LUT using the current y position
        slot_data  = (y < SCREEN_H[9:0]) ? SLOT_LUT[y] : 7'd0; 

        slot_valid = slot_data[6];
        depth_slot = slot_data[5:0];
    end

    // Drawing to the screen
    logic [3:0] draw_r, draw_g, draw_b;
    logic [1:0] note_cell;

    always_comb begin
        // Black background.
        draw_r = 4'h0; 
        draw_g = 4'h0; 
        draw_b = 4'h0;

        note_cell = CELL_EMPTY;
        if (in_highway && slot_valid) begin
            note_cell = slots[lane_idx][depth_slot];
        end

        // A note fills the whole depth slot it occupies. Because the slots get
        // shorter toward the horizon, the bar is automatically drawn thin when
        // far away and thick when near -- no extra maths needed.
        if (note_cell != CELL_EMPTY) begin
            draw_r = LANE_R[lane_idx];
            draw_g = LANE_G[lane_idx];
            draw_b = LANE_B[lane_idx];
            // Disscuss what to do - 
            // if (note_cell == CELL_HOLD) begin
                // Held-note body is dimmer so it reads as a tail, not a head.
            //    draw_r = LANE_R[lane_idx] >> 1;
            //    draw_g = LANE_G[lane_idx] >> 1;
            //    draw_b = LANE_B[lane_idx] >> 1;
            //end
        end

        // The white wireframe is drawn last so it always sits on top.
        // This colors the frame white only when on_outline is true.
        if (on_outline) begin
            draw_r = 4'hF; draw_g = 4'hF; draw_b = 4'hF;
        end
    end

    // Apply the VGA blanking mask (set the display to 0 when it isn't visible)
    always_comb begin
        vga_r = visible ? draw_r : 4'h0;
        vga_g = visible ? draw_g : 4'h0;
        vga_b = visible ? draw_b : 4'h0;
    end

endmodule
