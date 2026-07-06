//the input of ThreeStreamsToOneStream is 3 streams from the previous stage (z score norm)
// the output of ThreeStreamsToOneStream is 1 stream
//what is the purpose of this code? to tranform 3 streams to 1 stream 
//why? because the output of this block is the input to conv2d_matmul
//the input to conv2d_matmul is one stream



module ThreeStreamsToOneStream #(
	parameter DATA_W = 16,                         //total bits per sample (signed fixed-point)
	parameter FRAC_W = 8,                          //number of fractional bits
    parameter H_IN = 64,                           //height of each channel is 64
    parameter W_IN = 256                           //width of each channel is 255
)




(

	input wire clk,
	input wire rst_n,                               //active low reset


	//channel 0, stream 0 (1 of the three streams)
	input  wire                  in_valid_ch0,             //HIGH when ch0 data is valid (means the data from the previous stage is useful, not garbage)
	output wire                  in_ready_ch0,             //HIGH when ready to accept ch0 data (it is an input to the previous stage to let know this stage is ready)
	input  wire [DATA_W-1:0]     in_data_ch0,              //channel 0 pixel value (DATA_W-bit signed fixed-point, FRAC_W fractional bits)
	
	
	//channel 1, stream 1 (1 of the three streams)
	input  wire                  in_valid_ch1,             //HIGH when ch1 data is valid (means the data from the previous stage is useful, not garbage)
	output wire                  in_ready_ch1,             //HIGH when ready to accept ch1 data (it is an input to the previous stage to let know this stage is ready)
	input  wire [DATA_W-1:0]     in_data_ch1,              //channel 1 pixel value (DATA_W-bit signed fixed-point, FRAC_W fractional bits)
	
	
	//channel 2, stream 2 (1 of the three streams)
	input  wire                  in_valid_ch2,              //HIGH when ch2 data is valid (means the data from the previous stage is useful, not garbage)
	output wire                  in_ready_ch2,              //HIGH when ready to accept ch2 data (it is an input to the previous stage to let know this stage is ready)
	input  wire [DATA_W-1:0]     in_data_ch2,               //channel 2 pixel value (DATA_W-bit signed fixed-point, FRAC_W fractional bits)
	

	//the output as one stream (the merge of the 3 input streams)
	output wire                  out_valid,                       //HIGH when out_data is valid, useful data, so the next stage should store it
	input  wire                  out_ready,                       //HIGH when conv2d_matmul is ready to accept out_data
	output reg  [DATA_W-1:0]     out_data                         //output stream pixel value (DATA_W-bit signed fixed-point, FRAC_W fractional bits)

);



localparam pixels = H_IN * W_IN;                         //the number of elements of one stream, it is the height*width



//buffers for each stream
(* ram_style = "block" *) reg [DATA_W-1:0] buf0 [0:pixels-1];                      //buffer0 for stream 0, of width DATA_W, and depth H_IN*W_IN
(* ram_style = "block" *) reg [DATA_W-1:0] buf1 [0:pixels-1];                      //buffer1 for stream 1, of width DATA_W, and depth H_IN*W_IN
(* ram_style = "block" *) reg [DATA_W-1:0] buf2 [0:pixels-1];                      //buffer2 for stream 2, of width DATA_W, and depth H_IN*W_IN



//write pointers
reg [$clog2(pixels)-1:0] wr_ptr0, wr_ptr1, wr_ptr2;      //to point at the buffers
reg full0, full1, full2;                                  //full0 is HIGH when the buffer of channel 0 is full
                                                          //full1 is HIGH when the buffer of channel 1 is full
                                                          //full2 is HIGH when the buffer of channel 2 is full



//read state
reg [1:0] rd_ch;                                          //to switch between channels (streams) when reading (0, 1, or 2)
reg [$clog2(pixels)-1:0] rd_ptr;                          //a pointer to point at the pixel to be read
reg rd_active;                                            //HIGH when we are issuing a read address this cycle (address phase)
reg out_valid_r;                                           //registered: HIGH one cycle after rd_active, i.e. when out_data is actually valid




wire all_full = full0 && full1 && full2;                  //HIGH when all three buffers are full (used to know when to read)

// The output register stage (out_data / out_valid_r) can accept a new
// address-phase result whenever it is empty or the consumer is taking
// the current word this cycle. This is the same one-stage pipeline
// handshake used elsewhere in this design (BN.v, silu.v).
wire out_stage_ready = !out_valid_r || out_ready;

//rd_done condition: fires on the address-phase cycle that issues the LAST
//read address (rd_ch==2, rd_ptr==pixels-1), gated by out_stage_ready so it
//only fires when that address actually gets accepted into the output
//register this cycle (mirrors how rd_active/rd_ptr now advance below).
wire rd_done = rd_active && out_stage_ready && (rd_ch == 2) && (rd_ptr == pixels - 1);      //this flag is HIGH only on the address-issue cycle for the last pixel of channel 2




assign in_ready_ch0 = !full0 && !rd_active;       //channel0 only accepts new data if the buffer is not full & the module isn't currently reading out
assign in_ready_ch1 = !full1 && !rd_active;       //channel1 only accepts new data if the buffer is not full & the module isn't currently reading out
assign in_ready_ch2 = !full2 && !rd_active;       //channel2 only accepts new data if the buffer is not full & the module isn't currently reading out




//output
assign out_valid = out_valid_r;                          //out_data is valid one cycle after its address was issued (registered BRAM read)

//Each buffer gets its OWN dedicated read-register always block, touching
//only that one array -- this is the clean single-read-port template
//Vivado's RAM extractor expects, one per BRAM instance.
reg [DATA_W-1:0] buf0_q, buf1_q, buf2_q;
wire rd_fire = rd_active && out_stage_ready;     //an address is being issued AND accepted into the pipeline this cycle

always @(posedge clk) begin
	if (rd_fire && (rd_ch == 0))
		buf0_q <= buf0[rd_ptr];
end

always @(posedge clk) begin
	if (rd_fire && (rd_ch == 1))
		buf1_q <= buf1[rd_ptr];
end

always @(posedge clk) begin
	if (rd_fire && (rd_ch == 2))
		buf2_q <= buf2[rd_ptr];
end

//Mux the already-registered words (not the raw memories) + track which
//channel the pending registered word came from, so out_data can select
//the right one. rd_ch_q remembers rd_ch from the cycle the address was
//issued, since rd_ch itself may have already moved on by the time the
//data lands.
reg [1:0] rd_ch_q;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n)
		rd_ch_q <= 2'd0;
	else if (rd_fire)
		rd_ch_q <= rd_ch;
end

always @(*) begin
	case (rd_ch_q)
		2'd0:    out_data = buf0_q;
		2'd1:    out_data = buf1_q;
		default: out_data = buf2_q;
	endcase
end

//registered 3-to-1 valid: an address was issued+accepted last cycle ->
//data is valid this cycle. Pure control register, touches no memory.
always @(posedge clk or negedge rst_n)
	begin
		if (!rst_n)
			out_valid_r <= 1'b0;
		else if (out_stage_ready)
			out_valid_r <= rd_fire;
		//else: out_stage_ready is low (consumer stalled, out_valid_r already 1) -> hold
	end





//write channel 0 -- MEMORY WRITE ONLY, isolated in its own always block so
//Vivado's RAM extractor sees a clean single-write-port pattern with nothing
//else (pointers, flags) touching buf0 in the same process.
wire wren0 = in_valid_ch0 && in_ready_ch0;
always @(posedge clk) begin
	if (wren0)
		buf0[wr_ptr0] <= in_data_ch0;              //load the data from channel 0 into buffer 0
end

//channel 0 pointer / full-flag bookkeeping -- separate always block,
//behavior identical to before, just no longer touching buf0 directly.
always @(posedge clk or negedge rst_n) 
	begin
		if (!rst_n)                                        //if reset is low
			begin
				wr_ptr0 <= 0;                              //it places the pointer at the first place in the buffer
				full0   <= 0;                              //and lowers the flag that says the buffer is full
			end 
		
		else if (wren0)             //if the input to this buffer was valid (has meaning) and the buffer is not full and we are not in reading state
			begin
				if (wr_ptr0 == pixels - 1)                 //if the pointer reached the bottom of the buffer (the bottom of the memory)
					begin
						wr_ptr0 <= 0;                      //the pointer points at the top
						full0   <= 1;                      //the flag of full0 is raised, meaning the buffer 0 is full
					end 
				else
					wr_ptr0 <= wr_ptr0 + 1;                //else, the pointer points to the next place in the buffer
			end 
			 
		else if (rd_done)                                  //when the read phase finishes, clear the full flag so the buffer can accept the next frame
			begin
				full0 <= 0;
			end
	end





//write channel 1 -- MEMORY WRITE ONLY, isolated in its own always block.
wire wren1 = in_valid_ch1 && in_ready_ch1;
always @(posedge clk) begin
	if (wren1)
		buf1[wr_ptr1] <= in_data_ch1;
end

//channel 1 pointer / full-flag bookkeeping -- separate always block.
always @(posedge clk or negedge rst_n) 
	begin
		if (!rst_n) 
			begin
				wr_ptr1 <= 0;
				full1   <= 0;
			end 
		
		else if (wren1) 
			begin
				if (wr_ptr1 == pixels - 1) 
					begin
						wr_ptr1 <= 0;
						full1   <= 1;
					end 
				else
					wr_ptr1 <= wr_ptr1 + 1;
			end 
			 
		else if (rd_done)
			begin
				full1 <= 0;
			end
	end





//write channel 2 -- MEMORY WRITE ONLY, isolated in its own always block.
wire wren2 = in_valid_ch2 && in_ready_ch2;
always @(posedge clk) begin
	if (wren2)
		buf2[wr_ptr2] <= in_data_ch2;
end

//channel 2 pointer / full-flag bookkeeping -- separate always block.
always @(posedge clk or negedge rst_n) 
	begin
		if (!rst_n) 
			begin
				wr_ptr2 <= 0;
				full2   <= 0;
			end 
		
		else if (wren2) 
			begin
				if (wr_ptr2 == pixels - 1) 
					begin
						wr_ptr2 <= 0;
						full2   <= 1;
					end 
				else
					wr_ptr2 <= wr_ptr2 + 1;
			end 
			 
		else if (rd_done)
			begin
				full2 <= 0;
			end
	end





//read - address-phase FSM. Issues (rd_ch, rd_ptr) combinationally; the
//always block above captures buf[rd_ptr] into out_data one cycle later.
//Advances only when out_stage_ready (output register is free or being
//consumed this cycle) so no address result is ever dropped or overwritten.
//INTERLEAVED OUTPUT ORDER: ch0_pix0, ch1_pix0, ch2_pix0, ch0_pix1, ch1_pix1, ch2_pix1, ...
always @(posedge clk or negedge rst_n) 
	begin
		if (!rst_n)                    //when reseting, the selection of the mux selects channel 0, the pointer points to the top of the buffer, we are not in read mode 
			begin
				rd_ch     <= 0;
				rd_ptr    <= 0;
				rd_active <= 0;
			end 
		else 
			begin
				if (!rd_active && all_full && out_stage_ready)                //if we are not in reading mode & all the buffers are full & the output register has room, then we should get into reading mode
					begin
						rd_active <= 1;                      //get into reading mode          
						rd_ch     <= 0;                      //the mux chooses channel 0
						rd_ptr    <= 0;                      //the pointer is pointed at the top of the buffer
					end 
					
				else if (rd_active && out_stage_ready)           // an address was issued and the output register can accept its result this cycle -> advance to the next address
					begin
						if (rd_ch == 2)                      //if we just issued the address for channel 2, we need to move to the next pixel
							begin
								rd_ch <= 0;                    //go back to channel 0
								if (rd_ptr == pixels - 1)      //if this was the last pixel
									begin
										rd_ptr    <= 0;          //reset pointer
										rd_active <= 0;          //exit read mode
									end
								else
									rd_ptr <= rd_ptr + 1;      //move to next pixel
							end 
						else                                 //if we're on channel 0 or 1
							begin
								rd_ch <= rd_ch + 1;            //move to next channel (same pixel)
							end
					end
				else if (!out_stage_ready)
					begin
						rd_active <= rd_active;               //output register is stalled (out_valid_r high, out_ready low) -> hold address phase, do not issue a new address
					end
			end
	end


endmodule