`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// ccsds123_packer: packs variable-length codewords into a 64-bit AXI4-Stream
// byte stream.
//
//   in : (code, len, last); the codeword is the len low bits of code, MSB first
//   out: AXI4-Stream, byte lane 0 (tdata[7:0]) carries the first byte, tkeep
//        marks valid lanes (all ones except possibly on the last word of an
//        image), tlast marks the last word of an image
//
// Each image is padded with zero bits to a whole byte, as the standard's
// output word size B = 1 requires. One codeword is accepted per clock; an
// image whose tail spills into a second word costs one extra flush cycle.
// -----------------------------------------------------------------------------
module ccsds123_packer #(
    parameter int CW = 16,
    parameter int LW = 6
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [CW-1:0] s_code,
    input  logic [LW-1:0] s_len,
    input  logic          s_last,
    input  logic          s_valid,
    output logic          s_ready,

    output logic [63:0]   m_axis_tdata,
    output logic [7:0]    m_axis_tkeep,
    output logic          m_axis_tlast,
    output logic          m_axis_tvalid,
    input  logic          m_axis_tready
);
    // pending bits sit right-aligned in acc: the oldest is acc[cnt-1]
    logic [127:0] acc, acc_nx;
    logic [6:0]   cnt;                  // 0..63 between words
    logic [7:0]   cnt_nx;               // up to 63 + 48
    logic         flush;                // image tail still to be sent
    logic         ce, accept;

    assign ce      = !m_axis_tvalid || m_axis_tready;
    assign s_ready = ce && !flush;
    assign accept  = s_valid && s_ready;

    assign acc_nx = (acc << s_len) | 128'(s_code);    // code < 2^len by construction
    assign cnt_nx = 8'(cnt) + 8'(s_len);

    // first 64 bits of a big-endian bit string -> AXIS lanes (lane 0 first)
    function automatic [63:0] lanes(input logic [63:0] be);
        for (int i = 0; i < 8; i++) lanes[8*i +: 8] = be[63 - 8*i -: 8];
    endfunction
    function automatic [7:0] keep_of(input logic [6:0] nbits);   // 1..64 bits
        keep_of = 8'((9'd1 << ((nbits + 7'd7) >> 3)) - 1'b1);
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            acc <= '0; cnt <= '0; flush <= 1'b0;
            m_axis_tvalid <= 1'b0; m_axis_tdata <= '0; m_axis_tkeep <= '0; m_axis_tlast <= 1'b0;
        end else if (ce) begin
            m_axis_tvalid <= 1'b0;
            if (flush) begin
                // remaining 1..47 bits of the image, zero padded
                m_axis_tvalid <= 1'b1;
                m_axis_tdata  <= lanes(64'(acc << (7'd64 - cnt)));
                m_axis_tkeep  <= keep_of(cnt);
                m_axis_tlast  <= 1'b1;
                cnt   <= '0;
                acc   <= '0;
                flush <= 1'b0;
            end else if (accept) begin
                if (cnt_nx >= 8'd64) begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= lanes(64'(acc_nx >> (cnt_nx - 8'd64)));
                    m_axis_tkeep  <= 8'hff;
                    m_axis_tlast  <= s_last && (cnt_nx == 8'd64);
                    cnt   <= 7'(cnt_nx - 8'd64);
                    acc   <= acc_nx;
                    flush <= s_last && (cnt_nx != 8'd64);
                end else if (s_last) begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= lanes(64'(acc_nx << (8'd64 - cnt_nx)));
                    m_axis_tkeep  <= keep_of(7'(cnt_nx));
                    m_axis_tlast  <= 1'b1;
                    cnt <= '0;
                    acc <= '0;
                end else begin
                    cnt <= 7'(cnt_nx);
                    acc <= acc_nx;
                end
            end
        end
    end
endmodule
