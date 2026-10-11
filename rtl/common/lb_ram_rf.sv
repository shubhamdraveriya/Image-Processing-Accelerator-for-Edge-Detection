`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// lb_ram_rf: line-buffer RAM with one read-first read/write port (A) and one
// read-only port (B), single clock. Port A returns the old contents of the
// address it writes, which is how a line buffer reads the previous line and
// stores the current one in a single access. Maps to one true-dual-port
// BRAM (or URAM with RAM_STYLE = "ultra") per width/depth slice.
// -----------------------------------------------------------------------------
module lb_ram_rf #(
    parameter int DW        = 16,
    parameter int DEPTH     = 1024,
    parameter     RAM_STYLE = "block",
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
    output logic [DW-1:0] b_rdata
);
    /* verilator lint_off WIDTHEXPAND */
    generate
        if (RAM_STYLE == "ultra") begin : g_ultra
            (* ram_style = "ultra" *) logic [DW-1:0] mem [0:DEPTH-1];
            always_ff @(posedge clk) if (a_en) begin
                a_rdata <= mem[a_addr];
                if (a_we) mem[a_addr] <= a_wdata;
            end
            always_ff @(posedge clk) if (b_en) b_rdata <= mem[b_addr];
        end else if (RAM_STYLE == "block") begin : g_block
            (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];
            always_ff @(posedge clk) if (a_en) begin
                a_rdata <= mem[a_addr];
                if (a_we) mem[a_addr] <= a_wdata;
            end
            always_ff @(posedge clk) if (b_en) b_rdata <= mem[b_addr];
        end else begin : g_auto
            logic [DW-1:0] mem [0:DEPTH-1];
            always_ff @(posedge clk) if (a_en) begin
                a_rdata <= mem[a_addr];
                if (a_we) mem[a_addr] <= a_wdata;
            end
            always_ff @(posedge clk) if (b_en) b_rdata <= mem[b_addr];
        end
    endgenerate
    /* verilator lint_on WIDTHEXPAND */
endmodule
