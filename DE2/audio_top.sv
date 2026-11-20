// ============================================================================
//  audio_top.sv -- plays a .wav file from the SD card through the DE2-115's
//  audio chip.
//
//      SD card --> sd_file_reader --> wav_parser --> audio_fifo --> i2s_out --> WM8731
//                  (sd_card/, finds    (header,      (85 ms of      (12 MHz     (LINE OUT
//                   the file, bytes)    samples)      buffer)        domain)     jack)
//                        ^                                  |
//                        +---------- pause when full -------+
//
//                                          wm8731_config --I2C--> WM8731 (setup)
//
//  STARTUP ORDER
//  -------------
//    1. sd_file_reader starts the card, finds the FAT partition and the file.
//    2. wav_parser reads the header. Once it reaches the audio, it tells
//       wm8731_config the sample rate and the chip gets set up.
//    3. Samples pile up in the FIFO. As soon as the chip is set up AND the
//       FIFO is half full, `playing` goes high and the sound starts.
//
//  `playing` is what the top level uses to start the game, so the first note
//  and the first sample leave at the same moment.
//
//  If anything goes wrong (no card, file missing, not a 16-bit 44.1/48 kHz
//  WAV, or nothing has happened after TIMEOUT_CYCLES), `failed` goes high
//  instead, so the game can still run, just silently.
//
//  The SD card is read in 1-bit SD mode, not SPI. DAT1..DAT3 must sit high or
//  the card will switch itself into SPI mode; the top level ties them high.
// ============================================================================

module audio_top #(
    // The file to play, in the card's top folder. Case does not matter.
    // FILE_NAME_LEN must be the number of characters in FILE_NAME.
    parameter int            FILE_NAME_LEN  = 8,
    parameter logic [52*8-1:0] FILE_NAME    = "song.wav",
    parameter int            FIFO_AW        = 12,           // 4096 samples = 85 ms
    parameter int            TIMEOUT_CYCLES = 150_000_000,  // 3 s at 50 MHz
    parameter int            I2C_HZ         = 100_000,
    parameter logic [6:0]    VOLUME         = 7'h79,        // 0 dB, see wm8731_config
    parameter int            SIMULATE       = 0             // 1 = fast SD start-up, testbench only
)(
    input  logic        clk50,
    input  logic        rst,
    input  logic        clk_aud,        // 12.000 MHz from audio_pll

    // ---- SD card (1-bit SD mode) -------------------------------------------
    output logic        sd_clk,
    inout  wire         sd_cmd,
    input  logic        sd_dat0,

    // ---- WM8731 ----------------------------------------------------------
    output logic        aud_xck,
    output logic        aud_bclk,
    output logic        aud_daclrck,
    output logic        aud_dacdat,
    output logic        i2c_sclk,
    inout  wire         i2c_sdat,

    // ---- status ----------------------------------------------------------
    output logic        playing,        // sound has started
    output logic        failed,         // gave up; there will be no sound
    output logic [7:0]  status          // for LEDs, see the bottom of this file
);

    localparam int DEPTH = 1 << FIFO_AW;

    // ======================================================================
    //  SD card -> bytes
    // ======================================================================
    logic       sd_pause, sd_done, file_found;
    logic [1:0] card_type, fs_type;
    logic [3:0] card_stat;
    logic       byte_valid;
    logic [7:0] byte_data;

    sd_file_reader #(
        .FILE_NAME_LEN (FILE_NAME_LEN),
        .FILE_NAME     (FILE_NAME),
        .CLK_DIV       (3'd2),          // for a 25..50 MHz clk, per the core's notes
        .SIMULATE      (SIMULATE)
    ) u_sd (
        .rstn            (~rst),
        .clk             (clk50),
        .pause           (sd_pause),
        .done            (sd_done),
        .sdclk           (sd_clk),
        .sdcmd           (sd_cmd),
        .sddat0          (sd_dat0),
        .card_stat       (card_stat),
        .card_type       (card_type),
        .filesystem_type (fs_type),
        .file_found      (file_found),
        .outen           (byte_valid),
        .outbyte         (byte_data)
    );

    // ======================================================================
    //  bytes -> samples
    // ======================================================================
    logic        s_valid, header_ok, rate_44k, wav_err, data_done;
    logic [31:0] s_data;

    wav_parser u_wav (
        .clk          (clk50),
        .rst          (rst),
        .in_valid     (byte_valid),
        .in_byte      (byte_data),
        .sample_valid (s_valid),
        .sample       (s_data),
        .header_ok    (header_ok),
        .rate_44k     (rate_44k),
        .err          (wav_err),
        .data_done    (data_done)
    );

    // ======================================================================
    //  FIFO
    // ======================================================================
    logic              fifo_rd, fifo_empty, fifo_full;
    logic [31:0]       fifo_q;
    logic [FIFO_AW:0]  fifo_count;

    audio_fifo #(.AW(FIFO_AW)) u_fifo (
        .clk     (clk50),
        .rst     (rst),
        .wr_en   (s_valid),
        .wr_data (s_data),
        .rd_en   (fifo_rd),
        .rd_data (fifo_q),
        .count   (fifo_count),
        .empty   (fifo_empty),
        .full    (fifo_full)
    );

    // Stop asking the card for more once there is less room left than one
    // sector could fill. A 512-byte sector of 16-bit MONO is 256 samples, and
    // one sector may already be on its way when we say stop, so keep 512 free.
    assign sd_pause = (fifo_count > DEPTH - 512);

    // ======================================================================
    //  chip setup
    // ======================================================================
    logic cfg_done, cfg_nack;

    wm8731_config #(
        .CLK_HZ (50_000_000),
        .I2C_HZ (I2C_HZ),
        .VOLUME (VOLUME)
    ) u_cfg (
        .clk      (clk50),
        .rst      (rst),
        .start    (header_ok),
        .rate_44k (rate_44k),
        .done     (cfg_done),
        .nack     (cfg_nack),
        .i2c_sclk (i2c_sclk),
        .i2c_sdat (i2c_sdat)
    );

    // ======================================================================
    //  start / give up
    // ======================================================================
    logic [$clog2(TIMEOUT_CYCLES+1)-1:0] timer;
    logic timed_out;

    always_ff @(posedge clk50) begin
        if (rst) begin
            playing   <= 1'b0;
            timer     <= '0;
            timed_out <= 1'b0;
        end
        else begin
            // Once we have given up, stay given up: the game has already
            // started without us and sound now would be out of sync.
            if (!playing && !failed && cfg_done &&
                (fifo_count >= DEPTH / 2 || data_done || sd_done))
                playing <= 1'b1;

            if (!playing) begin
                if (timer == TIMEOUT_CYCLES) timed_out <= 1'b1;
                else                         timer     <= timer + 1'b1;
            end
        end
    end

    // The reader stopping before we ever reached the audio means it never
    // found the file (or the card / filesystem was not usable).
    assign failed = !playing && (wav_err || timed_out || (sd_done && !header_ok));

    // ======================================================================
    //  FIFO -> i2s_out (50 MHz -> 12 MHz)
    // ======================================================================
    logic        req_toggle;
    logic [2:0]  req_sync;        // 2 flops to tame metastability + 1 to find the edge
    logic        rd_pending;
    logic [31:0] sample_hold;
    logic        underrun;

    always_ff @(posedge clk50) begin
        if (rst) begin
            req_sync    <= '0;
            rd_pending  <= 1'b0;
            sample_hold <= '0;
            underrun    <= 1'b0;
        end
        else begin
            req_sync   <= {req_sync[1:0], req_toggle};
            rd_pending <= fifo_rd;
            // The FIFO answers one cycle after we ask.
            if (rd_pending) sample_hold <= fifo_q;
            // i2s_out just took sample_hold. Load the next one -- or silence if
            // we are not playing yet, or the card fell behind.
            else if (req_sync[2] != req_sync[1] && !fifo_rd) begin
                if (!playing || fifo_empty) sample_hold <= '0;
                if (playing && fifo_empty && !data_done && !sd_done) underrun <= 1'b1;
            end
        end
    end

    assign fifo_rd = playing && !fifo_empty && (req_sync[2] != req_sync[1]);

    i2s_out u_i2s (
        .clk_aud    (clk_aud),
        .rst        (rst),
        .rate_44k   (rate_44k),
        .sample     (sample_hold),
        .req_toggle (req_toggle),
        .dac_lrck   (aud_daclrck),
        .dac_dat    (aud_dacdat)
    );

    // The chip's master clock and bit clock are both the 12 MHz clock itself.
    assign aud_xck  = clk_aud;
    assign aud_bclk = clk_aud;

    // ======================================================================
    //  status, for LEDs
    // ======================================================================
    //   [0] card answered and was set up       [4] chip setup finished
    //   [1] FAT16 / FAT32 found                [5] chip did not ACK (wiring?)
    //   [2] file found                         [6] buffer ran dry while playing
    //   [3] WAV header OK (16 bit, 44.1/48k)   [7] WAV not playable
    assign status = { wav_err, underrun, cfg_nack, cfg_done,
                      header_ok, file_found, fs_type >= 2'd2, card_type != 2'd0 };

endmodule
