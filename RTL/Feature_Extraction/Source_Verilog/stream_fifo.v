module stream_fifo #(
    parameter DATA_W = 16,          // bits per pixel word (Q8.8 = 16)
    parameter DEPTH  = 524288       // FIFO depth in words — SIZE TO YOUR LATENCY DELTA
)
(
    input  wire clk,
    input  wire rst_n,      //active-low synchronous reset

    //upstream (connect to the fast finishing branch output)
    input  wire in_valid,                            //HIGH when the upstream has a valid data
    output wire in_ready,                            //High when the FIFO is ready to take data (not full)
    input  wire [DATA_W-1:0] in_data,                //input data

    //downstream
    output wire                 out_valid,          //HIGH when FIFO has valid data to give
    input  wire                 out_ready,          //downstream (next stage) is ready to take this data
    output wire [DATA_W-1:0]    out_data            //output data
);

localparam ADDR_W = $clog2(DEPTH);     // address width = log2(DEPTH)

// =============================================================================
// Storage — isolated, single write port / single read port, both synchronous.
// This is the standard "simple dual-port BRAM" template: one always block
// touching ONLY mem[] for writes, one always block touching ONLY mem[] for
// reads, nothing else (no pointers, no counts) sharing either process.
// =============================================================================
(* ram_style = "block" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

reg [ADDR_W-1:0] wr_ptr;     // points to next write location
reg [ADDR_W-1:0] rd_ptr;     // points to next location to PULL from mem into the output register

wire do_write = in_valid && in_ready;   // a word enters mem[] this cycle

// mem_count: words currently sitting in mem[] that have NOT yet been pulled
// into the output register. Used only to decide when it's safe to pull.
reg [ADDR_W:0] mem_count;

// out_valid_r/out_data_r form a one-deep output register (BRAM read latency
// buffer), same pattern used to fix ThreeStreamsToOneStream.
reg                out_valid_r;
reg [DATA_W-1:0]   out_data_r;

// Pull a word out of mem[] into the output register whenever mem[] has
// something AND the output register has room (empty, or being drained
// this same cycle).
wire out_stage_ready = !out_valid_r || out_ready;
wire do_pull = (mem_count != 0) && out_stage_ready;

// -----------------------------------------------------------------------
// Memory write — isolated, touches ONLY mem[]
// -----------------------------------------------------------------------
always @(posedge clk) begin
    if (do_write)
        mem[wr_ptr] <= in_data;
end

// -----------------------------------------------------------------------
// Memory read — isolated, touches ONLY mem[]. Registered (synchronous)
// read: captures mem[rd_ptr] one cycle after do_pull is asserted.
// -----------------------------------------------------------------------
always @(posedge clk) begin
    if (do_pull)
        out_data_r <= mem[rd_ptr];
end

// -----------------------------------------------------------------------
// Output valid register — one cycle behind do_pull, matches the
// registered read latency above. Pure control, touches no memory.
// -----------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        out_valid_r <= 1'b0;
    else if (out_stage_ready)
        out_valid_r <= do_pull;
    // else: out_stage_ready low (output register full, downstream stalled)
    //       -> hold out_valid_r, hold out_data_r
end

// -----------------------------------------------------------------------
// Write-pointer bookkeeping — pure control, touches no memory.
// -----------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        wr_ptr <= {ADDR_W{1'b0}};
    else if (do_write)
        wr_ptr <= wr_ptr + 1'b1;     // wraps naturally (mod 2^ADDR_W); DEPTH should be a power of 2
end

// -----------------------------------------------------------------------
// Read-pointer bookkeeping — pure control, touches no memory.
// -----------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rd_ptr <= {ADDR_W{1'b0}};
    else if (do_pull)
        rd_ptr <= rd_ptr + 1'b1;
end

// -----------------------------------------------------------------------
// mem_count — words resident in mem[] not yet pulled into the output
// register. Increments on write, decrements on pull.
// -----------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        mem_count <= {(ADDR_W+1){1'b0}};
    else begin
        case ({do_write, do_pull})
            2'b10: mem_count <= mem_count + 1'b1;   // write only
            2'b01: mem_count <= mem_count - 1'b1;   // pull only
            default: mem_count <= mem_count;        // both or neither
        endcase
    end
end

// -----------------------------------------------------------------------
// total_count — total words the FIFO currently owns, whether sitting in
// mem[] or parked in the output register. This is what in_ready (full/
// empty) must be based on, since overall capacity is DEPTH words
// end-to-end (mem[] + the 1-deep output register).
// Increments when a word is accepted on the input side, decrements when
// a word is accepted on the output side -- fully decoupled from the
// internal mem<->output-register shuffle (do_pull does not change it).
// -----------------------------------------------------------------------
reg [ADDR_W:0] total_count;
wire do_out_accept = out_valid_r && out_ready;   // a word leaves the FIFO this cycle

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        total_count <= {(ADDR_W+1){1'b0}};
    else begin
        case ({do_write, do_out_accept})
            2'b10: total_count <= total_count + 1'b1;   // accepted in, none out
            2'b01: total_count <= total_count - 1'b1;   // none in, one out
            default: total_count <= total_count;        // both or neither -> net zero change
        endcase
    end
end

wire full = (total_count == DEPTH);

assign in_ready  = !full;
assign out_valid = out_valid_r;
assign out_data  = out_data_r;

endmodule