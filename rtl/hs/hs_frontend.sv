`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// hs_frontend: hyperspectral pushbroom front end (vendor-neutral PL datapath).
//
//   s_axis (BIP samples, DW bits, tuser = SOF, tlast = end of line)
//     -> line_pacer        detector line timing for replayed data
//     -> radiometric_corr  (x - dark) * gain per pixel and band
//     -> badpix_replace    nearest-left good sample in the same band
//     -> band_select       keep the bands in BAND_MASK
//     -> m_axis            NX x popcount(mask) samples per line
//   register slices between every block.
//
// Register map (AXI4-Lite, 32-bit words, byte address = word index * 4):
//   0x0000_0000  ID            RO  0x4853_0002 ("HS", version 2)
//   0x0000_0004  GEOMETRY      RO  {NB[15:0], NX[15:0]}
//   0x0000_0008  CTRL          WO  bit0: clear the status counters
//   0x0000_000C  LINE_PERIOD   RW  clock cycles per line, 0 = unpaced
//   0x0000_0010  OVERRUNS      RO  lines that over-ran their period
//   0x0000_0014  FRAMING_ERRS  RO  input tuser/tlast inconsistencies
//   0x0000_0018  LINES_OUT     RO  lines delivered on m_axis
//   0x0000_001C  BADPIX_REPL   RO  samples replaced by badpix_replace
//   0x0000_0100+ BAND_MASK     RW  32 bands per word, word i = bands 32i..32i+31
//   0x0400_0000+ DARK[i]       WO  i = pixel * NB + band, DW bits
//   0x0800_0000+ GAIN[i]       WO  i = pixel * NB + band, GW bits (GF fraction)
//   0x0C00_0000+ BADPIX[i]     WO  i = pixel * NB + band, bit 0 = bad
// -----------------------------------------------------------------------------
module hs_frontend #(
    parameter int DW        = 16,
    parameter int NX        = 64,
    parameter int NB        = 16,
    parameter int GW        = 16,
    parameter int GF        = 14,
    parameter     RAM_STYLE = "block",
    parameter int AW        = 28
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [AW-1:0] s_axil_awaddr,
    input  logic          s_axil_awvalid,
    output logic          s_axil_awready,
    input  logic [31:0]   s_axil_wdata,
    input  logic [3:0]    s_axil_wstrb,
    input  logic          s_axil_wvalid,
    output logic          s_axil_wready,
    output logic [1:0]    s_axil_bresp,
    output logic          s_axil_bvalid,
    input  logic          s_axil_bready,
    input  logic [AW-1:0] s_axil_araddr,
    input  logic          s_axil_arvalid,
    output logic          s_axil_arready,
    output logic [31:0]   s_axil_rdata,
    output logic [1:0]    s_axil_rresp,
    output logic          s_axil_rvalid,
    input  logic          s_axil_rready,

    input  logic [DW-1:0] s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,
    input  logic          s_axis_tuser,
    input  logic          s_axis_tlast,

    output logic [DW-1:0] m_axis_tdata,
    output logic          m_axis_tvalid,
    input  logic          m_axis_tready,
    output logic          m_axis_tuser,
    output logic          m_axis_tlast
);
    // ------------------------------------------------------------------ cfg
    logic          cfg_we, cfg_re;
    logic [AW-3:0] cfg_addr;
    logic [31:0]   cfg_wdata, cfg_rdata;

    axil_cfg_bridge #(.AW(AW)) u_axil (
        .clk, .rst,
        .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
        .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
        .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
        .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
        .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
        .cfg_we, .cfg_re, .cfg_addr, .cfg_wdata, .cfg_rdata
    );

    hs_frontend_core #(.DW(DW), .NX(NX), .NB(NB), .GW(GW), .GF(GF), .RAM_STYLE(RAM_STYLE), .AW(AW)) u_core (
        .clk, .rst,
        .cfg_we, .cfg_re, .cfg_addr, .cfg_wdata, .cfg_rdata,
        .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
        .m_axis_tdata, .m_axis_tvalid, .m_axis_tready, .m_axis_tuser, .m_axis_tlast
    );
endmodule
