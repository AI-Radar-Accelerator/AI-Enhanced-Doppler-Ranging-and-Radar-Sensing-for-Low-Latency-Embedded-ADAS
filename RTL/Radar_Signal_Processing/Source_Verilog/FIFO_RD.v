module FIFO_RD #(
    parameter ADDR_WIDTH = 5,
    parameter PTR_WIDTH  = 6
)(
    input  wire                   R_INC,        
    input  wire                   R_CLK,        
    input  wire                   R_RST,        
    input  wire   [PTR_WIDTH-1:0] rq2_wptr,    
    output reg                    EMPTY,        
    output wire   [ADDR_WIDTH-1:0] r_addr,       
    output reg    [PTR_WIDTH-1:0] r_ptr         // Convert to synchronized Reg 100%
);
    reg [PTR_WIDTH-1:0] r_bin_v;

    // Logic for instant read prediction
    wire [PTR_WIDTH-1:0] r_bin_next = r_bin_v + (R_INC && !EMPTY);
    wire [PTR_WIDTH-1:0] r_ptr_next = r_bin_next ^ (r_bin_next >> 1);

    always @(posedge R_CLK or negedge R_RST) begin
        if (!R_RST) begin
            r_bin_v <= 0;
            r_ptr   <= 0;
        end else begin
            r_bin_v <= r_bin_next;
            r_ptr   <= r_ptr_next;
        end
    end

    assign r_addr = r_bin_v[ADDR_WIDTH-1:0];

    always @(*) begin   
         EMPTY = (r_ptr == rq2_wptr);
    end
endmodule