`timescale 1ns / 1ps
import highway_pkg::*;

module tb_guitar_top;

    // 50 MHz clock (20 ns period)
    logic        CLOCK_50 = 0;
    always #10 CLOCK_50 = ~CLOCK_50;

    // DUT Inputs
    logic        rst_n;
    logic [4:0]  fret;
    logic        strum_up;
    logic        strum_down;

    // DUT Outputs
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

    // Instantiate DUT (uses rst_n active-low reset)
    guitar_top dut (
        .CLOCK_50    (CLOCK_50),
        .rst_n       (rst_n),
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

    // Helper task to wait N VGA frames (~16.8 ms per frame)
    task automatic wait_frames(int n);
        repeat (n) @(posedge dut.frame_tick);
    endtask

    initial begin
        // --------------------------------------------------------------------
        // 1. Initialize & Release Reset
        // --------------------------------------------------------------------
        rst_n      = 1'b0;
        fret       = 5'b00000;
        strum_up   = 1'b1;   // strum buttons are active-low: 1 = not pressed
        strum_down = 1'b1;

        repeat (10) @(posedge CLOCK_50);
        rst_n = 1'b1;

        // Bypass the 3-second (150M cycle) SD card timeout so game_rst drops immediately
        force dut.u_audio.failed = 1'b1;
        repeat (5) @(posedge CLOCK_50);

        assert (dut.game_rst == 1'b0)
            else $fatal(1, "ERROR: game_rst did not release!");
        $display("[%0t] Reset released. Score = %0d, HEX0 = %b", $time, dut.score, HEX0);

        // Wait 1 full VGA frame so VGA_HS, VGA_VS, and frame_tick are active
        wait_frames(1);

        // --------------------------------------------------------------------
        // 2. Test Case 1: Valid Note Hit (+10 points)
        // --------------------------------------------------------------------
        // Inject a note into Lane 0, Slot 1 (inside HIT_WINDOW = 4)
        force dut.slots[0][1] = CELL_NOTE;
        @(posedge CLOCK_50);

        // Press Green fret (lane 0) and strum up
        fret[0]  = 1'b1;
        strum_up = 1'b0;   // press (active-low)

        // Hold until hit_detect samples it on frame_tick
        @(posedge dut.frame_tick);
        @(posedge CLOCK_50);

        // Release strum, fret, and forced slot so the note clears cleanly
        strum_up = 1'b1;   // release
        fret[0]  = 1'b0;
        release dut.slots[0][1];

        $display("[%0t] Test 1 (Valid Hit): Score = %0d (Expected: 10), HEX0 = %b",
                 $time, dut.score, HEX0);

        // Wait out the 4-frame COOLDOWN window so hit_detect returns to READY
        wait_frames(4);

        // --------------------------------------------------------------------
        // 3. Test Case 2: Wrong Fret Strum (-5 points)
        // --------------------------------------------------------------------
        // Inject a note into Lane 2 (Yellow), Slot 1
        force dut.slots[2][1] = CELL_NOTE;
        @(posedge CLOCK_50);

        // Press wrong fret (Lane 1 / Red) and strum down
        fret[1]    = 1'b1;
        strum_down = 1'b0;   // press (active-low)

        @(posedge dut.frame_tick);
        @(posedge CLOCK_50);

        strum_down = 1'b1;   // release
        fret[1]    = 1'b0;
        release dut.slots[2][1];

        $display("[%0t] Test 2 (Wrong Fret Miss): Score = %0d (Expected: 5), HEX0 = %b",
                 $time, dut.score, HEX0);

        // --------------------------------------------------------------------
        // 4. Test Case 3: Held Note Tail (+1 point per frame held)
        // --------------------------------------------------------------------
        // Inject a tail cell at Slot 0 (which drives hold_line[0] = 1)
        force dut.slots[0][0] = CELL_HOLD;
        fret[0] = 1'b1;

        // Hold across 2 frames to verify continuous +1 scoring
        wait_frames(2);
        @(posedge CLOCK_50);

        fret[0] = 1'b0;
        release dut.slots[0][0];

        $display("[%0t] Test 3 (Hold Tail x2 frames): Score = %0d (Expected: 7), HEX0 = %b",
                 $time, dut.score, HEX0);

        // Run 1 final frame and finish
        wait_frames(1);
        $display("[%0t] Simulation complete. Final Score = %0d", $time, dut.score);
        $finish;
    end

endmodule