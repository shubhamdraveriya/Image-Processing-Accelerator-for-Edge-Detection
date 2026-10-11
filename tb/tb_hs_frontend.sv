`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// tb_hs_frontend: self-checking test of the hyperspectral front end.
//
//   1. Programs line period, band mask, dark/gain tables and the bad-pixel map
//      over AXI4-Lite from +CFG= (written by model/hs_golden.py) and reads
//      back the ID and geometry registers.
//   2. Streams +IN= (BIP cube frames) with random tvalid gaps and random
//      tready stalls, and compares every output beat with +EXP=, including
//      tuser (start of frame) and tlast (end of line).
//   3. Reads the status counters back over AXI4-Lite and checks lines out,
//      bad-pixel replacements, framing errors and overruns.
//   With LINE_PERIOD set it also checks that no two lines start closer
//   together than the period.
// -----------------------------------------------------------------------------
module tb_hs_frontend;
    parameter int DW          = 12;
    parameter int NX          = 32;
    parameter int NB          = 16;
    parameter int NY          = 6;
    parameter int FRAMES      = 2;
    parameter int NSEL        = 8;
    parameter int NREPL       = 0;
    parameter int PERIOD      = 0;
    parameter int EXPECT_OVR  = 0;    // 1: overruns must be reported
    parameter int VALID_PCT   = 80;
    parameter int READY_PCT   = 70;
    parameter int SEED        = 1;

    localparam int AW    = 28;
    localparam int N_IN  = NX * NB * NY * FRAMES;
    localparam int N_OUT = NX * NSEL * NY * FRAMES;
    localparam int LINE_OUT = NX * NSEL;

    logic clk = 1'b0, rst = 1'b1;
    always #2.5 clk = ~clk;

    // AXI-Lite
    logic [AW-1:0] awaddr = '0, araddr = '0;
    logic          awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
    logic [31:0]   wdata = '0, rdata;
    logic          awready, wready, bvalid, arready, rvalid;
    logic [1:0]    bresp, rresp;

    // AXI-Stream
    logic [DW-1:0] s_tdata, m_tdata;
    logic          s_tvalid, s_tready, s_tuser, s_tlast;
    logic          m_tvalid, m_tready, m_tuser, m_tlast;

    hs_frontend #(.DW(DW), .NX(NX), .NB(NB)) dut (
        .clk, .rst,
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(4'hf), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast)
    );

    // ----------------------------------------------------------- AXI-Lite BFM
    // Signals change at negedge; a handshake seen at a negedge happens at the
    // following posedge (inputs and readies are stable in between).
    task automatic axil_write(input logic [31:0] a, input logic [31:0] d);
        logic aw_ok, w_ok, aw_hs, w_hs;
        aw_ok = 1'b0; w_ok = 1'b0;
        @(negedge clk);
        awaddr = a[AW-1:0]; awvalid = 1'b1; wdata = d; wvalid = 1'b1;
        while (!(aw_ok && w_ok)) begin
            aw_hs = awvalid && awready;
            w_hs  = wvalid && wready;
            @(negedge clk);
            if (aw_hs) begin aw_ok = 1'b1; awvalid = 1'b0; end
            if (w_hs)  begin w_ok  = 1'b1; wvalid  = 1'b0; end
        end
        bready = 1'b1;
        while (!bvalid) @(negedge clk);
        @(negedge clk);
        bready = 1'b0;
    endtask

    task automatic axil_read(input logic [31:0] a, output logic [31:0] d);
        logic hs;
        @(negedge clk);
        araddr = a[AW-1:0]; arvalid = 1'b1;
        hs = 1'b0;
        while (!hs) begin
            hs = arready;
            @(negedge clk);
        end
        arvalid = 1'b0;
        rready  = 1'b1;
        while (!rvalid) @(negedge clk);
        d = rdata;
        @(negedge clk);
        rready = 1'b0;
    endtask

    // ------------------------------------------------------------------ data
    logic [DW-1:0] in_mem  [0:N_IN-1];
    logic [DW-1:0] exp_mem [0:N_OUT-1];
    int errors = 0, n_in = 0, n_out = 0, next;
    int seed_drv, seed_snk;
    logic cfg_done = 1'b0;
    logic [31:0] rd;

    initial begin
        string in_file, exp_file, cfg_file;
        int fd, code;
        logic [31:0] a, d;
        if (!$value$plusargs("IN=%s", in_file) || !$value$plusargs("EXP=%s", exp_file) ||
            !$value$plusargs("CFG=%s", cfg_file))
            $fatal(1, "need +IN= +EXP= +CFG=");
        $readmemh(in_file, in_mem);
        $readmemh(exp_file, exp_mem);
        seed_drv = SEED; seed_snk = SEED * 13 + 5;
        $display("tb_hs_frontend %0dx%0d bands x %0d lines x %0d frames, %0d-bit, keep %0d bands, period %0d, valid %0d%% ready %0d%%",
                 NX, NB, NY, FRAMES, DW, NSEL, PERIOD, VALID_PCT, READY_PCT);
        repeat (5) @(posedge clk);
        rst = 1'b0;

        axil_read(32'h0, rd);
        if (rd !== 32'h4853_0002) begin $display("ERROR: ID = %08h", rd); errors++; end
        axil_read(32'h4, rd);
        if (rd !== {16'(NB), 16'(NX)}) begin $display("ERROR: GEOMETRY = %08h", rd); errors++; end

        fd = $fopen(cfg_file, "r");
        if (fd == 0) $fatal(1, "cannot open %s", cfg_file);
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h\n", a, d);
            if (code == 2) axil_write(a, d);
        end
        $fclose(fd);
        axil_read(32'hC, rd);
        if (rd !== 32'(PERIOD)) begin $display("ERROR: LINE_PERIOD readback %0d", rd); errors++; end
        cfg_done = 1'b1;
    end

    // driver (clocked, race-free)
    always @(posedge clk) begin
        if (rst || !cfg_done) begin
            s_tvalid <= 1'b0; s_tdata <= '0; s_tuser <= 1'b0; s_tlast <= 1'b0;
        end else begin
            next = n_in + ((s_tvalid && s_tready) ? 1 : 0);
            n_in <= next;
            if (!s_tvalid || s_tready) begin
                if (next < N_IN && ($urandom(seed_drv) % 100) < VALID_PCT) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= in_mem[next];
                    s_tuser  <= (next % (NX * NB * NY)) == 0;
                    s_tlast  <= (next % (NX * NB)) == NX * NB - 1;
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
            seed_drv = seed_drv + 1;
        end
    end

    // line start spacing
    longint cyc = 0, last_start = -1;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (s_tvalid && s_tready && (n_in % (NX * NB)) == 0) begin
            if (PERIOD > 0 && last_start >= 0 && cyc - last_start < PERIOD) begin
                $display("ERROR: line started %0d cycles after the previous one (period %0d)", cyc - last_start, PERIOD);
                errors++;
            end
            last_start <= cyc;
        end
    end

    // sink + checks
    logic exp_user, exp_last;
    always @(posedge clk) begin
        if (rst) begin
            m_tready <= 1'b0;
        end else begin
            if (m_tvalid && m_tready) begin
                exp_user = (n_out % (LINE_OUT * NY)) == 0;
                exp_last = (n_out % LINE_OUT) == LINE_OUT - 1;
                if (n_out >= N_OUT) begin
                    $display("ERROR: extra output beat"); errors++;
                end else if (m_tdata !== exp_mem[n_out] || m_tuser !== exp_user || m_tlast !== exp_last) begin
                    if (errors < 20)
                        $display("ERROR: beat %0d (line %0d, pos %0d): got %0h u%b l%b, expected %0h u%b l%b",
                                 n_out, n_out / LINE_OUT, n_out % LINE_OUT, m_tdata, m_tuser, m_tlast,
                                 exp_mem[n_out], exp_user, exp_last);
                    errors++;
                end
                n_out++;
            end
            m_tready <= ($urandom(seed_snk) % 100) < READY_PCT;
            seed_snk = seed_snk + 1;
        end
    end

    // end of test
    localparam int LIMIT = (N_IN * 100 / ((VALID_PCT < READY_PCT) ? VALID_PCT : READY_PCT)) * 3
                         + PERIOD * NY * FRAMES * 2 + 20000 + 40 * NX * NB;
    int cycles = 0;
    always @(posedge clk) if (!rst) cycles++;

    initial begin
        @(negedge rst);
        wait ((n_out == N_OUT && cfg_done) || cycles >= LIMIT);
        if (n_out != N_OUT) begin
            $display("ERROR: timeout, %0d of %0d output beats", n_out, N_OUT); errors++;
        end
        repeat (100) @(posedge clk);
        axil_read(32'h18, rd);
        if (rd !== 32'(NY * FRAMES)) begin $display("ERROR: LINES_OUT = %0d", rd); errors++; end
        axil_read(32'h1C, rd);
        if (rd !== 32'(NREPL)) begin $display("ERROR: BADPIX_REPL = %0d, expected %0d", rd, NREPL); errors++; end
        axil_read(32'h14, rd);
        if (rd !== 0) begin $display("ERROR: FRAMING_ERRS = %0d", rd); errors++; end
        axil_read(32'h10, rd);
        if (EXPECT_OVR ? (rd == 0) : (rd != 0)) begin
            $display("ERROR: OVERRUNS = %0d (expected %s)", rd, EXPECT_OVR ? "> 0" : "0"); errors++;
        end else begin
            $display("info: OVERRUNS = %0d", rd);
        end
        axil_write(32'h8, 32'h1);
        axil_read(32'h18, rd);
        if (rd !== 0) begin $display("ERROR: counters not cleared (%0d)", rd); errors++; end

        if (errors == 0) begin
            $display("PASS: %0d samples in, %0d out, registers and counters correct", N_IN, N_OUT);
            $finish;
        end else begin
            $display("FAIL: %0d error(s)", errors);
            $fatal(1, "test failed");
        end
    end
endmodule
