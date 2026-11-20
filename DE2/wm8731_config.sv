// ============================================================================
//  wm8731_config.sv -- sets up the DE2-115's audio chip (Wolfson WM8731) over
//  its two-wire I2C control bus.
//
//  The WM8731 powers up muted and switched off. Before it will make a sound
//  we have to write ten of its registers. Each write is one I2C transaction
//  of three bytes:
//
//      START  0x34(+ACK)  {reg[6:0], data[8]}(+ACK)  data[7:0](+ACK)  STOP
//
//  0x34 is the chip's address on the DE2-115. Registers are 7 bits wide by
//  address and 9 bits wide by data, which is why the 9th data bit rides along
//  in the second byte.
//
//  HOW THE CHIP IS SET UP
//  ----------------------
//  The FPGA feeds the chip a 12.000 MHz master clock (from audio_pll). The
//  WM8731 has a "USB mode" made for exactly that clock: it divides 12 MHz by
//  250 to get exactly 48 kHz, or by 272 to get 44.118 kHz (0.04% fast for a
//  44.1 kHz song -- about 70 ms over 3 minutes). That is why 48 kHz files are
//  preferred.
//
//  The chip is a SLAVE: the FPGA (i2s_out.sv) drives the bit clock and the
//  left/right clock, and the chip just listens.
//
//  I2C TIMING
//  ----------
//  Each bit is split into four quarters. SDA only changes while SCL is low;
//  START and STOP are the two special cases where SDA changes while SCL is
//  high.
//
//          quarter:   0     1     2     3
//          SCL:      ___   ___________   ___
//                       |_|           |_|        (low, high, high, low)
//          SDA:      <bit>=============          (set in quarter 0)
//
//  SDA is open drain: we only ever pull it LOW or let go (high-Z). The board
//  has a pull-up resistor that makes it read 1 when nobody pulls it down. That
//  is how the chip can answer ACK (pull low) on the same wire.
// ============================================================================

module wm8731_config #(
    parameter int CLK_HZ = 50_000_000,
    parameter int I2C_HZ = 100_000,
    // Headphone / line-out volume. 0x79 = 0 dB, each step down is -1 dB,
    // 0x30 or less = mute.
    parameter logic [6:0] VOLUME = 7'h79
)(
    input  logic clk,
    input  logic rst,

    input  logic start,        // hold high to start (once the WAV header is read)
    input  logic rate_44k,     // 1 = 44.1 kHz, 0 = 48 kHz

    output logic done,         // all registers written
    output logic nack,         // the chip did not answer at least once

    output logic i2c_sclk,
    inout  wire  i2c_sdat
);

    // ---- the register list -------------------------------------------------
    localparam int N_REGS = 10;

    function automatic logic [15:0] reg_word(input logic [3:0] i, input logic r44);
        // {7-bit register address, 9-bit value}
        case (i)
            4'd0: reg_word = {7'h0F, 9'h000};           // reset everything
            4'd1: reg_word = {7'h06, 9'h067};           // power: DAC + output on, rest off
            4'd2: reg_word = {7'h00, 9'h080};           // left  line in: mute (unused)
            4'd3: reg_word = {7'h01, 9'h080};           // right line in: mute (unused)
            4'd4: reg_word = {7'h02, {2'b01, VOLUME}};  // output volume, both channels
            4'd5: reg_word = {7'h04, 9'h012};           // analog path: DAC -> output, mic muted
            4'd6: reg_word = {7'h05, 9'h000};           // digital path: DAC not muted
            4'd7: reg_word = {7'h07, 9'h002};           // format: I2S, 16 bit, chip is slave
            4'd8: reg_word = {7'h08, r44 ? 9'h023       // USB mode, 44.118 kHz
                                         : 9'h001};     // USB mode, 48 kHz
            default: reg_word = {7'h09, 9'h001};        // activate (must be last)
        endcase
    endfunction

    // ---- quarter-bit tick --------------------------------------------------
    localparam int QTR = CLK_HZ / (4 * I2C_HZ);
    logic [$clog2(QTR+1)-1:0] div;
    logic tick;
    assign tick = (div == QTR - 1);

    // ---- sequencer ---------------------------------------------------------
    // One transaction is 120 quarter-steps:
    //   0..2      START       (SDA high, SDA low, SCL low)
    //   3..110    27 bits x 4 quarters  (3 bytes, each followed by an ACK slot)
    //   111..113  STOP        (SDA low, SCL high, SDA high)
    //   114..119  idle gap
    localparam int STEPS = 120;

    logic [6:0]  step;
    logic [3:0]  idx;          // which register
    logic        busy;

    logic [15:0] word;
    logic [26:0] bits;         // 1 in an ACK slot = let go of SDA
    assign word = reg_word(idx, rate_44k);
    assign bits = {8'h34, 1'b1, word[15:8], 1'b1, word[7:0], 1'b1};

    logic [6:0] b_step;        // step - 3
    logic [4:0] b_idx;         // which of the 27 bits
    logic [1:0] b_q;           // which quarter of that bit
    assign b_step = step - 7'd3;
    assign b_idx  = b_step[6:2];
    assign b_q    = b_step[1:0];

    logic scl_c, sda_c;        // what SCL / SDA should be right now (1 = released)

    always_comb begin
        scl_c = 1'b1;
        sda_c = 1'b1;
        if (busy) begin
            if (step == 0)           begin scl_c = 1'b1; sda_c = 1'b1; end
            else if (step == 1)      begin scl_c = 1'b1; sda_c = 1'b0; end   // START
            else if (step == 2)      begin scl_c = 1'b0; sda_c = 1'b0; end
            else if (step < 111)     begin
                scl_c = (b_q == 2'd1 || b_q == 2'd2);
                sda_c = bits[26 - b_idx];
            end
            else if (step == 111)    begin scl_c = 1'b0; sda_c = 1'b0; end
            else if (step == 112)    begin scl_c = 1'b1; sda_c = 1'b0; end
            else                     begin scl_c = 1'b1; sda_c = 1'b1; end   // STOP, gap
        end
    end

    // Is this the quarter where we read the chip's ACK? (bits 8, 17, 26)
    logic ack_slot;
    assign ack_slot = busy && step >= 3 && step < 111 && b_q == 2'd2
                   && (b_idx == 5'd8 || b_idx == 5'd17 || b_idx == 5'd26);

    logic sda_drive_low;
    assign i2c_sdat = sda_drive_low ? 1'b0 : 1'bz;

    always_ff @(posedge clk) begin
        if (rst) begin
            div           <= '0;
            step          <= '0;
            idx           <= '0;
            busy          <= 1'b0;
            done          <= 1'b0;
            nack          <= 1'b0;
            i2c_sclk      <= 1'b1;
            sda_drive_low <= 1'b0;
        end
        else begin
            div <= tick ? '0 : div + 1'b1;

            // Outputs are registered so SCL and SDA never glitch.
            i2c_sclk      <= scl_c;
            sda_drive_low <= ~sda_c;

            if (!busy && !done && start) begin
                busy <= 1'b1;
                step <= '0;
                idx  <= '0;
            end
            else if (busy && tick) begin
                // Sample ACK at the END of the quarter, when SCL has been
                // high for a full quarter. 1 = nobody pulled it low = NACK.
                if (ack_slot && i2c_sdat) nack <= 1'b1;

                if (step == STEPS - 1) begin
                    step <= '0;
                    if (idx == N_REGS - 1) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                    else idx <= idx + 1'b1;
                end
                else step <= step + 1'b1;
            end
        end
    end

endmodule
