module csp_concat #(
    parameter DATA_W = 16,
    parameter C_HALF = 64,      // channels per branch
    parameter H_OUT  = 8,
    parameter W_OUT  = 16
)(
    input  wire clk, rst_n,

    // y1 stream (branch1, slower — arrives second)
    input  wire              y1_valid,
    output wire              y1_ready,
    input  wire [DATA_W-1:0] y1_data,

    // y2 stream (branch2, faster — arrives first)
    input  wire              y2_valid,
    output wire              y2_ready,
    input  wire [DATA_W-1:0] y2_data,

    // output stream (128 channels per position)
    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data
);

localparam CH_W = $clog2(C_HALF);

reg             state;    // 0 = sending y1, 1 = sending y2
reg [CH_W-1:0]  ch_cnt;

localparam ST_Y1 = 1'b0;
localparam ST_Y2 = 1'b1;

assign out_valid = (state == ST_Y1) ? y1_valid : y2_valid;
assign out_data  = (state == ST_Y1) ? y1_data  : y2_data;
assign y1_ready  = (state == ST_Y1) && out_ready;
assign y2_ready  = (state == ST_Y2) && out_ready;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state  <= ST_Y1;
        ch_cnt <= 0;
    end else begin
        case (state)
            ST_Y1: if (y1_valid && out_ready) begin
                if (ch_cnt == C_HALF-1) begin ch_cnt <= 0; state <= ST_Y2; end
                else ch_cnt <= ch_cnt + 1;
            end
            ST_Y2: if (y2_valid && out_ready) begin
                if (ch_cnt == C_HALF-1) begin ch_cnt <= 0; state <= ST_Y1; end
                else ch_cnt <= ch_cnt + 1;
            end
        endcase
    end
end

endmodule

