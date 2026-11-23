module score_top (
    input [15:0] score_in,
    output [6:0] seg0, 
    output [6:0] seg1,
    output [6:0] seg2,
    output [6:0] seg3
);
    logic [3:0] ones = score % 10; 
    logic [3:0] tens = (score / 10) % 10;
    logic [3:0] hundreds = (score / 100) % 10;
    logic [3:0] thousands = (score / 1000) % 10;
    hex7seg seg0_unit (
        .digit (ones),
        .seg   (seg0)
    );

    hex7seg seg1_unit (
        .digit (tens),
        .seg   (seg1)
    );

    hex7seg seg2_unit (
        .digit (hundreds),
        .seg   (seg2)
    );

    hex7seg seg3_unit (
        .digit (thousands),
        .seg   (seg3)
    );
endmodule