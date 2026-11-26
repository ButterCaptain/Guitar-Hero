`timescale 1ns / 1ps
module audio_pll (
    input  wire inclk0,
    output reg  c0 = 0,
    output wire locked
);
    always #41.667 c0 = ~c0; // 12.000 MHz clock (83.33 ns period)
    assign locked = 1'b1;
endmodule