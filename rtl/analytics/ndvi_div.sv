`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ndvi_div: pipelined NDVI, one pixel per clock.
//
//   ndvi8 = floor(256 * nir / (nir + red)), saturated to 255; 128 if both 0
//
// i.e. NDVI = (nir - red) / (nir + red) mapped from [-1, 1] to [0, 255].
// Restoring division, one quotient bit per stage: 9 stages (q = 0..256),
// then saturation. A side-band word (SB bits) travels with each pixel.
// All stages advance together on ce = !m_valid || m_ready.
// -----------------------------------------------------------------------------
module ndvi_div #(
    parameter int D  = 12,
    parameter int SB = 1
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [D-1:0]  s_nir,
    input  logic [D-1:0]  s_red,
    input  logic [SB-1:0] s_sb,
    input  logic          s_valid,
    output logic          s_ready,

    output logic [7:0]    m_ndvi,
    output logic [SB-1:0] m_sb,
    output logic          m_valid,
    input  logic          m_ready
);
    localparam int NS = 9;               // quotient bits 8..0
    localparam int RW = D + 2;           // remainder < 2 * den <= 2^(D+2)

    logic ce;
    assign ce      = !m_valid || m_ready;
    assign s_ready = ce;

    (* shreg_extract = "no" *) logic [NS:0]   v;
    (* shreg_extract = "no" *) logic [RW-1:0] rem [0:NS];
    (* shreg_extract = "no" *) logic [D:0]    den [0:NS];
    (* shreg_extract = "no" *) logic [NS-1:0] q   [0:NS];
    (* shreg_extract = "no" *) logic [SB-1:0] sb  [0:NS];

    always_ff @(posedge clk) begin
        if (rst) v <= '0;
        else if (ce) v <= {v[NS-1:0], s_valid};
    end

    // stage i (1..9) produces quotient bit 9-i: bit 8 compares nir with den
    // directly, later bits shift the remainder first
    logic [RW-1:0] r_c [1:NS];
    logic          ge_c [1:NS];
    always_comb begin
        for (int i = 1; i <= NS; i++) begin
            r_c[i]  = (i == 1) ? rem[i-1] : (rem[i-1] << 1);
            ge_c[i] = r_c[i] >= RW'(den[i-1]);
        end
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            rem[0] <= RW'(s_nir);
            den[0] <= (D+1)'(s_nir) + (D+1)'(s_red);
            q[0]   <= '0;
            sb[0]  <= s_sb;
            for (int i = 1; i <= NS; i++) begin
                rem[i] <= ge_c[i] ? r_c[i] - RW'(den[i-1]) : r_c[i];
                q[i]   <= {q[i-1][NS-2:0], ge_c[i]};
                den[i] <= den[i-1];
                sb[i]  <= sb[i-1];
            end
        end
    end

    assign m_valid = v[NS];
    assign m_sb    = sb[NS];
    assign m_ndvi  = (den[NS] == '0) ? 8'd128 : q[NS][8] ? 8'd255 : q[NS][7:0];
endmodule
