`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// badpix_replace: replaces samples flagged in a bad-pixel map.
//
//   A flagged sample takes the value of the nearest good sample to its left
//   in the same band and the same line (the last good pixel already seen). If
//   there is none (bad samples from pixel 0 onward) the output is 0.
//   The map holds one bit per (pixel, band), written through the table port.
//   replaced pulses for every substituted sample (for telemetry).
// -----------------------------------------------------------------------------
module badpix_replace #(
    parameter int DW        = 16,
    parameter int NX        = 64,
    parameter int NB        = 16,
    parameter     RAM_STYLE = "block",
    parameter int IW        = (NX * NB > 1) ? $clog2(NX * NB) : 1,
    parameter int BW        = (NB > 1) ? $clog2(NB) : 1
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          map_we,
    input  logic [IW-1:0] tbl_addr,
    input  logic          map_wdata,

    input  logic [DW-1:0] s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,
    input  logic          s_axis_tuser,
    input  logic          s_axis_tlast,

    output logic [DW-1:0] m_axis_tdata,
    output logic          m_axis_tvalid,
    input  logic          m_axis_tready,
    output logic          m_axis_tuser,
    output logic          m_axis_tlast,

    output logic          replaced,
    output logic          framing_err
);
    localparam int PW = (NX > 1) ? $clog2(NX) : 1;

    logic ce, fire;
    assign ce            = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = ce;
    assign fire          = s_axis_tvalid && ce;

    logic [PW-1:0] cur_pix;
    logic [BW-1:0] cur_band;
    logic [IW-1:0] cur_idx;
    /* verilator lint_off PINCONNECTEMPTY */
    bip_counter #(.NX(NX), .NB(NB)) u_pos (
        .clk, .rst, .fire,
        .s_tuser (s_axis_tuser),
        .s_tlast (s_axis_tlast),
        .cur_pix, .cur_band, .cur_idx, .cur_eol (),
        .framing_err
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // Stage A: register sample, read map bit and last-good value.
    logic          a_v, a_u, a_l;
    logic [DW-1:0] a_x;
    logic [PW-1:0] a_pix;
    logic [BW-1:0] a_band;
    logic          bad_q;
    logic [DW-1:0] lg_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_v <= 1'b0; a_u <= 1'b0; a_l <= 1'b0;
        end else if (ce) begin
            a_v <= fire; a_u <= s_axis_tuser; a_l <= s_axis_tlast;
        end
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            a_x    <= s_axis_tdata;
            a_pix  <= cur_pix;
            a_band <= cur_band;
        end
    end

    sdp_ram #(.DW(1), .DEPTH(NX * NB), .RAM_STYLE(RAM_STYLE)) u_map (
        .wclk(clk), .we(map_we), .waddr(tbl_addr), .wdata(map_wdata),
        .rclk(clk), .re(ce), .raddr(cur_idx), .rdata(bad_q)
    );

    // Last good value per band. Written in stage B, read in stage A; when both
    // touch the same band on the same edge (NB == 1) the new value is forwarded.
    logic          lg_we;
    logic [DW-1:0] lg_rdata;
    logic          fwd_v;
    logic [DW-1:0] fwd_d;

    sdp_ram #(.DW(DW), .DEPTH(NB), .RAM_STYLE("auto")) u_last_good (
        .wclk(clk), .we(lg_we), .waddr(a_band), .wdata(a_x),
        .rclk(clk), .re(ce), .raddr(cur_band), .rdata(lg_rdata)
    );

    always_ff @(posedge clk) begin
        if (rst) fwd_v <= 1'b0;
        else if (ce) fwd_v <= lg_we && (a_band == cur_band);
    end
    always_ff @(posedge clk) if (ce) fwd_d <= a_x;

    assign lg_q = fwd_v ? fwd_d : lg_rdata;

    // seen[b]: a good sample of band b has been seen earlier in this line.
    logic [NB-1:0] seen;
    logic          have_left;
    assign have_left = (a_pix != '0) && seen[a_band];
    assign lg_we     = ce && a_v && !bad_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            seen <= '0;
        end else if (ce && a_v) begin
            if (!bad_q)              seen[a_band] <= 1'b1;
            else if (a_pix == '0)    seen[a_band] <= 1'b0;
        end
    end

    // Stage B: output
    always_ff @(posedge clk) begin
        if (rst) begin
            m_axis_tvalid <= 1'b0; m_axis_tuser <= 1'b0; m_axis_tlast <= 1'b0;
            replaced      <= 1'b0;
        end else begin
            replaced <= ce && a_v && bad_q;
            if (ce) begin
                m_axis_tvalid <= a_v; m_axis_tuser <= a_u; m_axis_tlast <= a_l;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (ce) m_axis_tdata <= !bad_q ? a_x : (have_left ? lg_q : '0);
    end
endmodule
