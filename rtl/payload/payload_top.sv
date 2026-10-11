`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// payload_top: the complete onboard hyperspectral processing chain.
//
//   sensor BIP stream (D bits, NB bands)
//     -> hs_frontend_core   line pacing, dark/gain correction, bad pixels,
//                           band selection (NZ bands kept)
//     -> fork ─▶ ccsds123_top    CCSDS 123.0-B-2 lossless compression
//              └▶ analytics_top  NDVI, cloud mask, Sobel edges, frame summary
//
//   m_comp  : compressed images (64-bit AXI4-Stream, one standard file per
//             image, header included)
//   m_prod  : per-pixel {cloud, veg, ndvi8}      m_edge : NDVI edge image
//   irq_frame pulses when a frame's summary is ready (cloud / vegetation /
//   edge counts and the keep flag, also in registers), so flight software
//   can decide whether to downlink the compressed copy of that frame.
//
// One AXI4-Lite slave (byte addresses):
//   0x0000_0000 - 0x0FFF_FFFF  front end, register map in hs_frontend.sv
//   0x1000_0000 +              payload registers:
//     0x00 ID               RO  0x504C_0005
//     0x04 GEOMETRY         RO  {NZ[15:0], NX[15:0]}
//     0x08 LINES            RO  NY
//     0x0C CTRL             WO  bit0: clear the counters below
//     0x10 AN_BANDS         RW  {blue[23:16], nir[15:8], red[7:0]}, indices among the kept bands
//     0x14 AN_BRIGHT        RW  cloud brightness threshold (blue band, D bits)
//     0x18 AN_THRESH        RW  {edge[23:16], veg[15:8], white[7:0]}
//     0x1C AN_CLOUD_MAX     RW  keep a frame if cloud fraction <= value / 256 (0..256)
//     0x20 LAST_CLOUD       RO  last frame: cloud pixels
//     0x24 LAST_VEG         RO  last frame: vegetation pixels
//     0x28 LAST_EDGE        RO  last frame: edge pixels
//     0x2C LAST_KEEP        RO  last frame: keep flag
//     0x30 FRAMES_ANALYSED  RO      0x34 FRAMES_KEPT        RO
//     0x38 IMAGES_COMPRESSED RO     0x3C BYTES_COMPRESSED   RO
//     0x40 ECC_CORRECTED    RO      0x44 ECC_UNCORRECTABLE  RO
//     0x48 TMR_UPSETS       RO      0x4C FRAMING_ERRS       RO  (compressor + analytics)
//
// NZ must equal the number of bands set in BAND_MASK; otherwise the
// compressor and analytics report framing errors.
// -----------------------------------------------------------------------------
module payload_top #(
    parameter int D         = 12,
    parameter int NX        = 32,
    parameter int NY        = 16,
    parameter int NB        = 32,      // sensor bands
    parameter int NZ        = 16,      // bands kept by BAND_MASK
    parameter int GW        = 16,
    parameter int GF        = 14,
    parameter int P         = 3,
    parameter bit FULL      = 1'b1,
    parameter int LOCAL_SUM = 0,
    parameter int OMEGA     = 13,
    parameter int R         = 64,
    parameter int VMIN      = -1,
    parameter int VMAX      = 3,
    parameter int TINC_LOG2 = 6,
    parameter int UMAX      = 18,
    parameter int GSTAR     = 6,
    parameter int GAMMA0    = 1,
    parameter int KINIT     = 3,
    parameter bit ECC       = 1'b0,
    parameter bit TMR       = 1'b0,
    parameter     RAM_STYLE = "block",
    parameter int AW        = 29,
    parameter int CW        = $clog2(NX * NY + 1)
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

    input  logic [D-1:0]  s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,
    input  logic          s_axis_tuser,
    input  logic          s_axis_tlast,

    output logic [63:0]   m_comp_tdata,
    output logic [7:0]    m_comp_tkeep,
    output logic          m_comp_tlast,
    output logic          m_comp_tvalid,
    input  logic          m_comp_tready,

    output logic [15:0]   m_prod_tdata,
    output logic          m_prod_tvalid,
    input  logic          m_prod_tready,
    output logic          m_prod_tuser,
    output logic          m_prod_tlast,

    output logic [7:0]    m_edge_tdata,
    output logic          m_edge_tvalid,
    input  logic          m_edge_tready,
    output logic          m_edge_tuser,
    output logic          m_edge_tlast,

    output logic          irq_frame
);
    // ------------------------------------------------------------ config bus
    logic          cfg_we, cfg_re, rd_pl;
    logic [AW-3:0] cfg_addr;
    logic [31:0]   cfg_wdata, cfg_rdata, fe_rdata, pl_rdata;
    logic          sel_pl;

    axil_cfg_bridge #(.AW(AW)) u_axil (
        .clk, .rst,
        .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
        .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
        .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
        .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
        .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
        .cfg_we, .cfg_re, .cfg_addr, .cfg_wdata, .cfg_rdata
    );

    assign sel_pl    = cfg_addr[AW-3];               // byte address bit 28
    assign cfg_rdata = rd_pl ? pl_rdata : fe_rdata;
    always_ff @(posedge clk) if (cfg_re) rd_pl <= sel_pl;

    // ------------------------------------------------------------- front end
    logic [D-1:0] fe_d;
    logic         fe_v, fe_r, fe_u, fe_l;

    hs_frontend_core #(.DW(D), .NX(NX), .NB(NB), .GW(GW), .GF(GF), .RAM_STYLE(RAM_STYLE), .AW(AW - 1)) u_fe (
        .clk, .rst,
        .cfg_we (cfg_we && !sel_pl), .cfg_re (cfg_re && !sel_pl), .cfg_addr (cfg_addr[AW-4:0]),
        .cfg_wdata, .cfg_rdata (fe_rdata),
        .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
        .m_axis_tdata (fe_d), .m_axis_tvalid (fe_v), .m_axis_tready (fe_r),
        .m_axis_tuser (fe_u), .m_axis_tlast (fe_l)
    );

    // fork: a sample leaves the front end when both consumers take it
    logic c_ready, a_ready;
    assign fe_r = c_ready && a_ready;

    // ------------------------------------------------------------ compressor
    logic [15:0] c_sbe, c_dbe, c_tmr;
    logic        c_framing;

    ccsds123_top #(
        .NX(NX), .NY(NY), .NZ(NZ), .D(D), .P(P), .FULL(FULL), .LOCAL_SUM(LOCAL_SUM), .OMEGA(OMEGA),
        .R(R), .VMIN(VMIN), .VMAX(VMAX), .TINC_LOG2(TINC_LOG2), .UMAX(UMAX), .GSTAR(GSTAR),
        .GAMMA0(GAMMA0), .KINIT(KINIT), .EMIT_HEADER(1'b1), .LB_RAM_STYLE(RAM_STYLE), .ECC(ECC), .TMR(TMR)
    ) u_comp (
        .clk, .rst,
        .s_axis_tdata (fe_d), .s_axis_tvalid (fe_v && a_ready), .s_axis_tready (c_ready),
        .s_axis_tuser (fe_u), .s_axis_tlast (fe_l),
        .m_axis_tdata (m_comp_tdata), .m_axis_tkeep (m_comp_tkeep), .m_axis_tlast (m_comp_tlast),
        .m_axis_tvalid (m_comp_tvalid), .m_axis_tready (m_comp_tready),
        .framing_err (c_framing),
        .cnt_ecc_sbe (c_sbe), .cnt_ecc_dbe (c_dbe), .cnt_tmr (c_tmr),
        .inj_sbe (1'b0), .inj_dbe (1'b0), .inj_tmr (1'b0)
    );

    // ------------------------------------------------------------- analytics
    localparam int BW = (NZ > 1) ? $clog2(NZ) : 1;
    logic [7:0]    an_red, an_nir, an_blue, an_white, an_veg, an_edge;
    logic [D-1:0]  an_bright;
    logic [8:0]    an_cloud_max;
    logic [CW-1:0] sum_cloud, sum_veg, sum_edge;
    logic          sum_keep, sum_valid, a_framing;

    analytics_top #(.D(D), .NX(NX), .NY(NY), .NB(NZ)) u_an (
        .clk, .rst,
        .cfg_red (an_red[BW-1:0]), .cfg_nir (an_nir[BW-1:0]), .cfg_blue (an_blue[BW-1:0]),
        .cfg_bright (an_bright), .cfg_white (an_white), .cfg_veg (an_veg), .cfg_edge (an_edge),
        .cfg_cloud_max (an_cloud_max),
        .s_axis_tdata (fe_d), .s_axis_tvalid (fe_v && c_ready), .s_axis_tready (a_ready),
        .s_axis_tuser (fe_u), .s_axis_tlast (fe_l),
        .m_prod_tdata, .m_prod_tvalid, .m_prod_tready, .m_prod_tuser, .m_prod_tlast,
        .m_edge_tdata, .m_edge_tvalid, .m_edge_tready, .m_edge_tuser, .m_edge_tlast,
        .sum_cloud, .sum_veg, .sum_edge, .sum_keep, .sum_valid,
        .framing_err (a_framing)
    );
    assign irq_frame = sum_valid;

    // ------------------------------------------------------ payload registers
    logic [31:0] last_cloud, last_veg, last_edge, n_frames, n_kept, n_images, n_bytes, n_framing;
    logic        last_keep, clear;
    logic [7:0]  rsel;
    logic [3:0]  keep_bytes;

    assign rsel  = cfg_addr[7:0];                    // word index
    assign clear = cfg_we && sel_pl && rsel == 8'h03 && cfg_wdata[0];

    always_comb begin
        keep_bytes = '0;
        for (int i = 0; i < 8; i++) keep_bytes = keep_bytes + 4'(m_comp_tkeep[i]);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            an_red <= '0; an_nir <= '0; an_blue <= '0; an_bright <= '1;
            an_white <= '0; an_veg <= '1; an_edge <= '1; an_cloud_max <= 9'd256;
        end else if (cfg_we && sel_pl) begin
            case (rsel)
                8'h04: {an_blue, an_nir, an_red} <= cfg_wdata[23:0];
                8'h05: an_bright <= cfg_wdata[D-1:0];
                8'h06: {an_edge, an_veg, an_white} <= cfg_wdata[23:0];
                8'h07: an_cloud_max <= cfg_wdata[8:0];
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            last_cloud <= '0; last_veg <= '0; last_edge <= '0; last_keep <= 1'b0;
            n_frames <= '0; n_kept <= '0; n_images <= '0; n_bytes <= '0; n_framing <= '0;
        end else begin
            if (sum_valid) begin
                last_cloud <= 32'(sum_cloud);
                last_veg   <= 32'(sum_veg);
                last_edge  <= 32'(sum_edge);
                last_keep  <= sum_keep;
                n_frames   <= n_frames + 1'b1;
                n_kept     <= n_kept + 32'(sum_keep);
            end
            if (m_comp_tvalid && m_comp_tready) begin
                n_bytes <= n_bytes + 32'(keep_bytes);
                if (m_comp_tlast) n_images <= n_images + 1'b1;
            end
            n_framing <= n_framing + 32'(c_framing || a_framing);
        end
    end

    always_ff @(posedge clk) begin
        if (cfg_re && sel_pl) begin
            case (rsel)
                8'h00: pl_rdata <= 32'h504C_0005;
                8'h01: pl_rdata <= {16'(NZ), 16'(NX)};
                8'h02: pl_rdata <= 32'(NY);
                8'h04: pl_rdata <= {8'd0, an_blue, an_nir, an_red};
                8'h05: pl_rdata <= 32'(an_bright);
                8'h06: pl_rdata <= {8'd0, an_edge, an_veg, an_white};
                8'h07: pl_rdata <= 32'(an_cloud_max);
                8'h08: pl_rdata <= last_cloud;
                8'h09: pl_rdata <= last_veg;
                8'h0A: pl_rdata <= last_edge;
                8'h0B: pl_rdata <= 32'(last_keep);
                8'h0C: pl_rdata <= n_frames;
                8'h0D: pl_rdata <= n_kept;
                8'h0E: pl_rdata <= n_images;
                8'h0F: pl_rdata <= n_bytes;
                8'h10: pl_rdata <= 32'(c_sbe);
                8'h11: pl_rdata <= 32'(c_dbe);
                8'h12: pl_rdata <= 32'(c_tmr);
                8'h13: pl_rdata <= n_framing;
                default: pl_rdata <= '0;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    assign unused = ^{cfg_addr[AW-4:8], an_red, an_nir, an_blue};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
