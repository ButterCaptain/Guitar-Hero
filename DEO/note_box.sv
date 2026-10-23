module note_box #(
    parameter int X_POS      = 100,
    parameter int BOX_W      = 40,
    parameter int BOX_H      = 40,
    parameter int START_Y    = 0,
    parameter int SPEED_MIN  = 256,    // 1 px/frame   (8.8 fixed point)
    parameter int SPEED_MAX  = 2048,   // 8 px/frame, hard cap
    parameter int SPEED_STEP = 6,      // added per frame -> ramp length
    parameter int ZONE_Y0    = 400,    // hit zone top
    parameter int ZONE_Y1    = 420     // hit zone bottom
)(
    input  logic       clk50,
    input  logic       rst,
    input  logic       frame_tick,
    input  logic [9:0] x, y,
    input  logic       fret_held,      // this lane's button
    input  logic       strum_edge,     // 1-cycle pulse when strum is pressed
    output logic       in_box,         // pixel is inside the note
    output logic       hit             // 1-cycle pulse when note is hit
);
    localparam int SCREEN_H = 480;

    logic [17:0] pos;     // 10.8 fixed point
    logic [11:0] speed;   //  4.8 fixed point

    wire [9:0] box_y   = pos[17:8];
    wire [17:0] next_pos = pos + speed;

    // Note overlaps the hit zone
    wire in_zone = (box_y + BOX_H > ZONE_Y0) && (box_y < ZONE_Y1);

    assign hit = strum_edge && fret_held && in_zone;

    always_ff @(posedge clk50) begin
        if (rst) begin
            pos   <= START_Y << 8;
            speed <= 12'(SPEED_MIN);
        end else begin
            if (frame_tick) begin
                pos <= (next_pos >= (SCREEN_H << 8)) ? 18'd0 : next_pos;

                // Accelerate, then hard-cap
                if (speed + SPEED_STEP >= SPEED_MAX)
                    speed <= 12'(SPEED_MAX);
                else
                    speed <= speed + 12'(SPEED_STEP);
            end

            // Later assignment wins: a hit sends the note back to the top.
            // Speed is untouched, so it keeps running at full speed.
            if (hit) pos <= 18'd0;
        end
    end

    assign in_box = (x >= X_POS) && (x < X_POS + BOX_W) &&
                    (y >= box_y) && (y < box_y + BOX_H);
endmodule