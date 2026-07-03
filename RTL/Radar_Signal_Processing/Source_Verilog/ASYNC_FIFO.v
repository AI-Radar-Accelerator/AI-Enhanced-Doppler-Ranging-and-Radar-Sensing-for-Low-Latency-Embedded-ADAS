module ASYNC_FIFO #(
    parameter DATA_WIDTH = 32,               // Data width
    parameter DEPTH      = 32,               // FIFO depth
    parameter NUM_STAGES = 2,               // Number of flip-flops for synchronization
    parameter ptr_width  = 6                 // Pointer width
) (
    input  wire                        W_CLK   ,    // Write clock
    input  wire                        W_RST   ,    // Write reset
    input  wire                        W_INC   ,    // Write increment/enable
    input  wire                        R_CLK   ,    // Read clock
    input  wire                        R_RST   ,    // Read reset
    input  wire                        R_INC   ,    // Read increment/enable
    input  wire   [DATA_WIDTH-1:0]     WR_DATA ,    // Write data
    output wire   [DATA_WIDTH-1:0]     RD_DATA ,    // Read data
    output wire                        FULL    ,    // FIFO full flag
    output wire                        EMPTY        // FIFO empty flag
);

    wire   [ptr_width-2:0]   w_addr  ;            // Write address
    wire   [ptr_width-2:0]   r_addr  ;            // Read address
    wire   [ptr_width-1:0]   w_ptr   ;            // Write pointer
    wire   [ptr_width-1:0]   r_ptr   ;            // Read pointer
    wire   [ptr_width-1:0]   wq2_rptr;            // Write pointer to read pointer
    wire   [ptr_width-1:0]   rq2_wptr;            // Read pointer to write pointer

    // Instantiate FIFO memory control
    FIFO_MEM_CNTRL #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH),
        .ADDR_WIDTH(ptr_width-1)
    ) fifo_mem_cntrl_inst (
        .W_CLK(W_CLK),
        .W_RST(W_RST),
        .W_INC(W_INC),
        .FULL(FULL),
        .WR_DATA(WR_DATA),
        .w_addr(w_addr),
        .r_addr(r_addr),
        .RD_DATA(RD_DATA)
    );

    // Instantiate write pointer to read pointer synchronizer
    DF_SYNC #(
        .NUM_STAGES(NUM_STAGES),
        .BUS_WIDTH(ptr_width)
    ) df_sync_w2r_inst (
        .CLK(R_CLK),
        .RST(R_RST),
        .ASYNC_DATA(w_ptr),
        .SYNC_DATA(rq2_wptr)
    );

    // Instantiate read pointer to write pointer synchronizer
    DF_SYNC #(
        .NUM_STAGES(NUM_STAGES),
        .BUS_WIDTH(ptr_width)
    ) df_sync_r2w_inst (
        .CLK(W_CLK),
        .RST(W_RST),
        .ASYNC_DATA(r_ptr),
        .SYNC_DATA(wq2_rptr)
    );

    // Instantiate write control logic
    FIFO_WR #(
        .ADDR_WIDTH(ptr_width-1),
        .PTR_WIDTH(ptr_width)
    )fifo_wr_inst (
        .W_CLK(W_CLK),
        .W_RST(W_RST),
        .W_INC(W_INC),
        .wq2_rptr(wq2_rptr),
        .FULL(FULL),
        .w_addr(w_addr),
        .w_ptr(w_ptr)
    );

    // Instantiate read control logic
    FIFO_RD #(
        .PTR_WIDTH(ptr_width),
        .ADDR_WIDTH(ptr_width-1)
    )
    fifo_rd_inst (
        .R_INC(R_INC),
        .R_CLK(R_CLK),
        .R_RST(R_RST),
        .rq2_wptr(rq2_wptr),
        .EMPTY(EMPTY),
        .r_addr(r_addr),
        .r_ptr(r_ptr)
    );  
endmodule
