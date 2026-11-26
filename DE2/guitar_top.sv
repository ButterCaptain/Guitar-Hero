import highway_pkg::*;

module guitar_top #(
    // Pin polarity of the player inputs. The strum buttons are active-low
    // (pressed = 0, like KEY[1]/KEY[2] and the guitar's strum switches); the
    // old DE2 top inverted them with ~KEY[1] / ~KEY[2]. Set FRET_ACTIVE_LOW
    // if the frets are wired to active-low buttons instead of switches.
    parameter bit STRUM_ACTIVE_LOW = 1'b1,
    parameter bit FRET_ACTIVE_LOW  = 1'b0,
    // A strum button must hold a new level this many clocks before it counts
    // (250_000 = 5 ms at 50 MHz). Swallows switch bounce, which otherwise
    // shows up as extra strums -- usually on release -- and costs -5 each.
    parameter int DEBOUNCE_CYCLES  = 250_000
) (
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

    // Player inputs: convert to active-high and pass through two flip-flops.
    // The buttons are asynchronous to CLOCK_50; the synchronizer keeps the
    // strum edge detector in hit_detect from seeing a metastable value.
    //
    // Without the inversion, an idle active-low strum button reads 1, so
    // (strum_up | strum_down) is stuck at 1 and no strum edge ever reaches
    // hit_detect -- only hold-line scoring, which needs no strum, works.
    logic [6:0] in_sync1, in_sync2;
    logic [4:0] fret_s;
    logic       strum_up_s, strum_down_s;

    always_ff @(posedge CLOCK_50) begin
        in_sync1 <= { strum_down ^ STRUM_ACTIVE_LOW,
                      strum_up   ^ STRUM_ACTIVE_LOW,
                      fret       ^ {5{FRET_ACTIVE_LOW}} };
        in_sync2 <= in_sync1;
    end

    assign fret_s = in_sync2[4:0];

    // Strum debounce: the output follows the input only after the input has
    // stayed at its new level for DEBOUNCE_CYCLES clocks in a row.
    logic [1:0] strum_sync, strum_db;
    logic [$clog2(DEBOUNCE_CYCLES+1)-1:0] db_cnt [0:1];
    assign strum_sync = in_sync2[6:5];      // {down, up}

    always_ff @(posedge CLOCK_50) begin
        for (int i = 0; i < 2; i++) begin
            if (rst) begin
                strum_db[i] <= 1'b0;
                db_cnt[i]   <= '0;
            end
            else if (strum_sync[i] == strum_db[i]) begin
                db_cnt[i] <= '0;                      // no change pending
            end
            else if (db_cnt[i] == DEBOUNCE_CYCLES - 1) begin
                strum_db[i] <= strum_sync[i];         // stable long enough
                db_cnt[i]   <= '0;
            end
            else begin
                db_cnt[i] <= db_cnt[i] + 1'b1;
            end
        end
    end

    assign strum_up_s   = strum_db[0];
    assign strum_down_s = strum_db[1];

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
    assign LEDR       = {audio_status, 5'd0, fret_s};
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
        .frets       (fret_s),
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
        .HIT_WINDOW (4),   // frames before the line a strum still counts
        .LATE_WINDOW(3)    // frames after the line a strum still counts
    ) hit_unit (
        .clk50       (CLOCK_50),
        .rst         (game_rst),
        .frame_tick  (frame_tick),
        .fret        (fret_s),
        .strum_up    (strum_up_s),
        .strum_down  (strum_down_s),
        .slots       (slots),
        .hold_line   (hold_line),
        .score       (score)
    );

endmodule