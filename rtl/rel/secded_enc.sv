`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// secded_enc: single-error-correcting, double-error-detecting (SECDED)
// extended Hamming encoder, any data width. Purely combinational.
// -----------------------------------------------------------------------------
module secded_enc #(
    parameter int DW = 32,
    // check bits: smallest NP with 2^NP >= DW + NP + 1, plus overall parity
    parameter int NP = (DW <= 1) ? 2 : (DW <= 4) ? 3 : (DW <= 11) ? 4 : (DW <= 26) ? 5 :
                                   (DW <= 57) ? 6 : (DW <= 120) ? 7 : (DW <= 247) ? 8 : 9,
    parameter int CW = DW + NP + 1
) (
    input  logic [DW-1:0] d,
    output logic [CW-1:0] c
);
    localparam int N  = DW + NP;

    logic [N:0]    w;      // data bits in place, check bits still zero
    logic [NP-1:0] chk;

    always_comb begin
        integer k;
        w = '0;
        k = 0;
        for (int pos = 1; pos <= N; pos++) begin
            if ((pos & (pos - 1)) != 0) begin      // not a power of two: data
                w[pos] = d[k];
                k = k + 1;
            end
        end
        chk = '0;
        for (int i = 0; i < NP; i++)
            for (int pos = 1; pos <= N; pos++)
                if (((pos >> i) & 1) == 1) chk[i] = chk[i] ^ w[pos];
    end

    always_comb begin
        c = CW'(w);
        for (int i = 0; i < NP; i++) c[1 << i] = chk[i];
        c[0] = ^c[N:1];
    end
endmodule
