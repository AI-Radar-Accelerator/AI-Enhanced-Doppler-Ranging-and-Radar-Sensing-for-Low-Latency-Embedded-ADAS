// =============================================================================
// CSP_Top.v — Fully Parameterized
// =============================================================================
//
// All dimensions are parameters — change at instantiation time.
// Testbench uses small values; real design uses full values.
//
// Real design:
//   C_IN=128, C_HALF=64, H=8, W=32, K=3, STRIDE=1, PAD=1
//
// Testbench uses:
//   C_IN=4, C_HALF=2, H=2, W=2, K=3, STRIDE=1, PAD=1
//
// Architecture:
//
//   Branch 1 (top half of channels):
//     x1 → conv_a → FORK ──────────────────────────────┐
//                     │                                  │
//                     ├─→ conv_c → conv_d → elem_add(+)←┤
//                     └─→ skip_FIFO ─────────────────────┘
//                                    ↓
//                                   y1 ──────→ csp_concat
//   Branch 2 (bottom half of channels):
//     x2 → conv_b → FIFO_b → y2 ──────────→ csp_concat
//
//   csp_concat → conv_e → output
//
// FIFO sizes:
//   skip_FIFO : C_HALF * H_OUT * W_OUT words  (skip connection delay buffer)
//   FIFO_b    : C_HALF * H_OUT * W_OUT words  (branch2 delay buffer)
//
// =============================================================================

module CSP_Top #(

    // -------------------------------------------------------------------------
    // Arithmetic
    // -------------------------------------------------------------------------
    parameter DATA_W   = 16,
    parameter FRAC_W   = 8,

    // -------------------------------------------------------------------------
    // Tensor shape
    // Total input channels = C_IN (must be even)
    // Each branch gets C_HALF = C_IN/2 channels
    // -------------------------------------------------------------------------
    parameter C_IN     = 128,          // total input channels  (real=128, test=4)
    parameter C_HALF   = C_IN / 2,     // channels per branch   (real=64,  test=2)
    parameter H_IN     = 16,            // feature map height    (real=8,   test=2)
    parameter W_IN     = 32,           // feature map width     (real=32,  test=2)

    // -------------------------------------------------------------------------
    // Convolution geometry (same for all internal conv_units)
    // -------------------------------------------------------------------------
    parameter K        = 3,
    parameter STRIDE   = 1,
    parameter PAD      = 1,
    parameter P = 64,                  
    // -------------------------------------------------------------------------
    // Hex files — one per conv_unit (a,b,c,d,e)
    // -------------------------------------------------------------------------
    parameter WEIGHT_FILE_A = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_weights_a.hex",
    parameter WEIGHT_FILE_B = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_weights_b.hex",
    parameter WEIGHT_FILE_C = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_weights_c.hex",
    parameter WEIGHT_FILE_D = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_weights_d.hex",
    parameter WEIGHT_FILE_E = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_weights_e.hex",

    parameter LUT_FILE_A    = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex",
    parameter LUT_FILE_B    = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex",
    parameter LUT_FILE_C    = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex",
    parameter LUT_FILE_D    = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/silu_lut.hex",
    parameter LUT_FILE_E    = "silu_lut.hex",

    parameter SCALE_FILE_A  = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_scale_a.hex",
    parameter SCALE_FILE_B  = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_scale_b.hex",
    parameter SCALE_FILE_C  = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_scale_c.hex",
    parameter SCALE_FILE_D  = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_scale_d.hex",
    parameter SCALE_FILE_E  = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_scale_e.hex",

    parameter BIAS_FILE_A   = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_bias_a.hex",
    parameter BIAS_FILE_B   = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_bias_b.hex",
    parameter BIAS_FILE_C   = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_bias_c.hex",
    parameter BIAS_FILE_D   = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_bias_d.hex",
    parameter BIAS_FILE_E   = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/cu_bn_bias_e.hex"

)(
    input  wire              clk,
    input  wire              rst_n,

    // Input stream (pos-first interleaved, C_IN channels per position)
    input  wire              in_valid,
    output wire              in_ready,
    input  wire [DATA_W-1:0] in_data,

    // Output stream (pos-first interleaved, C_IN channels per position)
    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    // Output spatial size = input spatial size (STRIDE=1, PAD=1, K=3)
    localparam H_OUT      = (H_IN + 2*PAD - K) / STRIDE + 1;   // = H_IN
    localparam W_OUT      = (W_IN + 2*PAD - K) / STRIDE + 1;   // = W_IN

    // FIFO depths — must hold one complete feature map per branch
    localparam FIFO_DEPTH = C_HALF * H_OUT * W_OUT;

    // =========================================================================
    // Internal wires
    // =========================================================================

    // Split outputs
    wire              x1_valid, x1_ready;
    wire [DATA_W-1:0] x1_data;
    wire              x2_valid, x2_ready;
    wire [DATA_W-1:0] x2_data;

    // conv_a output — fans out to conv_c AND skip_FIFO
    wire              a_valid,  a_ready;
    wire [DATA_W-1:0] a_data;

    // Fork ready: conv_a stalls unless BOTH conv_c AND skip_FIFO can accept
    wire              c_in_ready;
    wire              skip_in_ready;
    assign a_ready = c_in_ready && skip_in_ready;

    // Skip FIFO output → elem_add skip input
    wire              skip_out_valid, skip_out_ready;
    wire [DATA_W-1:0] skip_out_data;

    // conv_c output → conv_d input
    wire              c_valid, c_ready;
    wire [DATA_W-1:0] c_data;

    // conv_d output → elem_add residual input
    wire              d_valid, d_ready;
    wire [DATA_W-1:0] d_data;

    // elem_add output → y1 → concat
    wire              y1_valid, y1_ready;
    wire [DATA_W-1:0] y1_data;

    // conv_b output → FIFO_b input
    wire              b_valid, b_ready;
    wire [DATA_W-1:0] b_data;

    // FIFO_b output → y2 → concat
    wire              y2_valid, y2_ready;
    wire [DATA_W-1:0] y2_data;

    // concat output → conv_e input
    wire              concat_valid, concat_ready;
    wire [DATA_W-1:0] concat_data;

    // =========================================================================
    // SPLIT — routes ch0..C_HALF-1 to branch1, ch C_HALF..C_IN-1 to branch2
    // =========================================================================
    csp_split #(
        .DATA_W(DATA_W),
        .C_IN  (C_IN)
    ) u_split (
        .clk     (clk),
        .rst_n   (rst_n),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_data (in_data),
        .x1_valid(x1_valid),
        .x1_ready(x1_ready),
        .x1_data (x1_data),
        .x2_valid(x2_valid),
        .x2_ready(x2_ready),
        .x2_data (x2_data)
    );

    // =========================================================================
    // BRANCH 1 — conv_a → fork → (conv_c → conv_d → elem_add)
    //                          ↘ skip_FIFO ─────────────────↗
    // =========================================================================

    // conv_a
    conv_unit #(
        .DATA_W     (DATA_W),
        .FRAC_W     (FRAC_W),
        .C_IN       (C_HALF),
        .C_OUT      (C_HALF),
        .H_IN       (H_IN),
        .W_IN       (W_IN),
        .K          (K),
        .STRIDE     (STRIDE),
        .PAD        (PAD),
        .P          (P),
        .WEIGHT_FILE(WEIGHT_FILE_A),
        .LUT_FILE   (LUT_FILE_A),
        .SCALE_FILE (SCALE_FILE_A),
        .BIAS_FILE  (BIAS_FILE_A)
    ) u_conv_a (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (x1_valid),
        .in_ready (x1_ready),
        .in_data  (x1_data),
        .out_valid(a_valid),
        .out_ready(a_ready),    // stalls if EITHER consumer not ready
        .out_data (a_data)
    );

    // Skip FIFO — taps conv_a output, delays it for elem_add
    stream_fifo #(
        .DATA_W(DATA_W),
        .DEPTH (FIFO_DEPTH)
    ) u_skip_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (a_valid && c_in_ready),
        .in_ready (skip_in_ready),   // part of fork ready
        .in_data  (a_data),
        .out_valid(skip_out_valid),
        .out_ready(skip_out_ready),
        .out_data (skip_out_data)
    );

    // conv_c
    conv_unit #(
        .DATA_W     (DATA_W),
        .FRAC_W     (FRAC_W),
        .C_IN       (C_HALF),
        .C_OUT      (C_HALF),
        .H_IN       (H_IN),
        .W_IN       (W_IN),
        .K          (K),
        .STRIDE     (STRIDE),
        .PAD        (PAD),
        .P          (P),
        .WEIGHT_FILE(WEIGHT_FILE_C),
        .LUT_FILE   (LUT_FILE_C),
        .SCALE_FILE (SCALE_FILE_C),
        .BIAS_FILE  (BIAS_FILE_C)
    ) u_conv_c (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (a_valid),
        .in_ready (c_in_ready),      // part of fork ready
        .in_data  (a_data),
        .out_valid(c_valid),
        .out_ready(c_ready),
        .out_data (c_data)
    );

    // conv_d
    conv_unit #(
        .DATA_W     (DATA_W),
        .FRAC_W     (FRAC_W),
        .C_IN       (C_HALF),
        .C_OUT      (C_HALF),
        .H_IN       (H_IN),
        .W_IN       (W_IN),
        .K          (K),
        .STRIDE     (STRIDE),
        .PAD        (PAD),
        .P          (P),
        .WEIGHT_FILE(WEIGHT_FILE_D),
        .LUT_FILE   (LUT_FILE_D),
        .SCALE_FILE (SCALE_FILE_D),
        .BIAS_FILE  (BIAS_FILE_D)
    ) u_conv_d (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (c_valid),
        .in_ready (c_ready),
        .in_data  (c_data),
        .out_valid(d_valid),
        .out_ready(d_ready),
        .out_data (d_data)
    );

    // elem_add — y1 = skip + residual
    elem_add #(
        .DATA_W(DATA_W)
    ) u_elem_add (
        .clk       (clk),
        .rst_n     (rst_n),
        .skip_valid(skip_out_valid),
        .skip_ready(skip_out_ready),
        .skip_data (skip_out_data),
        .res_valid (d_valid),
        .res_ready (d_ready),
        .res_data  (d_data),
        .out_valid (y1_valid),
        .out_ready (y1_ready),
        .out_data  (y1_data)
    );

    // =========================================================================
    // BRANCH 2 — conv_b → FIFO_b → y2
    // =========================================================================

    // conv_b
    conv_unit #(
        .DATA_W     (DATA_W),
        .FRAC_W     (FRAC_W),
        .C_IN       (C_HALF),
        .C_OUT      (C_HALF),
        .H_IN       (H_IN),
        .W_IN       (W_IN),
        .K          (K),
        .STRIDE     (STRIDE),
        .PAD        (PAD),
        .P          (P),
        .WEIGHT_FILE(WEIGHT_FILE_B),
        .LUT_FILE   (LUT_FILE_B),
        .SCALE_FILE (SCALE_FILE_B),
        .BIAS_FILE  (BIAS_FILE_B)
    ) u_conv_b (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (x2_valid),
        .in_ready (x2_ready),
        .in_data  (x2_data),
        .out_valid(b_valid),
        .out_ready(b_ready),
        .out_data (b_data)
    );

    // FIFO_b — holds branch2 output while branch1 finishes
    stream_fifo #(
        .DATA_W(DATA_W),
        .DEPTH (FIFO_DEPTH)
    ) u_fifo_b (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (b_valid),
        .in_ready (b_ready),
        .in_data  (b_data),
        .out_valid(y2_valid),
        .out_ready(y2_ready),
        .out_data (y2_data)
    );

    // =========================================================================
    // CONCAT — interleaves y1 (C_HALF ch) and y2 (C_HALF ch)
    // Output: C_IN channels per position
    // =========================================================================
    csp_concat #(
        .DATA_W(DATA_W),
        .C_HALF(C_HALF),
        .H_OUT (H_OUT),
        .W_OUT (W_OUT)
    ) u_csp_concat (
        .clk      (clk),
        .rst_n    (rst_n),
        .y1_valid (y1_valid),
        .y1_ready (y1_ready),
        .y1_data  (y1_data),
        .y2_valid (y2_valid),
        .y2_ready (y2_ready),
        .y2_data  (y2_data),
        .out_valid(concat_valid),
        .out_ready(concat_ready),
        .out_data (concat_data)
    );

    // =========================================================================
    // FUSE CONV — C_IN channels → C_IN channels
    // =========================================================================
    conv_unit #(
        .DATA_W     (DATA_W),
        .FRAC_W     (FRAC_W),
        .C_IN       (C_IN),
        .C_OUT      (C_IN),
        .H_IN       (H_IN),
        .W_IN       (W_IN),
        .K          (K),
        .STRIDE     (STRIDE),
        .PAD        (PAD),
        .P          (P),
        .WEIGHT_FILE(WEIGHT_FILE_E),
        .LUT_FILE   (LUT_FILE_E),
        .SCALE_FILE (SCALE_FILE_E),
        .BIAS_FILE  (BIAS_FILE_E)
    ) u_conv_e (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (concat_valid),
        .in_ready (concat_ready),
        .in_data  (concat_data),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_data (out_data)
    );

endmodule