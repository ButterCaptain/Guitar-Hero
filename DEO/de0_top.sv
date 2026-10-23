module de0_top (
    input  logic        CLOCK_50,
    input  logic [2:0]  KEY,          // KEY[0] = reset (active-low)
    input  logic [6:0]  GUITAR,       // 4:0 frets, 5 strum up, 6 strum down (active-low)
    output logic        VGA_HS, VGA_VS,
    output logic [3:0]  VGA_R, VGA_G, VGA_B,
    output logic [9:0]  LEDG          // temporary score debug
);
    // 2-flip-flop synchronizers, inverting to active-high
    logic [6:0] sync1, sync2;
    logic [1:0] rst_sync;
    always_ff @(posedge CLOCK_50) begin
        sync1    <= ~GUITAR;
        sync2    <= sync1;
        rst_sync <= {rst_sync[0], ~KEY[0]};
    end

    logic [15:0] score;

    guitar_top game (
        .clk50      (CLOCK_50),
        .rst        (rst_sync[1]),
        .fret       (sync2[4:0]),
        .strum_up   (sync2[5]),
        .strum_down (sync2[6]),
        .hsync      (VGA_HS),
        .vsync      (VGA_VS),
        .r(VGA_R), .g(VGA_G), .b(VGA_B),
        .score      (score)
    );

    assign LEDG = score[9:0];   // shows score in binary until the 7-seg exists
endmodule