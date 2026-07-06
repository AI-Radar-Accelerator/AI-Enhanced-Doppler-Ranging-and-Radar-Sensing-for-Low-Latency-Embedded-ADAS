module elem_add #(
   parameter  DATA_W    = 16
)(
    input  wire clk, rst_n,

    // skip connection stream (b1c1 — arrives first, must be buffered)
    input  wire              skip_valid, // output from skip block is valid (not garb data)
    output wire              skip_ready, // elem add block output signal that i am ready to take inputs 
    input  wire [DATA_W-1:0] skip_data,  

    // residual block stream (b1c2 — arrives second)
    input  wire              res_valid, // output from res block is valid (not garb data)
    output wire              res_ready, // elem add block output signal that i am ready to take inputs
    input  wire [DATA_W-1:0] res_data,

    // output stream (y1 = skip + residual)
    output wire              out_valid, // elem add has already valid output data
    input  wire              out_ready, // check wheither the next block ready to take output to wait and holding data if not
    output wire [DATA_W-1:0] out_data
);

// fire only when BOTH streams have valid data
assign out_valid  = skip_valid && res_valid;
assign skip_ready = res_valid  && out_ready;   
assign res_ready  = skip_valid && out_ready;   
assign out_data   = $signed(skip_data) + $signed(res_data);

endmodule

