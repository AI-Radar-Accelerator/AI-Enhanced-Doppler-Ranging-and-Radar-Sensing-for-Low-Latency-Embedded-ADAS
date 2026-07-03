module DF_SYNC #(
    parameter NUM_STAGES = 2 ,
	parameter BUS_WIDTH  = 4 
) (
    input  wire                     CLK           ,     // Clock
    input  wire                     RST           ,     // Reset
    input  wire   [BUS_WIDTH-1:0]   ASYNC_DATA    ,     // Asynchronous data
    output reg    [BUS_WIDTH-1:0]   SYNC_DATA           // Synchronized data
);

    reg [NUM_STAGES-1:0] sync_reg [BUS_WIDTH-1:0];      // Synchronization registers

    integer  I ;

    always @(posedge CLK or negedge RST) 
    begin
        if (!RST) begin
            for (I=0; I<BUS_WIDTH; I=I+1)           // Initialize synchronization registers
                sync_reg[I] <= 'b0;
        end else begin
            for (I=0; I<BUS_WIDTH; I=I+1)           // Shift synchronization registers
                sync_reg[I] <= {sync_reg[I][NUM_STAGES-2:0],ASYNC_DATA[I]};
        end
    end

    // Output synchronized data
    always @(*)
    begin
     for (I=0; I<BUS_WIDTH; I=I+1)
       SYNC_DATA[I] = sync_reg[I][NUM_STAGES-1] ; 
    end 

endmodule