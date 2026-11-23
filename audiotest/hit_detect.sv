import highway_pkg::*; 

module hit_detect #(
    parameter int HIT_WINDOW = 4
) (
    input logic clk50,
    input logic rst,
    input logic frame_tick, 
    input logic [N_LANES-1:0] fret,
    input logic strum_up,
    input logic strum_down,
    // Iput where the notes are at
    input logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots, 
    // Input if the the note is a hold line
    input logic [N_LANES-1:0] hold_line,

    // Output the score
    output logic signed [15:0] score
);
    // Edge detection for the strum input -----
    logic raw_strum, strum_prev, strum_edge; 
    assign raw_strum = strum_up | strum_down;

    always_ff @(posedge clk50) begin
        if (rst) begin
            strum_prev <= 1'b0;
        end 
        else strum_prev <= raw_strum;
    end

    assign strum_edge = raw_strum && !strum_prev; 
    //=------------------------------------

    logic strum_pending; 

    logic [N_LANES-1:0] note_hit_zone;
    
    // Goes through all the slots array and checks if 
    // a note is in the hit zone
    always_comb begin
        note_hit_zone = '0;
        for (int i = 0; i < N_LANES; i++) begin
            for (int j = 0; j < HIT_WINDOW; j++) begin
                if (slots[i][j] == CELL_NOTE) begin
                    note_hit_zone[i] = 1'b1;
                end
            end
        end
    end

    // State machine to handle the hit detection
    typedef enum logic [1:0] {
        READY, // listening for a strum
        COOLDOWN // A note was hit let is slide out of the hit window
    } hit_state_t;

    // Initialize the state machine
    hit_state_t state; 

    // Special system verilog function that calculates the number of bits needed to represent a number
    // We only need enough bits to count up to HIT_WINDOW
    logic [$clog2(HIT_WINDOW+1)-1:0] cooldown_cnt;

    // a bit that hold the result of the comparison between the fret and the note hit zone
    logic fret_match;
    logic note_at_bottom; 

    always_comb begin 
        // 1 if the exact fret is being pressed and it isn't all 0s 
        fret_match = (fret == note_hit_zone) && (note_hit_zone != '0);

        // Make sure not at bottom is false to begin with
        note_at_bottom = 1'b0;
        // If the note is on the veery last slot then the note fell off
        for (int L = 0; L < N_LANES; L++) begin
            if (slots[L][0] == CELL_NOTE) begin
                note_at_bottom = 1'b1;
            end
        end
    end

    always_ff @(posedge clk50) begin
        if (rst) begin
            state <= READY;
            score <= 16'sd0; 
            strum_pending <= 1'b0;
            cooldown_cnt <= 0;
        end 
        else begin
            
            // This places the input strum into a variable
            // just incase the user strums between frames
            if (strum_edge) begin
                strum_pending <= 1'b1;
            end

            if (frame_tick) begin
                // Do something with the holdline

                case(state)
                    // Checks if the fret_match is true
                    // if it is true add points
                    // else remove points 
                    // then go to cooldown state
                    READY: begin 
                        if(strum_pending) begin
                            // set it back to 0 so we don't double count the strum
                            strum_pending <= 1'b0;

                            if (fret_match) begin
                                score <= score + 16'sd10;
                                cooldown_cnt <= HIT_WINDOW - 1; // load the timer
                                state <= COOLDOWN;
                            end
                            else begin
                                score <= score - 16'sd5;
                            end
                            
                        end
                        else if (note_at_bottom) begin
                            score <= score - 16'sd5;
                        end
                        else begin 
                            // Check for hold_line when not strumming
                            // if the lane is a hold line and the fret of the same hold line 
                            // keep giving points
                            for (int L = 0; L < N_LANES; L++) begin
                                if (hold_line[L]) begin
                                    if(fret[L]) score <= score + 16'sd1;
                                    else        score <= score - 16'sd1;
                                
                                end
                            end
                        
                        end 
                    end

                    // Cool down stat that just waits until the count reaches 0 then goes back to ready
                    COOLDOWN: begin
                        
                        // Need to check for hold lines during cooldown too
                        for (int L = 0; L < N_LANES; L++) begin
                            if (hold_line[L]) begin
                                if (fret[L]) score <= score + 16'sd1;
                                else         score <= score - 16'sd1;
                            end
                        end

                        // Ignore strums when coodling down
                        strum_pending <= 1'b0;
                        if (cooldown_cnt == 0) begin
                            state <= READY;
                        end
                        else begin
                            cooldown_cnt <= cooldown_cnt - 1'b1;
                        end
                    end

                    default: begin
                        state <= READY;
                    end

                endcase
            end 
        end
    end
endmodule