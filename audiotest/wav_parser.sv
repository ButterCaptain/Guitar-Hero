// ============================================================================
//  wav_parser.sv -- turns the raw bytes of a .wav file into audio samples.
//
//  The SD card reader (sd_card/sd_file_reader.v) hands us the file one byte at
//  a time, with no idea what is in it. This module understands the WAV format:
//  it checks the header, pulls out the sample rate / channels / bit depth, and
//  then turns the audio bytes into one {left, right} pair per sample.
//
//  WHAT A WAV FILE LOOKS LIKE
//  --------------------------
//  A WAV is a "RIFF" file: a 12-byte header followed by a list of CHUNKS. Every
//  chunk is a 4-letter name, a 4-byte length, then that many bytes of body.
//  All numbers are LITTLE ENDIAN (lowest byte first).
//
//      "RIFF" <file size> "WAVE"          <- 12-byte file header
//      "fmt " <16>  <the format, below>   <- tells us how to read the audio
//      "LIST" <n>   <n bytes>             <- optional junk (song title, ...)
//      "data" <n>   <n bytes of audio>    <- the samples themselves
//
//  The fmt body we care about:
//      bytes 0-1   format      1 = plain PCM (0xFFFE "extensible" also allowed)
//      bytes 2-3   channels    1 = mono, 2 = stereo
//      bytes 4-7   sample rate 44100 or 48000
//      bytes 14-15 bits        must be 16
//
//  Chunks we do not know (LIST, fact, ...) are skipped by counting off their
//  length. A chunk with an odd length has one padding byte after it.
//
//  The audio in a 16-bit stereo file is L_lo L_hi R_lo R_hi L_lo L_hi ...
//  A mono file is just S_lo S_hi S_lo S_hi ..., and we send each sample to BOTH
//  speakers.
//
//  "44.1 kHz" here really plays at 44.118 kHz -- see wm8731_config.sv. 48 kHz is
//  exact, so prefer 48 kHz files.
// ============================================================================

module wav_parser (
    input  logic        clk,
    input  logic        rst,

    // ---- bytes from the SD card reader -----------------------------------
    input  logic        in_valid,      // one pulse per byte
    input  logic [7:0]  in_byte,

    // ---- samples out ----------------------------------------------------
    output logic        sample_valid,  // one pulse per sample pair
    output logic [31:0] sample,        // {left[15:0], right[15:0]}, signed

    // ---- what we learned from the header --------------------------------
    output logic        header_ok,     // 1 once we are inside the data chunk
    output logic        rate_44k,      // 1 = 44.1 kHz, 0 = 48 kHz
    output logic        err,           // 1 = not a WAV we can play
    output logic        data_done      // 1 = every audio byte has been seen
);

    typedef enum logic [2:0] {
        S_RIFF,       // 12-byte "RIFF" <size> "WAVE"
        S_CHUNK_HDR,  // 8-byte chunk name + length
        S_FMT,        // inside the fmt chunk
        S_SKIP,       // inside a chunk we do not care about
        S_DATA,       // inside the data chunk: audio samples
        S_DONE,
        S_ERR
    } state_t;

    state_t state;

    // Counts bytes within the current header or chunk.
    logic [31:0] cnt;
    // Bytes left in the current chunk (plus its pad byte, if any).
    logic [31:0] left;
    // The last four bytes, assembled little endian: after bytes b0 b1 b2 b3,
    // last4 = {b3, b2, b1, b0}. So "RIFF" reads back as 32'h46464952.
    logic [31:0] last4;
    logic [31:0] last4_next;
    assign last4_next = {in_byte, last4[31:8]};

    // Fields from the fmt chunk.
    logic [15:0] fmt_format, fmt_channels, fmt_bits;
    logic [31:0] fmt_rate;
    logic        fmt_seen;

    // Sample assembly.
    logic [1:0]  pos;          // which byte of the sample frame this is
    logic [7:0]  lo_byte;      // low byte waiting for its high byte
    logic [15:0] left_s;       // left sample waiting for the right one

    localparam logic [31:0] ID_RIFF = 32'h46464952;   // "RIFF"
    localparam logic [31:0] ID_WAVE = 32'h45564157;   // "WAVE"
    localparam logic [31:0] ID_FMT  = 32'h20746d66;   // "fmt "
    localparam logic [31:0] ID_DATA = 32'h61746164;   // "data"

    logic [31:0] chunk_id;     // name of the chunk whose header we are reading

    // Is the format we just finished reading one we can play?
    logic fmt_good;
    assign fmt_good = (fmt_format == 16'd1 || fmt_format == 16'hFFFE)
                   && (fmt_channels == 16'd1 || fmt_channels == 16'd2)
                   && (fmt_bits == 16'd16)
                   && (fmt_rate == 32'd44100 || fmt_rate == 32'd48000);

    assign header_ok = (state == S_DATA) || (state == S_DONE);
    assign err       = (state == S_ERR);
    assign data_done = (state == S_DONE);
    assign rate_44k  = (fmt_rate == 32'd44100);

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= S_RIFF;
            cnt          <= '0;
            left         <= '0;
            last4        <= '0;
            chunk_id     <= '0;
            fmt_format   <= '0;
            fmt_channels <= '0;
            fmt_bits     <= '0;
            fmt_rate     <= '0;
            fmt_seen     <= 1'b0;
            pos          <= '0;
            lo_byte      <= '0;
            left_s       <= '0;
            sample_valid <= 1'b0;
            sample       <= '0;
        end
        else begin
            sample_valid <= 1'b0;

            if (in_valid) begin
                last4 <= last4_next;

                case (state)

                // ---- "RIFF" <size> "WAVE" ------------------------------
                S_RIFF: begin
                    cnt <= cnt + 32'd1;
                    if (cnt == 32'd3 && last4_next != ID_RIFF) state <= S_ERR;
                    if (cnt == 32'd11) begin
                        if (last4_next != ID_WAVE) state <= S_ERR;
                        else begin
                            state <= S_CHUNK_HDR;
                            cnt   <= '0;
                        end
                    end
                end

                // ---- chunk name (4 bytes) + length (4 bytes) ------------
                S_CHUNK_HDR: begin
                    cnt <= cnt + 32'd1;
                    if (cnt == 32'd3) chunk_id <= last4_next;
                    if (cnt == 32'd7) begin
                        cnt <= '0;
                        if (chunk_id == ID_DATA) begin
                            // A data chunk with no fmt before it is broken.
                            if (!fmt_seen || !fmt_good) state <= S_ERR;
                            else begin
                                // Some programs that stream audio write 0 or
                                // 0xFFFFFFFF here; play to the end of the file.
                                left  <= (last4_next == 32'd0) ? 32'hFFFF_FFFF : last4_next;
                                pos   <= '0;
                                state <= S_DATA;
                            end
                        end
                        else begin
                            // fmt or something to skip. Round odd lengths up
                            // to take in the pad byte.
                            left  <= last4_next + {31'd0, last4_next[0]};
                            if (last4_next == 32'd0)
                                state <= S_CHUNK_HDR;           // empty chunk
                            else
                                state <= (chunk_id == ID_FMT) ? S_FMT : S_SKIP;
                        end
                    end
                end

                // ---- fmt body -----------------------------------------
                S_FMT: begin
                    cnt  <= cnt + 32'd1;
                    left <= left - 32'd1;
                    if (cnt == 32'd1)  fmt_format   <= last4_next[31:16];
                    if (cnt == 32'd3)  fmt_channels <= last4_next[31:16];
                    if (cnt == 32'd7)  fmt_rate     <= last4_next;
                    if (cnt == 32'd15) fmt_bits     <= last4_next[31:16];
                    if (left == 32'd1) begin
                        fmt_seen <= 1'b1;
                        cnt      <= '0;
                        state    <= S_CHUNK_HDR;
                    end
                end

                // ---- chunk we do not care about ------------------------
                S_SKIP: begin
                    left <= left - 32'd1;
                    if (left == 32'd1) begin
                        cnt   <= '0;
                        state <= S_CHUNK_HDR;
                    end
                end

                // ---- audio --------------------------------------------
                S_DATA: begin
                    left <= left - 32'd1;
                    if (left == 32'd1) state <= S_DONE;

                    if (fmt_channels == 16'd1) begin
                        // mono: lo hi -> same sample to both speakers
                        if (pos[0] == 1'b0) lo_byte <= in_byte;
                        else begin
                            sample       <= {in_byte, lo_byte, in_byte, lo_byte};
                            sample_valid <= 1'b1;
                        end
                        pos <= {1'b0, ~pos[0]};
                    end
                    else begin
                        // stereo: Llo Lhi Rlo Rhi
                        case (pos)
                            2'd0: lo_byte <= in_byte;
                            2'd1: left_s  <= {in_byte, lo_byte};
                            2'd2: lo_byte <= in_byte;
                            2'd3: begin
                                sample       <= {left_s, in_byte, lo_byte};
                                sample_valid <= 1'b1;
                            end
                        endcase
                        pos <= pos + 2'd1;
                    end
                end

                default: ;   // S_DONE, S_ERR: ignore anything else
                endcase
            end
        end
    end

endmodule
