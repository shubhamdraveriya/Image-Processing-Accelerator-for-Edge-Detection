`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// analytics_top: onboard scene analytics on the hyperspectral stream.
//
//   in : AXI4-Stream samples, D bits, band-interleaved-by-pixel (NB bands per
//        pixel), tuser = first sample of a frame, tlast = last sample of a line
//   out: m_prod  one 16-bit word per pixel {cloud, veg, 000000, ndvi8},
//                raster order, tuser = first pixel, tlast = end of line
//        m_edge  Sobel edge magnitude of the NDVI image (8 bits, valid region
//                (NX-2) x (NY-2)), from the Phase 1 sobel_core
//        sum_*   per-frame summary, sum_valid pulses once per frame
//
//   ndvi8 = floor(256 * NIR / (NIR + RED)) saturated to 255 (128 if both 0)
//   cloud = BLUE >= cfg_bright and |ndvi8 - 128| <= cfg_white
//   veg   = !cloud and ndvi8 >= cfg_veg
//   sum_edge counts edge pixels >= cfg_edge;
//   sum_keep = sum_cloud * 256 <= cfg_cloud_max * NX * NY
//
// The keep flag lets the payload controller drop or deprioritise a cloudy
// frame (whose compressed copy comes out of the compressor at the same time)
// before downlink. The cfg_* inputs are sampled at the first sample of each
// frame. Bit-exact with model/analytics_golden.py.
// -----------------------------------------------------------------------------
module analytics_top #(
    parameter int D  = 12,
    parameter int NX = 32,
    parameter int NY = 24,
    parameter int NB = 16,
    parameter int BW = (NB > 1) ? $clog2(NB) : 1,
    parameter int CW = $clog2(NX * NY + 1)          // pixel count width
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [BW-1:0] cfg_red,
    input  logic [BW-1:0] cfg_nir,
    input  logic [BW-1:0] cfg_blue,
    input  logic [D-1:0]  cfg_bright,
    input  logic [7:0]    cfg_white,
    input  logic [7:0]    cfg_veg,
    input  logic [7:0]    cfg_edge,
    input  logic [8:0]    cfg_cloud_max,            // x / 256 of the frame

    input  logic [D-1:0]  s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,
    input  logic          s_axis_tuser,
    input  logic          s_axis_tlast,

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

    output logic [CW-1:0] sum_cloud,
    output logic [CW-1:0] sum_veg,
    output logic [CW-1:0] sum_edge,
    output logic          sum_keep,
    output logic          sum_valid,

    output logic          framing_err
);
    localparam int XW = (NX > 1) ? $clog2(NX) : 1;
    localparam int YW = (NY > 1) ? $clog2(NY) : 1;

    // `ifndef SYNTHESIS guards checks that only make sense in simulation
`ifndef SYNTHESIS
    initial if (NX < 3 || NY < 3) $fatal(1, "analytics_top: Sobel needs NX, NY >= 3");
`endif

    // ------------------------------------------- band tap: BIP -> pixels
    logic [BW-1:0] b;
    logic [XW-1:0] x;
    logic [BW-1:0] c_red, c_nir, c_blue;            // band indices of this frame
    logic [D-1:0]  c_bright;
    logic [7:0]    c_white, c_veg, c_edge;
    logic [8:0]    c_cloud_max;
    logic [D-1:0]  red_q, nir_q, blue_q;
    logic          tap_framing;
    logic          sof_pend;

    logic [BW-1:0] cur_b, sel_red, sel_nir, sel_blue;
    logic [XW-1:0] cur_x;
    logic          px_valid, px_ready, px_user, px_last, accept, pix_end;
    logic [D-1:0]  red_c, nir_c, blue_c;

    assign cur_b    = s_axis_tuser ? '0 : b;
    assign cur_x    = s_axis_tuser ? '0 : x;
    assign sel_red  = s_axis_tuser ? cfg_red  : c_red;
    assign sel_nir  = s_axis_tuser ? cfg_nir  : c_nir;
    assign sel_blue = s_axis_tuser ? cfg_blue : c_blue;
    // a frame start waits while the previous frame's first pixel is still on
    // its way to the classifier (only frames shorter than the divider are
    // affected), so c_* always holds the thresholds of the frame being
    // classified
    logic          cfg_busy;
    assign s_axis_tready = (!px_valid || px_ready) && !(s_axis_tuser && cfg_busy);
    assign accept   = s_axis_tvalid && s_axis_tready;
    assign pix_end  = (cur_b == BW'(NB - 1));
    assign red_c    = (cur_b == sel_red)  ? s_axis_tdata : red_q;
    assign nir_c    = (cur_b == sel_nir)  ? s_axis_tdata : nir_q;
    assign blue_c   = (cur_b == sel_blue) ? s_axis_tdata : blue_q;

    logic [D-1:0] px_red, px_nir, px_blue;

    always_ff @(posedge clk) begin
        if (rst) begin
            b <= '0; x <= '0; sof_pend <= 1'b0; px_valid <= 1'b0; tap_framing <= 1'b0; cfg_busy <= 1'b0;
            c_red <= '0; c_nir <= '0; c_blue <= '0; c_bright <= '0;
            c_white <= '0; c_veg <= '0; c_edge <= '0; c_cloud_max <= '0;
        end else begin
            tap_framing <= accept && (s_axis_tlast != (pix_end && cur_x == XW'(NX - 1)));
            if (px_valid && px_ready) px_valid <= 1'b0;
            if (nd_valid && nd_ready && nd_first) cfg_busy <= 1'b0;
            if (accept) begin
                if (s_axis_tuser) begin
                    cfg_busy <= 1'b1;
                    c_red <= cfg_red; c_nir <= cfg_nir; c_blue <= cfg_blue; c_bright <= cfg_bright;
                    c_white <= cfg_white; c_veg <= cfg_veg; c_edge <= cfg_edge;
                    c_cloud_max <= cfg_cloud_max;
                end
                red_q  <= red_c;
                nir_q  <= nir_c;
                blue_q <= blue_c;
                if (pix_end) begin
                    b        <= '0;
                    x        <= (cur_x == XW'(NX - 1)) ? '0 : cur_x + 1'b1;
                    px_valid <= 1'b1;
                    px_red   <= red_c;
                    px_nir   <= nir_c;
                    px_blue  <= blue_c;
                    px_user  <= s_axis_tuser || sof_pend;
                    px_last  <= (cur_x == XW'(NX - 1));
                    sof_pend <= 1'b0;
                end else begin
                    b        <= cur_b + 1'b1;
                    x        <= cur_x;
                    sof_pend <= sof_pend || s_axis_tuser;
                end
            end
        end
    end

    // --------------------------------------------------------------- NDVI
    logic [7:0]   nd;
    logic [D+1:0] nd_sb;                // {user, last, blue}
    logic         nd_valid, nd_ready;

    ndvi_div #(.D(D), .SB(D + 2)) u_div (
        .clk, .rst,
        .s_nir (px_nir), .s_red (px_red), .s_sb ({px_user, px_last, px_blue}),
        .s_valid (px_valid), .s_ready (px_ready),
        .m_ndvi (nd), .m_sb (nd_sb), .m_valid (nd_valid), .m_ready (nd_ready)
    );

    // ------------------------------------------------------ classification
    logic       is_cloud, is_veg;
    logic [7:0] nd_dist;
    assign nd_dist     = (nd >= 8'd128) ? nd - 8'd128 : 8'd128 - nd;
    // thresholds follow the frame through the pipeline: c_* holds them until
    // the frame's first pixel is classified (see cfg_busy), and the classifier
    // keeps its own copy (k_*) for the rest of the frame, while the band tap
    // may already be on the next one. The edge threshold waits in a two-entry
    // queue for the frame's first edge pixel, which leaves Sobel later.
    logic         nd_first;
    logic [D-1:0] k_bright, k_bright_q;
    logic [7:0]   k_white, k_veg, k_white_q, k_veg_q;
    logic [8:0]   k_cloud_max_q;
    assign nd_first = nd_sb[D+1];
    assign k_bright = nd_first ? c_bright : k_bright_q;
    assign k_white  = nd_first ? c_white : k_white_q;
    assign k_veg    = nd_first ? c_veg : k_veg_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            k_bright_q <= '0; k_white_q <= '0; k_veg_q <= '0; k_cloud_max_q <= '0;
        end else if (nd_valid && nd_ready && nd_first) begin
            k_bright_q <= c_bright; k_white_q <= c_white; k_veg_q <= c_veg;
            k_cloud_max_q <= c_cloud_max;
        end
    end

    assign is_cloud = (nd_sb[D-1:0] >= k_bright) && (nd_dist <= k_white);
    assign is_veg   = !is_cloud && (nd >= k_veg);

    // fork to the product output and the Sobel core: a beat leaves when both
    // can take it
    logic prod_ready, sob_ready;
    assign nd_ready = prod_ready && sob_ready;

    axis_register #(.W(18)) u_prod_reg (
        .clk, .rst,
        .s_data ({nd_sb[D+1], nd_sb[D], is_cloud, is_veg, 6'd0, nd}),
        .s_valid (nd_valid && sob_ready), .s_ready (prod_ready),
        .m_data ({m_prod_tuser, m_prod_tlast, m_prod_tdata}),
        .m_valid (m_prod_tvalid), .m_ready (m_prod_tready)
    );

    logic edge_framing;
    assign framing_err = tap_framing || edge_framing;
    sobel_core #(.DW(8), .IMG_W(NX), .IMG_H(NY)) u_sobel (
        .clk, .rst,
        .s_axis_tdata (nd), .s_axis_tvalid (nd_valid && prod_ready), .s_axis_tready (sob_ready),
        .s_axis_tuser (nd_sb[D+1]), .s_axis_tlast (nd_sb[D]),
        .m_axis_tdata (m_edge_tdata), .m_axis_tvalid (m_edge_tvalid), .m_axis_tready (m_edge_tready),
        .m_axis_tuser (m_edge_tuser), .m_axis_tlast (m_edge_tlast),
        .framing_err (edge_framing)
    );

    // --------------------------------------------------------- frame summary
    // product counts close at the last pixel of a frame, the edge count at the
    // last edge pixel (one line later); the summary goes out when both are in
    logic [CW-1:0] n_cloud, n_veg, n_edge, n_pix, h_cloud, h_veg;
    logic [7:0]    e_edge, e_edge_q;          // edge threshold of the frame leaving Sobel
    logic [7:0]    eq0, eq1;                  // queued edge thresholds, eq0 = oldest
    logic [1:0]    eq_n;
    logic          eq_push, eq_pop;
    logic [8:0]    h_cloud_max;
    logic [CW-1:0] cur_pix, cur_cloud, cur_veg, cur_edge;
    logic [YW-1:0] e_rows, cur_rows;
    logic          p_done, e_done, prod_beat, edge_beat, prod_end, edge_end;

    // a frame start (tuser) restarts the counts, which also re-synchronises
    // them after an error
    assign prod_beat = nd_valid && nd_ready;
    assign cur_pix   = nd_sb[D+1] ? '0 : n_pix;
    assign cur_cloud = (nd_sb[D+1] ? '0 : n_cloud) + CW'(is_cloud);
    assign cur_veg   = (nd_sb[D+1] ? '0 : n_veg) + CW'(is_veg);
    assign prod_end  = prod_beat && (cur_pix == CW'(NX * NY - 1));

    assign edge_beat = m_edge_tvalid && m_edge_tready;
    assign cur_rows  = m_edge_tuser ? '0 : e_rows;
    assign eq_push   = prod_beat && nd_first;
    assign eq_pop    = edge_beat && m_edge_tuser;
    assign e_edge    = m_edge_tuser ? eq0 : e_edge_q;
    assign cur_edge  = (m_edge_tuser ? '0 : n_edge) + CW'(m_edge_tdata >= e_edge);
    assign edge_end  = edge_beat && m_edge_tlast && (cur_rows == YW'(NY - 3));

    always_ff @(posedge clk) begin
        if (rst) begin
            n_cloud <= '0; n_veg <= '0; n_edge <= '0; n_pix <= '0; e_rows <= '0;
            p_done <= 1'b0; e_done <= 1'b0; sum_valid <= 1'b0;
            sum_cloud <= '0; sum_veg <= '0; sum_edge <= '0; sum_keep <= 1'b0;
            h_cloud <= '0; h_veg <= '0; h_cloud_max <= '0; e_edge_q <= '0;
            eq0 <= '0; eq1 <= '0; eq_n <= '0;
        end else begin
            case ({eq_push, eq_pop})
                2'b10: begin
                    if (eq_n == 2'd0) eq0 <= c_edge; else eq1 <= c_edge;
                    eq_n <= eq_n + 1'b1;
                end
                2'b01: begin
                    eq0 <= eq1; eq_n <= eq_n - 1'b1;
                end
                2'b11: begin
                    if (eq_n == 2'd1) eq0 <= c_edge;
                    else begin eq0 <= eq1; eq1 <= c_edge; end
                end
                default: ;
            endcase
            sum_valid <= 1'b0;
            if (prod_beat) begin
                n_pix   <= prod_end ? '0 : cur_pix + 1'b1;
                n_cloud <= prod_end ? '0 : cur_cloud;
                n_veg   <= prod_end ? '0 : cur_veg;
                if (prod_end) begin
                    h_cloud <= cur_cloud;
                    h_veg   <= cur_veg;
                    h_cloud_max <= k_cloud_max_q;
                    p_done  <= 1'b1;
                end
            end
            if (edge_beat) begin
                e_edge_q <= e_edge;
                n_edge <= edge_end ? '0 : cur_edge;
                if (m_edge_tlast)  e_rows <= edge_end ? '0 : cur_rows + 1'b1;
                else               e_rows <= cur_rows;
                if (edge_end) begin
                    sum_edge <= cur_edge;
                    e_done   <= 1'b1;
                end
            end
            if (p_done && e_done) begin
                p_done    <= 1'b0;
                e_done    <= 1'b0;
                sum_valid <= 1'b1;
                sum_cloud <= h_cloud;
                sum_veg   <= h_veg;
                sum_keep  <= (CW + 9)'({h_cloud, 8'd0}) <= (CW + 9)'(h_cloud_max) * (CW + 9)'(NX * NY);
            end
        end
    end
endmodule
