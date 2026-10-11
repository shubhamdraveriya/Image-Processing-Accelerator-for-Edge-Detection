`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// reset_sync: asynchronous assert, synchronous de-assert reset bridge.
// Every clock domain gets its own copy; all downstream logic uses the
// synchronous, active-high output.
// -----------------------------------------------------------------------------
module reset_sync #(
    parameter int STAGES = 3
) (
    input  logic clk,
    input  logic rst_async,   // active high, any domain
    output logic rst_sync     // active high, synchronous to clk
);
    (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q;

    always_ff @(posedge clk or posedge rst_async) begin
        if (rst_async) sync_q <= '1;
        else           sync_q <= {sync_q[STAGES-2:0], 1'b0};
    end

    assign rst_sync = sync_q[STAGES-1];
endmodule
