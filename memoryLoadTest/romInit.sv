module rom_init #(
    parameter DATA_W,
    parameter ADDR_W, 
    parameter DATASIZE// parameters are set when design is compiled and not after (like constant variables)
)(
    input  logic                clk, // input and output are called "ports" and are connections in and out of module
    input  logic [ADDR_W-1:0]   addr,
    output logic [DATA_W-1:0]   dout
);

    logic [DATA_W-1:0] mem [0:2**ADDR_W-1]; // ** means raised to the second power
						// when ADDR_W is 10, it is 1024
						// indentical to logic [15:0] mem [0:1023];

//mem is name of memory array. it holds the data 1024 entries of 16 bits 

    initial begin // means it does only once during compilation and never again, it is baked into the hardware
        $readmemh("washingMachine.hex", mem, 0, DATASIZE-1); // has to be done during initialization can't be changed after (which is fine)

					// this fills mem on startup with whatever is it init.hex
    end

    always_ff @(posedge clk)
        dout <= mem[addr];		// sets dout to whatever value is at memory address addr

endmodule

