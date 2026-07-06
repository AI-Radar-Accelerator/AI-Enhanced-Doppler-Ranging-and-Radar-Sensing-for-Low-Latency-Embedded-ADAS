// =============================================================================
// conv2d_matmul.sv  —  MAC-serialized conv2d (fixed P x K x K multipliers)
// =============================================================================

module conv2d_matmul #(
    parameter DATA_W      = 16,
    parameter FRAC_W      = 8,
    parameter C_IN        = 3,
    parameter C_OUT       = 64,
    parameter H_IN        = 64,
    parameter W_IN        = 256,
    parameter K           = 3,
    parameter STRIDE      = 2,
    parameter PAD         = 1,
    parameter P           = 64,           // filters computed in parallel (must divide C_OUT)
    parameter WEIGHT_FILE = "G:/0. Sarah/0. Files_Sarah/4. GP Docs/singleline/weights.hex"
)(
    input  wire              clk,
    input  wire              rst_n,
    // Input pixel stream — channel-interleaved, valid/ready handshake
    input  wire              in_valid,
    output wire              in_ready,
    input  wire [DATA_W-1:0] in_data,
    // Output stream — one result pixel per cycle, valid/ready handshake
    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data
);

// ─── Derived parameters ──────────────────────────────────────────────────────
localparam H_OUT   = (H_IN + 2*PAD - K) / STRIDE + 1;
localparam W_OUT   = (W_IN + 2*PAD - K) / STRIDE + 1;
localparam KK      = K * K;                    // multipliers per filter per cycle
localparam W_PAD   = W_IN + 2*PAD;
// Accumulator must hold sum over C_IN*K*K signed products without overflow
localparam ACC_W   = 2*DATA_W + $clog2(C_IN*KK) + 1;
localparam GROUPS  = C_OUT / P;
localparam LEVELS  = $clog2(KK);               // adder tree depth for K*K terms
localparam PAD_SZ  = 1 << LEVELS;

// Extra slot K is the permanent zero/padding row
localparam BUF_ROWS = K + 1;

localparam GRP_W = (GROUPS <= 1) ? 1 : $clog2(GROUPS);
localparam P_W   = (P <= 1) ? 1 : $clog2(P);
localparam HOUT_W = (H_OUT <= 1) ? 1 : $clog2(H_OUT);
localparam WOUT_W = (W_OUT <= 1) ? 1 : $clog2(W_OUT);
localparam HIN_W  = (H_IN <= 1) ? 1 : $clog2(H_IN);
localparam WIN_W  = (W_IN <= 1) ? 1 : $clog2(W_IN);
localparam CIN_CTR_W = (C_IN <= 1) ? 1 : $clog2(C_IN);

// ─── Weight ROM ──────────────────────────────────────────────────────────────
// Flat layout: [(grp*P + gf)*C_IN*KK + ic*KK + (ky*K+kx)]
localparam FILT_SZ = C_OUT * C_IN * KK;
reg [DATA_W-1:0] filt_mem [0:FILT_SZ-1];
initial $readmemh(WEIGHT_FILE, filt_mem);

// ─── Line buffer: K+1 rows per channel (slot K = permanent zero row) ─────────
reg [DATA_W-1:0] row_buf [0:C_IN-1][0:BUF_ROWS-1][0:W_PAD-1];

// Write-side counters
reg [CIN_CTR_W-1:0] wr_c;
reg [HIN_W-1:0]     wr_r;
reg [WIN_W-1:0]     wr_w;

// rows_filled: sole owner = write block; cleared via row_done signal from FSM
reg rows_filled;

// tensor_loaded: set permanently once the full input tensor (C_IN*H_IN*W_IN
// pixels) has been written at least once. Needed because once the input
// stream ends, wr_r/wr_c/wr_w stop advancing — so for trailing output rows
// whose need_row was already satisfied by data written for an earlier
// oh_base, there is no new write event left to re-assert rows_filled.
// Once the whole frame is resident in row_buf, every remaining oh_base's
// window data is already present.
localparam integer TOTAL_PX = C_IN * H_IN * W_IN;
localparam PXCNT_W = $clog2(TOTAL_PX + 1);
reg [PXCNT_W-1:0] px_cnt;
reg               tensor_loaded;
wire              effective_rows_filled = rows_filled | tensor_loaded;

// ─── FSM ─────────────────────────────────────────────────────────────────────
localparam S_FILL      = 3'd0;
localparam S_COMPUTE   = 3'd1;
localparam S_SERIALIZE = 3'd2;
localparam S_ADVANCE   = 3'd3;

reg [2:0]            state;
reg [HOUT_W-1:0]     oh_base;
reg [WOUT_W-1:0]     col_idx;
reg [GRP_W-1:0]      grp_idx;
reg [P_W-1:0]        ser_idx;
reg [CIN_CTR_W-1:0]  ic_cnt;          // current input channel being accumulated (0..C_IN-1)

reg signed [ACC_W-1:0] acc      [0:P-1];   // running accumulator per filter
reg signed [ACC_W-1:0] mac_result [0:P-1]; // final result, latched after last channel

// FSM tells write block: current row group done, clear rows_filled next clock
wire row_done = (state == S_ADVANCE)
             && (grp_idx == GROUPS - 1)
             && (col_idx == W_OUT  - 1);

// frame_done: the row_done that finishes the LAST output row (oh_base ==
// H_OUT-1). At this point the entire output tensor for this frame has been
// produced, so it is safe to reset the write-side state (px_cnt, wr_*,
// tensor_loaded, row_buf) and accept a new frame.
wire frame_done = row_done && (oh_base == H_OUT - 1);

// ─── need_row: last input row required for current oh_base ───────────────────
wire signed [15:0] need_row_s =
    $signed({2'b0, oh_base}) * STRIDE + (K - 1 - PAD);
// Clamp to the valid row range [0, H_IN-1]. If the ideal "needed" row is
// negative (top padding only) or >= H_IN (bottom padding only), the row
// buffer is complete once the last real input row (H_IN-1) is written.
wire [HIN_W-1:0] need_row =
    (need_row_s[15])            ? {HIN_W{1'b0}}        :  // negative -> row 0
    (need_row_s >= H_IN)        ? (H_IN - 1)            :  // overflow -> last row
                                   need_row_s[HIN_W-1:0];
wire need_immediate = need_row_s[15];

// ─── Window extractor (combinational) — K*K values for channel ic_cnt ────────
wire [DATA_W-1:0] win [0:KK-1];

genvar gi;
generate
    for (gi = 0; gi < KK; gi = gi + 1) begin : WIN_EXTRACT
        localparam integer GI_KY = gi / K;
        localparam integer GI_KX = gi % K;

        wire signed [15:0] ih_s =
            $signed({2'b0, oh_base}) * STRIDE + GI_KY - PAD;
        wire signed [15:0] iw_s =
            $signed({2'b0, col_idx}) * STRIDE + GI_KX - PAD;

        wire ih_valid = (ih_s >= 0) && (ih_s < H_IN);
        wire iw_valid = (iw_s >= 0) && (iw_s < W_IN);

        wire [$clog2(BUF_ROWS)-1:0] slot =
            ih_valid ? (ih_s[HIN_W-1:0] % K) : K;

        wire [$clog2(W_PAD)-1:0] bufcol =
            iw_valid ? (iw_s[WIN_W-1:0] + PAD) : 0;

        assign win[gi] = row_buf[ic_cnt][slot][bufcol];
    end
endgenerate

// ─── P parallel filter units: K*K multipliers + adder tree each ──────────────
wire signed [ACC_W-1:0] partial [0:P-1];   // sum of K*K products for this channel

genvar gf, gw, gl, gn;
generate
    for (gf = 0; gf < P; gf = gf + 1) begin : FILT_UNIT
        wire signed [2*DATA_W-1:0] prod [0:KK-1];
        for (gw = 0; gw < KK; gw = gw + 1) begin : MACS
            assign prod[gw] =
                $signed(filt_mem[((grp_idx * P + gf) * C_IN + ic_cnt) * KK + gw])
              * $signed(win[gw]);
        end

        wire signed [ACC_W-1:0] ext [0:KK-1];
        for (gw = 0; gw < KK; gw = gw + 1) begin : EXTEND
            assign ext[gw] = {{(ACC_W-2*DATA_W){prod[gw][2*DATA_W-1]}}, prod[gw]};
        end

        // Balanced binary adder tree over KK terms (padded to next pow2)
        wire signed [ACC_W-1:0] tree [0:LEVELS][0:PAD_SZ-1];
        for (gn = 0; gn < PAD_SZ; gn = gn + 1) begin : LEAVES
            if (gn < KK) assign tree[0][gn] = ext[gn];
            else         assign tree[0][gn] = {ACC_W{1'b0}};
        end
        for (gl = 1; gl <= LEVELS; gl = gl + 1) begin : TREE_LEVELS
            localparam integer CUR = PAD_SZ >> gl;
            for (gn = 0; gn < CUR; gn = gn + 1) begin : NODES
                assign tree[gl][gn] = tree[gl-1][2*gn] + tree[gl-1][2*gn+1];
            end
            for (gn = CUR; gn < PAD_SZ; gn = gn + 1) begin : UNUSED
                assign tree[gl][gn] = {ACC_W{1'b0}};
            end
        end
        assign partial[gf] = tree[LEVELS][0];
    end
endgenerate

// ─── Output: arithmetic right-shift + saturating clip ────────────────────────
wire signed [ACC_W-1:0]  cur_shifted = mac_result[ser_idx] >>> FRAC_W;

localparam signed [ACC_W-1:0] MAX_VAL =
    {{(ACC_W-DATA_W+1){1'b0}}, {(DATA_W-1){1'b1}}};
localparam signed [ACC_W-1:0] MIN_VAL =
    {{(ACC_W-DATA_W+1){1'b1}}, {(DATA_W-1){1'b0}}};

wire signed [DATA_W-1:0] cur_clipped =
    (cur_shifted > MAX_VAL) ? MAX_VAL[DATA_W-1:0] :
    (cur_shifted < MIN_VAL) ? MIN_VAL[DATA_W-1:0] :
                              cur_shifted[DATA_W-1:0];

assign out_valid = (state == S_SERIALIZE);
assign out_data  = cur_clipped;
assign in_ready  = (state == S_FILL) && !effective_rows_filled;

// =============================================================================
// WRITE BLOCK — sole owner: row_buf, wr_c, wr_r, wr_w, rows_filled
// =============================================================================
integer pi, pj, pk;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_c <= 0; wr_r <= 0; wr_w <= 0;
        rows_filled <= 1'b0;
        px_cnt <= 0;
        tensor_loaded <= 1'b0;
        for (pi = 0; pi < C_IN; pi = pi + 1)
            for (pj = 0; pj < BUF_ROWS; pj = pj + 1)
                for (pk = 0; pk < W_PAD; pk = pk + 1)
                    row_buf[pi][pj][pk] <= {DATA_W{1'b0}};
    end else if (frame_done) begin
        // Last output row of this frame just finished -> re-arm for the
        // next frame. wr_c/wr_r/wr_w are already 0 (no input was accepted
        // while tensor_loaded was 1); px_cnt must be explicitly rewound.
        rows_filled   <= 1'b0;
        tensor_loaded <= 1'b0;
        px_cnt        <= 0;
    end else begin

        if (row_done) begin
            rows_filled <= 1'b0;
        end else begin

            if (in_valid && in_ready) begin
                row_buf[wr_c][wr_r % K][wr_w + PAD] <= in_data;

                if (px_cnt == TOTAL_PX - 1)
                    tensor_loaded <= 1'b1;
                else
                    px_cnt <= px_cnt + 1;

                if (wr_c == C_IN - 1) begin
                    wr_c <= 0;
                    if (wr_w == W_IN - 1) begin
                        wr_w <= 0;
                        if (!rows_filled) begin
                            if (need_immediate || (wr_r == need_row))
                                rows_filled <= 1'b1;
                        end
                        wr_r <= (wr_r == H_IN - 1) ? 0 : wr_r + 1;
                    end else
                        wr_w <= wr_w + 1;
                end else
                    wr_c <= wr_c + 1;
            end

        end
    end
end

// =============================================================================
// FSM BLOCK — sole owner: state, oh_base, col_idx, grp_idx, ser_idx, ic_cnt,
//                          acc[], mac_result[]
// =============================================================================
integer gf2;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state   <= S_FILL;
        oh_base <= 0;
        col_idx <= 0;
        grp_idx <= 0;
        ser_idx <= 0;
        ic_cnt  <= 0;
        for (gf2 = 0; gf2 < P; gf2 = gf2 + 1) begin
            acc[gf2]        <= 0;
            mac_result[gf2] <= 0;
        end
    end else begin
        case (state)

            S_FILL: begin
                if (effective_rows_filled) begin
                    col_idx <= 0;
                    grp_idx <= 0;
                    ser_idx <= 0;
                    ic_cnt  <= 0;
                    for (gf2 = 0; gf2 < P; gf2 = gf2 + 1)
                        acc[gf2] <= 0;
                    state <= S_COMPUTE;
                end
            end

            S_COMPUTE: begin
                for (gf2 = 0; gf2 < P; gf2 = gf2 + 1)
                    acc[gf2] <= acc[gf2] + partial[gf2];

                if (ic_cnt == C_IN - 1) begin
                    ic_cnt <= 0;
                    for (gf2 = 0; gf2 < P; gf2 = gf2 + 1)
                        mac_result[gf2] <= acc[gf2] + partial[gf2];
                    ser_idx <= 0;
                    state   <= S_SERIALIZE;
                end else begin
                    ic_cnt <= ic_cnt + 1;
                end
            end

            S_SERIALIZE: begin
                if (out_valid && out_ready) begin
                    if (ser_idx == P - 1) begin
                        ser_idx <= 0;
                        state   <= S_ADVANCE;
                    end else
                        ser_idx <= ser_idx + 1;
                end
            end

            S_ADVANCE: begin
                if (grp_idx == GROUPS - 1) begin
                    grp_idx <= 0;
                    if (col_idx == W_OUT - 1) begin
                        col_idx <= 0;
                        oh_base <= (oh_base == H_OUT-1) ? 0 : oh_base + 1;
                        state   <= S_FILL;
                    end else begin
                        col_idx <= col_idx + 1;
                        ic_cnt  <= 0;
                        for (gf2 = 0; gf2 < P; gf2 = gf2 + 1)
                            acc[gf2] <= 0;
                        state   <= S_COMPUTE;
                    end
                end else begin
                    grp_idx <= grp_idx + 1;
                    ic_cnt  <= 0;
                    for (gf2 = 0; gf2 < P; gf2 = gf2 + 1)
                        acc[gf2] <= 0;
                    state   <= S_COMPUTE;
                end
            end

            default: state <= S_FILL;
        endcase
    end
end


endmodule