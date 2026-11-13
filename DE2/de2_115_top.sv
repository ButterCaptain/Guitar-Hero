// ============================================================================
//  de2_115_top.sv -- board wrapper for the Terasic DE2-115 (Cyclone IV E,
//                    EP4CE115F29C7).
//
//  WHY THIS FILE EXISTS
//  --------------------
//  `guitar_top` is the portable design: it talks in plain names like clk50,
//  rst, fret, r/g/b. That is what the Verilator simulation drives, and it would
//  work on any board. THIS file is the only thing that knows it is sitting on a
//  DE2-115: it maps the board's actual pin names onto those plain ones.
//
//  Keeping the two apart means you never have to edit the design to simulate
//  it, and never have to edit the simulation to synthesise it.
//
//  SET THIS AS THE TOP-LEVEL ENTITY IN QUARTUS (not guitar_top).
//
//  THE VGA PATH ON THIS BOARD
//  --------------------------
//  The DE2-115 does not have the DE0's passive resistor ladder. It has an
//  ADV7123 triple video DAC, which means:
//
//    * 8 bits per channel instead of 4 -- 16.7 million colours instead of 4096.
//      (The ADV7123 is a 10-bit part, but the board only wires 8 bits; the two
//      least significant inputs of each channel are grounded.)
//    * The DAC needs VGA_CLK to latch pixels on.
//    * VGA_BLANK_N must go low during the porches or the monitor sees garbage.
//    * VGA_SYNC_N selects sync-on-green, which we do not use, so it is tied
//      high.
//
//  BUTTONS AND SWITCHES ARE ACTIVE LOW on this board. KEY[0] pressed reads as
//  0, so reset is `~KEY[0]`: pressing the button asserts reset. Get this
//  backwards and the design sits in reset until you hold the button down.
//
//  PIN ASSIGNMENTS: do not hand-type them. Import the DE2-115 .qsf that ships
//  with the board's System Builder / CD, which already names every pin exactly
//  as below.
// ============================================================================

import highway_pkg::*;

module de2_115_top (
    // ---- clock ------------------------------------------------------------
    input  logic        CLOCK_50,

    // ---- user input (ACTIVE LOW) -------------------------------------------
    input  logic [3:0]  KEY,          // KEY[0] = reset, KEY[3:1] spare
    input  logic [17:0] SW,           // SW[4:0] = the five frets

    // ---- VGA, to the ADV7123 ----------------------------------------------
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_CLK,
    output logic        VGA_BLANK_N,
    output logic        VGA_SYNC_N,
    output logic        VGA_HS,
    output logic        VGA_VS,

    // ---- a bit of feedback on the LEDs -------------------------------------
    output logic [17:0] LEDR,
    output logic [8:0]  LEDG
);

    // ---- reset -------------------------------------------------------------
    // KEY is active low, our design wants active high.
    logic rst;
    assign rst = ~KEY[0];

    // ---- frets and strum ---------------------------------------------------
    // Slide switches for the five frets, and the two spare push buttons for
    // strum up / strum down. Buttons are active low, hence the inversion.
    logic [4:0] fret;
    logic       strum_up, strum_down;
    assign fret       = SW[4:0];
    assign strum_up   = ~KEY[1];
    assign strum_down = ~KEY[2];

    logic signed [15:0] score;

    guitar_top u_game (
        .clk50      (CLOCK_50),
        .rst        (rst),
        .fret       (fret),
        .strum_up   (strum_up),
        .strum_down (strum_down),
        .hsync      (VGA_HS),
        .vsync      (VGA_VS),
        .vga_clk    (VGA_CLK),
        .blank_n    (VGA_BLANK_N),
        .r          (VGA_R),
        .g          (VGA_G),
        .b          (VGA_B),
        .score      (score)
    );

    // Sync-on-green off. The ADV7123 wants this input high for normal RGB.
    assign VGA_SYNC_N = 1'b1;

    // ---- LEDs --------------------------------------------------------------
    // Red LEDs mirror the frets you are holding, green LEDs show the low bits
    // of the score. Purely so you can see the board is alive.
    assign LEDR = {13'd0, fret};
    assign LEDG = score[8:0];

endmodule
