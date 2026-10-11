`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// line_pacer: pushbroom detector timing for replayed data.
//
// Data replayed from memory is always available, but a real focal plane
// delivers one line every line period and cannot be stalled. This block lets a
// new line start at most once every LINE_PERIOD clock cycles (0 = no pacing)
// and passes the samples of a started line through at full rate.
//
// If downstream backpressure keeps a line running past its period, the
// detector would have overwritten data: overrun pulses once for that line.
// -----------------------------------------------------------------------------
module line_pacer #(
    parameter int DW = 16
) (
    input  logic          clk,
    input  logic          rst,
    input  logic [31:0]   line_period,   // clock cycles per line, 0 = unpaced

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

    output logic          overrun
);
    logic [31:0] cnt;          // cycles since the current/last line started
    logic        in_line;
    logic        started;      // at least one line has started since reset
    logic        overrun_seen; // already flagged for the current line
    logic        allow, fire;

    assign allow = in_line || !started || (cnt >= line_period);

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tuser  = s_axis_tuser;
    assign m_axis_tlast  = s_axis_tlast;
    assign m_axis_tvalid = s_axis_tvalid && allow;
    assign s_axis_tready = m_axis_tready && allow;
    assign fire          = s_axis_tvalid && s_axis_tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt          <= '0;
            in_line      <= 1'b0;
            started      <= 1'b0;
            overrun_seen <= 1'b0;
            overrun      <= 1'b0;
        end else begin
            overrun <= 1'b0;
            if (cnt != '1) cnt <= cnt + 1'b1;

            if (fire && !in_line) begin          // first beat of a line
                cnt          <= 32'd1;
                started      <= 1'b1;
                overrun_seen <= 1'b0;
                in_line      <= !s_axis_tlast;
            end else if (fire && s_axis_tlast) begin
                in_line <= 1'b0;
            end

            // The next line is due but this one is still being delivered.
            if (in_line && line_period != '0 && cnt >= line_period && !overrun_seen
                && !(fire && s_axis_tlast)) begin
                overrun      <= 1'b1;
                overrun_seen <= 1'b1;
            end
        end
    end
endmodule
