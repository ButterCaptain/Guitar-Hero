// =========================================================================
//  vga_sync.sv -- 640x480 @ 60 Hz timing generator.  TARGET: Terasic DE2-115.
//
//  Runs off the 50 MHz board clock (CLOCK_50). The pixel clock is 25 MHz, so a
//  single toggle flop (pix_en) lets the counters advance on every OTHER clk50
//  edge. That matches tb_main.cpp, which calls tick() twice per vga.step().
//
//  THE DE2-115 NEEDS MORE THAN JUST SYNC PULSES. Unlike the DE0, whose VGA
//  connector was a passive resistor ladder, the DE2-115 drives a real ADV7123
//  video DAC chip, and that chip has its own control inputs:
//
//      VGA_CLK      the DAC latches R/G/B on this clock's rising edge. Must be
//                   the 25 MHz pixel clock, NOT the 50 MHz system clock.
//      VGA_BLANK_N  active LOW. Pull it low and the DAC outputs black, which is
//                   what the monitor needs during the porches.
//      VGA_SYNC_N   sync-on-green. Unused on this design -- tie it HIGH at the
//                   board top level.
//
//  We output vga_clk and blank_n here; the board top wires them to the pins.
//
//  x and y are the RAW counters (x: 0..799, y: 0..524), not just the visible
//  region. Everything the highway draws lives at x < 640 / y < 480 anyway, and
//  `visible` masks the rest, so raw counters are simpler and give a clean
//  single x==0 cycle per line for the scanline tracker in highway_draw.
// =========================================================================
module vga_sync (
    input  logic       clk50,
    input  logic       rst,
    output logic       hsync,
    output logic       vsync,
    output logic [9:0] x,
    output logic [9:0] y,
    output logic       visible,
    output logic       frame_tick,
    // ---- ADV7123 DAC control (DE2-115) -------------------------------------
    output logic       vga_clk,     // 25 MHz pixel clock, straight to VGA_CLK
    output logic       blank_n      // active low; drive VGA_BLANK_N with this
);

    // Horizontal: 640 visible, 16 front porch, 96 sync, 48 back porch = 800
    localparam int H_VIS = 640, H_FP = 16, H_SYNC = 96, H_BP = 48;
    localparam int H_TOTAL = H_VIS + H_FP + H_SYNC + H_BP;      // 800
    localparam int H_SYNC_START = H_VIS + H_FP;                 // 656
    localparam int H_SYNC_END   = H_VIS + H_FP + H_SYNC;        // 752

    // Vertical: 480 visible, 10 front porch, 2 sync, 33 back porch = 525
    localparam int V_VIS = 480, V_FP = 10, V_SYNC = 2, V_BP = 33;
    localparam int V_TOTAL = V_VIS + V_FP + V_SYNC + V_BP;      // 525
    localparam int V_SYNC_START = V_VIS + V_FP;                 // 490
    localparam int V_SYNC_END   = V_VIS + V_FP + V_SYNC;        // 492

    // 50 MHz -> 25 MHz pixel enable.
    logic pix_en;
    always_ff @(posedge clk50) begin
        if (rst) pix_en <= 1'b0;
        else     pix_en <= ~pix_en;
    end

    logic [9:0] h_cnt, v_cnt;

    always_ff @(posedge clk50) begin
        if (rst) begin
            h_cnt <= 10'd0;
            v_cnt <= 10'd0;
        end
        else if (pix_en) begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= 10'd0;
                v_cnt <= (v_cnt == V_TOTAL - 1) ? 10'd0 : v_cnt + 10'd1;
            end
            else begin
                h_cnt <= h_cnt + 10'd1;
            end
        end
    end

    always_comb begin
        x = h_cnt;
        y = v_cnt;

        // Both pulses are ACTIVE LOW, which is what vga_sim.h expects for the
        // 640x480 mode (sync_active_low = true).
        hsync = ~((h_cnt >= H_SYNC_START) && (h_cnt < H_SYNC_END));
        vsync = ~((v_cnt >= V_SYNC_START) && (v_cnt < V_SYNC_END));

        visible = (h_cnt < H_VIS) && (v_cnt < V_VIS);

        // One pulse per frame, on the first cycle of vertical blanking. This is
        // the heartbeat the note loader and the hit-detect FSM should run on.
        frame_tick = pix_en && (h_cnt == 10'd0) && (v_cnt == V_VIS[9:0]);

        // The DAC blanks on LOW, so this is just `visible` inverted.
        blank_n = visible;

        // The DAC samples colour on the RISING edge of VGA_CLK. pix_en toggles
        // at 25 MHz, so feeding it out directly gives the DAC a clock whose
        // rising edge lands in the middle of each stable pixel. Driving a clock
        // from a register like this is fine for a 25 MHz DAC strobe; Quartus
        // will warn that it is not on a global clock network, which is expected
        // and harmless here.
        vga_clk = pix_en;
    end

endmodule
