`timescale 1ns / 1ps
import highway_pkg::*;

module tb_hit_detect;

    // Parameters & Signals connecting to hit_detect
    localparam int HIT_WINDOW = 4;

    logic               clk50;
    logic               rst;
    logic               frame_tick;
    logic [N_LANES-1:0] fret;
    logic               strum_up;
    logic               strum_down;
    logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots;
    logic [N_LANES-1:0] hold_line;
    logic signed [15:0] score;

    // Instantiate the Unit Under Test
    hit_detect #(
        .HIT_WINDOW(HIT_WINDOW)
    ) uut (
        .clk50      (clk50),
        .rst        (rst),
        .frame_tick (frame_tick),
        .fret       (fret),
        .strum_up   (strum_up),
        .strum_down (strum_down),
        .slots      (slots),
        .hold_line  (hold_line),
        .score      (score)
    );

    // Generate the "50 MHz Clock" (20ns period -> flips every 10ns)
    initial clk50 = 1'b0;
    always #10 clk50 = ~clk50; // This waits 10 units then flips the clock

    // Mirror the hold_line logic from highway_draw.sv
    // (High whenever slot 0 of a lane contains a CELL_HOLD tail)
    always_comb begin
        for (int L = 0; L < N_LANES; L++) begin
            hold_line[L] = (slots[L][0] == CELL_HOLD);
        end
    end

    // Simulates one video frame passing: pulses frame_tick and shifts notes down
    task automatic step_frame();
        // Wait a few 50MHz cycles to mimic time between frames
        repeat (4) @(posedge clk50);
        
        frame_tick <= 1'b1;
        @(posedge clk50);
        frame_tick <= 1'b0;

        // Shift all lanes down by 1 slot, just like note_feeder.sv does
        for (int L = 0; L < N_LANES; L++) begin
            slots[L] <= {CELL_EMPTY, slots[L][N_SLOTS-1:1]};
        end
        @(posedge clk50);
    endtask

    // Simulates the player pressing and releasing the strum button
    task automatic do_strum();
        @(posedge clk50);
        strum_up <= 1'b1;
        @(posedge clk50);
        strum_up <= 1'b0;
    endtask

    // Prints PASS or FAIL to the simulator transcript
    task automatic check_score(input signed [15:0] expected, input string test_name);
        if (score === expected)
            $display("[PASS] %s | Score = %0d", test_name, score);
        else
            $display("[FAIL] %s | Expected = %0d, Got = %0d", test_name, expected, score);
    endtask

    // Main Test Sequence 
    initial begin
        $display("==================================================");
        $display(" Starting hit_detect Testbench (HIT_WINDOW = %0d)", HIT_WINDOW);
        $display("==================================================");

        // --- INITIALIZE & RESET ---
        rst        = 1'b1;
        frame_tick = 1'b0;
        fret       = 5'b00000;
        strum_up   = 1'b0;
        strum_down = 1'b0;
        slots      = '0;

        repeat (3) @(posedge clk50);
        rst = 1'b0;
        @(posedge clk50);
        check_score(16'sd0, "Reset Check");

        // TEST 1: Successful Note Hit + Cooldown Protection
        // Place a note in Lane 0 at slot 3 (top of our 4-slot HIT_WINDOW).

        slots[0][3] = CELL_NOTE;
        fret        = 5'b00001; // Hold Lane 0 (Green fret)
        do_strum();             // Strum before the frame tick!
        step_frame();           // Frame tick evaluates the hit (+10 pts)
        check_score(16'sd10, "Test 1A: Valid Note Hit at Slot 3");

        // Now step 4 more frames so the note slides through slots 2, 1, 0, and off.
        // Because of S_COOLDOWN, it should NOT penalize us when it crosses slot 0!
        repeat (4) step_frame();
        fret = 5'b00000;
        check_score(16'sd10, "Test 1B: Cooldown Prevents False Miss at Slot 0");

        // --------------------------------------------------------------------

        // TEST 2: Missed Note (Player never strums)
        // Place a note in Lane 1 at slot 1. Let it reach slot 0 and fall off.
        slots[1][1] = CELL_NOTE;
        step_frame(); // Moves note from slot 1 -> slot 0
        step_frame(); // Note is at slot 0 with no strum -> MISS (-5 pts)
        check_score(16'sd5, "Test 2: Missed Note Penalty");

        // --------------------------------------------------------------------

        // TEST 3: Wrong Fret / Overstrum Penalty
        // Place a note in Lane 2, but player holds Lane 4 and strums.
        slots[2][2] = CELL_NOTE;
        fret        = 5'b10000; // Wrong fret!
        do_strum();
        step_frame();           // Evaluates wrong strum (-5 pts -> score = 0)
        check_score(16'sd0, "Test 3: Wrong Fret Strum Penalty");

        // Clear the highway before Test 4
        slots = '0;
        fret  = 5'b00000;
        step_frame();

        // --------------------------------------------------------------------


        // TEST 4: Held Note (Head + 3-frame Tail)
        // Put a note head at slot 1, and 3 hold-tail cells behind it (slots 2..4)
        slots[3][1] = CELL_NOTE;
        slots[3][2] = CELL_HOLD;
        slots[3][3] = CELL_HOLD;
        slots[3][4] = CELL_HOLD;

        fret = 5'b01000; // Hold Lane 3
        do_strum();      // Strum the head!
        step_frame();    // Head hit (+10 pts). Tail shifts into slots 1, 2, 3.
        check_score(16'sd10, "Test 4A: Hold Note Head Hit");

        // Step 1 more frame so the first CELL_HOLD reaches slot 0
        step_frame();    // Tail is now at slot 0, 1, 2

        // Now the 3 tail cells cross slot 0 over the next 3 frames (+1 pt each)
        step_frame();    // Tail cell 1 scored (+1 -> 11)
        step_frame();    // Tail cell 2 scored (+1 -> 12)  
        step_frame();    // Tail cell 3 scored (+1 -> 13)
        check_score(16'sd13, "Test 4B: Held Tail Bonus (+3 pts over 3 frames)");

        $display("==================================================");
        $display(" All Tests Complete!");
        $display("==================================================");
        $finish;
    end

endmodule