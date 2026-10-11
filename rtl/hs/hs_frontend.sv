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
    localparam int IW  = (NX * NB > 1) ? $clog2(NX * NB) : 1;
    localparam int MW  = (NB + 31) / 32;    // mask words
    localparam int PLW = DW + 2;

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

    logic [1:0]    region;
    logic [IW-1:0] tbl_addr;
    assign region   = cfg_addr[AW-3 -: 2];
    assign tbl_addr = cfg_addr[IW-1:0];

    logic [31:0]          line_period;
    logic [32*MW-1:0]     band_mask_words;
    logic [31:0]          cnt_overrun, cnt_framing, cnt_lines, cnt_badpix;
    logic                 ev_overrun, ev_lines, ev_badpix;
    logic [3:0]           ev_framing;
    logic                 clear_cnt;

    assign clear_cnt = cfg_we && region == 2'd0 && cfg_addr[7:0] == 8'h02 && cfg_wdata[0];

    always_ff @(posedge clk) begin
        if (rst) begin
            line_period     <= '0;
            band_mask_words <= '1;
        end else if (cfg_we && region == 2'd0) begin
            if (cfg_addr[7:0] == 8'h03) line_period <= cfg_wdata;
            for (int i = 0; i < MW; i++)
                if (cfg_addr[7:0] == 8'(64 + i)) band_mask_words[32*i +: 32] <= cfg_wdata;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || clear_cnt) begin
            cnt_overrun <= '0; cnt_framing <= '0; cnt_lines <= '0; cnt_badpix <= '0;
        end else begin
            cnt_overrun <= cnt_overrun + 32'(ev_overrun);
            cnt_framing <= cnt_framing + 32'(|ev_framing);
            cnt_lines   <= cnt_lines   + 32'(ev_lines);
            cnt_badpix  <= cnt_badpix  + 32'(ev_badpix);
        end
    end

    always_ff @(posedge clk) begin
        if (cfg_re) begin
            cfg_rdata <= 32'h0;
            if (region == 2'd0) begin
                case (cfg_addr[7:0])
                    8'h00: cfg_rdata <= 32'h4853_0002;
                    8'h01: cfg_rdata <= {16'(NB), 16'(NX)};
                    8'h03: cfg_rdata <= line_period;
                    8'h04: cfg_rdata <= cnt_overrun;
                    8'h05: cfg_rdata <= cnt_framing;
                    8'h06: cfg_rdata <= cnt_lines;
                    8'h07: cfg_rdata <= cnt_badpix;
                    default: begin
                        for (int i = 0; i < MW; i++)
                            if (cfg_addr[7:0] == 8'(64 + i)) cfg_rdata <= band_mask_words[32*i +: 32];
                    end
                endcase
            end
        end
    end

    // ------------------------------------------------------------ datapath
    logic [DW-1:0] p_d;  logic p_v, p_r, p_u, p_l;
    line_pacer #(.DW(DW)) u_pacer (
        .clk, .rst, .line_period,
        .s_axis_tdata, .s_axis_tvalid, .s_axis_tready, .s_axis_tuser, .s_axis_tlast,
        .m_axis_tdata(p_d), .m_axis_tvalid(p_v), .m_axis_tready(p_r),
        .m_axis_tuser(p_u), .m_axis_tlast(p_l),
        .overrun(ev_overrun)
    );

    logic [PLW-1:0] r0_q; logic r0_v, r0_r;
    axis_register #(.W(PLW)) u_r0 (.clk, .rst,
        .s_data({p_u, p_l, p_d}), .s_valid(p_v), .s_ready(p_r),
        .m_data(r0_q), .m_valid(r0_v), .m_ready(r0_r));

    logic [DW-1:0] rc_d; logic rc_v, rc_r, rc_u, rc_l;
    radiometric_corr #(.DW(DW), .NX(NX), .NB(NB), .GW(GW), .GF(GF), .RAM_STYLE(RAM_STYLE)) u_rad (
        .clk, .rst,
        .dark_we (cfg_we && region == 2'd1),
        .gain_we (cfg_we && region == 2'd2),
        .tbl_addr, .tbl_wdata(cfg_wdata),
        .s_axis_tdata(r0_q[DW-1:0]), .s_axis_tvalid(r0_v), .s_axis_tready(r0_r),
        .s_axis_tuser(r0_q[DW+1]), .s_axis_tlast(r0_q[DW]),
        .m_axis_tdata(rc_d), .m_axis_tvalid(rc_v), .m_axis_tready(rc_r),
        .m_axis_tuser(rc_u), .m_axis_tlast(rc_l),
        .framing_err(ev_framing[0])
    );

    logic [PLW-1:0] r1_q; logic r1_v, r1_r;
    axis_register #(.W(PLW)) u_r1 (.clk, .rst,
        .s_data({rc_u, rc_l, rc_d}), .s_valid(rc_v), .s_ready(rc_r),
        .m_data(r1_q), .m_valid(r1_v), .m_ready(r1_r));

    logic [DW-1:0] bp_d; logic bp_v, bp_r, bp_u, bp_l;
    badpix_replace #(.DW(DW), .NX(NX), .NB(NB), .RAM_STYLE(RAM_STYLE)) u_bad (
        .clk, .rst,
        .map_we (cfg_we && region == 2'd3),
        .tbl_addr, .map_wdata(cfg_wdata[0]),
        .s_axis_tdata(r1_q[DW-1:0]), .s_axis_tvalid(r1_v), .s_axis_tready(r1_r),
        .s_axis_tuser(r1_q[DW+1]), .s_axis_tlast(r1_q[DW]),
        .m_axis_tdata(bp_d), .m_axis_tvalid(bp_v), .m_axis_tready(bp_r),
        .m_axis_tuser(bp_u), .m_axis_tlast(bp_l),
        .replaced(ev_badpix),
        .framing_err(ev_framing[1])
    );

    logic [PLW-1:0] r2_q; logic r2_v, r2_r;
    axis_register #(.W(PLW)) u_r2 (.clk, .rst,
        .s_data({bp_u, bp_l, bp_d}), .s_valid(bp_v), .s_ready(bp_r),
        .m_data(r2_q), .m_valid(r2_v), .m_ready(r2_r));

    logic [DW-1:0] bs_d; logic bs_v, bs_r, bs_u, bs_l;
    band_select #(.DW(DW), .NX(NX), .NB(NB)) u_sel (
        .clk, .rst,
        .band_mask (band_mask_words[NB-1:0]),
        .s_axis_tdata(r2_q[DW-1:0]), .s_axis_tvalid(r2_v), .s_axis_tready(r2_r),
        .s_axis_tuser(r2_q[DW+1]), .s_axis_tlast(r2_q[DW]),
        .m_axis_tdata(bs_d), .m_axis_tvalid(bs_v), .m_axis_tready(bs_r),
        .m_axis_tuser(bs_u), .m_axis_tlast(bs_l),
        .framing_err(ev_framing[2])
    );

    axis_register #(.W(PLW)) u_r3 (.clk, .rst,
        .s_data({bs_u, bs_l, bs_d}), .s_valid(bs_v), .s_ready(bs_r),
        .m_data({m_axis_tuser, m_axis_tlast, m_axis_tdata}),
        .m_valid(m_axis_tvalid), .m_ready(m_axis_tready));

    assign ev_lines      = m_axis_tvalid && m_axis_tready && m_axis_tlast;
    assign ev_framing[3] = 1'b0;

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused;
    assign unused = ^{cfg_addr[AW-5:IW], band_mask_words};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
