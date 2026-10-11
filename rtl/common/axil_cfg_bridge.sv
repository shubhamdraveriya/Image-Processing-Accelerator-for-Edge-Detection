`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// axil_cfg_bridge: AXI4-Lite slave -> simple word-addressed config bus.
//
//   cfg_we/cfg_addr/cfg_wdata : one-cycle write strobe (full 32-bit words;
//                               WSTRB is ignored, partial writes unsupported)
//   cfg_re/cfg_addr           : one-cycle read strobe; cfg_rdata must be
//                               valid on the following cycle
//   One transaction at a time, OKAY responses only. This keeps the register
//   maps of the processing blocks free of AXI details, and the same cfg bus
//   can later sit behind a TMR MicroBlaze or SpaceWire RMAP target on the
//   XQRKU060 (no PS there).
// -----------------------------------------------------------------------------
module axil_cfg_bridge #(
    parameter int AW = 26          // byte address width
) (
    input  logic          clk,
    input  logic          rst,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [AW-1:0] s_axil_awaddr,   // [1:0] ignored (word access)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic          s_axil_awvalid,
    output logic          s_axil_awready,
    input  logic [31:0]   s_axil_wdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [3:0]    s_axil_wstrb,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic          s_axil_wvalid,
    output logic          s_axil_wready,
    output logic [1:0]    s_axil_bresp,
    output logic          s_axil_bvalid,
    input  logic          s_axil_bready,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [AW-1:0] s_axil_araddr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic          s_axil_arvalid,
    output logic          s_axil_arready,
    output logic [31:0]   s_axil_rdata,
    output logic [1:0]    s_axil_rresp,
    output logic          s_axil_rvalid,
    input  logic          s_axil_rready,

    output logic          cfg_we,
    output logic          cfg_re,
    output logic [AW-3:0] cfg_addr,    // word address
    output logic [31:0]   cfg_wdata,
    input  logic [31:0]   cfg_rdata
);
    logic          aw_have, w_have, rd_wait;
    logic [AW-3:0] aw_q;
    logic [31:0]   w_q;
    logic          do_write, do_read;

    assign s_axil_awready = !aw_have;
    assign s_axil_wready  = !w_have;
    assign s_axil_bresp   = 2'b00;
    assign s_axil_rresp   = 2'b00;

    // Writes have priority; a read starts only when no write is pending.
    assign do_write = aw_have && w_have && !s_axil_bvalid;
    assign s_axil_arready = !do_write && !rd_wait && !s_axil_rvalid;
    assign do_read  = s_axil_arvalid && s_axil_arready;

    assign cfg_we    = do_write;
    assign cfg_re    = do_read;
    assign cfg_addr  = do_write ? aw_q : s_axil_araddr[AW-1:2];
    assign cfg_wdata = w_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_have       <= 1'b0;
            w_have        <= 1'b0;
            rd_wait       <= 1'b0;
            s_axil_bvalid <= 1'b0;
            s_axil_rvalid <= 1'b0;
        end else begin
            if (s_axil_awvalid && s_axil_awready) begin
                aw_have <= 1'b1;
                aw_q    <= s_axil_awaddr[AW-1:2];
            end
            if (s_axil_wvalid && s_axil_wready) begin
                w_have <= 1'b1;
                w_q    <= s_axil_wdata;
            end
            if (do_write) begin
                aw_have       <= 1'b0;
                w_have        <= 1'b0;
                s_axil_bvalid <= 1'b1;
            end else if (s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end

            rd_wait <= do_read;
            if (rd_wait) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rdata  <= cfg_rdata;
            end else if (s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end
endmodule
