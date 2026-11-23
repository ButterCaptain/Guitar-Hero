// ============================================================================
//  tb_audio.sv -- end-to-end test of the SD card -> speaker path.
//
//  A fake SD card (sd_fake.v, from the same project as the reader) holds a
//  FAT32 image made by make_sd_image.py. A fake WM8731 in this file:
//    * answers I2C and records every register written, and
//    * listens to the I2S wires and decodes every sample it receives.
//  At the end we check that EVERY sample in the WAV came out, in order, with
//  nothing missing, nothing extra, and the right number of bit clocks per
//  sample.
//
//  Run (see run_audio_tests.sh for all cases):
//      python3 make_sd_image.py --out build_audio
//      iverilog -g2012 -I build_audio -o tb_audio.vvp tb_audio.sv sd_fake.v \
//          ../DE2/audio_top.sv ../DE2/wav_parser.sv ../DE2/audio_fifo.sv \
//          ../DE2/wm8731_config.sv ../DE2/i2s_out.sv ../DE2/sd_card/*.v
//      vvp tb_audio.vvp +DIR=build_audio
//
//  Add +EXPECT_FAIL to check that a card WITHOUT the file is reported as
//  failed instead.
// ============================================================================

`timescale 1ps/1ps
`include "params.vh"

module tb_audio;

    // ---- clocks and reset -----------------------------------------------
    logic clk50 = 0, clk_aud = 0, rst = 1;
    always #10000 clk50   = ~clk50;     // 50 MHz
    always #41667 clk_aud = ~clk_aud;   // 12 MHz (to 0.001%)
    initial begin
        repeat (10) @(posedge clk50);
        rst = 0;
    end

    // ---- DUT ------------------------------------------------------------
    wire        sd_clk, sd_cmd;
    wire [3:0]  sd_dat;
    wire        aud_xck, aud_bclk, aud_daclrck, aud_dacdat;
    wire        i2c_sclk, i2c_sdat;
    logic       playing, failed;
    logic [7:0] status;

    pullup (sd_cmd);
    pullup (i2c_sdat);

    audio_top #(
        .FILE_NAME_LEN  (8),
        .FILE_NAME      ("song.wav"),
        .FIFO_AW        (10),          // small buffer so `pause` gets exercised
        .TIMEOUT_CYCLES (2_000_000),   // 40 ms
        .SIMULATE       (1)
    ) dut (
        .clk50       (clk50),
        .rst         (rst),
        .clk_aud     (clk_aud),
        .sd_clk      (sd_clk),
        .sd_cmd      (sd_cmd),
        .sd_dat0     (sd_dat[0]),
        .aud_xck     (aud_xck),
        .aud_bclk    (aud_bclk),
        .aud_daclrck (aud_daclrck),
        .aud_dacdat  (aud_dacdat),
        .i2c_sclk    (i2c_sclk),
        .i2c_sdat    (i2c_sdat),
        .playing     (playing),
        .failed      (failed),
        .status      (status)
    );

    // ---- fake SD card ----------------------------------------------------
    wire        rom_req;
    wire [39:0] rom_addr;
    logic [15:0] rom_data;

    sd_fake u_card (
        .rstn_async       (~rst),
        .sdclk            (sd_clk),
        .sdcmd            (sd_cmd),
        .sddat            (sd_dat),
        .rdreq            (rom_req),
        .rdaddr           (rom_addr),
        .rddata           (rom_data),
        .show_status_bits (),
        .show_sdcmd_en    (),
        .show_sdcmd_cmd   (),
        .show_sdcmd_arg   ()
    );

    // Sparse card contents: sector number list + 256 words per sector.
    logic [31:0] sec_map  [0:`N_SECTORS-1];
    logic [15:0] sec_data [0:`N_SECTORS*256-1];
    logic [31:0] expected [0:`N_SAMPLES-1];
    string dir;

    initial begin
        if (!$value$plusargs("DIR=%s", dir)) dir = "build_audio";
        $readmemh($sformatf("%s/sd_map.hex", dir),   sec_map);
        $readmemh($sformatf("%s/sd_data.hex", dir),  sec_data);
        $readmemh($sformatf("%s/expected.hex", dir), expected);
    end

    // rdaddr counts 16-bit words: sector = addr / 256.
    always @(posedge sd_clk) begin
        if (rom_req) begin
            rom_data <= 16'h0000;
            for (int i = 0; i < `N_SECTORS; i++)
                if (sec_map[i] == rom_addr[39:8])
                    rom_data <= sec_data[i*256 + rom_addr[7:0]];
        end
    end

    // ---- fake WM8731: I2C side ----------------------------------------------
    logic [8:0] regs [0:15];
    int         n_writes = 0;
    logic [6:0] last_reg;
    logic       ack_drive = 0;
    assign i2c_sdat = ack_drive ? 1'b0 : 1'bz;

    int         i2c_bit = 0;
    logic [7:0] i2c_shift;
    logic [7:0] i2c_bytes [0:2];
    int         i2c_nbytes = 0;

    always @(negedge i2c_sdat) if (i2c_sclk) begin       // START
        i2c_bit = 0; i2c_nbytes = 0;
    end
    always @(posedge i2c_sdat) if (i2c_sclk) begin       // STOP
        if (i2c_nbytes == 3 && i2c_bytes[0] == 8'h34) begin
            regs[i2c_bytes[1][7:1]] = {i2c_bytes[1][0], i2c_bytes[2]};
            last_reg = i2c_bytes[1][7:1];
            n_writes++;
        end
    end
    always @(posedge i2c_sclk) begin
        if (i2c_bit < 8) i2c_shift = {i2c_shift[6:0], i2c_sdat};
        i2c_bit++;
    end
    always @(negedge i2c_sclk) begin
        if (i2c_bit == 8) begin
            ack_drive = 1;                               // ACK
            if (i2c_nbytes < 3) i2c_bytes[i2c_nbytes] = i2c_shift;
            i2c_nbytes++;
        end
        else if (i2c_bit == 9) begin
            ack_drive = 0;
            i2c_bit   = 0;
        end
    end

    // ---- fake WM8731: I2S side ----------------------------------------------
    // The chip reads on the rising edge of BCLK. Standard I2S: the bit just
    // after DACLRCK changes is padding, then 16 bits MSB first.
    logic        prev_lrck = 0;
    int          bitpos = 0, bclks = 0, frame_len = -1, bad_frames = 0;
    logic [15:0] sh, got_l;
    int          n_got = 0, errors = 0, zeros_after = 0;
    logic        started = 0;

    always @(posedge aud_bclk) begin
        bclks++;
        if (aud_daclrck != prev_lrck) begin
            bitpos = 0;
            if (!aud_daclrck) begin                  // new frame
                if (frame_len >= 0 && bclks != `FRAME_BCLKS) bad_frames++;
                frame_len = bclks;
                bclks = 0;
            end
        end
        else bitpos++;
        prev_lrck = aud_daclrck;

        if (bitpos >= 1 && bitpos <= 16) sh = {sh[14:0], aud_dacdat};
        if (bitpos == 16) begin
            if (!aud_daclrck) got_l = sh;
            else              check_sample({got_l, sh});
        end
    end

    task automatic check_sample(input logic [31:0] s);
        if (!started && s != 0) started = 1;
        if (started) begin
            if (n_got < `N_SAMPLES) begin
                if (s !== expected[n_got]) begin
                    if (errors < 10)
                        $display("  MISMATCH sample %0d: got %08h want %08h",
                                 n_got, s, expected[n_got]);
                    errors++;
                end
                n_got++;
            end
            else if (s != 0) zeros_after++;   // anything after the song must be silence
        end
    endtask

    // ---- run --------------------------------------------------------------
    logic seen_pause = 0;
    always @(posedge clk50) if (dut.sd_pause) seen_pause = 1;

    real t_play;
    initial begin
        bit expect_fail;
        int pass;
        expect_fail = $test$plusargs("EXPECT_FAIL");
        pass = 1;

        wait (playing || failed);
        t_play = $realtime / 1e9;
        $display("[%0.2f ms] playing=%0d failed=%0d status=%08b",
                 t_play, playing, failed, status);

        if (expect_fail) begin
            if (!failed || playing) begin
                $display("FAIL: expected `failed`"); pass = 0;
            end
            $display(pass ? "PASS (missing file reported as failed)" : "FAIL");
            $finish;
        end

        if (!playing) begin
            $display("FAIL: audio did not start"); $finish;
        end

        // Song length + some slack.
        #(64'd83333 * (`N_SAMPLES * `FRAME_BCLKS + 20000));

        $display("samples received : %0d / %0d", n_got, `N_SAMPLES);
        $display("mismatches       : %0d", errors);
        $display("frame length     : %0d bit clocks (want %0d), bad frames %0d",
                 frame_len, `FRAME_BCLKS, bad_frames);
        $display("I2C writes       : %0d, last reg R%0d, R7=%03h R8=%03h (want %03h) R9=%03h",
                 n_writes, last_reg, regs[7], regs[8], `R8_EXPECTED, regs[9]);
        $display("status bits      : %08b, buffer paused the card: %0d", status, seen_pause);

        if (n_got != `N_SAMPLES)                   pass = 0;
        if (errors != 0)                           pass = 0;
        if (zeros_after != 0)                      pass = 0;
        if (bad_frames != 0)                       pass = 0;
        if (frame_len != `FRAME_BCLKS)             pass = 0;
        if (n_writes != 10 || last_reg != 7'h09)   pass = 0;
        if (regs[8] !== `R8_EXPECTED)              pass = 0;
        if (regs[7] !== 9'h002 || regs[9] !== 9'h001) pass = 0;
        if (status[6] || status[5] || status[7])   pass = 0;   // underrun / nack / wav err
        if (!seen_pause)                           pass = 0;

        $display(pass ? "PASS" : "FAIL");
        $finish;
    end

    // Hard stop in case something hangs.
    initial begin
        #(64'd400_000_000_000);
        $display("FAIL: timeout");
        $finish;
    end

endmodule
