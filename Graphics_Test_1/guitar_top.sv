import highway_pkg::*;


//  The throwaway note generator is gone. `slots` is now driven by
//  note_feeder, which reads the chart out of notes.hex.
module guitar_top (
    input  logic               clk50,
    input  logic               rst,
    input  logic [4:0]         fret,
    input  logic               strum_up,
    input  logic               strum_down,
    output logic               hsync,
    output logic               vsync,
    output logic [3:0]         r,
    output logic [3:0]         g,
    output logic [3:0]         b,
    output logic signed [15:0] score
);
    // The 2D Array where the notes are held
    logic [N_LANES-1:0][N_SLOTS-1:0][1:0] slots;
    // Global Fram tick so everything is synced 
    logic frame_tick;
    // Counts the frames
    logic [14:0] frame_count;
    logic song_done;
    // Per-lane "a held note is over the hit line, the user should be holding
    // this fret". The hit-detect FSM can just AND this with `fret`.
    logic [N_LANES-1:0] hold_line;

    highway_draw draw_unit (
        .clk50      (clk50),
        .rst        (rst),
        .slots      (slots),
        .hsync      (hsync),
        .vsync      (vsync),
        .frame_tick (frame_tick),
        .vga_r      (r),
        .vga_g      (g),
        .vga_b      (b),
        .hold_line  (hold_line)
    );

    // Reads the note chart and pushes notes onto the far end of the highway.
    //
    // HEXFILE is handed to $readmemh, which resolves a relative path against
    // the WORKING DIRECTORY OF THE PROCESS -- not against the directory this
    // .sv file lives in. Verilog has no notion of "next to the source file".
    // So this path assumes you launch from the project root:
    //
    //     ./obj_dir/guitar_sim          <- works, cwd is the project root
    //     cd obj_dir && ./guitar_sim    <- FAILS, cwd has no rtl/ in it
    //
    // If the file cannot be opened, Verilator prints ONE warning
    // ("$readmem file not found") and then carries on with the ROM full of
    // zeros. Zeros mean note_count = 0 for every lane, so the feeder decides
    // the song is over on frame one and not a single note ever spawns -- an
    // empty highway that otherwise looks perfectly healthy. If you see no
    // notes, scroll up and check for that warning first.
    note_feeder #(
        .HEXFILE("rtl/notes.hex"),
        .ADDR_W (11)
    ) feeder (
        .clk50       (clk50),
        .rst         (rst),
        .frame_tick  (frame_tick),
        .slots       (slots),
        .frame_count (frame_count),
        .song_done   (song_done)
    );

    // Placeholder until the hit-detect FSM exists.
    always_comb begin
        score = 16'sd0;
    end

endmodule
