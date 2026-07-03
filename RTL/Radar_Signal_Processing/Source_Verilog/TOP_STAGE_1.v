// ===========================================================================
// TOP_STAGE_1.v
//
// OVERVIEW:
//   This is the Grand TOP module for STAGE 1 (Radar Signal Processing).
//   It connects the entire DSP pipeline:
//   ADC -> Range (Prep + FFT) -> Doppler (Prep + FFT) -> Coherent Integration -> Normalization & RD Channel Split.
// ===========================================================================

module TOP_STAGE_1 #(
    parameter DATA_WIDTH = 16,
    parameter NUM_BINS = 128,     // Positive range bins only
    parameter NUM_CHIRPS = 255,   // Actual valid chirps
    parameter NUM_ANGLES = 8      // Virtual antennas
)(
    input  wire                             clk,         // System Clock (100MHz or similar)
    input  wire                             rst_n,       // System Reset (Active Low)


    input  wire                             adc_clk,     // ADC Clock (Slower clock from Radar)
    input  wire                             adc_rst_n,   // ADC Reset (Active Low)

    // ==========================================
    // 1. INPUT: Raw ADC Data (From Testbench or Radar)
    // ==========================================
    input  wire                             adc_valid_in,   // Indicates valid ADC data
    input  wire signed [DATA_WIDTH-1:0]     adc_data_I,     // In-phase ADC data
    input  wire signed [DATA_WIDTH-1:0]     adc_data_Q,     // Quadrature ADC data
    input  wire                             ready,          // Ready signal from Stage 2 (AI Backbone)
    output wire                             adc_ready_out,  // Added for Backpressure Monitoring

    // ==========================================
    // 2. OUTPUT: Final Normalized Features (To Stage 2: AI Backbone)
    // ==========================================
    output wire                             stage1_valid_out, // Indicates valid output data
    output wire [DATA_WIDTH-1:0]            stage1_data_amp,  // Magnitude of the complex output
    output wire [DATA_WIDTH-1:0]            stage1_data_re,   // Real part of the complex output
    output wire [DATA_WIDTH-1:0]            stage1_data_im,   // Imaginary part of the complex output
    
    // Status flag for monitoring 
    output wire                             integration_done // Indicates completion of coherent integration
);
// =======================================================================
    // INTERNAL INTERCONNECT WIRES
    // =======================================================================

    // 1. Interconnect Wires for the External FIFO Read Side
    wire [31:0] w_fifo_rd_data;
    wire        w_fifo_full;
    wire        w_fifo_empty;
    wire        w_fifo_rd_en;

    // 2. Range Preprocessing -> Range FFT
    wire                       w_pp1_valid;
    wire signed [DATA_WIDTH-1:0] w_pp1_I, w_pp1_Q;
    wire w_rfft_ready;

    // 3. Range FFT -> Doppler Preprocessing
    wire                       w_rfft_valid;
    wire signed [DATA_WIDTH-1:0] w_rfft_I, w_rfft_Q;
    wire                       w_rfft_last;
    // 4. Doppler Preprocessing -> Doppler FFT
    wire                       w_dprep_valid;
    wire signed [DATA_WIDTH-1:0] w_dprep_I, w_dprep_Q;
    wire                       w_dprep_last;
    // 5. Doppler FFT -> Coherent Integration
    wire                       w_dfft_valid;
    wire signed [DATA_WIDTH-1:0] w_dfft_I, w_dfft_Q;
    wire                       w_dfft_last;
    
    wire                       w_dfft_ready;
    // 6. Coherent Integration -> Normalization
    wire                       w_ci_valid;
    wire signed [DATA_WIDTH-1:0] w_ci_I, w_ci_Q;
    
    // Packing {Re, Im} for top_norm_and_RD input based on your module's requirements
    wire [2*DATA_WIDTH-1:0]    w_ci_packed = {w_ci_I, w_ci_Q};
    // =======================================================================
    // PIPELINE INSTANTIATIONS
    // =======================================================================

    // ----------------------------------------------------
    // ASYNC FIFO for Clock Domain Crossing
    // ----------------------------------------------------
    ASYNC_FIFO #(
        .DATA_WIDTH(2*DATA_WIDTH), // Packing I and Q together
        .DEPTH(32),
        .NUM_STAGES(2),
        .ptr_width(6)
    ) u_adc_async_fifo (
        .W_CLK   (adc_clk),        
  
        .W_RST   (adc_rst_n),       
        .W_INC   (adc_valid_in && !w_fifo_full),
        .R_CLK   (clk),
        .R_RST   (rst_n),
        .R_INC   (w_fifo_rd_en),
        .WR_DATA ({adc_data_Q, adc_data_I}),
        .RD_DATA (w_fifo_rd_data),
        .FULL    (w_fifo_full),
    
        .EMPTY   (w_fifo_empty)
    );
// ----------------------------------------------------
    // BLOCK 1: Range Preprocessing (128-pt Hanning)
    // ----------------------------------------------------
    preprocessing_1 #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_range_prep (
        .clk         (clk),
        .rst_n       (rst_n),
        .fifo_empty  (w_fifo_empty),
        .fifo_rd_en  (w_fifo_rd_en),
        .fifo_data_I (w_fifo_rd_data[15:0]),
        .ready_in    (w_rfft_ready),
    
        .fifo_data_Q (w_fifo_rd_data[31:16]),
        .valid_out   (w_pp1_valid),
        .data_out_I  (w_pp1_I),
        .data_out_Q  (w_pp1_Q)
    );
// ----------------------------------------------------
    // BLOCK 2: Range FFT (128-pt)
    // ----------------------------------------------------
    range_fft_wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_BINS(NUM_BINS),
        .NUM_CHIRPS(NUM_CHIRPS),
        .NUM_ANGLES(NUM_ANGLES),
        .FRAME_SIZE(8*NUM_CHIRPS) // 8 * 255 = 2040 valid samples
    ) u_range_fft (
        .clk           (clk),
         
        .rst_n         (rst_n),
        .pp_valid_out  (w_pp1_valid),
        .pp_data_I     (w_pp1_I),
        .pp_data_Q     (w_pp1_Q),
        .fft_valid_out (w_rfft_valid),
        .fft_out_I     (w_rfft_I),
        .fft_out_Q     (w_rfft_Q),
        .fft_last_out  (w_rfft_last),
        .pp_ready_out  (w_rfft_ready)
    );
// ----------------------------------------------------
    // BLOCK 3: Doppler Preprocessing (MIMO Ping-Pong Buffer)
    // ----------------------------------------------------
    doppler_preprocessing #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_BINS(NUM_BINS),         
        .NUM_CHIRPS(NUM_CHIRPS),     
        .FFT_SIZE(256),              
        .NUM_ANTENNAS(NUM_ANGLES)    
    ) u_doppler_prep 
(
        .clk            (clk),
        .rst_n          (rst_n),
        .range_valid_in (w_rfft_valid),
        .range_data_I   (w_rfft_I),
        .range_data_Q   (w_rfft_Q),
        .ready_in       (w_dfft_ready),
        .dop_valid_out  (w_dprep_valid),
        .dop_data_I     (w_dprep_I),
        
        .dop_data_Q     (w_dprep_Q),
        .dop_last_out   (w_dprep_last)
    );
// ----------------------------------------------------
    // BLOCK 4: Doppler FFT (256-pt)
    // ----------------------------------------------------
    doppler_fft_wrapper #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_doppler_fft (
        .clk                (clk),
        .rst_n              (rst_n),
        .dop_valid_in    
       (w_dprep_valid),
        .dop_data_I         (w_dprep_I),
        .dop_data_Q         (w_dprep_Q),
        .dop_last_in        (w_dprep_last),
        .fft_valid_out      (w_dfft_valid),
        .fft_out_I          (w_dfft_I),
        .fft_out_Q       
       (w_dfft_Q),
        .fft_last_out       (w_dfft_last),
        .dop_ready_out  (w_dfft_ready)
    );
// ----------------------------------------------------
    // BLOCK 5: Coherent Integration (Summing Across 8 Antennas)
    // ----------------------------------------------------
    coherent_integration #(
        .NUM_RANGE   (128),     
        .NUM_DOPPLER (256),
        .NUM_ANGLE   (8),
        .ACC_WIDTH   (24),
        .ADDR_WIDTH  (15)       
    ) u_coherent_integration (
         
        .clk                   (clk),
        .rst_n                 (rst_n),
        .valid_in              (w_dfft_valid), 
        .data_in_I             (w_dfft_I),
        .data_in_Q             (w_dfft_Q),
        .ready_in              (1'b1),         
        .valid_out             (w_ci_valid),
        .data_out_I            (w_ci_I),
        .data_out_Q    
            (w_ci_Q),
        .integration_done_flag (integration_done)
    );
// ----------------------------------------------------
    // BLOCK 6: Normalization and RD Extraction (Z-Score)
    // ----------------------------------------------------
    top_norm_and_RD #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_top_norm (
        .clk          (clk),
        .rstn         (rst_n),           // Module uses rstn
        .valid_in     (w_ci_valid),
  
        .data_in      (w_ci_packed),     // Packed {Re, Im}
        .ready        (ready),          
        .valid_out    (stage1_valid_out),
        .data_out_amp (stage1_data_amp),
        .data_out_re  (stage1_data_re),
        .data_out_im  (stage1_data_im)
    );

    // =======================================================================
    // BLOCK 7: Pipeline Monitor Controller (Smart End-to-End Gatekeeper)
    // =======================================================================
    wire w_monitor_ready;
    wire w_err_fifo;
    wire w_err_timeout;

    stage1_ctrl #(
        .TIMEOUT_CYCLES(32'd5_000_000) 
    ) u_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        
        .fifo_full        (w_fifo_full),
        .stage2_ready     (ready),
        
        //  End-to-End Tracking Signals
        .val_start        (w_pp1_valid),       // Start of Frame logic
        .frame_done       (integration_done),  // End of Frame logic
        
        .monitor_ready    (w_monitor_ready),
        .error_fifo_overflow   (w_err_fifo),
        .error_pipeline_timeout(w_err_timeout)
    );

    // =======================================================================
    // INPUT GATE (Backpressure to AXI DMA)
    // =======================================================================
    assign adc_ready_out = (!w_fifo_full) && w_monitor_ready;

endmodule