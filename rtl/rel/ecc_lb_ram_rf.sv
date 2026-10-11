`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ecc_lb_ram_rf: lb_ram_rf (read-first line buffer RAM) with optional SECDED
// protection on both read ports. Same conventions as ecc_sdp_ram; the error
// flags cover port A and port B together.
// -----------------------------------------------------------------------------
module ecc_lb_ram_rf #(
    parameter int DW        = 16,
    parameter int DEPTH     = 1024,
    parameter     RAM_STYLE = "block",
    parameter bit ECC       = 1'b1,
    parameter int AW        = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic          clk,
    input  logic          a_en,
    input  logic          a_we,
    input  logic [AW-1:0] a_addr,
    input  logic [DW-1:0] a_wdata,
    output logic [DW-1:0] a_rdata,
    input  logic          b_en,
    input  logic [AW-1:0] b_addr,
    output logic [DW-1:0] b_rdata,
    input  logic          inj_sbe,
    input  logic          inj_dbe,
    output logic          sbe,
    output logic          dbe
);
    localparam int NP = (DW <= 1) ? 2 : (DW <= 4) ? 3 : (DW <= 11) ? 4 : (DW <= 26) ? 5 :
                        (DW <= 57) ? 6 : (DW <= 120) ? 7 : 8;
    localparam int MW = ECC ? DW + NP + 1 : DW;

    logic [MW-1:0] enc, flip, a_q, b_q;

    // injected bit position steps through the word, one bit per injection
    localparam int IBW = (MW > 1) ? $clog2(MW) : 1;
    logic [IBW-1:0] ib, ib2;
    always_ff @(posedge clk) begin
        if (inj_sbe || inj_dbe) ib <= (ib == IBW'(MW - 1)) ? '0 : ib + 1'b1;
    end
    initial ib = '0;
    assign ib2 = (ib == IBW'(MW - 1)) ? '0 : ib + 1'b1;
    always_comb begin
        flip = '0;
        if (inj_sbe || inj_dbe) flip[ib]  = 1'b1;
        if (inj_dbe)            flip[ib2] = 1'b1;
    end

    lb_ram_rf #(.DW(MW), .DEPTH(DEPTH), .RAM_STYLE(RAM_STYLE)) u_mem (
        .clk,
        .a_en, .a_we, .a_addr, .a_wdata (enc ^ flip), .a_rdata (a_q),
        .b_en, .b_addr, .b_rdata (b_q)
    );

    generate
        if (ECC) begin : g_ecc
            logic a_sbe, a_dbe, b_sbe, b_dbe;
            secded_enc #(.DW(DW)) u_enc   (.d (a_wdata), .c (enc));
            secded_dec #(.DW(DW)) u_dec_a (.c (a_q), .d (a_rdata), .sbe (a_sbe), .dbe (a_dbe));
            secded_dec #(.DW(DW)) u_dec_b (.c (b_q), .d (b_rdata), .sbe (b_sbe), .dbe (b_dbe));
            assign sbe = a_sbe || b_sbe;
            assign dbe = a_dbe || b_dbe;
        end else begin : g_raw
            assign enc     = a_wdata;
            assign a_rdata = a_q;
            assign b_rdata = b_q;
            assign sbe     = 1'b0;
            assign dbe     = 1'b0;
        end
    endgenerate
endmodule
