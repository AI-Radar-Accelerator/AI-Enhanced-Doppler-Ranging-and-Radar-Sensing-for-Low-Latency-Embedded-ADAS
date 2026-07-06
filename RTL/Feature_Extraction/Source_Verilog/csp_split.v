module csp_split #(
    parameter DATA_W = 16,       // bits per pixel
    parameter C_IN   = 128       // total input channels (must be even)
)(
    input  wire              clk,
    input  wire              rst_n,

    // ── input stream (from Stage3 conv_unit, pos-by-pos) ──────────────
    input  wire              in_valid,
    output wire              in_ready,
    input  wire [DATA_W-1:0] in_data,

    // ── x1 output (channels 0 .. C_IN/2-1, to Branch1) ───────────────
    output wire              x1_valid,
    input  wire              x1_ready,
    output wire [DATA_W-1:0] x1_data,

    // ── x2 output (channels C_IN/2 .. C_IN-1, to Branch2) ────────────
    output wire              x2_valid,
    input  wire              x2_ready,
    output wire [DATA_W-1:0] x2_data
);

    // ── threshold ─────────────────────────────────────────────────────
    localparam HALF = C_IN / 2;            // 64 for CSP

    // ── channel counter ───────────────────────────────────────────────
    // counts which channel within the current position group
    // range: 0 .. C_IN-1
    reg [$clog2(C_IN)-1:0] ch_cnt;

    // ── routing (purely combinational, zero latency) ──────────────────
    wire in_branch1 = (ch_cnt < HALF);    // HIGH when routing to x1

    // x1 gets data when we are in the first half of the channel group
    assign x1_valid = in_valid &&  in_branch1;
    assign x2_valid = in_valid && !in_branch1;

    // data buses — both connected, valid gates which one is meaningful
    assign x1_data  = in_data;
    assign x2_data  = in_data;

    // backpressure: stall input if the active branch is not ready
    assign in_ready = in_branch1 ? x1_ready : x2_ready;

    // ── channel counter advance ───────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ch_cnt <= 0;
        else if (in_valid && in_ready) begin
            // a pixel was accepted — advance channel counter
            if (ch_cnt == C_IN - 1)
                ch_cnt <= 0;         // end of position group → wrap
            else
                ch_cnt <= ch_cnt + 1;
        end
    end

endmodule