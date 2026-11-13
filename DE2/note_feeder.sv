import highway_pkg::*;

// The only purpose of note_feeder.sv is 

// ROM layout 
// Address breakdown 
// address: 0 - 4 : Stores the total notes per lane
// address: 5 - 9 : Stores where each lane's notes start
// address: 10+ : Stores the acutal notes, sorted by when they appear

// Data Received from ROM
// 16 bit word
// bit 15 -> flag if its a hold note (1), or standard tap note (0)
// bits 14:0 -> the exact video frame where the note appears (spawn it at the top)

// HOW A HELD NOTE IS ENCODED IN THE CHART
// ---------------------------------------
// A hold is TWO entries in notes.hex: the hold itself (bit 15 set) and then the
// next note in that same lane, which is the RELEASE point. The gap between the
// two is the length of the hold. Looking at lane 3 of the demo chart:
//
//      frame 186  hold      <- strum here, start holding
//      frame 250  plain     <- let go here. 64 frames long.
//      frame 442  hold      <- next hold, 192 frames later
//      frame 506  plain     <- let go
//
// So the plain note at 250 is NOT something to hit. It just marks the end.
//
// WHAT THIS MODULE WRITES INTO `slots` (this is the whole contract with
// highway_draw -- it does no hold bookkeeping of its own, it just paints what
// it finds here)
//
//      CELL_NOTE      a note to hit: a tap, OR the head of a hold. Drawn as a
//                     full-width rectangle either way.
//      CELL_HOLD      the tail body trailing BEHIND a hold head. Drawn as a
//                     thin line. The player should be holding the fret while
//                     these are crossing the hit line.
//      CELL_HOLD_END  the release marker. Drawn as NOTHING -- it is where the
//                     tail stops, not a note.
//      CELL_EMPTY     nothing here.
//
// WHICH WAY THE TAIL POINTS
// -------------------------
// Notes travel from the far end of the queue (slot N_SLOTS-1, the horizon)
// toward slot 0 (the hit line). The HEAD arrives first and the tail follows it,
// so the tail lives in HIGHER slot numbers than the head -- above it on screen.
// That is why the tail is written by the shift below, one cell per frame, after
// the head has already been pushed in:
//
//      slot:      ... 127     126     125     124  ...
//      frame T:       HEAD
//      frame T+1:     tail    HEAD
//      frame T+2:     tail    tail    HEAD
//      frame T+3:     END     tail    tail    HEAD      <- release marker lands

module note_feeder #(
    parameter string HEXFILE = "notes.hex",  // Read in these value to ROM 
    parameter int    ADDR_W  = 11            // 2048 words, raise for longer songs
)(
    input  logic clk50,
    input  logic rst,
    input  logic frame_tick,                 // one pulse per video frame

    output logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots,
    output logic [14:0] frame_count,         // frames since reset
    output logic        song_done            // 1 when every lane is used up
);

    // number of header words at the top of the hex file
    localparam int HDR_WORDS = 2 * N_LANES;  // 2 * 5 lanes = 10 

    logic [ADDR_W-1:0] addr; // Address holder
    logic [15:0]       rom_data; // This this is where incoming rom data goes

    // Instantiate the note_rom.sv
    note_rom #(
        .DATA_W (16),
        .ADDR_W (ADDR_W),
        .HEXFILE(HEXFILE)
    ) u_rom (
        .clk (clk50),
        .addr(addr),
        .dout(rom_data)
    );

    // Header copied out of the ROM at power-up, plus one read pointer per lane
    logic [15:0] note_count [0:N_LANES-1];   // Total notes per lane
    logic [15:0] note_start [0:N_LANES-1];   // ROM address where the lane begins in memory
    logic [15:0] note_ptr   [0:N_LANES-1];   // How many notes have been played

    // The state machine for reading notes in
    typedef enum logic [2:0] {
        S_HDR_ADDR,     // ask the ROM for header word `hdr_idx`
        S_HDR_WAIT,     // ROM takes one cycle to answer
        S_HDR_STORE,    // file the answer into note_count / note_start
        S_WAIT_TICK,    // idle until the next video frame
        S_NOTE_ADDR,    // ask the ROM for lane `lane`'s next unused note
        S_NOTE_WAIT,    // ROM takes one cycle to answer
        S_NOTE_CHECK    // is that note due yet?
    } state_t;

    state_t      state;
    logic [3:0]  hdr_idx;    // 0..9 while reading the header
    logic [2:0]  lane;       // 0..4 while scanning lanes, 5 means "done"

    // One bit per lane: "I have pushed a hold head and have not yet seen the
    // note that releases it." While this is set, every cell this module shifts
    // in at the far end becomes tail instead of empty. Five flip-flops is the
    // entire cost of drawing held notes -- highway_draw needs no state at all.
    logic [N_LANES-1:0] in_hold;

    always_ff @(posedge clk50) begin
        if (rst) begin
            state       <= S_HDR_ADDR;
            hdr_idx     <= 4'd0;
            lane        <= 3'd0;
            addr        <= '0;
            frame_count <= 15'd0;
            slots       <= '0;
            in_hold     <= '0;
            for (int k = 0; k < N_LANES; k++) begin
                note_count[k] <= 16'd0;
                note_start[k] <= 16'd0;
                note_ptr[k]   <= 16'd0;
            end
        end
        else begin
            case (state)
            
            // Reading header stuffs ----------------------------------------------------
            // Request data from ROM
            S_HDR_ADDR: begin
                // Request data from ROM 
                // the ADDR_W' is casting syntax
                addr  <= ADDR_W'(hdr_idx);
                state <= S_HDR_WAIT;
            end

            // Wait 1 cycle cycle for the ROM to find the data
            S_HDR_WAIT: state <= S_HDR_STORE;

            S_HDR_STORE: begin
                // Store that indexed value into the indexed note_count and note start
                if (hdr_idx < N_LANES) note_count[hdr_idx]        <= rom_data;
                else                   note_start[hdr_idx - 4'd5] <= rom_data;

                // Break condition to continue in the state machine
                if (hdr_idx == HDR_WORDS - 1) state <= S_WAIT_TICK;
                // continue indexing hdr_idx by 1 to continue grabbing the header contents
                else begin
                    hdr_idx <= hdr_idx + 4'd1;
                    state   <= S_HDR_ADDR;
                end
            end
            // ----------------------------------------------------------------------------

            // Wait for new frame then update highway
            S_WAIT_TICK: begin
                if (frame_tick) begin
                    // This makes the animation for the notes moving down
                    for (int L = 0; L < N_LANES; L++) begin
                        // Drop slot 0 (it just reached the player) and push a
                        // new cell in at the far end. Normally that cell is
                        // empty -- but if this lane is in the middle of a hold,
                        // it is a piece of the tail. One cell per frame is
                        // exactly what makes the tail stretch out behind the
                        // head as the head moves down the highway.
                        //
                        // If a note is due this frame, S_NOTE_CHECK overwrites
                        // this same cell a few cycles from now, so a real note
                        // always wins over a tail cell.
                        slots[L] <= { in_hold[L] ? CELL_HOLD : CELL_EMPTY,
                                      slots[L][N_SLOTS-1:1] };
                    end
                    // Increment frame count
                    frame_count <= frame_count + 15'd1;
                    // Start lane index at 0 after frame tick
                    lane        <= 3'd0;
                    // Change state to walk through the lanes 
                    state       <= S_NOTE_ADDR;
                end
            end

            // check the lanes
            S_NOTE_ADDR: begin
                // All Lanes are good go wait for frame tick
                if (lane == N_LANES) begin
                    state <= S_WAIT_TICK;
                end
                // Lane has no more notes left increment lane
                else if (note_ptr[lane] >= note_count[lane]) begin
                    lane <= lane + 3'd1; // lane has no notes left
                end
                // Request Data from ROM at lane start address + of ptr offset
                else begin
                    addr  <= ADDR_W'(note_start[lane] + note_ptr[lane]);
                    state <= S_NOTE_WAIT;
                end
            end

            // Wait for the ROM to respond
            S_NOTE_WAIT: state <= S_NOTE_CHECK;
            
            // Compare the fetched note's timestamp against the current frame
            S_NOTE_CHECK: begin
                // "<=" not "==" so a note is never skipped if we somehow
                // arrive to a frame late.
                if (rom_data[14:0] <= frame_count) begin
                    // Spawn it at the far end of the highway. rom_data[15] is
                    // the hold flag. Three cases:
                    if (rom_data[15]) begin
                        // HOLD HEAD. It is a note you strum, so graphically it
                        // is an ordinary rectangle -- CELL_NOTE. Setting
                        // in_hold is what makes every following frame trail a
                        // tail cell in behind it.
                        slots[lane][N_SLOTS-1] <= CELL_NOTE;
                        in_hold[lane]          <= 1'b1;
                    end
                    else if (in_hold[lane]) begin
                        // RELEASE MARKER. This lane is mid-hold, so this note
                        // is not something to hit -- it is where the tail ends.
                        // CELL_HOLD_END draws as nothing, and clearing in_hold
                        // stops the tail from growing any further.
                        slots[lane][N_SLOTS-1] <= CELL_HOLD_END;
                        in_hold[lane]          <= 1'b0;
                    end
                    else begin
                        // Ordinary tap note.
                        slots[lane][N_SLOTS-1] <= CELL_NOTE;
                    end
                    note_ptr[lane] <= note_ptr[lane] + 16'd1;
                    state <= S_NOTE_ADDR;     // same lane check for a chord
                end
                else begin
                    lane  <= lane + 3'd1; // not due; next lane
                    state <= S_NOTE_ADDR;
                end
            end

            default: state <= S_WAIT_TICK;
            endcase
        end
    end

    // true when every lane's pointer has run off the
    // end of its note list.
    always_comb begin
        song_done = 1'b1;
        for (int L = 0; L < N_LANES; L++) begin
            if (note_ptr[L] < note_count[L]) song_done = 1'b0;
        end
    end

endmodule
