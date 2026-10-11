`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ecc_sdp_ram: sdp_ram with optional SECDED protection, as a drop-in
// replacement (same ports plus error flags and error injection).
//
//   ECC = 0 : plain sdp_ram
//   ECC = 1 : the word is split into slices of up to SLICE bits, each stored
//             with its own SECDED check bits; one upset bit per slice is
//             corrected on read, two in a slice are flagged
//
//   sbe / dbe : valid with rdata; a slice of this read had a corrected /
//               an uncorrectable error
//   inj_sbe / inj_dbe : flip one / two bits of one slice of the word being
//               written (position steps on each time). For fault-injection
//               tests on the ground or in orbit; tie to 0 otherwise.
//
// Used for state that the design rewrites continuously (weights, accumulators,
// line buffers), so an upset is either corrected on its next read or
// overwritten; these memories need no background scrubber.
// -----------------------------------------------------------------------------
module ecc_sdp_ram #(
    parameter int DW        = 8,
    parameter int DEPTH     = 64,
    parameter     RAM_STYLE = "auto",
    parameter bit ECC       = 1'b1,
    parameter int SLICE     = 64,
    parameter int AW        = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic          inj_sbe,
    input  logic          inj_dbe,

    input  logic          re,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata,
    output logic          sbe,
    output logic          dbe
);
    localparam int SW  = (DW < SLICE) ? DW : SLICE;          // data bits per slice
    localparam int NS  = (DW + SW - 1) / SW;                 // slices
    localparam int NP  = (SW <= 1) ? 2 : (SW <= 4) ? 3 : (SW <= 11) ? 4 : (SW <= 26) ? 5 :
                         (SW <= 57) ? 6 : (SW <= 120) ? 7 : (SW <= 247) ? 8 : 9;
    localparam int SCW = ECC ? SW + NP + 1 : SW;             // stored bits per slice
    localparam int MW  = NS * SCW;

    logic [NS*SW-1:0] din, dout;
    logic [MW-1:0]    enc, flip, mem_rdata;
    logic [NS-1:0]    s_sbe, s_dbe;

    assign din = (NS*SW)'(wdata);

    // injection: the slice and the bit step on by one per injection, so a
    // test sweeps every stored bit; a double error flips two neighbouring
    // bits of the same slice
    localparam int IBW = (SCW > 1) ? $clog2(SCW) : 1;
    localparam int ISW = (NS > 1) ? $clog2(NS) : 1;
    logic [IBW-1:0] ib, ib2;
    logic [ISW-1:0] isl;
    initial begin ib = '0; isl = '0; end
    always_ff @(posedge clk) begin
        if (inj_sbe || inj_dbe) begin
            isl <= (isl == ISW'(NS - 1)) ? '0 : isl + 1'b1;
            if (isl == ISW'(NS - 1)) ib <= (ib == IBW'(SCW - 1)) ? '0 : ib + 1'b1;
        end
    end
    assign ib2 = (ib == IBW'(SCW - 1)) ? '0 : ib + 1'b1;
    always_comb begin
        flip = '0;
        for (int i = 0; i < NS; i++) begin
            if ((inj_sbe || inj_dbe) && isl == ISW'(i)) flip[i * SCW + 32'(ib)] = 1'b1;
            if (inj_dbe && isl == ISW'(i))              flip[i * SCW + 32'(ib2)] = 1'b1;
        end
    end

    sdp_ram #(.DW(MW), .DEPTH(DEPTH), .RAM_STYLE(RAM_STYLE)) u_mem (
        .wclk (clk), .we, .waddr, .wdata (enc ^ flip),
        .rclk (clk), .re, .raddr, .rdata (mem_rdata)
    );

    generate
        for (genvar i = 0; i < NS; i++) begin : g_slice
            if (ECC) begin : g_ecc
                secded_enc #(.DW(SW)) u_enc (.d (din[i*SW +: SW]), .c (enc[i*SCW +: SCW]));
                secded_dec #(.DW(SW)) u_dec (.c (mem_rdata[i*SCW +: SCW]), .d (dout[i*SW +: SW]),
                                             .sbe (s_sbe[i]), .dbe (s_dbe[i]));
            end else begin : g_raw
                assign enc[i*SCW +: SCW] = din[i*SW +: SW];
                assign dout[i*SW +: SW]  = mem_rdata[i*SCW +: SCW];
                assign s_sbe[i] = 1'b0;
                assign s_dbe[i] = 1'b0;
            end
        end
    endgenerate

    assign rdata = dout[DW-1:0];
    assign sbe   = |s_sbe;
    assign dbe   = |s_dbe;
endmodule
