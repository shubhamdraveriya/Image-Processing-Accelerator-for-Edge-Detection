`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ccsds123_top: CCSDS 123.0-B-2 lossless hyperspectral compressor.
//
//   in : AXI4-Stream samples, D bits, band-interleaved-by-pixel order,
//        tuser = first sample of an image, tlast = last sample of each line
//   out: AXI4-Stream bytes, 64 bits wide (lane 0 first), tkeep on the last
//        word, tlast at the end of each compressed image
//
// With EMIT_HEADER = 1 every image starts with the 19-byte CCSDS 123 header
// built from the parameters, so the output of each image is a complete
// standard file that any compliant decompressor reads. With EMIT_HEADER = 0
// only the body is sent (software adds the header).
//
// Configuration (fixed at build time, carried in the header):
//   lossless, unsigned samples, D <= 16, full or reduced prediction, P <= 15,
//   wide neighbour or column local sums, default weight initialisation,
//   sample-adaptive entropy coder, BIP (M = Nz), output word size 1 byte.
//
// Throughput: one sample per clock when NZ >= 9 (smaller NZ stalls for the
// per-band weight update; see ccsds123_predictor).
// -----------------------------------------------------------------------------
module ccsds123_top #(
    parameter int NX          = 64,
    parameter int NY          = 64,
    parameter int NZ          = 16,
    parameter int D           = 16,
    parameter int P           = 3,
    parameter bit FULL        = 1'b1,
    parameter int LOCAL_SUM   = 0,
    parameter int OMEGA       = 13,
    parameter int R           = 64,
    parameter int VMIN        = -1,
    parameter int VMAX        = 3,
    parameter int TINC_LOG2   = 6,
    parameter int UMAX        = 18,
    parameter int GSTAR       = 6,
    parameter int GAMMA0      = 1,
    parameter int KINIT       = 3,
    parameter bit EMIT_HEADER = 1'b1,
    parameter     LB_RAM_STYLE = "block"
) (
    input  logic         clk,
    input  logic         rst,

    input  logic [D-1:0] s_axis_tdata,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,
    input  logic         s_axis_tuser,
    input  logic         s_axis_tlast,

    output logic [63:0]  m_axis_tdata,
    output logic [7:0]   m_axis_tkeep,
    output logic         m_axis_tlast,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,

    output logic         framing_err
);
    localparam int ZW = (NZ > 1) ? $clog2(NZ) : 1;
    localparam int CW = (D > 8) ? D : 8;
    localparam int LW = 6;

    // ------------------------------------------------------------- header
    localparam logic [151:0] HEADER = {
        // image metadata, essential subpart (12 bytes)
        8'd0, 16'(NX), 16'(NY), 16'(NZ),
        1'b0, 1'b0, 1'b0, 4'(D), 1'b0, 16'(NZ), 2'b00, 3'd1, 2'd0, 1'b0, 2'd0, 2'b00, 4'd0,
        // predictor metadata, primary structure (5 bytes)
        1'b0, 1'b0, 4'(P), !FULL, 1'b0, 2'(LOCAL_SUM), 6'(R), 4'(OMEGA - 4), 4'(TINC_LOG2 - 4),
        4'(VMIN + 6), 4'(VMAX + 6), 1'b0, 1'b0, 1'b0, 5'd0,
        // entropy coder metadata, sample-adaptive (2 bytes)
        5'(UMAX), 3'(GSTAR - 4), 3'(GAMMA0), 4'(KINIT), 1'b0
    };

    // ---------------------------------------------------------- predictor
    logic [D-1:0]  p_delta;
    logic [ZW-1:0] p_z;
    logic          p_t0, p_t1, p_last, p_valid, p_ready;

    ccsds123_predictor #(
        .NX(NX), .NY(NY), .NZ(NZ), .D(D), .P(P), .FULL(FULL), .LOCAL_SUM(LOCAL_SUM),
        .OMEGA(OMEGA), .R(R), .VMIN(VMIN), .VMAX(VMAX), .TINC_LOG2(TINC_LOG2),
        .LB_RAM_STYLE(LB_RAM_STYLE)
    ) u_pred (
        .clk, .rst,
        .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
        .m_delta(p_delta), .m_z(p_z), .m_t0(p_t0), .m_t1(p_t1), .m_last(p_last),
        .m_valid(p_valid), .m_ready(p_ready),
        .framing_err
    );

    // register slice: breaks the ready path from the output back to the predictor
    logic [D-1:0]  r_delta;
    logic [ZW-1:0] r_z;
    logic          r_t0, r_t1, r_last, r_valid, r_ready;

    axis_register #(.W(D + ZW + 3)) u_slice (
        .clk, .rst,
        .s_data({p_delta, p_z, p_t0, p_t1, p_last}), .s_valid(p_valid), .s_ready(p_ready),
        .m_data({r_delta, r_z, r_t0, r_t1, r_last}), .m_valid(r_valid), .m_ready(r_ready)
    );

    // -------------------------------------------------------------- coder
    logic [CW-1:0] c_code;
    logic [LW-1:0] c_len;
    logic          c_first, c_last, c_valid, c_ready;

    ccsds123_coder #(
        .NZ(NZ), .D(D), .UMAX(UMAX), .GSTAR(GSTAR), .GAMMA0(GAMMA0), .KINIT(KINIT),
        .CW(CW), .LW(LW)
    ) u_coder (
        .clk, .rst,
        .s_delta(r_delta), .s_z(r_z), .s_t0(r_t0), .s_t1(r_t1), .s_last(r_last),
        .s_valid(r_valid), .s_ready(r_ready),
        .m_code(c_code), .m_len(c_len), .m_first(c_first), .m_last(c_last),
        .m_valid(c_valid), .m_ready(c_ready)
    );

    // ---------------------------------------------- header insertion
    logic [4:0]    hcnt;
    logic          hdr_done, hdr_active;
    logic [CW-1:0] k_code;
    logic [LW-1:0] k_len;
    logic          k_last, k_ready;

    assign hdr_active = EMIT_HEADER && c_valid && c_first && !hdr_done;
    assign k_code     = hdr_active ? CW'(HEADER[151 - 8 * hcnt -: 8]) : c_code;
    assign k_len      = hdr_active ? LW'(8) : c_len;
    assign k_last     = !hdr_active && c_last;
    assign c_ready    = k_ready && !hdr_active;

    always_ff @(posedge clk) begin
        if (rst) begin
            hcnt <= '0; hdr_done <= 1'b0;
        end else if (c_valid && k_ready) begin
            if (hdr_active) begin
                hcnt     <= (hcnt == 5'd18) ? '0 : hcnt + 1'b1;
                hdr_done <= (hcnt == 5'd18);
            end else if (c_last) begin
                hdr_done <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------- packer
    ccsds123_packer #(.CW(CW), .LW(LW)) u_pack (
        .clk, .rst,
        .s_code(k_code), .s_len(k_len), .s_last(k_last), .s_valid(c_valid), .s_ready(k_ready),
        .m_axis_tdata, .m_axis_tkeep, .m_axis_tlast, .m_axis_tvalid, .m_axis_tready
    );
endmodule
