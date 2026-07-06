module FIFO_WR #(
    parameter ADDR_WIDTH = 5,
    parameter PTR_WIDTH  = 6
)(
    input  wire                    W_CLK   ,   
    input  wire                    W_RST   ,   
    input  wire                    W_INC   ,   
    input  wire   [PTR_WIDTH-1:0]  wq2_rptr,   
    output reg                     FULL    ,   
    output wire   [ADDR_WIDTH-1:0] w_addr  ,   
    output reg    [PTR_WIDTH-1:0]  w_ptr       
);
    //  Solution: full-size binary counter for write pointer
    reg [PTR_WIDTH-1:0] w_bin_v;

    wire [PTR_WIDTH-1:0] w_bin_next = w_bin_v + (W_INC && !FULL);
    wire [PTR_WIDTH-1:0] w_ptr_next = w_bin_next ^ (w_bin_next >> 1);

always @(posedge W_CLK or negedge W_RST) begin
        if (!W_RST) begin
            w_bin_v <= 0;
            w_ptr   <= 0; // safely reset
        end else begin
            w_bin_v <= w_bin_next;
            w_ptr   <= w_ptr_next; // updates Gray-coded pointer synchronously and cleanly
        end
    end

    assign w_addr = w_bin_v[ADDR_WIDTH-1:0];

    // Compute FULL flag based on stable registers
    always @(*) begin
         FULL = ((w_ptr[PTR_WIDTH-1] != wq2_rptr[PTR_WIDTH-1]) && 
                 (w_ptr[PTR_WIDTH-2] != wq2_rptr[PTR_WIDTH-2]) && 
                 (w_ptr[PTR_WIDTH-3:0] == wq2_rptr[PTR_WIDTH-3:0]));
    end
endmodule