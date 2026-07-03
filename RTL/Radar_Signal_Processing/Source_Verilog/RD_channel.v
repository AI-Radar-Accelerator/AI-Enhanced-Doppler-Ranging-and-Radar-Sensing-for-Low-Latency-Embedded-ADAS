module RD_channel #(
    parameter DATA_WIDTH = 16,
    parameter CORDIC_LATENCY = 16  
)(
    input clk,
    input rstn,
    input valid_in,
    input  [2*DATA_WIDTH-1:0] data_in,
    output reg valid_out,
    output reg [DATA_WIDTH-1:0] amp_out,
    output reg signed [DATA_WIDTH-1:0] re_out,
    output reg signed [DATA_WIDTH-1:0] im_out
);

    reg [2*DATA_WIDTH-1:0] buffer;
    reg valid_buf;

    always @(posedge clk) begin
        if (!rstn) begin
            buffer <= 0;
            valid_buf <= 0;
        end else begin
            buffer <= data_in;
            valid_buf <= valid_in;
        end
    end

    wire signed [DATA_WIDTH-1:0] re_in = buffer[2*DATA_WIDTH-1:DATA_WIDTH];
    wire signed [DATA_WIDTH-1:0] im_in = buffer[DATA_WIDTH-1:0];

    reg signed [31:0] re_sq, im_sq;
    reg valid_sq;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_sq <= 0;
            re_sq <= 0;
            im_sq <= 0;
        end else begin
            valid_sq <= valid_buf;
            if (valid_buf) begin
                re_sq <= re_in * re_in;
                im_sq <= im_in * im_in;
            end
        end
    end

    reg [32:0] sum_sq;
    reg valid_sum;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            valid_sum <= 0;
            sum_sq <= 0;
        end else begin
            valid_sum <= valid_sq;
            if (valid_sq) begin
                sum_sq <= re_sq + im_sq;
            end
        end
    end

    wire [23:0] cordic_out_full;
    wire [15:0] cordic_out = cordic_out_full[15:0]; // Extracting lower 16 bits
    wire cordic_valid;

    cordic_0 u_cordic (
        .aclk(clk),                                        
        .s_axis_cartesian_tvalid(valid_sum),       
        .s_axis_cartesian_tdata(sum_sq[31:0]),     
        .m_axis_dout_tvalid(cordic_valid),         
        .m_axis_dout_tdata(cordic_out_full)             
    );

    localparam PIPE_DEPTH = 3 + CORDIC_LATENCY; 
    
    reg signed [DATA_WIDTH-1:0] re_pipe [0:PIPE_DEPTH-1];
    reg signed [DATA_WIDTH-1:0] im_pipe [0:PIPE_DEPTH-1];
    integer i;

    always @(posedge clk) begin
        re_pipe[0] <= re_in;
        im_pipe[0] <= im_in;
        for (i = 1; i < PIPE_DEPTH; i = i + 1) begin
            re_pipe[i] <= re_pipe[i-1];
            im_pipe[i] <= im_pipe[i-1];
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            amp_out   <= 0;
            re_out    <= 0;
            im_out    <= 0;
            valid_out <= 0;
        end else begin
            if (cordic_valid) begin
                // 🚀 THE FIX: Saturate Amp to fit in signed 16-bit without wrapping to negative
                amp_out   <= (cordic_out > 16'd32767) ? 16'd32767 : cordic_out; 
                re_out    <= re_pipe[PIPE_DEPTH-1]; 
                im_out    <= im_pipe[PIPE_DEPTH-1];
                valid_out <= 1;
            end else begin
                valid_out <= 0;
            end
        end
    end
endmodule