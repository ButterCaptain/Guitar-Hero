import highway_pkg::*;

module guitar_top (
    // Clock 
    input  logic        CLOCK_50,

    // User input
    input  logic [4:0] fret,
    input  logic       strum_up,
    input  logic       strum_down,
    input  logic       rst_n,

    // VGA
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_CLK,
    output logic        VGA_BLANK_N,
    output logic        VGA_SYNC_N,
    output logic        VGA_HS,
    output logic        VGA_VS,

    // 7-segment score display
    output logic [6:0]  HEX0, HEX1, HEX2, HEX3,

    // SD card slot (1-bit SD mode)
    output logic        SD_CLK,
    inout  wire         SD_CMD,
    inout  wire  [3:0]  SD_DAT,

    // WM8731 audio chip
    output logic        AUD_XCK,
    output logic        AUD_BCLK,
    output logic        AUD_DACLRCK,
    output logic        AUD_DACDAT,
    output logic        I2C_SCLK,
    inout  wire         I2C_SDAT,

    // LEDs
    output logic [17:0] LEDR,
    output logic [8:0]  LEDG
);

    // Active-low button for rst
    logic rst;
    assign rst = ~rst_n;

    // Audio subsystem 
    logic clk_aud, pll_locked;
    logic audio_playing, audio_failed;
    logic [7:0] audio_status;

    audio_pll u_pll (
        .inclk0 (CLOCK_50),
        .c0     (clk_aud),
        .locked (pll_locked)
    );

    audio_top #(
        .FILE_NAME_LEN (8),
        .FILE_NAME     ("song.wav")
    ) u_audio (
        .clk50       (CLOCK_50),
        .rst         (rst | ~pll_locked),
        .clk_aud     (clk_aud),
        .sd_clk      (SD_CLK),
        .sd_cmd      (SD_CMD),
        .sd_dat0     (SD_DAT[0]),
        .aud_xck     (AUD_XCK),
        .aud_bclk    (AUD_BCLK),
        .aud_daclrck (AUD_DACLRCK),
        .aud_dacdat  (AUD_DACDAT),
        .i2c_sclk    (I2C_SCLK),
        .i2c_sdat    (I2C_SDAT),
        .playing     (audio_playing),
        .failed      (audio_failed),
        .status      (audio_status)
    );

    assign SD_DAT = 4'b111z;

    logic game_rst;
    assign game_rst = rst | ~(audio_playing | audio_failed);

    // Score & LEDs 
    logic signed [15:0] score;

    score_top u_score (
        .score_in (score),
        .seg0     (HEX0),
        .seg1     (HEX1),
        .seg2     (HEX2),
        .seg3     (HEX3)
    );

    assign VGA_SYNC_N = 1'b1;
    assign LEDR       = {audio_status, 5'd0, fret};
    assign LEDG       = score[8:0];

    // Core Game Logic
    logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots;

    // Frame Tick and Frame number
    logic frame_tick;
    logic [14:0] frame_count;

    logic song_done;

    // hold line control line
    logic [N_LANES-1:0] hold_line;

    logic        effect_fire;
    logic [31:0] effect_word;

    highway_draw draw_unit (
        .clk50       (CLOCK_50),
        .rst         (game_rst),
        .slots       (slots),
        .frets       (fret),
        .hsync       (VGA_HS),
        .vsync       (VGA_VS),
        .vga_clk     (VGA_CLK),
        .blank_n     (VGA_BLANK_N),
        .frame_tick  (frame_tick),
        .vga_r       (VGA_R),
        .vga_g       (VGA_G),
        .vga_b       (VGA_B),
        .hold_line   (hold_line),
        .effect_fire (effect_fire),
        .effect_word (effect_word)
    );

    note_feeder #(
        .HEXFILE("notes.hex"),
        .ADDR_W (11)
    ) feeder (
        .clk50       (CLOCK_50),
        .rst         (game_rst),
        .frame_tick  (frame_tick),
        .slots       (slots),
        .frame_count (frame_count),
        .song_done   (song_done),
        .effect_fire (effect_fire),
        .effect_word (effect_word)
    );

    hit_detect #(
        .HIT_WINDOW(4)
    ) hit_unit (
        .clk50       (CLOCK_50),
        .rst         (game_rst),
        .frame_tick  (frame_tick),
        .fret        (fret),
        .strum_up    (strum_up),
        .strum_down  (strum_down),
        .slots       (slots),
        .hold_line   (hold_line),
        .score       (score)
    );

endmodule