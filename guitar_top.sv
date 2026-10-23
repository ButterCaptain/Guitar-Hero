module guitar_top (
    input  logic        clk50,
    input  logic        rst,
    input  logic [4:0]  fret,         // active-high: 1 = held
    input  logic        strum_up,     // active-high
    input  logic        strum_down,   // active-high
    output logic        hsync,
    output logic        vsync,
    output logic [3:0]  r, g, b,
    output logic [15:0] score         // binary, saturates at 9999
);
    logic [9:0] x, y;
    logic       visible, frame_tick;
	// moses was here
    vga_sync sync (.clk50, .rst, .hsync, .vsync, .x, .y, .visible, .frame_tick);

    // ---- Strum: two pins, one action, detected as an edge ----
    logic strum, strum_prev;
    assign strum = strum_up | strum_down;

    always_ff @(posedge clk50)
        strum_prev <= rst ? 1'b0 : strum;

    wire strum_edge = strum & ~strum_prev;   // high for exactly one clock

    // ---- Lanes ----
    localparam int NUM_LANES = 5;
    localparam int LANE_W    = 100;
    localparam int LANE_X0   = (640 - NUM_LANES * LANE_W) / 2;
    localparam int ZONE_Y0   = 400;
    localparam int ZONE_Y1   = 420;

    localparam logic [11:0] LANE_COLOR [NUM_LANES] =
        '{12'h0F0, 12'hF00, 12'hFF0, 12'h00F, 12'hF80};

    logic [NUM_LANES-1:0] note_px, zone_px, hit;

    genvar i;
    generate
        for (i = 0; i < NUM_LANES; i++) begin : lane
            localparam int LX = LANE_X0 + i * LANE_W;

            note_box #(
                .X_POS  (LX + 30),
                .BOX_W  (40),
                .BOX_H  (40),
                .START_Y(i * 90),
                .ZONE_Y0(ZONE_Y0),
                .ZONE_Y1(ZONE_Y1)
            ) nb (
                .clk50, .rst, .frame_tick, .x, .y,
                .fret_held (fret[i]),
                .strum_edge(strum_edge),
                .in_box    (note_px[i]),
                .hit       (hit[i])
            );

            assign zone_px[i] = (x >= LX + 10) && (x < LX + LANE_W - 10) &&
                                (y >= ZONE_Y0) && (y < ZONE_Y1);
        end
    endgenerate

    // ---- Score (not displayed yet) ----
    wire [2:0] hit_cnt = 3'($countones(hit));   // several lanes can hit at once

    always_ff @(posedge clk50) begin
        if (rst)
            score <= 16'd0;
        else if (hit_cnt != 0)
            score <= (score + hit_cnt > 9999) ? 16'd9999 : score + hit_cnt;
    end

    // ---- Drawing ----
    wire strum_px = strum &&
                    (x >= LANE_X0) && (x < LANE_X0 + NUM_LANES * LANE_W) &&
                    (y >= 430) && (y < 440);

    always_comb begin
        {r, g, b} = 12'h111;
        if (strum_px) {r, g, b} = 12'hFFF;
        for (int k = 0; k < NUM_LANES; k++) begin
            if (zone_px[k])
                {r, g, b} = fret[k] ? LANE_COLOR[k]
                                    : ((LANE_COLOR[k] >> 2) & 12'h333);
            if (note_px[k])
                {r, g, b} = LANE_COLOR[k];
        end
        if (!visible) {r, g, b} = 12'h000;
    end
endmodule
