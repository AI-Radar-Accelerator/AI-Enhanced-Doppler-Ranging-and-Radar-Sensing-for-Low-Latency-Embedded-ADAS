module stage1_ctrl #(
    // Limit: Max expected cycles to process one full frame.
    // Radar Frame = 128*255*8 + FFT delays ? ~300,000 cycles.
    // We set it to 5,000,000 to be extremely safe against false triggers.
    parameter TIMEOUT_CYCLES = 32'd5_000_000 
)(
    input wire clk,
    input wire rst_n,
    
    // Status Inputs
    input wire fifo_full,
    input wire stage2_ready, 
    
    // --- NEW: End-to-End Frame Tracking ---
    input wire val_start,    // Indicates data is entering the pipeline
    input wire frame_done,   // Indicates a full frame has been processed
    
    // Action Output
    output reg monitor_ready,
    
    // Diagnostic Flags
    output reg error_fifo_overflow,
    output reg error_pipeline_timeout
);

    // ========================================================
    // 1. Detect Critical Errors (FIFO Overflow)
    // ========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_fifo_overflow <= 1'b0;
        end else if (fifo_full) begin
            error_fifo_overflow <= 1'b1; // Sticky error
        end
    end

    // ========================================================
    // 2. Smart End-to-End Watchdog Timer
    // ========================================================
    reg in_flight;
    reg [31:0] watchdog_cnt;
    reg err_timeout;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_flight    <= 1'b0;
            watchdog_cnt <= 32'd0;
            err_timeout  <= 1'b0;
            error_pipeline_timeout <= 1'b0;
        end else begin
            // Track if a frame is currently processing inside the pipeline
            if (frame_done) begin
                in_flight <= 1'b0;      // Frame exited successfully, pipeline is resting
            end else if (val_start) begin
                in_flight <= 1'b1;      // Data actively entering, start tracking
            end

            // Watchdog increments ONLY when data is supposed to be in-flight
            if (frame_done) begin
                watchdog_cnt <= 32'd0;  // Reset timer on success
            end else if (in_flight) begin
                if (watchdog_cnt < TIMEOUT_CYCLES) begin
                    watchdog_cnt <= watchdog_cnt + 1'b1;
                end else begin
                    err_timeout <= 1'b1; // The frame got stuck inside forever!
                    error_pipeline_timeout <= 1'b1;
                end
            end
        end
    end

    // ========================================================
    // 3. The Gatekeeper Logic (Action)
    // ========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            monitor_ready <= 1'b1;
        end else begin
            // Stop receiving new frames IF:
            // 1. FIFO overflowed
            // 2. Stage 2 (AI) is completely stalled
            // 3. Pipeline swallowed a frame and never outputted it (Hung)
            if (error_fifo_overflow || !stage2_ready || err_timeout) begin
                monitor_ready <= 1'b0; 
            end else begin
                monitor_ready <= 1'b1;
            end
        end
    end

endmodule