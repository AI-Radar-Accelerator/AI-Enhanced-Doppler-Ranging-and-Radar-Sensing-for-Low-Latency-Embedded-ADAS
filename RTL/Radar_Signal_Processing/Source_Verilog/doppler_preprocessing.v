`timescale 1ns / 1ps

module doppler_preprocessing #(
    parameter DATA_WIDTH   = 16,
    parameter NUM_BINS     = 128,  // Keeping positive range bins only
    parameter NUM_CHIRPS   = 255,  // Actual valid chirps
    parameter FFT_SIZE     = 256,  // Power of 2 size for Xilinx FFT IP (Zero-padded)
    parameter NUM_ANTENNAS = 8     // 8 Virtual Antennas
)(
    input  wire clk,
    input  wire rst_n,

    // ==========================================
    // 1. Inputs from Range FFT
    // ==========================================
    input  wire                               range_valid_in,  // Valid signal from Range FFT
    input  wire signed [DATA_WIDTH-1:0]       range_data_I,    // In-phase data from Range FFT 
    input  wire signed [DATA_WIDTH-1:0]       range_data_Q,    // Quadrature data from Range FFT
    

    input  wire                               ready_in,        // Ready signal from Doppler FFT

    // ==========================================
    // 2. Outputs to Doppler FFT
    // ==========================================
    output reg                                dop_valid_out,    
    output reg  signed [DATA_WIDTH-1:0]       dop_data_I,
    output reg  signed [DATA_WIDTH-1:0]       dop_data_Q,
    output reg                                dop_last_out
);

    // ==========================================
    // Internal Memories (Triple Buffer)
    // ==========================================
    (* ram_style = "ultra" *) reg [31:0] corner_mem [0:98303];

    // Hanning Window ROM
    reg signed [15:0] hanning_rom [0:254];

    initial begin
        $readmemh("hanning_255.mem", hanning_rom);
    end

    // ==========================================
    // State Machine & Counters
    // ==========================================
    reg [1:0] write_page;
    reg [1:0] read_page;

    // Write Counters
    reg [6:0] write_bin_cnt;   
    reg [7:0] write_chirp_cnt; 
    reg [2:0] write_ant_cnt;   
    
    // Read Counters
    reg [6:0] read_bin_cnt;    
    reg [8:0] read_chirp_cnt;  
    reg [2:0] read_ant_cnt;    

    // ==========================================
    // Address Mapping (Triple Buffer)
    // ==========================================
    wire [16:0] write_addr = (write_page * 17'd32768) + (write_chirp_cnt * 128) + write_bin_cnt;
    wire [16:0] read_addr  = (read_page  * 17'd32768) + (read_chirp_cnt[7:0] * 128) + read_bin_cnt;

    // ==========================================
    // Page Availability Manager 
    // ==========================================
    wire write_page_done = range_valid_in && (write_bin_cnt == NUM_BINS - 1) && (write_chirp_cnt == NUM_CHIRPS - 1);
    reg reading; 
    
    wire read_page_done  = reading && ready_in && (read_chirp_cnt == FFT_SIZE - 1) && (read_bin_cnt == NUM_BINS - 1);
    
    reg [1:0] pages_available; 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            pages_available <= 0;
        else if (write_page_done && !read_page_done) 
            pages_available <= pages_available + 1;
        else if (!write_page_done && read_page_done) 
            pages_available <= pages_available - 1;
    end

    // ==========================================
    // ? Write Logic - MEMORY WRITE BLOCK 
    // ==========================================
    wire write_en = range_valid_in && (write_bin_cnt < NUM_BINS);
    always @(posedge clk) begin
        if (write_en) begin
            corner_mem[write_addr] <= {range_data_Q, range_data_I};
        end
    end

    // ==========================================
    // Write Logic - COUNTERS BLOCK 
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_bin_cnt   <= 0;
            write_chirp_cnt <= 0;
            write_ant_cnt   <= 0;
            write_page      <= 0;
        end else begin
            if (range_valid_in) begin
                if (write_bin_cnt == NUM_BINS - 1) begin
                    write_bin_cnt <= 0;
                    if (write_chirp_cnt == NUM_CHIRPS - 1) begin
                        write_chirp_cnt <= 0;
                        write_page      <= (write_page == 2) ? 0 : write_page + 1;
                        if (write_ant_cnt == NUM_ANTENNAS - 1)
                            write_ant_cnt <= 0;
                        else
                            write_ant_cnt <= write_ant_cnt + 1;
                    end else begin
                        write_chirp_cnt <= write_chirp_cnt + 1;
                    end
                end else begin
                    write_bin_cnt <= write_bin_cnt + 1;
                end
            end
        end
    end

    // ==========================================
    // Read Logic (Independent FSM)
    // ==========================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_bin_cnt   <= 0;
            read_chirp_cnt <= 0;
            read_ant_cnt   <= 0;
            read_page      <= 0;
            reading        <= 0;
        end else begin
            if (!reading && pages_available > 0) begin
                reading <= 1;
            end

            if (reading && ready_in) begin
                if (read_chirp_cnt == FFT_SIZE - 1) begin
                    read_chirp_cnt <= 0;
                    if (read_bin_cnt == NUM_BINS - 1) begin
                        read_bin_cnt <= 0;
                        read_page    <= (read_page == 2) ? 0 : read_page + 1;
                        
                        if (pages_available == 1 && !write_page_done) begin
                            reading <= 0;
                        end

                        if (read_ant_cnt == NUM_ANTENNAS - 1)
                            read_ant_cnt <= 0;
                        else
                            read_ant_cnt <= read_ant_cnt + 1;
                    end else begin
                        read_bin_cnt <= read_bin_cnt + 1;
                    end
                end else begin
                    read_chirp_cnt <= read_chirp_cnt + 1;
                end
            end
        end
    end

    // ==========================================
    // Pipeline Stages 
    // ==========================================
    
    // STAGE 1 - Memory Read
    reg [31:0] mem_read_data;
    reg [8:0]  chirp_cnt_stage1;
    reg valid_stage1;
    reg last_stage1;

    //  STAGE 1 - Valid and Last Signal Generation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_stage1 <= 1'b0;
            last_stage1  <= 1'b0;
        end else if (ready_in) begin 
            if (reading) begin
                valid_stage1 <= 1'b1;
                last_stage1  <= (read_chirp_cnt == FFT_SIZE - 1);
            end else begin
                valid_stage1 <= 1'b0;
                last_stage1  <= 1'b0;
            end
        end
    end
    //  STAGE 1 - Memory Read
    always @(posedge clk) begin
        if (ready_in && reading) begin 
            mem_read_data    <= corner_mem[read_addr];
            chirp_cnt_stage1 <= read_chirp_cnt;
        end
    end

    // STAGE 2 - Windowing
    reg signed [15:0] I_reg_1, Q_reg_1, win_coeff_reg;
    reg               valid_reg_1, last_reg_1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_reg_1 <= 1'b0;
            last_reg_1  <= 1'b0;
        end else if (ready_in) begin
            valid_reg_1 <= valid_stage1;
            last_reg_1  <= last_stage1;
        end
    end

    always @(posedge clk) begin
        if (ready_in && valid_stage1) begin
            if (chirp_cnt_stage1 < NUM_CHIRPS) begin
                I_reg_1       <= mem_read_data[15:0];
                Q_reg_1       <= mem_read_data[31:16];
                win_coeff_reg <= hanning_rom[chirp_cnt_stage1];
            end else begin
                I_reg_1       <= 16'd0;
                Q_reg_1       <= 16'd0;
                win_coeff_reg <= 16'd0;
            end
        end
    end

    // STAGE 3
    reg signed [31:0] mult_I_reg, mult_Q_reg;
    reg valid_reg_2, last_reg_2;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_reg_2 <= 1'b0;
            last_reg_2  <= 1'b0;
        end else if (ready_in) begin
            valid_reg_2 <= valid_reg_1;
            last_reg_2  <= last_reg_1;
        end
    end

    always @(posedge clk) begin
        if (ready_in) begin 
            mult_I_reg   <= I_reg_1 * win_coeff_reg;
            mult_Q_reg   <= Q_reg_1 * win_coeff_reg;
        end
    end

    // ? STAGE 4
    wire overflow_I = mult_I_reg[31] ^ mult_I_reg[30];
    wire overflow_Q = mult_Q_reg[31] ^ mult_Q_reg[30];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dop_data_I     <= 0;
            dop_data_Q     <= 0;
            dop_valid_out  <= 0;
            dop_last_out   <= 0;
        end else if (ready_in) begin 
            dop_data_I <= overflow_I ? (mult_I_reg[31] ? 16'sh8000 : 16'sh7FFF) : mult_I_reg[30:15];
            dop_data_Q <= overflow_Q ? (mult_Q_reg[31] ? 16'sh8000 : 16'sh7FFF) : mult_Q_reg[30:15];
            dop_valid_out  <= valid_reg_2;
            dop_last_out   <= last_reg_2;
        end
    end

endmodule