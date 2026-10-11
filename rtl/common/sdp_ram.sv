`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// sdp_ram: generic simple-dual-port RAM (one write port, one registered read
// port), written so Vivado infers block RAM / LUTRAM / UltraRAM from plain RTL.
//
// No vendor primitives, so the same file maps to 7-series (Basys 3),
// Zynq UltraScale+ (ZCU106) and Kintex UltraScale (XQRKU060, which has no
// UltraRAM: use "block" there).
//
//   RAM_STYLE : "block" | "distributed" | "ultra" | "auto" (let the tool pick)
//   Read latency is 1 cycle. rdata only changes when re is high, so a stalled
//   pipeline can simply hold re low.
// -----------------------------------------------------------------------------
module sdp_ram #(
    parameter int DW        = 8,
    parameter int DEPTH     = 64,
    parameter     RAM_STYLE = "auto",
    parameter int AW        = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic          wclk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,

    input  logic          rclk,
    input  logic          re,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);
    // String parameters are compared against literals of other widths.
    /* verilator lint_off WIDTHEXPAND */
    generate
        if (RAM_STYLE == "block") begin : g_block
            (* ram_style = "block" *) logic [DW-1:0] mem [0:DEPTH-1];
`ifndef SYNTHESIS
            initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;   // BRAM/LUTRAM power up as zero
`endif
            always_ff @(posedge wclk) if (we) mem[waddr] <= wdata;
            always_ff @(posedge rclk) if (re) rdata <= mem[raddr];
        end else if (RAM_STYLE == "distributed") begin : g_dist
            (* ram_style = "distributed" *) logic [DW-1:0] mem [0:DEPTH-1];
`ifndef SYNTHESIS
            initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;   // BRAM/LUTRAM power up as zero
`endif
            always_ff @(posedge wclk) if (we) mem[waddr] <= wdata;
            always_ff @(posedge rclk) if (re) rdata <= mem[raddr];
        end else if (RAM_STYLE == "ultra") begin : g_ultra
            (* ram_style = "ultra" *) logic [DW-1:0] mem [0:DEPTH-1];
`ifndef SYNTHESIS
            initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;   // BRAM/LUTRAM power up as zero
`endif
            always_ff @(posedge wclk) if (we) mem[waddr] <= wdata;
            always_ff @(posedge rclk) if (re) rdata <= mem[raddr];
        end else begin : g_auto
            logic [DW-1:0] mem [0:DEPTH-1];
`ifndef SYNTHESIS
            initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;   // BRAM/LUTRAM power up as zero
`endif
            always_ff @(posedge wclk) if (we) mem[waddr] <= wdata;
            always_ff @(posedge rclk) if (re) rdata <= mem[raddr];
        end
    endgenerate
    /* verilator lint_on WIDTHEXPAND */
endmodule
