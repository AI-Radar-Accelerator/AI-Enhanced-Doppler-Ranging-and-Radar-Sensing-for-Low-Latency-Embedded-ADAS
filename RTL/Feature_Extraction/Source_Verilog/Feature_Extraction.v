module Feature_Extraction #
(
    parameter DATA_W = 16

)
(    

	input wire clk,
	input wire rst_n,


	//channel 0
	input  wire                  in_valid_ch0_top,
	output wire                  in_ready_ch0_top,
	input  wire [DATA_W-1:0]     in_data_ch0_top,
	
	
	//channel 1
	input  wire                  in_valid_ch1_top,
	output wire                  in_ready_ch1_top,
	input  wire [DATA_W-1:0]     in_data_ch1_top,
	
	
	//channel 2
	input  wire                  in_valid_ch2_top,
	output wire                  in_ready_ch2_top,
	input  wire [DATA_W-1:0]     in_data_ch2_top,

	
	output wire                  out_valid_Feature_top,
    input  wire                  out_ready_Feature_top,
    output wire [DATA_W-1:0]     out_data_Feature_top



);


// Internal wires: ThreeStreamsToOneStream to conv_unit 1
wire                  out_valid_three_to_one;
wire                  out_ready_three_to_one;
wire [DATA_W-1:0]     out_data_three_to_one;

// Internal wires: conv_unit 1 to conv_unit 2
wire                  out_valid_conv1;
wire                  out_ready_conv1;
wire [DATA_W-1:0]     out_data_conv1;

// Internal wires: conv_unit 2 to conv_unit 3
wire                  out_valid_conv2;
wire                  out_ready_conv2;
wire [DATA_W-1:0]     out_data_conv2;

// Internal wires: conv_unit 3 to CSP_Top
wire                  in_valid_conv_csp;
wire                  in_ready_conv_csp;
wire [DATA_W-1:0]     in_data_conv_csp;


/*
// Internal wires: conv_unit 3 to CSP_Top
wire                  in_valid_CSPtoDeinter;
wire                  in_ready_CSPtoDeinter;
wire [DATA_W-1:0]     in_data_CSPtoDeinter;

*/


// Internal wires: CSP_TOP to Interleaver
wire                  out_valid_CSPtoDeinter;
wire                  out_ready_CSPtoDeinter;
wire [DATA_W-1:0]     out_data_CSPtoDeinter;



ThreeStreamsToOneStream #
(
    .DATA_W (16),
    .FRAC_W(8),
    .H_IN   (128),
    .W_IN   (256)
) 
u_3to1 
(
    .clk          (clk),
    .rst_n        (rst_n),

    // Channel 0 input stream
    .in_valid_ch0 (in_valid_ch0_top),
    .in_ready_ch0 (in_ready_ch0_top),
    .in_data_ch0  (in_data_ch0_top),

    // Channel 1 input stream
    .in_valid_ch1 (in_valid_ch1_top),
    .in_ready_ch1 (in_ready_ch1_top),
    .in_data_ch1  (in_data_ch1_top),

    // Channel 2 input stream
    .in_valid_ch2 (in_valid_ch2_top),
    .in_ready_ch2 (in_ready_ch2_top),
    .in_data_ch2  (in_data_ch2_top),

    // Output stream
    .out_valid    (out_valid_three_to_one),
    .out_ready    (out_ready_three_to_one),
    .out_data     (out_data_three_to_one)
);







conv_unit #
(
    .DATA_W      (16),
    .FRAC_W      (8),
    // Tensor dimensions
    .C_IN        (3),
    .C_OUT        (64),
    .H_IN        (128),
    .W_IN        (256),
    // Convolution geometry
    .K           (3),
    .STRIDE      (2),
    .P          (64),
    .PAD         (1),
    // Hex files
    .WEIGHT_FILE ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_stage1_conv.hex"),
    .LUT_FILE    ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
    .SCALE_FILE  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_stage1_bn.hex"),
    .BIAS_FILE   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_stage1_bn.hex")
) 
u1_conv_unit 
(
    .clk      (clk),
    .rst_n    (rst_n),
    // Input stream
    .in_valid (out_valid_three_to_one),
    .in_ready (out_ready_three_to_one),
    .in_data  (out_data_three_to_one),
    // Output stream
    .out_valid(out_valid_conv1),
    .out_ready(out_ready_conv1),
    .out_data (out_data_conv1)
);






conv_unit #
(
    .DATA_W      (16),
    .FRAC_W      (8),
    // Tensor dimensions
    .C_IN        (64),
    .C_OUT        (128),
    .H_IN        (64),
    .W_IN        (128),
    .P          (64),
    // Convolution geometry
    .K           (3),
    .STRIDE      (2),
    .PAD         (1),
    // Hex files
    .WEIGHT_FILE ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_stage2_conv.hex"),
    .LUT_FILE    ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
    .SCALE_FILE  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_stage2_bn.hex"),
    .BIAS_FILE   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_stage2_bn.hex")
) 
u2_conv_unit 
(
    .clk      (clk),
    .rst_n    (rst_n),
    // Input stream
    .in_valid (out_valid_conv1),
    .in_ready (out_ready_conv1),
    .in_data  (out_data_conv1),
    // Output stream
    .out_valid(out_valid_conv2),
    .out_ready(out_ready_conv2),
    .out_data (out_data_conv2)
);






conv_unit #
(
    .DATA_W      (16),
    .FRAC_W      (8),
    // Tensor dimensions
    .C_IN        (128),
    .C_OUT        (128),
    .H_IN        (32),
    .W_IN        (64),
    .P          (64),
    // Convolution geometry
    .K           (3),
    .STRIDE      (2),
    .PAD         (1),
    // Hex files
    .WEIGHT_FILE ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_stage3_conv.hex"),
    .LUT_FILE    ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
    .SCALE_FILE  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_stage3_bn.hex"),
    .BIAS_FILE   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_stage3_bn.hex")
) 
u3_conv_unit 
(
    .clk      (clk),
    .rst_n    (rst_n),
    // Input stream
    .in_valid (out_valid_conv2),
    .in_ready (out_ready_conv2),
    .in_data  (out_data_conv2),
    // Output stream
    .out_valid(in_valid_conv_csp),
    .out_ready(in_ready_conv_csp),
    .out_data (in_data_conv_csp)
);







CSP_Top #(
.DATA_W       (16),
.FRAC_W       (8),
.H_IN         (16),
.W_IN         (32),
.C_IN         (128),
.K            (3),
.PAD          (1),
.P            (64),
.STRIDE       (1),
.C_HALF       (64),
.LUT_FILE_A   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
.LUT_FILE_B   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
.LUT_FILE_C   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
.LUT_FILE_D   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
.LUT_FILE_E   ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"),
.BIAS_FILE_A  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_csp_branch1_0_bn.hex"),
.BIAS_FILE_B  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_csp_branch2_bn.hex"),
.BIAS_FILE_C  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_csp_branch1_1_conv1_bn.hex"),
.BIAS_FILE_D  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_csp_branch1_1_conv2_bn.hex"),
.BIAS_FILE_E  ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_bias_backbone_csp_fuse_conv_bn.hex"),
.SCALE_FILE_A ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_csp_branch1_0_bn.hex"),
.SCALE_FILE_B ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_csp_branch2_bn.hex"),
.SCALE_FILE_C ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_csp_branch1_1_conv1_bn.hex"),
.SCALE_FILE_D ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_csp_branch1_1_conv2_bn.hex"),
.SCALE_FILE_E ("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/bn_scale_backbone_csp_fuse_conv_bn.hex"),
.WEIGHT_FILE_A("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_csp_branch1_0_conv.hex"),
.WEIGHT_FILE_B("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_csp_branch2_conv.hex"),
.WEIGHT_FILE_C("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_csp_branch1_1_conv1_conv.hex"),
.WEIGHT_FILE_D("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_csp_branch1_1_conv2_conv.hex"),
.WEIGHT_FILE_E("G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weight_backbone_csp_fuse_conv_conv.hex")
)
u_csp_stage 
(
    .clk              (clk),
    .rst_n            (rst_n),
	//in of CSP
    .in_valid(in_valid_conv_csp),
    .in_ready(in_ready_conv_csp),
    .in_data(in_data_conv_csp),
	//out of CSP
    .out_valid(out_valid_CSPtoDeinter),
    .out_ready(out_ready_CSPtoDeinter),
    .out_data(out_data_CSPtoDeinter)
);


InterleavedToSerial #
(
    .DATA_W(16),
    .FRAC_W(8),
    .N_CH(128),
    .H_IN(16),
    .W_IN(32)
) 
u_interleaved_to_serial 
(
    .clk        (clk),          
    .rst_n      (rst_n),        
    .in_valid   (out_valid_CSPtoDeinter),    
    .in_ready   (out_ready_CSPtoDeinter),
    .in_data    (out_data_CSPtoDeinter),
    .out_valid  (out_valid_Feature_top),
    .out_ready  (out_ready_Feature_top),
    .out_data   (out_data_Feature_top)
);




endmodule