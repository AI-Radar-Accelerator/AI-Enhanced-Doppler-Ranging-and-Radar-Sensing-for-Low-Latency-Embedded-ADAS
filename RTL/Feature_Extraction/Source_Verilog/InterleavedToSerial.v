module InterleavedToSerial #(
    parameter DATA_W = 16,     // bits per sample (signed fixed-point)
    parameter FRAC_W = 8,      // fractional bits  (informational)
    parameter N_CH   = 128,    // number of interleaved channels
    parameter H_IN   = 16,     // spatial height of one channel  -- TEMP: matches real CSP_Top instantiation (was 64) for standalone OOC synth sizing; restore/override as needed elsewhere
    parameter W_IN   = 32      // spatial width  of one channel  -- TEMP: matches real CSP_Top instantiation (was 255) for standalone OOC synth sizing; restore/override as needed elsewhere
)
(
    input  wire               clk,
    input  wire               rst_n,     // active-low synchronous reset
    //INPUT: interleaved stream
    input  wire               in_valid,  // upstream data valid
    output wire               in_ready,  // this module ready to accept
    input  wire [DATA_W-1:0]  in_data,   // interleaved pixel word
    //OUTPUT: serial stream
    output wire               out_valid, // output data valid
    input  wire                out_ready, // downstream ready
    output wire [DATA_W-1:0]  out_data   // serialised pixel word
);
localparam integer PIXELS   = H_IN * W_IN;        // pixels per channel
localparam integer CH_W     = $clog2(N_CH);       // bits to address a channel
localparam integer PIX_W    = $clog2(PIXELS);     // bits to address a pixel

// =============================================================================
// Storage — isolated, single write port / single read port, both synchronous.
// Nothing else (pointers, flags) shares either always block with mem[].
// =============================================================================
(* ram_style = "block" *) reg [DATA_W-1:0] mem [0:N_CH*PIXELS-1];

reg rd_active;   // HIGH during the address-ISSUE phase of the serial read
//write counters
reg [CH_W-1:0]  in_ch;       // which channel the incoming word belongs to
reg [PIX_W-1:0] in_pix;      // pixel address within that channel
reg all_full;
//read counters (address-issue phase)
reg [CH_W-1:0]  rd_ch;
reg [PIX_W-1:0] rd_ptr;

assign in_ready  = !rd_active && !all_full;

// -----------------------------------------------------------------------
// Output register (skid stage) — one cycle of registered-read latency
// between the address-issue phase (rd_active/rd_ch/rd_ptr) and out_data.
// -----------------------------------------------------------------------
reg                out_valid_r;
reg [DATA_W-1:0]   out_data_r;

wire out_stage_ready = !out_valid_r || out_ready;   // output register free, or being drained this cycle
wire rd_fire = rd_active && out_stage_ready;         // an address is issued AND accepted into the pipeline this cycle

assign out_valid = out_valid_r;
assign out_data  = out_data_r;

// rd_done: fires on the address-issue cycle for the LAST word of the frame,
// gated by out_stage_ready so it only fires when that address is actually
// accepted this cycle (mirrors the rd_active/rd_ch/rd_ptr advance below).
wire rd_done = rd_fire
               && (rd_ch  == N_CH   - 1)
               && (rd_ptr == PIXELS - 1);

// -----------------------------------------------------------------------
// Memory write — isolated, touches ONLY mem[]
// -----------------------------------------------------------------------
wire wr_en = in_valid && in_ready;
always @(posedge clk) begin
    if (wr_en)
        mem[ in_ch * PIXELS + in_pix ] <= in_data;
end

// -----------------------------------------------------------------------
// Memory read — isolated, touches ONLY mem[]. Registered (synchronous)
// read: captures mem[rd_ch*PIXELS+rd_ptr] one cycle after rd_fire.
// -----------------------------------------------------------------------
always @(posedge clk) begin
    if (rd_fire)
        out_data_r <= mem[ rd_ch * PIXELS + rd_ptr ];
end

// -----------------------------------------------------------------------
// Output valid register — pure control, touches no memory.
// -----------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        out_valid_r <= 1'b0;
    else if (out_stage_ready)
        out_valid_r <= rd_fire;
    // else: out_stage_ready low (downstream stalled, out_valid_r already 1)
    //       -> hold out_valid_r, hold out_data_r
end

// -----------------------------------------------------------------------
// Write-side bookkeeping — pure control, touches no memory.
// -----------------------------------------------------------------------
always @(posedge clk or negedge rst_n)
	begin
		if (!rst_n) 
			begin
				in_ch    <= 0;
				in_pix   <= 0;
				all_full <= 0;
			end 
			
		else 
			begin
				if (rd_done)
					all_full <= 0;
	
				if (wr_en) 
					begin
						//advance interleave counters
						if (in_ch == N_CH - 1)
							begin
							//completed one full interleaved stripe (one pixel per channel)
								in_ch <= 0;
								if (in_pix == PIXELS - 1)
									begin
										in_pix   <= 0;
										all_full <= 1;          // last word of the frame
									end 
								else 
									begin
										in_pix <= in_pix + 1;
									end
							end 
						else 
							begin
								in_ch <= in_ch + 1;
							end
					end
			end
	end

// -----------------------------------------------------------------------
// Read-side address-issue FSM — pure control, touches no memory.
// Advances only when out_stage_ready, so no address result is ever
// dropped or overwritten in the output register (same fix applied to
// ThreeStreamsToOneStream's read FSM).
// -----------------------------------------------------------------------
always @(posedge clk or negedge rst_n) 
	begin
		if (!rst_n)
			begin
				rd_active <= 0;
				rd_ch     <= 0;
				rd_ptr    <= 0;
			end 
			
			
		else
			begin
			if (!rd_active && all_full && out_stage_ready) 
				begin
					rd_active <= 1;
					rd_ch     <= 0;
					rd_ptr    <= 0;
				end 
				
			else if (rd_active && out_stage_ready) 
				begin
					if (rd_ptr == PIXELS - 1) 
						begin
							rd_ptr <= 0;
							if (rd_ch == N_CH - 1) 
								begin
									rd_active <= 0;     //done(wait for next frame)
									rd_ch     <= 0;
								end 
							else 
								begin
									rd_ch <= rd_ch + 1;
								end
						end 
					else 
						begin
							rd_ptr <= rd_ptr + 1;
						end
				end
			end
	end
endmodule