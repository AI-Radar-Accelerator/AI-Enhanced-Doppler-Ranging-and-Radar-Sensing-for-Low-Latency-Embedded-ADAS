module zscore_2d_stream #(
    parameter DATA_WIDTH    = 16,
    parameter ROWS          = 128,          
    parameter COLS          = 256,
    parameter FRAME_SIZE    = ROWS * COLS,  
    parameter FRACTION_BITS = 24,
    parameter FRAC_OUT_BITS = 8
)(
    input  wire clk,
    input  wire rstn,
    
    input  wire valid_in,
    input  wire signed [DATA_WIDTH-1:0] data_in,
    input  wire ready,
    output reg  valid_out,
    output reg  signed [DATA_WIDTH-1:0] data_out
);

    localparam SHIFT      = FRACTION_BITS - FRAC_OUT_BITS; 
    localparam PROD_WIDTH = DATA_WIDTH + 33;
    localparam LOG2_N     = $clog2(FRAME_SIZE);            

    localparam [2:0] LOAD       = 3'd0;
    localparam [2:0] VARIANCE   = 3'd1;
    localparam [2:0] WAIT_SQRT  = 3'd2;
    localparam [2:0] CALC_RECIP = 3'd3; 
    localparam [2:0] NORMALIZE  = 3'd4;

    //  BRAM Inference with Safe Simulation Read
    (* ram_style = "block" *) reg signed [DATA_WIDTH-1:0] mem [0:FRAME_SIZE-1];
    
    reg [2:0] state, next_state; 

    reg [LOG2_N:0] index; 
    
    reg signed [31:0] sum;
    reg signed [63:0] var_sum;
    reg signed [31:0] mean;
    reg signed [63:0] variance;

    reg  variance_valid;
    wire cordic_valid;
    wire [23:0] cordic_full_out;
    wire [15:0] std_dev = cordic_full_out[15:0];
    reg [32:0] recip_std;
    
    reg signed [PROD_WIDTH-1:0] pipe_product;
    
    //  PIPELINE REGISTERS (To sync 1-cycle BRAM read latency)
    reg pipe_valid_1;
    reg pipe_valid_2;
    reg signed [31:0] clean_diff_pipe;

    //  SEQUENTIAL DIVIDER REGISTERS (For Timing Closure)
    reg [32:0] quotient_reg;
    reg [16:0] remainder_reg;
    reg [16:0] divisor_reg;
    reg [5:0]  div_cnt;

    // ==========================================
    // MEMORY WRITE & READ BLOCKS
    // ==========================================
    wire write_en = (state == LOAD) && valid_in && (index < FRAME_SIZE);
    always @(posedge clk) begin
        if (write_en) begin
            mem[index] <= data_in;
        end
    end

    reg signed [DATA_WIDTH-1:0] mem_read_data;
    always @(posedge clk) begin
        // Safe read: Prevents reading out of bounds during simulation which causes 'x'
        mem_read_data <= mem[(index < FRAME_SIZE) ? index : 0];
    end

    // ==========================================
    // COMBINATIONAL LOGIC
    // ==========================================
    wire signed [31:0] data_in_ext = { {16{data_in[15]}}, data_in };
    wire signed [31:0] mem_ext     = { {16{mem_read_data[15]}}, mem_read_data };
    wire signed [31:0] clean_diff  = mem_ext - mean;
    
    wire signed [63:0] sq_diff     = clean_diff * clean_diff;
    
    wire signed [33:0] clean_recip = $signed({1'b0, recip_std});
    wire signed [PROD_WIDTH-1:0] norm_shifted = pipe_product >>> SHIFT;
    
    reg signed [DATA_WIDTH-1:0] norm_saturated;
    always @(*) begin
        if (norm_shifted > 32767)
            norm_saturated = 16'sh7FFF;
        else if (norm_shifted < -32768)
            norm_saturated = 16'sh8000;
        else
            norm_saturated = norm_shifted[15:0];
    end

    // ==========================================
    // STATE MACHINE (Zero-Delay Transitions)
    // ==========================================

    always @(*) begin
        case (state)
            LOAD:       next_state = (valid_in && index == FRAME_SIZE - 1) ? VARIANCE : LOAD;
            VARIANCE:   next_state = (index == FRAME_SIZE && pipe_valid_1 == 0) ? WAIT_SQRT : VARIANCE;
            WAIT_SQRT:  next_state = cordic_valid ? CALC_RECIP : WAIT_SQRT; 
            CALC_RECIP: next_state = (div_cnt == 0) ? NORMALIZE : CALC_RECIP; 
            NORMALIZE:  next_state = (index == FRAME_SIZE && pipe_valid_1 == 0 && pipe_valid_2 == 0) ? LOAD : NORMALIZE;
            default:    next_state = LOAD;
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) state <= LOAD;
        else       state <= next_state;
    end

    // ==========================================
    // MAIN FSM LOGIC
    // ==========================================
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            index          <= 0;
            sum            <= 0;
            var_sum        <= 0;
            mean           <= 0;
            variance       <= 0;
            variance_valid <= 0;
            recip_std      <= 0;
            pipe_product   <= 0;
            valid_out      <= 0;
            data_out       <= 0;
            quotient_reg   <= 0;
            remainder_reg  <= 0;
            divisor_reg    <= 0;
            div_cnt        <= 0;
            pipe_valid_1   <= 0;
            pipe_valid_2   <= 0;
            clean_diff_pipe<= 0;
        end else begin
            variance_valid <= 0;
            valid_out      <= 0;

            case (state)
            LOAD: begin
                if (valid_in && index < FRAME_SIZE) begin
                    sum <= sum + data_in_ext;
                    if (index == FRAME_SIZE - 1) begin
                        mean       <= (sum + data_in_ext) >>> LOG2_N;
                        sum        <= 0;
                        var_sum    <= 0;
                        index      <= 0;
                    end else begin
                        index <= index + 1;
                    end
                end
            end

            VARIANCE: begin
                // 🚀 STAGE 0: Fetch Address
                if (index < FRAME_SIZE) begin
                    index <= index + 1;
                    pipe_valid_1 <= 1;
                end else begin
                    pipe_valid_1 <= 0;
                end

                // 🚀 STAGE 1: Process Data (Delayed by 1 clock to match BRAM)
                if (pipe_valid_1) begin
                    var_sum <= var_sum + sq_diff;
                end

                // Done when all addresses are fetched AND processed
                if (index == FRAME_SIZE && pipe_valid_1 == 0) begin
                    variance <= var_sum >>> LOG2_N;
                    variance_valid <= 1;
                    var_sum        <= 0;
                    index          <= 0;
                end
            end

            WAIT_SQRT: begin
                if (cordic_valid) begin
                    if (std_dev == 0) begin
                        quotient_reg <= 0;
                        div_cnt      <= 0; 
                    end else begin
                        quotient_reg  <= (33'd1 << FRACTION_BITS) + {17'd0, std_dev[15:1]};
                        divisor_reg   <= {1'b0, std_dev};
                        remainder_reg <= 0;
                        div_cnt       <= 33; 
                    end
                end
            end

            CALC_RECIP: begin
                if (div_cnt != 0) begin
                    if ({remainder_reg[15:0], quotient_reg[32]} >= divisor_reg) begin
                        remainder_reg <= {remainder_reg[15:0], quotient_reg[32]} - divisor_reg;
                        quotient_reg  <= {quotient_reg[31:0], 1'b1};
                    end else begin
                        remainder_reg <= {remainder_reg[15:0], quotient_reg[32]};
                        quotient_reg  <= {quotient_reg[31:0], 1'b0};
                    end
                    div_cnt <= div_cnt - 1;
                end else begin
                    recip_std <= quotient_reg; 
                    index     <= 0;
                end
            end

            NORMALIZE: begin
                if (ready) begin
                    //  STAGE 0: Fetch Address
                    if (index < FRAME_SIZE) begin
                        index <= index + 1;
                        pipe_valid_1 <= 1;
                    end else begin
                        pipe_valid_1 <= 0;
                    end

                    //  STAGE 1: Compute Product
                    if (pipe_valid_1) begin
                        pipe_product <= clean_diff * clean_recip;
                        clean_diff_pipe <= clean_diff;
                        pipe_valid_2 <= 1;
                    end else begin
                        pipe_valid_2 <= 0;
                    end

                    //  STAGE 2: Saturate and Output
                    valid_out <= pipe_valid_2;
                    if (pipe_valid_2) begin
                        if (recip_std != 0) data_out <= norm_saturated;
                        else                data_out <= clean_diff_pipe[15:0];
                    end

                    // Done when all addresses fetched, computed, and outputted
                    if (index == FRAME_SIZE && pipe_valid_1 == 0 && pipe_valid_2 == 0) begin
                        index <= 0;
                    end
                end
            end
            endcase
        end
    end

    cordic_1 sqrt_inst (
        .aclk                    (clk),
        .s_axis_cartesian_tvalid (variance_valid),
        .s_axis_cartesian_tdata  (variance[31:0]),
        .m_axis_dout_tvalid      (cordic_valid),
        .m_axis_dout_tdata       (cordic_full_out)
    );

endmodule