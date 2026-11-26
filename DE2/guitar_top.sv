import highway_pkg::*;

module guitar_top #(
    // Fret polarity. Set to 1 if the frets are wired to active-low buttons
    // instead of switches. (The strum buttons need no setting: their idle
    // level is learned at power-up / reset -- see "Player inputs" below.)
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

    // ---- Player inputs -----------------------------------------------------
    // 1. Two flip-flops: the buttons are asynchronous to CLOCK_50, and the
    //    strum edge detector must never see a metastable value.
    logic [6:0] in_sync1, in_sync2;
    logic [4:0] fret_s;
    logic       strum_up_s, strum_down_s;

    always_ff @(posedge CLOCK_50) begin
        in_sync1 <= {strum_down, strum_up, fret ^ {5{FRET_ACTIVE_LOW}}};
        in_sync2 <= in_sync1;
    end

    assign fret_s = in_sync2[4:0];

    // 2. Strum polarity, learned. For the first 255 clocks after power-up and
    //    after every reset we record each strum pin's level as "not pressed";
    //    afterwards "pressed" means "different from that". So active-low and
    //    active-high buttons both work, and a pin that never changes (wrong
    //    pin, not wired) simply never strums -- it can no longer block the
    //    other strum button. Don't hold the strum bar while pressing reset.
    logic [7:0] cal_cnt = '0;           // power-up value: calibrate at configuration
    logic [1:0] strum_idle = '0;        // {down, up} level when not pressed
    logic [1:0] strum_sync;             // {down, up}, 1 = pressed

    always_ff @(posedge CLOCK_50) begin
        if (rst)                cal_cnt <= '0;
        else if (cal_cnt != '1) cal_cnt <= cal_cnt + 1'b1;

        if (cal_cnt != '1) strum_idle <= in_sync2[6:5];
    end

    assign strum_sync = (cal_cnt != '1) ? 2'b00 : (in_sync2[6:5] ^ strum_idle);

    // 3. Debounce: each strum output follows its input only after the input
    //    has stayed at its new level for DEBOUNCE_CYCLES clocks in a row.
    logic [1:0] strum_db;
    logic [$clog2(DEBOUNCE_CYCLES+1)-1:0] db_cnt [0:1];

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
    // ---- Debug LEDs for the strum path (LEDR[9:5]) --------------------------
    // Read them left to right to find where a strum gets lost:
    //   LEDR[5]  strum UP   pressed (after polarity learning + debounce)
    //   LEDR[6]  strum DOWN pressed
    //   LEDR[7]  flips every time hit_detect judges a strum
    //   LEDR[8]  lights ~1/4 s when a strum scores a hit (+10)
    //   LEDR[9]  on while a note is inside the hit window
    // LEDR[4:0] are the frets, LEDR[17:10] the audio status.
    logic dbg_strum_judged, dbg_hit, dbg_note_in_zone;
    logic strum_toggle;
    logic [23:0] hit_led_cnt;   // 12.5 M clocks = 0.25 s

    always_ff @(posedge CLOCK_50) begin
        if (game_rst) begin
            strum_toggle <= 1'b0;
            hit_led_cnt  <= '0;
        end
        else begin
            if (dbg_strum_judged) strum_toggle <= ~strum_toggle;
            if (dbg_hit)                hit_led_cnt <= 24'd12_500_000;
            else if (hit_led_cnt != '0) hit_led_cnt <= hit_led_cnt - 1'b1;
        end
    end

    assign LEDR = {audio_status,
                   dbg_note_in_zone, (hit_led_cnt != '0), strum_toggle,
                   strum_down_s, strum_up_s,
                   fret_s};
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
        .LATE_WINDOW(3),   // frames after the line a strum still counts
        .HOLD_FRAMES(10)   // hold this many frames for each +1 (60 frames = 1 s)
    ) hit_unit (
        .clk50       (CLOCK_50),
        .rst         (game_rst),
        .frame_tick  (frame_tick),
        .fret        (fret_s),
        .strum_up    (strum_up_s),
        .strum_down  (strum_down_s),
        .slots       (slots),
        .hold_line   (hold_line),
        .score       (score),
        .dbg_strum_judged (dbg_strum_judged),
        .dbg_hit          (dbg_hit),
        .dbg_note_in_zone (dbg_note_in_zone)
    );

endmodule