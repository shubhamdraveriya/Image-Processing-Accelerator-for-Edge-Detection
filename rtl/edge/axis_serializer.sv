`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// axis_serializer: DW-bit AXI4-Stream words -> 1-bit stream, MSB first.
//
//   m_bit_last marks the LSB (last bit) of each word so a receiver can find
//   word boundaries. Accepts a new word on the same cycle the last bit of the
//   previous word is taken, so a continuous input gives a gap-free bit stream.
// -----------------------------------------------------------------------------
module axis_serializer #(
    parameter int DW = 8
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [DW-1:0] s_axis_tdata,
    input  logic          s_axis_tvalid,
    output logic          s_axis_tready,

    output logic          m_bit,
    output logic          m_bit_valid,
    output logic          m_bit_last,
    input  logic          m_bit_ready
);
    localparam int BW = (DW > 1) ? $clog2(DW) : 1;

    logic [DW-1:0] shreg;
    logic [BW-1:0] bit_cnt;   // bits still to send after the current one

    assign s_axis_tready = !m_bit_valid || (m_bit_ready && bit_cnt == '0);
    assign m_bit         = shreg[DW-1];
    assign m_bit_last    = (bit_cnt == '0);

    always_ff @(posedge clk) begin
        if (rst) begin
            m_bit_valid <= 1'b0;
            bit_cnt     <= '0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            shreg       <= s_axis_tdata;
            bit_cnt     <= BW'(DW - 1);
            m_bit_valid <= 1'b1;
        end else if (m_bit_valid && m_bit_ready) begin
            if (bit_cnt != '0) begin
                shreg   <= shreg << 1;
                bit_cnt <= bit_cnt - 1'b1;
            end else begin
                m_bit_valid <= 1'b0;
            end
        end
    end
endmodule
