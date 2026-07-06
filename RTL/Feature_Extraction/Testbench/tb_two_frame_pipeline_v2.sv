`timescale 1ns/1ps
// =============================================================================
//  tb_two_frame_pipeline.sv
//
//  Sends the SAME frame TWICE back-to-back (no gap) to test true pipelined
//  throughput and latency. Captures output at every stage boundary.
//
//  Output files written:
//    out_conv1_f1.hex   — conv1 output Frame 1  (64 x 64 x 128 = 524288 words)
//    out_conv1_f2.hex   — conv1 output Frame 2
//    out_conv2_f1.hex   — conv2 output Frame 1  (128 x 32 x 64 = 262144 words)
//    out_conv2_f2.hex   — conv2 output Frame 2
//    out_conv3_f1.hex   — conv3 output Frame 1  (128 x 16 x 32 = 65536 words)
//    out_conv3_f2.hex   — conv3 output Frame 2
//    out_final_f1.hex   — full pipeline Frame 1 (128 x 16 x 32 = 65536 words)
//    out_final_f2.hex   — full pipeline Frame 2
// =============================================================================

module tb_two_frame_pipeline;

// ---------------------------------------------------------------------------
// PARAMETERS
// ---------------------------------------------------------------------------
localparam DATA_W     = 16;

localparam integer PIX_PER_CH = 128 * 256;       // 32768
localparam integer C1_WORDS   = 64  * 64  * 128; // 524288 — conv1 output
localparam integer C2_WORDS   = 128 * 32  * 64;  // 262144 — conv2 output
localparam integer C3_WORDS   = 128 * 16  * 32;  // 65536  — conv3 output
localparam integer OUT_PIXELS = 128 * 16  * 32;  // 65536  — final output

// Extra stage word counts (CSP internals + 3to1)
localparam integer W3TO1_WORDS = 3   * 128 * 256; // 98304  — 3to1 output (= conv1 input)
localparam integer WCSPH_WORDS = 64  * 16  * 32;  // 32768  — csp branch-width: x1,x2,conv_a/b/c/d,skip_fifo,fifo_b,elem_add(y1)
localparam integer WCSPF_WORDS = 128 * 16  * 32;  // 65536  — csp full-width: concat, conv_e

// ---------------------------------------------------------------------------
// CLOCK & RESET
// ---------------------------------------------------------------------------
reg clk, rst_n;
initial clk = 1'b0;
always #5 clk = ~clk;

reg [31:0] cycle_count;
initial cycle_count = 0;
always @(posedge clk) cycle_count = cycle_count + 1;

// ---------------------------------------------------------------------------
// DUT SIGNALS
// ---------------------------------------------------------------------------
reg                  in_valid_ch0, in_valid_ch1, in_valid_ch2;
wire                 in_ready_ch0, in_ready_ch1, in_ready_ch2;
reg  [DATA_W-1:0]    in_data_ch0,  in_data_ch1,  in_data_ch2;

wire                 out_valid;
reg                  out_ready;
wire [DATA_W-1:0]    out_data;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
Feature_Extraction #(
    .DATA_W (DATA_W)
) dut (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .in_valid_ch0_top      (in_valid_ch0),
    .in_ready_ch0_top      (in_ready_ch0),
    .in_data_ch0_top       (in_data_ch0),
    .in_valid_ch1_top      (in_valid_ch1),
    .in_ready_ch1_top      (in_ready_ch1),
    .in_data_ch1_top       (in_data_ch1),
    .in_valid_ch2_top      (in_valid_ch2),
    .in_ready_ch2_top      (in_ready_ch2),
    .in_data_ch2_top       (in_data_ch2),
    .out_valid_Feature_top (out_valid),
    .out_ready_Feature_top (out_ready),
    .out_data_Feature_top  (out_data)
);

// ---------------------------------------------------------------------------
// INPUT MEMORIES
// ---------------------------------------------------------------------------
reg [DATA_W-1:0] mem_ch0 [0:PIX_PER_CH-1];
reg [DATA_W-1:0] mem_ch1 [0:PIX_PER_CH-1];
reg [DATA_W-1:0] mem_ch2 [0:PIX_PER_CH-1];

initial begin
    $readmemh("ch0.hex", mem_ch0);
    $readmemh("ch1.hex", mem_ch1);
    $readmemh("ch2.hex", mem_ch2);
    $display("[TB] Input files loaded.");
end

// ---------------------------------------------------------------------------
// OUTPUT FILE HANDLES
// ---------------------------------------------------------------------------
integer fd_c1_f1, fd_c1_f2;
integer fd_c2_f1, fd_c2_f2;
integer fd_c3_f1, fd_c3_f2;
integer fd_fn_f1, fd_fn_f2;

initial begin
    fd_c1_f1 = $fopen("out_conv1_f1.hex", "w");
    fd_c1_f2 = $fopen("out_conv1_f2.hex", "w");
    fd_c2_f1 = $fopen("out_conv2_f1.hex", "w");
    fd_c2_f2 = $fopen("out_conv2_f2.hex", "w");
    fd_c3_f1 = $fopen("out_conv3_f1.hex", "w");
    fd_c3_f2 = $fopen("out_conv3_f2.hex", "w");
    fd_fn_f1 = $fopen("out_final_f1.hex", "w");
    fd_fn_f2 = $fopen("out_final_f2.hex", "w");
    if (fd_c1_f1==0 || fd_c1_f2==0 || fd_c2_f1==0 || fd_c2_f2==0 ||
        fd_c3_f1==0 || fd_c3_f2==0 || fd_fn_f1==0 || fd_fn_f2==0) begin
        $display("[TB] ERROR: cannot open output files"); $finish;
    end
    $display("[TB] Output files opened.");
end

// ---------------------------------------------------------------------------
// WORD COUNTERS PER STAGE PER FRAME
// ---------------------------------------------------------------------------
integer cnt_c1, cnt_c2, cnt_c3, cnt_fn;
initial begin
    cnt_c1 = 0; cnt_c2 = 0; cnt_c3 = 0; cnt_fn = 0;
end

// ---------------------------------------------------------------------------
// EXTRA OUTPUT FILE HANDLES — additional capture points (3to1, CSP internals, ITS)
// Relative filenames, same naming style as the requested capture list.
// ---------------------------------------------------------------------------
integer fd_3to1_f1,   fd_3to1_f2;
integer fd_cspx1_f1,  fd_cspx1_f2;
integer fd_cspx2_f1,  fd_cspx2_f2;
integer fd_conva_f1,  fd_conva_f2;
integer fd_convb_f1,  fd_convb_f2;
integer fd_convc_f1,  fd_convc_f2;
integer fd_convd_f1,  fd_convd_f2;
integer fd_skip_f1,   fd_skip_f2;
integer fd_fifob_f1,  fd_fifob_f2;
integer fd_elemadd_f1,fd_elemadd_f2;
integer fd_concat_f1, fd_concat_f2;
integer fd_conve_f1,  fd_conve_f2;
integer fd_its_f1,    fd_its_f2;

initial begin
    fd_3to1_f1    = $fopen("f1_after_3to1.hex",     "w");
    fd_3to1_f2    = $fopen("f2_after_3to1.hex",     "w");
    fd_cspx1_f1   = $fopen("f1_csp_x1.hex",         "w");
    fd_cspx1_f2   = $fopen("f2_csp_x1.hex",         "w");
    fd_cspx2_f1   = $fopen("f1_csp_x2.hex",         "w");
    fd_cspx2_f2   = $fopen("f2_csp_x2.hex",         "w");
    fd_conva_f1   = $fopen("f1_after_conva.hex",    "w");
    fd_conva_f2   = $fopen("f2_after_conva.hex",    "w");
    fd_convb_f1   = $fopen("f1_after_convb.hex",    "w");
    fd_convb_f2   = $fopen("f2_after_convb.hex",    "w");
    fd_convc_f1   = $fopen("f1_after_convc.hex",    "w");
    fd_convc_f2   = $fopen("f2_after_convc.hex",    "w");
    fd_convd_f1   = $fopen("f1_after_convd.hex",    "w");
    fd_convd_f2   = $fopen("f2_after_convd.hex",    "w");
    fd_skip_f1    = $fopen("f1_after_skipfifo.hex", "w");
    fd_skip_f2    = $fopen("f2_after_skipfifo.hex", "w");
    fd_fifob_f1   = $fopen("f1_after_fifob.hex",    "w");
    fd_fifob_f2   = $fopen("f2_after_fifob.hex",    "w");
    fd_elemadd_f1 = $fopen("f1_after_elemadd.hex",  "w");
    fd_elemadd_f2 = $fopen("f2_after_elemadd.hex",  "w");
    fd_concat_f1  = $fopen("f1_after_concat.hex",   "w");
    fd_concat_f2  = $fopen("f2_after_concat.hex",   "w");
    fd_conve_f1   = $fopen("f1_after_conve.hex",    "w");
    fd_conve_f2   = $fopen("f2_after_conve.hex",    "w");
    fd_its_f1     = $fopen("f1_after_its.hex",      "w");
    fd_its_f2     = $fopen("f2_after_its.hex",      "w");
    if (fd_3to1_f1==0 || fd_3to1_f2==0 || fd_cspx1_f1==0 || fd_cspx1_f2==0 ||
        fd_cspx2_f1==0 || fd_cspx2_f2==0 || fd_conva_f1==0 || fd_conva_f2==0 ||
        fd_convb_f1==0 || fd_convb_f2==0 || fd_convc_f1==0 || fd_convc_f2==0 ||
        fd_convd_f1==0 || fd_convd_f2==0 || fd_skip_f1==0  || fd_skip_f2==0  ||
        fd_fifob_f1==0 || fd_fifob_f2==0 || fd_elemadd_f1==0 || fd_elemadd_f2==0 ||
        fd_concat_f1==0|| fd_concat_f2==0|| fd_conve_f1==0 || fd_conve_f2==0 ||
        fd_its_f1==0   || fd_its_f2==0) begin
        $display("[TB] ERROR: cannot open extra capture output files"); $finish;
    end
    $display("[TB] Extra capture output files opened.");
end

// ---------------------------------------------------------------------------
// EXTRA WORD COUNTERS — one per new tap point
// ---------------------------------------------------------------------------
integer cnt_3to1, cnt_cspx1, cnt_cspx2;
integer cnt_conva, cnt_convb, cnt_convc, cnt_convd;
integer cnt_skip, cnt_fifob, cnt_elemadd;
integer cnt_concat, cnt_conve, cnt_its;
initial begin
    cnt_3to1 = 0; cnt_cspx1 = 0; cnt_cspx2 = 0;
    cnt_conva = 0; cnt_convb = 0; cnt_convc = 0; cnt_convd = 0;
    cnt_skip = 0; cnt_fifob = 0; cnt_elemadd = 0;
    cnt_concat = 0; cnt_conve = 0; cnt_its = 0;
end

// ---------------------------------------------------------------------------
// RESET
// ---------------------------------------------------------------------------
initial begin : reset_seq
    rst_n        = 1'b0;
    out_ready    = 1'b0;
    in_valid_ch0 = 0; in_valid_ch1 = 0; in_valid_ch2 = 0;
    in_data_ch0  = 0; in_data_ch1  = 0; in_data_ch2  = 0;
    repeat (10) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("[TB] Reset released at cycle %0d", cycle_count);
end

// ---------------------------------------------------------------------------
// STAGE CAPTURE — Conv1 output tap
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst_n && dut.out_valid_conv1 && dut.out_ready_conv1) begin
        if (cnt_c1 < C1_WORDS) begin
            $fdisplay(fd_c1_f1, "%04h", dut.out_data_conv1);
            if (cnt_c1 == C1_WORDS-1) begin
                $fclose(fd_c1_f1);
                $display("[STAGE] conv1 Frame 1 captured (%0d words) at cycle %0d",
                         C1_WORDS, cycle_count);
            end
        end else if (cnt_c1 < 2*C1_WORDS) begin
            $fdisplay(fd_c1_f2, "%04h", dut.out_data_conv1);
            if (cnt_c1 == 2*C1_WORDS-1) begin
                $fclose(fd_c1_f2);
                $display("[STAGE] conv1 Frame 2 captured (%0d words) at cycle %0d",
                         C1_WORDS, cycle_count);
            end
        end
        cnt_c1 = cnt_c1 + 1;
    end
end

// Conv2 output tap
always @(posedge clk) begin
    if (rst_n && dut.out_valid_conv2 && dut.out_ready_conv2) begin
        if (cnt_c2 < C2_WORDS) begin
            $fdisplay(fd_c2_f1, "%04h", dut.out_data_conv2);
            if (cnt_c2 == C2_WORDS-1) begin
                $fclose(fd_c2_f1);
                $display("[STAGE] conv2 Frame 1 captured (%0d words) at cycle %0d",
                         C2_WORDS, cycle_count);
            end
        end else if (cnt_c2 < 2*C2_WORDS) begin
            $fdisplay(fd_c2_f2, "%04h", dut.out_data_conv2);
            if (cnt_c2 == 2*C2_WORDS-1) begin
                $fclose(fd_c2_f2);
                $display("[STAGE] conv2 Frame 2 captured (%0d words) at cycle %0d",
                         C2_WORDS, cycle_count);
            end
        end
        cnt_c2 = cnt_c2 + 1;
    end
end

// Conv3 output tap (= CSP input)
always @(posedge clk) begin
    if (rst_n && dut.in_valid_conv_csp && dut.in_ready_conv_csp) begin
        if (cnt_c3 < C3_WORDS) begin
            $fdisplay(fd_c3_f1, "%04h", dut.in_data_conv_csp);
            if (cnt_c3 == C3_WORDS-1) begin
                $fclose(fd_c3_f1);
                $display("[STAGE] conv3 Frame 1 captured (%0d words) at cycle %0d",
                         C3_WORDS, cycle_count);
            end
        end else if (cnt_c3 < 2*C3_WORDS) begin
            $fdisplay(fd_c3_f2, "%04h", dut.in_data_conv_csp);
            if (cnt_c3 == 2*C3_WORDS-1) begin
                $fclose(fd_c3_f2);
                $display("[STAGE] conv3 Frame 2 captured (%0d words) at cycle %0d",
                         C3_WORDS, cycle_count);
            end
        end
        cnt_c3 = cnt_c3 + 1;
    end
end

// Final output tap
always @(posedge clk) begin
    if (rst_n && out_valid && out_ready) begin
        if (cnt_fn < OUT_PIXELS) begin
            $fdisplay(fd_fn_f1, "%04h", out_data);
            if (cnt_fn == OUT_PIXELS-1) begin
                $fclose(fd_fn_f1);
                $display("[STAGE] final Frame 1 captured (%0d words) at cycle %0d",
                         OUT_PIXELS, cycle_count);
            end
        end else if (cnt_fn < 2*OUT_PIXELS) begin
            $fdisplay(fd_fn_f2, "%04h", out_data);
            if (cnt_fn == 2*OUT_PIXELS-1) begin
                $fclose(fd_fn_f2);
                $display("[STAGE] final Frame 2 captured (%0d words) at cycle %0d",
                         OUT_PIXELS, cycle_count);
            end
        end
        cnt_fn = cnt_fn + 1;
    end
end

// ---------------------------------------------------------------------------
// EXTRA STAGE CAPTURE TAPS
// ---------------------------------------------------------------------------

// 3to1 output tap (= conv1 input)
always @(posedge clk) begin
    if (rst_n && dut.out_valid_three_to_one && dut.out_ready_three_to_one) begin
        if (cnt_3to1 < W3TO1_WORDS) begin
            $fdisplay(fd_3to1_f1, "%04h", dut.out_data_three_to_one);
            if (cnt_3to1 == W3TO1_WORDS-1) begin
                $fclose(fd_3to1_f1);
                $display("[STAGE] 3to1 Frame 1 captured (%0d words) at cycle %0d", W3TO1_WORDS, cycle_count);
            end
        end else if (cnt_3to1 < 2*W3TO1_WORDS) begin
            $fdisplay(fd_3to1_f2, "%04h", dut.out_data_three_to_one);
            if (cnt_3to1 == 2*W3TO1_WORDS-1) begin
                $fclose(fd_3to1_f2);
                $display("[STAGE] 3to1 Frame 2 captured (%0d words) at cycle %0d", W3TO1_WORDS, cycle_count);
            end
        end
        cnt_3to1 = cnt_3to1 + 1;
    end
end

// csp_split x1 output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.x1_valid && dut.u_csp_stage.x1_ready) begin
        if (cnt_cspx1 < WCSPH_WORDS) begin
            $fdisplay(fd_cspx1_f1, "%04h", dut.u_csp_stage.x1_data);
            if (cnt_cspx1 == WCSPH_WORDS-1) begin
                $fclose(fd_cspx1_f1);
                $display("[STAGE] csp_x1 Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_cspx1 < 2*WCSPH_WORDS) begin
            $fdisplay(fd_cspx1_f2, "%04h", dut.u_csp_stage.x1_data);
            if (cnt_cspx1 == 2*WCSPH_WORDS-1) begin
                $fclose(fd_cspx1_f2);
                $display("[STAGE] csp_x1 Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_cspx1 = cnt_cspx1 + 1;
    end
end

// csp_split x2 output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.x2_valid && dut.u_csp_stage.x2_ready) begin
        if (cnt_cspx2 < WCSPH_WORDS) begin
            $fdisplay(fd_cspx2_f1, "%04h", dut.u_csp_stage.x2_data);
            if (cnt_cspx2 == WCSPH_WORDS-1) begin
                $fclose(fd_cspx2_f1);
                $display("[STAGE] csp_x2 Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_cspx2 < 2*WCSPH_WORDS) begin
            $fdisplay(fd_cspx2_f2, "%04h", dut.u_csp_stage.x2_data);
            if (cnt_cspx2 == 2*WCSPH_WORDS-1) begin
                $fclose(fd_cspx2_f2);
                $display("[STAGE] csp_x2 Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_cspx2 = cnt_cspx2 + 1;
    end
end

// conv_a output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.a_valid && dut.u_csp_stage.a_ready) begin
        if (cnt_conva < WCSPH_WORDS) begin
            $fdisplay(fd_conva_f1, "%04h", dut.u_csp_stage.a_data);
            if (cnt_conva == WCSPH_WORDS-1) begin
                $fclose(fd_conva_f1);
                $display("[STAGE] conv_a Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_conva < 2*WCSPH_WORDS) begin
            $fdisplay(fd_conva_f2, "%04h", dut.u_csp_stage.a_data);
            if (cnt_conva == 2*WCSPH_WORDS-1) begin
                $fclose(fd_conva_f2);
                $display("[STAGE] conv_a Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_conva = cnt_conva + 1;
    end
end

// conv_b output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.b_valid && dut.u_csp_stage.b_ready) begin
        if (cnt_convb < WCSPH_WORDS) begin
            $fdisplay(fd_convb_f1, "%04h", dut.u_csp_stage.b_data);
            if (cnt_convb == WCSPH_WORDS-1) begin
                $fclose(fd_convb_f1);
                $display("[STAGE] conv_b Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_convb < 2*WCSPH_WORDS) begin
            $fdisplay(fd_convb_f2, "%04h", dut.u_csp_stage.b_data);
            if (cnt_convb == 2*WCSPH_WORDS-1) begin
                $fclose(fd_convb_f2);
                $display("[STAGE] conv_b Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_convb = cnt_convb + 1;
    end
end

// conv_c output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.c_valid && dut.u_csp_stage.c_ready) begin
        if (cnt_convc < WCSPH_WORDS) begin
            $fdisplay(fd_convc_f1, "%04h", dut.u_csp_stage.c_data);
            if (cnt_convc == WCSPH_WORDS-1) begin
                $fclose(fd_convc_f1);
                $display("[STAGE] conv_c Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_convc < 2*WCSPH_WORDS) begin
            $fdisplay(fd_convc_f2, "%04h", dut.u_csp_stage.c_data);
            if (cnt_convc == 2*WCSPH_WORDS-1) begin
                $fclose(fd_convc_f2);
                $display("[STAGE] conv_c Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_convc = cnt_convc + 1;
    end
end

// conv_d output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.d_valid && dut.u_csp_stage.d_ready) begin
        if (cnt_convd < WCSPH_WORDS) begin
            $fdisplay(fd_convd_f1, "%04h", dut.u_csp_stage.d_data);
            if (cnt_convd == WCSPH_WORDS-1) begin
                $fclose(fd_convd_f1);
                $display("[STAGE] conv_d Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_convd < 2*WCSPH_WORDS) begin
            $fdisplay(fd_convd_f2, "%04h", dut.u_csp_stage.d_data);
            if (cnt_convd == 2*WCSPH_WORDS-1) begin
                $fclose(fd_convd_f2);
                $display("[STAGE] conv_d Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_convd = cnt_convd + 1;
    end
end

// skip_fifo output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.skip_out_valid && dut.u_csp_stage.skip_out_ready) begin
        if (cnt_skip < WCSPH_WORDS) begin
            $fdisplay(fd_skip_f1, "%04h", dut.u_csp_stage.skip_out_data);
            if (cnt_skip == WCSPH_WORDS-1) begin
                $fclose(fd_skip_f1);
                $display("[STAGE] skip_fifo Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_skip < 2*WCSPH_WORDS) begin
            $fdisplay(fd_skip_f2, "%04h", dut.u_csp_stage.skip_out_data);
            if (cnt_skip == 2*WCSPH_WORDS-1) begin
                $fclose(fd_skip_f2);
                $display("[STAGE] skip_fifo Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_skip = cnt_skip + 1;
    end
end

// fifo_b output tap (y2)
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.y2_valid && dut.u_csp_stage.y2_ready) begin
        if (cnt_fifob < WCSPH_WORDS) begin
            $fdisplay(fd_fifob_f1, "%04h", dut.u_csp_stage.y2_data);
            if (cnt_fifob == WCSPH_WORDS-1) begin
                $fclose(fd_fifob_f1);
                $display("[STAGE] fifo_b Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_fifob < 2*WCSPH_WORDS) begin
            $fdisplay(fd_fifob_f2, "%04h", dut.u_csp_stage.y2_data);
            if (cnt_fifob == 2*WCSPH_WORDS-1) begin
                $fclose(fd_fifob_f2);
                $display("[STAGE] fifo_b Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_fifob = cnt_fifob + 1;
    end
end

// elem_add output tap (y1)
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.y1_valid && dut.u_csp_stage.y1_ready) begin
        if (cnt_elemadd < WCSPH_WORDS) begin
            $fdisplay(fd_elemadd_f1, "%04h", dut.u_csp_stage.y1_data);
            if (cnt_elemadd == WCSPH_WORDS-1) begin
                $fclose(fd_elemadd_f1);
                $display("[STAGE] elem_add Frame 1 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end else if (cnt_elemadd < 2*WCSPH_WORDS) begin
            $fdisplay(fd_elemadd_f2, "%04h", dut.u_csp_stage.y1_data);
            if (cnt_elemadd == 2*WCSPH_WORDS-1) begin
                $fclose(fd_elemadd_f2);
                $display("[STAGE] elem_add Frame 2 captured (%0d words) at cycle %0d", WCSPH_WORDS, cycle_count);
            end
        end
        cnt_elemadd = cnt_elemadd + 1;
    end
end

// csp_concat output tap
always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.concat_valid && dut.u_csp_stage.concat_ready) begin
        if (cnt_concat < WCSPF_WORDS) begin
            $fdisplay(fd_concat_f1, "%04h", dut.u_csp_stage.concat_data);
            if (cnt_concat == WCSPF_WORDS-1) begin
                $fclose(fd_concat_f1);
                $display("[STAGE] concat Frame 1 captured (%0d words) at cycle %0d", WCSPF_WORDS, cycle_count);
            end
        end else if (cnt_concat < 2*WCSPF_WORDS) begin
            $fdisplay(fd_concat_f2, "%04h", dut.u_csp_stage.concat_data);
            if (cnt_concat == 2*WCSPF_WORDS-1) begin
                $fclose(fd_concat_f2);
                $display("[STAGE] concat Frame 2 captured (%0d words) at cycle %0d", WCSPF_WORDS, cycle_count);
            end
        end
        cnt_concat = cnt_concat + 1;
    end
end

// conv_e output tap (= CSP_Top output)
always @(posedge clk) begin
    if (rst_n && dut.out_valid_CSPtoDeinter && dut.out_ready_CSPtoDeinter) begin
        if (cnt_conve < WCSPF_WORDS) begin
            $fdisplay(fd_conve_f1, "%04h", dut.out_data_CSPtoDeinter);
            if (cnt_conve == WCSPF_WORDS-1) begin
                $fclose(fd_conve_f1);
                $display("[STAGE] conv_e Frame 1 captured (%0d words) at cycle %0d", WCSPF_WORDS, cycle_count);
            end
        end else if (cnt_conve < 2*WCSPF_WORDS) begin
            $fdisplay(fd_conve_f2, "%04h", dut.out_data_CSPtoDeinter);
            if (cnt_conve == 2*WCSPF_WORDS-1) begin
                $fclose(fd_conve_f2);
                $display("[STAGE] conv_e Frame 2 captured (%0d words) at cycle %0d", WCSPF_WORDS, cycle_count);
            end
        end
        cnt_conve = cnt_conve + 1;
    end
end

// ITS output tap (= top-level final output, same data as fd_fn but separate file)
always @(posedge clk) begin
    if (rst_n && out_valid && out_ready) begin
        if (cnt_its < OUT_PIXELS) begin
            $fdisplay(fd_its_f1, "%04h", out_data);
            if (cnt_its == OUT_PIXELS-1) begin
                $fclose(fd_its_f1);
                $display("[STAGE] ITS Frame 1 captured (%0d words) at cycle %0d", OUT_PIXELS, cycle_count);
            end
        end else if (cnt_its < 2*OUT_PIXELS) begin
            $fdisplay(fd_its_f2, "%04h", out_data);
            if (cnt_its == 2*OUT_PIXELS-1) begin
                $fclose(fd_its_f2);
                $display("[STAGE] ITS Frame 2 captured (%0d words) at cycle %0d", OUT_PIXELS, cycle_count);
            end
        end
        cnt_its = cnt_its + 1;
    end
end

// ---------------------------------------------------------------------------
// CHANNEL 0 DRIVER — Frame 1 then Frame 2 back to back, no gap
// ---------------------------------------------------------------------------
integer p0;
initial begin : drive_ch0
    in_valid_ch0 = 0; in_data_ch0 = 0;
    wait (rst_n === 1'b1); @(posedge clk);

    repeat (2) begin : frames_ch0
        p0 = 0; in_data_ch0 = mem_ch0[0]; in_valid_ch0 = 1;
        while (p0 < PIX_PER_CH) begin
            @(posedge clk);
            if (in_ready_ch0) begin
                p0 = p0 + 1;
                if (p0 < PIX_PER_CH) in_data_ch0 = mem_ch0[p0];
                else                  in_valid_ch0 = 0;
            end
        end
    end
    $display("[CH0] Both frames done at cycle=%0d", cycle_count);
end

// ---------------------------------------------------------------------------
// CHANNEL 1 DRIVER — pipelined
// ---------------------------------------------------------------------------
integer p1;
initial begin : drive_ch1
    in_valid_ch1 = 0; in_data_ch1 = 0;
    wait (rst_n === 1'b1); @(posedge clk);

    repeat (2) begin : frames_ch1
        p1 = 0; in_data_ch1 = mem_ch1[0]; in_valid_ch1 = 1;
        while (p1 < PIX_PER_CH) begin
            @(posedge clk);
            if (in_ready_ch1) begin
                p1 = p1 + 1;
                if (p1 < PIX_PER_CH) in_data_ch1 = mem_ch1[p1];
                else                  in_valid_ch1 = 0;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// CHANNEL 2 DRIVER — pipelined
// ---------------------------------------------------------------------------
integer p2;
initial begin : drive_ch2
    in_valid_ch2 = 0; in_data_ch2 = 0;
    wait (rst_n === 1'b1); @(posedge clk);

    repeat (2) begin : frames_ch2
        p2 = 0; in_data_ch2 = mem_ch2[0]; in_valid_ch2 = 1;
        while (p2 < PIX_PER_CH) begin
            @(posedge clk);
            if (in_ready_ch2) begin
                p2 = p2 + 1;
                if (p2 < PIX_PER_CH) in_data_ch2 = mem_ch2[p2];
                else                  in_valid_ch2 = 0;
            end
        end
    end
end

// ---------------------------------------------------------------------------
// LATENCY & THROUGHPUT MEASUREMENT
// ---------------------------------------------------------------------------
longint unsigned t_in_first;
longint unsigned t_out_first;
longint unsigned t_frame1_last;
longint unsigned t_frame2_last;

reg latency_in_captured;
reg latency_out_captured;
reg frame1_last_captured;
reg frame2_last_captured;

initial begin
    t_in_first           = 0;
    t_out_first          = 0;
    t_frame1_last        = 0;
    t_frame2_last        = 0;
    latency_in_captured  = 0;
    latency_out_captured = 0;
    frame1_last_captured = 0;
    frame2_last_captured = 0;
end

// First accepted input pixel
always @(posedge clk) begin
    if (rst_n && !latency_in_captured && in_valid_ch0 && in_ready_ch0) begin
        t_in_first          <= cycle_count;
        latency_in_captured <= 1;
        $display("[LATENCY] First input accepted at cycle %0d", cycle_count);
    end
end

// Output milestones
always @(posedge clk) begin
    if (rst_n && out_valid && out_ready) begin
        if (!latency_out_captured) begin
            t_out_first          <= cycle_count;
            latency_out_captured <= 1;
            $display("[LATENCY] First output received at cycle %0d", cycle_count);
        end
        if (!frame1_last_captured && cnt_fn == OUT_PIXELS-1) begin
            t_frame1_last        <= cycle_count;
            frame1_last_captured <= 1;
            $display("[THROUGHPUT] Frame 1 last pixel at cycle %0d", cycle_count);
        end
        if (!frame2_last_captured && cnt_fn == 2*OUT_PIXELS-1) begin
            t_frame2_last        <= cycle_count;
            frame2_last_captured <= 1;
            $display("[THROUGHPUT] Frame 2 last pixel at cycle %0d", cycle_count);
        end
    end
end

// ---------------------------------------------------------------------------
// DIAGNOSTIC COUNTERS
// ---------------------------------------------------------------------------
integer cnt_skip_fire, cnt_res_fire, cnt_a_fire;
initial begin
    cnt_skip_fire = 0;
    cnt_res_fire  = 0;
    cnt_a_fire    = 0;
end

always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.u_elem_add.skip_valid && dut.u_csp_stage.u_elem_add.skip_ready)
        cnt_skip_fire = cnt_skip_fire + 1;
end

always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.u_elem_add.res_valid && dut.u_csp_stage.u_elem_add.res_ready)
        cnt_res_fire = cnt_res_fire + 1;
end

always @(posedge clk) begin
    if (rst_n && dut.u_csp_stage.u_conv_a.out_valid && dut.u_csp_stage.u_conv_a.out_ready)
        cnt_a_fire = cnt_a_fire + 1;
end

// ---------------------------------------------------------------------------
// MAIN CONTROLLER
// ---------------------------------------------------------------------------
initial begin : controller
    out_ready = 0;
    wait (rst_n === 1'b1);
    repeat (5) @(posedge clk);
    out_ready = 1;

    // Wait for Frame 1 final output
    wait (cnt_fn >= OUT_PIXELS);
    $display("[CTRL] Frame 1 final output complete at cycle %0d", cycle_count);

    // Frame 2 is already flowing in pipeline — no gap inserted

    // Wait for Frame 2 final output
    wait (cnt_fn >= 2*OUT_PIXELS);
    $display("[CTRL] Frame 2 final output complete at cycle %0d", cycle_count);

    // Performance report
    $display("");
    $display("==========================================================");
    $display("     Feature_Extraction  Performance Report");
    $display("     Clock : 100 MHz  (10 ns/cycle)");
    $display("==========================================================");
    $display("  LATENCY  (first input -> first output)");
    $display("    First input  accepted : cycle %0d", t_in_first);
    $display("    First output received : cycle %0d", t_out_first);
    $display("    Latency               : %0d cycles = %.2f us",
        t_out_first - t_in_first,
        real'(t_out_first - t_in_first) * 10.0 / 1000.0);
    $display("----------------------------------------------------------");
    $display("  THROUGHPUT  (last pixel frame1 -> last pixel frame2)");
    $display("    Frame 1 ended : cycle %0d", t_frame1_last);
    $display("    Frame 2 ended : cycle %0d", t_frame2_last);
    $display("    Cycles/frame  : %0d cycles = %.3f ms",
        t_frame2_last - t_frame1_last,
        real'(t_frame2_last - t_frame1_last) * 10.0 / 1_000_000.0);
    $display("    Throughput    : %.2f FPS",
        1000.0 / (real'(t_frame2_last - t_frame1_last) * 10.0 / 1_000_000.0));
    $display("==========================================================");

    // Diagnostic summary
    $display("");
    $display("+==============================================================+");
    $display("|  DIAGNOSTIC SUMMARY (end of both frames)");
    $display("+==============================================================+");
    $display("| [conv_a]   out_fires=%0d  (expected=65536 for 2 frames)", cnt_a_fire);
    $display("| [elem_add] skip_fires=%0d  res_fires=%0d  diff=%0d",
        cnt_skip_fire, cnt_res_fire, cnt_skip_fire - cnt_res_fire);
    $display("| [skip_fifo] count=%0d rd=%0d wr=%0d",
        dut.u_csp_stage.u_skip_fifo.count,
        dut.u_csp_stage.u_skip_fifo.rd_ptr,
        dut.u_csp_stage.u_skip_fifo.wr_ptr);
    $display("| [fifo_b]    count=%0d rd=%0d wr=%0d",
        dut.u_csp_stage.u_fifo_b.count,
        dut.u_csp_stage.u_fifo_b.rd_ptr,
        dut.u_csp_stage.u_fifo_b.wr_ptr);
    $display("+==============================================================+");

    $display("");
    $display("+==============================================================+");
    $display("|  SIMULATION COMPLETE");
    $display("|  Files written:");
    $display("|    out_conv1_f1.hex  out_conv1_f2.hex  (%0d words each)", C1_WORDS);
    $display("|    out_conv2_f1.hex  out_conv2_f2.hex  (%0d words each)", C2_WORDS);
    $display("|    out_conv3_f1.hex  out_conv3_f2.hex  (%0d words each)", C3_WORDS);
    $display("|    out_final_f1.hex  out_final_f2.hex  (%0d words each)", OUT_PIXELS);
    $display("+==============================================================+");

    #100; $finish;
end

// ---------------------------------------------------------------------------
// HEARTBEAT every 500k cycles
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if ((cycle_count % 500000 == 0) && (cycle_count > 0)) begin
        $display("[HB] cycle=%0d cnt_fn=%0d/%0d",
                 cycle_count, cnt_fn, 2*OUT_PIXELS);
        $display("  c1=%0d/%0d c2=%0d/%0d c3=%0d/%0d",
                 cnt_c1, 2*C1_WORDS, cnt_c2, 2*C2_WORDS, cnt_c3, 2*C3_WORDS);
        $display("  3to1->c1 v=%0d r=%0d | c1->c2 v=%0d r=%0d",
            dut.out_valid_three_to_one, dut.out_ready_three_to_one,
            dut.out_valid_conv1, dut.out_ready_conv1);
        $display("  c2->c3 v=%0d r=%0d | c3->CSP v=%0d r=%0d | CSP->ITS v=%0d r=%0d",
            dut.out_valid_conv2, dut.out_ready_conv2,
            dut.in_valid_conv_csp, dut.in_ready_conv_csp,
            dut.out_valid_CSPtoDeinter, dut.out_ready_CSPtoDeinter);
        $display("  [skip_fifo] count=%0d | [fifo_b] count=%0d",
            dut.u_csp_stage.u_skip_fifo.count,
            dut.u_csp_stage.u_fifo_b.count);
    end
end

// ---------------------------------------------------------------------------
// TIMEOUT
// ---------------------------------------------------------------------------
initial begin : watchdog
    #(64'd50_000_000_000);
    $display("[TB] TIMEOUT at cycle %0d", cycle_count);
    $finish;
end

endmodule
