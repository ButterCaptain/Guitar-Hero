import highway_pkg::*;

// ============================================================================
//  hit_detect -- scores strums, misses and held notes, once per video frame
//
//  THE HIT WINDOW
//  Slot 0 is the band just above the hit line (screen rows 431..448), slot 3
//  ends at row 386, so HIT_WINDOW = 4 is the bottom 62 rows of the highway --
//  the same band the fret glow lights up. Each slot is one frame (16.7 ms).
//
//  A human strums when the note looks like it is ON the line, and is often a
//  little late. Once a note leaves slot 0 it is gone from `slots`, so this
//  module remembers it for LATE_WINDOW more frames:
//
//      slot:  ... 4 | 3  2  1  0 | -1 -2 -3        (-k = k frames past the line)
//                   |   early    |   late
//                   <----- strum here = hit ----->
//
//  With 4 early + 3 late frames the window is 7 frames = ~117 ms, close to
//  Guitar Hero's. A note that leaves the late window un-hit is a miss (-5).
//
//  NO DOUBLE COUNTING
//  `done` marks notes in the early window that were already hit, and a hit
//  note never enters the late memory, so one note scores once and is never
//  also charged as a miss. These masks shift on frame_tick in lockstep with
//  note_feeder's shift of `slots`.
//
//  SCORING (all applied together on frame_tick, floored at 0)
//      +10  strum with the right frets while a note is in the window
//       -5  strum with the wrong frets, or with nothing in the window
//       -5  per note that leaves the late window un-hit
//       +1 / -1  per lane with a hold tail on the line, fret held / not held
// ============================================================================
module hit_detect #(
    parameter int HIT_WINDOW  = 4,   // early frames: slots 0 .. HIT_WINDOW-1
    parameter int LATE_WINDOW = 3    // frames a note stays hittable past the line (>= 1)
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
    // (guitar_top hands us synchronized, debounced, active-high strums)
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

    // Holds a strum until the next frame_tick, in case the user strums between frames
    logic strum_pending;
    // A strum on the very cycle of frame_tick counts for this frame
    logic strum_now;
    assign strum_now = strum_pending | strum_edge;

    // ---- note tracking ---------------------------------------------------
    // done[L][j]: the note now in slots[L][j] (early window) was already hit
    // late[L][k]: an un-hit note passed the line k+1 frames ago
    logic [N_LANES-1:0][HIT_WINDOW-1:0]  done;
    logic [N_LANES-1:0][LATE_WINDOW-1:0] late;

    logic [N_LANES-1:0][HIT_WINDOW-1:0] live_early; // hittable notes, early window
    logic [N_LANES-1:0] note_hit_zone;              // lanes with any hittable note
    logic [N_LANES-1:0] late_last;                  // note in its last late frame
    logic [N_LANES-1:0] lane_missed;                // un-hit note leaving the late window

    always_comb begin
        for (int L = 0; L < N_LANES; L++) begin
            late_last[L] = late[L][LATE_WINDOW-1];
            for (int j = 0; j < HIT_WINDOW; j++)
                live_early[L][j] = (slots[L][j] == CELL_NOTE) && !done[L][j];
            note_hit_zone[L] = (|live_early[L]) || (|late[L]);
        end
    end

    // The frets must match the lanes in the window exactly (a chord needs all
    // of its frets), except that a fret held for a sustain in another lane is
    // ignored -- otherwise every tap note during a hold would be a miss.
    logic fret_match;
    logic hit_now;
    assign fret_match = ((fret & ~hold_line) == note_hit_zone) && (note_hit_zone != '0);
    assign hit_now    = strum_now && fret_match;

    // A hit takes every hittable note in its lanes with it
    logic [N_LANES-1:0] lane_hit;
    assign lane_hit = hit_now ? note_hit_zone : '0;

    // Missed: the note is in its last late frame and is not being hit now
    assign lane_missed = late_last & ~lane_hit;

    // Hold-line scoring for this frame, summed over every lane at once:
    // +1 per lane whose tail is on the hit line with its fret held, -1 per
    // lane whose tail is there without it.
    logic signed [15:0] hold_delta;
    always_comb begin
        hold_delta = 16'sd0;
        for (int L = 0; L < N_LANES; L++) begin
            if (hold_line[L]) begin
                if (fret[L]) hold_delta = hold_delta + 16'sd1;
                else         hold_delta = hold_delta - 16'sd1;
            end
        end
    end

    // Everything that happens to the score on this frame, added up
    logic signed [15:0] frame_delta;
    always_comb begin
        frame_delta = hold_delta;
        if (strum_now) frame_delta = frame_delta + (fret_match ? 16'sd10 : -16'sd5);
        for (int L = 0; L < N_LANES; L++)
            if (lane_missed[L]) frame_delta = frame_delta - 16'sd5;
    end

    // score + delta, but never below zero
    function automatic logic signed [15:0] add_floor0(input logic signed [15:0] s,
                                                      input logic signed [15:0] d);
        logic signed [16:0] sum;
        sum = 17'(s) + 17'(d);
        return (sum < 0) ? 16'sd0 : sum[15:0];
    endfunction

    always_ff @(posedge clk50) begin
        if (rst) begin
            score         <= 16'sd0;
            strum_pending <= 1'b0;
            done          <= '0;
            late          <= '0;
        end
        else if (frame_tick) begin
            score         <= add_floor0(score, frame_delta);
            strum_pending <= 1'b0;   // every strum is judged exactly once

            // note_feeder shifts `slots` one place toward the line on this
            // same edge, so shift the masks with it.
            for (int L = 0; L < N_LANES; L++) begin
                for (int j = 0; j < HIT_WINDOW - 1; j++)
                    done[L][j] <= done[L][j+1] ||
                                  (lane_hit[L] && slots[L][j+1] == CELL_NOTE);
                done[L][HIT_WINDOW-1] <= 1'b0;   // arrives from outside the window

                late[L][0] <= live_early[L][0] && !lane_hit[L];  // crossed the line un-hit
                for (int k = 1; k < LATE_WINDOW; k++)
                    late[L][k] <= late[L][k-1] && !lane_hit[L];
            end
        end
        else if (strum_edge) begin
            strum_pending <= 1'b1;
        end
    end
endmodule
