`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ccsds123_predictor: CCSDS 123.0-B-2 adaptive linear predictor and mapper,
// lossless mode, band-interleaved-by-pixel (BIP) sample order.
//
//   in : samples s(x,y,z), D bits, BIP order, tuser = first sample of the
//        image, tlast = last sample of each line
//   out: mapped prediction residuals delta(x,y,z) in the same order, with the
//        band index and t = 0 / t = 1 flags the entropy coder needs
//
// Supports full and reduced prediction, P = 0..15 previous bands, wide
// neighbour-oriented (LOCAL_SUM = 0) and wide column-oriented (LOCAL_SUM = 2)
// local sums, default weight initialisation and zero weight exponent offsets.
// Bit-exact with model/ccsds123.py, which matches the NTNU reference model.
//
// Throughput is one sample per clock. BIP order makes this possible: a band's
// weights are next needed NZ samples later, so the weight update has NZ clocks
// to complete. If NZ < 9 (NZ < 10 with ECC = 1) the input stalls until the
// previous sample of the same band has written its weights back.
//
// Pipeline (all stages advance together on ce = !m_valid || m_ready):
//   A  accept; line buffer read (N, NE), band state read (W, NW)
//   P0 ECC = 1 only: SECDED decode of the memory reads, registered, so the
//      decoder is not in series with the local sums or the multipliers;
//      the weight read is issued here instead of in P1
//   P1 local sum, central and directional local differences
//   P2 weight read data; local difference vector U
//   P3 products W_i * U_i      P4 partial sums      P5 predicted central diff
//   P6 mod-R scaled value      P7 double-resolution prediction s~
//   P8 mapped residual delta, prediction error sign
//   P9 weight update term; weights written back as the sample leaves P9
//
// Pipeline registers carry shreg_extract = "no": the flight build bans SRLs,
// whose contents configuration scrubbing cannot repair.
// -----------------------------------------------------------------------------
module ccsds123_predictor #(
    parameter int NX        = 64,
    parameter int NY        = 64,
    parameter int NZ        = 16,
    parameter int D         = 16,
    parameter int P         = 3,
    parameter bit FULL      = 1'b1,
    parameter int LOCAL_SUM = 0,       // 0 = wide neighbour, 2 = wide column
    parameter int OMEGA     = 13,
    parameter int R         = 64,
    parameter int VMIN      = -1,
    parameter int VMAX      = 3,
    parameter int TINC_LOG2 = 6,
    parameter     LB_RAM_STYLE = "block",
    parameter bit ECC       = 1'b0,    // SECDED on line buffer, band state and weights
    parameter bit TMR       = 1'b0,    // triplicated position counters
    parameter int ZW        = (NZ > 1) ? $clog2(NZ) : 1
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [D-1:0]  s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,
    input  logic          s_axis_tuser,
    input  logic          s_axis_tlast,

    output logic [D-1:0]  m_delta,
    output logic [ZW-1:0] m_z,
    output logic          m_t0,        // first pixel of the image
    output logic          m_t1,        // second pixel of the image
    output logic          m_last,      // last sample of the image
    output logic          m_valid,
    input  logic          m_ready,

    output logic          framing_err,

    // reliability: error injection (tie to 0 in normal use) and error pulses
    input  logic          inj_sbe,
    input  logic          inj_dbe,
    input  logic          inj_tmr,
    output logic          ecc_sbe,
    output logic          ecc_dbe,
    output logic          tmr_err
);
    // ------------------------------------------------------------ constants
    localparam int CZ   = P + (FULL ? 3 : 0);      // local difference vector length
    localparam int CZE  = (CZ > 0) ? CZ : 1;       // array size (CZ = 0 -> one zero entry)
    localparam int OFS  = FULL ? 3 : 0;            // index of the first spectral component
    localparam int UW   = D + 3;                   // local difference width (signed)
    localparam int WW   = OMEGA + 3;               // weight width (signed)
    localparam int PRW  = UW + WW;                 // product width
    localparam int NG   = (CZE + 3) / 4;           // partial-sum groups of 4
    localparam int DHW  = PRW + 5;                 // predicted central difference width
    localparam int XW   = ((DHW > D + OMEGA + 3) ? DHW : D + OMEGA + 3) + 1;
    localparam int SW   = ((XW > R) ? XW : R) + 3; // scaled value working width
    localparam int XIW  = (NX > 1) ? $clog2(NX) : 1;
    localparam int YIW  = (NY > 1) ? $clog2(NY) : 1;
    localparam int LIW  = (NX * NZ > 1) ? $clog2(NX * NZ) : 1;
    localparam int TW   = 32;
    localparam int RHO_MIN = VMIN + D - OMEGA;
    localparam int LSH  = (RHO_MIN < 0) ? -RHO_MIN : 0;   // largest left shift
    localparam int TRW  = UW + LSH + 2;                   // weight update term width
    localparam logic signed [63:0] SMID = 64'sd1 <<< (D - 1);
    localparam logic signed [63:0] SMAX = (64'sd1 <<< D) - 1;

`ifndef SYNTHESIS
    initial begin
        if (D < 2 || D > 16) $fatal(1, "ccsds123_predictor: D must be 2..16");
        if (P > 15) $fatal(1, "ccsds123_predictor: P must be 0..15");
        if (LOCAL_SUM != 0 && LOCAL_SUM != 2) $fatal(1, "ccsds123_predictor: LOCAL_SUM must be 0 or 2");
        if (R < 32 || R > 64 || R < D + OMEGA + 2) $fatal(1, "ccsds123_predictor: bad R");
        if (NX == 1 && (FULL || LOCAL_SUM != 2)) $fatal(1, "ccsds123_predictor: NX = 1 needs reduced mode and column sums");
    end
`endif


    // ------------------------------------------------------------ handshake
    logic ce, hazard, accept;
    assign ce            = !m_valid || m_ready;
    assign s_axis_tready = ce && !hazard;
    assign accept        = s_axis_tvalid && s_axis_tready;

    // ------------------------------------------------------------- counters
    logic [XIW-1:0] x, cur_x;
    logic [YIW-1:0] y, cur_y;
    logic [ZW-1:0]  z, cur_z;
    logic [LIW-1:0] li, cur_li;   // sample index within the line
    logic [TW-1:0]  t, cur_t;
    logic           cur_xl, cur_eol, cur_last;

    assign cur_x    = s_axis_tuser ? '0 : x;
    assign cur_y    = s_axis_tuser ? '0 : y;
    assign cur_z    = s_axis_tuser ? '0 : z;
    assign cur_li   = s_axis_tuser ? '0 : li;
    assign cur_t    = s_axis_tuser ? '0 : t;
    assign cur_xl   = (cur_x == XIW'(NX - 1));
    assign cur_eol  = cur_xl && (cur_z == ZW'(NZ - 1));
    assign cur_last = cur_eol && (cur_y == YIW'(NY - 1));

    // Position counters. An upset here would misplace every later sample of
    // the image, so with TMR = 1 they are triplicated and voted.
    localparam int CNTW = XIW + YIW + ZW + LIW + TW;
    logic [XIW-1:0] x_nx;
    logic [YIW-1:0] y_nx;
    logic [ZW-1:0]  z_nx;
    logic [LIW-1:0] li_nx;
    logic [TW-1:0]  t_nx;

    always_comb begin
        x_nx = cur_x; y_nx = cur_y; t_nx = cur_t;
        if (cur_z == ZW'(NZ - 1)) begin
            z_nx = '0;
            if (cur_xl) begin
                x_nx  = '0;
                li_nx = '0;
                y_nx  = cur_last ? '0 : cur_y + 1'b1;
                t_nx  = cur_last ? '0 : cur_t + 1'b1;
            end else begin
                x_nx  = cur_x + 1'b1;
                li_nx = cur_li + 1'b1;
                t_nx  = cur_t + 1'b1;
            end
        end else begin
            z_nx  = cur_z + 1'b1;
            li_nx = cur_li + 1'b1;
        end
    end

    tmr_reg #(.W(CNTW), .TMR(TMR)) u_cnt (
        .clk, .rst, .en (accept),
        .d ({x_nx, y_nx, z_nx, li_nx, t_nx}), .q ({x, y, z, li, t}),
        .inj ({CNTW{inj_tmr}}), .mismatch (tmr_err)
    );

    always_ff @(posedge clk) begin
        if (rst) framing_err <= 1'b0;
        else     framing_err <= accept && (s_axis_tlast != cur_eol);
    end

    // weight update scaling exponent rho(t), registered per sample
    function automatic signed [7:0] rho_of(input [TW-1:0] tt);
        reg [TW-1:0] q;
        integer      v;
        begin
            q = (tt - TW'(NX)) >> TINC_LOG2;
            if (tt < TW'(NX))                v = VMIN;
            else if (q > TW'(VMAX - VMIN))   v = VMAX;
            else                             v = VMIN + q;
            rho_of = 8'(v + D - OMEGA);
        end
    endfunction

    // ----------------------------------------------------- stage registers
    (* shreg_extract = "no" *) logic           v1, v2, v3, v4, v5, v6, v7, v8, v9;
    (* shreg_extract = "no" *) logic [ZW-1:0]  z1, z2, z3, z4, z5, z6, z7, z8, z9;
    logic          v0;              // P0 (ECC = 1 only; 0 otherwise)
    logic [ZW-1:0] z0;

    // Hazard: the incoming band must not be in P0..P8. Its band state is
    // written from P1, and its weights are written as it leaves P9 and read
    // in P1 (P0 with ECC = 1), one clock after it was accepted, so a sample in
    // P9 has already written them by the time a new sample of the same band
    // issues its weight read.
    always_comb begin
        hazard = 1'b0;
        if (v0 && z0 == cur_z) hazard = 1'b1;
        if (v1 && z1 == cur_z) hazard = 1'b1;
        if (v2 && z2 == cur_z) hazard = 1'b1;
        if (v3 && z3 == cur_z) hazard = 1'b1;
        if (v4 && z4 == cur_z) hazard = 1'b1;
        if (v5 && z5 == cur_z) hazard = 1'b1;
        if (v6 && z6 == cur_z) hazard = 1'b1;
        if (v7 && z7 == cur_z) hazard = 1'b1;
        if (v8 && z8 == cur_z) hazard = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            {v1, v2, v3, v4, v5, v6, v7, v8, v9} <= '0;
        end else if (ce) begin
            v1 <= v_p; v2 <= v1; v3 <= v2; v4 <= v3; v5 <= v4;
            v6 <= v5; v7 <= v6; v8 <= v7; v9 <= v8;
        end
    end
    assign m_valid = v9;

    // ------------------------------------------- A: memories and stage P1
    (* shreg_extract = "no" *) logic [D-1:0]   s1, sp1, s_prev;
    (* shreg_extract = "no" *) logic           x0_1, xl_1, y0_1, t0_1, t1_1, last1;
    (* shreg_extract = "no" *) logic signed [7:0] rho1;
    logic [D-1:0]   n_q, ne_q;
    logic [2*D-1:0] bs_q;            // {W, NW} of this band at the previous pixel

    // per-sample fields set at accept: {s, s_prev, z, x0, xl, y0, t0, t1, last, rho}
    localparam int SBW = 2 * D + ZW + 6 + 8;
    logic [SBW-1:0] side_a, side_p;  // at accept / entering P1
    logic           v_p;             // valid entering P1
    assign side_a = {s_axis_tdata, s_prev, cur_z, cur_x == '0, cur_xl, cur_y == '0,
                     cur_t == '0, cur_t == TW'(1), cur_last, rho_of(cur_t)};

    generate
        if (ECC) begin : g_p0
            (* shreg_extract = "no" *) logic [SBW-1:0] side0;
            (* shreg_extract = "no" *) logic           v0_q;
            always_ff @(posedge clk) begin
                if (rst)     v0_q <= 1'b0;
                else if (ce) v0_q <= accept;
            end
            always_ff @(posedge clk) if (ce) side0 <= side_a;
            assign v0     = v0_q;
            assign z0     = side0[SBW-2*D-1 -: ZW];
            assign v_p    = v0_q;
            assign side_p = side0;
        end else begin : g_no_p0
            assign v0     = 1'b0;
            assign z0     = '0;
            assign v_p    = accept;
            assign side_p = side_a;
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (ce) {s1, sp1, z1, x0_1, xl_1, y0_1, t0_1, t1_1, last1, rho1} <= side_p;
        if (accept) s_prev <= s_axis_tdata;
    end

    // line buffer: port A reads N = s(x, y-1, z) and stores s(x, y, z);
    // port B reads NE = s(x+1, y-1, z)
    logic [LIW-1:0] ne_addr;
    assign ne_addr = cur_xl ? '0 : LIW'(cur_li + LIW'(NZ));

    logic lb_sbe, lb_dbe, bs_sbe, bs_dbe, wt_sbe, wt_dbe;
    logic [D-1:0]   n_m, ne_m;       // memory outputs (decoded)
    logic [2*D-1:0] bs_m;
    logic           lb_sbe_m, lb_dbe_m, bs_sbe_m, bs_dbe_m;

    ecc_lb_ram_rf #(.DW(D), .DEPTH(NX * NZ), .RAM_STYLE(LB_RAM_STYLE), .ECC(ECC)) u_lb (
        .clk,
        .a_en (ce), .a_we (accept), .a_addr (cur_li), .a_wdata (s_axis_tdata), .a_rdata (n_m),
        .b_en (ce), .b_addr (ne_addr), .b_rdata (ne_m),
        .inj_sbe (inj_sbe && accept), .inj_dbe (inj_dbe && accept), .sbe (lb_sbe_m), .dbe (lb_dbe_m)
    );

    // band state: {s, N} of this pixel become {W, NW} of the next one
    ecc_sdp_ram #(.DW(2 * D), .DEPTH(NZ), .RAM_STYLE("auto"), .ECC(ECC)) u_bs (
        .clk, .we (ce && v1), .waddr (z1), .wdata ({s1, n_q}),
        .inj_sbe (inj_sbe && ce && v1), .inj_dbe (inj_dbe && ce && v1),
        .re (ce), .raddr (cur_z), .rdata (bs_m), .sbe (bs_sbe_m), .dbe (bs_dbe_m)
    );

    // P0 -> P1: with ECC = 1 the decoded reads are registered
    generate
        if (ECC) begin : g_rd_reg
            always_ff @(posedge clk) begin
                if (ce) begin
                    n_q <= n_m; ne_q <= ne_m; bs_q <= bs_m;
                    lb_sbe <= lb_sbe_m; lb_dbe <= lb_dbe_m; bs_sbe <= bs_sbe_m; bs_dbe <= bs_dbe_m;
                end
            end
        end else begin : g_rd_comb
            assign n_q = n_m; assign ne_q = ne_m; assign bs_q = bs_m;
            assign lb_sbe = lb_sbe_m; assign lb_dbe = lb_dbe_m;
            assign bs_sbe = bs_sbe_m; assign bs_dbe = bs_dbe_m;
        end
    endgenerate

    // ---------------------------------------------------------- P1 -> P2
    logic [D-1:0] w_q, nw_q;
    assign w_q  = bs_q[2*D-1:D];
    assign nw_q = bs_q[D-1:0];

    logic [D+1:0] sigma_c;
    always_comb begin
        if (LOCAL_SUM == 2) begin
            sigma_c = y0_1 ? {w_q, 2'b00} : {n_q, 2'b00};
        end else if (y0_1) begin
            sigma_c = {w_q, 2'b00};
        end else if (x0_1) begin
            sigma_c = ({2'b00, n_q} + {2'b00, ne_q}) << 1;
        end else if (xl_1) begin
            sigma_c = {2'b00, w_q} + {2'b00, nw_q} + ({2'b00, n_q} << 1);
        end else begin
            sigma_c = {2'b00, w_q} + {2'b00, nw_q} + {2'b00, n_q} + {2'b00, ne_q};
        end
    end

    function automatic signed [UW-1:0] ldiff(input [D-1:0] a, input [D+1:0] sg);
        ldiff = $signed({1'b0, a, 2'b00}) - $signed({1'b0, sg});
    endfunction

    (* shreg_extract = "no" *) logic [D-1:0]       s2, sp2;
    (* shreg_extract = "no" *) logic               t0_2, t1_2, last2;
    (* shreg_extract = "no" *) logic signed [7:0]  rho2;
    (* shreg_extract = "no" *) logic [D+1:0]       sigma2;
    (* shreg_extract = "no" *) logic signed [UW-1:0] dc2, dn2, dw2, dnw2;

    always_ff @(posedge clk) begin
        if (ce) begin
            s2 <= s1; sp2 <= sp1; z2 <= z1; t0_2 <= t0_1; t1_2 <= t1_1; last2 <= last1; rho2 <= rho1;
            sigma2 <= sigma_c;
            dc2    <= ldiff(s1, sigma_c);
            if (y0_1) begin
                dn2 <= '0; dw2 <= '0; dnw2 <= '0;
            end else begin
                dn2  <= ldiff(n_q, sigma_c);
                dw2  <= x0_1 ? ldiff(n_q, sigma_c) : ldiff(w_q, sigma_c);
                dnw2 <= x0_1 ? ldiff(n_q, sigma_c) : ldiff(nw_q, sigma_c);
            end
        end
    end

    // weight memory (one word = all CZ weights of a band)
    logic [CZE*WW-1:0] w_rdata, w_wdata, w_m;
    logic              w_we, wt_sbe_m, wt_dbe_m;

    // one SECDED slice per weight, so each weight can lose a bit independently;
    // with ECC = 1 the read is issued from P0 and the decoded word registered
    ecc_sdp_ram #(.DW(CZE * WW), .DEPTH(NZ), .RAM_STYLE("auto"), .ECC(ECC), .SLICE(WW)) u_weights (
        .clk, .we (w_we), .waddr (z9), .wdata (w_wdata),
        .inj_sbe (inj_sbe && w_we), .inj_dbe (inj_dbe && w_we),
        .re (ce), .raddr (ECC ? z0 : z1), .rdata (w_m), .sbe (wt_sbe_m), .dbe (wt_dbe_m)
    );

    generate
        if (ECC) begin : g_w_reg
            always_ff @(posedge clk) begin
                if (ce) begin w_rdata <= w_m; wt_sbe <= wt_sbe_m; wt_dbe <= wt_dbe_m; end
            end
        end else begin : g_w_comb
            assign w_rdata = w_m; assign wt_sbe = wt_sbe_m; assign wt_dbe = wt_dbe_m;
        end
    endgenerate

    // count each read once, when the sample that uses it moves on
    assign ecc_sbe = ce && ((v1 && (lb_sbe || bs_sbe)) || (v2 && wt_sbe));
    assign ecc_dbe = ce && ((v1 && (lb_dbe || bs_dbe)) || (v2 && wt_dbe));

    // ---------------------------------------------------------- P2 -> P3
    // central differences of the previous bands of this pixel (newest first)
    logic signed [UW-1:0] dsr [0:15];
    always_ff @(posedge clk) begin
        if (ce && v2) begin
            dsr[0] <= dc2;
            for (int i = 1; i < 16; i++) dsr[i] <= dsr[i-1];
        end
    end

    logic signed [UW-1:0] u_c [0:CZE-1];
    logic signed [WW-1:0] w_c [0:CZE-1];
    always_comb begin
        for (int i = 0; i < CZE; i++) begin
            u_c[i] = '0;
            // default initial weights (4.6.3.2): 7/8 * 2^Omega for the nearest
            // band, each further band 1/8 of the previous one
            if (!t1_2)                 w_c[i] = $signed(w_rdata[i*WW +: WW]);
            else if (i < OFS || P == 0) w_c[i] = '0;
            else                       w_c[i] = WW'((64'sd7 <<< OMEGA) >>> (3 * (i - OFS) + 3));
        end
        if (FULL) begin
            u_c[0] = dn2; u_c[1] = dw2; u_c[2] = dnw2;
        end
        for (int i = 0; i < P; i++)
            if (32'(z2) > i) u_c[OFS + i] = dsr[i];
        if (CZ == 0) w_c[0] = '0;
    end

    (* shreg_extract = "no" *) logic [D-1:0]          s3, sp3;
    (* shreg_extract = "no" *) logic                  t0_3, t1_3, last3;
    (* shreg_extract = "no" *) logic signed [7:0]     rho3;
    (* shreg_extract = "no" *) logic [D+1:0]          sigma3;
    (* shreg_extract = "no" *) logic signed [UW-1:0]  u3 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [WW-1:0]  w3 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [PRW-1:0] prod3 [0:CZE-1];

    always_ff @(posedge clk) begin
        if (ce) begin
            s3 <= s2; sp3 <= sp2; z3 <= z2; t0_3 <= t0_2; t1_3 <= t1_2; last3 <= last2; rho3 <= rho2;
            sigma3 <= sigma2;
            for (int i = 0; i < CZE; i++) begin
                u3[i]    <= u_c[i];
                w3[i]    <= w_c[i];
                prod3[i] <= PRW'(u_c[i]) * PRW'(w_c[i]);
            end
        end
    end

    // ------------------------------------------------- P3 -> P4 -> P5
    (* shreg_extract = "no" *) logic [D-1:0]          s4, sp4, s5, sp5;
    (* shreg_extract = "no" *) logic                  t0_4, t1_4, last4, t0_5, t1_5, last5;
    (* shreg_extract = "no" *) logic signed [7:0]     rho4, rho5;
    (* shreg_extract = "no" *) logic [D+1:0]          sigma4, sigma5;
    (* shreg_extract = "no" *) logic signed [UW-1:0]  u4 [0:CZE-1], u5 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [WW-1:0]  w4 [0:CZE-1], w5 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [DHW-1:0] gs4 [0:NG-1];
    (* shreg_extract = "no" *) logic signed [DHW-1:0] dhat5;
    logic signed [DHW-1:0] gs_c [0:NG-1];
    logic signed [DHW-1:0] dhat_c;

    always_comb begin
        for (int g = 0; g < NG; g++) begin
            gs_c[g] = '0;
            for (int j = 0; j < 4; j++)
                if (4 * g + j < CZE) gs_c[g] = gs_c[g] + DHW'(prod3[4*g+j]);
        end
        dhat_c = '0;
        for (int g = 0; g < NG; g++) dhat_c = dhat_c + gs4[g];
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            s4 <= s3; sp4 <= sp3; z4 <= z3; t0_4 <= t0_3; t1_4 <= t1_3; last4 <= last3; rho4 <= rho3;
            sigma4 <= sigma3;
            for (int i = 0; i < CZE; i++) begin u4[i] <= u3[i]; w4[i] <= w3[i]; end
            for (int g = 0; g < NG; g++) gs4[g] <= gs_c[g];

            s5 <= s4; sp5 <= sp4; z5 <= z4; t0_5 <= t0_4; t1_5 <= t1_4; last5 <= last4; rho5 <= rho4;
            sigma5 <= sigma4;
            for (int i = 0; i < CZE; i++) begin u5[i] <= u4[i]; w5[i] <= w4[i]; end
            dhat5 <= dhat_c;
        end
    end

    // ---------------------------------------------------------- P5 -> P6
    // X = mod_R( dhat + 2^Omega * (sigma - 4 * s_mid) )
    logic signed [XW-1:0] x_sig, x_sum;
    logic signed [SW-1:0] x_mod;
    assign x_sig = XW'($signed({1'b0, sigma5})) - XW'(4 * SMID);
    assign x_sum = XW'(dhat5) + (x_sig <<< OMEGA);
    generate
        if (R < XW) begin : g_modr
            assign x_mod = SW'($signed(x_sum[R-1:0]));
        end else begin : g_nomod
            assign x_mod = SW'(x_sum);
        end
    endgenerate

    (* shreg_extract = "no" *) logic [D-1:0]          s6, sp6;
    (* shreg_extract = "no" *) logic                  t0_6, t1_6, last6;
    (* shreg_extract = "no" *) logic signed [7:0]     rho6;
    (* shreg_extract = "no" *) logic signed [UW-1:0]  u6 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [WW-1:0]  w6 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [SW-1:0]  x6;

    always_ff @(posedge clk) begin
        if (ce) begin
            s6 <= s5; sp6 <= sp5; z6 <= z5; t0_6 <= t0_5; t1_6 <= t1_5; last6 <= last5; rho6 <= rho5;
            for (int i = 0; i < CZE; i++) begin u6[i] <= u5[i]; w6[i] <= w5[i]; end
            x6 <= x_mod;
        end
    end

    // ---------------------------------------------------------- P6 -> P7
    // s_breve = clip(X + 2^(Omega+2) s_mid + 2^(Omega+1), 0, 2^(Omega+2) s_max + 2^(Omega+1))
    // s~ = s_breve >> (Omega + 1);  at t = 0: 2 s(z-1) if P > 0 and z > 0, else 2 s_mid
    localparam logic signed [63:0] SB_OFS_L = (SMID <<< (OMEGA + 2)) + (64'sd1 <<< (OMEGA + 1));
    localparam logic signed [63:0] SB_HI_L  = (SMAX <<< (OMEGA + 2)) + (64'sd1 <<< (OMEGA + 1));
    localparam logic signed [SW-1:0] SB_OFS = SW'(SB_OFS_L);
    localparam logic signed [SW-1:0] SB_HI  = SW'(SB_HI_L);
    logic signed [SW-1:0] sb_raw, sb_clip;
    assign sb_raw  = x6 + SB_OFS;
    assign sb_clip = (sb_raw < 0) ? '0 : (sb_raw > SB_HI) ? SB_HI : sb_raw;

    (* shreg_extract = "no" *) logic [D-1:0]          s7;
    (* shreg_extract = "no" *) logic                  t0_7, t1_7, last7;
    (* shreg_extract = "no" *) logic signed [7:0]     rho7;
    (* shreg_extract = "no" *) logic signed [UW-1:0]  u7 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [WW-1:0]  w7 [0:CZE-1];
    (* shreg_extract = "no" *) logic [D:0]            st7;      // s~ (double-resolution predicted sample)

    always_ff @(posedge clk) begin
        if (ce) begin
            s7 <= s6; z7 <= z6; t0_7 <= t0_6; t1_7 <= t1_6; last7 <= last6; rho7 <= rho6;
            for (int i = 0; i < CZE; i++) begin u7[i] <= u6[i]; w7[i] <= w6[i]; end
            if (t0_6)
                st7 <= (P > 0 && z6 != '0) ? {sp6, 1'b0} : (D+1)'(2 * SMID);
            else
                st7 <= (D+1)'(sb_clip >>> (OMEGA + 1));
        end
    end

    // ---------------------------------------------------------- P7 -> P8
    logic [D-1:0]        shat;
    logic signed [D+1:0] dlt;
    logic [D:0]          adlt;
    logic [D-1:0]        theta;
    logic [D-1:0]        delta_c;   // delta <= s_max always fits in D bits
    logic                pos_side;

    assign shat  = st7[D:1];
    assign dlt   = $signed({2'b00, s7}) - $signed({2'b00, shat});
    assign adlt  = dlt[D+1] ? (D+1)'(-dlt) : (D+1)'(dlt);
    assign theta = (shat < D'(SMAX) - shat) ? shat : D'(SMAX) - shat;
    // (-1)^s~ * Delta >= 0  <=>  (s~ even and Delta >= 0) or (s~ odd and Delta <= 0)
    assign pos_side = st7[0] ? (dlt <= 0) : (dlt >= 0);
    always_comb begin
        if (adlt > {1'b0, theta}) delta_c = D'(adlt + {1'b0, theta});
        else                      delta_c = pos_side ? D'(adlt << 1) : D'((adlt << 1) - 1'b1);
    end

    (* shreg_extract = "no" *) logic [D-1:0]          delta8;
    (* shreg_extract = "no" *) logic                  t0_8, t1_8, last8, eneg8;
    (* shreg_extract = "no" *) logic signed [7:0]     rho8;
    (* shreg_extract = "no" *) logic signed [UW-1:0]  u8 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [WW-1:0]  w8 [0:CZE-1];

    always_ff @(posedge clk) begin
        if (ce) begin
            z8 <= z7; t0_8 <= t0_7; t1_8 <= t1_7; last8 <= last7; rho8 <= rho7;
            for (int i = 0; i < CZE; i++) begin u8[i] <= u7[i]; w8[i] <= w7[i]; end
            delta8 <= delta_c;
            eneg8  <= ({1'b0, s7, 1'b0} < {1'b0, st7});     // e = 2s - s~ < 0
        end
    end

    // ---------------------------------------------------------- P8 -> P9
    // term_i = floor(sgn+(e) * U_i * 2^-rho)
    logic signed [TRW-1:0] su_c [0:CZE-1];
    logic signed [TRW-1:0] term_c [0:CZE-1];
    always_comb begin
        for (int i = 0; i < CZE; i++) begin
            su_c[i] = eneg8 ? -(TRW'(u8[i])) : TRW'(u8[i]);
            if (rho8 >= 0) term_c[i] = su_c[i] >>> rho8;
            else           term_c[i] = su_c[i] <<< (-rho8);
        end
    end

    (* shreg_extract = "no" *) logic                  t0_9, t1_9, last9;
    (* shreg_extract = "no" *) logic [D-1:0]          delta9;
    (* shreg_extract = "no" *) logic signed [TRW-1:0] term9 [0:CZE-1];
    (* shreg_extract = "no" *) logic signed [WW-1:0]  w9 [0:CZE-1];

    always_ff @(posedge clk) begin
        if (ce) begin
            z9 <= z8; t0_9 <= t0_8; t1_9 <= t1_8; last9 <= last8; delta9 <= delta8;
            for (int i = 0; i < CZE; i++) begin term9[i] <= term_c[i]; w9[i] <= w8[i]; end
        end
    end

    // W(t+1) = clip(W + floor((term + 1) / 2), -2^(Omega+2), 2^(Omega+2) - 1)
    localparam logic signed [TRW+1:0] WMIN = -((TRW+2)'(64'sd1 <<< (OMEGA + 2)));
    localparam logic signed [TRW+1:0] WMAX =  (TRW+2)'((64'sd1 <<< (OMEGA + 2)) - 1);
    logic signed [TRW+1:0] nw_c [0:CZE-1];
    always_comb begin
        for (int i = 0; i < CZE; i++) begin
            nw_c[i] = (TRW+2)'(w9[i]) + (((TRW+2)'(term9[i]) + 1) >>> 1);
            if (nw_c[i] < WMIN)      w_wdata[i*WW +: WW] = WW'(WMIN);
            else if (nw_c[i] > WMAX) w_wdata[i*WW +: WW] = WW'(WMAX);
            else                     w_wdata[i*WW +: WW] = WW'(nw_c[i]);
        end
    end
    assign w_we = ce && v9 && !t0_9;

    assign m_delta = delta9;
    assign m_z     = z9;
    assign m_t0    = t0_9;
    assign m_t1    = t1_9;
    assign m_last  = last9;
endmodule
