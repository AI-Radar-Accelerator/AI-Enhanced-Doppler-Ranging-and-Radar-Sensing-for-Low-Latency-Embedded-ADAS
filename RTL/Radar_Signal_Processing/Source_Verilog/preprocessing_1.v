module preprocessing_1 #(
    parameter DATA_WIDTH = 16,
    parameter ROM_DEPTH  = 128, 
    parameter ADDR_WIDTH = 7    
)(
    input  wire                             clk,            // Clock signal
    input  wire                             rst_n,          // Active-low reset

    input  wire                             fifo_empty,     // FIFO empty flag 
    output wire                             fifo_rd_en,     // FIFO read enable signal 
    input  wire signed [DATA_WIDTH-1:0]     fifo_data_I,    // FIFO data input for I channel
    input  wire signed [DATA_WIDTH-1:0]     fifo_data_Q,    // FIFO data input for Q channel
    
    input  wire                             ready_in,       // Ready signal from downstream module
    
    output reg                              valid_out,      // Valid signal for output data
    output reg  signed [DATA_WIDTH-1:0]     data_out_I,     // Output data for I channel
    output reg  signed [DATA_WIDTH-1:0]     data_out_Q      // Output data for Q channel
);

    // FIFO read enable signal is asserted when the FIFO is not empty and the downstream module is ready to accept data.
    assign fifo_rd_en = !fifo_empty && ready_in;

    reg signed [DATA_WIDTH-1:0] hanning_rom [0:ROM_DEPTH-1];
    initial begin
        $readmemh("hanning_128.mem", hanning_rom);
    end
    // Address counter for reading from the Hanning window ROM
    reg [ADDR_WIDTH-1:0] addr_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_cnt <= 0;
        end else if (ready_in) begin 
            if (fifo_rd_en) begin
                if (addr_cnt == 127)
                    addr_cnt <= 0;
                else
                    addr_cnt <= addr_cnt + 1;
            end
        end
    end

    reg signed [15:0] I_reg_1, Q_reg_1;
    reg signed [15:0] win_coeff_reg;
    reg               valid_reg_1;
    // Registering the input data and Hanning window coefficient for the next stage
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            I_reg_1       <= 0;
            Q_reg_1       <= 0;
            win_coeff_reg <= 0;
            valid_reg_1   <= 0;
        end else if (ready_in) begin 
            I_reg_1       <= fifo_data_I;
            Q_reg_1       <= fifo_data_Q;
            win_coeff_reg <= hanning_rom[addr_cnt];
            valid_reg_1   <= fifo_rd_en;
        end
    end

    reg signed [31:0] mult_I_reg;  // Register to hold the product of I channel data and Hanning window coefficient
    reg signed [31:0] mult_Q_reg;  // Register to hold the product of Q channel data and Hanning window coefficient 
    reg               valid_reg_2; // Register to hold the valid signal for the next stage
    // Performing multiplication of the registered input data with the Hanning window coefficient
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_I_reg  <= 0;
            mult_Q_reg  <= 0;
            valid_reg_2 <= 0;
        end else if (ready_in) begin 
            mult_I_reg  <= I_reg_1 * win_coeff_reg;
            mult_Q_reg  <= Q_reg_1 * win_coeff_reg;
            valid_reg_2 <= valid_reg_1;
        end
    end

    wire overflow_I = mult_I_reg[31] ^ mult_I_reg[30]; // Overflow detection for I channel multiplication result
    wire overflow_Q = mult_Q_reg[31] ^ mult_Q_reg[30]; // Overflow detection for Q channel multiplication result
    // Assigning the final output data and valid signal, with overflow handling
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out_I <= 0;
            data_out_Q <= 0;
            valid_out  <= 0;
        end else if (ready_in) begin 
            if (overflow_I)
                data_out_I <= mult_I_reg[31] ? 16'sh8000 : 16'sh7FFF;
            else
                data_out_I <= mult_I_reg[30:15];
                
            if (overflow_Q)
                data_out_Q <= mult_Q_reg[31] ? 16'sh8000 : 16'sh7FFF;
            else
                data_out_Q <= mult_Q_reg[30:15];
                
            valid_out <= valid_reg_2;
        end
    end
endmodule