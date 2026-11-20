// ============================================================================
//  audio_fifo.sv -- the buffer between the SD card and the speaker.
//
//  The card delivers audio in bursts (a 512-byte sector at a time, with pauses
//  in between while it looks things up), but the speaker wants exactly one
//  sample every 1/48000 s. This first-in-first-out queue soaks up the
//  difference.
//
//  One entry = one {left, right} sample pair (32 bits). With AW = 12 that is
//  4096 entries = 85 ms of 48 kHz audio, in 16 of the FPGA's M9K memory blocks.
//
//  Reading: raise `rd_en` for one cycle. The sample shows up on `rd_data` ONE
//  CYCLE LATER (the memory block has a registered output). Do not read when
//  `empty`, do not write when `full` -- both are simply ignored if you do.
// ============================================================================

module audio_fifo #(
    parameter int AW = 12                // 2^AW entries
)(
    input  logic          clk,
    input  logic          rst,

    input  logic          wr_en,
    input  logic [31:0]   wr_data,

    input  logic          rd_en,
    output logic [31:0]   rd_data,

    output logic [AW:0]   count,         // entries currently stored
    output logic          empty,
    output logic          full
);

    localparam int DEPTH = 1 << AW;

    // Written exactly like this so Quartus turns it into M9K RAM blocks
    // rather than 131072 flip-flops.
    logic [31:0] mem [0:DEPTH-1];

    logic [AW-1:0] wr_ptr, rd_ptr;

    logic do_wr, do_rd;
    assign do_wr = wr_en && !full;
    assign do_rd = rd_en && !empty;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);

    always_ff @(posedge clk) begin
        if (do_wr) mem[wr_ptr] <= wr_data;
    end

    always_ff @(posedge clk) begin
        rd_data <= mem[rd_ptr];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end
        else begin
            if (do_wr) wr_ptr <= wr_ptr + 1'b1;
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;
            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: ;
            endcase
        end
    end

endmodule
