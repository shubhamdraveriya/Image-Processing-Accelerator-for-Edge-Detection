`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// edge_accel_top: vendor-neutral top of the edge accelerator demo.
//
//   clk_src  domain : image_rom_source (AXI-Stream)
//   CDC             : axis_async_fifo (gray pointers, no vendor IP)
//   clk_proc domain : edge_pipeline (Sobel + 2x2 pool) -> axis_serializer
//
// Contains no clocking primitives; board wrappers (rtl/board/*) provide the
// clocks. That keeps this file portable to Artix-7, Zynq UltraScale+ and the
// XQRKU060.
// -----------------------------------------------------------------------------
module edge_accel_top #(
    parameter int DW           = 8,
    parameter int IMG_W        = 64,
    parameter int IMG_H        = 64,
    parameter int NUM_FRAMES   = 0,
    parameter     INIT_FILE    = "image_stripes_64x64.mem",
    parameter int FIFO_DEPTH   = 16,
    parameter     LB_RAM_STYLE = "block"
) (
    input  logic clk_src,
    input  logic clk_proc,
    input  logic rst,            // asynchronous, active high

    output logic serial_out,
    output logic serial_valid,
    output logic serial_last,    // last (LSB) bit of each output pixel
    input  logic serial_ready,

    output logic framing_err,
    output logic src_done
);
    localparam int PW = DW + 2;

    logic rst_src, rst_proc;
    reset_sync u_rst_src  (.clk(clk_src),  .rst_async(rst), .rst_sync(rst_src));
    reset_sync u_rst_proc (.clk(clk_proc), .rst_async(rst), .rst_sync(rst_proc));

    // ---------------- source domain ----------------
    logic [DW-1:0] src_data;
    logic          src_v, src_r, src_user, src_last;

    image_rom_source #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H),
        .NUM_FRAMES(NUM_FRAMES), .INIT_FILE(INIT_FILE)
    ) u_src (
        .clk           (clk_src),
        .rst           (rst_src),
        .m_axis_tdata  (src_data),
        .m_axis_tvalid (src_v),
        .m_axis_tready (src_r),
        .m_axis_tuser  (src_user),
        .m_axis_tlast  (src_last),
        .done          (src_done)
    );

    // ---------------- clock crossing ---------------
    logic [PW-1:0] cdc_q;
    logic          cdc_v, cdc_r;

    axis_async_fifo #(.W(PW), .DEPTH(FIFO_DEPTH)) u_cdc (
        .s_clk   (clk_src),
        .s_rst   (rst_src),
        .s_data  ({src_user, src_last, src_data}),
        .s_valid (src_v),
        .s_ready (src_r),
        .m_clk   (clk_proc),
        .m_rst   (rst_proc),
        .m_data  (cdc_q),
        .m_valid (cdc_v),
        .m_ready (cdc_r)
    );

    // ---------------- processing domain -------------
    logic [DW-1:0] px_data;
    logic          px_v, px_r;
    logic          px_user_unused, px_last_unused;

    edge_pipeline #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .LB_RAM_STYLE(LB_RAM_STYLE)
    ) u_pipe (
        .clk           (clk_proc),
        .rst           (rst_proc),
        .s_axis_tdata  (cdc_q[DW-1:0]),
        .s_axis_tvalid (cdc_v),
        .s_axis_tready (cdc_r),
        .s_axis_tuser  (cdc_q[DW+1]),
        .s_axis_tlast  (cdc_q[DW]),
        .m_axis_tdata  (px_data),
        .m_axis_tvalid (px_v),
        .m_axis_tready (px_r),
        .m_axis_tuser  (px_user_unused),
        .m_axis_tlast  (px_last_unused),
        .framing_err   (framing_err)
    );

    axis_serializer #(.DW(DW)) u_ser (
        .clk           (clk_proc),
        .rst           (rst_proc),
        .s_axis_tdata  (px_data),
        .s_axis_tvalid (px_v),
        .s_axis_tready (px_r),
        .m_bit         (serial_out),
        .m_bit_valid   (serial_valid),
        .m_bit_last    (serial_last),
        .m_bit_ready   (serial_ready)
    );
endmodule
