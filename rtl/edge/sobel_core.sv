`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// sobel_core: streaming 3x3 Sobel edge magnitude, AXI4-Stream in and out.
//
//   * Input frame : IMG_W x IMG_H pixels, raster order, DW bits each.
//                   tuser = start of frame (first pixel), tlast = end of line.
//   * Output frame: (IMG_W-2) x (IMG_H-2) pixels ("valid" border policy: a
//                   result is produced only where the full 3x3 window lies
//                   inside the image, so there is no row-wrap or edge garbage).
//   * Magnitude   : |Gx| + |Gy|, saturated to 2^DW - 1.
//   * Backpressure: the whole pipeline stalls when m_axis_tready is low, so no
//                   pixel is ever dropped. Put an axis_register on each side
//                   to keep tready off the critical path.
//   * Framing     : tuser on an input beat re-aligns the row/column counters;
//                   framing_err pulses when an input tlast does not match the
//                   configured line length.
//
// Line buffers live in one generic sdp_ram (2 lines x IMG_W x DW), so they map
// to BRAM/LUTRAM/URAM by parameter and contain no SRLs.
// -----------------------------------------------------------------------------
module sobel_core #(
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
    localparam int CW   = $clog2(IMG_W);
    localparam int RW   = $clog2(IMG_H);
    localparam int MAXV = (1 << DW) - 1;

    // synthesis translate_off
    initial begin
        if (IMG_W < 3 || IMG_H < 3) $fatal(1, "sobel_core: image must be at least 3x3");
    end
    // synthesis translate_on

    // ---------------------------------------------------------------------
    // Pipeline enable: everything advances together when the output register
    // is empty or being read.
    // ---------------------------------------------------------------------
    logic ce;
    logic fire;
    assign ce            = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = ce;
    assign fire          = s_axis_tvalid && ce;

    // ---------------------------------------------------------------------
    // Position counters
    // ---------------------------------------------------------------------
    logic [CW-1:0] col, cur_col;
    logic [RW-1:0] row, cur_row;

    assign cur_col = s_axis_tuser ? '0 : col;
    assign cur_row = s_axis_tuser ? '0 : row;

    always_ff @(posedge clk) begin
        if (rst) begin
            col         <= '0;
            row         <= '0;
            framing_err <= 1'b0;
        end else begin
            framing_err <= fire && (s_axis_tlast != (cur_col == CW'(IMG_W - 1)));
            if (fire) begin
                if (cur_col == CW'(IMG_W - 1)) begin
                    col <= '0;
                    row <= (cur_row == RW'(IMG_H - 1)) ? '0 : cur_row + 1'b1;
                end else begin
                    col <= cur_col + 1'b1;
                    row <= cur_row;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // Stage A: accept pixel, issue line-buffer read for this column.
    // Line-buffer word = {pixel from row r-2, pixel from row r-1}.
    // ---------------------------------------------------------------------
    logic          a_v;
    logic [DW-1:0] a_pix;
    logic [CW-1:0] a_col;
    logic [RW-1:0] a_row;
    logic [2*DW-1:0] lb_rdata;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_v <= 1'b0;
        end else if (ce) begin
            a_v <= fire;
        end
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            a_pix <= s_axis_tdata;
            a_col <= cur_col;
            a_row <= cur_row;
        end
    end

    sdp_ram #(
        .DW        (2 * DW),
        .DEPTH     (IMG_W),
        .RAM_STYLE (LB_RAM_STYLE)
    ) u_line_buf (
        .wclk  (clk),
        .we    (ce && a_v),
        .waddr (a_col),
        .wdata ({lb_rdata[DW-1:0], a_pix}),   // r-1 becomes r-2, new pixel becomes r-1
        .rclk  (clk),
        .re    (ce),
        .raddr (cur_col),
        .rdata (lb_rdata)
    );

    // ---------------------------------------------------------------------
    // Stage B: shift the 3x3 window (w[row][col], row 0 = top).
    // ---------------------------------------------------------------------
    logic [DW-1:0] w00, w01, w02, w10, w11, w12, w20, w21, w22;
    logic          b_v, b_user, b_last;

    always_ff @(posedge clk) begin
        if (rst) begin
            b_v <= 1'b0;
        end else if (ce) begin
            b_v <= a_v && (a_row >= RW'(2)) && (a_col >= CW'(2));
        end
    end

    always_ff @(posedge clk) begin
        if (ce && a_v) begin
            w00 <= w01; w01 <= w02; w02 <= lb_rdata[2*DW-1:DW];
            w10 <= w11; w11 <= w12; w12 <= lb_rdata[DW-1:0];
            w20 <= w21; w21 <= w22; w22 <= a_pix;
        end
        if (ce) begin
            b_user <= (a_row == RW'(2)) && (a_col == CW'(2));
            b_last <= (a_col == CW'(IMG_W - 1));
        end
    end

    // ---------------------------------------------------------------------
    // Stage C: column / row differences
    // ---------------------------------------------------------------------
    logic signed [DW+1:0] d1x, d2x, d3x, d1y, d2y, d3y;
    logic                 c_v, c_user, c_last;

    function automatic logic signed [DW+1:0] sx(input logic [DW-1:0] v);
        return $signed({2'b00, v});
    endfunction

    // ---------------------------------------------------------------------
    // Stage D: gradients. Stage E: |Gx| + |Gy|. Stage F: saturate (output).
    // ---------------------------------------------------------------------
    logic signed [DW+3:0] gx, gy;
    logic                 d_v, d_user, d_last;
    logic        [DW+3:0] mag;
    logic                 e_v, e_user, e_last;

    always_ff @(posedge clk) begin
        if (rst) begin
            c_v <= 1'b0; d_v <= 1'b0; e_v <= 1'b0; m_axis_tvalid <= 1'b0;
        end else if (ce) begin
            c_v <= b_v; d_v <= c_v; e_v <= d_v; m_axis_tvalid <= e_v;
        end
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            d1x <= sx(w02) - sx(w00);
            d2x <= sx(w12) - sx(w10);
            d3x <= sx(w22) - sx(w20);
            d1y <= sx(w00) - sx(w20);
            d2y <= sx(w01) - sx(w21);
            d3y <= sx(w02) - sx(w22);
            c_user <= b_user; c_last <= b_last;

            gx <= (DW+4)'(d1x) + ((DW+4)'(d2x) <<< 1) + (DW+4)'(d3x);
            gy <= (DW+4)'(d1y) + ((DW+4)'(d2y) <<< 1) + (DW+4)'(d3y);
            d_user <= c_user; d_last <= c_last;

            mag <= (gx[DW+3] ? -gx : gx) + (gy[DW+3] ? -gy : gy);
            e_user <= d_user; e_last <= d_last;

            m_axis_tdata <= (mag > (DW+4)'(MAXV)) ? DW'(MAXV) : mag[DW-1:0];
            m_axis_tuser <= e_user; m_axis_tlast <= e_last;
        end
    end
endmodule
