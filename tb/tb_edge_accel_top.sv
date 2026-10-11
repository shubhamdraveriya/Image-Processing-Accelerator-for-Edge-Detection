`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_edge_accel_top: end-to-end self-checking test of edge_accel_top.
//
//   ROM image -> async FIFO (two unrelated clocks) -> Sobel -> pool ->
//   serializer. The testbench de-serializes the bit stream (MSB first, framed
//   by serial_last), applies random serial_ready backpressure and compares
//   every pixel with the golden model output in +EXP=.
// -----------------------------------------------------------------------------
module tb_edge_accel_top;
    parameter int  DW         = 8;
    parameter int  IMG_W      = 64;
    parameter int  IMG_H      = 64;
    parameter int  FRAMES     = 2;
    parameter      INIT_FILE  = "data/image_stripes_64x64.mem";
    parameter real SRC_HALF   = 5.0;    // 100 MHz
    parameter real PROC_HALF  = 2.5;    // 200 MHz
    parameter int  READY_PCT  = 70;
    parameter int  SEED       = 1;

    localparam int OUT_W = (IMG_W - 2) / 2;
    localparam int OUT_H = (IMG_H - 2) / 2;
    localparam int N_OUT = OUT_W * OUT_H * FRAMES;

    logic clk_src = 1'b0, clk_proc = 1'b0;
    logic rst = 1'b1;
    always #(SRC_HALF)  clk_src  = ~clk_src;
    always #(PROC_HALF) clk_proc = ~clk_proc;

    logic serial_out, serial_valid, serial_last, serial_ready;
    logic framing_err, src_done;

    edge_accel_top #(
        .DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H), .NUM_FRAMES(FRAMES), .INIT_FILE(INIT_FILE)
    ) dut (.*);

    logic [DW-1:0] exp_mem [0:N_OUT-1];
    logic [DW-1:0] shreg;
    int nbits  = 0;
    int n_out  = 0;
    int errors = 0;
    int seed;

    initial begin
        string exp_file;
        if (!$value$plusargs("EXP=%s", exp_file)) $fatal(1, "need +EXP=<file>");
        $readmemh(exp_file, exp_mem);
        seed = SEED;
        $display("tb_edge_accel_top %0dx%0d DW=%0d frames=%0d src=%0.1fns proc=%0.1fns ready=%0d%%",
                 IMG_W, IMG_H, DW, FRAMES, 2 * SRC_HALF, 2 * PROC_HALF, READY_PCT);
        #100 rst = 1'b0;
    end

    always @(posedge clk_proc) begin
        serial_ready <= ($urandom(seed) % 100) < READY_PCT;
        seed = seed + 1;
        if (framing_err) begin
            $display("ERROR: framing_err asserted");
            errors++;
        end
        if (!rst && serial_valid && serial_ready) begin
            shreg = {shreg[DW-2:0], serial_out};
            nbits++;
            if (serial_last) begin
                if (nbits != DW) begin
                    $display("ERROR: word %0d had %0d bits", n_out, nbits);
                    errors++;
                end
                if (n_out >= N_OUT) begin
                    $display("ERROR: extra word %0h", shreg);
                    errors++;
                end else if (shreg !== exp_mem[n_out]) begin
                    if (errors < 20)
                        $display("ERROR: pixel %0d: got %0h expected %0h", n_out, shreg, exp_mem[n_out]);
                    errors++;
                end
                n_out++;
                nbits = 0;
            end
        end
    end

    // generous bound: source time x20 plus serial time at the given ready rate x4
    localparam int LIMIT = int'((IMG_W * IMG_H * FRAMES * SRC_HALF * 20.0) / PROC_HALF)
                         + (N_OUT * DW * 400) / READY_PCT + 10000;
    int cycles = 0;
    always @(posedge clk_proc) if (!rst) cycles++;

    initial begin
        @(negedge rst);
        wait (n_out == N_OUT || cycles >= LIMIT);
        if (n_out == N_OUT) begin
            repeat (500) @(posedge clk_proc);
        end else begin
            $display("ERROR: timeout, %0d of %0d pixels", n_out, N_OUT);
            errors++;
        end
        if (errors == 0 && n_out == N_OUT && src_done) begin
            $display("PASS: %0d pixels over the serial link match the golden model", N_OUT);
            $finish;
        end else begin
            $display("FAIL: %0d error(s), %0d of %0d pixels, src_done=%b", errors, n_out, N_OUT, src_done);
            $fatal(1, "test failed");
        end
    end
endmodule
