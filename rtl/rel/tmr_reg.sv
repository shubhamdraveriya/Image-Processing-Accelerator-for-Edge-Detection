`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tmr_reg: register with optional triple modular redundancy.
//
//   TMR = 0 : one register
//   TMR = 1 : three copies and a bitwise majority voter. Every enabled clock
//             loads the voted next value into all three, and the copies
//             re-converge on every clock even when en is low (each copy
//             reloads the voted value), so an upset lasts at most one cycle
//             and never reaches q.
//
//   mismatch : the copies disagreed this cycle (an upset was outvoted), for
//              a telemetry counter
//   inj      : flips copy 0 for one clock (fault-injection testing; tie to 0)
//
// Each copy is its own tmr_copy instance with keep_hierarchy / dont_touch, so
// neither Vivado nor Yosys merges the copies back into one register.
// -----------------------------------------------------------------------------
module tmr_reg #(
    parameter int         W   = 8,
    parameter bit         TMR = 1'b1,
    parameter logic [W-1:0] RST_VAL = '0
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         en,
    input  logic [W-1:0] d,
    output logic [W-1:0] q,
    input  logic [W-1:0] inj,
    output logic         mismatch
);
    generate
        if (TMR) begin : g_tmr
            logic [W-1:0] r0, r1, r2, voted, nxt;
            assign voted    = (r0 & r1) | (r1 & r2) | (r0 & r2);
            assign q        = voted;
            assign mismatch = (r0 != r1) || (r1 != r2);
            assign nxt      = en ? d : voted;
            (* keep_hierarchy = "yes", dont_touch = "true" *)
            tmr_copy #(.W(W), .RST_VAL(RST_VAL)) u_r0 (.clk, .rst, .d (nxt ^ inj), .q (r0));
            (* keep_hierarchy = "yes", dont_touch = "true" *)
            tmr_copy #(.W(W), .RST_VAL(RST_VAL)) u_r1 (.clk, .rst, .d (nxt), .q (r1));
            (* keep_hierarchy = "yes", dont_touch = "true" *)
            tmr_copy #(.W(W), .RST_VAL(RST_VAL)) u_r2 (.clk, .rst, .d (nxt), .q (r2));
        end else begin : g_one
            logic [W-1:0] r;
            assign q        = r;
            assign mismatch = 1'b0;
            always_ff @(posedge clk) begin
                if (rst)     r <= RST_VAL;
                else         r <= (en ? d : r) ^ inj;
            end
        end
    endgenerate
endmodule

