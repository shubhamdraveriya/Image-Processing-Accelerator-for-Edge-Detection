`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// band_select: keeps only the bands whose bit is set in band_mask.
//
//   Pixxel-style capture: of NB bands on the detector, a programmable subset
//   is kept. The mask is sampled at the start of each frame (tuser), so a
//   mask written mid-frame takes effect from the next frame.
//   Output tlast marks the last kept band of the last pixel of each line;
//   tuser marks the first kept sample of each frame.
// -----------------------------------------------------------------------------
module band_select #(
    parameter int DW = 16,
    parameter int NX = 64,
    parameter int NB = 16,
    parameter int BW = (NB > 1) ? $clog2(NB) : 1
) (
    input  logic          clk,
    input  logic          rst,
    input  logic [NB-1:0] band_mask,

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

    output logic          framing_err
);
    localparam int PW = (NX > 1) ? $clog2(NX) : 1;

    function automatic [BW-1:0] last_set(input [NB-1:0] m);
        last_set = '0;
        for (int i = 0; i < NB; i++) if (m[i]) last_set = BW'(i);
    endfunction

    logic ce, fire;
    assign ce            = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = ce;
    assign fire          = s_axis_tvalid && ce;

    logic [PW-1:0] cur_pix;
    logic [BW-1:0] cur_band;
    /* verilator lint_off PINCONNECTEMPTY */
    bip_counter #(.NX(NX), .NB(NB)) u_pos (
        .clk, .rst, .fire,
        .s_tuser (s_axis_tuser),
        .s_tlast (s_axis_tlast),
        .cur_pix, .cur_band, .cur_idx (), .cur_eol (),
        .framing_err
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // Configured mask and its last kept band, registered (static config),
    // then latched into the active copy at each start of frame.
    logic [NB-1:0] mask_cfg_q, mask_act, mask_eff;
    logic [BW-1:0] last_cfg_q, last_act, last_eff;
    logic          sof_pending;

    always_ff @(posedge clk) begin
        mask_cfg_q <= band_mask;
        last_cfg_q <= last_set(band_mask);
    end

    assign mask_eff = s_axis_tuser ? mask_cfg_q : mask_act;
    assign last_eff = s_axis_tuser ? last_cfg_q : last_act;

    always_ff @(posedge clk) begin
        if (rst) begin
            mask_act    <= '1;
            last_act    <= BW'(NB - 1);
            sof_pending <= 1'b0;
        end else if (fire) begin
            if (s_axis_tuser) begin
                mask_act <= mask_cfg_q;
                last_act <= last_cfg_q;
            end
            if (mask_eff[cur_band])  sof_pending <= 1'b0;
            else if (s_axis_tuser)   sof_pending <= 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            m_axis_tvalid <= 1'b0; m_axis_tuser <= 1'b0; m_axis_tlast <= 1'b0;
        end else if (ce) begin
            m_axis_tvalid <= fire && mask_eff[cur_band];
            m_axis_tuser  <= s_axis_tuser || sof_pending;
            m_axis_tlast  <= (cur_pix == PW'(NX - 1)) && (cur_band == last_eff);
        end
    end

    always_ff @(posedge clk) if (ce) m_axis_tdata <= s_axis_tdata;
endmodule
