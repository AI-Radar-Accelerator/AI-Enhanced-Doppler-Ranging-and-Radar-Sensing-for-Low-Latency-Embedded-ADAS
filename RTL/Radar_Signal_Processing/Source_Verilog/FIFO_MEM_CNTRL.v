module FIFO_MEM_CNTRL #(
    parameter DATA_WIDTH = 32,      
    parameter DEPTH      = 32,
    parameter ADDR_WIDTH = 5        // log2(DEPTH)

) (
    input  wire                      W_CLK     ,    // Write clock
    input  wire                      W_RST     ,    // Write reset
    input  wire                      W_INC     ,    // Write increment/enable
    input  wire                      FULL      ,    // FIFO full flag
    input  wire   [DATA_WIDTH-1:0]   WR_DATA   ,    // Write data
    input  wire   [ADDR_WIDTH-1:0]   w_addr    ,    // Write address
    input  wire   [ADDR_WIDTH-1:0]   r_addr    ,    // Read address
    output wire   [DATA_WIDTH-1:0]   RD_DATA        // Read data
);

    wire    w_en;                       // Write enable

    assign w_en = W_INC && !FULL;       // Write enable logic

    reg [DATA_WIDTH-1:0] fifo_mem [DEPTH-1:0];  // FIFO memory

    reg [DEPTH-1:0]  I ;

    always @(posedge W_CLK or negedge W_RST) 
    begin
        if (!W_RST) 
        begin
            for (I=0; I<DEPTH; I=I+1)       // Initialize FIFO memory
            fifo_mem[I] <= 'b0;
        end 
        else if (w_en) 
        begin
            fifo_mem[w_addr] <= WR_DATA;    // Write data to FIFO memory
        end

    end

    assign RD_DATA = fifo_mem[r_addr];    // Read data from FIFO memory
endmodule