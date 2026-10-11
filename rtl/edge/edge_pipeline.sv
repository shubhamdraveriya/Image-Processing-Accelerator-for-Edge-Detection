`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// edge_pipeline: the reusable, vendor-neutral processing core.
//
//   s_axis (IMG_W x IMG_H) -> register slice -> sobel_core -> register slice
//          -> avg_pool2x2 -> register slice -> m_axis
//
//   Output frame: (IMG_W-2)/2 x (IMG_H-2)/2. IMG_W and IMG_H must be even.
//   All handshakes are AXI4-Stream (tdata/tvalid/tready/tuser=SOF/tlast=EOL);
//   tready is registered at every module boundary.
// -----------------------------------------------------------------------------
module edge_pipeline #(
    parameter int DW           = 8,
    parameter int IMG_W        = 64,
    parameter int IMG_H        = 64,
    parameter     LB_RAM_STYLE = "block"
) (
    input  logic          clk,
    input  logic          rst,

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
    localparam int PW = DW + 2;   // {tuser, tlast, tdata}

    // input slice
    logic [PW-1:0] in_q;
    logic          in_v, in_r;
    axis_register #(.W(PW)) u_in_reg (
        .clk, .rst,
        .s_data  ({s_axis_tuser, s_axis_tlast, s_axis_tdata}),
        .s_valid (s_axis_tvalid),
        .s_ready (s_axis_tready),
        .m_data  (in_q),
        .m_valid (in_v),
        .m_ready (in_r)
    );

    // Sobel
    logic          sobel_framing_err, pool_framing_err;
    logic [DW-1:0] sb_data;
    logic          sb_v, sb_r, sb_user, sb_last;
    sobel_core #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .LB_RAM_STYLE(LB_RAM_STYLE)
    ) u_sobel (
        .clk, .rst,
        .s_axis_tdata  (in_q[DW-1:0]),
        .s_axis_tvalid (in_v),
        .s_axis_tready (in_r),
        .s_axis_tuser  (in_q[DW+1]),
        .s_axis_tlast  (in_q[DW]),
        .m_axis_tdata  (sb_data),
        .m_axis_tvalid (sb_v),
        .m_axis_tready (sb_r),
        .m_axis_tuser  (sb_user),
        .m_axis_tlast  (sb_last),
        .framing_err   (sobel_framing_err)
    );

    // middle slice
    logic [PW-1:0] mid_q;
    logic          mid_v, mid_r;
    axis_register #(.W(PW)) u_mid_reg (
        .clk, .rst,
        .s_data  ({sb_user, sb_last, sb_data}),
        .s_valid (sb_v),
        .s_ready (sb_r),
        .m_data  (mid_q),
        .m_valid (mid_v),
        .m_ready (mid_r)
    );

    // Pooling
    logic [DW-1:0] pl_data;
    logic          pl_v, pl_r, pl_user, pl_last;
    avg_pool2x2 #(
        .DW(DW), .IN_W(IMG_W - 2), .IN_H(IMG_H - 2), .LB_RAM_STYLE("auto")
    ) u_pool (
        .clk, .rst,
        .s_axis_tdata  (mid_q[DW-1:0]),
        .s_axis_tvalid (mid_v),
        .s_axis_tready (mid_r),
        .s_axis_tuser  (mid_q[DW+1]),
        .s_axis_tlast  (mid_q[DW]),
        .m_axis_tdata  (pl_data),
        .m_axis_tvalid (pl_v),
        .m_axis_tready (pl_r),
        .m_axis_tuser  (pl_user),
        .m_axis_tlast  (pl_last),
        .framing_err   (pool_framing_err)
    );

    assign framing_err = sobel_framing_err || pool_framing_err;

    // output slice
    axis_register #(.W(PW)) u_out_reg (
        .clk, .rst,
        .s_data  ({pl_user, pl_last, pl_data}),
        .s_valid (pl_v),
        .s_ready (pl_r),
        .m_data  ({m_axis_tuser, m_axis_tlast, m_axis_tdata}),
        .m_valid (m_axis_tvalid),
        .m_ready (m_axis_tready)
    );
endmodule
