`timescale 1ns / 1ps

module doppler_fft_wrapper #(
    parameter DATA_WIDTH   = 16
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // -----------------------------------------------------------------------
    // Input from doppler_preprocessing
    // -----------------------------------------------------------------------
    input  wire                       dop_valid_in, // Valid signal for doppler data
    input  wire signed [DATA_WIDTH-1:0] dop_data_I, // In-phase component of doppler data
    input  wire signed [DATA_WIDTH-1:0] dop_data_Q, // Quadrature component of doppler data
    input  wire                       dop_last_in,  // Last signal for doppler data

    // -----------------------------------------------------------------------
    // Output (Doppler FFT Result)
    // -----------------------------------------------------------------------
    output wire                       fft_valid_out, // Valid signal for FFT output
    output wire signed [DATA_WIDTH-1:0] fft_out_I,   // In-phase component of FFT output
    output wire signed [DATA_WIDTH-1:0] fft_out_Q,   // Quadrature component of FFT output
    output wire                       fft_last_out,  // Last signal for FFT output
    
    
    output wire                       dop_ready_out  // Ready signal for doppler input (backpressure)
);

    // =======================================================================
    // 0. GLOBAL WIRES & BACKPRESSURE LOGIC
    // =======================================================================
    wire s_tready;       // driven by xfft_1
    reg  config_sent;
    
    // Backpressure logic: doppler_preprocessing can send data only when FFT is ready and configuration has been sent
    assign dop_ready_out = s_tready && config_sent;

    // =======================================================================
    // 1. CONFIGURATION CHANNEL (Set to FORWARD FFT) + Wake-up Timer
    // =======================================================================
    reg        cfg_tvalid;
    wire       cfg_tready;
    reg [4:0]  wakeup_timer; // 5-bit timer to wait for 20 clock cycles before sending configuration

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            config_sent  <= 1'b0;
            cfg_tvalid   <= 1'b0;
            wakeup_timer <= 5'd0;
        end else begin
            // 1. Wait for 20 clock cycles after reset before sending configuration
            if (wakeup_timer < 5'd20) begin
                wakeup_timer <= wakeup_timer + 1;
            end 
            // 2. If configuration has not been sent and the timer has expired, assert cfg_tvalid to send configuration
            else if (!config_sent && !cfg_tvalid) begin
                cfg_tvalid <= 1'b1; 
            end
            // 3. Once configuration is sent and acknowledged (cfg_tready), mark configuration as sent and deassert cfg_tvalid
            else if (cfg_tvalid && cfg_tready) begin
                config_sent <= 1'b1;
                cfg_tvalid  <= 1'b0;
            end
        end
    end

    // FWD=1 => Forward FFT, INVERSE=0 => Inverse FFT
    wire [15:0] cfg_tdata = 16'b0000000_10101010_1; 

    // =======================================================================
    // 2. AXI4-STREAM INPUT BUS ASSEMBLY
    // =======================================================================
    // 
    wire [31:0] s_tdata  = (dop_valid_in) ? { dop_data_Q, dop_data_I } : 32'd0;
    wire        s_tvalid = dop_valid_in && config_sent;
    wire        s_tlast  = dop_last_in;

    // =======================================================================
    // 3. FFT OUTPUT BUS UNPACKING
    // =======================================================================
    wire [31:0] m_tdata;
    wire        m_tvalid;
    wire        m_tlast;

    assign fft_out_I     = m_tdata[15:0];
    assign fft_out_Q     = m_tdata[31:16];
    assign fft_valid_out = m_tvalid;
    assign fft_last_out  = m_tlast;

    // =======================================================================
    // 4. XILINX FFT IP INSTANTIATION (xfft_1)
    // =======================================================================
    xfft_1 u_doppler_xfft (
        // Clock and Reset
        .aclk                        (clk),
        .aresetn                     (rst_n), 
        
        // Config channel
        .s_axis_config_tdata         (cfg_tdata),
        .s_axis_config_tvalid        (cfg_tvalid),
        .s_axis_config_tready        (cfg_tready),

        // Input data channel
        .s_axis_data_tdata           (s_tdata),
        .s_axis_data_tvalid          (s_tvalid),
        .s_axis_data_tready          (s_tready),
        .s_axis_data_tlast           (s_tlast),

        // Output data channel
        .m_axis_data_tdata           (m_tdata),
        .m_axis_data_tvalid          (m_tvalid),
        .m_axis_data_tready          (1'b1), 
        .m_axis_data_tlast           (m_tlast),

        // Unused Event Flags
        .event_frame_started         (),
        .event_tlast_unexpected      (),
        .event_tlast_missing         (),
        .event_status_channel_halt   (),
        .event_data_in_channel_halt  (),
        .event_data_out_channel_halt ()
    );

endmodule