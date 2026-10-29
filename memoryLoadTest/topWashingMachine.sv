module topWashingMachine #(
	parameter DATASIZE = 26 // the amount of notes, after its done this many it stops

)(
	input logic rst_n,
	CLOCK_50,
	output logic [7:0] LED
	);

logic [9:0]  address_signal;
logic [15:0] rom_data;


rom_init #(.DATA_W(16), .ADDR_W(10), .DATASIZE(DATASIZE)) my_rom ( 
    .clk (CLOCK_50),				
    .addr(address_signal),
    .dout(rom_data)
); // read my_rom and get the rom_data at whatever the address signal is
	// does this 50 million times a second so maybe we can change that

logic [15:0] frame; 			// current frame
logic [19:0] clkCounter;		// clock counter for 60fps
logic [15:0] shiftRegister [7:0];	// the shift registers

logic stopEnable;	


    always_ff @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin

	frame <= 0;
 	clkCounter <= 0;
	address_signal <= 0;
	stopEnable <= 0;
				// reset all the values

	for (int k = 0; k < 8; k++) begin 
            // sets all registers to 0 on reset
            begin
                shiftRegister[k] <= '0;
            end 
        end



	end
	else begin
		if (!stopEnable) begin

		clkCounter <= clkCounter + 1; 


        	if(clkCounter == 833333) begin
        	clkCounter <= 0;
		frame <= frame + 1; // adds a frame every 833333rd clock count

		if(rom_data[14:0] <= frame) begin // if the data at the memory location is <= the current frame, add it to the shift register
		

			for (int k = 0; k < 7; k++) begin 
            		        begin
                		shiftRegister[k] <= shiftRegister[k+1];
            			end
				// for all shift registers 0-7 move them back one
        		end
		shiftRegister[7] <= rom_data; // then set the new one to rom_data

		



		address_signal <= address_signal + 1; // increment memory adress, now rom_data is reading from the next location
		
		if(address_signal == DATASIZE - 1) 
		stopEnable <= 1; // if its at the final position then stopEnable
		
		end
		end
	end

end 
    end


    always_comb begin

        for (int i = 0; i < 8; i++) begin 
                LED[i] = shiftRegister[i][15]; // always set the leds to the shift register[i]'s most significant digit
        end
    end


endmodule