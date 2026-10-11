`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// axis_register: full-throughput AXI4-Stream register slice (skid buffer).
// Registers both the forward path (tdata/tvalid) and the backward path
// (tready), so it breaks the combinational tready chain between stages.
// TDATA here is any packed payload (e.g. {tuser, tlast, tdata}).
// -----------------------------------------------------------------------------
module axis_register #(
    parameter int W = 8
) (
    input  logic         clk,
    input  logic         rst,

    input  logic [W-1:0] s_data,
    input  logic         s_valid,
    output logic         s_ready,

    output logic [W-1:0] m_data,
    output logic         m_valid,
    input  logic         m_ready
);
    logic [W-1:0] skid_data;
    logic         skid_valid;

    assign s_ready = !skid_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid    <= 1'b0;
            skid_valid <= 1'b0;
        end else if (!skid_valid) begin
            if (!m_valid || m_ready) begin
                m_valid <= s_valid;
            end else if (s_valid) begin
                skid_valid <= 1'b1;   // output stalled: park the beat
            end
        end else if (m_ready) begin
            m_valid    <= 1'b1;       // drain the skid entry
            skid_valid <= 1'b0;
        end
    end

    // Data registers carry no reset (saves routing; valid qualifies them).
    always_ff @(posedge clk) begin
        if (!skid_valid) begin
            if (!m_valid || m_ready) m_data    <= s_data;
            else if (s_valid)        skid_data <= s_data;
        end else if (m_ready) begin
            m_data <= skid_data;
        end
    end
endmodule
