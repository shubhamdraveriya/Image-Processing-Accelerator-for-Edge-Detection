`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_axis_stage: self-checking AXI4-Stream testbench for the processing blocks.
//
//   MODE 0 = sobel_core, 1 = avg_pool2x2, 2 = edge_pipeline
//
//   Stimulus and expected output come from model/edge_golden.py (+IN=, +EXP=).
//   The driver inserts random tvalid gaps (VALID_PCT) and the sink applies
//   random tready backpressure (READY_PCT). Every output beat is compared with
//   the golden model, including tuser (start of frame) and tlast (end of line),
//   and the output must hold steady while tvalid && !tready (AXI-Stream rule).
//   The test fails on any mismatch, missing/extra beat or timeout.
// -----------------------------------------------------------------------------
module tb_axis_stage;
    parameter int MODE       = 2;
    parameter int DW         = 8;
    parameter int IMG_W      = 64;
    parameter int IMG_H      = 64;
    parameter int FRAMES     = 2;
    parameter int VALID_PCT  = 80;
    parameter int READY_PCT  = 70;
    parameter int SEED       = 1;

    localparam int OUT_W = (MODE == 0) ? IMG_W - 2 : (MODE == 1) ? IMG_W / 2 : (IMG_W - 2) / 2;
    localparam int OUT_H = (MODE == 0) ? IMG_H - 2 : (MODE == 1) ? IMG_H / 2 : (IMG_H - 2) / 2;
    localparam int N_IN  = IMG_W * IMG_H * FRAMES;
    localparam int N_OUT = OUT_W * OUT_H * FRAMES;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #2.5 clk = ~clk;   // 200 MHz

    logic [DW-1:0] s_tdata, m_tdata;
    logic          s_tvalid, s_tready, s_tuser, s_tlast;
    logic          m_tvalid, m_tready, m_tuser, m_tlast;
    logic          framing_err;

    generate
        if (MODE == 0) begin : g_dut
            sobel_core #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H)) dut (
                .clk, .rst,
                .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
                .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
                .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
                .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast),
                .framing_err);
        end else if (MODE == 1) begin : g_dut
            avg_pool2x2 #(.DW(DW), .IN_W(IMG_W), .IN_H(IMG_H)) dut (
                .clk, .rst,
                .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
                .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
                .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
                .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast),
                .framing_err);
        end else begin : g_dut
            edge_pipeline #(.DW(DW), .IMG_W(IMG_W), .IMG_H(IMG_H)) dut (
                .clk, .rst,
                .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
                .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
                .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
                .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast),
                .framing_err);
        end
    endgenerate

    logic [DW-1:0] in_mem  [0:N_IN-1];
    logic [DW-1:0] exp_mem [0:N_OUT-1];

    int errors   = 0;
    int n_out    = 0;
    int n_in     = 0;
    int seed_drv;
    int seed_snk;

    // ------------------------------------------------------------------ setup
    initial begin
        string in_file, exp_file;
        if (!$value$plusargs("IN=%s", in_file) || !$value$plusargs("EXP=%s", exp_file))
            $fatal(1, "need +IN=<file> and +EXP=<file>");
        $readmemh(in_file, in_mem);
        $readmemh(exp_file, exp_mem);
        seed_drv = SEED;
        seed_snk = SEED * 7 + 3;
        $display("tb_axis_stage MODE=%0d DW=%0d %0dx%0d frames=%0d valid=%0d%% ready=%0d%% seed=%0d",
                 MODE, DW, IMG_W, IMG_H, FRAMES, VALID_PCT, READY_PCT, SEED);
        repeat (5) @(posedge clk);
        rst <= 1'b0;
    end

    // ----------------------------------------------------------------- driver
    // Clocked process with non-blocking updates (same style as the sink), so
    // the handshake is sampled race-free in both Icarus and Verilator.
    int next;
    always @(posedge clk) begin
        if (rst) begin
            s_tvalid <= 1'b0;
            s_tdata  <= '0;
            s_tuser  <= 1'b0;
            s_tlast  <= 1'b0;
        end else begin
            next = n_in + ((s_tvalid && s_tready) ? 1 : 0);
            n_in <= next;
            if (!s_tvalid || s_tready) begin
                if (next < N_IN && ($urandom(seed_drv) % 100) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[next];
                    s_tuser  <= (next % (IMG_W * IMG_H)) == 0;
                    s_tlast  <= (next % IMG_W) == IMG_W - 1;
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
            seed_drv = seed_drv + 1;
        end
    end

    // ------------------------------------------------------------ sink/checks
    logic          prev_stall;
    logic [DW+1:0] prev_beat;
    logic          exp_user, exp_last;

    always @(posedge clk) begin
        if (rst) begin
            m_tready   <= 1'b0;
            prev_stall <= 1'b0;
        end else begin
            if (prev_stall && (!m_tvalid || {m_tuser, m_tlast, m_tdata} !== prev_beat)) begin
                $display("ERROR: output changed while stalled at beat %0d", n_out);
                errors++;
            end
            if (m_tvalid && m_tready) begin
                if (n_out >= N_OUT) begin
                    $display("ERROR: extra output beat %0d (data %0h)", n_out, m_tdata);
                    errors++;
                end else begin
                    exp_user = (n_out % (OUT_W * OUT_H)) == 0;
                    exp_last = (n_out % OUT_W) == OUT_W - 1;
                    if (m_tdata !== exp_mem[n_out] || m_tuser !== exp_user || m_tlast !== exp_last) begin
                        if (errors < 20)
                            $display("ERROR: beat %0d (frame %0d, row %0d, col %0d): got data=%0h user=%b last=%b, expected data=%0h user=%b last=%b",
                                     n_out, n_out / (OUT_W * OUT_H), (n_out % (OUT_W * OUT_H)) / OUT_W, n_out % OUT_W,
                                     m_tdata, m_tuser, m_tlast, exp_mem[n_out], exp_user, exp_last);
                        errors++;
                    end
                end
                n_out++;
            end
            if (framing_err) begin
                $display("ERROR: framing_err asserted");
                errors++;
            end
            prev_stall <= m_tvalid && !m_tready;
            prev_beat  <= {m_tuser, m_tlast, m_tdata};
            m_tready   <= ($urandom(seed_snk) % 100) < READY_PCT;
            seed_snk = seed_snk + 1;
        end
    end

    // ------------------------------------------------------------ end of test
    localparam int LIMIT = (N_IN * 100 / ((VALID_PCT < READY_PCT) ? VALID_PCT : READY_PCT)) * 2 + 1000;
    int cycles = 0;
    always @(posedge clk) if (!rst) cycles++;

    initial begin
        @(negedge rst);
        wait (n_out == N_OUT || cycles >= LIMIT);
        if (n_out == N_OUT) begin
            repeat (200) @(posedge clk);   // catch extra beats
        end else begin
            $display("ERROR: timeout, %0d of %0d output beats", n_out, N_OUT);
            errors++;
        end
        if (errors == 0 && n_out == N_OUT) begin
            $display("PASS: %0d input beats, %0d output beats, all match the golden model", N_IN, N_OUT);
            $finish;
        end else begin
            $display("FAIL: %0d error(s), %0d of %0d output beats", errors, n_out, N_OUT);
            $fatal(1, "test failed");
        end
    end
endmodule
