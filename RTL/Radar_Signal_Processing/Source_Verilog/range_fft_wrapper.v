`timescale 1ns / 1ps

// ===========================================================================
// range_fft_wrapper.v
// ===========================================================================

module range_fft_wrapper #(
    parameter DATA_WIDTH   = 16,
    parameter NUM_BINS     = 128, 
    parameter NUM_CHIRPS   = 255,
    parameter NUM_ANGLES   = 8 ,
    parameter FRAME_SIZE   = NUM_ANGLES * NUM_CHIRPS  // 2,040 samples per frame
)(
    // -----------------------------------------------------------------------
    // Global
    // -----------------------------------------------------------------------
    input  wire                       clk,
    input  wire                       rst_n,          // Active-low reset

    // -----------------------------------------------------------------------
    // Input: comes directly from preprocessing_1 outputs
    // -----------------------------------------------------------------------
    input  wire                       pp_valid_out,     // valid_out of preprocessing_1
    input  wire signed [DATA_WIDTH-1:0] pp_data_I,      // data_out_I of preprocessing_1
    input  wire signed [DATA_WIDTH-1:0] pp_data_Q,      // data_out_Q of preprocessing_1

    // -----------------------------------------------------------------------
    // Output: Range-FFT result (one bin per cycle, natural order)
    // -----------------------------------------------------------------------
    output wire                       fft_valid_out,    // high when a range bin is ready
    output wire signed [DATA_WIDTH-1:0] fft_out_I,      // real part of range bin
    output wire signed [DATA_WIDTH-1:0] fft_out_Q,      // imaginary part of range bin
    output wire                       fft_last_out,     // high on bin 127 (last bin)
    output wire                       pp_ready_out      // Backpressure to preprocessing_1
);

    localparam LOG2_N_NUM_BINS   = $clog2(NUM_BINS);    // 7 for 128 bins
    localparam LOG2_N_FRAME_SIZE = $clog2(FRAME_SIZE);  // 11 for 2040 samples per frame

    // =======================================================================
    // 0.  GLOBAL WIRES & BACKPRESSURE LOGIC
    // =======================================================================
    wire s_tready;       // driven by xfft_0, indicates FFT IP is ready to accept input data
    reg  config_sent;
    
    // Backpressure to preprocessing_1: only ready if FFT IP is ready AND config has been sent
    assign pp_ready_out = s_tready && config_sent;

    // =======================================================================
    // 1.  FFT IP CONFIG CHANNEL (Wake-up Timer Fix)
    // =======================================================================
    reg        cfg_tvalid;
    wire       cfg_tready;       // driven by xfft_0
    reg [4:0]  wakeup_timer;     // counts 20 cycles after reset before sending config to FFT IP

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            config_sent  <= 1'b0;
            cfg_tvalid   <= 1'b0;
            wakeup_timer <= 5'd0;
        end else begin
            // 1. Wait 20 cycles after reset before sending config to FFT IP
            if (wakeup_timer < 5'd20) begin
                wakeup_timer <= wakeup_timer + 1;
            end 
            // 2. If config has not been sent and the wakeup timer has expired, assert cfg_tvalid to send config to FFT IP
            else if (!config_sent && !cfg_tvalid) begin
                cfg_tvalid <= 1'b1; 
            end
            // 3. If config has been sent and the FFT IP has accepted it, deassert cfg_tvalid
            else if (cfg_tvalid && cfg_tready) begin
                config_sent <= 1'b1;
                cfg_tvalid  <= 1'b0;
            end
        end
    end

    // Unscaled FFT config: just set FWD=1
    wire [15:0] cfg_tdata = 16'b0000_0000_0000_0001; 

    // =======================================================================
    // 2.  AXI4-STREAM INPUT BUS ASSEMBLY & HANDSHAKING
    // =======================================================================
    // Only assert valid to FFT if we have valid data AND the config has been accepted
    wire        s_tvalid = (pp_valid_out && config_sent);
    
    // Handshake success indicates data was successfully clocked into the FFT IP
    wire        handshake_success = (s_tvalid && s_tready);

    wire [31:0] s_tdata = (pp_valid_out) ? { pp_data_Q, pp_data_I } : 32'd0;

    // =======================================================================
    // 3.  SAMPLE COUNTER  -  drives tlast on sample 127
    // =======================================================================
    reg [LOG2_N_NUM_BINS-1:0] sample_cnt; // Counts samples from 0 to 127 for each chirp

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_cnt <= 0;
        end else if (handshake_success) begin
            if (sample_cnt == NUM_BINS - 1) begin
                sample_cnt <= 0;
            end else begin
                sample_cnt <= sample_cnt + 1;
            end
        end
    end

    // tlast is asserted on the last sample of each chirp (sample 127)
    wire s_tlast = (sample_cnt == NUM_BINS - 1);

    // =======================================================================
    // 4.  FFT OUTPUT BUS UNPACKING
    // =======================================================================
    wire [31:0] m_tdata;
    wire        m_tvalid;
    wire        m_tlast;

    assign fft_out_I     = m_tdata[15: 0];
    assign fft_out_Q     = m_tdata[31:16];
    assign fft_valid_out = m_tvalid;
    assign fft_last_out  = m_tlast;

    // =======================================================================
    // 5.  XILINX FFT IP INSTANTIATION
    // =======================================================================
    xfft_0 u_xfft (
        // Clock and Reset
        .aclk                  ( clk             ),
        .aresetn               ( rst_n           ), 

        // Config channel
        .s_axis_config_tdata   ( cfg_tdata       ),   
        .s_axis_config_tvalid  ( cfg_tvalid      ),
        .s_axis_config_tready  ( cfg_tready      ),

        // Input data channel
        .s_axis_data_tdata     ( s_tdata         ),  
        .s_axis_data_tvalid    ( s_tvalid        ),
        .s_axis_data_tready    ( s_tready        ), 
        .s_axis_data_tlast     ( s_tlast         ),

        // Output data channel
        .m_axis_data_tdata     ( m_tdata         ),  
        .m_axis_data_tvalid    ( m_tvalid        ),
        .m_axis_data_tready    ( 1'b1            ),
        .m_axis_data_tlast     ( m_tlast         ),

        // Event flags - Ignored
        .event_frame_started          (),
        .event_tlast_unexpected       (),
        .event_tlast_missing          (),
        .event_status_channel_halt    (),  
        .event_data_in_channel_halt   (),
        .event_data_out_channel_halt  ()   
    );

endmodule