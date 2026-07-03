module top_norm_and_RD #(
    parameter DATA_WIDTH=16
)(
    input wire clk,
    input wire rstn,
    input wire valid_in,
    input wire ready,
    // packed input: {Re, Im}
    input wire [2*DATA_WIDTH-1:0] data_in,
    output wire valid_out,
    output wire [DATA_WIDTH-1:0] data_out_amp,
    output wire [DATA_WIDTH-1:0] data_out_re,
    output wire [DATA_WIDTH-1:0] data_out_im
);
    // internal wires RD channel 
    wire valid_out_RD;
    wire [DATA_WIDTH-1:0] amp_out;
    wire signed [DATA_WIDTH-1:0] re_out;    
    wire signed [DATA_WIDTH-1:0] im_out;    

    // internal wires Normalization 
    wire valid_out_amp;
    wire valid_out_re;
    wire valid_out_im;

    // instantiation RD channel
    RD_channel dut_RD(.clk(clk),.rstn(rstn),.valid_in(valid_in),.data_in(data_in),
    .valid_out(valid_out_RD),.amp_out(amp_out),.re_out(re_out),.im_out(im_out));
    
    // instantiation Normalization to Amplitude
    zscore_2d_stream dut_amp(.clk(clk),.rstn(rstn),.valid_in(valid_out_RD),.data_in(amp_out),
    .ready(ready),.valid_out(valid_out_amp),.data_out(data_out_amp));

    // instantiation Normalization to real
    zscore_2d_stream dut_re(.clk(clk),.rstn(rstn),.valid_in(valid_out_RD),.data_in(re_out),
    .ready(ready),.valid_out(valid_out_re),.data_out(data_out_re));

    // instantiation Normalization to img
    zscore_2d_stream dut_im(.clk(clk),.rstn(rstn),.valid_in(valid_out_RD),.data_in(im_out),
    .ready(ready),.valid_out(valid_out_im),.data_out(data_out_im));
    
    // valid out
    assign valid_out = (valid_out_amp && valid_out_im && valid_out_re)? 1:0;
endmodule