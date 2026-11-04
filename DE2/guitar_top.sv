import highway_pkg::*;

//  note_feeder, which reads the chart out of notes.hex.
module guitar_top (
    input  logic               clk50,
    input  logic               rst,
    input  logic [4:0]         fret,
    input  logic               strum_up,
    input  logic               strum_down,
    output logic               hsync,
    output logic               vsync,
    output logic [3:0]         r,
    output logic [3:0]         g,
    output logic [3:0]         b,
    output logic signed [15:0] score
);
    // The 2D Array where the notes are held
    logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots;
    // Global Fram tick so everything is synced 
    logic frame_tick;
    // Counts the frames
    logic [14:0] frame_count;
    logic song_done;

    highway_draw draw_unit (
        .clk50      (clk50),
        .rst        (rst),
        .slots      (slots),
        .hsync      (hsync),
        .vsync      (vsync),
        .frame_tick (frame_tick),
        .vga_r      (r),
        .vga_g      (g),
        .vga_b      (b)
    );

    // Reads notes.hex and pushes notes onto the far end of the highway.
    note_feeder #(
        .ADDR_W (11)
    ) feeder (
        .clk50       (clk50),
        .rst         (rst),
        .frame_tick  (frame_tick),
        .slots       (slots),
        .frame_count (frame_count),
        .song_done   (song_done)
    );

    // Placeholder until the hit-detect FSM exists.
    always_comb begin
        score = 16'sd0;
    end

endmodule
