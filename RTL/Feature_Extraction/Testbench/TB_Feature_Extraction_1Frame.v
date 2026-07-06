`timescale 1ns/1ps

module feature_extraction_tb;

// ---------------------------------------------------------------------------
// PARAMETERS
// ---------------------------------------------------------------------------
localparam DATA_W     = 16;
localparam PIX_PER_CH = 128 * 256;   // 32768 words per input channel
localparam OUT_PIXELS = 128 * 16 * 32; // 65536 output words (N_CH * H * W)

// ---------------------------------------------------------------------------
// CLOCK & RESET
// ---------------------------------------------------------------------------
reg clk, rst_n;
initial clk = 1'b0;
always  #5 clk = ~clk;

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
// LOAD INPUT FILES
// ---------------------------------------------------------------------------
reg [DATA_W-1:0] mem_ch0 [0:PIX_PER_CH-1];
reg [DATA_W-1:0] mem_ch1 [0:PIX_PER_CH-1];
reg [DATA_W-1:0] mem_ch2 [0:PIX_PER_CH-1];

initial begin
    $readmemh("ch0.hex", mem_ch0);
    $readmemh("ch1.hex", mem_ch1);
    $readmemh("ch2.hex", mem_ch2);
    $display("[TB] Input files loaded. PIX_PER_CH=%0d, OUT_PIXELS=%0d",
             PIX_PER_CH, OUT_PIXELS);
end

// ---------------------------------------------------------------------------
// OUTPUT FILE HANDLE
// ---------------------------------------------------------------------------
integer out_fd;

initial begin
    out_fd = $fopen("feature_output.hex", "w");
    if (out_fd == 0) begin
        $display("[TB] ERROR: could not open feature_output.hex for writing");
        $finish;
    end
    $display("[TB] Output will be written to feature_output.hex");
end

// ---------------------------------------------------------------------------
// RESET
// ---------------------------------------------------------------------------
initial begin : reset_seq
    rst_n        = 1'b0;
    out_ready    = 1'b0;
    in_valid_ch0 = 1'b0;
    in_valid_ch1 = 1'b0;
    in_valid_ch2 = 1'b0;
    in_data_ch0  = {DATA_W{1'b0}};
    in_data_ch1  = {DATA_W{1'b0}};
    in_data_ch2  = {DATA_W{1'b0}};
    repeat (10) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("[TB] Reset released at t=%0t", $time);
end

// ---------------------------------------------------------------------------
// HEARTBEAT — prints every 100k cycles so you know sim is alive, not stuck
// Also prints valid/ready state of all ports so you can spot a stall
// ---------------------------------------------------------------------------
integer cycle_count;
initial cycle_count = 0;
always @(posedge clk) cycle_count = cycle_count + 1;

always @(posedge clk) begin
    if (cycle_count % 100000 == 0 && cycle_count > 0) begin
        $display("[HEARTBEAT] cycle=%0d t=%0t", cycle_count, $time);
        $display("  IN  ch0: valid=%b ready=%b  ch1: valid=%b ready=%b  ch2: valid=%b ready=%b",
                 in_valid_ch0, in_ready_ch0,
                 in_valid_ch1, in_ready_ch1,
                 in_valid_ch2, in_ready_ch2);
        $display("  OUT     : valid=%b ready=%b  data=%04h",
                 out_valid, out_ready, out_data);
        $display("  PROGRESS: ch0_sent=%0d  ch1_sent=%0d  ch2_sent=%0d  out_recv=%0d / %0d",
                 p0, p1, p2, out_idx, OUT_PIXELS);
    end
end
// Probe internal handshake points every 100k cycles
// Add to the always @heartbeat block:
always @(posedge clk) begin
    if (cycle_count % 100000 == 0 && cycle_count > 0) begin
        // After 3to1 merger
        $display("  [3to1->conv1] valid=%b ready=%b",
            dut.out_valid_three_to_one, dut.out_ready_three_to_one);
        // After stage1 conv
        $display("  [conv1->conv2] valid=%b ready=%b",
            dut.out_valid_conv1, dut.out_ready_conv1);
        // After stage2 conv
        $display("  [conv2->conv3] valid=%b ready=%b",
            dut.out_valid_conv2, dut.out_ready_conv2);
        // After stage3 conv -> CSP
        $display("  [conv3->CSP  ] valid=%b ready=%b",
            dut.in_valid_conv_csp, dut.in_ready_conv_csp);
        // After CSP -> InterleavedToSerial
        $display("  [CSP->ITS    ] valid=%b ready=%b",
            dut.out_valid_CSPtoDeinter, dut.out_ready_CSPtoDeinter);
    
    $display("  [conv1 dbg] state=%0d rows_filled=%b tensor_loaded=%b wr_r=%0d wr_w=%0d wr_c=%0d oh_base=%0d col_idx=%0d in_valid=%b in_ready=%b",
    dut.u1_conv_unit.CONV2D.state,
    dut.u1_conv_unit.CONV2D.rows_filled,
    dut.u1_conv_unit.CONV2D.tensor_loaded,
    dut.u1_conv_unit.CONV2D.wr_r,
    dut.u1_conv_unit.CONV2D.wr_w,
    dut.u1_conv_unit.CONV2D.wr_c,
    dut.u1_conv_unit.CONV2D.oh_base,
    dut.u1_conv_unit.CONV2D.col_idx,
    dut.out_valid_three_to_one,
    dut.out_ready_three_to_one);
    

   $display("  [conv2 dbg] state=%0d rows_filled=%b tensor_loaded=%b wr_r=%0d wr_w=%0d wr_c=%0d oh_base=%0d col_idx=%0d in_valid=%b in_ready=%b",
    dut.u2_conv_unit.CONV2D.state,
    dut.u2_conv_unit.CONV2D.rows_filled,
    dut.u2_conv_unit.CONV2D.tensor_loaded,
    dut.u2_conv_unit.CONV2D.wr_r,
    dut.u2_conv_unit.CONV2D.wr_w,
    dut.u2_conv_unit.CONV2D.wr_c,
    dut.u2_conv_unit.CONV2D.oh_base,
    dut.u2_conv_unit.CONV2D.col_idx,
    dut.out_valid_three_to_one,
    dut.out_ready_three_to_one);
    end
    
end
// ---------------------------------------------------------------------------
// CHANNEL DRIVERS
// Each channel: assert valid, present data, wait for ready handshake,
// then de-assert valid for one cycle before next pixel (matches toy TB style)
// ---------------------------------------------------------------------------
integer p0;
initial begin : drive_ch0
    wait (rst_n === 1'b1);
    @(posedge clk);
    $display("[CH0] Starting to send %0d pixels at t=%0t", PIX_PER_CH, $time);
    for (p0 = 0; p0 < PIX_PER_CH; p0 = p0 + 1) begin
        in_data_ch0  = mem_ch0[p0];
        in_valid_ch0 = 1'b1;
        @(posedge clk);
        while (!in_ready_ch0) @(posedge clk);
        in_valid_ch0 = 1'b0;
        @(posedge clk);
        // Trace every 4096 pixels sent on ch0
        if ((p0 % 4096) == 0)
            $display("[CH0] sent %0d / %0d pixels at t=%0t", p0, PIX_PER_CH, $time);
    end
    $display("[CH0] DONE: all %0d pixels sent at t=%0t", PIX_PER_CH, $time);
end

integer p1;
initial begin : drive_ch1
    wait (rst_n === 1'b1);
    @(posedge clk);
    $display("[CH1] Starting to send %0d pixels at t=%0t", PIX_PER_CH, $time);
    for (p1 = 0; p1 < PIX_PER_CH; p1 = p1 + 1) begin
        in_data_ch1  = mem_ch1[p1];
        in_valid_ch1 = 1'b1;
        @(posedge clk);
        while (!in_ready_ch1) @(posedge clk);
        in_valid_ch1 = 1'b0;
        @(posedge clk);
        if ((p1 % 4096) == 0)
            $display("[CH1] sent %0d / %0d pixels at t=%0t", p1, PIX_PER_CH, $time);
    end
    $display("[CH1] DONE: all %0d pixels sent at t=%0t", PIX_PER_CH, $time);
end

integer p2;
initial begin : drive_ch2
    wait (rst_n === 1'b1);
    @(posedge clk);
    $display("[CH2] Starting to send %0d pixels at t=%0t", PIX_PER_CH, $time);
    for (p2 = 0; p2 < PIX_PER_CH; p2 = p2 + 1) begin
        in_data_ch2  = mem_ch2[p2];
        in_valid_ch2 = 1'b1;
        @(posedge clk);
        while (!in_ready_ch2) @(posedge clk);
        in_valid_ch2 = 1'b0;
        @(posedge clk);
        if ((p2 % 4096) == 0)
            $display("[CH2] sent %0d / %0d pixels at t=%0t", p2, PIX_PER_CH, $time);
    end
    $display("[CH2] DONE: all %0d pixels sent at t=%0t", PIX_PER_CH, $time);
end

// ---------------------------------------------------------------------------
// OUTPUT RECEIVER — collect all OUT_PIXELS words, write each to hex file
// ---------------------------------------------------------------------------
integer out_idx;

initial begin : receiver
    out_idx   = 0;
    wait (rst_n === 1'b1);
    repeat (5) @(posedge clk);
    out_ready = 1'b1;

    $display("[OUT] Receiver ready, waiting for out_valid at t=%0t", $time);

    while (out_idx < OUT_PIXELS) begin
        @(posedge clk);
        if (out_valid && out_ready) begin
            $fdisplay(out_fd, "%04h", out_data);
            // Print first 8 outputs so you can sanity-check values immediately
            if (out_idx < 8)
                $display("[OUT] word[%0d] = %04h  at t=%0t", out_idx, out_data, $time);
            // Then progress every 4096
            if ((out_idx % 4096) == 0 && out_idx >= 8)
                $display("[OUT] received %0d / %0d words at t=%0t",
                         out_idx, OUT_PIXELS, $time);
            out_idx = out_idx + 1;
        end
    end

    $fclose(out_fd);
    $display("[TB] Done. %0d output words written to feature_output.hex at t=%0t",
             OUT_PIXELS, $time);
    $finish;
end

// ---------------------------------------------------------------------------
// TIMEOUT WATCHDOG
// Sized generously for the large pipeline: 2 billion ns = 2 s sim time
// Adjust if your pipeline needs more cycles
// ---------------------------------------------------------------------------
initial begin : watchdog
    #2_000_000_000;
    $fclose(out_fd);
    $display("[TB] TIMEOUT — simulation exceeded time limit");
    $finish;
end

endmodule
