module coherent_integration #(
    parameter NUM_RANGE   = 128,  //  128 Range Bins
    parameter NUM_DOPPLER = 256,
    parameter NUM_ANGLE   = 8,
    parameter ACC_WIDTH   = 24,   // Accumulator width to prevent overflow
    parameter ADDR_WIDTH  = 15    // 7 (Range) + 8 (Doppler) = 15 bits
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // 1. Interface with Doppler FFT (Input Stream)
    input  wire                   valid_in,
    input  wire signed [15:0]     data_in_I,
    input  wire signed [15:0]     data_in_Q,

    // 2. Interface with next stage (Output Stream)
    input  wire                   ready_in,
    output reg                    valid_out,
    output reg  signed [15:0]     data_out_I,
    output reg  signed [15:0]     data_out_Q,

    // Status
    output reg                    integration_done_flag
);

    // ========================================================
    // 1. Memory Definition (Accumulator RAM)
    // ========================================================
    // Depth = 128 * 256 = 32,768 entries
    localparam MEM_DEPTH = NUM_RANGE * NUM_DOPPLER;
    reg signed [ACC_WIDTH-1:0] acc_mem_I [0:MEM_DEPTH-1];
    reg signed [ACC_WIDTH-1:0] acc_mem_Q [0:MEM_DEPTH-1];

    // ========================================================
    // 2. Write Counters (Order: Doppler -> Range -> Angle)
    // ========================================================
    reg [7:0]  w_doppler; // 0 to 255 (Fastest)
    reg [6:0]  w_range;   // 0 to 127 (Middle)
    reg [2:0]  w_angle;   // 0 to 7   (Slowest)
    
    // Write address maintains fixed memory order for easy storage
    wire [ADDR_WIDTH-1:0] w_addr = {w_range, w_doppler};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_doppler <= 0;
            w_range   <= 0;
            w_angle   <= 0;
        end else if (valid_in) begin
            if (w_doppler == NUM_DOPPLER - 1) begin
                w_doppler <= 0;
                if (w_range == NUM_RANGE - 1) begin
                    w_range <= 0;
                    if (w_angle == NUM_ANGLE - 1) begin
                        w_angle <= 0;
                    end else begin
                        w_angle <= w_angle + 1;
                    end
                end else begin
                    w_range <= w_range + 1;
                end
            end else begin
                w_doppler <= w_doppler + 1;
            end
        end
    end

    // ========================================================
    // 3. Read FSM (Streaming Output - Range First & Doppler Shifted)
    // ========================================================
    reg [7:0] r_doppler;
    reg [6:0] r_range;      
    reg       r_reading;

    // Modification 1: Apply fftshift by inverting MSB of Doppler counter
    wire [7:0] r_doppler_shifted = {~r_doppler[7], r_doppler[6:0]};

    // Read address based on original stored order but with shifted Doppler
    wire [ADDR_WIDTH-1:0] r_addr = {r_range, r_doppler_shifted};

    // Multiplexing the BRAM Read Address
    wire [ADDR_WIDTH-1:0] mem_read_addr = r_reading ? r_addr : w_addr;

    reg signed [ACC_WIDTH-1:0] ram_read_I, ram_read_Q;
    always @(posedge clk) begin
        ram_read_I <= acc_mem_I[mem_read_addr];
        ram_read_Q <= acc_mem_Q[mem_read_addr];
    end

    // ========================================================
    // 4. Accumulator Pipeline (Read-Modify-Write)
    // ========================================================
    reg valid_in_d1;
    reg [2:0] w_angle_d1;
    
    // Delayed counter registers for pipeline
    reg [6:0] w_range_d1;
    reg [7:0] w_doppler_d1;
    
    reg [ADDR_WIDTH-1:0] w_addr_d1;
    reg signed [15:0] data_in_I_d1, data_in_Q_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_in_d1  <= 0;
            w_angle_d1   <= 0;
            w_range_d1   <= 0;  // Reset
            w_doppler_d1 <= 0;  // Reset
            w_addr_d1    <= 0;
            data_in_I_d1 <= 0;
            data_in_Q_d1 <= 0;
        end else begin
            valid_in_d1  <= valid_in;
            w_angle_d1   <= w_angle;
            w_range_d1   <= w_range;     // Forward value
            w_doppler_d1 <= w_doppler;   // Forward value
            w_addr_d1    <= w_addr;
            data_in_I_d1 <= data_in_I;
            data_in_Q_d1 <= data_in_Q;
        end
    end

    // Write and accumulate data to memory
    always @(posedge clk) begin
        if (valid_in_d1) begin
            if (w_angle_d1 == 0) begin
                acc_mem_I[w_addr_d1] <= data_in_I_d1;
                acc_mem_Q[w_addr_d1] <= data_in_Q_d1;
            end else begin
                acc_mem_I[w_addr_d1] <= ram_read_I + data_in_I_d1;
                acc_mem_Q[w_addr_d1] <= ram_read_Q + data_in_Q_d1;
            end
        end
    end

    // Integration completion pulse
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integration_done_flag <= 0;
        end else begin
            if (valid_in_d1 && w_angle_d1 == NUM_ANGLE - 1 && 
                w_range_d1 == NUM_RANGE - 1 && w_doppler_d1 == NUM_DOPPLER - 1) begin
                integration_done_flag <= 1;
            end else begin
                integration_done_flag <= 0;
            end
        end
    end

    // ========================================================
    // 5. Output Streaming Logic (Modification 2: Output Range First)
    // ========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_doppler <= 0;
            r_range   <= 0;
            r_reading <= 0;
        end else begin
            if (integration_done_flag)
                r_reading <= 1;
                
            if (r_reading && ready_in) begin
                // Range is the fastest index, changes every clock cycle
                r_range <= r_range + 1;
                if (r_range == NUM_RANGE - 1) begin
                    r_range   <= 0;
                    // Doppler increments only when Range completes (Slowest Index)
                    r_doppler <= r_doppler + 1;
                    if (r_doppler == NUM_DOPPLER - 1) begin
                        r_doppler <= 0;
                        r_reading <= 0; // Frame output complete
                    end
                end
            end
        end
    end

    // ========================================================
    // 6. Output Pipeline & Saturation
    // ========================================================
    reg r_valid_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_valid_d1 <= 0;
            valid_out  <= 0;
            data_out_I <= 0;
            data_out_Q <= 0;
        end else begin
            r_valid_d1 <= (r_reading && ready_in);
            valid_out  <= r_valid_d1;
            
            if (r_valid_d1) begin
                // Saturation logic for I
                if (ram_read_I[ACC_WIDTH-1] == 1'b0 && |ram_read_I[ACC_WIDTH-2:18]) 
                    data_out_I <= 16'sh7FFF;
                else if (ram_read_I[ACC_WIDTH-1] == 1'b1 && ~&ram_read_I[ACC_WIDTH-2:18]) 
                    data_out_I <= 16'sh8000;
                else 
                    data_out_I <= ram_read_I[18:3];

                // Saturation logic for Q
                if (ram_read_Q[ACC_WIDTH-1] == 1'b0 && |ram_read_Q[ACC_WIDTH-2:18]) 
                    data_out_Q <= 16'sh7FFF;
                else if (ram_read_Q[ACC_WIDTH-1] == 1'b1 && ~&ram_read_Q[ACC_WIDTH-2:18]) 
                    data_out_Q <= 16'sh8000;
                else 
                    data_out_Q <= ram_read_Q[18:3];
            end
        end
    end

endmodule