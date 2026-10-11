`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ccsds123_coder: CCSDS 123.0-B-2 sample-adaptive entropy coder (5.4.3.2),
// band-interleaved order.
//
//   in : mapped residuals delta(t, z) with band index and t = 0 / t = 1 flags
//   out: variable-length codewords as (value, length); the codeword is the
//        `len` low bits of `code`, sent MSB first. Leading zeros of the unary
//        part are implied by len.
//
// Per band an accumulator Sigma(z) is kept in a small RAM; the counter Gamma
// is shared by all bands and advances once per pixel. Codewords:
//   t = 0          : delta in D bits
//   u = delta >> k : u < U_max -> u zeros, a one, the k low bits of delta
//                    otherwise -> U_max zeros, delta in D bits
//
// Pipeline (ce = !m_valid || m_ready):
//   C0 accept, Gamma update, Sigma RAM read
//   C1 Sigma select (init / forwarded / RAM), threshold, Sigma write back
//   C2 k from D-2 parallel compares
//   C3 codeword
//
// Pipeline registers carry shreg_extract = "no": the flight build bans SRLs,
// whose contents configuration scrubbing cannot repair.
// -----------------------------------------------------------------------------
module ccsds123_coder #(
    parameter int NZ     = 16,
    parameter int D      = 16,
    parameter int UMAX   = 18,
    parameter int GSTAR  = 6,      // rescaling counter size gamma*
    parameter int GAMMA0 = 1,      // initial count exponent gamma_0
    parameter int KINIT  = 3,      // accumulator initialisation constant K
    parameter bit ECC    = 1'b0,   // SECDED on the accumulator RAM
    parameter bit TMR    = 1'b0,   // triplicated counter Gamma
    parameter int ZW     = (NZ > 1) ? $clog2(NZ) : 1,
    parameter int CW     = (D > 8) ? D : 8,    // code value width
    parameter int LW     = 6                   // code length width (max U_max + D = 48)
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [D-1:0]  s_delta,
    input  logic [ZW-1:0] s_z,
    input  logic          s_t0,
    input  logic          s_t1,
    input  logic          s_last,
    input  logic          s_valid,
    output logic          s_ready,

    output logic [CW-1:0] m_code,
    output logic [LW-1:0] m_len,
    output logic          m_first,     // first codeword of an image
    output logic          m_last,      // last codeword of an image
    output logic          m_valid,
    input  logic          m_ready,

    input  logic          inj_sbe,
    input  logic          inj_dbe,
    input  logic          inj_tmr,
    output logic          ecc_sbe,
    output logic          ecc_dbe,
    output logic          tmr_err
);
    localparam int GW = GSTAR;                    // Gamma < 2^gamma*
    localparam int AW = D + GSTAR + 2;            // Sigma < 2^(D + 1 + gamma*)
    localparam int KW = 4;                        // k <= D - 2 <= 14
    localparam int GMAX   = (1 << GSTAR) - 1;
    localparam int GAMMA1 = 1 << GAMMA0;
    localparam int K1     = (KINIT <= 30 - D) ? KINIT : 2 * KINIT + D - 30;
    localparam int SIGMA1 = ((3 * (1 << (K1 + 6)) - 49) * GAMMA1) >>> 7;   // < 2^30

`ifndef SYNTHESIS
    initial begin
        if (UMAX < 8 || UMAX > 32) $fatal(1, "ccsds123_coder: U_max must be 8..32");
        if (GAMMA0 < 1 || GAMMA0 > 8 || GSTAR > 11 || GSTAR < GAMMA0 + 1 || GSTAR < 4)
            $fatal(1, "ccsds123_coder: bad gamma_0 / gamma*");
        if (KINIT > D - 2 || KINIT > 14) $fatal(1, "ccsds123_coder: K must be <= min(D-2, 14)");
        if (AW < 31 && SIGMA1 >= (1 << AW)) $fatal(1, "ccsds123_coder: Sigma width too small");
    end
`endif

    logic ce, accept;
    assign ce      = !m_valid || m_ready;
    assign s_ready = ce;
    assign accept  = s_valid && s_ready;

    // ------------------------------------------------- C0: Gamma, RAM read
    logic [GW-1:0] gamma, gamma_nx;
    always_comb begin
        gamma_nx = gamma;
        if (s_z == '0) begin
            if (s_t1)       gamma_nx = GW'(GAMMA1);
            else if (!s_t0) gamma_nx = (gamma == GW'(GMAX)) ? GW'(({1'b0, gamma} + 1'b1) >> 1) : gamma + 1'b1;
        end
    end
    tmr_reg #(.W(GW), .TMR(TMR), .RST_VAL(GW'(GAMMA1))) u_gamma (
        .clk, .rst, .en (accept), .d (gamma_nx), .q (gamma),
        .inj ({GW{inj_tmr}}), .mismatch (tmr_err)
    );

    (* shreg_extract = "no" *) logic           v1, v2, v3;
    (* shreg_extract = "no" *) logic [D-1:0]   d1, d2;
    (* shreg_extract = "no" *) logic [ZW-1:0]  z1;
    (* shreg_extract = "no" *) logic           t0_1, t1_1, last1, first1, t0_2, last2, first2;
    (* shreg_extract = "no" *) logic [GW-1:0]  g1;
    logic [AW-1:0]  acc_rd, acc_wd, fwd_val;
    (* shreg_extract = "no" *) logic           fwd1;
    logic           acc_we;

    logic acc_sbe, acc_dbe;
    ecc_sdp_ram #(.DW(AW), .DEPTH(NZ), .RAM_STYLE("auto"), .ECC(ECC)) u_acc (
        .clk, .we (acc_we), .waddr (z1), .wdata (acc_wd),
        .inj_sbe (inj_sbe && acc_we), .inj_dbe (inj_dbe && acc_we),
        .re (ce), .raddr (s_z), .rdata (acc_rd), .sbe (acc_sbe), .dbe (acc_dbe)
    );
    assign ecc_sbe = ce && v1 && acc_sbe;
    assign ecc_dbe = ce && v1 && acc_dbe;

    always_ff @(posedge clk) begin
        if (rst) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
        end else if (ce) begin
            v1 <= accept; v2 <= v1; v3 <= v2;
        end
    end
    assign m_valid = v3;

    always_ff @(posedge clk) begin
        if (ce) begin
            d1     <= s_delta;
            z1     <= s_z;
            t0_1   <= s_t0;
            t1_1   <= s_t1;
            last1  <= s_last;
            first1 <= s_t0 && (s_z == '0);
            g1     <= gamma_nx;
            // the sample in C1 writes this band now; the RAM read misses it
            fwd1    <= v1 && !t0_1 && (z1 == s_z);
            fwd_val <= acc_wd;
        end
    end

    // ------------------------------------------- C1: Sigma, threshold, update
    logic [AW-1:0] acc_cur;
    logic [AW:0]   acc_sum, thr_c;
    assign acc_cur = t1_1 ? AW'(SIGMA1) : fwd1 ? fwd_val : acc_rd;
    assign acc_sum = {1'b0, acc_cur} + (AW+1)'(d1);
    assign acc_wd  = (g1 == GW'(GMAX)) ? AW'((acc_sum + 1'b1) >> 1) : AW'(acc_sum);
    assign acc_we  = ce && v1 && !t0_1;
    assign thr_c   = {1'b0, acc_cur} + (AW+1)'(({6'd0, g1} * (GW+6)'(49)) >> 7);

    (* shreg_extract = "no" *) logic [AW:0]   thr2;
    (* shreg_extract = "no" *) logic [GW-1:0] g2;
    always_ff @(posedge clk) begin
        if (ce) begin
            d2 <= d1; t0_2 <= t0_1; last2 <= last1; first2 <= first1;
            thr2 <= thr_c; g2 <= g1;
        end
    end

    // ------------------------------------------------------ C2: k, C3: code
    // k = largest k <= D-2 with Gamma * 2^k <= threshold (0 if none); the
    // compares are monotone in j, so k is the number that hold
    logic [KW-1:0] k_c;
    always_comb begin
        k_c = '0;
        for (int j = 1; j <= D - 2; j++)
            if (((AW+1+16)'(g2) << j) <= (AW+1+16)'(thr2)) k_c = k_c + 1'b1;
    end

    (* shreg_extract = "no" *) logic [D-1:0]  d3;
    (* shreg_extract = "no" *) logic [KW-1:0] k3;
    logic          t0_3;
    always_ff @(posedge clk) begin
        if (ce) begin
            d3 <= d2; k3 <= k_c; t0_3 <= t0_2; m_last <= last2; m_first <= first2;
        end
    end

    logic [D-1:0] u_c;
    assign u_c = d3 >> k3;
    always_comb begin
        if (t0_3) begin
            m_code = CW'(d3);
            m_len  = LW'(D);
        end else if (32'(u_c) < UMAX) begin
            m_code = CW'((D+1)'(1) << k3) | CW'(d3 & ((D'(1) << k3) - 1'b1));
            m_len  = LW'(u_c) + LW'(k3) + 1'b1;
        end else begin
            m_code = CW'(d3);
            m_len  = LW'(UMAX + D);
        end
    end
endmodule
