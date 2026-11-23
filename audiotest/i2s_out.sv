// ============================================================================
//  i2s_out.sv -- sends samples to the WM8731 audio chip, one bit at a time.
//
//  This is the only audio module that does NOT run on the 50 MHz clock. It
//  runs on the 12 MHz audio clock from audio_pll, because the chip's sample
//  timing must be locked exactly to its own master clock (AUD_XCK).
//
//  THE WIRES (all driven by us, the chip is a slave)
//  ---------
//    AUD_XCK      12 MHz master clock      = clk_aud
//    AUD_BCLK     bit clock                = clk_aud as well (12 MHz)
//    AUD_DACLRCK  left/right clock         low = left sample, high = right
//    AUD_DACDAT   the data bit
//
//  ONE SAMPLE PERIOD (48 kHz: 250 bit clocks, 44.1 kHz: 272)
//  ------------------------------------------------------
//    bit clock #   0    1 .. 16       17 .. 124   125   126 .. 141     ...
//    DACLRCK       0    0              0           1     1
//    DACDAT        0    L[15] .. L[0]  0           0     R[15] .. R[0]  0
//
//  This is standard I2S: the first data bit comes ONE bit clock after the
//  left/right clock changes. We only need 16 bits per side and have 125, so
//  the rest is padding zeros -- the chip ignores them.
//
//  WHY NEGEDGE
//  -----------
//  The chip reads DACDAT and DACLRCK on the RISING edge of the bit clock. So
//  we change them on the FALLING edge, giving them half a clock (42 ns) to
//  settle before they are read.
//
//  CROSSING FROM 50 MHz
//  --------------------
//  `sample` comes from the 50 MHz side. At the start of every sample period we
//  copy it into our shift register and flip `req_toggle`. The 50 MHz side sees
//  the flip a few cycles later and puts the NEXT sample into `sample`. It then
//  sits still for ~20 us until we copy it again, so we never read it while it
//  is changing.
// ============================================================================

module i2s_out (
    input  logic        clk_aud,       // 12 MHz
    input  logic        rst,           // async, any clock domain

    input  logic        rate_44k,      // 1 = 44.118 kHz, 0 = 48 kHz (slow-changing)
    input  logic [31:0] sample,        // {left, right}, from the 50 MHz side
    output logic        req_toggle,    // flips once per sample period

    output logic        dac_lrck,
    output logic        dac_dat
);

    // ---- reset and rate, brought into this clock domain --------------------
    logic [1:0] rst_sync;
    logic       rst_a;
    always_ff @(negedge clk_aud or posedge rst) begin
        if (rst) rst_sync <= 2'b11;
        else     rst_sync <= {rst_sync[0], 1'b0};
    end
    assign rst_a = rst_sync[1];

    logic [1:0] rate_sync;
    always_ff @(negedge clk_aud) rate_sync <= {rate_sync[0], rate_44k};

    // ---- frame counter -----------------------------------------------------
    logic [8:0] last, half;
    assign last = rate_sync[1] ? 9'd271 : 9'd249;
    assign half = rate_sync[1] ? 9'd136 : 9'd125;

    logic [8:0]  cnt, cnt_n;
    // `>=` rather than `==` so a change of rate can never strand the counter
    // above `last`.
    assign cnt_n = (cnt >= last) ? 9'd0 : cnt + 9'd1;

    logic [31:0] shreg;

    always_ff @(negedge clk_aud) begin
        if (rst_a) begin
            cnt        <= '0;
            shreg      <= '0;
            req_toggle <= 1'b0;
            dac_lrck   <= 1'b0;
            dac_dat    <= 1'b0;
        end
        else begin
            cnt <= cnt_n;

            if (cnt_n == 9'd0) begin
                shreg      <= sample;
                req_toggle <= ~req_toggle;
            end

            dac_lrck <= (cnt_n >= half);

            if (cnt_n >= 9'd1 && cnt_n <= 9'd16)
                dac_dat <= shreg[9'd32 - cnt_n];             // L[15] .. L[0]
            else if (cnt_n >= half + 9'd1 && cnt_n <= half + 9'd16)
                dac_dat <= shreg[9'd16 + half - cnt_n];      // R[15] .. R[0]
            else
                dac_dat <= 1'b0;
        end
    end

endmodule
