`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// avg_pool2x2: streaming 2x2 average pooling (stride 2), AXI4-Stream in/out.
//
//   * Input : IN_W x IN_H (both even), raster order, tuser = SOF, tlast = EOL.
//   * Output: IN_W/2 x IN_H/2, floor((a + b + c + d) / 4).
//   * Pair sums from even rows are kept in one generic sdp_ram line buffer of
//     IN_W/2 entries; odd rows read them back and emit the average.
//   * Same stall-the-pipeline backpressure scheme and framing check
//     (tuser re-aligns, framing_err flags a misplaced tlast) as sobel_core.
// -----------------------------------------------------------------------------
module avg_pool2x2 #(
    parameter int DW           = 8,
    parameter int IN_W         = 62,
    parameter int IN_H         = 62,
    parameter     LB_RAM_STYLE = "auto"
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
    localparam int OUT_W = IN_W / 2;
    localparam int CW    = (IN_W > 1) ? $clog2(IN_W) : 1;
    localparam int RW    = (IN_H > 1) ? $clog2(IN_H) : 1;
    localparam int IW    = (OUT_W > 1) ? $clog2(OUT_W) : 1;

    `ifndef SYNTHESIS
    initial begin
        if (IN_W < 2 || IN_H < 2 || (IN_W % 2) != 0 || (IN_H % 2) != 0)
            $fatal(1, "avg_pool2x2: IN_W (%0d) and IN_H (%0d) must be even and >= 2", IN_W, IN_H);
    end
    `endif

    logic ce, fire;
    assign ce            = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = ce;
    assign fire          = s_axis_tvalid && ce;

    // Position counters (tuser re-aligns to 0,0).
    logic [CW-1:0] col, cur_col;
    logic [RW-1:0] row, cur_row;
    assign cur_col = s_axis_tuser ? '0 : col;
    assign cur_row = s_axis_tuser ? '0 : row;

    always_ff @(posedge clk) begin
        if (rst) framing_err <= 1'b0;
        else     framing_err <= fire && (s_axis_tlast != (cur_col == CW'(IN_W - 1)));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            col <= '0;
            row <= '0;
        end else if (fire) begin
            if (cur_col == CW'(IN_W - 1)) begin
                col <= '0;
                row <= (cur_row == RW'(IN_H - 1)) ? '0 : cur_row + 1'b1;
            end else begin
                col <= cur_col + 1'b1;
                row <= cur_row;
            end
        end
    end

    // Stage P: horizontal pair sum on every odd column.
    logic [DW-1:0] hold;
    logic [DW:0]   p_sum;
    logic [IW-1:0] p_idx;
    logic          p_v, p_odd_row, p_user, p_last;
    logic [DW:0]   lb_rdata;

    always_ff @(posedge clk) begin
        if (rst) p_v <= 1'b0;
        else if (ce) p_v <= fire && cur_col[0];
    end

    always_ff @(posedge clk) begin
        if (fire && !cur_col[0]) hold <= s_axis_tdata;
        if (ce) begin
            p_sum     <= {1'b0, hold} + {1'b0, s_axis_tdata};
            p_idx     <= IW'(cur_col >> 1);
            p_odd_row <= cur_row[0];
            p_user    <= (cur_row == RW'(1)) && (cur_col == CW'(1));
            p_last    <= (cur_col == CW'(IN_W - 1));
        end
    end

    sdp_ram #(
        .DW        (DW + 1),
        .DEPTH     (OUT_W),
        .RAM_STYLE (LB_RAM_STYLE)
    ) u_pair_buf (
        .wclk  (clk),
        .we    (ce && p_v && !p_odd_row),
        .waddr (p_idx),
        .wdata (p_sum),
        .rclk  (clk),
        .re    (ce),
        .raddr (IW'(cur_col >> 1)),
        .rdata (lb_rdata)
    );

    // Output stage: vertical sum and divide by 4 on odd rows.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [DW+1:0] total;   // bits [1:0] are dropped by the divide by 4
    /* verilator lint_on UNUSEDSIGNAL */
    assign total = {1'b0, lb_rdata} + {1'b0, p_sum};

    always_ff @(posedge clk) begin
        if (rst) m_axis_tvalid <= 1'b0;
        else if (ce) m_axis_tvalid <= p_v && p_odd_row;
    end

    always_ff @(posedge clk) begin
        if (ce) begin
            m_axis_tdata <= total[DW+1:2];
            m_axis_tuser <= p_user;
            m_axis_tlast <= p_last;
        end
    end
endmodule
