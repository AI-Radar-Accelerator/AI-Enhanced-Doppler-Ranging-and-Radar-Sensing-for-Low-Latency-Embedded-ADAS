`timescale 1ns / 1ps

module axis_radar_wrapper #(
    parameter DATA_WIDTH = 16,
    parameter FRAME_SIZE = 32768
)(
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Stream Slave (Input from DMA / Laptop)
    input  wire [31:0] s_axis_tdata,    // 16-bit I + 16-bit Q
    input  wire        s_axis_tvalid,   // Indicates valid data on s_axis_tdata
    output wire        s_axis_tready,   // Indicates the module is ready to accept data
    input  wire        s_axis_tlast,    // Indicates the last data word in a frame
    input  wire [3:0]  s_axis_tkeep,    // Indicates which bytes of s_axis_tdata are valid

    // AXI4-Stream Master (Output to DMA / Laptop)
    output wire [63:0] m_axis_tdata,    // 16-bit padding + Amp + Re + Im
    output wire        m_axis_tvalid,   // Indicates valid data on m_axis_tdata
    input  wire        m_axis_tready,   // Indicates the downstream module is ready to accept data
    output reg         m_axis_tlast,    // Indicates the last data word in a frame
    output wire [7:0]  m_axis_tkeep     // Indicates which bytes of m_axis_tdata are valid 
);

    wire [DATA_WIDTH-1:0] out_amp;      // Output amplitude from the radar core
    wire [DATA_WIDTH-1:0] out_re;       // Output real part from the radar core
    wire [DATA_WIDTH-1:0] out_im;       // Output imaginary part from the radar core
    wire                  radar_valid_out;  // Indicates valid output data from the radar core

    // Pack the outputs into a 64-bit word (16-bit padding + Amp + Re + Im)
    assign m_axis_tdata  = {16'd0, out_amp, out_re, out_im};
    assign m_axis_tvalid = radar_valid_out;
    
    
    assign m_axis_tkeep  = 8'hFF; 

    // ==========================================
    // ⏳ 40MHz Spaced Throttling Logic
    // ==========================================
    reg [3:0] throttle_cnt;
    wire      throttle_allow;

    // Throttle counter to allow data every 10 cycles (for 40MHz from 100MHz)
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            throttle_cnt <= 0;
        end else begin
            if (throttle_cnt == 9)
                throttle_cnt <= 0;
            else
                throttle_cnt <= throttle_cnt + 1;
        end
    end

    // Allow data on specific cycles to achieve 40MHz effective rate
    assign throttle_allow = (throttle_cnt == 0 || throttle_cnt == 2 || throttle_cnt == 5 || throttle_cnt == 7);

    wire core_ready;
    assign s_axis_tready = core_ready && throttle_allow;
    wire gated_valid_in  = s_axis_tvalid && throttle_allow;

    // ==========================================
    //  TLAST Generator for DMA
    // ==========================================
    reg [15:0] out_counter;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            out_counter  <= 0;
            m_axis_tlast <= 0;
        end else begin
            if (radar_valid_out && m_axis_tready) begin
                if (out_counter == FRAME_SIZE - 2) begin
                    m_axis_tlast <= 1'b1; // Trigger TLAST on the last sample
                    out_counter  <= out_counter + 1;
                end else if (out_counter == FRAME_SIZE - 1) begin
                    m_axis_tlast <= 1'b0;
                    out_counter  <= 0;
                end else begin
                    out_counter  <= out_counter + 1;
                end
            end
        end
    end

    // ==========================================
    // Instantiate Your Masterpiece (TOP_STAGE_1)
    // ==========================================
    TOP_STAGE_1 #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_BINS(128),
        .NUM_CHIRPS(255),
        .NUM_ANGLES(8)
    ) u_radar_core (
        .clk              (aclk),
        .rst_n            (aresetn),
        .adc_clk          (aclk),      // Single clock domain 100MHz for AXI DMA
        .adc_rst_n        (aresetn),
        
        .adc_valid_in     (gated_valid_in), 
        
        // ADC Data Inputs (I and Q)
        .adc_data_I       (s_axis_tdata[31:16]),
        .adc_data_Q       (s_axis_tdata[15:0]),
        
        .ready            (m_axis_tready),
        .adc_ready_out    (core_ready), 
        
        .stage1_valid_out (radar_valid_out),
        .stage1_data_amp  (out_amp),
        .stage1_data_re   (out_re),
        .stage1_data_im   (out_im),
        .integration_done ()
    );

endmodule