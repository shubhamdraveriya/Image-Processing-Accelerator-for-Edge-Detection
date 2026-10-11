`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// secded_dec: SECDED decoder for secded_enc. Purely combinational.
//
//   sbe : one bit was wrong and has been corrected (d is right)
//   dbe : two bits are wrong; d is not trustworthy
// -----------------------------------------------------------------------------
module secded_dec #(
    parameter int DW = 32,
    // check bits: smallest NP with 2^NP >= DW + NP + 1, plus overall parity
    parameter int NP = (DW <= 1) ? 2 : (DW <= 4) ? 3 : (DW <= 11) ? 4 : (DW <= 26) ? 5 :
                                   (DW <= 57) ? 6 : (DW <= 120) ? 7 : (DW <= 247) ? 8 : 9,
    parameter int CW = DW + NP + 1
) (
    input  logic [CW-1:0] c,
    output logic [DW-1:0] d,
    output logic          sbe,
    output logic          dbe
);
    localparam int N  = DW + NP;

    logic [NP-1:0] syn;
    logic          par;
    logic [N:0]    fixed;

    always_comb begin
        integer k;
        syn = '0;
        for (int i = 0; i < NP; i++)
            for (int pos = 1; pos <= N; pos++)
                if (((pos >> i) & 1) == 1) syn[i] = syn[i] ^ c[pos];
        par = ^c;
        // syndrome = position of a single error; overall parity tells single
        // (odd number of flips) from double (even, non-zero syndrome)
        sbe   = par;
        dbe   = !par && (syn != '0);
        fixed = c[N:0];
        for (int pos = 1; pos <= N; pos++)
            if (par && syn == NP'(pos)) fixed[pos] = !c[pos];
        d = '0;
        k = 0;
        for (int pos = 1; pos <= N; pos++) begin
            if ((pos & (pos - 1)) != 0) begin
                d[k] = fixed[pos];
                k = k + 1;
            end
        end
    end
endmodule
