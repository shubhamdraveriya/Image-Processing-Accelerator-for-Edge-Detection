`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// image_rom_source: plays an image stored in on-chip ROM out as AXI4-Stream.
//
//   Reads addresses 0 .. IMG_W*IMG_H-1 in order (the old design started at
//   address 1 and wrapped to 0 at the end; fixed). tuser on pixel 0, tlast at
//   the end of every line. NUM_FRAMES = 0 repeats forever, otherwise the
//   source stops after that many frames.
//   The ROM output register is the AXI-Stream output register; it only loads
//   when the stream can advance, so backpressure never loses a pixel.
// -----------------------------------------------------------------------------
module image_rom_source #(
    parameter int DW         = 8,
    parameter int IMG_W      = 64,
    parameter int IMG_H      = 64,
    parameter int NUM_FRAMES = 0,
    parameter     INIT_FILE  = "image_stripes_64x64.mem"
) (
    input  logic          clk,
    input  logic          rst,

    output logic [DW-1:0] m_axis_tdata,
    output logic          m_axis_tvalid,
    input  logic          m_axis_tready,
    output logic          m_axis_tuser,
    output logic          m_axis_tlast,

    output logic          done
);
    localparam int N  = IMG_W * IMG_H;
    localparam int AW = $clog2(N);
    localparam int CW = (IMG_W > 1) ? $clog2(IMG_W) : 1;
    localparam int FW = 16;

    (* ram_style = "block" *) logic [DW-1:0] rom [0:N-1];
    initial $readmemh(INIT_FILE, rom);

    logic [AW-1:0] addr;
    logic [CW-1:0] col;
    logic [FW-1:0] frame;
    logic          ce;

    assign ce = !m_axis_tvalid || m_axis_tready;

    always_ff @(posedge clk) begin
        if (rst) begin
            addr          <= '0;
            col           <= '0;
            frame         <= '0;
            done          <= 1'b0;
            m_axis_tvalid <= 1'b0;
        end else if (ce) begin
            m_axis_tvalid <= !done;
            if (!done) begin
                col <= (col == CW'(IMG_W - 1)) ? '0 : col + 1'b1;
                if (addr == AW'(N - 1)) begin
                    addr  <= '0;
                    frame <= frame + 1'b1;
                    if (NUM_FRAMES != 0 && frame == FW'(NUM_FRAMES - 1)) done <= 1'b1;
                end else begin
                    addr <= addr + 1'b1;
                end
            end
        end
    end

    // ROM read with output enable (maps to BRAM with its output register).
    always_ff @(posedge clk) begin
        if (ce) begin
            m_axis_tdata <= rom[addr];
            m_axis_tuser <= (addr == '0);
            m_axis_tlast <= (col == CW'(IMG_W - 1));
        end
    end
endmodule
