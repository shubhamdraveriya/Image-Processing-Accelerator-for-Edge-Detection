`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// axis_async_fifo: vendor-neutral dual-clock AXI4-Stream FIFO.
//
// Gray-coded pointers crossed with 2-flop synchronizers (Cummings style), a
// generic sdp_ram for storage and a registered first-word-fall-through output.
// Replaces the Vivado FIFO Generator IP so the datapath also builds for
// UltraScale+ and the rad-tolerant XQRKU060 without regenerating IP.
//
//   DEPTH must be a power of two, >= 4.
//   Each side has its own synchronous reset (use reset_sync per domain).
// -----------------------------------------------------------------------------
module axis_async_fifo #(
    parameter int W         = 8,
    parameter int DEPTH     = 16,
    parameter     RAM_STYLE = "auto"
) (
    // write side
    input  logic         s_clk,
    input  logic         s_rst,
    input  logic [W-1:0] s_data,
    input  logic         s_valid,
    output logic         s_ready,

    // read side
    input  logic         m_clk,
    input  logic         m_rst,
    output logic [W-1:0] m_data,
    output logic         m_valid,
    input  logic         m_ready
);
    localparam int AW = $clog2(DEPTH);

    // synthesis translate_off
    initial begin
        if (DEPTH < 4 || (1 << AW) != DEPTH)
            $fatal(1, "axis_async_fifo: DEPTH (%0d) must be a power of two >= 4", DEPTH);
    end
    // synthesis translate_on

    function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
        return b ^ (b >> 1);
    endfunction

    // ---------------- write domain ----------------
    logic [AW:0] wbin, wgray, wbin_next, wgray_next;
    (* ASYNC_REG = "TRUE" *) logic [AW:0] rgray_s1, rgray_s2;
    logic        full;
    logic        wr_fire;

    assign s_ready    = !full;
    assign wr_fire    = s_valid && !full;
    assign wbin_next  = wbin + {{AW{1'b0}}, wr_fire};
    assign wgray_next = bin2gray(wbin_next);

    always_ff @(posedge s_clk) begin
        if (s_rst) begin
            wbin     <= '0;
            wgray    <= '0;
            full     <= 1'b0;
            rgray_s1 <= '0;
            rgray_s2 <= '0;
        end else begin
            wbin     <= wbin_next;
            wgray    <= wgray_next;
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
            full     <= (wgray_next == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});
        end
    end

    // ---------------- read domain -----------------
    logic [AW:0] rbin, rgray, rbin_next, rgray_next;
    (* ASYNC_REG = "TRUE" *) logic [AW:0] wgray_s1, wgray_s2;
    logic        empty;
    logic        rd_fire;

    assign rd_fire    = !empty && (!m_valid || m_ready);
    assign rbin_next  = rbin + {{AW{1'b0}}, rd_fire};
    assign rgray_next = bin2gray(rbin_next);

    always_ff @(posedge m_clk) begin
        if (m_rst) begin
            rbin     <= '0;
            rgray    <= '0;
            empty    <= 1'b1;
            wgray_s1 <= '0;
            wgray_s2 <= '0;
            m_valid  <= 1'b0;
        end else begin
            rbin     <= rbin_next;
            rgray    <= rgray_next;
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
            empty    <= (rgray_next == wgray_s2);
            if (rd_fire)      m_valid <= 1'b1;
            else if (m_ready) m_valid <= 1'b0;
        end
    end

    sdp_ram #(
        .DW        (W),
        .DEPTH     (DEPTH),
        .RAM_STYLE (RAM_STYLE)
    ) u_mem (
        .wclk  (s_clk),
        .we    (wr_fire),
        .waddr (wbin[AW-1:0]),
        .wdata (s_data),
        .rclk  (m_clk),
        .re    (rd_fire),
        .raddr (rbin[AW-1:0]),
        .rdata (m_data)
    );
endmodule
