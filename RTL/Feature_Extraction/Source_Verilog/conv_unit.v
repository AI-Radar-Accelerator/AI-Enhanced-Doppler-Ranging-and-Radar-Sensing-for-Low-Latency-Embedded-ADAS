module conv_unit #(
    parameter DATA_W = 16,
    parameter FRAC_W = 8,

    //tensor dimensions
    parameter C_IN = 3,                //number of input  channels
    parameter C_OUT = 64,              //number of output channels (which is equal to the number of filters)
    parameter H_IN = 64,               //input height
    parameter W_IN = 255,              //input width

	//convolution geometry
    parameter K = 3,                     //kernel
    parameter STRIDE = 2,                //stride
    parameter PAD = 1, 
    parameter P = 64,                  

    //weight file
    parameter WEIGHT_FILE = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weights.hex", 
    parameter LUT_FILE = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex",
    parameter SCALE_FILE = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale.hex",   // A = gamma / sqrt(var + eps)
    parameter BIAS_FILE  = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias.hex"
    )(



    input  wire clk,
    input  wire rst_n,       //active-low synchronous reset

    //input stream (one pixel per cycle, handshake) conv2d in
    input  wire                  in_valid,            //previous stage says: data on in_data is useful not garbage
    output wire                  in_ready,            //this stage says: can accept data right now
    input  wire [DATA_W-1:0]     in_data,             //one input pixel is stored in 16 bits (Q8.8 signed)

    //input stream (one pixel per cycle, handshake) silu out
    output wire                  out_valid,          //this stage says: data on out_data is useful not garbage
    input  wire                  out_ready,          //the next stage says: can accept right now
    output wire [DATA_W-1:0]     out_data
);
    wire                  out_valid_conv2d;
    wire                  out_ready_conv2d;
    wire [DATA_W-1:0]     out_data_conv2d;
    wire                  out_valid_BN;
    wire                  out_ready_BN;
    wire [DATA_W-1:0]     out_data_BN;

localparam H_OUT = (H_IN + 2*PAD - K) / STRIDE + 1;
localparam W_OUT = (W_IN + 2*PAD - K) / STRIDE + 1;


conv2d_matmul #(
	.DATA_W(DATA_W),
	.FRAC_W(FRAC_W),
	.C_IN(C_IN),
	.C_OUT(C_OUT),
	.H_IN(H_IN),
	.W_IN(W_IN),
	.K(K),
	.STRIDE(STRIDE),
	.PAD(PAD),
    .P(P),
	.WEIGHT_FILE(WEIGHT_FILE)
	) CONV2D (
    .clk(clk),
    .rst_n(rst_n),       
    .in_valid(in_valid),            
    .in_ready(in_ready),            
    .in_data(in_data),             
    .out_valid(out_valid_conv2d),          
    .out_ready(out_ready_conv2d),          
    .out_data(out_data_conv2d)
	);

 batch_norm #(
    .DATA_W(DATA_W),
    .FRAC_W(FRAC_W),
    .C_OUT(C_OUT),
    .H_OUT(H_OUT),          
    .W_OUT(W_OUT),          
    .BIAS_FILE (BIAS_FILE),
    .SCALE_FILE(SCALE_FILE)
    ) BN (
    .clk      (clk),
    .rst_n    (rst_n),
    .in_valid (out_valid_conv2d),
    .in_ready(out_ready_conv2d),
    .in_data(out_data_conv2d),
    .out_valid(out_valid_BN),
    .out_ready(out_ready_BN),
    .out_data(out_data_BN)
    );

silu #(
 .DATA_W(DATA_W),
 .FRAC_W(FRAC_W),
 .LUT_FILE (LUT_FILE)
) SILU (
    .clk(clk),
    .rst_n(rst_n),
    .in_valid(out_valid_BN),
    .in_ready(out_ready_BN),
    .in_data(out_data_BN),
    .out_valid(out_valid),
    .out_ready(out_ready),
    .out_data(out_data)
);

endmodule 
