`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// bip_counter: position tracker for a band-interleaved-by-pixel (BIP) stream.
//
//   Sample order inside a line: pixel 0 band 0..NB-1, pixel 1 band 0..NB-1, ...
//   tuser on a beat forces that beat to (pixel 0, band 0); tlast must sit on
//   the last band of the last pixel of each line, otherwise framing_err pulses.
//
//   The cur_* outputs describe the beat currently on the input (combinational
//   from registers and s_tuser); the counters advance on fire.
// -----------------------------------------------------------------------------
module bip_counter #(
    parameter int NX = 64,     // pixels per line
    parameter int NB = 16,     // bands per pixel
    parameter int PW = (NX > 1) ? $clog2(NX) : 1,
    parameter int BW = (NB > 1) ? $clog2(NB) : 1,
    parameter int IW = (NX * NB > 1) ? $clog2(NX * NB) : 1
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          fire,      // a beat is accepted this cycle
    input  logic          s_tuser,
    input  logic          s_tlast,

    output logic [PW-1:0] cur_pix,
    output logic [BW-1:0] cur_band,
    output logic [IW-1:0] cur_idx,   // pix * NB + band (sample index in line)
    output logic          cur_eol,   // last sample of the line
    output logic          framing_err
);
    logic [PW-1:0] pix;
    logic [BW-1:0] band;
    logic [IW-1:0] idx;

    assign cur_pix  = s_tuser ? '0 : pix;
    assign cur_band = s_tuser ? '0 : band;
    assign cur_idx  = s_tuser ? '0 : idx;
    assign cur_eol  = (cur_pix == PW'(NX - 1)) && (cur_band == BW'(NB - 1));

    always_ff @(posedge clk) begin
        if (rst) begin
            pix         <= '0;
            band        <= '0;
            idx         <= '0;
            framing_err <= 1'b0;
        end else begin
            framing_err <= fire && (s_tlast != cur_eol);
            if (fire) begin
                if (cur_eol) begin
                    pix  <= '0;
                    band <= '0;
                    idx  <= '0;
                end else begin
                    idx <= cur_idx + 1'b1;
                    if (cur_band == BW'(NB - 1)) begin
                        band <= '0;
                        pix  <= cur_pix + 1'b1;
                    end else begin
                        band <= cur_band + 1'b1;
                        pix  <= cur_pix;
                    end
                end
            end
        end
    end
endmodule
