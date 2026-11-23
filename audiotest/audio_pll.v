// ============================================================================
//  audio_pll.v -- makes the 12.000 MHz clock for the WM8731 audio chip from
//  the board's 50 MHz crystal.
//
//  50 MHz x 6 / 25 = 12.000 MHz exactly, so audio and video both come from
//  the same crystal and can never drift apart.
//
//  This is the Cyclone IV `altpll` block instantiated by hand -- the same
//  thing the Quartus IP wizard (ALTPLL) would generate. If Quartus complains
//  about it, delete this file and make one in the IP Catalog instead:
//  ALTPLL, name it audio_pll, input 50 MHz, one output c0 = 12 MHz, with a
//  `locked` output and no areset.
//
//  Quartus only. It is not used in simulation (the testbench makes its own
//  12 MHz clock).
// ============================================================================

module audio_pll (
    input  wire inclk0,     // 50 MHz
    output wire c0,         // 12 MHz
    output wire locked
);

    wire [4:0] clk_out;
    assign c0 = clk_out[0];

    altpll #(
        .bandwidth_type          ("AUTO"),
        .clk0_divide_by          (25),
        .clk0_duty_cycle         (50),
        .clk0_multiply_by        (6),
        .clk0_phase_shift        ("0"),
        .compensate_clock        ("CLK0"),
        .inclk0_input_frequency  (20000),          // period in ps = 50 MHz
        .intended_device_family  ("Cyclone IV E"),
        .lpm_hint                ("CBX_MODULE_PREFIX=audio_pll"),
        .lpm_type                ("altpll"),
        .operation_mode          ("NORMAL"),
        .pll_type                ("AUTO"),
        .port_inclk0             ("PORT_USED"),
        .port_clk0               ("PORT_USED"),
        .port_locked             ("PORT_USED"),
        .port_areset             ("PORT_UNUSED"),
        .port_inclk1             ("PORT_UNUSED"),
        .port_clk1               ("PORT_UNUSED"),
        .port_clk2               ("PORT_UNUSED"),
        .port_clk3               ("PORT_UNUSED"),
        .port_clk4               ("PORT_UNUSED"),
        .width_clock             (5)
    ) u_pll (
        .inclk  ({1'b0, inclk0}),
        .clk    (clk_out),
        .locked (locked)
    );

endmodule
