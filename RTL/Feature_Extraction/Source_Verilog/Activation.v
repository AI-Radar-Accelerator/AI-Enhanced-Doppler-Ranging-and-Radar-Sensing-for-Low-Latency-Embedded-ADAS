module silu #(
    parameter DATA_W   = 16,
    parameter FRAC_W   = 8,
    parameter LUT_FILE = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex"     // 1024-line hex file
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  in_valid,
    output wire                  in_ready,
    input  wire [DATA_W-1:0]     in_data,

    output reg                   out_valid,
    input  wire                  out_ready,
    output reg  [DATA_W-1:0]     out_data
);

    // =========================================================================
    // LUT ROM — 1024 entries, each 16-bit Q8.8, covers x in [-32, +32)
    // =========================================================================
    reg [DATA_W-1:0] rom [0:1023];

    initial begin
        $readmemh(LUT_FILE, rom);
    end

    // =========================================================================
    // Address computation:
    //   addr = ($signed(in_data) + 0x2000) >>> 5   (10-bit index)
    //
    //   in_data max = 0x7FFF (+127.996), + 0x2000 = 0x9FFF — needs 17 bits
    // =========================================================================

    wire signed [16:0] sum17 = {in_data[DATA_W-1], in_data} + 17'sh2000;
    wire [9:0] lut_addr = sum17[13:4];   // shift by 4 -> bits [13:4], 10-bit address

    wire high_sat = ($signed(in_data) >= $signed(16'h2000));  // x >= +32.0
    wire low_sat  = ($signed(in_data) <  $signed(16'hE000));  // x <  -32.0

    wire [DATA_W-1:0] comb_out = high_sat ? in_data        :
                                 low_sat  ? {DATA_W{1'b0}} :
                                            rom[lut_addr];

    assign in_ready = !out_valid || out_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= {DATA_W{1'b0}};
        end else if (!out_valid || out_ready) begin
            out_valid <= in_valid;
            if (in_valid)
                out_data <= comb_out;
        end
    end

endmodule