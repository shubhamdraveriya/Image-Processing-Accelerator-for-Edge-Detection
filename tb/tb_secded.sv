`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_secded: exhaustive error-pattern test of secded_enc / secded_dec.
// For random data words: no error -> clean; every single-bit flip -> corrected
// and flagged sbe; every double-bit flip -> flagged dbe (never sbe).
// -----------------------------------------------------------------------------
module tb_secded;
    parameter int DW    = 16;
    parameter int WORDS = 100;
    localparam int NP = (DW <= 1) ? 2 : (DW <= 4) ? 3 : (DW <= 11) ? 4 : (DW <= 26) ? 5 :
                        (DW <= 57) ? 6 : (DW <= 120) ? 7 : (DW <= 247) ? 8 : 9;
    localparam int CW = DW + NP + 1;

    logic [DW-1:0] d, q;
    logic [CW-1:0] c, cf;
    logic          sbe, dbe;
    int            errors = 0, checks = 0;

    secded_enc #(.DW(DW)) u_enc (.d, .c);
    secded_dec #(.DW(DW)) u_dec (.c(cf), .d(q), .sbe, .dbe);

    task automatic check(input logic [CW-1:0] flip, input int nflip);
        cf = c ^ flip;
        #1;
        checks++;
        if (nflip == 0 && (q !== d || sbe || dbe)) errors++;
        if (nflip == 1 && (q !== d || !sbe || dbe)) errors++;
        if (nflip == 2 && (sbe || !dbe)) errors++;
    endtask

    initial begin
        for (int w = 0; w < WORDS; w++) begin
            d = DW'({$urandom, $urandom, $urandom, $urandom});
            if (w == 0) d = '0;
            if (w == 1) d = '1;
            #1;
            check('0, 0);
            for (int i = 0; i < CW; i++) begin
                check(CW'(1) << i, 1);
                for (int j = i + 1; j < CW; j++) check((CW'(1) << i) | (CW'(1) << j), 2);
            end
        end
        if (errors == 0) $display("PASS: DW=%0d CW=%0d, %0d error patterns checked", DW, CW, checks);
        else             $fatal(1, "FAIL: %0d of %0d checks wrong", errors, checks);
        $finish;
    end
endmodule
