`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// radiometric_corr: per-pixel, per-band dark and gain correction.
//
//   y = clamp( ((x - dark[p,b]) * gain[p,b] + 2^(GF-1)) >>> GF , 0, 2^DW - 1 )
//
//   dark : DW-bit unsigned offset          gain : GW-bit unsigned, GF fraction
//   bits (GW=16, GF=14 gives gains 0 .. 3.99994, 1.0 = 0x4000).
//
//   Tables hold NX*NB entries indexed by the sample's position in the line and
//   are written through the table port (from the AXI-Lite register map). The
//   multiply maps to one DSP48E1/E2 per lane on Xilinx parts. Same
//   stall-the-pipeline backpressure scheme as the edge blocks.
// -----------------------------------------------------------------------------
module radiometric_corr #(
    parameter int DW        = 16,
    parameter int NX        = 64,
    parameter int NB        = 16,
    parameter int GW        = 16,
    parameter int GF        = 14,
    parameter     RAM_STYLE = "block",
    parameter int IW        = (NX * NB > 1) ? $clog2(NX * NB) : 1
) (
    input  logic          clk,
    input  logic          rst,

    // table write port
    input  logic          dark_we,
    input  logic          gain_we,
    input  logic [IW-1:0] tbl_addr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]   tbl_wdata,     // low DW / GW bits used
    /* verilator lint_on UNUSEDSIGNAL */

    input  logic [DW-1:0] s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,
    input  logic          s_axis_tuser,
    input  logic          s_axis_tlast,

    output logic [DW-1:0] m_axis_tdata,
    output logic          m_axis_tvalid,
    input  logic          m_axis_tready,
    output logic          m_axis_tuser,
    output logic          m_axis_tlast,

    output logic          framing_err
);
    localparam int MAXV = (1 << DW) - 1;
    localparam int PRW  = DW + GW + 2;     // product width (signed)

    logic ce, fire;
    assign ce            = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = ce;
    assign fire          = s_axis_tvalid && ce;

    logic [IW-1:0] cur_idx;
    /* verilator lint_off PINCONNECTEMPTY */
    bip_counter #(.NX(NX), .NB(NB)) u_pos (
        .clk, .rst, .fire,
        .s_tuser (s_axis_tuser),
        .s_tlast (s_axis_tlast),
        .cur_pix (), .cur_band (), .cur_idx (cur_idx), .cur_eol (),
        .framing_err
    );
    /* verilator lint_on PINCONNECTEMPTY */

    logic [DW-1:0] dark_q;
    logic [GW-1:0] gain_q;

    sdp_ram #(.DW(DW), .DEPTH(NX * NB), .RAM_STYLE(RAM_STYLE)) u_dark (
        .wclk(clk), .we(dark_we), .waddr(tbl_addr), .wdata(tbl_wdata[DW-1:0]),
        .rclk(clk), .re(ce), .raddr(cur_idx), .rdata(dark_q)
    );
    sdp_ram #(.DW(GW), .DEPTH(NX * NB), .RAM_STYLE(RAM_STYLE)) u_gain (
        .wclk(clk), .we(gain_we), .waddr(tbl_addr), .wdata(tbl_wdata[GW-1:0]),
        .rclk(clk), .re(ce), .raddr(cur_idx), .rdata(gain_q)
    );

    // A: sample registered alongside the table reads
    logic [DW-1:0] a_x;
    // B: difference, C: product, D: product (DSP M/P register), E: output
    logic signed [DW:0]      b_diff;
    logic        [GW-1:0]    b_gain;
    logic signed [PRW-1:0]   c_prod, d_prod;
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [PRW-1:0]   d_round;  // fraction bits dropped by the shift
    /* verilator lint_on UNUSEDSIGNAL */
    logic signed [PRW-GF-1:0] d_shift;
    logic a_v, b_v, c_v, d_v;
    logic a_u, b_u, c_u, d_u;
    logic a_l, b_l, c_l, d_l;

    always_ff @(posedge clk) begin
        if (rst) begin
            {a_v, b_v, c_v, d_v, m_axis_tvalid} <= '0;
            {a_u, b_u, c_u, d_u, m_axis_tuser}  <= '0;
            {a_l, b_l, c_l, d_l, m_axis_tlast}  <= '0;
        end else if (ce) begin
            a_v <= fire;      b_v <= a_v; c_v <= b_v; d_v <= c_v; m_axis_tvalid <= d_v;
            a_u <= s_axis_tuser; b_u <= a_u; c_u <= b_u; d_u <= c_u; m_axis_tuser <= d_u;
            a_l <= s_axis_tlast; b_l <= a_l; c_l <= b_l; d_l <= c_l; m_axis_tlast <= d_l;
        end
    end

    assign d_round = d_prod + PRW'(1 << (GF - 1));
    assign d_shift = d_round[PRW-1:GF];

    always_ff @(posedge clk) begin
        if (ce) begin
            a_x    <= s_axis_tdata;
            b_diff <= $signed({1'b0, a_x}) - $signed({1'b0, dark_q});
            b_gain <= gain_q;
            c_prod <= PRW'(b_diff) * $signed({1'b0, b_gain});
            d_prod <= c_prod;
            if (d_shift < 0)
                m_axis_tdata <= '0;
            else if (d_shift > (PRW-GF)'(MAXV))
                m_axis_tdata <= DW'(MAXV);
            else
                m_axis_tdata <= d_shift[DW-1:0];
        end
    end
endmodule
