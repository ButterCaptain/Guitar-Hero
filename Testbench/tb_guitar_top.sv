`timescale 1ns / 1ps
import highway_pkg::*;

module tb_guitar_top;

    // 50 MHz clock (20 ns period)
    logic        CLOCK_50 = 0;
    always #10 CLOCK_50 = ~CLOCK_50;

    // Inputs
    logic [3:0]  KEY;
    logic [4:0]  fret;
    logic        strum_up;
    logic        strum_down;

    // Outputs
    logic [7:0]  VGA_R, VGA_G, VGA_B;
    logic        VGA_CLK, VGA_BLANK_N, VGA_SYNC_N, VGA_HS, VGA_VS;
    logic [6:0]  HEX0, HEX1, HEX2, HEX3;
    logic        SD_CLK;
    wire         SD_CMD;
    wire  [3:0]  SD_DAT;
    logic        AUD_XCK, AUD_BCLK, AUD_DACLRCK, AUD_DACDAT, I2C_SCLK;
    wire         I2C_SDAT;
    logic [17:0] LEDR;
    logic [8:0]  LEDG;

    // Instantiate DUT
    guitar_top dut (
        .CLOCK_50    (CLOCK_50),
        .KEY         (KEY),
        .fret        (fret),
        .strum_up    (strum_up),
        .strum_down  (strum_down),
        .VGA_R       (VGA_R),
        .VGA_G       (VGA_G),
        .VGA_B       (VGA_B),
        .VGA_CLK     (VGA_CLK),
        .VGA_BLANK_N (VGA_BLANK_N),
        .VGA_SYNC_N  (VGA_SYNC_N),
        .VGA_HS      (VGA_HS),
        .VGA_VS      (VGA_VS),
        .HEX0        (HEX0),
        .HEX1        (HEX1),
        .HEX2        (HEX2),
        .HEX3        (HEX3),
        .SD_CLK      (SD_CLK),
        .SD_CMD      (SD_CMD),
        .SD_DAT      (SD_DAT),
        .AUD_XCK     (AUD_XCK),
        .AUD_BCLK    (AUD_BCLK),
        .AUD_DACLRCK (AUD_DACLRCK),
        .AUD_DACDAT  (AUD_DACDAT),
        .I2C_SCLK    (I2C_SCLK),
        .I2C_SDAT    (I2C_SDAT),
        .LEDR        (LEDR),
        .LEDG        (LEDG)
    );

    // Helper task to wait N VGA frames
    task automatic wait_frames(int n);
        repeat (n) @(posedge dut.frame_tick);
    endtask

    initial begin
        // 1. Initialize & Reset (KEY[0] is active-low)
        KEY        = 4'b1110;
        fret       = 5'b00000;
        strum_up   = 1'b0;
        strum_down = 1'b0;

        repeat (10) @(posedge CLOCK_50);
        KEY = 4'b1111; // Release reset

        // Bypass the 3-second (150M cycle) SD card timeout for fast simulation
        force dut.u_audio.failed = 1'b1;
        repeat (5) @(posedge CLOCK_50);

        assert (dut.game_rst == 1'b0)
            else $fatal(1, "game_rst did not release after audio_failed!");
        $display("[%0t] Reset released. Initial Score = %0d, HEX0 = %b", $time, dut.score, HEX0);

        // 2. Wait for notes from notes.hex to travel down the 128-slot highway
        // Note: notes spawn at slot 127 and shift 1 slot per frame_tick (~60 Hz)
        wait_frames(130);
        $display("[%0t] After 130 frames: Score = %0d", $time, dut.score);

        // 3. Dynamically detect any note entering the HIT_WINDOW (slots 0..3) and hit it
        fork
            begin : auto_player
                forever begin
                    @(posedge CLOCK_50);
                    // Check if any lane has CELL_NOTE in slot 1 (sweet spot)
                    for (int L = 0; L < N_LANES; L++) begin
                        if (dut.slots[L][1] == CELL_NOTE && dut.hit_unit.state == 2'd0) begin
                            fret[L]  <= 1'b1;
                            strum_up <= 1'b1;
                            @(posedge dut.frame_tick);
                            @(posedge CLOCK_50);
                            strum_up <= 1'b0;
                            fret     <= 5'b00000;
                            $display("[%0t] Hit note on lane %0d! New Score = %0d (LEDG = %0d)",
                                     $time, L, dut.score, LEDG);
                        end
                    end
                end
            end
            begin : sim_timer
                wait_frames(40); // Run for 40 more frames after notes arrive
                disable auto_player;
            end
        join

        // Verify VGA sync activity occurred
        assert (VGA_SYNC_N == 1'b1) else $error("VGA_SYNC_N mismatch");
        $display("[%0t] Testbench complete. Final Score = %0d, HEX0 = %b", $time, dut.score, HEX0);
        $finish;
    end

endmodule