module vga_sync (
    input  logic       clk50,
    input  logic       rst,
    output logic       hsync,
    output logic       vsync,
    output logic [9:0] x, y,
    output logic       visible,
    output logic       frame_tick   // 1 clk50 pulse per frame, during vblank
);
    logic pix_en;
    always_ff @(posedge clk50)
        pix_en <= rst ? 1'b0 : ~pix_en;

    logic [9:0] hcount, vcount;

    always_ff @(posedge clk50) begin
        if (rst) begin
            hcount <= 0;
            vcount <= 0;
        end else if (pix_en) begin
            if (hcount == 799) begin
                hcount <= 0;
                vcount <= (vcount == 524) ? 10'd0 : vcount + 1'b1;
            end else
                hcount <= hcount + 1'b1;
        end
    end

    assign hsync   = ~(hcount >= 656 && hcount < 752);
    assign vsync   = ~(vcount >= 490 && vcount < 492);
    assign visible = (hcount < 640) && (vcount < 480);
    assign x = hcount;
    assign y = vcount;

    // First pixel-clock of line 480 = first line after the visible area
    assign frame_tick = pix_en && (hcount == 0) && (vcount == 480);
endmodule