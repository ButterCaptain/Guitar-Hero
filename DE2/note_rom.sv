
module note_rom #(
    parameter int    DATA_W  = 16,          // bits per word
    parameter int    ADDR_W  = 11,          // 2**11 = 2048 words of storage
    parameter string HEXFILE = "notes.hex"  // file loaded at power-up
)(
    input  logic                clk,
    input  logic [ADDR_W-1:0]   addr,
    output logic [DATA_W-1:0]   dout
);

    // The storage itself: 2**ADDR_W words, each DATA_W bits wide.
    logic [DATA_W-1:0] mem [0:2**ADDR_W-1];

    // Runs once, before the simulation (or the FPGA) starts. On a real DE0
    // this becomes the initial contents baked into the M9K block RAM.
    initial begin
        $readmemh(HEXFILE, mem);
    end

    // Synchronous read: whatever address you present on one clock edge shows
    // up on dout after the NEXT clock edge.
    always_ff @(posedge clk)
        dout <= mem[addr];

endmodule
