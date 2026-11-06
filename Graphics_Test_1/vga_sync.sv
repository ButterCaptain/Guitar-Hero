// =========================================================================
//  vga_sync.sv -- 640x480 @ 60 Hz timing generator.
//
//  Runs off the 50 MHz board clock. The pixel clock is 25 MHz, so a single
//  toggle flop (pix_en) lets the counters advance on every OTHER clk50 edge.
//  That matches tb_main.cpp, which calls tick() twice per vga.step().
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
    output logic       frame_tick
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
    end

endmodule
