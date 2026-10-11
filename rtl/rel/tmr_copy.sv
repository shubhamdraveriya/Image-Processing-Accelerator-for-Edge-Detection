`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tmr_copy: one copy of a tmr_reg register (a separate module so the three
// copies can be protected from merging with keep_hierarchy / dont_touch).
// -----------------------------------------------------------------------------
module tmr_copy #(
    parameter int           W       = 8,
    parameter logic [W-1:0] RST_VAL = '0
) (
    input  logic         clk,
    input  logic         rst,
    input  logic [W-1:0] d,
    output logic [W-1:0] q
);
    always_ff @(posedge clk) begin
        if (rst) q <= RST_VAL;
        else     q <= d;
    end
endmodule
